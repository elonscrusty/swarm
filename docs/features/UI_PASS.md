# UI pass, wave 3 (2026-10-05)

A layout pass over the new feature screens and HUD pieces. Every result below is an
offline preview render (Lune mock + headless Chromium) with `check_layout.py`; nothing has been
played in Studio or on a real device, so device / Studio behaviour is BLOCKED.

## Fixes

| Area | Problem | Fix |
|---|---|---|
| FeatureHud badges | The row was positioned with the camera viewport width inside a safe-area ScreenGui: on iphone it ran off the right edge ("FOG 4..."); it ignored the tip card, team rows and spectate bar | The row is placed in the root's own (safe-area) pixels, under the counters, and drops under every piece it would touch (HUD top cluster, minimap only when it is on the right, team rows, TEAM TIP card, spectate bar, ULT / COMBO buttons). When the right column is full it sits left of it. It shrinks (UIScale down to `Config.FeatureHud.BadgeMinScale` 0.7) before badges are dropped; phones show at most `MaxBadgesCompact` (3) |
| Ultimate button | Same viewport bug; the charge fill was a square clipped by `ClipsDescendants` (Roblox clips square, so the corners showed) | Placed from the real JUMP button: above it on PC / tablet / portrait, beside it on landscape phones (left-handed layout: the other side). The fill is a round frame with a UIGradient cut-off. `FeatureHud.NextToUltimate(size)` gives the TEAM combo button its spot (it used the viewport too) |
| Announcer line | Fixed at 26 % height: over the objective panel on phones, over the vitals in portrait | Under the HUD top cluster; narrowed to clear the minimap (landscape), or beside it (portrait, TextScaled shrinks the words), never over the badge row |
| Revive status line | Portrait: the left-edge minimap covered "A teammate is reviving you" | Hud places the status line under the portrait minimap (`placeStatus`, same rule as the banner) |
| Merchant (ExploreUI) | No gamepad purchase | D-pad left / right moves a gold rim over the buyable offers, its button reads "X  BUY", X buys. No GUI selection (the stick keeps moving the hero). Ignored while the ping wheel is open, while a chest / shrine prompt shows (X is its hold key), while dead, and unless `UIState.WorldInputAllowed()` |
| Champion ring (ChallengesUI) | Two near-opaque neon discs: a solid pink plate hiding gems and telegraphs | Gold rim 0.5, violet inner disc 0.55 SmoothPlastic (only the rim glows) |
| Trial ring (server look) | Running look 0.55: a solid purple floor | 0.72 |
| Title plate (META) + nameplate (STORE) | Already routed through `StoreFx.DecoratePlate` (StoreFx skips its plate for a titled player); the glow was always a pill on META's 12 px plate | Glow follows the plate's corner radius. New check `team --set plate=on` |

Preview tool changes: parts a client parents to its camera are drawn (Roblox renders
them; ChallengesUI's rings were invisible in renders); `preview.setLastInput(kind)` sets
`GetLastInputType()`; new scene `challenges` (champion plate + ring, trial ring + badge,
cursed badge, `--set extras=on` ULT + announcer); `explore --set pad=on` (gamepad buy).

## Results (scene x device)

RESULTS_TABLE

## Not fixed (outside the new modules)

- Landscape phones: the TEAM TIP card (Tutorial) covers the right end of the HUD status
  line while both show (the card is temporary).
- Portrait `team --set me=down`: the minimap sits over the world label "YOU · REVIVING"
  (a billboard at the downed hero), flagged COVERED by check_layout.
