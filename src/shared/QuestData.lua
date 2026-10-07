--[[
	QuestData.lua
	Daily quests (Config.Features.DailyQuests, Config.DailyQuests; docs/next/DAILY_QUESTS.md).
	Pure data and maths shared by the server (DailyQuests.lua) and the lobby (MenuQuests.lua).

	Every UTC day (CurseData.DayOf) has 3 quests, the same for every player: Config.DailyQuests
	.Slots lists the pool tier of each slot ("Easy", "Easy", "Hard"), and a seeded pick from
	the day number takes distinct quests from that tier. Quests whose feature switch is off
	are left out of the pool (the pick stays the same for everyone on a server build).

	Quest: { Id, Text, Goal, Metric, Kind = "Sum" | "Max", Tier, Icon, Feature? }
	  Sum  progress adds up across the day's clean runs (kills, chests, gold ...)
	  Max  the best single run of the day (stage reached, minutes survived, weapon level)
	Metric names are what DailyQuests.lua measures on a run player (see METRICS there).
]]

local Config = require(script.Parent.Config)

local QuestData = {}

export type Quest = {
	Id: string,
	Text: string,
	Goal: number,
	Metric: string,
	Kind: string,
	Tier: string,
	Icon: string,
	Feature: string?,
}

QuestData.Quests = {
	-- Easy
	{ Id = "Kills500", Text = "Defeat 500 enemies", Goal = 500, Metric = "Kills", Kind = "Sum", Tier = "Easy", Icon = "stat_Kills" },
	{ Id = "Chests5", Text = "Open 5 chests", Goal = 5, Metric = "Chests", Kind = "Sum", Tier = "Easy", Icon = "chest" },
	{ Id = "Gold2000", Text = "Collect 2,000 gold in runs", Goal = 2000, Metric = "Gold", Kind = "Sum", Tier = "Easy", Icon = "stat_Gold" },
	{ Id = "Gems300", Text = "Pick up 300 XP gems", Goal = 300, Metric = "Gems", Kind = "Sum", Tier = "Easy", Icon = "sparkle" },
	{ Id = "Ultimate5", Text = "Use your ultimate 5 times", Goal = 5, Metric = "Ultimates", Kind = "Sum", Tier = "Easy", Icon = "chevronsUp", Feature = "Ultimate" },
	{ Id = "DailyRun", Text = "Play the daily challenge", Goal = 1, Metric = "DailyRuns", Kind = "Sum", Tier = "Easy", Icon = "calendar" },
	{ Id = "DuoRun", Text = "Play a Duo run", Goal = 1, Metric = "DuoRuns", Kind = "Sum", Tier = "Easy", Icon = "people2" },
	{ Id = "SecretRoom", Text = "Break open a secret room", Goal = 1, Metric = "SecretRooms", Kind = "Sum", Tier = "Easy", Icon = "castle", Feature = "SecretRooms" },
	{ Id = "Level15", Text = "Reach level 15 in one run", Goal = 15, Metric = "Level", Kind = "Max", Tier = "Easy", Icon = "stat_Upgrades" },
	-- Hard
	{ Id = "WinMage", Text = "Win a run with the Mage", Goal = 1, Metric = "WinsMage", Kind = "Sum", Tier = "Hard", Icon = "trophy" },
	{ Id = "Stage3", Text = "Reach stage 3", Goal = 3, Metric = "Stage", Kind = "Max", Tier = "Hard", Icon = "portal" },
	{ Id = "Survive10", Text = "Survive 10 minutes in one run", Goal = 600, Metric = "Time", Kind = "Max", Tier = "Hard", Icon = "stat_BestTime" },
	{ Id = "Boss1", Text = "Defeat a boss", Goal = 1, Metric = "Bosses", Kind = "Sum", Tier = "Hard", Icon = "skull" },
	{ Id = "Weapon8", Text = "Level a weapon to 8", Goal = 8, Metric = "WeaponLevel", Kind = "Max", Tier = "Hard", Icon = "sword" },
	{ Id = "Trial", Text = "Win a Shrine of Trial", Goal = 1, Metric = "Trials", Kind = "Sum", Tier = "Hard", Icon = "medal", Feature = "TrialShrine" },
	{ Id = "Rescue", Text = "Rescue the lost villager", Goal = 1, Metric = "Rescues", Kind = "Sum", Tier = "Hard", Icon = "person", Feature = "Rescue" },
	{ Id = "Win1", Text = "Win a run", Goal = 1, Metric = "Wins", Kind = "Sum", Tier = "Hard", Icon = "stat_Wins" },
} :: { Quest }

QuestData.ById = {} :: { [string]: Quest }
for _, q in ipairs(QuestData.Quests) do
	assert(QuestData.ById[q.Id] == nil, "QuestData: duplicate id " .. q.Id)
	QuestData.ById[q.Id] = q
end

-- The quests a pick can use for one tier (switched-off features left out), in list order.
function QuestData.Pool(tier: string): { Quest }
	local list = {}
	for _, q in ipairs(QuestData.Quests) do
		if q.Tier == tier and (q.Feature == nil or Config.FeatureOn(q.Feature)) then
			table.insert(list, q)
		end
	end
	return list
end

-- Park-Miller step: small integers only, so Luau and every runtime give the same numbers.
local M = 2147483647
local function step(x: number): number
	return (x * 48271) % M
end

-- The day's quest ids, one per Config.DailyQuests.Slots entry, distinct. Deterministic.
function QuestData.Pick(day: number): { string }
	local slots = Config.DailyQuests.Slots
	local seed = (math.floor(day) * 7919 + 104729) % M
	if seed == 0 then
		seed = 1
	end
	local x = step(step(seed))
	local out, used = {}, {}
	for _, tier in ipairs(slots) do
		local pool = {}
		for _, q in ipairs(QuestData.Pool(tier)) do
			if not used[q.Id] then
				table.insert(pool, q)
			end
		end
		if #pool > 0 then
			x = step(x)
			local q = pool[(x % #pool) + 1]
			used[q.Id] = true
			table.insert(out, q.Id)
		end
	end
	return out
end

-- The gold for slot i (Config.DailyQuests.Rewards).
function QuestData.RewardGold(i: number): number
	return math.max(0, math.floor(tonumber(Config.DailyQuests.Rewards[i]) or 0))
end

-- The day's saved state as a clean read-only view: (progress[id], claimed[id], bonusClaimed).
-- A save from another day reads as empty.
function QuestData.View(save: any, day: number): ({ [string]: number }, { [string]: boolean }, boolean)
	if type(save) ~= "table" or tonumber(save.Day) ~= day then
		return {}, {}, false
	end
	local progress = type(save.Progress) == "table" and save.Progress or {}
	local claimed = type(save.Claimed) == "table" and save.Claimed or {}
	local p, c = {}, {}
	for k, v in pairs(progress) do
		if type(k) == "string" and type(v) == "number" then
			p[k] = v
		end
	end
	for k, v in pairs(claimed) do
		if type(k) == "string" and v == true then
			c[k] = true
		end
	end
	return p, c, c.Bonus == true
end

-- (done, claimed, claimable) counts for the day's three quests.
function QuestData.Counts(save: any, day: number): (number, number, number)
	local progress, claimed = QuestData.View(save, day)
	local done, got, ready = 0, 0, 0
	for _, id in ipairs(QuestData.Pick(day)) do
		local q = QuestData.ById[id]
		local isDone = (progress[id] or 0) >= q.Goal
		if isDone then
			done += 1
		end
		if claimed[id] then
			got += 1
		elseif isDone then
			ready += 1
		end
	end
	return done, got, ready
end

-- True when all of the day's quests are claimed and the bonus is not yet.
function QuestData.BonusReady(save: any, day: number): boolean
	local _, got = QuestData.Counts(save, day)
	local _, _, bonus = QuestData.View(save, day)
	return got >= #QuestData.Pick(day) and not bonus
end

-- "12 / 500", "4:10 / 10:00" for the time quest.
function QuestData.ProgressText(q: Quest, value: number): string
	local v = math.min(math.floor(value), q.Goal)
	if q.Metric == "Time" then
		return string.format("%d:%02d / %d:%02d", v // 60, v % 60, q.Goal // 60, q.Goal % 60)
	end
	return string.format("%d / %d", v, q.Goal)
end

-- The notice dot key: what can be claimed today ("" = nothing).
function QuestData.DotKey(save: any, day: number): string
	local progress, claimed = QuestData.View(save, day)
	local parts = {}
	for _, id in ipairs(QuestData.Pick(day)) do
		if not claimed[id] and (progress[id] or 0) >= QuestData.ById[id].Goal then
			table.insert(parts, id)
		end
	end
	if QuestData.BonusReady(save, day) then
		table.insert(parts, "Bonus")
	end
	return #parts > 0 and (tostring(day) .. ":" .. table.concat(parts, ",")) or ""
end

return QuestData
