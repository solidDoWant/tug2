-- =====================================================
-- Map Logger - PostgreSQL Database Schema
-- Tracks map playtime and usage statistics
-- =====================================================

CREATE TABLE IF NOT EXISTS maps (
    map_name VARCHAR(128) NOT NULL PRIMARY KEY,
    play_time INTEGER DEFAULT 0,
    last_start INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_maps_last_start ON maps(last_start);
CREATE INDEX IF NOT EXISTS idx_maps_play_time ON maps(play_time);

-- =====================================================
-- Example Data
-- =====================================================

-- Example map entry:
-- INSERT INTO maps (map_name, play_time, last_start) VALUES (
--   'buhriz',
--   3600,              -- total seconds played
--   1638360000         -- unix timestamp of last start
-- ) ON CONFLICT (map_name) DO NOTHING;

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all maps sorted by playtime
-- SELECT map_name, play_time,
--        to_timestamp(last_start) as last_played,
--        created_at
-- FROM maps
-- ORDER BY play_time DESC;

-- View maps played in last 7 days
-- SELECT map_name, play_time, to_timestamp(last_start) as last_played
-- FROM maps
-- WHERE last_start > EXTRACT(epoch FROM NOW() - INTERVAL '7 days')
-- ORDER BY last_start DESC;

-- Total playtime across all maps
-- SELECT SUM(play_time) as total_seconds,
--        SUM(play_time) / 3600.0 as total_hours
-- FROM maps;
