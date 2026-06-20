package main

import (
	"os"
	"time"
)

// Config holds the configuration this tool actually owns: the HTTP listener and
// request timeouts. Database connection settings are intentionally absent — pgx
// reads the standard libpq inputs (PGHOST, PGPORT, PGDATABASE, PGUSER,
// PGPASSWORD, PGSSLMODE, PGSSLROOTCERT, PGSSLCERT, PGSSLKEY, PGCONNECT_TIMEOUT,
// the pool_max_conns conn-string param, ...) natively, so DATABASE_URL — or, when
// it is empty, the libpq environment variables — fully describes the connection.
type Config struct {
	// ListenAddr is the host:port the API HTTP server binds to.
	ListenAddr string

	// MetricsAddr is the host:port the Prometheus metrics server binds to. It is
	// deliberately a separate listener from ListenAddr so the operator-facing
	// /metrics endpoint is not exposed alongside the public API.
	MetricsAddr string

	// DatabaseURL is passed straight to pgx. When empty, pgx falls back to the
	// standard libpq environment variables.
	DatabaseURL string

	// ReadTimeout / WriteTimeout bound individual HTTP requests.
	ReadTimeout  time.Duration
	WriteTimeout time.Duration
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok && value != "" {
		return value
	}
	return fallback
}

// ParseConfig builds a Config from the process environment.
func ParseConfig() (*Config, error) {
	return &Config{
		ListenAddr:   getEnv("LISTEN_ADDR", ":8080"),
		MetricsAddr:  getEnv("METRICS_ADDR", ":9090"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
	}, nil
}
