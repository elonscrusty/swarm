# UISTATE: interface state coordination (master prompt §4, first half)

Contract for other helpers: `docs/overhaul/UI_STATE_CONTRACT.md`. This file is the evidence log.
Nothing here was tested in Studio or on a device.

## What I inspected
- Evidence frames Short 0:13, 0:14, 0:50, 1:25 and Long 8:12, 9:02, 9:10 (02_Review/evidence).
- Producers: `UIBuilder` show/hide/setCovering, `UIBuilder.Toast` (pill stack AND a second
  big-banner band), remote `Notify` (RunManager.Broadcast / Notify: ~70 call sites),
  `Hud.Announce` + its private banner queue, `StageUI` (portal reveal, waves, pressure, stage
  clear panel, travel fade), `LootUI` (loot prompt, hold, caravan bar), `RunIntro`,
  `BugReportUI`, `DevInbox`, server `LevelUpSystem.offerNext` / `StageManager.stepOpen`.

## Root causes (observed in code)
| Case | Root cause |
|---|---|
| Duplicate portal heading (Short 0:13/0:14, Long 9:10) | Two banner systems for one event: the server's `Broadcast("THE PORTAL HAS APPEARED", big)` drew `UIBuilder.Toast`'s band banner, and StageUI's `PortalReveal` watcher drew Hud's banner. No shared id. |
| Caravan toast over its panel (Short 0:50) | The toast list sat at `Hud.TopBottom()+6`, ignoring `Hud.ReserveCentre` bars (only the banner respected them); and the toast repeated what the bar says. |
| Elite toast over the wave headline (Short 1:25) | Toasts and the centre banner had independent positions; nothing knew the other was up. |
| Four stacked notices (Long 8:12) | Toast stack capped at 4, no coalescing of the same event. |
| Upgrade over the Stage 2 clear dialog (Long 9:02) | `show()` only toggled visibility/covering; two modals could both be visible. Server: a level-up panel already open absorbs portal-vacuum XP while StageManager opens the portal choice. |
| Reel + portal headings + chest prompt (Long 9:10) | Portal duplicate (above) + banners not held during reward feedback + loot prompt shown for the opened chest during its own reward. |

## Changes (files)
- NEW `src/client/UIState.lua`: primary overlays (priority, suspend/resume, stacking sub-panels,
  owner listeners, watchdog), headline lane (dedupe, merge twins, settle, expiry, holds),
  notice lane (max 2 phone / 3 PC, coalesce "x2", expiry, Critical/Info/Player classes),
  `Classify`/`FromServer` for `Notify`, `Reset`.
- `src/client/UIBuilder.lua` (plumbing only): `show`/`hide`/`setCovering` go through UIState;
  covering and thumbstick follow the owner; toasts are the notice renderer (old band banner
  removed); `Notify` -> `UIState.FromServer`; achievements -> notice id `achievement`;
  run menu refused while a higher panel is open; per-frame Step/Audit/toast placement;
  Reset on InRun and Alive changes.
- `src/client/Hud.lua` (banner only): the banner is the headline renderer (own queue removed);
  `Hud.Announce(title, sub, color, sound, id?, class?)`; stage banner id `stage.N`;
  `Hud.HeadlineBottom()`.
- `src/client/StageUI.lua`: semantic ids/classes on its headlines; travel = `Travel` primary +
  Reset; stage-clear open checks use `UIState.IsOpen("Portal")` (a suspended panel still closes
  when the stage leaves Open).
- `src/client/LootUI.lua`: loot prompt hidden and hold/purchase refused unless
  `UIState.WorldInputAllowed()`; a hold in progress is released when a panel takes input.
- NEW `tools/uistate_regression.luau` (34 checks), NEW scene `tools/preview/scenes/ui-stack.luau`.

- Coordinator rule added for HUD (loot-scene collisions): informational headlines hold while a
  loot prompt or item popup shows (LootUI sets holds `Prompt` / `ItemPopup`) and one already up
  is taken off; portal reveal waits up to 15 s.

## Tests run (offline only; NOT Studio / device / live multiplayer)
- `bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok. PASS
- `lune run tools/uistate_regression.luau`: 34/34 PASS (all six proven cases as state logic,
  stacking, expiry, watchdog, reset, prompt hold/cancel).
- `lune run tools/ui_regression.luau phone` / `phone-portrait`: 30/30 PASS each.
- Renders `ui-stack` (iphone unless noted), real client UI against the preview mock:
  - portal: 1 heading "THE PORTAL HAS APPEARED" with the client sub line (was 2). PASS
  - caravan: defence bar + WAVE 4 headline, 0 notice pills (caravan toast suppressed). PASS
  - elite: SWARM IS GROWING headline, elite pill directly under it, altar info pill waiting. PASS
  - stack: 2 pills, the two elites coalesced "x2" (was 4 stacked). PASS
  - levelup: `LevelUp(shown), Portal(suspended)`; pc + closeup: after the choice `Portal(shown)`. PASS
  - reel (pc, after=on): during the reward 0 portal headings + no chest prompt; after it 1
    heading + prompt back. PASS
- `check_layout.py` on ui-stack stack/elite/caravan/reel (iphone), loot (iphone,
  phone-portrait), rewards (iphone): 0 problems. PASS
- menu-sim cycles=1 headless: lobby -> run -> pause -> MAIN MENU -> death -> results -> lobby,
  0 errors. PASS (headless: no GUI exercised); GUI menu-sim: see the final report.

## Remaining risk
- Critical notices during a headline sit under it, near the hero on phones (~2.4 s).
- Group runs: the portal ChoiceLeft countdown keeps running while a player's upgrade panel
  suspends the stage-clear panel (server rule, CHOICE-SERVER).
- A full reward reveal suspended behind a higher panel keeps playing hidden (presentation only).
- The mini reel is not hidden under a covering panel (unchanged).
- Notify classification is text-based until the server sends `Id` (FOR OTHERS).
