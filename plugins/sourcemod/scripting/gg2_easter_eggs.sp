// Small, rare surprises.
//
// SNIPER
//
// A headshot kill on a bot with a sniper rifle or DMR, or with a long-range scope mounted on any
// weapon, has a small chance of playing one of the Dota 2 Sniper's kill lines from the shooter.
//
// The weapon is the attacker's active weapon when the killing player_hurt fires - a bullet kill is
// always dealt by the weapon in hand. The killing blow is the player_hurt with the victim at 0 health
// (gg2_bomber relies on the same thing), which is also the only event that carries the hitgroup.
//
// Scopes are matched by theater upgrade NAME, read back from m_upgradeSlots through
// gg2_theater_items, because upgrade ids move whenever the theater is edited.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <theateritems>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name        = "[GG2 Easter Eggs] Easter eggs",
    author      = "solidDoWant",
    description = "Small, rare surprises",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

#define HITGROUP_HEAD 1

// Delivered to clients by fastdl (fastdl/src/sound/gg2_easter_eggs/) and also shipped in the server
// image. Fixed paths, so a changed recording must go in under a new name - see that directory's
// PROVENANCE.md.
char g_sniperLines[][] = {
    "gg2_easter_eggs/sniper_assass_01.ogg",
    "gg2_easter_eggs/sniper_assass_02.ogg",
    "gg2_easter_eggs/sniper_assass_03.ogg",
    "gg2_easter_eggs/sniper_assass_04.ogg",
    "gg2_easter_eggs/sniper_assass_12.ogg",
    "gg2_easter_eggs/sniper_attack_07.ogg",
    "gg2_easter_eggs/sniper_kill_01.ogg",
    "gg2_easter_eggs/sniper_kill_02.ogg",
    "gg2_easter_eggs/sniper_kill_03.ogg",
    "gg2_easter_eggs/sniper_kill_05.ogg",
    "gg2_easter_eggs/sniper_kill_06.ogg",
    "gg2_easter_eggs/sniper_kill_07.ogg",
    "gg2_easter_eggs/sniper_kill_08.ogg",
    "gg2_easter_eggs/sniper_kill_09.ogg",
    "gg2_easter_eggs/sniper_kill_10.ogg",
    "gg2_easter_eggs/sniper_kill_11.ogg",
    "gg2_easter_eggs/sniper_kill_13.ogg",
    "gg2_easter_eggs/sniper_lasthit_04.ogg",
    "gg2_easter_eggs/sniper_tf2_01.ogg",
    "gg2_easter_eggs/sniper_tf2_03.ogg",
    "gg2_easter_eggs/sniper_tf2_04.ogg",
    "gg2_easter_eggs/sniper_tf2_07.ogg",
    "gg2_easter_eggs/sniper_win_03.ogg"
};

ConVar g_cvSniperChance;
ConVar g_cvSniperWeapons;
ConVar g_cvSniperScopes;

public void OnPluginStart()
{
    g_cvSniperChance  = CreateConVar("gg_easter_sniper_chance", "0.01", "Chance a qualifying headshot kill on a bot plays a Dota 2 Sniper line. 0 disables.", _, true, 0.0, true, 1.0);
    // The theater's own weapon_class is no help here: it files the M79 under sniper_rifle and every
    // DMR under rifle_controlled_fire alongside the M16s, so the rifles are listed by hand.
    g_cvSniperWeapons = CreateConVar("gg_easter_sniper_weapons",
                                     "weapon_m40a1,weapon_mosin,weapon_kar98,weapon_enfield,weapon_remingtonmsr,weapon_gol,weapon_M107,"
                                     ... "weapon_m14,weapon_svd,weapon_dragunovsvu,weapon_sr25,weapon_hk417,weapon_sandstorm_m110",
                                     "Comma-separated weapon classnames (sniper rifles and DMRs) whose headshots qualify, whatever optic they carry");
    // Mk4 8.7x, Mosin 7x and the SVD's PSO - the scopes built for long range. The 4x optics are not.
    g_cvSniperScopes  = CreateConVar("gg_easter_sniper_scopes", "optic_scope_mk4,optic_scope_7x,optic_pks07",
                                     "Comma-separated theater upgrade names. A headshot from any weapon carrying one qualifies.");
    AutoExecConfig(true, "gg2_easter_eggs");

    HookEvent("player_hurt", Event_PlayerHurt);

    RegAdminCmd("sm_easter_sniper_test", Command_SniperTest, ADMFLAG_GENERIC,
                "Play a random Sniper line from yourself, and say whether your current weapon qualifies");
}

public void OnMapStart()
{
    for (int i = 0; i < sizeof(g_sniperLines); i++) PrecacheSound(g_sniperLines[i]);
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (event.GetInt("health") > 0 || event.GetInt("hitgroup") != HITGROUP_HEAD) return;

    float chance = g_cvSniperChance.FloatValue;
    if (chance <= 0.0) return;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (victim == 0 || attacker == 0 || victim == attacker) return;
    if (!IsFakeClient(victim) || IsFakeClient(attacker) || !IsClientInGame(attacker)) return;
    if (GetClientTeam(victim) == GetClientTeam(attacker)) return;

    if (!SniperWeaponQualifies(GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon"))) return;
    if (GetURandomFloat() >= chance) return;

    PlaySniperLine(attacker);
}

bool SniperWeaponQualifies(int weapon)
{
    if (weapon <= 0 || !IsValidEntity(weapon)) return false;

    char setting[512];
    char classname[64];
    GetEntityClassname(weapon, classname, sizeof(classname));
    g_cvSniperWeapons.GetString(setting, sizeof(setting));
    if (ListContains(setting, classname)) return true;

    if (!HasEntProp(weapon, Prop_Send, "m_upgradeSlots")) return false;

    g_cvSniperScopes.GetString(setting, sizeof(setting));
    int slots = GetEntPropArraySize(weapon, Prop_Send, "m_upgradeSlots");
    for (int i = 0; i < slots; i++)
    {
        int id = GetEntProp(weapon, Prop_Send, "m_upgradeSlots", 4, i);
        if (id <= 0) continue;

        char upgrade[64];
        if (TheaterItem_Name(TheaterCategory_Upgrade, id, upgrade, sizeof(upgrade)) && ListContains(setting, upgrade)) return true;
    }

    return false;
}

void PlaySniperLine(int client)
{
    EmitSoundToAll(g_sniperLines[GetRandomInt(0, sizeof(g_sniperLines) - 1)], client);
}

// Whether a comma-separated list holds name, ignoring case and surrounding whitespace.
bool ListContains(const char[] list, const char[] name)
{
    char entries[32][64];
    int  count = ExplodeString(list, ",", entries, sizeof(entries), sizeof(entries[]));
    for (int i = 0; i < count; i++)
    {
        TrimString(entries[i]);
        if (entries[i][0] != '\0' && StrEqual(entries[i], name, false)) return true;
    }

    return false;
}

public Action Command_SniperTest(int client, int args)
{
    if (client < 1 || !IsPlayerAlive(client))
    {
        ReplyToCommand(client, "[Easter Eggs] Run this in game while alive.");
        return Plugin_Handled;
    }

    char classname[64] = "<none>";
    int  weapon        = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon > 0 && IsValidEntity(weapon)) GetEntityClassname(weapon, classname, sizeof(classname));

    ReplyToCommand(client, "[Easter Eggs] %s %s for the Sniper line (chance %.2f%%)",
                   classname, SniperWeaponQualifies(weapon) ? "qualifies" : "does not qualify",
                   g_cvSniperChance.FloatValue * 100.0);
    PlaySniperLine(client);
    return Plugin_Handled;
}
