package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"time"

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

	config := huma.DefaultConfig("stats-api", "2")
	config.Info.Description = "Read-only REST API over the stats v2 database (issue #44): players, weapons, maps, rounds, bots, medics, team kills and fire support."
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

type SteamIDInput struct {
	SteamID string `path:"steam_id" pattern:"^[0-9]{1,20}$" example:"76561198000000001" doc:"64-bit Steam ID."`
}

// steamID parses the path's Steam ID; one that doesn't fit a BIGINT can't
// belong to anyone, so it is a 404.
func (in SteamIDInput) steamID() (int64, error) {
	id, err := strconv.ParseInt(in.SteamID, 10, 64)
	if err != nil {
		return 0, huma.Error404NotFound("player not found")
	}
	return id, nil
}

type ListPlayersInput struct {
	Sort string `query:"sort" default:"score" enum:"score,kills,deaths,kd,assists,wins,play_time,accuracy,revives,heals,caps,headshot_kills,killstreak,last_seen" doc:"Column to order by, descending. accuracy ranks players with at least 500 shots by enemy hit rate; everyone else follows. killstreak is lifetime only (no order with a window)."`
	Name string `query:"name" maxLength:"128" doc:"Only players whose current in-game name contains this text (case-insensitive, literal)."`
	PageInput
	PeriodInput
}

type PlayersOutput struct {
	Body ListResponse[PlayerStats]
}

// PlayerInput is a player's SteamID with an optional time window.
type PlayerInput struct {
	SteamIDInput
	PeriodInput
}

type PlayerOutput struct {
	Body PlayerDetail
}

type PlayerWeaponsOutput struct {
	Body []PlayerWeapon
}

type PlayerClassesOutput struct {
	Body []PlayerClass
}

type PlayerRoundsInput struct {
	SteamIDInput
	PageInput
	PeriodInput
}

type PlayerRoundsOutput struct {
	Body ListResponse[PlayerRound]
}

type ListWeaponsInput struct {
	Sort string `query:"sort" default:"kills" enum:"kills,shots,accuracy" doc:"Order by kills, shots fired, or enemy hit rate (weapons with at least 1000 shots first, then the rest); descending."`
	PageInput
	PeriodInput
}

type WeaponsOutput struct {
	Body ListResponse[WeaponTotals]
}

type WeaponPlayersInput struct {
	WeaponName string `path:"weapon_name" example:"m4a1" maxLength:"64" doc:"Weapon name as in /api/v2/weapons."`
	Sort       string `query:"sort" default:"accuracy" enum:"accuracy,kills" doc:"accuracy: players with at least min_shots shots by enemy hit rate. kills: players with a kill, by kills."`
	MinShots   int    `query:"min_shots" default:"100" minimum:"1" maximum:"100000" doc:"For sort=accuracy: only players with at least this many shots with the weapon."`
	PageInput
	PeriodInput
}

type WeaponPlayersOutput struct {
	Body ListResponse[WeaponPlayer]
}

type ListMapsInput struct {
	Sort string `query:"sort" default:"rounds" enum:"rounds,play_time,last_played,win_rate" doc:"Order by rounds, play time, most recent play, or win rate (maps without results last); descending."`
	PageInput
}

type MapsOutput struct {
	Body ListResponse[MapStats]
}

type MapInput struct {
	MapName        string `path:"map_name" example:"ministry" maxLength:"128" doc:"Map name."`
	LimitPositions int    `query:"limit_positions" default:"2000" minimum:"0" maximum:"10000" doc:"How many recent kill positions to return."`
}

type MapOutput struct {
	Body MapDetail
}

type MapRunsOutput struct {
	Body ListResponse[MapRun]
}

type IDInput struct {
	ID int64 `path:"id" minimum:"1" example:"1"`
}

type MapRunOutput struct {
	Body MapRunDetail
}

type RoundOutput struct {
	Body RoundDetail
}

type ListBotsInput struct {
	Sort string `query:"sort" default:"kills" enum:"kills" doc:"Order by kills of human players, descending."`
	PageInput
}

type BotsOutput struct {
	Body ListResponse[BotStats]
}

type BotNameInput struct {
	BotName string `path:"bot_name" example:"Rifleman Jones" maxLength:"129" doc:"Bot name (URL-encode spaces and special characters)."`
}

type BotWeaponsOutput struct {
	Body []WeaponKills
}

type ListMedicsInput struct {
	Sort string `query:"sort" default:"medic_time" enum:"medic_time,revives,heals,hp_healed" doc:"Order by seconds as medic, revives, full heals or HP healed; descending."`
	PageInput
	PeriodInput
}

type MedicsOutput struct {
	Body ListResponse[MedicStats]
}

type ListTeamKillsInput struct {
	Sort string `query:"sort" default:"team_kills" enum:"team_kills,team_killed,forgiven" doc:"Order by team kills given, taken, or forgiven; descending."`
	PageInput
	PeriodInput
}

type TeamKillsOutput struct {
	Body ListResponse[TeamKillStats]
}

// WindowedPageInput is a paginated list that also takes a time window.
type WindowedPageInput struct {
	PageInput
	PeriodInput
}

type TeamKillWeaponsOutput struct {
	Body ListResponse[TeamKillWeaponStats]
}

type ListFireSupportInput struct {
	Sort string `query:"sort" default:"calls" enum:"calls,failed,last_called" doc:"Order by successful calls, failed calls, or the last call; descending."`
	PageInput
	PeriodInput
}

type FireSupportOutput struct {
	Body ListResponse[FireSupportStats]
}

// --- registration ----------------------------------------------------------

// apiPrefix is the versioned data API's path prefix (below the base path).
const apiPrefix = "/api/v2"

// op describes a GET operation under apiPrefix.
func op(id, path, summary, tag string) huma.Operation {
	return huma.Operation{
		OperationID: id,
		Method:      http.MethodGet,
		Path:        apiPrefix + path,
		Summary:     summary,
		Tags:        []string{tag},
	}
}

func (s *Server) register(api huma.API) {
	huma.Register(api, op("list-players", "/players", "List players", "players"), s.listPlayers)
	huma.Register(api, op("get-player", "/players/{steam_id}", "One player's stats and name history", "players"), s.getPlayer)
	huma.Register(api, op("get-player-weapons", "/players/{steam_id}/weapons", "A player's stats per weapon", "players"), s.getPlayerWeapons)
	huma.Register(api, op("get-player-classes", "/players/{steam_id}/classes", "A player's time, kills and deaths per class", "players"), s.getPlayerClasses)
	huma.Register(api, op("get-player-rounds", "/players/{steam_id}/rounds", "A player's round history, newest first", "players"), s.getPlayerRounds)
	huma.Register(api, op("list-weapons", "/weapons", "Weapons across all players", "weapons"), s.listWeapons)
	huma.Register(api, op("get-weapon-players", "/weapons/{weapon_name}", "Top players with one weapon", "weapons"), s.getWeaponPlayers)
	huma.Register(api, op("list-maps", "/maps", "Per-map rounds, results and play time", "maps"), s.listMaps)
	huma.Register(api, op("get-map", "/maps/{map_name}", "One map with recent runs and kill positions", "maps"), s.getMap)
	huma.Register(api, op("list-map-runs", "/map-runs", "Map runs, newest first", "maps"), s.listMapRuns)
	huma.Register(api, op("get-map-run", "/map-runs/{id}", "One map run with its rounds and scoreboard", "maps"), s.getMapRun)
	huma.Register(api, op("get-round", "/rounds/{id}", "One round with its timeline", "maps"), s.getRound)
	huma.Register(api, op("list-bots", "/bots", "Bots ranked by kills of players", "bots"), s.listBots)
	huma.Register(api, op("get-bot-weapons", "/bots/{bot_name}/weapons", "A bot's kills per weapon", "bots"), s.getBotWeapons)
	huma.Register(api, op("list-medics", "/medics", "Players ranked by medic play", "medics"), s.listMedics)
	huma.Register(api, op("list-teamkills", "/teamkills", "Players ranked by team kills", "teamkills"), s.listTeamKills)
	huma.Register(api, op("list-teamkill-weapons", "/teamkills/weapons", "Weapons ranked by team kills", "teamkills"), s.listTeamKillWeapons)
	huma.Register(api, op("list-fire-support", "/fire-support", "Players ranked by fire-support calls", "fire-support"), s.listFireSupport)
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

// window resolves an endpoint's time-window query; a bad one is a 422.
func window(p PeriodInput) (*Window, error) {
	w, err := p.resolve(time.Now())
	if err != nil {
		return nil, huma.Error422UnprocessableEntity(err.Error())
	}
	return w, nil
}

// fail maps a store error to a response: ErrNotFound to a 404 saying notFound,
// anything else to a logged 500 saying what failed.
func fail(ctx context.Context, err error, what, notFound string) error {
	if errors.Is(err, ErrNotFound) && notFound != "" {
		return huma.Error404NotFound(notFound)
	}
	slog.ErrorContext(ctx, "query failed", "what", what, "err", err)
	return huma.Error500InternalServerError("failed to " + what)
}

// pageOf wraps a slice and total into the standard pagination envelope.
func pageOf[T any](items []T, total int, p PageInput, w *Window) ListResponse[T] {
	return ListResponse[T]{Items: items, Total: total, Limit: p.Limit, Offset: p.Offset, Window: w.info()}
}

func (s *Server) listPlayers(ctx context.Context, in *ListPlayersInput) (*PlayersOutput, error) {
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	players, total, err := s.store.ListPlayers(ctx, w, in.Sort, in.Name, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list players", "")
	}
	return &PlayersOutput{Body: pageOf(players, total, in.PageInput, w)}, nil
}

func (s *Server) getPlayer(ctx context.Context, in *PlayerInput) (*PlayerOutput, error) {
	id, err := in.steamID()
	if err != nil {
		return nil, err
	}
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	player, err := s.store.GetPlayer(ctx, w, id)
	if err != nil {
		return nil, fail(ctx, err, "fetch player", "player not found")
	}
	return &PlayerOutput{Body: *player}, nil
}

func (s *Server) getPlayerWeapons(ctx context.Context, in *PlayerInput) (*PlayerWeaponsOutput, error) {
	id, err := in.steamID()
	if err != nil {
		return nil, err
	}
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	weapons, err := s.store.GetPlayerWeapons(ctx, w, id)
	if err != nil {
		return nil, fail(ctx, err, "fetch player weapons", "")
	}
	return &PlayerWeaponsOutput{Body: weapons}, nil
}

func (s *Server) getPlayerClasses(ctx context.Context, in *PlayerInput) (*PlayerClassesOutput, error) {
	id, err := in.steamID()
	if err != nil {
		return nil, err
	}
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	classes, err := s.store.GetPlayerClasses(ctx, w, id)
	if err != nil {
		return nil, fail(ctx, err, "fetch player classes", "")
	}
	return &PlayerClassesOutput{Body: classes}, nil
}

func (s *Server) getPlayerRounds(ctx context.Context, in *PlayerRoundsInput) (*PlayerRoundsOutput, error) {
	id, err := in.steamID()
	if err != nil {
		return nil, err
	}
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	rounds, total, err := s.store.GetPlayerRounds(ctx, w, id, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "fetch player rounds", "")
	}
	return &PlayerRoundsOutput{Body: pageOf(rounds, total, in.PageInput, w)}, nil
}

func (s *Server) listWeapons(ctx context.Context, in *ListWeaponsInput) (*WeaponsOutput, error) {
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	weapons, total, err := s.store.ListWeapons(ctx, w, in.Sort, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list weapons", "")
	}
	return &WeaponsOutput{Body: pageOf(weapons, total, in.PageInput, w)}, nil
}

func (s *Server) getWeaponPlayers(ctx context.Context, in *WeaponPlayersInput) (*WeaponPlayersOutput, error) {
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	players, total, err := s.store.GetWeaponPlayers(ctx, w, in.WeaponName, in.Sort, in.MinShots, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "fetch weapon players", "weapon not found")
	}
	return &WeaponPlayersOutput{Body: pageOf(players, total, in.PageInput, w)}, nil
}

func (s *Server) listMaps(ctx context.Context, in *ListMapsInput) (*MapsOutput, error) {
	maps, total, err := s.store.ListMaps(ctx, in.Sort, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list maps", "")
	}
	return &MapsOutput{Body: pageOf(maps, total, in.PageInput, nil)}, nil
}

func (s *Server) getMap(ctx context.Context, in *MapInput) (*MapOutput, error) {
	m, err := s.store.GetMap(ctx, in.MapName, in.LimitPositions)
	if err != nil {
		return nil, fail(ctx, err, "fetch map", "map not found")
	}
	return &MapOutput{Body: *m}, nil
}

func (s *Server) listMapRuns(ctx context.Context, in *PageInput) (*MapRunsOutput, error) {
	runs, total, err := s.store.ListMapRuns(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list map runs", "")
	}
	return &MapRunsOutput{Body: pageOf(runs, total, *in, nil)}, nil
}

func (s *Server) getMapRun(ctx context.Context, in *IDInput) (*MapRunOutput, error) {
	run, err := s.store.GetMapRun(ctx, in.ID)
	if err != nil {
		return nil, fail(ctx, err, "fetch map run", "map run not found")
	}
	return &MapRunOutput{Body: *run}, nil
}

func (s *Server) getRound(ctx context.Context, in *IDInput) (*RoundOutput, error) {
	round, err := s.store.GetRound(ctx, in.ID)
	if err != nil {
		return nil, fail(ctx, err, "fetch round", "round not found")
	}
	return &RoundOutput{Body: *round}, nil
}

func (s *Server) listBots(ctx context.Context, in *ListBotsInput) (*BotsOutput, error) {
	bots, total, err := s.store.ListBots(ctx, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list bots", "")
	}
	return &BotsOutput{Body: pageOf(bots, total, in.PageInput, nil)}, nil
}

func (s *Server) getBotWeapons(ctx context.Context, in *BotNameInput) (*BotWeaponsOutput, error) {
	weapons, err := s.store.GetBotWeapons(ctx, in.BotName)
	if err != nil {
		return nil, fail(ctx, err, "fetch bot weapons", "")
	}
	return &BotWeaponsOutput{Body: weapons}, nil
}

func (s *Server) listMedics(ctx context.Context, in *ListMedicsInput) (*MedicsOutput, error) {
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	medics, total, err := s.store.ListMedics(ctx, w, in.Sort, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list medics", "")
	}
	return &MedicsOutput{Body: pageOf(medics, total, in.PageInput, w)}, nil
}

func (s *Server) listTeamKills(ctx context.Context, in *ListTeamKillsInput) (*TeamKillsOutput, error) {
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	teamKills, total, err := s.store.ListTeamKills(ctx, w, in.Sort, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list team kills", "")
	}
	return &TeamKillsOutput{Body: pageOf(teamKills, total, in.PageInput, w)}, nil
}

func (s *Server) listTeamKillWeapons(ctx context.Context, in *WindowedPageInput) (*TeamKillWeaponsOutput, error) {
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	weapons, total, err := s.store.ListTeamKillWeapons(ctx, w, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list team kill weapons", "")
	}
	return &TeamKillWeaponsOutput{Body: pageOf(weapons, total, in.PageInput, w)}, nil
}

func (s *Server) listFireSupport(ctx context.Context, in *ListFireSupportInput) (*FireSupportOutput, error) {
	w, err := window(in.PeriodInput)
	if err != nil {
		return nil, err
	}
	players, total, err := s.store.ListFireSupport(ctx, w, in.Sort, in.Limit, in.Offset)
	if err != nil {
		return nil, fail(ctx, err, "list fire support", "")
	}
	return &FireSupportOutput{Body: pageOf(players, total, in.PageInput, w)}, nil
}
