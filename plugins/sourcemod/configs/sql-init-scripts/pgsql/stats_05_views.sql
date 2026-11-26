-- =====================================================
-- Stats v2 (issue #44), part 5: per-kill and per-player-round views.
--
-- Nothing derived is stored; these views are the one definition of every stat. The stats API and
-- the Discord bot read them, never the raw tables, for totals.
--
-- The cutover is the first v2 map run (v_cutover). Before it, per-round numbers come from the old
-- tables' history; from it on, only from v2 rows, so the weeks both are written count once.
-- Needs stats_01..04.
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

CREATE OR REPLACE VIEW v_cutover AS
SELECT COALESCE(min(started_at), 'infinity'::timestamptz) AS cutover_at FROM map_runs;

-- kills, plus each side's team (bots: their own column; humans: the span they were in at the time),
-- whether the round was live, and what kind of death it was.
--
-- A human's span is found with a hash join on (round, player) and an interval test rather than a
-- per-kill lookup (4x faster at a year of data): each span is taken to last until the player's next
-- span starts, so the intervals never overlap and every kill matches at most one.
CREATE OR REPLACE VIEW v_kills AS
WITH si AS (
    SELECT round_id, steam_id, team, started_at AS from_at,
           COALESCE(lead(started_at) OVER (PARTITION BY round_id, steam_id ORDER BY started_at), 'infinity') AS to_at
    FROM player_spans
)
SELECT k.*,
       COALESCE(k.attacker_bot_team, a.team) AS attacker_team,
       COALESCE(k.victim_bot_team, v.team)   AS victim_team,
       (r.live_at IS NOT NULL AND k.killed_at >= r.live_at
            AND (r.ended_at IS NULL OR k.killed_at <= r.ended_at)) AS during_live,
       CASE
           WHEN k.attacker_steam_id IS NULL AND k.attacker_bot_name IS NULL THEN 'world'
           WHEN k.attacker_steam_id = k.victim_steam_id THEN 'suicide'
           WHEN COALESCE(k.attacker_bot_team, a.team) = COALESCE(k.victim_bot_team, v.team) THEN 'team_kill'
           ELSE 'enemy'
       END AS kind
FROM kills k
JOIN rounds r USING (round_id)
LEFT JOIN si a ON a.round_id = k.round_id AND a.steam_id = k.attacker_steam_id
              AND k.killed_at >= a.from_at AND k.killed_at < a.to_at
LEFT JOIN si v ON v.round_id = k.round_id AND v.steam_id = k.victim_steam_id
              AND k.killed_at >= v.from_at AND k.killed_at < v.to_at;

-- Best killstreak per player from v2 data: enemy kills between two deaths, carried across rounds and
-- maps as the old plugin did.
CREATE OR REPLACE VIEW v_killstreaks AS
WITH ev AS (
    SELECT attacker_steam_id AS steam_id, killed_at AS t, 1 AS is_kill
    FROM v_kills WHERE kind = 'enemy' AND attacker_steam_id IS NOT NULL
    UNION ALL
    SELECT victim_steam_id, killed_at, 0 FROM kills WHERE victim_steam_id IS NOT NULL
), g AS (
    SELECT steam_id, is_kill,
           sum(1 - is_kill) OVER (PARTITION BY steam_id ORDER BY t, is_kill DESC ROWS UNBOUNDED PRECEDING) AS life
    FROM ev
)
SELECT steam_id, max(n)::int AS best_killstreak
FROM (SELECT steam_id, life, sum(is_kill) AS n FROM g GROUP BY steam_id, life) x
GROUP BY steam_id;

-- One row per player per round. v2 rounds have a round_id; old history rows (before the cutover)
-- have none, and old medic, team kill and fire support history arrive as rows of their own.
-- Columns the old data never had are NULL there, not 0.
CREATE OR REPLACE VIEW v_player_round_stats AS
WITH keys AS (
    SELECT round_id, steam_id FROM player_spans
    UNION SELECT round_id, steam_id FROM player_rounds
    UNION SELECT round_id, attacker_steam_id FROM kills WHERE attacker_steam_id IS NOT NULL
    UNION SELECT round_id, victim_steam_id FROM kills WHERE victim_steam_id IS NOT NULL
),
vk AS MATERIALIZED (   -- v_kills once (its team join is the costly part), narrowed to what is counted
    SELECT round_id, attacker_steam_id, victim_steam_id, assister_steam_id, kind, headshot FROM v_kills
),
kk AS (
    SELECT round_id, attacker_steam_id AS steam_id,
           count(*) FILTER (WHERE kind = 'enemy') AS kills,
           count(*) FILTER (WHERE kind = 'enemy' AND headshot) AS headshot_kills,
           count(*) FILTER (WHERE kind = 'team_kill') AS team_kills
    FROM vk WHERE attacker_steam_id IS NOT NULL GROUP BY 1, 2
),
kd AS (
    SELECT round_id, victim_steam_id AS steam_id,
           count(*) AS deaths,
           count(*) FILTER (WHERE kind = 'suicide') AS suicides,
           count(*) FILTER (WHERE kind = 'world') AS world_deaths,
           count(*) FILTER (WHERE kind = 'team_kill') AS team_killed
    FROM vk WHERE victim_steam_id IS NOT NULL GROUP BY 1, 2
),
ka AS (
    SELECT round_id, assister_steam_id AS steam_id, count(*) AS assists
    FROM vk WHERE assister_steam_id IS NOT NULL AND kind = 'enemy' GROUP BY 1, 2
),
ob AS (
    SELECT e.round_id, p.steam_id,
           count(*) FILTER (WHERE e.kind = 'captured' AND p.role = 'capper') AS caps,
           count(*) FILTER (WHERE e.kind = 'cache_destroyed') AS cache_kills
    FROM objective_participants p JOIN objective_events e USING (objective_event_id) GROUP BY 1, 2
),
sp AS (
    SELECT s.round_id, s.steam_id,
           sum(extract(epoch FROM s.ended_at - s.started_at)) FILTER (WHERE s.team = 'security') AS play_seconds,
           sum(extract(epoch FROM s.ended_at - s.started_at)) FILTER (WHERE s.class_template ILIKE '%medic%') AS medic_seconds,
           bool_or(s.team = 'security' AND r.ended_at IS NOT NULL AND s.ended_at >= r.ended_at - interval '5 seconds') AS present_at_end
    FROM player_spans s JOIN rounds r USING (round_id) GROUP BY 1, 2
),
rv AS (SELECT round_id, reviver_steam_id AS steam_id, count(*) AS revives FROM revives GROUP BY 1, 2),
rd AS (SELECT round_id, revived_steam_id AS steam_id, count(*) AS times_revived FROM revives GROUP BY 1, 2),
he AS (
    SELECT round_id, healer_steam_id AS steam_id,
           count(*) FILTER (WHERE to_full) AS heals, sum(hp_healed) AS hp_healed
    FROM heals GROUP BY 1, 2
),
fs AS (
    SELECT round_id, steam_id, count(*) FILTER (WHERE failure_reason IS NULL) AS fire_support_calls
    FROM fire_support_calls GROUP BY 1, 2
),
wp AS (
    SELECT round_id, steam_id, sum(shots) AS shots, sum(shots_hit_enemy) AS shots_hit_enemy,
           sum(shots_hit_friendly) AS shots_hit_friendly, sum(hits_head) AS headshot_hits,
           sum(damage_enemy) AS damage_enemy
    FROM player_round_weapons GROUP BY 1, 2
)
SELECT k.round_id, k.steam_id, COALESCE(r.ended_at, r.started_at) AS at, 'v2'::text AS source,
       COALESCE(kk.kills, 0) AS kills, COALESCE(kd.deaths, 0) AS deaths,
       COALESCE(kd.suicides, 0) AS suicides, COALESCE(kd.world_deaths, 0) AS world_deaths,
       COALESCE(kk.team_kills, 0) AS team_kills, COALESCE(kd.team_killed, 0) AS team_killed,
       COALESCE(ka.assists, 0) AS assists, COALESCE(kk.headshot_kills, 0) AS headshot_kills,
       COALESCE(wp.headshot_hits, 0) AS headshot_hits,
       COALESCE(ob.caps, 0) AS caps, COALESCE(ob.cache_kills, 0) AS cache_kills,
       COALESCE(pr.score, 0) AS score,
       (COALESCE(sp.present_at_end, false) AND r.winner = 'security')::int AS wins,
       (COALESCE(sp.present_at_end, false) AND r.winner IS NOT NULL AND r.winner <> 'security')::int AS losses,
       COALESCE(sp.play_seconds, 0)::bigint AS play_seconds,
       COALESCE(sp.medic_seconds, 0)::bigint AS medic_seconds,
       COALESCE(rv.revives, 0) AS revives, COALESCE(rd.times_revived, 0) AS times_revived,
       COALESCE(he.heals, 0) AS heals, COALESCE(he.hp_healed, 0) AS hp_healed,
       COALESCE(fs.fire_support_calls, 0) AS fire_support_calls,
       COALESCE(pr.suppressions, 0) AS suppressions, COALESCE(pr.times_suppressed, 0) AS times_suppressed,
       COALESCE(wp.shots, 0) AS shots, COALESCE(wp.shots_hit_enemy, 0) AS shots_hit_enemy,
       COALESCE(wp.shots_hit_friendly, 0) AS shots_hit_friendly,
       COALESCE(wp.damage_enemy, 0) AS damage_enemy, COALESCE(pr.damage_taken, 0) AS damage_taken
FROM keys k
JOIN rounds r USING (round_id)
LEFT JOIN kk USING (round_id, steam_id) LEFT JOIN kd USING (round_id, steam_id)
LEFT JOIN ka USING (round_id, steam_id) LEFT JOIN ob USING (round_id, steam_id)
LEFT JOIN sp USING (round_id, steam_id) LEFT JOIN rv USING (round_id, steam_id)
LEFT JOIN rd USING (round_id, steam_id) LEFT JOIN he USING (round_id, steam_id)
LEFT JOIN fs USING (round_id, steam_id) LEFT JOIN wp USING (round_id, steam_id)
LEFT JOIN player_rounds pr USING (round_id, steam_id)
UNION ALL
SELECT NULL, o.steam_id::bigint, o.recorded_at, 'old',
       o.kills, o.deaths, o.suicides, NULL, NULL, NULL, NULL, NULL, o.headshot_given,
       o.caps, NULL, o.score, o.wins, o.losses, o.play_time_seconds, NULL,
       NULL, NULL, NULL, NULL, NULL, o.suppressions, NULL,
       o.shots, o.enemy_hits, o.friendly_hits, NULL, NULL
FROM old_player_rounds o, v_cutover c
WHERE o.recorded_at < c.cutover_at AND o.steam_id ~ '^[0-9]+$'
UNION ALL
SELECT NULL, m.steam_id::bigint, m.recorded_at, 'old',
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       m.medic_time, m.revives, NULL, m.heals, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM old_medic_rounds m, v_cutover c
WHERE m.recorded_at < c.cutover_at AND m.steam_id ~ '^[0-9]+$'
UNION ALL
SELECT NULL, x.steam_id, x.created_at, 'old',
       NULL, NULL, NULL, NULL, x.tk, x.tkd, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM (SELECT attacker_steam_id AS steam_id, created_at, 1 AS tk, 0 AS tkd FROM old_player_tk_logs
      UNION ALL SELECT victim_steam_id, created_at, 0, 1 FROM old_player_tk_logs) x, v_cutover c
WHERE x.created_at < c.cutover_at
UNION ALL
SELECT NULL, f.steam_id::bigint, f.called_at, 'old',
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL
FROM old_fire_support_calls f, v_cutover c
WHERE f.called_at < c.cutover_at AND f.steam_id ~ '^[0-9]+$';
