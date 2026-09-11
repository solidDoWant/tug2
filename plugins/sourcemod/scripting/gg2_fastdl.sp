// Advertises this repo's downloadable content to clients.
//
// sv_downloadurl is only half of a fast download. The other half is the downloadables string table:
// a client only ever fetches files the server has put in it, so content sitting on the fastdl host
// that nothing advertises is never requested. This puts every file in the fastdl image into that
// table on map start.
//
// WHY THE LIST IS GENERATED RATHER THAN WRITTEN
//
// configs/fastdl_downloadables.txt is produced by the same Dockerfile stage that builds the fastdl
// image, from the same tree, and copied into both. The two therefore cannot drift: if a file is
// served it is advertised, and if it is advertised it is served. A hand-maintained list would go
// stale the first time somebody added a material and forgot.
//
// WHY THIS EXISTS AT ALL
//
// This content used to ship as a Steam Workshop item, which cannot update an item a client already
// has unless that item contains the map being loaded - CWorkshopItem::CheckForUpdate has exactly one
// caller and it is gated on ContainsMap(), so a scripts-or-materials-only item is frozen at whatever
// version a client first downloaded. The engine's own download path has no such problem:
// CL_ShouldRedownloadFile does a CRC comparison, and it lives in the same binary as the consistency
// check rather than in a subsystem the engine cannot see.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name        = "[GG2 FastDL] Downloadable content",
    author      = "solidDoWant",
    description = "Adds this repo's client content to the downloadables table",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

#define LIST_FILE   "configs/fastdl_downloadables.txt"

ConVar g_cvEnabled;

public void OnPluginStart()
{
    CreateConVar("sm_fastdl_version", PLUGIN_VERSION, "FastDL content version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    // Advertising costs nothing when sv_downloadurl is empty - the client just falls back to the
    // game channel - so this defaults on and the switch is here for turning it off during a
    // fastdl outage rather than for turning it on.
    g_cvEnabled = CreateConVar("sm_fastdl_enabled", "1", "Advertise this repo's content to clients.", _, true, 0.0, true, 1.0);
}

// The table is rebuilt per map, so the entries have to go back in every time.
public void OnMapStart()
{
    if (!g_cvEnabled.BoolValue) return;

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), LIST_FILE);

    File list = OpenFile(path, "r");
    if (list == null)
    {
        LogError("Missing %s - no content will be advertised, so clients will not fetch it", path);
        return;
    }

    int added = 0;
    char line[PLATFORM_MAX_PATH];

    while (list.ReadLine(line, sizeof(line)))
    {
        TrimString(line);
        if (line[0] == '\0' || line[0] == '/' || line[0] == '#') continue;

        AddFileToDownloadsTable(line);
        added++;
    }

    delete list;

    LogMessage("Advertised %d downloadable file(s)", added);
}
