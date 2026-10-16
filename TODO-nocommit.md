TODO discord plugin makes WAY too many getclientauthid calls. Cache them with the post auth and player disconnect events. Remove BAWT_AUTH_ID checks if possible. - backlog

<!-- confirmed bug: sometimes after changing maps, loadouts are not loaded but inv is reset -->
<!-- confirmed bug: smoke not spawning on art, due to art type. Need to create new theater/mod that has a death message set -->
<!-- reported bug: art smoke is on player position when thrown, not far away -->
<!-- confirmed bug: art not coming in on arcate_aof when grenade touches wall - todo make check look at multiple points within radius for sky vision -->
<!-- confirmed bug: art does not go off if grenade is cooked -->
<!-- confirmed bug: res takes way too long (30s for crit + med kit) -->
<!-- confirmed bug: no free lives -->
# confirmed bug: waterway map causes server to hang
confirmed bug: perf issues

admin plugins potential:
* submissions - https://forums.alliedmods.net/showthread.php?t=339036
* gag mute ban - https://github.com/fbef0102/Sourcemod-Plugins/tree/main/GagMuteBanEx
* team flashers to chat: https://forums.alliedmods.net/showthread.php?t=318496


others:
* bot name based on class name: https://forums.alliedmods.net/showthread.php?t=350950
* Auto-translate chat messages: https://forums.alliedmods.net/showthread.php?t=306279
* killer info: https://forums.alliedmods.net/showthread.php?t=75969



loadout failed to save
[console.log] [SGT] AT&T sucks Cox: !savelo
[console.log] L 12/17/2025 - 09:16:54: [LoadoutSaver.smx] Failed to save loadout: ERROR:  syntax error at or near "3"
[console.log] LINE 1: ...61198033602994, 'template_recon_security_coop', ''3;10;12'',...

[ADMIN] not showing up for me only

Discord messages dont show [SGT], [MEDIC], etc but do show name changes

reconnecting on every connection, not just first (bug?)

Round count is wrong
ROUND END: Insurgent Forces WIN! (4/3 embassy_coop)


discord plugin not capturing console output


betterbots.cfg raises ins_bot_arousal_combat_max 5 -> 10 (line 185) on main AND test. The engine
gates CINSBotCombat::Update on IsMinArousal(8): at arousal >= 8 a bot builds CINSBotRetreatToCover
instead of engaging. At the stock cap of 5 that is unreachable from combat alone; at 10 every bot
crosses it in any sustained firefight. The frac_* aim/reaction tuning that config wants scales
continuously and doesn't need the cap that high. Suspect unintended - investigate on main.
See plugins/sourcemod/scripting/gg2_bot_smoke_suppress.md, "SOLVED: suppression died after the
first smoke".

## Pending: workshop republish (test server)

Four committed theater changes are inert until item **3796695587** is republished and clients
re-download it. `make workshop-package WORKSHOP_ITEM_ID=3796695587`, then publish.

- M777 white phosphorus round + its yellow marker grenade, ammo entry and localisation
- NVG moved from the `accessory` gear slot to `misc1` (frees the sling slot) - UNVERIFIED, the
  category may render unlabelled; revert the block if the slot does not appear
- `carry 2` on grenade_m18_us / _ins / _wp_us (buying two arty smokes only granted one)
- HE shells use the RPG projectile model

Also unpublished: `workshop/map_asset_stubs/` (13 stub materials, `make workshop-package-stubs`
with `WORKSHOP_STUBS_ITEM_ID=0` for the first publish, then record the ID in the Makefile and in
subscribed_file_ids.txt).

## Pending: side-loaded builds on test

`gg2_forceretry_optout.smx` and `gg2_messages.smx` are side-loaded. Source is committed, so the next
image build carries them - but a redeploy before that reverts the server to the old behaviour.
`gg2_spectalk` and `gg2_hostname_rounds` are NEW files and could not be side-loaded at all (see the
casecache note in memory); they need the image build.

## Worth investigating separately

The stats Postgres drops idle connections - `server closed the connection unexpectedly` /
`no connection to the server` has now hit gg2_forceretry_optout, gg2_messages and SourceMod's own
clientprefs. Each has its own ad-hoc reconnect and each loses the in-flight query. Likely a
keepalive/connection-lifetime setting on the DB or on the Envoy proxy in front of it, rather than
something to keep patching per plugin.

## Session 2026-09-14 carryover

### Test server is running hand-placed state - ALL OF IT VANISHES ON REDEPLOY
Nothing below is at risk (the repo has it), but the live server is NOT running what a deploy would
produce:
* `/opt/insurgency-server/insurgency/models/twp_f8fd459b06d1/` (7 files) and `models/tug2/` were
  copied in by hand. A container restart re-indexes casecache and keeps them; a REDEPLOY loses them.
* The theater and the new vgui icons were pushed straight into the fastdl pod's emptyDir
  (`/srv/test`), not built into the content image.
* `sv_cheats 1` was set over RCON. Reverts on the next map change (server.cfg re-exec).

A real deploy needs BOTH images: `make server-image-test` (gg2_fastdl model fetch + CASECACHE_EXCLUDE)
and `make fastdl-image-test` (models, localisation group, icons). Watch the log for
`Fetching N theater file(s) and M model file(s)` - the server-side model download has only ever been
exercised by hand-copies.

### Uncommitted
* `fastdl/src/vgui/ammo_mk211_m107.{vmt,png,png.txt}` + `ammo_api_m107.{vmt,png,png.txt}` - M107
  ammo upgrade icons (the slots had no material at all). Both are stock `kit_ap_rifle` with the tip
  recoloured: mk211 green (Raufoss marking), api silver (M8 API marking). api deliberately does NOT
  reuse `kit_tracer` - right shape, but red is already that round's marking, so two upgrades would
  share an icon.
* Both icons recolour exactly the pixels `kit_tracer` changes relative to `kit_ap_rifle` - the tip
  cone the game's own artists masked, 379 px, bbox x52-79 y120-139 - so they differ from the stock
  ammo icons only at the tip. mk211 was re-cut against that mask; its first revision used a
  hand-drawn one covering the whole ogive, which bled onto the jacket and case mouth.
* `fastdl/tools/build.sh` - vgui step no longer warns for a VMT that deliberately references a
  shared/stock texture; it only warns when the VMT names its OWN stem and no source exists.

### Deferred, agreed
* Hash the vgui icon names. Blocked on adding a loadout DB column holding a CONSTANT name alongside
  the hashed one. Until then a changed icon needs the player to delete the file - fixed paths are
  write-once per client.

### Open, low priority
* `pow_raid_x64` buy/scoreboard map image renders as the missing-texture checkerboard. Confirmed NOT
  ours: the map ships no `vgui/maps/*` loose, none in any subscribed workshop item, and none among
  the 5423 files packed in its BSP. Stock ships `fallback_large/small` so it should fall back to the
  black placeholder - why it does not is unknown. Cosmetic, one map.
* Ammo-slot upgrade tooltips: DO work (earlier report was mistaken). No action.
* `gg2_theater_items` fails on the FIRST map of a process only, then recovers. Harmless.

## teamflash -> gg2_teamflash: bot flashbangs credited to players - FIXED 2026-09-15

De-vendored to `plugins/sourcemod/scripting/gg2_teamflash.{sp,md}` (git mv from `teamflash.sp`) and
rewritten; Dockerfile stage `sourcemod-plugins-teamflash` now builds `gg2_teamflash.smx`. Full
diagnosis is in the .md - in short, `#define FLASH_ID 2` was never the flashbang here (main: 2 is
`grenade_m18_impact`, m84 is 3; test: 2 is `grenade_m777_ins`, m84 is 10), and the victim flags were
only ever cleared for victims that got counted, so blinds caused by bots accumulated forever and the
next id-2 detonation claimed them all. Now: id looked up by name via gg2_theater_items per map, and
blinds matched to their grenade on the game TICK, which is exact because
`CFlashBangGrenade::DoFlashEffect` calls `RadiusFlash` and then `EmitEvent` in one call.

**Hand-placed on the TEST server, discarded by a redeploy:** the new plugin was side-loaded by
overwriting the EXISTING file - `docker cp` to
`.../addons/sourcemod/plugins/teamflash.smx`, then `sm plugins reload teamflash`. It had to reuse
that filename: casecache answers an authoritative ENOENT for a path under an indexed ancestor that
did not exist at startup, so a NEW `gg2_teamflash.smx` would have been invisible to the server. A
`make server-image-test` deploy puts it at the right name and the stale `teamflash.smx` goes away
with the old image.

Worth a look separately: **main is running TUG's `theater_tug_39_medicbomber_12p_default` directly,
not our built theater.** No `theater_tug_nvg_default` and no fastdl plugin lines anywhere in main's
console.log. If that is not intended, none of our theater work is live on main.


## LoadoutSaverSlots "not responding to commands" - DIAGNOSED 2026-09-15, not fixed

Nothing is broken in the infrastructure. Verified live: plugin #53 loaded and running, executes
commands (`sm_loadout_dumppurchases` over RCON returns a full dump), DB connected since 06:32 UTC
09/14 with no reconnects and no SQL errors, its tables are present (schema `insurgency-test`:
`loadouts_slots`, `loadout_items`, `theater_items`), saves are landing (JaneWick `!savelo` at
01:38:33 -> row written 01:38:34), `last_seen_at` updating on connect, theater ids resolving, all
`sm_loadout_*` cvars at defaults.

The LOAD path has three early returns that say nothing to the player:

1. `ApplyLoadout`: `if (!IsPlayerAlive(client)) return;` - after the whole DB round trip. Dead or
   not yet spawned means the command does nothing and reports nothing.
2. `OnLoadoutRetrieved`: `!results.FetchRow()` only messages for a NAMED load. A bare `!loadlo`
   with no saved loadout for the class you are currently on is silent by design.
3. `Command_LoadLoadout`: the cooldown check is a bare `return Plugin_Handled;`.

`!savelo` has none of these (it messages on cooldown, and has no alive check), which is why saving
kept working and the pair looked half-dead.

What actually happened today: connect 01:23:44, `!loadlo saiga` at 01:24:10 - 26s later, before the
spawn wave at 01:24:33 - so path 1. The `saiga` row exists in the DB, so the query found it; path 1
is the only silent exit left. Same shape on 09/14: `!loadlo saiga` at 00:18:01 and 00:18:47, both
within a minute of connecting at 00:17:25, both before `GR_STATE_RND_RUNNING` at 00:18:5x. Chronic,
not new - roughly half of all `!loadlo` uses in two days of console.log produced no plugin output.

Aggravating: **`!lsload` is not a registered alias.** Registered are `sm_listlo`, `sm_listloadouts`,
`sm_loadouts`, `sm_lslo`, `sm_lsloadout`, `sm_lsloadouts`. SourceMod silently ignores an unknown
`!` command, so the natural follow-up probe also produced nothing and made the whole plugin look
dead.

`sm_lsload` HAS NOW BEEN ADDED to both LoadoutSaverSlots.sp and LoadoutSaver.sp, and side-loaded
onto test (`docker cp` over `LoadoutSaverSlots.smx` + `sm plugins reload`); RCON confirms it is
registered. It was never registered before - `git log -S sm_lsload` only matches because
`sm_lsloadout`/`sm_lsloadouts` contain the substring, so commit 62e68ac "make lsload show basic
weapon info" was naming the feature, not the alias. Still uncommitted, and main's copy is not
deployed.

Still to fix: the three silent returns should say something - "you have to be spawned to load a
loadout", "nothing saved for <class>", and the cooldown.

## Smoke warning cap - FIXED 2026-09-15

The cap was being enforced correctly; the HINT was not per-player. Style 1 builds an
`env_instructor_hint`, and `CEnvInstructorHint::InputShowHint` fires ONE
`instructor_server_hint_create` event with `FireEvent(event, bDontBroadcast = 0)` and no recipient
filter - every client receives it. The activator is carried only as `hint_activator_userid` (read
from the input's activator, verified in the disassembly), and the filtering is client side, in the
`server_hint` lesson in `scripts/instructor_lessons.txt`:

    hint_local_player_only 0 -> opens on EVERY client; the activator merely gets
                                hint_activator_caption swapped in, which we never set
    hint_local_player_only 1 -> "local_player is entity2", opens only on the activator

We shipped 0. So the cap chose who TRIGGERED a warning while the warning was painted on everyone
within hint_range (1500) of the cloud - which in coop is most of the squad. A capped player kept
seeing it whenever any uncapped player set one off, and never incremented their own count (not the
activator), so their row froze and it never stopped. Exactly matches the report: user at count 10,
last_shown stuck at 09-13, still seeing it, and no row anywhere above 10.

Observed live: across two `sm_bot_smoke_suppress_warnstate` dumps five minutes apart, LoRdLoSs went
2 -> 3 and JaneWick 4 -> 5 while both capped players sat at 10. Those two increments are the hints
the capped players were seeing.

Fixed by setting `hint_local_player_only` to 1. Styles 0 (`game_text`, "All Players" spawnflag
clear) and 2 (`PrintHintText`) were never affected.

UNCOMMITTED in `gg2_bot_smoke_suppress.sp`: the fix, plus a `sm_bot_smoke_suppress_warnstate` RCON
debug command that dumps per-player cap state (captured Steam id, loaded count, round gate,
verdict). `.md` updated. Side-loaded onto test by `docker cp` over `gg2_bot_smoke_suppress.smx` +
`sm plugins reload`; discarded by a redeploy.

Still latent, not hit here: if `GetClientAuthId` fails in `OnClientPostAdminCheck` the Steam id is
never captured, `g_iWarnCount` falls open to 0 and `RecordWarning` no-ops, so that player is warned
once per round forever and the table never moves. `warnstate` shows it as `steamid=<NOT CAPTURED>`
with `count=0`. Worth re-attempting the capture on spawn or a timer if it ever turns up.

## Survival: Security bot kits - FIXED 2026-09-15

**Root cause.** Survival does not build its waves from the theater's `teams/security/squads`. The
mode asks for 12 class templates BY NAME - `template_survival_base_01..05_security`,
`template_survival_officer_01..05_security`, `template_survival_m249_security`,
`template_survival_at4_security` - which live in stock `default_survival.theater`. That file is NOT
in our ancestry (`theater_tug_nvg_default` -> TUG `medicbomber_12p` -> ... -> `default.theater`;
`default_survival` is a SIBLING of `default`), and TUG ships no `_survival` variant. The server said
so once per wave: `Can't precache non-existant class ...` / `Failed to find template ... when giving
items`. A template that cannot be found gives no items. Confirmed live on `convoy_pve`:
`sm_bot_smoke_suppress_nadecheck` reported 0/8 living bots carrying anything.

**Fix.** All 12 defined in a `player_templates` section of
`theater_tug_nvg_default_survival.theater`, built out of the MODIFIED rack rather than copied from
stock - stock arms every wave from vanilla (m9/mp5/ump45/m16a4/m4a1) so none of the weapons this
theater adds ever reach an attacker. Same escalation shape and same supply cost per wave, so the
difficulty curve is unchanged and only the hardware differs:

    01 base    3  glock17 + m84                    01 officer  5  mp5a4
    02 base    5  mp7                              02 officer  8  p90 + AP
    03 base    7  m16a1                            03 officer 10  g36c silenced
    04 base    9  scarl + foregrip                 04 officer 10  sig553 silenced
    05 base   10  acr + aimpoint + AP              05 officer 10  m4a1sopmod silenced + AP
    m249      9  mk46 + aimpoint                   at4         6  at4

Every entry was verified programmatically against the merged theater before being written: weapon
exists and has `security` in `team_access`, each upgrade lists its weapon in its own
`allowed_weapons`, each gear item resolves. That check is why the SCAR gets
`underbarrel_foregrip_scar` and not `underbarrel_foregrip_sec1`. Costs 3-10 against
`mp_supply_token_bot_base` 20 (stock) / 35 (gg2_supply), so every wave affords its kit.

**Pushed** to fastdl as `theater_tug_nvg_default_b7b664edc55f`; gg2_fastdl repoints
`mp_theater_override` at the next map change, no deploy needed.

## Survival: player starting supply - FIXED 2026-09-15, NEEDS A DEPLOY

The engine was already right - the game's own `cfg/default_server_survival.cfg` sets
`mp_supply_token_base 2`. `gg2_supply` was overriding it: it raises `m_nRecievedTokens` to
`sm_supply_player_tokens` (100) on every `round_start` and `player_team`, in every gamemode. So
survival players spawned with 100 supply.

New `cfg/server_survival.cfg` sets `sm_supply_player_tokens 15`. Chosen, not guessed: the insurgent
templates the survival cells use cost 4-12 supply for their own buy_order (the AT4/LAW sappers are
the 12), so 15 covers the dearest with headroom and leaves nothing meaningful to spend. gg2_supply
only ever raises, so this does not fight the engine's 2.

The cvar is not reset between maps, so it is pinned back to 100 in `server_checkpoint.cfg` and
`server_hunt.cfg`, and new one-line `server_conquer.cfg` / `server_outpost.cfg` pin it for the two
modes in the cycle that had no cfg at all.

**Needs `make server-image-test`.** Three of those five files are NEW, and casecache answers an
authoritative ENOENT for a path that did not exist at container start - so they cannot be side-loaded
the way a .smx over an existing filename can. Stopgap if wanted before the deploy: `sm_supply_player_tokens 15`
over RCON, but it then applies to every mode until the image lands.

Not applied to `server config/main/` - main's cycle was not checked for survival maps.

Still open from this work: the survival `teams/security/squads` block is a verbatim copy of the
CHECKPOINT PLAYER squads and the waves ignore it, so it may be dead weight; and all six
`*_security_coop` templates have byte-identical buy_orders, making those role names cosmetic.

## gg2_fuckyeah: per-faction voicelines - FIXED 2026-10-01

Every file in `FuckingSounds` is a `player/voice/.../security/...` line, so an insurgent kill emitted a
security voice out of the killer's own body. The 2026-09-15 fix (8405510) gated `Fuck()` on
`TEAM_SEC`, on the wrong belief that the game ships no insurgent counterparts - which silenced the
plugin entirely in survival, where the players are insurgents (team 3). The game does ship them
(`radial/insurgents/...`, `responses/insurgent/...` in insurgency_sound_dir.vpk), so 1.2.0 adds
`FuckingSoundsIns` and picks the list by the killer's team. Insurgents have 10 subordinate "target"
responses to security's 13; the insurgent lines were picked by path, not listened to.

## Shell-fed ("loose") ammo audit - 2026-09-15

**The discriminator is `flags_clear "AMMO_USE_MAGAZINES"`.** An ammo type that clears it is loose
fed, counted in ROUNDS, and its `magsize` is the size of one load. Every such type needs its OWN
magsize: the `default` ammo base declares `magsize 30` for magazine-fed rifles, and inheriting that
is always wrong for something you feed by hand. This is the same shape as the pump-shotgun bug in
a094cf6.

TUG's per-weapon escape hatch is **`magsize_override`** inside the weapon's `ammo_clip` block, and
two weapons already use it (`weapon_gol` and `weapon_remingtonmsr`, `clip_max_rounds 10` +
`magsize_override 10`). Worth knowing - it is a much smaller lever than restating an ammo type, and
it is the only way to fix weapons that SHARE an ammo type but hold different amounts.

Full sweep of every loose-fed weapon, effective magsize vs `clip_max_rounds`:

### Fixed (bolt actions)
    weapon_mosin    762x54mm          load 5, was 30
    weapon_kar98    762x54mm          load 5, was 30
    weapon_enfield  303_clip_enfield  load 5, was 30
    weapon_m40a1    762x51mm          load 5, was 30

Fixed at the ammo level - seven types restated in full with `magsize 5`: `762x54mm`, `762x54mm_ap`,
`762x51mm`, `762x51mm_ap`, `303_clip_enfield`, `303_clip_enfield_ap`, `303_clip_enfield_hp`. Safe
because none of those types is shared with a weapon that disagrees: `762x51mm` is the m40a1 plus the
two rifles that already override to 10, and a weapon-level override beats the ammo type.

The `_ap`/`_hp` variants are included because they do NOT import their base type - `762x54mm_ap`
runs `762x54_ap -> 762x51_ap -> 762x51 -> default`, never through `762x54mm` - so fixing the base
alone would leave the round you actually bought broken. Same trap as the shotgun upgrades.

Pushed as `theater_tug_nvg_default_a209a3601a03`; live at the next map change.

### NOT fixed - shotguns that share an ammo type with a different tube size
    weapon_ksg             load 14, magsize 8   (4buckshot)
    weapon_toz             load  6, magsize 8   (4buckshot)
    weapon_m1014           load  4, magsize 8   (4buckshot)
    weapon_doi2ins_m1897   load  5, magsize 8   (00buckshot)

a094cf6 set 4buckshot/00buckshot to 8, which is right for m590/m500/spas12/nova and wrong for these
four. One ammo type cannot express five tube sizes, so the fix is `magsize_override` per weapon -
which needs the weapon restated in full, four times. Not done.

### Also found: the rifled-slug fix landed on a dead name
`rifledslugs` (added by a094cf6, magsize 8) is referenced by **nothing** - no weapon `ammo_type`, no
upgrade `import` or `ammo_type_override`. The live path is the upgrade `ammo_rifledslug`, which
imports `rifledslug`: a root definition with no `import`, no `carry`, no `magsize` and no flags at
all. So buying rifled slugs is still unfixed, and the comment above the shotgun block claiming
otherwise is wrong. Verify with `ammo_probe` while holding slugs before deciding the shape of the
fix.

## Objective supply in survival - INVESTIGATED 2026-09-15, NOT resolved

Report: no points for taking objectives as insurgents in survival.

Live cvars on the test server, all enabled, none touched by us or by the game's own
`default_server_survival.cfg`:

    mp_supply_gain               1
    mp_supply_gain_obj_cap       1     amount earned by capturing a point
    mp_supply_gain_obj_hero_cap  1
    mp_supply_gain_obj_destroyed 1     amount earned by destroying a cache
    mp_supply_gain_regroup       1
    mp_supply_token_max          30    the maximum a player may HOLD

First hypothesis was that `mp_supply_token_max` (30) was the blocker - gg2_supply forces
`m_nRecievedTokens` to `sm_supply_player_tokens` (100), which would park every player permanently
above the cap so no in-round award could raise them. **The live read does not support it.**
`ammo_probe` now prints supply, and on `payback_x64`:

    humans   received=2  available=2  max=30
    bots     received=35 available=24 max=30

So players are at 2, nowhere near the cap, and the bots prove gg2_supply's write does stick above
max (35 > 30) - the engine does not clamp the netprop. Both humans were dead at both samples, so 2
is the engine's `mp_supply_token_base` for survival and gg2_supply had not (yet) raised them.

**This also undercuts the premise of the server_survival.cfg change above.** That was written on the
assumption players spawn into survival with 100; the only live read says 2. The pin is still correct
- it stops gg2_supply raising them if it does fire - but whether 100 ever actually lands needs a
read from a LIVE player, which I could not get before the server moved off survival.

What is still needed: `ammo_probe` immediately before and immediately after a cache capture, with a
spawned player, to see whether `available` moves at all. That is one RCON call now that the probe
prints supply. Candidate causes if it does not move: survival caches are *secured*
(`ins_survival_cache_secure_team_ratio`) rather than captured or destroyed, so they may not reach
the code path `mp_supply_gain_obj_cap` / `_obj_destroyed` guards.

UNCOMMITTED: supply line added to `Command_AmmoProbe` in LoadoutSaverSlots.sp, side-loaded onto test.

## gg2_discord: bot join spam in survival, no insurgent joins - FIXED 2026-09-15

`Event_PlayerTeam` filtered on TEAM, not on bots:

    if (team == TEAM_2_INS) return Plugin_Continue;

That is only a bot filter by coincidence - insurgents are the bots in checkpoint. Survival swaps the
sides (players insurgents, bots security), so the line silenced every human join and let the whole
bot team through instead, once per respawn wave. Each of those rendered as a bare
" Joined Security Forces" because `gen_steam_link` falls back to `%N` when `GetClientAuthId` returns
the BAWT_AUTH_ID placeholder, and a bot has no name yet at `player_team` time.

Fixed three ways:
* filter `IsFakeClient` instead of the team - the same test `Event_PlayerDisconnect` already used;
* added the `TEAM_2_INS` -> "Insurgent Forces" label that never existed;
* `joined_team` widened from `[16]` to `[20]` - "Insurgent Forces" is 16 chars plus the NUL;
* empty-name fallback to the event's own `name` field, so a first-connect `player_team` that fires
  before the name is set cannot post a message starting with a space.

Checkpoint behaviour is effectively unchanged: insurgent bots were already suppressed (by team,
now by IsFakeClient) and there are no security bots in that mode.

Compiled with `--include plugins/sourcemod/scripting/include-nocommit` for `ripext` (the Dockerfile
mounts it from the ripext extension stage). The two remaining warnings are pre-existing, line 623,
HTTPStatus tag mismatch. Side-loaded onto test; uncommitted.

## sm-ext-discord security review - 2026-09-15: CLEAN but UNUSABLE, not installed

Reviewed https://github.com/Dreae/sm-ext-discord at 21b819e.

**Not malicious.** ~1,500 lines of first-party code (10 Rust files, 12 C++), a thin FFI wrapper
around the `serenity` crate. Scanned for `system`/`popen`/`exec*`/`fork`/`dlopen`/`Command::new`/
raw sockets/`getenv`/file writes/hardcoded hosts: nothing. The only URLs anywhere are Discord's own,
the project's GitHub page, and google.com in the example plugin. No binaries committed (`git ls-files`
is 100% text). Submodules point at the official alliedmodders repos for sourcemod, hl2sdk and
metamod-source. Its entire job is: open a gateway connection, hand messages to SourcePawn callbacks,
send messages/embeds/webhooks back.

**Unusable anyway, on three independent counts:**

1. *No obtainable Linux binary.* The README's GitLab artifact link (the only Linux one) is **404**.
   No GitHub releases exist at all. AppVeyor covers Windows only.
2. *Cannot connect to Discord.* It pins `serenity = "0.5.1"`, whose `src/constants.rs` says
   `GATEWAY_VERSION: u8 = 6` and whose REST base is `https://discordapp.com/api/v6`. Discord retired
   gateway/API v6, and v8+ requires an `intents` field on IDENTIFY that serenity 0.5 never sends.
   MESSAGE_CONTENT also became a privileged intent in 2022, which this predates entirely.
3. *Cannot be built.* `rust/src/lib.rs` opens with `#![feature(libc)]` - a nightly feature gate that
   no longer exists - and the CI is Fedora 27 + `rustup --default-toolchain nightly` + i686 static
   OpenSSL, from 2018.

Repo state: last push **2018-09-22**, 5 stars, 0 releases, no commits in 8 years.

**Not installed.** Nothing was copied to the test server. Awaiting a decision on transport - see the
Discord bridge feasibility discussion: either the game server polls Discord's REST API directly with
ripext (no new binary, but the bot token lives on the game server), or a small bridge service in the
cluster holds the gateway and the plugin polls that (token stays off the game server).
