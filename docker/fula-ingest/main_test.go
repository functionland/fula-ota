package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// mockKubo returns an httptest server that computes the real blake3 raw CID
// for received block/put bodies (exactly what kubo does with
// cid-codec=raw&mhtype=blake3) and counts calls.
func mockKubo(t *testing.T, calls *int64) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/api/v0/block/put"):
			atomic.AddInt64(calls, 1)
			if err := r.ParseMultipartForm(8 << 20); err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			f, _, err := r.FormFile("data")
			if err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			var buf bytes.Buffer
			buf.ReadFrom(f)
			c, err := computeBlake3RawCID(buf.Bytes())
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
			json.NewEncoder(w).Encode(map[string]any{"Key": c.String(), "Size": buf.Len()})
		case strings.HasPrefix(r.URL.Path, "/api/v0/id"):
			json.NewEncoder(w).Encode(map[string]string{"ID": "12D3KooWMockKubo"})
		default:
			http.NotFound(w, r)
		}
	}))
}

// mockStorage returns a storage-API mock answering /api/v1/storage.
func mockStorage(canUpload bool, status int) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/storage" {
			http.NotFound(w, r)
			return
		}
		if status != http.StatusOK {
			w.WriteHeader(status)
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"canUpload": canUpload})
	}))
}

func newTestServer(kubo, storage string, strict, noAuth bool) *server {
	cfg := config{
		kuboAPI:       kubo,
		storageAPIURL: storage,
		quotaStrict:   strict,
		maxBlockBytes: 1 << 20,
		maxConcurrent: 4,
		noAuth:        noAuth,
	}
	return newServer(cfg)
}

func doPut(s *server, cid string, body []byte, token string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPut, "/v0/block?cid="+cid, bytes.NewReader(body))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rr := httptest.NewRecorder()
	s.handleBlockPut(rr, req)
	return rr
}

func TestValidBlockAcceptedAndStored(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	s := newTestServer(k.URL, "", false, true)

	body := []byte("fula-ingest-valid-chunk")
	c, _ := computeBlake3RawCID(body)
	rr := doPut(s, c.String(), body, "")
	if rr.Code != 200 {
		t.Fatalf("want 200, got %d: %s", rr.Code, rr.Body.String())
	}
	if atomic.LoadInt64(&kuboCalls) != 1 {
		t.Fatalf("kubo should be called exactly once, got %d", kuboCalls)
	}
	var resp map[string]any
	json.Unmarshal(rr.Body.Bytes(), &resp)
	if resp["cid"] != c.String() {
		t.Fatalf("response cid mismatch: %v", resp)
	}
}

func TestTamperedByteRejectedNotStored(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	s := newTestServer(k.URL, "", false, true)

	body := []byte("fula-ingest-original-bytes")
	c, _ := computeBlake3RawCID(body)
	tampered := append([]byte{}, body...)
	tampered[3] ^= 0x01 // single flipped bit
	rr := doPut(s, c.String(), tampered, "")
	if rr.Code != 422 {
		t.Fatalf("want 422 for tampered body, got %d: %s", rr.Code, rr.Body.String())
	}
	if atomic.LoadInt64(&kuboCalls) != 0 {
		t.Fatalf("tampered block must NOT reach the blockstore (kubo calls=%d)", kuboCalls)
	}
}

func TestMissingOrInvalidCid(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	s := newTestServer(k.URL, "", false, true)

	rr := doPut(s, "", []byte("x"), "")
	if rr.Code != 400 {
		t.Fatalf("missing cid: want 400, got %d", rr.Code)
	}
	rr = doPut(s, "not-a-cid", []byte("x"), "")
	if rr.Code != 400 {
		t.Fatalf("invalid cid: want 400, got %d", rr.Code)
	}
}

func TestOversizeRejected(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	s := newTestServer(k.URL, "", false, true)
	s.cfg.maxBlockBytes = 64

	body := bytes.Repeat([]byte("A"), 65)
	c, _ := computeBlake3RawCID(body)
	rr := doPut(s, c.String(), body, "")
	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("want 413, got %d", rr.Code)
	}
}

func TestAuthRequiredWhenEnabled(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	s := newTestServer(k.URL, "", false, false) // auth ON

	body := []byte("needs-auth")
	c, _ := computeBlake3RawCID(body)
	rr := doPut(s, c.String(), body, "")
	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("want 401 without token, got %d", rr.Code)
	}
}

func TestQuotaDeniedBlocksIngestion(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	st := mockStorage(false, http.StatusOK) // canUpload=false
	defer st.Close()
	s := newTestServer(k.URL, st.URL, false, false)

	body := []byte("over-quota-user")
	c, _ := computeBlake3RawCID(body)
	rr := doPut(s, c.String(), body, "user-jwt")
	if rr.Code != http.StatusPaymentRequired {
		t.Fatalf("want 402 for quota-denied, got %d: %s", rr.Code, rr.Body.String())
	}
	if atomic.LoadInt64(&kuboCalls) != 0 {
		t.Fatalf("quota-denied upload must not store anything")
	}
}

func TestQuotaFailOpenMatchesGateway(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	st := mockStorage(false, http.StatusInternalServerError) // storage API down
	defer st.Close()
	s := newTestServer(k.URL, st.URL, false, false) // mode=open

	body := []byte("storage-api-down-open-mode")
	c, _ := computeBlake3RawCID(body)
	rr := doPut(s, c.String(), body, "user-jwt")
	if rr.Code != 200 {
		t.Fatalf("open mode must fail open like the gateway: want 200, got %d", rr.Code)
	}
}

func TestQuotaStrictDeniesWhenUnavailable(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	st := mockStorage(false, http.StatusInternalServerError)
	defer st.Close()
	s := newTestServer(k.URL, st.URL, true, false) // mode=strict

	body := []byte("storage-api-down-strict-mode")
	c, _ := computeBlake3RawCID(body)
	rr := doPut(s, c.String(), body, "user-jwt")
	if rr.Code != http.StatusPaymentRequired {
		t.Fatalf("strict mode must deny when quota unverifiable: want 402, got %d", rr.Code)
	}
	if atomic.LoadInt64(&kuboCalls) != 0 {
		t.Fatalf("strict-denied upload must not store anything")
	}
}

func TestQuotaCacheOneCallPerWindow(t *testing.T) {
	var kuboCalls int64
	var storageCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	st := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&storageCalls, 1)
		json.NewEncoder(w).Encode(map[string]any{"canUpload": true})
	}))
	defer st.Close()
	s := newTestServer(k.URL, st.URL, false, false)

	for i := 0; i < 5; i++ {
		body := []byte(fmt.Sprintf("chunk-%d", i))
		c, _ := computeBlake3RawCID(body)
		rr := doPut(s, c.String(), body, "same-jwt")
		if rr.Code != 200 {
			t.Fatalf("chunk %d: want 200, got %d", i, rr.Code)
		}
	}
	if atomic.LoadInt64(&storageCalls) != 1 {
		t.Fatalf("quota cache: want exactly 1 storage-API call for 5 chunks, got %d", storageCalls)
	}
}

func TestHealth(t *testing.T) {
	var kuboCalls int64
	k := mockKubo(t, &kuboCalls)
	defer k.Close()
	s := newTestServer(k.URL, "", false, true)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rr := httptest.NewRecorder()
	s.handleHealth(rr, req)
	if rr.Code != 200 {
		t.Fatalf("health: want 200, got %d", rr.Code)
	}
}
