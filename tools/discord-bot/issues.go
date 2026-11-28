package main

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/bradleyfalzon/ghinstallation/v2"
	ghinst "github.com/google/go-github/v88/github" // the version ghinstallation's token options use
	"github.com/google/go-github/v93/github"
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
	// Labels are the area and server labels the model chose; see
	// issuelabels.go. The kind's label and GITHUB_ISSUE_LABELS are added
	// when filing.
	Labels []string
	// Attachments are the reporter's images to include; see attachments.go.
	// Set by the bot, not the model.
	Attachments []AttachmentRef
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
	labelChoices []labelChoice
	// media holds the reporter's screenshots for filed issues; nil when
	// GITHUB_ATTACHMENTS_REPO is not set, and then drafts carry none.
	media MediaStore
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

	// Each token is limited to what its client needs, so granting the app
	// Contents access for screenshots doesn't extend to the issues repo.
	issuesTransport := ghinstallation.NewFromAppsTransport(appTransport, installationID)
	issuesTransport.InstallationTokenOptions = &ghinst.InstallationTokenOptions{
		Repositories: []string{cfg.GitHubRepo},
		Permissions:  &ghinst.InstallationPermissions{Issues: new("write"), Metadata: new("read")},
	}
	client, err := github.NewClient(clientOpts(issuesTransport)...)
	if err != nil {
		return nil, err
	}

	var media MediaStore
	if cfg.GitHubAttachmentsRepo != "" {
		owner, repo := cfg.GitHubAttachmentsOwner, cfg.GitHubAttachmentsRepo
		mediaInstallation := installationID
		if owner != cfg.GitHubOwner {
			appClient, err := github.NewClient(clientOpts(appTransport)...)
			if err != nil {
				return nil, err
			}
			installation, _, err := appClient.Apps.GetRepositoryInstallation(ctx, owner, repo)
			if err != nil {
				return nil, fmt.Errorf("finding the GitHub App's installation on %s/%s (is the app installed on that repository?): %w", owner, repo, err)
			}
			mediaInstallation = installation.GetID()
		}
		mediaTransport := ghinstallation.NewFromAppsTransport(appTransport, mediaInstallation)
		mediaTransport.InstallationTokenOptions = &ghinst.InstallationTokenOptions{
			Repositories: []string{repo},
			Permissions:  &ghinst.InstallationPermissions{Contents: new("write"), Metadata: new("read")},
		}
		mediaClient, err := github.NewClient(clientOpts(mediaTransport)...)
		if err != nil {
			return nil, err
		}
		// Fails fast if the app can't reach the repo, and finds the branch.
		r, _, err := mediaClient.Repositories.Get(ctx, owner, repo)
		if err != nil {
			return nil, fmt.Errorf("checking GITHUB_ATTACHMENTS_REPO %s/%s (is the app installed on it, with Contents: Read and write?): %w", owner, repo, err)
		}
		if r.GetPrivate() {
			return nil, fmt.Errorf("GITHUB_ATTACHMENTS_REPO %s/%s is private, so issues couldn't show its images", owner, repo)
		}
		branch := cfg.GitHubAttachmentsBranch
		if branch == "" {
			branch = r.GetDefaultBranch()
		}
		media = &githubMediaStore{client: mediaClient, owner: owner, repo: repo, branch: branch}
	}

	return &IssueTracker{
		media:        media,
		client:       client,
		owner:        cfg.GitHubOwner,
		repo:         cfg.GitHubRepo,
		labels:       cfg.IssueLabels,
		bugLabel:     cfg.BugLabel,
		featureLabel: cfg.FeatureLabel,
		labelChoices: issueLabelChoices(cfg),
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
		PerPage: 5,
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

// Create files the draft and returns the new issue's URL. threadLink is the
// Discord thread it came from. images are the draft's attachments already
// copied to the media store, and missing counts those that couldn't be. Issues are public, so the reporter is not
// named; the thread shows who it was to anyone in the Discord server, and the
// bot's log records their user ID with the issue URL.
func (t *IssueTracker) Create(ctx context.Context, draft IssueDraft, threadLink string, images []IssueImage, missing int) (string, error) {
	labels := append([]string{}, t.labels...)
	chosen, err := checkLabels(draft.Labels, t.labelChoices)
	if err != nil {
		return "", err
	}
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

	labels = append(labels, chosen...)

	body := strings.TrimSpace(draft.Body) + imagesSection(images, missing) + fmt.Sprintf(
		"\n\n---\n_Reported on Discord via the stats bot. Discussion: [Discord thread](%s)_", threadLink)

	issue, _, err := t.client.Issues.Create(ctx, t.owner, t.repo, github.CreateIssueRequest{
		Title:  draft.Title,
		Body:   new(body),
		Labels: labels,
	})
	if err != nil {
		return "", fmt.Errorf("creating GitHub issue: %w", err)
	}
	return issue.GetHTMLURL(), nil
}

// imagesSection embeds the reporter's screenshots after the issue body.
func imagesSection(images []IssueImage, missing int) string {
	if len(images) == 0 && missing == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("\n\n### Screenshots\n")
	for _, img := range images {
		fmt.Fprintf(&b, "\n![%s](%s)\n", img.Name, img.URL)
	}
	if missing > 0 {
		fmt.Fprintf(&b, "\n_%d more couldn't be copied here; see the Discord thread._\n", missing)
	}
	return strings.TrimRight(b.String(), "\n")
}
