package main

import (
	"context"
	"log"
	"os"
	"os/signal"
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
	var daemonCancel context.CancelFunc

	startDaemon := func() context.CancelFunc {
		if !cfg.IsPaired() {
			log.Println("fula-pinning: not paired, waiting for config...")
			return nil
		}

		log.Println("fula-pinning: paired, starting daemon and server")
		dctx, dcancel := context.WithCancel(ctx)

		kubo := NewKuboClient(cfg.KuboAPI)
		pinning := NewPinningClient(cfg.PinningEndpoint, cfg.PinningToken)
		daemon := NewDaemon(kubo, pinning, cfg.SyncInterval, cfg.RegistryCIDPath)
		server := NewServer(daemon, cfg.PairingSecret)

		go daemon.Run(dctx)
		go func() {
			addr := "0.0.0.0:" + cfg.AutoPinPort
			if err := server.ListenAndServe(addr); err != nil {
				log.Printf("server error: %v", err)
			}
		}()

		return dcancel
	}

	daemonCancel = startDaemon()

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
				if daemonCancel != nil {
					daemonCancel()
				}
				daemonCancel = startDaemon()
			}
		case <-ctx.Done():
			if daemonCancel != nil {
				daemonCancel()
			}
			return
		}
	}
}
