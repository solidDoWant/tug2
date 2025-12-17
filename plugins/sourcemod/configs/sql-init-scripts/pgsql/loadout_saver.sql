-- =====================================================
-- Insurgency Loadout Saver - PostgreSQL Database Schema
-- Single Row Per Player/Class Design
-- =====================================================

CREATE TABLE IF NOT EXISTS loadouts (
    steam_id BIGINT NOT NULL,
    class_template VARCHAR(128) NOT NULL,
    gear TEXT,
    primary_weapon TEXT,
    secondary_weapon TEXT,
    explosive TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_count INTEGER DEFAULT 0,
    PRIMARY KEY (steam_id, class_template)
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_loadouts_steam_id ON loadouts(steam_id);
CREATE INDEX IF NOT EXISTS idx_loadouts_last_seen ON loadouts(last_seen_at);

-- =====================================================
-- Example Data (Semicolon-Separated IDs Format)
-- =====================================================

-- Example loadout entry:
-- INSERT INTO loadouts (steam_id, class_template, gear, primary_weapon, secondary_weapon, explosive) VALUES (
--   76561197960287930,
--   'template_rifleman_security_coop',
--   '39;47',              -- gear IDs
--   '5;12;13;14',         -- primary weapon ID + upgrade IDs
--   '8;15',               -- secondary weapon ID + upgrade IDs
--   '20'                  -- explosive weapon ID + upgrade IDs
-- );

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all loadouts for a player
-- SELECT * FROM loadouts WHERE steam_id = 76561197960287930;

-- Delete old loadouts (not seen in 30 days)
-- DELETE FROM loadouts WHERE last_seen_at < NOW() - INTERVAL '30 days';

-- Count total loadouts per player
-- SELECT steam_id, COUNT(*) as loadout_count 
-- FROM loadouts 
-- GROUP BY steam_id 
-- ORDER BY loadout_count DESC;

-- View most recently updated loadouts
-- SELECT steam_id, class_template, updated_at, update_count
-- FROM loadouts
-- ORDER BY updated_at DESC
-- LIMIT 10;
