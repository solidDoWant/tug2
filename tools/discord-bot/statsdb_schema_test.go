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

// migrationScripts lists one server's migrations for one database (its block
// in database-migrations.cfg, e.g. "insurgency-stats"), in order.
func migrationScripts(t *testing.T, server, database string) []string {
	t.Helper()
	cfg, err := os.ReadFile("../../server config/" + server + "/opt/insurgency-server/insurgency/addons/sourcemod/configs/database-migrations.cfg")
	if err != nil {
		t.Fatal(err)
	}
	block := regexp.MustCompile(`(?s)"` + regexp.QuoteMeta(database) + `"\s*\{(.*?)\}`).FindSubmatch(cfg)
	if block == nil {
		t.Fatalf("%s: no %s migrations", server, database)
	}
	var files []string
	for line := range strings.SplitSeq(string(block[1]), "\n") {
		if m := regexp.MustCompile(`^\s*"[^"]+"\s+"configs/sql-init-scripts/pgsql/([^"]+)"`).FindStringSubmatch(line); m != nil {
			files = append(files, filepath.Join(pgsqlScripts, m[1]))
		}
	}
	return files
}

// migratedDB is a throwaway database laid out like production, with both
// servers' real migrations for one database applied.
type migratedDB struct {
	name string
	// urlFor connects to it as a role (password "pw").
	urlFor func(role string) string
}

// migrationRoles creates the game servers' roles and the bot's, dropping the
// given databases first so the roles own nothing. Needs STATSDB_TEST_ADMIN_URL.
func migrationRoles(t *testing.T, ctx context.Context, admin *pgx.Conn, databases ...string) {
	t.Helper()
	var stmts []string
	for _, db := range databases {
		stmts = append(stmts, `DROP DATABASE IF EXISTS `+db+` WITH (FORCE)`)
	}
	stmts = append(stmts,
		`DROP ROLE IF EXISTS insurgency`, `DROP ROLE IF EXISTS "insurgency-test"`, `DROP ROLE IF EXISTS "discord-bot"`,
		`CREATE ROLE insurgency LOGIN PASSWORD 'pw'`,
		`CREATE ROLE "insurgency-test" LOGIN PASSWORD 'pw'`,
		`CREATE ROLE "discord-bot" LOGIN PASSWORD 'pw' CONNECTION LIMIT 3`)
	for _, stmt := range stmts {
		if err := execAll(ctx, admin, stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}
}

func execAll(ctx context.Context, conn *pgx.Conn, sql string) error {
	_, err := conn.PgConn().Exec(ctx, sql).ReadAll()
	return err
}

// migrateDatabase creates dbName (main's role owns it and uses public; test's
// role owns its own schema) and runs each server's migrations for block as
// that server's role, the way DatabaseMigrator does: each file in one
// transaction, twice, as every server start re-runs them. before lists
// scripts to run first, per server, for tables production already has.
func migrateDatabase(t *testing.T, ctx context.Context, adminURL, dbName, block string, before map[string][]string) migratedDB {
	t.Helper()
	admin, err := pgx.Connect(ctx, adminURL)
	if err != nil {
		t.Fatal(err)
	}
	defer admin.Close(ctx)
	if err := execAll(ctx, admin, `CREATE DATABASE `+dbName+` OWNER insurgency`); err != nil {
		t.Fatal(err)
	}
	cfg, _ := pgx.ParseConfig(adminURL)
	db := migratedDB{name: dbName, urlFor: func(role string) string {
		return fmt.Sprintf("postgres://%s:pw@%s:%d/%s?sslmode=disable", role, cfg.Host, cfg.Port, dbName)
	}}
	adminMig, err := pgx.Connect(ctx, strings.Replace(adminURL, "/"+cfg.Database+"?", "/"+dbName+"?", 1))
	if err != nil {
		t.Fatal(err)
	}
	defer adminMig.Close(ctx)
	if err := execAll(ctx, adminMig, `CREATE SCHEMA "insurgency-test" AUTHORIZATION "insurgency-test"`); err != nil {
		t.Fatal(err)
	}

	for _, run := range []struct{ role, server string }{{"insurgency", "main"}, {"insurgency-test", "test"}} {
		conn, err := pgx.Connect(ctx, db.urlFor(run.role))
		if err != nil {
			t.Fatal(err)
		}
		files := migrationScripts(t, run.server, block)
		if filepath.Base(files[len(files)-1]) != "discord_bot_grants.sql" {
			t.Errorf("%s %s: discord_bot_grants.sql must be the last migration", run.server, block)
		}
		var pre []string
		for _, f := range before[run.server] {
			pre = append(pre, filepath.Join(pgsqlScripts, f))
		}
		for pass := 1; pass <= 2; pass++ {
			list := files
			if pass == 1 {
				list = append(pre, files...)
			}
			for _, f := range list {
				sql, err := os.ReadFile(f)
				if err != nil {
					t.Fatal(err)
				}
				if err := execAll(ctx, conn, "BEGIN;\n"+string(sql)+"\nCOMMIT;"); err != nil {
					t.Errorf("%s pass %d: %s: %v", run.server, pass, filepath.Base(f), err)
					execAll(ctx, conn, "ROLLBACK")
				}
			}
		}
		conn.Close(ctx)
	}
	return db
}

// botSchemaDoc renders what the bot can read in a migrated database.
func botSchemaDoc(t *testing.T, ctx context.Context, db migratedDB) string {
	t.Helper()
	bot, err := NewPostgresStatsDB(db.urlFor("discord-bot"))
	if err != nil {
		t.Fatal(err)
	}
	defer bot.Close()
	schemas := map[string][]schemaTable{}
	for server, schema := range map[string]string{"main": "public", "test": "insurgency-test"} {
		if schemas[server], err = bot.Schema(ctx, schema); err != nil {
			t.Fatal(err)
		}
	}
	return renderSchemaDoc([]string{"main", "test"}, schemas)
}

// TestSchemaFromMigrations runs both servers' real migrations for each
// database the bot reads, as their own roles, then loads the tables as the
// bot and checks what it would see. Like TestPostgresStatsDB it needs
// STATSDB_TEST_ADMIN_URL.
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
	migrationRoles(t, ctx, admin, "statsmig", "loadoutmig")

	stats := botSchemaDoc(t, ctx, migrateDatabase(t, ctx, adminURL, "statsmig", "insurgency-stats", nil))
	// Main still has LoadoutSaver's legacy table, which must stay unreadable.
	loadouts := botSchemaDoc(t, ctx, migrateDatabase(t, ctx, adminURL, "loadoutmig", "loadoutsaver",
		map[string][]string{"main": {"loadout_saver.sql"}, "test": {"loadout_saver.sql"}}))

	for name, doc := range map[string]string{"insurgency-stats": stats, "loadoutsaver": loadouts} {
		if n := strings.Count(doc, undocumented); n > 0 {
			t.Errorf("%s: %d tables or columns have no COMMENT:\n%s", name, n, doc)
		}
		if strings.Contains(doc, "connection_log") || strings.Contains(doc, "ip_address") {
			t.Errorf("%s: the bot can see connection_log", name)
		}
	}
	for _, table := range grantedTables(t) {
		in := func(doc string) bool {
			return strings.Contains(doc, "\n- "+table+" ") || strings.Contains(doc, "\n- "+table+":")
		}
		if !in(stats) && !in(loadouts) {
			t.Errorf("granted table %s missing from both databases' docs", table)
		}
	}
	if !strings.Contains(stats, "\n- smoke_warning_seen (only on test):") {
		t.Errorf("smoke_warning_seen should be test-only:\n%s", stats)
	}
	for _, table := range []string{"loadouts_slots", "loadout_items", "theater_items"} {
		if !strings.Contains(loadouts, "\n- "+table+": ") {
			t.Errorf("loadoutsaver: %s should be readable on both servers:\n%s", table, loadouts)
		}
	}
	for _, hidden := range []string{"\n- loadouts:", "\n- loadouts ", "loadouts_slots_imports", "loadouts_import_theater_ids"} {
		if strings.Contains(loadouts, hidden) {
			t.Errorf("loadoutsaver: the bot can see %q:\n%s", strings.TrimSpace(hidden), loadouts)
		}
	}
	t.Logf("stats doc is %d bytes:\n%s", len(stats), stats)
	t.Logf("loadouts doc is %d bytes:\n%s", len(loadouts), loadouts)
}
