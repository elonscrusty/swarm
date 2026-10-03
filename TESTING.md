## 2026-10-02 progression and polish verification

The new progression supersedes older eight-rank and automatic-revive expectations below. Offline checks pass; Studio, live teleports, real purchases, music audibility and phone FPS still require device testing.

On Windows, run `python -X utf8 tools/check.py --quick --rojo <rojo.exe>` with the toolchain in `../toolchain` (or pass `--tools`). Run `python -X utf8 tools/run_regressions.py` for the real-module offline regression suite. The original shell checker remains available on Linux.

- [ ] Play Standard through five stages. Aim for 20–30 minutes during normal exploration; portals remain available immediately, so skilled rushing can finish sooner.
- [ ] All seventeen weapons reach rank twelve. Behavior milestones work; evolution needs the matching passive at rank three. Six weapons remain the limit.
- [ ] Every filled XP bar opens the upgrade cards at once (no combat-time delay between panels; a panel holds up to four earned choices, XP is conserved). The pace comes from the XP costs only: level 1 costs 42, level 20 costs 270, level 50 costs 450 (`Config.XP`). Offline `levelrate-sim` (real server, hero walking in the swarm): solo ~3.0 level-ups per minute on the old 20 + 8/level curve, ~2 per minute now; Duo per player was ~2x solo before `Config.XP.CoopShare`, about solo pace after it (numbers in the Claude handoff notes). Owner playtest decides the final numbers.
- [ ] Max weapons alone do not stop upgrades. Finish owned passives and available evolutions: queued and later XP become automatic coins with no chooser. Higher tiers and uninterrupted survival increase these coins; knockdown resets the streak.
- [ ] Standard completion unlocks Veteran; Veteran completion unlocks Nightmare. Daily, Endless and DEV runs do not unlock tiers. Older recorded Standard winners retain Veteran access after migration.
- [ ] Optional locations vary between guarded elites, caravan defense, rune sequences and free treasure. Walking near an altar does not activate it. Markers are visible from the start, including every naturally spawned loot location. Rewards and secrets end with the run.
- [ ] Each boss gains warned attack combinations below forty percent HP. Pause freezes combat clocks, including projectile lifetime, terrain hazards, slows and burns. Late-stage enemies and hazards remain bounded.
- [ ] Hold REVIVE near a fallen teammate for two seconds. Movement, release, lost focus or leaving range resets progress. A held movement touch cannot select a newly opened upgrade, reroll or skip.
- [ ] Ordinary rewards animate briefly while combat continues; legendary rewards, evolutions and encounter finales use the dramatic presentation. Quick reward releases do not close a newer rare reward.
- [ ] Old savings and purchased coins remain separate from the current run. Defeat/abandon/disconnect retain 25% of unspent run earnings plus 15 percentage points per cleared stage, capped at 85%. Safe extraction retains all run earnings. Repeated end events do not pay twice.
- [ ] Permanent upgrade tracks show the extended caps and preserve existing levels. Results show retained/lost earnings, defeat cause, progress and quick replay. Victories do not show a death cause.
- [ ] Test phone landscape/portrait: all controls fit, icons animate, Reduced Effects restores stable poses, low health has a heartbeat warning, and automatic decoration reduction preserves telegraphs and markers.
- [ ] Test save failure and receipt retry only in a safe test environment: no duplicate grant, no acknowledgement until saved, no receipt mutation after profile handoff. Rejoin and confirm saved tier, balances and ownership.

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
- [ ] ARENA cycles to Ruins only after reaching stage 2 in a run (otherwise a toast says so and the card reads "Ruins: reach stage 2 to unlock"); the button shows the arena name. Later unlocks: Swamp at stage 3, Snow 4, Desert 5, Lava 6 (the card names the next locked arena; once all are unlocked it shows the picked arena's hint, e.g. "Mud pools slow you").
- [ ] SETTINGS opens the volume menu ("Close" button); sliders work and are saved.
- [ ] No walking in the lobby: WASD / touch do nothing, no thumbstick appears.

## 0c. Characters, achievements, upgrades (new)
- [ ] CHARACTERS lists 8 heroes (landscape PC: one column; phone landscape: two columns of names; portrait: two rows of four tabs, no "..."); the Alchemist / Engineer / Necromancer read "Locked · Deep Delver / Field Engineer / Reaper" with their progress (e.g. "2/4", "1/3", "318/500").
- [ ] The Ranger reads "Locked · Queen Slayer". Its details show Starts with Longbow, Trait Steady Aim, EFFECT / STRENGTH / TRADEOFF lines, "UNLOCK Queen Slayer: Defeat the Scorpion Queen. 0/1" and a disabled LOCKED · QUEEN SLAYER button (no gold purchase possible; the home nameplate shows LOCKED).
- [ ] Every other hero shows its trait, strength and tradeoff; Rogue / Priest still unlock for gold.
- [ ] Portrait: the eight hero tabs (two rows) fit without "...".
- [ ] STATS has STATS / ACHIEVEMENTS tabs; the Achievements tile shows n / (the number of achievements). The list shows one row each with reward lines and progress bars (time ones as m:ss).
- [ ] Kill the Queen (DEV: spawn portal boss): toast "Achievement: Queen Slayer · Unlocks the Ranger · 150 gold"; the results screen lists it; back in the lobby the Ranger is owned and selectable.
- [ ] Clearing a stage as the Knight unlocks Knight's Oath; opening a Golden Chest unlocks Golden Touch; a Duo partner revive counts toward Lifesaver (3).
- [ ] Earned titles / name colours appear under WEAR TITLE / NAME COLOUR; picking one changes the name line above the hero nameplate on home.
- [ ] Old save (schema 3) loads with gold, characters and skins intact and empty achievements (Output: no migration errors).
- [ ] UPGRADES: rows show LV n/max, NOW / NEXT effect, BUY price (gold when affordable, "Need N more gold" when not) or MAXED. Double-tap BUY quickly: only ONE level is bought; the button reads BUYING... until gold updates; a toast confirms the new level.

## 1. Solo run (Play, 1 player)
- [ ] The lobby menu shows a grey Knight with a helmet turning in the middle.
- [ ] Tap SOLO: the run starts at once (no countdown); the timer counts up from 0:00, the pill under it says "STAGE 1 · Find the portal" and a "STAGE 1" banner shows.
- [ ] In the run WASD / arrows / the thumbstick move you; there is no jump.
- [ ] The Whip swings a sword arc in front of you (and behind at level 2+) automatically; slimes and bats come from off-screen.
- [ ] Enemies go around trees and rocks instead of through them; ghosts drift through.
- [ ] Killed enemies flash white, poof, and drop blue gems; gems bob and fly to you; the XP bar fills.
- [ ] Level up: the whole run pauses, 3 cards appear, each with an icon (placeholder letters until IconData has pictures); picking one closes the screen.
- [ ] Upgrade bar: weapons (top row) and passives (bottom row) sit at the bottom centre. A new item pops in; levelling it shows an "x2", "x3"... badge in its corner; an evolved weapon gets a gold border and its evolution's icon.
- [ ] Touching on top of the upgrade bar still moves you (the tiles don't block the thumbstick).
- [ ] DEV button in a run: "+5 levels" gives 5 level-ups in a row; "Spawn portal boss" summons the Scorpion Queen at this stage's portal; "Teleport to portal" puts you next to the portal's rune circle.
- [ ] Leave the level-up screen alone: a card is auto-picked after 25 s.
- [ ] Every 30 s (while exploring, not during the boss / surge) a "swarm approaches" toast and a ring of enemies.
- [ ] Pause button (II): menu opens, "The run is paused", enemies freeze; sliders change volume; Resume continues.
- [ ] Take damage: red flash, HP bar over your head drops. Chicken heals, Magnet pulls every gem, Bomb clears the screen.
- [ ] An elite (big, shiny) drops a chest; touching it plays the chest animation and lists a weapon level + gold.
- [ ] Get a weapon to level 8 + its passive: the next level-up offers a gold EVOLUTION card (or a chest evolves it).
- [ ] Quick boss test: DEV → "Spawn portal boss". The Queen rises out of the ground behind the portal while the boss bar fills with her name, then runs her attack cycle (full checklist in section 1f). Killing her plays a short collapse, then the surge starts (section 1d).
- [ ] The run no longer ends at 15:00: past 15:00 the timer keeps counting and nothing special happens.
- [ ] Die (stand still at minute 5+): DEFEATED screen with "Fell on stage N", stages, time/kills/gold/level/damage.
- [ ] After the results screen you are back on the lobby menu (home screen), no walking.
- [ ] After reaching stage 2, the ARENA button can switch to the next arena.

## 1g. Level-up cards, perks and the Ranger (solo)
- [ ] Every card shows the rarity band, the rank line (NEW / LV 3 → 4 / 8 / EVOLUTION) and what changes with real numbers ("Damage 10 → 15"; passives "Max HP 144 → 168").
- [ ] A weapon at level 6+ shows "Evolves at Lv 8 with <passive>" (gold when you own it).
- [ ] Maxed weapons / passives never show up; Ammo / Candle / Fletching don't show up with a Whip + Garlic only build; Duplicator has 3 levels, each +1.
- [ ] REROLL shows "n left · 3 new cards" and SKIP "+10 GOLD · n left"; without the permanent upgrades they are greyed out with "Buy rerolls / skips in Upgrades".
- [ ] Perks: Whip L6 every 3rd attack cuts both ways; Orb L5 kills split into 2 small orbs; Knives L4 bounce once; Garlic L4 visibly slows enemies in the ring (not the Queen); Longbow L6 every 3rd shot fires 3+ arrows fanned out.
- [ ] Ranger: arrows fly where you move; standing still they aim at the nearest enemy. After 0.8 s still (server-checked position, < 0.3 studs drift) the chip over the ability bar turns gold-green "STEADY AIM +30% DAMAGE" (+30% Longbow, +10% other weapons); moving turns it back to "STAND STILL TO AIM".
- [ ] Longbow + Fletching at Lv 8 → Windpiercer (green wind arrows, pierce everything, 4-arrow volley). Arrows use the Shot_Arrow mesh once uploaded.

## 1h. New weapons and heroes (Alchemist, Engineer, Necromancer)
Tip: DEV → "All new weapons Lv 8" gives all eight at level 8 (past the slot limit), "Evolve all weapons" evolves everything. Offline: `bash tools/preview/render.sh weapons-sim --studio --devices pc --set character=Necromancer` (logic smoke test), `render.sh arena --set weapons=new [--set evolved=on]` (the effects), `render.sh levelup --set cards=Spear+ChainHook:4+evo:Turret`.
- [ ] Level-up cards: the new weapons show with their icon and real numbers ("Damage 14", "Spears 1", "Heal 1 → 1.5", "Turrets 1 → 2", "Rebuild 7.00s → 6.50s", "Flame every 0.45s"); perks show as NEW lines at their level (Spear 5, Crossbow 4, Frost Nova 5, Fire Trail 5, Totem 5, Hook 4, Turret 5, Soul Bolt 4); "Evolves at Lv 8 with <passive>" from level 6. Precision / Renewal cards show "Crit chance 5% → 10%" / "HP regen 0.6 HP/s". New-weapon cards don't crowd out upgrades (about as often as before).
- [ ] Spear: thrusts out and back where you face (the arm moves), hits a line of enemies (3 at Lv 1), Impale at Lv 5. Dragon Lance: three crimson lances with a small gold burst at their tips.
- [ ] Crossbow: fast bolts at the nearest enemies; from Lv 4 a bolt bounces once; Heartseeker crimson bolts bounce three times.
- [ ] Frost Nova: every ~3 s a pale ice ring and spikes burst around you; enemies inside take damage and walk slower (not the Queen); Lv 5 kills throw ice shards. Absolute Zero: bigger burst, almost frozen enemies.
- [ ] Fire Trail: walking leaves warm amber patches with a gold rim and a flame; enemies chasing you through them take damage; standing still leaves nothing new; **the flames never hurt any hero** (walk through them, also in Duo). Lv 5: every 3rd patch is wider. Phoenix Stride: golden flames, enemies keep burning a moment after leaving them.
- [ ] Healing Totem: a totem rises out of the ground behind you, pulses a green ring every second, hurts enemies in the ring and heals you and teammates standing in it (two totems never heal twice as fast); at most 1 (Lv 5+: 2, Lifebloom: 3) — the oldest is rebuilt next to you.
- [ ] Chain Hook: a hook flies at the furthest enemy in front of you with a steel chain back to your hand, drags it in and hurts everything on the chain's line; the Queen barely moves. Lv 4: the chained enemies are dragged too. Reaper's Chain: crimson hooks, three at once.
- [ ] Turret: a turret rises next to you and its head turns to shoot gold bolts at the nearest enemy (range ~30); max 1 (Lv 5+: 2); when you walk away the oldest is rebuilt next to you; Lv 5 every 4th shot bursts. Bastion: gilded turrets, much faster fire.
- [ ] Soul Bolt: skull souls curl out and home in; a soul whose target died seeks another; Lv 4 a killing soul flies on. Soul Storm: crimson souls passing through three enemies.
- [ ] Alchemist (Deep Delver: reach stage 4): starts with the Fire Trail; area / fire weapons do 20% more (compare Frost Nova numbers with damage numbers on).
- [ ] Engineer (Field Engineer: 3 Guarded Altars / Bargain stages in total): starts with the Turret; turrets and totems last 30% longer.
- [ ] Necromancer (Reaper: 500 kills in one run): starts with the Soul Bolt; now and then a small soul rises from a kill (green sparkle) and hunts another enemy.
- [ ] Unlocking any of them: toast "Achievement: … · Unlocks the <hero> · 150 gold"; the hero is owned and selectable in the lobby; no gold purchase is possible before.
- [ ] Travel to the next stage / end of run: every turret, totem, flame patch, hook and soul is gone.

## 1d. Stages and portal (solo first, then Duo)
Tip: lower `Config.Stages.PortalLockSeconds` / `HintAfterSeconds` and use the DEV buttons to go faster.
- [ ] Stage 1 is the lobby's arena; a stone ring PORTAL stands somewhere at least ~120 studs from the spawn, never inside a tree, wall, pond or landmark, with a dashed rune circle on the floor and a soft slate-blue light beam rising from it. Start several runs: the spot changes.
- [ ] The early game feels like before (same swarm sizes and toughness in stage 1).
- [ ] (Only with `Config.Stages.PortalLockSeconds` > 0; the owner chose 0) The portal is dormant: the pill says "The portal is dormant: m:ss", standing in the circle shows "DORMANT m:ss" and does not charge.
- [ ] The portal reveal, ~4 s into every stage (after the "STAGE N" banner; `Config.Stages.RevealDelaySeconds`): the banner "THE PORTAL HAS APPEARED · Follow the arrow and stand in its circle to open it" slams in with a low chime, a tall light pillar with a glowing cap rises over the portal with a floor shockwave, two rings keep pulsing outward from the rune circle, the minimap pings the portal marker with three expanding rings (the marker sits pinned to the map's edge while the portal is off the map) and the arrow badge with the distance ("120 m") appears at the screen edge at once. Same again on every later stage. Pillar / rings are arcane blue while exploring, gold while charging and open, crimson during the boss and surge.
- [ ] Settings: Reduced effects = pillar and one steady ring, no pulsing, no shockwave, no minimap ping, plain banner; Reduce flashes = no shockwave / pillar rise; a colorblind palette recolours pillar, rings, marker and ping.
- [ ] The arrow stays clear of the timer, plates and the ability bar; when the portal is on screen it becomes a small marker floating over it. Each player's arrow points from their own position.
- [ ] Stand inside the rune circle: a ring of 24 gold segments over the portal fills in ~2 s ("Opening 60%"), the stage pill says "Opening the portal 60%", the portal and its circle warm to gold. Step out early: the charge drains slowly. It works by just standing (phone: no button needed).
- [ ] Charged: the Scorpion Queen climbs out behind the portal, the portal turns crimson, "Defeat the Queen", boss bar and boss music; regular enemies keep coming, but only about half the normal crowd (15-60); no mini-waves.
- [ ] Queen dies: every living player gets the boss gold; "QUEEN DEFEATED! SURVIVE THE SURGE!", the pill shows "Survive the surge · 20s" and a burst of enemies pours out of the portal over ~4 s (40 on stage 1, 15 more each stage).
- [ ] The surge ends after 20 s or when most of it is dead: the leftovers burn up, every gem flies to you, the portal glows gold, "THE PORTAL IS OPEN".
- [ ] Travel right away (gems still flying, a chest on the floor): the gems' XP still arrives and the chest opens for you; nothing is lost.
- [ ] The choice panel: "STAGE 1 CLEARED", stages / time / kills / gold, NEXT STAGE (gold, "Stage 2 · Ruins") and RETURN TO LOBBY ("+175 gold · win from stage 3" before 3 cleared stages, "· a win" from 3), "Next stage in 15s unless you return" with a bar. Phone landscape and portrait: buttons stack when narrow, nothing is cut off.
- [ ] Leave it alone: after 15 s you travel on. Open the pause menu meanwhile (solo): the countdown stops ("paused") and resumes when you close it. A level-up during the open portal also stops it.
- [ ] NEXT STAGE: the screen fades to slate with "STAGE 2 · <BIOME>", then comes back on the next arena (stage 1 is the lobby's arena, then a shuffled tour of Ruins / Swamp / Snow / Desert / Lava, never the same arena twice in a row; the NEXT STAGE button names the same biome the fade shows): you stand at the spawn with the same level, XP, weapons, passives and gold, HP topped up to at least 60%; no enemies, gems or projectiles from the old stage; the timer kept counting from where it was; "STAGE 2" banner and a new portal somewhere else.
- [ ] Stage 2 enemies are a bit tougher and more numerous; the stage 2 Queen has more HP than stage 1's.
- [ ] RETURN TO LOBBY after 1-2 stages: back on the lobby menu at once with an ESCAPED panel ("2 stages cleared · Ruins", Stages tile, CONTINUE, closes by itself); gold includes the win bonus + stage bonus; Wins does NOT go up. After 3+ stages the panel says VICTORY! and STATS shows Wins +1. STATS shows "Best stage"; reaching stage 2 unlocks Ruins in the lobby ("Unlocked: Ruins arena!").
- [ ] Die on stage 2+: DEFEATED with "Fell on stage 2" and the stages cleared; Best stage is updated.
- [ ] Duo: both get the panel; one taps NEXT STAGE → their button turns to READY and the note says "Waiting for your team (1/2 ready)"; the other taps RETURN TO LOBBY → that player gets their VICTORY panel in the lobby, the first travels on alone. If both return, the run ends and the lobby is free for a new run.
- [ ] Duo: a teammate who is down when the Queen dies is revived on the next stage (50% HP). If the only living player returns while the teammate is down (also while the teammate is still on the revive offer and then declines), the run ends and both get the same portal result (ESCAPED, or VICTORY from 3 stages), never DEFEATED.
- [ ] Duo: a player who leaves the game mid-boss or while the portal is open doesn't block the other (the choice completes without them).
- [ ] Everyone falls during the surge: DEFEATED for all, as before.
- [ ] Level-up during travel: the cards stay up on the next stage and the run stays paused until picked.
- [ ] While a run is going, the lobby (for players who returned or joined late) shows "Run in progress · Stage N · Time m:ss".
- [ ] HUD status: in SOLO a level-up never says "a teammate is choosing"; in Duo/Trio the others see "Paused: <Name> is choosing an upgrade" and the chooser sees only the cards.

## 1e. Loot: chests, shrines, guarded altar, items (solo first, then Duo)
Tip: DEV → "+300 gold" and "+3 random items" speed this up.
- [ ] Every stage has 10-14 small chests, 2-3 large, 1 golden, 1-2 gold-sigil Shrines of Chance, 1 crimson Bargain Shrine and 1 Guarded Altar (stone dais with a chest on it). None stand in the spawn clearing, inside trees / walls / ponds or on the portal; travel to stage 2: all new spots, nothing left from stage 1.
- [ ] Walk next to a chest: a prompt appears beside it with the name, what it gives, the price (coin) and HOLD E. Too little gold: the price is red, "Need N more gold", holding does nothing.
- [ ] Hold E: the ring around the icon fills (~1 s); the gold counter drops by the price, the lid swings open, an item popup appears at the left (icon, name, rarity colour, what it does, "Large Chest"), the item joins the strip at the top left (x2 when stacked). Release early: nothing is spent. Walk away mid-hold: cancelled.
- [ ] Phone: the prompt has a HOLD button: press and hold it (the thumbstick does not start); release stops it. Gamepad: hold X.
- [ ] Prices grow per stage (stage 1: 25 / 60 / 150; stage 2: 57 / 138 / 345). With DoubleGold the shown price doubles (and so does income).
- [ ] Shrine of Chance: the prompt says "+ 50% chance of an item (2 left)" and "- Each try costs 20% more gold"; each try takes gold, sometimes an item, otherwise "nothing this time"; price goes up; after 2 items / 6 tries it goes dark ("The shrine has gone dark").
- [ ] Bargain Shrine: prompt shows "+ Team: +25% damage, +30% gold this stage" and "- Enemies: +20% HP this stage", FREE. Use it: a banner names who sealed it, a crimson BARGAIN chip shows under the items strip, enemies take longer to kill, more gold drops; next stage the chip is gone and the effect ends.
- [ ] Guarded Altar: a floating "GUARDED ALTAR" marker over it; the prompt (when near) shows the free reward and "Wakes N elite guards". Walk within ~24 studs: "The altar's guardians awaken!", N elites climb out around it, the marker says "GUARDS LEFT x / N". Guards drop no elite chests. Kill them all: "unguarded: open it", hold to open: every living teammate gets an item popup. Marker then disappears.
- [ ] Summon the Queen while guards are alive: the guards vanish, the altar goes back to dormant; walking near again brings back only the guards that were not killed.
- [ ] Items work: Whetstone / Crown more damage, Quick Gloves faster attacks, Swift Feather faster walking, Hearty Bread max HP up, Bandage HP slowly refills, Keen Lens / Hunter's Eye sometimes bigger hits, Iron Plate less damage, Guardian Ward a steel band on the health bar and "+N" after 5 s without damage, Barbed Mail red ring + damage when hit, Storm Charm chain lightning, Volatile Spore explosions on kills, Spare Quiver an extra knife / orb now and then, Magnet Totem gem pulls every ~10 s, Phoenix Feather: fall once and rise at 50% (it leaves the strip).
- [ ] Pause menu → ITEMS: a list with every item, stack count, rarity and full text; BACK closes it.
- [ ] Results (defeat and portal return): "Items found" row with the run's items; gold = what you took home (earned minus spent). Next run starts with no items.
- [ ] Duo: both stand at one chest and hold: only one opens it and pays; the other gets "Someone was faster" and keeps their gold. A player who leaves mid-hold: nothing breaks. Bargain applies to both. The altar gives both players an item.

## 1f. Enemies, elites and the Scorpion Queen (solo first, then Duo)
Tip: `Config.Pacing.EliteFirst = 20` and a `SpawnTable` row 1 with `Spitter = 30, Bomber = 30, Brute = 30` show every enemy within a minute; DEV → "Spawn portal boss" for the Queen (stage 1). Offline: `bash tools/preview/render.sh enemy-telegraphs,boss --devices pc,phone --set moment=charge` (moments: entrance, charge, venom, ring, burrow, summon, stunned, collapse) and the headless `boss-sim --studio`. The other bosses and the later creatures: section 1i.

Enemy roles and telegraphs
- [ ] New enemies climb out of the ground (short rise + dust puff) and can't hurt you during it; deaths are the usual short poof.
- [ ] First appearance of a type in a run: one toast "New: <name> - <hint>" (Beetle Warrior 1:00, Phase Moth 3:00, Spitter / Bomb Tick 4:00, Rhino 5:00), with a small group of that type. Never again in the same run; again in the next run.
- [ ] Spitter (mauve beetle, amber sac): keeps 22-30 studs away (backs off when you come close), stops, swells for 0.7 s while a dashed amber ring with a crosshair appears where you stood; the glob arcs over (~1 s) and splashes inside that ring only. Walking out of the ring = no damage.
- [ ] Bomb Tick: reaching you it stops, swells and blinks faster and faster for 0.7 s inside a crimson ring with a blinking amber double edge (the blast radius), then explodes. Stepping out of the ring = no damage; killing it during the fuse defuses it (no explosion).
- [ ] Rhino Beetle: within ~15 studs it rears up for 0.65 s over a short crimson lane, lunges along that lane, then stands still briefly (free hits). Sidestepping the lane avoids it.
- [ ] Wasps, Mites, Beetle Warriors and Phase Moths behave as before (moths still fly through walls).
- [ ] Telegraphs sit on the floor above paths and plazas, under heroes and bugs; they have a dark outline and stay readable on grass, dirt and stone; they never cover enemies.

Pacing
- [ ] The first seconds of a run and of every new stage are calm (few enemies), then pressure builds toward each 30 s mini-wave; after a mini-wave a few seconds of lighter spawning.
- [ ] At 2:30 and every 2:45 after: "An elite <Affix> <Name> hunts you!" and that elite appears from off-screen.

Elites (one affix each)
- [ ] Every elite (big, gold, crowned) has exactly one aura + a small tag over the crown: BURNING (flame ring), SHIELDED (three orbiting plates), SWIFT (wind streaks, clearly faster).
- [ ] Shielded: the first hits do no HP damage (hit flashes still show); when the shield breaks the plates shatter and the aura disappears.
- [ ] Burning: while walking it leaves small fire patches behind it that glow for half a second before they burn; standing in a burning patch hurts in ticks; patches fade after ~3 s; never more than 5 per elite.
- [ ] Elites still drop a chest (altar guards drop gems only).

The Scorpion Queen
- [ ] Entrance (~2.5 s): she rises out of the ground behind the portal with a dust ring, a roar and a small shake; the boss bar fills with "SCORPION QUEEN"; your hits do nothing and touching her doesn't hurt; she does not attack for ~2 s after she is up.
- [ ] The boss bar has a notch at 50%.
- [ ] Charge: she crouches and trembles while a crimson lane (with chevrons) fills toward its end (1 s), then rushes along it; afterwards she is dizzy for ~1.3 s (stars over her head): touching her is safe, hit her.
- [ ] Venom Burst: claws up, then 3 circles (4 in Duo, 5 in Trio) appear under and next to the players and fill in ~1 s, then erupt with crimson spikes. Only the circles hurt; one or two steps get you out.
- [ ] Stinger Ring: her tail rises with an amber glow and crimson spokes show every stinger lane with 3 clear gaps; two waves of stingers fly along the spokes. Standing in a gap = no damage.
- [ ] Burrow: she sinks, a dust trail chases one player for ~2 s (she can't be hit meanwhile), then a crimson circle with inward ticks stays put for 0.8 s and she erupts there (dirt burst), dizzy for ~1 s.
- [ ] Summon: eggs appear around her, wobble harder and crack, and Beetle Warriors fade in (no instant spawns on top of you).
- [ ] Below 50%: "THE QUEEN IS ENRAGED!", a roar, the notch is passed; attacks come a bit sooner and every charge is a double charge (a second lane right after the first).
- [ ] Kill her in the middle of an attack (e.g. while circles are filling): every circle, spoke, egg and flying stinger disappears at once; she collapses (~1.5 s, no slow motion); then the gold, gems and the surge come as before.
- [ ] Duo / Trio: she targets whoever is alive; a fallen or leaving player is never charged / burrowed at; revived players are targeted again; two players hitting her at the same time never double-reward.
- [ ] Travel to the next stage or the end of the run with telegraphs on the floor: they all vanish; nothing lingers on the next stage.
- [ ] Phone: telegraphs are readable at phone size; the boss bar fits under the plate.

## 1i. Rotating bosses and the later creatures (solo first, then Duo / Trio)
Tip: DEV → "Spawn portal boss" always summons the stage's boss; to test one boss on stage 1
set `Config.Boss.First` to `MothMatriarch`, `RhinoWarlord` or `HiveMother`. Offline:
`bash tools/preview/render.sh boss --devices pc,phone --set boss=RhinoWarlord --set moment=pound`
(see docs/PREVIEW.md for every moment), `enemy-telegraphs --set view=creatures` and the headless
`boss-sim --studio --set boss=<Name>`.

Rotation
- [ ] Stage 1 is always the Scorpion Queen. Stages 2-5 bring the other three and the Queen in a shuffled order; after that a new shuffle; never the same boss twice in a row.
- [ ] The travel card reads "STAGE N" and "<ARENA> · <BOSS>"; during the fight the pill reads "Defeat the <boss>" and the boss bar shows its name and the 50% notch.
- [ ] The awaken banner names the boss ("THE MOTH MATRIARCH DESCENDS!", "THE RHINO WARLORD CHARGES IN!", "THE HIVE MOTHER STIRS!") and "<BOSS> DEFEATED! SURVIVE THE SURGE!" follows its death.
- [ ] Every boss: invulnerable and harmless during its 2.5 s entrance, no attack for 2 s after; HP scales with stage and players (Moth x0.85, Warlord x1.15, Hive x1.05 of the Queen's).
- [ ] Achievements: Moth Bane / Banner Breaker / Hive Cleanser (120 gold each, Banner Breaker also a title) unlock the first time that boss dies; Queen Slayer still needs the Scorpion Queen.

Moth Matriarch (flies)
- [ ] Entrance: she flies down from high above onto an amber ring.
- [ ] Dust Storm: wings up and shaking; a crimson ring at her feet with one opening, two ivory lines and gold chevrons marking the safe lane (1.1 s); then a dust ring rolls outward (21 studs/s). Standing in the gap lane = no damage; anywhere else the ring hits once (18).
- [ ] Dive: she rises and leans back while a lane fills (1.1 s), swoops along it, then lands grounded for ~1.4 s (stars; touching her is safe).
- [ ] Glimmer Mines: 5 motes (7 Duo, 9 Trio) drift down around the players and blink slowly, then faster, over dashed circles; they pop after 2.6 s (16). Stepping out is easy.
- [ ] Summon: cocoons crack around her and Phase Moths flutter out.
- [ ] Below 50%: "THE MATRIARCH WHIPS UP A TEMPEST!"; Wing Gust joins the cycle: she rears back while an ivory wind cone with drifting streaks shows (0.9 s), then players inside are pushed ~12 studs away (no damage, never into rocks or out of the fence, no rubber-banding). Dust Storm sends a second wave whose gap is turned ~70°, its gap lane shown as the first wave leaves.

Rhino Warlord (heavy)
- [ ] Horn Charge: a lane fills (1.1 s), he charges. If the lane ends at a tree / rock / the fence he slams into it and is stuck for ~2.2 s (stars, dust, free hits); otherwise a short 1 s recovery.
- [ ] Ground Pound: he rears up (0.8 s), slams; three crimson bands (0-8, 8-15, 15-22 studs) each with a bright front rolling outward; they strike one after another (1.0 / 1.6 / 2.2 s): step into a band that already struck.
- [ ] War Banner: he raises the banner from his back and plants it beside him (it disappears from his back); a dashed crimson zone (22 studs) with a gold ring at its foot; toast "WAR BANNER! Destroy it to break the rally"; two Beetle Warriors climb out with it. Beetles in the zone stand on crimson rings and are faster / hit harder. The banner has an HP bar; destroying it removes the zone and the buff and the banner returns to his back. With one standing, he summons instead.
- [ ] Summon: the soil cracks open in 4 spots (5 Duo, 6 Trio) and Beetle Warriors climb out.
- [ ] Below 50%: "THE WARLORD GOES BERSERK!"; every pound is a double pound: after the first, he rears again and the bands come back from the outside in.

Hive Mother (slow)
- [ ] Egg Barrage: the egg sac heaves, then 4 eggs (5 Duo, 6 Trio) tumble in arcs onto dashed acid circles near the players (12 on landing). Each egg then sits with an HP bar and an amber timer ring, wobbling harder; unless destroyed within 3.5 s it hatches 3 Mites.
- [ ] Acid Pools: head down; dashed acid circles fill (1.2 s), then bubble as pools for 6 s (5 per 0.5 s while you stand in them).
- [ ] Brood Call: soil cracks around her and Spitters climb out (never past the Spitter cap).
- [ ] Hit her hard (a lot of damage in 1.5 s): a double-edged amber ring around her fills for 0.9 s and pulses (14), at most every 9 s.
- [ ] Below 50%: "THE HIVE MOTHER SWELLS WITH ACID!"; each pool drips a trail of 3 small pools back toward her.

Every boss
- [ ] Kill it in the middle of an attack: every telegraph, wave, mine, band, pool, egg, banner and flying projectile disappears at once; the collapse; then gold, gems and the surge.
- [ ] Duo / Trio: deaths, revives and a teammate leaving never leave a boss aiming at nobody; gusts only push living players.

Later creatures
- [ ] Healer (from 6:00, at most 4 + 1 per extra player): pale aphid with a spinning halo that hangs back 16-26 studs; every ~3.5 s it glows and a green pulse heals nearby enemies (not bosses or nests); dies in a hit or two. Callout "New: Healer - it heals the swarm, kill it first".
- [ ] Burrower (from 7:00, at most 6 + 2 per extra player): only a soil ring with a dust trail moves toward you (it can't be hit); near you it stops, a crimson circle with inward ticks warns for 0.9 s, it bursts out (10), is dazed for 0.6 s and then bites like a normal bug. Callout "New: Burrower - watch for the dust trail".
- [ ] Neither Healers nor Burrowers come in mini-wave rings.
- [ ] Nest (stage 1 only after 6:00; from stage 2 50 s into the stage, then every 70 s; 2 per stage, 3 from stage 3; at most 2 at once; only while exploring): a wax-rimmed mound with an HP bar 30-46 studs from a player; every 4.5 s two small amber rings at its openings, then 2 Mites climb out (at most 8 of its mites alive). Destroying it: "Nest destroyed! +N gold each" (12 + 6 per stage after the first, to every living player) and extra gems. The open portal clears leftover nests without the reward.

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
- [ ] All fall → DEFEATED; the results line says "Fell on stage N · Forest (Duo)" / "(Trio)".
- [ ] DEV → "Start solo now" during someone's countdown starts the run immediately with the players already in.

## 1c. Uploaded 3D models (after tools/upload_meshes.py)
- [ ] Output has no "[MeshService] could not load" warnings.
- [ ] Bugs, heroes, crystals, weapons, chest and pickups use the new models; legs/wings/claws move.
- [ ] No mesh lies on its side or floats/sinks: trees, mushrooms, rocks, bushes, pillars, crystals, torches and banners stand upright on the ground (Output has no "imported rotated" warnings; if it does, heroes/bugs need the same fix).
- [ ] Forest arena: a dirt clearing with a stone ring at the spawn (nothing solid within ~40 studs), 4 dirt paths leading out, tree groves with red mushrooms in their shade, two fairy rings, a reed pond, rock outcrops, fallen logs, flowers, 3 purple alien nests with egg pods. The edge is a broken wooden fence with bushes and a dense tree line outside; the south (camera) side has only low trees, so the hero is never hidden there.
- [ ] Forest collision: you can't walk through trunks, big mushrooms, big rocks, logs, hive mounds or the pond; small mushrooms, bushes and flowers are walk-through decoration.
- [ ] Ruins arena (stage 2 of any run, or picked in the lobby after reaching stage 2): mosaic plaza at the spawn, 4 flagstone avenues with colonnades (standing, broken and toppled pillars), 8 flickering torches at the plaza, a ruined building in each quadrant, 5 glowing purple crystal fields, autumn trees, rubble; a broken crenellated wall with corner towers (low on the south side), dark pines outside. Golden-dusk light with purple haze.
- [ ] Ruins collision: pillars, stumps, toppled pillars, building walls, crystal centres, torches and corner towers block you and the bugs; enemies path around them.
- [ ] Castle lobby (behind the menu): the shot shows the courtyard flagstones and the gold/blue emblem in the middle, the keep behind with a warm-lit arched gate and raised portcullis, steps, red wall banners, braziers with fire, two roofed towers with flags, blue pole banners, torches and planters on the sides, pine forest and hazy mountains in the background, drifting dust motes / fireflies. Torch lights flicker.
- [ ] Swamp arena: murky green bog, two bog tracks crossing at the spawn, a stilt hut with wisp lanterns (north-west), sunken mossy ruins with an arch (north-east), a ring of bog stones round a lantern (east), a low fisher camp (south-west), a deep bog pond with lilypads (impassable), mangrove and willow groves, reeds along the edge, mangrove tree line (low on the south side). 8 dark MUD pools: walking through one slows you clearly (~65%) and slows walking bugs too; wasps / moths fly over at full speed; the slow ends the moment you step out.
- [ ] Snow arena: snowfield with packed-snow trails, the carved totem shrine with stone lamps (west), a snowed arch over the north trail, an ice-crystal ring with a frost glow (east), a trapper camp (south-west), a boulder field, two collapsed towers, snowy pine groves, a snowed fence and tall snowy pines outside. 7 pale-blue FROZEN PONDS: on the ice you run ~20% faster but turning and stopping drift (you slide a little after letting go of the stick); off the ice control is crisp again. Enemies are not affected.
- [ ] Desert arena: warm sand, caravan tracks, the gold-capped obelisk court with braziers (north), a nomad camp with striped tents and torches (west), a ruined gate (east), giant bones among cacti (south-west), two big mesas, a dry oasis basin (impassable), cactus stands, sandstone ruins, mesas and rocks outside, dunes on the camera side. 7 swirling QUICKSAND pools: they slow you hard (~55%) and slow walking bugs.
- [ ] Lava arena: ash plain with pale ash tracks, the brimstone altar with a big flame (north), a ruined basalt fort with an ember vent (west), an ember field of vents and obsidian (east), a lava lake behind rim rocks (impassable), basalt column clusters, charred trees. 7 LAVA pools with a breathing orange glow ring: standing in one costs 6 HP (minus armor) every half second after a short grace; level-up / revive invulnerability and shields still protect you; enemies walk through unharmed. Light stays bright enough to read the swarm.
- [ ] In every biome: the portal and the chests / shrines / altar are never in or right next to a pool; nothing solid within ~40 studs of the spawn; pools are never in the spawn clearing; tall trees, mesas, columns and huts fade when they cover the hero.
- [ ] Lighting differs per place: warm golden hour (lobby), bright day with light haze (Forest), dusk with purple haze and stronger glow (Ruins), humid green midday (Swamp), crisp cool late morning (Snow), high warm sun (Desert), warm smoky but bright afternoon (Lava).
- [ ] Performance: in each arena View → Stats shows a steady FPS on the phone emulator (each arena is about 500 Parts + 300-450 MeshParts, all anchored).

## 2. Four-player run (Test tab → Clients and Servers → 4 players, Start)
- [ ] Player 1 taps TRIO; others see "is starting a TRIO run" and a JOIN button; 3 join and it starts; the 4th player sees "A run is in progress (m:ss)".
- [ ] A 4th player tapping JOIN too late gets "This run is full".
- [ ] Everyone spawns in a circle; more enemies than solo.
- [ ] A gem picked up by one player gives XP to all living players.
- [ ] Each player levels separately; a level-up pauses everyone's game (the others see "Paused: <Name> is choosing an upgrade"; auto-pick after 10 s in groups).
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
- [ ] Earn gold in a run, buy a meta upgrade, buy Mage (1,000 gold), equip a skin. Stop.
- [ ] Play again: gold, upgrade levels, Mage owned and selected, skin, settings sliders and stats are back.
- [ ] Gold collected before dying in a run is kept.
- [ ] Session lock: run two Studio sessions with the same account (or Team Test) → the second one waits and then gets the "data is still in use" kick unless the first one left.
- [ ] Shutdown: start a run, stop the server mid-run; the next session settles saved current-run earnings using the failure retention rate. Existing savings and purchases remain intact.
- [ ] Note: if Studio crashes, the lock frees itself after `Config.Data.LockStaleSeconds` (200 s).

## 6. Co-op HUD, tips, results, accessibility, saving (new)
Team HUD (Test tab → 2 or 3 players, DUO / TRIO):
- [ ] Each player sees one row per teammate (right side, under the counters; portrait: under the ability bar): hero icon, name, health bar. Nothing on the left / bottom where the thumb goes; a touch starting on a row still moves the hero.
- [ ] A teammate picks a level-up card: the run freezes, others see "Paused: <Name> is choosing an upgrade" and that row says CHOOSING.
- [ ] A teammate falls: the row says "DOWN · N m" (crimson) and a dashed gold circle appears around them on the floor plus a ring marker over them; when they are off screen a crimson arrow at the screen edge points at them with name and distance.
- [ ] Hold REVIVE in the circle for two seconds: the dashes light up, the marker ring fills, the row says "REVIVING 60%" with a gold bar, and the fallen player sees the same ring over themselves and "A teammate is reviving you... 60%". Release, move or step out: progress resets.
- [ ] A fallen player on the revive-product offer shows DECIDING; with no partner revives left OUT (no circle).
- [ ] A teammate closes their client mid-run: everyone gets "<Name> left the run.", the row disappears at once, nothing breaks.
- [ ] First group run: a "Team run" tip explains shared XP / own gold and items (once ever).

First-run tips (use a fresh save: in Studio with API access off every session is fresh):
- [ ] First run: "How to play" (drag / WASD / left stick by device) appears ~1.5 s in and closes early after walking a bit; then "Auto attack"; after the first kill "Experience"; the first LEVEL UP! line reads "Tap a card: a new weapon, an upgrade or a passive"; after ~40 s "Your goal" (portal); when the Queen appears "The Queen" (floor warnings).
- [ ] Hints never pause or block: you keep moving through them; they wait while the pause / level-up menus are open.
- [ ] SKIP TIPS on a hint: no more tutorial hints this run or later.
- [ ] Second run: no tutorial hints. Settings → Replay tips: they come back. Show tips OFF: nothing shows.
- [ ] An old save (Runs > 0) never sees tutorial hints (schema 5 migration).

Results:
- [ ] Defeat / escape / victory: title, hero medallion, arena + mode, damage, time, enemies defeated, Queens slain (or "Fell to her" / "Not reached"), stages, gold, level, NEW BEST / unlock / achievements, the build (weapons with levels, gold border when evolved, passives) and items found. On a phone everything fits or the middle scrolls; buttons always visible.
- [ ] REPLAY (solo): back to the lobby and a new Solo run starts by itself. REPLAY (Duo defeat): a new Duo countdown starts (or joins the teammate's). REPLAY after leaving through the portal while teammates go on: disabled, "YOUR TEAM IS STILL PLAYING".
- [ ] MAIN MENU: back to the menu. Gold on the menu matches the results (no double reward after REPLAY).

Accessibility (Settings in the lobby and the pause menu):
- [ ] Music / Effects / Screen shake sliders, Reduced effects, Damage numbers, Show tips switches (each says ON / OFF), Replay tips. Rejoin: every value is back.
- [ ] Screen shake 0%: no shake from explosions, the Queen's roar or being hit.
- [ ] Reduced effects: fewer sparks / dust / trails in a big fight, no crimson edge pulse when hit, the low-health edge is steady, no XP bar flash. Telegraphs are unchanged.
- [ ] Damage numbers ON: numbers over enemies you hit; with 150+ enemies there are only a handful at a time (one per enemy, merged), crits gold with "!". OFF (default): none, and the server sends nothing.

Audio:
- [ ] In a 200-enemy fight the Bomb Tick fuse ticks, Spitter wind-up, Rhino lunge and the Queen's warnings stay audible over the hits (combat ducks briefly). Far-away warnings are quieter.
- [ ] Your own swings / throws have a quiet cue; teammates' don't spam yours. Leaving a run silences everything at once.

Saving visibility:
- [ ] Studio with API access OFF: the lobby shows "Progress isn't being saved in this session"; the pause / settings note says so too.
- [ ] Live server with DataStores failing (or simulate with a failing UpdateAsync): after the retries a run toast "Progress isn't being saved right now" and the lobby notice; when a save works again, "Saving works again".

## 7. Curses, Daily Challenge, leaderboards, account level (new)
Offline first: `bash tools/preview/render.sh curses,daily,leaderboards,track,countdown,menu --devices pc,phone,phone-portrait`, `render.sh results --set daily=on`, `render.sh arena --set curses=Frenzy,Horde --set daily=on` (HUD chips) and the headless `render.sh stage-sim --studio --devices pc --max-time 260 --set daily=on` / `--set curses=Frenzy,Fragile`.

Curses
- [ ] Home: a CURSES button under TRIO (portrait: next to DAILY) reads "Harder runs, more gold"; it opens the CURSES screen with 6 cards (icon, name, effect, gold badge, ON / OFF).
- [ ] Tap cards: they turn gold-bordered and ON; a 4th tap says "Up to 3 curses: drop one first."; the footer shows "2 / 3 curses · +35% gold"; CLEAR empties it; DONE goes back. Rejoin: the pick is still there.
- [ ] Solo with Frenzy + Horde: start toasts "Curses: Frenzy, Horde · +45% gold"; HUD chips FRENZY / HORDE / +45% GOLD under the items strip; enemies are visibly faster and more numerous; the results list the curses; gold income is about 45% higher than the same run without.
- [ ] Fragile: max HP 70% (100 → 70 on the health bar). Glass Cannon: damage numbers 30% higher, hits hurt more. Famine: no roast chickens drop. Elite Surge: noticeably more random elites.
- [ ] Duo: the starter's curses show on the countdown panel for both players ("CURSES Frenzy, Horde · +45% gold"); the starter changing them during the countdown updates the panel; the other player's own pick does not change the run (the CURSES screen says so).
- [ ] In a run SetCurses does nothing (a tap from an old client mid-run is ignored).

Daily Challenge
- [ ] The DAILY card reads "Ready · <time> left"; its screen shows today's date (UTC), the reset countdown, the route (stage 1-5 arena · boss), 2 curses + their gold, the starting bonus and PLAY "Scored attempt".
- [ ] PLAY: a solo run starts on the route's first arena with "DAILY CHALLENGE" / "Scored attempt: make it count!", the DAILY + curse chips and the bonus (a second weapon / two items / level 4 cards / an extra life). The travel card names the route's next arena and boss.
- [ ] Leave the run any way (die, portal, quit the game): the card now says "Done · 2 stages · 7:41"; the screen says the scored attempt is used and PLAY reads PRACTICE. A practice run says "Practice run: not scored." and its results say "DAILY · PRACTICE ... (not scored)"; the daily score does not change.
- [ ] Two players on different servers see the same route, curses and bonus on the same UTC day; the next UTC day everything changes and the attempt is ready again.
- [ ] REPLAY from a daily's results starts a practice daily run.

Leaderboards (API access ON; Studio without it: the screen says "Global leaderboards need DataStores ... Showing runs on this server only.")
- [ ] RANKS opens BEST STAGE / DAILY / MOST KILLS tabs; rows show rank (gold / silver / bronze discs for the top 3), name and value ("Stage 7", "3 stages · 9:12", "1,874"); your row is gold; the bottom bar shows "#4 ... Your best: Stage 10" or "Not in the top 50 · Your best: ...".
- [ ] Finish a run: within about a minute the boards show the new values (writes are throttled; reads are cached 60 s). The DAILY tab only lists today's scored attempts. The DAILY screen's LEADERBOARD button opens the DAILY tab.
- [ ] Output shows no DataStore errors or throttling warnings in a normal session.

Account level
- [ ] The nameplate reads "LV 1 <name>"; after a run the results show "+N XP · Level 1 → 2" with the XP bar and "UNLOCKED Title: Recruit (wear it in TRACK)"; the nameplate shows the new level and the title.
- [ ] TRACK: level, XP bar "x / y XP to level n", how XP is earned, and every reward (LV 2 ... LV 50) with WEAR / WORN / LOCKED. WEAR a ring: a glowing ring appears on the lobby dais under your hero (some with sparkles); WEAR a frame: the results and TRACK medallions get it; tap WORN to take it off. Colours and titles also appear under STATS → ACHIEVEMENTS.
- [ ] Nothing on the track changes run stats (compare a run before / after wearing everything).
- [ ] Old save (schema 5) loads with gold, characters, achievements intact, level 1, no curses, daily ready (Output: no migration errors).

## 8. Fixes and polish pass (DEV, main menu, chests, XP, fire, HP, high score, effects, performance)
Publish the new `build/Swarm.rbxlx` first: a live game only changes after a publish.

DEV and invincibility
- [ ] Live game, owner account (UserId 20194281): the DEV button shows in the lobby and in a run, and is still there after dying, respawning and going back to the menu. A friend's account: no DEV button.
- [ ] RUN tab → "Invincible: OFF" turns to ON; a red INVINCIBLE badge sits on the DEV button. Slimes, spitter globs, bombs, lava / biome pools and every boss attack do no damage.
- [ ] The results of that run say it was a DEV run; no leaderboard, record, achievement or daily score changes. The next run starts with invincibility OFF.
- [ ] SAVE tab → Reset progress in a live game only shows "works in Studio only".

Pause → MAIN MENU
- [ ] Pause → MAIN MENU asks "LEAVE THIS RUN?"; KEEP PLAYING goes back; LEAVE RUN returns to the menu with a "RUN ENDED" results panel. No enemies, sounds, camera or HUD left over.
- [ ] Do it three times in a row, then die in a run, then start another run: everything starts clean. Duo: the partner keeps playing.

Level-up cards, icons
- [ ] Cards fly in one after another with their icons already showing (Vacuum too). Holding WASD / the stick / A when the cards appear does not pick one. Hover / gamepad focus lifts a card; picking punches it and the screen closes fast.

Chests
- [ ] Hold E about 0.4 s (touch / gamepad: hold the prompt). A reward strip slides past a gold marker, ticks, slows and lands on the item, shows it, and closes by itself (tap skips). Several chests queue ("1/3"). The item is owned even if you die or leave during the strip.

XP, Fire Trail, HP
- [ ] XP drops are blue / violet crystals (not coins), merge when close, fly to you; Vacuum / Magnet still collect all of them.
- [ ] Fire Trail: tall flickering flames on a faint scorch; the floor and enemies stay visible.
- [ ] HUD shows "85 / 100 HP" and stays right through damage, healing, max HP upgrades, death and revive.

High score, effects, performance
- [ ] LEADERBOARDS opens on HIGH SCORE; after a normal run your score (also on the results line) appears there; in Studio the note says this server's runs only.
- [ ] Lobby screens, HUD, banners, results and combat effects animate; with "Reduced effects" on they calm down.
- [ ] A dense swarm (stage 4+, 300+ enemies): compare FPS with the previous version (Ctrl+F6 MicroProfiler: EnemyAI.* bars).

## 9. Private run servers (published game only: teleports do not work in Studio)
Studio runs stay on one server as before (check: Solo in Studio starts at once, no "Travelling" screen).
Publish the place, then use two accounts (A and B) on two devices.
- [ ] A and B join the same lobby server. Both tap SOLO at about the same time: each sees "Travelling to your run…", then "Starting your run…", then their own run. Neither sees the other in the run.
- [ ] While A is in a run, B (back in a lobby) can start SOLO again at once: no "a run is in progress" message.
- [ ] Party DUO: A invites B (PARTY), B taps READY, A taps DUO: both travel together and play the same run; the HUD shows both.
- [ ] Duo countdown without a party: A taps DUO, B taps JOIN: both arrive in the same run.
- [ ] After a run (die, portal RETURN, or pause → MAIN MENU) the banner "Back to the lobby in N s" shows; GO NOW travels at once, STAY keeps you in the private server's lobby (start another run there, or leave). After a defeat you go back by yourself about 2 s after the results.
- [ ] A and B as a party go home together: they land on the same lobby server and are in a party again.
- [ ] JOIN (PARTY → friends) on a friend who is mid-run says the server can't be joined; nobody can get into someone's run.
- [ ] Save integrity: note gold, owned heroes, account level and best stage before a run. Earn gold, buy an upgrade in the run server's lobby (STAY), go home: everything is there in the lobby, and again after leaving and rejoining the game. Repeat 3 times quickly (start → MAIN MENU → GO NOW): never "Your data is still in use", never a kick, no lost gold.
- [ ] Daily: the scored attempt counts once (play it, go home, the DAILY card says used); Endless and curses picked in the lobby are active in the run.
- [ ] DEV (owner account): the DEV button works in a run server; a DEV run is still marked as a DEV run (nothing recorded).
- [ ] If a teleport fails (rare; e.g. Roblox outage) you get a toast and the run plays on the lobby server instead; nobody is stuck on a blank screen.

