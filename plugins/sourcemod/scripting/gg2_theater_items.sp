/*
 * @Description:
 *               中文INS服务器使用此插件请注明和鸣谢作者。
 * @Author: Gandor
 * @Github: https://github.com/gandor233
 * @Date: 2021-02-10 04:38:27
 * @LastEditTime: 2022-01-19 21:29:55
 * @LastEditors: Gandor
 * @FilePath: \SourceMod_1.10.0\TheaterItemsAPI.sp
 */
public Plugin myinfo =
{
    name        = "[GG2 TheaterItems] TheaterItemsAPI",
    author      = "Gandor | 游而不擊 轉進如風",
    description = "Theater Items API For Insurgency(2014)",
    version     = "1.0",
    url         = "https://github.com/gandor233"
};

#pragma semicolon 1

ConVar mp_theater_override;
bool   g_bNeedUpdateTheaterItems = true;

enum THEATER_ITEM_TABLE_TYPE
{
    THEATER_ITEM_TABLE_WEAPONS = 0,
    THEATER_ITEM_TABLE_WEAPON_UPGRADES,
    THEATER_ITEM_TABLE_EXPLOSIVES,
    THEATER_ITEM_TABLE_PLAYER_GEAR,
};

char g_cTheaterItemsTableNameList[][] = {
    "Weapons",
    "WeaponUpgrades",
    "Explosives",
    "PlayerGear",
};

char g_cTheaterItemsList[sizeof(g_cTheaterItemsTableNameList)][256][128];
int  g_iTheaterItemsStringsCount[sizeof(g_cTheaterItemsTableNameList)];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("TI_GetTheaterItemIdByName", Native_GetTheaterItemIdByName);
    CreateNative("TI_GetWeaponItemName", Native_GetWeaponItemName);
    CreateNative("TI_GetWeaponUpgradeItemName", Native_GetWeaponUpgradeItemName);
    CreateNative("TI_GetExplosiveItemName", Native_GetExplosiveItemName);
    CreateNative("TI_GetPlayerGearItemName", Native_GetPlayerGearItemName);
    RegPluginLibrary("TheaterItemsAPI");
    return APLRes_Success;
}

public void OnPluginStart()
{
    mp_theater_override = FindConVar("mp_theater_override");
    if (mp_theater_override == null)
    {
        SetFailState("Failed to find ConVar 'mp_theater_override' - plugin requires Insurgency (2014)");
    }
    mp_theater_override.AddChangeHook(OnTheaterChange);

    RegAdminCmd("sm_update_theater_items", Command_UpdateTheaterItems, ADMFLAG_ROOT, "Force update the theater items name record list");

    RegAdminCmd("listweapons", Command_ListItemName, ADMFLAG_ROOT);
    RegAdminCmd("listweapon", Command_ListItemName, ADMFLAG_ROOT);
    RegAdminCmd("listupgrades", Command_ListItemName, ADMFLAG_ROOT);
    RegAdminCmd("listupg", Command_ListItemName, ADMFLAG_ROOT);
    RegAdminCmd("listexplosives", Command_ListItemName, ADMFLAG_ROOT);
    RegAdminCmd("listexp", Command_ListItemName, ADMFLAG_ROOT);
    RegAdminCmd("listplayergear", Command_ListItemName, ADMFLAG_ROOT);
    RegAdminCmd("listgear", Command_ListItemName, ADMFLAG_ROOT);

    g_bNeedUpdateTheaterItems = true;
    return;
}

public void OnConfigsExecuted()
{
    CreateTimer(5.0, CheckTheaterItemsDelay_Timer, _, TIMER_FLAG_NO_MAPCHANGE);
    return;
}

public void OnTheaterChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_bNeedUpdateTheaterItems = true;
    return;
}

// Function
public Action Command_ListItemName(int client, int args)
{
    char cCommand[65];
    GetCmdArg(0, cCommand, sizeof(cCommand));
    ReplaceString(cCommand, sizeof(cCommand), "list", "", false);

    // Require minimum 3 characters to prevent overly broad matches
    if (strlen(cCommand) < 3) return Plugin_Handled;

    for (int i = 0; i < sizeof(g_cTheaterItemsTableNameList); i++)
    {
        if (StrContains(g_cTheaterItemsTableNameList[i], cCommand, false) == -1) continue;

        PrintToConsole(client, "Listing %s [1~%d]", g_cTheaterItemsTableNameList[i], g_iTheaterItemsStringsCount[i]);
        for (int j = 1; j <= g_iTheaterItemsStringsCount[i]; j++)
        {
            PrintToConsole(client, "  %d - %s", j, g_cTheaterItemsList[i][j]);
        }
        PrintToConsole(client, " ");

        return Plugin_Handled;
    }

    return Plugin_Handled;
}

public int GetTheaterItemIdByName(THEATER_ITEM_TABLE_TYPE iItemTableType, char[] cItemName)
{
    if (iItemTableType < THEATER_ITEM_TABLE_WEAPONS) return -1;
    if (iItemTableType > THEATER_ITEM_TABLE_PLAYER_GEAR) return -1;

    for (int i = 1; i <= g_iTheaterItemsStringsCount[iItemTableType]; i++)
    {
        if (!StrEqual(g_cTheaterItemsList[iItemTableType][i], cItemName, false)) continue;

        return i;
    }

    return -1;
}

public Action Command_UpdateTheaterItems(int client, int args)
{
    RequestFrame(UpdateTheaterItems);
    return Plugin_Handled;
}

public Action CheckTheaterItemsDelay_Timer(Handle timer, any data)
{
    if (g_bNeedUpdateTheaterItems)
    {
        UpdateTheaterItems();
    }

    g_bNeedUpdateTheaterItems = false;
    return Plugin_Stop;
}

public void UpdateTheaterItems()
{
    char buffer[32768];
    ServerCommandEx(buffer, sizeof(buffer), "listtheateritems");

    int  currentTableIndex     = -1;
    int  currentTableItemIndex = 0;

    int  pos                   = 0;
    char line[64];
    int  nextLineIndex;

    // Parse buffer line by line using SplitString (same approach as ExplodeString)
    while (true)
    {
        nextLineIndex   = SplitString(buffer[pos], "\n", line, sizeof(line));

        bool isLastLine = (nextLineIndex == -1);

        if (isLastLine)
        {
            // Last line without trailing newline
            nextLineIndex = strcopy(line, sizeof(line), buffer[pos]);
            if (strlen(line) == 0) break;

            // For strcopy, check if there's more data after what was copied to detect truncation
            if (nextLineIndex == sizeof(line) - 1 && buffer[pos + nextLineIndex] != '\0')
            {
                nextLineIndex = sizeof(line);    // Normalize to trigger truncation warning
            }
        }
        else
        {
            pos += nextLineIndex;
        }

        // Skip empty lines
        if (strlen(line) == 0) continue;

        // Process the line
        int colonPos = FindCharInString(line, ':');
        if (colonPos > -1)
        {
            // This is a header - extract table name
            line[colonPos] = '\0';    // Truncate at colon
            ReplaceString(line, sizeof(line), " ", "", false);

            currentTableIndex     = GetTheaterItemsTableIndexByTableName(line);
            currentTableItemIndex = 0;
        }
        else if (currentTableIndex >= 0)
        {
            // Detect truncation by checking if source line was longer than buffer
            if (nextLineIndex >= sizeof(line))
            {
                LogMessage("[Theater Items] Warning: Line truncated - original %d chars, buffer holds %d: %.50s...",
                           nextLineIndex - 1,    // Exclude newline from count
                           sizeof(line) - 1,     // Exclude null terminator
                           line);
            }
            else if (currentTableItemIndex == 255)
            {
                LogMessage("[Theater Items] Warning: Table %s exceeded maximum capacity (255 items) - ignoring excess items",
                           g_cTheaterItemsTableNameList[currentTableIndex]);
            }
            else
            {
                // Add item to current table
                currentTableItemIndex++;
                g_iTheaterItemsStringsCount[currentTableIndex]                = currentTableItemIndex;
                g_cTheaterItemsList[currentTableIndex][currentTableItemIndex] = line;
            }
        }

        if (isLastLine) break;
    }
}

stock int GetTheaterItemsTableIndexByTableName(char[] cTableName)
{
    for (int i = 0; i < sizeof(g_cTheaterItemsTableNameList); i++)
    {
        if (!StrEqual(g_cTheaterItemsTableNameList[i], cTableName, false)) continue;

        return i;
    }

    return -1;
}

// Native
public int Native_GetTheaterItemIdByName(Handle plugin, args)
{
    char cItemName[64];
    if (GetNativeString(2, cItemName, sizeof(cItemName)) != SP_ERROR_NONE) return -1;

    return GetTheaterItemIdByName(view_as<THEATER_ITEM_TABLE_TYPE>(GetNativeCell(1)), cItemName);
}

stock bool GetItemNameByTableType(THEATER_ITEM_TABLE_TYPE tableType, int iTableStringIndex, int maxlen)
{
    if (iTableStringIndex <= 0) return false;
    if (iTableStringIndex > g_iTheaterItemsStringsCount[tableType]) return false;

    SetNativeString(2, g_cTheaterItemsList[tableType][iTableStringIndex], maxlen);
    return true;
}

public int Native_GetWeaponItemName(Handle plugin, args)
{
    return GetItemNameByTableType(THEATER_ITEM_TABLE_WEAPONS, GetNativeCell(1), GetNativeCell(3));
}

public int Native_GetWeaponUpgradeItemName(Handle plugin, args)
{
    return GetItemNameByTableType(THEATER_ITEM_TABLE_WEAPON_UPGRADES, GetNativeCell(1), GetNativeCell(3));
}

public int Native_GetExplosiveItemName(Handle plugin, args)
{
    return GetItemNameByTableType(THEATER_ITEM_TABLE_EXPLOSIVES, GetNativeCell(1), GetNativeCell(3));
}

public int Native_GetPlayerGearItemName(Handle plugin, args)
{
    return GetItemNameByTableType(THEATER_ITEM_TABLE_PLAYER_GEAR, GetNativeCell(1), GetNativeCell(3));
}
