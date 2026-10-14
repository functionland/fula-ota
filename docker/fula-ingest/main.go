// fula-ingest — verified byte ingress for the Fula network (Phase 2).
//
// Accepts client-side-encrypted chunk BYTES with a client-DECLARED blake3
// raw-leaf CID, verifies the CID over the body BEFORE storing (tampered
// byte => 422, nothing stored), then writes the block to the local kubo
// (block/put?cid-codec=raw&mhtype=blake3) and double-checks kubo's returned
// key. This is the server-side half of upload tamper-evidence; the client
// half (per-chunk pre-compute + ETag self-verify) ships in fula-client
// (walkable-v8).
//
// S1 quota gate (safeguards invariant: never unmetered ingestion): mirrors
// the gateway's check exactly — GET {STORAGE_API_URL}/api/v1/storage with
// the client's Bearer JWT => {canUpload}. INGEST_QUOTA_MODE=open matches the
// gateway's fail-open semantics; =strict denies when the check cannot pass.
//
// Endpoints:
//   PUT  /v0/block?cid=<declared-cidv1-raw-blake3>   body = chunk bytes
//   GET  /health
//
// Env: INGEST_PORT (3601), INGEST_BIND (0.0.0.0), KUBO_API
// (http://127.0.0.1:5001), STORAGE_API_URL (empty disables the quota call —
// pair with INGEST_NO_AUTH only in tests), INGEST_QUOTA_MODE (open|strict),
// INGEST_MAX_BLOCK_BYTES (4194304), INGEST_MAX_CONCURRENT (32),
// INGEST_NO_AUTH (0|1, tests only).
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/ipfs/go-cid"
	"github.com/multiformats/go-multihash"
	_ "github.com/multiformats/go-multihash/register/blake3"
)

type config struct {
	port          string
	bind          string
	kuboAPI       string
	storageAPIURL string
	quotaStrict   bool
	maxBlockBytes int64
	maxConcurrent int
	noAuth        bool
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func loadConfig() config {
	maxBytes, _ := strconv.ParseInt(envOr("INGEST_MAX_BLOCK_BYTES", "4194304"), 10, 64)
	if maxBytes <= 0 {
		maxBytes = 4194304
	}
	maxConc, _ := strconv.Atoi(envOr("INGEST_MAX_CONCURRENT", "32"))
	if maxConc <= 0 {
		maxConc = 32
	}
	return config{
		port:          envOr("INGEST_PORT", "3601"),
		bind:          envOr("INGEST_BIND", "0.0.0.0"),
		kuboAPI:       strings.TrimRight(envOr("KUBO_API", "http://127.0.0.1:5001"), "/"),
		storageAPIURL: strings.TrimRight(os.Getenv("STORAGE_API_URL"), "/"),
		quotaStrict:   envOr("INGEST_QUOTA_MODE", "open") == "strict",
		maxBlockBytes: maxBytes,
		maxConcurrent: maxConc,
		noAuth:        envOr("INGEST_NO_AUTH", "0") == "1",
	}
}

// computeBlake3RawCID returns the CIDv1(raw, blake3-256) for body — the same
// construction as fula-client's local_blake3_raw_cid and kubo's
// block/put?cid-codec=raw&mhtype=blake3 (codec 0x55, multihash 0x1e).
func computeBlake3RawCID(body []byte) (cid.Cid, error) {
	mh, err := multihash.Sum(body, multihash.BLAKE3, 32)
	if err != nil {
		return cid.Undef, err
	}
	return cid.NewCidV1(cid.Raw, mh), nil
}

// quotaCache: short per-token cache so a multi-thousand-chunk upload performs
// one storage-API call per TTL window, not one per chunk.
type quotaCache struct {
	mu  sync.Mutex
	m   map[string]quotaEntry
	ttl time.Duration
}

type quotaEntry struct {
	allowed bool
	exp     time.Time
}

func newQuotaCache(ttl time.Duration) *quotaCache {
	return &quotaCache{m: make(map[string]quotaEntry), ttl: ttl}
}

func (q *quotaCache) get(tok string) (bool, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	e, ok := q.m[tok]
	if !ok || time.Now().After(e.exp) {
		return false, false
	}
	return e.allowed, true
}

func (q *quotaCache) put(tok string, allowed bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.m[tok] = quotaEntry{allowed: allowed, exp: time.Now().Add(q.ttl)}
	// Opportunistic bound: drop expired entries when the map grows.
	if len(q.m) > 4096 {
		now := time.Now()
		for k, e := range q.m {
			if now.After(e.exp) {
				delete(q.m, k)
			}
		}
	}
}

type server struct {
	cfg    config
	http   *http.Client
	quota  *quotaCache
	sem    chan struct{}
}

func newServer(cfg config) *server {
	return &server{
		cfg:   cfg,
		http:  &http.Client{Timeout: 30 * time.Second},
		quota: newQuotaCache(30 * time.Second),
		sem:   make(chan struct{}, cfg.maxConcurrent),
	}
}

// checkQuota mirrors fula-cli's check_can_upload: GET /api/v1/storage with the
// user's Bearer token => {canUpload}. mode=open fails open (gateway parity);
// mode=strict denies whenever a positive canUpload cannot be obtained.
func (s *server) checkQuota(token string) (bool, string) {
	if s.cfg.storageAPIURL == "" {
		if s.cfg.quotaStrict {
			return false, "quota strict mode but no STORAGE_API_URL configured"
		}
		return true, ""
	}
	if allowed, ok := s.quota.get(token); ok {
		if !allowed {
			return false, "quota exceeded (cached)"
		}
		return true, ""
	}
	req, _ := http.NewRequest(http.MethodGet, s.cfg.storageAPIURL+"/api/v1/storage", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := s.http.Do(req)
	if err != nil || resp.StatusCode != http.StatusOK {
		if resp != nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
		}
		if s.cfg.quotaStrict {
			return false, "quota check unavailable (strict mode denies)"
		}
		return true, "" // fail-open: gateway parity
	}
	defer resp.Body.Close()
	var st struct {
		CanUpload bool `json:"canUpload"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&st); err != nil {
		if s.cfg.quotaStrict {
			return false, "quota response unparseable (strict mode denies)"
		}
		return true, ""
	}
	s.quota.put(token, st.CanUpload)
	if !st.CanUpload {
		return false, "insufficient credits or quota exceeded"
	}
	return true, ""
}

// kuboBlockPut stores body via kubo block/put with blake3 raw addressing and
// returns the key kubo computed.
func (s *server) kuboBlockPut(ctx context.Context, body []byte) (string, error) {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	part, err := w.CreateFormFile("data", "blob")
	if err != nil {
		return "", err
	}
	if _, err := part.Write(body); err != nil {
		return "", err
	}
	w.Close()

	url := s.cfg.kuboAPI + "/api/v0/block/put?cid-codec=raw&mhtype=blake3&mhlen=32&pin=false"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, &buf)
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", w.FormDataContentType())
	resp, err := s.http.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("kubo block/put status %d: %s", resp.StatusCode, strings.TrimSpace(string(rb)))
	}
	var out struct {
		Key string `json:"Key"`
	}
	if err := json.Unmarshal(rb, &out); err != nil {
		return "", fmt.Errorf("kubo block/put bad response: %w", err)
	}
	return out.Key, nil
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func (s *server) handleBlockPut(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPut && r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "use PUT"})
		return
	}

	// Bounded concurrency — a thundering herd of chunks queues here instead of
	// exhausting kubo or memory.
	s.sem <- struct{}{}
	defer func() { <-s.sem }()

	declared := r.URL.Query().Get("cid")
	if declared == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing ?cid= (declared blake3 raw CID)"})
		return
	}
	declaredCid, err := cid.Decode(declared)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid cid: " + err.Error()})
		return
	}

	// Auth + S1 quota gate BEFORE reading the full body where possible.
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !s.cfg.noAuth {
		if token == "" || token == r.Header.Get("Authorization") {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "missing Bearer token"})
			return
		}
		if ok, reason := s.checkQuota(token); !ok {
			writeJSON(w, http.StatusPaymentRequired, map[string]string{"error": reason})
			return
		}
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, s.cfg.maxBlockBytes+1))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "read body: " + err.Error()})
		return
	}
	if int64(len(body)) > s.cfg.maxBlockBytes {
		writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": fmt.Sprintf("block exceeds %d bytes", s.cfg.maxBlockBytes)})
		return
	}
	if len(body) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "empty body"})
		return
	}

	// TAMPER-EVIDENCE: verify the declared CID over the received bytes BEFORE
	// anything touches the blockstore. A single flipped bit => 422, not stored.
	actual, err := computeBlake3RawCID(body)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "hash: " + err.Error()})
		return
	}
	if !actual.Equals(declaredCid) {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{
			"error":    "cid mismatch: body does not hash to the declared cid (tampered or corrupted)",
			"declared": declaredCid.String(),
			"actual":   actual.String(),
		})
		return
	}

	key, err := s.kuboBlockPut(r.Context(), body)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "kubo: " + err.Error()})
		return
	}
	// Belt and suspenders: kubo's independently computed key must agree.
	if kc, err := cid.Decode(key); err != nil || !kc.Equals(declaredCid) {
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "kubo key disagrees with declared cid", "kubo": key, "declared": declaredCid.String(),
		})
		return
	}

	writeJSON(w, http.StatusOK, map[string]any{"cid": declaredCid.String(), "size": len(body)})
}

func (s *server) handleHealth(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, s.cfg.kuboAPI+"/api/v0/id", nil)
	resp, err := s.http.Do(req)
	kubo := err == nil && resp.StatusCode == http.StatusOK
	if resp != nil {
		io.Copy(io.Discard, resp.Body)
		resp.Body.Close()
	}
	code := http.StatusOK
	if !kubo {
		code = http.StatusServiceUnavailable
	}
	writeJSON(w, code, map[string]any{"status": "ok", "kubo": kubo})
}

func main() {
	cfg := loadConfig()
	s := newServer(cfg)

	mux := http.NewServeMux()
	mux.HandleFunc("/v0/block", s.handleBlockPut)
	mux.HandleFunc("/health", s.handleHealth)

	srv := &http.Server{
		Addr:         cfg.bind + ":" + cfg.port,
		Handler:      mux,
		ReadTimeout:  60 * time.Second,
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	go func() {
		log.Printf("[fula-ingest] listening on %s (kubo=%s, quota=%s, max-block=%d, no-auth=%v)",
			srv.Addr, cfg.kuboAPI, map[bool]string{true: "strict", false: "open"}[cfg.quotaStrict], cfg.maxBlockBytes, cfg.noAuth)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[fula-ingest] server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	log.Printf("[fula-ingest] stopped")
}
