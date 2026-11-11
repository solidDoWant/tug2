package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/bwmarrin/discordgo"
)

func forwardOf(id string, ts time.Time, content string) *discordgo.Message {
	return &discordgo.Message{
		ID: id, Timestamp: ts, GuildID: "42", Author: &discordgo.User{ID: "u1", Username: "TestUserOne"},
		MessageReference: &discordgo.MessageReference{Type: discordgo.MessageReferenceTypeForward, GuildID: "42", ChannelID: "777", MessageID: "555"},
		MessageSnapshots: []discordgo.MessageSnapshot{{Message: &discordgo.Message{
			Content:     content,
			Timestamp:   ts.Add(-time.Hour),
			Embeds:      []*discordgo.MessageEmbed{{Title: "Round over"}},
			Attachments: []*discordgo.MessageAttachment{{Filename: "shot.png"}},
		}}},
	}
}

func TestForwardedText(t *testing.T) {
	ts := time.Date(2026, 11, 11, 2, 0, 0, 0, time.UTC)
	raw := "[[MEDIC] [TAG]TestPlayerAlpha](<https://steamcommunity.com/profiles/1>): revived [TestPlayerBravo](<https://steamcommunity.com/profiles/2>)"
	got := forwardedText(forwardOf("9", ts, raw))
	for _, want := range []string{
		"[Forwarded message from channel ID 777, originally posted 2026-11-11 01:00 UTC, original: https://discord.com/channels/42/777/555]",
		raw, // raw markup, so rendering problems stay visible
		"[Embed: Round over]",
		"[Attachment: shot.png]",
		"[End of forwarded message]",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("missing %q in:\n%s", want, got)
		}
	}

	plain := &discordgo.Message{Content: "hi", MessageReference: &discordgo.MessageReference{MessageID: "1"}}
	if forwardedText(plain) != "" || withForwarded("hi", plain) != "hi" {
		t.Error("a reply was treated as a forward")
	}
	if w := withForwarded("look at this", forwardOf("9", ts, "x")); !strings.HasPrefix(w, "look at this\n[Forwarded") {
		t.Errorf("withForwarded = %q", w)
	}
}

func TestReadChannelForward(t *testing.T) {
	ts := time.Date(2026, 11, 11, 2, 0, 0, 0, time.UTC)
	reader := &fakeReader{msgs: []*discordgo.Message{forwardOf("9", ts, "forwarded text")}}
	got, err := readChannel(context.Background(), reader, "42", ReadableChannel{Name: "bugs", ID: "100"}, 0, time.Time{}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || !strings.Contains(got[0].Content, "forwarded text") {
		t.Errorf("forward dropped or empty: %+v", got)
	}
}

func TestLeadIn(t *testing.T) {
	const bot = "900"
	t0 := time.Date(2026, 11, 11, 2, 0, 0, 0, time.UTC)
	user := &discordgo.User{ID: "u1"}
	other := &discordgo.User{ID: "u2"}
	at := func(id string, u *discordgo.User, ago time.Duration) *discordgo.Message {
		return &discordgo.Message{ID: id, Author: u, Timestamp: t0.Add(-ago)}
	}
	starter := at("10", user, 0)

	ids := func(ms []*discordgo.Message) string {
		var s []string
		for _, m := range ms {
			s = append(s, m.ID)
		}
		return strings.Join(s, ",")
	}

	// Newest first: two of the user's messages, then someone else's.
	before := []*discordgo.Message{at("9", user, time.Minute), at("8", user, 3*time.Minute), at("7", other, 4*time.Minute), at("6", user, 5*time.Minute)}
	if got := ids(leadIn(starter, before, bot)); got != "8,9" {
		t.Errorf("run = %s, want 8,9", got)
	}

	// A gap longer than leadInGap ends the run.
	before = []*discordgo.Message{at("9", user, time.Minute), at("8", user, time.Minute+leadInGap+time.Second)}
	if got := ids(leadIn(starter, before, bot)); got != "9" {
		t.Errorf("gap run = %s, want 9", got)
	}

	// An earlier @mention is its own question.
	asked := at("9", user, time.Minute)
	asked.Mentions = []*discordgo.User{{ID: bot}}
	if got := ids(leadIn(starter, []*discordgo.Message{asked}, bot)); got != "" {
		t.Errorf("mention run = %s, want none", got)
	}

	// A reply brings in what it replies to, first, without duplicating it.
	reply := at("10", user, 0)
	reply.Type = discordgo.MessageTypeReply
	reply.ReferencedMessage = at("5", other, time.Hour)
	if got := ids(leadIn(reply, []*discordgo.Message{at("9", user, time.Minute)}, bot)); got != "5,9" {
		t.Errorf("reply run = %s, want 5,9", got)
	}
	reply.ReferencedMessage = at("9", user, time.Minute)
	if got := ids(leadIn(reply, []*discordgo.Message{at("9", user, time.Minute)}, bot)); got != "9" {
		t.Errorf("reply to run member = %s, want 9", got)
	}
}
