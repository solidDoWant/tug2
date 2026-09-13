// Vendored from upstream, then patched. Do NOT re-fetch over this file without re-applying the
// gamemode gate below.
//
//   upstream: https://github.com/NullifidianSF/insurgency_public
//   file:     addons/sourcemod/scripting/ca_countdown.sp
//   commit:   e6eb683a6ba407b5bba29b74817e0c0bcb9d6a0c
//
// It used to be curl'd at image build time (see the counterattack-countdown stage in the
// Dockerfile). It is vendored now because it needed a fix that upstream does not have: the countdown
// announced itself in hunt.
//
// WHAT WAS WRONG. Neither trigger checked the gamemode. Event_ControlPointCaptured and
// Event_ObjectDestroyed both start the timer on any team-2 cap or cache kill, and the timer's only
// guard was Ins_InCounterAttack() - which reads m_bCounterAttack, and that flag is NOT
// checkpoint-only. Hunt raises it when a cache is blown while bots are still alive (it is what
// mp_hunt_counterattack_distance steers the bots by). So in hunt the plugin counted down
// mp_checkpoint_counterattack_delay - a checkpoint convar - towards a counterattack wave that was
// never coming, and told everybody so, top-middle, once a second.
//
// HasCounterAttacks() below is the gate, and it is deliberately the same idiom as the one in
// gg2_messages.sp, which already had to solve this for its chat messages.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <insurgencydy>

public Plugin myinfo = {
	name = "ca_countdown",
	author = "Nullifidian",
	description = "Print how long left until counterattack.",
	version = "1.2",
	url = "https://steamcommunity.com/id/Nullifidian/"
};

ConVar	g_cvDelay,
		g_cvDelayFinale;

// Counterattacks are a checkpoint mechanic. m_bCounterAttack is not, so the flag alone is not enough
// to decide whether a countdown means anything - see the note at the top of this file.
bool HasCounterAttacks() {
	ConVar cvGamemode = FindConVar("mp_gamemode");
	if (cvGamemode == null) {
		return true;
	}

	char sGamemode[32];
	cvGamemode.GetString(sGamemode, sizeof(sGamemode));
	return StrEqual(sGamemode, "checkpoint", false);
}

int		g_iDelay,
		g_iDelayFinale;

char	g_sSound1[] = "hq/outpost/outpost_nextwave8.ogg",
		g_sSound2[] = "hq/outpost/outpost_nextwave5.ogg";

public void OnPluginStart() {
	HookEvent("controlpoint_captured", Event_ControlPointCaptured);
	HookEvent("object_destroyed", Event_ObjectDestroyed);

	//How long (in seconds) until the enemy counter-attack wave spawns.
	g_cvDelay = FindConVar("mp_checkpoint_counterattack_delay");
	if (!g_cvDelay) {
		SetFailState("mp_checkpoint_counterattack_delay not found!");
	}
	g_iDelay = g_cvDelay.IntValue;
	g_cvDelay.AddChangeHook(OnConVarChanged);

	//How long (in seconds) until the enemy counter-attack wave spawns (finale).
	g_cvDelayFinale = FindConVar("mp_checkpoint_counterattack_delay_finale");
	if (!g_cvDelayFinale) {
		SetFailState("mp_checkpoint_counterattack_delay_finale not found!");
	}
	g_iDelayFinale = g_cvDelayFinale.IntValue;
	g_cvDelayFinale.AddChangeHook(OnConVarChanged);
}

public void OnMapStart() {
	PrecacheSound(g_sSound1, true);
	PrecacheSound(g_sSound2, true);
}

public Action Event_ControlPointCaptured(Event event, const char[] name, bool dontBroadcast) {
	if (!HasCounterAttacks()) {
		return Plugin_Continue;
	}
	if (event.GetInt ("team") == 2) {
		CreateTimer(1.0, Timer_Countdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
	return Plugin_Continue;
}

public Action Event_ObjectDestroyed(Event event, const char[] name, bool dontBroadcast) {
	if (!HasCounterAttacks()) {
		return Plugin_Continue;
	}
	if (event.GetInt ("attackerteam") == 2) {
		CreateTimer(1.0, Timer_Countdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
	return Plugin_Continue;
}

Action Timer_Countdown(Handle timer) {
	static int	iTimeDone = 0,
				ncp,
				acp;

	// iTimeDone is static and shared by every countdown, so a timer that bails has to reset it or the
	// next one resumes from wherever this one stopped. Upstream's early return did not, which is
	// harmless while the only exit is a finished countdown but not once the gate can cut one short.
	if (!Ins_InCounterAttack() || !HasCounterAttacks()) {
		iTimeDone = 0;
		return Plugin_Stop;
	}

	if (iTimeDone == 0) {
		ncp = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
		acp = Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex");
	}

	int iTimeLeft;

	//last point (from bot respawn by daimyo)
	if ((acp+1) == ncp) {
		if (iTimeDone >= g_iDelayFinale) {
			iTimeDone = 0;
			return Plugin_Stop;
		}

		iTimeDone++;
		iTimeLeft = g_iDelayFinale - iTimeDone;

		if (iTimeLeft <= 0) {
			iTimeDone = 0;
			PlaySound();
			return Plugin_Stop;
		}
	} else {
		if (iTimeDone >= g_iDelay) {
			iTimeDone = 0;
			return Plugin_Stop;
		}

		iTimeDone++;
		iTimeLeft = g_iDelay - iTimeDone;

		if (iTimeLeft <= 0) {
			iTimeDone = 0;
			PlaySound();
			return Plugin_Stop;
		}
	}
	PrintCenterTextAll("Insurgents counter-attacking in %d", iTimeLeft);
	return Plugin_Continue;
}

void PlaySound() {
	switch (GetRandomInt(0, 1)) {
		case 0: EmitSoundToAll(g_sSound1);
		case 1: EmitSoundToAll(g_sSound2);
	}
}

void OnConVarChanged(ConVar convar, const char[] oldValue, const char[] newValue) {
	if (convar == g_cvDelay) {
		g_iDelay = g_cvDelay.IntValue;
	}
	else if (convar == g_cvDelayFinale) {
		g_iDelayFinale = g_cvDelayFinale.IntValue;
	}
}