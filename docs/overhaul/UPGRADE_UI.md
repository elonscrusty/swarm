# Upgrade choice panel (UPGRADE-UI, phase 2)

Owner: UPGRADE-UI. Code: the level-up section of `src/client/UIBuilder.lua` (from
"Level-up screen" to "Chest reward"), plus the `group` / `paused` options of
`tools/preview/scenes/levelup.luau`. Reference: `01_Approved_UI/04_Upgrade_Choice.png`.
Server contract: `docs/overhaul/CHOICE_STATE.md`. State owner: `docs/overhaul/UI_STATE_CONTRACT.md` (`LevelUp`, 70).

Status: type-checked, compiled, offline previews rendered. NOT tested in Studio, on a device or in a live duo.

## Side by side with screen 04

| Screen 04 | Built | Notes |
|---|---|---|
| CHOOSE YOUR UPGRADE, gold serif, rule with a diamond | Same (was "LEVEL UP!") | Size fits the screen width (46 pc, down to ~26 on phone portrait) |
| LEVEL 2 • PICK ONE | `LEVEL 14  •  PICK ONE  •  1 OF 4` | Round count added when a panel holds merged rounds. Hidden on phones in landscape (no room); the tutorial line replaces it on the first run |
| AUTO-PICK IN 24s pill | Same, from `ChoiceProtectedUntil` | `AUTO-PICK ALL 3 IN 24s` when several rounds are left (they are all auto-picked at zero, as CHOICE-SERVER asked to disclose); `TIMER PAUSED · 18s` while `ChoiceTimerPaused`; `· TEAM KEEPS PLAYING` in group runs. The old gold countdown bar is gone (not in 04) |
| Tab on the card top: NEW PASSIVE / UPGRADE • LV 1 → 2 | Same; `FINAL UPGRADE · LV 11 → 12` on a last rank; `/ max` added where it fits | "MAX LEVEL" is gone. "Maxed" is never shown: a capped item is never offered |
| Large item art over a tinted backdrop | Art panel: item picture, backdrop tinted with the item's own `Color`, soft glow, plinth | Tint is a theme, not a rarity. Uses the existing icon art (we have no bespoke card paintings), so it is flatter than the concept |
| Sculpted frame, corner gems | Slate frame, steel-tinted border, four gold corner gems | Close, simpler |
| Serif name + one-line effect | Same (server `Summary` on upgrades, description on NEW cards) | NEW weapon descriptions can take two lines on PC |
| Box: stat label, `+0% → +8%` with the new value mint | Same box (`changeBox`), extra changes as rows | NEW weapons keep their starting-stat rows instead of a box (more truthful than one number) |
| `[1] CHOOSE` plate | Same plate with the 1/2/3 key | Shown on every device |
| Highlighted card: gold frame + glow | Focus (hover, gamepad, the pick): 3.5 px gold border, glow, warm tint, plate rim brightens | Border thickness changes too, so focus is not colour only |
| REROLL 1 left / SKIP 0 left | Kept (`2 left · 3 new cards`, `1 left · +10 gold`, disabled when 0) | |
| Footer "how to choose" | `InputPrompts.Choose` (COPY) | Hidden on phones in landscape |

Portrait phones keep the stacked wide cards (no room for three tall cards); their band now
reads the kind and rank (`UPGRADE · LV 5 → 6 / 12`, `FINAL UPGRADE ...`).

## Behaviour

- Picks send `LevelUpChoose(index, OfferId)`; reroll and skip send `OfferId` (it was not
  actually sent before this pass, despite the brief).
- Countdown: `ChoiceProtectedUntil - workspace:GetServerTimeNow()`, frozen at its value while
  `ChoiceTimerPaused`; falls back to the offer's `Seconds` when the attribute is missing.
  Group: `ChoiceGroup` attribute (or the offer's `Group`).
- Safe input unchanged: 0.35 s arm and fresh-press rule for keys/mouse/gamepad, touch arm
  0.8 s, thumb-zone/JUMP guard 1.2 s, whole-tap rule, dimmed cards with an arm sweep.
- 1/2/3 keys and gamepad focus unchanged.
- Sounds: `ChoiceOpen` when a new panel opens, `CardAppear` when the next round or a reroll
  brings new cards into the same panel, `ChoicePick` on a pick (replaces the generic click).
- No change to the offer, weights, weapon evolution or fusion.
- The new helpers sit in one `Choice` table: UIBuilder had reached Luau's 200-local limit
  (the compiler failed with "Out of local registers" while I worked).

## Tests (offline)

| Test | Result |
|---|---|
| `bash tools/check.sh --quick` | PASS (0 diagnostics, compile ok) |
| Renders `levelup` pc, iphone, phone-portrait, tablet (`images=loaded`) | Rendered, checked by eye |
| Render `levelup` iphone `group=on cards=Whip:12+passive:Heart+Longbow` | FINAL UPGRADE tab, NEW PASSIVE, team pill: OK |
| `check_layout.py` on all of the above | 0 problems (only SMALL info on phone portrait) |
| `ui_regression` phone / phone-portrait | Every level-up check PASS (entrance, no repeat entrance, touch reroll guard, early tap, thumb zone, long press, single pick). One FAIL: "ordinary chest only plays the non-blocking mini reel", see below |
| `uistate_regression` | PASS |
| `choice-regression` | PASS |

The chest FAIL is not from this panel. The whole file from 275c152 passes. The current file
with only its level-up section swapped back to 275c152 still fails. So the cause is in the
reward or reel code (REWARD's area).

BLOCKED: Studio, real touch devices, gamepad hardware, live duo/trio timing.

## Remaining risk

- On phones in landscape the art panel is short (72 reference px), so the pictures are small.
  Cards with many rows lose their last rows before the art shrinks further.
- The art is the existing icon set, not painted card art like 04.
- On phones the one-line summary of a busy upgrade is cut off with "..."; the rows under it
  carry the full numbers.
