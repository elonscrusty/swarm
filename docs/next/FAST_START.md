# Shorter early game (switch `FastStart`)

## What
The first three waves of a run (stage 1 only) come quicker and a little bigger, so the opening
reaches the fun part sooner. Nothing else changes: wave 4 onward, stage 2+, bosses, enemy HP
and damage, the XP curve and gold are exactly as before.

How (server, `EnemySpawner` wave state machine, helper `FastStartMult(n, key)`): for run
waves 1..3 while the run is on stage 1 the wave's Config.Waves numbers are multiplied:

| Number | Plain | FastStart |
| --- | --- | --- |
| wave time cap (`MaxSeconds`) | 30 s | 10.5 s (leftovers stay and fight on) |
| next wave when this share is left (`ClearShare`) | 0.1 (min 3) | 0.4 (min 3) |
| breather after the wave (`BreatherSeconds`) | 3 s | ~1 s |
| wave size (solo) | 12 / 15 / 18 | 14 / 18 / 22 (x1.2) |
| delay before wave 1, pour-in time | 4 s, 4.5 s | unchanged (x1) |

The bigger size is applied after the never-shrink floor is recorded, so wave 4 is sized
exactly as before (regression-checked). Co-op runs get the same opening (their sizes keep the
player-count density). Config.FirstRun is untouched: an account's first run still gets
FirstLevelXP and its gentle waves 1-2 (x0.7 size and HP, applied on top of FastStart), and the
tutorial portal hold (`RevealWaitsForPick`) is a StageManager rule this item does not touch.

## Config
- `Config.Features.FastStart = true` (false = the waves are exactly as before; the
  regression's off run reproduces the old wave timings to the second)
- `Config.FastStart`: `Waves = 3`, `FirstDelayMult = 1`, `BurstMult = 1`,
  `MaxSecondsMult = 0.35`, `BreatherMult = 0.34`, `SizeMult = 1.2`, `ClearShare = 0.4`,
  `FirstLevelUpBy = 30` (regression threshold only)

## Measurements
Offline Lune sim (`fast-start-regression --set measure=on`, real server, solo Knight walking
a circle, cards auto-picked, no dodging, no chests). Not invulnerable: a hit that would down
the hero counts as a would-be death and refills HP. Same frozen code (HEAD + this item only),
seeds 1-8 per row, means. Baseline = `--set faststart=off` (identical to the old code: same
waves to the second). Two bot policies, because "clear time" depends on when the player goes
to the portal:

**A. explore 150 s, then the portal** (the pacing-sim habit; best for XP and damage)

| Measure | Before | After |
| --- | --- | --- |
| first level-up | 23.6 s | 20.5 s |
| XP per minute, first 90 s | 197 | 261 (+32 %) |
| level at 2:00 | 6.7 | 7.5 |
| damage taken, stage 1 | 463 | 455 |
| damage taken, first 90 s | 77 | 75 |
| stage 1 clear time | 245 s | 246 s (explore is fixed) |
| would-be deaths, stage 1 (explore phase) | 3.2 (0.6) | 3.0 (0.4) |
| stage 2 would-be deaths (config unchanged) | 9.4 | 8.1 |

**B. go to the portal when wave 4 is announced** (shows the shorter opening)

| Measure | Before | After |
| --- | --- | --- |
| waves 1-3 done (wave 4 starts) | 47.4 s | 34.4 s (-27 %) |
| XP per minute, first 90 s | 127 | 157 (+24 %) |
| level at 2:00 | 6.0 | 5.8 (boss starts sooner) |
| damage taken, stage 1 | 684 | 720 |
| stage 1 clear time | 210 s | 206 s |
| would-be deaths, stage 1 (explore phase) | 5.2 (0) | 5.5 (0) |
| stage 2 would-be deaths (config unchanged) | 14.0 | 11.9 |

Reading: the bot dies mostly in boss fights (it never dodges), and per seed the stage-1 count
ranges 1-11 with or without FastStart, so +-0.5 is noise; deaths and damage in the waves
themselves did not go up. Stage 2+ use exactly the old numbers (the multiplier is 1 there,
regression-checked); their differences above come from arriving with a different level.
Variants tried (same seeds): shortening FirstDelay / pour-in too pushed the first level-up to
~18 s; size x1.3 gave +40 % XP; size x1.0 gave +23 % XP but more early damage. First level-up
spread per seed: 10-32 s (one seed levels at 10 s in both runs).

## Regression
`tools/preview/scenes/fast-start-regression.luau`, registered in `tools/run_regressions.py`
(`fast-start-regression`, headless, ~3 s real):

    python3 tools/run_regressions.py --only fast-start-regression

PASS lines: multipliers on waves 1-3 only, 1 with the switch off and on stage 2, live waves 1-3
bigger than the plain size and inside the shorter cap, wave 4 reached and its size equal to the
plain one, first level-up by `FirstLevelUpBy` (30 s). `--set faststart=off` runs the old opening.
Measure mode: `--set measure=on [--set faststart=off] [--set leave=99 --set explore=150]
[--set fs=SizeMult:1.3,...] --seed N --max-time 900`.

## Owner steps / status
- PASS (offline Lune sim only): numbers above, regression scene, `tools/check.sh --quick`.
- BLOCKED: feel on a real phone / Studio playtest (does the opening feel faster but fair?).
  To undo: set `Config.Features.FastStart = false`.
