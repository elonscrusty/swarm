# Comeback gift (switch `ComebackGift`)

## What
A player who joins after 3 or more days away gets a one-time WELCOME BACK card in the lobby.
- 3-6 days away: gold.
- 7+ days away: more gold plus the Homecoming Trail (a new earned look, never sold; if it is
  owned already, extra gold instead).

Server (`src/server/Modules/ComebackGift.lua`): the save keeps `LastSeen` (refreshed every
60 s while online and on leave). When a profile loads, the server reads the time away before
refreshing it and decides the gift: never for a brand-new account (no `LastSeen` yet, or no
finished run), never while one is waiting, at most once per 72 h. The gift waits in the save
(`Comeback.Pending`) until claimed; CLAIM (remote `Comeback`, lobby only) clears it before
paying, so it pays exactly once.

Client (`src/client/MenuComeback.lua`): the card opens by itself once per session on the
home screen while a gift waits, and from MORE > WELCOME BACK (shown only then, just before
DAILY REWARD). The login streak stays its own card: after claiming, the button reads
"NEXT: DAILY REWARD" when today's streak claim is open.

Save (additive, no schema bump): `LastSeen = os.time`, `Comeback = { LastGift = os.time,
Pending = { Days, Gold, Look? } | nil }`. With the switch off neither field is written.

## Config
- `Config.Features.ComebackGift = true`
- `Config.Comeback`: `AwayDays = 3`, `LongDays = 7`, `CooldownHours = 72`, `MinRuns = 1`,
  `SeenEvery = 60`, `Rate = 2`
- PROPOSED, awaiting owner approval: `Gold = 500` (3-6 days), `LongGold = 1000` (7+ days),
  `LongCosmetic = "Trail_Homecoming"`, `CosmeticOwnedGold = 250`

## Owner steps
1. Approve or change the amounts and the look (Config.Comeback).
2. Studio: the gift needs a save last seen 3+ days ago; test with a copy of a save or wait.

## Regression
`tools/preview/scenes/comeback-regression.luau` (server logic, headless, ~50 s):

    python3 tools/run_regressions.py --only comeback-regression,layout-meta-iphone-screen-Comeback

Checks: switch off; new accounts (no LastSeen, no runs) never; 2 days nothing, 3 days the
short gift; claim refused in a run, paid once; 72 h cooldown; 7+ days gold + look; a waiting
gift is not replaced; owned look pays gold; LastSeen refreshed while online. The card opening
by itself from home is checked in the client scene `meta` (screen=Comeback, a PASS/FAIL line
in the `layout-meta-*-screen-Comeback` checks for iphone, phone-portrait and pc); a full
client inside the server scene costs ~40 s real per simulated second.

Expect: PASS offline. BLOCKED until Studio / live: real absence across days, DataStore saves.
