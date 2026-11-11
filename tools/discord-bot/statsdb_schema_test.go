package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

const pgsqlScripts = "../../plugins/sourcemod/configs/sql-init-scripts/pgsql"

func testSchemas() map[string][]schemaTable {
	stats := schemaTable{Name: "player_stats", Comment: "One row per player.", Columns: []schemaColumn{
		{"steam_id", "character varying(64)", "SteamID64 as text."},
		{"kills", "integer", "Kills."},
		{"updated_at", "timestamp without time zone", ""},
	}}
	statsTest := stats
	statsTest.Columns = append(slices.Clone(stats.Columns), schemaColumn{"name", "character varying(128)", "Latest  Steam\nname."})
	return map[string][]schemaTable{
		"public": {stats},
		"insurgency-test": {statsTest, {Name: "smoke_warning_seen", Comment: "", Columns: []schemaColumn{
			{"steam_id", "bigint", "SteamID64 as bigint."},
		}}},
	}
}

func TestRenderSchemaDoc(t *testing.T) {
	s := testSchemas()
	byServer := map[string][]schemaTable{"main": s["public"], "test": s["insurgency-test"]}
	got := renderSchemaDoc([]string{"main", "test"}, byServer)
	want := schemaDocHeader + `
- player_stats: One row per player.
  - steam_id varchar(64): SteamID64 as text.
  - kills integer: Kills.
  - updated_at timestamp: (undocumented)
  - name varchar(128) (only on test): Latest Steam name.
- smoke_warning_seen (only on test): (undocumented)
  - steam_id bigint: SteamID64 as bigint.
` + schemaDocFooter
	if got != want {
		t.Errorf("renderSchemaDoc =\n%s\nwant\n%s", got, want)
	}
	// Deterministic: same input, same bytes, whatever the input order.
	slices.Reverse(byServer["test"])
	if again := renderSchemaDoc([]string{"main", "test"}, byServer); again != got {
		t.Error("rendering depends on the order tables arrive in")
	}
	if empty := renderSchemaDoc([]string{"main"}, nil); !strings.Contains(empty, "No tables are readable yet") {
		t.Errorf("empty = %q", empty)
	}
}

func TestRefreshQueryStatsDoc(t *testing.T) {
	cfg := &Config{
		StatsDBURL: "postgres:///",
		Servers: map[string]GameServer{
			"main": {Name: "main", StatsAPIURL: "http://x", StatsDBSchema: "public"},
			"test": {Name: "test", StatsAPIURL: "http://y", StatsDBSchema: "insurgency-test"},
		},
		ServerOrder: []string{"main", "test"},
	}
	db := &fakeStatsDB{tables: testSchemas()}
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, db)
	description := func() string {
		for _, p := range ts.Params() {
			if p.OfTool.Name == "query_stats" {
				return p.OfTool.Description.Value
			}
		}
		t.Fatal("no query_stats tool")
		return ""
	}
	if !strings.Contains(description(), "haven't loaded yet") {
		t.Errorf("before loading: %q", description())
	}

	ctx := context.Background()
	if changed, err := ts.refreshQueryStatsDoc(ctx); !changed || err != nil {
		t.Fatalf("first refresh: changed=%v err=%v", changed, err)
	}
	loaded, params := description(), ts.Params()
	if !strings.Contains(loaded, "- smoke_warning_seen (only on test)") {
		t.Errorf("loaded description:\n%s", loaded)
	}

	// Nothing changed: the tool list is left exactly as it was.
	if changed, err := ts.refreshQueryStatsDoc(ctx); changed || err != nil {
		t.Errorf("unchanged refresh: changed=%v err=%v", changed, err)
	}
	if after := ts.Params(); &after[0] != &params[0] {
		t.Error("an unchanged refresh rebuilt the tool list")
	}

	// A failed load keeps the last good description.
	db.schemaErr = errors.New("connection refused")
	if changed, err := ts.refreshQueryStatsDoc(ctx); changed || err == nil || description() != loaded {
		t.Errorf("failed refresh: changed=%v err=%v", changed, err)
	}

	// A real change replaces it, and earlier snapshots are untouched.
	db.schemaErr = nil
	db.tables["public"] = append(db.tables["public"], schemaTable{Name: "maps", Comment: "Playtime.", Columns: []schemaColumn{{"map_name", "varchar", "Map."}}})
	if changed, _ := ts.refreshQueryStatsDoc(ctx); !changed || !strings.Contains(description(), "- maps (only on main): Playtime.") {
		t.Errorf("changed refresh:\n%s", description())
	}
	for _, p := range params {
		if p.OfTool.Name == "query_stats" && p.OfTool.Description.Value != loaded {
			t.Error("a refresh changed a tool list handed out earlier")
		}
	}
}

// grantedTables reads the allowed table list from discord_bot_grants.sql.
func grantedTables(t *testing.T) []string {
	t.Helper()
	sql, err := os.ReadFile(filepath.Join(pgsqlScripts, "discord_bot_grants.sql"))
	if err != nil {
		t.Fatal(err)
	}
	list := regexp.MustCompile(`(?s)allowed text\[\] := ARRAY\[(.*?)\];`).FindSubmatch(sql)
	if list == nil {
		t.Fatal("no allowed table list in discord_bot_grants.sql")
	}
	var tables []string
	for _, m := range regexp.MustCompile(`'([a-z0-9_]+)'`).FindAllSubmatch(list[1], -1) {
		tables = append(tables, string(m[1]))
	}
	return tables
}

// TestGrantedTablesHaveComments checks, without a database, that every table
// granted to the bot is described by some plugin script, and that the IP log
// is never granted. TestSchemaFromMigrations checks the columns for real.
func TestGrantedTablesHaveComments(t *testing.T) {
	scripts, err := filepath.Glob(filepath.Join(pgsqlScripts, "*.sql"))
	if err != nil || len(scripts) == 0 {
		t.Fatalf("no scripts found: %v", err)
	}
	var all strings.Builder
	for _, f := range scripts {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		all.Write(b)
	}
	for _, table := range grantedTables(t) {
		if table == "connection_log" {
			t.Error("connection_log (IP addresses) must never be granted")
		}
		if !regexp.MustCompile(`COMMENT ON TABLE ` + table + ` IS`).MatchString(all.String()) {
			t.Errorf("table %s is granted but no script has COMMENT ON TABLE for it", table)
		}
	}
}

// migrationScripts lists one server's insurgency-stats migrations, in order,
// from its database-migrations.cfg.
func migrationScripts(t *testing.T, server string) []string {
	t.Helper()
	cfg, err := os.ReadFile("../../server config/" + server + "/opt/insurgency-server/insurgency/addons/sourcemod/configs/database-migrations.cfg")
	if err != nil {
		t.Fatal(err)
	}
	block := regexp.MustCompile(`(?s)"insurgency-stats"\s*\{(.*?)\}`).FindSubmatch(cfg)
	if block == nil {
		t.Fatalf("%s: no insurgency-stats migrations", server)
	}
	var files []string
	for _, line := range strings.Split(string(block[1]), "\n") {
		if m := regexp.MustCompile(`^\s*"[^"]+"\s+"configs/sql-init-scripts/pgsql/([^"]+)"`).FindStringSubmatch(line); m != nil {
			files = append(files, filepath.Join(pgsqlScripts, m[1]))
		}
	}
	return files
}

// TestSchemaFromMigrations runs both servers' real migrations, as their own
// roles and the way DatabaseMigrator does (each file in one transaction, every
// start), then loads the tables as the bot and checks what the model would see.
// Like TestPostgresStatsDB it needs STATSDB_TEST_ADMIN_URL.
func TestSchemaFromMigrations(t *testing.T) {
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
	exec := func(conn *pgx.Conn, sql string) error {
		_, err := conn.PgConn().Exec(ctx, sql).ReadAll()
		return err
	}
	for _, stmt := range []string{
		`DROP DATABASE IF EXISTS statsmig WITH (FORCE)`,
		`DROP ROLE IF EXISTS insurgency`, `DROP ROLE IF EXISTS "insurgency-test"`, `DROP ROLE IF EXISTS "discord-bot"`,
		`CREATE ROLE insurgency LOGIN PASSWORD 'pw'`,
		`CREATE ROLE "insurgency-test" LOGIN PASSWORD 'pw'`,
		`CREATE ROLE "discord-bot" LOGIN PASSWORD 'pw' CONNECTION LIMIT 2`,
		`CREATE DATABASE statsmig OWNER insurgency`,
	} {
		if err := exec(admin, stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
	cfg, _ := pgx.ParseConfig(adminURL)
	urlFor := func(role string) string {
		return fmt.Sprintf("postgres://%s:pw@%s:%d/statsmig?sslmode=disable", role, cfg.Host, cfg.Port)
	}
	adminMig, err := pgx.Connect(ctx, strings.Replace(adminURL, "/"+cfg.Database+"?", "/statsmig?", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer adminMig.Close(ctx)
	if err := exec(adminMig, `CREATE SCHEMA "insurgency-test" AUTHORIZATION "insurgency-test"`); err != nil {
		t.Fatal(err)
	}

	for _, run := range []struct{ role, server string }{{"insurgency", "main"}, {"insurgency-test", "test"}} {
		conn, err := pgx.Connect(ctx, urlFor(run.role))
		if err != nil {
			t.Fatal(err)
		}
		files := migrationScripts(t, run.server)
		if filepath.Base(files[len(files)-1]) != "discord_bot_grants.sql" {
			t.Errorf("%s: discord_bot_grants.sql must be the last migration", run.server)
		}
		for pass := 1; pass <= 2; pass++ { // every server start re-runs them
			for _, f := range files {
				sql, err := os.ReadFile(f)
				if err != nil {
					t.Fatal(err)
				}
				if err := exec(conn, "BEGIN;\n"+string(sql)+"\nCOMMIT;"); err != nil {
					t.Errorf("%s pass %d: %s: %v", run.server, pass, filepath.Base(f), err)
					exec(conn, "ROLLBACK")
				}
			}
		}
		conn.Close(ctx)
	}

	db, err := NewPostgresStatsDB(urlFor("discord-bot"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	schemas := map[string][]schemaTable{}
	for server, schema := range map[string]string{"main": "public", "test": "insurgency-test"} {
		if schemas[server], err = db.Schema(ctx, schema); err != nil {
			t.Fatal(err)
		}
	}
	doc := renderSchemaDoc([]string{"main", "test"}, schemas)
	if n := strings.Count(doc, undocumented); n > 0 {
		t.Errorf("%d tables or columns have no COMMENT:\n%s", n, doc)
	}
	if strings.Contains(doc, "connection_log") || strings.Contains(doc, "ip_address") {
		t.Error("the bot can see connection_log")
	}
	for _, table := range grantedTables(t) {
		if !strings.Contains(doc, "\n- "+table+" ") && !strings.Contains(doc, "\n- "+table+":") {
			t.Errorf("granted table %s missing from the doc", table)
		}
	}
	if !strings.Contains(doc, "\n- smoke_warning_seen (only on test):") {
		t.Errorf("smoke_warning_seen should be test-only:\n%s", doc)
	}
	t.Logf("doc is %d bytes:\n%s", len(doc), doc)
}
