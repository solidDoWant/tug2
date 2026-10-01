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
