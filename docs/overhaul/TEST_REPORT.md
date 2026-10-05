# SWARM overhaul: test report

Build: `59f533b` (base `83be6c9`). Tools: Lune with the preview mock of the Roblox API
(`tools/preview/runtime`), `tools/check.sh`, `tools/run_regressions.py`, `tools/preview/render.sh`,
`tools/preview/check_layout.py`, Blender for meshes.

**What was exercised:** offline only. Simulations run the real server and client modules against
a mock; renders use a three.js approximation of Roblox lighting. **Not exercised:** Roblox Studio,
any phone or tablet, any gamepad, two or three real clients, real teleports, live DataStores,
OrderedDataStores or purchases. Every Studio/device line below is BLOCKED (owner steps:
MIGRATION_ROLLBACK.md 4).

The machine was shared by many helpers all session (load average 8-28). Timings are not
evidence; a few sims timed out or were killed for load (noted).

## Full regression run

> **Placeholder for the lead.** Command: `python3 tools/run_regressions.py` (83 checks) plus
> `bash tools/check.sh`. Fill in: date, commit, `N/83 passed`, wall time, evidence folder, and
> the Result line of each check below.
>
> - Date / commit:
> - Result: __ / 83
> - `tools/check.sh` (typecheck + build):
> - Failures and their cause:

"Area evidence" below is the latest result an area doc reports for that check, on the working
tree at the time; it is not a substitute for the full run.

## Regressions in `tools/run_regressions.py`

### Server and economy sims

| Check | Area evidence (doc) | Full run |
| --- | --- | --- |
| economy-sim | PASS (BALANCE_TUNE 5c) | |
| storage-sim | PASS (SAFETY) | |
| storage-sim outage=all | PASS (SAFETY) | |
| difficulty-sim | no area report | |
| difficulty-handoff | PASS (SAFETY) | |
| difficulty-handoff unlocked=off | PASS (SAFETY) | |
| ground-sim | PASS (WORLD_ART) | |
| audio-sim | 1 FAIL in section 7 reported by NOTIFY_SERVER; lead then set `Config.Audio.CriticalPriority = 5`; sections 7-8 need a re-run | |
| progression-regression | PASS (CHOICE_STATE) | |
| mastery-regression | PASS (CHOICE_STATE, SAFETY) | |
| combat-regression | PASS (CORNER_REPORT, ENEMY_ART) | |
| corner-regression | PASS, 0 FAIL (was 177 before the fix) (CORNER_REPORT, WORLD_ART); needs `--max-time 3000` | |
| whip-regression | PASS (HERO_ART, CHOICE_STATE) | |
| data-regression | PASS, 0 findings (COPY, HERO_ART) | |
| passives-regression | PASS 13/13 (COPY, HERO_ART) | |
| run-manager-regression | PASS (CHOICE_STATE, NOTIFY_SERVER) | |
| choice-regression | PASS (CHOICE_STATE, NOTIFY_SERVER, UPGRADE_UI, DUO_MENU) | |
| portal-hold-regression | PASS (NOTIFY_SERVER) | |
| fall-regression | PASS (CHOICE_STATE) | |
| safety-sim | PASS (SAFETY); must run without `--studio` (runner does this) | |
| settings-sim | PASS (SETTINGS_TEST); scene now opens run settings directly (DUO_MENU note, commit 7cb3c90) | |
| settlement-lifecycle | FAIL earlier (solo choice freeze stopped the run clock; SAFETY, FLOW), then PASS after the scene fix (NOTIFY_SERVER, BALANCE_TUNE 5c) | |
| reward-regression | PASS (REWARD, BALANCE_TUNE 5c) | |
| reward-once-regression | PASS 29/29 (REWARD); slow, close to the 360 s runner timeout under load | |
| encounters-sim | PASS (PROPS_ART) | |
| encounter-placement | PASS (WORLD_ART) | |
| expedition-sim | PASS (NOTIFY_SERVER) | |
| party-sim | no area report | |
| stage-sim | PASS, 0 FAIL (CORNER_REPORT, WORLD_ART) | |
| weapons-sim | PASS (VFX_ART, armoury) | |
| xp-sim | PASS (CHOICE_STATE) | |
| synergy-sim | no area report | |
| chest-gold-sim | PASS (REWARD, BALANCE_TUNE 5c, CHOICE_STATE) | |
| curses-sim | no area report | |
| runserver-sim role=lobby | PASS (FLOW, SAFETY) | |
| runserver-sim role=run | PASS (FLOW, SAFETY) | |
| coop-regression rejoin=success | PASS (CHOICE_STATE, NOTIFY_SERVER, DUO_MENU, SAFETY) | |
| coop-regression rejoin=expired | PASS (CHOICE_STATE, NOTIFY_SERVER, DUO_MENU) | |
| coop-regression rejoin=ended | PASS (CHOICE_STATE, NOTIFY_SERVER, DUO_MENU) | |
| coop-regression rejoin=forged | PASS (CHOICE_STATE, NOTIFY_SERVER, DUO_MENU) | |
| reconnect-lobby | 0 errors (FLOW, SAFETY) | |
| reconnect-lobby fail=teleport | 0 errors (FLOW, SAFETY) | |
| reconnect-lobby fail=expired | 0 errors (FLOW, SAFETY) | |

### Bosses

| Check | Area evidence (doc) | Full run |
| --- | --- | --- |
| boss-sim boss=ScorpionQueen | no area report (mesh recoloured, AI unchanged: ENEMY_ART) | |
| boss-sim boss=MothMatriarch | no area report (mesh recoloured, AI unchanged: ENEMY_ART) | |
| boss-sim boss=RhinoWarlord | no area report | |
| boss-sim boss=HiveMother | no area report | |
| boss-sim boss=BriarSentinel | no area report | |
| boss-sim boss=FrostboundColossus | no area report | |

### Client scripts

| Check | Area evidence (doc) | Full run |
| --- | --- | --- |
| ui phone | PASS (UISTATE 30/30, HUD, REWARD, DUO_MENU, RESULTS) | |
| ui phone-portrait | PASS (same) | |
| menu phone | PASS (TITLE, menu_clarity_regression) | |
| menu phone-portrait | PASS (TITLE) | |
| discovery phone | no area report | |
| discovery phone-portrait | no area report | |
| pings phone | no area report | |
| pings phone-portrait | no area report | |
| accessibility-sim | PASS (SAFETY, SETTINGS_TEST); lead note: a second error remained after the XP-colour fix, re-run alone | |
| uistate | PASS 34/34 (UISTATE; also REWARD, UPGRADE_UI, DUO_MENU, NOTIFY_SERVER) | |
| results-flow case=auto | PASS (FLOW, RESULTS; runs with the client, not headless) | |
| results-flow case=stay | PASS (FLOW, RESULTS) | |
| results-flow case=replay | PASS (FLOW, RESULTS) | |
| results-flow case=portal | PASS (FLOW, RESULTS) | |
| results-flow case=plain | PASS (FLOW, RESULTS) | |
| leaderboards mismatch=board | PASS (FLOW) | |

### Phone layouts (`check_layout.py`)

| Check | Area evidence (doc) | Full run |
| --- | --- | --- |
| layout menu iphone | 0 problems (TITLE renders) | |
| layout menu phone-portrait | 0 problems (TITLE) | |
| layout levelup iphone | 0 problems (UPGRADE_UI) | |
| layout levelup phone-portrait | 0 problems (UPGRADE_UI) | |
| layout results iphone | 0 problems (RESULTS, results-ledger renders) | |
| layout results phone-portrait | 0 problems (RESULTS) | |
| layout pause iphone | 0 problems (DUO_MENU co-op render) | |
| layout pause phone-portrait | 0 problems (DUO_MENU) | |
| layout revive iphone | no area report | |
| layout revive phone-portrait | no area report | |
| layout stage-choice iphone | no area report | |
| layout stage-choice phone-portrait | no area report | |
| layout characters iphone | 0 problems (TITLE) | |
| layout characters phone-portrait | no area report | |
| layout countdown iphone | no area report | |
| layout countdown phone-portrait | no area report | |
| layout characters iphone mastery=open | 0 problems (TITLE, `--set mastery=open`) | |
| layout characters phone-portrait mastery=open | no area report | |

## Other offline checks (not in the runner)

| Check | Result (doc) |
| --- | --- |
| `bash tools/check.sh --quick` | PASS in every area doc at the time; final full `check.sh` belongs in the placeholder above |
| `lune run tools/audio_regression.luau` | PASS (AUDIO_MIX) |
| menu-sim cycles=1 / 3 | 0 errors (UISTATE, TITLE, PERFORMANCE_BASELINE); "new run after death" showed Alive=false in the baseline, not investigated |
| firstjoin-sim | PASS (TITLE) |
| endless-sim | PASS (BALANCE_TUNE) |
| tutorial scene, tips Move / Portal / Boss | 0 errors, check_layout clean (COPY) |
| caravan-sim | BLOCKED: killed after 40 min under load (PROPS_ART); re-run |
| perf-sim 200/300/400, boss scenario | baseline only, on `83be6c9`, loaded machine (PERFORMANCE_BASELINE); after run NOT RUN |
| econ-sim cohorts (scratch scene, not in the tree) | BALANCE_AUDIT 4-5, BALANCE_TUNE |
| arena-map | layout metrics identical before/after in six arenas (WORLD_ART) |
| Renders with check_layout: ui-stack, hud-build, reward-card, results-ledger, pause, levelup, menu, characters, enemy-slice, friendly-fx, props | 0 layout problems except the loot-scene banner collisions HUD reported, then fixed by UIState holds (UISTATE) |

## Acceptance checklist summary

Full table with evidence: ACCEPTANCE.md. Totals: PASS (offline) 54, FAIL 4, BLOCKED 5, NOT RUN 5.

- FAIL: #6 every issue dispositioned (8 open); #7 exact recorded build not reproduced; #33 total
  vs added effect not separated on cards; #37 optional caravan label and RunIntro prompt.
- BLOCKED: #23 real two-client duo; #31 real phones/tablets; #38 gamepad; #57 feel and audio in
  motion; #64 listener/memory cleanup in Studio.
- NOT RUN: #11 party modes at corners; #39 localised text, ultrawide, UI scale; #53 Swamp combat
  and critical-HP views; #65 after-overhaul performance run; #66 before/after images packaged.
- Everything else PASS on offline evidence only.

## Known failures and unrun checks to close before release

1. Full regression run (placeholder above), including audio-sim sections 7-8 and
   accessibility-sim alone.
2. caravan-sim; perf-sim after-run on a quiet machine plus a boss + 200 enemies scene.
3. Open register items: UI-11, UI-30, CP-02, CP-05, CP-11, CP-16, ART-22, ART-24.
4. All Studio, device, gamepad and two-client checks (MIGRATION_ROLLBACK.md 4).


## Full regression run (lead, 2026-10-05)

`python3 tools/run_regressions.py` on commit after the final polish: 82/83 on the first run.
The one FAIL (leaderboards mismatch=board) was the scene itself: it ran headless (no client)
and looked for a RANKS button that now sits under MORE. Fixed the scene and the runner
(leaderboards runs with the client, like results-flow); rerun alone: ALL PASS. Result: 83/83.
`tools/check.sh` (type check + Rojo build): clean. All offline (Lune preview); nothing in
Studio, on a device, with a gamepad or in a live multi-client server.
