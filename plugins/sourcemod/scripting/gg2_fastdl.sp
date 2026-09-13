// Advertises this repo's downloadable content to clients, and keeps mp_theater_override in step
// with what the fastdl host is serving.
//
// sv_downloadurl is only half of a fast download. The other half is the downloadables string table:
// a client only fetches files the server has put in it, so unadvertised content is never requested.
//
// The manifest (fetched from the fastdl host at every map change, so content can be republished
// without touching the server - see fastdl/README.md) is the authority on two things:
//
//   files    - everything to advertise. A cached copy on disk is applied first, so the table is
//              never empty while the fetch is in flight.
//   theater  - the content-hashed base name the served theaters use, which the server must match
//              exactly.
//
// WHY THE THEATER NAME HAS TO TRACK THE CONTENT
//
// Theaters are the only content here the engine enforces outright. The game DLL calls ForceExactFile
// on <mp_theater_override>.theater and <...>_<gamemode>.theater, which enters them in the
// downloadables table with CONSISTENCY_EXACT and a CRC; the client re-CRCs its local copy in
// CClientState::ConsistencyCheck at the end of CL_FullyConnected and kicks itself with "Server is
// enforcing consistency for this file" on a mismatch. (The CRC is CRC-32 with no final xor, if you
// ever need to reproduce one by hand.)
//
// Insurgency added a .theater-specific escape hatch - a predicate that re-downloads a .theater whose
// local CRC differs, instead of the engine's usual "file exists, skip it". It fires, and the file
// arrives, but too late for the connect that triggered it: the client fails once and succeeds on
// retry. That is the long-standing "error on first join, works the second time" report, and it
// cannot be fixed server-side. Content-hashed theater names avoid it entirely - a path no client has
// seen has nothing stale to invalidate.
//
// WHY THIS FORCES A MAP CHANGE
//
// The cvar is read when the theater loads during map load, so setting it mid-map does nothing until
// the next one - and for the rest of the current map the server keeps enforcing the PREVIOUS hash,
// which the fastdl host no longer serves. Joins in that window cannot satisfy consistency at all.
// Ending the map once the new theater is on disk shrinks that window to a map load, and costs
// nothing in practice because the manifest is only fetched at map start. sm_fastdl_theater_changelevel
// can restrict this to empty servers, or disable it and leave joins broken until the next map.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <ripext>

#define PLUGIN_VERSION "2.0.0"

public Plugin myinfo =
{
    name        = "[GG2 FastDL] Downloadable content",
    author      = "solidDoWant",
    description = "Fetches the fastdl manifest and advertises its content; keeps the theater in step",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

// Applied at map start before the fetch, so a fastdl outage or a slow response degrades to "last
// known good list" rather than "advertise nothing".
#define CACHE_FILE      "configs/fastdl_manifest_cache.txt"
#define MANIFEST_NAME   "manifest.json"
#define THEATER_PREFIX  "scripts/theaters/"
#define THEATER_SUFFIX  ".theater"

// Downloads land here first and are renamed into place only on a 2xx, so an interrupted transfer
// cannot leave a truncated file that FileExists() then reports as present forever.
#define PART_SUFFIX     ".part"

ConVar g_cvEnabled;
ConVar g_cvChangeLevel;
ConVar g_cvDownloadUrl;
ConVar g_cvTheater;

// Bumped on every map start. A response carrying a stale value is from a map that has already
// ended: its file list is for the wrong map and its theater download would race the current one.
int  g_iGeneration = 0;

char g_sWantTheater[PLATFORM_MAX_PATH];

// The name the last forced map change was for. Belt and braces against a loop: if the cvar somehow
// did not stick, this stops the plugin changing level again for the same theater on every map.
char g_sForcedFor[PLATFORM_MAX_PATH];
int  g_iPendingDownloads  = 0;
bool g_bDownloadFailed    = false;

public void OnPluginStart()
{
    CreateConVar("sm_fastdl_version", PLUGIN_VERSION, "FastDL content version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    // Advertising costs nothing when sv_downloadurl is empty - the client just falls back to the
    // game channel - so this defaults on and the switch is here for turning it off during a fastdl
    // outage rather than for turning it on.
    g_cvEnabled     = CreateConVar("sm_fastdl_enabled", "1", "Advertise the fastdl manifest's content to clients.", _, true, 0.0, true, 1.0);

    // A new theater name only takes effect on a map load, and until then clients cannot join - see
    // the header.
    //
    // Defaults to 2 because the manifest is only fetched at map start, so this fires seconds into a
    // fresh map rather than part way through a round: players get a second map load back to back,
    // not an interrupted game. That is a far better trade than leaving joins broken until the map
    // happens to end.
    //   0 - never; wait for the next natural map change
    //   1 - only when no humans are connected
    //   2 - always, immediately
    g_cvChangeLevel = CreateConVar("sm_fastdl_theater_changelevel", "2", "Force a map change when the theater name changes: 0 never, 1 only when empty, 2 always.", _, true, 0.0, true, 2.0);

    g_cvDownloadUrl = FindConVar("sv_downloadurl");
    g_cvTheater     = FindConVar("mp_theater_override");

    if (g_cvDownloadUrl == null) LogError("sv_downloadurl not found - cannot locate the manifest");
    if (g_cvTheater == null)     LogError("mp_theater_override not found - the theater cannot be kept in step");

    ApplyDownloadUrl();
}

/* Builds sv_downloadurl from the -fastdl_host command-line parameter.
 *
 * WHY THE HOST ARRIVES WITHOUT A SCHEME. "+sv_downloadurl <url>" cannot work: the engine builds a
 * console command out of each "+cvar value" pair, and "//" in an UNQUOTED console token is a
 * comment, so an https:// URL is stored as just "https:". Quoting it in the ENTRYPOINT does not help
 * either - the engine strips the quotes off the argv element before building the command. Measured
 * all three ways:
 *
 *   argv  +sv_downloadurl https://host/path     -> "https:"
 *   argv  +sv_downloadurl "https://host/path"   -> "https:"
 *   ConVar.SetString("https://host/path")       -> "https://host/path"
 *
 * So the scheme is added here instead, where SetString bypasses the console entirely. -fastdl_host
 * carries host plus optional path and nothing the tokenizer can eat. It is a command-line parameter
 * rather than a cvar because a SourceMod cvar does not exist yet when the engine processes "+"
 * arguments, and a parameter rather than a cfg line because the host name is a secret and must not
 * be committed.
 *
 * https is hard-coded: the engine downloads through ISteamHTTP, so it inherits Steam's TLS.
 */
static void ApplyDownloadUrl()
{
    if (g_cvDownloadUrl == null) return;

    char host[PLATFORM_MAX_PATH];
    GetCommandLineParam("-fastdl_host", host, sizeof(host), "");
    TrimString(host);

    // Absent: leave whatever is already set, so the cvar can still be driven by hand when testing.
    if (host[0] == '\0') return;

    /* An EMPTY value collapses on the command line - the engine joins the arguments into one string,
     * so "-fastdl_host" followed by "" is indistinguishable from "-fastdl_host" followed by the next
     * argument, and that argument is what lands here. (The same thing is already visible with an
     * unset GSLT: "+sv_setsteamaccount  +rcon_password ...".) Anything starting with - or + is that
     * case, not a host name. */
    if (host[0] == '-' || host[0] == '+')
    {
        LogMessage("-fastdl_host is empty - no fast download configured");
        return;
    }

    // A scheme here means someone passed a full URL, which cannot have survived the command line -
    // so the value is already damaged and prepending to it would produce nonsense. Only "//"
    // disqualifies: a ":" is legitimate in host:port.
    if (StrContains(host, "//") != -1)
    {
        LogError("-fastdl_host must be a host with no scheme (got \"%s\") - pass e.g. host.example/test, not https://host.example/test", host);
        return;
    }

    int len = strlen(host);
    while (len > 0 && host[len - 1] == '/') host[--len] = '\0';
    if (len == 0) return;

    char url[PLATFORM_MAX_PATH];
    Format(url, sizeof(url), "https://%s", host);
    g_cvDownloadUrl.SetString(url);

    LogMessage("sv_downloadurl set from -fastdl_host: %s", url);
}

public void OnMapStart()
{
    g_iGeneration++;

    if (!g_cvEnabled.BoolValue) return;

    /* Re-applied every map, not just at load, because server.cfg is re-executed on EVERY map change
     * and a bare "sv_downloadurl" line in it would otherwise blank the value for the rest of the
     * server's life. Same trap that keeps mp_theater_override out of server.cfg. Idempotent: it sets
     * the cvar to the string it already holds. */
    ApplyDownloadUrl();

    ApplyCachedList();
    FetchManifest();
}

/* The downloadables table is rebuilt per map, so the cached list goes back in every time. This is a
 * best effort: it is the previous map's list, which is the right answer whenever the manifest has
 * not changed and a strictly better one than nothing when it has.
 */
static void ApplyCachedList()
{
    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), CACHE_FILE);

    File cache = OpenFile(path, "r");
    if (cache == null) return;

    int  added = 0;
    char line[PLATFORM_MAX_PATH];

    while (cache.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0' || line[0] == '#' || line[0] == '/') continue;

        AddFileToDownloadsTable(line);
        added++;
    }

    delete cache;

    if (added > 0) LogMessage("Advertised %d file(s) from the cached manifest", added);
}

/* Remembers the value already complained about, so a permanently broken URL costs one line rather
 * than one per map change. */
static char g_sWarnedUrl[PLATFORM_MAX_PATH];

static bool GetBaseUrl(char[] buffer, int maxlen)
{
    if (g_cvDownloadUrl == null) return false;

    g_cvDownloadUrl.GetString(buffer, maxlen);
    TrimString(buffer);
    if (buffer[0] == '\0') return false;

    /* A URL with a scheme and nothing after it is not a typo, it is the engine eating the value.
     * "//" in an UNQUOTED console token is a comment, and "+cvar value" from the command line is
     * unquoted, so "+sv_downloadurl https://host/path" stores "https:" - silently, and with it
     * every download and the hashed theater name this plugin exists to apply. Worth a loud line:
     * the symptom otherwise surfaces as clients failing theater consistency, several layers away.
     *
     * Detected as "no // anywhere" rather than by matching schemes, so it also catches whatever
     * else strips it. A real URL always has one; a bare host with no scheme is not valid here. */
    if (StrContains(buffer, "//") == -1)
    {
        if (!StrEqual(g_sWarnedUrl, buffer))
        {
            strcopy(g_sWarnedUrl, sizeof(g_sWarnedUrl), buffer);
            LogError("sv_downloadurl is \"%s\" - the \"//\" has been stripped, so no content can be \
downloaded and the theater cannot be switched. An unquoted // is a console comment: pass the value \
from a cfg file with the value quoted (see sv_downloadurl in cfg/server.cfg) - the command line \
cannot carry it, the engine strips the quotes off an argv element and then truncates.", buffer);
        }
        return false;
    }

    g_sWarnedUrl[0] = '\0';

    // A trailing slash would produce "...//manifest.json". Harmless on most servers, a 404 on some.
    int len = strlen(buffer);
    while (len > 0 && buffer[len - 1] == '/') buffer[--len] = '\0';

    return len > 0;
}

static void FetchManifest()
{
    char base[PLATFORM_MAX_PATH];
    if (!GetBaseUrl(base, sizeof(base)))
    {
        // Not an error: an empty sv_downloadurl is a server that deliberately serves no content.
        return;
    }

    char url[PLATFORM_MAX_PATH];
    Format(url, sizeof(url), "%s/%s", base, MANIFEST_NAME);

    HTTPRequest request = new HTTPRequest(url);
    request.Get(OnManifestReceived, g_iGeneration);
}

public void OnManifestReceived(HTTPResponse response, any generation)
{
    if (generation != g_iGeneration) return;

    if (response.Status != HTTPStatus_OK)
    {
        LogError("Manifest fetch returned HTTP %d - keeping the cached list", view_as<int>(response.Status));
        return;
    }

    JSONObject manifest = view_as<JSONObject>(response.Data);
    if (manifest == null)
    {
        LogError("Manifest is not a JSON object - keeping the cached list");
        return;
    }

    if (!manifest.HasKey("files"))
    {
        LogError("Manifest has no \"files\" array - keeping the cached list");
        delete manifest;
        return;
    }

    JSONArray files = view_as<JSONArray>(manifest.Get("files"));

    // Rewritten wholesale rather than merged: a file dropped from the manifest must stop being
    // advertised, and the table itself is rebuilt on the next map anyway.
    char cachePath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, cachePath, sizeof(cachePath), CACHE_FILE);
    File cache = OpenFile(cachePath, "w");
    if (cache == null) LogError("Cannot write %s - the next map start will have no list to fall back on", cachePath);

    int  count = files.Length;
    int  added = 0;
    char entry[PLATFORM_MAX_PATH];

    for (int i = 0; i < count; i++)
    {
        if (!files.GetString(i, entry, sizeof(entry))) continue;

        TrimString(entry);
        if (entry[0] == '\0') continue;

        AddFileToDownloadsTable(entry);
        added++;

        if (cache != null) cache.WriteLine("%s", entry);
    }

    if (cache != null) delete cache;

    LogMessage("Advertised %d file(s) from the manifest", added);

    ReconcileTheater(manifest, files);

    delete files;
    delete manifest;
}

/* Makes sure every theater file the manifest names is on disk, then points mp_theater_override at
 * the manifest's base name.
 *
 * The name is only applied once the files are actually present: pointing the cvar at a theater the
 * server cannot open would take the next map down, which is far worse than staying a generation
 * behind.
 */
static void ReconcileTheater(JSONObject manifest, JSONArray files)
{
    if (g_cvTheater == null) return;

    char want[PLATFORM_MAX_PATH];
    if (!manifest.HasKey("theater") || !manifest.GetString("theater", want, sizeof(want)) || want[0] == '\0')
    {
        // A manifest without a theater is a content-only one. Nothing to reconcile.
        return;
    }

    char current[PLATFORM_MAX_PATH];
    g_cvTheater.GetString(current, sizeof(current));

    if (StrEqual(current, want, false)) return;

    strcopy(g_sWantTheater, sizeof(g_sWantTheater), want);
    g_iPendingDownloads = 0;
    g_bDownloadFailed   = false;

    char base[PLATFORM_MAX_PATH];
    if (!GetBaseUrl(base, sizeof(base))) return;

    // Only the files belonging to the wanted theater: the manifest also carries the previous
    // generation and the unhashed fallback, and fetching those would be wasted transfers.
    char wantBase[PLATFORM_MAX_PATH];
    Format(wantBase, sizeof(wantBase), "%s%s", THEATER_PREFIX, want);

    int  count = files.Length;
    char entry[PLATFORM_MAX_PATH];

    for (int i = 0; i < count; i++)
    {
        if (!files.GetString(i, entry, sizeof(entry))) continue;
        TrimString(entry);

        if (strncmp(entry, wantBase, strlen(wantBase), false) != 0) continue;

        int len = strlen(entry);
        int sufLen = strlen(THEATER_SUFFIX);
        if (len <= sufLen || !StrEqual(entry[len - sufLen], THEATER_SUFFIX, false)) continue;

        if (FileExists(entry)) continue;

        char url[PLATFORM_MAX_PATH];
        Format(url, sizeof(url), "%s/%s", base, entry);

        char part[PLATFORM_MAX_PATH];
        Format(part, sizeof(part), "%s%s", entry, PART_SUFFIX);

        DataPack pack = new DataPack();
        pack.WriteString(entry);
        pack.WriteString(part);
        pack.WriteCell(g_iGeneration);

        g_iPendingDownloads++;

        HTTPRequest request = new HTTPRequest(url);
        request.DownloadFile(part, OnTheaterDownloaded, pack);
    }

    if (g_iPendingDownloads == 0)
    {
        // Already on disk - a restart, or a name we fetched on an earlier map.
        ApplyTheaterName();
    }
    else
    {
        LogMessage("Fetching %d file(s) for theater \"%s\"", g_iPendingDownloads, want);
    }
}

public void OnTheaterDownloaded(HTTPStatus status, any data)
{
    DataPack pack = view_as<DataPack>(data);

    char final[PLATFORM_MAX_PATH];
    char part[PLATFORM_MAX_PATH];

    pack.Reset();
    pack.ReadString(final, sizeof(final));
    pack.ReadString(part, sizeof(part));
    int generation = pack.ReadCell();
    delete pack;

    g_iPendingDownloads--;

    if (generation != g_iGeneration)
    {
        // The map changed under us; the next map start will redo this from scratch.
        DeleteFile(part);
        return;
    }

    if (status != HTTPStatus_OK)
    {
        LogError("Download of %s returned HTTP %d - theater will stay on the current name", final, view_as<int>(status));
        DeleteFile(part);
        g_bDownloadFailed = true;
    }
    else if (!RenameFile(final, part))
    {
        LogError("Cannot rename %s into place - theater will stay on the current name", part);
        DeleteFile(part);
        g_bDownloadFailed = true;
    }

    if (g_iPendingDownloads > 0) return;

    if (g_bDownloadFailed)
    {
        LogError("Theater \"%s\" is incomplete on disk, not switching to it", g_sWantTheater);
        return;
    }

    ApplyTheaterName();
}

static void ApplyTheaterName()
{
    if (g_cvTheater == null || g_sWantTheater[0] == '\0') return;

    // Verified rather than assumed: the engine resolves <name>.theater, and if that is missing the
    // theater manager falls back to stock and every custom class goes with it.
    char probe[PLATFORM_MAX_PATH];
    Format(probe, sizeof(probe), "%s%s%s", THEATER_PREFIX, g_sWantTheater, THEATER_SUFFIX);

    if (!FileExists(probe))
    {
        LogError("%s is missing after download - not switching the theater", probe);
        return;
    }

    char current[PLATFORM_MAX_PATH];
    g_cvTheater.GetString(current, sizeof(current));
    if (StrEqual(current, g_sWantTheater, false)) return;

    g_cvTheater.SetString(g_sWantTheater);

    // Loud on purpose: this is the one thing here that changes gameplay.
    LogMessage("mp_theater_override \"%s\" -> \"%s\"", current, g_sWantTheater);

    MaybeChangeLevel();
}

static int CountHumans()
{
    int humans = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i)) humans++;
    }
    return humans;
}

/* Ends the map so the theater just downloaded actually loads, closing the window in which the server
 * enforces a hash the fastdl host no longer serves.
 */
static void MaybeChangeLevel()
{
    int mode = g_cvChangeLevel.IntValue;
    if (mode == 0)
    {
        LogMessage("Not changing level (sm_fastdl_theater_changelevel 0) - clients cannot join until the next map change");
        return;
    }

    if (StrEqual(g_sForcedFor, g_sWantTheater, false))
    {
        LogError("Already forced a map change for theater \"%s\" and it is still not active - not doing it again", g_sWantTheater);
        return;
    }

    int humans = CountHumans();
    if (mode == 1 && humans > 0)
    {
        LogMessage("Theater changed but %d player(s) are connected - waiting for the next map change rather than interrupting the round", humans);
        return;
    }

    char map[PLATFORM_MAX_PATH];
    GetCurrentMap(map, sizeof(map));

    strcopy(g_sForcedFor, sizeof(g_sForcedFor), g_sWantTheater);

    LogMessage("Changing level to %s to load theater \"%s\" (%d player(s) connected)", map, g_sWantTheater, humans);

    // Deferred a tick rather than called straight from the HTTP callback, so the request handle is
    // finished with before the level unloads under it.
    DataPack pack = new DataPack();
    pack.WriteString(map);
    CreateTimer(0.5, Timer_ChangeLevel, pack);
}

public Action Timer_ChangeLevel(Handle timer, DataPack pack)
{
    char map[PLATFORM_MAX_PATH];
    pack.Reset();
    pack.ReadString(map, sizeof(map));
    delete pack;

    ForceChangeLevel(map, "fastdl theater update");
    return Plugin_Stop;
}
