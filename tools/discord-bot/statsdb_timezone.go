package main

import (
	"context"
	"fmt"
	"time"
	_ "time/tzdata" // the session zone is loaded by name; don't depend on the image having zoneinfo

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
)

// The plugins' tables use timestamp without time zone filled by
// CURRENT_TIMESTAMP, which stores the wall-clock time in the session's
// TimeZone: the server default, which need not be UTC. pgx would otherwise read
// those as UTC and be off by the zone offset, so query_stats would report
// local times labelled UTC (and wrong Unix seconds).
//
// So each connection reads its session TimeZone (the same default the plugins
// get, since neither side sets one) and scans timestamp values as wall-clock
// times in that zone; jsonValue then reports them in UTC. The same approach as
// tools/stats-api/timezone.go. Comparisons in SQL (col > now() - interval ...)
// need nothing: Postgres casts timestamp to timestamptz in the session zone.

// useSessionTimeZone is a pgxpool AfterConnect hook. DISCARD ALL after each
// query resets the session TimeZone to this same default, and leaves the
// connection's type map alone.
func useSessionTimeZone(ctx context.Context, conn *pgx.Conn) error {
	var name string
	if err := conn.QueryRow(ctx, "SHOW TimeZone").Scan(&name); err != nil {
		return fmt.Errorf("reading the session time zone: %w", err)
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return fmt.Errorf("session time zone %q: %w", name, err)
	}
	registerStoredTimestamps(conn.TypeMap(), loc)
	return nil
}

// registerStoredTimestamps makes timestamp values scan as wall-clock times in
// loc. rows.Values, which query_stats uses, decodes through the codec's own
// ScanLocation.
func registerStoredTimestamps(m *pgtype.Map, loc *time.Location) {
	m.RegisterType(&pgtype.Type{
		Name:  "timestamp",
		OID:   pgtype.TimestampOID,
		Codec: &pgtype.TimestampCodec{ScanLocation: loc},
	})
}
