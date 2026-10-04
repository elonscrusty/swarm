# PROPS-ART: portal, rune puzzle, chests, shrines, altar, caravan

Overhaul area for master prompt section 7 (interactables) and issues ART-11, ART-12, ART-13,
ART-14, ART-15 (plus the caravan ring part of ART-01). Offline only: preview renders and Lune
sims. Nothing here was checked in Studio or on a device.

## What I inspected

- Review frames: long/480s and 522s (portal beam and pulse dashes over the masonry while charging
  in Snow), long/574s (rune stones: gray cuboids with a coloured orb; the prompt carries the
  order), short/093s (Small Chest prompt; small flat chest), long/450s and 482s (bargain shrine,
  altar).
- Code: `LootSystem.lua` (chest, shrine, altar, rune builders and state paint),
  `CaravanEvent.lua` (`buildCart`, `recolour`, `succeed`), `MapBuilder.BuildPortal`,
  `PortalBeacon.lua`, `LootUI.lua` target selection (read only), `MeshCatalog` (which kits are
  meshes), the chest icons (`art/icons/chest.png`, `art/icons/rewards/reward_ChestLarge.png`,
  `reward_ChestGolden.png`).
- Whole rune prop: it was one part (`Stone`, 2x3x2) plus an orb and a ring. No face had a
  symbol; the only identity was the orb colour (Moon slate, Sun gold, Star crimson).

## Root causes (observed in code)

- Portal: two beams stacked over the arch: the server beam (4.4 wide, from 6 studs, inside the
  11-stud arch) and the client pillar (2.4 wide, from 1 stud, transparency ~0.2-0.4), plus a
  two-ring floor pulse running 14 studs out in every state, charging and boss included. That
  is the "sunburst" in long/480s and 522s.
- Rune targeting: stones stood 6 studs from the centre (10.4 apart) with 6.5-stud interact
  circles, so most of the puzzle area was in reach of two or three stones. The client picks the
  nearest stone and drops the hold when another becomes nearest, so a player between stones could
  lose a hold or see the prompt switch.
- Chests: `Chest_Small/Large/Golden` have no mesh, so the part fallback is what players see: a
  flat box with a flat lid, iron straps, and Golden as an all-gold block. The icons have a
  rounded faceted lid, two bands, a lock plate and tier materials (wood/gold, crimson/steel,
  slate/gold). The loot prompt uses `reward_ChestLarge` for every chest (`LootUI.lua:89`).
- Shrines: Chance and Bargain are the same small stone-pillar silhouette with a coloured orb;
  a sealed bargain kept glowing crimson.
- Caravan: the canvas used Fabric (the fine tan pattern); the hold ring was a filled warm disc
  like a fire pool; Saved kept a full gold lantern and light.

## Changes

`src/server/Modules/LootSystem.lua` (model/state functions only; prices, odds, rewards and
rules untouched):
- `CHEST_LOOK` / `chestFallback`: one construction for all tiers matching the icons (faceted
  lid with wedge bevels, two bands over body and lid, rim, corner posts, lock plate, keyhole,
  hasp). Tiers: Small wood + gold, Large crimson + steel + gold studs, Golden slate + gold + red
  gems, Plain (free cache) wood + iron with no gold. Every lid piece is named `Lid*`, so the
  existing hinge swing opens it.
- `premiumDressing`: beam starts above the coin (4.9 studs), slimmer and fainter.
  `quietOpened`: opened chests (and the claimed altar chest) dull their gems and plinth trim.
- Runes: `runeGlyph`, `runeLook`, new `buildRunes`, `useRune` repaint. Monument = plinth,
  pillar, tablet leaning to face the 55° camera with a raised crescent / sun / star; centre
  order tablet with three flat glyphs left to right. States: ready (muted), correct (glyph and
  token glow + light), reset (0.7 s crimson flash, then the restarted sequence), completed
  (quiet gold, no light, rings hidden). Star colour crimson → fx_ivory, Moon slate → fx_arcane.
  `RUNE_RADIUS` 9: stones are 15.6 apart, so the 6.5-stud circles never overlap (fair targeting
  without touching the client picker). The hold (0.4 s), order, reset rule and reward are as before.
- `shrineCrown`: Chance wears a gold coin with a glowing core (it costs gold, like paid
  chests); Bargain wears an iron balance with a gold and a crimson pan (a trade). Sealing tips
  the balance, turns off its Neon, light and ring.
- Shrine/rune/altar "stand here" disc fainter (`RING_T` 0.88, was 0.8).

`src/server/Modules/CaravanEvent.lua` (model only): canvas SmoothPlastic ivory_300, crimson
heraldic band and gold crest on the camera side, banded cargo chest, ring = faint fill + 28 ivory
edge dashes (friendly-area language from ART_VOCABULARY), Saved = quiet (ring hidden, low
lantern, light off). Waves, timing and rewards untouched.

`src/server/Modules/MapBuilder.lua` (`PORTAL_LOOK`, `BuildPortal` only): beam from 11.5 studs
(above the arch), 3 wide, core 1 wide, every state 0.04-0.06 more transparent, light a bit
softer. State colours unchanged.

`src/client/PortalBeacon.lua`: pillar 1.6 wide from 12 studs up, transparency 0.45-0.6, cap
3.6; floor pulse reaches R+6 (was R+14) with smaller, fainter dashes and runs only while the
portal is available (idle) or open (exit ready); none while charging (the rune-circle marks
show the charge) or during boss / surge (telegraphs stay readable). Reveal burst radius 30.

New preview scene `tools/preview/scenes/props.luau`: the whole family side by side with real
holds (`--set rune=0|1|2|solved|reset`, `altar=Guarded|Claimed`, `bargain=active`).

No Blender mesh was made or uploaded: every change is part-built at runtime (the chests and
runes had no mesh to begin with), so there are no new asset ids. Rows in ASSET_REGISTER.md.

## Evidence (scratchpad/wf/props/)

- `before/props-pc.png` vs `after/props-pc.png`, `after/r2/` (two runes correct),
  `after/solved/` (runes solved, bargain sealed, altar claimed), crops `after_crop_chests.png`,
  `after/crop_runes2.png`, `after/crop_solved.png`.
- `before|after/stage-portal-{pc,iphone}.png` (charging 60%), `before|after/boss/` (charge 1 with
  the Boss look), side by side `portal_pc_ba.png`, `portal_crop_ba.png`, `portal_boss_ba.png`,
  `portal_iphone_ba.png`. "Before" was rendered from a copy of the tree with the old
  PortalBeacon/MapBuilder.
- `before/loot-{pc,iphone}.png` (focus Golden, old chests).

Read of the renders: the arch masonry and the 60 % charge marks are visible after (they were
under the beam and dashes before); glyphs read at gameplay zoom (crescent, rayed sun, star), lit
vs muted vs gold-complete are distinct; the three chest tiers match their icons.

## Tests

| Check | Result |
|---|---|
| `bash tools/check.sh --quick` | PASS (typecheck, compile, icons) |
| encounters-sim (deliberate altar, rune order/reset, single rewards, cleanup) | PASS |
| caravan-sim, encounter-placement | see bottom |
| props scene pc, 4 variants | rendered, 0 errors |
| stage-portal pc + iphone, before/after; Boss look pc | rendered, 0 errors |
| perf-sim | see bottom |

## Remaining risk / not done

- Not Studio-tested: WedgePart orientation and Metal material look were checked only in the
  preview renderer (whose wedge matches Roblox: full back face, slope to the front).
- Part count: a paid chest is ~24-28 parts (was ~10-13), about +220 static anchored
  non-colliding parts per stage; runes +~70; caravan +34. Server CPU is unaffected (static);
  phone draw cost is unmeasured offline.
- The muted Star glyph (ivory) is still fairly light on its stone; lit vs muted relies on Neon
  plus the light. Check on a phone in Snow.
- Chest beams are still Neon columns (the owner asked for paid chests to read from afar); only
  thinner and lifted off the chest.
- The altar mesh (`Guard_Altar`) and shrine meshes are unchanged; distinction comes from the
  crowns. A bespoke Bargain mesh would need the Blender pipeline + upload.

## FOR OTHERS

- UISTATE / LootUI `src/client/LootUI.lua:89` and `:761`: pick the prompt icon by tier so the
  prompt matches the world chest: `LootType` Small / Treasure → `"chest"`, Large →
  `"reward_ChestLarge"`, Golden → `"reward_ChestGolden"` (today every chest shows
  `reward_ChestLarge`, the crimson one).
- UISTATE / LootUI `:1100`: optional hysteresis (keep the current target while it stays in
  reach unless another is clearly nearer, e.g. by 1 stud) for chests placed close together; the
  rune stones no longer need it.
- HUD / MiniMap: the rune stones still show as "Loot"; a small glyph marker would help (not
  required).
