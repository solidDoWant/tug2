# Render-only inputs

Decoded copies of maps the icon render needs but the payload does **not** ship.

At runtime `materials/models/<hashed>/mi_1p_m18.vmt` references these in place out of workshop item
`2744181131`, which every client already has via the server's subscription list — so shipping copies
would add ~5 MB of identical bytes to every download. The icon render, however, runs in a build
container with no access to that item, so it needs them locally.

Nothing here reaches a client. `src/textures/` is the directory whose contents become payload; this
one is consumed only by the `icon-render` stage.

| File | Role | Notes |
|---|---|---|
| `t_1p_m18_n.png` | `$bumpmap` | Tangent-space normal map, RGB = XYZ (R/G centred ~128, B ~244) |
| `t_1p_m18_m.png` | `$phongexponenttexture` | Channel-packed **ORM**: R occlusion, G roughness, B metalness |

`t_1p_m18_m` is read as **ORM**, the glTF convention — R ambient occlusion, G roughness, B metalness
— and the channel statistics fit that: R is flat and bright (mean 156, std 15), G carries the most
variation (mean 188, std 76), and B spans the full 0–255 the way a paint-versus-bare-metal mask does.
`$roughnessmultiplier` in the VMT is the confirmation: you would not scale a *gloss* value by a
roughness multiplier.

This was initially read the other way — as gloss, so roughness = 1 - G — on the strength of the
`$phongexponenttexture` parameter name alone. That is wrong, and it is worth recording why it
survived: inverting a mean of 0.737 gives roughness 0.20, and at a forced metalness of 1.0 that
renders as crumpled aluminium foil. Every aggregate statistic (mean, p50, p95) stayed within a few
points of the target while the surface was visibly wrong; what exposed it was the fraction of
near-black pixels, 10.4% against the reference's 6.4%, because a near-mirror reflects empty
environment as black. Aggregate brightness is not a useful check on material response.

Metalness comes from B rather than a constant: forcing 1.0 makes painted areas behave like mirrors
too.

Regenerate with `fastdl-tools vtf2png` against the VTFs inside the workshop item's VPK.
