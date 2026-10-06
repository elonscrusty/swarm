# 30-features batch: balance check (BALANCE-2, 2026-10-06)

Offline only (Lune econ-sim on the real server modules). Nothing here was played in Studio, on a
device or in a live server. The sim bot is weak on purpose: it walks a circle, takes random cards,
and never dodges. Use the numbers to compare cohorts, not as real player outcomes.

## Method

- Scene: scratch `econ-sim` (BALANCE_TUNE section 0), on a copy of the current `src` tree (working
  tree of 2026-10-06, including the uncommitted MATH-15 `DamageDealt` change). Knight, fresh
  profile, 5 stages, `enc=on` (the bot does every encounter: champion, secret wall, Trial, villager,
  merchant), `ult=on`, `life=undying` (a would-be lethal hit is counted and HP refilled).
- Repro: Knight seed 1 on the new tree matched the old `repro_Knight_s1` log line for line
  through stage 4 (only new log lines were added). The sim drifts after stage 3 between runs, as
  before, so stage 4-5 rows have real spread.
- Cohorts: greedy buyer (teleports to the best affordable paid chest every 2 s, buys merchant
  items) and no-buy. "Off" = `MapEvents, MiniBosses, SecretRooms, TrialShrine, Merchant,
  CursedChests, Rescue, Weather` switched off.
- New scene logging (scratch only): what was running at each would-be death (`Ltrial`,
  `Lcursed`, `Lrescue`, `Lboss`, `Lplain`), cursed-chest seconds, `LETHAL` / `DEATH` lines with
  time and cause, and `--set curse=` for curse runs.
- Sample sizes are small (n = 2 to 4 seeds). Differences under about 15 % are inside the noise.

## 1. Encounter features: economy and pressure (solo, greedy buyer)

Chests = paid chests bought / spawned, summed over seeds. Lethal = would-be deaths per run.
"Before" is the shipped config, "after" has the one change in section 4.

| Stage | Gold, off / on / after | Items gained, off / on / after | Chests bought, off / on / after | Taken/min, off / on / after | Lethal, off / on / after | Stage s, off / on |
|---|---|---|---|---|---|---|
| 1 | 574 / 497 / 456 | 13.0 / 12.5 / 11.5 | 82 / 73 / 65 % | 72 / 146 / 182 | 0.8 / 3.8 / 5.5 | 243 / 268 |
| 2 | 1,150 / 895 / 966 | 13.2 / 12.2 / 13.8 | 88 / 72 / 80 % | 63 / 106 / 165 | 0.2 / 1.0 / 2.5 | 222 / 221 |
| 3 | 2,013 / 1,756 / 1,524 | 11.0 / 10.0 / 11.0 | 72 / 57 / 63 % | 35 / 128 / 304 | 0.0 / 2.2 / 3.2 | 206 / 206 |
| 4 | 2,960 / 2,631 / 3,050 | 11.0 / 11.2 / 11.8 | **69 / 56 / 66 %** | 24 / 74 / 334 | 0.0 / 0.2 / 2.5 | 201 / 202 |
| 5 | 5,224 / 4,931 / 5,208 | 11.5 / 12.8 / 12.2 | **69 / 62 / 59 %** | 116 / 69 / 212 | 0.0 / 0.5 / 0.8 | 182 / 176 |

n = 4 each (seeds 1-4). Run gold earned: off 10.4k-13.2k, on 10.0k-11.1k, after 9.5k-15.0k.
Lobby gold after the run: 4.1k-4.7k in all three (the settlement evens it out).

No-buy cohort (n = 2, seeds 1-2, before the change): gold per stage on / off 708 / 640,
1,356 / 1,040, 1,822 / 1,944, 2,632 / 2,570, 5,026 / 5,425; lobby gold 12.2k-16.0k / 14.0k-14.4k.
Items gained per stage 1-2 (on: free champion / cache chests) vs 0-0.5 (off). Taken/min is higher
with the features on (stage 3: 665 / 322), with 6-18 would-be deaths per stage in both. Banking
gold is still a clear trade.

Reading:
- **Chest affordability, stages 4-5 (target 60-80 %).** Off: 69 / 69 %. On: 56 / 62 %, after:
  66 / 59 %. Counting merchant items as purchases (they cost a chest of the same rarity), on is
  62 / 64 % and after 66 / 61 %. The features take gold the same way the chests do and add free
  items (champion Large chest, secret caches), so items per stage stay level (11-13 in every
  cohort). **Inside the target within noise: no change made.**
- **Damage taken** is roughly 2x with the features on, mostly from fights the bot chooses (the
  Trial, champion, cursed chests). The bot never dodges and stands still in the Trial ring.
- **Clear time**: same (stage 1 is 25 s longer with the villager escort; stages 2-5 within 6 s).

### What caused the would-be deaths (features on, tagged runs)

| Tag | Stage 1 | Stage 2 | Stage 3 | Stage 4 | Stage 5 |
|---|---|---|---|---|---|
| Trial running | 9 (3 of 3 runs that started it at the stage start) | 2-5 | 4-5 per trial | 1-5 per trial | 0 |
| Cursed chest active | 1-5 | 0 | 0 | 0 | 0 |
| Boss fight | 2-16 | 1-6 | 0-1 | 0-2 | 0 |
| Plain | 0-2 | 2-9 | 2-8 | 4 | 2-3 |

**Trial on stage 1, the "instant death".** The bot starts the Trial as soon as the shrine is
there. On stage 1 that is a level-1 hero with one weapon: would-be deaths at 8, 12 and 23 s
(Mite contact) in every such run, and a real death at 8 s in every `life=mortal` seed-2 run,
with or without curses. That is the one clear miss, so it is the one change (section 4).

## 2. Duo: team combo and co-op boss weak spot

Two Knights, 3 stages, `life=invuln`, partner 0.4 rad behind, on the far side of the boss
(`gapb=pi`), the bot fires the combo whenever it is charged. Seeds 1-2. The duo needs a run
without `--studio` (the run-server ticket path is live-only); the earlier attempt with `--studio`
failed on that.

| Run | Combo share of team damage, S1 / S2 / S3 | Bursts | Boss damage S1 (ScorpionQueen) | Weak-spot share of boss damage |
|---|---|---|---|---|
| All on, s1 | 0.1 / 0.0 / 0.9 % | 3 / 3 / 2 | 2,532 | 3.5 % |
| All on, s2 | 0.1 / 1.1 / 1.3 % | 3 / 2 / 3 | 2,397 | 1.8 % |
| Weak spot off, s1 / s2 | 0.1-1.3 % | 2-3 | 2,442 / 2,468 | 0 |
| Both off, s1 / s2 | 0 | 0 | 2,404 / 2,468 | 0 |

- **Team combo**: at most 1.3 % of team damage per stage (target at most about 10 %). PASS.
- **Co-op weak spot**: 1.8-3.5 % of the boss's damage, so at most about 4 % off the boss time
  (target at most about 20 % shorter). PASS. The stage-1 boss was force-killed at the 126 s cap
  in every duo run (20-24 % HP left), so the time itself could not be compared directly.
- Both are well under target. If the owner wants them to matter more, raise
  `TeamCombo.Damage` / `BossShare` or `CoopBoss.Mult` / `MaxBonusShare`. Not changed.

## 3. Curses (solo, greedy, all features on, `life=undying`)

n = 2 (seeds 1-2), shipped config, compared to the same runs with no curse.

| Curse | Taken/min S1 | Would-be deaths S1 | Would-be deaths S1-5 | Mean min HP | Run s | Kills | Run gold |
|---|---|---|---|---|---|---|---|
| none | 147 | 3.0 | 5.5 | 36 % | 1,055 | 6,147 | 10.5k |
| Frenzy | 202 | 4.5 | 8.5 | 31 % | 1,081 | 7,450 | 15.2k |
| Fragile | 148 | 4.5 | 11.5 | 28 % | 1,084 | 5,716 | 11.8k |
| Horde | 150 | 2.5 | 7.0 | 30 % | 1,072 | 7,174 | 18.5k |
| Elite Surge | 150 | 3.0 | 4.0 | 53 % | 1,015 | 7,412 | 21.4k |

After the change (seed 2 only): first stage-1 would-be death at 123 s with no curse, 89 s with
Frenzy and 115 s with Fragile. None in the first 30 s. Horde and Elite Surge after the change:
NOT RUN (the batch was paused for the UI fixes).

Reading:
- No curse kills instantly on stage 1, and every curse run finished all 5 stages (undying).
  PASS for "harder, not broken" on the bot's terms.
- Frenzy and Fragile are harder (more damage or deaths, lower min HP).
- **Horde and Elite Surge get easier after stage 2 for a buyer.** More kills and elites bring
  60-100 % more run gold, so the bot bought 88-100 % of the chests on stages 3-5 (no curse: 50-61 %).
  Elite Surge had the fewest deaths and the best min HP. Curses are not this batch's knobs, so
  this is a note for the owner: their `Gold` bonus (0.25 / 0.30) and the extra elite chest gold
  stack. Not changed.
- `life=mortal` runs are not useful with this bot. A fresh Knight dies on stage 1 at 89-189 s,
  at level 3-5, even with no curse (it never dodges). Finishability for real players is BLOCKED
  (Studio / device playtest).

## 4. Change made

| Knob | Before | After | Why |
|---|---|---|---|
| `Config.TrialShrine.MinStage` (new; TrialShrine registers an `Allow` like MiniBoss) | none (stage 1 on) | 2 | Starting the Trial at the start of stage 1 killed a level-1 hero in about 8 s in every run that did it |

Effect (n = 4 after vs before): no Trial deaths on stage 1. Stage-1 deaths overall did not fall
(5.5 vs 3.8), because boss-fight deaths on stage 1 swing a lot between seeds (2-16 per 4 runs).
Stages 4-5 affordability 66 / 59 % (inside the target within noise). Stage 1 loses the Trial's
bonus card (stage 1 items 11.5 vs 12.5).

Not changed, for the lead or owner:
- The Trial still causes about 1-5 would-be deaths per trial on stages 2-4 for the bot, which
  stands still in the ring. Real players can kite inside the 22-stud ring or step out (no reward).
  If playtests agree it is too harsh, lower `TrialShrine.DamageMult` (1.25) or `Alive` (10)
  first.
- Cursed chests: a few stage-1 deaths while active (60 s per stage). Within noise, left alone.

## 5. Verified vs assumed

- PASS: econ-sim measurements above (offline, small samples). Knight seed-1 repro matches.
- PASS: `bash tools/check.sh --quick` (typecheck, compile, art keys: 0 problems).
- Regressions for the changed config: `challenges-regression` now lowers the gate for its
  stage-1 Trial checks and adds a check that the shipped `MinStage` leaves stage 1 without a
  Trial. Results of `challenges-regression`, `encounters-sim`, `encounter-placement`,
  `foundation-regression`, `explore-regression`, `events-regression`, `curses-sim`,
  `economy-sim`, `chest-gold-sim` and `reward-regression`: see the status line below.
- BLOCKED: Studio, device and live behaviour; real players' routing, dodging and buying; co-op
  with real positioning; Endless.

Regressions: PENDING (queued behind the paused batch).
