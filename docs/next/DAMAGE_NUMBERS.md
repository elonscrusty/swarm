# Damage number options (switch `DamageNumberOptions`)

## What
What existed: Settings had one toggle, "Damage numbers" (`Settings.DamageNumbers`, off by default).
The server (`DamageNumbers.lua`) sums each player's hits per enemy and sends them 8 times a second,
only while the setting is on; the client (`DamageText.lua`) draws them, merging into an enemy's
number for 0.5 s, at most 18 labels, 3 new per frame, crits gold, 22 px, ending in "!".

Now the Settings screen's Comfort column has two rows in its existing style (the cycle button like
COLORS / TOUCH LAYOUT, and a toggle):

- **DAMAGE NUMBERS: OFF / SMALL / NORMAL / BIG** (tap to cycle). Off is the old `DamageNumbers`
  setting being false (the server then sends nothing). Small 14 px, Normal 18 px (the current look),
  Big 24 px; crits 18 / 22 / 30 px.
- **Combine numbers** (default on): hits on one enemy within 0.3 s merge into one rising number. Off:
  every server batch (up to 8 a second per enemy) gets its own number, still under the 18-label cap.
- **Crits** always differ by more than colour: gold, bold (heavy weight), bigger, and start with a star,
  even at Small.

Default: numbers stay OFF as before (the existing default), size Normal, Combine on. Choosing Off keeps
the remembered size, so Off then cycling again continues from Small.

Persistence: through the existing settings path. `DamageNumbers` (existing), plus two new keys in
`Config.Settings.Defaults`: `DamageNumberSize` ("Small" | "Normal" | "Big") and `CombineNumbers` (bool).
`ClientSettings.Set` debounces, `SaveSettings` validates with `Config.ValidateSetting`, an older save gets
the defaults in `DataService.Migrate`. No schema bump.

Files: `src/shared/DamageNumberView.lua` (the pure rules), `src/client/DamageText.lua` (sizes, merge
window, star + bold crits, scene hooks), `src/client/DamageOptionsUI.lua` (the two rows; UIBuilder has no
locals left, so `buildPause` only calls `Build`), `Config.DamageNumberOptions`.

## Config
- `Config.Features.DamageNumberOptions = true` (false: the old single toggle, 0.5 s merge, "!" crits)
- `Config.DamageNumberOptions`: `Order`, `Sizes` (Small 14/18, Normal 18/22, Big 24/30), `CombineSeconds = 0.3`,
  `CritMark = "★"`
- `Config.Settings.Defaults.DamageNumberSize = "Normal"`, `CombineNumbers = true`
- Decision for you: the spec said "default Normal". The existing default is numbers OFF, so I kept it
  (Normal is the size you get once you switch them on). Say if you want them on for new players.

## Owner steps
1. Studio playtest: SETTINGS > Comfort: cycle the row, hit enemies in a run, check Small / Normal / Big,
   Combine off (more, shorter numbers) and crits with the star at Small.
2. Check on the phone at Text size Largest that the two new rows are not cut.

## Performance
Label counts come from `damage-numbers-regression` (virtual clock, 16 enemies hit 8 times a second for
3 s, `NUMBERS` line in its output): Off creates 0 labels; Combine on creates far fewer labels than Combine
off (the check requires at least 4x fewer) and never shows more at once; the 18-label cap holds either way.
Measured (virtual clock, 16 enemies x 8 hits/s x 3 s; labels created / most on screen at once): Off 0 / 0,
Combine off 384 / 18 (the cap), Combine on 16 / 16. `perf-sim` was not extended or run (it measures
server and client frame time with the setting on and does not change).

## Regression
- `damage-numbers-regression` (layout check on iphone, phone-portrait, pc; the last frame is the Settings
  screen with the new rows): rules, sizes per option, crit distinctness at every size, label counts, setting
  persistence on the client, the rows cycle and toggle, switch off.
- `damage-settings-regression` (real server): defaults, SaveSettings stores the new keys, junk is refused,
  Migrate fills an older save, the server sends numbers only while on.

    python3 tools/run_regressions.py --only damage-settings-regression,layout-damage-numbers-regression-iphone

## Status
PASS offline: `damage-settings-regression` PASS, `layout-damage-numbers-regression-iphone`,
`-phone-portrait` and `-pc` PASS (check_layout 0 problems on the Settings screen).
BLOCKED until Studio: real fonts (bold weight, the star glyph), phone readability of the three sizes.
