package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humago"
)

// Server holds the dependencies shared by the API operations.
type Server struct {
	store *Store
	// basePath prefixes every API, docs, and spec route (see Config.BasePath).
	basePath string
}

// NewServer wires the operations up to a data store, serving them under
// basePath ("" for the root; otherwise normalised as by normaliseBasePath).
func NewServer(store *Store, basePath string) *Server {
	return &Server{store: store, basePath: basePath}
}

// Routes builds the API router. A huma API is layered over the standard
// library mux so the OpenAPI 3.1 spec and docs are generated from the Go types
// registered below — served at /docs (UI), /openapi.yaml, and /openapi.json.
//
// With a base path, every API, docs, and spec route moves under it, and huma's
// prefix support also points the docs UI, the spec's server URL, and the
// $schema links at the prefixed paths. The request is expected to arrive with
// the prefix intact: a reverse proxy in front must forward it, not strip it.
// The health probes stay at the root (see registerProbes).
//
// The concrete *http.ServeMux is returned (rather than http.Handler) so the
// metrics middleware can resolve each request's matched route pattern for its
// labels.
func (s *Server) Routes() *http.ServeMux {
	mux := http.NewServeMux()

	config := huma.DefaultConfig("stats-api", "1")
	config.Info.Description = "Read-only REST API over the gg2_mstats2 player statistics database."
	var api huma.API
	if s.basePath == "" {
		api = humago.New(mux, config)
	} else {
		api = humago.NewWithPrefix(mux, s.basePath, config)
	}

	s.register(api)
	s.registerProbes(mux)

	// Send the bare root and common default-document paths to the API docs so a
	// browser hitting the domain lands on something useful instead of a 404.
	// Registered on the mux directly (not via huma) so they stay out of the
	// OpenAPI spec, and as exact patterns ({$} matches only "/") so unknown paths
	// still 404 rather than being swallowed by a catch-all redirect.
	// 302, not 301: a permanent redirect is cached by browsers indefinitely, which would strand
	// anyone who has hit "/" once if it ever serves something other than a redirect to the docs.
	//
	// Under a base path, the prefix itself (with and without a trailing slash)
	// redirects too, so "/test" and "/test/" both land on "/test/docs".
	docsRedirect := http.RedirectHandler(s.basePath+"/docs", http.StatusFound)
	mux.Handle("GET "+s.basePath+"/{$}", docsRedirect)
	mux.Handle("GET "+s.basePath+"/index.html", docsRedirect)
	mux.Handle("GET "+s.basePath+"/index.htm", docsRedirect)
	if s.basePath != "" {
		mux.Handle("GET "+s.basePath, docsRedirect)
	}

	return mux
}

// --- inputs / outputs ------------------------------------------------------
//
// huma derives the request schema (query/path params, validation) and the
// response schema from these struct types, so the spec stays in lockstep with
// the handlers.

// PageInput is the shared pagination query for list endpoints.
//
// Offset is capped (rather than left unbounded) for two reasons: a deep OFFSET
// forces Postgres to scan and discard that many rows on every request, and an
// attacker walking arbitrary offsets would also mint a unique cache key per
// request, sailing straight past the shared cache to the origin. 100000 is far
// beyond any legitimate paging depth here while bounding the worst case; raise
// it if a leaderboard genuinely needs to be paged deeper.
type PageInput struct {
	Limit  int `query:"limit" default:"50" minimum:"0" maximum:"200"`
	Offset int `query:"offset" default:"0" minimum:"0" maximum:"100000"`
}

type ListPlayersInput struct {
	Sort string `query:"sort" default:"score" enum:"kills,deaths,score,wins,killstreak,caps,kd,play_time,accuracy,updated_at" doc:"Column to order by, descending. accuracy ranks players with at least 500 recorded shots by enemy hit rate; everyone else follows."`
	Name string `query:"name" maxLength:"128" doc:"Only players whose most recent in-game name contains this text (case-insensitive)."`
	PageInput
}

type PlayersOutput struct {
	Body ListResponse[PlayerStats]
}

type SteamIDInput struct {
	SteamID string `path:"steam_id" example:"76561198000000001" doc:"64-bit Steam ID."`
}

type PlayerOutput struct {
	Body PlayerStats
}

type PlayerWeaponsOutput struct {
	Body []PlayerWeapon
}

type WeaponsOutput struct {
	Body ListResponse[WeaponTotals]
}

type ListMapsInput struct {
	Sort string `query:"sort" default:"rounds" enum:"rounds,play_time,last_played" doc:"Order by total logged rounds, total playtime, or most recent activity; descending."`
	PageInput
}

type MapsOutput struct {
	Body ListResponse[MapStats]
}

type MatchesOutput struct {
	Body ListResponse[MatchResult]
}

type BotNameInput struct {
	BotName string `path:"bot_name" example:"Bot Adams" doc:"Bot name as recorded by gg2_mstats2 (URL-encode spaces and special characters)."`
}

type BotWeaponsOutput struct {
	Body []WeaponKills
}

type BotsOutput struct {
	Body ListResponse[BotStats]
}

type MedicsOutput struct {
	Body ListResponse[MedicStats]
}

type TeamKillsOutput struct {
	Body ListResponse[TeamKillStats]
}

type TeamKillWeaponsOutput struct {
	Body ListResponse[TeamKillWeaponStats]
}

type FireSupportOutput struct {
	Body ListResponse[FireSupportStats]
}

// --- registration ----------------------------------------------------------

func (s *Server) register(api huma.API) {
	huma.Register(api, huma.Operation{
		OperationID: "list-players",
		Method:      http.MethodGet,
		Path:        "/api/v1/players",
		Summary:     "List players",
		Tags:        []string{"players"},
	}, s.listPlayers)

	huma.Register(api, huma.Operation{
		OperationID: "get-player",
		Method:      http.MethodGet,
		Path:        "/api/v1/players/{steam_id}",
		Summary:     "Get a single player",
		Tags:        []string{"players"},
	}, s.getPlayer)

	huma.Register(api, huma.Operation{
		OperationID: "get-player-weapons",
		Method:      http.MethodGet,
		Path:        "/api/v1/players/{steam_id}/weapons",
		Summary:     "Per-weapon kill breakdown for a player",
		Tags:        []string{"players"},
	}, s.getPlayerWeapons)

	huma.Register(api, huma.Operation{
		OperationID: "list-weapons",
		Method:      http.MethodGet,
		Path:        "/api/v1/weapons",
		Summary:     "Most-used weapons across all players",
		Tags:        []string{"weapons"},
	}, s.listWeapons)

	huma.Register(api, huma.Operation{
		OperationID: "list-maps",
		Method:      http.MethodGet,
		Path:        "/api/v1/maps",
		Summary:     "Per-map win/loss and playtime summary",
		Tags:        []string{"maps"},
	}, s.listMaps)

	huma.Register(api, huma.Operation{
		OperationID: "list-matches",
		Method:      http.MethodGet,
		Path:        "/api/v1/matches",
		Summary:     "Recent match results",
		Tags:        []string{"maps"},
	}, s.listMatches)

	huma.Register(api, huma.Operation{
		OperationID: "list-bots",
		Method:      http.MethodGet,
		Path:        "/api/v1/bots",
		Summary:     "Bots ranked by total kills",
		Tags:        []string{"bots"},
	}, s.listBots)

	huma.Register(api, huma.Operation{
		OperationID: "get-bot-weapons",
		Method:      http.MethodGet,
		Path:        "/api/v1/bots/{bot_name}/weapons",
		Summary:     "Per-weapon kill breakdown for a bot",
		Tags:        []string{"bots"},
	}, s.getBotWeapons)

	huma.Register(api, huma.Operation{
		OperationID: "list-medics",
		Method:      http.MethodGet,
		Path:        "/api/v1/medics",
		Summary:     "Players ranked by time spent as medic",
		Tags:        []string{"medics"},
	}, s.listMedics)

	huma.Register(api, huma.Operation{
		OperationID: "list-teamkills",
		Method:      http.MethodGet,
		Path:        "/api/v1/teamkills",
		Summary:     "Players ranked by team kills",
		Tags:        []string{"teamkills"},
	}, s.listTeamKills)

	huma.Register(api, huma.Operation{
		OperationID: "list-teamkill-weapons",
		Method:      http.MethodGet,
		Path:        "/api/v1/teamkills/weapons",
		Summary:     "Weapons ranked by logged team kills",
		Tags:        []string{"teamkills"},
	}, s.listTeamKillWeapons)

	huma.Register(api, huma.Operation{
		OperationID: "list-fire-support",
		Method:      http.MethodGet,
		Path:        "/api/v1/fire-support",
		Summary:     "Players ranked by fire-support (artillery) calls",
		Tags:        []string{"fire-support"},
	}, s.listFireSupport)
}

// registerProbes serves the liveness and readiness probes on the API listener
// (so they share fate with the path they vouch for) but always at the root,
// whatever the base path: the orchestrator calls the pod directly, not through
// the proxy that the base path exists for. They are plain handlers rather than
// huma operations so they stay out of the OpenAPI spec and outside the prefix —
// the published contract is the data API only. Keep the paths in sync with
// probePatterns (metrics.go) and isProbe (logging.go).
func (s *Server) registerProbes(mux *http.ServeMux) {
	mux.HandleFunc("GET /livez", func(w http.ResponseWriter, r *http.Request) {
		writeStatus(w, http.StatusOK, "ok")
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, r *http.Request) {
		if err := s.store.Ping(r.Context()); err != nil {
			writeStatus(w, http.StatusServiceUnavailable, "database unavailable")
			return
		}
		writeStatus(w, http.StatusOK, "ok")
	})
}

// writeStatus writes a probe response body of the form {"status": "..."}.
func writeStatus(w http.ResponseWriter, code int, status string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"status": status})
}

// --- handlers --------------------------------------------------------------

func (s *Server) listPlayers(ctx context.Context, in *ListPlayersInput) (*PlayersOutput, error) {
	players, total, err := s.store.ListPlayers(ctx, in.Sort, in.Name, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list players")
	}
	return &PlayersOutput{Body: page(players, total, in.PageInput)}, nil
}

func (s *Server) getPlayer(ctx context.Context, in *SteamIDInput) (*PlayerOutput, error) {
	player, err := s.store.GetPlayer(ctx, in.SteamID)
	if errors.Is(err, ErrNotFound) {
		return nil, huma.Error404NotFound("player not found")
	}
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to fetch player")
	}
	return &PlayerOutput{Body: *player}, nil
}

func (s *Server) getPlayerWeapons(ctx context.Context, in *SteamIDInput) (*PlayerWeaponsOutput, error) {
	weapons, err := s.store.GetPlayerWeapons(ctx, in.SteamID)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to fetch player weapons")
	}
	return &PlayerWeaponsOutput{Body: weapons}, nil
}

func (s *Server) listWeapons(ctx context.Context, in *PageInput) (*WeaponsOutput, error) {
	weapons, total, err := s.store.ListWeapons(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list weapons")
	}
	return &WeaponsOutput{Body: page(weapons, total, *in)}, nil
}

func (s *Server) listMaps(ctx context.Context, in *ListMapsInput) (*MapsOutput, error) {
	maps, total, err := s.store.ListMaps(ctx, in.Sort, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list maps")
	}
	return &MapsOutput{Body: page(maps, total, in.PageInput)}, nil
}

func (s *Server) listMatches(ctx context.Context, in *PageInput) (*MatchesOutput, error) {
	matches, total, err := s.store.ListMatches(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list matches")
	}
	return &MatchesOutput{Body: page(matches, total, *in)}, nil
}

func (s *Server) listBots(ctx context.Context, in *PageInput) (*BotsOutput, error) {
	bots, total, err := s.store.ListBots(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list bots")
	}
	return &BotsOutput{Body: page(bots, total, *in)}, nil
}

func (s *Server) getBotWeapons(ctx context.Context, in *BotNameInput) (*BotWeaponsOutput, error) {
	weapons, err := s.store.GetBotWeapons(ctx, in.BotName)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to fetch bot weapons")
	}
	return &BotWeaponsOutput{Body: weapons}, nil
}

func (s *Server) listMedics(ctx context.Context, in *PageInput) (*MedicsOutput, error) {
	medics, total, err := s.store.ListMedics(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list medics")
	}
	return &MedicsOutput{Body: page(medics, total, *in)}, nil
}

func (s *Server) listTeamKills(ctx context.Context, in *PageInput) (*TeamKillsOutput, error) {
	teamKills, total, err := s.store.ListTeamKills(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list team kills")
	}
	return &TeamKillsOutput{Body: page(teamKills, total, *in)}, nil
}

func (s *Server) listTeamKillWeapons(ctx context.Context, in *PageInput) (*TeamKillWeaponsOutput, error) {
	weapons, total, err := s.store.ListTeamKillWeapons(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list team kill weapons")
	}
	return &TeamKillWeaponsOutput{Body: page(weapons, total, *in)}, nil
}

func (s *Server) listFireSupport(ctx context.Context, in *PageInput) (*FireSupportOutput, error) {
	players, total, err := s.store.ListFireSupport(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list fire support")
	}
	return &FireSupportOutput{Body: page(players, total, *in)}, nil
}

// page wraps a slice and total into the standard pagination envelope.
func page[T any](items []T, total int, p PageInput) ListResponse[T] {
	return ListResponse[T]{
		Items:  items,
		Total:  total,
		Limit:  p.Limit,
		Offset: p.Offset,
	}
}
