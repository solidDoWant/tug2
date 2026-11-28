package main

import (
	"strings"
	"time"
)

// Replies show absolute times as Discord timestamp markup (<t:UNIX:f>), which
// each reader's client renders in their own timezone. The model is unreliable
// at converting dates to Unix seconds, so the tools hand it the number next to
// each time to copy (see the Times rules in the system prompt).

// unixSuffix names the field or column holding a time's Unix seconds.
const unixSuffix = "_unix"

// addUnixTimes walks a decoded stats-api response and adds key_unix next to
// every RFC 3339 time (created_at, last_seen, played_at, window since/until,
// history_since...). The API's times are all UTC.
func addUnixTimes(v any) {
	switch v := v.(type) {
	case map[string]any:
		for key, e := range v {
			if s, ok := e.(string); ok && !strings.HasSuffix(key, unixSuffix) {
				if _, taken := v[key+unixSuffix]; !taken {
					if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
						v[key+unixSuffix] = t.Unix()
					}
				}
				continue
			}
			addUnixTimes(e)
		}
	case []any:
		for _, e := range v {
			addUnixTimes(e)
		}
	}
}
