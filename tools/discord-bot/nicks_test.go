package main

import (
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/bwmarrin/discordgo"
)

func TestNickCache(t *testing.T) {
	c := newNickCache()
	now := time.Date(2026, 11, 11, 21, 0, 0, 0, time.UTC)
	c.now = func() time.Time { return now }
	calls := 0
	var nick string
	var err error
	lookup := func(guildID, userID string) (*discordgo.Member, error) {
		calls++
		if err != nil {
			return nil, err
		}
		return &discordgo.Member{Nick: nick}, nil
	}

	nick = "discordalpha [TestPlayerAlpha]"
	if got, ok := c.get("g", "u1", lookup); !ok || got != nick || calls != 1 {
		t.Fatalf("first get = %q %v, %d calls", got, ok, calls)
	}
	nick = "renamed"
	if got, _ := c.get("g", "u1", lookup); got != "discordalpha [TestPlayerAlpha]" || calls != 1 {
		t.Errorf("cached get = %q, %d calls", got, calls)
	}
	now = now.Add(nickTTL + time.Second)
	if got, _ := c.get("g", "u1", lookup); got != "renamed" || calls != 2 {
		t.Errorf("after expiry = %q, %d calls", got, calls)
	}

	// A member who left has no nickname, cached like any other answer.
	err = &discordgo.RESTError{Response: &http.Response{StatusCode: http.StatusNotFound}}
	if got, ok := c.get("g", "gone", lookup); !ok || got != "" {
		t.Errorf("left the server = %q %v", got, ok)
	}

	// Other failures aren't trusted, and are retried after a minute.
	err = errors.New("discord is down")
	if _, ok := c.get("g", "u2", lookup); ok {
		t.Error("a failed lookup reported ok")
	}
	before := calls
	c.get("g", "u2", lookup)
	if calls != before {
		t.Error("retried a failed lookup straight away")
	}
	now = now.Add(nickRetryTTL + time.Second)
	err = nil
	nick = "back"
	if got, ok := c.get("g", "u2", lookup); !ok || got != "back" {
		t.Errorf("after retry = %q %v", got, ok)
	}
}

func TestAuthorName(t *testing.T) {
	session, _ := discordgo.New("Bot test")
	session.State.User = &discordgo.User{ID: "bot"}
	b := &Bot{session: session, nicks: newNickCache()}
	if err := session.State.GuildAdd(&discordgo.Guild{ID: "g"}); err != nil {
		t.Fatal(err)
	}
	if err := session.State.MemberAdd(&discordgo.Member{GuildID: "g", Nick: "discordalpha [TestPlayerAlpha]", User: &discordgo.User{ID: "u1"}}); err != nil {
		t.Fatal(err)
	}

	// From REST (no member object): the nickname is looked up.
	rest := &discordgo.Message{Author: &discordgo.User{ID: "u1", Username: "discordalpha", GlobalName: "Discord Alpha"}}
	if got := b.authorName("g", rest); got != "discordalpha [TestPlayerAlpha]" {
		t.Errorf("REST message: %q", got)
	}
	// From the gateway or an /ask interaction: the member it carries wins.
	live := &discordgo.Message{Author: rest.Author, Member: &discordgo.Member{Nick: "TestNick"}}
	if got := b.authorName("g", live); got != "TestNick" {
		t.Errorf("gateway message: %q", got)
	}
	noNick := &discordgo.Message{Author: rest.Author, Member: &discordgo.Member{}}
	if got := b.authorName("g", noNick); got != "Discord Alpha" {
		t.Errorf("member without a nickname: %q", got)
	}
}
