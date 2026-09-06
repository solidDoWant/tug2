#!/usr/bin/env python3
"""Pack a directory into a Source VPK version 2, as `<name>_dir.vpk` + `<name>_000.vpk`.

Why this exists: Insurgency enforces file consistency for theater files (sv_consistency, which is
on by default and is a separate mechanism from sv_pure). A client that lacks a byte-identical copy
of a theater the server is using is refused with "server is enforcing consistency for this file".
Files baked into the server image have no way to reach the client, so anything the client needs
has to be published as a Workshop item - and every Insurgency Workshop item is a VPK.

The dedicated server ships no VPK tool (the SDK ones are not in the srcds install), hence this.

The output layout is copied from a real, working Workshop item rather than from a spec: all 43
items in `workshop cache/contents` are version 2, store their data in a single `_000.vpk` with
archive index 0 and no preload, and carry a 48-byte "other MD5" section. The three checksums in
that section were verified byte-for-byte against `dev_35ab_theaters` (itself a theaters-only item,
so the closest possible reference) before this was written:

    treeMD5              = MD5(tree bytes)
    archiveMD5SectionMD5 = MD5(archive MD5 section)   - empty here, so MD5 of nothing
    wholeFileMD5         = MD5(every byte of the dir file preceding this field)

Usage:  pack_vpk.py <content-dir> <output-dir> <name>

`content-dir` is treated as the game root, so a file at `<content-dir>/scripts/theaters/x.theater`
is stored in the VPK as `scripts/theaters/x.theater`.
"""

import binascii
import hashlib
import os
import struct
import sys

VPK_SIGNATURE = 0x55AA1234
VPK_VERSION = 2
HEADER_SIZE = 28
# 0x7FFF would mean "data is inline in the dir file"; real items use a numbered archive, so we do.
ARCHIVE_INDEX = 0
ENTRY_TERMINATOR = 0xFFFF


def collect(content_dir):
    """Map every file under content_dir to (ext, path, basename), the VPK tree's three levels."""
    out = []
    for root, _, files in os.walk(content_dir):
        for f in sorted(files):
            full = os.path.join(root, f)
            rel = os.path.relpath(full, content_dir).replace(os.sep, "/")
            path, _, base = rel.rpartition("/")
            name, dot, ext = base.rpartition(".")
            if not dot:
                # VPK has no representation for an extensionless file; " " is the documented
                # placeholder for an empty path, but not for a missing extension.
                raise SystemExit(f"file has no extension, cannot be packed: {rel}")
            out.append((ext, path or " ", name, full))
    if not out:
        raise SystemExit(f"no files found under {content_dir}")
    return out


def build(content_dir, out_dir, name):
    entries = collect(content_dir)

    # Data first, so the tree can record each entry's offset into the archive.
    archive = bytearray()
    meta = {}
    for ext, path, base, full in entries:
        data = open(full, "rb").read()
        meta[(ext, path, base)] = (binascii.crc32(data) & 0xFFFFFFFF, len(archive), len(data))
        archive += data

    # Tree: extension -> path -> filename, each level a run of NUL-terminated strings ended by "".
    tree = bytearray()
    by_ext = {}
    for ext, path, base, _ in entries:
        by_ext.setdefault(ext, {}).setdefault(path, []).append(base)
    for ext in sorted(by_ext):
        tree += ext.encode() + b"\0"
        for path in sorted(by_ext[ext]):
            tree += path.encode() + b"\0"
            for base in sorted(by_ext[ext][path]):
                crc, offset, length = meta[(ext, path, base)]
                tree += base.encode() + b"\0"
                tree += struct.pack("<IHHIIH", crc, 0, ARCHIVE_INDEX, offset, length, ENTRY_TERMINATOR)
            tree += b"\0"
        tree += b"\0"
    tree += b"\0"

    header = struct.pack(
        "<IIIIIII",
        VPK_SIGNATURE, VPK_VERSION,
        len(tree),
        0,   # file data section - empty, everything lives in the _000 archive
        0,   # archive MD5 section - empty
        48,  # other MD5 section - the three checksums below
        0,   # signature section - unsigned, as the reference item is
    )

    body = header + bytes(tree)
    other = hashlib.md5(bytes(tree)).digest() + hashlib.md5(b"").digest()
    body += other
    body += hashlib.md5(body).digest()   # whole-file MD5 covers everything preceding it

    os.makedirs(out_dir, exist_ok=True)
    dir_path = os.path.join(out_dir, f"{name}_dir.vpk")
    arc_path = os.path.join(out_dir, f"{name}_000.vpk")
    open(dir_path, "wb").write(body)
    open(arc_path, "wb").write(bytes(archive))
    return dir_path, arc_path, entries


def verify(dir_path, arc_path, entries):
    """Read the result back with an independent parser and check every file round-trips."""
    b = open(dir_path, "rb").read()
    arc = open(arc_path, "rb").read()
    sig, ver, tree_size, data_sz, amd5, omd5, ssz = struct.unpack_from("<IIIIIII", b, 0)
    assert sig == VPK_SIGNATURE and ver == VPK_VERSION, "bad signature/version"
    off = HEADER_SIZE + tree_size + data_sz + amd5
    assert hashlib.md5(b[HEADER_SIZE:HEADER_SIZE + tree_size]).digest() == b[off:off + 16], "tree MD5"
    assert hashlib.md5(b[:off + 32]).digest() == b[off + 32:off + 48], "whole-file MD5"

    def cstr(buf, i):
        j = buf.index(b"\0", i)
        return buf[i:j].decode(), j + 1

    seen = {}
    i = HEADER_SIZE
    while True:
        ext, i = cstr(b, i)
        if not ext:
            break
        while True:
            path, i = cstr(b, i)
            if not path:
                break
            while True:
                base, i = cstr(b, i)
                if not base:
                    break
                crc, pre, aidx, eoff, elen, _ = struct.unpack_from("<IHHIIH", b, i)
                i += 18 + pre
                data = arc[eoff:eoff + elen]
                assert binascii.crc32(data) & 0xFFFFFFFF == crc, f"CRC mismatch for {base}.{ext}"
                key = f"{'' if path == ' ' else path + '/'}{base}.{ext}"
                seen[key] = data

    for ext, path, base, full in entries:
        key = f"{'' if path == ' ' else path + '/'}{base}.{ext}"
        assert key in seen, f"missing from VPK: {key}"
        assert seen[key] == open(full, "rb").read(), f"content differs: {key}"
    return len(seen)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    content_dir, out_dir, name = sys.argv[1:4]
    dir_path, arc_path, entries = build(content_dir, out_dir, name)
    count = verify(dir_path, arc_path, entries)
    print(f"packed {count} file(s)")
    print(f"  {dir_path} ({os.path.getsize(dir_path)} bytes)")
    print(f"  {arc_path} ({os.path.getsize(arc_path)} bytes)")


if __name__ == "__main__":
    main()
