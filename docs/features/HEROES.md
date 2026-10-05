# HEROES: three new heroes earned by play (feature 11)

Wave 2 of the 30-features batch. The switch is `Config.Features.NewHeroes`. When it is off,
the three heroes are taken out of `CharacterData.Order` and `CharacterData.Characters`, so
every screen, check and save works exactly as before. A saved unlock is never removed.
There's no save schema change: a hero is owned through `OwnedCharacters[id] = true`, the
same as every other hero.

## The heroes

| | Archer | Bard | Golem |
|---|---|---|---|
| Role | Quick shooter | Team booster | Stone tank |
| Start weapon (existing) | Crossbow | War Horn | Earthsplitter |
| Signature (trait) | **Quick Draw**: -10% weapon cooldown (-20% at signature 5) | **Rally Song**: allies within 22 m deal +12% damage (+22% at signature 5); the Bard itself gets 60% of that (+7%, also when alone) | **Stone Body**: +25% max HP (+40% at signature 5), +1 armor, 10% slower |
| Second skill (mastery rank 5) | Eagle Eye: +1 pierce | Encore: +10% luck | Rock Spines: a hit on you also hurts enemies around you for half its damage (thorns 0.5) |
| Ultimate | Bolt Barrage (x1.1 damage, Arrows look) | Battle Hymn (x0.85 damage, heals you and allies in range for 15% max HP, Nova look) | Landslide (x0.95 damage, 2 s no damage, big knockback, Quake look) |
| Unlock (earned by play) | 10,000 gold | 20,000 gold | 30,000 gold |
| Price tier used | the Mage tier (10k) | the Rogue tier (20k) | the Priest tier (30k) |
| Store early unlock | `Config.Monetization.HeroUnlocks.Archer = 0` | `HeroUnlocks.Bard = 0` | `HeroUnlocks.Golem = 0` |
| Mesh (uploaded) | `Archer` 115789672564709 | `Bard` 127501319863180 | `Golem` 127125027530641 |
| Part-built fallback | ModelBuilder.ClassGear.Archer, hat Plume | ClassGear.Bard, hat Cap | ClassGear.Golem, hat Horns |

- **Unlocking:** each hero is bought with gold on the Characters screen, using the
  existing `BuyCharacter` path and the existing price tiers. No new tier was invented.
- **Early unlock with Robux:** `Config.Monetization.HeroUnlocks` holds developer products
  with `Id = 0`, so the Store shows "Coming soon". STORE (`StoreService`, `StoreCatalog`) wires
  the purchase, which sets the same `OwnedCharacters` flag as gold. The owner creates the
  three products in Creator Dashboard, chooses the price and pastes the ids
  (docs/features/STORE.md). This is allowed under the rules, because every hero can also
  be earned by play.
- **Each hero's own trait upgrade:** `MetaUpgradeData.Signature` adds Archer, Bard and
  Golem, using the same 5 levels and costs as the other heroes.

## Rally Song (server)

`src/server/Modules/HeroSong.lua` (in GameServer ORDER and STEPS) recomputes every 0.25 s
from server positions only:
- **Song value:** each living Bard who hasn't returned through the portal and isn't waiting
  for a revive sings at the Signature trait value `v`.
- **Teammates:** each living teammate within `Song.Radius` gets `v`.
- **The Bard itself:** it gets `v x Song.SelfShare`, so a solo Bard still has a smaller buff.
- **Two Bards:** every player keeps the best single value; two Bards don't stack.
- **Damage:** `WeaponSystem.weaponStats` multiplies weapon damage by `1 + rp.SongBuff`
  (one line). The ultimate, souls and thorns don't use it.
- **Pauses:** while the run is paused, frozen or travelling, the values are kept.
- **Switch off:** with the switch off, everything is 0.
- **HUD:** the player attribute `SongBuff` (a whole percent) drives the client badge
  `src/client/HeroSong.lua`, a FeatureHud badge that reads "SONG +12%". It is cleared after
  the run.
- **Pulse:** every `Song.Pulse` seconds, a gold `Fx.Ring` (an existing effect) pulses
  around the Bard.

## Tuning

- **Prices:** `CharacterData.NewHeroes[id].Cost`. Keep to 10000 / 20000 / 30000.
- **Traits:**
  - Archer: `Bonus.cooldown`.
  - Golem: `Bonus` (`maxHpMult`, `armor`, `speed`).
  - Bard: `Song = { Radius = 22, SelfShare = 0.6, Pulse = 4 }`.
- **Signature levels:** `MetaUpgradeData.Signature.<id>` (Base / Per in whole percent).
  The Bard's song value is its `Trait`.
- **Second skills / ultimates:** `CharacterData.SecondSkills`, `CharacterData.Ultimates`.
- **Meshes:**
  - Build: `blender/models/heroes3.py`, then
    `python3 blender/build.py --only Archer,Bard,Golem --samples 12`.
  - Upload: `ROBLOX_USER_ID=20194281 python3 tools/upload_meshes.py --only Archer,Bard,Golem`,
    then `python3 tools/gen_mesh_catalog.py`.
  - Each mesh uses the same rig, slots and colours as its CharacterData entry.

## Balance check (econ-sim, offline)

Method:
- The scene is the audit's scratch `econ-sim`, copied onto this tree in `scratchpad/heroes/econ/repo`.
- Run settings: fresh profile, greedy shop, 5 stages, seeds 1-5. The ultimate and second
  skill are off, so only the hero traits differ.
- Each row averages 5 seeds.
- "Taken/min" is damage taken per minute in stages 1-3. "Lethal" counts would-be deaths in
  stages 1-5. "TTK" is the average normal-enemy kill time, and "Boss s" is the stage 1-5
  boss-phase time.
- Gold and cleared stages are unaffected (fixed explore time).

| Hero | Taken/min S1-3 | Lethal S1-5 | Min HP S1-3 | TTK normal s | Boss phase s | Kills | Seeds |
|---|---|---|---|---|---|---|---|
| Knight | 87 | 3.4 | 39% | 1.12 | 58 | 6326 | 5 |
| Archer | 252 | 21.2 | 20% | 1.40 | 64 | 6456 | 5 |
| Bard | 183 | 9.2 | 20% | 1.40 | 74 | 5672 | 5 |
| Golem | 97 | 2.8 | 38% | 0.90 | 62 | 6934 | 5 |

How to read it:
- **Golem:** within the Knight's range.
- **Archer and Bard:** they take about 2-3x the Knight's damage. Part of that is that they
  have no defensive trait, while the Knight takes 10% less damage. Their weapons also clear
  more slowly than the Sword (TTK 1.40 s vs 1.12 s).
- **Baseline missing:** the gold-hero runs (Mage, Rogue, Priest) were stopped at the lead's
  request, so it's still unknown whether Archer and Bard sit inside the existing heroes'
  range. That check is **BLOCKED** until wave 3.
- **Bard balance:** the econ-sim bot is solo, so the Bard only shows its 7% self buff.
- **Tuning if wave 3 confirms the gap:** Archer `Bonus.cooldown` 0.10 → 0.15; Bard
  `SelfShare` 0.6 → 0.8.

Logs: `scratchpad/heroes/econ/out/<Hero>_s1..5.log`.

## Files

- **Shared:**
  - `CharacterData`: the `NewHeroes` / `NewHeroOrder` table and `SetNewHeroes(on)`, plus
    Ultimates and SecondSkills entries.
  - `MetaUpgradeData`: Signature entries.
  - `Config`: `Monetization.HeroUnlocks`.
- **Server:**
  - `HeroSong.lua` (new).
  - `WeaponSystem`: 3 lines.
  - `GameServer`: 2 lines.
  - `ModelBuilder`: ClassGear for Archer, Bard and Golem; the Golem's stone arms; Archer
    and Bard are gloved.
- **Client:**
  - `HeroSong.lua` (new), with one init line in `ClientMain`.
  - `Icons.CharacterIcon`: a `HERO_DRAWN` map shows the existing `Crossbow`, `music` and
    `Stoneskin` icons until the owner's `hero_<Id>` pictures exist.
- **Art:**
  - Code: `blender/models/heroes3.py`.
  - Exports: `meshes/Heroes/{Archer,Bard,Golem}.fbx`, `meshes/catalog.json`,
    `meshes/uploaded_ids.json`, `src/shared/MeshCatalog.lua`.
  - Renders: `renders/Heroes/{Archer,Bard,Golem}.png`.
- **Docs:**
  - This file.
  - `docs/ICON_CHECKLIST.md`: hero icon, portrait and SONG badge lines.
    `tools/gen_icon_checklist.py` now holds the rows the feature helpers added (a
    regeneration used to drop them) and reads `HERO_DRAWN`.
- **Tests:**
  - `tools/preview/scenes/heroes-regression.luau` (new; solo, plus `--set coop=on`).
  - `mastery-regression` checks the three new signatures.
  - `characters --set owned=all` owns them too.

## Verified vs BLOCKED

- PASS (offline Lune):
  - `heroes-regression`:
    - data, tiers, store keys and meshes
    - gold unlock (refused without gold, bought once)
    - start weapons and traits
    - solo song: self share, damage factor, server recompute, badge cleared
    - switch off: hidden, not buyable, selection falls back, unlock kept
  - `heroes-regression --set coop=on`: mate in and out of range, no stacking, a dead Bard
    gives no song.
  - Existing scenes: `mastery-regression`, `heropower-regression`, `math-regression`,
    `data-regression`, `progression-regression`, `storage-sim`, `security-regression` and
    `lobby-screens-regression`.
  - `check.sh --quick`.
  - Layout checks with 0 problems: `characters` on iphone and phone-portrait.
  - Meshes built, uploaded and in MeshCatalog.
  - Renders: lobby (Bard) on pc; Characters on pc and iphone.
  - econ-sim: Knight and the 3 new heroes, 5 seeds each.
- BLOCKED:
  - econ-sim range check against Mage, Rogue and Priest: the runs were stopped (see the balance check).
  - Studio, real phones and live servers.
  - The Robux early unlock: the products don't exist yet (Id 0), so it shows "Coming soon".
  - How the new meshes look in Roblox lighting.
  - Owner pictures (portraits and class icons): fallbacks are shown until they exist.
