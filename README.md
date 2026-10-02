# SWARM

Look and feel: heroic low-poly fantasy (see `docs/ART_DIRECTION.md`). Screenshots can be
rendered without Studio with the offline preview tool (`docs/PREVIEW.md`).

A Vampire Survivors-style auto-attack wave survival game for Roblox, written in Luau
with a Rojo project layout: exterminator heroes against an alien insect swarm.

Models come from two places:
- **Blender meshes** (`blender/`): chunky low-poly heroes, bugs, the Scorpion Queen boss,
  weapons, crystals and map props. They show up in game after they are uploaded (see §9).
- **Part-built fallbacks** in code, used for anything not uploaded yet, so the game always runs.

- Third-person top-down camera. You only move; weapons fire on their own.
- Runs are a series of STAGES (Risk of Rain / Megabonk style, see "Gameplay loop" below):
  find the portal, summon and kill the Scorpion Queen, survive the surge, then go deeper or
  cash out with a win. The lobby is a full-screen menu with three modes:
  **Solo** (starts at once), **Duo** (2 players) and **Trio** (3 players). In Duo and Trio
  you revive a fallen teammate by standing next to them for 3 s (see §10).
- 8 weapons (8 levels + evolution each), 12 passives, 6 enemy types + elites + boss.
- 4 characters, permanent gold upgrades, gamepasses, developer products, cosmetic skins.
- Mobile first: a floating thumbstick is the only control during a run.

## Gameplay loop

1. **Stage 1** is the lobby's arena (Forest or Ruins); later stages alternate through
   `Config.Arenas.Order` (Forest → Ruins → Forest ...). Each stage has a stone-ring
   **portal** at a random clear spot at least 120 studs from the spawn (a new spot every
   stage), with a soft light beam and a rune circle on the floor.
2. **Explore** while the swarm comes as always. Difficulty keeps scaling with the **total
   run time** (the per-minute tiers and spawn table), plus a per-stage multiplier
   (`Config.Stages`); stage 1 plays exactly like the old early game. HP / damage stop
   growing with time after minute 12 (`Config.Difficulty.MaxTier`). After 90 s (and not
   before the portal wakes) an arrow at the screen edge points every player to the portal.
3. **Charge the portal**: stand in its rune circle for ~2 s (any living player; on a phone
   just stand there) once it wakes up (dormant for 2:30 on stage 1, 0:45 later). That summons the **Scorpion Queen** behind the portal (HP scaled by
   stage and player count, the normal boss-fight spawning rules).
4. **Surge**: when she dies, every living player gets the boss gold and a burst of enemies
   pours out of the portal (25 + 15 per stage); survive 20 s or kill most of them. Gems,
   chests and chickens left on the floor when the group travels are collected for them.
5. **The portal opens**: leftovers burn up, the gems fly to you, and each living player
   picks **NEXT STAGE** or **RETURN TO LOBBY** (15 s, undecided = next stage).
   * Return = that player's run ends at once: `WinBonus` + `StageClearBonus` per stage
     cleared, best time / furthest stage saved, results over the lobby menu. It counts as a
     WIN (Stats.Wins) only with `Config.Stages.WinMinStages` (3) stages cleared.
   * Reaching stage 2 unlocks Ruins in the lobby (`Config.Arenas.<name>.RequiredBestStage`).
   * Next stage = everyone who stays travels (fade, "STAGE N"): new arena, enemies / gems /
     projectiles cleared, level / XP / weapons / passives / gold kept, HP topped up,
     fallen teammates revived. If nobody goes on, the run ends cleanly.
6. Dying still ends your run (results show the stage you fell on); everyone down = defeat.
   The timer shows the total run time; there is no 15:00 end any more.

Code: `StageManager.lua` (server, the loop and the portal), `RunManager.lua` (players,
results, travel), `MapBuilder.FindPortalSpot / BuildPortal`, client `StageUI.lua` (arrow,
charge ring, choice panel, travel fade) and the stage pill in `Hud.lua`.

## 1. Sync with Rojo

1. Install Rojo 7.x (the CLI and the Roblox Studio plugin).
2. In this folder (`swarm/`) run:
   ```
   rojo serve default.project.json
   ```
3. Open a new Baseplate in Studio, delete the Baseplate part, open the Rojo plugin and press **Connect**.
4. Press Play. The lobby menu appears; tap **SOLO** to start a run right away.

To make a place file without Studio: `rojo build default.project.json -o Swarm.rbxlx`.

Studio setup for saving:
- **Game Settings → Security → Enable Studio Access to API Services** (DataStores). Without it the
  game still runs, but progress is kept in memory only (the shop shows a red note).
- **Game Settings → Places → Max Players**: 4 (matches `Config.Run.MaxPlayers`).

## 2. Project layout

```
default.project.json
src/shared/   → ReplicatedStorage.Shared
  Config.lua            every tunable number
  WeaponData.lua        8 weapons x 8 levels + evolutions + projectile visuals
  PassiveData.lua       12 passives x 5 levels
  EnemyData.lua         enemy types + per-minute spawn table
  CharacterData.lua     4 characters + 13 skins
  MetaUpgradeData.lua   lobby shop upgrades
  IconData.lua          upgrade icon pictures (weapon / evolution / passive id → asset id)
  Remotes.lua           creates/gets ReplicatedStorage.Remotes (server creates them at boot)
src/server/
  GameServer.server.lua bootstraps modules, runs the single Heartbeat loop
  Modules/
    RunManager.lua      lobby → countdown → run → results, HP, death, revive, characters,
                        portal wins, travel between stages
    StageManager.lua    the stage loop: portal, charge, Queen, surge, NEXT / RETURN, travel
    EnemySpawner.lua    enemy pool, spawning, damage, deaths, drops, boss spawn
    EnemyAI.lua         batched movement, obstacle raycasts, contact damage, boss patterns
    WeaponSystem.lua    all weapons, projectile simulation, hit detection, sync batches
    XPSystem.lua        XP gems (pooled), shared XP, floor pickups, chests
    LevelUpSystem.lua   stat sheet, level-up cards, reroll/skip, evolutions, chest rewards
    GoldSystem.lua      run gold, lobby purchases (characters, skins, meta), settings
    DataService.lua     DataStore with session locking, retry, autosave, migration
    MonetizationService.lua  gamepasses, developer products, ProcessReceipt
    MapBuilder.lua      castle lobby (+ MenuCamera shot), Forest + Ruins arenas, lighting,
                        the stage portal (spot, model, beam, rune circle, state colours)
    ModelBuilder.lua    characters, hats, enemy shells, gems, pickups, chests
    SpatialGrid.lua     20-stud bucket grid for hit detection / neighbour queries
    Fx.lua              batches visual effects into one remote call per tick
src/client/   → StarterPlayerScripts.SwarmClient
  ClientMain.client.lua starts everything, music, VIP chat tag
  CameraController.lua  fixed-angle follow camera (+ spectate when dead)
  MobileControls.lua    floating thumbstick, WASD, gamepad
  VFX.lua               projectile rendering + spin/trails/impacts, sword swings, effects, gem/pickup
                        bob, aura rings, HP bars, walk cycle + attack poses
  ModelLibrary.lua      detailed animated 3D models for every enemy, the boss and every projectile
  EnemyRenderer.lua     draws those models on the server's enemy bodies (client only)
  UIBuilder.lua         in-run screens (HUD + upgrade bar, level-up, pause, results), scaling
  StageUI.lua           portal arrow, charge ring, NEXT STAGE / RETURN TO LOBBY panel, travel fade
  LobbyScreen.lua       the 2D lobby menu: home, characters, upgrades (§10)
  ViewportPreview.lua   turning 3D character previews (ViewportFrames)
  DevPanel.lua          DEV button, Studio only by default (§10)
  UIKit.lua             shared UI helpers, colours, upgrade icon tiles
  UIAnim.lua            UI motion: pop-ins, screen slides, punches, count-ups, button feedback
  Audio.lua             pooled sound effects + music
```

## 3. Gamepass and product IDs

Create them on the Creator Dashboard (your experience → Monetization), then paste the
numbers into `src/shared/Config.lua` → `Config.Monetization`:

| Key | What it is |
|---|---|
| `GamePasses.StarterPack` | +25% gold forever + Gold Trim skin for every character |
| `GamePasses.VIP` | +1 reroll per run, [VIP] chat tag, crown in the lobby |
| `GamePasses.DoubleGold` | 2x gold |
| `Products.Gold500/Gold1500/Gold5000` | gold packs (amounts in `ProductGold`) |
| `Products.Revive` | revive offered once per run when you fall |
| `SkinPasses.<SkinId>` | one gamepass per cosmetic skin (12) |

`0` means "not set up": the shop shows "Not set up yet" and the revive offer is skipped.
Purchases are cosmetic or convenience (gold and skins). There are no loot boxes.

## 4. Tuning difficulty (Config.lua)

| Want | Change |
|---|---|
| More / fewer enemies | `EnemyData.SpawnTable[minute].Target`, `Config.Difficulty.PlayerCountMult` |
| Tougher enemies over time | `Config.Difficulty.HPPerMinute`, `DamagePerMinute`, `SpeedPerMinute`, `MaxTier` |
| Bigger mini-waves | `Config.Spawn.MiniWaveBaseCount`, `MiniWavePerMinute`, `Config.Run.MiniWaveInterval` |
| Enemy cap (performance) | `Config.Enemies.MaxLive` (≤ `PoolSize`) |
| Elites | `Config.Enemies.EliteChance`, `EliteHPMult`, `EliteSizeMult` |
| Boss | `Config.Boss.*` (HP, attack timings, projectile count), `Config.Stages.BossHPByStage` |
| Stage difficulty | `Config.Stages.EnemyHPPerStage`, `EnemyDamagePerStage`, `SpawnTargetPerStage` |
| Portal | `Config.Stages.PortalMinDistance`, `PortalRadius`, `ChargeSeconds`, `PortalLockSeconds`, `HintAfterSeconds` |
| Queen fight crowd | `Config.Stages.BossMinionShare`, `BossMinionMin`, `Config.Boss.MinionCapDuringBoss` |
| Surge / choice | `Config.Stages.SurgeBase`, `SurgePerStage`, `SurgeSeconds`, `ChoiceSeconds`, `TravelHealFraction` |
| What counts as a win | `Config.Stages.WinMinStages`; arena unlocks: `Config.Arenas.<name>.RequiredBestStage` |
| Leveling speed | `Config.XP.Base`, `PerLevel`, `CapLevel` |
| Gold income | `Config.Gold.KillGoldChance`, `MinPerKill`, `MaxPerKill`, `Boss`, `WinBonus`, `StageClearBonus` |
| Player survivability | `Config.Player.BaseMaxHP`, `ReviveHPFraction` |
| Run length | the players decide (portal); `Config.Run.BossTime` is no longer used |
| Camera | `Config.Camera.RunDistance`, `Pitch` |

## 5. Adding a weapon

1. `WeaponData.lua`: add an entry to `Weapons` (copy an existing one) and its id to `Order`.
   Fill 8 rows in `Levels` (`row(damage, cooldown, amount, area, speed, pierce, duration, knockback)`)
   and an `Evolution` with a `Passive` id and evolved `Stats`.
2. If it needs a new look, add a visual to `WeaponData.Visuals` and use its index in `Params.Visual`.
   Its `Style` (Orb, Knife, Dart, Axe, Bottle, Boomerang, Saw, Stinger), `Trail` and `Impact` fields
   set how the client animates it; all of that is client-side and costs no network.
3. `WeaponSystem.lua`: write `Fire.<Behavior>(rp, w, s, def)` where `Behavior` matches the entry.
   Use `allocProjectile()` for projectiles (pick an existing `Kind`: Straight, Homing, Arc, Lob,
   Orbit, Boomerang) or damage directly with `hitEnemy` after a `grid():QueryCircle` lookup.
   Level-up card text is generated from the row differences automatically.

## 6. Adding an enemy

1. `EnemyData.lua`: add an entry to `Enemies` (HP, Speed, Damage, Radius, Size, Shape/Mesh, Color,
   Gem weights, flags like `Ghost`, `Erratic`, `Explode`).
2. Give it weight in the `SpawnTable` rows for the minutes it should appear.
That's all: pooling, movement, elites, drops and hit flashes work for every type.

## 7. How the performance budget is met

- One server Heartbeat loop for everything; enemy "thinking" is split across 3 frames.
- Enemies: one anchored Part each, pooled (300), moved with a single `workspace:BulkMoveTo`.
- No Humanoids on enemies, no per-enemy scripts, no `.Touched`: hits use a 20-stud spatial grid.
- Projectiles are server data only; clients get one buffer of positions per sync tick (30 Hz)
  and draw pooled parts. Effects are batched into one remote per tick.
- Gems are pooled Parts (500); bob/spin is local to each client.
- Detailed enemy models exist only on clients: the server still replicates one part per
  enemy. `Config.Graphics.MaxDetailedEnemies` caps how many get the full model on screen.

Note: `SetNetworkOwner(nil)` is only called for unanchored enemy parts. Enemy bodies are
anchored (moved by CFrame), and anchored parts are always server-owned; Roblox rejects the
call on them.

## 8. Audio

`Config.Sounds` uses sounds that ship with every Roblox client (`rbxasset://sounds/...`) for
effects. Music entries are empty: pick free licensed tracks in the Creator Store (Audio,
filter by creator "Roblox"), and paste `rbxassetid://<id>` into `LobbyMusic`, `BattleMusic`
and `BossMusic`.

## 9. 3D models (Blender → Roblox)

Preview pictures of every model are in `renders/` (`renders/Sheet_*.png`).

1. Edit models in `blender/models/*.py` (enemies, heroes, items, world).
2. Build: `pip install bpy==5.0.1 pillow` (Python 3.11), then `python3 blender/build.py`
   (exports `meshes/<Category>/*.fbx`, `meshes/catalog.json` and new renders).
3. Upload (once per changed model) with an Open Cloud API key that has
   *Assets read + write* for the account that owns the game:
   ```
   ROBLOX_API_KEY=... ROBLOX_USER_ID=... python3 tools/upload_meshes.py
   ```
   This fills `meshes/uploaded_ids.json` and regenerates `src/shared/MeshCatalog.lua`.
4. Rebuild the place (`rojo build`). On start the server loads each uploaded model with
   InsertService; anything missing keeps its part-built fallback.

The stage portal (`Portal`, World category: stone ring, rune dais, membrane and glyphs
recoloured per portal state) is built and in the catalog but not uploaded yet; until it is,
`MapBuilder` uses its part-built fallback with the same look and collider.

Each model is split into pieces (one MeshPart each) that are coloured in game by "slot"
(skins and elites recolour them) and animated by the client (legs, wings, claws, tail).

## 10. Lobby screen, modes and dev tools

Whenever you are not in a run, a full-screen menu (`LobbyScreen.lua`) covers the screen;
there is no walking in the lobby (no thumbstick, lobby characters stand still, the lobby's
ProximityPrompts are switched off).

- **Home**: gold, best time and wins at the top, SETTINGS (volume) top right; your own
  character turning in the middle (tap it to change character); your permanent upgrades
  summarised; the big **SOLO / DUO / TRIO** buttons; CHARACTERS, UPGRADES and ARENA.
- **Characters**: one card per character with a turning 3D preview, role, description,
  starting weapon, bonus, Buy / Select and the skins (tap a swatch to equip or buy).
- **Upgrades**: permanent gold upgrades and the Robux shop (gold and cosmetics only).
- **Camera**: if the lobby (a Model/Folder `Lobby` in workspace or in `SwarmMap`) has a part
  named `MenuCamera`, its CFrame is the menu camera; otherwise a fixed view of the spawn.

Modes (`Config.Modes`):

| Mode | Players | Start |
|---|---|---|
| Solo | 1 | at once, no countdown |
| Duo | 2 | countdown (`Config.Run.CountdownSeconds`); others tap JOIN |
| Trio | 3 | same as Duo |

During a countdown the lobby shows who joined; the player who started it can tap
**START NOW** once someone joined, and a full run starts by itself. Duo and Trio share the
partner-revive rules (`PartnerRevive`: 3 s next to a fallen teammate, 40% HP, 3 per player).
`Config.Run.MaxPlayers` (4) stays the hard cap; the old "Squad" (1-4) mode is still accepted
from old clients but not shown.

**DEV button** (bottom right): only in Studio by default, so it never shows in normal play.
Set `Config.Dev.ShowInLiveGame = true` to also show it to the game's creator in live servers.
Lobby: *Start solo now*. In a run: *+5 levels*, *Spawn portal boss* (charges this stage's
portal at once) and *Teleport to portal*. The server checks
the same rule again for every request (`RunManager` "DevCommand"). Turn it off with
`Config.Dev.Enabled = false`.

## 11. Upgrade icons

During a run your weapons (top row) and passives (bottom row) show as icon tiles at the
bottom of the screen, with an "xN" level badge and a gold border once a weapon evolves.
Level-up cards use the same icons. Until pictures exist each icon is a coloured tile with
1-2 letters. To add pictures: make square PNGs (one per weapon, evolution and passive id),
upload them as Decals/Images, and paste each asset id into `src/shared/IconData.lua`
(instructions at the top of that file).
