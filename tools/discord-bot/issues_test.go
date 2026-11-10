package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// TestIssueTrackerGitHubApp drives the whole GitHub App chain against a fake
// API: the app JWT finds the repo installation, an installation token is
// minted, and search/create run with that token.
func TestIssueTrackerGitHubApp(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})

	var mu sync.Mutex
	var created map[string]any
	authSeen := map[string]string{}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /repos/example/repo/installation", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		authSeen["installation"] = r.Header.Get("Authorization")
		mu.Unlock()
		w.Write([]byte(`{"id": 77}`))
	})
	mux.HandleFunc("POST /app/installations/77/access_tokens", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"token": "installation-token", "expires_at": "2099-01-01T00:00:00Z"}`))
	})
	mux.HandleFunc("GET /search/issues", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		authSeen["search"] = r.Header.Get("Authorization")
		authSeen["query"] = r.URL.Query().Get("q")
		mu.Unlock()
		w.Write([]byte(`{"total_count":1,"items":[{"number":5,"title":"Medic revive broken","state":"open","html_url":"https://github.com/example/repo/issues/5"}]}`))
	})
	mux.HandleFunc("POST /repos/example/repo/issues", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		authSeen["create"] = r.Header.Get("Authorization")
		json.NewDecoder(r.Body).Decode(&created)
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"number": 6, "html_url": "https://github.com/example/repo/issues/6"}`))
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	cfg := &Config{
		GitHubAppID: 12345, GitHubAppPrivateKey: keyPEM,
		GitHubOwner: "example", GitHubRepo: "repo",
		IssueLabels: []string{"from-discord"}, BugLabel: "bug", FeatureLabel: "enhancement",
		githubAPIURL: server.URL + "/",
	}
	tracker, err := NewIssueTracker(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}

	hits, err := tracker.Search(context.Background(), "medic revive")
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 || hits[0].Number != 5 {
		t.Errorf("search hits = %+v", hits)
	}

	url, err := tracker.Create(context.Background(),
		IssueDraft{Kind: IssueBug, Title: "Medics can't revive", Body: "Steps..."},
		Reporter{Username: "testuserone", UserID: "100000000000000001", MessageLink: "https://discord.com/channels/1/2/3"})
	if err != nil {
		t.Fatal(err)
	}
	if url != "https://github.com/example/repo/issues/6" {
		t.Errorf("url = %s", url)
	}

	mu.Lock()
	defer mu.Unlock()
	if !strings.HasPrefix(authSeen["installation"], "Bearer ") {
		t.Errorf("installation lookup must use the app JWT, got %q", authSeen["installation"])
	}
	for _, call := range []string{"search", "create"} {
		if authSeen[call] != "token installation-token" {
			t.Errorf("%s used auth %q, want the installation token", call, authSeen[call])
		}
	}
	if authSeen["query"] != "repo:example/repo is:issue medic revive" {
		t.Errorf("search query = %q", authSeen["query"])
	}
	labels, _ := json.Marshal(created["labels"])
	if string(labels) != `["from-discord","bug"]` {
		t.Errorf("labels = %s", labels)
	}
	if body, _ := created["body"].(string); !strings.Contains(body, "testuserone") || !strings.Contains(body, "https://discord.com/channels/1/2/3") {
		t.Errorf("body missing reporter footer: %q", body)
	}
}
