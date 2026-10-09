--[[
	StageManager.lua
	The Risk of Rain style stage loop inside a run (Config.Stages). RunManager owns the
	run itself (players, lives, results); this module owns what happens on each stage:

	  Explore  the arena of this stage with a PORTAL at a random clear spot. The swarm
	           comes in numbered waves (Config.Waves, EnemySpawner stepWaves; the old
	           mini-waves only with Config.Waves.Enabled = false). The portal is
	           dormant for PortalLockSeconds; when the lock ends (and the stage banner has
	           gone: RevealDelaySeconds) it is REVEALED (PortalHint / PortalReveal: the HUD
	           arrow, banner, beacon and minimap ping) and any living player standing in
	           its rune circle charges it (ChargeSeconds; never before the reveal). The
	           tutorial run (RunManager.TutorialRevealHold) reveals the stage-1 portal
	           only after the first level-up card is picked (or at
	           Config.FirstRun.RevealCapSeconds).
	  Boss     charging summons the stage's boss behind the portal (stage 1: the Scorpion
	           Queen; later stages rotate the Queen, Moth Matriarch, Rhino Warlord and Hive
	           Mother, never the same one twice in a row: bossFor); HP scaled by stage and
	           player count; regular spawning follows the boss-phase rules.
	  Surge    the boss died: SurgeBase + SurgePerStage x stage enemies pour out; survive
	           SurgeSeconds or kill most of them.
	  Open     the leftovers die, the gems fly to the players and every living player
	           chooses NEXT STAGE or RETURN TO LOBBY (remote "PortalChoice"). Returning
	           ends that player's run (RunManager.ReturnThroughPortal; a win from
	           WinMinStages cleared stages, the gold bonus always). When all
	           living players chose (or ChoiceSeconds ran out: undecided = next stage) the
	           rest travel; if nobody is left to go on, the run ends cleanly.
	  Travel   fade, new arena (a shuffled biome tour, see arenaFor), enemies, gems
	           and projectiles cleared, players moved to the new spawn, healed, fallen
	           teammates revived (RunManager.TravelPlayers). Nothing simulates meanwhile.

	Difficulty keeps scaling with TOTAL run time (RunManager.GetTier / the spawn table) and
	this module adds per-stage multipliers (EnemyHPMult, DamageMult, SpawnMult, BossHPMult);
	stage 1 multiplies by exactly 1, so the early game plays as before.

	Endless runs (Config.Endless, RunModifiers.IsEndless): the open portal offers NEXT
	STAGE only (a "Return" choice is refused; the panel gets Endless = true), so the run
	ends only when everyone falls or leaves through the pause menu. Arenas and bosses keep
	rotating (arenaFor / bossFor grow without end). Past Config.Endless.LastNormalStage
	the four multipliers grow further (endlessMult; bounded by MaxExtraStages, spawns by
	SpawnMultCap and Config.Enemies.MaxLive). Standard runs are unchanged.

	[stream D] DIRECTOR RUN (docs/redesign/DECISIONS.md C5; RunConfig.Director): a run on the single
	map (RunConfig.Map.MapName, Cliffwood) with Director.LegacyStages off is ONE 15-minute run instead
	of the loop above. No portal, no next-stage choice, no travel. RunStage (SwarmState) goes
	  Survive -> BeaconAvailable (12:30, the beacon is revealed at the Stone Circle, Beacon.lua)
	  -> Rally (a living, non-downed hero lit it; RallySeconds) -> Charge (BeaconCharge fills while a
	  hero stands inside ChargeRadius; pauses outside, never goes back) -> Boss (the Basin Breaker,
	  spawned exactly once at 100%) -> Victory (its death, once) | Defeat (a full wipe, once).
	The director clock (RunClock) runs with the simulation (x Director.TimeScale in Studio tests);
	past RunMinutes only the spawn rate ramps up (overtime, SwarmState Overtime). Party size N
	(PartyN) starts at the heroes in the run and only grows (late admissions: OnPlayerAdmitted).
	Victory locks the terminal state at once: ordinary enemies and hazards are cleared without
	rewards, open upgrade offers are cancelled, the boss XP is banked and RunManager.EndRun(true) follows;
	a later wipe can no longer turn it into a defeat (RunManager.EndRun checks Terminal()).
	StagePhase stays "Explore" until the boss ("Boss"), so the encounter / loot systems work as on
	stage 1; GetStage() is 1 (WinMinStages after a victory, so the win and its bonuses settle as a
	full expedition did). Other arenas (and LegacyStages = true) keep the stage loop above.
	SwarmState (director): RunStage, RunClock, BeaconPos, BeaconCharge, RallyLeft, Overtime;
	BossHP / BossMaxHP / BossName come from EnemySpawner / BossAI as for every boss.

	SwarmState attributes (client HUD): Stage, StagePhase, StageArena, StageBoss, PortalPos,
	PortalHint, SwarmWarn (0-2, Config.Stages.Pressure), PortalCharge, PortalLockLeft, SurgeLeft, ChoiceLeft, ChoiceLeftHeld (group: the countdown waits for an open upgrade choice), PortalReady ("ready/total"),
	PortalReveal (counts up each time a stage's portal becomes chargeable: the clients'
	cue for the banner, sound, beacon burst and minimap ping; see Config.Stages.RevealDelaySeconds).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local MapBuilder = require(script.Parent.MapBuilder)
local Fx = require(script.Parent.Fx)
local Events = require(script.Parent.Events)
local BiomeHazards = require(script.Parent.BiomeHazards)
local EncounterDirector = require(script.Parent.EncounterDirector)
local BossData = require(game:GetService("ReplicatedStorage").Shared.BossData)
local HeightGrid = require(script.Parent.HeightGrid)

local StageManager = {}

-- Single-map settings (src/swarmv2/shared/Run/RunConfig.lua, Map section). Safe defaults when the
-- module is not in the tree.
local MapCfg: { [string]: any } = { MapName = "Cliffwood", SingleMap = true, BossLandmark = "Stone Circle", TransitionSeconds = 0.7, PortalLandmarkMargin = 14, BossEvery = 5 }
do
	local folder = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmV2")
	local run = folder and folder:FindFirstChild("Run")
	local mod = run and run:FindFirstChild("RunConfig")
	if mod and mod:IsA("ModuleScript") then
		local ok, cfg = pcall(require, mod)
		if ok and type(cfg) == "table" and type(cfg.Map) == "table" then
			for k, v in pairs(cfg.Map) do
				MapCfg[k] = v
			end
		end
	end
end

-- [stream D] the run director's settings (RunConfig.Director) and the beacon (SwarmV2.Run.Beacon)
local DirCfg: { [string]: any } = {}
local RunCfgAll: { [string]: any } = {}
do
	local folder = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmV2")
	local run = folder and folder:FindFirstChild("Run")
	local mod = run and run:FindFirstChild("RunConfig")
	if mod and mod:IsA("ModuleScript") then
		local ok, cfg = pcall(require, mod)
		if ok and type(cfg) == "table" then
			RunCfgAll = cfg
			if type(cfg.Director) == "table" then
				DirCfg = cfg.Director
			end
		end
	end
end
local Beacon: any = nil

local ctx
local state: Configuration
local rng = Random.new()
local FLAT = Vector3.new(1, 0, 1)

local stage = 0
local sub = "None" -- "None" | "Explore" | "Boss" | "Surge" | "Open" | "Travel"
local firstArena = "Forest"
local arenaName = "Forest"
local portal: MapBuilder.Portal? = nil
local lastPortal: { [string]: Vector3 } = {} -- last portal spot per arena (a new one differs)
local stageTime = 0
local revealed = false -- this stage's portal reveal happened (PortalReveal bumped)
local revealAt = 0 -- stageTime of this stage's reveal (swarm pressure counts from it)
local holdReleasedAt: number? = nil -- stageTime the tutorial reveal hold ended (nil = not yet)
local tutorialHeld = false -- this stage's reveal waited for the tutorial's first pick
local swarmWarn = 0 -- Config.Stages.Pressure step shown (SwarmState SwarmWarn)
local reveals = 0
local shownLock = -1
local charge = 0
local shownCharge = -1
local miniWaveTimer = 0
local surgeTotal = 0
local surgeQueued = 0
local surgeBudget = 0
local surgeTimer = 0
local choiceLeft = 0
local shownChoice = -1
local choiceHeld = 0 -- seconds this stage-clear countdown already waited for upgrade choices
local shownHeld: boolean? = nil
local travelStep = ""
local travelTimer = 0
-- Single-map run (every stage on one arena, see buildStage): the arena, the portal's extra
-- nodes and the stage-only colliders to drop at the next stage.
local singleMode = false
local mapArena: any = nil
local lastLandmark: string? = nil
local landmarkBag: { string } = {}
local portalNodes: { Instance } = {}
local stageBase: { Obstacles: number, Keepout: number, Colliders: { [Instance]: boolean } }? = nil
local lastClearTime = 0 -- run time when the last stage boss died (Daily Challenge score)
-- [stream D] director run state (see the header)
local directorOn = false
local runStage: string? = nil -- SwarmState RunStage
local dClock = 0 -- director seconds
local shownClock = -1
local partyN = 0 -- 0 = not counted yet (the first director step counts the run's heroes)
local terminal: string? = nil -- "Victory" | "Defeat" once the run's outcome is locked
local bossSpawned = false
local overtimeShown = false
local timeScale = 1 -- Studio tests only (SetTimeScale / Director.TimeScale)

------------------------------------------------------------------------------------------
-- Queries
------------------------------------------------------------------------------------------

function StageManager.GetStage(): number
	if directorOn and terminal == "Victory" then
		return Config.Stages.WinMinStages -- a won director run settles as a full expedition
	end
	return stage
end

function StageManager.GetPhase(): string
	return sub
end

-- Stages whose Queen is dead (the current one counts once the surge started).
function StageManager.StagesCleared(): number
	if directorOn then
		return terminal == "Victory" and Config.Stages.WinMinStages or 0
	end
	if sub == "Surge" or sub == "Open" or sub == "Travel" then
		return stage
	end
	return math.max(0, stage - 1)
end

-- Display name of the current stage's arena.
function StageManager.ArenaDisplayName(): string
	local def = (Config.Arenas :: any)[arenaName]
	return def and def.DisplayName or arenaName
end

-- Travel: nothing moves, nobody can be hurt, the timer stops.
-- [stream D] Also a director run's locked outcome (the victory frame, until RunManager.EndRun):
-- the boss XP banked then opens no upgrade panel (LevelUpSystem waits while holding).
function StageManager.IsHolding(): boolean
	return sub == "Travel" or (directorOn and terminal ~= nil)
end

-- Regular top-up spawning runs while exploring and during the boss fight (boss rules).
function StageManager.AllowSpawning(): boolean
	if directorOn then
		return false -- the director spawns on its own clock (EnemySpawner stepDirector)
	end
	return sub == "Explore" or sub == "Boss"
end

function StageManager.IsBossFight(): boolean
	return sub == "Boss"
end

function StageManager.PortalPosition(): Vector3?
	return portal and portal.Pos or nil
end

local function perStage(k: number): number
	return 1 + k * math.max(0, stage - 1)
end

-- Endless: x(1 + k * extra stages past Config.Endless.LastNormalStage), at most cap
-- (1 in Standard runs and up to that stage).
local function endlessMult(k: number, cap: number?): number
	local extra = ctx.RunModifiers and ctx.RunModifiers.EndlessStage(stage) or 0
	return math.min(1 + k * extra, cap or math.huge)
end

function StageManager.EnemyHPMult(): number
	local tier = ctx.RunModifiers and ctx.RunModifiers.DifficultyMultiplier and ctx.RunModifiers.DifficultyMultiplier("HP") or 1
	-- x the stage modifier (Thick Hides; 1 otherwise, docs/next/STAGE_MODIFIERS.md)
	local mod = ctx.RunModifiers and ctx.RunModifiers.StageMod and ctx.RunModifiers.StageMod("EnemyHP") or 1
	return perStage(Config.Stages.EnemyHPPerStage) * endlessMult(Config.Endless.HPPerStage) * tier * mod
end

function StageManager.DamageMult(): number
	local tier = ctx.RunModifiers and ctx.RunModifiers.DifficultyMultiplier and ctx.RunModifiers.DifficultyMultiplier("Damage") or 1
	local mod = ctx.RunModifiers and ctx.RunModifiers.StageMod and ctx.RunModifiers.StageMod("EnemyDamage") or 1 -- Bounty
	return perStage(Config.Stages.EnemyDamagePerStage) * endlessMult(Config.Endless.DamagePerStage) * tier * mod
end

-- Live-target / mini-wave multiplier: the stage share x the Horde curse (x Endless).
function StageManager.SpawnMult(): number
	return perStage(Config.Stages.SpawnTargetPerStage) * endlessMult(Config.Endless.SpawnPerStage, Config.Endless.SpawnMultCap) * (ctx.RunModifiers and ctx.RunModifiers.SpawnMult() or 1)
end

function StageManager.IsEndless(): boolean
	return ctx.RunModifiers ~= nil and ctx.RunModifiers.IsEndless()
end

-- Seconds of this stage before the portal can be charged (Config.Stages.PortalLockSeconds).
local function lockSeconds(): number
	local list = Config.Stages.PortalLockSeconds
	return list[math.clamp(stage, 1, #list)] or 0
end

function StageManager.BossHPMult(): number
	local list = Config.Stages.BossHPByStage
	local s = math.max(1, stage)
	local tier = ctx.RunModifiers and ctx.RunModifiers.DifficultyMultiplier and ctx.RunModifiers.DifficultyMultiplier("HP") or 1
	if s <= #list then
		return list[s] * tier
	end
	return (list[#list] + (s - #list) * Config.Stages.BossHPPerExtraStage) * endlessMult(Config.Endless.BossHPPerStage) * tier
end

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function setSub(newSub: string)
	sub = newSub
	state:SetAttribute("StagePhase", newSub)
end

--[[
	Arena of stage n: the lobby's choice first, then a tour of Config.Arenas.Rotation
	(without the first arena; shuffled per run when ShuffleRotation), then reshuffled
	tours of every arena in Config.Arenas.Order. Never the same arena twice in a row.
	The plan grows on demand, so the NEXT STAGE panel and the travel agree.
]]
local plan: { string } = {}

local function known(name: string): boolean
	return (Config.Arenas :: any)[name] ~= nil
end

local function extendPlan(n: number)
	local A = Config.Arenas :: any
	while #plan < n do
		local bag: { string } = {}
		local source = (#plan <= 1 and A.Rotation) or A.Order
		for _, name in ipairs(source or A.Order) do
			if known(name) and not (#plan <= 1 and name == plan[1]) then
				table.insert(bag, name)
			end
		end
		if #bag == 0 then
			for _, name in ipairs(A.Order) do
				table.insert(bag, name)
			end
		end
		if A.ShuffleRotation then
			for i = #bag, 2, -1 do
				local j = rng:NextInteger(1, i)
				bag[i], bag[j] = bag[j], bag[i]
			end
		end
		if #bag > 1 and bag[1] == plan[#plan] then
			bag[1], bag[2] = bag[2], bag[1]
		end
		for _, name in ipairs(bag) do
			table.insert(plan, name)
		end
	end
end

local function arenaFor(n: number): string
	if singleMode and plan[1] then
		return plan[1]
	end
	if #plan == 0 then
		plan = { known(firstArena) and firstArena or "Forest" }
	end
	extendPlan(n)
	return plan[n]
end

--[[
	Boss of stage n: Config.Boss.First on stage 1, then BossData.Rotation as shuffled bags
	(every boss once before any repeats), never the same boss on two stages in a row.
	Like the arena plan it grows on demand, so the NEXT STAGE panel and the stage agree.
	forcedBoss (dev / preview: StageManager.ForceBoss) replaces the pick.
]]
local bossPlan: { string } = {}
local stageBoss = "ScorpionQueen"
local forcedBoss: string? = nil
local fixedBosses: { string }? = nil -- the Daily Challenge's boss order (CurseData.Daily)

local function bossFor(n: number): string
	local fixed = fixedBosses
	if fixed and fixed[n] and BossData.Bosses[fixed[n]] then
		return fixed[n]
	end
	if n <= 1 or #bossPlan == 0 then
		bossPlan = { BossData.Bosses[Config.Boss.First] and Config.Boss.First or "ScorpionQueen" }
	end
	while #bossPlan < n do
		local bag = table.clone(BossData.Rotation)
		for i = #bag, 2, -1 do
			local j = rng:NextInteger(1, i)
			bag[i], bag[j] = bag[j], bag[i]
		end
		if #bag > 1 and bag[1] == bossPlan[#bossPlan] then
			bag[1], bag[#bag] = bag[#bag], bag[1]
		end
		for _, id in ipairs(bag) do
			table.insert(bossPlan, id)
		end
	end
	return bossPlan[n]
end

local function bossName(id: string): string
	return BossData.Get(id).DisplayName
end

local function portalState(name: string, c: number?)
	if portal then
		portal.SetState(name, c)
	end
end

local function participants()
	return ctx.RunManager.GetRunPlayers()
end

local function publishCharge()
	local q = math.floor(charge * 50 + 0.5) / 50
	if q ~= shownCharge then
		shownCharge = q
		state:SetAttribute("PortalCharge", q)
	end
end

--[[
	Landmark for stage n's portal (single map). Stage MapCfg.BossEvery (5) and every multiple of
	it use MapCfg.BossLandmark; the others take the next name of a shuffled bag, never the one
	used last stage. Pure: bag and last are passed in and the updated bag comes back.
]]
function StageManager.PickLandmark(names: { string }, n: number, last: string?, bag: { string }, rand: Random): (string?, { string })
	if #names == 0 then
		return nil, bag
	end
	local bossName_ = MapCfg.BossLandmark
	local every = MapCfg.BossEvery or 5
	if n > 0 and n % every == 0 and table.find(names, bossName_) then
		return bossName_, bag
	end
	local valid: { [string]: boolean } = {}
	for _, name in ipairs(names) do
		valid[name] = true
	end
	local fresh: { string } = {}
	for _, name in ipairs(bag) do
		if valid[name] then
			table.insert(fresh, name)
		end
	end
	bag = fresh
	-- not the last landmark, and not the boss landmark the very stage before a boss stage
	-- (the boss stage would repeat it)
	local nextIsBoss = (n + 1) % every == 0 and table.find(names, bossName_) ~= nil and #names > 2
	local function bad(name: string, strict: boolean): boolean
		return (name == last and #names > 1) or (strict and nextIsBoss and name == bossName_)
	end
	local function shuffled(): { string }
		local fresh_ = table.clone(names)
		for i = #fresh_, 2, -1 do
			local j = rand:NextInteger(1, i)
			fresh_[i], fresh_[j] = fresh_[j], fresh_[i]
		end
		return fresh_
	end
	for _ = 1, 2 do
		if #bag == 0 then
			bag = shuffled()
		end
		for i, name in ipairs(bag) do
			if not bad(name, true) then
				table.remove(bag, i)
				return name, bag
			end
		end
		bag = {} -- everything left is excluded: start a new bag
	end
	bag = shuffled()
	for i, name in ipairs(bag) do
		if not bad(name, false) then
			table.remove(bag, i)
			return name, bag
		end
	end
	return table.remove(bag, 1), bag
end

-- A clear spot inside the picked landmark (FindSpotInRadius), else the usual portal rule.
local function landmarkSpot(arena, n: number): Vector3
	local names: { string } = {}
	local byName: { [string]: any } = {}
	for _, lm in ipairs(arena.Landmarks) do
		table.insert(names, lm.Name)
		byName[lm.Name] = lm
	end
	local pick
	pick, landmarkBag = StageManager.PickLandmark(names, n, lastLandmark, landmarkBag, rng)
	lastLandmark = pick
	local lm = pick and byName[pick]
	if lm then
		local spot = MapBuilder.FindSpotInRadius(arena, rng, lm.Pos, math.max(8, lm.Radius - (MapCfg.PortalLandmarkMargin or 0)), Config.Stages.PortalClearance)
		if spot then
			return spot
		end
	end
	return MapBuilder.FindPortalSpot(arena, rng, nil)
end

-- Drops what the previous stage added to the shared map: its portal, stage colliders.
local function resetStageProps(arena)
	for _, node in ipairs(portalNodes) do
		if node.Parent then
			node:Destroy()
		end
	end
	table.clear(portalNodes)
	local base = stageBase
	if not base then
		return
	end
	for i = #arena.Obstacles, base.Obstacles + 1, -1 do
		table.remove(arena.Obstacles, i)
	end
	for i = #arena.Keepout, base.Keepout + 1, -1 do
		table.remove(arena.Keepout, i)
	end
	for _, c in ipairs(arena.ObstacleFolder:GetChildren()) do
		if not base.Colliders[c] then
			c:Destroy()
		end
	end
end

local function markStageBase(arena)
	local set: { [Instance]: boolean } = {}
	for _, c in ipairs(arena.ObstacleFolder:GetChildren()) do
		set[c] = true
	end
	stageBase = { Obstacles = #arena.Obstacles, Keepout = #arena.Keepout, Colliders = set }
end

-- Builds stage n: its arena, the portal and the obstacle grid. Returns the arena.
-- Single map (arena has Landmarks, RunConfig.Map.SingleMap ~= false): stage 1 builds the map
-- and later stages reuse it, with a fresh portal in another landmark and fresh loot.
local function buildStage(n: number)
	stage = n
	arenaName = arenaFor(n)
	local arena
	local spot: Vector3
	if singleMode and mapArena and n > 1 then
		arena = mapArena
		resetStageProps(arena)
		markStageBase(arena)
		spot = HeightGrid.Ground(landmarkSpot(arena, n))
		local before: { [Instance]: boolean } = {}
		for _, c in ipairs(arena.Model:GetChildren()) do
			before[c] = true
		end
		portal = MapBuilder.BuildPortal(arena, spot)
		for _, c in ipairs(arena.Model:GetChildren()) do
			if not before[c] then
				table.insert(portalNodes, c)
			end
		end
	else
		arena = MapBuilder.BuildArena(arenaName, n - 1)
		-- ground heights + flow fields; flat (today's floor) when the map tags no NavGround
		HeightGrid.Build(arena)
		if singleMode then
			if arena.Landmarks and #arena.Landmarks > 0 then
				mapArena = arena
				lastLandmark = nil
				table.clear(landmarkBag)
				table.clear(portalNodes)
				markStageBase(arena)
				spot = HeightGrid.Ground(landmarkSpot(arena, n))
				local before: { [Instance]: boolean } = {}
				for _, c in ipairs(arena.Model:GetChildren()) do
					before[c] = true
				end
				portal = MapBuilder.BuildPortal(arena, spot)
				for _, c in ipairs(arena.Model:GetChildren()) do
					if not before[c] then
						table.insert(portalNodes, c)
					end
				end
			else
				singleMode = false -- no landmarks: the old arena rules
			end
		end
		if not singleMode then
			spot = HeightGrid.Ground(MapBuilder.FindPortalSpot(arena, rng, lastPortal[arenaName]))
			lastPortal[arenaName] = spot
			portal = MapBuilder.BuildPortal(arena, spot)
		end
	end
	-- chests, shrines and the guarded altar (new spots every stage; the old ones are gone)
	ctx.LootSystem.BuildStage(arena, n, spot)
	-- feature encounters (EncounterDirector; nothing runs while none is registered)
	EncounterDirector.StageStart(arena, n, spot, arenaName)
	ctx.EnemyAI.SetArena(arena) -- after the portal and the loot: their colliders count too
	BiomeHazards.SetArena(arena) -- mud / ice / quicksand / lava pools of a biome arena
	stageTime = 0
	revealed = false
	revealAt = 0
	holdReleasedAt = nil
	tutorialHeld = false
	shownLock = -1
	charge = 0
	shownCharge = -1
	miniWaveTimer = 0
	state:SetAttribute("Stage", n)
	state:SetAttribute("Arena", arenaName)
	state:SetAttribute("StageArena", StageManager.ArenaDisplayName())
	stageBoss = forcedBoss or bossFor(n)
	state:SetAttribute("StageBoss", bossName(stageBoss))
	state:SetAttribute("PortalPos", spot)
	state:SetAttribute("PortalHint", false)
	swarmWarn = 0
	state:SetAttribute("SwarmWarn", 0)
	state:SetAttribute("PortalCharge", 0)
	state:SetAttribute("PortalLockLeft", math.ceil(lockSeconds()))
	state:SetAttribute("SurgeLeft", 0)
	state:SetAttribute("ChoiceLeft", 0)
	state:SetAttribute("ChoiceLeftHeld", false)
	shownHeld = false
	state:SetAttribute("PortalReady", "")
	return arena
end

------------------------------------------------------------------------------------------
-- [stream D] Director run: formulas, state, beacon, the Basin Breaker
------------------------------------------------------------------------------------------

local function dget(section: string): { [string]: any }
	local t = DirCfg[section]
	return type(t) == "table" and t or {}
end

--[[
	The brief's baselines. B: weapon / enemy HP coefficients (RunConfig.Combat.B from stream B,
	else Director.DefaultB = the starter weapons' base damage, 10). H0: normal player maximum HP
	(RunConfig.Survival.H0 from stream E1, else Config.Player.BaseMaxHP = 120).
]]
function StageManager.Baselines(): (number, number)
	local combat = RunCfgAll.Combat
	local survival = RunCfgAll.Survival
	local B = (type(combat) == "table" and tonumber(combat.B)) or tonumber(DirCfg.DefaultB) or 10
	local H0 = (type(survival) == "table" and tonumber(survival.H0)) or tonumber((Config.Player :: any).BaseMaxHP) or 100
	return B, H0
end

-- Pure formulas of the brief (n = party size N, t = director minutes). Tests read these.
local Formula = {}
StageManager.Formula = Formula

function Formula.PartyHP(n: number): number
	return 1 + (dget("Party").HPPerExtra or 0.30) * (math.max(1, n) - 1)
end
function Formula.PartyDamage(n: number): number
	return 1 + (dget("Party").DamagePerExtra or 0.10) * (math.max(1, n) - 1)
end
function Formula.PartySpawn(n: number): number
	return 1 + (dget("Party").SpawnPerExtra or 0.45) * (math.max(1, n) - 1)
end
function Formula.TimeHP(t: number): number
	return 1 + (dget("Time").HPPerMinute or 0.07) * math.max(0, t)
end
function Formula.TimeDamage(t: number): number
	return 1 + (dget("Time").DamagePerMinute or 0.025) * math.max(0, t)
end
-- ordinary enemy HP: coeff x B x party x time
function Formula.EnemyHP(coeff: number, n: number, t: number): number
	local B = StageManager.Baselines()
	return coeff * B * Formula.PartyHP(n) * Formula.TimeHP(t)
end
-- ordinary contact / attack damage: coeff x H0 x party x time
function Formula.EnemyDamage(coeff: number, n: number, t: number): number
	local _, H0 = StageManager.Baselines()
	return coeff * H0 * Formula.PartyDamage(n) * Formula.TimeDamage(t)
end
-- past RunMinutes: min(OvertimeCap, 1 + OvertimePerMinute (t - RunMinutes)), else 1
function Formula.Overtime(t: number): number
	local S = dget("Spawn")
	local over = t - (DirCfg.RunMinutes or 15)
	if over <= 0 then
		return 1
	end
	return math.min(S.OvertimeCap or 1.5, 1 + (S.OvertimePerMinute or 0.10) * over)
end
-- enemies per second: (Base + PerMinute t) x party spawn x overtime
function Formula.SpawnRate(t: number, n: number): number
	local S = dget("Spawn")
	return ((S.Base or 0.60) + (S.PerMinute or 0.14) * math.max(0, t)) * Formula.PartySpawn(n) * Formula.Overtime(t)
end
function Formula.AliveCap(n: number): number
	local caps = dget("Spawn").AliveCaps or { 55, 95, 145, 200 }
	return math.min(caps[math.clamp(math.floor(n), 1, #caps)], Config.Enemies.MaxLive)
end
-- the Basin Breaker: HPB x B x [1 + HPPerExtra (N-1)] x [1 + HPPerMinute t]
function Formula.BossHP(n: number, t: number): number
	local Bs = dget("Boss")
	local B = StageManager.Baselines()
	return (Bs.HPB or 200) * B * (1 + (Bs.HPPerExtra or 0.80) * (math.max(1, n) - 1)) * (1 + (Bs.HPPerMinute or 0.07) * math.max(0, t))
end

function StageManager.IsDirector(): boolean
	return directorOn
end

-- SwarmState RunStage (nil outside a director run).
function StageManager.RunStage(): string?
	return runStage
end

-- Director seconds / minutes (RunClock).
function StageManager.DirectorClock(): number
	return dClock
end
function StageManager.DirectorMinutes(): number
	return dClock / 60
end

-- Party size N for spawns (at least 1; only ever grows during a run).
function StageManager.PartyN(): number
	if partyN <= 0 and directorOn and ctx then
		return math.clamp(#ctx.RunManager.GetRunPlayers(), 1, dget("Party").Max or 4)
	end
	return math.max(1, partyN)
end

-- The locked outcome of this director run ("Victory" | "Defeat") or nil.
function StageManager.Terminal(): string?
	return directorOn and terminal or nil
end

local function setRunStage(name: string?)
	runStage = name
	state:SetAttribute("RunStage", name)
end

local function noteParty(count: number)
	local n = math.clamp(math.floor(count), 1, dget("Party").Max or 4)
	if n > partyN then
		partyN = n
		state:SetAttribute("PartyN", n)
	end
end

-- RunManager.AddLatePlayer: an admitted late arrival raises N for future spawns (never lowers it;
-- living enemies and an existing boss keep their stats).
function StageManager.OnPlayerAdmitted(count: number)
	if directorOn and not terminal then
		noteParty(count)
	end
end

local function timeScaleNow(): number
	if game:GetService("RunService"):IsStudio() then
		return math.max(0, timeScale)
	end
	return 1
end

-- Studio tests: the director clock runs `scale` times faster (live servers ignore it).
function StageManager.SetTimeScale(scale: number)
	if game:GetService("RunService"):IsStudio() and type(scale) == "number" and scale == scale then
		timeScale = math.max(0, scale)
	end
end

-- Studio tests / DEV: move the director clock to `seconds` (forward only).
function StageManager.SetDirectorClock(seconds: number): boolean
	if not directorOn or terminal or not game:GetService("RunService"):IsStudio() then
		return false
	end
	if type(seconds) == "number" and seconds == seconds and seconds > dClock then
		dClock = seconds
	end
	return true
end

-- The beacon's landmark (Director.Beacon.Landmark) on the ground; the first landmark or a free
-- spot when the map has no such landmark.
local function beaconSpotFor(arena): Vector3
	local want = dget("Beacon").Landmark or MapCfg.BossLandmark
	local pick = nil
	for _, lm in ipairs(arena.Landmarks or {}) do
		if lm.Name == want then
			pick = lm
			break
		end
	end
	pick = pick or (arena.Landmarks and arena.Landmarks[1])
	local p = pick and pick.Pos or MapBuilder.FindPortalSpot(arena, rng, nil)
	local x, z = p.X, p.Z
	if not HeightGrid.IsWalkable(x, z) then
		local nx, nz = HeightGrid.NearestWalkable(x, z, 8)
		if nx and nz then
			x, z = nx, nz
		end
	end
	return Vector3.new(x, HeightGrid.GroundY(x, z), z)
end

-- Builds the single map for a director run. Returns the arena.
local function buildDirector()
	stage = 1
	arenaName = plan[1]
	local arena = MapBuilder.BuildArena(arenaName, 0)
	HeightGrid.Build(arena)
	mapArena = arena
	singleMode = false
	portal = nil
	table.clear(portalNodes)
	stageBase = nil
	local spot = beaconSpotFor(arena)
	Beacon.Place(arena, spot)
	-- loot and encounters keep clear of the (hidden) beacon like they kept clear of the portal
	ctx.LootSystem.BuildStage(arena, 1, spot)
	EncounterDirector.StageStart(arena, 1, spot, arenaName)
	ctx.EnemyAI.SetArena(arena)
	BiomeHazards.SetArena(arena)
	stageTime = 0
	revealed = false
	charge = 0
	dClock = 0
	shownClock = -1
	partyN = 0
	terminal = nil
	bossSpawned = false
	overtimeShown = false
	timeScale = tonumber(DirCfg.TimeScale) or 1
	stageBoss = dget("Boss").Id or "BasinBreaker"
	state:SetAttribute("Stage", 1)
	state:SetAttribute("Arena", arenaName)
	state:SetAttribute("StageArena", StageManager.ArenaDisplayName())
	state:SetAttribute("StageBoss", bossName(forcedBoss or stageBoss))
	state:SetAttribute("PortalPos", nil)
	state:SetAttribute("PortalHint", false)
	state:SetAttribute("SwarmWarn", 0)
	state:SetAttribute("PortalCharge", 0)
	state:SetAttribute("PortalLockLeft", 0)
	state:SetAttribute("SurgeLeft", 0)
	state:SetAttribute("ChoiceLeft", 0)
	state:SetAttribute("ChoiceLeftHeld", false)
	state:SetAttribute("PortalReady", "")
	state:SetAttribute("RunClock", 0)
	state:SetAttribute("Overtime", false)
	state:SetAttribute("PartyN", nil)
	state:SetAttribute("BeaconPos", nil)
	state:SetAttribute("BeaconCharge", 0)
	state:SetAttribute("RallyLeft", 0)
	setRunStage("Survive")
	ctx.EnemySpawner.SetDirector(true)
	return arena
end

local function revealBeacon(): boolean
	if not Beacon.Reveal() then
		return false
	end
	setRunStage("BeaconAvailable")
	local p = Beacon.Position()
	if p then
		Fx.Ring(p, 30, Color3.fromRGB(255, 220, 130))
	end
	ctx.RunManager.Broadcast("THE BEACON HAS APPEARED AT THE STONE CIRCLE", Color3.fromRGB(255, 220, 130), true, { Id = "beacon.reveal", Lane = "Headline", Class = "Info" })
	return true
end

-- Beacon.TryActivate succeeded: the rally starts.
function StageManager.OnBeaconActivated(rp)
	if not directorOn or terminal then
		return
	end
	setRunStage("Rally")
	local who = rp and rp.Player and rp.Player.DisplayName or "A hero"
	ctx.RunManager.Broadcast(string.format("%s LIT THE BEACON! RALLY: THE CHARGE STARTS IN %d s", string.upper(who), math.ceil(dget("Beacon").RallySeconds or 30)),
		Color3.fromRGB(255, 190, 90), true, { Id = "beacon.rally", Lane = "Headline", Class = "Critical" })
end

-- A walkable spot SpawnDistance from the beacon, on the side away from the heroes.
local function breakerSpot(): Vector3
	local p = Beacon.Position() or Config.ArenaOrigin
	local d = dget("Boss").SpawnDistance or 22
	local cx, cz, k = 0, 0, 0
	for _, rp in ipairs(participants()) do
		if rp.Alive and rp.Root then
			cx += rp.Root.Position.X
			cz += rp.Root.Position.Z
			k += 1
		end
	end
	local base = rng:NextNumber(0, math.pi * 2)
	if k > 0 then
		local ax, az = p.X - cx / k, p.Z - cz / k
		if ax * ax + az * az > 1 then
			base = math.atan2(az, ax)
		end
	end
	for i = 0, 11 do
		local a = base + (i % 2 == 0 and 1 or -1) * math.ceil(i / 2) * (math.pi / 6)
		local x, z = ctx.EnemySpawner.ClampToArena(p.X + math.cos(a) * d, p.Z + math.sin(a) * d, 8)
		if HeightGrid.IsWalkable(x, z) and HeightGrid.CanStep(p.X, p.Z, x, z) and not ctx.EnemyAI.IsBlocked(x, z, 4) then
			return Vector3.new(x, HeightGrid.GroundY(x, z), z)
		end
	end
	return p
end

-- The Basin Breaker, exactly once (HP / damage from N and the minute at its spawn).
local function spawnBreaker(): boolean
	if bossSpawned or terminal then
		return false
	end
	local n = StageManager.PartyN()
	local t = dClock / 60
	local _, H0 = StageManager.Baselines()
	local hpDiff = ctx.RunModifiers and ctx.RunModifiers.DifficultyMultiplier and ctx.RunModifiers.DifficultyMultiplier("HP") or 1
	local dmgDiff = ctx.RunModifiers and ctx.RunModifiers.DifficultyMultiplier and ctx.RunModifiers.DifficultyMultiplier("Damage") or 1
	local dmg = Formula.PartyDamage(n) * dmgDiff
	local id = forcedBoss or stageBoss
	local boss = ctx.EnemySpawner.SpawnBoss(breakerSpot(), id, {
		BossHP = Formula.BossHP(n, t) * hpDiff,
		BossContact = (dget("Boss").Contact or 0.10) * H0 * dmg,
		BossDmgScale = dmg,
	})
	if not boss then
		return false -- no free enemy slot this frame: tried again next frame
	end
	bossSpawned = true
	boss.SpawnMinute = t
	boss.SpawnN = n
	setSub("Boss")
	setRunStage("Boss")
	Fx.Ring(boss.Pos, 40, Color3.fromRGB(255, 60, 70))
	ctx.RunManager.Broadcast(BossData.Get(id).Title, Color3.fromRGB(255, 60, 60), true, { Id = "boss.arrive", Lane = "Headline", Class = "Critical" })
	return true
end

-- How many times the Basin Breaker was spawned this run (tests: exactly once).
function StageManager.BossSpawned(): boolean
	return bossSpawned
end

-- The boss died: the run is won, once. Everything run-only stops here.
local function directorVictory(bossId: string)
	if terminal then
		return
	end
	terminal = "Victory"
	setRunStage("Victory")
	lastClearTime = ctx.RunManager.GetRunTime()
	for _, rp in ipairs(participants()) do
		if rp.Alive then
			ctx.GoldSystem.AddRunGold(rp, Config.Gold.Boss * (rp.Stats and rp.Stats.GoldMult or 1))
		end
		if not rp.Returned then
			Events.Fire("BossDefeated", rp.Player, { Boss = bossId, Stage = stage })
		end
	end
	-- the terminal lock: unclaimed offers cancelled (no new panels after this), ordinary
	-- enemies and every hazard gone without rewards, the boss's XP banked
	for _, rp in ipairs(participants()) do
		local LU = ctx.LevelUpSystem
		if LU.CancelAll then
			LU.CancelAll(rp)
		else
			LU.Cancel(rp)
		end
	end
	ctx.EnemySpawner.DespawnAll()
	ctx.WeaponSystem.ClearHostile()
	ctx.EnemySpawner.SetDirector(false)
	pcall(ctx.XPSystem.CollectAll, true)
	Fx.Sound("BossRoar")
	ctx.RunManager.EndRun(true)
end

local function stepDirector(dt: number)
	if partyN <= 0 then
		noteParty(#participants())
	end
	if not ctx.RunManager.IsSimulating() then
		return
	end
	BiomeHazards.Step(dt)
	EncounterDirector.Step(dt)
	if terminal then
		return
	end
	local ddt = dt * timeScaleNow()
	dClock += ddt
	local whole = math.floor(dClock)
	if whole ~= shownClock then
		shownClock = whole
		state:SetAttribute("RunClock", whole)
	end
	if not overtimeShown and dClock >= (DirCfg.RunMinutes or 15) * 60 then
		overtimeShown = true
		state:SetAttribute("Overtime", true)
		ctx.RunManager.Broadcast("OVERTIME! THE SWARM KEEPS GROWING", Color3.fromRGB(255, 120, 90), true, { Id = "run.overtime", Lane = "Headline", Class = "Critical" })
	end
	if runStage == "Survive" and dClock >= (dget("Beacon").RevealAt or 750) then
		revealBeacon()
	end
	local ev = Beacon.Step(ddt, participants())
	if ev == "ChargeStarted" then
		setRunStage("Charge")
		ctx.RunManager.Broadcast("CHARGE THE BEACON! STAY INSIDE ITS RING", Color3.fromRGB(255, 220, 130), true, { Id = "beacon.charge", Lane = "Headline", Class = "Critical" })
	end
	if not bossSpawned and runStage == "Charge" and Beacon.Phase() == "Done" then
		spawnBreaker()
	end
end

------------------------------------------------------------------------------------------
-- Run lifecycle (called by RunManager)
------------------------------------------------------------------------------------------

--[[
	Stage 1 of a new run. Returns the arena (players are placed by RunManager).
	fixed (the Daily Challenge): { Arenas = {...}, Bosses = {...} } the arena of every
	stage (the first one is stage 1's) and the boss order; past their end the normal
	shuffled tour takes over.
]]
function StageManager.BeginRun(selectedArena: string, fixed: { Arenas: { string }, Bosses: { string } }?)
	firstArena = selectedArena
	plan = { known(selectedArena) and selectedArena or "Forest" }
	fixedBosses = nil
	lastClearTime = 0
	terminal = nil
	if fixed then
		plan = {}
		for _, name in ipairs(fixed.Arenas) do
			if known(name) and name ~= plan[#plan] then
				table.insert(plan, name)
			end
		end
		if #plan == 0 then
			plan = { "Forest" }
		end
		firstArena = plan[1]
		fixedBosses = table.clone(fixed.Bosses)
	end
	table.clear(lastPortal)
	-- single map: only when every planned arena is the single-map arena (a daily with old arenas
	-- keeps the old tour); buildStage turns it off again if the built arena has no Landmarks
	singleMode = MapCfg.SingleMap ~= false and #plan > 0
	for _, name in ipairs(plan) do
		if name ~= MapCfg.MapName then
			singleMode = false
		end
	end
	mapArena = nil
	lastLandmark = nil
	table.clear(landmarkBag)
	table.clear(portalNodes)
	stageBase = nil
	-- [stream D] the single map with the director: one run, no stage loop
	directorOn = DirCfg.Enabled ~= false and not DirCfg.LegacyStages and Beacon ~= nil and fixed == nil
		and #plan == 1 and plan[1] == MapCfg.MapName and not StageManager.IsEndless()
	if directorOn then
		local arena = buildDirector()
		setSub("Explore")
		return arena
	end
	setRunStage(nil)
	local arena = buildStage(1)
	setSub("Explore")
	return arena
end

-- The run is over (defeat, everyone returned, server cleanup). outcome ("Victory" | "Defeat",
-- RunManager.EndRun) locks a director run's terminal state and stays in RunStage through the
-- results; the call without one (back in the lobby) clears it.
function StageManager.EndRun(outcome: string?)
	if directorOn then
		if outcome and not terminal then
			terminal = outcome
		end
		ctx.EnemySpawner.SetDirector(false)
		if Beacon then
			Beacon.Clear()
		end
		directorOn = false
		setRunStage(terminal)
	elseif outcome == nil and runStage ~= nil then
		setRunStage(nil)
	end
	bossSpawned = false
	partyN = 0
	state:SetAttribute("Overtime", false)
	state:SetAttribute("PartyN", nil)
	EncounterDirector.StageEnd("RunEnd") -- feature encounters clean up (defeat, abandon, last one out)
	portal = nil
	singleMode = false
	mapArena = nil
	stageBase = nil
	table.clear(portalNodes)
	fixedBosses = nil
	BiomeHazards.Clear()
	ctx.LootSystem.Clear()
	stage = 0
	setSub("None")
	state:SetAttribute("Stage", 0)
	state:SetAttribute("PortalHint", false)
	swarmWarn = 0
	state:SetAttribute("SwarmWarn", 0)
	state:SetAttribute("PortalCharge", 0)
	state:SetAttribute("PortalLockLeft", 0)
	state:SetAttribute("PortalPos", nil)
	state:SetAttribute("PortalReveal", 0)
	reveals = 0
	state:SetAttribute("StageBoss", nil)
	state:SetAttribute("SurgeLeft", 0)
	state:SetAttribute("ChoiceLeft", 0)
	state:SetAttribute("ChoiceLeftHeld", false)
	shownHeld = false
	state:SetAttribute("PortalReady", "")
end

------------------------------------------------------------------------------------------
-- Boss
------------------------------------------------------------------------------------------

local function startBoss(): boolean
	local p = portal
	if not p then
		return false
	end
	-- the Queen climbs out behind the portal (away from the arena centre, where the
	-- players who charged it usually stand), so she never lands on top of them
	local toCentre = (Config.ArenaOrigin - p.Pos) * FLAT
	local dir = toCentre.Magnitude > 1 and -toCentre.Unit or Vector3.new(0, 0, -1)
	local x, z = ctx.EnemySpawner.ClampToArena(p.Pos.X + dir.X * Config.Stages.BossSpawnOffset, p.Pos.Z + dir.Z * Config.Stages.BossSpawnOffset, 8)
	if not (HeightGrid.IsWalkable(x, z) and HeightGrid.CanStep(p.Pos.X, p.Pos.Z, x, z)) then
		x, z = p.Pos.X, p.Pos.Z -- behind the portal is a cliff / gap: climb out at the portal
	end
	local boss = ctx.EnemySpawner.SpawnBoss(Vector3.new(x, HeightGrid.GroundY(x, z), z), forcedBoss or stageBoss)
	if not boss then
		return false
	end
	setSub("Boss")
	charge = 1
	publishCharge()
	portalState("Boss")
	Fx.Ring(p.Pos, Config.Stages.PortalRadius * 2, Color3.fromRGB(255, 60, 70))
	ctx.RunManager.Broadcast(BossData.Get(forcedBoss or stageBoss).Title, Color3.fromRGB(255, 60, 60), true, { Id = "boss.arrive", Lane = "Headline", Class = "Critical" })
	return true
end

-- Run time when the last stage was cleared (its boss died); 0 = none yet.
function StageManager.LastClearTime(): number
	return lastClearTime
end

-- Called by RunManager when the Queen dies (EnemySpawner.Kill → RunManager.OnBossKilled).
function StageManager.OnBossKilled(_pos: Vector3)
	if sub ~= "Boss" then
		return
	end
	if directorOn then
		directorVictory(forcedBoss or stageBoss) -- [stream D] the run is won
		return
	end
	lastClearTime = ctx.RunManager.GetRunTime()
	for _, rp in ipairs(participants()) do
		if rp.Alive then
			ctx.GoldSystem.AddRunGold(rp, Config.Gold.Boss * (rp.Stats and rp.Stats.GoldMult or 1))
		end
	end
	local list = Config.Difficulty.PlayerCountMult
	local n = 0
	for _, rp in ipairs(participants()) do
		if rp.Alive or rp.AwaitingRevive then
			n += 1
		end
	end
	local S = Config.Stages
	surgeTotal = math.floor((S.SurgeBase + S.SurgePerStage * stage) * list[math.clamp(math.max(1, n), 1, #list)] + 0.5)
	surgeQueued = surgeTotal
	surgeBudget = 0
	surgeTimer = Config.Stages.SurgeSeconds
	setSub("Surge")
	portalState("Surge")
	state:SetAttribute("SurgeLeft", math.ceil(surgeTimer))
	local bossId = forcedBoss or stageBoss
	ctx.RunManager.Broadcast(string.upper(bossName(bossId)) .. " DEFEATED! SURVIVE THE SURGE!", Color3.fromRGB(255, 200, 80), true, { Id = "boss.defeated", Lane = "Headline", Class = "Info" })
	-- achievements per boss (Queen Slayer, Moth Bane ...): the whole team (fallen too)
	for _, rp in ipairs(participants()) do
		if not rp.Returned then
			Events.Fire("BossDefeated", rp.Player, { Boss = bossId, Stage = stage })
		end
	end
	if portal then
		Fx.Ring(portal.Pos, 34, Color3.fromRGB(255, 90, 80))
	end
	Fx.Sound("BossRoar")
end

------------------------------------------------------------------------------------------
-- Open portal: the choice
------------------------------------------------------------------------------------------

local function expeditionComplete(): boolean
	return not StageManager.IsEndless() and StageManager.StagesCleared() >= Config.Stages.WinMinStages
end

local function sendOffer(rp)
	rp.PortalOffered = true
	local cleared = StageManager.StagesCleared()
	local endless = StageManager.IsEndless()
	Remotes.FireClient("PortalOffer", rp.Player, {
		Endless = endless, -- NEXT STAGE only (no RETURN TO LOBBY, no win)
		Complete = expeditionComplete(),
		CountsAsWin = not endless and cleared >= Config.Stages.WinMinStages,
		WinMinStages = Config.Stages.WinMinStages,
		Stage = stage,
		StagesCleared = cleared,
		NextStage = stage + 1,
		NextArena = ((Config.Arenas :: any)[arenaFor(stage + 1)] or {}).DisplayName or arenaFor(stage + 1),
		NextBoss = bossName(forcedBoss or bossFor(stage + 1)),
		ReturnBonus = endless and 0 or math.floor((Config.Gold.WinBonus + Config.Gold.StageClearBonus * cleared) * ctx.GoldSystem.PriceMult(rp.Player) * (ctx.RunModifiers and ctx.RunModifiers.GoldMult() or 1) + 0.5),
		Gold = rp.Gold,
		Kills = rp.Kills,
		Level = rp.Level,
		Time = math.floor(ctx.RunManager.GetRunTime()),
		Seconds = choiceLeft,
		Group = #participants() > 1,
	})
end

local function closeOffers()
	for _, rp in ipairs(participants()) do
		if rp.PortalOffered and rp.Player.Parent then
			Remotes.FireClient("PortalOffer", rp.Player, { Close = true })
		end
		rp.PortalOffered = false
	end
end

local function startTravel()
	closeOffers()
	setSub("Travel")
	local seamless = singleMode and mapArena ~= nil
	travelStep = seamless and "Swap" or "FadeIn"
	travelTimer = seamless and (MapCfg.TransitionSeconds or 0.7) or Config.Stages.TravelFadeSeconds
	if seamless then
		-- the old stage ends in a burst around every player and over the live enemies
		for _, rp in ipairs(participants()) do
			if rp.Root and rp.Player.Parent then
				Fx.Ring(rp.Root.Position, 60, Color3.fromRGB(255, 225, 150))
				Fx.Explosion(rp.Root.Position, 30)
			end
		end
		local shown = 0
		for _, e in ipairs(ctx.EnemySpawner.Active) do
			if shown >= 30 then
				break
			end
			if e.Pos then
				shown += 1
				Fx.Explosion(e.Pos, 7)
			end
		end
	end
	local nextName = arenaFor(stage + 1)
	local display = ((Config.Arenas :: any)[nextName] or {}).DisplayName or nextName
	for _, rp in ipairs(participants()) do
		if rp.Player.Parent then
			Remotes.FireClient("StageTravel", rp.Player, { Stage = stage + 1, Arena = display, Boss = bossName(forcedBoss or bossFor(stage + 1)), Seconds = Config.Stages.TravelFadeSeconds, Seamless = seamless })
		end
	end
	ctx.RunManager.ApplyMovementAll()
end

--[[
	Resolves the open portal once every living player decided (timeout = undecided ones
	go on). Waits while nobody living is left but someone is still deciding on the revive
	offer (they may come back and choose).
]]
local function checkChoices(timeout: boolean)
	if sub ~= "Open" then
		return
	end
	local alive, ready, awaiting = 0, 0, false
	for _, rp in ipairs(participants()) do
		if rp.Alive then
			alive += 1
			if rp.PortalChoice then
				ready += 1
			end
		elseif rp.AwaitingRevive then
			awaiting = true
		end
	end
	state:SetAttribute("PortalReady", alive > 0 and (ready .. "/" .. alive) or "")
	if alive == 0 and awaiting then
		return
	end
	if ready < alive and not timeout then
		return
	end
	if expeditionComplete() then
		closeOffers()
		ctx.XPSystem.CollectAll(true)
		ctx.RunManager.FinishFromPortal()
		return
	end
	if alive > 0 then
		for _, rp in ipairs(participants()) do
			if rp.Alive and not rp.PortalChoice then
				rp.PortalChoice = "Next"
			end
		end
		startTravel()
	else
		-- every living player went back to the lobby: the run ends here
		closeOffers()
		ctx.XPSystem.CollectAll(true)
		ctx.RunManager.FinishFromPortal()
	end
end

-- Someone left the run, returned, fell or was revived: the choice may be complete now.
function StageManager.OnRosterChanged()
	if sub == "Open" then
		checkChoices(false)
	end
end

local function openPortal()
	setSub("Open")
	portalState("Open")
	state:SetAttribute("SurgeLeft", 0)
	local p = portal
	-- the leftovers burn up (they still drop their gems) and every gem flies to the team
	ctx.EnemySpawner.KillInRadius(p and p.Pos or Config.ArenaOrigin, 100000, nil)
	ctx.WeaponSystem.ClearHostile()
	for _, rp in ipairs(participants()) do
		if rp.Alive then
			ctx.XPSystem.MagnetAll(rp)
			break
		end
	end
	if p then
		Fx.Ring(p.Pos, 40, Color3.fromRGB(255, 220, 130))
	end
	choiceLeft = Config.Stages.ChoiceSeconds
	shownChoice = -1
	choiceHeld = 0
	for _, rp in ipairs(participants()) do
		rp.PortalChoice = nil
		rp.PortalOffered = false
	end
	-- the next arena's kit moves up the mesh queue now, so it is loaded by the travel
	if ctx.MeshService and ctx.MeshService.PrioritizeArena then
		ctx.MeshService.PrioritizeArena(arenaFor(stage + 1))
	end
	ctx.RunManager.Broadcast("THE PORTAL IS OPEN", Color3.fromRGB(255, 220, 120), true, { Id = "portal.open", Lane = "Headline", Class = "Info" })
	-- achievements: the stage is cleared for everyone standing (a Bargain stage counts as
	-- an optional event)
	local bargain = ctx.LootSystem and (ctx.LootSystem.TeamBonus().might or 0) > 0
	for _, rp in ipairs(participants()) do
		if rp.Alive and not rp.Returned then
			Events.Fire("StageCleared", rp.Player, { Stage = stage, Character = rp.CharacterId, Bargain = bargain })
			if bargain then
				Events.Fire("OptionalEvent", rp.Player, { Kind = "Bargain" })
			end
		end
	end
	checkChoices(false)
end

local function onChoice(player: Player, choice: any)
	if choice ~= "Next" and choice ~= "Return" then
		return
	end
	if sub ~= "Open" then
		return
	end
	local rp = ctx.RunManager.GetRunPlayer(player)
	if not rp or rp.Returned or not rp.Alive or rp.PortalChoice == choice then
		return
	end
	if choice == "Return" and StageManager.IsEndless() then
		return -- Endless: the portal only leads deeper (leaving = the pause menu's MAIN MENU)
	end
	if choice == "Next" and expeditionComplete() then
		return
	end
	if choice == "Return" then
		ctx.RunManager.ReturnThroughPortal(rp)
	else
		rp.PortalChoice = "Next"
		Remotes.FireClient("PortalOffer", player, { Chosen = "Next" })
	end
	checkChoices(false)
end

------------------------------------------------------------------------------------------
-- Per frame
------------------------------------------------------------------------------------------

-- The tutorial run's reveal wait (Config.FirstRun.RevealAfterPickSeconds / RevealCapSeconds):
-- stage 1 only, until the first level-up card was picked (+ a moment for the cards to
-- close) or the cap. Everyone else: never.
local function tutorialHold(): boolean
	if stage ~= 1 then
		return false
	end
	-- the first-run walkthrough (Walkthrough.lua) keeps it hidden until its GO step (no cap:
	-- every walkthrough step has its own timeout)
	if ctx.Walkthrough and ctx.Walkthrough.HoldsReveal() then
		tutorialHeld = true
		return true
	end
	local cfg = (Config :: any).FirstRun or {}
	if stageTime >= (tonumber(cfg.RevealCapSeconds) or 45) then
		return false
	end
	if holdReleasedAt == nil then
		if ctx.RunManager.TutorialRevealHold and ctx.RunManager.TutorialRevealHold() then
			tutorialHeld = true
			return true
		end
		holdReleasedAt = stageTime
	end
	if not tutorialHeld then
		return false -- never held (a returning player, co-op): the usual reveal moment
	end
	return stageTime < (holdReleasedAt :: number) + (tonumber(cfg.RevealAfterPickSeconds) or 1)
end

local function stepExplore(dt: number)
	stageTime += dt
	local locked = math.max(0, lockSeconds() - stageTime)
	local lockShown = math.ceil(locked)
	if lockShown ~= shownLock then
		shownLock = lockShown
		state:SetAttribute("PortalLockLeft", lockShown)
	end
	-- the reveal: the portal can be charged (lock over), once the stage banner has gone
	local revealDelay = Config.Stages.RevealDelaySeconds or 0
	if not revealed and locked <= 0 and stageTime >= revealDelay and not tutorialHold() then
		revealed = true
		revealAt = stageTime
		reveals += 1
		state:SetAttribute("PortalHint", true)
		state:SetAttribute("PortalReveal", reveals)
		if portal then
			Fx.Ring(portal.Pos, Config.Stages.PortalRadius * 2.5, Color3.fromRGB(190, 210, 255))
		end
		ctx.RunManager.Broadcast("THE PORTAL HAS APPEARED", Color3.fromRGB(190, 210, 255), true, { Id = "portal.reveal", Lane = "Headline", Class = "Info" })
	end
	-- swarm pressure: the longer the portal stays unopened, the louder the warning
	local pressure = Config.Stages.Pressure
	if pressure and revealed then
		-- counted as if the reveal came at the usual moment: a tutorial run's later reveal
		-- does not bring the warnings closer to it
		local t = stageTime - math.max(0, revealAt - revealDelay)
		local step = t >= pressure.DangerSeconds and 2 or (t >= pressure.WarnSeconds and 1 or 0)
		if step > swarmWarn then
			swarmWarn = step
			-- the clients' banner (StageUI, through the Hud.Announce queue) watches this
			state:SetAttribute("SwarmWarn", step)
		end
	end
	miniWaveTimer += dt
	if miniWaveTimer >= Config.Run.MiniWaveInterval then
		miniWaveTimer = 0
		ctx.EnemySpawner.MiniWave()
	end
	local p = portal
	if not p then
		return
	end
	local inside = false
	local r2 = p.Radius * p.Radius
	for _, rp in ipairs(participants()) do
		local root: BasePart? = rp.Root
		if rp.Alive and root then
			local d = (root.Position - p.Pos) * FLAT
			if d.X * d.X + d.Z * d.Z <= r2 then
				inside = true
			end
		end
	end
	if inside and locked <= 0 and revealed then
		charge = math.min(1, charge + dt / Config.Stages.ChargeSeconds)
	else
		charge = math.max(0, charge - dt * Config.Stages.ChargeDecay)
	end
	publishCharge()
	portalState("Charging", charge)
	if charge >= 1 and not startBoss() then
		charge = 0.98 -- no free enemy slot this frame: try again next frame
	end
end

local function stepSurge(dt: number)
	local S = Config.Stages
	if surgeQueued > 0 then
		surgeBudget += dt * surgeTotal / math.max(0.1, S.SurgeSpawnSeconds)
		local k = math.min(surgeQueued, math.floor(surgeBudget))
		if k > 0 then
			surgeBudget -= k
			local p = portal
			local made = ctx.EnemySpawner.SpawnSurge(k, p and p.Pos or Config.ArenaOrigin)
			surgeQueued -= k
			if made == 0 and #ctx.EnemySpawner.Active >= Config.Enemies.MaxLive then
				surgeQueued = 0 -- the enemy cap is full: the surge is as big as it gets
			end
		end
	end
	surgeTimer -= dt
	state:SetAttribute("SurgeLeft", math.max(0, math.ceil(surgeTimer)))
	local left = #ctx.EnemySpawner.Active
	if surgeTimer <= 0 or (surgeQueued == 0 and left <= math.max(3, math.floor(surgeTotal * S.SurgeEndRemaining))) then
		openPortal()
	end
end

-- True while a living, still-playing participant has an upgrade panel open (server state:
-- rp.Offer with rp.Paused, the same test as LevelUpSystem's ChoiceOpen attribute).
function StageManager.AnyChoiceOpen(): boolean
	for _, rp in ipairs(participants()) do
		if rp.Alive and not rp.Returned and rp.Paused and rp.Offer ~= nil then
			return true
		end
	end
	return false
end

local function stepOpen(dt: number)
	-- send the panel to players who are (or came back) alive
	for _, rp in ipairs(participants()) do
		if rp.Alive and not rp.PortalOffered and not rp.PortalChoice then
			sendOffer(rp)
		end
	end
	-- the countdown stops while the run is frozen (solo pause menu, solo level-up choice).
	-- Group run: it also waits while any living player has an upgrade choice open (that
	-- panel outranks the stage-clear dialog on their screen), bounded by
	-- Config.Stages.ChoiceHoldMaxSeconds per stage clear so nobody can stall the team.
	local held = false
	if not ctx.RunManager.IsFrozen() then
		if choiceHeld < (Config.Stages.ChoiceHoldMaxSeconds or 0) and StageManager.AnyChoiceOpen() then
			held = true
			choiceHeld += dt
		else
			choiceLeft -= dt
		end
	end
	if held ~= shownHeld then
		shownHeld = held
		state:SetAttribute("ChoiceLeftHeld", held)
	end
	local shown = math.max(0, math.ceil(choiceLeft))
	if shown ~= shownChoice then
		shownChoice = shown
		state:SetAttribute("ChoiceLeft", shown)
	end
	if choiceLeft <= 0 then
		checkChoices(true)
	end
end

local function finishTravel()
	travelStep = ""
	setSub("Explore")
	portalState("Idle", 0)
	ctx.RunManager.ApplyMovementAll()
	-- the "STAGE n" title is the client HUD's stage banner (Hud.lua)
	-- biome arenas with floor hazards name them ("Swamp · Mud pools slow you · ...")
	local def = (Config.Arenas :: any)[arenaName]
	local hint = (BiomeHazards.Count() > 0 and def and def.Hint) and (" · " .. def.Hint) or ""
	-- (the portal is revealed a few seconds later, with its own headline)
	ctx.RunManager.Broadcast(StageManager.ArenaDisplayName() .. hint .. " · the portal opens soon", Color3.fromRGB(180, 200, 255), nil, { Id = "stage.objective" })
end

local function stepTravel(dt: number)
	travelTimer -= dt
	if travelTimer > 0 then
		return
	end
	if travelStep == "FadeIn" or travelStep == "Swap" then
		-- FadeIn: the screens are dark: bank what is still on the floor, then swap the arena.
		-- Swap (single map): same clean-up with no fade; the players stay where they are.
		ctx.XPSystem.CollectAll()
		EncounterDirector.StageEnd("Travel")
		ctx.EnemySpawner.DespawnAll()
		ctx.WeaponSystem.Clear()
		ctx.XPSystem.Clear()
		local arena = buildStage(stage + 1)
		if travelStep == "Swap" then
			ctx.RunManager.TravelPlayers(arena, true)
			finishTravel()
			return
		end
		ctx.RunManager.TravelPlayers(arena)
		travelStep = "FadeOut"
		travelTimer = 0.5
	else
		finishTravel()
	end
end

function StageManager.Step(dt: number)
	if sub == "None" or not ctx.RunManager.IsRunning() then
		return
	end
	if directorOn then
		stepDirector(dt)
		return
	end
	if sub == "Travel" then
		stepTravel(dt)
		return
	end
	if sub == "Open" then
		stepOpen(dt) -- offers go out even while the run is frozen
	end
	if not ctx.RunManager.IsSimulating() then
		return
	end
	-- floor hazards keep working while the portal is open too: a player who walks off the
	-- ice or out of the mud on the way to it gets their footing back at once
	BiomeHazards.Step(dt)
	EncounterDirector.Step(dt)
	if sub == "Explore" then
		stepExplore(dt)
	elseif sub == "Surge" then
		stepSurge(dt)
	end
end

------------------------------------------------------------------------------------------
-- Dev tools (RunManager checks who may use them)
------------------------------------------------------------------------------------------

-- "Spawn portal boss": charges the portal at once (also while it is dormant).
function StageManager.DevActivate(): boolean
	if directorOn then
		-- the Basin Breaker now (the beacon is revealed if it was hidden; dev runs are tainted)
		if terminal or bossSpawned then
			return false
		end
		if Beacon.Phase() == "Hidden" then
			revealBeacon()
		end
		return spawnBreaker()
	end
	if sub ~= "Explore" then
		return false
	end
	charge = 1
	return startBoss()
end

-- The boss id of the current stage (BossData).
function StageManager.StageBoss(): string
	return forcedBoss or stageBoss
end

function StageManager.HasForcedBoss(): boolean
	return forcedBoss ~= nil
end

-- Dev / preview: every portal summons this boss (nil = the normal rotation again).
function StageManager.ForceBoss(id: string?)
	forcedBoss = (id and BossData.Bosses[id]) and id or nil
	if state and stage > 0 then
		state:SetAttribute("StageBoss", bossName(forcedBoss or stageBoss))
	end
end

-- "Teleport to portal": next to the portal's rune circle (the charge then starts).
function StageManager.DevTeleport(rp): boolean
	if directorOn then
		-- next to the beacon (revealed first if it was hidden)
		if terminal or not rp.Alive or not rp.Root then
			return false
		end
		if Beacon.Phase() == "Hidden" then
			revealBeacon()
		end
		local b = Beacon.Position()
		if not b then
			return false
		end
		ctx.RunManager.TeleportPlayer(rp, b + Vector3.new(6, 0, 6))
		return true
	end
	local p = portal
	local root: BasePart? = rp.Root
	if not p or not root or not rp.Alive or sub == "Travel" then
		return false
	end
	local toCentre = (Config.ArenaOrigin - p.Pos) * FLAT
	local dir = toCentre.Magnitude > 1 and toCentre.Unit or Vector3.new(0, 0, 1)
	ctx.RunManager.TeleportPlayer(rp, p.Pos + dir * (p.Radius - 2))
	return true
end

-- "Next stage": opens the portal now (leftovers burn up, a live boss is removed) and sends every
-- living player on to the next stage.
function StageManager.DevNextStage(): boolean
	if directorOn then
		-- one director step on: reveal -> light (rally) -> charge -> boss -> victory (dev)
		if terminal then
			return false
		end
		if runStage == "Survive" then
			dClock = math.max(dClock, dget("Beacon").RevealAt or 750)
			return revealBeacon()
		elseif runStage == "BeaconAvailable" then
			return Beacon.DevActivate()
		elseif runStage == "Rally" then
			Beacon.ForceCharge(0)
			return true
		elseif runStage == "Charge" then
			Beacon.ForceCharge(1)
			return true
		elseif runStage == "Boss" then
			local boss = ctx.EnemySpawner.Boss
			if boss and boss.Alive then
				ctx.EnemySpawner.Kill(boss, nil)
				return true
			end
		end
		return false
	end
	if sub ~= "Explore" and sub ~= "Boss" and sub ~= "Surge" and sub ~= "Open" then
		return false
	end
	-- a live boss goes with no rewards (openPortal's sweep skips bosses, so it used to stay
	-- alive through the portal choice; dev only, the run is tainted)
	local boss = ctx.EnemySpawner.Boss
	if boss and boss.Alive then
		ctx.EnemySpawner.Despawn(boss)
	end
	if sub ~= "Open" then
		openPortal()
	end
	local now: string = sub
	if now ~= "Open" then
		return now == "Travel" -- openPortal's own check already sent everyone on
	end
	for _, rp in ipairs(participants()) do
		if rp.Alive then
			rp.PortalChoice = "Next"
		end
	end
	checkChoices(false)
	return true
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function StageManager.Init(c)
	ctx = c
	BiomeHazards.Init(c)
	EncounterDirector.Init(c)
	state = Remotes.State()
	state:SetAttribute("Stage", 0)
	state:SetAttribute("StagePhase", "None")
	-- [stream D] the beacon (SwarmV2.Run.Beacon); without it every run keeps the stage loop
	local v2 = game:GetService("ServerScriptService"):FindFirstChild("SwarmV2")
	local run = v2 and v2:FindFirstChild("Run")
	local mod = run and run:FindFirstChild("Beacon")
	if mod and mod:IsA("ModuleScript") then
		local ok, result = pcall(require, mod)
		if ok and type(result) == "table" then
			Beacon = result
			Beacon.Init(c)
			c.Beacon = Beacon -- the interact / UI layer: ctx.Beacon.TryActivate(rp)
		else
			warn("[StageManager] Beacon failed to load: " .. tostring(result))
		end
	end
end

function StageManager.Start()
	Remotes.Listen("PortalChoice", onChoice, 3)
end

return StageManager
