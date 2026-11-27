-- =====================================================
-- Stats v2 (issue #44), part 8: descriptions of the identity, reference and match tables.
-- The Discord bot's query_stats tool shows these to the model writing SQL (tools/discord-bot), so
-- every table and column is described: what it holds, its unit, what NULL means, and any trap.
-- =====================================================

COMMENT ON TABLE v2_maps IS 'Every map played since v2 began. For per-map totals use v_maps.';
COMMENT ON COLUMN v2_maps.map_name IS 'Map name, e.g. ministry.';
COMMENT ON TABLE game_modes IS 'Game modes seen (mp_gamemode).';
COMMENT ON COLUMN game_modes.game_mode IS 'Mode name: checkpoint, conquer, survival, ...';
COMMENT ON TABLE theaters IS 'Theater overrides seen (mp_theater_override).';
COMMENT ON COLUMN theaters.theater_name IS 'Theater name.';
COMMENT ON TABLE weapon_types IS 'Weapon categories, from the theater''s weapon_class.';
COMMENT ON COLUMN weapon_types.weapon_type IS 'Category name, e.g. rifle_automatic_fire, pistol, shotgun.';
COMMENT ON TABLE weapons IS 'Every weapon seen. Names have no weapon_ prefix; explosives are named by projectile (rocket_rpg7, grenade_m67, grenade_c4).';
COMMENT ON COLUMN weapons.weapon_name IS 'Weapon name (ak74, m4a1, rocket_rpg7).';
COMMENT ON COLUMN weapons.weapon_type IS 'weapon_types.weapon_type; NULL until classified.';

COMMENT ON TABLE players IS 'Every human player seen by v2. Names, first/last seen and totals are in v_players and v_player_lifetime.';
COMMENT ON COLUMN players.steam_id IS 'SteamID64 (bigint). The player key in every table.';
COMMENT ON TABLE sessions IS 'One row per connection to the server.';
COMMENT ON COLUMN sessions.steam_id IS 'players.steam_id.';
COMMENT ON COLUMN sessions.connected_at IS 'When the player connected (UTC timestamptz).';
COMMENT ON COLUMN sessions.disconnected_at IS 'When they left; NULL while connected, or if the server crashed.';
COMMENT ON COLUMN sessions.disconnect_reason IS 'The engine''s disconnect reason text.';
COMMENT ON TABLE name_changes IS 'In-game names: one row at each connect and at each name change. Latest per player is the current name (v_players.name).';
COMMENT ON COLUMN name_changes.steam_id IS 'players.steam_id.';
COMMENT ON COLUMN name_changes.connected_at IS 'The session it happened in (sessions.connected_at).';
COMMENT ON COLUMN name_changes.changed_at IS 'When this name was seen or set.';
COMMENT ON COLUMN name_changes.name IS 'The in-game name.';

COMMENT ON TABLE server_builds IS 'Server image builds that have run.';
COMMENT ON COLUMN server_builds.git_commit IS 'Git commit the image was built from; -dirty suffix if built with uncommitted changes.';
COMMENT ON COLUMN server_builds.image_version IS 'Image version tag, e.g. 0.0.27-dev. A tag can be reused; the commit cannot.';
COMMENT ON TABLE server_boots IS 'Each start of the game server process.';
COMMENT ON COLUMN server_boots.booted_at IS 'When the server process started.';
COMMENT ON COLUMN server_boots.git_commit IS 'server_builds.git_commit it was running.';

COMMENT ON TABLE map_runs IS 'Each time a map was loaded and played. Rounds hang off it.';
COMMENT ON COLUMN map_runs.map_run_id IS 'Map run key.';
COMMENT ON COLUMN map_runs.booted_at IS 'server_boots.booted_at: the server process it ran in.';
COMMENT ON COLUMN map_runs.started_at IS 'When the map started.';
COMMENT ON COLUMN map_runs.map_name IS 'v2_maps.map_name.';
COMMENT ON COLUMN map_runs.game_mode IS 'game_modes.game_mode.';
COMMENT ON COLUMN map_runs.theater IS 'theaters.theater_name; NULL when no theater override was set.';
COMMENT ON COLUMN map_runs.load_seconds IS 'Seconds the server took to change to this map; NULL for the first map after a server start.';
COMMENT ON COLUMN map_runs.game_over_at IS 'When the game ended normally (game over and map vote); NULL if the map was left early (admin map change, server emptied) or the server crashed.';

COMMENT ON TABLE rounds IS 'Each round. For rounds with their map and the old (pre-v2) results, use v_rounds.';
COMMENT ON COLUMN rounds.round_id IS 'Round key; most v2 tables reference it.';
COMMENT ON COLUMN rounds.map_run_id IS 'map_runs.map_run_id.';
COMMENT ON COLUMN rounds.round_number IS 'Round number within the map run, from 1.';
COMMENT ON COLUMN rounds.started_at IS 'Round start (preround begins).';
COMMENT ON COLUMN rounds.live_at IS 'When play started (preround over); NULL if it never did.';
COMMENT ON COLUMN rounds.ended_at IS 'Round end; NULL if the map ended mid-round.';
COMMENT ON COLUMN rounds.winner IS 'Winning team: security is the human players. NULL for a draw or a round that never ended.';
COMMENT ON COLUMN rounds.end_reason IS 'Why it ended: objective, elimination, time_expired or draw.';
COMMENT ON COLUMN rounds.mvp_steam_id IS 'The game''s round MVP on the players'' side; NULL if it was a bot or none was chosen.';
COMMENT ON TABLE survival_levels IS 'Survival mode levels reached, with when.';
COMMENT ON COLUMN survival_levels.round_id IS 'rounds.round_id.';
COMMENT ON COLUMN survival_levels.level IS 'Level number reached.';
COMMENT ON COLUMN survival_levels.reached_at IS 'When it was reached.';
COMMENT ON TABLE counterattacks IS 'Enemy counterattacks on a captured point.';
COMMENT ON COLUMN counterattacks.round_id IS 'rounds.round_id.';
COMMENT ON COLUMN counterattacks.control_point IS 'Index of the point counterattacked (0 = first).';
COMMENT ON COLUMN counterattacks.started_at IS 'Counterattack start.';
COMMENT ON COLUMN counterattacks.ended_at IS 'Counterattack end; NULL if the round ended during it.';
COMMENT ON COLUMN counterattacks.finale IS 'True for the map''s last point.';
