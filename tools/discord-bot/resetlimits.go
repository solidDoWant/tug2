package main

import (
	"fmt"
	"log/slog"

	"github.com/bwmarrin/discordgo"
)

// /resetlimits gives one user their full question and issue limits back, for
// when the defaults are too low for someone on a given day. It only clears
// their recent counts: a standing change belongs in USER_LIMITS. Counts are
// in memory, like the limits themselves.
//
// Who can run it is up to Discord: by default members with Manage Server, and
// server admins can grant it to a role (e.g. a bot admin role) under Server
// Settings → Integrations. Discord enforces that before the interaction is
// sent, so the bot doesn't check again; checking for Manage Server here would
// undo a role grant made there.

const (
	resetLimitsCommand = "resetlimits"
	resetLimitsUser    = "user"
)

var manageGuild int64 = discordgo.PermissionManageGuild

var resetLimitsCommandDef = &discordgo.ApplicationCommand{
	Name:                     resetLimitsCommand,
	Description:              "Admins: give a user their full question and issue limits back",
	Contexts:                 &[]discordgo.InteractionContextType{discordgo.InteractionContextGuild},
	DefaultMemberPermissions: &manageGuild,
	Options: []*discordgo.ApplicationCommandOption{{
		Type:        discordgo.ApplicationCommandOptionUser,
		Name:        resetLimitsUser,
		Description: "Whose limits to reset",
		Required:    true,
	}},
}

func (b *Bot) onResetLimits(s *discordgo.Session, i *discordgo.InteractionCreate) {
	if i.Member == nil || i.Member.User == nil || i.GuildID == "" {
		return
	}
	admin := i.Member.User
	var targetID string
	for _, opt := range i.ApplicationCommandData().Options {
		if opt.Name == resetLimitsUser && opt.Type == discordgo.ApplicationCommandOptionUser {
			targetID = opt.UserValue(nil).ID // nil session: just the ID, no API call
		}
	}
	if targetID == "" {
		b.ephemeral(i, "Pick a user to reset.")
		return
	}

	questions, issues := b.limits.Reset(targetID)
	slog.Info("limits reset", "admin", admin.ID, "target", targetID, "questions_cleared", questions, "issues_cleared", issues)
	b.ephemeral(i, resetLimitsReply(targetID, questions, issues))
}

func resetLimitsReply(userID string, questions, issues int) string {
	return fmt.Sprintf("Reset <@%s>'s limits: cleared %s from the last hour and %s from the last 24 hours. Standing limits (USER_LIMITS) are unchanged.",
		userID, plural(questions, "question"), plural(issues, "issue"))
}
