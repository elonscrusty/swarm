# SWARM Full-game Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Complete recovered presentation work and ship the approved twelve-rank, less-interrupted survival progression with exploration, difficulty tiers and safe persistent rewards.

**Architecture:** Extend the existing data-driven weapon, level-up, run-modifier, encounter and UI modules. Keep the server authoritative and preserve existing profile data. The integrator owns shared economy and run lifecycle edits; workers own disjoint gameplay and presentation files.

**Tech Stack:** Roblox Luau, Rojo, luau-lsp, luau-compile, Lune offline preview runtime, existing Python/Chromium preview renderer.

**Spec:** `docs/superpowers/specs/2026-10-02-full-game-polish-design.md`

## Global Constraints

- Baseline is recovered commit `30bd6c3`; verified backups predate every edit.
- Twelve base weapon ranks, six weapon slots, passive rank three for evolution, no post-evolution mastery.
- Preserve saves, purchased coins, unlocks, owner art, Robux prices/products, and public records.
- Never publish Roblox, make purchases, change security settings, or reset saves.
- Use existing dependencies and module patterns. Prefer exact source and preserve raw verification logs.
- Workers do not commit or push; the integrator performs one final build and coordinated main commit/push.

## Review Focus

1. Bulk XP arriving while a panel is open must not lose levels, spawn extra panels or leave a player invulnerable.
2. A receipt save failure, repeated settlement, disconnect or run-server handoff must not acknowledge lost rewards or consume unrelated coins.
3. A touch held before a menu appears must never authorize a card, reroll or skip through another touch's record.
4. Hidden/destroyed icons, rotated phones and Reduced Effects changes must release animation state and preserve layout.
5. Full inventories, unavailable evolution partners, unlucky encounter placement and tier boundaries must remain playable and bounded.

## Task 1: Repair recovered ground and presentation infrastructure

**Files:** `src/client/GroundDetail.lua`, `src/client/ClientMain.client.lua`, `src/client/ArtImage.lua`, `src/client/IdleFx.lua`, `docs/AUDIO.md`.

**Owner:** Coordinator for GroundDetail/ClientMain/audio documentation; presentation worker for ArtImage/IdleFx.

- [x] Confirm baseline compiler/analyzer failures from `../toolchain/baseline-analyze.log` and add a focused ground smoke check.
- [x] Replace invalid XOR syntax with `bit32.bxor`, repair numeric patterns and the footprint return type, and initialize GroundDetail after client settings/UI setup.
- [x] Correct ArtImage idle descriptor typing; restore idle pose on Reduced Effects transitions and correct glow sizing under root scaling.
- [x] Verify bounded grass pool counts, clear/run lifecycle and changing effect budget. Record the three checked audio IDs and exact remaining Studio checks.

## Task 2: Twelve-rank progression and grouped upgrade panels

**Files:** `src/shared/WeaponData.lua`, LevelUp/XP sections of `src/shared/Config.lua`, `src/server/Modules/LevelUpSystem.lua`, `src/server/Modules/XPSystem.lua`, relevant progression regression scene.

**Owner:** Progression worker. Only use anchored patches in Config, since other owners edit separate sections.

**Interfaces:** Continue existing `LevelUpOffer` and `LevelUpClose`. Offers additionally carry `PanelId`, `BatchRemaining`, and `BatchTotal`; repeated offers with the same PanelId update the existing panel without replaying entrance/exit. Existing `Pending` remains total banked levels. `ChoicesPerPanel=4`. (The `FirstOfferSeconds` / `OfferIntervalSeconds` combat-time gates planned here were dropped: the owner decided every filled XP bar opens the panel immediately, with pace coming from `Config.XP` costs and `Config.XP.CoopShare` only.) `LevelUpSystem` never modifies RunManager directly without coordination.

- [x] Add assertions for all seventeen twelve-row weapons, actual useful changes, rank-three evolution rejection/acceptance, and nondecreasing XP costs after level twenty. Observe failure first.
- [x] Extend each weapon with explicit meaningful stats while preserving early identity, perks and stronger evolution stats; update all rank hints and dev labels.
- [x] Add panel state with one deadline and at most four earned choices, conserving XP/pending count across choices, rerolls, skip, timeout, death and chest upgrades.
- [x] Add checks for the final useful upgrade draining queued coin levels without offers/pause, including bulk XP and late evolution availability.
- [x] Route post-max gold through GoldSystem; difficulty multiplier is `RunModifiers.DifficultyMultiplier("Gold")`, and streak time comes from the run's uninterrupted survival clock or a documented safe fallback.
- [x] Run focused checks, analyzer and compiler; send exact UI integration contract to presentation owner.

## Task 3: Phone UI, animated icons and reward presentation

**Files:** `src/client/UIKit.lua`, `UIBuilder.lua`, `Hud.lua`, `Icons.lua`, `LobbyScreen.lua`, `MenuUpgrades.lua`, `ArtImage.lua`, `IdleFx.lua`, `UIAnim.lua`, `MobileControls.lua`, `MiniMap.lua` as needed.

**Owner:** Presentation worker; no ClientMain, server or Config edits without coordinator.

**Interfaces:** UIKit Button callbacks accept optional activating InputObject. Same-PanelId LevelUpOffer updates the existing panel. Chest payload `Dramatic=true` selects the rare/evolution reel; false/absent ordinary rewards use a nonblocking compact animation. Difficulty selector sends `SetDifficulty(id)` and reads ProfileSync `Difficulty`/`DifficultyClears` plus historical Stats.Wins.

- [x] Reproduce touch-identity and idle reset/scaling failures with existing input and preview runtime checks before fixes.
- [x] Forward exact button InputObject; preserve movement/card arming rules. Wire deliberate home/shop/card icon effects through existing IdleFx helpers.
- [x] Keep grouped choices in one panel with clear remaining count. Ordinary chest notices do not cover the HUD or hold movement; rare dramatic rewards keep established presentation.
- [x] Add tier selector and clear unlock text, death-cause/coin retention result lines, heartbeat/low-health effect with reduced-effects behavior.
- [x] Verify phone landscape/portrait, hidden screens, rerolls/skips and repeated runs. Keep required cues visible when decorations are reduced.

## Task 4: Difficulty progression and permanent upgrades

**Files:** new `src/shared/DifficultyData.lua`, `src/server/Modules/RunModifiers.lua`, `src/shared/Remotes.lua`, non-LevelUp/XP `Config.lua` sections, `MetaUpgradeData.lua`, existing achievement data. Root integrates DataService, GoldSystem and RunManager hooks.

**Owner:** Coordinator, with exact root hooks agreed before RunManager edits.

**Interfaces:** `RunModifiers.DifficultyId(): string`; `DifficultyMultiplier(stat: string): number`; `CompleteDifficulty(player, cleared: number, won: boolean)`; profile `Difficulty` string and `DifficultyClears` boolean map. `DifficultyData` supplies tier order, names, multipliers and unlock checks from historical wins/clear flags. Run-server transfer retains selected difficulty.

- [x] Test Standard/Veteran/Nightmare unlock boundaries, invalid client requests, five-stage clear, historical winner access and no DEV unlocks.
- [x] Apply approved tier multipliers at existing enemy/spawn/reward boundaries and preserve live caps; Standard completion requires five clears.
- [x] Extend permanent track limits without changing existing prices/formulas or ownership. Add alternate tier-based achievement paths to existing locked heroes, never relock existing weapons.
- [x] Verify restart/handoff preserves selected tier and unlocks; server rejects locked choices.

## Task 5: Optional encounters, boss phases and held revives

**Files:** existing `CaravanEvent.lua`, `LootSystem.lua`, `StageManager.lua`, `BossAI.lua`, `BossData.lua`, `BiomeHazards.lua`, `EnemySpawner.lua`, client interaction/minimap adapters; RunManager revive edits explicitly handed off by root.

**Owner:** Gameplay worker in the second wave after Task 2; coordinator manages file handoff.

- [x] Add deterministic checks for optional placement, one-shot reward grants, puzzle success/reset and deliberately activated elite encounters.
- [x] Reuse existing interactable/encounter replication for one or two locations selected from caravan, guarded elite, rune shrine and treasure cache. Keep all important locations on the minimap and secrets run-local.
- [x] Add enhanced existing boss attack combinations below forty percent HP, preserve telegraphs and caps, and exercise every boss family in simulation.
- [x] Require a two-second held revive with server proximity/eligibility checks, cancel on release/range/death, and verify co-op choice protection cannot bypass conditions.
- [x] Validate stage travel clears encounters/hazards and does not create double rewards or leftover callbacks.

## Task 6: Durable economy and lifecycle integration

**Files:** `DataService.lua`, `MonetizationService.lua`, `GoldSystem.lua`, `RunManager.lua`, `RunServers.lua` as required; economy regression checks.

**Owner:** Root integrator only until explicit handoff.

- [x] Add failure/retry receipt and live-store-unavailable checks; acknowledge only after durable persistence.
- [x] Implement per-run safe accounting and idempotent retention settlement: 25% +15 percentage points per cleared stage capped85%, safe extraction100%; protect prior/purchased balance.
- [x] Cover duplicate end events, abandon, disconnect, crash recovery and successful/failed handoffs. Temporary knockdown does not settle.
- [x] Add profile defaults for Difficulty/DifficultyClears without resetting existing fields; integrate tier completion and result payloads, including death cause and retained/lost amounts.
- [x] Coordinate revive and streak timing contracts with gameplay and progression workers.

## Task 7: Integrated verification and delivery

**Owner:** Root integrator; coordinator reviews worker batches and cross-module contracts.

- [x] Run complete analyzer, unoptimized compiler, icon checks and focused regression simulations. Review spec coverage and all shared payloads.
- [x] Render menu, upgrade, reward, minimap, grass and results at desktop, phone and portrait sizes; inspect actual renders where supported.
- [x] Exercise stage/weapon/XP/reward/co-op lifecycle simulations and note any unsupported Studio-only checks.
- [x] Update TESTING.md and release evidence with PASS/FAIL/BLOCKED, rebuild `build/Swarm.rbxlx` once, and commit/push main. Do not publish Roblox.

## Execution ledger

- Design and plan self-review: approved twelve-rank requirement replaces earlier eight-rank proposal; all requirements map to Tasks 1–7. Root's backup is already complete. User's explicit 'do it all, no questions asked' supersedes additional design/plan approval prompts.
- Shared worktree ruling: use the dedicated recovered clone already backed up, matching repository main workflow. Do not create another checkout or discard recovered commits.
- Model allocation: Astra coordinates/integrates; Sol workers handle independent gameplay and UI work in two concurrent slots. Reuse completed workers when thread capacity prevents new contexts, with explicit scopes and fresh source reads.
- Coordinator implementation: difficulty data and validation, tier multipliers, additive hero unlocks, expanded permanent caps, adaptive grass wiring, heartbeat sound and pooled-voice correction are in place. Ground, difficulty, and audio focused checks pass. Music metadata is recorded in `docs/AUDIO.md`; audibility still requires Roblox.
- Progression worker implementation: all seventeen weapons have twelve explicit ranks; upgrade timing, bounded panels, bank preservation and post-cap coins pass `progression-regression`. Root independently found and corrected capped-stat passive eligibility and predictive synergy text.
- Encounter implementation: one or two distinct optional locations are drawn from guarded altar, caravan, rune sequence and treasure. Real remote-hold checks in `encounters-sim` cover deliberate activation, wrong sequence reset, success, single-use rewards, cleanup, and ordinary/legendary presentation. The initial missing-encounter failure was observed before implementation; the final scene passes without errors.
- Finite expedition implementation: `PortalOffer.Complete` hides continuation after five clears; the server rejects further continuation and returns on countdown. `expedition-sim` first failed the fifth-clear boundary, then passed finite return and Endless continuation beyond five.
- Combat worker implementation: six distinct boss follow-up combinations below forty percent HP, complete telegraphs, shared combat clocks, gentle opening, escalating variety and bounded biome eruptions. `combat-regression` passes; focused analysis and unoptimized compilation report no diagnostics.
- Independent reviews are underway before the integrated build. Root reviews coordinator/progression work; coordinator reviews economy/save/revive changes; the gameplay worker reviews encounter/difficulty integration. Tooling and real-device limitations remain the integrator's final release gate.
- Review outcomes: corrected Daily wins bypassing difficulty gates, held-revive releases lost to rate limiting, receipts mutating released profiles, and omitted difficulty in teleport tickets. Missing-host handoff now preserves the requested tier only when the replacement host's loaded profile grants access. Focused handoff checks pass both eligible and locked cases.
- Placement coverage expanded to ninety real arena builds: six biomes, four individual encounter types, three variants, and paired random locations. Every requested placement succeeded; no overlapping-location fallback was added. Guarded and caravan waves share the regular enemies' stage progression floor.
- UI worker completed twenty runtime checks in both phone orientations, with zero analyzer diagnostics and successful unoptimized compilation. Independent UI review of combat found no blocking defect. Coordinator review of the root's lifecycle fixes found no remaining blocker. Rendered visual checks and the final build remain Task 7.

- Final integrated evidence: zero analyzer diagnostics, all production files compile unoptimized, 75 art keys/29 symbols/49 used keys validate, and all 31 regression processes pass. The suite includes six real boss smoke scenes, 90 encounter placement builds and 20 UI assertions per phone orientation. Desktop/phone/portrait menu, upgrades, rewards, arena and results were rendered and visually inspected. A 200/400-enemy server benchmark and 30-second soak complete with zero mock errors; this is not a device FPS result.
- Final place built once and XML/source-verified: 102 scripts, 2,569,985 bytes. The owner-facing file and verification evidence are under the chat outputs directory. Studio/device tests remain explicitly unverified; publishing, purchases and security settings were not performed. Main commit/push follows repository authorization.
