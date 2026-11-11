package main

// queryableTables are the tables the discord-bot database role may read, as
// granted by plugins/sourcemod/configs/sql-init-scripts/pgsql/discord_bot_grants.sql
// (which every game server applies to its own schema). TestQueryableTables
// checks this list against that file and against statsSchemaDoc.
var queryableTables = []string{
	"player_stats", "player_kills", "weapon_stats", "bot_kills", "map_stats",
	"win_loss_log", "maps", "medics", "fire_support", "player_tks", "player_tk_logs",
	"player_drag_mode", "player_fy_opt_out", "players_smoke_cache", "smoke_warning_seen",
	"gg2_messages_rotating_player", "gg2_messages_rotating_admin", "gg2_messages_join_player",
}

// statsSchemaDoc describes the tables query_stats can read. It is part of the
// tool definition, so it is cached with the rest of the request prefix. Every
// table in queryableTables must be described here.
const statsSchemaDoc = `Tables (PostgreSQL; each server has its own copy, selected by the server parameter, so never schema-qualify names):
- player_stats: one row per player. steam_id varchar (SteamID64 as text, the key everywhere), name (latest Steam/in-game name, may be NULL), kills, deaths, suicides, headshot_given, headshot_taken, suppressions, caps, killstreak (best), score, wins, losses (rounds), created_at (first seen), updated_at (last seen).
- player_kills: steam_id, weapon_id, kill_count: a player's kills per weapon. Join weapon_stats.
- weapon_stats: weapon_id, weapon_name (no "weapon_" prefix; explosives are named by projectile, e.g. rocket_rpg7, grenade_m67, grenade_c4).
- bot_kills: bot_name, weapon_id, kill_count: kills on players by each AI bot name, per weapon.
- map_stats: map_id, map_name. win_loss_log: id, map_id, win (boolean: true when the players won the round), created_at (when the round ended).
- maps: map_name, play_time (interval, returned as seconds), last_start, created_at, updated_at. Playtime per map, from a separate plugin; join on map_name.
- medics: steamid (lowercase column name; SteamID64 text), medic_time (seconds as medic), banned (boolean: barred from the medic class), created_at, updated_at.
- fire_support: steamid (SteamID64 text), arty_thrown (artillery calls), last_used (Unix seconds; 0 = unknown, use to_timestamp), created_at.
- player_tks: steam_id (bigint; join with player_stats.steam_id = player_tks.steam_id::text), tk_given, tk_taken, last_seen, created_at, updated_at.
- player_tk_logs: one row per logged team kill: victim_steam_id, attacker_steam_id (bigint), forgiven (boolean), weapon, created_at. Starts later than the tk_given/tk_taken totals.
- Player settings (rarely useful): player_drag_mode (steam_id bigint, toggle_drag), player_fy_opt_out (steam_id bigint, opt_out), players_smoke_cache (steam_id bigint, has_smoke, auto_retry_opt_out), smoke_warning_seen (test server only: steam_id bigint, shown_count, first_shown_at, last_shown_at).
- In-game chat messages the server rotates: gg2_messages_rotating_player, gg2_messages_rotating_admin, gg2_messages_join_player (id, message, enabled). Many messages are translation keys rather than text.
Notes: timestamps are UTC (timestamp without time zone). Counts are lifetime totals per server. For K/D, divide by NULLIF(deaths, 0) and say how you treated players with no deaths; for averages, consider leaving out players with very few kills or deaths and say so.`
