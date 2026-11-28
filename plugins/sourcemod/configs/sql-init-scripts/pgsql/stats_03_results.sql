-- =====================================================
-- Stats v2 (issue #44), part 3b: per-round results, a cache of what each round's raw facts add up to.
--
-- Every per-round stat is defined once, by stats_round_results() / stats_round_weapon_results()
-- below, over the raw tables. Adding up every raw kill for lifetime totals takes seconds at a year,
-- so each finished round's result is kept here (about 76k rows a year on main) and the views add
-- those up. Nothing is only here: any row can be recomputed exactly, and is.
--   - gg2_stats2 calls stats_refresh_round() in every flush for a round that is over.
--   - Rounds not cached (in progress, or left out by a crash) are computed live by the *_current
--     views (stats_05_views.sql), so the views are always exact.
--   - round_results_done records the definitions' hash per round; the end of this file recomputes
--     out-of-date and missed rounds on every boot.
-- The Discord bot reads the v_* views built on these, not the tables.
-- Needs stats_01..03_counters.
-- =====================================================

CREATE TABLE IF NOT EXISTS round_results_done (
    round_id    BIGINT PRIMARY KEY REFERENCES rounds,
    def_hash    TEXT NOT NULL,
    computed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS player_round_results (
    round_id                 BIGINT NOT NULL REFERENCES round_results_done ON DELETE CASCADE,
    steam_id                 BIGINT NOT NULL REFERENCES players,
    at                       TIMESTAMPTZ NOT NULL,
    kills                    INTEGER NOT NULL,
    deaths                   INTEGER NOT NULL,
    suicides                 INTEGER NOT NULL,
    world_deaths             INTEGER NOT NULL,
    team_kills               INTEGER NOT NULL,
    team_killed              INTEGER NOT NULL,
    assists                  INTEGER NOT NULL,
    headshot_kills           INTEGER NOT NULL,
    headshot_hits            INTEGER NOT NULL,
    caps                     INTEGER NOT NULL,
    cache_kills              INTEGER NOT NULL,
    score                    INTEGER NOT NULL,
    wins                     INTEGER NOT NULL,
    losses                   INTEGER NOT NULL,
    play_seconds             INTEGER NOT NULL,
    medic_seconds            INTEGER NOT NULL,
    revives                  INTEGER NOT NULL,
    times_revived            INTEGER NOT NULL,
    heals                    INTEGER NOT NULL,
    hp_healed                INTEGER NOT NULL,
    fire_support_calls       INTEGER NOT NULL,
    suppressions             INTEGER NOT NULL,
    times_suppressed         INTEGER NOT NULL,
    shots                    INTEGER NOT NULL,
    shots_hit_enemy          INTEGER NOT NULL,
    shots_hit_friendly       INTEGER NOT NULL,
    damage_enemy             INTEGER NOT NULL,
    damage_taken             INTEGER NOT NULL,
    -- Killstreaks run across rounds; these let v_killstreaks join rounds up without the kills.
    kills_before_first_death INTEGER NOT NULL,
    best_streak_inside       INTEGER NOT NULL,
    kills_after_last_death   INTEGER NOT NULL,
    died                     BOOLEAN NOT NULL,
    PRIMARY KEY (round_id, steam_id)
);
CREATE INDEX IF NOT EXISTS idx_player_round_results_steam_id ON player_round_results (steam_id, at);
CREATE INDEX IF NOT EXISTS idx_player_round_results_at ON player_round_results (at);

CREATE TABLE IF NOT EXISTS player_round_weapon_results (
    round_id    BIGINT NOT NULL REFERENCES round_results_done ON DELETE CASCADE,
    steam_id    BIGINT NOT NULL REFERENCES players,
    weapon_name TEXT NOT NULL REFERENCES weapons,
    kills       INTEGER NOT NULL,
    hits_head       INTEGER NOT NULL DEFAULT 0,
    hits_chest      INTEGER NOT NULL DEFAULT 0,
    hits_stomach    INTEGER NOT NULL DEFAULT 0,
    hits_arms       INTEGER NOT NULL DEFAULT 0,
    hits_legs       INTEGER NOT NULL DEFAULT 0,
    damage_enemy    INTEGER NOT NULL DEFAULT 0,
    damage_friendly INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (round_id, steam_id, weapon_name)
);
CREATE INDEX IF NOT EXISTS idx_player_round_weapon_results_steam_id ON player_round_weapon_results (steam_id);
-- Hits and damage joined the cache with the hits table; a boot then recomputes every round (the
-- definitions' hash changes), so the defaults never stay.
ALTER TABLE player_round_weapon_results ADD COLUMN IF NOT EXISTS hits_head INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hits_chest INTEGER NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS hits_stomach INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS hits_arms INTEGER NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS hits_legs INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS damage_enemy INTEGER NOT NULL DEFAULT 0, ADD COLUMN IF NOT EXISTS damage_friendly INTEGER NOT NULL DEFAULT 0;

-- The kind of a death: the one definition, used by v_kills and the cache. It reads no tables, so it
-- is left without a pinned search_path: a SET clause would stop it being inlined, and it would then
-- run as a call per kill.
CREATE OR REPLACE FUNCTION stats_kill_kind(p_attacker BIGINT, p_attacker_bot TEXT, p_victim BIGINT,
                                           p_attacker_team team, p_victim_team team)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $f$
SELECT CASE
           WHEN p_attacker IS NULL AND p_attacker_bot IS NULL THEN 'world'
           WHEN p_attacker = p_victim THEN 'suicide'
           WHEN p_attacker_team = p_victim_team THEN 'team_kill'
           ELSE 'enemy'
       END
$f$;

-- The given rounds' kills with the kind of death.
CREATE OR REPLACE FUNCTION stats_round_kills(p_rounds BIGINT[])
RETURNS TABLE (round_id BIGINT, killed_at TIMESTAMPTZ, attacker_steam_id BIGINT, victim_steam_id BIGINT,
               assister_steam_id BIGINT, weapon_name TEXT, headshot BOOLEAN, kind TEXT)
LANGUAGE sql STABLE AS $f$
SELECT k.round_id, k.killed_at, k.attacker_steam_id, k.victim_steam_id, k.assister_steam_id, k.weapon_name, k.headshot,
       stats_kill_kind(k.attacker_steam_id, k.attacker_bot_name, k.victim_steam_id, k.attacker_team, k.victim_team)
FROM kills k WHERE k.round_id = ANY (p_rounds)
$f$;

-- Every hit of the given rounds, once: the hits table, and each kill's killing blow. kind is a kill's
-- kind (stats_kill_kind) applied to the hit: 'team_kill' is a hit on a teammate.
CREATE OR REPLACE FUNCTION stats_round_hits(p_rounds BIGINT[])
RETURNS TABLE (round_id BIGINT, hit_at TIMESTAMPTZ, attacker_steam_id BIGINT, victim_steam_id BIGINT,
               weapon_name TEXT, hitgroup hitgroup, damage INTEGER, damagebits INTEGER, fatal BOOLEAN, kind TEXT)
LANGUAGE sql STABLE AS $f$
SELECT h.round_id, h.hit_at, h.attacker_steam_id, h.victim_steam_id, h.weapon_name, h.hitgroup, h.damage, h.damagebits, false,
       stats_kill_kind(h.attacker_steam_id, h.attacker_bot_name, h.victim_steam_id, h.attacker_team, h.victim_team)
FROM hits h WHERE h.round_id = ANY (p_rounds)
UNION ALL
SELECT k.round_id, k.killed_at, k.attacker_steam_id, k.victim_steam_id, k.weapon_name, k.hitgroup, k.damage, k.damagebits, true,
       stats_kill_kind(k.attacker_steam_id, k.attacker_bot_name, k.victim_steam_id, k.attacker_team, k.victim_team)
FROM kills k WHERE k.round_id = ANY (p_rounds) AND k.damage IS NOT NULL
$f$;

-- One row per player per round for the given rounds: the definition of every per-round stat.
CREATE OR REPLACE FUNCTION stats_round_results(p_rounds BIGINT[])
RETURNS SETOF player_round_results
LANGUAGE sql STABLE AS $f$
WITH vk AS MATERIALIZED (SELECT * FROM stats_round_kills(p_rounds)),
vh AS MATERIALIZED (SELECT * FROM stats_round_hits(p_rounds)),
keys AS (
    SELECT round_id, steam_id FROM player_spans WHERE round_id = ANY (p_rounds)
    UNION SELECT round_id, steam_id FROM v2_player_rounds WHERE round_id = ANY (p_rounds)
    UNION SELECT round_id, attacker_steam_id FROM vk WHERE attacker_steam_id IS NOT NULL
    UNION SELECT round_id, victim_steam_id FROM vk WHERE victim_steam_id IS NOT NULL
    UNION SELECT round_id, attacker_steam_id FROM vh WHERE attacker_steam_id IS NOT NULL
    UNION SELECT round_id, victim_steam_id FROM vh WHERE victim_steam_id IS NOT NULL
),
kk AS (
    SELECT round_id, attacker_steam_id AS steam_id,
           count(*) FILTER (WHERE kind = 'enemy') AS kills,
           count(*) FILTER (WHERE kind = 'enemy' AND headshot) AS headshot_kills,
           count(*) FILTER (WHERE kind = 'team_kill') AS team_kills
    FROM vk WHERE attacker_steam_id IS NOT NULL GROUP BY 1, 2
),
kd AS (
    SELECT round_id, victim_steam_id AS steam_id, count(*) AS deaths,
           count(*) FILTER (WHERE kind = 'suicide') AS suicides,
           count(*) FILTER (WHERE kind = 'world') AS world_deaths,
           count(*) FILTER (WHERE kind = 'team_kill') AS team_killed
    FROM vk WHERE victim_steam_id IS NOT NULL GROUP BY 1, 2
),
ka AS (
    SELECT round_id, assister_steam_id AS steam_id, count(*) AS assists
    FROM vk WHERE assister_steam_id IS NOT NULL AND kind = 'enemy' GROUP BY 1, 2
),
-- Killstreaks: number each player's lives in the round (a death starts the next; a kill at the
-- same instant as a death counts before it), then the kills in the first, the last and the best
-- life bounded by deaths on both sides.
ev AS (
    SELECT round_id, attacker_steam_id AS steam_id, killed_at AS t, 1 AS is_kill
    FROM vk WHERE kind = 'enemy' AND attacker_steam_id IS NOT NULL
    UNION ALL
    SELECT round_id, victim_steam_id, killed_at, 0 FROM vk WHERE victim_steam_id IS NOT NULL
),
lv AS (
    SELECT round_id, steam_id, life, sum(is_kill) AS n
    FROM (SELECT round_id, steam_id, is_kill,
                 sum(1 - is_kill) OVER (PARTITION BY round_id, steam_id ORDER BY t, is_kill DESC
                                        ROWS UNBOUNDED PRECEDING) AS life
          FROM ev) x
    GROUP BY 1, 2, 3
),
ks AS (
    SELECT l.round_id, l.steam_id, d.deaths > 0 AS died,
           COALESCE(sum(l.n) FILTER (WHERE l.life = 0), 0) AS first_n,
           COALESCE(sum(l.n) FILTER (WHERE l.life = d.deaths), 0) AS last_n,
           COALESCE(max(l.n) FILTER (WHERE l.life > 0 AND l.life < d.deaths), 0) AS inside_n
    FROM lv l JOIN (SELECT round_id, steam_id, max(life) AS deaths FROM lv GROUP BY 1, 2) d USING (round_id, steam_id)
    GROUP BY 1, 2, d.deaths
),
ob AS (
    SELECT e.round_id, p.steam_id,
           count(*) FILTER (WHERE e.kind = 'captured' AND p.role = 'capper') AS caps,
           count(*) FILTER (WHERE e.kind = 'cache_destroyed') AS cache_kills
    FROM objective_events e JOIN objective_participants p USING (objective_event_id)
    WHERE e.round_id = ANY (p_rounds) GROUP BY 1, 2
),
sp AS (
    SELECT s.round_id, s.steam_id,
           sum(extract(epoch FROM s.ended_at - s.started_at)) FILTER (WHERE s.team = 'security') AS play_seconds,
           sum(extract(epoch FROM s.ended_at - s.started_at)) FILTER (WHERE s.class_template ILIKE '%medic%') AS medic_seconds,
           bool_or(s.team = 'security' AND r.ended_at IS NOT NULL AND s.ended_at >= r.ended_at - interval '5 seconds') AS present_at_end
    FROM player_spans s JOIN rounds r USING (round_id) WHERE s.round_id = ANY (p_rounds) GROUP BY 1, 2
),
rv AS (SELECT round_id, reviver_steam_id AS steam_id, count(*) AS revives
       FROM revives WHERE round_id = ANY (p_rounds) GROUP BY 1, 2),
rd AS (SELECT round_id, revived_steam_id AS steam_id, count(*) AS times_revived
       FROM revives WHERE round_id = ANY (p_rounds) GROUP BY 1, 2),
he AS (SELECT round_id, healer_steam_id AS steam_id, count(*) FILTER (WHERE to_full) AS heals, sum(hp_healed) AS hp_healed
       FROM heals WHERE round_id = ANY (p_rounds) GROUP BY 1, 2),
fs AS (SELECT round_id, steam_id, count(*) FILTER (WHERE failure_reason IS NULL) AS fire_support_calls
       FROM v2_fire_support_calls WHERE round_id = ANY (p_rounds) GROUP BY 1, 2),
wp AS (SELECT round_id, steam_id, sum(shots) AS shots, sum(shots_hit_enemy) AS shots_hit_enemy,
              sum(shots_hit_friendly) AS shots_hit_friendly
       FROM v2_player_round_weapons WHERE round_id = ANY (p_rounds) GROUP BY 1, 2),
hg AS (SELECT round_id, attacker_steam_id AS steam_id, count(*) FILTER (WHERE hitgroup = 'head') AS headshot_hits,
              sum(damage) AS damage_enemy
       FROM vh WHERE kind = 'enemy' AND attacker_steam_id IS NOT NULL GROUP BY 1, 2),
ht AS (SELECT round_id, victim_steam_id AS steam_id, sum(damage) AS damage_taken
       FROM vh WHERE victim_steam_id IS NOT NULL GROUP BY 1, 2)
SELECT k.round_id, k.steam_id, COALESCE(r.ended_at, r.started_at),
       COALESCE(kk.kills, 0)::int, COALESCE(kd.deaths, 0)::int, COALESCE(kd.suicides, 0)::int,
       COALESCE(kd.world_deaths, 0)::int, COALESCE(kk.team_kills, 0)::int, COALESCE(kd.team_killed, 0)::int,
       COALESCE(ka.assists, 0)::int, COALESCE(kk.headshot_kills, 0)::int, COALESCE(hg.headshot_hits, 0)::int,
       COALESCE(ob.caps, 0)::int, COALESCE(ob.cache_kills, 0)::int, COALESCE(pr.score, 0),
       (COALESCE(sp.present_at_end, false) AND r.winner = 'security')::int,
       (COALESCE(sp.present_at_end, false) AND r.winner IS NOT NULL AND r.winner <> 'security')::int,
       COALESCE(sp.play_seconds, 0)::int, COALESCE(sp.medic_seconds, 0)::int,
       COALESCE(rv.revives, 0)::int, COALESCE(rd.times_revived, 0)::int,
       COALESCE(he.heals, 0)::int, COALESCE(he.hp_healed, 0)::int, COALESCE(fs.fire_support_calls, 0)::int,
       COALESCE(pr.suppressions, 0), COALESCE(pr.times_suppressed, 0),
       COALESCE(wp.shots, 0)::int, COALESCE(wp.shots_hit_enemy, 0)::int, COALESCE(wp.shots_hit_friendly, 0)::int,
       COALESCE(hg.damage_enemy, 0)::int, COALESCE(ht.damage_taken, 0)::int,
       COALESCE(ks.first_n, 0)::int, COALESCE(ks.inside_n, 0)::int, COALESCE(ks.last_n, 0)::int,
       COALESCE(ks.died, false)
FROM keys k
JOIN rounds r USING (round_id)
LEFT JOIN kk USING (round_id, steam_id) LEFT JOIN kd USING (round_id, steam_id)
LEFT JOIN ka USING (round_id, steam_id) LEFT JOIN ks USING (round_id, steam_id)
LEFT JOIN ob USING (round_id, steam_id) LEFT JOIN sp USING (round_id, steam_id)
LEFT JOIN rv USING (round_id, steam_id) LEFT JOIN rd USING (round_id, steam_id)
LEFT JOIN he USING (round_id, steam_id) LEFT JOIN fs USING (round_id, steam_id)
LEFT JOIN wp USING (round_id, steam_id)
LEFT JOIN hg USING (round_id, steam_id) LEFT JOIN ht USING (round_id, steam_id)
LEFT JOIN v2_player_rounds pr USING (round_id, steam_id)
$f$;

-- Per player and weapon for the given rounds: kills of enemies, hits on enemies by body part, and
-- damage to enemies and to teammates.
CREATE OR REPLACE FUNCTION stats_round_weapon_results(p_rounds BIGINT[])
RETURNS SETOF player_round_weapon_results
LANGUAGE sql STABLE AS $f$
WITH k AS (
    SELECT round_id, attacker_steam_id AS steam_id, weapon_name, count(*) AS kills
    FROM stats_round_kills(p_rounds)
    WHERE kind = 'enemy' AND attacker_steam_id IS NOT NULL AND weapon_name IS NOT NULL
    GROUP BY 1, 2, 3
), h AS (
    SELECT round_id, attacker_steam_id AS steam_id, weapon_name,
           count(*) FILTER (WHERE kind = 'enemy' AND hitgroup = 'head') AS hits_head,
           count(*) FILTER (WHERE kind = 'enemy' AND hitgroup = 'chest') AS hits_chest,
           count(*) FILTER (WHERE kind = 'enemy' AND hitgroup = 'stomach') AS hits_stomach,
           count(*) FILTER (WHERE kind = 'enemy' AND hitgroup IN ('left_arm', 'right_arm')) AS hits_arms,
           count(*) FILTER (WHERE kind = 'enemy' AND hitgroup IN ('left_leg', 'right_leg')) AS hits_legs,
           COALESCE(sum(damage) FILTER (WHERE kind = 'enemy'), 0) AS damage_enemy,
           COALESCE(sum(damage) FILTER (WHERE kind = 'team_kill'), 0) AS damage_friendly
    FROM stats_round_hits(p_rounds)
    WHERE attacker_steam_id IS NOT NULL AND weapon_name IS NOT NULL AND kind IN ('enemy', 'team_kill')
    GROUP BY 1, 2, 3
)
SELECT round_id, steam_id, weapon_name, COALESCE(k.kills, 0)::int,
       COALESCE(h.hits_head, 0)::int, COALESCE(h.hits_chest, 0)::int, COALESCE(h.hits_stomach, 0)::int,
       COALESCE(h.hits_arms, 0)::int, COALESCE(h.hits_legs, 0)::int,
       COALESCE(h.damage_enemy, 0)::int, COALESCE(h.damage_friendly, 0)::int
FROM k FULL JOIN h USING (round_id, steam_id, weapon_name)
$f$;

-- Pin every function to this server's schema: never a fall-through to public.
DO $$
DECLARE f text;
BEGIN
    FOREACH f IN ARRAY ARRAY['stats_round_kills(bigint[])', 'stats_round_hits(bigint[])', 'stats_round_results(bigint[])',
                             'stats_round_weapon_results(bigint[])'] LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = %I', f, current_schema());
    END LOOP;
END $$;

-- Identifies the current definitions: a cached round computed with other ones is out of date.
CREATE OR REPLACE FUNCTION stats_results_hash() RETURNS TEXT
LANGUAGE sql STABLE AS $f$
SELECT md5(pg_get_functiondef('stats_kill_kind(bigint,text,bigint,team,team)'::regprocedure)
        || pg_get_functiondef('stats_round_kills(bigint[])'::regprocedure)
        || pg_get_functiondef('stats_round_hits(bigint[])'::regprocedure)
        || pg_get_functiondef('stats_round_results(bigint[])'::regprocedure)
        || pg_get_functiondef('stats_round_weapon_results(bigint[])'::regprocedure))
$f$;

-- Recomputes the cached results of a set of rounds (one query for all of them: a boot recomputing
-- every round does it in batches). Serialised per round by locking the rounds' rows (a flush and a
-- boot can both refresh one). A failure leaves those rounds uncached, so the views compute them live,
-- and never fails the caller: gg2_stats2 runs this inside its flush, which must not be lost over a
-- cache.
CREATE OR REPLACE FUNCTION stats_refresh_rounds(p_rounds BIGINT[]) RETURNS VOID
LANGUAGE plpgsql AS $f$
BEGIN
    PERFORM 1 FROM rounds WHERE round_id = ANY (p_rounds) ORDER BY round_id FOR UPDATE;
    BEGIN
        DELETE FROM round_results_done WHERE round_id = ANY (p_rounds);
        INSERT INTO round_results_done (round_id, def_hash)
        SELECT round_id, stats_results_hash() FROM rounds WHERE round_id = ANY (p_rounds);
        INSERT INTO player_round_results SELECT * FROM stats_round_results(p_rounds);
        INSERT INTO player_round_weapon_results SELECT * FROM stats_round_weapon_results(p_rounds);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'stats_refresh_rounds(%): % (left uncached)', p_rounds, SQLERRM;
    END;
END $f$;

CREATE OR REPLACE FUNCTION stats_refresh_round(p_round BIGINT) RETURNS VOID
LANGUAGE sql AS $f$ SELECT stats_refresh_rounds(ARRAY[p_round]) $f$;

DO $$
DECLARE f text;
BEGIN
    FOREACH f IN ARRAY ARRAY['stats_results_hash()', 'stats_refresh_rounds(bigint[])', 'stats_refresh_round(bigint)'] LOOP
        EXECUTE format('ALTER FUNCTION %s SET search_path = %I', f, current_schema());
    END LOOP;
END $$;

-- Every boot: recompute rounds cached with other definitions (any round: one cached while still
-- going, as at a shutdown mid-round, is out of date too), and cache rounds that are over but were
-- never cached (a crash before their end was flushed). A round is over once it has ended, or once a
-- later map run started; one in progress and never cached is left to its own end. In batches of 1000.
DO $$
DECLARE b BIGINT[]; h TEXT := stats_results_hash(); n INT := 0;
BEGIN
    FOR b IN
        SELECT array_agg(round_id ORDER BY round_id) FROM (
            SELECT ro.round_id, (row_number() OVER (ORDER BY ro.round_id) - 1) / 1000 AS batch
            FROM rounds ro LEFT JOIN round_results_done d USING (round_id)
            WHERE d.def_hash <> h
               OR (d.round_id IS NULL AND (ro.ended_at IS NOT NULL OR ro.map_run_id <> (SELECT max(map_run_id) FROM map_runs)))) x
        GROUP BY batch ORDER BY batch
    LOOP
        PERFORM stats_refresh_rounds(b);
        n := n + cardinality(b);
    END LOOP;
    IF n > 0 THEN RAISE NOTICE 'stats: cached the results of % rounds', n; END IF;
END $$;
