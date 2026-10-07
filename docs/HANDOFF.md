# active-memory handoff: SWARM (Roblox horde-survival roguelite)

**Handoff #2** · 2026-10-07 · Lineage: #1 (2026-10-07): home TOP SCORES panel, phone layout fixes, open items list; #2 (2026-10-07): finished open items, two owner recording briefs (mobile clarity + boss/combat fairness), bigger icons, plan for the next 9 improvements

## 0. Instructions for Claude (read first)

You are continuing work from a previous chat. That chat is gone; this file is the complete context and the source of truth.

1. Read this whole file before replying.
2. Follow sections 3 (Style), 4 (Hard rules) and 5 (Corrections) in every reply, for the rest of this chat. They override your defaults.
3. Use the values in section 8 exactly. Never round, re-estimate, or "correct" them.
4. Do not suggest anything listed in section 7 (Changed / rejected) again unless the user brings it up.
5. Code word: None active. If the user types /amcodeword, start every reply with the phrase they choose (default "Yes Boss!").
6. Your first reply: at most 5 lines covering the goal, the current state, and the next step (section 11). Mention any files from section 13 that were not attached. Ask the questions in section 12 if there are any. End with "Ready to continue with <next step>?" Then wait for the user's go.

## 1. Mission
- **Goal:** keep improving the existing Roblox game "[BETA] SWARM ⚔ Wave Survival" (Rojo + Luau, repo elonscrusty/swarm, working dir /home/user/swarm) toward a publish-ready release; next: build the 9 improvements in docs/PROMPT_NEXT_BATCH.md.
- **Done looks like:** each item built behind its own `Config.Features` switch, regression scene added, full regressions + `bash tools/check.sh` clean, `build/Swarm.rbxlx` rebuilt, pushed to `main`, file + renders sent to the owner, PASS/FAIL/BLOCKED per item.
- **Why it matters:** owner plays on a phone and wants the game clear, fair and ready to publish.

## 2. About the user (as relevant to this work)
- Owner: kcdrewcarter, Roblox user 20194281 (email mysoncarter@gmail.com, use only for attribution).
- Not a programmer; plays on a phone (iPhone, landscape; recordings at 1108×512); no Studio access during sessions.
- Nothing is verified in Studio unless the owner says so.

## 3. Style & communication
- **Language:** English.
- **Tone:** talk to the owner "like I'm 3 years old" (owner's words, latest instruction): tiny words, very short sentences, simple emoji markers are fine (🎮 ✅ 🧪 📦).
- **Reply length:** short. Lists over paragraphs.
- **Formatting:** short bullet lists, a few emojis, no jargon. Code, commits and docs stay in normal prose (CLAUDE.md).
- **Working style:** build ALL the changes first, then test once at the end (owner: "making one change then testing takes wayyy to long"). Use parallel helper agents for building; one big test round after.
- **Avoid:** long technical explanations in chat; per-change test loops.

## 4. Hard rules (word for word)
From CLAUDE.md (loads automatically, binding):
1. "Never pay-to-win: Robux buys cosmetics/coins only; early unlock only for characters also earnable by play."
2. "Don't publish, deploy, buy assets, create products, invent or change prices, or make purchases."
3. "Don't enable Studio API access, HTTP or other security settings; give the owner steps."
4. "Don't wipe saves, reset unlocks or reset public rankings. Studio uses separate `_Studio` DataStores."
5. "DEV access is enforced on the server (`RunManager.isDev`, `DevAllowlist`); client hiding is not security. Runs that used DEV tools are tainted and never reach leaderboards or records."
6. "Player text (bug reports) always goes through Roblox text filtering; never show unfiltered text."
7. "No secrets in client code or ReplicatedStorage. No external backend, analytics, ads or subscriptions."
8. "Never present a mock or unconnected feature as working. Report verified vs assumed (PASS/FAIL/BLOCKED)."
9. "Don't copy Megabonk characters, items, assets or text."
10. "Save straight to `main` and push (`git push origin main`). No PRs unless asked."
11. "Commit messages end with the attribution lines the session provides. Never put model names in code or commits."
12. "Rebuild and commit `build/Swarm.rbxlx` once at the end of a batch, then send it to the owner."
From the owner's briefs this chat:
13. "Do not invent bugs, claim the recording proves the cause of bad ratings, or claim tests passed without running them."
14. "Treat the numerical values below as initial tuning candidates, not proven optimal settings. Centralize them in the existing configuration."
15. "Fix an actual logic defect before compensating for it with easier numbers."
16. Next-batch prompt: "Run only one lune process at a time; the machine has 4 cores." (in practice ≤2 heavy jobs via the lock script was fine with 15 GB RAM)

## 5. Corrections log
| # | Claude did | The user wanted |
|---|---|---|
| 1 | Tested after every helper's change (slow queue) | "make all changes then test it" — build everything first, one test round at the end |
| 2 | Caveman-style chat replies | "Talk to me like I'm 3 years old from now on" |
| 3 | Made Hero Power favourites icons bigger, thinking that was the "powerful screen" | They meant the in-run "Power up" screen ("choose 3 upgrades"); that was then made bigger too |

## 6. Decisions
| Decision | Why |
|---|---|
| Build first, test once at the end | user's call |
| Merchant prices unchanged (63 = 25 × 2.5 from the owner's two gold passes) | rule: never change prices |
| Portal arrow hides while the merchant panel is open | brief allowed "suppress or relocate" |
| Show "Defeated by: <cause>" on results again | latest owner brief overrides the older request that removed it |
| First solo run reveals the portal after the first upgrade pick (cap 45 s) | owner brief: basics before the portal |
| Stage-1 intro policy: no new caravan/escort during the boss, 20 s quiet after | owner brief 2 |

## 7. Changed / rejected
- Testing after each change → build all, test once at the end (owner).
- Caveman style → "like I'm 3 years old" (owner).
- Old results-screen request (no death cause) → show "Defeated by" line (owner's newer brief).
- Villager catch-up `CatchUp = 45` → `12` (a rock 40 studs back stranded it; real bug).
- Card art on phones `min(110, w*0.42)` → `min(150, w*0.55)`.
- ❌ Lowering merchant prices globally (forbidden; prices scale with GoldMult on purpose).
- ❌ Removing JUMP (it has a purpose: bunny-hop speed to 1.24x, hopping onto low obstacles).

## 8. Data & facts (exact)
- Repo: elonscrusty/swarm, branch `main`, HEAD `ef1abbd` (merge) after `7fe1d5b` bigger level-up pictures. Remote also has `6029d30` docs/PROMPT_NEXT_BATCH.md.
- Toolchain (reinstall if missing): `/tmp/sh-tools` with lune 0.10.4 (via `bash tools/preview/setup.sh`), rojo v7.4.4 (`rojo/rojo`), luau-lsp latest (`lsp/luau-lsp`), `globalTypes.d.luau` (luau-lsp repo scripts/), luau-compile (luau-lang release `luau-ubuntu.zip` into `luau/`).
- Commands: `bash tools/check.sh [--quick]`; `bash tools/preview/render.sh <scene> --device <d> --outdir <dir>`; `python3 tools/preview/check_layout.py <dir|json>`; `python3 tools/run_regressions.py --lune /tmp/sh-tools/lune/lune --out <dir> [--only a,b] [--workers N]`; build `/tmp/sh-tools/rojo/rojo build default.project.json -o build/Swarm.rbxlx`.
- Preview devices: pc, laptop, phone, iphone (Largest text, 852×393), phone-portrait, tablet, phone-1108 (owner's recording 1108×512), phone-small (667×375).
- Last full regression: 157/165 first pass; the 8 failures fixed/rerun → all PASS. After that, 7/7 level-up checks PASS. perf-regression PASS; perf-sim result lost (log deleted), not re-run.
- Key tuning (Config): Camera PhoneDistanceMult 0.85 (77.5 → 65.9 studs); Player.ContactGraceSeconds 0.4; LevelUp.RevealGraceSeconds 1.5; LevelUp.EarlyHelpLevels 3; FirstRun.RevealWaitsForPick true, RevealAfterPickSeconds 1, RevealCapSeconds 45; Caravan StartSeconds 1, LeaveGraceByStage {10} (8 elsewhere); Encounters.Intro {Stages={1}, QuietAfterSeconds=20}; Boss.Targeting PreferBoss, PreferWithin 20; Explore.Rescue.CatchUp 12.
- Scorpion Queen stage-1 solo Standard HP 1980 (Config.Boss.HP 9000 × BossHPByStage[1] 0.22).
- Merchant prices: Chests.Cost Small 25 / Large 60 / Golden 150 × stage scaling × GoldMult (StarterPack 1.25, DoubleGold 2).
- Feature switches: every feature has `Config.Features.<Name>`; `Announcer` is off (owner).

## 9. People, terms & names
- **People:** kcdrewcarter = owner.
- **Terms:** "Power up screen" = in-run level-up "CHOOSE YOUR UPGRADE"; "powerful screen" (ambiguous) — first read as Hero Power (Characters › favourites grid).
- **Names in use:** docs/CLARITY_PASS_2026-10-07.md (last batch report), docs/PROMPT_NEXT_BATCH.md (next batch spec), new scenes hud-merchant, portal-reveal-sim; client modules WorldLabelFade.lua; scratch lock script `scratchpad/lune-lock.sh` (session-only).

## 10. Work state
| Item | Status | Version / location | Notes |
|---|---|---|---|
| Handoff open items 1-4 (phone menus, tray, audit leftovers, regressions) | done | main | audit items were already fixed |
| Brief 1: mobile clarity (HUD, portal, tutorial, cards, merchant, ULT/JUMP, PLAY, daily, DEV) | done, offline-tested | main, docs/CLARITY_PASS_2026-10-07.md | not Studio/phone tested |
| Brief 2: boss/combat/events/totem/items/results | done, offline-tested | main, same doc | boss fight duration never measured |
| Bigger icons: Hero Power favourites + level-up card pictures | done | main (a6163db, 7fe1d5b) | |
| build/Swarm.rbxlx | rebuilt and sent | main 7fe1d5b | |
| Next batch: 9 improvements | not started | docs/PROMPT_NEXT_BATCH.md | items 1, 2, 6, 11, 12, 15, 17, 18, 20 |
| Known leftovers | open | — | shared "More" scroll hint covers 2 words (Daily, Play advanced); merchant may touch the ability bar on the shortest phones; ULT first-ready callout per session only |

## 11. Next steps
1. **Next action:** reinstall the toolchain if `/tmp/sh-tools` is missing, run `bash tools/check.sh --quick`, then build item 1 (SmartTutorial) of docs/PROMPT_NEXT_BATCH.md — note brief-1 already reworked Tutorial.lua (tips Move/Attack/Gems/Portal/Boss, reveal after first pick), so merge, don't duplicate.
2. Build all 9 items (order: 1, 2, 6, then 11, 12, then 18, 17, 15, then 20) before testing.
3. One full test round: run_regressions, check.sh, renders on iphone/phone-portrait/pc/phone-1108, check_layout.
4. Rebuild build/Swarm.rbxlx, push main, send file + renders; report PASS/FAIL/BLOCKED per item.

## 12. Open questions ⚠️
- Gold amounts for daily quests (suggested 300 / 300 / 600) and comeback gift: owner must approve.
- Roblox group id for GroupBonus (Config.Group.Id stays 0 until given).
- Is the "Pioneer" Knight skin OK for the Starter Bundle?
- Starter Bundle product id/price: owner creates it (Id 0 = hidden).

## 13. Re-attach checklist
- Nothing to attach: docs/PROMPT_NEXT_BATCH.md and this file are in the repo.

---
<sub>Audit: 13/13 sections · 16 rules · 3 corrections · 30 data points · secrets removed: none found · generated by active-memory</sub>
