# PERF audit, 2026-10-05

Area: performance and leaks (audit-prompt section 13). Read-only on game code except one
evidence-backed fix (PERF-01, `src/client/Hud.lua`). Statuses and test words follow
`audit-brief.md`.

## Environment and method

- Machine: Linux, 4 cores, 15 GB RAM. PERF was the only job: load average 0.8-1.9 for every
  run (logged per run). One Lune process at a time, never in parallel.
- Runtime: offline Lune preview with the mock Roblox API (`tools/preview`). NOT a phone, NOT
  Studio, NOT multiplayer, no physics step, no rendering cost. Milliseconds are Lua time in
  the mock and only compare runs of the same scene with each other. Counts (instances,
  remotes, writes, connections) are the portable evidence.
- Before = tag `audit-baseline-2026-10-05` (b07d83b), checked out as a git worktree in the
  scratchpad (removed afterwards). After = HEAD `02644c6` plus the PERF-01 fix in the working
  tree. Both used the SAME harness: the current `tools/preview` was copied into the baseline
  worktree and run through `render.sh --repo <worktree>`, so only `src/` differs.
- The scenes are deterministic (fixed seed): identical kills and traffic in both swarm runs
  confirm the same workload.
- Sample size: one run per row (deterministic sim, so repeat runs give the same counts; ms
  vary a few percent). Swarm phases: 6 simulated s each (396 frames) after 2 s settling.

Commands (from the repo root; `SWARM_TOOLS=/tmp/sh-tools`):

```
bash tools/preview/render.sh perf-sim --studio --max-time 3000 --set enemies=200,300,400 --set seconds=6
bash tools/preview/render.sh perf-sim --studio --max-time 6000 --set enemies=200 --set scenario=boss --set bossenemies=200 --set seconds=6
bash tools/preview/render.sh menu-sim --studio --devices pc --set cycles=5 --max-time 7000
bash tools/preview/render.sh perf-sim --studio --max-time 9000 --set enemies=200 --set seconds=2 --set soak=600
# before: the same commands with --repo <baseline worktree>
```

Harness additions (test tooling only, no game code):
- `perf-sim --set bossenemies=N`: the dense boss case (each boss held in phase 2 with N swarm
  enemies kept alive around the hero). None existed before.
- mock `preview.liveCounts()`: live connections (by signal name), threads waiting on
  task.wait/delay, deferred threads, active tweens, Sounds (alive / playing). Printed by
  menu-sim at every step (plus connection growth by signal) and by the perf-sim soak.
- mock `preview.forcedLayouts(reset)`: forced GUI layout passes (AbsoluteSize / TextBounds
  read on a dirty GUI) per game line. perf-sim prints the top lines.

## Findings

| ID | subsystem | expected (source) | files/functions | repro/start state | actual | evidence type | severity | root cause | fix/proposal | status | next check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| PERF-01 | HUD stage caption | no per-frame layout work while idle (PERFORMANCE_BASELINE budget: writes only on change) | `Hud.lua` updateStage | any run, caption fits the panel (PC, most phones) | `ui.StageNumber.AbsoluteSize` read every frame: 1 632 forced GUI layouts in 1 750 frames (baseline), 300 in 300 frames (regression, old code) | mock forced-layout counter, perf-regression FAIL on old code | P2 | width check for the "drop the arena name" rule ran every frame until the caption was too wide, which never happens when it fits | measure only on the 4 frames after the caption, UI scale or panel room changes | VERIFIED FIXED (offline): 56 forced layouts in the same scene, perf-regression PASS | MicroProfiler on a phone: no `Layout` spike under the HUD each frame |
| PERF-02 | enemy affix tags / HP bars | bounded per-pool UI | `EnemyRenderer.lua` ensureAura / HP bar | 10-min soak, 200 enemies | `AffixTag` BillboardGuis in PlayerGui +80 instances over 600 s, never destroyed | soak bucket growth | none (P2 note) | one tag per enemy pool slot, created on its first elite; slots are the server's fixed pool (`Config.Enemies.PoolSize` 300) | none needed: hard cap 300 tags (600 instances), disabled when unused | VERIFIED WORKING (bounded by design) | none |
| PERF-03 | icon fallback listeners | no connection growth per run | `Icons.lua` picture() | menu-sim, offline pictures never load | +92-94 `IsLoaded` connections once (between cycle 2 and 3), then flat; waiting threads drop 120 -> 30 | liveCounts by signal | none | after 20 s of polling, a not-loaded picture switches to an `IsLoaded` listener; it is freed with the picture | none (offline artefact: mock pictures never load) | VERIFIED WORKING | none |
| PERF-04 | soak connection drift | flat connections in a long run | not attributed | 10-min soak | connections 5 061 -> 5 093 (+32), plateau from 460 s (5 092-5 093) | liveCounts | P2 (watch) | probably per-pool-slot listeners like PERF-02 (bounded); the soak does not print the signal names | add a by-signal print to the soak if it grows in a longer run | UNVERIFIABLE (bounded so far) | 20-min soak with by-signal growth |

No regression from the audit's changes: baseline and HEAD-before-fix give the same counts,
traffic and (within noise) ms in every scenario (pre-fix HEAD run: server 8.4 / 13.0 / 16.9,
client 30.5 / 39.5 / 44.4 ms at 200 / 300 / 400).

## 1. Dense swarm (hero walking a circle, six evolved weapons, client on; ms/frame exclusive)

| enemies | server before | server after | client before | client after | kills/s (both) | instances in tree before / after | Lua heap before / after |
|---|---|---|---|---|---|---|---|
| 200 | 8.4 | 6.9 | 30.2 | 21.4 | 101 | 23 852 / 23 884 | 156 / 139 MB |
| 300 | 12.5 | 11.6 | 38.3 | 29.3 | 157 | 24 650 / 24 674 | 143 / 87 MB |
| 400 | 16.9 | 13.6 | 47.4 | 29.9 | 135 | 25 562 / 25 587 | 133 / 122 MB |

Biggest client callbacks at 200 (before -> after): EnemyRenderer 9.2 -> 7.7, VFX 8.2 -> 7.0,
DamageText 3.4 -> 0.25, Telegraphs 1.9 -> 1.5, HUD frame (UIBuilder) about 2.8 -> 1.7. The
DamageText and HUD drops are mostly the mock no longer re-laying out the GUI between their
property writes (a mock cost charged to the next writer), so read them as "the HUD no longer
forces layout", not as a phone-side 3 ms saving. Wall time per phase: 314 s -> 33 s.

Same in both: remotes FxBatch 30.5/s (11.4 KB/s at 200, 16.8 KB/s at 300, 15.3 KB/s at 400),
DamageNumbers 8.2/s (~2 KB/s), ProjectileBatch 33/s (0.5 KB/s), total about 14-19 KB/s;
attribute changes 610 / 1 000 / 981 per s; property writes Transparency 38-51 k/s, Size
28-31 k/s (VFX and Telegraphs pooled parts); BulkMoveTo 133-188 k parts/s. +32 instances in
the tree after (audit UI), static.

## 2. Boss plus swarm (each boss held in phase 2 at 40% HP, 200 enemies kept alive)

| case | server before / after | client before / after | kills before / after | live peaks (after) | FxBatch | instances in tree before / after |
|---|---|---|---|---|---|---|
| Briar Sentinel + 200 | 8.4 / 7.2 | 30.0 / 22.6 | 591 / 591 | hazards 10, telegraphs 21, boss lines 6, CombatFx 95 | 30.3/s, 11.3 KB/s (both) | 23 746 / 23 783 |
| Frostbound Colossus + 200 | 9.7 / 7.6 | 48.9 / 23.2 | 631 / 544 | hazards 6, telegraphs 7, boss lines 4, CombatFx 78 | 28.0 / 27.7 per s, 11.8 / 10.3 KB/s | 23 900 / 23 980 |

The Colossus row is not the same workload: kills differ (631 vs 544, the audit's WORLD and
MATH fixes change the snow stage), so compare it loosely. Both bosses ran every state
(Briar: RootWindup Rooted Recover Chase Volley; Colossus: Slam LaneWindup BreathWindup
Breathing). 0 errors.

## 3. Menu cycles (menu-sim, 5 lobby -> run -> MAIN MENU cycles, then death, results, new run)

Lobby rows (after MAIN MENU / results), after the fix; the baseline row is in brackets.

| step | workspace | PlayerGui | connections | waiting threads | tweens | Sounds alive (playing) | tree / all instances |
|---|---|---|---|---|---|---|---|
| boot | 2 536 [2 536] | 10 158 [10 115] | 4 965 [4 962] | 120 | 18 | 120 (1) | 15 784 / 15 824 |
| cycle 1 lobby | 3 121 [3 121] | 10 538 [10 495] | 4 970 [4 967] | 121 | 22 | 130 (12) | 16 749 / 16 810 |
| cycle 2 lobby | 3 215 [3 215] | 10 538 [10 495] | 4 970 [4 967] | 126 | 21 | 130 (15) | 16 843 / 16 904 |
| cycle 3 lobby | 3 221 [3 221] | 10 543 [10 500] | 5 064 [5 059] | 30 | 19 | 130 (16) | 16 854 / 16 917 |
| cycle 4 lobby | 3 223 [3 223] | 10 544 [10 501] | 5 064 [5 059] | 32 | 19 | 130 (16) | 16 857 / 16 922 |
| cycle 5 lobby | 3 223 [3 223] | 10 544 [10 501] | 5 064 [5 059] | 27 | 20 | 130 (16) | 16 857 / 16 918 |
| results closed | 3 197 [3 197] | 10 582 [10 539] | 5 064 | 28 | 20 | 130 (17) | 16 869 / 16 938 |
| final lobby | 3 197 [3 197] | 10 583 [10 540] | 5 065 [5 060] | 28 | 21 | 130 (17) | 16 870 / 16 943 |

Reading: no per-cycle growth in workspace, PlayerGui, connections, threads, tweens or Sounds
after cycle 3 (cycles 3-5: +0 to +2). The one-time +94 connections are PERF-03. PlayerGui is
+43 over the baseline (the audit's new UI), flat. Sounds: a fixed pool of 130; "playing" is
how many are sounding at that moment. Lua heap swings 67-139 MB with the collector and shows
no trend. Both PASS lines (new run after death; enemies spawn) PASS before and after.

## 4. Soak (after only; 200 enemies, 600 simulated s, ~46 800 kills)

| t | tree | all | heap | connections | waiting threads | tweens | Sounds (playing) |
|---|---|---|---|---|---|---|---|
| 20 s | 23 936 | 24 063 | 147 MB | 5 061 | 9 | 24 | 130 (18) |
| 120 s | 24 633 | 24 976 | 141 MB | 5 062 | 7 | 23 | 130 (20) |
| 300 s | 24 385 | 25 099 | 166 MB | 5 062 | 14 | 21 | 130 (21) |
| 460 s | 24 909 | 25 962 | 165 MB | 5 092 | 7 | 23 | 130 (25) |
| 600 s | 24 947 | 26 260 | 188 MB | 5 093 | 12 | 25 | 130 (22) |

Growth by container after 600 s: enemy model pool +1 046 (pooled models per enemy type, kept
by design, capped per type), telegraph pool +660 (flat from 40 s), client FX +145, pickups
+80 (moves with gems on the floor), AffixTag +80 (PERF-02), CombatFx +29. Threads, tweens and
Sounds are flat. Heap swings 97-196 MB with the collector, no steady climb. "all" (not
destroyed, incl. unparented) grows 2 200: pooled parts parked out of the tree plus garbage the
mock cannot force-collect; not a confirmed leak. Baseline soak: NOT RUN (before the fix the
mock needs ~0.8 s per frame, so 600 s would take about 8 hours).

## Tests (after)

| check | command | result |
|---|---|---|
| type check + build | `bash tools/check.sh` | PASS (TYPECHECK ok, BUILD ok) |
| perf-regression (new) | `lune run tools/preview/runtime/main.luau -- --scene perf-regression --studio --device pc` | PASS after; FAIL on the old Hud.lua (300 forced layouts in 300 frames) |
| hud-key-regression | same runner | PASS |
| run-intro stage=2 panel=on | same runner | PASS |
| layout countdown, iphone + phone-portrait | runner + `check_layout.py` | PASS (0 problems) |
| ui_regression phone | `lune run tools/ui_regression.luau phone` | PASS (0 FAIL) |
| perf-sim swarm / boss / soak, menu-sim | above | PASS (0 errors; menu-sim PASS lines PASS) |
| real phone, Studio, multiplayer (4 players) | - | NOT RUN |

`perf-regression` needs the client: register it like `hud-key-regression` (in the main list
and in the tuple of scenes that drop `headless=on`).

## Owner checklist: real-phone test (NOT RUN here)

Use your phone and, if you can, one older/cheaper phone. Turn on Settings > Damage numbers for
the heavy tests.
1. Start a Solo run; open the Developer Console (F9 on PC, or the chat command `/console`) >
   Memory. Note "Total" and "PlaceMemory" at the first wave.
2. Play 10 minutes (or to stage 3). Watch the frame rate (Ctrl+Shift+F5 on PC; on a phone:
   does movement stay smooth when 150+ enemies are on screen?). Note any hitch longer than a
   blink, and when (level-up card, chest reel, boss entrance, portal, stage change).
3. Fight a boss with a big swarm alive (Briar Sentinel or Frostbound Colossus). Note
   stutters during slams, lanes or root lines.
4. Open the pause menu > MAIN MENU, start again; repeat 5 times. Memory in the lobby after
   run 5 should be within about 50 MB of the lobby after run 1.
5. Die once, close the results, start a new run: no stuck enemies, no doubled HUD.
6. Duo/Squad with friends: same as 2 with 2-4 players; note ping (Developer Console > Network)
   and whether enemies jump.
7. Phone heat and battery after 20 minutes: warm is fine, too hot to hold is not.
8. Tell Claude the phone model and what you saw (numbers from steps 1 and 4, any hitches).
