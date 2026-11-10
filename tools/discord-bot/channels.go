package main

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/bwmarrin/discordgo"
)

// messageReader is the part of the Discord session the channel tool needs.
type messageReader interface {
	ChannelMessages(channelID string, limit int, beforeID, afterID, aroundID string, options ...discordgo.RequestOption) ([]*discordgo.Message, error)
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
