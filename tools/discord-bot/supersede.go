package main

import (
	"fmt"
	"log/slog"
	"strings"

	"github.com/bwmarrin/discordgo"
)

// Refining a draft ("make the title shorter") makes the model post a new one
// in the same thread. Only the latest draft in a thread can be filed: posting
// one takes the buttons off any earlier draft still awaiting confirmation,
// and Confirm re-checks the thread at click time, in case that edit failed or
// raced the click. The bot keeps no state, so both read the thread itself.

const (
	pendingDraftState    = "awaiting confirmation"
	supersededDraftState = "replaced by a newer draft"
	// supersedeScan is how many messages are checked on either side of a
	// draft; Discord's maximum for one page.
	supersedeScan = 100
)

// draftMessenger is the part of the Discord session that superseding uses.
type draftMessenger interface {
	ChannelMessages(channelID string, limit int, beforeID, afterID, aroundID string, options ...discordgo.RequestOption) ([]*discordgo.Message, error)
	ChannelMessageEditComplex(m *discordgo.MessageEdit, options ...discordgo.RequestOption) (*discordgo.Message, error)
}

// draftEmbedOf returns the issue draft embed of one of the bot's messages, in
// any state (pending, cancelled, superseded or filed), or nil.
func draftEmbedOf(m *discordgo.Message, botID string) *discordgo.MessageEmbed {
	if m == nil || m.Author == nil || m.Author.ID != botID {
		return nil
	}
	for _, e := range m.Embeds {
		if e.Footer != nil && (strings.HasPrefix(e.Footer.Text, draftFooterPrefix) || strings.HasPrefix(e.Footer.Text, filedFooterPrefix)) {
			return e
		}
	}
	return nil
}

// supersededEmbed is a draft's embed marked as replaced, everything else kept
// so the thread still shows what it said.
func supersededEmbed(e *discordgo.MessageEmbed) *discordgo.MessageEmbed {
	out := *e
	out.Footer = &discordgo.MessageEmbedFooter{Text: draftFooterPrefix + supersededDraftState}
	return &out
}

// supersedeDrafts takes the buttons off every draft before latestID in the
// thread that is still awaiting confirmation, and marks it replaced. It is
// best effort: a draft it misses is refused at click time by newerDraft.
func supersedeDrafts(log *slog.Logger, s draftMessenger, threadID, botID, latestID string) {
	msgs, err := s.ChannelMessages(threadID, supersedeScan, latestID, "", "")
	if err != nil {
		log.Warn("reading thread to supersede earlier drafts", "err", err)
		return
	}
	for _, m := range msgs {
		e := draftEmbedOf(m, botID)
		if e == nil || e.Footer.Text != draftFooterPrefix+pendingDraftState || len(m.Components) == 0 {
			continue
		}
		embeds := []*discordgo.MessageEmbed{supersededEmbed(e)}
		components := []discordgo.MessageComponent{}
		if _, err := s.ChannelMessageEditComplex(&discordgo.MessageEdit{
			ID: m.ID, Channel: threadID, Embeds: &embeds, Components: &components, AllowedMentions: noMentions,
		}); err != nil {
			log.Warn("superseding earlier draft", "draft", m.ID, "err", err)
			continue
		}
		log.Info("superseded earlier draft", "draft", m.ID, "by", latestID)
	}
}

// newerDraft reports whether the bot posted another draft in the thread after
// draftID, so draftID is no longer the one to file.
func newerDraft(s draftMessenger, threadID, botID, draftID string) (bool, error) {
	msgs, err := s.ChannelMessages(threadID, supersedeScan, "", draftID, "")
	if err != nil {
		return false, fmt.Errorf("reading the thread after the draft: %w", err)
	}
	for _, m := range msgs {
		if m.ID != draftID && draftEmbedOf(m, botID) != nil {
			return true, nil
		}
	}
	return false, nil
}
