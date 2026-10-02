-- results: the results screen over the arena (RunResult remote, as RunManager sends it):
-- verdict, hero, numbers, the build, items, rewards, REPLAY / MAIN MENU.
--   --set outcome=defeat   a defeat during the Queen fight (no rewards lines)
--   --set daily=on         a scored Daily Challenge run (daily line, its curses)
-- The progress block shows the account XP / level ("+340 XP · Level 7 → 8"), the run's
-- curses and a track reward; the medallion wears the Gold portrait frame.
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 60, seconds = 900 })
C.settle(1)
C.setState({ Phase = "Results" })
C.sendProfile(C.profile({ Frame = "Gold", Account = { XP = 2240 } }))
local daily = preview.args.daily == "on"
local CurseData = C.shared("CurseData")
local curses = daily and { "Horde", "EliteSurge" } or { "Frenzy", "GlassCannon" }
local progress = {
	Curses = curses,
	CurseGold = CurseData.GoldMult(curses),
	Account = { Gained = 342, From = 7, To = 8, Into = 92, Need = 500, Rewards = { "Bronze Frame" } },
	Daily = daily and { Scored = true, Score = CurseData.DailyScore(3, 552, 700), Text = CurseData.ScoreText(CurseData.DailyScore(3, 552, 700)), NewBest = true } or nil,
}
local build = {
	Weapons = { { Id = "Whip", Level = 8, Evolved = true }, { Id = "MagicOrb", Level = 6, Evolved = false }, { Id = "Knives", Level = 4, Evolved = false }, { Id = "Garlic", Level = 2, Evolved = false } },
	Passives = { { Id = "Might", Level = 5 }, { Id = "Armor", Level = 3 }, { Id = "Heart", Level = 2 }, { Id = "Luck", Level = 1 } },
}
if preview.args.outcome == "defeat" then
	C.fire("RunResult", { Curses = progress.Curses, CurseGold = progress.CurseGold, Account = { Gained = 118, From = 7, To = 7, Into = 210, Need = 450, Rewards = {} }, Won = false, Portal = false, Time = 412, Kills = 655, Gold = 138, Level = 17, Damage = 64210, Arena = "Ruins (Duo)", Mode = "Duo", CharacterId = "Mage", Build = build, BossKills = 0, BossFight = true, Seconds = 25, StagesCleared = 0, Stage = 1, Items = { { Id = "Whetstone", Count = 1 }, { Id = "Bandage", Count = 2 } } })
	C.settle(3)
	return
end
C.fire("RunResult", { Curses = progress.Curses, CurseGold = progress.CurseGold, Account = progress.Account, Daily = progress.Daily, Won = true, Mode = daily and "Daily" or "Solo", CharacterId = "Knight", Build = build, BossKills = 3, BossFight = false, Achievements = { { Id = "QueenSlayer", Name = "Queen Slayer", Reward = "Unlocks the Ranger" } }, Time = 900, Kills = 1874, Gold = 412, Level = 31, Damage = 286400, Arena = "Forest", NewBest = true, Unlocked = "Ruins", Seconds = 25, Portal = true, StagesCleared = 3, Stage = 4, Items = { { Id = "Whetstone", Count = 3 }, { Id = "QuickGloves", Count = 2 }, { Id = "StormCharm", Count = 1 }, { Id = "GuardianWard", Count = 1 }, { Id = "KeenLens", Count = 4 }, { Id = "SunMedallion", Count = 1 }, { Id = "IronPlate", Count = 2 }, { Id = "Bandage", Count = 1 } } })
C.settle(3)
