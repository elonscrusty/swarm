# Stream H1: pacing, boss and performance of the beacon run

Brief sections: "Full-loop quality targets", "Progression and personal choices" (targets), "Enemy
pressure and final objective" (boss 45-90 s), "Validate authority and measure the complete loop",
"Complete delivery" (flow 8). Every number here is from the **offline Lune mock of the real
server** (tools/preview), played by a scripted bot. It is **not Studio, not a device, not
multiplayer on Roblox**. Milliseconds are host Lua time on a shared 4-core Linux box that other
jobs were also using (load average noted per run): compare them only with each other.

## Tools

| Tool | What it does |
|---|---|
| `tools/preview/scenes/pacing-sim.luau` | A player bot per hero plays the Cliffwood beacon run on the real height grid: walks at its WalkSpeed (far goals follow a flow field), opens the nearest ready team chest when the team gold covers the price, else walks to its own XP shards within 30 studs, else to the nearest enemy (stops ~6 studs short and circles it), picks the first card of every choice at once, lights the beacon at 12:30, stays in its ring, fights the Basin Breaker. Invulnerable (damage it WOULD take is logged). Parts `solo` (per class, `minutes` or `full`), `party` (4 players), `boss` (13:00 builds replayed against a boss spawned at 13:30). Tuning overrides for experiments: `--set opening=Seconds:Start:First:PartyRamp`, `startgold=N`, `bosshpb=N`. Registered in run_regressions (2 classes, 3 minutes). |
| `perf-sim --set scenario=cliffwood` (`scenes/lib/perfcliff.luau`) | 4 heroes with maximum builds (4 weapons rank 5, every existing evolution, Seed Slinger plants, Magic Orb orbits, Vortex, 4 loot passives rank 5) and 200 enemies on the beacon run: server ms per module, replication, instances / connections over time, worst single calls, then run / return leak cycles. Registered (20 s, 4 cycles). |
| `swarm-v2-flow --set cycles=N` | The real queue -> countdown -> RunEntry -> run -> results -> camp flow repeated N times with the client running; instance, connection, thread and heap growth per cycle (F1-F4). |
| `walkthrough-regression`, `walkthrough-bubble` | The first-run walkthrough on the beacon run (see the last section). |

Commands (from the repo root; `SWARM_TOOLS=/tmp/sh-tools`):

```
lune run tools/preview/runtime/main.luau -- --scene pacing-sim --studio --device pc --max-time 40000 --set headless=on \
    --set part=solo --set classes=all --set minutes=6 --set full=none
lune run ... --scene pacing-sim ... --set part=solo,boss --set classes=ruckus,captain_croak --set full=all
lune run ... --scene pacing-sim ... --set part=party,boss
lune run ... --scene perf-sim --studio --device pc --max-time 40000 --set headless=on --set scenario=cliffwood --set seconds=120 --set cycles=10
lune run ... --scene swarm-v2-flow --studio --device pc --max-time 6000 --set cycles=10
```

## 1. Pacing (offline Lune, NOT Studio)

The bot is a fast, perfect collector that never dodges and always picks the first card: it
reaches every target sooner than a new player would, and its builds ignore evolutions on
purpose. Its account also gains the classes earned by goals during earlier runs of the same
scene (later classes in one scene may be offered other classes' signatures). Seed: the
preview's default; repeats of the same configuration differ by about +-2 s on the first-minute
numbers.

### First minute, before and after the tuning (6 classes, solo)

Before = the branch as merged (no opening ramp, no start gold). After = Opening 60 s from x0.2,
1 first enemy, StartGold 25 (sweep E, the chosen values).

| class | first kill before / after | combat -> kill before / after | first level choice before / after | first chest opened before / after |
|---|---|---|---|---|
| ruckus | 3.9 / 2.5 s | 1.4 / 1.5 s | 14.8 / 22.5 s | 32.2 / 24.2 s |
| toastmaster | 4.2 / 3.4 s | 1.9 / 1.9 s | 15.6 / 24.0 s | 39.3 / 27.3 s |
| captain_croak | 3.6 / 4.0 s | 1.1 / 2.3 s | 14.2 / 21.6 s | 30.1 / 25.2 s |
| granny_boom | 6.5 / 5.3 s | 3.4 / 3.2 s | 17.7 / 25.1 s | 43.9 / 29.5 s |
| coach_crunch | 4.7 / 4.2 s | 1.6 / 2.4 s | 17.7 / 23.9 s | 39.1 / 26.1 s |
| knuckles_mcgee | 5.9 / 3.7 s | 2.8 / 2.5 s | 17.2 / 23.0 s | 38.6 / 25.1 s |
| **target** | | **<= 5 s** | **20-35 s** | **~30 s** |

Configurations tried (same 6 classes, 1 minute each; first level choice / first chest opened):

| opening (s : start : first) | start gold | first level choice | first chest | verdict |
|---|---|---|---|---|
| none | 0 | 14-18 s | 30-44 s | both miss |
| 45 : 0.4 : 2 | 0 | 14-18 s | 36-42 s | ramp too weak, chest later |
| 45 : 0.4 : 2 | 20 | 14-17 s | 20-24 s | level still early |
| 60 : 0.35 : 2 | 25 | 15-17 s | 16-20 s | level still early |
| 60 : 0.25 : 2 | 20 | 16-28 s | 25-35 s | mixed |
| **60 : 0.2 : 1** | **25** | **22-25 s** | **24-30 s** | **chosen** |
| 90 : 0.25 : 1 | 25 | 21-27 s | 24-28 s | also fine; a longer light opening |

### All twelve classes after the tuning (solo, 6 minutes)

| class | first kill | combat -> kill | first level choice | first chest opened | level @3 / @6 | ranks @6 | weapons @6 | build at 6:00 |
|---|---|---|---|---|---|---|---|---|
| ruckus | 2.5 s | 1.5 s | 22.5 s | 24.2 s | 7 / 10 | 19 | 3 | ScrapToss5 Vortex1 Whip2, Bell5 Sneakers5 Padding1 |
| toastmaster | 4.3 s | 2.9 s | 23.4 s | 26.8 s | 7 / 10 | 18 | 4 | ToastVolley1 Dodgeball3 Seed1 Confetti1, Bell5 Splinter5 Sneakers2 |
| captain_croak | 4.2 s | 2.3 s | 23.6 s | 27.0 s | 7 / 10 | 23 | 3 | BubbleBomb*5 (evolved) Seed1 Scrap1, Bell5 Stitch5 Ratchet5 Lucky1 |
| granny_boom | 5.0 s | 3.4 s | 32.5 s | 30.7 s | 7 / 10 | 21 | 3 | YarnBomb*5 (evolved) Confetti4 Bubble1, Ratchet5 Splinter4 Dynamo2 |
| coach_crunch | 3.3 s | 2.6 s | 24.4 s | 27.3 s | 7 / 10 | 22 | 1 | Dodgeball5, Bell5 Splinter5 Padding4 Ratchet3 |
| doug_janitor | 6.3 s | 4.9 s | 27.8 s | 29.4 s | 7 / 10 | 20 | 2 | MopSweep2 Bubble4, Lucky5 Dynamo5 Splinter3 Stitch1 |
| peter_parkour | 1.9 s | 0.9 s | 26.8 s | 29.6 s | 7 / 10 | 19 | 4 | Sneakers2 Orb4 Confetti1 Toast1, Dynamo5 Ratchet4 Stitch1 Padding1 |
| barry_plotter | 4.7 s | 3.8 s | 27.4 s | 28.4 s | 7 / 10 | 22 | 4 | Seed3 Claws2 Mop1 Confetti1, Ratchet5 Bell5 Splinter5 |
| rambozo | 5.3 s | 3.4 s | 22.1 s | 23.2 s | 6 / 10 | 21 | 2 | Confetti5 Toast2, Bell2 Stitch4 Splinter4 Lucky4 |
| swolverine | 3.3 s | 2.6 s | 23.9 s | 27.0 s | 7 / 10 | 25 | 2 | Claws2 Bubble4, Dynamo5 Sneakers5 Stitch4 Bell5 |
| crash_cassidy | 2.3 s | 1.5 s | 22.5 s | 23.5 s | 6 / 10 | 20 | 3 | Puck5 Dodgeball3 Bubble3, Sneakers5 Dynamo4 |
| knuckles_mcgee | 3.9 s | 2.4 s | 23.1 s | 26.0 s | 7 / 10 | 21 | 3 | Glove5 Scrap3 Dodgeball1, Bell5 Padding5 Ratchet1 Splinter1 |

All 12: first kill within 5 s of active combat (0.9-4.9 s), first level choice inside 20-35 s
(22.1-32.5 s). First chest: 11 of 12 by 30 s, Granny Boom at 30.7 s. Level 10 at 6:00 for every
class (the XP supply, not the weapon, sets the pace early: ~340 kills by 6:00 for most). By minute
six every hero holds 18-25 ranks over 1-4 weapons and 2-4 passives; 7 of 12 have a rank-5 weapon
(its rank-5 milestone), two have an evolution. Heroes whose bot never picked their signature card
(toastmaster: Toast Toss rank 1 at 6:00) show the limit of a first-card bot, not of the offers.

### Whole runs (solo, after the tuning)

Ruckus, minute by minute: level 3 / 5 / 7 / 8 / 9 / 10 / 11 / 12 / 13 / 14 / 15 / 16 / 16 at
minutes 1-13; kills per minute 21 42 62 61 76 83 84 97 109 109 115 147 123; XP collected per
minute 84 168 248 244 348 380 432 540 512 532 532 780 584; team gold per minute 63 126 186 183 261
295 344 440 399 419 423 645 535. Chests: 15 by 12:30 (40, 54, 73, 98, 133, 179, 242, 327, then 400
each from 7:14), about one per 40-60 s. Every passive slot is at rank 5 by 11:00; later chest
choices fall back to the heal (brief: exhausted pools offer a 10% heal).

| run | level @6 / @13 | ranks @13 | chests by 12:30 | beacon reached | boss spawned |
|---|---|---|---|---|---|
| ruckus (before tuning) | 10 / 17 | 36 | 15 | 12:30 (16 studs away) | 14:00 |
| ruckus | 10 / 16 | 33 | 15 | 12:32 (73 studs) | 14:02 |
| captain_croak | 10 / 16 | 33 | 15 | 12:54 (503 studs) | 14:24 |
| knuckles_mcgee | 10 / 17 | 36 | 15 | 12:31 (34 studs) | 14:01 |
| rambozo | 9 / 14 | 33 | 11 | 13:00 (644 studs) | 14:30 |
| granny_boom | 10 / 16 | 33 | 14 | 13:00 (686 studs) | 14:30 |
| toastmaster | 10 / 16 | 35 | 15 | never: the bot circled a collider 473 studs out (scene now moves a lost bot after 40 s) | not reached |

Getting from wherever the fight took you to the Stone Circle took the bot 1-30 s (16-686 studs at
22 studs/s); the rally (30 s) and charge (60 s) then put the boss at 14:00-14:30.

### Party of four (ruckus, toastmaster, captain_croak, granny_boom; after the start gold, before the party ramp)

Team: first kill 1.8 s, first chest bought 13.5 s, every hero's first level choice 12.9-13.2 s
(personal XP: every hero gets every kill within 120 studs, and the spawn rate is x2.35). 28 chests
by 12:30 (one every ~25 s once the price caps at 400): every hero gets 28 passive choices, so all
passive slots are full by about 7:00. Boss at 14:05 (N 4, HP 13 501 at HPB 200).

With the party ramp (Opening.PartyRamp: the party's extra spawn share ramps in with the opening,
1 minute): team first kill 1.8 s, first chest 17.7 s, first level choices 18.6-18.8 s.

## 2. Basin Breaker (offline Lune, NOT Studio)

The bot closes to ~8 studs and circles the boss at 6 studs; it never dodges a telegraph
(invulnerable), so its uptime is higher than a player's; its builds skip most evolutions, so its
damage is lower than a focused player's. Fight = boss spawn to its death. "Replay" = a fresh run with
the 13:00 build of the same run, clock at 13:30, the boss spawned near the beacon.

| HPB | run | N | the bot's build at the boss | boss HP | fight |
|---|---|---|---|---|---|
| 200 | ruckus, before the opening tuning | 1 | Scrap Shot 5, Sword 5, Vortex 5, Orb 1 + 4 passives at 5 | 3 960 | 46.9 s |
| 200 | ruckus | 1 | Scrap Shot evolved, Vortex 4, Sword 5 + 4 passives at 5 | 3 965 | 71.7 s |
| 200 | ruckus, 13:00 replay | 1 | the same at 13:00 | 3 892 | 69.4 s |
| 200 | captain_croak | 1 | Bubble Bomb 5, Confetti 3, Claws 4, Scrap 2 + 4 at 5 | 4 015 | 55.2 s |
| 200 | captain_croak, replay | 1 | Bubble Bomb 4 ... | 3 892 | 63.4 s |
| 200 | knuckles_mcgee | 1 | Glove 5, Scrap 5, Vortex 5, Orb 1 + 4 at 5 | 3 962 | 42.5 s |
| 200 | knuckles_mcgee, replay | 1 | the same | 3 892 | 42.6 s |
| 200 | rambozo | 1 | Confetti 5, Seed 5, Orb 5, Sword 2 + 4 | 4 030 | 34.1 s |
| 200 | rambozo, replay | 1 | Confetti 5, Seed 5, Orb 5 + 4 | 3 892 | 35.7 s |
| 200 | party: ruckus, toastmaster, captain_croak, granny_boom | 4 | ranks 32-37 each, Scrap Shot evolved | 13 501 | 51.7 s |
| 200 | the same party, replay | 4 | 13:00 builds | 13 234 | 46.3 s |
| **240** | rambozo | 1 | Confetti 5, Scrap 5, Orb 2, Sword 1 + 4 | 4 789 | 46.1 s |
| **240** | rambozo, replay | 1 | the same at 13:00 | 4 671 | 47.7 s |
| **240** | ruckus | 1 | Scrap Shot evolved, Seed 5, Orb 5, Puck 2 + 4 at 5 | 4 827 | 39.8 s |
| **240** | ruckus, replay | 1 | the same at 13:00 | 4 671 | 37.1 s |
| **240** | granny_boom | 1 | Yarn Bomb 5, Seed 3, Confetti 4, Scrap 2 + 4 at 5 | 4 835 | 82.2 s |
| **240** | granny_boom, replay | 1 | the same at 13:00 | 4 671 | 82.0 s |
| **240** | toastmaster, replay (its own run's bot got lost on the way to the beacon) | 1 | Toast Toss 5, Scrap 5, Vortex 5 + 4 at 5 | 4 671 | 61.2 s |
| **240** | party: rambozo, knuckles_mcgee, coach_crunch, swolverine | 4 | ranks 31-37 each | 16 315 | 55.2 s |
| **240** | the same party, replay | 4 | 13:00 builds | 15 881 | 64.9 s |

At HPB 200 the eleven fights took 34-72 s, median 49 s (N = 1 34-72 s, N = 4 46-52 s): four below
the brief's 45 s, none above 90. HPB is the one number the brief leaves for this ("tuned initially
to 200B ..."; "tune HP against real late-run DPS for approximately 45-90 seconds"), so it went to
**240** (x1.2): the same builds project to 41-86 s (median ~59 s), and the nine fights measured at
240 took 37-82 s (N = 1 37-82 s, median 48 s; N = 4 55-65 s): two strong ruckus builds (evolved Scrap
Shot + Seed Slinger 5 + Orb 5) under 45 s, none over 90. The bot's builds
vary a lot from run to run (first-card picks), so one class spans 37-72 s across runs; real players
lose uptime dodging the three telegraphs and get downed (longer fights), and aim for evolutions
(shorter). The formula's shape (x[1 + 0.80 (N-1)] x [1 + 0.07 t]) is unchanged. A Studio playtest of
a few real boss fights per party size is the next check (RunConfig.Director.Boss.HPB).

## 3. Performance (offline Lune mock of the real server: NOT device FPS)

Scene: `perf-sim --set scenario=cliffwood`: 4 heroes (ruckus, toastmaster, captain_croak,
barry_plotter), each 4 weapons at rank 5 with every evolution that exists (the four pack
evolutions Scrap Shot, Toast Toss, Bubble Bomb and Yarn Bomb, plus the old evolution flag on Sword,
Magic Orb and Vortex: more than a real build reaches), Seed Slinger plants and 4 loot passives at rank 5 (Pocket Dynamo, Ratchet Timer, Lucky Button, Splinter
Badge); director minute 10, 200 ordinary enemies kept alive (director plus top-ups), heroes
walking 30-stud circles, 30 server frames per second, no client. Kills ~25/s. These are Lune
mock milliseconds on a shared host, NOT device FPS and NOT a Roblox server.

### Hot spots fixed (same scene, 40 s, identical workload: same kills and shard counts; host load ~11-15)

| module | before | after | fix |
|---|---|---|---|
| XPSystem.Step | 3.76 ms/frame | 0.93 ms/frame | a per-frame view of each hero (root, ground, pickup radius, eligibility) for the shard checks instead of reading the owner's root, player, attributes and stat sheet again for each of up to 800 shards |
| Dash landing check (Heartbeat) | 0.55 ms/frame | 0.21 ms/frame | the raycast filter list is set once per character, not rebuilt 30 times a second per hero |
| server total | 18.5 ms/frame | 14.0 ms/frame | |

Also fixed: a straight shot is now tested where it appears (an enemy pressed against the hero was
skipped by its first move; pacing-sim saw 6 s without a hit on a beetle at 1.9 studs). That is a
hit-rule fix, not a cost fix.

### The full scene after the fixes (120 s measured, then spikes and 10 cycles; host load 11-12, so every ms is about 2x the 40 s run above)

Server ms per frame (exclusive): total 30.2. EnemyAI per-enemy loop 10.5, HeightGrid flow fields
5.3 (by design: one field rebuild spread over frames, FieldBudget 6000 cells per frame), EnemyAI
think 4.7 (66 thinks per frame), XPSystem 2.7 (the shard pool stays full at ~800: four owners,
the bots leave shards behind), WeaponSystem 2.3, delayed callbacks 1.2, EnemyAI grids 0.9, body
sync 0.6 (5 133 BulkMoveTo parts per second), Dash 0.5, everything else under 0.25 each.

Replication per second (to every client): FxBatch 29.9 calls / 12.6 KB, ProjectileBatch 30.0 /
6.8 KB (a buffer, 11 bytes per projectile; up to 27 hero projectiles live), WeaponFx 14.7 / 2.6 KB;
remotes ~22.5 KB/s in total. XP shard parts: Active 96.5, Fly 57.6, Base 50.7, Owner 39.6, Fade
35.1 attribute changes per second (446 attribute changes per second in all); CFrame writes 263/s.
Instances: 13 585-13 600 in the tree during the fight (flat), ~0 created per second (pools).
Connections 116, waiting threads 5-6, flat over the 120 s.

Worst single calls (host ms, inclusive):

| call | max | average | note |
|---|---|---|---|
| run start (RunManager.StartTeamRun) | 7 633 | 6 238 | includes the map build and the height grid |
| HeightGrid.Build | 4 595 | 3 867 | 76 k down rays; in the mock each ray is a Lua box test (lib/mapray), so this is mostly the mock. On Roblox it is one frame of native raycasts at the run start: NOT measured here |
| map build (MapBuilder.BuildArena) | 1 014 | 693 | |
| a queued level / chest choice | 8.6 | 1.2 | 47 calls |
| chest reward frame (LootSystem.Step with the purchase and 4 choices) | 0.95 | | |
| boss spawn (EnemySpawner.SpawnBoss) | 0.75 | | |
| chest purchase (GoldSystem.BuyChest) | 0.02 | | |

Leak check, 10 Squad run / return cycles (start, 15 s of the dense build, everyone back to the
lobby): lobby probes identical after every cycle: tree 8 350, connections 120, waiting threads 4-5,
tweens 0; growth cycle 1 -> 10: +0 instances, +0 connections, -1 waiting thread. The heap swings
78-151 MB with the collector, no trend.

Leak check through the real lobby flow (`swarm-v2-flow --set cycles=10`: join a gate, READY,
countdown, RunEntry starts the run on Cliffwood, 8 s of play, results, back at the bonfire; client
running): the DataModel tree is flat from cycle 2 (25 785 instances), waiting threads flat, but 3
connections and 49 not-destroyed (unparented) instances were added per cycle. Attributed by the
mock's new per-function count: `RunManager:530` (the run character's AncestryChanged, +1) and
`Icons:2297` (a picture's IsLoaded listener, +2). The preview mock's
LoadCharacter only unparented the old character; Roblox's LoadCharacter destroys it (which
disconnects its connections), so the mock now destroys it too. With that mock fix
(`swarm-v2-flow --set cycles=6`): not-destroyed instances flat (25 374 every cycle), RunManager:530 gone; only `Icons:2297` still adds 2 IsLoaded listeners per cycle. That
listener is connected only for a picture that has not loaded after 20 s, and offline pictures never
load (audit PERF-03), so it is an offline artefact; on Roblox it would only pile up for a picture
that fails to load and is redrawn every run (open item for the UI owners).

Not measured here: device FPS (30 mobile / 60 desktop targets), a Roblox server's frame time, real
network bytes (the mock estimates payload sizes), memory on a phone, the client's cost with four
players' effects (the scene runs without the client; `--set client=on` adds it). Those need a
Studio or published test with real devices.

## 4. First-run walkthrough on the beacon run

`src/server/Modules/Walkthrough.lua`, `src/client/WalkthroughClient.lua`, `src/client/Tutorial.lua`,
`Config.Walkthrough` (OpeningHold 10, DirectorEnemyType "Skeleton" = the roster beetle,
DirectorEnemyCount 5, Timeouts.Dash 12). Once per account (save WalkthroughDone), Solo only,
skippable (Settings > Show tips off / SKIP TIPS ends it at once), Settings > Replay tips runs it
again (its chest then costs the normal team price).

| step (beacon run) | the line (computer / touch / gamepad) | done when | timeout |
|---|---|---|---|
| Move | "WASD to walk, right-drag to look." / "Drag on the left to walk, swipe on the right to look." / "Left stick to walk, right stick to look." + "Walk into the gold ring!" | in the ring | 45 s |
| Dash | "Space jumps, Shift dashes." / "Tap JUMP to hop, DASH to zoom ahead." / "A jumps, B dashes." + "Try a dash!" | a server-validated dash | 12 s |
| Fight | "Your weapon attacks by itself. Beat the bugs! n/5" (5 weak, slow roster beetles, 20 studs) | all 5 beaten | 45 s |
| Gems | "Grab your blue XP shards!" (5 x 4 XP = the first level) | the first level choice opens | 30 s |
| Upgrade | "Pick an upgrade!" | a card is picked | 45 s |
| Chest | "Kills earn team gold for chests. This one's free: Hold E!" (a replay: "... Open a chest when you have enough") | the gift chest is opened (once) | 45 s |
| Beacon | "Survive and grow strong! At 12:30 a beacon appears: light it and beat the boss." | GoSeconds (6 s) | - |

The director's spawns are held only until Fight starts or OpeningHold (10 s of run time),
whichever is first; the old stage loop (other arenas) keeps Move, Fight, Gems, Upgrade, Chest,
Go. Fixed on the way: a beacon run's LootSystem.BuildStage skips the OnBuilt hooks, so the
walkthrough never knew the arena and its gift chest failed to appear; it now uses
MapBuilder.GetArena(), and its ring, bugs and chest sit on walkable height-grid ground. Tutorial
tips on a beacon run: "Light the beacon: follow the arrow" (done once lit), "Beat the Basin
Breaker to win!", and the team rules line names personal XP shards and shared team gold.


## 5. Every tuning change (RunConfig only; all proposals the brief allows)

| setting | before | after | why (offline Lune measurement) |
|---|---|---|---|
| `Director.Spawn.Opening` (new) | none | `{ Seconds = 60, Start = 0.2, FirstEnemies = 1, PartyRamp = true }` | first level choice came at 14-18 s solo (target 20-35 s), 13 s in a party of 4; now 22-33 s solo, ~19 s for 4. The brief's rate (0.60 + 0.14 t) x party is exact again from 1:00; the brief allows adjusting it "by population and safe opportunities". First kill stays 1-5 s (one enemy is owed at once) |
| `Economy.Gold.StartGold` (new) | 0 | 25 | the first chest (40) needed 14 kills: opened at 30-44 s; with 25 it is paid by the 5th kill and opened at 23-31 s (target: useful loot within ~30 s). Chest prices, kill gold and the cap are the brief's, unchanged |
| `Director.Boss.HPB` | 200 | 240 | fights took 34-72 s, median 49 s (N 1 and 4); x1.2 centres the same builds in 45-90 s (see section 2) |
| spawn distance, roster, XP curve and values, kill gold, chest curve, boss formula shape | | unchanged | brief-exact |

## 6. Open items

- Boss: the measured spread per class (37-72 s) is wider than the band; a Studio playtest of real
  fights (solo and 4 players) should confirm HPB 240 (one number, RunConfig.Director.Boss.HPB).
- Passives saturate: every passive slot reaches rank 5 by ~11:00 solo and ~7:00 in a party of 4
  (28 chests by 12:30), after which chest choices are the 10% heal. The chest curve and the 4 + 4
  slots are the brief's; the owner may want a later cap or another reward once the pool is empty.
- The damage a contact-hugging bot would take climbs from ~55-250 per minute (minute 1) to
  800-1 700 per minute (minute 14) against 108-168 max HP; it never dodges, so this is an upper
  bound of the pressure, not a survival measurement. Real survival needs Studio play.
- HeightGrid.Build casts ~76 k rays in one frame at the run start; the Lune numbers are the mock's
  Lua rays, the Roblox cost is not measured (one hitch at the start, under the entry overlay).
- `Icons.lua:2297` (picture fallback) connects an IsLoaded listener for a picture still not loaded
  after 20 s and never disconnects it while the picture lives; offline it adds 2 per lobby/run
  cycle. Harmless when pictures load (Roblox); the UI owners may want it disconnected on load/give-up.
- The run character (class rig) is replaced by the lobby avatar through LoadCharacter, which
  destroys it on Roblox; nothing in RunManager destroys it itself (its AncestryChanged handler,
  RunManager:530, lives as long as the model). Worth an explicit Destroy on return if the avatar
  path ever stops using LoadCharacter.
- Not measured anywhere here: device FPS, a Roblox server frame, real network bytes, phone memory,
  the client with four players' effects, real teleports (queue -> reserved server -> return).

## 7. Tests run (offline Lune, NOT Studio; host shared with other jobs)

| check | result |
|---|---|
| `bash tools/check.sh` (type check + Rojo build) | PASS |
| pacing-sim (registered: ruckus + granny_boom, 3 min) | PASS, all targets PASS |
| pacing-sim 12 classes x 6 min; full runs; party; boss replays | see sections 1-2 (12 of 12 first kill <= 5 s of combat, 12 of 12 first choice 20-35 s, 11 of 12 first chest <= 30 s) |
| director-sim (A-E, incl. new A24 opening, A7b HPB) | PASS |
| perf-sim cliffwood (registered: 20 s, 4 cycles) and the 120 s / 10-cycle run | PASS |
| perf-regression (HUD layouts) | PASS |
| walkthrough-regression (beacon run, timeouts, replay, co-op, old loop, client lines) | PASS |
| layout walkthrough-bubble (iphone, phone-portrait; Move and Beacon) | PASS (check_layout 0 problems) |
| layout smart-tutorial-regression iphone | PASS (alone; timed out once in a parallel batch) |
| cliffwood-run-sim | PASS (after the dash-check fix) |
| class-kits-sim, survival-sim, economy2-sim, builds-sim | PASS |
| swarm-v2-flow (A-E plus F leak cycles, `--set cycles=6`) | PASS 53/53; the plain registered run timed out once (1 500 s) in a parallel batch under the shared load |
