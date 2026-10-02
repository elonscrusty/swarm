# SWARM art direction: heroic low-poly fantasy

The visual rebuild of SWARM. Gameplay, balance, progression, multiplayer and saving stay exactly
as they are; everything you can see changes. This brief is the shared target for models, world,
effects and UI. Colours: `art/palette.json` (generated into `src/shared/Palette.lua`, read by
Blender through `blender/style.py`). Semantic tokens for the game: `src/shared/Theme.lua`.

## 1. The look in one paragraph

A cohesive, professionally art-directed Roblox game: chunky low-poly forms with strong
silhouettes, clean flat-shaded materials and restrained texture. A brave little knight in a mossy
forest clearing full of old stone ruins, fighting a swarm of beetles, wasps and moths. Moss greens,
cool stone grays and slate blues set the world; crimson and antique gold mark heroes, banners and
rewards; ivory is the text and the light. Soft sun, subtle shadows, controlled contrast. The menu
is a castle courtyard at dusk lit by torches.

Avoid: neon grass, noisy tiled textures (Grass/Slate/Cobblestone materials on big surfaces),
random rainbow buttons, heavy bloom, glowing everything, decorative clutter in the play space.

## 2. Palette (see art/palette.json for every value)

| Family | Use |
|---|---|
| moss_900..100 | grass (500 base, 600/400 patches), canopies (700/800), pines (800/900), ferns |
| stone_900..100 | rocks, ruins, castle walls (500/600), paving (400/300), shadows (800) |
| slate_950..200 | UI panels (900/800), roofs, blue banners (600), cool accents, night sky |
| crimson_900..300 | knight cape/plume/shield, banners, health, danger, boss |
| gold_900..200 | trims, crowns, coins/XP gems, primary button, borders (500), highlights (300) |
| ivory_100..500 | all UI text (100 primary, 300 secondary), bone/horn, cloth highlights |
| wood_*, dirt_*, leather_* | fences, barrels, posts, paths (dirt_500/600), straps |
| steel_* | armour (400 main, 600 shade, 300 edge), blades (300/200) |
| beetle_*, amber_*, wasp_*, moth_*, tick_*, chitin_* | creatures only (they must pop off the grass) |
| fx_* | effects: slash ivory, sparks gold, heal green, arcane blue, holy white, fire, bolt |

Value plan for readability from the top-down camera: ground is a mid value (moss_500), props one
step darker or lighter, creatures have dark legs/undersides (chitin) and a brighter shell than the
grass, heroes carry the brightest whites (steel/ivory) and the strongest colour (crimson/gold).

## 3. Materials and shading

- SmoothPlastic for almost everything; colour does the work (wood, stone, cloth, leaves).
- Metal only for armour plates and blades (small surfaces).
- Neon only for small glowing bits: eyes, flames, gem cores, magic cores. Never a big surface.
- Glass/transparency for wings and flasks (piece `transparency=`), sparingly.
- Flat shading (faceted), bevelled blocks (bevel 0.06-0.2), tapered forms. Big shapes first,
  then 2-3 levels of detail. No greebles that vanish at gameplay distance.
- Colour variation by piece (two or three tones per material), not by texture.

## 4. Proportions and silhouettes

The gameplay camera looks down at about 55° from 60+ studs away. Design for the TOP view:
helmets, hats, shoulders, shells, wings and weapons are what players see.

### Heroes (6-part rig, see blender/models/heroes.py)
- Heroic chunky proportions: head + headgear about 30% of height; shoulders/pauldrons wider than
  the hips; short sturdy legs; oversized hands, weapons and shields. 6.4-7.2 studs tall with
  headgear. Feet at y = 0. HumanoidRootPart (2x2x1 at y = 3) and HipHeight 2 do not change.
- Rig: six bone pieces named Torso, Head, LeftArm, RightArm, LeftLeg, RightLeg; gear pieces name
  their `bone`. Move the joints to fit the body with `m.extra["joints"]` (Neck, LeftShoulder,
  RightShoulder, LeftHip, RightHip; hips stay at y = 2).
- Slots that skins recolour: Metal (main armour / headgear), Cloth (main fabric), Cloth2
  (secondary fabric / legs), Accent (cape, plume, scarf, trims), Gold (trim). Design so recolours
  still look good. The bare `Head` piece is plain; helmets/hats/hoods are separate Head-bone
  pieces (a skin with its own hat removes them).
- Knight: steel plate (steel_400/600), great helm with a dark T visor and a crimson plume,
  crimson cape with gold trim, crimson kite shield with gold rim and cross, steel longsword with a
  gold guard. The reference hero.
- Mage: slate-blue robes and a wide-brim pointed hat with a gold band, ivory beard, wooden staff
  with a small arcane crystal, leather belt and satchel.
- Rogue: moss-green hooded cloak, leather armour, crimson scarf mask, twin steel daggers.
- Priest: ivory robes with a gold stole, mitre, sun staff in gold, small book; warm and bright.

### Creatures (client-drawn pieces; origin = ground centre, front = -Y in Blender)
Each type owns a hue so it reads in a swarm; all have dark chitin legs/undersides for contrast.

| id (DisplayName) | Size (studs) | Read |
|---|---|---|
| Slime (Mite) | 2.8 wide, ~2 tall | the grunt: round yellow-green beetle shell, dark head, amber eyes, 6 short legs. Cheapest model (<= 350 tris, <= 5 pieces). |
| Bat (Wasp) | 2.6 span, flies | gold and black stripes, translucent ivory wings flapping, stinger. |
| Skeleton (Beetle Warrior) | 2 wide, 4.2 tall | upright armoured beetle soldier, dark green carapace, horned helm, steel blade/spear. |
| Ghost (Phase Moth) | 3.2 span, floats | pale grey-lavender moth, translucent wings with slate eye-spots, faint glowing core. |
| Brute (Rhino Beetle) | 4.6 wide, 5 tall | heavy slate-blue armoured beetle with a big ivory horn. |
| Bomber (Bomb Tick) | 2.4 | bloated crimson tick with glowing amber spots (pulse) that say "explosive". |
| Boss (Scorpion Queen) | 12 | crimson carapace with antique-gold plates, huge claws, segmented tail with an amber stinger. |

Animated pieces use the runtime keys: SwingA/SwingB (legs/arms), FlapL/FlapR (wings), Jaw
(claws/mandibles), Tail, Spin, Wiggle, Pulse, Flicker, with a pivot at the joint. One or two big
body pieces per creature get `shadow=True`. Budgets: grunts <= 450 tris, mid <= 900, boss <= 3500.

### World kit
Trees (pine tiers, chunky round broadleaf), boulders and slabs, shrubs, ferns, grass tufts,
flowers, ruins (broken walls, pillars, an arch, fallen blocks), wooden fences, banner on a pole
(slate blue with a gold crown), torch post, lantern post, barrel, crate, fallen log, stump,
small forest mushrooms (in tree shade only). Castle pieces for the menu scene: crenellated wall,
round tower, gate arch with portcullis, wall banner (crimson with gold crown), wall torch,
brazier, round two-step stone dais. Props <= 700 tris, castle pieces <= 1500.

## 5. Gameplay environment rules (the forest arena)

- Same arena: 400 x 400 play square, Config.ArenaOrigin, boundary walls, ClearRadius 40 around
  the spawn, obstacles registered in the existing Circle/Box format. Navigable area and obstacle
  coverage must stay within about 10% of the previous builder (measure it).
- Decoration never collides: CanCollide/CanQuery/CanTouch off, not in the obstacle folder. Only
  deliberate obstacles (tree trunks, boulders, ruin walls) collide, each with one simple collider.
- A designed layout, not a uniform scatter: an open central clearing, natural dirt paths, a few
  landmarks (ruined arch, shrine with banner, standing stones, lantern post), prop clusters at
  edges and around landmarks, a dense tree line outside the boundary. Deterministic (fixed seed).
- Keep combat areas open and readable. Tall props stand in groves and outside the boundary; the
  south side (camera side) stays low. Big canopies near the player fade out (client occlusion)
  so they never hide the player, enemies, attacks or pickups.
- Subtle ground variation: large moss patches in two or three tones, dirt paths with soft edges,
  stones along paths; the walkable floor itself stays flat.
- Phone budget: anchored, CastShadow off on small clutter, about 600 MeshParts + 400 Parts max.

## 6. Lighting

- Gameplay: bright, clear late-morning sun; soft shadows (ShadowSoftness ~0.4); moderate
  contrast; a light atmosphere for depth; bloom low (Intensity <= 0.3, high threshold).
- Menu: dusk courtyard; cool slate-blue sky and ambient, warm torch and brazier pools around the
  dais; atmospheric haze; the hero is the brightest thing on screen.

## 7. Effects

Restrained and informative: ivory/pale-gold slash arcs, small gold sparks on hits, a white hit
flash on enemies, soft heal sparkles, short thin projectile trails, gold XP gems with a tiny pop
when collected, a gold ring under the local player (slate-blue rings under teammates). Effects
must not cover the arena; keep alpha low, lifetimes short, sizes modest.

## 8. Interface system

- Panels: slate_900 at ~8% transparency, 10 px corners, 1.5 px antique-gold border at ~55%
  transparency, soft drop shadow. Text ivory_100 (primary) / ivory_300 (secondary).
- Typography: Merriweather (Bold/Heavy) for titles, names and button titles; Source Sans for
  body, labels (upper case, letter-spaced feel) and numbers. Sizes: Theme.TextSize.
- Buttons: one primary action per screen in antique gold (gold gradient, dark text, gold glow);
  everything else dark slate with ivory text and gold icons. States: hover lifts and brightens,
  press scales to 0.96, disabled desaturates (stone_500), selected gets a strong gold border.
- Icons: one consistent set (vector shapes, ivory/gold), same stroke weight and size grid.
- Spacing on a 4 px grid (Theme.Space); 48 px minimum touch targets; device safe areas.
- Main menu (reference image): logo top-left; stats chip (best time, wins, gold) top-right;
  left column of feature cards (Characters, Upgrades, Arena); centre: the hero on the lit dais in
  the 3D scene; bottom-centre nameplate with character arrows; right column SOLO (primary gold),
  DUO, TRIO; bottom-left Settings and Stats. Countdown/queue replaces the mode column. Portrait
  stacks: logo, hero, nameplate, modes, cards.
- HUD: timer top-centre; health and level/XP plate under it; pause top-right; kills/gold small;
  weapons and passives as an ability bar bottom-centre with level badges; boss bar under the
  timer. Clear of the thumbstick.
- Development controls only in Studio (or when Config.Dev.ShowInLiveGame is on).

## 9. Do not change

Gameplay numbers and rules: Config sections other than Camera/UI/Graphics/visual parts of
Arenas/Lobby, EnemyData stats (HP, Speed, Damage, Radius, Size, Gem...), WeaponData numbers,
PassiveData values, hitboxes, remotes and their validation, saving, monetization behaviour.
