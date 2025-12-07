#include <sourcemod>
#include <discord>

public Plugin myinfo =
{
    name        = "[GG2 ADMINLOGGER] Admin loggin",
    author      = "vIr-Dan // zachm",
    description = "Logs to admin_STEAMID",
    version     = "1.0.1",
    url         = "http://dansbasement.us"
};

public void OnPluginStart()
{
    CreateConVar("sm_al_version", "1.0", "The version of 'admin logging' running.", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
}

public Action OnLogAction(Handle source, Identity ident, int client, int target, const char[] message)
{
    /* If there is no client or they're not an admin, we don't care. */
    if (client < 1 || GetUserAdmin(client) == INVALID_ADMIN_ID) return Plugin_Continue;

    /* At the moment extensions can't be passed through here yet,
     * so we only bother with plugins, and use "SM" for anything else.
     */
    char logtag[64] = "SM";
    if (ident == Identity_Plugin)
    {
        GetPluginFilename(source, logtag, sizeof(logtag));
    }

    char d_message[512];
    Format(d_message, sizeof(d_message), "%s %N ADMINLOGGER (%s)", logtag, client, message);
    send_to_discord(client, d_message);

    /* Block Core from re-logging this. */
    return Plugin_Handled;
}