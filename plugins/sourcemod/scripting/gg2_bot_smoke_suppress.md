# gg2_bot_smoke_suppress

**Status: working, verified live.** Bots blind-fire into smoke. Ships disabled
(`sm_bot_smoke_suppress_enabled 0`); everything is cvar-tunable at runtime.

Makes bots occasionally fire blind into a smoke cloud they have no legitimate reason to shoot at.

## Why the obvious approaches don't work

**Tuning cvars alone.** Insurgency already blind-fires. `ins_bot_suppressing_fire_duration` is
described by the engine as *"How long should we light up the last spotted area of a threat"*, and
`betterbots.cfg` already raises it to `5.0` (stock `2.0`) with `ins_bot_suppress_visible_requirement`
at `0.25` (stock `1.00`). Get glimpsed for a quarter second, pop smoke, and bots hose your last
known spot for five seconds.

What no cvar covers is smoke thrown *before* anyone is seen. No "last spotted area" exists, so
there is nothing to suppress and a squad crosses untouched. There is no cvar governing smoke as a
bot vision blocker — `ins_visibility_blockers` is a map entity and `ins_bot_debug_visibility_blockers`
is debug-only.

**Forcing the trigger.** Injecting `IN_ATTACK` via `OnPlayerRunCmd` does not work. Insurgency bots
are NextBot-driven (`CINSNextBot`, `NextBotPlayer<CINSPlayer>`); aim and firing are re-derived every
tick from the AI's own state, and injected usercmd buttons are ignored or fought.

## What it actually does

Seed the bot's *vision* and let the stock suppression code do the shooting:

```
NextBotPlayer<CINSPlayer>::MyNextBotPointer()  ->  INextBot*
CINSNextBot::GetVisionInterface()              ->  IVision*
IVision::AddKnownEntity(player)                ->  bot "knows" a threat it never saw
```

Smoke still blocks line of sight, so that known entity is **known but not visible** — precisely the
state the engine's existing suppression path handles, including `CINSNextBot::GetSuppressingOffset()`,
the engine's own aim scatter. The bot sprays roughly where the player is instead of tracking them.

## Why the gamedata is symbol-based

`server_srv.so` exports **7** symbols in `.dynsym` but carries ~46,500 in `.symtab` (it is not
stripped). SourceMod's symbol resolver reads `.symtab`, which is why the existing
`insurgency.games.txt` works — `_ZN10CINSPlayer12ForceRespawnEv`, which `bm2_respawn` calls in
production, is itself `.symtab`-only. So `@`-prefixed mangled names resolve fine and no byte
signatures or vtable offsets are needed. Linux only; there is no Windows build.

## Risk

This calls into NextBot internals. A wrong assumption is a **segfault, not a failed call** - proven
the hard way, see below. Note also that `server-runner` maps srcds's exit 139 to 0, so a crash looks
like a clean restart; check `coredumpctl`/`dmesg` on the host, or the container's `RestartCount`,
rather than trusting the log. stdout is block-buffered, so the last writes before a crash are lost -
`-condebug`'s `insurgency/console.log` survives and is the place to look.

Guards in place: every returned pointer is null-checked; missing signatures make the plugin inert
rather than half-wired; and it is gated behind a cvar defaulting to `0`.

### Verified on the live test server (2026-09-06)

1. **All gamedata entries resolve.** No "Signature not found". `.symtab` lookup works as expected.
2. **The full call chain executes without crashing**, via the `sm_bot_smoke_suppress_selftest`
   debug command against two bots.

### The bug that testing caught

The first attempt segfaulted the server. `GetVisionInterface` and `AddKnownEntity` are both
**virtual**, and were being called as direct symbol lookups. `MyNextBotPointer()` returns a pointer
to the INextBot *subobject*, which is not the CINSNextBot address (the `_ZThn4_` thunks in the
binary give the multiple inheritance away), so the concrete override got the wrong `this`:

```
step 2 ok, IVision=0x870000     <- inside the .so image, not a heap object
step 3 ...                      <- segfault
```

Switching both to virtual dispatch (`SDKConf_Virtual`, slots 55 and 58, read out of the vtables with
nm + objdump) fixed it:

```
step 1 ok, INextBot=0xe875850
step 2 ok, IVision=0xe83e7e0    <- heap, adjacent to the bot
step 4 ok - full chain survived
```

Lesson for anything similar: check whether a function appears in a vtable before calling it by
symbol. `CINSNextBot::IsLineOfFireClear` was dropped for the same reason - it has the same
wrong-`this` problem and was only an optimisation. Without it a bot may occasionally suppress a
cloud it has no shot at; worth restoring later via its own vtable slot.

### Still unverified - these need a human on the server

1. That an injected known entity survives the next `CINSBotVision::Update()` rather than being
   discarded as obsolete. If it does not, the plugin simply does nothing.
2. **That the bot treats it as *not visible* (-> suppression) rather than *visible* (-> accurate
   fire).** If this is wrong the plugin makes smoke **worse than useless**, because bots would shoot
   straight through it. This is the one that decides whether the feature is viable at all, and it
   cannot be judged from logs - it needs eyes on incoming fire.
3. That `grenade_m18` / `grenade_smoke` cover player-thrown smoke. `grenade_m18` is confirmed valid
   (FireSupport creates it), but a player-thrown m18 was never observed being tracked.

## Testing

The load-time and crash-safety checks are done. What remains needs a player.

1. Join the test server and throw a smoke. With `sm_bot_smoke_suppress_debug 1`, look for
   `Tracking smoke '<classname>'` in the console. No line means assumption 3 is wrong - put the real
   classname into `sm_bot_smoke_suppress_classnames`, no recompile needed.
2. Stand in the smoke with bots at range and `sm_bot_smoke_suppress_chance 1.0`. Expect
   `given knowledge of ... at smoke` lines and inaccurate incoming fire.
3. **Watch for assumption 2.** If bots kill you through smoke with normal accuracy rather than
   spraying, disable immediately - the approach is a dead end and the fallback is cvar tuning
   (`ins_bot_suppressing_fire_duration`, `ins_bot_suppress_visible_requirement`).
4. Only then drop chance to something playable (0.15-0.3) for a real round.

Rollback is `sm_cvar sm_bot_smoke_suppress_enabled 0` - no redeploy.

`sm_bot_smoke_suppress_selftest <botIndex> <targetIndex>` is a debug-only server command (RCON or
console, never clients) that runs the SDKCall chain directly with per-step logging, bypassing the
smoke and geometry checks. It is how the crash above was located to a single call.


## How it works end to end

1. Track smoke entities via `OnEntityCreated` (substring match, so the whole `grenade_m18*` family
   including `grenade_m18_impact` is covered).
2. Each sweep, find players inside a cloud and bots within range.
3. `IVision::AddKnownEntity(player)` injects a threat the bot never saw.
4. `CKnownEntity::UpdateVisibilityStatus(true)` then `(false)` stamps a visual memory: the engine's
   own "glimpsed a moment ago, now lost" state.
5. **Do not re-seed that bot for `reseed_cooldown` seconds** so the threat ages past the engine's
   known-for-N-seconds threshold. See gate 3.
6. Detours force the remaining decisions, and `CINSBotCombat::Update` builds a real
   `CINSBotSuppressTarget` action. The engine does the shooting, including its own aim scatter via
   `GetSuppressingOffset`.

## The five gates

`CINSBotSuppressTarget` is constructed in exactly two places (`CINSBotCombat::Update` and
`CINSBotDestroyCache::Update`), and `Combat::Update` filters hard before it gets there:

| # | gate | how it was beaten |
|---|---|---|
| 1 | AI prefers **pursue** over attack | detour `ShouldPursue` (both impls) -> `ANSWER_NO` |
| 2 | `IsVisibleInFOVNow()` true -> skip | already false for a smoked target; override removed as needless risk |
| 3 | `GetTimeSinceBecameKnown()` below threshold | **not re-seeding**, so the value becomes genuinely true |
| 4 | weapon class must be 9/10/12 | one-shot promotion at the gate call only (see below) |
| 5 | `CINSBotVision::IsBlinded()` for bots inside the cloud | detour -> false, gated by `include_in_smoke` |

`ShouldAttack`/`ShouldPursue` are **advisory inputs to action selection, not commands**: 804 forced
`ANSWER_YES` answers produced zero shots on their own. `ShouldSuppressThreat` is the real gate.

## The one-shot gate window (gate 4)

Promoting `GetWeaponClass` globally does not work - `ChooseBestWeapon` and the retreat/ammo branches
read the same value earlier in `Combat::Update`, so lying to them derails the bot before it reaches
the gate. Measured, same conditions, only the class list changing:

| approach | promoted | suppressForced | shots |
|---|---|---|---|
| native `9,10,12` | 0 | 9-10 | 145 |
| blanket promotion | 1276 | 1 | 26 |
| blanket, scoped to smoke | 466 | 0 | 0 |
| **one-shot gate window** | 148 | 4 | **104** |

The fix is an ordering property: `UpdateInternalInfo` runs **after** `ChooseBestWeapon` and **before**
the gate. Detouring it arms a flag that the next `GetWeaponClass` consumes, so only the gate is lied
to. `promoted == gateHits` exactly (148/148), confirming nothing leaked to other callers.

This is why **no binary patch is needed**. The gate could be widened by patching two bytes
(`0x706dd3` `0x0c`->`0x0f`, `0x706de2` `0x16`->`0xff`) but that needs `.text` write access, is
version-locked, and changes suppression globally. The hook approach has none of those problems.

## Weapon classes (measured live, not from any symbol)

| class | weapons | native? |
|---|---|---|
| 1 | `kabar` | melee - can never pass (see below) |
| 8 | `makarov`, `deagle` | no |
| **9** | `mac10`, `ppsh41` | **yes** (SMG) |
| **10** | `m4a1`, `ak74`, `akm`, `m1918bar` | **yes** (rifle) |
| 11 | `asval`, `sks`, `svd` | no (DMR) |
| **12** | *(unobserved - see below)* | **yes** (presumed LMG) |
| 14 | `mosin` | no |

Classes 0-7 set bits in `%dl`, but the gate tests `%dh`, so they can never pass regardless of the
mask - melee is permanently excluded, which happens to match "all but melee".

**Class 12 was never observed** because every machine gun still fails to equip: 113 `Invalid player`
errors for `m60`/`m240`/`m249`/`pecheneg`/`rpk`. That is the `allowed_items` bug fixed in
`theater_tug_nvg_default.theater` but **not yet deployed**. Shipping it adds the weapons most suited
to suppression.

## Rules learned the hard way (four segfaults)

1. **Never detour a float-returning function on a 32-bit hot path.** `GetTimeSinceBecameKnown`
   returns a float on the x87 stack; wrapping it crashed on every smoke throw *even when the
   callback only returned `MRES_Ignored`*. Every stable detour here returns `int`, `bool` or `void`.
2. **Never dereference inside a hot detour.** Calling `GetEntity()` on whatever `CKnownEntity` came
   in segfaulted - those run on temporaries copied by value out of `CollectKnownEntities`. Cache
   addresses per sweep and compare integers.
3. **Virtuals need virtual dispatch.** `MyNextBotPointer()` returns the INextBot *subobject*; calling
   a concrete override with it returned `0x870000` (inside the .so image) and crashed. Check whether
   a function is in a vtable before calling it by symbol.
4. **Synthesised state must be internally coherent** - "known for 999s but never seen" is a state the
   engine never produces, and its own code then dereferences data that was never populated.

## Vtable slots (read with nm + objdump)

```
INextBot::GetVisionInterface        55     IVision::AddKnownEntity            58
IVision::GetPrimaryKnownThreat      52     CINSWeapon::GetWeaponClass        380
CKnownEntity: GetEntity 4, MarkLastKnownPositionAsSeen 9, GetTimeSinceBecameKnown 12,
              UpdateVisibilityStatus 13, IsVisibleInFOVNow 14, IsVisibleRecently 15,
              GetTimeSinceLastSeen 18, WasEverVisible 19
```

## Not possible without action injection

Bots **cannot throw grenades while suppressing**. `CINSBotThrowGrenade` is only constructed from
`CINSBotAttack::InitialContainedAction` and `CINSBotAttackFromCover::Update` - a different branch of
the behaviour tree. NextBot runs one leaf action at a time, so a suppressing bot never reaches it.
Adding that would need real action-stack injection: there is no API to push an action, and
`Behavior<CINSNextBot>` exposes only query methods.

## Cvars

| cvar | default | purpose |
|---|---|---|
| `..._enabled` | 0 | master switch |
| `..._chance` | 0.25 | how many eligible bots per pass |
| `..._interval` | 2.0 | sweep period (live-tunable; restarts the timer) |
| `..._range` | 1500 | max bot distance to the cloud |
| `..._radius` | 400 | how close a player must be to count as hidden |
| `..._reseed_cooldown` | 8.0 | **load-bearing** - lets the threat age past gate 3 |
| `..._weapon_classes` | 9,10,12 | which classes suppress; non-native ones get promoted |
| `..._include_in_smoke` | 0 | let bots inside the cloud suppress too |
| `..._classnames` | grenade_m18,grenade_smoke | smoke entity substrings |
| `..._debug` | 0 | per-sweep counters |

Debug commands: `..._selftest <bot> <target>`, `..._peek <bot>`, `..._dumpclasses`.

## Testing notes

`sm plugins reload` **resets cvars to defaults** - re-apply them after every load, or you will
measure a disabled plugin. A crash also wipes the runtime environment (`sv_cheats`,
`sv_infinite_ammo`, `mp_roundtime`, `mp_maxrounds`, `ins_bot_suppress_visible_requirement`).

`server-runner` maps srcds's exit 139 to 0, so a crash looks like a clean restart - check
`RestartCount` or `/opt/insurgency-server/dumps/`. stdout is block-buffered so the last lines before
a crash are lost; `-condebug`'s `insurgency/console.log` survives and is the place to look.
