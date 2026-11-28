package main

import (
	"errors"
	"log/slog"
	"slices"
	"strings"
	"testing"

	"github.com/bwmarrin/discordgo"
)

// fakeThread is a thread's messages, oldest first, answering ChannelMessages
// the way Discord does for "before" and "after".
type fakeThread struct {
	msgs    []*discordgo.Message
	edits   []*discordgo.MessageEdit
	readErr error
	editErr error
}

func (f *fakeThread) ChannelMessages(channelID string, limit int, beforeID, afterID, aroundID string, options ...discordgo.RequestOption) ([]*discordgo.Message, error) {
	if f.readErr != nil {
		return nil, f.readErr
	}
	var out []*discordgo.Message
	for _, m := range f.msgs {
		if (beforeID != "" && m.ID >= beforeID) || (afterID != "" && m.ID <= afterID) {
			continue
		}
		out = append(out, m)
	}
	slices.Reverse(out) // newest first
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (f *fakeThread) ChannelMessageEditComplex(m *discordgo.MessageEdit, options ...discordgo.RequestOption) (*discordgo.Message, error) {
	if f.editErr != nil {
		return nil, f.editErr
	}
	f.edits = append(f.edits, m)
	return &discordgo.Message{ID: m.ID}, nil
}

const testBotID = "900"

func draftMsg(id, state string, buttons bool) *discordgo.Message {
	d := IssueDraft{Kind: IssueBug, Title: "Draft " + id, Body: "body", Labels: []string{"area:maps"}}
	m := &discordgo.Message{ID: id, Author: &discordgo.User{ID: testBotID, Bot: true},
		Embeds: []*discordgo.MessageEmbed{draftEmbed(d, state)}}
	if buttons {
		m.Components = draftButtons(IssueBug, "100", false)
	}
	return m
}

func TestSupersedeDrafts(t *testing.T) {
	filed := draftMsg("13", "", false)
	filed.Embeds[0] = filedEmbed(IssueDraft{Kind: IssueBug, Title: "Filed"}, "https://github.com/o/r/issues/4")
	thread := &fakeThread{msgs: []*discordgo.Message{
		{ID: "10", Author: &discordgo.User{ID: "100"}, Content: "the map vote is broken"},
		draftMsg("11", pendingDraftState, true),
		draftMsg("12", "cancelled", false),
		filed,
		{ID: "14", Author: &discordgo.User{ID: "100"}, Content: "shorter title please"},
		draftMsg("15", pendingDraftState, true),
		draftMsg("16", pendingDraftState, true), // the new draft
	}}

	supersedeDrafts(slog.Default(), thread, "t", testBotID, "16")

	var edited []string
	for _, e := range thread.edits {
		edited = append(edited, e.ID)
		if e.Channel != "t" || e.Components == nil || len(*e.Components) != 0 {
			t.Errorf("edit %s must remove the buttons: %+v", e.ID, e)
		}
		got := (*e.Embeds)[0]
		if got.Footer.Text != draftFooterPrefix+supersededDraftState || got.Title != "Draft "+e.ID ||
			len(draftLabels(got)) != 1 {
			t.Errorf("edit %s embed = %+v", e.ID, got)
		}
	}
	slices.Sort(edited)
	if !slices.Equal(edited, []string{"11", "15"}) {
		t.Errorf("superseded %v, want only the earlier pending drafts 11 and 15", edited)
	}

	// The model sees the earlier draft as replaced.
	if text := botMessageText(&discordgo.Message{Embeds: *thread.edits[0].Embeds}); !strings.Contains(text, supersededDraftState) {
		t.Errorf("model sees %q", text)
	}

	// Discord errors are logged, not fatal.
	supersedeDrafts(slog.Default(), &fakeThread{readErr: errors.New("boom")}, "t", testBotID, "16")
	supersedeDrafts(slog.Default(), &fakeThread{msgs: thread.msgs, editErr: errors.New("boom")}, "t", testBotID, "16")
}

func TestNewerDraft(t *testing.T) {
	thread := &fakeThread{msgs: []*discordgo.Message{
		draftMsg("11", pendingDraftState, true),
		{ID: "12", Author: &discordgo.User{ID: "100"}, Content: "shorter title please"},
		{ID: "13", Author: &discordgo.User{ID: testBotID}, Content: "Filed as issue #4"},
		draftMsg("14", pendingDraftState, true),
		{ID: "15", Author: &discordgo.User{ID: "100"}, Content: "looks good"},
	}}
	for id, want := range map[string]bool{"11": true, "14": false} {
		if got, err := newerDraft(thread, "t", testBotID, id); err != nil || got != want {
			t.Errorf("newerDraft(%s) = %v, %v; want %v", id, got, err, want)
		}
	}
	// A draft by someone else, e.g. another bot echoing the embed, doesn't count.
	other := draftMsg("16", pendingDraftState, true)
	other.Author = &discordgo.User{ID: "901", Bot: true}
	thread.msgs = append(thread.msgs, other)
	if got, _ := newerDraft(thread, "t", testBotID, "14"); got {
		t.Error("another author's embed superseded the draft")
	}
	if _, err := newerDraft(&fakeThread{readErr: errors.New("boom")}, "t", testBotID, "14"); err == nil {
		t.Error("read error not returned")
	}
}
