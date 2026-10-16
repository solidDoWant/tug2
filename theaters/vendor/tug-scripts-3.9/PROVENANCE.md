# TUG Scripts 3.9 - vendored theater files

Unmodified copies of every `.theater` file in Steam Workshop item
[3551935737](https://steamcommunity.com/sharedfiles/filedetails/?id=3551935737)
("TUG Scripts 3.9 (10,12,14p)"):

| | |
|---|---|
| Workshop item | 3551935737 |
| Content manifest | 7641588715112482498 |
| `time_updated` | 1755599904 (2025-08-19) |
| Source | `scripts/theaters/*.theater` inside `tug3.9_scripts_dir.vpk` / `tug3.9_scripts_000.vpk` |
| Vendored | 2026-10-15 |

Do not edit these files. Every change we make to TUG's content lives in our override layer and is
applied by the merge tool, so these stay a faithful record of what TUG shipped and a diff against a
fresh extraction stays empty. Line endings are TUG's own CRLF (see `../.gitattributes`).

## Why vendored

Our theaters used to `#base` these files from the workshop item at runtime, on the server and on every
client, and changed TUG's content by declaring same-named definitions on top. How the engine combines
two same-named definitions is not what the repo assumed: an upgrade restated verbatim (only a weapon
name added to its lists) rendered wrongly in first person on every weapon. Earlier `#base` surprises
are documented throughout the old theater's comments. Vendoring lets the merge happen in our own tool
with rules we define, so the engine only ever sees one flat theater with one definition per name.

Note that TUG's own `#base` graph is a diamond: `base_weapon`, `base_common_ammo` and
`base_explosives` are reached through both `default_weapon` and `custom_weapon`, and
`base_weapon_upgrades` through both `default_weapon_upgrades` and `weapon_mods`.

## Updating

If TUG Scripts is ever updated, extract the new version's theaters from the VPK into a new
`tug-scripts-<version>/` directory beside this one, point the merge tool at it, and review the
resulting diff of the flattened theaters. The workshop item stays subscribed regardless: clients
still need it for `resource/ui/tug_english_modern.txt` and the rest of its non-theater content.
