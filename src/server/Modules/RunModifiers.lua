--[[
	RunModifiers.lua
	Curses (run modifiers) and the Daily Challenge on the server (data: CurseData.lua).

	Curses
	  Lobby: remote SetCurses({ids}) stores the player's pick (CurseData.Sanitize: known
	  ids, no duplicates, at most CurseData.MaxActive) in the save (data.Curses) and in the
	  player attribute "Curses" ("Frenzy,Horde"). Ignored while the player is in a run.
	  A run uses the curses of the player who STARTED it (Solo: you; Duo / Trio: the
	  countdown's starter, who may still change them during the countdown). They are fixed
	  when the run begins and apply to everyone in it.
	  SwarmState "Curses" / "CurseGold": the curses on show (countdown: the starter's pick;
	  running / results: the run's), "DailyRun" (the run is a Daily Challenge).
	  Effects are read through the queries below by EnemySpawner (speed, elites),
	  StageManager.SpawnMult (horde), XPSystem (no chickens), LevelUpSystem's stat sheet
	  (max HP, damage dealt / taken) and GoldSystem.AddRunGold (the gold multiplier).

	Endless (Config.Endless)
	  Lobby: remote SetEndless(boolean) stores the switch in the save (data.Endless) and the
	  player attribute "Endless". Ignored while the player is in a run. Like curses, a run
	  uses the STARTER's switch (the countdown's starter may still flip it), fixed when the
	  run begins, and only for Config.Endless.Modes (never the Daily Challenge). Every run
	  player gets rp.Endless. StageManager reads IsEndless (no RETURN at the portal, the
	  extra difficulty past LastNormalStage: EndlessStage); RunManager scores the run on
	  "ScoreEndless" instead of "Score" and never counts it as a win.
	  SwarmState "Endless": the switch on show (countdown: the starter's; running /
	  results: the run's; lobby: false).

	Daily Challenge
	  StartRun("Daily") (RunManager) starts a solo run with CurseData.Daily(today): its
	  arena tour and bosses (StageManager.BeginRun's fixed plan), its curses and its starting
	  bonus (SetupRunPlayer). The first daily run of a UTC day is the scored attempt: it is
	  marked used the moment it starts (quitting does not give a retry); later ones are
	  practice. CommitDaily scores the attempt (CurseData.DailyScore), keeps today's score
	  and the best ever in data.Daily and sends it to the Daily leaderboard.
	  SwarmState "DailyDay": today's UTC day number (the lobby card shows that day).
]]

local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CurseData = require(game:GetService("ReplicatedStorage").Shared.CurseData)
local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)
local ItemData = require(game:GetService("ReplicatedStorage").Shared.ItemData)

local RunModifiers = {}

local ctx
local state: Configuration
local active: { string } = {} -- curses of the running run
local effects = CurseData.Effects({})
local goldMult = 1
local daily: CurseData.Daily? = nil -- the running run's daily setup (nil = not a daily)
local endless = false -- the running run is an Endless run (Config.Endless)
local publishTimer = 0

------------------------------------------------------------------------------------------
-- Queries (gameplay hooks)
------------------------------------------------------------------------------------------

function RunModifiers.Active(): { string }
	return active
end

function RunModifiers.GoldMult(): number
	return goldMult
end

function RunModifiers.EnemySpeedMult(): number
	return effects.EnemySpeed
end

function RunModifiers.SpawnMult(): number
	return effects.SpawnMult
end

function RunModifiers.EliteChanceMult(): number
	return effects.EliteChance
end

function RunModifiers.NoHealPickups(): boolean
	return effects.NoHealPickups
end

-- Final multipliers for the stat sheet (StatSheet.Compute input.Curse).
function RunModifiers.StatMults(): { [string]: number }?
	if #active == 0 then
		return nil
	end
	return { MaxHP = effects.MaxHP, Might = effects.Might, DamageTaken = effects.DamageTaken }
end

function RunModifiers.IsDaily(): boolean
	return daily ~= nil
end

function RunModifiers.IsEndless(): boolean
	return endless
end

-- Stages past Config.Endless.LastNormalStage that add Endless difficulty (0 in Standard
-- runs and before that stage; at most MaxExtraStages).
function RunModifiers.EndlessStage(stage: number): number
	if not endless then
		return 0
	end
	local E = Config.Endless
	return math.clamp(stage - E.LastNormalStage, 0, E.MaxExtraStages)
end

-- True when a run of `modeName` started by a player whose save says `wanted` is Endless.
local function endlessFor(modeName: string, wanted: any): boolean
	return Config.Endless.Enabled == true and wanted == true and table.find(Config.Endless.Modes, modeName) ~= nil
end

function RunModifiers.Today(): number
	return CurseData.DayOf(os.time())
end

------------------------------------------------------------------------------------------
-- Run lifecycle (RunManager)
------------------------------------------------------------------------------------------

local function setActive(list: { string })
	active = table.clone(list)
	effects = CurseData.Effects(active)
	goldMult = CurseData.GoldMult(active)
end

--[[
	A run is starting. modeName "Daily" uses today's daily setup; any other mode the
	starter's saved curses. Returns the daily setup (fixed arena / boss plan) or nil.
]]
function RunModifiers.BeginRun(modeName: string, starter: Player?): CurseData.Daily?
	if modeName == CurseData.DailyMode then
		daily = CurseData.Daily(RunModifiers.Today())
		setActive((daily :: CurseData.Daily).Curses)
		endless = false
	else
		daily = nil
		local data = starter and ctx.DataService.GetData(starter)
		setActive(data and CurseData.Sanitize(data.Curses) or {})
		endless = endlessFor(modeName, data and data.Endless)
	end
	RunModifiers.Publish()
	return daily
end

function RunModifiers.EndRun()
	setActive({})
	daily = nil
	endless = false
	RunModifiers.Publish()
end

-- Daily: the scored attempt (first daily run of the UTC day) or practice, and the
-- starting bonus. Called once per run player after the start weapon is set.
function RunModifiers.SetupRunPlayer(rp)
	rp.Endless = endless
	local d = daily
	if not d then
		return
	end
	rp.Daily = true
	rp.DailyDay = d.Day
	local data = ctx.DataService.GetData(rp.Player)
	if data then
		local D = data.Daily
		if D.Day ~= d.Day then
			D.Day = d.Day
			D.Used = false
			D.Score = 0
			D.Plays = 0
		end
		D.Plays += 1
		rp.DailyScored = not D.Used
		D.Used = true -- the scored attempt is spent the moment it starts
		task.spawn(ctx.DataService.ForceSave, rp.Player)
	end
	-- the starting bonus (run only, the same for everyone today)
	if d.Bonus == "Armory" then
		local id = d.BonusWeapon
		if id and rp.Weapons[id] then
			-- the hero already starts with it: the next weapon of the pool instead
			local list = CurseData.ArmoryWeapons
			local i = table.find(list, id) or 0
			id = list[(i % #list) + 1]
		end
		if id and WeaponData.Weapons[id] then
			ctx.LevelUpSystem.AddWeapon(rp, id)
		end
	elseif d.Bonus == "Treasure" then
		for _, id in ipairs(d.BonusItems or {}) do
			if ItemData.Items[id] then
				ctx.ItemSystem.Grant(rp, id, "Daily bonus")
			end
		end
	elseif d.Bonus == "SecondWind" then
		rp.RevivesLeft += 1
	end
end

-- After the run player is fully set up: the level bonus (its cards follow at once).
function RunModifiers.AfterSetup(rp)
	local d = daily
	if d and d.Bonus == "HeadStart" then
		for _ = 2, CurseData.HeadStartLevel do
			ctx.XPSystem.GiveXP(rp, math.max(0, rp.XPNeeded - rp.XP))
		end
	end
end

--[[
	Scores a daily run (once, from RunManager's commit). cleared = stages cleared,
	clearTime = run time when the last of them was cleared, survived = run time survived.
	Returns the results line data: { Scored, Score, Text, Best, NewBest, Practice }.
]]
function RunModifiers.CommitDaily(rp, cleared: number, clearTime: number, survived: number): { [string]: any }?
	if not rp.Daily then
		return nil
	end
	local score = CurseData.DailyScore(cleared, clearTime, survived)
	local info: { [string]: any } = {
		Scored = rp.DailyScored == true,
		Score = score,
		Text = CurseData.ScoreText(score),
		Day = rp.DailyDay,
	}
	local data = ctx.DataService.GetData(rp.Player)
	if data and rp.DailyScored then
		local D = data.Daily
		if D.Day == rp.DailyDay then
			D.Score = math.max(D.Score or 0, score)
		end
		if score > (D.BestScore or 0) then
			D.BestScore = score
			D.BestDay = rp.DailyDay
			info.NewBest = true
		end
		info.Best = D.BestScore
		if ctx.LeaderboardService then
			ctx.LeaderboardService.Submit(rp.Player, "Daily", score, rp.DailyDay, rp.RunId)
		end
	end
	return info
end

-- Profile view of the daily (lobby DAILY card / screen).
function RunModifiers.DailyView(data): { [string]: any }
	local D = data.Daily or {}
	local today = RunModifiers.Today()
	local isToday = D.Day == today
	return {
		Day = today,
		Used = isToday and D.Used == true,
		Score = isToday and (D.Score or 0) or 0,
		Plays = isToday and (D.Plays or 0) or 0,
		BestScore = D.BestScore or 0,
		BestDay = D.BestDay or 0,
	}
end

------------------------------------------------------------------------------------------
-- Lobby: picking curses
------------------------------------------------------------------------------------------

local function onSetCurses(player: Player, list: any)
	local data = ctx.DataService.GetData(player)
	if not data or ctx.RunManager.IsParticipant(player) then
		return
	end
	local clean = CurseData.Sanitize(list)
	if not clean then
		return
	end
	data.Curses = clean
	player:SetAttribute("Curses", CurseData.ToString(clean))
	RunModifiers.Publish()
end

local function onSetEndless(player: Player, on: any)
	local data = ctx.DataService.GetData(player)
	if type(on) ~= "boolean" or not data or ctx.RunManager.IsParticipant(player) then
		return
	end
	data.Endless = on and Config.Endless.Enabled == true
	player:SetAttribute("Endless", data.Endless)
	RunModifiers.Publish()
end

-- SwarmState: the curses and Endless switch on show and today's daily day.
function RunModifiers.Publish()
	if not state then
		return
	end
	local phase = state:GetAttribute("Phase")
	local list: { string } = {}
	local endlessShown = false
	if phase == "Running" or phase == "Results" then
		list = active
		endlessShown = endless
	elseif phase == "Countdown" then
		local starter = ctx.RunManager.GetStarter and ctx.RunManager.GetStarter()
		local data = starter and ctx.DataService.GetData(starter)
		list = data and CurseData.Sanitize(data.Curses) or {}
		endlessShown = data ~= nil and endlessFor(tostring(state:GetAttribute("Mode")), data.Endless)
	end
	if state:GetAttribute("Endless") ~= endlessShown then
		state:SetAttribute("Endless", endlessShown)
	end
	local s = CurseData.ToString(list)
	if state:GetAttribute("Curses") ~= s then
		state:SetAttribute("Curses", s)
	end
	state:SetAttribute("CurseGold", CurseData.GoldMult(list))
	state:SetAttribute("DailyRun", (phase == "Running" or phase == "Results") and daily ~= nil)
	state:SetAttribute("DailyDay", RunModifiers.Today())
end

function RunModifiers.Step(dt: number)
	publishTimer += dt
	if publishTimer >= 0.5 then
		publishTimer = 0
		RunModifiers.Publish()
	end
end

function RunModifiers.Init(c)
	ctx = c
	state = Remotes.State()
	state:SetAttribute("Curses", "")
	state:SetAttribute("CurseGold", 1)
	state:SetAttribute("DailyRun", false)
	state:SetAttribute("DailyDay", RunModifiers.Today())
	state:SetAttribute("CurseMax", CurseData.MaxActive)
	state:SetAttribute("Endless", false)
	assert(Config.Data.SchemaVersion >= 6, "RunModifiers needs save schema 6")
end

function RunModifiers.Start()
	Remotes.Listen("SetCurses", onSetCurses, 6)
	Remotes.Listen("SetEndless", onSetEndless, 6)
	ctx.DataService.OnProfileLoaded(function(player)
		local data = ctx.DataService.GetData(player)
		if data then
			player:SetAttribute("Curses", CurseData.ToString(CurseData.Sanitize(data.Curses) or {}))
			player:SetAttribute("Endless", data.Endless == true and Config.Endless.Enabled == true)
		end
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(RunModifiers.Publish)
	end)
end

return RunModifiers
