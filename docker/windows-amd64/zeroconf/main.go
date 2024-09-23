package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/grandcat/zeroconf"
)

type DeviceInfo struct {
	IP   string `json:"ip"`
	Port int    `json:"port"`
}

func main() {
	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to initialize resolver: %v\n", err)
		os.Exit(1)
	}

	entries := make(chan *zeroconf.ServiceEntry)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second*5)
	defer cancel()

	err = resolver.Browse(ctx, "_fulatower._tcp", "local.", entries)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to browse: %v\n", err)
		os.Exit(1)
	}

	var device DeviceInfo

	select {
	case entry := <-entries:
		if len(entry.AddrIPv4) > 0 {
			device.IP = entry.AddrIPv4[0].String()
			device.Port = entry.Port
		}
	case <-ctx.Done():
		if ctx.Err() == context.DeadlineExceeded {
			fmt.Fprintf(os.Stderr, "No device found within timeout\n")
			os.Exit(1)
		}
	}

	if device.IP != "" {
		jsonData, err := json.Marshal(device)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Failed to marshal device info: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(string(jsonData))
	} else {
		fmt.Fprintf(os.Stderr, "No device found\n")
		os.Exit(1)
	}
}
