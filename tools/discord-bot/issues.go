package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/bradleyfalzon/ghinstallation/v2"
	"github.com/google/go-github/v88/github"
)

// IssueKind is what a user is filing.
type IssueKind string

const (
	IssueBug     IssueKind = "bug"
	IssueFeature IssueKind = "feature"
)

// IssueDraft is an issue the model has written up, waiting for the reporter
// to confirm it in Discord. Nothing reaches GitHub until they do.
type IssueDraft struct {
	Kind  IssueKind
	Title string
	Body  string
}

// Limits keep a draft inside a single Discord embed (title 256, description
// 4096 characters) with room for the footer.
const (
	maxIssueTitle = 200
	maxIssueBody  = 3500
)

// IssueTracker searches and files issues in one GitHub repository.
type IssueTracker struct {
	client       *github.Client
	owner, repo  string
	labels       []string
	bugLabel     string
	featureLabel string
}

// NewIssueTracker authenticates as the GitHub App's installation on the
// repository, so issues are filed as "<app name>[bot]" rather than as a
// person. The installation is looked up from the repository unless it is
// configured, which also fails fast if the app is not installed there.
// ghinstallation mints and refreshes the short-lived installation tokens.
func NewIssueTracker(ctx context.Context, cfg *Config) (*IssueTracker, error) {
	appTransport, err := ghinstallation.NewAppsTransport(http.DefaultTransport, cfg.GitHubAppID, cfg.GitHubAppPrivateKey)
	if err != nil {
		return nil, fmt.Errorf("loading the GitHub App private key: %w", err)
	}

	clientOpts := func(transport http.RoundTripper) []github.ClientOptionsFunc {
		opts := []github.ClientOptionsFunc{github.WithTransport(transport), github.WithTimeout(15 * time.Second)}
		if cfg.githubAPIURL != "" {
			opts = append(opts, github.WithURLs(&cfg.githubAPIURL, &cfg.githubAPIURL))
		}
		return opts
	}
	if cfg.githubAPIURL != "" {
		appTransport.BaseURL = strings.TrimSuffix(cfg.githubAPIURL, "/")
	}

	installationID := cfg.GitHubInstallationID
	if installationID == 0 {
		appClient, err := github.NewClient(clientOpts(appTransport)...)
		if err != nil {
			return nil, err
		}
		installation, _, err := appClient.Apps.GetRepositoryInstallation(ctx, cfg.GitHubOwner, cfg.GitHubRepo)
		if err != nil {
			return nil, fmt.Errorf("finding the GitHub App's installation on %s/%s (is the app installed on that repository?): %w",
				cfg.GitHubOwner, cfg.GitHubRepo, err)
		}
		installationID = installation.GetID()
	}

	client, err := github.NewClient(clientOpts(ghinstallation.NewFromAppsTransport(appTransport, installationID))...)
	if err != nil {
		return nil, err
	}

	return &IssueTracker{
		client:       client,
		owner:        cfg.GitHubOwner,
		repo:         cfg.GitHubRepo,
		labels:       cfg.IssueLabels,
		bugLabel:     cfg.BugLabel,
		featureLabel: cfg.FeatureLabel,
	}, nil
}

// IssueSummary is one search hit, as the model sees it.
type IssueSummary struct {
	Number int    `json:"number"`
	Title  string `json:"title"`
	State  string `json:"state"`
	URL    string `json:"url"`
}

// Search returns up to five issues (open or closed) in the repository that
// match the query, so the model can point to an existing report instead of
// drafting a duplicate.
func (t *IssueTracker) Search(ctx context.Context, query string) ([]IssueSummary, error) {
	q := fmt.Sprintf("repo:%s/%s is:issue %s", t.owner, t.repo, query)
	result, _, err := t.client.Search.Issues(ctx, q, &github.SearchOptions{
		ListOptions: github.ListOptions{PerPage: 5},
	})
	if err != nil {
		return nil, fmt.Errorf("searching GitHub issues: %w", err)
	}
	out := []IssueSummary{}
	for _, issue := range result.Issues {
		out = append(out, IssueSummary{
			Number: issue.GetNumber(),
			Title:  issue.GetTitle(),
			State:  issue.GetState(),
			URL:    issue.GetHTMLURL(),
		})
	}
	return out, nil
}

// Reporter identifies who asked for the issue, for the issue body.
type Reporter struct {
	Username    string
	UserID      string
	MessageLink string
}

// Create files the draft and returns the new issue's URL.
func (t *IssueTracker) Create(ctx context.Context, draft IssueDraft, reporter Reporter) (string, error) {
	labels := append([]string{}, t.labels...)
	switch draft.Kind {
	case IssueBug:
		if t.bugLabel != "" {
			labels = append(labels, t.bugLabel)
		}
	case IssueFeature:
		if t.featureLabel != "" {
			labels = append(labels, t.featureLabel)
		}
	}

	body := strings.TrimSpace(draft.Body) + fmt.Sprintf(
		"\n\n---\n_Reported on Discord by %s (user ID %s) via the stats bot. [Conversation](%s)_",
		reporter.Username, reporter.UserID, reporter.MessageLink)

	issue, _, err := t.client.Issues.Create(ctx, t.owner, t.repo, &github.IssueRequest{
		Title:  github.Ptr(draft.Title),
		Body:   github.Ptr(body),
		Labels: &labels,
	})
	if err != nil {
		return "", fmt.Errorf("creating GitHub issue: %w", err)
	}
	return issue.GetHTMLURL(), nil
}
