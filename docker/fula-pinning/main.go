package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

func main() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
	log.Println("fula-pinning: starting")

	cfg := LoadConfig()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Graceful shutdown on SIGINT/SIGTERM
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Printf("fula-pinning: received %s, shutting down", sig)
		cancel()
	}()

	// Main loop: watch for config changes (pair/unpair)
	runWithConfig(ctx, cfg)
}

func runWithConfig(ctx context.Context, cfg *Config) {
	var cleanup func()

	startDaemon := func() func() {
		if !cfg.IsPaired() {
			log.Println("fula-pinning: not paired, waiting for config...")
			return nil
		}

		log.Println("fula-pinning: paired, starting daemon and server")
		dctx, dcancel := context.WithCancel(ctx)

		kubo := NewKuboClient(cfg.KuboAPI)
		pinning := NewPinningClient(cfg.PinningEndpoint, cfg.PinningToken)
		daemon := NewDaemon(kubo, pinning, cfg.SyncInterval, cfg.RegistryCIDPath, cfg.LastSyncFile)
		appServer := NewServer(daemon, cfg.PairingSecret)

		addr := "0.0.0.0:" + cfg.AutoPinPort
		httpServer := &http.Server{Addr: addr, Handler: appServer}

		var wg sync.WaitGroup

		wg.Add(1)
		go func() {
			defer wg.Done()
			daemon.Run(dctx)
		}()

		wg.Add(1)
		go func() {
			defer wg.Done()
			log.Printf("server: listening on %s", addr)
			if err := httpServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
				log.Printf("server error: %v", err)
			}
		}()

		return func() {
			dcancel()
			shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer shutdownCancel()
			if err := httpServer.Shutdown(shutdownCtx); err != nil {
				log.Printf("server shutdown error: %v", err)
			}
			wg.Wait()
		}
	}

	cleanup = startDaemon()

	// Poll config file for changes (pair/unpair/token refresh)
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			oldPaired := cfg.IsPaired()
			oldToken := cfg.PinningToken
			cfg.loadProps()
			newPaired := cfg.IsPaired()

			if oldPaired != newPaired || oldToken != cfg.PinningToken {
				log.Printf("fula-pinning: config changed (paired: %v → %v)", oldPaired, newPaired)
				if cleanup != nil {
					cleanup()
				}
				cleanup = startDaemon()
			}
		case <-ctx.Done():
			if cleanup != nil {
				cleanup()
			}
			return
		}
	}
}
