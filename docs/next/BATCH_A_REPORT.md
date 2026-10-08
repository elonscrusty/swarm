# Batch A report (docs/PROMPT_NEXT_BATCH.md), 2026-10-07

Branch `batch-a` (also `claude/batch-a-prompt-docs-yhs66s`); not merged to `main`.
Offline only (Lune preview + type check). NOT tested in Studio or on a phone.

The nine items (plus the interactive first-run walkthrough) were built in commit 86b31a4. This
batch reviewed that code, ran the full offline test round, and fixed what it found.

## Fixes in this batch
Game code:
- Walkthrough: Settings > Replay tips never replayed it (the done flag blocked it). Fixed. A
  replay's chest now has its normal price, so replaying can't give a free chest every run.
- InviteRewards: a run counts toward the inviter's credit only when won or at least
  `Config.Invite.MinRunSeconds` (120) long, so join-and-leave doesn't credit.
- GroupBonus: membership is cleared deferred on leave, so a mid-run leaver's settlement still
  pays the bonus.
- LobbyScreen: the home Starter Bundle card was stored under the same name as the "Starter"
  screen, so every lobby load errored. It is now `ui.StarterHome`.
- SmartTutorial: in phone portrait the bubble now sits in the free lower screen instead of on
  the tray (the tray is under the top HUD there). An open ping wheel hides the tip.
- DangerArrows: the keep-out list now covers the gold/kills counters, pause, buff and status.
- StarterCard: the detail line wraps under the title, so "Pioneer skin + 2,000 gold · 6d left"
  isn't cut on iPhone.

Tests: data-regression knows the 10 new switches. team-regression moves heroes the legal way
and measures the weak-spot side on the opening tick (FastStart's timing exposed raw jumps that
tripped the speed check). menu_clarity allows the Quests chip and the shortened Daily subtitle.
smart-tutorial and comeback scenes are lighter or set up correctly. textfit, comeback and
smart-tutorial layout runs get the 600 s limit.

## Results
- `bash tools/check.sh`: TYPECHECK ok, COMPILE ok, BUILD ok.
- Full `tools/run_regressions.py`: 201/203 on the final round; the 2 fails (menu-phone,
  menu-phone-portrait: the test didn't know the new Quests chip) were fixed and pass on rerun.
  So 203/203 offline.

## Per item
| # | Item | Offline | Blocked on |
|---|------|---------|------------|
| 1 | SmartTutorial | PASS | Studio / phone playtest |
| 2 | DangerArrows | PASS | phone playtest |
| 6 | FastStart | PASS (econ-sim numbers in FAST_START.md) | feel on a phone |
| 11 | DailyQuests | PASS | gold 300 / 300 / 600 owner OK; real run pacing |
| 12 | ComebackGift | PASS | gold 500 / 1,000 owner OK; real days away |
| 15 | InviteRewards | PASS (mocked) | real invites need the live game |
| 17 | GroupBonus | PASS (mocked) | owner's group id (`Config.Group.Id` is 0 = off) |
| 18 | StarterBundle | PASS (mocked purchase) | owner creates the product (Id 0 = hidden), OK on the Pioneer skin |
| 20 | BugReportPlus | PASS | real LogService / filter in Studio |
| - | Walkthrough | PASS | phone playtest |

## Owner decisions still needed
- Gold for daily quests (300 / 300 / 600) and the comeback gift (500 / 1,000): owner OK 2026-10-07.
- The bonus looks (Questor plate/trail, Homecoming trail) and the small gold fallbacks.
- The Roblox group id for the group bonus.
- Is the Pioneer Knight skin OK for the Starter Bundle; create its product and set the price.
