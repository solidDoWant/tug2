-- =====================================================
-- Stats v2 (issue #44), part 2: the player timeline and one row per game event.
-- Needs stats_01_schema.sql. See that file for how the stats_* schema is chosen.
-- =====================================================

DO $$
DECLARE n int;
BEGIN
    SELECT count(*) INTO n FROM pg_namespace
    WHERE nspname LIKE 'stats\_%' AND nspowner = (SELECT oid FROM pg_roles WHERE rolname = current_user);
    IF n <> 1 THEN
        RAISE EXCEPTION 'expected exactly one stats_* schema owned by %, found %', current_user, n;
    END IF;
    PERFORM set_config('search_path', (SELECT quote_ident(nspname) FROM pg_namespace
        WHERE nspname LIKE 'stats\_%' AND nspowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)), true);
END $$;

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
    spawn_id  BIGINT NOT NULL REFERENCES spawns,
    item_name TEXT NOT NULL,
    PRIMARY KEY (spawn_id, item_name)
);

-- Every player_death with a human on either side.
CREATE TABLE IF NOT EXISTS kills (
    kill_id            BIGSERIAL PRIMARY KEY,
    round_id           BIGINT NOT NULL REFERENCES rounds,
    killed_at          TIMESTAMPTZ NOT NULL,
    victim_steam_id    BIGINT REFERENCES players,
    victim_bot_name    TEXT,
    victim_bot_team    team,
    victim_bot_class   TEXT,
    victim_x REAL, victim_y REAL, victim_z REAL,
    attacker_steam_id  BIGINT REFERENCES players,
    attacker_bot_name  TEXT,
    attacker_bot_team  team,
    attacker_bot_class TEXT,
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
    CHECK (num_nonnulls(victim_steam_id, victim_bot_name) = 1),
    CHECK (num_nonnulls(attacker_steam_id, attacker_bot_name) <= 1),
    CHECK (num_nonnulls(assister_steam_id, assister_bot_name) <= 1),
    CHECK (victim_bot_name IS NOT NULL OR (victim_bot_team IS NULL AND victim_bot_class IS NULL)),
    CHECK (attacker_bot_name IS NOT NULL OR (attacker_bot_team IS NULL AND attacker_bot_class IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_kills_round_id ON kills (round_id);
CREATE INDEX IF NOT EXISTS idx_kills_killed_at ON kills (killed_at);
CREATE INDEX IF NOT EXISTS idx_kills_attacker ON kills (attacker_steam_id, killed_at) WHERE attacker_steam_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_kills_victim ON kills (victim_steam_id, killed_at) WHERE victim_steam_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_kills_attacker_bot ON kills (attacker_bot_name) WHERE attacker_bot_name IS NOT NULL;

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
