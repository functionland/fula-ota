package main

import (
	"context"
	"log"
	"os"
	"path/filepath"
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
}

func NewDaemon(kubo *KuboClient, pinning *PinningClient, syncInterval time.Duration, registryCIDPath string) *Daemon {
	return &Daemon{
		kubo:            kubo,
		pinning:         pinning,
		pinnedCIDs:      make(map[string]bool),
		syncInterval:    syncInterval,
		priorityQueue:   make(chan string, 100),
		registryCIDPath: registryCIDPath,
	}
}

func (d *Daemon) Run(ctx context.Context) {
	log.Println("daemon: starting auto-pin daemon")

	// Wait for kubo to become healthy
	for !d.kubo.IsHealthy() {
		log.Println("daemon: waiting for kubo to become healthy...")
		select {
		case <-ctx.Done():
			return
		case <-time.After(10 * time.Second):
		}
	}
	log.Println("daemon: kubo is healthy")

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
	log.Println("daemon: starting sync cycle")
	startTime := time.Now()

	// Fetch remote pins from pinning service
	remotePins, err := d.pinning.ListAllPins()
	if err != nil {
		log.Printf("daemon: failed to fetch remote pins: %v", err)
		return
	}
	log.Printf("daemon: fetched %d remote pins", len(remotePins))

	// Find registry pin and write CID to shared file for fula-gateway
	for _, pin := range remotePins {
		if pin.Pin.Name == "fula-bucket-registry" && pin.Pin.CID != "" {
			d.writeRegistryCID(pin.Pin.CID)
			break
		}
	}

	// Fetch local pins from kubo
	localPins, err := d.kubo.PinLs()
	if err != nil {
		log.Printf("daemon: failed to fetch local pins: %v", err)
		return
	}

	// Update local cache
	d.pinnedMu.Lock()
	d.pinnedCIDs = localPins
	d.pinnedMu.Unlock()

	// Pin missing CIDs
	var pinned, skipped, failed int
	for _, pin := range remotePins {
		if ctx.Err() != nil {
			return
		}

		cid := pin.Pin.CID
		if cid == "" {
			continue
		}

		d.pinnedMu.RLock()
		alreadyPinned := d.pinnedCIDs[cid]
		d.pinnedMu.RUnlock()

		if alreadyPinned {
			skipped++
			continue
		}

		if err := d.kubo.PinAdd(cid); err != nil {
			log.Printf("daemon: failed to pin %s: %v", cid, err)
			failed++
			continue
		}

		d.pinnedMu.Lock()
		d.pinnedCIDs[cid] = true
		d.pinnedMu.Unlock()
		pinned++
	}

	d.lastSyncAt = time.Now()
	log.Printf("daemon: sync complete in %v — pinned=%d skipped=%d failed=%d",
		time.Since(startTime), pinned, skipped, failed)
}

func (d *Daemon) pinImmediately(ctx context.Context, cid string) {
	d.pinnedMu.RLock()
	alreadyPinned := d.pinnedCIDs[cid]
	d.pinnedMu.RUnlock()

	if alreadyPinned {
		return
	}

	log.Printf("daemon: priority pinning %s", cid)
	if err := d.kubo.PinAdd(cid); err != nil {
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
	d.pinnedMu.RUnlock()

	return DaemonStatus{
		Paired:       true,
		TotalPinned:  totalPinned,
		TotalPending: len(d.priorityQueue),
		LastSyncAt:   d.lastSyncAt,
		NextSyncAt:   d.lastSyncAt.Add(d.syncInterval),
	}
}

type DaemonStatus struct {
	Paired       bool      `json:"paired"`
	TotalPinned  int       `json:"total_pinned"`
	TotalPending int       `json:"total_pending"`
	LastSyncAt   time.Time `json:"last_sync_at"`
	NextSyncAt   time.Time `json:"next_sync_at"`
}
