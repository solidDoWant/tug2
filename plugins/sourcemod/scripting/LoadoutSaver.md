# Insurgency Loadout Saver Plugin

A SourceMod plugin for Insurgency (2014) that allows players to save and restore their loadouts per class.

Thanks [Bot Chris](https://github.com/santosoch/insurgency) and [Nullifidian](https://github.com/NullifidianSF/insurgency_public)!

## Features

- **Per-Class Loadout Saving**: Each class template has its own saved loadout
- **Named Loadouts**: Save a kit under a name and load it on any class, capped per player
- **Manual Save**: Players explicitly save loadouts with `!savelo` command
- **Automatic Loading**: Saved loadouts automatically apply when selecting a class
- **PostgreSQL Backend**: Simple, efficient single-row schema with semicolon-separated IDs
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
psql -d insurgency_loadouts -f loadout_saver.sql
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

| Command           | Description                                              | Cooldown  |
| ----------------- | -------------------------------------------------------- | --------- |
| `!savelo`         | Save your current loadout for the active class           | 3 seconds |
| `!clearlo`        | Clear your saved loadout for the active class            | None      |
| `!clearlo all`    | Clear your class loadouts for every class                | None      |
| `!loadlo`         | Manually load this class's saved loadout                 | 100ms     |
| `!savelo <name>`  | Save the current loadout under a name, usable on any class | 3 seconds |
| `!loadlo <name>`  | Load a named loadout, whatever class you are playing      | 100ms     |
| `!listlo`         | List your named loadouts and how many you have left       | None      |
| `!dello <name>`   | Delete one named loadout                                  | None      |
| `!dello all`      | Delete every named loadout                                | None      |

`!listlo` also answers to `!listloadouts`, `!loadouts`, `!lslo`, `!lsloadout` and `!lsloadouts`;
`!dello` also answers to `!delloadout`, `!deletelo` and `!deleteloadout`.

### Named Loadouts

A bare `!savelo` / `!loadlo` behaves exactly as it always has: one loadout per class, loaded
automatically when you spawn into that class. Adding a name switches to a separate set of loadouts
that are not tied to a class:

```
(as machine gunner)  !savelo cqb kit
(later, as medic)    !loadlo cqb kit
```

- Names may be up to 40 characters of letters, digits, spaces, dashes and underscores. Multi-word
  names work without quotes, and runs of spaces are collapsed so `cqb  kit` and `cqb kit` cannot
  become two loadouts that look identical in chat.
- A name that is blank or only whitespace is rejected rather than being treated as a bare
  `!savelo`, which would otherwise silently overwrite the class loadout instead.
- Names are matched case-insensitively, so `!loadlo CQB Kit` finds `cqb kit`. You cannot have two
  names that differ only in case.
- `all` is reserved, since `!dello all` uses it.
- Saving under a name you already have overwrites it, and that is allowed even at the cap.
- The cap (`sm_loadout_max_named`, default 15) applies only to named loadouts. Your per-class
  loadouts are unlimited and never count towards it. It is enforced twice: inside the plugin's
  insert statement, and again by a database trigger (see below).
- `!clearlo all` clears class loadouts only. Named loadouts are removed with `!dello all`.

#### What stops a named loadout smuggling class weapons?

Loading a named loadout on a different class does not bypass class restrictions. Every item is
applied with the same `inventory_buy_gear` / `inventory_buy_weapon` / `inventory_buy_upgrade`
commands the in-game buy menu issues, so the game validates each purchase against the current
class and the player's supply points exactly as it would for a manual buy. A medic loading a
machine gunner's kit does not receive the LMG; the buy is simply refused.

Because that guarantee lives in the game rather than in this plugin, a cross-class load is checked
afterwards rather than assumed: 0.5 seconds after applying, the weapons the player is actually
holding are compared against the ones the loadout asked for. Anything the game refused is reported
to the player ("N item(s) are not available to this class"), and the comparison is written to the
server log with the source class, the current class, and both item lists. If the game ever failed
to enforce a restriction, that log line is the evidence.

`sm_loadout_named_cross_class 0` disables cross-class loading entirely, confining each named
loadout to the class it was saved on, without otherwise removing the feature.

### How It Works

1. **Join Server**: Player connects and their `last_seen_at` timestamp is updated
2. **Select Class**: Player picks a class (e.g., `template_rifleman_security_coop`)
3. **Auto-Load**: If a saved loadout exists for this class, it's automatically applied
4. **Equip Weapons**: Player customizes their loadout in-game
5. **Manual Save**: Player types `!savelo` to save their current loadout
6. **Reconnect**: When the player rejoins and selects the same class, their loadout is restored

### Save Behavior

Loadouts are **only saved manually** using the `!savelo` command. This ensures:
- Players have full control over when loadouts are saved
- No accidental overwrites during gameplay
- Loadout represents exactly what the player wants, not a mid-game state

## Configuration

The plugin creates a config file at `cfg/sourcemod/plugin.loadoutsaver.cfg` on first run.

### ConVars

| ConVar                       | Default                                                              | Description                              |
| ---------------------------- | -------------------------------------------------------------------- | ---------------------------------------- |
| `sm_loadoutsaver_version`    | `2.0.0`                                                              | Plugin version (read-only)               |
| `sm_loadout_msg_saved`       | `{olivedrab}[Loadout]{default} Loadout saved!`                       | Message shown when loadout is saved      |
| `sm_loadout_msg_cleared`     | `{olivedrab}[Loadout]{default} Loadout cleared!`                     | Message shown when loadout is cleared    |
| `sm_loadout_msg_cleared_all` | `{olivedrab}[Loadout]{default} All class loadouts cleared! ...`      | Message shown when class loadouts cleared |
| `sm_loadout_msg_loaded`      | `{olivedrab}[Loadout]{default} Loadout loaded!`                      | Message shown when loadout is loaded     |
| `sm_loadout_msg_failed`      | `{red}[Loadout]{default} Failed to process loadout.`                 | Message shown when operation fails       |
| `sm_loadout_msg_supply`      | `{red}[Loadout]{default} Can't save loadout that costs more than...` | Message shown when loadout too expensive |
| `sm_loadout_save_cooldown`   | `3.0`                                                                | Cooldown for save command (seconds)      |
| `sm_loadout_load_cooldown`   | `0.1`                                                                | Cooldown for load command (seconds)      |
| `sm_loadout_max_named`       | `15`                                                                 | Named loadouts allowed per player        |
| `sm_loadout_named_cross_class` | `1`                                                                | Allow named loadouts to load on a different class than they were saved on |

Messages support color tags from the `morecolors` library. See [Color Tags](#color-tags) below.

### Example Configuration

```
// Custom messages
sm_loadout_msg_saved "{green}[✓]{default} Your loadout has been saved!"
sm_loadout_msg_cleared "{red}[✗]{default} Loadout deleted."
sm_loadout_msg_loaded "{blue}[i]{default} Loadout restored."
```

## Database Schema

The plugin uses a simple PostgreSQL database schema with one row per player/class combo:

### Table Structure

**loadouts** table:
- `steam_id` (VARCHAR(32)): Player's Steam ID
- `class_template` (VARCHAR(128)): Class template name. For a named loadout this records the class
  it was saved on, which is what the cross-class check compares against
- `name` (VARCHAR(64)): Loadout name, or NULL for a class loadout
- `gear` (TEXT): Semicolon-separated list of gear theater IDs
- `primary_weapon` (TEXT): Semicolon-separated list (weapon ID; upgrade IDs)
- `secondary_weapon` (TEXT): Semicolon-separated list (weapon ID; upgrade IDs)
- `explosive` (TEXT): Semicolon-separated list (weapon ID; upgrade IDs)
- `created_at` (TIMESTAMP): Initial creation timestamp
- `updated_at` (TIMESTAMP): Last update timestamp
- `last_seen_at` (TIMESTAMP): Last time player was seen
- `update_count` (INTEGER): Number of times loadout was updated

Uniqueness is enforced by two partial indexes rather than a primary key, because the two kinds of
row are unique on different things:

- `(steam_id, class_template) WHERE name IS NULL` - one class loadout per class, which is what the
  old `(steam_id, class_template)` primary key enforced
- `(steam_id, lower(name)) WHERE name IS NOT NULL` - one named loadout per name, case-insensitive

The migration in `loadout_saver.sql` adds the `name` column and drops the old primary key. Existing
rows get `name = NULL`, so every loadout saved before named loadouts existed stays a class loadout
and behaves identically.

### Cap Enforcement

The cap is enforced in two independent places:

1. **In the insert statement.** The plugin's named-save is a single `INSERT ... SELECT ... WHERE
   (count < cap OR name already exists) ON CONFLICT ... DO UPDATE`, so the check and the write
   cannot be separated by a concurrent save. A refused save writes no row, which the plugin
   detects from the affected row count and reports as "you already have N named loadouts".
2. **In the database.** `enforce_named_loadout_cap()` runs `BEFORE INSERT OR UPDATE` and raises
   `check_violation` if a player would exceed the cap. This is the backstop for anything that does
   not go through the plugin's statement - hand-written SQL, a future code change, a bug.

The trigger is deliberately careful about what does *not* consume a slot, or it would break normal
use: overwriting a name the player already owns is allowed even at the cap (a `BEFORE INSERT`
trigger fires before `ON CONFLICT` resolves, so the row being replaced is still present and would
otherwise be counted), and any update to a row that was already named passes straight through -
which covers the `last_seen_at` touch applied to all of a player's rows when they connect.

The cap value is hardcoded as `15` in the trigger. If you raise `sm_loadout_max_named` above that,
update the trigger to match, otherwise saves past 15 fail as a database error instead of a polite
chat message. (The plugin recognises that specific error and still shows the cap message, but the
save is refused either way.)

### Storage Format

Each equipment type is stored as a semicolon-separated string of theater IDs:

- **gear**: `39;47;52` (armor ID; head ID; vest ID; etc.)
- **primary_weapon**: `5;12;13;14` (weapon ID; upgrade1 ID; upgrade2 ID; etc.)
- **secondary_weapon**: `8;15` (weapon ID; upgrade1 ID; etc.)
- **explosive**: `20;21` (weapon ID; upgrade1 ID; etc.)

### Schema Benefits

- **Simplicity**: Easy to read and debug - just semicolon-separated numbers
- **Performance**: Single row per player/class, indexed for fast lookups
- **Compatibility**: Works with any theater configuration automatically
- **Efficiency**: No complex JSON parsing required
- **Flexibility**: Easy to manually edit or inspect database contents

### Example Data Flow

When a player saves a loadout for `template_rifleman_security_coop`:

```sql
-- Single row is inserted/updated
INSERT INTO loadouts (steam_id, class_template, gear, primary_weapon, secondary_weapon, explosive)
VALUES (
  'STEAM_0:1:12345678',
  'template_rifleman_security_coop',
  '39;47',      -- gear
  '5;12;13',    -- primary + upgrades
  '8;15',       -- secondary + upgrades
  '20'          -- explosive
)
ON CONFLICT (steam_id, class_template) DO UPDATE
SET gear = EXCLUDED.gear,
    primary_weapon = EXCLUDED.primary_weapon,
    secondary_weapon = EXCLUDED.secondary_weapon,
    explosive = EXCLUDED.explosive,
    updated_at = CURRENT_TIMESTAMP,
    update_count = loadouts.update_count + 1;
```

When loading, the plugin:
1. Queries the single row for the player's steam_id and class_template
2. Splits each column's string by semicolons using `ExplodeString()`
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
- Wait 3 seconds between `!savelo` commands
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
SELECT steam_id, class_template, updated_at 
FROM loadouts 
ORDER BY updated_at DESC;
```

View loadout details for a player:
```sql
SELECT * FROM loadouts 
WHERE steam_id = 'STEAM_0:1:12345678'
ORDER BY class_template;
```

Count loadouts per player:
```sql
SELECT steam_id, COUNT(*) as class_count 
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
