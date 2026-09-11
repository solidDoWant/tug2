"""Minimal Source BSP reader - just the lumps needed to audit map assets.

Header is "VBSP", an int version, then 64 lump descriptors of (offset, length, version, fourCC).
Only three lumps matter here:
    0   entities            the entity lump, as NUL-terminated text
    40  pakfile             a zip of everything the mapper embedded
    43  texdata string data  material names used by brush faces and displacements
"""
import struct, zipfile, io

LUMP_ENTITIES = 0
LUMP_PAKFILE = 40
LUMP_TEXDATA_STRING_DATA = 43


class Bsp:
    def __init__(self, path):
        self.path = path
        with open(path, "rb") as f:
            self.data = f.read()
        if self.data[:4] != b"VBSP":
            raise ValueError("%s is not a VBSP file (magic %r)" % (path, self.data[:4]))
        self.version = struct.unpack_from("<i", self.data, 4)[0]
        self.lumps = {}
        for i in range(64):
            off, ln, _lver, _fcc = struct.unpack_from("<iiii", self.data, 8 + i * 16)
            self.lumps[i] = (off, ln)

    def _lump(self, index):
        off, ln = self.lumps[index]
        return self.data[off:off + ln]

    def entities(self):
        return self._lump(LUMP_ENTITIES).split(b"\0")[0].decode("latin1")

    def face_materials(self):
        raw = self._lump(LUMP_TEXDATA_STRING_DATA)
        return sorted({s.decode("latin1").lower().replace("\\", "/")
                       for s in raw.split(b"\0") if s})

    def packed(self):
        """Lowercased names of everything in the embedded pakfile."""
        raw = self._lump(LUMP_PAKFILE)
        if not raw:
            return set()
        try:
            return {n.lower().replace("\\", "/") for n in zipfile.ZipFile(io.BytesIO(raw)).namelist()}
        except Exception:
            # A corrupt pakfile is itself worth knowing about, but it should not abort the audit.
            return set()
