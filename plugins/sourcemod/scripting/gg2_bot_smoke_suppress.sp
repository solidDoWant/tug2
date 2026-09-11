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

// Test scaffolding for verifying the grenade half of the mechanic. OFF.
//
// Set to 1 and recompile to bring back two things that exist only to observe a test, never to make
// the mechanic work:
//
//   sm_bot_smoke_suppress_hide_client + the CINSBotVision::IsIgnored detour
//       Hides ONE client index from bot vision, so seeding is the only channel by which bots can
//       learn about the tester. notarget does not work on NextBot vision and nb_blind is too blunt
//       (it kills the vision update outright, leaving nothing to inject into). Do not ship this
//       enabled: on a live server it is a "make me invisible to bots" switch for anyone with rcon.
//
//   the CINSBotAttack::ctor detour
//       A whole detour whose body is one increment. atkCtor == fovForced means the fork works and
//       OnStart is killing the action; atkCtor == 0 means the branch is not being taken at all.
//       It is the only ground truth for whether the grenade fork reached the attack branch.
//
// To verify grenades: set this to 1, recompile, then set grenade_chance 1.0 and debug 1, throw one
// smoke, and check fovForced -> atkCtor -> icaCalls -> nadeHits still run 1:1:1:1.
#define GRENADE_VERIFY 0

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
Handle    g_hGetBodyInterface = null;
Handle    g_hAddKnownEntity    = null;
Handle    g_hGetPrimaryThreat  = null;
Handle    g_hKE_GetEntity      = null;
Handle    g_hKE_UpdateVis      = null;
Handle    g_hKE_UpdatePos      = null;
Handle    g_hGetWeaponClass    = null;
bool      g_bReady             = false;

ConVar    g_cvEnabled, g_cvChance, g_cvInterval, g_cvRange, g_cvRadius, g_cvClassnames, g_cvDebug;
ConVar    g_cvNoPursue;
ConVar    g_cvReseed;
ConVar    g_cvWeaponClasses;
ConVar    g_cvInSmoke;
ConVar    g_cvGrenadeChance;
ConVar    g_cvGrenadeClass;
ConVar    g_cvSmokeLife;
ArrayList g_aSmokeBorn;
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

// Second one-shot window, for the grenade dispatch in CINSBotAttack::InitialContainedAction.
// Separate from the suppression window because it promotes to a different class and is armed from
// a different call site.
bool      g_bNadeWindow = false;
int       g_iNadeArmed = 0, g_iNadeHits = 0;
// Third one-shot window: the fork into CINSBotAttack.
//
// CINSBotAttack is constructed in exactly two places, both inside CINSBotCombat::Update, and the
// first of them is guarded by IsVisibleInFOVNow on the primary known threat:
//
//     706d6e:  call *0x38(%eax)      ; CKnownEntity::IsVisibleInFOVNow, vtable slot 14
//     706d73:  jne  706f6e           ; -> new CINSBotAttack, ChangeTo
//     706d79:  ...                   ; else fall through to the suppression path
//
// That branch is three instructions ahead of the weapon-class gate this plugin already exploits,
// on the same code path, for the same bot, in the same tick. So the whole "bot must genuinely see
// you" problem reduces to answering true to one call - the one made on the known entity we seeded
// ourselves. Everything else keeps getting the truth, which is what keeps the bot from shooting
// accurately through the smoke.
//
// Armed at seed time (so grenade_chance is rolled per seed, not per call) and keyed on the
// CKnownEntity address, so no assumption about call ordering is needed to identify the right call.
#define NADE_SLOTS 32
int       g_aNadeKnown[NADE_SLOTS];
float     g_aNadeExp[NADE_SLOTS];
int       g_iNadeSlot = 0, g_iFovForced = 0, g_iFovSkip = 0, g_iNadeSkipNoNade = 0;

ConVar    g_cvArousalCap;
int       g_iArousalClamped = 0;

// The gate window brackets the fork, but it is not the only thing that runs inside it. On the
// direct path CINSBotCombat::Update calls the ShouldPursue dispatch at 0x706baa, BEFORE the fork at
// 0x706d6e - and the engine's own ShouldPursue implementations ask about the same known entity. Any
// such call would burn the one-shot before Update reaches the branch that matters, which is the
// suspected cause of 17 forks converting into 1 attack. Counted separately to prove or kill it.
// Which ShouldPursue fired? Only CINSBotCombat::ShouldPursue is dispatched from inside
// CINSBotCombat::Update (0x706baa). CINSBotMainAction::ShouldPursue comes from the behavior layer
// and says nothing about whether the bot is running the Combat action. Conflating them hid the
// possibility that during a dropout the bots are simply not in Combat at all - in which case every
// gate inside Update is irrelevant.
int       g_iPursueCombat = 0, g_iPursueMain = 0, g_iPursueCombatOk = 0;

// Arousal. CINSBotCombat::Update's FIRST branch is:
//
//     706baa:  call *0x164(%edx)   ; CINSBotBody::IsMinArousal(8)
//     706bb2:  je   706c55         ; NOT aroused -> ammo gate -> suppression
//              ...                 ; aroused    -> new CINSBotRetreatToCover
//
// and IsMinArousal is simply round(*(float *)(this + 0x138)) >= arg. So at arousal >= 8 the bot
// stops suppressing and retreats, no matter what every downstream gate says - which is why seeding,
// pursuit denial, ages, FOV and weapon class can all look perfectly healthy while suppCalls sits
// at 0. The server's own cvars make this a one-way door: combat_falloff is NEGATIVE (-0.25/s, i.e.
// arousal RISES while in combat) and default_falloff only applies out of combat. This mechanic
// holds bots in combat indefinitely, so arousal climbs to the cap and never comes back down.
int       g_iArousalHigh = 0, g_iArousalSampled = 0;
float     g_fArousalMin = 99.0, g_fArousalMax = -1.0;
#define AROUSAL_OFFSET  0x138
#define AROUSAL_GATE    8.0
int       g_iBotWepCls[MAXPLAYERS + 1];
int       g_aClsHist[16];

// A bot that pulls out a grenade and never throws it is left HOLDING that grenade. Its active
// weapon class is then 2/3/4, which the engine's suppression whitelist rejects - so that bot can
// never suppress again for the rest of its life. One grenade fork permanently disables one bot,
// which is exactly the reported "one suppression per bot life, resets only on respawn", and it
// gets worse the longer a pool of bots is reused. Self-inflicted by the grenade feature.
ConVar    g_cvUnstick;
float     g_fNadeHeldSince[MAXPLAYERS + 1];
int       g_iUnstuck = 0, g_iHoldingNade = 0;
bool      g_bInShouldPursue = false;
int       g_iFovInPursue = 0;
#if GRENADE_VERIFY
int       g_iAttackCtor = 0;
#endif

// Arming the fork off UpdateInternalInfo did not work: measured 20 forced -> 0 constructions.
// That flag has 8 arming sites, 5 of them OUTSIDE CINSBotCombat::Update (OnStart/OnResume/OnEnd),
// and it is also consumed by the weapon-class gate - so the one-shot was routinely spent on some
// unrelated query while the window happened to be open, never at 0x706d6e. There are no branches
// between the fork and the constructor, so zero constructions proved the true was landing
// elsewhere.
//
// ShouldPursue is a far better trigger: dispatched at 0x706baa, inside Update, strictly before the
// fork, and it hands us the CKnownEntity directly. Denying pursuit there is what steers execution
// down 706c55 -> 706d63 -> the fork, so arming at that moment brackets the fork as tightly as
// possible.
bool      g_bForkWindow = false;
int       g_iForkKnown = 0;

// Diagnosing "bots periodically stop suppressing entirely". suppForced is the discriminator - it is
// 0 through every dead window while seeding, pursuit denial and the weapon-class gate all look
// identical to a healthy one. These two say WHY: if ShouldSuppressThreat is being called often but
// about somebody else, the bots have simply acquired a real visible threat (a friendly bot) that
// outranks a remembered one, and the dropout is correct engine behaviour rather than a fault.
int       g_iSuppCalls = 0, g_iSuppOther = 0;

// The age gate at 0x706dbb, read straight out of the binary: skip suppression unless the threat has
// been known for >= 1.0s. It sits BEFORE the weapon-class gate, so a bot failing it never reaches
// ShouldSuppressThreat at all - which is exactly the signature of the per-smoke dropouts
// (suppCalls=0 while seeding and gateHits look healthy). Measured and CLEARED as a suspect: seeded
// threats aged 2-25s against the 1.0s threshold, never below it.
#define AGE_THRESHOLD 1.0
Handle    g_hKE_Age = null;

Handle    g_hAmmoRatio = null;
Handle    g_hChooseBestWeapon = null;
Handle    g_hKE_Destroy = null;
ConVar    g_cvRefresh;
int       g_iForgot = 0;
int       g_iRearmed = 0;
int       g_iClipFilled = 0;
ConVar    g_cvRefillAmmo;
#define AMMO_GATE 0.1
int       g_iAmmoSampled = 0, g_iAmmoBelow = 0, g_iRefilled = 0;
float     g_fAmmoMin = 1.0;
int       g_iAgeBelow = 0, g_iAgeSampled = 0;
float     g_fAgeMax = 0.0;

#if GRENADE_VERIFY
ConVar    g_cvHideClient;
int       g_iHidden = 0;
#endif

// Which pointer is a CINSNextBot* actually equal to? MyNextBotPointer returns the INextBot
// subobject, which is NOT the entity address - so match against both and count which one hits.
int       g_iIcaCalls = 0, g_iIcaMatchEnt = 0;
int       g_iBotEntAddr[MAXPLAYERS + 1];
bool      g_bBotCanSuppress[MAXPLAYERS + 1];
int       g_iAttackForced = 0;
int       g_iSuppressForced = 0;
int       g_iCombatUpdates = 0;
int       g_iAgeForced = 0;


// Entity references for live smoke clouds. References rather than indices so a recycled index
// cannot make us read a different entity.
ArrayList g_aSmokes;

// ---------------------------------------------------------------------------------------------
// Player warning
//
// Bots blind-firing into smoke is not a base-game behaviour, so a player who walks into a cloud and
// gets shot has no way to know that was a mechanic rather than bad luck. This tells them once.
//
// Delivered as a game_text entity rather than a user message. Insurgency registers ObjMsg and
// GameMessage - the objective-style popups - but the server never sends either; the objective HUD is
// driven client-side off the objective resource, so there is nothing to borrow. game_text is the
// screen-space path that is actually reachable from a plugin: CEntityFactory<CGameText> and
// CGameText::InputDisplay are both in the binary, it takes position, colour, fade and hold time as
// keyvalues, and firing Display with a player as the activator shows it to that player alone.
//
// Shown at most once per round per player, and at most sm_bot_smoke_suppress_warn_max times ever -
// regulars stop seeing it. That cap is persisted per steam id, and rows untouched for
// sm_bot_smoke_suppress_warn_forget_days are treated as unseen, so someone returning after a long
// break gets the explanation again.
ConVar    g_cvWarnEnabled, g_cvWarnRadius, g_cvWarnMax, g_cvWarnForgetDays;
ConVar    g_cvWarnText, g_cvWarnHold, g_cvWarnX, g_cvWarnY, g_cvWarnColor;

Database  g_hWarnDb = null;
bool      g_bWarnedThisRound[MAXPLAYERS + 1];
int       g_iWarnCount[MAXPLAYERS + 1];        // -1 = not loaded yet
char      g_sWarnSteamId[MAXPLAYERS + 1][32];
Handle    g_hTimer = null;

public void OnPluginStart()
{
    g_aSmokes = new ArrayList();
    g_aSmokeBorn = new ArrayList();

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
    g_cvRefresh = CreateConVar("sm_bot_smoke_suppress_refresh_threat", "1",
        "Forget the injected threat before re-adding it, so the bot treats each seed as a NEW acquisition. Without this, re-adding an already-known entity does not move the behavior back into the Combat action and bots engage the first smoke only.", _, true, 0.0, true, 1.0);

    g_cvUnstick = CreateConVar("sm_bot_smoke_suppress_unstick_grenade", "0",
        "Seconds a bot may hold an unthrown grenade before being switched back to a firearm (0 = never). A bot holding a grenade fails the engine's weapon-class check and cannot suppress meanwhile. Default 0: bots were observed putting the grenade away on their own, so this is a safety valve, not a fix.", _, true, 0.0, true, 30.0);

    g_cvRefillAmmo = CreateConVar("sm_bot_smoke_suppress_refill_ammo", "1",
        "Top up a seeded bot's RESERVE ammo when it falls near the engine's 10% suppression cutoff. Without this the mechanic self-limits to roughly one burst per bot life, because suppressing fire empties a magazine the bot would not otherwise have spent.", _, true, 0.0, true, 1.0);

    // If the measurement above shows IsVisibleInFOVNow answering true for a threat that is
    // demonstrably behind a smoke cloud, this makes it answer false - which is the honest answer,
    // not a new lie: the bot cannot see through the smoke. Off by default until measured.
    // The fix for the arousal pin. Clamping only the bots this mechanic is actually driving keeps
    // the change surgical: betterbots.cfg raises ins_bot_arousal_combat_max from 5 to 10 on purpose,
    // and lowering it globally would change every bot on the server, not just the ones we hold in
    // combat. 0 disables. Keep it below 7.5: the engine adds 0.25/s and the gate rounds, so a cap of
    // 7.0 still rounds up to 8 before the next sweep two seconds later.
    g_cvArousalCap = CreateConVar("sm_bot_smoke_suppress_arousal_cap", "6.5",
        "Clamp a seeded bot's arousal to this value so it stays under the engine's IsMinArousal(8) gate, which routes aroused bots to cover instead of suppressing. 0 = off. Without this the mechanic works for roughly 30 seconds and then stops permanently.", _, true, 0.0, true, 10.0);

#if GRENADE_VERIFY
    g_cvHideClient = CreateConVar("sm_bot_smoke_suppress_hide_client", "0",
        "DEBUG/TESTING: hide this client index from bot vision (0 = nobody). Unlike nb_blind this leaves the vision system running, so seeding still works.", _, true, 0.0, true, float(MAXPLAYERS));
#endif

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
    // Grenades into smoke. 0 disables. Chance is rolled per InitialContainedAction call for a
    // seeded bot, so it is a per-engagement roll rather than per sweep - keep it low.
    g_cvGrenadeChance = CreateConVar("sm_bot_smoke_suppress_grenade_chance", "0.0",
        "Chance a seeded bot entering the attack branch is steered onto the grenade-throw action.", _, true, 0.0, true, 1.0);
    g_cvGrenadeClass = CreateConVar("sm_bot_smoke_suppress_grenade_class", "2",
        "Weapon class to report at the attack dispatch. 2=frag 3=molotov 4=smoke 7=AT4.");
    // Reachability, not mechanism. CINSBotAttack::InitialContainedAction - the only route to the
    // grenade action - is entered when a bot acquires a VISIBLE threat, so for a player hidden in
    // smoke it essentially never runs (measured: 0 calls with notarget on, 4 in 24s with it off).
    //
    // Seeding normally stamps visibility true-then-false, giving the engine's "glimpsed, then lost"
    // state. For this fraction of seeds we skip the false, leaving the threat momentarily visible
    // so the bot enters the attack branch - where the class promotion steers it to ThrowGrenade.
    // The engine's own vision update corrects it within a tick or so.
    //
    // This is the one thing we spent the session avoiding: visible means accurately shootable. Keep
    // it low, and watch whether incoming fire starts tracking you rather than spraying.
    // Smoke entities OUTLIVE their visible cloud - the projectile stays valid long after the smoke
    // has gone. Tracking on entity validity alone meant stale clouds piled up (19 tracked at once),
    // so bots were seeded and pursuit-denied for smoke that no longer existed and stood around
    // servicing phantoms. Suppression measured 0 shots at 19 tracked clouds vs 184 at 3-10.
    g_cvWarnEnabled = CreateConVar("sm_bot_smoke_suppress_warn", "1",
        "Warn players on screen the first few times they are near smoke that bots may fire into it. Only ever fires while the mechanic itself is enabled.", _, true, 0.0, true, 1.0);
    g_cvWarnRadius = CreateConVar("sm_bot_smoke_suppress_warn_radius", "400.0",
        "How close to a live cloud a player must be to be warned. Distance rather than line of sight - it is one check per player per sweep either way, and being beside a cloud you cannot see is exactly when the mechanic surprises people.", _, true, 0.0);
    g_cvWarnMax = CreateConVar("sm_bot_smoke_suppress_warn_max", "10",
        "How many times a player is ever shown the warning. 0 = unlimited.", _, true, 0.0);
    g_cvWarnForgetDays = CreateConVar("sm_bot_smoke_suppress_warn_forget_days", "90",
        "A player whose last warning was longer ago than this is treated as new and starts the count again. 0 = never forget.", _, true, 0.0);
    g_cvWarnText = CreateConVar("sm_bot_smoke_suppress_warn_text",
        "Enemies may fire blindly into smoke on this server.",
        "The warning text. Keep it short - it is a popup, not a briefing.");
    g_cvWarnHold = CreateConVar("sm_bot_smoke_suppress_warn_hold", "5.0",
        "Seconds the warning stays on screen.", _, true, 0.5);
    g_cvWarnX = CreateConVar("sm_bot_smoke_suppress_warn_x", "-1",
        "Horizontal position, 0.0-1.0 across the screen. -1 centres it.");
    g_cvWarnY = CreateConVar("sm_bot_smoke_suppress_warn_y", "0.65",
        "Vertical position, 0.0-1.0 down the screen. -1 centres it.");
    g_cvWarnColor = CreateConVar("sm_bot_smoke_suppress_warn_color", "255 200 60 255",
        "Warning colour as \"R G B A\".");

    g_cvSmokeLife = CreateConVar("sm_bot_smoke_suppress_smoke_life", "18.0",
        "Seconds a smoke stays tracked. Should roughly match how long the cloud is actually visible.", _, true, 1.0, true, 120.0);
    g_cvDebug = CreateConVar("sm_bot_smoke_suppress_debug", "0",
        "Log every suppression decision. Noisy - troubleshooting only.");

    // The sweep timer is built once, so the interval has to restart it to take effect - otherwise
    // tuning it live silently does nothing.
    g_cvInterval.AddChangeHook(OnIntervalChanged);

    AutoExecConfig(true, "gg2_bot_smoke_suppress");

    HookEvent("weapon_fire", Event_WeaponFire);
    HookEvent("round_start", Event_WarnRoundStart);

    for (int i = 1; i <= MaxClients; i++) g_iWarnCount[i] = -1;
    Database.Connect(OnWarnDatabaseConnected, "insurgency-stats");

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

    // Same pattern, two slots earlier in the INextBot vtable. Nothing is ever CALLED on the result:
    // the arousal float is read - and clamped - straight out of the body object at +0x138.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "INextBot::GetBodyInterface"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
        g_hGetBodyInterface = EndPrepSDKCall();
    }
    if (g_hGetBodyInterface == null) LogError("[SMOKE SUPPRESS] Failed to prepare INextBot::GetBodyInterface - arousal cannot be measured");

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

    // void CKnownEntity::UpdatePosition(Vector) - vtable slot 3. Sets the aim point that
    // CINSBotCombat::Update reads back out of slot 5 and hands to CINSBotSuppressTarget's ctor.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CKnownEntity::UpdatePosition"))
    {
        PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByValue);
        g_hKE_UpdatePos = EndPrepSDKCall();
    }
    if (g_hKE_UpdatePos == null) LogError("[SMOKE SUPPRESS] UpdatePosition missing - bots will suppress a stale point");

    // void CKnownEntity::Destroy() - vtable slot 2.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Virtual, "CKnownEntity::Destroy"))
        g_hKE_Destroy = EndPrepSDKCall();
    if (g_hKE_Destroy == null) LogError("[SMOKE SUPPRESS] CKnownEntity::Destroy unavailable - threats cannot be refreshed");

    // void CINSNextBot::ChooseBestWeapon(CKnownEntity const*) - re-run the engine's own weapon
    // selection after refilling, so a bot that fell back to its knife picks a rifle up again.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CINSNextBot::ChooseBestWeapon"))
    {
        PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
        g_hChooseBestWeapon = EndPrepSDKCall();
    }
    if (g_hChooseBestWeapon == null) LogError("[SMOKE SUPPRESS] ChooseBestWeapon unavailable - bots stuck on knives cannot be re-armed");

    // float CINSNextBot::GetActiveWeaponAmmoRatio() - the 10% suppression cutoff reads this.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CINSNextBot::GetActiveWeaponAmmoRatio"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_Plain);
        g_hAmmoRatio = EndPrepSDKCall();
    }
    if (g_hAmmoRatio == null) LogError("[SMOKE SUPPRESS] GetActiveWeaponAmmoRatio unavailable - ammo gate cannot be measured");

    // float CKnownEntity::GetTimeSinceBecameKnown() const - vtable slot 12. Read only; the
    // DETOUR on this crashed the server four times (x87 float return), an SDKCall does not.
    StartPrepSDKCall(SDKCall_Raw);
    if (PrepSDKCall_SetFromConf(conf, SDKConf_Signature, "CKnownEntity::GetTimeSinceBecameKnown"))
    {
        PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_Plain);
        g_hKE_Age = EndPrepSDKCall();
    }
    // Say so loudly. Two diagnostics in this plugin have already silently done nothing because a
    // lookup returned null - a dead instrument reads exactly like a negative result.
    if (g_hKE_Age == null) LogError("[SMOKE SUPPRESS] GetTimeSinceBecameKnown unavailable - age gate cannot be measured");

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

#if GRENADE_VERIFY
    DynamicDetour ddCtor = DynamicDetour.FromConf(conf, "CINSBotAttack::ctor");
    if (ddCtor != null && ddCtor.Enable(Hook_Pre, Detour_AttackCtor)) detours++;
    else LogError("[SMOKE SUPPRESS] attack-ctor counter not installed");
#endif

    DynamicDetour ddIca = DynamicDetour.FromConf(conf, "CINSBotAttack::InitialContainedAction");
    if (ddIca != null && ddIca.Enable(Hook_Pre, Detour_InitialContainedAction)) detours++;
    else LogError("[SMOKE SUPPRESS] InitialContainedAction detour not installed");

    // Blinded override, so bots inside the cloud can suppress too (gated by cvar at call time).
    DynamicDetour ddBlind = DynamicDetour.FromConf(conf, "CINSBotVision::IsBlinded");
    if (ddBlind != null && ddBlind.Enable(Hook_Pre, Detour_IsBlinded)) detours++;
    else LogError("[SMOKE SUPPRESS] IsBlinded detour not installed");

#if GRENADE_VERIFY
    DynamicDetour ddIgn = DynamicDetour.FromConf(conf, "CINSBotVision::IsIgnored");
    if (ddIgn != null && ddIgn.Enable(Hook_Pre, Detour_IsIgnored)) detours++;
    else LogError("[SMOKE SUPPRESS] hide-client detour not installed");
#endif

    // Answers the 0x706d6e gate: true forks Update into CINSBotAttack so a grenade can be thrown.
    DynamicDetour ddFov = DynamicDetour.FromConf(conf, "CKnownEntity::IsVisibleInFOVNow");
    if (ddFov != null && ddFov.Enable(Hook_Pre, Detour_IsVisibleInFOVNow)) detours++;
    else LogError("[SMOKE SUPPRESS] FOV fork detour not installed - grenades disabled");

    // Arms the weapon-class gate window - load-bearing for promotion, not just a counter.
    DynamicDetour ddc = DynamicDetour.FromConf(conf, "CINSBotCombat::UpdateInternalInfo");
    if (ddc != null && ddc.Enable(Hook_Pre, Detour_CombatUpdate)) detours++;
    else LogError("[SMOKE SUPPRESS] UpdateInternalInfo detour not installed - weapon-class promotion will not work, so only natively eligible weapons (9/10/12) can suppress");

    if (detours == 0)
        LogError("[SMOKE SUPPRESS] No pursuit detours installed - bots will walk into smoke rather than shoot it");
    else
        LogMessage("[SMOKE SUPPRESS] %d pursuit detour(s) installed", detours);

    delete conf;

    g_bReady = (g_hMyNextBotPointer != null && g_hGetVisionInterface != null && g_hAddKnownEntity != null);
    if (!g_bReady)
    {
        LogError("[SMOKE SUPPRESS] Required signatures missing - plugin inert.");
        return;
    }

    // All RegServerCmd, so these are reachable from RCON/console only - never from a client.
    // dumpclasses maps GetWeaponClass() ints to real weapons empirically: the enum has no symbol
    // and the name table could not be recovered statically, so the whitelist {9,10,12} was read
    // out of a bitmask in the disassembly and is otherwise unlabelled.
    RegServerCmd("sm_bot_smoke_suppress_reset", Cmd_Reset,
        "DEBUG: clear ALL plugin runtime state without touching the engine or reinstalling detours");

    RegServerCmd("sm_bot_smoke_suppress_why", Cmd_Why,
        "DEBUG: per-bot dump of every gate between seeding and suppressing fire");

    RegServerCmd("sm_bot_smoke_suppress_nadecheck", Cmd_NadeCheck,
        "DEBUG: per-bot count of throwable grenades still carried");

    RegServerCmd("sm_bot_smoke_suppress_dumpclasses", Cmd_DumpClasses,
        "DEBUG: print each bot's active weapon and its GetWeaponClass() value");

    RestartTimer();
    LogMessage("[SMOKE SUPPRESS] Loaded. Enabled=%d interval=%.1f", g_cvEnabled.BoolValue, g_cvInterval.FloatValue);
}

// Clears every piece of runtime state a plugin reload would clear, without reinstalling detours.
// Built to bisect "a reload fixes suppression but a round restart does not" - which it did: reset
// alone never helped, so the fault was never in this state (it was bot arousal).
//
// Careful with it now. It clears g_bBotCanSuppress, and the arousal clamp only acts on bots with
// that flag set - so running this mid-round un-clamps every bot until the next sweep re-populates
// the flag, which needs a live smoke. It is a debugging tool, not a "fix it" button.
Action Cmd_Reset(int args)
{
    for (int i = 1; i <= MAXPLAYERS; i++)
    {
        g_fSeededUntil[i] = 0.0;
        g_fBotLastSeed[i] = 0.0;
        g_iBotNextBot[i] = 0;
        g_iBotVision[i] = 0;
        g_iBotEntAddr[i] = 0;
        g_bBotInSmoke[i] = false;
        g_bBotCanSuppress[i] = false;
        g_fNadeHeldSince[i] = 0.0;
    }
    for (int i = 0; i < PROMO_SLOTS; i++) { g_aPromoWeapon[i] = 0; g_aPromoExp[i] = 0.0; }
    for (int i = 0; i < NADE_SLOTS;  i++) { g_aNadeKnown[i]  = 0; g_aNadeExp[i]  = 0.0; }
    g_iPromoSlot = 0; g_iNadeSlot = 0;
    g_bGateWindow = false; g_bNadeWindow = false;
    g_bForkWindow = false; g_iForkKnown = 0;
    g_bInShouldPursue = false;
    g_aSmokes.Clear(); g_aSmokeBorn.Clear();
    PrintToServer("[SMOKE SUPPRESS] runtime state cleared (detours untouched)");
    return Plugin_Handled;
}

// Chasing one hypothesis per test round has been wrong five times. This dumps EVERY gate on the
// path from "we seeded this bot" to "the engine lets it suppress", for every living bot, in one
// shot - so a single run during a dead smoke says which gate is actually failing instead of
// confirming or killing one guess at a time.
//
// The gates, in the order CINSBotCombat::Update applies them:
//   0. arousal < 8                                (706baa - IsMinArousal; the one that killed it)
//   1. active weapon exists                       (706b18)
//   2. ammo ratio >= 0.10                         (706c5d)
//   3. threat known >= 1.0s                       (706db8)
//   4. weapon class in {9,10,12}                  (706dd2, promotion can fake this)
//   5. ShouldSuppressThreat                       (706df5)
Action Cmd_Why(int args)
{
    if (g_hGetWeaponClass == null || g_hAmmoRatio == null)
    { PrintToServer("[SMOKE SUPPRESS] diagnostics unavailable"); return Plugin_Handled; }

    int human = -1;
    for (int c = 1; c <= MaxClients; c++)
        if (IsClientInGame(c) && !IsFakeClient(c) && IsPlayerAlive(c)) { human = c; break; }

    PrintToServer("[SMOKE SUPPRESS] --- gate dump (human=%d, smokes=%d) ---", human, g_aSmokes.Length);

    for (int bot = 1; bot <= MaxClients; bot++)
    {
        if (!IsClientInGame(bot) || !IsFakeClient(bot) || !IsPlayerAlive(bot)) continue;

        int wep = GetEntPropEnt(bot, Prop_Send, "m_hActiveWeapon");
        char wname[64];
        int cls = -1;
        if (wep > 0 && IsValidEntity(wep)) { GetEntityClassname(wep, wname, sizeof(wname)); cls = SDKCall(g_hGetWeaponClass, wep); }
        else strcopy(wname, sizeof(wname), "NONE");

        float ratio = SDKCall(g_hAmmoRatio, GetEntityAddress(bot));

        // Does this bot's primary known threat point at the human, and how old is it?
        float age = -1.0;
        bool threatIsHuman = false;
        int nextbot = (g_hMyNextBotPointer == null) ? 0 : SDKCall(g_hMyNextBotPointer, bot);
        if (nextbot != 0 && g_hGetVisionInterface != null)
        {
            int vision = SDKCall(g_hGetVisionInterface, nextbot);
            if (vision != 0 && g_hGetPrimaryThreat != null && g_hKE_GetEntity != null)
            {
                int known = SDKCall(g_hGetPrimaryThreat, vision, false);
                if (known != 0)
                {
                    threatIsHuman = (SDKCall(g_hKE_GetEntity, known) == human);
                    if (g_hKE_Age != null) age = SDKCall(g_hKE_Age, known);
                }
            }
        }

        // What else is this bot carrying? A bot sitting on a knife with a rifle in its inventory
        // is a weapon-selection problem; a bot with no firearm at all is a loadout problem, and no
        // amount of ammo or re-selection will ever help it.
        char inv[256];
        int maxw2 = GetEntPropArraySize(bot, Prop_Send, "m_hMyWeapons");
        bool hasFirearm = false;
        for (int wi = 0; wi < maxw2; wi++)
        {
            int alt = GetEntPropEnt(bot, Prop_Send, "m_hMyWeapons", wi);
            if (alt <= 0 || !IsValidEntity(alt)) continue;
            int ac = SDKCall(g_hGetWeaponClass, alt);
            char an[64];
            GetEntityClassname(alt, an, sizeof(an));
            Format(inv, sizeof(inv), "%s%s(%d) ", inv, an, ac);
            if (ac >= 8 && ac <= 14) hasFirearm = true;
        }

        // Two different questions, and conflating them made this dump lie once weapon_classes was
        // widened: "native" is what the engine accepts unaided, "allowed" is what the cvar lets
        // through (non-native entries get promoted at the gate). Only "allowed" predicts behaviour.
        // Arousal, gate 0 - added after it turned out to be the one that actually kills the
        // mechanic. Without it this dump can show every other gate green on a bot that has not
        // fired a shot in minutes.
        float arousal = -1.0;
        if (nextbot != 0 && g_hGetBodyInterface != null)
        {
            int body = SDKCall(g_hGetBodyInterface, nextbot);
            if (body != 0)
                arousal = view_as<float>(LoadFromAddress(view_as<Address>(body + AROUSAL_OFFSET), NumberType_Int32));
        }

        bool nativeOk = (cls == 9 || cls == 10 || cls == 12);
        bool classOk  = nativeOk || IsClassInCvarList(cls);
        PrintToServer("[SMOKE SUPPRESS]   ^ inv: %s| hasFirearm=%s", inv, hasFirearm ? "Y" : "**NO**");
        PrintToServer("[SMOKE SUPPRESS] %N: arousal=%.1f %s | wep=%s cls=%d classOk=%s%s | ammo=%.2f %s | threat=%s age=%.1f %s | seedFresh=%s",
                      arousal, arousal < AROUSAL_GATE ? "OK" : "**PINNED**",
                      wname, cls, classOk ? "Y" : "n", nativeOk ? "" : "(promo)",
                      ratio, ratio >= AMMO_GATE ? "OK" : "**FAIL**",
                      threatIsHuman ? "human" : "other/none", age,
                      age >= AGE_THRESHOLD ? "OK" : "**FAIL**",
                      (human > 0 && g_fSeededUntil[human] > GetGameTime()) ? "Y" : "n");
    }
    return Plugin_Handled;
}

// sv_infinite_ammo refills the ammo reserve for firearms, but a frag or molotov is a weapon entity
// that is REMOVED from the inventory when the last one is thrown - so bots can genuinely run dry,
// and every grenade measurement after that point silently reads zero for the wrong reason.
// Grenade weapon classes, measured live: 2 frag, 3 molotov, 4 smoke, 7 launcher.
Action Cmd_NadeCheck(int args)
{
    if (g_hGetWeaponClass == null) { PrintToServer("[SMOKE SUPPRESS] GetWeaponClass unavailable"); return Plugin_Handled; }

    int maxw = GetEntPropArraySize(1, Prop_Send, "m_hMyWeapons");
    int botsAlive = 0, botsWithNade = 0, totalNades = 0;

    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || !IsFakeClient(c) || !IsPlayerAlive(c)) continue;
        botsAlive++;

        char line[256];
        int n = 0;
        for (int wi = 0; wi < maxw; wi++)
        {
            int wep = GetEntPropEnt(c, Prop_Send, "m_hMyWeapons", wi);
            if (wep <= 0 || !IsValidEntity(wep)) continue;

            int wc = SDKCall(g_hGetWeaponClass, wep);
            if (wc != 2 && wc != 3 && wc != 4 && wc != 7) continue;

            char cls[64];
            GetEntityClassname(wep, cls, sizeof(cls));
            int clip = GetEntProp(wep, Prop_Send, "m_iClip1");
            Format(line, sizeof(line), "%s%s%s(cls %d, clip %d)", line, n > 0 ? ", " : "", cls, wc, clip);
            n++;
            totalNades += (clip > 0 ? clip : 1);
        }
        if (n > 0) botsWithNade++;
        PrintToServer("[SMOKE SUPPRESS] %N: %s", c, n > 0 ? line : "NO THROWABLES");
    }

    PrintToServer("[SMOKE SUPPRESS] %d/%d living bots still carry a throwable (%d total)",
                  botsWithNade, botsAlive, totalNades);
    return Plugin_Handled;
}

Action Cmd_DumpClasses(int args)
{
    if (g_hGetWeaponClass == null) { PrintToServer("[SMOKE SUPPRESS] GetWeaponClass unavailable"); return Plugin_Handled; }

    char seen[32][64];
    int classOf[32];
    int n = 0;

    // Walk every weapon each bot carries, not just the active one - grenades are almost never the
    // active weapon when sampled, so an active-only dump never reveals their class.
    int maxw = GetEntPropArraySize(1, Prop_Send, "m_hMyWeapons");
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!IsClientInGame(c) || !IsPlayerAlive(c)) continue;
        for (int wi = -1; wi < maxw; wi++)
        {
        int wep = (wi < 0) ? GetEntPropEnt(c, Prop_Send, "m_hActiveWeapon")
                           : GetEntPropEnt(c, Prop_Send, "m_hMyWeapons", wi);
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
    }

    PrintToServer("[SMOKE SUPPRESS] weapon class map (%d distinct):", n);
    for (int i = 0; i < n; i++)
        PrintToServer("[SMOKE SUPPRESS]   class %2d  %s%s", classOf[i], seen[i],
                      (classOf[i] == 9 || classOf[i] == 10 || classOf[i] == 12) ? "   <-- CAN SUPPRESS" : "");
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
// Arm the grenade window when a SEEDED bot enters the attack branch. The bot is param 1, a
// CINSNextBot* - which is the entity address, unlike the INextBot subobject MyNextBotPointer hands
// back. Matched against a per-sweep cache with plain comparisons; no SDKCall in the hot path.
public MRESReturn Detour_InitialContainedAction(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return MRES_Ignored;
    float chance = g_cvGrenadeChance.FloatValue;
    if (chance <= 0.0) return MRES_Ignored;

    g_iIcaCalls++;

    int bot = DHookGetParam(hParams, 1);
    if (bot == 0) return MRES_Ignored;

    for (int b = 1; b <= MaxClients; b++)
    {
        bool hitEnt = (g_iBotEntAddr[b] == bot);
        bool hitNb  = (g_iBotNextBot[b] == bot);
        if (!hitEnt && !hitNb) continue;
        if (hitEnt) g_iIcaMatchEnt++;

        if (g_fBotLastSeed[b] <= GetGameTime() - g_cvNoPursue.FloatValue) return MRES_Ignored;
        if (GetURandomFloat() > chance) return MRES_Ignored;
        g_bNadeWindow = true;
        g_iNadeArmed++;
        return MRES_Ignored;
    }
    return MRES_Ignored;
}

public MRESReturn Detour_GetWeaponClass(Address pThis, DHookReturn hReturn)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return MRES_Ignored;

    // Grenade dispatch takes precedence: report a grenade class so InitialContainedAction's jump
    // table selects CINSBotThrowGrenade. One-shot, same as the suppression window.
    if (g_bNadeWindow)
    {
        g_bNadeWindow = false;
        g_iNadeHits++;
        DHookSetReturn(hReturn, g_cvGrenadeClass.IntValue);
        return MRES_Supercede;
    }

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

// The fork into CINSBotAttack. Return true for exactly one call, on exactly the known entity we
// seeded, and CINSBotCombat::Update takes the ChangeTo(new CINSBotAttack) branch instead of
// falling through to the suppression path. InitialContainedAction then runs on the next behavior
// update, where the grenade window turns it into CINSBotThrowGrenade.
//
// Consuming the slot immediately is what keeps this honest: the lie lasts one call, so nothing
// downstream - aiming, line of fire, the vision update - ever sees the threat as visible.
public MRESReturn Detour_IsVisibleInFOVNow(Address pThis, DHookReturn hReturn)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return MRES_Ignored;
    if (g_cvGrenadeChance.FloatValue <= 0.0) return MRES_Ignored;

    // Only the fork window counts - see g_bForkWindow for why UpdateInternalInfo was the wrong
    // trigger. Must be the same known entity ShouldPursue just handed us.
    if (!g_bForkWindow) { g_iFovSkip++; return MRES_Ignored; }

    // Inside a ShouldPursue call, so this is not the fork. Leave the window open for the real one.
    if (g_bInShouldPursue) { g_iFovInPursue++; return MRES_Ignored; }

    int k = view_as<int>(pThis);
    if (k != g_iForkKnown) return MRES_Ignored;

    g_bForkWindow = false;
    g_iForkKnown  = 0;

    // Consume the grenade slot too - one fork per arm.
    for (int i = 0; i < NADE_SLOTS; i++)
        if (g_aNadeKnown[i] == k) { g_aNadeKnown[i] = 0; g_aNadeExp[i] = 0.0; break; }

    g_iFovForced++;

    // Update takes the attack branch, so it will not reach the weapon-class gate this tick.
    // Disarm that window rather than leave it for some later unrelated read.
    g_bGateWindow = false;

    DHookSetReturn(hReturn, true);
    return MRES_Supercede;
}

#if GRENADE_VERIFY
// Hide one player from bot vision without disabling it. The engine calls this to decide whether an
// entity is worth considering at all, so returning true for the test subject makes bots unable to
// acquire them naturally - while our own AddKnownEntity injection, which bypasses this filter, still
// lands. That is the separation nb_blind could not give us.
public MRESReturn Detour_IsIgnored(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bReady) return MRES_Ignored;
    int hide = g_cvHideClient.IntValue;
    if (hide < 1 || hide > MaxClients) return MRES_Ignored;

    int ent = DHookGetParam(hParams, 1);
    if (ent == 0) return MRES_Ignored;
    if (ent != GetClientEntityAddressAsInt(hide)) return MRES_Ignored;

    g_iHidden++;
    DHookSetReturn(hReturn, true);
    return MRES_Supercede;
}

int GetClientEntityAddressAsInt(int client)
{
    if (!IsClientInGame(client)) return 0;
    return view_as<int>(GetEntityAddress(client));
}

// Pure counter. ctor == fovForced means the fork works and OnStart is killing the action;
// ctor == 0 means the branch is not being taken at all.
public MRESReturn Detour_AttackCtor(Address pThis)
{
    g_iAttackCtor++;
    return MRES_Ignored;
}
#endif  // GRENADE_VERIFY

public MRESReturn Detour_CombatUpdate(Address pThis)
{
    g_iCombatUpdates++;
    // Arms the gate window. Moving this to ShouldPursue (pre, then post) was tried and made things
    // strictly worse - promotions fell 10-20 -> 0-5 - because UpdateInternalInfo fires 140-240x per
    // window versus pCombat's 8-31, so it catches far more gate reads. The promotions it produces
    // are imprecise, but suppression never depended on them: native class-10 rifles pass anyway.
    g_bGateWindow = true;

    // This is an imprecise arming point, and knowingly so. UpdateInternalInfo has 8 call sites, 5
    // of them outside CINSBotCombat::Update, so the one-shot is routinely spent on an unrelated
    // GetWeaponClass call and the real gate at 0x706dcc sees the bot's true class. That is fine
    // while bots hold rifles (class 10 passes natively) and only matters for weapon classes that
    // depend on promotion - DMRs, pistols.
    //
    // Proven by the same bug in the grenade fork: moving its arming point from here to
    // ShouldPursue took constructions from 0 to 9. See Detour_ShouldPursue_Combat.
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

    g_iSuppCalls++;

    int ent = SDKCall(g_hKE_GetEntity, known);
    if (ent < 1 || ent > MaxClients) return MRES_Ignored;
    if (g_fSeededUntil[ent] <= GetGameTime()) { g_iSuppOther++; return MRES_Ignored; }

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
    bool isCombat = (StrContains(name, "CINSBotCombat") != -1);
    if (!dd.Enable(Hook_Pre, isCombat ? Detour_ShouldPursue_Combat : Detour_ShouldPursue_Main))
    { LogError("[SMOKE SUPPRESS] detour enable failed: %s", name); return false; }
    // Post hook clears the "inside ShouldPursue" marker, and for the Combat action it also arms
    // the weapon-class gate window at the one moment nothing else can consume it.
    if (!dd.Enable(Hook_Post, isCombat ? Detour_ShouldPursue_Post_Combat : Detour_ShouldPursue_Post))
        LogError("[SMOKE SUPPRESS] post detour failed: %s", name);
    return true;
}

public MRESReturn Detour_ShouldPursue_Post(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    g_bInShouldPursue = false;
    return MRES_Ignored;
}

// CINSBotCombat::ShouldPursue has returned, so execution is at 0x706bb0 heading for the gate at
// 0x706dcc. Nothing between those two points reads a weapon class, so the next GetWeaponClass call
// IS the gate - which is the whole point of the one-shot.
public MRESReturn Detour_ShouldPursue_Post_Combat(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    g_bInShouldPursue = false;
    return MRES_Ignored;
}

// QueryResultType: ANSWER_NO = 0, ANSWER_YES = 1, ANSWER_UNDEFINED = 2.
// Only ever supersedes for a client we seeded within the last nopursue_time seconds; every other
// call falls straight through, so ordinary bot behaviour is untouched.
public MRESReturn Detour_ShouldPursue_Combat(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    g_iPursueCombat++;

    // Diagnostic only, and behind the debug gate: this is a linear scan over every client on every
    // ShouldPursue call, and Detour_ShouldPursue immediately does the same scan for real.
    if (g_cvDebug.BoolValue)
    {
        int me = DHookGetParam(hParams, 1);
        if (me != 0)
            for (int b = 1; b <= MaxClients; b++)
                if (g_iBotNextBot[b] == me)
                {
                    if (g_bBotCanSuppress[b]) g_iPursueCombatOk++;
                    break;
                }
    }

    // The window is armed in the POST hook, not here - see Detour_ShouldPursue_Post. Arming it
    // pre meant that for any bot we did NOT deny, the engine's own ShouldPursue body ran next and
    // consumed the one-shot before Update reached the gate. Measured: promotions fell 10-20 -> 1-6.
    return Detour_ShouldPursue(hReturn, hParams);
}

public MRESReturn Detour_ShouldPursue_Main(Address pThis, DHookReturn hReturn, DHookParam hParams)
{
    g_iPursueMain++;
    return Detour_ShouldPursue(hReturn, hParams);
}

MRESReturn Detour_ShouldPursue(DHookReturn hReturn, DHookParam hParams)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return MRES_Ignored;
    if (g_hKE_GetEntity == null) return MRES_Ignored;

    g_iPursueCalls++;
    g_bInShouldPursue = true;

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

    // Denying pursuit here is what sends Update on to the fork. If this bot is armed for a
    // grenade, open the fork window now - it closes at the next IsVisibleInFOVNow on this exact
    // known entity, which is the fork itself.
    float nowP = GetGameTime();
    for (int i = 0; i < NADE_SLOTS; i++)
    {
        if (g_aNadeKnown[i] != known || g_aNadeExp[i] <= nowP) continue;
        g_bForkWindow = true;
        g_iForkKnown  = known;
        break;
    }

    g_iPursueDenied++;
    DHookSetReturn(hReturn, 0);
    return MRES_Supercede;
}

public void OnClientDisconnect(int client)
{
    g_fSeededUntil[client]    = 0.0;
    g_bWarnedThisRound[client] = false;
    g_iWarnCount[client]       = -1;
    g_sWarnSteamId[client][0]  = '\0';
}

public void OnClientPostAdminCheck(int client)
{
    g_bWarnedThisRound[client] = false;
    g_iWarnCount[client]       = -1;

    if (IsFakeClient(client)) return;
    if (!GetClientAuthId(client, AuthId_SteamID64, g_sWarnSteamId[client], sizeof(g_sWarnSteamId[]))) return;

    LoadWarnCount(client);
}

public void OnIntervalChanged(ConVar cvar, const char[] oldValue, const char[] newValue)
{
    RestartTimer();
}

public void OnMapStart()
{
    g_aSmokes.Clear();
    g_aSmokeBorn.Clear();
    for (int i = 1; i <= MaxClients; i++) g_bWarnedThisRound[i] = false;
    RestartTimer();
}

public void Event_WarnRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++) g_bWarnedThisRound[i] = false;
}

public void OnMapEnd()
{
    g_aSmokes.Clear();
    g_aSmokeBorn.Clear();
    if (g_hTimer != null) { KillTimer(g_hTimer); g_hTimer = null; }
}

// ---------------------------------------------------------------------------------------------
// Player warning - see the block comment by g_cvWarnEnabled
// ---------------------------------------------------------------------------------------------

public void OnWarnDatabaseConnected(Database db, const char[] error, any data)
{
    if (db == null)
    {
        // Not fatal, and deliberately not retried on a timer. Without the table the per-player cap
        // cannot be enforced, so the warning falls back to once per round and no lifetime limit -
        // noisy for regulars, but better than never explaining the mechanic to anyone.
        LogError("[SMOKE SUPPRESS] No database - the warning cap cannot be enforced, warnings fall back to once per round: %s", error);
        return;
    }

    g_hWarnDb = db;

    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i) && g_sWarnSteamId[i][0] != '\0') LoadWarnCount(i);
}

void LoadWarnCount(int client)
{
    if (g_hWarnDb == null || g_sWarnSteamId[client][0] == '\0') return;

    // A row older than the forget window counts as zero rather than being deleted - the row is
    // still useful history, and treating it as unseen is all the behaviour needs.
    char query[512];
    int  days = g_cvWarnForgetDays.IntValue;

    if (days > 0)
        g_hWarnDb.Format(query, sizeof(query),
            "SELECT CASE WHEN last_shown_at < NOW() - INTERVAL '%d days' THEN 0 ELSE shown_count END FROM smoke_warning_seen WHERE steam_id = %s",
            days, g_sWarnSteamId[client]);
    else
        g_hWarnDb.Format(query, sizeof(query),
            "SELECT shown_count FROM smoke_warning_seen WHERE steam_id = %s", g_sWarnSteamId[client]);

    g_hWarnDb.Query(OnWarnCountLoaded, query, GetClientUserId(client));
}

public void OnWarnCountLoaded(Database db, DBResultSet results, const char[] error, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1) return;

    if (results == null)
    {
        LogError("[SMOKE SUPPRESS] Failed to read the warning count: %s", error);
        g_iWarnCount[client] = 0;    // unknown, so treat as new rather than silently never warning
        return;
    }

    g_iWarnCount[client] = results.FetchRow() ? results.FetchInt(0) : 0;
}

// Called once per sweep. One distance check per eligible human per live cloud, and every player is
// eliminated by the cheap in-memory gates long before the loop is reached once they have been told.
void WarnPlayersNearSmoke()
{
    if (!g_cvWarnEnabled.BoolValue || g_aSmokes.Length == 0) return;

    float radius = g_cvWarnRadius.FloatValue;
    int   cap    = g_cvWarnMax.IntValue;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (g_bWarnedThisRound[client]) continue;
        if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client)) continue;
        if (cap > 0 && g_iWarnCount[client] >= cap) continue;
        if (g_iWarnCount[client] < 0) continue;    // still loading, do not burn the one-per-round

        float pos[3];
        GetClientAbsOrigin(client, pos);

        for (int i = 0; i < g_aSmokes.Length; i++)
        {
            int ent = EntRefToEntIndex(g_aSmokes.Get(i));
            if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent)) continue;

            float smokePos[3];
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", smokePos);
            if (GetVectorDistance(pos, smokePos) > radius) continue;

            ShowWarning(client);
            break;
        }
    }
}

void ShowWarning(int client)
{
    g_bWarnedThisRound[client] = true;
    g_iWarnCount[client]++;

    char text[192];
    g_cvWarnText.GetString(text, sizeof(text));
    if (text[0] != '\0') ShowGameText(client, text);

    RecordWarning(client);
}

// game_text without the "All Players" spawnflag shows only to the entity's activator, which is what
// makes this per-player. The entity is created per use and removed once the text has faded: one
// short-lived edict per warning, and a player only ever sees a handful.
void ShowGameText(int client, const char[] text)
{
    int entity = CreateEntityByName("game_text");
    if (entity <= 0) return;

    char buffer[32];

    DispatchKeyValue(entity, "message", text);
    DispatchKeyValue(entity, "spawnflags", "0");    // 0 = activator only, 1 would be everyone

    FloatToString(g_cvWarnX.FloatValue, buffer, sizeof(buffer));
    DispatchKeyValue(entity, "x", buffer);
    FloatToString(g_cvWarnY.FloatValue, buffer, sizeof(buffer));
    DispatchKeyValue(entity, "y", buffer);

    g_cvWarnColor.GetString(buffer, sizeof(buffer));
    DispatchKeyValue(entity, "color", buffer);
    DispatchKeyValue(entity, "color2", buffer);

    float hold = g_cvWarnHold.FloatValue;
    FloatToString(hold, buffer, sizeof(buffer));
    DispatchKeyValue(entity, "holdtime", buffer);
    DispatchKeyValue(entity, "fadein", "0.4");
    DispatchKeyValue(entity, "fadeout", "0.8");
    DispatchKeyValue(entity, "effect", "0");
    DispatchKeyValue(entity, "channel", "3");

    DispatchSpawn(entity);
    ActivateEntity(entity);
    AcceptEntityInput(entity, "Display", client, client);

    CreateTimer(hold + 2.0, Timer_KillWarnText, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_KillWarnText(Handle timer, int ref)
{
    int entity = EntRefToEntIndex(ref);
    if (entity != INVALID_ENT_REFERENCE && IsValidEntity(entity)) AcceptEntityInput(entity, "Kill");

    return Plugin_Stop;
}

void RecordWarning(int client)
{
    if (g_hWarnDb == null || g_sWarnSteamId[client][0] == '\0') return;

    // The count is recomputed from the stored row rather than written from memory, so two servers
    // warning the same player cannot lose an increment. GREATEST keeps a forgotten row from
    // resurrecting an old total: once the window has passed it restarts from this warning.
    char query[768];
    int  days = g_cvWarnForgetDays.IntValue;

    if (days > 0)
        g_hWarnDb.Format(query, sizeof(query),
            "INSERT INTO smoke_warning_seen (steam_id, shown_count, first_shown_at, last_shown_at) VALUES (%s, 1, NOW(), NOW()) ON CONFLICT (steam_id) DO UPDATE SET shown_count = CASE WHEN smoke_warning_seen.last_shown_at < NOW() - INTERVAL '%d days' THEN 1 ELSE smoke_warning_seen.shown_count + 1 END, last_shown_at = NOW()",
            g_sWarnSteamId[client], days);
    else
        g_hWarnDb.Format(query, sizeof(query),
            "INSERT INTO smoke_warning_seen (steam_id, shown_count, first_shown_at, last_shown_at) VALUES (%s, 1, NOW(), NOW()) ON CONFLICT (steam_id) DO UPDATE SET shown_count = smoke_warning_seen.shown_count + 1, last_shown_at = NOW()",
            g_sWarnSteamId[client]);

    g_hWarnDb.Query(OnWarnRecorded, query);
}

public void OnWarnRecorded(Database db, DBResultSet results, const char[] error, any data)
{
    if (results == null) LogError("[SMOKE SUPPRESS] Failed to record a warning: %s", error);
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
        if (g_aSmokes.FindValue(ref) == -1) { g_aSmokes.Push(ref); g_aSmokeBorn.Push(GetGameTime()); }
        if (g_cvDebug.BoolValue) LogMessage("[SMOKE SUPPRESS] Tracking smoke '%s' (ent %d)", classname, entity);
        return;
    }
}

// Arousal for every live bot, sampled before anything else and independent of whether a smoke is
// up. The pin persists BETWEEN smokes - that is the whole complaint - so sampling only near a cloud
// blinds the measurement exactly when the interesting thing happens.
void SampleArousal()
{
    if (g_hGetBodyInterface == null || g_hMyNextBotPointer == null) return;

    for (int b = 1; b <= MaxClients; b++)
    {
        if (!IsClientInGame(b) || !IsFakeClient(b) || !IsPlayerAlive(b)) continue;

        // Two SDKCalls and a raw read per bot per sweep. The clamp below only ever acts on a bot
        // with g_bBotCanSuppress set, so for every other bot this whole body is measurement - skip
        // it unless someone is watching. Clamping behaviour is byte-for-byte identical either way.
        if (!g_bBotCanSuppress[b] && !g_cvDebug.BoolValue) continue;

        int nb = SDKCall(g_hMyNextBotPointer, b);
        if (nb == 0) continue;
        int body = SDKCall(g_hGetBodyInterface, nb);
        if (body == 0) continue;

        float a = view_as<float>(LoadFromAddress(view_as<Address>(body + AROUSAL_OFFSET), NumberType_Int32));

        // Clamp before recording, so the logged numbers describe what the engine will actually see.
        // Only bots we are currently driving: a bot we never seeded is none of our business.
        //
        // Two things about g_bBotCanSuppress are load-bearing here and easy to break:
        //   - It is refreshed in Timer_Sweep BELOW the `no smokes -> return` guard, so between
        //     clouds it holds whatever the last sweep with smoke decided. That is deliberate. The
        //     arousal pin outlives the cloud that caused it, and a bot left pinned at 10 is dead to
        //     the mechanic for the rest of the round; keeping the last known set clamped is what
        //     lets the NEXT smoke work. Move the refresh above that guard and the pin comes back.
        //   - A bot near a cloud holding an ineligible weapon class is never clamped, so it is free
        //     to drift to the cap. Correct as long as it stays ineligible - but it is one weapon
        //     switch away from being eligible AND pinned, which reads as "some bots never join in".
        float cap = g_cvArousalCap.FloatValue;
        if (cap > 0.0 && a > cap && g_bBotCanSuppress[b])
        {
            StoreToAddress(view_as<Address>(body + AROUSAL_OFFSET), view_as<int>(cap), NumberType_Int32);
            a = cap;
            g_iArousalClamped++;
        }

        g_iArousalSampled++;
        if (a >= AROUSAL_GATE) g_iArousalHigh++;
        if (a < g_fArousalMin) g_fArousalMin = a;
        if (a > g_fArousalMax) g_fArousalMax = a;
    }
}

Action Timer_Sweep(Handle timer)
{
    if (!g_bReady || !g_cvEnabled.BoolValue) return Plugin_Continue;

    SampleArousal();
    WarnPlayersNearSmoke();

    if (g_cvDebug.BoolValue)
    {
        char hist[128];
        for (int c = 0; c < sizeof(g_aClsHist); c++)
            if (g_aClsHist[c] > 0) Format(hist, sizeof(hist), "%s%d:%d ", hist, c, g_aClsHist[c]);

        LogMessage("[SMOKE SUPPRESS] pursue detour: calls=%d pCombat=%d pCombatOk=%d pMain=%d denied=%d nonClient=%d stale=%d attackForced=%d suppressForced=%d suppCalls=%d suppOther=%d combatUpd=%d ageForced=%d ageSampled=%d ageBelow=%d ageMax=%.1f ammoSampled=%d ammoBelow=%d ammoMin=%.2f refilled=%d rearmed=%d clipFill=%d forgot=%d holdNade=%d unstuck=%d | smokes=%d | BOT SHOTS near smoke=%d (inSmoke=%d outside=%d) | seeded=%d skipNoWep=%d skipClass=%d lastBadCls=%d unblinded=%d promoted=%d gateHits=%d nadeArmed=%d nadeHits=%d icaCalls=%d mEnt=%d fovForced=%d fovSkip=%d fovInPursue=%d noNade=%d | clsHist=%s | arousal n=%d high=%d min=%.1f max=%.1f clamped=%d",
                   g_iPursueCalls, g_iPursueCombat, g_iPursueCombatOk, g_iPursueMain, g_iPursueDenied, g_iPursueNonClient, g_iPursueStale, g_iAttackForced, g_iSuppressForced, g_iSuppCalls, g_iSuppOther, g_iCombatUpdates, g_iAgeForced, g_iAgeSampled, g_iAgeBelow, g_fAgeMax, g_iAmmoSampled, g_iAmmoBelow, g_fAmmoMin, g_iRefilled, g_iRearmed, g_iClipFilled, g_iForgot, g_iHoldingNade, g_iUnstuck, g_aSmokes.Length, g_iBotShotsNearSmoke, g_iShotsInSmoke, g_iShotsOutSmoke, g_iSeeded, g_iSkipNoWeapon, g_iSkipBadClass, g_iLastBadClass, g_iUnblinded, g_iPromoted, g_iGateHits, g_iNadeArmed, g_iNadeHits, g_iIcaCalls, g_iIcaMatchEnt, g_iFovForced, g_iFovSkip, g_iFovInPursue, g_iNadeSkipNoNade, hist, g_iArousalSampled, g_iArousalHigh, g_fArousalMin, g_fArousalMax, g_iArousalClamped);
        g_iPursueCalls = 0; g_iPursueCombat = 0; g_iPursueCombatOk = 0; g_iPursueMain = 0; g_iPursueDenied = 0; g_iPursueNonClient = 0; g_iPursueStale = 0; g_iBotShotsNearSmoke = 0; g_iShotsInSmoke = 0; g_iShotsOutSmoke = 0; g_iSeeded = 0; g_iSkipNoWeapon = 0; g_iSkipBadClass = 0; g_iUnblinded = 0; g_iPromoted = 0; g_iGateHits = 0; g_iNadeArmed = 0; g_iNadeHits = 0; g_iIcaCalls = 0; g_iIcaMatchEnt = 0; g_iFovForced = 0; g_iFovSkip = 0; g_iFovInPursue = 0; g_iNadeSkipNoNade = 0; g_iAttackForced = 0; g_iSuppressForced = 0; g_iSuppCalls = 0; g_iSuppOther = 0; g_iCombatUpdates = 0; g_iAgeForced = 0; g_iAgeSampled = 0; g_iAgeBelow = 0; g_fAgeMax = 0.0; g_iAmmoSampled = 0; g_iAmmoBelow = 0; g_fAmmoMin = 1.0; g_iRefilled = 0; g_iRearmed = 0; g_iClipFilled = 0; g_iForgot = 0; g_iHoldingNade = 0; g_iUnstuck = 0; g_iArousalSampled = 0; g_iArousalHigh = 0; g_fArousalMin = 99.0; g_fArousalMax = -1.0; g_iArousalClamped = 0;
        for (int c = 0; c < sizeof(g_aClsHist); c++) g_aClsHist[c] = 0;
#if GRENADE_VERIFY
        LogMessage("[SMOKE SUPPRESS] grenade verify: atkCtor=%d hidden=%d", g_iAttackCtor, g_iHidden);
        g_iAttackCtor = 0; g_iHidden = 0;
#endif
    }

    // Runs regardless of smoke: a bot stuck holding a grenade stays stuck long after the cloud is
    // gone, and every tick it stays that way is a bot permanently removed from the mechanic.
    UnstickGrenadeHolders();

    if (g_aSmokes.Length == 0) return Plugin_Continue;

    // Refresh the per-bot caches the pursuit detour reads.
    for (int b = 1; b <= MaxClients; b++)
    {
        g_iBotNextBot[b] = 0;
        g_bBotCanSuppress[b] = false;
        if (!IsClientInGame(b) || !IsFakeClient(b) || !IsPlayerAlive(b)) continue;
        g_iBotNextBot[b] = SDKCall(g_hMyNextBotPointer, b);
        g_iBotEntAddr[b] = view_as<int>(GetEntityAddress(b));
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

        g_iBotWepCls[b] = -1;
        if (nearSmoke && g_cvDebug.BoolValue && g_hGetWeaponClass != null)
        {
            int aw = GetEntPropEnt(b, Prop_Send, "m_hActiveWeapon");
            if (aw > 0 && IsValidEntity(aw))
            {
                int wc = SDKCall(g_hGetWeaponClass, aw);
                g_iBotWepCls[b] = wc;
                if (wc >= 0 && wc < sizeof(g_aClsHist)) g_aClsHist[wc]++;
            }
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
        bool expired = (GetGameTime() - g_aSmokeBorn.Get(i)) > g_cvSmokeLife.FloatValue;
        if (ent == INVALID_ENT_REFERENCE || !IsValidEntity(ent) || expired)
        {
            g_aSmokes.Erase(i);
            g_aSmokeBorn.Erase(i);
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

            // Pursuit denial is a property of "this player is currently hidden in a live cloud",
            // so it has to refresh every sweep - NOT on the reseed cadence. Those are different
            // clocks: reseeding is held off for reseed_cooldown (8s) because injecting knowledge
            // again resets the age gate, but denial only lasted nopursue_time (6s) from the last
            // seed. That left a 2s hole each cycle in which the bot was free to walk in, which is
            // what made bots drift out of suppression and pile up around the smoke.
            g_fSeededUntil[client] = GetGameTime() + g_cvNoPursue.FloatValue;

            for (int bot = 1; bot <= MaxClients; bot++)
            {
                if (!IsClientInGame(bot) || !IsFakeClient(bot) || !IsPlayerAlive(bot)) continue;
                if (GetClientTeam(bot) == GetClientTeam(client)) continue;

                float bPos[3];
                GetClientAbsOrigin(bot, bPos);
                if (GetVectorDistance(bPos, smokePos) > range) continue;
                if (g_cvDebug.BoolValue) SampleThreatAge(bot, client);
                SampleAndRefillAmmo(bot);

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
int GiveVisualMemory(int vision, int target)
{
    if (g_hGetPrimaryThreat == null || g_hKE_GetEntity == null || g_hKE_UpdateVis == null) return 0;

    int known = SDKCall(g_hGetPrimaryThreat, vision, false);
    if (known == 0) return 0;
    if (SDKCall(g_hKE_GetEntity, known) != target) return 0;

    // Seen, then immediately unseen. Both halves are required: see the comment above.
    SDKCall(g_hKE_UpdateVis, known, true);
    SDKCall(g_hKE_UpdateVis, known, false);

    return known;
}

// Does this bot carry a grenade the ThrowGrenade action could actually use? Classes 2 (frag) and
// 3 (molotov/anm14) are throwables; 4 is smoke, which bots may as well throw back. Launchers (7)
// are deliberately excluded - they dispatch through a different branch of the jump table.
bool BotHasThrowable(int bot)
{
    if (g_hGetWeaponClass == null) return true;   // fail open, same as CanBotSuppress

    int maxw = GetEntPropArraySize(bot, Prop_Send, "m_hMyWeapons");
    for (int wi = 0; wi < maxw; wi++)
    {
        int wep = GetEntPropEnt(bot, Prop_Send, "m_hMyWeapons", wi);
        if (wep <= 0 || !IsValidEntity(wep)) continue;

        int wc = SDKCall(g_hGetWeaponClass, wep);
        if (wc == 2 || wc == 3 || wc == 4) return true;
    }
    g_iNadeSkipNoNade++;
    return false;
}

// Can this bot suppress at all? CINSBotCombat::Update refuses unless the held weapon's class is on
// the whitelist, so seeding anyone else is worse than useless: it denies their pursuit and leaves
// them idle. Fail open - if the class cannot be read, treat the bot as eligible.
// Read-only membership test against sm_bot_smoke_suppress_weapon_classes. Deliberately has none
// of CanBotSuppress's side effects (no promotion slot, no counters) so diagnostics cannot perturb
// the thing they are measuring.
bool IsClassInCvarList(int cls)
{
    char list[96], parts[24][8];
    g_cvWeaponClasses.GetString(list, sizeof(list));
    int n = ExplodeString(list, ",", parts, sizeof(parts), sizeof(parts[]));
    for (int i = 0; i < n; i++)
    {
        TrimString(parts[i]);
        if (parts[i][0] != '\0' && StringToInt(parts[i]) == cls) return true;
    }
    return false;
}

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

// See g_cvUnstick. Switch a bot that has been holding an unthrown grenade for too long back onto a
// weapon the engine will actually let it suppress with.
void UnstickGrenadeHolders()
{
    if (g_hGetWeaponClass == null) return;
    float limit = g_cvUnstick.FloatValue;

    for (int bot = 1; bot <= MaxClients; bot++)
    {
        if (!IsClientInGame(bot) || !IsFakeClient(bot) || !IsPlayerAlive(bot))
        {
            g_fNadeHeldSince[bot] = 0.0;
            continue;
        }

        int wep = GetEntPropEnt(bot, Prop_Send, "m_hActiveWeapon");
        if (wep <= 0 || !IsValidEntity(wep)) { g_fNadeHeldSince[bot] = 0.0; continue; }

        int cls = SDKCall(g_hGetWeaponClass, wep);
        if (cls != 2 && cls != 3 && cls != 4) { g_fNadeHeldSince[bot] = 0.0; continue; }

        g_iHoldingNade++;
        if (limit <= 0.0) continue;

        if (g_fNadeHeldSince[bot] == 0.0) { g_fNadeHeldSince[bot] = GetGameTime(); continue; }
        if (GetGameTime() - g_fNadeHeldSince[bot] < limit) continue;

        // Find any firearm this bot carries and deploy it the normal way.
        int maxw = GetEntPropArraySize(bot, Prop_Send, "m_hMyWeapons");
        for (int wi = 0; wi < maxw; wi++)
        {
            int alt = GetEntPropEnt(bot, Prop_Send, "m_hMyWeapons", wi);
            if (alt <= 0 || !IsValidEntity(alt) || alt == wep) continue;

            int ac = SDKCall(g_hGetWeaponClass, alt);
            if (ac != 9 && ac != 10 && ac != 11 && ac != 12 && ac != 14) continue;

            char cname[64];
            GetEntityClassname(alt, cname, sizeof(cname));
            FakeClientCommand(bot, "use %s", cname);
            g_iUnstuck++;
            break;
        }
        g_fNadeHeldSince[bot] = 0.0;
    }
}

// Suppressing fire spends a magazine the bot would never otherwise have spent, and the engine
// refuses to suppress below a 10% ammo ratio - so without help the mechanic fires once per bot life
// and then goes silent until that bot dies. Topping up the RESERVE (not the clip) keeps this honest:
// the bot still has to run its normal reload action to benefit.
void SampleAndRefillAmmo(int bot)
{
    if (g_hAmmoRatio == null || g_hGetWeaponClass == null) return;

    // Diagnostic only, and read it carefully: this is the ratio for the ACTIVE weapon. A bot that
    // has burned its rifle dry and switched to a knife reports 1.00 here, which is what made this
    // number look healthy for hours while bots were in fact out of ammo. Behind the debug gate -
    // the refill below is the part that has to run in production.
    if (g_cvDebug.BoolValue)
    {
        float ratio = SDKCall(g_hAmmoRatio, GetEntityAddress(bot));
        g_iAmmoSampled++;
        if (ratio < AMMO_GATE) g_iAmmoBelow++;
        if (ratio < g_fAmmoMin) g_fAmmoMin = ratio;
    }

    if (!g_cvRefillAmmo.BoolValue) return;

    // Refill EVERY carried firearm's reserve, not just the active weapon. Suppressing fire empties
    // magazines the bot would never otherwise have spent; once dry it falls back to a pistol and
    // then to its knife, and melee can never pass the engine's suppression gate - so the bot is
    // silently removed from the mechanic for the rest of its life. Measured live: 7 of 25 bots on
    // knives and 6 on pistols after three smokes.
    int maxw = GetEntPropArraySize(bot, Prop_Send, "m_hMyWeapons");
    for (int wi = 0; wi < maxw; wi++)
    {
        int wep = GetEntPropEnt(bot, Prop_Send, "m_hMyWeapons", wi);
        if (wep <= 0 || !IsValidEntity(wep)) continue;

        int cls = SDKCall(g_hGetWeaponClass, wep);
        if (cls != 8 && cls != 9 && cls != 10 && cls != 11 && cls != 12 && cls != 14) continue;

        int ammoType = GetEntProp(wep, Prop_Send, "m_iPrimaryAmmoType");
        if (ammoType < 0) continue;

        if (GetEntProp(bot, Prop_Send, "m_iAmmo", _, ammoType) < 90)
        {
            SetEntProp(bot, Prop_Send, "m_iAmmo", 150, _, ammoType);
            g_iRefilled++;
        }

        // Refill the MAGAZINE too, not just the reserve. ChooseBestWeapon compares weapons as they
        // stand: an empty rifle with a full reserve loses to a loaded pistol, so the bot keeps the
        // pistol, and a pistol only passes the engine's class gate via the (unreliable) promotion.
        // Measured: rearmed=13-18 every seed while bots stayed on pistols throughout a dead smoke.
        if (GetEntProp(wep, Prop_Send, "m_iClip1") < 5)
        {
            SetEntProp(wep, Prop_Send, "m_iClip1", 30);
            g_iClipFilled++;
        }
    }
}

// How long has this bot known the player? Below AGE_THRESHOLD the engine refuses to suppress and
// never even reaches the weapon-class gate. Instrumentation only - it walks five SDKCalls per
// seeded bot per sweep and writes nothing - so the caller runs it only under `debug`. The gate
// itself was cleared as a suspect (ages measured 2-25s against a 1.0s threshold); this stays
// because it is the cheapest way to re-check that if the mechanic ever goes quiet again.
void SampleThreatAge(int bot, int target)
{
    if (g_hKE_Age == null || g_hMyNextBotPointer == null || g_hGetVisionInterface == null) return;
    if (g_hGetPrimaryThreat == null || g_hKE_GetEntity == null) return;

    int nextbot = SDKCall(g_hMyNextBotPointer, bot);
    if (nextbot == 0) return;
    int vision = SDKCall(g_hGetVisionInterface, nextbot);
    if (vision == 0) return;
    int known = SDKCall(g_hGetPrimaryThreat, vision, false);
    if (known == 0) return;
    if (SDKCall(g_hKE_GetEntity, known) != target) return;

    float age = SDKCall(g_hKE_Age, known);
    g_iAgeSampled++;
    if (age < AGE_THRESHOLD) g_iAgeBelow++;
    if (age > g_fAgeMax) g_fAgeMax = age;
}

// Give one bot knowledge of one player. Every pointer is checked before use: a null here is a
// server crash, not a failed function call.
void SeedKnowledge(int bot, int target, const float smokePos[3])
{
    int nextbot = SDKCall(g_hMyNextBotPointer, bot);
    if (nextbot == 0) return;

    int vision = SDKCall(g_hGetVisionInterface, nextbot);
    if (vision == 0) return;

    // Forget first. An AddKnownEntity for an entity already in the list is not an acquisition,
    // so the behavior never transitions back into Combat - the bot keeps the (ageing) memory and
    // ignores it. Dropping the entry makes the very next add read as a fresh sighting.
    if (g_cvRefresh.BoolValue && g_hKE_Destroy != null && g_hGetPrimaryThreat != null && g_hKE_GetEntity != null)
    {
        int old = SDKCall(g_hGetPrimaryThreat, vision, false);
        if (old != 0 && SDKCall(g_hKE_GetEntity, old) == target)
        {
            SDKCall(g_hKE_Destroy, old);
            g_iForgot++;
        }
    }

    SDKCall(g_hAddKnownEntity, vision, target);
    int known = GiveVisualMemory(vision, target);

    // Refilling ammo is not enough on its own: weapon selection is not re-run when the reserve
    // changes, so a bot that fell back to melee keeps holding the knife with full magazines. Ask
    // the engine to reconsider, but only when the bot is actually holding something that cannot
    // suppress - never disturb a bot that is already correctly armed.
    if (known != 0 && g_hChooseBestWeapon != null && g_hGetWeaponClass != null)
    {
        int held = GetEntPropEnt(bot, Prop_Send, "m_hActiveWeapon");
        int hcls = (held > 0 && IsValidEntity(held)) ? SDKCall(g_hGetWeaponClass, held) : -1;
        if (hcls != 9 && hcls != 10 && hcls != 12)
        {
            SDKCall(g_hChooseBestWeapon, GetEntityAddress(bot), known);
            g_iRearmed++;
        }
    }
    g_fSeededUntil[target] = GetGameTime() + g_cvNoPursue.FloatValue;

    // Roll for a grenade here rather than in the detour, so the chance is per seeded bot per
    // window instead of per engine call - the detour fires far too often to be a fair coin.
    //
    // Only arm a bot that actually carries something to throw. Measured live: 11 of 25 living bots
    // carry no throwable at all, purely by loadout. Steering an empty-handed bot onto the
    // ThrowGrenade branch wastes the fork and strands it - it can neither throw nor suppress - so
    // this both raises the conversion rate and removes an idling failure mode.
    if (known != 0 && BotHasThrowable(bot) && GetURandomFloat() < g_cvGrenadeChance.FloatValue)
    {
        float until = GetGameTime() + g_cvNoPursue.FloatValue;
        bool have = false;
        for (int k = 0; k < NADE_SLOTS; k++)
            if (g_aNadeKnown[k] == known) { g_aNadeExp[k] = until; have = true; break; }
        if (!have)
        {
            g_aNadeKnown[g_iNadeSlot] = known;
            g_aNadeExp[g_iNadeSlot]   = until;
            g_iNadeSlot = (g_iNadeSlot + 1) % NADE_SLOTS;
        }
    }

    if (g_cvDebug.BoolValue)
        LogMessage("[SMOKE SUPPRESS] %N given knowledge of %N at smoke (%.0f %.0f %.0f)",
                   bot, target, smokePos[0], smokePos[1], smokePos[2]);
}
