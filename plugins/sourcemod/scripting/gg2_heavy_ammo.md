# Heavy ammunition (Mk 211 / M8 API)

Rounds that damage, ignite and suppress everything **around** where they land rather than only what
they hit — so a round into the crate a machine gunner is behind still gets the machine gunner.

Config-driven, one block per round in `configs/heavyammo.cfg`, the same shape `firesupport.cfg`
uses. Adding a round to another weapon is a theater entry plus a config block, with no code change.

The two shipped rounds are for the M107:

| | Mk 211 Mod 0 HEIAP | M8 API |
| --- | --- | --- |
| Blast radius | 260u, 110 damage at centre, linear falloff | 180u, 45 damage at centre |
| Burns | 3s, within 130u | 7s, within 180u |
| Suppresses | 500u | 500u |
| Carried | 5 magazines | 7 |
| Supply cost | 4 | 3 |
| Damage type | `DMG_BLAST` | `DMG_BURN` |

The Mk 211 bursts; the API does not. An M8 API carries no explosive filler, so its splash is burning
material rather than fragmentation, and most of what it does comes from what catches light
afterwards.

**Kills with the API round are not counted as teamkills.** `gg2_teamkill` drops any death carrying
`DMG_BURN` unless the weapon is the flamethrower. That is not specific to this round — molotovs, the
ANM14, the 40mm incendiaries and WP artillery are all already exempt, because fire spreads between
players and the attacker on a fire death is frequently not who lit it. Typing the round as blast to
work around that would make it the only incendiary on the server behaving differently; if fire TKs
should be tracked, that belongs in `gg2_teamkill`.

Direct-hit ballistics come from the theater and are close to the existing AP round: the Mk 211
trades a little per-shot damage for its burst, the API is AP ballistics with an incendiary charge.

## Adding a round to another weapon

1. Define the ammo type and an upgrade for it in the theater, listing the weapon in the upgrade's
   `allowed_weapons`. **That is what decides where the round can be mounted** — the plugin does not
   need to know.
2. Add a block to `configs/heavyammo.cfg` naming that upgrade.

```
"heat_762"
{
    "upgrade"          "ammo_heat_762"
    "radius"           "150"
    "damage"           "70"
    "burn_time"        "2.0"
    "suppress_radius"  "350"
    "cooldown"         "0.6"          // raise this for anything with a real rate of fire
    "particle"         "ins_m203_explosion"
}
```

Every key has a default, so a block only needs to state what it changes; the minimum useful entry
is a name and an `upgrade`. `sm_heavyammo_reload` re-reads the file without a restart.

The optional `weapons` key is a *further* filter on classname, for when the same upgrade should only
take effect on some of the weapons it can be mounted on. Omitted means "wherever it is mounted". It
is written the same way the theater writes `allowed_weapons`, so the two read alike when you have
both files open:

```
"weapons"
{
    "weapon"  "weapon_m107"
    "weapon"  "weapon_svd"
}
```

A flat `"weapons" "weapon_m107,weapon_svd"` is accepted as well.

## Why the plugin exists

None of the area effect can be done in the theater. Ammo definitions do carry a `damageType` key,
and the server accepts `DMG_BLAST` and `DMG_BURN` among others — but that only relabels the damage,
changing how armour and the medic system treat it, not where it lands. Bullets here are hitscan
traces; there is no projectile in flight to detonate.

So the theater supplies the round (ballistics, scarcity, per-bullet `SuppressionIncrement`) and the
plugin supplies everything spatial.

## Why it is cheap

The obvious implementation — spawn a grenade entity per bullet — is the expensive one. Tracers show
the shape the engine actually uses for per-bullet effects: a one-shot networked effect, not an
entity. This does the same. Per shot it creates one short-lived `info_particle_system` for the
visual and then runs a single loop over connected players applying damage directly. No explosive
entity, no edict per bullet, no physics, no think.

The M107 is 450rpm semi-automatic with an 11-round magazine, and `sm_heavyammo_cooldown` (0.25s)
bounds the worst case regardless.

## How the impact point is found

There is no bullet-impact game event in Insurgency — `modevents.res` has `weapon_fire` with only
`weaponid`, `userid` and `shots` — and no projectile to follow. So the plugin traces the shot itself
from the shooter's eye on `weapon_fire`.

That follows the shooter's aim rather than the bullet's exact path, so it ignores spread. The M107's
spread is `0.04` and the effect radius is hundreds of units, so at any range where this matters the
difference is a rounding error. The important property is that the trace hits the **world**: a round
into a wall or a crate produces an impact point exactly as a round into a body does, which is what
makes "hit the cover, kill the man behind it" work.

Walls stop the blast — every victim gets a `MASK_SOLID` line-of-effect check back to the impact — so
a round into one side of a building does not kill everyone on the other side.

## Suppression

Bots within `sm_heavyammo_suppress_radius` (500u, wider than the damage) have their arousal raised.
Arousal is what the game's own suppression feeds; `ins_bot_arousal_suppression_max` is its ceiling
and the default here matches it. The `ins_bot_arousal_frac_*` cvars in `betterbots.cfg` are what
turn it into behaviour — at the top of the range a bot's aim tolerance and aim tracking both get
worse.

Reaching it needs `NextBotPlayer_CINSPlayer::MyNextBotPointer` and `INextBot::GetBodyInterface` from
`tug2.games`, then the arousal float at `+0x138` — the same path `gg2_bot_smoke_suppress` already
uses in production. If that gamedata is missing the blast and fire still work and the plugin logs
once; suppression is the only part that degrades.

Note this makes a rattled bot *worse at shooting* but also *faster to react*, since high arousal cuts
`attackdelay` and `recognizetime`. That is the engine's model, not a choice made here.

## Setup

None beyond the config file. Each block's `upgrade` name is resolved to its runtime id on every map
through [`gg2_theater_items`](gg2_theater_items.md):

```sourcepawn
public void TheaterItems_OnReady()
{
    for (int i = 0; i < g_NumRounds; i++)
        g_Rounds[i].upgradeId = TheaterItem_Find(TheaterCategory_Upgrade, g_Rounds[i].upgrade);
}
```

Weapon upgrades are addressed at runtime by a theater-assigned integer that moves whenever the
theater is edited, and nothing exposed the name-to-id mapping to a plugin — `listtheateritems` prints
names with no ids at all. `gg2_theater_items` reads the theater's own definition tables, so the ids
are always right for whatever theater is loaded and there is nothing to configure or re-check after
an edit.

A round whose upgrade is missing from the loaded theater logs which one it could not find and then
behaves as ordinary ammunition.

`sm_heavyammo_scan` remains as a diagnostic — it prints the upgrades on the weapon you are holding
**by name** rather than as bare numbers:

```
[Heavy Ammo] weapon_m107: weapon def 58, ammo type 61
[Heavy Ammo]   upgrade slot 2 = 186 (ammo_ap_m107)
```

**`gg2_theater_items` is a hard dependency.** It provides the natives, so it has to be present
wherever this plugin is; the Dockerfile copies both into the test image together.

## The M107 itself

Already available, and needs nothing from this change. TUG defines `weapon_M107` in full — models,
optics, bipod, heavy barrel, quick-reload perk, a black skin, and HP/AP ammo upgrades — and it is
`"class_restricted" "0"`, which is what makes it buyable **without** appearing in any class's
`allowed_items`. Every `class_restricted "1"` weapon in this theater is listed in a class template
(14 of 14); 79 of the 107 `class_restricted "0"` weapons are listed nowhere and are still available.

Two things to know if you go looking for it, both of which caused wrong conclusions while this was
being written:

- **Case.** The definition is `weapon_M107`; every upgrade that references it says `weapon_m107`.
  The parser does not care, but a case-sensitive search for one will not find the other.
- **`allowed_items` is not the availability gate.** Its absence from every class template does not
  mean nothing can buy it. Do not add it to a class list to "fix" that.

## Not verified

Written against the binaries and the theater; none of it has been run.

- Whether `ins_m203_explosion` and `ins_molotov_explosion` are precached at the time of the first
  shot. Both are referenced by the theater's explosives, so they should be.
- The damage, radius and burn numbers are first guesses, not playtested.
- Whether the `weapon_upgrades` block merges cleanly on top of TUG's, which already defines
  `ammo_hp_m107` and `ammo_ap_m107` for the same weapon in the same upgrade slot. Both new names are
  unique, so by the `#base` first-match-by-name rule it should, but the M107 will then offer four
  ammo options where it offered two.
