# SCREENS audit (UI, assets, input, accessibility, audio): 2026-10-05

Source audited: `audit-baseline-2026-10-05` (b07d83b) plus this area's fixes. Environment: Lune offline
preview (mock Roblox API, headless Chromium for pictures). No Studio, no real devices, no gamepad hardware,
no live asset permissions. Everything below is offline evidence: **NOT Studio-tested**.

## 1. Screen and state inventory (rendered)

Renders are the real client modules on the mock (`tools/preview/runtime/main.luau --set images=loaded`), one
Lune process at a time, checked with `tools/preview/check_layout.py`. Devices: pc 1920x1080, iphone 852x393,
phone-portrait 390x844, tablet 1024x768 (touch).

| Screen / state | Scene (`--set`) | pc | iphone | phone-portrait | tablet |
|---|---|---|---|---|---|
| Home | `menu` | OK | OK | OK | OK |
| Play (run setup) | `menu screen=Play` | OK | OK | OK | OK |
| More | `menu screen=More` | OK | OK | OK | OK |
| Stats | `menu screen=Stats` | OK | OK | OK | OK |
| Journal (undiscovered rows) | `menu screen=Journal` | OK | OK | OK | OK |
| Party | `menu screen=Party` | OK | OK | OK | OK |
| Duo countdown queue | `menu phase=countdown` | OK | **FAIL then FIXED** (S-01) | OK | OK |
| Save failing notice (error state) | `menu save=failing` | OK | OK | OK | OK |
| Last run card | `menu lastrun=fell` | OK | OK | OK | OK |
| Characters / mastery open | `characters [mastery=open]` | OK | OK | OK | OK |
| Remaining screens | see §1a | | | | |

Legend: OK = no OVERLAP / OFFSCREEN / TOPBAR / COVERED / OVERFLOW finding (TRUNCATED / CLIPPED / SMALL are
information only and were looked at: the TRUNCATED hits are literal "..." in copy, e.g. "mastery 2, 4, 6..."
and "Waiting for a player..."; CLIPPED hits are scroll-list edge rows).

### 1a. In-run and remaining screens

| Scene (`--set`) | pc | iphone | phone-portrait | tablet |
|---|---|---|---|---|
| `arena` | OK | OK | OK | OK |
| `arena arena=Snow` | OK | OK | OK | OK |
| `levelup` | OK | OK | OK | OK |
| `rewards` | OK | OK | OK | OK |
| `results` | OK | OK | OK | OK |
| `pause` | OK | OK | OK | OK |
| `hud-build` | OK | OK | OK | OK |
| `characters mastery=open` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `upgrades` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `upgrades tab=shop` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `settings` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `countdown` | not run (approved desktop layout; pc covered by existing scenes) | OK (after S-01) | OK | OK |
| `curses` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `daily` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `leaderboards` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `leaderboards status=error` | not run (approved desktop layout; pc covered by existing scenes) | **S-19** | OK | OK |
| `leaderboards rows=1` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `track` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `arenas` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `party view=panel` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `levelup rerolls=0 skips=0 rerollsMax=0` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `rewards view=need` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `results outcome=defeat` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `items synergies=on` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `bugreport result=fail` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `revive` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `team choosing=on` | not run (approved desktop layout; pc covered by existing scenes) | S-20 (preview artifact) | S-20 (preview artifact) | OK |
| `run-intro` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `stage-arrow wave=5` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `stage-choice` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `loot focus=Golden gold=5` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |
| `menu save=failing` | not run (approved desktop layout; pc covered by existing scenes) | OK | OK | OK |

141 scene/device JSONs checked in total (`checked 141 scene(s)`). Not rendered this pass (time): `menu screen=Party/Journal` on extra variants, `tutorial`, `minimap`, `stage-portal`, `loot result=lose`, `loading`, `bugreport` (plain), `team mode=Trio`, `rewards view=other / queue=on`, `results outcome=endless`; their phone layouts were covered by earlier overhaul checks only (NOT RUN here).


## 2. Findings matrix

| ID | subsystem | expected (source) | files/functions | repro/start state | actual | evidence type | severity | root cause | fix/proposal | status | next check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| S-01 | Lobby duo queue panel | Text never drawn under a button (owner prompt §11: clipping, z-order) | `LobbyScreen.lua` relayout (queue section) | iPhone landscape, a Duo countdown someone else started (`menu --set phase=countdown --device iphone`) | the note "PreviewPlayer · Tap JOIN to play" was drawn behind the JOIN button (6 COVERED findings; visible in the render) | runtime render + check_layout | P2 | the short-panel branch placed the note at y=68 without checking the room left above the button row (panel ~120 px tall on iPhone) | lines that would run under the JOIN / START row are left out; the curse count / Endless then folds into the caption ("STARTING · 2/2 JOINED · 2 CURSES"). Baseline `countdown --device iphone` (curses on) also hid the whole curse row under START NOW and ran the note below the panel, which check_layout did not flag (text past its own panel's bottom is not a finding: tools gap, FOR OTHERS) | VERIFIED FIXED (check_layout 0 problems; renders before / after) | Studio: iPhone landscape duo countdown |
| S-02 | Lobby gamepad back | gamepad B backs out of a screen (InputPrompts.Back says "Press B") | `LobbyScreen.Show`, `LobbyScreen.Init` | lobby on a gamepad, open MORE → RANKS, press B | nothing happened on any lobby screen (B only handled by the pause / settings and run menu panels); the selection stayed on the now-hidden home button | `lobby-screens-regression` FAIL at baseline, PASS after | P2 | no B handler for lobby screens; Show() never moved the gamepad selection | B = the screen's BACK (ctx.Back), not while a UIState panel owns input or on the same press that closed one, not while typing; on a gamepad Show() selects inside the new screen (`GuiService:Select`) | VERIFIED FIXED (offline) | real controller in Studio / console |
| S-03 | HUD build key under a panel | keys must not act behind overlays (prompt §12) | `Hud.lua` B / ButtonY handler | in a run, open the run menu drawer (it leaves the HUD visible), press B | the BUILD details opened behind the drawer | `hud-key-regression` FAIL at baseline, PASS after | P2 | the handler only checked `ui.Frame.Visible`; the drawer uses covers=false | also require `UIState.Owner() == nil` | VERIFIED FIXED (offline) | Studio keyboard |
| S-04 | Account level label (from ECONOMY) | account level must not read as the hero's level | `LobbyScreen.buildAccount / layoutAccount` | home screen | "LV n" sat next to the hero badge | regression (account caption) FAIL at baseline, PASS after | P2 | label without a noun | small gold "ACCOUNT" caption above "LV n" in the pill (pill width unchanged; caption 8.4 pt on iPhone = SMALL info) | VERIFIED FIXED (offline) | owner look on phone |
| S-05 | Hero upgrade wording (from ECONOMY) | one word for upgrade steps | `MenuCharacters.lua` mastery rows + rule text | CHARACTERS → UPGRADE KNIGHT | rows said "LV n/max", the locked line said "Rank n needs mastery", the rule said "ranks higher / up to rank n" | static | P2 | mixed copy | everything says LV / levels; "mastery" stays the hero's own level | VERIFIED FIXED (static + characters renders) | - |
| S-06 | Stats screen personal records (from ECONOMY) | best score and highest level visible as personal stats, distinct from boards | `MenuStats.lua` GROUPS / refresh | MORE → STATS with Stats.BestScore / BestLevel in the save | no tiles (data already in ProfileSync `Stats`) | regression FAIL at baseline, PASS after | P2 | not built | two tiles in RUN RECORDS: "Best score" (crown) and "Highest run level" ("LV n"); "-" when 0 | VERIFIED FIXED (offline) | phone look |
| S-07 | Asset ids | every id real and recorded; no fake ids | `IconData`, `ArtData`, `MeshCatalog`, `Config.Sounds`, upload records | `python3 tools/gen_icon_checklist.py`, cross-check script (below) | IconData 106/106 = `art/icons/uploaded_ids.json`; ArtData 146/146 = `art/uploaded_art.json`, every key has its PNG; MeshCatalog 143 ids = `meshes/uploaded_ids.json`, none 0; 39 of 42 sounds = `art/audio/uploaded_ids.json`; checklist 288 entries, 0 problems | static | - | - | docs/ICON_CHECKLIST.md regenerated (it was stale: new UIBuilder / LootUI call sites) | VERIFIED WORKING (records) | owner steps §4 |
| S-08 | Asset permissions / moderation | ids load for players | all of the above | live Roblox | cannot be checked offline | - | - | - | owner steps §4 | UNVERIFIABLE | Studio + live server |
| S-09 | Unused uploads | each uploaded picture referenced | `ArtData` | key scan | `ui/home/home_DockFrame`, `ui/home/home_ModeFrame`, `ui/home/home_More` are uploaded but no code uses them (the dock / mode frame / MORE plate are drawn) | static | P2 | owner art arrived after the drawn versions | none (design choice for the owner; not an error) | NOT APPLICABLE | owner: wire or drop |
| S-10 | Library music | music ids playable | `Config.Sounds` LobbyMusic 1836939228, BattleMusic 9047425352, BossMusic 1838623501 | - | Roblox library tracks, not in the upload record | static | - | - | owner already plans licensed music (CLAUDE.md) | UNVERIFIABLE | Studio: hear all three |
| S-11 | Preload / join never waits on art | slow or missing pictures cannot hang join or hide controls | `AssetPreload.Start` (background, every id once), `ClientMain` loading picture (only while `SwarmMeshes` says models are loading, max 12 s, skipped with no picture), `ArtImage.watch` / `Icons` (drawn fallback after 0.6 s, give-up 20 s, a late picture still replaces it), `ArtImage.ButtonIcon` keeps the glyph under the picture | static + `loading` scene | nothing blocks: no `PreloadAsync` is awaited on the join path; every picture has a drawn fallback (glyph / vector icon / drawn PLAY plate) | static | - | - | - | VERIFIED WORKING (static) | Studio with throttled network |
| S-12 | Settings work and persist (design untouched) | all 15 `Config.Settings.Defaults` keys apply at once and persist | `ClientSettings.Set/Apply` (debounced SaveSettings, 5 s echo grace), `GoldSystem.onSaveSettings` (ValidateSetting per key), `DataService` defaults fill | settings screen controls (UIBuilder 3163-3229) map to every key | every key has a control and a reader: Music/Sfx/MuteAll + 3 channel sliders → Audio buses; Shake → camera/CombatFx/Hud; ReducedEffects (21 files), ReduceFlashes (`ClientSettings.Flashes()` 9 files); DamageNumbers → server attribute; Tips → Tutorial; Minimap; Colorblind → Accessibility/MiniMap/EnemyRenderer; VisualAudioCues → Accessibility.Cue; TouchLayout → MobileControls | static + existing `settings-sim`, `accessibility-sim` (both PASS at baseline per brief) | - | - | - | VERIFIED WORKING (offline) | Studio: rejoin keeps settings |
| S-13 | Critical warnings with reduced effects / flashes | warnings still shown | `Telegraphs` (blink → steady edge), `Hud.Hurt` (no edge flash, heart punch), low-HP vignette (steady 0.8 instead of breathing), `EnemyRenderer` fuse ring calm | `accessibility-sim` asserts telegraphs kept with ReduceFlashes, muted warnings still give visual cues | warnings stay, only the flashing goes | test (existing) + static | - | - | - | VERIFIED WORKING (offline) | - |
| S-14 | Audio buses and cleanup | music / SFX / channel buses; no stray sounds between runs | `Audio.Init` (SwarmMusic → SwarmMusicDuck; SwarmSFX → Combat / Interface / Warning → categories), `Audio.StopEffects` on run end (UIBuilder InRun false), music follows InRun / BossMaxHP (ClientMain) | `audio-sim`, `tools/audio_regression.luau` | buses and stop are correct; ducking and crowd tweens cancel each other | static + existing tests | - | - | - | VERIFIED WORKING (offline) | Studio listen test |
| S-15 | Hold E / taps through overlays | no hold or purchase while a panel or reward feedback is up | `LootUI.Press` (`UIState.WorldInputAllowed`), `UIState.OnOwnerChanged` → `LootUI.Release`, reward reel skip ignores an E held from the chest (< 0.5 s), level-up touch guard (`offerArm`) | static + existing reward / levelup regressions | correct | static | - | - | - | VERIFIED WORKING (static) | - |
| S-16 | Gamepad: opening the run menu | a controller can reach the run menu | `Hud` InputBegan (ButtonStart) → host `OnPause` / `OnPauseClose` (`UIBuilder.OpenPause` / `ClosePause`) | in a run, press Start; again; press Start under the level-up choice | FINAL-FIX: Start opens and closes the run menu like the on-screen button; under a higher panel nothing happens (`UIState.CanOpen("Pause")`, only `Owner() == "Pause"` closes) | `hud-key-regression` (3 new Start checks) | P2 | no binding | bound ButtonStart; ignored when the input is already processed (if Roblox's own menu takes Start on a device, ours stays shut) | VERIFIED FIXED (offline) | Studio with a controller: does Roblox's menu also take Start? |
| S-17 | Keyboard back | Escape belongs to Roblox | - | - | keyboard users use BACK / DONE buttons; no Backspace shortcut | static | P2 | - | none proposed (Escape is reserved) | NOT APPLICABLE | - |
| S-18 | Snow contrast (prompt §14 lead) | HUD, pickups and enemies readable on snow | `EnemyRenderer` `SnowContrast` (mark / base, synced to SwarmState `Arena`) | `arena --set arena=Snow --set types=Ghost,Healer,Slime --set enemies=60` pc, before (HEAD EnemyRenderer) and after | HUD fine (dark plates). Before: pale Phase Moths and Healer aphids nearly vanish on the grey-white ground. FINAL-FIX: on Snow only, the pale pieces of those two enemies are drawn darker in the same hue (value capped 0.5, a little more saturation): slate moths, olive aphids; eyes / stripes / other arenas / other enemies unchanged; flashes and colourblind mode build on the same base | render before / after (offline) | P2 | pale palette on a pale ground | restrained per-arena tint, no new parts | VERIFIED FIXED (offline render) | owner look in Studio |
| S-19 | Leaderboards error state (ECONOMY file) | pinned YOUR BEST row stays on screen | `MenuLeaderboards` layout (`NoteShort`, column head dropped when tight) | `leaderboards --set status=error --devices iphone,phone,pc,phone-portrait` | before: OFFSCREEN 566x46 on iphone. FINAL-FIX: on short screens the note is one line ("Could not read the board. Trying again in a minute.") and the column heading goes when a row + YOUR BEST would not fit; YOUR BEST sits inside the panel | render + check_layout: 0 problems on all 4 devices | P2 | fixed panel heights ignored the banner | as above | VERIFIED FIXED (offline) | - |
| S-20 | Team status pill vs revive ring | screen text readable; the scene shows real behaviour | `team.luau` choosing=on, `Hud` status line | `team --set choosing=on` iphone / pc | FINAL-FIX: the scene now sets the live group choice (SwarmState Frozen=false, LevelUpPause=false, ChoosingIds/Names; the chooser carries ChoiceOpen, ChoiceGroup, ChoiceProtectedUntil = now + GroupAutoPickSeconds, Paused) and asserts the line reads "Ava is choosing an upgrade" with no "Paused" (PASS on both). check_layout still reports the revive-ring billboard over two words: a preview artifact (Roblox draws ScreenGuis over BillboardGuis) | render + scene assert | - | stale scene state | scene updated | VERIFIED FIXED (scene) / NOT APPLICABLE (billboard overlap) | - |
| S-21 | Tips over the minimap on phones | tips never hide critical info | `Tutorial` team tip card | `team --set choosing=on --device iphone` | the TEAM TIP card covers the minimap and the right edge for its few seconds | render | P2 | card anchored right on landscape phones | proposal only (owner look): move the tip card left of the minimap on phones | open (proposal) | owner look |
| S-22 | Build details on portrait phones | panels do not hide combat by surprise | `Hud` BUILD details | `hud-build --device phone-portrait` | the open BUILD list covers the hero (centre); it only opens on a tap / B and says "The run keeps going while this is open" | render | P2 | by design | none | VERIFIED WORKING | - |

## 3. Tests

| Test | Command | Baseline (audit tag) | After |
|---|---|---|---|
| lobby-screens-regression (S-02, S-04, S-06) | `lune run tools/preview/runtime/main.luau -- --scene lobby-screens-regression --studio --device pc --out <json> --max-time 400` | FAIL (6) | PASS (12/12) |
| hud-key-regression (S-03) | same with `--scene hud-key-regression` | FAIL (2) | PASS (5/5) |
| hud-key-regression (S-03, S-16 FINAL-FIX) | same | - | PASS (8/8, 3 new gamepad Start checks) |
| team choosing=on (S-20 FINAL-FIX) | `render.sh team --set choosing=on --devices iphone,pc` | - | PASS (group-choice status line, no "Paused") |
| leaderboards status=error (S-19 FINAL-FIX) | `render.sh leaderboards --set status=error --devices iphone,phone,pc,phone-portrait` + check_layout | OFFSCREEN on iphone | 0 problems on 4 devices |
| Layout sweep (S-01 and §1) | `scratchpad/scr/sweep.sh` + `python3 tools/preview/check_layout.py <dir>` | 1 scene with problems (countdown iPhone) | see §1a |
| Type check | `bash tools/check.sh --quick` | ok | ok |

Both new scenes need the client GUI, so in `tools/run_regressions.py` they belong in the tuple that drops
`headless=on` (like `results-flow`).

## 4. Owner steps (asset permissions: UNVERIFIABLE offline)

1. In Studio, play the place on a test account that does not own the assets: home screen, CHARACTERS,
   SHOP, a run with a level-up and a chest. Every picture should appear within a second or two; a grey
   box or a drawn glyph where a picture should be means that id is not loading.
2. Creator Dashboard → Development Items → Images / Decals / Meshes / Audio: every item should be
   "Approved" (not "Pending" / "Rejected") and owned by you (or your group if the game is a group game).
3. Listen to lobby, battle and boss music once each (library tracks, not your uploads).
4. Plug in a controller (or use the Studio emulator): on a lobby screen press B to go back; in a run open
   the menu with the on-screen button and press B to close it.
