# Persistent Punishments Plugin

A comprehensive SourceMod plugin for managing persistent bans and communication restrictions with PostgreSQL database backend. Punishments automatically reapply when players reconnect to the server.

## Features

- **Persistent Bans**: every basebans ban (`!ban`, `sm_addban`, `sm_banip`, the admin menu, auto-bans) is stored and re-enforced on connect
- **Persistent Gags/Mutes**: every basecomm gag (text chat) and mute (voice) is stored and re-applied on connect
- **Unbans/ungags** through basebans/basecomm deactivate the stored row
- **Survives database drops**: writes that hit a dead connection are queued and replayed after reconnecting

## Bans From Other Plugins

`!ban` / `sm_ban`, basebans' `sm_addban` and `sm_banip`, and anything else that calls `BanClient()` or
`BanIdentity()` with a command string (including gg2_teamkill's automatic team-kill bans) are also
written to the database, through SourceMod's `OnBanClient` / `OnBanIdentity` forwards. The engine
still applies the ban itself - the forwards return `Plugin_Continue` - so it takes effect and kicks
immediately; the database row is what makes it survive a restart. The engine only holds timed bans
in memory, so before this every `!ban` was lost on the next restart or redeploy.

basebans' `sm_unban` is mirrored the same way (`OnRemoveBan`), so an unban there also deactivates
the row instead of leaving the player to be kicked again on their next connect.

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
| punishment_type | VARCHAR(32)  | Type: ban_steamid, ban_ip, gag, mute, silence |
| target_steamid  | VARCHAR(32)  | Target's SteamID (nullable)                   |
| target_ip       | VARCHAR(64)  | Target's IP address (nullable)                |
| target_name     | VARCHAR(64)  | Last known name                               |
| admin_steamid   | VARCHAR(32)  | Admin who issued punishment                   |
| admin_name      | VARCHAR(64)  | Admin's name                                  |
| reason          | VARCHAR(255) | Reason for punishment                         |
| issued_at       | TIMESTAMP    | When issued                                   |
| expires_at      | TIMESTAMP    | When expires (NULL = permanent)               |
| is_active       | BOOLEAN      | Whether currently active                      |

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

This plugin registers **no admin commands**. basebans and basecomm own every ban and comm command;
this plugin records what they do and re-applies it.

### Gags and mutes

basecomm owns `sm_gag` (text chat), `sm_mute` (voice), `sm_silence` (both) and their `sm_un...`
forms. Every change - by command, by the admin menu, by group targets such as `@all`, or by another
plugin - reaches the database through basecomm's `BaseComm_OnClientGag` / `BaseComm_OnClientMute`
forwards. They are stored as separate `gag` and `mute` rows with no expiry; they last until lifted.
The issuing admin is recorded when the change came from a command (the admin menu records none).

Legacy `silence` rows are still enforced. Lifting one half of a legacy silence keeps the other half
by splitting it into its own row.

### When a punishment is issued
1. basebans / basecomm apply it in-game immediately (and kick, for bans)
2. The matching forward fires and the row is written via `RunWrite` (see Database outages)

### On Player Connect
1. Query database for active punishments by SteamID and IP
2. Bans: kick immediately
3. Gags/mutes: re-applied through basecomm once the player is fully in game - basecomm's natives
   refuse a client that is still loading, which is where the lookup usually finishes

## Admin Immunity

Enforced by basebans and basecomm when the command is issued, using SourceMod's standard
`CanUserTarget()` rules. This plugin issues no punishments of its own, so it has nothing to check.
