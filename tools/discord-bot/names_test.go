package main

import (
	"context"
	"encoding/json"
	"maps"
	"net/http"
	"net/http/httptest"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"
	"unicode"
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

// fakeStats serves /api/v1/players?name=&name_match=fuzzy from a fixed player
// list, roughly like the real API: exact and substring case-insensitively,
// normalised ignoring everything but letters and digits. It checks the bot
// asks for the fuzzy match.
func fakeStats(t *testing.T, players map[string]string, searched *[]string) *StatsClient {
	t.Helper()
	norm := func(s string) string {
		return strings.Map(func(r rune) rune {
			if unicode.IsLetter(r) || unicode.IsDigit(r) {
				return unicode.ToLower(r)
			}
			return -1
		}, s)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		if r.URL.Query().Get("name_match") != "fuzzy" {
			t.Errorf("search for %q is not fuzzy", name)
		}
		*searched = append(*searched, name)
		ids := slices.Sorted(maps.Keys(players))
		items := []map[string]any{}
		for _, id := range ids {
			n := players[id]
			kind := ""
			switch {
			case strings.EqualFold(n, name):
				kind = "exact"
			case strings.Contains(strings.ToLower(n), strings.ToLower(name)):
				kind = "substring"
			case norm(name) != "" && strings.Contains(norm(n), norm(name)):
				kind = "normalised"
			default:
				continue
			}
			items = append(items, map[string]any{"steam_id": id, "name": n, "name_match": kind})
		}
		total := len(items)
		if len(items) > 2 {
			items = items[:2] // pretend the page is short, to see more_matches
		}
		json.NewEncoder(w).Encode(map[string]any{"items": items, "total": total})
	}))
	t.Cleanup(srv.Close)
	return NewStatsClient(map[string]GameServer{"main": {Name: "main", StatsAPIURL: srv.URL}})
}

func TestMatchRank(t *testing.T) {
	if matchRank("exact") != 0 || matchRank("loose") != 3 || matchRank("bogus") != 4 {
		t.Error("ranks out of order")
	}
	// An older stats API leaves name_match out of a plain substring search.
	if matchRank(nil) != matchRank("substring") {
		t.Error("a missing name_match is not a substring match")
	}
}

func TestFindPlayersConfidence(t *testing.T) {
	var searched []string
	stats := fakeStats(t, map[string]string{
		"76561198000000001": "Jane Doe",
		"76561198000000002": "JaneDoeFan",
		"76561198000000003": "J_Smith",
		"76561198000000004": "J.Smith",
		"76561198000000005": "TestPlayerAlpha",
		"76561198000000006": "TestPlayerBravo",
		"76561198000000007": "TestPlayerCharlie",
	}, &searched)
	cfg := &Config{Servers: map[string]GameServer{"main": {Name: "main", StatsAPIURL: "unused"}}, ServerOrder: []string{"main"}}
	ts := NewToolset(cfg, stats, nil, nil, nil)

	for _, c := range []struct {
		name, confidence string
		first            string // the best match's name
		more             bool
	}{
		{"jane doe", confidenceExact, "Jane Doe", false},
		{"Alpha", confidenceClear, "TestPlayerAlpha", false},
		{"jane-doe", confidenceLow, "Jane Doe", false}, // only normalised matches
		// JaneDoeFan contains it, but Jane Doe is the same name but for the space.
		{"janedoe", confidenceAmbiguous, "JaneDoeFan", false},
		{"J Smith", confidenceLow, "J_Smith", false},
		{"Smith", confidenceAmbiguous, "J_Smith", false},
		{"TestPlayer", confidenceAmbiguous, "TestPlayerAlpha", true},
		{"Nobody", confidenceNone, "", false},
	} {
		out, err := ts.Run(context.Background(), &toolContext{asker: "whoever"}, "find_players", json.RawMessage(`{"name":`+strconv.Quote(c.name)+`}`))
		if err != nil {
			t.Fatalf("%q: %v", c.name, err)
		}
		res := out.(*nameMatches)
		first := ""
		if len(res.Players) > 0 {
			first, _ = res.Players[0]["name"].(string)
		}
		if res.Confidence != c.confidence || first != c.first || res.More != c.more || res.Advice == "" {
			t.Errorf("%q: confidence %q, first %q, more %v, advice %q; want %q, %q, %v",
				c.name, res.Confidence, first, res.More, res.Advice, c.confidence, c.first, c.more)
		}
		if (c.confidence == confidenceLow || c.confidence == confidenceAmbiguous) && !strings.Contains(res.Advice, "ask the user which one") {
			t.Errorf("%q: advice doesn't say to ask: %q", c.name, res.Advice)
		}
	}
}

func TestFindPlayersMe(t *testing.T) {
	var searched []string
	stats := fakeStats(t, map[string]string{
		"76561198000000001": "Test Player Beta",
		"76561198000000002": "[TAG] TestPlayerGamma",
	}, &searched)
	cfg := &Config{Servers: map[string]GameServer{"main": {Name: "main", StatsAPIURL: "unused"}}, ServerOrder: []string{"main"}}
	ts := NewToolset(cfg, stats, nil, nil, nil)
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

	if res.Confidence != confidenceExact {
		t.Errorf("confidence = %q", res.Confidence)
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
