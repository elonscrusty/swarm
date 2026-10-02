--[[
	BossAI.lua
	Runs a boss encounter described in src/shared/BossData.lua (the Scorpion Queen). Called
	every frame by EnemyAI for the boss record (after think() picked her target); started by
	EnemySpawner.SpawnBoss (Begin) and ended by EnemySpawner.Damage (StartCollapse).

	Flow: Entrance (rises out of the ground, invulnerable and harmless, then Grace seconds
	of walking without attacks) → Chase → attack from the phase's Cycle → its recovery →
	Chase → ... Crossing a phase's HP share queues the next phase: at the next Chase she
	roars (banner, boss bar marker) and the new phase's speed and twist apply.
	Defeat: Collapse seconds (every boss hazard, telegraph and stinger removed at once,
	no slow motion), then EnemySpawner.Kill pays the rewards and the surge begins.

	Her current pose is the body attribute "Act" (client poses + effects): Emerge, Windup,
	Charge, Stunned, Claws, TailRaise, Dive, Burrow, Summon, Roar, Collapse.
	SwarmState attributes for the HUD: BossName, BossPhase, BossPhaseAt, BossIntro.
	Every attack only hits through its telegraph: lanes (charge), filling circles (venom,
	burrow) and spokes with gaps (stinger ring); targets are living players only, so deaths,
	revives and players leaving never leave her aiming at nobody.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local BossData = require(ReplicatedStorage.Shared.BossData)
local Fx = require(script.Parent.Fx)
local Hazards = require(script.Parent.Hazards)

local BossAI = {}

local ctx
local rng = Random.new()
local FLAT = Vector3.new(1, 0, 1)
local TAU = math.pi * 2
local GROUP = "Boss"
local STINGER_VISUAL = 7 -- WeaponData.Visuals index of the boss stinger

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function setAct(e, act: string?)
	ctx.EnemySpawner.SetAct(e, act)
end

local function setState(e, name: string, seconds: number)
	e.BossState = name
	e.BossTimer = seconds
end

local function living(): { any }
	local out = {}
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and rp.Root and not rp.Returned then
			table.insert(out, rp)
		end
	end
	return out
end

local function valid(rp): boolean
	return rp ~= nil and rp.Alive and rp.Root ~= nil and not rp.Returned
end

local function floorPos(rp): Vector3
	local p = rp.Root.Position
	return Vector3.new(p.X, Config.ArenaOrigin.Y, p.Z)
end

local function nearest(pos: Vector3)
	local best, bestD = nil, math.huge
	for _, rp in ipairs(living()) do
		local d = ((rp.Root.Position - pos) * FLAT).Magnitude
		if d < bestD then
			best, bestD = rp, d
		end
	end
	return best
end

local function phase(e)
	return e.BossData.Phases[e.PhaseIndex] or e.BossData.Phases[1]
end

-- Chase / recovery times shrink in faster phases; telegraph times never do.
local function paced(e, seconds: number): number
	return seconds / (phase(e).Speed or 1)
end

local function damage(n: number): number
	return n * ctx.StageManager.DamageMult()
end

local function addWarn(e, id: number)
	table.insert(e.BossWarns, id)
end

local function clamp(pos: Vector3): Vector3
	local x, z = ctx.EnemySpawner.ClampToArena(pos.X, pos.Z, 4)
	return Vector3.new(x, Config.ArenaOrigin.Y, z)
end

local function setVulnerable(e, on: boolean)
	e.Invulnerable = not on
	e.Untargetable = not on
end

local function chase(e, seconds: number)
	setAct(e, nil)
	e.Harmless = false
	e.SpeedOverride = nil
	setState(e, "Chase", seconds)
end

local function stunned(e, seconds: number)
	setAct(e, "Stunned")
	e.Harmless = true -- dizzy: walking into her is safe, hitting her is free
	e.SpeedOverride = 0
	setState(e, "Recover", seconds)
end

local function recover(e, seconds: number)
	e.SpeedOverride = 0
	setState(e, "Recover", seconds)
end

------------------------------------------------------------------------------------------
-- Attacks: start functions (anticipation + telegraph)
------------------------------------------------------------------------------------------

local Start = {}

function Start.Charge(e, windup: number?)
	local A = e.BossData.Attacks.Charge
	local target = nearest(e.Pos)
	local dir = target and ((target.Root.Position - e.Pos) * FLAT) or e.Dir
	dir = (dir and dir.Magnitude > 0.1) and dir.Unit or Vector3.new(0, 0, 1)
	e.ChargeDir = dir
	local w = windup or A.Windup
	local length = A.Speed * A.Duration
	addWarn(e, Fx.Telegraph(e.Pos + dir * (length / 2), math.atan2(-dir.X, -dir.Z), length, e.Radius * 2, w))
	e.SpeedOverride = 0
	setAct(e, "Windup")
	setState(e, "ChargeWindup", w)
end

function Start.VenomBurst(e)
	local A = e.BossData.Attacks.VenomBurst
	e.SpeedOverride = 0
	setAct(e, "Claws")
	setState(e, "VenomWindup", A.Windup)
end

function Start.StingerRing(e)
	local A = e.BossData.Attacks.StingerRing
	local count, gaps = A.Count, A.Gaps
	local skip = {}
	local first = rng:NextInteger(0, count - 1)
	for g = 0, gaps - 1 do
		local c = first + math.floor(g * count / gaps)
		for k = 0, A.GapWidth - 1 do
			skip[(c + k) % count] = true
		end
	end
	local rot = rng:NextNumber(0, TAU / count)
	local angles = {}
	for i = 0, count - 1 do
		if not skip[i] then
			table.insert(angles, math.floor((rot + i * TAU / count) * 1000 + 0.5) / 1000)
		end
	end
	e.RingAngles = angles
	e.RingWave = 0
	e.SpeedOverride = 0
	setAct(e, "TailRaise")
	local shown = A.Windup + (A.Waves - 1) * A.WaveGap + 0.35
	addWarn(e, Fx.Warn("spokes", e.Pos.X, e.Pos.Z, e.Radius + 0.5, 18, shown, angles))
	setState(e, "Ring", A.Windup)
end

function Start.Burrow(e)
	local A = e.BossData.Attacks.Burrow
	local list = living()
	e.BurrowTarget = #list > 0 and list[rng:NextInteger(1, #list)] or nil
	e.SpeedOverride = 0
	setAct(e, "Dive")
	setState(e, "Dive", A.Dive)
end

function Start.Summon(e)
	local A = e.BossData.Attacks.Summon
	local spots = {}
	local offset = rng:NextNumber(0, TAU)
	local r = e.Radius + A.Distance
	for i = 1, A.Count do
		local a = offset + (i / A.Count) * TAU
		local p = clamp(e.Pos + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
		if not ctx.EnemyAI.IsBlocked(p.X, p.Z, 1.5) then
			table.insert(spots, p)
			addWarn(e, Fx.Warn("egg", p.X, p.Z, A.Windup))
		end
	end
	e.SummonSpots = spots
	e.SpeedOverride = 0
	setAct(e, "Summon")
	setState(e, "SummonWindup", A.Windup)
end

------------------------------------------------------------------------------------------
-- Active moments
------------------------------------------------------------------------------------------

local function venomCircles(e)
	local A = e.BossData.Attacks.VenomBurst
	local players = living()
	if #players == 0 then
		return
	end
	local n = math.min(A.MaxCircles, A.Circles + #players - 1)
	local spots: { Vector3 } = {}
	local function free(p: Vector3): boolean
		for _, q in ipairs(spots) do
			if ((p - q) * FLAT).Magnitude < A.Radius * 1.3 then
				return false
			end
		end
		return true
	end
	-- one circle right where each player stands (a small random offset) ...
	for _, rp in ipairs(players) do
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(0, 1.5)
		local p = clamp(floorPos(rp) + Vector3.new(math.cos(a) * d, 0, math.sin(a) * d))
		if free(p) and #spots < n then
			table.insert(spots, p)
		end
	end
	-- ... and the rest close around them, so the safe ground is a short step away
	for _ = 1, 40 do
		if #spots >= n then
			break
		end
		local rp = players[rng:NextInteger(1, #players)]
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(8, 14)
		local p = clamp(floorPos(rp) + Vector3.new(math.cos(a) * d, 0, math.sin(a) * d))
		if free(p) then
			table.insert(spots, p)
		end
	end
	for _, p in ipairs(spots) do
		Hazards.Strike(p, A.Radius, A.Fill, damage(A.Damage), { Group = GROUP, Style = "venom" })
	end
	Fx.Sound("Explosion")
end

local function fireRing(e)
	local A = e.BossData.Attacks.StingerRing
	for _, a in ipairs(e.RingAngles or {}) do
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		ctx.WeaponSystem.SpawnHostile(e.Pos + dir * e.Radius, dir, A.Speed, damage(A.Damage), A.ProjectileRadius, A.Life, STINGER_VISUAL)
	end
end

local function nextAttack(e)
	table.clear(e.BossWarns) -- the last attack's telegraphs are over by now
	local cycle = phase(e).Cycle
	e.BossCycle = (e.BossCycle % #cycle) + 1
	local name = cycle[e.BossCycle]
	local fn = Start[name]
	if fn then
		fn(e)
	else
		chase(e, paced(e, e.BossData.Chase))
	end
end

local function publishPhase(e)
	local state = Remotes.State()
	local nextPhase = e.BossData.Phases[e.PhaseIndex]
	state:SetAttribute("BossPhase", e.PhaseIndex)
	state:SetAttribute("BossPhaseAt", nextPhase and nextPhase.Above or 0)
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- The boss just spawned (EnemySpawner.SpawnBoss): start the entrance.
function BossAI.Begin(e)
	local data = BossData.Get(Config.Boss.Id)
	e.BossData = data
	e.PhaseIndex = 1
	e.PendingPhase = nil
	e.BossCycle = 0
	e.BossWarns = {}
	e.SecondCharge = false
	e.Dying = false
	e.Harmless = true
	setVulnerable(e, false)
	e.SpeedOverride = 0
	setAct(e, "Emerge")
	setState(e, "Entrance", data.Entrance.Seconds)
	local state = Remotes.State()
	state:SetAttribute("BossName", data.DisplayName)
	state:SetAttribute("BossIntro", data.Entrance.Seconds)
	publishPhase(e)
	Fx.Warn("pop", e.Pos.X, e.Pos.Z, data.Entrance.DustRadius, "dust")
	Fx.Warn("circle", e.Pos.X, e.Pos.Z, e.Radius + 2, data.Entrance.Seconds, "burrow")
end

-- Removes the boss's hazards, telegraphs and stingers at once.
function BossAI.ClearHazards(e)
	Hazards.Clear(GROUP)
	if e and e.BossWarns then
		for _, id in ipairs(e.BossWarns) do
			Fx.ClearWarn(id)
		end
		table.clear(e.BossWarns)
	end
	ctx.WeaponSystem.ClearHostile()
end

-- Her HP reached 0 (EnemySpawner.Damage): the collapse, then the real kill.
function BossAI.StartCollapse(e, rp)
	if e.Dying then
		return
	end
	e.Dying = true
	e.Killer = rp
	e.HP = 0
	e.Harmless = true
	setVulnerable(e, false)
	e.SpeedOverride = 0
	BossAI.ClearHazards(e)
	setAct(e, "Collapse")
	setState(e, "Dying", (e.BossData and e.BossData.Collapse) or 1.5)
	Fx.Sound("BossRoar")
	Fx.Warn("pop", e.Pos.X, e.Pos.Z, e.Radius * 2.2, "dust")
end

function BossAI.Step(e, dt: number)
	if not e.BossData then
		BossAI.Begin(e)
	end
	e.BossTimer -= dt
	local stateName = e.BossState
	local data = e.BossData
	local A = data.Attacks

	-- phase thresholds (applied at the next Chase so an attack is never cut in half)
	if not e.Dying and stateName ~= "Entrance" and e.PhaseIndex < #data.Phases then
		local want = BossData.PhaseFor(data, e.HP / math.max(1, e.MaxHP))
		if want > e.PhaseIndex then
			e.PendingPhase = want
		end
	end

	if stateName == "Entrance" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			setVulnerable(e, true)
			chase(e, data.Entrance.Grace) -- no attack for Grace seconds after she is up
		end
	elseif stateName == "Dying" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			ctx.EnemySpawner.Kill(e, valid(e.Killer) and e.Killer or nil)
		end
	elseif stateName == "Chase" then
		e.SpeedOverride = nil
		if e.PendingPhase then
			e.PhaseIndex = e.PendingPhase
			e.PendingPhase = nil
			publishPhase(e)
			local p = phase(e)
			if p.Message then
				ctx.RunManager.Broadcast(p.Message, Color3.fromRGB(255, 90, 80), true)
			end
			Fx.Sound("BossRoar")
			Fx.Ring(e.Pos, 26, Color3.fromRGB(255, 60, 70))
			e.SpeedOverride = 0
			setAct(e, "Roar")
			setState(e, "Roar", p.Roar or 1)
		elseif e.BossTimer <= 0 then
			nextAttack(e)
		end
	elseif stateName == "Roar" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			chase(e, paced(e, data.Chase) * 0.5)
		end
	elseif stateName == "Recover" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			chase(e, paced(e, data.Chase))
		end
	elseif stateName == "ChargeWindup" then
		e.SpeedOverride = 0
		e.Dir = e.ChargeDir
		if e.BossTimer <= 0 then
			setAct(e, "Charge")
			setState(e, "Charging", A.Charge.Duration)
		end
	elseif stateName == "Charging" then
		e.Dir = e.ChargeDir
		e.SpeedOverride = A.Charge.Speed
		if e.BossTimer <= 0 then
			e.SpeedOverride = 0
			if phase(e).Twist == "DoubleCharge" and not e.SecondCharge and #living() > 0 then
				e.SecondCharge = true
				Start.Charge(e, A.Charge.SecondWindup)
			else
				e.SecondCharge = false
				stunned(e, paced(e, A.Charge.Recover))
			end
		end
	elseif stateName == "VenomWindup" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			venomCircles(e)
			setState(e, "VenomHold", A.VenomBurst.Fill)
		end
	elseif stateName == "VenomHold" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			setAct(e, nil)
			recover(e, paced(e, A.VenomBurst.Recover))
		end
	elseif stateName == "Ring" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			fireRing(e)
			e.RingWave += 1
			if e.RingWave >= A.StingerRing.Waves then
				setAct(e, nil)
				recover(e, paced(e, A.StingerRing.Recover))
			else
				e.BossTimer = A.StingerRing.WaveGap
			end
		end
	elseif stateName == "Dive" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			setAct(e, "Burrow")
			setVulnerable(e, false)
			e.Harmless = true
			setState(e, "Burrowed", A.Burrow.Track)
		end
	elseif stateName == "Burrowed" then
		local B = A.Burrow
		if not valid(e.BurrowTarget) then
			e.BurrowTarget = nearest(e.Pos)
		end
		local t = e.BurrowTarget
		if t then
			local to = (t.Root.Position - e.Pos) * FLAT
			local d = to.Magnitude
			if d > 0.5 then
				e.Dir = to.Unit
				e.SpeedOverride = math.min(B.TrackSpeed, d / math.max(dt, 1e-3))
			else
				e.SpeedOverride = 0
			end
		else
			e.SpeedOverride = 0
		end
		if e.BossTimer <= 0 then
			e.SpeedOverride = 0
			local at = Vector3.new(e.Pos.X, Config.ArenaOrigin.Y, e.Pos.Z)
			Hazards.Strike(at, B.Radius, B.Warn, damage(B.Damage), { Group = GROUP, Style = "burrow" })
			setState(e, "Surface", B.Warn)
		end
	elseif stateName == "Surface" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			setVulnerable(e, true)
			stunned(e, paced(e, A.Burrow.Recover))
		end
	elseif stateName == "SummonWindup" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			for _, p in ipairs(e.SummonSpots or {}) do
				ctx.EnemySpawner.Spawn(A.Summon.Type, p)
			end
			e.SummonSpots = nil
			chase(e, paced(e, data.Chase))
		end
	else
		chase(e, data.Chase)
	end
end

function BossAI.Init(c)
	ctx = c
end

return BossAI
