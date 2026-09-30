# Persistent Punishments Plugin

A comprehensive SourceMod plugin for managing persistent bans and communication restrictions with PostgreSQL database backend. Punishments automatically reapply when players reconnect to the server.

## Features

- **Persistent Bans**: every basebans ban (`!ban`, `sm_addban`, `sm_banip`, the admin menu, auto-bans) is stored and re-enforced on connect
- **Persistent Gags/Mutes**: every basecomm gag (text chat) and mute (voice) is stored and re-applied on connect
- **!calladmin bans**: a player banned from `!calladmin` who uses it is banned from the server automatically, and their message reaches Discord without the admin ping
- **Class bans**: a player banned from a class (medic, sergeant, ...) can't pick it - the pick is refused, not undone with warnings and a kick
- **Unbans/ungags** through basebans/basecomm deactivate the stored row
- **Survives database drops**: writes that hit a dead connection are queued and replayed after reconnecting

## Bans From Other Plugins

`!ban` / `sm_ban`, basebans' `sm_addban` and `sm_banip`, and anything else that calls `BanClient()` or
`BanIdentity()` with a command string (including gg2_teamkill's automatic team-kill bans) are
written to the database through SourceMod's `OnBanClient` / `OnBanIdentity` forwards.

**This plugin enforces bans, not the engine.** The forwards return `Plugin_Handled`, so core skips
its `banid` / `addip`. The engine rejects banned players with its own fixed text, which can't be
changed; taking the ban away from it means every message the player sees can show the duration.

The plugin also kicks the player itself. Core still queues its own kick after a handled forward
(basebans' message: `Banned` or the bare reason), but it ignores a second kick for a player
already queued, and ours is queued first.

### Ban messages

| When | Message |
| --- | --- |
| On the ban | `Banned for 1d 8h. Reason: TK` |
| Reconnecting | `Banned - 23h 12m remaining. Reason: TK` |
| Permanent | `Permanently banned. Reason: TK` |

Durations are compact (`y`/`d`/`h`/`m`, zero units dropped, a year is 365 days). Remaining time
rounds up, so it never reads `0m`. basebans' placeholder reason `Banned` (no reason given) is
left out. Kick messages are capped at 255 bytes (`KickClient`'s buffer). The duration is never
cut; a long reason is trimmed on a UTF-8 character boundary and marked with `...`.

The chat announcement to other players (`Banned player "x" for 1440 minutes.`) is basebans' and is
unchanged.

### Ban cache

Every active ban is held in memory so enforcement never waits on the database. The cache is loaded
from the database once, on the first connection that works. After that, bans and unbans issued on
this server update it directly. Bans are only ever issued through this server, never on another
server or in SQL, so there's no periodic refresh. A ban added to the table by hand is still
enforced through the per-connect database lookup, but an unban done in SQL won't take effect
until the plugin reloads.

- **IP bans** are refused in `OnClientConnect`, before the player loads in and without needing
  Steam authorization.
- **SteamID bans** are kicked in `OnClientAuthorized`. A cache miss still asks the database, and a
  ban found there is added to the cache.

basebans' `sm_unban` is mirrored the same way (`OnRemoveBan`), so an unban there also deactivates
the row and drops the ban from the cache. It still lets the engine run its `removeid`/`removeip`,
which lifts any ban the engine held from before this plugin took bans over.

SteamIDs in `STEAM_X:Y:Z`, `[U:1:N]` or SteamID64 form are all stored as SteamID64
(see `include/steamids.inc`).

### Ban commands belong to basebans

This plugin does **not** register any ban command. Use SourceMod's standard ones - times are in
minutes, `0` is permanent:

| Command | Use |
| --- | --- |
| `!ban <name\|#userid> <minutes> ["reason"]` | Ban a connected player |
| `sm_addban <minutes> <STEAM_X:Y:Z> ["reason"]` | Ban an offline player by SteamID |
| `sm_banip <ip\|name\|#userid> <minutes> ["reason"]` | Ban by IP |
| `sm_unban <STEAM_X:Y:Z\|ip>` | Lift a ban |

It used to register its own `sm_addban`, `sm_banip` and `sm_unban` (SteamID64 and `8h`-style
times). SourceMod ran both plugins' handlers for each command, with incompatible argument formats,
so every use was half-applied. basebans' `sm_addban` and `sm_unban` require the `STEAM_X:Y:Z` form.

### Database outages

The pooled connection to this database drops when it sits idle. Every write goes through
`RunWrite`: a write that hits a dead connection is queued, the plugin reconnects, and the write is
replayed once. Anything that still fails is logged with the full query, so a ban can be re-entered by
hand. A player who connects while the plugin is reconnecting is checked once the connection is back,
rather than being let through unchecked.

## Database Schema

### Punishments Table

| Column          | Type         | Description                                   |
| --------------- | ------------ | --------------------------------------------- |
| punishment_id   | SERIAL       | Primary key                                   |
| punishment_type | VARCHAR(32)  | Type: ban_steamid, ban_ip, gag, mute, silence, calladmin_ban, class_ban |
| target_steamid  | VARCHAR(32)  | Target's SteamID (nullable)                   |
| target_ip       | VARCHAR(64)  | Target's IP address (nullable)                |
| target_name     | VARCHAR(64)  | Last known name                               |
| admin_steamid   | VARCHAR(32)  | Admin who issued punishment                   |
| admin_name      | VARCHAR(64)  | Admin's name                                  |
| reason          | VARCHAR(255) | Reason for punishment                         |
| issued_at       | TIMESTAMP    | When issued                                   |
| expires_at      | TIMESTAMP    | When expires (NULL = permanent)               |
| is_active       | BOOLEAN      | Whether currently active                      |
| target_class    | VARCHAR(64)  | Class template of a `class_ban`; NULL otherwise |

## Maintenance

### Deactivate Expired Punishments

Run periodically via cron or manually:

```sql
SELECT deactivate_expired_punishments();
```

### View Active Punishments

```sql
SELECT * FROM punishments 
WHERE is_active = TRUE 
AND (expires_at IS NULL OR expires_at > CURRENT_TIMESTAMP);
```

### Delete Old Inactive Records

```sql
DELETE FROM punishments 
WHERE is_active = FALSE 
AND issued_at < CURRENT_TIMESTAMP - INTERVAL '90 days';
```

### Find Player Punishments

```sql
SELECT * FROM punishments 
WHERE target_steamid = 'STEAM_0:1:12345678';
```

### Punishment Statistics

```sql
SELECT punishment_type, COUNT(*) as count 
FROM punishments 
WHERE is_active = TRUE 
GROUP BY punishment_type;
```

## How It Works

basebans and basecomm own every ban and comm command; this plugin records what they do and
re-applies it. The only commands it registers are for its own punishments: the `!calladmin` ban
and class bans.

### !calladmin bans

`!calladmin` pings the whole admin role on Discord (gg2_discord). For players who abuse it:

| Command | Use |
| --- | --- |
| `sm_bancalladmin <#userid\|name\|steamid> <minutes\|0> [reason]` | Ban from `!calladmin`; `0` is permanent |
| `sm_unbancalladmin <#userid\|name\|steamid>` | Lift it |

Both need the ban flag (`d`) and work from chat as `!bancalladmin` / `!unbancalladmin`. Arguments
match `sm_ban`: the length is required, and the reason is the rest of the line. A SteamID in any
form works for players who are offline. Banning again replaces the old calladmin ban, its length
and its reason.

The admin menu has it under **Player Commands > Ban/unban from !calladmin**. Picking a player who
is already banned from `!calladmin` (marked `[banned]`) lifts it; anyone else goes on to a length
(permanent, 1 day, 1 week, 30 days). The menu has no way to enter a reason, so its calladmin bans
have none; use the command when you want one.

When a player banned from `!calladmin` types it:
- **The message still goes through.** It shows in chat, and gg2_discord relays it to Discord
  marked `(banned from !calladmin - no ping)`, without the role mention. gg2_discord asks through
  the `Punishments_IsCallAdminBanned` native (`include/punishments.inc`), which also holds the
  shared `IsCallAdminMessage` check (message starts with `!calladmin`, any case) so both plugins
  agree on what counts.
- **They are banned from the server** for `sm_calladmin_abuse_ban_minutes` (default `60`) with the
  reason `Abusing !calladmin`. The ban goes through `BanClient`, so it is stored, cached, messaged
  and reported to Discord like any other.
- **The calladmin ban stays**, so each later use costs another server ban.

Calladmin bans are stored as `calladmin_ban` rows and re-applied on connect.

**Ownership.** `admin_steam_id` records who issued each row (NULL = console):
- A `calladmin_ban` row belongs to the admin who ran the command or used the menu.
- The server ban it triggers belongs to that same admin, even if they are offline by then.
  Discord's **BAN:** notice names them when they're online, and says Console otherwise.

### Class bans

Bans a player from one class. Replaces gg2_medic_tracker's `sm_ban_medic`, which let the player
pick medic and then warned them three times before kicking; that plugin now only tracks medic
playtime.

| Command | Use |
| --- | --- |
| `sm_banclass <#userid\|name\|steamid> <class> <minutes\|0> [reason]` | Ban from a class; `0` is permanent |
| `sm_unbanclass <#userid\|name\|steamid> <class>` | Lift it |
| `sm_classes` | List the current theater's classes: slot title and template name |

Both need the ban flag (`d`) and work from chat as `!banclass` / `!unbanclass`. A SteamID in any
form works for offline players. Banning again from the same class replaces the length and reason.

**Naming the class.** Bans are stored by class template name (`template_combat_medic`,
`template_recon_security_coop`). `<class>` can be:
- the full template name;
- any text found in exactly one of the current theater's template names or slot titles: `medic`,
  `sgt` (the `#Squad_Fireteam_WeaponsSgt` slot), `recon`. More than one match lists them, and no
  match prints every class in the current theater (slot title and template name, as `sm_classes`);
- a full `template_...` name the current theater doesn't have. It's stored anyway and applies on
  maps whose theater has that class.

Because the key is the template, a theater that drops a class just never matches it; the ban is
kept and applies again wherever the class exists.

**Admin menu:** Player Commands > **Ban/unban from a class**. Pick a player, then a class: the
current theater's classes by slot title, plus any class the player is banned from that this theater
lacks. A class marked `[banned]` is lifted when picked; anything else goes on to a length
(permanent, 1 day, 1 week, 30 days). No reason step, as with the `!calladmin` menu.

**Enforcement.** The pick itself is refused:
- A detour on `CPlayTeam::AddPlayerToSquad` (`gamedata/tug2.games.txt`) returns false for a slot
  whose class the player is banned from. It is the only place a player is put into a squad slot;
  its single caller, `CINSPlayer::JoinSquad(int, int)`, serves the `joinsquad` command, squad-only
  picks and `AutoJoinSquad` alike. A refused join changes nothing: no class, no loadout, no
  `player_pick_squad`. `AutoJoinSquad` moves on to the next free slot.
- The slot's class is read from the theater's team definition, the way `OnSquadSlotChanged` reads
  it (offsets are in the gamedata comments).
- The player is told why in chat and center text. If they had no class yet, the plugin sends the
  client `changesquad` to reopen the selection screen.
- A player already in the class when banned, or whose stored bans load after they picked, is moved
  to spectator with the same explanation.
- If the gamedata stops resolving, the plugin logs an error and falls back to moving the player to
  spectator after the pick. Server bans are unaffected either way.

Class bans and unbans are posted to Discord (`**CLASS BAN:**` / `**CLASS UNBAN:**`) when gg2_discord
is loaded.

### Gags and mutes

basecomm owns `sm_gag` (text chat), `sm_mute` (voice), `sm_silence` (both) and their `sm_un...`
forms. Every change - by command, by the admin menu, by group targets such as `@all`, or by another
plugin - reaches the database through basecomm's `BaseComm_OnClientGag` / `BaseComm_OnClientMute`
forwards. They are stored as separate `gag` and `mute` rows with no expiry; they last until lifted.
The issuing admin is recorded when the change came from a command (the admin menu records none).

Legacy `silence` rows are still enforced. Lifting one half of a legacy silence keeps the other half
by splitting it into its own row.

### When a punishment is issued
1. Bans: the forward caches the ban, kicks with the duration message and writes the row
2. Gags/mutes: basecomm applies it in-game, then the forward writes the row
3. `!calladmin` bans and class bans: applied to the player if connected, and the row is written
4. Writes go through `RunWrite` (see Database outages)

### On Player Connect
1. IP bans: refused at connect from the cache
2. SteamID bans: kicked on authorization from the cache, otherwise from the database lookup
3. Gags/mutes: re-applied through basecomm once the player is fully in game - basecomm's natives
   refuse a client that is still loading, which is where the lookup usually finishes
4. `!calladmin` bans and class bans: re-applied from the database lookup

## Admin Immunity

Enforced by basebans and basecomm when the command is issued, using SourceMod's standard
`CanUserTarget()` rules. The `!calladmin` and class ban commands and menus apply the same rules: `CanUserTarget()`
for a connected player, `CanAdminTarget()` for an offline SteamID.
