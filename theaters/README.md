# Theaters

Sources for every theater the test server loads. The engine never resolves a `#base` from here:
`tools/theater-build/build.py` merges each entry point with what it `#base`s and writes one flat,
self-contained theater per entry point into
`server config/test/opt/insurgency-server/insurgency/scripts/theaters/`, which the fastdl and server
images pick up as before.

```
theaters/
  vendor/tug-scripts-3.9/   TUG Scripts 3.9, byte-for-byte as shipped (see its PROVENANCE.md)
  src/                      ours: every *.theater not starting with "_" is an entry point
```

```sh
make theater-build    # regenerate the flat theaters after editing theaters/src/
make theater-check    # fail if a committed flat theater is stale (fastdl and server builds run it)
```

`tools/survival-economy` and `tools/weapon-clone` edit generated blocks inside `theaters/src/`; run
`make theater-build` after either.

## Why the merge moved out of the engine

Our theaters used to `#base` TUG's from the workshop item at runtime, on the server and on every
client. Several things broke in ways that were hard to see from the theater text, most recently an
XM8 change that restated 21 of TUG's upgrades verbatim (plus one weapon name) and made every one of
them misrender in first person on every weapon. Doing the merge here means the engine only ever
loads one definition per name, and what it loads can be read and diffed.

## How the merge works

It is the engine's own algorithm - proven by reverse-engineering `KeyValues::LoadFromBuffer` and
`RecursiveMergeKeyValues` in the shipped `server.so`/`client.so`, and checked against the live
server's item tables (same 112 weapons, 228 upgrades, same ids) - so flattening changes no content:

- `"#base" "<file>"` loads `<file>` with its own `#base` chain, then merges it in, in listed order.
- A base child whose name matches the **first** same-named derived child is merged into it
  recursively; one with no match is appended. A value is never overwritten - the derived side wins.
- So a definition we declare is **merged** with TUG's, not substituted: TUG keys we leave out
  survive. A list of repeated keys (`"weapon" "x"` ...) that we declare replaces TUG's whole,
  because every inherited entry matches our first one. Declaring a partial list therefore drops
  TUG's entries.
- To remove an inherited item, declare `"name" { "IsBase" "1" }`: the merged result carries
  `IsBase` and the engine skips it before assigning an id.

**One deliberate difference:** in `weapon_upgrades` a merged definition keeps TUG's position and
our new upgrades come after TUG's. The engine put derived definitions first, which gave every
restated upgrade a new low id; that id move was the only difference a verbatim restatement made, and
it coincided with the first-person breakage. Ids are assigned in definition order, so an upgrade's
id now changes only when items are added or removed before it. Other sections keep the engine's
order - `ammo` must, because its first entry is a deliberate sacrifice to the engine's index-0
ammo bug.

## Ids

Weapon, upgrade, explosive and gear ids are positions in the flat file. Saved loadouts store names
(LoadoutSaverSlots), so an id shift is harmless there, but the hard caps still apply: 126 usable
weapon ids and 254 upgrade ids. To count, load an output with `build.Loader` and count the
non-`IsBase` children of a section, or run `sm_theateritems` on the server.
