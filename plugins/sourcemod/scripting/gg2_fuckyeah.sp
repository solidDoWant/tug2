#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION     "1.0.1"
#define PLUGIN_DESCRIPTION "Fucking fuck yeah"

#pragma newdecls required

public Plugin myinfo =
{
    name        = "[GG2 FUCKYEAH] Fuck Yeah",
    author      = "Casey Weed (Battleroid) || zachm",
    description = PLUGIN_DESCRIPTION,
    version     = PLUGIN_VERSION
};

Handle g_CvarEnabled;
Handle g_CvarYellChance;

// list of specific files that are decent
char   FuckingSounds[][] = {
    "player/voice/radial/security/leader/suppressed/target5.ogg",
    "player/voice/radial/security/subordinate/unsuppressed/enemydown_knifekill3.ogg",
    "player/voice/radial/security/subordinate/unsuppressed/enemydown_knifekill1.ogg",
    "player/voice/responses/security/subordinate/suppressed/target1.ogg",
    "player/voice/responses/security/subordinate/suppressed/target2.ogg",
    "player/voice/responses/security/subordinate/suppressed/target3.ogg",
    "player/voice/responses/security/subordinate/suppressed/target4.ogg",
    "player/voice/responses/security/subordinate/suppressed/target5.ogg",
    "player/voice/responses/security/subordinate/suppressed/target6.ogg",
    "player/voice/responses/security/subordinate/suppressed/target7.ogg",
    "player/voice/responses/security/subordinate/suppressed/target8.ogg",
    "player/voice/responses/security/subordinate/suppressed/target9.ogg",
    "player/voice/responses/security/subordinate/suppressed/target10.ogg",
    "player/voice/responses/security/subordinate/suppressed/target11.ogg",
    "player/voice/responses/security/subordinate/suppressed/target12.ogg",
    "player/voice/responses/security/subordinate/suppressed/target13.ogg"
};

// whether or not the player has an active cooldown, end time for cooldown
float  PlayerTimeDone[MAXPLAYERS + 1];
int    PlayerLastSoundNumber[MAXPLAYERS + 1] = { -1, ... };

// length of time to wait before yelling can occur again (in seconds)
Handle CooldownPeriod;

public void OnPluginStart()
{
    // cvars
    CreateConVar("fy_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_NOTIFY | 0 | FCVAR_DONTRECORD);
    g_CvarEnabled    = CreateConVar("fy_enabled", "1", "Fuck Yeah Enabled [0/1]", FCVAR_NOTIFY | 0);
    g_CvarYellChance = CreateConVar("fy_chance", "0.5", "Chance of Yelling [0-1]", FCVAR_NOTIFY | 0, true, 0.0, true, 1.0);
    CooldownPeriod   = CreateConVar("fy_cooldown", "1.0", "Cooldown period between yells [>0.0]", FCVAR_NOTIFY | 0, true, 0.0, false);

    // commands (debug)
    RegConsoleCmd("fuckyeah", Command_FuckTest, "Test Fuck Yeah plugin.");

    // events
    HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
    HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);

    // notify
    if (GetConVarBool(g_CvarEnabled))
    {
        float percentage = GetConVarFloat(g_CvarYellChance) * 100;
        PrintToServer("[FY] Started with %0.2f% yell chance!", percentage);
        PrintToServer("[FY] CooldownPeriod is %0.2f", GetConVarFloat(CooldownPeriod));
    }

    AutoExecConfig(true, "fuckyeah");
}

public void OnMapStart()
{
    for (int i = 0; i < sizeof(FuckingSounds); i++)
    {
        PrecacheSound(FuckingSounds[i]);
    }

    PrintToServer("[FY] Done caching %d sounds", sizeof(FuckingSounds));
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    RemoveCooldown(client);
    return Plugin_Continue;
}

public Action Command_FuckTest(int client, int args)
{
    Fuck(client);
    return Plugin_Handled;
}

public Action Fuck(int client)
{
    if (!GetConVarBool(g_CvarEnabled)) return Plugin_Stop;

    if (client == 0 || client > MaxClients) return Plugin_Continue;
    if (IsFakeClient(client)) return Plugin_Continue;
    if (!IsClientInGame(client)) return Plugin_Continue;

    int numSoundsAvailable = sizeof(FuckingSounds) - 1;    // Inclusive, starting from zero
    int lastSoundNumber    = PlayerLastSoundNumber[client];
    if (lastSoundNumber != -1)
    {
        // Removing another item prevents the same sound from being picked twice
        numSoundsAvailable--;
    }

    int soundNumber = GetRandomInt(0, numSoundsAvailable);
    if (soundNumber >= lastSoundNumber && lastSoundNumber != -1)
    {
        // Shift the pick upwards by one when the picked number is on the interval at or above
        // the last picked sound. This shouldn't go out of bounds and should still be a uniformly
        // random choice between all the sounds except for the most recently played one.
        soundNumber++;
    }

    EmitSoundToAll(FuckingSounds[soundNumber], client);
    PlayerLastSoundNumber[client] = soundNumber;

    return Plugin_Continue;
}

public Action SetCooldown(int client)
{
    // set timeDone for client
    float timeDone         = GetGameTime() + GetConVarFloat(CooldownPeriod);
    PlayerTimeDone[client] = timeDone;

    return Plugin_Continue;
}

public Action RemoveCooldown(int client)
{
    PlayerTimeDone[client] = 0.0;

    return Plugin_Continue;
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(GetEventInt(event, "userid"));
    if (victim == 0) return Plugin_Continue;

    int killer = GetClientOfUserId(GetEventInt(event, "attacker"));
    if (killer == 0) return Plugin_Continue;

    // Reset cooldown for victim
    if (victim > 0 && !IsFakeClient(victim) && IsClientInGame(victim))
    {
        RemoveCooldown(victim);
    }

    // Skip if the killer is a bot
    if (killer == 0 || !IsClientInGame(killer) || IsFakeClient(killer) || victim == killer) return Plugin_Continue;

    // Skip if the victim and killer are on the same team
    int victimTeam = GetClientTeam(victim);
    int killerTeam = GetClientTeam(killer);
    if (victimTeam == killerTeam) return Plugin_Continue;

    // Get killer timeDone and check if it is still active
    if (GetGameTime() < PlayerTimeDone[killer]) return Plugin_Continue;

    // Play sound at the player if RNG passes
    float yellRoll = GetRandomFloat(0.0, 1.0);
    if (yellRoll > GetConVarFloat(g_CvarYellChance)) return Plugin_Continue;

    Fuck(killer);
    SetCooldown(killer);
    return Plugin_Continue;
}
