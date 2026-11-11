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

-- Lifetime revives and full heals (issue #10). Counted since 2026-11; before that they were shown at
-- round end and then discarded.
ALTER TABLE medics ADD COLUMN IF NOT EXISTS heals INTEGER NOT NULL DEFAULT 0;
ALTER TABLE medics ADD COLUMN IF NOT EXISTS revives INTEGER NOT NULL DEFAULT 0;

-- What each player added to medics, with when, for stats over a period. Written in the same
-- statement as the medics update.
CREATE TABLE IF NOT EXISTS medic_rounds (
    id BIGSERIAL PRIMARY KEY,
    steam_id VARCHAR(64) NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    medic_time INTEGER NOT NULL DEFAULT 0,
    heals INTEGER NOT NULL DEFAULT 0,
    revives INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_medic_rounds_recorded_at ON medic_rounds(recorded_at);
CREATE INDEX IF NOT EXISTS idx_medic_rounds_steam_id_recorded_at ON medic_rounds(steam_id, recorded_at);

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

-- Descriptions for the Discord bot's query_stats tool, which shows the comments of the tables it can
-- read to the model writing SQL against them (tools/discord-bot). Keep them accurate and short, and
-- describe every column: what it counts, its units, and any trap in how it joins or is stored.
COMMENT ON TABLE medics IS 'Time each player has spent playing medic, and their revives and full heals.';
COMMENT ON COLUMN medics.steamid IS 'SteamID64 as text (player_stats.steam_id). Note the column name has no underscore.';
COMMENT ON COLUMN medics.banned IS 'Unused leftover; always false. Medic bans are kept elsewhere.';
COMMENT ON COLUMN medics.medic_time IS 'Seconds played as medic.';
COMMENT ON COLUMN medics.created_at IS 'First time as medic (UTC).';
COMMENT ON COLUMN medics.updated_at IS 'Last update (UTC).';
COMMENT ON COLUMN medics.heals IS 'Heals to full health given, as medic or not. Counted since 2026-11.';
COMMENT ON COLUMN medics.revives IS 'Revives completed, as medic or not. Counted since 2026-11.';

COMMENT ON TABLE medic_rounds IS 'What each player added to medics, with when: sum over recorded_at for medic stats over a period. Usually one row per player per round. Recorded since 2026-11.';
COMMENT ON COLUMN medic_rounds.id IS 'Row key.';
COMMENT ON COLUMN medic_rounds.steam_id IS 'SteamID64 as text (player_stats.steam_id).';
COMMENT ON COLUMN medic_rounds.recorded_at IS 'When recorded: round end, leaving, or switching away from medic (UTC).';
COMMENT ON COLUMN medic_rounds.medic_time IS 'Seconds played as medic.';
COMMENT ON COLUMN medic_rounds.heals IS 'Heals to full health given.';
COMMENT ON COLUMN medic_rounds.revives IS 'Revives completed.';
