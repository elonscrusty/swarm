# Party quick lines (switch `PartyQuickLines`)

## What
Six fixed lines a party can say to each other: "Ready?", "Go!", "GG", "One more?",
"Wait for me", "Thanks!". There is no typing anywhere, so no text filtering is needed: the
client sends only the line's index (1 to 6) and every client looks the text up in its own
`Config.PartyQuickLines.Lines`. A bad or forged message can never put other words on
someone's screen.

Where it shows:
- PARTY screen (`MenuParty`): a strip under both columns with the six buttons and a small
  party feed (the newest lines, yours in gold; three lines on tall screens, one on short
  landscape phones). The strip only exists while you are in a party.
- Lobby home (`LobbyScreen`): a small SAY chip (landscape: under the QUESTS chip in the right
  column, portrait: centred above the QUESTS chip while the hero keeps room). A tap opens a
  popup with the same six buttons; sending a line closes it. Only shown in a party.
- A bubble over the sender's lobby hero holds 4 s and fades out over the last 0.6 s. Your own
  line hangs over your hero on the menu stand; other members' lines hang over their lobby
  characters. If a hero is not on screen yet, the line still goes into the feed.

Server (`PartyService`, remote `Party`, action `Say`, then `PartySay` to the clients):
- the index must be a whole number from 1 to the number of lines
- the sender must be in a party of two or more
- one line per 2 s and 10 per rolling minute per player (the rest are dropped; the 11th in a
  minute also tells the sender)
- delivered only to the sender's own party members (including the sender), with just
  `{ FromId, FromName, Index }`; names are Roblox display names
- the client mirrors the 2 s gap (buttons grey out for 2 s) so a quick second tap is not lost
- off switch: the action is ignored and the client shows nothing

Nothing is saved. No new save field.

## Config
- `Config.Features.PartyQuickLines = true`
- `Config.PartyQuickLines`: `Lines`, `MinGap = 2`, `PerMinute = 10`, `BubbleSeconds = 4`,
  `FadeSeconds = 0.6`, `FeedMax = 6`
- New remote `PartySay` (server to client). `Party` gains the `Say` action.

## Owner steps
1. Studio playtest with two accounts in a party: tap lines on the PARTY screen and from the
   home SAY chip, check the bubble over the other hero in the lobby and the feed.
2. Say if you want different words or more lines (the list is in `Config.PartyQuickLines`).

## Regression
`party-quick-lines-regression` (logic, real server and full client) and
`layout-party-quick-lines-layout-*` (iphone at Text size Largest, phone-portrait, pc; views
panel, home, solo), all in `tools/run_regressions.py` under "batch B group D".

    python3 tools/run_regressions.py --only party-quick-lines-regression

Checks: delivery to the sender's party only; payload has no text; junk indexes (0, 7, 1.5,
-1, NaN, inf, strings, tables, nil) deliver nothing; the 2 s gap and the 10 per minute limit,
and that both reset; switch off; the client feed keeps 6 lines and takes its text from the
config; the bubble holds, fades and goes; leaving the party ends it. The existing `party-sim`
still covers the party flow itself.

Status: written and type-checked; regression results pending the final check (not run in this
session by request). BLOCKED until Studio: the bubble placement over real lobby characters
and the home SAY chip position on real devices.
