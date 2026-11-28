-- =====================================================
-- Player IP history (issue #44), in the punitive-persistence database beside punishments, so the
-- stats database - which the public stats API and the Discord bot read - holds no IP addresses.
-- Written by gg2_connection_tracker at each connect. Keyed like the stats database's sessions table
-- (steam_id, connected_at), so the two join by value; there is no foreign key across databases.
--
-- Old connection_log rows (stats database) are copied in once by hand, two connections per row (the
-- first and the last use of that address):
--   psql "<stats db>" -c "\copy (SELECT steamid::bigint, created_at AT TIME ZONE current_setting('TimeZone'), ip_address FROM connection_log WHERE steamid ~ '^[0-9]+$' UNION SELECT steamid::bigint, to_timestamp(connect_date), ip_address FROM connection_log WHERE steamid ~ '^[0-9]+$' AND connect_date > 0) TO STDOUT"
--     | psql "<punitive db>" -c "\copy player_connections (steam_id, connected_at, ip) FROM STDIN"
-- =====================================================

CREATE TABLE IF NOT EXISTS player_connections (
    steam_id     BIGINT NOT NULL CHECK (steam_id > 0),
    connected_at TIMESTAMPTZ NOT NULL,
    ip           INET NOT NULL,
    PRIMARY KEY (steam_id, connected_at)
);

CREATE INDEX IF NOT EXISTS idx_player_connections_ip ON player_connections (ip);

COMMENT ON TABLE player_connections IS 'IP address of each connection. Admin use only.';
COMMENT ON COLUMN player_connections.steam_id IS 'SteamID64 of the player.';
COMMENT ON COLUMN player_connections.connected_at IS 'When they connected; matches sessions.connected_at in the stats database.';
COMMENT ON COLUMN player_connections.ip IS 'IP address they connected from.';
