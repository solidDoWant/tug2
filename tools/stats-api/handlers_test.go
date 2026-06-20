package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestDocsRedirect verifies the default-document paths redirect to /docs while
// unknown paths still 404 (i.e. the redirect is not a greedy catch-all). The
// store is never touched by these routes, so a nil-store Server is sufficient.
func TestDocsRedirect(t *testing.T) {
	mux := NewServer(nil).Routes()

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
