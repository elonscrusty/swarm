-- results: the results screen over the arena (RunResult remote, as RunManager sends it):
-- verdict, hero, numbers, the build, items, rewards, REPLAY / MAIN MENU.
--   --set outcome=defeat   a defeat during the Queen fight (no rewards lines)
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 60, seconds = 900 })
C.settle(1)
C.setState({ Phase = "Results" })
local build = {
	Weapons = { { Id = "Whip", Level = 8, Evolved = true }, { Id = "MagicOrb", Level = 6, Evolved = false }, { Id = "Knives", Level = 4, Evolved = false }, { Id = "Garlic", Level = 2, Evolved = false } },
	Passives = { { Id = "Might", Level = 5 }, { Id = "Armor", Level = 3 }, { Id = "Heart", Level = 2 }, { Id = "Luck", Level = 1 } },
}
if preview.args.outcome == "defeat" then
	C.fire("RunResult", { Won = false, Portal = false, Time = 412, Kills = 655, Gold = 138, Level = 17, Damage = 64210, Arena = "Ruins (Duo)", Mode = "Duo", CharacterId = "Mage", Build = build, BossKills = 0, BossFight = true, Seconds = 25, StagesCleared = 0, Stage = 1, Items = { { Id = "Whetstone", Count = 1 }, { Id = "Bandage", Count = 2 } } })
	C.settle(3)
	return
end
C.fire("RunResult", { Won = true, Mode = "Solo", CharacterId = "Knight", Build = build, BossKills = 3, BossFight = false, Achievements = { { Id = "QueenSlayer", Name = "Queen Slayer", Reward = "Unlocks the Ranger" } }, Time = 900, Kills = 1874, Gold = 412, Level = 31, Damage = 286400, Arena = "Forest", NewBest = true, Unlocked = "Ruins", Seconds = 25, Portal = true, StagesCleared = 3, Stage = 4, Items = { { Id = "Whetstone", Count = 3 }, { Id = "QuickGloves", Count = 2 }, { Id = "StormCharm", Count = 1 }, { Id = "GuardianWard", Count = 1 }, { Id = "KeenLens", Count = 4 }, { Id = "SunMedallion", Count = 1 }, { Id = "IronPlate", Count = 2 }, { Id = "Bandage", Count = 1 } } })
C.settle(3)
