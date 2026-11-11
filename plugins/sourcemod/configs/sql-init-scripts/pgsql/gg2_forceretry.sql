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
-- Migrations
-- =====================================================

-- Per-player opt-out from the automatic reconnect (!autoreconnect). Added after the table shipped;
-- additive and idempotent, so it is safe to run against a database created before the column
-- existed. Defaulting to FALSE means every existing player stays opted in, which is
-- the behaviour they had before this column existed.
ALTER TABLE players_smoke_cache ADD COLUMN IF NOT EXISTS auto_retry_opt_out BOOLEAN NOT NULL DEFAULT FALSE;

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

-- Players who have opted out of the automatic reconnect
-- SELECT steam_id, has_smoke, updated_at
-- FROM players_smoke_cache WHERE auto_retry_opt_out = TRUE ORDER BY updated_at DESC;

-- Opted out AND missing the particle cache, i.e. smoke looks wrong for them by choice
-- SELECT steam_id, updated_at
-- FROM players_smoke_cache WHERE auto_retry_opt_out = TRUE AND has_smoke = FALSE;

-- Descriptions for the Discord bot's query_stats tool, which shows the comments of the tables it can
-- read to the model writing SQL against them (tools/discord-bot). Keep them accurate and short, and
-- describe every column: what it counts, its units, and any trap in how it joins or is stored.
COMMENT ON TABLE players_smoke_cache IS 'Whether each player has the custom smoke effects downloaded. New players are reconnected once so their game downloads them.';
COMMENT ON COLUMN players_smoke_cache.steam_id IS 'SteamID64 as bigint.';
COMMENT ON COLUMN players_smoke_cache.has_smoke IS 'True once the player has reconnected and should have the smoke effects.';
COMMENT ON COLUMN players_smoke_cache.created_at IS 'First seen (UTC).';
COMMENT ON COLUMN players_smoke_cache.updated_at IS 'Last update (UTC).';
COMMENT ON COLUMN players_smoke_cache.auto_retry_opt_out IS 'True when the player turned off the automatic reconnect.';
