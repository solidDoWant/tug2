// Forwards the stats v2 recorder (gg2_stats2, issue #44) listens to. Each is raised by the plugin that
// owns the mechanic, carrying what it already knows at that moment; gg2_stats2 turns them into rows.
#if defined _gg2_stats_included
    #endinput
#endif
#define _gg2_stats_included

// Revive methods (revives.method).
enum
{
    STATS_REVIVE_DEFIB = 0,
    STATS_REVIVE_KNIFE,
    STATS_REVIVE_HEALTHKIT
};

// Why a heal hold ended (heal_holds.released_by).
enum
{
    STATS_HOLD_FULL_HEALTH = 0,
    STATS_HOLD_KEYS_RELEASED,
    STATS_HOLD_LOST_TARGET,
    STATS_HOLD_DEATH,
    STATS_HOLD_DISCONNECT,
    STATS_HOLD_ROUND_END,
    STATS_HOLD_MAP_END
};

/**
 * A downed player was revived (bm2_respawn). Raised once per revive, for the credited reviver.
 *
 * @param reviver       Client credited with the revive.
 * @param revived       Client revived.
 * @param startedAt     GetEngineTime() when anyone first made progress on this revive.
 * @param method        STATS_REVIVE_*.
 * @param helpers       Other medics nearby who sped it up.
 * @param helperCount   Entries in helpers.
 */
forward void Stats_OnRevive(int reviver, int revived, float startedAt, int method, const int[] helpers, int helperCount);

/**
 * One heal tick on another player (bm2_respawn, every 0.5 s while healing). Self-heals are not raised.
 *
 * @param healer        Client healing.
 * @param patient       Client healed.
 * @param hpGained      Health added this tick.
 * @param reachedMax    The patient reached the most this healer can give (full health for a medic).
 */
forward void Stats_OnHealTick(int healer, int patient, int hpGained, bool reachedMax);

/**
 * A medic started or stopped holding a patient in place while healing (bm2_respawn).
 *
 * @param medic         Client holding.
 * @param patient       Client held.
 * @param started       True when the hold starts, false when it ends.
 * @param reason        STATS_HOLD_* when it ends; ignored when it starts.
 */
forward void Stats_OnHealHold(int medic, int patient, bool started, int reason);

/**
 * A fire support call was accepted or refused (FireSupport).
 *
 * @param client        Caller.
 * @param supportType   Strike type: the marker weapon's name from firesupport.cfg.
 * @param target        Target position, if hasTarget.
 * @param hasTarget     False when it was refused before the marker landed.
 * @param failure       Why it was refused (team_cooldown, team_limit, player_cooldown, marker_lost,
 *                      marker_destroyed, no_sky); empty if the strike goes ahead.
 */
forward void FireSupport_OnCallResult(int client, const char[] supportType, const float target[3], bool hasTarget, const char[] failure);

/**
 * A fire support call was refunded (FireSupport).
 *
 * @param client        Caller refunded.
 */
forward void FireSupport_OnRefund(int client);

/**
 * A team kill victim forgave their killer (gg2_teamkill).
 *
 * @param victim        Client who forgave.
 * @param attacker      Client forgiven.
 */
forward void TeamKill_OnForgiven(int victim, int attacker);
