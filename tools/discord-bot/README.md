# discord-bot

A Discord bot that answers questions about the game servers in plain English,
and helps players file bug reports and feature requests on GitHub. It uses a
Claude model with a fixed set of tools; the model can only read stats, query
server state, search issues, and draft issues. Filing an issue always needs
the reporter to press **Confirm**.

## What it does

- **Stats:** player, weapon, map, bot, medic, team-kill and fire-support stats
  from each server's [stats-api](../stats-api), including lookups by in-game
  name ("how's TestPlayerAlpha doing?", "top 5 by K/D on test").
- **Live server state:** map, players (names, scores, time connected), round
  number, objective progress, and whether the map vote is up. This comes from
  the Source server query (A2S) on the game port, so it needs no RCON password.
  Round and objective are parsed from the hostname that `gg2_hostname_rounds`
  writes for the server browser, so that plugin must be running.
- **Using the API:** gives people links to the public stats API, its docs and
  curl examples. These come from a built-in endpoint reference that a test
  checks against the stats API's OpenAPI spec, so the bot doesn't invent
  paths or parameters.
- **Other channels:** reads channels you list, such as a changelog, to
  answer "what changed in the last update?" or "was this already fixed?".
- **Bug reports / feature requests:** the model asks for missing detail,
  searches existing issues, then posts a draft with **Confirm and file** and
  **Cancel** buttons. Only the person who asked can press them. Filed issues
  get the configured labels and a footer naming the Discord reporter.

## How conversations work

- Mention the bot in the configured channel. It starts a thread named after
  the question and answers there.
- Follow-ups in that thread don't need a mention. The thread itself is the
  conversation history: the bot re-reads it on every message (up to
  `HISTORY_MESSAGES`), so nothing is stored and restarts lose nothing.
- Drafts live in the message embed. Confirming reads the draft back from the
  message, so pending drafts survive restarts too.
- Replies never ping anyone (`allowed_mentions` is empty), whatever the text.

## Discord setup

1. Create an application and bot in the Discord developer portal.
2. Under **Bot**, enable the **Message Content** privileged intent. It is what
   lets the bot read follow-ups in its threads that don't mention it.
3. Invite it with the `bot` scope and these permissions in the bot channel:
   View Channel, Send Messages, Send Messages in Threads, Create Public
   Threads, Read Message History, Embed Links.
4. Copy the channel's ID (Developer Mode → right-click → Copy Channel ID).

## GitHub setup

Issues are filed by a GitHub App, so they show up as `<app name>[bot]`, not as
you. The app's permissions are limited to issues on the repositories you
install it on.

1. GitHub → Settings → Developer settings → GitHub Apps → **New GitHub App**.
   - Homepage URL: anything, e.g. the repository URL.
   - Webhook: untick **Active**. The bot doesn't need events.
   - Repository permissions: **Issues: Read and write**. Metadata (read-only)
     is selected automatically. Nothing else.
   - Where can it be installed: **Only on this account**.
2. Note the **App ID**, then **Generate a private key**. This downloads a `.pem`.
3. **Install App** → choose **Only select repositories** → the one repo.
4. Make sure the labels exist in the repo (`from-discord`, `bug`, `enhancement`
   by default), or change the label settings below.

Give the bot `GITHUB_APP_ID`, the key (as a mounted file via
`GITHUB_APP_PRIVATE_KEY_FILE`, or inline in `GITHUB_APP_PRIVATE_KEY`) and
`GITHUB_REPO`. At startup it finds the app's installation on that repository,
and refuses to start if the app isn't installed there. It then mints
short-lived installation tokens as needed.

Without the app settings the bot still runs: the issue tools are not offered,
and it says reporting isn't set up.

## Per-user limits

Everyone gets the default limits (`RATE_LIMIT_QUESTIONS_PER_HOUR`,
`RATE_LIMIT_ISSUES_PER_DAY`). `USER_LIMITS` overrides them per Discord user
ID. `0` means no limit, and an omitted field keeps the default:

```json
{
  "100000000000000001": { "questions_per_hour": 0, "issues_per_day": 0, "note": "server owner" },
  "100000000000000002": { "questions_per_hour": 60, "note": "admin, raised 2026-11" }
}
```

To get a user ID, enable Developer Mode in Discord, then right-click the user
and choose Copy User ID. Pass the JSON inline in `USER_LIMITS`, or as a
file with `USER_LIMITS_FILE` (e.g. a mounted ConfigMap). Changes take effect
on restart. Counts are kept in memory, so a restart also resets them.
Everyone, including users with no limit, is still answered one question at
a time and shares `MAX_CONCURRENT_QUESTIONS`.

## Reading other channels

`READABLE_CHANNELS` lists extra channels the model may read with its
`read_channel` tool. The model sees each channel's name and description,
reads recent messages (optionally before or after a date), and links what it
cites:

```json
[
  { "name": "changelog", "id": "100000000000000003",
    "description": "Server update notes: what changed in each update, newest first" }
]
```

The bot needs **View Channel** and **Read Message History** in each listed
channel. At startup it logs a warning for any listed channel it can't read.
Text and embeds are both read, since changelogs are often posted by webhooks.
It can only read the channels listed here.

## Configuration

| Variable                        | Default            | Description                                                                                                         |
| ------------------------------- | ------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `DISCORD_TOKEN`                 | _(required)_       | Bot token.                                                                                                          |
| `DISCORD_CHANNEL_ID`            | _(required)_       | The channel the bot answers mentions in.                                                                            |
| `ANTHROPIC_API_KEY`             | _(required)_       | Claude API key.                                                                                                     |
| `SERVERS`                       | _(required)_       | JSON array of servers; see below. The first is the default when a question doesn't name one.                        |
| `LLM_MODEL`                     | `claude-haiku-5-5` | Model ID, e.g. `claude-sonnet-5-5` or `claude-opus-5-5` for better answers at higher cost.                          |
| `LLM_EFFORT`                    | `low`              | `low`, `medium`, `high`, `xhigh` or `max`. Higher thinks harder and costs more.                                     |
| `LLM_MAX_TOKENS`                | `8000`             | Output token cap per model call, thinking included.                                                                 |
| `LLM_MAX_CONTEXT_TOKENS`        | `80000`            | Input token cap for any single model call. See [Limits per question](#limits-per-question).                         |
| `LLM_MAX_TOOL_CALLS_PER_ROUND`  | `4`                | Tool calls run from one model response; extras are refused.                                                         |
| `LLM_MAX_TOOL_ROUNDS`           | `8`                | Maximum model↔tool round trips for one question.                                                                    |
| `LLM_TOKENS_PER_QUESTION`       | `150000`           | Total tokens one question may use across all its model calls; `0` for no cap. See [Limits per question](#limits-per-question). |
| `HISTORY_MESSAGES`              | `40`               | Thread messages sent as context (max 100).                                                                          |
| `GITHUB_REPO`                   | _(empty)_          | `owner/name`, e.g. `solidDoWant/tug2`.                                                                              |
| `GITHUB_APP_ID`                 | _(empty)_          | The GitHub App's ID.                                                                                                |
| `GITHUB_APP_PRIVATE_KEY_FILE`   | _(empty)_          | Path to the app's private key (`.pem`). Or pass the PEM itself in `GITHUB_APP_PRIVATE_KEY`.                         |
| `GITHUB_APP_INSTALLATION_ID`    | _(looked up)_      | Optional; skips the startup lookup of the app's installation on the repo.                                           |
| `GITHUB_ISSUE_LABELS`           | `from-discord`     | Comma-separated labels added to every filed issue.                                                                  |
| `GITHUB_BUG_LABEL`              | `bug`              | Extra label for bug reports (empty for none).                                                                       |
| `GITHUB_FEATURE_LABEL`          | `enhancement`      | Extra label for feature requests (empty for none).                                                                  |
| `RATE_LIMIT_QUESTIONS_PER_HOUR` | `20`               | Per user; `0` disables.                                                                                             |
| `RATE_LIMIT_ISSUES_PER_DAY`     | `5`                | Issues each user can file per day; `0` disables.                                                                    |
| `MAX_CONCURRENT_QUESTIONS`      | `4`                | Questions answered at once across everyone; others wait. Each user also gets one question at a time.                |
| `USER_LIMITS` / `_FILE`         | _(empty)_          | Per-user overrides of the two limits above; see [Per-user limits](#per-user-limits).                                |
| `READABLE_CHANNELS` / `_FILE`   | _(empty)_          | Extra channels the model may read; see [Reading other channels](#reading-other-channels).                           |
| `A2S_TIMEOUT_MS`                | `3000`             | Timeout for server queries.                                                                                         |
| `HEALTH_ADDR`                   | `:8080`            | Serves `/livez` (process up) and `/readyz` (connected to Discord).                                                  |

`SERVERS` example, with a separate stats-api instance per server:

```json
[
  {
    "name": "main",
    "description": "the main public server",
    "stats_api_url": "http://stats-api-main.insurgency.svc",
    "public_stats_api_url": "https://stats.example.com",
    "query_address": "game.example.com:27000"
  },
  {
    "name": "test",
    "description": "the test server, where changes are tried before main",
    "stats_api_url": "http://stats-api-test.insurgency.svc",
    "public_stats_api_url": "https://test-stats.example.com",
    "query_address": "game.example.com:27001"
  }
]
```

- `stats_api_url` is the address the bot itself calls, typically in-cluster.
  It is never shown to users or to the model.
- `public_stats_api_url` is where users can reach the same instance. The bot
  shares it, plus its `/docs` page, when someone asks how to use the API.
  Leave it out to keep that server's API private; the bot will say so.
- Both URLs include any `BASE_PATH` that instance runs with.
- Leave `stats_api_url` or `query_address` empty to turn off stats or live
  status for a server. `query_address` is the game port: main is 27000 and
  test is 27001, not Source's default 27015.

All configuration errors are reported together at startup.

## Limits per question

Every model call resends the whole conversation so far, including everything
the tools have returned. A question that reads a lot therefore costs more
with each step. These limits bound one question:

| Limit                               | Default | Setting                        |
| ----------------------------------- | ------- | ------------------------------ |
| Tokens across all its model calls   | 150,000 | `LLM_TOKENS_PER_QUESTION`      |
| Input tokens for any single call    | 80,000  | `LLM_MAX_CONTEXT_TOKENS`       |
| Output tokens per call (incl. thinking) | 8,000 | `LLM_MAX_TOKENS`             |
| Model↔tool rounds                   | 8       | `LLM_MAX_TOOL_ROUNDS`          |
| Tool calls run from one response    | 4       | `LLM_MAX_TOOL_CALLS_PER_ROUND` |
| Time                                | 3 min   | -                              |

Individual tools are bounded too: `read_channel` returns at most 50 messages
and about 40,000 characters, leaderboard pages are at most 25 rows, and any
stats response is cut at 64 KB.

After running a round's tools, the bot estimates the next call's size
(everything so far plus the new results). If that call would push the
question over its token budget or past the per-call cap, it doesn't happen.
The results are withheld and replaced with a note telling the model to answer
from what it already has and say what it couldn't check, which it does in
one final call. If it asks for more lookups anyway, the bot replies with
whatever text it has rather than looping. That final call
is never larger than the previous one plus its output. So "summarise the last
500 changelog posts" gets a partial answer covering the most recent ones,
not a silent cut-off or a runaway bill.

### Worst-case cost

With the defaults, one question processes at most about 254,000 tokens:
the 150,000 budget, plus one call's output of overshoot, plus the final call
(at most 80,000 + 8,000 input and 8,000 output). The 80,000 per-call cap keeps
every call under the 100,000-token prompt size above which Claude Haiku 5.5
charges five times as much. At Haiku 5.5's rates ($0.10 in /
$0.50 out per million tokens, and $0.125 for input written to the cache), the
most a single question can cost is about **6 cents**. That assumes the worst
case of no cache hits. A typical stats question is two calls of a few thousand tokens,
about a tenth of a cent. `LLM_EFFORT` changes how much the model thinks,
which mostly affects typical cost; the limits above set the ceiling.

These figures are for Haiku 5.5. With a bigger `LLM_MODEL`, multiply by its
price, and lower the limits to match.

### Prompt caching

Requests use prompt caching, so repeated context is billed at a tenth of the
input price instead of in full:

- **Tools and system prompt:** identical on every request, so after the first
  question every call reads them from the cache.
- **Within a question:** each tool round resends the conversation so far.
  Automatic caching puts a breakpoint at the end of every request, so each
  round reads everything before it from the cache and pays full price only for
  the new tool results.
- **Follow-ups in a thread:** the history is rebuilt from the thread on every
  message. Each user message carries its own posting time, so earlier messages
  render to the same bytes every time and the shared history is read from the
  cache. The previous question's tool calls aren't part of the rebuilt
  history, so the cache covers the history up to the bot's last reply.
- **Lifetime:** 5 minutes, refreshed on every read. A follow-up after a
  longer pause rebuilds the cache (a 1.25× write on the history). At Haiku
  prices that costs less than a 1-hour cache would.
- **Settings:** `tool_choice`, thinking and effort never change between
  requests, since changing any of them would invalidate the cached
  conversation.
- **Long threads:** once a thread has more than `HISTORY_MESSAGES` messages,
  the oldest drop off the front, so only the tools, system prompt and the
  thread's first message stay cached.

Each model call is logged with its token usage (`input_tokens`,
`cache_read_tokens`, `cache_write_tokens`, `output_tokens`) and the running
total for the question (`question_tokens`), so cache hit rates can be checked
from the logs. A question that hits a limit logs a warning saying which one.
The token limits count cached tokens too, so they bound size and cost
conservatively.

## Safety notes

- The model only has the tools above. Stats and server status are read-only,
  and issues need a human click.
- Player names from the server query, issue titles and stats are passed to the
  model as data; the system prompt tells it not to follow instructions in them.
  Even if it did, the worst case is a misleading answer or a draft the reporter
  has to confirm.
- GitHub access is a GitHub App limited to issues on one repository. Nothing
  is filed as a person.
- `read_channel` can only read the channels in `READABLE_CHANNELS`. Their
  text is treated as data, like everything else the tools return.

## Development

```sh
make test     # unit tests
make binary   # build for the local platform
make push VERSION=x.y.z CONTAINER_REGISTRY=<registry>/tug2
```

Integration tests run against real services when their variables are set:

```sh
# stats tools, against the stats-api dev stack (cd ../stats-api && docker compose up, then seed it)
STATS_API_URL=http://localhost:8080 go test -run TestToolsAgainstStatsAPI ./...

# live server query
A2S_ADDR=host:27000 go test -run TestQueryServerLive -v ./...
```
