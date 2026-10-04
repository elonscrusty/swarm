# UI state contract (UIState)

Owner: UISTATE helper. Code: `src/client/UIState.lua`. Every client screen that opens a panel,
shows a centre headline or a short notice goes through this module. Build new screens on it;
do not add parallel listeners, private toast stacks or private banner queues.

Status: implemented in code, type-checked, exercised by a Lune unit test
(`lune run tools/uistate_regression.luau`) and the preview scene `ui-stack`
(`--set case=portal|caravan|elite|stack|levelup|reel`). NOT tested in Studio or on a device.

## 1. Three things UIState owns

1. **Primary overlay** (at most one input owner). A primary is a panel that takes the player's
   input: it is the only thing that can be clicked, it disables the thumbstick when it blocks,
   and it hides the HUD when it covers. Several primaries can be *open* at once (earned and
   waiting), but only the highest-priority one is *shown*; the others are *suspended* (hidden,
   not resolved, nothing granted or lost) and come back when the owner closes.
2. **Notification lanes**: one persistent objective slot, one centre headline lane, one short
   notice lane. Every message carries a semantic id; the same id from two producers shows once.
3. **Cleanup**: one `UIState.Reset(reason)` for death, respawn, stage travel, leaving the run and
   disconnect (InRun false). Queued headlines/notices are dropped; earned decisions are not
   (they are server-held and re-sent; see section 5).

## 2. Primary overlays and priority

Names are UIBuilder's overlay names (what `show(overlay, name, blocks)` / `kit.Show` pass).
Higher number wins. "Blocks" = thumbstick and world interaction off while shown. "Covers" =
HUD, minimap and item strip hidden while it owns the screen. "Stacks" = a sub-panel that owns
input but leaves the panel under it on screen (it never suspends its parent).

| Priority | Name | Screen | Producer | Blocks | Covers | Stacks | What the world does |
|---|---|---|---|---|---|---|---|
| 100 | `Travel` | stage travel / loading fade | StageUI `StageTravel` | no | no | no | server holds (StageManager.IsHolding) |
| 95 | `BugReport` | bug report form | BugReportUI (from Results / run menu / lobby) | yes | yes | yes | unchanged |
| 90 | `Results` | results | UIBuilder `RunResult` | yes | yes | no | run over |
| 80 | `Revive` | death / revive offer | UIBuilder `ReviveOffer` | yes | yes | no | hero down; teammates play on |
| 70 | `LevelUp` | upgrade selection | UIBuilder `LevelUpOffer` | yes | yes | no | solo: run frozen; group: only the chooser is protected (CHOICE-SERVER) |
| 65 | `Portal` | stage clear / continue | StageUI `PortalOffer` | yes | yes | no | stage over; ChoiceLeft stops while the run is frozen |
| 60 | `Reward` | full reward reveal (rare / paused rewards) | UIBuilder reward reel, full mode | no | yes | no | server reward pause (bounded, RewardPauseMax) |
| 55 | `Items` | items list | LootUI (from the run menu) | yes | yes | yes | as the run menu |
| 50 | `Pause` | run menu / settings | UIBuilder pause | yes | yes | no | solo: paused; group: live (label must say so) |
| 40 | `DevInbox` | dev inbox | DevInbox (lobby) | no | no | no | lobby |
| - | (feedback) | automatic reward (mini reel / compact card) | UIBuilder reward reel, mini mode | no | no | - | live; NOT a primary, see §3 `Feedback` |

Rules:
- `UIState.Open(name, handle)` registers an open primary and returns `true` when it is on screen
  now, `false` when it is suspended behind a higher one. `UIState.Close(name)` removes it and
  the next one shows. Suspend/resume only toggle visibility (handle `Hide` / `Show`); they never
  fire remotes, grant, pick, reroll or close anything. UIBuilder's `show` / `hide` do this for
  every overlay, so producers keep calling `show` / `hide` (or `kit.Show` / `kit.Hide`).
- Code that asks "is my panel open?" must use `UIState.IsOpen(name)`, not `Overlay.Visible`
  (a suspended panel is open but invisible).
- `LevelUp` (70) above `Portal` (65): an upgrade earned before or during a stage clear is chosen
  first; the stage-clear panel waits and comes back with its remaining time (solo: the server's
  ChoiceLeft countdown stops while the run is frozen). Fixes Long 9:02.
- `Pause` (run menu) opens only when nothing above it is open (`UIState.CanOpen("Pause")`; the
  pause button also sits in the HUD, covered under every higher panel).
- The full reward reveal is a primary only while it covers (`setCovering("Reward", true)`); the
  mini reel is reward feedback. A full reveal suspended behind a higher panel keeps running
  hidden: presentation only, the server granted the reward before sending it.
- New screens (new upgrade chooser, compact reward card, results, duo run menu) keep these names.
  A new primary needs a row here first (ask UISTATE / the lead).

## 3. Lanes

| Lane | Slot | Who | Behaviour |
|---|---|---|---|
| `Objective` | persistent, top centre under the HP/XP panel | stage pill / objective (HUD), caravan defence bar (LootUI, `Hud.ReserveCentre`), boss bar | always visible during live play; headlines and notices are placed *below* reserved bars |
| `Headline` | centre banner (Hud renderer) | stage banner, portal reveal/open, waves, swarm pressure, boss arrival/defeat, run start/end | one at a time; queue max 3; same id dropped while queued or showing; each item has an expiry (stale ones are skipped); held while a primary covers the screen or a reward feedback card is up, except `Critical` |
| `Notice` | short pills under the top HUD (below the objective bars) | everything else from `Notify`, achievements, client toasts | max 2 visible on phones, 3 on PC; same id coalesces (text refreshed, "x2"); identical text within 4 s shows once; waiting notices expire (Info 6 s, Critical 3 s); while a headline shows only `Critical` / `Player` notices start and the whole stack sits directly under the headline |
| `Feedback` | beside the hero | automatic reward (mini reel today, compact card later) | `UIState.SetFeedback(true/false)`; holds non-critical headlines; hides the loot prompt |

Classes: `Critical` (threat: boss arrival, elite/swarm/wave sides, a teammate down, swarm
overwhelming) always shows during live play (it may wait only behind a primary that covers the
screen, where the run is frozen for this player). `Info` may queue, coalesce or expire.
`Player` (client `UIBuilder.Toast`: the answer to the player's own action, e.g. "Not enough
gold yet", "report sent") shows at once, even over a panel. Headlines: informational ones settle
0.15 s before showing so a twin from a second producer merges into them (the richer sub line and
sound win); the queue expiry is 6 s (Critical 4 s); the same id within 6 s is a duplicate.

Semantic ids (client classifier `UIState.Classify(text)` for server `Notify`, until the server
sends `Id` itself; a payload `Id` / `Lane` / `Class` field always wins):

| Id | Source | Lane / class |
|---|---|---|
| `portal.reveal` | StageManager Broadcast + StageUI PortalReveal | Headline Info (one banner) |
| `portal.open` | StageManager "THE PORTAL IS OPEN" | Headline Info |
| `swarm.pressure.N` | StageUI SwarmWarn | Headline: N=1 Info, N=2 Critical |
| `wave.N` | StageUI WaveSeq banner | Headline Critical |
| `wave.N.info` | EnemySpawner quiet-wave toast "WAVE N · ..." | Notice Critical; dropped if the `wave.N` headline showed |
| `wave.N.elite` | EnemySpawner loud-wave elite toast "Wave N: ..." | Notice Critical (sits under the wave headline) |
| `elite` | "An elite X hunts you!" | Notice Critical, coalesces |
| `swarm.approach` | "A swarm of X approaches!" | Notice Critical, coalesces |
| `big:<text>` | any other big broadcast (boss arrival title, enrage phases) | Headline Critical |
| `boss.defeated` | StageManager "... DEFEATED! SURVIVE THE SURGE!" | Headline Info |
| `stage.N` | Hud stage banner (when the stage card does not replace it) | Headline Info |
| `caravan.defend` | CaravanEvent start | covered by the objective bar: not shown as a notice |
| `caravan.result` | CaravanEvent end | Notice Info |
| `team.fallen.<text>` | RunManager "X has fallen" | Notice Critical (one per teammate) |
| `achievement` | AchievementUnlocked | Notice Info, coalesces |
| `run.start` / `run.end` | RunManager big broadcasts | Headline Info |
| `text:<text>` | anything else | Notice Info |

## 4. Input focus and interaction suppression

- `UIState.Owner()` = shown primary or nil. `UIState.WorldInputAllowed()` = no primary open.
  LootUI's hold (chest, shrine, altar, purchases) starts only when it is true, and any hold in
  progress is released the moment a primary opens (`UIState.OnOwnerChanged`).
- No click-through: the shown primary's overlay is the only Active panel; suspended overlays are
  invisible (Roblox does not route input to invisible GuiObjects).
- No stale held button: a primary's buttons must count only a press that *began* after it was
  shown (`UIState.ShownAt(name)`; the level-up already enforces this with its arm timer). After
  a primary closes, world interaction needs a new press (InputBegan), never a held key.
- Hidden UI never eats movement: the thumbstick is disabled only while the shown owner blocks
  (or the lobby menu). A watchdog (`UIState.Audit`, every frame) closes any on-screen primary
  whose overlay vanished without a `Close`, so a stale block cannot persist.
- The loot prompt is hidden while a primary is open or reward feedback is on screen (Long 9:10).

## 5. Lifecycle

| Event | UIState action |
|---|---|
| hero down (Alive false) | `Reset("death")`: headline/notice queues dropped; Revive primary may open |
| respawn / revive (Alive true) | `Reset("respawn")` (lanes only) |
| stage travel | `Open("Travel")`, `Reset("travel")`; `Close("Travel")` when the fade lifts |
| InRun changes (enter; leave, results, the run server going away) | `Reset("enter"/"leave")`; UIBuilder closes level-up, revive, reward, run menu (results / bug report stay) |
| reconnect mid-run | server re-sends the pending offer; it opens through `Open` like any other |

Pending earned decisions: the level-up offer, the portal choice and the reward reveal are held
by the server (LevelUpSystem / StageManager / RunManager.HoldReward) and re-sent; UIState never
drops or auto-resolves them. Suspending a panel does not stop a server timer: the solo run is
frozen during an upgrade choice (so the stage-clear countdown waits); in a group run the portal
countdown keeps running while a player picks (documented risk, CHOICE-SERVER).

## 6. Proven cases and the rule that fixes each

| Case | Evidence | Fix |
|---|---|---|
| Duplicate portal announcements | Short 0:13/0:14, Long 9:10 | both producers emit `portal.reveal`; the headline lane shows it once (the separate big-toast band is gone) |
| Caravan toast over the caravan panel | Short 0:50 | `caravan.defend` is covered by the objective slot; notices sit below reserved bars |
| Elite toast over the wave headline | Short 1:25 | while a headline shows, Critical notices go directly under it, Info notices wait |
| Four stacked notices | Long 8:12 | max 2 (phone) / 3 (PC) visible, `elite` coalesces, waiting notices expire |
| Upgrade above the Stage 2 clear dialog | Long 9:02 | one primary shown: Upgrade (70) suspends StageClear (65) until chosen |
| Reel + two portal headings + chest prompt | Long 9:10 | portal dedupe; headlines wait while reward feedback / a covering primary is up; loot prompt hidden |

## 7. API (summary)

```
UIState.Open(name, { Show, Hide, Blocks, Covers, Stacks }) -> on screen: boolean
UIState.Close(name)     UIState.IsOpen(name)    UIState.IsShown(name)   UIState.Owner()
UIState.CanOpen(name)   UIState.ShownAt(name)   UIState.WorldInputAllowed()
UIState.Blocking()      UIState.Covered()       UIState.OnOwnerChanged(fn)   UIState.Audit(fn)
UIState.Headline({ Id, Title, Sub, Color, Sound, Class, Expire })
UIState.Notice({ Id, Text, Color, Class, Seconds })
UIState.FromServer(data)            UIState.Classify(text, big) -> { Id, Lane, Class }
UIState.SetFeedback(on)             UIState.Reset(reason)       UIState.Step(now)
UIState.SetHold(name, on)           UIState.SetMaxNotices(n)
UIState.SetRenderer("Headline" | "Notice", fn)
```
