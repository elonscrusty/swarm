# Off-screen danger arrows (switch `DangerArrows`)

## What
While a boss, champion (the mini-boss guarding a chest) or elite is off screen, or farther than
60 studs from your hero, an arrow sits on the edge of the screen pointing at it, with the
distance under it ("42 m", the same units as the portal arrow).

| Kind | Badge | Colour |
| --- | --- | --- |
| Boss | skull | red |
| Champion | crown | gold |
| Elite | ring with a dot | crimson |

The badge shape differs per kind, not only the colour (colour-blind players); colours also go
through the Colorblind setting. At most 4 arrows: a boss always gets one, the rest are nearest
first. Arrows fade in (0.15 s) and pulse softly; Reduced effects keeps them but stops the pulse.

They slide along the edge to stay inside the safe area and off the HUD: top-centre stack,
vitals, ability bar, banner, BUILD panel, centre bars, notice pills, minimap, JUMP / ULT
buttons, feature badges, the portal arrow and each other. If there is no clear spot an arrow
is skipped. They hide outside a running run, while dead, and while any panel is open (same
rules as the portal arrow).

Client only (`src/client/DangerArrows.lua`, started in ClientMain). It reads the replicated
enemy bodies (`workspace.SwarmEnemies`, attributes Type / Elite / MiniBoss) 10 times a second.
No remotes, no save data, no server change.

## Config
- `Config.Features.DangerArrows = true` (false = no arrows, game exactly as before)
- `Config.DangerArrows`: `FarStuds = 60`, `MaxArrows = 4`, `UpdateHz = 10`,
  `FadeSeconds = 0.15`, `Size = 44` (badge px), `EdgeMargin = 8` (px inside the safe area)

## Regression
Scene `tools/preview/scenes/danger-arrows-regression.luau`, registered in
`tools/run_regressions.py` as layout checks on iphone, phone-portrait and pc (each run also
prints the logic PASS / FAIL lines):

    python3 tools/run_regressions.py --only layout-danger-arrows-regression-iphone,layout-danger-arrows-regression-phone-portrait,layout-danger-arrows-regression-pc

Checks: off-screen elite gets one ring arrow with "N m"; an on-screen elite within 60 studs
gets none; six threats cap at 4 (boss + champion + 2 nearest elites, boss first then nearest);
badge shapes match kinds; arrows inside the safe area and off every HUD rect and each other;
Reduced effects stops the pulse but keeps the arrows; a panel hides them; switch off hides them.

## Owner steps
None. Try a run in Studio and look for the arrows when an elite or the boss is off screen.

## Expected status
- Offline preview: PASS expected (logic + layout on iphone / phone-portrait / pc).
- Studio / real phone: BLOCKED until the owner plays a run (not Studio-tested).
