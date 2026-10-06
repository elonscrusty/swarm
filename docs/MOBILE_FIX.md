# Mobile menu fix (2026-10-06)

## Wrap-up status (2026-10-06, tonight's update)

Owner's scope for tonight: home, play, characters, the run menu and the level-up cards, plus
the shared BACK button / top-bar fix. Offline preview only (iphone profile with Roblox Text
size = Largest, the owner's phone): NOT checked on a device or in Studio. Side-by-sides
(owner shot vs render): scratchpad `wrapup/side/` (9-home, 6-play-top, 5-characters,
10-runmenu, 13-levelup).

| Screen (shot) | Problem | Now |
|---|---|---|
| all sub-screens | BACK cut to "BA..." | fixed (TextFit, shared) |
| characters (5) | BACK under the Roblox chat button | fixed (TopbarInset X space, shared) |
| home (9) | ACCOUNT pill dropped below the top bar, "ACCOUNT / LV 7" overlapping | fixed |
| play (6) | "Change in...", "Desert at...", "clear...", "found on..." cut | fixed |
| characters (5) | "Alch...", "Engi...", "Necro...", "KNIGHT...", rows overlapping | fixed; portrait tabs shrink long names to fit |
| run menu (10, 12) | ULT and DEV over the drawer, pill text spills, note cut, LEAVE RUN cut, "Paused" banner on the marker | fixed |
| run (11) | JUMP over DEV | fixed: DEV sits above JUMP on touch screens |
| level-up (13) | title under the Roblox buttons, cut descriptions, REROLL "1 left · 3..." | fixed |

Left as they are (outside tonight's scope): party, daily, arenas, more and account level got
only the shared fixes (BACK, top bar, TextFit; in the renders they no longer cut or overlap).
The HUD tray words (WEAPONS / PASSIVES / BUILD) were already changed to shrink to fit by an
earlier helper; they read small but whole.

Still open: a real phone test by the owner; phone-portrait lobby screens were checked only by
the regressions, not re-rendered one by one.

## 1. Calibration: why the device differed from the preview

Measured by rendering the same screens at `--device iphone` and comparing them with the
owner's screenshots (scratchpad `mobile-shots/1..13`).

### Cause A: the player's Roblox "Text size" setting (the big one)

Roblox shipped a platform-wide accessibility setting in 2025: **Settings > Text size**
(`GuiService.PreferredTextSize`: Medium (default), Large, Larger, Largest). It scales
**every label whose size comes from `TextSize`** at render time. It does not scale
`TextScaled` text, and it never grows text past a `UITextSizeConstraint.MaxTextSize`.
`TextBounds`, `TextFits` and `TextService:GetTextSize` report the scaled size.
Sources: the Creator Hub "Size modifiers and constraints" page and the DevForum
announcement "Introducing Text Scaling Setting".

Our layouts size every label from the designed `TextSize` (`UIKit.TS(n)` + a few px),
so at a large setting:

- one-line labels and buttons truncate early ("BA...", "Alch...", "KNIGHT...", "R...");
- the two labels of a two-line row (name + status, STARTING WEAPON + Sword, date + NEW
  CHALLENGE IN) each grow taller than their box and are drawn over each other;
- wrapped text needs more lines than its box has, so the end is cut off;
- AutomaticSize titles grow into badges next to them ("ARENA" vs "BEST STAGE 4").

Measured factor on the owner's phone: **about 1.6x** (widths of the same Source Sans
labels against a Medium render: "Open slot" 1.57x, "THIS SERVER" 1.60x, "Not in a party
yet" 1.58x). Roblox does not publish the factors; we take the owner's phone as
**Largest = 1.6** and estimate Large = 1.2, Larger = 1.4. Titles that are `TextScaled`
(the gold number, some captions) matched the preview, which confirms the cause.

### Cause B: the top-bar inset is read in a different X space on the iPhone

`GuiService.TopbarInset` (the free strip right of Roblox's buttons) is reported 59 px
(the left safe-area inset) to the left of where the game measures its own gui from
(`AbsolutePosition` difference of the safe-area and full-screen guis). Two independent
symptoms fit that exactly:

- CHARACTERS puts its BACK button at `TopbarInset.Min.X + 8`: on the device it sat at
  x = 170 pt, under the chat button (which ends at x = 222 pt = 163 pt + 59 pt);
- the home ACCOUNT pill drops to the row below the top bar when the strip "does not reach
  the right edge" (`Insets().Right > 4`): on the device it dropped by exactly that amount.

The new Roblox top bar is also bigger than the old preview ghost: a round Roblox button
(x 77-119 pt) and a menu + chat pill (x 128-222 pt), y 13-55 pt.

### Not a cause

UIScale, AutomaticSize and the safe-area insets matched the device (header heights, panel
positions and TextScaled sizes line up with the screenshots).

## 2. Preview changes (tools/preview)

- `iphone` device profile: the measured top-bar buttons (`coreButtons`, drawn as the new
  round button + pill and used by check_layout's TOPBAR rule), `TopbarInset` reported in
  safe-area space like the device, and `textSize = "Largest"`.
- Every scene takes `--set textsize=Medium|Large|Larger|Largest` (overrides the profile).
  The mock scales `TextSize` text at layout time like Roblox (not TextScaled, capped by a
  UITextSizeConstraint), reports it in `TextFits` / `TextBounds`, returns it from
  `GuiService.PreferredTextSize` and from the new `TextService:GetTextSize` mock.
- `check_layout.py` new hard rule **CUT**: text cut with "..." down to a stub (under 4
  characters left, a one-to-three-word label losing a quarter of its letters, or any text
  losing more than 60 %). The exporter now writes the full string of a truncated label.
- New scene `lobby-sweep` + `tools/preview/sweep.sh OUTDIR [--devices ...] [--set ...]`:
  every lobby screen in one Lune run per device (`preview.snapshot`), PNGs, then the
  layout check. It waits while another Lune process runs.

## 3. Game changes

(filled in below as the fixes land)
