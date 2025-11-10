# Persistent Punishments Plugin

A comprehensive SourceMod plugin for managing persistent bans and communication restrictions with PostgreSQL database backend. Punishments automatically reapply when players reconnect to the server.

## Features

- **Persistent Bans**: Ban by SteamID or IP address with timed or permanent duration
- **Communication Restrictions**: Gag (voice), mute (text), or silence (both) players
- **Automatic Reapplication**: All active punishments automatically reapply on player connect
- **Admin Immunity**: Built-in checks to prevent admins from targeting other admins
- **Flexible Targeting**: Support for name, #userid, and #steamid targeting
- **Database Persistence**: All punishments stored in PostgreSQL for reliability

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

### When Admin Issues Punishment
1. Validates target and admin permissions
2. Checks admin immunity
3. Applies punishment via SourceMod natives
4. Only saves to database if successfully applied
5. For bans: kicks player from server

### On Player Connect
1. Query database for active punishments
2. Check both SteamID and IP address
3. Verify punishments haven't expired
4. Reapply all active punishments
5. For bans: kick player immediately
6. For comms: restore gag/mute state

## Admin Immunity

The plugin respects SourceMod's admin immunity system:
- Admins cannot target other admins with equal or higher immunity
- Uses `CanUserTarget()` for immunity checks
- Console always has highest immunity
