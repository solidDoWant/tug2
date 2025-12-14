-- =====================================================
-- GG2 TeamKill System - PostgreSQL Database Schema
-- Tracks teamkill incidents and player statistics
-- =====================================================

CREATE TABLE IF NOT EXISTS player_tks (
    steam_id BIGINT PRIMARY KEY,
    tk_amnesty BOOLEAN DEFAULT FALSE,
    kills INTEGER DEFAULT 0,
    tk_given INTEGER DEFAULT 0,
    tk_taken INTEGER DEFAULT 0,
    last_seen INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS player_tk_logs (
    id SERIAL PRIMARY KEY,
    victim_steam_id BIGINT NOT NULL REFERENCES player_tks(steam_id) ON DELETE CASCADE,
    attacker_steam_id BIGINT NOT NULL REFERENCES player_tks(steam_id) ON DELETE CASCADE,
    forgiven BOOLEAN DEFAULT FALSE,
    weapon VARCHAR(64),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

-- Indexes on player_tks
CREATE INDEX IF NOT EXISTS idx_player_tks_tk_amnesty ON player_tks(tk_amnesty) WHERE tk_amnesty = TRUE;
CREATE INDEX IF NOT EXISTS idx_player_tks_last_seen ON player_tks(last_seen);
CREATE INDEX IF NOT EXISTS idx_player_tks_tk_ratio ON player_tks(kills, tk_given) WHERE kills >= 500;

-- Indexes on player_tk_logs
CREATE INDEX IF NOT EXISTS idx_player_tk_logs_victim_steam_id ON player_tk_logs(victim_steam_id);
CREATE INDEX IF NOT EXISTS idx_player_tk_logs_attacker_steam_id ON player_tk_logs(attacker_steam_id);
CREATE INDEX IF NOT EXISTS idx_player_tk_logs_forgiven ON player_tk_logs(forgiven);
CREATE INDEX IF NOT EXISTS idx_player_tk_logs_created_at ON player_tk_logs(created_at DESC);

-- =====================================================
-- Example Data
-- =====================================================

-- Example player with amnesty:
-- INSERT INTO player_tks (steam_id, tk_amnesty, kills, tk_given, last_seen) VALUES (
--   76561198012345678,
--   TRUE,
--   1000,
--   5,
--   1701388800         -- unix timestamp
-- ) ON CONFLICT (steam_id) DO NOTHING;

-- Example teamkill incident:
-- INSERT INTO player_tk_logs (victim_steam_id, attacker_steam_id, forgiven, weapon)
-- VALUES (
--   76561198012345678,
--   76561198087654321,
--   FALSE,
--   'weapon_m4a1'
-- );

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View players with TK amnesty
-- SELECT steam_id, kills, tk_given,
--        to_timestamp(last_seen) as last_seen_date
-- FROM player_tks
-- WHERE tk_amnesty = TRUE
-- ORDER BY steam_id;

-- View known TK offenders (same logic as plugin)
-- SELECT steam_id, kills, tk_given,
--        ROUND(kills::NUMERIC / NULLIF(tk_given, 0), 2) as kill_to_tk_ratio,
--        to_timestamp(last_seen) as last_seen_date
-- FROM player_tks
-- WHERE kills >= 500
--   AND (kills::NUMERIC / NULLIF(tk_given, 0)) < 100
--   AND last_seen > EXTRACT(epoch FROM NOW() - INTERVAL '90 days')
-- ORDER BY kill_to_tk_ratio ASC;

-- View recent unforgiven teamkills
-- SELECT
--     tk.attacker_steam_id,
--     tk.victim_steam_id,
--     tk.weapon,
--     tk.created_at
-- FROM player_tk_logs tk
-- WHERE tk.forgiven = FALSE
-- ORDER BY tk.created_at DESC
-- LIMIT 50;

-- Count teamkills by player
-- SELECT
--     attacker_steam_id,
--     COUNT(*) as total_tks,
--     COUNT(*) FILTER (WHERE forgiven = TRUE) as forgiven_count,
--     COUNT(*) FILTER (WHERE forgiven = FALSE) as unforgiven_count
-- FROM player_tk_logs
-- GROUP BY attacker_steam_id
-- ORDER BY total_tks DESC
-- LIMIT 20;

-- Clean up old teamkill records (older than 6 months)
-- DELETE FROM player_tk_logs
-- WHERE created_at < NOW() - INTERVAL '6 months';
