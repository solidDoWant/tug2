package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCacheControl(t *testing.T) {
	const value = "public, s-maxage=60"

	// implicit=true exercises the bare-Write path (Go fills in an implicit 200);
	// implicit=false issues an explicit WriteHeader(status) followed by a body,
	// which is how huma emits both success and problem-detail error responses.
	handlerWith := func(status int, implicit bool) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if implicit {
				_, _ = w.Write([]byte("{}"))
				return
			}
			w.WriteHeader(status)
			_, _ = w.Write([]byte("{}"))
		})
	}

	tests := []struct {
		name     string
		value    string
		method   string
		path     string
		status   int
		implicit bool
		wantCC   string
	}{
		{"cacheable 200 via Write", value, http.MethodGet, "/api/v1/players", http.StatusOK, true, value},
		{"cacheable 200 via WriteHeader", value, http.MethodGet, "/api/v1/maps", http.StatusOK, false, value},
		{"error 422 not cached", value, http.MethodGet, "/api/v1/players", http.StatusUnprocessableEntity, false, "no-store"},
		{"error 500 not cached", value, http.MethodGet, "/api/v1/weapons", http.StatusInternalServerError, false, "no-store"},
		{"probe path untouched", value, http.MethodGet, "/readyz", http.StatusOK, true, ""},
		{"docs path untouched", value, http.MethodGet, "/openapi.json", http.StatusOK, true, ""},
		{"non-GET untouched", value, http.MethodPost, "/api/v1/players", http.StatusOK, true, ""},
		{"disabled passes through", "", http.MethodGet, "/api/v1/players", http.StatusOK, true, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			h := CacheControl(tt.value, handlerWith(tt.status, tt.implicit))
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, httptest.NewRequest(tt.method, tt.path, nil))

			if got := rec.Header().Get("Cache-Control"); got != tt.wantCC {
				t.Errorf("Cache-Control = %q, want %q", got, tt.wantCC)
			}
		})
	}
}
