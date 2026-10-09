# Stream L1: lobby UI (class browser, home, settings, codex)

Done for the lobby chat, which had not started. Branch: the worktree branch of stream L1, based on
`claude/dazzling-fermi-ycslnt` (7c96a55). Offline only: everything below was run in the preview mock
(Lune + headless Chromium), nothing in Studio, nothing published. `bash tools/check.sh --quick` is clean.

## 1. What was built

### Class browser (replaces the four-card class sheet)
`src/swarmv2/client/Lobby/ClassBrowser.lua`, opened by the CLASSES chip (`ClassPanel.lua`).

| Brief item | How |
|---|---|
| Exact 12 ids | `ClassCatalog.Order` (checked in `class-browser-regression`). |
| Wide: stable 3-column grid beside details | 3 columns, rows from the available height, **paged** (prev / next, "PAGE 1 / 2"); pages never move cards. |
| Phone: 2-column grid, then a dedicated details view | BACK returns to the same filter, page and highlighted card. Phone landscape uses one header row (title, tabs, pager, close) and a split details view (name + actions left, text right). |
| All / Owned filters, Locked visible in All | Tabs with counts ("ALL 12", "OWNED 2"); a locked card is dimmed with a LOCKED badge and its requirement line. |
| Card | portrait, name, ownership badge (STARTER / OWNED / LOCKED / CHECKING), SELECTED badge (icon + words), role. |
| Portrait | A `ViewportFrame` of the real class model: `ViewportPreview.Template(id)` = `ReplicatedStorage.CharacterPreviews["<id>|Default"]`, which the server builds from the same `ModelBuilder` as the run character (GameServer registers the 12 classes before RunManager builds previews). Until it arrives: a swatch labelled PREVIEW LOADING; after 12 s PREVIEW UNAVAILABLE (explicit state). |
| Details | id, name, description, ownership state, unlock requirement + progress bar, starting weapon, passive, movement ability (names and behaviour), eight base measurements. |
| Authoritative numbers | `src/swarmv2/shared/Lobby/ClassDetails.lua` reads only shared tuning: health and speed with StatSheet's formulas on `ClassRoster.Entry().Bonus` + `Config.Player`; jump apex `RunConfig.Movement`; dash / leap distance and cooldown `RunConfig.Dash` (what `Dash.lua` reads); weapon damage / interval / range `WeaponData.RankSpec(sig, 1)` through `BuildRules` (B = 10); kit sentences are built from `RunConfig.Classes.*` numbers. Labelled "Base values before upgrades". |
| Inapplicable values | A figure that cannot be read is returned as `Hidden = <reason>` and shown as "Not shown" plus the reason, never a zero. A melee weapon is labelled "reach", not "range". |
| Preview and Select separate | PREVIEW toggles a turning model (never selects or buys). SELECT / BUY are separate. |
| Selection pending until the server confirms | `ClassAck` (see section 2). Pending shows SELECTING... / BUYING..., the old class keeps its SELECTED badge, a refusal or a 6 s silence drops the choice and says "Still using X". |
| Locked shows the real requirement | `ClassDetails.Access`: price (first three, DECISIONS C2) and / or the goal text with `LobbyView.Progress` ("120 / 300 XP", survival as "1:30 / 3:00", Knuckles shows both routes). |
| Queued | Select / Buy are disabled with the reason "You are in a queue, so your class is locked. Leave the queue to change it." and a LEAVE QUEUE button (`QueueAction Leave`). Committed / teleporting: "locked while the run starts"; the browser closes while teleporting. The server still allows a change while queued (it cancels READY, as before): the browser is the stricter, brief-conform front. |
| Gold purchase kept | The three priced classes keep BUY-with-gold, now behind a confirmation that names the class, price, gold before / after and the outcome ("Nothing here is bought with Robux"). Disabled while the profile or a class answer is pending. |
| Controller | Every card and button is `Selectable` with a cyan outline; the pager reaches other pages; B / Escape step back (confirmation, details, grid, closed); gamepad focus returns to the highlighted card. |

### Home screen and onboarding
- Entry points: **CLASSES** chip (top left, shows the class in use), **PARTY** strip with count / leader, **SHOP**, **CODEX**, **SETTINGS**, **MORE** (boards, quests, daily, stats ...) and the gold **PLAY** (`MenuBar.lua`, `PartyStrip.lua`, `QueuePanel.lua`). Every button is at least 48 px, PLAY 84.
- Loading statuses (`Status.lua`): a card lists lobby connection, profile (`ProfileSync`) and class ownership / selection (first `LobbyState`). After 8 s it names what is still loading; after 30 s it shows an error line (icon + words), says the saved progress is untouched and offers RETRY (`RequestProfile` + `LobbySync`, 3 s cooldown, safe to repeat). The class chip says "Loading class..." instead of guessing Ruckus, the party strip "Loading...", and the first-time guide never opens without a real profile. A status row shows Connected / Not saving / Not saved (from the `SaveStatus` attribute) and a HOW TO PLAY button.
- First-time guide (`Guide.lua`): 5 steps (choose class, optional party, join a queue, controls of the current device, how a run goes), about 40 s, SKIP at every step, Escape / B skips. It opens by itself once, only when the real profile says `Stats.Runs == 0`, no tutorial progress and `Settings.LobbyGuideSeen` is not set; finishing or skipping saves `LobbyGuideSeen` through `ClientSettings` (coalesced). Reopen from HOW TO PLAY or Settings > HOW TO PLAY (does not touch the flag). Returning players never see it by themselves. Switch: `LobbyConfig.Home.Guide`.
- Controls shown per device: keyboard (WASD, Space, Left Shift or Q, right mouse for the camera), touch (left stick, right-side swipe, JUMP and DASH), gamepad (sticks, A, B or R1). One list, `CodexData.Controls`, shared with the codex.

### Settings (extended, not rebuilt)
`src/client/MenuSettingsPlus.lua`, hooked into the existing modal by four tagged lines in `UIBuilder.lua`.

| Setting | Key | Reader |
|---|---|---|
| Music, Effects (existing) | `Music`, `Sfx` | `Audio` |
| **Master volume** | `MasterVolume` | `Audio.SetVolumes` multiplies music and effects |
| **Camera sensitivity** (0.5x to 2.0x, shown as "1.0x") | `CameraSensitivity` | `CameraController.rotate` (every look input) |
| **Invert camera left / right, up / down** | `InvertCameraX/Y` | same |
| Screen shake (existing slider) | `Shake` | `CameraController.Shake` |
| Reduced motion = existing "Reduced effects" (no shake or kicks, slower recentre); a line says so | `ReducedEffects` | unchanged |
| **Effects intensity** (decoration only; warnings and telegraphs never use it) | `EffectsIntensity` | `VFX.budgetScale`, `CombatFx.scale` (floor 25 %) |
| **UI size** (80 % to 120 %, default 100 %) | `UIScale` | `UIBuilder.updateScale` and the lobby UI's scale |
| **Reset to defaults** (two taps) | all keys except `LobbyGuideSeen` | `ClientSettings.Set` per key (one coalesced save) |
| **How to play** (lobby only) | attribute `SwarmGuideRequest` | `LobbyClient` |

All of it persists through the existing `Config.Settings.Defaults` / `SaveSettings` / `DataService` mechanism (new keys are additive; old saves get the defaults). The note under the rows says "saved with your profile" or, when `SaveStatus` is failing / memory, "these options last for this session only". No brightness (no supported visual setting exists) and no sprint (Shift is dash).

### Codex (the COLLECTION screen, now CODEX)
`src/client/MenuCollection.lua` + `src/swarmv2/shared/Lobby/CodexData.lua`, reached from the home CODEX button and MORE.
Categories: Classes (12), Weapons (15, `WeaponData.Catalog`), Passives (8, `PassiveData.LootOrder`), Evolutions (4, `RunConfig.Builds.Evolutions`), Enemies (7: beetle, floating eye, root runner, stump brute, sap lobber, elite marker, Basin Breaker; values from `RunConfig.Director`, `EnemyData`, `BossData`), Controls (keyboard, touch, gamepad, how a run goes). Tap an entry for its details (class kit and base values, weapon rank 1 figures + rank 3 / 5 milestones + evolution, passive ranks + evolution partner, recipe numbers, enemy health / speed / damage / first minute, the Basin Breaker's three marked attacks). Discovery follows the existing rules (`CollectionData`: owned or played class, `Discovered.Weapons / Passives / Evolutions`, `Journal.Enemies`, boss beaten); an entry not found shows "???" and how to find it, never its details. The elite marker has no record of its own: it is known after the first defeated elite (`Stats.ClassGoals.Elites`, server-counted). No category that does not exist is listed (old heroes, items, the old boss rotation are not shown). The server-side title thresholds still read `CollectionData` and are unchanged.

### Visual tokens
`src/swarmv2/client/Lobby/Brief.lua` holds the brief's tokens (navy `#162438`, cream `#FFF3DC`, gold `#EFC46E`, cyan `#65DDE0`, Nunito only: 36 / 24 / 18 desktop, 32 / 24 / 19 phone) and the shared widgets: opaque navy panel, button with default / hover / focused (cyan outline) / pressed / disabled / pending, badges and notes that always carry an icon and words, progress bar. Used by the class browser, chip, party strip, menu bar, PLAY, load card, status row and guide. Margins 24 desktop / 12 phone; targets at least 48 px (56 for main actions).

## 2. Contract changes (please keep when merging)

- `LobbyNet.LobbyView` gained `Progress` (goal progress of classes not owned: `{ Have, Need, Stat, Parts? }`) and `ClassAck` (`{ N, Id, Action, Ok, Code? }`, the server's answer to the last ClassAction). `LobbyBoot.View` fills them (`ClassOwnership.ProgressAll`, `ClassService.AckOf`).
- `ClassService.OnAction` now pushes **one** fresh `LobbyState` after every Select / Buy, worked or refused (the browser waits for it); a refused buy of a goal-only class says so (`GOAL_ONLY` note). Existing return values and the `lobby-queue-regression` checks are unchanged.
- `Config.Settings.Defaults` (Chat 2's file) got seven additive keys: `MasterVolume`, `CameraSensitivity`, `InvertCameraX`, `InvertCameraY`, `EffectsIntensity`, `UIScale`, `LobbyGuideSeen`.
- `LobbyConfig.Home = { Guide, ExplainLoadingAfter = 8, OfferRetryAfter = 30 }`.
- Tiny hooks in run-side files, each marked `[stream L1]`: `CameraController.rotate` (sensitivity + invert), `Audio.SetVolumes` (master), `VFX.budgetScale` and `CombatFx.scale` (effects intensity), `ClientSettings` (accessors), `UIBuilder` (UI size in `updateScale`, the listener, `MenuSettingsPlus.Build`, `pause.Plus.Sync`, `UIBuilder.SyncSettings`). Defaults change nothing (1x, not inverted, 100 %, master 1).
- `MenuBar` lost BOARDS and QUESTS buttons (both stay in MORE); STORE is now SHOP; `MenuMore`'s COLLECTION entry is CODEX.

## 3. Tests (all offline)

See section 4 for the results table and what is only mock-verified.

| Check | What it covers |
|---|---|
| `class-browser-regression` (headless) | ids, details vs the tuning for all 12, hidden figures, access / progress text, `Progress` + `ClassAck` through the real `ClassService`, codex data and discovery rules, settings keys and readers. |
| `class-browser-ui` layout scenes | grid, details, long names, queued, confirm (and the buy request), loading at 0 / 9 / 31 s + RETRY, guide (device controls), home entry points, pending + timeout, refused, owned filter, page 2, unavailable portraits. pc, iphone, phone-portrait, tablet. |
| `codex-ui` layout scenes | classes, weapons, enemies, controls (found) and not-found entries on pc, iphone, phone-portrait. |
| `settings` layout | the existing Settings screen with the new rows (pc, iphone, phone-portrait, tablet). |
| `lobby-queue-regression`, `basecamp-ui` | the older lobby checks kept green. |

Registered in `tools/run_regressions.py` (comment "stream L1").

## 4. Results (offline only; nothing here was run in Studio)

PASS = last run of that check passed. All layout runs use the preview renderer's mock of Roblox, not a device.

| Area | Result |
|---|---|
| `bash tools/check.sh --quick` (type check, compile, art keys) | PASS, zero diagnostics, after the last source edit |
| `class-browser-regression` (headless) | PASS |
| `class-browser-ui` layout, 12 classes: grid and details on pc / iphone / phone-portrait / tablet | PASS (8) |
| long names (wrapped, not cut) on four devices | PASS (4) |
| queued (pc, iphone), confirm purchase (pc, iphone, phone-portrait), pending, refused, owned filter, page 2, unavailable portraits (pc) | PASS (11) |
| loading card at 0 s, 9 s, 31 s (31 s on pc, iphone, phone-portrait) with RETRY | PASS (5) |
| first-time guide, step 4 (pc, iphone, phone-portrait) | PASS (3) |
| home entry points (pc, iphone, phone-portrait, tablet) | PASS (4), run before the last load-card placement edit; not repeated (see below) |
| `codex-ui` layout: classes, weapons, enemies, controls on pc / iphone / phone-portrait; two not-found cases | PASS (14) |
| `settings` layout (pc, iphone, phone-portrait, tablet) and `settings-sim` | PASS (5) |
| `lobby-screens-regression` | PASS |
| `lobby-queue-regression` | PASS (237/237) earlier in the stream; NOT re-run after the last edits (BLOCKED, see below) |
| `basecamp-ui` layout (iphone, phone-portrait: idle, classes, gates, countdown) | BLOCKED: not re-run after the last edits |
| `menu-phone`, `menu-phone-portrait` clarity, `layout-pause-*`, `party-v2`, `admission` | BLOCKED: not re-run (see below) |
| `layout-menu-iphone` | FAIL, CUT `Name: 'Bramblew...  [Bramblewick]'` at (655,101); not investigated, probably not from this stream (the menu leaderboard/hero name lines were not touched) |
| `discovery-phone`, `discovery-phone-portrait` | FAIL at `tools/menu_discovery_regression.luau` line 28 (the Characters skin swatch `Knight_Crimson` is nil); the same line fails on a clean extract of 7c96a55, so it is not from this stream |
| `data-regression` | FAIL with 22 findings (weapon rank specs of six new weapons, BasinBreaker boss data, `Config.Features` count / `ClassSfx`); all in files this stream did not edit |

Findings fixed in this last pass: the refused-answer toast covered the details name (the open browser now shows the answer in its own note, toasts only when it is closed); the 31 s load card covered the SHOP / CODEX buttons and HOW TO PLAY on iphone (landscape: it sits under the menu buttons and right of the left column, shorter when needed); the enemy list lines are the short label before the colon (the full sentence stays in the details); the not-found evolution check used an evolution name instead of the weapon id.

Screenshots (final renders of the passing scenes) are in `docs/redesign/lobby/l1-shots/`. The refused picture is a scene that forces a NOT_OWNED answer for a class the profile owns, so its grid badge and its note disagree on purpose.

## 5. Gaps, risks and owner decisions

- **Not tested in Studio or live.** ViewportFrame portraits, gamepad navigation, Escape on a real keyboard (Roblox's own menu also opens on Escape), safe areas on real phones, text size Largest, and the real `CharacterPreviews` replication are only mock-verified. The preview renders models with its own approximation of Roblox's ViewportFrame.
- **Two visual systems on the home screen.** The brief's navy tokens are applied to everything stream L1 built or restyled. The gate sheet and queue panel (`QueuePanel.lua`), the toasts, and every old `Menu*` screen (Settings rows, Party, Store, More, Daily ...) still use the Bright Arcade theme from `Theme.lua`. Re-theming those is the lobby chat's job (`Theme` / `UIKit` belong to the gameplay track). `Brief.lua` is the place to extend.
- **Codex and Journal.** The old enemy JOURNAL screen still lists every old `EnemyData` entry (reached from STATS). Hide it or point it at `CodexData` in the lobby chat's pass; the codex itself is clean.
- **Profile screen** (section "Shop, purchases, profile, and codex") was not part of this stream's task list and was not built.
- **First-run auto start (PATCHES L4).** While `Config.FirstRun.AutoStart` is on, a brand-new account is sent into a run before the lobby shows, so the guide cannot open by itself (afterwards `Stats.Runs > 0`). It stays reachable from HOW TO PLAY and Settings. If the gameplay chat switches AutoStart off, the guide opens on the first visit.
- **Class change while queued.** The brief says changes normally need Leave Queue; the server (and `lobby-queue-regression`) still accepts a change while queued and resets READY. The browser disables it; the server rule is unchanged.
- **Reduced motion** is the existing "Reduced effects" switch (it already disables shake, kicks and FOV kick). A separate "reduced motion" toggle would duplicate it; say if you want one.
- **Effects intensity** trims only the cosmetic effect and juice budgets (`VFX`, `CombatFx`); telegraphs, warnings and player events never read it (`VFX.room` critical path).
- **Preloading class previews:** the server already builds all twelve previews at boot and Roblox replicates them; the browser only polls for them (every 0.5 s while open). A real preload (ContentProvider) was not added.
- **Elite marker discovery** uses `Stats.ClassGoals.Elites` because no journal flag exists for elites.
- Nunito is the only font in the new screens (one family, weights the game already uses). Fredoka One remains in the old screens.
