#!/usr/bin/env bash
# Tests the stats v2 schema (issue #44) against a throwaway Postgres 18 laid out like production:
# the test server's user owns its own schema, which holds the old tables and the v2 ones, and cannot
# create schemas. Every SQL file is applied the way DatabaseMigrator applies it
# (the whole file as one query inside BEGIN/COMMIT), twice, because the migrator re-runs every file on
# every boot. Then test.sql seeds old and v2 data as the dual-writing plugins would and checks the
# views' arithmetic, and plugin_sql.sql replays two of gg2_stats2's flushes statement for statement.
#
#   tools/stats-schema-test/run.sh            # needs docker and psql
#
# The database runs in a non-UTC zone on purpose: the old tables hold local wall-clock time.
set -euo pipefail

cd "$(dirname "$0")"
SQL_DIR=../../plugins/sourcemod/configs/sql-init-scripts/pgsql
PORT=${STATS_TEST_PORT:-55439}
NAME=stats-schema-test-$$

docker run -d --rm --name "$NAME" -e POSTGRES_PASSWORD=pw -p "127.0.0.1:$PORT:5432" \
    postgres:18 -c timezone=America/New_York > /dev/null
trap 'docker rm -f "$NAME" > /dev/null' EXIT

ADMIN="host=127.0.0.1 port=$PORT user=postgres password=pw"
for _ in $(seq 60); do psql "$ADMIN dbname=postgres" -Atc 'select 1' > /dev/null 2>&1 && break; sleep 1; done

psql "$ADMIN dbname=postgres" -q -v ON_ERROR_STOP=1 <<'EOF'
CREATE ROLE "insurgency-test" LOGIN PASSWORD 't';
CREATE DATABASE "sourcemod-insurgency-stats";
EOF
psql "$ADMIN dbname=sourcemod-insurgency-stats" -q -v ON_ERROR_STOP=1 <<'EOF'
CREATE SCHEMA "insurgency-test" AUTHORIZATION "insurgency-test";
EOF

USER_DB="host=127.0.0.1 port=$PORT user=insurgency-test password=t dbname=sourcemod-insurgency-stats options=-cclient_min_messages=warning"
apply() {
    psql "$USER_DB" -q -v ON_ERROR_STOP=1 -c BEGIN -c "$(cat "$SQL_DIR/$1")" -c COMMIT > /dev/null
}

OLD=(firesupport d_dy_pull_rag gg2_bot_smoke_suppress gg2_connection_tracker gg2_forceretry gg2_fuckyeah
     gg2_medic_tracker gg2_messages gg2_mstats2 gg2_mstats2_shots gg2_mstats2_history gg2_teamkill map_logger)
for pass in 1 2; do
    for f in "${OLD[@]}"; do apply "$f.sql"; done
    if (( pass == 1 )); then
        # What the old files made, so test.sql can tell v2 objects from old ones in the shared schema.
        OLD_TABLES=$(psql "$USER_DB" -Atc "SELECT string_agg(relname, ',') FROM pg_class
            WHERE relnamespace = current_schema()::regnamespace AND relkind IN ('r', 'v')")
    fi
    for f in "$SQL_DIR"/stats_*.sql; do
        size=$(wc -c < "$f")
        # DatabaseMigrator's buffer is 16384 bytes, less 256 for its own use.
        if (( size >= 16128 )); then echo "FAIL: $(basename "$f") is $size bytes (migrator max 16127)"; exit 1; fi
        if awk 'length > 1022 { exit 1 }' "$f"; then :; else echo "FAIL: $(basename "$f") has a line over 1022 chars"; exit 1; fi
        apply "$(basename "$f")"
    done
    echo "pass $pass: all files applied"
done

psql "$USER_DB" -q -v ON_ERROR_STOP=1 -v old_tables="$OLD_TABLES" -f test.sql
psql "$USER_DB" -q -v ON_ERROR_STOP=1 -f plugin_sql.sql > /dev/null
echo "OK"
