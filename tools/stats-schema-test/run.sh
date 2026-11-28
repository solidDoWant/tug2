#!/usr/bin/env bash
# Tests the stats v2 schema (issue #44) against a throwaway Postgres 18 laid out like production:
# the test server's user owns its own schema, which holds the old tables and the v2 ones, and cannot
# create schemas. Every SQL file is applied the way DatabaseMigrator applies it (the whole file as
# one query inside BEGIN/COMMIT), twice, because the migrator re-runs every file on every boot. Then
# test.sql seeds old and v2 data as the plugins would and checks the views' arithmetic, and
# plugin_sql.sql replays two of gg2_stats2's flushes statement for statement, and results.sql checks
# the per-round results cache.
#
#   tools/stats-schema-test/run.sh             # a new database; needs docker and psql
#   tools/stats-schema-test/run.sh <git-ref>   # an upgrade: lay out and seed the database with
#                                              # <git-ref>'s files, then apply this tree's on top
#
# The upgrade form checks that every stats view returns exactly what it did before the upgrade
# (e.g. phase 3 to phase 4, whose stats_00_legacy_rename.sql renames tables under live data).
#
# The database runs in a non-UTC zone on purpose: the old tables hold local wall-clock time.
set -euo pipefail

cd "$(dirname "$0")"
HERE=$PWD
SQL_DIR=$HERE/../../plugins/sourcemod/configs/sql-init-scripts/pgsql
FROM_REF=${1:-}
PORT=${STATS_TEST_PORT:-55439}
NAME=stats-schema-test-$$
WORK=$(mktemp -d)

docker run -d --rm --name "$NAME" -e POSTGRES_PASSWORD=pw -p "127.0.0.1:$PORT:5432" \
    postgres:18 -c timezone=America/New_York > /dev/null
trap 'docker rm -f "$NAME" > /dev/null; rm -rf "$WORK"' EXIT

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
apply() {   # <dir> <file>
    psql "$USER_DB" -q -v ON_ERROR_STOP=1 -c BEGIN -c "$(cat "$1/$2")" -c COMMIT > /dev/null
}

OLD=(firesupport d_dy_pull_rag gg2_bot_smoke_suppress gg2_forceretry gg2_fuckyeah
     gg2_medic_tracker gg2_messages gg2_mstats2 gg2_mstats2_shots gg2_mstats2_history gg2_teamkill map_logger)

# Boots twice the way test's database-migrations.cfg orders the files: stats_00 (if any), the old
# schema files, the other stats files. stats_12_retire_old.sql takes write access to the old tables
# away, so it runs separately, after the seed.
boot_twice() {   # <dir>
    local dir=$1 pass f size
    for pass in 1 2; do
        [ -f "$dir/stats_00_legacy_rename.sql" ] && apply "$dir" stats_00_legacy_rename.sql
        for f in "${OLD[@]}"; do apply "$dir" "$f.sql"; done
        if [ -z "${OLD_TABLES:-}" ]; then
            # What the old files made, so test.sql can tell v2 objects from old ones in the shared schema.
            OLD_TABLES=$(psql "$USER_DB" -Atc "SELECT string_agg(relname, ',') FROM pg_class
                WHERE relnamespace = current_schema()::regnamespace AND relkind IN ('r', 'v')")
        fi
        for f in $(cd "$dir" && ls stats_*.sql | grep -v 'stats_00_legacy_rename\|stats_12_retire_old'); do
            size=$(wc -c < "$dir/$f")
            # DatabaseMigrator refuses a file over MAX_SQL_FILE_SIZE.
            if (( size > 1048576 )); then echo "FAIL: $f is $size bytes (migrator max 1048576)"; exit 1; fi
            apply "$dir" "$f"
        done
        echo "$dir: pass $pass: all files applied"
    done
}

# Every stats view, row by row, in a stable order.
snapshot() {
    local v
    for v in $(psql "$USER_DB" -Atc "SELECT relname FROM pg_class WHERE relnamespace = current_schema()::regnamespace
                                     AND relkind = 'v' AND relname LIKE 'v\_%' ORDER BY 1"); do
        echo "== $v"
        psql "$USER_DB" -Atc "SELECT t::text FROM $v t ORDER BY 1"
    done
}

if [ -n "$FROM_REF" ]; then
    git -C "$HERE/../.." archive "$FROM_REF" plugins/sourcemod/configs/sql-init-scripts/pgsql tools/stats-schema-test | tar -x -C "$WORK"
    FROM_SQL=$WORK/plugins/sourcemod/configs/sql-init-scripts/pgsql
    FROM_TEST=$WORK/tools/stats-schema-test
    boot_twice "$FROM_SQL"
    (cd "$FROM_TEST" && psql "$USER_DB" -q -v ON_ERROR_STOP=1 -v old_tables="$OLD_TABLES" -f test.sql)
    (cd "$FROM_TEST" && psql "$USER_DB" -q -v ON_ERROR_STOP=1 -f plugin_sql.sql > /dev/null)
    if [ -f "$FROM_TEST/results.sql" ]; then
        (cd "$FROM_TEST" && psql "$USER_DB" -q -v ON_ERROR_STOP=1 -f results.sql > /dev/null)
    fi
    # A boot on the old files first, as the server had before the upgrade: results.sql leaves rounds
    # marked out of date, which any boot recomputes, so they would differ for that reason alone.
    apply "$FROM_SQL" stats_03_results.sql
    snapshot > "$WORK/before"
    boot_twice "$SQL_DIR"
    snapshot > "$WORK/after"
    if ! diff -u "$WORK/before" "$WORK/after" > "$WORK/diff"; then
        echo "FAIL: the views changed in the upgrade from $FROM_REF:"; head -60 "$WORK/diff"; exit 1
    fi
    echo "upgrade from $FROM_REF: $(grep -c '^== ' "$WORK/after") views unchanged ($(wc -l < "$WORK/after") lines)"
    # The plugin's writes, with this tree's table names, into the upgraded tables: the same flushes
    # on a boot an hour later, so its rows don't collide with the old tree's (its checks assume a
    # new database, so they are left out).
    sed 's/1764086400/1764090000/g; /^DO \$\$/,$d' plugin_sql.sql | psql "$USER_DB" -q -v ON_ERROR_STOP=1 > /dev/null
    if [ "$(psql "$USER_DB" -Atc "SELECT count(*) FROM fire_support_calls WHERE called_at > to_timestamp(1764090000)")" = 0 ]; then
        echo "FAIL: the plugin's writes did not land after the upgrade"; exit 1
    fi
else
    boot_twice "$SQL_DIR"
    psql "$USER_DB" -q -v ON_ERROR_STOP=1 -v old_tables="$OLD_TABLES" -f test.sql
    psql "$USER_DB" -q -v ON_ERROR_STOP=1 -f plugin_sql.sql > /dev/null
    psql "$USER_DB" -q -v ON_ERROR_STOP=1 -f results.sql > /dev/null
    # A boot recomputes rounds cached by an older definition (results.sql marked two).
    apply "$SQL_DIR" stats_03_results.sql
fi

# Every finished round is cached by the current definitions, and matches its live computation.
if [ "$(psql "$USER_DB" -Atc "SELECT count(*) FROM round_results_done WHERE def_hash <> stats_results_hash()")" != 0 ]; then
    echo "FAIL: rounds cached by an older definition after a boot"; exit 1
fi
if [ "$(psql "$USER_DB" -Atc "SELECT count(*) FROM ((TABLE player_round_results EXCEPT ALL SELECT * FROM stats_round_results(ARRAY(SELECT round_id FROM round_results_done)))
        UNION ALL (SELECT * FROM stats_round_results(ARRAY(SELECT round_id FROM round_results_done)) EXCEPT ALL TABLE player_round_results)) d")" != 0 ]; then
    echo "FAIL: cached round results differ from their live computation"; exit 1
fi

# Phase 4: the old tables become read-only to their owner (twice: every boot re-runs it), the views
# still read them, and the old schema files' DDL still applies.
if [ -f "$SQL_DIR/stats_12_retire_old.sql" ]; then
    apply "$SQL_DIR" stats_12_retire_old.sql
    apply "$SQL_DIR" stats_12_retire_old.sql
    boot_twice "$SQL_DIR" > /dev/null
    psql "$USER_DB" -q -v ON_ERROR_STOP=1 -c 'SELECT count(*) FROM v_player_lifetime' > /dev/null
    if psql "$USER_DB" -q -c 'INSERT INTO player_stats (steam_id) VALUES ($$76561198000000099$$)' 2> /dev/null; then
        echo "FAIL: the old tables still accept writes after stats_12_retire_old.sql"; exit 1
    fi
fi
echo "OK"
