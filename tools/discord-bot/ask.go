package main

import (
	"log/slog"
	"slices"
	"strings"

	"github.com/bwmarrin/discordgo"
)

// /ask is the slash-command way to ask a question. Discord lists it in the "/"
// menu under the bot, so it's easier to find than the bot in the @ list.
//
// The command's response is a normal message from the bot holding the
// question, which Discord shows under "<user> used /ask". From there it is
// handled exactly like an @mention of that message: in a bot channel it
// starts a thread, in a thread of a bot channel it is answered there. When
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

// registerCommands creates /ask and /resetlimits in a guild that holds a bot
// channel, once per guild per process. Bot channels may be spread over
// several guilds; each gets the commands. Guild commands appear immediately;
// a bulk overwrite is idempotent and removes commands the bot no longer has.
func (b *Bot) registerCommands(s *discordgo.Session, guildID string) {
	if len(botChannelsIn(s, b.cfg.ChannelIDs, guildID)) == 0 {
		return
	}
	b.mu.Lock()
	done := b.commandsRegistered[guildID]
	b.commandsRegistered[guildID] = true
	b.mu.Unlock()
	if done {
		return
	}

	appID := s.State.User.ID
	if s.State.Application != nil && s.State.Application.ID != "" {
		appID = s.State.Application.ID
	}
	if _, err := s.ApplicationCommandBulkOverwrite(appID, guildID, []*discordgo.ApplicationCommand{askCommandDef, resetLimitsCommandDef}); err != nil {
		slog.Warn("registering slash commands (was the bot invited with the applications.commands scope?)", "guild", guildID, "err", err)
		b.mu.Lock()
		delete(b.commandsRegistered, guildID)
		b.mu.Unlock()
		return
	}
	slog.Info("registered slash commands", "guild", guildID, "commands", []string{"/" + askCommand, "/" + resetLimitsCommand})
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

	// Same places as an @mention: a bot channel, or a thread in one.
	var ch *discordgo.Channel
	if !slices.Contains(b.cfg.ChannelIDs, i.ChannelID) {
		ch, _ = b.channel(i.ChannelID)
	}
	threadID, ok := route(b.cfg.ChannelIDs, s.State.User.ID, i.ChannelID, ch, true)
	if !ok {
		b.ephemeral(i, askElsewhereMessage(botChannelsIn(s, b.cfg.ChannelIDs, i.GuildID)))
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

// botChannelsIn returns the bot channels that are in a guild, as far as the
// state cache knows.
func botChannelsIn(s *discordgo.Session, ids []string, guildID string) []string {
	var in []string
	for _, id := range ids {
		if ch, err := s.State.Channel(id); err == nil && ch.GuildID == guildID {
			in = append(in, id)
		}
	}
	return in
}

// askElsewhereMessage points someone who used /ask outside the bot channels
// to the ones in their server.
func askElsewhereMessage(ids []string) string {
	if len(ids) == 0 {
		return "I only answer in my own channels, and there are none in this server."
	}
	links := make([]string, len(ids))
	for i, id := range ids {
		links[i] = "<#" + id + ">"
	}
	if len(links) == 1 {
		return "Ask me in " + links[0] + "."
	}
	return "Ask me in " + strings.Join(links[:len(links)-1], ", ") + " or " + links[len(links)-1] + "."
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
