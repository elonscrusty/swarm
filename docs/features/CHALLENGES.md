# CHALLENGES: mini-bosses, Shrine of Trial, cursed chests

Wave 1 of the 30-features batch (features 3, 5 and 7). Each feature has its own switch
in `Config.Features`. With a switch off, that feature places nothing, ticks nothing and
changes nothing. Every reward is granted on the server, through the existing pipelines,
exactly once.

Status: offline only (Lune). Studio, phones and live servers are **BLOCKED**, because none of
it has been tested there.

## 3. Mid-stage mini-boss (`MiniBosses`, `src/server/Modules/MiniBoss.lua`)

- This is an EncounterDirector placed encounter from stage `Config.MiniBoss.MinStage` (2). It is
  registered with `Weight = 3`, so the director picks it before the other placed encounters
  most of the time. `MaxActive` is 2.
- **Champion's Chest:** a free Large chest on the premium plinth, with no price coin. It has a violet
  seal ring, a lock bar, and a violet orb and beam. Its state is `Locked` until the guard dies,
  and the prompt says "Locked · a champion guards it".
- **The guard:** when a player comes within `WakeRadius` (30 studs), an existing enemy type
  (`Types`: Rhino Beetle, Beetle Warrior or Phase Moth) spawns as an elite. On top of the elite stats
  it gets HP x`HPMult` (3), damage x`DamageMult` (1.3) and speed x`SpeedMult` (0.9). Its name comes from
  `Names` ("Ironhorn the Brute", ...).
- **Guard killed by a player:** the chest unlocks (gold light). Opening it is the normal chest hold
  and `openChest`, rolled with `ChestWeights` (0/70/30). It is exactly once, because the state leaves
  `Ready` before the grant. Only the player who opens it gets the item, like every other chest.
- **Guard dies with no killer** (portal sweep, a boss clearing the field, a bulk despawn): it pays nothing
  and the chest stays locked. The guard returns `RetrySeconds` (4) later, but only while the stage is still
  exploring. This follows audit W-04. As a guard it also never drops the free elite chest.
- **Client** (`src/client/ChallengesUI.lua`): a name plate over the guard and a pulsing gold and
  violet double ring under it. Its HP uses the existing small enemy bar (body `HPFrac`).
- **Replication:** SwarmState `MiniBossId` (the pool id, 0 when there is none) and `MiniBossName`, plus the body
  attribute `MiniBoss`. They are cleared on death, at stage end and at run end.

## 5. Shrine of Trial (`TrialShrine`, `src/server/Modules/TrialShrine.lua`)

- This is a placed encounter (`Weight = 1`): a violet Shrine-kit shrine with a faint trial ring of radius
  `Radius` (22) around it.
- **Prompt:** "+ Survive 30 s in the ring: 1 bonus upgrade with a rare card" and
  "- Harder enemies attack · leave the ring or fall: no reward". It is free and works once per stage.
- **Hold to start** (`Hold` 1.2 s). The trial is only for the players inside the ring. For `Seconds` (30),
  `Alive` (10, plus 4 for each extra player) trial enemies are kept around the shrine, with HP x1.5 and damage x1.25.
  An elite joins every 10 s. The timer only runs while the world runs, so a solo level-up panel pauses it.
- **Out:** a player is out after dying, leaving the run, or spending more than `LeaveGrace` (2 s) outside
  the ring (the HUD shows "BACK TO THE RING! 1.4"). When everyone is out, the trial fails.
  If the portal opens or the boss phase starts, the trial fades with no reward.
- **Won:** the state changes first. Then each participant still in gets ONE
  `LevelUpSystem.QueueBonusPick(rp)`. That is an extra queued level whose card set always contains a card
  above Common (NEW, MAX or EVOLUTION) whenever the build still has one. It goes through the normal offer
  flow with OfferId, and its pick (or a skip) uses it up. The trial enemies left over are removed with no drops.
- **HUD:** a FeatureHud badge "TRIAL 24s" for the players taking part.
- **Replication:** SwarmState `TrialLeft` (-1 when no trial is running), `TrialPos` and `TrialRadius`, plus the player attributes
  `TrialIn` and `TrialAway`.

## 7. Cursed chests (`CursedChests`, `src/server/Modules/CursedChest.lua`)

- After `LootSystem.BuildStage`, with chance `Chance` (0.6) per stage from `MinStage` (1), one paid
  Small or Large chest turns cursed. This uses its own `Random`, so the existing loot rolls do not change.
  **The price does not change.**
- **Look:** the chest is tinted violet, with a violet beam, trim and coin, a violet orb with a light, and a violet ring.
  Its title is "Cursed Small Chest" or "Cursed Large Chest".
- **Disclosure before the hold** (prompt): "+ Better loot: 1 item (30% common, 60% uncommon, 10%
  legendary before luck)" and "- Curse: enemies +25% damage, +15% speed for 60 s".
- **Opening** uses the normal paid-chest pipeline. The item is granted first and exactly once, then
  `obj.OnOpened` starts the curse. For `Seconds` (60) of run time, every enemy except bosses and boss objects
  has speed x1.15, contact damage x1.25 and attack damage x1.25 (`DmgScale`). Enemies that spawn during the curse
  are buffed on the next frame. Opening a second cursed chest restarts the timer and does not stack.
  When the curse ends, or the stage or run ends, the multipliers are taken back off the living enemies.
- **HUD:** a FeatureHud badge "CURSED 42s" (SwarmState `CurseLeft`).

## Hooks in shared modules (kept small)

- `LootSystem`: optional object fields `Weights`, `Title`, `OnOpened`, `OnComplete` and
  `OnGuardDown`. The changes are:
  - a `Locked` state ("Defeat its guard first.")
  - `OnBuilt(fn)`, called after BuildStage
  - `AddFeatureChest` and `AddFeatureShrine`
  - `SetObjState`, `SetGlow` and `AddGuard`
  - `openChest` uses `obj.Weights` / `obj.Title` and calls `OnOpened` after the grant
  - `complete` calls `OnComplete`
  - `OnGuardDown` hands a feature guard to its callback

  Existing objects never set these fields, so they behave as before.
- `LevelUpSystem`: `QueueBonusPick(rp)` and `rp.BonusPicks`. `rollChoices` adds one card above
  Common to a bonus set (and tags the cards `Bonus = true`). `choose` and skip use the bonus up, and `Cancel` without
  kept levels clears it.
- `GameServer` ORDER lists `MiniBoss`, `TrialShrine` and `CursedChest`. `ClientMain` starts `ChallengesUI`.
- CursedChest registers with the director using `Allow = false`, so it never takes a placed slot and only
  gets ticks and cleanup.

## Tuning

Everything is in `src/shared/Config.lua` under `Config.MiniBoss`, `Config.TrialShrine` and
`Config.CursedChest`. To make the encounters show up more or less often, change `Weight` and
`Config.Encounters.Director.MaxActive`.

## Balance (econ check)

Prices are untouched. No `Config.Chests` costs, `CostExponent` values or gold numbers changed.
See the before/after table below.

Offline runs before the change (HEAD snapshot) and after it:

| Check | Before | After |
|---|---|---|
| `economy-sim` (escrow, retention, survival gold, receipts) | 3/3 PASS | 3/3 PASS, same numbers |
| `chest-gold-sim` (shown price = charged price, GoldMult) | 9/9 PASS, a stage-1 chest costs 150 | 9/9 PASS, same prices (the cursed Small chest in the regression costs 25 = the normal price) |

What each stage can now give (expected values, base odds before luck):

| Source | Before | After |
|---|---|---|
| Cursed Small chest (same price) | 80% common / 19% uncommon / 1% legendary | 30 / 60 / 10, plus 60 s of stronger enemies |
| Cursed Large chest (same price) | 0 / 80 / 20 | 0 / 55 / 45, plus 60 s of stronger enemies |
| Chance of a cursed chest | - | 60% of stages, one chest out of 13-18 |
| Champion's Chest (stage 2+, free after a fight) | - | about 0.7 extra items per stage (0/70/30), worth about a Large chest (stage 2 price is about 138 gold) |
| Shrine of Trial (when placed) | - | +1 upgrade pick after 30 s of harder enemies |

How often the director picks them (`MaxActive` 2, placed weights MiniBoss 3, Trial 1, three
EXPLORE encounters at weight 1, no spot failures): the champion runs on about 71% of stages from
stage 2, and the trial on about 32% of stages. This is a moderate in-run power gain that has to be
earned with risk. Gold income and prices are unchanged. To trim it, lower `Config.MiniBoss.Weight`,
lower `ChestWeights.Legendary`, or lower `Config.CursedChest.Chance`.

## Verified vs BLOCKED

VERIFIED offline (Lune, real GameServer with all modules), `challenges-regression`, 44/44 checks PASS:
- **Cursed chest.** It is placed. Its price is unchanged. The curse is on the prompt before the hold. It uses the better table and pays one item, only once.
  Enemies get speed x1.15 and damage x1.25, including ones that spawn during the curse. The curse ends after 60 s and the stats are restored.
- **Shrine of Trial.** Holding starts it, and the trial wave is kept around the shrine. Surviving wins. It gives one bonus pick whose
  set holds a card above Common, through OfferId, and the bonus is used up by its pick. A finished shrine cannot restart. Leaving
  the ring fails the trial with no reward.
- **Champion.** There is none on stage 1. On stage 2 the chest is locked and free. Walking close wakes the guard (name plate, HP bar,
  guard link). A death with no killer pays nothing and the guard comes back after 4 s. A player kill unlocks the chest, which pays
  one item, once.
- **Cleanup.** Travel and MAIN MENU remove the models and SwarmState attributes and undo the enemy buffs.
- **Switches off.** With the switches off, nothing is placed and every loot object is a plain one.
- Note: a level-up panel that opens during a hold cancels that hold. This is how every chest already works, and the
  test simply holds again.

Also run after the hooks, unchanged: `economy-sim`, `chest-gold-sim`, plus the hook-adjacent regressions
listed in the lead report. `check.sh --quick` reports no diagnostics in these files.

Client visuals (`ChallengesUI`) pass the type check only. They have not been rendered or checked on a device, so they are BLOCKED.

BLOCKED: Studio playtest, phones (touch hold, badge readability), live multiplayer (co-op trial with
2-3 players, the champion in a duo), and the look of the Shrine kit mesh in violet. Icons: no new icons are
used. The prompts reuse the chest and shrine icons. Owner art is optional later (a Shrine of Trial icon, a
cursed chest icon, a champion's chest icon).
