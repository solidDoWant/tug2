# Map asset stubs

Placeholder materials for assets that custom maps reference but never packed.

A Source client that cannot load a VMT does **not** cache the failure. It retries every time
something asks for that material - many times a second - and the framerate collapses:

```
CMaterial::PrecacheVars: error loading vmt file for decals/rug_green01
```

These files exist so the lookup **succeeds**. They do not reproduce the original art; the surface
renders as a placeholder grid, deliberately, so the remaining damage stays visible.

## Scope

Only materials referenced by **brush faces** are here. Where an *entity* is what asks for a missing
material, removing the entity is the better fix - it needs no client download at all, which matters
because `sv_downloadurl` is empty and Workshop is the only delivery channel. That side lives in
`gg2_strip_entities` and its config.

## Regenerating

Both halves come out of the same audit:

```
python3 tools/bspaudit/audit.py \
    --maps-dir <steam workshop content dir> \
    --content-index tools/bspaudit/content_index.txt \
    --strip-config plugins/sourcemod/configs/gg2_strip_entities.cfg \
    --stub-dir fastdl/map_asset_stubs/materials
```

Nothing else to do. These are picked up automatically by the fastdl content image
(`make -C fastdl content`, or `make fastdl-image-test` from the repo root), listed in the generated
`manifest.json`, and advertised to clients by `gg2_fastdl`, which fetches that manifest over HTTP on
every map start. Adding a stub therefore needs the content image rebuilt and republished, but **not**
the game server image — a running server picks the new list up on its next map change.

## Why these are the one group that is not content-hashed

Everything else in the fastdl payload — textures, materials, models, theaters — is published under a
directory name carrying a hash of its contents, so changing a file changes its path and no client can
be left holding a stale copy. See `fastdl/tools/build.sh`.

These cannot do that. The paths are hardcoded in each map's BSP, so they have to resolve at exactly
the name the map asks for. That collides with an engine limitation: a client re-downloads a file it
already has only if it is a `.theater` whose CRC differs, and skips every other existing file
outright. **So a change to a stub's contents will never reach a client that already has the old one.**

In practice that does not matter, which is why there is no build-time guard for it: a stub only has to
*exist* for the client's VMT lookup to succeed and the retry storm to stop. An old placeholder does
that exactly as well as a new one. Adding new stubs is always fine — a new path is never a problem.
If you ever need a stub change to actually reach clients, give it a new path and update whatever
references it.

These used to be a Steam Workshop item, and were never published. That is just as well — the
workshop path cannot update an item a client already has unless the item contains the map being
loaded, so a materials-only item would have been frozen at its first version forever.

## The one unverified assumption

Every stub points `$basetexture` at `dev/dev_measuregeneric01`, which is present in the collected
content index and is a standard Source dev texture. That keeps the item to a few KB of text and
redistributes no art - but whether a stub whose *texture* is missing still stops the retry storm was
not tested. If a stubbed surface still spams the console, that base texture is the first suspect.
