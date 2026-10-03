# SWARM

Look and feel: heroic low-poly fantasy (see `docs/ART_DIRECTION.md`). Screenshots can be
rendered without Studio with the offline preview tool (`docs/PREVIEW.md`).

A Vampire Survivors-style auto-attack wave survival game for Roblox, written in Luau
with a Rojo project layout: exterminator heroes against an alien insect swarm.

Models come from two places:
- **Blender meshes** (`blender/`): chunky low-poly heroes, bugs, the Scorpion Queen boss,
  weapons, crystals and map props. They show up in game after they are uploaded (see §9).
- **Part-built fallbacks** in code, used for anything not uploaded yet, so the game always runs.

- Third-person top-down camera. You only move; weapons fire on their own.
- Runs are a series of STAGES (Risk of Rain / Megabonk style, see "Gameplay loop" below):
  find the portal, summon and kill its boss, survive the surge, then go deeper or
  cash out with a win. The lobby is a full-screen menu with three modes:
  **Solo** (starts at once), **Duo** (2 players) and **Trio** (3 players). In Duo and Trio
  you revive a fallen teammate by standing next to them for 3 s (see §10).
- 17 weapons (8 levels + evolution each, 13 of them with a behaviour perk), 15 passives, 9 enemy types with clear roles + nests + elites with affixes + 4 stage bosses (Scorpion Queen, Moth Matriarch, Rhino Warlord, Hive Mother).
- 8 characters (the Ranger, Alchemist, Engineer and Necromancer are earned through achievements), achievements, permanent gold upgrades, gamepasses, developer products, cosmetic skins.
- Mobile first: a floating thumbstick is the only control during a run.

## Gameplay loop

1. **Stage 1** is the lobby's arena (Forest by default); later stages tour the other
   biomes (`Config.Arenas.Rotation`: Ruins, Swamp, Snow, Desert, Lava, shuffled per run,
   then every arena reshuffled; never the same arena twice in a row; the travel banner
   names the biome). Swamp, Snow, Desert and Lava have floor **hazards** (below). Each stage has a stone-ring
   **portal** at a random clear spot at least 120 studs from the spawn (a new spot every
   stage), with a soft light beam and a rune circle on the floor.
2. **Explore** while the swarm comes as always. Difficulty keeps scaling with the **total
   run time** (the per-minute tiers and spawn table), plus a per-stage multiplier
   (`Config.Stages`); stage 1 plays exactly like the old early game. HP / damage stop
   growing with time after minute 12 (`Config.Difficulty.MaxTier`). **The portal reveal**
   (`SwarmState.PortalReveal`, a few seconds into the stage once the portal can be charged,
   `Config.Stages.RevealDelaySeconds` / `PortalLockSeconds`) is made unmistakable: a banner
   "THE PORTAL HAS APPEARED" with a sound, a tall light pillar with a pulsing floor ring over
   the portal (client `PortalBeacon`, one pooled beacon; steady and without the burst under
   Reduced effects / Reduce flashes; colorblind palette through `Accessibility`), an
   always-on arrow at the screen edge with the distance (`StageUI`; `HintAfterSeconds` = 0)
   and a minimap ping (the portal marker is pinned to the map's edge while it is out of view).
3. **Charge the portal**: stand in its rune circle for ~2 s (any living player; on a phone
   just stand there) once it is revealed (`PortalLockSeconds` can keep it dormant first; the
   owner chose 0). That summons the stage's **boss** behind the portal: the **Scorpion Queen** on stage 1, later stages rotate the Queen, the **Moth Matriarch**, the **Rhino Warlord** and the **Hive Mother** (HP scaled by
   stage and player count, the normal boss-fight spawning rules; see "Stage bosses").
4. **Surge**: when she dies, every living player gets the boss gold and a burst of enemies
   pours out of the portal (25 + 15 per stage); survive 20 s or kill most of them. Gems,
   chests and chickens left on the floor when the group travels are collected for them.
5. **The portal opens**: leftovers burn up, the gems fly to you, and each living player
   picks **NEXT STAGE** or **RETURN TO LOBBY** (15 s, undecided = next stage).
   * Return = that player's run ends at once: `WinBonus` (100) + `StageClearBonus` (150) per stage
     cleared, best time / furthest stage saved, results over the lobby menu. It counts as a
     WIN (Stats.Wins) only with `Config.Stages.WinMinStages` (3) stages cleared.
   * Reaching a stage unlocks arenas in the lobby (`Config.Arenas.<name>.RequiredBestStage`):
     Ruins at stage 2, Swamp 3, Snow 4, Desert 5, Lava 6.
   * Next stage = everyone who stays travels (fade, "STAGE N"): new arena, enemies / gems /
     projectiles cleared, level / XP / weapons / passives / gold kept, HP topped up,
     fallen teammates revived. If nobody goes on, the run ends cleanly.
6. Dying still ends your run (results show the stage you fell on); everyone down = defeat.

### Biome hazards (`Config.Arenas.Hazards`, `BiomeHazards.lua`)

Fixed pools in the designed layouts (7-8 per arena, 55+ studs from the spawn, never under
the portal or loot: `FindPortalSpot` / `FindOpenSpot` keep `LootPad` studs from a pool's
edge). The server decides everything; the pool meshes are the telegraph.

| Arena | Hazard | Players | Enemies |
|---|---|---|---|
| Swamp | 8 mud pools | move at 65% | walkers 65% (flyers, bosses unaffected) |
| Snow | 7 frozen ponds | +20% speed but the steering drifts (client input smoothing, 0.35 s) | unaffected |
| Desert | 7 quicksand pools | move at 55% | walkers 55% (flyers, bosses unaffected) |
| Lava | 7 lava pools (glowing rims) | 6 damage every 0.5 s (first tick after 0.25 s; armor, shields and invulnerability apply) | unaffected |
   The timer shows the total run time; there is no 15:00 end any more.

Code: `StageManager.lua` (server, the loop and the portal), `RunManager.lua` (players,
results, travel), `MapBuilder.FindPortalSpot / BuildPortal`, client `StageUI.lua` (arrow,
charge ring, choice panel, travel fade) and the stage pill in `Hud.lua`.

## Exploration loot: items, chests, shrines, the guarded altar

Every stage scatters loot over the map (new spots each stage, never in the spawn
clearing, away from the portal and each other; all of it is removed on travel and when the
run ends). Code: `LootSystem.lua` (server), `ItemSystem.lua` (server), `ItemData.lua`
(shared), client `LootUI.lua`; numbers in `Config.Items / Chests / Shrines / Guarded`.

* **Chests** (10-14 small, 2-3 large, 1 golden): stand next to one and **hold E** (gamepad X,
  or press and hold the HOLD button on a phone). It costs **run gold** and gives one item.
  Price = 25 / 60 / 150 x stage^1.2 (stage 2: 57 / 138 / 345), x your gold multiplier
  (gamepass owners earn more, so they pay the same share: passes never buy items).
  Small: 80% common, 19% uncommon, 1% legendary; large: uncommon or 20% legendary;
  golden: legendary. Luck raises the better odds.
* **Shrine of Chance** (1-2 per stage, gold sigil): pay gold (15 x stage^1.2, +20% per try)
  for a 50% chance of an item (55% common, 38% uncommon, 7% legendary); dark after 2 items
  or 6 tries.
* **Bargain Shrine** (1 per stage, crimson): free, once per stage, the prompt shows both
  sides first: the whole team gets **+25% damage and +30% gold**, the swarm gets **+20% HP**
  (enemies that spawn afterwards and the Queen) until the next stage. A HUD chip shows it.
* **Guarded Altar** (1 per stage, at least 90 studs out): a free rare chest. It wakes when a
  player comes within 24 studs: 2 + stage + (players - 1) elite guards (max 8) climb out
  around it. When they are all dead it unlocks; opening it gives **every living teammate**
  an item (75% uncommon, 25% legendary). Guards drop gems, not elite chests. States show in
  the world and on a floating marker: dormant / guards left / unguarded / claimed. If the
  guards are swept away (the Queen's arrival, the portal), it goes dormant again and only
  the guards that were not killed come back.
* **Run gold**: the big purse in the middle of the HUD, just over the ability bar (portrait:
  under it), is gold this run has banked (it goes into your save the moment it is earned).
  It counts up with a "+N" on every gain; a kill that pays gold throws chunky gold coins
  (GoldCoin / GoldPile meshes, a client-side visual from FxBatch "g") that fly into the
  player. Next to a chest or shrine the purse shows its price, and turns red with "NEED N"
  after a press without enough gold. Chests and shrines spend it and take the same amount
  back out of the save, so a run can only spend what it earned; older savings are never
  touched. The results screen shows the gold you took home and the items you found.
* **Chest rewards pause the run**: an item from a chest / shrine / altar, or an elite chest's
  level-ups and gold, shows in a compact centred TREASURE panel while the whole run freezes
  like a level-up (`RunManager.HoldReward`; teammates see "<Name> is opening a chest"). It
  closes after `Config.Chests.RewardPauseSeconds` (2.5 s) or on a tap; rewards in a row
  join the same panel and never hold the run longer than `RewardPauseMax` (5 s).

**Items** (19, stacking, kept across stages, lost when the run ends; ivory common,
slate-blue uncommon, gold legendary). "Linear" = every copy adds the same, "hyperbolic" =
1 - 1/(1 + k x copies), so it never reaches 100%.

| Item | Rarity | Effect (per stack) | Stacking |
|---|---|---|---|
| Whetstone | Common | +10% damage | linear |
| Quick Gloves | Common | +6% attack speed | linear |
| Swift Feather | Common | +5% move speed (total move speed capped at 2.2x) | linear |
| Hearty Bread | Common | +15 max HP | linear |
| Bandage Roll | Common | 1 HP/s regeneration | linear |
| Lodestone | Common | +20% pickup radius | linear |
| Keen Lens | Common | +5% crit chance (crits deal x2; total chance max 60%) | linear |
| Healing Herb | Common | kills have ~5% chance to heal 3 HP | hyperbolic k = 0.05 |
| Iron Plate | Uncommon | take less damage (6% / 15% at 3 / 38% at 10) | hyperbolic k = 0.06 |
| Barbed Mail | Uncommon | when hit: 150% (+100%/stack) of max(half the raw hit, damage taken) to enemies within 8 studs, every 0.5 s at most | linear |
| Storm Charm | Uncommon | ~10% of hits chain lightning to 3 (+1/stack, max 5) enemies for 40% (0.2 s cooldown) | chance hyperbolic k = 0.11 |
| Volatile Spore | Uncommon | 20% of kills explode for 60% (+30%/stack) of the enemy's max HP (bosses: at most 5% of theirs) | linear |
| Guardian Ward | Uncommon | shield of 8% max HP after 5 s unhurt (max 40%) | linear, capped |
| Spare Quiver | Uncommon | every 6th attack of each weapon +1 projectile (not Garlic; 1 sooner per stack, best every 2nd) | special |
| Magnet Totem | Uncommon | pull gems within 45 studs every 10 s (-2 s, +10 studs per stack, min 4 s) | special |
| Hunter's Eye | Uncommon | +30% crit damage, +3% crit chance | linear |
| Phoenix Feather | Legendary | rise again at 50% HP when you fall (used up) | one life per copy, hold at most 2 (a 3rd re-rolls into another legendary) |
| Crown of Ages | Legendary | +12% damage, +8% attack speed, +8% move speed, +10% max HP | linear |
| Sun Medallion | Legendary | +18% damage, +12% area, +12% duration | linear |

Procs never crit and never trigger other procs; their cooldowns are in `Config.Items`.
Models: `blender/models/loot.py` (Chest_Small / Chest_Large / Chest_Golden, category Loot,
not uploaded yet: part-built fallbacks in `LootSystem.lua` until then), the event models
Guard_Altar and Shrine_Bargain (category Events) and the World Shrine.
DEV panel: "+3 random items", "+300 gold".

## Enemies, pacing and the Scorpion Queen

Code: `EnemyData.lua` (roster, spawn table), `BossData.lua` (boss encounters, data only),
server `EnemySpawner.lua` (spawning, pacing, affixes, damage), `EnemyAI.lua` (movement and
behaviours), `BossAI.lua` (runs a BossData entry), `Hazards.lua` (ground strikes, fire
patches), `Fx.lua` (`Fx.Warn`: every telegraph is one batched entry), client
`Telegraphs.lua` (all floor warnings) and `EnemyRenderer.lua` (poses, auras, emerge).
Every attack follows the same rhythm: **anticipation** (a pose) → **telegraph** (a shape on
the floor that shows exactly where it hits) → **active** (the damage, once, at the end of
the telegraph, decided by the server) → **recovery** (a pause where the attacker can be
hit). Telegraphs are shape-coded (filled growing circles, lanes with edge lines and
chevrons, spokes with gaps, a dashed ring + crosshair for acid, a blinking double ring for
a bomb, inward ticks for the burrow) in the crimson / amber family over a dark outline,
just above the ground and under every character.

### Roster (HP / damage at minute 0, stage 1, solo; both grow per minute / stage / player)

| Enemy (id) | Role | HP | Speed | Contact dmg | Attack | Rewards | First seen |
|---|---|---|---|---|---|---|---|
| Mite (Slime) | basic melee, the standard threat | 8 | 7 | 5 | - | gem (95% small) | 0:00 |
| Wasp (Bat) | fast and fragile, wobbles in, keeps you moving | 5 | 13 | 4 | - | gem 90% | 0:00 |
| Beetle Warrior (Skeleton) | armoured grunt, the Queen's summons | 20 | 9 | 8 | - | gem (20% medium) | 1:00 |
| Phase Moth (Ghost) | flanker, flies through walls | 15 | 10.5 | 7 | - | gem (15% medium) | 3:00 |
| Spitter (new) | ranged: keeps 22-30 studs away | 14 | 8.5 | 4 | acid glob 12 dmg, 4.5 splash; 0.7 s wind-up + 1.05 s flight, every 3.2 s | gem (25% medium) | 4:00 |
| Bomb Tick (Bomber) | suicide bomber | 12 | 11.5 | 0 | stops next to you, 0.7 s fuse, 22 dmg in 8 studs | gem (30% medium) | 4:00 |
| Rhino Beetle (Brute) | slow and durable, blocks paths | 90 | 6 | 16 | 0.65 s rear-up + lane, 0.45 s lunge (13.5 studs), 0.8 s recovery, every 4.5 s | gem (30% large) | 5:00 |
| Healer | support: hangs back 16-26 studs, every 3.5 s a 0.6 s glow then a green pulse heals enemies within 14 studs by 15% of their max HP (never bosses or nests); fragile priority target | 12 | 8 | 3 | heal pulse | gem (50% medium) | 6:00 |
| Burrower | ambusher: tunnels as a dust trail (untargetable, harmless, 12 studs/s, max 8 s), stops within 5 studs of a player, 0.9 s warning circle (r 3.2), bursts out (10), 0.6 s daze, then melee | 22 | 7.5 | 8 | burst 10 | gem (30% medium) | 7:00 |
| Nest | stationary spawner with an HP bar: every 4.5 s two small rings at its openings, then 2 Mites (max 8 of its own alive) | 140 | 0 | 0 | - | 12 + 6/stage gold to every living player + 3 gems | stage 2+ (stage 1 after 6:00) |
| Scorpion Queen (Boss) | the stage boss at the portal | 9000 x stage share | 8 | 30 | see below | 200 gold each + 12 large gems + the surge | portal |
| Moth Matriarch / Rhino Warlord / Hive Mother | the rotating stage bosses | 9000 x 0.85 / 1.15 / 1.05 x stage share | 9.5 / 7.5 / 5.5 | 26 / 32 / 26 | see "Stage bosses" | as the Queen | portal, stage 2+ |

Spawn: enemies climb out of the ground (0.35 s, dust puff) and can't hurt anyone for
`Config.Enemies.SpawnGrace` (0.45 s). Death: the same creature-coloured poof for everyone.
The first time a type spawns in a run it comes as a small group with one callout toast
("New: Spitter - dodge the acid"). Targeting only ever picks living players, so deaths,
revives and players leaving never leave an enemy aiming at nobody.

### Elites (Config.Enemies.EliteAffixes / Affix)

Elites stay big, gold-tinted, crowned, x5 HP, x1.5 damage and drop a chest (15-40 + 15 gold,
x(1 + 0.25 x (stage - 1))), and each gets
**exactly one** affix, shown by its aura (`EliteAura_*` models, part ring until uploaded)
and a small tag over the crown:
* **Swift**: x1.45 speed, wind streaks spiral around it.
* **Shielded**: three orbiting plates soak the first 40% of its max HP, then shatter.
* **Burning**: a ring of flames; while it walks it drops a fire patch every 0.8 s (max 5):
  the patch glows harmless for 0.5 s, then burns 3.2 s (6 dmg every 0.5 s to whoever stands
  in it). Patches are only left behind it, so they never stack into unavoidable damage.

### Pacing curve (Config.Pacing)

* **Calm**: the first 6 s of a run and the first 10 s of every new stage (after the Queen's
  surge and the travel) spawn at 35% of the normal live target.
* **Build-up**: between mini-waves the live target climbs from 85% to 110%.
* **Mini-wave** every 30 s while exploring (a ring of one type, never Spitters), then a **lull**: 8 s at
  55% of the target, so once the wave is beaten there is a short recovery.
* **Introductions**: Beetle Warrior 1:00, Phase Moth 3:00, Spitter and Bomb Tick 4:00
  (Spitter weight 4 → 12 by 12:00, at most 12 alive: `Config.Enemies.MaxLiveRanged`), Rhino
  5:00, Healer 6:00 (at most 4 + 1 per extra player: `MaxLiveSupport`), Burrower 7:00 (at
  most 6 + 2 per extra player: `MaxLiveBurrowers`), each with its callout (intro groups of
  2 for the last two: `Config.Pacing.IntroGroupOf`). Healers and Burrowers never come in
  mini-wave rings or the surge.
* **Nests** (`Config.Pacing.Nests`): on stage 1 only after 6:00 of run time; from stage 2
  the first one 50 s into the stage, then every 70 s; 2 per stage (3 from stage 3), at most
  2 at once, 30-46 studs from a living player, only while exploring. The first one has the
  callout "New: Nest - destroy it to stop the mites", later ones "A Nest takes root nearby!".
  The open portal burns leftover nests (no reward).
* **Elites**: a scheduled, announced elite at 2:30 run time and every 2:45 after
  ("An elite Shielded Rhino Beetle hunts you!"), random elites (1 in 80 spawns) only
  after 1:00. An elite Bomb Tick's blast is x1.4 wider (12 studs) with a 1.0 s fuse.
* **Boss milestone**: the portal (dormant 2:30 on stage 1) summons the stage's boss; the
  crowd drops to half (15-60) during the fight; the surge follows its death.

### The Scorpion Queen (BossData.Bosses.ScorpionQueen)

* **Entrance** 2.5 s: she rises out of the ground behind the portal (dust ring, a short
  shake, roar), invulnerable and harmless; the boss bar fills with her name. Then 2 s of
  walking with no attack.
* **Health display**: name, bar, a notch at 50% (the phase marker).
* **Cycle** (3 s chase between attacks): Charge → Venom Burst → Stinger Ring → Burrow →
  Summon → ...
  | Attack | Anticipation | Telegraph | Active | Recovery |
  |---|---|---|---|---|
  | Charge (directional) | crouches, trembles | 1.0 s lane (12 wide, 63 long) filling toward its end, chevrons | 0.9 s rush at 70 studs/s, contact 30 | 1.3 s dizzy (stars), harmless to touch |
  | Venom Burst (area) | claws up 0.5 s | 3 circles (+1 per extra player, max 5, r 6) under / near players fill over 1.1 s | erupt: 24 dmg | 0.9 s |
  | Stinger Ring (pressure) | tail raises and glows 0.9 s | spokes for every stinger lane, 3 safe gaps of 54° | 2 waves (0.55 s apart) of 11 stingers, 15 dmg | 1.0 s |
  | Burrow (repositioning) | sinks 0.7 s | dust trail follows one player 2 s (19 studs/s; she is invulnerable and untargetable), then the circle (r 7.5) stays put 0.8 s | erupts: 28 dmg | 1.1 s dizzy |
  | Summon | raises up 1.1 s | 6 eggs wobble and crack around her | 6 Beetle Warriors fade in | - |
* **Phase 2** below 50%: a 1.4 s roar ("THE QUEEN IS ENRAGED!"), chase / recovery 30%
  shorter (telegraphs keep their length) and one twist: every Charge is a **double charge**
  (a second 0.8 s lane re-aimed at the nearest player right after the first).
* **Defeat**: a 1.5 s collapse (every Queen hazard, telegraph and stinger is removed at
  once, no slow motion), then the rewards and the existing surge. Damage after 0 HP is
  ignored (no double kill). Travel and the end of a run clear every hazard, projectile and
  telegraph (`Fx.ClearWarn(0)`).
* Party scaling is unchanged (`Config.Boss.HPPerExtraPlayer`, `Config.Stages.BossHPByStage`);
  extra players add Venom Burst circles.

### Stage bosses (BossData: rotation, entrances, patterns)

Stage 1 is always the Scorpion Queen (`Config.Boss.First`). Later stages take
`BossData.Rotation` (Queen, Moth Matriarch, Rhino Warlord, Hive Mother) as shuffled bags:
every boss once before any repeats, never the same boss on two stages in a row
(`StageManager` bossFor; the plan grows on demand so the NEXT STAGE panel and the stage
agree). HP = `Config.Boss.HP` x the boss's `HPMult` x the stage share x the party scaling.
The boss's name is on the boss bar, the awaken banner, the "Defeat the <boss>" pill and the
travel card ("RUINS · MOTH MATRIARCH"). Every boss has the Queen's frame: a 2.5 s entrance
(invulnerable, harmless) + 2 s without attacks, the 50% notch and a phase-2 roar, chase /
recovery shrinking in phase 2 while telegraphs keep their length, a collapse that removes
every hazard / telegraph / projectile / banner / egg at once, damage ignored after 0 HP.
Defeating each one is an achievement (Queen Slayer, Moth Bane, Banner Breaker, Hive
Cleanser). Times in seconds, damage before the stage multiplier.

**Moth Matriarch** (flies; HP x0.85, contact 26, speed 9.5; chase 2.8 s): flies down from
the sky. Cycle: Dust Storm → Dive → Glimmer Mines → Summon.

| Attack | Anticipation | Telegraph | Active | Recovery |
|---|---|---|---|---|
| Dust Storm | wings up, shaking (1.1) | crimson ring at her feet with one opening + ivory lines and gold chevrons marking the safe lane (gap 60°) | a dust ring rolls out at 21 studs/s to 64 studs (3 thick): 18 to anyone it passes outside the gap | 0.9 |
| Dive | rises and leans back | 1.1 s lane (10 wide, 54 long) | swoop at 64 studs/s, contact 26 | 1.4 grounded (stars, harmless) |
| Glimmer Mines | wings up (0.7) | 5 motes (+2 per extra player, max 9) drift onto dashed circles (r 4.2) near the players, blinking slow → fast | pop after 2.6 s: 16 | 0.8 |
| Summon | raises up | 4 cocoons (+1 per extra player, max 6) crack around her (1.1) | Phase Moths flutter out | - |

Phase 2 ("THE MATRIARCH WHIPS UP A TEMPEST!", x1.25 pace): **Wing Gust** joins the cycle
twice (she rears back 0.9 s over an ivory wind cone 34 long / 76° wide with drifting
streaks; for 0.6 s players inside are pushed 20 studs/s away, about 12 studs, no damage,
never into an obstacle or out of the fence, the anti-cheat speed check moves with them) and
Dust Storm sends a **second wave** 1.6 s later with its gap turned 70° (its gap lane shows
as the first wave leaves).

**Rhino Warlord** (heavy; HP x1.15, contact 32, speed 7.5; chase 3 s). Cycle: Horn Charge →
Ground Pound → War Banner → Horn Charge → Ground Pound → Summon.

| Attack | Anticipation | Telegraph | Active | Recovery |
|---|---|---|---|---|
| Horn Charge | crouches, trembles | 1.1 s lane (12 wide, up to 62 long); the lane stops at the first tree / rock / the fence | charge at 62 studs/s, contact 32 | blocked: horn stuck 2.2 (stars, harmless, free hits); else 1.0 |
| Ground Pound | rears up (0.8) | three bands 0-8 / 8-15 / 15-22 studs, each with a front rolling outward | they strike at 1.0 / 1.6 / 2.2 s: 22 each (step into a band that already struck) | 1.0 |
| War Banner | raises the banner from his back (0.9) | plants it 10 studs to his side: a dashed crimson rally zone (r 22) with a gold ring at its foot, toast "WAR BANNER! Destroy it to break the rally"; 2 Beetle Warriors climb out | beetles in the zone (crimson ring under them): x1.3 speed, x1.4 contact damage; the banner has 3.5% of his max HP and an HP bar; only one at a time (else he summons) | 0.6 |
| Summon | raises up | the soil cracks in 4 spots (+1 per extra player, max 6) (1.1) | Beetle Warriors climb out | - |

Phase 2 ("THE WARLORD GOES BERSERK!", x1.25 pace): every pound is a **double pound**: after
the first he rears again (0.5 s) and the bands come back from the outside in.

**Hive Mother** (slow; HP x1.05, contact 26, speed 5.5; chase 3.2 s; the mesh is shown at
0.8 scale, ~14 studs long). Cycle: Egg Barrage → Acid Pools → Brood Call → Egg Barrage →
Acid Pools.

| Attack | Anticipation | Telegraph | Active | Recovery |
|---|---|---|---|---|
| Egg Barrage | egg sac heaves (0.8) | 4 eggs (+1 per extra player, max 7), 0.15 s apart, tumble in arcs onto dashed acid circles (r 3) near the players (1.1 s flight) | landing: 12; each egg then sits (30 HP, HP bar, amber timer ring, wobbling harder) and hatches 3 Mites after 3.5 s unless destroyed | 0.8 |
| Acid Pools | head down (0.7) | 3 dashed acid circles (+1 per extra player, max 5, r 5) fill for 1.2 s | they bubble for 6 s: 5 per 0.5 s while you stand in them | 0.9 |
| Brood Call | raises up | the soil cracks in 3 spots (+1 per extra player, max 5; never past the Spitter cap) (1.2) | Spitters climb out | - |
| (when hit hard) | - | 7% of her max HP within 1.5 s: a double-edged amber ring around her (5 studs past her body) fills 0.9 s | pulse: 14 | at most every 9 s |

Phase 2 ("THE HIVE MOTHER SWELLS WITH ACID!", x1.2 pace): each acid pool drips a **trail**
of 3 small pools (r 2.4, 70% of the life) back toward her.

## Level-ups, characters, achievements

**Pace** (owner decision): every filled XP bar offers an upgrade at once; there is no pacing
timer or delayed gate, and the only brake is the XP cost curve `Config.XP` (30 + 12 per level
to level 20, then +6: level 1 costs 42, level 20 costs 270, level 50 costs 450). The offline
`levelrate-sim` scene (real server, hero walking in the swarm, cards auto-picked) measures
level-ups per player-minute solo / Duo / Trio; see TESTING.md for the latest numbers.

**Level-up cards** (LevelUpSystem → UIBuilder): every card says exactly what changes with real
numbers, current → next: weapons from their stat rows ("Damage 10 → 15", "Arrows 1 → 2",
"Cooldown 1.35s → 1.30s"), passives from the player's real stat sheet ("Max HP 144 → 168",
"Damage +20% → +30%"). The rank line reads "LV 3 → 4 / 8" or NEW / EVOLUTION; the rarity band
(Theme.Rarity) stays on top. From weapon level 6 a card says what it evolves with ("Evolves at
Lv 8 with Heart (owned)"); the passive an owned weapon needs says so too and is 1.5x likelier.
Rules: never past a max level (weapons 8, passives `MaxLevelOf`), evolutions only at max level
with the passive owned, and never a passive that changes nothing for the build (Ammo with only
melee weapons) unless it evolves a weapon you own. REROLL / SKIP show what is left this run and
what they do ("2 left · 3 new cards", "SKIP +10 GOLD · 1 left"); with none bought they say
"Buy rerolls in Upgrades".

Passive levels were merged into meaningful steps (same totals at max): Speed Boots 4 x 10%,
Cooldown 4 levels (8/15/22/30%), Area 4 levels (12/25/37/50%), Duplicator 3 x +1 (it had two
empty levels), Vacuum 3 x 50%, Luck 15/30/50%, Ammo 15/30/50% + 1 projectile, Candle
15/30/50%, Growth 12/25/40%. New passive **Fletching** (3 levels, +1 pierce each) for
projectiles that stop on a hit; it evolves the Longbow.

**Weapon perks** (behaviour changes at a level, kept when evolved):

| Weapon | Level | Perk |
|---|---|---|
| Whip | 6 | Riposte: every 3rd attack the forehand cut covers the full circle |
| Magic Orb | 5 | Splitting Orbs: an orb's first kill splits off 2 small orbs (half damage) |
| Throwing Knives | 4 | Ricochet: a knife that would stop bounces once to the nearest enemy (20 studs) |
| Garlic Aura | 4 | Chilling Aura: non-boss enemies inside move 25% slower |
| Longbow | 6 | Volley: every 3rd shot adds 2 arrows at ±12° |
| Spear | 5 | Impale: the first enemy each spear hits takes +50% |
| Crossbow | 4 | Ricochet: a bolt that would stop bounces once to the nearest other enemy |
| Frost Nova | 5 | Shatter: enemies the nova kills burst into 3 ice shards (half damage) |
| Fire Trail | 5 | Wildfire: every 3rd flame patch is 60% wider |
| Healing Totem | 5 | Rooting Pulse: every 3rd pulse roots enemies in the ring for 0.5 s |
| Chain Hook | 4 | Barbed Chain: enemies along the chain are dragged in too |
| Turret | 5 | Flak Shells: every 4th turret shot bursts for half damage around its target |
| Soul Bolt | 4 | Wandering Souls: a soul that kills its target flies on to another enemy |

**Characters** (CharacterData: Trait, Strengths, Tradeoff, Unlock), shown on CHARACTERS:

| Character | Starts with | Trait | Tradeoff | Unlock |
|---|---|---|---|---|
| Knight | Whip | Iron Skin: -10% damage taken | short reach (~7 studs) | free |
| Mage | Magic Orb | Arcane Reach: +10% area | fragile, orbs stop at the first enemy early | 10,000 gold |
| Rogue | Throwing Knives | Fleet Foot: +15% speed | knives only fly where you move | 20,000 gold |
| Priest | Garlic Aura | Blessed: +20% max HP | no reach | 30,000 gold |
| Ranger | Longbow | Steady Aim: stand still 0.8 s for +30% Longbow damage (+10% other weapons) until you move | slow shots, one direction, bonus needs standing still | achievement Queen Slayer |
| Alchemist | Fire Trail | Volatile Mix: +20% damage for burning / area weapons (Fire Trail, Frost Nova, Healing Totem, Holy Water, Garlic, Lightning) | damage stays behind you: needs to keep moving | achievement Deep Delver (reach stage 4) |
| Engineer | Turret | Tinkerer: turrets and Healing Totems last 30% longer | turrets stay where they were built; slow start | achievement Field Engineer (3 optional events) |
| Necromancer | Soul Bolt | Soul Harvest: every weapon kill has a 15% chance to release a homing soul (10 + 0.6 x level damage, x Might) | slow souls, small hits: tough single targets take long | achievement Reaper (500 kills in one run) |

**Longbow** (Ranger's weapon, also a normal weapon card for everyone): heavy arrows in the
movement direction (at the nearest enemy while standing still), range ≈ 90-125 studs, pierce
2 → 5. Damage 18 → 42, cooldown 1.70 → 1.40 s, 1 → 2 arrows. Per-target DPS L1 10.6, L8 60
(≈ 80 with Volley), evolution **Windpiercer** (needs Fletching): 52 damage, 1.25 s, unlimited
pierce, a 4-arrow volley every shot (≈ 166). Projectile mesh `Shot_Arrow` (part-built arrow
until it loads); hero mesh `Ranger` (part-built fallback with longbow and quiver). The HUD
shows a buff chip over the ability bar: "STAND STILL TO AIM" / "STEADY AIM +30% DAMAGE".

**New weapons** (WeaponData; every hero can find them on cards, the start weapons of the
three new heroes included). Per-target DPS = damage x amount / cooldown (area weapons hit
everything in range, so their number is lower on purpose; reference: Longbow 10.6 / 60 /
166, Knives 7 / 65 / 150, Death Spiral 160):

| Weapon | What it does | Lv1 | Lv8 | Evolution (passive) | Evolved |
|---|---|---|---|---|---|
| Spear | thrusts out and back in your facing direction (reach 11 x area), pierces 3 → 6 | 11.7 | 64 | Dragon Lance (Might): 3 lances, pierce all, tip bursts 60% | 140 (+ bursts ≈ 160) |
| Crossbow | fast bolts at the nearest enemies, range ≈ 80 | 8.4 | 65 | Heartseeker (Precision): 3 ricochets | 131 (+ ricochets ≈ 165) |
| Frost Nova | ice burst around you every 3.0 → 2.2 s, slows non-boss enemies to 60% | 4.0 | 13.6 | Absolute Zero (Area): huge burst, slow to 30% | 22 |
| Fire Trail | burning patches behind you while you walk (none while standing still), 0.5 s ticks, never hurts heroes | 8 | 24 | Phoenix Stride (Speed Boots): golden flames, enemies keep burning 2 s | 32 (+ ignite ≈ 40) |
| Healing Totem | plants a totem (max 1 → 2, evolved 3) that pulses: damage around it and 1 → 2.5 HP to every hero in range (no stacking between totems) | 4.7 | 18 | Lifebloom (Renewal): faster pulses, 4 HP | 32 |
| Chain Hook | hooks the furthest enemy in a 40° cone, drags it to you; 60% to everything on the chain | 7.5 | 44 (+ chain) | Reaper's Chain (Vacuum): 3 hooks | 118 (+ chain ≈ 160) |
| Turret | builds a turret next to you (max 1 → 2; the oldest is rebuilt next to you) that shoots the nearest enemy every 0.55 s | 7.8 | 62 | Bastion (Armor): fires every 0.33 s, bolts pierce 3 | 145 |
| Soul Bolt | slow homing souls; a soul whose target died seeks another | 6.4 | 65 | Soul Storm (Growth): 5 souls, pierce 3 | 153 |

New passives: **Precision** (+5 / 10 / 15% crit chance, evolves the Crossbow) and **Renewal**
(0.6 / 1.2 / 2 HP/s, evolves the Healing Totem). With 17 weapons the "new weapon" card
weight is shared (`Config.LevelUp.NewWeaponPoolRef`), so new-weapon cards are as likely as
with 9 weapons; turrets / totems have a hard cap (`Params.MaxAmount`, Duplicator stops
counting there). Projectile meshes Shot_Spear / Shot_Bolt / Shot_FrostShard / Shot_Totem /
Shot_Hook / Shot_Soul / Ability_Turret (head aims at its target) / Shot_Fire (the trail's
flames), with part-built stand-ins in ModelLibrary. Visual ids 32-63 go in the same byte
(bit 7, `WeaponData.VisualByte`). Effects that are not projectiles (nova burst, flame
patches, totem pulses, hook chains, flak / lance bursts, harvested souls) come in the
`WeaponFx` remote, flushed with the projectile sync.

**Achievements** (server-authoritative: AchievementService + AchievementData; game systems only
fire bus events: RunManager BossKilled / RunWon / PartnerRevive, StageManager BossDefeated
{ Boss } / StageCleared /
OptionalEvent (Bargain), LootSystem GoldenChest / OptionalEvent (altar); run time and level are
polled once a second). A toast shows the unlock in the run; the results screen lists the run's
unlocks; STATS → ACHIEVEMENTS shows progress bars and lets you wear earned titles and name
colours (lobby nameplate, above the hero name).

| Achievement | Goal | Reward |
|---|---|---|
| Hold the Line | survive 5:00 in one run | 100 gold |
| Unbroken | survive 10:00 in one run | 250 gold, title Unbroken |
| Queen Slayer | defeat the Scorpion Queen | **unlocks the Ranger**, 150 gold |
| Moth Bane / Banner Breaker / Hive Cleanser | defeat the Moth Matriarch / Rhino Warlord / Hive Mother | 120 gold each (+ title Banner Breaker) |
| Conqueror | clear stage 3 and leave through the portal (a win) | 400 gold, title, Gold name colour |
| Daredevil | open a Guarded Altar or clear a stage under a Bargain | 150 gold, title, Crimson name colour |
| Knight's Oath / Arcane Mastery / Shadow Run / Holy Light | clear a stage as Knight / Mage / Rogue / Priest | 100 gold each (+ Arcane / Ivory colour for Mage / Priest) |
| Lifesaver | revive teammates 3 times (total) | 200 gold, title, Moss name colour |
| Veteran | reach level 30 in one run | 200 gold, title Veteran |
| Golden Touch | open a Golden Chest | 100 gold, title Treasure Hunter |
| Deep Delver | reach stage 4 in one run | **unlocks the Alchemist**, 150 gold |
| Field Engineer | complete 3 optional events (Guarded Altars / Bargain stages, total) | **unlocks the Engineer**, 150 gold |
| Reaper | defeat 500 enemies in one run | **unlocks the Necromancer**, 150 gold |

Save schema 4 (DataService migration 3 → 4): `Achievements = { Progress, Unlocked }`, `Title`,
`NameColor`, all starting empty; gold, owned characters, skins and stats are untouched.

**Permanent upgrades** (UPGRADES → PERMANENT): each row shows the rank (LV 2/5), pips, NOW and
NEXT effect in plain words (MetaUpgradeData `Effect`), BUY with the price (gold button when
affordable, "Need N more gold" when not) or MAXED. A tap shows BUYING... until the server's
ProfileSync; `BuyMeta` carries the level the player saw, so a double tap buys one level, and a
rejected purchase re-syncs the real gold.

**Hero Mastery** (save schema 7, `MetaUpgradeData`, `Config.HeroMastery`): the six stat upgrades
(Max HP, Might, Armor, Speed, Luck, Growth) are bought per hero on the CHARACTERS screen (an owned
hero's MASTERY block → UPGRADE <HERO>), same prices and max levels as before. Each committed run gives
the hero played Mastery XP (the run's account XP, none for DEV runs); mastery level N allows stat
levels up to 2N (max mastery 10). Each hero also has a 5-level signature upgrade of its trait (500 gold,
x1.6 per level; level n needs mastery 2n). Revive / Reroll / Skip stay account-wide on UPGRADES. The v7
migration copied the old shared stat levels to every hero (Meta kept unchanged for rollback). Gold
buys these; Robux never buys stats or mastery. Server: `GoldSystem` `BuyHeroUpgrade`,
`AccountService.AwardMastery`, `RunManager` merges the selected hero's track into the run.

## Curses, Daily Challenge, leaderboards, account level

Four retention systems, all server-authoritative and cosmetic / opt-in (no pay-to-win:
nothing is sold, nothing gives run stats outside the run it belongs to). Save schema 6
(DataService migration 5 → 6, below).

**Curses** (run modifiers; data `src/shared/CurseData.lua`, server `RunModifiers.lua`,
lobby `MenuCurses.lua`). Before a run the starter toggles up to 3 on the CURSES screen
(home: the button under TRIO; portrait: next to DAILY). Each one makes the run harder for
everyone in it and adds gold (additive, shown on every card and as a total):

| Curse | Effect | Gold |
|---|---|---|
| Frenzy | normal enemies +25% speed (bosses keep their patterns) | +20% |
| Fragile | heroes -30% max HP | +20% |
| Horde | +40% live enemies and mini-wave size (the enemy cap still holds) | +25% |
| Famine | no Roast Chicken floor pickups | +15% |
| Glass Cannon | +30% damage dealt and +30% damage taken | +15% |
| Elite Surge | random elites x3 as often | +30% |

The pick is sent with `SetCurses` (validated: known ids, no duplicates, max 3; ignored in a
run) and saved (`data.Curses`, player attribute `Curses`). A run uses the curses of whoever
started it (Solo: you; Duo / Trio: the countdown's starter, who can still change them
during the countdown; joiners see them on the countdown panel and can open the screen).
They are fixed when the run starts (SwarmState `Curses` / `CurseGold`), shown as small
chips on the HUD (under the items strip), in a start toast and on the results. The gold
bonus multiplies all run gold (`GoldSystem.AddRunGold`: kills, chests, the boss, nests,
the portal bonus) and the account XP of the run. Hooks: `EnemySpawner.Spawn` (speed),
`topUp` (elites), `StageManager.SpawnMult` (horde), `XPSystem.RollFloorPickup` (famine),
the stat sheet's `Curse` input (`StatSheet.Compute`: max HP, Might, DamageTaken).

**Daily Challenge** (`CurseData.Daily(day)`, lobby DAILY card → `MenuDaily.lua`). One fixed
setup per UTC day, the same on every server: the first arena and the whole arena tour
(stage n's arena), the boss order (stage 1 is always the Scorpion Queen), 2 curses and a
starting bonus (Armory: a second weapon; Treasure: two common items; Head Start: start at
level 4; Second Wind: one extra life). Solo only; you pick your hero. PLAY sends
`StartRun("Daily")`. The FIRST daily run of the UTC day is the scored attempt and is spent
the moment it starts (quitting gives no retry); later ones are PRACTICE (unscored, normal
XP). Score = stages cleared, then time: with stages cleared, the run time when the last
boss died (faster is better); with none, the time survived (`CurseData.DailyScore`, one
integer for the leaderboard). Saved: today's score and the best ever (`data.Daily`); the
results show "DAILY · SCORED 3 stages · 9:12 · NEW DAILY BEST" or "PRACTICE".

**Leaderboards** (`LeaderboardService.lua`, lobby RANKS → `MenuLeaderboards.lua`, numbers in
`Config.Leaderboards`). OrderedDataStores `SwarmLB_BestStage` (furthest stage reached),
`SwarmLB_Daily_<UTC day>` (today's scored attempts), `SwarmLB_Kills` (most kills in one
run). Written when a run is committed: a queue keeps each player's best, flushes every 6 s,
at most one write per player and board every 30 s, `UpdateAsync` keeping the stored max,
only while the write budget leaves 3 requests in reserve, retried up to 5 times, all
pcall'd, and once more at shutdown. Read on request (`LeaderboardRequest`): the top 50 from
a cache refreshed at most every 60 s (in the background, only for boards someone looked at
in the last 3 minutes), your row highlighted, your rank when you are in the top 50, your
own best from your save otherwise. Without DataStores (Studio without API access) the
screen says so and shows this server's runs only.

**Account level** (`AccountData.lua`, `AccountService.lua`, lobby TRACK → `MenuTrack.lua`).
Every committed run gives account XP: 12 per minute survived, 50 per stage cleared, 1 per
10 kills, 40 per stage boss, 60 for a win, x the curses' gold bonus, +100 for the day's
scored daily attempt (capped at 5,000 per run). Level n → n+1 needs 150 + 50 x (n - 1) XP
(level 50 = 66,150 XP, about 120 good runs). Rewards are cosmetic only: titles (2, 10, 20,
30, 40, 50), nameplate colours (3, 12, 22, 33, 43), lobby dais rings (5, 15, 25, 35, 45:
a glowing ring under your hero on the menu dais, some with sparkles) and portrait frames
(7, 18, 28, 38, 48, 50: the hero medallion on the results and TRACK screens). The first one
of each kind is worn automatically; TRACK lists every reward with WEAR / WORN / LOCKED
(`EquipCosmetic` with "Title" / "Color" / "Ring" / "Frame", checked on the server); titles
and colours from the track also show under STATS → ACHIEVEMENTS. The level shows on the
lobby nameplate ("LV 7 Name · TITLE") and the results ("+340 XP · Level 7 → 8" with the XP
bar and any reward unlocked).

Save schema 6 (DataService migration 5 → 6): `Curses = {}`, `Daily = { Day, Used, Score,
Plays, BestScore, BestDay }` (all 0 / false), `Account = { XP = 0, Level = 1 }`, `Ring = ""`,
`Frame = ""`, `Stats.MostKills = 0`; everything else is untouched (the level track starts
for everyone from their next run). Migrate also re-validates these fields on every load.

## 1. Sync with Rojo

1. Install Rojo 7.x (the CLI and the Roblox Studio plugin).
2. In this folder (`swarm/`) run:
   ```
   rojo serve default.project.json
   ```
3. Open a new Baseplate in Studio, delete the Baseplate part, open the Rojo plugin and press **Connect**.
4. Press Play. The lobby menu appears; tap **SOLO** to start a run right away.

To make a place file without Studio: `rojo build default.project.json -o Swarm.rbxlx`.

Studio setup for saving:
- **Game Settings → Security → Enable Studio Access to API Services** (DataStores). Without it the
  game still runs, but progress is kept in memory only (the shop shows a red note) and the
  leaderboards show this server's runs only (the RANKS screen says so).
- **Game Settings → Places → Max Players**: 4 (matches `Config.Run.MaxPlayers`).

## 2. Project layout

```
default.project.json
src/shared/   → ReplicatedStorage.Shared
  Config.lua            every tunable number
  WeaponData.lua        17 weapons x 8 levels + evolutions + perks + projectile visuals,
                        card lines ("Damage 10 → 15") and which stats each behaviour uses
  PassiveData.lua       15 passives x 3-5 levels (PassiveData.MaxLevelOf)
  StatSheet.lua         the run stat sheet as a pure function + card lines for passives
  AchievementData.lua   achievements: event, goal, reward; titles / name colours, hero unlocks
  CurseData.lua         curses (run modifiers), the Daily Challenge setup and score
  AccountData.lua       account level: XP per run, the level curve, cosmetic rewards
  EnemyData.lua         enemy types (roles, behaviours, creatures, boss bodies and boss
                        objects) + per-minute spawn table
  BossData.lua          the 4 stage bosses: entrance, phases, attack timings, the rotation (data only)
  CharacterData.lua     8 characters (trait, strengths, tradeoff, unlock) + 13 skins
  ItemData.lua          19 run items (rarity, text, stacking, stat bonus), item rolls, prices
  MetaUpgradeData.lua   gold upgrades: account (Revive/Reroll/Skip), per-hero stats, signatures, mastery
  IconData.lua          upgrade icon pictures (weapon / evolution / passive id → asset id)
  Remotes.lua           creates/gets ReplicatedStorage.Remotes (server creates them at boot)
src/server/
  GameServer.server.lua bootstraps modules, runs the single Heartbeat loop
  Modules/
    RunManager.lua      lobby → countdown → run → results, HP, death, revive, characters,
                        portal wins, travel between stages
    DevTools.lua        the dev panel's commands (RunManager checks isDev first)
    StageManager.lua    the stage loop: portal, charge, Queen, surge, NEXT / RETURN, travel
    EnemySpawner.lua    enemy pool, spawning, damage, deaths, drops, boss spawn
    EnemyAI.lua         batched movement, obstacle raycasts, contact damage, behaviours
                        (ranged wind-up, lunge, fuse, burning patches)
    BossAI.lua          runs a BossData encounter (entrance, attacks, phases, twists, boss
                        objects, collapse) for all four bosses
    Hazards.lua         delayed ground strikes (circles, ring bands), fire / acid patches and
                        rolling ring waves with a gap (server-decided damage)
    BiomeHazards.lua    biome floor pools: mud / quicksand slow, ice slip, lava burn
    WeaponSystem.lua    all weapons, projectile simulation, hit detection, sync batches
    XPSystem.lua        XP gems (pooled), shared XP, floor pickups, chests
    LevelUpSystem.lua   stat sheet, level-up cards, reroll/skip, evolutions, chest rewards
    GoldSystem.lua      run gold (earning, spending at chests), lobby purchases, settings
    ItemSystem.lua      run items: grant / roll, stat bonus, crits and item procs
    LootSystem.lua      chests, Shrine of Chance, Bargain Shrine, guarded altar per stage
    DataService.lua     DataStore with session locking, retry, autosave, migration
                        (schema 6: curses, daily, account level, ring / frame)
    RunModifiers.lua    curses (SetCurses, the run's modifiers) and the Daily Challenge
    AccountService.lua  account XP / level per run, ring / frame cosmetics
    LeaderboardService.lua  OrderedDataStore boards: queued writes, cached top 50
    Events.lua          tiny server event bus (Fire / On) for achievements
    AchievementService.lua  achievement progress, unlocks, rewards, EquipCosmetic
    MonetizationService.lua  gamepasses, developer products, ProcessReceipt
    MapBuilder.lua      castle lobby (+ MenuCamera shot), the six arenas (Forest, Ruins,
                        Swamp, Snow, Desert, Lava) with their hazard pools, lighting,
                        the stage portal (spot, model, beam, rune circle, state colours)
    ModelBuilder.lua    characters, hats, enemy shells, gems, pickups, chests
    SpatialGrid.lua     20-stud bucket grid for hit detection / neighbour queries
    Fx.lua              batches visual effects into one remote call per tick
src/client/   → StarterPlayerScripts.SwarmClient
  ClientMain.client.lua starts everything, music, VIP chat tag
  CameraController.lua  fixed-angle follow camera (+ spectate when dead)
  MobileControls.lua    floating thumbstick, WASD, gamepad
  TerrainFx.lua         biome hazard feel: slippery steering on ice, breathing lava glow
  Telegraphs.lua        every enemy floor warning (circles, lanes, spokes, acid globs, eggs,
                        fire / acid patches, ring bands, dust waves with a gap, glimmer mines,
                        wind cones, emerge cracks, the banner's zone, impact bursts), pooled,
                        from the FxBatch "w" / "x" keys
  VFX.lua               projectile rendering + spin/trails/impacts, sword swings, effects, gem/pickup
                        bob, aura rings, HP bars, walk cycle + attack poses
  ModelLibrary.lua      detailed animated 3D models for every enemy, the boss and every projectile
  EnemyRenderer.lua     draws those models on the server's enemy bodies (client only)
  UIBuilder.lua         in-run screens (HUD + upgrade bar, level-up, pause, results), scaling
  StageUI.lua           portal arrow, charge ring, NEXT STAGE / RETURN TO LOBBY panel, travel fade
  LootUI.lua            items strip, item popups, chest / shrine / altar prompts, items list
  LobbyScreen.lua       the 2D lobby menu: home, characters, upgrades (§10)
  MenuCurses.lua        CURSES screen (pick up to 3 run modifiers)
  MenuDaily.lua         DAILY CHALLENGE screen (today's route, curses, bonus, PLAY)
  MenuLeaderboards.lua  LEADERBOARDS screen (Best stage / Daily / Most kills)
  MenuTrack.lua         TRACK screen (account level, cosmetic rewards to wear)
  Cosmetics.lua         portrait frames, name colours, the level badge
  ViewportPreview.lua   turning 3D character previews (ViewportFrames)
  DevPanel.lua          DEV button + tabbed tools panel, Studio only by default (§10)
  MenuArenas.lua        the ARENAS screen (§10)
  UIKit.lua             shared UI helpers, colours, upgrade icon tiles
  UIAnim.lua            UI motion: pop-ins, screen slides, punches, count-ups, button feedback
  Audio.lua             pooled sound effects + music
```

## 3. Gamepass and product IDs

Create them on the Creator Dashboard (your experience → Monetization), then paste the
numbers into `src/shared/Config.lua` → `Config.Monetization`:

| Key | What it is |
|---|---|
| `GamePasses.StarterPack` | +25% gold forever + Gold Trim skin for every character |
| `GamePasses.VIP` | +1 reroll per run, [VIP] chat tag, crown in the lobby |
| `GamePasses.DoubleGold` | 2x gold |
| `Products.Gold500/Gold1500/Gold5000` | gold packs (amounts in `ProductGold`) |
| `Products.Revive` | revive offered once per run when you fall |
| `SkinPasses.<SkinId>` | one gamepass per cosmetic skin (12) |

`0` means "not set up": the shop shows "Not set up yet" and the revive offer is skipped.
Purchases are cosmetic or convenience (gold and skins). There are no loot boxes.

## 4. Tuning difficulty (Config.lua)

| Want | Change |
|---|---|
| More / fewer enemies | `EnemyData.SpawnTable[minute].Target`, `Config.Difficulty.PlayerCountMult` |
| Tougher enemies over time | `Config.Difficulty.HPPerMinute`, `DamagePerMinute`, `SpeedPerMinute`, `MaxTier` |
| Bigger mini-waves | `Config.Spawn.MiniWaveBaseCount`, `MiniWavePerMinute`, `Config.Run.MiniWaveInterval` |
| Enemy cap (performance) | `Config.Enemies.MaxLive` (≤ `PoolSize`), `MaxLiveRanged` (Spitters) |
| Elites | `Config.Enemies.EliteChance`, `EliteHPMult`, `EliteSizeMult`, `EliteBlastMult`, `EliteFuse`, `EliteAffixes`, `Affix`; chest gold `Config.Gold.Elite`, `EliteStageScale` |
| Pacing (calm, lulls, build-up, elites, intro groups, nests) | `Config.Pacing` (`Nests`, `IntroGroupOf`), caps `Config.Enemies.MaxLiveSupport` / `MaxLiveBurrowers` |
| Boss | `Config.Boss` (HP, crowd, `First` = stage 1's boss), `BossData.lua` (entrance, phases, attack timings, `HPMult`, `Rotation`), `Config.Stages.BossHPByStage` |
| Stage difficulty | `Config.Stages.EnemyHPPerStage`, `EnemyDamagePerStage`, `SpawnTargetPerStage` |
| Portal | `Config.Stages.PortalMinDistance`, `PortalRadius`, `ChargeSeconds`, `PortalLockSeconds`, `RevealDelaySeconds`, `HintAfterSeconds` |
| XP pace | `Config.XP.Base` / `PerLevel` / `CapLevel` / `AfterCapPerLevel` (the cost curve), `CoopShare` (shared gem XP by team size) |
| Queen fight crowd | `Config.Stages.BossMinionShare`, `BossMinionMin`, `Config.Boss.MinionCapDuringBoss` |
| Surge / choice | `Config.Stages.SurgeBase`, `SurgePerStage`, `SurgeSeconds`, `ChoiceSeconds`, `TravelHealFraction` |
| What counts as a win | `Config.Stages.WinMinStages`; arena unlocks: `Config.Arenas.<name>.RequiredBestStage` |
| Arena order / biome hazards | `Config.Arenas.Order` (lobby), `Rotation`, `ShuffleRotation`; `Config.Arenas.Hazards` (Mud, Quicksand, Ice, Lava numbers, `LootPad`) |
| Leveling speed | `Config.XP.Base`, `PerLevel`, `CapLevel` |
| Gold income | `Config.Gold.KillGoldChance`, `MinPerKill`, `MaxPerKill`, `Boss`, `WinBonus`, `StageClearBonus` |
| Player survivability | `Config.Player.BaseMaxHP`, `ReviveHPFraction` |
| Run length | the players decide (portal); `Config.Run.BossTime` is no longer used |
| Camera | `Config.Camera.RunDistance`, `Pitch` |
| Items | `ItemData.lua` (per-stack values), `Config.Items` (crits, proc numbers and cooldowns) |
| Chests | `Config.Chests` (counts, `Cost`, `CostExponent`, `Weights`, `HoldSeconds`, spacing) |
| Shrines / altar | `Config.Shrines` (Chance price / odds, Bargain numbers), `Config.Guarded` (guard count, wake radius) |

## 5. Adding a weapon

1. `WeaponData.lua`: add an entry to `Weapons` (copy an existing one) and its id to `Order`.
   Fill 8 rows in `Levels` (`row(damage, cooldown, amount, area, speed, pierce, duration, knockback)`)
   and an `Evolution` with a `Passive` id and evolved `Stats`.
2. If it needs a new look, add a visual to `WeaponData.Visuals` and use its index in `Params.Visual`.
   Its `Style` (Orb, Knife, Dart, Axe, Bottle, Boomerang, Saw, Stinger, Spear, Bolt, Shard, Hook,
   Soul, Totem, Turret, Flame), `Trail` and `Impact` fields set how the client animates it; all of
   that is client-side and costs no network. Indexes 1-63 work (32+ use bit 7 of the visual byte:
   always build it with `WeaponData.VisualByte`); 12-19 stay free for enemy shots. A mesh goes in
   `ModelLibrary` `SHOT_MESH` (+ a part-built stand-in in `SHOTS`).
3. `WeaponSystem.lua`: write `Fire.<Behavior>(rp, w, s, def)` where `Behavior` matches the entry.
   Use `allocProjectile()` for projectiles (pick an existing `Kind`: Straight, Homing, Arc, Lob,
   Orbit, Boomerang, Thrust, Hook, Soul, Totem, Turret) or damage directly with `hitEnemy` /
   `damageEnemy` after a `grid():QueryCircle` lookup (never `EnemySpawner.Damage` directly:
   `damageEnemy` also runs the hero kill traits). Effects that are not projectiles go through
   `pushFx` (the `WeaponFx` remote, drawn in VFX `onWeaponFx`). Hero traits read weapon flags:
   `Area = true` (Volatile Mix), `Deployable = true` (Tinkerer); `Params.MaxAmount` caps amount.
   Level-up card text is generated from the row differences automatically ("Damage 10 → 15"):
   list the stats the behaviour really uses in `WeaponData.StatUse[Behavior]` (unused stats are
   never shown, and passives that only touch unused stats are not offered), and name the amount
   with `AmountLabel` ("Arrows"). A behaviour change at a level goes in `Perks` and is checked
   with `WeaponData.HasPerk(w, id)`.

## 6. Adding an enemy

1. `EnemyData.lua`: add an entry to `Enemies` (HP, Speed, Damage, Radius, Size, Shape/Mesh, Color,
   Gem weights, `Role`, `Intro` (the first-appearance callout), flags like `Ghost`, `Erratic`,
   `Explode` + `Fuse`, and optional behaviours `Ranged` / `Lunge` (EnemyAI)).
2. Give it weight in the `SpawnTable` rows for the minutes it should appear.
3. Client look: a mesh name in `ModelLibrary` `ENEMY_MESH` and a part-built fallback in
   `ENEMIES` (+ `LOOKS`; its low-detail variant is cut automatically); poses for its `Act` values in
   `EnemyRenderer.actPose`.
That's all: pooling, movement, elites, affixes, drops and hit flashes work for every type.
A new boss is a `BossData` entry (and `Config.Boss.Id`); new attack moves go in `BossAI`.

## 7. How the performance budget is met

- One server Heartbeat loop for everything; enemy "thinking" is split across 3 frames.
- Enemies: one anchored Part each, pooled (300), moved with a single `workspace:BulkMoveTo`.
- No Humanoids on enemies, no per-enemy scripts, no `.Touched`: hits use a 20-stud spatial grid.
- Projectiles are server data only; clients get one buffer of positions per sync tick (30 Hz)
  and draw pooled parts. Effects are batched into one remote per tick.
- Gems are pooled Parts (500); bob/spin is local to each client.
- Enemy models exist only on clients: the server still replicates one part per enemy,
  and the client always hides it (no enemy is ever drawn as that plain part). The client's
  level of detail (`EnemyRenderer`, values in `Config.Graphics`):
  - Screen culling: an enemy outside the camera view (plus `CullMargin` 6 studs, a little
    more before it leaves) has no model and costs no updates. Only bosses are never culled.
  - Detail budget among on-screen enemies: the nearest `MaxDetailedEnemies` (80) get the
    full animated model; the rest get a low-detail variant (the model's `LowDetailParts`
    (4) largest pieces, mirrored pairs kept whole, own colours, posed rigidly, no shadow).
    On slow frames the budget steps down to `MinDetailedEnemies` (40); the worst case is
    more low-detail models, never plain parts. Elites, static / support creatures,
    Burrowers and bosses are always full models.
  - Update rate: when more than `FullRateEnemies` (30) are on screen, only that many
    nearest update every frame; the rest (and every low-detail model) every 2nd frame,
    staggered. Full and low-detail models are pooled per type.

Note: `SetNetworkOwner(nil)` is only called for unanchored enemy parts. Enemy bodies are
anchored (moved by CFrame), and anchored parts are always server-owned; Roblox rejects the
call on them.

## 8. Audio

Client `Audio.lua` plays `Config.Sounds` with the mixing rules in `Config.Audio`:

- **Categories** (each its own SoundGroup under the Effects group): Combat (hits, deaths,
  lightning, explosions), Pickup (gems, chests, items, shrines), UI (clicks, toggles, tips,
  victory), Player (your swing / throw, hurt, level-up, revive, death), Warning (Bomb Tick
  fuse ticks, Spitter wind-up, Rhino lunge scrape), Boss (the Queen's roar, attacks,
  summons).
- **Priorities and limits**: at most `Config.Audio.MaxVoices` (14) effects at once and a
  per-category voice limit. A full category or mix lets a higher-priority sound steal the
  oldest lower-priority voice; lower ones are dropped. Warnings and the Queen outrank
  combat noise, and while one plays the Combat group ducks to 45% for half a second.
- **Per sound**: `MinGap` (the same sound can't restart faster), `Pitch` / `PitchVar`
  (random +/- variation), `World = true` (3D at the warning's floor spot: full volume near
  the hero, quieter far away; `Config.Audio.World` sets the roll-off).
- **Cues**: your melee swing and thrown / cast projectiles (local hero only), hit and
  death crunches (batched), gem pickups, level-up, revive, the Bomb Tick fuse (three
  ticks rising to the blast, timed to the real fuse), the Spitter wind-up, lunges and the
  Queen's telegraphs (VFX plays them for every new `Fx.Warn` entry), button clicks and
  toggles. Leaving a run stops every effect (no stray fuse ticks in the menu).
- Every effect uses a sound that ships with Roblox (`rbxasset://sounds/...`), no invented
  asset ids. To swap one for licensed audio, put `rbxassetid://<id>` in its `Id`.
- **Music slots**: `LobbyMusic` (menu), `BattleMusic` (a run), `BossMusic` (while the
  Queen's bar shows; `ClientMain` switches them). They are empty (silent) on purpose. To
  fill one: find a track you may use (Creator Store → Audio, e.g. Roblox's own free
  music, or upload your own), copy its id and set `Id = "rbxassetid://<id>"`; `Volume`
  sets its level under the Music slider.
- **Volumes**: Music and Effects sliders (Settings / pause menu) are saved in the profile
  (`Settings.Music`, `Settings.Sfx`) and applied on every join.

## 9. 3D models (Blender → Roblox)

Preview pictures of every model are in `renders/` (`renders/Sheet_*.png`).

1. Edit models in `blender/models/*.py` (enemies, heroes, items, world).
2. Build: `pip install bpy==5.0.1 pillow` (Python 3.11), then `python3 blender/build.py`
   (exports `meshes/<Category>/*.fbx`, `meshes/catalog.json` and new renders).
3. Upload (once per changed model) with an Open Cloud API key that has
   *Assets read + write* for the account that owns the game:
   ```
   ROBLOX_API_KEY=... ROBLOX_USER_ID=... python3 tools/upload_meshes.py
   ```
   This fills `meshes/uploaded_ids.json` and regenerates `src/shared/MeshCatalog.lua`.
4. Rebuild the place (`rojo build`). On start the server loads each uploaded model with
   InsertService; anything missing keeps its part-built fallback.

The stage portal (`Portal`, World category: stone ring, rune dais, membrane and glyphs
recoloured per portal state) is built and in the catalog but not uploaded yet; until it is,
`MapBuilder` uses its part-built fallback with the same look and collider.

Each model is split into pieces (one MeshPart each) that are coloured in game by "slot"
(skins and elites recolour them) and animated by the client (legs, wings, claws, tail).

## 10. Lobby screen, modes and dev tools

Whenever you are not in a run, a full-screen menu (`LobbyScreen.lua`) covers the screen;
there is no walking in the lobby (no thumbstick, lobby characters stand still, the lobby's
ProximityPrompts are switched off).

- **Home**: gold, best time and wins at the top, SETTINGS (sound, comfort, tips; see §12) top right; your own
  character turning in the middle (tap it to change character); your permanent upgrades
  summarised; the big **SOLO / DUO / TRIO** buttons and CURSES; the cards CHARACTERS,
  UPGRADES, ARENA and DAILY CHALLENGE; corner buttons SETTINGS, STATS, RANKS (leaderboards)
  and TRACK (account level). The nameplate shows your level, name and worn title.
- **Characters**: one card per character with a turning 3D preview, role, description,
  starting weapon, bonus, Buy / Select and the skins (tap a swatch to equip or buy).
- **Upgrades**: permanent gold upgrades and the Robux shop (gold and cosmetics only).
- **Camera**: if the lobby (a Model/Folder `Lobby` in workspace or in `SwarmMap`) has a part
  named `MenuCamera`, its CFrame is the menu camera; otherwise a fixed view of the spawn.

Modes (`Config.Modes`):

| Mode | Players | Start |
|---|---|---|
| Solo | 1 | at once, no countdown |
| Duo | 2 | countdown (`Config.Run.CountdownSeconds`); others tap JOIN |
| Trio | 3 | same as Duo |
| Daily | 1 | the DAILY CHALLENGE card's PLAY (fixed route / curses / bonus; see "Curses, Daily Challenge ...") |

During a countdown the lobby shows who joined; the player who started it can tap
**START NOW** once someone joined, and a full run starts by itself. Duo and Trio share the
partner-revive rules (`PartnerRevive`: 3 s next to a fallen teammate, 40% HP, 3 per player).
`Config.Run.MaxPlayers` (4) stays the hard cap; the old "Squad" (1-4) mode is still accepted
from old clients but not shown.

**Private run servers** (`RunServers.lua`, `Config.RunServers`, client `TravelOverlay.lua`).
In the published game a run never plays on the public lobby server, so anyone can start a
run whenever they like, even while others are mid-run. When a run would start (SOLO, the
Daily, a DUO / TRIO countdown ending or START NOW, a party leader's start after READY) the
lobby saves and releases each player's save, reserves a fresh private server of the same
place and teleports the whole team there in one go ("Travelling to your run…"). The run
server reads the run ticket (mode, Endless, curses, arena, members, starter, party; every
field re-checked on arrival), waits up to 15 s for the team ("Starting your run…") and
starts the run by itself; nobody else can get in. After the run (results, portal return,
MAIN MENU) a banner counts down "Back to the lobby in N s" with GO NOW / STAY; going home
saves first and teleports to a public lobby, party mates together (the party re-forms
there). If a teleport fails twice the save is taken back and the run plays on the lobby
server as before (or, coming home, the run server's own lobby keeps working). Studio, an
unpublished place and `Config.RunServers.Enabled = false` keep the old one-run-per-server
behaviour. Saves are safe across the hop: the old server writes and releases the save
before the teleport and never writes it again; the new server waits for a slow release
instead of stealing it (`DataService.ReleaseForTeleport` / `Reclaim`). Party members still
in a run when the others go home travel back on their own (no party re-form for them).

**ARENAS screen** (`MenuArenas.lua`, the ARENA card): every arena as a card with a small
painted preview of the biome, its hazard, LOCKED / UNLOCKED with the exact rule ("Reach
stage 4") and your progress toward it. Tap an unlocked arena to pick it for stage 1
(`CycleArena(name)`: the server checks the lobby phase, the name and your best stage).

**Loading**: the server loads the uploaded meshes in priority order (`MeshService`, at most
6 InsertService loads at a time): the lobby / castle kit and whatever is standing in with a
fallback first, then the heroes and hats (your own hero first), then the selected arena's
kit and the run's creatures, then the other biomes. The menu works at once; a small
"Loading models… n%" pill under the stats chip shows until the lobby and heroes are in, and
every fallback (props, previews, your lobby hero) swaps to its mesh as soon as it loads.

**DEV button** (bottom right): only in Studio by default, so it never shows in normal play.
Set `Config.Dev.ShowInLiveGame = true` to also show it to the game's creator in live servers.
It opens a tabbed panel (`DevPanel.lua`; the x folds it away):
- SAVE: *Start solo now*, **UNLOCK EVERYTHING** (+1,000,000 gold, every character, every
  achievement and its rewards, every arena, account level 50 with its rings / frames /
  titles; in Studio also every skin for the session, never saved), +gold, +account levels,
  damage numbers on / off, *Reset progress* (tap twice; purchases and settings are kept).
- RUN: +1 / +5 levels, run gold, **godmode** on / off, damage numbers, *Teleport to portal*,
  *Portal boss now*, *Next stage* (opens the portal and sends everyone on).
- MOBS: any stage boss (the portal summons it; *Normal rotation* undoes it), 5 of any enemy
  type, 1 elite of any type.
- ITEMS: *All weapons Lv 8*, *Evolve all*, any single weapon at level 8, *+3 random items*,
  any item.
The server checks the same rule again for every request and re-validates every argument
(`RunManager` "DevCommand" → `DevTools.lua`). Turn it off with `Config.Dev.Enabled = false`.

## 11. Upgrade icons

During a run your weapons (top row) and passives (bottom row) show as icon tiles at the
bottom of the screen, with an "xN" level badge and a gold border once a weapon evolves.
Level-up cards use the same icons. Until pictures exist each icon is a coloured tile with
1-2 letters. To add pictures: make square PNGs (one per weapon, evolution and passive id),
upload them as Decals/Images, and paste each asset id into `src/shared/IconData.lua`
(instructions at the top of that file).

## 12. Co-op HUD, first-run tips, results, settings, saving

**Team HUD (Duo / Trio, `TeamUI.lua`)**
- A compact row per teammate (landscape: right edge under the kill / gold counters;
  portrait: right edge under the ability bar), never Active, so a thumb on it still moves
  the hero: hero icon, name, a bar and a state word (never colour alone): health bar while
  alive, `CHOOSING` while they pick a level-up card, `DOWN · 12 m`, `REVIVING 60%` (gold
  bar), `DECIDING` (on the revive-product offer) or `OUT` (no partner revives left).
- Every revivable fallen player (teammates and you) gets a ring of segments over them that
  fills with the revive progress (so both the helper and the fallen player see it) and, in
  the world, a dashed gold circle of the revive radius (`PartnerRevive.Radius`) whose
  dashes light up with the progress. An off-screen fallen teammate gets a crimson edge
  arrow with their name and distance.
- A teammate who disconnects disappears from the list at once and everyone gets a toast
  "<Name> left the run." The level-up freeze and its "<Name> is choosing" line are
  unchanged.
- What is shared (checked in code): **XP** from gems goes to every *living* teammate
  (each scaled by their own Growth), multiplied by `Config.XP.CoopShare` for the team size
  (Duo 0.5, Trio 0.36): Duo / Trio spawn 1.6x / 2.1x the enemies and several heroes kill
  faster, so without it a duo levelled about twice as fast per player as a solo hero (and
  everyone sat through everyone's upgrade panels; `levelrate-sim`). **Gold** is per player: your kills (1-3 gold by
  chance), plus the Queen's reward paid to every living player, plus the portal bonus;
  chests and shrines spend your own run gold. **Items** are per player: a chest or shrine
  gives the item to whoever paid; the Guarded Altar gives one to every living teammate.
  The first group run shows this once as a tip.

**First-run tips (`Tutorial.lua`, `Config.Tutorial`)**: a brand-new player's first run gets
big callouts that teach through play: an icon, a bold title, one line, "TIP 2 / 5" and a big
SKIP TIPS button, placed next to what they explain with an arrow and a gold ring around it:
how to move (by device: drag / WASD / left stick; it closes early once you walk), auto
attack (the weapon row), gems are XP (the XP bar, after the first kill), the level-up cards
(one line under LEVEL UP!), the portal objective (the stage pill, after 40 s) and the
boss's red floor warnings (the boss bar). Co-op tips (once ever, also for experienced
players): team rules and "stand in the gold circle" when a teammate first falls. Each hint
shows once (saved), slides in, closes itself after ~6 s, never pauses or blocks (only SKIP
TIPS takes a tap; on short phone screens the callout moves aside so the hero stays visible)
and waits while a menu is open. Anyone with a run played before this update skips the
tutorial (schema 5 migration: `TutorialDone = Runs > 0`); the server also marks it done when
the first run ends. Settings: **Show tips** on / off, **Replay tips**.

**Results screen**: the verdict (VICTORY / ESCAPED / DEFEATED), the hero's medallion, the
arena and mode, damage dealt; tiles for time survived, enemies defeated, Queens slain (or
"Fell to her" / "Not reached"), stages cleared, gold banked and level; new best / unlocked
arena / achievements; the build (weapons with levels and evolutions, passives) and the
items found. **REPLAY** goes back to the lobby and starts the same mode again with the
existing StartRun remote (a Duo / Trio replay starts a countdown others can join; disabled
while your team still plays on through a portal). **MAIN MENU** returns. Rewards are
granted once on the server, not by this screen: gold is banked as it is earned, the
portal bonus is guarded by `rp.WinPaid` and the run stats / tutorial flag by
`rp.Committed`.

**Settings (pause menu in a run, SETTINGS in the lobby; saved in the profile and checked
by the server, `GoldSystem` SaveSettings, `Config.Settings.Defaults`)**: Music, Effects,
Screen shake (0-100%, 0 = off), Reduced effects (effect and trail budgets x
`Config.Graphics.ReducedEffectsBudget`, no hurt pulse / XP flash / breathing low-health
edge, damage numbers don't move), Damage numbers (off by default; the server sums each
player's hits per enemy 8 times a second and sends them only to players who turned them
on, at most 16 enemies per message; the client merges new hits into the number already
shown and shows at most 18, 3 new per frame; crits are gold, larger and end with "!"),
Show tips, Replay tips. Changes apply at once and are sent once shortly after the last
change.

**Saving visibility**: the server sets the player attribute `SaveStatus` (`ok`,
`failing` after a save failed all its retries, `memory` when DataStores are unavailable,
e.g. Studio without API access). The lobby then shows a small crimson-edged notice
"Progress isn't being saved right now" (top centre; over the dais in portrait), a run shows a
toast when it starts failing and the pause / settings menu repeats it; "Saving works again"
appears when a later save succeeds. Nothing pretends to save when it doesn't.

