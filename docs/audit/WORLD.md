# WORLD audit (enemies, arenas, bosses, difficulty), 2026-10-05

Scope: owner prompt sections 6 and 14 (`scratchpad/audit-prompt.md`). Audited source:
`audit-baseline-2026-10-05` (b07d83b). Offline only: real server modules on the Lune mock, headless.
Nothing was tested in Studio, on a device or with several real clients.

## How it was checked

- Baseline copy `scratchpad/world/base` = `git archive HEAD`; fixed copy `scratchpad/world/fix` =
  HEAD + this area's two files (`EnemySpawner.lua`, `CaravanEvent.lua`). Running in copies kept the
  other auditors' half-finished edits out of the results. Logs are in `scratchpad/world/out`.
- New regression `tools/preview/scenes/world-regression.luau`: **11 FAIL on the baseline, 0 FAIL
  with the fix** (`wr_base.log`, `wr_fix.log`). About 5 s real time.
- Difficulty: the balance audit's `econ-sim` bot (`scratchpad/econ`, a scratch scene, not in the
  tree), run against the fixed copy. Fresh Knight, buys chests greedily, "undying": a would-be
  lethal hit is counted and HP refills. The bot has no dodging and picks random cards.
- Scratch probe `idle-probe` (base and fix copies only): a hero idles 2 studs outside the portal ring.

Command used for each scene (`scratchpad/world/scene.sh`):
`lune run tools/preview/runtime/main.luau -- --scene <scene> --studio --device pc --out <json> --max-time 900 --set headless=on`
(`corner-regression` with `--max-time 3000`, as in `tools/run_regressions.py`).

## Matrix

| ID | Subsystem | Expected (source) | Files / functions | Repro / start state | Actual | Evidence | Sev | Root cause | Fix / proposal | Status | Next check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| W-01 | Spawn budgets, waves, elites | Waves grow each time, are capped, and the elite schedule follows `Config.Waves` | `EnemySpawner.startWave/pourWave/stepWaves`, `topUp`, `SpawnSurge` | Static table (below) + stage-sim, econ-sim | As specified: the same rules in all 6 arenas (only the obstacle layout and the floor hazards differ by arena). Waves are capped at MaxLive 200 (squad from wave ~30). The surge needs 213-250 on squad stages 4-5 and is cut to 200 (`stepSurge`). Boss crowd 12-60. | static + test | – | – | – | VERIFIED WORKING | Squad live test (BLOCKED) |
| W-02 | Reach at walls, corners and narrow gaps | Enemies reach a hero at every legal spot. Piles stuck at walls do not farm. | `EnemyAI.think/Step` | `corner-regression`: 6 arenas, walls, corners and pockets, every enemy role | PASS, 0 FAIL (fixed copy). Contact is a 2D distance check, so height (cliff tops, rims) gives no safe spot. A corner adds no safety: incoming damage rises (see Difficulty). | test | – | (fixed 2026-10-04, c5ad391) | – | VERIFIED WORKING | Studio playtest at the SE Forest corner (real character physics) |
| W-03 | Portal wave hold | The breather waits only while someone charges the portal (`Config.Waves.PortalHoldSeconds`) | `EnemySpawner.nearPortal` | Solo, stage 1: stand 2 studs outside the portal ring (radius 9) | **Before:** no wave ever came. In 12 min: 0 waves, 0 damage, 480 survival gold paid on MAIN MENU (up to 1,200 at the 30-min cap), plus playtime. A risk-free AFK spot. **After:** waves come (11 in 45 s); the idle hero dies at 1:17. Standing inside the ring still holds the wave and summons the boss in 2.1 s. | test (`world-regression` W-03, `idle-probe`) | **P1** (exploitable grant: borderline P0, but it pays less than normal play) | The hold radius was ring + 4 studs, which covers spots that never charge the portal; the dormant lock was not checked either | The hold applies only inside the charge ring and only when the portal can be charged (`PortalLockLeft` = 0) | **VERIFIED FIXED** | Studio: stand at the ring edge |
| W-04 | Elite rewards with no killer | An elite chest is a reward for beating the elite | `EnemySpawner.Kill` | An elite still alive when the portal opens (boss-fight random elite, caravan elite) | **Before:** the portal's sweep (`KillInRadius(..., nil)`) and an elite Bomb Tick blowing itself up each dropped a free chest (+1 chest). **After:** gems only. Control: an elite the hero kills still drops its chest. | test (W-04) | P2 | `Kill` paid the elite chest whether or not there was a killer | Chest only when `rp ~= nil` (altar guards unchanged) | **VERIFIED FIXED** | – |
| W-05 | Open-portal cleanup | Nothing hostile remains while the team chooses | `EnemySpawner.KillInRadius` (sweep), `StageManager.openPortal` | A Burrower from the boss fight is still tunnelling when the surge ends; an enemy strike is pending | **Before:** the Burrower survived the sweep (it was invulnerable) and kept hunting through the choice; the strike was still pending (enemies left 1, hazards 1). **After:** 0 and 0, still 0 three seconds into the choice. | test (W-05) | P2 | The sweep reused the bomb-pickup filter, which skips invulnerable enemies | `rp == nil` (the sweep) also takes burrowed enemies and calls `EnemyAI.ClearHazards(nil)`. Bomb pickups and the revive shockwave are unchanged. | **VERIFIED FIXED** | – |
| W-06 | Lost Caravan vs boss arrival | Caravan rewards need a defence (`CaravanEvent` header) | `CaravanEvent.Step` | Step into the ring, run to the portal, charge it | **Before:** the boss arriving saved *any* started defence: +1 item and +60 gold at 223 studs from the cart, on every stage, with no defence. **After:** the defence goes on and is Lost after LeaveGrace. A ring that is held (someone inside, at least half the hold done) is still saved when the boss comes (the designed "scattered the raiders"). A ring held for less keeps going and the full hold saves it during the boss fight (exactly 1 item). | test (W-06a/b/c), caravan-sim parts 1-2 PASS | **P1** (repeatable free run item) | Unconditional success on the first Boss frame | Success needs the ring held and ≥ 50 % progress (`SCATTER_SHARE`); it is checked once per defence (`BossSeen`) | **VERIFIED FIXED** | Duo: one player holds, one charges |
| W-07 | Boss telegraphs, phases, cleanup | Invulnerable entrance, attacks only through telegraphs, phase 2, collapse clears hazards / eggs / banner, one kill | `BossAI`, `EnemySpawner.Damage/Kill` | `boss-sim` Queen, Hive Mother, Frostbound Colossus (fixed copy); all 6 in the baseline run (83/83) | PASS, 0 errors. `OnBossKilled` is guarded by the phase, and `Damage` ignores a dying boss (no double kill). | test | – | – | – | VERIFIED WORKING | Studio readability of telegraphs |
| W-08 | Transitions | Combat can't be skipped, one portal per stage, stage clear awarded once | `StageManager` (JOURNEY), `MapBuilder.BuildArena/BuildPortal`, `RunManager.finishPlayer` | stage-sim, portal-hold-regression, choice-regression, world-regression (fixed copy) | Boss and surge are always required (the surge ends after 20 s or with 80 % killed). The portal is a child of the arena model, which `DestroyArena` removes on every build. `StageCleared` fires only from `openPortal`; boss gold is paid once (phase guard); the win bonus is guarded by `WinPaid`. Dev "Next stage" during a boss fight leaves the boss alive into the Open phase (dev only, the run is tainted). | test + static | P2 (dev only) | `DevNextStage` → `openPortal` skips bosses | FOR OTHERS (JOURNEY): optional `Despawn` of `EnemySpawner.Boss` in `DevNextStage` | VERIFIED WORKING (player paths) | – |
| W-09 | Caravan during the Open phase | – | `CaravanEvent.Step` | Start it in the last seconds of the surge, then hold during the choice | By design, hold time counts while the portal is open but no waves come, so about 15 s of the 20 s hold can be free. | static | P2 | Design | Proposal: stop counting progress in Open (or end the defence as Lost/Saved at the sweep). Owner decision. | UNVERIFIABLE (not run) | – |
| W-10 | Rush play | – | `Config.Stages.PortalLockSeconds {0,0}` (owner) | econ-sim `explore=60` + Bargain | Charging early skips the exploration waves, but it is **not** easier: lower level, higher damage taken (below). | test | – | Owner design | – | VERIFIED WORKING | – |
| W-11 | Contact through thin walls | No hits through walls | `EnemyAI.Step` contact (2D distance) | – | A hit would need a collider thinner than about 0.2 studs between the hero and the enemy (push-out keeps enemies a full radius off faces). None is known; not measured. | static | P2 | – | – | NOT RUN | Optional probe: thinnest box per arena |
| W-12 | Second world ease | Stages should get harder | `Config.Stages`, `Config.Waves` | econ-sim moving, seeds 1-2 | Confirmed for a buying build: stage 2 is easier than stage 1 (below). Not for a build that doesn't buy. | test | P2 (balance) | Stage-1 chests are cheap; the bot buys 13+ before stage 2 | Proposals only (below) | UNVERIFIABLE (balance call) | Owner decision, then re-measure |
| W-13 | Snow visibility | Enemies, heals and hazards readable on snow | MapBuilder snow palette; art owned by ENEMY/VFX art | – | Not re-rendered in this audit (shared machine). The 2026-10-04 fixes (ART-05) are documented as offline renders only. | – | P2 | – | SCREENS / art follow-up | UNVERIFIABLE | Studio on snow at the owner's zoom |
| W-14 | Co-op targeting at walls | Each enemy chases the nearest living player | `EnemyAI.nearestPlayer` | – | Solo sims only | – | – | – | – | UNVERIFIABLE (multi-client BLOCKED) | Duo playtest |

## Spawn budget (W-01; `Config.Waves`, `Config.Stages`, `Difficulty.PlayerCountMult`)

| Wave | Solo | Duo | Squad | Elites (from wave 4; always on every 5th wave) |
|---|---|---|---|---|
| 1 / 2 / 4 | 12 / 15 / 21 | 19 / 24 / 34 | 30 / 38 / 53 | 0 / 0 / 1 |
| 5 (big) / 10 (big) | 32 / 49 | 51 / 78 | 81 / 122 | 1 |
| 15 (big) / 20 (big) / 30 (big) | 59 / 69 / 89 | 95 / 111 / 143 | 147 / 173 / 200 (cap) | 2 / 3 / 3 |
| Surge, stage 1 / 3 / 5 | 40 / 70 / 100 | 64 / 112 / 160 | 100 / 175 / 250 → 200 | none |

Boss crowd: 35 % of the live target, between 12 and 60. Nests every 4th wave from stage 2 (at most 2 alive).
Boss HP = 9000 × boss HPMult (0.85-1.2) × `BossHPByStage` {0.22, 0.4, 0.85, 1.35, 2.0} × (1 + 0.6 per extra
player). These are the post-tune values (BALANCE_TUNE 1b). The current `Config` matches BALANCE_TUNE
1a, 1b and 5a: `MaxTier` 16, the boss list above, `LateCostExponent` 0.75, `EliteLateStageScale` 0.05.

## Difficulty: ordinary vs optimized vs exploit play (current curve, fixed copy)

Fresh Knight, greedy chest buying, solo, econ-sim. Small samples: n=2 for moving and rush, n=1 for
standing and corner. Per stage: damage taken per minute / minimum HP / would-be deaths. Boss = time
from first hit to kill.

| Play | Stage 1 | Stage 2 | Stage 3 | Stage 4 | Stage 5 | Run |
|---|---|---|---|---|---|---|
| **Moving** (circles; seed 1 / 2) | 100/6 %/0 · 93/1 %/2 | 85/65 %/0 · 50/65 %/0 | 76/61 %/0 · 87/46 %/0 | 131/11 %/0 · 67/67 %/0 | 146/17 %/0 · 104/83 %/0 | 17.8 / 17.2 min, level 61 / 69, lobby +4,173 / +4,470 |
| Moving: boss time | 65 / 64 s | 35 / 22 s | 29 / 23 s | 14 / 11 s | 20 / 15 s | |
| **Rush + Bargain** (`explore=60`, seed 1 / 2) | 118/2 %/2 · 201/4 %/5 | 191/8 %/0 · 133/15 %/2 | 354/9 %/3 · 341/7 %/5 | 358/9 %/1 · 120/9 %/1 | 744/1 %/2 · 315/6 %/2 | 14.6 / 13.0 min, level 48 / 56, lobby +4,425 / +4,394; boss force-killed on stages 1-3 (seed 1) |
| **Standing**, open field (3 stages) | 150/3 %/2 | 227/9 %/2 | 288/5 %/1 | | | level 40, kills 2,132 |
| **Exploit: corner** (SE, 3 stages) | 244/1 %/4 | 433/4 %/4 | 802/5 %/7 | | | level 51, kills 2,853, gold +4,897 |
| **Exploit: portal-edge idle** (W-03) | before fix: 12 min, 0 damage, +480 gold. After: dead at 1:17 | | | | | |

Reading:
- No exploit or stationary play beats moving play on survival. Standing still takes 1.5-3× the
  damage; the corner takes 3-9× and adds would-be deaths on every stage. The corner does earn more
  kills and levels: enemies arrive from fewer sides and the bot's weapons hit dense piles. That
  income is real fighting (the enemies reach the hero), not a trapped pile.
- Rushing the portal (owner's portal-at-once rule) skips exploration waves, but it lowers the level
  (48-56 vs 61-69) and raises the damage. It is a harder way to play, not an exploit.
- Stage 5 boss: 15-20 s for the moving bot (goal 25-30 s from BALANCE_TUNE is still not met).

## Second world ease (W-12): current curve confirmed

For the moving, buying bot, stage 2 is easier than stage 1 in both seeds: minimum HP 6 % → 65 % and
1 % → 65 %; damage 100 → 85 and 93 → 50 per minute; boss time 65 → 35 s and 64 → 22 s. Yesterday's
tune runs (`scratchpad/econ/tune/out/x75y05_A_s*`, same Config) show the same in 2 of 3 seeds.
Without buying (cohort B, standing) stage 2 is *harder* than stage 1. So the ease comes from the
stage-1 shop (13 Small + 2 Large + 1 Golden chest, about 25 levels by stage 2), not from weak stage-2
enemies.

Proposals (not applied; owner decision; each needs a re-measure with cohorts A, B and C, stage 1 must
stay identical):
1. `Config.Stages.BossHPByStage[2]` 0.4 → 0.5: stage-2 boss time 22-35 s → about 28-44 s. This does
   not touch stage 1 or the waves. Note the older owner comment "round two is way too hard": this
   undoes part of that step, so the owner must agree.
2. A stage-2 wave bump without code: none exists (waves are counted across the whole run).
   `Waves.PerWave` would change stage 1 too, so it is rejected.
3. Leave it: stage 2 is still harder than stage 1 for players who don't buy, and the boss is the
   real threat (Moth Matriarch, EC-07).

## Changed files

| File | Change | Risk | Recovery |
|---|---|---|---|
| `src/server/Modules/EnemySpawner.lua` | `nearPortal` = charge ring only and only when chargeable (W-03); elite chest only with a killer (W-04); the sweep (`KillInRadius` with `rp == nil`) also takes burrowed enemies and clears enemy hazards (W-05) | Low: bomb pickups and the revive shockwave pass `rp` and are unchanged. A team standing inside the ring gets the boss in 2 s, as before. | Revert the three hunks |
| `src/server/Modules/CaravanEvent.lua` | Boss-arrival success needs the ring held and ≥ 50 % progress; checked once (W-06) | Low: an abandoned caravan is now Lost (as with walking away) | Revert the block |
| `tools/preview/scenes/world-regression.luau` | New regression | – | – |

Note: the same `EnemySpawner.lua` also has another auditor's NaN guard in `Damage`
(`not (amount > 0)`), which is not from this area.

## Tests (fixed copy unless noted)

| Test | Result |
|---|---|
| world-regression (baseline) | FAIL ×11 (proves W-03/04/05/06) |
| world-regression (fixed) | PASS |
| idle-probe base / fixed (scratch) | 0 damage, +480 gold in 12 min / dead at 1:17 |
| corner-regression (`--max-time 3000`) | PASS |
| boss-sim Queen / Hive Mother / Frostbound Colossus | PASS |
| stage-sim, portal-hold-regression, choice-regression, caravan-sim part 1 and 2, encounters-sim, encounter-placement | PASS |
| `tools/check.sh --quick` (working tree) | PASS |
| boss-sim Moth / Rhino / Briar after the change | NOT RUN (baseline PASS; code path is the same as the three rerun) |
| Studio, device, multi-client | BLOCKED |

## FOR OTHERS

- Lead: register the regression in `tools/run_regressions.py`. Add `"world-regression",` to the
  first `checks` tuple after `"corner-regression",`.
- JOURNEY (`StageManager.DevNextStage`): a boss alive at dev "Next stage" stays alive through the
  Open phase (dev only).
- ECONOMY: survival gold has no activity requirement. W-03 removes the one safe idle spot I found;
  any other safe spot would pay up to 1,200 gold per run.
