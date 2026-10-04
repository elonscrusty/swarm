# Audio mix (overhaul, section 9)

Offline only. Nothing here was heard; the owner must listen on a phone and on headphones.

## What changed
- `src/client/Audio.lua`
  - Reserve: non-critical sounds (priority below 4) may use at most `MaxVoices - 3` voices, so warnings always find a free one.
  - Ducking now also lowers Pickup (x0.6) and Player (x0.8) while a Warning or Boss sound plays, besides Combat (x0.45). Defaults live in Audio.lua (`A.Reserve`, `A.CriticalPriority`, `A.Duck.Also` override them).
- `Config.Sounds`
  - Per-sound `Priority = 5` for WaveHorn (wave start) and Heartbeat (low HP). Boss telegraphs were already priority 5.
  - New `EliteSpawn` (Warning, BossWhoosh id, low pitch, short music dip).
  - New UI-state cues, all existing approved ids re-pitched: `CardAppear` (compact reward card), `ChoiceOpen`, `ChoicePick` (upgrade choice), `ResultsLose`, `PartyJoin` (duo menu), `TitleStart` (title PLAY). Win results keep `Victory`.
- Already in place and kept: MinGap on every frequent sound, pitch variation, climbing gem scale, crowd ceiling, per-category voice caps, channel volumes (Combat / Interface / Warning), Visual Sound Cues (Accessibility.Cue runs before any gate, so a dropped sound still shows its cue).
- No new sound ids were invented.

## FOR OTHERS (callers; not wired by AUDIO)
- Server Fx / EnemySpawner: send `EliteSpawn` in the FxBatch name list (`batch.n`) when an elite spawns (VFX.lua already plays any name in `n`).
- UIKit.Sound / audio.Play: `CardAppear` in the compact reward card, `ChoiceOpen` when the upgrade chooser shows, `ChoicePick` on pick, `ResultsLose` on a lost results screen (UIBuilder.lua ~3720 plays Victory), `PartyJoin` when a partner joins MenuParty, `TitleStart` on the title PLAY press.

## Tests
- `tools/audio_regression.luau`: PASS (reserve voices, boss warning in a crowded mix, EliteSpawn is a Warning).
- `audio-sim` extended with section 7 (priority in a full mix, Pickup ducking) and 8 (UI cues, Warning channel volume). Result: see report.
- `tools/check.sh --quick`: typecheck and compile ok.

## Needs ears
- Is the 3-voice reserve audible as "missing" pickups during a heavy fight?
- Do Pickup/Player dips under a boss telegraph feel pumping?
- EliteSpawn and WaveHorn are re-pitched BossWhoosh / BossRoar: do they read as different cues?
- UI cues are re-pitched existing sounds; check they sit under the music and are not shrill.
