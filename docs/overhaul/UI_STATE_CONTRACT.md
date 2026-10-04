# UI state contract (UIState)

Owner: UISTATE helper. Code: `src/client/UIState.lua`. Every client screen that opens a panel,
shows a centre headline or a short notice goes through this module. Build new screens on it;
do not add parallel listeners, private toast stacks or private banner queues.

Status: implemented in code, type-checked and exercised in offline previews and a Lune unit
test (`tools/preview/uistate_test.luau`). NOT tested in Studio or on a device.

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

Higher number wins. "Blocks" = thumbstick and world interaction off while shown.
"Covers" = HUD, minimap and item strip hidden under it.

| Priority | Name (UIState) | UIBuilder name | Producer | Blocks | Covers | What the world does |
|---|---|---|---|---|---|---|
| 100 | `Transition` | (StageUI travel fade) | StageUI `StageTravel` | yes | no (own fade) | server holds (StageManager.IsHolding) |
| 95 | `BugReport` | `BugReport` | BugReportUI | yes | yes | unchanged (sub-panel of Results / RunMenu) |
| 90 | `Results` | `Results` | UIBuilder `RunResult` | yes | yes | run over |
| 80 | `Revive` | `Revive` | UIBuilder `ReviveOffer` | yes | yes | hero down; teammates play on |
| 70 | `Upgrade` | `LevelUp` | UIBuilder `LevelUpOffer` | yes | yes | solo: run frozen; group: only the chooser is protected (CHOICE-SERVER) |
| 65 | `StageClear` | `Portal` | StageUI `PortalOffer` | yes | yes | stage over; countdown stops while the run is frozen |
| 60 | `Reward` | `Reward` (full reveal only) | UIBuilder reward reel (rare / paused rewards) | no | yes | server holds the reward pause (bounded) |
| 55 | `Items` | `Items` | LootUI items list (from the run menu) | yes | yes | as the run menu |
| 50 | `RunMenu` | `Pause` | UIBuilder pause / settings | yes | yes | solo: paused; group: live (label says so) |
| 40 | `DevInbox` | `DevInbox` | DevInbox (lobby only) | no | no | lobby |

Rules:
- `UIState.Open(name, handle)` registers an open primary; returns `true` when it is shown now,
  `false` when it is suspended behind a higher one. `UIState.Close(name)` removes it and resumes
  the next one. Suspend/resume only toggle visibility; they never fire remotes, grant, pick,
  reroll or close anything.
- Upgrade (70) above StageClear (65): an upgrade earned before or during a stage clear is chosen
  first; the stage-clear panel waits (the server's ChoiceLeft countdown stops while the run is
  frozen, solo). This fixes the upgrade drawn over the Stage 2 clear dialog (Long 9:02).
- RunMenu (50) opens only when nothing above it is open (`UIState.CanOpen("RunMenu")`); the
  pause button sits in the HUD, which is covered under every higher primary anyway.
- The automatic *mini* reward (and the compact reward card that replaces it) is NOT a primary:
  it is reward feedback (section 3) and never takes input.
- New screens (new upgrade chooser, compact reward card, results, duo run menu) keep these
  names. A new primary needs a row here first.

## 3. Lanes

| Lane | Slot | Who | Behaviour |
|---|---|---|---|
| `Objective` | persistent, top centre under the HP/XP panel | stage pill / objective (HUD), caravan defence bar (LootUI, `Hud.ReserveCentre`), boss bar | always visible during live play; headlines and notices are placed *below* reserved bars |
| `Headline` | centre banner (Hud renderer) | stage banner, portal reveal/open, waves, swarm pressure, boss arrival/defeat, run start/end | one at a time; queue max 3; same id dropped while queued or showing; each item has an expiry (stale ones are skipped); held while a primary covers the screen or a reward feedback card is up, except `Critical` |
| `Notice` | short pills under the top HUD (below the objective bars) | everything else from `Notify`, achievements, client toasts | max 2 visible on phones, 3 on PC; same id coalesces (text refreshed, "x2"); waiting notices expire; while a headline shows only `Critical` notices appear (directly under the headline), the rest wait |
| `Feedback` | beside the hero | automatic reward (mini reel today, compact card later) | `UIState.SetFeedback(true/false)`; holds non-critical headlines; hides the loot prompt |

Classes: `Critical` (threat: boss arrival, elite/swarm/wave sides, a teammate down, swarm
overwhelming) always shows during live play (it may wait only behind a primary that covers the
screen, where the run is frozen for this player). `Info` may queue, coalesce or expire.

Semantic ids (client classifier `UIState.Classify(text)` for server `Notify`, until the server
sends `Id` itself; a payload `Id` / `Lane` / `Class` field always wins):

| Id | Source | Lane / class |
|---|---|---|
| `portal.reveal` | StageManager Broadcast + StageUI PortalReveal | Headline Info (one banner, 8 s expiry) |
| `portal.open` | StageManager "THE PORTAL IS OPEN" | Headline Info |
| `swarm.pressure.N` | StageUI SwarmWarn | Headline Critical at N=2 |
| `wave.N` | StageUI WaveSeq banner | Headline Critical |
| `wave.N.info` | EnemySpawner quiet-wave / elite toast | Notice Critical; dropped if `wave.N` headline shows |
| `elite` | "An elite X hunts you!" | Notice Critical, coalesces |
| `swarm.approach` | "A swarm of X approaches!" | Notice Critical, coalesces |
| `boss.arrive` / `boss.defeated` | StageManager big broadcasts | Headline Critical / Info |
| `caravan.defend` | CaravanEvent start | covered by the objective bar: not shown as a notice |
| `caravan.result` | CaravanEvent end | Notice Info |
| `team.fallen` | RunManager fallen | Notice Critical |
| `achievement` | AchievementUnlocked | Notice Info, coalesces |
| `run.start` / `run.end` | RunManager big broadcasts | Headline Info |
| text hash | anything else | Notice Info, identical text within 4 s shows once |

## 4. Input focus and interaction suppression

- `UIState.Owner()` = shown primary or nil. `UIState.WorldInputAllowed()` = no primary open.
  LootUI's hold (chest, shrine, altar, purchases) starts only when it is true, and any hold in
  progress is released the moment a primary opens (`UIState.OnOwnerChanged`).
- No click-through: the shown primary's overlay is the only Active panel; suspended overlays are
  invisible (Roblox does not route input to invisible GuiObjects).
- No stale held button: a primary's buttons must count only a press that *began* after it was
  shown (`UIState.ShownAt(name)`; the level-up already enforces this with its arm timer). After
  a primary closes, world interaction needs a new press (InputBegan), never a held key.
- Hidden UI never eats movement: the thumbstick is disabled only while the shown primary blocks.
  A watchdog (`UIState.Audit`, every frame) closes any registered primary whose overlay is no
  longer visible and not suspended, so a stale block cannot persist.
- The loot prompt is hidden while a primary is open or reward feedback is on screen (Long 9:10).

## 5. Lifecycle

| Event | UIState action |
|---|---|
| hero down (Alive false) | `Reset("death")`: headline/notice queues dropped; Revive primary may open |
| respawn / revive | `Reset("respawn")` (lanes only) |
| stage travel | `Open("Transition")`, `Reset("travel")`; `Close("Transition")` when the fade lifts |
| InRun false (leave, results, disconnect of the run) | `Reset("leave")` and every run primary closed except `Results` / `BugReport` |
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
UIState.Open(name, { Show = fn, Hide = fn, Blocks = bool, Covers = bool }) -> shown: boolean
UIState.Close(name)                 UIState.IsOpen(name)        UIState.Owner()
UIState.CanOpen(name)               UIState.ShownAt(name)       UIState.WorldInputAllowed()
UIState.OnOwnerChanged(fn)          UIState.Audit()
UIState.Headline({ Id, Title, Sub, Color, Sound, Class, Expire })
UIState.Notice({ Id, Text, Color, Class, Seconds })
UIState.FromServer(data)            UIState.Classify(text, big) -> { Id, Lane, Class }
UIState.SetFeedback(on)             UIState.Reset(reason)       UIState.Step(now)
UIState.SetRenderer("Headline" | "Notice", fn)   UIState.SetCovered fn hooks
```
