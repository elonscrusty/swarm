# POLISH (final phase): leftovers and register items

Offline only (preview renderer + Lune sims against the mock Roblox API). Nothing here was
tested in Studio, on a device or in a live multiplayer server.

## 1. accessibility-sim second error (FIXED, test)
- Observed: after "PASS accessibility settings..." the scene asserted
  `settings must fit the viewport or remain reachable by scrolling` (line 104).
- Root cause (observed): the test found the options list with `gui:FindFirstChild("Options", true)`,
  which since the PLAY sheet rebuild returns `MenuPlay`'s "Options" list (CanvasSize 0), not the
  run settings list that `UIBuilder.OpenRunSettings()` shows. The game was fine; the assumption was stale.
- Fix: `tools/preview/scenes/accessibility-sim.luau` takes the visible "Options" ScrollingFrame
  (every ancestor visible / enabled).
- Tests: accessibility-sim with and without headless: PASS, 0 errors.

## 2. Heart card dark bar (FIXED)
- The bar was the art panel's "Plinth" (`Choice.cardArt`, drawn when the panel is 100+ px tall).
  It showed on every upgrade card, and the floating picture never sat on it. Removed.
- Evidence: `levelup` iphone before/after; passive-only cards (Heart, Stoneskin, Might) on
  iphone, phone and phone-portrait; check_layout 0 problems.

## 3. Waiting text (FIXED)
- `StageUI.lua` stage-clear countdown: while `ChoiceLeftHeld` it reads
  "Waiting for <ChoosingNames> to choose · Ns" ("a teammate" if no name).
- `stage-choice` scene: new `--set held=on` prints `PASS held note: WAITING FOR BRYNN TO CHOOSE · 11S`; render checked.

## 4. UI state contract (DONE)
- `UI_STATE_CONTRACT.md` id table now lists every server `Id` from the Notify/Broadcast callers:
  boss.arrive / armor / banner, team.fallen / revived / left / rejoined.<UserId>, stage.objective,
  altar.guardians / unguarded / opened, nest.spawn / destroyed, shrine.bargain, run.curses,
  run.daily.scored, run.start.daily / endless, run.end, lobby.run.starting / lobby.arena.

## 5. menu-sim "new run after death" Alive=false (TEST ARTEFACT, test fixed)
- A solo death opens the revive offer (`AwaitingRevive`, `RevivePromptSeconds` 12 s). The run
  correctly stays in Running with Alive=false and the world waits. The script never declined
  it, so ReturnToLobby and StartRun were ignored; enemies=0 was the frozen downed run.
- Fix: the scene fires `ReviveDecline` (as the offer's button does) and asserts a fresh live
  run with its own results and spawns. Full menu-sim (4 cycles): PASS, 0 errors
  (12 enemies 5 s into the new run).

## 6. Results above the fold on landscape iPhone (FIXED on iphone)
- Slim (phone landscape) only: content/body gaps 10 → 6, content padding 24 → 14, screen margin
  24 → 12, title 34 → 30, medal 80 → 60, tiles 52 → 48, ledger cells 4 px shorter, progress
  cards ~14 px shorter (14 px bars), buttons 48 → 42, footer 40 → 36. `fitModal` now reads the
  content's real UIPadding (identical result for every other modal).
- iphone: ledger + all three progress cards fully visible; RUN DETAILS below "MORE BELOW".
  check_layout 0 problems on iphone, phone, phone-portrait and pc.
- Remaining: generic `phone` (844x390 with the 21 px top bar: 369 px usable) still needs
  about 15 px, so the progress cards start under the fold there.

## Register items (lead request)
| Id | Result |
|---|---|
| UI-30 | Disabled SKIP: "No skips left" |
| CP-02 | Solo branches by run player count: altar (benefit, unguarded, opened), caravan (benefit, results); StageUI READY sub "Traveling..." in solo |
| CP-03 | RunIntro close prompt from `InputPrompts.ToClose()` + `OnChanged` refresh (the reel already used InputPrompts) |
| CP-05 | "Optional: defend the caravan!..." broadcast; bar "OPTIONAL · DEFEND THE CARAVAN" (short form when narrow; caravan-sim show=defend iphone render fits); result lines add "Back to the portal!" |
| CP-09 | Passive change box caption "TOTAL <STAT>"; the line under the name keeps the added amount. Compact phone rows are unchanged (no room) |
| CP-11 | Card hint on a soft plate with a gold edge, brighter text; same text |
| CP-16 | RUN DETAILS: "Last hit: <cause> (N damage)" + "Before that: X n, Y n"; `results --set outcome=defeat --set details=open` PASS |
| UI-11 | No change needed: probe on the real server, solo stage 1: first wave at 4.0 s, 60 studs out, nearest enemy 50 studs at 6 s, no DamagePlayer call in 10 s; the card lasts 2.4-5 s and is not Active. Later stages: DespawnAll on travel + 6 s StageStartDelay. The run clock does tick. Group runs use the same timing (reasoned, not simulated) |

ISSUE_REGISTER rows and ACCEPTANCE #33 / #37 updated (PASS offline; fresh account BLOCKED).

## Final checks (all offline)
- `check.sh --quick`: clean.
- ui_regression phone + phone-portrait: PASS. uistate_regression: all passed.
- results-flow case=auto (client running): ALL PASS. accessibility-sim (both modes): PASS.
- Layout (menu, levelup, results, pause, revive, stage-choice, characters, countdown × iphone,
  phone-portrait): 0 problems.

## For others
- Studio-only: on iphone the JUMP button overlaps the DEV button (caravan-sim render, `--studio`).
  Not seen by players.
