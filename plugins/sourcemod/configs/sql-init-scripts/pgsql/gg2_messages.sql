-- =====================================================
-- GG2 Messages System - PostgreSQL Database Schema
-- Manages rotating player/admin messages and join messages
-- =====================================================

-- Table for rotating messages shown to all players
CREATE TABLE IF NOT EXISTS gg2_messages_rotating_player (
    id SERIAL PRIMARY KEY,
    message VARCHAR(256) NOT NULL UNIQUE,
    enabled BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Table for rotating messages shown only to admins
CREATE TABLE IF NOT EXISTS gg2_messages_rotating_admin (
    id SERIAL PRIMARY KEY,
    message VARCHAR(256) NOT NULL UNIQUE,
    enabled BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Table for messages shown to players on first connect
CREATE TABLE IF NOT EXISTS gg2_messages_join_player (
    id SERIAL PRIMARY KEY,
    message VARCHAR(256) NOT NULL UNIQUE,
    enabled BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

-- Indexes on gg2_messages_rotating_player
CREATE INDEX IF NOT EXISTS idx_gg2_messages_rotating_player_enabled
    ON gg2_messages_rotating_player(enabled) WHERE enabled = TRUE;
CREATE INDEX IF NOT EXISTS idx_gg2_messages_rotating_player_id
    ON gg2_messages_rotating_player(id ASC);

-- Indexes on gg2_messages_rotating_admin
CREATE INDEX IF NOT EXISTS idx_gg2_messages_rotating_admin_enabled
    ON gg2_messages_rotating_admin(enabled) WHERE enabled = TRUE;
CREATE INDEX IF NOT EXISTS idx_gg2_messages_rotating_admin_id
    ON gg2_messages_rotating_admin(id ASC);

-- Indexes on gg2_messages_join_player
CREATE INDEX IF NOT EXISTS idx_gg2_messages_join_player_enabled
    ON gg2_messages_join_player(enabled) WHERE enabled = TRUE;
CREATE INDEX IF NOT EXISTS idx_gg2_messages_join_player_id
    ON gg2_messages_join_player(id ASC);

-- =====================================================
-- Initial Data
-- Translatable message keys reference tug.phrases
-- =====================================================

-- Rotating player messages
INSERT INTO gg2_messages_rotating_player (id, message, enabled) VALUES
  (1, '{dodgerblue}Slava{default} {yellow}Ukraini!{default}', TRUE),
  (2, 'dontbeadick', TRUE),
  (3, 'findresupply', TRUE),
  (4, 'dragbodies', TRUE),
  (5, 'getsmoke', TRUE),
  (6, 'protip_web_link', TRUE),
  (7, 'protip_revenge_kill', TRUE),
  (8, 'protip_push_cp_bot_spawn', TRUE),
  (9, 'tip_sound_broken', TRUE),
  (10, 'tip_smoke_broken_missing_models', TRUE),
  (11, 'tip_machinegun_etiquette', TRUE),
  (12, 'tip_calladmin', TRUE),
  (13, 'tip_medics_do_medic_shit', TRUE),
  (14, 'tip_server_missing', TRUE),
  (15, 'catchfire', TRUE),
  (16, 'tip_stats_reset', TRUE),
  (17, 'Join us on Discord at https://discord.gg/RAQgnjeQuE', TRUE),
  (18, 'Report issues on Discord or at https://github.com/solidDoWant/tug2', TRUE),
  (1000, 'protip_stuck', TRUE),
  (1001, 'protip_good_bad_medics', TRUE),
  (1002, 'callmedic', TRUE),
  (1003, 'tip_stop_pushing', TRUE),
  (1004, 'protip_show_compass', TRUE)
ON CONFLICT (id) DO UPDATE SET
  message = EXCLUDED.message,
  enabled = EXCLUDED.enabled,
  updated_at = CURRENT_TIMESTAMP;

-- Rotating admin messages
INSERT INTO gg2_messages_rotating_admin (id, message, enabled) VALUES
  (1, '{gold}Admins:{default} use {green}sm_admin{default} in console to bring up the admin menu (kick/ban idiots, etc)', TRUE),
  (2, '{gold}Admins:{default} use {green}sm_spec{default} {red}playerName{default} in console to send a player to Spectator (great for shit ass medics)', TRUE),
  (3, '{gold}Admins:{common} Remember: your job is to keep others from being {red}dicks{common}, not to be one yourself.', TRUE),
  (4, '{gold}Admins:{common} Don''t fuck with the gravity. If you do, let ATT know so they can fix it.', TRUE),
  (5, '{gold}Admins:{common} Players can be banned from the medic slots with {green}sm_ban_medic{default} {red}playerName{default}.', TRUE)
ON CONFLICT (id) DO UPDATE SET
  message = EXCLUDED.message,
  enabled = EXCLUDED.enabled,
  updated_at = CURRENT_TIMESTAMP;

-- Join player messages (shown once on first spawn)
INSERT INTO gg2_messages_join_player (id, message, enabled) VALUES
  (1, 'join_message_racism', TRUE),
  (2, 'join_message_medics', TRUE),
  (3, 'join_message_stupid', TRUE),
  (4, 'join_message_play_objectives', TRUE),
  (5, 'join_message_ahead_of_team', TRUE),
  (6, 'join_message_accepted_rules', TRUE)
ON CONFLICT (id) DO UPDATE SET
  message = EXCLUDED.message,
  enabled = EXCLUDED.enabled,
  updated_at = CURRENT_TIMESTAMP;

-- =====================================================
-- Example Data (for reference)
-- =====================================================

-- Example rotating player messages:
-- INSERT INTO gg2_messages_rotating_player (message, enabled) VALUES
--   ('{red}PROTIP:{default} Use smoke grenades to obscure enemy vision!', TRUE),
--   ('{red}PROTIP:{default} Press E to drag wounded teammates to safety', TRUE),
--   ('{red}REMINDER:{default} Follow server rules and be respectful', TRUE),
--   ('getsmoke', TRUE),  -- Translatable message key
--   ('dragbodies', TRUE) -- Translatable message key
-- ON CONFLICT DO NOTHING;

-- Example admin messages:
-- INSERT INTO gg2_messages_rotating_admin (message, enabled) VALUES
--   ('{gold}[ADMIN]:{default} Remember to monitor chat for rule violations', TRUE),
--   ('{gold}[ADMIN]:{default} Use !admin menu for quick moderation actions', TRUE)
-- ON CONFLICT DO NOTHING;

-- Example join messages (shown in insertion order by ID):
-- INSERT INTO gg2_messages_join_player (message, enabled) VALUES
--   ('{dodgerblue}Welcome to the server!{default}', TRUE),
--   ('Join our Discord: discord.gg/example', TRUE),
--   ('{yellow}Type !help for available commands{default}', TRUE),
--   ('dontbeadick', TRUE),  -- Translatable message key
--   ('findresupply', TRUE)  -- Translatable message key
-- ON CONFLICT DO NOTHING;

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View all enabled rotating player messages
-- SELECT id, message, created_at
-- FROM gg2_messages_rotating_player
-- WHERE enabled
-- ORDER BY id ASC;

-- View all enabled admin messages
-- SELECT id, message, created_at
-- FROM gg2_messages_rotating_admin
-- WHERE enabled
-- ORDER BY id ASC;

-- View join messages in ID order
-- SELECT id, message, created_at
-- FROM gg2_messages_join_player
-- WHERE enabled
-- ORDER BY id ASC;

-- Count messages by type
-- SELECT
--     'rotating_player' as type,
--     COUNT(*) as total,
--     COUNT(*) FILTER (WHERE enabled) as enabled_count
-- FROM gg2_messages_rotating_player
-- UNION ALL
-- SELECT
--     'rotating_admin' as type,
--     COUNT(*) as total,
--     COUNT(*) FILTER (WHERE enabled) as enabled_count
-- FROM gg2_messages_rotating_admin
-- UNION ALL
-- SELECT
--     'join_player' as type,
--     COUNT(*) as total,
--     COUNT(*) FILTER (WHERE enabled) as enabled_count
-- FROM gg2_messages_join_player;

-- Disable a specific message (example)
-- UPDATE gg2_messages_rotating_player
-- SET enabled = FALSE, updated_at = CURRENT_TIMESTAMP
-- WHERE id = 1;

-- Re-enable a message (example)
-- UPDATE gg2_messages_rotating_player
-- SET enabled = TRUE, updated_at = CURRENT_TIMESTAMP
-- WHERE id = 1;

-- Add a new rotating player message
-- INSERT INTO gg2_messages_rotating_player (message, enabled)
-- VALUES ('{red}NEW MESSAGE:{default} Your message here', TRUE);

-- Update message text
-- UPDATE gg2_messages_rotating_player
-- SET message = '{red}UPDATED:{default} New text here',
--     updated_at = CURRENT_TIMESTAMP
-- WHERE id = 1;

-- Delete old disabled messages
-- DELETE FROM gg2_messages_rotating_player
-- WHERE enabled = FALSE
--   AND updated_at < NOW() - INTERVAL '6 months';

-- =====================================================
-- Notes
-- =====================================================

-- Message Format:
--   - Messages can use color codes like {red}, {blue}, {yellow}, {dodgerblue}, {gold}, {default}
--   - Messages without spaces are treated as translation keys (e.g., 'dontbeadick')
--   - Regular messages are displayed as-is with color parsing
--
-- Plugin Behavior:
--   - Rotating player messages: Shown every 30 seconds to all players
--   - Rotating admin messages: Shown every 120 seconds to admins only (team 2)
--   - Join messages: Shown once on first spawn to new players
--   - Plugin queries: SELECT message FROM table WHERE enabled ORDER BY id ASC LIMIT 64
--
-- Performance:
--   - Max 64 messages per table (enforced by plugin)
--   - Messages are cached in-game and reloaded every 5 minutes
--   - Partial indexes on 'enabled' for query optimization
