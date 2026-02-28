package main

import (
	"crypto/subtle"
	"encoding/json"
	"log"
	"net"
	"net/http"
	"strings"
)

type Server struct {
	daemon        *Daemon
	pairingSecret string
	mux           *http.ServeMux
}

func NewServer(daemon *Daemon, pairingSecret string) *Server {
	s := &Server{
		daemon:        daemon,
		pairingSecret: pairingSecret,
		mux:           http.NewServeMux(),
	}
	s.mux.HandleFunc("/api/v1/auto-pin/status", s.handleStatus)
	s.mux.HandleFunc("/api/v1/auto-pin/report-missing", s.handleReportMissing)
	return s
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mux.ServeHTTP(w, r)
}

func (s *Server) ListenAndServe(addr string) error {
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	log.Printf("server: listening on %s", addr)
	return http.Serve(listener, s)
}

func (s *Server) auth(r *http.Request) bool {
	authHeader := r.Header.Get("Authorization")
	if authHeader == "" {
		return false
	}
	parts := strings.SplitN(authHeader, " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(parts[1]), []byte(s.pairingSecret)) == 1
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "", http.StatusMethodNotAllowed)
		return
	}
	if !s.auth(r) {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	status := s.daemon.Status()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
}

type reportMissingRequest struct {
	CIDs []string `json:"cids"`
}

type reportMissingResponse struct {
	Queued int `json:"queued"`
}

func (s *Server) handleReportMissing(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "", http.StatusMethodNotAllowed)
		return
	}
	if !s.auth(r) {
		http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
		return
	}

	// Limit request body to 1MB
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20)

	var req reportMissingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, `{"error":"invalid request body"}`, http.StatusBadRequest)
		return
	}

	// Cap CIDs per request and validate format
	var validCIDs []string
	for _, cid := range req.CIDs {
		if len(validCIDs) >= 100 {
			break
		}
		if len(cid) >= 10 && len(cid) <= 200 && (strings.HasPrefix(cid, "baf") || strings.HasPrefix(cid, "Qm")) {
			validCIDs = append(validCIDs, cid)
		}
	}

	queued := s.daemon.QueuePriority(validCIDs)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(reportMissingResponse{Queued: queued})
}
