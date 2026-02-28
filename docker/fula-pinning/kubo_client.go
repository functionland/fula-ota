package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"time"
)

type KuboClient struct {
	apiURL string
	client *http.Client
}

func NewKuboClient(apiURL string) *KuboClient {
	return &KuboClient{
		apiURL: apiURL,
		client: &http.Client{Timeout: 120 * time.Second},
	}
}

// PinAdd pins a CID recursively on the local kubo node.
func (k *KuboClient) PinAdd(cid string) error {
	u := fmt.Sprintf("%s/api/v0/pin/add?arg=%s&recursive=true", k.apiURL, url.QueryEscape(cid))
	resp, err := k.client.Post(u, "", nil)
	if err != nil {
		return fmt.Errorf("kubo pin/add %s: %w", cid, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("kubo pin/add %s: status %d: %s", cid, resp.StatusCode, string(body))
	}
	return nil
}

type pinLsKey struct {
	Type string `json:"Type"`
}

// PinLs returns the set of recursively pinned CIDs.
func (k *KuboClient) PinLs() (map[string]bool, error) {
	u := fmt.Sprintf("%s/api/v0/pin/ls?type=recursive", k.apiURL)
	resp, err := k.client.Post(u, "", nil)
	if err != nil {
		return nil, fmt.Errorf("kubo pin/ls: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("kubo pin/ls: status %d: %s", resp.StatusCode, string(body))
	}

	var result struct {
		Keys map[string]pinLsKey `json:"Keys"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("kubo pin/ls decode: %w", err)
	}

	pinned := make(map[string]bool, len(result.Keys))
	for cid := range result.Keys {
		pinned[cid] = true
	}
	return pinned, nil
}

// IsHealthy checks if the kubo API is reachable.
func (k *KuboClient) IsHealthy() bool {
	u := fmt.Sprintf("%s/api/v0/id", k.apiURL)
	resp, err := k.client.Post(u, "", nil)
	if err != nil {
		log.Printf("kubo health check failed: %v", err)
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
