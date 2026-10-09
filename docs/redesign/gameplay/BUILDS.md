# SWARM redesign: rank builds and the combat core (stream B)

Brief: `docs/redesign/continuation/Swarm-Complete-Continuation-Prompt.md` ("Baselines and shared combat
rules", "Progression and personal choices", "Twelve approved classes", "Eight original loot passives").
Decisions: `../DECISIONS.md` C6. Shared contract: `../continuation/GAMEPLAY_PLAN.md`.
Offline only, NOT Studio-tested.

## Where things are

| Part | File |
|---|---|
| Numbers (`Builds`, `Combat`) | `src/swarmv2/shared/Run/RunConfig.lua` |
| Pure formulas (rank damage / interval, crit, armor, rarity and category rolls, status caps) | `src/swarmv2/shared/Run/BuildRules.lua` |
| Catalog: `Catalog`, `Signatures`, `Rank` specs + milestones, the four evolutions, the 8 new signature entries | `src/shared/WeaponData.lua` (section "The continuation pack's catalog") |
| Loot passives (`LootOrder`) | `src/shared/PassiveData.lua` |
| Stat sheet (damage bonus, attack speed, crit, `FallDamageMult`, `LandLockReduce`, `SplinterChance`, `ArmorMult`) | `src/shared/StatSheet.lua` |
| Offers, queue, deadlines, rerolls, evolutions, entitlement (`R` section) | `src/server/Modules/LevelUpSystem.lua` |
| Combat core (`Rk` section) and the catalog behaviours (`Fire.Rank*`) | `src/server/Modules/WeaponSystem.lua` |
| Synergies hidden | `src/shared/SynergyData.lua` (`Hidden()`) |
| Tests | `tools/preview/scenes/builds-sim.luau`, `choice-regression.luau` (`--set builds=legacy` = old system) |

`RunConfig.Builds.Enabled = false` switches the whole run back to the old 12-level system (6 + 6 slots,
old weights, every old weapon / passive / synergy). It exists for the old regressions only.

## Baselines (audited)

- **B = 10.** The ordinary starter damage before upgrades: the Knight's Sword level 1 and Ruckus's Scrap
  Toss level 1 both dealt 10 (WeaponData rows); most other starters were 7.5-12.5. Every coefficient is a
  multiple of B (`RunConfig.Builds.B`).
- **H0 = 120** = `Config.Player.BaseMaxHP`, the normal player maximum HP (unchanged). Class HP modifiers
  (0.90 / 1.10 / 1.15 H0 ...) are stream C's `RunConfig.Classes` roster `Bonus.maxHpMult`.

## Rules

- Hit = B x coeff x (1 + 0.20 (r - 1)) x (1 + damage bonus); damage bonus = every `might` (class, account
  upgrades, Pocket Dynamo) clamped 0..2. Interval = base x 0.95^(r - 1) / (1 + attack speed), attack
  speed clamped 0..1, never below 0.25 s. Secondaries use their weapon's rank (`s.mult`).
- Crit 5 % base (a class may set `CritBase`, e.g. Swolverine 0), +Lucky Button, max 50 %, x1.75; rolled
  on the server (`ItemSystem.ModifyHit` for direct hits, `WeaponSystem.Damage` otherwise). Status damage
  never crits; secondaries never crit unless `Crit = true` and never proc.
- Armor A / (100 + A), A clamped 0..100 (`BuildRules.ArmorMult`; enemies: `e.Armor` / `Def.Armor`).
- Hits: projectiles hit a target once (`p.Hits`), bursts and pulses once per target, swings once;
  `WeaponSystem.Damage` keeps a ledger per `CastId`.
- Targeting: the nearest hittable enemy whose body edge is in range, on this level and in sight; ties by
  `Uid`; at most `LOSMaxChecks` sight tests; with a `Key` a target is held 0.30 s and reconsidered every
  0.15 s; small capped lead (0.25 s, 3 studs). The existing boss preference (`Config.Boss.Targeting`) is
  kept when the boss is in sight (an owner rule from before the pack; reported).
- Line of sight: the HeightGrid ground between the two points must stay under a line 2.5 studs above the
  ground at both ends (cliffs, ridges and NavBlock tops block; water and gaps do not). Rank shots stop at
  a cliff rise and ride up ramps. Bursts, swings and rift pulses only hit what they can see.
- Statuses: scorch 0.12 B/s for 3 s in exact 0.5 s ticks, refreshed, strongest source kept; slow =
  strongest only, max 40 % (bosses 10 %); knockback horizontal, max 24 studs/s per target, elites half,
  bosses none; stagger stops movement (`e.StaggerUntil`, EnemyAI), 1.5 s immunity after, elites max
  0.15 s, bosses never.
- Secondaries: a per-player token bucket of 10 per second (`Rk.tryEmit`); bounces, rank extras, final
  bursts, evolution pulses / toasts / small bubbles / fragments and splinters each pay one. Pulses,
  small bubbles, fragments and splinters are terminal (they never emit); `WeaponSystem.CanEmit(rp, parent)`
  refuses a terminal parent or depth >= 2.

## Catalog (15)

Ranks 1-5. Milestones replace spec fields from rank 3 / 5 (`WeaponData.RankSpec`).

| Weapon (id) | Owner | Rank 1 | Rank 3 | Rank 5 | Behaviour now |
|---|---|---|---|---|---|
| Scrap Shot (`ScrapToss`) | ruckus | 0.90 B, 0.90 s, 32 / 70, 1 bounce 0.45 B within 10 | 2 bounces | +1 0.40 B scrap | RankShot (done) |
| Toast Toss (`ToastVolley`) | toastmaster | 0.65 B, 0.85 s, 32 / 65, 1 ricochet 0.35 B | 2 ricochets | radius-3 0.20 B final burst | RankShot (done) |
| Bubble Bomb (`BubbleBomb`) | captain_croak | 0.20 B impact + r6 0.90 B burst, 1.20 s, 28 / 48, fuse 0.8 | burst radius 7 | second bubble at half | RankBubble (done) |
| Yarn Bomb (`YarnBomb`) | granny_boom | 1.25 B, 1.40 s, 35, fuse 1.0, r8, max 8 | fuse 0.85 | radius 10 | RankYarn (done) |
| Dodgeball | coach_crunch | 0.85 B, 1.00 s, 35 / 70, bounce 0.40 B | 2 bounces | second ball at half (data) | placeholder RankShot |
| Mop Sweep | doug_janitor | 0.85 B, 1.15 s, 10-stud arc (110 assumed), max 6, 20 % slow 2 s | 130 degrees | max 8 | RankSwing (done) |
| Returning Sneakers | peter_parkour | out 0.70 B / back 0.35 B, 1.20 s, 28, 2 + 2 targets | 3 out | 3 back (data) | placeholder RankShot (out leg only) |
| Seed Slinger | barry_plotter | 0.25 B seed, 1.80 s, 28; plant 6 s, 0.25 B/s within 20, cap 3 | plants 8 s (data) | cap 4 (data) | placeholder RankShot (seed only) |
| Confetti Minigun | rambozo | 3 x 0.20 B pellets, 0.75 s, 30 | 4 pellets | 5 pellets | placeholder RankShot (pellet count works) |
| Protein Claws | swolverine | 0.65 B, 0.75 s, 14-stud swipe, max 3 | max 4 | every 3rd: r4 0.20 B pulse (data) | placeholder RankSwing |
| Ricochet Puck | crash_cassidy | 0.70 B, 1.00 s, 38, bounce 0.35 B | 2 bounces | 3 bounces | placeholder RankShot (bounces work) |
| Glove Combo | knuckles_mcgee | 0.65 B, 0.65 s, 8 studs; uppercut 1.40 B + r4 0.30 B after 5 | after 4 (data) | after 3 (data) | placeholder RankSwing (no charge) |
| Sword (`Whip`) | everyone | 1.00 B, 0.95 s, 110 degrees, 10 studs, max 6 | 130 degrees | 12 studs | RankSwing (done) |
| Magic Orb (`MagicOrb`) | everyone | orbit r6, 1 turn/s, 0.45 B, 0.75 s per target per orb | 2 orbs | 3 orbs | RankOrb (the Ward Shields orbit; done) |
| Vortex (`Vortex`) | everyone | the existing rift: r7, 3 s, 0.25 B per 0.75 s, max 8, pull 4 | radius 9 | 4 s | RankVortex (done) |

Audit of the legacy three: the old Magic Orb was a homing shot, not an orbit, so the rank Magic Orb runs
on the existing Ward Shields orbit machinery (`Fire.RankOrb`); the old homing orb stays in the 12-level
system. Vortex already existed (densest-crowd rift with pull) and keeps its look and crowd pick; the
numbers are the brief's. The Sword keeps its slash look and auto aim with the brief's geometry.

Evolutions (player level >= 8, weapon rank 5, partner passive rank 3; the first eligible one is always the
first option of a level choice, never from a chest; once):

| Evolution | Weapon + passive | Effect |
|---|---|---|
| Junkyard Cyclone | Scrap Shot + Patchwork Padding | the final bounce emits one r5 0.35 B scrap pulse |
| Toaststorm | Toast Toss + Ratchet Timer | a second 0.35 B toast 0.12 s later |
| Bubble Torrent | Bubble Bomb + Collector's Bell | each primary burst: two 0.25 B small bubbles at separate visible enemies within 8 |
| Knitting Nightmare | Yarn Bomb + Splinter Badge | three radial 0.15 B fragments, each hitting once |

Old recipes stay as data and are never offered. Cross-class signatures: offered / allowed only when the
player owns that class (`ClassOwnership.Owns`, save `OwnedCharacters`, snapshotted per run; Ruckus is free)
and they give the weapon behaviour only (class passive hooks run for the owning class only).

## Loot passives (8, ranks 1-5, n = rank)

Pocket Dynamo +10 % n damage; Ratchet Timer +8 % n attack speed; Trail Sneakers +4 % n move speed;
Patchwork Padding +8 % n max HP (a rise keeps the HP fraction); Collector's Bell +1.5 n studs pickup;
Lucky Button +3 n points crit; Spring Stitch -8 % n fall damage and -0.01 n s landing jump lock
(`Stats.FallDamageMult`, `Stats.LandLockReduce`, player attributes `FallDamageMult` / `LandLockReduce`
for stream E1); Splinter Badge: direct hits 4 % n chance to throw two 0.15 B splinters (secondary).

## Offers and choices

- 4 weapon + 4 passive slots; the class signature is slot 1 at rank 1 (no replace / drop / sell exists).
- An offer: the eligible evolution first, then up to 3 distinct options: category by weight (weapon
  upgrade 45, passive upgrade 35, new weapon 12, new passive 8; empty categories removed, renormalised),
  an item uniform inside it, a rank grant by rarity (Common +1 70, Uncommon +2 23, Rare +3 6, Epic +4 1;
  tiers past the item's capacity removed and renormalised; new items have capacity 5). Nothing left: one
  heal card (10 % max HP, living heroes only). Fewer options are sent as they are (`Empty`, `EmptyText`).
- Choices queue (`rp.ChoiceQueue`) and show one at a time, each with its own deadline; the first
  displayed card is taken on timeout. Team run (more than one hero in the run): `ChoiceSeconds` = 10 s,
  the world and the chooser keep going (no root, no protection, no close grace; `rp.LiveChoice`,
  attribute `ChoiceLive`). Solo is kept as before the pack (the world freezes, `SoloChoiceSeconds` 25 s,
  the pause menu stops the clock): an explicit decision, switchable by setting both seconds equal.
- Downed / eliminated / disconnected: the open choice is suspended with its cards and time left
  (`rp.SuspendedOffer`), picks are refused, the world is not paused; revival resumes the same cards.
- Rerolls: one per choice, `FreeRerolls` (2) per run on top of the existing VIP pass and account Reroll
  upgrade; debited only when the new offer differs; the deadline stays. Skips and Banish work as before.
  A Shrine of Trial bonus pick queues a choice whose offer holds a card above Common; the Clove Bulb
  sigil still removes one card from the run's first offer.
- Payload (LevelUpOffer) adds per card `Category`, `Rarity`, `RankFrom`, `RankTo`, `Slot`, `Lines`,
  `Synergy` (evolution partner text) and per offer `Deadline` (server time), `RerollsLeft`, `Source`,
  `Kind`, `Live`, `Empty`, `EmptyText`; `OfferId` validation is unchanged (the client already sends it,
  keys 1/2/3 already pick). Inventory rows add `Rank`, `MaxRank`, `Damage`, `Interval`, `Slot`,
  `Protected`, `Evolution`, `NextMilestone`.

## API

```
LevelUpSystem.QueueChoice(rp, source: "Level" | "Chest", kind: "Any" | "PassiveOnly")
LevelUpSystem.PendingCount(rp) -> number            (attribute PendingChoices)
LevelUpSystem.CancelAll(rp)                         (run end / victory: drops everything, no new choice)
LevelUpSystem.Entitled(rp, weaponId) -> boolean
WeaponSystem.Damage(rp, enemy, coefficient, weaponId, rank?, opts?) -> (died, dealt)
  opts: Secondary, Status (true = status damage; "Scorch" = apply scorch after the hit), Crit, Proc,
        CastId, Rehit, Depth/Terminal (for CanEmit), From (sight check + knock direction), LOS = false,
        Dir, Knock (studs/s), Stagger (s), Slow (share) + SlowSeconds, Scorch (mult), Mult, Amount,
        NoHarvest. Defaults: a primary hit (crit + procs); rank = the player's rank of weaponId.
WeaponSystem.HasLineOfSight(fromPos, toPos) -> boolean
WeaponSystem.NearestTarget(rp, range, { Key?, From?, Exclude?, PreferBoss? }) -> enemy?
WeaponSystem.CanEmit(rp, parentOpts?) -> boolean   WeaponSystem.NewCast() -> castId
WeaponSystem.ApplyScorch(rp, e, mult?, weapon?)    WeaponSystem.ApplySlow(e, share, seconds)
WeaponSystem.Stagger(e, seconds) -> boolean
```

## Stream C: still to do for the 8 newer signatures and the kits

> Done by stream C (2026-10-09): every item below is implemented, see `CLASSES.md` (behaviours
> `Fire.RankDodgeball / RankSneakers / RankSeed / RankConfetti / RankClaws / RankPuck / RankGlove`).

Each runs a placeholder now (`RANK[id].Behavior`); give it its own `Fire.<Name>` in WeaponSystem, set the
spec's `Behavior`, and use the stored fields: Dodgeball `SecondBall` (r5); Returning Sneakers return leg
(`ReturnCoeff`, `OutTargets` / `ReturnTargets`, one hit per target per leg, terrain ends the leg); Seed
Slinger plants (`Plant*`, cap, oldest replaced, no recursion); Confetti pellets may all hit one target
(`SameTarget`); Protein Claws `ThirdPulse` (r5) and alternating swipes; Glove Combo charge
(`ChargeAfter` 5/4/3, `UppercutCoeff`, `ShockRadius` / `ShockCoeff` / `ShockTargets`, weapon-intrinsic so
any holder gets it); Mop Sweep is complete except its look. Kits: Ruckus's barrage (3 x 0.60 B), cans
(0.40 B, r5, 0.9 s), Big Splash (+30 % burst, 6 s expiry: `TakeSplash` returns `DamageMult` /
`RadiusMult`, applied to the burst), Overheat -> `WeaponSystem.ApplyScorch` (3 hits in 5 s), Tangled Up
-> `WeaponSystem.ApplySlow` (boss cap 10 %), class HP / speed / crit (`CritBase`) in the roster.

## Small edits in other streams' files (marked `[stream B]`)

- `EnemySpawner.Damage`: 7th parameter `critIn` (a crit already rolled / never crit), 3 lines.
- `EnemyAI`: `e.StaggerUntil` stops movement, 3 lines.
- `RunManager.RefreshFrozen`: a live team-run choice (`rp.LiveChoice`) never counts as a freezing choice.

## Notes for the other streams

- E1: player armor should use `BuildRules.ArmorMult(A)` (A/(100+A)) in `DamagePlayer` (today it is flat);
  `rp.Downed = true` is honoured as downed by the choice code; Spring Stitch values above.
- E2: chests call `QueueChoice(rp, "Chest", "PassiveOnly")`; the old `OpenChest` no longer evolves.
- F: live choices (`Live`, `ChoiceLive`) must not take Space (jump) as a card confirm; show `Rarity`
  (Uncommon / Evolution are new names), `EmptyText`, ranks from the inventory; the BUILD panel's
  `EvolutionPreview` text still says "Lv 12".
- D: enemies may set `Armor`; the Basin Breaker is a boss (no knockback / stagger, slows max 10 %).
