#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.1"
#define PLUGIN_DESCRIPTION "Fucking fuck yeah"

#pragma newdecls required

public Plugin myinfo = {
	name = "[GG2 FUCKYEAH] Fuck Yeah",
	author = "Casey Weed (Battleroid) || zachm",
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION
};

Handle g_CvarEnabled;
Handle g_CvarDebugEnabled;
Handle g_CvarYellChance;


// list of specific files that are decent
char FuckingSounds[][] = {
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
bool PlayerCooldown[MAXPLAYERS + 1] = {true, ...};
float PlayerTimedone[MAXPLAYERS + 1];

// length of time to wait before yelling can occur again (in seconds)
Handle CooldownPeriod;

public void OnPluginStart() {
	// cvars
	CreateConVar("fy_enabled", PLUGIN_VERSION, PLUGIN_DESCRIPTION, FCVAR_NOTIFY | 0 | FCVAR_DONTRECORD);
	g_CvarEnabled = CreateConVar("fy_enabled", "1", "Fuck Yeah Enabled [0/1]", FCVAR_NOTIFY | 0);
	g_CvarDebugEnabled = CreateConVar("fy_debug", "0", "Fuck Yeah Debugging Enabled [0/1]", FCVAR_NOTIFY | 0);
	g_CvarYellChance = CreateConVar("fy_chance", "0.5", "Chance of Yelling [0-1]", FCVAR_NOTIFY | 0, true, 0.0, true, 1.0);
	CooldownPeriod = CreateConVar("fy_cooldown", "1.0", "Cooldown period between yells [>0.0]", FCVAR_NOTIFY | 0, true, 0.0, false);

	// commands (debug)
	RegConsoleCmd("fuckyeah", Command_FuckTest, "Test Fuck Yeah plugin.");

	// events
	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Pre);
	HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Pre);
	
	// notify
	if (GetConVarBool(g_CvarEnabled)) {
		float percentage = GetConVarFloat(g_CvarYellChance) * 100;
		PrintToServer("[FY] Started with %0.2f% yell chance!", percentage);
		PrintToServer("[FY] CooldownPeriod is %0.2f", GetConVarFloat(CooldownPeriod));
	}
	AutoExecConfig(true, "fuckyeah");
}

public void OnMapStart() {
	int noncached = 0;
	// cache sounds in string array to be used
	for (int i = 0; i < sizeof(FuckingSounds); i++) {
		//if (!IsSoundPrecached(FuckingSounds[i])) {
		PrecacheSound(FuckingSounds[i]);
		noncached++;
		if (GetConVarBool(g_CvarDebugEnabled)) {
			PrintToServer("[FY] Cached: %s", FuckingSounds[i]);
		}
		//}
	}
	PrintToServer("[FY] Done caching %d sounds (total %d)", noncached, sizeof(FuckingSounds));
}

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	RemoveCooldown(client);
	return Plugin_Continue;
}

public Action Command_FuckTest(int client, int args) {
	Fuck(client);
	return Plugin_Handled;
}

public Action Fuck(int client) {
	if (!GetConVarBool(g_CvarEnabled)) {
		return Plugin_Stop;
	}

	// statics
	int idx_Sound = -1;
	// static voice = false;

	// decide on voice or sound
	int idx_Old = idx_Sound;
	idx_Sound = GetRandomInt(0, sizeof(FuckingSounds) - 1);

	if (GetConVarBool(g_CvarDebugEnabled)) {
		PrintToServer("[FY] Sound ID: Old %d, New %d", idx_Old, idx_Sound);
	}

	// prevent playing the same sound in a row
	if (idx_Old == idx_Sound) {
		return Fuck(client);
	} else {
		EmitSoundToAll(FuckingSounds[idx_Sound], client);
	}
	return Plugin_Continue;
}

public Action SetCooldown(int client) {
	// remove the existing timedone
	RemoveCooldown(client);

	// set timedone for client
	float timedone = GetGameTime() + GetConVarFloat(CooldownPeriod);
	PlayerTimedone[client] = timedone;
	PlayerCooldown[client] = true;

	if (GetConVarBool(g_CvarDebugEnabled)) {
		PrintToServer("[FY] Client %d timedone is %0.2f, it is %0.2f now", client, timedone, GetGameTime());
	}
	return Plugin_Continue;
}

public Action RemoveCooldown(int client) {
	PlayerCooldown[client] = false;
	PlayerTimedone[client] = 0.0;

	if (GetConVarBool(g_CvarDebugEnabled)) {
		PrintToServer("[FY] Removing cooldown for %d", client);
	}
	return Plugin_Continue;
}

//public Action:Event_PlayerDeath(Handle:event, String:name[], bool:broadcast) {
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	// get killer of victim
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));
	int killer = GetClientOfUserId(GetEventInt(event, "attacker"));

	// if victim was a player, remove his timer
	if (victim > 0 && !IsFakeClient(victim) && IsClientInGame(victim)) {
		RemoveCooldown(victim);
	}

	// if the killer is a bot stop here
	if (killer == 0 || !IsClientInGame(killer) || IsFakeClient(killer) || victim==killer) {
		if (GetConVarBool(g_CvarDebugEnabled)) {
			PrintToServer("[FY] Did not yell, client was not valid (client %d)", killer);
		}
		return Plugin_Continue;
	}

	// get killer timedone and check if we have passed it
	float CurrentTime = GetGameTime();
	if (PlayerCooldown[killer]) {
		if (CurrentTime < PlayerTimedone[killer]) {
			if (GetConVarBool(g_CvarDebugEnabled)) {
				PrintToServer("[FY] Time check: %f < %f", CurrentTime, PlayerTimedone[killer]);
			}
			return Plugin_Continue;
		} else {
			if (GetConVarBool(g_CvarDebugEnabled)) {
				PrintToServer("[FY] Removed cooldown for %d", killer);
			}
			RemoveCooldown(killer);
		}
	}

	// play sound at the player if RNG passes
	float rn = GetRandomFloat(0.0, 1.0);
	if (rn <= GetConVarFloat(g_CvarYellChance)) {
		Fuck(killer);
		SetCooldown(killer);
	} else {
		if (GetConVarBool(g_CvarDebugEnabled)) {
			PrintToServer("[FY] Did not yell (client %d) chance was %0.2f", killer, rn * 100);
		}
	}

	return Plugin_Continue;
}
