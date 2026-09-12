# Vendored model source

Geometry and animation source for the M18 marker, from
[Gmod4phun/sandstorm_source_files](https://github.com/Gmod4phun/sandstorm_source_files)
(`release/weapons/m18_anm14/` plus the shared `.qci` includes and `gen_grd` animations), GPL-3.0.

This is the genuine source for the compiled models previously shipped: `SKM_1P_M18_World.smd` and
`SKM_1P_M18_World_Spoon.smd` are byte-identical in name to the strings `studiomdl` baked into the old
`w_m18.mdl`, which is how the match was confirmed.

Local changes, applied at fetch time:

* `$modelname` retargeted to `twp\` so `compile_models.sh` can collect the output.
* `$cdmaterials` replaced with `@@MATDIR(mat)@@`, resolved to the content-hashed material directory
  by the `template` pre-pass **before** compiling. This is what removes the need to byte-patch the
  compiled MDL's string table.
* Absolute author paths (`F:\SMD_PROJECTS\...`) rewritten to the sibling copies fetched alongside.
* The ANM14 QCs were dropped; that is a different grenade.

Changes needed for PulseModel, whose script vocabulary is not stock QC:

* `$include "sandstorm_deltas_macros.qci"` dropped and the file deleted. It defines four macros in
  stock `$definemacro` continuation syntax, which PulseModel rejects (it wants `$endmacro`). None of
  the four is ever invoked, so the include was dead weight.
* `frames <start> <end>` renamed to `frame <start> <end>`, PulseModel's spelling.
* Extensionless source references given an explicit `.smd`. PulseModel resolves a bare name as
  `.dmx`, its primary format, and does not fall back.
* Filename case. The sources were authored on a case-insensitive filesystem and the references
  disagree with the real filenames in both directions. References here are lowercase; the build
  lowercases the names to match (`fastdl-tools template --lowercase-names`). Renaming in this tree cannot work
  — a case-insensitive checkout silently ignores it.
* `$bonecullmethod none` added to `w_m18_ins2.qc`. PulseModel culls bones more aggressively than
  stock studiomdl and dropped `b_wpn`, leaving one bone instead of two. This is its spelling of stock
  `$nocollapsebones`.

The meshes derive from Insurgency: Sandstorm, a commercial New World Interactive product. The
upstream GPL-3.0 grant cannot extend to assets its author does not own, so redistribution rests on
the same footing as the rest of the Insurgency workshop port ecosystem — see the note in
`server config/test/.../scripts/theaters/README.md`.
