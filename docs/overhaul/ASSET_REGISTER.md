# SWARM overhaul: asset register

Every custom model, icon, VFX or audio asset changed in the overhaul. One row per change.
Helpers append rows to the table for their own area; keep the columns.

Columns: asset; kind; what changed; editable source; import / runtime assumptions; asset id
(only ids returned by the upload tools); status (finished / placeholder / not uploaded).

Pipeline for meshes: `python3 blender/build.py --only <Name> --samples 12` exports
`meshes/<Category>/<Name>.fbx` + `renders/<Category>/<Name>.png`;
`ROBLOX_USER_ID=20194281 python3 tools/upload_meshes.py --only <Name> --force` uploads it
(ids in `meshes/uploaded_ids.json`) and regenerates `src/shared/MeshCatalog.lua`. Piece names,
pivots, origins (ground centre, front -Y) and scale stay as before unless a row says so, so
rigs (runtime anim keys in `src/client/ModelLibrary.lua`) keep working.

| Asset | Kind | Change | Source | Assumptions | Asset id | Status |
|---|---|---|---|---|---|---|
| Mite (Slime id) | mesh, 6 pieces / 400 tris (was 5 / ~350) | Elytra and pronotum split into a pale top `Shell` (Base) and a darker olive lower band `ShellSide` (new slot `Side`, beetle_300 → beetle_700 at 0.7); wider seam between the elytra; pronotum set slightly forward. Crowds keep a dark rim between shells | `blender/models/enemies.py` `mite` | Same origin, pivots, leg pieces and size; part-built fallback in `ModelLibrary.ENEMIES.Slime` gets the same darker sides; the low-detail cut keeps the 4 biggest pieces | 71654881065197 (was 131793605673006) | finished, not Studio-tested |
| ScorpionQueen (Boss id) | mesh, 25 pieces / 2044 tris (was 24) | Palette aligned with `art/bosses/ScorpionQueen.png`: charcoal chitin (Base), slate-charcoal legs (Accent), amber-orange armour plates and tail rings (Gold), green venom tip and eyes; the crown is its own `Crown` piece in gold; claws thicker and armoured amber over the whole upper half; legs thicker (radius 0.5 → 0.05) | `blender/models/enemies.py` `scorpion_queen` | All existing piece names kept (+ `Crown`, static); pivots and bounds unchanged; fallback `LOOKS.Boss` recoloured to match. Hostile cues (tail glow, stinger projectile, telegraphs) stay amber/crimson on purpose: green is the heal colour | 72660051836708 (was 85324322185907) | finished, not Studio-tested |
| MothMatriarch (MothBoss id) | mesh, 17 pieces / 1634 tris | Violet fore-wings (Light) and deep plum under-wings (Accent), both less transparent (0.32 → 0.12, 0.18 → 0.08); a dark plum rim strip along each fore-wing's outer edge (in `WingMarks*`); dark navy abdomen (new slot `Belly`) under the gold bands; cream fur, gold eye-spots, coronet and antennae unchanged | `blender/models/bosses.py` `moth_matriarch` | Piece names, pivots, flutter rig unchanged; fallback `LOOKS.MothBoss` recoloured to match. The portrait's ornate crescent pattern is not copied (unreadable at gameplay scale) | 85428907301667 (was 92319373542620) | finished, not Studio-tested |
| EliteAura_Swift | runtime palette override (no new mesh) | Streaks deep blue (46, 82, 150) with ivory cores and pale-blue tips instead of all-ivory (vanished on snow) | `src/client/ModelLibrary.lua` `AURA_PALETTE` | Uses the existing uploaded mesh; part-built fallback streaks recoloured the same | unchanged | finished |
| Elite ground ring | runtime parts (EnemyRenderer) | Was a soft gold filled disc; now a crimson rim (Accessibility "Danger") around a dark core disc, slow breathing (steady with Reduce Flashes) | `src/client/EnemyRenderer.lua` | Two pooled cylinders per elite (pool keep 12) | n/a | finished |
| Enemy hit flash | runtime colour (EnemyRenderer) | Was every piece pure white; now each piece lerps toward warm ivory by 0.6 (grunt) / 0.45 (elite) / 0.32 (boss), scaled by the piece's luminance so dark legs/undersides stay dark; a boss re-flashes at most every 0.3 s | `src/client/EnemyRenderer.lua` `flashColors` | Off with Reduce Flashes / Reduced Effects as before; duration `Config.Enemies.HitFlashSeconds` unchanged | n/a | finished |
| Burning fire patch, Healer pulse | runtime telegraph parts | Fire patch rim crimson (Danger) and thicker instead of amber; Healer pulse = darker moss rim disc under a lighter, more transparent fill | `src/client/Telegraphs.lua` `Kind.patch`, `POP.heal` | Timing and radii unchanged | n/a | finished |
