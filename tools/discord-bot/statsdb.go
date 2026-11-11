package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// query_stats runs the model's own SELECTs against a read replica of the stats
// database. Nothing here trusts the SQL: the limits hold whatever it says.
//
//   - The database role can read only the stats tables (granted one by one;
//     never connection_log, which holds IP addresses) and has a low
//     connection limit and temp_file_limit.
//   - Every query runs in its own READ ONLY transaction that sets
//     statement_timeout, lock_timeout and search_path with SET LOCAL, and is
//     always rolled back, which also undoes any setting the query changed.
//   - The query is sent over the extended protocol, which refuses more than
//     one statement, and wrapped in a subquery with a LIMIT so the server
//     stops early. If the SQL escapes the wrapper, the client still stops
//     reading after maxQueryRows and drops the connection.
//   - Afterwards the connection is reset with DISCARD ALL (advisory locks,
//     temp state), or closed if anything went wrong.
const (
	queryStatementTimeout = 3 * time.Second
	queryLockTimeout      = time.Second
	// queryDeadline bounds the whole call, including waiting for a connection.
	queryDeadline   = 10 * time.Second
	maxQueryRows    = 200
	maxQueryChars   = 40000
	maxQueryCell    = 500
	maxQuerySQLLen  = 8000
	statsDBMaxConns = 2
)

// statsDB runs one read-only query in a server's schema.
type statsDB interface {
	Query(ctx context.Context, schema, sql string) (*QueryResult, error)
}

// QueryResult is what query_stats returns to the model.
type QueryResult struct {
	Columns []string `json:"columns"`
	Rows    [][]any  `json:"rows"`
	// Truncated is set when there were more rows (or more text) than returned.
	Truncated bool `json:"truncated,omitempty"`
}

// PostgresStatsDB is the statsDB backed by a small pgx pool.
type PostgresStatsDB struct {
	pool *pgxpool.Pool
}

// NewPostgresStatsDB sets up the pool. It does not connect: the first query
// does, so a database outage only affects query_stats, not startup.
func NewPostgresStatsDB(databaseURL string) (*PostgresStatsDB, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parsing STATS_DB_URL: %w", err)
	}
	enableTLSReload(&cfg.ConnConfig.Config, databaseURL)
	// Extended protocol with an unnamed statement: one statement per query, and
	// nothing cached on the server between queries.
	cfg.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeExec
	cfg.MaxConns = statsDBMaxConns
	cfg.MinConns = 0
	cfg.MaxConnIdleTime = 5 * time.Minute
	if cfg.ConnConfig.RuntimeParams["application_name"] == "" {
		cfg.ConnConfig.RuntimeParams["application_name"] = "discord-bot"
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		return nil, err
	}
	return &PostgresStatsDB{pool: pool}, nil
}

func (d *PostgresStatsDB) Close() { d.pool.Close() }

var errQueryTimeout = fmt.Errorf("the query ran longer than %s and was stopped; make it simpler or more selective", queryStatementTimeout)

func (d *PostgresStatsDB) Query(ctx context.Context, schema, sql string) (res *QueryResult, err error) {
	ctx, cancel := context.WithTimeout(ctx, queryDeadline)
	defer cancel()

	conn, err := d.pool.Acquire(ctx)
	if err != nil {
		return nil, fmt.Errorf("connecting to the stats database: %w", err)
	}
	// Keep the connection only if it was cleanly reset.
	clean := false
	defer func() {
		if !clean {
			conn.Conn().Close(context.Background())
		}
		conn.Release()
	}()

	tx, err := conn.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, fmt.Errorf("starting the query: %w", err)
	}
	_, err = tx.Exec(ctx,
		"SELECT set_config('statement_timeout', $1, true), set_config('lock_timeout', $2, true), "+
			"set_config('idle_in_transaction_session_timeout', $3, true), set_config('search_path', $4, true)",
		fmt.Sprint(queryStatementTimeout.Milliseconds()), fmt.Sprint(queryLockTimeout.Milliseconds()),
		fmt.Sprint(queryDeadline.Milliseconds()), pgx.Identifier{schema}.Sanitize())
	if err == nil {
		res, err = readRows(ctx, tx, wrapQuery(sql))
	}
	if errors.Is(err, errRowLimit) {
		// The SQL got around the LIMIT. readRows dropped the connection rather
		// than read the rest.
		return res, nil
	}
	if rbErr := tx.Rollback(ctx); rbErr == nil && (err == nil || isQueryError(err)) {
		if _, dErr := conn.Exec(ctx, "DISCARD ALL"); dErr == nil {
			clean = true
		}
	}
	if err != nil {
		return nil, describeQueryError(err)
	}
	return res, nil
}

var errRowLimit = errors.New("row limit reached")

// readRows collects up to maxQueryRows rows and maxQueryChars of values.
// errRowLimit means it stopped early with rows left unread.
func readRows(ctx context.Context, tx pgx.Tx, sql string) (*QueryResult, error) {
	// Cancelling ctx makes pgx abandon the connection; closing rows normally
	// would read every remaining row first.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	rows, err := tx.Query(ctx, sql)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	res := &QueryResult{Rows: [][]any{}}
	for _, f := range rows.FieldDescriptions() {
		res.Columns = append(res.Columns, f.Name)
	}
	size := 0
	for rows.Next() {
		if len(res.Rows) >= maxQueryRows || size > maxQueryChars {
			res.Truncated = true
			cancel()
			return res, errRowLimit
		}
		vals, err := rows.Values()
		if err != nil {
			return nil, err
		}
		row := make([]any, len(vals))
		for i, v := range vals {
			row[i] = jsonValue(v)
			size += len(fmt.Sprint(row[i])) + 3
		}
		res.Rows = append(res.Rows, row)
	}
	return res, rows.Err()
}

// wrapQuery puts the model's SELECT in a subquery with a LIMIT one above what
// is returned, so the server stops early and the client can tell there was
// more. The newline keeps a trailing -- comment from swallowing the wrapper.
func wrapQuery(sql string) string {
	return fmt.Sprintf("SELECT * FROM (\n%s\n) AS query_stats LIMIT %d", trimQuery(sql), maxQueryRows+1)
}

func trimQuery(sql string) string {
	return strings.TrimRight(strings.TrimSpace(sql), "; \t\r\n")
}

// checkQuery rejects SQL the tool won't run before it reaches the database.
// The database enforces the real limits; this only gives clearer errors and
// blocks set_config, which could raise work_mem for the rest of the statement.
func checkQuery(sql string) error {
	sql = trimQuery(sql)
	lower := strings.ToLower(sql)
	switch {
	case sql == "":
		return errors.New("give a SELECT query")
	case len(sql) > maxQuerySQLLen:
		return fmt.Errorf("the query is too long (at most %d characters)", maxQuerySQLLen)
	case !strings.HasPrefix(lower, "select") && !strings.HasPrefix(lower, "with") && !strings.HasPrefix(lower, "("):
		return errors.New("only a single SELECT (optionally starting WITH) can be run")
	case strings.Contains(lower, "set_config"):
		return errors.New("set_config is not allowed")
	}
	return nil
}

// isQueryError reports whether err came from the server rejecting or stopping
// the query (the connection itself is fine) rather than from the connection.
func isQueryError(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr)
}

// describeQueryError turns a database error into something the model can act
// on: the server's message, hint and position, or a plain timeout notice.
func describeQueryError(err error) error {
	var pgErr *pgconn.PgError
	switch {
	case errors.As(err, &pgErr) && pgErr.Code == "57014": // query_canceled
		return errQueryTimeout
	case errors.As(err, &pgErr) && pgErr.Code == "42501": // insufficient_privilege
		return fmt.Errorf("%s (only the documented stats tables can be read)", pgErr.Message)
	case errors.As(err, &pgErr):
		msg := pgErr.Message
		if pgErr.Hint != "" {
			msg += ". Hint: " + pgErr.Hint
		}
		return errors.New(msg)
	case errors.Is(err, context.DeadlineExceeded):
		return errQueryTimeout
	}
	slog.Warn("stats database query failed", "err", err)
	return errors.New("the stats database is unreachable right now; use the other stats tools")
}

// jsonValue converts a scanned value to something that encodes plainly and
// briefly as JSON.
func jsonValue(v any) any {
	switch v := v.(type) {
	case nil, bool, int16, int32, int64, float32:
		return v
	case float64:
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return fmt.Sprint(v)
		}
		return v
	case string:
		return truncateCell(v)
	case time.Time:
		return v.UTC().Format("2006-01-02 15:04:05")
	case pgtype.Numeric:
		if f, err := v.Float64Value(); err == nil && f.Valid {
			return f.Float64
		}
		return nil
	case pgtype.Interval:
		if !v.Valid {
			return nil
		}
		// As seconds, taking a month as 30 days like Postgres's EXTRACT(EPOCH).
		return float64(v.Microseconds)/1e6 + float64(v.Days)*86400 + float64(v.Months)*30*86400
	case []byte:
		return fmt.Sprintf("<%d bytes>", len(v))
	case []any:
		out := make([]any, len(v))
		for i, e := range v {
			out[i] = jsonValue(e)
		}
		return out
	case map[string]any:
		return v
	}
	return truncateCell(fmt.Sprint(v))
}

func truncateCell(s string) string {
	if utf8.RuneCountInString(s) <= maxQueryCell {
		return s
	}
	return string([]rune(s)[:maxQueryCell]) + "…"
}
