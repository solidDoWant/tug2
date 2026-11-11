-- =====================================================
-- gg2_fuckyeah - per-player kill voice line opt-out
-- =====================================================
-- One row per player who has used !fy: TRUE = opted out (their kills stay silent and they hear no
-- one else's), FALSE = opted back in. Players with no row are opted in.

CREATE TABLE IF NOT EXISTS player_fy_opt_out (
    steam_id BIGINT PRIMARY KEY,
    opt_out BOOLEAN NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Maintenance
-- =====================================================

-- How many players have opted out
-- SELECT opt_out, COUNT(*) FROM player_fy_opt_out GROUP BY opt_out;

-- Opt everyone back in
-- TRUNCATE player_fy_opt_out;

-- Descriptions for the Discord bot's query_stats tool, which shows the comments of the tables it can
-- read to the model writing SQL against them (tools/discord-bot). Keep them accurate and short, and
-- describe every column: what it counts, its units, and any trap in how it joins or is stored.
COMMENT ON TABLE player_fy_opt_out IS 'Players who changed whether they hear the kill yell sounds. Players who never changed it have no row.';
COMMENT ON COLUMN player_fy_opt_out.steam_id IS 'SteamID64 as bigint.';
COMMENT ON COLUMN player_fy_opt_out.opt_out IS 'True when the player turned the yells off.';
COMMENT ON COLUMN player_fy_opt_out.created_at IS 'First change (UTC).';
COMMENT ON COLUMN player_fy_opt_out.updated_at IS 'Last change (UTC).';
