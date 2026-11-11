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

-- Descriptions for the Discord bot's query_stats tool, which shows the comments of the tables it can
-- read to the model writing SQL against them (tools/discord-bot). Keep them accurate and short, and
-- describe every column: what it counts, its units, and any trap in how it joins or is stored.
COMMENT ON TABLE maps IS 'Playtime per map. Join to map_stats on map_name.';
COMMENT ON COLUMN maps.map_name IS 'Map name.';
COMMENT ON COLUMN maps.play_time IS 'Total time played, added at each round end (time after the last round is not counted). query_stats returns intervals as seconds.';
COMMENT ON COLUMN maps.last_start IS 'When the map or its current round last started (UTC).';
COMMENT ON COLUMN maps.created_at IS 'First played (UTC).';
COMMENT ON COLUMN maps.updated_at IS 'Last activity on the map (UTC).';
