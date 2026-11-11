package main

import (
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/bwmarrin/discordgo"
)

// How long a looked-up nickname is trusted. Long enough that one thread's
// history renders the same on every turn (keeping the prompt cache warm),
// short enough that a renamed member is picked up the same day.
const (
	nickTTL      = 30 * time.Minute
	nickRetryTTL = time.Minute // after a failed lookup
)

type nickEntry struct {
	nick    string
	expires time.Time
}

// nickCache holds server nicknames ("" for none) by guild and user.
type nickCache struct {
	mu      sync.Mutex
	entries map[string]nickEntry
	now     func() time.Time
}

func newNickCache() *nickCache {
	return &nickCache{entries: map[string]nickEntry{}, now: time.Now}
}

// get returns the user's nickname, looking it up when not cached. ok is false
// when the lookup failed; the failure is remembered briefly so a Discord
// outage doesn't mean one request per message.
func (c *nickCache) get(guildID, userID string, lookup func(guildID, userID string) (*discordgo.Member, error)) (string, bool) {
	key := guildID + "/" + userID
	c.mu.Lock()
	e, found := c.entries[key]
	c.mu.Unlock()
	if found && c.now().Before(e.expires) {
		return e.nick, true
	}

	member, err := lookup(guildID, userID)
	nick, ttl := "", nickTTL
	var rest *discordgo.RESTError
	switch {
	case err == nil:
		nick = member.Nick
	case errors.As(err, &rest) && rest.Response != nil && rest.Response.StatusCode == http.StatusNotFound:
		// Left the server: no nickname.
	default:
		slog.Warn("looking up a member's nickname", "user", userID, "err", err)
		ttl = nickRetryTTL
	}
	c.mu.Lock()
	c.entries[key] = nickEntry{nick: nick, expires: c.now().Add(ttl)}
	c.mu.Unlock()
	return nick, ttl == nickTTL
}
