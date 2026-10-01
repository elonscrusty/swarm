# SWARM

A Vampire Survivors-style auto-attack wave survival game for Roblox, written in Luau
with a Rojo project layout. Everything (maps, characters, enemies, gems, UI) is built
in code from Parts, built-in meshes and UI instances. No external assets are needed.

- Third-person top-down camera. You only move; weapons fire on their own.
- 15-minute runs, a boss at 15:00, up to 4 players per server in one arena.
- 8 weapons (8 levels + evolution each), 12 passives, 6 enemy types + elites + boss.
- 4 characters, permanent gold upgrades, gamepasses, developer products, cosmetic skins.
- Mobile first: a floating thumbstick is the only control during a run.

## 1. Sync with Rojo

1. Install Rojo 7.x (the CLI and the Roblox Studio plugin).
2. In this folder (`swarm/`) run:
   ```
   rojo serve default.project.json
   ```
3. Open a new Baseplate in Studio, delete the Baseplate part, open the Rojo plugin and press **Connect**.
4. Press Play. The server builds the lobby; walk onto the green pad to start a run.

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
  Remotes.lua           creates/gets ReplicatedStorage.Remotes (server creates them at boot)
src/server/
  GameServer.server.lua bootstraps modules, runs the single Heartbeat loop
  Modules/
    RunManager.lua      lobby → countdown → run → results, HP, death, revive, characters
    EnemySpawner.lua    enemy pool, spawning, damage, deaths, drops, boss spawn
    EnemyAI.lua         batched movement, obstacle raycasts, contact damage, boss patterns
    WeaponSystem.lua    all weapons, projectile simulation, hit detection, sync batches
    XPSystem.lua        XP gems (pooled), shared XP, floor pickups, chests
    LevelUpSystem.lua   stat sheet, level-up cards, reroll/skip, evolutions, chest rewards
    GoldSystem.lua      run gold, lobby purchases (characters, skins, meta), settings
    DataService.lua     DataStore with session locking, retry, autosave, migration
    MonetizationService.lua  gamepasses, developer products, ProcessReceipt
    MapBuilder.lua      lobby + Backyard + Mall arenas
    ModelBuilder.lua    characters, hats, enemy shells, gems, pickups, chests
    SpatialGrid.lua     20-stud bucket grid for hit detection / neighbour queries
    Fx.lua              batches visual effects into one remote call per tick
src/client/   → StarterPlayerScripts.SwarmClient
  ClientMain.client.lua starts everything, music, VIP chat tag
  CameraController.lua  fixed-angle follow camera (+ spectate when dead)
  MobileControls.lua    floating thumbstick, WASD, gamepad
  VFX.lua               projectile rendering, effects, gem bob, aura rings, HP bars, walk cycle
  UIBuilder.lua         every screen, built in code, scaled with UIScale
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
| Tougher enemies over time | `Config.Difficulty.HPPerMinute`, `DamagePerMinute`, `SpeedPerMinute` |
| Bigger mini-waves | `Config.Spawn.MiniWaveBaseCount`, `MiniWavePerMinute`, `Config.Run.MiniWaveInterval` |
| Enemy cap (performance) | `Config.Enemies.MaxLive` (≤ `PoolSize`) |
| Elites | `Config.Enemies.EliteChance`, `EliteHPMult`, `EliteSizeMult` |
| Boss | `Config.Boss.*` (HP, attack timings, projectile count) |
| Leveling speed | `Config.XP.Base`, `PerLevel`, `CapLevel` |
| Gold income | `Config.Gold.KillGoldChance`, `MinPerKill`, `MaxPerKill`, `Boss`, `WinBonus` |
| Player survivability | `Config.Player.BaseMaxHP`, `ReviveHPFraction` |
| Run length | `Config.Run.BossTime` |
| Camera | `Config.Camera.RunDistance`, `Pitch` |

## 5. Adding a weapon

1. `WeaponData.lua`: add an entry to `Weapons` (copy an existing one) and its id to `Order`.
   Fill 8 rows in `Levels` (`row(damage, cooldown, amount, area, speed, pierce, duration, knockback)`)
   and an `Evolution` with a `Passive` id and evolved `Stats`.
2. If it needs a new look, add a visual to `WeaponData.Visuals` and use its index in `Params.Visual`.
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

Note: `SetNetworkOwner(nil)` is only called for unanchored enemy parts. Enemy bodies are
anchored (moved by CFrame), and anchored parts are always server-owned; Roblox rejects the
call on them.

## 8. Audio

`Config.Sounds` uses sounds that ship with every Roblox client (`rbxasset://sounds/...`) for
effects. Music entries are empty: pick free licensed tracks in the Creator Store (Audio,
filter by creator "Roblox"), and paste `rbxassetid://<id>` into `LobbyMusic`, `BattleMusic`
and `BossMusic`.
