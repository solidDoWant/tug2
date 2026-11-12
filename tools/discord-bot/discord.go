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

	mu                 sync.Mutex
	inFlight           map[string]bool // users with a question being answered
	commandsRegistered bool            // /ask is registered in the bot channel's guild

	// nicks caches server nicknames by user ID; see authorName.
	nicks *nickCache
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
		nicks:    newNickCache(),
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
		b.registerCommands(s, g.ID)
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

// channelName is a channel's name from the state cache, or "" if unknown.
// Cache only, so the same history renders the same way on every turn.
func (b *Bot) channelName(id string) string {
	if ch, err := b.session.State.Channel(id); err == nil {
		return ch.Name
	}
	return ""
}

func (b *Bot) mentionsMe(m *discordgo.Message) bool {
	return addressesBot(m, b.session.State.User.ID)
}

// addressesBot reports whether a message is meant for the bot: it @mentions
// the bot, or it is a Discord reply to one of the bot's messages. A reply with
// its ping switched off doesn't list the bot in Mentions, so replies are
// checked separately.
func addressesBot(m *discordgo.Message, botID string) bool {
	if slices.ContainsFunc(m.Mentions, func(u *discordgo.User) bool { return u.ID == botID }) {
		return true
	}
	ref := m.ReferencedMessage
	return m.Type == discordgo.MessageTypeReply && ref != nil && ref.Author != nil && ref.Author.ID == botID
}

// onMessage answers an @mention or reply to the bot in the configured channel
// by starting a thread, any message in a thread the bot started there, and an
// @mention or reply to the bot in a thread someone else started there.
func (b *Bot) onMessage(s *discordgo.Session, m *discordgo.MessageCreate) {
	if m.Author == nil || m.Author.Bot || m.GuildID == "" {
		return
	}

	var ch *discordgo.Channel
	if m.ChannelID != b.cfg.ChannelID {
		var err error
		if ch, err = b.channel(m.ChannelID); err != nil {
			return
		}
	}
	threadID, ok := route(b.cfg.ChannelID, s.State.User.ID, m.ChannelID, ch, b.mentionsMe(m.Message))
	if !ok {
		return
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

// route decides whether a message gets an answer and in which thread. ch is
// the message's channel, nil when it is the bot channel itself. mentioned
// means the message is addressed to the bot: an @mention or a reply to it. In
// the bot channel it answers those in a new thread (threadID ""). In a thread
// of the bot channel it answers every message if the bot started the thread,
// and only those addressed to it if someone else did, since people may be
// talking among themselves there. Elsewhere it ignores the message.
func route(botChannelID, botUserID, channelID string, ch *discordgo.Channel, mentioned bool) (threadID string, ok bool) {
	if channelID == botChannelID {
		return "", mentioned
	}
	if ch == nil || !ch.IsThread() || ch.ParentID != botChannelID {
		return "", false
	}
	return ch.ID, ch.OwnerID == botUserID || mentioned
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
	// message identifies the request in the logs; thread is added once known.
	log := slog.With("message", m.ID, "user", m.Author.ID)
	if ok, wait := b.limits.AllowQuestion(m.Author.ID); !ok {
		b.metrics.Question(outcomeRateLimited)
		limit, _ := b.limits.limitsFor(m.Author.ID)
		log.Info("rate limited", "kind", "question", "limit", limit, "retry_in", wait.Round(time.Second).String())
		b.replyTo(m, threadID, questionLimitMessage(limit, wait))
		return
	}

	// A new conversation gets its own thread, named after the question; the
	// model renames it once it has read the question (see retitle).
	newThread := threadID == ""
	if newThread {
		thread, err := b.session.MessageThreadStartComplex(m.ChannelID, m.ID, &discordgo.ThreadStart{
			Name:                threadName(b.cleanContent(m)),
			AutoArchiveDuration: b.cfg.ThreadArchiveMinutes,
		})
		if err != nil {
			log.Error("starting thread", "err", err)
			b.replyTo(m, "", "Sorry, I couldn't start a thread for that.")
			return
		}
		threadID = thread.ID
	}
	log = log.With("thread", threadID)

	select {
	case b.busy <- struct{}{}:
		defer func() { <-b.busy }()
	case <-b.ctx.Done():
		return
	}

	ctx, cancel := context.WithTimeout(withLogger(b.ctx, log), 3*time.Minute)
	defer cancel()
	stopTyping := b.keepTyping(ctx, threadID)
	defer stopTyping()

	history, err := b.history(threadID)
	if err != nil {
		log.Error("reading thread history", "err", err)
		b.replyTo(m, threadID, "Sorry, I couldn't read this thread.")
		return
	}

	if newThread && b.cfg.ThreadTitles {
		go b.retitle(log, threadID, history)
	}

	start := time.Now()
	done := b.metrics.QuestionStarted()
	ans, err := b.agent.Answer(ctx, m.GuildID, history)
	done()
	b.metrics.QuestionFinished(time.Since(start), ans.Tokens)
	log.Info("answered",
		"duration_ms", time.Since(start).Milliseconds(), "tokens", ans.Tokens,
		"limit", ans.Limit, "draft", ans.Draft != nil, "error", errString(err))
	declined := err == nil && ans.Draft == nil && strings.TrimSpace(ans.Text) == noReplyMarker
	addressed := b.mentionsMe(m) || isAsk(m)
	switch {
	case err != nil:
		b.metrics.Question(outcomeError)
	case declined && !addressed:
		b.metrics.Question(outcomeSilent)
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
	if declined {
		if !addressed {
			// Talk among others in the thread: say nothing, and don't
			// count it against the poster's questions.
			b.limits.RefundQuestion(m.Author.ID)
			log.Info("not addressed to the bot; staying silent")
			return
		}
		log.Warn("model chose not to reply to a message addressed to it")
		ans.Text = "Did you mean to ask me something? I'm not sure what you'd like me to do."
	}
	b.sendAnswer(log, threadID, m.Author.ID, ans)
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

// authorName is the name the server shows for a message's author. Messages
// fetched over REST (the whole thread history) carry no member object, so
// their author's server nickname is looked up separately; without it a
// "discordname [SteamName]" nickname would show as just the account name.
func (b *Bot) authorName(guildID string, m *discordgo.Message) string {
	if m.Member == nil && guildID != "" {
		if nick, ok := b.nicks.get(guildID, m.Author.ID, b.lookupMember); ok && nick != "" {
			return nick
		}
	}
	return displayName(m)
}

// lookupMember fetches a member from the gateway state, or else over REST.
func (b *Bot) lookupMember(guildID, userID string) (*discordgo.Member, error) {
	if member, err := b.session.State.Member(guildID, userID); err == nil {
		return member, nil
	}
	return b.session.GuildMember(guildID, userID)
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

	me := b.session.State.User.ID
	var msgs []*discordgo.Message
	if starter, err := b.session.ChannelMessage(thread.ParentID, threadID); err == nil {
		starter = asAsker(starter, me)
		// What the first message builds on, e.g. a forward posted just
		// before "@bot this isn't rendering properly".
		var before []*discordgo.Message
		if prev, err := b.session.ChannelMessages(thread.ParentID, maxLeadIn, threadID, "", ""); err == nil {
			for _, m := range prev {
				before = append(before, asAsker(m, me))
			}
		} else {
			slog.Warn("reading messages before thread start", "thread", threadID, "err", err)
		}
		msgs = append(msgs, leadIn(starter, before, me)...)
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
	for _, m := range recent {
		msgs = append(msgs, asAsker(m, me))
	}

	var turns []Turn
	for _, m := range msgs {
		if m.Author == nil || (m.Type != discordgo.MessageTypeDefault && m.Type != discordgo.MessageTypeReply && !isAsk(m)) {
			continue
		}
		if m.Author.ID == me {
			turns = append(turns, Turn{FromBot: true, Text: botMessageText(m)})
			continue
		}
		if m.Author.Bot {
			continue
		}
		turns = append(turns, Turn{Author: b.authorName(thread.GuildID, m), Text: withForwarded(b.cleanContent(m), m, b.channelName), Posted: m.Timestamp,
			ToBot: addressesBot(m, me) || isAsk(m)})
	}
	return turns, nil
}

// Bounds on the messages before a thread's first message that count as part of
// it.
const (
	maxLeadIn = 5
	leadInGap = 5 * time.Minute
)

// leadIn returns the context a thread's first message builds on, oldest first:
// the message it replies to, and the run of messages its author posted just
// before it (each within leadInGap of the next), such as a forward followed by
// "@bot what's wrong with this?". before is the parent channel's messages
// preceding the starter, newest first (with /ask responses already turned
// into their askers' questions). The run stops at anyone else's message and
// at a message addressed to the bot (an @mention, a reply to it or an /ask),
// which is a question of its own.
func leadIn(starter *discordgo.Message, before []*discordgo.Message, botID string) []*discordgo.Message {
	var run []*discordgo.Message
	next := starter.Timestamp
	for _, m := range before {
		if m.Author == nil || starter.Author == nil || m.Author.ID != starter.Author.ID ||
			next.Sub(m.Timestamp) > leadInGap ||
			addressesBot(m, botID) || isAsk(m) {
			break
		}
		run = append(run, m)
		next = m.Timestamp
	}
	slices.Reverse(run)

	if ref := starter.ReferencedMessage; ref != nil && starter.Type == discordgo.MessageTypeReply &&
		!slices.ContainsFunc(run, func(m *discordgo.Message) bool { return m.ID == ref.ID }) {
		run = append([]*discordgo.Message{ref}, run...)
	}
	return run
}

// botMessageText is what the model sees of one of the bot's own messages,
// including the state of any issue draft it carries.
func botMessageText(m *discordgo.Message) string {
	text := m.Content
	for _, e := range m.Embeds {
		if e.Footer == nil {
			continue
		}
		switch {
		case strings.HasPrefix(e.Footer.Text, draftFooterPrefix):
			text += fmt.Sprintf("\n[Issue draft %q: %s]", e.Title, strings.TrimPrefix(e.Footer.Text, draftFooterPrefix))
		case strings.HasPrefix(e.Footer.Text, filedFooterPrefix):
			text += fmt.Sprintf("\n[Issue %q: filed as %s]", e.Title, e.URL)
		}
	}
	return strings.TrimSpace(text)
}

// sendAnswer posts the reply, split to Discord's message limit, with any issue
// draft and its buttons attached to the last part.
func (b *Bot) sendAnswer(log *slog.Logger, threadID, userID string, ans Answer) {
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
			log.Error("sending answer", "err", err)
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
	filedFooterPrefix = "Filed on GitHub · "
	confirmPrefix     = "issue_confirm"
	cancelPrefix      = "issue_cancel"
)

func kindLabel(kind IssueKind) string {
	if kind == IssueFeature {
		return "Feature request"
	}
	return "Bug report"
}

// draftEmbed renders a draft in a state such as "awaiting confirmation".
func draftEmbed(d IssueDraft, state string) *discordgo.MessageEmbed {
	color := 0xd73a4a // GitHub's bug red
	if d.Kind == IssueFeature {
		color = 0xa2eeef
	}
	embed := &discordgo.MessageEmbed{
		Author:      &discordgo.MessageEmbedAuthor{Name: kindLabel(d.Kind)},
		Title:       d.Title,
		Description: d.Body,
		Color:       color,
		Footer:      &discordgo.MessageEmbedFooter{Text: draftFooterPrefix + state},
	}
	if len(d.Labels) > 0 {
		embed.Fields = []*discordgo.MessageEmbedField{{Name: draftLabelsField, Value: "`" + strings.Join(d.Labels, "` `") + "`"}}
	}
	return embed
}

// draftLabelsField is the embed field that shows, and carries, a draft's
// labels: the draft lives only in its message until it is confirmed.
const draftLabelsField = "Labels"

// draftLabels reads the labels back from a draft's embed. Create checks them
// against the allowed labels.
func draftLabels(embed *discordgo.MessageEmbed) []string {
	for _, f := range embed.Fields {
		if f.Name == draftLabelsField {
			return strings.Fields(strings.ReplaceAll(f.Value, "`", " "))
		}
	}
	return nil
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
	if i.Type == discordgo.InteractionApplicationCommand {
		switch i.ApplicationCommandData().Name {
		case askCommand:
			b.onAsk(s, i)
		case resetLimitsCommand:
			b.onResetLimits(s, i)
		}
		return
	}
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
	draft := IssueDraft{Kind: IssueKind(kind), Title: embed.Title, Body: embed.Description, Labels: draftLabels(embed)}

	if action == cancelPrefix {
		b.metrics.Issue(draft.Kind, "cancelled")
		b.updateDraft(i, draftEmbed(draft, "cancelled"))
		return
	}

	if b.issues == nil {
		b.ephemeral(i, "Issue filing isn't configured right now.")
		return
	}
	if ok, wait := b.limits.AllowIssue(user.ID); !ok {
		b.metrics.Issue(draft.Kind, "rate_limited")
		_, limit := b.limits.limitsFor(user.ID)
		slog.Info("rate limited", "kind", "issue", "user", user.ID, "limit", limit, "retry_in", wait.Round(time.Second).String())
		b.ephemeral(i, issueLimitMessage(limit, wait))
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
	// Drafts are only posted in threads, so this links the whole conversation.
	link := fmt.Sprintf("https://discord.com/channels/%s/%s", i.GuildID, i.ChannelID)
	issueURL, err := b.issues.Create(ctx, draft, link)
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
	b.editDraft(i, filedEmbed(draft, issueURL))

	// Announce it separately too, as a reply to the draft, so the link is easy
	// to find and the model sees in the history that it was filed.
	if _, err := s.ChannelMessageSendComplex(i.ChannelID, &discordgo.MessageSend{
		Content:         filedMessage(issueURL),
		Reference:       &discordgo.MessageReference{MessageID: i.Message.ID, ChannelID: i.ChannelID, GuildID: i.GuildID},
		AllowedMentions: noMentions,
	}); err != nil {
		slog.Error("announcing filed issue", "url", issueURL, "err", err)
	}
}

// filedEmbed is a filed issue: the title links to it and the footer says so.
// An embed footer can't hold a link, so the URL goes on the title.
func filedEmbed(d IssueDraft, url string) *discordgo.MessageEmbed {
	e := draftEmbed(d, "")
	e.URL = url
	e.Footer.Text = filedFooterPrefix + issueRef(url)
	return e
}

// issueRef is "#4" for an issue URL ending in /issues/4.
func issueRef(url string) string {
	if i := strings.LastIndex(url, "/"); i >= 0 && i < len(url)-1 {
		return "#" + url[i+1:]
	}
	return url
}

func filedMessage(url string) string {
	return fmt.Sprintf("Filed as issue %s: %s", issueRef(url), url)
}

// updateDraft responds to the click by rewriting the draft message in place.
func (b *Bot) updateDraft(i *discordgo.InteractionCreate, embed *discordgo.MessageEmbed) {
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
func (b *Bot) editDraft(i *discordgo.InteractionCreate, embed *discordgo.MessageEmbed) {
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
