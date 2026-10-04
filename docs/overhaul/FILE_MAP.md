# SWARM overhaul: file map

Every file changed between `83be6c9` (last release) and `59f533b`, what changed, and the doc that
covers it. Source: `git diff --stat 83be6c9..HEAD` (144 files, +13,052 / -2,377). All docs are in
`docs/overhaul/` unless a path is given.

## Setup and run (the project's own workflow)

```
bash tools/check.sh              # type check (zero diagnostics) + Rojo build; --quick skips the build
python3 tools/run_regressions.py # all 83 offline regression checks (evidence goes to ../verification)
bash tools/preview/render.sh <scene> --device pc|phone|phone-portrait   # preview renders (docs/PREVIEW.md)
/tmp/sh-tools/rojo/rojo build default.project.json -o build/Swarm.rbxlx  # place file for Studio
```

New preview scenes from this overhaul (render or sim): `corner-regression`, `choice-regression`,
`portal-hold-regression`, `safety-sim`, `settings-sim`, `reward-once-regression`, `results-flow`,
`results-ledger`, `reward-card`, `ui-stack`, `hud-build`, `enemy-slice`, `friendly-fx`, `props`.
New Lune script: `tools/uistate_regression.luau`. Extended: `audio-sim`, `tools/audio_regression.luau`.

## Server (`src/server/Modules/`)

| File | What changed | Doc |
| --- | --- | --- |
| EnemyAI.lua | Look-ahead ray capped at the target, low origin, contact fallback (`BlockNormal`), head-on tie-break | CORNER_REPORT |
| EnemySpawner.lua | Notice ids/classes (`wave.N.*`, `elite`, `swarm.approach`, `nest.*`); `EliteSpawn` sound | NOTIFY_SERVER |
| LevelUpSystem.lua | Bounded choice state (panel deadline, merge, `OfferId`, deferral, budget), auto-pick of every round; elite-chest gold uses `EliteLateStageScale` from stage 3 | CHOICE_STATE, BALANCE_TUNE 5 |
| RunManager.lua | `IsGroupChoice`, `ChoiceBudget`, `GrantChoiceGrace`, `HoldReward` (solo only), protection test in `DamagePlayer`; `NotifyPayload` (Id/Lane/Class); real stage-1 boss name; return-flow hooks | CHOICE_STATE, NOTIFY_SERVER, FLOW |
| StageManager.lua | Group stage-clear countdown waits for an open choice (max 12 s, `ChoiceLeftHeld`); tagged broadcasts | NOTIFY_SERVER |
| RunServers.lua | One-step home after defeat results / MAIN MENU, `Hold` (STAY) and `Replay`, one departure per player | FLOW |
| LeaderboardService.lua | Replies carry `MyBoard` / `MyQueued`; pruned throttle table; local boards only when DataStores are off | FLOW |
| LootSystem.lua | Chest models per tier, rune monuments, shrine crowns, opened-state quieting; odds "before luck", Bargain text; notice ids | PROPS_ART, BALANCE_TUNE 3, NOTIFY_SERVER |
| CaravanEvent.lua | Cart model, dashed ring, quiet Saved state; notice ids | PROPS_ART, NOTIFY_SERVER |
| MapBuilder.lua | Arena corners, rim caps, fence removal, pond banks, hazard circles (arena); lobby dusk lighting (lobby); portal beam (`BuildPortal`) | WORLD_ART, TITLE, PROPS_ART |
| ModelBuilder.lua | Part-built hero fallback: SmoothPlastic big shells | HERO_ART |
| BossAI.lua | Notice ids (`boss.armor`, `boss.banner`, phase headlines) | NOTIFY_SERVER |
| DataService.lua | `releasing` guard: a rejoin waits for this server's leave save; leave save pcall-guarded. No schema change | SAFETY 3 |
| MonetizationService.lua | Malformed receipts refused; unknown pass ids ignored; `_ProcessReceipt` exposed for tests | SAFETY 2 |
| GoldSystem.lua | Lobby "upgraded to level" success notices removed (rows update) | NOTIFY_SERVER 4 |
| DevTools.lua | DEV broadcasts tagged `dev` | NOTIFY_SERVER |
| PartyService.lua | Notify payload carries Id/Lane/Class | NOTIFY_SERVER |

## Client (`src/client/`)

| File | What changed | Doc |
| --- | --- | --- |
| UIState.lua (new) | Primary overlays, lanes, holds, watchdog, `Reset` | UI_STATE_CONTRACT, UISTATE |
| UIBuilder.lua | show/hide through UIState, toast = notice renderer; upgrade choice panel (04); compact reward card and contained reveal (05); results (06); run menu drawer (07); InputPrompts in reel skip and choice hint | UISTATE, UPGRADE_UI, REWARD, RESULTS, DUO_MENU |
| Hud.lua | Vitals top left, objective under the timer, quiet tray, BUILD details; banner = headline renderer | HUD, UISTATE |
| StageUI.lua | Semantic headline ids, Travel primary; amber wave edge; portal marker clears corner panels | UISTATE, HUD |
| LootUI.lua | Prompt hidden / hold refused unless world input allowed; strip follows vitals; recent rewards; prompt icon by tier; Bargain chip | UISTATE, HUD, REWARD |
| MiniMap.lua | Legend "Portal" with its own key, 10 px labels, bigger desktop map | HUD |
| LobbyScreen.lua | Home rebuilt to approved 01 | TITLE |
| MenuPlay.lua | Run-setup step (mode, world, difficulty, curses, Endless, Daily, last run) | TITLE |
| MenuCharacters.lua | Sticky EQUIPPED / PREVIEW strip, mastery rules, cumulative purchase line | TITLE |
| MenuUpgrades.lua | Hero Upgrades card text and box fixed | TITLE |
| MenuLeaderboards.lua | Card shows the row value + save best line; one retry chain | FLOW |
| MenuParty.lua | Party copy (SOLO/Daily), `PartyJoin` sound | DUO_MENU |
| NoticeDots.lua | MORE dot counts only Achievements and Track | NOTIFY_SERVER 4 |
| CameraController.lua | `MenuHeroX` menu framing | TITLE |
| TravelOverlay.lua | One countdown (hidden while results are open), "Main lobby" wording | FLOW |
| InputPrompts.lua (new) | Last-input-aware prompt text | COPY 3 |
| Tutorial.lua | Staged portal/boss tips, input-aware Move tip | COPY 2-3 |
| EnemyRenderer.lua | Partial hit flash, crimson elite ring, low-detail mite cut | ENEMY_ART |
| Telegraphs.lua | Crimson fire-patch rim, Healer pulse rim | ENEMY_ART |
| ModelLibrary.lua | Enemy/boss fallbacks recoloured, Swift aura, totem/snare/soul builders, `Grip` animation | ENEMY_ART, VFX_ART |
| VFX.lua | Totem pulse, snare cast/release, dashed friendly rings, coin/gem bursts, aura edge, fallback flash | VFX_ART |
| PortalBeacon.lua | Thinner pillar, shorter pulse, none while charging or in boss | PROPS_ART |
| GroundDetail.lua | No ground pieces under rims and corner steps | WORLD_ART |
| Audio.lua | Voice reserve for warnings, extra ducking | AUDIO_MIX |
| ClientSettings.lua | Recently sent values are not overwritten by an older sync (5 s) | SETTINGS_TEST |

## Shared (`src/shared/`)

| File | What changed | Doc |
| --- | --- | --- |
| Config.lua | New and changed keys (list in MIGRATION_ROLLBACK.md); new sounds | MIGRATION_ROLLBACK, BALANCE_TUNE, CHOICE_STATE, AUDIO_MIX |
| ItemData.lua | `StagePrice` late term (stage 3+, capped at stage 5); item text qualifiers and "m" | BALANCE_TUNE 5, COPY 4 |
| StatSheet.lua | Line labels and units (Damage reduction, max HP, m) | COPY 4 |
| PassiveData.lua | Description qualifiers | COPY 4 |
| CharacterData.lua | Text ("m", Sword); hero and skin palette steps (Gold Trim unchanged) | COPY, HERO_ART |
| WeaponData.lua | Display names Sword / Bloodblade | HERO_ART |
| SynergyData.lua | Bulwark description (Sword) | HERO_ART |
| IconData.lua | Fallback glyphs "Sw" / "BB" | HERO_ART |
| MeshCatalog.lua | Regenerated: new mesh ids (Mite, Scorpion Queen, Moth Matriarch, Shot_Totem), hero materials/palettes | ASSET_REGISTER |

## Models, meshes and renders

| Files | What changed | Doc |
| --- | --- | --- |
| blender/models/enemies.py, bosses.py | Mite, Scorpion Queen, Moth Matriarch | ENEMY_ART |
| blender/models/items2.py | Shot_Totem idol | VFX_ART |
| blender/models/heroes.py, heroes2.py, hats.py | Materials and palettes (Knight, Priest, Engineer, Necromancer, helm) | HERO_ART |
| meshes/Enemies/*.fbx, meshes/Projectiles/Shot_Totem.fbx, meshes/Heroes/*.fbx, meshes/Hats/Hat_Helmet.fbx | Rebuilt exports | ASSET_REGISTER |
| meshes/catalog.json, meshes/uploaded_ids.json | Catalog data and four new uploaded ids | ASSET_REGISTER |
| renders/** | Blender preview renders and sheets | ASSET_REGISTER |

## Tools and tests

| File | What changed | Doc |
| --- | --- | --- |
| tools/run_regressions.py | Added corner, choice, portal-hold, safety, settings, reward-once, uistate, results-flow, leaderboards checks; corner max-time 3000; results-flow runs with the client | TEST_REPORT |
| tools/uistate_regression.luau (new) | 34 UIState checks | UISTATE |
| tools/audio_regression.luau | Reserve voices, EliteSpawn | AUDIO_MIX |
| tools/ui_regression.luau | HUD build-details checks, compact reward checks | HUD, REWARD |
| tools/menu_clarity_regression.luau | Home section rewritten for the title screen | TITLE |
| tools/preview/runtime/mock/init.luau, classes/world.luau | Opt-in `preview.setRaycast` hook | CORNER_REPORT |
| tools/preview/scenes/corner-regression, choice-regression, portal-hold-regression, safety-sim, settings-sim, reward-once-regression, results-flow, results-ledger, reward-card, ui-stack, hud-build, enemy-slice, friendly-fx, props (new) | New regressions and render scenes | per area doc |
| tools/preview/scenes/audio-sim, accessibility-sim, leaderboards, levelup, menu, pause, progression-regression, reward-regression, rewards, runserver-sim, settlement-lifecycle | Updated for the new screens and flows | per area doc |

## Other docs

| File | What changed | Doc |
| --- | --- | --- |
| docs/PERFORMANCE.md | Arena part counts | WORLD_ART, NOTIFY_SERVER 6 |
| docs/PREVIEW.md | `hud-build` scene | HUD |
| docs/ICON_LIST.md, docs/ICON_CHECKLIST.md | Sword / Bloodblade names | HERO_ART |
| docs/overhaul/*.md (new) | Area reports, register, contract and these handoff files | this folder |
