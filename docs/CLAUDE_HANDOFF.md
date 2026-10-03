# SWARM handoff from Codex

Continue work on `elonscrusty/swarm` from the latest `main`. Read `CLAUDE.md` and applicable `AGENTS.md` first. Preserve the completed work; inspect the source before changing it. The owner asked Codex to wrap up a stable batch when Claude usage reset. This is a handoff, not a claim that all requested features are complete.

## Latest decisions override earlier plans

- Automatic aiming only. Do not add manual aiming or an aiming setting.
- Every filled XP bar immediately offers an upgrade. Do not add an upgrade pacing timer or delayed menu gate. Slow progression through higher XP costs.
- Current XP costs are base 30 plus 12 per level through level 20, then 6 per later level: level 1 costs 42, level 20 costs 270, level 21 costs 276, and level 50 costs 450 (raised x1.5 from 20 + 8 after the owner's "way too many upgrade pop-ups" feedback; `levelrate-sim` numbers in TESTING.md). Shared gem XP in Duo / Trio is multiplied by `Config.XP.CoopShare`. Playtest and tune; these numbers are not live balance evidence.
- After all legal weapon, passive, and evolution upgrades are exhausted, further levels grant automatic coins scaled by difficulty and survival streak.
- The owner likes substantial animation, but specifically rejected the spinning settings cog and skin hover jitter. Keep the cog still and hover targets stable.
- Preserve six weapon slots, weapon milestones, matching-passive evolutions, distinct difficulty phases, exploration, stage-finale bosses, challenge unlocks, permanent progression, tougher co-op, and partial coin retention on defeat.

## Completed in this follow-up

The source includes upright lobby/HUD gold icons, Party/Best Time/Wins icons, permanent-upgrade tallies and cleaner tabs, restored Endless switch and difficulty button styling, steadier skin hover, clearer character details with bold arcade styling, guided Daily rules and closest-completion-first Achievements. Native grass patches replace triangular decoration; the minimap has clearer landmarks and marker shapes.

Immediate XP upgrade choices and the harder XP curve are implemented. The HUD labels XP progress, queued upgrades, and post-max coin progress without a pacing timer.

The new accessibility settings provide colorblind palettes and marker shapes, separate Reduce Flashes, detailed audio channels and Mute All, optional visual sound cues, and touch layout presets. HUD, UI, boss, XP and combat flash guards honor Reduce Flashes while retaining a steady low-health warning.

Team pings cover Location, Enemy, Loot, Help and Regroup. Client controls and pooled six-second markers are registered. Server validation checks participation, target IDs, distance, finite positions, cooldowns and recipients. Colors come from the server-assigned team roster. Automatic matchmaking remains unchanged.

The optional enemy journal is registered in the lobby and accessed through the Stats Journal tab. It reveals attack clues only for encountered enemies and records actual observed drops. Skins can be previewed independently, with explicit Equip. Daily results show score, personal best and rank only when matching current data is available.

Same-live-run co-op reconnect support keeps server-only reserved routing information and authoritative cached player state for 120 seconds. It validates the player, run, expiry and escrow before one-time consumption. Failed, expired, ended and forged paths are covered by portable tests. It does not resurrect a destroyed server. Never expose routing secrets through ProfileSync or client attributes.

Recent damage history is bounded to six hits over fifteen combat seconds. Defeat results show the latest hits first with HP loss and time before defeat; victory, escape and abandonment hide it. A compact LastRun record is saved and synchronized to the lobby.

## Remaining implementation and review

1. Build the small last-run lobby summary and explicit retry action. LastRun data and ProfileSync are ready; this client UI is not implemented. Route retry through the existing validated start-run flow and honor current character, mode, difficulty, unlock and party rules.
2. Finish/review weapon-combination clues gated by discovered ingredients. Existing evolution/synergy UI is present, but the requested discovery-gated behavior has not been claimed complete.
3. Review upgrade cards for concise benefit summaries. Existing delta/evolution descriptions remain; a final wording pass is unfinished.
4. Done: the planning and testing documents that mentioned timed upgrade pacing (TESTING.md, the full-game polish plan and spec) now carry the XP-only immediate-upgrade decision.
5. Playtest full 20–30 minute standard runs and tune the XP curve, difficulty, rewards and late-game variety. Portable regressions verify logic; they do not establish real balance or real phone performance.
6. Put discovered journal entries ahead of unknown placeholders. Final phone previews show alphabetical unknown rows burying known clues, especially in landscape. Keep unknown details hidden; change only row order and verify both orientations.

## Verification and delivery

The final source passes the portable `tools/check.py --quick`: zero type diagnostics, all production scripts compile, and icon checks pass. `tools/run_regressions.py` passes 45/45 processes, including both phone orientations, immediate progression, menus, journal discoveries, client pings, accessibility, and successful/expired/ended/forged reconnect paths. The revive fixture now clears its earned upgrade menu before checking combat-clock grace, because immediate menus legitimately pause solo simulation.

Focused damage-review tests pass in both phone orientations. Real Stats-to-Journal navigation also passes in both orientations, with zero preview errors. The inspected journal previews identified the ordering issue listed above. Source and XML place are rebuilt together at `build/Swarm.rbxlx`; all 108 source files match the embedded XML scripts. Codex's delivery report records the final commit, place hash and evidence paths.

The prior broad progression/polish baseline is commit `4fdac4f1974d7a7a3af36b38437eb7bdc08ed6b9`. Follow-up backups exist locally under the chat's `outputs/backups/`: the original full source/place/history backup, `swarm-before-lobby-adjustments`, and the 102-file hash-verified `swarm-before-accessibility-coop/src`. The handoff delivery also preserves a source snapshot and verification evidence.

Live Roblox teleports, live DataStores, Studio purchases, real audio playback, real phone input/performance and full-run balance remain unverified. Do not publish the place, make purchases, change product IDs/prices, enable API/security settings, wipe saves, reset rankings or upload new assets. The owner handles live publication after testing. Preserve existing monetization and save safeguards.

Back up files before edits. Use the smallest correct existing/native implementation. Delegate independent substantive work, review it, run appropriate focused checks plus required regressions, rebuild once at the end, commit and push main without a PR unless requested. Report PASS/FAIL/BLOCKED honestly; do not claim a feature works from a mock alone.
