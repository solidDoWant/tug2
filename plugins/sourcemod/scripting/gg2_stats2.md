# gg2_stats2 - stats v2 recorder (issue #44)

Records raw game facts into the stats v2 tables, beside the old stats tables in each server's own
schema (`public` on main, `insurgency-test` on test). Every total (lifetime kills, K/D, wins,
accuracy, killstreaks, play and medic time, ...) is a view in
`configs/sql-init-scripts/pgsql/stats_05..07_views.sql`. The design and its reasoning are in
issue #44.

The one thing kept that could be derived is a cache: each finished round's per-player results
(`player_round_results`, `stats_03_results.sql`), so lifetime totals add up rounds instead of every
raw kill. The plugin recomputes a round's cache in every flush once the round is over; rounds not
cached yet are computed live by the views, and a boot recomputes every round when the definitions
change. Any row can be rebuilt from the raw tables, and the schema test checks it is.

## What it records

| Table | From |
| --- | --- |
| `server_builds`, `server_boots` | `configs/gg2_build.cfg` (written into the image from the Makefile's `GIT_COMMIT` / `IMAGE_VERSION`), engine uptime |
| `map_runs`, `rounds` | map start/end, `round_start`, `round_freeze_end`, `round_end` (winner, reason), `game_end`, the game's round MVP (`CINSServerGameStats::FindTopPlayers`) |
| `survival_levels`, `counterattacks` | `round_level_advanced`; `m_bCounterAttack` polled every second |
| `sessions`, `name_changes` | first admin check per SteamID, `player_disconnect`, `player_changename` |
| `player_spans` | `player_team`, `player_pick_squad`, round start/end, disconnects |
| `spawns`, `spawn_items` | `player_spawn` + 0.5 s: gear by theater name, weapons by classname |
| `kills`, `team_kill_forgives` | `player_death` (each side's team, positions, assister, deathflags, last hitgroup, killer's stance and aim), and the killing blow's damage from its `player_hurt`; `TeamKill_OnForgiven` |
| `hits` | every other `player_hurt` with a human on either side: both sides, positions, weapon, hitgroup, damage, health left, damage bits, attacker's stance and aim |
| `objective_events`, `objective_participants` | `controlpoint_captured` / `_neutralized` (cappers), `object_destroyed` |
| `revives`, `revive_helpers`, `heals`, `heal_holds` | bm2_respawn's `Stats_OnRevive`, `Stats_OnHealTick`, `Stats_OnHealHold` |
| `v2_fire_support_calls` | FireSupport's `FireSupport_OnCallResult`, `FireSupport_OnRefund` |
| `v2_player_rounds` | the game's round stats (score, capture ticks, resets) as deltas; suppressions, flashes |
| `v2_player_round_weapons` | shots and shots that hit (as gg2_mstats2 attributes them), `weapon_reload`, `weapon_deploy`, `time_weapon` |
| `punitive-persistence.player_connections` | the client's IP at each new session |

The forwards it listens to are declared in `include/gg2_stats.inc`.

### Damage

A hit's damage is the health it took. `player_hurt`'s `dmg_health` is that for a hit the victim
survives, but on a killing blow it is the whole uncapped damage: one rifle headshot on a bot reported
561050, and M107 kills 5000-77000 (measured on test, 2026-11-28). So the plugin reads the victim's
health in an `OnTakeDamage` hook, which runs just before the game applies the hit and fires
`player_hurt` in the same tick, and records health before minus health after.

Each hit is stored once: a killing blow as its `kills` row (`kills.damage`), any other as a `hits`
row. Damage dealt and taken, and hits by body part, are added up from the two by the per-round
cache, not counted separately.

Two things the game reports need correcting:

- `player_hurt`'s `hitgroup` is the victim's last hit location, even for damage that has none (a fall
  after a bullet hit came through as `right_arm`). Only bullets and melee keep it; anything else is
  `generic`, for hits and for the kill's hitgroup.
- A restart or crash ends every session without a `player_disconnect`. When the plugin first reaches
  the database after a boot, it closes sessions earlier boots left open at this boot's start, with
  `disconnect_reason` `server restarted`.

### Loading mid-map

A plugin loaded during a map (`sm plugins load`, or a changed `.smx` reloaded at a map change once
players are in) cannot know what the earlier instance wrote. It:

- skips the `OnMapStart` SourceMod calls right after `OnPluginStart`, which would start the map over;
- reads players' SteamIDs before the round's score baselines, so the round's score is not counted
  twice;
- writes nothing until it has read from the database, for this boot and map, the open map run, the
  round's start and live times, and the open sessions, and then carries on with those rows. The map
  start cannot be worked out on the server: game time stands still while the server is empty, so it
  came out 150 s off on test, outside `stats_round_id`'s 5 s match.

It counts as mid-map only with a client in the game, because `GameRules_GetProp` is a native error
until the map has loaded (gg2_hostname_rounds measured the same). A load with nobody in the game
starts a new map run. `sm_stats2_status` (server console) prints the plugin's state.

## Enabling it on a server

1. Nothing to create by hand: the `stats_*.sql` files make the tables in the database user's own
   schema, where its unqualified names resolve. Four would clash with old tables still being
   written, so they are `v2_maps`, `v2_player_rounds`, `v2_player_round_weapons` and
   `v2_fire_support_calls` until the old tables are retired. Until the tables exist, the plugin
   records nothing and logs why (it checks again each map start).
2. The server's `database-migrations.cfg` lists the `stats_*.sql` files after the old ones
   (`stats_04_old.sql` builds views over the old tables), and `player_connections.sql` under
   `punitive-persistence`.
3. The image ships `gg2_stats2.smx` (the `sourcemod-plugins-gg2-stats2` stage).
4. Once, by hand, copy the old IP history across (the command is at the top of
   `player_connections.sql`).

## Testing

`tools/stats-schema-test/run.sh` (docker + psql) builds a database laid out like production, applies
every file twice the way DatabaseMigrator does, checks the views' arithmetic against old data written
by both systems, and replays two of this plugin's flushes statement for statement. `results.sql`
checks the per-round cache: killstreaks built from rounds equal the plain definition over every
kill, caching changes no view's output, and every cached row equals its round's live computation.

## Still to confirm on the test server

These come from reading `server_srv.so`, not from watching a live game:

- `m_iCurrentStance` values 0/1/2 = standing/crouched/prone.
- `m_iPlayerFlags` bits 0x1 iron sights, 0x2 bipod, 0x20 focus (from `SetIronsightsState`,
  `SetBipodState`, `CINSPlayerShared::SetFocusMode`).
- `time_weapon`'s `weapon` and `weapon_deploy`'s `weaponid` being theater weapon ids.
- The order SourceMod runs `OnMapEnd` and `OnClientDisconnect` at a map change (either order is
  handled, but worth a look in the data).
