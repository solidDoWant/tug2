package main

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rumblefrog/go-a2s"
)

// ServerStatus is the live state of one game server, from a Source (A2S)
// query. Round progress comes from the hostname, which gg2_hostname_rounds
// decorates for the server browser (see that plugin's header for the format).
type ServerStatus struct {
	Server     string `json:"server"`
	Online     bool   `json:"online"`
	Error      string `json:"error,omitempty"`
	Hostname   string `json:"hostname,omitempty"`
	Map        string `json:"map,omitempty"`
	Players    int    `json:"players"`
	MaxPlayers int    `json:"max_players"`
	// Bots is what the server reports; Insurgency's AI is not counted here.
	Bots int `json:"bots"`
	// Round / MaxRounds are parsed from "(2/5)"; MaxRounds is 0 when the
	// server has no round limit, and both are 0 when not shown.
	Round     int `json:"round,omitempty"`
	MaxRounds int `json:"max_rounds,omitempty"`
	// Objective is the bracketed progress, e.g. "Cap 3/8" or "Level 6".
	Objective string `json:"objective,omitempty"`
	// MapEnded is true while the map vote is up after the last round.
	MapEnded bool `json:"map_ended,omitempty"`
	// Theater is mp_theater_override, which names the game mode on most maps.
	Theater     string         `json:"theater,omitempty"`
	PlayerList  []StatusPlayer `json:"player_list,omitempty"`
	QueriedAtUT string         `json:"queried_at_utc"`
}

// StatusPlayer is one connected player as the query reports them.
type StatusPlayer struct {
	Name          string `json:"name"`
	Score         int    `json:"score"`
	ConnectedMins int    `json:"connected_minutes"`
}

var (
	roundPattern     = regexp.MustCompile(`\((\d+)(?:/(\d+|\?))?\)`)
	objectivePattern = regexp.MustCompile(`\[([^\]]+)\]\s*$`)
)

const mapEndSuffix = "(Map end)"

// parseHostname extracts the round progress gg2_hostname_rounds appends:
// "Name (2/5) [Cap 3/8]", "Name (3)" with no round limit, or "Name (Map end)".
// Anything else leaves the fields zero; the raw hostname is still returned.
func parseHostname(status *ServerStatus, hostname string) {
	trimmed := strings.TrimSpace(hostname)
	if strings.HasSuffix(trimmed, mapEndSuffix) {
		status.MapEnded = true
		return
	}
	if m := objectivePattern.FindStringSubmatch(trimmed); m != nil {
		status.Objective = strings.TrimSpace(m[1])
		trimmed = strings.TrimSpace(trimmed[:len(trimmed)-len(m[0])])
	}
	// Only a round marker at the end of what remains counts, so a "(...)" that
	// is part of the base server name is not mistaken for progress.
	if locs := roundPattern.FindAllStringSubmatchIndex(trimmed, -1); len(locs) > 0 {
		last := locs[len(locs)-1]
		if last[1] == len(trimmed) {
			status.Round, _ = strconv.Atoi(trimmed[last[2]:last[3]])
			if last[4] >= 0 {
				status.MaxRounds, _ = strconv.Atoi(trimmed[last[4]:last[5]])
			}
		}
	}
}

// QueryServer asks one game server for its info, players and rules. Players
// and rules are best-effort: a server that answers info is reported online
// even if the follow-up queries fail.
func QueryServer(name, address string, timeout time.Duration) ServerStatus {
	status := ServerStatus{Server: name, QueriedAtUT: time.Now().UTC().Format(time.RFC3339)}

	client, err := a2s.NewClient(address, a2s.TimeoutOption(timeout))
	if err != nil {
		status.Error = fmt.Sprintf("could not create query client: %v", err)
		return status
	}
	defer client.Close()

	info, err := client.QueryInfo()
	if err != nil {
		status.Error = "server did not answer (it may be restarting or changing maps)"
		return status
	}
	status.Online = true
	status.Hostname = info.Name
	status.Map = info.Map
	status.Players = int(info.Players)
	status.MaxPlayers = int(info.MaxPlayers)
	status.Bots = int(info.Bots)
	parseHostname(&status, info.Name)

	if players, err := client.QueryPlayer(); err == nil {
		for _, p := range players.Players {
			if strings.TrimSpace(p.Name) == "" {
				continue // connecting players have no name yet
			}
			status.PlayerList = append(status.PlayerList, StatusPlayer{
				Name:          p.Name,
				Score:         int(p.Score),
				ConnectedMins: int(p.Duration / 60),
			})
		}
		sort.SliceStable(status.PlayerList, func(i, j int) bool {
			return status.PlayerList[i].Score > status.PlayerList[j].Score
		})
	}

	if rules, err := client.QueryRules(); err == nil {
		status.Theater = rules.Rules["mp_theater_override"]
	}

	return status
}
