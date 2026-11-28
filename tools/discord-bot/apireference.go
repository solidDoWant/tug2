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
	// response's window says the range and when the history behind it starts.
	periodParams = []apiParam{
		{"period", "only the last N days, e.g. 7d, 30d, 365d (1-3650); not with since/until"},
		{"since", "only from this UTC date (YYYY-MM-DD) or RFC 3339 time, inclusive"},
		{"until", "only before this UTC date or time, exclusive; default now"},
	}
	windowedPage = append(append([]apiParam{}, pageParams...), periodParams...)
	apiEndpoints = []apiEndpoint{
		{"/api/v1/players", "Players with lifetime stats (or stats in a time window), descending.", append([]apiParam{
			{"sort", "score (default), kills, deaths, wins, killstreak, caps, kd, play_time, accuracy (players with 500+ shots, by enemy hit rate), updated_at"},
			{"name", "only players whose latest in-game name contains this, case-insensitive"},
		}, windowedPage...)},
		{"/api/v1/players/{steam_id}", "One player's stats by SteamID64 (lifetime, or in a time window); 404 if unknown.", periodParams},
		{"/api/v1/players/{steam_id}/weapons", "One player's kills, rounds fired, enemy/friendly hits and enemy hit rate per weapon (a plain array, not paginated).", periodParams},
		{"/api/v1/weapons", "Weapons across all players: total kills, players with a kill, rounds fired, enemy/friendly hits and enemy hit rate.", append([]apiParam{
			{"sort", "kills (default), shots, accuracy (weapons with 1000+ shots, by enemy hit rate)"},
		}, windowedPage...)},
		{"/api/v1/weapons/{weapon_name}/accuracy", "Players ranked by enemy hit rate with one weapon (e.g. m4a1); 404 for an unknown weapon.", append([]apiParam{
			{"min_shots", "only players with at least this many shots with it, 1-100000, default 100"},
		}, windowedPage...)},
		{"/api/v1/maps", "Per-map wins, losses, win rate, playtime and last played.", append([]apiParam{
			{"sort", "rounds (default), play_time, last_played"},
		}, pageParams...)},
		{"/api/v1/matches", "Round results, newest first.", pageParams},
		{"/api/v1/bots", "Bots ranked by kills on players.", pageParams},
		{"/api/v1/bots/{bot_name}/weapons", "One bot's kills per weapon; URL-encode the name (spaces as %20). Plain array.", nil},
		{"/api/v1/medics", "Players ranked by time spent as medic (seconds), with full heals and revives.", append([]apiParam{
			{"sort", "time (default), heals, revives"},
		}, windowedPage...)},
		{"/api/v1/teamkills", "Players ranked by team kills given, with taken and forgiven counts.", windowedPage},
		{"/api/v1/teamkills/weapons", "Weapons ranked by team kills.", windowedPage},
		{"/api/v1/fire-support", "Players ranked by artillery calls.", windowedPage},
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
