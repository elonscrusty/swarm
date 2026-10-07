# Smarter first-run tutorial (`Config.Features.SmartTutorial`)

Status: built and type-checked, offline only, NOT tested in Studio.

## What
Seven tips over a player's first 2 runs, one at a time, each only when it is needed, in a
small speech bubble near the bottom centre (just above the ability tray). When a tip is about
a thing, the bubble's tail and a gold pointer aim at it. A bubble fades once its action is
done or after 8 s, and hides (and waits) while a panel covers the screen (UIState owner or
the stage-start card).

| # | Tip | When | Points at | Ends when |
|---|-----|------|-----------|-----------|
| 1 | Drag anywhere to move / WASD to move / Left stick to move | run start | - | hero walked 10 studs |
| 2 | Your weapon attacks by itself | first kill | weapon row | after 4 s |
| 3 | Pick up the blue gems for XP | a gem within 30 studs | the gem | XP bar moves |
| 4 | Choose an upgrade | first level-up | line under LEVEL UP! (cards stay free to pick) | panel closes |
| 5 | Hold E / Hold X / Hold the button to open chests | ready chest within 12 studs | the chest | chest opens |
| 6 | Find and charge the portal | 2 s after the reveal banner | the PORTAL arrow | charge starts |
| 7 | Bosses guard the way out | first boss arrival | boss bar | boss phase ends |

Touch says "Drag anywhere" rather than "Drag the left side": the thumbstick floats wherever
the thumb lands (MobileControls), so "anywhere" is the true instruction.
The co-op tips (Team run, Revive) use the same bubble. The old Move / Attack / Gems / Portal /
Boss callouts are replaced (not shown) while the switch is on, so nothing doubles up.

## Save
- `TutorialStep` (number, default 0): tutorial runs played. Each finished run adds 1;
  `TutorialDone` becomes true at `Config.Tutorial.Smart.Runs` (2), when all seven tips were
  seen, on SKIP, or after a DEV-tainted run. Additive, no schema bump; old saves keep their
  `TutorialDone`.
- Each tip shown is saved in `SeenTips` (server `Tutorial` remote "Seen"), so it never shows twice.
- Settings > REPLAY TIPS (existing button) is the "Replay tutorial" function: it resets
  `TutorialDone`, `SeenTips` and `TutorialStep`.

## Config
- `Config.Features.SmartTutorial = true` (off: the earlier callout tour, first run only).
- `Config.Tutorial.Smart`: `Runs = 2`, `Seconds = 8`, `AttackSeconds = 4`, `MoveStuds = 10`,
  `GemNearStuds = 30`, `ChestStuds = 12`, `GapSeconds = 0.8`. `Config.Tutorial.Tips` gained "Chest".

## Files
`src/client/Tutorial.lua` (triggers), `src/client/TutorialBubble.lua` (new, the bubble),
`src/client/InputPrompts.lua` (`MoveShort`, `OpenChest`), `src/server/Modules/GoldSystem.lua`
(profile + Seen/Replay), `src/server/Modules/RunManager.lua` (run count at commit),
`src/server/Modules/DataService.lua` (default).

## Tests
- `tools/preview/scenes/smart-tutorial-regression.luau`, registered in `tools/run_regressions.py`
  as a layout check on iphone, phone-portrait and pc:
  `python3 tools/run_regressions.py --only layout-smart-tutorial-regression-iphone,layout-smart-tutorial-regression-phone-portrait,layout-smart-tutorial-regression-pc` (or run the scene with
  `bash tools/preview/render.sh smart-tutorial-regression --device iphone`).
- `tools/preview/scenes/tutorial.luau --set smart=off` shows the old callout.

Expected: PASS offline (steps on the right events, once each, skipped when done, hidden behind
panels, bubble above the tray). BLOCKED: Studio playtest on the owner's phone (real touch,
Text size Largest, the real first-run flow).

Note: with the switch on, the second tutorial run also keeps `TutorialDone` false, so its
stage-1 portal reveal waits for the first upgrade pick (`RunManager.TutorialRevealHold`) and
its stage-start card is the longer first-run version.
