--[[
	StageManager.lua
	The Risk of Rain style stage loop inside a run (Config.Stages). RunManager owns the
	run itself (players, lives, results); this module owns what happens on each stage:

	  Explore  the arena of this stage with a PORTAL at a random clear spot. The swarm
	           comes as usual (mini-waves every Config.Run.MiniWaveInterval). After
	           HintAfterSeconds (never before the lock ends) the HUD shows an arrow to the
	           portal. The portal is dormant for PortalLockSeconds; after that any living
	           player standing in its rune circle charges it (ChargeSeconds).
	  Boss     charging summons the Scorpion Queen in front of the portal (HP scaled by
	           stage and player count); regular spawning follows the boss-phase rules.
	  Surge    the Queen died: SurgeBase + SurgePerStage x stage enemies pour out; survive
	           SurgeSeconds or kill most of them.
	  Open     the leftovers die, the gems fly to the players and every living player
	           chooses NEXT STAGE or RETURN TO LOBBY (remote "PortalChoice"). Returning
	           ends that player's run (RunManager.ReturnThroughPortal; a win from
	           WinMinStages cleared stages, the gold bonus always). When all
	           living players chose (or ChoiceSeconds ran out: undecided = next stage) the
	           rest travel; if nobody is left to go on, the run ends cleanly.
	  Travel   fade, new arena (alternating through Config.Arenas.Order), enemies, gems
	           and projectiles cleared, players moved to the new spawn, healed, fallen
	           teammates revived (RunManager.TravelPlayers). Nothing simulates meanwhile.

	Difficulty keeps scaling with TOTAL run time (RunManager.GetTier / the spawn table) and
	this module adds per-stage multipliers (EnemyHPMult, DamageMult, SpawnMult, BossHPMult);
	stage 1 multiplies by exactly 1, so the early game plays as before.

	SwarmState attributes (client HUD): Stage, StagePhase, StageArena, PortalPos,
	PortalHint, PortalCharge, PortalLockLeft, SurgeLeft, ChoiceLeft, PortalReady ("ready/total").
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local MapBuilder = require(script.Parent.MapBuilder)
local Fx = require(script.Parent.Fx)

local StageManager = {}

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
local hinted = false
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
local travelStep = ""
local travelTimer = 0

------------------------------------------------------------------------------------------
-- Queries
------------------------------------------------------------------------------------------

function StageManager.GetStage(): number
	return stage
end

function StageManager.GetPhase(): string
	return sub
end

-- Stages whose Queen is dead (the current one counts once the surge started).
function StageManager.StagesCleared(): number
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
function StageManager.IsHolding(): boolean
	return sub == "Travel"
end

-- Regular top-up spawning runs while exploring and during the boss fight (boss rules).
function StageManager.AllowSpawning(): boolean
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

function StageManager.EnemyHPMult(): number
	return perStage(Config.Stages.EnemyHPPerStage)
end

function StageManager.DamageMult(): number
	return perStage(Config.Stages.EnemyDamagePerStage)
end

function StageManager.SpawnMult(): number
	return perStage(Config.Stages.SpawnTargetPerStage)
end

-- Seconds of this stage before the portal can be charged (Config.Stages.PortalLockSeconds).
local function lockSeconds(): number
	local list = Config.Stages.PortalLockSeconds
	return list[math.clamp(stage, 1, #list)] or 0
end

function StageManager.BossHPMult(): number
	local list = Config.Stages.BossHPByStage
	local s = math.max(1, stage)
	if s <= #list then
		return list[s]
	end
	return list[#list] + (s - #list) * Config.Stages.BossHPPerExtraStage
end

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function setSub(newSub: string)
	sub = newSub
	state:SetAttribute("StagePhase", newSub)
end

-- Arena of stage n: the lobby's choice first, then the next arenas in Config.Arenas.Order.
local function arenaFor(n: number): string
	local order = Config.Arenas.Order
	local start = table.find(order, firstArena) or 1
	return order[((start - 1) + (n - 1)) % #order + 1]
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

-- Builds stage n: its arena, the portal and the obstacle grid. Returns the arena.
local function buildStage(n: number)
	stage = n
	arenaName = arenaFor(n)
	local arena = MapBuilder.BuildArena(arenaName, n - 1)
	local spot = MapBuilder.FindPortalSpot(arena, rng, lastPortal[arenaName])
	lastPortal[arenaName] = spot
	portal = MapBuilder.BuildPortal(arena, spot)
	ctx.EnemyAI.SetArena(arena) -- after the portal: its plinths are obstacles too
	stageTime = 0
	hinted = false
	shownLock = -1
	charge = 0
	shownCharge = -1
	miniWaveTimer = 0
	state:SetAttribute("Stage", n)
	state:SetAttribute("Arena", arenaName)
	state:SetAttribute("StageArena", StageManager.ArenaDisplayName())
	state:SetAttribute("PortalPos", spot)
	state:SetAttribute("PortalHint", false)
	state:SetAttribute("PortalCharge", 0)
	state:SetAttribute("PortalLockLeft", math.ceil(lockSeconds()))
	state:SetAttribute("SurgeLeft", 0)
	state:SetAttribute("ChoiceLeft", 0)
	state:SetAttribute("PortalReady", "")
	return arena
end

------------------------------------------------------------------------------------------
-- Run lifecycle (called by RunManager)
------------------------------------------------------------------------------------------

-- Stage 1 of a new run. Returns the arena (players are placed by RunManager).
function StageManager.BeginRun(selectedArena: string)
	firstArena = selectedArena
	table.clear(lastPortal)
	local arena = buildStage(1)
	setSub("Explore")
	return arena
end

-- The run is over (defeat, everyone returned, server cleanup).
function StageManager.EndRun()
	portal = nil
	stage = 0
	setSub("None")
	state:SetAttribute("Stage", 0)
	state:SetAttribute("PortalHint", false)
	state:SetAttribute("PortalCharge", 0)
	state:SetAttribute("PortalLockLeft", 0)
	state:SetAttribute("PortalPos", nil)
	state:SetAttribute("SurgeLeft", 0)
	state:SetAttribute("ChoiceLeft", 0)
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
	local boss = ctx.EnemySpawner.SpawnBoss(Vector3.new(x, Config.ArenaOrigin.Y, z))
	if not boss then
		return false
	end
	setSub("Boss")
	charge = 1
	publishCharge()
	portalState("Boss")
	Fx.Ring(p.Pos, Config.Stages.PortalRadius * 2, Color3.fromRGB(255, 60, 70))
	ctx.RunManager.Broadcast("THE SCORPION QUEEN AWAKENS!", Color3.fromRGB(255, 60, 60), true)
	return true
end

-- Called by RunManager when the Queen dies (EnemySpawner.Kill → RunManager.OnBossKilled).
function StageManager.OnBossKilled(_pos: Vector3)
	if sub ~= "Boss" then
		return
	end
	for _, rp in ipairs(participants()) do
		if rp.Alive then
			ctx.GoldSystem.AddRunGold(rp, Config.Gold.Boss)
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
	ctx.RunManager.Broadcast("QUEEN DEFEATED! SURVIVE THE SURGE!", Color3.fromRGB(255, 200, 80), true)
	if portal then
		Fx.Ring(portal.Pos, 34, Color3.fromRGB(255, 90, 80))
	end
	Fx.Sound("BossRoar")
end

------------------------------------------------------------------------------------------
-- Open portal: the choice
------------------------------------------------------------------------------------------

local function sendOffer(rp)
	rp.PortalOffered = true
	local cleared = StageManager.StagesCleared()
	Remotes.FireClient("PortalOffer", rp.Player, {
		CountsAsWin = cleared >= Config.Stages.WinMinStages,
		WinMinStages = Config.Stages.WinMinStages,
		Stage = stage,
		StagesCleared = cleared,
		NextStage = stage + 1,
		NextArena = ((Config.Arenas :: any)[arenaFor(stage + 1)] or {}).DisplayName or arenaFor(stage + 1),
		ReturnBonus = math.floor((Config.Gold.WinBonus + Config.Gold.StageClearBonus * cleared) * ctx.MonetizationService.GoldMultiplier(rp.Player) + 0.5),
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
	travelStep = "FadeIn"
	travelTimer = Config.Stages.TravelFadeSeconds
	local nextName = arenaFor(stage + 1)
	local display = ((Config.Arenas :: any)[nextName] or {}).DisplayName or nextName
	for _, rp in ipairs(participants()) do
		if rp.Player.Parent then
			Remotes.FireClient("StageTravel", rp.Player, { Stage = stage + 1, Arena = display, Seconds = Config.Stages.TravelFadeSeconds })
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
	for _, rp in ipairs(participants()) do
		rp.PortalChoice = nil
		rp.PortalOffered = false
	end
	ctx.RunManager.Broadcast("THE PORTAL IS OPEN", Color3.fromRGB(255, 220, 120), true)
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

local function stepExplore(dt: number)
	stageTime += dt
	local locked = math.max(0, lockSeconds() - stageTime)
	local lockShown = math.ceil(locked)
	if lockShown ~= shownLock then
		shownLock = lockShown
		state:SetAttribute("PortalLockLeft", lockShown)
		if lockShown == 0 and stageTime > 0.5 then
			ctx.RunManager.Broadcast("The portal awakens!", Color3.fromRGB(180, 200, 255))
		end
	end
	if not hinted and stageTime >= math.max(Config.Stages.HintAfterSeconds, lockSeconds()) then
		hinted = true
		state:SetAttribute("PortalHint", true)
		ctx.RunManager.Broadcast("The portal is marked on your screen.", Color3.fromRGB(180, 200, 255))
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
	if inside and locked <= 0 then
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

local function stepOpen(dt: number)
	-- send the panel to players who are (or came back) alive
	for _, rp in ipairs(participants()) do
		if rp.Alive and not rp.PortalOffered and not rp.PortalChoice then
			sendOffer(rp)
		end
	end
	-- the countdown stops while the run is frozen (pause menu, level-up choice)
	if not ctx.RunManager.IsFrozen() then
		choiceLeft -= dt
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

local function stepTravel(dt: number)
	travelTimer -= dt
	if travelTimer > 0 then
		return
	end
	if travelStep == "FadeIn" then
		-- the screens are dark: bank what is still on the floor, then swap the arena
		ctx.XPSystem.CollectAll()
		ctx.EnemySpawner.DespawnAll()
		ctx.WeaponSystem.Clear()
		ctx.XPSystem.Clear()
		local arena = buildStage(stage + 1)
		ctx.RunManager.TravelPlayers(arena)
		travelStep = "FadeOut"
		travelTimer = 0.5
	else
		travelStep = ""
		setSub("Explore")
		portalState("Idle", 0)
		ctx.RunManager.ApplyMovementAll()
		ctx.RunManager.Broadcast("STAGE " .. stage, Color3.fromRGB(255, 230, 150), true)
		ctx.RunManager.Broadcast(StageManager.ArenaDisplayName() .. " · find the portal", Color3.fromRGB(180, 200, 255))
	end
end

function StageManager.Step(dt: number)
	if sub == "None" or not ctx.RunManager.IsRunning() then
		return
	end
	if sub == "Travel" then
		stepTravel(dt)
		return
	end
	if sub == "Open" then
		stepOpen(dt)
		return
	end
	if not ctx.RunManager.IsSimulating() then
		return
	end
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
	if sub ~= "Explore" then
		return false
	end
	charge = 1
	return startBoss()
end

-- "Teleport to portal": next to the portal's rune circle (the charge then starts).
function StageManager.DevTeleport(rp): boolean
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

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function StageManager.Init(c)
	ctx = c
	state = Remotes.State()
	state:SetAttribute("Stage", 0)
	state:SetAttribute("StagePhase", "None")
end

function StageManager.Start()
	Remotes.Listen("PortalChoice", onChoice, 3)
end

return StageManager
