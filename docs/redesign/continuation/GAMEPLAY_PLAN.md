# Gameplay track (Chat 2): continuation plan and shared contract

Brief: `Swarm-Complete-Continuation-Prompt.md` (this folder). Mapping decisions: `../DECISIONS.md` C1-C10.
The redesign so far: `../gameplay/DESIGN.md`, `../gameplay/HANDOFF.md`. Every number below comes from the
brief. All tuning lives in `src/swarmv2/shared/Run/RunConfig.lua`, with **one section per work stream**.
Edit only your own section.

## Work streams and file ownership

| Stream | Owns (edit) | Wave |
|---|---|---|
| **A Models** | `blender/models/classes2.py`, `meshes/Classes/*`, `MeshCatalog.lua` (generated), renders | 1 |
| **B Builds and combat core** | `WeaponData.lua`, `PassiveData.lua`, `StatSheet.lua`, `LevelUpSystem.lua`, `WeaponSystem.lua` (core rules and legacy and existing-4 behaviours), `SynergyData.lua` (hide), RunConfig `Builds` / `Combat` | 1 |
| **D Run director** | `StageManager.lua`, `EnemySpawner.lua`, `EnemyData.lua`, `EnemyAI.lua` (new behaviours), `BossData.lua`, `BossAI.lua`, new `src/swarmv2/server/Run/Beacon.lua`, RunConfig `Director`, plus in RunManager only `EndRun` / victory wiring | 1 |
| **E1 Survival rules** | RunManager damage / downed / revive / death / reconnect / fallRescue sections, `JumpController.lua`, `MobileControls.lua` movement numbers, `DashClient.lua` / `Dash.lua` (shared rules), RunConfig `Survival` | 1 |
| **E2 Loot economy** | `XPSystem.lua`, `GoldSystem.lua` (team run gold only, keep settlement), `LootSystem.lua` chests, `ItemSystem.lua` (hide old items in chests), class-goal counters plus the settlement hook in RunManager `saveRunStats`, RunConfig `Economy` | 1 |
| **F Run UI** | `Hud.lua`, `MiniMap.lua`, new `src/swarmv2/client/Run/*` UI modules, `UIBuilder.lua` (level-up cards, results), RunConfig `UI` | 1 |
| **C Class kits (12)** | `ClassKits.lua`, `ClassRoster.lua`, kit parts of `WeaponSystem.lua` (new `Fire.*` for the 8 new signatures), RunConfig `Classes` | 2 (after B) |
| **G Feel and audio** | `tools/synth_sfx.py`, `Audio.lua` cues, `CombatFx` / `HitFeel` | 3 |
| **H Perf and verification** | tests, profiling, fixes anywhere | 3 |

If you need a change in someone else's file, keep it to a few lines, mark it `-- [stream X]`, and list it in
your report.

## Shared contract (names every stream uses)

**Run phase:** the SwarmState attribute `RunStage` is one of `Survive`, `BeaconAvailable`, `Rally`, `Charge`,
`Boss`, `Victory`, `Defeat`. Related SwarmState attributes:
- `RunClock`: seconds, server elapsed
- `BeaconPos`: Vector3
- `BeaconCharge`: 0..1
- `RallyLeft`: seconds
- `BossHP` / `BossMaxHP` / `BossName`: set by D

**Per player** (Player attributes, set by the server, read by the UI):
- `HP`, `MaxHP`, `Level`, `XP`, `XPNeeded` (existing)
- `Downed` (bool), `BleedLeft` (seconds), `ReviveProgress` (0..1), `Eliminated` (bool), `Spectating` (bool) (E1)
- `HitProtectUntil` (server time): 0.35 s shared hit protection
- `ReviveProtectUntil`: 1 s after a revive
- `DashReadyAt`, `DashCd` (existing). `ClassKit`, `ClassCharge` (0..1), `ClassReady`, `ClassStored`, `ClassChargeText` (for example "3/5") (C)
- `TeamRunGold` lives on SwarmState (one team balance). `ChestCost` (next chest price, SwarmState) (E2)
- `PendingChoices` (count of queued level and chest choices) (B)

**Builds (B):**
- A weapon instance is `{Id, Rank (1..5), Evolved (bool)}`. A passive is `{Id, Rank (1..5)}`.
- Slots are 4 + 4, with the class signature in weapon slot 1 (protected).
- The offer payload (LevelUpOffer remote) keeps its existing shape and adds per card: `Category` (`WeaponUpgrade` / `PassiveUpgrade` / `NewWeapon` / `NewPassive` / `Evolution` / `Heal`), `Rarity` (`Common` / `Uncommon` / `Rare` / `Epic` / `Evolution`), `RankFrom`, `RankTo`, `Slot`, `Lines` (current -> next text) and `Synergy` (text or nil). It also adds `Deadline` (server time), `RerollsLeft`, `Source` (`Level` / `Chest`) and `OfferId`.
- Server API used by E2:
  - `LevelUpSystem.QueueChoice(rp, source: "Level"|"Chest", kind: "Any"|"PassiveOnly")`
  - `LevelUpSystem.PendingCount(rp)`
  - `LevelUpSystem.CancelAll(rp)`: run end / victory
- Combat API used by C:
  - `WeaponSystem.Damage(rp, enemy, coefficient, weaponId, rank, opts)`, where opts has `{Secondary, Crit=true/false, Proc=bool, CastId, Depth, Knock, Stagger, Status}`. It applies the brief's formula, crit, armor, the status caps and the per-player secondary-emission budget.
  - `WeaponSystem.HasLineOfSight(fromPos, toPos)`
  - `WeaponSystem.NearestTarget(rp, range, opts)`

**XP and economy (E2):** XP shards are personal. `XPSystem.Award(enemyPos, amount, kind)` gives every eligible
player within 120 studs their own shard (8-stud pickup, 30 s expiry). Enemy kinds and their XP: `Normal` 4,
`Tough` 8, `Elite` 20, `Boss` 100 (direct).

**Unlock goals (E2 counts them at settlement into `data.Stats.ClassGoals`; DECISIONS C3):**
- `XP`: cumulative eligible run XP
- `Distance`: legitimate horizontal studs
- `Elites`
- `BestSurvive`: seconds, best single run
- `Chests`: reward chests opened
- `Dashes`: valid dashes
- `MostWeapons`: most different weapons held in one run
- `Kills`
- `CloseKills`: kills by close-range attacks (melee signatures, Sword, dash hits within 10 studs)
- `Bosses`
- `Revives`: teammate revives completed

After the commit, call `ClassOwnership.RefreshEarned(player)` (lobby track; guard with `if` it exists). Its return
goes into `rp.CommitInfo.NewUnlocks` for the results screen.

## Checklist (brief sections -> stream)

- [ ] **A** 8 new class models: coach_crunch, doug_janitor, peter_parkour, barry_plotter, rambozo, swolverine, crash_cassidy, knuckles_mcgee
- [x] **B** rank 1-5 formula, crit, armor, intervals, hit ledgers, LOS targeting (0.15 s re-pick, 0.30 s hold), status caps (scorch, slow 40%, knockback 24, stagger immunity, elite / boss limits), secondary budget 10/s
- [x] **B** 15-weapon catalog, milestones at rank 3 and 5 for all 15, 4 evolutions (level 8+, rank 5 + passive rank 3), 8 loot passives, offers (weights 45/35/12/8, rarity 70/23/6/1, capacity), heal fallback, queue, 10 s deadline (first card on timeout), 1 reroll per panel, 2 free per run (+VIP existing), 1/2/3 keys (milestone behaviour of the 8 newer signatures: data only, stream C; see ../gameplay/BUILDS.md)
- [x] **C** 12 kits exactly as the brief: weapons, passives, movement hooks, HP modifiers, base speed (Granny 20) (../gameplay/CLASSES.md)
- [ ] **D** 15-minute run, beacon at 12:30 (rally 30 s, charge 60 s, r35, one living non-downed hero within 20 to activate), Basin Breaker (HP formula, 3 telegraphed attacks, 50% phase), victory / defeat, overtime ramp
- [ ] **D** N scaling (HP / damage / spawn), time scaling, spawn rate, alive caps 55/95/145/200, roster (beetle, floating eye, root runner from min 2, stump brute from min 4, sap lobber from min 6, elites from min 5 at 5%), spawns 35-70 studs on reachable ground, stuck repath / despawn
- [ ] **E1** downed 20 s, hold-interact revive 3 s within 8, 25% HP, 1 s protection, elimination -> spectate, wipe once, reconnect window 60 s, hit protection 0.35 s, fall damage (>18 studs, 2%/stud, cap 35%), OOB rescue 10% with 3 s lockout, movement accel / decel, air 65%, coyote / buffer 0.10, horizontal cap 34, dash rules (no i-frames, wall stop)
- [ ] **E2** personal XP shards, XP curve, team run gold, chest cost curve, chest = passive choices for the snapshot recipients, class-goal counters, settlement hook, results data (outcome, NewUnlocks, save status)
- [ ] **F** HUD layout (desktop and phone positions from the brief), boss bar and objective stage strip, 4+4 slot rows with ranks, upgrade cards (rarity symbol + text, current -> next), inventory (Tab), north-up minimap with 80-stud reveal shared per team and big map (M), interact (E) prompts for chest / beacon / revive, downed / spectate UI, results (Pending Save -> Saved, new unlocks), Escape run menu "The run continues"
- [ ] **G** class sounds, contact sparks, crit burst, damage text grouping, mild shake (<0.12 s), reduced-motion paths
- [ ] **H** acceptance flows 1-8 offline where possible, perf scenes (4 players, 200 enemies), full regression, report

## Notes from stream A for stream C (models done, uploaded, in MeshCatalog)

- **Mesh names** for the ClassRoster `MeshName` field (ModelBuilder reads it):

  | Class id | MeshName |
  |---|---|
  | coach_crunch | CoachCrunch |
  | doug_janitor | DougJanitor |
  | peter_parkour | PeterParkour |
  | barry_plotter | BarryPlotter |
  | rambozo | Rambozo |
  | swolverine | Swolverine |
  | crash_cassidy | CrashCassidy |
  | knuckles_mcgee | KnucklesMcGee |

- **ClassAnimator:** `CLASS_IDS` / `TUNE` only know the first 4 classes. Add the 8 new ones with these settings:

  | Class | Gear and anchor | Animation tuning |
  |---|---|---|
  | Rambozo | gun welded to the torso, arms posed on it | ArmSwing 0 |
  | Crash | stick on the right arm, blade near the ground | small or zero right-arm swing |
  | Doug | mop on the right arm, soap on the left | small swing |
  | Barry | staff and pots on the right arm | reduced swing |
  | Coach | ball on the right arm | none listed |
  | Peter | spring shoes, long legs | Hop style, bigger Bob |
  | Knuckles | big gloves | ArmSwing ~0.3 |
  | Swolverine | claws on the arms | small swing |

- **Rig:** feet at y=0, HumanoidRootPart at y=3, CanCollide off on the mesh parts (as before).
