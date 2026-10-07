# Revive thank-you (switch `ReviveThanks`)

## What
In a Duo or Trio run, when a teammate revives you (standing next to you, the proximity revive
in `RunManager`), a gold THANKS! button appears for 6 s at the bottom centre of the screen,
away from JUMP and ULT (bottom right) and the thumbstick. A tap:
- tells the reviver "<your name> says thanks! +25 XP" (the usual notice lane)
- gives the reviver `Config.Revive.ThanksXP` (25) run XP, through `XPSystem.GiveXP` (the exact
  amount, no multipliers). Run XP only: nothing is saved and nothing goes to a leaderboard.

Server (`src/server/Modules/ReviveThanks.lua`, hooked into the partner revive in
`RunManager`, remote `ReviveThanks`, offer remote `ReviveThanksOffer`):
- one offer per revive, sent only to the revived player; a newer revive replaces an older open
  offer
- the tap carries only the offer id. Checked on the server: switch on, a group run (never solo),
  you are in the run, the offer is yours, open, unused and not older than 6 s plus 1.5 s of
  lag grace, the reviver is still in the run and is not you, the pair has fewer than 3
  thank-yous this run, and neither run is DEV-tainted (no offer for a tainted run; a taint
  after the offer blocks the payout)
- the offer is marked used before anything is paid, so a repeated tap pays nothing
- the XP goes to the reviver only if they are alive; otherwise they still get the notice

Client (`src/client/ReviveThanks.lua`): its own ScreenGui; shown only while `FeatureHud` says
the HUD is visible (in a run, no UIState panel or owner), hidden after one tap, after the time
is up, when you go down again and when the run ends. The client never shows it longer than
`Config.Revive.ThanksSeconds`, whatever the message says.

Counters live on the run player record (`ThanksOffer`, `ThanksGiven`), so they reset every run.
Nothing is saved. No new save field.

## Config
- `Config.Features.ReviveThanks = true`
- `Config.Revive`: `ThanksXP = 25` (PROPOSED, awaiting owner approval), `ThanksSeconds = 6`,
  `ThanksGrace = 1.5`, `ThanksPerPair = 3`, `ThanksRate = 2`
- New remotes `ReviveThanksOffer` (server to client) and `ReviveThanks` (client to server).

## Owner steps
1. Approve or change the thank-you XP (`Config.Revive.ThanksXP`, now 25).
2. Studio playtest with two accounts: get downed, get revived, tap THANKS!, check the reviver's
   notice and XP, and that the button is not on top of JUMP or ULT on your phone.

## Regression
`revive-thanks-regression` (real server, real proximity revive, full client) and
`layout-revive-thanks-layout-*` (iphone at Text size Largest, phone-portrait, pc), registered in
`tools/run_regressions.py` under "batch B group D".

    python3 tools/run_regressions.py --only revive-thanks-regression

Checks: a real revive makes one offer for the revived player only; the client shows the button
and a tap pays exactly 25 XP and one notice, once; repeated taps, junk and wrong ids, outsiders,
the reviver, replaced and expired offers pay nothing; no self-revive offer; no offer or payout
in a solo run; three thank-yous per pair then refused; DEV-tainted runs (either side, before or
after the offer); switch off; the button hides after 6 s; the client ignores junk offers.

Status: written and type-checked; regression results pending the final check (not run in this
session by request). BLOCKED until Studio: placement of the button against real touch controls
(left- and right-handed), real revive timing.
