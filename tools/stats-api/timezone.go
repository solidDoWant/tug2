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
// those as UTC and be off by the zone offset.
//
// So each connection reads its session TimeZone (the same default the plugins
// get, since neither side sets one) and scans timestamp columns as wall-clock
// times in that zone, returned in UTC. Window bounds are sent as timestamptz and
// cast to timestamp in SQL, which uses the same zone (see Window.bind).

// useSessionTimeZone is a pgxpool AfterConnect hook.
func useSessionTimeZone(ctx context.Context, conn *pgx.Conn) error {
	var name string
	if err := conn.QueryRow(ctx, "SHOW TimeZone").Scan(&name); err != nil {
		return fmt.Errorf("read session time zone: %w", err)
	}
	loc, err := time.LoadLocation(name)
	if err != nil {
		return fmt.Errorf("session time zone %q: %w", name, err)
	}
	registerStoredTimestamps(conn.TypeMap(), loc)
	return nil
}

func registerStoredTimestamps(m *pgtype.Map, loc *time.Location) {
	m.RegisterType(&pgtype.Type{
		Name:  "timestamp",
		OID:   pgtype.TimestampOID,
		Codec: &storedTimestampCodec{TimestampCodec: pgtype.TimestampCodec{ScanLocation: loc}},
	})
}

// storedTimestampCodec reads a timestamp as a wall-clock time in ScanLocation
// and hands it on in UTC, so the API's times are all UTC.
type storedTimestampCodec struct {
	pgtype.TimestampCodec
}

func (c *storedTimestampCodec) PlanScan(m *pgtype.Map, oid uint32, format int16, target any) pgtype.ScanPlan {
	if _, ok := target.(pgtype.TimestampScanner); !ok {
		return nil // pgx retries with a TimestampScanner wrapper (e.g. for *time.Time)
	}
	inner := c.TimestampCodec.PlanScan(m, oid, format, &pgtype.Timestamp{})
	if inner == nil {
		return nil
	}
	return utcTimestampScanPlan{inner}
}

type utcTimestampScanPlan struct {
	inner pgtype.ScanPlan
}

func (p utcTimestampScanPlan) Scan(src []byte, target any) error {
	var ts pgtype.Timestamp
	if err := p.inner.Scan(src, &ts); err != nil {
		return err
	}
	if ts.Valid {
		ts.Time = ts.Time.UTC()
	}
	return target.(pgtype.TimestampScanner).ScanTimestamp(ts)
}
