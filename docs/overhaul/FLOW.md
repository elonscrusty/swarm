# FLOW: return flow, leaderboards, lifecycle cleanup

Owner: FLOW helper (overhaul phase 1). Issues: UI-41, UI-42 (stop control only), UI-57, GI-05.
Everything below was checked offline (Lune preview sims against the Roblox mock). Nothing was
run in Studio, on a device, against live DataStores or with a real teleport.

## 1. Return flow after a run (UI-41, UI-42)

### What the frames show
Short 2:04 (`short/124s.jpg`): the lobby menu with "Back to the lobby in 2s" / GO NOW / STAY on
top of it. Short 2:06 (`126s`): "BACK TO THE LOBBY · Saving your progress…". Short 2:10
(`130s`): the lobby again, after a Roblox loading screen.

### Real lifecycle (traced in code, before the fix)
Every live run plays on a private reserved server (`RunServers`). After a defeat:
1. `RunManager.EndRun` → phase `Results`; the client results say "Back to the lobby in 12s"
   (`Config.Run.ResultsSeconds`).
2. The timer runs out → `returnAll("results")` → `returnPlayerToLobby` sets `InRun = false` and
   spawns the player in the **run server's own lobby**; the client hides the results, so the
   lobby menu appears (frame 124s: this is not the real lobby).
3. `RunServers.OnBackInLobby(…, "results")` started a second countdown
   (`HomeDelayAfterResultsSeconds = 2`, attribute `TravelHomeIn`) shown by the TravelOverlay
   banner with GO NOW / STAY.
4. `sendHome` saved + released the profile, then set `Travel = "ToLobby"` (cover, frame 126s),
   then `TeleportAsync` to a public lobby: the Roblox loading screen and the real lobby (130s).

Root cause (observed in code): the client showed the run server's local lobby menu while the
server still meant to teleport, so the player saw "lobby", a stale second countdown, a cover,
and a second lobby. MAIN MENU on the results had the same two-step shape; the results'
countdown could not be stopped (UI-42).

### Fix: one transition
Server (`RunServers.OnBackInLobby`, `homeStep`, `onTravelHome`):
- `"results"` (defeat results ran out) and `"menu"` (MAIN MENU on them): home **at once**.
  `Travel = "ToLobby"` is set in the same server step as `InRun = false`, no `TravelHomeIn`.
  The cover is now set before the save (it can take a moment) and cleared if the save fails.
- `"replay"` (REPLAY on the results; client sends `ReturnToLobby("Replay")`): the player
  stays for the new run. If no run or lobby countdown takes them within
  `Config.RunServers.ReplayGraceSeconds` (10), the normal visible countdown starts.
- `"portal"` (results over the lobby menu: portal return, pause MAIN MENU): unchanged 20 s
  `TravelHomeIn` countdown, but now shown once (see client).
- New `TravelHome` choices: `"Hold"` (results STAY: nothing automatic until the player picks
  MAIN MENU; allowed while the defeat results are still up) and `"Replay"`. `"Go"` now works
  without a countdown (after STAY). A player in a run or joined to a lobby countdown
  (`RunManager.IsQueued`) is never sent home. Each departure clears `homeAt` before
  `sendHome` yields, so one player is teleported once; party mates waiting for a replay are
  not dragged along.
- Config: `HomeDelayAfterResultsSeconds` removed (unused), `ReplayGraceSeconds = 10` added.

Client (`UIBuilder` results, `TravelOverlay`):
- On a run server the results footer names the real destination ("Main lobby in Ns") and the
  results **stay up until the travel cover covers them**; the run server's lobby is shown only
  if the trip does not start within 2 s (or fails: the server's toast says why).
- MAIN MENU on a run server keeps the results ("Going to the main lobby…", buttons disabled)
  until the cover appears (4 s fallback).
- New footer button STAY (next to REPORT A BUG): stops the automatic return / close; the
  results then stay until REPLAY or MAIN MENU ("Stays open until you choose"). Opening the
  bug form holds the results too, so a report is never cut off by a timer or teleport.
- Results over a run server's lobby show the `TravelHomeIn` countdown in their footer and do
  not close on their own 12 s timer; the TravelOverlay banner is hidden while the results are
  open (`TravelOverlay.SetResultsOpen`), so there is only ever one countdown. Banner text:
  "Main lobby in Ns"; cover title "TO THE MAIN LOBBY".
- Off run servers (Studio, failed teleports, `Enabled = false`) nothing travels: the old
  "Back to the lobby in Ns" behaviour stays, plus STAY.

Assumption (not verifiable offline): attributes set in one server step replicate together, so
the client sees `InRun = false` and `Travel = "ToLobby"` in the same frame. The client keeps a
2 s grace in case they do not.

## 2. Leaderboards (UI-57, GI-05)

### What the frames show
Long 1:12 (`long/072s`): Standard high score, my row #4 = 12,712, pinned "Your best #4 · 9,508
points". Long 1:16 (`long/076s`): Best stage, my row #2 = Stage 5, pinned "Stage 4". The lobby
in the same recording says "Unlock Desert at stage 5", so the **save** really holds best
stage 4.

### Sources (code)
- Rows: the global OrderedDataStore (`SwarmLB_<board>`), written by `Submit` → `flush` with
  `UpdateAsync` keeping the max, read into a cache refreshed at most every 60 s.
- Pinned "Your best": the player's save (`Stats.BestScore` / `BestStage` …, `ownBest`).
- The client showed the row's rank next to the save's value as if they were one number.

### Diagnosis
Observed: the two values come from different authoritative stores, and the board is
higher than the save for both boards. Code paths that make board > save (not proven which one
happened): the board only ever rises, while a save can miss a run whose save write failed
or was lost (SaveStatus "failing", a dropped session) after its board write went through;
before 2026-10-02 (`16ce94b`) DEV-command runs were not tainted and Studio shared the live
stores. Code path that makes save > board: a new best waits in the write queue (30 s
throttle, 6 s flush) and the read cache (60 s). No client caching bug: the client shows the
last answer for the open board.

### Fix (display only; no score is written, lowered, deleted or copied)
- `LeaderboardService` answers also carry `MyBoard` (your value in the rows) and `MyQueued`
  (a better value still in this server's write queue). `MyBest` stays the save's best.
- `MenuLeaderboards.YouText`: when you are ranked, the card shows **your row's value**
  (matching the outlined row). A different save value gets its own line:
  "Board record · your save's best: 9,508", "Saved best X: not on the board yet",
  "New best X: board updating". Not ranked: save best + "Not in the top 50". Without global
  boards ("local"): "Best on any server: X" / "Not ranked on this server".
- Unlocks keep using the save (unchanged): a board record does not unlock arenas.

GI-05 (corner runs on the boards): every board value is computed by the server from its own
run record (`RunScore`), DEV-tainted runs are excluded; a corner-farmed run is a normal run and
is submitted. The reachability fix is CORNER's. No historical scores were touched;
checking the live boards needs the owner (BLOCKED offline).

## 3. Lifecycle cleanup (my files)
- `LeaderboardService`: `lastWrite` stamps older than the throttle are pruned each flush;
  `localBoards` is only filled when DataStores are off (it was filled forever on live servers
  but never read).
- `MenuLeaderboards`: one "loading" retry chain per board (repeated asks used to stack
  retries).
- `RunServers`: new per-player tables (`homeQuiet`, `held`) cleared on leave, on departure and
  on a failed trip; one departure per player.
- `TravelOverlay`: one poll loop, one viewport connection, tween only on state change (no
  change needed). Results: per-result flags reset in `onRunResult`.

## Tests run (offline, mock; PASS/FAIL/BLOCKED)
- `bash tools/check.sh --quick`: PASS.
- `runserver-sim role=run` (extended: defeat → cover in the same step, no second countdown,
  exactly one teleport, failed trip → save back; STAY/Hold → no trip, later GO once, a second
  GO ignored; REPLAY stays, replayed run never sent home, unstarted replay → visible
  countdown; banner STAY): PASS.
- `runserver-sim role=lobby`: PASS.
- `results-flow` (new client scene) cases auto / stay / replay / portal / plain: all checks
  PASS. The first stay/portal runs also logged mock WaitForChild timeouts (the scene had not
  created the run folders); the scene now creates them.
- `leaderboards --set mismatch=board`: PASS (card 11,920 = row; "Board record · your save's
  best: 8,940"). save / queued / BestStage variants: not run (machine load), same code path.
- `reconnect-lobby` (default, fail=teleport, fail=expired): 0 errors.
- `settlement-lifecycle`: FAIL at line 55 ("survival gold: 0"), **not caused by FLOW**. The
  scene advances 125 s and expects 2 min of run clock, but solo level-up offers now freeze
  `runTime` (measured: 67 s of clock after 120 s simulated, `frozen = true`, `PendingLevels = 1`).
  saveRunStats / SettleRun / `seconds` are unchanged. Fix belongs in the scene (advance until
  `RM.GetRunTime() >= 125`, or pick the offers) or with CHOICE-SERVER if the freeze is wrong.
- BLOCKED: real teleports, live OrderedDataStores, Studio, phone hardware, multi-client.

## Remaining risk
- Replication order of `InRun`/`Travel` is assumed (2 s client grace covers a lag).
- Party members who leave the results at different moments still travel in separate
  teleports (pre-existing; PartyService re-forms parties from SwarmReturn).
- Which real event made the owner's board exceed the save is not established; the display is
  now honest about it, the data is untouched.
