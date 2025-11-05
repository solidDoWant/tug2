# Insurgency Loadout Saver Plugin

A SourceMod plugin for Insurgency (2014) that allows players to save and restore their loadouts per class.

Thanks [Bot Chris](https://github.com/santosoch/insurgency) and [Nullifidian](https://github.com/NullifidianSF/insurgency_public)!

## Features

- **Per-Class Loadout Saving**: Each class template has its own saved loadout
- **Automatic Loading**: Saved loadouts automatically apply when selecting a class
- **Auto-Save on Disconnect**: Current loadout is automatically saved when disconnecting or changing classes
- **PostgreSQL Backend**: Simple, efficient database schema with semicolon-separated IDs
- **Rate Limiting**: Built-in abuse prevention with configurable cooldowns
- **Entity Inspection**: Direct reading from game entities - no theater files required
- **Configurable Messages**: All user-facing messages customizable via ConVars

## Requirements

- SourceMod 1.10 or higher
- PostgreSQL database
- Insurgency (2014) dedicated server
- `morecolors.inc` include file (included in repository)

## Installation

### 1. Database Setup

Create a PostgreSQL database for the plugin (e.g., `insurgency_loadouts`):

```bash
createdb insurgency_loadouts
```

Run the schema creation script:

```bash
psql -d insurgency_loadouts -f schema.sql
```

### 2. Database Configuration

Add database connection details to `addons/sourcemod/configs/databases.cfg`:

```
"Databases"
{
    "loadoutsaver"
    {
        "driver"    "pgsql"
        "host"      "localhost"
        "database"  "insurgency_loadouts"
        "user"      "your_db_user"
        "pass"      "your_db_password"
        "port"      "5432"
    }
}
```

### 3. Plugin Installation

1. Copy `LoadoutSaver.sp` to `addons/sourcemod/scripting/`
2. Copy `morecolors.inc` to `addons/sourcemod/scripting/include/`
3. Compile the plugin:
   ```bash
   cd addons/sourcemod/scripting
   ./spcomp LoadoutSaver.sp
   ```
4. Copy the compiled `LoadoutSaver.smx` to `addons/sourcemod/plugins/`
5. Restart the server or load the plugin:
   ```
   sm plugins load LoadoutSaver
   ```

## Usage

### Player Commands

| Command    | Description                                    | Cooldown  |
| ---------- | ---------------------------------------------- | --------- |
| `!savelo`  | Save your current loadout for the active class | 3 seconds |
| `!clearlo` | Clear your saved loadout for the active class  | 3 seconds |
| `!loadlo`  | Manually load your saved loadout               | 100ms     |

### How It Works

1. **Join Server**: Player connects and their `last_seen_at` timestamp is updated
2. **Select Class**: Player picks a class (e.g., `template_rifleman_security_coop`)
3. **Auto-Load**: If a saved loadout exists for this class, it's automatically applied
4. **Equip Weapons**: Player customizes their loadout in-game
5. **Save**: Player types `!savelo` to save their current loadout
6. **Reconnect**: When the player rejoins and selects the same class, their loadout is restored

### Auto-Save Behavior

The plugin automatically saves your loadout in these situations:

- **Changing Classes**: When you switch to a different class
- **Disconnecting**: When you leave the server
- **Map Change**: When the map changes (triggers disconnect)
- **Plugin Unload**: When the plugin is reloaded/unloaded

Auto-saved loadouts are marked with `is_auto_saved = TRUE` in the database. These can be overwritten by:
- Another auto-save (class change/disconnect)
- A manual save using `!savelo` (changes `is_auto_saved` to `FALSE`)

Manual saves (`!savelo`) are never auto-overwritten - you must explicitly save again to update them.

## Configuration

The plugin creates a config file at `cfg/sourcemod/plugin.loadoutsaver.cfg` on first run.

### ConVars

| ConVar                       | Default                                                                | Description                            |
| ---------------------------- | ---------------------------------------------------------------------- | -------------------------------------- |
| `sm_loadoutsaver_version`    | `1.0.0`                                                                | Plugin version (read-only)             |
| `sm_loadout_msg_saved`       | `{olivedrab}[Loadout]{default} Loadout saved successfully!`            | Message shown when loadout is saved    |
| `sm_loadout_msg_cleared`     | `{olivedrab}[Loadout]{default} Loadout cleared!`                       | Message shown when loadout is cleared  |
| `sm_loadout_msg_loaded`      | `{olivedrab}[Loadout]{default} Loadout loaded successfully!`           | Message shown when loadout is loaded   |
| `sm_loadout_msg_failed`      | `{red}[Loadout]{default} Failed to process loadout.`                   | Message shown when operation fails     |
| `sm_loadout_msg_ratelimit`   | `{red}[Loadout]{default} Please wait before using this command again.` | Message shown when rate limited        |
| `sm_loadout_msg_equipfailed` | `{red}[Loadout]{default} Failed to equip: {1}`                         | Message shown when item fails to equip |

Messages support color tags from the `morecolors` library. See [Color Tags](#color-tags) below.

### Example Configuration

```
// Custom messages
sm_loadout_msg_saved "{green}[✓]{default} Your loadout has been saved!"
sm_loadout_msg_cleared "{red}[✗]{default} Loadout deleted."
sm_loadout_msg_loaded "{blue}[i]{default} Loadout restored."
```

## Database Schema

The plugin uses a simple PostgreSQL database schema with semicolon-separated IDs:

### Table Structure

**loadouts** table:
- `steam_id` (VARCHAR(32)): Player's Steam ID
- `class_template` (VARCHAR(128)): Class template name
- `item_type` (VARCHAR(16)): Equipment type ('gear', 'primary', 'secondary', 'explosive')
- `itemid` (TEXT): Semicolon-separated list of theater IDs
- `is_auto_saved` (BOOLEAN): Whether this was auto-saved or manually saved
- `created_at` (TIMESTAMP): Initial creation timestamp
- `updated_at` (TIMESTAMP): Last update timestamp
- `last_seen_at` (TIMESTAMP): Last time player was seen
- `update_count` (INTEGER): Number of times loadout was updated
- Primary Key: `(steam_id, class_template, item_type)`

### Storage Format

Each equipment type is stored as a semicolon-separated string of theater IDs:

- **gear**: `39;47;52` (armor ID; head ID; vest ID; etc.)
- **primary**: `5;12;13;14` (weapon ID; upgrade1 ID; upgrade2 ID; etc.)
- **secondary**: `8;15` (weapon ID; upgrade1 ID; etc.)
- **explosive**: `20;21` (weapon ID; upgrade1 ID; etc.)

### Schema Benefits

- **Simplicity**: Easy to read and debug - just semicolon-separated numbers
- **Performance**: Indexed for fast lookups with minimal overhead
- **Compatibility**: Works with any theater configuration automatically
- **Efficiency**: No complex JSON parsing required
- **Flexibility**: Easy to manually edit or inspect database contents

### Example Data Flow

When a player saves a loadout for `template_rifleman_security_coop`:

```sql
-- Four rows are inserted/updated (one per equipment type)
INSERT INTO loadouts (steam_id, class_template, item_type, itemid, is_auto_saved)
VALUES 
  ('STEAM_0:1:12345678', 'template_rifleman_security_coop', 'gear', '39;47', FALSE),
  ('STEAM_0:1:12345678', 'template_rifleman_security_coop', 'primary', '5;12;13', FALSE),
  ('STEAM_0:1:12345678', 'template_rifleman_security_coop', 'secondary', '8;15', FALSE),
  ('STEAM_0:1:12345678', 'template_rifleman_security_coop', 'explosive', '20', FALSE)
ON CONFLICT (steam_id, class_template, item_type) DO UPDATE
SET itemid = EXCLUDED.itemid, is_auto_saved = EXCLUDED.is_auto_saved, updated_at = CURRENT_TIMESTAMP;
```

When loading, the plugin:
1. Queries all 4 rows for the player's steam_id and class_template
2. Splits each `itemid` string by semicolons using `ExplodeString()`
3. Executes buy commands in order:
   - `inventory_buy_gear 39`
   - `inventory_buy_gear 47`
   - `inventory_buy_weapon 5` (primary weapon)
   - `inventory_buy_upgrade 1 12` (primary upgrade #1)
   - `inventory_buy_upgrade 1 13` (primary upgrade #2)
   - `inventory_buy_weapon 8` (secondary weapon)
   - `inventory_buy_upgrade 2 15` (secondary upgrade #1)
   - `inventory_buy_weapon 20` (explosive weapon)

## Entity Inspection

The plugin uses Insurgency's entity system to directly read loadout data:

### How It Works

1. On save, the plugin reads directly from player entities:
   - **Gear**: Read from `m_EquippedGear` netprop (6 slots)
   - **Weapons**: Read from weapon slots 0-3 (primary, secondary, melee, explosive)
   - **Weapon IDs**: Read from `m_hWeaponDefinitionHandle` netprop
   - **Upgrades**: Read from `m_upgradeSlots` netprop (8 slots per weapon)

2. IDs are stored as semicolon-separated strings in the database

3. On load, the plugin executes buy commands in sequence:
   - `inventory_sell_all` (clear current loadout)
   - `inventory_buy_gear <id>` for each gear item
   - `inventory_buy_weapon <id>` for each weapon
   - `inventory_buy_upgrade <weapon_num> <id>` for each upgrade

### Benefits

- **No Theater Files Required**: Reads IDs directly from entities
- **Always Accurate**: Gets exact IDs the game is using
- **Theater Independent**: Works with any theater configuration
- **Automatic**: No manual configuration or maintenance needed

## Limitations

### Current Limitations

1. **Melee Weapons**: Melee weapons (slot 2) are not currently tracked
   - **Reason**: Most classes use default knife, saving is not typically needed
   - **Impact**: Players must manually select melee weapon after loading

2. **Theater-Specific IDs**: IDs are specific to the current theater configuration
   - **Impact**: If theater changes, saved IDs may refer to different items
   - **Workaround**: Players should re-save loadouts after theater changes

3. **Supply Point Validation**: Only validates on save, not on load
   - **Impact**: Loadouts may cost more than starting supply points after balance changes
   - **Workaround**: Plugin will attempt to buy as much as possible with available points

## Troubleshooting

### Database Connection Fails

**Problem**: Plugin logs `Failed to connect to database`

**Solutions**:
1. Verify database credentials in `databases.cfg`
2. Ensure PostgreSQL is running: `systemctl status postgresql`
3. Check PostgreSQL logs for connection errors
4. Verify firewall allows connections on port 5432
5. Check PostgreSQL `pg_hba.conf` for authentication settings

### Loadout Not Loading

**Problem**: Saved loadout doesn't apply when selecting class

**Solutions**:
1. Verify loadout exists in database: `SELECT * FROM loadouts WHERE steam_id = 'YOUR_STEAM_ID'`
2. Check server logs for errors during load
3. Ensure player has supply points for at least some items
4. Try manually loading: `!loadlo`
5. Re-save the loadout to ensure it's current

### Rate Limit Messages

**Problem**: `Please wait before using this command again`

**Solutions**:
- Wait 3 seconds between `!savelo` and `!clearlo` commands
- Wait 100ms between `!loadlo` commands
- This is intentional abuse prevention

### Items Not Equipping

**Problem**: Some items from saved loadout don't equip

**Possible Causes**:
1. Insufficient supply points (player can't afford all items)
2. Class restrictions (item not allowed for this class)
3. Theater configuration changed (IDs may refer to different items)
4. Item removed from theater

**Solutions**:
- Check available supply points in-game
- Verify class can use the equipment
- Re-save loadout if theater has changed
- Check class `allowed_items` in theater files (if modified)

## Color Tags

Messages support the following color tags (via `morecolors.inc`):

| Tag           | Color         | Example                |
| ------------- | ------------- | ---------------------- |
| `{default}`   | White/Default | `{default}Normal text` |
| `{teamcolor}` | Team color    | `{teamcolor}Team text` |
| `{red}`       | Red           | `{red}Error!`          |
| `{green}`     | Green         | `{green}Success!`      |
| `{blue}`      | Blue          | `{blue}Info`           |
| `{olivedrab}` | Olive green   | `{olivedrab}[Loadout]` |
| `{orange}`    | Orange        | `{orange}Warning`      |

See `morecolors.inc` for full color list.

## Developer Information

### Building from Source

```bash
cd addons/sourcemod/scripting
./spcomp LoadoutSaver.sp -o../plugins/LoadoutSaver.smx
```

### Database Queries

View active loadouts:
```sql
SELECT steam_id, class_template, item_type, itemid, updated_at 
FROM loadouts 
ORDER BY updated_at DESC;
```

View loadout details for a player:
```sql
SELECT * FROM loadouts 
WHERE steam_id = 'STEAM_0:1:12345678'
ORDER BY class_template, item_type;
```

Count loadouts per player:
```sql
SELECT steam_id, COUNT(DISTINCT class_template) as class_count 
FROM loadouts 
GROUP BY steam_id 
ORDER BY class_count DESC;
```

Delete old loadouts (not seen in 30 days):
```sql
DELETE FROM loadouts 
WHERE last_seen_at < NOW() - INTERVAL '30 days';
```

### Debugging

Enable debug logging in SourceMod:
```
sm_debuglog on
```

Check plugin status:
```
sm plugins info LoadoutSaver
```

Reload plugin:
```
sm plugins reload LoadoutSaver
```
