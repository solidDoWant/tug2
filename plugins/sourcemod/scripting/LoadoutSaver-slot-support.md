# LoadoutSaver: Custom Theater Slot Support

**Status:** implemented, as a separate plugin. Written 2026-09-05 from a read of
`LoadoutSaver.sp` @ v1.1.0 (named loadouts) and the extracted TUG theater; carried out
2026-09-11 as `LoadoutSaverSlots.sp` — see
[LoadoutSaverSlots.md](LoadoutSaverSlots.md). `LoadoutSaver.sp` is untouched and still
runs on main.

The open questions below were settled as follows.

- **Which slots the theater actually uses** (stage 1): moot. The save path no longer
  guesses — it walks `m_hMyWeapons` and asks each weapon for its slot, so it does not
  matter which ones a theater invents.
- **`MAX_GEAR_SLOTS` = 6 and `MAX_WEAPON_UPGRADES` = 8**: both confirmed short. The
  server networks **7** gear slots and **10** upgrade slots (`sm_dump_netprops`). Both
  counts now come from `GetEntPropArraySize`.
- **What the `inventory_buy_upgrade` index means** (stage 3, "the single most important
  unknown"): it is a **0-based position in `CPlayerInventory`'s weapon purchase list** —
  `PurchaseWeaponUpgrade` bounds-checks `0 <= index < purchaseCount`. Not a slot, and not
  the order the plugin bought things in, because the list already holds whatever the class
  template granted. The implementation reads the index back out of
  `m_PlayerInventory.inventory_local.m_WeaponPurchases` after each buy instead of counting.
- **The real blocker was never the upgrade index.** A bare
  `inventory_buy_weapon <def>` can only ever hold one item per slot: the handler reads
  `args[4]` as the **sub-slot** and defaults it to 0, and `PurchaseWeapon` refunds whatever
  occupies the target sub-slot before inserting. Every buy therefore replaces the last.
  Passing `-1` makes it take the next free sub-slot. The full form is
  `inventory_buy_weapon <def> <firemode> <unused> <subslot>`. This is what made a second
  primary, secondary or grenade impossible, and no amount of work on the save path would
  have fixed it.
- Stage 4 (`SDKCall` into the native buy path) was not needed - the console command can
  express everything once its arguments are known.
- **"The Linux server binary exports its symbols"**: not quite. `nm -D` gives only 7
  dynamic symbols — the useful names are in the full symbol table, so `nm` without `-D`
  is what works.

`!savelo` / `!loadlo` only round-trip the stock Insurgency slots. Items in slots a
custom theater adds — or a second item in a bucket the plugin already reads — are
silently dropped on save and therefore never restored. This document records where
that limitation actually comes from, which parts are the plugin's own doing versus
the engine's, and a staged plan for fixing it.

## Where the slot assumption lives

Four places. Only one of them is genuinely an engine constraint.

### 1. Reading weapons — `LoadoutSaver.sp:566-568`

```sourcepawn
ExtractWeaponData(GetPlayerWeaponSlot(client, 0), primaryBuffer, ...);
ExtractWeaponData(GetPlayerWeaponSlot(client, 1), secondaryBuffer, ...);
ExtractWeaponData(GetPlayerWeaponSlot(client, 3), explosiveBuffer, ...);
```

`GetPlayerWeaponSlot` is an SDKTools native over `CBaseCombatCharacter::Weapon_GetSlot`.
It returns the **first** weapon found in that bucket and stops — there is no way to ask
it for the second. So:

- any slot other than 0, 1, 3 is never read at all;
- a second item sharing a bucket with one of those is never read either.

`Timer_VerifyCrossClassLoad` (`LoadoutSaver.sp:907`) hardcodes the same
`int slots[3] = { 0, 1, 3 }`, so the post-load verification inherits the blind spot.

Candidates from the TUG theater (`base.theater`) that plausibly trip this:

| Class template | Carries |
| --- | --- |
| `template_recon_security_coop` | `weapon_m67` **and** `weapon_m18_us` |
| every `*_security_coop` template | `weapon_healthkit` |
| `template_combat_medic` | `weapon_healthkit`, `weapon_m18_impact` |

Which of these actually collide is **unconfirmed** — it depends on the `slot` each
weapon script declares, and the weapon scripts live in the workshop VPK
(`3551935737`), not in this repo. Stage 1 below settles it empirically.

### 2. Reading gear — `LoadoutSaver.sp:552`

`MAX_GEAR_SLOTS` is hardcoded to 6 and used as the loop bound over `m_EquippedGear`.
If a theater exposes more gear slots, the extras are dropped.

### 3. Writing upgrades — `LoadoutSaver.sp:954`

```sourcepawn
FakeClientCommand(client, "inventory_buy_upgrade %d %s", weaponsAdded + upgradeSlot, itemArray[i]);
```

The index is synthesised from a running counter of weapons the plugin believes it just
bought (`ApplyLoadoutFromArrays` threads `weaponCount` through three `BuyWeapons` calls),
giving primary→1, secondary→2, explosive→3. It is positional and assumes exactly three
weapons in a fixed order. Any extra item shifts every index after it, so upgrades land
on the wrong gun.

**Unverified:** whether that index is purchase order, position in the player's inventory
array, or something else. This is the single most important unknown — it decides whether
stage 3 is cheap or needs stage 4.

### 4. The schema

`loadouts` has exactly four item columns: `gear`, `primary_weapon`, `secondary_weapon`,
`explosive`. Even with a perfect read there is nowhere to put a fifth item. Inherited
from the old MySQL plugin — see the four `type` values in `tools/migrate_loadouts.py`.

## What does *not* need reverse engineering

More than expected. All of the following work with what is already in the tree:

- **Enumerating every held item regardless of slot.** Iterate `m_hMyWeapons` with
  `GetEntPropArraySize` + `GetEntPropEnt` instead of asking for buckets 0/1/3. That
  yields every weapon entity the player holds.
- **Getting each item's real slot.** `CBaseCombatWeapon::GetSlot` is a plain virtual and
  its offset is **already in `plugins/sourcemod/gamedata/insurgency.games.txt`**
  (`"GetSlot"`, linux `333` / windows `332`). One `SDKCall` per weapon gives the
  authoritative slot number whatever the theater invented.
- **Real gear slot count.** `GetEntPropArraySize(client, Prop_Send, "m_EquippedGear")`
  replaces the hardcoded 6.

So the **save** path can be made fully slot-agnostic with existing gamedata and no new
hooks.

## What might

The **load** path. `inventory_buy_weapon <defindex>` is likely already slot-agnostic —
the game picks the slot from the weapon definition, which is why cross-class loads get
correctly refused today (see the abuse analysis in `LoadoutSaver.md`). The open question
is the `inventory_buy_upgrade` index described above.

If the console-command path can't be made to work, note that **the Linux server binary
exports its symbols**. The existing gamedata proves it: entries like
`@_ZN10CINSPlayer8ResupplyEv` are mangled-name lookups, not byte signatures. So this is
a symbol-table read, not an IDA session:

```sh
nm -D --defined-only insurgency/bin/server_srv.so | c++filt \
  | grep -iE "CINSPlayer::(Buy|Sell|Equip|Inventory|Give)"
```

From there: `SDKCall` the real buy function with an explicit slot, or `DHooks` a detour
on the buy handler to observe what the console command does with its index — which also
answers the stage-3 unknown empirically.

## Staged plan

1. **Slot-agnostic read.** Walk `m_hMyWeapons`, `SDKCall` `GetSlot` on each, log
   `slot:defindex:upgrades` for everything held. No RE, no risk, no behaviour change if
   it only logs at first. This immediately reveals which slots the theater actually uses
   and what is currently being dropped — i.e. it answers the open questions above.
   Also switch gear to `GetEntPropArraySize`.
2. **Schema.** Replace the four item columns with a single list encoding slot per item.
   Old rows migrate cleanly (slot 0 → primary, 1 → secondary, 3 → explosive, plus gear).
   Same idempotent-migration pattern as the `name` column already in
   `configs/sql-init-scripts/pgsql/loadout_saver.sql`.
3. **Slot-agnostic write.** Still through `inventory_buy_*`, but derive the upgrade index
   from the weapon that actually appeared after each buy rather than from a counter.
4. **Only if 3 proves impossible:** `SDKCall` into the native buy path.

Stages 1–2 are self-contained and useful on their own.

## Testing

Stages 3 and 4 cannot be validated without a live server with the theater loaded —
`spcomp` and a throwaway Postgres do not reach the buy path. Stage 1's logging is the
cheap way to gather ground truth before committing to a design.

## Doc correction owed

`LoadoutSaver.md` currently claims the entity-inspection approach is **"Theater
Independent: Works with any theater configuration"** and lists weapons as read from
"slots 0-3". Both are wrong in the way described above, and both are still wrong: that
document describes `LoadoutSaver.sp`, which has not changed. Its "Known Limitations"
section now records the limitation, but the two claims above contradict it and should be
corrected or removed.
