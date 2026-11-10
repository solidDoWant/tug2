package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

// GameServer is one game server the bot can answer about: its stats-api
// deployment and its Source query (A2S) address.
type GameServer struct {
	// Name is the label users and the model use ("main", "test").
	Name string `json:"name"`
	// Description is a short note for the model, e.g. "the public server" or
	// "where balance changes are tried first".
	Description string `json:"description"`
	// StatsAPIURL is the stats-api base URL including any BASE_PATH, e.g.
	// "http://stats-api.insurgency.svc/test". Empty disables stats for it.
	StatsAPIURL string `json:"stats_api_url"`
	// PublicStatsAPIURL is the address users can reach the same stats API at
	// (including any BASE_PATH), shared when they ask how to use the API.
	// Empty means the API is not public for this server.
	PublicStatsAPIURL string `json:"public_stats_api_url"`
	// QueryAddress is the game server's host:port for A2S queries (the game
	// port; Source answers queries on it). Empty disables live status for it.
	QueryAddress string `json:"query_address"`
}

// UserLimit overrides the default limits for one Discord user. A nil field
// keeps the default; 0 means no limit.
type UserLimit struct {
	QuestionsPerHour *int `json:"questions_per_hour"`
	IssuesPerDay     *int `json:"issues_per_day"`
	// Note is free text for whoever maintains the list ("server owner").
	Note string `json:"note"`
}

// ReadableChannel is a Discord channel the model may read, such as a changelog.
type ReadableChannel struct {
	// Name is how the model refers to it ("changelog").
	Name string `json:"name"`
	ID   string `json:"id"`
	// Description tells the model what the channel holds and when to read it.
	Description string `json:"description"`
}

// Config is the bot's runtime configuration, read from the environment.
type Config struct {
	DiscordToken string
	// ChannelID is the one channel the bot answers @mentions in. Follow-ups in
	// the threads it starts there need no mention.
	ChannelID string

	// Servers is keyed by GameServer.Name; ServerOrder keeps the configured
	// order for prompts and tool enums, and its first entry is the default.
	Servers     map[string]GameServer
	ServerOrder []string

	// Anthropic API key is read by the SDK from ANTHROPIC_API_KEY.
	Model     string
	Effort    string
	MaxTokens int64
	// MaxToolRounds caps model<->tool round trips per question.
	MaxToolRounds int
	// TokensPerQuestion caps the tokens processed for one question across all
	// rounds; 0 means no cap. Reaching it ends the lookups and the model
	// answers with what it has.
	TokensPerQuestion int
	// MaxContextTokens caps the size of any single model call's input. The
	// default keeps every call under the 100K-token prompt size above which
	// Claude Haiku 5.5 charges a higher rate.
	MaxContextTokens int
	// MaxToolCallsPerRound caps how many tool calls run from one response.
	MaxToolCallsPerRound int
	// HistoryMessages caps how many thread messages are sent as context.
	HistoryMessages int

	// GitHub App credentials. Issues are filed as the app ("name[bot]"), not
	// as any person. The installation is looked up from the repo at startup
	// unless GitHubInstallationID is set.
	GitHubAppID          int64
	GitHubAppPrivateKey  []byte
	GitHubInstallationID int64
	// githubAPIURL overrides https://api.github.com/ (tests only).
	githubAPIURL string
	// GitHubOwner/GitHubRepo is where bug reports and feature requests go.
	GitHubOwner string
	GitHubRepo  string
	// Labels applied to every filed issue, plus one per kind.
	IssueLabels   []string
	BugLabel      string
	FeatureLabel  string
	IssuesEnabled bool

	// Per-user limits: questions per hour, and issues filed per day.
	QuestionsPerHour int
	IssuesPerDay     int
	// MaxConcurrent caps questions being answered at once across all users.
	MaxConcurrent int
	// UserLimits overrides the per-user limits, keyed by Discord user ID.
	UserLimits map[string]UserLimit

	// ReadableChannels are the extra channels the model may read, in
	// configured order.
	ReadableChannels []ReadableChannel

	HealthAddr string
	A2STimeout time.Duration
}

func getEnv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	return fallback
}

func getEnvInt(key string, fallback int) (int, error) {
	raw := getEnv(key, "")
	if raw == "" {
		return fallback, nil
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v < 0 {
		return 0, fmt.Errorf("%s must be a non-negative integer, got %q", key, raw)
	}
	return v, nil
}

func splitList(raw string) []string {
	var out []string
	for _, part := range strings.Split(raw, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

// ParseConfig reads and validates the configuration. Every problem is
// reported at once so a misconfigured deployment fails with the full list.
func ParseConfig() (*Config, error) {
	var errs []error
	c := &Config{
		DiscordToken: getEnv("DISCORD_TOKEN", ""),
		ChannelID:    getEnv("DISCORD_CHANNEL_ID", ""),
		Model:        getEnv("LLM_MODEL", "claude-haiku-5-5"),
		Effort:       getEnv("LLM_EFFORT", "low"),
		IssueLabels:  splitList(getEnv("GITHUB_ISSUE_LABELS", "from-discord")),
		BugLabel:     getEnv("GITHUB_BUG_LABEL", "bug"),
		FeatureLabel: getEnv("GITHUB_FEATURE_LABEL", "enhancement"),
		HealthAddr:   getEnv("HEALTH_ADDR", ":8080"),
		Servers:      map[string]GameServer{},
	}

	if c.DiscordToken == "" {
		errs = append(errs, errors.New("DISCORD_TOKEN is required"))
	}
	if c.ChannelID == "" {
		errs = append(errs, errors.New("DISCORD_CHANNEL_ID is required"))
	}

	switch c.Effort {
	case "low", "medium", "high", "xhigh", "max":
	default:
		errs = append(errs, fmt.Errorf("LLM_EFFORT must be one of low, medium, high, xhigh, max; got %q", c.Effort))
	}

	maxTokens, err := getEnvInt("LLM_MAX_TOKENS", 8000)
	errs = append(errs, err)
	c.MaxTokens = int64(maxTokens)
	c.MaxToolRounds, err = getEnvInt("LLM_MAX_TOOL_ROUNDS", 8)
	errs = append(errs, err)
	c.TokensPerQuestion, err = getEnvInt("LLM_TOKENS_PER_QUESTION", 150000)
	errs = append(errs, err)
	c.MaxContextTokens, err = getEnvInt("LLM_MAX_CONTEXT_TOKENS", 80000)
	errs = append(errs, err)
	c.MaxToolCallsPerRound, err = getEnvInt("LLM_MAX_TOOL_CALLS_PER_ROUND", 4)
	errs = append(errs, err)
	c.HistoryMessages, err = getEnvInt("HISTORY_MESSAGES", 40)
	errs = append(errs, err)
	c.QuestionsPerHour, err = getEnvInt("RATE_LIMIT_QUESTIONS_PER_HOUR", 20)
	errs = append(errs, err)
	c.IssuesPerDay, err = getEnvInt("RATE_LIMIT_ISSUES_PER_DAY", 5)
	errs = append(errs, err)
	c.MaxConcurrent, err = getEnvInt("MAX_CONCURRENT_QUESTIONS", 4)
	errs = append(errs, err)
	if c.MaxConcurrent == 0 {
		c.MaxConcurrent = 1
	}
	timeoutMS, err := getEnvInt("A2S_TIMEOUT_MS", 3000)
	errs = append(errs, err)
	c.A2STimeout = time.Duration(timeoutMS) * time.Millisecond

	errs = append(errs, c.parseGitHub())
	errs = append(errs, c.parseUserLimits())
	errs = append(errs, c.parseReadableChannels())

	// SERVERS is a JSON array of GameServer objects.
	raw := getEnv("SERVERS", "")
	if raw == "" {
		errs = append(errs, errors.New("SERVERS is required (JSON array of {name, description, stats_api_url, query_address})"))
	} else {
		var servers []GameServer
		if err := json.Unmarshal([]byte(raw), &servers); err != nil {
			errs = append(errs, fmt.Errorf("SERVERS is not valid JSON: %w", err))
		}
		for _, s := range servers {
			s.Name = strings.ToLower(strings.TrimSpace(s.Name))
			s.StatsAPIURL = strings.TrimRight(s.StatsAPIURL, "/")
			s.PublicStatsAPIURL = strings.TrimRight(strings.TrimSpace(s.PublicStatsAPIURL), "/")
			switch {
			case s.Name == "":
				errs = append(errs, errors.New("SERVERS: every server needs a name"))
			case c.Servers[s.Name].Name != "":
				errs = append(errs, fmt.Errorf("SERVERS: duplicate server name %q", s.Name))
			case s.PublicStatsAPIURL != "" && !isHTTPURL(s.PublicStatsAPIURL):
				errs = append(errs, fmt.Errorf("SERVERS: server %q public_stats_api_url must be an http(s) URL, got %q", s.Name, s.PublicStatsAPIURL))
			case s.StatsAPIURL == "" && s.QueryAddress == "":
				errs = append(errs, fmt.Errorf("SERVERS: server %q has neither stats_api_url nor query_address", s.Name))
			default:
				c.Servers[s.Name] = s
				c.ServerOrder = append(c.ServerOrder, s.Name)
			}
		}
		if len(servers) > 0 && len(c.ServerOrder) == 0 {
			errs = append(errs, errors.New("SERVERS: no usable servers"))
		}
	}

	if err := errors.Join(errs...); err != nil {
		return nil, err
	}
	return c, nil
}

// parseGitHub reads the repository and GitHub App settings. Issue tools are
// offered only when the repo and the app are both configured, so the bot
// still runs for stats alone.
func (c *Config) parseGitHub() error {
	var errs []error
	if repo := getEnv("GITHUB_REPO", ""); repo != "" {
		owner, name, ok := strings.Cut(repo, "/")
		if !ok || owner == "" || name == "" || strings.Contains(name, "/") {
			errs = append(errs, fmt.Errorf("GITHUB_REPO must be owner/name, got %q", repo))
		}
		c.GitHubOwner, c.GitHubRepo = owner, name
	}

	if raw := getEnv("GITHUB_APP_ID", ""); raw != "" {
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || id <= 0 {
			errs = append(errs, fmt.Errorf("GITHUB_APP_ID must be a positive integer, got %q", raw))
		}
		c.GitHubAppID = id
	}
	if raw := getEnv("GITHUB_APP_INSTALLATION_ID", ""); raw != "" {
		id, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || id <= 0 {
			errs = append(errs, fmt.Errorf("GITHUB_APP_INSTALLATION_ID must be a positive integer, got %q", raw))
		}
		c.GitHubInstallationID = id
	}

	// The key is a PEM file, normally a mounted secret; the inline variable is
	// for environments that can only pass strings.
	keyFile, keyInline := getEnv("GITHUB_APP_PRIVATE_KEY_FILE", ""), os.Getenv("GITHUB_APP_PRIVATE_KEY")
	switch {
	case keyFile != "" && keyInline != "":
		errs = append(errs, errors.New("set only one of GITHUB_APP_PRIVATE_KEY_FILE and GITHUB_APP_PRIVATE_KEY"))
	case keyFile != "":
		key, err := os.ReadFile(keyFile)
		if err != nil {
			errs = append(errs, fmt.Errorf("reading GITHUB_APP_PRIVATE_KEY_FILE: %w", err))
		}
		c.GitHubAppPrivateKey = key
	case keyInline != "":
		c.GitHubAppPrivateKey = []byte(keyInline)
	}

	appSet := c.GitHubAppID != 0 || len(c.GitHubAppPrivateKey) > 0
	switch {
	case appSet && (c.GitHubAppID == 0 || len(c.GitHubAppPrivateKey) == 0):
		errs = append(errs, errors.New("GITHUB_APP_ID and a GitHub App private key must be set together"))
	case appSet && c.GitHubRepo == "":
		errs = append(errs, errors.New("GITHUB_REPO is required when a GitHub App is configured"))
	}
	c.IssuesEnabled = appSet && c.GitHubRepo != "" && len(errs) == 0
	return errors.Join(errs...)
}

// isHTTPURL reports whether s is an absolute http or https URL with a host and
// no query or fragment, so base URL + path builds a valid link.
func isHTTPURL(s string) bool {
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" && u.RawQuery == "" && u.Fragment == ""
}

// hasPublicStatsAPI reports whether any server shares its stats API publicly.
func (c *Config) hasPublicStatsAPI() bool {
	for _, s := range c.Servers {
		if s.PublicStatsAPIURL != "" {
			return true
		}
	}
	return false
}

// isSnowflake reports whether s looks like a Discord ID.
func isSnowflake(s string) bool {
	_, err := strconv.ParseUint(s, 10, 64)
	return err == nil && len(s) >= 15
}

// readJSONSetting reads a JSON setting given either inline (key) or as a file
// (key_FILE, e.g. a mounted ConfigMap). It returns nil when neither is set.
func readJSONSetting(key string) ([]byte, error) {
	inline, file := getEnv(key, ""), getEnv(key+"_FILE", "")
	switch {
	case inline != "" && file != "":
		return nil, fmt.Errorf("set only one of %s and %s_FILE", key, key)
	case file != "":
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, fmt.Errorf("reading %s_FILE: %w", key, err)
		}
		return data, nil
	case inline != "":
		return []byte(inline), nil
	}
	return nil, nil
}

// parseUserLimits reads USER_LIMITS: a JSON object mapping Discord user IDs to
// UserLimit overrides.
func (c *Config) parseUserLimits() error {
	c.UserLimits = map[string]UserLimit{}
	raw, err := readJSONSetting("USER_LIMITS")
	if err != nil || raw == nil {
		return err
	}
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c.UserLimits); err != nil {
		return fmt.Errorf("USER_LIMITS is not valid: %w", err)
	}
	var errs []error
	for id, limit := range c.UserLimits {
		if !isSnowflake(id) {
			errs = append(errs, fmt.Errorf("USER_LIMITS: %q is not a Discord user ID", id))
		}
		for _, v := range []*int{limit.QuestionsPerHour, limit.IssuesPerDay} {
			if v != nil && *v < 0 {
				errs = append(errs, fmt.Errorf("USER_LIMITS: limits for %s must be 0 (no limit) or more", id))
			}
		}
	}
	return errors.Join(errs...)
}

// parseReadableChannels reads READABLE_CHANNELS: a JSON array of the extra
// channels the model may read.
func (c *Config) parseReadableChannels() error {
	raw, err := readJSONSetting("READABLE_CHANNELS")
	if err != nil || raw == nil {
		return err
	}
	var channels []ReadableChannel
	dec := json.NewDecoder(strings.NewReader(string(raw)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&channels); err != nil {
		return fmt.Errorf("READABLE_CHANNELS is not valid: %w", err)
	}
	var errs []error
	seen := map[string]bool{}
	for _, ch := range channels {
		ch.Name = strings.ToLower(strings.TrimSpace(ch.Name))
		switch {
		case ch.Name == "" || !isSnowflake(ch.ID):
			errs = append(errs, fmt.Errorf("READABLE_CHANNELS: each channel needs a name and a Discord channel id (got %q, %q)", ch.Name, ch.ID))
		case seen[ch.Name]:
			errs = append(errs, fmt.Errorf("READABLE_CHANNELS: duplicate name %q", ch.Name))
		default:
			seen[ch.Name] = true
			c.ReadableChannels = append(c.ReadableChannels, ch)
		}
	}
	return errors.Join(errs...)
}

// statsServers / queryServers list the servers with each capability, in
// configured order, for tool enums.
func (c *Config) statsServers() []string {
	var out []string
	for _, name := range c.ServerOrder {
		if c.Servers[name].StatsAPIURL != "" {
			out = append(out, name)
		}
	}
	return out
}

func (c *Config) queryServers() []string {
	var out []string
	for _, name := range c.ServerOrder {
		if c.Servers[name].QueryAddress != "" {
			out = append(out, name)
		}
	}
	return out
}
