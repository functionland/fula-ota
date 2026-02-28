package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

type PinningClient struct {
	endpoint string
	token    string
	client   *http.Client
}

type PinEntry struct {
	RequestID string `json:"requestid"`
	Status    string `json:"status"`
	Pin       struct {
		CID  string `json:"cid"`
		Name string `json:"name"`
	} `json:"pin"`
	Created string `json:"created"`
}

type PinListResponse struct {
	Count   int        `json:"count"`
	Results []PinEntry `json:"results"`
}

func NewPinningClient(endpoint, token string) *PinningClient {
	return &PinningClient{
		endpoint: endpoint,
		token:    token,
		client:   &http.Client{Timeout: 30 * time.Second},
	}
}

// ListAllPins fetches all pins from the pinning service, paginating as needed.
func (p *PinningClient) ListAllPins() ([]PinEntry, error) {
	var allPins []PinEntry
	limit := 1000
	before := ""

	for {
		pins, err := p.listPins(limit, before)
		if err != nil {
			return allPins, err
		}
		allPins = append(allPins, pins.Results...)

		if len(pins.Results) < limit {
			break // no more pages
		}
		// Use the created timestamp of the last result for pagination
		last := pins.Results[len(pins.Results)-1]
		before = last.Created
	}

	return allPins, nil
}

func (p *PinningClient) listPins(limit int, before string) (*PinListResponse, error) {
	u, err := url.Parse(fmt.Sprintf("%s/pins", p.endpoint))
	if err != nil {
		return nil, fmt.Errorf("invalid pinning endpoint: %w", err)
	}

	q := u.Query()
	q.Set("limit", fmt.Sprintf("%d", limit))
	if before != "" {
		q.Set("before", before)
	}
	u.RawQuery = q.Encode()

	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+p.token)

	resp, err := p.client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("pinning list: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("pinning list: status %d: %s", resp.StatusCode, string(body))
	}

	var result PinListResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("pinning list decode: %w", err)
	}
	return &result, nil
}
