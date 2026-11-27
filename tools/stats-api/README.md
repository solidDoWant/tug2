# stats-api

A small read-only REST API over the stats v2 database (issue #44; the schema is
`plugins/sourcemod/configs/sql-init-scripts/pgsql/stats_*.sql`): players,
weapons, maps, map runs, rounds, bots, medics, team kills and fire support.

## Configuration

This tool only owns its HTTP settings:

| Variable        | Default                                                                | Description                                                                                                                                               |
| --------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LISTEN_ADDR`   | `:8080`                                                                | Address the API HTTP server binds to.                                                                                                                     |
| `METRICS_ADDR`  | `:9090`                                                                | Address the Prometheus metrics server binds to.                                                                                                           |
| `CACHE_CONTROL` | `public, s-maxage=60, stale-while-revalidate=60, stale-if-error=86400` | `Cache-Control` header stamped on successful `GET /api/v2/*` responses so a shared cache/CDN can serve repeated anonymous reads. Set to `off` to disable. |
| `BASE_PATH`     | _(empty)_                                                              | URL path prefix to serve the API, docs, and spec under (e.g. `/test`), so several deployments can share one hostname. See [Base path](#base-path).        |

`CACHE_CONTROL` exists because this API is intended to sit behind a CDN (e.g.
Cloudflare) on a public network. `s-maxage` targets the shared cache only (no
browser `max-age`), so responses are at most ~60s stale at the edge; error and
non-`/api/v2/` responses (probes, docs) are never cached.

To cap how long any single query may run on the database (the origin-side
backstop for cache misses — chiefly the aggregation endpoints and deep-`offset`
pages), set Postgres `statement_timeout` through the connection: either
`DATABASE_URL=...?statement_timeout=5000` (milliseconds) or
`PGOPTIONS="-c statement_timeout=5000"`. pgx forwards both as session startup
parameters; the service does not set a default of its own.

### Base path

Setting `BASE_PATH=/test` moves every API, docs, and spec route under that
prefix: `/test/api/v2/players`, `/test/docs`, `/test/openapi.yaml`, with
`/test` and `/test/` redirecting to `/test/docs`. The unprefixed paths then
return 404. Leading/trailing slashes are optional (`test`, `/test` and `/test/`
are equivalent); an invalid value (query string, `{}` wildcards, empty or dot
segments) fails startup.

The spec's server URL, the docs UI's spec link, and the `$schema`/`Link`
schema URLs all include the prefix, so the docs and "try it" requests work
through the proxy. The proxy in front must therefore **forward the prefix
intact rather than strip it**.

What does not move:

- `/livez` and `/readyz` stay at the root, since the orchestrator probes the
  pod directly rather than through the proxy.
- The metrics listener (`METRICS_ADDR`) is unaffected, and the `route` label
  omits the prefix (`GET /api/v2/players`, not `GET /test/api/v2/players`), so
  every deployment reports the same route names; `job`/`instance` tell them
  apart.

### Database connection

The database connection is configured entirely through pgx's native inputs —
this tool adds no connection variables of its own. Set `DATABASE_URL` to a
PostgreSQL connection string, or leave it empty and use the standard libpq
environment variables, which pgx reads directly.

The connection's `search_path` selects the server's schema; the API names no
schema itself. Main's tables are in `public`, which the default finds; for test,
`DATABASE_URL=postgres://...?options=-csearch_path%3Dinsurgency-test` (or
`PGOPTIONS="-c search_path=insurgency-test"`). Each
session is set to `TimeZone=UTC` on connect.

- **Connection:** `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`,
  `PGCONNECT_TIMEOUT`.
- **TLS / verification mode:** `PGSSLMODE` (`disable`, `require`, `verify-ca`,
  `verify-full`).
- **Mutual TLS:** `PGSSLROOTCERT` (server CA), `PGSSLCERT` + `PGSSLKEY` (client
  certificate and key), `PGSSLPASSWORD`.
- **Pool size:** the `pool_max_conns` connection-string parameter, e.g.
  `...?pool_max_conns=10`.

These match the `insurgency-stats` entry in the SourceMod `databases.cfg`. See
the [pgconn connection-string docs](https://pkg.go.dev/github.com/jackc/pgx/v5/pgconn#ParseConfig)
for the full list.

Example with full verification and mutual TLS via env vars:

```sh
export PGHOST=envoy PGPORT=5432 PGDATABASE=sourcemod-insurgency-stats PGUSER=insurgency
export PGSSLMODE=verify-full
export PGSSLROOTCERT=/etc/tls/ca.crt PGSSLCERT=/etc/tls/client.crt PGSSLKEY=/etc/tls/client.key
```

The service is stateless, so you can run multiple replicas behind a load
balancer and route any request to any instance. The only shared state is
Postgres. When scaling out, set `pool_max_conns` so the total connections across
all replicas stays within Postgres's `max_connections`.

## API documentation

The OpenAPI 3.1 spec is generated from the Go request/response types by
[huma](https://github.com/danielgtaylor/huma), so it never drifts from the code.
When the server is running it serves:

| Path            | Description                        |
| --------------- | ---------------------------------- |
| `/docs`         | Interactive API documentation UI.  |
| `/openapi.yaml` | Generated OpenAPI 3.1 spec (YAML). |
| `/openapi.json` | Generated OpenAPI 3.1 spec (JSON). |

```sh
open http://localhost:8080/docs
```

The spec documents the data API only. The `/livez` and `/readyz` probes are
served on this port but marked `Hidden`, so they are omitted from the spec and
`/docs` — the published contract stays the resource API, while the probes remain
on the listener whose health they report.

## Operator metrics

Prometheus metrics are served from `GET /metrics` on a **separate listener**
(`METRICS_ADDR`, default `:9090`) so they are never exposed on the public API
port and never appear in the OpenAPI spec. Scrape that port from your monitoring
network; keep it off any public ingress.

| Metric                                                                       | Type      | Labels                    | Notes                                                                                                                                                                                                                                                                                                                                                                                              |
| ---------------------------------------------------------------------------- | --------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `http_requests_total`                                                        | counter   | `route`, `method`, `code` | `route` is the matched pattern (e.g. `GET /api/v2/players/{steam_id}`), not the raw path, so path params don't explode cardinality. Unmatched paths collapse to `unmatched`. The `/livez` and `/readyz` probes are excluded — they carry no operational signal (Kubernetes reports probe health) and their constant kubelet traffic would skew the aggregate request rate and latency percentiles. |
| `http_request_duration_seconds`                                              | histogram | `route`, `method`         | Default buckets.                                                                                                                                                                                                                                                                                                                                                                                   |
| `http_requests_in_flight`                                                    | gauge     | —                         | Requests currently being served.                                                                                                                                                                                                                                                                                                                                                                   |
| `pgxpool_acquired_conns` / `_idle_conns` / `_total_conns` / `_max_conns`     | gauge     | —                         | Connection-pool snapshot, read at scrape time. Watch `acquired`/`total` against `max` to validate `pool_max_conns` sizing.                                                                                                                                                                                                                                                                         |
| `pgxpool_acquire_total` / `_empty_acquire_total` / `_canceled_acquire_total` | counter   | —                         | A rising `empty_acquire_total` means requests are waiting for a free connection — the pool is undersized.                                                                                                                                                                                                                                                                                          |
| `go_*` / `process_*`                                                         | various   | —                         | Default Go runtime and process collectors.                                                                                                                                                                                                                                                                                                                                                         |

```sh
curl localhost:9090/metrics
```

## Endpoints

The data API is versioned via the URL (`/api/v2`; v1 is gone). The operational
probe endpoints are unversioned. Every endpoint is a `GET`.

| Path                                     | Description                                                                 |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `/livez`                                 | Liveness probe. Does not touch the DB; use for restart decisions.           |
| `/readyz`                                | Readiness probe. Pings the DB; use for load-balancer rotation.              |
| `/api/v2/players`                        | Player leaderboard. `sort`, `name`, window, pagination.                     |
| `/api/v2/players/{steam_id}`             | One player's stats and name history. Window.                                |
| `/api/v2/players/{steam_id}/weapons`     | A player's stats per weapon (plain array). Window.                          |
| `/api/v2/players/{steam_id}/classes`     | A player's time, kills and deaths per class (plain array). Window.          |
| `/api/v2/players/{steam_id}/rounds`      | A player's round history, newest first. Window, pagination.                 |
| `/api/v2/weapons`                        | Weapons across all players. `sort`, window, pagination.                     |
| `/api/v2/weapons/{weapon_name}`          | Top players with one weapon. `sort`, `min_shots`, window, pagination.       |
| `/api/v2/maps`                           | Per-map rounds, results and play time. `sort`, pagination.                  |
| `/api/v2/maps/{map_name}`                | One map, its last 20 runs and recent kill positions. `limit_positions`.     |
| `/api/v2/map-runs`                       | Map runs (map loads), newest first. Pagination.                             |
| `/api/v2/map-runs/{id}`                  | One map run: its rounds and a scoreboard.                                   |
| `/api/v2/rounds/{id}`                    | One round and its timeline.                                                 |
| `/api/v2/bots`                           | Bots by kills of players. Pagination.                                       |
| `/api/v2/bots/{bot_name}/weapons`        | A bot's kills per weapon (plain array; `[]` for an unknown bot).            |
| `/api/v2/medics`                         | Medic leaderboard. `sort`, window, pagination.                              |
| `/api/v2/teamkills`                      | Team-kill leaderboard. `sort`, window, pagination.                          |
| `/api/v2/teamkills/weapons`              | Weapons by team kills. Window, pagination.                                  |
| `/api/v2/fire-support`                   | Fire-support leaderboard. `sort`, window, pagination.                       |

`/docs` and `/openapi.yaml` describe every field; the notes below cover the rules.

### Where the numbers come from

The API reads the stats v2 views and tables (issue #44,
`plugins/sourcemod/configs/sql-init-scripts/pgsql/stats_*.sql`). Facts are stored
once and every total is a view: lifetime stats come from `v_player_lifetime`,
`v_player_weapon_lifetime`, `v_maps`, `v_bot_weapon_kills` and `v_team_kills`,
which combine v2 rows with the pre-v2 tables. The API does not re-derive any
stat; it only sums the per-round views over a window, joins names in
(`v_players`), pages and sorts. The schema itself is not named anywhere: the
connection's `search_path` selects the server's schema (see
[Database connection](#database-connection)).

- **SteamIDs** are JSON strings (a SteamID64 exceeds JavaScript's safe integers).
- **Times** are RFC 3339 in UTC.
- **Names** are each player's latest in-game name (`v_players`), or `null`.
- **v2-only stats** (assists, world deaths, headshot kills, cache kills, times
  revived, HP healed, times suppressed, damage, per-hitgroup hits, reloads,
  deploys, time drawn, rounds played, class breakdowns, map runs, rounds,
  kill positions, failed/refunded fire support, revive times) only exist from the
  v2 cutover (late 2026-11). Lifetime totals count them as 0 before that; in a
  window holding only pre-v2 history they are `null`, not 0.
- `kd` is `kills / deaths` to two decimals (`kills` when `deaths` is 0);
  `accuracy` is `100 * shots_hit_enemy / shots` to one decimal, `null` without shots.
- `best_killstreak` is lifetime only, so `null` with a window.

### Sorts

All sorts are descending, `null`s last; an invalid value is a `422`.

| Endpoint                     | `sort` (default first)                                                                                                                  |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `/players`                   | `score`, `kills`, `deaths`, `kd`, `assists`, `wins`, `play_time`, `accuracy`, `revives`, `heals`, `caps`, `headshot_kills`, `killstreak`, `last_seen` |
| `/weapons`                   | `kills`, `shots`, `accuracy`                                                                                                            |
| `/weapons/{weapon_name}`     | `accuracy` (players with at least `min_shots`, default 100), `kills` (players with a kill)                                              |
| `/maps`                      | `rounds`, `play_time`, `last_played`, `win_rate`                                                                                        |
| `/bots`                      | `kills`                                                                                                                                 |
| `/medics`                    | `medic_time`, `revives`, `heals`, `hp_healed`                                                                                           |
| `/teamkills`                 | `team_kills`, `team_killed`, `forgiven`                                                                                                 |
| `/fire-support`              | `calls`, `failed`, `last_called`                                                                                                        |

`accuracy` on `/players` ranks players with at least 500 shots first, everyone
else after; on `/weapons` the cut is 1000 shots. `/players?name=` keeps players
whose current name contains the text, case-insensitively (`%`, `_` and `\` match
literally). Map runs and a player's rounds are newest first.

### Time windows

By default every number is a lifetime total. Add `?period=30d` (the last N days,
1-3650) or `?since=2026-11-01&until=2026-12-01` (UTC dates or RFC 3339 times; `since`
inclusive, `until` exclusive and defaulting to now) to get the same response for that
window instead. Mixing `period` with `since`/`until`, a bad date, or an empty range is
a `422`. Windowed list responses carry `window: {since, until}`, as does a single
player; lifetime responses have no `window`.

Endpoints taking a window: players, a player, their weapons, classes and rounds,
weapons, a weapon's players, medics, team kills, team-kill weapons and fire support.

With a window, player and weapon stats are summed from `v_player_round_stats` and
`v_player_round_weapon_stats` over their `at` (round end); the other sources are
filtered on their own time (revives on `revived_at`, `v_team_kills` on `killed_at`,
fire-support calls on `called_at`, class spans on their start and kills on
`killed_at`). That per-round history only reaches back so far: **to 2026-11 for the
core stats** (kills, deaths, score, shots, medic time, fire support, ...) and **to
2025-12 for team kills**. A window starting earlier only covers the part from then
on; earlier play exists only in the lifetime totals. A windowed list only includes
players (or weapons) with activity in the window; a single player is returned with
zeros if they didn't play in it.

### Pagination

Every list endpoint returns a paginated envelope so clients can build pagers:

```json
{ "items": [ ... ], "total": 1234, "limit": 50, "offset": 0, "window": { ... } }
```

`total` is the count before `limit`/`offset` is applied. `limit` defaults to 50
(max 200); `offset` defaults to 0 (max 100000). The per-player weapons and classes
and a bot's weapons are plain arrays.

### Notes per endpoint

- **`/players/{steam_id}`**: the leaderboard fields plus `name_history`
  (`[{name, changed_at}]`, newest first, consecutive repeats collapsed; v2 only).
  `404` for a SteamID `v_players` doesn't know.
- **`/players/{steam_id}/classes`**: per `class_template`, `seconds` played in it
  (from `player_spans`) and the enemy `kills` and `deaths` while in it (the span open
  at the kill). v2 only.
- **`/players/{steam_id}/rounds`**: rows of `v_player_round_stats` with the round's
  `map_name`, `game_mode`, `ended_at`, `winner`, `end_reason` and `was_mvp`. Pre-v2
  rows have `source: "old"`, `round_id: null`, and `null` for what the old plugins
  did not record; old medic, team-kill and fire-support history are rows of their own.
- **`/weapons/{weapon_name}`**: `404` for a weapon neither v2 nor the old stats know.
- **`/maps/{map_name}`**: the `/maps` row, `recent_runs` (last 20 map runs) and
  `kill_positions` (the most recent `limit_positions`, default 2000, max 10000, v2
  kills on the map with a recorded position). `404` for an unknown map.
- **`/map-runs/{id}`**: `{run, rounds, scoreboard}`; `run` is the `/map-runs` item
  (its `rounds` is a count of ended rounds), `rounds` the run's rounds, `scoreboard`
  each player's sums over them, by score.
- **`/rounds/{id}`**: the round plus `timeline`, every event in time order as
  `{at, type, ...}`: `kill` (kind, attacker/victim SteamID or bot name and name,
  weapon, headshot), `objective` (kind, control point, name, team, participants),
  `counterattack_start`/`counterattack_end`, `revive` (reviver, revived, method) and
  `survival_level`. Fields that don't apply are omitted.
- **`/medics`**: players with medic time, revives or heals; `avg_revive_seconds` is
  their mean revive duration as the reviver (v2 only).
- **`/teamkills`**: players with team kills given or taken; `kills` (enemy kills)
  is for context, `forgiven` counts their logged team kills (`v_team_kills`) that
  the victim forgave.
- **`/fire-support`**: `calls` are successful calls; `failed` and `refunded` are v2
  only; `last_called_at` is the last successful call in the v2 or old call log.

## Development

```sh
make run                 # go run with fmt+vet
make test                # unit tests (the integration test skips itself)
make binary              # build a static binary under build/
make container-image     # build the container image
testdata/run-integration.sh   # integration test against a throwaway Postgres 18 (docker, psql)
```

`testdata/run-integration.sh` starts `postgres:18` on a random port in a non-UTC
zone, lays it out with `testdata/init-db.sh` (old and v2 tables side by side
in `public`, `testdata/seed.sql`'s fictional data in both), and runs
`integration_test.go` with `STATS_API_TEST_DB_URL` set: every endpoint's query
runs, lifetime numbers are compared with the views, and the HTTP responses are
checked for status codes, string SteamIDs and `null` pre-v2 stats.

### Local stack (docker-compose)

`docker-compose.yml` brings up the same database (`testdata/init-db.sh`) alongside
this service built from the `Dockerfile`:

```sh
docker compose up --build      # start Postgres + stats-api
curl localhost:8080/readyz     # API is up and the DB is reachable
curl localhost:8080/api/v2/players
docker compose down -v         # stop and wipe the database volume
```

The schema and seed are applied only when the database volume is first created.
After changing them, recreate the volume with `docker compose down -v` followed by
`docker compose up`. Postgres is also exposed on `localhost:5432` (user/password
`insurgency`, database `sourcemod-insurgency-stats`) for direct inspection.
