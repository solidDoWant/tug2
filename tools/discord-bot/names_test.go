package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

func TestNameCandidates(t *testing.T) {
	for _, c := range []struct {
		display string
		want    []string
	}{
		{"TestPlayerAlpha", []string{"TestPlayerAlpha"}},
		{"discordalpha [Test Player Beta]", []string{"discordalpha [Test Player Beta]", "discordalpha", "Test Player Beta"}},
		{"[TAG] TestPlayerGamma", []string{"[TAG] TestPlayerGamma", "TestPlayerGamma", "TAG"}},
		{"alpha (beta) {gamma}", []string{"alpha (beta) {gamma}", "alpha", "beta", "gamma"}},
		{"alpha | Beta Delta", []string{"alpha | Beta Delta", "alpha", "Beta Delta"}},
		{"alpha [ALPHA]", []string{"alpha [ALPHA]", "alpha"}}, // same name twice
		{"alpha [x] []", []string{"alpha [x] []", "alpha"}},   // fragments too short
		{"[[TestPlayerAlpha]]", []string{"[[TestPlayerAlpha]]", "TestPlayerAlpha"}},
		{"  ", nil},
		{"a [b] [c] [d] [e] [f] [g]", []string{"a [b] [c] [d] [e] [f] [g]"}},
		{"aa [bb] [cc] [dd] [ee] [ff] [gg]", []string{"aa [bb] [cc] [dd] [ee] [ff] [gg]", "aa", "bb", "cc", "dd"}},
	} {
		if got := nameCandidates(c.display); !reflect.DeepEqual(got, c.want) {
			t.Errorf("nameCandidates(%q) = %q, want %q", c.display, got, c.want)
		}
	}
}

// fakeStats serves /api/v1/players?name= from a fixed player list, matching
// like the real API (case-insensitive substring).
func fakeStats(t *testing.T, players map[string]string, searched *[]string) *StatsClient {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		*searched = append(*searched, name)
		items := []map[string]any{}
		for id, n := range players {
			if strings.Contains(strings.ToLower(n), strings.ToLower(name)) {
				items = append(items, map[string]any{"steam_id": id, "name": n})
			}
		}
		json.NewEncoder(w).Encode(map[string]any{"items": items, "total": len(items)})
	}))
	t.Cleanup(srv.Close)
	return NewStatsClient(map[string]GameServer{"main": {Name: "main", StatsAPIURL: srv.URL}})
}

func TestFindPlayersMe(t *testing.T) {
	var searched []string
	stats := fakeStats(t, map[string]string{
		"76561198000000001": "Test Player Beta",
		"76561198000000002": "[TAG] TestPlayerGamma",
	}, &searched)
	cfg := &Config{Servers: map[string]GameServer{"main": {Name: "main", StatsAPIURL: "unused"}}, ServerOrder: []string{"main"}}
	ts := NewToolset(cfg, stats, nil, nil)
	run := func(asker, input string) (any, error) {
		searched = nil
		return ts.Run(context.Background(), &toolContext{asker: asker}, "find_players", json.RawMessage(input))
	}

	out, err := run("discordalpha [Test Player Beta]", `{"me":true}`)
	if err != nil {
		t.Fatal(err)
	}
	res := out.(*nameMatches)
	if len(res.Players) != 1 || res.Players[0]["steam_id"] != "76561198000000001" ||
		!reflect.DeepEqual(res.Players[0]["matched_by"], []string{"Test Player Beta"}) {
		t.Errorf("players = %v", res.Players)
	}
	if !reflect.DeepEqual(searched, []string{"discordalpha [Test Player Beta]", "discordalpha", "Test Player Beta"}) {
		t.Errorf("searched %q", searched)
	}

	// A player found by more than one part is listed once.
	out, err = run("[TAG] TestPlayerGamma", `{"me":true}`)
	if err != nil {
		t.Fatal(err)
	}
	res = out.(*nameMatches)
	if len(res.Players) != 1 || len(res.Players[0]["matched_by"].([]string)) != 3 {
		t.Errorf("players = %v", res.Players)
	}

	// A plain name search is unchanged.
	if _, err := run("whoever", `{"name":"Beta"}`); err != nil || !reflect.DeepEqual(searched, []string{"Beta"}) {
		t.Errorf("name search: %v, searched %q", err, searched)
	}

	for _, c := range []struct{ asker, input string }{
		{"discordalpha", `{"me":true,"name":"x"}`},
		{"", `{"me":true}`},
		{"x", `{"me":true}`},
		{"discordalpha", `{}`},
		{"discordalpha", `{"name":"  "}`},
	} {
		if _, err := run(c.asker, c.input); err == nil {
			t.Errorf("%q %s: no error", c.asker, c.input)
		}
	}
}
