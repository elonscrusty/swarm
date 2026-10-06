# Mobile menu fix (2026-10-06)

The owner tested on a real iPhone (2556 x 1179 px, landscape, 852 x 393 pt at 3x) and found
every lobby menu broken: buttons cut to "BA...", names cut to "Alch...", two-line rows
drawn over each other, content cut off at the bottom, a header under the Roblox chat
button and the home ACCOUNT pill dropped onto the 3D scene. Our offline preview at
`--device iphone` showed none of it. This file says why, what changed and how to check it.

Status: offline only (preview renderer + regressions). NOT verified on a device or in
Studio; the owner's next phone test is the real check.

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
