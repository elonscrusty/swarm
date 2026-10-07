# Better bug reports (switch `BugReportPlus`)

## What
A Roblox game can't upload a player's screenshot (no external backend), so every bug report
now carries an automatic snapshot instead:

- open panel (UIState primary under the report form, or `None`)
- stage, wave and arena; hero and level
- build: weapons and passives with levels (the server's own copy from the run, plus the client's)
- device type, screen size, Roblox Text size setting, input type
- average FPS (last 10 seconds)
- the last 10 client warnings / errors (LogService), each trimmed to 200 characters
- `game.PlaceVersion`

Player text still goes through Roblox text filtering. The snapshot holds no player text: every
field is a known id, a name from a fixed list or a clamped number, cleaned again on the server
(`BugSnapshotData.CleanSnapshot`). Log lines are the only text: the server removes the names of
everyone in the server and runs them through the text filter; if the filter fails they are dropped.

Reports are stored where they were (`SwarmBugReports_v1`, `_Studio` in Studio), field `Snapshot`
(and `ServerBuild`). Rate limit: 3 reports per player per rolling hour, enforced on the server
(this server's memory plus a `Recent` list in the per-player quota record, so across servers),
on top of the old 1 per minute / 10 per day.

DEV viewer: the existing DEV inbox (DEV panel "Bug inbox", or the BUGS button for allowlisted
players) now shows the latest 20 reports per page, each with its snapshot. Access is checked on
the server (`BugReportService.CanViewInbox` = `DevAccess.IsDev`); other players get nothing.

## Files
`src/shared/BugSnapshotData.lua` (rules), `src/client/BugSnapshot.lua` (collector),
`src/client/BugReportUI.lua` (sends it), `src/server/Modules/BugReportService.lua` (clean, filter,
rate limit, store, inbox rows), `src/client/DevInbox.lua` (viewer).

## Config
`Config.Features.BugReportPlus = true`. Limits in `BugSnapshotData`: `HourLimit = 3`,
`HourWindow = 3600`, `InboxRows = 20`, `MaxLogs = 10`, `MaxLogLength = 200`, `MaxBuild = 8`.
Off: no snapshot is sent or stored, no hourly limit, inbox pages of 8 as before.

## Owner steps
Saving reports needs Studio API access / live DataStores (unchanged). To read reports in a live
server, your UserId must be in `DevAllowlist` (it is).

## Tests
`tools/preview/scenes/bugreport-plus-regression.luau` (runs without `--studio`; registered in
`tools/run_regressions.py`):
`lune run tools/preview/runtime/main.luau -- --scene bugreport-plus-regression --device pc --set headless=on`

Expected PASS (offline): snapshot fields present, hostile values dropped/clamped, log lines
name-scrubbed and filtered, 4th report in an hour refused, non-dev gets no inbox data, owner
gets rows with snapshots, switch off stores no snapshot.
BLOCKED (needs Studio / live): real LogService output, real FPS, the real text filter, live
DataStore quotas across servers.
