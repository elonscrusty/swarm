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

	The boss runs a small state machine here: Chase → Charge → Chase → Ring → Chase →
	Summon → ... (projectiles are spawned through WeaponSystem as hostile projectiles).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local SpatialGrid = require(script.Parent.SpatialGrid)
local Fx = require(script.Parent.Fx)

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
-- Boss
------------------------------------------------------------------------------------------

local BOSS_CYCLE = { "Charge", "Ring", "Summon" }

local function bossSetState(e, state: string, duration: number)
	e.BossState = state
	e.BossTimer = duration
end

local function bossStep(e, dt: number)
	local B = Config.Boss
	if not e.BossState then
		e.BossCycle = 0
		bossSetState(e, "Chase", B.ChaseSeconds)
	end
	e.BossTimer -= dt
	local state = e.BossState
	local target = e.Target
	if state == "Chase" then
		e.SpeedOverride = nil
		if e.BossTimer <= 0 then
			e.BossCycle = (e.BossCycle % #BOSS_CYCLE) + 1
			local nextState = BOSS_CYCLE[e.BossCycle]
			if nextState == "Charge" then
				local dir = target and ((target.Root.Position - e.Pos) * FLAT) or Vector3.new(0, 0, 1)
				e.ChargeDir = dir.Magnitude > 0.1 and dir.Unit or Vector3.new(0, 0, 1)
				local yaw = math.atan2(-e.ChargeDir.X, -e.ChargeDir.Z)
				local length = B.ChargeSpeed * B.ChargeDuration
				Fx.Telegraph(e.Pos + e.ChargeDir * (length / 2), yaw, length, e.Radius * 2, B.ChargeTelegraph)
				bossSetState(e, "ChargeWindup", B.ChargeTelegraph)
			elseif nextState == "Ring" then
				e.RingWave = 0
				bossSetState(e, "Ring", 0)
			else
				bossSetState(e, "Summon", 0.6)
				Fx.Ring(e.Pos, 20, Color3.fromRGB(180, 60, 255))
			end
		end
	elseif state == "ChargeWindup" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			Fx.Sound("BossRoar")
			bossSetState(e, "Charging", B.ChargeDuration)
		end
	elseif state == "Charging" then
		e.Dir = e.ChargeDir
		e.SpeedOverride = B.ChargeSpeed
		if e.BossTimer <= 0 then
			bossSetState(e, "Chase", B.ChaseSeconds)
		end
	elseif state == "Ring" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			e.RingWave += 1
			local offset = (e.RingWave % 2) * (math.pi / B.RingProjectiles)
			for i = 1, B.RingProjectiles do
				local a = offset + (i / B.RingProjectiles) * math.pi * 2
				local dir = Vector3.new(math.cos(a), 0, math.sin(a))
				ctx.WeaponSystem.SpawnHostile(e.Pos + dir * e.Radius, dir, B.RingProjectileSpeed, B.RingProjectileDamage * ctx.StageManager.DamageMult(), B.RingProjectileRadius, B.RingProjectileLife, 7)
			end
			if e.RingWave >= B.RingWaves then
				bossSetState(e, "Chase", B.ChaseSeconds)
			else
				e.BossTimer = B.RingWaveGap
			end
		end
	elseif state == "Summon" then
		e.SpeedOverride = 0
		if e.BossTimer <= 0 then
			for i = 1, B.SummonCount do
				local a = (i / B.SummonCount) * math.pi * 2
				local x, z = ctx.EnemySpawner.ClampToArena(e.Pos.X + math.cos(a) * (e.Radius + 6), e.Pos.Z + math.sin(a) * (e.Radius + 6), 4)
				ctx.EnemySpawner.Spawn(B.SummonType, Vector3.new(x, Config.ArenaOrigin.Y, z))
			end
			bossSetState(e, "Chase", B.ChaseSeconds)
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
		if e.ThinkSlot == slot or e.Target == nil or (e.Target and not e.Target.Alive) then
			think(e, runPlayers)
		end
		if e.Boss then
			bossStep(e, dt)
		end

		local speed = e.SpeedOverride or e.Speed
		local vel = e.Dir * speed + (e.Sep or Vector3.zero) * sepStrength + e.Knock
		local pos = e.Pos + vel * dt
		e.Knock *= decay
		if not e.Ghost then
			pos = pushOut(pos, e.Radius)
		end
		pos = Vector3.new(math.clamp(pos.X, c.X - half + e.Radius, c.X + half - e.Radius), c.Y, math.clamp(pos.Z, c.Z - half + e.Radius, c.Z + half - e.Radius))
		e.Pos = pos

		local removed = false
		local far = true
		for _, rp in ipairs(runPlayers) do
			if rp.Alive and rp.Root then
				local rpos = rp.Root.Position
				local dx, dz = rpos.X - pos.X, rpos.Z - pos.Z
				local d2 = dx * dx + dz * dz
				if d2 < recycle2 then
					far = false
				end
				local reach = e.Radius + PLAYER_RADIUS
				if d2 <= reach * reach then
					if e.Def.Explode then
						ctx.EnemySpawner.Explode(e)
						removed = true
						break
					elseif now >= e.NextContact then
						e.NextContact = now + Config.Enemies.ContactCooldown
						ctx.RunManager.DamagePlayer(rp, e.Damage)
					end
				end
			end
		end

		if not removed and far and not e.Boss and #runPlayers > 0 then
			-- left far behind: bring it back to the edge of someone's screen
			local spawnAt = ctx.EnemySpawner.SpawnPoint(e.Radius)
			if spawnAt then
				e.Pos = spawnAt
				e.Knock = Vector3.zero
			end
		end

		if not removed and e.Alive then
			local look = e.Dir.Magnitude > 0.1 and e.Dir or Vector3.new(0, 0, -1)
			local bob = 0
			if e.Def.FlyHeight then
				bob = math.sin(clock * 6 + e.Phase) * 0.4
			end
			local center = e.Pos + Vector3.new(0, e.Height + bob, 0)
			n += 1
			movedBuf[n] = e
			cframesBuf[n] = CFrame.lookAt(center, center + look)
			i += 1
		elseif e.Alive then
			i += 1
		end
		-- when an enemy died this frame, Active was swap-removed: re-check index i
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
		grid:Insert(active[j])
	end
end

function EnemyAI.Init(c)
	ctx = c
end

function EnemyAI.Start() end

return EnemyAI
