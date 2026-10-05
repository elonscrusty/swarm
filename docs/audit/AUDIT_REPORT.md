# SWARM full-game audit, 2026-10-05: handoff

Area matrices (ID, expected, files, repro, evidence, severity, root cause, status):
JOURNEY.md, MATH.md, WORLD.md, SECURITY.md, ECONOMY.md, SCREENS.md, PERF.md (114 rows in total).

## 1. What was audited
- Source: branch `claude/relaxed-shannon-t6qo8p` = `main` at `b07d83b` (local tag `audit-baseline-2026-10-05`;
  the remote refused tag pushes, so recovery uses the commit id).
- Build: Rojo project `default.project.json` → `build/Swarm.rbxlx`. Whether the published place
  matches this source is UNVERIFIABLE from here (no Studio or universe access).
- Environment: Lune offline preview and sims only. No Studio, no real devices, no live
  multi-client server, no DataStores, no purchases. Config.Run.MaxPlayers = 4.
- Baseline before any change: `bash tools/check.sh` clean; `tools/run_regressions.py` 83/83 PASS.

## 2. Verified issues fixed (each with a regression that fails on the baseline code)
| ID | Sev | What | Files |
|---|---|---|---|
| SEC-03 | P1 | Same-server rejoin during the final save loaded the older save; the next autosave wrote it back (progress loss). Now waits up to 60 s, then asks the player to rejoin | DataService |
| W-03 | P1 | Standing just outside the portal ring held every wave: 0 damage and survival gold for 12 min. Only charging inside the ring holds waves now | EnemySpawner |
| W-06 | P1 | Stepping into the caravan ring then charging the portal "saved" the caravan (+1 item, +60 gold per stage) | CaravanEvent |
| SEC-04 | P2 | Corrupt record overwritten by defaults; old value now kept under `Recovered` | DataService |
| SEC-05 | P2 | Newer-schema save downgraded (migration could run twice) | DataService |
| W-04 | P2 | Elites with no killer (portal sweep, Bomb Tick) dropped free chests | EnemySpawner |
| W-05 | P2 | Portal sweep left burrowers and pending attacks | EnemySpawner |
| MATH-01..04 | P2 | Non-finite XP could hang the server; NaN heal/damage; permanent upgrade levels unclamped | XPSystem, RunManager, EnemySpawner, StatSheet |
| J-05 | P2 | Banked level-ups covered the stage-start card after travel | RunIntro |
| J-07 | P2 | Losing window focus mid-hold still opened and charged a chest | LootUI |
| J-08 | P2 | A DEV command tainted other groups' runs | RunManager |
| J-09 | P2 | Results never said NEW BEST SCORE | RunManager, UIBuilder |
| EC (several) | P2 | Tied scores now share a rank; board error states no longer show stale rows as fresh or "Be the first!"; board copy; next goal respects locked Veteran; same board name on every server (display-name lookup is untested offline) | LeaderboardService, MenuLeaderboards, NextGoal |
| EC-A21 | P2 | Pass owner paid x1 before the pass lookup answered; topped up afterwards | MonetizationService, GoldSystem |
| S-01 | P2 | Duo countdown note and curse row hidden behind buttons on iPhone | LobbyScreen |
| S-02, S-03, S-16 | P2 | Gamepad: B = back on lobby screens; BUILD key blocked behind the run menu; Start opens the run menu | LobbyScreen, Hud |
| S-04..06 | P2 | "ACCOUNT LV" label, one name for hero upgrade levels, best score + highest level tiles | LobbyScreen, MenuCharacters, MenuStats |
| S-18 | P2 | Pale moths and aphids darker on snow | EnemyRenderer |
| S-19 | P2 | Leaderboard YOUR BEST row off screen with the error note on iPhone | MenuLeaderboards |
| PERF-01 | P2 | HUD stage caption forced a full GUI layout every frame (1,632 in 1,750 frames → ~56) | Hud |

No P0 found. Every changed file is listed in `git diff audit-baseline-2026-10-05 --stat`
(19 src files, +466/−66), plus new test scenes under tools/preview/scenes and the runner.

## 3. Previous-work traceability (from the area matrices)
- Corner farming (Oct 4 lead): VERIFIED FIXED. Enemies reach corners; corner and open standing
  take 1.5-9x the damage of moving play; no trapped piles (corner-regression, world audit).
- Interruptions (38 rounds + 35 reels in 8:17): now measured. Solo 2.29 blocking interruptions per
  minute, 11.5 % of the run unable to move (64.5 s of 84 s is card choice), 22 of 27 rewards
  non-blocking; duo 9.5 %, a mate's choice never freezes the partner (interrupt-sim).
- Duplicated portal text, reel overflow, HP 46→40 during a reward panel: VERIFIED WORKING now.
  HP can still drop while a non-blocking reward card shows (by design).
- Duo choice protection: VERIFIED WORKING (server-bounded, no stale flags). DEV allowlist
  enforced server-side: VERIFIED WORKING.
- Stage 3+ economy tune: VERIFIED WORKING (70 % / 75 % of paid chests bought on stages 4/5).
- Second-world ease: confirmed still present for buying builds (stage 2 easier than stage 1).
  Not changed: owner decision below.
- Snow visibility: HUD VERIFIED WORKING; pale enemies fixed (S-18).
- No regressions caused by the overhaul were found.

## 4. Recovery
Reset to `b07d83b` (the pre-audit main) or revert the audit commits after it. No save schema change,
no Config price, product or Robux change, no leaderboard key change. DataService changes are
additive (a `Recovered` field only appears for corrupt records).

## 5. Test matrix
- `bash tools/check.sh`: PASS (type check 0 diagnostics, Rojo build ok).
- `python3 tools/run_regressions.py --lune /tmp/sh-tools/lune/lune`: 96/96 PASS. 13 checks were
  added by this audit: security, math, economy, world, journey, loot-focus, lobby-screens, hud-key,
  pass-warm, perf regressions, run-intro panel, results best score, leaderboards error.
- Layout: 141 scene/device renders through check_layout (SCREENS.md); about 12 variants NOT RUN.
- BLOCKED: Studio play, real phone/tablet, real gamepad, live 2-4 player server, DataStores,
  real purchases, asset permissions in the live experience, Roblox's own use of gamepad Start.

## 6. Measurements (offline mock, same machine, see PERF.md / ECONOMY.md / WORLD.md)
- Perf, before → after, mock client ms at 200/300/400 enemies: 30/38/47 → 21/29/30 (part is a mock
  artefact). No leaks in 5 menu cycles or a 10-minute soak.
- Economy: econ-sim n=5 fresh buyer: 70 %/75 % of paid chests on stages 4/5; first buy 0:24-1:00;
  repeat win ≈ 2,500 lobby gold (buy everything) or ≈ 12,500 (buy nothing); full hero track 633k.
- Difficulty: moving play n=2, no would-be deaths after stage 1, ends ≈ level 65.

## 7. Remaining items and decisions for the owner
Owner decisions (nothing applied):
1. SEC-02b: enemies still chase a player who is choosing, so they draw enemies off their partner for a short while.
2. SEC-13: lobby DEV gold/levels on the owner's live save can feed public boards (needs a save flag).
3. SEC-14: DEV ResetProgress also works in live servers (proposal: Studio only).
4. SEC-16: a friend can join a party from join data without an invite (proposal: invite card).
5. MATH-13: weapons lose up to a frame per attack (fix makes all weapons slightly faster).
6. MATH-14: weapon cards show base numbers before bonuses.
7. MATH-15: "Damage dealt" counts overkill.
8. WORLD: stage-2 boss HP 0.4 → 0.5 to fix second-world ease.
9. ECONOMY: 633k per-hero upgrade track; Score board mixes difficulties and curses.
10. SCREENS S-09: three uploaded home pictures are unused.
Open P2: MATH-17 Windstep cap briefly exceeded; LootSystem has no refund if a paid chest can't
grant (unreachable today); +32 connections plateau in the soak (untraced, bounded).

Owner checklist (Studio / phone / multi-client): docs/audit/SCREENS.md (assets, music), PERF.md
(phone), SECURITY.md (saves, purchases), plus docs/overhaul/MIGRATION_ROLLBACK.md.

## 8. Not done
Nothing was published, migrated, purchased or changed in production. No DataStore or leaderboard
was touched. Nothing was verified in Studio, on a device or in a live server.
