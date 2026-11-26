-- One flush as gg2_stats2 builds it (statement shapes copied from gg2_stats2.sp), twice: once for a
-- round's first flush and once again with more data, to exercise the additive upserts and the
-- round key finding an existing round. Run by run.sh after test.sql, inside one transaction per flush
-- (the plugin's Transaction). All names are fictional.
\set ON_ERROR_STOP on
\set key 'stats_round_id(to_timestamp(1764086400), ''deadbeef-dirty'', ''test-0.0.2'', to_timestamp(1764086400+3600.250), ''sinjar'', ''checkpoint'', NULL, 4.125, 1::smallint, to_timestamp(1764086400+3610.500))'

BEGIN;
INSERT INTO players (steam_id) VALUES (76561198000000011),(76561198000000012) ON CONFLICT DO NOTHING;
INSERT INTO weapons (weapon_name) VALUES ('m4a1'),('rocket_rpg7') ON CONFLICT DO NOTHING;
INSERT INTO bot_classes (class_template) SELECT n FROM (VALUES ('template_rifleman_insurgent_coop')) v(n) WHERE NOT EXISTS (SELECT 1 FROM bot_classes b WHERE b.class_template = v.n) ON CONFLICT DO NOTHING;
INSERT INTO items (item_name) SELECT n FROM (VALUES ('kevlar_heavy'),('weapon_m4a1')) v(n) WHERE NOT EXISTS (SELECT 1 FROM items i WHERE i.item_name = v.n) ON CONFLICT DO NOTHING;
INSERT INTO sessions (steam_id, connected_at) VALUES (76561198000000011, to_timestamp(1764086400+3500.000)) ON CONFLICT DO NOTHING;
INSERT INTO name_changes (steam_id, connected_at, changed_at, name) VALUES (76561198000000011, to_timestamp(1764086400+3500.000), to_timestamp(1764086400+3500.000), 'Charlie O''Test') ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) INSERT INTO kills (round_id, killed_at, victim_steam_id, victim_bot_name, victim_team, victim_bot_class_id, victim_x, victim_y, victim_z, attacker_steam_id, attacker_bot_name, attacker_team, attacker_bot_class_id, attacker_x, attacker_y, attacker_z, assister_steam_id, assister_bot_name, weapon_name, hitgroup, headshot, domination, revenge, savior, offensive, defensive, damagebits, customkill, attacker_stance, attacker_aim, damage) VALUES ((SELECT id FROM r),to_timestamp(1764086400+3620.125),NULL,'Rifleman O''Neil','insurgents',(SELECT bot_class_id FROM bot_classes WHERE class_template = 'template_rifleman_insurgent_coop'),100.5,-20.0,8.0,76561198000000011,NULL,'security',NULL,120.000000,-30.000000,8.000000,76561198000000012,NULL,'m4a1','head',true,false,false,false,true,false,2,0,'crouched','sights',80),((SELECT id FROM r),to_timestamp(1764086400+3630.000),76561198000000012,NULL,'security',NULL,1.0,2.0,3.0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,false,false,false,false,false,false,32,0,NULL,NULL,25);
WITH r AS (SELECT :key AS id) INSERT INTO hits (round_id, hit_at, victim_steam_id, victim_bot_name, victim_team, victim_bot_class_id, victim_x, victim_y, victim_z, attacker_steam_id, attacker_bot_name, attacker_team, attacker_bot_class_id, attacker_x, attacker_y, attacker_z, weapon_name, hitgroup, damage, health_after, damagebits, attacker_stance, attacker_aim) VALUES ((SELECT id FROM r),to_timestamp(1764086400+3619.500),NULL,'Rifleman O''Neil','insurgents',(SELECT bot_class_id FROM bot_classes WHERE class_template = 'template_rifleman_insurgent_coop'),100.500000,-20.000000,8.000000,76561198000000011,NULL,'security',NULL,120.000000,-30.000000,8.000000,'m4a1','chest',20,80,2,'crouched','sights'),((SELECT id FROM r),to_timestamp(1764086400+3621.000),76561198000000011,NULL,'security',NULL,120.000000,-30.000000,8.000000,NULL,'Rifleman O''Neil','insurgents',(SELECT bot_class_id FROM bot_classes WHERE class_template = 'template_rifleman_insurgent_coop'),100.500000,-20.000000,8.000000,'m4a1','stomach',25,75,2,NULL,NULL);
WITH r AS (SELECT :key AS id) INSERT INTO player_spans (round_id, steam_id, started_at, ended_at, team, squad, squad_slot, class_template) VALUES ((SELECT id FROM r),76561198000000011,to_timestamp(1764086400+3610.500),to_timestamp(1764086400+3640.000),'security',0,1,'template_medic_security_coop') ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) INSERT INTO v2_fire_support_calls (round_id, called_at, steam_id, support_type, target_x, target_y, target_z, failure_reason, refunded_at) VALUES ((SELECT id FROM r),to_timestamp(1764086400+3625.000),76561198000000011,'m18_arty',10.000000,20.000000,30.000000,NULL,NULL),((SELECT id FROM r),to_timestamp(1764086400+3626.000),76561198000000011,'m18_arty',NULL,NULL,NULL,'player_cooldown',NULL);
WITH r AS (SELECT :key AS id) INSERT INTO survival_levels (round_id, level, reached_at) VALUES ((SELECT id FROM r),2,to_timestamp(1764086400+3627.000)) ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) UPDATE rounds SET live_at = to_timestamp(1764086400+3615.000) WHERE round_id = (SELECT id FROM r);
WITH r AS (SELECT :key AS id) , s AS (INSERT INTO spawns (round_id, steam_id, spawned_at) SELECT id, 76561198000000011, to_timestamp(1764086400+3611.000) FROM r ON CONFLICT DO NOTHING RETURNING spawn_id) INSERT INTO spawn_items (spawn_id, item_id) SELECT s.spawn_id, i.item_id FROM s, (VALUES ('kevlar_heavy'),('weapon_m4a1')) v(item) JOIN items i ON i.item_name = v.item ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) , e AS (INSERT INTO objective_events (round_id, at, kind, control_point, cp_name, team, weapon_name) SELECT id, to_timestamp(1764086400+3629.000), 'captured', 0, 'Alpha', 'security', NULL FROM r RETURNING objective_event_id) INSERT INTO objective_participants (objective_event_id, steam_id, role) SELECT e.objective_event_id, v.sid, v.role::objective_role FROM e, (VALUES (76561198000000011,'capper'),(76561198000000012,'capper')) v(sid, role) ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) , e AS (INSERT INTO objective_events (round_id, at, kind, control_point, cp_name, team, weapon_name) SELECT id, to_timestamp(1764086400+3629.500), 'cache_destroyed', 1, NULL, 'security', 'rocket_rpg7' FROM r RETURNING objective_event_id) SELECT 1 FROM e;
WITH r AS (SELECT :key AS id) , v AS (INSERT INTO revives (round_id, started_at, revived_at, reviver_steam_id, revived_steam_id, method) SELECT id, to_timestamp(1764086400+3631.000), to_timestamp(1764086400+3636.000), 76561198000000011, 76561198000000012, 'defib' FROM r RETURNING revive_id) SELECT 1 FROM v;
WITH r AS (SELECT :key AS id) , h AS (INSERT INTO heals (round_id, started_at, ended_at, healer_steam_id, patient_steam_id, hp_healed, to_full) SELECT id, to_timestamp(1764086400+3637.000), to_timestamp(1764086400+3639.000), 76561198000000011, 76561198000000012, 60, true FROM r RETURNING heal_id) INSERT INTO heal_holds (heal_id, started_at, ended_at, released_by) SELECT h.heal_id, v.s, v.e, v.why::heal_hold_release FROM h, (VALUES (to_timestamp(1764086400+3637.000),to_timestamp(1764086400+3639.000),'full_health')) v(s, e, why) ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) INSERT INTO v2_player_rounds AS p (round_id, steam_id, score, capture_ticks, objective_resets, suppressions, times_suppressed, enemies_flashed, teammates_flashed) SELECT id, 76561198000000011, 30, 2, 0, 4, 1, 0, 1 FROM r ON CONFLICT (round_id, steam_id) DO UPDATE SET score = p.score + EXCLUDED.score, capture_ticks = p.capture_ticks + EXCLUDED.capture_ticks, objective_resets = p.objective_resets + EXCLUDED.objective_resets, suppressions = p.suppressions + EXCLUDED.suppressions, times_suppressed = p.times_suppressed + EXCLUDED.times_suppressed, enemies_flashed = p.enemies_flashed + EXCLUDED.enemies_flashed, teammates_flashed = p.teammates_flashed + EXCLUDED.teammates_flashed;
WITH r AS (SELECT :key AS id) INSERT INTO v2_player_round_weapons AS w (round_id, steam_id, weapon_name, shots, shots_hit_enemy, shots_hit_friendly, reloads, deploys, seconds_drawn) SELECT r.id, 76561198000000011, v.* FROM r, (VALUES ('m4a1',30,8,0,2,3,41),('rocket_rpg7',1,0,0,0,1,5)) v ON CONFLICT (round_id, steam_id, weapon_name) DO UPDATE SET shots = w.shots + EXCLUDED.shots, shots_hit_enemy = w.shots_hit_enemy + EXCLUDED.shots_hit_enemy, shots_hit_friendly = w.shots_hit_friendly + EXCLUDED.shots_hit_friendly, reloads = w.reloads + EXCLUDED.reloads, deploys = w.deploys + EXCLUDED.deploys, seconds_drawn = w.seconds_drawn + EXCLUDED.seconds_drawn;
WITH r AS (SELECT :key AS id) UPDATE v2_fire_support_calls SET refunded_at = to_timestamp(1764086400+3626.100) WHERE call_id = (SELECT max(call_id) FROM v2_fire_support_calls WHERE steam_id = 76561198000000011 AND refunded_at IS NULL);
COMMIT;

-- Second flush of the same round: same key, more counters, the round's end, a team kill and its forgive.
BEGIN;
INSERT INTO players (steam_id) VALUES (76561198000000011),(76561198000000012) ON CONFLICT DO NOTHING;
INSERT INTO weapons (weapon_name) VALUES ('m4a1') ON CONFLICT DO NOTHING;
INSERT INTO items (item_name) SELECT n FROM (VALUES ('kevlar_heavy')) v(n) WHERE NOT EXISTS (SELECT 1 FROM items i WHERE i.item_name = v.n) ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) INSERT INTO kills (round_id, killed_at, victim_steam_id, victim_bot_name, victim_team, victim_bot_class_id, victim_x, victim_y, victim_z, attacker_steam_id, attacker_bot_name, attacker_team, attacker_bot_class_id, attacker_x, attacker_y, attacker_z, assister_steam_id, assister_bot_name, weapon_name, hitgroup, headshot, domination, revenge, savior, offensive, defensive, damagebits, customkill, attacker_stance, attacker_aim, damage) VALUES ((SELECT id FROM r),to_timestamp(1764086400+3650.000),76561198000000012,NULL,'security',NULL,1.0,2.0,3.0,76561198000000011,NULL,'security',NULL,4.0,5.0,6.0,NULL,NULL,'m4a1','chest',false,false,false,false,false,false,2,0,'standing','hip',40);
WITH r AS (SELECT :key AS id) INSERT INTO hits (round_id, hit_at, victim_steam_id, victim_bot_name, victim_team, victim_bot_class_id, victim_x, victim_y, victim_z, attacker_steam_id, attacker_bot_name, attacker_team, attacker_bot_class_id, attacker_x, attacker_y, attacker_z, weapon_name, hitgroup, damage, health_after, damagebits, attacker_stance, attacker_aim) VALUES ((SELECT id FROM r),to_timestamp(1764086400+3660.000),76561198000000011,NULL,'security',NULL,4.000000,5.000000,6.000000,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'generic',7,68,32,NULL,NULL);
WITH r AS (SELECT :key AS id) INSERT INTO player_spans (round_id, steam_id, started_at, ended_at, team, squad, squad_slot, class_template) VALUES ((SELECT id FROM r),76561198000000012,to_timestamp(1764086400+3610.500),to_timestamp(1764086400+3700.000),'security',NULL,NULL,NULL) ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) INSERT INTO counterattacks (round_id, control_point, started_at, ended_at, finale) VALUES ((SELECT id FROM r),1,to_timestamp(1764086400+3628.000),to_timestamp(1764086400+3660.000),false) ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) UPDATE rounds SET ended_at = to_timestamp(1764086400+3700.000), live_at = COALESCE(live_at, to_timestamp(1764086400+3615.000)), winner = 'security', end_reason = 'objective', mvp_steam_id = 76561198000000011 WHERE round_id = (SELECT id FROM r);
WITH r AS (SELECT :key AS id) INSERT INTO v2_player_rounds AS p (round_id, steam_id, score, capture_ticks, objective_resets, suppressions, times_suppressed, enemies_flashed, teammates_flashed) SELECT id, 76561198000000011, 10, 0, 0, 1, 0, 0, 0 FROM r ON CONFLICT (round_id, steam_id) DO UPDATE SET score = p.score + EXCLUDED.score, capture_ticks = p.capture_ticks + EXCLUDED.capture_ticks, objective_resets = p.objective_resets + EXCLUDED.objective_resets, suppressions = p.suppressions + EXCLUDED.suppressions, times_suppressed = p.times_suppressed + EXCLUDED.times_suppressed, enemies_flashed = p.enemies_flashed + EXCLUDED.enemies_flashed, teammates_flashed = p.teammates_flashed + EXCLUDED.teammates_flashed;
WITH r AS (SELECT :key AS id) INSERT INTO v2_player_round_weapons AS w (round_id, steam_id, weapon_name, shots, shots_hit_enemy, shots_hit_friendly, reloads, deploys, seconds_drawn) SELECT r.id, 76561198000000011, v.* FROM r, (VALUES ('m4a1',10,2,1,1,0,20)) v ON CONFLICT (round_id, steam_id, weapon_name) DO UPDATE SET shots = w.shots + EXCLUDED.shots, shots_hit_enemy = w.shots_hit_enemy + EXCLUDED.shots_hit_enemy, shots_hit_friendly = w.shots_hit_friendly + EXCLUDED.shots_hit_friendly, reloads = w.reloads + EXCLUDED.reloads, deploys = w.deploys + EXCLUDED.deploys, seconds_drawn = w.seconds_drawn + EXCLUDED.seconds_drawn;
WITH r AS (SELECT :key AS id) INSERT INTO team_kill_forgives (kill_id, forgiven_at) SELECT kill_id, to_timestamp(1764086400+3655.000) FROM kills WHERE attacker_steam_id = 76561198000000011 AND victim_steam_id = 76561198000000012 ORDER BY killed_at DESC LIMIT 1 ON CONFLICT DO NOTHING;
WITH r AS (SELECT :key AS id) UPDATE map_runs SET game_over_at = to_timestamp(1764086400+3705.000) WHERE map_run_id = (SELECT map_run_id FROM rounds WHERE round_id = (SELECT id FROM r));
UPDATE sessions SET disconnected_at = to_timestamp(1764086400+3710.000), disconnect_reason = 'Disconnect by user.' WHERE steam_id = 76561198000000011 AND connected_at = to_timestamp(1764086400+3500.000);
WITH r AS (SELECT :key AS id) SELECT stats_refresh_round((SELECT id FROM r));
COMMIT;

DO $$
DECLARE pr record; w record; r record; c record;
BEGIN
    SELECT * INTO r FROM rounds JOIN map_runs USING (map_run_id) WHERE map_name = 'sinjar';
    ASSERT r.round_number = 1 AND r.winner = 'security' AND r.mvp_steam_id = 76561198000000011 AND r.load_seconds = 4.125
           AND r.game_over_at IS NOT NULL AND r.live_at IS NOT NULL, 'round row';
    ASSERT (SELECT count(*) FROM rounds JOIN map_runs USING (map_run_id) WHERE map_name = 'sinjar') = 1, 'one round across both flushes';
    ASSERT (SELECT count(*) FROM player_round_results WHERE round_id = r.round_id) > 0, 'the round-end flush cached the round';
    SELECT * INTO pr FROM v2_player_rounds WHERE steam_id = 76561198000000011 AND round_id = r.round_id;
    ASSERT pr.score = 40 AND pr.suppressions = 5, format('player_rounds %s', pr);
    SELECT * INTO w FROM v2_player_round_weapons WHERE steam_id = 76561198000000011 AND weapon_name = 'm4a1';
    ASSERT w.shots = 40 AND w.seconds_drawn = 61, format('weapons %s', w);
    -- Hits and damage come from hits plus each kill's killing blow: 20 (hit) + 80 (kill) to the bot,
    -- 40 (team kill) to a teammate; one head hit (the kill), one chest hit (the hit, not the team kill).
    SELECT * INTO w FROM v_player_round_weapon_stats WHERE steam_id = 76561198000000011 AND weapon_name = 'm4a1' AND round_id = r.round_id;
    ASSERT w.damage_enemy = 100 AND w.damage_friendly = 40 AND w.hits_head = 1 AND w.hits_chest = 1 AND w.hits_stomach = 0
           AND w.kills = 1 AND w.shots = 40, format('weapon stats %s', w);
    ASSERT (SELECT count(*) FROM v_hits WHERE round_id = r.round_id) = 3 AND (SELECT count(*) FROM v_hits WHERE round_id = r.round_id AND kind = 'world' AND damagebits & 32 <> 0 AND damage = 7) = 1,
           'hits rows, a fall among them';
    ASSERT (SELECT attacker_bot_class FROM v_hits WHERE attacker_bot_name = 'Rifleman O''Neil') = 'template_rifleman_insurgent_coop', 'hit bot class by key';
    ASSERT (SELECT count(*) FROM team_kill_forgives) = 1, 'forgive linked to the team kill';
    ASSERT (SELECT refunded_at IS NOT NULL FROM v2_fire_support_calls WHERE failure_reason = 'player_cooldown'), 'refund marked the latest call';
    ASSERT (SELECT max(item_id) FROM items) = 2, 'known item names do not use up item keys';
    ASSERT (SELECT victim_bot_class FROM v_kills WHERE victim_bot_name = 'Rifleman O''Neil') = 'template_rifleman_insurgent_coop', 'bot class by key';
    ASSERT (SELECT count(*) FROM spawn_items) = 2 AND (SELECT count(*) FROM heal_holds) = 1, 'child rows';
    ASSERT (SELECT ended_at IS NOT NULL FROM counterattacks), 'counterattack written at its end';
    ASSERT (SELECT name FROM v_players WHERE steam_id = 76561198000000011) = 'Charlie O''Test', 'quoted name';
    SELECT * INTO c FROM v_player_round_stats WHERE steam_id = 76561198000000011 AND round_id = r.round_id;
    ASSERT c.kills = 1 AND c.team_kills = 1 AND c.caps = 1 AND c.revives = 1 AND c.heals = 1 AND c.wins = 0
           AND c.damage_enemy = 100 AND c.damage_taken = 32 AND c.headshot_hits = 1,
           format('round stats %s', c);    -- span ended before the round end: not present at the end
END $$;

-- gg2_teamkill's amnesty and offender lookups (phase 4), as it formats them.
DO $$ BEGIN
    ASSERT (SELECT array_agg(steam_id::text) FROM "stats_test".v_player_lifetime
            WHERE steam_id = ANY(ARRAY[76561198000000011,76561198000000012]::bigint[]) AND kills >= 1 AND team_kills > 0
            AND (kills::numeric / team_kills) > 0) = ARRAY['76561198000000011'], 'amnesty lookup';
    ASSERT (SELECT count(*) FROM "stats_test".v_player_lifetime
            WHERE steam_id = ANY(ARRAY[76561198000000011]::bigint[]) AND kills >= 500 AND team_kills > 0
            AND (kills::numeric / team_kills) < 100) = 0, 'offender lookup';
END $$;
