-- =====================================================
-- Insurgency Loadout Saver - PostgreSQL Database Schema
-- =====================================================

CREATE TABLE IF NOT EXISTS loadouts (
    steam_id VARCHAR(32) NOT NULL,
    class_template VARCHAR(128) NOT NULL,
    item_type VARCHAR(16) NOT NULL,
    itemid TEXT,
    is_auto_saved BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    update_count INTEGER DEFAULT 0,
    PRIMARY KEY (steam_id, class_template, item_type)
);

CREATE INDEX IF NOT EXISTS idx_loadouts_steam_id ON loadouts(steam_id);
CREATE INDEX IF NOT EXISTS idx_loadouts_last_seen ON loadouts(last_seen_at);

-- =====================================================
-- Example Data (Semicolon-Separated IDs Format)
-- =====================================================

-- Example loadout entries using semicolon-separated theater item IDs:
-- INSERT INTO loadouts (steam_id, class_template, item_type, itemid, is_auto_saved) VALUES 
-- ('STEAM_0:1:12345678', 'template_rifleman_security_coop', 'gear', '39;47', false),
-- ('STEAM_0:1:12345678', 'template_rifleman_security_coop', 'primary', '5;12;13;14', false),
-- ('STEAM_0:1:12345678', 'template_rifleman_security_coop', 'secondary', '8;15', false),
-- ('STEAM_0:1:12345678', 'template_rifleman_security_coop', 'explosive', '20', false);

-- Format explanation:
--   item_type 'gear':      semicolon-separated gear IDs (armor, head, vest, accessory, perk, misc)
--   item_type 'primary':   weapon ID followed by upgrade IDs (weapon_id;upgrade1;upgrade2;...)
--   item_type 'secondary': weapon ID followed by upgrade IDs (weapon_id;upgrade1;upgrade2;...)
--   item_type 'explosive': weapon ID followed by upgrade IDs (weapon_id;upgrade1;upgrade2;...)

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- Delete old loadouts (not seen in 30 days)
-- DELETE FROM loadouts WHERE last_seen_at < NOW() - INTERVAL '30 days';

-- Count total loadouts per player
-- SELECT steam_id, COUNT(DISTINCT class_template) as loadout_count 
-- FROM loadouts 
-- GROUP BY steam_id 
-- ORDER BY loadout_count DESC;

-- View most recently updated loadouts
-- SELECT steam_id, class_template, item_type, itemid, updated_at, update_count
-- FROM loadouts
-- ORDER BY updated_at DESC
-- LIMIT 10;
