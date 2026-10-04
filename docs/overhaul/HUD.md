# HUD: approved 02 Desktop HUD and 03 Mobile HUD

Owner area: HUD (overhaul phase 1). Issues: UI-17 to UI-27, UI-62, UI-64 (docs/overhaul/ISSUE_REGISTER.md).
Everything below was checked offline (preview renderer, Lune regressions). Nothing here was
tested in Studio, on a real phone, with a gamepad or in a real multiplayer session.

## What I inspected

- Approved images `01_Approved_UI/02_Desktop_HUD.png`, `03_Mobile_HUD.png` and the reference guide
  (tokens: slate #172029, gold #BDA15F, ivory #F2ECD9, crimson HP #A3313B, cyan XP #64B7CB).
- Review sections "Opening instructions and objective guidance", "Combat HUD", "Rewards and results"
  and frames short/013s, short/027s.
- Code: `src/client/Hud.lua` (layout, vitals, objective, tray), `StageUI.lua` (portal marker, wave
  edges), `MiniMap.lua`, `MobileControls.lua`, `LootUI.lua` strip layout, `UIBuilder.lua` insets.
- Baseline renders (before) for arena, boss, team, loot on pc, iphone and phone-portrait:
  `scratchpad/wf/hud/before/`.

## Findings (observed vs suspected)

| Issue | Finding |
|---|---|
| UI-17 timer vs HP | Observed: HP/XP sat in a wide panel under the timer at top centre, the objective was a pill top left. Approved 02/03 put vitals top left and the objective under the timer. |
| UI-18 early tray | Observed: 12 empty slots drawn from the first second (a 6+6 strip for one weapon). |
| UI-19 three places to look | Observed: objective top left, marker near the tray, minimap top right. Now objective is top centre under the timer, the marker clamps to the screen edge and avoids the corner panels, the minimap uses the same word. Comprehension is still BLOCKED (no player test). |
| UI-20 minimap legend | Observed: legend called the portal "Exit" with a bare diamond, the same shape as a shrine; 9 px labels. |
| UI-21 reddish edge | **Verified in code**: the crimson edge at full HP (short/013s, bottom edge only, 0:04 run time) is StageUI's **wave-direction glow** (`flashEdge`, wave 1 "from the south"). The Hud vignette (`HurtVignette`) only fires on a hit (`Hud.Hurt`) and at low health (`LowHealthFraction` 0.3). Two meanings shared one colour. |
| UI-23 items vs weapons/passives | Observed: weapons/passives had no in-run inspection at all; items only via pause > ITEMS. Tiles are deliberately non-Active (the floating thumbstick works through them). |
| UI-24 dense late build | Observed: 6+6 tray fits; ranks badge readable; the item strip wraps under the vitals. |
| UI-25 mobile | Code: insets already come from the real `GuiService.TopbarInset` plus `ScreenInsets.DeviceSafeInsets` (UIBuilder `computeInsets`); controls are the game's own floating thumbstick + JUMP (Roblox default controls are disabled), no native control is duplicated. |
| UI-27 marker | Observed: marker badge + distance; it could land on the vitals or the minimap. |
| Portal vs Exit | "Exit" appeared only in the minimap legend (`MiniMap.lua`). Everything else says Portal. |
| Distance units | World markers (portal, caravan, fallen teammate) all say "m" for studs; some item/hero copy says "studs" (ItemData, CharacterData, StatSheet). Not changed here (copy owner). |

## Changes

`src/client/Hud.lua` (layout only; UISTATE's banner/headline code untouched)
- Vitals panel top left under the Roblox buttons (landscape), centred under the objective in
  portrait; width 380 (phones x0.76). XP bar is now cyan (local `XP_GRADIENT`, approved token),
  text "169 / 306 XP" ("Gold: ..." once levels pay coins).
- Objective panel under the timer: gold caption "FOREST · STAGE 2 · WAVE 6" (Endless: "ENDLESS ·
  STAGE n"; arena name dropped when it does not fit) over one persistent objective sentence in
  the serif heading ("Find the portal", "Portal dormant · 0:26", "Opening the portal · 60%",
  "Open the portal · swarm growing", "Defeat the Scorpion Queen", "Survive the surge · 0:20",
  "Portal open · step in"). Shrinks before it truncates (TextScaled + size cap). The old "calm"
  rule that hid the objective after 8 s is gone: the objective slot never hides.
- Width of the objective is computed from the room between the vitals and the minimap column.
- Boss bar under the objective, kept clear of the left column.
- Tray: quiet "+" empty slots; it shows owned + 1 free slot (min 3) and grows with the build.
- BUILD column at the tray's right end (also B key / gamepad Y): opens **build details**: every
  weapon (name, EVOLVED / MAX / LV n / 12, effect), passive (LV n / max, effect) and item (count,
  existing rarity, effect), with "WEAPONS 4 / 6" capacity. Non-modal ("The run keeps going while
  this is open"), its own layer above the HUD and world markers, Active so taps on it do not walk
  the hero; tiles stay non-Active. Closes on BUILD / X / B / Y, on any covering overlay
  (`SetCovered`), on leaving the run. While open it sets `UIState.SetHold("Build")` so routine
  headlines wait; critical ones still show.
- Elements for others: `LeftBottom`, `LeftWidth` (left column), `TopBottom`, `BarTop`.

`src/client/MiniMap.lua`: legend "Exit" -> "Portal" with the marker's own diamond-in-a-ring key
(a shrine is a bare diamond), labels 10 px; desktop map 150 -> 180 px.

`src/client/StageUI.lua`: wave-direction edge glow is amber (was crimson) so crimson at the screen
edge only means "you are hurt / low health"; the portal edge marker drops below the vitals/item
column and the minimap instead of covering them (`clearCornerPanels`).

`src/client/LootUI.lua` (strip layout lines only, `LootUI.Layout`): the item strip, chips and
popups follow the vitals column (`els.LeftWidth`) instead of the space left of the old centred panel.

`tools/preview/scenes/hud-build.luau` (new, documented in docs/PREVIEW.md): full 6+6 build, stacked
items, wave 6, portal marker, build details open; `--set early=on`, `--set build=off`.

`tools/ui_regression.luau`: +3 checks (build details list all three categories; a covering
decision closes them; minimap legend says Portal).

MobileControls.lua: no change needed (JUMP bottom right inside the safe area, LeftHanded mirror;
the tray already reserves the JUMP column on both sides).

## Verification

RESULTS_PLACEHOLDER

## Side-by-sides

`scratchpad/wf/hud/sbs-desktop.png` (02 vs hud-build pc), `scratchpad/wf/hud/sbs-mobile.png`
(03 vs hud-build iphone).

## Remaining differences and risks

- Mockup 03 shows an INTERACT button bottom right; the game uses JUMP plus the loot prompt's own
  HOLD button. Not added (no new control scheme from an illustrative mockup).
- Mockup items row has an "ITEMS" label; ours is the existing LootUI strip (no label) under the vitals.
- Mockup tray always shows 6 slots; ours shows owned + 1 (min 3) to satisfy the quieter-early-tray
  finding; capacity is stated in the build details.
- The pause button is the run menu (approved 07 drawer is another helper's).
- Real-device checks are BLOCKED: notch/home-indicator insets, thumb reach, tablet split view,
  orientation change, gamepad Y focus, B key conflicts with other games' habits.
- A headline already showing when BUILD opens finishes under the panel; new routine ones wait.
- Distance units: "m" on world markers vs "studs" in some copy (FOR COPY).
