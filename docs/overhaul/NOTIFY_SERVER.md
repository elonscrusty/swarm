# Server notifications, group stage-clear hold, copy cleanups (NOTIFY-SERVER)

Phase 2 helper. Offline only (Lune preview / sims). NOT tested in Studio, on a device or in a
live multi-client session.

## 1. Id / Lane / Class on every Notify payload

`RunManager.Notify(player, text, color, meta?)` and `RunManager.Broadcast(text, color, big, meta?)`
now always send `{ Text, Color, Big, Id, Lane, Class }` (`RunManager.NotifyPayload`).
`meta = { Id, Lane?, Class? }` comes from the sender; without it a personal message is an Info
notice `text:<lower text>` and a broadcast is an Info notice or, when big, a Critical headline
`big:<lower text>`, which is exactly the client classifier's fallback. `RunServers` and
`PartyService` (they fire `Notify` directly) send the same fields.

Tagged senders (contract ids from UI_STATE_CONTRACT.md section 3, plus new ones):

| Sender | Id | Lane / Class |
|---|---|---|
| StageManager portal appeared / open | `portal.reveal` / `portal.open` | Headline Info |
| StageManager boss title | `boss.arrive` | Headline Critical |
| StageManager boss defeated | `boss.defeated` | Headline Info |
| StageManager stage n + RunManager stage 1 "find the portal" | `stage.objective` | Notice Info |
| EnemySpawner quiet / loud wave | `wave.N.info` / `wave.N.elite` | Notice Critical |
| EnemySpawner elite, swarm | `elite`, `swarm.approach` | Notice Critical |
| EnemySpawner nest spawn / destroyed | `nest.spawn`, `nest.destroyed` | Notice Info |
| BossAI phase message | `big:<lower text>` | Headline Critical |
| BossAI frost armour / war banner | `boss.armor` (regrow Critical), `boss.banner` | Notice |
| RunManager fallen | `team.fallen.<UserId>` | Notice Critical |
| RunManager left / returned / left through portal, rejoined, revived | `team.left.<UserId>`, `team.rejoined.<UserId>`, `team.revived.<UserId>` | Notice Info |
| RunManager Daily / Endless start, run end | `run.start.daily`, `run.start.endless`, `run.end` | Headline Info |
| RunManager daily scored line, curses | `run.daily.scored`, `run.curses` | Notice Info |
| RunManager lobby: run starting, arena set | `lobby.run.starting`, `lobby.arena` | Notice Info |
| CaravanEvent start / end (all three endings) | `caravan.defend`, `caravan.result` | Notice Info |
| LootSystem altar guards / unguarded / opened, bargain | `altar.guardians` (Critical), `altar.unguarded`, `altar.opened`, `shrine.bargain` | Notice |
| DevTools broadcasts | `dev` | Notice Info |

Deviation from the contract table: the boss arrival uses `boss.arrive` instead of `big:<text>`
(one id per arrival; UISTATE may add the row). `team.fallen.<UserId>` instead of the lower-cased
text (two lines for one fall share one id). The caravan "saved" line with a custom text and the
"left behind" line are now `caravan.result` (before, the classifier only caught texts containing
"caravan").

## 2. Stage-1 boss name

RunManager's run-start line said "summon the Scorpion Queen!" for every run. It now names
`BossData.Bosses[StageManager.StageBoss()].DisplayName` (rotation, Daily order or DEV-forced).

## 3. Group stage-clear countdown waits for an open upgrade choice (bounded)

Root cause: `StageManager.stepOpen` only stopped `ChoiceLeft` while the run was frozen (solo).
In Duo/Trio a player whose upgrade panel was open (it outranks the stage-clear dialog on their
screen, CHOICE_STATE.md) lost the countdown and was sent on as "Next" without seeing the dialog.

Fix (`StageManager.lua`, `Config.Stages.ChoiceHoldMaxSeconds = 12`): while the run is not frozen
and any living, not-returned participant has `rp.Paused and rp.Offer` (`StageManager.AnyChoiceOpen`,
same test as the `ChoiceOpen` attribute), the countdown does not tick, up to 12 s per stage clear
(reset in `openPortal`). After that it runs regardless. 12 s covers one group panel
(`GroupAutoPickSeconds` 10) plus grace; new panels cannot open during the dialog anyway
(`ChoiceDeferred = "Portal"`). Solo is unchanged (frozen run). New SwarmState attribute
`ChoiceLeftHeld` (bool) says the countdown is waiting.

Measured (`portal-hold-regression`): ChoiceLeft stays 15 for 3 s with a panel open; resumes after
the pick; with a fresh panel forced open every time one closes the clear still resolves after
26.6 s (15 + 12 cap); no panel: 14.7 s.

## 4. Copy cleanups

- "studs" -> "m": already done by COPY (StatSheet, ItemData, CharacterData). Verified: no
  player-facing string in `src` contains "stud" (only comments). No change needed.
- NoticeDots: the MORE tile's dot counts only Achievements and Track; Daily and Party have home
  buttons with their own dots.
- UIBuilder.Toast: texts with "upgraded to level" share id `upgraded`, so repeats fold into one
  pill ("x2", latest text).
- GoldSystem: removed the lobby "X upgraded to level N!" success notices (account and hero
  upgrades); the rows update from ProfileSync. Errors ("Not enough gold.", mastery) stay.

## 5. EliteSpawn sound

Was not wired. `EnemySpawner.Spawn` now calls `Fx.Sound("EliteSpawn")` for every elite (waves,
roaming, altar guards, caravan), never for bosses. The client spaces repeats (`MinGap` 1.2 s).

## 6. docs/PERFORMANCE.md

Arena table updated to the WORLD-ART numbers (Forest 1183, Ruins 1185, Swamp 1184, Snow 1251,
Desert 1043, Lava 1108; MeshParts and instances from docs/overhaul/WORLD_ART.md).

## Tests (offline Lune, `--studio --set headless=on`)

PASS: portal-hold-regression (new, in run_regressions.py), choice-regression,
run-manager-regression, settlement-lifecycle, uistate_regression, coop-regression x4
(success/expired/ended/forged), expedition-sim.
`check.sh --quick`: TYPECHECK exit 0 on the final run; the 3 remaining lint notes are unused
functions in UIBuilder's level-up section (another helper's edit in progress). An earlier run
had 62 errors there, also from in-progress edits by others; none in my files.
audio-sim: 1 FAIL "non-critical sounds leave the reserve free (10 of 12)": client Audio mix,
the sim does not boot the server, so not caused by the EliteSpawn wiring (AUDIO owner).

## Remaining risk / for others

- StageUI (~791): when `ChoiceLeftHeld` is true, show "Waiting for <name> to choose" next to the
  frozen number (it now just stops ticking).
- UI_STATE_CONTRACT.md table: add `boss.arrive`, `stage.objective`, `team.left/rejoined/revived.*`,
  `nest.*`, `altar.*`, `boss.armor`, `boss.banner`, `run.curses`, `run.daily.scored`, `lobby.*`, `dev`.
- NoticeDots: Track also has a home dot (account button); it still counts toward MORE as asked.
- Live multi-client behaviour of the hold (latency, three choosers) is BLOCKED (owner Studio test).
