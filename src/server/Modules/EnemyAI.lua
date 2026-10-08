--[[
	EnemyAI.lua
	Moves every enemy from ONE Heartbeat loop (no per-enemy scripts, no Humanoids,
	no Touched events).

	Per frame, for every living enemy:
	  * "Think" (only for 1/ThinkChunks of the enemies each frame): pick the nearest
	    living player, steer around obstacles with a short raycast (skipped on open ground:
	    no obstacle cell or fence near the ray), add a separation push from neighbours (via
	    a fine separation grid), add bat wobble.
	  * Integrate movement + knockback, push out of obstacle shapes, clamp to the fence.
	  * Distance-based contact damage against the (max 4) players.
	  * Recycle enemies left far behind back to the screen edge.
	Then the bodies move with a single workspace:BulkMoveTo call (those near a player every
	frame, farther ones every Config.Enemies.BodyFarEvery frames, staggered: fewer CFrame
	writes to replicate; clients smooth), and the enemy grid used by WeaponSystem hit
	detection is rebuilt.

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
local HeightGrid = require(script.Parent.HeightGrid)
local Nav = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Nav

local EnemyAI = {}
-- Weather (a snow storm): every walking enemy x this; 1 = normal.
EnemyAI.WorldSpeedMult = 1

local ctx
local rng = Random.new()
local UP = Vector3.yAxis
local FLAT = Vector3.new(1, 0, 1)
local PLAYER_RADIUS = 1.2

local obstacleGrid = SpatialGrid.new(Config.Projectiles.CellSize)
-- Fine grid for the separation push only (the coarse EnemySpawner.Grid serves weapon hit
-- queries): in a dense swarm a 20-stud cell holds dozens of enemies, so every think would
-- check them all; an 8-stud cell checks a handful. Same results, rebuilt with the other.
local sepGrid = SpatialGrid.new(Config.Enemies.SeparationCell)
local sepPad = 0 -- largest radius in sepGrid (its queries only widen by this much)
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
-- How far from its centre an enemy's body hurts a player (contact check below): BossAI
-- draws charge lanes this wide so the warning covers the real reach.
function EnemyAI.ContactReach(e): number
	return e.Radius + PLAYER_RADIUS
end

function EnemyAI.PushOut(pos: Vector3, r: number): Vector3
	return pushOut(pos, r)
end

------------------------------------------------------------------------------------------
-- Thinking
------------------------------------------------------------------------------------------

-- Living players' root positions, read once per frame (EnemyAI.Step) instead of once per
-- enemy per use: rp -> position.
local playerPos: { [any]: Vector3 } = {}
-- Their ground height (HeightGrid; only filled while a height grid is active): rp -> Y.
local playerGround: { [any]: number } = {}
-- Players whose server-opened upgrade choice protects them this frame (the state that
-- ChoiceProtectedUntil mirrors: rp.Offer while rp.Paused). Enemies pick someone else while
-- anyone else is free (owner OK 2026-10-05, SEC-02b); if all are protected, nothing changes.
local protectedNow: { [any]: boolean } = {}
local anyFree = false

local function isProtected(rp): boolean
	return rp.Paused == true and rp.Offer ~= nil
end
EnemyAI.IsChoiceProtected = isProtected

local function nearestPlayer(pos: Vector3, runPlayers)
	local best, bestD2 = nil, math.huge
	local freeBest, freeD2 = nil, math.huge
	local px, pz = pos.X, pos.Z
	for _, rp in ipairs(runPlayers) do
		local p = playerPos[rp]
		if p and rp.Alive then
			local dx, dz = p.X - px, p.Z - pz
			local d2 = dx * dx + dz * dz
			if d2 < bestD2 then
				best, bestD2 = rp, d2
			end
			if d2 < freeD2 and not protectedNow[rp] then
				freeBest, freeD2 = rp, d2
			end
		end
	end
	if freeBest then
		return freeBest, math.sqrt(freeD2)
	end
	return best, math.sqrt(bestD2)
end

-- Could the look-ahead ray (from pos along dir, `reach` studs) hit anything? Only obstacle
-- footprints (obstacle grid cells around the ray) and the fence's boundary walls can be hit,
-- so on open ground the raycast is skipped (most of a swarm, most of the time).
local function obstacleAhead(pos: Vector3, dir: Vector3, reach: number): boolean
	local minX, minZ, maxX, maxZ = HeightGrid.Bounds()
	local m = reach + 2
	if pos.X < minX + m or pos.X > maxX - m or pos.Z < minZ + m or pos.Z > maxZ - m then
		return true -- near the fence
	end
	local half = reach / 2
	return obstacleGrid:QueryCells(pos.X + dir.X * half, pos.Z + dir.Z * half, half + 2, obstacleBuf) > 0
end

local function think(e, runPlayers)
	local target = nearestPlayer(e.Pos, runPlayers)
	e.Target = target
	if not target then
		e.Dir = Vector3.zero
		e.Sep = Vector3.zero
		return
	end
	local tp = playerPos[target]
	local to = (tp - e.Pos) * FLAT
	local toDist = to.Magnitude
	if toDist < 0.1 then
		e.Dir = Vector3.zero
		return
	end
	local desired = to.Unit
	-- Height grid (terraces, ramps, a cave): close and on a steppable straight line, seek
	-- directly; otherwise walk down the target's flow field (round a cliff to its ramp). No
	-- field here (outside its radius, no grid): seek directly as on a flat arena.
	if HeightGrid.IsActive() and not (toDist <= Nav.DirectSeekRange and HeightGrid.CanStep(e.Pos.X, e.Pos.Z, tp.X, tp.Z)) then
		local flow = HeightGrid.FlowDir(target, e.Pos.X, e.Pos.Z)
		if flow ~= Vector3.zero then
			desired = flow
		end
	end

	if e.Erratic > 0 then
		local angle = math.sin(clock * 3 + e.Phase) * e.Erratic
		desired = CFrame.fromAxisAngle(UP, angle):VectorToWorldSpace(desired)
	end

	-- The look-ahead stops at the target: a wall or tree BEHIND the player is not in the
	-- way. (A full-length ray hit the boundary wall behind a player standing at the fence
	-- or in a corner and turned every enemy within ~10 studs sideways along the wall, so
	-- they crawled at about a tenth of their speed just outside contact reach:
	-- docs/overhaul/CORNER_REPORT.md, tools/preview/scenes/corner-regression.luau.)
	local look = math.min(Config.Enemies.AvoidRayLength + e.Radius, to.Magnitude)
	local normal: Vector3? = nil
	if not e.Ghost and rayParams and obstacleAhead(e.Pos, desired, look) then
		-- 1 stud up: the lowest colliders (rubble, low walls, plinths) top out at ~1.3 studs;
		-- a ray at 2.5 passed over them and an enemy meeting one head-on stalled behind it
		local origin = e.Pos + Vector3.new(0, 1, 0)
		local hit = workspace:Raycast(origin, desired * look, rayParams)
		if hit then
			normal = hit.Normal * FLAT
		end
	end
	-- The ray is thin, the enemy is not: a big enemy whose edge rests on an obstacle the
	-- ray misses was pushed straight back every frame (EnemyAI.Step pushOut) and stalled.
	-- Pressed against an obstacle and still heading into it: steer round it the same way.
	local pressed = e.BlockNormal
	if not normal and pressed and pressed:Dot(desired) < -0.2 then
		normal = pressed
	end
	if normal then
		local tangent = normal:Cross(UP) * FLAT
		if tangent.Magnitude > 1e-3 then
			tangent = tangent.Unit
			-- go round on the side the target is; meeting a face (nearly) head-on, each enemy
			-- keeps one hand on it (by id): choosing by the target's side flipped from think
			-- to think there and a big enemy dithered behind a box in line with the player
			local side = tangent:Dot(desired)
			if side < -0.3 or (side <= 0.3 and e.Id % 2 == 1) then
				tangent = -tangent
			end
			local steer = tangent * Config.Enemies.AvoidTurnStrength + desired * 0.4 + normal * 0.3
			if steer.Magnitude > 1e-3 then
				desired = steer.Unit
			end
		end
	end
	e.Dir = desired

	-- Separation from neighbours (grid is from the previous frame, good enough); plain
	-- number math, this is the hottest loop in a dense swarm.
	local sx, sz = 0, 0
	if not e.Ghost then
		local sepMult = Config.Enemies.SeparationRadius
		local ex, ez, er = e.Pos.X, e.Pos.Z, e.Radius
		local n = sepGrid:QueryCircle(ex, ez, er * sepMult, queryBuf, sepPad)
		for i = 1, n do
			local o = queryBuf[i]
			if o ~= e and o.Alive and not o.Ghost then
				local op = o.Pos
				local ax, az = ex - op.X, ez - op.Z
				local d = math.sqrt(ax * ax + az * az)
				local minD = (er + o.Radius) * sepMult
				if d < minD then
					if d < 1e-3 then
						ax, az = rng:NextNumber(-1, 1), rng:NextNumber(-1, 1)
						d = math.max(math.sqrt(ax * ax + az * az), 1e-3)
					end
					local k = (minD - d) / minD / d
					sx += ax * k
					sz += az * k
				end
			end
		end
	end
	e.Sep = (sx ~= 0 or sz ~= 0) and Vector3.new(sx, 0, sz) or Vector3.zero
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
			local at = HeightGrid.Ground(e.Pos)
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
		table.insert(out, Vector3.new(x, HeightGrid.GroundY(x, z), z))
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
				table.insert(spots, Vector3.new(x, HeightGrid.GroundY(x, z), z))
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
	local point = HeightGrid.Ground(p)
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
	Hazards.Strike(point, R.Splash, R.Flight, R.Damage * (e.DmgScale or 1), { Warn = e.WarnId, Style = "acid", Cause = "Spitter acid glob" })
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
	local tp = t and t.Alive and playerPos[t]
	if tp then
		to = (tp - e.Pos) * FLAT
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
					table.insert(list, Hazards.Patch(HeightGrid.Ground(at), B.Radius + e.Radius * 0.3, B.Arm, B.Life, B.Tick, B.Damage * (e.DmgScale or 1)))
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
	table.clear(playerPos)
	table.clear(playerGround)
	table.clear(protectedNow)
	anyFree = false
	-- a weapon band left set by a failed WeaponSystem step must not filter these queries
	ctx.EnemySpawner.Grid.BandY = nil
	local heights = HeightGrid.IsActive()
	for _, rp in ipairs(runPlayers) do
		if rp.Alive and rp.Root then
			local rpos = rp.Root.Position
			playerPos[rp] = rpos
			if heights then
				playerGround[rp] = HeightGrid.GroundY(rpos.X, rpos.Z)
			end
			if isProtected(rp) then
				protectedNow[rp] = true
			else
				anyFree = true
			end
		end
	end
	local chunks = Config.Enemies.ThinkChunks
	local slot = frame % chunks
	local now = ctx.RunManager.GetRunTime()
	local decay = math.max(0, 1 - Config.Enemies.KnockbackDecay * dt)
	local sepStrength = Config.Enemies.SeparationStrength
	local recycle2 = Config.Enemies.RecycleDistance ^ 2
	-- the fence: the arena's bounds (today's square around ArenaOrigin without them)
	local minX, minZ, maxX, maxZ = HeightGrid.Bounds()
	local floorY = Config.ArenaOrigin.Y
	local contactBand = Nav.ContactBand
	local syncNear2 = Config.Enemies.BodySyncNear ^ 2
	local farEvery = Config.Enemies.BodyFarEvery

	table.clear(movedBuf)
	table.clear(cframesBuf)
	local n = 0
	debug.profilebegin("EnemyAI.Enemies") -- MicroProfiler labels (Ctrl+F6 in a test)

	local i = 1
	while i <= #active do
		local e = active[i]
		local static = e.Def.Static == true
		if not static and (e.ThinkSlot == slot or e.Target == nil or (e.Target and not e.Target.Alive) or (anyFree and protectedNow[e.Target])) then
			debug.profilebegin("EnemyAI.Think")
			think(e, runPlayers)
			debug.profileend()
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
		if not e.SpeedOverride then
			speed *= EnemyAI.WorldSpeedMult -- a snow storm (Weather); 1 otherwise
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
				local free = pushOut(pos, e.Radius)
				local bx, bz = free.X - pos.X, free.Z - pos.Z
				local b = math.sqrt(bx * bx + bz * bz)
				-- which way an obstacle pushed it back this frame (think() steers round)
				e.BlockNormal = b > 1e-3 and Vector3.new(bx / b, 0, bz / b) or nil
				pos = free
			end
		end
		local r = e.Radius
		local nx = math.clamp(pos.X, minX + r, math.max(minX + r, maxX - r))
		local nz = math.clamp(pos.Z, minZ + r, math.max(minZ + r, maxZ - r))
		if heights then
			if not static and not pin then
				-- never step off a cliff or onto a wall face: cancel the blocked axis (slide)
				local ox, oz = e.Pos.X, e.Pos.Z
				if not HeightGrid.CanStep(ox, oz, nx, nz) then
					if HeightGrid.CanStep(ox, oz, nx, oz) then
						nz = oz
					elseif HeightGrid.CanStep(ox, oz, ox, nz) then
						nx = ox
					else
						nx, nz = ox, oz
					end
				end
				pos = Vector3.new(nx, HeightGrid.GroundY(nx, nz), nz)
			else
				pos = Vector3.new(nx, pos.Y, nz)
			end
		else
			pos = Vector3.new(nx, floorY, nz)
		end
		e.Pos = pos

		local far = true
		local nearest2 = math.huge
		local harmless = e.Harmless or e.SpawnGrace > 0 or e.Damage <= 0
		for _, rp in ipairs(runPlayers) do
			local rpos = playerPos[rp]
			if rpos and rp.Alive then
				local dx, dz = rpos.X - pos.X, rpos.Z - pos.Z
				local d2 = dx * dx + dz * dz
				if d2 < recycle2 then
					far = false
				end
				if d2 < nearest2 then
					nearest2 = d2
				end
				local reach = e.Radius + PLAYER_RADIUS
				-- with a height grid: only on (about) the same level, not across a cliff
				if not harmless and d2 <= reach * reach and (not heights or math.abs(playerGround[rp] - pos.Y) <= contactBand) then
					-- the contact cooldown is per enemy AND per player (one bite on you
					-- never uses up its bite on your partner); a pooled record gets a fresh
					-- table when its uid changes
					local cd = e.ContactNext
					if cd == nil or e.ContactUid ~= e.Uid then
						cd = {}
						e.ContactNext = cd
						e.ContactUid = e.Uid
					end
					if now >= (cd[rp] or 0) then
						cd[rp] = now + Config.Enemies.ContactCooldown
						e.NextContact = cd[rp] -- latest bite on anyone (read by tests and tools)
						local name = (e.BossData and e.BossData.DisplayName) or e.Def.DisplayName or e.Type
						ctx.RunManager.DamagePlayer(rp, e.Damage * (rallied and e.RallyDamage or 1), name .. " contact", "contact")
					end
				end
			end
		end

		if far and not e.Boss and not e.Act and not static and #runPlayers > 0 then
			-- left far behind: bring it back to the edge of someone's screen
			local spawnAt = ctx.EnemySpawner.SpawnPoint(e.Radius)
			if spawnAt then
				e.Pos = spawnAt
				e.Knock = Vector3.zero
				nearest2 = 0 -- moved: sync the body now
			end
		end

		-- Body sync: enemies near a player (and bosses, enemies mid-behaviour, fresh
		-- spawns) move their body every frame; the rest every BodyFarEvery frames, staggered
		-- by id. Clients smooth between updates, so this only cuts CFrame writes and their
		-- replication; the simulation (e.Pos, hits, contact damage) still runs every frame.
		local sync = nearest2 <= syncNear2 or (frame + e.Id) % farEvery == 0 or e.Boss or e.Act ~= nil or e.SpawnGrace > 0
		if e.Alive and sync then
			local look = e.Face or (e.Dir.Magnitude > 0.1 and e.Dir) or Vector3.new(0, 0, -1)
			local bob = 0
			if e.Def.FlyHeight then
				bob = math.sin(clock * 6 + e.Phase) * 0.4
			end
			local center = e.Pos + Vector3.new(0, e.Height + bob, 0)
			n += 1
			movedBuf[n] = e
			cframesBuf[n] = CFrame.lookAt(center, center + look)
		end
		if e.Alive then
			i += 1
		end
		-- when an enemy died this frame (a revive shockwave), Active was swap-removed:
		-- re-check index i
	end

	debug.profileend()

	-- An enemy can die after it was queued (a revive shockwave, an explosion chain), so
	-- only move the ones still alive; a dead one must stay parked.
	debug.profilebegin("EnemyAI.Sync")
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
	debug.profileend()

	-- Rebuild the enemy grid for this frame's hit detection (and the fine separation grid).
	debug.profilebegin("EnemyAI.Grids")
	local grid = ctx.EnemySpawner.Grid
	grid:Clear()
	sepGrid:Clear()
	local pad = 0
	for j = 1, #active do
		local e = active[j]
		if not e.Untargetable then
			grid:Insert(e)
			if not e.Ghost then
				sepGrid:Insert(e)
				if e.Radius > pad then
					pad = e.Radius
				end
			end
		end
	end
	sepPad = pad
	debug.profileend()
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
