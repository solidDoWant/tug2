package main

import (
	"context"
	"os"
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestLoosePattern(t *testing.T) {
	for _, c := range []struct {
		name string
		want any // string pattern, or nil
	}{
		{"Jane Doe", "%Jane%Doe%"},
		{"jane_doe", "%jane%doe%"},
		{"  Jane.-.Doe  ", "%Jane%Doe%"},
		{"JaneDoe", nil},
		{"...", nil},
		{"[TAG] Jane Doe", "%TAG%Jane%Doe%"},
		{"Ünï cødé", "%Ünï%cødé%"},
	} {
		got := loosePattern(c.name)
		switch want := c.want.(type) {
		case nil:
			if got != nil {
				t.Errorf("loosePattern(%q) = %q, want nil", c.name, *got)
			}
		case string:
			if got == nil || *got != want {
				t.Errorf("loosePattern(%q) = %v, want %q", c.name, got, want)
			}
		}
	}
}

// TestPostgresFindPlayers runs the name search against a real database, on
// the plugin's own player_stats table, as a role that can read only that
// table. Set STATSDB_TEST_ADMIN_URL as for TestPostgresStatsDB.
func TestPostgresFindPlayers(t *testing.T) {
	adminURL := os.Getenv("STATSDB_TEST_ADMIN_URL")
	if adminURL == "" {
		t.Skip("STATSDB_TEST_ADMIN_URL not set")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, adminURL)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close(ctx)
	migration, err := os.ReadFile("../../plugins/sourcemod/configs/sql-init-scripts/pgsql/gg2_mstats2.sql")
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`DROP SCHEMA IF EXISTS "names-test" CASCADE`,
		`DROP ROLE IF EXISTS name_reader`,
		`CREATE ROLE name_reader LOGIN PASSWORD 'pw'`,
		`CREATE SCHEMA "names-test"`,
		`SET search_path = "names-test"`,
		string(migration),
		`INSERT INTO player_stats (steam_id, name, score, kills, updated_at) VALUES
			('76561198000000001', 'Jane Doe', 10, 1, '2026-11-10 06:37:04'),
			('76561198000000002', 'JaneDoe', 20, 2, NULL),
			('76561198000000003', '[TAG] jane_doe', 30, 3, NULL),
			('76561198000000004', 'J4ne.D0e', 40, 4, NULL),
			('76561198000000005', 'Jane the Doe', 50, 5, NULL),
			('76561198000000006', 'TestPlayerAlpha', 60, 6, NULL),
			('76561198000000007', 'test_100%', 70, 7, NULL),
			('76561198000000008', 'test1100x', 80, 8, NULL),
			('76561198000000009', NULL, 90, 9, NULL)`,
		`GRANT USAGE ON SCHEMA "names-test" TO name_reader`,
		`GRANT SELECT ON "names-test".player_stats TO name_reader`,
	} {
		if _, err := admin.Exec(ctx, stmt); err != nil {
			t.Fatalf("%.80s: %v", stmt, err)
		}
	}
	t.Cleanup(func() {
		admin.Exec(context.Background(), `DROP SCHEMA "names-test" CASCADE`)
		admin.Exec(context.Background(), `DROP ROLE name_reader`)
	})
	cfg, _ := pgx.ParseConfig(adminURL)
	db, err := NewPostgresStatsDB("postgres://name_reader:pw@" + cfg.Host + ":" + strconv.Itoa(int(cfg.Port)) + "/" + cfg.Database + "?sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	type match struct{ Name, Kind string }
	for _, c := range []struct {
		name string
		want []match
	}{
		// Better matches first, then by score.
		{"jane doe", []match{
			{"Jane Doe", "exact"},
			{"J4ne.D0e", "normalised"}, {"[TAG] jane_doe", "normalised"}, {"JaneDoe", "normalised"},
			{"Jane the Doe", "loose"},
		}},
		{"JaneDoe", []match{
			{"JaneDoe", "exact"},
			{"J4ne.D0e", "normalised"}, {"[TAG] jane_doe", "normalised"}, {"Jane Doe", "normalised"},
		}},
		{"jane", []match{
			{"Jane the Doe", "substring"}, {"[TAG] jane_doe", "substring"}, {"JaneDoe", "substring"}, {"Jane Doe", "substring"},
			{"J4ne.D0e", "normalised"},
		}},
		// LIKE metacharacters in the search are literal in every form.
		// (test1100x is a leetspeak match: both are "...ioo..." normalised.)
		{"100%", []match{{"test_100%", "substring"}, {"test1100x", "normalised"}}},
		{"t_1", []match{{"test_100%", "substring"}, {"test1100x", "normalised"}}},
		{"%", []match{{"test_100%", "substring"}}},
		{`\`, nil},
		{"_ %", nil},
		// Regex metacharacters are not regexes either.
		{".*", nil},
		{"Jane.*Doe", []match{
			{"J4ne.D0e", "normalised"}, {"[TAG] jane_doe", "normalised"}, {"JaneDoe", "normalised"}, {"Jane Doe", "normalised"},
			{"Jane the Doe", "loose"},
		}},
		// A search of only punctuation doesn't match everyone.
		{"...", nil},
	} {
		players, total, err := db.FindPlayers(ctx, "names-test", c.name)
		if err != nil {
			t.Fatalf("FindPlayers(%q): %v", c.name, err)
		}
		var got []match
		for _, p := range players {
			got = append(got, match{p.Name, p.NameMatch})
		}
		if !reflect.DeepEqual(got, c.want) || total != len(c.want) {
			t.Errorf("FindPlayers(%q): total %d\n got %v\nwant %v", c.name, total, got, c.want)
		}
	}

	// Headline stats come along, with the local wall-clock updated_at read as
	// the server's zone (the bot's session doesn't set one).
	var zone string
	if err := admin.QueryRow(ctx, "SELECT reset_val FROM pg_settings WHERE name = 'TimeZone'").Scan(&zone); err != nil {
		t.Fatal(err)
	}
	loc, err := time.LoadLocation(zone)
	if err != nil {
		t.Fatal(err)
	}
	players, _, err := db.FindPlayers(ctx, "names-test", "Jane Doe")
	if err != nil || len(players) == 0 {
		t.Fatalf("%v %v", err, players)
	}
	p := players[0]
	want := time.Date(2026, 11, 10, 6, 37, 4, 0, loc)
	if p.SteamID != "76561198000000001" || p.Score != 10 || p.Kills != 1 || p.UpdatedAt == nil || !p.UpdatedAt.Equal(want) {
		t.Errorf("player = %+v, want updated_at %s", p, want)
	}

	// More players than a page: the best first, and the total.
	if _, err := admin.Exec(ctx, `INSERT INTO "names-test".player_stats (steam_id, name, score)
		SELECT '7656119900000' || lpad(i::text, 4, '0'), 'TestPlayer' || i, i FROM generate_series(1, 30) i`); err != nil {
		t.Fatal(err)
	}
	players, total, err := db.FindPlayers(ctx, "names-test", "TestPlayer")
	if err != nil || len(players) != maxNameMatches || total != 31 || players[0].Name != "TestPlayerAlpha" {
		t.Errorf("paged: %v, %d players of %d, first %+v", err, len(players), total, players)
	}
}
