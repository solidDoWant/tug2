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
(`make fastdl-image-test`, or `make server-image-test` which builds both), added to the generated
`downloadables.txt`, and advertised to clients by `gg2_fastdl` on every map start.

They are shared rather than per-server: a stub exists because a map references a material that is in
nobody's content, and both servers run the affected maps. Only servers listed in `FASTDL_SERVERS`
actually ship them today.

These used to be a Steam Workshop item, and were never published. That is just as well — the
workshop path cannot update an item a client already has unless the item contains the map being
loaded, so a materials-only item would have been frozen at its first version forever.

## The one unverified assumption

Every stub points `$basetexture` at `dev/dev_measuregeneric01`, which is present in the collected
content index and is a standard Source dev texture. That keeps the item to a few KB of text and
redistributes no art - but whether a stub whose *texture* is missing still stops the retry storm was
not tested. If a stubbed surface still spams the console, that base texture is the first suspect.
