# Show weapon evolutions early (switch `EvolutionPreview`)

## What
Players can see what a weapon evolves into, and what it still needs, long before it is ready.
Built on the existing card hint line ("Evolves into X with Y Lv N"); with the switch on, that
line is replaced, so there is never a second line.

- **Weapon cards** (NEW and upgrade, every level, not only from `EvolveHintLevel` on): the
  evolved weapon's small icon at the left of the hint plate, then the recipe with live progress,
  e.g. `Bloodblade: Sword Lv 12 + Heart Lv 3 (you: Heart 1)`. The progress part reads
  `(you: no Heart)`, `(you: Heart 1)`, `(Heart done)` or `(ready!)`. The plate turns bright gold
  once this pick makes the evolution ready.
- **Ingredient passive cards** (the partner passive of a weapon you own and have not evolved):
  `Needed for Bloodblade (Heart Lv 3)`, with the evolved icon.
- **BUILD panel** (HUD BUILD button, B / gamepad Y): a new EVOLUTIONS section after PASSIVES
  lists every evolution the build can reach, i.e. each owned weapon not yet evolved, plus each
  owned passive whose released weapon you could still take (while a weapon slot is free).
  Each row shows the evolved icon and name, the recipe (`Sword Lv 12 + Heart Lv 3`), `READY` or
  `1 / 2` parts done, and `Missing: Sword Lv 9 → 12, Heart Lv 1 → 3` (or `Heart Lv 3 (not
  owned)`, `Sword (not owned)`). Ready ones come first. It refreshes with every Inventory
  update, so it changes right after a pick.

Data only: `src/shared/EvolutionPreview.lua` reads `WeaponData.Weapons[id].Evolution` and
`PassiveData` and uses the same rule as `LevelUpSystem.canEvolve` (weapon at
`WeaponData.MaxLevel`, partner passive at min(3, its max level)). No new combining system.
The server writes the card text (`LevelUpSystem` decorate: `Hint`, `HintReady`, `EvoIcon`,
`EvoName`); the client draws the icon (`UIBuilder` `Choice.hintPlate`) and the BUILD list
(`Hud` `refreshDetails`).

Text fit: the longer hint shrinks to fit inside its plate (wraps on tall cards, one line on
portrait cards); BUILD rows wrap and the list scrolls.

**Owner decision needed (discovery):** the old hint hid the evolution's name and an
undiscovered partner passive behind "???" (DiscoveryService). This feature exists to show
evolutions early, so with the switch on the names are always shown. Switch it off to get the
discovery-gated hints back.

## Config
- `Config.Features.EvolutionPreview = true` (false: the old hints exactly as before, no icon,
  no EVOLUTIONS section)
- No new numbers.

## Owner steps
1. Decide whether showing evolution names right away (instead of "???" until discovered) is
   what you want; if not, switch the feature off.
2. Studio playtest: take a weapon, look at its card line and the BUILD panel's EVOLUTIONS
   section; pick the partner passive and check that the progress changes.

## Regression
Registered in `tools/run_regressions.py` under `# batch B group B`:

- `evolution-preview-regression` (real server, Solo run): every released weapon maps to its
  own evolution; weapon card carries the evolved icon, name and `Recipe (you: no Heart)`; a NEW
  weapon card shows its evolution; the ingredient passive card says `Needed for ...`; after real
  picks through `LevelUpChoose` the line reads `you: Heart 1`, then `Heart done`, then `ready!`;
  the BUILD list names the missing weapon level, an evolution whose weapon is not owned, and
  puts a ready one first with nothing missing; switched off the old hint returns.
- `layout-evolution-panel-regression-{iphone,phone-portrait,pc}` (client): the open BUILD panel
  has the EVOLUTIONS section, the recipe and `Missing: Sword Lv 9 → 12, Heart Lv 1 → 3`; a
  second Inventory (after a pick) leaves only the weapon level missing; check_layout on the
  final frame.
- `layout-levelup-{iphone,phone-portrait,pc}-evo-on`: the cards with the evolution lines and
  icons; `layout-hud-build-{iphone,phone-portrait,pc}`: the full-build BUILD panel with the
  new section.

    python3 tools/run_regressions.py --only evolution-preview-regression,layout-evolution-panel-regression-iphone

Status: code type-checked (`bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok). The
regression results are pending the final check (the full round runs at the end of the batch).
Offline only, NOT tested in Studio.
