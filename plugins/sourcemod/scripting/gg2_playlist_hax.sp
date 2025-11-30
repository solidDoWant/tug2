#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required


public Plugin myinfo = {
    name = "[GG2 PlaylistHax] GG Playlist Hax",
    author = "zachm",
    version = "0.0.1",
    description = "Get other maps on default nwi/coop playlist",
    url = "http://insurgency.lol"
};

public void OnPluginStart() {
    LogMessage("[INS DEV] GG Playlist Hax started!!");
}

public void OnMapStart() {
    LogMessage("[INS DEV] GG Playlist Hax started (OnMapStart)!!");
    CreateTimer(0.1, Timer_PlaylistEnable, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    char mapname[32];
    GetCurrentMap(mapname, sizeof(mapname));
    char sGamemode[32];
    GetConVarString(FindConVar("mp_gamemode"), sGamemode, sizeof(sGamemode));
    bool ModeCheckpoint = StrEqual(sGamemode, "checkpoint");
    
    if (!ModeCheckpoint) {
        LogError("Current map \"%s\" has run on \"%s\" game mode (not supported/alloowed). changing to default map...", mapname, sGamemode);
        ServerCommand("map market_coop checkpoint");
        return;
    }
}

Action Timer_PlaylistEnable(Handle timer) {
    GameRules_SetProp("m_bPlaylistEnabled", true);
    return Plugin_Continue;
}