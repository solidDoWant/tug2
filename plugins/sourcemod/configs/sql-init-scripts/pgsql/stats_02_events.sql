-- =====================================================
-- Stats v2 (issue #44), part 2: the player timeline and one row per game event.
-- Needs stats_01_schema.sql.
-- =====================================================

-- A stretch of one round on one team and class. Closed at any team or class change, disconnect or
-- round end; spans still open are written when the round ends.
CREATE TABLE IF NOT EXISTS player_spans (
    round_id       BIGINT NOT NULL REFERENCES rounds,
    steam_id       BIGINT NOT NULL REFERENCES players,
    started_at     TIMESTAMPTZ NOT NULL,
    ended_at       TIMESTAMPTZ NOT NULL CHECK (ended_at >= started_at),
    team           team NOT NULL,
    squad          SMALLINT,
    squad_slot     SMALLINT,
    class_template TEXT,
    PRIMARY KEY (round_id, steam_id, started_at)
);
CREATE INDEX IF NOT EXISTS idx_player_spans_steam_id ON player_spans (steam_id, started_at);

CREATE TABLE IF NOT EXISTS spawns (
    spawn_id   BIGSERIAL PRIMARY KEY,
    round_id   BIGINT NOT NULL REFERENCES rounds,
    steam_id   BIGINT NOT NULL REFERENCES players,
    spawned_at TIMESTAMPTZ NOT NULL,
    UNIQUE (steam_id, spawned_at)
);
CREATE INDEX IF NOT EXISTS idx_spawns_round_id ON spawns (round_id);

CREATE TABLE IF NOT EXISTS spawn_items (
    spawn_id BIGINT NOT NULL REFERENCES spawns,
    item_id  SMALLINT NOT NULL REFERENCES items,
    PRIMARY KEY (spawn_id, item_id)
);

-- Every player_death with a human on either side. Each side's team is as the game had it at the death
-- (humans and bots alike), so a kill's kind needs nothing but its own row.
CREATE TABLE IF NOT EXISTS kills (
    kill_id            BIGSERIAL PRIMARY KEY,
    round_id           BIGINT NOT NULL REFERENCES rounds,
    killed_at          TIMESTAMPTZ NOT NULL,
    victim_steam_id    BIGINT REFERENCES players,
    victim_bot_name    TEXT,
    victim_team        team,
    victim_bot_class_id SMALLINT REFERENCES bot_classes,
    victim_x REAL, victim_y REAL, victim_z REAL,
    attacker_steam_id  BIGINT REFERENCES players,
    attacker_bot_name  TEXT,
    attacker_team      team,
    attacker_bot_class_id SMALLINT REFERENCES bot_classes,
    attacker_x REAL, attacker_y REAL, attacker_z REAL,
    assister_steam_id  BIGINT REFERENCES players,
    assister_bot_name  TEXT,
    weapon_name        TEXT REFERENCES weapons,
    hitgroup           hitgroup,
    headshot           BOOLEAN NOT NULL,
    domination         BOOLEAN NOT NULL,
    revenge            BOOLEAN NOT NULL,
    savior             BOOLEAN NOT NULL,
    offensive          BOOLEAN NOT NULL,
    defensive          BOOLEAN NOT NULL,
    damagebits         INTEGER NOT NULL,
    customkill         SMALLINT NOT NULL,
    attacker_stance    stance,
    attacker_aim       aim_mode,
    damage             SMALLINT CHECK (damage >= 0),
    CHECK (num_nonnulls(victim_steam_id, victim_bot_name) = 1),
    CHECK (num_nonnulls(attacker_steam_id, attacker_bot_name) <= 1),
    CHECK (num_nonnulls(assister_steam_id, assister_bot_name) <= 1),
    CHECK (victim_bot_name IS NOT NULL OR victim_bot_class_id IS NULL),
    CHECK (attacker_bot_name IS NOT NULL OR attacker_bot_class_id IS NULL)
);
-- Added after the first deploy, at the end like a fresh table has it. Every stats view is dropped first,
-- because v_kills selects k.* and a view's columns cannot be inserted before its last; stats_05..07
-- create them all again in this same boot.
DO $$
DECLARE v text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'kills'::regclass AND attname = 'damage' AND NOT attisdropped) THEN
        FOR v IN SELECT viewname FROM pg_views WHERE schemaname = current_schema() AND (viewname LIKE 'v\_%' OR viewname LIKE '%\_current') LOOP
            EXECUTE format('DROP VIEW IF EXISTS %I CASCADE', v);
        END LOOP;
        ALTER TABLE kills ADD COLUMN damage SMALLINT CHECK (damage >= 0);
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS idx_kills_round_id ON kills (round_id);
-- Kills arrive in time order, so a BRIN index serves time ranges at a few hundred KB a year instead
-- of ~55 MB for a b-tree. The per-player indexes hold only the SteamID: b-tree deduplication then
-- keeps each player's entries compact, and a player's time range combines it with the BRIN one.
CREATE INDEX IF NOT EXISTS idx_kills_killed_at ON kills USING brin (killed_at);
CREATE INDEX IF NOT EXISTS idx_kills_attacker ON kills (attacker_steam_id) WHERE attacker_steam_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_kills_victim ON kills (victim_steam_id) WHERE victim_steam_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_kills_attacker_bot ON kills (attacker_bot_name) WHERE attacker_bot_name IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_kills_team_kills ON kills (killed_at)
    WHERE attacker_steam_id IS NOT NULL AND attacker_team = victim_team;

-- Every player_hurt with a human on either side that did not kill: the hit that kills is its kill row
-- (kills.damage). Together they are each hit once. damage is the health the hit took, which on a
-- killing blow is less than the game's dmg_health (that is the whole uncapped damage).
CREATE TABLE IF NOT EXISTS hits (
    round_id              BIGINT NOT NULL REFERENCES rounds,
    hit_at                TIMESTAMPTZ NOT NULL,
    victim_steam_id       BIGINT REFERENCES players,
    victim_bot_name       TEXT,
    victim_team           team,
    victim_bot_class_id   SMALLINT REFERENCES bot_classes,
    victim_x REAL, victim_y REAL, victim_z REAL,
    attacker_steam_id     BIGINT REFERENCES players,
    attacker_bot_name     TEXT,
    attacker_team         team,
    attacker_bot_class_id SMALLINT REFERENCES bot_classes,
    attacker_x REAL, attacker_y REAL, attacker_z REAL,
    weapon_name           TEXT REFERENCES weapons,
    hitgroup              hitgroup,
    damage                SMALLINT NOT NULL CHECK (damage >= 0),
    health_after          SMALLINT NOT NULL CHECK (health_after > 0),
    damagebits            INTEGER NOT NULL,
    attacker_stance       stance,
    attacker_aim          aim_mode,
    CHECK (num_nonnulls(victim_steam_id, victim_bot_name) = 1),
    CHECK (num_nonnulls(attacker_steam_id, attacker_bot_name) <= 1),
    CHECK (victim_steam_id IS NOT NULL OR attacker_steam_id IS NOT NULL),
    CHECK (victim_bot_name IS NOT NULL OR victim_bot_class_id IS NULL),
    CHECK (attacker_bot_name IS NOT NULL OR attacker_bot_class_id IS NULL)
);
-- Rows arrive in round and time order, so BRIN indexes find a round or a time range for a few hundred
-- KB a year. Per-player totals come from the per-round cache; the victim index answers "what hit me".
CREATE INDEX IF NOT EXISTS idx_hits_round_id ON hits USING brin (round_id) WITH (pages_per_range = 16);
CREATE INDEX IF NOT EXISTS idx_hits_hit_at ON hits USING brin (hit_at);
CREATE INDEX IF NOT EXISTS idx_hits_victim ON hits (victim_steam_id) WHERE victim_steam_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS team_kill_forgives (
    kill_id     BIGINT PRIMARY KEY REFERENCES kills,
    forgiven_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS revives (
    revive_id        BIGSERIAL PRIMARY KEY,
    round_id         BIGINT NOT NULL REFERENCES rounds,
    started_at       TIMESTAMPTZ NOT NULL,
    revived_at       TIMESTAMPTZ NOT NULL CHECK (revived_at >= started_at),
    reviver_steam_id BIGINT NOT NULL REFERENCES players,
    revived_steam_id BIGINT NOT NULL REFERENCES players,
    method           revive_method NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_revives_round_id ON revives (round_id);
CREATE INDEX IF NOT EXISTS idx_revives_reviver ON revives (reviver_steam_id, revived_at);

CREATE TABLE IF NOT EXISTS revive_helpers (
    revive_id BIGINT NOT NULL REFERENCES revives,
    steam_id  BIGINT NOT NULL REFERENCES players,
    PRIMARY KEY (revive_id, steam_id)
);

CREATE TABLE IF NOT EXISTS heals (
    heal_id          BIGSERIAL PRIMARY KEY,
    round_id         BIGINT NOT NULL REFERENCES rounds,
    started_at       TIMESTAMPTZ NOT NULL,
    ended_at         TIMESTAMPTZ NOT NULL CHECK (ended_at >= started_at),
    healer_steam_id  BIGINT NOT NULL REFERENCES players,
    patient_steam_id BIGINT NOT NULL REFERENCES players,
    hp_healed        SMALLINT NOT NULL CHECK (hp_healed >= 0),
    to_full          BOOLEAN NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_heals_round_id ON heals (round_id);
CREATE INDEX IF NOT EXISTS idx_heals_healer ON heals (healer_steam_id, ended_at);

CREATE TABLE IF NOT EXISTS heal_holds (
    heal_id     BIGINT NOT NULL REFERENCES heals,
    started_at  TIMESTAMPTZ NOT NULL,
    ended_at    TIMESTAMPTZ NOT NULL CHECK (ended_at >= started_at),
    released_by heal_hold_release NOT NULL,
    PRIMARY KEY (heal_id, started_at)
);

CREATE TABLE IF NOT EXISTS fire_support_calls (
    call_id        BIGSERIAL PRIMARY KEY,
    round_id       BIGINT NOT NULL REFERENCES rounds,
    called_at      TIMESTAMPTZ NOT NULL,
    steam_id       BIGINT NOT NULL REFERENCES players,
    support_type   TEXT NOT NULL,
    target_x REAL, target_y REAL, target_z REAL,
    failure_reason TEXT,
    refunded_at    TIMESTAMPTZ CHECK (refunded_at >= called_at)
);
CREATE INDEX IF NOT EXISTS idx_fire_support_calls_round_id ON fire_support_calls (round_id);
CREATE INDEX IF NOT EXISTS idx_fire_support_calls_steam_id ON fire_support_calls (steam_id, called_at);

CREATE TABLE IF NOT EXISTS objective_events (
    objective_event_id BIGSERIAL PRIMARY KEY,
    round_id           BIGINT NOT NULL REFERENCES rounds,
    at                 TIMESTAMPTZ NOT NULL,
    kind               objective_kind NOT NULL,
    control_point      SMALLINT,
    cp_name            TEXT,
    team               team NOT NULL,
    weapon_name        TEXT REFERENCES weapons
);
CREATE INDEX IF NOT EXISTS idx_objective_events_round_id ON objective_events (round_id);

CREATE TABLE IF NOT EXISTS objective_participants (
    objective_event_id BIGINT NOT NULL REFERENCES objective_events,
    steam_id           BIGINT NOT NULL REFERENCES players,
    role               objective_role NOT NULL,
    PRIMARY KEY (objective_event_id, steam_id)
);
CREATE INDEX IF NOT EXISTS idx_objective_participants_steam_id ON objective_participants (steam_id);
