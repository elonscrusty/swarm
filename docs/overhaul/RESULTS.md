# RESULTS: run results screen to approved screen 06

Owner: RESULTS helper (phase 2). Scope: the results section of `src/client/UIBuilder.lua` only.
Offline preview and Lune sims only. NOT tested in Studio, on a device or live multiplayer.

Side by side (approved 06 left, PC loss render right):
`scratchpad/results/results-side-by-side.png`
(scratchpad = /tmp/claude-0/-home-user-swarm/587c5e35-da3e-5580-abb3-5cc8b9f0c56b/scratchpad).
Renders: `scratchpad/results/ledger-{loss,win}-{pc,iphone,phone-portrait}.png` (+ .json).

## What the screen shows
- Header: hero medallion, DEFEATED / VICTORY! / ESCAPED / RUN ENDED, "HERO · ARENA · STAGE", damage and score.
- Four tiles: survived, enemies defeated, stages cleared, boss state.
- Gold ledger (from RunResult, server values only):
  - EARNED (gross) = GoldEarned + GoldSpent
  - SPENT = GoldSpent (chests, shrines)
  - UNSPENT / GOLD AT DEFEAT = GoldEarned
  - KEPT · N% = Gold (rate from GoldRetention)
  - BONUSES = GoldSurvival + FirstRun.Bonus
  - Note line: "Added to your gold" total, gold lost. On a loss it also states the real rule from
    `Config.Gold` / `GoldSystem.RetentionRate`: 35% + 15% per stage cleared, max 85%. A portal
    keeps everything.
- Three separate progress cards, never merged: RUN LEVEL (temporary, steel bar), HERO MASTERY
  (per hero, gold bar), ACCOUNT LEVEL (cosmetic only, cyan bar, animated).
- RUN DETAILS (collapsed), NEXT GOAL pinned above REPLAY / MAIN MENU, footer with the single
  countdown, STAY and REPORT A BUG (FLOW's return flow unchanged).
- Sounds: Victory on a win, ResultsLose on a defeat or a run left early (none on a portal escape).

## Changes this pass
Most of the layout came from the earlier RESULTS helper (WIP commits 173e9a2, 54f9c4b). This
pass added the loss rule line to the ledger note (`fillLedger`). No new top-level locals.

## Tests (offline)
- `tools/check.sh --quick`: PASS (typecheck, compile, art keys).
- results-flow auto/stay/replay/portal/plain: PASS (8/10/4/5/5 checks) when run without
  `--set headless=on`. With headless=on (as `tools/run_regressions.py` passes it) the client
  never starts and every case FAILS: the runner needs results-flow exempted from headless.
- ui_regression phone and phone-portrait: PASS.
- results-ledger renders, loss and win on pc / iphone / phone-portrait: scene checks PASS,
  check_layout 0 problems (only "small text" notes on phones).

## Remaining risk
- Landscape iPhone: the ledger and progress cards sit below the fold (MORE BELOW, scroll).
- Screen 06 puts RUN LEVEL as the fourth tile; we keep the boss tile and show run level in its
  own card.
