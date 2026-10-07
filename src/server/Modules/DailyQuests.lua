--[[
	DailyQuests.lua
	Daily quests (Config.Features.DailyQuests, Config.DailyQuests, QuestData;
	docs/next/DAILY_QUESTS.md). Three quests per UTC day, the same for everyone
	(QuestData.Pick(day)); progress across the day's runs; gold per quest and a look for
	finishing all three. With the switch off nothing here runs and the remote does nothing.

	Counting (server only, from real run events):
	  * live, once a second, from the run player: Kills, Gold (earned = rp.Gold + GoldSpent),
	    Level, Stage (StageManager while not returned), Time (run seconds while alive),
	    WeaponLevel (best weapon), Ultimates (rp.UltUses), Chests (LootSystem rp.ChestsOpened),
	    Gems (XPSystem rp.GemsPicked), SecretRooms (SecretRoom rp.SecretRoomsOpened), Trials
	    (TrialShrine rp.TrialsWon), Rescues (Rescue rp.VillagersSaved), Bosses (Events
	    BossDefeated: a stage boss beaten by the team).
	  * at the end, from RunManager's commit: Wins, WinsMage (a win as the Mage), DuoRuns and
	    DailyRuns (that mode played at least PlayMinSeconds).
	  The live numbers are only shown (progress notices, at most one per ToastGap seconds per
	  player through the notice lane); the save changes once, in CommitRun, which RunManager
	  calls once per run player after its DEV-taint return, and again refuses a DEV-tainted
	  run or a DevBoosted profile. A run that crosses midnight counts for the day it ends.

	Save (additive, no schema bump): data.DailyQuests = { Day = n, Progress = { [questId] =
	number }, Claimed = { [questId] = true, Bonus = true? } }. Another day's table is
	replaced by an empty one for today.

	Remote "Quests" (lobby only, Config.DailyQuests.Rate per second):
	  ("Claim", questId)  one of today's quests, done and not claimed: marked, then paid
	  ("ClaimBonus")      all of today's quests claimed: the first BonusCosmetics look not
	                      owned yet, else BonusGoldAfter gold. Marked before it pays.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local QuestData = require(Shared.QuestData)
local CurseData = require(Shared.CurseData)
local CosmeticData = require(Shared.CosmeticData)
local WeaponData = require(Shared.WeaponData)
local Events = require(script.Parent.Events)

local DailyQuests = {}

local ctx
local stepTimer = 0
local clock: () -> number = os.time

local GOOD = Color3.fromRGB(255, 220, 120)
local INFO = Color3.fromRGB(200, 220, 255)
local QUEST = Color3.fromRGB(150, 230, 200)

local function on(): boolean
	return Config.FeatureOn("DailyQuests")
end

local function K()
	return Config.DailyQuests
end

-- Tests swap the clock (day rollover).
function DailyQuests._SetClock(fn: (() -> number)?)
	clock = fn or os.time
end

function DailyQuests.Today(): number
	return CurseData.DayOf(clock())
end

local function finite(v: any): number
	local n = tonumber(v)
	if not n or n ~= n or n == math.huge or n == -math.huge then
		return 0
	end
	return math.max(0, math.floor(n))
end

-- The save's table for today (a new day starts empty). Cleans junk on the way.
function DailyQuests.Ensure(data, day: number?): { [string]: any }
	local today = day or DailyQuests.Today()
	local q = data.DailyQuests
	if type(q) ~= "table" or finite(q.Day) ~= today then
		q = { Day = today, Progress = {}, Claimed = {} }
		data.DailyQuests = q
		return q
	end
	q.Day = today
	local progress, claimed = {}, {}
	if type(q.Progress) == "table" then
		for id, v in pairs(q.Progress) do
			if type(id) == "string" and QuestData.ById[id] then
				progress[id] = finite(v)
			end
		end
	end
	if type(q.Claimed) == "table" then
		for id, v in pairs(q.Claimed) do
			if v == true and type(id) == "string" and (QuestData.ById[id] or id == "Bonus") then
				claimed[id] = true
			end
		end
	end
	q.Progress = progress
	q.Claimed = claimed
	return q
end

local function tainted(rp, data): boolean
	return rp.DevTainted == true or (data ~= nil and data.DevBoosted == true)
end

-- What this run has done so far (live metrics; the end-of-run ones are added in CommitRun).
local function metrics(rp): { [string]: number }
	local best = 0
	for _, w in pairs(rp.Weapons or {}) do
		if type(w) == "table" then
			best = math.max(best, w.Evolved and WeaponData.MaxLevel or finite(w.Level))
		end
	end
	return {
		Kills = finite(rp.Kills),
		Gold = finite((tonumber(rp.Gold) or 0) + (tonumber(rp.GoldSpent) or 0)),
		Level = finite(rp.Level),
		Stage = finite(rp.QuestStage),
		Time = finite(rp.QuestTime),
		WeaponLevel = best,
		Ultimates = finite(rp.UltUses),
		Chests = finite(rp.ChestsOpened),
		Gems = finite(rp.GemsPicked),
		SecretRooms = finite(rp.SecretRoomsOpened),
		Trials = finite(rp.TrialsWon),
		Rescues = finite(rp.VillagersSaved),
		Bosses = finite(rp.QuestBosses),
	}
end
DailyQuests.Metrics = metrics

-- Saved progress + this run's numbers for one quest.
local function combined(q: QuestData.Quest, saved: number, run: number): number
	if q.Kind == "Max" then
		return math.max(saved, run)
	end
	return saved + run
end

-- Live progress of today's quests for a run player (nothing for a tainted one): {{Quest, Value, Claimed}}.
function DailyQuests.Live(rp): { { [string]: any } }
	local data = ctx.DataService.GetData(rp.Player)
	if not data or not on() or tainted(rp, data) then
		return {}
	end
	local day = DailyQuests.Today()
	local progress, claimed = QuestData.View(data.DailyQuests, day)
	local m = metrics(rp)
	local out = {}
	for _, id in ipairs(QuestData.Pick(day)) do
		local q = QuestData.ById[id]
		table.insert(out, { Quest = q, Value = combined(q, progress[id] or 0, m[q.Metric] or 0), Claimed = claimed[id] == true, Saved = progress[id] or 0 })
	end
	return out
end

------------------------------------------------------------------------------------------
-- Run end
------------------------------------------------------------------------------------------

--[[
	RunManager.saveRunStats (once per run player, clean runs only): adds the run to today's
	progress. info = { Won, Mode, Seconds }. Returns the ids that became done, or nil.
]]
function DailyQuests.CommitRun(rp, info: { [string]: any }): { string }?
	local ok, result = pcall(function()
		if not on() or rp.QuestCommitted then
			return nil
		end
		rp.QuestCommitted = true
		local data = ctx.DataService.GetData(rp.Player)
		if not data or tainted(rp, data) then
			return nil
		end
		local m = metrics(rp)
		local seconds = finite(info.Seconds)
		local played = seconds >= (K().PlayMinSeconds or 0)
		m.Wins = info.Won == true and 1 or 0
		m.WinsMage = (info.Won == true and rp.CharacterId == "Mage") and 1 or 0
		m.DuoRuns = (played and info.Mode == "Duo") and 1 or 0
		m.DailyRuns = (played and (rp.Daily == true or info.Mode == "Daily")) and 1 or 0
		local day = DailyQuests.Today()
		local save = DailyQuests.Ensure(data, day)
		local newly = {}
		for _, id in ipairs(QuestData.Pick(day)) do
			local q = QuestData.ById[id]
			local before = save.Progress[id] or 0
			local after = math.min(combined(q, before, m[q.Metric] or 0), q.Goal)
			save.Progress[id] = after
			if before < q.Goal and after >= q.Goal then
				table.insert(newly, id)
			end
		end
		if #newly > 0 and ctx.RunManager then
			local q = QuestData.ById[newly[1]]
			ctx.RunManager.Notify(rp.Player, #newly == 1 and ("Quest complete: " .. q.Text .. "! Claim it in the lobby.") or (#newly .. " quests complete! Claim them in the lobby."), QUEST, { Id = "quest.done", Lane = "Notice", Class = "Info" })
		end
		return newly
	end)
	if not ok then
		warn("[DailyQuests] commit failed: " .. tostring(result))
		return nil
	end
	return result
end

------------------------------------------------------------------------------------------
-- In-run notices (live, never saved)
------------------------------------------------------------------------------------------

local function quarter(value: number, goal: number): number
	return math.clamp(math.floor(value / goal * 4), 0, 4)
end

local function liveStep()
	local RM = ctx.RunManager
	if not RM.IsRunning() then
		return
	end
	local stage = ctx.StageManager and ctx.StageManager.GetStage() or 0
	local runTime = RM.GetRunTime()
	local gap = K().ToastGap or 20
	for _, rp in ipairs(RM.GetRunPlayers()) do
		if not rp.Returned then
			rp.QuestStage = math.max(finite(rp.QuestStage), stage)
			if rp.Alive then
				rp.QuestTime = math.max(finite(rp.QuestTime), math.floor(runTime))
			end
		end
		local live = DailyQuests.Live(rp)
		if #live > 0 then
			local marks = rp.QuestMarks
			if not marks then
				-- the first look this run: what was already true makes no notice
				marks = {}
				for _, e in ipairs(live) do
					marks[e.Quest.Id] = e.Claimed and 4 or quarter(e.Value, e.Quest.Goal)
				end
				rp.QuestMarks = marks
			end
			for _, e in ipairs(live) do
				local qn = quarter(e.Value, e.Quest.Goal)
				if qn > (marks[e.Quest.Id] or 0) then
					marks[e.Quest.Id] = qn
					local q = e.Quest
					local done = qn >= 4
					-- a finished quest outranks a progress line waiting for its turn
					if done or not (rp.QuestToast and rp.QuestToast.Done) then
						rp.QuestToast = {
							Done = done,
							Text = done and ("Quest done: " .. q.Text .. "! Claim it in the lobby.")
								or ("Quest: " .. q.Text .. " · " .. QuestData.ProgressText(q, e.Value)),
						}
					end
				end
			end
			local pending = rp.QuestToast
			if pending and runTime - (rp.QuestToastAt or -math.huge) >= gap then
				rp.QuestToast = nil
				rp.QuestToastAt = runTime
				RM.Notify(rp.Player, pending.Text, QUEST, { Id = "quest.progress", Lane = "Notice", Class = "Info" })
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Claims (lobby)
------------------------------------------------------------------------------------------

local function notify(player: Player, text: string, color: Color3, id: string)
	if ctx.RunManager and player.Parent then
		ctx.RunManager.Notify(player, text, color, { Id = id })
	end
end

local function persist(player: Player)
	if ctx.DataService.ForceSave then
		task.spawn(function()
			pcall(ctx.DataService.ForceSave, player)
		end)
	end
	if player.Parent and ctx.GoldSystem then
		ctx.GoldSystem.SyncProfile(player)
	end
end

-- Puts an earned look in Cosmetics.Owned; false when owned already, unknown or the set is full.
function DailyQuests.GrantLook(data, id: string): boolean
	local e = CosmeticData.Get(id)
	if not e or e.Source ~= "Earned" then
		return false
	end
	if type(data.Cosmetics) ~= "table" then
		data.Cosmetics = {}
	end
	if type(data.Cosmetics.Owned) ~= "table" then
		data.Cosmetics.Owned = {}
	end
	local owned = data.Cosmetics.Owned
	if owned[id] == true then
		return false
	end
	local n = 0
	for _ in pairs(owned) do
		n += 1
	end
	if n >= Config.Data.Caps.SetEntries then
		return false
	end
	owned[id] = true
	return true
end

local function claim(player: Player, data, id: any)
	if type(id) ~= "string" then
		return
	end
	local day = DailyQuests.Today()
	local picks = QuestData.Pick(day)
	local slot = table.find(picks, id)
	if not slot then
		return
	end
	local save = DailyQuests.Ensure(data, day)
	local q = QuestData.ById[id]
	if save.Claimed[id] then
		notify(player, "Already claimed.", INFO, "quest.claimed")
		return
	end
	if (save.Progress[id] or 0) < q.Goal then
		notify(player, "Not done yet: " .. QuestData.ProgressText(q, save.Progress[id] or 0), INFO, "quest.notyet")
		return
	end
	-- marked before anything is paid: exactly once
	save.Claimed[id] = true
	local gold = QuestData.RewardGold(slot)
	data.Gold += gold
	notify(player, string.format("Quest reward: +%d gold", gold), GOOD, "quest.reward")
	persist(player)
end

local function claimBonus(player: Player, data)
	local day = DailyQuests.Today()
	local save = DailyQuests.Ensure(data, day)
	if not QuestData.BonusReady(save, day) then
		return
	end
	save.Claimed.Bonus = true
	local line
	for _, id in ipairs(K().BonusCosmetics or {}) do
		if DailyQuests.GrantLook(data, id) then
			local e = CosmeticData.Get(id)
			line = "New look: " .. (e and e.Name or id) .. "! Wear it from the STORE."
			break
		end
	end
	if not line then
		local gold = math.max(0, math.floor(tonumber(K().BonusGoldAfter) or 0))
		data.Gold += gold
		line = string.format("All quests done: +%d gold", gold)
	end
	notify(player, line, GOOD, "quest.bonus")
	persist(player)
end

local function onQuests(player: Player, action: any, a: any)
	if not on() or type(action) ~= "string" then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data or ctx.RunManager.IsParticipant(player) then
		return
	end
	if action == "Claim" then
		claim(player, data, a)
	elseif action == "ClaimBonus" then
		claimBonus(player, data)
	end
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function DailyQuests.Step(dt: number)
	if not on() then
		return
	end
	stepTimer += dt
	if stepTimer < 1 then
		return
	end
	stepTimer = 0
	liveStep()
end

function DailyQuests.Init(c)
	ctx = c
end

function DailyQuests.Start()
	Remotes.Listen("Quests", onQuests, Config.DailyQuests.Rate or 4)
	Events.On("BossDefeated", function(player)
		local rp = ctx.RunManager.GetRunPlayer(player)
		if rp then
			rp.QuestBosses = (rp.QuestBosses or 0) + 1
		end
	end)
	ctx.DataService.OnProfileLoaded(function(player)
		local data = ctx.DataService.GetData(player)
		if data and on() and data.DailyQuests ~= nil then
			DailyQuests.Ensure(data) -- a stale day is cleared before the client sees it
		end
	end)
end

return DailyQuests
