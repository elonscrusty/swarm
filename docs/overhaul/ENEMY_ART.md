# ENEMY-ART: enemies, bosses and combat feedback (master prompt section 7)

Issues: ART-01 (hostile vs friendly areas), ART-02 (white hit flash), ART-03 (mite crowds),
ART-04 (elite affixes), ART-05 (Snow readability, enemy side), ART-06 (Scorpion Queen),
ART-07 (Moth Matriarch); UI-22 partly (elite ring/tag order). Asset rows: ASSET_REGISTER.md.

Everything below is offline evidence (Lune preview + mock renderer, Blender renders). Nothing
was tested in Studio or on a device.

## Representative slice

New scene `tools/preview/scenes/enemy-slice.luau` (normal run camera, real EnemyRenderer,
Telegraphs and VFX): Knight in a 46-enemy crowd (mites, wasps, beetle warriors), Swift,
Burning and Shielded elites, Burning fire patches, a Healer pulse, the hero's Healing Totem
and Vine Snare, the stage boss closing in over its charge lane, and a hit-flash moment on the
boss, two elites and every third enemy (`EnemyRenderer.Flash`, as VFX calls it).
`--set arena=Forest|Snow` (Scorpion Queen / Moth Matriarch), `--set flash=off`.

Renders (before = tree at task start, after = these changes), pc + iphone, Forest + Snow:
`scratchpad/wf/enemy-art/{before,after}/[snow/]enemy-slice-{pc,iphone}.png`.

## Root causes (observed in code and renders)

| Issue | Root cause | Change |
|---|---|---|
| ART-02 | `EnemyRenderer.Flash` set every piece to pure white (1,1,1) for 0.08 s, every hit; a boss under constant hits re-whitened continuously | Per-piece lerp toward warm ivory: 0.6 grunt / 0.45 elite / 0.32 boss, scaled by the piece's luminance (dark legs, undersides and seams barely change: contour kept); a boss re-flashes at most every 0.3 s. Reduce Flashes / Reduced Effects still switch it off. Damage = this brief lift; attack prep = pose + floor telegraph (unchanged); elite = crown, ring, aura (never a flash) |
| ART-03 | Mite mesh shell was one pale slot over the full dome | Mite mesh: pale top `Shell` + darker olive lower band `ShellSide`, wider elytra seam. Low-detail cut keeps the shell and its band together (still 4 parts: shell, band, head, eyes; legs dropped at distance instead of the pale top) |
| ART-04, ART-01 | Elite ground ring was a soft gold filled disc (same family as loot, the hero ring and amber fire); Swift aura all ivory | Elite ring = crimson rim around a dark core (hostile, ring-shaped); Swift aura deep blue streaks with pale cores; tag text 11 → 13 px. Burning (flame wedges), Shielded (orbiting plates) shapes kept |
| ART-01 | Burning fire patch had an amber dashed edge | Crimson (Danger) dashed rim, thicker, over the dark scorch; Healer pulse now a dark moss rim under a lighter, more transparent fill |
| ART-05 | Pale moth wings, ivory Swift aura and white flashes on snow | Moth recolour (below), Swift recolour, flash change. Player effects on snow are VFX.lua (not owned): FOR OTHERS |
| ART-06 | Mesh crimson/gold vs portrait black/amber; thin legs | Charcoal chitin, amber-orange plates and claws, gold crown piece, green venom tip and eyes; thicker legs and claws. Tail glow, stinger shots and telegraphs stay amber/crimson (green means healing elsewhere) |
| ART-07 | Pale ivory/lavender translucent wings, pale abdomen | Violet fore-wings, deep plum under-wings (less transparent), dark plum outer-edge rim, navy abdomen; cream fur, gold eye-spots, coronet kept. Portrait ornament not copied |

Queen wind-up / contact / recovery: checked in code, not changed. Server `BossAI Start.Rush`
sets Act `Windup` for the lane telegraph's full `Windup` (1.0 s; 0.8 s second lane), then
`Charge` for `Duration` 0.9 s, then `Stunned` recovery 1.3 s (BossData Charge); the client
poses (crouch + tremble, lunge, dizzy stars) follow the same Act attribute. Timing on a device
is not verified.

## Tests

- `bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok (remaining lints are in Hud.lua, not owned).
- enemy-slice before/after, Forest + Snow, pc + iphone: 0 errors; flash 18/18 hit.
- combat-regression: PASS.
- perf-sim: see the report / PERFORMANCE_BASELINE.md (see below).
- Blender: Mite 400 tris (6 pieces), ScorpionQueen 2044 tris, MothMatriarch 1634 tris.

## Remaining risk / not done

- Studio/device: meshes uploaded (ids from the upload tool) but never loaded in Studio.
- Full-detail mites move one more part each (up to MaxDetailedEnemies = 80 more parts per frame).
- Not done in this pass: Vine Snare / Healing Totem look, spectral projectile vs pale flyers,
  the hero's aura ring on snow (all VFX.lua or weapon models: FOR OTHERS), other enemy families.
