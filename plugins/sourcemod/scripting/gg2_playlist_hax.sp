#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required

public Plugin myinfo =
{
    name        = "[GG2 PlaylistHax] GG Playlist Hax",
    author      = "zachm",
    version     = "0.0.1",
    description = "Get other maps on default nwi/coop playlist",
    url         = "http://insurgency.lol"
};

public void OnMapStart()
{
    CreateTimer(0.1, Timer_PlaylistEnable, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    char mapname[32];
    GetCurrentMap(mapname, sizeof(mapname));

    char sGamemode[32];
    GetConVarString(FindConVar("mp_gamemode"), sGamemode, sizeof(sGamemode));

    if (StrEqual(sGamemode, "checkpoint")) return;

    LogError("Current map \"%s\" has run on \"%s\" game mode (not supported/allowed). changing to default map...", mapname, sGamemode);
    ServerCommand("map embassy_coop checkpoint");
    return;
}

Action Timer_PlaylistEnable(Handle timer)
{
    GameRules_SetProp("m_bPlaylistEnabled", true);
    return Plugin_Continue;
}
