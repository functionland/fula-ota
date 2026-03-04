package main

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type Daemon struct {
	kubo            *KuboClient
	pinning         *PinningClient
	pinnedCIDs      map[string]bool
	pinnedMu        sync.RWMutex
	syncInterval    time.Duration
	priorityQueue   chan string
	lastSyncAt      time.Time
	registryCIDPath string
	lastSyncFile    string
	syncCycle       int
}

func NewDaemon(kubo *KuboClient, pinning *PinningClient, syncInterval time.Duration, registryCIDPath, lastSyncFile string) *Daemon {
	d := &Daemon{
		kubo:            kubo,
		pinning:         pinning,
		pinnedCIDs:      make(map[string]bool),
		syncInterval:    syncInterval,
		priorityQueue:   make(chan string, 100),
		registryCIDPath: registryCIDPath,
		lastSyncFile:    lastSyncFile,
	}
	d.loadLastSync()
	return d
}

func (d *Daemon) Run(ctx context.Context) {
	log.Println("daemon: starting auto-pin daemon")

	// Wait for kubo to become healthy
	for !d.kubo.IsHealthy(ctx) {
		log.Println("daemon: waiting for kubo to become healthy...")
		select {
		case <-ctx.Done():
			return
		case <-time.After(10 * time.Second):
		}
	}
	log.Println("daemon: kubo is healthy")

	// Detect kubo instance reset: if we think we've synced before but kubo
	// has zero pins, the kubo instance was likely replaced (e.g. switched
	// from main kubo to kubo-local). Force a full sync to re-pin everything.
	if !d.lastSyncAt.IsZero() {
		localPins, err := d.kubo.PinLs(ctx)
		if err == nil && len(localPins) == 0 {
			log.Println("daemon: kubo has 0 pins but lastSyncAt is set — kubo instance was likely reset. Forcing full sync.")
			d.pinnedMu.Lock()
			d.lastSyncAt = time.Time{}
			d.pinnedMu.Unlock()
		}
	}

	// Initial sync
	d.syncPins(ctx)

	ticker := time.NewTicker(d.syncInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			d.syncPins(ctx)
		case cid := <-d.priorityQueue:
			d.pinImmediately(ctx, cid)
		case <-ctx.Done():
			log.Println("daemon: shutting down")
			return
		}
	}
}

func (d *Daemon) syncPins(ctx context.Context) {
	d.syncCycle++
	startTime := time.Now()

	// Signal to go-fula that we are actively syncing pins
	syncingPath := "/internal/fula-pinning/.syncing"
	_ = os.MkdirAll(filepath.Dir(syncingPath), 0755)
	_ = os.WriteFile(syncingPath, []byte(time.Now().Format(time.RFC3339)), 0644)
	defer os.Remove(syncingPath)

	// Every 10th cycle, force a full sync to catch any missed pins
	forceFullSync := d.syncCycle%10 == 0
	incremental := !d.lastSyncAt.IsZero() && !forceFullSync

	log.Printf("daemon: starting sync cycle #%d (incremental=%v)", d.syncCycle, incremental)

	var remotePins []PinEntry
	var err error
	if incremental {
		// Subtract 1 minute for clock skew safety
		since := d.lastSyncAt.Add(-1 * time.Minute)
		remotePins, err = d.pinning.ListPinsSince(since)
		if err != nil {
			log.Printf("daemon: incremental fetch failed: %v, trying full sync", err)
			remotePins, err = d.pinning.ListAllPins()
			incremental = false
		}
	} else {
		remotePins, err = d.pinning.ListAllPins()
	}
	if err != nil {
		log.Printf("daemon: failed to fetch remote pins: %v", err)
		return
	}
	log.Printf("daemon: fetched %d remote pins (incremental=%v)", len(remotePins), incremental)

	// Find registry pin and write CID to shared file for fula-gateway
	for _, pin := range remotePins {
		if pin.Pin.Name == "fula-bucket-registry" && pin.Pin.CID != "" {
			d.writeRegistryCID(pin.Pin.CID)
			break
		}
	}

	// Fetch local pins from kubo
	localPins, err := d.kubo.PinLs(ctx)
	if err != nil {
		log.Printf("daemon: failed to fetch local pins: %v", err)
		return
	}

	// Update local cache
	d.pinnedMu.Lock()
	d.pinnedCIDs = localPins
	d.pinnedMu.Unlock()

	// Pin missing CIDs
	total := len(remotePins)
	var pinned, skipped, failed, processed int
	for _, pin := range remotePins {
		if ctx.Err() != nil {
			return
		}

		cid := pin.Pin.CID
		if cid == "" {
			continue
		}

		processed++

		d.pinnedMu.RLock()
		alreadyPinned := d.pinnedCIDs[cid]
		d.pinnedMu.RUnlock()

		if alreadyPinned {
			skipped++
			continue
		}

		if err := d.kubo.PinAdd(ctx, cid); err != nil {
			log.Printf("daemon: failed to pin %s: %v", cid, err)
			failed++
			continue
		}

		d.pinnedMu.Lock()
		d.pinnedCIDs[cid] = true
		d.pinnedMu.Unlock()
		pinned++

		// Log progress every 50 pins
		if pinned%50 == 0 {
			log.Printf("daemon: progress %d/%d — pinned=%d skipped=%d failed=%d elapsed=%v",
				processed, total, pinned, skipped, failed, time.Since(startTime))
		}
	}

	d.pinnedMu.Lock()
	d.lastSyncAt = startTime
	d.pinnedMu.Unlock()
	d.persistLastSync()
	log.Printf("daemon: sync complete in %v — pinned=%d skipped=%d failed=%d",
		time.Since(startTime), pinned, skipped, failed)
}

func (d *Daemon) loadLastSync() {
	if d.lastSyncFile == "" {
		return
	}
	data, err := os.ReadFile(d.lastSyncFile)
	if err != nil {
		return
	}
	t, err := time.Parse(time.RFC3339, strings.TrimSpace(string(data)))
	if err != nil {
		return
	}
	d.lastSyncAt = t
	log.Printf("daemon: loaded lastSyncAt=%s from %s", t.Format(time.RFC3339), d.lastSyncFile)
}

func (d *Daemon) persistLastSync() {
	if d.lastSyncFile == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(d.lastSyncFile), 0755); err != nil {
		log.Printf("daemon: failed to create lastSync dir: %v", err)
		return
	}
	tmpPath := d.lastSyncFile + ".tmp"
	if err := os.WriteFile(tmpPath, []byte(d.lastSyncAt.Format(time.RFC3339)+"\n"), 0644); err != nil {
		log.Printf("daemon: failed to write lastSyncAt to %s: %v", tmpPath, err)
		return
	}
	if err := os.Rename(tmpPath, d.lastSyncFile); err != nil {
		log.Printf("daemon: failed to rename %s to %s: %v", tmpPath, d.lastSyncFile, err)
	}
}

func (d *Daemon) pinImmediately(ctx context.Context, cid string) {
	d.pinnedMu.RLock()
	alreadyPinned := d.pinnedCIDs[cid]
	d.pinnedMu.RUnlock()

	if alreadyPinned {
		return
	}

	log.Printf("daemon: priority pinning %s", cid)
	if err := d.kubo.PinAdd(ctx, cid); err != nil {
		log.Printf("daemon: failed to priority pin %s: %v", cid, err)
		return
	}

	d.pinnedMu.Lock()
	d.pinnedCIDs[cid] = true
	d.pinnedMu.Unlock()
}

// writeRegistryCID atomically writes the registry CID to the shared file.
func (d *Daemon) writeRegistryCID(cid string) {
	if d.registryCIDPath == "" {
		return
	}

	// Ensure parent directory exists
	dir := filepath.Dir(d.registryCIDPath)
	if err := os.MkdirAll(dir, 0755); err != nil {
		log.Printf("daemon: failed to create registry CID directory %s: %v", dir, err)
		return
	}

	// Atomic write: write to .tmp then rename
	tmpPath := d.registryCIDPath + ".tmp"
	if err := os.WriteFile(tmpPath, []byte(cid+"\n"), 0644); err != nil {
		log.Printf("daemon: failed to write registry CID to %s: %v", tmpPath, err)
		return
	}
	if err := os.Rename(tmpPath, d.registryCIDPath); err != nil {
		log.Printf("daemon: failed to rename %s to %s: %v", tmpPath, d.registryCIDPath, err)
		return
	}

	log.Printf("daemon: wrote registry CID %s to %s", cid, d.registryCIDPath)
}

// QueuePriority adds CIDs to the priority pin queue.
func (d *Daemon) QueuePriority(cids []string) int {
	queued := 0
	for _, cid := range cids {
		select {
		case d.priorityQueue <- cid:
			queued++
		default:
			log.Printf("daemon: priority queue full, dropping %s", cid)
		}
	}
	return queued
}

// Status returns current daemon status info.
func (d *Daemon) Status() DaemonStatus {
	d.pinnedMu.RLock()
	totalPinned := len(d.pinnedCIDs)
	lastSync := d.lastSyncAt
	d.pinnedMu.RUnlock()

	return DaemonStatus{
		Paired:       true,
		TotalPinned:  totalPinned,
		TotalPending: len(d.priorityQueue),
		LastSyncAt:   lastSync,
		NextSyncAt:   lastSync.Add(d.syncInterval),
	}
}

type DaemonStatus struct {
	Paired       bool      `json:"paired"`
	TotalPinned  int       `json:"total_pinned"`
	TotalPending int       `json:"total_pending"`
	LastSyncAt   time.Time `json:"last_sync_at"`
	NextSyncAt   time.Time `json:"next_sync_at"`
}
