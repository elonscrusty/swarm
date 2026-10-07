# Quick resume (switch `QuickResume`)

## What
Co-op runs already had a rejoin grace (`Config.RunServers.RejoinGraceSeconds`, RunManager
`TryReconnect`, RunServers "Rejoin"). Quick resume gives SOLO runs (Solo, Daily, Weekly) the
same, with a card first instead of an automatic teleport.

When a living player drops out of a solo run (`RunManager.OnPlayerRemoving` asks
`QuickResume.CanHold`):
- the run and its server state are kept for 60 s (`Config.RunServers.SoloResumeSeconds`): the
  run record is snapshotted exactly as for co-op (lifetime stats checkpointed, escrow kept) and
  the run world is NOT cleared
- the run is frozen (`RunManager.SoloAway` makes `RefreshFrozen` freeze it): the run clock
  stops, enemies, projectiles and timers stop; the hero is out of the run, so nothing can
  damage it
- the save gets `SoloResume = { Id, Expires, Stage, Level, Hero, Wave }` before it is released;
  the secret reserved-server route stays in `RunReconnect` (never replicated) with Expires 0,
  so no lobby teleports by itself

Back within 60 s (joining the game, or landing in a lobby): the lobby keeps the escrow and
shows a big card first (`src/client/ResumeCard.lua`, its own ScreenGui, UIState primary
"ResumeRun", so other lobby cards wait): "YOUR RUN IS WAITING", "Stage 2 · Wave 7 · Level 14 ·
Knight", a short explanation, RESUME RUN (0:42) and END RUN (two taps within 3 s).
- RESUME RUN (remote `QuickResume` "Resume"): when the run is held on this server, RunManager
  `TryReconnect` restores it: same run id, build, HP, gold, XP, level, kills, stage and wave;
  the hero comes back where it stood with 2 s of protection; the clock runs again. In the live
  game, `RunServers.ResumeSolo` arms the saved route (Expires = the solo window) and teleports
  to the run's reserved server with its access code; the run server restores it through the
  same `TryReconnect`.
- END RUN ("End"): the run is settled now.

Not back in time: settled exactly once with today's loss / leave gold-kept rule.
- The server that holds the run ends it at expiry (`RunManager.ExpireSoloHold`) and frees the
  run world. With the player back on that server (no tap): the normal leave commit
  (`saveRunStats`: kept gold + survival gold, stats, boards, account XP, quests). With the
  player away: the boards get the run's final score once from the snapshot; the gold settles on
  their next load (`GoldSystem.RecoverEscrow`, the same kept rule by stages cleared) and
  `SoloResume` is cleared in the same update.
- A lobby whose card runs out settles the same way (QuickResume step, twice a second).
Difference to an ordinary leave when the player is away at expiry (same as today's expired
co-op rejoin): survival gold, account XP, mastery XP and quest progress of that run are not
added, because the player's save is on another server at that moment.

Security: only the save's owner can resume (the snapshot is keyed by UserId, the remote only
acts on the caller's own save, and the run server only accepts its ticket's members); one
resume per disconnect (the snapshot and `SoloResume` are consumed); a resumed run keeps its
DEV taint (the snapshot keeps `DevTainted`); boards get the final score once (once per run id
in LeaderboardService; DEV-tainted runs send none).

Code: `src/server/Modules/QuickResume.lua` (new), small hunks in RunManager (OnPlayerRemoving,
RefreshFrozen, Step, TryReconnect, CommitAll, returnAll, new SoloHoldFor / ExpireSoloHold),
RunServers (lobby load hook, new ResumeSolo), GoldSystem (escrow kept while pending),
`src/client/ResumeCard.lua` (new), one line in ClientMain.

## Config
- `Config.Features.QuickResume = true` (false: a solo disconnect ends the run at once, as before)
- `Config.RunServers.SoloResumeSeconds = 60`
- `Config.QuickResume.Rate = 2` (requests per second per player)

## BLOCKED (needs Studio / the live game)
- Real teleports and separate servers can't run offline; they are mocked like the existing
  reconnect scenes (coop-regression, reconnect-lobby).
- Important for the live game: Roblox shuts a server down when its last player leaves
  (BindToClose gives at most 30 s). Live solo runs play on their own reserved server, so when
  the only player drops, that server is likely closed before 60 s and the held run is lost.
  The code handles that safely (a RESUME then lands on a fresh instance, is refused with
  "That run has ended…", and the gold is settled once by the kept rule), but the resume
  itself will mostly only work where the server stays up (runs on a lobby server: Studio,
  the teleport fallback). Making it work on live reserved servers would need the run state
  saved and rebuilt on a new server (MemoryStore handoff): a bigger job, owner decision.

## Owner steps
1. Studio playtest with two clients (or the teleport fallback): start a solo run, leave,
   rejoin within 60 s, tap RESUME RUN; leave again and wait 60 s.
2. Decide whether the live reserved-server case (see BLOCKED) is worth the bigger handoff job.

## Regression
`tools/preview/scenes/quick-resume-regression.luau` (registered under "batch B group E"):

    python3 tools/run_regressions.py --only quick-resume-regression-case-local,quick-resume-regression-case-run,quick-resume-regression-case-run-rejoin-expired,quick-resume-regression-case-lobby-flow-resume,quick-resume-regression-case-lobby-flow-end,quick-resume-regression-case-lobby-flow-timeout,quick-resume-regression-case-lobby-flow-expired,layout-quick-resume-regression-iphone-case-card,layout-quick-resume-regression-phone-portrait-case-card,layout-quick-resume-regression-pc-case-card

Checks: a disconnect freezes the run (clock stopped, nothing simulates, hero out of the run);
a wrong user can't resume (remote, TryReconnect, a stranger arriving with the run id); a rejoin
within the window shows the offer first and resumes the same state (run id, build, HP, gold,
XP, level, kills, stage), DEV taint kept, one resume per disconnect; after the window it settles
once (boards once, world freed, gold on the next join), also with the player back but not
tapping; no double settlement anywhere; switch off ends the run as before; the lobby shows the
card first (no teleport), RESUME teleports once with the saved access code (never in teleport
data), END and a running-out window settle once, an expired save settles on load with no card.
Layout (`case=card`): the card on iphone, phone-portrait and pc with check_layout.
Also to run: coop-regression (rejoin=success, rejoin=expired), reconnect-lobby,
settlement-lifecycle, meta-regression, mastery-regression.

Status: code type-checked (`bash tools/check.sh --quick`); regression results pending the
final check. Teleports / multi-server BLOCKED offline (mocked). NOT tested in Studio.
