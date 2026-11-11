package main

import "time"

// PlayerStats mirrors a row in the player_stats table.
type PlayerStats struct {
	SteamID string `json:"steam_id"`
	// Name is the player's most recent in-game name, or null if they have not
	// connected since gg2_mstats2 started recording names.
	Name          *string `json:"name"`
	Kills         int     `json:"kills"`
	Deaths        int     `json:"deaths"`
	Suicides      int     `json:"suicides"`
	HeadshotGiven int     `json:"headshot_given"`
	HeadshotTaken int     `json:"headshot_taken"`
	Suppressions  int     `json:"suppressions"`
	Caps          int     `json:"caps"`
	Killstreak    int     `json:"killstreak"`
	Score         int     `json:"score"`
	Wins          int     `json:"wins"`
	Losses        int     `json:"losses"`
	// PlayTimeSeconds is time spent on the Security team. gg2_mstats2 only
	// started counting it in 2026-11, so earlier play is missing.
	PlayTimeSeconds int64 `json:"play_time_seconds"`
	// Shots, EnemyHits and FriendlyHits total player_shots over every
	// firearm: rounds fired, and rounds that damaged at least one enemy or
	// teammate. Counted since 2026-11.
	Shots        int64 `json:"shots"`
	EnemyHits    int64 `json:"enemy_hits"`
	FriendlyHits int64 `json:"friendly_hits"`
	// EnemyHitRate is enemy_hits / shots as a percentage, or null with no
	// shots recorded.
	EnemyHitRate *float64  `json:"enemy_hit_rate"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
}

// PlayerWeapon is one weapon in a player's breakdown: kills (player_kills)
// and rounds fired and hit (player_shots). A weapon appears if either has a
// row, so the other half may be zero.
type PlayerWeapon struct {
	WeaponName   string `json:"weapon_name"`
	KillCount    int    `json:"kill_count"`
	Shots        int    `json:"shots"`
	EnemyHits    int    `json:"enemy_hits"`
	FriendlyHits int    `json:"friendly_hits"`
	// EnemyHitRate is enemy_hits / shots as a percentage, or null with no
	// shots recorded.
	EnemyHitRate *float64 `json:"enemy_hit_rate"`
}

// WeaponKills represents how many kills a player has with a single weapon.
type WeaponKills struct {
	WeaponName string `json:"weapon_name"`
	KillCount  int    `json:"kill_count"`
}

// WeaponTotals aggregates kills for a weapon across all players.
type WeaponTotals struct {
	WeaponName    string `json:"weapon_name"`
	TotalKills    int    `json:"total_kills"`
	UniquePlayers int    `json:"unique_players"`
}

// MapStats summarises a single map: win/loss outcomes (from gg2_mstats2's
// win_loss_log) and accumulated playtime (from map_logger's maps table). A map
// can appear in either source alone, so each half is zero/null when the other
// source has no record of it.
type MapStats struct {
	MapName     string `json:"map_name"`
	Wins        int    `json:"wins"`
	Losses      int    `json:"losses"`
	TotalRounds int    `json:"total_rounds"`
	// WinRate is a percentage (0-100), or null when no rounds are logged.
	WinRate *float64 `json:"win_rate"`
	// PlayTimeSeconds is the total time played on the map. map_logger adds the
	// elapsed time at each round end, so time after the final round (e.g. the
	// map vote) is not counted.
	PlayTimeSeconds int64 `json:"play_time_seconds"`
	// LastPlayedAt is when map_logger last recorded activity on the map (a map
	// start or a round end), or null if it has never seen the map.
	LastPlayedAt *time.Time `json:"last_played_at"`
}

// MatchResult is a single entry from the win/loss log.
type MatchResult struct {
	MapName  string    `json:"map_name"`
	Win      bool      `json:"win"`
	PlayedAt time.Time `json:"played_at"`
}

// BotStats is a bot ranked by total kills (from the bot_kills table).
type BotStats struct {
	BotName    string `json:"bot_name"`
	TotalKills int    `json:"total_kills"`
}

// MedicStats is a player ranked by time spent as medic, in seconds (from the
// gg2_medic_tracker schema).
type MedicStats struct {
	SteamID   string  `json:"steam_id"`
	Name      *string `json:"name"`
	MedicTime int     `json:"medic_time"`
}

// TeamKillStats is a player's team-kill record (from the gg2_teamkill schema).
// SteamID is serialized as a string because a SteamID64 exceeds JavaScript's
// safe-integer range.
type TeamKillStats struct {
	SteamID string  `json:"steam_id"`
	Name    *string `json:"name"`
	// Kills is the player's total kills, joined in from player_stats, so it can
	// be compared against TKGiven as a kill/teamkill ratio.
	Kills   int `json:"kills"`
	TKGiven int `json:"tk_given"`
	TKTaken int `json:"tk_taken"`
	// TKForgiven is how many of the player's logged team kills their victim
	// forgave. It counts player_tk_logs rows, so team kills from before that
	// log existed are included in TKGiven but can never count as forgiven.
	TKForgiven int        `json:"tk_forgiven"`
	LastSeen   *time.Time `json:"last_seen"`
}

// TeamKillWeaponStats aggregates logged team kills by the weapon used (from
// gg2_teamkill's player_tk_logs).
type TeamKillWeaponStats struct {
	Weapon    string `json:"weapon"`
	TeamKills int    `json:"team_kills"`
	Forgiven  int    `json:"forgiven"`
}

// FireSupportStats is a player ranked by fire-support (artillery) calls, from
// the FireSupport plugin's fire_support table.
type FireSupportStats struct {
	SteamID    string  `json:"steam_id"`
	Name       *string `json:"name"`
	ArtyThrown int     `json:"arty_thrown"`
	// LastUsedAt is when the player last called fire support, or null if the
	// plugin never recorded a time.
	LastUsedAt *time.Time `json:"last_used_at"`
}

// ListResponse is the envelope for every paginated list endpoint. Total is the
// number of records matching the query before limit/offset, so a client can
// build pagination controls.
type ListResponse[T any] struct {
	Items  []T `json:"items"`
	Total  int `json:"total"`
	Limit  int `json:"limit"`
	Offset int `json:"offset"`
}
