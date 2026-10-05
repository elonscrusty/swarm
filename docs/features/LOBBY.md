# LOBBY: weapon mastery, photo mode, courtyard

Wave 2 of the 30-features batch (features 15, 29 and 30). All three are cosmetic or
lobby-only. None of them changes damage, drops, XP, gold or what a run gives you, and
none of them can be bought. Each one has its own switch in `Config.Features`. When a
switch is `false`, the game behaves as it did before that feature existed, and
`lobby-regression` checks this.

| # | Switch | Modules | Tuning |
|---|---|---|---|
| 15 | `WeaponMastery` | `src/server/Modules/WeaponMastery.lua`, `src/client/WeaponMastery.lua`, kill hook `WeaponSystem.OnKill`, tint hook `VFX.SetMasteryColor` | `Config.WeaponMastery` |
| 29 | `PhotoMode` | `src/client/PhotoMode.lua` (one line in UIBuilder's results footer), `HeroPoses.Shared.Cheer` | `Config.PhotoMode` |
| 30 | `LobbyFun` | `src/client/LobbyFun.lua` (client only) | `Config.LobbyFun` |

How to reach them: on the MORE screen, the **WEAPON MASTERY** and **COURTYARD** rows appear only
while their switches are on. The **PHOTO** button sits in the results footer, next to STAY and
REPORT A BUG.

## 1. Weapon mastery (15)

- **Counting kills:** the server counts every weapon kill into the save field `WeaponMastery`
  (`{weaponId → kills}`).
  - `WeaponSystem` remembers which weapon's hit it is resolving: the fire call, each projectile,
    pool, Fire Trail patch, ignite, and the delayed sword swing and horn blast. `OnKill`
    listeners get `(rp, weapon, enemy)`.
  - Kills from item procs aren't counted, and neither are kills on a DEV-tainted run.
  - A count stops at `MaxCount`. A new weapon only gets a key while the field holds fewer than
    `Config.Data.Caps.WeaponMastery` keys.
- **Milestones** (`Config.WeaponMastery.Milestones`):

  | Kills | Unlocks |
  |---|---|
  | 250 | Bronze Glow |
  | 1,000 | Silver Glow |
  | 3,000 | Gold Glow |
  | 8,000 | Arcane Glow |

  - Each milestone is earned for **that weapon** only.
  - Crossing one during a run shows a quiet notice, for example "Sword: Bronze Glow unlocked".
  - The milestones are registered in `CosmeticData` as `Trail` entries with `Source = "Earned"` and
    `Weapon = true`.
  - The server works out ownership from the kill counts. Nothing is written to
    `Cosmetics.Owned`.
- **Choosing a glow:** the WEAPON MASTERY menu has one row per weapon. Each row shows the
  weapon's kills, the next milestone, and swatches for its own colour plus each glow. A locked
  swatch shows a lock, and tapping it says how many kills it needs.
  - A tap sends `SetMasteryGlow(weaponId, 0..4)`. The server checks the weapon, the index and
    the kills.
  - The choice is saved **in the same field** as `"Glow:<weaponId>" → milestone`. There's no new
    save field and no schema change, and `DataService.CleanFeatureFields` keeps these keys like
    any other count.
  - Choosing 0 removes the key and puts the weapon back to its own colour.
- **Drawing the glow:** only on your own screen, and only on your own effects.
  - Every sword slash you make takes the colour.
  - A projectile trail takes the colour in a solo run. In co-op it only does when the shot
    appears within 4.5 studs of your hero, because the projectile sync carries no owner.
  - Turret bolts and other shots that start away from the hero are only tinted in solo.
  - Non-projectile effects (pools, auras, novas) keep their own colours.
- **The store:** STORE's bought "trails" (`StoreCatalog`) are hero trails worn in the
  `Cosmetics.Equipped.Trail` slot. They're a different thing from these weapon glows, and the
  mastery glows never use that slot. If the owner later wants to sell weapon glows, add a store
  entry and a colour, and have `WeaponMastery.SetGlow` accept owned store glows.

## 2. Photo mode (29)

- **Entering:** PHOTO in the results footer holds the results, just like STAY, so nothing
  closes automatically. Then:
  - Every other ScreenGui is switched off.
  - Your real hero is hidden on your screen only (`LocalTransparencyModifier`).
  - An anchored, non-colliding copy (`PhotoMode.CloneHero`) stands on the same spot.
  - The camera circles it slowly (`OrbitSpeed`).
- **The control bar:**
  - **POSE** cycles HEROIC (the lobby stance), CHEER (`HeroPoses.Shared.Cheer`) and RELAXED
    (idle breathing).
  - **ORBIT** turns the circling on and off.
  - **FRAME** cycles none, gold, crimson and frost border overlays.
  - **EXIT** leaves photo mode.
- **Taking the picture:** after `HintSeconds` with no input, the bar fades so the screen is
  clean, and the player takes the screenshot with the device. A tap brings the bar back. A tap
  on empty space while the bar shows exits, and so do Esc and B.
- **Leaving:** leaving the run (`InRun` goes false) exits at once and restores everything.
  Nothing is uploaded or saved.

## 3. Courtyard (30)

- **Where it is:** a play area behind the menu camera, between z +48 and +112 from
  `Config.Lobby.Origin`. The camera sits at about z +15.5 and looks toward −Z, so the title
  shot can't see it.
  - The courtyard is built on your client only when you enter and destroyed when you leave.
    The title screen pays nothing for it.
  - It has 21 parts plus the hero copy, under `MaxParts` (80). All are anchored and none
    cast shadows.
- **Walking:** the menu GUIs hide and your lobby character moves to `Spawn`.
  - The stick, WASD and the gamepad move it, using a local `WalkSpeed`. The server keeps lobby
    characters at 0 and doesn't check lobby movement.
  - A follow camera uses the run camera's angle, so the stick directions match.
  - **BACK**, Esc or B puts you back by the dais with the menu. A run starting while you're in
    the courtyard closes it.
- **Training dummy:** shows the selected hero's starting weapon at level 1, for example "about
  7 damage a second". The number comes from `WeaponData` and `StatSheet` with the hero's bonus,
  for one target, with no upgrades, items or crits. While you stand within 14 studs, it shows a
  hit number every `DummyHitEvery` seconds.
- **Cosmetics mirror:**
  - A copy of your selected hero in its worn skin stands on a pedestal in front of a mirror.
  - A board lists what you wear: hero and skin, title, trail, burst, pet, plate, dais, and how
    many weapons wear a glow.
- **Jump pads:** a gold pad throws you straight up (`LaunchSpeed`) and you steer onto the next
  platform. There are four platforms, and the last one is gold, with a flag.
  - The clock starts on the first pad and stops on the top platform.
  - Landing back on the courtyard floor ends the try. Falling out of the world puts you back at
    the start, and a try longer than `MaxSeconds` is dropped.
  - The best time is kept **for this session only**. It's never saved and never sent to the
    server, so there's no leaderboard to cheat.

## Tuning

- `Config.WeaponMastery`: `Milestones` (kills, id, name, colour), `MaxCount`, `EquipRate`.
- `Config.PhotoMode`: `Poses`, `PoseNames`, `OrbitSpeed`, `Distance`, `Height`, `AimHeight`,
  `FieldOfView`, `Frames`, `HintSeconds`.
- `Config.LobbyFun`: `Spawn`, `WalkSpeed`, `CameraDistance`, `Dummy`, `DummyHitEvery`, `Mirror`,
  `Course` (`Start`, `Platforms`, `LaunchSpeed`, `PadRadius`, `PadCooldown`, `FinishRadius`,
  `FallY`, `MaxSeconds`), `Floor`, `MaxParts`. Course positions are studs from
  `Config.Lobby.Origin`. Keep everything at z > +45 so it stays out of the title shot.

## Verified and blocked

Verified offline (Lune preview), with my files at zero type-check diagnostics:

- `lobby-regression` passes every check:
  - Sword and orb kills are credited to the right weapon.
  - DEV taint and the switch off both stop counting.
  - A milestone crossing sends one notice. The cap and `MaxCount` hold.
  - `SetMasteryGlow` validation works, and the glow survives `Migrate`.
  - The client tint is correct in solo and co-op, and off with the switch off.
  - Photo mode: the button, hiding the GUIs, the hero copy, the orbit, the frame and the fade,
    and both exits.
  - Courtyard: the dummy DPS for all 11 heroes, the course clock (launch, finish and best, fail,
    reset, timeout), the build on entry, the part count, the position behind the camera, BACK,
    a run start, and the switch off.
- Renders:
  - `photo-mode` on pc and phone.
  - `lobby-fun` on pc and phone.
  - The `menu` title screen on pc and iphone, compared with HEAD; see the report for the
    numbers.

BLOCKED (needs Studio or a device):

- How the glows look on real effects.
- Whether a humanoid really launches from the pads at `LaunchSpeed` and lands on the platforms.
  The air control is the run's.
- The courtyard's touch stick on a phone.
- Taking a real device screenshot in photo mode.
- How the mirror's glass looks.
