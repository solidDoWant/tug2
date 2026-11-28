package main

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"time"
)

// Stats over a period. The lifetime views are the default; with ?period= or
// ?since=/?until= an endpoint sums the per-round views over their `at` column
// instead (v_player_round_stats, v_player_round_weapon_stats), or filters the
// event rows it reads on their own time. Per-round history reaches back to
// 2026-11 for the core stats and 2025-12 for team kills; earlier play exists
// only in the lifetime totals.

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
}

// info describes w for a response, or nil for all time.
func (w *Window) info() *WindowInfo {
	if w == nil {
		return nil
	}
	return &WindowInfo{Since: w.Since, Until: w.Until}
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

// bind appends the window's bounds to args and returns a function that
// restricts a timestamptz column to the window, for use as many times as a
// query needs.
func (w *Window) bind(args *[]any) func(column string) string {
	*args = append(*args, w.Since, w.Until)
	since, until := len(*args)-1, len(*args)
	return func(column string) string {
		return fmt.Sprintf("(%s >= $%d::timestamptz AND %s < $%d::timestamptz)", column, since, column, until)
	}
}
