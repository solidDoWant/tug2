-- =====================================================
-- Connection Tracker - PostgreSQL Database Schema
-- Tracks player connections and IP addresses
-- =====================================================

CREATE TABLE IF NOT EXISTS connection_log (
    steamId VARCHAR(64) NOT NULL,
    ip_address VARCHAR(64) NOT NULL,
    connect_date INTEGER NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (steamId, ip_address)
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_connection_log_steamid ON connection_log(steamId);
CREATE INDEX IF NOT EXISTS idx_connection_log_ip_address ON connection_log(ip_address);
CREATE INDEX IF NOT EXISTS idx_connection_log_connect_date ON connection_log(connect_date);

-- =====================================================
-- Example Data
-- =====================================================

-- Example connection entry:
-- INSERT INTO connection_log (steamId, ip_address, connect_date) VALUES (
--   '76561198012345678',
--   '192.168.1.100',
--   1638360000         -- unix timestamp of connection
-- ) ON CONFLICT (steamId, ip_address) DO UPDATE SET connect_date = EXCLUDED.connect_date;

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all connections for a specific player
-- SELECT steamId, ip_address,
--        to_timestamp(connect_date) as last_connection,
--        created_at, updated_at
-- FROM connection_log
-- WHERE steamId = '76561198012345678'
-- ORDER BY connect_date DESC;

-- View all players who connected from a specific IP
-- SELECT steamId, ip_address,
--        to_timestamp(connect_date) as last_connection,
--        created_at
-- FROM connection_log
-- WHERE ip_address = '192.168.1.100'
-- ORDER BY connect_date DESC;

-- View recent connections (last 7 days)
-- SELECT steamId, ip_address, to_timestamp(connect_date) as last_connection
-- FROM connection_log
-- WHERE connect_date > EXTRACT(epoch FROM NOW() - INTERVAL '7 days')
-- ORDER BY connect_date DESC;

-- Find players with multiple IPs
-- SELECT steamId, COUNT(DISTINCT ip_address) as ip_count,
--        array_agg(DISTINCT ip_address) as ip_addresses
-- FROM connection_log
-- GROUP BY steamId
-- HAVING COUNT(DISTINCT ip_address) > 1
-- ORDER BY ip_count DESC;

-- Find IPs used by multiple players
-- SELECT ip_address, COUNT(DISTINCT steamId) as player_count,
--        array_agg(DISTINCT steamId) as steam_ids
-- FROM connection_log
-- GROUP BY ip_address
-- HAVING COUNT(DISTINCT steamId) > 1
-- ORDER BY player_count DESC;

-- Total unique players and IPs tracked
-- SELECT COUNT(DISTINCT steamId) as unique_players,
--        COUNT(DISTINCT ip_address) as unique_ips,
--        COUNT(*) as total_records
-- FROM connection_log;
