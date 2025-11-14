#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
    name        = "Map Change Logger",
    author      = "sdw",
    description = "Logs map changes to console",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/solidDoWant/tug2"
};

public void OnMapEnd()
{
    char currentMap[64], nextMap[64];
    GetCurrentMap(currentMap, sizeof(currentMap));
    GetNextMap(nextMap, sizeof(nextMap));
    PrintToServer("Map changing from %s to %s", currentMap, nextMap);
}
