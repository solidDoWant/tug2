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
    --stub-dir workshop/map_asset_stubs/materials
```

Then:

```
make workshop-package-stubs WORKSHOP_STUBS_ITEM_ID=<id>
```

A first publish uses `0`, which creates the item; put the resulting ID in the Makefile and in the
servers' `subscribed_file_ids.txt`, or clients will never receive it.

## The one unverified assumption

Every stub points `$basetexture` at `dev/dev_measuregeneric01`, which is present in the collected
content index and is a standard Source dev texture. That keeps the item to a few KB of text and
redistributes no art - but whether a stub whose *texture* is missing still stops the retry storm was
not tested. If a stubbed surface still spams the console, that base texture is the first suspect.
