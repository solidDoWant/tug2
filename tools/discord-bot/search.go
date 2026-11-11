package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/bwmarrin/discordgo"
)

// Message search uses Discord's own index (the same one as the search box in
// the app), so it finds matches anywhere in a channel's history. read_channel
// only pages back from a point in time, which in a busy log channel covers a
// few minutes.

// Bounds on a search. Discord returns at most 25 matches per call and allows
// offsets up to 9975.
const (
	defaultSearchLimit = 10
	maxSearchLimit     = 25
	maxSearchOffset    = 9975
	maxSearchQuery     = 1024
	maxSearchChannels  = 500
)

// messageSearch is the part of Discord's search response the bot uses.
type messageSearch struct {
	TotalResults int `json:"total_results"`
	// Messages holds one group per match. Discord used to add the messages
	// around each match to its group; it now sends only the match.
	Messages [][]*discordgo.Message `json:"messages"`
}

// errSearchIndexing is returned while Discord is still building the server's
// search index (HTTP 202).
var errSearchIndexing = errors.New("Discord is still indexing this server's messages, so search isn't available yet; try again in a minute or use read_channel")

// searchQuery is what the model asks for, before it is turned into Discord's
// query parameters.
type searchQuery struct {
	Content    string
	ChannelIDs []string
	Before     time.Time
	After      time.Time
	Oldest     bool // oldest first instead of newest first
	Relevance  bool // best matches first
	Limit      int
	Offset     int
}

// values renders the query as Discord's search parameters.
func (q searchQuery) values() url.Values {
	v := url.Values{}
	v.Set("content", q.Content)
	for _, id := range q.ChannelIDs {
		v.Add("channel_id", id)
	}
	if !q.Before.IsZero() {
		v.Set("max_id", snowflakeAt(q.Before))
	}
	if !q.After.IsZero() {
		v.Set("min_id", snowflakeAt(q.After))
	}
	switch {
	case q.Relevance:
		v.Set("sort_by", "relevance")
		v.Set("sort_order", "desc")
	case q.Oldest:
		v.Set("sort_by", "timestamp")
		v.Set("sort_order", "asc")
	default:
		v.Set("sort_by", "timestamp")
		v.Set("sort_order", "desc")
	}
	v.Set("limit", strconv.Itoa(q.Limit))
	if q.Offset > 0 {
		v.Set("offset", strconv.Itoa(q.Offset))
	}
	return v
}

// SearchMessages runs a guild message search.
func (d *DiscordChannels) SearchMessages(ctx context.Context, guildID string, q url.Values) (*messageSearch, error) {
	endpoint := discordgo.EndpointGuild(guildID) + "/messages/search"
	body, err := d.session.RequestWithBucketID(http.MethodGet, endpoint+"?"+q.Encode(), nil, endpoint, discordgo.WithContext(ctx))
	if err != nil {
		var rest *discordgo.RESTError
		if errors.As(err, &rest) && rest.Response != nil && rest.Response.StatusCode == http.StatusAccepted {
			return nil, errSearchIndexing
		}
		return nil, err
	}
	var out messageSearch
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decoding search results: %w", err)
	}
	return &out, nil
}

// SearchResult is what search_channels returns to the model.
type SearchResult struct {
	// TotalMatches is Discord's count of all matches, which can be an
	// estimate.
	TotalMatches int              `json:"total_matches"`
	Messages     []ChannelMessage `json:"messages"`
	// Next is the offset for the next page, when there are more matches.
	Next int `json:"next_offset,omitempty"`
}

// searchChannels searches the given readable channels. The query is always
// limited to readable channels, so it never reaches the bot's own channel or
// one the bot shouldn't read.
func searchChannels(ctx context.Context, src channelSource, guildID string, chans, readable []ReadableChannel, q searchQuery) (*SearchResult, error) {
	q.Content = strings.TrimSpace(q.Content)
	if q.Content == "" {
		return nil, errors.New("give some text to search for")
	}
	if len(q.Content) > maxSearchQuery {
		return nil, fmt.Errorf("the search text is too long (at most %d characters)", maxSearchQuery)
	}
	if len(chans) == 0 {
		return nil, errors.New("there are no channels to search")
	}
	if len(chans) > maxSearchChannels {
		chans = chans[:maxSearchChannels]
	}
	q.ChannelIDs = nil
	names := map[string]string{}
	for _, ch := range chans {
		q.ChannelIDs = append(q.ChannelIDs, ch.ID)
	}
	for _, ch := range readable {
		names[ch.ID] = ch.Name
	}
	if q.Limit <= 0 {
		q.Limit = defaultSearchLimit
	}
	q.Limit = min(q.Limit, maxSearchLimit)
	q.Offset = max(0, min(q.Offset, maxSearchOffset))

	found, err := src.SearchMessages(ctx, guildID, q.values())
	if err != nil {
		if errors.Is(err, errSearchIndexing) {
			return nil, err
		}
		return nil, fmt.Errorf("searching messages: %w", err)
	}

	channelName := func(id string) string { return names[id] }
	out := &SearchResult{TotalMatches: found.TotalResults, Messages: []ChannelMessage{}}
	total, seen := 0, 0
	for _, group := range found.Messages {
		for _, m := range group {
			if m == nil {
				continue
			}
			seen++
			cm, ok := toChannelMessage(m, guildID, m.ChannelID, channelName)
			if !ok {
				continue
			}
			cm.Channel = names[m.ChannelID]
			if total += cm.size(); total > maxChannelReadChars && len(out.Messages) > 0 {
				break
			}
			out.Messages = append(out.Messages, cm)
		}
	}
	// Discord may return fewer than asked for even with more to come, so
	// page on the offset rather than the count returned.
	if next := q.Offset + len(out.Messages); next < found.TotalResults && next <= maxSearchOffset && seen > 0 {
		out.Next = next
	}
	return out, nil
}
