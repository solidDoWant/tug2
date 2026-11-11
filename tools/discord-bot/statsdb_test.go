package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

func TestCheckQuery(t *testing.T) {
	for _, ok := range []string{
		"SELECT 1",
		"  select avg(kills) from player_stats;  ",
		"WITH t AS (SELECT 1) SELECT * FROM t",
		"(SELECT 1) UNION (SELECT 2)",
	} {
		if err := checkQuery(ok); err != nil {
			t.Errorf("checkQuery(%q) = %v", ok, err)
		}
	}
	for _, bad := range []string{
		"", " ; ",
		"DELETE FROM player_stats",
		"SET statement_timeout = 0",
		"SELECT set_config('work_mem', '4GB', true)",
		"SELECT pg_catalog.SET_CONFIG('work_mem', '4GB', false)",
		"SELECT '" + strings.Repeat("a", maxQuerySQLLen) + "'",
	} {
		if err := checkQuery(bad); err == nil {
			t.Errorf("checkQuery(%.40q) passed", bad)
		}
	}
}

func TestWrapQuery(t *testing.T) {
	got := wrapQuery("SELECT 1 -- trailing comment;\n;")
	want := "SELECT * FROM (\nSELECT 1 -- trailing comment\n) AS query_stats LIMIT 201"
	if got != want {
		t.Errorf("wrapQuery = %q, want %q", got, want)
	}
}

func TestJSONValue(t *testing.T) {
	var num pgtype.Numeric
	if err := num.Scan("12.5"); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		in, want any
	}{
		{nil, nil},
		{int64(7), int64(7)},
		{time.Date(2026, 11, 10, 6, 37, 4, 0, time.FixedZone("x", -5*3600)), "2026-11-10 11:37:04"},
		{num, 12.5},
		{pgtype.Interval{Microseconds: 90_000_000, Days: 1, Valid: true}, 86490.0},
		{[]byte{1, 2, 3}, "<3 bytes>"},
		{strings.Repeat("é", maxQueryCell+5), strings.Repeat("é", maxQueryCell) + "…"},
	} {
		if got := jsonValue(c.in); !jsonEqual(got, c.want) {
			t.Errorf("jsonValue(%v) = %#v, want %#v", c.in, got, c.want)
		}
	}
}

func jsonEqual(a, b any) bool {
	ja, _ := json.Marshal(a)
	jb, _ := json.Marshal(b)
	return string(ja) == string(jb)
}

type fakeStatsDB struct {
	schema, sql string
	// tables is what Schema returns per schema; schemaErr fails it.
	tables    map[string][]schemaTable
	schemaErr error
}

func (f *fakeStatsDB) Query(_ context.Context, schema, sql string) (*QueryResult, error) {
	f.schema, f.sql = schema, sql
	return &QueryResult{Columns: []string{"x"}, Rows: [][]any{{1}}}, nil
}

func (f *fakeStatsDB) Schema(_ context.Context, schema string) ([]schemaTable, error) {
	return f.tables[schema], f.schemaErr
}

func TestQueryStatsTool(t *testing.T) {
	cfg := &Config{
		StatsDBURL: "postgres:///",
		Servers: map[string]GameServer{
			"main":  {Name: "main", StatsAPIURL: "http://x", StatsDBSchema: "public"},
			"test":  {Name: "test", StatsAPIURL: "http://y", StatsDBSchema: "insurgency-test"},
			"other": {Name: "other", StatsAPIURL: "http://z"},
		},
		ServerOrder: []string{"main", "test", "other"},
	}
	db := &fakeStatsDB{}
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, db)
	run := func(input string) error {
		_, err := ts.Run(context.Background(), &toolContext{}, "query_stats", json.RawMessage(input))
		return err
	}

	if err := run(`{"sql":"SELECT 1"}`); err != nil || db.schema != "public" {
		t.Errorf("default server: %v, schema %q", err, db.schema)
	}
	if err := run(`{"sql":"SELECT 2","server":"test"}`); err != nil || db.schema != "insurgency-test" || db.sql != "SELECT 2" {
		t.Errorf("test server: %v, schema %q sql %q", err, db.schema, db.sql)
	}
	for _, bad := range []string{`{"sql":"SELECT 1","server":"other"}`, `{"sql":"DROP TABLE x"}`, `{}`} {
		if err := run(bad); err == nil {
			t.Errorf("%s: no error", bad)
		}
	}
	if !strings.Contains(buildSystemPrompt(cfg, false), "query_stats") {
		t.Error("system prompt doesn't mention query_stats")
	}

	// Not offered without a database URL, or without a database.
	cfg.StatsDBURL = ""
	if _, ok := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, db).tools["query_stats"]; ok {
		t.Error("offered without STATS_DB_URL")
	}
	cfg.StatsDBURL = "postgres:///"
	if _, ok := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, nil).tools["query_stats"]; ok {
		t.Error("offered without a database")
	}
}

// TestPostgresStatsDB runs the guards against a real database. Set
// STATSDB_TEST_ADMIN_URL to a superuser connection string on a throwaway
// server; the test creates its own roles, schemas and tables.
func TestPostgresStatsDB(t *testing.T) {
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
	for _, stmt := range []string{
		`DROP SCHEMA IF EXISTS "test-schema" CASCADE`,
		`DROP TABLE IF EXISTS public.player_stats, public.maps, public.connection_log`,
		`DROP ROLE IF EXISTS bot_reader`,
		`CREATE ROLE bot_reader LOGIN PASSWORD 'pw' CONNECTION LIMIT 2`,
		`ALTER ROLE bot_reader SET temp_file_limit = '64MB'`,
		`CREATE TABLE public.player_stats (steam_id varchar PRIMARY KEY, name varchar, kills int, deaths int, updated_at timestamp)`,
		`INSERT INTO public.player_stats SELECT '765611980000000' || lpad(i::text, 2, '0'), 'TestPlayer' || i, i * 10, i, '2026-11-10 06:37:04' FROM generate_series(1, 30) i`,
		`CREATE TABLE public.maps (map_name varchar PRIMARY KEY, play_time interval)`,
		`INSERT INTO public.maps VALUES ('test_map', '1 day 00:01:30')`,
		`CREATE TABLE public.connection_log (steamid varchar, ip_address varchar)`,
		`INSERT INTO public.connection_log VALUES ('76561198000000001', '192.0.2.1')`,
		`CREATE SCHEMA "test-schema"`,
		`CREATE TABLE "test-schema".player_stats (steam_id varchar PRIMARY KEY, name varchar, kills int, deaths int, updated_at timestamp)`,
		`INSERT INTO "test-schema".player_stats VALUES ('76561198000000099', 'TestPlayerOnTest', 1, 1, now())`,
		`GRANT USAGE ON SCHEMA "test-schema" TO bot_reader`,
		`GRANT SELECT ON public.player_stats, public.maps, "test-schema".player_stats TO bot_reader`,
	} {
		if _, err := admin.Exec(ctx, stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	cfg, _ := pgx.ParseConfig(adminURL)
	botURL := "postgres://bot_reader:pw@" + cfg.Host + ":" + strconv.Itoa(int(cfg.Port)) + "/" + cfg.Database + "?sslmode=disable"
	db, err := NewPostgresStatsDB(botURL)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	res, err := db.Query(ctx, "public", "SELECT count(*) AS players, avg(kills::numeric / NULLIF(deaths, 0)) AS avg_kd, max(updated_at) AS last FROM player_stats;")
	if err != nil {
		t.Fatal(err)
	}
	if got := mustJSON(res); got != `{"columns":["players","avg_kd","last"],"rows":[[30,10,"2026-11-10 06:37:04"]]}` {
		t.Errorf("aggregate = %s", got)
	}
	if res, err := db.Query(ctx, "public", "SELECT map_name, play_time FROM maps"); err != nil || mustJSON(res.Rows) != `[["test_map",86490]]` {
		t.Errorf("interval: %v %v", err, res)
	}
	if res, err := db.Query(ctx, "test-schema", "SELECT name FROM player_stats"); err != nil || mustJSON(res.Rows) != `[["TestPlayerOnTest"]]` {
		t.Errorf("test schema: %v %v", err, res)
	}
	if res, err := db.Query(ctx, "public", "SELECT generate_series(1, 100000) AS n"); err != nil || !res.Truncated || len(res.Rows) != maxQueryRows {
		t.Errorf("row cap: %v, truncated=%v rows=%d", err, res != nil && res.Truncated, len(res.Rows))
	}

	// Without the wrapper's LIMIT, the client stops reading and drops the
	// connection rather than draining 50M rows.
	conn, err := db.pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	res, err = readRows(ctx, tx, "SELECT generate_series(1, 50000000)")
	if !errors.Is(err, errRowLimit) || len(res.Rows) != maxQueryRows || time.Since(start) > 2*time.Second {
		t.Errorf("unwrapped: %v, %d rows in %s", err, len(res.Rows), time.Since(start))
	}
	conn.Conn().Close(ctx)
	conn.Release()

	expectErr := func(sql, want string) {
		t.Helper()
		start := time.Now()
		_, err := db.Query(ctx, "public", sql)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: error %v, want it to mention %q", sql, err, want)
		}
		if time.Since(start) > queryStatementTimeout+2*time.Second {
			t.Errorf("%q took %s", sql, time.Since(start))
		}
	}
	expectErr("SELECT ip_address FROM connection_log", "permission denied")
	expectErr(`SELECT * FROM "test-schema".player_stats, public.connection_log`, "permission denied")
	expectErr("SELECT 1; SELECT 2", "syntax error")
	expectErr("SELECT nosuchcolumn FROM player_stats", "nosuchcolumn")
	expectErr("SELECT pg_sleep(10)", "ran longer than")
	expectErr("WITH d AS (DELETE FROM player_stats RETURNING 1) SELECT * FROM d", "")
	expectErr("SELECT nextval('x')", "")

	// The connection is reset after each query: no advisory lock survives.
	if _, err := db.Query(ctx, "public", "SELECT pg_advisory_lock(42)"); err != nil {
		t.Fatal(err)
	}
	var held int
	if err := admin.QueryRow(ctx, "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory'").Scan(&held); err != nil || held != 0 {
		t.Errorf("advisory locks held after the query: %d (%v)", held, err)
	}

	// The table data really is out of reach, whatever the query.
	var ipSeen bool
	for _, sql := range []string{"SELECT * FROM connection_log", "SELECT * FROM public.connection_log"} {
		if res, err := db.Query(ctx, "public", sql); err == nil && strings.Contains(mustJSON(res), "192.0.2.1") {
			ipSeen = true
		}
	}
	if ipSeen {
		t.Error("connection_log was readable")
	}
}

func mustJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
