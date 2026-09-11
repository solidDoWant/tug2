#include <sourcemod>
#include <discord>

public Plugin myinfo =
{
    name        = "[GG2 ADMINLOGGER] Admin loggin",
    author      = "vIr-Dan // zachm",
    description = "Logs to admin_STEAMID",
    version     = "1.0.2",
    url         = "http://dansbasement.us"
};

public void OnPluginStart()
{
    CreateConVar("sm_al_version", "1.0", "The version of 'admin logging' running.", FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
}

/* Appends msg[from..to) at `at`, stopping at the end of the buffer. Returns the number of
 * characters written.
 */
static int AppendRange(char[] buffer, int maxlen, int at, const char[] msg, int from, int to)
{
    int written = 0;
    while (from < to && at + written < maxlen - 1)
    {
        buffer[at + written] = msg[from];
        written++;
        from++;
    }

    buffer[at + written] = '\0';
    return written;
}

/* Finds the next player identity in a log message.
 *
 * LogAction callers build these with "%L", which expands to name<userid><authid><team> and is by
 * convention wrapped in quotes, e.g. "pl0x<275><STEAM_1:0:60762482><>". Since a name may contain
 * anything at all, the three angle-bracketed fields are what's matched, and the name is whatever
 * sits between the opening quote and them.
 *
 * `start`/`end` bound the whole thing including its quotes, ready to be replaced; `nameStart` and
 * `nameLen` isolate the bare name for when the player has since left and can't be linked.
 */
static bool FindIdentity(const char[] msg, int from, int &start, int &end, int &userid, int &nameStart, int &nameLen)
{
    int len = strlen(msg);

    for (int i = from; i < len; i++)
    {
        if (msg[i] != '<') continue;

        /* <userid> */
        int p      = i + 1;
        int digits = 0;
        while (p < len && msg[p] >= '0' && msg[p] <= '9')
        {
            p++;
            digits++;
        }
        if (digits == 0 || p >= len || msg[p] != '>') continue;
        p++;

        /* <authid><team>, either of which may be empty */
        int fields = 0;
        for (; fields < 2; fields++)
        {
            if (p >= len || msg[p] != '<') break;
            p++;
            while (p < len && msg[p] != '>') p++;
            if (p >= len) break;
            p++;
        }
        if (fields < 2) continue;

        userid = StringToInt(msg[i + 1]);
        end    = p;

        int quote = -1;
        for (int q = i - 1; q >= from; q--)
        {
            if (msg[q] == '"')
            {
                quote = q;
                break;
            }
        }

        if (quote == -1)
        {
            /* Unquoted, so the name can't be delimited - swap out the fields alone. */
            start     = i;
            nameStart = i;
            nameLen   = 0;
        }
        else
        {
            start     = quote;
            nameStart = quote + 1;
            nameLen   = i - nameStart;
            if (end < len && msg[end] == '"') end++;
        }

        return true;
    }

    return false;
}

public Action OnLogAction(Handle source, Identity ident, int client, int target, const char[] message)
{
    /* If there is no client or they're not an admin, we don't care. */
    if (client < 1 || GetUserAdmin(client) == INVALID_ADMIN_ID) return Plugin_Continue;

    /* send_to_discord already opens the message with the admin's linked name, so their identity is
     * dropped from the front of the log line rather than repeated, and everyone else named in it is
     * linked the same way.
     */
    char cleaned[1024];
    int  out   = 0;
    int  pos   = 0;
    bool first = true;

    int start, end, userid, nameStart, nameLen;
    while (FindIdentity(message, pos, start, end, userid, nameStart, nameLen))
    {
        out += AppendRange(cleaned, sizeof(cleaned), out, message, pos, start);

        int who = GetClientOfUserId(userid);
        if (!(first && start == 0 && who == client))
        {
            char link[256];
            if (who > 0 && discord_player_link(who, link, sizeof(link)))
            {
                out += AppendRange(cleaned, sizeof(cleaned), out, link, 0, strlen(link));
            }
            else
            {
                out += AppendRange(cleaned, sizeof(cleaned), out, message, nameStart, nameStart + nameLen);
            }
        }

        first = false;
        pos   = end;
    }

    out += AppendRange(cleaned, sizeof(cleaned), out, message, pos, strlen(message));
    TrimString(cleaned);

    send_to_discord(client, cleaned);

    /* Block Core from re-logging this. */
    return Plugin_Handled;
}
