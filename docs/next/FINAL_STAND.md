# Final Stand (switch `FinalStand`)

**HELD (owner decision, 2026-10-07): switched off (`Config.Features.FinalStand = false`) and its
regression checks removed from tools/run_regressions.py. The code stays in the tree, unreleased;
with the switch off the game behaves as before.**

## What
The first time in a stage a living hero's HP drops below 10% of max HP, the hero gets
FINAL STAND for 5 s: +30% move speed and +40% damage, a crimson-gold aura, a short
"FINAL STAND!" headline and one sound.

- Server only (`src/server/Modules/FinalStand.lua`). `RunManager.DamagePlayer` calls
  `FinalStand.OnHurt` after a non-lethal hit (a lethal hit downs the hero first, so Final
  Stand never blocks lethal damage). No healing.
- The buff is a temporary stat-sheet multiplier: `rp.TempMods.FinalStand = { Might = 1.4,
  Speed = 1.3 }`, passed by LevelUpSystem's sheet to `StatSheet.Compute` as the new `Temp`
  input (applied last, after curses), then `RecomputeStats` re-applies the walk speed. Every
  weapon, the ultimate and item procs read `Stats.Might`, so all damage gets the +40%.
- Limits: once per stage per player (`rp.FinalStandStage`, re-armed by the next stage); not
  while choosing an upgrade or watching a reward (`rp.Paused` / `rp.Offer` / `rp.RewardUntil`),
  not while protected (`rp.InvulnUntil`), not within 2 s of a revive (`rp.RevivedAt`, set in
  RunManager's revive), not while the world is frozen. Co-op: every hero has their own.
- Cleared (FinalStand.Step, every frame): after 5 s of run time, on a down (also one that an
  extra life revived at once), at the stage's end (travel / a new stage), when the hero leaves
  the run (portal return, MAIN MENU, disconnect) and when the run ends.
- Nothing is granted or saved, so DEV taint does not apply (a tainted run is already kept
  off boards by RunManager).
- Client (`src/client/FinalStandFx.lua`): the player attribute `FinalStand` (seconds) drives
  an ember aura + soft light on every hero that has it (teammates too); Reduced effects keeps
  a smaller aura without the light. For the local hero only: one "FINAL STAND!" headline
  through UIState (Critical, 1.5 s expiry, dropped if the buff already ended) and one existing
  sound (`Evolve`).

## Config
- `Config.Features.FinalStand = true` (false: never triggers; the game is exactly as before)
- `Config.FinalStand` (PROPOSED, awaiting owner approval): `HPShare = 0.10`, `Seconds = 5`,
  `Speed = 0.30`, `Damage = 0.40`, `ReviveGrace = 2`, `Sound = "Evolve"`

## Balance (offline Lune sim)
Method (the BALANCE_TUNE econ-sim style, rebuilt in the tree as
`final-stand-regression --set measure=on`): the REAL server, a solo Knight on the preview's
default profile (tutorial marked done) walks a circle, cards auto-picked, no dodging, no shopping; each stage = 150 s of
exploring, then the portal ring, the boss (the bot circles it) and the surge, 3 stages. Not
invulnerable: a hit that would down the hero is counted as a would-be death and HP refills
("undying"). Stage modifiers off in both runs (one change at a time). Seeds 1-5, Final
Stand on vs `--set fs=off`, same code otherwise. Same seed = identical run until the first
difference (stage 1 is the same in both columns except where Final Stand fired), then runs
drift, so stage 3 has real seed-to-seed spread.

| Stage (means, n = 5) | Would-be deaths off -> on | Damage taken | Boss kill s | Stage s | Min HP | Triggers / stage |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 3.8 -> 3.8 | 512 -> 507 | 70 -> 69 | 235 -> 233 | 3% -> 3% | 0.8 |
| 2 | 8.4 -> 8.0 | 1108 -> 994 | 67 -> 67 | 228 -> 229 | 1% -> 1% | 1.0 |
| 3 | 10.4 -> 7.4 | 1546 -> 1011 | 61 -> 49 | 222 -> 210 | 2% -> 4% | 1.0 |
| total | 113 -> 96 (-15%) | | | 2,122 -> 2,059 s (5 runs) | | |

Per seed, total would-be deaths off -> on: 28 -> 27, 32 -> 19, 30 -> 31, 7 -> 10, 16 -> 9.

Reading: Final Stand fires about once per stage for this bot (it is hurt a lot) and helps a
little: stage 1-2 practically unchanged, the run as a whole about 15% fewer would-be deaths,
clear times within a few seconds (the explore time is fixed by the bot). The stage-3 drop
(-29%) comes mostly from one seed (seed 2: 17 -> 5; seed 3 went 10 -> 13), so treat it as
noise-sized. It does not make runs easy: the bot still "dies" 96 times in 15 stages.
Measured: deaths, damage, boss time, stage time, triggers, offline only. Not measured: co-op,
real players who dodge (they reach 10% HP less often), Studio / device.

## Owner steps
1. Approve or change the numbers (`Config.FinalStand`).
2. Studio playtest: drop under 10% HP in a stage, check the aura, the headline and the sound;
   check it comes back on the next stage.

## Regression
- `tools/preview/scenes/final-stand-regression.luau` (`final-stand-regression`, headless
  server): stat math (x1.4 damage, x1.3 speed, no healing, after curses), trigger under 10%
  and not at 30%, live stats and walk speed, a lethal hit still downs the hero, cleared on a
  down, once per stage, not while protected / choosing / within the revive grace, per player,
  removed after 5 s of run time, cleared at the stage's end and re-armed on the next stage (a
  real travel), switch off, cleared on leaving the run. `--set measure=on` is the balance bot.
- `tools/preview/scenes/final-stand-fx.luau` (`layout-final-stand-fx-iphone`,
  `layout-final-stand-fx-phone-portrait`): aura on / off, one headline through UIState,
  Reduced effects, switch off, final frame with the banner for check_layout.

    python3 tools/run_regressions.py --only final-stand-regression,layout-final-stand-fx-iphone,layout-final-stand-fx-phone-portrait

Status: code type-checked (`tools/check.sh --quick` ok). Regression results: pending the
final check (the coordinator runs the full round). Studio / device: BLOCKED (offline only).
