# Balance and economy audit (master prompt section 6, AUDIT phase)

Owner: ECON-AUDIT. Date 2026-10-04. Status: **audit only, no balance values changed.**
Issue IDs: EC-01 to EC-15, GI-02 (docs/overhaul/ISSUE_REGISTER.md).

What this is: a read of the live formulas and config, a reconciliation of the recorded
examples, and numbers from reproducible offline cohorts (real server modules on the Lune mock,
headless). What it is not: Studio, device or live multiplayer evidence. Every simulated number
below comes from a scripted bot (see "Method and limits"); it is a controlled baseline, not a
measure of real players.

Code baseline for the cohorts: commit `07578bf` (after the CORNER fix `c5ad391`), copied to a
scratch snapshot so concurrent edits could not change a run halfway. A first batch on the
pre-fix commit `83be6c9` gave the same picture (kept in scratch, not used for the tables).
No balance key changed between the two commits (`git diff 83be6c9 07578bf -- src/shared/Config.lua`
touches no economy, XP, stage or enemy key).

## 1. Gold: every source, as coded

All in-run gold goes through `GoldSystem.AddRunGold(rp, base)`:
`paid = floor(base x PublishGoldMult(player) x RunModifiers.GoldMult() + 0.5)`.
`PublishGoldMult` = gamepasses (Starter Pack x1.25, Double Gold x2; both = x2.5).
`RunModifiers.GoldMult` = curses (sum of each curse's Gold, e.g. +0.15 to +0.30) x difficulty tier
(Standard 1, Veteran 1.35, Nightmare 1.75). Some sources first multiply `base` by the hero's
in-run `Stats.GoldMult` (= 1 + goldGain: Gilded Purse passive +15/30/50 %, Bargain Shrine +30 %).

| Source | Formula (base before pass/curse) | x Stats.GoldMult? | Code |
|---|---|---|---|
| Normal kill | chance `KillGoldChance` 0.25 (x `Waves.GoldChanceMult` 1.5 for wave members = 0.375), then 1-3 | yes | `GoldSystem.OnKill`, `EnemySpawner.Kill` |
| Elite chest (free, dropped by an elite) | (15-40 + `Gold.Elite` 15) x (1 + 0.25 x (stage-1)); avg 42.5 at S1, 85 at S5 | yes | `LevelUpSystem.OpenChest` |
| Stage boss | 200 to every living player | yes | `StageManager.OnBossKilled` |
| Nest destroyed | `Reward.Gold + GoldPerStage x (stage-1)` to every living player | yes | `EnemySpawner.Kill` |
| Lost Caravan saved | caravan gold | yes | `CaravanEvent` |
| Return through the portal | `WinBonus` 100 + `StageClearBonus` 300 x stages cleared | no | `RunManager.finishPlayer` |
| Level-up when the build is full | `FallbackGold` 25 x min(3, 1 + 0.1 x minutes since last down) per level | no | `LevelUpSystem.convertMaxedLevels` |
| Gold card / skip | 25 / `SkipGold` 10 | no | `LevelUpSystem` |
| Survival gold (lobby only) | 40 x whole minutes (max 30), x pass multiplier, paid at settlement straight to the save, never at risk | no | `GoldSystem.SurvivalGold` |
| Achievements / first-run bonus (lobby only) | one-time rewards (100-400) / 200 | no | `AchievementService`, `RunManager.saveRunStats` |
| Floor pickups | none pay gold (chicken heal, magnet, bomb) | - | `Config.Drops` |

No passive income during a run. Guarded Altar, rune stones and the treasure cache pay items,
not gold.

**Server authority.** Prices, spending and payouts are all server side. The client only sends ids
(`LootHold`, `PortalChoice`, `BuyHeroUpgrade` with the level it saw). Run gold lives in a saved
escrow ledger (`data.RunEscrow`); only that ledger can pay for chests and shrines
(`GoldSystem.RunWallet`), so lobby savings and bought coins can never be spent or lost in a run.
A crashed server's ledger is settled once on the next profile load (`RecoverEscrow`, same rate as
a defeat).

## 2. Chests, shrines and the purchase rules

- **Per stage** (`LootSystem.BuildStage`, `Config.Chests`): Small 10-14, Large 2-3, Golden 1 (all
  paid), Shrine of Chance 1-2, Bargain Shrine 1, plus 1-2 encounters drawn from Guarded Altar /
  Lost Caravan / Rune stones / Treasure cache (all free). Chests that fail to find a legal spot
  are skipped. Nothing respawns during a stage; no purchase-count rule, no per-player limit.
- **Price** = `StagePrice(base, stage, 1.2)` = `floor(base x stage^1.2 + 0.5)`, fixed when the stage
  is built; then `PlayerPrice` = `max(1, floor(price x GoldMult + 0.5))` at open time, where
  GoldMult is the pass multiplier the client was shown (`GoldSystem.PriceMult`). Bases: Small 25,
  Large 60, Golden 150, Chance 15 (Chance grows x1.2 per try, max 2 items / 6 tries, 50 % success).
- Because passes multiply income and price alike, a pass buys **no extra items** in a run (it only
  raises the lobby payout). Curses, difficulty tiers, Gilded Purse and the Bargain multiply income
  but **not** price, so they do raise in-run purchasing power.

Price table (base, then with both gold passes x2.5):

| Stage | Small | Large | Golden | Chance (1st try) |
|---|---|---|---|---|
| 1 | 25 / **63** | 60 / **150** | 150 / **375** | 15 / 38 |
| 2 | 57 / **143** | 138 / **345** | 345 / **863** | 34 / 85 |
| 3 | 93 / **233** | 224 / **560** | 561 / 1403 | 56 / 140 |
| 4 | 132 / 330 | 317 / 793 | 792 / 1980 | 79 / 198 |
| 5 | 172 / 430 | 414 / 1035 | 1035 / 2588 | 103 / 258 |

Every price in the recordings (bold) is reproduced exactly with GoldMult 2.5, i.e. **the recorded
account owns both gold passes** (EC-01 PASS, explained).

- **Rarity tables** (`Config.Chests.Weights`): Small 80/19/1, Large 0/80/20, Golden 0/0/100,
  Guarded 0/75/25, Chance 55/38/7 (common/uncommon/legendary). Luck multiplies the uncommon and
  legendary weights by (1 + luck, max 2) (`ItemData.RollRarity`). Item inside a rarity: uniform.
  **Disclosure gap:** the prompt's odds (`chestBenefit`) are the base weights; with luck > 0 the
  real odds are better than shown (Small at luck 0.4: 74 % / 25 % / 1.3 %). In the player's favour,
  but not exact. Fix belongs to LootUI/LootSystem text (FOR OTHERS).
- **Stacking** (`ItemData`): every item stacks with no cap except Phoenix Feather (max 2; an extra
  copy re-rolls inside its rarity). Linear items add to the same additive pools as passives and
  meta upgrades (see section 5). Iron Plate, Herb and Storm Charm are hyperbolic. Crown of Ages:
  linear, unlimited, +12 % damage +8 % attack speed +8 % move speed +10 % max HP per copy (EC-09).

## 3. Retention, settlement and the recorded examples

`SettleRun`: extraction keeps 100 % of the **unspent** ledger; a defeat keeps
`min(0.85, 0.35 + 0.15 x stages cleared)` (rounded to whole percent), and the kept amount is
`floor(unspent x rate)`. Survival gold is added on top and is never cut.

**Short example (EC-02, EC-03): reconciled.** Results "505 gold earned" is the ledger at
settlement, which is the **unspent** balance after purchases (the 63-gold Small Chest was already
taken out), not gross income. Gross was at least 505 + 63 = 568. 0 stages cleared -> 35 %:
`floor(505 x 0.35) = floor(176.75) = 176` kept, 329 lost, lobby 16,743 -> 16,919 (+176). Exact.
The lobby gained no survival gold although 1:49 was survived: survival gold
(`SurvivalPerMinute` 40) arrived in commit 319a5db, after the recording; today the same run would
also pay `floor(40 x 1 min x 2.5) = 100`. Copy issue: "gold earned" should read "unspent run gold"
or show gross separately (FOR OTHERS, results copy).

**+1,000 return offer (EC-12): reconciled, but the recording predates the current values.**
The offer shows `(WinBonus + StageClearBonus x cleared) x pass x curse` (`StageManager.sendOffer`)
and the same base is paid by `finishPlayer` through `AddRunGold` (same multipliers, so shown =
paid). At the recording, StageClearBonus was 150: (100 + 150 x 2) x 2.5 = 1,000. With today's 300
the same screen would offer (100 + 600) x 2.5 = **1,750**. The player chose NEXT, so nothing was
paid; the bonus is paid only on a portal return. The Bargain's +30 % does not apply to it (correct:
the offer does not claim it). Sim check (H_pass cohort below) reproduces payout = offer.

## 4. Method and limits of the cohorts

Scene: `econ-sim.luau` (scratch, not in the tree: `scratchpad/econ/repo2/tools/preview/scenes/econ-sim.luau`,
summariser `scratchpad/econ/summarize.py`). It boots the real server and plays a 5-stage
Standard Forest run: explore 150 s per stage walking a 24-stud circle round the arena centre,
charge the portal, fight the boss up close (force-killed after 90 s, marked F), take NEXT STAGE,
and after stage 5 RETURN (extraction). Cards are the server's random auto-pick (a low-skill
picker). The EnemyAI steering sees the real colliders (the ray caster from
`corner-regression`). Logged per stage: gold by source (caller of `AddRunGold`), spend, wallet,
chests available/bought, stat sheet, time-to-kill from first hit, damage taken, healing by source
(caller of `RunManager.Heal`), "would-be" damage and would-be deaths.

- **Life modes.** `undying`: real damage; a hit that would kill is logged as a *would-be death* and
  HP refills (so every run reaches stage 5 and pressure stays measurable). `mortal`: real deaths.
- **Shopping.** `greedy`: every 2 s, teleport to the best affordable paid chest (Golden > Large >
  Small) and hold it. No walking time, so this is the **upper bound** of purchasing. `none`: never
  buys. Shrines of Chance are not used by the bot.
- **Profiles.** `fresh`: no upgrades. `est` (established): Knight MaxHP 10, Might 10, Armor 4,
  Speed 3, Luck 4, Growth 5, Signature 3, Revive/Reroll/Skip 1 (about 79,000 lobby gold of
  upgrades, roughly 15-20 successful runs at today's payout).
- **Positions.** circle (default); `open` and `corner` stand still at the field centre or the
  south-east corner (the recorded pocket) while exploring.
- Seeds 1-3 (`--seed`): same seed = same map, loot layout and rolls.
- Limits: one map (Forest start, biome tour after), one bot skill, random cards, no dodging, no
  real latency, no Shrine of Chance, Duo = two bots where only player 1 shops. Lune is not Roblox.
  Pressure numbers are comparative, not what a skilled player feels.

Cohorts run on `07578bf` (post CORNER fix). Sample sizes: A fresh/greedy n=3, B fresh/no-shop
n=1 (+2 pre-fix), C est/greedy n=1 (+3 pre-fix), D est/greedy/Bargain n=1, E mortal fresh n=1 and
est n=1, F Duo n=1, G Mage n=1, H both passes (2 stages) n=1, K corner/open (2 stages) n=1 each
plus a pre-fix corner run. 18 post-fix runs, 9 pre-fix runs. **Small n: treat single runs as
examples, cohort A as the baseline.**

## 5. Results

### 5.1 Baseline (A: fresh Knight, buys everything it can; mean of 3 seeds)

| Stage | Time | Level end | Kills | Gold earned (/min) | Spent | Wallet avg | Might | Cooldown | Normal TTK | Elite TTK | Boss TTK | Dmg taken /min | Heal /min | Would-be deaths | Min HP |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 Forest | 261 s | 15 | 323 | 605 (139) | 523 | 16 | 1.11 | 0.87 | 1.0 s | 5.6 s | 67 s | 92 | 52 | 1.3 | 3 % |
| 2 | 218 s | 25 | 599 | 1241 (344) | 987 | 49 | 1.37 | 0.80 | 1.5 s | 4.6 s | 34 s | 95 | 101 | 0.3 | 45 % |
| 3 | 205 s | 38 | 1026 | 2211 (651) | 1733 | 97 | 1.59 | 0.71 | 1.4 s | 6.2 s | 23 s | 56 | 57 | 0 | 62 % |
| 4 | 197 s | 54 | 1503 | 3593 (1111) | 2896 | 136 | 1.89 | 0.61 | 1.5 s | 6.6 s | 15 s | 44 | 57 | 0 | 74 % |
| 5 | 174 s | 66 | 2152 | 5786 (1999*) | 4260 | 552 | 2.30 | 0.59 | 1.3 s | 5.8 s | 11 s | 28 | 47 | 0 | 92 % |

\* stage 5 includes the 1,600 return bonus; without it about 1,450/min.

Run totals (3 seeds): gross 11,759 / 16,471 / 12,077; spent 9,971 / 11,543 / 9,683 (73-80 %);
unspent at extraction 1,788-4,928; lobby +4,238 / +7,458 / +4,884 (incl. survival 600-680 and
first-time achievement gold). Time to first purchase 0:24 / 1:00 / 0:42 (a 25-gold Small Chest).
Chests bought 93-95 % of all paid chests offered (67-75 items per run). At purchase the price was a
median 17-21 % of the previous 60 s of income and 80-90 % of the wallet (the bot buys as soon as it
can, so the wallet stays near zero until stage 5).

**Gold by source (A, 3 seeds, whole run):** kills 33-38 %, elite chests 30-35 %, return bonus
10-14 %, boss 8-11 %, full-build level coins 7-12 %, nests 2 %. Elite chests are as large as kill
gold: their value scales with the stage *and* elites get more frequent in later waves.

**Income vs price:** income per minute grows about 10x from stage 1 to stage 5 (139 -> ~1,450
excluding the return bonus); chest prices grow 6.9x (stage^1.2). Price of a Small Chest relative to
a minute of income: 0.18 (S1), 0.17 (S2), 0.14 (S3), 0.12 (S4), 0.12 (S5). Purchasing power
therefore *rises* through the run, and the number of chests (not gold) becomes the limit from
about stage 3. This matches the recording's late "bursty" shopping (EC-04).

### 5.2 Where the pressure goes (EC-06)

Across every cohort the pattern is the same: **danger peaks on stage 1-2 and falls away from
stage 3**.

| Cohort | Would-be deaths S1 / S2 / S3 / S4 / S5 | Min HP S3-S5 | Boss TTK S1 -> S5 |
|---|---|---|---|
| A fresh, greedy (n=3) | 4 / 1 / 0 / 0 / 0 (total) | 48-96 % | 64-70 s -> 6-18 s |
| C est, greedy | 0 / 0 / 0 / 0 / 0 | 75-97 % | 44 s -> 16 s |
| B fresh, **never buys** | 5 / 7 / 2 / 1 / 0 | 0-25 % | 69 s -> 50 s |
| F Duo (player 1) | 3 / 2 / 1 / 1 / 0 | 6-89 % | force-kill -> 12 s |
| G Mage fresh | 3 / 0 / 0 / 0 / 0 | 65-82 % | 68 s -> 22 s |
| E mortal (fresh s1, est s1) | both survived all 5 stages | | |

Enemy side, from the code: normal enemy HP = def x (1 + 0.12 x minute, **capped at minute 12**,
`Difficulty.MaxTier`) x (1 + 0.35 x (stage-1)) x (1 + 0.25 per extra player) x wave (1 + 0.01 x
(wave-1)); damage x (1 + 0.045 x minute, same cap) x (1 + 0.08 x (stage-1)). With the sim's
timing that is HP x1.24 / 2.3 / 3.7 / 5.0 / 5.9 and damage x1.09 / 1.37 / 1.68 / 1.91 / 2.03 for
stages 1-5. The minute cap is reached during stage 3-4, after which only the stage term grows.
Boss HP = 9000 x boss mult x {0.22, 0.4, 0.7, 1.05, 1.5}: x6.8 from stage 1 to 5, while boss TTK
falls x4-10. Player power multiplies: Might +100-230 % (all additive), cooldown x0.4-0.7, 6
weapons at max rank by about level 50-58, 60-75 run items, crit, procs. The level curve
(`Config.XP`) is cheap after level 20 (+6 XP per level), so stage 4-5 give 12-17 levels each and
the build is full by stage 4; later levels pay coins.

**Paid items are the largest single swing.** Same bot, same seeds, no purchases (B): would-be
deaths 5 / 7 / 2 / 1 / 0 by stage on the post-fix run and 6-22 per stage on stages 2-5 in the two
pre-fix runs, Min HP 0-6 % on stages 1-4; with purchases (A): none after stage 2. The difference is mostly sustain and defence from items (Bandage regen,
Herb, Iron Plate, Hearty Bread, Crown of Ages), not damage: normal TTK is similar (B 0.6-2.5 s vs
A 1.0-1.5 s). The heal-by-source logs show regen (Bandage Roll + passives) and Healing Herb doing
60-95 % of all healing.

**Flat armor is the established profile's main defence.** `RunManager.DamagePlayer`:
`max(1, amount x DamageTaken - Armor)`, i.e. percentage first, then the flat Armor. Common contact
hits are small (Mite 5, Wasp 4, Skeleton 8; x1.4-2.0 by stage 2-5), so Armor 4 (meta) removes most
of a Mite's hit on stage 2 (5 x 1.37 x 0.84 - 4 = 1.8 instead of 5.8) and about half on stage 5
(4.5 instead of 8.5); Armor 8 (meta max) holds it at or near the 1-damage floor all run. Cohort C (Armor 4, DamageTaken 0.84) took 15-116 HP/min against 28-95 for
fresh A and never came close to dying.

**Stage transitions (EC-08).** Code: living players are healed *up to at least* 60 % of max HP
(`Stages.TravelHealFraction` 0.6), fallen teammates stand up at 50 %; not a full heal. The
recording's 111 -> 168 (66 % -> 100 %) is not the travel heal (already above 60 %). Suspected, not
verified: regen / totem / herb keep ticking during the Open phase (up to 15 s of choice with the
surge cleared; the world is still simulated), which a 4-Bandage build covers easily.

**Boss danger (EC-07).** Stage-2 bosses still hurt fresh builds (A: Min HP during stage 2 as low as
6-65 %), consistent with the Moth Matriarch taking the recorded hero to 74/168. From stage 3 on the
bosses die in 6-33 s and rarely threaten.

### 5.3 Sustain vs incoming at the corner (GI-02, CORNER follow-up)

Same seed, fresh Knight, buying chests, standing still for the 150 s explore phases:

| Run | Spot | Dmg taken /min S1 / S2 | Heal /min S1 / S2 | Would-be deaths S1 / S2 | Min HP | Level at end of S2 |
|---|---|---|---|---|---|---|
| PRE fix (`83be6c9` + same ray caster) | SE corner | 80 / 137 | 80 / 144 | 0 / 0 | 59-70 % | 24 |
| post fix (`07578bf`) | SE corner | **244 / 461** | 127 / 308 | **4 / 4** | 1-4 % | 35 |
| post fix | open field, standing | 150 / 242 | 96 / 175 | 2 / 2 | 3-9 % | 24 |
| post fix, **established** | SE corner | 10 / 26 | 14 / 39 | 0 / 0 | 88-89 % | 33 |

Before the fix, incoming damage in the corner equalled the healing (80 vs 80, 137 vs 144): the
pocket let only a trickle through and regen (300-340 HP per stage) plus Herb cancelled it, which is
the recording's 145 -> 154 recovery. After the fix the corner takes 3x the damage, more than the
open field, and healing covers only 52-67 % of it: **for a fresh build sustain does not hold a
reachable corner**, so no sustain nerf is needed for the corner. Healing sources measured: regen
(Bandage Roll and passives) 65-95 %, Healing Herb most of the rest, chicken and Healing Totem
small. No lifesteal except the evolved Whip.

Remaining risk: an **established armoured** Knight standing still in the corner still takes only
10-26 HP/min, because flat Armor 4 cancels most small contact hits (section 5.2). That is
defence, not a reach bug, and it applies anywhere, not just in corners.

### 5.4 Bargain Shrine (EC-05)

Code: `useBargain` adds `might +0.25` and `goldGain +0.30` to the **same additive pools** as
passives, items, meta and the hero (`StatSheet.Compute`), and multiplies the HP of every enemy and
boss that spawns afterwards this stage by 1.2 (`EnemySpawner.Spawn`, after stage/wave/elite
scaling, before the per-wave HP step). Party: team-wide benefit, global enemy HP. Procs: Storm
Charm and burn scale with the hit, so with Might; Volatile Spore's burst is a share of the dead
enemy's max HP, so it grows with the +20 % (neutral); thorns (Barbed Mail) does not scale with
Might, so it is 20 % slower. Gold: +30 % on kills, elite chests, bosses, nests and the caravan, not
on the return bonus, full-build coins or survival gold. Kill-gold rounding (1-3 x 1.3, rounded)
gives +33 % on average, not +30 %.

Theoretical time-to-kill ratio = 1.2 x M / (M + 0.25), where M is the build's total Might:

| M before the shrine | 1.0 (fresh, stage 1) | 1.4 | 1.9 (est, stage 1) | 2.3 | 3.0 |
|---|---|---|---|---|---|
| TTK vs no bargain | **0.96** | 1.02 | 1.06 | 1.08 | 1.09 |

So the review's 0.96 holds only for an un-upgraded build on stage 1; for every later or
established build the shrine is a small real cost (2-9 % slower kills, 20 % for thorns) for +30 %
gold. D (est, Bargain sealed on all 5 stages, seed 1) against C (same seed): gross gold 12,773 vs
11,351 (+12.5 %; kill gold +36 %), 74 vs 69 chests, boss TTK similar, lower min HP on stage 4
(40 % vs 80 %), no would-be deaths either way. Verdict: **working as a fair tradeoff; not a power
exploit.** Its main effect is more gold, which matters only because gold is already plentiful
(5.1). The HUD line "+25 % DMG" reads as a multiplier while it is additive: copy only.

### 5.5 Party, passes and heroes

- **Duo (F):** player-1 pressure is higher than solo through stage 4 (243-275 HP/min taken on
  stages 2-3, 7 would-be deaths in total) and drops on stage 5 like solo. Chests are world objects
  shared by the team (13-17 per stage for two players), so per-player items halve when both shop.
- **Both passes (H):** prices 63 / 150 / 375 and 143 / 345 / 863 exactly as recorded; income x2.5;
  the return offer and payout after stage 2 = (100 + 300 x 2) x 2.5 = **1,750**. Items bought (28
  in 2 stages) same as without passes: no in-run advantage (not pay-to-win in-run). Lobby payout
  x2.5 by design.
- **Mage (G):** same shape as the Knight; more damage taken on stages 1-4 (no Iron Skin), no
  would-be deaths after stage 1.

### 5.6 Choice: buy now, save, or bank (PROPOSAL baseline)

On a successful return every unspent coin goes to the lobby 1:1, so a chest costs lobby
progress. The cohorts show the size of that trade:

| Strategy | Lobby gold after a 5-stage win | Would-be deaths (5 stages) |
|---|---|---|
| Buy everything (A, 3 seeds) | 4,238-7,458 | 0-3 |
| Buy nothing (B, 3 seeds incl. 2 pre-fix) | 13,697-16,376 | 15-70 |

So a real choice exists in principle (run safety vs savings), and on a loss the 35 % + 15 %/stage
rule cuts the banked gold. What is missing is the *middle*: from stage 3 on a buying player can
afford almost every chest on the map within a minute or two of income, so there is no
"this chest or that one" decision late in the run.

## 6. Power engine notes (code, not tuned)

- **XP:** level n costs `30 + 12 x min(n, 20) + 6 x max(0, n - 20)`; x Growth (meta +5 %/level,
  passives); Opening x1.5 for 90 s; stage XP x {1, 1, 0.9, 0.8, 0.7}; wave gems x1.8; Duo/Trio
  share 0.5 / 0.36. Measured: about 3.5 levels/min on stage 1, 4-5 on stages 3-5.
- **Free ranks:** every elite chest gives 1 weapon/passive rank (+20 % x (1 + luck) chance of a
  second) plus gold; separate from paid map chests (EC-11).
- **Might / area / damage taken / gold:** one additive pool each (hero, meta, passives, items,
  Bargain, synergies), then curses multiply. Crit (max 60 %, x2 + Hunter's Eye), elite damage and
  Lionheart multiply per hit.
- **Cooldown:** passives floor at -60 % (`max(0.4, 1 - cooldown)`), item attack speed divides that,
  overall floor x0.3 (`Items.MinCooldownMult`), any weapon >= 0.08 s.
- **Move speed** clamp 0.5-2.2x; **crit** cap 60 %; **luck** cap 2 for rarity; **Iron Plate**
  hyperbolic; **Phoenix** max 2.
- **Revives:** meta Revive (1 per run), Phoenix Feather (max 2, 50 % HP), Robux revive token,
  partner revive in co-op, travel revives fallen teammates at 50 %.
- **Crown of Ages (EC-09):** linear, unlimited copies, each +12 % Might +8 % attack speed +8 %
  move +10 % max HP. Legendary pool = 3 items, so each Golden Chest is a 1/3 Crown. Additive Might
  means later copies are worth relatively less (12 % of a 2.3 Might build = +5 %).
- **Waves:** 12 + 3/wave (+1.5 after wave 8), x1.35 every 5th, elites from wave 4 (max 3),
  HP +1 %/wave; `MaxLive` 200.

## 7. Proposed pressure/choice goal (PROPOSAL, not configuration or owner approval)

1. A fresh hero on Standard should face real risk on every stage, not only stages 1-2: in the
   undying bot, at least one moment per stage below about 40 % HP on stages 3-5 (today: 62-92 %
   minimum on stages 3-5), and stage bosses on 3-5 lasting at least about 25-30 s for a buying
   build (today 6-23 s).
2. An established profile should feel stronger but still drop below about 60 % HP at least once
   on stages 4-5.
3. Chest gold should keep a choice going: through stage 4-5 a buying player should be able to
   afford roughly 60-80 % of the paid chests, not 93-100 %, while stage 1 stays as it is
   (first purchase within about 30-60 s).
4. Banking vs buying stays a visible trade: a no-buy run should remain clearly riskier, and the
   difference in lobby gold should stay meaningful.

Reasoning: these keep the early save-up decision and the satisfying growth, target the measured
gap (stages 3-5), and can be checked with the same scene.

## 8. Bounded recommendations for World 2+ (nothing applied; owner OK needed where marked)

Ordered by evidence and reversibility. Each is one centralised key in `src/shared/Config.lua`;
measure each with the same cohorts (A, C, B, 3 seeds) before and after, one change at a time.

1. **Threat after minute 12 (enemy side, centralised).** `Config.Difficulty.MaxTier` 12 stops HP and
   damage growth during stage 3-4. Proposal: 12 -> 16 (stage 5 normal HP x1.2, damage x1.12), or a
   new per-stage late term from stage 3. Prefer this over flat enemy HP: it targets exactly the stages
   that go soft. Risk: Endless also uses it.
2. **Threat composition, not sponges.** From stage 3, more ranged / lunging / affix elites rather
   than more HP: `Config.Waves.EliteMax` 3 -> 4 and `PressureMult` up a step on stages 3+, or the
   stage hazard cadence (`Enemies.StageHazards.Every` 22 s). Damage that ignores flat armor
   (hazards, globs, bosses) is what keeps armoured builds honest.
3. **Bosses on stages 3-5.** `Config.Stages.BossHPByStage` {0.22, 0.4, 0.7, 1.05, 1.5}: boss TTK
   falls to 6-23 s. A bounded step: {.., .., 0.85, 1.35, 2.0} (+21 %, +29 %, +33 %), combined with
   the boss-move work rather than alone.
4. **Flat armor order.** `amount x DamageTaken - Armor` lets Armor 4-8 erase the commonest hits.
   Option: apply Armor as a share of the hit (e.g. at most 50 % of a hit), keeping the 1-damage
   floor. Changes how a bought meta upgrade works, so **owner decision**.
5. **Late gold (income side).** Elite-chest gold scales twice (stage and elite count). Proposal:
   `Config.Gold.EliteStageScale` 0.25 -> 0.15 (stage 5 elite chest 85 -> 68 avg). Lobby payout falls
   a little, so **owner OK** (it touches progression speed).
6. **Chest price curve.** `Config.Chests.CostExponent` 1.2 -> 1.35 leaves stage 1 unchanged and
   raises stage 3 / 5 prices by 18 % / 27 %. In-run gold prices, not Robux, but still a price:
   **owner OK** required by the brief. Try 5 before 6.
7. **Not recommended:** a blanket gold cut, universal upgrade nerfs, or a Bargain nerf (5.4).

## 9. Copy and disclosure findings (FOR OTHERS, no balance change)

- Results "N gold earned" is the unspent ledger, not gross. Use `GoldEarned + GoldSpent` (both
  already in the `RunResult` payload) for "earned", and name the other "unspent" (`UIBuilder.lua`
  ~3659-3662).
- Chest odds text (`LootSystem.chestBenefit`) shows base weights; with luck > 0 the real
  uncommon/legendary odds are higher. Show the odds with the player's luck, or add "before luck".
- Bargain line "+25 % DMG" is additive to the build's damage bonus; "+30 % gold" applies to kills,
  elite chests and bosses, not the return bonus (`LootSystem.useBargain` text, HUD buff chip).

## 10. Verified vs assumed

- PASS (code + sim): every recorded chest price; 505 / 176 / 329 and +176 lobby; +1,000 offer
  = old StageClearBonus 150 with both passes (today 1,750, sim-paid); shown price = charged price;
  passes give no in-run item advantage; Bargain additive math; travel heal rule.
- PASS (sim, offline only): gold by source, spend, chest share, pressure by stage, corner sustain
  before/after the fix.
- ASSUMED / not verified: the 111 -> 168 HP jump comes from Open-phase regen; real players'
  pacing, routing time to chests and card choices; Studio, device and live party behaviour.
- No balance value, price or data was changed. No game code was edited by ECON-AUDIT.
