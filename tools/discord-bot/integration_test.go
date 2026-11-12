package main

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// TestToolsAgainstStatsAPI runs the stats tools against a live stats-api,
// e.g. the tools/stats-api docker compose stack with its seed data:
//
//	STATS_API_URL=http://localhost:8080 go test -run TestToolsAgainstStatsAPI ./...
func TestToolsAgainstStatsAPI(t *testing.T) {
	base := os.Getenv("STATS_API_URL")
	if base == "" {
		t.Skip("STATS_API_URL not set")
	}
	t.Setenv("DISCORD_TOKEN", "x")
	t.Setenv("ANTHROPIC_API_KEY", "test")
	t.Setenv("DISCORD_CHANNEL_ID", "1")
	t.Setenv("SERVERS", `[{"name":"main","stats_api_url":"`+base+`"}]`)
	cfg, err := ParseConfig()
	if err != nil {
		t.Fatal(err)
	}
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, nil)

	calls := []struct {
		tool, input, want string
		wantErr           bool
	}{
		{"find_players", `{"name":"alpha"}`, "TestPlayerAlpha", false},
		{"get_player", `{"steam_id":"76561198000000001"}`, `"kills_by_weapon"`, false},
		{"get_player", `{"steam_id":"76561198999999999"}`, `"found":false`, false},
		{"get_player", `{"steam_id":"123"}`, "", true},
		{"leaderboard", `{"board":"players","sort":"kd","limit":2}`, `"limit":2`, false},
		{"leaderboard", `{"board":"maps","sort":"play_time"}`, "play_time_seconds", false},
		{"leaderboard", `{"board":"weapons","sort":"kd"}`, "", true},
		{"leaderboard", `{"board":"fire_support"}`, "arty_thrown", false},
		{"leaderboard", `{"board":"players","sort":"kills","period":"30d"}`, `"history_since"`, false},
		{"leaderboard", `{"board":"medics","sort":"revives","period":"30d"}`, `"revives"`, false},
		{"leaderboard", `{"board":"teamkills","since":"2026-01-01"}`, `"window"`, false},
		{"leaderboard", `{"board":"maps","period":"30d"}`, "", true}, // maps have no history
		{"leaderboard", `{"board":"players","period":"thirty"}`, "", true},
		{"get_player", `{"steam_id":"76561198000000001","period":"30d"}`, `"window"`, false},
		{"weapon_accuracy", `{"weapon":"m16a4","period":"60d"}`, `"enemy_hit_rate"`, false},
		{"weapon_accuracy", `{"weapon":"nope"}`, "", true},
		{"recent_matches", `{"limit":3}`, "played_at", false},
		{"get_bot_weapons", `{"bot_name":"Bot Adams"}`, "kill_count", false},
		{"find_players", `{"name":"x","bogus":1}`, "", true},
		{"server_status", `{"server":"all"}`, "", true}, // not offered: no query address
	}
	for _, c := range calls {
		t.Run(c.tool+" "+c.input, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			out, err := ts.Run(ctx, &toolContext{}, c.tool, json.RawMessage(c.input))
			if c.wantErr {
				if err == nil {
					t.Fatalf("expected an error, got %v", out)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			encoded, _ := json.Marshal(out)
			if !strings.Contains(string(encoded), c.want) {
				t.Errorf("result does not contain %q: %s", c.want, encoded)
			}
			if strings.Contains(string(encoded), "$schema") {
				t.Errorf("$schema not stripped: %s", encoded)
			}
		})
	}
}

// TestQueryServerLive queries a real game server: A2S_ADDR=host:port.
func TestQueryServerLive(t *testing.T) {
	addr := os.Getenv("A2S_ADDR")
	if addr == "" {
		t.Skip("A2S_ADDR not set")
	}
	status := QueryServer("live", addr, 3*time.Second)
	encoded, _ := json.MarshalIndent(status, "", "  ")
	t.Logf("%s", encoded)
	if !status.Online {
		t.Fatalf("server did not answer: %s", status.Error)
	}
}
