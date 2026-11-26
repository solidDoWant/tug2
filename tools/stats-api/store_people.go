package main

import "context"

// ListBots returns a page of bots by their kills of human players, summed
// over weapons from v_bot_weapon_kills.
func (s *Store) ListBots(ctx context.Context, limit, offset int) ([]BotStats, int, error) {
	const from = `SELECT bot_name, sum(kills)::bigint AS total_kills FROM v_bot_weapon_kills GROUP BY bot_name`
	return page[BotStats](ctx, s, from, nil, "total_kills DESC, bot_name", limit, offset)
}

// GetBotWeapons returns one bot's kills per weapon; empty for an unknown bot.
func (s *Store) GetBotWeapons(ctx context.Context, botName string) ([]WeaponKills, error) {
	return all[WeaponKills](ctx, s, `
		SELECT weapon_name, kills::bigint AS kills FROM v_bot_weapon_kills
		WHERE bot_name = $1 AND kills > 0 ORDER BY kills DESC, weapon_name`, botName)
}

// medicSorts maps the /medics sort values to ORDER BY clauses.
var medicSorts = map[string]string{
	"medic_time": "medic_seconds DESC NULLS LAST",
	"revives":    "revives DESC NULLS LAST",
	"heals":      "heals DESC NULLS LAST",
	"hp_healed":  "hp_healed DESC NULLS LAST",
}

// ListMedics returns a page of players with medic time, revives or heals,
// from the per-player totals (lifetime or in a window), plus their average
// revive time from the revives table (filtered on revived_at in a window).
func (s *Store) ListMedics(ctx context.Context, w *Window, sort string, limit, offset int) ([]MedicStats, int, error) {
	order, ok := medicSorts[sort]
	if !ok {
		order = medicSorts["medic_time"]
	}
	var args []any
	totals := playerTotals(w, &args, "")
	reviveFilter := ""
	if w != nil {
		reviveFilter = "WHERE " + w.bind(&args)("revived_at")
	}
	from := `
		SELECT t.steam_id::text AS steam_id, p.name, t.medic_seconds, t.revives, t.times_revived,
		       t.heals, t.hp_healed, rv.avg_revive_seconds
		FROM (` + totals + `) t
		LEFT JOIN v_players p ON p.steam_id = t.steam_id
		LEFT JOIN (
			SELECT reviver_steam_id AS steam_id,
			       round(avg(extract(epoch FROM revived_at - started_at)), 1)::float8 AS avg_revive_seconds
			FROM revives ` + reviveFilter + ` GROUP BY reviver_steam_id
		) rv ON rv.steam_id = t.steam_id
		WHERE COALESCE(t.medic_seconds, 0) > 0 OR COALESCE(t.revives, 0) > 0 OR COALESCE(t.heals, 0) > 0`
	return page[MedicStats](ctx, s, from, args, order+", steam_id", limit, offset)
}

// teamKillSorts maps the /teamkills sort values to ORDER BY clauses.
var teamKillSorts = map[string]string{
	"team_kills":  "team_kills DESC NULLS LAST",
	"team_killed": "team_killed DESC NULLS LAST",
	"forgiven":    "forgiven DESC",
}

// ListTeamKills returns a page of players with team kills given or taken,
// from the per-player totals, with how many of their logged team kills
// (v_team_kills) were forgiven.
func (s *Store) ListTeamKills(ctx context.Context, w *Window, sort string, limit, offset int) ([]TeamKillStats, int, error) {
	order, ok := teamKillSorts[sort]
	if !ok {
		order = teamKillSorts["team_kills"]
	}
	var args []any
	totals := playerTotals(w, &args, "")
	tkFilter := ""
	if w != nil {
		tkFilter = "WHERE " + w.bind(&args)("killed_at")
	}
	from := `
		SELECT t.steam_id::text AS steam_id, p.name, t.kills, t.team_kills, t.team_killed,
		       COALESCE(f.forgiven, 0) AS forgiven
		FROM (` + totals + `) t
		LEFT JOIN v_players p ON p.steam_id = t.steam_id
		LEFT JOIN (
			SELECT attacker_steam_id AS steam_id, count(*) FILTER (WHERE forgiven) AS forgiven
			FROM v_team_kills ` + tkFilter + ` GROUP BY attacker_steam_id
		) f ON f.steam_id = t.steam_id
		WHERE COALESCE(t.team_kills, 0) > 0 OR COALESCE(t.team_killed, 0) > 0`
	return page[TeamKillStats](ctx, s, from, args, order+", steam_id", limit, offset)
}

// ListTeamKillWeapons returns a page of weapons by team kills (v_team_kills).
func (s *Store) ListTeamKillWeapons(ctx context.Context, w *Window, limit, offset int) ([]TeamKillWeaponStats, int, error) {
	var args []any
	where := ""
	if w != nil {
		where = "WHERE " + w.bind(&args)("killed_at")
	}
	from := `SELECT weapon_name, count(*) AS team_kills, count(*) FILTER (WHERE forgiven) AS forgiven
		FROM v_team_kills ` + where + ` GROUP BY weapon_name`
	return page[TeamKillWeaponStats](ctx, s, from, args, "team_kills DESC, weapon_name NULLS LAST", limit, offset)
}

// fireSupportSorts maps the /fire-support sort values to ORDER BY clauses.
var fireSupportSorts = map[string]string{
	"calls":       "calls DESC NULLS LAST",
	"failed":      "failed DESC",
	"last_called": "last_called_at DESC NULLS LAST",
}

// ListFireSupport returns a page of players by fire-support calls: the
// successful calls from the per-player totals, failed and refunded calls from
// v2's fire_support_calls, and the last successful call in either the v2 or
// the old call log (filtered on called_at in a window).
func (s *Store) ListFireSupport(ctx context.Context, w *Window, sort string, limit, offset int) ([]FireSupportStats, int, error) {
	order, ok := fireSupportSorts[sort]
	if !ok {
		order = fireSupportSorts["calls"]
	}
	var args []any
	totals := playerTotals(w, &args, "")
	v2Filter, oldFilter := "", ""
	if w != nil {
		in := w.bind(&args)
		v2Filter = "WHERE " + in("called_at")
		oldFilter = "AND " + in("called_at")
	}
	from := `
		SELECT t.steam_id::text AS steam_id, p.name, t.fire_support_calls AS calls,
		       COALESCE(f.failed, 0) AS failed, COALESCE(f.refunded, 0) AS refunded,
		       GREATEST(f.last_called_at, o.last_called_at) AS last_called_at
		FROM (` + totals + `) t
		LEFT JOIN v_players p ON p.steam_id = t.steam_id
		LEFT JOIN (
			SELECT steam_id, count(*) FILTER (WHERE failure_reason IS NOT NULL) AS failed,
			       count(*) FILTER (WHERE refunded_at IS NOT NULL) AS refunded,
			       max(called_at) FILTER (WHERE failure_reason IS NULL) AS last_called_at
			FROM fire_support_calls ` + v2Filter + ` GROUP BY steam_id
		) f ON f.steam_id = t.steam_id
		LEFT JOIN (
			SELECT steam_id::bigint AS steam_id, max(called_at) AS last_called_at
			FROM old_fire_support_calls WHERE steam_id ~ '^[0-9]+$' ` + oldFilter + ` GROUP BY 1
		) o ON o.steam_id = t.steam_id
		WHERE COALESCE(t.fire_support_calls, 0) > 0 OR COALESCE(f.failed, 0) > 0`
	return page[FireSupportStats](ctx, s, from, args, order+", steam_id", limit, offset)
}
