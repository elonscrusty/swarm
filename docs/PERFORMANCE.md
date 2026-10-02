# Performance

How SWARM's frame budget is measured offline, the latest numbers, what is still a limit, and
how the owner checks it on a real device. The design rules (one Heartbeat loop, pooled
anchored enemy parts, spatial grid, batched remotes) are in `README.md` section 7.

## The benchmark

`tools/preview/scenes/perf-sim.luau` boots the real server and client modules on the
preview's mock Roblox API (Lune), starts a solo run with six evolved weapons and prints
per-system server ms/frame, client callback ms/frame, remotes/s and KB/s, attribute changes,
property writes, instances created / alive and the Lua heap. See `docs/PREVIEW.md` for every
option. Lune on Linux is not a phone: Vector3 / CFrame maths costs much more here, and this
machine is shared, so compare runs of the scene with each other (same settings, ideally run
side by side), never with a device. Counts (instances, remotes, writes) are the portable
evidence; milliseconds are relative.

```
bash tools/preview/render.sh perf-sim --studio --max-time 600 --set seconds=6            # 200/400/600 ring
bash tools/preview/render.sh perf-sim --studio --set scenario=boss --set seconds=8       # each new boss
bash tools/preview/render.sh perf-sim --studio --set scenario=caravan,endless --set seconds=5
bash tools/preview/render.sh perf-sim --studio --set enemies=200 --set seconds=2 --set soak=100
bash tools/preview/render.sh perf-sim --ref <commit> ...                                 # an older version
```

Scenarios (`--set scenario=`, comma list, `all` = every one):

| scenario | what runs |
|---|---|
| `swarm` (default) | exactly N enemies kept alive in a ring around the hero walking a circle (stage 1) |
| `caravan` | the Lost Caravan defence: the hero stands in the ring, waves come every 5 s |
| `boss` | Briar Sentinel and Frostbound Colossus (`--set bosses=Id,Id`), HP held at 40% so phase 2 runs, hazards live; prints the boss states seen and the peak boss lines / rings |
| `endless` | an Endless run moved to stage 12 (`--set stage=N`) with the real spawner and its multipliers |

Each phase also prints live peaks: server `Hazards.Count()`, client `Telegraphs.Count()` and
`CombatFx.Stats()` (alive / peak / pool / skipped). With `--set soak=N` the soak prints the
instance growth per container (workspace folders and ScreenGuis) every 20 s.

## Re-test after the content batch (2026-10-02)

Before = commit `38f713a` (the earlier perf pass), after = `main` with the new HUD, CombatFx,
brighter lighting, synergy, Lost Caravan, Endless scaling, Briar Sentinel / Frostbound
Colossus and party. Same seed, client on, ms per frame (exclusive), offline mock.

Dense swarm, all three phases in one run each (6 simulated s per phase, both runs at once):

| enemies | server before | server after | client before | client after | kills/s before / after | instances alive before / after |
|---|---|---|---|---|---|---|
| 200 | 15.9 | 13.8 | 46.8 | 43.7 | 103 / 94 | 18 972 / 20 221 |
| 400 | 32.0 | 32.0 | 61.2 | 61.9 | 193 / 185 | 19 420 / 20 873 |
| 600 | 43.3 | 48.2 | 59.2 | 74.4 | 231 / 330 | 20 141 / 23 080 |

The 600 row of that run killed 43% more enemies per second (more spawns, deaths and death
effects), so it was re-run alone, side by side (5 s):

| 600 enemies alone | server | client | EnemyRenderer | VFX | Telegraphs | CombatFx | HUD (UIBuilder frame) | kills/s | instances created/s |
|---|---|---|---|---|---|---|---|---|---|
| before | 32.0 | 38.8 | 18.1 | 11.0 | 3.3 | 1.4 | 1.0 | 249 | 210 |
| after | 28.5 | 36.5 | 17.2 | 11.0 | 3.2 | 1.4 | 1.0 | 253 | 240 |

Result: no regression in the dense swarm. Traffic is unchanged (FxBatch ~32/s, 10-25 KB/s;
ProjectileBatch 33/s, 0.5 KB/s; DamageNumbers ~8/s). Replicated attribute changes went
down (600 enemies: 3 330/s before, 1 269/s after; the per-enemy `Base` attribute churn is
gone). About 1 700 more instances are alive at all times (new HUD, arena dressing, caravan
cart, boss meshes in the catalogue); that is static, not growth.

New content (after only, 5-8 simulated s each, the real spawner):

| scenario | enemies alive | server | client | live peaks | traffic |
|---|---|---|---|---|---|
| Lost Caravan defence (2 waves) | 16 | 2.5 | 12.8 | hazards 0, CombatFx 38 parts | FxBatch 6.6/s, 0.8 KB/s |
| Briar Sentinel phase 2 (root lines, bramble ring, volley) | 15 | 1.5-3.4 | 8.7-20 | boss lines 6, rings 2, telegraphs 2 | FxBatch 5.8/s, 0.7 KB/s |
| Frostbound Colossus phase 2 (slam, ice lanes, breath, shards) | 14 | 1.4-2.8 | 8.5-15 | boss lines 4, hazards 2, telegraphs 4 | FxBatch 6.2/s, 0.9 KB/s |
| Endless stage 12 (HP x9.0, damage x3.2, spawn x2.84) | 59 | 3.9 | 16.3 | CombatFx 44 parts | FxBatch 18/s, 2.1 KB/s |

BossAI itself costs about 0.05 ms/frame here; the boss fights are far cheaper than the swarm
benchmark. Endless stage 12 stays under the normal `MaxLive` cap (59 alive on average).

Soak (200 enemies, 100 s, ~9 400 kills): instances alive 19 723 → 20 332, growth by
container after 40 s: enemy model pools +589 → +667, telegraph pool +476 → +477 (flat),
client VFX +154 → +189, CombatFx +24 (flat), pickups 50-80 (gems on the floor), HUD
ScreenGuis ±7. Every container levels off at its pool cap (enemy models: 48 per type and
elite variant); no leak found. The Lua heap swings 94-162 MB with garbage collection and
does not climb.

HUD (the rewrite): its frame callback stays at 1.0-2.4 ms/frame here, the same as before.
Text is only written when it changes (`setText`); about 12 same-value property writes per
frame remain (`Visible` / `TextColor3` re-set each frame), which Roblox treats as no-ops.
Gold pickups create about 40-70 tweens/s and 15-30 frames/s (pill punch, coin sparks, "+N"
float) at high kill rates; this was the same before the rewrite.

Fixes in this pass: none were needed (no measured regression). Not run on this machine
(too slow while shared): a before soak at commit `38f713a`, a party (Duo/Trio) swarm (the
preview has one local player), and a stage-sim full run.

## Remaining limits

- The swarm is capped by design: `Config.Enemies.MaxLive` 200 (pool 300). At 400-600 the
  server's `EnemyAI.Enemies` loop is the largest cost (about half the server time); it
  scales linearly with enemy count.
- On the client, EnemyRenderer and VFX are the two big callbacks. EnemyRenderer moves every
  detailed model each frame (BulkMoveTo); `Config.Graphics.MaxDetailedEnemies` 110 (down
  to 60 on slow frames) bounds it. VFX's per-frame Transparency / Size tweening of pooled
  effect parts is the largest source of property writes (12-15 k/s at 600 enemies here).
- Telegraph ground warnings scale with burrowers and lunges: up to ~40 k Transparency
  writes/s at 600 enemies (14/s warnings). Normal play (200) is a third of that.
- FxBatch bytes grow with kills (10 KB/s at 200, 25 KB/s at 600 enemies). That is within
  Roblox's budget but is the biggest remote.
- Party runs multiply the per-player work (weapons, projectiles, damage numbers); untested
  offline.

## Owner: checking it on a real device (MicroProfiler)

Do this in a live test server (or Studio play test) during a busy late-stage fight.

1. Frame rate: on PC press **Shift+F5** for the summary stats (or in Studio **View → Stats**). On a
   phone open the Roblox menu → **Settings** → turn **Performance Stats** on.
2. MicroProfiler on PC: press **Ctrl+F6** (Ctrl+Alt+F6 on some keyboards). Bars at the top
   show each frame; press **Ctrl+P** to pause, then click a tall bar to see what took the
   time. On a phone: Roblox menu → **Settings** → **Micro Profiler** On.
3. Server labels: the server marks its enemy loop with `EnemyAI.Enemies`, `EnemyAI.Think`,
   `EnemyAI.Sync` and `EnemyAI.Grids`. Open the Developer Console (**F9**, or type `/console`
   in chat) → **MicroProfiler** tab → record a few seconds of the server; the labels show up
   in the dump.
4. Memory: Developer Console → **Memory** (client and server). The `Instances` and `LuaHeap`
   numbers should level off after a few minutes of play, not keep climbing.
5. Network: Developer Console → **Network** (or Shift+F3 on PC): received KB/s should stay in
   the tens of KB/s even in the biggest fights.
6. Report: the FPS in the worst moment, the device, the stage and roughly how many enemies were
   on screen, and a screenshot of the paused MicroProfiler if FPS drops below ~40.
