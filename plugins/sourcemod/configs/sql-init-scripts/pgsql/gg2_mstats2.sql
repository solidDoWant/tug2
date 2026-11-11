-- =====================================================
-- GG2 MSTATS2 System - PostgreSQL Database Schema
-- Tracks player stats, weapon kills, map stats, and match history
-- =====================================================

CREATE TABLE IF NOT EXISTS player_stats (
    steam_id VARCHAR(64) PRIMARY KEY,
    kills INTEGER DEFAULT 0,
    deaths INTEGER DEFAULT 0,
    suicides INTEGER DEFAULT 0,
    headshot_given INTEGER DEFAULT 0,
    headshot_taken INTEGER DEFAULT 0,
    suppressions INTEGER DEFAULT 0,
    caps INTEGER DEFAULT 0,
    killstreak INTEGER DEFAULT 0,
    score INTEGER DEFAULT 0,
    wins INTEGER DEFAULT 0,
    losses INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- The player's most recent in-game name, refreshed whenever the plugin records them, so the stats
-- can be searched and shown by name rather than only by SteamID. NULL for players last seen before
-- this column existed, until they next connect.
ALTER TABLE player_stats ADD COLUMN IF NOT EXISTS name VARCHAR(128);

CREATE TABLE IF NOT EXISTS weapon_stats (
    weapon_id SERIAL PRIMARY KEY,
    weapon_name VARCHAR(64) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS player_kills (
    steam_id VARCHAR(64) NOT NULL,
    weapon_id INTEGER NOT NULL,
    kill_count INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (steam_id, weapon_id),
    FOREIGN KEY (steam_id) REFERENCES player_stats(steam_id) ON DELETE CASCADE,
    FOREIGN KEY (weapon_id) REFERENCES weapon_stats(weapon_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS bot_kills (
    bot_name VARCHAR(129) NOT NULL,
    weapon_id INTEGER NOT NULL,
    kill_count INTEGER DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (bot_name, weapon_id),
    FOREIGN KEY (weapon_id) REFERENCES weapon_stats(weapon_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS map_stats (
    map_id SERIAL PRIMARY KEY,
    map_name VARCHAR(257) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS win_loss_log (
    id SERIAL PRIMARY KEY,
    map_id INTEGER NOT NULL,
    win BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (map_id) REFERENCES map_stats(map_id) ON DELETE CASCADE
);

-- =====================================================
-- Indexes for Performance
-- =====================================================

-- Indexes on player_stats
CREATE INDEX IF NOT EXISTS idx_player_stats_created_at ON player_stats(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_player_stats_updated_at ON player_stats(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_player_stats_kills ON player_stats(kills DESC);
CREATE INDEX IF NOT EXISTS idx_player_stats_kd_ratio ON player_stats(kills, deaths) WHERE deaths > 0;
CREATE INDEX IF NOT EXISTS idx_player_stats_score ON player_stats(score DESC);
CREATE INDEX IF NOT EXISTS idx_player_stats_killstreak ON player_stats(killstreak DESC);
CREATE INDEX IF NOT EXISTS idx_player_stats_wins ON player_stats(wins DESC);

-- Indexes on weapon_stats
CREATE INDEX IF NOT EXISTS idx_weapon_stats_weapon_name ON weapon_stats(weapon_name);

-- Indexes on player_kills
CREATE INDEX IF NOT EXISTS idx_player_kills_weapon_id ON player_kills(weapon_id);
CREATE INDEX IF NOT EXISTS idx_player_kills_kill_count ON player_kills(kill_count DESC);

-- Indexes on bot_kills
CREATE INDEX IF NOT EXISTS idx_bot_kills_weapon_id ON bot_kills(weapon_id);
CREATE INDEX IF NOT EXISTS idx_bot_kills_kill_count ON bot_kills(kill_count DESC);

-- Indexes on map_stats
CREATE INDEX IF NOT EXISTS idx_map_stats_map_name ON map_stats(map_name);

-- Indexes on win_loss_log
CREATE INDEX IF NOT EXISTS idx_win_loss_log_map_id ON win_loss_log(map_id);
CREATE INDEX IF NOT EXISTS idx_win_loss_log_created_at ON win_loss_log(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_win_loss_log_win ON win_loss_log(win);

-- =====================================================
-- Example Data
-- =====================================================

-- Example player stats:
-- INSERT INTO player_stats (steam_id, kills, deaths, score, wins, losses) VALUES (
--   '76561198012345678',
--   1500,
--   800,
--   45000,
--   125,
--   75
-- ) ON CONFLICT (steam_id) DO NOTHING;
-- Note: created_at and updated_at are automatically set by the database

-- Example weapon:
-- INSERT INTO weapon_stats (weapon_name) VALUES ('weapon_m4a1') ON CONFLICT (weapon_name) DO NOTHING;

-- Example player weapon kills (using weapon_id from weapon_stats table):
-- INSERT INTO player_kills (steam_id, weapon_id, kill_count)
-- SELECT '76561198012345678', weapon_id, 450
-- FROM weapon_stats WHERE weapon_name = 'weapon_m4a1'
-- ON CONFLICT (steam_id, weapon_id) DO UPDATE SET kill_count = player_kills.kill_count + 450;

-- Example bot weapon kills (using weapon_id from weapon_stats table):
-- INSERT INTO bot_kills (bot_name, weapon_id, kill_count)
-- SELECT 'BotJohn', weapon_id, 120
-- FROM weapon_stats WHERE weapon_name = 'weapon_ak47'
-- ON CONFLICT (bot_name, weapon_id) DO UPDATE SET kill_count = bot_kills.kill_count + 120;

-- Example map:
-- INSERT INTO map_stats (map_name) VALUES ('ministry') ON CONFLICT (map_name) DO NOTHING;
-- Note: Map wins/losses are derived from win_loss_log, not stored in map_stats table

-- =====================================================
-- Maintenance Queries
-- =====================================================

-- View top players by K/D ratio (min 100 kills)
-- SELECT
--     steam_id,
--     kills,
--     deaths,
--     ROUND(kills::NUMERIC / NULLIF(deaths, 0), 2) as kd_ratio,
--     score,
--     created_at as first_seen,
--     updated_at as last_seen
-- FROM player_stats
-- WHERE kills >= 100
-- ORDER BY kd_ratio DESC
-- LIMIT 20;

-- View top players by score
-- SELECT
--     steam_id,
--     score,
--     kills,
--     deaths,
--     wins,
--     losses,
--     created_at as first_seen,
--     updated_at as last_seen
-- FROM player_stats
-- ORDER BY score DESC
-- LIMIT 20;

-- View top players by killstreak
-- SELECT
--     steam_id,
--     killstreak,
--     kills,
--     deaths,
--     created_at as first_seen,
--     updated_at as last_seen
-- FROM player_stats
-- WHERE killstreak > 0
-- ORDER BY killstreak DESC
-- LIMIT 20;

-- View most popular weapons (by player kills)
-- SELECT
--     w.weapon_name,
--     SUM(pk.kill_count) as total_kills,
--     COUNT(DISTINCT pk.steam_id) as unique_players
-- FROM player_kills pk
-- JOIN weapon_stats w ON pk.weapon_id = w.weapon_id
-- GROUP BY w.weapon_name
-- ORDER BY total_kills DESC
-- LIMIT 20;

-- View player weapon proficiency
-- SELECT
--     p.steam_id,
--     w.weapon_name,
--     pk.kill_count,
--     ROUND(100.0 * pk.kill_count / NULLIF(p.kills, 0), 2) as kill_percentage
-- FROM player_kills pk
-- JOIN player_stats p ON pk.steam_id = p.steam_id
-- JOIN weapon_stats w ON pk.weapon_id = w.weapon_id
-- WHERE p.steam_id = '76561198012345678'  -- Replace with actual steam_id
-- ORDER BY pk.kill_count DESC;

-- View map statistics
-- SELECT
--     m.map_name,
--     COUNT(*) FILTER (WHERE wll.win = TRUE) as wins,
--     COUNT(*) FILTER (WHERE wll.win = FALSE) as losses,
--     COUNT(*) as total_rounds,
--     ROUND(100.0 * COUNT(*) FILTER (WHERE wll.win = TRUE) / NULLIF(COUNT(*), 0), 2) as win_percentage
-- FROM win_loss_log wll
-- JOIN map_stats m ON wll.map_id = m.map_id
-- GROUP BY m.map_name
-- ORDER BY total_rounds DESC;

-- View recent match history
-- SELECT
--     m.map_name,
--     wll.created_at as match_time,
--     CASE WHEN wll.win THEN 'WIN' ELSE 'LOSS' END as result
-- FROM win_loss_log wll
-- JOIN map_stats m ON wll.map_id = m.map_id
-- ORDER BY wll.created_at DESC
-- LIMIT 50;

-- View map win rate over time
-- SELECT
--     m.map_name,
--     COUNT(*) as total_matches,
--     COUNT(*) FILTER (WHERE wll.win = TRUE) as wins,
--     COUNT(*) FILTER (WHERE wll.win = FALSE) as losses,
--     ROUND(100.0 * COUNT(*) FILTER (WHERE wll.win = TRUE) / NULLIF(COUNT(*), 0), 2) as win_rate
-- FROM win_loss_log wll
-- JOIN map_stats m ON wll.map_id = m.map_id
-- WHERE wll.created_at > NOW() - INTERVAL '30 days'
-- GROUP BY m.map_name
-- ORDER BY total_matches DESC;

-- View headshot accuracy
-- SELECT
--     steam_id,
--     headshot_given,
--     kills,
--     ROUND(100.0 * headshot_given / NULLIF(kills, 0), 2) as headshot_percentage
-- FROM player_stats
-- WHERE kills >= 50
-- ORDER BY headshot_percentage DESC
-- LIMIT 20;

-- View suppression leaders
-- SELECT
--     steam_id,
--     suppressions,
--     kills,
--     ROUND(suppressions::NUMERIC / NULLIF(kills, 0), 2) as suppressions_per_kill
-- FROM player_stats
-- WHERE suppressions > 0
-- ORDER BY suppressions DESC
-- LIMIT 20;

-- View objective players (caps)
-- SELECT
--     steam_id,
--     caps,
--     kills,
--     score,
--     created_at as first_seen,
--     updated_at as last_seen
-- FROM player_stats
-- WHERE caps > 0
-- ORDER BY caps DESC
-- LIMIT 20;

-- Clean up old win/loss log entries (older than 1 year)
-- DELETE FROM win_loss_log
-- WHERE created_at < NOW() - INTERVAL '1 year';

-- Clean up inactive players (not seen in 1 year)
-- DELETE FROM player_stats
-- WHERE updated_at < NOW() - INTERVAL '1 year';

-- Descriptions for the Discord bot's query_stats tool, which shows the comments of the tables it can
-- read to the model writing SQL against them (tools/discord-bot). Keep them accurate and short, and
-- describe every column: what it counts, its units, and any trap in how it joins or is stored.
COMMENT ON TABLE player_stats IS 'Lifetime stats, one row per player (humans only; bots are in bot_kills).';
COMMENT ON COLUMN player_stats.steam_id IS 'SteamID64 as text. The player key in every table; some tables store it as bigint, so cast to join.';
COMMENT ON COLUMN player_stats.name IS 'Latest Steam name (the name shown in game); NULL if never recorded.';
COMMENT ON COLUMN player_stats.kills IS 'Kills of enemies (bots).';
COMMENT ON COLUMN player_stats.deaths IS 'Deaths, from any cause.';
COMMENT ON COLUMN player_stats.suicides IS 'Suicides.';
COMMENT ON COLUMN player_stats.headshot_given IS 'Headshots landed on enemies.';
COMMENT ON COLUMN player_stats.headshot_taken IS 'Headshots taken from enemies.';
COMMENT ON COLUMN player_stats.suppressions IS 'Times the player suppressed an enemy.';
COMMENT ON COLUMN player_stats.caps IS 'Objectives taken: control points captured plus caches destroyed.';
COMMENT ON COLUMN player_stats.killstreak IS 'Best killstreak ever (a maximum, not a total).';
COMMENT ON COLUMN player_stats.score IS 'In-game score earned, summed over all rounds.';
COMMENT ON COLUMN player_stats.wins IS 'Rounds the player was in when the players won.';
COMMENT ON COLUMN player_stats.losses IS 'Rounds the player was in when the players lost.';
COMMENT ON COLUMN player_stats.created_at IS 'First seen (UTC).';
COMMENT ON COLUMN player_stats.updated_at IS 'Last stats update, roughly last seen (UTC).';

COMMENT ON TABLE weapon_stats IS 'Weapon names, keyed by weapon_id for player_kills and bot_kills.';
COMMENT ON COLUMN weapon_stats.weapon_id IS 'Weapon key.';
COMMENT ON COLUMN weapon_stats.weapon_name IS 'Name without the weapon_ prefix (ak74, m4a1). Explosives are named by projectile: rocket_rpg7, grenade_m67, grenade_c4.';
COMMENT ON COLUMN weapon_stats.created_at IS 'When the weapon was first seen (UTC).';

COMMENT ON TABLE player_kills IS 'Each player''s lifetime kills per weapon.';
COMMENT ON COLUMN player_kills.steam_id IS 'SteamID64 as text (player_stats.steam_id).';
COMMENT ON COLUMN player_kills.weapon_id IS 'weapon_stats.weapon_id.';
COMMENT ON COLUMN player_kills.kill_count IS 'Kills with this weapon.';
COMMENT ON COLUMN player_kills.created_at IS 'First kill with this weapon (UTC).';
COMMENT ON COLUMN player_kills.updated_at IS 'Last update (UTC).';

COMMENT ON TABLE bot_kills IS 'Kills by AI bots, per bot name and weapon. Bot names repeat across rounds, so a name is not one bot.';
COMMENT ON COLUMN bot_kills.bot_name IS 'The bot''s in-game name.';
COMMENT ON COLUMN bot_kills.weapon_id IS 'weapon_stats.weapon_id.';
COMMENT ON COLUMN bot_kills.kill_count IS 'Kills with this weapon.';
COMMENT ON COLUMN bot_kills.created_at IS 'First kill (UTC).';
COMMENT ON COLUMN bot_kills.updated_at IS 'Last update (UTC).';

COMMENT ON TABLE map_stats IS 'Map names, keyed by map_id for win_loss_log.';
COMMENT ON COLUMN map_stats.map_id IS 'Map key.';
COMMENT ON COLUMN map_stats.map_name IS 'Map name, as in the maps table.';
COMMENT ON COLUMN map_stats.created_at IS 'When the map was first played (UTC).';

COMMENT ON TABLE win_loss_log IS 'One row per round played.';
COMMENT ON COLUMN win_loss_log.id IS 'Row key.';
COMMENT ON COLUMN win_loss_log.map_id IS 'map_stats.map_id.';
COMMENT ON COLUMN win_loss_log.win IS 'True when the players won the round.';
COMMENT ON COLUMN win_loss_log.created_at IS 'When the round ended (UTC).';
