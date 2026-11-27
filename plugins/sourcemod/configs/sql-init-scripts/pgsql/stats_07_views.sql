-- =====================================================
-- Stats v2 (issue #44), part 7: per-weapon lifetime, players, matches, maps, team kills and bots.
-- Same rules as stats_05/06: v2 rows from the cutover on, old history before it, old totals minus
-- old history for the time before any history existed. Needs stats_01..06.
-- =====================================================

-- Lifetime per player and weapon.
CREATE OR REPLACE VIEW v_player_weapon_lifetime AS
WITH r AS (
    SELECT steam_id, weapon_name, sum(kills) AS kills, sum(shots) AS shots,
           sum(shots_hit_enemy) AS shots_hit_enemy, sum(shots_hit_friendly) AS shots_hit_friendly,
           sum(hits_head) AS hits_head, sum(hits_chest) AS hits_chest, sum(hits_stomach) AS hits_stomach,
           sum(hits_arms) AS hits_arms, sum(hits_legs) AS hits_legs,
           sum(damage_enemy) AS damage_enemy, sum(damage_friendly) AS damage_friendly,
           sum(reloads) AS reloads, sum(deploys) AS deploys, sum(seconds_drawn) AS seconds_drawn
    FROM v_player_round_weapon_stats GROUP BY 1, 2
),
oh AS (   -- all old per-round weapon history
    SELECT o.steam_id, w.weapon_id, sum(w.kills) AS kills, sum(w.shots) AS shots,
           sum(w.enemy_hits) AS enemy_hits, sum(w.friendly_hits) AS friendly_hits
    FROM old_player_round_weapons w JOIN old_player_rounds o ON o.id = w.round_id GROUP BY 1, 2
),
ot AS (   -- old lifetime totals
    SELECT COALESCE(k.steam_id, s.steam_id) AS steam_id, COALESCE(k.weapon_id, s.weapon_id) AS weapon_id,
           COALESCE(k.kill_count, 0) AS kills, COALESCE(s.shots, 0) AS shots,
           COALESCE(s.enemy_hits, 0) AS enemy_hits, COALESCE(s.friendly_hits, 0) AS friendly_hits
    FROM old_player_kills k FULL JOIN old_player_shots s USING (steam_id, weapon_id)
),
pre AS (
    SELECT ot.steam_id::bigint AS steam_id, ws.weapon_name,
           ot.kills - COALESCE(oh.kills, 0) AS kills, ot.shots - COALESCE(oh.shots, 0) AS shots,
           ot.enemy_hits - COALESCE(oh.enemy_hits, 0) AS shots_hit_enemy,
           ot.friendly_hits - COALESCE(oh.friendly_hits, 0) AS shots_hit_friendly
    FROM ot JOIN old_weapon_stats ws USING (weapon_id)
    LEFT JOIN oh ON oh.steam_id = ot.steam_id AND oh.weapon_id = ot.weapon_id
    WHERE ot.steam_id ~ '^[0-9]+$'
)
SELECT COALESCE(r.steam_id, pre.steam_id) AS steam_id, COALESCE(r.weapon_name, pre.weapon_name) AS weapon_name,
       COALESCE(r.kills, 0) + COALESCE(pre.kills, 0) AS kills,
       COALESCE(r.shots, 0) + COALESCE(pre.shots, 0) AS shots,
       COALESCE(r.shots_hit_enemy, 0) + COALESCE(pre.shots_hit_enemy, 0) AS shots_hit_enemy,
       COALESCE(r.shots_hit_friendly, 0) + COALESCE(pre.shots_hit_friendly, 0) AS shots_hit_friendly,
       COALESCE(r.hits_head, 0) AS hits_head, COALESCE(r.hits_chest, 0) AS hits_chest,
       COALESCE(r.hits_stomach, 0) AS hits_stomach, COALESCE(r.hits_arms, 0) AS hits_arms,
       COALESCE(r.hits_legs, 0) AS hits_legs,
       COALESCE(r.damage_enemy, 0) AS damage_enemy, COALESCE(r.damage_friendly, 0) AS damage_friendly,
       COALESCE(r.reloads, 0) AS reloads, COALESCE(r.deploys, 0) AS deploys,
       COALESCE(r.seconds_drawn, 0) AS seconds_drawn
FROM r FULL JOIN pre ON pre.steam_id = r.steam_id AND pre.weapon_name = r.weapon_name;

-- Every player known to v2 or to the old stats, with current name and first/last seen.
CREATE OR REPLACE VIEW v_players AS
WITH ids AS (
    SELECT steam_id FROM players
    UNION SELECT steam_id::bigint FROM old_player_stats WHERE steam_id ~ '^[0-9]+$'
),
s AS (SELECT steam_id, min(connected_at) AS first_seen,
             max(COALESCE(disconnected_at, connected_at)) AS last_seen
      FROM sessions GROUP BY 1),
n AS (SELECT DISTINCT ON (steam_id) steam_id, name FROM name_changes ORDER BY steam_id, changed_at DESC)
SELECT ids.steam_id, COALESCE(n.name, o.name) AS name,
       LEAST(s.first_seen, o.created_at) AS first_seen,
       GREATEST(s.last_seen, o.updated_at) AS last_seen
FROM ids
LEFT JOIN s USING (steam_id)
LEFT JOIN n USING (steam_id)
LEFT JOIN old_player_stats o ON o.steam_id = ids.steam_id::text;

-- Every round played: v2 rounds, plus old win_loss_log rows before the cutover (map and result only).
CREATE OR REPLACE VIEW v_rounds AS
SELECT r.round_id, r.map_run_id, m.map_name, m.game_mode, r.round_number, r.started_at, r.live_at,
       r.ended_at, r.winner, r.end_reason, r.mvp_steam_id, 'v2'::text AS source
FROM rounds r JOIN map_runs m USING (map_run_id)
UNION ALL
SELECT NULL, NULL, ms.map_name, NULL, NULL, NULL, NULL, w.created_at,
       CASE WHEN w.win THEN 'security'::team ELSE 'insurgents'::team END, NULL, NULL, 'old'
FROM old_win_loss_log w JOIN old_map_stats ms USING (map_id), v_cutover c
WHERE w.created_at < c.cutover_at;

-- Per map: rounds, results and play time. Old play time is map_logger's running total, which keeps
-- growing while both writers run; v2 rounds that ended before its last update (updated_at) were
-- counted by both, so they are taken off it. Once the old writer is retired nothing more comes off.
CREATE OR REPLACE VIEW v_maps AS
WITH r AS (
    SELECT map_name, count(*) FILTER (WHERE ended_at IS NOT NULL) AS rounds,
           count(*) FILTER (WHERE winner = 'security') AS wins,
           count(*) FILTER (WHERE winner IS NOT NULL AND winner <> 'security') AS losses,
           max(COALESCE(ended_at, started_at)) AS last_played_at
    FROM v_rounds GROUP BY 1
),
v2 AS (
    SELECT m.map_name, sum(extract(epoch FROM r.ended_at - r.started_at)) AS seconds
    FROM rounds r JOIN map_runs m USING (map_run_id) WHERE r.ended_at IS NOT NULL GROUP BY 1
),
overlap AS (   -- v2 time the old total also counted: rounds that ended before its last update
    SELECT m.map_name, sum(extract(epoch FROM r.ended_at - r.started_at)) AS seconds
    FROM rounds r JOIN map_runs m USING (map_run_id) JOIN old_maps o ON o.map_name = m.map_name
    WHERE r.ended_at IS NOT NULL AND r.ended_at <= o.updated_at + interval '5 seconds' GROUP BY 1
)
SELECT COALESCE(r.map_name, o.map_name) AS map_name,
       COALESCE(r.rounds, 0) AS rounds, COALESCE(r.wins, 0) AS wins, COALESCE(r.losses, 0) AS losses,
       (COALESCE(v2.seconds, 0)
        + GREATEST(COALESCE(extract(epoch FROM o.play_time), 0) - COALESCE(overlap.seconds, 0), 0))::bigint
           AS play_seconds,
       GREATEST(r.last_played_at, o.last_start) AS last_played_at
FROM r
FULL JOIN old_maps o ON o.map_name = r.map_name
LEFT JOIN v2 ON v2.map_name = COALESCE(r.map_name, o.map_name)
LEFT JOIN overlap ON overlap.map_name = COALESCE(r.map_name, o.map_name);

-- Every team kill: v2 kills of a teammate, plus old logged ones before the cutover.
CREATE OR REPLACE VIEW v_team_kills AS
SELECT k.kill_id, k.killed_at, k.attacker_steam_id, k.victim_steam_id, k.weapon_name,
       f.forgiven_at IS NOT NULL AS forgiven, 'v2'::text AS source
FROM v_kills k LEFT JOIN team_kill_forgives f USING (kill_id)
WHERE k.kind = 'team_kill' AND k.attacker_steam_id IS NOT NULL
UNION ALL
SELECT NULL, t.created_at, t.attacker_steam_id, t.victim_steam_id, t.weapon, t.forgiven, 'old'
FROM old_player_tk_logs t, v_cutover c
WHERE t.created_at < c.cutover_at;

-- Kills of human players by bots, per bot name and weapon. The old table only kept totals, which
-- keep growing while both writers run; kills both counted (live-round v2 kills up to the old row's
-- last update) come off them. Once the old writer is retired nothing more comes off.
CREATE OR REPLACE VIEW v_bot_weapon_kills AS
WITH old AS (
    SELECT b.bot_name, ws.weapon_name, b.kill_count, b.updated_at
    FROM old_bot_kills b JOIN old_weapon_stats ws USING (weapon_id)
),
v2 AS (
    SELECT k.attacker_bot_name AS bot_name, k.weapon_name, count(*) AS kills,
           -- counted by the old plugin too: live-round kills up to its last update of that row
           count(*) FILTER (WHERE k.during_live AND k.killed_at <= old.updated_at) AS overlap
    FROM v_kills k
    LEFT JOIN old ON old.bot_name = k.attacker_bot_name AND old.weapon_name = k.weapon_name
    WHERE k.attacker_bot_name IS NOT NULL AND k.victim_steam_id IS NOT NULL AND k.kind = 'enemy'
    GROUP BY 1, 2
)
SELECT COALESCE(v2.bot_name, old.bot_name) AS bot_name,
       COALESCE(v2.weapon_name, old.weapon_name) AS weapon_name,
       COALESCE(v2.kills, 0) + GREATEST(COALESCE(old.kill_count, 0) - COALESCE(v2.overlap, 0), 0) AS kills
FROM v2 FULL JOIN old ON old.bot_name = v2.bot_name AND old.weapon_name = v2.weapon_name;
