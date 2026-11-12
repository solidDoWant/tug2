package main

import (
	"errors"
	"testing"
	"time"
)

func TestPeriodResolve(t *testing.T) {
	now := time.Date(2026, 11, 12, 15, 30, 0, 0, time.UTC)
	day := func(d int) time.Time { return time.Date(2026, 11, d, 0, 0, 0, 0, time.UTC) }

	for _, tc := range []struct {
		name string
		in   PeriodInput
		want *Window
	}{
		{"all time", PeriodInput{}, nil},
		{"period", PeriodInput{Period: "7d"}, &Window{Since: now.AddDate(0, 0, -7), Until: now}},
		{"since only", PeriodInput{Since: "2026-11-01"}, &Window{Since: day(1), Until: now}},
		{"until only", PeriodInput{Until: "2026-11-05"}, &Window{Since: time.Unix(0, 0).UTC(), Until: day(5)}},
		{"both", PeriodInput{Since: "2026-11-01", Until: "2026-11-05"}, &Window{Since: day(1), Until: day(5)}},
		{"rfc3339", PeriodInput{Since: "2026-11-01T12:00:00+02:00"}, &Window{Since: time.Date(2026, 11, 1, 10, 0, 0, 0, time.UTC), Until: now}},
	} {
		got, err := tc.in.resolve(now)
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
			continue
		}
		if (got == nil) != (tc.want == nil) || got != nil && (!got.Since.Equal(tc.want.Since) || !got.Until.Equal(tc.want.Until)) {
			t.Errorf("%s: got %+v, want %+v", tc.name, got, tc.want)
		}
	}

	for _, bad := range []PeriodInput{
		{Period: "7d", Since: "2026-11-01"},
		{Period: "0d"},
		{Period: "9999d"},
		{Since: "yesterday"},
		{Since: "2026-11-05", Until: "2026-11-01"},
		{Since: "2026-11-05", Until: "2026-11-05"},
	} {
		if _, err := bad.resolve(now); !errors.Is(err, errWindow) {
			t.Errorf("%+v: err = %v, want a window error", bad, err)
		}
	}
}

func TestWindowBind(t *testing.T) {
	w := &Window{Since: time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), Until: time.Date(2026, 11, 2, 3, 4, 5, 0, time.UTC)}
	args := []any{"x"}
	in := w.bind(&args)
	if got := in("r.recorded_at"); got != "(r.recorded_at >= $2::timestamptz::timestamp AND r.recorded_at < $3::timestamptz::timestamp)" {
		t.Errorf("cond = %s", got)
	}
	if len(args) != 3 || args[1] != "2026-11-01T00:00:00Z" || args[2] != "2026-11-02T03:04:05Z" {
		t.Errorf("args = %v", args)
	}
}
