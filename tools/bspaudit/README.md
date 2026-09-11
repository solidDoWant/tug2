# bspaudit

Finds map assets that are referenced but not available, before a player finds them for you.

## The problem

A Source client that cannot load a material does not cache the failure. It retries every time
something asks for that material - many times a second - and the framerate collapses. In the client
console it looks like:

```
CMaterial::PrecacheVars: error loading vmt file for decals/rug_green01
```

The cause is almost always a mapper forgetting to pack an asset. The map plays fine for them,
because they have the source content installed.

## Usage

```
# One map, no context - separates "packed" from "not packed" only
./audit.py /path/to/showdown.bsp

# The useful version
./audit.py --maps-dir /path/to/maps --content-index content_index.txt --json report.json
```

`--content-index` is what makes the result trustworthy. Without it every stock material is a false
positive: showdown reports 7 findings bare, of which 6 are base-game materials and 1 is real.

Build the index on a machine with the game installed - not the server. **On Windows, double-click
`collect_content_index.bat`** - it finds Steam, the game and your Workshop content on its own and
needs no arguments:

```
collect_content_index.bat                       Windows
python3 collect_content_index.py                everywhere else
```

Steam is located through the registry, then every library in `libraryfolders.vdf` is searched - a
game on a second drive is the normal case, and only checking the Steam install is the main reason a
naive scan comes back empty. Both the old (`"1" "D:\Games"`) and new (`"path" "D:\Games"`) vdf
layouts are handled. If it still cannot find the game it prints where it looked and how to point it
directly.

It reads VPK directory trees and loose `materials/` folders, including subscribed Workshop items,
and writes one material path per line. Read-only, stdlib only - but it does need Python installed.
If that is a problem, zip up the `*_dir.vpk` files from `insurgency2/insurgency/` and build the
index elsewhere; those are directory trees only, not content, so they are small.

## Reading the output

Each finding is labelled by what refers to it, which decides the fix:

| Label | Meaning | Fix |
|---|---|---|
| `STRIPPABLE` | only entities reference it | remove the entity - `gg2_strip_entities` |
| `needs stub material` | a brush face references it | ship a stub VMT to clients |

Stripping is preferred where it applies: it works server-side with no client download, which
matters because `sv_downloadurl` is empty and Workshop is the only delivery channel.

A stub does not have to look right, it only has to **exist** - a valid VMT loads once, caches, and
the retry storm stops. Pointing `$basetexture` at a stock texture makes it look plausible rather
than checkerboard.

Neither repairs the map. They suppress the symptom.

## Caveats

- Materials referenced only by *models* (a `.mdl`'s `$cdmaterials`) are not followed. A missing
  model material produces the same symptom and would need the pakfile's models parsed too.
- `tools/*` is skipped - never rendered.
- A map whose pakfile is corrupt reports as having none, which will flag everything.
