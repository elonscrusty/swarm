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

No passive income during a run. Gold Altar / Guarded Altar / runes / treasure cache pay items,
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
