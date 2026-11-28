package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/bwmarrin/discordgo"
)

func TestReporterImages(t *testing.T) {
	img := func(id, name, ctype string, size int) *discordgo.MessageAttachment {
		return &discordgo.MessageAttachment{ID: id, Filename: name, ContentType: ctype, Size: size}
	}
	reporter, other := &discordgo.User{ID: "100"}, &discordgo.User{ID: "200"}
	msgs := []*discordgo.Message{
		// The thread's starter, in the parent channel.
		{ID: "50", ChannelID: "1", Author: reporter, Attachments: []*discordgo.MessageAttachment{
			img("a1", "vote [broken].png", "image/png", 1000), img("a2", "console.log", "text/plain", 10)}},
		{ID: "51", ChannelID: "50", Author: other, Attachments: []*discordgo.MessageAttachment{img("a3", "mine.png", "image/png", 10)}},
		{ID: "52", ChannelID: "50", Author: reporter, Attachments: []*discordgo.MessageAttachment{
			img("a4", "huge.png", "image/png", maxImageBytes+1), img("a5", "old.JPG", "", 10)}},
		{ID: "53", ChannelID: "50", Author: reporter, Attachments: []*discordgo.MessageAttachment{
			img("a6", "3.png", "image/png", 1), img("a7", "4.png", "image/png", 1), img("a8", "5.png", "image/png", 1),
			img("a9", "6.png", "image/png", 1)}},
	}
	got := reporterImages(msgs, "100", "9")
	var names []string
	for _, r := range got {
		names = append(names, r.Name)
	}
	if want := []string{"vote -broken-.png", "old.JPG", "3.png", "4.png", "5.png"}; !slices.Equal(names, want) {
		t.Errorf("images %v, want %v", names, want)
	}
	if got[0] != (AttachmentRef{Name: "vote -broken-.png", GuildID: "9", ChannelID: "1", MessageID: "50"}) {
		t.Errorf("first ref = %+v", got[0])
	}

	// The draft carries them, with the public warning, and reads them back.
	d := IssueDraft{Kind: IssueBug, Title: "t", Body: "b", Labels: []string{"area:maps"}, Attachments: got}
	embed := draftEmbed(d, "awaiting confirmation")
	if len(embed.Fields) != 2 || !strings.Contains(embed.Fields[1].Name, "public") ||
		!strings.Contains(embed.Fields[1].Value, "[vote -broken-.png](https://discord.com/channels/9/1/50)") {
		t.Errorf("fields = %+v", embed.Fields)
	}
	if back := draftAttachments(embed); !slices.Equal(back, got) {
		t.Errorf("read back %+v", back)
	}
	if !slices.Equal(draftLabels(embed), d.Labels) {
		t.Error("labels lost next to attachments")
	}
	if len(embed.Fields[1].Value) > 1024 {
		t.Errorf("field is %d characters, over Discord's 1024", len(embed.Fields[1].Value))
	}
}

type fakeMessages map[string]*discordgo.Message

func (f fakeMessages) ChannelMessage(channelID, messageID string, options ...discordgo.RequestOption) (*discordgo.Message, error) {
	if m, ok := f[channelID+"/"+messageID]; ok {
		return m, nil
	}
	return nil, errors.New("404 Unknown Message")
}

type fakeStore struct{ puts map[string][]byte }

func (s *fakeStore) Put(ctx context.Context, path string, data []byte) (string, error) {
	if s.puts == nil {
		s.puts = map[string][]byte{}
	}
	s.puts[path] = data
	return "https://media.example/" + path, nil
}

func TestCopyAttachments(t *testing.T) {
	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/gone.png" {
			http.Error(w, "expired", http.StatusNotFound)
			return
		}
		fmt.Fprint(w, "png bytes of "+r.URL.Path)
	}))
	defer cdn.Close()

	discord := fakeMessages{
		"1/50": {Attachments: []*discordgo.MessageAttachment{
			{ID: "a1", Filename: "vote [broken].png", ContentType: "image/png", URL: cdn.URL + "/fresh.png"}}},
		"50/52": {Attachments: []*discordgo.MessageAttachment{
			{ID: "a5", Filename: "gone.png", ContentType: "image/png", URL: cdn.URL + "/gone.png"}}},
	}
	refs := []AttachmentRef{
		{Name: "vote -broken-.png", GuildID: "9", ChannelID: "1", MessageID: "50"},
		{Name: "deleted.png", GuildID: "9", ChannelID: "50", MessageID: "51"}, // message deleted before Confirm
		{Name: "gone.png", GuildID: "9", ChannelID: "50", MessageID: "52"},    // CDN refuses
	}
	store := &fakeStore{}
	images, missing := copyAttachments(context.Background(), slog.Default(), discord, cdn.Client(), store, "50", refs)
	if missing != 2 || len(images) != 1 {
		t.Fatalf("images %+v, missing %d", images, missing)
	}
	path := "discord/50/a1-vote__broken_.png"
	if images[0] != (IssueImage{Name: "vote -broken-.png", URL: "https://media.example/" + path}) || string(store.puts[path]) != "png bytes of /fresh.png" {
		t.Errorf("images %+v, stored %q", images, store.puts)
	}

	section := imagesSection(images, missing)
	if !strings.Contains(section, "![vote -broken-.png](https://media.example/"+path+")") || !strings.Contains(section, "2 more couldn't be copied") {
		t.Errorf("section = %q", section)
	}
	if imagesSection(nil, 0) != "" {
		t.Error("an issue without images got a screenshots section")
	}
}

// TestIssueTrackerAttachmentsRepo checks the screenshots repository setup:
// its own token limited to that repo's contents, the issues token limited to
// issues, and files committed and embedded from raw.githubusercontent.com.
func TestIssueTrackerAttachmentsRepo(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})

	var mu sync.Mutex
	tokenRequests := map[string]string{} // token -> requested options
	committed := map[string]map[string]any{}
	var issueBody string
	mux := http.NewServeMux()
	mux.HandleFunc("GET /repos/example/repo/installation", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"id": 77}`))
	})
	mux.HandleFunc("POST /app/installations/77/access_tokens", func(w http.ResponseWriter, r *http.Request) {
		var opts struct {
			Repositories []string          `json:"repositories"`
			Permissions  map[string]string `json:"permissions"`
		}
		json.NewDecoder(r.Body).Decode(&opts)
		token := "issues-token"
		if opts.Permissions["contents"] != "" {
			token = "contents-token"
		}
		raw, _ := json.Marshal(opts)
		mu.Lock()
		tokenRequests[token] = string(raw)
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
		fmt.Fprintf(w, `{"token": %q, "expires_at": "2099-01-01T00:00:00Z"}`, token)
	})
	mux.HandleFunc("GET /repos/example/media", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"name": "media", "private": false, "default_branch": "main"}`))
	})
	mux.HandleFunc("PUT /repos/example/media/contents/{path...}", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Header.Get("Authorization") != "token contents-token" {
			t.Errorf("commit used %q", r.Header.Get("Authorization"))
		}
		path := r.PathValue("path")
		if _, ok := committed[path]; ok {
			w.WriteHeader(http.StatusUnprocessableEntity)
			w.Write([]byte(`{"message": "Invalid request.\n\n\"sha\" wasn't supplied."}`))
			return
		}
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		committed[path] = body
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{}`))
	})
	mux.HandleFunc("GET /repos/example/media/contents/{path...}", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if _, ok := committed[r.PathValue("path")]; !ok || r.URL.Query().Get("ref") != "main" {
			http.NotFound(w, r)
			return
		}
		w.Write([]byte(`{"type": "file", "name": "x"}`))
	})
	mux.HandleFunc("POST /repos/example/repo/issues", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		issueBody, _ = body["body"].(string)
		if r.Header.Get("Authorization") != "token issues-token" {
			t.Errorf("issue created with %q", r.Header.Get("Authorization"))
		}
		mu.Unlock()
		w.WriteHeader(http.StatusCreated)
		w.Write([]byte(`{"number": 6, "html_url": "https://github.com/example/repo/issues/6"}`))
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	cfg := &Config{
		GitHubAppID: 12345, GitHubAppPrivateKey: keyPEM,
		GitHubOwner: "example", GitHubRepo: "repo",
		GitHubAttachmentsOwner: "example", GitHubAttachmentsRepo: "media",
		ServerOrder:  []string{"main"},
		githubAPIURL: server.URL + "/",
	}
	tracker, err := NewIssueTracker(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	if tracker.media == nil {
		t.Fatal("no media store")
	}

	url, err := tracker.media.Put(context.Background(), "discord/50/a1-shot.png", []byte("png"))
	if err != nil || url != "https://raw.githubusercontent.com/example/media/main/discord/50/a1-shot.png" {
		t.Fatalf("Put = %q, %v", url, err)
	}
	// A retried filing finds the file already there.
	if again, err := tracker.media.Put(context.Background(), "discord/50/a1-shot.png", []byte("png")); err != nil || again != url {
		t.Errorf("retry Put = %q, %v", again, err)
	}
	if _, err := tracker.Create(context.Background(), IssueDraft{Kind: IssueBug, Title: "t", Body: "b"}, "https://discord.com/channels/9/50",
		[]IssueImage{{Name: "shot.png", URL: url}}, 0); err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	defer mu.Unlock()
	c := committed["discord/50/a1-shot.png"]
	if content, _ := base64.StdEncoding.DecodeString(fmt.Sprint(c["content"])); string(content) != "png" || c["branch"] != "main" {
		t.Errorf("commit = %v", c)
	}
	if !strings.Contains(issueBody, "![shot.png]("+url+")") {
		t.Errorf("issue body = %q", issueBody)
	}
	if got := tokenRequests["issues-token"]; got != `{"repositories":["repo"],"permissions":{"issues":"write","metadata":"read"}}` {
		t.Errorf("issues token requested %s", got)
	}
	if got := tokenRequests["contents-token"]; got != `{"repositories":["media"],"permissions":{"contents":"write","metadata":"read"}}` {
		t.Errorf("contents token requested %s", got)
	}
}
