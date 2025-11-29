#if defined _stats_included_
  #endinput
#endif 
#define _stats_included_

/**
 * updates player revives for other plugins
 *
 * @param client    int pointing to client
 * @return          bool success/failure
 */
native bool update_revive_count(int client);

/**
 * updates player healed_hp for other plugins
 *
 * @param client    int pointing to client
 * @param hp_val    int val amount of healed_hp to add
 * @return          bool success/failure
 */
native bool update_healed_hp_count(int client, int hp_val);

/**
 * updates player medic_time for other plugins
 *
 * @param client        int pointing to client
 * @param time_to_add   int val amount of medic_time to add
 * @return          bool success/failure
 */
native bool update_medic_time(int client, int time_to_add);