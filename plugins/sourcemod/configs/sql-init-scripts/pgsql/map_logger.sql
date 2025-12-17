-- =====================================================
-- Map Logger - PostgreSQL Database Schema
-- Tracks map playtime and usage statistics
-- =====================================================

CREATE TABLE IF NOT EXISTS maps (
    map_name VARCHAR(128) NOT NULL PRIMARY KEY,
    play_time INTERVAL DEFAULT '0 seconds',
    last_start TIMESTAMP DEFAULT NULL,
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
--   '1 hour'::INTERVAL,  -- total time played
--   CURRENT_TIMESTAMP    -- timestamp of last start
-- ) ON CONFLICT (map_name) DO NOTHING;

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all maps sorted by playtime
-- SELECT map_name, play_time,
--        last_start as last_played,
--        created_at
-- FROM maps
-- ORDER BY play_time DESC;

-- View maps played in last 7 days
-- SELECT map_name, play_time, last_start as last_played
-- FROM maps
-- WHERE last_start > NOW() - INTERVAL '7 days'
-- ORDER BY last_start DESC;

-- Total playtime across all maps
-- SELECT SUM(play_time) as total_duration,
--        EXTRACT(EPOCH FROM SUM(play_time)) / 3600.0 as total_hours
-- FROM maps;
