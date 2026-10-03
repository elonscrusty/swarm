# SWARM full-game polish and progression design

## Approval and baseline

The owner approved the complete fifteen-point design, including twelve base weapon ranks, and explicitly requested implementation without further questions. The owner requested a backup before changes. The integrator verified a source archive, complete Git bundle, original place file and SHA256 manifest under the chat outputs/backups directory before any edit. The recovered source baseline is `30bd6c3`, including twenty-four interrupted Claude commits.

This design records that approval and the tuning defaults needed to implement it. It supersedes the earlier eight-rank proposal. It does not authorize Roblox publishing, purchases, price/product changes, security-setting changes, save resets or leaderboard resets.

## Intended experience

SWARM should be an active, unpredictable survival adventure with a gentle opening, a broad six-weapon build, optional secrets and increasingly demanding enemies. A successful Standard expedition should normally take twenty to thirty minutes. Skilled players may finish faster; portals remain available immediately and no timer artificially forces a run length. Combat should be interrupted much less often. Phones retain readable attack and hazard cues even when decorative effects are reduced.

## Run progression

- Six weapon slots and six passive slots remain. Weapons have twelve base ranks with meaningful behavioral milestones and smaller numerical steps. Existing weapon identities, evolution names and owned art are preserved.
- Evolution requires rank twelve and rank three of the matching passive, capped by that passive's maximum. Evolution ends that weapon's upgrade chain. The unfinished ten-rank mastery chain is not activated.
- The first upgrade panel becomes eligible after twenty active combat seconds. Later panels are at least fifty active combat seconds apart, measured after a panel closes. Earned XP levels remain banked rather than discarded.
- A panel resolves up to four earned choices quickly without repeatedly closing and opening the overlay. Each choice spends one earned level. The panel has one bounded deadline, not a fresh timeout for every card. Solo combat pauses. In co-op the chooser is protected while teammates continue fighting.
- XP retains its existing early costs, then increases by two XP per level after level twenty instead of becoming permanently flat. Offline simulations and owner playtesting assess the resulting pace; the time targets are tuning goals, not claims of verified live balance.
- Once the full useful build has no acquisitions, upgrades or available evolutions left, later XP levels become coins automatically. Already queued levels drain immediately. No gold/heal chooser, pause or dramatic reward panel appears for these levels.
- The post-max coin base is twenty-five, multiplied by the selected difficulty reward multiplier and a survival multiplier of `min(3, 1 + 0.1 * whole survival minutes)`. A knockdown resets the uninterrupted survival streak. All coin grants use the existing server economy path.
- No weapon replacement is added. Rare upgrades combine behavior and numerical changes. Synergy recipes are hidden before activation, then the discovered active synergy is explained.

## Stages, challenge and exploration

- Standard completion is five cleared stages. Safe extraction remains available at each open portal. Endless continues to use its existing separate rules and records.
- Standard completion unlocks Veteran; Veteran completion unlocks Nightmare. Previous recorded Standard winners retain access to Veteran. No historical records are removed.
- Default tier multipliers (HP / damage / speed / density / gold): Standard `1 / 1 / 1 / 1 / 1`; Veteran `1.35 / 1.15 / 1.05 / 1.15 / 1.35`; Nightmare `1.75 / 1.35 / 1.12 / 1.25 / 1.75`. Existing live-enemy caps remain hard limits.
- Later challenge includes enemy behavior, movement and combat hazards, elite encounters, density and numerical scaling. Bosses gain enhanced attack patterns at forty percent HP. Tier challenge must not depend only on larger health pools.
- One or two optional special locations are available per stage, selected from existing caravan defense and guarded encounters plus a rune-order shrine and treasure cache. Optional elite encounters require a deliberate hold activation.
- The minimap marks important locations from the start. Undiscovered reward details can remain unknown; the map must not hide the location itself. Secret rewards and discovery state last only for the current run.
- Runs vary through existing shuffled biomes/bosses and randomized encounters. Occasional difficult combinations are allowed, but attacks still have readable cues and valid placement.
- Co-op scales challenge and rewards teamwork. Reviving requires approaching a downed teammate and holding for two seconds. The server validates continued proximity, eligibility and held interaction; release or leaving the radius cancels progress.

## Economy and persistent progress

- Existing savings, purchased coins, characters, cosmetics, unlocks and records are preserved.
- On unsuccessful final settlement, retain twenty-five percent of unspent current-run earnings plus fifteen percentage points per cleared stage, capped at eighty-five percent. Safe portal extraction retains one hundred percent.
- A temporary knockdown or revive does not settle the run. Abandon and disconnect settle unsuccessfully. Successful run-server handoffs do not settle or duplicate earnings. Settlement is idempotent per run.
- Current code deposits run earnings into the profile immediately. The economy implementation must distinguish current-run funds from existing savings and purchases before applying retention. A durable ledger or equivalent safe accounting prevents duplicate settlement and recovery errors.
- Extend existing permanent upgrade tracks using their existing effect rates and price formulas: MaxHP twenty, Might twenty, Armor eight, Speed six, Luck ten, Growth ten. Preserve Revive, Reroll and Skip limits and all Robux prices/mappings. Existing levels remain valid.
- Higher-tier rewards provide alternate achievement paths to existing challenge-earned heroes. Existing weapon access is never taken away. Do not introduce a permanent secret-unlock system.
- The results screen reports death cause, progress, earned/retained/lost run coins and quick retry. Paid receipt acknowledgement requires a durable successful save.

## Phone presentation and accessibility

- Complete the recovered minimap, grass, sound/music, animated icon and SHOP presentation work rather than duplicating it.
- Upgrade, reroll and skip input must validate the exact activating touch; ongoing movement touches must not select cards. Responsive layouts preserve safe areas and finger-sized controls.
- Ordinary chest rewards are brief nonblocking animations while combat continues. Rare rewards and evolutions can use the dramatic presentation.
- Low health adds a readable heartbeat/glow warning. Rich motion remains the default; Reduced Effects restores stable poses and suppresses unnecessary flashes.
- Automatic performance reduction lowers decorative particles, grass and idle glow load while preserving danger telegraphs, essential markers and controls. It does not alter server difficulty or player settings.
- Preserve owner artwork and existing licensed music asset IDs. The three music IDs were checked against Roblox public metadata; audibility and experience access still require Studio/device verification.

## Validation and integration

Use meaningful Luau regression checks for progression, economy, input/lifecycle rules and encounter/tier boundaries. Run the existing analyzer, unoptimized compiler, icon check, relevant offline simulation scenes and phone/portrait previews where the available renderer supports them. Rebuild the place once at the end of the integrated batch. Report PASS, FAIL and BLOCKED honestly; offline verification is not Studio verification. Commit and push main as repository instructions require, but never publish Roblox.
