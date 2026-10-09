# Gameplay track: handoff (2026-10-09)

Branch `claude/dazzling-fermi-ycslnt`. Offline only; nothing has been run in Studio.

## Done and merged (type check clean)

- **Shared base on `main`:**
  - `src/swarmv2/*` Rojo folders
  - `Types`, `ClassCatalog`, `MatchAdmission` placeholders
  - boot hooks
  - `docs/redesign/OWNERSHIP.md` and `DECISIONS.md`
- **Camera and movement:**
  - third-person orbit camera (`CameraController`)
  - camera-relative movement and touch layout (`MobileControls`, `JumpController`)
  - server-validated dash and leap, plus server-started launches (`SwarmV2/Run/Dash.lua`, `DashClient.lua`)
- **Ground height:**
  - `HeightGrid` (ground height plus flow fields), used across the run engine (`docs` in its header)
  - `GroundHeight` on the client
- **Map:** Cliffwood Basin (`CliffwoodLayout.lua`, `CliffwoodBuilder.lua`; arena name `Cliffwood`). It has:
  - landmarks
  - loot spots (LootSystem uses them, `RunConfig.Map.ChestMult`)
  - a launch pad (`Run/LaunchPads.lua`)
- **Single-map stages:** `StageManager`. The portal moves between landmarks, and the boss uses the Stone Circle.
- **Classes:**
  - four meshes (uploaded; `MeshCatalog` category Classes)
  - `ClassRoster` registered at server and client boot (old heroes hidden, default `ruckus`)
  - four ClassOnly weapons, kits and passives (`ClassKits.lua`, `docs/redesign/gameplay/CLASSES.md`)
  - procedural animation (`ClassAnimator`) and the class HUD chip
- **Run entry** (`Run/RunEntry.lua`, `ArrivalBarrier.lua`, `DevAdmission.lua` test-only):
  - the match-server barrier (20 s group wait, 60 s late grace)
  - `BeginLocalMatch` for Studio
  - the return hook through `MatchAdmission.ReturnToLobby`
  - loading overlay (`EntryOverlay`)

## Tests (offline Lune, 2026-10-09; all PASS when run together)

| Area | Checks |
|---|---|
| New for the redesign | cliffwood-run-sim, class-kits-sim, run-entry-regression (21/21), heightgrid-regression, single-map-regression, cliffwood-top |
| Existing | combat, math, run-manager, data, fall (updated for Cliffwood), portal-hold, corner, stage-sim, weapons-sim, reward-once, security |

The full regression suite has not been run since the merges.

## Next: final merge with the lobby track

1. The owner sends the lobby chat's branch name. Merge it into this branch.
2. Its `docs/redesign/lobby/HANDOFF.md` and `PATCHES_lobby.md` say what to apply.
3. Check the contract seams:
   - the real `MatchAdmission` must replace the placeholder (`ServerRole`, `ResolvePlayer`, `ReturnToLobby`)
   - the lobby calls `RunEntry.BeginLocalMatch` in the "local" role
   - the lobby sets `workspace` attribute `SwarmV2Lobby = true`
   - RunServers coexists with the new match role
4. Remove the old menu lobby (`MapBuilder.BuildLobby` use, the old START flow) once the basecamp works.
5. Full check: `bash tools/check.sh`, then `python3 tools/run_regressions.py --workers 4` (long). Fix fails.
6. Rebuild `build/Swarm.rbxlx`, commit, send to the owner. Merge into `main` (owner chose: two branches, merge at end).
7. Update the "Where things stand" section of CLAUDE.md.

## Known gaps (playable-first; follow-up polish)

- The cliffs are blocky 10-stud cells. A mesh cliff pass is needed.
- The launch pad arc is high (~85 studs, 2.5 s). Tune it with the owner.
- No icons yet for the 4 class weapons and their evolutions.
- "Spawn behind the camera" is not done. A TODO is in `EnemySpawner`.
- No performance pass and no phone layout check of the new DASH button vs the HUD and minimap.
- Class bonus numbers, bubble splash 60%, and the ultimate and second-skill names need the owner's OK (`CLASSES.md`).
