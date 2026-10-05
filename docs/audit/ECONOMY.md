# Economy audit (2026-10-05)

Area: currency, progression, leaderboards, purchases (mocks only). Auditor: ECONOMY.
Source audited: `audit-baseline-2026-10-05` (b07d83b) plus the fixes below. Environment:
offline Lune preview and the `econ-sim` bot only. No Studio, devices, live DataStores, real
purchases or multi-client. Whether the published place matches this source is UNVERIFIABLE.
No price, Robux, product, pass, save schema or balance value was changed.

## 1. Gold: sources and sinks (code trace)

All in-run gold goes through `GoldSystem.AddRunGold(rp, base)`:
`floor(base x PublishGoldMult x RunModifiers.GoldMult + 0.5)` into the saved escrow
(`data.RunEscrow`). Only that escrow pays for chests and shrines (`RunWallet`, `SpendRunGold`).
Clients send ids only, never amounts.

| Source / sink | Formula (before pass x curse x difficulty) | Where | Server-owned | Verdict |
|---|---|---|---|---|
| Kill | 25 % (wave 37.5 %) chance, 1-3 x Stats.GoldMult | `GoldSystem.OnKill` | yes | ok |
| Elite chest | (15-40 + 15) x (1 + 0.25 x (min(s,2)-1) + 0.05 x max(0,s-2)) x GoldMult | `LevelUpSystem.OpenChest` | yes | ok, matches BALANCE_TUNE 5a |
| Boss | 200 x GoldMult to each living player | `StageManager.OnBossKilled` | yes | fallen players get none (design) |
| Nest | Reward.Gold + GoldPerStage x (s-1), each living player | `EnemySpawner.Kill` | yes | ok |
| Caravan | event gold x GoldMult | `CaravanEvent` | yes | ok |
| Gold card / skip | 25 / 10 | `LevelUpSystem` | yes | ok |
| Full-build levels | 25 x min(3, 1 + 0.1 x min since last down) per level | `convertMaxedLevels` | yes | ok, 9-13 % of income |
| Portal return | 100 + 300 x cleared (once, `rp.WinPaid`) | `RunManager.finishPlayer` | yes | ok |
| Survival | 40 x whole minutes (max 30) x pass, straight to save | `GoldSystem.SurvivalGold` | yes | ok |
| First run / achievements | 200 once (save flag) / one-time rewards | `saveRunStats`, `AchievementService.unlock` | yes | once-only by flag / `Unlocked[id]` |
| Robux gold packs | 500 / 1,500 / 5,000 to the save | `MonetizationService` handlers | yes | not multiplied by passes; receipt idempotent by PurchaseId |
| Settlement | extraction 100 % of unspent; loss `min(0.85, 0.35+0.15 x cleared)` | `SettleRun`, `RecoverEscrow` | yes | once per run (`rp.GoldSettlement`) |
| Sink: chests / Chance | `StagePrice` (x (s/2)^0.75 from stage 3, capped at 5) then `PlayerPrice` with the shown GoldMult | `LootSystem` | yes | shown = charged (code + chest-gold-sim) |
| Sink: heroes | 10k / 20k / 30k | `onBuyCharacter` | yes | achievement heroes never sold |
| Sink: account upgrades | Revive 2,500, Reroll 800/1,600, Skip 600 (5,500 total) | `onBuyMeta` | yes | stale-level guard |
| Sink: hero upgrades | base x growth^n, stat levels capped at 20,000 | `onBuyHeroUpgrade` | yes | mastery cap, stale-level guard |

Rounding: every payout rounds once, after all multipliers. No runaway multiplier found: the
pass multiplier is applied in `AddRunGold` only, item/Bargain gold through `Stats.GoldMult`
only, and caps exist on curses (sum), Luck (2) and cooldown. Duplication: each one-time grant
has a flag (`WinPaid`, `GoldSettlement`, `FirstRunBonus`, `Unlocked[id]`, `RunEscrow.Id`,
`PurchaseIds`).

## 2. Measured economy sheet (econ-sim, current tree incl. the stage 3+ tune)

Method as `docs/overhaul/BALANCE_AUDIT.md` section 4 (scene copied from
`scratchpad/econ/tune/repo`, run on a snapshot of b07d83b in `scratchpad/econ/audit/repo`,
logs `scratchpad/econ/audit/out`, aggregator `scratchpad/econ/audit/agg.py`). Bot: Knight,
Standard Forest, 5 stages then RETURN, random cards, no dodging, "undying" (would-be deaths
logged, HP refilled), greedy = teleports to the best affordable paid chest (upper bound).
Mean ±sd [min-max]. **Small n**; stage 3-5 values drift between seeds (not deterministic
after stage 3); treat differences under ~15 % as noise.

Cohort A, fresh Knight, greedy buyer, n=5 (seeds 1-5):

| Stage | Time s | Gold earned | Gold/min | Spent | Paid chests bought | Min HP % | Would-be deaths (sum) | Boss TTK s |
|---|---|---|---|---|---|---|---|---|
| 1 | 257 ±10 | 566 ±63 | 132 ±12 | 517 | 63/77 (82 %) | 2 [1-6] | 9 | 63 ±8 |
| 2 | 224 ±16 | 1,203 ±204 | 326 ±74 | 965 | 69/80 (86 %) | 31 [4-65] | 3 | 38 ±12 |
| 3 | 216 ±12 | 1,825 ±404 | 512 ±139 | 1,676 | 59/71 (83 %) | 53 [6-77] | 3 | 34 ±11 |
| 4 | 206 ±21 | 2,893 ±611 | 854 ±226 | 2,522 | 54/77 (70 %) | 41 [11-69] | 1 | 22 ±14 |
| 5 | 191 ±17 | 5,324 ±630 | 1,688 ±286 | 4,322 | 56/75 (75 %) | 54 [3-94] | 2 | 25 ±13 |

Run: gross 11,810 ±1,754, spent 10,001 (85 %), unspent at extraction 1,809 ±71, survival
680 ±40, lobby +4,347 ±115 (includes about 1,850 one-time first-run and achievement gold, so a
repeat win pays about **2,500 lobby gold in ~18 min**). First purchase 0:24-1:00. Sources:
kills 38 %, elite chests 28 %, return bonus 14 %, boss 10 %, full-build coins 9 %, nests 2 %.

Cohort C, established Knight (Armor 4, Might 10 ...), greedy, n=2: bought 83 / 78 / 76 /
53 / 70 % on stages 1-5; min HP stages 4-5 64 / 98 %; lobby +4,312. Cohort B, fresh, never
buys, n=2: would-be deaths 9 / 13 / 16 / 7 / 6 per stage, min HP 0-6 % on every stage, lobby
+14,313 (repeat about 12,500). Cohort H, both gold passes, 2 stages, n=1: prices 63/150/375
and 143/345/863 (x2.5), 28 items bought in 2 stages (same count range as no pass: passes give
no in-run advantage), survival 800 = 40 x 8 x 2.5.

Reading against the tune goals (BALANCE_TUNE section 5): stage 4-5 purchase share 70 / 75 %
is inside the 60-80 % target with n=5 (was n=3); stage 1 first buy unchanged. Buying vs
banking stays a large, visible trade (A 2,500 vs B 12,500 lobby gold per repeat win; B
dies far more). Uncertainty: per-stage sd 15-35 % of the mean on stages 3-5.

Lobby sink scale (code): one hero's full track is 633,353 gold (Max HP 211,500, Might
231,300, the rest 190,553), account upgrades 5,500, heroes 60,000. At ~2,500 per greedy
win that is ~250 wins per hero; at ~12,500 (banking) ~50. PROPOSAL only (owner): the 20,000
cap levels of Max HP / Might (levels 11-20 of each) are 77 % of a hero's track; consider
whether that tail is intended. Not changed.

## 3. Finding matrix

| ID | Subsystem | Expected (source) | Files / functions | Repro / start state | Actual | Evidence | Sev | Root cause | Fix / proposal | Status | Next check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| EC-A01 | High-score boards: ties | Equal values share a rank (prompt 9: "ties, row identity") | `LeaderboardService.onRequest`, new `RankRows` | Two players on Stage 4, one on 6 | Before: #1, #2, #3 by store key order (medal for one of two equal runs). After: 1, 2, 2 | test: economy-regression (baseline 2 FAIL, fixed PASS) | P2 | rank = row index | Competition ranking (1, 2, 2, 4); MyRank uses it | VERIFIED FIXED | Studio board with real ties |
| EC-A02 | Best-score semantics | Board keeps the best ever; one run counted once | `Submit`, `flush` (UpdateAsync keeps max) | Submit 5000, then 3000, then the same run id at 99,999 | Board stays 5,000, queue empty | test: economy-regression | - | - | none | VERIFIED WORKING | live store |
| EC-A03 | Row identity (names) | One person, one name | `nameOf`, new `lookupNames` | Player on this server vs another server | Before: DisplayName while on your server, username elsewhere/after leave lookups. After: DisplayName via one batched `UserService:GetUserInfosByUserIdsAsync` per answer, username fallback, cached | static; test covers fallback + cache only (mock has no UserService, names equal) | P2 | `GetNameFromUserIdAsync` returns the username | batched display-name lookup, pcall'd | UNVERIFIABLE (fix in, live API not testable offline) | Studio: a friend's row on/off server |
| EC-A04 | Board error state | Error keeps last rows and says how old they are | `refresh`, `rowsOf`, `Step` | Store read fails after a good read | Before: Age reset to 0 on failure (stale rows looked fresh). After: `Tried` throttles, `Time` = last good read | test: economy-regression (baseline FAIL, fixed PASS) | P2 | one timestamp for two jobs | split `Tried` / `Time` | VERIFIED FIXED | - |
| EC-A06 | Board screen copy | Empty/error/count text true | `MenuLeaderboards` `EmptyText`, `CountText`, error note, HIGH SCORE subtitle | Read error with no rows; full top 50 | Before: "Nobody is on this board yet. Be the first!" + "Showing the last rows we had" with none; "50 ranked players" for a top-50 cut; "Best **Standard** run score" while Veteran/Nightmare runs count (Standard is a difficulty name) | test: leaderboards textcheck=on (7 PASS) + mismatch=board PASS | P2 | copy | error-aware texts; "Top 50 players"; "Best non-Endless run score, all servers" + "Any difficulty." | VERIFIED FIXED | phone layout (run) |
| EC-A05 | NEXT GOAL difficulty card | Progress matches the unlock rule (win = portal return with 5 cleared, not Endless/Daily) | `NextGoal.Pick` | BestStage 6, no Standard clear | Before: "Best: 5 / 5 stages" with Veteran still locked. After: "Not won yet" + "Then return through the portal (not Endless or Daily)" | test: economy-regression (baseline FAIL, fixed PASS) | P2 | share capped at 0.95 then x5 rounded to 5 | cleared count shown directly | VERIFIED FIXED | - |
| EC-A07 | Cross-server board | OrderedDataStore, Studio stores separate, DEV runs never submit | `LeaderboardService`, `RunManager.saveRunStats` | - | `SwarmLB_*` / `SwarmLB_Studio_*`; DEV-tainted runs return before Submit; budget reserve; UpdateAsync max; BindToClose flush | static + security-regression (DEV) | - | - | - | VERIFIED WORKING (offline) / UNVERIFIABLE live | live servers |
| EC-A08 | Score validation | Score from server counters only | `RunScore`, `saveRunStats` | - | Stage 1000 / boss 500 / level 20 / kill 1 / second 0.5, from server state; no client input | static | - | - | - | VERIFIED WORKING | - |
| EC-A09 | Score board fairness | One board compares like with like | `saveRunStats` | Nightmare, Horde curse or Daily run | All non-Endless runs share "Score": difficulty, curses (Horde adds kills) and Daily raise score potential. Labelled now (EC-A06) | static | P2 | design | PROPOSAL (owner): keep, or score Standard-difficulty no-curse runs only, or add a difficulty column | NOT APPLICABLE (decision) | owner |
| EC-A10 | Paging / caching | Top N cached, refresh while watched | `refresh`, `Step` | - | Top 50, one page, re-read at most every 60 s while asked within 180 s; client re-asks every 30 s and on open; "loading" retry chain per board; your entry beyond 50 shows save best "Not in the top 50" | static + leaderboards scenes | - | - | no paging beyond 50 (by design) | VERIFIED WORKING | - |
| EC-A11 | Personal best vs board | Card = row value; different save labelled | `MenuLeaderboards.YouText` | save lower / higher / queued | labelled per case | test: leaderboards mismatch=board PASS | - | - | - | VERIFIED WORKING | - |
| EC-A12 | Results: new high score | Results say when the run beat your best score | `RunManager.finishPlayer` (CommitInfo), `UIBuilder` results | beat BestScore | Results show "Score N" and NEW BEST TIME / STAGE / LEVEL, never NEW BEST SCORE | static | P2 | not sent | FOR OTHERS: send `NewBestScore` in CommitInfo (RunManager, JOURNEY) and show it (UIBuilder, SCREENS) | MISSING | - |
| EC-A13 | Level labels | Run level, account level, mastery distinct | `LobbyScreen` AccountPill, `Hud`, `MenuCharacters`, results | lobby home | Results: three separate cards (run "Temporary", mastery, account "Cosmetic") good. Lobby pill shows the **selected hero's badge next to "LV n" = account level** (reads as the hero's level); hero upgrade rows say "LV 3/10" and "Rank 4 needs mastery 2" for the same thing; "RANKS" = leaderboards | static | P2 | copy | FOR OTHERS (SCREENS): pill "ACCOUNT LV n" or a non-hero icon; use one word (LV) for upgrade levels in `MenuCharacters` 616 and the rule text | UNVERIFIED (proposal) | owner look |
| EC-A14 | Stats screen | Personal records in one place | `MenuStats` | STATS tab | Best time / stage / wins / runs / kills shown; no best score, best level or most kills (only on the boards) | static | P2 | - | FOR OTHERS (SCREENS): add Best score (Standard / Endless) and Highest level tiles from `Stats` | MISSING | - |
| EC-A15 | Account / mastery XP | Once per committed run, not DEV | `AccountService.AwardRun/AwardMastery` | - | after `rp.Committed` and DEV return; level derived from XP; rewards between levels granted once | static + mastery-regression PASS | - | - | - | VERIFIED WORKING | - |
| EC-A16 | UI refresh | Lobby numbers update after a run / buy | `SyncProfile` callers | - | sync on return, buys, achievements (lobby), passes, receipts; MenuTrack `Refresh` | static + progression-regression PASS | - | - | - | VERIFIED WORKING (offline) | Studio |
| EC-A17 | Results ledger | "earned" = gross | `UIBuilder` results ledger | - | Gross = GoldEarned + GoldSpent, unspent separate (the 10-04 finding is fixed) | static | - | - | - | VERIFIED WORKING | - |
| EC-A18 | Purchases: mapping | Shop item -> configured id -> handler | `MenuUpgrades.SHOP`, `Config.Monetization`, `buildProductHandlers` | - | 3 passes + 3 gold products + Revive map 1:1; skin passes all 0 = "coming soon"; gold packs not pass-multiplied | static | - | - | - | VERIFIED WORKING (static) | owner Studio test |
| EC-A19 | Purchases: ownership refresh | Pass works at once, prices stay = shown | `PromptGamePassPurchaseFinished`, `RefreshAttributes`, `PublishGoldMult` | buy a pass mid-run | cache set, attributes + GoldMult republished, profile synced (OWNED badge) | static | - | - | - | VERIFIED WORKING (static) | Studio |
| EC-A20 | Purchases: failure / receipts | Cancel changes nothing; receipt once | `processReceipt` | cancel; save fails | cancel ignored (Roblox shows its own UI); receipt recorded then acknowledged only after save; retry path saves again | static + safety-sim (SECURITY) | - | - | - | VERIFIED WORKING (mock) | real purchase: owner only |
| EC-A21 | Pass lookup at join | Earnings use the pass from the first coin | `OwnsPassId`, `warm` | pass owner, slow first lookup | an unknown pass counts as not owned until the lookup answers: the first seconds of a run can pay x1 | static | P2 | non-blocking cache | PROPOSAL (SECURITY owner): warm before run start or re-pay the difference | UNVERIFIABLE | Studio |
| EC-A22 | Paid chest with no grantable item | Gold refunded | `LootSystem.openChest` | every item of the rarity capped | only Phoenix is capped, so practically unreachable; would warn and keep the gold | static | P2 | no refund branch | FOR OTHERS: refund on `granted == false` | UNVERIFIABLE (unreachable today) | - |
| EC-A23 | Stage 3+ tune | Stages 1-2 unchanged, 60-80 % bought on 4-5 | `ItemData.StagePrice`, `OpenChest` | econ-sim A n=5 | 70 / 75 % bought on stages 4-5; first buy 0:24-1:00 | sim | - | - | - | VERIFIED WORKING (offline sim) | real players |

## 4. Changed files

| File | Change | Risk / recovery |
|---|---|---|
| `src/server/Modules/LeaderboardService.lua` | tie ranks (`RankRows`), batched display-name lookup with fallback, `Tried` vs `Time` | read path only; never writes or lowers a board. Revert the file to restore |
| `src/client/MenuLeaderboards.lua` | `EmptyText`, `CountText`, error note without rows, HIGH SCORE subtitle/caption | copy only |
| `src/shared/NextGoal.lua` | difficulty card progress text | display only |
| `tools/preview/scenes/economy-regression.luau` | new regression (EC-A01..05) | test |
| `tools/preview/scenes/leaderboards.luau` | `textcheck=on` mode (EC-A06) | test |
| `tools/preview/runtime/mock/classes/services.luau` | `GetSortedAsync` honours `failDataStores` reads | test mock; only scenes that fail reads are affected (storage-sim does not read boards) |

## 5. Tests (2026-10-05, offline Lune, commands from the repo root)

- `lune run tools/preview/runtime/main.luau -- --scene economy-regression --studio --device pc --out <o> --max-time 400 --set headless=on`: 20/20 PASS (baseline code: 5 FAIL).
- `... --scene leaderboards --studio --device pc --set status=error --set rows=0 --set textcheck=on`: 7/7 PASS; `--set textcheck=on --set rows=50` and `--set mismatch=board`: PASS.
- PASS (0 FAIL lines): economy-sim, chest-gold-sim, progression-regression, mastery-regression, settlement-lifecycle.
- `bash tools/check.sh --quick`: typecheck ok.
- econ-sim cohorts A x5, C x2, B x2, H x1 (section 2).
- BLOCKED: live OrderedDataStores, UserService names, real purchases, Studio, devices, multi-client.
