# JOURNEY audit (2026-10-05): join to results, interruptions, reward flow, cleanup

Scope: owner prompt sections 4, 7 and the historical leads in 14 (portal text, stage-clear
overlap, reel overflow, HP 46→40 during a reward panel, interruption counts), plus the
combinations in 15 (level-up during stage clear, chest reward during death, rewards queued,
restart after victory).
Baseline: `audit-baseline-2026-10-05` (b07d83b). Environment: offline Lune preview against the
Roblox mock, real server modules (and the real client where noted). No Studio, no device, no
live multi-client, no real teleport. Everything below is sim or static evidence, not production.

## Changed files

| File | Purpose | Risk | Recovery |
|---|---|---|---|
| `src/client/RunIntro.lua` | J-05: the stage card's clock waits while a covering panel (level-up, rare reveal, run menu) owns the screen, capped at 30 s in total, so the stage objective is still seen after the post-travel level-up. | Low (presentation; one `UIState.Covered()` read per frame while the card is up). | Revert the hunk. |
| `src/client/LootUI.lua` | J-07: `WindowFocusReleased` releases a chest / shrine hold in progress. | Low. A real alt-tab mid-hold now cancels (the player re-holds 0.4 s). | Remove the connection. |
| `src/server/Modules/RunManager.lua` | J-08 (SEC-15): a DEV command taints only the run its sender is in. J-09: `CommitInfo.NewBestScore` and `RunResult.NewBestScore` (score beat the saved `BestScore` / `BestScoreEndless`, not on the first scored run). | Low. Taint direction: a dev outside the run cannot affect it (DevTools run commands need a live run player). | Revert the hunks. |
| `src/client/UIBuilder.lua` (results badge only) | J-09: the existing NEW BEST badge reads "NEW BEST SCORE!" / "NEW BEST SCORE AND STAGE!" first. Same badge, same layout. | Low. | Revert the 4 lines. |
| `tools/preview/scenes/interrupt-sim.luau` | New measurement scene (interruptions, time unable to play). | None. | Delete. |
| `tools/preview/scenes/journey-regression.luau` | New regression (A-G, 40 checks). | None. | Delete. |
| `tools/preview/scenes/loot-focus-regression.luau` | New regression, real server + client. | None. | Delete. |
| `tools/preview/scenes/run-intro.luau`, `results.luau` | New `--set panel=on` / `--set bestscore=on` checks. | None. | Revert. |

Register in `tools/run_regressions.py` (lead edits):
- add `"journey-regression", "loot-focus-regression",` to the first name tuple; give
  `loot-focus-regression` the long timeout (`timeout=1500 if scene in (..., "loot-focus-regression")`);
- `checks += [("run-intro", ["stage=2", "panel=on"]), ("results", ["bestscore=on"])]` and add
  `"run-intro", "results"` to the tuple that removes `--set headless=on` (they drive the client UI);
- optional, not a pass/fail check: `interrupt-sim` is a measurement.

## Measurement: interruptions and time unable to play (interrupt-sim)

Command: `lune run tools/preview/runtime/main.luau -- --scene interrupt-sim --studio --device pc
--out <json> --set headless=on --set stages=3 --set explore=150 [--set players=2]`.
Model (labelled assumption): a steady player walks a circle, detours to a chest the purse covers
(every 20 s at most), charges the portal, fights the boss up close (force-killed after 90 s),
picks the first card of a panel after 2.0 s and each further round after 1.2 s, closes a rare
reveal after 2.6 s (the client reel's spin + reveal), answers the stage-clear dialog after
2.5 s. Hero invulnerable so both runs reach the same stages. One seed per mode (sample size 1
run each; treat as order of magnitude, not a distribution).

| | Solo (3 stages, 12.2 min, L37) | Duo (3 stages, 13.4 min, L34) |
|---|---|---|
| Level-up panels / rounds | 25 / 34 (1.36 rounds per panel) | 29 / 33 |
| Rare reveals (hold) / compact cards (no hold) | 5 / 22 | 1 shown as a card, no hold / 14 |
| Stage-clear dialogs / travels | 3 / 3 | 3 / 3 |
| Time unable to play | **84.0 s = 11.5 %**: choice 64.5, reveal 7.5, stage clear 8.2, travel 3.8 | **76.0 s = 9.5 %**: choice 64.0, stage clear 8.2, travel 3.8, mate never froze me |
| Blocking interruptions | 28 = **2.29 / min**, longest 10.5 s | 29 = 2.17 / min, longest 9.0 s |
| Headlines + notices (non-blocking) | 15 + 34 = 4.0 / min | 16 + 37 = 4.0 / min |
| First panel after each travel | 0.0 s, 0.0 s, 0.0 s | 0.0 s ×3 |

Historical lead (14): 38 upgrade rounds and 35 reels in 8:17 = 4.6 rounds/min and 4.2 reels/min.
Now (solo): 2.8 rounds/min and 0.4 rare reveals/min; the other 22 rewards are the compact
non-blocking card. Most of the remaining blocked time is the player's own card choice (by
design: meaningful choices kept). No change proposed to the level-up rate (MATH/ECONOMY area;
`levelrate-sim` / `pacing-sim` own it). The duo partner was never frozen by a mate's choice
(rule holds).

## Matrix

| ID | Subsystem | Expected (source) | Files / functions | Repro / start state | Actual | Evidence | Sev | Root cause | Fix / proposal | Status | Next check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| J-01 | Stage clear × level-up | No panel over the stage-clear dialog; levels kept; panel after travel (CHOICE_STATE deferral) | `LevelUpSystem.offerNext`, `StageManager.stepOpen/startTravel` | Solo, portal open, 2 levels queued, NEXT | Deferred "Portal", none during the fade, one panel run after the travel resolves every banked level | runtime (journey-regression A) | - | - | none | VERIFIED WORKING | Studio playtest |
| J-02 | Stage clear countdown × open solo choice | Countdown stops while the solo world is frozen | `StageManager.stepOpen` | Solo, panel open over the open portal | ChoiceLeft held, runs again after the pick | runtime (B) | - | - | none | VERIFIED WORKING | - |
| J-03 | Rewards queued | One hold, ≤ RewardPauseMax (7 s) even with a silent client; stale close ignored | `RunManager.HoldReward/Step`, RewardClose | 3 rare rewards at once | Hold capped, server released a silent client in 7.2 s (0.1 s step), latest close ends it at once | runtime (C) | - | - | none | VERIFIED WORKING | - |
| J-04 | Reward × level-up | No stacked blocking panels | `offerNext` deferral | Rare reward + 1 level | Panel waits for the reveal, then opens once | runtime (D) | - | - | none | VERIFIED WORKING | - |
| J-04b | Reward × death (lead "HP 46→40 with a reward panel open") | Solo rare reveal: world frozen, no damage; compact card never blocks input | `RefreshFrozen`, `DamagePlayer`, UIBuilder `present` | Lethal hit during a hold | No damage during the hold; after it the hero falls once, one result, no panel / freeze left. HP can drop while a compact card shows, by design: it is not a primary and movement stays on (REWARD.md); a duo reveal is a card too | runtime (E) + reward-once-regression E | - | Old full-screen reel on every chest (replaced in the overhaul) | none | VERIFIED WORKING | Studio |
| J-05 | Stage-start card × post-travel panel | The stage objective card is seen each stage (RunIntro) | `RunIntro.Update`, Theme.Z (card 19 < level-up 30) | Any stage with levels banked at the portal (every travel in both sims) | Panel opened 0.0 s after every travel; the 2.4 s card ran out under the level-up dim and was never readable | runtime (interrupt-sim; run-intro panel=on FAIL 2/4 before) | P2 | Card timer ran regardless of covering panels | Card clock waits while `UIState.Covered()` (cap 30 s) | VERIFIED FIXED (run-intro panel=on 4/4) | Studio look |
| J-06 | Restart after victory | Next run clean | `FinishFromPortal`, `returnAll`, `beginRun` | WinMinStages=1, win with 3 banked levels, StartRun | Fresh run player, stage 1 Explore, no offer / hold / deferral / portal / freeze / boss, level 1, clock runs | runtime (F) | - | - | none | VERIFIED WORKING | menu-sim cycles in Studio |
| J-07 | Chest hold × focus loss | Release early / focus loss → no open, no charge (prompt 7) | `LootUI` input, `LootSystem.onHold/Step` | E held, alt-tab before 0.4 s | Before: chest opened and charged (InputEnded never arrives on focus loss). After: stays Ready, no gold, no grant | runtime (loot-focus-regression FAIL 3/7 before, PASS 7/7 after) | P2 | No `WindowFocusReleased` handler | Release on focus loss | VERIFIED FIXED | Studio alt-tab |
| J-08 | DEV taint scope (SEC-15) | Taint only the dev's own run | `RunManager.devCommand` | Non-participant dev sends a DEV command during another run | Before: run tainted. After: untainted; a participant's command still taints | runtime (journey-regression G: FAIL before, PASS after) | P2 | Taint keyed to phase, not participation | Require a live run player | VERIFIED FIXED | - |
| J-09 | Results: new best score (ECONOMY) | Results say NEW BEST SCORE when the personal best is beaten | `saveRunStats`, `finishPlayer`, UIBuilder results badge | Saved BestScore 1, run ends | Before: no flag, badge only time / stage / level. After: `NewBestScore` true; not set below the saved best; badge "NEW BEST SCORE AND STAGE!" fits iphone + portrait | runtime (E/F checks) + render + check_layout 0 problems | P2 | Score best not compared | Flag + badge text | VERIFIED FIXED | Studio |
| J-10 | Duplicated portal heading (lead) | One heading | server `Broadcast` Id `portal.reveal` + StageUI same id, UIState merge | Portal reveal | One heading | uistate_regression (see tests) | - | fixed in overhaul | none | VERIFIED WORKING | - |
| J-11 | Reel overflow (lead) | Reveal fits on phones | UIBuilder reward reel `layoutChest` | rewards view=panel queue=on | see tests | render + check_layout | - | - | none | see tests | Studio phone |
| J-12 | Chest hold edge cases (static) | walk away, insufficient gold, panel opens, other player first, repeated hold | `LootSystem.check/onHold/Step/openChest`, `LootUI.Press/Release` | static + reward-once B | Server re-checks range, gold, state, Paused every frame; `setState("Opened")` before grant; spam refused | static + reward-once-regression | - | - | none | VERIFIED WORKING (offline) | touch/controller on device BLOCKED |
| J-13 | Disconnect during selection / save | Levels kept on rejoin | `Cancel(rp, true)`, `TryReconnect` | - | coop-regression rejoin variants, choice-regression | existing tests | - | - | none | NOT RUN here (baseline PASS 83/83) | live BLOCKED |
| J-14 | Duo transitions | Partner keeps playing; fallen mates revive on travel | `TravelPlayers`, `groupLive` | interrupt-sim duo | Mate never froze me; travel revives fallen players | runtime (duo sim) + static | - | - | none | VERIFIED WORKING (sim) | two clients BLOCKED |
| J-15 | Interruption rate | Measure (prompt 7) | - | interrupt-sim | see Measurement | runtime | - | - | Proposal only: none needed for flow; rate is a balance question | MEASURED | Owner playtest feel |

## Tests (offline; PASS / FAIL / BLOCKED / NOT RUN)

- `bash tools/check.sh --quick`: PASS.
- journey-regression: PASS (all checks A-G incl. J-09); G FAIL on the pre-fix RunManager.
- loot-focus-regression: PASS 7/7; pre-fix LootUI FAIL 3.
- run-intro `--set stage=2 --set panel=on`: PASS 4/4; pre-fix RunIntro FAIL 2.
- results `--set bestscore=on` iphone + phone-portrait: PASS, check_layout 0 problems.
- interrupt-sim solo and duo: measurement (above).
- ADJACENT: filled in below.
- BLOCKED: Studio, devices, touch / controller hardware, two-client duo, real teleports.

## Note for the lead
A WIP commit (3faf066 or neighbours) captured `LootUI.lua` and `RunIntro.lua` while I had the
baseline versions swapped in to prove the regressions fail before the fix. The working tree has
the fixed versions again (`git diff` shows the fix hunks); commit them.
