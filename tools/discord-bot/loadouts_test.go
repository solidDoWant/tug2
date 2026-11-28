package main

import (
	"context"
	"encoding/json"
	"math/rand/v2"
	"os/exec"
	"slices"
	"strings"
	"testing"
)

func testLoadoutData(t *testing.T) *loadoutData {
	t.Helper()
	d, err := embeddedLoadoutData()
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// TestLoadoutDataIsFresh fails when theater_loadouts.json no longer matches
// the theaters, like `make theater-check` does. Skipped without python3.
func TestLoadoutDataIsFresh(t *testing.T) {
	python, err := exec.LookPath("python3")
	if err != nil {
		t.Skip("python3 not installed")
	}
	cmd := exec.Command(python, "-B", "../theater-build/loadouts.py", "check")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
}

func TestLoadoutDataShape(t *testing.T) {
	d := testLoadoutData(t)
	for _, want := range []struct{ server, mode string }{{"main", "checkpoint"}, {"test", "checkpoint"}, {"test", "survival"}} {
		s := d.server(want.server)
		if s == nil || s.mode(want.mode) == nil {
			t.Fatalf("no data for %s %s", want.server, want.mode)
		}
		m := s.mode(want.mode)
		if len(m.Classes) == 0 || len(m.items.Weapons) == 0 || len(m.items.Upgrades) == 0 || len(m.items.Gear) == 0 || m.StartingSupply <= 0 {
			t.Errorf("%s %s looks empty: %d classes, supply %d", want.server, want.mode, len(m.Classes), m.StartingSupply)
		}
		for _, c := range m.Classes {
			for _, id := range c.Unlocked {
				_, w := m.items.Weapons[id]
				_, u := m.items.Upgrades[id]
				_, g := m.items.Gear[id]
				if !w && !u && !g {
					t.Errorf("%s %s %s unlocks unknown item %s", want.server, want.mode, c.Name, id)
				}
			}
		}
		for id, u := range m.items.Upgrades {
			for _, w := range u.Weapons {
				if _, ok := m.items.Weapons[w]; !ok {
					t.Errorf("%s fits unknown weapon %s", id, w)
				}
			}
		}
	}
	// Survival is played as the insurgents, on its own small starting supply.
	if m := d.server("test").mode("survival"); m.Team != "insurgents" || m.StartingSupply >= 10 {
		t.Errorf("survival: team %s, supply %d", m.Team, m.StartingSupply)
	}
	if m := d.server("main").mode("checkpoint"); m.Team != "security" || m.StartingSupply != 120 {
		t.Errorf("main checkpoint: team %s, supply %d", m.Team, m.StartingSupply)
	}
	// Class restrictions come through: only support may buy an LMG, only the medic a defib.
	m := d.server("main").mode("checkpoint")
	support, _ := m.findClass("support")
	rifleman, _ := m.findClass("rifleman")
	medic, _ := m.findClass("medic")
	if support == nil || rifleman == nil || medic == nil {
		t.Fatal("missing classes")
	}
	if !unlocked(support, "weapon_m249", m.items.Weapons["weapon_m249"].Restricted) || unlocked(rifleman, "weapon_m249", m.items.Weapons["weapon_m249"].Restricted) {
		t.Error("the M249 should be support-only")
	}
	if !unlocked(medic, "weapon_defib", true) || unlocked(rifleman, "weapon_defib", m.items.Weapons["weapon_defib"].Restricted) {
		t.Error("the defib should be medic-only")
	}
}

// TestGeneratedLoadoutsAreValid generates many loadouts for every server,
// mode, class and build, and checks each against the theater rules.
func TestGeneratedLoadoutsAreValid(t *testing.T) {
	d := testLoadoutData(t)
	rng := rand.New(rand.NewPCG(1, 2))
	for _, s := range d.Servers {
		for _, m := range s.Modes {
			for _, c := range m.Classes {
				made := 0
				for _, build := range loadoutBuilds {
					for i := 0; i < 20; i++ {
						budget := m.StartingSupply
						if i%3 == 1 {
							budget = min(budget, 1+rng.IntN(12))
						}
						l, ok := generateLoadout(rng, d.BaseWeaponSlots, m, loadoutRequest{class: c, budget: budget, build: build})
						if !ok {
							continue
						}
						if err := validateLoadout(d.BaseWeaponSlots, m, c, l, budget); err != nil {
							t.Fatalf("%s %s %s %s budget %d: %v\n%+v", s.Name, m.Mode, c.Name, build, budget, err, l)
						}
						made++
					}
				}
				if made < 60 {
					t.Errorf("%s %s %s: only %d of 80 attempts made a loadout", s.Name, m.Mode, c.Name, made)
				}
			}
		}
	}
}

func TestValidateLoadoutRejects(t *testing.T) {
	d := testLoadoutData(t)
	m := d.server("main").mode("checkpoint")
	rifleman, _ := m.findClass("rifleman")
	item := func(id string) LoadoutItem {
		if w, ok := m.items.Weapons[id]; ok {
			return LoadoutItem{ID: id, Name: w.Name, Slot: w.Slot, Cost: w.Cost}
		}
		if g, ok := m.items.Gear[id]; ok {
			return LoadoutItem{ID: id, Name: g.Name, Slot: g.Slot, Cost: g.Cost}
		}
		u := m.items.Upgrades[id]
		return LoadoutItem{ID: id, Name: u.Name, Slot: u.Slot, Cost: u.Cost}
	}
	weapon := func(id string, upgrades ...string) LoadoutWeapon {
		w := LoadoutWeapon{LoadoutItem: item(id), Category: m.items.Weapons[id].Class}
		for _, u := range upgrades {
			w.Attachments = append(w.Attachments, item(u))
		}
		return w
	}
	total := func(l Loadout) Loadout {
		l.Cost = 0
		for _, g := range l.Gear {
			l.Cost += g.Cost
		}
		for _, w := range l.Weapons {
			l.Cost += w.Cost
			for _, a := range w.Attachments {
				l.Cost += a.Cost
			}
		}
		return l
	}
	good := total(Loadout{Gear: []LoadoutItem{item("sec_heavy_armor"), item("sec_chest_rig")},
		Weapons: []LoadoutWeapon{weapon("weapon_m4a1", "optic_aimpoint", "underbarrel_foregrip_sec1"), weapon("weapon_m9"), weapon("weapon_m67")}})
	if err := validateLoadout(d.BaseWeaponSlots, m, rifleman, good, m.StartingSupply); err != nil {
		t.Fatalf("the stock-like kit is rejected: %v", err)
	}
	cases := map[string]Loadout{
		"class restricted":        total(Loadout{Weapons: []LoadoutWeapon{weapon("weapon_m249")}}),
		"two optics":              total(Loadout{Weapons: []LoadoutWeapon{weapon("weapon_m4a1", "optic_aimpoint", "optic_kobra")}}),
		"upgrade doesn't fit":     total(Loadout{Weapons: []LoadoutWeapon{weapon("weapon_m9", "optic_aimpoint")}}),
		"explosive, no vest":      total(Loadout{Gear: []LoadoutItem{item("sec_heavy_armor")}, Weapons: []LoadoutWeapon{weapon("weapon_m67")}}),
		"two vests":               total(Loadout{Gear: []LoadoutItem{item("sec_chest_rig"), item("sec_chest_carrier")}}),
		"two primaries":           total(Loadout{Weapons: []LoadoutWeapon{weapon("weapon_m4a1"), weapon("weapon_akm")}}),
		"knife, pistol, no sling": total(Loadout{Weapons: []LoadoutWeapon{weapon("weapon_m9"), weapon("weapon_kabar")}}),
	}
	if _, ok := m.items.Upgrades["optic_kobra"]; !ok {
		delete(cases, "two optics")
	}
	for name, l := range cases {
		if err := validateLoadout(d.BaseWeaponSlots, m, rifleman, l, m.StartingSupply); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := validateLoadout(d.BaseWeaponSlots, m, rifleman, good, good.Cost-1); err == nil {
		t.Error("over budget: accepted")
	}
}

func TestRandomLoadoutTool(t *testing.T) {
	cfg := &Config{
		Servers:     map[string]GameServer{"main": {Name: "main"}, "test": {Name: "test"}},
		ServerOrder: []string{"main", "test"},
	}
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, nil, nil)
	run := func(input string) (map[string]any, error) {
		out, err := ts.Run(context.Background(), &toolContext{}, "random_loadout", json.RawMessage(input))
		if err != nil {
			return nil, err
		}
		b, _ := json.Marshal(out)
		var m map[string]any
		json.Unmarshal(b, &m)
		return m, nil
	}
	out, err := run(`{}`)
	if err != nil || out["server"] != "main" || out["mode"] != "checkpoint" || len(out["loadouts"].([]any)) != 1 {
		t.Fatalf("default: %v %v", out, err)
	}
	out, err = run(`{"server":"test","class":"support","category":"lmg","build":"loaded","count":3}`)
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range out["loadouts"].([]any) {
		l := l.(map[string]any)
		if l["class"] != "support" {
			t.Errorf("class %v", l["class"])
		}
		hasLMG := slices.ContainsFunc(l["weapons"].([]any), func(w any) bool { return w.(map[string]any)["category"] == "lmg" })
		if !hasLMG {
			t.Errorf("no lmg in %v", l)
		}
	}
	out, err = run(`{"server":"test","mode":"survival"}`)
	if err != nil || out["team"] != "insurgents" {
		t.Errorf("survival: %v %v", out, err)
	}
	if out, err := run(`{"budget":5}`); err != nil || out["loadouts"].([]any)[0].(map[string]any)["cost"].(float64) > 5 {
		t.Errorf("budget: %v %v", out, err)
	}
	for _, bad := range []string{`{"class":"pilot"}`, `{"mode":"firefight"}`, `{"build":"tank"}`, `{"server":"other"}`, `{"class":"rifleman","category":"lmg"}`} {
		if _, err := run(bad); err == nil {
			t.Errorf("%s: no error", bad)
		}
	}
	t.Logf("sample: %v", out)
	desc := ts.tools["random_loadout"].param.Description.Value
	if !strings.Contains(desc, "nothing is applied in game") || !strings.Contains(desc, "main checkpoint") {
		t.Errorf("description: %s", desc)
	}
	if !strings.Contains(buildSystemPrompt(cfg, false), "random_loadout") {
		t.Error("system prompt doesn't mention random_loadout")
	}

	// Not offered for servers the data doesn't cover.
	other := &Config{Servers: map[string]GameServer{"other": {Name: "other"}}, ServerOrder: []string{"other"}}
	if _, ok := NewToolset(other, NewStatsClient(other.Servers), nil, nil, nil).tools["random_loadout"]; ok {
		t.Error("offered with no matching server")
	}
	if strings.Contains(buildSystemPrompt(other, false), "random_loadout") {
		t.Error("system prompt mentions random_loadout without the tool")
	}
}
