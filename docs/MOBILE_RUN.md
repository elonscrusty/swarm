# Mobile in-run fix (2026-10-06)

The owner played a run on a real iPhone (852 x 393 pt at 3x, landscape) and sent four
in-run screenshots (scratchpad `mobile-shots/10..13`): "More interface issue I need you to
fix". The lobby screens are covered by docs/MOBILE_FIX.md (MOBILE-LEAD), which also
explains the two causes: Roblox's **Text size** accessibility setting (about 1.6x on the
owner's phone, plain `TextSize` labels only, never `TextScaled` ones or past a
`UITextSizeConstraint.MaxTextSize`) and `GuiService.TopbarInset` reported in safe-area X
space on the iPhone.

Status: offline preview + regressions only. NOT verified on a device or in Studio.

## What changed

The approach: a label in a fixed box becomes `TextScaled` with its own
`UITextSizeConstraint` named `Fit` (max = the designed size, a small minimum) and the
attribute `NoTextFit` (TextFit then leaves it alone). Text can only shrink to fit its box,
whatever the player's Text size setting is.

| Problem (owner's shot) | Fix | Where |
|---|---|---|
| ULT draws on top of the run menu drawer | FeatureHud hides under any shown panel (`UIState.Owner() ~= nil`), not only covering ones | `FeatureHud.lua` |
| DEV draws on LEAVE RUN | the DEV button hides while a panel is shown (unless the dev panel itself is open) | `DevPanel.lua` |
| JUMP overlaps DEV | on touch screens DEV sits just above JUMP (Config.Movement ButtonSize / ButtonMargin, Compact touch layout 0.8x); left-handed layouts keep the corner | `DevPanel.lua` |
| "SOLO · GAME PAUSED" spills out of its pill | pill wider estimate; the text shrinks inside it | `UIBuilder.lua` run menu |
| "The run is paused while this" cut off | the note shrinks to fit its box (wrapped); the line estimate is a bit wider | `UIBuilder.lua` run menu |
| LEAVE RUN cut off at the bottom | short screens squeeze in order: crest, the top-right inset (wrong on iPhones, the top right is free), shorter buttons, SETTINGS + VIEW BUILD on one row, a shorter note box, tighter gaps; the hint only shows when it fits | `UIBuilder.lua` run menu |
| "Paused" banner over the portal marker | no "Paused" status line while this player's own run menu is open (the drawer says it); the portal marker hides while the run menu is open | `Hud.lua`, `StageUI.lua` |
| "WEAP" / "PASSI" tray labels | the row words shrink to fit the label column | `Hud.lua` |
| "BUILD" spills out of the tray | the word shrinks inside the BUILD column | `Hud.lua` |
| "139 m" sits on the tray | the marker keeps its badge + distance label 66 px above the tray (was 48); the distance text shrinks inside its box | `StageUI.lua` |
| Card descriptions cut | the description shrinks to fit its lines (min 10 px); the line estimate is a bit wider | `UIBuilder.lua` level-up |
| REROLL "1 left · 3..." | phones in landscape say "1 left" (SKIP "1 left · +N"); both buttons' words shrink to fit | `UIBuilder.lua` level-up |
| CHOOSE YOUR UPGRADE under the Roblox buttons | in landscape, when the title is level with the top bar its box stays clear of the buttons on both sides (centred), using the larger of `insets.Left` and `TopbarInset.Min.X` (`Choice.topbarLeft`); the title shrinks to fit | `UIBuilder.lua` level-up |

No new top-level locals in UIBuilder (helpers live in `runMenu` / `Choice`).

## Verified (offline)

See the results section below.

## Owner check on the phone

1. Start a solo run, open the run menu (pause button): no ULT or DEV over the drawer, the
   pill text inside its outline, the full note, LEAVE RUN fully on screen.
2. In play: WEAPONS / PASSIVES / BUILD readable inside the tray; DEV above JUMP; the
   portal marker never on the tray.
3. Level up: CHOOSE YOUR UPGRADE clear of the Roblox buttons, full card descriptions,
   REROLL "1 left".
