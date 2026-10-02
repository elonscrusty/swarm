--[[
	AchievementService.lua
	Server-authoritative achievements (src/shared/AchievementData.lua).

	Game systems only fire bus events (Modules/Events.lua): RunManager (BossKilled, RunWon,
	PartnerRevive), StageManager (StageCleared, BossDefeated { Boss } per stage boss),
	LootSystem (GoldenChest, OptionalEvent).
	RunTime, Level, StageReached and RunKills are read here once a second from the run players.

	Save (DataService schema 4):
	  data.Achievements = { Progress = { [id] = number }, Unlocked = { [id] = os.time() } }
	  data.Title = "" | title text, data.NameColor = "" | AchievementData.Colors id
	Unlocking pays the reward at once into the save (gold, a character, a cosmetic) and
	tells the player (AchievementUnlocked toast). Unlocks of the current run are listed on
	the results screen (TakeRunUnlocks). Clients only ever send EquipCosmetic (a title /
	colour they have earned from an achievement or the account level track, validated here;
	rings and frames go to AccountService.Equip).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local AchievementData = require(game:GetService("ReplicatedStorage").Shared.AchievementData)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local Events = require(script.Parent.Events)

local AchievementService = {}

local ctx
local runUnlocks: { [Player]: { { [string]: any } } } = {}
local pollTimer = 0

local function store(data)
	local a = data.Achievements
	if type(a) ~= "table" then
		a = {}
		data.Achievements = a
	end
	if type(a.Progress) ~= "table" then
		a.Progress = {}
	end
	if type(a.Unlocked) ~= "table" then
		a.Unlocked = {}
	end
	return a
end

function AchievementService.IsUnlocked(player: Player, id: string): boolean
	local data = ctx.DataService.GetData(player)
	return data ~= nil and store(data).Unlocked[id] ~= nil
end

local function unlock(player: Player, data, id: string)
	local def = AchievementData.Achievements[id]
	local a = store(data)
	if a.Unlocked[id] then
		return
	end
	a.Unlocked[id] = os.time()
	a.Progress[id] = def.Goal
	local r = def.Reward
	if r.Gold and r.Gold > 0 then
		data.Gold += r.Gold -- straight into the save (never the run wallet)
	end
	if r.Character and CharacterData.Characters[r.Character] then
		data.OwnedCharacters[r.Character] = true
	end
	if r.Title and (data.Title == nil or data.Title == "") then
		data.Title = r.Title -- the first earned title is worn at once
	end
	if r.Color and (data.NameColor == nil or data.NameColor == "") then
		data.NameColor = r.Color
	end
	local info = { Id = id, Name = def.Name, Reward = AchievementData.RewardText(id), Icon = def.Icon }
	local list = runUnlocks[player]
	if not list then
		list = {}
		runUnlocks[player] = list
	end
	table.insert(list, info)
	if player.Parent then
		Remotes.FireClient("AchievementUnlocked", player, info)
		player:SetAttribute("Gold", data.Gold)
		if not ctx.RunManager.IsParticipant(player) then
			ctx.GoldSystem.SyncProfile(player)
		end
	end
end

local function matches(filter: { [string]: any }?, data: { [string]: any }): boolean
	if not filter then
		return true
	end
	for k, v in pairs(filter) do
		if data[k] ~= v then
			return false
		end
	end
	return true
end

local function onEvent(eventName: string, player: Player, payload: { [string]: any })
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	local a = store(data)
	for _, id in ipairs(AchievementData.Order) do
		local def = AchievementData.Achievements[id]
		if def.Event == eventName and not a.Unlocked[id] and matches(def.Filter, payload) then
			local before = tonumber(a.Progress[id]) or 0
			local value = before
			if def.Kind == "Max" then
				value = math.max(before, tonumber(payload[def.Field or "Value"]) or 0)
			else
				value = before + (tonumber(payload.Amount) or 1)
			end
			if value ~= before then
				a.Progress[id] = math.min(value, def.Goal)
			end
			if value >= def.Goal then
				unlock(player, data, id)
			end
		end
	end
end

-- Unlocks earned since the last call (results screen), oldest first.
function AchievementService.TakeRunUnlocks(player: Player): { { [string]: any } }
	local list = runUnlocks[player] or {}
	runUnlocks[player] = nil
	return list
end

-- Clears the list at the start of a run (a lobby unlock is not "this run").
function AchievementService.OnRunStart(player: Player)
	runUnlocks[player] = nil
end

-- Title / colour lists for the profile view: what is earned and worn.
function AchievementService.ProfileView(data)
	local a = store(data)
	return {
		Progress = a.Progress,
		Unlocked = a.Unlocked,
	}
end

local function onEquip(player: Player, kind: any, value: any)
	local data = ctx.DataService.GetData(player)
	if not data or type(value) ~= "string" or #value > 40 then
		return
	end
	if kind == "Ring" or kind == "Frame" then
		-- level-track cosmetics (AccountService checks the level)
		if ctx.AccountService.Equip(player, kind, value) then
			ctx.GoldSystem.SyncProfile(player)
		end
		return
	end
	if kind ~= "Title" and kind ~= "Color" then
		return
	end
	if value ~= "" then
		-- earned from an achievement, or from the account level track
		local source = AchievementData.Source(kind, value)
		local fromAchievement = source ~= nil and store(data).Unlocked[source] ~= nil
		if not fromAchievement and not ctx.AccountService.CanWear(data, kind, value) then
			return
		end
	end
	if kind == "Title" then
		data.Title = value
	else
		data.NameColor = value
	end
	ctx.GoldSystem.SyncProfile(player)
end

function AchievementService.Step(dt: number)
	pollTimer += dt
	if pollTimer < 1 then
		return
	end
	pollTimer = 0
	if not ctx.RunManager.IsRunning() then
		return
	end
	local runTime = ctx.RunManager.GetRunTime()
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and not rp.Returned then
			Events.Fire("RunTime", rp.Player, { Seconds = math.floor(runTime) })
		end
		if (rp.Level or 1) > (rp.AchievedLevel or 1) then
			rp.AchievedLevel = rp.Level
			Events.Fire("Level", rp.Player, { Level = rp.Level })
		end
		-- hero unlocks: the stage the run reached (Deep Delver) and kills this run (Reaper)
		if not rp.Returned then
			local stage = ctx.StageManager and ctx.StageManager.GetStage() or 0
			if stage > (rp.AchievedStage or 0) then
				rp.AchievedStage = stage
				Events.Fire("StageReached", rp.Player, { Stage = stage })
			end
			if (rp.Kills or 0) > (rp.AchievedKills or 0) then
				rp.AchievedKills = rp.Kills
				Events.Fire("RunKills", rp.Player, { Kills = rp.Kills })
			end
		end
	end
end

function AchievementService.Init(c)
	ctx = c
	local bound: { [string]: boolean } = {}
	for _, id in ipairs(AchievementData.Order) do
		local name = AchievementData.Achievements[id].Event
		if not bound[name] then
			bound[name] = true
			Events.On(name, function(player, payload)
				onEvent(name, player, payload)
			end)
		end
	end
	assert(Config.Data.SchemaVersion >= 4, "AchievementService needs save schema 4")
end

function AchievementService.Start()
	Remotes.Listen("EquipCosmetic", onEquip, 4)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		runUnlocks[player] = nil
	end)
end

return AchievementService
