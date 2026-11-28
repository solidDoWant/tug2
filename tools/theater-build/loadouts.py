#!/usr/bin/env python3
"""Writes what the Discord bot needs to suggest valid loadouts: tools/discord-bot/theater_loadouts.json.

The bot's random_loadout tool (tools/discord-bot/loadouts.go) never reads game files. It embeds
this JSON, generated from the same theater sources the servers load, so a suggestion only ever
names items the server would actually sell to that class. `make theater-build` regenerates it and
`make theater-check` (run by every server and fastdl image build) fails while it is stale, exactly
like the flattened theaters.

WHAT EACH SERVER LOADS

  main  mp_theater_override in its server.cfg (TUG's theater_tug_39_medicbomber_12p_default, from the
        vendored copy), plus <that>_<mode>.theater. TUG ships only the _checkpoint variant, so every
        other mode falls back to stock classes on main and is left out here.
  test  theater_tug_nvg_default (gg2_fastdl points mp_theater_override at a content-hashed copy of
        it), plus each mode theater under theaters/src/.

The merged theater is loaded with build.Loader, the same #base merge the flattened theaters use.

WHAT THE RULES ARE, AND HOW SURE WE ARE OF EACH

Read from the theater:
  - Classes are the player_templates the players' team's squads name. Players are Security in
    every mode except survival, where they are the insurgents (theaters/src/..._survival.theater).
  - An item ("import" resolved: the definition is merged over the one it imports, derived side
    wins, recursively - the same merge as #base) is sold to a class when its team_access names the
    players' team, and it is either not class_restricted or listed in the class's allowed_items.
  - Defaults, inferred rather than proven: a missing team_access means every team, and a missing
    class_restricted means 0. Most upgrades have neither key, and every class's default buy_order
    installs some of them, so either other default would make the stock kits unbuyable.
  - Costs: weapon_cost, upgrade_cost, gear_cost. The starting supply is what LoadoutSaverSlots'
    GetStartingSupply computes: the larger of mp_supply_token_base and gg2_supply's
    sm_supply_player_tokens (default 100), each taken from server.cfg then server_<mode>.cfg (the
    engine runs the mode file after). A mode whose stock default_server_<mode>.cfg sets the base is
    not visible from here; the sm_supply_player_tokens floor still is.
  - Upgrades: one per upgrade_slot per weapon, only on the weapons in allowed_weapons, never two
    that list each other in excluded_upgrades, and none in a slot another installed upgrade names
    in lock_slot.
  - Gear: at most one item per gear_slot. weapon_slots on gear adds to (or, with a negative value,
    takes from) the weapon slots below.

Assumed, and deliberately conservative - a suggestion may under-use a kit, never over-fill one:
  - A player starts with one primary and one secondary slot and no explosive slots; vests add
    explosive slots and slings add primary/secondary ones. Melee weapons share the secondary
    slots: every class's default buy_order pairs a knife and a pistol with secondary_sling.
  - Underbarrel launchers (weapons named by an upgrade's attach_weapon) come with their upgrade and
    are never offered as weapons of their own.

Display names: the localisation files are inside game and workshop VPKs, not in this repo, so a
name is the repo's own localisation (fastdl/src/localization/) where it has the item's print_name
token, and otherwise a tidied class name ("weapon_m4a1" -> "M4A1"). The bot always shows the theater
name too.

Usage:
    loadouts.py build     write tools/discord-bot/theater_loadouts.json
    loadouts.py check     fail if it is stale
"""
import argparse
import codecs
import json
import os
import re
import sys

import build

REPO = build.REPO
VENDOR = build.DEFAULT_VENDOR
SRC = build.DEFAULT_SRC
SERVER_CONFIG = os.path.join(REPO, "server config")
LOCALIZATION = os.path.join(REPO, "fastdl", "src", "localization")
OUT = os.path.join(REPO, "tools", "discord-bot", "theater_loadouts.json")

MODES = ("checkpoint", "conquer", "hunt", "outpost", "survival")
# The team humans play in each mode. Every other mode is coop against insurgent bots.
PLAYER_TEAM = {"survival": "insurgents"}
# gg2_supply's own default for sm_supply_player_tokens.
GG2_SUPPLY_DEFAULT = 100
# The engine's base slots - see the module docstring.
BASE_WEAPON_SLOTS = {"primary": 1, "secondary": 1, "explosive": 0}


def cfg_dir(server):
    return os.path.join(SERVER_CONFIG, server, "opt", "insurgency-server", "insurgency", "cfg")


def read_cvars(path):
    """{cvar: value} for plain `name value` lines, last one winning. Missing file: {}."""
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.split("//", 1)[0].strip()
                m = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s+"?([^"\s]*)"?', line)
                if m:
                    out[m.group(1)] = m.group(2)
    except FileNotFoundError:
        pass
    return out


def main_theater():
    cvars = read_cvars(os.path.join(cfg_dir("main"), "server.cfg"))
    name = cvars.get("mp_theater_override")
    if not name:
        raise build.KeyValuesError("main server.cfg sets no mp_theater_override")
    return name


def servers():
    """[(server, [VENDOR...] dirs, base theater name, [modes])], in the bot's order."""
    out = []
    main = main_theater()
    out.append(("main", [VENDOR], main,
                [m for m in MODES if os.path.isfile(os.path.join(VENDOR, "%s_%s.theater" % (main, m)))]))
    test = "theater_tug_nvg_default"
    out.append(("test", [SRC, VENDOR], test,
                [m for m in MODES if os.path.isfile(os.path.join(SRC, "%s_%s.theater" % (test, m)))]))
    return out


def starting_supply(server, mode):
    cvars = read_cvars(os.path.join(cfg_dir(server), "server.cfg"))
    cvars.update(read_cvars(os.path.join(cfg_dir(server), "server_%s.cfg" % mode)))
    base = int(cvars.get("mp_supply_token_base", "0"))
    tokens = int(cvars.get("sm_supply_player_tokens", str(GG2_SUPPLY_DEFAULT)))
    return max(base, tokens)


def load_localization():
    tokens = {}
    if not os.path.isdir(LOCALIZATION):
        return tokens
    for name in sorted(os.listdir(LOCALIZATION)):
        if not name.endswith("_english.txt") and "_english_" not in name:
            continue
        with open(os.path.join(LOCALIZATION, name), "rb") as f:
            raw = f.read()
        text = raw.decode("utf-16") if raw[:2] in (codecs.BOM_UTF16_LE, codecs.BOM_UTF16_BE) else raw.decode("utf-8")
        for m in re.finditer(r'^\s*"([^"]+)"\s+"([^"]*)"', text, re.M):
            tokens[m.group(1).lower()] = m.group(2)
    return tokens


# --------------------------------------------------------------------------------------------
# Theater reading
# --------------------------------------------------------------------------------------------


def leaf(kv, name):
    c = build.child(kv, name)
    return c.value if c is not None and c.children is None else None


def values(kv, name):
    """Values of the leaves inside block `name`, in order."""
    c = build.child(kv, name)
    return [x.value for x in (c.children or ()) if x.children is None] if c is not None else []


def resolve_imports(section):
    """{name: definition} with "import" merged in, skipping IsBase and conditional (?...) blocks."""
    defs = {}
    for d in section.children or ():
        if d.children is not None:
            defs.setdefault(d.name.lower(), d)
    cache = {}

    def get(name, seen):
        key = name.lower()
        if key in cache:
            return cache[key]
        d = defs[key].copy()
        imp = leaf(d, "import")
        if imp and imp.lower() in defs and imp.lower() not in seen:
            build.merge(d, get(imp, seen | {key}), 2)
        cache[key] = d
        return d

    out = {}
    for d in section.children or ():
        if d.children is None or d.name.startswith("?") or build.is_base(d):
            continue
        out[d.name] = get(d.name, frozenset())
    return out


def teams_of(kv):
    access = leaf(kv, "team_access")
    if access is None:
        return {"security", "insurgents"}
    return {"insurgents" if t.strip().lower().startswith("insurgent") else t.strip().lower()
            for t in access.split(",") if t.strip()}


def restricted(kv):
    return leaf(kv, "class_restricted") not in (None, "", "0")


def cost(kv, key):
    try:
        return int(leaf(kv, key) or 0)
    except ValueError:
        return 0


def tidy(name, kind, upgrade_slot=None):
    n = name
    if kind == "weapon":
        n = re.sub(r"^weapon_", "", n)
        return n.replace("_", " ").upper()
    if kind == "upgrade":
        prefix = {"optics": "optic", "ammo": "ammo", "magazine": "magazine", "barrel": "barrel",
                  "underbarrel": "underbarrel", "stock": "stock", "siderail": "siderail"}.get(upgrade_slot)
        if prefix:
            n = re.sub(r"^%s_" % prefix, "", n)
    if kind == "gear":
        n = re.sub(r"^(sec|ins)_", "", n)
    return n.replace("_", " ")


def display(kv, name, kind, loc, upgrade_slot=None):
    token = (leaf(kv, "print_name") or "").lstrip("#").lower()
    if token and token in loc:
        return loc[token]
    return tidy(name, kind, upgrade_slot)


def mode_data(root, team, loc):
    weapons_kv = resolve_imports(build.child(root, "weapons"))
    upgrades_kv = resolve_imports(build.child(root, "weapon_upgrades"))
    gear_kv = resolve_imports(build.child(root, "player_gear"))

    attached = {leaf(u, "attach_weapon").lower() for u in upgrades_kv.values() if leaf(u, "attach_weapon")}

    weapons = {}
    for name, w in weapons_kv.items():
        slot = (leaf(w, "weapon_slot") or "").lower()
        if slot not in ("primary", "secondary", "melee", "explosive") or name.lower() in attached:
            continue
        if team not in teams_of(w):
            continue
        weapons[name] = {
            "name": display(w, name, "weapon", loc),
            "slot": slot,
            "class": (leaf(w, "weapon_class") or slot).lower(),
            "cost": cost(w, "weapon_cost"),
            "restricted": restricted(w),
        }

    lower_weapons = {n.lower(): n for n in weapons}
    upgrades = {}
    for name, u in upgrades_kv.items():
        if team not in teams_of(u):
            continue
        fits = []
        for w in values(u, "allowed_weapons"):
            real = lower_weapons.get(w.lower())
            if real and real not in fits:
                fits.append(real)
        if not fits:
            continue
        slot = (leaf(u, "upgrade_slot") or "").lower()
        entry = {
            "name": display(u, name, "upgrade", loc, slot),
            "slot": slot,
            "cost": cost(u, "upgrade_cost"),
            "weapons": sorted(fits),
            "restricted": restricted(u),
        }
        excl = [x for x in values(u, "excluded_upgrades")]
        if excl:
            entry["excludes"] = excl
        lock = leaf(u, "lock_slot")
        if lock:
            entry["locks"] = lock.lower()
        upgrades[name] = entry
    # excluded_upgrades applies both ways; only keep names that exist.
    for name, entry in upgrades.items():
        if "excludes" in entry:
            entry["excludes"] = sorted({x for x in entry["excludes"] if x in upgrades})
            if not entry["excludes"]:
                del entry["excludes"]

    gear = {}
    for name, g in gear_kv.items():
        slot = (leaf(g, "gear_slot") or "").lower()
        if not slot or team not in teams_of(g):
            continue
        entry = {
            "name": display(g, name, "gear", loc),
            "slot": slot,
            "cost": cost(g, "gear_cost"),
            "restricted": restricted(g),
        }
        ws = build.child(g, "weapon_slots")
        slots = {}
        for s in (ws.children or ()) if ws is not None else ():
            if s.children is None:
                try:
                    slots[s.name.lower()] = int(s.value)
                except ValueError:
                    pass
        if slots:
            entry["weapon_slots"] = slots
        gear[name] = entry

    # Classes: what this team's squads name, in squad order.
    team_kv = build.child(build.child(root, "teams"), team)
    squads = build.child(team_kv, "squads") if team_kv is not None else None
    used = []
    for squad in (squads.children or ()) if squads is not None else ():
        for role in squad.children or ():
            if role.children is None and role.value not in used:
                used.append(role.value)
    templates = {t.name.lower(): t for t in build.child(root, "player_templates").children or () if t.children is not None}

    classes = []
    for tname in used:
        t = templates.get(tname.lower())
        if t is None:
            continue
        allowed = {v.lower() for v in values(t, "allowed_items")}
        # Only the class_restricted items this class may buy; everything else in the tables is
        # sold to every class of the team, so listing it per class would only repeat it.
        unlocked = sorted(n for table in (weapons, upgrades, gear) for n, item in table.items()
                          if item["restricted"] and n.lower() in allowed)
        classes.append({"id": tname, "name": class_name(tname), "unlocked": unlocked})

    for table in (weapons, upgrades, gear):
        for entry in table.values():
            if not entry["restricted"]:
                del entry["restricted"]
    return {"weapons": weapons, "upgrades": upgrades, "gear": gear}, classes


def class_name(template):
    n = re.sub(r"^template_", "", template)
    n = re.sub(r"_(security_coop|coop)$", "", n)
    n = re.sub(r"^(survival_ins_|tugvar_|coop_)", "", n)
    return n.replace("_", " ")


def generate():
    loc = load_localization()
    out = {"servers": [], "items": {}}
    for server, dirs, base, modes in servers():
        srv = {"name": server, "theater": base, "modes": []}
        for mode in modes:
            name = "%s_%s.theater" % (base, mode)
            root = build.Loader(dirs).load(name)
            build.drop_orphan_attachments(root)
            team = PLAYER_TEAM.get(mode, "security")
            items, classes = mode_data(root, team, loc)
            # Modes whose items are identical share one copy (on test, every mode but survival only
            # adds squads to the same base theater).
            key = next((k for k, v in out["items"].items() if v == items), None)
            if key is None:
                key = "%s/%s" % (server, mode)
                out["items"][key] = items
            srv["modes"].append({
                "mode": mode,
                "team": team,
                "starting_supply": starting_supply(server, mode),
                "items": key,
                "classes": classes,
            })
        out["servers"].append(srv)
    out["base_weapon_slots"] = BASE_WEAPON_SLOTS
    return json.dumps(out, indent=1, sort_keys=True, ensure_ascii=False) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("command", choices=("build", "check"))
    ap.add_argument("--out", default=OUT)
    args = ap.parse_args()
    try:
        text = generate()
    except build.KeyValuesError as e:
        sys.exit("loadouts: %s" % e)
    try:
        with open(args.out, encoding="utf-8") as f:
            current = f.read()
    except FileNotFoundError:
        current = None
    if args.command == "check":
        if current != text:
            sys.exit("loadouts: %s is stale; run `make theater-build` and commit the result"
                     % os.path.relpath(args.out, REPO))
        print("bot loadout data is up to date with the theaters")
        return
    if current == text:
        print("  unchanged %s" % os.path.relpath(args.out, REPO))
        return
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(text)
    print("  wrote     %s" % os.path.relpath(args.out, REPO))


if __name__ == "__main__":
    main()
