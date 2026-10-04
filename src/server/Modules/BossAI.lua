--[[
	BossAI.lua
	Runs a boss encounter described in src/shared/BossData.lua: the Scorpion Queen, the
	Moth Matriarch, the Rhino Warlord, the Hive Mother, the Briar Sentinel and the
	Frostbound Colossus. Called every frame by EnemyAI
	for the boss record (after think() picked its target); started by
	EnemySpawner.SpawnBoss (Begin, with the stage's BossData entry) and ended by
	EnemySpawner.Damage (StartCollapse).

	Flow: Entrance (rises out of the ground / flies down, invulnerable and harmless, then
	Grace seconds of walking without attacks) → Chase → attack from the phase's Cycle → its
	recovery → Chase → ... Crossing a phase's HP share queues the next phase: at the next
	Chase the boss roars (banner, boss bar marker) and the new phase's speed and twist apply.
	Defeat: Collapse seconds (every boss hazard, telegraph, stinger, banner and egg removed
	at once, no slow motion), then EnemySpawner.Kill pays the rewards and the surge begins.

	The current pose is the body attribute "Act" (client poses + effects):
	  every boss   Emerge, Roar, Collapse, Summon
	  Queen        Windup, Charge, Stunned, Claws, TailRaise, Dive, Burrow
	  Matriarch    Gather (storm / mines), Lift + Swoop + Grounded (dive), GustWindup + Gust
	  Warlord      Windup + Charge (+ Stuck in an obstacle), Rear + Pound, Plant
	  Hive Mother  Heave (egg barrage), Spew (acid pools)
	  Briar        Root (root lines / bramble ring wind-up) + Rooted, Volley + Fling
	  Colossus     SlamWindup + Slam, Stomp (ice lanes), Inhale + Breathe, ShardCall
	Body attribute "BannerOut" = the Warlord's banner is planted (hidden on his back);
	"FrostArmor" = the Colossus wears his phase-2 frost armour (e.Shield soaks the hits in
	EnemySpawner.Damage; breaking it staggers him, it grows back after a while).
	Line hazards (root lines, ice lanes) and closing rings (the bramble ring) are kept on
	the boss record and stepped here; the freezing breath chills players (walk speed
	lowered on top of RunManager.ApplyMovement, player attribute "Chilled"). Every hit
	goes through RunManager.DamagePlayer (invulnerability, armor, shields, DEV god mode).
	SwarmState attributes for the HUD: BossName, BossPhase, BossPhaseAt, BossIntro.
	Every attack only hits through its telegraph (lanes, filling circles, spokes, ring
	bands, a rolling wave with a gap, mines, lanes that erupt, a closing ring with a gap, a
	breath cone); targets are living players only, so deaths,
	revives and players leaving never leave a boss aiming at nobody.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local BossData = require(ReplicatedStorage.Shared.BossData)
local EnemyData = require(ReplicatedStorage.Shared.EnemyData)
local Fx = require(script.Parent.Fx)
local Hazards = require(script.Parent.Hazards)

local BossAI = {}

local ctx
local rng = Random.new()
local FLAT = Vector3.new(1, 0, 1)
local TAU = math.pi * 2
local GROUP = "Boss"
local STINGER_VISUAL = 7 -- WeaponData.Visuals index of the boss stinger
local clock = 0 -- boss time (only runs while the run simulates)

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

local function valid(rp): boolean
	return rp ~= nil and rp.Alive and rp.Root ~= nil and rp.Root.Parent ~= nil and not rp.Returned
end

local function living(): { any }
	local out = {}
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if valid(rp) then
			table.insert(out, rp)
		end
	end
	return out
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

local function twist(e): string?
	return phase(e).Twist
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

local function clamp(pos: Vector3, margin: number?): Vector3
	local x, z = ctx.EnemySpawner.ClampToArena(pos.X, pos.Z, margin or 4)
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

-- dizzy / stuck / grounded: walking into the boss is safe, hitting it is free
local function stunned(e, seconds: number, act: string?)
	setAct(e, act or "Stunned")
	e.Harmless = true
	e.SpeedOverride = 0
	setState(e, "Recover", seconds)
end

local function recover(e, seconds: number)
	e.SpeedOverride = 0
	setState(e, "Recover", seconds)
end

local function partySize(): number
	return math.max(1, #living())
end

-- Unit floor direction from the boss to the nearest player (or its facing).
local function aimDir(e): Vector3
	local target = nearest(e.Pos)
	local dir = target and ((target.Root.Position - e.Pos) * FLAT) or e.Dir
	return (dir and dir.Magnitude > 0.1) and dir.Unit or Vector3.new(0, 0, 1)
end

-- Objects the boss made (War Banner, Brood Eggs): tracked by uid (pool slots are reused).
local function trackObject(e, o)
	o.Owner = e
	e.BossObjects = e.BossObjects or {}
	table.insert(e.BossObjects, { o, o.Uid })
end

local function liveObjects(e, typeId: string?): number
	local list = e.BossObjects
	if not list then
		return 0
	end
	local n = 0
	for i = #list, 1, -1 do
		local o, uid = list[i][1], list[i][2]
		if not (o.Alive and o.Uid == uid) then
			table.remove(list, i)
		elseif typeId == nil or o.Type == typeId then
			n += 1
		end
	end
	return n
end

local function clearObjects(e)
	local list = e and e.BossObjects
	if not list then
		return
	end
	e.BossObjects = nil
	for _, item in ipairs(list) do
		local o, uid = item[1], item[2]
		if o.Alive and o.Uid == uid then
			ctx.EnemySpawner.Despawn(o)
		end
	end
end

-- A free floor spot around `centre` at distance `dist` (tries several angles).
local function freeSpot(centre: Vector3, dist: number, radius: number, angle: number?): Vector3?
	local a0 = angle or rng:NextNumber(0, TAU)
	for k = 0, 7 do
		local a = a0 + k * TAU / 8 * ((k % 2 == 0) and 1 or -1) * 0.5
		local p = clamp(centre + Vector3.new(math.cos(a) * dist, 0, math.sin(a) * dist), 6)
		if not ctx.EnemyAI.IsBlocked(p.X, p.Z, radius) then
			return p
		end
	end
	return nil
end

-- Spots near the players: one close to each (offset minOff..maxOff), the rest around
-- random players (near..far), at least `apart` from each other.
local function spotsNearPlayers(n: number, minOff: number, maxOff: number, near: number, far: number, apart: number): { Vector3 }
	local players = living()
	local spots: { Vector3 } = {}
	if #players == 0 then
		return spots
	end
	local function free(p: Vector3): boolean
		for _, q in ipairs(spots) do
			if ((p - q) * FLAT).Magnitude < apart then
				return false
			end
		end
		return true
	end
	for _, rp in ipairs(players) do
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(minOff, maxOff)
		local p = clamp(floorPos(rp) + Vector3.new(math.cos(a) * d, 0, math.sin(a) * d))
		if free(p) and #spots < n then
			table.insert(spots, p)
		end
	end
	for _ = 1, 50 do
		if #spots >= n then
			break
		end
		local rp = players[rng:NextInteger(1, #players)]
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(near, far)
		local p = clamp(floorPos(rp) + Vector3.new(math.cos(a) * d, 0, math.sin(a) * d))
		if free(p) then
			table.insert(spots, p)
		end
	end
	return spots
end

-- Pushes a living player along the floor (the Matriarch's wing gust): never into an
-- obstacle or out of the fence; the anti-cheat speed check is moved along with them.
local function pushPlayer(rp, delta: Vector3)
	local root: BasePart? = rp.Root
	if not root or not root.Parent or root.Anchored then
		return
	end
	local p = root.Position
	local x, z = ctx.EnemySpawner.ClampToArena(p.X + delta.X, p.Z + delta.Z, 3)
	if ctx.EnemyAI.IsBlocked(x, z, 1.2) then
		return
	end
	local move = Vector3.new(x - p.X, 0, z - p.Z)
	root.CFrame += move
	if rp.LastValidPos then
		rp.LastValidPos += move
	end
end

------------------------------------------------------------------------------------------
-- Attacks: start functions (anticipation + telegraph)
------------------------------------------------------------------------------------------

local Start = {}

--[[
	A lane rush: the Queen's Charge, the Matriarch's Dive, the Warlord's Horn Charge.
	A.Stuck (Horn Charge): the lane stops at the first obstacle / the fence and he sticks
	there. Acts: Queen Windup / Charge, Matriarch Lift / Swoop, Warlord Windup / Charge.
]]
function Start.Rush(e, name: string, windup: number?)
	local A = e.BossData.Attacks[name]
	local dir = aimDir(e)
	e.ChargeDir = dir
	e.ChargeName = name
	local w = windup or A.Windup
	local full = A.Speed * A.Duration
	local len, blocked = full, false
	if A.Stuck then
		-- where would his horn hit something? (the lane shows exactly that)
		local c = Config.ArenaOrigin
		local half = Config.Arenas.Size / 2 - e.Radius - 1
		local reach = e.Radius * 0.6
		for d = 2, full, 1 do
			local p = e.Pos + dir * d
			local tip = p + dir * reach
			if math.abs(p.X - c.X) > half or math.abs(p.Z - c.Z) > half or ctx.EnemyAI.IsBlocked(tip.X, tip.Z, 1.2) then
				len, blocked = math.max(2, d - 1), true
				break
			end
		end
	end
	if blocked and len < 10 and e.BossData.Attacks.GroundPound then
		-- facing a wall right in front of him: a charge would be silly, pound instead
		Start.GroundPound(e)
		return
	end
	e.ChargeBlocked = blocked
	e.ChargeTime = len / A.Speed
	local shown = len + (blocked and e.Radius * 0.6 or 0)
	addWarn(e, Fx.Telegraph(e.Pos + dir * (shown / 2), math.atan2(-dir.X, -dir.Z), shown, e.Radius * 2, w))
	e.SpeedOverride = 0
	setAct(e, name == "Dive" and "Lift" or "Windup")
	setState(e, "ChargeWindup", w)
end

function Start.Charge(e)
	Start.Rush(e, "Charge")
end

function Start.Dive(e)
	Start.Rush(e, "Dive")
end

function Start.HornCharge(e)
	Start.Rush(e, "HornCharge")
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

-- Summons (Queen eggs, Matriarch cocoons, Warlord beetles, Hive Mother's Brood Call).
function Start.Summon(e, name: string?)
	local A = e.BossData.Attacks[name or "Summon"]
	local n = BossData.ForParty(A.Count, A.PerExtraPlayer, A.MaxCount, partySize())
	local def = EnemyData.Enemies[A.Type]
	if def and def.Ranged then
		-- Spitters keep their own cap (Config.Enemies.MaxLiveRanged)
		n = math.min(n, math.max(0, Config.Enemies.MaxLiveRanged - ctx.EnemySpawner.LiveRanged()))
	end
	local spots = {}
	local offset = rng:NextNumber(0, TAU)
	local r = e.Radius + A.Distance
	for i = 1, n do
		local a = offset + (i / n) * TAU
		local p = clamp(e.Pos + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
		if not ctx.EnemyAI.IsBlocked(p.X, p.Z, 1.5) then
			table.insert(spots, p)
			addWarn(e, Fx.Warn(A.Style == "emerge" and "emerge" or "egg", p.X, p.Z, A.Windup))
		end
	end
	if #spots == 0 then
		chase(e, paced(e, e.BossData.Chase) * 0.5) -- nothing to call (caps): keep walking
		return
	end
	e.SummonSpots = spots
	e.SummonType = A.Type
	e.SpeedOverride = 0
	setAct(e, "Summon")
	setState(e, "SummonWindup", A.Windup)
end

function Start.BroodCall(e)
	Start.Summon(e, "BroodCall")
end

-- Matriarch: a dust ring rolls outward from her with one safe gap.
-- (the Colossus's Ground Slam rings use the same rolling wave: A = its attack entry)
local function stormWave(e, delay: number, gap: number, A: any?)
	A = A or e.BossData.Attacks.DustStorm
	local r0 = e.Radius * 0.8
	local gapHalf = math.rad(A.GapHalf)
	local g = math.floor(gap * 1000 + 0.5) / 1000
	local id = Fx.Warn("wave", e.Pos.X, e.Pos.Z, r0, delay, A.Speed, A.MaxRadius, A.Width, g, math.floor(gapHalf * 1000 + 0.5) / 1000)
	local at = Vector3.new(e.Pos.X, Config.ArenaOrigin.Y, e.Pos.Z)
	Hazards.Wave(at, delay, A.Speed, A.MaxRadius, A.Width, g, gapHalf, damage(A.Damage), { Group = GROUP, Warn = id, Start = r0 })
end

function Start.DustStorm(e)
	local A = e.BossData.Attacks.DustStorm
	e.StormLeft = (twist(e) == "Gusts" and A.TwistWaves or A.Waves) - 1
	e.StormGap = rng:NextNumber(0, TAU)
	e.StormTurn = rng:NextNumber() < 0.5 and -1 or 1
	stormWave(e, A.Windup, e.StormGap)
	e.SpeedOverride = 0
	setAct(e, "Gather")
	setState(e, "Storm", A.Windup)
end

-- Matriarch: glimmer motes drift down around the players and pop after a fuse.
function Start.GlimmerMines(e)
	local A = e.BossData.Attacks.GlimmerMines
	e.SpeedOverride = 0
	setAct(e, "Gather")
	setState(e, "MineWindup", A.Windup)
end

-- Matriarch (phase 2): a wind cone toward the nearest player pushes everyone in it away.
function Start.WingGust(e)
	local A = e.BossData.Attacks.WingGust
	local dir = aimDir(e)
	e.GustDir = dir
	e.SpeedOverride = 0
	setAct(e, "GustWindup")
	addWarn(e, Fx.Warn("gust", e.Pos.X, e.Pos.Z, math.floor(math.atan2(dir.Z, dir.X) * 1000 + 0.5) / 1000, A.Length, math.floor(math.rad(A.HalfAngle) * 1000 + 0.5) / 1000, A.Windup, A.Blow))
	setState(e, "GustWindup", A.Windup)
end

-- Warlord: rears up, slams; ring bands fill one after another.
function Start.GroundPound(e)
	local A = e.BossData.Attacks.GroundPound
	e.SecondPound = false
	e.SpeedOverride = 0
	setAct(e, "Rear")
	setState(e, "PoundWindup", A.Windup)
end

local function poundBands(e, outsideIn: boolean): number
	local A = e.BossData.Attacks.GroundPound
	local at = Vector3.new(e.Pos.X, Config.ArenaOrigin.Y, e.Pos.Z)
	local bands = A.Bands
	local n = #bands
	for i, outer in ipairs(bands) do
		local inner = i > 1 and bands[i - 1] or 0
		local order = outsideIn and (n - i) or (i - 1)
		local delay = A.First + order * A.Gap
		local id = Fx.Warn("band", at.X, at.Z, inner, outer, delay)
		Hazards.Strike(at, outer, delay, damage(A.Damage), { Group = GROUP, Style = "pound", Warn = id, Inner = inner > 0 and inner or nil })
	end
	Fx.Sound("BossPound")
	return A.First + (n - 1) * A.Gap
end

-- Warlord: plants a banner (rallies beetles nearby) or, with one still standing, summons.
function Start.WarBanner(e)
	if liveObjects(e, "WarBanner") > 0 then
		Start.Summon(e)
		return
	end
	local A = e.BossData.Attacks.WarBanner
	e.SpeedOverride = 0
	setAct(e, "Plant")
	setState(e, "PlantWindup", A.Windup)
end

-- Hive Mother: eggs are lobbed at the players (landing markers), then sit and hatch.
function Start.EggBarrage(e)
	local A = e.BossData.Attacks.EggBarrage
	local n = BossData.ForParty(A.Count, A.PerExtraPlayer, A.MaxCount, partySize())
	e.Throws = spotsNearPlayers(n, 2, 5, 6, 13, 4.5)
	e.SpeedOverride = 0
	setAct(e, "Heave")
	setState(e, "Heave", A.Windup)
end

function Start.AcidPools(e)
	local A = e.BossData.Attacks.AcidPools
	e.SpeedOverride = 0
	setAct(e, "Spew")
	setState(e, "SpewWindup", A.Windup)
end

-- Line hazards (the Briar Sentinel's root lines, the Colossus's ice lanes): a lane
-- telegraph, then after `delay` the line hits once, either all at once (travel nil) or as
-- an eruption running outward along it at `travel` studs/s. Stepped in BossAI.Step;
-- removed with the boss's other hazards. Returns nothing (the lane id is in BossWarns).
local function lineHazard(e, from: Vector3, dir: Vector3, len: number, width: number, delay: number, travel: number?, dmg: number, pop: string)
	-- stop at the fence (a lane drawn through the wall would lie)
	local c = Config.ArenaOrigin
	local half = Config.Arenas.Size / 2 - 1
	for d = 2, len, 2 do
		local p = from + dir * d
		if math.abs(p.X - c.X) > half or math.abs(p.Z - c.Z) > half then
			len = math.max(4, d - 2)
			break
		end
	end
	addWarn(e, Fx.Telegraph(from + dir * (len / 2), math.atan2(-dir.X, -dir.Z), len, width, delay))
	e.BossLines = e.BossLines or {}
	table.insert(e.BossLines, {
		From = Vector3.new(from.X, Config.ArenaOrigin.Y, from.Z),
		Dir = dir,
		Len = len,
		Half = width / 2,
		Delay = delay,
		Travel = travel,
		Damage = dmg,
		Pop = pop,
		NextPop = width / 2,
		PopEvery = math.max(5, width * 1.6),
		Hit = {},
	})
end

local function stepLines(e, dt: number)
	local list = e.BossLines
	if not list or #list == 0 then
		return
	end
	local players = living()
	for i = #list, 1, -1 do
		local L = list[i]
		L.Delay -= dt
		if L.Delay <= 0 then
			local front = L.Travel and math.min(L.Len, -L.Delay * L.Travel) or L.Len
			for _, rp in ipairs(players) do
				if not L.Hit[rp] then
					local rel = (rp.Root.Position - L.From) * FLAT
					local t = rel:Dot(L.Dir)
					if t >= -0.8 and t <= front + 0.6 and (rel - L.Dir * t).Magnitude <= L.Half + 0.6 then
						L.Hit[rp] = true
						ctx.RunManager.DamagePlayer(rp, L.Damage, e.BossData.DisplayName .. " eruption")
					end
				end
			end
			while L.NextPop <= front do
				local p = L.From + L.Dir * L.NextPop
				Fx.Warn("pop", p.X, p.Z, L.Half + 0.6, L.Pop)
				L.NextPop += L.PopEvery
			end
			if front >= L.Len then
				table.remove(list, i)
			end
		end
	end
end

-- Closing rings (the Briar Sentinel's bramble ring): a ring of radius StartRadius around
-- Pos closes in at Speed after Delay; it hits a player once where it touches them unless
-- they stand in its gap. Drawn by the client from the same numbers ("bramble").
local function closingRing(e, delay: number, gap: number)
	local A = e.BossData.Attacks.BrambleRing
	local at = Vector3.new(e.Pos.X, Config.ArenaOrigin.Y, e.Pos.Z)
	local minR = e.Radius + 1.5
	local gapHalf = math.rad(A.GapHalf)
	local g = math.floor(gap * 1000 + 0.5) / 1000
	addWarn(e, Fx.Warn("bramble", at.X, at.Z, A.StartRadius, delay, A.Speed, minR, A.Width, g, math.floor(gapHalf * 1000 + 0.5) / 1000))
	e.BossRings = e.BossRings or {}
	table.insert(e.BossRings, { Pos = at, R = A.StartRadius, MinR = minR, Speed = A.Speed, Half = A.Width / 2, Gap = g, GapHalf = gapHalf, Delay = delay, Damage = damage(A.Damage), Hit = {} })
end

local function stepRings(e, dt: number)
	local list = e.BossRings
	if not list or #list == 0 then
		return
	end
	local players = living()
	for i = #list, 1, -1 do
		local R = list[i]
		if R.Delay > 0 then
			R.Delay -= dt
		else
			R.R -= R.Speed * dt
			if R.R < R.MinR then
				table.remove(list, i)
			else
				for _, rp in ipairs(players) do
					if not R.Hit[rp] then
						local dx, dz = rp.Root.Position.X - R.Pos.X, rp.Root.Position.Z - R.Pos.Z
						local d = math.sqrt(dx * dx + dz * dz)
						if math.abs(d - R.R) <= R.Half + 0.6 then
							local off = (math.atan2(dz, dx) - R.Gap) % TAU
							if math.min(off, TAU - off) > R.GapHalf then
								R.Hit[rp] = true
								ctx.RunManager.DamagePlayer(rp, R.Damage, "Briar Sentinel bramble ring")
							end
						end
					end
				end
			end
		end
	end
end

-- Chill (the Colossus's freezing breath): walk speed x mult until the time runs out.
-- RunManager.ApplyMovement sets the normal speed; this only lowers it on top, and gives
-- it back through ApplyMovement when the chill ends (or the boss is gone).
local chilled: { [any]: { Until: number, Mult: number } } = {}

local function chill(rp, mult: number, seconds: number)
	local c = chilled[rp]
	if c then
		c.Until = math.max(c.Until, clock + seconds)
		c.Mult = math.min(c.Mult, mult)
	else
		chilled[rp] = { Until = clock + seconds, Mult = mult }
		rp.Player:SetAttribute("Chilled", true)
	end
end

local function unchill(rp)
	chilled[rp] = nil
	if rp.Player and rp.Player.Parent then
		rp.Player:SetAttribute("Chilled", nil)
	end
	if valid(rp) then
		ctx.RunManager.ApplyMovement(rp)
	end
end

local function stepChill()
	for rp, c in pairs(chilled) do
		if clock >= c.Until or not valid(rp) then
			unchill(rp)
		else
			local hum = rp.Humanoid
			if hum and hum.Parent and hum.WalkSpeed > 0 and rp.Stats then
				local want = rp.Stats.Speed * (rp.TerrainSpeedMult or 1) * c.Mult
				if hum.WalkSpeed > want + 0.05 then
					hum.WalkSpeed = want
				end
			end
		end
	end
end

local function clearChill()
	for rp in pairs(chilled) do
		unchill(rp)
	end
end

-- Briar Sentinel: root lanes toward the players (+ spread ones); thorns erupt along them.
local function rootSet(e, windup: number)
	local A = e.BossData.Attacks.RootLines
	local n = BossData.ForParty(A.Lines, A.PerExtraPlayer, A.MaxLines, partySize())
	local angles: { number } = {}
	local function free(a: number): boolean
		for _, b in ipairs(angles) do
			local d = (a - b) % TAU
			if math.min(d, TAU - d) < math.rad(28) then
				return false
			end
		end
		return true
	end
	for _, rp in ipairs(living()) do
		local to = (rp.Root.Position - e.Pos) * FLAT
		if #angles < n and to.Magnitude > 0.5 then
			local a = math.atan2(to.Z, to.X)
			if free(a) then
				table.insert(angles, a)
			end
		end
	end
	local base = #angles > 0 and angles[1] or rng:NextNumber(0, TAU)
	for k = 1, 40 do
		if #angles >= n then
			break
		end
		-- the rest fan out around the first lane, never closer than 28 degrees
		local a = base + (k % 2 == 0 and 1 or -1) * math.rad(35 + rng:NextNumber(0, 110))
		if free(a) then
			table.insert(angles, a)
		end
	end
	local dmg = damage(A.Damage)
	for _, a in ipairs(angles) do
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		lineHazard(e, e.Pos + dir * (e.Radius * 0.5), dir, A.Length, A.Width, windup, A.Travel, dmg, "thorn")
	end
	Fx.Sound("BossEmerge")
end

function Start.RootLines(e)
	local A = e.BossData.Attacks.RootLines
	e.SecondRoots = false
	rootSet(e, A.Windup)
	e.SpeedOverride = 0
	setAct(e, "Root")
	setState(e, "RootWindup", A.Windup)
end

-- Briar Sentinel: a fan of thorns at the nearest player, the same spokes each volley.
function Start.ThornVolley(e)
	local A = e.BossData.Attacks.ThornVolley
	local dir = aimDir(e)
	local mid = math.atan2(dir.Z, dir.X)
	local spread = math.rad(A.Spread)
	local angles = {}
	for i = 0, A.Count - 1 do
		local a = mid - spread / 2 + spread * i / math.max(1, A.Count - 1)
		table.insert(angles, math.floor(a * 1000 + 0.5) / 1000)
	end
	e.VolleyAngles = angles
	e.VolleyLeft = A.Volleys
	e.Dir = dir
	e.SpeedOverride = 0
	setAct(e, "Volley")
	local shown = A.Windup + (A.Volleys - 1) * A.VolleyGap + 0.35
	addWarn(e, Fx.Warn("spokes", e.Pos.X, e.Pos.Z, e.Radius + 0.5, 22, shown, angles))
	setState(e, "Volley", A.Windup)
end

-- Briar Sentinel: the bramble ring closes in on her (one gap; two rings in phase 2).
function Start.BrambleRing(e)
	local A = e.BossData.Attacks.BrambleRing
	e.RingLeft = (twist(e) == "Overgrowth" and A.TwistRings or A.Rings) - 1
	e.RingGap = rng:NextNumber(0, TAU)
	e.RingTurn = rng:NextNumber() < 0.5 and -1 or 1
	closingRing(e, A.Windup, e.RingGap)
	e.SpeedOverride = 0
	setAct(e, "Root")
	setState(e, "Bramble", A.Windup)
end

function Start.Sproutling(e)
	Start.Summon(e, "Sproutling")
end

-- Colossus: slow shockwave rings roll out of his slam, each with a turning gap.
function Start.GroundSlam(e)
	local A = e.BossData.Attacks.GroundSlam
	e.StormLeft = A.Waves - 1
	e.StormGap = rng:NextNumber(0, TAU)
	e.StormTurn = rng:NextNumber() < 0.5 and -1 or 1
	stormWave(e, A.Windup, e.StormGap, A)
	e.SpeedOverride = 0
	setAct(e, "SlamWindup")
	setState(e, "Slam", A.Windup)
end

-- Colossus: parallel ice lanes along his aim, one through the nearest player.
function Start.IceLanes(e)
	local A = e.BossData.Attacks.IceLanes
	local dir = aimDir(e)
	local right = Vector3.new(-dir.Z, 0, dir.X)
	local target = nearest(e.Pos)
	local s = target and ((target.Root.Position - e.Pos) * FLAT):Dot(right) or 0
	local j = rng:NextInteger(1, A.Lanes) -- which lane runs through the target
	local dmg = damage(A.Damage)
	for k = 1, A.Lanes do
		local off = s + (k - j) * A.Spacing
		local from = e.Pos + right * off - dir * 4
		lineHazard(e, from, dir, A.Length, A.Width, A.Windup, nil, dmg, "ice")
	end
	e.Dir = dir
	e.SpeedOverride = 0
	setAct(e, "Stomp")
	Fx.Sound("BossPound")
	setState(e, "LaneWindup", A.Windup)
end

-- Colossus: a freezing cone toward the nearest player (hurts a little, slows).
function Start.FrostBreath(e)
	local A = e.BossData.Attacks.FrostBreath
	local dir = aimDir(e)
	e.BreathDir = dir
	e.BreathHit = {}
	e.Dir = dir
	e.SpeedOverride = 0
	setAct(e, "Inhale")
	addWarn(e, Fx.Warn("gust", e.Pos.X, e.Pos.Z, math.floor(math.atan2(dir.Z, dir.X) * 1000 + 0.5) / 1000, A.Length, math.floor(math.rad(A.HalfAngle) * 1000 + 0.5) / 1000, A.Windup, A.Breath, "frost"))
	setState(e, "BreathWindup", A.Windup)
end

-- Colossus: ice shards fall on circles around the players, one after another.
function Start.ShardRain(e)
	local A = e.BossData.Attacks.ShardRain
	e.SpeedOverride = 0
	setAct(e, "ShardCall")
	setState(e, "ShardWindup", A.Windup)
end

-- Frost armour (the Colossus in phase 2): EnemySpawner.Damage lets e.Shield soak hits;
-- the body attribute "FrostArmor" shows the ice plates on the client.
local function growArmor(e)
	local F = e.BossData.FrostArmor
	if not F or e.Dying then
		return
	end
	e.Shield = e.MaxHP * F.Share
	e.FrostArmorOn = true
	e.ArmorRegrowAt = nil
	e.Part:SetAttribute("FrostArmor", true)
	Fx.Warn("pop", e.Pos.X, e.Pos.Z, e.Radius * 1.4, "frost")
end

local function stepArmor(e)
	local F = e.BossData.FrostArmor
	if not F or e.Dying then
		return
	end
	if e.FrostArmorOn then
		if e.Shield <= 0 then
			-- broken: he staggers (a free punish window); it grows back later
			e.FrostArmorOn = false
			e.ArmorRegrowAt = clock + F.Regrow
			e.Part:SetAttribute("FrostArmor", nil)
			Fx.Warn("pop", e.Pos.X, e.Pos.Z, e.Radius * 1.8, "frost")
			Fx.Ring(e.Pos, 16, Color3.fromRGB(190, 225, 255))
			Fx.Sound("BossRoar")
			ctx.RunManager.Broadcast("FROST ARMOR SHATTERED!", Color3.fromRGB(190, 225, 255), nil, { Id = "boss.armor" })
			if e.BossState ~= "Entrance" and e.BossState ~= "Roar" then
				e.SlamHit = nil
				stunned(e, F.Stun)
			end
		end
	elseif e.ArmorRegrowAt and clock >= e.ArmorRegrowAt and e.BossState == "Chase" and twist(e) == "FrostArmor" then
		growArmor(e)
		ctx.RunManager.Broadcast("THE FROST ARMOR GROWS BACK!", Color3.fromRGB(190, 225, 255), nil, { Id = "boss.armor", Class = "Critical" })
	end
end

------------------------------------------------------------------------------------------
-- Active moments
------------------------------------------------------------------------------------------

local function venomCircles(e)
	local A = e.BossData.Attacks.VenomBurst
	local n = math.min(A.MaxCircles, A.Circles + partySize() - 1)
	-- one circle right where each player stands (a small random offset), the rest close
	-- around them, so the safe ground is a short step away
	for _, p in ipairs(spotsNearPlayers(n, 0, 1.5, 8, 14, A.Radius * 1.3)) do
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

local function dropMines(e)
	local A = e.BossData.Attacks.GlimmerMines
	local n = BossData.ForParty(A.Count, A.PerExtraPlayer, A.MaxCount, partySize())
	for _, p in ipairs(spotsNearPlayers(n, 3, 6, 6, 16, A.Radius * 1.5)) do
		local id = Fx.Warn("mine", p.X, p.Z, A.Radius, A.Fuse, math.floor(e.Pos.X * 10) / 10, math.floor(e.Pos.Z * 10) / 10)
		Hazards.Strike(p, A.Radius, A.Fuse, damage(A.Damage), { Group = GROUP, Style = "glimmer", Warn = id })
	end
end

local function throwEgg(e, spot: Vector3)
	local A = e.BossData.Attacks.EggBarrage
	local dist = ((spot - e.Pos) * FLAT).Magnitude
	addWarn(e, Fx.Warn("glob", e.Pos.X, e.Pos.Z, spot.X, spot.Z, A.Flight, 6 + dist * 0.15, "egg"))
	Hazards.Strike(spot, A.Splash, A.Flight, damage(A.Damage), {
		Group = GROUP,
		Style = "acid",
		OnStrike = function()
			if not e.Alive or e.Dying then
				return
			end
			local egg = ctx.EnemySpawner.Spawn(A.Type, spot, { Force = true })
			if egg then
				egg.HatchLeft = A.Hatch
				egg.HatchCount = A.Hatchlings
				egg.WarnId = Fx.Warn("circle", spot.X, spot.Z, 2.3, A.Hatch, "hatch")
				trackObject(e, egg)
			end
		end,
	})
end

local function acidPools(e)
	local A = e.BossData.Attacks.AcidPools
	local n = BossData.ForParty(A.Count, A.PerExtraPlayer, A.MaxCount, partySize())
	local trails = twist(e) == "Trails"
	local dmg = damage(A.Damage)
	for _, p in ipairs(spotsNearPlayers(n, 0, 3, 7, 14, A.Radius * 2)) do
		Hazards.Patch(p, A.Radius, A.Fill, A.Life, A.Tick, dmg, GROUP, "acid")
		if trails then
			-- phase 2: drips of acid back toward her (smaller pools on the same timer)
			local back = (e.Pos - p) * FLAT
			if back.Magnitude > A.Radius + A.TrailSpacing then
				local dir = back.Unit
				for k = 1, A.TrailCount do
					local q = p + dir * (A.Radius + A.TrailSpacing * (k - 0.4))
					if ((q - e.Pos) * FLAT).Magnitude > e.Radius + A.TrailRadius then
						Hazards.Patch(clamp(q), A.TrailRadius, A.Fill + 0.1 * k, A.Life * 0.7, A.Tick, dmg, GROUP, "acid")
					end
				end
			end
		end
	end
	Fx.Sound("SpitterWindup")
end

local function plantBanner(e)
	local A = e.BossData.Attacks.WarBanner
	local dir = e.Dir.Magnitude > 0.1 and e.Dir.Unit or aimDir(e)
	local right = Vector3.new(-dir.Z, 0, dir.X)
	local spot = nil
	for _, side in ipairs({ right, -right, -dir }) do
		local p = clamp(e.Pos + side * (e.Radius + A.Distance), 10)
		if not ctx.EnemyAI.IsBlocked(p.X, p.Z, 2.5) then
			spot = p
			break
		end
	end
	spot = spot or freeSpot(e.Pos, e.Radius + A.Distance, 2.5)
	if not spot then
		return false
	end
	local banner = ctx.EnemySpawner.Spawn(A.Type, spot, { Force = true, HP = math.max(40, e.MaxHP * A.HPShare) })
	if not banner then
		return false
	end
	banner.RallyRadius = A.Radius
	banner.RallySpeed = A.SpeedMult
	banner.RallyDamage = A.DamageMult
	banner.WarnId = Fx.Warn("aura", spot.X, spot.Z, A.Radius, 900) -- cleared with the banner
	trackObject(e, banner)
	e.Part:SetAttribute("BannerOut", true)
	Fx.Warn("pop", spot.X, spot.Z, 4, "slam")
	Fx.Sound("BossBanner")
	for k = 1, A.Escort do
		local a = k * TAU / math.max(1, A.Escort) + rng:NextNumber(0, 1)
		local p = clamp(spot + Vector3.new(math.cos(a) * 4, 0, math.sin(a) * 4))
		if not ctx.EnemyAI.IsBlocked(p.X, p.Z, 1.5) then
			ctx.EnemySpawner.Spawn("Skeleton", p)
		end
	end
	ctx.RunManager.Broadcast("WAR BANNER! DESTROY IT TO BREAK THE RALLY!", Color3.fromRGB(255, 190, 110), nil, { Id = "boss.banner", Class = "Critical" })
	return true
end

-- The start function of an attack name: its own, or the move its BossData entry names
-- ("Move = Summon" for BroodCall / Sproutling), which is told the attack's name.
local function startOf(e, name: string): ((any) -> ())?
	local fn = Start[name]
	if fn then
		return fn
	end
	local A = e.BossData.Attacks[name]
	local move = A and A.Move and Start[A.Move]
	if move then
		return function(boss)
			move(boss, name)
		end
	end
	return nil
end

local function nextAttack(e)
	table.clear(e.BossWarns) -- the last attack's telegraphs are over by now
	local cycle = phase(e).Cycle
	e.BossCycle = (e.BossCycle % #cycle) + 1
	local name = cycle[e.BossCycle]
	e.BossFollowup = phase(e).FollowUps and phase(e).FollowUps[name] or nil
	local fn = startOf(e, name)
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
-- States (one handler per BossState; each runs every frame while it is current)
------------------------------------------------------------------------------------------

local State: { [string]: (any, number) -> () } = {}

State.Entrance = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		setVulnerable(e, true)
		chase(e, e.BossData.Entrance.Grace) -- no attack for Grace seconds after it is up
	end
end

State.Dying = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		ctx.EnemySpawner.Kill(e, valid(e.Killer) and e.Killer or nil)
	end
end

State.Chase = function(e, _dt)
	e.SpeedOverride = nil
	if e.PendingPhase then
		e.PhaseIndex = e.PendingPhase
		e.PendingPhase = nil
		publishPhase(e)
		local p = phase(e)
		if p.Message then
			ctx.RunManager.Broadcast(p.Message, Color3.fromRGB(255, 90, 80), true, { Id = "big:" .. string.lower(p.Message), Lane = "Headline", Class = "Critical" })
		end
		Fx.Sound("BossRoar")
		Fx.Ring(e.Pos, 26, Color3.fromRGB(255, 60, 70))
		if p.Twist == "FrostArmor" then
			growArmor(e)
		end
		e.SpeedOverride = 0
		setAct(e, "Roar")
		setState(e, "Roar", p.Roar or 1)
	elseif e.BossTimer <= 0 then
		nextAttack(e)
	end
end

State.Roar = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		chase(e, paced(e, e.BossData.Chase) * 0.5)
	end
end

State.Recover = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		local followup = e.BossFollowup
		e.BossFollowup = nil
		local fn = followup and startOf(e, followup) or nil
		if fn and not e.PendingPhase and #living() > 0 then
			-- Keep the complete punish window, then telegraph the follow-up normally.
			e.Harmless = false
			fn(e)
		else
			chase(e, paced(e, e.BossData.Chase))
		end
	end
end

-- lane rushes ----------------------------------------------------------------------------

State.ChargeWindup = function(e, _dt)
	e.SpeedOverride = 0
	e.Dir = e.ChargeDir
	if e.BossTimer <= 0 then
		setAct(e, e.ChargeName == "Dive" and "Swoop" or "Charge")
		setState(e, "Charging", e.ChargeTime or e.BossData.Attacks[e.ChargeName].Duration)
	end
end

State.Charging = function(e, _dt)
	local name = e.ChargeName or "Charge"
	local A = e.BossData.Attacks[name]
	e.Dir = e.ChargeDir
	e.SpeedOverride = A.Speed
	if e.BossTimer > 0 then
		return
	end
	e.SpeedOverride = 0
	if name == "Charge" and twist(e) == "DoubleCharge" and not e.SecondCharge and #living() > 0 then
		e.SecondCharge = true
		Start.Rush(e, "Charge", A.SecondWindup)
		return
	end
	e.SecondCharge = false
	if name == "HornCharge" then
		if e.ChargeBlocked then
			-- the horn is stuck in a tree / rock / the fence: a long free punish window
			local tip = e.Pos + e.ChargeDir * e.Radius
			Fx.Warn("pop", tip.X, tip.Z, 6, "slam")
			Fx.Ring(tip, 10, Color3.fromRGB(200, 170, 120))
			Fx.Sound("BossPound")
			stunned(e, paced(e, A.Stuck), "Stuck")
		else
			setAct(e, nil)
			recover(e, paced(e, A.Recover))
		end
	elseif name == "Dive" then
		Fx.Warn("pop", e.Pos.X, e.Pos.Z, e.Radius * 1.6, "dust")
		stunned(e, paced(e, A.Recover), "Grounded")
	else
		stunned(e, paced(e, A.Recover))
	end
end

-- Queen ---------------------------------------------------------------------------------

State.VenomWindup = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		venomCircles(e)
		setState(e, "VenomHold", e.BossData.Attacks.VenomBurst.Fill)
	end
end

State.VenomHold = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		setAct(e, nil)
		recover(e, paced(e, e.BossData.Attacks.VenomBurst.Recover))
	end
end

State.Ring = function(e, _dt)
	local A = e.BossData.Attacks.StingerRing
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		fireRing(e)
		e.RingWave += 1
		if e.RingWave >= A.Waves then
			setAct(e, nil)
			recover(e, paced(e, A.Recover))
		else
			e.BossTimer = A.WaveGap
		end
	end
end

State.Dive = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		setAct(e, "Burrow")
		setVulnerable(e, false)
		e.Harmless = true
		setState(e, "Burrowed", e.BossData.Attacks.Burrow.Track)
	end
end

State.Burrowed = function(e, dt)
	local B = e.BossData.Attacks.Burrow
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
end

State.Surface = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		setVulnerable(e, true)
		stunned(e, paced(e, e.BossData.Attacks.Burrow.Recover))
	end
end

State.SummonWindup = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		local typeId = e.SummonType or "Skeleton"
		for _, p in ipairs(e.SummonSpots or {}) do
			ctx.EnemySpawner.Spawn(typeId, p)
		end
		e.SummonSpots = nil
		Fx.Sound("BossSummon")
		chase(e, paced(e, e.BossData.Chase))
	end
end

-- Matriarch -----------------------------------------------------------------------------

State.Storm = function(e, _dt)
	local A = e.BossData.Attacks.DustStorm
	e.SpeedOverride = 0
	if e.BossTimer > 0 then
		return
	end
	if (e.StormLeft or 0) > 0 then
		-- the next wave: its gap turns, and its marker shows at once
		e.StormLeft -= 1
		e.StormGap += math.rad(A.TurnGap) * (e.StormTurn or 1)
		stormWave(e, A.WaveGap, e.StormGap)
		e.BossTimer = A.WaveGap
		return
	end
	setAct(e, nil)
	recover(e, paced(e, A.Recover))
end

State.MineWindup = function(e, _dt)
	local A = e.BossData.Attacks.GlimmerMines
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		dropMines(e)
		setAct(e, nil)
		recover(e, paced(e, A.Recover))
	end
end

State.GustWindup = function(e, _dt)
	local A = e.BossData.Attacks.WingGust
	e.SpeedOverride = 0
	e.Dir = e.GustDir or e.Dir
	if e.BossTimer <= 0 then
		setAct(e, "Gust")
		Fx.Sound("BossGust")
		setState(e, "Gusting", A.Blow)
	end
end

State.Gusting = function(e, dt)
	local A = e.BossData.Attacks.WingGust
	e.SpeedOverride = 0
	local dir = e.GustDir or Vector3.new(0, 0, 1)
	local cosHalf = math.cos(math.rad(A.HalfAngle))
	for _, rp in ipairs(living()) do
		local to = (rp.Root.Position - e.Pos) * FLAT
		local d = to.Magnitude
		if d > 0.5 and d <= A.Length + 1 and to.Unit:Dot(dir) >= cosHalf then
			pushPlayer(rp, to.Unit * A.Push * dt)
		end
	end
	if e.BossTimer <= 0 then
		Fx.Warn("pop", e.Pos.X + dir.X * A.Length * 0.6, e.Pos.Z + dir.Z * A.Length * 0.6, A.Length * 0.4, "gust")
		setAct(e, nil)
		recover(e, paced(e, A.Recover))
	end
end

-- Warlord -------------------------------------------------------------------------------

State.PoundWindup = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		setAct(e, "Pound")
		Fx.Warn("pop", e.Pos.X, e.Pos.Z, e.Radius * 1.5, "pound")
		setState(e, "Pounding", poundBands(e, e.SecondPound == true) + 0.05)
	end
end

State.Pounding = function(e, _dt)
	local A = e.BossData.Attacks.GroundPound
	e.SpeedOverride = 0
	if e.BossTimer > 0 then
		return
	end
	if twist(e) == "DoublePound" and not e.SecondPound and #living() > 0 then
		-- phase 2: he rears again and the bands come back from the outside in
		e.SecondPound = true
		setAct(e, "Rear")
		setState(e, "PoundWindup", A.SecondWindup)
		return
	end
	setAct(e, nil)
	recover(e, paced(e, A.Recover))
end

State.PlantWindup = function(e, _dt)
	local A = e.BossData.Attacks.WarBanner
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		if plantBanner(e) then
			setAct(e, nil)
			recover(e, paced(e, A.Recover))
		else
			Start.Summon(e) -- nowhere to plant it: call warriors instead
		end
	end
end

-- Hive Mother ---------------------------------------------------------------------------

State.Heave = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		e.ThrowIndex = 0
		setState(e, "Throwing", 0) -- the first egg flies next frame, then every Stagger
	end
end

State.Throwing = function(e, _dt)
	local A = e.BossData.Attacks.EggBarrage
	e.SpeedOverride = 0
	if e.BossTimer > 0 then
		return
	end
	local list = e.Throws or {}
	e.ThrowIndex = (e.ThrowIndex or 0) + 1
	local spot = list[e.ThrowIndex]
	if spot then
		throwEgg(e, spot)
		e.BossTimer = A.Stagger
	else
		e.Throws = nil
		setAct(e, nil)
		recover(e, paced(e, A.Recover))
	end
end

State.SpewWindup = function(e, _dt)
	local A = e.BossData.Attacks.AcidPools
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		acidPools(e)
		setAct(e, nil)
		recover(e, paced(e, A.Recover))
	end
end

-- Briar Sentinel -------------------------------------------------------------------------

State.RootWindup = function(e, _dt)
	local A = e.BossData.Attacks.RootLines
	e.SpeedOverride = 0
	if e.BossTimer > 0 then
		return
	end
	if twist(e) == "Overgrowth" and not e.SecondRoots and #living() > 0 then
		-- phase 2: the second set shows as the first one erupts
		e.SecondRoots = true
		rootSet(e, A.SecondWindup)
		setState(e, "RootWindup", A.SecondWindup)
		return
	end
	setAct(e, "Rooted")
	e.RootedRecover = A.Recover
	setState(e, "Rooted", A.Length / A.Travel)
end

State.Rooted = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		setAct(e, nil)
		recover(e, paced(e, e.RootedRecover or 1))
	end
end

State.Volley = function(e, _dt)
	local A = e.BossData.Attacks.ThornVolley
	e.SpeedOverride = 0
	if e.BossTimer > 0 then
		return
	end
	setAct(e, "Fling")
	for _, a in ipairs(e.VolleyAngles or {}) do
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		ctx.WeaponSystem.SpawnHostile(e.Pos + dir * e.Radius, dir, A.Speed, damage(A.Damage), A.ProjectileRadius, A.Life, STINGER_VISUAL)
	end
	e.VolleyLeft = (e.VolleyLeft or 1) - 1
	if e.VolleyLeft > 0 then
		e.BossTimer = A.VolleyGap
	else
		setAct(e, nil)
		recover(e, paced(e, A.Recover))
	end
end

State.Bramble = function(e, _dt)
	local A = e.BossData.Attacks.BrambleRing
	e.SpeedOverride = 0
	if e.BossTimer > 0 then
		return
	end
	if (e.RingLeft or 0) > 0 then
		-- the next ring: its gap turns, and it shows at once
		e.RingLeft -= 1
		e.RingGap += math.rad(A.TurnGap) * (e.RingTurn or 1)
		closingRing(e, A.RingGap, e.RingGap)
		e.BossTimer = A.RingGap
		return
	end
	-- she stays rooted while the last ring closes (a free window for the brave)
	setAct(e, "Rooted")
	e.RootedRecover = A.Recover
	setState(e, "Rooted", (A.StartRadius - e.Radius - 1.5) / A.Speed)
end

-- Frostbound Colossus ---------------------------------------------------------------------

State.Slam = function(e, _dt)
	local A = e.BossData.Attacks.GroundSlam
	e.SpeedOverride = 0
	if e.BossTimer > 0 then
		return
	end
	if not e.SlamHit then
		e.SlamHit = true
		setAct(e, "Slam")
		Fx.Warn("pop", e.Pos.X, e.Pos.Z, e.Radius * 1.6, "frost")
		Fx.Sound("BossPound")
	end
	if (e.StormLeft or 0) > 0 then
		e.StormLeft -= 1
		e.StormGap += math.rad(A.TurnGap) * (e.StormTurn or 1)
		stormWave(e, A.WaveGap, e.StormGap, A)
		e.BossTimer = A.WaveGap
		return
	end
	e.SlamHit = nil
	setAct(e, nil)
	recover(e, paced(e, A.Recover))
end

State.LaneWindup = function(e, _dt)
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		setAct(e, nil)
		recover(e, paced(e, e.BossData.Attacks.IceLanes.Recover))
	end
end

State.BreathWindup = function(e, _dt)
	local A = e.BossData.Attacks.FrostBreath
	e.SpeedOverride = 0
	e.Dir = e.BreathDir or e.Dir
	if e.BossTimer <= 0 then
		setAct(e, "Breathe")
		Fx.Sound("BossGust")
		setState(e, "Breathing", A.Breath)
	end
end

State.Breathing = function(e, _dt)
	local A = e.BossData.Attacks.FrostBreath
	e.SpeedOverride = 0
	local dir = e.BreathDir or Vector3.new(0, 0, 1)
	e.Dir = dir
	local cosHalf = math.cos(math.rad(A.HalfAngle))
	local hit = e.BreathHit or {}
	for _, rp in ipairs(living()) do
		local to = (rp.Root.Position - e.Pos) * FLAT
		local d = to.Magnitude
		if d > 0.5 and d <= A.Length + 0.8 and to.Unit:Dot(dir) >= cosHalf and clock >= (hit[rp] or 0) then
			hit[rp] = clock + A.Tick
			ctx.RunManager.DamagePlayer(rp, damage(A.Damage), "Frostbound Colossus freezing breath")
			chill(rp, A.Chill, A.ChillTime)
		end
	end
	if e.BossTimer <= 0 then
		e.BreathHit = nil
		setAct(e, nil)
		recover(e, paced(e, A.Recover))
	end
end

State.ShardWindup = function(e, _dt)
	local A = e.BossData.Attacks.ShardRain
	e.SpeedOverride = 0
	if e.BossTimer <= 0 then
		local n = BossData.ForParty(A.Count, A.PerExtraPlayer, A.MaxCount, partySize())
		for i, p in ipairs(spotsNearPlayers(n, 0, 2, 5, 13, A.Radius * 1.7)) do
			Hazards.Strike(p, A.Radius, A.Fall + (i - 1) * A.Stagger, damage(A.Damage), { Group = GROUP, Style = "frost" })
		end
		Fx.Sound("BossMine")
		setAct(e, nil)
		recover(e, paced(e, A.Recover))
	end
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- The boss just spawned (EnemySpawner.SpawnBoss): start the entrance.
function BossAI.Begin(e, data: any?)
	local boss = data or BossData.Get(Config.Boss.First)
	e.BossData = boss
	e.PhaseIndex = 1
	e.PendingPhase = nil
	e.BossCycle = 0
	e.BossWarns = {}
	e.BossObjects = nil
	e.SecondCharge = false
	e.SecondPound = false
	e.SecondRoots = false
	e.SlamHit = nil
	e.BossLines = nil
	e.BossRings = nil
	e.FrostArmorOn = false
	e.ArmorRegrowAt = nil
	e.HitSum = 0
	e.HitAt = clock
	e.PulseReady = clock + 4
	e.Dying = false
	e.Harmless = true
	setVulnerable(e, false)
	e.SpeedOverride = 0
	setAct(e, "Emerge")
	setState(e, "Entrance", boss.Entrance.Seconds)
	local state = Remotes.State()
	state:SetAttribute("BossName", boss.DisplayName)
	state:SetAttribute("BossId", boss.Id)
	state:SetAttribute("BossIntro", boss.Entrance.Seconds)
	publishPhase(e)
	if boss.Entrance.From == "Sky" then
		Fx.Warn("circle", e.Pos.X, e.Pos.Z, e.Radius + 2, boss.Entrance.Seconds, "pulse")
		Fx.Warn("pop", e.Pos.X, e.Pos.Z, boss.Entrance.DustRadius * 0.6, "gust")
	else
		Fx.Warn("pop", e.Pos.X, e.Pos.Z, boss.Entrance.DustRadius, "dust")
		Fx.Warn("circle", e.Pos.X, e.Pos.Z, e.Radius + 2, boss.Entrance.Seconds, "burrow")
	end
end

-- Removes the boss's hazards, telegraphs, stingers, banner and eggs at once.
function BossAI.ClearHazards(e)
	Hazards.Clear(GROUP)
	if e and e.BossWarns then
		for _, id in ipairs(e.BossWarns) do
			Fx.ClearWarn(id)
		end
		table.clear(e.BossWarns)
	end
	clearObjects(e)
	if e then
		e.BossFollowup = nil
		e.BossLines = nil
		e.BossRings = nil
		if e.FrostArmorOn then
			e.FrostArmorOn = false
			e.Shield = 0
		end
		e.ArmorRegrowAt = nil
	end
	if e and e.Part then
		e.Part:SetAttribute("BannerOut", nil)
		e.Part:SetAttribute("FrostArmor", nil)
	end
	clearChill()
	ctx.WeaponSystem.ClearHostile()
end

-- Its HP reached 0 (EnemySpawner.Damage): the collapse, then the real kill.
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

-- A hit landed (EnemySpawner.Damage, HP still above 0): the Hive Mother pulses when a
-- lot of damage arrives quickly (BossData OnHit), telegraphed like every attack.
function BossAI.OnDamaged(e, amount: number)
	local H = e.BossData and e.BossData.OnHit
	if not H or e.Dying or e.BossState == "Entrance" then
		return
	end
	-- damage within the window, fading linearly
	local since = clock - (e.HitAt or clock)
	e.HitAt = clock
	e.HitSum = math.max(0, (e.HitSum or 0) * (1 - since / H.Window)) + amount
	if e.HitSum >= e.MaxHP * H.Share and clock >= (e.PulseReady or 0) then
		e.HitSum = 0
		e.PulseReady = clock + H.Cooldown
		local at = Vector3.new(e.Pos.X, Config.ArenaOrigin.Y, e.Pos.Z)
		Hazards.Strike(at, e.Radius + H.Radius, H.Warn, damage(H.Damage), { Group = GROUP, Style = "pulse" })
	end
end

function BossAI.Step(e, dt: number)
	if not e.BossData then
		BossAI.Begin(e)
	end
	clock += dt
	e.BossTimer -= dt
	local data = e.BossData

	-- phase thresholds (applied at the next Chase so an attack is never cut in half)
	if not e.Dying and e.BossState ~= "Entrance" and e.PhaseIndex < #data.Phases then
		local want = BossData.PhaseFor(data, e.HP / math.max(1, e.MaxHP))
		if want > e.PhaseIndex then
			e.PendingPhase = want
		end
	end
	-- line / closing-ring hazards, the breath's chill, the Colossus's frost armour
	if not e.Dying then
		stepLines(e, dt)
		stepRings(e, dt)
		stepArmor(e)
	end
	stepChill()
	-- the Warlord's banner fell: it is back on his back
	if e.Part:GetAttribute("BannerOut") and liveObjects(e, "WarBanner") == 0 then
		e.Part:SetAttribute("BannerOut", nil)
	end

	local handler = State[e.BossState]
	if handler then
		handler(e, dt)
	else
		chase(e, data.Chase)
	end
end

function BossAI.Init(c)
	ctx = c
end

return BossAI
