package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
)

// wifEnv clears every credential variable, then sets the given ones.
func wifEnv(t *testing.T, set map[string]string) {
	t.Helper()
	t.Setenv("DISCORD_TOKEN", "x")
	t.Setenv("DISCORD_CHANNEL_ID", "1")
	t.Setenv("SERVERS", `[{"name":"main","query_address":"h:27000"}]`)
	for _, k := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_PROFILE",
		"ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID", "ANTHROPIC_SERVICE_ACCOUNT_ID",
		"ANTHROPIC_WORKSPACE_ID", "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_IDENTITY_TOKEN"} {
		t.Setenv(k, "")
	}
	for k, v := range set {
		t.Setenv(k, v)
	}
}

func TestParseAnthropicAuth(t *testing.T) {
	tokenFile := t.TempDir() + "/token"
	if err := os.WriteFile(tokenFile, []byte("header.payload.sig"), 0o600); err != nil {
		t.Fatal(err)
	}
	emptyFile := t.TempDir() + "/empty"
	os.WriteFile(emptyFile, nil, 0o600)

	wif := map[string]string{
		"ANTHROPIC_FEDERATION_RULE_ID":  "fdrl_test",
		"ANTHROPIC_ORGANIZATION_ID":     "org_test",
		"ANTHROPIC_IDENTITY_TOKEN_FILE": tokenFile,
	}
	with := func(extra map[string]string, drop ...string) map[string]string {
		out := map[string]string{}
		for k, v := range wif {
			out[k] = v
		}
		for k, v := range extra {
			out[k] = v
		}
		for _, k := range drop {
			delete(out, k)
		}
		return out
	}

	tests := []struct {
		name    string
		env     map[string]string
		want    string
		wantErr string
	}{
		{"api key", map[string]string{"ANTHROPIC_API_KEY": "sk-test"}, authAPIKey, ""},
		{"wif", wif, authWorkloadIdentity, ""},
		{"wif with optional ids", with(map[string]string{"ANTHROPIC_SERVICE_ACCOUNT_ID": "svac_x", "ANTHROPIC_WORKSPACE_ID": "wrkspc_x"}), authWorkloadIdentity, ""},
		{"wif inline token", with(map[string]string{"ANTHROPIC_IDENTITY_TOKEN": "a.b.c"}, "ANTHROPIC_IDENTITY_TOKEN_FILE"), authWorkloadIdentity, ""},
		{"nothing", nil, "", "for the Claude API are required"},
		{"both", with(map[string]string{"ANTHROPIC_API_KEY": "sk-test"}), "", "silently win"},
		{"partial", with(nil, "ANTHROPIC_ORGANIZATION_ID"), "", "missing ANTHROPIC_ORGANIZATION_ID"},
		{"no token", with(nil, "ANTHROPIC_IDENTITY_TOKEN_FILE"), "", "ANTHROPIC_IDENTITY_TOKEN_FILE (or"},
		{"auth token shadows", with(map[string]string{"ANTHROPIC_AUTH_TOKEN": "x"}), "", "ANTHROPIC_AUTH_TOKEN is set"},
		{"profile shadows", with(map[string]string{"ANTHROPIC_PROFILE": "work"}), "", "ANTHROPIC_PROFILE is set"},
		{"missing token file", with(map[string]string{"ANTHROPIC_IDENTITY_TOKEN_FILE": "/nonexistent/token"}), "", "reading ANTHROPIC_IDENTITY_TOKEN_FILE"},
		{"empty token file", with(map[string]string{"ANTHROPIC_IDENTITY_TOKEN_FILE": emptyFile}), "", "is empty"},
		{"two token sources", with(map[string]string{"ANTHROPIC_IDENTITY_TOKEN": "a.b.c"}), "", "only one of"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			wifEnv(t, tt.env)
			cfg, err := ParseConfig()
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("want error containing %q, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if cfg.AnthropicAuth != tt.want {
				t.Errorf("auth = %q, want %q", cfg.AnthropicAuth, tt.want)
			}
		})
	}
}

// TestWorkloadIdentityEndToEnd runs the bot's client against a fake API with
// workload identity configured: the SDK must exchange the identity token for
// an access token, and both the startup check and a question must use it.
func TestWorkloadIdentityEndToEnd(t *testing.T) {
	tokenFile := t.TempDir() + "/token"
	if err := os.WriteFile(tokenFile, []byte("k8s.projected.token\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	var exchange map[string]any
	var authSeen []string
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/oauth/token", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		json.NewDecoder(r.Body).Decode(&exchange)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"access_token":"exchanged-access-token","token_type":"Bearer","expires_in":3600}`)
	})
	mux.HandleFunc("GET /v1/models/{model}", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		authSeen = append(authSeen, "models:"+r.Header.Get("Authorization"))
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"id":%q,"type":"model","display_name":"Test","created_at":"2026-01-01T00:00:00Z"}`, r.PathValue("model"))
	})
	mux.HandleFunc("POST /v1/messages", func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		authSeen = append(authSeen, "messages:"+r.Header.Get("Authorization")+" key="+r.Header.Get("X-Api-Key"))
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"msg_1","type":"message","role":"assistant","model":"fake","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":5,"output_tokens":1}}`)
	})
	server := httptest.NewServer(mux)
	defer server.Close()

	wifEnv(t, map[string]string{
		"ANTHROPIC_BASE_URL":            server.URL,
		"ANTHROPIC_FEDERATION_RULE_ID":  "fdrl_test",
		"ANTHROPIC_ORGANIZATION_ID":     "org_test",
		"ANTHROPIC_SERVICE_ACCOUNT_ID":  "svac_test",
		"ANTHROPIC_IDENTITY_TOKEN_FILE": tokenFile,
	})
	cfg, err := ParseConfig()
	if err != nil {
		t.Fatal(err)
	}
	cfg.Model = "fake"
	agent := NewAgent(cfg, &Toolset{tools: map[string]tool{}}, false, nil)

	if err := agent.CheckAccess(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := agent.Answer(context.Background(), "1", []Turn{{Author: "TestUserOne", Text: "hello"}}); err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	defer mu.Unlock()
	for k, want := range map[string]string{"assertion": "k8s.projected.token", "federation_rule_id": "fdrl_test",
		"organization_id": "org_test", "service_account_id": "svac_test"} {
		if got, _ := exchange[k].(string); got != want {
			t.Errorf("token exchange %s = %q, want %q", k, got, want)
		}
	}
	want := []string{"models:Bearer exchanged-access-token", "messages:Bearer exchanged-access-token key="}
	if strings.Join(authSeen, "|") != strings.Join(want, "|") {
		t.Errorf("requests authenticated as %v, want %v", authSeen, want)
	}
}

func TestThreadArchiveMinutes(t *testing.T) {
	for _, tc := range []struct {
		value   string
		want    int
		wantErr bool
	}{
		{"", 60, false},
		{"1440", 1440, false},
		{"10080", 10080, false},
		{"30", 0, true},
		{"abc", 0, true},
	} {
		wifEnv(t, map[string]string{"ANTHROPIC_API_KEY": "k", "THREAD_AUTO_ARCHIVE_MINUTES": tc.value})
		cfg, err := ParseConfig()
		if tc.wantErr {
			if err == nil || !strings.Contains(err.Error(), "THREAD_AUTO_ARCHIVE_MINUTES") {
				t.Errorf("%q: want an error naming THREAD_AUTO_ARCHIVE_MINUTES, got %v", tc.value, err)
			}
			continue
		}
		if err != nil {
			t.Fatalf("%q: %v", tc.value, err)
		}
		if cfg.ThreadArchiveMinutes != tc.want {
			t.Errorf("%q: got %d, want %d", tc.value, cfg.ThreadArchiveMinutes, tc.want)
		}
	}
}
