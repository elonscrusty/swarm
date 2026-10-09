# Audio: sounds, music and the owner checklist

## What plays now

**Sound effects: original SWARM sounds.** The owner said the old effects were awful (they were
Roblox UI-pack clicks and built-in `collide.wav` / `splat.wav` thumps reused for everything). Every
effect the player hears often was replaced on 2026-10-03 with sounds made for this game:

- Made from scratch in code (`tools/synth_sfx.py`: oscillators, filters, a small reverb; no samples,
  so no licence questions). Style: warm fantasy, low-mid and soft-edged for the frequent sounds,
  bells, chords and a hall tail for the rewards. Built with energy above 250 Hz so they still come
  through phone speakers.
- Uploaded by the owner's account (user 20194281) through Open Cloud (`tools/upload_audio.py`).
  **All 26 came back `Approved` from Roblox moderation, asset type Audio** (checked with
  `python3 tools/upload_audio.py --check`). Ids and status: `art/audio/uploaded_ids.json`;
  the `.ogg` files are in `art/audio/`.
- NOT yet heard by anyone. They were checked by spectrum and loudness numbers only (no speakers in
  the build machine). The owner's ears decide; see the checklist below.

| File (art/audio) | Asset id | Used by (Config.Sounds) |
|---|---|---|
| Hit | 132528923449580 | Hit |
| EnemyDeath | 121753247942951 | EnemyDeath |
| Lightning | 74962400988388 | Lightning |
| Explosion | 121247904139587 | Explosion |
| Swing | 110381677719056 | Swing, Throw |
| Hurt | 103629944065626 | Hurt |
| Heartbeat | 106832514643917 | Heartbeat (low HP) |
| Death | 106619962538253 | Death |
| LevelUp | 131826585081742 | LevelUp |
| Revive | 97435297484172 | Revive |
| BigKill | 79432466085613 | BigKill |
| Evolve | 93333085469531 | Evolve |
| GemPickup | 111456984593913 | GemPickup |
| Coin | 86606172414417 | Coin |
| Chest | 109507162178062 | Chest |
| Item | 105588297309015 | Item |
| Shrine | 106727264178055 | Shrine |
| PortalAppear | 72802301491749 | PortalAppear |
| Victory | 71641610011777 | Victory |
| BossRoar | 135802539734782 | BossRoar |
| BossWhoosh | 113336786346138 | BossWarn, BossWave, BossGust |
| BossSlam | 114145211136875 | BossPound, BossEmerge |
| Click | 130072904039232 | Click |
| Toggle | 78864064038524 | Toggle |
| Tip | 133320151991833 | Tip, HealPulse |
| ReelTick | 111197240897473 | ReelTick |

### Second batch: class cues, run stages, crits (stream G, 2026-10-09)

26 more original sounds, made the same way (`python3 tools/synth_sfx.py --new`; each is reseeded from its own
name, so `--only Name` renders the same file as a full run; never run `synth_sfx.py` with no flag to "refresh":
it re-renders the first 26 too and their files would no longer match the ids above). Uploaded with
`ROBLOX_USER_ID=20194281 python3 tools/upload_audio.py`; **all 26 are `Approved`, asset type Audio** (checked with
`--check`, ids in `art/audio/uploaded_ids.json`). NOT heard by anyone yet: spectrum and loudness numbers only
(every file has most of its energy above 250 Hz for phone speakers; volumes from each file's loudest 100 ms,
target about -29 dB effective for the frequent class cues, like Hit and Coin).

| File | Asset id | Cue and what plays it |
|---|---|---|
| ScrapClatter | 126675498482317 | Ruckus: Scrap Shot leaves the hero (visual 57), lighter at its impact; dash (rolling cans) |
| ToastPop | 89543620087020 | Toastmaster: Toast Toss (visuals 58, 62); spring jump; landing blast pop (>= 0.35 s in the air) |
| BubbleBloop | 132010916160149 | Captain Croak: Bubble Bomb (59, 63), higher at the burst; leap |
| YarnPop | 81759392777602 | Granny Boom: Yarn Bomb (60), full pop at the blast; rocket boost |
| DodgeballThump | 130806214212181 | Coach Crunch: Dodgeball (visual 45), impact |
| DodgeballWhistle | 125785610035813 | Coach Crunch: shoulder-tackle dash |
| MopSwoosh | 100812590264480 | Doug: every Mop Sweep slash |
| MopSqueak | 130304148137330 | Doug: every 3rd sweep, and the dash |
| ConfettiRattle | 125336972916367 | Rambozo: Confetti Minigun burst (visual 24; five pellets are one rattle) |
| ConfettiHonk | 123550918869276 | Rambozo: every 6th burst, and the dash balloon |
| GymScrape | 123947392192969 | Swolverine: every Protein Claws swipe; dash |
| PuckClack | 101673143804604 | Crash Cassidy: Ricochet Puck (visual 49) leaving and every bounce / end |
| SkateRoll | 78117229124778 | Crash Cassidy: body-check dash |
| GloveThud | 87565218066949 | Knuckles: every punch; dash |
| GloveBell | 111533137471424 | Knuckles: the uppercut (slash tier 3), with a thud |
| ShoeBoing | 98678378204244 | Peter: Returning Sneakers throw (visual 5), every jump (lower when charged), dash |
| SeedSprout | 104808793216642 | Barry: seed flick (visual 45), a plant taking root (visual 51), dash |
| CritTick | 130747321535480 | the local hero's own critical hit (the server says who rolled it: FxBatch `ku`) |
| BeaconActivate | 101983713680096 | RunStage `Rally`: the beacon is lit |
| BeaconCharge | 116632965410778 | RunStage `Charge`: a seamless 2 s hum (loop), louder and higher as `BeaconCharge` fills, quieter when the hero is far from the beacon |
| BossSpawn | 77012636523636 | RunStage `Boss`: swell, brass stab, drum (+ a boss-kind camera shake) |
| RunVictory | 135733489539540 | RunStage `Victory`: the stinger; the results `Victory` fanfare waits 6 s for it |
| RunDefeat | 122212551428474 | RunStage `Defeat`: the stinger; the results `ResultsLose` waits 6 s |
| Downed | 116846841000990 | the local hero goes down (`Downed` attribute); teammates' falls keep the global `Death` sound |
| ReviveBeat | 96148528483086 | a revive hold on a downed hero (own or one within 14 studs): one pulse per 0.45 s, rising in pitch with `ReviveProgress`; the finished revive is the existing `Revive` |
| ChestBuy | 127806368430108 | the team pays for a chest (SwarmState `ChestCost` steps up / `TeamRunGold` drops by about a price) |

`RunStage` `BeaconAvailable` plays the existing `PortalAppear` (the reveal). Every cue above lives in
`Config.Sounds` (class cues and the crit tick in the new **Weapon** group, stingers in UI / Boss, the hum in
**Stage**) and is wired by `src/client/ClassSfx.lua`; the fire / impact / swing hooks are in `VFX.lua`
(new projectile next to a hero, a projectile ending, a slash), the crit tick in `CombatFx.Crit`.

**Limits (Config.Feel.ClassSfx, Config.Audio).** A hero's cue repeats at most every 0.12 s; all class cues
together start at most 9 per second; the Weapon group holds at most 3 voices (the oldest gives way) and sits
at priority 2 under the Combat slider, so hits, pickups, UI, player and warning sounds always win; a teammate's
cue plays at 45 % and only within 70 studs (teammates' crit ticks are silent); the group is ducked to 50 % while
a warning or boss cue plays. The beacon hum is a loop outside the 12-voice mix (its own group, ducked to 60 %
by warnings). `RunVictory` / `RunDefeat` have `Keep = true`: the end-of-run sound sweep (`Audio.StopEffects`)
lets them finish.

**Music pressure.** `Audio.SetIntensity(level)` (ClassSfx, from `RunStage`: Survive 0, BeaconAvailable 0.25,
Rally 0.6, Charge 0.8, Boss 1) lifts the playing track by up to 14 % (`Config.Audio.Music.IntensityBoost`,
2.5 s ease). While raised, a warning or boss cue dips the music to 75 % for its duck, so a telegraph is never
masked. Track choice and crossfades are unchanged; 0 outside a run.

**Camera shake (Config.Camera, CameraController).** Ordinary feedback (hurt, explosions) shakes at most
0.4 studs for 0.11 s (< 0.12 s); a boss event (Queen roar, phase change, the Boss stage, a huge kill) is the one
longer shake: at most 0.55 studs for 0.3 s. Reduced effects and Screen shake 0 give none. The 35 ms camera-only
hold in HitFeel is unchanged (it never touches the simulation) and is off with Reduced effects.

**Checks.** `class-sfx-regression` (client: 12 class cues, limits, movement, run stages, down / revive / chest,
crits, shake, recoil; about 100 PASS lines), `crit-owner-regression` (real server), `audio-sim`.

Still on Roblox built-in sounds (they ship with every client and are short warning ticks):
FuseTick, BossMine (`clickfast.wav`), SpitterWindup, BossSummon, BurrowWarn (`splat.wav`),
Lunge, BossBanner (`unsheath.wav`).

**Asset access.** Audio uploaded by a user plays in experiences that user owns. If SWARM is
published under a **group**, open each asset in Creator Hub (Creations > Audio) and grant the group
experience permission, or the sounds are silent (Output shows "asset is not approved for the
requester" / permission errors).

**Music: unchanged tracks, better mixing.** Still the three APMOfficial tracks below (licensed by
Roblox for free use in any experience). No new music is wired; that is the owner's pick.

| Use | Asset | Title / artist | Duration |
|---|---|---|---|
| Lobby | [1836939228](https://create.roblox.com/store/asset/1836939228) | Celtic Adventures / Bob Bradley | 136 s |
| Battle | [9047425352](https://create.roblox.com/store/asset/9047425352) | Drums of Battle / Gabriel Saban | 167 s |
| Boss | [1838623501](https://create.roblox.com/store/asset/1838623501) | Hell Ride / Thomas Parisch | 141 s |

Metadata checked 2026-10-02 via `apis.roblox.com/toolbox-service/v1/items/details` (verified
creator APMOfficial, user 7462718749, public audio).

## How the mix works (Config.Audio, client Audio.lua)

- **Loudness ladder.** Frequent sounds sit low (Hit 0.10, EnemyDeath 0.12, GemPickup 0.07,
  Coin 0.11); player feedback in the middle (Hurt 0.32); rewards and big moments on top
  (LevelUp 0.46, Chest 0.6, PortalAppear 0.52, Victory 0.55, BossRoar 0.5). Volumes were set
  from each file's measured loudness (loudest 100 ms), not guessed.
- **No machine-gun repeats.** Pitch spread on every combat sound (PitchVar 0.12-0.18). Gem
  pickups play notes of a pentatonic scale and **climb** while you keep collecting (reset after
  0.35 s); coins pick one of three notes.
- **Swarm safety.** MinGap per sound, voice caps per category (12 total), priority stealing,
  and the crowd ceiling that fades Combat/Pickup towards 35 % in a dense fight.
- **Ducking.** Warnings/boss cues duck combat noise. New: sounds with `DuckMusic` (LevelUp,
  Chest, Evolve, Shrine, PortalAppear, BossRoar, Victory, Death, Revive) dip the music to 40 %
  for a moment (`Config.Audio.MusicDuck`), then it swells back over 1.2 s.
- **Music.** Crossfade 1.5 s between lobby / battle / boss, battle resumes where it stopped
  after a boss, track volumes lowered (0.26 / 0.22 / 0.26). The Music and Effects sliders, the
  Combat / Interface / Warning channel sliders and Mute All are unchanged.

## Owner checklist (Studio, about 20 minutes)

1. **Listen first.** Play a run on the phone. For each sound below, note "keep" or "swap".
   Fast way to audition one sound in Studio: Explorer > SoundService > the sound named in the
   table (e.g. `LevelUp1`) > Properties > tick **Playing**.
2. **Rollback any one sound** if you prefer the old one: in `src/shared/Config.lua`,
   `Config.Sounds`, paste the old id back:

   | Sound | Previous id |
   |---|---|
   | Hit | rbxassetid://16480568821 |
   | EnemyDeath | rbxassetid://17208204604 |
   | Lightning | rbxassetid://15930283552 |
   | Explosion, BossPound | rbxassetid://3149249837 |
   | LevelUp, Revive | rbxassetid://15675043410 |
   | Evolve | rbxassetid://17208327798 |
   | GemPickup, ReelTick | rbxassetid://15675032796 |
   | Coin | rbxassetid://17208319162 |
   | Chest | rbxassetid://17208380755 |
   | Item | rbxassetid://17208323435 |
   | Shrine, PortalAppear | rbxassetid://17208372272 |
   | BossRoar | rbxassetid://9120031442 |
   | Click | rbxassetid://17208396156 |
   | Toggle | rbxassetid://17208408337 |
   | Swing / Throw / Hurt / Heartbeat / Death / BigKill / Victory / Tip | rbxasset://sounds/ swordlunge.wav, Rocket whoosh 01.wav, action_jump_land.mp3, collide.wav, collide.wav, collide.wav, victory.wav, electronicpingshort.wav |

   GemPickup's `Pitch = 0.5` and `Steps` assume the new file; set `Pitch = 1.1` and remove
   `Steps`/`Climb` if you roll it back.
3. **Swap a sound for a Creator Store one.** Studio > Toolbox > Marketplace > Audio, filter
   "Sound Effects". Roblox-uploaded and APM sounds are free. Click to preview; right-click >
   Copy Asset ID; paste into Config as `"rbxassetid://<id>"`. Good search words:

   | Slot | Search |
   |---|---|
   | Hit | "soft impact", "punch light", "body hit" |
   | EnemyDeath | "poof", "puff", "creature death small" |
   | GemPickup | "crystal chime", "gem pickup", "magic ding" |
   | Coin | "coin collect", "coin single" |
   | LevelUp | "level up fantasy", "magic success", "orchestral sting" |
   | Chest | "treasure chest open", "chest reward" |
   | PortalAppear | "portal open", "magic whoosh rise" |
   | BossRoar | "monster roar", "giant roar" |
   | Click / Toggle | "ui click soft", "wood click" |
   | Victory | "fanfare short", "victory orchestral" |

4. **Make your own variant.** Edit a function in `tools/synth_sfx.py`, then
   `python3 tools/synth_sfx.py --only Chest` and
   `ROBLOX_USER_ID=20194281 python3 tools/upload_audio.py --only Chest --force`; wait for
   `python3 tools/upload_audio.py --check` to say `ok` before pasting the id.

## Music: choosing tracks (owner)

Licensed music only: APMOfficial or Roblox-uploaded tracks from the Creator Store (Toolbox >
Audio > Music), or music you own the rights to. Paste ids into `LobbyMusic` / `BattleMusic` /
`BossMusic` in `Config.Sounds`. Mood per context:

- **Lobby: calm, heroic, inviting.** Light orchestral or Celtic, mid tempo, no heavy drums.
- **Run: driving, upbeat, loops well.** Percussive orchestral or adventure rock, steady energy,
  nothing that peaks and drops (it runs 10+ minutes; 2+ minute tracks loop less obviously).
- **Boss: intense, darker.** Choir or brass hits, faster, clearly different from the run track.
- **Results:** the Victory fanfare plays over the lobby track; a separate results track is
  optional.

APMOfficial candidates found by keyword search (title/duration only, **not heard**; audition
before using): Lobby: 1842961239 *Frontiers (Underscore Version)* 130 s. Run: 9048541013
*Battleground* 131 s, 1846428560 *Forces Of Nature B* 122 s, 1842754581 *Enemy Escape* 128 s,
9045942872 *Secret Warrior - Alternative Mix* 118 s, 1837240654 *On the Warpath* 115 s.
Boss: 9043171470 *Edge Of Extinction* 160 s, 9045953483 *Last Man Standing* 137 s,
1838626031 *Hell Ride (No Choir)* 140 s (calmer version of the current boss track).

Per-world and boss-phase tracks (feature 28, `Config.Features.MusicSlots`): the slots
`WorldMusic_Forest` ... `WorldMusic_Lava` and `BossPhaseMusic` in `Config.Sounds` are empty
and play their `Fallback` (BattleMusic / BossMusic) until an id is pasted. Steps:
docs/features/FEEL.md section 4.

## Required live checks

- In Studio and on the owner's phone, hear lobby, battle and boss tracks with no asset-access errors.
- The new SWARM effects play (no "failed to load" / permission lines in Output) and sound good on the phone speaker; LevelUp, Chest and the portal dip the music and it comes back.
- Collect a stream of gems: the chimes rise in pitch, then restart low after a pause.
- Travel between phases rapidly; crossfades do not leave overlapping full-volume tracks, and returning battle music resumes.
- Set Music and Effects to zero separately; the corresponding channels become silent.
- In a dense fight, danger warnings remain audible over hits, deaths and low-health feedback.
- Exit or die repeatedly; no old warning or heartbeat continues outside its run.
- With Reduced Effects on, low-health danger remains readable without an animated flash.
- Second batch (listen once per class on the phone speaker): each class's fire / swing, impact and dash cue is quiet, short and
  never repeats like a machine gun; a dense co-op fight keeps boss telegraphs clearly audible over the class cues and the louder
  Charge / Boss music; the crit tick is easy to pick out but not tiring; the hum rises as the beacon fills and stops with the Boss stage;
  the Victory / Defeat stinger plays once and the results screen's own sound follows ~6 s later, not on top. Any cue you dislike can be
  silenced with `Id = ""` in its `Config.Sounds` entry (the call then does nothing).

Offline audio simulation checks mixer state, voice caps, ducking and crossfades. It is silent and cannot substitute for listening in Roblox.
