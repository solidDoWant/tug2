#if defined _punishments_included
    #endinput
#endif
#define _punishments_included

/**
 * Whether the player is banned from !calladmin (punitive_persistence's calladmin_ban). Their
 * !calladmin still reaches Discord, but must not ping the admin role; punitive_persistence bans
 * them from the server for it.
 *
 * @param client  Client index.
 * @return        true while a calladmin ban is active; false for an invalid client or none.
 */
native bool Punishments_IsCallAdminBanned(int client);

/**
 * Whether a chat message is a !calladmin: it starts with "!calladmin" (any case). Pass the text
 * after StripQuotes, as GetCmdArgString gives it in a say / say_team listener. Shared so
 * gg2_discord (which pings) and punitive_persistence (which bans) always agree on what counts.
 */
stock bool  IsCallAdminMessage(const char[] message)
{
    return StrContains(message, "!calladmin", false) == 0;
}

// punitive_persistence defines PUNISHMENTS_PLUGIN before including this, so it does not declare a
// dependency on itself.
#if !defined PUNISHMENTS_PLUGIN

public SharedPlugin __pl_punishments = {
    name = "punitive_persistence",
    file = "punitive_persistence.smx",
    #if defined REQUIRE_PLUGIN
    required = 1,
    #else
    required = 0,
    #endif
};

    #if !defined REQUIRE_PLUGIN

public void __pl_punishments_SetNTVOptional()
{
    MarkNativeAsOptional("Punishments_IsCallAdminBanned");
}
    #endif
#endif
