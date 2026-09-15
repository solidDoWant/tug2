# gg2_teamflash

**Status: rewritten 2026-09-15.** Side-loaded onto test and confirmed to load, resolve
`grenade_m84 = explosive id 10` off a live detonation, and run without errors. The report itself has
not been seen fire yet — that needs a player to actually flash a teammate. Prints the name of anyone
who flashbangs their own team to team chat. No cvars, no config.

Originally a vendored copy of Apple3.14159's [\[MAGA\] Teamflash](https://forums.alliedmods.net/showthread.php?p=2665681).
Pulled into this repo because it was reporting players as having thrown grenades that bots threw.

## The bug it was pulled in to fix

Players were being credited with blindings caused by bots. Two independent defects, either of which
alone would have been enough.

### 1. It was not watching flashbangs

```sourcepawn
#define FLASH_ID 2
...
if (event.GetInt("id") != FLASH_ID) return;
```

`grenade_detonate`'s `id` is the explosive's **theater definition id**, and that is nothing more
than its position in the merged explosives list. From `server_srv.so`:

```
CTheaterItemBaseDefinition<explosiveDefinition_t, int>::InitFromKV(KeyValues *kv)
    for each subkey:
        if (sub->GetInt("IsBase", 0) != 0) continue;   // base definitions get no id
        id = m_Dict.Find(name);                        // a redefined name keeps its id
        if (id < 0) m_Dict.Insert(name, ++m_nNextId);  // otherwise: 1-based counter, parse order

CBaseDetonator::EmitEvent(...)
    event->SetInt("id", this->m_nExplosivesDefinitionHandle);   // +0x4b8
```

So the constant is really "the second explosive the theater happens to declare". On a stock server
that *is* the flashbang — `scripts/theaters/default_weapon.theater` lists `grenade_m18` then
`grenade_m84` — so the constant was right where it was written. It is wrong on both of ours, and
differently wrong on each.

**Main** runs TUG's `theater_tug_39_medicbomber_12p_default` unmodified. Resolving its `#base` chain
out of `tug3.9_scripts_dir.vpk` gives 29 explosives:

| id | name | |
| --- | --- | --- |
| 1 | `grenade_m18` | |
| **2** | **`grenade_m18_impact`** | what the plugin was treating as a flashbang |
| **3** | **`grenade_m84`** | the actual flashbang |
| 4… | `grenade_m67`, `grenade_f1`, … | |

An impact smoke. Players throw those constantly, which is why the symptom showed up as often as it
did — every impact smoke was read as "this player just threw a flashbang".

**Test** runs our `theater_tug_nvg_default`, which `#base`s the above and prepends its own
`explosives` block. Measured live with `sm_theateritems explosive`:

| id | name | |
| --- | --- | --- |
| 1 | `grenade_m777_us` | |
| **2** | **`grenade_m777_ins`** | what the plugin was treating as a flashbang |
| 3 | `grenade_m18_wp_us` | |
| 4 | `grenade_m777_wp_us` | |
| 5–7 | `grenade_m203_smoke`, `grenade_gp25_smoke`, `grenade_m79_smoke` | |
| 8 | `grenade_m18` | |
| 9 | `grenade_m18_impact` | |
| **10** | **`grenade_m84`** | the actual flashbang |

Ids 1–7 are our own block, which `#base` places ahead of the inherited ones — the same ordering
documented above the theater's `ammo` section. **Every explosive added to that block shifts the
flashbang again**, which is why this is now a lookup by name through `gg2_theater_items` on every
map. That also makes it correct per gamemode, since each one loads its own theater.

### 2. The victim flags were never cleared

```sourcepawn
if (!IsClientInGame(i) || !IsPlayerAlive(i) || !isClientFlashed[i] || throwerTeam != GetClientTeam(i) || i == thrower) continue;
numFlashed++;
isClientFlashed[i] = 0;      // only ever reached for a victim that was counted
```

A blind was consumed only if the victim turned out to be a live teammate of the thrower. A blind
caused by an **enemy** — which is every bot on a coop server — is on the other team from that
thrower, so it was recorded and then left set forever. Same for a self-blind (`i == thrower`), a
victim who died inside the 0.1s delay, and one who disconnected. Nothing reset between rounds or
maps, and the array was `int[MAXPLAYERS]` rather than `MAXPLAYERS + 1`.

### Put together

Real flashbangs only ever *set* flags — their id never matched 2, so no timer ever ran to consume
them. The flags piled up, overwhelmingly from bots, and then the first id-2 detonation claimed the
lot. On main that is an impact smoke; on test it is the insurgent 155mm shell, whose owner
FireSupport sets to the player who called the strike (`SDKCall(fCreateRocket, client, ...)`). Either
way a player got credited with every teammate any bot had flashbanged since the previous one.

## How attribution works now

A blind belongs to exactly the grenade that caused it, matched on the **tick**. That is exact rather
than a heuristic, and it is why there is no timer and no tolerance window:

```
CFlashBangGrenade::DoFlashEffect(def)
    RadiusFlash(...)                        -> CINSPlayer::Blind per victim,
                                               each firing player_blind synchronously
    EmitEvent(this, grenade_detonate, ...)  -> the event this plugin keys on
```

Both happen inside one call, so every `player_blind` a flashbang causes is fired in the same tick as,
and strictly before, its `grenade_detonate`. Nothing can land in between. The deferred branch of
`DoFlashEffect` emits no event at all; when its think runs it comes back through the same function
and both fire together then.

So: `player_blind` records `GetGameTickCount()` for the victim, and `grenade_detonate` counts the
players whose recorded tick is the current one. Every match is consumed regardless of team, alive
state or whether the thrower is still connected — that is the line the original was missing.
Consuming also settles the one genuinely ambiguous case, two flashbangs detonating on the same tick,
in favour of the first rather than crediting both with the same victims.

Other differences from the original: the pending detonation is carried as a **userid** rather than a
client index, `IsPlayerAlive` is gone (it only excluded a teammate blinded and then killed within
the same tick, which is the most deserving case there is), and the array is sized `MAXPLAYERS + 1`.

State is cleared on `OnMapEnd` rather than `OnMapStart` deliberately: `gg2_theater_items` fires
`TheaterItems_OnReady` from its own `OnMapStart`, and the order two plugins' `OnMapStart` run in is
not defined, so clearing there could wipe an id the forward had already handed over. Nothing
detonates between one map ending and the next starting.

## Dependencies

`gg2_theater_items` for the name→id lookup. If it is missing or its tables fail to build, the
flashbang id resolves to 0 and the plugin reports nothing rather than reporting the wrong thing; the
failure is logged once per map.
