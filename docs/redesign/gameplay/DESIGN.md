# SWARM redesign: gameplay track design

Brief: `docs/redesign/reference/Swarm-Claude-Chat-2-Gameplay.md`. Ownership: `docs/redesign/OWNERSHIP.md`.
Owner decisions: `docs/redesign/DECISIONS.md`. All numbers are starting tuning, kept in
`src/swarmv2/shared/Run/RunConfig.lua` (ReplicatedStorage.SwarmV2.Run.RunConfig) unless an existing
`Config` value already covers it.

Guiding rule: **reuse the existing run engine.** RunManager, StageManager, WeaponSystem,
EnemySpawner/EnemyAI, LevelUpSystem, LootSystem, encounters, bosses and rewards stay. The redesign
changes the camera, movement, ground height, map, roster and run entry. It does not write a second
engine.

## 1. Camera (client, `src/client/CameraController.lua`)

- The run camera becomes a third-person orbit: yaw and pitch from player input, distance 22
  (clamped 16-28 by pinch, wheel or settings), focus = root + (0, 2.5, 0), which is about the upper
  torso. Pitch is limited to 8-70 degrees down. Default pitch 22.
- Collision: spherecast (radius 0.6) from the focus to the wanted camera position, ignoring
  characters, enemies, projectiles, loot and `CollectionService` tag `CameraIgnore`. On a hit the
  camera pulls in fast and eases back out slowly (no pops).
- Input: on PC, right-mouse drag or mouse-lock (Shift) orbits. On gamepad, the right stick orbits.
  On touch, a drag on the camera area (the right 55% of the screen, outside buttons) orbits.
- Mobile recenter: after `RecenterDelay` 1.25 s with no camera input while moving, yaw eases behind
  the move direction at `RecenterRate` 2.2 rad/s. It never recenters while a camera drag is held.
- Reduced motion (`Accessibility` / settings): no shake, slower recenter, FOV kick off.
- The lobby camera belongs to the lobby track (the basecamp uses the standard Roblox follow
  camera). Outside a run, CameraController leaves `CameraType = Custom` alone.
- `GroundAxes()` returns camera-yaw-relative axes, so the move stick is camera-relative.
- Top-down-only client helpers (`Occlusion`, overhead `MiniMap` framing, `DangerArrows` screen edge
  logic, `GroundDetail` density) are checked and adjusted. Floor telegraphs still work: they are
  drawn on the ground and need the ground height.

## 2. Movement (client-driven, server-checked)

- Keep the existing custom driver (`MobileControls` binds `SwarmMove`, `hum:Move`) and
  `JumpController` (buffer, coyote, air control). Change these numbers:
  - `Config.Player.BaseSpeed` 16 -> 22
  - jump apex ~9 studs. With gravity 196.2, JumpPower = sqrt(2*196.2*9) ~ 59.4.
  - air control 0.7
  - Toastmaster apex 12 (JumpPower ~ 68.6)
- Touch layout: the left 45% of the screen is a floating move stick (touch-down spawns it). The
  right side is camera drag. Buttons: JUMP (big, bottom right) and DASH (above-left of JUMP, with a
  radial cooldown ring). Respect `GuiService` safe insets. A small ULT button stays where it is.
  PC: Space jumps, Shift or Q dashes, F ult. Gamepad: A jumps, B or RB dashes.
- **Dash** (`ServerScriptService.SwarmV2.Run.Dash`, remote `SwarmV2Net.Run.Dash`):
  - The client asks with a unit direction (no position, no speed).
  - The server checks: alive, in a run, not frozen, travelling or choosing in solo; cooldown
    passed; direction finite and normalised. Then it sets `rp.DashUntil`,
    `rp.DashSpeed`, `rp.DashDir` and fires back an ack.
  - The client (network owner) applies `AssemblyLinearVelocity` = dir * speed (horizontal only)
    for the duration, then hands control back.
  - Anti-tunnel: the client raycasts ahead each frame of the dash and stops at walls (0.8 stud
    margin).
  - Base: 70 studs/s, 0.22 s, cooldown 2.5 s.
  - `speedCheck` (RunManager) allows `max(normal, DashSpeed * 1.15)` while `DashUntil + 0.25` has
    not passed, the same pattern as `RushMult`.
  - Class variants: Granny 80/0.25/3.0. Croak's dash is a **leap**: a ballistic arc, horizontal
    31 studs, apex 7, about 0.55 s. His allowance covers horizontal 31/0.55*1.2 and the vertical.
- Cooldown and movement bonuses: the DASH button ring, plus the `Inventory` remote carries
  `DashCd` for the HUD.

## 3. Ground height and navigation (server, new `src/server/Modules/HeightGrid.lua`)

- After the map is built, `HeightGrid.Build(arena)` raycasts straight down on a 4-stud grid over
  the map bounds. It hits only parts tagged `NavGround` (floor, terraces, ramps, bridge decks,
  cave floors). Cave roofs and overhangs are not tagged.
- It stores `groundY[cell]` and `walk[cell]` (false where nothing was hit or the part is tagged
  `NavBlock`: cliffs faces, water, deep gaps).
- API:
  - `GroundY(x, z) -> number` (bilinear inside a cell; falls back to `Config.ArenaOrigin.Y`)
  - `IsWalkable(x, z)`
  - `CanStep(ax, az, bx, bz) -> bool`: the height change between neighbour cells is at most
    `StepMax` = 3.2 studs per 4-stud cell (about a 38 degree slope). Cliff edges are not steppable.
- **Flow fields:** for each living run player, a Dijkstra fill (8-neighbour, cells that can step)
  from the player's cell, out to a radius of 72 cells (288 studs). One player's field rebuilds per
  0.25 s, round robin, so 4 players means each field is under 1 s old.
- Enemy steering (`EnemyAI.think`):
  - If the target is within 10 studs and `CanStep` holds along a straight 3-sample line, seek
    directly.
  - Otherwise follow the flow-field gradient of the target's field.
  - With no field (outside the radius), seek directly as today.
- Each step: `pos.Y = GroundY(pos.X, pos.Z)`. A move into a cell that can't be stepped into is
  cancelled on that axis (slide along).
- Contact damage and weapon hits also need a vertical band: |dy| <= 6 for contact. For weapon
  hits, |dy| <= weapon area height (default 7).
- Spawning (`EnemySpawner`): candidate spots must be walkable and connected to the player
  (finite flow distance), 45-80 studs path distance away, and preferably off screen (behind the
  camera yaw, which the client sends at 2 Hz).
- Every other `Config.ArenaOrigin.Y` use in run modules (projectiles, loot, XP, hazards,
  telegraphs, encounters, portal, boss spawn) moves to `HeightGrid.GroundY` at that x/z.
  Projectiles fly at `GroundY(origin) + Height` and keep that Y. Ballistic ones land on
  `GroundY(target)`.
- Fall rescue: below `GroundY - 40`, or below the map, puts the player back at the last good
  ground position.

## 4. Cliffwood Basin (server, new `src/server/Modules/CliffwoodBuilder.lua`, used by MapBuilder for arena name `"Cliffwood"`)

- One map, about 1100 x 1100 studs, built from Parts (no Terrain). Kit:
  - cliff block (faceted, stacked, 60-180 tall)
  - terrace top
  - ramp/slope at least 24 wide
  - boulder
  - tall tree and bush
  - ruin arch, pillar and wall stub
  - standing stones
  - bridge (deck and rails)
  - cave (floor tagged NavGround, roof untagged, both sides open)
  - spring launch pad
- Palette: one green/brown/grey-tan palette (reuse the Forest palette and the `Config.Arenas.Dressing`
  greens).
- Layout (shape of the reference image):
  - **Main Basin**: centre clearing, 140 wide, the spawn.
  - Four more clearings of 80-120: **Old Ruins** (NE), **Stone Circle** (boss landmark: huge arch
    and standing stones, N), **Hollow Spring** (W), **Bramble Field** (SE).
  - **Upper Terrace** (E): reached by a wide winding ramp. An optional launch pad shortcut goes
    from the basin.
  - **Overlook** (NW): joined back to the basin by a broad stone bridge.
  - **Cave Shortcut**: under the cliff between the basin and Hollow Spring.
  - Two loops around rock formations. Outer border: giant cliffs (180 tall), so there is no fence
    wall.
- Main routes at least 24 wide, the main traversal route 1400-1800 studs. No essential jump. Every
  clearing is reachable on foot.
- Loot: chest, shrine and pot spots every 10-15 s of travel at 22 studs/s (about every 220-330
  studs of route). Side pockets are riskier but richer.
- Budget: aim for 6000 parts or fewer in total. Detail goes on landmarks; meshes from the existing
  prop kit where possible.
- The builder fills the existing arena table (`Obstacles` for trees and boulders, `Keepout`,
  `Paths`, `Half` = 550) and adds `arena.Landmarks = { {Name, Pos, Radius} }`, `arena.Spawn`,
  `arena.LootSpots`, `arena.Bounds`.
- Streaming: `Workspace.StreamingEnabled = true`, target radius 384, min 160. Run state never waits
  for a streamed part. Client lookups use `FindFirstChild` with no infinite waits.

## 5. Stages on one map

- `StageManager.arenaFor(n)` always returns `"Cliffwood"`. The map is built once per run and
  reused, not rebuilt each stage.
- Each stage picks the next landmark (not the last one used) for the portal (rune circle). Stage 5
  and the Endless boss stages use the Stone Circle.
- Travel between stages: no fade and no arena swap. Players stay where they are, enemies are
  cleared with a burst effect, XP is collected, then the new objective is revealed with an arrow.
  Difficulty steps up as today.
- The 5-stage win, Endless, bosses, surges, the portal choice and rescues are unchanged. The
  rescue villager uses the flow field to follow its hero.

## 6. Classes (`src/swarmv2/server/Run/ClassRegistry.lua` + `src/swarmv2/shared/Run/ClassKits.lua`)

- `ClassRegistry` registers `ruckus`, `toastmaster`, `captain_croak` and `granny_boom` into
  `CharacterData.Characters` at runtime (only ids that are missing; it never overwrites). Each gets
  `StartWeapon`, base stats, colours, a mesh model id and its passive. This keeps Mastery, hero
  upgrades, stats and leaderboards working with the new ids.
- The four signature weapons are added to `WeaponData` as normal weapons. Each has 12 levels and an
  evolution, and is offered only to its own class (`ClassOnly`).

| Class | Weapon (vs Knight Sword lvl 1: 10 dmg) | Passive | Movement |
|---|---|---|---|
| Ruckus | Scrap Toss: 10 dmg, 0.9 s, 1 bounce | **Loot Rush**: every 5 chest/shrine/item pickups (not XP gems) charges 1 Scrap Barrage (max 1 stored), fired with the next volley: 8 scraps in a ring | Dash drops 2 rolling cans; each explodes after 0.8 s, 6 radius, 1.2x weapon damage |
| Toastmaster | Toast Volley: 7.5 dmg, 0.65 s, 1 ricochet | **Overheat**: 3 hits on the same enemy within 4 s = Burn 3 s (refreshes, never stacks), 20% weapon damage per 0.5 s | Spring jump apex 12. Landing blast: 8 radius, 1.0x damage, 2 s cooldown, only after 0.35 s or more in the air |
| Captain Croak | Bubble Bomb: 11 dmg, 1.2 s, 1 bounce, 7 burst radius | **Big Splash**: a leap landing with an enemy within 10 empowers the next bubble (x1.8 damage, x1.4 radius), max 1 stored | Dash = Leap, 31 horizontal |
| Granny Boom | Yarn Bomb: 12.5 dmg, 1.4 s, 8 radius | **Tangled Up**: explosions tangle 0.75 s, 35% slow (bosses 0.3 s, 15%); refreshes up to 1.5 s in total per 3 s | Rocket Boost 80/0.25/3.0; the boost scorches the path for 0.6x damage |

- Every effect that triggers on a hit carries `NoProc = true`, so it can't trigger itself
  (no recursion).
- Visuals: mesh models from `blender/models/classes.py`. Procedural client animation on the
  Motor6Ds (`src/swarmv2/client/Run/ClassAnimator.lua`):
  - idle bob, walk cycle, jump squash
  - Ruckus tail swing and can clatter
  - Toastmaster toast pop on fire
  - Croak crouch before a leap and a boing on landing
  - Granny walker recoil and rocket flicker
- The StarterPack pass Gold Trim skin applies to the new classes.

## 7. Run entry (`src/swarmv2/server/Run/*`)

- `RunBoot.Init(ctx)`:
  - If `MatchAdmission.ServerRole() == "match"`: the server waits for arrivals. Each player
    calls `MatchAdmission.ResolvePlayer`, with bounded retry (3 tries, 1/2/4 s) while the
    loading overlay shows.
  - The first admission starts the barrier: start when every expected player is in, or after
    20 s. Missing players have 60 s of grace (a late player initialises once with the ticket's
    class, at a safe spawn, and the run clock doesn't reset). After the grace, or on rejection:
    the reason is shown, then `ReturnToLobby`.
- `RunEntry.BeginLocalMatch(matchId, players)` ("local" role): resolve each player, then
  `RunManager.StartTeamRun` with the admitted classes.
- The run never spawns a default avatar: `CharacterAutoLoads` stays false on match servers, and
  the class rig is built before the loading overlay drops.
- The class comes from the admission context (`rp.CharacterId = context.classId`), never from a
  client.
- End: results screen, then RETURN TO LOBBY calls `MatchAdmission.ReturnToLobby({player})`.
  Rewards are already committed by `RunManager.saveRunStats` (the `rp.Committed` guard), so a
  failed return never pays twice.
- Dev provider (`src/swarmv2/server/Run/DevAdmission.lua`): used only by tests and the offline
  preview, never by live code paths.

## 8. Co-op level-ups

The world already never pauses in co-op (`CoopChoiceFreezesRun = false`). Changes:
- the choice panel becomes a compact strip of 3 cards
- movement stays live while choosing (no more WalkSpeed 0)
- 10 s deadline, then a predictable fallback (the highest-weighted card)
- the protection budget stays

Solo still pauses (existing behaviour).
