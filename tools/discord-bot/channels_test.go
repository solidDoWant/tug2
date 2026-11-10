package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/bwmarrin/discordgo"
)

type fakeReader struct {
	msgs                []*discordgo.Message // newest first, as Discord returns them
	gotBefore, gotAfter string
	gotLimit            int
}

func (f *fakeReader) ChannelMessages(channelID string, limit int, beforeID, afterID, aroundID string, options ...discordgo.RequestOption) ([]*discordgo.Message, error) {
	f.gotLimit, f.gotBefore, f.gotAfter = limit, beforeID, afterID
	if afterID != "" {
		// Discord pages forward from "after" and returns oldest first.
		out := append([]*discordgo.Message{}, f.msgs...)
		for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
			out[i], out[j] = out[j], out[i]
		}
		return out, nil
	}
	return f.msgs, nil
}

func msgAt(id string, ts time.Time, content string, embeds ...*discordgo.MessageEmbed) *discordgo.Message {
	return &discordgo.Message{ID: id, Timestamp: ts, Content: content, Embeds: embeds,
		Author: &discordgo.User{Username: "changelog-webhook"}}
}

func TestReadChannel(t *testing.T) {
	day := func(d int) time.Time { return time.Date(2026, 11, d, 12, 0, 0, 0, time.UTC) }
	reader := &fakeReader{msgs: []*discordgo.Message{
		msgAt("3", day(9), "", &discordgo.MessageEmbed{Title: "Update 0.0.111", Description: "Fixed medic revives",
			Fields: []*discordgo.MessageEmbedField{{Name: "Maps", Value: "added Crossbow"}}}),
		msgAt("2", day(5), "Update 0.0.110: new weapon"),
		msgAt("1", day(1), "Update 0.0.109"),
	}}
	ch := ReadableChannel{Name: "changelog", ID: "999"}

	got, err := readChannel(context.Background(), reader, "42", ch, 0, time.Time{}, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if reader.gotLimit != defaultChannelRead || len(got) != 3 {
		t.Fatalf("limit %d, got %d messages", reader.gotLimit, len(got))
	}
	if got[0].Link != "https://discord.com/channels/42/999/3" || !strings.Contains(got[0].Embeds[0], "Maps: added Crossbow") {
		t.Errorf("newest message = %+v", got[0])
	}

	// Only "after": results come back newest first and exclude the boundary.
	got, _ = readChannel(context.Background(), reader, "42", ch, 100, time.Time{}, day(1))
	if reader.gotLimit != maxChannelRead || reader.gotAfter == "" {
		t.Errorf("limit %d after %q", reader.gotLimit, reader.gotAfter)
	}
	if len(got) != 2 || !strings.Contains(got[0].Embeds[0], "0.0.111") {
		t.Errorf("after-only read = %+v", got)
	}

	// Both bounds: "before" is sent to Discord, "after" filters.
	got, _ = readChannel(context.Background(), reader, "42", ch, 10, day(9), day(1))
	if reader.gotBefore != snowflakeAt(day(9)) || reader.gotAfter != "" {
		t.Errorf("before %q after %q", reader.gotBefore, reader.gotAfter)
	}
	if len(got) != 2 { // the fake ignores before; the after filter drops message 1
		t.Errorf("both-bounds read returned %d messages", len(got))
	}
}

func TestSnowflakeAt(t *testing.T) {
	// A known snowflake and its timestamp, from Discord's documentation.
	ts, _ := discordgo.SnowflakeTimestamp("175928847299117063")
	got := snowflakeAt(ts)
	if got > "175928847299117063" || len(got) != len("175928847299117063") {
		t.Errorf("snowflakeAt = %s, want the smallest snowflake at that millisecond", got)
	}
	if back, _ := discordgo.SnowflakeTimestamp(got); !back.Equal(ts) {
		t.Errorf("round trip %v != %v", back, ts)
	}
}

func TestParseToolTime(t *testing.T) {
	for _, in := range []string{"2026-11-01", "2026-11-01 18:30", "2026-11-01T18:30:00Z"} {
		if _, err := parseToolTime(in); err != nil {
			t.Errorf("%q: %v", in, err)
		}
	}
	if tm, err := parseToolTime(""); err != nil || !tm.IsZero() {
		t.Errorf("empty should be no bound")
	}
	if _, err := parseToolTime("last tuesday"); err == nil {
		t.Error("free text accepted")
	}
}
