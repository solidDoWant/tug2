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
	"slices"
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
	var createdLabels []string
	mux.HandleFunc("GET /repos/example/repo/labels", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`[{"name":"bug"},{"name":"Area:Maps"}]`))
	})
	mux.HandleFunc("POST /repos/example/repo/labels", func(w http.ResponseWriter, r *http.Request) {
		var l map[string]string
		json.NewDecoder(r.Body).Decode(&l)
		mu.Lock()
		createdLabels = append(createdLabels, l["name"])
		mu.Unlock()
		if l["description"] == "" || len(l["color"]) != 6 {
			t.Errorf("label created without a description or color: %v", l)
		}
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{}`))
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	cfg := &Config{
		GitHubAppID: 12345, GitHubAppPrivateKey: keyPEM,
		GitHubOwner: "example", GitHubRepo: "repo",
		IssueLabels: []string{"from-discord"}, BugLabel: "bug", FeatureLabel: "enhancement",
		ServerOrder: []string{"main", "test"},
		githubAPIURL: server.URL + "/",
	}
	tracker, err := NewIssueTracker(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}

	if err := tracker.EnsureLabels(context.Background()); err != nil {
		t.Fatal(err)
	}
	// Existing labels match case-insensitively, as on GitHub.
	if want := []string{"area:gameplay", "area:stats", "area:discord-relay", "area:discord-bot", "server:main", "server:test"}; !slices.Equal(createdLabels, want) {
		t.Errorf("created labels %v, want %v", createdLabels, want)
	}
	if _, err := tracker.Create(context.Background(), IssueDraft{Kind: IssueBug, Title: "x", Body: "y", Labels: []string{"wontfix"}}, ""); err == nil {
		t.Error("a label outside the list was accepted")
	}

	hits, err := tracker.Search(context.Background(), "medic revive")
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 || hits[0].Number != 5 {
		t.Errorf("search hits = %+v", hits)
	}

	url, err := tracker.Create(context.Background(),
		IssueDraft{Kind: IssueBug, Title: "Medics can't revive", Body: "Steps...", Labels: []string{"server:test", "area:gameplay"}},
		"https://discord.com/channels/1/2")
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
	if string(labels) != `["from-discord","bug","area:gameplay","server:test"]` {
		t.Errorf("labels = %s", labels)
	}
	if body, _ := created["body"].(string); !strings.Contains(body, "[Discord thread](https://discord.com/channels/1/2)") || strings.Contains(body, "Reported on Discord by") {
		t.Errorf("body footer wrong: %q", body)
	}
}

func TestDraftLabelsRoundTrip(t *testing.T) {
	d := IssueDraft{Kind: IssueFeature, Title: "t", Body: "b", Labels: []string{"area:stats", "server:main"}}
	embed := draftEmbed(d, "awaiting confirmation")
	if got := draftLabels(embed); !slices.Equal(got, d.Labels) {
		t.Errorf("labels read back as %v", got)
	}
	if e := draftEmbed(IssueDraft{Kind: IssueBug, Title: "t", Body: "b"}, "x"); len(e.Fields) != 0 || draftLabels(e) != nil {
		t.Error("a draft without labels got a labels field")
	}

	choices := issueLabelChoices(&Config{ServerOrder: []string{"main"}})
	if got, err := checkLabels([]string{"server:main", "area:maps", "server:main"}, choices); err != nil || !slices.Equal(got, []string{"area:maps", "server:main"}) {
		t.Errorf("checkLabels = %v, %v", got, err)
	}
	if _, err := checkLabels([]string{"server:test"}, choices); err == nil {
		t.Error("a server that isn't configured was accepted")
	}
}
