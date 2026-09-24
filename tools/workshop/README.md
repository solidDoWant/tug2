# Workshop content

Every workshop item a server subscribes to is pinned in [`workshop.lock.json`](../../workshop.lock.json) and fetched at build time as a set of independent image layers.

## What this replaced, and why

The build used to boot `srcds -workshop` once per server and let the engine fetch everything. That had two problems.

**It was not pinned.** The boot took whatever Steam was serving that minute. Two images built a week apart could ship different versions of the same item, main and test could disagree, and nothing anywhere recorded which version either of them had. For a repo that otherwise goes to some length over content determinism — `sv_consistency`, content-hashed fastdl paths — that was a real gap.

**It was one layer.** All ~20 GB of it. Change a single item and every host re-pulls the lot, even though consecutive versions overlap almost entirely, and even though main and test share 97 items worth 16.4 GB that were stored and transferred twice.

## How the items are split up

One layer per item would be ideal. It is also impossible: overlay2 refuses to build past **128 layers** (`max depth exceeded`), a server image is already in the fifties before any of this, and main subscribes to 158 items. So items are bucketed, and the bucketing is chosen for two properties.

**Grouped by subscriber set** — `main-test`, `main`, `test`. A bucket that both servers subscribe to holds identical bytes in both images, so `COPY --link` gives it the same layer digest in both and the registry and the game host store it once. Grouping is what makes that possible; bucket over the union instead and most buckets end up with a different member list per server.

**Bucketed within a group by `sha256(item id)`** — not by size. Size-balanced packing reshuffles when the item set changes, which would invalidate every layer for every host. Hashing the id means adding an item rewrites exactly the one bucket it lands in.

**Except above `solo_bytes` (512 MB), where an item gets a layer to itself.** Seven items qualify, one of them 1.7 GB. Left in a shared bucket, a single item that size sets the floor for what every other item in that bucket costs to re-pull.

Bucket counts and the threshold live in the lockfile and are sticky on purpose. Changing either repartitions a whole group, so `refresh` never touches a value it did not invent.

Current split — 183 items, 28.9 GB, 51 buckets:

| group | items | size | buckets |
| --- | --- | --- | --- |
| `main-test` | 97 | 16.4 GB | 24 + solo |
| `main` | 61 | 9.1 GB | 15 + solo |
| `test` | 25 | 3.4 GB | 6 + solo |

Median bucket 591 MB, p90 993 MB, largest 1.7 GB (one item, alone). That puts main at ~90 layers and test at ~87, leaving room for roughly 38 more plugins before the ceiling matters.

## Workflow

```
make workshop-lock     # re-pin every subscribed item to what Steam serves now, then re-render
make workshop-render   # regenerate only (after editing the lockfile by hand)
make workshop-check    # fail if the committed Dockerfile is stale; server builds run this first
```

`render` writes three kinds of generated output:

- the `ws-<group>-<NN>` and `ws-<group>-<item id>` stages in the `Dockerfile`, between `# >>> workshop-lock: ... >>>` markers
- the `COPY --link` lines inside each server stage, likewise
- `server config/<server>/opt/insurgency-server/steamapps/workshop/appworkshop_222880.acf`

The first two are committed. The `.acf` files are not — they are gitignored, and `make server-image-<server>` writes them fresh from the lockfile before every build, so the lockfile is the single source of truth. A bare `docker build` on a clean checkout will therefore fail on the missing `.acf`; build through `make`.

Editing a `subscribed_file_ids.txt` needs a `make workshop-lock` afterwards. `make server-image-<server>` runs `workshop-check` before building, so a forgotten render fails the build rather than shipping the wrong items.

## The .acf

`appworkshop_222880.acf` is what the engine reads to decide an item is installed and current. Without a correct one the server re-downloads everything **at runtime**, on first boot, which is far worse than doing it at build time.

It is generated from the lockfile rather than captured from a build, and the three fields that matter come straight from `ISteamRemoteStorage/GetPublishedFileDetails`:

| .acf field | API field |
| --- | --- |
| `manifest`, `latest_manifest` | `hcontent_file` |
| `size` | `file_size` |
| `timeupdated`, `latest_timeupdated` | `time_updated` |

Verified against a file the engine itself wrote on the running test server: for all 122 subscribed items, every `size`, `timeupdated` and `manifest` matches, and the layout is byte-identical. The only difference is that the engine's copy also listed two items test had already unsubscribed from — it never prunes them — which the generated one correctly omits.

`timetouched` is a last-seen stamp the engine rewrites on every boot, so it is seeded with the publish time.

## Why steamcmd, and why the pin is checked

`steamcmd +workshop_download_item` can fetch one item at a time, which is what makes per-bucket layers possible at all; `srcds -workshop` only ever fetches the whole subscription list. Anonymous login is enough for this app.

steamcmd has no way to request a *specific* manifest — it always fetches current. So [`fetch_items.sh`](fetch_items.sh) reads back the manifest steamcmd recorded and fails the build if it is not the pinned one, telling you to run `make workshop-lock`. Without that check a republished item would be fetched silently while the generated `.acf` still claimed the old version, and because the `.acf` is what suppresses re-downloading, nothing downstream would ever notice the mismatch.

## Adding a server

`refresh` discovers servers by looking for `server config/*/opt/insurgency-server/insurgency/subscribed_file_ids.txt`, so a new one needs no change here — but it does create new groups, which the render turns into new stages, and those need the matching `# >>> workshop-lock: workshop layers: <server> >>>` markers added to the new server stage in the `Dockerfile` by hand.
