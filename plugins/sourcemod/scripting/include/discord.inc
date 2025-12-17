#if defined _discord_included_
  #endinput
#endif 
#define _discord_included_

/**
 * Sends message to discord for other plugins
 *
 * @param client    int pointing to client
 * @param message   char[] containing the message to send
 * @return          bool success/failure
 */
native bool send_to_discord(int client, char[] message);