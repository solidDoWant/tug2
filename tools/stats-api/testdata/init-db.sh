#!/usr/bin/env bash
# Lays out a database the way production has it, for docker-compose.yml and the
# integration test (run-integration.sh):
#   - the old (pre-v2) stats tables and the stats v2 ones (issue #44) side by side in the user's
#     schema (here: public, as on main),
#   - then testdata/seed.sql's dummy data in both.
#
# Run as postgres's /docker-entrypoint-initdb.d hook (POSTGRES_USER/POSTGRES_DB
# set, files mounted at /sql and /seed.sql). Each file is one transaction, as
# DatabaseMigrator applies it.
set -euo pipefail

SQL_DIR=${SQL_DIR:-/sql}
SEED=${SEED:-/seed.sql}
psql=(psql -v ON_ERROR_STOP=1 -q --username "$POSTGRES_USER" --dbname "$POSTGRES_DB")

# The old tables the stats_04_old.sql views read.
for f in gg2_mstats2 gg2_mstats2_shots gg2_mstats2_history gg2_medic_tracker gg2_teamkill map_logger firesupport; do
    "${psql[@]}" -1 -f "$SQL_DIR/$f.sql"
done
for f in "$SQL_DIR"/stats_*.sql; do
    "${psql[@]}" -1 -f "$f"
done

"${psql[@]}" -1 -f "$SEED"
