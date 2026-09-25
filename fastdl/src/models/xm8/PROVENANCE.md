# XM8 model source

Decompiled from Steam Workshop item
[2019515066 "HK XM8 & G36K (Galils)"](https://steamcommunity.com/sharedfiles/filedetails/?id=2019515066)
(published 2020-03-11, never updated). Credits from the item: XM8 model and texture by Crytek Kiev,
30-round magazine by NWI, C-Mag by r_populik, animation by Cele. No published source exists; the
XM8 on GameBanana (mod 236500) is a different model - EndOfDays' mesh, replacing the M4A1, no C-mag.

The item is a *replacement*: it overwrites the stock Galil SAR's files. Here the same models are
compiled under their own names so the XM8 is a weapon of its own and the Galil is untouched.

| Here | Item's file (`models/weapons/...`) |
|---|---|
| `v_xm8/` | `v_galil_sar.mdl` |
| `w_xm8/` | `w_galil_sar.mdl` |
| `a_magazine_xm8_30/`, `w_magazine_xm8_30/` | `upgrades/{a,w}_magazine_galil_35.mdl` |
| `a_magazine_xm8_cmag/`, `w_magazine_xm8_cmag/` | `upgrades/{a,w}_magazine_galil_75.mdl` |
| `a_bipod_xm8/`, `w_bipod_xm8/` | `upgrades/{a,w}_bipod_galil.mdl` |

Not taken: the G36K (`v_galil`/`w_galil`), the item's empty `a_standard_galil` / `a_mount_galil`
(the XM8 has an integrated rail and nothing under the handguard, so the theater simply does not
attach the Galil's parts to it), and the replacement Galil sounds - the model's animation events
name the stock `Weapon_Galil.*` sound scripts, which play the game's own Galil sounds.

## How it was produced

```
mdldecompiler <item's .mdl files> -outdir <dir>     # PulseModel 0.16.0, fb8af77
```

Each model is its decompiler output folder verbatim, renamed, with two lines of its QC changed:

* `$modelname` -> `@@MDLNAME(mdl,<name>.mdl)@@`
* `$cdmaterials` -> `@@MATDIR(mat)@@`

Nothing else was edited. Meshes and animations are binary DMX, PulseModel's native format. Filenames
inside a folder keep the item's names (e.g. `meshes/w_galil_sar_reference.dmx`) - they are
compile inputs only and appear nowhere in game.

## Round-trip check

The compiled output was decompiled again and compared with the decompile of the item's originals:

* every sequence, activity, animation event, weight list, attachment, hitbox and bodygroup identical;
* every mesh the same vertex and triangle count;
* all 69 viewmodel animations the same frame count, and over all 240,864 bone-frames the worst
  difference is 0.008 units of position (animation compression) and nothing in rotation beyond
  2pi wraps;
* `$definebone` values differ only in the sixth decimal, and `-180` vs `180`.

The one structural addition is `$rootbone "R Hand"` in `w_xm8`'s collision model, which the
decompiler reports from the recompiled `.phy`.

## Textures

`src/textures/` carries the item's VTFs byte-for-byte; `src/materials/` its VMTs with the texture paths
templated. The 30-round magazine's normal map is the exception - see `src/materials/t_1p_g36_d.vmt`.
