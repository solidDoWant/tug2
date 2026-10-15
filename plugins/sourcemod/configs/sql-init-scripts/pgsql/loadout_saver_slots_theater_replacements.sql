-- =====================================================
-- LoadoutSaverSlots - move saved loadouts off weapons the theater removed
-- =====================================================
-- Runs after loadout_saver_slots.sql. Idempotent: once applied, nothing names the old items, so
-- every statement below matches no rows on later runs.
--
-- theater_tug_nvg_default.theater stubs out weapons to free weapon ids (see "Removed weapons" at
-- the bottom of its "weapons" block). A loadout naming one of them still loads - the plugin skips
-- the missing item - but the player silently loses that slot. Where the theater names a weapon that
-- stays in its place, this points the saved item at it instead. Weapons removed with nothing in
-- their place (the 1911s, AC-556, Sten, Khukuri) are left alone and keep being skipped.
--
-- WHAT IS PRESERVED
--
-- Upgrades installed on a replaced weapon stay installed (parent_ordinal is unchanged). Most fit the
-- replacement as-is; the few that have a same-stat equivalent on it are translated in step 2. Any
-- other upgrade that does not fit is left in place: the game refuses that one buy at load time,
-- costing nothing, and the row disappears the next time the player saves.
--
-- ORDINALS ARE NOT RENUMBERED, AND NOTHING IS DELETED
--
-- ApplyLoadout matches an upgrade's parent_ordinal against the weapon's POSITION in the
-- ORDER BY ordinal result, so ordinals must stay 0..n-1 with no gaps. Every statement here either
-- rewrites item_id in place or appends at max(ordinal) + 1, which keeps them contiguous.
--
-- A loadout that held both a removed weapon and its replacement (a Glock 17 and a Glock 18) ends up
-- with the replacement twice. That is left to the game to arbitrate like any other buy.

-- 1. Every name this writes has to exist in theater_items. The plugin records names as it sees
--    them, so on a server that never saw one (the M79 rounds are new) the row is missing.
INSERT INTO theater_items (category, name) VALUES
    (0, 'weapon_mp5a4'),
    (0, 'weapon_glock18'),
    (0, 'weapon_at4'),
    (0, 'weapon_fal'),
    (0, 'weapon_mp40'),
    (0, 'weapon_sigp226'),
    (0, 'weapon_m79'),
    (1, 'ammo_ap_m9'),
    (1, 'ammo_hp_m9'),
    (1, 'underbarrel_foregrip_ins1'),
    (1, 'magazine_m79_napalm'),
    (1, 'magazine_m79_smoke')
ON CONFLICT (category, name) DO NOTHING;

-- 2. Upgrades that do not fit the replacement but have an equivalent that does. Runs before step 4,
--    which renames the parent weapons this matches on.
--      SIG P220 .45 AP/HP -> the P226's 9mm AP/HP (same cost)
--      L1A1 foregrip_sec2 -> the FAL's foregrip_ins1 (both import base_foregrip: same stats)
--    Not translated, no equivalent: the L1A1's folding foregrip, the P220's extended magazine, and
--    the Sterling's integrated suppressor and Aimpoint.
UPDATE loadout_items u
SET item_id = nu.id
FROM (VALUES
        ('weapon_sigp220', 'ammo_ap_m45',               'ammo_ap_m9'),
        ('weapon_sigp220', 'ammo_hp_m45',               'ammo_hp_m9'),
        ('weapon_l1a1',    'underbarrel_foregrip_sec2', 'underbarrel_foregrip_ins1')
     ) AS m(weapon, old_upgrade, new_upgrade)
     JOIN theater_items ow ON ow.category = 0 AND ow.name = m.weapon
     JOIN theater_items ou ON ou.category = 1 AND ou.name = m.old_upgrade
     JOIN theater_items nu ON nu.category = 1 AND nu.name = m.new_upgrade,
     loadout_items w
WHERE w.loadout_id = u.loadout_id
  AND w.ordinal = u.parent_ordinal
  AND w.item_id = ow.id
  AND u.item_id = ou.id;

-- 3. The M79 napalm and smoke weapons are now rounds on the one M79 (magazine_m79_napalm /
--    magazine_m79_smoke). Install the round on each, appended after the loadout's last item. Runs
--    before step 4 turns these rows into plain weapon_m79, after which they cannot be told apart.
INSERT INTO loadout_items (loadout_id, ordinal, item_id, slot, parent_ordinal, quantity)
SELECT w.loadout_id,
       last.ordinal + row_number() OVER (PARTITION BY w.loadout_id ORDER BY w.ordinal),
       r.id,
       NULL,
       w.ordinal,
       1
FROM loadout_items w
JOIN theater_items ow ON ow.id = w.item_id AND ow.category = 0
JOIN (VALUES
        ('weapon_m79_napalm', 'magazine_m79_napalm'),
        ('weapon_m79_smoke',  'magazine_m79_smoke')
     ) AS m(weapon, round) ON ow.name = m.weapon
JOIN theater_items r ON r.category = 1 AND r.name = m.round
JOIN (SELECT loadout_id, max(ordinal) AS ordinal FROM loadout_items GROUP BY loadout_id) last
  ON last.loadout_id = w.loadout_id;

-- 4. The weapons themselves. quantity goes to 1 for the M79s: it counted napalm/smoke purchases,
--    each of which granted rounds, and replaying that on weapon_m79 would buy the launcher again
--    rather than more rounds. Every other replacement keeps its quantity (all are single buys).
UPDATE loadout_items w
SET item_id  = n.id,
    quantity = CASE WHEN m.new_weapon = 'weapon_m79' THEN 1 ELSE w.quantity END
FROM (VALUES
        ('weapon_mp5',        'weapon_mp5a4'),
        ('weapon_glock17',    'weapon_glock18'),
        ('weapon_law',        'weapon_at4'),
        ('weapon_l1a1',       'weapon_fal'),
        ('weapon_sterling',   'weapon_mp40'),
        ('weapon_sigp220',    'weapon_sigp226'),
        ('weapon_m79_napalm', 'weapon_m79'),
        ('weapon_m79_smoke',  'weapon_m79')
     ) AS m(old_weapon, new_weapon)
     JOIN theater_items o ON o.category = 0 AND o.name = m.old_weapon
     JOIN theater_items n ON n.category = 0 AND n.name = m.new_weapon
WHERE w.item_id = o.id;
