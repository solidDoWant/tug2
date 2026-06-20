package main

import (
	"os"
	"strings"
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

	// CacheControl is the Cache-Control header stamped on successful (2xx) GET
	// responses to /api/v1/* so a shared cache (a CDN such as Cloudflare) can
	// serve repeated reads without hitting the origin. An empty value disables
	// the header entirely. The default keeps shared caches no more than ~60s
	// stale, which is the intended freshness floor for this data.
	CacheControl string
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok && value != "" {
		return value
	}
	return fallback
}

// defaultCacheControl keeps shared caches at most ~60s stale (s-maxage), lets
// them serve slightly-stale content while refreshing in the background
// (stale-while-revalidate) and keep serving the last good response when the
// origin is erroring (stale-if-error). It targets shared caches only via
// s-maxage, leaving browser caching to the absent max-age (i.e. effectively
// uncached in the browser).
const defaultCacheControl = "public, s-maxage=60, stale-while-revalidate=60, stale-if-error=86400"

// ParseConfig builds a Config from the process environment.
func ParseConfig() (*Config, error) {
	// CACHE_CONTROL overrides the default directive; the sentinel "off" disables
	// the header entirely (an unset/empty var keeps the default).
	cacheControl := getEnv("CACHE_CONTROL", defaultCacheControl)
	if strings.EqualFold(cacheControl, "off") {
		cacheControl = ""
	}

	return &Config{
		ListenAddr:   getEnv("LISTEN_ADDR", ":8080"),
		MetricsAddr:  getEnv("METRICS_ADDR", ":9090"),
		DatabaseURL:  os.Getenv("DATABASE_URL"),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 30 * time.Second,
		CacheControl: cacheControl,
	}, nil
}
