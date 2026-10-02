--[[
	EnemyAI.lua
	Moves every enemy from ONE Heartbeat loop (no per-enemy scripts, no Humanoids,
	no Touched events).

	Per frame, for every living enemy:
	  * "Think" (only for 1/ThinkChunks of the enemies each frame): pick the nearest
	    living player, steer around obstacles with a short raycast, add a separation
	    push from neighbours (via the enemy spatial grid), add bat wobble.
	  * Integrate movement + knockback, push out of obstacle shapes, clamp to the fence.
	  * Distance-based contact damage against the (max 4) players.
	  * Recycle enemies left far behind back to the screen edge.
	Then all parts move with a single workspace:BulkMoveTo call, and the enemy grid used
	by WeaponSystem hit detection is rebuilt.

	Behaviours with a readable rhythm (anticipation → telegraph → active → recovery), each
	enemy's current one published as the body attribute "Act" for the client's poses:
	  Ranged (Spitter)   keeps MinRange-MaxRange away, stops, "Windup" (swells; an acid
	                     circle marks the landing spot), lobs a glob (Hazards strike)
	  Lunge (Rhino)      "Windup" (rears up; a short lane on the floor) → "Lunge" → "Recover"
	  Fuse (Bomb Tick)   next to a player: "Fuse" (swells and blinks inside its blast ring),
	                     then explodes where it stands; killing it first defuses it
	  Burning elites     drop fire patches behind them while walking (Hazards patches)
	  Burrow (Burrower)  "Tunnel" underground (a dust trail on clients; untargetable,
	                     invulnerable, harmless) toward the nearest player → "Surface" (a
	                     circle warns where it bursts out, it holds still) → bursts out
	                     (Hazards strike), "Popped" (a short daze), then a normal melee bug
	  Support (Healer)   keeps its distance like a Spitter; "Channel" (glows) → a green pulse
	                     heals nearby enemies (never bosses or stationary things)
	  Static             nests, the War Banner, Brood Eggs never move. A nest ("Pulse") warns
	                     at its openings, then mites climb out; a Brood Egg ("Incubate")
	                     hatches Mites when its timer ends; the War Banner rallies beetles in
	                     its zone (faster, harder contact hits; body attribute "Rallied")
	The boss runs BossAI (data in BossData). Hazards (strikes / patches / waves) step here too.
	Fresh spawns are harmless for Config.Enemies.SpawnGrace (they fade in on clients);
	Harmless / Untargetable enemies (the Queen's entrance, burrow, collapse) neither touch
	players nor enter the hit grid.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local SpatialGrid = require(script.Parent.SpatialGrid)
local Fx = require(script.Parent.Fx)
local Hazards = require(script.Parent.Hazards)
local BossAI = require(script.Parent.BossAI)

local EnemyAI = {}

local ctx
local rng = Random.new()
local UP = Vector3.yAxis
local FLAT = Vector3.new(1, 0, 1)
local PLAYER_RADIUS = 1.2

local obstacleGrid = SpatialGrid.new(Config.Projectiles.CellSize)
local rayParams: RaycastParams? = nil
local frame = 0
local clock = 0
local partsBuf: { BasePart } = {}
local cframesBuf: { CFrame } = {}
local movedBuf: { any } = {}
local queryBuf = {}
local obstacleBuf = {}

------------------------------------------------------------------------------------------
-- Obstacles
------------------------------------------------------------------------------------------

-- Called by RunManager after MapBuilder.BuildArena.
function EnemyAI.SetArena(arena)
	obstacleGrid:Clear()
	if not arena then
		rayParams = nil
		return
	end
	for _, ob in ipairs(arena.Obstacles) do
		if ob.Kind == "Circle" then
			obstacleGrid:InsertBox(ob, ob.Pos.X - ob.Radius, ob.Pos.Z - ob.Radius, ob.Pos.X + ob.Radius, ob.Pos.Z + ob.Radius)
		else
			obstacleGrid:InsertBox(ob, ob.MinX, ob.MinZ, ob.MaxX, ob.MaxZ)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { arena.ObstacleFolder }
	rayParams = params
end

-- True if a circle (x, z, r) overlaps any obstacle.
function EnemyAI.IsBlocked(x: number, z: number, r: number): boolean
	local n = obstacleGrid:QueryCells(x, z, r, obstacleBuf)
	for i = 1, n do
		local ob = obstacleBuf[i]
		if ob.Kind == "Circle" then
			local dx, dz = x - ob.Pos.X, z - ob.Pos.Z
			local rr = ob.Radius + r
			if dx * dx + dz * dz < rr * rr then
				return true
			end
		elseif x > ob.MinX - r and x < ob.MaxX + r and z > ob.MinZ - r and z < ob.MaxZ + r then
			return true
		end
	end
	return false
end

-- Pushes a ground position out of any obstacle it overlaps.
local function pushOut(pos: Vector3, r: number): Vector3
	local x, z = pos.X, pos.Z
	local n = obstacleGrid:QueryCells(x, z, r, obstacleBuf)
	for i = 1, n do
		local ob = obstacleBuf[i]
		if ob.Kind == "Circle" then
			local dx, dz = x - ob.Pos.X, z - ob.Pos.Z
			local rr = ob.Radius + r
			local d2 = dx * dx + dz * dz
			if d2 < rr * rr then
				local d = math.sqrt(d2)
				if d < 1e-3 then
					dx, dz, d = 1, 0, 1
				end
				x = ob.Pos.X + dx / d * rr
				z = ob.Pos.Z + dz / d * rr
			end
		else
			local minX, maxX, minZ, maxZ = ob.MinX - r, ob.MaxX + r, ob.MinZ - r, ob.MaxZ + r
			if x > minX and x < maxX and z > minZ and z < maxZ then
				-- leave along the shallowest side
				local left, right, back, front = x - minX, maxX - x, z - minZ, maxZ - z
				local m = math.min(left, right, back, front)
				if m == left then
					x = minX
				elseif m == right then
					x = maxX
				elseif m == back then
					z = minZ
				else
					z = maxZ
				end
			end
		end
	end
	return Vector3.new(x, pos.Y, z)
end

-- Nearest spot outside every obstacle footprint (RunManager uses it to move a player who
-- jumped on top of a low obstacle, where melee enemies cannot reach).
function EnemyAI.PushOut(pos: Vector3, r: number): Vector3
	return pushOut(pos, r)
end

------------------------------------------------------------------------------------------
-- Thinking
------------------------------------------------------------------------------------------

local function nearestPlayer(pos: Vector3, runPlayers)
	local best, bestD2 = nil, math.huge
	for _, rp in ipairs(runPlayers) do
		if rp.Alive and rp.Root then
			local d = rp.Root.Position - pos
			local d2 = d.X * d.X + d.Z * d.Z
			if d2 < bestD2 then
				best, bestD2 = rp, d2
			end
		end
	end
	return best, math.sqrt(bestD2)
end

local function think(e, runPlayers)
	local target = nearestPlayer(e.Pos, runPlayers)
	e.Target = target
	if not target then
		e.Dir = Vector3.zero
		e.Sep = Vector3.zero
		return
	end
	local to = (target.Root.Position - e.Pos) * FLAT
	if to.Magnitude < 0.1 then
		e.Dir = Vector3.zero
		return
	end
	local desired = to.Unit

	if e.Erratic > 0 then
		local angle = math.sin(clock * 3 + e.Phase) * e.Erratic
		desired = CFrame.fromAxisAngle(UP, angle):VectorToWorldSpace(desired)
	end

	if not e.Ghost and rayParams then
		local origin = e.Pos + Vector3.new(0, 2.5, 0)
		local hit = workspace:Raycast(origin, desired * (Config.Enemies.AvoidRayLength + e.Radius), rayParams)
		if hit then
			local tangent = hit.Normal:Cross(UP) * FLAT
			if tangent.Magnitude > 1e-3 then
				tangent = tangent.Unit
				if tangent:Dot(desired) < 0 then
					tangent = -tangent
				end
				local steer = tangent * Config.Enemies.AvoidTurnStrength + desired * 0.4 + (hit.Normal * FLAT) * 0.3
				if steer.Magnitude > 1e-3 then
					desired = steer.Unit
				end
			end
		end
	end
	e.Dir = desired

	-- Separation from neighbours (grid is from the previous frame, good enough).
	local sep = Vector3.zero
	if not e.Ghost then
		local n = ctx.EnemySpawner.Grid:QueryCircle(e.Pos.X, e.Pos.Z, e.Radius * Config.Enemies.SeparationRadius, queryBuf)
		for i = 1, n do
			local o = queryBuf[i]
			if o ~= e and not o.Ghost then
				local away = (e.Pos - o.Pos) * FLAT
				local d = away.Magnitude
				local minD = (e.Radius + o.Radius) * Config.Enemies.SeparationRadius
				if d < minD then
					if d < 1e-3 then
						away = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
						d = math.max(away.Magnitude, 1e-3)
					end
					sep += away / d * ((minD - d) / minD)
				end
			end
		end
	end
	e.Sep = sep
end

------------------------------------------------------------------------------------------
-- Behaviours (ranged, lunge, fuse, burning affix)
------------------------------------------------------------------------------------------

local setAct -- EnemySpawner.SetAct (bound in Init)

-- Spawns `count` of `typeId` at the given floor spots (cycled), respecting MaxLive.
-- Returns the enemies made.
local function spawnAt(typeId: string, spots: { Vector3 }, count: number): { any }
	local made = {}
	for k = 1, count do
		local p = spots[(k - 1) % math.max(1, #spots) + 1]
		if p then
			local e = ctx.EnemySpawner.Spawn(typeId, p)
			if e then
				table.insert(made, e)
			end
		end
	end
	return made
end

-- Burrower: tunnel → surface warning → burst out → fights as a normal melee bug.
local function behaveBurrow(e, dt: number, to: Vector3?, dist: number)
	local B = e.Def.Burrow
	local act = e.Act
	if act == nil and e.Tunnel == nil then
		-- just spawned: it starts underground
		e.Tunnel = true
		e.Untargetable = true
		e.Invulnerable = true
		e.Harmless = true
		e.Ghost = true -- underground: no obstacles
		setAct(e, "Tunnel", B.MaxTunnel)
		return
	end
	if act == "Tunnel" then
		e.ActTimer -= dt
		e.SpeedOverride = B.TunnelSpeed
		if (to and dist <= B.SurfaceRange) or e.ActTimer <= 0 then
			-- the circle shows where it bursts out; it holds still under it
			e.SpeedOverride = 0
			e.PinPos = e.Pos
			local at = Vector3.new(e.Pos.X, Config.ArenaOrigin.Y, e.Pos.Z)
			Hazards.Strike(at, B.Radius, B.Warn, B.Damage * (e.DmgScale or 1), { Style = "burrow" })
			setAct(e, "Surface", B.Warn)
		end
	elseif act == "Surface" then
		e.ActTimer -= dt
		e.SpeedOverride = 0
		if e.ActTimer <= 0 then
			e.Tunnel = false
			e.Untargetable = false
			e.Invulnerable = false
			e.Ghost = e.Def.Ghost == true
			e.PinPos = nil
			setAct(e, "Popped", 0.6)
		end
	elseif act == "Popped" then
		e.ActTimer -= dt
		e.SpeedOverride = 0
		if e.ActTimer <= 0 then
			e.Harmless = false
			e.SpeedOverride = nil
			setAct(e, nil)
		end
	else
		e.SpeedOverride = nil
	end
end

-- Healer: hangs back, glows, then a green pulse heals nearby enemies.
local function behaveSupport(e, dt: number, to: Vector3?, dist: number)
	local S = e.Def.Support
	if e.Act == "Channel" then
		e.ActTimer -= dt
		e.SpeedOverride = 0
		if to and dist > 0.1 then
			e.Face = (to :: Vector3).Unit
		end
		if e.ActTimer <= 0 then
			local n = ctx.EnemySpawner.Grid:QueryCircle(e.Pos.X, e.Pos.Z, S.Radius, queryBuf)
			for i = 1, n do
				local o = queryBuf[i]
				if o.Alive and not o.Boss and not o.Def.Static and o.HP < o.MaxHP then
					o.HP = math.min(o.MaxHP, o.HP + o.MaxHP * S.HealShare)
				end
			end
			Fx.Warn("pop", e.Pos.X, e.Pos.Z, S.Radius, "heal")
			Fx.Sound("HealPulse")
			e.HealTimer = S.Every
			e.SpeedOverride = nil
			setAct(e, nil)
		end
		return
	end
	e.HealTimer = (e.HealTimer or S.Every * (0.5 + rng:NextNumber() * 0.5)) - dt
	e.SpeedOverride = nil
	if to and dist > 0.1 then
		local dir = (to :: Vector3).Unit
		if dist < S.MinRange - 3 then
			e.Dir = -dir -- too close: back away, still facing the player
			e.SpeedOverride = e.Speed * 0.8
			e.Face = dir
		elseif dist <= S.MaxRange then
			e.SpeedOverride = 0
			e.Face = dir
		end
	end
	if e.HealTimer <= 0 and e.SpawnGrace <= 0 then
		setAct(e, "Channel", S.Windup)
	end
end

-- The two openings of a nest (model local -Z and -X), as floor points just outside it.
local function nestSpots(e): { Vector3 }
	local look = e.StaticFace or Vector3.new(0, 0, -1)
	local side = Vector3.new(look.Z, 0, -look.X)
	local r = e.Radius + 1.8
	local out = {}
	for _, d in ipairs({ look, side }) do
		local x, z = ctx.EnemySpawner.ClampToArena(e.Pos.X + d.X * r, e.Pos.Z + d.Z * r, 4)
		table.insert(out, Vector3.new(x, Config.ArenaOrigin.Y, z))
	end
	return out
end

-- Living enemies in a tracked list ({ e, uid }), pruning the dead / recycled ones.
local function liveIn(list: { any }): number
	for i = #list, 1, -1 do
		local item = list[i]
		if not (item[1].Alive and item[1].Uid == item[2]) then
			table.remove(list, i)
		end
	end
	return #list
end

-- Nests, Brood Eggs and the War Banner: they stand still and do their one job.
local function behaveStatic(e, dt: number)
	local def = e.Def
	e.SpeedOverride = 0
	e.Face = e.StaticFace
	if def.Spawner then
		local S = def.Spawner
		e.SpawnTimer = (e.SpawnTimer or S.Every * 0.6) - dt
		if e.Act ~= "Pulse" and e.SpawnTimer <= S.Warn then
			local children = e.Children or {}
			e.Children = children
			if liveIn(children) < S.MaxChildren then
				e.NestSpots = nestSpots(e)
				for _, p in ipairs(e.NestSpots) do
					Fx.Warn("circle", p.X, p.Z, 1.7, math.max(0.1, e.SpawnTimer), "nest")
				end
				setAct(e, "Pulse", e.SpawnTimer)
			else
				e.SpawnTimer = S.Every -- full: wait for the next cycle
			end
		end
		if e.Act == "Pulse" and e.SpawnTimer <= 0 then
			local children = e.Children or {}
			e.Children = children
			local room = math.max(0, S.MaxChildren - liveIn(children))
			for _, m in ipairs(spawnAt(S.Type, e.NestSpots or nestSpots(e), math.min(S.Count, room))) do
				table.insert(children, { m, m.Uid })
				e.SpawnedCount = (e.SpawnedCount or 0) + 1
			end
			e.NestSpots = nil
			e.SpawnTimer = S.Every
			setAct(e, nil)
		end
	elseif def.Hatch then
		local H = def.Hatch
		if e.Act ~= "Incubate" then
			e.HatchLeft = e.HatchLeft or H.Seconds
			setAct(e, "Incubate", e.HatchLeft)
		end
		e.HatchLeft = (e.HatchLeft or H.Seconds) - dt
		if e.HatchLeft <= 0 then
			local count = e.HatchCount or H.Count
			local spots = {}
			for k = 1, count do
				local a = k * math.pi * 2 / count + rng:NextNumber(0, 1)
				local x, z = ctx.EnemySpawner.ClampToArena(e.Pos.X + math.cos(a) * 2.2, e.Pos.Z + math.sin(a) * 2.2, 4)
				table.insert(spots, Vector3.new(x, Config.ArenaOrigin.Y, z))
			end
			Fx.Warn("pop", e.Pos.X, e.Pos.Z, 2, "hatch")
			ctx.EnemySpawner.Despawn(e) -- hatched: the shell is gone (no reward)
			spawnAt(H.Type, spots, count)
		end
	elseif def.Rally then
		e.RallyTick = (e.RallyTick or 0) - dt
		if e.RallyTick <= 0 then
			e.RallyTick = 0.25
			local radius = e.RallyRadius or 22
			local n = ctx.EnemySpawner.Grid:QueryCircle(e.Pos.X, e.Pos.Z, radius, queryBuf)
			for i = 1, n do
				local o = queryBuf[i]
				if o.Alive and o.Def.Beetle and not o.Boss then
					o.RallyUntil = clock + 0.6
					o.RallySpeed = e.RallySpeed or 1.3
					o.RallyDamage = e.RallyDamage or 1.4
				end
			end
		end
	end
end

local function startWindupRanged(e, R, to: Vector3)
	local t = e.Target
	local p = t.Root.Position
	local point = Vector3.new(p.X, Config.ArenaOrigin.Y, p.Z)
	e.GlobTarget = point
	e.WarnId = Fx.Warn("circle", point.X, point.Z, R.Splash, R.Windup + R.Flight, "acid")
	e.Face = to.Unit
	setAct(e, "Windup", R.Windup)
end

local function launchGlob(e, R)
	local point = e.GlobTarget
	if not point then
		return
	end
	local dist = ((point - e.Pos) * FLAT).Magnitude
	Fx.Warn("glob", e.Pos.X, e.Pos.Z, point.X, point.Z, R.Flight, 5 + dist * 0.12)
	Hazards.Strike(point, R.Splash, R.Flight, R.Damage * (e.DmgScale or 1), { Warn = e.WarnId, Style = "acid" })
	e.WarnId = nil -- the strike owns the landing circle now
	e.GlobTarget = nil
end

-- Per-frame behaviour after think(); may kill e (a fuse ending). Returns nothing.
local function behave(e, dt: number)
	local def = e.Def
	if e.SpawnGrace > 0 then
		e.SpawnGrace -= dt
	end
	e.Face = nil
	local t = e.Target
	local to: Vector3? = nil
	local dist = math.huge
	if t and t.Alive and t.Root then
		to = (t.Root.Position - e.Pos) * FLAT
		dist = (to :: Vector3).Magnitude
	end
	if def.Static then
		behaveStatic(e, dt)
		return
	elseif def.Burrow then
		behaveBurrow(e, dt, to, dist)
		if e.Act ~= nil then
			return
		end
	elseif def.Support then
		behaveSupport(e, dt, to, dist)
		return
	end

	local act = e.Act
	if act then
		e.ActTimer -= dt
		if act == "Windup" and def.Ranged then
			e.SpeedOverride = 0
			if to and dist > 0.1 then
				e.Face = (to :: Vector3).Unit
			end
			if e.ActTimer <= 0 then
				launchGlob(e, def.Ranged)
				e.Cooldown = def.Ranged.Cooldown
				e.SpeedOverride = nil
				setAct(e, nil)
			end
		elseif act == "Windup" and def.Lunge then
			e.SpeedOverride = 0
			e.Dir = e.LungeDir
			if e.ActTimer <= 0 then
				e.WarnId = nil
				setAct(e, "Lunge", def.Lunge.Duration)
			end
		elseif act == "Lunge" then
			e.Dir = e.LungeDir
			e.SpeedOverride = def.Lunge.Speed
			if e.ActTimer <= 0 then
				setAct(e, "Recover", def.Lunge.Recover)
				e.SpeedOverride = 0
			end
		elseif act == "Recover" then
			e.SpeedOverride = 0
			if e.ActTimer <= 0 then
				e.SpeedOverride = nil
				e.Cooldown = def.Lunge and def.Lunge.Cooldown or 2
				setAct(e, nil)
			end
		elseif act == "Fuse" then
			e.SpeedOverride = 0
			if e.ActTimer <= 0 then
				ctx.EnemySpawner.Explode(e)
				return
			end
		elseif e.ActTimer <= 0 then
			setAct(e, nil)
			e.SpeedOverride = nil
		end
	else
		if e.Cooldown then
			e.Cooldown -= dt
		end
		local ready = (e.Cooldown or 0) <= 0 and e.SpawnGrace <= 0
		if def.Ranged then
			local R = def.Ranged
			e.SpeedOverride = nil
			if to and dist > 0.1 then
				local dir = (to :: Vector3).Unit
				if dist < R.MinRange - 3 then
					-- too close: back away (still facing the player)
					e.Dir = -dir
					e.SpeedOverride = e.Speed * 0.75
					e.Face = dir
				elseif dist <= R.MaxRange then
					e.SpeedOverride = 0
					e.Face = dir
					if ready then
						startWindupRanged(e, R, to :: Vector3)
					end
				end
			end
		elseif def.Lunge then
			local L = def.Lunge
			if to and ready and dist >= L.MinRange and dist <= L.Range then
				local dir = (to :: Vector3).Unit
				e.LungeDir = dir
				local length = L.Speed * L.Duration
				e.WarnId = Fx.Telegraph(e.Pos + dir * (length / 2), math.atan2(-dir.X, -dir.Z), length, e.Radius * 2, L.Windup)
				e.PinPos = e.Pos -- held where the lane was drawn (EnemyAI.Step)
				e.SpeedOverride = 0
				setAct(e, "Windup", L.Windup)
			end
		elseif def.Explode and def.Fuse then
			if to and e.SpawnGrace <= 0 and dist <= e.Radius + PLAYER_RADIUS + 1 then
				-- elites: a wider blast (EliteBlastMult) but a longer fuse to get out of it
				local radius = def.Explode.Radius * (e.Elite and Config.Enemies.EliteBlastMult or 1)
				local fuse = e.Elite and math.max(def.Fuse, Config.Enemies.EliteFuse) or def.Fuse
				e.WarnId = Fx.Warn("circle", e.Pos.X, e.Pos.Z, radius, fuse, "blast")
				e.PinPos = e.Pos -- held inside the ring drawn now; Explode blasts from here
				e.SpeedOverride = 0
				setAct(e, "Fuse", fuse)
			end
		end
	end

	-- Burning elites leave short-lived fire patches behind them while they walk.
	if e.Affix == "Burning" and not e.Untargetable then
		local B = Config.Enemies.Affix.Burning
		e.BurnTimer = (e.BurnTimer or B.Every) - dt
		if e.BurnTimer <= 0 then
			e.BurnTimer = B.Every
			local moving = e.SpeedOverride ~= 0 and e.Dir.Magnitude > 0.1
			if moving then
				local list = e.Patches
				if not list then
					list = {}
					e.Patches = list
				end
				for i = #list, 1, -1 do
					if not Hazards.IsLive(list[i]) then
						table.remove(list, i)
					end
				end
				if #list < B.MaxPatches then
					local at = e.Pos - e.Dir * e.Radius
					table.insert(list, Hazards.Patch(Vector3.new(at.X, Config.ArenaOrigin.Y, at.Z), B.Radius + e.Radius * 0.3, B.Arm, B.Life, B.Tick, B.Damage * (e.DmgScale or 1)))
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Main loop
------------------------------------------------------------------------------------------

function EnemyAI.Step(dt: number)
	if not ctx.RunManager.IsSimulating() then
		return
	end
	frame += 1
	clock += dt
	Hazards.Step(dt)
	local active = ctx.EnemySpawner.Active
	local runPlayers = ctx.RunManager.GetRunPlayers()
	local chunks = Config.Enemies.ThinkChunks
	local slot = frame % chunks
	local now = os.clock()
	local decay = math.max(0, 1 - Config.Enemies.KnockbackDecay * dt)
	local sepStrength = Config.Enemies.SeparationStrength
	local recycle2 = Config.Enemies.RecycleDistance ^ 2
	local half = Config.Arenas.Size / 2
	local c = Config.ArenaOrigin

	table.clear(movedBuf)
	table.clear(cframesBuf)
	local n = 0

	local i = 1
	while i <= #active do
		local e = active[i]
		local static = e.Def.Static == true
		if not static and (e.ThinkSlot == slot or e.Target == nil or (e.Target and not e.Target.Alive)) then
			think(e, runPlayers)
		end
		if e.Boss then
			BossAI.Step(e, dt)
		else
			behave(e, dt)
		end
		if not e.Alive then
			continue -- exploded / died this frame: Active was swap-removed, re-check i
		end

		local speed = e.SpeedOverride or e.Speed
		if e.SlowUntil and e.SlowUntil > now then
			speed *= e.SlowMult or 1 -- Chilling Aura (Garlic perk, WeaponSystem)
		end
		-- a War Banner's rally (BossData WarBanner): faster beetles, harder contact hits
		local rallied = e.RallyUntil ~= nil and e.RallyUntil > clock
		if rallied ~= (e.Rallied == true) then
			e.Rallied = rallied
			e.Part:SetAttribute("Rallied", rallied or nil)
		end
		if rallied and not e.SpeedOverride then
			speed *= e.RallySpeed or 1
		end
		-- A fuse / lunge wind-up stays exactly where its telegraph was drawn (no
		-- separation or knockback drift).
		local pin = e.PinPos
		if pin and not (e.Act == "Fuse" or e.Act == "Surface" or (e.Act == "Windup" and e.Def.Lunge)) then
			pin = nil
			e.PinPos = nil
		end
		local pos
		if static then
			e.Knock = Vector3.zero
			pos = e.Pos
		elseif pin then
			e.Knock = Vector3.zero
			pos = pin
		else
			local vel = e.Dir * speed + (e.Sep or Vector3.zero) * sepStrength + e.Knock
			pos = e.Pos + vel * dt
			e.Knock *= decay
			if not e.Ghost then
				pos = pushOut(pos, e.Radius)
			end
		end
		pos = Vector3.new(math.clamp(pos.X, c.X - half + e.Radius, c.X + half - e.Radius), c.Y, math.clamp(pos.Z, c.Z - half + e.Radius, c.Z + half - e.Radius))
		e.Pos = pos

		local far = true
		local harmless = e.Harmless or e.SpawnGrace > 0 or e.Damage <= 0
		for _, rp in ipairs(runPlayers) do
			if rp.Alive and rp.Root then
				local rpos = rp.Root.Position
				local dx, dz = rpos.X - pos.X, rpos.Z - pos.Z
				local d2 = dx * dx + dz * dz
				if d2 < recycle2 then
					far = false
				end
				local reach = e.Radius + PLAYER_RADIUS
				if not harmless and d2 <= reach * reach and now >= e.NextContact then
					e.NextContact = now + Config.Enemies.ContactCooldown
					ctx.RunManager.DamagePlayer(rp, e.Damage * (rallied and e.RallyDamage or 1))
				end
			end
		end

		if far and not e.Boss and not e.Act and not static and #runPlayers > 0 then
			-- left far behind: bring it back to the edge of someone's screen
			local spawnAt = ctx.EnemySpawner.SpawnPoint(e.Radius)
			if spawnAt then
				e.Pos = spawnAt
				e.Knock = Vector3.zero
			end
		end

		if e.Alive then
			local look = e.Face or (e.Dir.Magnitude > 0.1 and e.Dir) or Vector3.new(0, 0, -1)
			local bob = 0
			if e.Def.FlyHeight then
				bob = math.sin(clock * 6 + e.Phase) * 0.4
			end
			local center = e.Pos + Vector3.new(0, e.Height + bob, 0)
			n += 1
			movedBuf[n] = e
			cframesBuf[n] = CFrame.lookAt(center, center + look)
			i += 1
		end
		-- when an enemy died this frame (a revive shockwave), Active was swap-removed:
		-- re-check index i
	end

	-- An enemy can die after it was queued (a revive shockwave, an explosion chain), so
	-- only move the ones still alive; a dead one must stay parked.
	table.clear(partsBuf)
	local m = 0
	for j = 1, n do
		local e = movedBuf[j]
		if e.Alive then
			m += 1
			partsBuf[m] = e.Part
			cframesBuf[m] = cframesBuf[j]
		end
	end
	for j = m + 1, n do
		cframesBuf[j] = nil
	end
	if m > 0 then
		workspace:BulkMoveTo(partsBuf, cframesBuf, Enum.BulkMoveMode.FireCFrameChanged)
	end

	-- Rebuild the enemy grid for this frame's hit detection.
	local grid = ctx.EnemySpawner.Grid
	grid:Clear()
	for j = 1, #active do
		local e = active[j]
		if not e.Untargetable then
			grid:Insert(e)
		end
	end
end

-- Cancels every hazard (group nil = all; "Boss" = the Queen's).
function EnemyAI.ClearHazards(group: string?)
	Hazards.Clear(group)
end

function EnemyAI.Init(c)
	ctx = c
	setAct = c.EnemySpawner.SetAct
	Hazards.Init(c)
	BossAI.Init(c)
end

function EnemyAI.Start() end

return EnemyAI
