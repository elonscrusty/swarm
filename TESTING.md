# SWARM testing checklist

Tick each box in Studio. "Output" means the Output window (View → Output); there should be no red errors.

## 0. Setup
- [ ] `rojo serve` connected, Play starts with no red errors in Output.
- [ ] Output shows `[SWARM] server ready`. If it also says "DataStores OFF", enable API access (README §1) for the save tests.
- [ ] The lobby menu fills the screen: gold / best time / wins pills at the top, your character turning in the middle, SOLO / DUO / TRIO on the right (landscape) or below the character (portrait).
- [ ] Behind the menu the 3D lobby shows from a fixed scenic camera (the `MenuCamera` part if the lobby has one); it sways very slightly.
- [ ] Background dots drift upward; the mode buttons breathe, glow and get a light sweep now and then; buttons shrink a little when pressed.
- [ ] DEV button (bottom left) is visible in Studio. In a published game it shows only for the game's creator.

## 0b. Lobby screens
- [ ] Tap CHARACTERS (or your character): the screen slides in from the right and the cards pop in one after another.
- [ ] Each card: turning 3D model, name, role (gold), description, "Starts with" + weapon icon, bonus (green), Buy / Select / SELECTED button, skin swatches. Your selected character has a gold border and a SELECTED ribbon.
- [ ] Buy Mage with too little gold: toast "Not enough gold"; with enough gold the card turns to SELECTED and the home screen's character changes.
- [ ] Tap an owned skin swatch: it gets a gold border, the card's model and the home character change colour. Locked skins show "R$" (gamepass set) or "soon".
- [ ] < BACK slides back to home. UPGRADES (or the upgrades summary) opens the shop with staggered cells; buying a level updates the summary bar on home.
- [ ] Gold pill counts up/down smoothly after a purchase.
- [ ] ARENA cycles to Ruins only after a win (otherwise a toast says to win a run first); the button shows the arena name.
- [ ] SETTINGS opens the volume menu ("Close" button); sliders work and are saved.
- [ ] No walking in the lobby: WASD / touch do nothing, no thumbstick appears.

## 1. Solo run (Play, 1 player)
- [ ] The lobby menu shows a grey Knight with a helmet turning in the middle.
- [ ] Tap SOLO: the run starts at once (no countdown); the timer counts up from 0:00.
- [ ] In the run WASD / arrows / the thumbstick move you; there is no jump.
- [ ] The Whip swings a sword arc in front of you (and behind at level 2+) automatically; slimes and bats come from off-screen.
- [ ] Enemies go around trees and rocks instead of through them; ghosts drift through.
- [ ] Killed enemies flash white, poof, and drop blue gems; gems bob and fly to you; the XP bar fills.
- [ ] Level up: the whole run pauses, 3 cards appear, each with an icon (placeholder letters until IconData has pictures); picking one closes the screen.
- [ ] Upgrade bar: weapons (top row) and passives (bottom row) sit at the bottom centre. A new item pops in; levelling it shows an "x2", "x3"... badge in its corner; an evolved weapon gets a gold border and its evolution's icon.
- [ ] Touching on top of the upgrade bar still moves you (the tiles don't block the thumbstick).
- [ ] DEV button in a run: "+5 levels" gives 5 level-ups in a row; "Skip to 14:30 (boss)" jumps the timer, the boss warning follows and the boss comes at 15:00.
- [ ] Leave the level-up screen alone: a card is auto-picked after 25 s.
- [ ] Every 30 s a "swarm approaches" toast and a ring of enemies.
- [ ] Pause button (II): menu opens, "The run is paused", enemies freeze; sliders change volume; Resume continues.
- [ ] Take damage: red flash, HP bar over your head drops. Chicken heals, Magnet pulls every gem, Bomb clears the screen.
- [ ] An elite (big, shiny) drops a chest; touching it plays the chest animation and lists a weapon level + gold.
- [ ] Get a weapon to level 8 + its passive: the next level-up offers a gold EVOLUTION card (or a chest evolves it).
- [ ] Quick boss test: DEV → "Skip to 14:30 (boss)" (or set `Config.Run.BossTime = 60` temporarily). Boss appears with a red HP bar; it charges (red floor warning), fires rings of red orbs, summons skeletons. Killing it shows VICTORY with stats; you return to the lobby after 25 s or "Return to lobby".
- [ ] Die (stand still at minute 5+): DEFEATED screen with time/kills/gold/level.
- [ ] After the results screen you are back on the lobby menu (home screen), no walking.
- [ ] After a win, the ARENA button can switch to the next arena.

## 1a. Weapon animations (use the lobby/run, level each weapon; Studio cheats or `Config` boosts help)
- [ ] Whip: a glowing blade pulls back, then sweeps a ~150° arc in front of you with a white crescent trail; it flashes white mid-sweep and fades. The knight's right arm swings with it. The second (back) slash makes the hero spin once. Enemies inside the arc flash; enemies outside it don't.
- [ ] Whip levels: trail turns pale gold (lv 4-6), gold and wider (lv 7-8). Bloodwhip: thicker crimson blade, red trail, bigger tip spark.
- [ ] Magic Orb: purple orb wobbles and rolls with a purple ribbon trail; a small purple puff where it hits. The Mage's arm points forward when orbs launch. Twin Orbs: pink, wider trail.
- [ ] Throwing Knives: knives tumble end over end with a thin white trail and a white puff on hit. The hero's arm does a throwing motion. Thousand Edge: golden knives fly straight, rolling, with gold trails.
- [ ] Garlic: faint filled disc, rim ring, a wave that pulses outward about once a second, 3 motes circling. Soul Eater: purple, waves pulse inward, 6 motes spiral into you.
- [ ] Holy Water: bottle tumbles along its arc with a blue drip trail, shatters (shards + splash) where it lands, and the pool ripples until it fades. Hellfire: orange, faster ripples.
- [ ] Lightning: a jagged bolt from the sky, a flash and a ring on the ground. Thunder Loop: icy-white bolts with jagged chain arcs between enemies.
- [ ] Axe: axe tumbles head over heels along its arc with a grey trail; puff on the last hit. Death Spiral: red axes spin flat like buzz saws around you, with red trails.
- [ ] Boomerang: spins flat, tilted into its flight, with a whirl trail, and comes back to you (no puff on return). Infinite Return: cyan, wider trail.
- [ ] Boss orbs: spinning stinger with a red trail and a red puff when it hits or expires.
- [ ] Performance: with 4 weapons maxed and 200 enemies, FPS stays near the earlier numbers (trails are capped at 64; puffs at 10 per frame).

## 1b. Duo and Trio (Test tab → 2 or 3 players)
- [ ] Player 1 taps DUO: the mode buttons turn into a panel "DUO run starts in 10" with "Joined 1/2: <name>"; player 2 sees the same panel with a JOIN button.
- [ ] Player 2 taps JOIN: both see "Joined 2/2" and the run starts at once (full).
- [ ] TRIO with 3 players: after player 2 joins, player 1 (the starter) gets START NOW; tapping it starts the run with 2. Without anyone else joined, START NOW does not show.
- [ ] A player who joins too late (run full) gets "This run is full".
- [ ] Let player 1 fall: toast says to stand next to them; a teammate stands close for 3 s → player 1 revives at 40% HP (works in Duo and Trio).
- [ ] All fall → DEFEATED; the results line says "Forest (Duo)" / "(Trio)".
- [ ] DEV → "Start solo now" during someone's countdown starts the run immediately with the players already in.

## 1c. Uploaded 3D models (after tools/upload_meshes.py)
- [ ] Output has no "[MeshService] could not load" warnings.
- [ ] Bugs, heroes, crystals, weapons, chest and pickups use the new models; legs/wings/claws move.
- [ ] No mesh lies on its side or floats/sinks: trees, mushrooms, rocks, bushes, pillars, crystals, torches and banners stand upright on the ground (Output has no "imported rotated" warnings; if it does, heroes/bugs need the same fix).
- [ ] Forest arena: a dirt clearing with a stone ring at the spawn (nothing solid within ~40 studs), 4 dirt paths leading out, tree groves with red mushrooms in their shade, two fairy rings, a reed pond, rock outcrops, fallen logs, flowers, 3 purple alien nests with egg pods. The edge is a broken wooden fence with bushes and a dense tree line outside; the south (camera) side has only low trees, so the hero is never hidden there.
- [ ] Forest collision: you can't walk through trunks, big mushrooms, big rocks, logs, hive mounds or the pond; small mushrooms, bushes and flowers are walk-through decoration.
- [ ] Ruins arena (after a win): mosaic plaza at the spawn, 4 flagstone avenues with colonnades (standing, broken and toppled pillars), 8 flickering torches at the plaza, a ruined building in each quadrant, 5 glowing purple crystal fields, autumn trees, rubble; a broken crenellated wall with corner towers (low on the south side), dark pines outside. Golden-dusk light with purple haze.
- [ ] Ruins collision: pillars, stumps, toppled pillars, building walls, crystal centres, torches and corner towers block you and the bugs; enemies path around them.
- [ ] Castle lobby (behind the menu): the shot shows the courtyard flagstones and the gold/blue emblem in the middle, the keep behind with a warm-lit arched gate and raised portcullis, steps, red wall banners, braziers with fire, two roofed towers with flags, blue pole banners, torches and planters on the sides, pine forest and hazy mountains in the background, drifting dust motes / fireflies. Torch lights flicker.
- [ ] Lighting differs per place: warm golden hour (lobby), bright day with light haze (Forest), dusk with purple haze and stronger glow (Ruins).
- [ ] Performance: in each arena View → Stats shows a steady FPS on the phone emulator (each arena is about 500 Parts + 300-450 MeshParts, all anchored).

## 2. Four-player run (Test tab → Clients and Servers → 4 players, Start)
- [ ] Player 1 taps TRIO; others see "is starting a TRIO run" and a JOIN button; 3 join and it starts; the 4th player sees "A run is in progress (m:ss)".
- [ ] A 4th player tapping JOIN too late gets "This run is full".
- [ ] Everyone spawns in a circle; more enemies than solo.
- [ ] A gem picked up by one player gives XP to all living players.
- [ ] Each player levels separately; one player's level-up screen doesn't stop the others.
- [ ] Pause in a group: menu says the swarm keeps coming; the run is NOT frozen.
- [ ] A player who dies becomes see-through, the camera follows a teammate; when everyone is dead → DEFEATED for all.
- [ ] A player who leaves mid-run doesn't break the run for the others.
- [ ] A player who joins the server mid-run sees the lobby menu with "A run is in progress (m:ss)" in place of the mode buttons.

## 3. Mobile controls (Studio device emulator: Test → Device, pick a phone; try portrait and landscape)
- [ ] Touch anywhere: a stick appears under the thumb and the character moves that way; release stops.
- [ ] No jump button and no other buttons are needed in a run.
- [ ] HUD fits inside the safe area (no text under the notch); level-up cards stack vertically in portrait with the icon next to the name.
- [ ] The upgrade bar sits above the bottom safe area and doesn't cover the thumbstick area's touches.
- [ ] Lobby menu in portrait: character on top, upgrades summary, SOLO / DUO / TRIO in a row, CHARACTERS / UPGRADES / ARENA in a row; nothing overlaps. Landscape: buttons left and right, character in the middle.
- [ ] Characters screen: 2 cards per row in portrait, 4 in landscape; it scrolls. Every button is easy to tap (at least a finger wide).
- [ ] Turn the phone while on a lobby screen: everything relayouts.
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
