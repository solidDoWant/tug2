package main

import (
	"net/http"
	"strings"
)

// cacheablePrefix is the path prefix whose successful GET responses are safe to
// stamp as cacheable: the versioned data API. Everything outside it — the
// liveness/readiness probes, the OpenAPI docs/spec — is intentionally excluded
// so health signals are never served stale and the spec stays revalidated.
const cacheablePrefix = "/api/v1/"

// CacheControl wraps next so that successful (2xx) responses to GET requests
// under /api/v1/* carry the given Cache-Control header, letting a shared cache
// (e.g. a CDN such as Cloudflare) serve repeated anonymous reads without hitting
// the origin. Because every data endpoint is a pure function of URL+query string
// with no auth or cookies, the full request URL is a sound cache key.
//
// Non-2xx responses (validation 422s, 404s, 5xx) are stamped no-store so a
// shared cache never holds an error in place of a real result. When value is
// empty the wrapper is a pass-through, so caching can be disabled wholesale via
// configuration.
func CacheControl(value string, next http.Handler) http.Handler {
	if value == "" {
		return next
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, cacheablePrefix) {
			w = &cacheWriter{ResponseWriter: w, cacheable: value}
		}
		next.ServeHTTP(w, r)
	})
}

// cacheWriter sets Cache-Control based on the final status code. The header must
// be written before the body, so the decision is deferred until WriteHeader (or
// the first Write, which implies a 200) — mirroring how statusRecorder captures
// the status for metrics.
type cacheWriter struct {
	http.ResponseWriter
	cacheable   string
	wroteHeader bool
}

func (w *cacheWriter) WriteHeader(code int) {
	if !w.wroteHeader {
		w.wroteHeader = true
		if code >= http.StatusOK && code < http.StatusMultipleChoices {
			w.Header().Set("Cache-Control", w.cacheable)
		} else {
			w.Header().Set("Cache-Control", "no-store")
		}
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *cacheWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(b)
}
