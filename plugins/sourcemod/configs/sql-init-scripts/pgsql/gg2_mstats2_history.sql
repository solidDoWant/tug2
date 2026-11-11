-- Per-round history behind the lifetime totals in player_stats and player_kills / player_shots
-- (gg2_mstats2, issue #10), so stats can be shown for a period ("past 30 days"). Its own file because
-- gg2_mstats2.sql is close to DatabaseMigrator's 16 KB limit; run after gg2_mstats2 and
-- gg2_mstats2_shots.
--
-- Each time gg2_mstats2 adds a player's numbers to their lifetime totals - at each round end, and when
-- they leave or the map changes - it also inserts what it added here, in the same transaction, so a
-- period's sums and the lifetime totals can't disagree. Recorded since 2026-11; earlier play is only
-- in the lifetime totals.
CREATE TABLE IF NOT EXISTS player_rounds (
    id BIGSERIAL PRIMARY KEY,
    steam_id VARCHAR(64) NOT NULL,
    recorded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    map_name VARCHAR(128) NOT NULL DEFAULT '',
    kills INTEGER NOT NULL DEFAULT 0,
    deaths INTEGER NOT NULL DEFAULT 0,
    suicides INTEGER NOT NULL DEFAULT 0,
    headshot_given INTEGER NOT NULL DEFAULT 0,
    headshot_taken INTEGER NOT NULL DEFAULT 0,
    suppressions INTEGER NOT NULL DEFAULT 0,
    caps INTEGER NOT NULL DEFAULT 0,
    score INTEGER NOT NULL DEFAULT 0,
    wins INTEGER NOT NULL DEFAULT 0,
    losses INTEGER NOT NULL DEFAULT 0,
    killstreak INTEGER NOT NULL DEFAULT 0,
    play_time_seconds INTEGER NOT NULL DEFAULT 0,
    shots INTEGER NOT NULL DEFAULT 0,
    enemy_hits INTEGER NOT NULL DEFAULT 0,
    friendly_hits INTEGER NOT NULL DEFAULT 0,
    FOREIGN KEY (steam_id) REFERENCES player_stats(steam_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_player_rounds_recorded_at ON player_rounds(recorded_at);
CREATE INDEX IF NOT EXISTS idx_player_rounds_steam_id_recorded_at ON player_rounds(steam_id, recorded_at);

-- Weapons by their weapon_stats id, which is keyed by name: never the theater's id, which shifts
-- whenever the theater is edited (see LoadoutSaverSlots.md).
CREATE TABLE IF NOT EXISTS player_round_weapons (
    round_id BIGINT NOT NULL,
    weapon_id INTEGER NOT NULL,
    kills INTEGER NOT NULL DEFAULT 0,
    shots INTEGER NOT NULL DEFAULT 0,
    enemy_hits INTEGER NOT NULL DEFAULT 0,
    friendly_hits INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (round_id, weapon_id),
    FOREIGN KEY (round_id) REFERENCES player_rounds(id) ON DELETE CASCADE,
    FOREIGN KEY (weapon_id) REFERENCES weapon_stats(weapon_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_player_round_weapons_weapon_id ON player_round_weapons(weapon_id);

-- Descriptions for the Discord bot's query_stats tool (see gg2_mstats2.sql).
COMMENT ON TABLE player_rounds IS 'What each player added to their lifetime stats, round by round, with when: sum over recorded_at for stats over a period. Usually one row per player per round; leaving or a map change mid-round makes a partial row. Recorded since 2026-11, so a period before that is empty (lifetime totals cover all time).';
COMMENT ON COLUMN player_rounds.id IS 'Row key; player_round_weapons.round_id.';
COMMENT ON COLUMN player_rounds.steam_id IS 'SteamID64 as text (player_stats.steam_id).';
COMMENT ON COLUMN player_rounds.recorded_at IS 'When the numbers were recorded: the round end, or when the player left (UTC).';
COMMENT ON COLUMN player_rounds.map_name IS 'Map the round was played on (map_stats.map_name, maps.map_name).';
COMMENT ON COLUMN player_rounds.kills IS 'Kills of enemies (bots).';
COMMENT ON COLUMN player_rounds.deaths IS 'Deaths, from any cause.';
COMMENT ON COLUMN player_rounds.suicides IS 'Suicides.';
COMMENT ON COLUMN player_rounds.headshot_given IS 'Headshots landed on enemies.';
COMMENT ON COLUMN player_rounds.headshot_taken IS 'Headshots taken from enemies.';
COMMENT ON COLUMN player_rounds.suppressions IS 'Times the player suppressed an enemy.';
COMMENT ON COLUMN player_rounds.caps IS 'Objectives taken: control points captured plus caches destroyed.';
COMMENT ON COLUMN player_rounds.score IS 'In-game score earned.';
COMMENT ON COLUMN player_rounds.wins IS '1 if the round ended with the players winning and this player in it, else 0.';
COMMENT ON COLUMN player_rounds.losses IS '1 if the round ended with the players losing and this player in it, else 0.';
COMMENT ON COLUMN player_rounds.killstreak IS 'Best killstreak reached during this row (a maximum: use MAX, not SUM). Streaks carry across rounds, so a long one appears in several rows.';
COMMENT ON COLUMN player_rounds.play_time_seconds IS 'Seconds on the Security team.';
COMMENT ON COLUMN player_rounds.shots IS 'Rounds fired from firearms (see player_shots).';
COMMENT ON COLUMN player_rounds.enemy_hits IS 'Rounds that damaged at least one enemy.';
COMMENT ON COLUMN player_rounds.friendly_hits IS 'Rounds that damaged at least one teammate.';

COMMENT ON TABLE player_round_weapons IS 'Per-weapon part of each player_rounds row: kills and shots by weapon. Join player_rounds on round_id for the player and time.';
COMMENT ON COLUMN player_round_weapons.round_id IS 'player_rounds.id.';
COMMENT ON COLUMN player_round_weapons.weapon_id IS 'weapon_stats.weapon_id.';
COMMENT ON COLUMN player_round_weapons.kills IS 'Kills with this weapon.';
COMMENT ON COLUMN player_round_weapons.shots IS 'Rounds fired with this weapon (firearms only).';
COMMENT ON COLUMN player_round_weapons.enemy_hits IS 'Rounds that damaged at least one enemy.';
COMMENT ON COLUMN player_round_weapons.friendly_hits IS 'Rounds that damaged at least one teammate.';
