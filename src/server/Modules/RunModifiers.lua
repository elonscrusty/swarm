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

	Stage modifiers (batch B, Config.Features.StageModifiers, Config.StageModifiers;
	docs/next/STAGE_MODIFIERS.md)
	  BeginRun picks the run seed (Daily / Weekly: their fixed seed, so everyone gets the same
	  list; otherwise a random one). StageModifierFor(stage) = StageModifierData.Roll(seed,
	  stage). The modifier is live while its stage runs (StageModifier: not during the travel,
	  not outside Running) and works through the existing hooks: EnemySpeedMult / SpawnMult /
	  EliteChanceMult and StatMults here (capped against the same curse effect,
	  Config.StageModifiers.Caps), StageMod(key) for StageManager (EnemyHP, EnemyDamage),
	  XPSystem (XP), GoldSystem (KillGold), StageModCount("ChestRolls") for the elite chest, and
	  LootSystem asks StageModifierFor while placing small chests. When it changes, every run
	  player's stat sheet is recomputed (Step). SwarmState "StageModifier": the id on show.
]]

local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CurseData = require(game:GetService("ReplicatedStorage").Shared.CurseData)
local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)
local ItemData = require(game:GetService("ReplicatedStorage").Shared.ItemData)
local DifficultyData = require(game:GetService("ReplicatedStorage").Shared.DifficultyData)
local MetaData = require(game:GetService("ReplicatedStorage").Shared.MetaData)
local StageModifierData = require(game:GetService("ReplicatedStorage").Shared.StageModifierData)

local RunModifiers = {}

local ctx
local state: Configuration
local active: { string } = {} -- curses of the running run
local effects = CurseData.Effects({})
local goldMult = 1
local daily: CurseData.Daily? = nil -- the running run's daily setup (nil = not a daily)
local weekly: MetaData.Weekly? = nil -- the running run's Weekly Challenge setup (META, feature 21)
local endless = false -- the running run is an Endless run (Config.Endless)
local difficulty = "Standard"
local publishTimer = 0
-- stage modifiers (Config.StageModifiers, docs/next/STAGE_MODIFIERS.md)
local runSeed: number? = nil -- the running run's seed (Daily / Weekly: their fixed seed)
local modCache: { [number]: string | false } = {} -- stage -> rolled id (false = none)
local appliedMod: string? = nil -- the modifier the stat sheets were last computed with
local seedRng: Random? = nil -- own Random, made on first use (switch on): the game's other rolls are untouched

------------------------------------------------------------------------------------------
-- Queries (gameplay hooks)
------------------------------------------------------------------------------------------

function RunModifiers.Active(): { string }
	return active
end

function RunModifiers.GoldMult(): number
	return goldMult * RunModifiers.DifficultyMultiplier("Gold")
end

function RunModifiers.DifficultyId(): string
	return difficulty
end

function RunModifiers.DifficultyMultiplier(stat: string): number
	local value = DifficultyData.Tiers[difficulty][stat]
	return type(value) == "number" and value or 1
end

------------------------------------------------------------------------------------------
-- Stage modifiers (Config.Features.StageModifiers; docs/next/STAGE_MODIFIERS.md)
------------------------------------------------------------------------------------------

-- The running run's seed (nil between runs).
function RunModifiers.RunSeed(): number?
	return runSeed
end

-- The modifier stage `stage` of this run rolls (nil: switch off, no run, before FromStage).
-- Pure on the run seed, so LootSystem can ask while the stage is being built.
function RunModifiers.StageModifierFor(stage: number): string?
	if not Config.FeatureOn("StageModifiers") or runSeed == nil or type(stage) ~= "number" then
		return nil
	end
	local cached = modCache[stage]
	if cached == nil then
		cached = StageModifierData.Roll(runSeed, stage) or false
		modCache[stage] = cached
	end
	return cached or nil
end

-- The modifier in force now: the live stage's, cleared during the travel (stage end) and
-- outside a running run.
function RunModifiers.StageModifier(): string?
	local sm = ctx and ctx.StageManager
	if not sm or not state or state:GetAttribute("Phase") ~= "Running" then
		return nil
	end
	local stage = sm.GetStage()
	if stage <= 0 or sm.GetPhase() == "Travel" then
		return nil
	end
	return RunModifiers.StageModifierFor(stage)
end

-- The live modifier's multiplier for effect `key` (1 = none).
function RunModifiers.StageMod(key: string): number
	local id = RunModifiers.StageModifier()
	if not id then
		return 1
	end
	return StageModifierData.Effects(id)[key] or 1
end

-- The live modifier's count for effect `key` (ChestRolls; 0 = none).
function RunModifiers.StageModCount(key: string): number
	local id = RunModifiers.StageModifier()
	if not id then
		return 0
	end
	return StageModifierData.Effects(id)[key] or 0
end

local function capOf(key: string): number?
	return (Config :: any).StageModifiers.Caps[key]
end

function RunModifiers.EnemySpeedMult(): number
	return StageModifierData.Combine(effects.EnemySpeed, RunModifiers.StageMod("EnemySpeed"), capOf("EnemySpeed")) * RunModifiers.DifficultyMultiplier("Speed")
end

function RunModifiers.SpawnMult(): number
	return StageModifierData.Combine(effects.SpawnMult, RunModifiers.StageMod("SpawnMult"), capOf("SpawnMult")) * RunModifiers.DifficultyMultiplier("Density")
end

function RunModifiers.EliteChanceMult(): number
	return StageModifierData.Combine(effects.EliteChance, RunModifiers.StageMod("EliteChance"), capOf("EliteChance"))
end

function RunModifiers.NoHealPickups(): boolean
	return effects.NoHealPickups
end

-- Final multipliers for the stat sheet (StatSheet.Compute input.Curse): the curses, with the
-- live stage modifier's stat effects (capped against the same curse effect).
function RunModifiers.StatMults(): { [string]: number }?
	local id = RunModifiers.StageModifier()
	if #active == 0 and not id then
		return nil
	end
	local m = StageModifierData.Effects(id)
	return {
		MaxHP = effects.MaxHP,
		Might = StageModifierData.Combine(effects.Might, m.Might, capOf("Might")),
		DamageTaken = StageModifierData.Combine(effects.DamageTaken, m.DamageTaken, capOf("DamageTaken")),
		Speed = m.Speed,
		CooldownMult = m.CooldownMult,
		GoldMult = m.Gold,
	}
end

function RunModifiers.IsDaily(): boolean
	return daily ~= nil
end

-- The Weekly Challenge (META, MetaData.Weekly): the running run's setup, or nil.
function RunModifiers.Weekly(): MetaData.Weekly?
	return weekly
end

-- The weekly's first world (RunManager.beginRun), or nil when the run is not a weekly.
function RunModifiers.WeeklyArena(): string?
	return weekly and weekly.Arena or nil
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
	difficulty = "Standard"
	weekly = nil
	table.clear(modCache)
	appliedMod = nil
	if modeName == CurseData.DailyMode then
		daily = CurseData.Daily(RunModifiers.Today())
		setActive((daily :: CurseData.Daily).Curses)
		endless = false
		runSeed = (daily :: CurseData.Daily).Seed -- everyone gets today's stage modifiers
	elseif modeName == MetaData.WeeklyMode and Config.FeatureOn("WeeklyChallenge") then
		-- the week's fixed curses (the starter's own pick is ignored), Standard, no Endless
		daily = nil
		weekly = MetaData.Weekly(MetaData.WeekOf(os.time()))
		setActive((weekly :: MetaData.Weekly).Curses)
		endless = false
		runSeed = (weekly :: MetaData.Weekly).Seed
	else
		daily = nil
		local data = starter and ctx.DataService.GetData(starter)
		difficulty = DifficultyData.Selected(data)
		setActive(data and CurseData.Sanitize(data.Curses) or {})
		endless = endlessFor(modeName, data and data.Endless)
		if Config.FeatureOn("StageModifiers") then
			seedRng = seedRng or Random.new()
			runSeed = (seedRng :: Random):NextInteger(1, 2147483646)
		end
	end
	RunModifiers.Publish()
	return daily
end

function RunModifiers.EndRun()
	setActive({})
	daily = nil
	weekly = nil
	endless = false
	difficulty = "Standard"
	runSeed = nil
	table.clear(modCache)
	appliedMod = nil
	RunModifiers.Publish()
end

-- Daily: the scored attempt (first daily run of the UTC day) or practice, and the
-- starting bonus. Called once per run player after the start weapon is set.
function RunModifiers.SetupRunPlayer(rp)
	rp.Endless = endless
	rp.Difficulty = difficulty
	if weekly then
		rp.Weekly = true
		rp.WeeklyWeek = (weekly :: MetaData.Weekly).Week
	end
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

-- Completion is additive: historical stats and existing challenge hero unlocks stay intact.
function RunModifiers.CompleteDifficulty(player: Player, cleared: number, won: boolean)
	local rp = ctx.RunManager.GetRunPlayer(player)
	if not won or cleared < Config.Stages.WinMinStages or not rp or rp.DevTainted or rp.Daily or rp.Endless then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	local id = rp.Difficulty or difficulty
	if not DifficultyData.Tiers[id] then
		return
	end
	data.DifficultyClears = data.DifficultyClears or {}
	if data.DifficultyClears[id] then
		return
	end
	data.DifficultyClears[id] = true
	local hero = id == "Veteran" and "Engineer" or id == "Nightmare" and "Necromancer" or nil
	if hero then
		data.OwnedCharacters = data.OwnedCharacters or {}
		if not data.OwnedCharacters[hero] then
			data.OwnedCharacters[hero] = true
			ctx.RunManager.Notify(player, hero .. " unlocked!", Color3.fromRGB(120, 255, 160))
		end
	end
	local index = table.find(DifficultyData.Order, id)
	local nextId = index and DifficultyData.Order[index + 1]
	if nextId then
		ctx.RunManager.Notify(player, nextId .. " difficulty unlocked!", Color3.fromRGB(255, 210, 80))
	end
	ctx.GoldSystem.SyncProfile(player)
end

local function onSetDifficulty(player: Player, id: any)
	local data = ctx.DataService.GetData(player)
	if type(id) ~= "string" or not data or ctx.RunManager.IsParticipant(player) then
		return
	end
	if not DifficultyData.IsUnlocked(data, id) then
		ctx.RunManager.Notify(player, "Clear the previous difficulty to unlock this one.", Color3.fromRGB(255, 210, 80))
		return
	end
	data.Difficulty = id
	player:SetAttribute("Difficulty", id)
	ctx.GoldSystem.SyncProfile(player)
	RunModifiers.Publish()
end

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
	local difficultyShown = "Standard"
	if phase == "Running" or phase == "Results" then
		list = active
		endlessShown = endless
		difficultyShown = difficulty
	elseif phase == "Countdown" then
		local starter = ctx.RunManager.GetStarter and ctx.RunManager.GetStarter()
		local data = starter and ctx.DataService.GetData(starter)
		list = data and CurseData.Sanitize(data.Curses) or {}
		endlessShown = data ~= nil and endlessFor(tostring(state:GetAttribute("Mode")), data.Endless)
		difficultyShown = DifficultyData.Selected(data)
	end
	state:SetAttribute("Difficulty", difficultyShown)
	if state:GetAttribute("Endless") ~= endlessShown then
		state:SetAttribute("Endless", endlessShown)
	end
	local s = CurseData.ToString(list)
	if state:GetAttribute("Curses") ~= s then
		state:SetAttribute("Curses", s)
	end
	state:SetAttribute("CurseGold", CurseData.GoldMult(list))
	state:SetAttribute("DailyRun", (phase == "Running" or phase == "Results") and daily ~= nil)
	state:SetAttribute("WeeklyRun", (phase == "Running" or phase == "Results") and weekly ~= nil)
	state:SetAttribute("DailyDay", RunModifiers.Today())
	-- the stage modifier on show: the current stage's ("" = none; also during its travel,
	-- so the next stage card can name it); the HUD badge and RunIntro read it
	local shownMod = ""
	if phase == "Running" and ctx.StageManager then
		shownMod = RunModifiers.StageModifierFor(ctx.StageManager.GetStage()) or ""
	end
	if state:GetAttribute("StageModifier") ~= shownMod then
		state:SetAttribute("StageModifier", shownMod)
	end
end

-- The live stage modifier changed (a new stage, its travel, the run's end): every run
-- player's stat sheet follows at once (Glass Arena, Haste, Thick Hides gold).
local function followStageModifier()
	local id = RunModifiers.StageModifier()
	if id == appliedMod then
		return
	end
	appliedMod = id
	if ctx.RunManager and ctx.LevelUpSystem then
		for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
			if rp.Stats then
				ctx.LevelUpSystem.RecomputeStats(rp)
			end
		end
	end
	RunModifiers.Publish()
end

function RunModifiers.Step(dt: number)
	followStageModifier()
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
	state:SetAttribute("Difficulty", "Standard")
	state:SetAttribute("StageModifier", "")
	assert(Config.Data.SchemaVersion >= 6, "RunModifiers needs save schema 6")
end

function RunModifiers.Start()
	Remotes.Listen("SetCurses", onSetCurses, 6)
	Remotes.Listen("SetEndless", onSetEndless, 6)
	Remotes.Listen("SetDifficulty", onSetDifficulty, 4)
	ctx.DataService.OnProfileLoaded(function(player)
		local data = ctx.DataService.GetData(player)
		if data then
			player:SetAttribute("Curses", CurseData.ToString(CurseData.Sanitize(data.Curses) or {}))
			player:SetAttribute("Endless", data.Endless == true and Config.Endless.Enabled == true)
			player:SetAttribute("Difficulty", DifficultyData.Selected(data))
		end
	end)
	Players.PlayerRemoving:Connect(function()
		task.defer(RunModifiers.Publish)
	end)
end

return RunModifiers
