#!/usr/bin/env python3
"""Pin the workshop items each server ships, and turn that pin into build inputs.

The engine used to fetch the workshop at build time by booting srcds with -workshop, which has two
problems. It is not pinned - the boot takes whatever Steam is serving that minute, so two servers
built a week apart can ship different versions of the same item and nothing records which. And it
lands the whole ~20 GB as one image layer, so any change to any item makes every host pull all of
it again, even though consecutive versions overlap almost completely and main and test overlap by
16 GB.

So the set is pinned in workshop.lock.json, and the download is split into buckets that each become
their own layer:

    workshop_lock.py refresh   ask Steam for the current manifest of every subscribed item and
                               write the lockfile
    workshop_lock.py render    regenerate the parts of the build that follow from the lockfile -
                               the download stages in the Dockerfile, the COPY lines that graft
                               them into each server, and each server's appworkshop_222880.acf
    workshop_lock.py check     fail if the committed Dockerfile is out of date with the lockfile

Items are bucketed by which servers subscribe to them and then by a hash of their id, except for
the handful big enough to be worth a layer to themselves. Both halves of that matter. Grouping by
subscriber set is what lets main and test share layer blobs - a bucket both subscribe to holds
identical bytes in both images, so the registry and the game host store it once. Hashing the id is
what keeps a bucket stable: adding an item rewrites the one bucket it lands in rather than
reshuffling every bucket the way size-balanced packing would.

Bucket counts are recorded in the lockfile and are deliberately sticky. Changing one repartitions
everything and costs every host a full pull, so `refresh` never changes a count it did not invent.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import urllib.parse
import urllib.request

APPID = 222880
API = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
# The API takes an unbounded list in principle; this keeps a single failure from costing much.
BATCH = 100

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOCKFILE = os.path.join(REPO, "workshop.lock.json")
DOCKERFILE = os.path.join(REPO, "Dockerfile")
SERVER_CONFIG = os.path.join(REPO, "server config")
# base holds settings every server shares and _template is the skeleton for a new one; neither is a
# server that gets built.
NOT_SERVERS = {"base", "_template"}

SUBSCRIBED = os.path.join(
    "opt", "insurgency-server", "insurgency", "subscribed_file_ids.txt"
)
ACF = os.path.join(
    "opt", "insurgency-server", "steamapps", "workshop", "appworkshop_%d.acf" % APPID
)


# --------------------------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------------------------


def servers():
    found = []
    for name in sorted(os.listdir(SERVER_CONFIG)):
        if name in NOT_SERVERS:
            continue
        if os.path.isfile(os.path.join(SERVER_CONFIG, name, SUBSCRIBED)):
            found.append(name)
    return found


def subscribed_ids(server):
    """The ids a server actually asks for. Ids are commented out rather than deleted when a map is
    dropped, so everything from "//" on has to go first."""
    path = os.path.join(SERVER_CONFIG, server, SUBSCRIBED)
    ids = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = re.sub(r"//.*", "", line).strip()
            if line.isdigit():
                ids.append(line)
    seen = set()
    return [i for i in ids if not (i in seen or seen.add(i))]


# --------------------------------------------------------------------------------------------
# Bucketing
# --------------------------------------------------------------------------------------------


def group_of(item_servers):
    """Stage name component for a set of subscribers: "main-test" for one both servers use."""
    return "-".join(sorted(item_servers))


def default_bucket_count(size):
    """Roughly four items a bucket, capped so one group cannot eat the image's layer budget.

    overlay2 refuses to build past 128 layers, and a server image is already in the fifties before
    any of this, so the totals have to stay modest.
    """
    return max(1, min(32, round(size / 4)))


def bucket_of(item_id, count):
    digest = hashlib.sha256(item_id.encode("ascii")).hexdigest()
    return int(digest[:8], 16) % count


def partition(lock):
    """{group: {bucket key: [item id, ...]}}, every list sorted, empty buckets omitted.

    Anything at or over solo_bytes gets a bucket to itself, keyed by its own id. A few items here
    are over a gigabyte, and left in a shared bucket one of them sets the floor for what every
    other item in that bucket costs to re-pull.
    """
    solo = lock.get("solo_bytes", 0)
    by_group = {}
    for item_id, item in lock["items"].items():
        by_group.setdefault(group_of(item["servers"]), []).append(item_id)

    out = {}
    for group, ids in by_group.items():
        count = lock["buckets"][group]
        buckets = {}
        for item_id in ids:
            if solo and lock["items"][item_id]["size"] >= solo:
                key = item_id
            else:
                key = "%02d" % bucket_of(item_id, count)
            buckets.setdefault(key, []).append(item_id)
        out[group] = {key: sorted(buckets[key], key=int) for key in sorted(buckets)}
    return out


def stage_name(group, key):
    return "ws-%s-%s" % (group, key)


# --------------------------------------------------------------------------------------------
# refresh
# --------------------------------------------------------------------------------------------


def published_file_details(ids):
    details = {}
    for start in range(0, len(ids), BATCH):
        chunk = ids[start : start + BATCH]
        fields = {"itemcount": str(len(chunk))}
        for index, item_id in enumerate(chunk):
            fields["publishedfileids[%d]" % index] = item_id
        body = urllib.parse.urlencode(fields).encode("ascii")
        with urllib.request.urlopen(API, data=body, timeout=60) as response:
            payload = json.load(response)
        for entry in payload["response"]["publishedfiledetails"]:
            details[entry["publishedfileid"]] = entry
    return details


def refresh(args):
    names = servers()
    if not names:
        sys.exit("no servers found under %s" % SERVER_CONFIG)

    subscriptions = {name: subscribed_ids(name) for name in names}
    all_ids = sorted({i for ids in subscriptions.values() for i in ids}, key=int)
    print("%d items across %s" % (len(all_ids), ", ".join(names)), file=sys.stderr)

    details = published_file_details(all_ids)

    items, broken = {}, []
    for item_id in all_ids:
        entry = details.get(item_id)
        # result 1 is success; anything else means removed, hidden or never existed, and the engine
        # will not be able to fetch it either.
        if entry is None or entry.get("result") != 1:
            broken.append((item_id, "not available (result %s)" % (entry or {}).get("result")))
            continue
        if str(entry.get("consumer_app_id")) != str(APPID):
            broken.append((item_id, "belongs to app %s" % entry.get("consumer_app_id")))
            continue
        items[item_id] = {
            "title": entry.get("title", ""),
            "manifest": str(entry["hcontent_file"]),
            "size": int(entry["file_size"]),
            "time_updated": int(entry["time_updated"]),
            "servers": sorted(name for name in names if item_id in subscriptions[name]),
        }

    if broken:
        for item_id, why in broken:
            print("  %s: %s" % (item_id, why), file=sys.stderr)
        sys.exit("%d subscribed items cannot be fetched" % len(broken))

    old = read_lock(missing_ok=True)
    groups = {}
    for item in items.values():
        groups.setdefault(group_of(item["servers"]), 0)
        groups[group_of(item["servers"])] += 1
    # Sticky: repartitioning a group invalidates every layer in it, so a count only ever gets
    # chosen once, when the group first appears.
    buckets = {
        group: old.get("buckets", {}).get(group, default_bucket_count(size))
        for group, size in sorted(groups.items())
    }

    lock = {
        "appid": APPID,
        # Sticky for the same reason the bucket counts are: moving the line repartitions things.
        "solo_bytes": old.get("solo_bytes", 512 * 2**20),
        "buckets": buckets,
        "items": {i: items[i] for i in sorted(items, key=int)},
    }
    write_lock(lock)

    total = sum(item["size"] for item in items.values())
    print("wrote %s: %d items, %.1f GB" % (rel(LOCKFILE), len(items), total / 2**30), file=sys.stderr)
    for group, count in buckets.items():
        in_group = [i for i in items.values() if group_of(i["servers"]) == group]
        gb = sum(i["size"] for i in in_group) / 2**30
        print(
            "  %-12s %3d items  %5.1f GB  %2d buckets (~%.0f MB each)"
            % (group, len(in_group), gb, count, gb * 1024 / count),
            file=sys.stderr,
        )


# --------------------------------------------------------------------------------------------
# render
# --------------------------------------------------------------------------------------------


def dockerfile_stages(lock, buckets):
    lines = []
    for group in sorted(buckets):
        for key in sorted(buckets[group]):
            ids = buckets[group][key]
            size = sum(lock["items"][i]["size"] for i in ids) / 2**20
            lines.append("")
            lines.append("# %d items, %.0f MB" % (len(ids), size))
            lines.append("FROM workshop-downloader AS %s" % stage_name(group, key))
            pinned = [
                "    %s:%s \\" % (i, lock["items"][i]["manifest"]) for i in ids
            ]
            pinned[-1] = pinned[-1].rstrip(" \\")
            lines.append("RUN fetch-items /out \\")
            lines.extend(pinned)
    return lines


def dockerfile_layers(server, buckets):
    lines = []
    for group in sorted(buckets):
        if server not in group.split("-"):
            continue
        for key in sorted(buckets[group]):
            lines.append(
                "COPY --link --chown=1000:1000 --from=%s /out"
                " /opt/insurgency-server/steamapps/workshop/content/%d/"
                % (stage_name(group, key), APPID)
            )
    return lines


def acf(lock, server):
    """The file the engine reads to decide an item is already installed and current.

    Byte-for-byte the shape it writes itself: tabs throughout, two between a key and its value, and
    items in ascending numeric order. timetouched is a last-seen stamp the engine rewrites on every
    boot, so seeding it with the publish time is as good as anything.
    """
    ids = sorted(
        (i for i, item in lock["items"].items() if server in item["servers"]), key=int
    )
    out = ['"AppWorkshop"', "{"]
    header = [
        ("appid", str(APPID)),
        ("SizeOnDisk", str(sum(lock["items"][i]["size"] for i in ids))),
        ("NeedsUpdate", "0"),
        ("NeedsDownload", "0"),
        ("TimeLastUpdated", "0"),
        ("TimeLastAppRan", "0"),
        ("LastBuildID", "0"),
    ]
    out += ['\t"%s"\t\t"%s"' % pair for pair in header]

    out += ['\t"WorkshopItemsInstalled"', "\t{"]
    for item_id in ids:
        item = lock["items"][item_id]
        out += [
            '\t\t"%s"' % item_id,
            "\t\t{",
            '\t\t\t"size"\t\t"%d"' % item["size"],
            '\t\t\t"timeupdated"\t\t"%d"' % item["time_updated"],
            '\t\t\t"manifest"\t\t"%s"' % item["manifest"],
            "\t\t}",
        ]
    out += ["\t}"]

    out += ['\t"WorkshopItemDetails"', "\t{"]
    for item_id in ids:
        item = lock["items"][item_id]
        out += [
            '\t\t"%s"' % item_id,
            "\t\t{",
            '\t\t\t"manifest"\t\t"%s"' % item["manifest"],
            '\t\t\t"timeupdated"\t\t"%d"' % item["time_updated"],
            '\t\t\t"timetouched"\t\t"%d"' % item["time_updated"],
            '\t\t\t"latest_timeupdated"\t\t"%d"' % item["time_updated"],
            '\t\t\t"latest_manifest"\t\t"%s"' % item["manifest"],
            "\t\t}",
        ]
    out += ["\t}", "}", ""]
    return "\n".join(out)


def generated(lock):
    """{path: (region name or None, content)} for everything that follows from the lockfile."""
    buckets = partition(lock)
    out = {DOCKERFILE: {}}
    out[DOCKERFILE]["workshop stages"] = dockerfile_stages(lock, buckets)
    for server in sorted({s for item in lock["items"].values() for s in item["servers"]}):
        out[DOCKERFILE]["workshop layers: %s" % server] = dockerfile_layers(server, buckets)
        out[os.path.join(SERVER_CONFIG, server, ACF)] = acf(lock, server)
    return out


MARKER = "# %s workshop-lock: %s %s"


def splice(text, region, lines):
    start = MARKER % (">>>", region, ">>>")
    end = MARKER % ("<<<", region, "<<<")
    if start not in text or end not in text:
        sys.exit("Dockerfile is missing the %r markers" % region)
    head, rest = text.split(start, 1)
    _, tail = rest.split(end, 1)
    body = "\n".join([start] + lines + [end])
    return head + body + tail


def rendered(lock):
    """{path: file content} after splicing the generated regions into what is on disk."""
    out = {}
    plan = generated(lock)
    for path, value in plan.items():
        if path == DOCKERFILE:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            for region in sorted(value):
                text = splice(text, region, value[region])
            out[path] = text
        else:
            out[path] = value
    return out


def render(args):
    for path, content in sorted(rendered(read_lock()).items()):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        existing = None
        if os.path.exists(path):
            with open(path, encoding="utf-8") as handle:
                existing = handle.read()
        if existing == content:
            print("  unchanged %s" % rel(path), file=sys.stderr)
            continue
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        print("  wrote     %s" % rel(path), file=sys.stderr)


def check(args):
    """Only the Dockerfile is checked. It is committed, so a stale copy is a mistake in the repo;
    the .acf files are build output, regenerated by every server build and never committed."""
    stale = []
    for path, content in sorted(rendered(read_lock()).items()):
        if path != DOCKERFILE:
            continue
        if not os.path.exists(path):
            stale.append(path)
            continue
        with open(path, encoding="utf-8") as handle:
            if handle.read() != content:
                stale.append(path)
    if stale:
        for path in stale:
            print("  stale %s" % rel(path), file=sys.stderr)
        sys.exit("run `make workshop-render` and commit the result")
    print("Dockerfile is up to date with the lockfile", file=sys.stderr)


# --------------------------------------------------------------------------------------------


def rel(path):
    return os.path.relpath(path, REPO)


def read_lock(missing_ok=False):
    if not os.path.exists(LOCKFILE):
        if missing_ok:
            return {}
        sys.exit("%s does not exist; run `make workshop-lock`" % rel(LOCKFILE))
    with open(LOCKFILE, encoding="utf-8") as handle:
        return json.load(handle)


def write_lock(lock):
    with open(LOCKFILE, "w", encoding="utf-8") as handle:
        json.dump(lock, handle, indent=2, sort_keys=False)
        handle.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("refresh", help="re-pin every subscribed item to what Steam serves now")
    sub.add_parser("render", help="regenerate the build inputs that follow from the lockfile")
    sub.add_parser("check", help="fail if the committed Dockerfile is out of date")
    args = parser.parse_args()
    {"refresh": refresh, "render": render, "check": check}[args.command](args)


if __name__ == "__main__":
    main()
