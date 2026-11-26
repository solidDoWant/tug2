package main

import "time"

// Response types. The `db` tags name the SQL column each field is scanned
// from (pgx.RowToStructByName), so every query's column aliases must match.
//
// SteamIDs are BIGINT in the database and strings here: a SteamID64 is beyond
// JavaScript's safe-integer range. Pointer fields are JSON null when the view
// returns NULL: with a time window, a stat the pre-v2 history never recorded
// (documented "v2 only" in the schema comments) is null rather than 0 when no
// v2 row in the window has it.

// PlayerStats is one player's totals: lifetime (v_player_lifetime), or summed
// from v_player_round_stats over a window.
type PlayerStats struct {
	SteamID string `json:"steam_id" db:"steam_id"`
	// Name is the latest in-game name (v_players), or null if never recorded.
	Name   *string `json:"name" db:"name"`
	Kills  *int64  `json:"kills" db:"kills" doc:"Enemy kills."`
	Deaths *int64  `json:"deaths" db:"deaths" doc:"Deaths of any kind."`
	// KD is kills / deaths to two decimals, or kills when there are no deaths.
	KD      *float64 `json:"kd" db:"kd" doc:"kills / deaths (2 decimals); kills when deaths is 0."`
	Assists *int64   `json:"assists" db:"assists" doc:"Assists on enemy kills. v2 only."`
	Score   *int64   `json:"score" db:"score"`
	Wins    *int64   `json:"wins" db:"wins" doc:"Rounds won while on the players' side at the round end."`
	Losses  *int64   `json:"losses" db:"losses"`
	// RoundsPlayed counts v2 rounds with play time; earlier play is not counted.
	RoundsPlayed     int64  `json:"rounds_played" db:"rounds_played" doc:"v2 rounds with Security play time (not counted before v2)."`
	PlaySeconds      *int64 `json:"play_seconds" db:"play_seconds" doc:"Seconds on the Security team."`
	MedicSeconds     *int64 `json:"medic_seconds" db:"medic_seconds" doc:"Seconds played as a medic class."`
	Suicides         *int64 `json:"suicides" db:"suicides"`
	WorldDeaths      *int64 `json:"world_deaths" db:"world_deaths" doc:"Deaths with no attacker (falls etc.). v2 only."`
	TeamKills        *int64 `json:"team_kills" db:"team_kills"`
	TeamKilled       *int64 `json:"team_killed" db:"team_killed" doc:"Times killed by a teammate."`
	HeadshotKills    *int64 `json:"headshot_kills" db:"headshot_kills" doc:"Enemy kills by headshot. v2 only."`
	HeadshotHits     *int64 `json:"headshot_hits" db:"headshot_hits" doc:"Hits to an enemy's head."`
	Caps             *int64 `json:"caps" db:"caps" doc:"Control points captured (before v2 this included caches)."`
	CacheKills       *int64 `json:"cache_kills" db:"cache_kills" doc:"Caches destroyed or assisted. v2 only."`
	Revives          *int64 `json:"revives" db:"revives"`
	TimesRevived     *int64 `json:"times_revived" db:"times_revived" doc:"v2 only."`
	Heals            *int64 `json:"heals" db:"heals" doc:"Heals to full health."`
	HPHealed         *int64 `json:"hp_healed" db:"hp_healed" doc:"Health points given by healing. v2 only."`
	FireSupportCalls *int64 `json:"fire_support_calls" db:"fire_support_calls" doc:"Successful fire-support calls."`
	Suppressions     *int64 `json:"suppressions" db:"suppressions"`
	TimesSuppressed  *int64 `json:"times_suppressed" db:"times_suppressed" doc:"v2 only."`
	Shots            *int64 `json:"shots" db:"shots" doc:"Rounds fired from firearms (a shotgun shell is one)."`
	ShotsHitEnemy    *int64 `json:"shots_hit_enemy" db:"shots_hit_enemy" doc:"Shots that damaged at least one enemy."`
	ShotsHitFriendly *int64 `json:"shots_hit_friendly" db:"shots_hit_friendly" doc:"Shots that damaged at least one teammate."`
	// Accuracy is shots_hit_enemy / shots as a percentage, or null with no shots.
	Accuracy    *float64 `json:"accuracy" db:"accuracy" doc:"100 * shots_hit_enemy / shots (1 decimal); null with no shots."`
	DamageEnemy *int64   `json:"damage_enemy" db:"damage_enemy" doc:"Damage dealt to enemies. v2 only."`
	DamageTaken *int64   `json:"damage_taken" db:"damage_taken" doc:"v2 only."`
	// BestKillstreak is lifetime only: null with a window.
	BestKillstreak *int64     `json:"best_killstreak" db:"best_killstreak" doc:"Most enemy kills between two deaths, lifetime. Null with a window."`
	FirstSeen      *time.Time `json:"first_seen" db:"first_seen"`
	LastSeen       *time.Time `json:"last_seen" db:"last_seen"`
}

// PlayerDetail is one player: their stats, name history, and the window.
type PlayerDetail struct {
	PlayerStats
	NameHistory []NameChange `json:"name_history" db:"-" doc:"Names used, newest first (consecutive repeats collapsed). v2 only."`
	Window      *WindowInfo  `json:"window,omitempty" db:"-"`
}

// NameChange is one name a player took on, and when.
type NameChange struct {
	Name      string    `json:"name" db:"name"`
	ChangedAt time.Time `json:"changed_at" db:"changed_at"`
}

// PlayerWeapon is one weapon in a player's breakdown.
type PlayerWeapon struct {
	WeaponName       string   `json:"weapon_name" db:"weapon_name"`
	WeaponType       *string  `json:"weapon_type" db:"weapon_type" doc:"Null for weapons only the pre-v2 stats know."`
	Kills            int64    `json:"kills" db:"kills"`
	Shots            int64    `json:"shots" db:"shots"`
	ShotsHitEnemy    int64    `json:"shots_hit_enemy" db:"shots_hit_enemy"`
	ShotsHitFriendly int64    `json:"shots_hit_friendly" db:"shots_hit_friendly"`
	Accuracy         *float64 `json:"accuracy" db:"accuracy"`
	HitsHead         *int64   `json:"hits_head" db:"hits_head" doc:"v2 only (as are all fields below)."`
	HitsChest        *int64   `json:"hits_chest" db:"hits_chest"`
	HitsStomach      *int64   `json:"hits_stomach" db:"hits_stomach"`
	HitsArms         *int64   `json:"hits_arms" db:"hits_arms"`
	HitsLegs         *int64   `json:"hits_legs" db:"hits_legs"`
	DamageEnemy      *int64   `json:"damage_enemy" db:"damage_enemy"`
	DamageFriendly   *int64   `json:"damage_friendly" db:"damage_friendly"`
	Reloads          *int64   `json:"reloads" db:"reloads"`
	Deploys          *int64   `json:"deploys" db:"deploys"`
	SecondsDrawn     *int64   `json:"seconds_drawn" db:"seconds_drawn"`
}

// PlayerClass is a player's time, kills and deaths in one class (v2 only).
type PlayerClass struct {
	ClassTemplate *string `json:"class_template" db:"class_template" doc:"Class template name; null if unknown."`
	Seconds       int64   `json:"seconds" db:"seconds"`
	Kills         int64   `json:"kills" db:"kills" doc:"Enemy kills while in this class."`
	Deaths        int64   `json:"deaths" db:"deaths"`
}

// PlayerRound is one row of a player's round history (v_player_round_stats).
// Rows from before v2 (source "old") have no round, and NULL for the stats the
// old plugins did not record; old medic, team-kill and fire-support history
// arrive as rows of their own.
type PlayerRound struct {
	RoundID   *int64     `json:"round_id" db:"round_id" doc:"Null for pre-v2 rows."`
	Source    string     `json:"source" db:"source" doc:"v2, or old for pre-v2 history."`
	At        time.Time  `json:"at" db:"at" doc:"When the round ended (old rows: when recorded)."`
	MapName   *string    `json:"map_name" db:"map_name"`
	GameMode  *string    `json:"game_mode" db:"game_mode"`
	EndedAt   *time.Time `json:"ended_at" db:"ended_at"`
	Winner    *string    `json:"winner" db:"winner" doc:"security or insurgents; null if unfinished or pre-v2."`
	EndReason *string    `json:"end_reason" db:"end_reason"`
	WasMVP    *bool      `json:"was_mvp" db:"was_mvp"`

	Kills            *int64 `json:"kills" db:"kills"`
	Deaths           *int64 `json:"deaths" db:"deaths"`
	Suicides         *int64 `json:"suicides" db:"suicides"`
	WorldDeaths      *int64 `json:"world_deaths" db:"world_deaths"`
	TeamKills        *int64 `json:"team_kills" db:"team_kills"`
	TeamKilled       *int64 `json:"team_killed" db:"team_killed"`
	Assists          *int64 `json:"assists" db:"assists"`
	HeadshotKills    *int64 `json:"headshot_kills" db:"headshot_kills"`
	HeadshotHits     *int64 `json:"headshot_hits" db:"headshot_hits"`
	Caps             *int64 `json:"caps" db:"caps"`
	CacheKills       *int64 `json:"cache_kills" db:"cache_kills"`
	Score            *int64 `json:"score" db:"score"`
	Wins             *int64 `json:"wins" db:"wins"`
	Losses           *int64 `json:"losses" db:"losses"`
	PlaySeconds      *int64 `json:"play_seconds" db:"play_seconds"`
	MedicSeconds     *int64 `json:"medic_seconds" db:"medic_seconds"`
	Revives          *int64 `json:"revives" db:"revives"`
	TimesRevived     *int64 `json:"times_revived" db:"times_revived"`
	Heals            *int64 `json:"heals" db:"heals"`
	HPHealed         *int64 `json:"hp_healed" db:"hp_healed"`
	FireSupportCalls *int64 `json:"fire_support_calls" db:"fire_support_calls"`
	Suppressions     *int64 `json:"suppressions" db:"suppressions"`
	TimesSuppressed  *int64 `json:"times_suppressed" db:"times_suppressed"`
	Shots            *int64 `json:"shots" db:"shots"`
	ShotsHitEnemy    *int64 `json:"shots_hit_enemy" db:"shots_hit_enemy"`
	ShotsHitFriendly *int64 `json:"shots_hit_friendly" db:"shots_hit_friendly"`
	DamageEnemy      *int64 `json:"damage_enemy" db:"damage_enemy"`
	DamageTaken      *int64 `json:"damage_taken" db:"damage_taken"`
}

// WeaponTotals is one weapon across all players.
type WeaponTotals struct {
	WeaponName       string   `json:"weapon_name" db:"weapon_name"`
	WeaponType       *string  `json:"weapon_type" db:"weapon_type"`
	Kills            int64    `json:"kills" db:"kills"`
	UniquePlayers    int64    `json:"unique_players" db:"unique_players" doc:"Players with at least one kill with it."`
	Shots            int64    `json:"shots" db:"shots"`
	ShotsHitEnemy    int64    `json:"shots_hit_enemy" db:"shots_hit_enemy"`
	ShotsHitFriendly int64    `json:"shots_hit_friendly" db:"shots_hit_friendly"`
	Accuracy         *float64 `json:"accuracy" db:"accuracy"`
}

// WeaponPlayer is one player's record with one weapon.
type WeaponPlayer struct {
	SteamID          string   `json:"steam_id" db:"steam_id"`
	Name             *string  `json:"name" db:"name"`
	Kills            int64    `json:"kills" db:"kills"`
	Shots            int64    `json:"shots" db:"shots"`
	ShotsHitEnemy    int64    `json:"shots_hit_enemy" db:"shots_hit_enemy"`
	ShotsHitFriendly int64    `json:"shots_hit_friendly" db:"shots_hit_friendly"`
	Accuracy         *float64 `json:"accuracy" db:"accuracy"`
}

// MapStats is one map (v_maps).
type MapStats struct {
	MapName string `json:"map_name" db:"map_name"`
	Rounds  int64  `json:"rounds" db:"rounds" doc:"Rounds that ended (pre-v2: logged results)."`
	Wins    int64  `json:"wins" db:"wins"`
	Losses  int64  `json:"losses" db:"losses"`
	// WinRate is a percentage (0-100), or null with no decided rounds.
	WinRate      *float64   `json:"win_rate" db:"win_rate" doc:"100 * wins / (wins + losses), 2 decimals; null with none."`
	PlaySeconds  int64      `json:"play_seconds" db:"play_seconds"`
	LastPlayedAt *time.Time `json:"last_played_at" db:"last_played_at"`
}

// MapDetail is one map with its recent runs and kill positions.
type MapDetail struct {
	MapStats
	RecentRuns    []MapRunBrief  `json:"recent_runs" db:"-" doc:"The last 20 map runs (v2), newest first."`
	KillPositions []KillPosition `json:"kill_positions" db:"-" doc:"Recent v2 kills on the map with a recorded position, newest first."`
}

// MapRunBrief is a map run in a map's history.
type MapRunBrief struct {
	MapRunID    int64      `json:"map_run_id" db:"map_run_id"`
	StartedAt   time.Time  `json:"started_at" db:"started_at"`
	GameMode    string     `json:"game_mode" db:"game_mode"`
	Rounds      int64      `json:"rounds" db:"rounds" doc:"Rounds that ended."`
	GameOverAt  *time.Time `json:"game_over_at" db:"game_over_at"`
	LoadSeconds *float64   `json:"load_seconds" db:"load_seconds"`
}

// KillPosition is where one kill happened.
type KillPosition struct {
	KilledAt   time.Time `json:"killed_at" db:"killed_at"`
	Kind       string    `json:"kind" db:"kind" doc:"enemy, team_kill, suicide or world."`
	VictimX    *float64  `json:"victim_x" db:"victim_x"`
	VictimY    *float64  `json:"victim_y" db:"victim_y"`
	VictimZ    *float64  `json:"victim_z" db:"victim_z"`
	AttackerX  *float64  `json:"attacker_x" db:"attacker_x"`
	AttackerY  *float64  `json:"attacker_y" db:"attacker_y"`
	AttackerZ  *float64  `json:"attacker_z" db:"attacker_z"`
	WeaponName *string   `json:"weapon_name" db:"weapon_name"`
	Headshot   bool      `json:"headshot" db:"headshot"`
}

// MapRun is one map load (v2 only).
type MapRun struct {
	MapRunID     int64      `json:"map_run_id" db:"map_run_id"`
	MapName      string     `json:"map_name" db:"map_name"`
	GameMode     string     `json:"game_mode" db:"game_mode"`
	Theater      *string    `json:"theater" db:"theater"`
	StartedAt    time.Time  `json:"started_at" db:"started_at"`
	GameOverAt   *time.Time `json:"game_over_at" db:"game_over_at"`
	LoadSeconds  *float64   `json:"load_seconds" db:"load_seconds"`
	GitCommit    string     `json:"git_commit" db:"git_commit"`
	ImageVersion string     `json:"image_version" db:"image_version"`
	Rounds       int64      `json:"rounds" db:"rounds" doc:"Rounds that ended."`
	Wins         int64      `json:"wins" db:"wins"`
	Losses       int64      `json:"losses" db:"losses"`
}

// MapRunDetail is a map run with its rounds and scoreboard. The run is nested
// (not inlined) because its round count is also called rounds.
type MapRunDetail struct {
	Run        MapRun            `json:"run"`
	Rounds     []Round           `json:"rounds" doc:"The run's rounds in order."`
	Scoreboard []ScoreboardEntry `json:"scoreboard" doc:"Per player, summed over the run's rounds (v_player_round_stats); by score."`
}

// Round is one v2 round.
type Round struct {
	RoundID     int64      `json:"round_id" db:"round_id"`
	MapRunID    int64      `json:"map_run_id" db:"map_run_id"`
	MapName     string     `json:"map_name" db:"map_name"`
	GameMode    string     `json:"game_mode" db:"game_mode"`
	RoundNumber int64      `json:"round_number" db:"round_number"`
	StartedAt   time.Time  `json:"started_at" db:"started_at"`
	LiveAt      *time.Time `json:"live_at" db:"live_at"`
	EndedAt     *time.Time `json:"ended_at" db:"ended_at"`
	Winner      *string    `json:"winner" db:"winner" doc:"security or insurgents; null if unfinished."`
	EndReason   *string    `json:"end_reason" db:"end_reason" doc:"objective, elimination, time_expired or draw."`
	MVPSteamID  *string    `json:"mvp_steam_id" db:"mvp_steam_id"`
	MVPName     *string    `json:"mvp_name" db:"mvp_name"`
}

// RoundDetail is a round with its timeline.
type RoundDetail struct {
	Round
	Timeline []TimelineEvent `json:"timeline" db:"-" doc:"Everything that happened, by time."`
}

// ScoreboardEntry is one player's line on a map run's scoreboard.
type ScoreboardEntry struct {
	SteamID     string  `json:"steam_id" db:"steam_id"`
	Name        *string `json:"name" db:"name"`
	Kills       int64   `json:"kills" db:"kills"`
	Deaths      int64   `json:"deaths" db:"deaths"`
	Assists     int64   `json:"assists" db:"assists"`
	Score       int64   `json:"score" db:"score"`
	Revives     int64   `json:"revives" db:"revives"`
	Heals       int64   `json:"heals" db:"heals"`
	Caps        int64   `json:"caps" db:"caps"`
	PlaySeconds int64   `json:"play_seconds" db:"play_seconds"`
}

// TimelineEvent is one event in a round. Which fields are present depends on
// type; fields that don't apply, or are null, are omitted.
//
//	kill                 kind, attacker_*, victim_*, weapon_name, headshot
//	objective            kind, control_point, cp_name, team, weapon_name, participants
//	counterattack_start  control_point, finale
//	counterattack_end    control_point, finale
//	revive               reviver_*, revived_*, method
//	survival_level       level
type TimelineEvent struct {
	At   time.Time `json:"at" db:"at"`
	Type string    `json:"type" db:"type" enum:"kill,objective,counterattack_start,counterattack_end,revive,survival_level"`
	// Kind is the kill kind (enemy, team_kill, suicide, world) or the
	// objective kind (captured, neutralized, cache_destroyed).
	Kind            *string `json:"kind,omitempty" db:"kind"`
	AttackerSteamID *string `json:"attacker_steam_id,omitempty" db:"attacker_steam_id"`
	AttackerBotName *string `json:"attacker_bot_name,omitempty" db:"attacker_bot_name"`
	AttackerName    *string `json:"attacker_name,omitempty" db:"attacker_name" doc:"Player name, or the bot name."`
	VictimSteamID   *string `json:"victim_steam_id,omitempty" db:"victim_steam_id"`
	VictimBotName   *string `json:"victim_bot_name,omitempty" db:"victim_bot_name"`
	VictimName      *string `json:"victim_name,omitempty" db:"victim_name" doc:"Player name, or the bot name."`
	WeaponName      *string `json:"weapon_name,omitempty" db:"weapon_name"`
	Headshot        *bool   `json:"headshot,omitempty" db:"headshot"`

	ControlPoint *int64                 `json:"control_point,omitempty" db:"control_point"`
	CPName       *string                `json:"cp_name,omitempty" db:"cp_name"`
	Team         *string                `json:"team,omitempty" db:"team"`
	Participants []ObjectiveParticipant `json:"participants,omitempty" db:"participants"`
	Finale       *bool                  `json:"finale,omitempty" db:"finale"`

	ReviverSteamID *string `json:"reviver_steam_id,omitempty" db:"reviver_steam_id"`
	ReviverName    *string `json:"reviver_name,omitempty" db:"reviver_name"`
	RevivedSteamID *string `json:"revived_steam_id,omitempty" db:"revived_steam_id"`
	RevivedName    *string `json:"revived_name,omitempty" db:"revived_name"`
	Method         *string `json:"method,omitempty" db:"method" doc:"Revive method: defib, knife or healthkit."`

	Level *int64 `json:"level,omitempty" db:"level" doc:"Survival level reached."`
}

// ObjectiveParticipant is a player credited with an objective.
type ObjectiveParticipant struct {
	SteamID string  `json:"steam_id"`
	Name    *string `json:"name"`
	Role    string  `json:"role" doc:"capper, attacker or assister."`
}

// BotStats is a bot's kills of human players (v_bot_weapon_kills).
type BotStats struct {
	BotName    string `json:"bot_name" db:"bot_name"`
	TotalKills int64  `json:"total_kills" db:"total_kills"`
}

// WeaponKills is kills with one weapon.
type WeaponKills struct {
	WeaponName string `json:"weapon_name" db:"weapon_name"`
	Kills      int64  `json:"kills" db:"kills"`
}

// MedicStats is one player's medic record.
type MedicStats struct {
	SteamID      string  `json:"steam_id" db:"steam_id"`
	Name         *string `json:"name" db:"name"`
	MedicSeconds *int64  `json:"medic_seconds" db:"medic_seconds"`
	Revives      *int64  `json:"revives" db:"revives"`
	TimesRevived *int64  `json:"times_revived" db:"times_revived" doc:"v2 only."`
	Heals        *int64  `json:"heals" db:"heals"`
	HPHealed     *int64  `json:"hp_healed" db:"hp_healed" doc:"v2 only."`
	// AvgReviveSeconds is the mean time from starting a revive to finishing it.
	AvgReviveSeconds *float64 `json:"avg_revive_seconds" db:"avg_revive_seconds" doc:"Mean seconds per completed revive as the reviver (1 decimal). v2 only; null with none."`
}

// TeamKillStats is one player's team-kill record.
type TeamKillStats struct {
	SteamID    string  `json:"steam_id" db:"steam_id"`
	Name       *string `json:"name" db:"name"`
	Kills      *int64  `json:"kills" db:"kills" doc:"Enemy kills, for context."`
	TeamKills  *int64  `json:"team_kills" db:"team_kills"`
	TeamKilled *int64  `json:"team_killed" db:"team_killed"`
	Forgiven   int64   `json:"forgiven" db:"forgiven" doc:"Of the logged team kills (v_team_kills; logged since 2025-12), how many the victim forgave."`
}

// TeamKillWeaponStats is team kills with one weapon (v_team_kills).
type TeamKillWeaponStats struct {
	WeaponName *string `json:"weapon_name" db:"weapon_name"`
	TeamKills  int64   `json:"team_kills" db:"team_kills"`
	Forgiven   int64   `json:"forgiven" db:"forgiven"`
}

// FireSupportStats is one player's fire-support record.
type FireSupportStats struct {
	SteamID      string     `json:"steam_id" db:"steam_id"`
	Name         *string    `json:"name" db:"name"`
	Calls        *int64     `json:"calls" db:"calls" doc:"Successful calls."`
	Failed       int64      `json:"failed" db:"failed" doc:"Calls that failed (e.g. on cooldown). v2 only."`
	Refunded     int64      `json:"refunded" db:"refunded" doc:"Calls refunded. v2 only."`
	LastCalledAt *time.Time `json:"last_called_at" db:"last_called_at" doc:"Last successful call."`
}

// ListResponse is the envelope for every paginated list endpoint. Total is the
// number of records matching the query before limit/offset, so a client can
// build pagination controls.
type ListResponse[T any] struct {
	Items  []T `json:"items"`
	Total  int `json:"total"`
	Limit  int `json:"limit"`
	Offset int `json:"offset"`
	// Window is set when the request asked for a time window.
	Window *WindowInfo `json:"window,omitempty"`
}
