# SWARM redesign: owner decisions

Source brief: `docs/redesign/reference/` (owner's Redesign Reference Pack, 2026-10-08).

| Date | Decision |
|---|---|
| 2026-10-08 | Redesign built as two parallel tracks: lobby (Chat 1) and gameplay + final integration (Chat 2). Each track works on its own branch, both branched from the shared base commit. Chat 2 merges both into `main` at the end. |
| 2026-10-08 | Playable roster becomes the four new classes: `ruckus`, `toastmaster`, `captain_croak`, `granny_boom`. |
| 2026-10-08 | The old 11 heroes (Knight, Mage, Rogue, Priest, Ranger, Alchemist, Engineer, Necromancer, Archer, Bard, Golem) are **hidden**: not selectable or shown. Their save data (`OwnedCharacters`, `Heroes`, `HeroUpgrades`, skins) stays in the save untouched and is never deleted. |
| 2026-10-08 | New class prices reuse the existing gold hero tiers: Ruckus free (every account), Toastmaster 10,000, Captain Croak 20,000, Granny Boom 30,000 gold. No Robux unlock (Config.Monetization.HeroUnlocks was never set up; leave it off). |
| 2026-10-08 | Players who bought old heroes with gold get **nothing extra**. Their old unlocks just stay stored. |

Facts found while preparing the split:
- Runs already happen in **reserved servers of the same place** (`src/server/Modules/RunServers.lua`, `TeleportAsync(game.PlaceId, ...)`). So the "match place" is this same place, and no new place id is needed. `targetMatchPlaceId` and `lobbyPlaceId` are both `game.PlaceId`.
- No hero was ever sold for Robux, so hiding old heroes touches no real-money purchase. The StarterPack pass's "Gold Trim skin for every character" is a Robux pass, so it must also apply to the new classes (gameplay track builds the look; lobby track shows it).
- Studio and unpublished copies have no teleports. In those, lobby and run share one server ("local" role, see OWNERSHIP.md).

## Continuation pack decisions (2026-10-09)

Source: `docs/redesign/continuation/Swarm-Complete-Continuation-Prompt.md` (owner's master prompt for both
chats). These map the pack onto the real project once, so both chats stay consistent. Everything is a
config value and can be changed.

| # | Decision |
|---|---|
| C1 | **Roster = 12 classes**: ruckus, toastmaster, captain_croak, granny_boom, coach_crunch, doug_janitor, peter_parkour, barry_plotter, rambozo, swolverine, crash_cassidy, knuckles_mcgee. The 11 old heroes stay hidden (saves untouched). Tony Starch / Darth Mulcher are excluded. |
| C2 | **Class access.** Ruckus is free. Toastmaster, Captain Croak and Granny Boom keep the owner's gold prices (10k / 20k / 30k, decision 2026-10-08) **and** can also be earned by their pack goal, whichever comes first. This adds a path; nothing is revoked or newly priced. Nobody has bought them yet (not published). The other 8 classes are earned only by their pack goals (XP 300, 3,000 studs, 3 elites, ... see the pack). There is no Robux route to any class. |
| C3 | **Goal progress.** The gameplay track counts it at run settlement from confirmed server events into `data.Stats.ClassGoals` (`XP`, `Distance`, `Elites`, `BestSurvive`, `Chests`, `Dashes`, `MostWeapons`, `Kills`, `CloseKills`, `Bosses`, `Revives`). The lobby track owns the goal table (in `ClassCatalog`: `Goal = {Stat, Need, Text}`) and the grant: `ClassOwnership.RefreshEarned(player) -> {newly unlocked ids}`. The gameplay track calls it right after settlement and shows new unlocks on results. |
| C4 | **One profile writer.** DataService stays the only save owner. The run's reward commit stays `RunManager.saveRunStats` / `GoldSystem.SettleRun` (once per run: `rp.Committed`, `rp.GoldSettlement`). There is one `ProcessReceipt` (MonetizationService). No second writer or receipt callback. |
| C5 | **Run structure (replaces the 5-stage portal loop).** One 15-minute Cliffwood run. At 12:30 a single beacon is revealed, followed by a 30 s rally and a 60 s charge (radius 35). Then the Basin Breaker spawns once, and its death is victory. A wipe is defeat. Overtime spawn ramp applies after 15:00. The single-map stage code stays behind a switch (off). Endless mode is hidden (its boards stay). |
| C6 | **Builds.** 4 weapon slots and 4 passive slots. Weapon ranks run 1-5 with the pack's damage, interval and rarity grants. The catalog is 15 weapons (12 signatures + Sword, Magic Orb, Vortex) and 8 loot passives, plus the pack's 4 evolutions and rank 3 / 5 milestones. Old weapons and passives are hidden from offers, not deleted. |
| C7 | **Gold.** The new **team run gold** (3 / 6 / 20 per kill) pays for chests (40 x 1.35^k, cap 400) and is temporary. The existing **account gold** reward is kept unchanged: personal kill-gold escrow, survival gold, clear / win bonuses, pass multipliers and loss retention. Chests no longer spend the personal escrow. |
| C8 | **Paid benefits kept as they are.** Revive product (offered on elimination, receipt-backed, ReviveTokens), VIP +1 reroll, StarterPack, DoubleGold and the cosmetics. No new paid revive, reroll or power. |
| C9 | **XP.** Personal shards for every eligible player within 120 studs; the pack's XP curve (20 + 12(L-1) + 3(L-1)^2) and XP values. |
| C10 | **Hand-off between chats = git.** The lobby chat works on `claude/brave-goodall-mzpahn`, merges `claude/dazzling-fermi-ycslnt` in at the start, pushes often, and writes `docs/redesign/handoff/LOBBY_READY.md` when validated. The gameplay chat works on `claude/dazzling-fermi-ycslnt`, merges the lobby branch whenever new commits land, and does the final merge to `main`. No Windows folder is needed. |
