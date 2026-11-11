package main

import (
	"context"
	"net/url"
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

	got, err := readChannel(context.Background(), reader, "42", ch, nil, 0, time.Time{}, time.Time{})
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
	got, _ = readChannel(context.Background(), reader, "42", ch, nil, 100, time.Time{}, day(1))
	if reader.gotLimit != maxChannelRead || reader.gotAfter == "" {
		t.Errorf("limit %d after %q", reader.gotLimit, reader.gotAfter)
	}
	if len(got) != 2 || !strings.Contains(got[0].Embeds[0], "0.0.111") {
		t.Errorf("after-only read = %+v", got)
	}

	// Both bounds: "before" is sent to Discord, "after" filters.
	got, _ = readChannel(context.Background(), reader, "42", ch, nil, 10, day(9), day(1))
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

// testSession builds a discordgo session whose state holds one guild, for
// exercising permission-based channel discovery without a connection.
func testSession(t *testing.T) *discordgo.Session {
	t.Helper()
	const (
		guildID  = "200000000000000000"
		botID    = "200000000000000001"
		everyone = guildID // the @everyone role shares the guild's ID
		botRole  = "200000000000000002"
		modRole  = "200000000000000003"
		view     = discordgo.PermissionViewChannel
		history  = discordgo.PermissionReadMessageHistory
		sendMsg  = discordgo.PermissionSendMessages
	)
	deny := func(id string, perms int64) *discordgo.PermissionOverwrite {
		return &discordgo.PermissionOverwrite{ID: id, Type: discordgo.PermissionOverwriteTypeRole, Deny: perms}
	}
	allow := func(id string, perms int64) *discordgo.PermissionOverwrite {
		return &discordgo.PermissionOverwrite{ID: id, Type: discordgo.PermissionOverwriteTypeRole, Allow: perms}
	}
	text := func(id, name, parent string, pos int, topic string, ow ...*discordgo.PermissionOverwrite) *discordgo.Channel {
		return &discordgo.Channel{ID: id, GuildID: guildID, Name: name, Type: discordgo.ChannelTypeGuildText,
			ParentID: parent, Position: pos, Topic: topic, PermissionOverwrites: ow}
	}

	s := &discordgo.Session{State: discordgo.NewState()}
	s.State.User = &discordgo.User{ID: botID}
	guild := &discordgo.Guild{
		ID: guildID, OwnerID: "209999999999999999",
		Roles: []*discordgo.Role{
			{ID: everyone, Permissions: view | history | sendMsg},
			{ID: botRole, Permissions: 0},
			{ID: modRole, Permissions: 0},
		},
		Members: []*discordgo.Member{{GuildID: guildID, User: &discordgo.User{ID: botID}, Roles: []string{botRole}}},
		Channels: []*discordgo.Channel{
			{ID: "300000000000000001", GuildID: guildID, Name: "Info", Type: discordgo.ChannelTypeGuildCategory, Position: 0},
			{ID: "300000000000000002", GuildID: guildID, Name: "Staff", Type: discordgo.ChannelTypeGuildCategory, Position: 1},
			text("400000000000000001", "general", "300000000000000001", 2, "chat about anything"),
			text("400000000000000002", "changelog", "300000000000000001", 1, "", deny(everyone, sendMsg)),
			// Hidden from @everyone, opened to mods only: the bot can't read it.
			text("400000000000000003", "mod-chat", "300000000000000002", 0, "", deny(everyone, view), allow(modRole, view|history)),
			// Visible but history denied to the bot's role: not readable.
			text("400000000000000004", "no-history", "300000000000000001", 3, "", deny(botRole, history)),
			// Hidden from @everyone but opened to the bot's role: readable.
			text("400000000000000005", "bot-feed", "300000000000000002", 1, "", deny(everyone, view), allow(botRole, view|history)),
			// The bot's own question channel is never offered.
			text("400000000000000006", "ask-the-bot", "", 0, ""),
			{ID: "400000000000000007", GuildID: guildID, Name: "Voice", Type: discordgo.ChannelTypeGuildVoice},
		},
	}
	if err := s.State.GuildAdd(guild); err != nil {
		t.Fatal(err)
	}
	return s
}

func TestDiscordChannelsReadable(t *testing.T) {
	d := &DiscordChannels{
		session:      testSession(t),
		botChannelID: "400000000000000006",
		descriptions: map[string]string{"400000000000000002": "Server update notes, newest first"},
	}
	got, err := d.Readable("200000000000000000")
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, ch := range got {
		names = append(names, ch.Category+"/"+ch.Name)
	}
	// Category order, then position; mod-chat, no-history, the bot's own
	// channel and the voice channel are excluded.
	want := []string{"Info/changelog", "Info/general", "Staff/bot-feed"}
	if strings.Join(names, ",") != strings.Join(want, ",") {
		t.Fatalf("readable = %v, want %v", names, want)
	}
	if got[0].Description != "Server update notes, newest first" || got[1].Description != "chat about anything" {
		t.Errorf("descriptions: configured should win, topic is the fallback: %+v", got)
	}
}

func TestResolveChannel(t *testing.T) {
	readable := []ReadableChannel{
		{Name: "changelog", ID: "1", Category: "Info"},
		{Name: "general", ID: "2", Category: "Info"},
		{Name: "general", ID: "3", Category: "Off-topic"},
	}
	for _, ref := range []string{"changelog", "#Changelog", "1"} {
		if ch, err := resolveChannel(readable, ref); err != nil || ch.ID != "1" {
			t.Errorf("%q -> %+v, %v", ref, ch, err)
		}
	}
	if ch, err := resolveChannel(readable, "3"); err != nil || ch.ID != "3" {
		t.Errorf("by ID among duplicates: %+v, %v", ch, err)
	}
	if _, err := resolveChannel(readable, "general"); err == nil || !strings.Contains(err.Error(), "use an ID") {
		t.Errorf("ambiguous name: %v", err)
	}
	if _, err := resolveChannel(readable, "mod-chat"); err == nil || !strings.Contains(err.Error(), "list_channels") {
		t.Errorf("unknown channel: %v", err)
	}
}

// fakeChannels is a channelSource for tool tests.
type fakeChannels struct {
	fakeReader
	readable []ReadableChannel
	fetched  []string
	// searched is the last search query; found is what searches return.
	searched  url.Values
	found     *messageSearch
	searchErr error
}

func (f *fakeChannels) SearchMessages(_ context.Context, _ string, q url.Values) (*messageSearch, error) {
	f.searched = q
	if f.searchErr != nil {
		return nil, f.searchErr
	}
	if f.found == nil {
		return &messageSearch{}, nil
	}
	return f.found, nil
}

func (f *fakeChannels) Readable(string) ([]ReadableChannel, error) { return f.readable, nil }

func (f *fakeChannels) ChannelMessages(channelID string, limit int, beforeID, afterID, aroundID string, options ...discordgo.RequestOption) ([]*discordgo.Message, error) {
	f.fetched = append(f.fetched, channelID)
	return f.fakeReader.ChannelMessages(channelID, limit, beforeID, afterID, aroundID, options...)
}

func TestChannelTools(t *testing.T) {
	src := &fakeChannels{
		readable:   []ReadableChannel{{Name: "changelog", ID: "11"}},
		fakeReader: fakeReader{msgs: []*discordgo.Message{msgAt("5", time.Now(), "Update 0.0.112")}},
	}
	cfg := &Config{Servers: map[string]GameServer{}}
	ts := NewToolset(cfg, NewStatsClient(cfg.Servers), nil, src)
	tc := &toolContext{guildID: "42"}

	out, err := ts.Run(context.Background(), tc, "list_channels", []byte(`{}`))
	if err != nil || len(out.([]ReadableChannel)) != 1 {
		t.Fatalf("list_channels = %v, %v", out, err)
	}
	if _, err := ts.Run(context.Background(), tc, "read_channel", []byte(`{"channel":"#changelog"}`)); err != nil {
		t.Fatal(err)
	}
	// A channel outside the readable list is refused without being fetched,
	// even by a valid-looking ID.
	if _, err := ts.Run(context.Background(), tc, "read_channel", []byte(`{"channel":"400000000000000003"}`)); err == nil {
		t.Error("read a channel outside the readable list")
	}
	if strings.Join(src.fetched, ",") != "11" {
		t.Errorf("fetched channels = %v, want only 11", src.fetched)
	}
}
