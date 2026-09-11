#!/usr/bin/env python3
"""Report map assets that are referenced but not available.

WHY
A client that cannot load a material does not cache the failure. It retries every time something
asks for that material - many times a second - and the framerate collapses:

    CMaterial::PrecacheVars: error loading vmt file for decals/rug_green01

That is a mapper packing error, and it is invisible until someone plays the map and notices their
FPS die. This finds them ahead of time.

HOW
For each BSP: collect every material the map refers to (brush faces, and entity keyvalues like an
infodecal's "texture"), then subtract what the map embeds in its own pakfile and what a client
already has. Whatever is left is what will fail to load.

"What a client already has" has to come from outside this repo - see --content-index and
collect_content_index.py. Without one, the audit still runs but can only separate "packed" from
"not packed", and every stock material shows up as a false positive.

USAGE
    audit.py MAP.bsp [MAP.bsp ...] --content-index index.txt
    audit.py --maps-dir /path/to/maps --content-index index.txt --json report.json
"""
import argparse, json, os, re, sys, collections
from bsplib import Bsp

# Entity keyvalues that name a material. "model" is included because env_sprite and friends point
# at a .vmt through it, which is a different shape of the same bug.
MATERIAL_KEYS = ("texture", "material", "detailmaterial", "overlaymaterial")

# ...but "material" is not always a path. On func_breakable and friends it is the gib type enum
# (0 glass, 1 wood, 2 metal, 3 flesh...), so reading it as a material reports every breakable crate
# in the map pool as a missing asset named "0".
ENUM_MATERIAL_CLASSES = ("func_breakable", "func_breakable_surf", "func_physbox", "prop_physics",
                         "prop_physics_multiplayer", "prop_door_rotating")


def normalise_material(value):
    """Reduce an entity value or face material to the form used in the content index.

    Entity values are written by mappers and come in every shape: with or without a leading slash,
    with or without the "materials/" prefix, with or without the ".vmt" suffix. Comparing them raw
    reports things like "sprites/light_glow02_add_noz.vmt" missing while the index holds the same
    path without the extension.
    """
    v = value.strip().lower().replace("\\", "/").lstrip("/")
    if v.startswith("materials/"):
        v = v[len("materials/"):]
    if v.endswith(".vmt"):
        v = v[:-4]
    return v


def referenced_materials(bsp):
    """-> {material_path: [reasons]} with paths normalised the way a VMT lookup sees them."""
    refs = collections.defaultdict(list)

    for mat in bsp.face_materials():
        norm = normalise_material(mat)
        if norm:
            refs[norm].append("brush face")

    ents = bsp.entities()
    for block in re.findall(r"\{[^{}]*\}", ents):
        kvs = dict(re.findall(r'"([^"]+)"\s+"([^"]*)"', block))
        classname = kvs.get("classname", "?")
        for key in MATERIAL_KEYS:
            val = kvs.get(key)
            if not val:
                continue
            if key == "material" and classname in ENUM_MATERIAL_CLASSES:
                continue
            norm = normalise_material(val)
            # A bare number is an enum on some entity we have not listed, not a material.
            if not norm or norm.isdigit():
                continue
            refs[norm].append("%s.%s" % (classname, key))
        # env_sprite's "model" is a material path; a studio model is not.
        model = kvs.get("model", "")
        if model.lower().endswith(".vmt"):
            refs[normalise_material(model)].append("%s.model" % classname)

    return refs


def load_content_index(path):
    """A newline-separated list of material paths a client can resolve (no 'materials/' prefix,
    no '.vmt' suffix - collect_content_index.py emits exactly that)."""
    out = set()
    with open(path, "r", errors="replace") as f:
        for line in f:
            line = line.strip().lower().replace("\\", "/")
            if not line or line.startswith("#"):
                continue
            if line.startswith("materials/"):
                line = line[len("materials/"):]
            if line.endswith(".vmt"):
                line = line[:-4]
            out.add(line)
    return out


def audit(path, content):
    bsp = Bsp(path)
    packed = bsp.packed()
    refs = referenced_materials(bsp)

    missing = {}
    for mat, reasons in sorted(refs.items()):
        if not mat or mat.startswith("tools/"):      # toolstrigger etc. are never rendered
            continue
        if ("materials/%s.vmt" % mat) in packed:
            continue
        if content is not None and mat in content:
            continue
        missing[mat] = sorted(set(reasons))

    return {
        "map": os.path.splitext(os.path.basename(path))[0],
        "bsp_version": bsp.version,
        "referenced": len(refs),
        "packed_files": len(packed),
        "missing": missing,
    }



# Entities that must never be stripped, whatever the audit says. worldspawn holds map-wide settings
# (skybox, fog, detail material) and removing it breaks the level; an audit WILL flag its
# "detailmaterial" as a missing asset referenced by an entity, so this is a live trap rather than a
# theoretical one. gg2_strip_entities refuses these too - belt and braces.
NEVER_STRIP = ("worldspawn",)


def write_strip_config(reports, path):
    """Emit gg2_strip_entities rules for every finding reachable by removing an entity."""
    out = ['// Generated by tools/bspaudit/audit.py - review before use.',
           '//',
           '// One rule per material that is referenced by an entity and cannot be resolved by a client.',
           '// Removing the entity removes the reference, which is what stops the failed-material retry',
           '// storm. Findings that came from brush faces are NOT here - there is no entity to remove and',
           '// they need a stub material shipped to clients instead.',
           '"StripEntities"',
           '{']
    rules = 0
    for r in sorted(reports, key=lambda x: x["map"]):
        lines = []
        for mat, reasons in sorted(r["missing"].items()):
            for reason in reasons:
                if "." not in reason:
                    continue
                classname, key = reason.rsplit(".", 1)
                if classname in NEVER_STRIP:
                    continue
                lines.append((mat, classname, key))
        if not lines:
            continue
        out.append('\t"%s"' % r["map"])
        out.append('\t{')
        for i, (mat, classname, key) in enumerate(lines):
            out.append('\t\t"rule%d"' % i)
            out.append('\t\t{')
            out.append('\t\t\t"classname"\t\t"%s"' % classname)
            out.append('\t\t\t"key"\t\t\t"%s"' % key)
            out.append('\t\t\t"value"\t\t\t"%s"' % mat)
            out.append('\t\t\t"note"\t\t\t"Auto-generated: material not packed by the map and not resolvable by a client."')
            out.append('\t\t}')
            rules += 1
        out.append('\t}')
    out.append('}')
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print("\nwrote %d strip rule(s) to %s" % (rules, path))

# A material a client can definitely resolve, used as every stub's base texture.
#
# It has to be a real texture or the stub is pointless. Using one that ships with the game avoids
# redistributing art and keeps the item to a few KB of text - but it IS an assumption, and the one
# thing in this pipeline that cannot be verified from here. dev/dev_measuregeneric01 is present in
# the collected content index and is a standard Source dev texture.
#
# Deliberately a loud placeholder rather than something that blends in: these surfaces are still
# broken, and a visible grid is a reminder where a plausible concrete would hide the problem.
STUB_BASETEXTURE = "dev/dev_measuregeneric01"

STUB_LINES = [
    "// STUB - generated by tools/bspaudit/audit.py",
    "//",
    "// %(material)s",
    "// Referenced by: %(maps)s",
    "//",
    "// This material is referenced by the map but is neither packed in its BSP nor resolvable by a",
    "// client. A failed VMT lookup is NOT cached, so the client retries it constantly and the",
    "// framerate collapses. This file exists so the lookup SUCCEEDS - it does not reproduce the",
    "// original art, and the surface renders as a placeholder grid.",
    "//",
    "// LightmappedGeneric because every one of these is a brush face. Materials referenced by an",
    "// entity are handled by removing the entity instead - see gg2_strip_entities.",
    '"LightmappedGeneric"',
    "{",
    '\t"$basetexture" "%(basetexture)s"',
    '\t"$surfaceprop" "concrete"',
    "}",
    "",
]


def write_stubs(reports, out_dir):
    """One VMT per material that is referenced by a brush face and cannot be resolved."""
    face = {}
    for r in reports:
        for mat, reasons in r["missing"].items():
            if "brush face" in reasons:
                face.setdefault(mat, set()).add(r["map"])

    written = 0
    for mat, maps in sorted(face.items()):
        # VBSP can emit a doubled separator when the source material name began with a slash.
        # The engine normalises that on lookup; a real file cannot contain it.
        rel = re.sub(r"/{2,}", "/", mat) + ".vmt"
        path = os.path.join(out_dir, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        body = "\n".join(STUB_LINES) % {
            "material": mat,
            "maps": ", ".join(sorted(maps)),
            "basetexture": STUB_BASETEXTURE,
        }
        with open(path, "w") as f:
            f.write(body)
        written += 1

    print("\nwrote %d stub material(s) to %s" % (written, out_dir))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bsps", nargs="*")
    ap.add_argument("--maps-dir", help="audit every .bsp under this directory, recursively")
    ap.add_argument("--content-index", help="materials a client can already resolve")
    ap.add_argument("--json", help="write the full report here")
    ap.add_argument("--quiet-clean", action="store_true", help="only print maps with findings")
    ap.add_argument("--strip-config", help="write gg2_strip_entities rules for the strippable findings")
    ap.add_argument("--stub-dir", help="write stub VMTs for the findings that cannot be stripped")
    args = ap.parse_args()

    paths = list(args.bsps)
    if args.maps_dir:
        for root, _dirs, files in os.walk(args.maps_dir):
            paths += [os.path.join(root, f) for f in files if f.lower().endswith(".bsp")]
    if not paths:
        ap.error("no BSPs given")

    content = load_content_index(args.content_index) if args.content_index else None
    if content is None:
        print("WARNING: no --content-index, so stock materials will show as missing.\n", file=sys.stderr)

    reports, bad = [], 0
    for p in sorted(paths):
        try:
            r = audit(p, content)
        except Exception as e:
            print("%-34s ERROR %s" % (os.path.basename(p), e))
            continue
        reports.append(r)
        if r["missing"]:
            bad += 1
            print("%-34s %d missing of %d referenced" % (r["map"], len(r["missing"]), r["referenced"]))
            for mat, reasons in sorted(r["missing"].items()):
                strippable = all(rs != "brush face" for rs in [reasons] for rs in reasons)
                print("    %-44s %-28s %s" % (mat, ",".join(reasons),
                                              "STRIPPABLE" if strippable else "needs stub material"))
        elif not args.quiet_clean:
            print("%-34s clean (%d referenced, %d packed)" % (r["map"], r["referenced"], r["packed_files"]))

    if args.strip_config:
        write_strip_config(reports, args.strip_config)
    if args.stub_dir:
        write_stubs(reports, args.stub_dir)

    print("\n%d map(s) audited, %d with findings." % (len(reports), bad))
    if args.json:
        with open(args.json, "w") as f:
            json.dump(reports, f, indent=2, sort_keys=True)
        print("report: %s" % args.json)


if __name__ == "__main__":
    main()
