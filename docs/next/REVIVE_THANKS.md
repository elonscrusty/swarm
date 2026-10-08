# Revive thank-you (switch `ReviveThanks`)

## What
In a Duo or Trio run, when a teammate revives you (standing next to you, the proximity revive
in `RunManager`), a gold THANKS! button appears for 6 s at the bottom centre of the screen,
above the weapon tray, away from JUMP and ULT (bottom right) and the thumbstick. A tap:
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
`revive-thanks-regression` (real server, real proximity revive, client module without UI) and
`layout-revive-thanks-layout-*` (iphone at Text size Largest, phone-portrait, pc), registered in
`tools/run_regressions.py` under "batch B group D".

    python3 tools/run_regressions.py --only revive-thanks-regression

Checks: a real revive makes one offer for the revived player only; the client shows the button
and a tap pays exactly 25 XP and one notice, once; repeated taps, junk and wrong ids, outsiders,
the reviver, replaced and expired offers pay nothing; no self-revive offer; no offer or payout
in a solo run; three thank-yous per pair then refused; DEV-tainted runs (either side, before or
after the offer); switch off; the offer lasts 6 s on the client; the client ignores junk offers. The button itself on screen
(and its clearance from the tray) is the layout check.

Status (offline only, not Studio-tested):
- `revive-thanks-regression`: PASS (server run with the client module but no UI; a full client
  simulation is far too slow, so the offer is handed to the client module in the scene).
- `layout-revive-thanks-layout-iphone` (Text size Largest), `-phone-portrait`, `-pc`: PASS.
- `bash tools/check.sh --quick`: TYPECHECK ok, COMPILE ok.
- BLOCKED until Studio: the button against real touch controls (left- and right-handed) and
  real revive timing.

Placement note: the button sits bottom centre, directly above the HUD weapon / passive tray and
any tutorial tip (it moves up with them), clear of JUMP, ULT and the team list. The "from <name>"
caption was dropped (it was cut on phones); the reviver's name is in the notice the reviver sees.
