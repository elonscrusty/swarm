# FEEL: boss intros, combo announcer, hit feel, music slots

Wave 1 of the 30-features batch (features 10, 26, 27, 28). Everything here runs on the
client and only changes what the player sees and hears. Damage, timing, the server
simulation and rewards stay exactly as they were. Each feature has its own switch in
`Config.Features`. With a switch set to `false`, the game behaves as it did before the
feature existed (`feel-regression` checks this).

| # | Switch | Module | Tuning |
|---|---|---|---|
| 10 | `BossIntro` | `src/client/BossIntro.lua` | `Config.Feel.BossIntro` |
| 26 | `Announcer` | `src/client/Announcer.lua` | `Config.Feel.Announcer`, sound `Config.Sounds.ComboMilestone` |
| 27 | `HitFeel` | `src/client/HitFeel.lua` | `Config.Feel.HitFeel` |
| 28 | `MusicSlots` | `src/client/Audio.lua` (`ResolveMusic`, `RunTrack`) | `Config.Sounds.WorldMusic_*`, `BossPhaseMusic` |

`ClientMain` starts the three modules after `FeatureHud`, and it picks the music through `Audio.RunTrack`.

## 1. Boss intro (10)

When a boss arrives (SwarmState `BossName` is set) or reaches a new phase (`BossPhase` goes up):

- **Name card:** shown through UIState's headline lane, under the same id the server's banner
  uses (`boss.arrive` for the arrival, `big:<phase message>` for a phase change). The two
  become one banner, and this one adds the "STAGE N BOSS · NAME" or "PHASE 2 · ENRAGED" line.
- **Solo:** the camera slides toward the boss and moves in a little. It eases in over `In`,
  holds, and eases out over `Out`, with a total of `Seconds` = 1.1 s (the code caps it at 1.2 s).
  Only the camera's position moves. Its angle stays the same, so the camera-relative controls
  don't change, and `MaxShift` (16 studs) keeps the hero on screen.
- **Co-op** (another player in the run): the camera doesn't move at all. Instead there's a short
  zoom (field of view × `CoopZoom`) and a dark edge `Vignette`.
- **Reduced effects or Screen shake 0:** the card only. The same applies while a panel covers the HUD.
- The world never pauses. No input is blocked and no damage is held back.

## 2. Combo counter and kill-streak announcer (26)

- The combo counts the local player's kills in a row, read from the `Kills` attribute (10 Hz). It
  ends after `ResetSeconds` (3 s) with no kill, on death, and when the run ends.
- The FeatureHud announcer line shows "37 COMBO" once the combo reaches `ShowFrom` (10).
- **Milestones** (`Milestones` = 50, 100, 250, 500, 1000, words in `Words`): each one gets one
  callout per combo, such as "RAMPAGE! 100". It plays the `ComboMilestone` chime (the existing
  SWARM SFX Item id), `PitchStep` semitones higher for every milestone. When one update crosses
  several milestones, only the highest is called out.
- **Working with UIState:** while a headline banner shows, the line clears. A milestone reached
  during a banner goes to the notice lane (id `combo.streak`, so quick repeats merge). Nothing
  shows while a panel covers the HUD.
- If another feature writes to the announcer line, the next combo update replaces its text.

## 3. Hit feel (27)

- **Hit-stop:** a crit within `CritRange` of the hero, or a huge kill (boss or large elite,
  `Config.Graphics.CombatFx.HugeKillSize`), holds the camera still for `StopSeconds` (35 ms,
  capped at 40). At most `MaxPerSecond` (2) can start in any second, at least `MinGap` apart.
  Only the view freezes; the server, the enemies and the controls keep running. It is off with
  Reduced effects or Screen shake 0.
- **Death burst:** chunks in the creature's colour fly out of a dead enemy, tumble, land and fade.
  - Bursts only show within `BurstRange` of the hero, at most `BurstsPerBatch` per batch.
  - The parts are pooled, at most `MaxPieces` (60) alive at once, refilled from a token bucket
    (`PiecesPerSecond`), with no Instance churn once warm.
  - With Reduced effects, only big kills get a burst, and with fewer chunks.
  - Nothing flashes. Chunks are parked when the run ends.
- This sits on top of CombatFx's existing shards and camera kick; it doesn't replace them.

## 4. Music slots (28) and the owner's steps for licensed music

- The run plays `WorldMusic_<Arena>` (Forest, Ruins, Swamp, Snow, Desert, Lava). The boss plays
  `BossMusic` in phase 1 and `BossPhaseMusic` from phase 2.
- Every slot is empty (`Id = ""`) and plays its `Fallback` (BattleMusic / BossMusic), so today
  the game sounds exactly as before. No new ids were invented. Tracks resume where they stopped
  and crossfade (`Config.Audio.Music`).

To add a track (owner, Studio):
1. Pick a track you may use: APMOfficial or a Creator Store track (Toolbox > Audio > Music), or
   music you own. Candidates and moods are in docs/AUDIO.md.
2. Copy its number and paste it as `"rbxassetid://<number>"` into the slot's `Id` in
   `src/shared/Config.lua` (for example `WorldMusic_Snow`). Keep `Volume` around 0.22-0.26.
3. Playtest that world in Studio and on the phone. Listen for the crossfade and for asset-access
   errors in the Output window.
4. To undo, set the `Id` back to `""`.

## Verified vs BLOCKED

- PASS (offline, Lune): `feel-regression`.
  - Switches off.
  - Music fallback and a slot with an id.
  - Solo push toward the boss, angle unchanged, done within 1.2 s, camera back.
  - The card merges with the server ids, and no pause.
  - Co-op zoom + vignette with no camera move, and reduced = card only.
  - Combo show, reset, one callout per milestone with its sound, the notice lane under a banner.
  - Bursts pooled and bounded under stress, hit-stop ≤ 40 ms, the per-second cap, crit range,
    reduced effects, and cleanup at run end.
- `perf-sim` (300 enemies, six evolved weapons, 8 s) before → after, Lune ms/frame (the
  machine was shared, so expect ±20% noise): VFX 9.6 → 10.7, CombatFx 0.96 → 1.21 (both
  unchanged code, so that's noise), HitFeel 1.16 new (5.6k BulkMoveTo parts/s against VFX's
  62k). After that run, `MaxPieces` went from 90 to 60 and `PiecesPerSecond` from 220 to 160.
  BossIntro and Announcer cost nothing while idle.
- BLOCKED: Studio, phone and live servers. Not tested there:
  - how the push and the hit-stop feel on a real device;
  - whether the headline merge order between the attribute and the server banner matches on
    real replication;
  - hearing the music slots.
