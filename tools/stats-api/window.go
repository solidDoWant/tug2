package main

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"time"
)

// Stats over a period (issue #10). The lifetime totals stay the default; with
// ?period= or ?since=/?until= an endpoint sums the per-round history the
// plugins record next to them instead:
//
//	players, player weapons, weapons, accuracy  player_rounds, player_round_weapons (gg2_mstats2)
//	medics                                      medic_rounds (gg2_medic_tracker)
//	teamkills, teamkill weapons                 player_tk_logs (gg2_teamkill)
//	fire support                                fire_support_calls (FireSupport)
//
// History only exists from when each plugin started recording it, so a
// windowed response says where its data starts (WindowInfo.HistorySince); a
// window reaching back before that is incomplete, and lifetime totals are the
// only record of earlier play.

// PeriodInput is the shared time-window query for endpoints that support one.
type PeriodInput struct {
	Period string `query:"period" pattern:"^[0-9]{1,4}d$" example:"30d" doc:"Only count the last N days (e.g. 7d, 30d, 365d) instead of all time. Not with since/until."`
	Since  string `query:"since" maxLength:"40" example:"2026-11-01" doc:"Only count from this UTC date (YYYY-MM-DD) or time (RFC 3339), inclusive."`
	Until  string `query:"until" maxLength:"40" example:"2026-12-01" doc:"Only count before this UTC date or time, exclusive. Defaults to now."`
}

// Window is a time range [Since, Until) in UTC.
type Window struct {
	Since, Until time.Time
}

// WindowInfo describes a windowed response.
type WindowInfo struct {
	Since time.Time `json:"since"`
	Until time.Time `json:"until"`
	// HistorySince is the earliest time the history behind this endpoint has
	// data for, or null if it has none yet. A window starting before it only
	// covers the part from then on.
	HistorySince *time.Time `json:"history_since"`
}

var errWindow = errors.New("invalid time window")

// maxPeriodDays bounds ?period=, so a typo can't produce a nonsense range.
const maxPeriodDays = 3650

// resolve turns the query into a window, or nil for all time.
func (p PeriodInput) resolve(now time.Time) (*Window, error) {
	now = now.UTC()
	if p.Period == "" && p.Since == "" && p.Until == "" {
		return nil, nil
	}
	if p.Period != "" {
		if p.Since != "" || p.Until != "" {
			return nil, fmt.Errorf("%w: use period or since/until, not both", errWindow)
		}
		days, err := strconv.Atoi(p.Period[:len(p.Period)-1])
		if err != nil || days < 1 || days > maxPeriodDays {
			return nil, fmt.Errorf("%w: period must be 1d to %dd", errWindow, maxPeriodDays)
		}
		return &Window{Since: now.AddDate(0, 0, -days), Until: now}, nil
	}

	w := &Window{Since: time.Unix(0, 0).UTC(), Until: now}
	var err error
	if p.Since != "" {
		if w.Since, err = parseWindowTime(p.Since); err != nil {
			return nil, err
		}
	}
	if p.Until != "" {
		if w.Until, err = parseWindowTime(p.Until); err != nil {
			return nil, err
		}
	}
	if !w.Since.Before(w.Until) {
		return nil, fmt.Errorf("%w: since must be before until", errWindow)
	}
	return w, nil
}

var datePattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)

func parseWindowTime(s string) (time.Time, error) {
	if datePattern.MatchString(s) {
		if t, err := time.Parse("2006-01-02", s); err == nil {
			return t, nil
		}
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t.UTC(), nil
	}
	return time.Time{}, fmt.Errorf("%w: %q is not a date (YYYY-MM-DD) or RFC 3339 time", errWindow, s)
}

// sqlTime formats a bound as an absolute time (RFC 3339 in UTC), sent as text
// and cast to timestamptz in SQL.
func sqlTime(t time.Time) string {
	return t.UTC().Format(time.RFC3339Nano)
}

// bind appends the window's bounds to args and returns a function that
// restricts a timestamp column to the window, for use as many times as a
// query needs. The columns hold wall-clock times in the session's time zone
// (see timezone.go), so each bound is converted to that zone once, in SQL,
// leaving the column bare for its index.
func (w *Window) bind(args *[]any) func(column string) string {
	*args = append(*args, sqlTime(w.Since), sqlTime(w.Until))
	since, until := len(*args)-1, len(*args)
	return func(column string) string {
		return fmt.Sprintf("(%s >= $%d::timestamptz::timestamp AND %s < $%d::timestamptz::timestamp)", column, since, column, until)
	}
}

// historySources maps an endpoint family to the earliest-row query of the
// history it reads.
var historySources = map[string]string{
	"players":     `SELECT MIN(recorded_at) FROM player_rounds`,
	"medics":      `SELECT MIN(recorded_at) FROM medic_rounds`,
	"teamkills":   `SELECT MIN(created_at) FROM player_tk_logs`,
	"firesupport": `SELECT MIN(called_at) FROM fire_support_calls`,
}

// WindowInfo describes w for a response, with where source's history starts.
func (s *Store) WindowInfo(ctx context.Context, w *Window, source string) (*WindowInfo, error) {
	if w == nil {
		return nil, nil
	}
	info := &WindowInfo{Since: w.Since, Until: w.Until}
	var first *time.Time
	if err := s.pool.QueryRow(ctx, historySources[source]).Scan(&first); err != nil {
		return nil, err
	}
	if first != nil {
		t := first.UTC()
		info.HistorySince = &t
	}
	return info, nil
}
