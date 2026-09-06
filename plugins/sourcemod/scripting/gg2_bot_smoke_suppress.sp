/**
 * [GG2 BOT SMOKE SUPPRESS] Make bots occasionally fire blind into smoke.
 *
 * WHY THIS EXISTS
 * Insurgency already blind-fires: ins_bot_suppressing_fire_duration is documented in the engine as
 * "How long should we light up the last spotted area of a threat", and betterbots.cfg raises it to
 * 5.0 (stock 2.0) with ins_bot_suppress_visible_requirement at 0.25 (stock 1.00). So a bot that
 * catches a glimpse of you and then loses line of sight - because you popped smoke - keeps hosing
 * your last known position for five seconds.
 *
 * The gap that mechanic cannot cover is smoke thrown BEFORE being seen. With no "last spotted
 * area" there is nothing for the engine to suppress, so a squad can walk through pre-emptive smoke
 * untouched. That is the abuse case this plugin targets.
 *
 * HOW IT WORKS
 * Rather than fighting the AI for control of aim and trigger - which does not work, because
 * Insurgency bots are NextBot-driven and re-derive both every tick, ignoring injected usercmd
 * buttons - this seeds the bot's *vision* and lets the stock suppression code do the shooting:
 *
 *   NextBotPlayer<CINSPlayer>::MyNextBotPointer()  ->  INextBot*
 *   CINSNextBot::GetVisionInterface()              ->  IVision*
 *   IVision::AddKnownEntity(player)                ->  bot now "knows" a threat it never saw
 *
 * Because smoke still blocks line of sight, that known entity is known-but-not-visible, which is
 * exactly the state the engine's suppression path already handles - including
 * CINSNextBot::GetSuppressingOffset(), the engine's own aim scatter. The bot sprays roughly where
 * the player is rather than tracking them precisely, which is the intended feel.
 *
 * STATUS: UNTESTED. This calls into NextBot internals; a wrong assumption crashes the server
 * rather than misbehaving quietly. It ships disabled - sm_bot_smoke_suppress_enabled defaults to
 * 0. Read the testing notes in gg2_bot_smoke_suppress.md before turning it on.
 */
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
    name        = "[GG2 BOT SMOKE SUPPRESS] Blind fire into smoke",
    author      = "solidDoWant",
    description = "Bots occasionally suppress smoke clouds they could not otherwise know to shoot at",
    version     = "0.1.0",
    url         = "https://github.com/solidDoWant/tug2"
};

Handle    g_hMyNextBotPointer  = null;
Handle    g_hGetVisionInterface = null;
Handle    g_hAddKnownEntity    = null;
// Diagnostics, used only by the selftest command.
Handle    g_hGetPrimaryThreat  = null;
Handle    g_hKE_GetEntity      = null;
Handle    g_hKE_VisibleRecent  = null;
Handle    g_hKE_TimeSinceSeen  = null;
Handle    g_hKE_WasEverVisible = null;
Handle    g_hKE_UpdateVis      = null;
Handle    g_hLineOfFireClear   = null;
Handle    g_hKE_MarkSeen       = null;
Handle    g_hGetWeaponClass    = null;
bool      g_bReady             = false;

ConVar    g_cvEnabled, g_cvChance, g_cvInterval, g_cvRange, g_cvRadius, g_cvClassnames, g_cvDebug;
ConVar    g_cvNoPursue;
ConVar    g_cvStage;
ConVar    g_cvReseed;
ConVar    g_cvWeaponClasses;
ConVar    g_cvInSmoke;
float     g_fBotLastSeed[MAXPLAYERS + 1];

// GetGameTime() until which a given client counts as smoke-seeded. While that is in the future the
// pursuit detour denies chasing them, which is what turns "walk into the smoke" into "shoot at it".
float     g_fSeededUntil[MAXPLAYERS + 1];

// Detour instrumentation: is ShouldPursue even being asked, and are we matching it?
int       g_iPursueCalls = 0, g_iPursueDenied = 0, g_iPursueNonClient = 0, g_iPursueStale = 0;
// Objective measure of whether any of this produces gunfire: shots fired by bots that are near a
// tracked smoke. Compare the per-sweep rate with the plugin enabled vs disabled - a vibe is not
// evidence, and bots shoot at plenty of other things.
int       g_iBotShotsNearSmoke = 0;
// Split those shots by whether the firing bot was itself standing in the cloud. Nothing in the
// plugin or in the four engine guards tests the bot's own position, so bots inside the smoke are
// expected to suppress too - this measures it rather than assuming.
int       g_iShotsInSmoke = 0, g_iShotsOutSmoke = 0;
// Why are eligible-looking bots not being seeded? Separate 'no weapon entity' from 'weapon class
// not on the whitelist' - the first would mean the prop lookup is wrong, the second that bots are
// genuinely holding sidearms/knives at the moment we sample them.
int       g_iSkipNoWeapon = 0, g_iSkipBadClass = 0, g_iSeeded = 0, g_iLastBadClass = -1;

// Refreshed once per sweep so the pursuit detour can decide with pure comparisons instead of
// SDKCalls. g_iBotNextBot maps a client to its INextBot address, which is what ShouldPursue is
// handed as its first argument; g_bBotCanSuppress caches the weapon-class eligibility.
int       g_iBotNextBot[MAXPLAYERS + 1];
int       g_iBotVision[MAXPLAYERS + 1];
bool      g_bBotInSmoke[MAXPLAYERS + 1];
int       g_iUnblinded = 0;

// Weapons to report as class 10 so the engine's hardcoded {9,10,12} gate in Combat::Update lets
// them suppress. Populated per sweep from bots whose real class is on the user's whitelist but not
// on the engine's. Addresses only - the detour never dereferences.
#define PROMO_SLOTS 64
int       g_aPromoWeapon[PROMO_SLOTS];
float     g_aPromoExp[PROMO_SLOTS];
int       g_iPromoSlot = 0, g_iPromoted = 0;

// One-shot window for the weapon-class gate.
//
// Promoting GetWeaponClass unconditionally does not work: ChooseBestWeapon and the retreat/ammo
// branches read the same value earlier in CINSBotCombat::Update, so lying to all of them derails
// the bot before it reaches the gate (measured: 145 -> 26 -> 0 shots as promotion widened).
//
// But the call order is exploitable. UpdateInternalInfo runs AFTER ChooseBestWeapon and BEFORE the
// gate, so detouring it arms a flag that the very next GetWeaponClass consumes. Earlier reads in
// the same tick see the truth; only the gate is lied to.
bool      g_bGateWindow = false;
int       g_iGateHits = 0;
bool      g_bBotCanSuppress[MAXPLAYERS + 1];
int       g_iAttackForced = 0;
int       g_iSuppressForced = 0;
int       g_iCombatUpdates = 0;
int       g_iAgeForced = 0;


// Entity references for live smoke clouds. References rather than indices so a recycled index
// cannot make us read a different entity.
ArrayList g_aSmokes;
Handle    g_hTimer = null;

public void OnPluginStart()
{
    g_aSmokes = new ArrayList();

    g_cvEnabled = CreateConVar("sm_bot_smoke_suppress_enabled", "0",
        "Let bots blind-fire at smoke they have not seen anyone enter. 0 = off (default).");
    g_cvChance = CreateConVar("sm_bot_smoke_suppress_chance", "0.25",
        "Per-pass chance that an eligible bot is given knowledge of a smoked player. 0.0-1.0.", _, true, 0.0, true, 1.0);
    g_cvInterval = CreateConVar("sm_bot_smoke_suppress_interval", "2.0",
        "Seconds between passes. Each pass rolls the chance once per eligible bot.", _, true, 0.5, true, 30.0);
    g_cvRange = CreateConVar("sm_bot_smoke_suppress_range", "1500.0",
        "Maximum distance from a bot to the smoke for that bot to be eligible.", _, true, 0.0, false);
    g_cvRadius = CreateConVar("sm_bot_smoke_suppress_radius", "250.0",
        "How close a player must be to a smoke cloud to be considered hidden by it.", _, true, 0.0, false);
    g_cvClassnames = CreateConVar("sm_bot_smoke_suppress_classnames", "grenade_m18,grenade_smoke",
        "Comma-separated substrings matched against entity classnames to identify smoke clouds.");
    g_cvNoPursue = CreateConVar("sm_bot_smoke_suppress_nopursue_time", "6.0",
        "Seconds after seeding during which bots are denied pursuit of that player, so they shoot instead of walking in. Pair with ins_bot_suppressing_fire_duration.", _, true, 0.0, true, 60.0);
    // Bisect switch. Guessing at the crashing call one build at a time has now been wrong twice,
    // so every step of the seeding sequence is individually switchable at runtime:
    //   0 = AddKnownEntity only            (known good - this is what produced 114 shots)
    //   1 = + UpdateVisibilityStatus       (visual memory)
    //   2 = + MarkLastKnownPositionAsSeen  (added with the crash; prime suspect)
    // The age override is separate (sm_bot_smoke_suppress_age_override).
    // The real fix for the age guard. Combat::Update refuses to suppress a threat that has not
    // been known for longer than a threshold, and re-seeding kept resetting that clock to zero -
    // our own aggressiveness held the gate shut. Seed a given bot once, then leave its known entity
    // alone so the age climbs naturally past the threshold. No hook, no synthesised value.
    g_cvReseed = CreateConVar("sm_bot_smoke_suppress_reseed_cooldown", "8.0",
        "Seconds before the same bot may be seeded again. Lets the injected threat age past the engine's suppression threshold.", _, true, 0.0, true, 60.0);
    g_cvWeaponClasses = CreateConVar("sm_bot_smoke_suppress_weapon_classes", "9,10,12",
        "Weapon classes allowed to suppress. 9=SMG 10=rifle 12=LMG are native; anything else here is promoted so the engine accepts it (e.g. add 11 for DMRs).");
    // Bots standing inside the cloud never fired: 57 of 57 suppressing shots came from outside.
    // They are flagged blinded by their own smoke and hold fire. Enabling this clears that flag for
    // bots inside the cloud so they suppress too. Off by default - a bot engulfed in smoke holding
    // fire is arguably the more believable behaviour.
    g_cvInSmoke = CreateConVar("sm_bot_smoke_suppress_include_in_smoke", "0",
        "Let bots standing inside the smoke cloud suppress as well, by clearing their blinded flag.");
    g_cvStage = CreateConVar("sm_bot_smoke_suppress_stage", "1",
        "How far the seeding sequence runs. 0=AddKnownEntity, 1=+visual memory, 2=+mark position seen.", _, true, 0.0, true, 2.0);
    g_cvDebug = CreateConVar("sm_bot_smoke_suppress_debug", "0",
        "Log every suppression decision. Noisy - troubleshooting only.");

    // The sweep timer is built once, so the interval has to restart it to take effect - otherwise
    // tuning it live silently does nothing.
    g_cvInterval.AddChangeHook(OnIntervalChanged);

    AutoExecConfig(true, "gg2_bot_smoke_suppress");

    HookEvent("weapon_fire", Event_WeaponFire);

    Handle conf = LoadGameConfigFile("tug2.games");
    if (conf == null)
    {
        LogError("[SMOKE SUPPRESS] Could not load gamedata/tug2.games.txt - plugin inert.");
        return;
    }

    g_hMyNextBotPointer = PrepCall(conf, "NextBotPlayer_CINSPlayer::MyNextBotPointer", true);

    // Virtual - see the comment in tug2.games.txt for why this cannot be a direct symbol call.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "INextBot::GetVisionInterface"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hGetVisionInterface = EndPrepSDKCall();
    }
    if (g_hGetVisionInterface == null) LogError("[SMOKE SUPPRESS] Failed to prepare INextBot::GetVisionInterface");

    // IVision::AddKnownEntity(CBaseEntity *) - also virtual.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "IVision::AddKnownEntity"))
    {
        PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
        g_hAddKnownEntity = EndPrepSDKCall();
    }
    if (g_hAddKnownEntity == null) LogError("[SMOKE SUPPRESS] Failed to prepare IVision::AddKnownEntity");

    // The CINSNextBot::IsLineOfFireClear check that used to live here was removed: it has the
    // same wrong-this-pointer problem as GetVisionInterface did, and it is only an
    // optimisation. Without it a bot may occasionally suppress a cloud it has no shot at.

    g_hGetPrimaryThreat  = PrepVirt(conf, "IVision::GetPrimaryKnownThreat", SDKType_Bool, true);
    g_hKE_GetEntity      = PrepVirtEnt(conf, "CKnownEntity::GetEntity");
    g_hKE_VisibleRecent  = PrepVirtRet(conf, "CKnownEntity::IsVisibleRecently", SDKType_Bool);
    g_hKE_TimeSinceSeen  = PrepVirtRet(conf, "CKnownEntity::GetTimeSinceLastSeen", SDKType_Float);
    g_hKE_WasEverVisible = PrepVirtRet(conf, "CKnownEntity::WasEverVisible", SDKType_Bool);

    // int CINSWeapon::GetWeaponClass() const - virtual on the weapon entity. Returns int, so it is
    // safe to detour/call (unlike the float-returning accessors).
    StartPrepSDKCall(SDKCall_Entity);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CINSWeapon::GetWeaponClass"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hGetWeaponClass = EndPrepSDKCall();
    }
    if (g_hGetWeaponClass == null)
        LogError("[SMOKE SUPPRESS] GetWeaponClass unavailable - cannot filter bots that can never suppress");

    // void CKnownEntity::MarkLastKnownPositionAsSeen()
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CKnownEntity::MarkLastKnownPositionAsSeen"))
        g_hKE_MarkSeen = EndPrepSDKCall();

    // void CKnownEntity::UpdateVisibilityStatus(bool)
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CKnownEntity::UpdateVisibilityStatus"))
    {
        PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
        g_hKE_UpdateVis = EndPrepSDKCall();
    }
    if (g_hKE_UpdateVis == null)
        LogError("[SMOKE SUPPRESS] CKnownEntity::UpdateVisibilityStatus missing - bots will search instead of fire");

    // Deny pursuit of seeded targets. AddKnownEntity alone gives the bot a threat it has never
    // seen, and its assessment answers "pursue" - which is why bots were walking into the smoke.
    // Both ShouldPursue implementations are detoured; either can be the one asking.
    int detours = 0;
    if (HookPursue(conf, "CINSBotMainAction::ShouldPursue")) detours++;
    if (HookPursue(conf, "CINSBotCombat::ShouldPursue")) detours++;
    // ...and force the attack answer, otherwise the bot simply idles with nowhere to go.
    if (HookAttack(conf, "Behavior_CINSNextBot::ShouldAttack")) detours++;
    if (HookAttack(conf, "CINSBotTacticalMonitor::ShouldAttack")) detours++;

    // ...and force the actual suppression gate, which is what builds CINSBotSuppressTarget.
    if (HookSuppress(conf, "CINSNextBot::ShouldSuppressThreat")) detours++;

    // NOTE: there was a detour on CKnownEntity::GetTimeSinceBecameKnown here to defeat the age
    // guard. Removed - it returns a FLOAT, and on 32-bit x86 that comes back on the x87 stack.
    // Wrapping that with DHooks on a function the AI calls hundreds of times a second crashed the
    // server on every smoke throw, even when the callback did nothing but MRES_Ignored. The age
    // guard is now satisfied honestly instead: see the re-seed cooldown below.

    // NOTE: an IsVisibleInFOVNow override used to live here. Dropped - for a target in smoke it is
    // already false, so it changed nothing while adding a second way to push the AI off its
    // expected paths. Keep the number of synthesised lies to the minimum that actually matters.

    // Promote non-native weapon classes so the whitelist cvar actually widens who can suppress.
    DynamicDetour ddWc = DynamicDetour.FromConf(conf, "CINSWeapon::GetWeaponClass_sig");
    if (ddWc != null && ddWc.Enable(Hook_Pre, Detour_GetWeaponClass)) detours++;
    else LogError("[SMOKE SUPPRESS] GetWeaponClass promotion detour not installed");

    // Blinded override, so bots inside the cloud can suppress too (gated by cvar at call time).
    DynamicDetour ddBlind = DynamicDetour.FromConf(conf, "CINSBotVision::IsBlinded");
    if (ddBlind != null && ddBlind.Enable(Hook_Pre, Detour_IsBlinded)) detours++;
    else LogError("[SMOKE SUPPRESS] IsBlinded detour not installed");

    // Pure observer: how often does the Combat action actually run?
    DynamicDetour ddc = DynamicDetour.FromConf(conf, "CINSBotCombat::UpdateInternalInfo");
    if (ddc != null && ddc.Enable(Hook_Pre, Detour_CombatUpdate)) detours++;
    else LogError("[SMOKE SUPPRESS] combat-update counter not installed");

    if (detours == 0)
        LogError("[SMOKE SUPPRESS] No pursuit detours installed - bots will walk into smoke rather than shoot it");
    else
        LogMessage("[SMOKE SUPPRESS] %d pursuit detour(s) installed", detours);

    // Diagnostic: does smoke block the bot's line of fire? Entity address is the this-pointer.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CINSNextBot::IsLineOfFireClear"))
    {
        PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
        PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
        g_hLineOfFireClear = EndPrepSDKCall();
    }

    delete conf;

    g_bReady = (g_hMyNextBotPointer != null && g_hGetVisionInterface != null && g_hAddKnownEntity != null);
    if (!g_bReady)
    {
        LogError("[SMOKE SUPPRESS] Required signatures missing - plugin inert.");
        return;
    }

    // DEBUG ONLY. Exercises the SDKCall chain directly on two clients, bypassing the smoke and
    // geometry checks, so the dangerous part can be validated on an empty server. Each step is
    // logged before it runs: if the server dies, the last line written names the call that did it.
    // RegServerCmd, so this is reachable from RCON/console only - never from a client.
    // Read a bot's current primary known threat WITHOUT injecting anything. Run this a second or
    // two after a selftest to see whether the injected entry survived the engine's vision update.
    // Map GetWeaponClass() ints to real weapons empirically - the enum has no symbol and the
    // name table could not be recovered statically, so the whitelist {9,10,12} was read out of a
    // bitmask in the disassembly and is otherwise unlabelled.
    RegServerCmd("sm_bot_smoke_suppress_dumpclasses", Cmd_DumpClasses,
        "DEBUG: print each bot's active weapon and its GetWeaponClass() value");

    RegServerCmd("sm_bot_smoke_suppress_peek", Cmd_Peek,
        "DEBUG: read a bot's primary known threat. Args: <botIndex>");

    RegServerCmd("sm_bot_smoke_suppress_selftest", Cmd_SelfTest,
        "DEBUG: exercise the NextBot SDKCall chain. Args: <botIndex> <targetIndex>");

    RestartTimer();
    LogMessage("[SMOKE SUPPRESS] Loaded. Enabled=%d interval=%.1f", g_cvEnabled.BoolValue, g_cvInterval.FloatValue);
}

Action Cmd_DumpClasses(int args)
{
    if (g_hGetWeaponClass == null) { PrintToServer("[SMOKE SUPPRESS] GetWeaponClass unavailable"); return Plugin_Handled; }

    char seen[32][64];
    int classOf[32];
    int n = 0;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || !IsPlayerAlive(c)) continue;
        int wep = GetEntPropEnt(c, Prop_Send, "m_hActiveWeapon");
        if (wep <= 0 || !IsValidEntity(wep)) continue;

        char cls[64];
        GetEntityClassname(wep, cls, sizeof(cls));
        int wc = SDKCall(g_hGetWeaponClass, wep);

        bool dup = false;
        for (int i = 0; i < n; i++)
            if (classOf[i] == wc && StrEqual(seen[i], cls)) { dup = true; break; }
        if (dup || n >= 32) continue;

        strcopy(seen[n], 64, cls);
        classOf[n] = wc;
        n++;
    }

    PrintToServer("[SMOKE SUPPRESS] weapon class map (%d distinct):", n);
    for (int i = 0; i < n; i++)
        PrintToServer("[SMOKE SUPPRESS]   class %2d  %s%s", classOf[i], seen[i],
                      (classOf[i] == 9 || classOf[i] == 10 || classOf[i] == 12) ? "   <-- CAN SUPPRESS" : "");
    return Plugin_Handled;
}

Action Cmd_Peek(int args)
{
    if (!g_bReady || g_hGetPrimaryThreat == null) { PrintToServer("[SMOKE SUPPRESS] peek: not ready"); return Plugin_Handled; }
    char a1[8]; GetCmdArg(1, a1, sizeof(a1));
    int bot = StringToInt(a1);
    if (bot < 1 || bot > MaxClients || !IsClientInGame(bot)) { PrintToServer("[SMOKE SUPPRESS] peek: bad bot index"); return Plugin_Handled; }

    int nextbot = SDKCall(g_hMyNextBotPointer, bot);
    if (nextbot == 0) { PrintToServer("[SMOKE SUPPRESS] peek: no nextbot"); return Plugin_Handled; }
    int vision = SDKCall(g_hGetVisionInterface, nextbot);
    if (vision == 0) { PrintToServer("[SMOKE SUPPRESS] peek: no vision"); return Plugin_Handled; }

    int known = SDKCall(g_hGetPrimaryThreat, vision, false);
    if (known == 0) { PrintToServer("[SMOKE SUPPRESS] peek: NO primary known threat (injection did not survive)"); return Plugin_Handled; }

    int ent = SDKCall(g_hKE_GetEntity, known);
    bool visRecent = SDKCall(g_hKE_VisibleRecent, known);
    bool everVis = SDKCall(g_hKE_WasEverVisible, known);
    float since = SDKCall(g_hKE_TimeSinceSeen, known);
    PrintToServer("[SMOKE SUPPRESS] peek: primary threat entity=%d visibleRecently=%d wasEverVisible=%d timeSinceSeen=%.2f",
                  ent, visRecent, everVis, since);
    return Plugin_Handled;
}

Action Cmd_SelfTest(int args)
{
    if (!g_bReady)
    {
        PrintToServer("[SMOKE SUPPRESS] selftest: plugin not ready (signatures missing)");
        return Plugin_Handled;
    }
    if (args < 2)
    {
        PrintToServer("[SMOKE SUPPRESS] usage: sm_bot_smoke_suppress_selftest <botIndex> <targetIndex>");
        return Plugin_Handled;
    }

    char a1[8], a2[8];
    GetCmdArg(1, a1, sizeof(a1));
    GetCmdArg(2, a2, sizeof(a2));
    int bot = StringToInt(a1), target = StringToInt(a2);

    if (bot < 1 || bot > MaxClients || !IsClientInGame(bot) || !IsPlayerAlive(bot))
    {
        PrintToServer("[SMOKE SUPPRESS] selftest: bot %d not an in-game living client", bot);
        return Plugin_Handled;
    }
    if (target < 1 || target > MaxClients || !IsClientInGame(target) || !IsPlayerAlive(target))
    {
        PrintToServer("[SMOKE SUPPRESS] selftest: target %d not an in-game living client", target);
        return Plugin_Handled;
    }

    PrintToServer("[SMOKE SUPPRESS] selftest: step 1 MyNextBotPointer(%d)", bot);
    int nextbot = SDKCall(g_hMyNextBotPointer, bot);
    PrintToServer("[SMOKE SUPPRESS] selftest: step 1 ok, INextBot=0x%x", nextbot);
    if (nextbot == 0) return Plugin_Handled;

    PrintToServer("[SMOKE SUPPRESS] selftest: step 2 GetVisionInterface");
    int vision = SDKCall(g_hGetVisionInterface, nextbot);
    PrintToServer("[SMOKE SUPPRESS] selftest: step 2 ok, IVision=0x%x", vision);
    if (vision == 0) return Plugin_Handled;

    PrintToServer("[SMOKE SUPPRESS] selftest: step 4 AddKnownEntity(target=%d)", target);
    SDKCall(g_hAddKnownEntity, vision, target);
    PrintToServer("[SMOKE SUPPRESS] selftest: step 4 ok - full chain survived");

    // Is the engine willing to let this bot shoot at the target's position at all?
    if (g_hLineOfFireClear != null)
    {
        float tpos[3];
        GetClientAbsOrigin(target, tpos);
        tpos[2] += 40.0;
        Address botAddr = GetEntityAddress(bot);
        PrintToServer("[SMOKE SUPPRESS] selftest: step 7 IsLineOfFireClear via entity addr 0x%x", botAddr);
        bool lof = SDKCall(g_hLineOfFireClear, botAddr, tpos);
        PrintToServer("[SMOKE SUPPRESS] selftest: LINE OF FIRE to target = %s", lof ? "CLEAR (engine would allow the shot)" : "BLOCKED (engine will never shoot there)");
    }

    // Read the injection back. This is the part that actually answers whether the engine kept the
    // known entity, and whether it thinks the target is visible (-> accurate fire) or merely known
    // (-> suppression of the last known position, which is what we want).
    if (g_hGetPrimaryThreat == null) { PrintToServer("[SMOKE SUPPRESS] selftest: no read-back handles"); return Plugin_Handled; }

    int known = SDKCall(g_hGetPrimaryThreat, vision, false);
    PrintToServer("[SMOKE SUPPRESS] selftest: step 5 GetPrimaryKnownThreat = 0x%x", known);
    if (known == 0)
    {
        PrintToServer("[SMOKE SUPPRESS] selftest: VERDICT injection did NOT stick (no primary threat)");
        return Plugin_Handled;
    }

    int ent = (g_hKE_GetEntity != null) ? SDKCall(g_hKE_GetEntity, known) : -1;
    bool visRecent = (g_hKE_VisibleRecent != null) ? SDKCall(g_hKE_VisibleRecent, known) : false;
    bool everVis = (g_hKE_WasEverVisible != null) ? SDKCall(g_hKE_WasEverVisible, known) : false;
    float sinceSeen = (g_hKE_TimeSinceSeen != null) ? SDKCall(g_hKE_TimeSinceSeen, known) : -1.0;

    PrintToServer("[SMOKE SUPPRESS] selftest: BEFORE memory: entity=%d (target %d) visibleRecently=%d wasEverVisible=%d timeSinceSeen=%.2f",
                  ent, target, visRecent, everVis, sinceSeen);

    if (ent == target && g_hKE_UpdateVis != null)
    {
        PrintToServer("[SMOKE SUPPRESS] selftest: step 6 UpdateVisibilityStatus(true) then (false)");
        SDKCall(g_hKE_UpdateVis, known, true);
        SDKCall(g_hKE_UpdateVis, known, false);
        visRecent = SDKCall(g_hKE_VisibleRecent, known);
        everVis   = SDKCall(g_hKE_WasEverVisible, known);
        sinceSeen = SDKCall(g_hKE_TimeSinceSeen, known);
        PrintToServer("[SMOKE SUPPRESS] selftest: AFTER  memory: visibleRecently=%d wasEverVisible=%d timeSinceSeen=%.2f",
                      visRecent, everVis, sinceSeen);
    }
    if (ent != target)
        PrintToServer("[SMOKE SUPPRESS] selftest: VERDICT primary threat is a DIFFERENT entity - injection lost or outranked");
    else if (visRecent)
        PrintToServer("[SMOKE SUPPRESS] selftest: VERDICT treated as VISIBLE - bots would shoot accurately. Approach is a dead end.");
    else
        PrintToServer("[SMOKE SUPPRESS] selftest: VERDICT known but NOT visible - correct state for suppression.");
    return Plugin_Handled;
}

// Both of these return a raw pointer. onPlayer selects the call type: the first is invoked on a
// player entity, the rest on pointers we already hold.
Handle PrepCall(Handle conf, const char[] name, bool onPlayer)
{
    StartPrepSDKCall(onPlayer ? SDKCall_Player : SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(conf, SDKConf_Signature, name))
    {
        LogError("[SMOKE SUPPRESS] Signature not found: %s", name);
        return null;
    }
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    return EndPrepSDKCall();
}

// Virtual call returning a raw pointer, with one optional argument.
Handle PrepVirt(Handle conf, const char[] name, SDKType argType, bool hasArg)
{
    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, name)) { LogError("[SMOKE SUPPRESS] missing %s", name); return null; }
    if (hasArg) PrepSDKCall_AddParameter(argType, SDKPass_Plain);
    PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
    return EndPrepSDKCall();
}

// Virtual call returning an entity (SourceMod hands back an index).
Handle PrepVirtEnt(Handle conf, const char[] name)
{
    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, name)) { LogError("[SMOKE SUPPRESS] missing %s", name); return null; }
    PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
    return EndPrepSDKCall();
}

// Virtual call returning a plain value.
Handle PrepVirtRet(Handle conf, const char[] name, SDKType ret)
{
    StartPrepSDKCall(SDKCall_Raw);
    if (!PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, name)) { LogError("[SMOKE SUPPRESS] missing %s", name); return null; }
    PrepSDKCall_SetReturnInfo(ret, SDKPass_Plain);
    return EndPrepSDKCall();
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bReady || !g_cvDebug.BoolValue) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsFakeClient(client)) return;
    if (g_aSmokes.Length == 0) return;

    float bPos[3];
    GetClientAbsOrigin(client, bPos);
    float range = g_cvRange.FloatValue;

    for (int i = 0; i < g_aSmokes.Length; i++)
    {
        int ent = EntRefToEntIndex(g_aSmokes.Get(i));
        if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent)) continue;
        float sPos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", sPos);
        float dist = GetVectorDistance(bPos, sPos);
        if (dist <= range)
        {
            g_iBotShotsNearSmoke++;
            if (dist <= g_cvRadius.FloatValue) g_iShotsInSmoke++;
            else                               g_iShotsOutSmoke++;
            return;
        }
    }
}

// Both of these are called on a CKnownEntity, so pThis IS the known entity - no param to read.
// Only ever override for an entity we seeded; everything else falls through untouched.
// this is the CINSBotVision. Matched against the per-sweep cache with plain comparisons - no
// SDKCall, no dereference, because this runs on every bot every tick.
// Report a promoted weapon as class 10 (assault rifle) so Combat::Update's {9,10,12} check passes.
// Scoped as tightly as possible: only weapons recorded this sweep, only while their bot is seeded.
public MRESReturn Detour_GetWeaponClass(Address pThis, DHookReturn hReturn)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return MRES_Ignored;

    // Only the first read after UpdateInternalInfo - that is the gate. Consume the window either
    // way, so a non-promoted weapon cannot leave it armed for some later unrelated call.
    if (!g_bGateWindow) return MRES_Ignored;
    g_bGateWindow = false;

    int w = view_as<int>(pThis);
    float now = GetGameTime();
    for (int i = 0; i < PROMO_SLOTS; i++)
    {
        if (g_aPromoWeapon[i] != w || g_aPromoExp[i] <= now) continue;
        g_iPromoted++; g_iGateHits++;
        DHookSetReturn(hReturn, 10);
        return MRES_Supercede;
    }
    return MRES_Ignored;
}

public MRESReturn Detour_IsBlinded(Address pThis, DHookReturn hReturn)
{
    if (!g_bReady || !g_cvEnabled.BoolValue || !g_cvInSmoke.BoolValue) return MRES_Ignored;

    int v = view_as<int>(pThis);
    for (int b = 1; b <= MaxClients; b++)
    {
        if (g_iBotVision[b] != v) continue;
        if (!g_bBotInSmoke[b]) return MRES_Ignored;
        g_iUnblinded++;
        DHookSetReturn(hReturn, false);
        return MRES_Supercede;
    }
    return MRES_Ignored;
}

public MRESReturn Detour_CombatUpdate(Address pThis)
{
    g_iCombatUpdates++;
    // Arm the gate window - ChooseBestWeapon has already run by this point.
    g_bGateWindow = true;
    return MRES_Ignored;
}

bool HookSuppress(Handle conf, const char[] name)
{
    DynamicDetour dd = DynamicDetour.FromConf(conf, name);
    if (dd == null) { LogError("[SMOKE SUPPRESS] detour setup failed: %s", name); return false; }
    if (!dd.Enable(Hook_Pre, Detour_ShouldSuppressThreat)) { LogError("[SMOKE SUPPRESS] detour enable failed: %s", name); return false; }
    return true;
}

// bool CINSNextBot::ShouldSuppressThreat(CKnownEntity const *) const - only ONE argument, so the
// known entity is param 1 here, not param 2 like the two-arg query hooks.
public MRESReturn Detour_ShouldSuppressThreat(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return MRES_Ignored;
    if (g_hKE_GetEntity == null) return MRES_Ignored;

    int known = DHookGetParam(hParams, 1);
    if (known == 0) return MRES_Ignored;

    int ent = SDKCall(g_hKE_GetEntity, known);
    if (ent < 1 || ent > MaxClients) return MRES_Ignored;
    if (g_fSeededUntil[ent] <= GetGameTime()) return MRES_Ignored;

    g_iSuppressForced++;
    DHookSetReturn(hReturn, true);
    return MRES_Supercede;
}

bool HookAttack(Handle conf, const char[] name)
{
    DynamicDetour dd = DynamicDetour.FromConf(conf, name);
    if (dd == null) { LogError("[SMOKE SUPPRESS] detour setup failed: %s", name); return false; }
    if (!dd.Enable(Hook_Pre, Detour_ShouldAttack)) { LogError("[SMOKE SUPPRESS] detour enable failed: %s", name); return false; }
    return true;
}

// Mirror of the pursuit detour, but forcing ANSWER_YES (1) instead of ANSWER_NO.
public MRESReturn Detour_ShouldAttack(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return MRES_Ignored;
    if (g_hKE_GetEntity == null) return MRES_Ignored;

    int known = DHookGetParam(hParams, 2);
    if (known == 0) return MRES_Ignored;

    int ent = SDKCall(g_hKE_GetEntity, known);
    if (ent < 1 || ent > MaxClients) return MRES_Ignored;
    if (g_fSeededUntil[ent] <= GetGameTime()) return MRES_Ignored;

    g_iAttackForced++;
    DHookSetReturn(hReturn, 1);
    return MRES_Supercede;
}

bool HookPursue(Handle conf, const char[] name)
{
    DynamicDetour dd = DynamicDetour.FromConf(conf, name);
    if (dd == null) { LogError("[SMOKE SUPPRESS] detour setup failed: %s", name); return false; }
    if (!dd.Enable(Hook_Pre, Detour_ShouldPursue)) { LogError("[SMOKE SUPPRESS] detour enable failed: %s", name); return false; }
    return true;
}

// QueryResultType: ANSWER_NO = 0, ANSWER_YES = 1, ANSWER_UNDEFINED = 2.
// Only ever supersedes for a client we seeded within the last nopursue_time seconds; every other
// call falls straight through, so ordinary bot behaviour is untouched.
public MRESReturn Detour_ShouldPursue(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return MRES_Ignored;
    if (g_hKE_GetEntity == null) return MRES_Ignored;

    g_iPursueCalls++;

    // Only withhold pursuit from bots the engine would actually let suppress. Denying it to a bot
    // holding a pistol just strands it: it cannot chase and cannot shoot, so it stands there. That
    // idling was the regression this check fixes. Pure array lookups - no SDKCall in a hot detour.
    int me = DHookGetParam(hParams, 1);
    if (me != 0)
    {
        bool known_bot = false;
        for (int b = 1; b <= MaxClients; b++)
        {
            if (g_iBotNextBot[b] != me) continue;
            known_bot = true;
            if (!g_bBotCanSuppress[b]) return MRES_Ignored;
            break;
        }
        if (!known_bot) return MRES_Ignored;
    }

    int known = DHookGetParam(hParams, 2);
    if (known == 0) return MRES_Ignored;

    int ent = SDKCall(g_hKE_GetEntity, known);
    if (ent < 1 || ent > MaxClients) { g_iPursueNonClient++; return MRES_Ignored; }
    if (g_fSeededUntil[ent] <= GetGameTime()) { g_iPursueStale++; return MRES_Ignored; }

    g_iPursueDenied++;
    DHookSetReturn(hReturn, 0);
    return MRES_Supercede;
}

public void OnClientDisconnect(int client)
{
    g_fSeededUntil[client] = 0.0;
}

public void OnIntervalChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    RestartTimer();
}

public void OnMapStart()
{
    g_aSmokes.Clear();
    RestartTimer();
}

public void OnMapEnd()
{
    g_aSmokes.Clear();
    if (g_hTimer != null) { KillTimer(g_hTimer); g_hTimer = null; }
}

void RestartTimer()
{
    if (g_hTimer != null) { KillTimer(g_hTimer); g_hTimer = null; }
    g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Sweep, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_bReady || entity <= MaxClients) return;

    char list[256];
    g_cvClassnames.GetString(list, sizeof(list));

    char parts[8][64];
    int n = ExplodeString(list, ",", parts, sizeof(parts), sizeof(parts[]));
    for (int i = 0; i < n; i++)
    {
        TrimString(parts[i]);
        if (parts[i][0] == '\0') continue;
        if (StrContains(classname, parts[i], false) == -1) continue;

        int ref = EntIndexToEntRef(entity);
        if (g_aSmokes.FindValue(ref) == -1) g_aSmokes.Push(ref);
        if (g_cvDebug.BoolValue) LogMessage("[SMOKE SUPPRESS] Tracking smoke '%s' (ent %d)", classname, entity);
        return;
    }
}

Action Timer_Sweep(Handle timer)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return Plugin_Continue;

    if (g_cvDebug.BoolValue)
    {
        LogMessage("[SMOKE SUPPRESS] pursue detour: calls=%d denied=%d nonClient=%d stale=%d attackForced=%d suppressForced=%d combatUpd=%d ageForced=%d | smokes=%d | BOT SHOTS near smoke=%d (inSmoke=%d outside=%d) | seeded=%d skipNoWep=%d skipClass=%d lastBadCls=%d unblinded=%d promoted=%d gateHits=%d",
                   g_iPursueCalls, g_iPursueDenied, g_iPursueNonClient, g_iPursueStale, g_iAttackForced, g_iSuppressForced, g_iCombatUpdates, g_iAgeForced, g_aSmokes.Length, g_iBotShotsNearSmoke, g_iShotsInSmoke, g_iShotsOutSmoke, g_iSeeded, g_iSkipNoWeapon, g_iSkipBadClass, g_iLastBadClass, g_iUnblinded, g_iPromoted, g_iGateHits);
        g_iPursueCalls = 0; g_iPursueDenied = 0; g_iPursueNonClient = 0; g_iPursueStale = 0; g_iBotShotsNearSmoke = 0; g_iShotsInSmoke = 0; g_iShotsOutSmoke = 0; g_iSeeded = 0; g_iSkipNoWeapon = 0; g_iSkipBadClass = 0; g_iUnblinded = 0; g_iPromoted = 0; g_iGateHits = 0; g_iAttackForced = 0; g_iSuppressForced = 0; g_iCombatUpdates = 0; g_iAgeForced = 0;
    }

    if (g_aSmokes.Length == 0) return Plugin_Continue;

    // Refresh the per-bot caches the pursuit detour reads.
    for (int b = 1; b <= MaxClients; b++)
    {
        g_iBotNextBot[b] = 0;
        g_bBotCanSuppress[b] = false;
        if (!IsClientInGame(b) || !IsFakeClient(b) || !IsPlayerAlive(b)) continue;
        g_iBotNextBot[b] = SDKCall(g_hMyNextBotPointer, b);
        g_iBotVision[b] = (g_iBotNextBot[b] != 0) ? SDKCall(g_hGetVisionInterface, g_iBotNextBot[b]) : 0;

        // How close is this bot to a tracked cloud? Only bots in play are evaluated at all: a bot
        // on the far side of the map has no business being pursuit-denied, and promoting its weapon
        // class is a lie told for no reason - which is exactly what tanked suppression when the
        // class list was widened (1276 promotions across the whole squad).
        g_bBotInSmoke[b] = false;
        bool nearSmoke = false;
        float bo[3]; GetClientAbsOrigin(b, bo);
        for (int i = 0; i < g_aSmokes.Length; i++)
        {
            int se = EntRefToEntIndex(g_aSmokes.Get(i));
            if (se == INVALID_ENT_REFERENCE || !IsValidEntity(se)) continue;
            float so[3]; GetEntPropVector(se, Prop_Send, "m_vecOrigin", so);
            float dd = GetVectorDistance(bo, so);
            if (dd <= g_cvRange.FloatValue) nearSmoke = true;
            if (dd <= g_cvRadius.FloatValue) { g_bBotInSmoke[b] = true; nearSmoke = true; break; }
        }

        g_bBotCanSuppress[b] = nearSmoke ? CanBotSuppress(b) : false;
    }

    float chance = g_cvChance.FloatValue;
    float range  = g_cvRange.FloatValue;
    float radius = g_cvRadius.FloatValue;

    // Walk backwards so removing dead references does not skip entries.
    for (int i = g_aSmokes.Length - 1; i >= 0; i--)
    {
        int ent = EntRefToEntIndex(g_aSmokes.Get(i));
        if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent))
        {
            g_aSmokes.Erase(i);
            continue;
        }

        float smokePos[3];
        GetEntPropVector(ent, Prop_Send, "m_vecOrigin", smokePos);

        // Why did a smoke produce no seeding? Almost always one of the two distance gates. Log the
        // nearest human and nearest enemy bot so the thresholds can be judged instead of guessed.
        if (g_cvDebug.BoolValue)
        {
            float bestP = 99999.0, bestB = 99999.0;
            int bestPc = -1;
            for (int c = 1; c <= MaxClients; c++)
            {
                if (!IsClientInGame(c) || !IsPlayerAlive(c)) continue;
                float o[3]; GetClientAbsOrigin(c, o);
                float dd = GetVectorDistance(o, smokePos);
                if (!IsFakeClient(c)) { if (dd < bestP) { bestP = dd; bestPc = c; } }
                else if (dd < bestB) bestB = dd;
            }
            LogMessage("[SMOKE SUPPRESS] smoke ent %d at (%.0f %.0f %.0f): nearest human=%.0f (radius %.0f) nearest bot=%.0f (range %.0f)%s",
                       ent, smokePos[0], smokePos[1], smokePos[2], bestP, radius, bestB, range,
                       bestPc == -1 ? " [no living human]" : "");
        }

        for (int client = 1; client <= MaxClients; client++)
        {
            if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client)) continue;

            float pPos[3];
            GetClientAbsOrigin(client, pPos);
            if (GetVectorDistance(pPos, smokePos) > radius) continue;

            for (int bot = 1; bot <= MaxClients; bot++)
            {
                if (!IsClientInGame(bot) || !IsFakeClient(bot) || !IsPlayerAlive(bot)) continue;
                if (GetClientTeam(bot) == GetClientTeam(client)) continue;

                float bPos[3];
                GetClientAbsOrigin(bot, bPos);
                if (GetVectorDistance(bPos, smokePos) > range) continue;
                if (GetURandomFloat() > chance) continue;
                // Do not reset the age clock on a bot we already seeded recently.
                if (g_fBotLastSeed[bot] > GetGameTime() - g_cvReseed.FloatValue) continue;

                g_fBotLastSeed[bot] = GetGameTime();
                g_iSeeded++;
                SeedKnowledge(bot, client, smokePos);
            }
        }
    }
    return Plugin_Continue;
}

// AddKnownEntity on its own is not enough. It leaves the entry with wasEverVisible=0, so the bot
// has no visual memory to suppress and its threat assessment sends it to investigate instead -
// which is why bots were seen running at the smoke rather than shooting into it. Marking the entry
// seen and then immediately unseen manufactures the exact state the engine's existing suppression
// path is written for: a threat glimpsed a moment ago and since lost. Only touches the entry if it
// really is the one we just injected, since the bot may have a more pressing threat.
void GiveVisualMemory(int vision, int target)
{
    if (g_hGetPrimaryThreat == null || g_hKE_GetEntity == null || g_hKE_UpdateVis == null) return;

    int stage = g_cvStage.IntValue;
    if (stage < 1) return;

    int known = SDKCall(g_hGetPrimaryThreat, vision, false);
    if (known == 0) return;
    if (SDKCall(g_hKE_GetEntity, known) != target) return;

    SDKCall(g_hKE_UpdateVis, known, true);
    SDKCall(g_hKE_UpdateVis, known, false);

    // Make the synthesised state coherent: an entity we claim is long-known must also have a last
    // known position the engine considers seen, or the suppression path dereferences data that was
    // never populated.
    if (stage >= 2 && g_hKE_MarkSeen != null) SDKCall(g_hKE_MarkSeen, known);

}

// Can this bot suppress at all? CINSBotCombat::Update refuses unless the held weapon's class is on
// the whitelist, so seeding anyone else is worse than useless: it denies their pursuit and leaves
// them idle. Fail open - if the class cannot be read, treat the bot as eligible.
bool CanBotSuppress(int bot)
{
    if (g_hGetWeaponClass == null) return true;

    int wep = GetEntPropEnt(bot, Prop_Send, "m_hActiveWeapon");
    if (wep <= 0 || !IsValidEntity(wep)) { g_iSkipNoWeapon++; return false; }

    int cls = SDKCall(g_hGetWeaponClass, wep);

    char list[96], parts[24][8];
    g_cvWeaponClasses.GetString(list, sizeof(list));
    int n = ExplodeString(list, ",", parts, sizeof(parts), sizeof(parts[]));
    for (int i = 0; i < n; i++)
    {
        TrimString(parts[i]);
        if (parts[i][0] == '\0' || StringToInt(parts[i]) != cls) continue;

        // On the user's list. If the engine would not natively accept it, arrange for this weapon
        // to report class 10 for a short while so Combat::Update lets the bot suppress.
        if (cls != 9 && cls != 10 && cls != 12)
        {
            int addr = view_as<int>(GetEntityAddress(wep));
            float until = GetGameTime() + g_cvReseed.FloatValue + 2.0;
            bool have = false;
            for (int k = 0; k < PROMO_SLOTS; k++)
                if (g_aPromoWeapon[k] == addr) { g_aPromoExp[k] = until; have = true; break; }
            if (!have)
            {
                g_aPromoWeapon[g_iPromoSlot] = addr;
                g_aPromoExp[g_iPromoSlot] = until;
                g_iPromoSlot = (g_iPromoSlot + 1) % PROMO_SLOTS;
            }
        }
        return true;
    }
    g_iSkipBadClass++; g_iLastBadClass = cls;
    return false;
}

// Give one bot knowledge of one player. Every pointer is checked before use: a null here is a
// server crash, not a failed function call.
void SeedKnowledge(int bot, int target, const float smokePos[3])
{
    int nextbot = SDKCall(g_hMyNextBotPointer, bot);
    if (nextbot == 0) return;

    int vision = SDKCall(g_hGetVisionInterface, nextbot);
    if (vision == 0) return;

    SDKCall(g_hAddKnownEntity, vision, target);
    GiveVisualMemory(vision, target);
    g_fSeededUntil[target] = GetGameTime() + g_cvNoPursue.FloatValue;

    if (g_cvDebug.BoolValue)
        LogMessage("[SMOKE SUPPRESS] %N given knowledge of %N at smoke (%.0f %.0f %.0f)",
                   bot, target, smokePos[0], smokePos[1], smokePos[2]);
}
