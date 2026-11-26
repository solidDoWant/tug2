package main

import "context"

// minWeaponAccuracyShots is how many shots, across all players, a weapon needs
// before sort=accuracy ranks it.
const minWeaponAccuracyShots = "1000"

// weaponSorts maps the /weapons sort values to ORDER BY clauses.
var weaponSorts = map[string]string{
	"kills":    "kills DESC",
	"shots":    "shots DESC",
	"accuracy": "(shots >= " + minWeaponAccuracyShots + ") DESC, " + ratio("shots_hit_enemy", "shots"),
}

// ListWeapons returns a page of weapons with their totals across all players,
// for all time or in a window.
func (s *Store) ListWeapons(ctx context.Context, w *Window, sort string, limit, offset int) ([]WeaponTotals, int, error) {
	order, ok := weaponSorts[sort]
	if !ok {
		order = weaponSorts["kills"]
	}
	var args []any
	from := `
		SELECT t.weapon_name, wt.weapon_type, t.kills, t.unique_players, t.shots, t.shots_hit_enemy,
		       t.shots_hit_friendly, ` + rate("t.shots_hit_enemy", "t.shots", 1) + ` AS accuracy
		FROM (
			SELECT weapon_name, sum(kills)::bigint AS kills,
			       count(DISTINCT steam_id) FILTER (WHERE kills > 0) AS unique_players,
			       sum(shots)::bigint AS shots, sum(shots_hit_enemy)::bigint AS shots_hit_enemy,
			       sum(shots_hit_friendly)::bigint AS shots_hit_friendly
			FROM (` + weaponTotals(w, &args, "") + `) pw
			GROUP BY weapon_name
		) t
		LEFT JOIN weapons wt ON wt.weapon_name = t.weapon_name
		WHERE t.kills <> 0 OR t.shots <> 0`
	return page[WeaponTotals](ctx, s, from, args, order+", weapon_name", limit, offset)
}

// weaponPlayerSorts maps the /weapons/{weapon_name} sort values to ORDER BY
// clauses.
var weaponPlayerSorts = map[string]string{
	"accuracy": ratio("shots_hit_enemy", "shots") + ", shots DESC",
	"kills":    "kills DESC",
}

// GetWeaponPlayers ranks the players of one weapon, for all time or in a
// window: by accuracy among those with at least minShots shots with it, or by
// kills among those with a kill. A weapon neither v2 nor the old stats know is
// ErrNotFound; a known one nobody qualifies for is an empty page.
func (s *Store) GetWeaponPlayers(ctx context.Context, w *Window, weaponName, sort string, minShots, limit, offset int) ([]WeaponPlayer, int, error) {
	var known bool
	err := s.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM weapons WHERE weapon_name = $1)
		OR EXISTS (SELECT 1 FROM old_weapon_stats WHERE weapon_name = $1)`, weaponName).Scan(&known)
	if err != nil {
		return nil, 0, err
	}
	if !known {
		return nil, 0, ErrNotFound
	}

	order, ok := weaponPlayerSorts[sort]
	if !ok {
		sort, order = "accuracy", weaponPlayerSorts["accuracy"]
	}
	args := []any{weaponName}
	qualify := "t.kills > 0"
	if sort == "accuracy" {
		qualify = "t.shots >= " + arg(&args, minShots) + "::bigint"
	}
	from := `
		SELECT t.steam_id::text AS steam_id, p.name, t.kills, t.shots, t.shots_hit_enemy,
		       t.shots_hit_friendly, ` + rate("t.shots_hit_enemy", "t.shots", 1) + ` AS accuracy
		FROM (` + weaponTotals(w, &args, "weapon_name = $1") + `) t
		LEFT JOIN v_players p ON p.steam_id = t.steam_id
		WHERE ` + qualify
	return page[WeaponPlayer](ctx, s, from, args, order+", steam_id", limit, offset)
}
