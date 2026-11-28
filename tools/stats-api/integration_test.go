package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

// The integration test runs every endpoint's queries against a database laid
// out by testdata/init-db.sh and seeded by testdata/seed.sql, and checks values
// the seed determines. It is skipped unless STATS_API_TEST_DB_URL is set;
// testdata/run-integration.sh starts such a database in docker and runs it.

const (
	alpha   = int64(76561198000000001) // old + v2
	bravo   = int64(76561198000000002) // old + v2
	charlie = int64(76561198000000003) // old only
	delta   = int64(76561198000000004) // v2 only
)

func integrationStore(t *testing.T) *Store {
	t.Helper()
	url := os.Getenv("STATS_API_TEST_DB_URL")
	if url == "" {
		t.Skip("STATS_API_TEST_DB_URL not set; see testdata/run-integration.sh")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	store, err := NewStore(ctx, url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(store.Close)
	return store
}

func day(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

// windows to run every windowed query with: all time, the old history day,
// and from the cutover on.
var testWindows = map[string]*Window{
	"lifetime":     nil,
	"old history":  {Since: day("2026-11-20T00:00:00Z"), Until: day("2026-11-21T00:00:00Z")},
	"from cutover": {Since: day("2026-11-25T00:00:00Z"), Until: day("2026-11-27T00:00:00Z")},
}

// must checks the error of a (value, err) call: must(call(...))(t).
func must[T any](v T, err error) func(*testing.T) T {
	return func(t *testing.T) T {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
}

func val[T any](p *T) any {
	if p == nil {
		return nil
	}
	return *p
}

func eq(t *testing.T, what string, got, want any) {
	t.Helper()
	if got != want {
		t.Errorf("%s = %v, want %v", what, got, want)
	}
}

// viewInt reads one bigint straight from the database, to compare the API's
// numbers with the views they must come from.
func viewInt(t *testing.T, s *Store, query string, args ...any) int64 {
	t.Helper()
	var n int64
	if err := s.pool.QueryRow(context.Background(), query, args...).Scan(&n); err != nil {
		t.Fatalf("%s: %v", query, err)
	}
	return n
}

func TestIntegrationEveryQueryRuns(t *testing.T) {
	s := integrationStore(t)
	ctx := context.Background()
	ok := func(_ any, err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	okPage := func(_ any, _ int, err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	for name, w := range testWindows {
		t.Run(name, func(t *testing.T) {
			for sort := range playerSorts {
				okPage(s.ListPlayers(ctx, w, sort, "", 50, 0))
			}
			for _, id := range []int64{alpha, bravo, charlie, delta} {
				ok(s.GetPlayer(ctx, w, id))
				ok(s.GetPlayerWeapons(ctx, w, id))
				ok(s.GetPlayerClasses(ctx, w, id))
				okPage(s.GetPlayerRounds(ctx, w, id, 50, 0))
			}
			for sort := range weaponSorts {
				okPage(s.ListWeapons(ctx, w, sort, 50, 0))
			}
			for sort := range weaponPlayerSorts {
				okPage(s.GetWeaponPlayers(ctx, w, "m4a1", sort, 1, 50, 0))
			}
			for sort := range medicSorts {
				okPage(s.ListMedics(ctx, w, sort, 50, 0))
			}
			for sort := range teamKillSorts {
				okPage(s.ListTeamKills(ctx, w, sort, 50, 0))
			}
			okPage(s.ListTeamKillWeapons(ctx, w, 50, 0))
			for sort := range fireSupportSorts {
				okPage(s.ListFireSupport(ctx, w, sort, 50, 0))
			}
		})
	}
	for sort := range mapSorts {
		okPage(s.ListMaps(ctx, sort, 50, 0))
	}
	for _, m := range []string{"ministry", "sinjar", "buhriz"} {
		ok(s.GetMap(ctx, m, 2000))
	}
	okPage(s.ListMapRuns(ctx, 50, 0))
	ok(s.GetMapRun(ctx, 2))
	for _, id := range []int64{1, 2, 3} {
		ok(s.GetRound(ctx, id))
	}
	okPage(s.ListBots(ctx, 50, 0))
	ok(s.GetBotWeapons(ctx, "Rifleman Jones"))
}

func TestIntegrationPlayers(t *testing.T) {
	s := integrationStore(t)
	ctx := context.Background()

	p := must(s.GetPlayer(ctx, nil, alpha))(t)
	eq(t, "steam_id", p.SteamID, "76561198000000001")
	eq(t, "name", val(p.Name), "Alpha Renamed")
	// Every lifetime total is the view's.
	for col, got := range map[string]*int64{"kills": p.Kills, "deaths": p.Deaths, "score": p.Score,
		"medic_seconds": p.MedicSeconds, "shots": p.Shots, "team_kills": p.TeamKills,
		"fire_support_calls": p.FireSupportCalls, "best_killstreak": p.BestKillstreak} {
		want := viewInt(t, s, `SELECT `+col+`::bigint FROM v_player_lifetime WHERE steam_id = $1`, alpha)
		eq(t, "lifetime "+col, val(got), want)
	}
	eq(t, "best_killstreak", val(p.BestKillstreak), int64(12))
	eq(t, "kd", val(p.KD), 10.1)
	eq(t, "accuracy", val(p.Accuracy), 25.4)
	// The old created_at is local wall-clock time (the test database is not in UTC).
	eq(t, "first_seen", p.FirstSeen.Format(time.RFC3339), "2026-01-01T13:00:00Z")
	eq(t, "name history", len(p.NameHistory), 2)
	if len(p.NameHistory) == 2 {
		eq(t, "newest name", p.NameHistory[0].Name, "Alpha Renamed")
		eq(t, "oldest name", p.NameHistory[1].Name, "Alpha Tester")
	}

	// A window over old history only: what the old plugins never recorded is null, not 0.
	w := testWindows["old history"]
	p = must(s.GetPlayer(ctx, w, alpha))(t)
	eq(t, "window kills", val(p.Kills), int64(10))
	eq(t, "window assists", val(p.Assists), nil)
	eq(t, "window world_deaths", val(p.WorldDeaths), nil)
	eq(t, "window best_killstreak", val(p.BestKillstreak), nil)
	eq(t, "window medic_seconds", val(p.MedicSeconds), int64(100))
	if p.Window == nil || !p.Window.Since.Equal(w.Since) {
		t.Errorf("window = %+v", p.Window)
	}
	// No play in the window: zeros.
	p = must(s.GetPlayer(ctx, testWindows["from cutover"], charlie))(t)
	eq(t, "idle kills", val(p.Kills), int64(0))
	eq(t, "idle assists", val(p.Assists), int64(0))

	if _, err := s.GetPlayer(ctx, nil, 1); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown player: err = %v", err)
	}

	// Name search matches % and _ literally.
	players, total := must2(s.ListPlayers(ctx, nil, "score", "_100%", 50, 0))(t)
	eq(t, "name search total", total, 1)
	if len(players) == 1 {
		eq(t, "name search hit", players[0].SteamID, "76561198000000003")
	}
	_, total = must2(s.ListPlayers(ctx, nil, "score", "a_", 50, 0))(t)
	eq(t, "literal underscore", total, 0)

	// Lifetime lists everyone; a window only those who played in it.
	_, total = must2(s.ListPlayers(ctx, nil, "score", "", 50, 0))(t)
	eq(t, "lifetime players", total, 4)
	players, total = must2(s.ListPlayers(ctx, testWindows["from cutover"], "kills", "", 50, 0))(t)
	eq(t, "window players", total, 3)
	if len(players) > 0 {
		eq(t, "top killer from the cutover", players[0].SteamID, "76561198000000001")
	}
	players, _ = must2(s.ListPlayers(ctx, nil, "accuracy", "", 50, 0))(t)
	eq(t, "most accurate (500+ shots)", players[0].SteamID, "76561198000000001")

	classes := must(s.GetPlayerClasses(ctx, nil, alpha))(t)
	want := map[string][3]int64{
		"template_medic_security":    {1440, 0, 1},
		"template_rifleman_security": {900, 3, 0},
	}
	eq(t, "classes", len(classes), len(want))
	for _, c := range classes {
		eq(t, "class "+val(c.ClassTemplate).(string), [3]int64{c.Seconds, c.Kills, c.Deaths}, want[*c.ClassTemplate])
	}

	rounds, total := must2(s.GetPlayerRounds(ctx, nil, alpha, 50, 0))(t)
	eq(t, "round rows", int64(total), viewInt(t, s, `SELECT count(*) FROM v_player_round_stats WHERE steam_id = $1`, alpha))
	eq(t, "newest round", val(rounds[0].RoundID), int64(3))
	var mvp, legacy bool
	for _, r := range rounds {
		if r.RoundID != nil && *r.RoundID == 1 {
			mvp = val(r.WasMVP) == true
		}
		if r.Source == "old" {
			legacy = r.RoundID == nil && r.WasMVP == nil
		}
	}
	if !mvp || !legacy {
		t.Errorf("round history: mvp %v, legacy row %v", mvp, legacy)
	}

	weapons := must(s.GetPlayerWeapons(ctx, nil, alpha))(t)
	eq(t, "weapons", len(weapons), 2)
	eq(t, "top weapon", weapons[0].WeaponName, "m4a1")
	eq(t, "m4a1 kills", weapons[0].Kills, viewInt(t, s,
		`SELECT kills::bigint FROM v_player_weapon_lifetime WHERE steam_id = $1 AND weapon_name = 'm4a1'`, alpha))
	weapons = must(s.GetPlayerWeapons(ctx, testWindows["old history"], alpha))(t)
	eq(t, "old-window weapons", len(weapons), 1)
	eq(t, "old-window hits_head", val(weapons[0].HitsHead), nil)
}

// must2 checks the error of a (items, total, err) call: must2(call(...))(t).
func must2[T any](items []T, total int, err error) func(*testing.T) ([]T, int) {
	return func(t *testing.T) ([]T, int) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return items, total
	}
}

func TestIntegrationWeaponsMapsRounds(t *testing.T) {
	s := integrationStore(t)
	ctx := context.Background()

	weapons, _ := must2(s.ListWeapons(ctx, nil, "kills", 50, 0))(t)
	byName := map[string]WeaponTotals{}
	for _, w := range weapons {
		byName[w.WeaponName] = w
	}
	eq(t, "m9 type (old only)", val(byName["m9"].WeaponType), nil)
	eq(t, "ak74 type", val(byName["ak74"].WeaponType), "rifle")
	eq(t, "ak74 players", byName["ak74"].UniquePlayers, int64(3))

	if _, _, err := s.GetWeaponPlayers(ctx, nil, "nope", "accuracy", 100, 50, 0); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown weapon: err = %v", err)
	}
	top, total := must2(s.GetWeaponPlayers(ctx, nil, "m9", "kills", 100, 50, 0))(t)
	eq(t, "m9 killers", total, 1)
	eq(t, "m9 kills", top[0].Kills, int64(10))
	_, total = must2(s.GetWeaponPlayers(ctx, nil, "ak74", "accuracy", 500, 50, 0))(t)
	eq(t, "ak74 players with 500+ shots", total, 1)

	m := must(s.GetMap(ctx, "ministry", 3))(t)
	eq(t, "map rounds", m.Rounds, viewInt(t, s, `SELECT rounds FROM v_maps WHERE map_name = 'ministry'`))
	eq(t, "win rate", val(m.WinRate), 50.0)
	eq(t, "recent runs", len(m.RecentRuns), 1)
	eq(t, "kill positions (limited)", len(m.KillPositions), 3)
	if _, err := s.GetMap(ctx, "nope", 10); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown map: err = %v", err)
	}

	runs, total := must2(s.ListMapRuns(ctx, 50, 0))(t)
	eq(t, "map runs", total, 2)
	eq(t, "newest run", runs[0].MapRunID, int64(2))
	run := must(s.GetMapRun(ctx, 1))(t)
	eq(t, "run rounds", run.Run.Rounds, int64(2))
	eq(t, "run wins", run.Run.Wins, int64(1))
	eq(t, "round list", len(run.Rounds), 2)
	eq(t, "scoreboard", len(run.Scoreboard), 3)
	eq(t, "scoreboard top", run.Scoreboard[0].SteamID, "76561198000000001")
	eq(t, "scoreboard top score", run.Scoreboard[0].Score, int64(80))
	if _, err := s.GetMapRun(ctx, 99); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown run: err = %v", err)
	}

	r := must(s.GetRound(ctx, 1))(t)
	eq(t, "mvp", val(r.MVPName), "Alpha Renamed")
	counts := map[string]int{}
	for i, e := range r.Timeline {
		counts[e.Type]++
		if i > 0 && e.At.Before(r.Timeline[i-1].At) {
			t.Errorf("timeline out of order at %d", i)
		}
	}
	eq(t, "timeline kills", counts["kill"], 7)
	eq(t, "timeline objectives", counts["objective"], 2)
	eq(t, "timeline counterattacks", counts["counterattack_start"]+counts["counterattack_end"], 2)
	eq(t, "timeline revives", counts["revive"], 1)
	eq(t, "timeline survival", counts["survival_level"], 1)
	if _, err := s.GetRound(ctx, 99); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown round: err = %v", err)
	}
}

func TestIntegrationBotsMedicsTeamKillsFireSupport(t *testing.T) {
	s := integrationStore(t)
	ctx := context.Background()

	bots, _ := must2(s.ListBots(ctx, 50, 0))(t)
	got := map[string]int64{}
	for _, b := range bots {
		got[b.BotName] = b.TotalKills
	}
	eq(t, "Rifleman Jones", got["Rifleman Jones"], viewInt(t, s,
		`SELECT sum(kills)::bigint FROM v_bot_weapon_kills WHERE bot_name = 'Rifleman Jones'`))
	eq(t, "Old Sniper", got["Old Sniper"], int64(7))
	eq(t, "unknown bot", len(must(s.GetBotWeapons(ctx, "nobody"))(t)), 0)

	medics, _ := must2(s.ListMedics(ctx, nil, "medic_time", 50, 0))(t)
	eq(t, "top medic", medics[0].SteamID, "76561198000000001")
	eq(t, "avg revive", val(medics[0].AvgReviveSeconds), 9.0)
	eq(t, "medic hp healed", val(medics[0].HPHealed), int64(80))

	tks, _ := must2(s.ListTeamKills(ctx, nil, "team_kills", 50, 0))(t)
	eq(t, "top team killer", tks[0].SteamID, "76561198000000001")
	eq(t, "team kills", val(tks[0].TeamKills), int64(3))
	eq(t, "forgiven", tks[0].Forgiven, int64(2))
	tkw, _ := must2(s.ListTeamKillWeapons(ctx, &Window{Since: day("2025-12-01T00:00:00Z"), Until: day("2026-01-01T00:00:00Z")}, 50, 0))(t)
	eq(t, "team kill weapons in 2025-12", len(tkw), 1)
	eq(t, "2025-12 weapon", val(tkw[0].WeaponName), "knife")

	fs, _ := must2(s.ListFireSupport(ctx, nil, "calls", 50, 0))(t)
	eq(t, "fire support calls", val(fs[0].Calls), int64(5))
	eq(t, "failed", fs[0].Failed, int64(1))
	eq(t, "refunded", fs[0].Refunded, int64(1))
	fs, _ = must2(s.ListFireSupport(ctx, testWindows["from cutover"], "calls", 50, 0))(t)
	eq(t, "windowed fire support players", len(fs), 2)
}

// TestIntegrationHTTP serves every endpoint through the real router and checks
// statuses and the JSON shapes clients depend on.
func TestIntegrationHTTP(t *testing.T) {
	s := integrationStore(t)
	mux := NewServer(s, "").Routes()
	get := func(path string) (int, string) {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v2"+path, nil))
		return rec.Code, rec.Body.String()
	}

	for path, want := range map[string]int{
		"/players": 200, "/players?sort=kd&period=30d": 200, "/players?name=x%25_": 200,
		"/players/76561198000000001": 200, "/players/76561198000000001?period=7d": 200,
		"/players/1": 404, "/players/99999999999999999999": 404, "/players/abc": 422,
		"/players/76561198000000001/weapons": 200, "/players/76561198000000001/classes": 200,
		"/players/76561198000000001/rounds?limit=2": 200,
		"/weapons": 200, "/weapons?sort=accuracy&since=2026-11-01": 200,
		"/weapons/m4a1": 200, "/weapons/m4a1?sort=kills": 200, "/weapons/nope": 404,
		"/maps": 200, "/maps?sort=win_rate": 200, "/maps/ministry": 200, "/maps/nope": 404,
		"/maps/ministry?limit_positions=20000": 422,
		"/map-runs":                            200, "/map-runs/1": 200, "/map-runs/99": 404, "/map-runs/0": 422,
		"/rounds/1": 200, "/rounds/99": 404,
		"/bots": 200, "/bots/Rifleman%20Jones/weapons": 200, "/bots/nobody/weapons": 200,
		"/medics": 200, "/medics?sort=hp_healed&since=2026-11-25": 200,
		"/teamkills": 200, "/teamkills?sort=forgiven": 200, "/teamkills/weapons?period=365d": 200,
		"/fire-support": 200, "/fire-support?sort=last_called": 200,
		"/players?period=7d&since=2026-11-01": 422, "/players?limit=201": 422,
	} {
		if code, body := get(path); code != want {
			t.Errorf("GET %s = %d, want %d: %.200s", path, code, want, body)
		}
	}

	// SteamIDs are strings; v2-only stats are null in an old-history window; windowed lists say so.
	_, body := get("/players?since=2026-11-20&until=2026-11-21&sort=kills")
	var list struct {
		Items  []map[string]any `json:"items"`
		Window *WindowInfo      `json:"window"`
	}
	if err := json.Unmarshal([]byte(body), &list); err != nil {
		t.Fatal(err)
	}
	if list.Window == nil || len(list.Items) == 0 {
		t.Fatalf("windowed list: %.300s", body)
	}
	top := list.Items[0]
	if top["steam_id"] != "76561198000000001" {
		t.Errorf("steam_id = %#v", top["steam_id"])
	}
	for _, k := range []string{"assists", "world_deaths", "headshot_kills", "best_killstreak", "damage_enemy"} {
		if v, ok := top[k]; !ok || v != nil {
			t.Errorf("%s = %#v, want null", k, v)
		}
	}
	if _, body := get("/players"); strings.Contains(body, `"window"`) {
		t.Errorf("lifetime list has a window")
	}
}
