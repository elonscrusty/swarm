# HEROPOWER: hero ultimate (13), second signature skill (12), build presets (14)

Wave 1 of the 30-features batch. Each part has its own switch in `Config.Features`
(`Ultimate`, `SecondSkill`, `BuildPresets`). With a switch off, the game plays exactly as before.
There's no save schema change.

## 13. Hero ultimate (`Ultimate`)

Each hero has one big move that clears the screen. Charge comes from kills, and the move fires with
the round **ULT** button above JUMP (FeatureHud slot), the **Q** key or gamepad **R1**.

| Hero | Ultimate | Extra | Drawn with (existing effects) |
|---|---|---|---|
| Knight | Valor Quake | no damage for 1.5 s, big knockback | two rings, ground-pound burst, blast |
| Mage | Starfall | survivors slowed 50% for 3 s | 8 explosions, ring |
| Rogue | Blade Storm | x1.15 damage, smaller ring | 6 sword slashes, ring |
| Priest | Holy Nova | heals self and allies in range for 25% max HP (x0.8 damage) | rings, holy pool, heal flash |
| Ranger | Arrow Rain | x1.1 damage, wider ring | 12 dust bursts, ring |
| Alchemist | Firestorm | x1.1 damage | 9 explosions, ring |
| Engineer | Overcharge | | lightning strike + chain arcs to targets |
| Necromancer | Soul Reap | heals 10% max HP | chain arcs to targets, glimmer burst, ring |

- **Server** (`src/server/Modules/Ultimate.lua`):
  - Charge = own kills since the last use / `KillsToCharge`, and also at least `Cooldown` run
    seconds since the last use. Kills made by the ultimate never feed the next charge.
  - The `UseUltimate` remote has no arguments and is rate-limited by `Remotes.Listen` (`Rate`).
  - Before firing, the server checks: switch on, run running *and* simulating (not paused,
    frozen or travelling), alive, not downed, not returned, not choosing a card or reward,
    full charge.
- **Damage** = `min(Cap, Base + PerLevel x (level - 1))` x hero factor x Might (Might counted
  up to `MaxMight`). Each enemy in `Radius` takes it once as proc damage (no crits, no item
  procs).
  - Elites, altar guards, mini-bosses, nests and boss objects take at most `EliteShare` of
    their max HP.
  - Bosses take at most `BossShare` (6%), so the move never kills a boss outright.
  - Elites with a shield lose the shield first.
- **Client** (`src/client/Ultimate.lua`) reads three player attributes: `UltCharge` (0..1),
  `UltHero` and `UltUsed`, a counter that triggers the announcement "VALOR QUAKE!". It also
  starts `HeroPresets`.
- **Characters screen:** an ULTIMATE block with the move's name and one line.

### Tuning (`Config.Ultimate`)
`KillsToCharge` 150, `Cooldown` 45, `Radius` 42 (the Bomb pickup clears 75), `Base` 40,
`PerLevel` 8, `Cap` 480, `MaxMight` 2.5, `EliteShare` 0.4, `BossShare` 0.06, `Knockback` 18,
`Rate` 2. Per-hero factors and extras are in `CharacterData.Ultimates`.

### Balance check (econ-sim, offline)
Method: the audit's scratch `econ-sim` scene, copied onto this tree in
`scratchpad/hp-econ/repo`. Settings: Knight, fresh profile, greedy shop, 5 stages, seeds
1-5. The bot fires the ultimate **the moment it is charged**, so these numbers are an upper
bound on its effect. Each row averages 5 seeds.

ECON_TABLE

## 12. Second signature skill (`SecondSkill`)

Each hero gets a second small passive. It's free and never sold, and it's on in every run once
that hero's Hero Mastery reaches `Config.SecondSkill.Rank` (5 of 10). It uses the mastery data
that already exists (`data.Heroes[hero].XP`), so there's no new save field.

| Hero | Skill | Bonus |
|---|---|---|
| Knight | Shield Wall | +1 armor |
| Mage | Quick Study | +8% XP |
| Rogue | Keen Edge | +5% crit chance |
| Priest | Mending | +0.5 HP/s |
| Ranger | Far Sight | +20% pickup radius |
| Alchemist | Slow Burn | +10% duration |
| Engineer | Spare Parts | -5% cooldown |
| Necromancer | Dark Pact | +6% damage |

- `RunManager.newRunPlayer` sets `rp.Meta.SecondSkill = 1`, and `StatSheet` adds
  `CharacterData.SecondSkills[hero].Bonus`.
- The Characters screen shows SECOND SKILL with "Unlocks at mastery rank 5." or "Unlocked: on in
  every run with this hero."
- New heroes (wave 2) get their own entry. Until then they have no second skill, and the
  ultimate falls back to the Knight's.

## 14. Build presets (`BuildPresets`)

- **Marking favourites:** on Characters, an owned hero has a FAVOURITES button that opens a
  grid of every released weapon and passive. Tap one to mark or unmark it; a marked one gets
  a gold edge and ★.
- **Saving:** server `BuildPresets.lua` (remote `SetPreset(hero, "Weapons"|"Passives", id, on)`)
  validates the hero, the kind and the id, and caps each list at `Caps.PresetPicks` (12).
  It stores one entry per hero in the `Presets` save field.
- **In a run:** level-up cards whose id is a favourite of the selected hero get a small
  "★ Favourite" pill in the top-right corner. The hook is one line in `UIBuilder` makeCard,
  `HeroPresets.Tag`. Offers and weights are never touched: `LevelUpSystem` doesn't read
  presets at all.
- **Cap change:** `Config.Data.Caps.Presets` went from 6 to 12, one list per hero for the 8
  heroes plus 3 new ones. Only the cap value changed, not the save shape.

## Files
- **Server:** `Ultimate.lua` and `BuildPresets.lua` (new). They're wired into `GameServer` ORDER and STEPS.
- **Client:** `Ultimate.lua`, `HeroPresets.lua` and `MenuHeroPower.lua` (new). `ClientMain` runs one init line.
- **Hooks into existing code:**
  - `MenuCharacters`: one require, the block built inside the mastery block, one refresh line.
  - `UIBuilder`: two lines in makeCard.
  - `RunManager`: the second skill (4 lines).
  - `StatSheet`: 4 lines.
- **Shared:** `CharacterData` (Ultimates, SecondSkills, helpers), `Config` (Ultimate,
  SecondSkill, BuildPresets, Caps.Presets), `Remotes` (UseUltimate, SetPreset).
- **Scenes:**
  - `heropower-regression` (new).
  - `characters --set favourites=open` and `levelup --set fav=on` (new options).
- **Docs:** `docs/ICON_CHECKLIST.md` has two lines (ULT is a text button, ★ is text; owner
  art for the ultimates is optional).

## Verified vs BLOCKED
- PASS (offline Lune):
  - `heropower-regression`: second skill rank gate and switch; ultimate refusals (lobby, no
    charge, cooldown, paused, dead, switch off), crowd cleared, out-of-range enemy untouched,
    boss cap 6%, elite survives, own kills don't recharge, remote path, attributes
    cleared, Priest heal; preset validation, caps, one list per hero, clean-stable, switch off.
  - `check.sh --quick`: no diagnostics in HEROPOWER files.
  - Layout checks: `characters favourites=open` on iphone and phone-portrait, `levelup fav=on`
    (see the report).
- BLOCKED:
  - Studio, real phones and live servers: no session access.
  - Feel of the ULT button on touch.
  - Visual read of the ultimates in Roblox (the offline renderer draws the Fx batch only
    roughly).
  - The "★" glyph in Roblox fonts.
