# Fast-download content

Everything a **client** must hold a byte-identical copy of, built from source and published under
content-hashed paths.

Its own project — own `Makefile` and `Dockerfile`, like `tools/server-runner` — because it is
decoupled from the game server: the server fetches `manifest.json` over HTTP at every map change, so
republishing this image alone is enough. No server rebuild, no redeploy.

```sh
make content          # build the image (textures, materials, theaters)
make inspect          # show manifest.json and the file list without publishing
make content-models   # additionally recompile models — needs `make sdk-image` once
```

From the repo root, `make fastdl-image-test` delegates here.

## Why paths carry a hash

A client re-downloads a file it already has **only** if it is a `.theater` whose CRC differs; every
other existing path is skipped outright. Two further facts make a fresh path the only reliable fix:

* `insurgency/download` — where fastdl files land — is the **last** search path in the client's
  `gameinfo.txt`, so a file that also exists in a mounted workshop item resolves from the workshop
  copy. Republishing over fastdl can be invisible even to a client that did fetch it.
* Workshop items cannot self-update: `CWorkshopItem::CheckForUpdate` runs only for items whose
  `ContainsMap()` matches the loading map, so a scripts/materials item is frozen at the version a
  client first downloaded.

A hashed path exists in exactly one place — the file just fetched — so search order stops mattering
and nothing stale can shadow it.

## The hash chain

Referring files cannot hard-code their targets, so the `template` subcommand substitutes resolved names
before each group is hashed. Groups resolve **bottom-up**, so the hashes chain without cycles:

```
textures  ->  materials/models/twp_tex_<hash>/   hash of the compiled VTFs
materials ->  materials/models/twp_<hash>/       hash of the VMT, which names the texture dir
models    ->  models/twp_<hash>/                 hash of the compiled MDL, which names the material dir
theaters                                         name the model dir, then are hashed themselves
```

Edit one pixel of a texture and every name above it moves. Placeholders, which exist because each
consumer wants a different path shape:

| Placeholder | Expands to | Used by |
|---|---|---|
| `@@DIR(tex)@@` | `materials/models/twp_tex_ab12` | anything wanting a game-relative path |
| `@@MATDIR(mat)@@` | `models\twp_ab12\` | `$cdmaterials` in a QC |
| `@@MATPATH(tex,t_x)@@` | `models\twp_tex_ab12\t_x` | `$basetexture` in a VMT |
| `@@PATH(mdl,v_m18.mdl)@@` | `models/twp_ab12/v_m18.mdl` | `view_model` in a theater |

An unresolved placeholder fails the build; shipped, it would surface as a missing texture only in
game.

## Source layout

```
src/textures/    .png + .png.txt sidecar  -> compiled to VTF
                 .vtf                     -> passed through byte-for-byte
src/materials/   .vmt                     -> templated
src/models/      .qc/.qci/.smd/.dmx       -> templated, then PulseModel
                 <dir>/<model>/<model>.qc -> the same, compiled from its own directory (decompiled
                                             models, e.g. xm8/, each carry meshes/ and anims/)
src/mapvote/     .jpg/.png + .txt sidecar -> cropped to 512x256, compiled to VTF, NOT hashed
                 .vmt                     -> copied (an alias to an image clients already have)
map_asset_stubs/                          -> copied, deliberately NOT hashed
```

### Editing a texture

`src/textures/t_1p_m18_d.png` is the source of truth; the VTF is a build artifact. Edit the PNG and
rebuild. The sidecar's settings match the original it was decoded from, so a rebuild produces a
structurally identical VTF.

* **Only ship maps you edit.** Re-encoding an unedited DXT texture costs a second generation of block
  artifacts for nothing. Only the M18 diffuse is shipped; the normal, gloss and envmap are referenced
  in place from workshop item `2744181131`, which clients already have via the server's subscription
  list. Payload ~5.6 MB instead of ~11 MB.
* **Never colour-correct a normal map.** It encodes surface direction as XYZ→RGB, not colour. Editing
  it as an image corrupts lighting in ways that read as "the model is subtly wrong".

DXT requires dimensions to be a multiple of 4; the build fails loudly otherwise.

## Models

Everything compiles natively — no Wine, no Steam credentials, no SDK. The compiler is
[PulseModel](https://github.com/ToppiOfficial/PulseModel) (MIT), a studiomdl replacement emitting
MDL v49, built from a pinned commit in the `model-compiler` stage.

Valve's `studiomdl` was the obvious choice and was rejected: it is Windows-only, the Insurgency SDK
is AppID 222890 *DLC* (so it needs an account owning the game), Source SDK Base 2013 refuses an
anonymous install, and it may not be redistributed inside an image — Docker layers are immutable, so
a later `rm` would not remove it. Models you compile are yours to ship; Valve's compiler is not.

**`-vtxformat 1` is required.** Insurgency is a CS:GO-branch build (`datacache.so` carries the build
path `.../csgo/rel_pc/src/datacache/mdlcache.cpp`), and format 1 is the CS:GO/SFM/ASW `.vtx` strip
layout. Format 0 is the older TF2/HL2 one and produces geometry the engine misreads.

`$cdmaterials` is rewritten in the QC *before* compiling, so the MDL references the hashed material
directory directly — no byte patching of its string table.

### Caveats

PulseModel is beta, and its script vocabulary is not stock QC. `src/models/PROVENANCE.md` lists every
local change needed to compile these sources. The commit is pinned because that vocabulary changes
between versions, and `patches/` carries a `<cstddef>` fix for a GCC build break.

Verified against the previously shipped models: both compile to v49 with matching bone, sequence and
bodypart counts. **One known difference: `v_m18` produces 14 local animations where the original had
15.** The cause is not established, and PulseModel 0.16.0 did not change it (its M18 output is
byte-identical to the previous pin's). Validate a compiled model in game before trusting the output.

### Models with no published source

PulseModel also ships `mdldecompiler`, which turns a compiled `.mdl` back into a QC plus DMX meshes
and animations. That is how the XM8 (`src/models/xm8/`) was brought in from a workshop item that
replaced the Galil SAR - its `PROVENANCE.md` has the exact command, the two QC lines changed, and the
round-trip comparison that showed the recompile matches the original. Do the same comparison for any
model brought in this way: decompile the compiled output again and diff it against the decompile of
the original.

## Tools

| File | Purpose |
|---|---|
| `tools/build.sh` | the ordered pipeline; runnable outside Docker for debugging |
| `tools/` (Go) | one static binary, `fastdl-tools`, with four subcommands |
| &nbsp;&nbsp;`vtfc` | texture compiler (`.png`/`.jpg` → `.vtf`, `.vtf` → copy) |
| &nbsp;&nbsp;`hashdir` | `<prefix>_<hash12>` for a directory's contents |
| &nbsp;&nbsp;`template` | the hashed-reference pre-pass |
| &nbsp;&nbsp;`vtf2png` | decode a VTF, for re-extracting an editable source |
| `tools/build.sh` | the ordered pipeline; runnable outside Docker for debugging |
| `tools/compile_models.sh` | PulseModel invocation |
| `tools/mapvote_images.py` | fills `src/mapvote/` from workshop previews - see below |

Go, to match `tools/server-runner`: one static binary and no runtime dependencies in the build
image. `make -C fastdl tools` builds it locally; normally it is built inside the `tools` stage.

The VTF codec is hand-rolled because there was nothing to vendor: VTFEdit and `vtex` are
Windows-only, and `no_vtf` decodes but does not encode. Mipmaps use a 2x2 box filter - conventional
for mipmaps, and no ringing on the hard edges these textures have.

## Map vote images

The end-of-round vote panel shows a picture of each candidate map. `client.so` looks for, in order:

1. `materials/vgui/maps/<map>_large.vmt` - the stock loading-screen image
2. `materials/vgui/maps/<map>_small.vmt` - with a "using incorrect size" console warning
3. `materials/vgui/endroundlobby/maps/<map>.vmt` - "falling back to old voting image"
4. `materials/vgui/maps/fallback_large.vmt` - a generic placeholder

Stock maps have (1). Custom maps mostly get (3) from the "map vote ui" workshop item (`890084623`),
and the rest showed the placeholder. `tools/mapvote_images.py` fills that gap from each map's workshop
preview image, which is the same kind of picture - the vote pack's images are plain 2:1 screenshots.

```sh
python3 fastdl/tools/mapvote_images.py            # generate what is missing
python3 fastdl/tools/mapvote_images.py --fetch    # first run on a machine, or after new items
python3 fastdl/tools/mapvote_images.py --previews <map>   # other preview images to choose from
```

Only maps in a server's `mapcycle.txt` count - that is the only place vote choices come from.

**Generated images go to (3), the lowest-priority slot that is not the placeholder.** So a real image
shipped later - by the mapper or by the vote pack - wins without anyone deleting ours, and the script
then lists ours as no longer needed.

**Knowing what is missing requires every subscribed item's contents**, because a map's image can come
from any item, not just the map's own. `src/mapvote/index.json` records, per item and at the manifest
the lockfile pins, the maps it holds and the vote/loading images it ships (loose, in VPKs, or packed
into a BSP). It is committed, so later runs need no workshop content; an item is rescanned only when
its pin moves. Items the Steam client has not downloaded are fetched with `--fetch`: `steamcmd` into
a scratch dir, a batch of about 1 GB at a time, deleted after indexing. The script refuses to
generate while any item is unindexed, because an unknown item could already hold the image.

### Fixing a bad image

Each image is the preview exactly as published, plus a sidecar that crops it at compile time:

```
"fit"     "512x256"
"focusx"  "0.5"      0 = keep the left edge, 1 = the right
"focusy"  "0.5"      0 = keep the top, 1 = the bottom
"zoom"    "1"        above 1 crops tighter than 2:1 needs
```

A bad crop is fixed by moving the focus; `zoom` reaches a HUD line or viewmodel that sits further in
than the aspect crop does (`laboratory` and `2022_BB_Arena_1` use it). A bad *picture* - HUD text, a logo, an overhead layout - is
fixed in `src/mapvote/overrides.txt`:

```
<map> url   <image url>        a different picture, e.g. one from --previews
<map> alias <texture>          reuse an image clients already have, e.g. a sibling map's
                               vgui/endroundlobby/maps/<other> - writes a VMT, ships no texture
<map> item  <workshop id>      take the preview from this item (a map no item's BSP resolves)
<map> skip                     never generate; the placeholder stays
```

An alias is also made **automatically** when a texture named after the map already exists but no
VMT of that name does. The vote pack does this for eight of its own images (`anbar_coop.vtf` sits
behind `anbar.vmt`, and so on): the picture was made for the map and never shown.

then delete the map's current image and sidecar and rerun.

### Write-once

The path is fixed by the map name, so like the buy-menu icons it cannot be content-hashed, and a
client that has fetched an image keeps it forever. Changing an image after it has shipped does not
reach anyone who already has it. Get it right before publishing; `--force <map>` regenerates one that
has not shipped yet. Adding images for new maps is always fine.

Nothing here needs the server image rebuilt: the images are in `manifest.json`, which `gg2_fastdl`
advertises at every map change.

