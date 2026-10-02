--[[
	AccountData.lua
	The account level: a COSMETIC track. Every run gives account XP (time survived, stages
	cleared, kills, bosses, a win, curses and the daily as a bonus); levels 1-50 unlock
	titles, nameplate colours, lobby dais rings and portrait frames. Never stats, never
	anything sold for Robux, never anything that changes a run.

	Pure data + functions, used by the server (AccountService.lua: awards XP, validates
	EquipCosmetic) and the lobby (MenuTrack.lua, the nameplate, the results screen).

	Save (DataService schema 6): data.Account = { XP = total XP ever, Level = level },
	data.Ring / data.Frame = worn dais ring / portrait frame id ("" = none). Titles and
	name colours share data.Title / data.NameColor with the achievements.
]]

local Palette = require(script.Parent.Palette)
local AchievementData = require(script.Parent.AchievementData)

local AccountData = {}

AccountData.MaxLevel = 50

-- XP from one run (all whole numbers; see RunXP).
AccountData.XP = {
	PerSecond = 1 / 5, -- 12 XP a minute survived
	PerStage = 50, -- each stage cleared
	PerKills = 10, -- 1 XP per this many kills
	PerBoss = 40, -- each stage boss the team beat
	Win = 60, -- left through the portal as a win
	Daily = 100, -- the day's scored Daily Challenge attempt
	MaxRun = 5000, -- safety cap for one run
}

-- XP needed to go from `level` to level + 1.
function AccountData.XPToNext(level: number): number
	return 150 + 50 * (math.max(1, level) - 1)
end

-- Total XP needed to reach `level` from level 1.
function AccountData.TotalFor(level: number): number
	local total = 0
	for l = 1, math.clamp(level, 1, AccountData.MaxLevel) - 1 do
		total += AccountData.XPToNext(l)
	end
	return total
end

-- Level for a total XP, plus the XP into that level and the XP the level needs
-- (need = 0 at the max level).
function AccountData.LevelFor(totalXP: number): (number, number, number)
	local xp = math.max(0, math.floor(totalXP))
	local level = 1
	while level < AccountData.MaxLevel do
		local need = AccountData.XPToNext(level)
		if xp < need then
			return level, xp, need
		end
		xp -= need
		level += 1
	end
	return AccountData.MaxLevel, 0, 0
end

export type RunSummary = {
	Seconds: number,
	Stages: number, -- stages cleared
	Kills: number,
	Bosses: number,
	Won: boolean,
	CurseMult: number?, -- the run's curse gold multiplier (XP gets the same bonus)
	DailyScored: boolean?,
}

-- XP of a run and its parts (for the results line).
function AccountData.RunXP(s: RunSummary): (number, { [string]: number })
	local X = AccountData.XP
	local parts = {
		Time = math.floor(math.max(0, s.Seconds) * X.PerSecond),
		Stages = math.max(0, s.Stages) * X.PerStage,
		Kills = math.floor(math.max(0, s.Kills) / X.PerKills),
		Bosses = math.max(0, s.Bosses) * X.PerBoss,
		Win = s.Won and X.Win or 0,
	}
	local base = parts.Time + parts.Stages + parts.Kills + parts.Bosses + parts.Win
	local mult = math.clamp(s.CurseMult or 1, 1, 3)
	parts.Curses = math.floor(base * (mult - 1) + 0.5)
	parts.Daily = s.DailyScored and X.Daily or 0
	local total = math.min(X.MaxRun, base + parts.Curses + parts.Daily)
	return total, parts
end

------------------------------------------------------------------------------------------
-- Cosmetics
------------------------------------------------------------------------------------------

-- Nameplate colours from the track (the achievement ones live in AchievementData.Colors).
AccountData.Colors = {
	Steel = { Name = "Steel", Color = Palette.steel_200 },
	Azure = { Name = "Azure", Color = Color3.fromRGB(132, 182, 230) },
	Rose = { Name = "Rose", Color = Color3.fromRGB(226, 150, 176) },
	Sunfire = { Name = "Sunfire", Color = Color3.fromRGB(250, 176, 92) },
	Starlight = { Name = "Starlight", Color = Color3.fromRGB(214, 226, 255) },
}

-- A nameplate colour from either source (achievements or the track), or nil.
function AccountData.ColorOf(id: string?): { Name: string, Color: Color3 }?
	if type(id) ~= "string" or id == "" then
		return nil
	end
	return AchievementData.Colors[id] or AccountData.Colors[id]
end

-- Rings of light on the lobby dais under your hero (client Showcase, your own screen).
-- Sparkles: rising motes; Glow: a soft light.
AccountData.Rings = {
	Ember = { Name = "Ember Ring", Color = Color3.fromRGB(240, 140, 70), Sparkles = false, Glow = 0.6 },
	Frost = { Name = "Frost Ring", Color = Color3.fromRGB(150, 210, 245), Sparkles = false, Glow = 0.7 },
	Verdant = { Name = "Verdant Ring", Color = Palette.moss_200, Sparkles = true, Glow = 0.7 },
	Arcane = { Name = "Arcane Ring", Color = Color3.fromRGB(176, 150, 236), Sparkles = true, Glow = 0.9 },
	Royal = { Name = "Royal Ring", Color = Palette.gold_300, Sparkles = true, Glow = 1.2, Double = true },
}

-- Portrait frames (the hero medallion on the results screen and the TRACK screen).
AccountData.Frames = {
	Bronze = { Name = "Bronze Frame", Color = Color3.fromRGB(196, 132, 82), Thickness = 3 },
	Silver = { Name = "Silver Frame", Color = Palette.steel_200, Thickness = 3, Double = true },
	Gold = { Name = "Gold Frame", Color = Palette.gold_300, Thickness = 3.5, Double = true },
	Crimson = { Name = "Crimson Frame", Color = Palette.crimson_300, Thickness = 3.5, Double = true, Gems = 2 },
	Royal = { Name = "Royal Frame", Color = Palette.gold_200, Thickness = 4, Double = true, Gems = 4 },
	Sovereign = { Name = "Sovereign Frame", Color = Color3.fromRGB(214, 226, 255), Thickness = 4, Double = true, Gems = 4 },
}

export type Reward = { Kind: string, Id: string } -- Kind = "Title" | "Color" | "Ring" | "Frame"

-- Level → rewards (levels without an entry give nothing but the level itself).
AccountData.Rewards = {
	[2] = { { Kind = "Title", Id = "Recruit" } },
	[3] = { { Kind = "Color", Id = "Steel" } },
	[5] = { { Kind = "Ring", Id = "Ember" } },
	[7] = { { Kind = "Frame", Id = "Bronze" } },
	[10] = { { Kind = "Title", Id = "Swarmbreaker" } },
	[12] = { { Kind = "Color", Id = "Azure" } },
	[15] = { { Kind = "Ring", Id = "Frost" } },
	[18] = { { Kind = "Frame", Id = "Silver" } },
	[20] = { { Kind = "Title", Id = "Hive Hunter" } },
	[22] = { { Kind = "Color", Id = "Rose" } },
	[25] = { { Kind = "Ring", Id = "Verdant" } },
	[28] = { { Kind = "Frame", Id = "Gold" } },
	[30] = { { Kind = "Title", Id = "Exterminator" } },
	[33] = { { Kind = "Color", Id = "Sunfire" } },
	[35] = { { Kind = "Ring", Id = "Arcane" } },
	[38] = { { Kind = "Frame", Id = "Crimson" } },
	[40] = { { Kind = "Title", Id = "Swarm Legend" } },
	[43] = { { Kind = "Color", Id = "Starlight" } },
	[45] = { { Kind = "Ring", Id = "Royal" } },
	[48] = { { Kind = "Frame", Id = "Royal" } },
	[50] = { { Kind = "Title", Id = "Sovereign" }, { Kind = "Frame", Id = "Sovereign" } },
} :: { [number]: { Reward } }

-- Levels that have a reward, ascending.
AccountData.RewardLevels = {}
for level in pairs(AccountData.Rewards) do
	table.insert(AccountData.RewardLevels, level)
end
table.sort(AccountData.RewardLevels)

-- The level that unlocks a cosmetic (nil = not a track cosmetic).
function AccountData.LevelOf(kind: string, id: string): number?
	for _, level in ipairs(AccountData.RewardLevels) do
		for _, r in ipairs(AccountData.Rewards[level]) do
			if r.Kind == kind and r.Id == id then
				return level
			end
		end
	end
	return nil
end

-- True when a player of `level` has this cosmetic from the track.
function AccountData.Has(level: number, kind: string, id: string): boolean
	local need = AccountData.LevelOf(kind, id)
	return need ~= nil and level >= need
end

-- Display name of a reward ("Title: Recruit", "Ember Ring").
function AccountData.RewardName(r: Reward): string
	if r.Kind == "Title" then
		return "Title: " .. r.Id
	elseif r.Kind == "Color" then
		local c = AccountData.Colors[r.Id]
		return (c and c.Name or r.Id) .. " name colour"
	elseif r.Kind == "Ring" then
		local c = AccountData.Rings[r.Id]
		return c and c.Name or r.Id
	elseif r.Kind == "Frame" then
		local c = AccountData.Frames[r.Id]
		return c and c.Name or r.Id
	end
	return r.Id
end

-- Rewards unlocked between two levels (from, to], in order.
function AccountData.RewardsBetween(from: number, to: number): { Reward }
	local out = {}
	for _, level in ipairs(AccountData.RewardLevels) do
		if level > from and level <= to then
			for _, r in ipairs(AccountData.Rewards[level]) do
				table.insert(out, r)
			end
		end
	end
	return out
end

return AccountData
