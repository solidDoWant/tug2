-- =====================================================
-- Stats v2 (issue #44), part 3: per-round counters, for values only the game knows or whose events
-- are too many to keep one row each (about 20 M shots a year). Writers add to them with
-- INSERT ... ON CONFLICT DO UPDATE SET col = col + EXCLUDED.col, so a round arrives in pieces.
-- Needs stats_01_schema.sql.
-- =====================================================

CREATE TABLE IF NOT EXISTS v2_player_rounds (
    round_id          BIGINT NOT NULL REFERENCES rounds,
    steam_id          BIGINT NOT NULL REFERENCES players,
    score             INTEGER NOT NULL DEFAULT 0,
    capture_ticks     INTEGER NOT NULL DEFAULT 0 CHECK (capture_ticks >= 0),
    objective_resets  INTEGER NOT NULL DEFAULT 0 CHECK (objective_resets >= 0),
    suppressions      INTEGER NOT NULL DEFAULT 0 CHECK (suppressions >= 0),
    times_suppressed  INTEGER NOT NULL DEFAULT 0 CHECK (times_suppressed >= 0),
    enemies_flashed   INTEGER NOT NULL DEFAULT 0 CHECK (enemies_flashed >= 0),
    teammates_flashed INTEGER NOT NULL DEFAULT 0 CHECK (teammates_flashed >= 0),
    PRIMARY KEY (round_id, steam_id)
);
CREATE INDEX IF NOT EXISTS idx_player_rounds_steam_id ON v2_player_rounds (steam_id);

CREATE TABLE IF NOT EXISTS v2_player_round_weapons (
    round_id           BIGINT NOT NULL,
    steam_id           BIGINT NOT NULL,
    weapon_name        TEXT NOT NULL REFERENCES weapons,
    shots              INTEGER NOT NULL DEFAULT 0 CHECK (shots >= 0),
    shots_hit_enemy    INTEGER NOT NULL DEFAULT 0 CHECK (shots_hit_enemy >= 0),
    shots_hit_friendly INTEGER NOT NULL DEFAULT 0 CHECK (shots_hit_friendly >= 0),
    reloads            INTEGER NOT NULL DEFAULT 0 CHECK (reloads >= 0),
    deploys            INTEGER NOT NULL DEFAULT 0 CHECK (deploys >= 0),
    seconds_drawn      INTEGER NOT NULL DEFAULT 0 CHECK (seconds_drawn >= 0),
    PRIMARY KEY (round_id, steam_id, weapon_name),
    FOREIGN KEY (round_id, steam_id) REFERENCES v2_player_rounds
);
CREATE INDEX IF NOT EXISTS idx_player_round_weapons_weapon ON v2_player_round_weapons (weapon_name);

-- Damage and hits by body part were counters here until the hits table (stats_02_events.sql) recorded
-- every hit; they are now added up from it, so the counters go. The stats views that read them are
-- dropped first and created again by stats_05..07 in this same boot.
DO $$
DECLARE v text;
BEGIN
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'v2_player_round_weapons'::regclass AND attname = 'damage_enemy' AND NOT attisdropped) THEN
        FOR v IN SELECT viewname FROM pg_views WHERE schemaname = current_schema() AND (viewname LIKE 'v\_%' OR viewname LIKE '%\_current') LOOP
            EXECUTE format('DROP VIEW IF EXISTS %I CASCADE', v);
        END LOOP;
        ALTER TABLE v2_player_round_weapons DROP COLUMN hits_head, DROP COLUMN hits_chest, DROP COLUMN hits_stomach,
            DROP COLUMN hits_arms, DROP COLUMN hits_legs, DROP COLUMN damage_enemy, DROP COLUMN damage_friendly;
        ALTER TABLE v2_player_rounds DROP COLUMN damage_taken, DROP COLUMN fall_damage;
    END IF;
END $$;

-- The one way writers name a round. Every argument is something the game server already knows, so a
-- plugin never waits on the database to learn an id: gg2_rounds formats this call and every writer
-- embeds it. It creates whatever is missing - build, boot, map, mode, theater, map run, round - and is
-- idempotent, so retried batches are safe.
--
-- Boots and map runs are matched within a few seconds rather than exactly: the game server works
-- them out from whole-second wall time minus engine uptime, so a plugin reload can be a second off.
CREATE OR REPLACE FUNCTION stats_round_id(
    p_booted_at      TIMESTAMPTZ,
    p_git_commit     TEXT,
    p_image_version  TEXT,
    p_map_started_at TIMESTAMPTZ,
    p_map_name       TEXT,
    p_game_mode      TEXT,
    p_theater        TEXT,
    p_load_seconds   REAL,
    p_round_number   SMALLINT,
    p_round_started  TIMESTAMPTZ
) RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_boot    TIMESTAMPTZ;
    v_run     BIGINT;
    v_round   BIGINT;
BEGIN
    SELECT booted_at INTO v_boot FROM server_boots
    WHERE booted_at BETWEEN p_booted_at - interval '5 seconds' AND p_booted_at + interval '5 seconds'
    ORDER BY abs(extract(epoch FROM booted_at - p_booted_at)) LIMIT 1;
    IF v_boot IS NULL THEN
        INSERT INTO server_builds (git_commit, image_version) VALUES (p_git_commit, p_image_version)
        ON CONFLICT (git_commit) DO NOTHING;
        INSERT INTO server_boots (booted_at, git_commit) VALUES (p_booted_at, p_git_commit)
        ON CONFLICT (booted_at) DO NOTHING;
        v_boot := p_booted_at;
    END IF;

    SELECT map_run_id INTO v_run FROM map_runs
    WHERE started_at BETWEEN p_map_started_at - interval '5 seconds' AND p_map_started_at + interval '5 seconds'
      AND map_name = p_map_name
    ORDER BY abs(extract(epoch FROM started_at - p_map_started_at)) LIMIT 1;
    IF v_run IS NULL THEN
        INSERT INTO v2_maps (map_name) VALUES (p_map_name) ON CONFLICT DO NOTHING;
        INSERT INTO game_modes (game_mode) VALUES (p_game_mode) ON CONFLICT DO NOTHING;
        IF p_theater IS NOT NULL THEN
            INSERT INTO theaters (theater_name) VALUES (p_theater) ON CONFLICT DO NOTHING;
        END IF;
        INSERT INTO map_runs (booted_at, started_at, map_name, game_mode, theater, load_seconds)
        VALUES (v_boot, p_map_started_at, p_map_name, p_game_mode, p_theater, p_load_seconds)
        ON CONFLICT (started_at) DO NOTHING
        RETURNING map_run_id INTO v_run;
        IF v_run IS NULL THEN   -- another writer created it first
            SELECT map_run_id INTO STRICT v_run FROM map_runs WHERE started_at = p_map_started_at;
        END IF;
    END IF;

    -- Read first: an upsert would rewrite the row (and lock it) on every flush.
    SELECT round_id INTO v_round FROM rounds WHERE map_run_id = v_run AND round_number = p_round_number;
    IF v_round IS NULL THEN
        INSERT INTO rounds (map_run_id, round_number, started_at)
        VALUES (v_run, p_round_number, p_round_started)
        ON CONFLICT (map_run_id, round_number) DO NOTHING
        RETURNING round_id INTO v_round;
        IF v_round IS NULL THEN
            SELECT round_id INTO STRICT v_round FROM rounds WHERE map_run_id = v_run AND round_number = p_round_number;
        END IF;
    END IF;
    RETURN v_round;
END $$;
-- Resolve names in this server's schema only, never a fall-through to public.
DO $$ BEGIN
    EXECUTE format('ALTER FUNCTION stats_round_id(timestamptz, text, text, timestamptz, text, text, text, real, smallint, timestamptz) SET search_path = %I', current_schema());
END $$;
