#if defined _classtemplate_included_
  #endinput
#endif
#define _classtemplate_included_

#include <sourcemod>
#include <sdktools>

/**
 * The class template a client is playing right now, read from the game rather than remembered.
 *
 * WHY THIS EXISTS. Plugins learn a class from the player_pick_squad event, and that event fires
 * once per pick. A plugin loaded mid-map - a reload, a hot patch - has missed every pick already
 * made, so without this every connected player looks classless until they pick again: no medics,
 * no bombers, nobody eligible to respawn.
 *
 * HOW. The player resource networks each client's squad and slot (m_iSquad, m_iSquadSlot), and the
 * theater's team definitions map a (team, squad, slot) to the template that slot hands out. The
 * walk through those definitions is punitive_persistence's - see the layout notes beside
 * CTheaterTeamDefinitions::GetDefinitionByTeamNumber in gamedata/tug2.games.txt.
 *
 * Call ClassTemplate_Init() once from OnPluginStart. ClassTemplate_Get then fails cleanly (returns
 * false) if the gamedata did not resolve, so callers simply keep waiting for player_pick_squad.
 */

static Handle g_hClassTemplateDirector = null;
static Handle g_hClassTemplateTeamDef  = null;

/**
 * Prepares the theater lookups. Safe to call again.
 *
 * @return  True if the class template of a client can be read.
 */
stock bool ClassTemplate_Init()
{
    delete g_hClassTemplateDirector;
    delete g_hClassTemplateTeamDef;

    GameData conf = new GameData("tug2.games");
    if (conf == null)
    {
        LogError("[ClassTemplate] tug2.games gamedata missing - classes cannot be read after a late load");
        return false;
    }

    // TheaterDirector: see gg2_theater_items for why this send proxy is the way to read it.
    StartPrepSDKCall(SDKCall_Static);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "SendProxy_TheaterDirector"))
    {
        for (int i = 0; i < 5; i++) PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hClassTemplateDirector = EndPrepSDKCall();
    }

    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CTheaterTeamDefinitions::GetDefinitionByTeamNumber"))
    {
        PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hClassTemplateTeamDef = EndPrepSDKCall();
    }

    delete conf;

    if (g_hClassTemplateDirector == null || g_hClassTemplateTeamDef == null)
    {
        LogError("[ClassTemplate] theater signatures did not resolve - classes cannot be read after a late load");
        return false;
    }
    return true;
}

/**
 * The class template the client currently has, e.g. "template_medic_security_coop".
 *
 * @return  False if the client has no squad slot yet, or the theater cannot be read.
 */
stock bool ClassTemplate_Get(int client, char[] buffer, int maxlen)
{
    buffer[0] = '\0';
    if (g_hClassTemplateDirector == null || g_hClassTemplateTeamDef == null) return false;
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return false;

    int resource = GetPlayerResourceEntity();
    if (resource == -1) return false;

    int squad = GetEntProp(resource, Prop_Send, "m_iSquad", _, client);
    int slot  = GetEntProp(resource, Prop_Send, "m_iSquadSlot", _, client);
    if (squad < 0 || slot < 0) return false;

    Address director = view_as<Address>(SDKCall(g_hClassTemplateDirector, 0, 0, 0, 0, 0));
    if (director == Address_Null) return false;

    Address teamDefs = view_as<Address>(ClassTemplate_ReadInt(director, 0x28));
    if (teamDefs == Address_Null) return false;

    Address teamDef = view_as<Address>(SDKCall(g_hClassTemplateTeamDef, teamDefs, GetClientTeam(client)));
    if (teamDef == Address_Null) return false;

    if (squad >= ClassTemplate_ReadInt(teamDef, 0x4b4)) return false;
    Address squadDef = view_as<Address>(ClassTemplate_ReadInt(teamDef, 0x4a8) + squad * 0x90);

    if (slot >= ClassTemplate_ReadInt(squadDef, 0x2c)) return false;
    Address slotDef = view_as<Address>(ClassTemplate_ReadInt(squadDef, 0x20) + slot * 0x54);

    Address namePtr = view_as<Address>(ClassTemplate_ReadInt(slotDef, 0x50));
    if (namePtr == Address_Null) return false;

    int i = 0;
    for (; i < maxlen - 1; i++)
    {
        int c = LoadFromAddress(namePtr + view_as<Address>(i), NumberType_Int8) & 0xFF;
        if (c == 0) break;
        buffer[i] = c;
    }
    buffer[i] = '\0';
    return buffer[0] != '\0';
}

stock int ClassTemplate_ReadInt(Address base, int offset)
{
    return LoadFromAddress(base + view_as<Address>(offset), NumberType_Int32);
}
