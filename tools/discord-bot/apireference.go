package main

import (
	"context"
	"encoding/json"
)

// apiParam is one query parameter of a stats-api endpoint.
type apiParam struct {
	Name        string `json:"name"`
	Description string `json:"description"`
}

// apiEndpoint documents one public stats-api endpoint for the model, so it can
// give users accurate links and curl examples without guessing. It must match
// tools/stats-api; TestAPIReferenceMatchesSpec checks it against the live
// OpenAPI spec.
type apiEndpoint struct {
	Path        string     `json:"path"`
	Description string     `json:"description"`
	Params      []apiParam `json:"query_params,omitempty"`
}

var (
	pageParams = []apiParam{
		{"limit", "page size, 0-200, default 50"},
		{"offset", "entries to skip, 0-100000, default 0"},
	}
	// periodParams select a time window instead of lifetime totals; the
	// response's window says the range.
	periodParams = []apiParam{
		{"period", "only the last N days, e.g. 7d, 30d, 365d (1-3650); not with since/until"},
		{"since", "only from this UTC date (YYYY-MM-DD) or RFC 3339 time, inclusive"},
		{"until", "only before this UTC date or time, exclusive; default now"},
	}
	windowedPage = append(append([]apiParam{}, pageParams...), periodParams...)
	apiEndpoints = []apiEndpoint{
		{"/api/v2/players", "Players with lifetime stats (or stats in a time window), descending.", append([]apiParam{
			{"sort", "score (default), kills, deaths, kd, assists, wins, play_time, accuracy (players with 500+ shots first), revives, heals, caps, headshot_kills, killstreak, last_seen"},
			{"name", "only players whose current in-game name contains this, case-insensitive"},
		}, windowedPage...)},
		{"/api/v2/players/{steam_id}", "One player's stats by SteamID64 (lifetime, or in a time window) and name history; 404 if unknown.", periodParams},
		{"/api/v2/players/{steam_id}/weapons", "One player's stats per weapon: kills, shots, accuracy, hits by body part, damage, reloads, seconds in hand (a plain array).", periodParams},
		{"/api/v2/players/{steam_id}/classes", "One player's time, kills and deaths per class (a plain array).", periodParams},
		{"/api/v2/players/{steam_id}/rounds", "One player's rounds, newest first: map, result, MVP and their stats in each.", windowedPage},
		{"/api/v2/weapons", "Weapons across all players: kills, players with a kill, shots, hits and accuracy.", append([]apiParam{
			{"sort", "kills (default), shots, accuracy (weapons with 1000+ shots first)"},
		}, windowedPage...)},
		{"/api/v2/weapons/{weapon_name}", "Top players with one weapon (e.g. m4a1); 404 for an unknown weapon.", append([]apiParam{
			{"sort", "accuracy (default; players with at least min_shots shots), kills"},
			{"min_shots", "for sort=accuracy: only players with at least this many shots with it, 1-100000, default 100"},
		}, windowedPage...)},
		{"/api/v2/maps", "Per-map rounds, wins, losses, win rate, play time and last played.", append([]apiParam{
			{"sort", "rounds (default), play_time, last_played, win_rate"},
		}, pageParams...)},
		{"/api/v2/maps/{map_name}", "One map with its recent games and recent kill positions (for heatmaps); 404 if unknown.", []apiParam{
			{"limit_positions", "how many recent kill positions, 0-10000, default 2000"},
		}},
		{"/api/v2/map-runs", "Games (map runs), newest first: map, mode, start, game over, load time, build, rounds won and lost.", pageParams},
		{"/api/v2/map-runs/{id}", "One game: its rounds (result, how it ended, MVP) and every player's scoreboard; 404 if unknown.", nil},
		{"/api/v2/rounds/{id}", "One round with a timeline of kills, objectives, counterattacks, revives and survival levels; 404 if unknown.", nil},
		{"/api/v2/bots", "Bots ranked by kills on players.", append([]apiParam{
			{"sort", "kills (default)"},
		}, pageParams...)},
		{"/api/v2/bots/{bot_name}/weapons", "One bot's kills per weapon; URL-encode the name (spaces as %20). Plain array.", nil},
		{"/api/v2/medics", "Players ranked by medic play: medic time (seconds), revives, full heals, HP healed, average seconds to revive.", append([]apiParam{
			{"sort", "medic_time (default), revives, heals, hp_healed"},
		}, windowedPage...)},
		{"/api/v2/teamkills", "Players ranked by team kills, with team kills taken and forgiven.", append([]apiParam{
			{"sort", "team_kills (default), team_killed, forgiven"},
		}, windowedPage...)},
		{"/api/v2/teamkills/weapons", "Weapons ranked by team kills.", windowedPage},
		{"/api/v2/fire-support", "Players ranked by fire support calls, with refused and refunded calls.", append([]apiParam{
			{"sort", "calls (default), failed, last_called"},
		}, windowedPage...)},
	}
)

// apiServerInfo is one server's public API location.
type apiServerInfo struct {
	Server  string `json:"server"`
	Public  bool   `json:"public"`
	BaseURL string `json:"base_url,omitempty"`
	DocsURL string `json:"docs_url,omitempty"`
	Note    string `json:"note,omitempty"`
}

// apiReference is what the api_reference tool returns.
type apiReference struct {
	Servers   []apiServerInfo `json:"servers"`
	Endpoints []apiEndpoint   `json:"endpoints"`
	Notes     []string        `json:"notes"`
}

func buildAPIReference(cfg *Config) apiReference {
	ref := apiReference{
		Endpoints: apiEndpoints,
		Notes: []string{
			"All endpoints are GET, read-only, need no authentication, and return JSON. Full URL = base_url + path.",
			`List endpoints return {"items": [...], "total": N, "limit": L, "offset": O}; total counts all entries before paging.`,
			"Invalid query parameters return 422 with an error body. Times are UTC.",
			"Per-round history reaches back to November 2026 (December 2025 for team kills); lifetime totals include play from before that. Stats only recorded since stats v2 are null for older periods.",
			"Responses are cached for about a minute, so very recent changes may not show yet.",
			"SteamIDs are returned as strings (they exceed JavaScript's safe integer range).",
			"The docs_url page has interactive documentation and the full schema.",
		},
	}
	for _, name := range cfg.ServerOrder {
		s := cfg.Servers[name]
		info := apiServerInfo{Server: name, Public: s.PublicStatsAPIURL != ""}
		if info.Public {
			info.BaseURL = s.PublicStatsAPIURL
			info.DocsURL = s.PublicStatsAPIURL + "/docs"
		} else {
			info.Note = "This server's stats API is not publicly available."
		}
		ref.Servers = append(ref.Servers, info)
	}
	return ref
}

func (ts *Toolset) addAPIReferenceTool(cfg *Config) {
	ref := buildAPIReference(cfg)
	ts.add("api_reference",
		"Reference for the public stats REST API: each server's public base URL and docs page, every endpoint with its "+
			"query parameters, and the response format. Call this before giving anyone an API link, URL or curl example, "+
			"and use only the URLs, paths and parameters it returns.",
		map[string]any{}, nil,
		func(ctx context.Context, _ *toolContext, raw json.RawMessage) (any, error) {
			var in struct{}
			if err := decode(raw, &in); err != nil {
				return nil, err
			}
			return ref, nil
		})
}
