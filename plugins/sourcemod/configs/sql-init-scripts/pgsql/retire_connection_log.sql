-- Drops the old IP history table from the stats database (issue #44, phase 4). NOT a migration: run by
-- hand, once per server, as the table's owner, and only after checking that its rows are in
-- punitive-persistence.player_connections (the copy command is at the top of player_connections.sql),
-- because this cannot be undone. For example, compare
--   SELECT count(DISTINCT (steamid, ip_address)) FROM connection_log;                 -- stats DB
--   SELECT count(DISTINCT (steam_id, ip)) FROM player_connections;                     -- punitive DB
-- (the second is at least the first).
DROP TABLE IF EXISTS connection_log;
