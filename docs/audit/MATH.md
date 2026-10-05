# MATH audit (upgrades, combat, stats), 2026-10-05

Source audited: baseline b07d83b plus this audit's working tree. Offline Lune only (no Studio, no
devices). Regression: `tools/preview/scenes/math-regression.luau` (80 checks, PASS).

Run it:
`lune run tools/preview/runtime/main.luau -- --scene math-regression --studio --device pc --max-time 400 --set headless=on`

## How each displayed stat is calculated

| Shown where | Value | Where it is calculated |
|---|---|---|
| HUD HP text and bar | `HP` / `MaxHP` player attributes; the text rounds both up, the bar uses HP / MaxHP | `RunManager.setHP` (clamps 0..MaxHP), `LevelUpSystem.RecomputeStats` |
| HUD XP bar, level | `XP`, `XPNeeded`, `Level` | `XPSystem.GiveXP`; cost = 30 + 12 x min(L, 20) + 6 x max(0, L - 20) |
| Passive cards ("Max HP 120 -> 135") | sheet before vs sheet after | `StatSheet.Lines` over `StatSheet.Compute` (the same function the server uses) |
| Weapon cards ("Damage 10 -> 15") | the weapon's own stat row, before Might / cooldown / area bonuses | `WeaponData.CardLines` |
| Garlic ring | `AuraRadius` | `WeaponSystem.UpdateAura`: radius x area x (1 + kill growth) |
| Shield | `Shield` / `ShieldMax` | `ItemSystem.UpdateShieldMax` / `AbsorbHit` |
| Damage numbers | the damage taken off the enemy's HP after crits and shields (summed per enemy, 10 Hz) | `EnemySpawner.Damage` -> `DamageNumbers.Add` |

### Stat sheet (`StatSheet.Compute`)
1. Inside one stat, every source is **added**: hero bonus, permanent upgrades (level clamped to
   0..MaxLevel), passive `Values[level]` (a running total; level clamped), items (`PerStack` x count),
   Bargain Shrine boon, finished synergies.
2. Then the sheet: Might = 1 + sum; MaxHP = round((120 + flat) x (1 + mult));
   CooldownMult = max(0.3, max(0.4, 1 - cooldown) / max(0.1, 1 + attackSpeed));
   Speed = 16 x clamp(1 + speed, 0.5, 2.2); CritChance = clamp(sum, 0, 0.6);
   DamageTaken = max(0.1, 1 + damageTaken) x Iron Plate 1/(1 + 0.06n); Growth = 1 + growth.
3. Last, curses **multiply**: MaxHP (rounded, at least 1), Might, DamageTaken.

### Damage dealt
weapon row damage x Might x Steady Aim (Ranger) x Volatile Mix (Alchemist, area weapons)
-> on the hit: x Giant's Bane (elite or boss) x Lionheart (low HP) x CritDamage (on a crit,
once; procs never crit) -> the enemy's shield soaks first -> HP. Cooldown = max(0.08, row x CooldownMult).

### Damage taken
max(1, raw x DamageTaken - Armor) -> Aegis ward (whole hit) -> Guardian Ward shield -> HP.
No damage while a server-opened upgrade panel is open, during InvulnUntil or with DEV godmode.

### XP per gem
gem value x CoopShare (living players: 1 / 0.5 / 0.36 / 0.3) x PaceMult (stage row, x1.5 in the
first 90 s) x Growth. Growth sources: Growth upgrade (+5% x 10) and Growth passive (max +40%),
so at most x1.9. Stacked XP is bounded and multiplied once per gem (C4c).

## Findings

| ID | subsystem | expected (source) | files/functions | repro/start state | actual | evidence type | severity | root cause | fix/proposal | status | next check |
|---|---|---|---|---|---|---|---|---|---|---|---|
| MATH-01 | XP | Bad XP input never stalls the run (prompt s.5 NaN/inf) | XPSystem.GiveXP | `GiveXP(rp, math.huge)` | Before: the level loop never ends (server hang); NaN froze the bar for the rest of the run. No caller found that can produce such a value today. | static + test C4b | P2 (latent, severe if reached) | no input guard | Ignore amounts that are not finite and positive | VERIFIED FIXED | math-regression C4b |
| MATH-02 | Heal | A heal only adds HP (s.4/s.5) | RunManager.Heal | `Heal(rp, NaN)`, `Heal(rp, -25)` | Before: NaN HP (the hero can never fall), a negative heal was armor-free damage that never downs the hero (alive at 0 HP). No current caller passes these values. | static + test C6 | P2 (latent) | no input guard | Same guard as MATH-01 | VERIFIED FIXED | C6 |
| MATH-03 | Enemy damage | NaN never reaches enemy HP | EnemySpawner.Damage | `Damage(e, NaN)` | Before: `amount <= 0` lets NaN through, so the enemy's HP becomes NaN and it can never die | static + test C8 | P2 (latent) | NaN comparison | `not (amount > 0)` | VERIFIED FIXED | C8 |
| MATH-04 | Stat sheet | A permanent upgrade never gives more than its MaxLevel (rank overflow) | StatSheet.Compute (Meta loop) | `Meta = { Growth = 1000 }` or `Signature = 99` | Before: the bonus scales without a limit (Growth x51). Saves are already clamped by DataService and `TraitValue` already clamps, so the sheet was the only unclamped reader. | test A10/A11 | P2 (defense in depth) | the level was used as is | Clamp to 0..MaxLevel, NaN = 0 | VERIFIED FIXED | A10, A11 |
| MATH-05 | Upgrades | A pick applies once; repeated, stale or garbage requests do nothing | LevelUpSystem choose / LevelUpChoose | same OfferId sent twice, a stale id, NaN and out-of-range index | one level applied, pending 0 | runtime test C1b | - | - | - | VERIFIED WORKING | C1b |
| MATH-06 | Upgrades | No rank past the cap (stale cards, free chest levels) | apply, chestLevelUp | WeaponUp at 12, PassiveUp at max, a chest on a maxed build | capped at 12 / the passive max | runtime test C2, C3 | - | - | - | VERIFIED WORKING | C2, C3 |
| MATH-07 | Cooldowns | A stat change never resets a weapon cooldown | afterChange / RecomputeStats | Timer 0.77 then a pick | Timer kept (it only counts down) | runtime test C1c | - | - | - | VERIFIED WORKING | C1c |
| MATH-08 | Max HP | Gaining max HP heals that much (Hearty Bread text); recompute without a change never heals; losing max HP clamps | RecomputeStats | 40/120, +2 Hearty Bread | 70/150; recompute again 70; drop back to 120/120 | runtime test C5 | - | intended design | - | VERIFIED WORKING | C5 |
| MATH-09 | Lethal hits | Two lethal hits in one frame use one life; a heal on the lethal frame does nothing; HP clamps at 0 | DamagePlayer, onDowned, Heal | HP 10, two 500 hits; HP 5, lethal + Heal(50) | one extra life used, revive at 50% plus invulnerability; fallen hero stays at 0 | runtime test E1, E2 | - | - | - | VERIFIED WORKING | E1, E2 |
| MATH-10 | Combat | Each hit equals the prediction (`WeaponStats`), HP lost = sum of hits | all 27 released weapons, level 1, a pinned dummy, crits off | 4 s per weapon | 27/27 match; HP lost = sum of hits; Garlic 4 ticks in 4 s as predicted; crit x2 once, procs never crit | runtime test D | - | - | - | VERIFIED WORKING | D |
| MATH-11 | Data | Every hero, weapon, passive, item, synergy and upgrade key is a real sheet key; rows finite; cooldown > 0; evolution partners released; passives never get worse with level | data tables | inventory | all valid (8 heroes, 27 weapons + evolutions, 26 passives, 19 items, 6 synergies) | test B1-B4 | - | - | - | VERIFIED WORKING | B |
| MATH-12 | Caps | Cooldown floor 0.3 (sheet) and 0.08 (weapon), crit 60%, speed x2.2, every sheet value finite for a fully maxed build of every hero | StatSheet, weaponStats | extreme stacks | all hold | test A6-A9, A14 | - | - | - | VERIFIED WORKING | A |
| MATH-13 | Cadence | A weapon fires every `cooldown` s | WeaponSystem.Step (`w.Timer = s.cooldown`) | 60 Hz frames | the time past zero is dropped, so each attack is up to one frame late: about +0.5 frame on average (around 1% at 0.7 s, up to 10% at the 0.08 s floor) | static | P2 | reset instead of carrying the remainder | Proposal: `w.Timer += s.cooldown` (with a floor). This makes weapons slightly faster, so it is a balance change and needs the owner. | UNVERIFIABLE (proposal) | owner decision |
| MATH-14 | Cards | Card numbers can be read as your real damage | WeaponData.CardLines | any weapon card | shows the base row (before Might, attack speed, area) while passive cards show whole-build totals | static | P2 | design choice | Proposal: label it "base", or show the effective value. This is a UI copy decision. | UNVERIFIABLE (proposal) | SCREENS / owner |
| MATH-15 | Results | "Damage dealt" | EnemySpawner.Damage (`rp.DamageDealt += amount`) | big hit on a weak enemy | counts overkill (the whole hit, not the HP actually removed) | static | P2 | - | Proposal: add min(amount, HP before the hit) if the stat should mean HP removed | UNVERIFIABLE (proposal) | WORLD / ECONOMY |
| MATH-16 | Lifesteal | Bloodblade heals at most 8 per swing | Fire.Whip | many enemies in one swing | exact today (1 per hit up to 8); `healed < cap then += Lifesteal` would go over the cap if Lifesteal were ever more than 1 | static | P2 (latent) | the cap is checked before adding | Proposal: `math.min(cap, healed + Lifesteal)` if Lifesteal is ever changed | NOT APPLICABLE today | - |
| MATH-17 | Windstep | Move speed never above x2.2 | ItemSystem.OnKill (RushMult) | gaining speed while a rush runs | RushMult is capped with the speed at the moment the rush starts; a speed gain during the 1.5 s rush can go past x2.2 until it ends | static | P2 | cap taken once | Proposal: recompute the cap in ApplyMovement | UNVERIFIABLE | - |

## Changed files
- `src/shared/StatSheet.lua`: permanent upgrade levels clamped (MATH-04).
- `src/server/Modules/XPSystem.lua`: GiveXP input guard (MATH-01).
- `src/server/Modules/RunManager.lua`: `Heal` input guard only (MATH-02); the file belongs to JOURNEY, and the heal code belongs to MATH.
- `src/server/Modules/EnemySpawner.lua`: one-line NaN guard in `Damage` (MATH-03); the file belongs to WORLD, and the damage code belongs to MATH.
- `tools/preview/scenes/math-regression.luau`: new regression.

Risk: low. Valid inputs behave exactly as before. Recovery: revert the guard lines.

## Tests (this audit, offline Lune, 2026-10-05)
- math-regression: PASS 80/80. MATH-01 to 04 fail without their fixes (worked out from the code; the old code was not run).
- Adjacent, after the changes: passives-regression, progression-regression, mastery-regression, xp-sim,
  combat-regression, choice-regression, synergy-sim: PASS.
- `bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok.
- Studio, real devices, multi-client: NOT RUN.
