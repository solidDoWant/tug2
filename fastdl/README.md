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
src/models/      .qc/.qci/.smd            -> templated, then studiomdl
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
15.** The cause is not established. Validate a compiled model in game before trusting the output.

## Tools

| File | Purpose |
|---|---|
| `tools/build.sh` | the ordered pipeline; runnable outside Docker for debugging |
| `tools/` (Go) | one static binary, `fastdl-tools`, with four subcommands |
| &nbsp;&nbsp;`vtfc` | texture compiler (`.png` → `.vtf`, `.vtf` → copy) |
| &nbsp;&nbsp;`hashdir` | `<prefix>_<hash12>` for a directory's contents |
| &nbsp;&nbsp;`template` | the hashed-reference pre-pass |
| &nbsp;&nbsp;`vtf2png` | decode a VTF, for re-extracting an editable source |
| `tools/build.sh` | the ordered pipeline; runnable outside Docker for debugging |
| `tools/compile_models.sh` | PulseModel invocation |

Go, to match `tools/server-runner`: one static binary and no runtime dependencies in the build
image. `make -C fastdl tools` builds it locally; normally it is built inside the `tools` stage.

The VTF codec is hand-rolled because there was nothing to vendor: VTFEdit and `vtex` are
Windows-only, and `no_vtf` decodes but does not encode. Mipmaps use a 2x2 box filter - conventional
for mipmaps, and no ringing on the hard edges these textures have.
