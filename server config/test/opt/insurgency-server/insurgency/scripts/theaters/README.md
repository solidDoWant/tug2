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

Files baked into the server image cannot reach a client by any route (`sv_downloadurl` is empty, so
there is no FastDL either). The Workshop item is what actually delivers them.

## The rule

**Any edit to a file in this directory must be republished before it is deployed:**

```sh
make workshop-package WORKSHOP_ITEM_ID=3796695587
steamcmd +login <account> +workshop_build_item "<printed vdf path>" +quit
```

Deploy the new image and the republished item together. If the loose copy here differs from the
published item by even one byte, the server will be running a theater no client has, and joins
start failing again with the message above. That failure looks like a server outage rather than a
content mismatch, so it is worth being careful about.

This README is not packaged — `make workshop-package` only picks up `*.theater` — so editing it
does not require a republish.

## Why these files exist at all

TUG Scripts 3.9 (workshop `3551935737`) ships only `_checkpoint` theater variants. The engine
resolves a theater as `<mp_theater_override>_<gamemode>.theater`, so hunt, conquer, outpost and
survival had nothing to load and fell back to stock team composition — no TUG classes, loadouts or
custom weapons. These files supply those modes, and add night vision as a buyable accessory plus
the bot loadout variants.

`mp_theater_override` is set to `theater_tug_nvg_default` in `cfg/server.cfg` and in the playlist's
`forced_cvars`. Both must agree, and both must be the **base** name with no mode suffix.
