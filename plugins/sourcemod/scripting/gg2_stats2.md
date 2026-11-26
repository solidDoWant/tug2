# gg2_stats2 - stats v2 recorder (issue #44)

Records raw game facts into a per-server `stats_*` schema. Nothing derived is stored: every total
(lifetime kills, K/D, wins, accuracy, killstreaks, play and medic time, ...) is a view in
`configs/sql-init-scripts/pgsql/stats_05..07_views.sql`. The design and its reasoning are in
issue #44.

## What it records

| Table | From |
| --- | --- |
| `server_builds`, `server_boots` | `configs/gg2_build.cfg` (written into the image from the Makefile's `GIT_COMMIT` / `IMAGE_VERSION`), engine uptime |
| `map_runs`, `rounds` | map start/end, `round_start`, `round_freeze_end`, `round_end` (winner, reason), `game_end`, the game's round MVP (`CINSServerGameStats::FindTopPlayers`) |
| `survival_levels`, `counterattacks` | `round_level_advanced`; `m_bCounterAttack` polled every second |
| `sessions`, `name_changes` | first admin check per SteamID, `player_disconnect`, `player_changename` |
| `player_spans` | `player_team`, `player_pick_squad`, round start/end, disconnects |
| `spawns`, `spawn_items` | `player_spawn` + 0.5 s: gear by theater name, weapons by classname |
| `kills`, `team_kill_forgives` | `player_death` (positions, assister, deathflags, last hitgroup, killer's stance and aim); `TeamKill_OnForgiven` |
| `objective_events`, `objective_participants` | `controlpoint_captured` / `_neutralized` (cappers), `object_destroyed` |
| `revives`, `revive_helpers`, `heals`, `heal_holds` | bm2_respawn's `Stats_OnRevive`, `Stats_OnHealTick`, `Stats_OnHealHold` |
| `fire_support_calls` | FireSupport's `FireSupport_OnCallResult`, `FireSupport_OnRefund` |
| `player_rounds` | the game's round stats (score, capture ticks, resets) as deltas; suppressions, flashes, damage taken, fall damage |
| `player_round_weapons` | shots and hits (as gg2_mstats2 attributes them), hits by hitgroup, damage, `weapon_reload`, `weapon_deploy`, `time_weapon` |
| `punitive-persistence.player_connections` | the client's IP at each new session |

The forwards it listens to are declared in `include/gg2_stats.inc`.

## Enabling it on a server

1. The server's schema exists, owned by its database user. The game server's user cannot create
   schemas, so it is declared in infra-mk3 (`backend/postgres/databases/sourcemod-insurgency-stats.yaml`,
   CloudNativePG `Database.spec.schemas`): `stats_test` owned by `insurgency-test`, later `stats_main`
   owned by `insurgency`. By hand it would be
   `CREATE SCHEMA stats_test AUTHORIZATION "insurgency-test";` as a superuser.

   The plugin and the `stats_*.sql` files find the one `stats_*` schema owned by the connecting
   user. With none, the plugin records nothing and logs why; the SQL files fail and roll back.
2. The server's `database-migrations.cfg` lists the `stats_*.sql` files after the old ones
   (`stats_04_old.sql` builds views over the old tables), and `player_connections.sql` under
   `punitive-persistence`.
3. The image ships `gg2_stats2.smx` (the `sourcemod-plugins-gg2-stats2` stage).
4. Once, by hand, copy the old IP history across (the command is at the top of
   `player_connections.sql`).

## Testing

`tools/stats-schema-test/run.sh` (docker + psql) builds a database laid out like production, applies
every file twice the way DatabaseMigrator does, checks the views' arithmetic against old data written
by both systems, and replays two of this plugin's flushes statement for statement.

## Still to confirm on the test server

These come from reading `server_srv.so`, not from watching a live game:

- `m_iCurrentStance` values 0/1/2 = standing/crouched/prone.
- `m_iPlayerFlags` bits 0x1 iron sights, 0x2 bipod, 0x20 focus (from `SetIronsightsState`,
  `SetBipodState`, `CINSPlayerShared::SetFocusMode`).
- `time_weapon`'s `weapon` and `weapon_deploy`'s `weaponid` being theater weapon ids.
- The order SourceMod runs `OnMapEnd` and `OnClientDisconnect` at a map change (either order is
  handled, but worth a look in the data).
