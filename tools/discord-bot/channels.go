package main

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/bwmarrin/discordgo"
)

// messageReader is the part of the Discord session that reads messages.
type messageReader interface {
	ChannelMessages(channelID string, limit int, beforeID, afterID, aroundID string, options ...discordgo.RequestOption) ([]*discordgo.Message, error)
}

// channelSource lists the channels the model may read and reads them.
type channelSource interface {
	messageReader
	Readable(guildID string) ([]ReadableChannel, error)
}

// ReadableChannel is a channel the model may read, as list_channels shows it.
type ReadableChannel struct {
	Name     string `json:"name"`
	ID       string `json:"id"`
	Category string `json:"category,omitempty"`
	// Description is the configured description, else the channel's topic.
	Description string `json:"description,omitempty"`
}

// readPermissions are what the bot needs in a channel to read its history.
const readPermissions = discordgo.PermissionViewChannel | discordgo.PermissionReadMessageHistory

// DiscordChannels discovers readable channels from Discord: every text or
// announcement channel in the guild where the bot has View Channel and Read
// Message History, except the bot's own question channel. Access is decided
// by Discord permissions alone, so granting or revoking the bot's access to a
// channel takes effect immediately with no configuration change.
type DiscordChannels struct {
	session      *discordgo.Session
	botChannelID string
	descriptions map[string]string
	// refreshMember re-fetches the bot's roles before each listing (off in
	// tests, which have no API to call).
	refreshMember bool
}

func (d *DiscordChannels) ChannelMessages(channelID string, limit int, beforeID, afterID, aroundID string, options ...discordgo.RequestOption) ([]*discordgo.Message, error) {
	return d.session.ChannelMessages(channelID, limit, beforeID, afterID, aroundID, options...)
}

// Readable lists the channels the bot can read in a guild, sorted the way
// Discord shows them. It works from the gateway's cached guild state (the bot
// receives its own roles and every channel's permission overrides on
// connect), falling back to the API only for anything not cached.
func (d *DiscordChannels) Readable(guildID string) ([]ReadableChannel, error) {
	if guildID == "" {
		return nil, errors.New("no server to list channels for")
	}
	var all []*discordgo.Channel
	if g, err := d.session.State.Guild(guildID); err == nil && len(g.Channels) > 0 {
		all = g.Channels
	} else {
		fetched, err := d.session.GuildChannels(guildID)
		if err != nil {
			return nil, fmt.Errorf("listing channels: %w", err)
		}
		all = fetched
	}

	categories := map[string]*discordgo.Channel{}
	for _, ch := range all {
		if ch.Type == discordgo.ChannelTypeGuildCategory {
			categories[ch.ID] = ch
		}
	}

	me := d.session.State.User.ID
	// Refresh the bot's own member (its roles) first: without the privileged
	// members intent Discord may not send updates when the bot is given a new
	// role, and that is a common way to grant it access. One API call; on
	// failure the cached roles are used.
	if d.refreshMember {
		if member, err := d.session.GuildMember(guildID, me); err == nil {
			member.GuildID = guildID
			_ = d.session.State.MemberAdd(member)
		}
	}

	var readable []*discordgo.Channel
	for _, ch := range all {
		if ch.Type != discordgo.ChannelTypeGuildText && ch.Type != discordgo.ChannelTypeGuildNews {
			continue
		}
		if ch.ID == d.botChannelID {
			continue // its own Q&A channel: other people's questions, not information
		}
		perms, err := d.session.State.UserChannelPermissions(me, ch.ID)
		if err != nil {
			perms, err = d.session.UserChannelPermissions(me, ch.ID) //nolint:staticcheck // falls back to the API when state is incomplete
		}
		if err != nil || perms&readPermissions != readPermissions {
			continue
		}
		readable = append(readable, ch)
	}
	return describeChannels(readable, categories, d.descriptions), nil
}

// describeChannels orders channels by category then position, and attaches
// category names and descriptions.
func describeChannels(chans []*discordgo.Channel, categories map[string]*discordgo.Channel, descriptions map[string]string) []ReadableChannel {
	position := func(ch *discordgo.Channel) (int, int) {
		if cat, ok := categories[ch.ParentID]; ok {
			return cat.Position, ch.Position
		}
		return -1, ch.Position // uncategorised channels come first, as in Discord
	}
	sort.SliceStable(chans, func(i, j int) bool {
		ci, pi := position(chans[i])
		cj, pj := position(chans[j])
		if ci != cj {
			return ci < cj
		}
		return pi < pj
	})

	out := make([]ReadableChannel, 0, len(chans))
	for _, ch := range chans {
		rc := ReadableChannel{Name: ch.Name, ID: ch.ID, Description: truncate(strings.TrimSpace(ch.Topic), 300)}
		if desc := descriptions[ch.ID]; desc != "" {
			rc.Description = desc
		}
		if cat, ok := categories[ch.ParentID]; ok {
			rc.Category = cat.Name
		}
		out = append(out, rc)
	}
	return out
}

// resolveChannel finds a channel by ID, or by name (case-insensitive, with or
// without a leading #), among the readable ones. A name shared by several
// channels must be given by ID.
func resolveChannel(readable []ReadableChannel, ref string) (ReadableChannel, error) {
	ref = strings.TrimSpace(ref)
	name := strings.ToLower(strings.TrimPrefix(ref, "#"))
	var matches []ReadableChannel
	for _, ch := range readable {
		if ch.ID == ref {
			return ch, nil
		}
		if strings.ToLower(ch.Name) == name {
			matches = append(matches, ch)
		}
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return ReadableChannel{}, fmt.Errorf("no readable channel %q; call list_channels to see the ones you can read", ref)
	}
	var ids []string
	for _, m := range matches {
		ids = append(ids, fmt.Sprintf("%s (%s, category %q)", m.ID, m.Name, m.Category))
	}
	return ReadableChannel{}, fmt.Errorf("several channels are named %q; use an ID: %s", ref, strings.Join(ids, "; "))
}

// ChannelMessage is one message as the model sees it.
type ChannelMessage struct {
	PostedUTC string   `json:"posted_utc"`
	Author    string   `json:"author"`
	Content   string   `json:"content,omitempty"`
	Embeds    []string `json:"embeds,omitempty"`
	Files     []string `json:"files,omitempty"`
	Link      string   `json:"link"`
}

// Bounds on what one read can put into the model's context.
const (
	defaultChannelRead  = 15
	maxChannelRead      = 50
	maxMessageChars     = 3000
	maxChannelReadChars = 40000
)

// discordEpochMS is the start of Discord's snowflake clock (2015-01-01 UTC).
const discordEpochMS = 1420070400000

// snowflakeAt is the smallest snowflake for a time, for before/after paging.
func snowflakeAt(t time.Time) string {
	ms := t.UnixMilli() - discordEpochMS
	if ms < 0 {
		ms = 0
	}
	return strconv.FormatUint(uint64(ms)<<22, 10)
}

// readChannel returns up to limit messages from a channel, newest first,
// optionally only those posted before and/or after the given times. Message
// text is cut to keep a single read within the context budget.
func readChannel(ctx context.Context, reader messageReader, guildID string, ch ReadableChannel, limit int, before, after time.Time) ([]ChannelMessage, error) {
	if limit <= 0 {
		limit = defaultChannelRead
	}
	if limit > maxChannelRead {
		limit = maxChannelRead
	}

	var beforeID, afterID string
	if !before.IsZero() {
		beforeID = snowflakeAt(before)
	}
	// Discord returns the oldest messages after an "after" ID, which is the
	// wrong end when both bounds are set, so "after" is applied as a filter
	// unless it is the only bound.
	if !after.IsZero() && before.IsZero() {
		afterID = snowflakeAt(after)
	}

	msgs, err := reader.ChannelMessages(ch.ID, limit, beforeID, afterID, "", discordgo.WithContext(ctx))
	if err != nil {
		return nil, fmt.Errorf("reading #%s (does the bot have View Channel and Read Message History there?): %w", ch.Name, err)
	}
	// With only "after", Discord pages forward and returns oldest first.
	if afterID != "" {
		for i, j := 0, len(msgs)-1; i < j; i, j = i+1, j-1 {
			msgs[i], msgs[j] = msgs[j], msgs[i]
		}
	}

	out := []ChannelMessage{}
	total := 0
	for _, m := range msgs {
		if !after.IsZero() && !m.Timestamp.After(after) {
			continue
		}
		cm := ChannelMessage{
			PostedUTC: m.Timestamp.UTC().Format("2006-01-02 15:04"),
			Content:   truncate(strings.TrimSpace(m.Content), maxMessageChars),
			Link:      fmt.Sprintf("https://discord.com/channels/%s/%s/%s", guildID, ch.ID, m.ID),
		}
		if m.Author != nil {
			cm.Author = m.Author.Username
			if m.Author.GlobalName != "" {
				cm.Author = m.Author.GlobalName
			}
		}
		// Changelogs are often posted by webhooks or bots as embeds.
		for _, e := range m.Embeds {
			if text := embedText(e); text != "" {
				cm.Embeds = append(cm.Embeds, truncate(text, maxMessageChars))
			}
		}
		for _, a := range m.Attachments {
			cm.Files = append(cm.Files, a.Filename)
		}
		if cm.Content == "" && len(cm.Embeds) == 0 && len(cm.Files) == 0 {
			continue
		}
		size := len(cm.Content)
		for _, e := range cm.Embeds {
			size += len(e)
		}
		if total+size > maxChannelReadChars && len(out) > 0 {
			break // keep the newest messages that fit
		}
		total += size
		out = append(out, cm)
	}
	return out, nil
}

// embedText flattens an embed's readable parts.
func embedText(e *discordgo.MessageEmbed) string {
	var parts []string
	if e.Title != "" {
		parts = append(parts, e.Title)
	}
	if e.Description != "" {
		parts = append(parts, e.Description)
	}
	for _, f := range e.Fields {
		parts = append(parts, f.Name+": "+f.Value)
	}
	return strings.TrimSpace(strings.Join(parts, "\n"))
}
