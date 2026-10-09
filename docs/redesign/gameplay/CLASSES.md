# SWARM redesign: the four class kits

> Continuation pack (2026-10-09): the weapon rows below (Level 1 / Level 12 / Evolution) are the old
> 12-level system. With `RunConfig.Builds.Enabled` the signatures run on ranks 1-5 with the brief's
> numbers, names (Scrap Shot, Toast Toss) and evolutions (Junkyard Cyclone, Toaststorm, Bubble Torrent,
> Knitting Nightmare): see `BUILDS.md`. Another class's signature can be found by a player who owns that
> class (weapon behaviour only). The kit passives below are stream C's to retune.

Spec: `DESIGN.md` section 6. Code: `src/swarmv2/server/Run/ClassRegistry.lua`, `ClassKits.lua`,
`src/swarmv2/shared/Run/ClassRoster.lua` and `RunConfig.lua` (section `Classes`, every kit number),
weapon rows and evolutions in `src/shared/WeaponData.lua`, behaviours in
`src/server/Modules/WeaponSystem.lua` (`Fire.ScrapToss`, `Fire.ToastVolley`, `Fire.BubbleBomb`,
`Fire.YarnBomb`). Offline check: `render.sh class-kits-sim --studio` (all PASS), not Studio-tested.

| | Ruckus (`ruckus`) | Toastmaster (`toastmaster`) | Captain Croak (`captain_croak`) | Granny Boom (`granny_boom`) |
|---|---|---|---|---|
| Price (gold) | 0 | 10,000 | 20,000 | 30,000 |
| Model (category Classes) | `Ruckus` | `Toastmaster` | `CaptainCroak` | `GrannyBoom` |
| Signature weapon (id) | Scrap Toss (`ScrapToss`) | Toast Volley (`ToastVolley`) | Bubble Bomb (`BubbleBomb`) | Yarn Bomb (`YarnBomb`) |
| Level 1 | 10 dmg, 0.9 s, 1 scrap, 1 bounce | 7.5 dmg, 0.65 s, 1 slice, 1 ricochet | 11 dmg, 1.2 s, 1 bubble, 1 bounce, burst radius 7 (60% damage to others) | 12.5 dmg, 1.4 s, 1 bomb, blast radius 8, throw range 34 |
| Level 12 | 23 dmg, 0.6 s, 3 scraps, 3 bounces | 12.5 dmg, 0.46 s, 3 slices, 3 ricochets | 24 dmg, 0.85 s, 3 bubbles, 3 bounces, burst x1.3 | 26 dmg, 0.9 s, 3 bombs, blast x1.3 |
| Evolution (needs weapon L12 + partner passive rank 3 or max) | Junkyard Barrage (`JunkyardBarrage`) + Gilded Purse: 32 dmg, 0.5 s, 4 scraps, 5 bounces, each bounce +15% damage | Double Decker (`DoubleDecker`) + Ember Oil: 18 dmg, 0.42 s, 4 slices, 4 ricochets, burnt-toast look | Tidal Burst (`TidalBurst`) + Area: 34 dmg, 0.75 s, 3 bubbles, 3 bounces, burst hits for 100% (not 60%), giant bubble look | Grand Knitwork (`GrandKnitwork`) + Duplicator: 36 dmg, 0.75 s, 4 bombs, blast x1.5 |
| Base stat (class bonus) | +25% pickup radius | +10% max HP | +10% XP | +10% area |
| Signature upgrade (hero mastery, 5 levels) | Scavenger +25% (+4%/level) | Sturdy Casing +10% (+3%/level) | Quick Study +10% (+2%/level) | Big Boom +10% (+3%/level) |
| Passive | **Loot Rush**: every 5 chest / shrine / merchant / encounter item pickups (not XP gems) load 1 Scrap Barrage (max 1 stored; pickups while full do not count). The next Scrap Toss volley adds a ring of 8 scraps (0 bounces, full weapon damage) | **Overheat**: 3 Toast Volley hits on the same enemy within 4 s set it burning for 3 s: 20% of the slice damage every 0.5 s. Refresh only, a burn never stacks | **Big Splash**: a leap landing with a living enemy within 10 studs empowers the next bubble: x1.8 damage, burst radius x1.4 (the first bubble of that volley). Max 1 stored | **Tangled Up**: a yarn explosion tangles every enemy it hits (and does not kill): 0.75 s at 35% slower. Bosses 0.3 s at 15%. An enemy takes at most 1.5 s of tangle per 3 s. A stronger slow already on the enemy is never weakened |
| Movement reaction | Dash drops 2 rolling cans (to the sides, behind the dash): explode after 0.8 s, radius 6, 1.2x Scrap Toss damage, at most 6 live per player | Spring jump (apex 12, movement helper). Landing blast after >= 0.35 s in the air: radius 8, 1.0x Toast Volley damage, 2 s cooldown | Dash is a leap (31 studs, movement helper); the landing triggers Big Splash | Rocket Boost (80 / 0.25 s / 3 s): leaves a fire patch every 4 studs for 0.35 s after the boost starts: radius 3, 1.4 s, 0.6x Yarn Bomb damage per 0.4 s |
| Hat / look fallback | Beanie, slate fur, red scarf | Tophat, steel and toast | Miner hat, green and brown | Hood, pink knit |

## Rules

- Each signature weapon is `ClassOnly`: it is in `WeaponData.ClassOrder`, not in `Order` or
  `HeldOrder`. `LevelUpSystem.AddWeapon` refuses it for any other class (`WeaponData.AllowedFor`) and
  the level-up pool only lists the player's own class weapon. The class starts with its weapon
  (`CharacterData.Characters[id].StartWeapon`).
- Every derived hit is `NoProc` (dealt with `isProc = true`: no crit, no item procs, kill procs do not
  chain): ricochet / bounce hits after the first, bubble bursts, cans, burn ticks, landing blast, scorch
  patches. Direct hits and the yarn explosion itself are normal hits. The tangle deals no damage.
- The projectile pool is shared (`Config.Projectiles.PoolSize`); a barrage or can that finds the pool
  empty just fires fewer.
- Numbers: kit and roster numbers only in `RunConfig.Classes`. Weapon rows (12 levels), `Params`
  (radii, visuals) and evolutions stay in `WeaponData` because they are weapon data like every other
  weapon.
- Old heroes: removed from `CharacterData.Order` at boot (hidden everywhere that lists heroes), their
  `Characters` entries and all save data stay. A run whose selected hero is an old one plays `ruckus`
  (`RunConfig.Classes.MapLegacyToDefault`). `CharacterData.Default` becomes `ruckus` at boot.
- Models: `CharacterData` entries carry `MeshName` ("CaptainCroak" ...). Until `MeshCatalog` has the
  entries `ModelBuilder` builds the generic part-built fallback (same rig, slot colours, hat).
- HUD attributes on the player (server-set, UI only): `ClassKit` (`LootRush`, `Overheat`, `BigSplash`,
  `TangledUp`), `ClassCharge` 0..1, `ClassReady` boolean, `ClassStored` whole number.
- Dash hooks (`Dash.OnDash(rp, kind, dir)`, `Dash.OnLeapLanded(rp)`, `Dash.OnLanded(rp, airtime)`):
  `ClassKits.Init` chains onto them when `Run/Dash.lua` exists. Without Dash the reactions simply never
  fire; `ClassKits.OnDash`, `OnLeapLanded` and `OnLanded` can also be called directly.
