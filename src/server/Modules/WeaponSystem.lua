--[[
	WeaponSystem.lua
	Server-authoritative auto-attacks for all 8 weapons + evolutions, the projectile
	simulation, holy water pools and hostile (boss) projectiles.

	* Projectiles are plain data records from a fixed pool (Config.Projectiles.PoolSize);
	  the server never creates Parts for them.
	* Hit detection uses the enemy SpatialGrid (20-stud cells) - no Touched events.
	* Visuals: positions of every live projectile are packed into ONE buffer and sent
	  with ONE RemoteEvent call per sync tick (Config.Net.ProjectileSyncHz). Clients
	  interpolate and render pooled parts.
	* Clients never send damage, targets or positions; every number comes from WeaponData
	  and the player's server-side stat sheet.

	Buffer layout: u16 count, then per projectile 11 bytes:
	  u16 id, u8 visual, u8 seq, i16 x*10, i16 y*10, i16 z*10, u8 yaw (0-255 = 0-2pi)
	  visual = WeaponData.Visuals index (low 5 bits) + 32 * visual tier (0-3, cosmetic)
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)
local Fx = require(script.Parent.Fx)

local WeaponSystem = {}

local ctx
local rng = Random.new()
local FLAT = Vector3.new(1, 0, 1)
local TAU = math.pi * 2
local PLAYER_RADIUS = 1.2

------------------------------------------------------------------------------------------
-- Projectile pool
------------------------------------------------------------------------------------------

type Projectile = { [string]: any }

local projectiles: { Projectile } = {}
local freeIds: { number } = {}
local live: { Projectile } = {} -- dense list of active projectiles
local zones: { any } = {} -- holy water pools
local queryBuf = {}
local syncTimer = 0
local sentEmpty = true

local function allocProjectile(): Projectile?
	local id = table.remove(freeIds)
	if not id then
		return nil
	end
	local p = projectiles[id]
	p.Active = true
	p.Seq = (p.Seq + 1) % 256
	table.clear(p.Hits)
	p.Target = nil
	p.TargetUid = nil
	p.Hostile = false
	p.Owner = nil
	p.Weapon = nil
	p.Age = 0
	p.Yaw = 0
	p.Y = Config.ArenaOrigin.Y + Config.Projectiles.Height
	p.VY = 0
	p.Rehit = nil
	p.Cancelled = false
	table.insert(live, p)
	p.LiveIndex = #live
	return p
end

local function freeProjectile(p: Projectile)
	if not p.Active then
		return
	end
	p.Active = false
	local i = p.LiveIndex
	local last = live[#live]
	live[i] = last
	last.LiveIndex = i
	live[#live] = nil
	if p.Owner and p.Weapon and p.Weapon.Live then
		p.Weapon.Live[p] = nil
	end
	table.insert(freeIds, p.Id)
end

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

-- Effective stats of one weapon for one player (WeaponData row × stat sheet).
local function weaponStats(rp, w)
	local row = WeaponData.GetStats(w.Id, w.Level, w.Evolved)
	local s = rp.Stats
	return {
		damage = row.damage * s.Might,
		cooldown = math.max(Config.Projectiles.MaxWeaponCooldownFloor, row.cooldown * s.CooldownMult),
		amount = math.max(1, row.amount + s.Amount),
		area = row.area * s.AreaMult,
		speed = row.speed * s.ProjSpeedMult,
		pierce = row.pierce,
		duration = row.duration * s.DurationMult,
		knockback = row.knockback,
	}
end
WeaponSystem.WeaponStats = weaponStats

local function flatDir(v: Vector3, fallback: Vector3): Vector3
	local f = v * FLAT
	if f.Magnitude < 1e-3 then
		return fallback
	end
	return f.Unit
end

local function rotateY(v: Vector3, angle: number): Vector3
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function yawOf(dir: Vector3): number
	return math.atan2(-dir.X, -dir.Z)
end

local function ground(v: Vector3): Vector3
	return Vector3.new(v.X, Config.ArenaOrigin.Y, v.Z)
end

local function grid()
	return ctx.EnemySpawner.Grid
end

-- k nearest distinct enemies to a point (small k, linear selection over a grid query).
local function nearestEnemies(pos: Vector3, range: number, k: number): { any }
	local n = grid():QueryCircle(pos.X, pos.Z, range, queryBuf)
	local result = {}
	if n == 0 then
		return result
	end
	local list = table.move(queryBuf, 1, n, 1, {})
	table.sort(list, function(a, b)
		local da = (a.Pos - pos) * FLAT
		local db = (b.Pos - pos) * FLAT
		return da.Magnitude < db.Magnitude
	end)
	for i = 1, math.min(k, #list) do
		result[i] = list[i]
	end
	return result
end

-- Damages one enemy from a weapon. Returns true if it died.
local function hitEnemy(rp, e, damage: number, fromPos: Vector3, knockback: number): boolean
	local dir = (e.Pos - fromPos) * FLAT
	dir = dir.Magnitude > 1e-3 and dir.Unit or Vector3.new(0, 0, 1)
	return ctx.EnemySpawner.Damage(e, damage, rp, dir, knockback)
end

------------------------------------------------------------------------------------------
-- Weapon behaviours
------------------------------------------------------------------------------------------

local Fire = {}

-- Visual tier sent with projectiles and slashes (0 = levels 1-3, 1 = 4-6, 2 = 7-8, 3 = evolved).
-- Purely cosmetic: the client draws stronger trails/glows for higher tiers.
local function visualTier(w): number
	if w.Evolved then
		return 3
	elseif w.Level >= 7 then
		return 2
	elseif w.Level >= 4 then
		return 1
	end
	return 0
end

-- Projectile visual byte: low 5 bits = WeaponData.Visuals index, bits 5-6 = tier (same u8 as before).
local function visualByte(index: number, w): number
	return index + visualTier(w) * 32
end

--[[
	WHIP / BLOODWHIP: sword swings, alternating front and back.
	The hit shape is a sector (Params.Arc degrees, Params.Reach studs) centred on the swing
	direction - the same shape the client draws. Reach 7 x 150 degrees covers about the same
	area as the old 13 x 4.5 rectangle (64 vs 58.5 studs^2; ~110 vs ~113 once enemy radii are
	added), so the damage per swing is unchanged. The swing's visual starts immediately and
	damage lands SWING_HIT_DELAY later, when the drawn blade is in the middle of its sweep.
]]
local SWING_HIT_DELAY = 0.08
local SWING_INNER = 1.5 -- enemies this close are always inside the swing

function Fire.Whip(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local reach = params.Reach * s.area
	local half = math.rad(params.Arc) / 2
	local facing = rp.Facing
	local tier = visualTier(w)
	for i = 1, s.amount do
		local dir = (i % 2 == 1) and facing or -facing
		local sweep = (i % 2 == 1) and 1 or -1 -- forehand / backhand
		task.delay((i - 1) * 0.12, function()
			if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() then
				return
			end
			Fx.Slash(ground(rp.Root.Position), yawOf(dir), reach, sweep, tier, rp.Player.UserId)
			task.delay(SWING_HIT_DELAY, function()
				if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() then
					return
				end
				local origin = ground(rp.Root.Position)
				local healed = 0
				local n = grid():QueryCircle(origin.X, origin.Z, reach, queryBuf)
				local hits = table.move(queryBuf, 1, n, 1, {})
				for _, e in ipairs(hits) do
					if e.Alive then
						local rel = (e.Pos - origin) * FLAT
						local d = rel.Magnitude
						local inside = d <= SWING_INNER + e.Radius
						if not inside then
							local off = math.acos(math.clamp(rel:Dot(dir) / d, -1, 1)) - half
							-- inside the sector, or overlapping one of its edges
							inside = off <= 0 or (off < math.pi / 2 and d * math.sin(off) <= e.Radius)
						end
						if inside then
							hitEnemy(rp, e, s.damage, origin, s.knockback)
							if evo and healed < evo.LifestealCapPerSwing then
								healed += evo.Lifesteal
							end
						end
					end
				end
				if healed > 0 then
					ctx.RunManager.Heal(rp, healed, true)
				end
			end)
		end)
	end
	Fx.Sound("Hit")
end

-- MAGIC ORB / TWIN ORBS: homing projectiles at the nearest enemies.
function Fire.Orb(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local targets = nearestEnemies(origin, 60, s.amount)
	if #targets == 0 then
		return
	end
	for i = 1, s.amount do
		local target = targets[((i - 1) % #targets) + 1]
		local dir = flatDir(target.Pos - origin, rp.Facing)
		local offsets = (evo and evo.Twin) and { -0.8, 0.8 } or { 0 }
		for _, off in ipairs(offsets) do
			local p = allocProjectile()
			if not p then
				return
			end
			p.Kind = "Homing"
			p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
			p.Owner = rp
			p.Weapon = w
			p.Pos = origin + Vector3.new(-dir.Z, 0, dir.X) * off + dir * 1.5
			p.Vel = dir * s.speed
			p.Speed = s.speed
			p.Damage = s.damage
			p.Pierce = s.pierce
			p.Radius = params.Radius * s.area
			p.Life = s.duration
			p.Knockback = s.knockback
			p.Target = target
			p.TargetUid = target.Uid
			p.TurnRate = params.TurnRate
		end
	end
end

-- THROWING KNIVES / THOUSAND EDGE: fast straight projectiles in the movement direction.
function Fire.Knives(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local dir = rp.MoveDir.Magnitude > 0.1 and rp.MoveDir or rp.Facing
	local origin = ground(rp.Root.Position)
	local side = Vector3.new(-dir.Z, 0, dir.X)
	for i = 1, s.amount do
		local p = allocProjectile()
		if not p then
			return
		end
		local centered = i - (s.amount + 1) / 2
		local d = dir
		local start = origin + dir * 1.5
		if evo and evo.Stream then
			d = rotateY(dir, centered * math.rad(4)) -- fan
		else
			start += side * centered * params.Spread - dir * math.abs(centered) * 0.8 -- staggered volley
		end
		p.Kind = "Straight"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = start
		p.Vel = d * s.speed
		p.Damage = s.damage
		p.Pierce = s.pierce
		p.Radius = params.Radius * s.area
		p.Life = s.duration
		p.Knockback = s.knockback
		p.Yaw = yawOf(d)
	end
end

-- GARLIC / SOUL EATER: damage ring around the player.
function Fire.Aura(rp, w, s, def)
	local evo = w.Evolved and def.Evolution or nil
	local radius = def.Params.Radius * s.area * (1 + (w.Growth or 0))
	local origin = ground(rp.Root.Position)
	local n = grid():QueryCircle(origin.X, origin.Z, radius, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive then
			local killed = hitEnemy(rp, e, s.damage, origin, s.knockback)
			if killed and evo then
				w.Growth = math.min(evo.GrowthCap, (w.Growth or 0) + evo.GrowthPerKill)
			end
		end
	end
	WeaponSystem.UpdateAura(rp)
end

-- HOLY WATER / HELLFIRE: lobbed bottles that leave damaging pools.
function Fire.HolyWater(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local n = grid():QueryCircle(origin.X, origin.Z, params.ThrowRange, queryBuf)
	for i = 1, s.amount do
		local dest
		if n > 0 then
			dest = queryBuf[rng:NextInteger(1, n)].Pos
		else
			local a = rng:NextNumber(0, TAU)
			dest = origin + Vector3.new(math.cos(a), 0, math.sin(a)) * rng:NextNumber(6, params.ThrowRange)
		end
		local p = allocProjectile()
		if not p then
			return
		end
		local to = (dest - origin) * FLAT
		local flight = math.max(0.35, to.Magnitude / math.max(1, s.speed))
		p.Kind = "Lob"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin
		p.Vel = to / flight
		p.Life = flight
		p.Y = Config.ArenaOrigin.Y + 3
		p.VY = 30 -- the arc is purely visual
		-- gravity chosen so the bottle comes back down to ~0.5 studs exactly at landing
		p.Gravity = 2 * (p.VY * flight + 2.5) / (flight * flight)
		p.Damage = s.damage
		p.Pierce = 0
		p.Radius = 0
		p.PoolRadius = params.PoolRadius * s.area
		p.PoolLife = s.duration
		p.PoolTick = params.TickSeconds
		p.Evo = evo ~= nil
		p.Knockback = 0
		p.Index = i
	end
end

-- LIGHTNING / THUNDER LOOP: instant strikes on random enemies near the player.
function Fire.Lightning(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local n = grid():QueryCircle(origin.X, origin.Z, params.Range, queryBuf)
	if n == 0 then
		return
	end
	local candidates = table.move(queryBuf, 1, n, 1, {})
	local strikeRadius = params.StrikeRadius * s.area
	for _ = 1, s.amount do
		if #candidates == 0 then
			break
		end
		local idx = rng:NextInteger(1, #candidates)
		local target = candidates[idx]
		table.remove(candidates, idx)
		if target.Alive then
			local at = target.Pos
			local m = grid():QueryCircle(at.X, at.Z, strikeRadius, queryBuf)
			local struck = table.move(queryBuf, 1, m, 1, {})
			local hitSet = {}
			for _, e in ipairs(struck) do
				if e.Alive then
					hitSet[e] = true
					hitEnemy(rp, e, s.damage, at, s.knockback)
				end
			end
			Fx.Bolt(at, strikeRadius, visualTier(w))
			if evo and evo.ChainJumps then
				local from = at
				for _ = 1, evo.ChainJumps do
					local nextE = grid():Nearest(from.X, from.Z, evo.ChainRange, function(e)
						return hitSet[e] == true or not e.Alive
					end)
					if not nextE then
						break
					end
					hitSet[nextE] = true
					Fx.Chain(from, nextE.Pos)
					local to = nextE.Pos
					hitEnemy(rp, nextE, s.damage * 0.7, from, 0)
					from = to
				end
			end
		end
	end
	Fx.Sound("Lightning")
end

-- AXE / DEATH SPIRAL: arcing heavy projectiles, or orbiting spiral axes when evolved.
function Fire.Axe(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	for i = 1, s.amount do
		local p = allocProjectile()
		if not p then
			return
		end
		p.Owner = rp
		p.Weapon = w
		p.Damage = s.damage
		p.Radius = params.Radius * s.area
		p.Life = s.duration
		p.Knockback = s.knockback
		if evo and evo.Orbit then
			p.Kind = "Orbit"
			p.Visual = visualByte(params.EvoVisual, w)
			p.Angle = (i / s.amount) * TAU
			p.OrbitRadius = params.OrbitRadius * s.area
			p.OrbitGrowth = params.OrbitGrowth * s.area
			p.OrbitSpin = params.OrbitSpin
			p.Pierce = s.pierce
			p.Rehit = 0.5
			p.Pos = origin
		else
			p.Kind = "Arc"
			p.Visual = visualByte(params.Visual, w)
			local spread = (i - (s.amount + 1) / 2) * math.rad(22) + rng:NextNumber(-0.15, 0.15)
			local dir = rotateY(rp.Facing, spread)
			p.Pos = origin
			p.Vel = dir * s.speed
			p.Y = Config.ArenaOrigin.Y + 3
			p.VY = params.UpSpeed
			p.Gravity = params.Gravity
			p.Pierce = s.pierce
		end
	end
end

-- BOOMERANG / INFINITE RETURN: out toward an enemy, then back to the owner.
function Fire.Boomerang(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local count = s.amount
	if evo and evo.Persistent then
		-- persistent boomerangs: only top up to the allowed amount
		local alive = 0
		for _ in pairs(w.Live) do
			alive += 1
		end
		count = s.amount - alive
	end
	local targets = nearestEnemies(origin, 50, math.max(1, count))
	for i = 1, count do
		local p = allocProjectile()
		if not p then
			return
		end
		local target = targets[((i - 1) % math.max(1, #targets)) + 1]
		local dir = target and flatDir(target.Pos - origin, rp.Facing) or rotateY(rp.Facing, (i - 1) * TAU / count)
		p.Kind = "Boomerang"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin
		p.Vel = dir * s.speed
		p.Speed = s.speed
		p.OutTime = s.duration
		p.Returning = false
		p.Damage = s.damage
		p.Pierce = s.pierce
		p.Radius = params.Radius * s.area
		p.Life = (evo and evo.Persistent) and math.huge or (s.duration * 2 + 3)
		p.Knockback = s.knockback
		p.Rehit = params.RehitSeconds
		p.Persistent = evo ~= nil and evo.Persistent == true
		w.Live[p] = true
	end
end

------------------------------------------------------------------------------------------
-- Hostile projectiles (boss)
------------------------------------------------------------------------------------------

function WeaponSystem.SpawnHostile(pos: Vector3, dir: Vector3, speed: number, damage: number, radius: number, life: number, visual: number)
	local p = allocProjectile()
	if not p then
		return
	end
	p.Kind = "Straight"
	p.Hostile = true
	p.Visual = visual
	p.Pos = ground(pos)
	p.Vel = dir * speed
	p.Damage = damage
	p.Pierce = 1
	p.Radius = radius
	p.Life = life
	p.Knockback = 0
	p.Yaw = yawOf(dir)
end

------------------------------------------------------------------------------------------
-- Projectile simulation
------------------------------------------------------------------------------------------

-- Hits enemies overlapping a projectile. Returns true if the projectile is used up.
local function collideEnemies(p: Projectile, now: number): boolean
	local n = grid():QueryCircle(p.Pos.X, p.Pos.Z, p.Radius, queryBuf)
	if n == 0 then
		return false
	end
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive then
			local last = p.Hits[e.Uid]
			if last == nil or (p.Rehit and now - last >= p.Rehit) then
				p.Hits[e.Uid] = now
				local dir = p.Vel and p.Vel.Magnitude > 1e-3 and (p.Vel * FLAT).Unit or nil
				if dir then
					ctx.EnemySpawner.Damage(e, p.Damage, p.Owner, dir, p.Knockback)
				else
					hitEnemy(p.Owner, e, p.Damage, p.Pos, p.Knockback)
				end
				if p.Pierce < 999 then
					p.Pierce -= 1
					if p.Pierce <= 0 then
						return true
					end
				end
			end
		end
	end
	return false
end

local function collidePlayers(p: Projectile): boolean
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		if rp.Alive and rp.Root then
			local d = (rp.Root.Position - p.Pos) * FLAT
			if d.Magnitude <= p.Radius + PLAYER_RADIUS then
				ctx.RunManager.DamagePlayer(rp, p.Damage)
				return true
			end
		end
	end
	return false
end

local function outOfArena(pos: Vector3): boolean
	local c = Config.ArenaOrigin
	local h = Config.Arenas.Size / 2 + 20
	return math.abs(pos.X - c.X) > h or math.abs(pos.Z - c.Z) > h
end

local function stepProjectile(p: Projectile, dt: number, now: number): boolean -- true = remove
	if p.Cancelled then
		return true
	end
	p.Age += dt
	if p.Age >= p.Life then
		if p.Kind == "Lob" then
			-- landed: create a pool
			table.insert(zones, {
				Pos = p.Pos,
				Radius = p.PoolRadius,
				Life = p.PoolLife,
				Tick = p.PoolTick,
				Timer = 0,
				Damage = p.Damage,
				Owner = p.Owner,
			})
			Fx.Pool(p.Pos, p.PoolRadius, p.PoolLife, p.Evo)
		end
		return true
	end

	local kind = p.Kind
	if kind == "Straight" then
		p.Pos += p.Vel * dt
	elseif kind == "Homing" then
		local t = p.Target
		if t and t.Alive and t.Uid == p.TargetUid then
			local want = flatDir(t.Pos - p.Pos, p.Vel.Unit)
			local cur = p.Vel.Unit
			local blended = cur:Lerp(want, math.min(1, p.TurnRate * dt))
			p.Vel = flatDir(blended, cur) * p.Speed
		end
		p.Pos += p.Vel * dt
		p.Yaw = yawOf(p.Vel)
	elseif kind == "Arc" then
		p.Pos += p.Vel * dt
		p.VY -= p.Gravity * dt
		p.Y = math.max(Config.ArenaOrigin.Y + 0.5, p.Y + p.VY * dt)
		p.Yaw += dt * 12
	elseif kind == "Lob" then
		p.Pos += p.Vel * dt
		p.VY -= p.Gravity * dt
		p.Y = math.max(Config.ArenaOrigin.Y + 0.5, p.Y + p.VY * dt)
		return false -- bottles don't hit in flight
	elseif kind == "Orbit" then
		local owner = p.Owner
		if not owner.Alive or not owner.Root then
			return true
		end
		p.Angle += p.OrbitSpin * dt
		local radius = p.OrbitRadius + p.OrbitGrowth * p.Age
		local center = ground(owner.Root.Position)
		local newPos = center + Vector3.new(math.cos(p.Angle), 0, math.sin(p.Angle)) * radius
		p.Vel = (newPos - p.Pos) / math.max(dt, 1e-3)
		p.Pos = newPos
		p.Yaw = -p.Angle
	elseif kind == "Boomerang" then
		local owner = p.Owner
		if not owner.Alive or not owner.Root then
			return true
		end
		if not p.Returning then
			p.Pos += p.Vel * dt
			if p.Age >= p.OutTime then
				p.Returning = true
			end
		else
			local home = ground(owner.Root.Position)
			local to = (home - p.Pos) * FLAT
			if to.Magnitude <= 2.5 then
				if p.Persistent then
					-- relaunch at a new target and keep going forever
					local targets = nearestEnemies(home, 50, 1)
					local dir = targets[1] and flatDir(targets[1].Pos - home, owner.Facing) or rotateY(owner.Facing, rng:NextNumber(0, TAU))
					p.Vel = dir * p.Speed
					p.Returning = false
					p.Age = 0
					table.clear(p.Hits)
				else
					return true
				end
			else
				p.Vel = to.Unit * p.Speed * 1.15
				p.Pos += p.Vel * dt
			end
		end
		p.Yaw += dt * 15
	end

	if outOfArena(p.Pos) and kind ~= "Orbit" and kind ~= "Boomerang" then
		return true
	end
	if p.Hostile then
		return collidePlayers(p)
	end
	return collideEnemies(p, now)
end

local function stepZones(dt: number)
	for i = #zones, 1, -1 do
		local z = zones[i]
		z.Life -= dt
		z.Timer -= dt
		if z.Timer <= 0 then
			z.Timer = z.Tick
			local n = grid():QueryCircle(z.Pos.X, z.Pos.Z, z.Radius, queryBuf)
			local hits = table.move(queryBuf, 1, n, 1, {})
			for _, e in ipairs(hits) do
				if e.Alive then
					ctx.EnemySpawner.Damage(e, z.Damage, z.Owner, nil, 0)
				end
			end
		end
		if z.Life <= 0 then
			table.remove(zones, i)
		end
	end
end

------------------------------------------------------------------------------------------
-- Network sync
------------------------------------------------------------------------------------------

local BYTES = 11

local function i16(n: number): number
	return math.clamp(math.floor(n * 10 + 0.5), -32768, 32767)
end

local function sync()
	local count = #live
	if count == 0 then
		if sentEmpty then
			return
		end
		sentEmpty = true
	else
		sentEmpty = false
	end
	local b = buffer.create(2 + count * BYTES)
	buffer.writeu16(b, 0, count)
	local o = 2
	for i = 1, count do
		local p = live[i]
		buffer.writeu16(b, o, p.Id)
		buffer.writeu8(b, o + 2, p.Visual or 1)
		buffer.writeu8(b, o + 3, p.Seq)
		buffer.writei16(b, o + 4, i16(p.Pos.X))
		buffer.writei16(b, o + 6, i16(p.Y))
		buffer.writei16(b, o + 8, i16(p.Pos.Z))
		buffer.writeu8(b, o + 10, math.floor(((p.Yaw % TAU) / TAU) * 255 + 0.5) % 256)
		o += BYTES
	end
	Remotes.FireAllClients("ProjectileBatch", b)
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- Updates the aura attributes the client uses to draw the garlic ring and the XP pull.
function WeaponSystem.UpdateAura(rp)
	local w = rp.Weapons.Garlic
	local player: Player = rp.Player
	if not w then
		player:SetAttribute("AuraRadius", 0)
		rp.AuraPullRadius = nil
		return
	end
	local def = WeaponData.Weapons.Garlic
	local s = weaponStats(rp, w)
	local radius = def.Params.Radius * s.area * (1 + (w.Growth or 0))
	player:SetAttribute("AuraRadius", math.floor(radius * 10 + 0.5) / 10)
	player:SetAttribute("AuraEvo", w.Evolved)
	rp.AuraPullRadius = (w.Evolved and def.Evolution.PullsXP) and radius or nil
end

function WeaponSystem.OnInventoryChanged(rp)
	WeaponSystem.UpdateAura(rp)
end

--[[
	Removes a player's projectiles and pools (death / leaving). This can run from inside
	the projectile loop (a boss orb downs a player), so projectiles are only flagged and
	freed by the loop itself. ClearOwner(nil) frees everything immediately (run cleanup).
]]
function WeaponSystem.ClearOwner(rp)
	for i = #live, 1, -1 do
		local p = live[i]
		if rp == nil then
			freeProjectile(p)
		elseif p.Owner == rp then
			p.Cancelled = true
		end
	end
	for i = #zones, 1, -1 do
		if rp == nil or zones[i].Owner == rp then
			table.remove(zones, i)
		end
	end
end

function WeaponSystem.Clear()
	WeaponSystem.ClearOwner(nil)
	sync()
end

function WeaponSystem.Step(dt: number)
	if ctx.RunManager.IsSimulating() then
		local now = os.clock()
		-- 1) fire weapons
		for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
			if rp.Alive and not rp.Paused and rp.Root then
				for _, id in ipairs(rp.WeaponOrder) do
					local w = rp.Weapons[id]
					w.Timer -= dt
					if w.Timer <= 0 then
						local def = WeaponData.Weapons[id]
						local s = weaponStats(rp, w)
						w.Timer = s.cooldown
						local fn = Fire[def.Behavior]
						if fn then
							fn(rp, w, s, def)
						end
					end
				end
			end
		end
		-- 2) simulate projectiles (iterate backwards: freeing swap-removes)
		for i = #live, 1, -1 do
			local p = live[i]
			if p and p.Active and stepProjectile(p, dt, now) then
				freeProjectile(p)
			end
		end
		-- 3) pools
		stepZones(dt)
	end

	syncTimer += dt
	if syncTimer >= 1 / Config.Net.ProjectileSyncHz then
		syncTimer = 0
		sync()
	end
end

function WeaponSystem.Init(c)
	ctx = c
	for i = 1, Config.Projectiles.PoolSize do
		projectiles[i] = { Id = i, Active = false, Seq = 0, Hits = {}, Age = 0, Pos = Vector3.zero, Y = 0, Yaw = 0 }
		table.insert(freeIds, 1, i)
	end
end

function WeaponSystem.Start() end

return WeaponSystem
