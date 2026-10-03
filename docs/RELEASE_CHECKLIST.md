# Release checklist (publish-readiness pass, 2026-10-03)

Verdict per area after the full offline pass over `main` (3307395 plus this batch). The
rule: **PASS** = verified in the offline preview / regression suite (real game modules on
the mock Roblox API); **BLOCKED** = can only be verified in Studio or a live server, with
the owner's steps below; **FAIL** = a known problem left in the build. Nothing in this
document was tested in Studio or on a real phone unless the owner's section says so.

## 1. Verdicts

| Area | Verdict | Evidence / what is left |
|---|---|---|
| Type check, compile, icon art | PASS | `tools/check.py --quick`: 0 diagnostics, 108 scripts compile, 0 icon problems |
| Offline regressions | PASS | `tools/run_regressions.py`: 61/61 (the 45 earlier checks plus 16 new `layout-*` phone checks); every scene 0 game errors |
| Phone UI scale (landscape / portrait, notch phones) | PASS (offline) | PhoneReferenceSize design space, text 20 % bigger (Theme.TextScaleCompact); `iphone` device profile with notch insets reproduces the owner's screenshots and now renders dimmers edge to edge |
| Overlays over the HUD (level-up, revive, pause, results, chest, portal, items, bug report) | PASS (offline) | full-screen dimmers (UIKit.Bleed), HUD + minimap hidden under covering modals (Hud.SetCovered); automatic layout check 0 overlap / 0 off-screen / 0 under top bar over 120 renders (30 scenes x pc, iphone, phone, phone-portrait) |
| Phone level-up touch safety | PASS (offline) | TouchArm 0.8 s, complete-tap rule (slop 24 px, hold < 0.6 s), thumbstick / JUMP zone guarded 1.2 s; 4 new checks in `tools/ui_regression.luau` |
| Upgrade pop-up pacing | PASS (config) | Config.XP 30 + 12/level to 20 then +6 (level 1 = 42, 20 = 270, 50 = 450), co-op share 0.5 / 0.36; `levelrate-sim` ~2.4 level-ups per minute solo. Real pacing is an owner playtest call |
| Lobby screens (home, characters, shop, arenas, daily, curses, endless, party, countdown, leaderboards, stats, achievements, journal, track, settings, bug report, DEV) | PASS (offline) | all render with 0 errors on 4 devices; fixes this pass listed in section 2 |
| Run flows (solo / duo / trio / daily / endless, run servers + Studio fallback, reconnect) | PASS (offline) | `stage-sim`, `endless-sim` (via regressions), `runserver-sim` lobby + run, `coop-regression` success / expired / ended / forged, `reconnect-lobby`. Live teleports BLOCKED |
| Level-up, chests / reel, shrines / altar, caravan, synergies | PASS (offline) | `reward-regression`, `rewards-sim` (TESTING.md), `encounters-sim`, `expedition-sim`, `synergy-sim`, `caravan-sim` |
| Bosses (Queen, Matriarch, Warlord, Hive Mother, Briar Sentinel, Frostbound Colossus) | PASS (offline) | `boss-sim` per boss: entrance, cycle, phase 2, kill mid-attack, collapse, surge, travel cleanup |
| Portal / stage travel, revive, pause / main menu, results, return to lobby | PASS (offline) | `stage-sim`, `run-manager-regression`, `settlement-lifecycle`; revive hold rules in `ui_regression` |
| Saves (schema 6, migrations, outage, settlement) | PASS (offline) | `storage-sim` incl. `outage=all`, `settlement-lifecycle`; live DataStores BLOCKED (Studio API access is the owner's step) |
| Leaderboards / records / DEV taint | PASS (offline) | `endless-sim` and `stage-sim` print the boards; DEV-tainted runs never recorded |
| Purchases (3 passes, 4 products in Config.Monetization) | BLOCKED | ids in Config, owner verified them in Studio earlier; receipts / retry only testable live. No prices or products were touched |
| Skin passes (12) | BLOCKED (owner) | pictures in `art/store/skins/` (Priest_Angel now shows its halo); ids still 0, tiles read SOON until the owner creates the passes (docs/SKIN_PASSES.md) |
| Remotes: validated, rate-limited, no client trust | PASS (review) | every client remote goes through `Remotes.Listen` (token bucket + pcall); the two direct `OnServerEvent` handlers (LootHold / ReviveHold release) only clear a hold |
| DEV access | PASS (review) | server-checked (`DevAccess`, `DevAllowlist` = owner); `Config.Dev.ShowInLiveGame = false` |
| Text filtering (bug reports) | PASS (offline) | `bugreport-sim`; the mock filter stands in for Roblox's, so the live filter result is BLOCKED |
| Performance budgets | PASS (offline, unchanged) | docs/PERFORMANCE.md numbers from 2026-10-02 still apply (no renderer / spawner change in this pass); real phone FPS BLOCKED |
| Audio | BLOCKED (owner) | offline `audio-sim` passes; audibility, licensing and asset access need the live checks in docs/AUDIO.md |
| Code health | PASS | no TODO / FIXME; only 3 boot `print`s; `warn` only on failure paths |

## 2. Fixed in this pass

1. Pause / settings toggles on phones ("REDUCED EFFE...", descriptions cut mid-sentence):
   titles shrink a little before truncating, descriptions scale into their two lines
   (`UIKit.Toggle`).
2. Tab rows on narrow screens ("ACHIEVEMEN..."): tab titles shrink instead of truncating
   (`UIKit.Button` `Shrink`, used by `UIKit.Tabs`).
3. HUD stage pill running under the health panel on landscape phones ("OPENING THE PORTAL ·
   60%"): any objective measured too wide now uses its short form (OPENING / DORMANT / SURGE,
   DEFEAT THE BOSS), keeping the count (`Hud.lua`).
4. Minimap under the JUMP button on landscape phones when the team rows push it down: it
   moves left of the button's column, and hides while it would sit on the ability panel
   (`MiniMap.lua`); in portrait it also stays under the curse / bargain / synergy chips.
5. Tutorial tip card (no target, e.g. the team rules) covering the minimap and team rows on
   phones: goes to the left side; it already lets touches through (`Tutorial.lua`).
6. Loot prompt over the minimap on phones: moves under the map or left of the loot
   (`LootUI.lua`).
7. Characters screen on landscape phones: the hero caption between the panels read
   "KNI..."; it hides when there is no room (the details panel names the hero).
8. Priest_Angel skin-pass picture had no halo (thin ring dropped by the matting):
   `tools/make_skin_pass_images.py` keeps thin pieces near the hero; picture regenerated.
9. New automatic layout check `tools/preview/check_layout.py` (text over text, text off
   screen / under the Roblox top bar, panels off screen, text partly under a later panel,
   truncations), wired into `run_regressions.py` as 16 `layout-*` checks (8 screens x
   iphone + phone-portrait). `docs/PREVIEW.md` documents it.
10. Four phone level-up touch regressions (tap before arm, thumb-zone tap, long press,
    complete fresh tap) in `tools/ui_regression.luau`.

## 3. Known, left as is

- Results on landscape phones: the settlement line and BUILD row sit in the scroll area
  (tiles and account XP show without scrolling). Cosmetic.
- Leaderboards on landscape phones show 1.5 rows before scrolling (tabs + STANDARD /
  ENDLESS switch take the room). Works, cramped.
- Countdown panel: "+45% gold · Frenz..." truncates curse names on purpose (the bonus wins).
- Item popups and a shrine prompt can share the left column on landscape phones while a
  prompt shows (both transient).
- Revive price in the offline preview is a placeholder; the live price comes from
  MarketplaceService.

## 4. Owner: Studio / live steps before publishing

Do these in order; stop and report the first thing that fails.

1. **Open the place**: `build/Swarm.rbxlx` (or `rojo serve` + connect). Play solo. Output
   must show `[SWARM] server ready (v1.0.0)` and no red errors. If it also says
   "DataStores OFF", go to step 2 first.
2. **Enable saving**: Game Settings → Security → **Enable Studio Access to API Services**
   (Studio uses the separate `_Studio` DataStores, live saves are untouched). Play again:
   the lobby must not show "Progress isn't being saved right now".
3. **Phone check (your phone, landscape and portrait)**: lobby home, CHARACTERS, SHOP,
   DAILY, start a solo run, level up (cards must not pick themselves when your thumb is on
   the stick: wait ~1 s then tap once), pause menu (every toggle label readable), die
   (revive offer), results. The dimmer must reach every screen edge and the HUD must be
   hidden under level-up / pause / revive / results. Screenshot anything odd.
4. **Co-op**: Duo from two devices (or Studio two-player test). Level-up on one device
   must not freeze the other; PING, revive hold, team rows, minimap position with 2 rows.
5. **Bosses**: DEV → Spawn portal boss on stages 1-6 (Queen, Matriarch, Warlord, Hive
   Mother, Briar Sentinel, Frostbound Colossus): entrance, phase 2 under 40 % HP, kill,
   surge, portal, NEXT STAGE. Watch FPS on the phone during the surge (Settings →
   Performance Stats, see docs/PERFORMANCE.md).
6. **Endless and Daily**: one Endless run past stage 5 (score only on the ENDLESS board),
   one scored Daily attempt (second start is PRACTICE).
7. **Purchases (test only, Studio sandbox)**: each gold product and the Revive once;
   gold / revive granted exactly once, no duplicate after a rejoin.
8. **Skin passes**: create the 12 passes with the pictures in `art/store/skins/`
   (docs/SKIN_PASSES.md), send the ids; until then the tiles read SOON.
9. **Audio**: the live checks in docs/AUDIO.md (tracks play on the phone, no asset-access
   errors, music / effects sliders).
10. **Live server check after publishing**: join from the phone, play one run, confirm the
    save persists after rejoin, DEV button visible only to you (UserId 20194281), the
    leaderboards fill, and no red errors in the Developer Console (F9 / `/console`).

Report each step as PASS / FAIL with a screenshot where it looks wrong.
