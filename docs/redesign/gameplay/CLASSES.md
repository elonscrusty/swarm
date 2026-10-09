# SWARM redesign: the twelve class kits (stream C)

Brief: `docs/redesign/continuation/Swarm-Complete-Continuation-Prompt.md` ("Twelve approved classes",
"Eight original loot passives and status limits", "Movement, camera and terrain", feel section).
Decisions: `../DECISIONS.md` C1-C3. Combat core and ranks: `BUILDS.md` (stream B). Offline only,
NOT Studio-tested.

## Where things are

| Part | File |
|---|---|
| Every kit / roster number (`Classes` section) and the dash variants (`Dash.Variants`) | `src/swarmv2/shared/Run/RunConfig.lua` |
| Roster: CharacterData entries, mesh names, texts, goals, ultimates, second skills, mastery signatures | `src/swarmv2/shared/Run/ClassRoster.lua` (registered by `src/swarmv2/server/Run/ClassRegistry.lua`) |
| Passives, movement hooks, HUD counters | `src/swarmv2/server/Run/ClassKits.lua` |
| Signature behaviours (`Fire.Rank*`) and kit helpers (`KitBurst`, `KitQuery`, `KitCan`, `KitBalloon`, `KitPlant`, `KitPlants`, `KitDamageFactor`, `GloveCharge`, `KitFx`) | `src/server/Modules/WeaponSystem.lua` (section "[stream C] CLASS KITS") |
| Rank specs and milestones (behaviour names) | `src/shared/WeaponData.lua` (`RANK`) |
| Charged jump (Peter), spring apex (Toastmaster) | `src/client/JumpController.lua` (`JumpPower`, through `SurvivalRules.JumpVelocity`) |
| Animation tuning (12 classes) / HUD chip | `src/swarmv2/client/Run/ClassAnimator.lua` / `ClassHud.lua` |
| Test | `tools/preview/scenes/class-kits-sim.luau` (exact numbers per class), `cliffwood-run-sim.luau` (12 classes on the real map) |

## Roster

H0 = 120 (`Config.Player.BaseMaxHP`), base walk 22, base crit 5 %. B = 10.

| Class (id) | Model | HP | Walk | Crit | Access | Signature |
|---|---|---|---|---|---|---|
| Ruckus (`ruckus`) | Ruckus | 1.00 | 22 | 5 % | free | Scrap Shot (`ScrapToss`) |
| Toastmaster (`toastmaster`) | Toastmaster | 0.90 | 22 | 5 % | 10,000 gold or 300 run XP | Toast Toss (`ToastVolley`) |
| Captain Croak (`captain_croak`) | CaptainCroak | 1.00 | 22 | 5 % | 20,000 gold or 3,000 studs | Bubble Bomb |
| Granny Boom (`granny_boom`) | GrannyBoom | 1.10 | 20 | 5 % | 30,000 gold or 3 elites | Yarn Bomb |
| Coach Crunch (`coach_crunch`) | CoachCrunch | 1.00 | 22 | 5 % | survive 3 min in a run | Dodgeball |
| Doug the Janitor (`doug_janitor`) | DougJanitor | 1.10 | 22 | 5 % | open 5 chests | Mop Sweep |
| Peter Parkour (`peter_parkour`) | PeterParkour | 0.95 | 22 | 5 % | 30 dashes | Returning Sneakers |
| Barry Plotter (`barry_plotter`) | BarryPlotter | 1.00 | 22 | 5 % | 3 weapons in one run | Seed Slinger |
| Rambozo (`rambozo`) | Rambozo | 1.00 | 22 | 5 % | 300 kills | Confetti Minigun |
| Swolverine (`swolverine`) | Swolverine | 1.15 | 22 | 0 % | 100 close-range kills | Protein Claws |
| Crash Cassidy (`crash_cassidy`) | CrashCassidy | 0.90 | 22 | 5 % | 10,000 studs | Ricochet Puck |
| Knuckles McGee (`knuckles_mcgee`) | KnucklesMcGee | 1.00 | 22 | 5 % | a boss OR a revive | Glove Combo |

- Goals are `Goal = { Stat, Need, Text }` (Knuckles adds `Any = { {Bosses, 1}, {Revives, 1} }`) on the
  CharacterData entry, copied from `RunConfig.Classes.Roster` (the lobby's `ClassCatalog` had no goal table
  yet; same field name and shape, DECISIONS C3). The 8 goal-only classes carry `Unlock = { Goal = ... }`
  and `Cost = 0`: the old gold buy path (`GoldSystem` BuyCharacter) refuses any entry with `Unlock`, so
  they have no gold price. The first four keep their prices and also have their goal (C2).
- The old innate class bonuses of the first four (+25 % pickup, +10 % HP, +10 % XP, +10 % area) are gone:
  the brief defines each class completely and gives Toastmaster 0.90 H0. The Hero Mastery signature
  upgrade stays as optional account progression (5 levels, `Base 0`, e.g. "+4% pickup radius per level").
- Ultimates and second skills: the first four keep theirs; the 8 newer classes reuse the existing generic
  effects (Quake / Stars / Blades / Nova / Fire / Sparks and simple stat second skills) with their own
  names (`ClassRoster`). No new ultimate mechanics.

## Signature weapons (rank formula, BUILDS.md; numbers at rank 1)

| Weapon | Behaviour | Rank 3 / rank 5 |
|---|---|---|
| Scrap Shot | 0.90 B, bounce 0.45 B to a different not-yet-hit visible target within 10 | 2 bounces / +1 scrap 0.40 B (secondary) |
| Toast Toss | 0.65 B, ricochet 0.35 B (same rule) | 2 ricochets / r3 0.20 B final burst |
| Bubble Bomb | 0.20 B direct impact + r6 0.90 B burst after one ground bounce or the 0.80 s fuse | r7 / half-damage second bubble |
| Yarn Bomb | 1.25 B, 1.0 s fuse, r8, max 8 targets, terrain blocks exposure | fuse 0.85 / r10 |
| Dodgeball (`RankDodgeball`) | 0.85 B, bounce 0.40 B (same rule, 10 studs at every rank) | 2 bounces / a second ball 0.3 s later at half damage (secondary: no bounce) |
| Mop Sweep (`RankSwing`) | 0.85 B, 10-stud arc 110 degrees (assumed), max 6, 20 % slow 2 s | 130 degrees / max 8 |
| Returning Sneakers (`RankSneakers`) | out 0.70 B (primary) to 2 targets, back 0.35 B (secondary) to 2, one hit per target per leg; a cliff ends the blocked leg (out: turns back; back: gone) | 3 out / 3 back |
| Seed Slinger (`RankSeed`) | 0.25 B seed; a stationary plant on walkable ground, 6 s, 0.25 B per second at the nearest visible enemy within 20 (a seed pellet, secondary), cap 3 (the oldest replaced), plants never plant | 8 s / cap 4 |
| Confetti Minigun (`RankConfetti`) | 3 pellets 0.20 B in a fixed 4-degree fan: all can hit one target up close, the outer ones miss far small targets | 4 / 5 pellets |
| Protein Claws (`RankClaws`) | alternating 14-stud forward swipes (no lunge), 0.65 B, max 3 | max 4 / every 3rd swipe a r4 0.20 B pulse (secondary) |
| Ricochet Puck (`RankPuck`) | 0.70 B, bounce 0.35 B (same rule) | 2 / 3 bounces |
| Glove Combo (`RankGlove`) | punches 0.65 B at the nearest target within 8; 5 landed punches charge the WEAPON (`w.Charge`, any holder); the next punch is a 1.40 B uppercut + r4 0.30 B shockwave on up to 3 others (secondary) | after 4 / after 3 |

Evolutions (stream B): Junkyard Cyclone, Toaststorm, Bubble Torrent, Knitting Nightmare; checked to still
evolve and deal damage. The 8 newer signatures have no evolution (the brief names none).

## Passives and movement hooks

Kit damage uses the class signature's rank and is secondary (no crit, no procs). Cooldowns ignore attack
speed. Every hook checks the run hero (`rp.CharacterId`): a cross-class signature brings its weapon only.

| Class | Passive | Movement |
|---|---|---|
| Ruckus | Junk Collector: 5 chest / item rewards (a chest = LootSystem's chest choice, stream E2; items = `ItemSystem.Grant` reward; never XP shards; rewards while full do not count) store 1 charge: the next Scrap Shot is 3 scraps of 0.60 B, each at another visible target, with the weapon's bounces. HUD "0/5" .. "Ready" | dash: 2 rolling cans, 0.40 B r5 after 0.90 s, one cast ledger per dash (one can hit per target) |
| Toastmaster | Overheat: 3 direct toast hits (ricochets / follow-ups do not count) on one target within 5 s = scorch (0.12 B/s, 3 s, refresh) and that target's counter resets. HUD "2/3", "Scorch!" | spring jump apex 12 (client); a landing after an intentional jump (the server saw the root rise above 30 studs/s; stairs, slopes, falls, launch pads, rescues never count), >= 0.35 s airtime: r6 0.35 B blast, 2 s cooldown |
| Captain Croak | Big Splash: a leap landing (once per leap) within 10 of a living enemy stores 1 empowered bubble: +30 % burst, expires after 6 s. HUD "Ready" | leap replaces dash: 30 studs over ~0.45 s (apex 5), cooldown 3 |
| Granny Boom | Tangled Up: yarn damage = 35 % slow for 0.75 s (refresh only, strongest slow kept, bosses capped at 10 %). HUD: enemies tangled now | rocket boost replaces dash: 80 studs/s, 0.25 s, cooldown 3 (no fire trail: the brief has none) |
| Coach Crunch | Warm-Up: 2 s continuously above 18 studs/s (server-measured) charges it. HUD "%" / "Ready" | shoulder-tackle dash: enemies touched take 0.60 B charged / 0.30 B uncharged, once each, at most 4, 0.25 s stagger (immunity rules; elites 0.15, bosses damage only); the dash spends the charge |
| Doug | Clean Route: +4 studs pickup (`pickupFlat`, the player's own pickup stat; shards are personal) | dash: a 16-stud wet trail along the dash path for 2 s, 25 % slow, no damage |
| Peter Parkour | Stride: 2 s above 20 studs/s charges it; the next Returning Sneakers throw +30 % (added to the damage bonus inside the 0..2 clamp), expires 6 s after charging | charged jump: apex 11 once per 6 s (client), no double jump, no speed |
| Barry Plotter | Garden Company: his own plants +15 % while he is within 12 studs of the plant | dash: an extra plant at the dash origin, 6 s cooldown, shares the cap |
| Rambozo | Punchline: +10 crit points (cap 50 %) on direct hits against enemies above 70 % HP (`rp.KitCritHigh`, the server's crit roll) | dash: a balloon grenade at the origin: 0.80 s, r6 0.40 B, then 2 mini-pops 0.15 B r3 (each pays a budget token, each target at most one, they never explode again) |
| Swolverine | Gains: 1 % max HP per 10 credited kills (`rp.Kills`), at most one heal per second (extra heals wait, max 5), living heroes only. HUD "7/10" | dash recovery: +15 % damage for 2 s after a dash ends (refreshed, never stacked) |
| Crash Cassidy | Momentum: +0..15 % damage as horizontal speed (server-measured) rises 12 -> 30 studs/s. HUD "+8%" | body-check dash (cooldown 2.20): 0.35 B once to each of at most 4 enemies touched, knockback 20 (normal; elites half, bosses none) |
| Knuckles McGee | Heavy Hands: x1.25 knockback on normal enemies inside the shared cap (`rp.KitKnockMult`). HUD: Glove charge "3/5" / "Ready" | close dodge: a dash ending within 6 studs of an enemy adds 1 Glove Combo charge, once per dash |

Damage bonuses (Momentum, dash recovery) patch the stat sheet's additive `DamageBonus` (clamped 0..2 with
everything else) and `Might`; a recomputed sheet is noticed and patched again on the next step.

HUD (player attributes, server-set): `ClassKit` (the passive id: `JunkCollector`, `Overheat`, `BigSplash`,
`TangledUp`, `WarmUp`, `CleanRoute`, `Stride`, `GardenCompany`, `Punchline`, `Gains`, `Momentum`,
`HeavyHands`), `ClassCharge` 0..1, `ClassReady`, `ClassStored`, `ClassChargeText`; published at 10 Hz.

CloseKills (stream E2): Mop Sweep, Protein Claws and Glove Combo carry `Melee = true`; dash effects (cans,
tackle, body-check, balloon) are credited to a kill source `{ Id, Dash = true }`, the landing blast to
`{ Id, Close = true }` (`WeaponSystem.KitBurst`).

## Rules kept

- Secondaries: bounces, the second ball, plant shots, claw pulses, shockwaves and mini-pops each pay one
  token of the per-player budget (10/s) and never emit anything themselves (plants never plant, mini-pops
  never pop, small effects are terminal). Dash / landing blasts are bounded by their cooldowns.
- Targeting: every behaviour uses `WeaponSystem.NearestTarget` (nearest visible, ties by Uid, 0.15 s
  re-pick, 0.30 s hold) or `Rk.pick`; blasts check line of sight per target (`KitBurst`).
- Status caps: slows through `ApplySlow` (strongest only, 40 %, bosses 10 %), staggers through `Stagger`,
  knockback through the shared cap.
- Speed: no kit moves the hero faster than 34 outside a `Dash.lua` dash / leap (the boost and leap are
  dash variants), so no `RunManager.SetSpeedBoost` is needed.
