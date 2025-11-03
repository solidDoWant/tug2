# FireSupport Enhanced - Configuration Documentation

## Console Variables (CVars)

These are set in `cfg/sourcemod/plugin.firesupport.cfg` or via server console/config files.

| CVar                           | Type    | Default      | Description                                                                                                                             |
| ------------------------------ | ------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------- |
| `sm_firesupport_class`         | String  | `""` (empty) | Player class template that can call fire support. If empty, all classes can use fire support. Example: `"template_recon_security_coop"` |
| `sm_firesupport_enable_cmd`    | Boolean | `0`          | Enable/disable the `sm_firesupport_call` console command. `0` = disabled, `1` = enabled                                                 |
| `sm_firesupport_enable_weapon` | Boolean | `1`          | Enable/disable weapon-based fire support triggers. `0` = disabled, `1` = enabled                                                        |

### CVar Usage Examples

```
// Allow only recon class to use fire support
sm_firesupport_class "template_recon_security_coop"

// Allow all classes to use fire support
sm_firesupport_class ""

// Enable both weapon triggers and console command
sm_firesupport_enable_weapon 1
sm_firesupport_enable_cmd 1

// Weapon triggers only (no console command)
sm_firesupport_enable_weapon 1
sm_firesupport_enable_cmd 0
```

---

## Configuration File

Located at: `addons/sourcemod/configs/firesupport.cfg`

The configuration file uses KeyValues format and defines all fire support types available on the server.

### File Structure

```
"FireSupport"
{
    "support_type_name"
    {
        // General settings
        "weapon"              "weapon_identifier"
        "spread"              "600.0"
        "shells"              "15"
        "delay"               "8.0"
        "duration"            "20.0"
        "jitter"              "0.3"
        "projectile"          "rocket_rpg7"
        
        // Audio
        "throw_sound"         "sound/path.wav"
        "success_sound"       "sound/path.wav"
        "fail_sound"          "sound/path.wav"
        
        // Messages
        "success_message"     "[Fire Support] Message here"
        "fail_message"        "[Fire Support] Message here"
        "projectile_message"  "[Fire Support] Message here"
        
        // Team-specific limits
        "security_count"      "5"
        "security_delay"      "0.0"
        "insurgent_count"     "0"
        "insurgent_delay"     "120.0"
    }
}
```

### Configuration Fields

#### General Settings

| Field        | Type    | Required | Description                                                                                                           | Example                                                              |
| ------------ | ------- | -------- | --------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `weapon`     | String  | **Yes**  | Weapon identifier to trigger this fire support. Partial match supported.                                              | `"m18_us"`, `"p2a1"`, `"m18_ins"`                                    |
| `spread`     | Float   | No       | Maximum radius in units for shell dispersion. Default: `800.0`                                                        | `600.0` for tight spread, `1000.0` for wide spread                   |
| `shells`     | Integer | No       | Number of shells/explosions in the strike. Default: `20`                                                              | `15` for light strike, `30` for heavy barrage                        |
| `delay`      | Float   | No       | Delay in seconds before first shell lands (warning time). Default: `10.0`                                             | `5.0` for fast strike, `15.0` for slow strike                        |
| `duration`   | Float   | No       | Total time in seconds for all shells to land. Default: `20.0`                                                         | `10.0` for rapid barrage, `30.0` for sustained strike                |
| `jitter`     | Float   | No       | Random timing variance between shells (0.0 to 1.0). `0.0` = no variance, `1.0` = up to ±100% variance. Default: `0.0` | `0.3` for realistic variation, `0.0` for precise timing              |
| `projectile` | String  | No       | Projectile entity to spawn. Default: `"rocket_rpg7"`                                                                  | `"rocket_rpg7"`, `"rocket_at4"`, `"rocket_m72"`, `"grenade_molotov"` |

**Duration and Timing Notes:**
- The plugin calculates time between shells as: `duration / (shells - 1)`
- Example: 20 second duration with 10 shells = ~2.22 seconds between each shell
- Jitter adds randomness: with jitter of 0.3, each interval varies by ±30%
- First shell lands at `delay` seconds, last shell lands at approximately `delay + duration` seconds

#### Audio Settings

All sound paths are relative to the game's sound directory. Leave empty (`""`) to disable.

| Field           | Type   | Required | Description                                    | When Played                                              |
| --------------- | ------ | -------- | ---------------------------------------------- | -------------------------------------------------------- |
| `throw_sound`   | String | No       | Sound when weapon is thrown/fired              | Always when trigger weapon is used                       |
| `success_sound` | String | No       | Sound when fire support is successfully called | When fire support validates and starts                   |
| `fail_sound`    | String | No       | Sound when fire support fails                  | When target location is invalid (indoors, no sky access) |

**Sound Examples:**
- `"weapons/smokegrenade/smoke_emit.wav"` - Smoke grenade sound
- `"weapons/m203/m203_reload_clipin.wav"` - M203 reload click
- `"weapons/c4/c4_beep1.wav"` - C4 beep
- `"buttons/button11.wav"` - Error beep

#### Projectile Types

The `projectile` field determines what entity is spawned when shells land. Common projectile types in Insurgency:

| Projectile Entity | Description            | Damage Type                         |
| ----------------- | ---------------------- | ----------------------------------- |
| `rocket_rpg7`     | RPG-7 rocket (default) | High explosive, large blast radius  |
| `rocket_at4`      | AT4 rocket             | High explosive, medium blast radius |
| `rocket_m72`      | M72 LAW rocket         | High explosive, medium blast radius |
| `grenade_molotov` | Molotov cocktail       | Fire damage, area denial            |

**Note:** Projectile availability depends on your server's game mode and configuration. Test projectiles to ensure they work as expected.

#### Message Settings

Messages are displayed to the entire team in team chat. Leave empty (`""`) to disable.

| Field                | Type   | Required | Description                                             | When Shown                                       |
| -------------------- | ------ | -------- | ------------------------------------------------------- | ------------------------------------------------ |
| `success_message`    | String | No       | Chat message on successful fire support call            | When fire support validates and starts           |
| `fail_message`       | String | No       | Chat message on failed fire support call                | When target location is invalid                  |
| `projectile_message` | String | No       | Chat message displayed when each projectile is launched | When each individual shell/projectile is spawned |

**Note:** The `projectile_message` is displayed once for each shell, so with `shells` set to 20, the message will appear 20 times throughout the strike. Use this sparingly or leave empty to avoid chat spam.

#### Team-Specific Limits

These settings control usage limits and cooldowns independently for each team.

| Field             | Type    | Required | Description                                                                              |
| ----------------- | ------- | -------- | ---------------------------------------------------------------------------------------- |
| `security_count`  | Integer | No       | Maximum uses per round for Security team. `0` = unlimited. Default: `0`                  |
| `security_delay`  | Float   | No       | Cooldown in seconds between uses for Security team. `0.0` = no cooldown. Default: `0.0`  |
| `insurgent_count` | Integer | No       | Maximum uses per round for Insurgent team. `0` = unlimited. Default: `0`                 |
| `insurgent_delay` | Float   | No       | Cooldown in seconds between uses for Insurgent team. `0.0` = no cooldown. Default: `0.0` |

**Important Notes:**
- Counts and delays are **per support type**, not global
- Each weapon type has independent tracking
- If a team obtains a weapon normally restricted to the other team, they use that weapon's settings for their team

#### Smoke and Effects Settings

| Field         | Type    | Required | Description                                                                              |
| ------------- | ------- | -------- | ---------------------------------------------------------------------------------------- |
| `spawn_smoke` | Integer | No       | Whether to spawn smoke at impact points. `0` = no smoke, `1` = spawn smoke. Default: `0` |
| `smoke_type`  | String  | No       | Type of smoke entity to spawn. Default: `"grenade_m18"`                                  |

**Smoke Type Notes:**
- `"grenade_m18"` - Real M18 smoke grenade entity (blocks bot vision, visible smoke)
- Smoke entities are tracked and automatically cleaned up on round start

- Different fire support types can have different delays (e.g., mortars might be slower than artillery)
- Set to `0.0` for instant activation when grenade is thrown

---

## Complete Configuration Examples

### Example 1: Balanced Teams (Default Config)

```
"FireSupport"
{
    // Security Forces - Limited uses, no cooldown (aggressive playstyle)
    "security_smoke"
    {
        "weapon"              "m18_us"
        "spread"              "600.0"
        "shells"              "15"
        "delay"               "8.0"
        "duration"            "20.0"
        "jitter"              "0.3"
        "projectile"          "rocket_rpg7"
        "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
        "success_sound"       "weapons/m203/m203_reload_clipin.wav"
        "fail_sound"          "buttons/button11.wav"
        "success_message"     "[Fire Support] Artillery strike inbound on your position!"
        "fail_message"        "[Fire Support] Unable to call artillery - invalid target location!"
        "projectile_message"  ""
        "security_count"      "5"       // 5 uses per round
        "security_delay"      "0.0"     // No cooldown
        "insurgent_count"     "0"       // Unlimited (can't normally get this weapon)
        "insurgent_delay"     "0.0"
    }
    
    // Insurgent Forces - Unlimited uses, long cooldown (sustained pressure)
    "insurgent_smoke"
    {
        "weapon"              "m18_ins"
        "spread"              "700.0"
        "shells"              "18"
        "delay"               "10.0"
        "duration"            "25.0"
        "jitter"              "0.3"
        "projectile"          "rocket_rpg7"
        "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
        "success_sound"       "weapons/c4/c4_beep1.wav"
        "fail_sound"          "buttons/button11.wav"
        "success_message"     "[Fire Support] Mortar strike authorized!"
        "fail_message"        "[Fire Support] Cannot request mortar support - no line of sight!"
        "projectile_message"  ""
        "security_count"      "0"       // Unlimited (can't normally get this weapon)
        "security_delay"      "0.0"
        "insurgent_count"     "0"       // Unlimited uses
        "insurgent_delay"     "120.0"   // 2 minute cooldown
    }
}
```

### Example 2: Multiple Weapons Per Team with Different Projectiles

```
"FireSupport"
{
    // Security - Standard Artillery (RPG-7 rockets)
    "security_artillery"
    {
        "weapon"              "m18_us"
        "spread"              "800.0"
        "shells"              "20"
        "delay"               "10.0"
        "duration"            "30.0"
        "jitter"              "0.4"
        "projectile"          "rocket_rpg7"
        "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
        "success_sound"       "weapons/m203/m203_reload_clipin.wav"
        "fail_sound"          "buttons/button11.wav"
        "success_message"     "[Fire Support] Artillery strike inbound!"
        "fail_message"        "[Fire Support] Cannot call artillery!"
        "projectile_message"  ""
        "security_count"      "3"
        "security_delay"      "60.0"
        "insurgent_count"     "0"
        "insurgent_delay"     "0.0"
    }
    
    // Security - Precision Strike (AT4 rockets, tighter spread)
    "security_precision"
    {
        "weapon"              "p2a1"
        "spread"              "300.0"
        "shells"              "8"
        "delay"               "5.0"
        "duration"            "10.0"
        "jitter"              "0.2"
        "projectile"          "rocket_at4"
        "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
        "success_sound"       "weapons/c4/c4_beep1.wav"
        "fail_sound"          "buttons/button11.wav"
        "success_message"     "[Fire Support] Precision strike authorized!"
        "fail_message"        "[Fire Support] Cannot call precision strike!"
        "projectile_message"  "[Fire Support] Impact!"
        "security_count"      "1"       // Only 1 precision strike
        "security_delay"      "0.0"     // But no cooldown
        "insurgent_count"     "0"
        "insurgent_delay"     "0.0"
    }
    
    // Insurgent - Mortar (Standard RPG-7)
    "insurgent_mortar"
    {
        "weapon"              "m18_ins"
        "spread"              "700.0"
        "shells"              "15"
        "delay"               "10.0"
        "duration"            "20.0"
        "jitter"              "0.3"
        "projectile"          "rocket_rpg7"
        "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
        "success_sound"       "weapons/c4/c4_beep1.wav"
        "fail_sound"          "buttons/button11.wav"
        "success_message"     "[Fire Support] Mortar strike inbound!"
        "fail_message"        "[Fire Support] Cannot call mortar strike!"
        "projectile_message"  ""
        "security_count"      "0"
        "security_delay"      "0.0"
        "insurgent_count"     "0"       // Unlimited
        "insurgent_delay"     "90.0"    // 90 second cooldown
    }
    
    // Insurgent - Incendiary Strike (Molotov cocktails)
    "insurgent_incendiary"
    {
        "weapon"              "anm14"
        "spread"              "500.0"
        "shells"              "12"
        "delay"               "8.0"
        "duration"            "15.0"
        "jitter"              "0.5"
        "projectile"          "grenade_molotov"
        "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
        "success_sound"       "weapons/molotov/molotov_detonate.wav"
        "fail_sound"          "buttons/button11.wav"
        "success_message"     "[Fire Support] Incendiary strike incoming!"
        "fail_message"        "[Fire Support] Cannot call incendiary strike!"
        "projectile_message"  ""
        "security_count"      "0"
        "security_delay"      "0.0"
        "insurgent_count"     "2"       // 2 uses
        "insurgent_delay"     "60.0"    // 60 second cooldown
    }
}
```

### Example 3: Symmetric Teams

```
"FireSupport"
{
    "us_strike"
    {
        "weapon"              "m18_us"
        "spread"              "650.0"
        "shells"              "15"
        "delay"               "8.0"
        "duration"            "20.0"
        "jitter"              "0.3"
        "projectile"          "rocket_rpg7"
        "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
        "success_sound"       "weapons/m203/m203_reload_clipin.wav"
        "fail_sound"          "buttons/button11.wav"
        "success_message"     "[Fire Support] Strike inbound!"
        "fail_message"        "[Fire Support] Cannot call strike!"
        "projectile_message"  ""
        "security_count"      "5"       // Same limits
        "security_delay"      "60.0"    // Same cooldown
        "insurgent_count"     "5"       // Same limits
        "insurgent_delay"     "60.0"    // Same cooldown
    }
    
    "ins_strike"
    {
        "weapon"              "m18_ins"
        "spread"              "650.0"
        "shells"              "15"
        "delay"               "8.0"
        "duration"            "20.0"
        "jitter"              "0.3"
        "projectile"          "rocket_rpg7"
        "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
        "success_sound"       "weapons/c4/c4_beep1.wav"
        "fail_sound"          "buttons/button11.wav"
        "success_message"     "[Fire Support] Strike inbound!"
        "fail_message"        "[Fire Support] Cannot call strike!"
        "projectile_message"  ""
        "security_count"      "5"       // Same limits
        "security_delay"      "60.0"    // Same cooldown
        "insurgent_count"     "5"       // Same limits
        "insurgent_delay"     "60.0"    // Same cooldown
    }
}
```

### Example 4: Unrestricted Mode

```
"FireSupport"
{
    "artillery"
    {
        "weapon"              "m18"      // Matches both m18_us and m18_ins
        "spread"              "700.0"
        "shells"              "20"
        "delay"               "10.0"
        "duration"            "25.0"
        "jitter"              "0.2"
        "projectile"          "rocket_rpg7"
        "throw_sound"         ""         // No sounds
        "success_sound"       ""
        "fail_sound"          ""
        "success_message"     ""         // No messages
        "fail_message"        ""
        "projectile_message"  ""         // No messages
        "security_count"      "0"        // Unlimited
        "security_delay"      "0.0"      // No cooldown
        "insurgent_count"     "0"        // Unlimited
        "insurgent_delay"     "0.0"      // No cooldown
    }
}
```

### Example 5: Different Projectile Types

```
"FireSupport"
{
    // Heavy barrage with RPG-7 rockets
    "heavy_artillery"
    {
        "weapon"              "m18_us"
        "projectile"          "rocket_rpg7"
        "spread"              "900.0"
        "shells"              "25"
        "duration"            "40.0"
        "jitter"              "0.5"
        "projectile_message"  ""
        // ... other settings ...
    }
    
    // Precise strike with AT4 rockets
    "at4_strike"
    {
        "weapon"              "p2a1"
        "projectile"          "rocket_at4"
        "spread"              "400.0"
        "shells"              "10"
        "duration"            "12.0"
        "jitter"              "0.2"
        "projectile_message"  ""
        // ... other settings ...
    }
    
    // Incendiary attack with M72 LAW
    "law_strike"
    {
        "weapon"              "m67"
        "projectile"          "rocket_m72"
        "spread"              "600.0"
        "shells"              "15"
        "duration"            "20.0"
        "jitter"              "0.3"
        "projectile_message"  ""
        // ... other settings ...
    }
    
    // Fire bombardment with Molotovs
    "molotov_barrage"
    {
        "weapon"              "anm14"
        "projectile"          "grenade_molotov"
        "spread"              "700.0"
        "shells"              "20"
        "duration"            "30.0"
        "jitter"              "0.6"
        "projectile_message"  ""
        // ... other settings ...
    }
}
```

---

## Admin Commands

| Command                  | Permission                | Description                                                                |
| ------------------------ | ------------------------- | -------------------------------------------------------------------------- |
| `sm_firesupport_call`    | Console                   | Call fire support at crosshair (if enabled via CVar)                       |
| `sm_firesupport_ad_call` | Admin                     | Debug command - call fire support at crosshair (bypasses all restrictions) |
| `sm_firesupport_reload`  | Config (`ADMFLAG_CONFIG`) | Reload configuration file without restarting server                        |

---

## Usage Tracking

### How Limits Work

1. **Per-team per-type tracking**: Each team has independent counters for each weapon type
2. **Round-based reset**: All counters reset at round start
3. **Independent cooldowns**: Each weapon type has its own cooldown timer per team

### Example Scenario

**Configuration:**
- Security m18_us: 5 uses, 0s cooldown
- Security p2a1: 1 use, 0s cooldown
- Insurgent m18_ins: unlimited, 120s cooldown

**Gameplay:**
1. Security throws m18_us → Success, 4 m18_us remaining
2. Security throws m18_us → Success, 3 m18_us remaining
3. Security throws p2a1 → Success, 0 p2a1 remaining
4. Security throws p2a1 → Fails (out of uses)
5. Security throws m18_us → Success, 2 m18_us remaining (p2a1 doesn't affect m18_us)
6. Insurgent throws m18_ins → Success, on 120s cooldown
7. Insurgent throws m18_ins → Fails (on cooldown)
8. After 120s, Insurgent can use m18_ins again

---

## Visual Effects

When fire support is called successfully:
- **Red vertical beam** from ground to sky
- **Red shrinking ring** at ground level (starts at 500 units, shrinks to 0)
- Both effects last for the `delay` duration
- After delay expires, shells begin landing in the target area

---

## Troubleshooting

### Fire support won't trigger

**Check:**
1. Is `sm_firesupport_enable_weapon` set to `1`?
2. Is the player's class allowed (check `sm_firesupport_class`)?
3. Does the weapon identifier in config match the weapon being used?
4. Does the team have remaining uses? (Check console for "X use(s) remaining" messages)
5. Is the fire support on cooldown?
6. Is the target location valid (outdoors with sky access)?

### Sounds not playing

**Check:**
1. Are sound paths correct and files exist?
2. Are sounds precached on map start? (Plugin handles this automatically)
3. Check server console for precache errors

### Config not loading

**Check:**
1. File exists at `addons/sourcemod/configs/firesupport.cfg`
2. KeyValues syntax is correct (matching quotes and braces)
3. Check server console for error messages
4. Use `sm_firesupport_reload` to reload after changes

### Weapon not triggering correct support type

The plugin uses `StrContains()` for weapon matching, which does partial matches:
- `"m18"` matches both `weapon_m18_us` and `weapon_m18_ins`
- `"m18_us"` only matches `weapon_m18_us`
- Be specific with weapon identifiers to avoid conflicts

---

## Smoke on Impact Feature

### Overview

The plugin can automatically spawn smoke grenades at the impact location of each projectile. This creates a smokescreen effect as shells land, providing visual cover and tactical opportunities.

### Configuration Fields

| Field         | Type    | Required | Description                                                                | Default Value               |
| ------------- | ------- | -------- | -------------------------------------------------------------------------- | --------------------------- |
| `spawn_smoke` | Integer | No       | Whether to spawn smoke on impact. `0` = disabled, `1` = enabled            | `0` (disabled)              |
| `smoke_type`  | String  | No       | Entity class name of smoke grenade to spawn. Only used if smoke is enabled | `"smokegrenade_projectile"` |

### How It Works

1. **Projectile Type Check**: Only works with **rocket projectiles** (entities starting with `"rocket_"`). Grenades and other projectiles are not supported.
2. **Impact Detection**: Uses SDKHooks to detect when a rocket touches/impacts any surface
3. **Smoke Spawning**: Creates a smoke grenade entity at the exact impact location
4. **Smoke Behavior**: The spawned smoke behaves identically to a thrown smoke grenade (duration, spread, opacity, etc.)

### Example Configurations

#### Artillery with Smoke Cover

```
"security_arty_smoke"
{
    "weapon"              "m18_us"
    "spread"              "800.0"
    "shells"              "30"
    "delay"               "8.0"
    "duration"            "25.0"
    "jitter"              "0.3"
    "projectile"          "rocket_rpg7"
    "spawn_smoke"         "1"                          // Enable smoke on impact
    "smoke_type"          "smokegrenade_projectile"    // Standard smoke grenade
    // ... other fields ...
}
```

#### No Smoke (Default Behavior)

```
"insurgent_strike"
{
    "weapon"              "m18_ins"
    "projectile"          "rocket_rpg7"
    "spawn_smoke"         "0"     // Disabled - no smoke spawns
    // ... other fields ...
}
```

### Smoke Types

| Smoke Entity  | Description                       | Visual Effect                                                                                 |
| ------------- | --------------------------------- | --------------------------------------------------------------------------------------------- |
| `grenade_m18` | Physical M18 smoke grenade entity | Actual smoke grenade that detonates automatically, invisible grenade model, blocks bot vision |

**Note:** The smoke type must be a valid entity that can be spawned with `CreateEntityByName()`. Using invalid entity names will log an error and skip smoke spawning.

### Important Limitations

1. **Rockets Only**: Smoke spawning only works with rocket projectiles (`rocket_rpg7`, `rocket_at4`, etc.)
   - Molotovs, grenades, and other projectiles are **not supported**
   - The plugin automatically checks if the projectile starts with `"rocket_"` before hooking

2. **Performance Consideration**: Spawning smoke on every shell impact can be intensive
   - With 30+ shells, you'll get 30+ smoke grenades
   - May cause performance issues on low-end servers
   - Consider reducing `shells` count when using smoke

3. **Visual Obscurity**: Heavy smoke coverage can significantly reduce visibility
   - Be mindful of game balance
   - Too much smoke may negatively impact gameplay

### Troubleshooting Smoke

#### Smoke not appearing

**Check:**
1. Is `spawn_smoke` set to `1`?
2. Is the projectile type a rocket (starts with `"rocket_"`)?
3. Check server console for entity creation errors
4. Verify `smoke_type` is a valid entity class

#### Smoke appears but behaves oddly

**Check:**
1. Is `smoke_type` set to a smoke entity class?
2. Some custom workshop smoke may have different behaviors
3. Try using the default `"smokegrenade_projectile"`

#### Performance issues with smoke

**Solutions:**
1. Reduce the number of `shells` in the strike
2. Increase `duration` to spread impacts over more time
3. Disable smoke for high-shell-count strikes

**Note on Entity Tracking:**
The plugin tracks active rockets and smoke grenades in ArrayLists to enable cleanup on round start. Entity references accumulate during a round but are automatically cleared when a new round begins. For typical gameplay (80 shells × 2 entities = 160 references = ~640 bytes), this memory usage is negligible. The alternative of hooking `OnEntityDestroyed` globally would add ~1000 callbacks per second with diminishing returns. Current approach is optimal for normal round durations.

### Example: Smoke Barrage Setup

This configuration creates a devastating smoke screen:

```
"smoke_barrage"
{
    "weapon"              "m18_us"
    "spread"              "1000.0"    // Wide area
    "shells"              "40"        // Many shells
    "delay"               "5.0"       // Quick response
    "duration"            "30.0"      // Sustained over 30 seconds
    "jitter"              "0.4"       // High variation
    "projectile"          "rocket_rpg7"
    "spawn_smoke"         "1"         // Smoke on every impact
    "smoke_type"          "smokegrenade_projectile"
    "throw_sound"         "weapons/smokegrenade/smoke_emit.wav"
    "success_sound"       "weapons/m203/m203_reload_clipin.wav"
    "fail_sound"          "buttons/button11.wav"
    "success_message"     "[Fire Support] Smoke barrage inbound - area will be obscured!"
    "fail_message"        "[Fire Support] Cannot deploy smoke barrage here!"
    "projectile_message"  ""
    "security_count"      "2"         // Limited to 2 uses
    "security_delay"      "180.0"     // 3 minute cooldown
    "insurgent_count"     "0"
    "insurgent_delay"     "0.0"
}
```

This creates a 40-shell strike over 30 seconds, spawning smoke at each impact point, creating a massive smokescreen over a 1000-unit radius.
