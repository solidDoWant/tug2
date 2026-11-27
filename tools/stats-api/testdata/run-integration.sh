#!/usr/bin/env bash
# Runs the integration test (integration_test.go) against a throwaway Postgres 18 laid out by
# init-db.sh: old and stats v2 tables side by side in public, seed.sql's data in both.
#
#   tools/stats-api/testdata/run-integration.sh      # needs docker, psql and go
#
# The database runs in a non-UTC zone on purpose: the old tables hold local wall-clock time, and
# the API must still report every time in UTC. Files are copied in (not bind-mounted) so this
# also works against a remote or nested docker daemon.
set -euo pipefail

cd "$(dirname "$0")/.."
SQL_DIR=../../plugins/sourcemod/configs/sql-init-scripts/pgsql
PORT=${STATS_API_TEST_PORT:-$((40000 + RANDOM % 20000))}
NAME=stats-api-integration-$$

docker create --name "$NAME" -e POSTGRES_PASSWORD=pw -e POSTGRES_USER=insurgency \
    -e POSTGRES_DB=sourcemod-insurgency-stats -p "127.0.0.1:$PORT:5432" \
    postgres:18 -c timezone=America/New_York > /dev/null
trap 'docker rm -f "$NAME" > /dev/null' EXIT
docker cp "$SQL_DIR" "$NAME:/sql"
docker cp testdata/seed.sql "$NAME:/seed.sql"
docker cp testdata/init-db.sh "$NAME:/docker-entrypoint-initdb.d/10-init-db.sh"
docker start "$NAME" > /dev/null

URL="postgres://insurgency:pw@127.0.0.1:$PORT/sourcemod-insurgency-stats?sslmode=disable"
# The entrypoint restarts the server after its init scripts, so wait for the seeded data over TCP
# (with the host's psql: docker exec is unreliable in nested docker).
for _ in $(seq 120); do
    if psql "$URL" -Atc 'SELECT 1 FROM rounds LIMIT 1' 2> /dev/null | grep -q 1; then
        break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" != true ]; then
        docker logs "$NAME" 2>&1 | tail -30
        exit 1
    fi
    sleep 1
done

STATS_API_TEST_DB_URL="$URL" \
    go test -count=1 -run Integration -v ./... "$@"
