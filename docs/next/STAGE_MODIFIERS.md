# Stage modifiers (switch `StageModifiers`)

**HELD (owner decision, 2026-10-07): switched off (`Config.Features.StageModifiers = false`) and its
regression checks removed from tools/run_regressions.py. The code stays in the tree, unreleased;
with the switch off the game behaves as before.**

## What
From stage 2, every stage rolls one modifier: a trade-off that makes the stage different.
It is named on the stage-start card and shown as a HUD badge while the stage lasts.

Pool (8, `Config.StageModifiers.Pool`):

| Id | Name | Effect |
| --- | --- | --- |
| SwiftFoes | Swift Foes | enemies +12% speed, +20% XP |
| ThickHides | Thick Hides | enemies +8% HP (not bosses), +12% gold |
| GlassArena | Glass Arena | you deal +20% damage, you take +20% damage |
| GemRain | Gem Rain | +30% XP, fewer small chests (x0.6) |
| EliteNight | Elite Night | elites twice as often and +1 per elite wave, elite chests +1 roll |
| Calm | Calm | -15% enemies, -15% XP |
| Bounty | Bounty | kill gold x1.4, enemies +5% damage |
| Haste | Haste | you +10% speed (within the item speed cap), weapon cooldowns +5% |

(Started from the spec's examples; Swift Foes, Thick Hides, Bounty and Haste were tuned down
by the balance runs below.)

- Rolls: `StageModifierData.Roll(seed, stage)` (shared, pure). The run seed is picked in
  `RunModifiers.BeginRun`: the Daily Challenge uses the day's fixed seed and the Weekly
  Challenge the week's, so everyone gets the same modifiers; other runs get a random seed
  (their own Random, so no other roll of the game changes). Never the same modifier two
  stages in a row; stage 1 never has one.
- Server only, through the existing multipliers (the curses pattern in `RunModifiers`):
  `EnemySpeedMult`, `SpawnMult`, `EliteChanceMult`, `StatMults` (stat sheet: damage dealt /
  taken, speed, cooldowns, in-run gold stat), `StageMod(key)` read by `StageManager`
  (EnemyHPMult, DamageMult), `XPSystem.GiveSharedXP` (gem XP), `GoldSystem.OnKill` (kill
  gold), `StageModCount("ChestRolls")` in `LevelUpSystem.OpenChest` (elite chest), and
  `LootSystem.BuildStage` asks `StageModifierFor(stage)` while placing small chests (the same
  random roll is used, so the other loot rolls of the stage do not shift).
- Live only while its stage runs: cleared during the travel (the stage's end) and outside a
  running run; when it changes, every run player's stat sheet is recomputed at once.
- Curse cap (`Config.StageModifiers.Caps`): when a curse has the same effect, curse x
  modifier never goes past the cap (Glass Cannon x Glass Arena damage: 1.45, not 1.56;
  Frenzy x Swift Foes: 1.35); a curse alone above the cap keeps its value; a lowering
  modifier (Calm under Horde) always applies.
- Display: SwarmState `StageModifier` (id, "" = none). `RunIntro` (stage card) adds a line
  "GLASS ARENA: You deal +20% damage · You take +20% damage" and stays 1.6 s longer;
  `src/client/StageModifierUI.lua` puts a FeatureHud badge "GLASS ARENA" (crimson edge) in
  the top-right badge row, which FeatureHud keeps in the safe area and hides under any
  covering panel (UIState).
- Nothing is granted or saved; no save fields, no remotes.

## Config
- `Config.Features.StageModifiers = true` (false: no roll, every hook is 1, no badge, no card
  line; the game is exactly as before)
- `Config.StageModifiers` (numbers PROPOSED, awaiting owner approval): `FromStage = 2`,
  `NoRepeat = true`, `CardSeconds = 1.6`, `Caps`, `Order`, `Pool` (table above)

## Balance (offline Lune sim)
Method (the BALANCE_TUNE econ-sim style, rebuilt in the tree as
`stage-modifiers-regression --set measure=on --set mod=<Id>|none`): the REAL server, a solo
Knight (preview default profile, tutorial marked done) walks a circle, cards auto-picked, no
dodging, no shopping (so run gold = gold earned); each stage = 150 s of exploring, then the
portal ring, the boss and the surge; 3 stages. Stage 2 and 3 get the forced modifier;
"none" = the switch off. Undying: a would-be lethal hit is counted and HP refills. Final
Stand on (the default) in every run. Same seed = identical stage 1 in every column.

Primary measure: stage 2, the first stage with the modifier (stage 3 adds the drift of a
different build). Each modifier is compared with the baseline on the SAME seeds (seeds 1-5;
1-10 where marked). Final numbers:

| Modifier (final numbers) | Seeds | Would-be deaths S2, base -> mod | Gold earned S2 | Deaths S2+S3 | Gold S2+S3 |
| --- | --- | --- | --- | --- | --- |
| Swift Foes | 1-5 | 8.0 -> 7.8 (-3%) | 1,746 -> 1,786 (+2%) | 15.4 -> 17.2 (+12%) | +15% |
| Thick Hides | 1-10 | 7.0 -> 8.3 (+19%) | 1,557 -> 1,595 (+2%) | 14.5 -> 18.3 (+26%) | +7% |
| Glass Arena | 1-5 | 8.0 -> 8.6 (+7%) | +1% | 15.4 -> 17.6 (+14%) | +7% |
| Gem Rain | 1-10 | 7.0 -> 7.7 (+10%) | +4% | 14.5 -> 16.5 (+14%) | +9% |
| Elite Night | 1-5 | 8.0 -> 4.2 (-48%) | 1,746 -> 1,993 (+14%) | 15.4 -> 5.8 (-62%) | +14% |
| Calm | 1-5 | 8.0 -> 9.0 (+12%) | -11% | 15.4 -> 18.4 (+19%) | -5% |
| Bounty | 1-10 | 7.0 -> 7.7 (+10%) | 1,557 -> 1,758 (+13%) | 14.5 -> 19.2 (+32%) | +17% |
| Haste | 1-5 | 8.0 -> 8.8 (+10%) | +6% | 15.4 -> 19.0 (+23%) | +5% |
| mean of the 8 | | +2% | +4% | +10% | +9% |

Tuning rounds (stage 2, same seeds): Swift Foes 1.15 speed: +25% deaths -> 1.12: -3%.
Thick Hides 1.2 HP / 1.25 gold: +35% deaths, +28% gold -> 1.15 / 1.2: +27%, +10% -> 1.1 /
1.15: +45% (seeds 1-5) / +31% (1-10) -> 1.08 / 1.12: +19% (1-10). Bounty x1.5 kill gold /
1.1 damage: +23% deaths, +25% gold -> 1.4 / 1.08: +20%, +14% -> 1.4 / 1.05: +10%, +13%
(1-10). Haste cooldowns +10%: +18% -> +6%: +15% -> +5%: +10%. Glass Arena, Gem Rain, Elite
Night and Calm kept their first numbers.

Result: on stage 2 every modifier is at or under +20% would-be deaths and +25% gold (Thick
Hides +19% is the closest); PASS for the spec's limits on that measure. Over two modifier
stages (S2+S3) Bounty (+32%), Thick Hides (+26%) and Haste (+23%) are above +20%; that window
carries the drift of a different stage-2 build and is much noisier, see below.

Noise, honestly: this bot's death count swings a lot between nearby runs. Gem Rain changes
nothing that hurts a bot that never opens chests, yet it read +23% deaths on seeds 1-5 and
-7% on seeds 6-10; Thick Hides at 1.1 / 1.15 read +45% on seeds 1-5 and +13% on seeds 6-10.
Treat differences under about 20% as noise. Elite Night makes the bot's run easier (elite
chests give extra level-ups); it is allowed by the limits (they cap increases) but is the
one to watch in playtests. Measured offline in Lune only: deaths, gold earned, XP, damage
taken, stage time. Not measured: real players (dodging, shopping), co-op, curse + modifier
combinations beyond the cap checks, stages 4-5, Studio / device.

## Owner steps
1. Approve or change the modifier numbers (`Config.StageModifiers.Pool`, `Caps`).
2. Studio playtest: reach stage 2, read the card line and the badge; try a Daily run on two
   accounts and check both get the same modifiers.

## Regression
- `tools/preview/scenes/stage-modifiers-regression.luau` (`stage-modifiers-regression`,
  headless server): pool >= 8 and every entry a trade-off, deterministic roll, no stage-1
  modifier, no repeat, every modifier seen across seeds, Daily / Weekly fixed seeds, caps;
  live: stage 1 neutral, a real stage 2 with Gem Rain (XP, fewer small chests, SwarmState),
  travel clears it, a real stage 3 with Glass Arena on the stat sheet, all 8 modifiers through
  every live hook and back to neutral, switch off, run end clears it, Glass Cannon / Frenzy
  caps live. `--set measure=on --set mod=<Id>|none` is the balance bot.
- `tools/preview/scenes/stage-modifiers-ui.luau` (`layout-stage-modifiers-ui-iphone`,
  `-phone-portrait`, `-pc`): the card line and the badge, the badge removed when the modifier
  clears, hidden under a covering panel, switch off, final frame with the longest text
  (Elite Night) for check_layout.

    python3 tools/run_regressions.py --only stage-modifiers-regression,layout-stage-modifiers-ui-iphone,layout-stage-modifiers-ui-phone-portrait,layout-stage-modifiers-ui-pc

Status: code type-checked (`tools/check.sh --quick` ok). Regression results: pending the
final check (the coordinator runs the full round). Studio / device: BLOCKED (offline only).
