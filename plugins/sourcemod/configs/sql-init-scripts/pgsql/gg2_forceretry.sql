-- =====================================================
-- GG2 ForceRetry - PostgreSQL Database Schema
-- Tracks smoke particle cache status for players
-- =====================================================

CREATE TABLE IF NOT EXISTS players_smoke_cache (
    steam_id BIGINT NOT NULL PRIMARY KEY,
    has_smoke BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_players_smoke_cache_has_smoke ON players_smoke_cache(has_smoke);

-- =====================================================
-- Example Data
-- =====================================================

-- Example player entry:
-- INSERT INTO players_smoke_cache (steam_id, has_smoke) VALUES (
--   76561198012345678,  -- SteamID64
--   TRUE                -- TRUE = has smoke cached, FALSE = needs retry
-- ) ON CONFLICT (steam_id) DO NOTHING;

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all players with smoke cached
-- SELECT steam_id, has_smoke, created_at, updated_at
-- FROM players_smoke_cache
-- WHERE has_smoke = TRUE
-- ORDER BY updated_at DESC;

-- View all players needing retry
-- SELECT steam_id, has_smoke, created_at, updated_at
-- FROM players_smoke_cache
-- WHERE has_smoke = FALSE
-- ORDER BY updated_at DESC;

-- Count players by cache status
-- SELECT has_smoke, COUNT(*) as player_count
-- FROM players_smoke_cache
-- GROUP BY has_smoke;

-- Clean up old entries (players who haven't connected in 90 days)
-- DELETE FROM players_smoke_cache
-- WHERE updated_at < NOW() - INTERVAL '90 days';
