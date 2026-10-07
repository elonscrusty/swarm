# Daily quests (switch `DailyQuests`)

## What
Three quests every UTC day, the same for every player (a seeded pick from the day number,
`QuestData.Pick`). Slots 1 and 2 come from the Easy pool, slot 3 from the Hard pool; quests
whose feature switch is off (Ultimate, SecretRooms, TrialShrine, Rescue) are left out.

Pool (17): defeat 500 enemies, open 5 chests, collect 2,000 gold in runs, pick up 300 XP gems,
use your ultimate 5 times, play the daily challenge, play a Duo run, break open a secret room,
reach level 15 in one run (Easy); win a run with the Mage, reach stage 3, survive 10 minutes in
one run, defeat a boss, level a weapon to 8, win a Shrine of Trial, rescue the lost villager,
win a run (Hard).

Progress is counted on the server from the run (`src/server/Modules/DailyQuests.lua`): kills,
earned run gold, level, stage, time alive, best weapon level, ultimates, chests opened
(LootSystem), XP gems picked up (XPSystem), secret rooms (SecretRoom), trials won
(TrialShrine), villagers saved (Rescue), stage bosses (Events BossDefeated); wins, Mage wins,
Duo and Daily runs (played 60+ s) at the end. "Sum" quests add up over the day's runs, "Max"
quests take the best single run. The save changes once per run, in RunManager's commit, and
never for a DEV-tainted run or a DevBoosted profile. During a run the player sees short
progress notices ("Quest: Defeat 500 enemies · 250 / 500", "Quest done: ...") through the
UIState notice lane, at most one per 20 s.

Rewards: CLAIM per quest (gold), then a DAILY BONUS when all three are claimed (the next
earned look not owned yet: Questor Plate, then Questor Trail; after that gold). Claims are
lobby only, checked and marked on the server before paying (exactly once), and saved at once.

Where: MORE > DAILY QUESTS (`src/client/MenuQuests.lua`, notice dot while something can be
claimed), and a "QUESTS 1/3" chip on the home screen: landscape at the top of the TOP SCORES
column (the board starts under it), portrait centred just above PLAY (hidden while the queue
shows or there is no room). The chip has the same notice dot and hides under any panel.

Save (additive, no schema bump): `DailyQuests = { Day = n, Progress = { [questId] = n },
Claimed = { [questId] = true, Bonus = true } }`. Another day's table reads as empty and is
replaced on the next commit / claim / load.

## Config
- `Config.Features.DailyQuests = true` (false: no chip, no row, no counting, remote ignored)
- `Config.DailyQuests`: `Slots = { "Easy", "Easy", "Hard" }`, `PlayMinSeconds = 60`,
  `ToastGap = 20`, `Rate = 4`
- PROPOSED, awaiting owner approval: `Rewards = { 300, 300, 600 }` gold per slot,
  `BonusCosmetics = { "Plate_Questor", "Trail_Questor" }` (new earned looks in
  StoreCatalog, never sold), `BonusGoldAfter = 200`

## Owner steps
1. Approve or change the gold amounts and the two bonus looks (Config.DailyQuests).
2. Studio playtest: play a run, check the in-run quest notices, claim in MORE > DAILY QUESTS.

## Regression
`tools/preview/scenes/daily-quests-regression.luau` (registered in tools/run_regressions.py):

    python3 tools/run_regressions.py --only daily-quests-regression

Checks: pool 15+, deterministic pick with slot tiers and distinct quests, varies by day;
switch off changes nothing; progress across two runs capped at the goal; live progress not
saved mid-run; notices spaced 20 s; DEV-tainted run adds nothing; claims refused when not done,
unknown, not today or in a run; paid once with 300/300/600; bonus once with the first look;
day rollover starts empty. Layout: `layout-meta-iphone-screen-Quests` (and phone-portrait, pc);
the home chip is covered by the existing `layout-menu-*` checks.

Expect: PASS offline. BLOCKED until Studio: real-device text size, real run pacing.
