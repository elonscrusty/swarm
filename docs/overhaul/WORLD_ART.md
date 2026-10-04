# World art: arena boundaries, biome edges, hazard footprints (WORLD-ART)

Scope: master prompt section 7 (boundaries; Forest / Snow / Swamp and the other arenas;
slowing regions vs visible edges; tree occlusion). Issues: ART-16, ART-17, ART-20 (and the
ground part of ART-05). Files: `src/server/Modules/MapBuilder.lua` (arena section only, not the
lobby), `src/client/GroundDetail.lua`. `BiomeHazards.lua` was read and needed no change.
Everything below was checked offline (preview renderer + Lune sims on the mock Roblox API).
Nothing was tested in Studio or on a phone.

## What I looked at
- Evidence `long/274s` (Forest SE corner, the GI-01 pocket): long grey south-rim slabs with
  tilted ends, a thin split-rail fence a stud *inside* the rim, and the tall east cliff ending
  in one sheer flat block face (flat green cap) standing on the knee-high rim.
- Evidence `long/588s` (Swamp, stage 3): a perfectly round olive ring around the bog pond;
  lilypads in both the deep water and (half of) the mud pools.
- Code: `cliffs` / `cliffBlock` / `brokenFence` / `treeLine`, the pond builders, `hazardPool`,
  `BiomeHazards.kindAt`, the GroundDetail density map, `Occlusion.lua`.
- Before renders of every biome's SE corner (pc + iphone, 120 enemies) from the CORNER commit
  `c5ad391`, same scene and seed after.

## Root causes (observed in code and renders)
1. **Corner seam (observed):** the west / east tall rows ran 6 studs past the south edge, so
   their last chunk (13-21 studs tall) ended in a flat block face right on the 2-4 stud rim,
   facing the camera. Same in all six arenas (Swamp before render shows it too).
2. **Slab rim (observed):** south rim chunks were bare rock blocks (no cap) of 25-30 studs with
   up to 7° turn and 3° tilt, so neighbouring ends stuck up at every join.
3. **False edge (observed):** the camera-side fence (Forest, Snow) stood at `h - 1`, inside the
   walkable square, with no collision; enemies and the hero stood "on" it while the real stop
   is the rim / invisible Boundary behind it.
4. **Foot rocks (observed):** cliff foot pieces were placed to poke up to 1 stud into the play
   square (decor, no collision) - solid-looking rock on walkable floor.
5. **Pond regularity (observed):** one disc bank of r + 2.6/2.8. Mud vs water language:
   lilypads and reeds were used on both the slowing mud and the impassable water.
6. **Hazard footprint (measured, `scratchpad/wf/worldart/footprint.py`):** the fixed hazard
   circle (3.6 / 4.4 at scale 1) was centred on the model origin, while the mesh's surface
   piece is off-centre by up to 0.4 studs; the circle ran up to 0.42-0.53 studs (x scale,
   about 0.8 studs in game) past the mud / sand / ice / lava surface into the rim on one side.

## Changes (`MapBuilder.lua` arena section)
- `cliffs`: west / east tall rows stop `CORNER_SET` (6) studs before the south edge; the last
  chunk is trimmed to end there (min 12 studs). New `cliffShoulder` at both camera-side corners:
  an 18-stud capped upper step (55 % of the cliff height) and a 22-stud capped lower step
  (rim + 1.4), inner faces at `h + 0.6` (just outside the Boundary), small turn / tilt.
  `cornerRock` sets the biome's face rock (Rock / Swamp_Rock / Snow_Rock / Desert_Rock /
  Basalt_Rock) on the upper step against the tall cliff's end face; Ruins (no face rock, its
  foot block costs 10 parts) keeps the cut-stone steps only.
- South rim: chunks 31-35 studs every 30 (was 25-30 every 26), calm (2.5° turn, 1.2° tilt),
  overlapping, each with a thin cap in a rim colour half-way between the biome cap and its rock
  (`CliffStyle.RimCap`; Snow uses fresh snow) so the edge reads as a bank a step off the floor
  value. The row now ends where the upper corner step hides it.
- `cliffBlock`: `cap` share (0 = none) and `calm` arguments replace `noCap`; optional cap colour.
- `brokenFence`: does nothing when the arena has cliffs (all six do), removing the false edge.
  Camp fences (real obstacles with colliders) stay. One-line revert if the owner wants them back.
- Cliff foot pieces sit flush with the edge (`- 0.2` instead of `- 1`).
- Tall-side chunks 48-55 studs every 46 (was 45-52 every 43) to pay for the corners.
- Ponds: new `pondBank` (Forest pond, Swamp bog pond) - main bank ring r + 1.9 plus two lobes,
  one a darker wet margin, from its own `Random` so the seeded layout after it is unchanged.
  Water disc and circle collider stay equal (the water edge is where you stop).
- Mud pools: rim decor is grass / pebbles / mushrooms, no lilypads; reeds + lilypads are now
  only on the deep water. The old lilypad rng draws are kept so the layout does not shift.
- Hazard pools: `hazardFill` reads the mesh's surface piece (`Mud`, `Sand`, `Ice`, `Lava`) from
  MeshCatalog; the hazard circle is centred on it (mesh shifted by the piece offset, model
  `WorldPivot` at the hazard point so the minimap / accessibility outlines line up) with the
  piece's mean half size as radius. Scale-1 radii: Mud 3.6 → 3.47, Quicksand 3.6 → 3.39,
  Ice 4.4 → 4.32, Lava 3.6 → 3.43. Residual mismatch is the ellipse vs circle only
  (0.02 / 0.19 / 0.31 / 0.22 studs at scale 1). Lava glow ring uses the real radius.
- Snow: collapsed watchtower snow caps 0.35 → 0.7 thick (closer to the cliff / rim caps);
  tree line step 38 → 42 (budget). Swamp: edge reeds inside the square 38 % → 22 % (budget,
  less clutter on walkable floor).

## Changes (`GroundDetail.lua`)
- No pooled ground pieces under the camera-side rim (z h+0.3..h+10) or the corner steps
  (|x| > h, z < h+31) in cliff arenas: they were hidden inside rock (wasted pool slots).

## Collision and layout
No collider was added, moved or removed. `arena-map` layout metrics (obstacle count, blocked
area per ring) are **identical** before / after in all six arenas. Hazard records moved by
≤ 0.6 studs and shrank 2-6 % (above).

## Part budget (`arena-map`, default seed; docs/PERFORMANCE.md table)
| arena | before (parts / mesh / instances) | after | pre-cliff guide |
|---|---|---|---|
| Forest | 1174 / 681 / 1526 | 1183 / 675 / 1531 | 1207 |
| Ruins | 1153 / 645 / 1423 | 1185 / 657 / 1458 | 1146 |
| Swamp | 1200 / 766 / 1513 | 1184 / 734 / 1488 | 1196 |
| Snow | 1241 / 841 / 1531 | 1251 / 837 / 1538 | 1196 |
| Desert | 1051 / 710 / 1332 | 1043 / 688 / 1320 | 1054 |
| Lava | 1092 / 744 / 1348 | 1108 / 744 / 1364 | 1046 |
All stay inside the 1 050-1 260 band; Ruins (+32) and Lava (+16) pay for the rim caps; Snow is
+10 (0.8 %). Tree-line counts move by a few pieces because the rng stream after `cliffs` shifted.

## Tests (offline)
- PASS `bash tools/check.sh --quick` (typecheck, compile, icon keys).
- PASS `corner-regression` (all arenas, every spot; needs `--max-time 3000`: it simulates
  2 330 s. With the runner's `--max-time 400` it fails as "did not finish" even at `c5ad391`
  - see FOR OTHERS).
- PASS `encounter-placement` (six biomes, four types, three variants).
- PASS `ground-sim` (pool, reduced settings, cleanup, hysteresis).
- PASS `stage-sim` (seed 1: Forest, Snow ice ×1.2, Desert quicksand 8.8, Lava burn 120 → 113,
  Ruins; seed 2: Swamp mud WalkSpeed 10.4 = 16 × 0.65), 0 FAIL.
- Renders: SE corner of every biome, pc + iphone, before (`c5ad391`) and after; Forest / Swamp
  pond before / after; occlusion grove and Snow SW / Forest NW corner after.
  Evidence: `scratchpad/wf/worldart/{before,after}/`.
- perf-sim: see the end of this file.

## Visual verdict (renders)
- Corners: PASS. The camera-side corner now steps tall cliff → capped step with a rock → low
  step → rim; no sheer block end on the rim. Snow rim reads as a snowed bank; Forest rim cap is
  a darker moss band, visibly an edge. The fence is gone.
- Ponds: improved but subtle at gameplay zoom (thinner bank, one visible lobe); the water edge
  is still round because the collider is round (deliberate: no hidden collision mismatch).
- Occlusion (ART-20): `Occlusion.lua` tests every tagged item's box independently against the
  camera-to-player lines, so overlapping crowns all fade; two faded crowns still stack to about
  58 % cover. Particles/shadows are not faded (VFX owners). See the grove render.

## Remaining risk / not done
- Not Studio-tested; real lighting/shadows and mesh shading differ from the preview.
- The far (north) corners were left as they were (the north row's and first west/east chunk's
  face rocks already meet there).
- Ruins corner has steps but no rock (budget).
- Hazard radius shrink is gameplay-visible (slightly smaller slow / burn area); reversible by
  going back to `HAZARD_KIT.Radius`.
