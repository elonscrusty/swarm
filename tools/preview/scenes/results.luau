-- results: the results screen over the arena (RunResult remote, as RunManager sends it):
-- verdict, hero, numbers, the build, items, rewards, REPLAY / MAIN MENU.
--   --set outcome=defeat   a defeat during the Queen fight (no rewards lines); --set details=open
--                          opens RUN DETAILS and checks the "Last hit" line
--   --set daily=on         a scored Daily Challenge run (daily line, its curses)
--   --set outcome=endless  an Endless run left from the pause menu on stage 9 (endless score)
--   --set mastery=on       with a Hero Mastery line in the progress block
--   --set outcome=first    a brand-new player's first run: FIRST RUN BONUS line + Mage goal
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
	Daily = daily and { Scored = true, Score = CurseData.DailyScore(5, 1552, 1500), Text = CurseData.ScoreText(CurseData.DailyScore(5, 1552, 1500)), NewBest = true } or nil,
}
local mastery = preview.args.mastery == "on" and { Hero = "Knight", Gained = 120, From = 3, To = 4 } or nil
-- NEXT GOAL, picked by the real shared NextGoal module from a sample settled save:
--   --set goal=gold (default) | mastery | earn | daily | difficulty | off
local NextGoal = C.shared("NextGoal")
local goalSaves = {
	gold = { Gold = 7700, OwnedCharacters = { Knight = true }, DifficultyClears = { Standard = true }, Daily = { Day = 0, Used = true }, Achievements = { Progress = {}, Unlocked = {} } },
	mastery = { Gold = 200, OwnedCharacters = { Knight = true, Mage = true }, Heroes = { Knight = { XP = 600, Runs = 4 } }, DifficultyClears = { Standard = true, Veteran = true }, Daily = { Day = 0, Used = true }, Achievements = { Progress = { QueenSlayer = 0 }, Unlocked = {} } },
	earn = { Gold = 0, OwnedCharacters = { Knight = true }, Achievements = { Progress = { DeepDelver = 3 }, Unlocked = {} }, DifficultyClears = { Standard = true }, Daily = { Day = 0, Used = true }, Stats = { BestStage = 3 } },
	daily = { Gold = 0, OwnedCharacters = { Knight = true }, Stats = { Runs = 9 }, Daily = { Day = 0, Used = false }, Achievements = { Progress = {}, Unlocked = {} } },
	difficulty = { Gold = 0, OwnedCharacters = { Knight = true }, Stats = { BestStage = 4 }, Daily = { Day = 0, Used = true }, Achievements = { Progress = {}, Unlocked = {} } },
}
local goalKind = preview.args.goal or "gold"
local nextGoal = goalSaves[goalKind] and NextGoal.Pick(goalSaves[goalKind], { Hero = "Knight", RunGold = 1412, Now = goalKind == "daily" and 86400 * 3 or 0 }) or nil
local build = {
	Weapons = { { Id = "Whip", Level = 12, Evolved = true }, { Id = "MagicOrb", Level = 9, Evolved = false }, { Id = "Knives", Level = 7, Evolved = false }, { Id = "Garlic", Level = 4, Evolved = false } },
	Passives = { { Id = "Might", Level = 5 }, { Id = "Armor", Level = 3 }, { Id = "Heart", Level = 3 }, { Id = "Luck", Level = 1 } },
}
if preview.args.outcome == "first" then
	-- a brand-new player's first run (Config.FirstRun): fell on stage 1, the one-time
	-- bonus line and the NEXT GOAL RunManager sends for it (first hero sold for gold)
	local FR = C.shared("Config").FirstRun
	C.fire("RunResult", { FirstRun = { Bonus = FR.BonusGold },
		NextGoal = { Kind = "BuyHero", Icon = "hero:Mage", Text = "Unlock Mage at 10,000 gold", Sub = "or play again", Progress = 0.034, ProgressText = "342 / 10,000 gold" },
		Curses = {}, CurseGold = 1, Account = { Gained = 64, From = 1, To = 1, Into = 64, Need = 300, Rewards = {} }, Mastery = { Hero = "Knight", Gained = 64, From = 1, To = 1 },
		Won = false, Portal = false, Time = 168, Kills = 141, Gold = 49, GoldEarned = 142, GoldLost = 93, GoldRetention = 0.35, Difficulty = "Standard", Level = 8, Damage = 9120,
		Arena = "Forest", Mode = "Solo", CharacterId = "Knight", Build = { Weapons = { { Id = "Whip", Level = 3, Evolved = false }, { Id = "Lightning", Level = 3, Evolved = false } }, Passives = { { Id = "Might", Level = 1 } } },
		BossKills = 0, BossFight = false, Seconds = 25, StagesCleared = 0, Stage = 1, Items = {} })
	C.settle(3)
	return
end
if preview.args.outcome == "endless" then
	C.fire("RunResult", { NextGoal = nextGoal, Curses = {}, CurseGold = 1, Account = { Gained = 610, From = 7, To = 8, Into = 60, Need = 500, Rewards = {} }, Won = false, Portal = false, Abandoned = true, Endless = true, Score = 13840, ScoreBoard = "ScoreEndless", NewBestLevel = true, Time = 2410, Kills = 5210, Gold = 960, Level = 46, Damage = 912400, Arena = "Snow", Mode = "Solo", CharacterId = "Knight", Build = build, BossKills = 8, BossFight = false, Seconds = 25, StagesCleared = 8, Stage = 9, Items = { { Id = "Whetstone", Count = 4 }, { Id = "IronPlate", Count = 2 } } })
	C.settle(3)
	return
end
if preview.args.outcome == "defeat" then
	C.fire("RunResult", { NextGoal = nextGoal, Mastery = mastery, Curses = progress.Curses, CurseGold = progress.CurseGold, Account = { Gained = 118, From = 7, To = 7, Into = 210, Need = 450, Rewards = {} }, Won = false, Portal = false, Time = 412, Kills = 655, Gold = 330, GoldEarned = 600, GoldLost = 270, GoldRetention = 0.55, Difficulty = "Veteran", DeathCause = "Frostbound Colossus freezing breath", DamageHistory = { { Cause = "Slime", Damage = 6, Time = 405 }, { Cause = "Ice Shard", Damage = 18, Time = 409 }, { Cause = "Frostbound Colossus freezing breath", Damage = 64, Time = 411.5 } }, Level = 29, Damage = 64210, Arena = "Ruins (Duo)", Mode = "Duo", CharacterId = "Mage", Build = build, BossKills = 2, BossFight = true, Seconds = 25, StagesCleared = 2, Stage = 3, Items = { { Id = "Whetstone", Count = 1 }, { Id = "Bandage", Count = 2 } } })
	C.settle(3)
	if preview.args.details == "open" then
		-- --set details=open: RUN DETAILS opened (the "Last hit" line, CP-16)
		local gui = game:GetService("Players").LocalPlayer.PlayerGui
		local toggle = gui:FindFirstChild("RunDetails", true)
		if toggle then
			preview.click(toggle)
			C.settle(1)
		end
		local details = gui:FindFirstChild("DetailsText", true)
		local t = details and details.Text or ""
		preview.log((string.find(t, "Last hit:", 1, true) and string.find(t, "Before that: Ice Shard 18, Slime 6", 1, true) and "PASS" or "FAIL") .. " last hit line: " .. string.gsub(t, "\n", " | "))
	end
	return
end
C.fire("RunResult", { NextGoal = nextGoal, Mastery = mastery, Curses = progress.Curses, CurseGold = progress.CurseGold, Account = progress.Account, Daily = progress.Daily, Won = true, Mode = daily and "Daily" or "Solo", CharacterId = "Knight", Build = build, BossKills = 5, BossFight = false, Achievements = { { Id = "QueenSlayer", Name = "Queen Slayer", Reward = "Unlocks the Ranger" } }, Time = 1500, Kills = 3874, Gold = 1412, GoldEarned = 1412, GoldLost = 0, GoldRetention = 1, Difficulty = "Standard", WinMinStages = 5, Level = 31, Damage = 286400, Arena = "Forest", NewBest = true, Unlocked = "Ruins", Seconds = 25, Portal = true, StagesCleared = 5, Stage = 5, Items = { { Id = "Whetstone", Count = 3 }, { Id = "QuickGloves", Count = 2 }, { Id = "StormCharm", Count = 1 }, { Id = "GuardianWard", Count = 1 }, { Id = "KeenLens", Count = 4 }, { Id = "SunMedallion", Count = 1 }, { Id = "IronPlate", Count = 2 }, { Id = "Bandage", Count = 1 } } })
C.settle(3)
