#if defined _steamids_included_
  #endinput
#endif
#define _steamids_included_

/**
 * SteamID string conversion.
 *
 * Ban identities arrive in whatever form the admin typed or the engine produced: "STEAM_1:0:12345"
 * from `status` and the engine's ban list, "[U:1:24690]" from newer tools, or a bare SteamID64
 * from a profile URL. The punishments table stores SteamID64 (bigint), so everything is
 * normalised to that before it touches the database or is compared.
 *
 * SourcePawn has no 64-bit integers, so the arithmetic is done in decimal on the string:
 * SteamID64 = 76561197960265728 + accountId, where accountId = Z*2 + Y for STEAM_X:Y:Z and N for
 * [U:1:N]. accountId fits in 32 bits, so only the final addition needs the string maths.
 */

#define STEAMID64_BASE "76561197960265728"

/**
 * Converts any supported SteamID form to a SteamID64 string.
 *
 * @param input   "STEAM_X:Y:Z", "[U:1:N]", or an already-64-bit decimal id.
 * @param output  Receives the SteamID64.
 * @param maxlen  Size of output (at least 18).
 * @return        true on success; false (output untouched) for anything unrecognised.
 */
stock bool SteamIdTo64(const char[] input, char[] output, int maxlen)
{
    int accountId = -1;

    if (strncmp(input, "STEAM_", 6, false) == 0)
    {
        // STEAM_X:Y:Z
        char parts[3][16];
        if (ExplodeString(input[6], ":", parts, sizeof(parts), sizeof(parts[])) != 3) return false;
        if (!SteamIds_IsDigits(parts[1]) || !SteamIds_IsDigits(parts[2])) return false;

        int y = StringToInt(parts[1]);
        int z = StringToInt(parts[2]);
        if (y > 1 || z < 0 || z > 0x3FFFFFFF) return false;
        accountId = z * 2 + y;
    }
    else if (strncmp(input, "[U:1:", 5, false) == 0)
    {
        char num[16];
        strcopy(num, sizeof(num), input[5]);
        int close = FindCharInString(num, ']');
        if (close <= 0) return false;
        num[close] = '\0';
        if (!SteamIds_IsDigits(num)) return false;
        accountId = StringToInt(num);
        if (accountId < 0) return false;
    }
    else if (SteamIds_IsDigits(input) && strlen(input) == 17 && strncmp(input, "7656119", 7) == 0)
    {
        strcopy(output, maxlen, input);
        return true;
    }

    if (accountId < 0) return false;

    char account[16];
    IntToString(accountId, account, sizeof(account));
    SteamIds_AddDecimal(STEAMID64_BASE, account, output, maxlen);
    return true;
}

stock bool SteamIds_IsDigits(const char[] s)
{
    if (s[0] == '\0') return false;
    for (int i = 0; s[i] != '\0'; i++)
        if (!IsCharNumeric(s[i])) return false;
    return true;
}

/** Adds two non-negative decimal strings. */
stock void SteamIds_AddDecimal(const char[] a, const char[] b, char[] output, int maxlen)
{
    char result[32];
    int  la = strlen(a), lb = strlen(b);
    int  n = (la > lb ? la : lb);
    int  carry = 0;

    // Built right-to-left into the end of the buffer.
    result[n + 1] = '\0';
    for (int i = 0; i <= n; i++)
    {
        int da = (i < la) ? view_as<int>(a[la - 1 - i]) - '0' : 0;
        int db = (i < lb) ? view_as<int>(b[lb - 1 - i]) - '0' : 0;
        int sum = da + db + carry;
        result[n - i] = view_as<char>('0' + (sum % 10));
        carry = sum / 10;
    }

    // Drop the leading zero left by the spare carry digit.
    strcopy(output, maxlen, result[(result[0] == '0') ? 1 : 0]);
}
