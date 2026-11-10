package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestDocsRedirect verifies the default-document paths redirect to /docs while
// unknown paths still 404 (i.e. the redirect is not a greedy catch-all). The
// store is never touched by these routes, so a nil-store Server is sufficient.
func TestDocsRedirect(t *testing.T) {
	mux := NewServer(nil, "").Routes()

	tests := []struct {
		path         string
		wantStatus   int
		wantLocation string
	}{
		{"/", http.StatusFound, "/docs"},
		{"/index.html", http.StatusFound, "/docs"},
		{"/index.htm", http.StatusFound, "/docs"},
		{"/does-not-exist", http.StatusNotFound, ""},
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tt.path, nil))

			if rec.Code != tt.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tt.wantStatus)
			}
			if got := rec.Header().Get("Location"); got != tt.wantLocation {
				t.Errorf("Location = %q, want %q", got, tt.wantLocation)
			}
		})
	}
}

// TestBasePathRouting verifies that under a base path the docs, spec, and
// redirects move under the prefix, the unprefixed paths stop matching, and the
// liveness probe stays at the root. None of these routes touch the store.
func TestBasePathRouting(t *testing.T) {
	mux := NewServer(nil, "/test").Routes()

	tests := []struct {
		path         string
		wantStatus   int
		wantLocation string
	}{
		{"/test", http.StatusFound, "/test/docs"},
		{"/test/", http.StatusFound, "/test/docs"},
		{"/test/index.html", http.StatusFound, "/test/docs"},
		{"/test/docs", http.StatusOK, ""},
		{"/test/openapi.json", http.StatusOK, ""},
		{"/livez", http.StatusOK, ""},
		{"/test/livez", http.StatusNotFound, ""},
		{"/", http.StatusNotFound, ""},
		{"/docs", http.StatusNotFound, ""},
		{"/openapi.json", http.StatusNotFound, ""},
		{"/api/v1/players", http.StatusNotFound, ""},
		{"/testing/docs", http.StatusNotFound, ""},
	}

	for _, tt := range tests {
		t.Run(tt.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, tt.path, nil))

			if rec.Code != tt.wantStatus {
				t.Errorf("status = %d, want %d", rec.Code, tt.wantStatus)
			}
			if got := rec.Header().Get("Location"); got != tt.wantLocation {
				t.Errorf("Location = %q, want %q", got, tt.wantLocation)
			}
		})
	}

	// The docs UI must load the spec from under the prefix, and the spec must
	// advertise the prefix as its server URL so "try it" requests resolve.
	for path, want := range map[string]string{
		"/test/docs":         `/test/openapi`,
		"/test/openapi.json": `"url":"/test"`,
	} {
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if body := rec.Body.String(); !strings.Contains(body, want) {
			t.Errorf("%s body does not contain %q", path, want)
		}
	}
}

func TestNormaliseBasePath(t *testing.T) {
	tests := []struct {
		raw     string
		want    string
		wantErr bool
	}{
		{"", "", false},
		{"/", "", false},
		{"  ", "", false},
		{"test", "/test", false},
		{"/test", "/test", false},
		{"/test/", "/test", false},
		{"/stats/test", "/stats/test", false},
		{"/a//b", "", true},
		{"/a/../b", "", true},
		{"/test?x=1", "", true},
		{"/{id}", "", true},
		{"/has space", "", true},
	}

	for _, tt := range tests {
		t.Run(tt.raw, func(t *testing.T) {
			got, err := normaliseBasePath(tt.raw)
			if (err != nil) != tt.wantErr {
				t.Fatalf("err = %v, wantErr %v", err, tt.wantErr)
			}
			if got != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestStripBasePath(t *testing.T) {
	tests := []struct {
		pattern, basePath, want string
	}{
		{"GET /api/v1/players", "", "GET /api/v1/players"},
		{"GET /test/api/v1/players/{steam_id}", "/test", "GET /api/v1/players/{steam_id}"},
		{"GET /test", "/test", "GET /"},
		{"GET /test/{$}", "/test", "GET /{$}"},
		{"GET /livez", "/test", "GET /livez"},
		{"GET /testing/x", "/test", "GET /testing/x"},
		{"unmatched", "/test", "unmatched"},
	}

	for _, tt := range tests {
		if got := stripBasePath(tt.pattern, tt.basePath); got != tt.want {
			t.Errorf("stripBasePath(%q, %q) = %q, want %q", tt.pattern, tt.basePath, got, tt.want)
		}
	}
}
