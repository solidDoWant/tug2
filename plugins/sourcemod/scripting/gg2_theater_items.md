# Theater item name ↔ ID lookup

Resolves theater item **names** to the integer **IDs** the `inventory_*` console commands and the
netprops use, and back again — automatically, server-side, with nothing to configure.

```sourcepawn
#include <theateritems>

public void TheaterItems_OnReady()
{
    int id = TheaterItem_Find(TheaterCategory_Upgrade, "ammo_ap_m107");   // 186
}
```

## The problem

Everything a theater defines is addressed at runtime by an integer — `m_upgradeSlots` holds upgrade
IDs, `inventory_buy_weapon` takes a weapon ID, `m_EquippedGear` holds gear IDs — and nothing exposed
the name↔ID mapping to a plugin. The `listtheateritems` console command prints names and **no IDs at
all**. So plugins had to hard-code numbers that shift whenever the theater is edited.

## Where the IDs come from

`CTheaterDirector` holds five `CUtlMap<int, definition_t*>` tables. It's a file-static global whose
address isn't an immediate in any instruction on this PIC build — but `SendProxy_TheaterDirector`
exists to network it and its entire body is `return TheaterDirector`, so calling that is the cheapest
way to read it. Both it and the global are named symbols in the binary, so this needs **no byte
signature** — just a mangled-name lookup, like the other entries in `tug2.games.txt`.

```
CTheaterDirector
  +0x10 explosives   +0x14 weapons   +0x18 upgrades   +0x20 gear   +0x24 class templates

CUtlMap<int, T*>:  [+0x08] element array   [+0x14] root index
node (24 bytes):   +0x00 Left  +0x04 Right  +0x08 Parent  +0x10 key (the ID)  +0x14 T*

name char* within the definition:
  weapons +0x30   upgrades +0x1c   explosives +0x04   gear +0x10
```

All of that was read from `server_srv.so` and then **confirmed against the running test server**: the
tables resolve, the walk yields 126 weapons / 246 upgrades / 29 explosives / 16 gear, and those
counts match what `listtheateritems` prints for the same theater.

## On the "position is the ID" hypothesis

It's correct, with a `+1`. `ListItems` walks the map in key order and the output is in definition
order, so keys ascend with definition order; and the keys turn out to be **dense and 1-based** —
weapons 1..126, upgrades 1..246, explosives 1..29, gear 1..16. Verified three ways:

| item | `listtheateritems` position | real ID |
| --- | --- | --- |
| `weapon_M107` | 57 | 58 |
| `ammo_ap_m107` | 185 | 186 |
| `secondary_sling` | 12 | 13 |

This plugin doesn't rely on that, though — it reads the actual key for each entry, so a theater that
ever produced a gap still resolves correctly. `ListItems` silently skips null definitions, which
would shift every position after one; reading keys is immune to that.

## Memory safety

This reads raw process memory, and `LoadFromAddress` will happily read any address it's given — a
wrong one takes the whole server down. That is not hypothetical: an early scanning version of this
walk crashed the test server while it was being written, by dereferencing whatever happened to be in
each `CTheaterDirector` field while hunting for the fifth table.

Two rules follow:

1. **Never dereference anything unvalidated.** Every pointer goes through `IsPointer`, every node
   index through `IsNodeIndex`, and both tree walkers bail to `-1` rather than following an
   out-of-range link.
2. **Never search.** Only the four documented offsets are read. Probing means dereferencing whatever
   is in a field, which is exactly what crashed it.

These catch "not a pointer". They can't catch "a valid pointer to the wrong thing", so the offsets
still have to be right — they're verified against this build, and the count check in `BuildTables`
is the tripwire if a game update moves them. The walk runs once per map, not per call, so the
exposure is bounded.

## Admin command

```
sm_theateritems                          category list with counts
sm_theateritems upgrade                  every upgrade with its id
sm_theateritems upgrade m107             filtered by substring
sm_theateritems weapon svd
```

## Not covered

**Player class templates.** There's a fifth table at `+0x24` and its keys read correctly, but its
definition struct doesn't hold the name as a plain `char*` anywhere in the first `0x40` bytes — it's
probably an inline array or a `CUtlString`. Worth finishing if class-template switching ever gets
built, since `listtheateritems` doesn't print them either, so there's no fallback for that category.
