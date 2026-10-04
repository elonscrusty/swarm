# VFX-ART: weapon / pickup effects and planted weapon models

Area: `src/client/VFX.lua` (weapon and pickup effects), `src/client/ModelLibrary.lua` projectile /
totem / snare builders, `blender/models/items2.py` `Shot_Totem`. Issues: ART-08 (Vine Snare),
ART-09 (Healing Totem), ART-10 (spectral bolts, equal white rings), ART-21 (gems, coin bursts),
part of ART-05 (snow separation of heal circles and skull projectiles). Shared vocabulary:
`docs/overhaul/ART_VOCABULARY.md`. Nothing here was tested in Studio or on a device.

## What I inspected

- Review frames long/420s (Snow, full build: totem, souls, garlic), short/070s; icons
  `art/icons/HealingTotem.png`, `VineSnare.png`, `SoulBolt.png`.
- Server mechanics read (not changed): `WeaponSystem.Fire.Vines` / `Arm.stepSnare` and
  `Fire.TotemOne` / `totemPulse`.
- Client drawing: `VFX.renderProjectiles`, `projectileRotation` ("Totem" style), `wave`,
  `totemPulseFx`, `K.vineSprout`, `goldBurst` / `renderCoins`, `gemPop`, `renderGems`;
  `ModelLibrary` `totem`, `snare`, `soul`, `SHOT_MESH`.

## Findings (observed in code / renders vs suspected)

| Issue | Root cause | Kind |
|---|---|---|
| ART-08 Vine Snare | Planted model was a 45%-transparent green disc with six thin straight sticks (0.32 studs) and tiny thorns; the cast added one more solid green ring. Grip / release: the server roots every 0.5 s for `duration` s (2-3 s; `x.T = 0` so the first tick is immediate); the client model rose in 0.25 s and then stood still, and vanished in one frame when the server dropped it (no release state at all). The model ring (2.4) was smaller than the real reach (2.6 x area). | observed in code |
| ART-09 Healing Totem | `Shot_Totem` mesh (3.1 x 1.5 scale) was a thin post, small wings and a gold crown cradling a small orb: from the overhead camera a post with a bright top (the "cross / torch" read). The icon is a stacked two-face idol with wings and a big green core, no gold. Pulse = a solid pale-green ring every 1.0 s per totem; pale fx_heal washes out on snow ("pale-yellow healing circles"). | observed |
| ART-10 | Soul Bolt skulls: ivory_200 bone, pale wisp (heal green mixed toward ivory), 1x scale: small pale shapes like the pale moths. Several friendly areas were solid pale rings (totem, snare cast, vortex) of the same weight as shockwaves. | observed |
| ART-21 coins | Coins flew INTO the hero's root (+0.5) and each ended with a gold sparkle there: up to 36 two-stud coins converging on the hero hide it from the overhead camera. | observed in code + render |
| ART-21 gems | Collected gems burst at the collection point, which for a flying gem is the hero: a Neon ball growing to 1.5 studs plus a 1.7-stud cross glint, up to 5 per frame, over the hero's body. | observed in code |
| ART-21 flat gems | See "Gems in motion" below. | test |

## Changes

- Healing Totem: new `Shot_Totem` mesh (Blender, 6 pieces / 502 tris, uploaded id
  124246776936271, was 139623917489526): compact idol, stern lower face, beaked upper head,
  two broad carved wing fins, banded cup holding a big faceted green life-core (Neon), three
  sprouts at the foot. Slots kept (Wood, Wood2, Dark, Gold = the cup band, Glow, Leaf) so
  Lifebloom's gold recolour still applies; origin ground centre, scale 1.5 in game (~3.7
  studs). Part-built fallback `ModelLibrary.totem` rebuilt to the same design.
- Totem pulse (`VFX.totemPulseFx`): one dashed ring per server pulse in a slightly deeper
  heal green, turning a little; a pulse that healed adds a thin dark-moss inner edge (snow
  readability) and a small flare off the core (`K.TOTEM_CORE_Y` = 3.1; off with Reduce Flashes);
  damage-only pulses are a single faint ring.
- Vine Snare model (`ModelLibrary.snare`): an opaque dark earth patch sized to the real reach
  (2.8 / 4.4 evolved), 4 (6 evolved) thick two-segment roots bursting up and curling in over the
  ring, big pale thorns on the outside of every bend, leaves; no glow. The root pieces carry the
  new `Grip` animation (`ModelLibrary.Animate`): driven by the snare's age (`VFX` passes
  `now - Born` for planted models), they clench inward on every 0.5 s root tick and ease off.
  Cast (`K.vineSprout`): a dashed moss ring to the edge plus earth clods thrown out (no green
  disc). Release (`K.snareRelease`, from `projectileImpact`): roots sink back into the floor
  with a dust disc. Mechanics untouched.
- Soul Bolt / Soul Storm (`SHOT_MESH[31]` / `[32]`): drawn 1.3x, warmer bone (ivory_300), a
  saturated green spectral tail (crimson for Soul Storm); fallback the same.
- Friendly-area language (`VFX.wave(..., dash)`): dash 0.55 rings turn slowly as they ripple out;
  used by the totem pulse, snare cast and Vortex opening (now arcane-tinted instead of one
  more white ring). Player and teammate markers unchanged (solid rings); enemy telegraphs
  are filled shapes (Telegraphs.lua, ENEMY-ART).
- Coins: absorbed at the hero's marker ring (`K.COIN_END_RING` = 2.9 studs out on the side
  they came from) instead of the hero's centre; one sparkle per arriving burst (80 ms gate).
- Garlic / Soul Eater aura: a thin dark slate under-edge outside each dash (`deco.AuraEdge`),
  so the pale ring survives on snow (coordinator / ENEMY-ART request).
- Fallback hit flash (`VFX.flash`, bodies EnemyRenderer does not track): was pure white; now
  the same partial brighten as EnemyRenderer (0.6 grunt / 0.45 elite / 0.32 boss, luminance
  scaled), still off with Reduce Flashes.
- Vortex rift model: the two wide discs are no longer Neon (only the core and swirl arms are).
- Gems taken on the hero (`gemPop(..., onHero)`): a floor-level ring flick (off with Reduce
  Flashes) and three shards thrown outward, at most `K.GEM_POPS_NEAR` = 2 per 0.1 s; the bright
  pop stays for gems taken away from the hero.

## Gems in motion (ART-21, test)

`pickups-close --set arena=Snow --set trail=off` at t = 0.8 and 1.25 s (scratchpad
`wf/vfx-art/gems/`): every crystal kit shows its two-tone crown and darker pavilion and the
facets swap light / dark as it turns; at some yaws a crown pair is near one tone for a moment,
which is the "flat quadrilateral" read in a still frame. Gems beyond `K.GEM_NEAR` (42 studs)
are the server cube on its corner in one colour by design. Verdict: not a mesh defect; no
change. Risk: a Studio check at the owner's zoom on snow is still open.

## Tests (offline only; nothing Studio / device / multiplayer verified)

New scene `tools/preview/scenes/friendly-fx.luau` (totem + pulse, two snares, souls, coins
and gems arriving at the hero; `arena`, `evolved`, `release`, `t`, `dist`, `reduced`).
Renders in scratchpad `wf/vfx-art/` (before = the tree with my files reverted to the
pre-overhaul versions, other helpers' work kept):

| Check | Result |
|---|---|
| `bash tools/check.sh --quick` | PASS (typecheck, compile, icons) |
| friendly-fx Forest + Snow, pc + iphone, before / after | PASS (visual): snares read as dark earth patches with thorny curled roots on grass and snow (before: thin sticks); totem is the idol with a green core (before: a post with a bright top); souls carry a green tail and read apart from the pale moths; coins gather at the marker ring and the hero stays visible; heal pulse is a dashed ring with a dark inner edge, visible on snow (`after/snow2`) |
| friendly-fx release (evolved, t 0.15) | PASS: snares and totem gone, Lifebloom dashed ring + core flare; roots sink (faint at this zoom) |
| combat-fx armoury Forest + Snow, pc + iphone, before / after | PASS, 0 errors; only the snare cast and vortex ring changed there (the after renders predate the vortex disc change) |
| weapons-sim `weapons=armoury` (headless, 5 s phases) | PASS: 0 errors, 45 kills / 1111 dmg, every armoury weapon incl. Vine Snare fires at lv 8 and evolved |
| perf-sim short (200 enemies) | see below |
| Studio, phone, co-op | BLOCKED (owner) |

Remaining risk: the Grip clench is driven by the client's first-seen time, so it can be up
to one sync interval off the server tick; the snare model radius is fixed per visual (2.8 /
4.4) while the real reach grows with Area upgrades; the new totem mesh only shows in game
once Studio loads asset 124246776936271 (the part-built fallback matches meanwhile).
