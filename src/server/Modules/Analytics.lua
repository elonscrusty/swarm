--[[
	Analytics.lua  (server only)
	Roblox funnel analytics for new players (AnalyticsService; switch
	Config.Features.Analytics; docs/ANALYTICS.md). Every call comes from this server module:
	Roblox ignores events sent from the client or from Studio, so nothing is sent in Studio
	(Studio only keeps the local log below for the offline checks).

	Onboarding funnel (LogOnboardingFunnelStepEvent; Roblox keeps the first of each step per
	user, across servers and reconnects, and counts skipped earlier steps as done). Step
	numbers and names are fixed: never renumber or rename them, the dashboard keys on them.
	  1 Joined Game       the player's save loaded on a lobby server
	  2 Ready to Play     the client reports (remote ClientReady) that the loading picture is
	                      gone and the lobby menu shows with the player's profile; the server
	                      accepts it once per server visit, only after step 1 here
	  3 Started First Run a run really started for the player (RunManager.beginRun) and the
	                      save says it is the account's first (Stats.Runs was 0)
	Only accounts that have never started a run (save Stats.Runs == 0 when the save loads)
	enter the funnel, so long-time players never inflate step 1. No later steps: everything
	after the first run start is optional or can happen in any order.

	Custom events (LogCustomEvent, value 1, at most once per account by the save rules):
	  "First Evolution"       a weapon evolved (level-up card or chest) and the save had no
	                          evolution discovered yet (Discovered.Evolutions)
	  "First Wave Completed"  wave 1 of the account's first run was cleared (EnemySpawner's
	                          clear rule, not its timeout); the player was in the run and alive
	  "Started Second Run"    a run really started and the save says it is the account's
	                          second (Stats.Runs was 1)
	The "first" in every name is per account (across visits), read from the existing save;
	nothing new is saved. DEV-tainted runs send no custom events.

	Every AnalyticsService call is wrapped in pcall: an analytics failure never reaches
	gameplay. Per server visit each player sends each step / event at most once.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)

local Analytics = {}

-- Fixed step numbers / names (the Creator Dashboard groups by them).
Analytics.Steps = {
	JoinedGame = { Step = 1, Name = "Joined Game" },
	ReadyToPlay = { Step = 2, Name = "Ready to Play" },
	StartedFirstRun = { Step = 3, Name = "Started First Run" },
}
Analytics.Events = {
	FirstEvolution = "First Evolution",
	FirstWaveCompleted = "First Wave Completed",
	StartedSecondRun = "Started Second Run",
}

local ctx
local service: AnalyticsService? = nil

-- per server visit: players whose save showed no run ever started when it loaded
local onboarding: { [Player]: boolean } = {}
-- per server visit: what this player has already sent ("Step1", "First Evolution", ...)
local sent: { [Player]: { [string]: boolean } } = {}
-- players in the account's first run right now (set at its start, cleared at the next one)
local inFirstRun: { [Player]: boolean } = {}

--[[
	What was sent (or, in Studio, would have been): { Kind = "Step" | "Event", UserId,
	Step?, Name } in order. Read by the offline checks; capped so a long server stays small.
]]
Analytics.Log = {} :: { { Kind: string, UserId: number, Step: number?, Name: string } }
local LOG_MAX = 200

local function enabled(): boolean
	return Config.FeatureOn("Analytics")
end

-- Real calls only in a published game (Roblox drops Studio / unpublished events anyway).
local function live(): boolean
	return service ~= nil and not RunService:IsStudio() and game.PlaceId ~= 0
end

local function record(entry)
	if #Analytics.Log >= LOG_MAX then
		table.remove(Analytics.Log, 1)
	end
	table.insert(Analytics.Log, entry)
end

-- First time `key` for this player this visit? Marks it.
local function once(player: Player, key: string): boolean
	local s = sent[player]
	if not s then
		s = {}
		sent[player] = s
	end
	if s[key] then
		return false
	end
	s[key] = true
	return true
end

local function logStep(player: Player, step: { Step: number, Name: string })
	if not enabled() or not player.Parent or not once(player, "Step" .. step.Step) then
		return
	end
	record({ Kind = "Step", UserId = player.UserId, Step = step.Step, Name = step.Name })
	if live() then
		local ok, err = pcall(function()
			(service :: AnalyticsService):LogOnboardingFunnelStepEvent(player, step.Step, step.Name)
		end)
		if not ok then
			warn("[Analytics] onboarding step " .. step.Step .. " failed: " .. tostring(err))
		end
	end
end

local function logEvent(player: Player, name: string)
	if not enabled() or not player.Parent or not once(player, name) then
		return
	end
	record({ Kind = "Event", UserId = player.UserId, Name = name })
	if live() then
		local ok, err = pcall(function()
			(service :: AnalyticsService):LogCustomEvent(player, name, 1)
		end)
		if not ok then
			warn("[Analytics] custom event '" .. name .. "' failed: " .. tostring(err))
		end
	end
end

local function runServer(): boolean
	return ctx.RunServers ~= nil and ctx.RunServers.IsRunServer()
end

local function devTainted(player: Player): boolean
	return ctx.RunManager ~= nil and ctx.RunManager.IsDevTainted(player)
end

-- Step 1: the save loaded on a lobby server (a run server's players came from a lobby).
local function onProfileLoaded(player: Player)
	-- memory-only saves start from defaults: an old account would look brand new
	if not enabled() or runServer() or ctx.DataService.IsMemoryOnly() then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data or type(data.Stats) ~= "table" or (tonumber(data.Stats.Runs) or 0) > 0 then
		return
	end
	onboarding[player] = true
	logStep(player, Analytics.Steps.JoinedGame)
end

--[[
	Step 2: remote ClientReady (no arguments; anything sent is ignored). Accepted once per
	visit, only from a player in the funnel on this lobby server whose save is loaded and
	whose step 1 went out; repeats, early calls and everyone else are dropped.
]]
local function onClientReady(player: Player)
	if not onboarding[player] or not ctx.DataService.GetData(player) then
		return
	end
	local s = sent[player]
	if not s or not s.Step1 then
		return
	end
	logStep(player, Analytics.Steps.ReadyToPlay)
end

--[[
	RunManager.beginRun, for each run player just before the save counts the run:
	`priorRuns` = the save's Stats.Runs before this run. 0 → step 3, 1 → "Started Second
	Run". Works on lobby and run servers alike (the run plays where it starts).
]]
function Analytics.OnRunStart(player: Player, priorRuns: number)
	local ok, err = pcall(function()
		if priorRuns == 0 then
			inFirstRun[player] = true
		else
			inFirstRun[player] = nil
		end
		if priorRuns == 0 then
			logStep(player, Analytics.Steps.StartedFirstRun)
		elseif priorRuns == 1 then
			logEvent(player, Analytics.Events.StartedSecondRun)
		end
	end)
	if not ok then
		warn("[Analytics] OnRunStart: " .. tostring(err))
	end
end

--[[
	LevelUpSystem, when a weapon evolves (card or chest), BEFORE the evolution is recorded
	in the save's Discovered.Evolutions: an empty record means this is the account's first.
]]
function Analytics.OnEvolution(player: Player)
	local ok, err = pcall(function()
		local data = ctx.DataService.GetData(player)
		local evolutions = data and type(data.Discovered) == "table" and data.Discovered.Evolutions
		if type(evolutions) ~= "table" or next(evolutions) ~= nil or devTainted(player) then
			return
		end
		logEvent(player, Analytics.Events.FirstEvolution)
	end)
	if not ok then
		warn("[Analytics] OnEvolution: " .. tostring(err))
	end
end

-- EnemySpawner: run wave `n` was cleared (its own clear rule, not the timeout).
function Analytics.OnWaveCleared(n: number)
	if n ~= 1 then
		return
	end
	local ok, err = pcall(function()
		for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
			local player = rp.Player
			if inFirstRun[player] and rp.Alive and not rp.DevTainted then
				logEvent(player, Analytics.Events.FirstWaveCompleted)
			end
		end
	end)
	if not ok then
		warn("[Analytics] OnWaveCleared: " .. tostring(err))
	end
end

function Analytics.Init(c)
	ctx = c
	local ok, result = pcall(function()
		return game:GetService("AnalyticsService")
	end)
	if ok then
		service = result
	else
		warn("[Analytics] AnalyticsService unavailable: " .. tostring(result))
	end
end

function Analytics.Start()
	ctx.DataService.OnProfileLoaded(onProfileLoaded)
	Remotes.Listen("ClientReady", function(player)
		onClientReady(player)
	end, 1)
	Players.PlayerRemoving:Connect(function(player)
		onboarding[player] = nil
		sent[player] = nil
		inFirstRun[player] = nil
	end)
end

return Analytics
