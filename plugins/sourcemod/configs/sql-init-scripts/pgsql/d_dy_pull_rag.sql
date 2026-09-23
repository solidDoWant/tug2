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
