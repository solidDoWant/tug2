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

`mp_theater_override` is set to `theater_tug_nvg_default` in `cfg/server.cfg` and in the playlist's
`forced_cvars`. Both must agree, and both must be the **base** name with no mode suffix.
