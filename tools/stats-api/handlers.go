package main

import (
	"context"
	"errors"
	"net/http"

	"github.com/danielgtaylor/huma/v2"
	"github.com/danielgtaylor/huma/v2/adapters/humago"
)

// Server holds the dependencies shared by the API operations.
type Server struct {
	store *Store
}

// NewServer wires the operations up to a data store.
func NewServer(store *Store) *Server {
	return &Server{store: store}
}

// Routes builds the API router. A huma API is layered over the standard
// library mux so the OpenAPI 3.1 spec and docs are generated from the Go types
// registered below — served at /docs (UI), /openapi.yaml, and /openapi.json.
//
// The concrete *http.ServeMux is returned (rather than http.Handler) so the
// metrics middleware can resolve each request's matched route pattern for its
// labels.
func (s *Server) Routes() *http.ServeMux {
	mux := http.NewServeMux()

	config := huma.DefaultConfig("stats-api", "1")
	config.Info.Description = "Read-only REST API over the gg2_mstats2 player statistics database."
	api := humago.New(mux, config)

	s.register(api)

	// Send the bare root and common default-document paths to the API docs so a
	// browser hitting the domain lands on something useful instead of a 404.
	// Registered on the mux directly (not via huma) so they stay out of the
	// OpenAPI spec, and as exact patterns ({$} matches only "/") so unknown paths
	// still 404 rather than being swallowed by a catch-all redirect.
	docsRedirect := http.RedirectHandler("/docs", http.StatusMovedPermanently)
	mux.Handle("GET /{$}", docsRedirect)
	mux.Handle("GET /index.html", docsRedirect)
	mux.Handle("GET /index.htm", docsRedirect)

	return mux
}

// --- inputs / outputs ------------------------------------------------------
//
// huma derives the request schema (query/path params, validation) and the
// response schema from these struct types, so the spec stays in lockstep with
// the handlers.

type StatusOutput struct {
	Body struct {
		Status string `json:"status" example:"ok"`
	}
}

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
	Sort string `query:"sort" default:"score" enum:"kills,deaths,score,wins,killstreak,caps,kd,updated_at" doc:"Column to order by, descending."`
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
	Body []WeaponKills
}

type WeaponsOutput struct {
	Body ListResponse[WeaponTotals]
}

type MapsOutput struct {
	Body ListResponse[MapStats]
}

type MatchesOutput struct {
	Body ListResponse[MatchResult]
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

// --- registration ----------------------------------------------------------

func (s *Server) register(api huma.API) {
	// The probes are served on the API listener (so they share fate with the
	// path they vouch for) but kept out of the OpenAPI spec — the published
	// contract is the data API only; these are infra endpoints for the
	// orchestrator, not API consumers.
	huma.Register(api, huma.Operation{
		OperationID: "live",
		Method:      http.MethodGet,
		Path:        "/livez",
		Summary:     "Liveness probe",
		Description: "Returns 200 as long as the server can serve requests. Does not touch the database, so it is safe to use for restart decisions.",
		Tags:        []string{"operational"},
		Hidden:      true,
	}, s.live)

	huma.Register(api, huma.Operation{
		OperationID: "ready",
		Method:      http.MethodGet,
		Path:        "/readyz",
		Summary:     "Readiness probe",
		Description: "Pings the database; use for load-balancer rotation.",
		Tags:        []string{"operational"},
		Hidden:      true,
	}, s.ready)

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
		Summary:     "Per-map win/loss summary",
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
}

// --- handlers --------------------------------------------------------------

func (s *Server) live(ctx context.Context, _ *struct{}) (*StatusOutput, error) {
	out := &StatusOutput{}
	out.Body.Status = "ok"
	return out, nil
}

func (s *Server) ready(ctx context.Context, _ *struct{}) (*StatusOutput, error) {
	if err := s.store.Ping(ctx); err != nil {
		return nil, huma.Error503ServiceUnavailable("database unavailable")
	}
	out := &StatusOutput{}
	out.Body.Status = "ok"
	return out, nil
}

func (s *Server) listPlayers(ctx context.Context, in *ListPlayersInput) (*PlayersOutput, error) {
	players, total, err := s.store.ListPlayers(ctx, in.Sort, in.Limit, in.Offset)
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

func (s *Server) listMaps(ctx context.Context, in *PageInput) (*MapsOutput, error) {
	maps, total, err := s.store.ListMaps(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, huma.Error500InternalServerError("failed to list maps")
	}
	return &MapsOutput{Body: page(maps, total, *in)}, nil
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

// page wraps a slice and total into the standard pagination envelope.
func page[T any](items []T, total int, p PageInput) ListResponse[T] {
	return ListResponse[T]{
		Items:  items,
		Total:  total,
		Limit:  p.Limit,
		Offset: p.Offset,
	}
}
