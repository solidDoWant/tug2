-- =====================================================
-- GG2 TeamKill System - PostgreSQL Database Schema
-- Tracks teamkill incidents and player statistics
-- =====================================================

CREATE TABLE IF NOT EXISTS redux_players (
    id SERIAL PRIMARY KEY,
    steam_id VARCHAR(64) NOT NULL UNIQUE,
    player_name VARCHAR(128),
    tk_amnesty BOOLEAN DEFAULT FALSE,
    kills INTEGER DEFAULT 0,
    tk_given INTEGER DEFAULT 0,
    last_seen INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS redux_player_tks (
    id SERIAL PRIMARY KEY,
    victim_id INTEGER NOT NULL REFERENCES redux_players(id) ON DELETE CASCADE,
    attacker_id INTEGER NOT NULL REFERENCES redux_players(id) ON DELETE CASCADE,
    forgiven BOOLEAN DEFAULT FALSE,
    weapon VARCHAR(64),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

-- Indexes on redux_players
CREATE INDEX IF NOT EXISTS idx_redux_players_steam_id ON redux_players(steam_id);
CREATE INDEX IF NOT EXISTS idx_redux_players_tk_amnesty ON redux_players(tk_amnesty) WHERE tk_amnesty = TRUE;
CREATE INDEX IF NOT EXISTS idx_redux_players_last_seen ON redux_players(last_seen);
CREATE INDEX IF NOT EXISTS idx_redux_players_tk_ratio ON redux_players(kills, tk_given) WHERE kills >= 500;

-- Indexes on redux_player_tks
CREATE INDEX IF NOT EXISTS idx_redux_player_tks_victim_id ON redux_player_tks(victim_id);
CREATE INDEX IF NOT EXISTS idx_redux_player_tks_attacker_id ON redux_player_tks(attacker_id);
CREATE INDEX IF NOT EXISTS idx_redux_player_tks_forgiven ON redux_player_tks(forgiven);
CREATE INDEX IF NOT EXISTS idx_redux_player_tks_created_at ON redux_player_tks(created_at DESC);

-- =====================================================
-- Example Data
-- =====================================================

-- Example player with amnesty:
-- INSERT INTO redux_players (steam_id, player_name, tk_amnesty, kills, tk_given, last_seen) VALUES (
--   '76561198012345678',
--   'AdminPlayer',
--   TRUE,
--   1000,
--   5,
--   1701388800         -- unix timestamp
-- ) ON CONFLICT (steam_id) DO NOTHING;

-- Example teamkill incident:
-- INSERT INTO redux_player_tks (victim_id, attacker_id, forgiven, weapon) VALUES (
--   (SELECT id FROM redux_players WHERE steam_id = '76561198012345678' LIMIT 1),
--   (SELECT id FROM redux_players WHERE steam_id = '76561198087654321' LIMIT 1),
--   FALSE,
--   'weapon_m4a1'
-- );

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View players with TK amnesty
-- SELECT steam_id, player_name, kills, tk_given,
--        to_timestamp(last_seen) as last_seen_date
-- FROM redux_players
-- WHERE tk_amnesty = TRUE
-- ORDER BY player_name;

-- View known TK offenders (same logic as plugin)
-- SELECT steam_id, player_name, kills, tk_given,
--        ROUND(kills::NUMERIC / NULLIF(tk_given, 0), 2) as kill_to_tk_ratio,
--        to_timestamp(last_seen) as last_seen_date
-- FROM redux_players
-- WHERE kills >= 500
--   AND (kills::NUMERIC / NULLIF(tk_given, 0)) < 100
--   AND last_seen > EXTRACT(epoch FROM NOW() - INTERVAL '90 days')
-- ORDER BY kill_to_tk_ratio ASC;

-- View recent unforgiven teamkills
-- SELECT
--     a.steam_id as attacker_steam_id,
--     a.player_name as attacker_name,
--     v.steam_id as victim_steam_id,
--     v.player_name as victim_name,
--     tk.weapon,
--     tk.created_at
-- FROM redux_player_tks tk
-- JOIN redux_players a ON tk.attacker_id = a.id
-- JOIN redux_players v ON tk.victim_id = v.id
-- WHERE tk.forgiven = FALSE
-- ORDER BY tk.created_at DESC
-- LIMIT 50;

-- Count teamkills by player
-- SELECT
--     p.steam_id,
--     p.player_name,
--     COUNT(*) as total_tks,
--     COUNT(*) FILTER (WHERE tk.forgiven = TRUE) as forgiven_count,
--     COUNT(*) FILTER (WHERE tk.forgiven = FALSE) as unforgiven_count
-- FROM redux_player_tks tk
-- JOIN redux_players p ON tk.attacker_id = p.id
-- GROUP BY p.steam_id, p.player_name
-- ORDER BY total_tks DESC
-- LIMIT 20;

-- Clean up old teamkill records (older than 6 months)
-- DELETE FROM redux_player_tks
-- WHERE created_at < NOW() - INTERVAL '6 months';
