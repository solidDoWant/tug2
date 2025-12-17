-- =====================================================
-- Medic Tracker - PostgreSQL Database Schema
-- Tracks medic performance and ban status
-- =====================================================

CREATE TABLE IF NOT EXISTS medics (
    steamId VARCHAR(64) NOT NULL PRIMARY KEY,
    banned BOOLEAN DEFAULT FALSE,
    medic_time INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

CREATE INDEX IF NOT EXISTS idx_medics_banned ON medics(banned);
CREATE INDEX IF NOT EXISTS idx_medics_medic_time ON medics(medic_time);

-- =====================================================
-- Example Data
-- =====================================================

-- Example medic entry:
-- INSERT INTO medics (steamId, banned, medic_time) VALUES (
--   '76561198012345678',
--   FALSE,             -- FALSE = not banned, TRUE = banned
--   3600               -- total seconds played as medic
-- ) ON CONFLICT (steamId) DO UPDATE SET medic_time = medics.medic_time + EXCLUDED.medic_time;

-- Ban a medic:
-- INSERT INTO medics (steamId, banned, medic_time) VALUES (
--   '76561198012345678',
--   TRUE,
--   0
-- ) ON CONFLICT (steamId) DO UPDATE SET banned = TRUE;

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all banned medics
-- SELECT steamId, medic_time, created_at, updated_at
-- FROM medics
-- WHERE banned = TRUE
-- ORDER BY created_at DESC;

-- View medics by playtime
-- SELECT steamId,
--        banned,
--        medic_time,
--        medic_time / 3600.0 as hours_played,
--        created_at
-- FROM medics
-- ORDER BY medic_time DESC;

-- Count banned vs unbanned medics
-- SELECT
--   SUM(CASE WHEN banned = TRUE THEN 1 ELSE 0 END) as banned_count,
--   SUM(CASE WHEN banned = FALSE THEN 1 ELSE 0 END) as active_count,
--   COUNT(*) as total_count
-- FROM medics;

-- Total medic playtime across all players
-- SELECT SUM(medic_time) as total_seconds,
--        SUM(medic_time) / 3600.0 as total_hours
-- FROM medics;

-- Unban a medic
-- UPDATE medics SET banned = FALSE WHERE steamId = '76561198012345678';
