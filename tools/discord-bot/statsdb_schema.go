package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The query_stats description documents the tables the model can read. It is
// built from the database itself: the tables the discord-bot role may SELECT
// (granted by each game server's discord_bot_grants.sql) and the COMMENTs the
// plugin SQL scripts put on them and their columns. So it follows the grants
// and the schema without a copy here to keep in step.
//
// The rendering is a pure function of the catalog (sorted tables, columns in
// order, no timestamps), so a refresh that finds nothing new produces the same
// bytes and the prompt cache stays warm; only a real change replaces the
// description. A refresh that fails keeps the last good description.

const (
	schemaRefreshInterval = 5 * time.Minute
	schemaLoadTimeout     = 15 * time.Second
	// undocumented marks a table or column without a COMMENT.
	undocumented = "(undocumented)"
)

// schemaDocLoading stands in until the first load succeeds.
const schemaDocLoading = "The table descriptions haven't loaded yet. List the tables and columns you can read with: " +
	"SELECT table_name, column_name, data_type FROM information_schema.columns WHERE table_schema = current_schema() ORDER BY table_name, ordinal_position"

const (
	schemaDocHeader = "Tables (PostgreSQL; each server has its own copy, selected by the server parameter, so never schema-qualify names). " +
		"Each table and column is described below; timestamps are UTC (timestamp without time zone)."
	schemaDocFooter = "Counts are lifetime totals per server. For K/D, divide by NULLIF(deaths, 0) and say how you treated players with no deaths; " +
		"for averages, consider leaving out players with very few kills or deaths and say so."
)

type schemaColumn struct {
	Name, Type, Comment string
}

type schemaTable struct {
	Name, Comment string
	Columns       []schemaColumn
}

// schemaQuery lists the tables in a schema that the current role may SELECT,
// with their columns and comments, in a fixed order.
const schemaQuery = `
SELECT c.relname, coalesce(obj_description(c.oid, 'pg_class'), ''),
       a.attname, format_type(a.atttypid, a.atttypmod), coalesce(col_description(c.oid, a.attnum), '')
FROM pg_catalog.pg_class c
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
WHERE n.nspname = $1 AND c.relkind IN ('r', 'p', 'v', 'm') AND has_table_privilege(c.oid, 'SELECT')
ORDER BY c.relname, a.attnum`

// Schema returns the tables the role can read in one schema.
func (d *PostgresStatsDB) Schema(ctx context.Context, schema string) ([]schemaTable, error) {
	ctx, cancel := context.WithTimeout(ctx, schemaLoadTimeout)
	defer cancel()
	var tables []schemaTable
	err := pgx.BeginTxFunc(ctx, d.pool, pgx.TxOptions{AccessMode: pgx.ReadOnly}, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT set_config('statement_timeout', '5000', true)"); err != nil {
			return err
		}
		rows, err := tx.Query(ctx, schemaQuery, schema)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var table, tableComment string
			var col schemaColumn
			if err := rows.Scan(&table, &tableComment, &col.Name, &col.Type, &col.Comment); err != nil {
				return err
			}
			if n := len(tables); n == 0 || tables[n-1].Name != table {
				tables = append(tables, schemaTable{Name: table, Comment: tableComment})
			}
			tables[len(tables)-1].Columns = append(tables[len(tables)-1].Columns, col)
		}
		return rows.Err()
	})
	return tables, err
}

// shortTypes trims the longest Postgres type names, which repeat on many
// columns.
var shortTypes = strings.NewReplacer(
	"timestamp without time zone", "timestamp",
	"timestamp with time zone", "timestamptz",
	"character varying", "varchar",
)

// renderSchemaDoc documents the tables of every server, in server order. A
// table or column missing from some servers says which ones have it; its
// description and column order come from the first server that has it.
func renderSchemaDoc(servers []string, schemas map[string][]schemaTable) string {
	byServer := map[string]map[string]schemaTable{}
	var names []string
	for _, srv := range servers {
		byServer[srv] = map[string]schemaTable{}
		for _, t := range schemas[srv] {
			byServer[srv][t.Name] = t
			if !slices.Contains(names, t.Name) {
				names = append(names, t.Name)
			}
		}
	}
	slices.Sort(names)

	only := func(have []string) string {
		if len(have) == len(servers) {
			return ""
		}
		return " (only on " + strings.Join(have, ", ") + ")"
	}

	var b strings.Builder
	b.WriteString(schemaDocHeader)
	if len(names) == 0 {
		b.WriteString("\n- No tables are readable yet.")
	}
	for _, name := range names {
		var have []string
		var columns []schemaColumn
		comment := ""
		for _, srv := range servers {
			t, ok := byServer[srv][name]
			if !ok {
				continue
			}
			if len(have) == 0 {
				comment = t.Comment
			}
			have = append(have, srv)
			for _, c := range t.Columns {
				if !slices.ContainsFunc(columns, func(e schemaColumn) bool { return e.Name == c.Name }) {
					columns = append(columns, c)
				}
			}
		}
		fmt.Fprintf(&b, "\n- %s%s: %s", name, only(have), describe(comment))
		for _, c := range columns {
			var colHave []string
			for _, srv := range have {
				if slices.ContainsFunc(byServer[srv][name].Columns, func(e schemaColumn) bool { return e.Name == c.Name }) {
					colHave = append(colHave, srv)
				}
			}
			colOnly := ""
			if len(colHave) < len(have) {
				colOnly = " (only on " + strings.Join(colHave, ", ") + ")"
			}
			fmt.Fprintf(&b, "\n  - %s %s%s: %s", c.Name, shortTypes.Replace(c.Type), colOnly, describe(c.Comment))
		}
	}
	b.WriteString("\n")
	b.WriteString(schemaDocFooter)
	return b.String()
}

func describe(comment string) string {
	comment = strings.Join(strings.Fields(comment), " ")
	if comment == "" {
		return undocumented
	}
	return comment
}

// refreshQueryStatsDoc reloads every server's tables and replaces the
// query_stats description if the result differs. On any error it changes
// nothing, so an outage never flips the description back and forth.
func (ts *Toolset) refreshQueryStatsDoc(ctx context.Context) (bool, error) {
	if ts.queryDB == nil {
		return false, nil
	}
	schemas := map[string][]schemaTable{}
	for _, srv := range ts.queryServers {
		tables, err := ts.queryDB.Schema(ctx, ts.querySchemas[srv])
		if err != nil {
			return false, fmt.Errorf("loading the %s server's tables: %w", srv, err)
		}
		schemas[srv] = tables
	}
	doc := renderSchemaDoc(ts.queryServers, schemas)
	changed := ts.setDescription("query_stats", queryStatsDescription(doc))
	if changed {
		var tables, missing int
		for _, srv := range ts.queryServers {
			tables += len(schemas[srv])
		}
		missing = strings.Count(doc, undocumented)
		slog.Info("query_stats table descriptions updated", "tables", tables,
			"undocumented", missing, "sha256", fmt.Sprintf("%x", sha256.Sum256([]byte(doc)))[:12])
		if missing > 0 {
			slog.Warn("tables or columns the bot can read have no COMMENT; add one in the plugin's SQL script", "count", missing)
		}
	}
	return changed, nil
}

// WatchQueryStatsDoc loads the query_stats descriptions now, then refreshes
// them every interval until ctx ends. The first load is waited for (briefly)
// so the first questions usually see the real tables.
func (ts *Toolset) WatchQueryStatsDoc(ctx context.Context, interval time.Duration) {
	if ts.queryDB == nil {
		return
	}
	first, cancel := context.WithTimeout(ctx, schemaLoadTimeout)
	_, err := ts.refreshQueryStatsDoc(first)
	cancel()
	if err != nil {
		slog.Warn("couldn't load the query_stats table descriptions; retrying in the background", "err", err)
	}
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if _, err := ts.refreshQueryStatsDoc(ctx); err != nil {
					slog.Warn("refreshing the query_stats table descriptions failed; keeping the current ones", "err", err)
				}
			}
		}
	}()
}
