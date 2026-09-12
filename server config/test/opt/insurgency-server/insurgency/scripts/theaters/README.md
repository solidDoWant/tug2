# Custom theaters — published to the Workshop, keep in step

These `.theater` files are **also published as Steam Workshop item
[3796695587](https://steamcommunity.com/sharedfiles/filedetails/?id=3796695587)**, and the test
server subscribes to that item in `subscribed_file_ids.txt`.

That is not redundancy. Theater files are covered by `sv_consistency`, which defaults to `1` and is
a **separate mechanism from `sv_pure`** — `sv_pure 0` does not disable it. A client that does not
hold a byte-identical copy of the theater the server is using is refused at connect with:

```
server is enforcing consistency for this file: scripts/theaters/<name>.theater
```

Files baked into the server image cannot reach a client by any route on their own. They are
delivered over fastdl (`sv_downloadurl`), from the content image built by the `fastdl-*` stages in
the Dockerfile.

These used to ship as a Steam Workshop item. They no longer do, because that path cannot update an
item a client already has: `CWorkshopItem::CheckForUpdate` has exactly one caller and it is gated on
the item containing the map being loaded, so a scripts-only item is frozen at whatever version a
client first downloaded. That is what produced the `SERVER IS ENFORCING CONSISTENCY FOR THIS FILE`
kicks.

## The rule

**Any edit to a file in this directory has to reach clients before the server that enforces it.**

```sh
make server-image-test      # builds the game server AND its fastdl content image
```

Publish the content image and deploy the server together, content first. If what is served differs
from what the server enforces by even one byte, joins fail with the message above — and that failure
looks like a server outage rather than a content mismatch, so it is worth being careful about.

This README is not served — the content image takes only `*.theater` from this directory and strips
documentation — so editing it changes nothing for clients.

## Why these files exist at all

TUG Scripts 3.9 (workshop `3551935737`) ships only `_checkpoint` theater variants. The engine
resolves a theater as `<mp_theater_override>_<gamemode>.theater`, so hunt, conquer, outpost and
survival had nothing to load and fell back to stock team composition — no TUG classes, loadouts or
custom weapons. These files supply those modes, and add night vision as a buyable accessory plus
the bot loadout variants.

`mp_theater_override` is **not** set in `cfg/server.cfg` or the playlist's `forced_cvars` any more.
Both of those are re-applied on every map change, before the theater loads, and `gg2_fastdl` needs to
be able to repoint the cvar at the content-hashed theater name the fastdl host is serving — a value
in either file would win every time and the plugin could never take effect.

Instead:

* The **boot fallback** is a command-line arg, applied once at startup: `THEATER_NAME` in the
  Dockerfile (`theater_tug_nvg_default` for test), passed as `+mp_theater_override`.
* The **running value** is owned by `gg2_fastdl`. The fastdl image publishes each theater under a
  name carrying a hash of its contents, plus the unhashed originals; the plugin downloads whichever
  hashed set the manifest names and points the cvar at it. Because the cvar is only read at map load,
  the plugin then ends the map itself so the new theater actually loads — otherwise the server would
  keep enforcing a hash the fastdl host no longer serves and nobody could join until the next map.
  `sm_fastdl_theater_changelevel` controls that: `0` never, `1` only when no humans are connected
  (default), `2` always. On a populated server with the default, the change waits for the next
  natural map change.

Whatever sets it, it must be the **base** name with no mode suffix.

The hashing is what fixes the long-standing "consistency error on first join, works the second time"
bug: theater files are CRC-enforced by the engine, and a client that already has a stale copy at the
same path fails the check before its re-download lands. A content-hashed name is a path no client has
ever seen, so there is nothing stale to invalidate. See `plugins/sourcemod/scripting/gg2_fastdl.sp`.
