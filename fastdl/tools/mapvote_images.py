#!/usr/bin/env python3
"""Generate map vote images for mapcycle maps that have none, from each map's workshop preview.

The end-of-round vote panel draws each candidate map from, in order:

    materials/vgui/maps/<map>_large.vmt           the stock loading-screen image
    materials/vgui/maps/<map>_small.vmt           (with a "using incorrect size" warning)
    materials/vgui/endroundlobby/maps/<map>.vmt   "falling back to old voting image"
    materials/vgui/maps/fallback_large.vmt        a generic placeholder

(client.so, the function that formats "materials/vgui/maps/%s_%s.vmt"; the vote panel calls it with
large=1.) Stock maps have the first. Custom maps mostly get the third from the "map vote ui" workshop
item (890084623), and the rest show the placeholder. This fills that gap.

Output goes to fastdl/src/mapvote/, one image per map, which fastdl/tools/build.sh compiles to
materials/vgui/endroundlobby/maps/<map>.vtf/.vmt. That path is the LOWEST-priority lookup in the chain
above, so an image a mapper or the vote pack ships later always wins over ours - nothing generated
here can hide a real one.

    mapvote_images.py            index what is new, then generate what is missing
    mapvote_images.py --fetch    also download (then delete) locked items this machine lacks, so the
                                 index is complete; refuses to generate until it is
    mapvote_images.py --previews MAP
                                 list every preview image on MAP's workshop page, for picking a
                                 better one than the default into overrides.txt

Nothing is ever overwritten. A generated file is write-once on every client that has fetched it (the
engine skips a path it already has), so changing an image that has shipped does not reach anyone -
see the "Map vote images" section of fastdl/README.md. --force MAP exists for images that have not
shipped yet.

Coverage comes from index.json beside the images: per workshop item, at the manifest the lockfile
pins, which maps it contains, which vote/loading images it ships, and which vote textures - a
texture made for a map but behind a misnamed VMT becomes an alias rather than a new image. Committed, so a run on a machine
with no workshop content still knows everything; an item is only rescanned when its pin moves.
"""

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

APPID = 222880
API = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
PAGE = "https://steamcommunity.com/sharedfiles/filedetails/?id=%s"

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(TOOLS))
OUT = os.path.join(REPO, "fastdl", "src", "mapvote")
INDEX = os.path.join(OUT, "index.json")
OVERRIDES = os.path.join(OUT, "overrides.txt")
LOCKFILE = os.path.join(REPO, "workshop.lock.json")
SERVER_CONFIG = os.path.join(REPO, "server config")
NOT_SERVERS = {"base", "_template"}
MAPCYCLE = os.path.join("opt", "insurgency-server", "insurgency", "mapcycle.txt")
GAME_DIR = os.path.join(REPO, "client", "insurgency")
STEAM_CONTENT = os.path.expanduser(
    "~/.local/share/Steam/steamapps/workshop/content/%d" % APPID
)

sys.path.insert(0, os.path.join(REPO, "tools", "bspaudit"))
import bsplib  # noqa: E402

VOTE_DIR = "vgui/endroundlobby/maps/"
LOADING_DIR = "vgui/maps/"
SIZE = "512x256"  # every image in the vote pack


# --------------------------------------------------------------------------------------------
# Reading content
# --------------------------------------------------------------------------------------------


def vpk_names(path):
    """Every file name in a VPK directory tree, lowercased. VPK v1 and v2 share the tree format."""
    with open(path, "rb") as f:
        head = f.read(12)
        sig, ver, tree = struct.unpack("<III", head)
        if sig != 0x55AA1234:
            return set()
        f.seek(12 if ver == 1 else 28)
        d = f.read(tree)
    names, o = set(), 0

    def cstr():
        nonlocal o
        e = d.index(b"\0", o)
        s = d[o:e].decode("latin1")
        o = e + 1
        return s

    while True:
        ext = cstr()
        if not ext:
            break
        while True:
            folder = cstr()
            if not folder:
                break
            while True:
                name = cstr()
                if not name:
                    break
                preload = struct.unpack_from("<H", d, o + 4)[0]
                o += 18 + preload
                full = "%s.%s" % (name, ext) if folder.strip() == "" else "%s/%s.%s" % (folder, name, ext)
                names.add(full.lower())
    return names


def image_of(path, ext=".vmt"):
    """'vgui/.../x' for a vote or loading-screen file of this type, else None. Paths are game-relative."""
    p = path.lower().replace("\\", "/")
    if not (p.startswith("materials/") and p.endswith(ext)):
        return None
    p = p[len("materials/"):-len(ext)]
    return p if p.startswith(VOTE_DIR) or p.startswith(LOADING_DIR) else None


def scan(root):
    """What a content directory holds: map names (from .bsp files), vote/loading images (VMTs) and
    the textures behind them, whether loose, in a VPK, or packed into a map's pakfile.

    Textures are kept separately because they do not always pair up by name: the vote pack ships
    anbar_coop.vtf behind a VMT called anbar.vmt, so the map anbar_coop finds no image while the
    picture made for it sits unused. Such a map gets a VMT pointing at it instead of a generated
    image."""
    maps, images, textures = set(), set(), set()
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            names = {rel.lower()}
            low = f.lower()
            # Numbered archives (_000.vpk) hold data only; the tree is in _dir.vpk or a lone .vpk.
            if low.endswith(".vpk") and not re.search(r"_\d{3}\.vpk$", low):
                try:
                    names |= vpk_names(full)
                except (OSError, ValueError, struct.error) as e:
                    print("  warning: unreadable VPK %s: %s" % (rel, e), file=sys.stderr)
            if low.endswith(".bsp"):
                maps.add(low[:-4])
                try:
                    names |= bsplib.Bsp(full).packed()
                except (OSError, ValueError) as e:
                    print("  warning: unreadable BSP %s: %s" % (rel, e), file=sys.stderr)
            for n in names:
                img = image_of(n)
                if img:
                    images.add(img)
                tex = image_of(n, ".vtf")
                if tex:
                    textures.add(tex)
    return sorted(maps), sorted(images), sorted(textures)


def acf_manifests(path):
    """{item id: manifest} from an appworkshop_<appid>.acf, for the items it says are installed."""
    out = {}
    if not os.path.isfile(path):
        return out
    section, item = "", None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if re.match(r'^\t"[A-Za-z]', line):
                section = line.strip().strip('"')
            if section != "WorkshopItemsInstalled":
                continue
            m = re.match(r'^\t\t"(\d+)"\s*$', line)
            if m:
                item = m.group(1)
            m = re.search(r'"manifest"\s+"(\d+)"', line)
            if m and item:
                out[item] = m.group(1)
    return out


# --------------------------------------------------------------------------------------------
# Inputs
# --------------------------------------------------------------------------------------------


def servers():
    return sorted(
        s for s in os.listdir(SERVER_CONFIG)
        if s not in NOT_SERVERS and os.path.isfile(os.path.join(SERVER_CONFIG, s, MAPCYCLE))
    )


def mapcycle(server):
    """Map names in the order the file lists them, keeping the file's spelling."""
    seen, out = set(), []
    with open(os.path.join(SERVER_CONFIG, server, MAPCYCLE), encoding="utf-8") as f:
        for line in f:
            tok = re.sub(r"//.*", "", line).split()
            if tok and tok[0].lower() not in seen:
                seen.add(tok[0].lower())
                out.append(tok[0])
    return out


def read_overrides():
    """overrides.txt: `<map> skip`, `<map> item <id>`, `<map> url <url>`, `<map> alias <texture>`."""
    out = {}
    if not os.path.isfile(OVERRIDES):
        return out
    with open(OVERRIDES, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            # A comment starts a line or follows whitespace - a bare "//" is the one in "https://".
            tok = re.sub(r"(^|\s)//.*", "", line).split()
            if not tok:
                continue
            ok = (len(tok) == 2 and tok[1] == "skip") or (
                len(tok) == 3 and tok[1] in ("item", "url", "alias"))
            if not ok:
                sys.exit("%s:%d: cannot parse %r" % (OVERRIDES, n, line.strip()))
            out[tok[0].lower()] = tok[1:]
    return out


def outputs():
    """{map lowercased: filename} for what is already in fastdl/src/mapvote."""
    out = {}
    if os.path.isdir(OUT):
        for f in os.listdir(OUT):
            stem, ext = os.path.splitext(f)
            if ext.lower() in (".jpg", ".png", ".vmt"):
                out[stem.lower()] = f
    return out


def http(url, data=None):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": "tug2-mapvote-images"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def details(ids):
    form = {"itemcount": len(ids)}
    for i, x in enumerate(ids):
        form["publishedfileids[%d]" % i] = x
    raw = http(API, urllib.parse.urlencode(form).encode())
    return {d["publishedfileid"]: d for d in json.loads(raw)["response"]["publishedfiledetails"]}


# --------------------------------------------------------------------------------------------
# Index
# --------------------------------------------------------------------------------------------


def load_index():
    if os.path.isfile(INDEX):
        with open(INDEX, encoding="utf-8") as f:
            return json.load(f)
    return {"base": {"maps": [], "images": []}, "items": {}}


def save_index(index):
    os.makedirs(OUT, exist_ok=True)
    with open(INDEX, "w", encoding="utf-8") as f:
        json.dump(index, f, indent=1, sort_keys=True)
        f.write("\n")


def refresh_index(index, lock, roots, fetch, batch_bytes):
    """Bring the index up to the lockfile. Returns ids still unindexed."""
    items = lock["items"]
    idx = index["items"]
    for gone in sorted(set(idx) - set(items)):
        del idx[gone]

    if os.path.isfile(os.path.join(GAME_DIR, "gameinfo.txt")):
        names = set()
        for f in sorted(os.listdir(GAME_DIR)):
            if f.endswith("_dir.vpk"):
                names |= vpk_names(os.path.join(GAME_DIR, f))
        maps_dir = os.path.join(GAME_DIR, "maps")
        index["base"] = {
            "maps": sorted(f[:-4].lower() for f in os.listdir(maps_dir) if f.endswith(".bsp")),
            "images": sorted({i for i in map(image_of, names) if i}),
            "textures": sorted({t for t in (image_of(n, ".vtf") for n in names) if t}),
        }
    elif not index["base"]["images"]:
        sys.exit("No base game at %s and none indexed yet - the stock images are unknown." % GAME_DIR)

    # An entry from before textures were recorded is incomplete, not merely old.
    stale = [i for i in items if idx.get(i, {}).get("manifest") != items[i]["manifest"]
             or "textures" not in idx[i]]
    missing = []
    for item in stale:
        for root in roots:
            path = os.path.join(root, item)
            if not os.path.isdir(path):
                continue
            # A local copy is only trusted at the pinned version; where no .acf records one, assume
            # it (the Steam client's own dir always has one).
            have = acf_manifests(os.path.join(os.path.dirname(os.path.dirname(root)),
                                              "appworkshop_%d.acf" % APPID)).get(item)
            if have and have != items[item]["manifest"]:
                continue
            print("indexing %s %s (local)" % (item, items[item]["title"]))
            maps, images, textures = scan(path)
            idx[item] = {"manifest": items[item]["manifest"], "maps": maps, "images": images,
                         "textures": textures}
            save_index(index)
            break
        else:
            missing.append(item)

    if missing and fetch:
        missing = fetch_and_index(index, lock, missing, batch_bytes)
    return missing


def fetch_and_index(index, lock, ids, batch_bytes):
    """Download items with steamcmd into a scratch dir, a batch at a time so a full disk is never
    needed, index each, and delete it. steamcmd always fetches the CURRENT version, so an item whose
    pin has moved on is indexed at what arrived and flagged - re-pin with `make workshop-lock`."""
    items = lock["items"]
    left = []
    batches, cur, size = [], [], 0
    for i in sorted(ids, key=lambda x: items[x]["size"]):
        if cur and size + items[i]["size"] > batch_bytes:
            batches.append(cur)
            cur, size = [], 0
        cur.append(i)
        size += items[i]["size"]
    if cur:
        batches.append(cur)

    for n, batch in enumerate(batches, 1):
        tmp = tempfile.mkdtemp(prefix="mapvote-fetch-")
        try:
            print("fetching batch %d/%d: %s" % (n, len(batches), " ".join(batch)))
            cmd = ["steamcmd", "+force_install_dir", tmp, "+login", "anonymous"]
            for i in batch:
                cmd += ["+workshop_download_item", str(APPID), i]
            subprocess.run(cmd + ["+quit"], stdout=subprocess.DEVNULL, check=False)
            ws = os.path.join(tmp, "steamapps", "workshop")
            got = acf_manifests(os.path.join(ws, "appworkshop_%d.acf" % APPID))
            for i in batch:
                path = os.path.join(ws, "content", str(APPID), i)
                if not os.path.isdir(path):
                    print("  %s: download failed" % i, file=sys.stderr)
                    left.append(i)
                    continue
                if got.get(i) != items[i]["manifest"]:
                    print("  %s: Steam served manifest %s, lockfile pins %s - indexed anyway; "
                          "re-pin with `make workshop-lock`" % (i, got.get(i), items[i]["manifest"]),
                          file=sys.stderr)
                print("indexing %s %s (fetched)" % (i, items[i]["title"]))
                maps, images, textures = scan(path)
                index["items"][i] = {"manifest": got.get(i) or "?", "maps": maps, "images": images,
                                     "textures": textures}
                save_index(index)
                shutil.rmtree(path, ignore_errors=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return left


# --------------------------------------------------------------------------------------------
# Generating
# --------------------------------------------------------------------------------------------


def covered(name, images):
    n = name.lower()
    return (VOTE_DIR + n in images or LOADING_DIR + n + "_large" in images
            or LOADING_DIR + n + "_small" in images)


def sidecar(map_name, item, title, url):
    return (
        "// Vote image for %s. Workshop item %s (%s), preview:\n"
        "// %s\n"
        "// Generated by fastdl/tools/mapvote_images.py. Move the crop with focusx/focusy (0-1).\n"
        '"format"  "DXT1"\n'
        '"nomip"   "1"\n'
        '"nolod"   "1"\n'
        '"fit"     "%s"\n'
        '"focusx"  "0.5"\n'
        '"focusy"  "0.5"\n'
    ) % (map_name, item or "-", title or "-", url, SIZE)


def alias_vmt(map_name, texture):
    return (
        "// Vote image for %s: reuses %s, which clients already have.\n"
        "// Generated by fastdl/tools/mapvote_images.py.\n"
        '"UnlitGeneric"\n{\n'
        '\t"$basetexture"\t"%s"\n'
        '\t"$vertexcolor"\t1\n'
        '\t"$vertexalpha"\t1\n'
        '\t"$ignorez"\t\t1\n'
        '\t"$no_fullbright"\t1\n'
        '\t"$nolod"\t\t\t1\n'
        "}\n"
    ) % (map_name, texture, texture)


def write_image(map_name, url, item, title):
    data = http(url)
    if data[:3] == b"\xff\xd8\xff":
        ext = ".jpg"
    elif data[:8] == b"\x89PNG\r\n\x1a\n":
        ext = ".png"
    else:
        raise ValueError("preview is neither JPEG nor PNG (starts %r)" % data[:8])
    path = os.path.join(OUT, map_name + ext)
    with open(path, "wb") as f:
        f.write(data)
    with open(path + ".txt", "w", encoding="utf-8") as f:
        f.write(sidecar(map_name, item, title, url))
    return os.path.basename(path)


def remove_output(existing):
    for f in (existing, existing + ".txt"):
        p = os.path.join(OUT, f)
        if os.path.exists(p):
            os.remove(p)


def previews(item):
    """Every preview on an item's workshop page - the API only returns the first."""
    html = http(PAGE % item).decode("utf-8", "replace")
    seen, out = set(), []
    for u in re.findall(r"https://images\.steamusercontent\.com/ugc/\d+/[0-9A-F]+/", html):
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


def owner(map_name, index, subscribed):
    """The subscribed item holding the map's BSP."""
    hits = [i for i in subscribed if map_name.lower() in index["items"].get(i, {}).get("maps", [])]
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--fetch", action="store_true",
                    help="download unindexed locked items with steamcmd (deleted after indexing)")
    ap.add_argument("--fetch-batch-mb", type=int, default=1024,
                    help="most content held on disk at once while fetching (default 1024)")
    ap.add_argument("--content", action="append", default=[],
                    help="extra workshop content root (<...>/content/222880); repeatable")
    ap.add_argument("--force", action="append", default=[], metavar="MAP",
                    help="regenerate MAP even though an image exists - only if it has not shipped")
    ap.add_argument("--previews", metavar="MAP", help="list MAP's workshop preview images and exit")
    ap.add_argument("--dry-run", action="store_true", help="report without writing images")
    args = ap.parse_args()

    with open(LOCKFILE, encoding="utf-8") as f:
        lock = json.load(f)
    index = load_index()
    roots = [r for r in [STEAM_CONTENT] + args.content if os.path.isdir(r)]
    missing = refresh_index(index, lock, roots, args.fetch, args.fetch_batch_mb << 20)
    save_index(index)

    per_server = {s: [i for i, v in lock["items"].items() if s in v["servers"]] for s in servers()}

    if args.previews:
        subscribed = sorted({i for ids in per_server.values() for i in ids})
        for item in owner(args.previews, index, subscribed):
            print("%s (%s):" % (item, lock["items"][item]["title"]))
            for u in previews(item):
                print("  " + u)
        return

    if missing:
        print("\n%d locked item(s) are not indexed, so coverage is unknown:" % len(missing))
        for i in missing:
            print("  %s  %s" % (i, lock["items"][i]["title"]))
        sys.exit("Run with --fetch (or --content <dir holding them>) before generating.")

    overrides = read_overrides()
    have = outputs()
    base = set(index["base"]["images"])
    # Our own outputs count as covering nothing: they are what is being decided.
    status = {}  # map lowercased -> (spelling, {server: covered})
    orphan = {}  # map lowercased -> {server: its own vote texture exists, unreferenced}
    server_textures = {}
    for s, ids in per_server.items():
        images, textures = set(base), set(index["base"].get("textures", []))
        for i in ids:
            images |= set(index["items"][i]["images"])
            textures |= set(index["items"][i]["textures"])
        server_textures[s] = textures
        for m in mapcycle(s):
            status.setdefault(m.lower(), (m, {}))[1][s] = covered(m, images)
            orphan.setdefault(m.lower(), {})[s] = VOTE_DIR + m.lower() in textures

    todo, mixed = [], []
    for low, (spelling, cov) in sorted(status.items()):
        if all(cov.values()):
            continue
        if any(cov.values()):
            mixed.append((spelling, cov))
            continue
        todo.append(spelling)

    # Anything we generated that a real image now covers should stop shipping.
    superseded = sorted(have[low] for low in have
                        if low in status and all(status[low][1].values()))
    orphaned = sorted(have[low] for low in have if low not in status)

    force = {m.lower() for m in args.force}
    wanted, made, skipped, unresolved, kept = [], [], [], [], []
    for m in todo:
        low = m.lower()
        if low in have and low not in force:
            kept.append(have[low])
            continue
        ov = overrides.get(low)
        if ov and ov[0] == "skip":
            skipped.append(m)
            continue
        servers_of = [s for s in status[low][1]]
        subscribed = sorted({i for s in servers_of for i in per_server[s]})
        if ov and ov[0] == "alias":
            # An alias to a texture a client lacks is a missing-material error, not a placeholder.
            lacking = [s for s in servers_of if ov[1].lower() not in server_textures[s]]
            if lacking:
                unresolved.append((m, "alias target %s is not on %s" % (ov[1], ", ".join(lacking))))
                continue
            wanted.append((m, "alias", ov[1], None))
        elif not ov and all(orphan[low].values()):
            wanted.append((m, "alias", VOTE_DIR + low, None))
        elif ov and ov[0] == "url":
            hits = owner(m, index, subscribed)
            wanted.append((m, "url", ov[1], hits[0] if hits else None))
        else:
            hits = [ov[1]] if ov and ov[0] == "item" else owner(m, index, subscribed)
            if not hits:
                stock = low in index["base"]["maps"]
                unresolved.append((m, "stock map with no image" if stock else "no item holds its BSP"))
                continue
            if len(hits) > 1:
                print("  note: %s is in several items (%s); using %s" % (m, " ".join(hits), hits[0]))
            wanted.append((m, "item", hits[0], hits[0]))

    need = sorted({w[2] for w in wanted if w[1] == "item"})
    info = details(need) if need else {}
    for m, kind, what, item in wanted:
        title = lock["items"][item]["title"] if item else None
        if low_existing := have.get(m.lower()):
            if not args.dry_run:
                remove_output(low_existing)
        if kind == "alias":
            if not args.dry_run:
                with open(os.path.join(OUT, m + ".vmt"), "w", encoding="utf-8") as f:
                    f.write(alias_vmt(m, what))
            made.append("%s.vmt -> %s" % (m, what))
            continue
        url = what if kind == "url" else info.get(what, {}).get("preview_url")
        if not url:
            unresolved.append((m, "item %s has no preview image" % what))
            continue
        if args.dry_run:
            made.append("%s <- %s" % (m, url))
            continue
        try:
            made.append("%s <- item %s" % (write_image(m, url, item, title), item or "-"))
        except (OSError, ValueError) as e:
            unresolved.append((m, "download failed: %s" % e))

    print("\n%d map(s) across %s; %d have no image on any server." % (
        len(status), ", ".join(per_server), len(todo)))
    for label, rows in (("generated", made), ("already generated", kept),
                        ("skipped (overrides.txt)", skipped)):
        if rows:
            print("\n%s (%d):" % (label, len(rows)))
            for r in rows:
                print("  " + r)
    if unresolved:
        print("\nunresolved - add an overrides.txt entry (%d):" % len(unresolved))
        for m, why in unresolved:
            print("  %-32s %s" % (m, why))
    if mixed:
        print("\ncovered on some servers only - not generated, a fastdl copy would ship to both (%d):"
              % len(mixed))
        for m, cov in mixed:
            print("  %-32s %s" % (m, " ".join("%s=%s" % (s, "yes" if c else "NO")
                                               for s, c in sorted(cov.items()))))
    if superseded or orphaned:
        print("\nno longer needed - delete these and their .txt so they stop being advertised:")
        for f in superseded:
            print("  %-32s a real image covers the map now" % f)
        for f in orphaned:
            print("  %-32s not in any mapcycle" % f)


if __name__ == "__main__":
    main()
