package main

import (
	"context"
	"fmt"
	"log/slog"
	"slices"
	"strings"

	"github.com/google/go-github/v88/github"
)

// Issues the bot files are labelled by kind (GITHUB_BUG_LABEL /
// GITHUB_FEATURE_LABEL), and the model also picks area and server labels from
// a fixed list, so maintainers (or agents) can select work with queries such
// as "label:bug label:server:test". The list is fixed, rather than whatever
// the model writes, so the names stay consistent and queryable. The reporter
// sees the labels on the draft before confirming it.

// labelChoice is a label the model may put on an issue it drafts.
type labelChoice struct {
	Name, Description, Color string
}

// areaLabels name the part of the project an issue is about. Balance changes
// are gameplay feature requests: kind says it's a change, area says where.
var areaLabels = []labelChoice{
	{"area:gameplay", "Weapons and balance, bots/AI, classes, game modes, in-game plugins and commands", "1d76db"},
	{"area:maps", "Map rotation and votes, custom/workshop maps and downloads", "0e8a16"},
	{"area:stats", "Player stats recording, the stats API and leaderboards", "5319e7"},
	{"area:discord-relay", "Game events and chat the servers post to Discord channels", "fbca04"},
	{"area:discord-bot", "This Discord stats and support bot", "b60205"},
}

// issueLabelChoices is the area labels plus one server label per configured
// game server ("server:main").
func issueLabelChoices(cfg *Config) []labelChoice {
	choices := slices.Clone(areaLabels)
	for _, name := range cfg.ServerOrder {
		choices = append(choices, labelChoice{
			Name:        "server:" + name,
			Description: "Seen on, or a change for, the " + name + " game server",
			Color:       "c5def5",
		})
	}
	return choices
}

func labelNames(choices []labelChoice) []string {
	names := make([]string, len(choices))
	for i, c := range choices {
		names[i] = c.Name
	}
	return names
}

// checkLabels validates labels against the choices and returns them
// deduplicated, in the choices' order.
func checkLabels(labels []string, choices []labelChoice) ([]string, error) {
	var out []string
	for _, c := range choices {
		if slices.Contains(labels, c.Name) {
			out = append(out, c.Name)
		}
	}
	for _, l := range labels {
		if !slices.Contains(out, l) {
			return nil, fmt.Errorf("unknown label %q; choose from %s", l, strings.Join(labelNames(choices), ", "))
		}
	}
	return out, nil
}

// EnsureLabels creates any of the bot's labels missing from the repository,
// with their descriptions, so they look intended on GitHub and filter
// cleanly. Existing labels are left as they are.
func (t *IssueTracker) EnsureLabels(ctx context.Context) error {
	have := map[string]bool{}
	for l, err := range t.client.Issues.ListLabelsIter(ctx, t.owner, t.repo, &github.ListOptions{PerPage: 100}) {
		if err != nil {
			return fmt.Errorf("listing labels: %w", err)
		}
		have[strings.ToLower(l.GetName())] = true
	}
	for _, c := range t.labelChoices {
		if have[strings.ToLower(c.Name)] {
			continue
		}
		if _, _, err := t.client.Issues.CreateLabel(ctx, t.owner, t.repo, &github.Label{
			Name: github.Ptr(c.Name), Description: github.Ptr(c.Description), Color: github.Ptr(c.Color),
		}); err != nil {
			return fmt.Errorf("creating label %s: %w", c.Name, err)
		}
		slog.Info("created GitHub label", "label", c.Name)
	}
	return nil
}

// describeLabels lists the choices with their meanings, for the model.
func describeLabels(choices []labelChoice) string {
	parts := make([]string, len(choices))
	for i, c := range choices {
		parts[i] = c.Name + " (" + c.Description + ")"
	}
	return strings.Join(parts, "; ")
}
