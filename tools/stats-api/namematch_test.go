package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
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

// TestListPlayersFuzzy runs the fuzzy search against a real Postgres. Set
// STATS_API_TEST_DATABASE_URL to a database the test may create a scratch
// schema in, e.g. the docker compose one:
// postgres://insurgency:insurgency@localhost:5432/sourcemod-insurgency-stats?sslmode=disable
func TestListPlayersFuzzy(t *testing.T) {
	dbURL := os.Getenv("STATS_API_TEST_DATABASE_URL")
	if dbURL == "" {
		t.Skip("STATS_API_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	schema := fmt.Sprintf("namematch_test_%d", time.Now().UnixNano())

	admin, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close(ctx)
	if _, err := admin.Exec(ctx, `CREATE SCHEMA `+schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Exec(context.Background(), `DROP SCHEMA `+schema+` CASCADE`) })

	u, err := url.Parse(dbURL)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	store, err := NewStore(ctx, u.String())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	conn, err := store.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"gg2_mstats2.sql", "gg2_mstats2_shots.sql", "gg2_mstats2_history.sql"} {
		sql, err := os.ReadFile(filepath.Join("../../plugins/sourcemod/configs/sql-init-scripts/pgsql", f))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Exec(ctx, string(sql)); err != nil {
			t.Fatalf("%s: %v", f, err)
		}
	}
	if _, err := conn.Exec(ctx, `INSERT INTO player_stats (steam_id, name, score) VALUES
		('76561198000000001', 'Jane Doe', 10),
		('76561198000000002', 'JaneDoe', 20),
		('76561198000000003', '[TAG] jane_doe', 30),
		('76561198000000004', 'J4ne.D0e', 40),
		('76561198000000005', 'Jane the Doe', 50),
		('76561198000000006', 'TestPlayerAlpha', 60),
		('76561198000000007', 'test_100%', 70),
		('76561198000000008', 'test1100x', 80),
		('76561198000000009', NULL, 90)`); err != nil {
		t.Fatal(err)
	}
	conn.Release()

	type match struct{ Name, Kind string }
	search := func(name string, fuzzy bool) ([]match, int) {
		t.Helper()
		players, total, err := store.ListPlayers(ctx, nil, "score", name, fuzzy, 50, 0)
		if err != nil {
			t.Fatalf("ListPlayers(%q, %v): %v", name, fuzzy, err)
		}
		out := []match{}
		for _, p := range players {
			m := match{Name: *p.Name}
			if p.NameMatch != nil {
				m.Kind = *p.NameMatch
			}
			out = append(out, m)
		}
		if total != len(out) {
			t.Errorf("ListPlayers(%q, %v): total %d, %d players", name, fuzzy, total, len(out))
		}
		return out, total
	}

	for _, c := range []struct {
		name  string
		fuzzy bool
		want  []match
	}{
		// Better matches first, then by score.
		{"jane doe", true, []match{
			{"Jane Doe", "exact"},
			{"J4ne.D0e", "normalised"}, {"[TAG] jane_doe", "normalised"}, {"JaneDoe", "normalised"},
			{"Jane the Doe", "loose"},
		}},
		{"JaneDoe", true, []match{
			{"JaneDoe", "exact"},
			{"J4ne.D0e", "normalised"}, {"[TAG] jane_doe", "normalised"}, {"Jane Doe", "normalised"},
		}},
		{"jane", true, []match{
			{"Jane the Doe", "substring"}, {"[TAG] jane_doe", "substring"}, {"JaneDoe", "substring"}, {"Jane Doe", "substring"},
			{"J4ne.D0e", "normalised"},
		}},
		// The plain search is unchanged and sets no kind.
		{"jane doe", false, []match{{"Jane Doe", ""}}},
		// LIKE metacharacters in the query are literal in every form.
		// (test1100x is a leetspeak match: both are "...ioo..." normalised.)
		{"100%", true, []match{{"test_100%", "substring"}, {"test1100x", "normalised"}}},
		{"t_1", true, []match{{"test_100%", "substring"}, {"test1100x", "normalised"}}},
		{"%", true, []match{{"test_100%", "substring"}}},
		{`\`, true, []match{}},
		{"_ %", true, []match{}},
		// Regex metacharacters are not regexes either.
		{".*", true, []match{}},
		{"Jane.*Doe", true, []match{
			{"J4ne.D0e", "normalised"}, {"[TAG] jane_doe", "normalised"}, {"JaneDoe", "normalised"}, {"Jane Doe", "normalised"},
			{"Jane the Doe", "loose"},
		}},
		// A query of only punctuation doesn't match everyone.
		{"...", true, []match{}},
	} {
		got, _ := search(c.name, c.fuzzy)
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("search %q fuzzy=%v:\n got %v\nwant %v", c.name, c.fuzzy, got, c.want)
		}
	}

	// A windowed fuzzy search only lists players with rounds in the window.
	w := &Window{Since: time.Now().Add(-time.Hour), Until: time.Now()}
	players, _, err := store.ListPlayers(ctx, w, "score", "jane doe", true, 50, 0)
	if err != nil || len(players) != 0 {
		t.Errorf("windowed: %v, %d players", err, len(players))
	}
}
