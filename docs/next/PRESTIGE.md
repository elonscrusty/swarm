# Prestige (switch `Prestige`)

## What
A hero whose whole Hero Mastery track is maxed (its six stat upgrades and its signature
upgrade all at their max level, `MetaUpgradeData.HeroOrder`) can Prestige from the
Characters screen. Prestige:
- puts that hero's upgrade levels back to 0 (they can be bought again with gold)
- keeps everything else: gold, mastery level / XP, unlocks, skins, looks and every other hero
- gives the hero one star, up to 5

Reward per star (PROPOSED, awaiting owner approval): +5% of the gold a run with that hero
pays into the lobby (kept gold + survival gold), added at settlement only, at most +25%. It is
never added to in-run gold, so chest and shrine prices keep the GoldMult rule. Stars give no
damage, health or other combat power. The results ledger shows it as its own line
("Prestige bonus +N gold") and in the "Added to your gold" note.

Where:
- Characters screen, MASTERY card of an owned hero, under the upgrade rows: a PRESTIGE block
  (`src/client/MenuPrestige.lua`) with "★2 / 5 · +10% gold from Knight runs" and a line on
  what is left to max. It shows once the hero has a star, its mastery is at max, or every
  upgrade is maxed. When the track is maxed (and stars < 5) the PRESTIGE KNIGHT button shows.
- The confirmation screen (`src/client/PrestigeConfirm.lua`, its own ScreenGui, UIState
  primary "PrestigeConfirm") says, in the owner's words: "Your Knight's upgrades go back to
  level 0. You keep your gold, skins and other heroes. You get ★1 and +5% gold with the
  Knight." Then RESETS / STAYS / YOU GET rows, PRESTIGE KNIGHT and CANCEL. PRESTIGE KNIGHT
  needs a second tap within 3 s (the first tap only arms it and a hint counts down; a tap in
  the first moment after the screen opened never counts). Only then the request is sent.
- Star badge "★n" on the hero's portrait (details panel and roster rows) and on the hero's
  nameplate under the dais ("K N I G H T  ★2"). The in-run title plates are unchanged.

Server (`src/server/Modules/Prestige.lua`, remote `Prestige` (heroId, starsSeen)): checks the
switch, lobby only (not in a run), a known and owned hero, a per-player cooldown (5 s, on top
of the remote's rate limit of 2 per second), the stars the client saw (a repeated request after
the first was applied carries the old count and is ignored: exactly once), fewer than 5 stars
and the whole track maxed. Then, in one synchronous block (one save update), the hero's upgrade
levels are cleared and its star count goes up by one; the save is written at once. There is no
Robux path. Settlement: `GoldSystem.SettleRun` calls `Prestige.Settle` (once per run, never for
a DEV-tainted run or a DevBoosted profile).

Save (additive, no schema bump): `Prestige = { [heroId] = stars }` (whole stars 1..5, cleaned on
load by `PrestigeData.Clean`), sent to the client as ProfileSync `Features.Prestige`. Shared rules:
`src/shared/PrestigeData.lua`.

## Config
- `Config.Features.Prestige = true` (false: no block, no badge, remote refused, no bonus)
- `Config.Prestige`: `ConfirmSeconds = 3`, `Rate = 2`, `CooldownSeconds = 5`
- PROPOSED, awaiting owner approval: `MaxStars = 5`, `GoldPerStar = 0.05`, `GoldCap = 0.25`

## Owner steps
1. Approve or change the reward: +5% run gold per star, max 5 stars (+25%).
2. Studio playtest: max a hero (DEV tools), prestige it, play a run, check the results ledger.

## Regression
`tools/preview/scenes/prestige-regression.luau` (registered in tools/run_regressions.py under
"batch B group E"):

    python3 tools/run_regressions.py --only prestige-regression,layout-prestige-regression-iphone-case-confirm,layout-prestige-regression-phone-portrait-case-confirm,layout-prestige-regression-pc-case-confirm

Checks: refused when off, not owned, unknown, in a run, not maxed, stale or junk stars; a maxed
hero resets to 0 and gets one star exactly once (repeat ignored, cooldown), gold / mastery XP /
skins / other heroes untouched; the remote path; no sixth star, junk saves cleaned; the bonus is
paid only at settlement (+10% for 2 stars, +25% cap at 5), once per run, none for DEV-tainted
runs, boosted profiles or with the switch off; in-run gold is the same with stars. Layout
(`case=confirm`): the PRESTIGE block, badge and button on the Characters screen, the owner's
exact text, first tap only arms, armed tap expires after 3 s, second tap sends once; the last
frame shows the confirmation screen for check_layout on iphone, phone-portrait and pc.

Status: code type-checked (`bash tools/check.sh --quick`); regression results pending the
final check (the full test round runs at the end of the batch). NOT tested in Studio.
BLOCKED until Studio: real-device text size, a real maxed hero and settlement in a real run.
