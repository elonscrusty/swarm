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
