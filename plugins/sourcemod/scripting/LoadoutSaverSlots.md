# LoadoutSaver (all slots)

`LoadoutSaverSlots.sp` — a sibling of `LoadoutSaver.sp` that saves **every** item a player is
carrying, not just the three the stock buy menu happens to expose.

The two plugins register the same commands and **must never be loaded together**. The test server
runs this one; main runs the original. That is the same arrangement `gg2_forceretry_optout` has with
`gg2_forceretry`, and it is enforced in the `Dockerfile`: each image copies one build stage or the
other.

Player-facing behaviour is unchanged — `!savelo`, `!loadlo`, `!clearlo`, `!listlo`, `!dello`, named
loadouts, the cap, the cooldowns and the supply check all work exactly as documented in
[LoadoutSaver.md](LoadoutSaver.md).

## What was actually wrong

Three separate things, all of which silently dropped items on **save**, so they could never be
restored no matter what the load path did.

### 1. Only three weapons were ever read

```sourcepawn
ExtractWeaponData(GetPlayerWeaponSlot(client, 0), primaryBuffer, ...);
ExtractWeaponData(GetPlayerWeaponSlot(client, 1), secondaryBuffer, ...);
ExtractWeaponData(GetPlayerWeaponSlot(client, 3), explosiveBuffer, ...);
```

`GetPlayerWeaponSlot` wraps `CBaseCombatCharacter::Weapon_GetSlot`, which returns the **first**
weapon in a bucket and stops. There is no way to ask it for the second. So any slot other than 0, 1
and 3 was never read, and neither was a second item sharing a bucket with those three.

This version walks `m_hMyWeapons` instead and asks each weapon for its own slot through
`CBaseCombatWeapon::GetSlot` — a plain virtual whose offset is already in
`gamedata/insurgency.games.txt`, so no new signature and no reverse engineering.

### 2. Two array bounds were short of what the game networks

Confirmed by dumping the server's send table (`sm_dump_netprops`), not by inference:

| Array | Entries networked | Entries the original read | Result |
| --- | --- | --- | --- |
| `m_EquippedGear` | **7** | 6 (`MAX_GEAR_SLOTS`) | the last gear slot is dropped |
| `m_upgradeSlots` | **10** | 8 (`MAX_WEAPON_UPGRADES`) | the last two upgrades on every weapon are dropped |

The gear one is not hypothetical here: the night-vision `misc1` slot this repo adds to the theater
is exactly the kind of item that lands past the old bound.

Both counts now come from `GetEntPropArraySize` at runtime, so a future theater change cannot
reintroduce the problem. The `#define`s that remain are upper bounds for buffer sizing only.

### 3. The schema had nowhere to put a fourth item

`loadouts` has one column per category — `gear`, `primary_weapon`, `secondary_weapon`, `explosive`.
Even a perfect read had nowhere to store anything else.

## Storage

Items are stored **by name**, and the schema is normalised.

```
theater_items    id, category, name                      every item name ever seen
loadouts_slots   id, steam_id, class_template, name       the set
loadout_items    loadout_id, ordinal, item_id,            one row per item
                 slot, parent_ordinal
```

### Why names rather than ids

Theater ids are assigned at parse time and shift whenever the theater is edited — add one weapon and
every id after it moves. A stored id therefore does not survive a theater change: it keeps
resolving, just to a *different item*, so a loadout silently becomes wrong with nothing to detect.
Names are stable, and [`gg2_theater_items`](gg2_theater_items.md) turns them back into ids for
whatever theater is loaded.

That also improves the failure mode. An item the theater no longer defines resolves to nothing, so
it is skipped with a log line and the player is told how many items did not arrive — and if the item
ever comes back, the loadout works again.

### Why normalised

**Not to save space.** Twenty items at ~25 bytes a name is ~500 bytes inline, and a row per item
costs about that much again in Postgres row headers, while multiplying row count by ~20. The reasons
are integrity and queryability: foreign keys instead of a text blob nothing can validate, deletes
that cascade instead of leaving orphans, and "which loadouts use this weapon" as a real query rather
than a `LIKE` over a separator-delimited string.

`theater_items.id` is a surrogate and is **deliberately not** the theater's id for the same item.
The theater's id is the unstable thing this schema exists to avoid storing.

### The two columns that carry the old format's meaning

`slot:def,upg,upg;...` encoded two things by position that now need to be explicit:

- **`ordinal`** is buy order, and it is load-bearing. The apply path buys weapons in this order and
  reads each weapon's purchase index back afterwards, so two grenades sharing a slot must go back in
  the order they were saved. Every read is `ORDER BY ordinal`.
- **`parent_ordinal`** is the nesting. An upgrade row points at the ordinal of the weapon it is
  installed on; `NULL` for weapons and gear.

Sub-slot is deliberately not stored — the buy passes `-1` for it, meaning "next free", so position
within a slot follows from `ordinal` alone.

### Saving is a transaction

Four statements, in order: add any unseen names, upsert the set, drop its existing items, insert the
new ones joining names back to ids. The set is addressed by its natural key in the last statement
rather than by an id carried between them, which keeps each statement independent and avoids needing
`RETURNING` across a transaction.

The named-loadout cap stays inside the set upsert, so two saves racing each other cannot both see
room, with the database trigger as the hard backstop.

## Melee is excluded, and the game is why

`sm_loadout_skip_slots` defaults to `"2"`. `CPlayerInventory::RefundAll` — all that
`inventory_sell_all` does — walks the purchase list and skips any entry whose slot is 2:

```
cmp DWORD PTR [eax+edi*1+0x30],0x2    ; purchase[i].m_iSlot == 2 ?
je  skip                              ; the knife is never sold
```

So melee survives `inventory_sell_all` and is still in the inventory when a loadout is applied.
Re-buying it would either burn supply on a second knife in the next free sub-slot, or be refused
outright. Neither is what the player asked for, so it is left out of saved loadouts entirely and the
class template keeps providing it.

This is also the missing piece of why the original plugin's positional upgrade index worked at all:
the surviving melee entry occupies purchase index 0, so the first weapon it bought landed at index
1 — exactly the number it was passing.

Other slots are deliberately not excluded. A medic's healthkit is refunded by `inventory_sell_all`
like anything else, so re-buying it is symmetric and costs what it originally cost.

## Failure modes

| Situation | Behaviour |
| --- | --- |
| `GetSlot` offset missing from gamedata | Saving refused with a chat message; loading still works. A save with no slot information would record every weapon as slot 0, which is worse than no loadout at all |
| A stored item does not parse | That item is skipped and logged; the rest of the loadout still applies |
| Database unavailable | Same as the original — failure message, reconnect on a timer |

## Testing

- `spcomp` and a throwaway Postgres cover the schema, the import and every query the plugin issues.
  All of that has been run: old rows convert exactly, the named cap still fires at 15, and a rerun of
  the migration is a no-op.
- Everything past that needs a live server with the theater loaded. In particular: whether a weapon
  in a theater-added slot round-trips, and whether upgrades on a fourth or later item land on the
  right gun.
- Quick check once deployed: save a loadout on a class that carries more than three items, then
  `SELECT weapons FROM loadouts_slots WHERE steam_id = <id>` and look for slots other than 0, 1 and
  3. The maintenance queries at the bottom of `loadout_saver_slots.sql` have this ready to paste.
