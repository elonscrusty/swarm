# SWARM: master list of images to generate (ChatGPT prompts)

Already made, NOT in this list: the 75 icons in `art/icons` (every weapon, evolution, passive
and item, plus Gold coin, Heal, chest, shrine, altar, portal and revive) and the shop upgrades
that reuse them (Max HP, Might, Armor, Speed, Luck, Growth, Revive). Everything below is what
the game still draws with simple vector shapes, borrows from another icon, or doesn't have.

**Total: 136 images** in 17 groups. Work top to bottom: groups 1-9 matter most in play.
**New requests: 38 images** in groups 18-21 (the two new stage bosses, three small UI symbols, eleven new passives, ten new weapons and their ten evolutions; not made yet).

How to use:
1. Paste the **STYLE BLOCK** first in every ChatGPT chat (or once at the top of a chat).
2. Then paste one prompt line at a time. Ask for **one image per message**.
3. Save each image with the file name shown in bold, as PNG.
4. Put the files in the repo folders listed per section, or send them in the chat and Claude
   will place, upload and wire them in.

Rules for every image: original art only. Don't copy other games' art (no Megabonk,
Vampire Survivors, Clash or Fortnite look-alikes). No text or letters inside images unless the
prompt asks for them. No watermarks or signatures.

---

## STYLE BLOCK (paste first)

```
Style for every image in this chat: heroic low-poly fantasy game art for a Roblox game called
SWARM. Chunky low-poly 3D forms with clear flat-shaded facets, strong readable silhouette,
soft top-left light, subtle shadow, thin dark outline around the object, slightly toy-like
proportions. Palette: moss greens, cool stone greys, slate blues, crimson red, antique gold,
ivory highlights. Clean and polished, no noise or gritty textures, no heavy bloom, no text,
no watermark. Same look as a low-poly red horseshoe magnet icon with gold octahedron gems.
```

---

## 1. Hero portraits: 8 images (`art/portraits/`)

Square 1024x1024, bust portrait (head and shoulders), facing three-quarters toward the
viewer, on a plain transparent background. Each is cropped to a circle in the game, so keep the
head centred with room around it.

- **Knight.png**: brave little knight in steel plate armour, crimson cape and crimson helmet plume, round shield with a gold rim, determined smile.
- **Mage.png**: young mage in a deep slate-blue pointed wizard hat with gold trim, glowing arcane-blue orb floating by one hand, ivory beard-less face, star embroidery.
- **Rogue.png**: nimble rogue in a dark green hood and leather straps, two small daggers crossed behind the shoulder, sly grin, half-mask scarf.
- **Priest.png**: kind priest in an ivory and gold mitre and robes, holding a small glowing holy water flask, warm golden halo light behind the head.
- **Ranger.png**: sharp-eyed ranger with a feathered cap, longbow over the shoulder, moss-green cloak, quiver of arrows with red fletching.
- **Alchemist.png**: cheerful alchemist with brass goggles on the forehead, leather apron, a bubbling orange-red potion flask, small flame wisps.
- **Engineer.png**: stocky engineer with a miner's helmet and lamp, brass wrench, toolbelt, little turret blueprint scroll tucked in a pocket.
- **Necromancer.png**: hooded necromancer with a skull-shaped hood clasp, pale teal soul wisps swirling around a bony staff, dark slate and violet robes (spooky but friendly, not gory).

Locked versions are not needed: the game darkens these by itself.

## 2. Arena cards: 6 images (`art/arenas/`)

Wide 1536x864 (16:9), top-down three-quarter view of a small circular battle clearing, no
characters, readable from far away, slightly darker at the edges so text can sit on top.

- **Forest.png**: mossy forest clearing ringed by pine trees, old mossy rocks, ferns, soft sunlight, a faint rune circle in the grass.
- **Ruins.png**: sunlit ancient stone ruins, broken pillars and arches, warm light, cracked paving with grass in the gaps.
- **Swamp.png**: murky swamp clearing, brown mud pools, twisted dead trees, lily pads, green mist low to the ground.
- **Snow.png**: snowy clearing with frozen blue ice ponds, snow-capped pines, icicles on rocks, cold blue light.
- **Desert.png**: sandy desert ring with sandstone rocks, a cactus, golden quicksand swirl pits, hot orange sky light.
- **Lava.png**: volcanic arena of dark basalt with glowing orange lava pools and cracks, embers in the air, smoky red light.

## 3. Boss portraits: 4 images (`art/bosses/`)

Square 1024x1024, menacing but kid-friendly, dramatic low angle, transparent background. Used
in the boss bar, the boss banner and the results screen.

- **ScorpionQueen.png**: giant amber and black scorpion queen with a small gold crown, raised glowing green venom stinger, big pincers.
- **MothMatriarch.png**: huge moth matriarch with dusty violet and cream patterned wings spread wide, glowing pale eyes, sparkling wing dust.
- **RhinoWarlord.png**: armoured rhino beetle warlord with a massive horn, war banner strapped on its back, crimson war paint, heavy plates.
- **HiveMother.png**: bloated wasp hive mother, honeycomb-patterned yellow and black body, dripping golden honey, small wasps buzzing around.

## 4. Lobby menu buttons: 12 images (`art/icons/ui/`)

Square 1024x1024, a single bold object, transparent background, readable at 48 px.

- **ui_Play.png**: crossed sword and shield with a small burst of light behind, ready-to-battle feel.
- **ui_Solo.png**: one knight helmet, front view, gold trim.
- **ui_Duo.png**: two knight helmets side by side, one crimson plume and one blue plume.
- **ui_Trio.png**: three knight helmets in a small group, crimson, blue and green plumes.
- **ui_Characters.png**: a hero's crimson banner on a pole with a gold helmet emblem.
- **ui_Upgrades.png**: a stone anvil with a glowing gold upward arrow above it.
- **ui_Arenas.png**: a rolled parchment map with a red X and a tiny pine tree.
- **ui_Daily.png**: a stone calendar tablet with a glowing gold sun on it.
- **ui_Curses.png**: a cracked purple skull candle with a violet flame.
- **ui_Leaderboards.png**: a gold three-step podium with a crown on the top step.
- **ui_Track.png**: a winding road of stone tiles leading to a gold star.
- **ui_Settings.png**: a bronze cogwheel with a small wrench across it.

## 5. Shop upgrades still without art: 2 images (`art/icons/meta/`)

Square 1024x1024, transparent background.

- **meta_Reroll.png**: two dice mid-roll with circular motion arrows.
- **meta_Skip.png**: a gold double arrow pointing right over a scroll.

## 6. Curses and run options: 8 images (`art/icons/curses/`)

Square 1024x1024, transparent background, purple and violet accent so they read as "curse".

- **curse_Frenzy.png**: a snarling beetle head with motion lines and red eyes (enemies faster).
- **curse_Fragile.png**: a cracked glass heart (you take more damage).
- **curse_Horde.png**: a crowd of tiny beetle silhouettes spilling out of a dark portal (more enemies).
- **curse_Famine.png**: an empty cracked bowl with one breadcrumb (less healing).
- **curse_GlassCannon.png**: a small glass cannon with a crack, a glowing cannonball (more damage dealt and taken).
- **curse_EliteSurge.png**: a beetle wearing a spiky gold crown with a purple aura (more elites).
- **opt_Armory.png**: two crossed swords on a weapon rack.
- **opt_HeadStart.png**: a gold triple chevron pointing up.

## 7. Chests, XP and pickups: 6 images (`art/icons/rewards/`)

Square 1024x1024, transparent background. (The small chest and gold coin already exist.)

- **reward_ChestLarge.png**: big steel-banded chest with crimson cloth trim, closed.
- **reward_ChestGolden.png**: ornate golden chest with gems, faint golden glow.
- **reward_ChestOpen.png**: golden chest bursting open with gold light and sparkles.
- **reward_XPGem.png**: one faceted blue crystal gem, octahedron shape, light blue glow, clearly not a coin.
- **reward_XPGemBig.png**: a cluster of three blue and violet crystal gems, bigger and brighter.
- **reward_Bomb.png**: a round black bomb with a lit fuse and a gold band.

## 8. Reel and card frames: 5 images (`art/ui/frames/`)

Square 512x512, a decorative frame border only, transparent centre and background, so icons
sit inside. Same shape, different colour and ornament per rarity.

- **frame_Common.png**: plain stone-grey frame with simple bevel.
- **frame_Uncommon.png**: moss-green frame with small leaf corners.
- **frame_Rare.png**: slate-blue frame with silver corner studs.
- **frame_Epic.png**: deep violet frame with glowing arcane corner runes.
- **frame_Legendary.png**: antique gold frame with crown corners and a soft gold glow.

## 9. Hero class badges: 8 images (`art/icons/heroes/`)

Square 1024x1024, transparent background, just the headgear, front view, readable at 32 px.
Used on small tabs, achievement rows and stats.

- **hero_Knight.png**: steel knight helmet with a crimson plume.
- **hero_Mage.png**: slate-blue pointed wizard hat with gold stars.
- **hero_Rogue.png**: dark green hood with a dagger crossing behind it.
- **hero_Priest.png**: ivory and gold mitre with a small sun emblem.
- **hero_Ranger.png**: green feathered cap with a red feather.
- **hero_Alchemist.png**: brass goggles with orange lenses.
- **hero_Engineer.png**: yellow miner's helmet with a glowing lamp.
- **hero_Necromancer.png**: dark hood with a skull clasp and teal glowing eyes.

## 10. Arena badges: 6 images (`art/icons/arenas/`)

Square 1024x1024, transparent background, a small round emblem per arena (for buttons and
pills; the big arena cards are group 2).

- **arena_Forest.png**: a pine tree on a mossy rock.
- **arena_Ruins.png**: a broken stone arch.
- **arena_Swamp.png**: a dead twisted tree over a mud puddle.
- **arena_Snow.png**: a snowy pine with an icicle.
- **arena_Desert.png**: a cactus beside a sandstone rock.
- **arena_Lava.png**: a black rock split by glowing lava.

## 11. Achievements: 15 images (`art/icons/achievements/`)

Square 1024x1024, transparent background, each on a round bronze medal so they read as awards.

- **ach_Survivor5.png** (Hold the Line, survive 5 min): a shield with a bronze clock face.
- **ach_Survivor10.png** (Unbroken, survive 10 min): a cracked but standing shield with a silver clock face.
- **ach_QueenSlayer.png** (beat the Scorpion Queen): a sword through a small gold scorpion crown.
- **ach_Conqueror.png** (clear stage 3 and win): a gold banner planted on a hill beside a glowing portal.
- **ach_KnightClear.png** (clear a stage as the Knight): crossed sword and shield behind a knight helmet.
- **ach_MageClear.png** (as the Mage): a wizard hat with an arcane rune circle.
- **ach_RogueClear.png** (as the Rogue): two crossed daggers in a dark hood shadow.
- **ach_PriestClear.png** (as the Priest): a mitre with golden light rays.
- **ach_Veteran.png** (reach level 30): three gold chevrons with a laurel wreath.
- **ach_FieldEngineer.png** (3 optional events): a wrench crossed with a key over a small altar.
- **ach_Reaper.png** (500 kills in one run): a scythe over a pile of tiny beetle shells.
- **ach_MothBane.png** (beat the Moth Matriarch): a torn moth wing pinned by an arrow.
- **ach_WarlordFall.png** (beat the Rhino Warlord): a snapped war banner and a broken horn.
- **ach_HiveCleanser.png** (beat the Hive Mother): a cracked honeycomb with a sword through it.
- **ach_Badge.png** (the Achievements tile and tab): a gold trophy cup on a medal.

## 12. Track (account level) rewards: 5 images (`art/icons/track/`)

Square 1024x1024, transparent background.

- **track_Title.png**: a ribbon scroll banner (title reward).
- **track_Color.png**: a paint palette with five fantasy colours (name colour reward).
- **track_Ring.png**: a glowing gold ring on the ground (dais ring reward).
- **track_Frame.png**: an ornate square portrait frame (frame reward).
- **track_Level.png**: a round gold medal with a star (account level).

## 13. Shop (Robux: cosmetics and coins only): 4 images (`art/icons/shop/`)

Square 1024x1024, transparent background. No Roblox logo (the game draws the Robux sign itself).

- **shop_GoldPouch.png**: a leather pouch overflowing with gold coins.
- **shop_StarterPack.png**: a wrapped gift box with a crimson ribbon and a gold coin tag.
- **shop_VIP.png**: a gold crown on a velvet cushion.
- **shop_DoubleGold.png**: two stacked gold coins with a glowing "x2" shape made of light (no letters needed, two coins is fine).

## 14. Stats tiles: 9 images (`art/icons/stats/`)

Square 1024x1024, transparent background, simple and bold (shown at 32 px).

- **stat_BestTime.png**: a gold stopwatch with a crown.
- **stat_Wins.png**: a gold victory laurel wreath.
- **stat_Runs.png**: a small flag on a path.
- **stat_WinRate.png**: a rising bar chart made of stone blocks.
- **stat_Kills.png**: a cracked beetle shell.
- **stat_Gold.png**: a stack of gold coins.
- **stat_Heroes.png**: three small hero helmets in a row.
- **stat_Skins.png**: a sparkling cloth swatch with a needle.
- **stat_Upgrades.png**: an anvil with a sword on it.

## 15. Big screens: 5 images (`art/screens/`)

- **logo_SWARM.png** (2048x1024, transparent): the word **SWARM** in chunky carved gold-and-stone fantasy letters, crimson shadow, a few beetles and wasps flying around the letters. (This one should have text.)
- **loading.png** (1920x1080): the little knight standing on a mossy rock at dusk, facing a huge incoming swarm of beetles, wasps and moths on the horizon, castle silhouette behind. Leave the bottom third calm for a loading bar.
- **victory.png** (1920x1080): the knight raising a sword on a pile of defeated (cartoon, not gory) beetles, golden light rays, confetti-like gold sparkles.
- **defeat.png** (1920x1080): the knight's helmet and sword lying in the grass at dusk, beetles crawling away, moody slate-blue light, sad but not scary.
- **results_bg.png** (1920x1080): soft blurred castle courtyard at dusk with torches, very dark, for behind the results panel.

## 16. Roblox store page (not in-game): 4 images

- **store_Icon.png** (512x512): the knight's face with a determined look, a swarm of bugs behind him, bright and bold, readable as a tiny phone icon. No text.
- **store_Thumb1.png** (1920x1080): action shot from above: the knight in a forest clearing slashing a sword arc through a huge ring of beetles, blue XP gems everywhere, gold coins flying.
- **store_Thumb2.png** (1920x1080): four heroes (knight, mage, ranger, necromancer) side by side facing the Scorpion Queen boss.
- **store_Thumb3.png** (1920x1080): a golden chest bursting open with weapon icons and gold flying out, the knight cheering.

## 17. Small UI symbols (lowest priority): 29 images (`art/icons/ui/`)

These are drawn crisply by code today; images only help if they match the style better.
Square 512x512, transparent background, ONE flat bold symbol each, ivory with a thin dark
outline and a tiny gold accent, no scene, readable at 20 px.

- **sym_play.png**: right-pointing triangle.
- **sym_pause.png**: two vertical bars.
- **sym_close.png**: an X.
- **sym_check.png**: a check mark.
- **sym_warning.png**: an exclamation mark in a triangle.
- **sym_info.png**: a lower-case i in a circle.
- **sym_lock.png**: a padlock.
- **sym_gear.png**: a cogwheel.
- **sym_music.png**: a music note.
- **sym_speaker.png**: a speaker with sound waves.
- **sym_calendar.png**: a calendar page.
- **sym_clock.png**: a clock face.
- **sym_hourglass.png**: an hourglass.
- **sym_cycle.png**: two circular arrows (reroll).
- **sym_skip.png**: double right chevrons (skip).
- **sym_chevronsUp.png**: three up chevrons.
- **sym_arrowFast.png**: an arrow with speed lines.
- **sym_person.png**: one person silhouette.
- **sym_people2.png**: two person silhouettes.
- **sym_people3.png**: three person silhouettes.
- **sym_userPlus.png**: a person silhouette with a plus.
- **sym_podium.png**: a three-step podium.
- **sym_trophy.png**: a trophy cup.
- **sym_crown.png**: a crown.
- **sym_medal.png**: a medal on a ribbon.
- **sym_flag.png**: a waving flag.
- **sym_skull.png**: a cartoon skull.
- **sym_sparkle.png**: a four-point sparkle star.
- **sym_curse.png**: a purple flame over a skull.

## 18. New requests: the two new stage bosses, 4 images

Not made yet. Until they exist the boss bar shows the plain full-width bar (no portrait
disc) and the achievements show a drawn sprout / frost icon. Same STYLE BLOCK.

Boss portraits (`art/bosses/`): square 1024x1024, menacing but kid-friendly, dramatic low
angle, transparent background (like group 3).

- **BriarSentinel.png**: a towering bramble treant guardian, bark body wrapped in thorny crimson-dark vines, a moss mantle on its shoulders, a carved bark mask with glowing amber eyes under a crown of thorns, long branch arms with twig claws, a few crimson berries and small gold blossoms, roots splitting the ground at its feet.
- **FrostboundColossus.png**: a hunched giant of dark blue-grey stone with pale ice crystals jutting from its shoulders and back, a small head sunk between the shoulders with glowing pale-blue eyes and an icicle beard, huge fists bound in antique gold bands, frost mist at its feet.

Achievement medals (`art/icons/achievements/`): square 1024x1024, transparent background, on
a round bronze medal (like group 11).

- **ach_BriarBane.png** (Briar Bane, beat the Briar Sentinel): a sword cutting through a coil of thorny vines with a small crimson berry.
- **ach_Frostbreaker.png** (Frostbreaker, beat the Frostbound Colossus): a hammer shattering a block of pale blue ice, shards flying.

When these come in: upload them, regenerate ArtData, and switch the two achievements' Icon
in `src/shared/AchievementData.lua` to `ach_BriarBane` / `ach_Frostbreaker` (adding both to
the ART_FALLBACK list in `src/client/Icons.lua`). The boss portraits are picked up by id.


## 19. New requests: three small UI symbols, 3 images (`art/icons/ui/`)

Not made yet; the game draws these with code today. Same STYLE BLOCK, same format as group 17:
square 512x512, transparent background, ONE flat bold symbol, ivory with a thin dark outline
and a tiny gold accent, no scene, readable at 20 px.

- **sym_heart.png** (health on the HUD and results): a chunky heart with a small gold highlight.
- **sym_castle.png** (MAIN MENU button on pause and results): a small castle gatehouse with two towers and an arched door.
- **sym_aim.png** (auto-aim / target buff on the HUD): a round crosshair target with four ticks and a gold centre dot.

When these come in: upload them with `tools/upload_icons.py`, run `tools/gen_icon_data.py`, and
map the keys `heart`, `castle` and `aim` to them in `src/client/Icons.lua`.

## 20. New requests: eleven new passives, 11 images (`art/icons/`)

Not made yet; the game draws these with code today. Same STYLE BLOCK, same format as the
passive icons in `art/icons` (see `docs/ICON_LIST.md`): square 512x512, transparent
background, ONE chunky low-poly object centred, no text, readable at 40 px. Save each file
under the passive's id.

- **GiantsBane.png** (Giant's Bane, more damage to elites and bosses): a heavy steel great-axe #D5DCE3 with a dark wooden haft #9A7752, a small antique gold crown #D5B062 knocked askew beside the blade.
- **Thornhide.png** (Thornhide, hit back when struck): a round moss-green hide buckler #648A47 ringed with sharp ivory thorns #E5DCC7 pointing outward, a lighter green boss in the middle.
- **BloodRune.png** (Blood Rune, critical hits heal): an upright cool grey rune stone #858A91 with two carved rune strokes, a glossy crimson drop #C9443F set in its face.
- **AegisCharm.png** (Aegis Charm, a ward blocks one hit): a small antique gold shield-shaped amulet #D5B062 on a short gold chain, a pale slate-blue gem #8DA1B7 glowing in its centre.
- **Windstep.png** (Windstep, speed burst after a kill): three curling pale slate-blue wind streaks #B8C5D3 sweeping right, ending in a bold gold forward chevron #E5C988.
- **GildedPurse.png** (Gilded Purse, more gold): a plump brown leather coin purse #8A5A3B tied with a gold cord, a few antique gold coins #D5B062 spilling from its mouth.
- **Stoneskin.png** (Stoneskin, take less damage): a chunk of stacked grey stone plates #A7ABB0 fitted like armour scales, one thin crack, a faint ivory edge highlight.
- **SecondWind.png** (Second Wind, level-ups heal): a curling pale slate-blue gust of wind #B8C5D3 wrapping around a soft glowing green plus sign #B9DE8E.
- **EmberOil.png** (Ember Oil, hits may burn): a round slate glass flask #8DA1B7 filled with glowing orange oil #E58A45, a small flame dancing on its cork.
- **Lionheart.png** (Lionheart, more damage at low health): a chunky crimson heart #C9443F wearing a small antique gold crown #E5C988, a short golden mane-like flare behind it.
- **StillWaters.png** (Still Waters, stand still to heal): a single glossy pale-teal water drop #8FD1C8 resting on calm slate-blue ripples #8DA1B7, a small soft green plus sign #B9DE8E glowing beside it.

When these come in: upload them with `tools/upload_icons.py`, then run `tools/gen_icon_data.py`
(the ids already match `PassiveData`, so the pictures replace the drawn icons automatically).

## 21. New requests: ten new weapons and their evolutions, 20 images (`art/icons/`)

Not made yet; the game draws these with code today. Same STYLE BLOCK, same format as the
weapon and evolution icons in `art/icons` (see `docs/ICON_LIST.md`): square 512x512,
transparent background, ONE chunky low-poly object centred, no text, readable at 40 px. Save
each file under the weapon's (or evolution's) id. Evolutions are the same object made grander,
gilded or glowing, so the pair reads as one family.

Weapons:
- **WardShields.png** (Ward Shields, shields circle you): a round cool steel shield #BCC3CB with a darker steel cross and rim #67707B and a small antique gold boss #D5B062, a second small shield floating at its top right.
- **Earthsplitter.png** (Earthsplitter, a crack of stone spikes): three jagged grey stone spikes #9EA2A7 bursting up out of a short strip of brown earth #A0815E, a dark crack running between them, two pebbles flying.
- **Starfall.png** (Starfall, meteors on crowds): a glowing orange-red meteor #D9542A with a molten amber core #E9B941 diving from the top left, a short flame tail #E58A45 behind it.
- **Sling.png** (Sling, stones that bounce): a dark leather sling #6E4C33 with two cords and a cupped pouch, a round grey stone #9EA2A7 flying out of it to the top right.
- **PlagueCenser.png** (Plague Censer, a drifting poison cloud): a small brass censer ball #D5B062 hanging from a short chain, a puffy sickly moss-green cloud #7E9F58 billowing from it.
- **Sawblade.png** (Sawblade, a saw that grinds crowds): a round toothed steel saw blade #D7DCE1 with eight chunky teeth and a dark steel hub #67707B, a thin ivory edge glint.
- **VineSnare.png** (Vine Snare, roots enemies): two thick moss-green thorny vines #648A47 curling up out of a small ring of earth, ivory thorns #E5DCC7 and two fresh leaves #A3B784.
- **WarHorn.png** (War Horn, a booming blast): a curved ivory war horn #C9BEA6 with two antique gold bands #D5B062 and a dark wooden mouthpiece #654832, two pale sound arcs out of its bell.
- **SpiritWisps.png** (Spirit Wisps, darting spirits): three small glowing pale-blue wisps #DCEAF7 with short curling tails circling a faint ring, each with a bright ivory core #F3EDDF.
- **Vortex.png** (Vortex, a rift that drags enemies in): a flat two-armed spiral of soft arcane blue light #9DB8E3 swirling into a small bright ivory core #F3EDDF.

Evolutions:
- **AegisRing.png** (Aegis Ring = Ward Shields + Aegis Charm): a gilded round shield #D5B062 with an ivory boss #F3EDDF, three small gold shields orbiting it on a thin glowing ring.
- **Worldbreaker.png** (Worldbreaker = Earthsplitter + Stoneskin): three tall black basalt spikes #433E42 with glowing lava cracks #F29A45, bursting from cracked ground.
- **Cataclysm.png** (Cataclysm = Starfall + Ember Oil): three golden-white meteors #E5C988 of different sizes raining down at an angle, amber flame tails #E9B941.
- **Giantfeller.png** (Giantfeller = Sling + Giant's Bane): the leather sling #6E4C33 hurling a big antique gold stone #D5B062 with two small crimson impact marks #C9443F.
- **Pestilence.png** (Pestilence = Plague Censer + Candle): the brass censer with a darker, larger green cloud #535F41 to #A3B784 and a small ivory skull shape #E5DCC7 in the fumes.
- **Ruinwheel.png** (Ruinwheel = Sawblade + Thornhide): a crimson saw blade #C9443F with antique gold teeth and hub #D5B062, a faint gold ring around it.
- **Strangleroot.png** (Strangleroot = Vine Snare + Growth): dark green vines #52763D with crimson thorn buds #DB6A5E, twisting tighter around a ring of earth.
- **TitansRoar.png** (Titan's Roar = War Horn + Lionheart): a golden war horn #E5C988 with crimson bands #C9443F inside two full amber shockwave rings #F6DA7E.
- **WispChoir.png** (Wisp Choir = Spirit Wisps + Luck): five warm golden wisps #F0DDB0 with ivory cores circling a bright centre.
- **Singularity.png** (Singularity = Vortex + Vacuum): a deep dark slate spiral #26323F with arcane blue arms #9DB8E3 around a black core rimmed in antique gold #E5C988.

When these come in: upload them with `tools/upload_icons.py`, then run `tools/gen_icon_data.py`
(the ids already match `WeaponData`, so the pictures replace the drawn icons automatically).

---

When images come back, Claude can resize, check and upload them. Uploads go through
`tools/upload_icons.py`, which needs Open Cloud asset upload access. Claude then wires them
into the game (portraits, arena cards, boss bar, menu buttons, reel frames), so nothing shows
as working until it's really connected.
