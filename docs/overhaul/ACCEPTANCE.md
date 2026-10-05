# SWARM overhaul: acceptance checklist

Every line of `SWARM_Overhaul/03_ACCEPTANCE_CHECKLIST.txt`, build `59f533b` (base `83be6c9`).

**How to read it.** Evidence types: *code* = code review; *sim* = offline Lune simulation of the
real modules on the mock Roblox API; *render* = preview renderer; *bot* = scripted econ-sim
cohorts. No line has Studio, device, gamepad, two-client or live evidence.

- **PASS (offline)**: every part of the line that can be checked offline was checked and passed.
  Any Studio/device part is named in the notes.
- **FAIL**: a part of the line is not met.
- **BLOCKED**: the line itself needs Studio, a real device, a gamepad, two real clients or live
  service, and offline evidence cannot stand in for it.
- **NOT RUN**: could be checked offline but was not.

Totals: PASS (offline) 54, FAIL 4, BLOCKED 5, NOT RUN 5 (68 lines).

## Scope and baseline

| # | Line | Result | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 1 | Project and instructions audited; systems and owners mapped | PASS (offline) | code; ISSUE_REGISTER (owners per entry), FILE_MAP | |
| 2 | Unrelated WIP and Studio-only assets preserved; recoverable baseline and rollback | PASS (offline) | git (`83be6c9` baseline, clean tree), MIGRATION_ROLLBACK 3 | Studio-only assets cannot be seen from the repo; nothing replaced the place file |
| 3 | Seven PNGs and full review inspected; illustrative values not copied | PASS (offline) | TITLE, HUD, UPGRADE_UI, REWARD, RESULTS, DUO_MENU side-by-sides | Real data bound everywhere; title's "EXAMPLE VALUES" footer not drawn |
| 4 | Existing Settings design retained | PASS (offline) | SETTINGS_TEST, DUO_MENU | The settings rows are unchanged. In a run, ITEMS / MAIN MENU / leave moved from the settings modal into the run-menu drawer (DUO_MENU); owner should confirm that counts as allowed |
| 5 | No combining / fusion / new evolution system | PASS (offline) | code; UPGRADE_UI, HERO_ART | Whip shown as Sword is a display name only |
| 6 | Every confirmed in-scope issue has a fix or documented disposition and evidence | FAIL | ISSUE_REGISTER | 8 open (UI-11, UI-30, CP-02, CP-05, CP-11, CP-16, ART-22, ART-24), 36 partly |

## Corner farming and combat integrity

| # | Line | Result | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 7 | Exact pocket reproduced with recorded hero, build, modifiers, stage/wave, enemy mix, location | FAIL | sim; CORNER_REPORT, BALANCE_AUDIT 5.3 | Same SE corner, but a controlled set-up (default hero, no weapons, stage 1); the recorded late build and wave were not reproduced. Studio repro BLOCKED |
| 8 | Open field, straight wall, other corners/edges and biome joins compared | PASS (offline) | sim; CORNER_REPORT | 6 arenas, field, 4 walls, 4 corners, 3 pockets each |
| 9 | Reach/steering/collision/crowding, attack eligibility, damage, healing, knockback measured separately | PASS (offline) | sim; CORNER_REPORT, BALANCE_AUDIT 5.3 | |
| 10 | Report acknowledges damage/recovery and names the real root cause | PASS (offline) | CORNER_REPORT | Ray past the target; sustain ruled out |
| 11 | Small/crowded enemies, elites, melee/ranged, party modes, bosses exercised | NOT RUN | sim; CORNER_REPORT | All but party modes passed; co-op targeting not run |
| 12 | Fixed without stationary punishment, teleport damage or score cuts | PASS (offline) | code; CORNER_REPORT | |
| 13 | Kiting, defensive builds, wall collision, out-of-bounds, scoring still correct | PASS (offline) | sim; CORNER_REPORT, BALANCE_AUDIT 5.3, FLOW 2 | Real hero physics at the wall assumed (Studio) |

## State coordination and rewards

| # | Line | Result | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 14 | Portal, wave, elite, caravan, reward, level-up events together without duplicate/overlap | PASS (offline) | sim + render; UISTATE (ui-stack), uistate_regression | |
| 15 | Explicit priority and one primary input owner | PASS (offline) | UI_STATE_CONTRACT 2 | |
| 16 | Death, disconnect, respawn, leaving, stage change: no stale UI, no lost grants | PASS (offline) | sim; UISTATE 5, CHOICE_STATE (cancellation), REWARD (leave case) | Real disconnects untested |
| 17 | Common rewards compact, non-blocking, correct item/rank/effect, later inspection | PASS (offline) | sim + render; REWARD | Weapon-rank "current -> next" line not recorded (UI-34) |
| 18 | Special reveal clipped, skippable, exact-once independent of animation | PASS (offline) | sim; REWARD (reward-once 29/29) | |
| 19 | Pending rounds visible, stable, applied once, not silently auto-picked or discarded | PASS (offline) | sim + render; CHOICE_STATE, UPGRADE_UI | Auto-pick at the deadline is disclosed ("AUTO-PICK ALL n"); round count hidden on landscape phones |
| 20 | Paid chest name, run-gold price, affordability, odds, input-aware hold disclosure | PASS (offline) | code + render; REWARD, BALANCE_TUNE 3 | Hold on a real touch device untested |
| 21 | Critical-HP pickups keep movement, HP, lethal cues; no click-through purchase | PASS (offline) | code + sim; REWARD, UI_STATE_CONTRACT 4 | Device check owed |
| 22 | Solo choices safe through the verified mechanism | PASS (offline) | sim; CHOICE_STATE (freeze bug fixed) | |
| 23 | Real two-client test: duo chooser protected, other player and world continue | BLOCKED | sim only (choice-regression) | Needs Studio with 2 clients (TS-08) |
| 24 | Protection cannot be forged, extended, re-entered or used to farm | PASS (offline) | sim; CHOICE_STATE (budget 14.5 s / 20 s), SAFETY 1 | Latency untested |
| 25 | Trio consistent rule; run menu never implies pause or immunity | PASS (offline) | code (trio) + sim (duo menu); CHOICE_STATE, DUO_MENU | Trio by code review only |

## Seven approved screens and related usability

| # | Line | Result | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 26 | Title matches the simpler direction; Play primary; every destination reachable | PASS (offline) | sim + render; TITLE (menu_clarity_regression) | |
| 27 | Hero preview/equipped, sticky ownership, mastery gates, arena unlocks, party capacity, mode rules clear | PASS (offline) | render; TITLE | |
| 28 | Daily ranked-attempt, loss/leave consequences, reset, route/modifiers disclosed | PASS (offline) | sim; TITLE, DUO_MENU (leave cost) | |
| 29 | Desktop HUD: centre clear, grouped vitals, objective/timer, utilities, minimap, build | PASS (offline) | render; HUD | |
| 30 | Full 6+6 build with stacked items and modifiers readable and inspectable | PASS (offline) | render; HUD (hud-build) | |
| 31 | Actual phone/tablet input, thumb zones, safe areas, native controls, gestures, holds | BLOCKED | render only | Real devices |
| 32 | Upgrade cards: approved treatment, current-to-next, qualifiers, focus, shortcuts | PASS (offline) | render; UPGRADE_UI, COPY 4 | Existing icon art, not painted card art |
| 33 | Final upgrade vs Maxed, total vs added, units, duration, HP/damage qualifiers | PASS (offline) | UPGRADE_UI, COPY, POLISH | Final/Maxed, units, qualifiers done; passive change box labelled TOTAL, added amount on the line under the name (CP-09, levelup render iphone / phone / portrait) |
| 34 | Results: stable tiles/actions, accurate gold accounting, separate progress | PASS (offline) | render + sim; RESULTS, BALANCE_AUDIT 3 | Landscape iPhone needs a scroll |
| 35 | Replay / Main Menu / Stay and return happen once, no stale countdown | PASS (offline) | sim; FLOW (runserver-sim, results-flow) | Real teleports untested |
| 36 | Duo menu side drawer, live-run label, restores input, confirms leave | PASS (offline) | render + sim; DUO_MENU | |
| 37 | Fresh onboarding, main vs optional objectives, Portal/Exit, guidance, input-aware copy tested | PASS (offline); fresh account BLOCKED | COPY, HUD, POLISH | Caravan labelled Optional in broadcast and bar (CP-05); RunIntro close prompt from InputPrompts (CP-03); solo copy branches (CP-02); real fresh account BLOCKED |
| 38 | Controller focus/back/selection and keyboard shortcuts | BLOCKED | none for gamepad | No gamepad in the mock (UI-61); keyboard 1/2/3 kept in code |
| 39 | Narrow/wide windows, ratios, long/localised text, large numbers, disabled states, glyph fallback | NOT RUN | render; HUD, TITLE (check_layout on 6 device sizes) | Localised text, ultrawide and UI scale not run |

## Economy and progression

| # | Line | Result | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 40 | Gold sources, chest availability/scaling, rarity, stacking, retained payout, rounding inspected | PASS (offline) | code; BALANCE_AUDIT 1-3 | |
| 41 | Ledger reconciles earned, spend, adjustments, wallet, retained, loss | PASS (offline) | code + bot; BALANCE_AUDIT 3, RESULTS | |
| 42 | Normal vs boundary cohorts; fresh/progressed, failed/successful, hero, solo/party | PASS (offline) | bot; BALANCE_AUDIT 4 | One bot skill level |
| 43 | Sample sizes, seeds, limits reported; no invented telemetry or targets | PASS (offline) | BALANCE_AUDIT 4, 7; BALANCE_TUNE 0 | Goals labelled PROPOSAL |
| 44 | World 2 onward evaluated by stage, boss spikes, beyond Stage 3 | PASS (offline) | bot; BALANCE_AUDIT 5.2 | |
| 45 | XP, free ranks, paid items, Growth, cooldown, defence, healing, control vs threat together | PASS (offline) | code + bot; BALANCE_AUDIT 5-6 | |
| 46 | Bargain Shrine and stacking with real multiplier order and party rules | PASS (offline) | code + bot; BALANCE_AUDIT 5.4, 6 | |
| 47 | Every tuning change: before/after, evidence, rationale, rollback, normal-play comparison | PASS (offline) | bot; BALANCE_TUNE, MIGRATION_ROLLBACK 2-3 | "Normal play" = bot cohorts, not people |
| 48 | Account cosmetic, mastery, run level distinct and correctly saved/displayed | PASS (offline) | sim + render; RESULTS, COPY 5, SAFETY 3 | |
| 49 | Leaderboard row vs pinned best consistent or explained; no deletions | PASS (offline) | sim; FLOW 2 | Live boards untested |

## Art, combat readability and feel

| # | Line | Result | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 50 | Representative slice coherent at normal zoom, tested before broad rollout | PASS (offline) | render; ENEMY_ART (enemy-slice), VFX_ART (friendly-fx) | The slice and the rest of the art ran in the same phase rather than strictly one after the other |
| 51 | Knight/skin/weapon and boss model/portrait conflicts resolved, no lost unlocks | PASS (offline) | HERO_ART 1, ENEMY_ART | Owner: Sword; Gold Trim stays gold |
| 52 | Player, enemy, elite, hostile floor, friendly spell, loot, objective distinguishable together | PASS (offline) | render; ENEMY_ART, VFX_ART, PROPS_ART | |
| 53 | Forest/Snow/Swamp, dense mobs, pale effects, boss flashes, tree occlusion, critical HP readable | NOT RUN | render; ENEMY_ART, VFX_ART, WORLD_ART | Forest and Snow combat rendered; Swamp combat and critical-HP views not rendered |
| 54 | Portals, runes, shrines/altar/caravan, chests, heal/snare, boundaries: truthful states, matching identity | PASS (offline) | render + sim; PROPS_ART, VFX_ART, WORLD_ART | caravan-sim BLOCKED by machine load (logic unchanged) |
| 55 | Collision/slow zones match visuals; combat lanes kept | PASS (offline) | sim; WORLD_ART (arena-map identical, stage-sim) | |
| 56 | Reduced Effects, Reduce Flashes, colours, visual cues, shake, audio keep threat info | PASS (offline) | sim; SETTINGS_TEST (accessibility-sim) | |
| 57 | Camera, animation, input feedback, audio judged in motion with real playback | BLOCKED | none | Needs a person playing (TS-09, AUDIO_MIX) |
| 58 | Asset sources, rights, editable files, import assumptions, placeholders documented | PASS (offline) | ASSET_REGISTER | |

## Security, purchases, persistence and performance

| # | Line | Result | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 59 | Remotes validate state, ownership, range, rate, duplicates, currency, grants | PASS (offline) | code + sim; SAFETY 1 (36 remotes fuzzed) | |
| 60 | Paid revive / native purchase paths tested safely or marked unrun | PASS (offline) | sim; SAFETY 2 | Native prompt cancel/funds explicitly marked BLOCKED |
| 61 | Save/load/retry/reconnect and migration keep currency, purchases, unlocks, mastery, settings | PASS (offline) | sim; SAFETY 3, SETTINGS_TEST | Live DataStores untested |
| 62 | No live data wiped or mutated; no spending, asset purchase, publish or purge | PASS (offline) | all docs; git | Nothing published; mesh uploads are the owner's own assets via the existing tool |
| 63 | Owner/debug controls server-restricted and inert for ordinary users | PASS (offline) | sim; SAFETY 4 | |
| 64 | Repeated runs clean up listeners, timers, tweens, UI, VFX, objects, memory | BLOCKED | sim; PERFORMANCE_BASELINE 3 | Instance counts flat over 3 cycles; listener counts and memory need Studio |
| 65 | Target devices named; before/after frame time, memory, CPU/GPU, network evidence | NOT RUN | PERFORMANCE_BASELINE | Only a before baseline on a loaded machine; after run not done; devices BLOCKED |

## Final handoff

| # | Line | Result | Evidence | Notes |
| --- | --- | --- | --- | --- |
| 66 | Code/assets, change summary/map, setup, register, seven-screen before/after evidence included | NOT RUN | CHANGE_SUMMARY, FILE_MAP, ISSUE_REGISTER | The before/after images live in the session scratchpad only; package them with the handoff |
| 67 | Corner, balance, security, multiplayer/input and performance reports separate observed from remaining | PASS (offline) | CORNER_REPORT, BALANCE_AUDIT/TUNE, SAFETY, CHOICE_STATE, PERFORMANCE_BASELINE | |
| 68 | Blockers, unrun tests, migrations/rollback, risks explicit; nothing called release-ready | PASS (offline) | this file, TEST_REPORT, MIGRATION_ROLLBACK | Not release-ready until the owner's Studio steps pass |
