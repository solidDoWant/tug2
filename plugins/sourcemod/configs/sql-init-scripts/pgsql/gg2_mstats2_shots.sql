-- Shots and hits per player and weapon, for accuracy (gg2_mstats2, issue #9). Its own file because
-- gg2_mstats2.sql is close to DatabaseMigrator's 16 KB limit; run after it (player_stats and
-- weapon_stats must exist).
--
-- How the plugin counts, from the game's server code: the game raises weapon_fire once per round a
-- firearm fires (a shotgun's pellets are one round), and before it, in the same call, applies that
-- round's damage, each victim getting player_hurt. A round counts as an enemy (or friendly) hit when it
-- damaged at least one enemy (or teammate), however many pellets or bodies it went through; a round
-- through one of each counts for both. Only bullet damage counts: grenades, rockets, fire and melee
-- don't, and nor does the M107's area damage (gg2_heavy_ammo). Rounds fired between rounds don't
-- count, as for kills.
CREATE TABLE IF NOT EXISTS player_shots (
    steam_id VARCHAR(64) NOT NULL,
    weapon_id INTEGER NOT NULL,
    shots INTEGER NOT NULL DEFAULT 0,
    enemy_hits INTEGER NOT NULL DEFAULT 0,
    friendly_hits INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (steam_id, weapon_id),
    FOREIGN KEY (steam_id) REFERENCES player_stats(steam_id) ON DELETE CASCADE,
    FOREIGN KEY (weapon_id) REFERENCES weapon_stats(weapon_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_player_shots_weapon_id ON player_shots(weapon_id);

-- Descriptions for the Discord bot's query_stats tool (see gg2_mstats2.sql).
COMMENT ON TABLE player_shots IS 'Rounds fired and rounds that hit, per player and firearm, for accuracy. Counted since 2026-11; there is no earlier data. Grenades, rockets and melee are not included.';
COMMENT ON COLUMN player_shots.steam_id IS 'SteamID64 as text (player_stats.steam_id).';
COMMENT ON COLUMN player_shots.weapon_id IS 'weapon_stats.weapon_id.';
COMMENT ON COLUMN player_shots.shots IS 'Rounds fired during live rounds (a shotgun shell is one round, whatever its pellets).';
COMMENT ON COLUMN player_shots.enemy_hits IS 'Rounds that damaged at least one enemy. Accuracy = enemy_hits / shots; very small shot counts make it meaningless.';
COMMENT ON COLUMN player_shots.friendly_hits IS 'Rounds that damaged at least one teammate (friendly fire). A round can count as both an enemy and a friendly hit.';
COMMENT ON COLUMN player_shots.created_at IS 'First recorded shot with this weapon (UTC).';
COMMENT ON COLUMN player_shots.updated_at IS 'Last update (UTC).';
