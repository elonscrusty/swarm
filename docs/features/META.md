# META: Sigils, weekly boards, season, titles, collection, login streak

Wave 2 of the 30-features batch (features 1, 19, 21, 22, 23, 24 and 25). Each feature has its own
switch in `Config.Features`. With a switch `false`, that feature's rows, screens, remote actions,
boards and grants are gone and the game plays as before. All of them use the additive save fields
from FOUNDATION (no schema bump).

| # | Feature | Switch | Where |
|---|---|---|---|
| 1 | Sigils | `Sigils` | `SigilData`, `MetaService`, `StatSheet`, `MenuSigils` (PLAY run setup) |
| 19 | Weekly team board | `TeamBoard` | `LeaderboardService.SubmitTeam`, `MenuWeekly` (DUO / TRIO tabs) |
| 21 | Weekly challenge | `WeeklyChallenge` | `MetaData.Weekly`, `RunModifiers`, `MenuWeekly` (PLAY + MORE) |
| 22 | Free season track | `SeasonTrack` | `Config.Season`, `MetaData`, `MenuSeason` (MORE) |
| 23 | Titles | `Titles` | `MetaData.Titles`, `MenuTitles` (MORE), `TitlePlates` (over each hero) |
| 24 | Collection book | `CollectionBook` | `CollectionData`, `DiscoveryService.RecordCollection`, `MenuCollection` (MORE) |
| 25 | Daily login streak | `LoginStreak` | `MetaData.Streak*`, `MenuStreak` ("DAILY REWARD" in MORE) |

The server side lives in one module, `src/server/Modules/MetaService.lua`, and uses one remote:
`Meta` with the actions `("EquipSigil", slot, id | "")`, `("ClaimStreak")`, `("ClaimSeason", tier | "All")`
and `("Sync")`. Equips and claims are only accepted in the lobby. Each screen is its own client
module, and they share `src/client/MetaUI.lua`.

## Grants: server-side, exactly once

- **Run rewards** (Sigils found, the weekly best and its board, the team board, season XP and the
  hero played in the collection) are paid only in `MetaService.CommitRun`. RunManager calls it
  once per run player, inside `saveRunStats` after the DEV-taint return, so a run that used a DEV
  tool, or a `DevBoosted` profile, gets nothing and reaches no board. `rp.Committed` keeps it to
  once, and the found-Sigil list is cleared the moment it is read.
- **Claims** mark the save first and pay second. The streak sets `LoginStreak.LastDay = today`
  before it pays, and the season sets `Season.Claimed[tier]` before it pays. A repeat claim finds
  the mark and pays nothing. The save is force-saved right after a claim.
- **Rewards are gold and cosmetics only**: titles and nameplate frames. Nothing is sold, and no
  product or price was created.

## 1. Sigils

These follow `docs/SIGILS_PLAN.md`. The data is in `src/shared/SigilData.lua`: 12 Sigils, each
with a gain and a cost of the same size.

- **Drops.** A boss kill gives each run player a `BossChance` (25%) roll; it listens to the
  `BossKilled` event. An elite killed by a player gives that player an `EliteChance` (2%) roll,
  at most `ElitePerRun` (1) per run. Guards and wave elites never roll. Daily and Weekly runs
  never roll, and neither do DEV-tainted runs. A found Sigil shows a "Sigil found" toast.
- **Keeping it.** A win or the portal keeps the Sigil. A loss keeps it `KeepOnLoss` (35%) of
  the time. A copy you already own pays `DupeGold`: 150 for Common, 400 for Rare.
- **Slots.** One slot to start. Slot 2 opens once any hero reaches Hero Mastery
  `SlotUnlockMastery` (3). The server checks every equip: the Sigil must be owned, the slot
  open, the Sigil not already worn, and the player in the lobby.
- **In the run.** `rp.Sigils` is added to `StatSheet` in its own step, after the permanent
  upgrades. Specials:
  - Clove Bulb adds Garlic Aura at the start, and the first card set shows one card fewer
    (LevelUpSystem).
  - Haggler's Coin gives back 10% of the gold paid at chests and shrines. **Changed from the
    plan:** the plan said "chests cost 10% less". A refund keeps the shown price equal to the
    charged price.
  - Ember Heart sets Regen to 0.
  - Lone Wolf checks every 0.5 s for a living ally within 30 studs and recomputes the sheet
    when that changes.
- **Daily and Weekly runs ignore Sigils.**
- **Tune:** the numbers are in `SigilData`. The player attribute `Sigils` lists the worn ids
  during a run.

## 21. Weekly challenge and 19. weekly team board

- The week runs from Monday 00:00 UTC (`MetaData.WeekOf`). `MetaData.Weekly(week)` uses a fixed
  seed to pick one hero from `WeeklyHeroes` (lent for the run, so the player does not need to own
  it), `WeeklyCurseCount` (2) curses and the first world. Every server gets the same result.
- It starts with `StartRun("Weekly")`. `Config.Modes.Weekly` is solo; it is not in `Order`, and the
  server only accepts it while the switch is on. RunModifiers sets the week's curses on Standard
  difficulty, with no Endless and no Sigils. RunManager plays the lent hero. The player's selected
  hero does not change.
- **Scoring.** The score is `LeaderboardService.RunScore`, the same formula as High Score. Every
  try counts. `data.Weekly` keeps the week's best and the best ever.
- **Boards.** All of them use new stores and never touch an existing board:
  - `SwarmLB_Weekly_<week>`
  - `SwarmLB_TeamDuo_<week>` and `SwarmLB_TeamTrio_<week>`: one row per team, keyed by the
    sorted UserIds (`12_34`); the value is the best member's run score. Only Duo and Trio runs
    whose whole starting team matches the mode's size count.
  - Studio uses the `_Studio_` prefix.
  - The same queue, throttle, budget, validation and run-once rules apply as for the other
    boards. DEV-tainted and DevBoosted runs never submit.
- **Screen.** WEEKLY shows the week's setup, your bests, the reset time, the WEEKLY / DUO / TRIO
  tabs and PLAY WEEKLY.

## 22. Season track

- Seasons are set in `Config.Season.List`: Id, Name, Start and End as UTC dates, both days
  included. Season 1 runs from 2026-10-05 to 2027-01-03. `XPPerTier` is 400 and `Tiers` is 30.
- Season XP is the account XP each clean run gives.
- Rewards:
  - Gold on most tiers: 100 + 10 x tier.
  - A nameplate frame at tiers 5, 15 and 25.
  - A title at tiers 10, 20 and 30.
  - A cosmetic you already own pays 250 gold instead.
- **New season.** A new Id starts a new track. Tiers reached but not claimed on the old track
  are paid once when the new season starts. **Add each season as a new row and never reuse an
  Id.** A new season should also get new reward ids in `MetaData.SeasonCosmetics`.
- It is free only. There is no paid lane.

## 23. Titles

- Every title (achievement, account level and META) is listed in TITLES. Earned ones can be worn
  through `EquipCosmetic("Title", text)`. AchievementService now also accepts a META title the
  save owns (`MetaService.OwnsTitle`), but only while the switch is on.
- The META titles (`MetaData.Titles`):
  - Collector: half the book
  - Archivist: the full book
  - Sigil Seeker: 6 Sigils
  - Sigil Keeper: all 12 Sigils
  - Weekly Warrior: 3 stages cleared in a weekly
  - Brothers in Arms: 3 stages cleared in Duo or Trio
  - Faithful: 7-day streak
  - Devoted: 30-day streak
  - Season tiers 10, 20 and 30
- The first title earned is worn at once, the same as with achievements. A DevBoosted profile
  earns no milestone titles.
- **Plate over each hero.** `TitlePlates` shows the name and, under it, the worn title, from the
  player attribute `Title`, in the lobby and in runs within 70 studs. With the Store on it wears
  the STORE nameplate frame (`StoreFx.DecoratePlate`), and StoreFx skips its own plate for that
  player, so only one plate shows.
- **Nameplate frames.** The four META frames (Ember, Frost, Royal, Dawn) are `Earned` entries in
  `StoreCatalog` with no Earn goal. MetaService puts them in `Cosmetics.Owned`, and they are worn
  through the STORE's `StoreEquip`. Their TITLES rows only show while the Store switch is on.

## 24. Collection book

- `CollectionData` reads what the save already records:
  - Enemies come from `Journal.Enemies`.
  - Bosses come from `Collection.Seen["Boss:<id>"]` (the `BossDefeated` event) or the journal.
  - Weapons, passives and items come from `Discovered`.
  - Heroes come from `Collection.Seen["Hero:<id>"]` (played) or ownership.
- `DiscoveryService.RecordCollection` was extended to write those keys, capped. No second record
  was added.
- What you have not found shows as a dark silhouette with "???". Half the book and the full book
  each earn a title.

## 25. Daily login streak

- There is one claim per UTC day. Claiming on back-to-back days adds 1 to the streak. One missed
  day is forgiven (`StreakGrace` = 1). A longer gap starts the streak again at day 1.
- Gold follows a 7-day cycle: 50 / 75 / 100 / 125 / 150 / 200 / 300.
- Milestones (paid once each):
  - Day 7: the Faithful title
  - Day 14: the Dawn frame
  - Day 30: the Devoted title

## Tests and status

- `meta-regression` (server, headless). It runs these checks:
  - switches off
  - Sigils: equip rules, sheet maths, Clove Bulb, Haggler's refund, the elite cap, kept / lost /
    duplicate, Daily ignores Sigils, a DEV-tainted run gets nothing
  - weekly: hero, curses, best and board
  - Duo team row
  - season: claim, claim all, no double, locked tier, season change
  - streak: same day, next day, grace, reset, day 7 title
  - titles: wear rules, the attribute
  - collection
- `meta` scene: each screen with a sample profile (`--set screen=Sigils|Weekly|Season|Titles|Collection|Streak|Play|More`).
  On 2026-10-05 the checks gave:
  - `meta-regression`: 63 PASS lines and 0 FAIL.
  - Layout: `check_layout.py` found 0 problems for all 8 screens, on both iphone and
    phone-portrait.

BLOCKED (offline only):
- Studio, phones and live servers.
- Real OrderedDataStores; the boards were tested in the "local" mode.
- The run-server teleport path for a Weekly run.
- The look of the plates over heroes in 3D.
