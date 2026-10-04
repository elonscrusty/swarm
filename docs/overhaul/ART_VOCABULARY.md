# SWARM shared material and lighting vocabulary

One small vocabulary for every model, icon, portrait and effect, so the hero, a mite, a chest
and a heal pulse read as one family. It refines `docs/ART_DIRECTION.md` sections 2, 3 and 7
(palette values: `src/shared/Palette.lua` / `art/palette.json`). Owner: VFX-ART (overhaul
2026-10). Applies to new and refined assets; existing assets are brought in line when touched.

## 1. Six materials

Every surface belongs to one of six families. Each has a value band (how light it may be from
the run camera), a Roblox material, a palette family and a highlight / shadow rule. Use two or
three tones per material on one model (by piece), never a texture.

| Family | Palette | Roblox material | Value band (run camera) | Highlights / shadows | Used for |
|---|---|---|---|---|---|
| Metal | steel_200..600, gold_200..600 (trim) | Metal (small surfaces only) | mid (steel_400 main), edges one step lighter | edge 300, shade 600; gold is trim, never a big plate; no Neon | armour, blades, hooks, chain, turret, coin rims |
| Wood | wood_400..900, leather_* | SmoothPlastic | mid-dark (wood_500/600 bodies) | carved grooves wood_900, raised carving one step lighter; never orange | totems, posts, fences, barrels, shafts, chests |
| Stone | stone_100..900, basalt_* | SmoothPlastic (Slate only on small rocks) | mid on the floor, one step lighter or darker than the ground it sits on | caps one step lighter, undersides 800 | ruins, portal masonry, rock projectiles, monuments |
| Shell | beetle_*, amber_*, wasp_*, moth_*, tick_*, chitin_* | SmoothPlastic | bright top over dark sides and undersides (chitin_900) | segmentation by darker seams; elites keep rank cues, never the player gold | creatures only |
| Cloth | crimson_*, slate_*, ivory_* (cloth highlights) | SmoothPlastic | crimson cape is the strongest colour on screen | folds one step darker; no white cloth on snow without a darker edge | hero cape, banners, bags |
| Magic | fx_* (heal, arcane, holy, fire, bolt, gold) + XP gem colours | Neon only for small cores (eyes, gem cores, orbs, flames) | the only family allowed to be lighter than everything around it, but small | a Neon core sits inside a non-Neon body (orb in a cup, eyes in a skull) | life-cores, orbs, eyes, sparks, trails |

Rules:
- A big surface is never Neon. Glow lives in a core the size of a fist relative to the hero.
- Pale objects (bone, ivory, snow props, moths) carry one darker element (sockets, rim, tail,
  underside) so they survive on snow and ice.
- Earth (dirt_500..700) is the ground material for things that come out of the floor (snares,
  burrows, spawns); it reads as "of the world", not as an effect.

## 2. Colour meaning (one meaning per family)

| Colour family | Means | Never used for |
|---|---|---|
| Gold (gold_300..500) | the local player (marker ring), coins, rewards, rank / evolution | enemy warnings, healing |
| Crimson / amber over a dark outline | enemy danger (telegraphs, elite rims, boss attacks) | the hero's own areas |
| Amber / orange fire (fx_fire, lava) | fire (hero's Fire Trail on the floor, burning elites are crimson-rimmed, see ENEMY_ART) | loot, the player ring |
| Green (fx_heal, moss) | healing, nature (Healing Totem, Vine Snare, heal pickups); enemy Healers use a filled disc | damage warnings |
| Spectral green tail + bone | the Necromancer's souls (projectiles) | creatures |
| Azure / blue / violet | XP gems only | gold, danger |
| Ivory / pale | slashes, hit sparks, Garlic aura | big areas on snow without a dark edge |
| Slate blue | teammates (marker ring) | the local player |

## 3. Floor-area language (hostile vs friendly)

Three shapes, so the read never depends on colour alone:

| Who | Shape | Rhythm | Height |
|---|---|---|---|
| Local player marker | a solid continuous gold ring (2.7 studs), soft gold fill, facing chevron | steady (no pulse) | floor + 0.07 |
| Teammate marker | a solid thinner slate-blue ring, chevron | steady | floor + 0.07 |
| Hero's own areas (friendly) | dashed / segmented ring at the effect's real reach, no fill (or a near-invisible one), turning slowly | ripples outward once per server beat (totem pulse 1.0 s, snare cast) and fades | floor + 0.09-0.1 |
| Enemy warnings (hostile) | filled shapes over a dark outline: growing discs, lanes, spokes (Telegraphs.lua) | fill grows toward the rim = the hit moment | floor + 0.36-0.43 |
| Shockwaves (any side) | solid ring racing out once, very short | one-shot | floor + 0.09 |

Code: `VFX.lua` `wave(..., dash)` (dash 0.55 = friendly), `styleRing`; markers `updateMarker`;
hostile shapes `Telegraphs.lua` (ENEMY-ART).

## 4. Lighting

- Gameplay lighting stays as `docs/ART_DIRECTION.md` section 6 (warm high sun, Snow Brightness
  2.25, bloom Threshold >= 1.6). Effects must read without bloom: a Neon core plus a darker
  body, not a bigger glow.
- A model may carry one PointLight (mesh catalog `light`) at its magic core only (totem
  core, chest gem); no lights on effects.
- Snow / ice: tune by value (darker edge, darker tail, deeper green) on the effect, never by
  darkening the biome.

## 5. Pickups and bursts

- Coins fly to the hero and are absorbed at the marker ring (2.9 studs out on the side they
  came from), never onto the hero's body; one sparkle per arriving burst.
- Gems collected on the hero burst at floor level (a ring flick and three shards outward), at
  most 2 per 0.1 s; the bright pop is for gems taken away from the hero.
- XP crystals keep their faceted two-tone crown / darker pavilion; see VFX_ART.md for the
  in-motion check.

## 6. Reduced Effects / Reduce Flashes

Every effect above checks `ClientSettings.Reduced()` (fewer parts: no inner heal edge, two clods
per snare cast, no snare-release roots, no gem shards) and the shared part budget (`room()`).
Reduce Flashes (`ClientSettings.Flashes()`) also drops the totem core flare and the Neon floor flick
of a gem taken on the hero. Nothing in this vocabulary flashes the whole screen or a whole model.
