-- =====================================================
-- GG2 TeamKill System - PostgreSQL Database Schema
-- Tracks teamkill incidents and player statistics
-- =====================================================

CREATE TABLE IF NOT EXISTS player_tks (
    steam_id BIGINT PRIMARY KEY,
    -- Kill counts are NOT stored here. They live in player_stats.kills (see gg2_mstats2.sql);
    -- the amnesty and offender queries join that table for them.
    tk_given INTEGER DEFAULT 0,
    tk_taken INTEGER DEFAULT 0,
    last_seen TIMESTAMP DEFAULT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS player_tk_logs (
    id SERIAL PRIMARY KEY,
    victim_steam_id BIGINT NOT NULL REFERENCES player_tks(steam_id) ON DELETE CASCADE,
    attacker_steam_id BIGINT NOT NULL REFERENCES player_tks(steam_id) ON DELETE CASCADE,
    forgiven BOOLEAN DEFAULT FALSE,
    weapon VARCHAR(64),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Migrations
-- =====================================================

-- player_tks.kills was dead weight: nothing ever wrote it, so it sat at 0 and silently broke
-- both queries that read it (no player was ever granted amnesty or flagged as an offender).
-- Both now read player_stats.kills instead, as does the stats API, so the column is unused.
-- Dropping it also drops idx_player_tks_offender_ratio, which indexed it.
ALTER TABLE player_tks DROP COLUMN IF EXISTS kills;

-- =====================================================
-- Indexes for Performance
-- =====================================================

-- Indexes on player_tks
CREATE INDEX IF NOT EXISTS idx_player_tks_last_seen ON player_tks(last_seen);
-- The amnesty and offender ratio indexes covered player_tks.kills. Both queries now look
-- players up by primary key in player_stats and player_tks instead, so neither is needed.
DROP INDEX IF EXISTS idx_player_tks_amnesty_ratio;

-- Indexes on player_tk_logs
CREATE INDEX IF NOT EXISTS idx_player_tk_logs_victim_steam_id ON player_tk_logs(victim_steam_id);
CREATE INDEX IF NOT EXISTS idx_player_tk_logs_attacker_steam_id ON player_tk_logs(attacker_steam_id);
CREATE INDEX IF NOT EXISTS idx_player_tk_logs_forgiven ON player_tk_logs(forgiven);
CREATE INDEX IF NOT EXISTS idx_player_tk_logs_created_at ON player_tk_logs(created_at DESC);

-- =====================================================
-- Example Data
-- =====================================================

-- Example player with amnesty-qualifying stats. The kills side of the ratio comes from
-- player_stats, so both rows are needed:
-- INSERT INTO player_stats (steam_id, kills) VALUES (
--   '76561198012345678',
--   10000
-- ) ON CONFLICT (steam_id) DO NOTHING;
-- INSERT INTO player_tks (steam_id, tk_given, last_seen) VALUES (
--   76561198012345678,
--   35,
--   CURRENT_TIMESTAMP  -- last seen now (k/tk ratio ~286, qualifies for amnesty)
-- ) ON CONFLICT (steam_id) DO NOTHING;

-- Example teamkill incident:
-- INSERT INTO player_tk_logs (victim_steam_id, attacker_steam_id, forgiven, weapon)
-- VALUES (
--   76561198012345678,
--   76561198087654321,
--   FALSE,
--   'weapon_m4a1'
-- );

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View players with TK amnesty (same logic as plugin)
-- SELECT ps.steam_id, ps.kills, pt.tk_given,
--        ROUND(ps.kills::NUMERIC / NULLIF(pt.tk_given, 0), 2) as kill_to_tk_ratio,
--        pt.last_seen
-- FROM player_stats ps
-- JOIN player_tks pt ON pt.steam_id::TEXT = ps.steam_id
-- WHERE ps.kills >= 1000
--   AND pt.tk_given > 0
--   AND (ps.kills::NUMERIC / pt.tk_given) > 250
--   AND pt.last_seen > NOW() - INTERVAL '90 days'
-- ORDER BY kill_to_tk_ratio DESC;

-- View known TK offenders (same logic as plugin)
-- SELECT ps.steam_id, ps.kills, pt.tk_given,
--        ROUND(ps.kills::NUMERIC / NULLIF(pt.tk_given, 0), 2) as kill_to_tk_ratio,
--        pt.last_seen
-- FROM player_stats ps
-- JOIN player_tks pt ON pt.steam_id::TEXT = ps.steam_id
-- WHERE ps.kills >= 500
--   AND pt.tk_given > 0
--   AND (ps.kills::NUMERIC / pt.tk_given) < 100
--   AND pt.last_seen > NOW() - INTERVAL '90 days'
-- ORDER BY kill_to_tk_ratio ASC;

-- View recent unforgiven teamkills
-- SELECT
--     tk.attacker_steam_id,
--     tk.victim_steam_id,
--     tk.weapon,
--     tk.created_at
-- FROM player_tk_logs tk
-- WHERE tk.forgiven = FALSE
-- ORDER BY tk.created_at DESC
-- LIMIT 50;

-- Count teamkills by player
-- SELECT
--     attacker_steam_id,
--     COUNT(*) as total_tks,
--     COUNT(*) FILTER (WHERE forgiven = TRUE) as forgiven_count,
--     COUNT(*) FILTER (WHERE forgiven = FALSE) as unforgiven_count
-- FROM player_tk_logs
-- GROUP BY attacker_steam_id
-- ORDER BY total_tks DESC
-- LIMIT 20;

-- Clean up old teamkill records (older than 6 months)
-- DELETE FROM player_tk_logs
-- WHERE created_at < NOW() - INTERVAL '6 months';

-- Descriptions for the Discord bot's query_stats tool, which shows the comments of the tables it can
-- read to the model writing SQL against them (tools/discord-bot). Keep them accurate and short, and
-- describe every column: what it counts, its units, and any trap in how it joins or is stored.
COMMENT ON TABLE player_tks IS 'Team kill totals per player.';
COMMENT ON COLUMN player_tks.steam_id IS 'SteamID64 as bigint: join with player_stats.steam_id = player_tks.steam_id::text.';
COMMENT ON COLUMN player_tks.tk_given IS 'Team kills the player made.';
COMMENT ON COLUMN player_tks.tk_taken IS 'Times the player was team killed.';
COMMENT ON COLUMN player_tks.last_seen IS 'Last time the player connected (UTC).';
COMMENT ON COLUMN player_tks.created_at IS 'First seen (UTC).';
COMMENT ON COLUMN player_tks.updated_at IS 'Last update (UTC).';

COMMENT ON TABLE player_tk_logs IS 'One row per team kill. Started later than the player_tks totals, so it holds fewer team kills than they count.';
COMMENT ON COLUMN player_tk_logs.id IS 'Row key.';
COMMENT ON COLUMN player_tk_logs.victim_steam_id IS 'SteamID64 as bigint of the player killed.';
COMMENT ON COLUMN player_tk_logs.attacker_steam_id IS 'SteamID64 as bigint of the player who killed them.';
COMMENT ON COLUMN player_tk_logs.forgiven IS 'True if the victim forgave the team kill.';
COMMENT ON COLUMN player_tk_logs.weapon IS 'Weapon used, named as in weapon_stats.';
COMMENT ON COLUMN player_tk_logs.created_at IS 'When the team kill happened (UTC).';
COMMENT ON COLUMN player_tk_logs.updated_at IS 'Last update, e.g. when forgiven (UTC).';
