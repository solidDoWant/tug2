package main

import (
	"context"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/bwmarrin/discordgo"
)

// Bot connects Discord to the agent.
type Bot struct {
	cfg      *Config
	session  *discordgo.Session
	agent    *Agent
	issues   *IssueTracker // nil when issue filing is not configured
	limits   *RateLimiter
	channels *DiscordChannels
	busy     chan struct{} // global concurrency slots
	metrics  *Metrics

	// ctx is cancelled on shutdown so in-flight answers stop promptly.
	ctx context.Context

	mu       sync.Mutex
	inFlight map[string]bool // users with a question being answered
}

// NewSession creates the Discord session shared by the bot and the
// read_channel tool. MessageContent is privileged: it is what lets the bot
// read follow-ups in its threads that don't mention it, and other channels'
// text. Enable it in the developer portal.
func NewSession(token string) (*discordgo.Session, error) {
	session, err := discordgo.New("Bot " + token)
	if err != nil {
		return nil, fmt.Errorf("creating Discord session: %w", err)
	}
	session.Identify.Intents = discordgo.IntentsGuilds | discordgo.IntentsGuildMessages | discordgo.IntentMessageContent
	return session, nil
}

func NewBot(ctx context.Context, cfg *Config, session *discordgo.Session, agent *Agent, issues *IssueTracker, metrics *Metrics, channels *DiscordChannels) *Bot {
	b := &Bot{
		cfg:      cfg,
		session:  session,
		agent:    agent,
		issues:   issues,
		limits:   NewRateLimiter(cfg.QuestionsPerHour, cfg.IssuesPerDay, cfg.UserLimits),
		busy:     make(chan struct{}, cfg.MaxConcurrent),
		metrics:  metrics,
		channels: channels,
		ctx:      ctx,
		inFlight: map[string]bool{},
	}
	session.AddHandler(b.onMessage)
	session.AddHandler(b.onInteraction)
	session.AddHandler(func(s *discordgo.Session, _ *discordgo.Connect) {
		metrics.DiscordConnection("connect", true)
	})
	session.AddHandler(func(s *discordgo.Session, _ *discordgo.Disconnect) {
		slog.Warn("disconnected from Discord")
		metrics.DiscordConnection("disconnect", false)
	})
	session.AddHandler(func(s *discordgo.Session, _ *discordgo.Resumed) {
		metrics.DiscordConnection("resume", true)
	})
	// Log which channels the model can read once each guild's data has
	// arrived (after Ready), so access is easy to check from the logs.
	session.AddHandler(func(s *discordgo.Session, g *discordgo.GuildCreate) {
		chans, err := b.channels.Readable(g.ID)
		if err != nil {
			slog.Warn("listing readable channels", "guild", g.ID, "err", err)
			return
		}
		names := make([]string, 0, len(chans))
		for _, ch := range chans {
			names = append(names, "#"+ch.Name)
		}
		slog.Info("readable channels", "guild", g.ID, "count", len(chans), "channels", names)
	})
	session.AddHandler(func(s *discordgo.Session, r *discordgo.Ready) {
		slog.Info("connected to Discord", "user", r.User.Username, "guilds", len(r.Guilds))
	})
	return b
}

func (b *Bot) Open() error  { return b.session.Open() }
func (b *Bot) Close() error { return b.session.Close() }

// Ready reports whether the gateway connection is up, for the readiness probe.
func (b *Bot) Ready() bool { return b.session.DataReady }

// noMentions stops replies from pinging anyone, whatever the text contains.
var noMentions = &discordgo.MessageAllowedMentions{Parse: []discordgo.AllowedMentionType{}}

// channel looks a channel up in the state cache, falling back to the API
// (threads the bot has not seen since starting are not cached).
func (b *Bot) channel(id string) (*discordgo.Channel, error) {
	if ch, err := b.session.State.Channel(id); err == nil {
		return ch, nil
	}
	return b.session.Channel(id)
}

func (b *Bot) mentionsMe(m *discordgo.Message) bool {
	me := b.session.State.User.ID
	return slices.ContainsFunc(m.Mentions, func(u *discordgo.User) bool { return u.ID == me })
}

// onMessage answers an @mention in the configured channel by starting a
// thread, and any message in a thread the bot started there.
func (b *Bot) onMessage(s *discordgo.Session, m *discordgo.MessageCreate) {
	if m.Author == nil || m.Author.Bot || m.GuildID == "" {
		return
	}

	var threadID string
	switch {
	case m.ChannelID == b.cfg.ChannelID:
		if !b.mentionsMe(m.Message) {
			return
		}
	default:
		ch, err := b.channel(m.ChannelID)
		if err != nil || !ch.IsThread() || ch.ParentID != b.cfg.ChannelID || ch.OwnerID != s.State.User.ID {
			return
		}
		threadID = ch.ID
	}

	userID := m.Author.ID
	if !b.startQuestion(userID) {
		b.metrics.Question(outcomeBusy)
		b.replyTo(m.Message, threadID, "I'm still working on your last question. One at a time, please!")
		return
	}

	go func() {
		defer b.finishQuestion(userID)
		b.answer(m.Message, threadID)
	}()
}

func (b *Bot) startQuestion(userID string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.inFlight[userID] {
		return false
	}
	b.inFlight[userID] = true
	return true
}

func (b *Bot) finishQuestion(userID string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.inFlight, userID)
}

// replyTo sends text in the thread when there is one, otherwise as a reply to
// the message in the channel.
func (b *Bot) replyTo(m *discordgo.Message, threadID, text string) {
	send := &discordgo.MessageSend{Content: text, AllowedMentions: noMentions}
	target := threadID
	if target == "" {
		target = m.ChannelID
		send.Reference = m.Reference()
	}
	if _, err := b.session.ChannelMessageSendComplex(target, send); err != nil {
		slog.Error("sending reply", "channel", target, "err", err)
	}
}

func (b *Bot) answer(m *discordgo.Message, threadID string) {
	if ok, wait := b.limits.AllowQuestion(m.Author.ID); !ok {
		b.metrics.Question(outcomeRateLimited)
		b.replyTo(m, threadID, fmt.Sprintf("You've hit the question limit. Try again in %s.", wait.Round(time.Minute)))
		return
	}

	// A new conversation gets its own thread, named after the question.
	if threadID == "" {
		thread, err := b.session.MessageThreadStartComplex(m.ChannelID, m.ID, &discordgo.ThreadStart{
			Name:                threadName(b.cleanContent(m)),
			AutoArchiveDuration: 1440,
		})
		if err != nil {
			slog.Error("starting thread", "err", err)
			b.replyTo(m, "", "Sorry, I couldn't start a thread for that.")
			return
		}
		threadID = thread.ID
	}

	select {
	case b.busy <- struct{}{}:
		defer func() { <-b.busy }()
	case <-b.ctx.Done():
		return
	}

	ctx, cancel := context.WithTimeout(b.ctx, 3*time.Minute)
	defer cancel()
	stopTyping := b.keepTyping(ctx, threadID)
	defer stopTyping()

	history, err := b.history(threadID)
	if err != nil {
		slog.Error("reading thread history", "thread", threadID, "err", err)
		b.replyTo(m, threadID, "Sorry, I couldn't read this thread.")
		return
	}

	start := time.Now()
	done := b.metrics.QuestionStarted()
	ans, err := b.agent.Answer(ctx, m.GuildID, history)
	done()
	b.metrics.QuestionFinished(time.Since(start), ans.Tokens)
	slog.Info("answered", "user", m.Author.ID, "thread", threadID,
		"duration_ms", time.Since(start).Milliseconds(), "tokens", ans.Tokens,
		"limit", ans.Limit, "draft", ans.Draft != nil, "error", errString(err))
	switch {
	case err != nil:
		b.metrics.Question(outcomeError)
	case ans.Refused:
		b.metrics.Question(outcomeRefused)
	case ans.Limit != "":
		b.metrics.Question(outcomeLimited)
		b.metrics.QuestionLimit(ans.Limit)
	default:
		b.metrics.Question(outcomeAnswered)
	}
	if ans.Draft != nil {
		b.metrics.Issue(ans.Draft.Kind, "drafted")
	}
	if err != nil {
		b.replyTo(m, threadID, "Sorry, something went wrong while answering. Try again in a bit.")
		return
	}
	stopTyping()
	b.sendAnswer(threadID, m.Author.ID, ans)
}

// keepTyping shows the typing indicator until stopped (it lasts ~10s per call).
func (b *Bot) keepTyping(ctx context.Context, channelID string) func() {
	ctx, cancel := context.WithCancel(ctx)
	go func() {
		ticker := time.NewTicker(8 * time.Second)
		defer ticker.Stop()
		for {
			_ = b.session.ChannelTyping(channelID)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	}()
	return cancel
}

func threadName(question string) string {
	name := strings.Join(strings.Fields(question), " ")
	if name == "" {
		name = "Question"
	}
	return truncate(name, 90)
}

// cleanContent is the message text with the bot's mention removed and other
// user, role and channel mentions turned into readable names.
func (b *Bot) cleanContent(m *discordgo.Message) string {
	content, err := m.ContentWithMoreMentionsReplaced(b.session)
	if err != nil {
		content = m.ContentWithMentionsReplaced()
	}
	me := b.session.State.User
	for _, mention := range []string{"@" + me.Username, "<@" + me.ID + ">", "<@!" + me.ID + ">"} {
		content = strings.ReplaceAll(content, mention, "")
	}
	return strings.TrimSpace(content)
}

func displayName(m *discordgo.Message) string {
	if m.Member != nil && m.Member.Nick != "" {
		return m.Member.Nick
	}
	if m.Author.GlobalName != "" {
		return m.Author.GlobalName
	}
	return m.Author.Username
}

// history returns the conversation in a bot thread, oldest first: the message
// that started the thread (it lives in the parent channel and shares the
// thread's ID), then the thread's messages.
func (b *Bot) history(threadID string) ([]Turn, error) {
	thread, err := b.channel(threadID)
	if err != nil {
		return nil, err
	}

	var msgs []*discordgo.Message
	if starter, err := b.session.ChannelMessage(thread.ParentID, threadID); err == nil {
		msgs = append(msgs, starter)
	}

	limit := b.cfg.HistoryMessages
	if limit <= 0 || limit > 100 {
		limit = 100
	}
	recent, err := b.session.ChannelMessages(threadID, limit, "", "", "")
	if err != nil {
		return nil, err
	}
	slices.Reverse(recent) // the API returns newest first
	msgs = append(msgs, recent...)

	me := b.session.State.User.ID
	var turns []Turn
	for _, m := range msgs {
		if m.Author == nil || (m.Type != discordgo.MessageTypeDefault && m.Type != discordgo.MessageTypeReply) {
			continue
		}
		if m.Author.ID == me {
			turns = append(turns, Turn{FromBot: true, Text: botMessageText(m)})
			continue
		}
		if m.Author.Bot {
			continue
		}
		turns = append(turns, Turn{Author: displayName(m), Text: b.cleanContent(m), Posted: m.Timestamp})
	}
	return turns, nil
}

// botMessageText is what the model sees of one of the bot's own messages,
// including the state of any issue draft it carries.
func botMessageText(m *discordgo.Message) string {
	text := m.Content
	for _, e := range m.Embeds {
		if e.Footer != nil && strings.HasPrefix(e.Footer.Text, draftFooterPrefix) {
			text += fmt.Sprintf("\n[Issue draft %q: %s]", e.Title, strings.TrimPrefix(e.Footer.Text, draftFooterPrefix))
		}
	}
	return strings.TrimSpace(text)
}

// sendAnswer posts the reply, split to Discord's message limit, with any issue
// draft and its buttons attached to the last part.
func (b *Bot) sendAnswer(threadID, userID string, ans Answer) {
	chunks := splitMessage(ans.Text, 1900)
	if len(chunks) == 0 {
		chunks = []string{""}
	}
	for i, chunk := range chunks {
		send := &discordgo.MessageSend{Content: chunk, AllowedMentions: noMentions}
		if i == len(chunks)-1 && ans.Draft != nil {
			send.Embeds = []*discordgo.MessageEmbed{draftEmbed(*ans.Draft, "awaiting confirmation")}
			send.Components = draftButtons(ans.Draft.Kind, userID, false)
		}
		if send.Content == "" && len(send.Embeds) == 0 {
			continue
		}
		if _, err := b.session.ChannelMessageSendComplex(threadID, send); err != nil {
			slog.Error("sending answer", "thread", threadID, "err", err)
			return
		}
	}
}

// splitMessage breaks text into chunks of at most max runes, preferring line
// breaks, and keeps ``` code blocks balanced across chunks.
func splitMessage(text string, max int) []string {
	text = strings.TrimSpace(text)
	var chunks []string
	for text != "" {
		r := []rune(text)
		if len(r) <= max {
			chunks = append(chunks, text)
			break
		}
		cut := max - 4 // room to close a code block
		if i := strings.LastIndex(string(r[:cut]), "\n"); i > max/2 {
			cut = len([]rune(string(r[:cut])[:i]))
		}
		chunk, rest := string(r[:cut]), strings.TrimLeft(string(r[cut:]), "\n")
		if strings.Count(chunk, "```")%2 == 1 {
			chunk += "\n```"
			rest = "```\n" + rest
		}
		chunks = append(chunks, chunk)
		text = rest
	}
	return chunks
}

// --- issue drafts ------------------------------------------------------------

// The draft lives in the message's embed (title = issue title, description =
// body), so confirming needs no server-side state and survives restarts.
const (
	draftFooterPrefix = "Issue draft · "
	confirmPrefix     = "issue_confirm"
	cancelPrefix      = "issue_cancel"
)

func kindLabel(kind IssueKind) string {
	if kind == IssueFeature {
		return "Feature request"
	}
	return "Bug report"
}

func draftEmbed(d IssueDraft, state string) *discordgo.MessageEmbed {
	color := 0xd73a4a // GitHub's bug red
	if d.Kind == IssueFeature {
		color = 0xa2eeef
	}
	return &discordgo.MessageEmbed{
		Author:      &discordgo.MessageEmbedAuthor{Name: kindLabel(d.Kind)},
		Title:       d.Title,
		Description: d.Body,
		Color:       color,
		Footer:      &discordgo.MessageEmbedFooter{Text: draftFooterPrefix + state},
	}
}

// draftButtons carry the kind and the reporter's ID, so only they can act.
func draftButtons(kind IssueKind, userID string, disabled bool) []discordgo.MessageComponent {
	return []discordgo.MessageComponent{discordgo.ActionsRow{Components: []discordgo.MessageComponent{
		discordgo.Button{
			Label: "Confirm and file", Style: discordgo.SuccessButton, Disabled: disabled,
			CustomID: fmt.Sprintf("%s:%s:%s", confirmPrefix, kind, userID),
		},
		discordgo.Button{
			Label: "Cancel", Style: discordgo.SecondaryButton, Disabled: disabled,
			CustomID: fmt.Sprintf("%s:%s:%s", cancelPrefix, kind, userID),
		},
	}}}
}

func (b *Bot) onInteraction(s *discordgo.Session, i *discordgo.InteractionCreate) {
	if i.Type != discordgo.InteractionMessageComponent || i.Message == nil {
		return
	}
	action, rest, _ := strings.Cut(i.MessageComponentData().CustomID, ":")
	kind, ownerID, _ := strings.Cut(rest, ":")
	if action != confirmPrefix && action != cancelPrefix {
		return
	}

	user := i.User
	if i.Member != nil {
		user = i.Member.User
	}
	if user == nil || user.ID != ownerID {
		b.ephemeral(i, "Only the person who asked for this draft can confirm or cancel it.")
		return
	}
	if len(i.Message.Embeds) == 0 {
		b.ephemeral(i, "This draft is missing its contents.")
		return
	}
	embed := i.Message.Embeds[0]
	draft := IssueDraft{Kind: IssueKind(kind), Title: embed.Title, Body: embed.Description}

	if action == cancelPrefix {
		b.metrics.Issue(draft.Kind, "cancelled")
		b.updateDraft(i, draft, "cancelled", nil)
		return
	}

	if b.issues == nil {
		b.ephemeral(i, "Issue filing isn't configured right now.")
		return
	}
	if ok, wait := b.limits.AllowIssue(user.ID); !ok {
		b.metrics.Issue(draft.Kind, "rate_limited")
		b.ephemeral(i, fmt.Sprintf("You've filed the maximum number of issues for today. Try again in %s.", wait.Round(time.Minute)))
		return
	}

	// Acknowledge within Discord's 3s window, then file and edit the message.
	if err := s.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
		Type: discordgo.InteractionResponseDeferredMessageUpdate,
	}); err != nil {
		slog.Error("acknowledging interaction", "err", err)
		return
	}
	// Lock the buttons first so a double click can't file twice.
	components := draftButtons(draft.Kind, ownerID, true)
	_, _ = s.InteractionResponseEdit(i.Interaction, &discordgo.WebhookEdit{Components: &components})

	ctx, cancel := context.WithTimeout(b.ctx, 30*time.Second)
	defer cancel()
	link := fmt.Sprintf("https://discord.com/channels/%s/%s/%s", i.GuildID, i.ChannelID, i.Message.ID)
	issueURL, err := b.issues.Create(ctx, draft, Reporter{Username: user.Username, UserID: user.ID, MessageLink: link})
	if err != nil {
		slog.Error("filing issue", "user", user.ID, "err", err)
		b.metrics.Issue(draft.Kind, "failed")
		b.limits.RefundIssue(user.ID)
		enabled := draftButtons(draft.Kind, ownerID, false)
		_, _ = s.InteractionResponseEdit(i.Interaction, &discordgo.WebhookEdit{Components: &enabled})
		_, _ = s.FollowupMessageCreate(i.Interaction, true, &discordgo.WebhookParams{
			Content: "Filing failed; please try again in a bit.", Flags: discordgo.MessageFlagsEphemeral,
		})
		return
	}
	slog.Info("filed issue", "user", user.ID, "url", issueURL)
	b.metrics.Issue(draft.Kind, "filed")
	b.editDraft(i, draft, "filed: "+issueURL, &issueURL)
}

// updateDraft responds to the click by rewriting the draft message in place.
func (b *Bot) updateDraft(i *discordgo.InteractionCreate, draft IssueDraft, state string, url *string) {
	embed := draftEmbed(draft, state)
	if url != nil {
		embed.URL = *url
	}
	err := b.session.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
		Type: discordgo.InteractionResponseUpdateMessage,
		Data: &discordgo.InteractionResponseData{
			Embeds:          []*discordgo.MessageEmbed{embed},
			Components:      []discordgo.MessageComponent{},
			AllowedMentions: noMentions,
		},
	})
	if err != nil {
		slog.Error("updating draft", "err", err)
	}
}

// editDraft edits an already-acknowledged draft message.
func (b *Bot) editDraft(i *discordgo.InteractionCreate, draft IssueDraft, state string, url *string) {
	embed := draftEmbed(draft, state)
	if url != nil {
		embed.URL = *url
	}
	embeds := []*discordgo.MessageEmbed{embed}
	components := []discordgo.MessageComponent{}
	if _, err := b.session.InteractionResponseEdit(i.Interaction, &discordgo.WebhookEdit{
		Embeds: &embeds, Components: &components,
	}); err != nil {
		slog.Error("editing draft", "err", err)
	}
}

func (b *Bot) ephemeral(i *discordgo.InteractionCreate, text string) {
	_ = b.session.InteractionRespond(i.Interaction, &discordgo.InteractionResponse{
		Type: discordgo.InteractionResponseChannelMessageWithSource,
		Data: &discordgo.InteractionResponseData{Content: text, Flags: discordgo.MessageFlagsEphemeral, AllowedMentions: noMentions},
	})
}
