package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// StatsClient calls the read-only stats-api of each configured server.
type StatsClient struct {
	http    *http.Client
	servers map[string]GameServer
}

func NewStatsClient(servers map[string]GameServer) *StatsClient {
	return &StatsClient{http: &http.Client{Timeout: 10 * time.Second}, servers: servers}
}

// errNotFound is returned for a 404, which the stats API uses for an unknown
// player; the tools turn it into a plain answer rather than an error.
var errNotFound = errors.New("not found")

// maxStatsResponse bounds what one call can feed into the model's context.
const maxStatsResponse = 64 << 10

// Get fetches path (e.g. "/api/v1/players") with the query from the named
// server's stats API and returns the decoded JSON with the "$schema" link
// removed, since it is noise to the model.
func (c *StatsClient) Get(ctx context.Context, server, path string, query url.Values) (any, error) {
	gs, ok := c.servers[server]
	if !ok || gs.StatsAPIURL == "" {
		return nil, fmt.Errorf("no stats are available for server %q", server)
	}

	u := gs.StatsAPIURL + path
	if len(query) > 0 {
		u += "?" + query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("stats API unreachable: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxStatsResponse))
	if err != nil {
		return nil, fmt.Errorf("reading stats API response: %w", err)
	}
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return nil, errNotFound
	case resp.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("stats API returned %d: %s", resp.StatusCode, truncate(string(body), 300))
	}

	var decoded any
	if err := json.Unmarshal(body, &decoded); err != nil {
		return nil, fmt.Errorf("stats API returned invalid JSON: %w", err)
	}
	if obj, ok := decoded.(map[string]any); ok {
		delete(obj, "$schema")
	}
	return decoded, nil
}

// pageQuery builds the limit/offset query shared by the list endpoints.
func pageQuery(limit, offset int) url.Values {
	q := url.Values{}
	q.Set("limit", strconv.Itoa(limit))
	q.Set("offset", strconv.Itoa(offset))
	return q
}
