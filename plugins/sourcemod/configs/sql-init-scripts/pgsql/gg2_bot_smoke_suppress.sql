-- =====================================================
-- Bot smoke suppression - player warning tracking
-- =====================================================
-- One row per player, counting how many times they have been shown the on-screen warning that bots
-- may fire blindly into smoke. The mechanic is not part of the base game, so a player who walks into
-- a cloud and gets shot has no way to know that was deliberate; this makes sure they are told, and
-- equally makes sure regulars stop being told.
--
-- The row is never deleted when it ages out. sm_bot_smoke_suppress_warn_forget_days (90 by default)
-- is applied at read and write time instead: a player whose last warning is older than the window
-- is treated as new and starts counting again, while the row stays as history. That way someone
-- returning after a long break gets the explanation once more without losing when they first saw it.

CREATE TABLE IF NOT EXISTS smoke_warning_seen (
    steam_id BIGINT PRIMARY KEY,
    shown_count INTEGER NOT NULL DEFAULT 0,
    first_shown_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_shown_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- The plugin reads by primary key on connect and upserts on show, so the key is the only index the
-- hot path needs. This one is for the maintenance queries below.
CREATE INDEX IF NOT EXISTS idx_smoke_warning_seen_last_shown ON smoke_warning_seen(last_shown_at);

-- =====================================================
-- Maintenance
-- =====================================================

-- Who is still being warned, and who has been capped out
-- SELECT steam_id, shown_count, last_shown_at FROM smoke_warning_seen ORDER BY shown_count DESC LIMIT 20;

-- Players who will be warned again because they have been away longer than the forget window
-- SELECT steam_id, shown_count, last_shown_at FROM smoke_warning_seen
-- WHERE last_shown_at < NOW() - INTERVAL '90 days';

-- Show the warning to everyone again, e.g. after changing what the mechanic does
-- TRUNCATE smoke_warning_seen;
