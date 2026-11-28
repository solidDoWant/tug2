package main

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func ptr[T any](v T) *T { return &v }

func TestShortClass(t *testing.T) {
	for in, want := range map[string]string{
		"template_rifleman_security_coop":            "rifleman",
		"template_designated_marksman_security_coop": "designated_marksman",
		"template_combat_medic":                      "combat_medic",
		"template_coop_fighter":                      "coop_fighter",
		"something_else":                             "something_else",
	} {
		if got := shortClass(in); got != want {
			t.Errorf("shortClass(%q) = %q, want %q", in, got, want)
		}
	}
}

// sampleLoadoutRows is what the query returns for one player: a class loadout
// with gear, a kitted rifle, a pistol and three grenades, and an empty named
// loadout.
func sampleLoadoutRows() []loadoutRow {
	saved := time.Date(2026, 11, 20, 18, 30, 0, 0, time.FixedZone("x", -5*3600))
	item := func(ord int, slot, parent *int, qty, cat int, name string) loadoutRow {
		return loadoutRow{LoadoutID: 7, ClassTemplate: "template_rifleman_security_coop", UpdatedAt: &saved, CreatedAt: &saved,
			UpdateCount: 3, Ordinal: ptr(ord), Slot: slot, Parent: parent, Quantity: ptr(qty), Category: ptr(cat), Item: name}
	}
	return []loadoutRow{
		item(0, nil, nil, 1, 3, "sec_heavy_armor"),
		item(1, nil, nil, 1, 3, "sec_tactical_carrier"),
		item(2, ptr(0), nil, 1, 0, "weapon_m4a1"),
		item(3, nil, ptr(2), 1, 1, "optic_aimpoint"),
		item(4, nil, ptr(2), 1, 1, "underbarrel_foregrip_sec1"),
		item(5, ptr(1), nil, 1, 0, "weapon_m9"),
		item(6, ptr(3), nil, 3, 0, "weapon_m67"),
		item(7, nil, ptr(9), 1, 1, "ammo_ap_m9"),
		{LoadoutID: 9, Name: ptr("Night Ops"), ClassTemplate: "template_recon_security_coop", UpdateCount: 1},
	}
}

func TestAssembleLoadouts(t *testing.T) {
	got := mustJSON(assembleLoadouts(sampleLoadoutRows()))
	want := `[{"kind":"class","class":"rifleman","class_template":"template_rifleman_security_coop",` +
		`"gear":["sec_heavy_armor","sec_tactical_carrier"],"weapons":[` +
		`{"slot":"primary","weapon":"m4a1","upgrades":["optic_aimpoint","underbarrel_foregrip_sec1"]},` +
		`{"slot":"secondary","weapon":"m9"},{"slot":"explosive","weapon":"m67","quantity":3}],` +
		`"unattached_upgrades":["ammo_ap_m9"],"last_saved":"2026-11-20 23:30","first_saved":"2026-11-20 23:30","times_saved":3},` +
		`{"name":"Night Ops","kind":"named","class":"recon","class_template":"template_recon_security_coop","empty":true,"times_saved":1}]`
	if got != want {
		t.Errorf("assembleLoadouts =\n%s\nwant\n%s", got, want)
	}
}

type fakeLoadoutDB struct {
	schema  string
	steamID uint64
	rows    []loadoutRow
}

func (f *fakeLoadoutDB) SavedLoadouts(_ context.Context, schema string, steamID uint64) ([]loadoutRow, error) {
	f.schema, f.steamID = schema, steamID
	return f.rows, nil
}

func TestSavedLoadoutsTool(t *testing.T) {
	cfg := &Config{
		LoadoutDBURL: "postgres:///",
		Servers: map[string]GameServer{
			"main":  {Name: "main", StatsAPIURL: "http://x", LoadoutDBSchema: "public"},
			"test":  {Name: "test", StatsAPIURL: "http://y", LoadoutDBSchema: "insurgency-test"},
			"other": {Name: "other", StatsAPIURL: "http://z"},
		},
		ServerOrder: []string{"main", "test", "other"},
	}
	db := &fakeLoadoutDB{rows: sampleLoadoutRows()}
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, nil)
	ts.AddSavedLoadoutsTool(cfg, db)
	found := false
	for _, p := range ts.Params() {
		found = found || p.OfTool.Name == "get_saved_loadouts"
	}
	if !found {
		t.Fatal("get_saved_loadouts not in the tool list")
	}
	run := func(input string) (map[string]any, error) {
		res, err := ts.Run(context.Background(), &toolContext{}, "get_saved_loadouts", json.RawMessage(input))
		m, _ := res.(map[string]any)
		return m, err
	}

	res, err := run(`{"steam_id":"76561198000000001"}`)
	if err != nil || db.schema != "public" || db.steamID != 76561198000000001 || res["count"] != 2 {
		t.Errorf("default server: %v, schema %q, steam id %d, %v", err, db.schema, db.steamID, res)
	}
	if res, err := run(`{"steam_id":"76561198000000001","server":"test","loadout":"night"}`); err != nil || db.schema != "insurgency-test" || res["count"] != 1 {
		t.Errorf("test server, filtered by name: %v, schema %q, %v", err, db.schema, res)
	}
	if res, err := run(`{"steam_id":"76561198000000001","loadout":"rifleman"}`); err != nil || res["count"] != 1 {
		t.Errorf("filtered by class: %v, %v", err, res)
	}
	if res, err := run(`{"steam_id":"76561198000000001","loadout":"sniper"}`); err != nil || res["count"] != 0 || res["note"] == nil {
		t.Errorf("no match: %v, %v", err, res)
	}
	for _, bad := range []string{`{"steam_id":"123"}`, `{"steam_id":"7656119800000000x"}`, `{"steam_id":"76561198000000001","server":"other"}`, `{}`, `{"steam_id":"76561198000000001","sql":"x"}`} {
		if _, err := run(bad); err == nil {
			t.Errorf("%s: no error", bad)
		}
	}
	if !strings.Contains(buildSystemPrompt(cfg, false), "get_saved_loadouts") {
		t.Error("system prompt doesn't mention get_saved_loadouts")
	}

	// Not offered without a database URL, a database, or a server with a schema.
	for name, setup := range map[string]func(*Config) (*Config, loadoutDB){
		"no url": func(c *Config) (*Config, loadoutDB) { c.LoadoutDBURL = ""; return c, db },
		"no db":  func(c *Config) (*Config, loadoutDB) { return c, nil },
		"no schema": func(c *Config) (*Config, loadoutDB) {
			c.Servers = map[string]GameServer{"main": {Name: "main", StatsAPIURL: "http://x"}}
			c.ServerOrder = []string{"main"}
			return c, db
		},
	} {
		c := *cfg
		cc, d := setup(&c)
		ts := NewToolset(cc, NewStatsClient(cc.Servers), nil, nil, nil)
		ts.AddSavedLoadoutsTool(cc, d)
		if _, ok := ts.tools["get_saved_loadouts"]; ok {
			t.Errorf("%s: offered", name)
		}
		if strings.Contains(buildSystemPrompt(cc, false), "get_saved_loadouts") && name != "no db" {
			t.Errorf("%s: system prompt mentions get_saved_loadouts", name)
		}
	}
}

// TestPostgresLoadoutDB saves loadouts the way LoadoutSaverSlots does into a
// database built by both servers' real loadoutsaver migrations, then reads
// them back as the bot. Needs STATSDB_TEST_ADMIN_URL, like TestPostgresStatsDB.
func TestPostgresLoadoutDB(t *testing.T) {
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
	db := migrateDatabase(t, ctx, adminURL, "loadoutmig", "loadoutsaver",
		map[string][]string{"main": {"loadout_saver.sql"}, "test": {"loadout_saver.sql"}})

	// The plugin's own save statements (LoadoutSaverSlots.sp SaveLoadoutToDatabase), as main's role.
	game, err := pgx.Connect(ctx, db.urlFor("insurgency"))
	if err != nil {
		t.Fatal(err)
	}
	defer game.Close(ctx)
	for _, stmt := range []string{
		`INSERT INTO theater_items (category, name) VALUES (3, 'sec_heavy_armor'), (0, 'weapon_m4a1'), (1, 'optic_aimpoint'), (0, 'weapon_m67') ON CONFLICT (category, name) DO NOTHING`,
		`INSERT INTO loadouts_slots (steam_id, class_template, name, updated_at, update_count) VALUES (76561198000000001, 'template_rifleman_security_coop', NULL, CURRENT_TIMESTAMP, 1)`,
		`INSERT INTO loadouts_slots (steam_id, class_template, name, updated_at, update_count) VALUES (76561198000000001, 'template_recon_security_coop', 'Quiet', CURRENT_TIMESTAMP, 2)`,
		`INSERT INTO loadouts_slots (steam_id, class_template, name) VALUES (76561198000000002, 'template_rifleman_security_coop', NULL)`,
		`INSERT INTO loadout_items (loadout_id, ordinal, item_id, slot, parent_ordinal, quantity)
		 SELECT l.id, v.ord, ti.id, v.slot, v.parent, v.qty FROM loadouts_slots l CROSS JOIN (VALUES
		   (0, 3, 'sec_heavy_armor', NULL::smallint, NULL::smallint, 1),
		   (1, 0, 'weapon_m4a1', 0, NULL, 1),
		   (2, 1, 'optic_aimpoint', NULL, 1, 1),
		   (3, 0, 'weapon_m67', 3, NULL, 2)) AS v(ord, cat, item, slot, parent, qty)
		 JOIN theater_items ti ON ti.category = v.cat AND ti.name = v.item
		 WHERE l.steam_id = 76561198000000001 AND l.name IS NULL`,
		// The legacy table holds theater ids; the bot must not be able to read it.
		`INSERT INTO loadouts (steam_id, class_template, gear, primary_weapon) VALUES (76561198000000001, 'template_rifleman_security_coop', '3;4', '17;88')`,
	} {
		if _, err := game.Exec(ctx, stmt); err != nil {
			t.Fatalf("%s: %v", stmt, err)
		}
	}

	bot, err := NewPostgresLoadoutDB(db.urlFor("discord-bot"))
	if err != nil {
		t.Fatal(err)
	}
	defer bot.Close()
	rows, err := bot.SavedLoadouts(ctx, "public", 76561198000000001)
	if err != nil {
		t.Fatal(err)
	}
	loadouts := assembleLoadouts(rows)
	for i := range loadouts { // timestamps vary; checked separately
		if loadouts[i].SavedAt == "" {
			t.Errorf("loadout %d has no save time", i)
		}
		saved, err := time.Parse("2006-01-02 15:04", loadouts[i].SavedAt)
		if err != nil || time.Since(saved) > 2*time.Minute || time.Since(saved) < -2*time.Minute {
			t.Errorf("loadout %d saved at %q, not about now in UTC", i, loadouts[i].SavedAt)
		}
		loadouts[i].SavedAt, loadouts[i].CreatedAt = "", ""
	}
	want := `[{"kind":"class","class":"rifleman","class_template":"template_rifleman_security_coop","gear":["sec_heavy_armor"],` +
		`"weapons":[{"slot":"primary","weapon":"m4a1","upgrades":["optic_aimpoint"]},{"slot":"explosive","weapon":"m67","quantity":2}],"times_saved":1},` +
		`{"name":"Quiet","kind":"named","class":"recon","class_template":"template_recon_security_coop","empty":true,"times_saved":2}]`
	if got := mustJSON(loadouts); got != want {
		t.Errorf("loadouts =\n%s\nwant\n%s", got, want)
	}
	if rows, err := bot.SavedLoadouts(ctx, "insurgency-test", 76561198000000001); err != nil || len(rows) != 0 {
		t.Errorf("test schema: %v, %d rows", err, len(rows))
	}

	// Everything else in the database stays unreadable.
	conn, err := pgx.Connect(ctx, db.urlFor("discord-bot"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	for _, table := range []string{"loadouts", "loadouts_slots_imports", "loadouts_import_theater_ids", `"insurgency-test".loadouts`} {
		if _, err := conn.Exec(ctx, "SELECT * FROM "+table); err == nil || !strings.Contains(err.Error(), "permission denied") {
			t.Errorf("SELECT from %s: %v, want permission denied", table, err)
		}
	}
}
