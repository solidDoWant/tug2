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

// normName is roughly the database's normalised form, for the fakes.
func normName(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			return unicode.ToLower(r)
		}
		return -1
	}, s)
}

// fakeStats serves /api/v1/players?name= from a fixed player list like the
// real API: a case-insensitive substring match.
func fakeStats(t *testing.T, players map[string]string, searched *[]string) *StatsClient {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		if r.URL.Query().Has("name_match") {
			t.Errorf("search for %q sends name_match, which the API doesn't have", name)
		}
		*searched = append(*searched, name)
		items := []map[string]any{}
		for _, id := range slices.Sorted(maps.Keys(players)) {
			if n := players[id]; strings.Contains(strings.ToLower(n), strings.ToLower(name)) {
				items = append(items, map[string]any{"steam_id": id, "name": n})
			}
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

// fakeNameDB is a statsDB whose FindPlayers ranks a fixed player list roughly
// like findPlayersSQL (TestPostgresFindPlayers checks the real one).
type fakeNameDB struct {
	fakeStatsDB
	players  map[string]string
	searched []string
	schema   string
}

func (f *fakeNameDB) FindPlayers(_ context.Context, schema, name string) ([]PlayerMatch, int, error) {
	f.searched = append(f.searched, name)
	f.schema = schema
	var out []PlayerMatch
	for _, id := range slices.Sorted(maps.Keys(f.players)) {
		n := f.players[id]
		kind := ""
		switch {
		case strings.EqualFold(n, name):
			kind = "exact"
		case strings.Contains(strings.ToLower(n), strings.ToLower(name)):
			kind = "substring"
		case normName(name) != "" && strings.Contains(normName(n), normName(name)):
			kind = "normalised"
		default:
			continue
		}
		out = append(out, PlayerMatch{SteamID: id, Name: n, NameMatch: kind})
	}
	slices.SortStableFunc(out, func(a, b PlayerMatch) int { return matchRank(a.NameMatch) - matchRank(b.NameMatch) })
	total := len(out)
	if len(out) > 2 {
		out = out[:2] // pretend the page is short, to see more_matches
	}
	return out, total, nil
}

// nameTestConfig is one server with a stats database schema.
func nameTestConfig() *Config {
	return &Config{
		StatsDBURL:  "postgres:///",
		Servers:     map[string]GameServer{"main": {Name: "main", StatsAPIURL: "unused", StatsDBSchema: "public"}},
		ServerOrder: []string{"main"},
	}
}

func TestMatchRank(t *testing.T) {
	if matchRank("exact") != 0 || matchRank("loose") != 3 || matchRank("bogus") != 4 || matchRank(nil) != 4 {
		t.Error("ranks out of order")
	}
}

func TestFindPlayersConfidence(t *testing.T) {
	db := &fakeNameDB{players: map[string]string{
		"76561198000000001": "Jane Doe",
		"76561198000000002": "JaneDoeFan",
		"76561198000000003": "J_Smith",
		"76561198000000004": "J.Smith",
		"76561198000000005": "TestPlayerAlpha",
		"76561198000000006": "TestPlayerBravo",
		"76561198000000007": "TestPlayerCharlie",
	}}
	cfg := nameTestConfig()
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, db)
	if !strings.Contains(ts.tools["find_players"].param.Description.Value, "forgiving") {
		t.Error("find_players doesn't describe the forgiving match")
	}

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
	db := &fakeNameDB{players: map[string]string{
		"76561198000000001": "Test Player Beta",
		"76561198000000002": "[TAG] TestPlayerGamma",
	}}
	cfg := nameTestConfig()
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, db)
	run := func(asker, input string) (any, error) {
		db.searched = nil
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
	if !reflect.DeepEqual(db.searched, []string{"discordalpha [Test Player Beta]", "discordalpha", "Test Player Beta"}) || db.schema != "public" {
		t.Errorf("searched %q in %q", db.searched, db.schema)
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
	if _, err := run("whoever", `{"name":"Beta"}`); err != nil || !reflect.DeepEqual(db.searched, []string{"Beta"}) {
		t.Errorf("name search: %v, searched %q", err, db.searched)
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

// Without a stats database, find_players falls back to the stats API's
// substring search, still telling an exact match apart.
func TestFindPlayersWithoutDatabase(t *testing.T) {
	var searched []string
	stats := fakeStats(t, map[string]string{
		"76561198000000001": "TestPlayerAlphaFan",
		"76561198000000002": "TestPlayerAlpha",
		"76561198000000003": "Jane Doe",
	}, &searched)
	cfg := &Config{Servers: map[string]GameServer{"main": {Name: "main", StatsAPIURL: "unused"}}, ServerOrder: []string{"main"}}
	ts := NewToolset(cfg, stats, nil, nil, nil)
	if strings.Contains(ts.tools["find_players"].param.Description.Value, "forgiving") {
		t.Error("find_players claims the forgiving match without a database")
	}
	for _, c := range []struct{ name, confidence, first string }{
		{"testplayeralpha", confidenceExact, "TestPlayerAlpha"},
		{"AlphaFan", confidenceClear, "TestPlayerAlphaFan"},
		{"TestPlayer", confidenceAmbiguous, "TestPlayerAlphaFan"},
		{"JaneDoe", confidenceNone, ""}, // only the forgiving match finds it
	} {
		out, err := ts.Run(context.Background(), &toolContext{}, "find_players", json.RawMessage(`{"name":`+strconv.Quote(c.name)+`}`))
		if err != nil {
			t.Fatalf("%q: %v", c.name, err)
		}
		res := out.(*nameMatches)
		first := ""
		if len(res.Players) > 0 {
			first, _ = res.Players[0]["name"].(string)
		}
		if res.Confidence != c.confidence || first != c.first {
			t.Errorf("%q: confidence %q, first %q; want %q, %q", c.name, res.Confidence, first, c.confidence, c.first)
		}
	}

	// A server without a stats schema uses the API even when there is a database.
	db := &fakeNameDB{}
	if _, err := NewToolset(cfg, stats, nil, nil, db).Run(context.Background(), &toolContext{}, "find_players", json.RawMessage(`{"name":"x"}`)); err != nil || len(db.searched) != 0 {
		t.Errorf("searched the database for a server without a schema: %v %q", err, db.searched)
	}
}

// query_stats and the system prompt send player lookups through find_players
// rather than name matching in SQL.
func TestPlayerSQLRule(t *testing.T) {
	cfg := nameTestConfig()
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, &fakeNameDB{})
	desc := ts.tools["query_stats"].param.Description.Value
	if !strings.Contains(desc, playerSQLRule) || !strings.Contains(playerSQLRule, "find_players") || !strings.Contains(playerSQLRule, "steam_id") {
		t.Errorf("query_stats description lacks the player rule: %q", desc)
	}
	if !strings.Contains(buildSystemPrompt(cfg, false), "filter your SQL by their steam_id; never match names in SQL") {
		t.Error("system prompt lacks the player rule")
	}
}
