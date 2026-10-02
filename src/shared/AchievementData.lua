--[[
	AchievementData.lua
	Milestones tracked by the server (ServerScriptService.Modules.AchievementService) and
	shown in the lobby (STATS → ACHIEVEMENTS) and as toasts in a run / on the results.

	An achievement listens to one bus event (ServerScriptService.Modules.Events):
	  Event    event name fired by the game systems, with a data table:
	             RunTime        { Seconds }        every second while you are alive in a run
	             Level          { Level }          your run level went up
	             BossKilled     {}                 a stage boss died (everyone in the run)
	             BossDefeated   { Boss, Stage }    a stage boss died (BossData id; everyone
	                                               in the run, fallen teammates too)
	             RunWon         { Stages }         left through the portal with WinMinStages+
	             StageCleared   { Stage, Character, Bargain }  the portal opened (alive players)
	             OptionalEvent  { Kind }           a Guarded Altar opened / a Bargain stage cleared
	             PartnerRevive  {}                 you revived a fallen teammate
	             GoldenChest    {}                 you opened a Golden Chest
	             StageReached   { Stage }          the run reached a new stage (polled once a second)
	             RunKills       { Kills }          your kills this run (polled once a second)
	  Kind     "Max"   progress = best value seen (data[Field])
	           "Count" progress += 1 each time (kept across runs)
	  Field    data field read by Max achievements
	  Goal     progress needed
	  Filter   optional { field = value } the event data must match
	  Reward   { Gold?, Character?, Title?, Color? }: modest gold, a hero (Ranger, Alchemist,
	           Engineer, Necromancer), and cosmetic
	           lobby titles / nameplate colours (never stats, never anything sold for Robux)

	Titles and nameplate colours are equipped in the achievements panel (EquipCosmetic) and
	shown on the lobby nameplate.
]]

local Palette = require(script.Parent.Palette)

local AchievementData = {}

AchievementData.Order = {
	"Survivor5",
	"Survivor10",
	"QueenSlayer",
	"Conqueror",
	"Daredevil",
	"KnightClear",
	"MageClear",
	"RogueClear",
	"PriestClear",
	"Lifesaver",
	"Veteran",
	"GoldenTouch",
	"DeepDelver",
	"FieldEngineer",
	"Reaper",
	"MothBane",
	"WarlordFall",
	"HiveCleanser",
}

AchievementData.Achievements = {
	Survivor5 = {
		Id = "Survivor5",
		Name = "Hold the Line",
		Description = "Survive 5 minutes in one run.",
		Icon = "ach_Survivor5",
		Event = "RunTime",
		Kind = "Max",
		Field = "Seconds",
		Goal = 300,
		Format = "Time",
		Reward = { Gold = 100 },
	},
	Survivor10 = {
		Id = "Survivor10",
		Name = "Unbroken",
		Description = "Survive 10 minutes in one run.",
		Icon = "ach_Survivor10",
		Event = "RunTime",
		Kind = "Max",
		Field = "Seconds",
		Goal = 600,
		Format = "Time",
		Reward = { Gold = 250, Title = "Unbroken" },
	},
	QueenSlayer = {
		Id = "QueenSlayer",
		Name = "Queen Slayer",
		Description = "Defeat the Scorpion Queen.",
		Icon = "ach_QueenSlayer",
		Event = "BossDefeated",
		Kind = "Count",
		Goal = 1,
		Filter = { Boss = "ScorpionQueen" },
		Reward = { Gold = 150, Character = "Ranger" },
	},
	Conqueror = {
		Id = "Conqueror",
		Name = "Conqueror",
		Description = "Clear stage 3 and leave through the portal (a win).",
		Icon = "ach_Conqueror",
		Event = "RunWon",
		Kind = "Count",
		Goal = 1,
		Reward = { Gold = 400, Title = "Conqueror", Color = "Gold" },
	},
	Daredevil = {
		Id = "Daredevil",
		Name = "Daredevil",
		Description = "Open a Guarded Altar, or clear a stage under a Bargain Shrine's pact.",
		Icon = "altar",
		Event = "OptionalEvent",
		Kind = "Count",
		Goal = 1,
		Reward = { Gold = 150, Title = "Daredevil", Color = "Crimson" },
	},
	KnightClear = {
		Id = "KnightClear",
		Name = "Knight's Oath",
		Description = "Clear a stage as the Knight.",
		Icon = "ach_KnightClear",
		Event = "StageCleared",
		Kind = "Count",
		Goal = 1,
		Filter = { Character = "Knight" },
		Reward = { Gold = 100 },
	},
	MageClear = {
		Id = "MageClear",
		Name = "Arcane Mastery",
		Description = "Clear a stage as the Mage.",
		Icon = "ach_MageClear",
		Event = "StageCleared",
		Kind = "Count",
		Goal = 1,
		Filter = { Character = "Mage" },
		Reward = { Gold = 100, Color = "Arcane" },
	},
	RogueClear = {
		Id = "RogueClear",
		Name = "Shadow Run",
		Description = "Clear a stage as the Rogue.",
		Icon = "ach_RogueClear",
		Event = "StageCleared",
		Kind = "Count",
		Goal = 1,
		Filter = { Character = "Rogue" },
		Reward = { Gold = 100 },
	},
	PriestClear = {
		Id = "PriestClear",
		Name = "Holy Light",
		Description = "Clear a stage as the Priest.",
		Icon = "ach_PriestClear",
		Event = "StageCleared",
		Kind = "Count",
		Goal = 1,
		Filter = { Character = "Priest" },
		Reward = { Gold = 100, Color = "Ivory" },
	},
	Lifesaver = {
		Id = "Lifesaver",
		Name = "Lifesaver",
		Description = "Revive fallen teammates 3 times (Duo or Trio).",
		Icon = "revive",
		Event = "PartnerRevive",
		Kind = "Count",
		Goal = 3,
		Reward = { Gold = 200, Title = "Lifesaver", Color = "Moss" },
	},
	Veteran = {
		Id = "Veteran",
		Name = "Veteran",
		Description = "Reach level 30 in one run.",
		Icon = "ach_Veteran",
		Event = "Level",
		Kind = "Max",
		Field = "Level",
		Goal = 30,
		Reward = { Gold = 200, Title = "Veteran" },
	},
	GoldenTouch = {
		Id = "GoldenTouch",
		Name = "Golden Touch",
		Description = "Open a Golden Chest.",
		Icon = "chest",
		Event = "GoldenChest",
		Kind = "Count",
		Goal = 1,
		Reward = { Gold = 100, Title = "Treasure Hunter" },
	},
	-- hero unlocks (the Alchemist, the Engineer, the Necromancer)
	DeepDelver = {
		Id = "DeepDelver",
		Name = "Deep Delver",
		Description = "Reach stage 4 in one run.",
		Icon = "portal",
		Event = "StageReached",
		Kind = "Max",
		Field = "Stage",
		Goal = 4,
		Reward = { Gold = 150, Character = "Alchemist" },
	},
	FieldEngineer = {
		Id = "FieldEngineer",
		Name = "Field Engineer",
		Description = "Complete 3 optional events: open Guarded Altars or clear stages under a Bargain (total).",
		Icon = "ach_FieldEngineer",
		Event = "OptionalEvent",
		Kind = "Count",
		Goal = 3,
		Reward = { Gold = 150, Character = "Engineer" },
	},
	Reaper = {
		Id = "Reaper",
		Name = "Reaper",
		Description = "Defeat 500 enemies in one run.",
		Icon = "ach_Reaper",
		Event = "RunKills",
		Kind = "Max",
		Field = "Kills",
		Goal = 500,
		Reward = { Gold = 150, Character = "Necromancer" },
	},
	-- the rotating stage bosses (modest gold, one title)
	MothBane = {
		Id = "MothBane",
		Name = "Moth Bane",
		Description = "Defeat the Moth Matriarch.",
		Icon = "ach_MothBane",
		Event = "BossDefeated",
		Kind = "Count",
		Goal = 1,
		Filter = { Boss = "MothMatriarch" },
		Reward = { Gold = 120 },
	},
	WarlordFall = {
		Id = "WarlordFall",
		Name = "Banner Breaker",
		Description = "Defeat the Rhino Warlord.",
		Icon = "ach_WarlordFall",
		Event = "BossDefeated",
		Kind = "Count",
		Goal = 1,
		Filter = { Boss = "RhinoWarlord" },
		Reward = { Gold = 120, Title = "Banner Breaker" },
	},
	HiveCleanser = {
		Id = "HiveCleanser",
		Name = "Hive Cleanser",
		Description = "Defeat the Hive Mother.",
		Icon = "ach_HiveCleanser",
		Event = "BossDefeated",
		Kind = "Count",
		Goal = 1,
		Filter = { Boss = "HiveMother" },
		Reward = { Gold = 120 },
	},
}

-- Nameplate colours an achievement can give (cosmetic, lobby nameplate). "" = default.
AchievementData.Colors = {
	Gold = { Name = "Gold", Color = Palette.gold_300 },
	Crimson = { Name = "Crimson", Color = Palette.crimson_300 },
	Arcane = { Name = "Arcane", Color = Color3.fromRGB(176, 156, 214) },
	Ivory = { Name = "Ivory", Color = Palette.ivory_100 },
	Moss = { Name = "Moss", Color = Palette.moss_200 },
}
AchievementData.ColorOrder = { "Gold", "Crimson", "Arcane", "Ivory", "Moss" }

-- Achievement that unlocks a character (nil = none).
function AchievementData.UnlockFor(characterId: string): string?
	for _, id in ipairs(AchievementData.Order) do
		local def = AchievementData.Achievements[id]
		if def.Reward.Character == characterId then
			return id
		end
	end
	return nil
end

-- Achievements that give a title / colour id (for the equip lists).
function AchievementData.Source(kind: string, value: string): string?
	for _, id in ipairs(AchievementData.Order) do
		local r = AchievementData.Achievements[id].Reward
		if (kind == "Title" and r.Title == value) or (kind == "Color" and r.Color == value) then
			return id
		end
	end
	return nil
end

-- Reward in one short line ("150 gold · Unlocks the Ranger · Title: Unbroken").
function AchievementData.RewardText(id: string): string
	local def = AchievementData.Achievements[id]
	if not def then
		return ""
	end
	local r = def.Reward
	local parts = {}
	if r.Character then
		table.insert(parts, "Unlocks the " .. r.Character)
	end
	if r.Title then
		table.insert(parts, "Title: " .. r.Title)
	end
	if r.Color then
		local c = AchievementData.Colors[r.Color]
		table.insert(parts, (c and c.Name or r.Color) .. " name colour")
	end
	if r.Gold then
		table.insert(parts, r.Gold .. " gold")
	end
	return table.concat(parts, " · ")
end

-- Progress as display text ("3:12 / 5:00", "1 / 3").
function AchievementData.ProgressText(id: string, progress: number): string
	local def = AchievementData.Achievements[id]
	if not def then
		return ""
	end
	local p = math.min(progress, def.Goal)
	if def.Format == "Time" then
		local function t(s: number): string
			s = math.floor(s)
			return string.format("%d:%02d", s // 60, s % 60)
		end
		return t(p) .. " / " .. t(def.Goal)
	end
	return string.format("%d / %d", p, def.Goal)
end

return AchievementData
