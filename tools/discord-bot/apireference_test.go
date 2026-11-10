package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"slices"
	"strings"
	"testing"
)

func TestAPIReferenceTool(t *testing.T) {
	t.Setenv("DISCORD_TOKEN", "x")
	t.Setenv("DISCORD_CHANNEL_ID", "1")
	t.Setenv("SERVERS", `[
		{"name":"main","stats_api_url":"http://internal","public_stats_api_url":"https://stats.example.com/"},
		{"name":"test","stats_api_url":"http://internal-test"}]`)
	cfg, err := ParseConfig()
	if err != nil {
		t.Fatal(err)
	}
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil)
	out, err := ts.Run(context.Background(), &toolContext{}, "api_reference", json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(out)
	s := string(encoded)
	for _, want := range []string{`"base_url":"https://stats.example.com"`, `"docs_url":"https://stats.example.com/docs"`, `"/api/v1/fire-support"`, "not publicly available"} {
		if !strings.Contains(s, want) {
			t.Errorf("reference missing %s", want)
		}
	}
	if strings.Contains(s, "internal") {
		t.Errorf("internal stats_api_url leaked into the reference: %s", s)
	}

	// No public URL anywhere: the tool is not offered.
	t.Setenv("SERVERS", `[{"name":"main","stats_api_url":"http://internal"}]`)
	cfg, _ = ParseConfig()
	if _, err := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil).Run(context.Background(), &toolContext{}, "api_reference", json.RawMessage(`{}`)); err == nil {
		t.Error("api_reference offered without any public URL")
	}

	for _, bad := range []string{"stats.example.com", "ftp://x", "https://x/?a=1"} {
		t.Setenv("SERVERS", `[{"name":"main","stats_api_url":"http://i","public_stats_api_url":"`+bad+`"}]`)
		if _, err := ParseConfig(); err == nil {
			t.Errorf("public URL %q accepted", bad)
		}
	}
}

// TestAPIReferenceMatchesSpec checks the hand-written reference against a
// running stats-api's OpenAPI spec, so the bot never hands out a path or
// parameter that doesn't exist (or misses a new one):
//
//	STATS_API_URL=http://localhost:8080 go test -run TestAPIReferenceMatchesSpec ./...
func TestAPIReferenceMatchesSpec(t *testing.T) {
	base := os.Getenv("STATS_API_URL")
	if base == "" {
		t.Skip("STATS_API_URL not set")
	}
	resp, err := http.Get(strings.TrimRight(base, "/") + "/openapi.json")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var spec struct {
		Paths map[string]map[string]struct {
			Parameters []struct {
				Name string `json:"name"`
				In   string `json:"in"`
			} `json:"parameters"`
		} `json:"paths"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&spec); err != nil {
		t.Fatal(err)
	}

	documented := map[string]bool{}
	for _, ep := range apiEndpoints {
		documented[ep.Path] = true
		op, ok := spec.Paths[ep.Path]["get"]
		if !ok {
			t.Errorf("reference lists %s, which the API does not serve", ep.Path)
			continue
		}
		var specParams, refParams []string
		for _, p := range op.Parameters {
			if p.In == "query" {
				specParams = append(specParams, p.Name)
			}
		}
		for _, p := range ep.Params {
			refParams = append(refParams, p.Name)
		}
		slices.Sort(specParams)
		slices.Sort(refParams)
		if !slices.Equal(specParams, refParams) {
			t.Errorf("%s query params: API has %v, reference has %v", ep.Path, specParams, refParams)
		}
	}
	for path := range spec.Paths {
		if strings.HasPrefix(path, "/api/") && !documented[path] {
			t.Errorf("API serves %s, which the reference does not list", path)
		}
	}
}
