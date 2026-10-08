# Elite affix icons (switch `AffixIcons`)

## What
Elites already roll one affix (Swift, Shielded, Burning; `Config.Enemies.EliteAffixes`,
`EnemySpawner`). Now every elite wears a small badge above its name tag that says which one:

| Affix | Badge | Colour |
| --- | --- | --- |
| Swift | round badge with three speed lines | blue |
| Shielded | shield | silver |
| Burning | flame | orange |

The shape differs per affix as well as the colour (colour-blind players), and the colours go
through `Accessibility.Color`. The badge is 20 px (`Config.AffixIcons.Size`, clamped to 18-22) and
one icon wide, far narrower than any enemy health bar (64 px), so it never sticks out. Elites have
no health bar of their own; the badge hangs above their existing name tag.

It is client only (`src/client/AffixIcons.lua`): it reads the replicated enemy body attributes
`Elite` and `Affix` that `EnemySpawner` already sets. No new attribute, no new remote. It is
removed as soon as the elite dies (the body is parked below the arena, loses `Elite`, or goes
away), within one scan (8 per second). Reduced effects keeps the badge and drops its pulse.

First sight: the first time a player meets each affix, one line goes through the UIState notice
lane, for example "Shielded elites block the first hits". The server decides
(`src/server/Modules/AffixSight.lua`, called from `EnemySpawner.Step`): a living elite within
`SightRange` (60 studs) of a living hero counts as met. The save field `SeenAffixes` is marked
before the notice is sent, so it is exactly once per account and affix, never again in later
runs. A DEV-tainted run or a DEV-boosted profile neither shows nor records it.

Save (additive, no schema bump): `SeenAffixes = { Swift = true, Shielded = true, Burning = true }`,
default `{}`; `DataService.Migrate` keeps known affix ids only.

Files: `src/shared/AffixIconData.lua` (shape, colour, notice per affix), `src/client/AffixIcons.lua`,
`src/server/Modules/AffixSight.lua`, `Config.AffixIcons`, one hook line in `ClientMain` and one
in `EnemySpawner.Step`.

## Config
- `Config.Features.AffixIcons = true` (false: no badges, no notice, nothing saved)
- `Config.AffixIcons`: `Size = 20`, `Lift = 6.2` (studs above half the body height), `UpdateHz = 8`,
  `PulseSeconds = 0.6`, `PulseScale = 1.12`, `MaxDistance = 200`, `SightRange = 60`, `SightEvery = 0.5`
- Notice texts live in `AffixIconData` (Swift: "Swift elites run much faster than normal enemies",
  Shielded: "Shielded elites block the first hits", Burning: "Burning elites leave fire behind them").
  Please read them and change the wording if you like.

## Owner steps
1. Studio playtest: meet one elite of each affix. Check the badge reads at game zoom on the phone,
   sits clear of the name tag, and the notice appears once (then never again on that account).
2. To see the notices again on a test account, a developer clears `SeenAffixes` in that save by hand;
   nothing in the game resets it.

## Regression
- `tools/preview/scenes/affix-icons-regression.luau` (layout check on iphone, phone-portrait, pc): data
  (three shapes, three colours, three notices), badge matches the affix, none on non-elites or unknown
  affixes, 18-22 px and at most 64 px wide, removed when the elite dies / is parked / is destroyed,
  Reduced effects drops the pulse, first-sight logic with a fake server context (once per account and
  affix, range, dead player, DEV taint, DEV boost, junk save value, switch off), switch off removes all
  badges. The final frame shows one elite of each affix for `check_layout`.
- `tools/preview/scenes/affix-sight-regression.luau` (real server): `SeenAffixes` default and Migrate,
  one notice per affix in a real run, none for a second elite, none in a later run, DEV taint, switch off.

    python3 tools/run_regressions.py --only affix-sight-regression,layout-affix-icons-regression-iphone

## Status
PASS offline (full round plus a re-run after two scene fixes: the real-server scene spawned a
non-existent enemy type, the layout scene needed empty SwarmGems / SwarmPickups folders):
`affix-sight-regression` PASS, `layout-affix-icons-regression-iphone`, `-phone-portrait` and `-pc`
PASS (36 PASS lines each, check_layout 0 problems). `tools/check.sh --quick` type check: my files
clean.
BLOCKED until Studio: real camera zoom and badge legibility, the real notice lane timing.
