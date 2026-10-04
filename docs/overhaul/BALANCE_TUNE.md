# Balance tune (ECON-TUNE, 2026-10-04)

Follow-up to `docs/overhaul/BALANCE_AUDIT.md` sections 7-9. Scope: recommendations 1-3 of
section 8 (enemy side), plus copy fixes. Items 4-6 were measured on request (see section 3)
but **not applied**.

## 0. Method

- Scene: the audit's `econ-sim` (scratch, not in the tree), copied to
  `scratchpad/econ/tune/repo` (frozen code at `07578bf` + the audit's instrumentation). Two
  additions to the scratch scene only: `--set cfg=Key.Path:value;...` overrides Config keys
  before the server boots, and a `WAVE Sn wave N tier T` line per stage. Runner
  `scratchpad/econ/trun.sh`, comparison `scratchpad/econ/cmp.py`, logs `scratchpad/econ/tune/out`.
- Every variant was run against the frozen code with only its Config key(s) changed, so each
  number below is that one change against the baseline. Baselines were re-run on the same
  copy (`base_*`), not taken from the audit.
- Cohorts as in the audit: **A** fresh Knight, greedy buyer; **C** established Knight
  (Armor 4 etc.), greedy; **B** fresh, never buys. Life mode "undying" (would-be deaths are
  logged, HP refills). Seeds 1-5 for A on the kept changes, 1-3 otherwise; C seeds 1-2; B seed 1.
- Determinism: same seed = identical run until the first changed value takes effect, then the
  runs drift. Every variant here reproduced the baseline's stages 1-2 **exactly** (same min HP,
  damage, boss time, purchases), except where noted for items 5-6 and 4. That is the main
  evidence that stages 1-2 are unchanged.
- Small n and one bot (no dodging, random cards, teleport-shopping). Late-stage numbers vary
  a lot between seeds (stage 5 min HP 66-96 % in the baseline alone). Treat a change of a few
  points as noise. Offline Lune only: nothing here was tested in Studio, on a device or in a
  live party.

Timing in the sim (tier = run minute): stage 1 ends at minute 3-4, stage 2 at 7-8, stage 3 at
10-11, stage 4 at 13-15, stage 5 at 15-18 (waves 8 / 16 / 25-30 / 34-45 / 44-61).

## 1. Applied (src/shared/Config.lua)

### 1a. `Config.Difficulty.MaxTier` 12 -> 16 (KEPT)

Normal enemies' HP and damage stop growing with the run clock at MaxTier. Stages 1-3 end
before minute 12 in every run, so they are untouched; stage 4-5 enemies get up to x1.20 HP and
x1.12 damage.

Cohort A, n=5 (seeds 1-5), means:

| Stage | Min HP base -> new | Dmg taken /min | Boss TTK s | Would-be deaths |
|---|---|---|---|---|
| 1-3 | identical | identical | identical | identical |
| 4 | 78 % -> 73 % | 49 -> 48 | 15.2 -> 15.8 | 0 -> 0 |
| 5 | 85 % -> 68 % | 59 -> 81 | 14.4 -> 13.3 | 0 -> 1 |

Cohort C (est, n=2): stages 1-3 identical, stage 4 min HP 77 -> 83 %, stage 5 98 -> 98 %
(noise; the armoured build barely notices). Cohort B (no-buy, n=1): stages 1-3 identical.
Verdict: a small move toward goal 1 on stage 5, mostly from one seed (stage 5 min HP 6 %);
stage 4 within noise. Kept because it is safe for stages 1-3 by construction and targets the
right stages. Assumed: real players who take longer than the bot reach minute 12 earlier (late
stage 3), so for them stage 3 also gets a little harder; a player still on stage 2 at minute
12+ would too (not seen in any run).

Endless: the cap applies to Endless as well, so every Endless stage past minute 12 gets the
same constant x1.20 HP / x1.12 damage on top of its own per-stage growth. `endless-sim`: all
checks PASS on the working tree after the change.

### 1b. `Config.Stages.BossHPByStage` {0.22, 0.4, 0.7, 1.05, 1.5} -> {0.22, 0.4, 0.85, 1.35, 2.0} (KEPT)

The audit's bounded step (+21 % / +29 % / +33 % on stages 3 / 4 / 5). Stages 1-2 unchanged.

Cohort A, n=5, means:

| Stage | Boss TTK base -> new | Min HP | Would-be deaths |
|---|---|---|---|
| 1-2 | identical | identical | identical |
| 3 | 24.9 -> 30.2 s | 55 -> 62 % | 1 -> 0 |
| 4 | 15.2 -> 18.1 s | 78 -> 69 % | 0 -> 0 |
| 5 | 14.4 -> 16.6 s | 85 -> 83 % | 0 -> 0 |

Goal 1 asks 25-30 s on stages 3-5: stage 3 now meets it; stages 4-5 move toward it but stay
below (the bot's build kills faster than HP grows). Not pushed further: the audit pairs a
larger step with the boss-move work, and a tankier boss without new attacks is a sponge.
Endless: stage 6+ bosses are `list[5] + 0.4 x (stage - 5)` x Endless growth, so they rise
too (stage 6 x2.64 instead of x2.09, stage 10 x6.0 instead of x5.25); the step from stage 5
to 6 is now x1.32 instead of x1.39, still increasing. `endless-sim` PASS.

### 1a + 1b together (A seeds 1-3, C seed 1, B seed 1)

A: stages 1-2 identical; stage 3 boss 22.8 -> 28.9 s, stage 4 min HP 78 -> 72 %, stage 5
79 vs 83 %. C: stages 1-2 identical, stages 3-5 min HP 88 / 90 / 100 % (goal 2, "an
established build drops below 60 % on stage 4-5", is **not** met by these changes). B (no
shop): stage 4-5 min HP 0 -> 5 % and 25 -> 2 %, would-be deaths stage 4 1 -> 2 (buying vs
banking stays a clear trade, goal 4).

## 2. Measured and NOT applied

### 2a. `Config.Enemies.StageHazards.Every` 22 -> 16 (rec. 2, rejected)

A n=3: stages 1-3 practically identical, stage 4 min HP 78 -> 76 %, stage 5 83 -> 91 %. C n=2:
identical to the baseline on every stage. The bot keeps walking, so it is rarely inside the
1.4 s telegraph: no measurable effect. Correction to the audit: biome eruptions go through
`RunManager.DamagePlayer`, so flat Armor **does** reduce them (they are not armour-ignoring).
`Waves.EliteMax` 3 -> 4 was not run: a 4th elite only comes from wave 28 (late stage 3 /
stage 4 in the sim) and elites already die in about 6 s; low expected effect, left for the
owner's composition work. Per-stage `PressureMult` needs code (no per-stage key).

### 2b. Items 4-6 (measured on the lead's request; not applied)

The lead relayed an owner approval for items 4-6. I could not see that approval myself, and
the project rules say no price or gold change without the owner's OK, so these were measured
only. They also fail the keep rule (stages 1-2 must not get harder):

| Change | Result | Verdict |
|---|---|---|
| 4. Armor blocks at most 50 % of a hit (code, scratch copy only) | C n=2: stages 3-5 identical to base (late hits are big enough that Armor 4 is never capped); stages 1-2 *more* damage (41 -> 48, 80 -> 87 HP/min). A n=1: no change | Hurts stages 1-2, no late effect: **do not apply** in this form |
| 5. `Gold.EliteStageScale` 0.25 -> 0.15 | A n=3: stage 2 elite gold falls too (x1.15 instead of x1.25): stage 2 min HP 45 -> 16 %, would-be deaths 1 -> 3; stage 3 deaths 0 -> 3. Chests bought stage 4 96 -> 89 %, stage 5 100 -> 100 %. Lobby gold -6 to -19 % | Harder stage 2, misses the 60-80 % target: **do not apply** |
| 5 + 6. + `Chests.CostExponent` 1.2 -> 1.35 | A n=3: stage 1 prices and first buy unchanged (25/60/150, 0:24); stage 2 prices +11 %; chests bought stage 3/4/5 77 / 85 / 88 % (target 60-80 %); stage 4 min HP 57 %. C n=1: bought 53 / 53 / 75 %, stage 4 min HP 30 % (meets goal 2), but stage 2 min HP 90 -> 1 % with a would-be death. Lobby gold A 4,170-4,652 (base 5,272-7,458) | Moves toward goals 2-3 but makes stage 2 harder: **not applied**. A version that starts from stage 3 needs code |

Shown price = charged price (code check, PASS): the client shows
`ItemData.PlayerPrice(Price attribute, GoldMult attribute)`, the server charges
`ItemData.PlayerPrice(obj.Price, GoldSystem.PriceMult)`, and the exponent only enters
`ItemData.StagePrice`, which sets `obj.Price` = the attribute. So a new exponent cannot split
them, with or without passes. Stage 1 is `base x 1^exp` = unchanged. Note that the Shrine of
Chance price uses the same exponent.

Suggested next try for the owner (not run): keep stage 2 as it is and raise only stage 3+
prices or elite-chest gold (a `max(0, stage - 2)` term), then re-measure with C and B.

## 3. Copy fixes (src/server/Modules/LootSystem.lua)

- `chestBenefit`: "1 item (80% common, 19% uncommon, 1% legendary before luck)". The prompt is
  one world label shared by every player, so it shows the base odds; Luck raises the rarer
  shares per player in `ItemSystem.Roll`. Single-rarity chests ("1 legendary item") unchanged.
- Bargain Shrine prompt: "Team: +25% added to damage bonus, +30% gold from kills, elite chests
  and bosses this stage" (also nests and the caravan, not the return bonus, full-build coins or
  survival gold; noted in the code comment). The sealed broadcast says the same.
- FOR OTHERS (LootUI owner): the HUD chip `src/client/LootUI.lua` ~1111 still reads
  "BARGAIN  +25% DMG  +30% GOLD". Suggested: "BARGAIN  +25% DMG BONUS  +30% GOLD" (keep it
  short; the prompt carries the full sentence).

## 4. Verified vs assumed

- PASS (offline sim): stages 1-2 unchanged by 1a and 1b (identical logs per seed); boss TTK
  and late pressure numbers above; endless-sim all PASS; `tools/check.sh --quick` ok;
  regressions: see the lead's report / section 5.
- ASSUMED: real players' pacing (slower players reach the MaxTier window earlier), dodging,
  card choices, routing time to chests; Studio / device / live party behaviour (BLOCKED here).
- Not touched: gold, prices, Robux, armor rules, `Config.Waves`, hazards.

## 5. Stage 3+ economy (owner OK 2026-10-04)

Owner decision (2026-10-04, in the owner's own answer to the lead): "Stage 3+ only". Stages 1-2
stay exactly as they were; from stage 3 chests and the Shrine of Chance cost more and elite
chests give less gold. Armor, Robux and pass values are not touched. Applied by ECON-TUNE-2.

### 5a. Change

- `Config.Chests.LateCostExponent = 0.75` (new). `ItemData.StagePrice` = `base x stage^CostExponent`,
  and from stage 3 also `x (stage / 2)^LateCostExponent` (stage 3 x1.36, 4 x1.68, 5 x1.99).
  Stages 1-2 multiply by exactly 1. Chests and the Shrine of Chance both go through
  `StagePrice`, so the shrine follows (its per-try growth is unchanged).
- `Config.Gold.EliteLateStageScale = 0.05` (new). Elite chest gold scale (`LevelUpSystem.OpenChest`)
  = `1 + EliteStageScale x (min(stage, 2) - 1) + EliteLateStageScale x max(0, stage - 2)`.
  Stages 1-2 keep x1.00 / x1.25; it was +0.25 per stage after that too.
- Endless: stages 6+ use the same formulas, so Endless prices rise further (stage 6 x2.28 on
  top of the old curve) and Endless elite gold grows 0.05 per stage. `endless-sim` PASS; Endless
  balance itself was not measured.

| Price (no pass) | Stage 1 | Stage 2 | Stage 3 | Stage 4 | Stage 5 |
|---|---|---|---|---|---|
| Small chest | 25 | 57 | 93 -> 127 | 132 -> 222 | 172 -> 343 |
| Large chest | 60 | 138 | 224 -> 304 | 317 -> 533 | 414 -> 823 |
| Golden chest | 150 | 345 | 561 -> 760 | 792 -> 1,331 | 1,035 -> 2,057 |
| Shrine of Chance (1st try) | 15 | 34 | 56 -> 76 | 79 -> 133 | 103 -> 206 |
| Elite chest gold scale | x1.00 | x1.25 | x1.50 -> x1.30 | x1.75 -> x1.35 | x2.00 -> x1.40 |

Elite chest gold, average before the gold multiplier (42.5 base): stage 3 64 -> 55, stage 4
74 -> 57, stage 5 85 -> 60. Gold-pass owners see and pay `PlayerPrice` of the new price,
as before.

### 5b. Measurements (econ-sim, same scratch copy and method as section 0)

Baseline = the shipped 1a + 1b (`v13_*` logs). Chests bought = paid chests bought / spawned,
summed over the seeds (count, not gold).

Candidates, cohort A (fresh Knight, greedy), seeds 1-3:

| LateCostExponent / EliteLateStageScale | Bought st 3 | st 4 | st 5 |
|---|---|---|---|
| baseline (0 / 0.25) | 98 % | 96 % | 100 % |
| 0.5 / 0.10 | 88 % | 81 % | 85 % (misses) |
| 0.75 / 0.10 | 86 % | 81 % | 77 % (edge) |
| **0.75 / 0.05 (applied)** | **86 %** | **68 %** | **75 %** |
| 1.0 / 0.10 | 79 % | 66 % | 69 % |

Chosen: the smallest price step that reaches the 60-80 % target on both stages 4 and 5.
0.75 / 0.10 lands on the edge (81 % on stage 4); 1.0 / 0.10 also works but with a 25 % larger
price step on stage 5.

Applied values, per cohort:

| Cohort | Stage | Bought before -> after | Min HP % before -> after (per seed) | Would-be deaths |
|---|---|---|---|---|
| A n=3 | 1-2 | identical | identical | identical |
| A n=3 | 3 | 98 -> 86 % | 62/79/82 -> 61/46/4 | 0 -> 1 |
| A n=3 | 4 | 96 -> 68 % | 62/83/71 -> 11/67/93 | 0 -> 0 |
| A n=3 | 5 | 100 -> 75 % | 74/94/70 -> 15/63/9 | 0 -> 0 |
| C n=1 (est.) | 1-2 | identical | identical | identical |
| C n=1 | 3 / 4 / 5 | 93 / 94 / 100 -> 73 / 47 / 56 % | 88 / 90 / 100 -> 90 / 79 / 95 | 0 -> 0 |
| B n=1 (no buy) | 1-5 | 0 % | identical on every stage | identical |

Lobby gold after the run: A 4,378 / 5,941 / 5,159 -> 4,224 / 4,406 / 4,685; C 4,358 -> 4,383;
B 15,248 -> 14,606 (-4 %, elite gold only). First purchase still 0:24 (stage 1 unchanged).

Reading: goal 3 (60-80 % on stages 4-5 for a greedy buyer) is met in this sample; fewer
items also push goal 1 (stage 3-5 min HP below 40 % in 4 of 9 stage-runs, was 0). The
established build (C) now buys about half of the stage 4-5 chests but still does not drop
below 60 % HP (goal 2 not met; armour was out of scope). Banking vs buying stays a clear
trade (B still 0-7 would-be deaths per stage and 0-5 % min HP, far more lobby gold).

### 5c. Verified vs assumed

- PASS keep rule: for A seeds 1-3, C seed 1 and B seed 1, the logs through the stage 2 summary
  are identical to the baseline (only the source line number of the elite-gold entry moved).
  A neutral run (new code, LateCostExponent 0, EliteLateStageScale 0.25) also matched the
  baseline through stage 3.
- Noise: the sim is **not** deterministic after stage 3. A rerun of the unchanged frozen code
  (seed 1) matched the old log through stage 3 and then drifted (stage 4 min HP 62 -> 58 %).
  So stage 4-5 numbers are n=3 samples with real spread; the chosen value has margin on
  stage 4 (68 %) and a little on stage 5 (75 %).
- PASS shown price = charged price, with and without passes: code check (the server sets the
  `Price` attribute from `obj.Price` = `StagePrice`; client shows `PlayerPrice(Price, GoldMult)`,
  server charges `PlayerPrice(obj.Price, GoldSystem.PriceMult)`; the new term is inside
  `StagePrice` only) and `chest-gold-sim` PASS (it exercises the pass multiplier on stage 1;
  stage 3+ prices are covered by the code check, not by that scene).
- PASS: `tools/check.sh --quick`; `chest-gold-sim`, `economy-sim`, `reward-regression`,
  `settlement-lifecycle`, `endless-sim` (0 FAIL lines each).
- ASSUMED / BLOCKED: real players' routing and buying habits, co-op purses, Studio and device
  behaviour; Endless economy balance.
- Lead: capped LateCostExponent term at stage 5 (Endless keeps stage-5 ratio); endless-sim 0 FAIL.
