package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"slices"
	"strings"
	"sync"
)

// random_loadout suggests loadouts a class could actually buy on a server. It
// is text only: nothing is applied in game, and it knows nothing about who is
// asking.
//
// Validity comes from theater_loadouts.json, generated from the theaters the
// servers load by tools/theater-build/loadouts.py (`make theater-build`; `make
// theater-check` fails while it is stale, and so does TestLoadoutDataIsFresh
// where python3 is available). That script's docstring says which rules are
// read from the theater and which are assumed. The rules are applied twice:
// generation only picks items that fit, and every suggestion is then checked
// by validateLoadout before it is returned, which is also what the tests use.

//go:embed theater_loadouts.json
var theaterLoadoutsJSON []byte

type loadoutData struct {
	Servers         []*loadoutServer         `json:"servers"`
	Items           map[string]*theaterItems `json:"items"`
	BaseWeaponSlots map[string]int           `json:"base_weapon_slots"`
}

type loadoutServer struct {
	Name    string         `json:"name"`
	Theater string         `json:"theater"`
	Modes   []*loadoutMode `json:"modes"`
}

type loadoutMode struct {
	Mode           string          `json:"mode"`
	Team           string          `json:"team"`
	StartingSupply int             `json:"starting_supply"`
	ItemsKey       string          `json:"items"`
	Classes        []*loadoutClass `json:"classes"`
	items          *theaterItems
}

type loadoutClass struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Unlocked []string `json:"unlocked"`
}

type theaterItems struct {
	Weapons  map[string]*theaterWeapon  `json:"weapons"`
	Upgrades map[string]*theaterUpgrade `json:"upgrades"`
	Gear     map[string]*theaterGear    `json:"gear,omitempty"`
}

type theaterWeapon struct {
	Name       string `json:"name"`
	Slot       string `json:"slot"`
	Class      string `json:"class"`
	Cost       int    `json:"cost"`
	Restricted bool   `json:"restricted"`
}

type theaterUpgrade struct {
	Name       string   `json:"name"`
	Slot       string   `json:"slot"`
	Cost       int      `json:"cost"`
	Weapons    []string `json:"weapons"`
	Restricted bool     `json:"restricted"`
	Excludes   []string `json:"excludes"`
	Locks      string   `json:"locks"`
}

type theaterGear struct {
	Name        string         `json:"name"`
	Slot        string         `json:"slot"`
	Cost        int            `json:"cost"`
	Restricted  bool           `json:"restricted"`
	WeaponSlots map[string]int `json:"weapon_slots"`
}

// embeddedLoadoutData parses theater_loadouts.json once.
var embeddedLoadoutData = sync.OnceValues(func() (*loadoutData, error) {
	return loadLoadoutData(theaterLoadoutsJSON)
})

func loadLoadoutData(raw []byte) (*loadoutData, error) {
	var d loadoutData
	if err := json.Unmarshal(raw, &d); err != nil {
		return nil, err
	}
	for _, s := range d.Servers {
		for _, m := range s.Modes {
			if m.items = d.Items[m.ItemsKey]; m.items == nil {
				return nil, fmt.Errorf("%s %s: no items %q", s.Name, m.Mode, m.ItemsKey)
			}
		}
	}
	return &d, nil
}

func (d *loadoutData) server(name string) *loadoutServer {
	for _, s := range d.Servers {
		if s.Name == name {
			return s
		}
	}
	return nil
}

func (s *loadoutServer) mode(name string) *loadoutMode {
	for _, m := range s.Modes {
		if m.Mode == name {
			return m
		}
	}
	return nil
}

func (m *loadoutMode) classNames() []string {
	var out []string
	for _, c := range m.Classes {
		out = append(out, c.Name)
	}
	return out
}

// findClass matches a class by name or template id, whole or in part.
func (m *loadoutMode) findClass(query string) (*loadoutClass, error) {
	q := strings.ToLower(strings.TrimSpace(query))
	for _, c := range m.Classes {
		if q == c.Name || q == strings.ToLower(c.ID) {
			return c, nil
		}
	}
	var matches []*loadoutClass
	for _, c := range m.Classes {
		if strings.Contains(c.Name, q) || strings.Contains(strings.ToLower(c.ID), q) {
			matches = append(matches, c)
		}
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	return nil, fmt.Errorf("no single class matches %q in %s; the classes are: %s", query, m.Mode, strings.Join(m.classNames(), ", "))
}

// Loadout is one suggestion, as the model sees it.
type Loadout struct {
	Class   string          `json:"class"`
	Gear    []LoadoutItem   `json:"gear,omitempty"`
	Weapons []LoadoutWeapon `json:"weapons"`
	Cost    int             `json:"cost"`
}

type LoadoutItem struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Slot string `json:"slot"`
	Cost int    `json:"cost"`
}

type LoadoutWeapon struct {
	LoadoutItem
	Category    string        `json:"category"`
	Attachments []LoadoutItem `json:"attachments,omitempty"`
}

// Build styles the tool offers.
var loadoutBuilds = []string{"random", "cheap", "loaded", "minimal"}

type loadoutRequest struct {
	class    *loadoutClass
	category string // weapon class one of the weapons must have; "" for any
	budget   int
	build    string
}

func unlocked(c *loadoutClass, id string, restricted bool) bool {
	return !restricted || slices.Contains(c.Unlocked, id)
}

// weaponSlotOf is the slot a weapon takes up. Melee weapons share the
// secondary slots (see tools/theater-build/loadouts.py).
func weaponSlotOf(w *theaterWeapon) string {
	if w.Slot == "melee" {
		return "secondary"
	}
	return w.Slot
}

func slotCapacity(base map[string]int, items *theaterItems, gear []LoadoutItem) map[string]int {
	capacity := map[string]int{}
	for k, v := range base {
		capacity[k] = v
	}
	for _, g := range gear {
		for k, v := range items.Gear[g.ID].WeaponSlots {
			capacity[k] += v
		}
	}
	return capacity
}

// validateLoadout checks a loadout against the theater: everything is sold to
// the class, one gear item per gear slot, no more weapons than slots, every
// attachment fits its weapon and the others on it, and the total is within
// budget (itself never above the starting supply).
func validateLoadout(base map[string]int, m *loadoutMode, c *loadoutClass, l Loadout, budget int) error {
	items := m.items
	if budget > m.StartingSupply {
		return fmt.Errorf("budget %d is above the starting supply %d", budget, m.StartingSupply)
	}
	total := 0
	gearSlots := map[string]bool{}
	for _, g := range l.Gear {
		def, ok := items.Gear[g.ID]
		switch {
		case !ok:
			return fmt.Errorf("unknown gear %s", g.ID)
		case !unlocked(c, g.ID, def.Restricted):
			return fmt.Errorf("%s is not sold to %s", g.ID, c.Name)
		case gearSlots[def.Slot]:
			return fmt.Errorf("two gear items in slot %s", def.Slot)
		case g.Cost != def.Cost:
			return fmt.Errorf("%s cost %d, not %d", g.ID, def.Cost, g.Cost)
		}
		gearSlots[def.Slot] = true
		total += def.Cost
	}
	capacity := slotCapacity(base, items, l.Gear)
	used := map[string]int{}
	seen := map[string]bool{}
	for _, w := range l.Weapons {
		def, ok := items.Weapons[w.ID]
		switch {
		case !ok:
			return fmt.Errorf("unknown weapon %s", w.ID)
		case !unlocked(c, w.ID, def.Restricted):
			return fmt.Errorf("%s is not sold to %s", w.ID, c.Name)
		case seen[w.ID]:
			return fmt.Errorf("%s twice", w.ID)
		case w.Cost != def.Cost:
			return fmt.Errorf("%s cost %d, not %d", w.ID, def.Cost, w.Cost)
		}
		seen[w.ID] = true
		used[weaponSlotOf(def)]++
		total += def.Cost
		if err := checkAttachments(items, c, w); err != nil {
			return err
		}
		for _, a := range w.Attachments {
			total += items.Upgrades[a.ID].Cost
		}
	}
	for slot, n := range used {
		if n > capacity[slot] {
			return fmt.Errorf("%d %s weapons but %d %s slots", n, slot, capacity[slot], slot)
		}
	}
	if total != l.Cost {
		return fmt.Errorf("cost is %d, not %d", total, l.Cost)
	}
	if total > budget {
		return fmt.Errorf("cost %d is over the budget %d", total, budget)
	}
	return nil
}

func checkAttachments(items *theaterItems, c *loadoutClass, w LoadoutWeapon) error {
	slots := map[string]bool{}
	locked := map[string]bool{}
	ids := map[string]bool{}
	for _, a := range w.Attachments {
		def, ok := items.Upgrades[a.ID]
		switch {
		case !ok:
			return fmt.Errorf("unknown upgrade %s", a.ID)
		case !unlocked(c, a.ID, def.Restricted):
			return fmt.Errorf("%s is not sold to %s", a.ID, c.Name)
		case !slices.Contains(def.Weapons, w.ID):
			return fmt.Errorf("%s does not fit %s", a.ID, w.ID)
		case slots[def.Slot]:
			return fmt.Errorf("two %s upgrades on %s", def.Slot, w.ID)
		case a.Cost != def.Cost:
			return fmt.Errorf("%s cost %d, not %d", a.ID, def.Cost, a.Cost)
		}
		slots[def.Slot] = true
		ids[a.ID] = true
		if def.Locks != "" {
			locked[def.Locks] = true
		}
	}
	for _, a := range w.Attachments {
		def := items.Upgrades[a.ID]
		if locked[def.Slot] {
			return fmt.Errorf("%s is in a slot another upgrade on %s locks", a.ID, w.ID)
		}
		for _, x := range def.Excludes {
			if ids[x] {
				return fmt.Errorf("%s and %s exclude each other", a.ID, x)
			}
		}
	}
	return nil
}

// fitsAttachment reports whether upgrade id can go on w next to what is there.
func fitsAttachment(items *theaterItems, w LoadoutWeapon, id string) bool {
	def := items.Upgrades[id]
	for _, a := range w.Attachments {
		other := items.Upgrades[a.ID]
		if other.Slot == def.Slot || other.Locks == def.Slot || def.Locks == other.Slot ||
			slices.Contains(other.Excludes, id) || slices.Contains(def.Excludes, a.ID) {
			return false
		}
	}
	return true
}

// generateLoadout builds one loadout greedily: gear, then weapons slot by
// slot, then attachments, each pick only from what is still affordable and
// fits. It can fail (e.g. no weapon of the category fits the budget), so the
// caller retries.
func generateLoadout(rng *rand.Rand, base map[string]int, m *loadoutMode, req loadoutRequest) (Loadout, bool) {
	items, c := m.items, req.class
	left := req.budget
	l := Loadout{Class: c.Name}
	cheap := func(cost int) bool { return req.build != "cheap" || cost <= 1 }

	// Gear: one per slot. Armour and the vest decide what can be carried, so
	// "random" picks them most of the time and the rest half the time.
	gearBySlot := map[string][]string{}
	for _, id := range sortedKeys(items.Gear) {
		g := items.Gear[id]
		if unlocked(c, id, g.Restricted) {
			gearBySlot[g.Slot] = append(gearBySlot[g.Slot], id)
		}
	}
	for _, slot := range sortedKeys(gearBySlot) {
		chance := 0.5
		switch {
		case slot == "armor":
			chance = 1
		case req.build == "minimal":
			chance = 0
		case slot == "vest" || req.build == "loaded":
			chance = 0.85
		}
		if rng.Float64() >= chance {
			continue
		}
		// Gear that takes a weapon slot away (secondary2_sling trades the primary
		// for a second secondary) only in random builds without a category: it
		// would leave the others, and most categories, nowhere to go.
		trades := req.build == "random" && req.category == "" && rng.Float64() < 0.25
		var options []string
		for _, id := range gearBySlot[slot] {
			g := items.Gear[id]
			removes := slices.ContainsFunc(sortedKeys(g.WeaponSlots), func(k string) bool { return g.WeaponSlots[k] < 0 })
			if g.Cost <= left && cheap(g.Cost) && (!removes || trades) {
				options = append(options, id)
			}
		}
		if len(options) == 0 {
			continue
		}
		id := options[rng.IntN(len(options))]
		g := items.Gear[id]
		l.Gear = append(l.Gear, LoadoutItem{ID: id, Name: g.Name, Slot: g.Slot, Cost: g.Cost})
		left -= g.Cost
	}
	capacity := slotCapacity(base, items, l.Gear)

	// Weapons available to the class, by the slot they take up.
	bySlot := map[string][]string{}
	for _, id := range sortedKeys(items.Weapons) {
		w := items.Weapons[id]
		if unlocked(c, id, w.Restricted) {
			bySlot[weaponSlotOf(w)] = append(bySlot[weaponSlotOf(w)], id)
		}
	}
	taken := map[string]bool{}
	add := func(id string) {
		w := items.Weapons[id]
		l.Weapons = append(l.Weapons, LoadoutWeapon{
			LoadoutItem: LoadoutItem{ID: id, Name: w.Name, Slot: w.Slot, Cost: w.Cost}, Category: w.Class})
		left -= w.Cost
		taken[id] = true
		capacity[weaponSlotOf(w)]--
	}
	pick := func(slot string, want func(*theaterWeapon) bool) bool {
		if capacity[slot] <= 0 {
			return false
		}
		var options []string
		for _, id := range bySlot[slot] {
			if w := items.Weapons[id]; !taken[id] && w.Cost <= left && cheap(w.Cost) && want(w) {
				options = append(options, id)
			}
		}
		if len(options) == 0 {
			return false
		}
		add(options[rng.IntN(len(options))])
		return true
	}
	anyWeapon := func(*theaterWeapon) bool { return true }

	// The requested category goes first, so the budget is spent on it, and in
	// the first slot that has weapons of it (TUG files the odd launcher under a
	// rifle class; a sniper rifle should still be a primary).
	if req.category != "" {
		isCategory := func(w *theaterWeapon) bool { return w.Class == req.category }
		placed := false
		for _, slot := range []string{"primary", "secondary", "explosive"} {
			if slices.ContainsFunc(bySlot[slot], func(id string) bool { return isCategory(items.Weapons[id]) }) {
				placed = pick(slot, isCategory)
				break
			}
		}
		if !placed {
			return l, false
		}
	}
	// Then a primary and a sidearm, which every build has when it can.
	if !slices.ContainsFunc(l.Weapons, func(w LoadoutWeapon) bool { return w.Slot == "primary" }) {
		pick("primary", anyWeapon)
	}
	pick("secondary", func(w *theaterWeapon) bool { return w.Class == "pistol" })
	if req.build != "minimal" {
		for capacity["secondary"] > 0 && rng.Float64() < 0.6 {
			if !pick("secondary", anyWeapon) {
				break
			}
		}
		for capacity["primary"] > 0 && rng.Float64() < 0.3 {
			if !pick("primary", anyWeapon) {
				break
			}
		}
		chance := 0.7
		if req.build == "loaded" {
			chance = 1
		}
		for capacity["explosive"] > 0 && rng.Float64() < chance {
			if !pick("explosive", anyWeapon) {
				break
			}
		}
	}

	// Attachments.
	if req.build != "minimal" {
		for i := range l.Weapons {
			w := &l.Weapons[i]
			var options []string
			for _, id := range sortedKeys(items.Upgrades) {
				u := items.Upgrades[id]
				if unlocked(c, id, u.Restricted) && slices.Contains(u.Weapons, w.ID) {
					options = append(options, id)
				}
			}
			rng.Shuffle(len(options), func(a, b int) { options[a], options[b] = options[b], options[a] })
			chance := 0.4
			switch req.build {
			case "loaded":
				chance = 1
			case "cheap":
				chance = 0.3
			}
			for _, id := range options {
				u := items.Upgrades[id]
				if u.Cost > left || (req.build == "cheap" && u.Cost > 0) || rng.Float64() >= chance || !fitsAttachment(items, *w, id) {
					continue
				}
				w.Attachments = append(w.Attachments, LoadoutItem{ID: id, Name: u.Name, Slot: u.Slot, Cost: u.Cost})
				left -= u.Cost
			}
		}
	}

	l.Cost = req.budget - left
	return l, len(l.Weapons) > 0
}

// suggestLoadouts makes up to count valid loadouts. A request nothing can
// satisfy is an error the model can relay.
func suggestLoadouts(rng *rand.Rand, d *loadoutData, m *loadoutMode, class *loadoutClass, category string, budget int, build string, count int) ([]Loadout, error) {
	var out []Loadout
	for attempt := 0; attempt < count*50 && len(out) < count; attempt++ {
		c := class
		if c == nil {
			c = m.Classes[rng.IntN(len(m.Classes))]
		}
		req := loadoutRequest{class: c, category: category, budget: budget, build: build}
		l, ok := generateLoadout(rng, d.BaseWeaponSlots, m, req)
		if !ok {
			continue
		}
		if err := validateLoadout(d.BaseWeaponSlots, m, c, l, budget); err != nil {
			// A bug in the generator, never something to show: skip it.
			continue
		}
		out = append(out, l)
	}
	if len(out) == 0 {
		return nil, errors.New("no valid loadout fits those choices; try another class, category or a bigger budget")
	}
	return out, nil
}

// weaponCategories lists every weapon class in the data, for the tool enum.
func (d *loadoutData) weaponCategories() []string {
	set := map[string]bool{}
	for _, items := range d.Items {
		for _, w := range items.Weapons {
			set[w.Class] = true
		}
	}
	return sortedKeys(set)
}

// loadoutServers lists the configured servers the data covers, in config order.
func loadoutServers(cfg *Config, d *loadoutData) []string {
	var out []string
	for _, name := range cfg.ServerOrder {
		if s := d.server(name); s != nil && len(s.Modes) > 0 {
			out = append(out, name)
		}
	}
	return out
}

// loadoutsOffered reports whether random_loadout is in the toolset.
func loadoutsOffered(cfg *Config) bool {
	d, err := embeddedLoadoutData()
	return err == nil && len(loadoutServers(cfg, d)) > 0
}

func (ts *Toolset) addLoadoutTool(cfg *Config, d *loadoutData) {
	servers := loadoutServers(cfg, d)
	var classes strings.Builder
	for _, name := range servers {
		for _, m := range d.server(name).Modes {
			fmt.Fprintf(&classes, " %s %s (players are %s, starting supply %d): %s.", name, m.Mode, m.Team, m.StartingSupply, strings.Join(m.classNames(), ", "))
		}
	}
	if len(servers) == 0 {
		return
	}
	modes := map[string]bool{}
	for _, name := range servers {
		for _, m := range d.server(name).Modes {
			modes[m.Mode] = true
		}
	}
	modeNames := sortedKeys(modes)

	ts.add("random_loadout",
		"Suggest random loadouts that are valid on a server: every item is one the class can buy there, the weapons fit the slots the chosen gear gives, "+
			"every attachment fits its weapon (one per attachment slot, none that exclude each other) and the total supply cost is within the budget. "+
			"Built from the server's theater files. Use it for requests like \"give me a random sniper loadout\" or \"a cheap breacher kit\". "+
			"These are only suggestions in text: nothing is applied in game, and players buy them themselves in the loadout menu. It knows nothing about who is asking, so never tie a suggestion to a player's account or saved loadouts. "+
			"Show each loadout as a short list (class, gear, each weapon with its attachments) with its total cost out of the starting supply; ids are theater names, names are for showing. "+
			"Classes per server and mode:"+classes.String(),
		map[string]any{
			"server":   enumProp("Which server's theater. Default "+servers[0]+".", servers),
			"mode":     enumProp("Game mode; classes and prices differ by mode. Default checkpoint.", modeNames),
			"class":    prop("string", "Class (squad role) name, whole or in part, e.g. rifleman or medic. Omit for a random class per loadout."),
			"category": enumProp("A weapon category the loadout must include, e.g. sniper_rifle or lmg. Omit for any.", d.weaponCategories()),
			"budget":   intProp("Most supply to spend. Defaults to, and can't exceed, the mode's starting supply.", 0, 1000),
			"build":    enumProp("random (default); cheap (cost-0/1 items, free attachments only); loaded (fill every slot and attachment it can afford); minimal (armour, one primary and a pistol, nothing else).", loadoutBuilds),
			"count":    intProp("How many loadouts (default 1).", 1, 5),
		}, nil,
		func(ctx context.Context, _ *toolContext, raw json.RawMessage) (any, error) {
			var in struct {
				Server, Mode, Class, Category, Build string
				Budget, Count                        int
			}
			if err := decode(raw, &in); err != nil {
				return nil, err
			}
			server := d.server(pickServer(in.Server, servers[0]))
			if server == nil || !slices.Contains(servers, server.Name) {
				return nil, fmt.Errorf("no loadout data for server %q", in.Server)
			}
			modeName := strings.ToLower(strings.TrimSpace(in.Mode))
			if modeName == "" {
				modeName = "checkpoint"
			}
			m := server.mode(modeName)
			if m == nil {
				var have []string
				for _, x := range server.Modes {
					have = append(have, x.Mode)
				}
				return nil, fmt.Errorf("%s has no loadout data for mode %q (it has: %s)", server.Name, in.Mode, strings.Join(have, ", "))
			}
			var class *loadoutClass
			if strings.TrimSpace(in.Class) != "" {
				var err error
				if class, err = m.findClass(in.Class); err != nil {
					return nil, err
				}
			}
			build := in.Build
			if build == "" {
				build = "random"
			}
			if !slices.Contains(loadoutBuilds, build) {
				return nil, fmt.Errorf("build must be one of %s", strings.Join(loadoutBuilds, ", "))
			}
			budget := m.StartingSupply
			note := ""
			if in.Budget > 0 && in.Budget < budget {
				budget = in.Budget
			} else if in.Budget > budget {
				note = fmt.Sprintf("The budget was capped at the starting supply, %d.", budget)
			}
			count := in.Count
			if count <= 0 {
				count = 1
			}
			count = min(count, 5)
			loadouts, err := suggestLoadouts(rand.New(rand.NewPCG(rand.Uint64(), rand.Uint64())), d, m, class, in.Category, budget, build, count)
			if err != nil {
				return nil, err
			}
			out := map[string]any{
				"server": server.Name, "mode": m.Mode, "team": m.Team,
				"starting_supply": m.StartingSupply, "budget": budget, "loadouts": loadouts,
			}
			if note != "" {
				out["note"] = note
			}
			return out, nil
		})
}
