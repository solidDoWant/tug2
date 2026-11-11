package main

import (
	"fmt"
	"log/slog"
	"strings"

	"github.com/bwmarrin/discordgo"
)

// /ask is the slash-command way to ask a question. Discord lists it in the "/"
// menu under the bot, so it's easier to find than the bot in the @ list.
//
// The command's response is a normal message from the bot holding the
// question, which Discord shows under "<user> used /ask". From there it is
// handled exactly like an @mention of that message: in the bot channel it
// starts a thread, in a thread of the bot channel it is answered there. When
// the history is rebuilt, asAsker turns that bot message back into the user's
// question.

const (
	askCommand        = "ask"
	askOption         = "question"
	maxAskQuestionLen = 1500
)

var askCommandDef = &discordgo.ApplicationCommand{
	Name:        askCommand,
	Description: "Ask the bot about stats or server status, or report a bug or request a feature",
	Contexts:    &[]discordgo.InteractionContextType{discordgo.InteractionContextGuild},
	Options: []*discordgo.ApplicationCommandOption{{
		Type:        discordgo.ApplicationCommandOptionString,
		Name:        askOption,
		Description: "What do you want to know?",
		Required:    true,
		MaxLength:   maxAskQuestionLen,
	}},
}

// registerCommands creates /ask in the guild that holds the bot channel, once
// per process. Guild commands appear immediately; a bulk overwrite is
// idempotent and removes commands the bot no longer has.
func (b *Bot) registerCommands(s *discordgo.Session, guildID string) {
	ch, err := s.State.Channel(b.cfg.ChannelID)
	if err != nil || ch.GuildID != guildID {
		return
	}
	b.mu.Lock()
	done := b.commandsRegistered
	b.commandsRegistered = true
	b.mu.Unlock()
	if done {
		return
	}

	appID := s.State.User.ID
	if s.State.Application != nil && s.State.Application.ID != "" {
		appID = s.State.Application.ID
	}
	if _, err := s.ApplicationCommandBulkOverwrite(appID, guildID, []*discordgo.ApplicationCommand{askCommandDef}); err != nil {
		slog.Warn("registering /ask (was the bot invited with the applications.commands scope?)", "guild", guildID, "err", err)
		b.mu.Lock()
		b.commandsRegistered = false
		b.mu.Unlock()
		return
	}
	slog.Info("registered slash commands", "guild", guildID, "commands", []string{"/" + askCommand})
}

// onAsk handles /ask.
func (b *Bot) onAsk(s *discordgo.Session, i *discordgo.InteractionCreate) {
	user := i.User
	if i.Member != nil {
		user = i.Member.User
	}
	if user == nil || i.GuildID == "" {
		return
	}

	var question string
	for _, opt := range i.ApplicationCommandData().Options {
		if opt.Name == askOption {
			question = strings.TrimSpace(opt.StringValue())
		}
	}
	if question == "" {
		b.ephemeral(i, "Add a question, e.g. `/ask question: who has the most kills on main?`")
		return
	}

	// Same places as an @mention: the bot channel, or a thread in it.
	var ch *discordgo.Channel
	if i.ChannelID != b.cfg.ChannelID {
		ch, _ = b.channel(i.ChannelID)
	}
	threadID, ok := route(b.cfg.ChannelID, s.State.User.ID, i.ChannelID, ch, true)
	if !ok {
		b.ephemeral(i, fmt.Sprintf("Ask me in <#%s>.", b.cfg.ChannelID))
		return
	}

	if !b.startQuestion(user.ID) {
		b.metrics.Question(outcomeBusy)
		b.ephemeral(i, "I'm still working on your last question. One at a time, please!")
		return
	}
	started := false
	defer func() {
		if !started {
			b.finishQuestion(user.ID)
		}
	}()

	// Post the question publicly as the command's response, then treat that
	// message as the question.
	if err := s.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
		Type: discordgo.InteractionResponseChannelMessageWithSource,
		Data: &discordgo.InteractionResponseData{Content: question, AllowedMentions: noMentions},
	}); err != nil {
		slog.Error("responding to /ask", "err", err)
		return
	}
	msg, err := s.InteractionResponse(i.Interaction)
	if err != nil {
		slog.Error("fetching /ask response", "err", err)
		return
	}
	q := *msg
	q.Author = user
	q.Member = i.Member
	q.GuildID = i.GuildID // REST messages don't carry it

	started = true
	go func() {
		defer b.finishQuestion(user.ID)
		b.answer(&q, threadID)
	}()
}

// asAsker returns an /ask response as the question it holds: the same message
// with the user who ran the command as its author. Other messages come back
// unchanged. The bot's only command is /ask, so any slash-command message of
// its own is one.
func asAsker(m *discordgo.Message, botID string) *discordgo.Message {
	if m == nil || m.Author == nil || m.Author.ID != botID || m.Type != discordgo.MessageTypeChatInputCommand {
		return m
	}
	var user *discordgo.User
	var member *discordgo.Member
	switch {
	case m.InteractionMetadata != nil && m.InteractionMetadata.User != nil:
		user = m.InteractionMetadata.User
		if m.Interaction != nil {
			member = m.Interaction.Member
		}
	case m.Interaction != nil && m.Interaction.User != nil:
		user, member = m.Interaction.User, m.Interaction.Member
	default:
		return m
	}
	q := *m
	q.Author = user
	q.Member = member
	return &q
}

// isAsk reports whether a message is an /ask question (after asAsker).
func isAsk(m *discordgo.Message) bool {
	return m.Type == discordgo.MessageTypeChatInputCommand && m.Author != nil && !m.Author.Bot
}
