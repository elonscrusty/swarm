# Performance baseline before the overhaul (PERF, 2026-10-04)

Measured on commit `83be6c9` (rendered from a snapshot with `--ref`, so other helpers' edits to the
working tree did not leak in). Offline Lune preview with a mock Roblox API: NOT device hardware,
NOT Studio, NOT multiplayer. See `docs/PERFORMANCE.md` for the method and the older numbers.

## Honest caveat: machine load

The 4-core machine was shared with many other helpers for the whole session. Load average
(1/5/15 min) when runs started: swarm 200/300/400: 0.14 at boot, climbing to 22 within 15 min
and staying 20-28 for the run; menu-sim: 19.6 / 21.2 / 22.6 at start, 8-10 at the end; boss
scenario: 8.5 / 8.5 / 10.6. Wall-clock (the "real" numbers: 201 s, 278 s, 620 s for 198 frames)
is useless. The per-callback ms are exclusive Lua time and are less affected, but still inflated
by CPU contention, and the 400 row clearly is: it ran last, under the heaviest load (server
69.7 ms against 32.0 ms for the same 400 count in the unloaded 2026-10-02 run in
`docs/PERFORMANCE.md`). Treat ms as relative and noisy; counts (instances, remotes/s, property
writes/s, attribute changes/s) are the portable evidence. Re-run quiet before using any ms as a
regression gate.

## Commands

```
# swarm ring, 200/300/400 enemies, 3 simulated s per phase (about 1 h under load, about 6 min quiet)
bash tools/preview/render.sh perf-sim --ref 83be6c9 --studio --max-time 900 --set enemies=200,300,400 --set seconds=3
# bosses (Briar Sentinel, Frostbound Colossus held in phase 2), 4 s each
bash tools/preview/render.sh perf-sim --ref 83be6c9 --studio --max-time 3000 --set scenario=boss --set seconds=4
# repeated lobby -> run -> lobby cycles, then a death, results close, new run, final lobby
bash tools/preview/render.sh menu-sim --ref 83be6c9 --studio --devices pc --set cycles=3 --max-time 3000
```
Run them one at a time and in the background (output only appears when the scene ends). Do not
use `pkill -f` with a scene name from the same shell: it kills the launching shell.
Not run: 5 cycles of menu-sim (a first 5-cycle attempt hit the 30 min background limit with no
output; 3 cycles took 3 759 s real under load) and a long `--set soak=` run (too slow under load).

## 1. Dense swarm (hero walking a circle, 6 evolved weapons, client on, ms per frame, exclusive)

| enemies | server | client | EnemyRenderer | VFX | DamageText | UIBuilder (HUD) | Telegraphs | kills/s | instances in tree | Lua heap |
|---|---|---|---|---|---|---|---|---|---|---|
| 200 | 11.1 | 40.8 | 11.6 | 10.9 | 5.1 | 4.8 | 2.2 | 97 | 22 662 | 81 MB |
| 300 | 24.1 | 84.2 | 19.0 | 19.0 | 20.4 | 5.8 | 5.0 | 140 | 23 747 | 130 MB |
| 400 | 69.7 (load-inflated) | 176.3 | 54.8 | 46.6 | 22.9 | 14.0 | 11.5 | 185 | 24 628 | 132 MB |

CPU split, server (200 / 300 / 400): `EnemyAI.Enemies` 5.4 / 13.4 / 37.0 (about half of the server,
includes `Think` 1.7 / 3.4 / 11.6), `EnemyAI.Grids` 0.6 / 1.4 / 3.9, XPSystem 0.8 / 1.4 / 5.7,
WeaponSystem 0.7 / 1.0 / 2.6, spawn+kill 0.5 / 1.3 / 3.4. Default `MaxLive` is 200, so 300/400
are stress only.

Client at 200: EnemyRenderer, VFX, DamageText, UIBuilder are the four big callbacks (33 of 41 ms).
DamageText at 300+ (20 ms) is new relative to the 2026-10-02 notes and is worth a look.
Enemy look at 200: 183 on screen, 87 low-detail, 96 full, 0 blobs; at 400: 349 on screen, 208
low-detail, 140 full, 0 blobs.

Physics / engine-side proxies (mock has no physics step): BulkMoveTo parts per second 125 k / 155 k
/ 191 k (EnemyRenderer 53 k / 68 k / 91 k), CFrame writes 5.5 k / 7.1 k / 7.9 k per s. Hazards
live 2 / 10 / 10, client telegraphs 4 / 12 / 17. Real physics cost on a device is BLOCKED: enemy
parts are anchored and moved by BulkMoveTo, so it should be small, but this was not measured.

Property writes per second (200 / 300 / 400): Transparency 35 k / 48 k / 54 k, Size 28 k / 32 k /
33 k (mostly VFX and Telegraphs pooled parts), Color 5.2 k / 7.0 k / 8.0 k. Attribute changes per
second: 547 / 844 / 1 155 (Active, Fly, BaseColor, Type, Base, XP lead).

Instances created per second 283 / 196 / 212, destroyed 45 / 7 / 43 (new enemy MeshParts from
ModelLibrary about 120/s at 200 and 400 until pools fill; Telegraphs parts 44-135/s).

UI churn at 200 enemies: HUD frame callback 4.8 ms, 17 Parts and 13 Tweens created per second
by UIBuilder's frame, 120 BackgroundTransparency / 1.4 k TextSize / TextTransparency writes per s.

Remote traffic (calls/s, KB/s) at 200 / 300 / 400: FxBatch 30.7 (11.2) / 31.0 (14.6) / 30.3
(19.4); DamageNumbers 8.3 (1.8) / 8.0 (2.1) / 8.3 (2.1); ProjectileBatch 33 (0.5) in all; others
under 1 KB/s. Total about 14 / 17 / 22 KB/s. Grows with kills, as before.

## 2. Bosses (scenario=boss, boss held at 40% HP so phase 2 runs; not a dense swarm)

| boss | enemies alive | server ms | client ms | live peaks | FxBatch | instances in tree |
|---|---|---|---|---|---|---|
| Briar Sentinel | 12 | 1.7 (BossAI 0.014) | 14.7 | boss lines 6, telegraphs 1 | 4.2/s, 0.5 KB/s | 19 923 |
| Frostbound Colossus | 14 | 2.0 (BossAI 0.014) | 13.6 | hazards 2, telegraphs 4, boss lines 4 | 7.5/s, 0.9 KB/s | 20 309 |

Telegraphs write about 7.6 k Transparency and 5.9 k Size per s during the Colossus lanes. A truly
dense boss scene (boss plus 200-300 enemies) is not a built scenario; proposal: add one to
perf-sim (`scenario=boss` with `enemies=200`) before the overhaul changes the boss HUD.

## 3. Menu cycles and repeated runs (menu-sim, 3 cycles; counts from `count(workspace)`, `count(PlayerGui)`)

| step | workspace instances | PlayerGui instances |
|---|---|---|
| boot (lobby) | 2 555 | 9 657 |
| cycle 1 in run / after MAIN MENU | 4 907 / 3 122 | 10 029 / 10 042 |
| cycle 2 in run / after MAIN MENU | 5 002 / 3 216 | 10 102 / 10 042 |
| cycle 3 in run / after MAIN MENU | 5 105 / 3 222 | 10 107 / 10 047 |
| after death / results closed | 5 068 / 5 068 | 10 150 / 10 116 |
| final lobby (after another start + abandon) | 3 198 | 10 092 |

Reading: back in the lobby the workspace settles at 3 122, 3 216, 3 222, 3 198: about +95 on the
second return, then flat (+6, -24), so no per-run leak is visible in 3 cycles. The lobby is
about 570 above first boot (pools and enemy models kept by design). PlayerGui grows 9 657 to
about 10 042 on the first run (screens built lazily) and then stays flat within +50, i.e. no
duplicate UI. Listener counts are not exposed by the mock: BLOCKED (use the Studio Developer
Console steps in `docs/PERFORMANCE.md`). Memory over 3-5 runs: Lua heap not printed by menu-sim;
perf-sim heap swings 81-132 MB with GC. 3 cycles are too few to rule out slow growth: a
5-run Studio check is still owed.

Possible oddity, not investigated (read-only task): in this scene, after the death path the
"new run after death" step still shows Alive=false, phase Running, 0 enemies (workspace stayed
5 068). It may be the mock timing of ReturnToLobby then StartRun; worth a look by the owner of
RunManager / FLOW.

## 4. Suggested budgets (PROPOSALS, not approved, not measured on devices)

Basis: the offline numbers above are relative only. Budgets are for counts, which port; the ms
columns are for on-device MicroProfiler checks by the owner.

| target class | enemies alive (normal / stress) | instances alive in tree | FxBatch + all remotes | property writes/s (client) | UI frame callback (HUD) | notes |
|---|---|---|---|---|---|---|
| Phone, low end (the owner's class) | 120-150 / 200 | under 22 000 (now 22 700 at 200) | under 25 KB/s | under 40 k | under 3 ms on device | keep `MaxDetailedEnemies` 80 or lower; no new per-frame HUD tween loops |
| Phone, mid / tablet | 200 / 300 | under 25 000 | under 30 KB/s | under 55 k | under 3 ms | adaptive detail stays on |
| PC / console | 200 (design cap) / 400 | under 28 000 | under 40 KB/s | under 80 k | under 2 ms | |

Overhaul-specific proposals: the new UI coordinator, banner queue and compact reward card must
add no per-frame property writes while idle (writes only on change) and under 2 tweens/s at
rest; PlayerGui instance count stays flat across 5 lobby/run cycles (tolerance +100); lobby
workspace count after return within +100 of the second return; no new remote above 5 calls/s
sustained; boss telegraph writes stay under the Colossus numbers above. Re-measure with the
three commands above on a quiet machine, compare same-load, and treat a rise of more than 15% in
counts (not ms) as a regression to explain.

## 5. Verified vs assumed

- PASS (exercised): perf-sim 200/300/400 and boss scenario complete with 0 errors; menu-sim 3
  cycles plus death path complete with 0 errors.
- BLOCKED: real CPU / GPU / physics frame time, memory in Studio, listener counts, party
  (Duo/Trio) load, long soak, 5-cycle repeat, a quiet-machine timing run.
