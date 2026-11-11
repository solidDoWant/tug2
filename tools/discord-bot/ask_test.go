package main

import (
	"testing"
	"time"

	"github.com/bwmarrin/discordgo"
)

func askResponse(id, botID, userID string, ts time.Time) *discordgo.Message {
	return &discordgo.Message{
		ID: id, Type: discordgo.MessageTypeChatInputCommand, Timestamp: ts, Content: "who has the most kills?",
		Author:              &discordgo.User{ID: botID, Bot: true},
		InteractionMetadata: &discordgo.MessageInteractionMetadata{User: &discordgo.User{ID: userID, Username: "testuserone", GlobalName: "TestUserOne"}},
	}
}

func TestAsAsker(t *testing.T) {
	const bot = "900"
	ts := time.Date(2026, 11, 11, 3, 0, 0, 0, time.UTC)

	q := asAsker(askResponse("1", bot, "u1", ts), bot)
	if q.Author.ID != "u1" || !isAsk(q) || displayName(q) != "TestUserOne" || q.Content != "who has the most kills?" {
		t.Errorf("asAsker = author %+v isAsk %v", q.Author, isAsk(q))
	}

	// The deprecated interaction field is used when metadata is missing.
	old := askResponse("2", bot, "u1", ts)
	old.InteractionMetadata = nil
	old.Interaction = &discordgo.MessageInteraction{User: &discordgo.User{ID: "u2", Username: "testusertwo"},
		Member: &discordgo.Member{Nick: "TestNick"}}
	if q := asAsker(old, bot); q.Author.ID != "u2" || displayName(q) != "TestNick" {
		t.Errorf("deprecated field: %+v", q.Author)
	}

	// Left alone: the bot's ordinary answers, other bots' command responses,
	// and user messages.
	for name, m := range map[string]*discordgo.Message{
		"bot answer":          {Author: &discordgo.User{ID: bot, Bot: true}, Content: "answer"},
		"other bot's /cmd":    askResponse("3", "777", "u1", ts),
		"user message":        {Author: &discordgo.User{ID: "u1"}, Content: "hi"},
		"no interaction info": {Type: discordgo.MessageTypeChatInputCommand, Author: &discordgo.User{ID: bot, Bot: true}},
	} {
		if got := asAsker(m, bot); got != m {
			t.Errorf("%s was changed", name)
		}
	}
	if isAsk(askResponse("4", "777", "u1", ts)) {
		t.Error("another bot's command response counted as a question")
	}
}

func TestLeadInStopsAtAsk(t *testing.T) {
	const bot = "900"
	t0 := time.Date(2026, 11, 11, 3, 0, 0, 0, time.UTC)
	user := &discordgo.User{ID: "u1"}
	starter := asAsker(askResponse("10", bot, "u1", t0), bot)
	before := []*discordgo.Message{
		{ID: "9", Author: user, Timestamp: t0.Add(-time.Minute)},          // part of this question
		asAsker(askResponse("8", bot, "u1", t0.Add(-2*time.Minute)), bot), // an earlier /ask
		{ID: "7", Author: user, Timestamp: t0.Add(-3 * time.Minute)},
	}
	got := leadIn(starter, before, bot)
	if len(got) != 1 || got[0].ID != "9" {
		t.Errorf("leadIn = %v, want just 9", got)
	}
}

func TestAskRouting(t *testing.T) {
	// /ask goes where an @mention would: route with mentioned=true.
	const botChan, bot = "100", "900"
	userThread := &discordgo.Channel{ID: "201", ParentID: botChan, OwnerID: "u1", Type: discordgo.ChannelTypeGuildPublicThread}
	if id, ok := route(botChan, bot, "201", userThread, true); !ok || id != "201" {
		t.Errorf("user thread: %q %v", id, ok)
	}
	if _, ok := route(botChan, bot, "555", &discordgo.Channel{ID: "555", Type: discordgo.ChannelTypeGuildText}, true); ok {
		t.Error("/ask outside the bot channel was accepted")
	}
	if askCommandDef.Options[0].MaxLength != maxAskQuestionLen || !askCommandDef.Options[0].Required {
		t.Error("question option must be required and length-capped")
	}
}
