/**
 * Objective progress of the round being played, as a short phrase shaped for the gamemode:
 *
 *   checkpoint, push   "Cap 3/8"                 the point being fought over, of all of them
 *   hunt               "Caches 1/3"              caches destroyed, of the ones in play
 *   conquer            "Caps 1/3, Caches 0/5"    required points taken, and caches destroyed
 *   outpost, survival  "Level 6"                 the level shown on the players' HUD
 *
 * Shared by gg2_hostname_rounds (the server browser name) and gg2_discord (round end), so the two
 * always say the same thing.
 *
 * The objective numbers come from gg2_insurgency's objective resource natives. Only checkpoint has
 * a meaningful m_nActivePushPointIndex - it is -1 or arbitrary everywhere else. m_iLevel is on the
 * gamerules proxy, so the level modes do not need the natives. The caller must know the gamerules
 * entity exists before calling (a round event having fired proves it).
 */

#if defined _objectivestatus_included
    #endinput
#endif
#define _objectivestatus_included

#include <insurgencydy>

// m_iGameState values, from CINSRules' state table in the binary.
#define OBJSTATUS_STATE_PREGAME     1
#define OBJSTATUS_STATE_RND_RUNNING 4
#define OBJSTATUS_STATE_POSTROUND   5

// Objective slots in the objective resource, by m_iObjectType. Measured on convoy_pve conquer and
// crossbow hunt, cross-checked against the map entities: -1 is a point_controlpoint with a capture
// zone (cq_cp_a..c), 0 is a cache point that spawned an obj_weapon_cache, 1 is a cache point that
// did not - conquer and hunt spread a random subset of caches over more cache points than they use.
// The split is only made once the round starts; during setup every cache point reads 0.
// m_iOwningTeam flips from 3 to 2 when security captures a point or destroys a cache.
#define OBJSTATUS_TYPE_CAPTURE_POINT -1
#define OBJSTATUS_TYPE_CACHE          0
#define OBJSTATUS_TEAM_SECURITY       2

/**
 * Writes the phrase for the current round into buffer, or an empty string when the mode has nothing
 * to count or the numbers would be meaningless: between games, and for the non-checkpoint modes
 * whenever a round is not actually being played (their cache split and level are only set up once
 * it starts). state is m_iGameState.
 *
 * The objective natives live in gg2_insurgency. If that plugin is not loaded they do not exist, and
 * calling one is a runtime error rather than something that can be caught - so the feature is probed
 * first and the phrase is simply left empty. A plugin that must load without gg2_insurgency also has
 * to MarkNativeAsOptional("Ins_ObjectiveResource_GetProp") in AskPluginLoad2.
 *
 * @return  true if anything was written.
 */
stock bool ObjectiveStatus_Build(char[] buffer, int maxlen, int state)
{
    buffer[0] = '\0';

    char mode[32];
    ConVar gamemode = FindConVar("mp_gamemode");
    if (gamemode != null) gamemode.GetString(mode, sizeof(mode));

    bool playing = (state == OBJSTATUS_STATE_RND_RUNNING || state == OBJSTATUS_STATE_POSTROUND);

    // Outpost counts waves, survival counts safehouses reached; both show as "Level N" on the HUD
    // and m_iLevel is that number exactly (measured against the HUD on both).
    if (StrEqual(mode, "outpost") || StrEqual(mode, "survival"))
    {
        if (!playing) return false;
        int level = GameRules_GetProp("m_iLevel");
        if (level >= 1) Format(buffer, maxlen, "Level %d", level);
        return buffer[0] != '\0';
    }

    if (GetFeatureStatus(FeatureType_Native, "Ins_ObjectiveResource_GetProp") != FeatureStatus_Available) return false;

    int total = Ins_ObjectiveResource_GetProp("m_iNumControlPoints");
    if (total <= 0) return false;

    if (StrEqual(mode, "hunt") || StrEqual(mode, "conquer"))
    {
        if (!playing) return false;

        int points = 0, pointsTaken = 0, caches = 0, cachesDestroyed = 0;
        for (int i = 0; i < total; i++)
        {
            int  type  = Ins_ObjectiveResource_GetProp("m_iObjectType", _, i);
            bool taken = (Ins_ObjectiveResource_GetProp("m_iOwningTeam", _, i) == OBJSTATUS_TEAM_SECURITY);

            if (type == OBJSTATUS_TYPE_CAPTURE_POINT)  { points++; if (taken) pointsTaken++; }
            else if (type == OBJSTATUS_TYPE_CACHE)     { caches++; if (taken) cachesDestroyed++; }
        }

        if (points > 0 && caches > 0) Format(buffer, maxlen, "Caps %d/%d, Caches %d/%d", pointsTaken, points, cachesDestroyed, caches);
        else if (points > 0)          Format(buffer, maxlen, "Caps %d/%d", pointsTaken, points);
        else if (caches > 0)          Format(buffer, maxlen, "Caches %d/%d", cachesDestroyed, caches);
        return buffer[0] != '\0';
    }

    // Checkpoint (and push, its PvP twin): points are taken in order, so the interesting number is
    // which one is being fought over. Anything else has no push order to report.
    if (!StrEqual(mode, "checkpoint") && !StrEqual(mode, "push")) return false;

    // m_nActivePushPointIndex is 0-based - bm2_respawn adds 1 to it for the same reason.
    // In pregame the index is left over from the abandoned game; the next one starts at the first.
    int active = (state <= OBJSTATUS_STATE_PREGAME) ? 1 : Ins_ObjectiveResource_GetProp("m_nActivePushPointIndex") + 1;

    // Between rounds, or on a map where the index has not settled, this can read outside the real
    // range. Clamping beats printing "Cap 0/8" or "Cap 9/8".
    if (active < 1) active = 1;
    if (active > total) active = total;

    Format(buffer, maxlen, "Cap %d/%d", active, total);
    return true;
}
