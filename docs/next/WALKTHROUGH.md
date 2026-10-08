# Interactive first-run walkthrough (`Config.Features.Walkthrough`)

Status: built and type-checked, offline only. NOT run in the preview yet (the lead runs the
regression round) and NOT tested in Studio.

## What
Owner request: "Can the beginning tutorial not just be a bunch of text how to play but an
interactive walkthrough". On a player's first solo run the game now waits for the player to
do each thing, one step at a time. The tutorial speech bubble shows a short line, and its
pointer aims at the thing.

| # | Step | Line | Points at | Done when | Timeout |
|---|------|------|-----------|-----------|---------|
| 1 | Move | "Drag to walk into the gold ring!" (WASD / left stick on pc / gamepad) | gold ground ring + bouncing arrow, ~15 studs away in open ground | hero stands in the ring | 45 s |
| 2 | Fight | "Your weapon attacks by itself. Beat the bugs! 2/5" | nearest of 5 weak, slow Mites (~20 studs away) | all 5 beaten | 45 s (the rest are killed for you) |
| 3 | Gems | "Pick up the blue gems!" | nearest gem | the first level-up opens | 30 s (gems fly to you) |
| 4 | Upgrade | "Pick an upgrade!" (line under LEVEL UP!, the cards stay free to pick) | the cards | a card is picked | 45 s |
| 5 | Chest | "Open the chest! Hold E" / "Hold X" / "Hold the button" | free chest (~12 studs) + bouncing arrow | the chest is opened | 45 s (the chest stays) |
| 6 | Go | "Waves are coming! Find the portal." | the PORTAL arrow | 6 s later the walkthrough ends | - |

Until step 6 no normal wave comes and the stage-1 portal stays hidden. At step 6 the first
wave comes within 4 s and the portal appears about 1 s later. After that the usual tips
(portal, boss) carry on as before.

- Timeouts count run time only, so the pause menu, the upgrade cards and travel stop them.
- If the 5 kills don't drop enough XP for the first level, a top-up gem is dropped next to
  the hero (checked against `Config.FirstRun.FirstLevelXP`, the first-run level cost).
- The free chest is a normal Small chest with no price (`LootSystem.AddFeatureChest`). The
  loot system opens it exactly once, and its reward is a normal Small chest item. It is free
  only on the account's first walkthrough: on a Replay tips run the chest has its normal
  price, so replaying can't hand out a free chest every run.
- The SmartTutorial tips the walkthrough teaches by doing (Move, Attack, Gems, LevelUp, Chest)
  are marked seen when it starts, so they never show after it.
- Death, leaving (MAIN MENU), DEV tools, switching tips off or the run ending stop it
  cleanly. Every hold is let go and the step attributes are cleared. Its enemies and the
  chest stay as normal objects.

## Who gets it
The same gate as the first-run flow: `Config.FirstRun.AutoStart` on, Solo, Standard
difficulty, no curses, Endless or Daily, not DEV-tainted, tips on. On top of that, either the
account's very first run (`Stats.Runs` 0, `TutorialDone` false) or Settings > Replay tips.
Co-op never runs it. It is marked done when it starts, so it never runs twice, even if that
run is cut short.

## Save (additive, no schema bump)
- `WalkthroughDone` (bool, default false): set when the walkthrough starts.
- `WalkthroughReplay` (bool, default false): set by Settings > Replay tips and cleared when
  the walkthrough starts. Older saves have `Stats.Runs > 0`, so they only get it through
  Replay tips.

## Config (`Config.Walkthrough`)
RingDistance 15, RingRadius 4.5, RingClearance 5, EnemyType "Slime", EnemyCount 5,
EnemyDistance 20, EnemyHP 4, EnemySpeedMult 0.45, EnemyDamageMult 0.3, GemRadius 45,
ChestDistance 12, ChestType "Small", GoSeconds 6, ReleaseWaveDelay 4,
Timeouts { Move 45, Fight 45, Gems 30, Upgrade 45, Chest 45 }.
Switch: `Config.Features.Walkthrough = true`. With it off the game behaves exactly as before.

## Code
- `src/server/Modules/Walkthrough.lua`: the step machine (`Consider`, `Step`, `HoldsReveal`,
  `Current`). It is in GameServer's ORDER and runs as a STEPS entry before EnemySpawner.
- Hooks: `RunManager.beginRun` calls `Walkthrough.Consider` before `Stats.Runs` counts the
  run. `EnemySpawner.SetHold(reason, on, delay)` and `EnemySpawner.Holds` keep the wave
  breather waiting. `StageManager` tutorialHold asks `Walkthrough.HoldsReveal()`.
  `XPSystem.ValueNear` does the top-up check. GoldSystem's "Replay" sets `WalkthroughReplay`.
- Replication: player attributes `Walkthrough` (step), `WalkCount` / `WalkTotal`,
  `WalkTarget` (Vector3).
- Client: `src/client/WalkthroughClient.lua` drives the bubble's line, its pointer (world
  positions projected to the screen) and the world marker (a gold neon ground ring plus a
  bouncing gold arrow billboard). `Tutorial.lua` hands it the bubble while it runs.
- `firstjoin-sim` and `portal-reveal-sim` switch the walkthrough off, because they test the
  first-run flow without it.

## Regression
`tools/preview/scenes/walkthrough-regression.luau` (registered in `tools/run_regressions.py`):

    lune run tools/preview/runtime/main.luau -- --scene walkthrough-regression --studio --device pc --out /tmp/wt.json --set headless=on

It checks: step order on the first run (ring by teleport, kills, gem pickup into the first
level, card pick, chest hold); waves and the reveal held, then released at Go; the free chest
pays exactly once and costs no gold; the next run never runs it; Replay tips runs it again,
where doing nothing times every step out in order and pause freezes it; leaving ends it
cleanly; co-op never runs it. The scene is server-only, so the client bubble and markers are
not covered by it.

## Expected PASS / BLOCKED
- PASS expected (offline): walkthrough-regression, firstjoin-sim, portal-reveal-sim.
- BLOCKED (owner, Studio): play a fresh account's first run on the phone. Check that the
  ring, arrow and bubble read clearly, that the Mites are easy, and that the chest prompt
  appears.
