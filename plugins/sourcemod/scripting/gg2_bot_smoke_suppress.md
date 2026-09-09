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

> **Superseded in part - read "SOLVED: suppression died after the first smoke" at the bottom first.**
> There is a gate *before* all five of these: `IsMinArousal(8)` at `0x706baa`. It is the one that
> actually decides whether a bot suppresses, and gates 2 and 3 below turn out not to be exits at all
> - both branches rejoin the suppression path. The corrected order is at the end of that section.

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
| 2 | `f1` | frag |
| 3 | `molotov` | incendiary |
| 4 | `m18` | smoke |
| 7 | `at4` | launcher |
| 8 | `makarov`, `deagle`, `m9` | no |
| **9** | `mac10`, `ppsh41` | **yes** (SMG) |
| **10** | `m4a1`, `ak74`, `akm`, `m1918bar` | **yes** (rifle) |
| 11 | `asval`, `sks`, `svd` | no (DMR) |
| **12** | *(unobserved - see below)* | **yes** (presumed LMG) |
| 14 | `mosin` | no |

Classes 0-7 set bits in `%dl`, but the gate tests `%dh`, so they can never pass regardless of the
mask - melee is permanently excluded, which happens to match "all but melee".

Grenades and launchers only appear if you walk `m_hMyWeapons`; they are almost never the active
weapon when sampled. `..._dumpclasses` does this.

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

`CKnownEntity`, decoded from `_ZTV12CKnownEntity` at 0xb8d460. Eight of these had been derived
independently before the table was dumped and all eight matched, which is why the rest are trusted:

| slot | method | used for |
|---|---|---|
| 3 | `UpdatePosition(Vector)` | **writes** the suppression aim point |
| 4 | `GetEntity` | identify the seeded entry |
| 5 | `GetLastKnownPosition` | **read** for the aim point |
| 7 | `GetLastKnownPositionPredicted` | - |
| 9 | `MarkLastKnownPositionAsSeen` | coherent synthesised state |
| 12 | `GetTimeSinceBecameKnown` | age gate (never detoured - float return) |
| 13 | `UpdateVisibilityStatus(bool)` | manufacture "glimpsed then lost" |
| 14 | `IsVisibleInFOVNow` | the fork into `CINSBotAttack` |
| 15 | `IsVisibleRecently` | - |
| 18 | `GetTimeSinceLastSeen` | - |
| 19 | `WasEverVisible` | - |

Others: `INextBot::GetVisionInterface` 55, `IVision::AddKnownEntity` 58,
`IVision::GetPrimaryKnownThreat` 52, `CINSWeapon::GetWeaponClass` 380.

## Grenades: solved via the same one-shot trick, one branch earlier

**Two earlier claims in this file were wrong and are corrected here.** Grenades do not need action
injection (corrected once already), *and* they do not need a visibility flash either.

`CINSBotAttack` is constructed in exactly two places in the whole binary, and both are inside
`CINSBotCombat::Update`. The first is guarded by a single call:

```asm
706d6e:  call *0x38(%eax)   ; CKnownEntity::IsVisibleInFOVNow, vtable slot 14
706d73:  jne  706f6e        ; -> new CINSBotAttack, ChangeTo
706d79:  ...                ; else fall through to the suppression path
```

That branch is **three instructions before the weapon-class gate** the plugin already exploits, on
the same code path, for the same bot, in the same tick. So "make the bot enter the attack branch"
is the same one-shot window problem, one branch earlier - answer `true` to exactly that one call.

Getting the *arming point* right took three attempts, and the first two silently did nothing:

1. **Arm at seed time, key on the `CKnownEntity` address.** Not selective enough on its own -
   `IsVisibleInFOVNow` runs ~1700 times/second, so whichever caller asked first burned the one-shot.
2. **Also require the weapon-class gate window open.** Still wrong, and this one looked plausible
   enough to survive two rounds of tuning. `UpdateInternalInfo` has **8 call sites, 5 of them
   outside `Update`** (OnStart/OnResume/OnEnd), and the same flag is consumed by the weapon-class
   gate - so the one-shot was routinely spent on an unrelated query while the window happened to be
   open. Measured **20 forced -> 0 constructions**.
3. **Arm in `ShouldPursue`.** Dispatched at 0x706baa, inside `Update`, strictly before the fork, and
   it hands us the `CKnownEntity` directly. Denying pursuit there is what steers execution down
   706c55 -> 706d63 -> the fork in the first place. Measured **12 forced -> 9 constructions**.

**The counter that made this tractable was a detour on `CINSBotAttack`'s constructor.** There are no
conditional branches between the fork at 0x706f6e and the constructor at 0x706fd1, so reaching the
fork *must* construct the action - which makes `atkCtor` a direct, unambiguous test of whether the
branch was taken. Without it, "no grenades appeared" is indistinguishable from a dozen causes. It is
a void-returning ctor, so it is safe to detour.

Measured end to end, with `hide_client` active and `flashed=0`:

| | forced | ctor | InitialContainedAction | dispatched |
|---|---|---|---|---|
| armed at UpdateInternalInfo | 20 | **0** | 0 | 0 |
| armed at ShouldPursue | 12 | 9 | 9 | 9 |

Once the fork lands the chain is 1:1:1 with no losses.

**A result that had to be withdrawn.** An earlier run measured 116 forks -> 25 -> 15 grenades and
was reported as the mechanism working. It was not: `notarget` was silently doing nothing, so bots
could genuinely see the player and were entering `CINSBotAttack` on their own. Once `hide_client`
made hiding real, the same build produced `atkCtor=0`. **Any grenade measurement taken while the
tester is visible proves nothing** - the whole feature exists for the case where they are not.

`grenade_flash` is now obsolete - it existed only because nothing could reach `CINSBotAttack`
without it, and it cost the one thing the design protects (visible means accurately shootable).
Leave it at 0.

**Only arm bots that carry a throwable.** Measured live: **11 of 25 living bots carry no throwable
at all**, purely by loadout (`sm_bot_smoke_suppress_nadecheck` dumps this). Steering an empty-handed
bot onto the ThrowGrenade branch wastes the fork and strands it - it can neither throw nor suppress.

Note `sv_infinite_ammo` does not refill throwables; it only affects firearm ammo reserves.

## The aim point: why bots fired ~45 degrees high

Reported in game as bots shooting well above horizontal, which suppresses nothing.

> **There are TWO separate causes of upward aim, and this section only covers the first.** The stale
> `GetLastKnownPosition` described here is real and fixed. But bots pinned at maximum arousal *also*
> aim wildly upward, via `ins_bot_arousal_frac_aimpenalty_max` and friends - and that one is a
> symptom of the suppression dropout, not a separate bug. If the upward aim comes back, check
> `arousalHigh` in the debug line before re-opening anything here.

`CINSBotCombat::Update` builds the suppression action like this:

```asm
707567:  ecx = [ebp-0x3c4]        ; the CKnownEntity we seed
707572:  call *0x14(%eax)         ; slot 5 = GetLastKnownPosition
7075a4:  rep movsl                ; copy that Vector by value
7075af:  call CINSBotSuppressTarget(Vector, CBaseEntity*)
```

So the aim point is `GetLastKnownPosition()` (slot 5), and that field is written **only** by
`UpdatePosition()` (slot 3), which the engine calls from its own vision update for entities it
genuinely sees. Our target is hidden by design, so that call never happened - the plugin created the
entry, marked its position *seen*, and never set the position. Bots were dutifully suppressing a
stale or unset point. `UpdateVisibilityStatus` does not set it; it only touches timers.

Fix: call `UpdatePosition` with the target's origin on every seed.

Two wrong diagnoses preceded this, both worth remembering:

1. **"It's the grenade throws"** - a bot lobbing a grenade does aim up ~45 degrees, which fit the
   symptom neatly. Disproved by a run at `grenade_chance 0.0`: zero forks, zero dispatches, bots
   still aimed high.
2. **"The fix is deployed and didn't work"** - it had never run. See below.

## Bugs in this plugin's own scaffolding (not the engine)

- **A `Signatures` entry placed in the `Offsets` section.** `UpdatePosition` was added by anchoring
  a text insert on `MarkLastKnownPositionAsSeen`, which appears in *both* sections; the first match
  was the offsets one. `SDKConf_Signature` could then never resolve it, `g_hKE_UpdatePos` stayed
  null, and the call silently never happened - so a real fix looked like a failed one. It is now an
  offset (slot 3) called virtually, like every other hook here. **The `[SM] ... missing` line in
  `logs/errors_*.log` is the authoritative check that a lookup resolved** - absence of that line on
  the newest load is the proof, not the absence of a crash.
- **An off-by-one in a log parser.** `"fovForced="` is 10 characters; offsetting by 11 chopped the
  digit and reported a clean 0 for every window. Nearly published as a finding.

## Pursuit denial and the reseed cadence are different clocks

`nopursue_time` (6s) and `reseed_cooldown` (8s) were coupled by accident: denial was set only when a
seed actually happened, but seeding is held off for 8s because re-injecting knowledge resets
`GetTimeSinceBecameKnown` and defeats the age gate. That left a **2-second hole every cycle** in
which the bot was free to pursue - it walked to the smoke and stayed, which in game reads as "bots
get tired of suppressing and congregate around the smoke".

Denial now refreshes every sweep while the player is inside a live cloud, so it ends 6s after they
leave the smoke rather than 6s after an arbitrary seed.

## Hiding a player for testing: notarget and nb_blind both fail

- **`notarget` does not work** on NextBot vision.
- **`nb_blind 1` is useless as a harness.** It does not just stop bots seeing you - it disables the
  vision update wholesale. Measured: `fovSkip=0` and `combatUpd=0` with 25 bots fighting, i.e. no
  `CKnownEntity` exists to inject into and `CINSBotCombat::Update` never runs at all.

Use `sm_bot_smoke_suppress_hide_client <index>` instead. It detours `CINSBotVision::IsIgnored` and
filters exactly one entity, leaving the rest of the vision system running - so bots cannot acquire
the tester naturally, but the plugin's own `AddKnownEntity` injection (which bypasses that filter)
still lands. Confirm it is matching with `hidden=` in the debug line.

## Cvars

| cvar | default | purpose |
|---|---|---|
| `..._enabled` | 0 | master switch |
| `..._chance` | 0.25 | how many eligible bots per pass |
| `..._interval` | 2.0 | sweep period (live-tunable; restarts the timer) |
| `..._range` | 1500 | max bot distance to the cloud |
| `..._radius` | 250 | how close a player must be to count as hidden |
| `..._nopursue_time` | 6.0 | pursuit denial; refreshed every sweep while the player is in a live cloud |
| `..._reseed_cooldown` | 8.0 | **load-bearing** - lets the threat age past the 1.0s gate. Deliberately NOT tied to `nopursue_time` |
| `..._arousal_cap` | 6.5 | **load-bearing** - keeps bots under `IsMinArousal(8)`. Without it suppression dies ~32s in and never returns. See the postmortem below |
| `..._weapon_classes` | 9,10,12 | which classes suppress; non-native ones get promoted. **`8,9,10,11,12,14` (all but melee) measured 3.7x the suppressing fire of the default** |
| `..._refill_ammo` | 1 | top up RESERVE ammo near the engine's 10% suppression cutoff, so the mechanic is not self-limiting to one burst per bot life |
| `..._refresh_threat` | 1 | forget the injected threat before re-adding, so each seed reads as a NEW acquisition |
| `..._unstick_grenade` | 0 | seconds a bot may hold an unthrown grenade before being switched back to a firearm. Safety valve; bots put it away on their own |
| `..._include_in_smoke` | 0 | let bots inside the cloud suppress too |
| `..._smoke_life` | 18.0 | seconds a smoke stays tracked - **prevents the stale-smoke failure** |
| `..._grenade_chance` | 0.0 | steer seeded bots onto the grenade action |
| `..._grenade_class` | 2 | class reported at the attack dispatch (2 frag 3 molotov 4 smoke 7 AT4) |
| `..._classnames` | grenade_m18,grenade_smoke | smoke entity substrings |
| `..._debug` | 0 | per-sweep counters |

Debug commands: `..._why` (all gates per bot, arousal first, plus full inventory - **start here**),
`..._dumpclasses`, `..._nadecheck` (per-bot throwable inventory), `..._reset` (clears runtime state,
leaves detours alone - see the warning on it, it un-clamps arousal).

Measured effect of widening `weapon_classes`, same map and position:

| | `9,10,12` | `8,9,10,11,12,14` |
|---|---|---|
| shots per smoke-active window | 5.4 | **19.8** |
| bots excluded by class (peak of 25) | 18 | 5 |
| `lastBadCls` | 11 (DMR) | 1 (melee) |

Debug counters worth knowing: `arousalHigh`/`arousalMax`/`clamped` (**check these first** - if
`arousalHigh` is nonzero the bots have left the suppression path entirely and nothing downstream
matters), `suppCalls` (the discriminator - 0 means the engine never reached `ShouldSuppressThreat`),
`clsHist` (active weapon class distribution near a cloud), `fovForced` (attack-branch forks taken),
`fovSkip` (matches rejected because the gate window was shut), `noNade` (bots skipped for carrying
no throwable), `hidden` (hide_client filter hits), `denied`/`stale` (pursuit denial working vs
lapsed), `skipClass` with `lastBadCls` (bots excluded by weapon class), and `atkCtor`
(`CINSBotAttack` constructions - ground truth for whether the grenade fork branch was taken).

`..._why` is the faster first move: it dumps every gate, arousal first, for every living bot in one
shot. Several counters that existed only to settle a specific hypothesis (`p2Sampled`/`p2Below`,
`fovSeedTrue`/`fovSeedFalse`, `pNative`) have been removed now that they have answered - the
measurements they produced are recorded in the eliminated-hypotheses table below.

## Testing notes

`cfg/sourcemod/gg2_bot_smoke_suppress.cfg` is exec'd on **every** plugin load, so cvars set by hand
at the console are silently reverted on the next reload. Put test values in that file. The same is
true of `cfg/server_checkpoint.cfg` on every round start, which resets `mp_roundtime`,
`mp_maxrounds` and `mp_winlimit`.

Test environment: `sv_cheats 1`, `sv_infinite_ammo 1`, `ins_bot_suppress_visible_requirement 0`,
`mp_roundtime 3600`, `mp_maxrounds 0`, `mp_winlimit 0`, `mp_winlimit_coop 0`, `mp_timelimit 0`,
and `..._hide_client <your index>`.

`server-runner` maps srcds's exit 139 to 0, so a crash looks like a clean restart - check
`RestartCount` or `/opt/insurgency-server/dumps/`. stdout is block-buffered so the last lines before
a crash are lost; `-condebug`'s `insurgency/console.log` survives and is the place to look.

## SOLVED: suppression died after the first smoke - bot arousal

**Symptom.** The first smoke after a plugin reload suppressed heavily; every smoke after it produced
little or nothing, until the plugin was reloaded again. A round restart never helped. Reproduced
across an entire evening of testing.

**Cause.** `CINSBotCombat::Update`'s *first* branch gates the whole suppression path on the bot's
arousal, and this mechanic drives arousal to the cap and holds it there.

```
706b97:  call *0x970(%eax)     ; CINSNextBot::GetBodyInterface()
706baa:  call *0x164(%edx)     ; CINSBotBody::IsMinArousal(8)
706bb0:  test %al,%al
706bb2:  je   706c55           ; NOT aroused -> ammo gate -> ... -> ShouldSuppressThreat
706bd9:  call operator new     ; aroused     -> new CINSBotRetreatToCover
```

`IsMinArousal` is a one-liner - arousal is a plain float on the body object:

```
744969:  movss 0x138(%eax),%xmm0    ; arousal, CINSBotBody + 0x138
744994:  frndint                     ; ROUNDS - so 7.5 already counts as 8
7449a1:  cmp %eax,0xc(%ebp)
7449a5:  setle %al                   ; return arg <= round(arousal)
```

At arousal >= 8 (>= 7.5 after rounding) the bot **retreats to cover instead of suppressing**, no
matter what any downstream gate says. That is why seeding, pursuit denial, threat age, FOV and
weapon class could all read perfectly healthy while `suppCalls` sat at 0: the decision was made
before any of them ran.

### Why it was a one-way door

```
ins_bot_arousal_combat_max         = 10     ( stock 5.0 )   <-- betterbots.cfg:185
ins_bot_arousal_firing_max         = 10     ( stock 5.0 )   <-- betterbots.cfg:187
ins_bot_arousal_suppression_max    = 12     ( stock 7.0 )   <-- betterbots.cfg:190
ins_bot_arousal_combat_falloff     = -0.25    "when in combat but not being suppressed"
ins_bot_arousal_default_falloff    =  0.25    "how fast arousal falls off OOC"
```

Combat falloff is **negative** - arousal *rises* 0.25/s while a bot is in combat - and the only
decay applies **out of combat**. At the stock cap of 5.0, combat alone can never reach the gate at
8, so this bug does not exist in an unmodified server. `betterbots.cfg` raises the cap to 10, which
lets combat alone walk straight through it.

This mechanic holds bots in combat indefinitely by design (seed a known threat, deny pursuit), so
arousal climbs to the cap in ~32s and can never come back down, because the bots never go OOC.

Measured live, with the ramp matching the cvar almost exactly:

```
time      SHOTS supC   arN arHI  arMin  arMax
17:44:42      6    7    25    2    0.0   10.0
17:44:46     29    4    25    2    0.5   10.0
17:44:50     66    8    25    2    1.2   10.0
17:44:54     58    7    25    2    2.7   10.0
17:44:58     37   10    25    2    3.7   10.0
17:45:00      0    3    25    2    4.2   10.0     0.0 -> 4.2 in 18s = 0.233/s
```

`arMax = 10.0` with `arHI = 2` throughout: two bots were already pinned at the cap from earlier
tests and never came down. That is the persistent dead state.

**This also explains the two facts that killed every other hypothesis:**

| Observation | Explanation |
|---|---|
| a plugin reload ALWAYS fixes it | seeding stops, bots drop out of combat, `default_falloff` decays arousal below 8 within seconds |
| a round restart NEVER fixes it | arousal lives on the bot's body object; the bots are not recreated |
| bots "get tired" and congregate near the smoke | they are in `CINSBotRetreatToCover`, which is what the aroused branch constructs |
| bots aim ~45 degrees upward | `ins_bot_arousal_frac_aimpenalty_max` / `aimtolerance_max` / `aimtracking_max` - the max-arousal aim degradation |

That last row is worth dwelling on. The upward aim was reported as a throwaway aside - "may or may
not be related" - and it was the single most direct observation of the cause anyone made all
evening. It should have been chased the moment it was mentioned.

### The fix

`sm_bot_smoke_suppress_arousal_cap` (default 0 = off, **6.5** is the useful value). Each sweep, any
bot currently eligible to suppress near a cloud has its arousal float clamped to the cap.

Clamped plugin-side rather than by lowering `ins_bot_arousal_combat_max` back to 5, because
`betterbots.cfg` raises it deliberately and that cvar affects every bot on the server. The clamp
touches only bots this mechanic is actively driving, and restores exactly the invariant stock
Insurgency has: combat alone cannot push a bot past the gate.

**6.5, not 7.0.** The engine adds 0.25/s and `IsMinArousal` rounds, so a cap of 7.0 reaches 7.5 and
rounds up to 8 before the next sweep two seconds later.

Result - the two smokes that used to be dead:

```
smoke   shots       arousal at smoke start     after clamp
  1     17 -> 107   0.0 -> 6.5 (fresh bots)    clamped 5 -> 12
  2      3 -> 130   arHI=14  arMax=10.2        clamped=24, arHI -> 0
  3      3 -> 128   arHI=23  arMax=10.0        clamped=24, arHI -> 0
                                               total 2282 bot shots near smoke
```

Arousal still rebounds between clouds (the clamp only touches eligible bots near a smoke), but one
sweep after a new smoke lands the whole squad is pulled back under the gate. The mechanic
self-heals instead of decaying.

**Known rough edge:** one bot was seen drifting to `arMax = 9.5` while 20 others were clamped. The
clamp is gated on `g_bBotCanSuppress`, so a bot holding an ineligible weapon class is never clamped.
Harmless, but it is why `arHI` is occasionally 1 instead of 0.

### Hypotheses eliminated on the way, and what killed each

| Hypothesis | Killed by |
|---|---|
| bots run out of ammo | `ammoBelow=0`, `ammoMin=1.00` in every dead window |
| bots stop reloading | same, plus `sv_infinite_ammo 1` |
| loadouts - bots carry no firearm | true before the theater fix (7 of 25), but the dead state persisted after it |
| threat goes stale / re-seeding resets the age clock | `p2Below=0`, ages 2-25s against a 1.0s threshold |
| the age gate at 0x706dbb | as above - and the gate *rejoins* the suppression path at 0x706dc1 anyway |
| `IsVisibleInFOVNow` answers true at 0x706d6e | measured: `fovSeedTrue=0-2` vs `fovSeedFalse=60-151` |
| `IsAbleToSee` at 0x706d80 | that branch rejoins at 0x706d86 - not an exit |
| weapon-class gate at 0x706dd2 | `pNative` stayed 5-21 in the dead state and `clsHist` was identical live vs dead |
| a sticky flag on the Combat action | 0x4d is `IsAbleToSee`, recomputed every `UpdateInternalInfo` |
| plugin-side state corruption | `sm_bot_smoke_suppress_reset` clears all of it and does not help |

### Method notes

Three separate instruments returned nothing and were briefly read as results:

- `SDKConf_Virtual` used against a signature-only gamedata entry - silently null, no error.
- a reference-returning `GetLastKnownPosition` SDKCall that was never prepared.
- a `sed` backreference written `\10`, which renders as group 1 followed by a literal `0` and
  invented a `skipClass=300` that never existed.

Every new instrument now logs a `LogError` when its handle fails to prepare. **A counter that reads
zero because the instrument is broken looks exactly like a counter that reads zero because the
thing is not happening.**

Two more traps worth remembering:

- `cfg/sourcemod/gg2_bot_smoke_suppress.cfg` is exec'd on **every** plugin load, so cvars set by
  hand at the console are silently reverted on the next reload. Test values belong in that file.
- `cfg/server_checkpoint.cfg` is exec'd on every round start and resets `mp_roundtime`,
  `mp_maxrounds` and `mp_winlimit`. Same fix: put the test values in the file.

### Reading a vtable slot from the binary

Used repeatedly here, and it is what identified `IsMinArousal`:

1. `nm -C server_srv.so | grep 'vtable for CINSBotBody'` -> the vtable symbol address.
2. The object's vptr points at `symbol + 8` (skipping offset-to-top and RTTI), so a call
   `*0x164(%edx)` reads `symbol + 8 + 0x164`.
3. Read those 4 bytes out of the file (map vaddr -> file offset via `readelf -S`) and resolve the
   value with `nm`.

Always sanity-check the arithmetic against a slot whose identity you can predict independently -
`+0xd8` resolving to `PlayerBody::AimHeadTowards` is what confirmed the layout before trusting
`+0x164`.

### Useful offsets and slots found here

| Thing | Where |
|---|---|
| arousal (float) | `CINSBotBody + 0x138` |
| `CINSBotBody::IsMinArousal(ArousalType)` | body vtable `+0x164` |
| `CINSBotBody::IsMaxArousal(ArousalType)` | body vtable `+0x168` |
| `PlayerBody::AimHeadTowards` | body vtable `+0xd8` |
| `INextBot::GetBodyInterface` | INextBot vtable slot 53 |
| `INextBot::GetVisionInterface` | INextBot vtable slot 55 |
| `CINSNextBot::GetBodyInterface` | CINSNextBot vtable `+0x970` |
| `CINSNextBot::GetVisionInterface` | CINSNextBot vtable `+0x974` |
| `CINSBotCombat` cached `IsAbleToSee(threat)` | `CINSBotCombat + 0x4d` |
| `CINSBotCombat` cached `IsVisibleInFOVNow(threat)` | `CINSBotCombat + 0x4c` |

### The real gate order in CINSBotCombat::Update

Corrected - two of the branches previously listed as gates are not exits at all:

```
706baa  IsMinArousal(8)              aroused -> CINSBotRetreatToCover        <-- THE GATE
706c5d  ammo ratio >= 0.10
706d6e  IsVisibleInFOVNow            true    -> CINSBotAttack
706d80  IsAbleToSee                  true    -> AimHeadTowards, REJOINS at 706d86
706dbb  threat known >= 1.0s         fail    -> REJOINS at 706dc1
706dd2  weapon class in {9,10,12}    (and $0x16,%dh - promotion can fake this)
706df5  ShouldSuppressThreat
```

## State, and what is left

### Where things stand (2026-09-07)

The mechanic works end to end. With `arousal_cap` on, three consecutive smokes each drew heavy
suppressing fire (2282 bot shots near smoke across the three), where previously only the first did.

**Nothing is committed.** `gg2_bot_smoke_suppress.sp`, this file, and `tug2.games.txt` are all
modified in the working tree.

**The test server runs a side-loaded build.** The `.smx`, `tug2.games.txt` and
`cfg/sourcemod/gg2_bot_smoke_suppress.cfg` were `docker cp`'d into the running container; a redeploy
wipes all three. Build with `spcomp`, then `tsh scp` to the host and `docker cp` into
`docker-compose-tug2-insurgency-test-1`.

Server was left in production shape: cheats off, round limits restored, `debug 0`, `hide_client 0`,
`grenade_chance 0`, `chance 0.25`, `weapon_classes 8,9,10,11,12,14`, `arousal_cap 6.5`.

### Next, in priority order

1. **Re-verify grenades.** The FOV fork was verified *before* the arousal cause was known, and
   arousal gated that entire branch - so the grenade path has almost certainly not been dispatching
   either (`nadeArmed=0`, `atkCtor=0` in every recent log). Set `grenade_chance 1.0` and `debug 1`,
   throw one smoke, and check `fovForced` -> `atkCtor` -> `icaCalls` -> `nadeHits` still run 1:1:1:1.

2. **Production defaults.** Two are real decisions rather than reverts:
   - `weapon_classes` - the widened set measured 3.7x the suppressing fire, but it fakes the class
     of pistols/DMRs/bolt-actions at the gate. Currently defaulted narrow (`9,10,12`) in the source
     and widened in the server cfg; pick one.
   - `chance` (0.25) was tuned before any of this worked and wants re-tuning now that suppression
     persists rather than dying after one smoke.

3. **Play-test in production shape.** Everything so far was one human with `hide_client` on.
   Unverified: multiple humans, and whether bots behave normally when no smoke is out. The plugin
   denies pursuit, fakes weapon classes and writes arousal - all scoped to bots eligible near a
   cloud, but that scoping is argued, not observed.

4. **Performance.** Never measured. The `IsVisibleInFOVNow` pre-detour still fires ~4000x/second,
   though with `grenade_chance` at 0 it returns on the second line. With `debug` off the sweep now
   costs 2 SDKCalls per *clamp-eligible* bot rather than per living bot, and the per-seed age and
   ammo sampling is gone entirely. Check frame time before this goes anywhere near the main server. If the pre-detour turns out to cost real time, it only exists for the
   grenade fork and could be installed lazily on a `grenade_chance` change hook.

5. **Cleanup.** Done - see the section below. One item was deliberately left alone: the arousal
   clamp is gated on `g_bBotCanSuppress`, so a bot near a cloud holding an ineligible weapon class
   is never clamped and can drift to 10. Changing that would alter behaviour that is currently
   verified working, so it is documented at the clamp instead of fixed.

## Cleanup pass

Done after the mechanic was confirmed working, with no behaviour change intended and a clean
compile (previously one warning):

- Removed `force_notvisible` and its branch - measured unnecessary, `IsVisibleInFOVNow` already
  answers false for a smoked target.
- Removed the `IsVisibleInFOVNow` **post** hook and the `g_iSeedKnown` latch that fed it. That hook
  ran on every one of ~4000 calls a second purely to count `fovSeedTrue`/`fovSeedFalse`, and those
  counters had already answered their question.
- Removed the parameter-2 age sampling from `Detour_ShouldPursue_Combat`. It cost an SDKCall on
  every `ShouldPursue` call to produce `p2Below`, which measured 0 every time.
- Removed `pNative`, and put the surviving per-call client scan in that detour behind `debug` - it
  is a linear scan over every client that `Detour_ShouldPursue` then immediately repeats for real.
- Weapon-class histogram sampling now only runs when `debug` is on.
- Deleted write-only state (`g_fArousal[]`, `g_iIcaMatchNb`) and fixed the unused-parameter warning
  in `Detour_ShouldPursue`.
- Removed `..._selftest` and `..._peek`. `selftest` was a bring-up scaffold: it wrote engine state
  on live bots with no smoke involved, its verdicts answered a question settled long ago, and its
  step numbering had rotted (1, 2, 4, 7, 5, 6). `..._why` covers the same SDKCall chain read-only
  and is the better post-update health check. With them went `IsVisibleRecently`,
  `GetTimeSinceLastSeen`, `WasEverVisible`, `IsLineOfFireClear` and the `PrepVirtRet` helper.
- `SampleThreatAge` now runs only under `debug`. It walked five SDKCalls per seeded bot per sweep
  and wrote nothing - pure instrumentation for a gate that was cleared as a suspect.
- Split `SampleAndRefillAmmo`: the ratio sample is behind `debug`, the refill still always runs.
- `SampleArousal` now skips the body read for bots the clamp could not act on anyway (no
  `g_bBotCanSuppress`) unless `debug` is on. Clamping behaviour is unchanged.
- Dropped `fovAll`, which counted every call on the ~4000/sec path before any early-out.
- Removed `..._grenade_flash` (documented obsolete, superseded by the FOV fork) and `..._stage`,
  a bisection dial whose only ever-used setting was the default - stage 0 disabled seeding and
  re-arming, stage 2 called `MarkLastKnownPositionAsSeen`, which was never on. Behaviour at the
  defaults is unchanged. `MarkLastKnownPositionAsSeen` went with it.
- Relabelled the `CINSBotCombat::UpdateInternalInfo` detour. It was registered and logged as a
  "combat-update counter", but it arms the weapon-class gate window - if it fails to install,
  promotion silently stops and only natively eligible weapons can suppress. The failure message now
  says that.
- Put the two grenade-verification-only pieces behind `#define GRENADE_VERIFY 0` - see the scope
  section. Also fixed two block comments that had drifted onto the wrong detour: "Pure observer: how
  often does the Combat action actually run?" sat above the `IsIgnored` install rather than
  `UpdateInternalInfo`, and the `IsVisibleInFOVNow` comment was truncated mid-sentence and still
  described the post hook that was removed in the first pass.
- Added arousal to `..._why` as gate 0. It was the gate that actually killed the mechanic and the
  one-shot diagnostic dump did not show it, so the dump could report every gate green on a bot that
  had not fired in minutes.

## Scope: what is in here that is not the mechanic

### Compiled out: `#define GRENADE_VERIFY`

Two pieces exist only to observe a test, never to make the mechanic work, and both are now behind a
compile-time switch at the top of the `.sp`, set to `0`. Both configurations compile clean; flip it
to `1` and recompile to get them back.

| Behind the switch | Why it is not shipped |
|---|---|
| `..._hide_client` + the `CINSBotVision::IsIgnored` detour | A test harness that hides one client index from bot vision, so seeding is the only channel by which bots can learn about the tester. `notarget` does not work on NextBot vision and `nb_blind` kills the vision update outright, leaving nothing to inject into. On a live server it is a "make me invisible to bots" switch for anyone with rcon |
| the `CINSBotAttack::ctor` detour | A whole detour whose body is one increment. `atkCtor` is the only ground truth for whether the grenade fork reached the attack branch |

When `GRENADE_VERIFY` is on, `atkCtor` and `hidden` are reported on their own log line rather than
being wedged into the main counter dump.

**To verify grenades:** set it to `1`, recompile, then `grenade_chance 1.0` and `debug 1`, throw one
smoke, and check `fovForced` -> `atkCtor` -> `icaCalls` -> `nadeHits` still run 1:1:1:1. Note that
the grenade *mechanism* - the FOV fork, `InitialContainedAction`, `grenade_chance` - is not behind
the switch and ships as normal. Only the instrumentation is.

### Shipped, but not the mechanic

None of the below is load-bearing for "bots shoot into smoke", so each is a decision rather than a
bug.

- **`..._include_in_smoke`.** Off by default, and arguably the opposite of the plugin's job: it
  clears the blinded flag so bots *inside* the cloud can see out. Keep or cut on gameplay grounds,
  not correctness.
- **`..._refill_ammo` (on) and `..._unstick_grenade` (off).** Both are compensation for side
  effects the mechanic itself causes - drained magazines, bots left holding a grenade. In scope,
  but worth knowing they are the plugin cleaning up after itself rather than doing its job.
- **`..._dumpclasses`.** A discovery tool for building the weapon-class map. That map is built and
  recorded above; the command is kept only because it costs nothing.

### Separate from this plugin

`betterbots.cfg` raises `ins_bot_arousal_combat_max` from 5 to 10 on **main as well as test**. That
puts every bot on the server past the `IsMinArousal(8)` gate in any sustained firefight, so they
prefer `CINSBotRetreatToCover` over engaging. The `frac_*` aim and reaction tuning that config
actually wants scales continuously with arousal and does not need the cap that high - crossing the
discrete gate looks like collateral damage rather than intent. Worth investigating on main.
