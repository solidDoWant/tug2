package main

import "time"

// PlayerStats mirrors a row in the player_stats table.
type PlayerStats struct {
	SteamID       string    `json:"steam_id"`
	Kills         int       `json:"kills"`
	Deaths        int       `json:"deaths"`
	Suicides      int       `json:"suicides"`
	HeadshotGiven int       `json:"headshot_given"`
	HeadshotTaken int       `json:"headshot_taken"`
	Suppressions  int       `json:"suppressions"`
	Caps          int       `json:"caps"`
	Killstreak    int       `json:"killstreak"`
	Score         int       `json:"score"`
	Wins          int       `json:"wins"`
	Losses        int       `json:"losses"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
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

// MapStats summarises win/loss outcomes for a single map.
type MapStats struct {
	MapName     string  `json:"map_name"`
	Wins        int     `json:"wins"`
	Losses      int     `json:"losses"`
	TotalRounds int     `json:"total_rounds"`
	WinRate     float64 `json:"win_rate"`
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
	SteamID   string `json:"steam_id"`
	MedicTime int    `json:"medic_time"`
}

// TeamKillStats is a player's team-kill record (from the gg2_teamkill schema).
// SteamID is serialized as a string because a SteamID64 exceeds JavaScript's
// safe-integer range.
type TeamKillStats struct {
	SteamID  string     `json:"steam_id"`
	Kills    int        `json:"kills"`
	TKGiven  int        `json:"tk_given"`
	TKTaken  int        `json:"tk_taken"`
	LastSeen *time.Time `json:"last_seen"`
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
