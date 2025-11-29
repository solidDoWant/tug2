#pragma semicolon 1
#pragma newdecls required
#define MAXENTITIES 2048

public Plugin myinfo = {
    name		= "[GG2 CFF] Artillery Fire support",
    author		= "rrrfffrrr // zachm",
    description	= "Fire support",
    version		= "0.0.4",
    url			= ""
};

#include <sourcemod>
#include <datapack>
#include <float>
#include <sdktools>
#include <sdkhooks>
#include <sdktools_trace>
#include <sdktools_functions>
#include <timers>
#include <discord>
#include <morecolors>

const int TEAM_SPECTATE = 1;
const int TEAM_SECURITY = 2;
const int TEAM_INSURGENT = 3;

int us_arty_smoke_weapon_int = 45;

//char US_ARTY_SMOKE_WEAPON[] = "weapon_m18_us";
char US_ARTY_ROCKET[] = "grenade_m777_us";
char US_ARTY_SMOKE[] = "grenade_m18_us";
char INS_ARTY_ROCKET[] = "grenade_m777_ins";
char INS_ARTY_SMOKE[] = "grenade_m18_ins";

const float MATH_PI = 3.14159265359;

float UP_VECTOR[3] = {-90.0, 0.0, 0.0};
float DOWN_VECTOR[3] = {90.0, 0.0, 0.0};

Handle cGameConfig;
Handle fCreateRocket;

GlobalForward ArtyThrownForward;
GlobalForward InsArtyThrownForward;

Database g_Database = null;
int gBeamSprite;

ConVar gCvarMaxSpread;
ConVar gCvarSecRoundCount;
ConVar gCvarInsRoundCount;
ConVar gCvarDelay;
ConVar gCvarCountPerRound;
ConVar g_server_id;
ConVar ins_spotter_name;
ConVar ins_callout_phrase;

int CountAvailableSupport[4];
bool gInCurrentBarrage = false;

char request_artillery_sounds[][] = {
	"requestartillery1.ogg",
    "requestartillery2.ogg",
    "requestartillery3.ogg",
    "requestartillery4.ogg",
    "requestartillery5.ogg",
    "requestartillery6.ogg",
    "requestartillery7.ogg",
    "requestartillery8.ogg",
    "requestartillery9.ogg",
    "requestartillery10.ogg",
    "requestartillery11.ogg",
    "requestartillery12.ogg"
};

char invalid_artillery_sounds[][] = {
    "invalidtarget1.ogg",
    "invalidtarget2.ogg",
    "invalidtarget3.ogg",
    "invalidtarget4.ogg",
    "invalidtarget5.ogg",
};

/*
char artillery_fired_sounds[][] = {
    "tug/arty_distant_1.wav"
};
*/


public Action SendForwardInsArtyThrown(int client) {	// tug stats forward
	Action result;
	Call_StartForward(InsArtyThrownForward);
	Call_PushCell(client);
	Call_Finish(result);
	return result;
}

public Action SendForwardArtyThrown(int client) {	// tug stats forward
	Action result;
	Call_StartForward(ArtyThrownForward);
	Call_PushCell(client);
	Call_Finish(result);
	return result;
}

public void T_Connect(Database db, const char[] error, any data) {
    if(db == null) {
        LogError("[INS Call for Fire] T_Connect returned invalid Database Handle");
        return;
    }
    g_Database = db;
    LogMessage("[INS Call for Fire] Connected to Database.");
    return;
} 

public void do_nothing(Handle owner, Handle results, const char[] error, any client) {
    if (strlen(error) != 0) {
        LogMessage("[INS Call for Fire] error: %s", error);
    }
    return;
}

public void add_throw_to_db(int client) {
    char steamId[64];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));
    char query[512];
    Format(query, sizeof(query), "UPDATE players SET arty_thrown = arty_thrown + 1 WHERE steamId = '%s' AND server_id = '%i'",steamId, g_server_id.IntValue);
    SQL_TQuery(g_Database, do_nothing, query);
    LogMessage("[INS Call for Fire] Incremented arty_thrown for %N", client);
}



public void OnPluginStart() {
    cGameConfig = LoadGameConfigFile("insurgency.games");
    if (cGameConfig == INVALID_HANDLE) {
        SetFailState("Fatal Error: Missing File \"insurgency.games\"!");
    }
    Database.Connect(T_Connect, "insurgency_stats");

    PrecacheGeneric("particles/gas_grenades.pcf", true);
    PrecacheEffect("ParticleEffect");
    PrecacheParticleEffect("smokegrenade_color_green");
    PrecacheParticleEffect("smokegrenade_color_pink");
    StartPrepSDKCall(SDKCall_Static);
    PrepSDKCall_SetFromConf(cGameConfig, SDKConf_Signature, "CBaseRocketMissile::CreateRocketMissile");
    PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
    PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef);
    PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_ByValue);
    fCreateRocket = EndPrepSDKCall();
    if (fCreateRocket == INVALID_HANDLE) {
        SetFailState("Fatal Error: Unable to find CBaseRocketMissile::CreateRocketMissile");
    }

    gCvarMaxSpread = CreateConVar("sm_firesupport_spread", "600.0", "Max spread.", FCVAR_PROTECTED, true, 10.0);
    gCvarSecRoundCount = CreateConVar("sm_firesupport_sec_shell_num", "15.0", "Shells to fire.", FCVAR_PROTECTED, true, 1.0);
    gCvarInsRoundCount = CreateConVar("sm_firesupport_ins_shell_num", "3.0", "Shells to fire.", FCVAR_PROTECTED, true, 1.0);
    gCvarDelay = CreateConVar("sm_firesupport_delay", "7.0", "Min delay to first shell.", FCVAR_PROTECTED, true, 1.0);
    gCvarCountPerRound = CreateConVar("sm_firesupport_count", "4", "Count of available support per rounds(0 = disable)", FCVAR_PROTECTED, true, 0.0);
    ins_spotter_name = CreateConVar("sm_ins_spotter_name", "Achmed", "Name of ins who cannot see the smoke", FCVAR_PROTECTED, false);
    ins_callout_phrase = CreateConVar("sm_ins_callout_phrase", "!!ALLAHU AKBAR!!", "Phrase INS prints to chat on rocket barrage", FCVAR_PROTECTED, false);


    ArtyThrownForward = new GlobalForward("Arty_Thrown", ET_Event, Param_Cell);
    InsArtyThrownForward = new GlobalForward("Ins_Arty_Thrown", ET_Event, Param_Cell);

    HookEvent("round_start", Event_RoundStart);
    HookEvent("grenade_detonate", Event_GrenadeDetonate);
    HookEvent("grenade_thrown", Event_GrenadeThrown);
    HookEvent("weapon_deploy", Event_WeaponDeploy);
    //HookEvent("player_death", Event_PlayerDeath_Pre, EventHookMode_Pre);
    //HookEvent("player_connect_full", Event_PlayerConnectFull);
    AutoExecConfig(true, "gg_cff");
    InitSupportCount();
    LoadTranslations("tug.phrases");
}

/*
public void OnConfigsExecuted() {
    char buffer[80];
    for (int i = 0; i < sizeof(request_artillery_sounds); i++) {
        Format(buffer, sizeof(buffer), "sound/m777/requestartillery/%s", request_artillery_sounds[i]);
        AddFileToDownloadsTable(buffer);
    }
    for (int i = 0; i < sizeof(invalid_artillery_sounds); i++) {
        Format(buffer, sizeof(buffer), "sound/m777/invalid/%s", invalid_artillery_sounds[i]);
        AddFileToDownloadsTable(buffer);
    }
    //AddFileToDownloadsTable(artillery_fired_sounds[0]);
}
*/
public void OnAllPluginsLoaded() {
    g_server_id = FindConVar("gg_stats_server_id");
}

void PrecacheSoundNumbers(const char[] soundprefix, const char[] soundpost, int number_begin, int number_end, bool zeroforlownumber = false)
{
    char soundfileformat[512];
    for (int i = number_begin;i <= number_end;i++) {
        if (zeroforlownumber && i < 10 && i > -1) {
            Format(soundfileformat, sizeof(soundfileformat), "%s0%d%s", soundprefix, i, soundpost);
        }
        else {
            Format(soundfileformat, sizeof(soundfileformat), "%s%d%s", soundprefix, i, soundpost);
        }
        PrecacheSound(soundfileformat);
    }
    return;
}

// actions to track whether player has smoke particles downloaded, reconnect them if they don't //
public Action Event_PlayerConnectFull(Handle event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (IsFakeClient(client)) {
        return Plugin_Continue;
    }
    char steamId[64];
    char query[512];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));
    Format(query, sizeof(query), "SELECT has_smoke FROM players WHERE steamId = '%s' LIMIT 1", steamId);
    SQL_TQuery(g_Database, check_if_player_has_smoke, query, client);
    return Plugin_Continue;
}

public void update_player_has_smoke(int client) {
    if (IsFakeClient(client)) {
        return;
    }
    char steamId[64];
    char query[512];
    GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId));
    Format(query, sizeof(query), "UPDATE players SET has_smoke = 1 WHERE steamId = '%s'", steamId);
    SQL_TQuery(g_Database, do_nothing, query, client);
    return;
}

public void check_if_player_has_smoke(Handle owner, Handle results, const char[] error, any client)
{
    if(results == INVALID_HANDLE) {
        LogToFile("wtf.log", "check if has_smoke results query failed");
        delete results;
        return;
    }
    if (!IsClientInGame(client)) {
        delete results;
        return;
    }
    while(SQL_FetchRow(results)) {
        int has_smoke = SQL_FetchInt(results, 0);
        if (has_smoke == 0) {
            LogMessage("[INS Call For Fire] Reconnecting %N since they do not have smoke particles", client);
            update_player_has_smoke(client);
            ReconnectClient(client);
            delete results;
            return;
        }
        LogMessage("[INS Call For Fire] %N has smoke particles, moving along", client);
    }
    delete results;
    return;
}
// end of actions to track whether player has smoke particles //



public void OnMapStart() {
    gBeamSprite = PrecacheModel("sprites/laserbeam.vmt");
    PrecacheModel("models/weapons/upgrades/a_projectile_m203.mdl", true);
    PrecacheSound("tug/arty_distant_1.wav");
    PrecacheSoundNumbers("m777/invalid/invalidtarget", ".ogg", 1, sizeof(invalid_artillery_sounds), false);
    PrecacheSoundNumbers("m777/requestartillery/requestartillery", ".ogg", 1, sizeof(request_artillery_sounds), false);
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    InitSupportCount();
    return Plugin_Continue;
}


// trans --> arty_calls_left (CountAvailableSupport[TEAM_SECURITY], gCvarCountPerRound.IntValue)
public Action Event_WeaponDeploy(Event event, const char[] name, bool dontBroadcast) {
    int weapon_id = GetEventInt(event, "weaponid");
    if (weapon_id == us_arty_smoke_weapon_int) {
        int client = GetClientOfUserId(GetEventInt(event, "userid"));
        //char hintTextDisplay[128];
        //Format(hintTextDisplay, sizeof(hintTextDisplay), "%i/%i Arty calls left", CountAvailableSupport[TEAM_SECURITY], gCvarCountPerRound.IntValue);
        PrintHintText(client, "%T", "arty_calls_left", client, CountAvailableSupport[TEAM_SECURITY], gCvarCountPerRound.IntValue);
        //PrintHintText(client, hintTextDisplay);
    }
    return Plugin_Continue;
}

/*
public void OnClientPutInServer(int client) {
    if (!IsFakeClient(client)) {
        SDKHook(client, SDKHook_WeaponSwitchPost, OnWeaponSwitchPost);
    }
}

public void OnWeaponSwitchPost(int client, int weapon) {
    char weaponname[64];
    GetEdictClassname(weapon, weaponname, 64);
    if (StrEqual(weaponname, US_ARTY_SMOKE_WEAPON, false)) {
        char hintTextDisplay[128];
        Format(hintTextDisplay, sizeof(hintTextDisplay), "%i/%i Arty calls left", CountAvailableSupport[TEAM_SECURITY], gCvarCountPerRound.IntValue);
        PrintHintText(client, hintTextDisplay);
    }
}
*/

char[] nade_type_from_id(int nade_id) {
    char grenade_name[32];
    GetEntityClassname(nade_id, grenade_name, sizeof(grenade_name));
    return grenade_name;
}

// handle yells when throwing
// trans --> no_arty_left
public Action Event_GrenadeThrown(Handle event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    int thrower_team = GetClientTeam(client);
    int nade_id = GetEventInt(event, "entityid");
    if (nade_id > -1 && client > -1) {
        if (IsPlayerAlive(client)) {
            char grenade_name[32];
            GetEntityClassname(nade_id, grenade_name, sizeof(grenade_name));
            if (StrEqual(grenade_name, US_ARTY_SMOKE)) {
                if ((thrower_team == TEAM_SECURITY) && (CountAvailableSupport[TEAM_SECURITY] == 0)) {
                    PrintHintText(client, "%T", "no_arty_left", client);
                    //PrintHintText(client, "Out of artillery rounds, you're on your own");
                    CPrintToChatAll("{palegreen}FDC:{default} %t", "no_arty_left");
                    //CPrintToChatAll("{palegreen}FDC:{default} Out of rounds, you're on your own");
                    return Plugin_Handled;
                }
                if (thrower_team == TEAM_SECURITY) {
                    //EmitSoundToAll("player/voice/radial/security/leader/suppressed/holdposition1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
                    //PlayRequestSoundToAll(client);
                    char sSoundFile[128];
                    Format(sSoundFile, sizeof(sSoundFile), "m777/requestartillery/requestartillery%d.ogg", GetRandomInt(1, sizeof(request_artillery_sounds)));
                    EmitSoundToAll(sSoundFile, client, SNDCHAN_STATIC, _, _, 0.65);
                } else {
                    EmitSoundToAll("player/voice/radial/insurgents/leader/suppressed/holdposition1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
                }
            } else if (StrEqual(grenade_name, INS_ARTY_SMOKE)) {
                if (thrower_team == TEAM_SECURITY) {
                    EmitSoundToAll("player/voice/radial/security/leader/suppressed/holdposition1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
                } else {
                    EmitSoundToAll("player/voice/radial/insurgents/leader/suppressed/holdposition1.ogg", client, SNDCHAN_VOICE, _, _, 1.0);
                }
            }

        }
    }
    return Plugin_Handled;
}

// trans nofire out arty_smoke_detonate_nofire_out
// trans nofire ongoing mission arty_smoke_detonate_nofire_ongoing
public Action Event_GrenadeDetonate(Handle event, const char[] name, bool dontBroadcast) {
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidPlayer(client)) {
        return Plugin_Continue;
    }
    int nade_id = GetEventInt(event, "entityid");
    if (nade_id < 0) {
        return Plugin_Continue;
    }
    char grenade_name[32];
    grenade_name = nade_type_from_id(nade_id);

    // we have a US arty smoke detonation
    if (StrEqual(grenade_name, US_ARTY_SMOKE)) {
        //LogMessage("[GG FireSupport] (SEC) %N threw %s and it detonated", client, grenade_name);
        if (CountAvailableSupport[TEAM_SECURITY] == 0) {
            LogMessage("[GG FireSupport] US fire mission requested but they're out of calls");
            CPrintToChatAll("{palegreen}FDC:{default} %t", "no_arty_left");
            //CPrintToChatAll("{palegreen}FDC:{default} Negative on Fire Mission, we're on gate guard right now");
            CPrintToChat(client, "{palegreen}FDC:{default} %T", "arty_smoke_detonate_nofire_out", client);
            return Plugin_Continue;
        }
        if (gInCurrentBarrage) {
            LogMessage("[GG FireSupport] gInCurrentBarrage is True. Only fire 1 mission at a time");
            CPrintToChatAll("{palegreen}FDC:{default} %t", "arty_smoke_detonate_nofire_ongoing");
            PrintHintText(client, "%T", "arty_smoke_detonate_nofire_ongoing", client);
            //CPrintToChatAll("{palegreen}FDC:{default} Negative New Fire Mission, Currently tasked with on-going Fire Mission");
            //CPrintToChat(client, "{palegreen}FDC:{default} %T", "");
            //CPrintToChat(client, "FDC: Negative Fire Mission, already on mission");
            return Plugin_Continue;
        }
        //LogMessage("[GG FireSupport] Should call US Fire Mission REQUEST Now");
        attempt_us_fire_support(client, nade_id);
        return Plugin_Continue;
    }
    // we have INS arty smoke detonation
    if (StrEqual(grenade_name, INS_ARTY_SMOKE)) {
        //LogMessage("[GG FireSupport] (INS) %N threw %s and it detonated", client, grenade_name);
        //LogMessage("[GG FireSupport] Should call INS Fire Mission REQUEST Now");
        attempt_ins_fire_support(client, nade_id);
        return Plugin_Continue;
    }

    return Plugin_Continue;
}

// trans nofire ongoing mission arty_smoke_detonate_nofire_ongoing
// trans fire_mission_hint (player, location, time, round count)
// trans fire_mission_chat (player, time, round count)
public void attempt_us_fire_support(int client, int nade_id) {
    if (gInCurrentBarrage) {
        LogMessage("[GG FireSupport] gInCurrentBarrage is True. Only fire 1 mission at a time");
        //CPrintToChatAll("{palegreen}FDC:{default} Negative on New Fire Mission, Currently tasked with on-going Fire Mission");
        CPrintToChatAll("{palegreen}FDC:{default} %t", "arty_smoke_detonate_nofire_ongoing");
    } else {
        float pos[3];
        GetEntPropVector(nade_id, Prop_Send, "m_vecOrigin", pos);
        if (CallFireSupport(client, pos)) {
            LogMessage("[GG FireSupport] CallFireSupport (US) successful");
            gInCurrentBarrage = true;
            CountAvailableSupport[TEAM_SECURITY]--;
            char playerName[128];
            Format(playerName, sizeof(playerName), "%N", client);
            char aLocation[32];
            Format(aLocation, sizeof(aLocation), "%d:%d:%d", gen_rando(), gen_rando(), gen_rando());
            //PrintHintTextToAll("FIRE MISSION: %s, suppress %s, 7sec, 15HE // DANGER CLOSE", playerName, aLocation);
            PrintHintTextToAll("%t", "fire_mission_hint", playerName, aLocation, gCvarDelay.IntValue, gCvarSecRoundCount.IntValue);
            //CPrintToChatAll("{palegreen}FDC:{default} FIRE MISSION: %s %isec, 15HE // DANGER CLOSE", playerName, gCvarDelay.IntValue);
            CPrintToChatAll("{palegreen}FDC:{default} %t", "fire_mission_chat", playerName, gCvarDelay.IntValue, gCvarSecRoundCount.IntValue);
            //CPrintToChatAll("{palegreen}FDC:{default} %t", "arty_count_left", CountAvailableSupport[TEAM_SECURITY]);

            CPrintToChatAll("{palegreen}FDC:{default} %t", "arty_calls_left", CountAvailableSupport[TEAM_SECURITY], gCvarCountPerRound.IntValue);
            add_throw_to_db(client);
            SendForwardArtyThrown(client);
        } else {
            PlayInvalidSoundToAll();
        }
    }
}

public void attempt_ins_fire_support(int client, int nade_id) {

    float pos[3];
    GetEntPropVector(nade_id, Prop_Send, "m_vecOrigin", pos);
    if (CallInsFireSupport(client, pos)) {
        int team = GetClientTeam(client);
        char playerName[128];
        Format(playerName, sizeof(playerName), "%N", client);
        LogMessage("[GG FireSupport] CallFireSupport (INS) successful");
        //CPrintToChatAll("{deeppink}ICOM Chatter:{default} Firing the rockets now");
        CPrintToChatAll("{deeppink}ICOM Chatter:{default} %t", "ins_firing_rockets_now");
        if (team == TEAM_SECURITY) {
            //CPrintToChatAll("{darkolivegreen}INTEL:{default} (%N) Stupid fucks are firing on themselves", client);
            CPrintToChatAll("{darkolivegreen}INTEL:{default} %t", "ins_firing_on_selves", playerName);
            SendForwardInsArtyThrown(client);
        }
    } else {
        //CPrintToChatAll("{deeppink}ICOM Chatter:{default} Achmed cannot find the telescope");
        char spotter_name[64];
        ins_spotter_name.GetString(spotter_name, sizeof(spotter_name));
        CPrintToChatAll("{deeppink}ICOM Chatter:{default} %t", "achmed_no_telescope", spotter_name);
    }
}

/// INS FireSupport
public bool CallInsFireSupport(int client, float ground[3]) {
    //LogMessage("[GG FireSupport] INSIDE CallInsFireSupport (INS");
    float sky[3];
    if (GetSkyPos(client, ground, sky)) {
        sky[2] -= 20.0;

        float time = gCvarDelay.FloatValue;
        int shells = gCvarInsRoundCount.IntValue;
        DataPack pack = new DataPack();
        pack.WriteCell(client);
        pack.WriteCell(shells);
        pack.WriteFloat(sky[0]);
        pack.WriteFloat(sky[1]);
        pack.WriteFloat(sky[2]);

        ShowDelayEffect(ground, sky, time, TEAM_INSURGENT);
        CreateTimer(time + 0.05, Timer_LaunchInsMissile, pack, TIMER_FLAG_NO_MAPCHANGE);
        CreateTimer(0.15, Timer_PlayOutgoingSound_Sec, shells);
        return true;
    }
    return false;
}


/// US FireSupport
public bool CallFireSupport(int client, float ground[3]) {
    //LogMessage("[GG FireSupport] INSIDE CallFireSupport (US)");
    float sky[3];
    if (GetSkyPos(client, ground, sky)) {
        sky[2] -= 20.0;

        float time = gCvarDelay.FloatValue;
        int shells = gCvarSecRoundCount.IntValue;
        DataPack pack = new DataPack();
        pack.WriteCell(client);
        pack.WriteCell(shells);
        pack.WriteFloat(sky[0]);
        pack.WriteFloat(sky[1]);
        pack.WriteFloat(sky[2]);

        ShowDelayEffect(ground, sky, time, TEAM_SECURITY);
        CreateTimer(time + 0.05, Timer_LaunchMissile, pack, TIMER_FLAG_NO_MAPCHANGE);
        CreateTimer(0.15, Timer_PlayOutgoingSound_Sec, shells);
        send_to_discord(client, "Called for M777 Fire // STEEL RAIN");
        return true;
    } else {
        char playerName[128];
        Format(playerName, sizeof(playerName), "%N", client);
        //PrintHintText(client, "FDC: Negative, Ghostrider. Unable to identify smoke.");
        PrintHintText(client, "FDC: %T", "fire_mission_no_visible_smoke", client);
        //CPrintToChatAll("{palegreen}FDC:{default} Negative, %N. Unable to identify smoke.", client);
        CPrintToChatAll("{palegreen}FDC:{default} %t", "fire_mission_no_visible_smoke_chat", playerName);
    }
    return false;
}

void InitSupportCount() {
    CountAvailableSupport[TEAM_SECURITY] = gCvarCountPerRound.IntValue;
    CountAvailableSupport[TEAM_INSURGENT] = 65535;
    gInCurrentBarrage = false;
}

void ShowDelayEffect(float ground[3], float sky[3], float time, int team) {
    //int thrower_team = GetClientTeam(client);
    if (team == TEAM_SECURITY) {
        TE_SetupBeamPoints(ground, sky, gBeamSprite, 0, 0, 1, time, 1.0, 0.0, 5, 0.0, {0, 255, 0, 255}, 10);
        TE_SendToAll();
        TE_SetupBeamRingPoint(ground, 500.0, 0.0, gBeamSprite, 0, 0, 1, time, 5.0, 0.0, {0, 255, 0, 255}, 10, 0);
        TE_SendToAll();
    } else {
        TE_SetupBeamPoints(ground, sky, gBeamSprite, 0, 0, 1, time, 1.0, 0.0, 5, 0.0, {255, 0, 0, 255}, 10);
        TE_SendToAll();
        TE_SetupBeamRingPoint(ground, 500.0, 0.0, gBeamSprite, 0, 0, 1, time, 5.0, 0.0, {255, 0, 0, 255}, 10, 0);
        TE_SendToAll();
    }
}

public void PlayRequestSoundToAll(int client) {
    char sSoundFile[128];
    Format(sSoundFile, sizeof(sSoundFile), "m777/requestartillery/requestartillery%d.ogg", GetRandomInt(1, sizeof(request_artillery_sounds)));
    EmitSoundToAll(sSoundFile, client, SNDCHAN_STATIC, _, _, 0.65);
    /*
    for (int i = 1; i < MaxClients+1; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            ClientCommand(i, "play %s", sSoundFile);
        }
    }
    */
}

public void PlayInvalidSoundToAll() {
    char sSoundFile[128];
    Format(sSoundFile, sizeof(sSoundFile), "m777/invalid/invalidtarget%d.ogg", GetRandomInt(1, sizeof(invalid_artillery_sounds)));
    for (int i = 1; i < MaxClients+1; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            ClientCommand(i, "play %s", sSoundFile);
        }
    }
}

public void PlayIncomingEffect() {
    char sSoundFile[128];
    Format(sSoundFile, sizeof(sSoundFile), "m777/incomingeffect/incomingeffect%d.ogg", GetRandomInt(1, 12)); // total 12 voices
    for (int i = 1; i < MaxClients+1; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            ClientCommand(i, "play %s", sSoundFile);
        }
    }
}

public Action Timer_PlayOutgoingSound_Sec(Handle timer, int shells) {
    if (!gInCurrentBarrage) {
        return Plugin_Continue;
    }
    if (shells > 8) {
        shells = 7;
    }
    for (int i = 1; i < MaxClients+1; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            EmitSoundToAll("tug/arty_distant_1.wav", i, SNDCHAN_STATIC, _, _, 0.65);
        }
    }
    shells--;
    if (shells > 0) {
        CreateTimer(0.2 + GetRandomFloat(), Timer_PlayOutgoingSound_Sec, shells);
    }
    return Plugin_Continue;
}


public Action Timer_LaunchInsMissile(Handle timer, DataPack pack) {
    float dir = GetURandomFloat() * MATH_PI * 8.0;	// not 2π for good result
    float length = GetURandomFloat() * gCvarMaxSpread.FloatValue;

    pack.Reset();
    int client = pack.ReadCell();

    DataPackPos cursor = pack.Position;
    int shells = pack.ReadCell();
    pack.Position = cursor;
    pack.WriteCell(shells - 1);

    float pos[3];
    pos[0] = pack.ReadFloat() + Cosine(dir) * length;
    pos[1] = pack.ReadFloat() + Sine(dir) * length;
    pos[2] = pack.ReadFloat();

    if (IsValidPlayer(client) && GetGameState() == 4) {
        
        SDKCall(fCreateRocket, client, INS_ARTY_ROCKET, pos, DOWN_VECTOR);
        char callout_phrase[64];
        ins_callout_phrase.GetString(callout_phrase, sizeof(callout_phrase));
        CPrintToChatAll("{deeppink}ICOM Chatter:{default} %s", callout_phrase);
        if (shells > 1) {
            CreateTimer(0.05 + GetURandomFloat(), Timer_LaunchInsMissile, pack, TIMER_FLAG_NO_MAPCHANGE);
        } else {
            CreateTimer(1.0, Timer_DataPackExpireIns, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
        }
    } else {
        CreateTimer(0.1, Timer_DataPackExpireIns, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    }
    return Plugin_Handled;
}

public Action Timer_DataPackExpireIns(Handle timer, DataPack pack) {
    //LogMessage("[GG FireSupport] Expiring INS datapack now");
    return Plugin_Handled;
}


public Action Timer_LaunchMissile(Handle timer, DataPack pack) {
    float dir = GetURandomFloat() * MATH_PI * 8.0;	// not 2π for good result
    float length = GetURandomFloat() * gCvarMaxSpread.FloatValue;

    pack.Reset();
    int client = pack.ReadCell();

    DataPackPos cursor = pack.Position;
    int shells = pack.ReadCell();
    pack.Position = cursor;
    pack.WriteCell(shells - 1);

    float pos[3];
    pos[0] = pack.ReadFloat() + Cosine(dir) * length;
    pos[1] = pack.ReadFloat() + Sine(dir) * length;
    pos[2] = pack.ReadFloat();

    if (IsValidPlayer(client) && GetGameState() == 4) {

        SDKCall(fCreateRocket, client, US_ARTY_ROCKET, pos, DOWN_VECTOR);
        //CPrintToChatAll("{palegreen}FDC:{default} SHOT OVER");
        CPrintToChatAll("{palegreen}FDC:{default} %t", "fire_mission_shot_over");
        if (shells > 1) {
            CreateTimer(0.05 + GetURandomFloat(), Timer_LaunchMissile, pack, TIMER_FLAG_NO_MAPCHANGE);
        } else {
            CreateTimer(1.0, Timer_DataPackExpire, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
            CPrintToChatAll("{palegreen}FDC:{default} %t", "arty_calls_left", CountAvailableSupport[TEAM_SECURITY], gCvarCountPerRound.IntValue);
        }
    } else {
        CreateTimer(0.1, Timer_DataPackExpire, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
    }
    return Plugin_Handled;
}

public Action Timer_DataPackExpire(Handle timer, DataPack pack) {
    //LogMessage("[GG FireSupport] Expiring datapack now, setting gInCurrentBarrage back to False");
    gInCurrentBarrage = false;
    return Plugin_Handled;
}


public Action Event_PlayerDeath_Pre(Handle event, const char[] name, bool dontBroadcast) {
    char weaponCheck[64];
    GetEventString(event, "weapon", weaponCheck, sizeof(weaponCheck));
    //LogMessage("[GG FireSupport] got weaponCheck: %s", weaponCheck);
    if(StrEqual(weaponCheck, US_ARTY_ROCKET, false)){
        //LogMessage("[GG FireSupport] changing weapon to 155MM");
        SetEventString(event, "weapon", "155MM Artillery");
        //char newWeapon[64];
        //GetEventString(event, "weapon", newWeapon, sizeof(newWeapon));
        //LogMessage("[GG FireSupport] got newWeapon: %s", newWeapon);
        return Plugin_Changed;
    }
    if(StrEqual(weaponCheck, INS_ARTY_ROCKET, false)){
        //LogMessage("[GG FireSupport] changing weapon to 122MM");
        SetEventString(event, "weapon", "122MM Rocket");
        return Plugin_Changed;
    }
    return Plugin_Continue;
}

/// UTILS
public Action Event_PlayerDeath(Handle event, const char[] name, bool dontBroadcast) {
    char weaponCheck[64];
    GetEventString(event, "weapon", weaponCheck, sizeof(weaponCheck)); 
    if ((StrEqual(weaponCheck, US_ARTY_ROCKET, false)) || (StrEqual(weaponCheck, INS_ARTY_ROCKET, false))) {
        // copy event details and fire new event that will appear proper in the killfeed //
        // remember to ignore the rocket_arty_X kills for stats purposes //
        //PrintToServer("Arty Kill...");
        char newWeapon[64];
        if (StrEqual(weaponCheck, US_ARTY_ROCKET, false)) {
            newWeapon = "155MM Artillery";
        } else {
            newWeapon = "122MM Rocket";
        }
        int eventUserid;
        int eventAttackerid;
        eventUserid = GetEventInt(event, "userid");
        eventAttackerid = GetEventInt(event, "attacker");

        Event event2 = CreateEvent("player_death");
        event2.SetString("weapon", newWeapon);
        event2.SetInt("attacker", eventAttackerid);
        event2.SetInt("userid", eventUserid);
        event2.Fire();
        return Plugin_Handled;
    }
    return Plugin_Continue; 
}

public void PlayIncomingSound() {
    char sVoice[128];
    Format(sVoice, sizeof(sVoice), "tug/arty_distant_1.wav", GetRandomInt(1, 29)); // total 29 voices
    for (int i = 1; i < MaxClients+1; i++) {
        if (IsClientInGame(i) && !IsFakeClient(i)) {
            ClientCommand(i, "play %s", sVoice);
        }
    }
}

char gen_rando() {
    return GetRandomInt(1,999);
}

bool GetSkyPos(int client, float pos[3], float vec[3]) {
    Handle ray = TR_TraceRayFilterEx(pos, UP_VECTOR, MASK_SOLID_BRUSHONLY, RayType_Infinite, TraceWorldOnly, client);

    if (TR_DidHit(ray)) {
        char surface[64];
        TR_GetSurfaceName(ray, surface, sizeof(surface));
        if (StrEqual(surface, "TOOLS/TOOLSSKYBOX", false)) {
            TR_GetEndPosition(vec, ray);
            CloseHandle(ray);
            return true;
        }
    }

    CloseHandle(ray);
    return false;
}

public bool TraceWorldOnly(int entity, int mask, any data) {
    if(entity == data || entity > 0)
        return false;
    return true;
}

int GetGameState(){
    return GameRules_GetProp("m_iGameState");
}

public bool IsValidPlayer(int client) {
    return (0 < client <= MaxClients) && IsClientInGame(client);
}


stock void PrecacheEffect(const char[] sEffectName)
{
    static int table = INVALID_STRING_TABLE;
    
    if (table == INVALID_STRING_TABLE)
    {
        table = FindStringTable("EffectDispatch");
    }
    bool save = LockStringTables(false);
    AddToStringTable(table, sEffectName);
    LockStringTables(save);
}
stock void PrecacheParticleEffect(const char[] sEffectName)
{
    static int table = INVALID_STRING_TABLE;
    
    if (table == INVALID_STRING_TABLE)
    {
        table = FindStringTable("ParticleEffectNames");
    }
    bool save = LockStringTables(false);
    AddToStringTable(table, sEffectName);
    LockStringTables(save);
} 