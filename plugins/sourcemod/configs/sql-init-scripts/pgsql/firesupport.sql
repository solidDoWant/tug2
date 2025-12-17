-- =====================================================
-- Fire Support System - PostgreSQL Database Schema
-- Tracks artillery/fire support usage statistics
-- =====================================================

CREATE TABLE IF NOT EXISTS fire_support (
    steamId VARCHAR(64) PRIMARY KEY,
    arty_thrown INTEGER DEFAULT 0,
    last_used INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

-- Index for finding active users (used fire support recently)
CREATE INDEX IF NOT EXISTS idx_fire_support_last_used ON fire_support(last_used DESC);

-- Index for finding top artillery users
CREATE INDEX IF NOT EXISTS idx_fire_support_arty_thrown ON fire_support(arty_thrown DESC);

-- =====================================================
-- Example Data
-- =====================================================

-- Example player with fire support usage:
-- INSERT INTO fire_support (steamId, arty_thrown, last_used) VALUES (
--   '76561198012345678',
--   42,
--   EXTRACT(epoch FROM NOW())::INTEGER
-- ) ON CONFLICT (steamId) DO NOTHING;

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View top artillery users
-- SELECT steamId, arty_thrown,
--        to_timestamp(last_used) as last_used_date
-- FROM fire_support
-- WHERE arty_thrown > 0
-- ORDER BY arty_thrown DESC
-- LIMIT 20;

-- View recent fire support users (last 30 days)
-- SELECT steamId, arty_thrown,
--        to_timestamp(last_used) as last_used_date
-- FROM fire_support
-- WHERE last_used > EXTRACT(epoch FROM NOW() - INTERVAL '30 days')
-- ORDER BY last_used DESC
-- LIMIT 50;

-- Get total fire support statistics
-- SELECT
--     COUNT(*) as total_players,
--     SUM(arty_thrown) as total_artillery_thrown,
--     AVG(arty_thrown) as avg_artillery_per_player,
--     MAX(arty_thrown) as max_artillery_by_player
-- FROM fire_support
-- WHERE arty_thrown > 0;

-- Clean up inactive players (no fire support usage in 6 months)
-- DELETE FROM fire_support
-- WHERE last_used < EXTRACT(epoch FROM NOW() - INTERVAL '6 months')
--   AND arty_thrown = 0;

-- Find players who might be spamming fire support (>100 uses)
-- SELECT steamId, arty_thrown,
--        to_timestamp(last_used) as last_used_date,
--        created_at as first_seen
-- FROM fire_support
-- WHERE arty_thrown > 100
-- ORDER BY arty_thrown DESC;
