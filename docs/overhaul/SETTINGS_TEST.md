# Existing settings: functional test (UI-59, TS-09, TS-10; UI-60 excluded)

The settings screen design is unchanged; only functional fixes are in scope. **What was exercised:** a
code review, and the offline Lune scenes `settings-sim` (new), `accessibility-sim` (existing) and
`safety-sim` (server save and reload). Nothing was tested on a device or in Studio, and no human
judged how anything feels or sounds.

## Persistence path

`UIBuilder` settings toggle → `ClientSettings.Set` (applied at once, saved 0.6 s after the last
change) → `SaveSettings` → `GoldSystem.onSaveSettings` (`Config.ValidateSetting` for every key in
`Config.Settings.Defaults`) → profile `Settings` → DataService save → `ProfileSync` → `ClientSettings.Apply`.

| Check | Result |
|---|---|
| Every one of the 15 keys from the save reaches the client (`settings-sim`) | PASS |
| Ten slider steps produce one save carrying the last value; NaN and an unknown colour mode are never sent (`settings-sim`) | PASS |
| Server: valid values saved; a wrong type, a string for a number, or an out-of-range number is ignored or clamped (`safety-sim`) | PASS |
| Leave and rejoin keep Shake 0.83, Colorblind, TouchLayout and Minimap (`safety-sim`) | PASS |
| A schema-0 save gets every key with the right type (`safety-sim`) | PASS |
| **Bug fixed:** a `ProfileSync` written before the server received a change (a purchase or other sync right after toggling) switched the setting back on screen while the server kept the new value | FAIL before the fix (negative control run) → PASS |

Fix: `src/client/ClientSettings.lua` remembers values it just sent. For 5 s, or until the server sends
the same value back, a different value from the profile does not overwrite them.

## Each control

| Control | Where it acts (code) | Covers newer effects? | Lethal cues kept? | Result |
|---|---|---|---|---|
| Music / Effects | `Audio.SetVolumes` | n/a | n/a | PASS (accessibility-sim) |
| Combat / Interface / Warnings channels | `Audio` sound groups SwarmCombat/SwarmInterface/SwarmWarning | n/a | Warnings has its own channel | PASS (accessibility-sim) |
| Mute all | Both masters set to 0; saved volumes come back on unmute | n/a | Visual sound cues still show while muted | PASS (accessibility-sim) |
| Visual sound cues | `Audio` cue label (for example "BOMB FUSE"); turning it off hides the cue on screen | n/a | yes | PASS (accessibility-sim) |
| Screen shake | `CameraController.Shake` / `Kick` scaled by the value; 0 is off | CombatFx and VFX shakes all go through it | n/a | Code review PASS |
| Reduced effects | VFX budget, CombatFx (no kick, fewer pieces), UIAnim, Hud, StageUI, TeamUI, MiniMap, PortalBeacon, Telegraphs (spawn puff only), DamageText, Tutorial, LootUI | Yes: CombatFx, PortalBeacon, UIAnim, RunIntro, TravelOverlay, NoticeDots, Showcase and IdleFx all check it | Yes: attack warnings stay (Telegraphs count kept, accessibility-sim) | PASS |
| Reduce flashes | `ClientSettings.Flashes()` (also true when Reduced is on): CombatFx edge flash, EnemyRenderer hit flash, VFX flashes, Hud vignette or XP sweep become steady, Telegraph blink becomes steady | yes | Yes: telegraph rims, the bomb's blast ring and boss warnings stay drawn, just not blinking; the low-HP vignette stays, held steady | PASS (accessibility-sim plus code) |
| Damage numbers | The server sends batches only to players with the setting on (player attribute set by SaveSettings); `DamageText` also checks it | n/a | n/a | Code review PASS |
| Show tips / Replay tips | `Tutorial` reads Tips. REPLAY TIPS sends `Tutorial("Replay")` (server clears seen tips and sets Tips on) and turns Tips on | n/a | n/a | Code review PASS |
| Minimap | `MiniMap` `enabled` flag set by the setting | n/a | The portal arrow is in StageUI, so it still shows with the minimap off | Code review PASS. The settings-sim UI check is BLOCKED while LobbyScreen is mid-edit (another helper) |
| Colors (Off / Protanopia / Deuteranopia / Tritanopia) | `Accessibility.Color`; minimap enemy markers turn into diamonds | n/a | Danger and heal colours stay distinct, and the shape cue does not rely on colour | PASS (accessibility-sim) |
| Touch layout (Right / Left / Compact) | `MobileControls.MovementSide` | n/a | n/a | PASS (accessibility-sim). Real touch BLOCKED (device) |

## Screen shake: default compared with the recording

Default is `Shake = 1` (100%). Peak camera jitter is `min(amount, ShakeMax 0.6) × setting` studs,
camera punch is `min(amount, KickMax) × setting`, and both decay within about 0.2-0.4 s. In the long
recording the player moved the slider from 0% to **83%**, which gives 0.83× the default amplitude
(peak about 0.5 studs instead of 0.6 at a camera distance of 77.5). So the camera motion in the
recording is **less** than a new player gets by default. Any judgement that it is too much applies
to the default even more. Whether it feels right is BLOCKED: it needs a human at normal speed (TS-09). I made no change.

## Accessibility limits (honest)

- Reduced effects does not lower camera shake; shake has its own slider. The setting's description
  ("Fewer particles and trails. No screen flashes.") does not promise that, so I left it alone. Changing
  it would need an owner decision.
- There is no reduced-motion setting separate from Reduced effects. This is not certified against any
  accessibility standard.
- The review's grouping and wording suggestions (UI-60) are excluded by the owner's decision on the
  settings screen.
