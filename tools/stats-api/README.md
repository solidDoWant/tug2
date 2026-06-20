# stats-api

A small read-only REST API over the `gg2_mstats2` player statistics database
(see `plugins/sourcemod/scripting/gg2_mstats2.sp` and the schema in
`plugins/sourcemod/configs/sql-init-scripts/pgsql/gg2_mstats2.sql`).

This is an early scaffold — the endpoint shapes are expected to change as
requirements firm up.

## Configuration

This tool only owns its HTTP settings:

| Variable       | Default | Description                                     |
| -------------- | ------- | ----------------------------------------------- |
| `LISTEN_ADDR`  | `:8080` | Address the API HTTP server binds to.           |
| `METRICS_ADDR` | `:9090` | Address the Prometheus metrics server binds to. |

### Database connection

The database connection is configured entirely through pgx's native inputs —
this tool adds no connection variables of its own. Set `DATABASE_URL` to a
PostgreSQL connection string, or leave it empty and use the standard libpq
environment variables, which pgx reads directly:

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

## Operator metrics

Prometheus metrics are served from `GET /metrics` on a **separate listener**
(`METRICS_ADDR`, default `:9090`) so they are never exposed on the public API
port and never appear in the OpenAPI spec. Scrape that port from your monitoring
network; keep it off any public ingress.

| Metric                                                                       | Type      | Labels                    | Notes                                                                                                                                                                        |
| ---------------------------------------------------------------------------- | --------- | ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `http_requests_total`                                                        | counter   | `route`, `method`, `code` | `route` is the matched pattern (e.g. `GET /api/v1/players/{steam_id}`), not the raw path, so path params don't explode cardinality. Unmatched paths collapse to `unmatched`. |
| `http_request_duration_seconds`                                              | histogram | `route`, `method`         | Default buckets.                                                                                                                                                             |
| `http_requests_in_flight`                                                    | gauge     | —                         | Requests currently being served.                                                                                                                                             |
| `pgxpool_acquired_conns` / `_idle_conns` / `_total_conns` / `_max_conns`     | gauge     | —                         | Connection-pool snapshot, read at scrape time. Watch `acquired`/`total` against `max` to validate `pool_max_conns` sizing.                                                   |
| `pgxpool_acquire_total` / `_empty_acquire_total` / `_canceled_acquire_total` | counter   | —                         | A rising `empty_acquire_total` means requests are waiting for a free connection — the pool is undersized.                                                                    |
| `go_*` / `process_*`                                                         | various   | —                         | Default Go runtime and process collectors.                                                                                                                                   |

```sh
curl localhost:9090/metrics
```

## Endpoints

The data API is versioned via the URL (`/api/v1`). The operational probe
endpoints are unversioned.

| Method & path                            | Description                                                        |
| ---------------------------------------- | ------------------------------------------------------------------ |
| `GET /livez`                             | Liveness probe. Does not touch the DB; use for restart decisions.  |
| `GET /readyz`                            | Readiness probe. Pings the DB; use for load-balancer rotation.     |
| `GET /api/v1/players`                    | List players. `?sort=&limit=&offset=`.                             |
| `GET /api/v1/players/{steam_id}`         | Single player's stats.                                             |
| `GET /api/v1/players/{steam_id}/weapons` | Per-weapon kill breakdown for a player (unpaginated sub-resource). |
| `GET /api/v1/weapons`                    | Most-used weapons across all players. `?limit=&offset=`.           |
| `GET /api/v1/maps`                       | Per-map win/loss summary. `?limit=&offset=`.                       |
| `GET /api/v1/matches`                    | Recent match results. `?limit=&offset=`.                           |
| `GET /api/v1/bots`                       | Bots ranked by total kills. `?limit=&offset=`.                     |
| `GET /api/v1/medics`                     | Players ranked by time spent as medic. `?limit=&offset=`.          |
| `GET /api/v1/teamkills`                  | Players ranked by team kills. `?limit=&offset=`.                   |

### Pagination

Every list endpoint returns a paginated envelope so clients can build pagers:

```json
{ "items": [ ... ], "total": 1234, "limit": 50, "offset": 0 }
```

`total` is the count before `limit`/`offset` is applied. `limit` defaults to 50
(max 200); `offset` defaults to 0.

`sort` for `/api/v1/players` accepts: `kills`, `deaths`, `score`, `wins`,
`killstreak`, `caps`, `kd`, `updated_at` (default `score`). Results are
descending. Query parameters are validated by huma — an invalid `sort` or an
out-of-range `limit`/`offset` returns `422` with a problem-detail body.

> Bots, medics, and team kills are sourced from the `bot_kills`,
> `gg2_medic_tracker`, and `gg2_teamkill` tables, which share the
> `insurgency-stats` database. Player **display names and avatars are not yet
> resolved** — these endpoints return raw Steam IDs for now.

## Development

```sh
make run                 # go run with fmt+vet
make binary              # build a static binary under build/
make container-image     # build the container image
```

### Local stack (docker-compose)

`docker-compose.yml` brings up a Postgres 18 instance with the `gg2_mstats2`,
`gg2_medic_tracker`, and `gg2_teamkill` schemas applied, alongside this service
built from the `Dockerfile`:

```sh
docker compose up --build      # start Postgres + stats-api
curl localhost:8080/readyz     # API is up and the DB is reachable
curl localhost:8080/api/v1/players
docker compose down -v         # stop and wipe the database volume
```

The schema is applied from `plugins/.../pgsql/gg2_mstats2.sql` only when the
database volume is first created. After changing the schema, recreate the volume
with `docker compose down -v` followed by `docker compose up`. Postgres is also
exposed on `localhost:5432` (user/password/db all `insurgency` /
`sourcemod-insurgency-stats`) for direct inspection.
