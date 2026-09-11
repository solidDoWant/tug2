#!/usr/bin/env python3
"""Build a list of every material a client can already resolve.

RUN THIS ON A MACHINE WITH THE GAME INSTALLED, not on the server. audit.py needs it to tell a
genuinely-missing material from a stock one - without it, every base-game material shows up as a
false positive.

It is read-only: it opens VPK directory files and walks folders, and writes exactly one output
file. It never touches the game install.

    python3 collect_content_index.py --out content_index.txt

By default it looks in the usual Steam locations. Point it somewhere else with --game-dir
(the folder containing "insurgency") and --workshop-dir if Steam is installed oddly, and pass
either flag more than once to scan several libraries.

The output is one material path per line, lowercased, without the "materials/" prefix or the
".vmt" suffix - roughly a few hundred thousand lines, a handful of MB. Compresses well.
"""
import argparse, os, re, struct, sys

def vpk_entries(dir_vpk):
    """Yield every path inside a VPK, read from its directory file alone.

    VPK v1/v2 store the tree as ext \\0 path \\0 name \\0 + an 18-byte entry, repeating, with an
    empty string closing each level. Only the tree is read here - never the archive data - so this
    stays fast even for multi-GB VPK sets.
    """
    with open(dir_vpk, "rb") as f:
        head = f.read(28)
        if len(head) < 12:
            return
        sig, ver, treelen = struct.unpack_from("<III", head, 0)
        if sig != 0x55AA1234:
            return
        hdr = 12 if ver == 1 else 28
        f.seek(hdr)
        tree = f.read(treelen)

    pos = 0
    def read_str():
        nonlocal pos
        end = tree.index(b"\0", pos)
        s = tree[pos:end].decode("latin1")
        pos = end + 1
        return s

    try:
        while True:
            ext = read_str()
            if not ext:
                return
            while True:
                path = read_str()
                if not path:
                    break
                while True:
                    name = read_str()
                    if not name:
                        break
                    _crc, preload, _arch, _off, _len, _term = struct.unpack_from("<IHHIIH", tree, pos)
                    pos += 18 + preload
                    yield ("%s/%s.%s" % (path, name, ext)) if path not in ("", " ") else ("%s.%s" % (name, ext))
    except (ValueError, struct.error):
        # A truncated tree means a damaged VPK; take what was parsed rather than dying.
        return


def normalise(p):
    p = p.lower().replace("\\", "/").lstrip("/")
    if not p.endswith(".vmt"):
        return None
    p = p[:-4]
    if p.startswith("materials/"):
        p = p[len("materials/"):]
    return p


def scan_dir(root, out, label):
    before = len(out)
    vpks = 0
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            low = fn.lower()
            if low.endswith("_dir.vpk") or (low.endswith(".vpk") and "_0" not in low):
                vpks += 1
                try:
                    for entry in vpk_entries(full):
                        n = normalise(entry)
                        if n:
                            out.add(n)
                except Exception as e:
                    print("  ! %s: %s" % (full, e), file=sys.stderr)
            elif low.endswith(".vmt"):
                rel = os.path.relpath(full, root).replace(os.sep, "/")
                i = rel.lower().find("materials/")
                n = normalise(rel[i:] if i >= 0 else rel)
                if n:
                    out.add(n)
    print("  %-52s %d VPK(s), +%d materials" % (label, vpks, len(out) - before))


APPID = "222880"
GAME_FOLDER = "insurgency2"     # Insurgency (2014)'s install folder name


def steam_roots():
    """Every Steam installation root we can find, most reliable first.

    On Windows the registry is the only dependable answer - Steam is routinely not in Program
    Files, and games are routinely on a different drive from Steam itself.
    """
    roots = []

    if sys.platform == "win32":
        try:
            import winreg
            for hive, key, value in (
                (winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath"),
                (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath"),
                (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam", "InstallPath"),
            ):
                try:
                    with winreg.OpenKey(hive, key) as k:
                        path = winreg.QueryValueEx(k, value)[0]
                    if path and os.path.isdir(path):
                        roots.append(os.path.normpath(path))
                except OSError:
                    pass
        except ImportError:
            pass

    for guess in (
        r"C:\Program Files (x86)\Steam",
        r"C:\Program Files\Steam",
        os.path.expanduser("~/.steam/steam"),
        os.path.expanduser("~/.local/share/Steam"),
        os.path.expanduser("~/Library/Application Support/Steam"),
    ):
        if os.path.isdir(guess):
            roots.append(os.path.normpath(guess))

    seen, out = set(), []
    for r in roots:
        key = os.path.normcase(r)
        if key not in seen:
            seen.add(key)
            out.append(r)
    return out


def library_folders(steam_root):
    """Steam library roots listed in libraryfolders.vdf, plus the Steam root itself.

    Games are very often not in the Steam install - a second drive is the norm - so skipping this
    is the main reason a naive scan finds nothing.
    """
    libs = [steam_root]
    for name in ("libraryfolders.vdf", "config/libraryfolders.vdf"):
        vdf = os.path.join(steam_root, "steamapps", name) if name == "libraryfolders.vdf" \
              else os.path.join(steam_root, name)
        if not os.path.isfile(vdf):
            continue
        try:
            with open(vdf, "r", errors="replace") as f:
                text = f.read()
        except OSError:
            continue

        # Capture BOTH halves of every "key" "value" pair, then filter - matching only on the keys
        # of interest lets the regex start in the middle of some other pair and consume the real
        # entry's opening quote. The old layout is "1" "D:\\Games", the new one "path" "D:\\Games",
        # and an old file's "TimeNextStatsReport" "1" is exactly what triggers that misalignment.
        for key, value in re.findall(r'"([^"]*)"\s+"([^"]*)"', text):
            if key != "path" and not key.isdigit():
                continue
            candidate = value.replace("\\\\", "\\")
            if os.path.isdir(candidate):
                libs.append(os.path.normpath(candidate))

    seen, out = set(), []
    for l in libs:
        k = os.path.normcase(l)
        if k not in seen:
            seen.add(k)
            out.append(l)
    return out


def autodetect():
    """-> (game_dirs, workshop_dirs) found across every Steam library."""
    games, shops = [], []
    for root in steam_roots():
        for lib in library_folders(root):
            g = os.path.join(lib, "steamapps", "common", GAME_FOLDER)
            w = os.path.join(lib, "steamapps", "workshop", "content", APPID)
            if os.path.isdir(g):
                games.append(g)
            if os.path.isdir(w):
                shops.append(w)

    def dedupe(paths):
        seen, out = set(), []
        for p in paths:
            k = os.path.normcase(p)
            if k not in seen:
                seen.add(k)
                out.append(p)
        return out

    return dedupe(games), dedupe(shops)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game-dir", action="append", default=[], help="folder containing 'insurgency' (repeatable)")
    ap.add_argument("--workshop-dir", action="append", default=[], help="steamapps/workshop/content/222880 (repeatable)")
    ap.add_argument("--out", default="content_index.txt")
    args = ap.parse_args()

    auto_game, auto_shop = ([], [])
    if not args.game_dir or not args.workshop_dir:
        auto_game, auto_shop = autodetect()

    game = args.game_dir or auto_game
    shop = args.workshop_dir or auto_shop

    if not game:
        print("Could not find Insurgency.\n", file=sys.stderr)
        print("Looked in these Steam installs:", file=sys.stderr)
        for r in steam_roots() or ["  (none found)"]:
            print("  " + r, file=sys.stderr)
        print("\nPoint at it directly, e.g.:", file=sys.stderr)
        print(r'  python collect_content_index.py --game-dir "D:\SteamLibrary\steamapps\common\insurgency2"',
              file=sys.stderr)
        print("\nThat folder is the one containing 'insurgency'.", file=sys.stderr)
        return 1

    if not shop:
        print("NOTE: no Workshop content folder found - materials that only come from subscribed", file=sys.stderr)
        print("      items will be reported as missing. Pass --workshop-dir if you have one.\n", file=sys.stderr)

    out = set()
    print("Scanning:")
    for d in game:
        scan_dir(d, out, d)
    for d in shop:
        scan_dir(d, out, d + "  (workshop)")

    with open(args.out, "w") as f:
        f.write("# material paths resolvable by this client, no 'materials/' prefix, no '.vmt'\n")
        for m in sorted(out):
            f.write(m + "\n")
    print("\n%d unique materials -> %s" % (len(out), args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
