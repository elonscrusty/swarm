# TEAM: team combo, quick pings, co-op boss, spectate

Wave 2 of the 30-features batch (features 16, 17, 18, 20). Everything here is for Duo and Trio
runs only, so a solo run plays exactly as before. Each feature has its own switch in
`Config.Features`, and with a switch set to `false` the game behaves as it did before that
feature existed (`team-regression` checks this for all four).

| # | Switch | Server | Client | Tuning |
|---|---|---|---|---|
| 16 | `TeamCombo` | `TeamCombo.lua` | `TeamCombo.lua` (also starts the other three) | `Config.TeamCombo` |
| 17 | `QuickPings` | `TeamPingService.lua` (new presets) | `PingWheel.lua`, `TeamPings.lua` | `Config.QuickPings`, `Config.TeamPings` |
| 18 | `CoopBoss` | `CoopBoss.lua` + a hook in `BossAI.lua` | `WeakSpot.lua` | `Config.CoopBoss` |
| 20 | `Spectate` | `TeamPingService.lua` (REVIVE ME) | `Spectate.lua`, `CameraController.SpectateCycle` | `Config.Spectate` |

New remote: `TeamComboFire` (client to server, no arguments). `ClientMain` starts
`TeamCombo.Init()` after the HEROPOWER pieces. `GameServer` loads `TeamCombo` and `CoopBoss`
and steps `TeamCombo` every frame.

## 16. Team combo

- There is one shared meter per run. It fills while two **free** players stand within `Radius`
  (12 studs) of each other and the world is running. A full meter takes `ChargeSeconds` (25 s).
  When nobody is paired, the meter drains over `DrainSeconds`, but a full meter stays full.
- A free player is alive, still in the run, not waiting on the revive offer, not choosing a card
  (`rp.Offer` / `rp.Paused`, which is choice protection) and not in a chest reward pause. A
  protected player can't charge the meter or fire the combo, so it can't be farmed from a panel.
- **Fire:** when the meter is full, either player of a pair presses COMBO (a round button left
  of ULT), **F**, or gamepad **L1**. The client only sends `TeamComboFire`, and the server
  checks the switch, the run, a free sender with a free partner in range, the full meter, the
  `Cooldown` (40 s) and `MaxPerStage` (3).
- **Effect:** every enemy within `BurstRadius` (20) of the pair's middle takes
  `min(Cap, Damage + PerLevel × (average level − 1))` once, as proc damage (no crits, no item
  procs). Elites, guards, mini-bosses and nests take at most `EliteShare` (20 %) of their max HP,
  and bosses take at most `BossShare` (4 %), so a boss is never killed outright. The burst uses
  both players' ping colours (existing Fx rings, explosion, chain).
- **HUD:** a FeatureHud badge shows "TEAM 46%", "COMBO READY" or "GET CLOSE". Each burst
  announces "TEAM COMBO!".
- **State:** SwarmState `TeamCombo` (0..1), `TeamComboPair` (",id,id,"), `TeamComboUsed`. These
  are cleared outside co-op runs.

## 17. Quick pings and emotes

- The PING button and **G** open a ping wheel in the FeatureHud `PingWheel` slot instead of the
  old five-option panel (with the switch off, the old panel comes back). Gamepad: **DPadUp**
  opens it, **DPadLeft/Right** move the highlight and **DPadDown** sends. Keyboard: **1-6**
  while it is open. Touch: tap an option, or tap the dimmed area or X to close it.
- The options are HELP HERE, CHEST HERE (the nearest chest, as before), GO PORTAL (the portal
  itself, with no distance limit), ON MY WAY and the two emotes HELLO! and NICE! (shown over the
  sender). All options are 76 px, which is above the 44 px touch minimum.
- Every option goes through `TeamPingService.Send`, so the rules stay the same: presets only (no
  text, so no filtering is needed), group runs only, the sender must be alive, a per-player
  `Cooldown` (2 s) and the remote rate limit (4/s). The marker text comes from
  `Config.QuickPings.Labels`.
- The wheel closes after a send, on death, outside a team run and whenever a panel covers the
  HUD.

## 18. Co-op boss: the weak spot

- **Variant boss:** `Config.CoopBoss.Boss` = Scorpion Queen (the stage 1 boss, so most groups meet
  it). The variant only runs while `MinPlayers` (2) or more players are alive in the run.
- **Aggro holder:** the boss's target (EnemyAI: the nearest free player). A switch that lasts less
  than `LoseSeconds` (0.6 s) counts as a flicker and keeps the holder. Once the holder has kept it
  for `HoldSeconds` (3 s) while the boss fights (not during its entrance, collapse or burrow), a
  weak spot opens on the side away from the holder for `OpenSeconds` (6 s). Then there is a
  `Cooldown` (8 s) before the next one.
- **Damage:** while the spot is open, hits from the **other** players standing behind the boss
  (dot < `BackDot`) deal `Mult` (×1.5). The extra damage is capped at `MaxBonusShare` (5 %) of the
  boss's max HP per opening. The holder's hits and hits from in front are unchanged. The spot
  closes if the aggro moves or the holder falls.
- **Telegraph:** a notice ("Weak spot open! Hit its back!", id `boss.weakspot`), a glimmer pop at
  the spot, a slowly pulsing gold floor ring with a "HIT HERE" tag (`WeakSpot.lua`, which never
  flashes) and a badge: "HIT ITS BACK" for the others, "HOLD AGGRO" for the holder.
- **Hook:** `BossAI.Variant = { Step, Hit, Clear }` (documented in BossAI). `EnemySpawner.Damage`
  calls `BossAI.ModifyHit` for player hits on bosses. Without a variant, both are no-ops.
- **State:** SwarmState `BossWeakSpot` (Vector3, only while open) and `BossAggroId`.

## 20. Spectate

- The camera already followed a living teammate while you were down. Now, while you are down or
  out in a Duo or Trio run, a bar shows:
  - **[<] WATCHING NAME [>]:** sits under the timer in landscape and bottom-left in portrait.
    The arrows, **Left/Right** and gamepad **DPadLeft/Right** cycle through the living teammates
    (`CameraController.SpectateCycle`), and the camera glides over.
  - **REVIVE ME:** sits bottom-left, where PING is while you are alive. It shows while a teammate
    can still revive you. It sends the `ReviveMe` ping at your body, which the server checks:
    the sender must be down, not on the revive offer, have revives left, and pass the cooldown.
    **G** and gamepad **DPadUp** also send it.
- When you are revived, the bar goes and the camera glides back to your hero. When the run ends,
  the lobby camera takes over. Spectate keeps no camera state of its own.

## Tests

- `team-regression` (new, 83 PASS lines, 0 failures). It uses the real server and the client
  modules in a Duo, a Trio, a solo run and a Duo with every switch off. There are 4 players: 3 in
  runs, plus 1 in the server who is never in a run.
  Run line: `("team-regression", [])` in the main scene list.
  Manual: `lune run tools/preview/runtime/main.luau -- --scene team-regression --studio --device pc --out x.json --max-time 600 --set headless=on`.
- `team` scene: new options `--set wheel=on`, `--set combo=full|half` and `--set weakspot=on`
  (`me=down` shows the spectate bar). Layout checks (check_layout, `images=loaded`, `mode=Duo`):
  - 0 problems for `wheel=on` on iphone and phone-portrait, `me=down` on iphone, and
    `combo=full weakspot=on` on phone-portrait.
  - Two existing problems, not from TEAM: (a) phone-portrait `me=down`: the minimap covers the
    HUD's "A teammate is reviving you" status line (Hud layout). (b) iphone: a FeatureHud badge
    covers the "TEAM TIP" chip of the tutorial card. This is the FeatureHud badge row placement
    (see the EVENTS note on the badge row), and it happens with any badge.
- `team_pings_regression` (phone, phone-portrait) still passes. The old panel works as before
  when PingWheel isn't started.

## Verified vs BLOCKED

- Verified offline (Lune mock): the rules above, the server checks, caps, flags off, solo
  unchanged, the touch sizes and the phone layouts listed.
- BLOCKED (needs Studio or a real device): real 2-4 player sessions and network latency, how the
  combo burst and weak-spot ring look and feel in play, gamepad and keyboard on real hardware,
  and balance (the combo damage and the weak-spot ×1.5 are first guesses).
- Not done: the 2 emotes are text callouts over the hero, with no animation. Emote animations are
  owner art.
