# Sigils plan (owner-approved decisions, build after Hero Mastery)

Owner decisions (2026-10-03): name **Sigils**; duplicates turn into gold (150 common / 400 rare);
slot 2 unlocks when any hero reaches Mastery 3; the Daily Challenge ignores Sigils.
Drop chances (boss 25 %, elite 2 %, one elite Sigil per run) are the planned defaults, to be
tuned after playtests. No Robux anywhere. Nothing below is built yet.

CHARMS PLAN (read-only; nothing has been changed)

Naming conflict found: the word "Charm" is already used in the game. Storm Charm is a run item (src/shared/ItemData.lua:66) and Aegis Charm is a passive (src/shared/PassiveData.lua:316). Calling the new system "Charms" would mix it up with run items, which is exactly what we were told to avoid. I recommend calling them **Sigils**. Nothing in the code is named that yet. "Trophies" is the backup choice.

=== FOR THE OWNER (under 500 words) ===

**How it works**
- Bosses and elites sometimes drop a glowing Sigil. Every boss you kill has a 25% chance to drop one. Each elite has a 2% chance, capped at one elite Sigil per run. The drop belongs only to you: in co-op, each player rolls for themselves, so nobody steals another player's Sigil.
- You keep a Sigil only if you finish the run (win, or leave through the portal). If you lose, you keep it 35% of the time, the same as gold.
- Sigils are permanent, but none of them is simply stronger. Each one gives you something and takes something away.
- **Slots:** you get 1 slot to start. Slot 2 opens when any hero reaches Mastery 3, so it is earned by playing and can never be bought.
- **Duplicates:** a second copy of a Sigil you already own turns into gold: 150 for Common, 400 for Rare. Sigils never level up, so their power stays fixed.
- **Collection:** each Sigil can be owned once, so the collection is capped at the size of the list (12 to start). Sigils can't be sold or traded, and no Robux is involved anywhere.
- **Lobby:** a new "SIGILS" card goes next to CHARACTERS and UPGRADES. It shows the 2 slots at the top and the collection grid below, with grey silhouettes for Sigils you haven't found. Tap one to equip it. The equipped Sigils also show as small icons on the hero nameplate.

**Starter Sigils** (all original)
1. Hare's Foot: +15% move speed, -10% max HP
2. Clove Bulb: start with Garlic Aura, -1 level-up choice on your first card
3. Haggler's Coin: chests cost 10% less, -5% damage
4. Glass Eye: +8% crit chance, take 8% more damage
5. Tortoise Shell: +2 armor, -10% move speed
6. Ember Heart: +10% damage, no health regeneration
7. Lodestar: +40% pickup radius, -8% attack area
8. Miser's Purse: +15% gold, -10% XP
9. Scholar's Quill: +12% XP, -10% gold
10. Hourglass Sand: weapons +8% faster, effects 15% shorter
11. Wide Brim: +15% area, -10% projectile speed
12. Lone Wolf: +10% damage while no ally is within 30 studs, -10% damage while one is (aimed at co-op)

**Balance rules**
- No single number goes above 15%, and every Sigil has a cost of the same size.
- Hero Mastery stays the main way to get stronger. Two Sigils with their drawbacks come out to roughly +0 to +5% total power, compared with about +100% from maxed Mastery.
- Sigils never stack with themselves. They are added in their own clearly labelled step, after Mastery.
- **Daily Challenge ignores Sigils** so everyone plays the same setup. Other leaderboards allow them, because everyone can earn them.
- DEV tools can't drop or give Sigils into a real save. Runs that used DEV tools award nothing, which matches how records already work.

**Questions for you (suggested answer in brackets)**
1. Name: Sigils, Trophies, or still Charms? [Sigils]
2. Drop chances: boss 25%, elite 2%? [Yes. We tune after playtests]
3. Duplicates: gold (150 / 400) or "upgrade the Sigil"? [Gold. Upgrades would add power]
4. Slot 2: Mastery 3 on any hero, or a gold price? [Mastery 3. I won't set a gold price unless you choose one]
5. Daily Challenge without Sigils? [Yes]

=== ENGINEERING NOTES ===

**Save data**
- Bump `Config.Data.SchemaVersion` from 7 to 8 (Hero Mastery is already on 7). If Mastery ships at 7 first, Sigils become 8. If both ship together, add both in one migration.
- New fields: `Sigils {Owned {id → os.time()}, Equipped {id, id}}`.
- Migration `[7]`: if `data.Sigils` isn't a table, create it empty. It only adds fields and never deletes anything, so no save is wiped.
- Clean on load: drop unknown ids and any equipped Sigil the player doesn't own, remove duplicates, and trim `Equipped` to the unlocked slot count (`SlotsFor(data)`, which reads `data.Heroes` mastery).
- Add to the DataService save-shape doc block and to the `defaultData` helper.

**Data file**
- New `src/shared/SigilData.lua` with `Order`, plus per Sigil: `Id, Name, Rarity, Bonus {StatSheet keys}, Special?, Text, Desc`.
- Also holds `DupeGold`, drop chances and `SlotUnlockMastery`. Keep the numbers in Config only if the codebase prefers that.
- Sigils that a stat bonus can't express use `Special`: StartWeapon (Garlic), ChestPriceMult, NoRegen, LoneWolf.

**Drops, server-authoritative**
- Boss: hook `RunManager.OnBossKilled` (src/server/Modules/RunManager.lua:1273), which already loops over runPlayers.
- Elite: hook the `elseif e.Elite` branch in `EnemySpawner.Kill` (src/server/Modules/EnemySpawner.lua:1053). Skip `e.Guard` enemies and wave-spawned elites.
- Rolls use the server RNG. Write `rp.PendingSigils` (on boss kills, roll once per run player). Grant it in the RunManager commit step next to `masteryInfo`. That step already returns early for `rp.DevTainted`; also gate it with `RunModifiers.IsDaily()` (no drops in the Daily Challenge) and with the 35% keep chance on a loss.
- Runs happen on run servers (RunServers / teleport), so grant through DataService on the run server, just as gold and mastery are committed there.
- Show a "Sigil found" banner with `Hud.Announce`, and add a line to the results screen.

**Equip remote**
- `Remotes.Listen("EquipSigil", handler, 4)` in GoldSystem, next to `BuyHeroUpgrade` (GoldSystem.lua:432).
- Validate: string id or nil, slot number 1 or 2, slot unlocked, Sigil owned, not already in the other slot, lobby only (not mid-run). Then send `ProfileSync`.

**StatSheet**
- Add `Sigils = {id → true}` to `StatSheet.Input` (src/shared/StatSheet.lua) and run `addAll` on each `Bonus` after Meta, before Curse.
- Fill `rp.Sigils` where `rp.Meta` is built (RunManager.lua around line 802). Set it to empty for Daily runs.
- Read Specials in WeaponSystem (start weapon), `GoldSystem.PriceMult` (chest price) and ItemSystem (regen, LoneWolf).

**UI**
- New `src/client/MenuSigils.lua`, with a "Sigils" entry in `SCREEN_ORDER` and a card in LobbyScreen.lua next to `CardUpgrades` (around line 781).
- Small icons on the nameplate. Art must come from the owner or the icon pipeline (`art/icons`, `upload_icons`).
- No placeholder may be presented as working.

**Tests**
- New scenes in tools/preview/scenes: `sigils-regression` (migration 7→8, cleaning invalid saves, equip validation, DEV/Daily rules, duplicate→gold, StatSheet math) and `sigils` (screen layout on phone and phone-portrait, plus check_layout).
- Extend `data-regression` and `mastery-regression`.

**Effort**
About 1.5 to 2 sessions: data/save 0.3, server 0.5, StatSheet/Specials 0.3, UI 0.5, tests 0.4. Start only after Hero Mastery lands, because it touches the same files (DataService, GoldSystem, StatSheet, MenuCharacters, LobbyScreen).

Critical files:
- /home/user/swarm/src/server/Modules/DataService.lua
- /home/user/swarm/src/shared/StatSheet.lua
- /home/user/swarm/src/server/Modules/RunManager.lua
- /home/user/swarm/src/server/Modules/EnemySpawner.lua
- /home/user/swarm/src/client/LobbyScreen.lua