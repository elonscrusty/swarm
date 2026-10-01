# SWARM testing checklist

Tick each box in Studio. "Output" means the Output window (View → Output); there should be no red errors.

## 0. Setup
- [ ] `rojo serve` connected, Play starts with no red errors in Output.
- [ ] Output shows `[SWARM] server ready`. If it also says "DataStores OFF", enable API access (README §1) for the save tests.

## 1. Solo run (Play, 1 player)
- [ ] You spawn in the lobby as a grey Knight with a helmet; the camera looks down from the south.
- [ ] WASD / arrows move you; there is no jump.
- [ ] Boards on the north wall read CHARACTERS / START RUN / UPGRADES; the right lectern shows your stats.
- [ ] Walking to the green pad shows "Start Run"; pressing it starts a 10 s countdown banner.
- [ ] At 0 you appear in the Backyard (grass, fence, trees, rocks); timer counts up from 0:00.
- [ ] The Whip slashes left/right automatically; slimes and bats come from off-screen.
- [ ] Enemies go around trees and rocks instead of through them; ghosts drift through.
- [ ] Killed enemies flash white, poof, and drop blue gems; gems bob and fly to you; the XP bar fills.
- [ ] Level up: the game pauses YOU (enemies keep moving), 3 cards appear; picking one closes the screen and the HUD icon row updates with level pips.
- [ ] Leave the level-up screen alone: a card is auto-picked after 25 s.
- [ ] Every 30 s a "swarm approaches" toast and a ring of enemies.
- [ ] Pause button (II): menu opens, "The run is paused", enemies freeze; sliders change volume; Resume continues.
- [ ] Take damage: red flash, HP bar over your head drops. Chicken heals, Magnet pulls every gem, Bomb clears the screen.
- [ ] An elite (big, shiny) drops a chest; touching it plays the chest animation and lists a weapon level + gold.
- [ ] Get a weapon to level 8 + its passive: the next level-up offers a gold EVOLUTION card (or a chest evolves it).
- [ ] Quick boss test: set `Config.Run.BossTime = 60` temporarily. Boss appears with a red HP bar; it charges (red floor warning), fires rings of red orbs, summons skeletons. Killing it shows VICTORY with stats; you return to the lobby after 25 s or "Return to lobby".
- [ ] Die (stand still at minute 5+): DEFEATED screen with time/kills/gold/level.
- [ ] After a win, the arena lectern can switch to Mall (neon storefronts, tiled floor, night lighting).

## 2. Four-player run (Test tab → Clients and Servers → 4 players, Start)
- [ ] Player 1 presses Start; others see "is starting a run" and a JOIN button; all 4 join.
- [ ] A 5th player (if testing 5) gets "This run is full".
- [ ] Everyone spawns in a circle; more enemies than solo.
- [ ] A gem picked up by one player gives XP to all living players.
- [ ] Each player levels separately; one player's level-up screen doesn't stop the others.
- [ ] Pause in a group: menu says the swarm keeps coming; the run is NOT frozen.
- [ ] A player who dies becomes see-through, the camera follows a teammate; when everyone is dead → DEFEATED for all.
- [ ] A player who leaves mid-run doesn't break the run for the others.
- [ ] A player who joins the server mid-run waits in the lobby with "A run is in progress".

## 3. Mobile controls (Studio device emulator: Test → Device, pick a phone; try portrait and landscape)
- [ ] Touch anywhere: a stick appears under the thumb and the character moves that way; release stops.
- [ ] No jump button and no other buttons are needed in a run.
- [ ] HUD fits inside the safe area (no text under the notch); level-up cards stack vertically in portrait.
- [ ] Lobby panels (Characters / Upgrades buttons bottom-right) fit the screen and scroll.
- [ ] ProximityPrompts can be tapped.
- [ ] Performance: with 200 enemies (`Config.Enemies.MaxLive`), View → Stats → FPS stays near 60 on the emulator; on a real phone check with the Developer Console (F9 → Memory / Network).

## 4. Purchase flow (Studio test purchases; needs real IDs in Config.Monetization)
- [ ] Upgrades panel → Robux items show "Buy (R$)"; with ID 0 they show "Not set up yet".
- [ ] Buy 500 Gold: Studio test dialog → gold goes up by 500 and a thank-you toast appears.
- [ ] Buy it again: a second +500 (each purchase is a new PurchaseId).
- [ ] Idempotency: in the command bar, `game.MarketplaceService.ProcessReceipt({PlayerId = <your id>, ProductId = <Gold500 id>, PurchaseId = "test1", CurrencySpent = 0, PlaceIdWherePurchased = 0})` twice → gold rises only once.
- [ ] VIP pass: buy → crown appears in the lobby, [VIP] tag in chat, next run's level-up shows 1 extra reroll.
- [ ] Starter Pack: Gold Trim skin becomes equippable on every character; run gold is 25% higher.
- [ ] Skin pass: buy → skin button changes from "(R$)" to equippable; equip → character rebuilds with new colours/hat.
- [ ] Revive product: die in a run → "YOU FELL!" offer with a timer. Buy → you come back at 50% HP with a shockwave. Next death in the same run → no offer.
- [ ] Decline / let the timer run out → you stay dead (spectate).

## 5. Data save / load (API access ON)
- [ ] Earn gold in a run, buy a meta upgrade, buy Mage (500 gold), equip a skin. Stop.
- [ ] Play again: gold, upgrade levels, Mage owned and selected, skin, settings sliders and stats are back.
- [ ] Gold collected before dying in a run is kept.
- [ ] Session lock: run two Studio sessions with the same account (or Team Test) → the second one waits and then gets the "data is still in use" kick unless the first one left.
- [ ] Shutdown: start a run, stop the server mid-run → next session keeps the run's gold.
- [ ] Note: if Studio crashes, the lock frees itself after `Config.Data.LockStaleSeconds` (200 s).
