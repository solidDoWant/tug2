package main

import (
	"fmt"
	"strings"

	"github.com/bwmarrin/discordgo"
)

// forwardedText renders the messages a Discord forward carries. A forward has
// no content of its own: the original is in MessageSnapshots and its location
// in MessageReference. Snapshots carry no author. The result names the source
// channel's ID and links the original, so the model can read that channel
// (read_channel takes an ID) and compare. It returns "" for other messages.
func forwardedText(m *discordgo.Message) string {
	if m.MessageReference == nil || m.MessageReference.Type != discordgo.MessageReferenceTypeForward {
		return ""
	}
	ref := m.MessageReference
	guildID := ref.GuildID
	if guildID == "" {
		guildID = m.GuildID
	}
	var b strings.Builder
	for _, s := range m.MessageSnapshots {
		if s.Message == nil {
			continue
		}
		snap := s.Message
		fmt.Fprintf(&b, "[Forwarded message from channel ID %s", ref.ChannelID)
		if !snap.Timestamp.IsZero() {
			fmt.Fprintf(&b, ", originally posted %s UTC", snap.Timestamp.UTC().Format("2006-01-02 15:04"))
		}
		if guildID != "" && ref.ChannelID != "" && ref.MessageID != "" {
			fmt.Fprintf(&b, ", original: https://discord.com/channels/%s/%s/%s", guildID, ref.ChannelID, ref.MessageID)
		}
		b.WriteString("]\n")
		if text := strings.TrimSpace(snap.Content); text != "" {
			// Raw, so markup that renders badly stays visible.
			b.WriteString(truncate(text, maxMessageChars) + "\n")
		}
		for _, e := range snap.Embeds {
			if text := embedText(e); text != "" {
				b.WriteString("[Embed: " + truncate(text, maxMessageChars) + "]\n")
			}
		}
		for _, a := range snap.Attachments {
			b.WriteString("[Attachment: " + a.Filename + "]\n")
		}
		b.WriteString("[End of forwarded message]\n")
	}
	return strings.TrimSpace(b.String())
}

// withForwarded appends any forwarded message to a message's own text.
func withForwarded(text string, m *discordgo.Message) string {
	fw := forwardedText(m)
	switch {
	case fw == "":
		return text
	case text == "":
		return fw
	default:
		return text + "\n" + fw
	}
}
