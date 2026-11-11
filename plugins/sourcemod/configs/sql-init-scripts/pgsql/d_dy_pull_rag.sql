-- =====================================================
-- Pull Rag (body dragging) - per-player drag mode
-- =====================================================
-- One row per player who has picked a mode with !dragmode: TRUE = press sprint once to grab and again
-- to let go, FALSE = hold sprint to drag. Players with no row get the server's sm_pullrag_toggle, so
-- only an explicit choice is ever stored and changing the server default still moves everyone else.
--
-- Only used where sm_pullrag_allow_choice is on (the test server).

CREATE TABLE IF NOT EXISTS player_drag_mode (
    steam_id BIGINT PRIMARY KEY,
    toggle_drag BOOLEAN NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Maintenance
-- =====================================================

-- How many players prefer each mode
-- SELECT toggle_drag, COUNT(*) FROM player_drag_mode GROUP BY toggle_drag;

-- Put everyone back on the server default
-- TRUNCATE player_drag_mode;

-- Descriptions for the Discord bot's query_stats tool, which shows the comments of the tables it can
-- read to the model writing SQL against them (tools/discord-bot). Keep them accurate and short, and
-- describe every column: what it counts, its units, and any trap in how it joins or is stored.
COMMENT ON TABLE player_drag_mode IS 'Players who chose how dragging bodies works (!dragmode). Players who never chose have no row.';
COMMENT ON COLUMN player_drag_mode.steam_id IS 'SteamID64 as bigint.';
COMMENT ON COLUMN player_drag_mode.toggle_drag IS 'True for toggle mode, false for hold.';
COMMENT ON COLUMN player_drag_mode.created_at IS 'First choice (UTC).';
COMMENT ON COLUMN player_drag_mode.updated_at IS 'Last change (UTC).';
