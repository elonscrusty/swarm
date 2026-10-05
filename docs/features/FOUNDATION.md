# FOUNDATION: shared groundwork for the 30-features batch

Wave 0 of the batch (brief: 2026-10-05). It adds feature switches, save fields, the server
encounter hook, client HUD slots and a cosmetics registry. While no feature uses them, the
game plays exactly as before.

Verified offline (Lune): `check.sh --quick`, data-regression, security-regression,
safety-sim, storage-sim, settlement-lifecycle, stage-sim, hud-key-regression and the new
`foundation-regression`. Studio, phones and live servers are BLOCKED (nothing has been
tested there).

## 1. Feature switches (`src/shared/Config.lua`)

`Config.Features.<Name> = true` turns a feature on. Read it with `Config.FeatureOn(name)`;
an unknown name counts as off. When a switch is `false`, the game must behave exactly as it
did before that feature existed.

| # | Flag | # | Flag |
|---|------|---|------|
| 1 | `Sigils` | 17 | `QuickPings` |
| 2 | `MapEvents` | 18 | `CoopBoss` |
| 3 | `MiniBosses` | 19 | `TeamBoard` |
| 4 | `SecretRooms` | 20 | `Spectate` |
| 5 | `TrialShrine` | 21 | `WeeklyChallenge` |
| 6 | `Merchant` | 22 | `SeasonTrack` |
| 7 | `CursedChests` | 23 | `Titles` |
| 8 | `Rescue` | 24 | `CollectionBook` |
| 9 | `Weather` | 25 | `LoginStreak` |
| 10 | `BossIntro` | 26 | `Announcer` |
| 11 | `NewHeroes` | 27 | `HitFeel` |
| 12 | `SecondSkill` | 28 | `MusicSlots` |
| 13 | `Ultimate` | 29 | `PhotoMode` |
| 14 | `BuildPresets` | 30 | `LobbyFun` |
| 15 | `WeaponMastery` | – | `Store` |
| 16 | `TeamCombo` | | |

Other new config:
- `Config.Encounters.Director` sets the director's caps and spacing: `MaxActive` (2), `MaxAmbient` (1),
  `MinDistance`, `Clearance` and `Spacing`.
- `Config.FeatureHud` holds the HUD slot settings: `UltimateKey` (Q), `UltimatePad` (ButtonR1), `UltimateSize`,
  `BadgeSize`, `MaxBadges` and `AnnounceSeconds`.
- `Config.Data.Caps` holds the size caps for the new save fields.
- `Config.Monetization.Cosmetics = {}` is empty for now. STORE adds an entry here for each cosmetic pass or
  product, with `Id = 0` until the owner creates it.

## 2. Save fields (`DataService`, additive, no schema bump)

These fields are added to `defaultData()` and cleaned by `DataService.CleanFeatureFields(data)`.
`Migrate` calls that function on every load. When a field is missing or has the wrong
shape, it gets its default. Ids must be strings of 1-64 characters, and sets are capped.
Unknown ids are kept, so nothing a player earned is lost. The schema version stays at 7.
`GoldSystem.SyncProfile` sends all of these fields to the client as
`ProfileSync.Features` (built by `DataService.FeatureView(data)`).

| Field | Shape | Notes |
|---|---|---|
| `Sigils` | `{ Owned = {id → os.time()}, Equipped = {id, ...} }` | Equipped Sigils must be owned. There are at most `Caps.SigilSlots` (2) of them, and at most `Caps.Sigils` (64) owned. The slot-2 mastery gate is checked by the equip remote (META). |
| `Weekly` | `{ Week, Score, Plays, BestScore, BestWeek }` | Whole numbers, the same idea as `Daily` |
| `Season` | `{ Id = "", XP, Claimed = {tostring(tier) → true} }` | Up to `Caps.SeasonClaims` claims |
| `Titles` | `{ Owned = {id → true} }` | The title being worn is still `data.Title`. Achievement and level-track titles stay derived from those systems. |
| `Collection` | `{ Seen = {"Kind:Id" → true} }` | Holds ids not already in `Journal.Enemies` or `Discovered.*` (for example `Boss:ScorpionQueen`) |
| `LoginStreak` | `{ Day, LastDay, Best }` | `Day` is the current streak length. `LastDay` is the UTC day number of the last claim, `os.time() // 86400`. |
| `Presets` | `{ List = {{Hero, Weapons {id}, Passives {id}}}, Active = {heroId → index} }` | Up to `Caps.Presets` (6) presets, each with up to `Caps.PresetPicks` (12) ids per list. Presets have no player-typed names, so no text filtering is needed. |
| `WeaponMastery` | `{weaponId → count}` | Whole numbers, up to `Caps.WeaponMastery` weapons |
| `Cosmetics` | `{ Owned = {id → true}, Equipped = {Trail, Burst, Pet, Emote, Nameplate, Dais} }` | `""` means nothing is worn. Skins stay in `data.Skins`, the worn title in `data.Title`, and the dais ring in `data.Ring`. |
| `Supporter` | boolean | Records that the one-time Supporter pass was seen. Load never clears it. |

Some features need no new field:
- **Second skill and ultimate (12, 13):** gated by Hero Mastery, so they read the mastery level from `data.Heroes[hero].XP`.
- **New heroes (11):** a hero is unlocked by `OwnedCharacters[id] = true`, like every other hero today. The
  `CharacterData.Unlock = { Achievement = id }` entry decides how it is earned. An early-unlock
  product sets the same flag. The `Migrate [6]` hero-mastery seeding covers new heroes too, because it loops over `CharacterData.Order`.
- **Team board and weekly board (19, 21):** they live on OrderedDataStores (LeaderboardService), not in the save.

The equip, claim and grant remotes for these fields belong to the feature that owns each one.
They must check ownership on the server, and they must award nothing on DEV-tainted runs.

Tests: `data-regression` covers defaults, keeping valid data, cleaning, caps and stability. `security-regression`
adds 11 malformed fixtures and checks that a save cannot forge ownership.

## 3. Server: `EncounterDirector` (`src/server/Modules/EncounterDirector.lua`)

Register a feature once, in that feature module's `Init`:

```lua
local EncounterDirector = require(script.Parent.EncounterDirector)
EncounterDirector.Register("Merchant", {
	Feature = "Merchant",          -- Config.Features key (default = the name)
	Ambient = false,               -- true = map-wide (weather, events): no spot, own cap
	Weight = 1,                    -- pick weight at stage start
	Allow = function(info) return true end,            -- optional
	OnStageStart = function(info) return started end,  -- true = it runs this stage
	OnTick = function(dt, info) end,                   -- every simulated frame
	OnStageEnd = function(info) end,                   -- the stage ended while it ran
	OnCleanup = function(reason) end,                  -- ALWAYS, must be idempotent
	OnPlayerOut = function(rp, reason) end,            -- "Death" | "Portal" | "Abandon" | "Leave"
})
```

`info` = `{ Arena, Stage, ArenaName, PortalPos, Rng, Phase }`. `Rng` is the director's own
`Random`, so the existing loot and stage rolls don't change.

API:

| Call | What it does |
|---|---|
| `FindSpot(name, opts?) → Vector3?` | Finds and reserves a free spot, kept away from the portal (`Chests.PortalClearance`), every loot object, the caravan and the other reserved spots. It uses the same rules as the optional locations. `opts` can override `MinDistance`, `Clearance`, `Spacing` and `EdgeMargin`. |
| `Release(name)` | Frees the spots that `name` reserved |
| `Begin(name) → bool` | Asks for a running slot in the middle of a stage, within the caps |
| `Finish(name)` | Marks `name` as done and frees its spot |
| `IsActive(name)` | Whether `name` is running now |
| `ActiveCount(ambient?)` | How many encounters are running |
| `Stage()` | The `info` table of the current stage |
| `Reserved()` | The spots reserved so far |
| `Registered()` | The names registered so far |
| `Unregister(name)` | Removes a registration |

Caps: at most `MaxActive` placed encounters and `MaxAmbient` ambient ones run at the same time. Each
callback runs inside `pcall`, so an error is logged at most once every 5 s and the other features keep going.

Where it is called (already wired):
- `StageManager.buildStage` calls `StageStart(arena, n, portalPos, arenaName)`. This happens after
  `LootSystem.BuildStage` and before `EnemyAI.SetArena`, so colliders added at stage start count.
- `StageManager.Step` calls `Step(dt)` while the run simulates, which is never during travel.
- `StageManager` calls `StageEnd("Travel")` on the travel fade, before the next arena is built.
  `StageManager.EndRun` calls `StageEnd("RunEnd")`. The run ends this way for a defeat, for the last player
  leaving through the portal or MAIN MENU (abandon), and for server cleanup.
  `StageEnd` calls `OnStageEnd` for the encounters that were running, then `OnCleanup` for
  **every** registered encounter, including ones whose switch is off.
- `RunManager` calls `PlayerOut(rp, reason)` when a player dies (`finalizeDeath`), returns through the portal,
  abandons the run, or leaves the game.

Test: `foundation-regression` runs 6 stages across the biomes. It covers the caps, the spacing, cleanup on travel
and at run end, flags switched off, a feature that throws, and the empty director.

## 4. Client: `FeatureHud` (`src/client/FeatureHud.lua`)

`FeatureHud` is its own ScreenGui named `FeatureHud`, with `DisplayOrder` 11, safe insets and real pixels. It starts in
`ClientMain` after TeamPings. The whole gui is hidden outside a run and whenever
`UIState.Covered()` is true (level-up, rewards, pause, results, travel). Nothing shows
until a feature uses one of its slots.

| Slot | API |
|---|---|
| Badges, top right, under the counters and minimap | `Badge(id, { Text, Color, Order }) → Frame`, `RemoveBadge(id)`. At most `MaxBadges` show, lowest `Order` first. |
| Announcer, centred line in the upper third | `Announce(text, { Color, Seconds })`. `""` clears it, and a new line replaces the old one. |
| Ultimate, round button above JUMP, plus Q / ButtonR1 | `SetUltimate({ OnActivate, Charge = 0..1, Label })`. Call `SetUltimate(nil)` to hide it. Also `UltimateReady()` and `FireUltimate()`. The button only fires at full charge, while the player is alive and the HUD is visible. |
| PingWheel, centred holder | `Slot("PingWheel")` (TEAM fills it), `SetPingWheel(open)`, `PingWheelOpen()` |
| Any slot | `Slot("Badges" / "Announcer" / "Ultimate" / "PingWheel") → Frame`, `Visible()`, `OnVisibility(fn)` |

The existing `TeamPings.lua` keeps its PING button, which keyboard G toggles. The wheel slot is there for TEAM to extend it.
The ultimate key does not reach the game server: HEROPOWER adds its own remote inside `OnActivate`.

## 5. Cosmetics registry (`src/shared/CosmeticData.lua`)

Kinds: `Skin, Trail, Burst, Pet, Emote, Nameplate, Dais, Title`.
Each entry is `{ Id, Kind, Name, Source, Condition?, StoreKey?, Character? }`, where `Source` is one of:
- `"Default"`: every player has it.
- `"Earned"`: earned by play. `Condition` holds the short text that tells the player how.
- `"Store"`: bought with Robux. `StoreKey` is a path into `Config.Monetization`, such as `"SkinPasses.Knight_Crimson"`
  or `"Cosmetics.Trail_Ember"`. If the id at that path is 0, the item shows as "Coming soon".

API: `Add(entry)`, `Get(id)`, `OfKind(kind)`, `StoreId(id)` and `ComingSoon(id)`, plus the
`Items` and `Order` tables.

The registry is already filled with:
- a `<Kind>_None` default for each slot kind
- every existing skin (the skin passes, and the Starter Pack for Gold Trim)
- every achievement title and level-track title, as Earned entries

STORE and META add the rest. Robux only ever buys cosmetics.
