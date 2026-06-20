package main

import (
	"log/slog"
	"net"
	"net/http"
	"time"
)

// AccessLog wraps next so every served request is logged once, at Info level via
// the default slog logger (structured JSON to stderr, configured in main). It is
// the outermost handler in the chain, so the logged status and duration reflect
// the full response — including the cache-header and metrics layers it wraps.
//
// Unlike the Prometheus labels in Instrument, log lines are not a bounded series,
// so the concrete request path (path params and all) is logged rather than the
// matched route pattern: it is both safe here and more useful for tracing an
// individual request.
//
// Successful liveness/readiness probes are skipped: an orchestrator polls them
// every few seconds and they would otherwise drown out real traffic. A failing
// probe (e.g. readyz's 503 when the database is down) is still logged, so the
// signal that actually matters is never suppressed.
func AccessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// statusRecorder (defined alongside the metrics middleware) captures the
		// final status code; default 200 covers handlers that write a body without
		// an explicit WriteHeader.
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		start := time.Now()
		next.ServeHTTP(rec, r)
		elapsed := time.Since(start)

		if isProbe(r.URL.Path) && rec.status < http.StatusBadRequest {
			return
		}

		slog.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", float64(elapsed.Microseconds())/1000,
			"client_ip", clientIP(r),
			"peer", r.RemoteAddr,
			"user_agent", r.UserAgent(),
		)
	})
}

// clientIP returns the originating client's IP. Behind Cloudflare the TCP peer
// (r.RemoteAddr) is a Cloudflare edge server, so the real visitor IP is taken
// from the CF-Connecting-IP header Cloudflare sets. This trusts the header
// unconditionally, which is sound only because the origin is reachable solely
// through Cloudflare (firewalled to Cloudflare's IP ranges) — a direct caller
// could otherwise forge it. The raw peer is logged separately as "peer".
//
// When the header is absent (a direct hit such as an in-cluster health probe),
// it falls back to the host portion of the socket address.
func clientIP(r *http.Request) string {
	if ip := r.Header.Get("CF-Connecting-IP"); ip != "" {
		return ip
	}
	if host, _, err := net.SplitHostPort(r.RemoteAddr); err == nil {
		return host
	}
	return r.RemoteAddr
}

// isProbe reports whether path is one of the infra health endpoints, whose
// successful hits are intentionally kept out of the access log.
func isProbe(path string) bool {
	return path == "/livez" || path == "/readyz"
}
