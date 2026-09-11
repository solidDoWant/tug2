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

/**
 * Builds the same linked display name that send_to_discord puts in front of a message, so a
 * plugin can name other players in the body the same way.
 *
 * @param client    int pointing to client
 * @param buffer    char[] to receive the link
 * @param maxlen    size of buffer
 * @return          bool true if the client was in game and a link was written
 */
native bool discord_player_link(int client, char[] buffer, int maxlen);
