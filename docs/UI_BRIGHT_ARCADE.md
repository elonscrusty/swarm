# Bright Arcade UI (owner's 2026-10-08 reference pack)

Owner brief: `docs/ui_refs/BRIEF.txt` (read it in full). Reference images:
`docs/ui_refs/01_arena.png` … `09_build.png` (arena, daily, party, play, settings, more,
ping wheel, HUD, build). They are visual references only: build real Frames / TextLabels,
never place a screenshot in the game, never hardcode their sample values (dates, gold,
counts). Project code and data are authoritative.

## Look

Icy-white panels (white → #E8F6FF gradient), solid royal blue borders (#087FFF, 2-3 px),
a blue drop shadow offset downward (#082D9C), navy text (#08164E, secondary #455F9D),
chunky rounded type, sunny yellow (#FFF35A → #FFD21C, edge #E8A90B) for the ONE main
action per screen, lime (#BBF52B, edge #5E9E00) for selected states (always with a check,
label or shape cue too), red (#E65050) for leave / destructive, blue-grey (#D8E3EE fill,
#778AA5 text) for unavailable. No gold frames, parchment, serif headings, dark slate plates,
neon glow or heavy bloom. Gold stays only for coins / currency and owner art.

Fonts (two families): Fredoka One (`Theme.Font.Display/Title/Heading/Number`) for titles,
buttons and figures; Nunito (`Theme.Font.Body/BodyStrong/Label`) for body and small labels.
Page titles: white Fredoka with a navy outline, `UIKit.PageTitleStyle(label)` (UIStroke,
Contextual). Never outline small labels; never fake shadows with duplicate labels.

## Where the tokens live

- `src/shared/Theme.lua`: `Theme.Arcade` raw tokens, `Theme.Color` semantic tokens
  (Panel, PanelEdge, Text, TextMuted, Primary…, Selected, SelectedEdge, SelectedPale,
  Danger, Disabled, DisabledText, Blue, BlueLight, BlueDeep, BluePale, TextOnBlue, Track,
  Divider, Coin…), `Theme.Gradient` (Panel, Primary, Selected, Blue, XP…). The old names
  Gold / GoldLight / GoldDark now point at the blues.
- `src/client/UIKit.lua`: Surface / Panel / Button kinds (`Primary` yellow, `Secondary`
  white, `Outline`, `Ghost`, `Selected` lime, `Danger` red, disabled) / IconButton / Card /
  Badge / Meter / Tile / Tabs (selected = lime) / Slider (blue fill, yellow knob) / Toggle /
  StatusPill / IconPill (blue pill) / TitleBar + ScreenHeader (page title lettering).

Rules for screen code: use `Theme.Color.*` / `Theme.Gradient.*` / UIKit components, not
`Palette.*` or `Color3.fromRGB` for UI chrome. Palette colours are fine for world art,
item/enemy identity colours and coins. Text on white = navy; on blue = white; on yellow /
lime = navy. Gold text on white is not readable: use BlueDeep or navy instead.

## Layout rules (from the brief)

Header (back / close + title) and footer (main action) stay outside the scrolling body; only
the body scrolls, with the UIKit scroll hint. Touch targets ≥ 44-48 px. Wrap body text,
reserve its height; reflow grids to fewer columns instead of shrinking text. Respect the
top-bar inset and the mobile thumbstick / jump. Layer order: HUD < notices < menu dimmer <
menu < confirmation. Wave banners never cover a menu title or close button.

## Checking

Render: `bash tools/preview/render.sh <scene> --device phone|phone-small|pc|phone-portrait
--out <png>` (see docs/PREVIEW.md for each scene's `--set` options), then
`python3 tools/preview/check_layout.py <json>` (the json is written next to the png when
`--outdir` is used; or pass `--json`). Phones: 844x390 (`phone`), 667x375 (`phone-small`),
iPhone with Largest text (`iphone`). Type check: `bash tools/check.sh --quick`.
Nothing here is Studio-tested unless the owner says so.
