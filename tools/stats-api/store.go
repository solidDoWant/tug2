package main

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ErrNotFound is returned by the store when a requested record does not exist.
var ErrNotFound = errors.New("not found")

// Store wraps the database connection pool and exposes read-only queries over
// the stats v2 schema (issue #44). Every total comes from the schema's v_*
// views, which are the one definition of each stat; the store only sums them
// over a window, joins names in, pages and sorts.
//
// The schema is not named anywhere: the connection's search_path selects the
// server's stats_* schema (e.g. DATABASE_URL=...?options=-csearch_path=stats_main).
type Store struct {
	pool *pgxpool.Pool
}

// NewStore connects to PostgreSQL and verifies the connection is reachable.
//
// databaseURL is passed straight to pgx, which understands both connection
// strings and — when the string is empty — the standard libpq environment
// variables. That means host, credentials, TLS mode (including verify-full and
// mutual TLS), pool sizing (pool_max_conns) and the search_path (options) are
// all configured through pgx's native inputs rather than anything bespoke here.
// That includes statement_timeout, which can be set as a connection-string
// parameter (DATABASE_URL=...?statement_timeout=5000, in milliseconds) or via
// PGOPTIONS=-c statement_timeout=5000 — pgx forwards both as session startup
// parameters.
//
// The config is parsed explicitly (rather than via pgxpool.New) so enableTLSReload
// can rewire the TLS handshake to reload certificates from disk: pgx otherwise
// reads sslrootcert/sslcert/sslkey once and reuses them for the pool's lifetime,
// which means a cert-manager/CNPG-style rotation is invisible until a restart.
func NewStore(ctx context.Context, databaseURL string) (*Store, error) {
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, err
	}

	enableTLSReload(&config.ConnConfig.Config, databaseURL)
	config.AfterConnect = useUTC

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, err
	}

	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, err
	}

	return &Store{pool: pool}, nil
}

// useUTC is a pgxpool AfterConnect hook. Every stored time is a timestamptz,
// so the session zone only affects how times are rendered: UTC keeps any
// date arithmetic in SQL in UTC, and scanned times come back in UTC too.
func useUTC(ctx context.Context, conn *pgx.Conn) error {
	if _, err := conn.Exec(ctx, "SET TIME ZONE 'UTC'"); err != nil {
		return fmt.Errorf("set session time zone: %w", err)
	}
	conn.TypeMap().RegisterType(&pgtype.Type{
		Name:  "timestamptz",
		OID:   pgtype.TimestamptzOID,
		Codec: &pgtype.TimestamptzCodec{ScanLocation: time.UTC},
	})
	return nil
}

// Close releases the underlying connection pool.
func (s *Store) Close() {
	s.pool.Close()
}

// Ping checks database connectivity, used by the readiness probe.
func (s *Store) Ping(ctx context.Context) error {
	return s.pool.Ping(ctx)
}

// Stat returns a snapshot of the connection-pool statistics, read lazily by the
// metrics collector at scrape time. Returning the pgxpool snapshot rather than
// the pool itself keeps the pool encapsulated in the store.
func (s *Store) Stat() *pgxpool.Stat {
	return s.pool.Stat()
}

// all runs query and scans every row into a T by column name.
func all[T any](ctx context.Context, s *Store, query string, args ...any) ([]T, error) {
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	items, err := pgx.CollectRows(rows, pgx.RowToStructByName[T])
	if err != nil {
		return nil, err
	}
	if items == nil {
		items = []T{}
	}
	return items, nil
}

// one runs query and scans its single row into a T, or ErrNotFound.
func one[T any](ctx context.Context, s *Store, query string, args ...any) (*T, error) {
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	item, err := pgx.CollectOneRow(rows, pgx.RowToAddrOfStructByName[T])
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	return item, err
}

// page lists one page of the rows of from, a query whose columns are exactly
// T's, ordered by order (whitelisted SQL over those columns), along with the
// total number of rows.
func page[T any](ctx context.Context, s *Store, from string, args []any, order string, limit, offset int) ([]T, int, error) {
	var total int
	if err := s.pool.QueryRow(ctx, `SELECT count(*) FROM (`+from+`) src`, args...).Scan(&total); err != nil {
		return nil, 0, err
	}
	n := len(args)
	// #nosec G202 -- order is built from whitelisted sort maps, never from input.
	query := `SELECT * FROM (` + from + `) src ORDER BY ` + order +
		` LIMIT $` + strconv.Itoa(n+1) + ` OFFSET $` + strconv.Itoa(n+2)
	items, err := all[T](ctx, s, query, append(args, limit, offset)...)
	if err != nil {
		return nil, 0, err
	}
	return items, total, nil
}

// arg appends v to args and returns its placeholder.
func arg(args *[]any, v any) string {
	*args = append(*args, v)
	return "$" + strconv.Itoa(len(*args))
}

// likeEscaper escapes the LIKE metacharacters (with the default backslash
// escape) so user input is matched literally inside a %...% pattern.
var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// rate is 100 * hits / shots to the given decimals, or NULL with no shots.
func rate(hits, shots string, decimals int) string {
	return fmt.Sprintf("CASE WHEN %[2]s > 0 THEN round(100.0 * %[1]s / %[2]s, %[3]d)::float8 END", hits, shots, decimals)
}

// ratio orders by hits / shots unrounded, NULLs (no shots) last.
func ratio(hits, shots string) string {
	return hits + "::numeric / NULLIF(" + shots + ", 0) DESC NULLS LAST"
}
