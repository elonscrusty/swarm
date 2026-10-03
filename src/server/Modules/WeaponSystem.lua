--[[
	WeaponSystem.lua
	Server-authoritative auto-attacks for every weapon + evolution, their level perks
	(WeaponData.Perks: Riposte, Splitting Orbs, Ricochet, Chilling Aura, Volley), the
	Ranger's Steady Aim, the projectile simulation, holy water pools and hostile (boss)
	projectiles.

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
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
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
local wards: { [any]: boolean } = {} -- Ward Shields with Bulwark: hostile shots break on them
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
	p.Cause = nil
	p.Owner = nil
	p.Weapon = nil
	p.Age = 0
	p.Yaw = 0
	p.Y = Config.ArenaOrigin.Y + Config.Projectiles.Height
	p.VY = 0
	p.Rehit = nil
	p.Cancelled = false
	p.Split = nil
	p.Bounces = nil
	-- fields of the newer behaviours (spear, hook, soul, turret, totem)
	p.Phase = nil
	p.Spent = nil
	p.FirstBonus = nil
	p.Burst = nil
	p.FlakBurst = nil
	p.Wander = nil
	p.NoHarvest = nil
	p.Carry = nil
	p.SeekAt = nil
	p.Gravity = nil
	-- armoury batch: per-kind data, Sling stagger / bounce gain
	p.X = nil
	p.Stagger = nil
	p.BounceGain = nil
	table.insert(live, p)
	p.LiveIndex = #live
	return p
end

local function freeProjectile(p: Projectile)
	if not p.Active then
		return
	end
	p.Active = false
	wards[p] = nil
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
	local def = WeaponData.Weapons[w.Id]
	local s = rp.Stats
	local hero = CharacterData.Characters[rp.CharacterId]
	-- Steady Aim (Ranger): standing still gives +SteadyAimBonus damage to the Longbow and
	-- +SteadyAimOther to every other weapon until you move
	local mult = s.Might * (rp.SteadyAim and (1 + ((w.Id == "Longbow" and rp.SteadyAimBonus or rp.SteadyAimOther) or 0)) or 1)
	-- Volatile Mix (Alchemist): burning / area weapons hit harder
	if hero and hero.AreaDamage and def and def.Area then
		mult *= 1 + hero.AreaDamage
	end
	local duration = row.duration * s.DurationMult
	-- Tinkerer (Engineer): turrets and totems last longer
	if hero and hero.DeployLife and def and def.Deployable then
		duration *= 1 + hero.DeployLife
	end
	return {
		damage = row.damage * mult,
		cooldown = math.max(Config.Projectiles.MaxWeaponCooldownFloor, row.cooldown * s.CooldownMult),
		amount = WeaponData.CapAmount(w.Id, math.max(1, row.amount + s.Amount)),
		area = row.area * s.AreaMult,
		speed = row.speed * s.ProjSpeedMult,
		-- Fletching: stopping projectiles pass through more enemies
		pierce = row.pierce >= 999 and 999 or row.pierce + (s.Pierce or 0),
		duration = duration,
		knockback = row.knockback,
		heal = row.heal or 0,
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

-- k nearest living enemies to a point (small k: a sort over a grid query; k = 1 walks the
-- grid outward instead, so a long-range single target never sorts the whole swarm).
local function skipDead(e): boolean
	return not e.Alive
end

local function nearestEnemies(pos: Vector3, range: number, k: number): { any }
	local result = {}
	if k <= 1 then
		local e = grid():Nearest(pos.X, pos.Z, range, skipDead)
		if e then
			result[1] = e
		end
		return result
	end
	local n = grid():QueryCircle(pos.X, pos.Z, range, queryBuf)
	if n == 0 then
		return result
	end
	local list = {}
	for i = 1, n do
		local e = queryBuf[i]
		if e.Alive then
			list[#list + 1] = e
		end
	end
	local px, pz = pos.X, pos.Z
	table.sort(list, function(a, b)
		local ax, az = a.Pos.X - px, a.Pos.Z - pz
		local bx, bz = b.Pos.X - px, b.Pos.Z - pz
		return ax * ax + az * az < bx * bx + bz * bz
	end)
	for i = 1, math.min(k, #list) do
		result[i] = list[i]
	end
	return result
end

------------------------------------------------------------------------------------------
-- Weapon effects that are not projectiles (WeaponFx remote, flushed with the projectile
-- sync): the client draws them (VFX). Purely cosmetic, capped per flush.
--   nv = { {x, z, radius, evo} }            frost nova burst
--   fp = { {x, z, radius, life, evo} }      a Fire Trail flame patch (harmless to heroes)
--   tp = { {x, z, radius, evo, healed} }    a Healing Totem pulse (healed = 1: it healed)
--   hk = { {userId, projectileId, seq} }    a Chain Hook: draw the chain from that hero
--   fk = { {x, z, radius} }                 a turret's flak burst
--   lb = { {x, z, radius} }                 a Dragon Lance tip burst
--   sh = { {x, z} }                         Soul Harvest: a soul rises from a kill
--   qk = { {x, z, radius, kind} }           Earthsplitter spikes (kind 0/1; 2/3 = Aftershock)
--   mt = { {x, z, radius, fall, evo} }      Starfall warning ring (the meteor lands in `fall` s)
--   vn = { {x, z, radius, evo} }            Vine Snare sprouting      vt = { {x, z, radius} } thorns
--   hn = { {x, z, yaw, range, halfDeg, evo} } War Horn shockwave (halfDeg 180 = full ring)
--   wb = { {x, z, reflect} }                a Ward Shield smashed an enemy projectile
--   vx = { {x, z, radius, life, evo} }      a Vortex opens            vi = { {x, z, radius, evo} } implosion
------------------------------------------------------------------------------------------

local wfx: { [string]: { any } } = {}
local wfxAny = false
local WFX_CAPS = { nv = 12, fp = 48, tp = 16, hk = 16, fk = 16, lb = 16, sh = 16, qk = 40, mt = 12, vn = 16, vt = 12, hn = 12, wb = 8, vx = 8, vi = 8 }

local function r1(n: number): number
	return math.floor(n * 10 + 0.5) / 10
end

local function pushFx(key: string, value: { any })
	local list = wfx[key]
	if not list then
		list = {}
		wfx[key] = list
	end
	if #list >= (WFX_CAPS[key] or 16) then
		return
	end
	table.insert(list, value)
	wfxAny = true
end

local function flushFx()
	if not wfxAny then
		return
	end
	Remotes.FireAllClients("WeaponFx", wfx)
	wfx = {}
	wfxAny = false
end

-- Soul Harvest (Necromancer), set below: a weapon kill may release a soul.
local onWeaponKill: (rp: any, pos: Vector3, dead: any) -> ()

--[[
	Every weapon hit goes through here: EnemySpawner.Damage (crits, item procs, kills), then
	the hero's kill trait. noHarvest = a soul from Soul Harvest itself (souls never chain).
]]
local function damageEnemy(rp, e, amount: number, dir: Vector3?, knockback: number, isProc: boolean?, noHarvest: boolean?): boolean
	local pos = e.Pos
	local died = ctx.EnemySpawner.Damage(e, amount, rp, dir, knockback, isProc)
	if died and rp and not noHarvest then
		onWeaponKill(rp, pos, e)
	end
	return died
end

-- Damages one enemy from a weapon. Returns true if it died.
local function hitEnemy(rp, e, damage: number, fromPos: Vector3, knockback: number): boolean
	local dir = (e.Pos - fromPos) * FLAT
	dir = dir.Magnitude > 1e-3 and dir.Unit or Vector3.new(0, 0, 1)
	return damageEnemy(rp, e, damage, dir, knockback)
end

-- Slows a (non-boss) enemy: EnemyAI multiplies its speed by SlowMult until SlowUntil. A
-- stronger slow that is still running is never weakened.
local function slowEnemy(e, mult: number, seconds: number, now: number)
	if e.Boss then
		return
	end
	if e.SlowUntil and e.SlowUntil > now and (e.SlowMult or 1) < mult then
		return
	end
	e.SlowUntil = now + seconds
	e.SlowMult = mult
	e.TerrainSlow = nil -- a weapon slow now: mud / quicksand must not overwrite it
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

-- Projectile visual byte (WeaponData.VisualByte): the Visuals index (1-63) and the tier.
local function visualByte(index: number, w): number
	return WeaponData.VisualByte(index, visualTier(w))
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
	-- auto aim (owner): the forehand cut faces the nearest enemy (looking well past the
	-- reach so the swing visibly turns toward incoming enemies), else the facing
	local facing = rp.Facing
	if rp.Root then
		local origin = ground(rp.Root.Position)
		local target = nearestEnemies(origin, math.max(reach * 3, 30), 1)[1]
		if target then
			facing = flatDir(target.Pos - origin, rp.Facing)
		end
	end
	local tier = visualTier(w)
	-- Riposte perk: every 3rd attack the forehand cut covers the full circle
	w.Attacks = (w.Attacks or 0) + 1
	local riposte = WeaponData.HasPerk(w, "Riposte") and w.Attacks % 3 == 0
	for i = 1, s.amount do
		local dir = (i % 2 == 1) and facing or -facing
		local sweep = (i % 2 == 1) and 1 or -1 -- forehand / backhand
		local full = riposte and i == 1
		task.delay((i - 1) * 0.12, function()
			if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() then
				return
			end
			Fx.Slash(ground(rp.Root.Position), yawOf(dir), reach, sweep, tier, rp.Player.UserId)
			if full then
				Fx.Slash(ground(rp.Root.Position), yawOf(-dir), reach, -sweep, tier, rp.Player.UserId)
			end
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
						local inside = d <= SWING_INNER + e.Radius or (full and d <= reach + e.Radius)
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
			p.Split = WeaponData.HasPerk(w, "Split")
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
		p.Bounces = WeaponData.HasPerk(w, "Ricochet") and 1 or nil
	end
end

-- GARLIC / SOUL EATER: damage ring around the player.
local CHILL_SLOW = 0.75 -- Chilling Aura perk: enemies in the ring move at 75% speed
function Fire.Aura(rp, w, s, def)
	local evo = w.Evolved and def.Evolution or nil
	local radius = def.Params.Radius * s.area * (1 + (w.Growth or 0))
	local origin = ground(rp.Root.Position)
	local n = grid():QueryCircle(origin.X, origin.Z, radius, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	local chill = WeaponData.HasPerk(w, "Chill")
	local now = ctx.RunManager.GetRunTime()
	for _, e in ipairs(hits) do
		if e.Alive then
			if chill then
				-- Chilling Aura: EnemyAI multiplies their speed by SlowMult until SlowUntil
				slowEnemy(e, CHILL_SLOW, s.cooldown + 0.3, now)
			end
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

--[[
	LONGBOW / WINDPIERCER: heavy piercing arrows at the nearest enemy in range (auto aim),
	else in the movement direction, else where you face. Several arrows fly side by side. Volley perk: every 3rd shot adds two arrows at
	±VolleyAngle degrees; Windpiercer does that on every shot.
]]
function Fire.Longbow(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	-- auto aim (owner): the nearest enemy in range, else the movement direction, else facing
	local target = nearestEnemies(origin, s.speed * s.duration, 1)[1]
	local dir = target and flatDir(target.Pos - origin, rp.Facing)
		or (rp.MoveDir.Magnitude > 0.1 and rp.MoveDir or rp.Facing)
	w.Attacks = (w.Attacks or 0) + 1
	local fan = (evo and evo.Fan) or (WeaponData.HasPerk(w, "Volley") and w.Attacks % params.VolleyEvery == 0)
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local shots = {}
	for i = 1, s.amount do
		local centered = i - (s.amount + 1) / 2
		table.insert(shots, { Dir = dir, Start = origin + dir * 1.8 + side * centered * params.Spread - dir * math.abs(centered) * 0.6 })
	end
	if fan then
		for _, sign in ipairs({ -1, 1 }) do
			table.insert(shots, { Dir = rotateY(dir, sign * math.rad(params.VolleyAngle)), Start = origin + dir * 1.8 })
		end
	end
	for _, shot in ipairs(shots) do
		local p = allocProjectile()
		if not p then
			return
		end
		p.Kind = "Straight"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = shot.Start
		p.Vel = shot.Dir * s.speed
		p.Damage = s.damage
		p.Pierce = s.pierce
		p.Radius = params.Radius * s.area
		p.Life = s.duration
		p.Knockback = s.knockback
		p.Yaw = yawOf(shot.Dir)
	end
	Fx.Sound("Hit")
end

-- Shards and harvested souls only spawn while this many projectile ids are free.
local EXTRA_MIN_FREE = 100

--[[
	SPEAR / DRAGON LANCE: spears thrust out and back along your facing (fanned FanAngle
	degrees apart), hitting up to `pierce` enemies on the way out. Impale perk: the first
	enemy each spear hits takes +ImpaleBonus. Dragon Lance: each thrust bursts at full reach.
]]
function Fire.Spear(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local impale = WeaponData.HasPerk(w, "Impale")
	for i = 1, s.amount do
		local p = allocProjectile()
		if not p then
			return
		end
		local centered = i - (s.amount + 1) / 2
		local dir = rotateY(rp.Facing, math.rad(centered * params.FanAngle))
		local reach = params.Reach * s.area
		p.Kind = "Thrust"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Dir = dir
		p.Reach = reach
		p.Pos = origin + dir * 1.2
		p.Vel = dir * (reach / (params.ThrustTime / 2))
		p.Damage = s.damage
		p.Pierce = s.pierce
		p.Radius = params.Width * math.sqrt(s.area)
		p.Life = params.ThrustTime
		p.Knockback = s.knockback
		p.Yaw = yawOf(dir)
		p.Spent = false
		p.FirstBonus = impale and params.ImpaleBonus or nil
		if evo and evo.Burst then
			p.Burst = { Radius = params.BurstRadius * s.area, Share = params.BurstShare }
		end
	end
	Fx.Sound("Hit")
end

-- CROSSBOW / HEARTSEEKER: fast straight bolts at the nearest enemies; Ricochet perk and
-- Heartseeker let a bolt that would stop bounce on to the nearest other enemy.
function Fire.Crossbow(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local targets = nearestEnemies(origin, s.speed * s.duration, s.amount)
	if #targets == 0 then
		w.Timer = math.min(w.Timer, 0.25) -- nothing in range: look again soon
		return
	end
	local bounces = evo and evo.Bounces or (WeaponData.HasPerk(w, "Ricochet") and 1 or nil)
	for i = 1, s.amount do
		local p = allocProjectile()
		if not p then
			return
		end
		local target = targets[((i - 1) % #targets) + 1]
		local dir = flatDir(target.Pos - origin, rp.Facing)
		if i > #targets then
			-- more bolts than targets: a small fan around the same target
			dir = rotateY(dir, (i % 2 == 0 and 1 or -1) * math.rad(6) * math.ceil((i - #targets) / 2))
		end
		p.Kind = "Straight"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin + dir * 1.5
		p.Vel = dir * s.speed
		p.Damage = s.damage
		p.Pierce = s.pierce
		p.Radius = params.Radius * s.area
		p.Life = s.duration
		p.Knockback = s.knockback
		p.Yaw = yawOf(dir)
		p.Bounces = bounces
	end
	Fx.Sound("Hit")
end

-- Ice shards flying out of an enemy the nova killed (Shatter perk).
local function shatterShards(rp, w, at: Vector3, count: number, damage: number, visual: number, params)
	if #freeIds < EXTRA_MIN_FREE then
		return
	end
	local a0 = rng:NextNumber(0, TAU)
	for k = 1, count do
		local c = allocProjectile()
		if not c then
			return
		end
		local d = rotateY(Vector3.new(1, 0, 0), a0 + k * TAU / count)
		c.Kind = "Straight"
		c.Visual = visual
		c.Owner = rp
		c.Weapon = w
		c.Pos = at
		c.Vel = d * params.ShardSpeed
		c.Damage = damage
		c.Pierce = 1
		c.Radius = 0.8
		c.Life = 0.4
		c.Knockback = 2
		c.Yaw = yawOf(d)
	end
end

--[[
	FROST NOVA / ABSOLUTE ZERO: a burst of ice around you: damage, a small push and a slow
	(non-boss enemies, Slow / EvoSlow speed for `duration` s). Shatter perk: enemies the
	burst kills split into ice shards (half damage, at most MaxShards per burst).
]]
function Fire.Nova(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local radius = params.Radius * s.area
	local n = grid():QueryCircle(origin.X, origin.Z, radius, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	local now = ctx.RunManager.GetRunTime()
	local slow = (evo and evo.DeepFreeze) and params.EvoSlow or params.Slow
	local shatter = WeaponData.HasPerk(w, "Shatter")
	local shardVisual = visualByte(evo and params.EvoVisual or params.Visual, w)
	local shards = 0
	for _, e in ipairs(hits) do
		if e.Alive then
			slowEnemy(e, slow, s.duration, now)
			local at = e.Pos
			if hitEnemy(rp, e, s.damage, origin, s.knockback) and shatter and shards < params.MaxShards then
				shards += params.ShardCount
				shatterShards(rp, w, at, params.ShardCount, s.damage * params.ShardShare, shardVisual, params)
			end
		end
	end
	pushFx("nv", { r1(origin.X), r1(origin.Z), r1(radius), evo and 1 or 0 })
	Fx.Sound("Hit")
end

--[[
	FIRE TRAIL / PHOENIX STRIDE: every `cooldown` s a burning patch is left where you stand,
	if you walked at least Spacing studs since the last one (standing still never stacks
	patches). A patch burns enemies every Tick s (an enemy is burnt by at most one of your
	patches per tick) after a short Arm time; it never touches heroes. Wildfire perk: every
	WildfireEvery-th patch is wider. Phoenix Stride: burnt enemies keep burning (Ignite).
]]
local patches: { any } = {}
local burns: { [any]: any } = {}

function Fire.FireTrail(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local pos = ground(rp.Root.Position)
	local last: Vector3? = w.LastPatch
	if last and ((pos - last) * FLAT).Magnitude < params.Spacing * math.sqrt(s.area) then
		return
	end
	w.LastPatch = pos
	w.PatchCount = (w.PatchCount or 0) + 1
	local wide = WeaponData.HasPerk(w, "Wildfire") and w.PatchCount % params.WildfireEvery == 0
	local radius = params.Radius * s.area * (wide and params.WildfireScale or 1)
	-- per-player cap: the oldest patch goes out first
	local mine, oldest = 0, nil
	for i, z in ipairs(patches) do
		if z.Owner == rp then
			mine += 1
			oldest = oldest or i
		end
	end
	-- sized so a patch normally burns out before it is evicted (the client keeps drawing
	-- a patch for its whole duration and is never told about an eviction)
	local cap = math.clamp(math.ceil(s.duration / s.cooldown) + 4, params.MaxPatches, 32)
	if mine >= cap and oldest then
		table.remove(patches, oldest)
	end
	table.insert(patches, {
		Pos = pos,
		Radius = radius,
		Life = s.duration,
		Tick = params.Tick,
		Timer = params.Arm,
		Damage = s.damage,
		Owner = rp,
		Weapon = w,
		Ignite = evo ~= nil and evo.Ignite == true,
		IgniteSeconds = params.IgniteSeconds,
		IgniteShare = params.IgniteShare,
	})
	pushFx("fp", { r1(pos.X), r1(pos.Z), r1(radius), r1(s.duration), evo and 1 or 0 })
end

-- Has this weapon's fire burnt enemy `e` within the last tick? (marks it when not)
local function burnReady(w, e, tick: number, now: number): boolean
	local seen = w.TrailHit
	if not seen or now >= (w.TrailHitClear or 0) then
		seen = {}
		w.TrailHit = seen
		w.TrailHitClear = now + 10 -- forget old enemy ids now and then
	end
	local last = seen[e.Uid]
	if last and now - last < tick * 0.9 then
		return false
	end
	seen[e.Uid] = now
	return true
end

local function stepPatches(dt: number, now: number)
	for i = #patches, 1, -1 do
		local z = patches[i]
		z.Life -= dt
		z.Timer -= dt
		if z.Timer <= 0 and z.Life > 0 then
			z.Timer = z.Tick
			local owner = z.Owner
			if owner.Alive then
				local n = grid():QueryCircle(z.Pos.X, z.Pos.Z, z.Radius, queryBuf)
				local hits = table.move(queryBuf, 1, n, 1, {})
				for _, e in ipairs(hits) do
					if e.Alive and burnReady(z.Weapon, e, z.Tick, now) then
						damageEnemy(owner, e, z.Damage, nil, 0)
						if z.Ignite and e.Alive then
							burns[e] = { Uid = e.Uid, Until = now + z.IgniteSeconds, Next = now + z.Tick, Tick = z.Tick, Damage = z.Damage * z.IgniteShare, Owner = owner, Weapon = z.Weapon }
						end
					end
				end
			end
		end
		if z.Life <= 0 then
			table.remove(patches, i)
		end
	end
	-- Phoenix Stride's ignite: burning enemies outside the flames
	for e, b in pairs(burns) do
		if not e.Alive or e.Uid ~= b.Uid or now >= b.Until or not b.Owner.Alive then
			burns[e] = nil
		elseif now >= b.Next then
			b.Next = now + b.Tick
			if burnReady(b.Weapon, e, b.Tick, now) then
				damageEnemy(b.Owner, e, b.Damage, nil, 0)
			end
		end
	end
end

-- Live deployables (turrets / totems) of a weapon, oldest first.
local function deployed(w): { Projectile }
	local list = {}
	for p in pairs(w.Live) do
		if p.Active and not p.Cancelled then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		return (a.Born or 0) < (b.Born or 0)
	end)
	return list
end

--[[
	How many deployables to build this attack: every missing one up to the cap; when all
	are standing the oldest is taken down and rebuilt next to you (so they follow you
	around the map over time). Uptime per deployable = min(1, life / cooldown).
]]
local function deployCount(w, cap: number): number
	local list = deployed(w)
	if #list < cap then
		return cap - #list
	end
	for i = 1, #list - cap + 1 do
		local old = list[i]
		old.Cancelled = true
		w.Live[old] = nil
	end
	return 1
end

-- A spot next to the hero (behind them, spread for several deployables).
local function besideHero(rp, index: number): Vector3
	local back = -rp.Facing
	local dir = rotateY(back, (index % 2 == 0 and 1 or -1) * math.rad(35) * math.floor(index / 2))
	return ground(rp.Root.Position) + dir * 3
end

--[[
	HEALING TOTEM / LIFEBLOOM: plants a totem next to you (up to `amount`, the oldest is
	rebuilt). Every Pulse s it hurts enemies in its ring (a small push) and heals every
	living hero in the ring by `heal` (at most one totem heal per hero per HealGap: totems
	never stack heals). Rooting Pulse perk: every RootEvery-th pulse roots enemies briefly.
]]
function Fire.Totem(rp, w, s, def)
	for _ = 1, deployCount(w, s.amount) do
		Fire.TotemOne(rp, w, s, def)
	end
end

function Fire.TotemOne(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local p = allocProjectile()
	if not p then
		return
	end
	w.Placed = (w.Placed or 0) + 1
	p.Kind = "Totem"
	p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
	p.Owner = rp
	p.Weapon = w
	p.Pos = besideHero(rp, w.Placed)
	p.Vel = Vector3.zero
	p.Y = Config.ArenaOrigin.Y
	p.Yaw = yawOf(rp.Facing)
	p.Life = s.duration
	p.Damage = s.damage
	p.Heal = s.heal
	p.Pierce = 999
	p.Radius = 0
	p.Knockback = s.knockback
	p.PulseRadius = params.Radius * s.area
	p.Pulse = evo and params.EvoPulse or params.Pulse
	p.PulseTimer = 0.35
	p.Pulses = 0
	p.Rooting = WeaponData.HasPerk(w, "Rooting")
	p.Evo = evo ~= nil
	p.Born = ctx.RunManager.GetRunTime()
	w.Live[p] = true
end

local function totemPulse(p: Projectile, now: number)
	local def = WeaponData.Weapons.HealingTotem
	local params = def.Params
	p.Pulses += 1
	local root = p.Rooting and p.Pulses % params.RootEvery == 0
	local n = grid():QueryCircle(p.Pos.X, p.Pos.Z, p.PulseRadius, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive then
			if root then
				slowEnemy(e, 0.05, params.RootSeconds, now)
			end
			hitEnemy(p.Owner, e, p.Damage, p.Pos, p.Knockback)
		end
	end
	local healed = 0
	local r2 = p.PulseRadius * p.PulseRadius
	for _, other in ipairs(ctx.RunManager.GetRunPlayers()) do
		if other.Alive and other.Root and other.HP and other.Stats and other.HP < other.Stats.MaxHP and now >= (other.TotemHealAt or 0) then
			local d = (other.Root.Position - p.Pos) * FLAT
			if d.X * d.X + d.Z * d.Z <= r2 then
				other.TotemHealAt = now + params.HealGap
				ctx.RunManager.Heal(other, p.Heal, true)
				healed = 1
			end
		end
	end
	pushFx("tp", { r1(p.Pos.X), r1(p.Pos.Z), r1(p.PulseRadius), p.Evo and 1 or 0, healed })
end

--[[
	CHAIN HOOK / REAPER'S CHAIN: a hook flies at the furthest enemy inside a Cone in front of
	you (reach = speed x duration; several hooks take the next furthest). When it bites:
	full damage to that enemy and a pull to PullTo studs in front of you (knockback, so
	heavy enemies resist and the Queen barely moves), and ChainShare damage to every enemy
	on the chain's line (Barbed Chain perk: they are dragged in too). Then the hook reels back.
]]
function Fire.Hook(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local facing = rp.Facing
	local reach = s.speed * s.duration
	local n = grid():QueryCircle(origin.X, origin.Z, reach, queryBuf)
	local cosCone = math.cos(math.rad(params.Cone))
	local found = {}
	for i = 1, n do
		local e = queryBuf[i]
		if e.Alive then
			local rel = (e.Pos - origin) * FLAT
			local d = rel.Magnitude
			if d > 3 and d <= reach and (rel / d):Dot(facing) >= cosCone then
				table.insert(found, { E = e, D = d })
			end
		end
	end
	if #found == 0 then
		w.Timer = math.min(w.Timer, 0.3) -- nothing in front: look again soon
		return
	end
	table.sort(found, function(a, b)
		return a.D > b.D
	end)
	local barbed = WeaponData.HasPerk(w, "Barbed")
	for i = 1, math.min(s.amount, #found) do
		local target = found[i].E
		local p = allocProjectile()
		if not p then
			return
		end
		local dir = flatDir(target.Pos - origin, facing)
		p.Kind = "Hook"
		p.Phase = "Out"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin + dir * 1.5
		p.Speed = s.speed
		p.Vel = dir * s.speed
		p.Target = target
		p.TargetUid = target.Uid
		p.Damage = s.damage
		p.Pierce = 999
		p.Radius = params.Radius * s.area
		p.ChainWidth = params.ChainWidth * s.area
		p.ChainShare = params.ChainShare
		p.PullTo = params.PullTo
		p.Barbed = barbed
		p.OutLimit = s.duration * 1.8
		p.Life = s.duration * 2 + 2
		p.Knockback = 0
		p.Yaw = yawOf(dir)
		pushFx("hk", { rp.Player.UserId, p.Id, p.Seq })
	end
	Fx.Sound("Hit")
end

-- Knockback speed that moves an enemy about `dist` studs (EnemyAI decays knockback at
-- KnockbackDecay per second, so it travels speed / decay).
local function pullSpeed(dist: number): number
	return math.clamp(dist, 0, 40) * Config.Enemies.KnockbackDecay
end

local function hookBite(p: Projectile, t, home: Vector3)
	local owner = p.Owner
	local toHome = (home - t.Pos) * FLAT
	local dist = toHome.Magnitude
	local dir = dist > 1e-3 and toHome / dist or Vector3.zAxis
	local far = t.Pos
	damageEnemy(owner, t, p.Damage, dir, pullSpeed(dist - p.PullTo))
	-- everything on the chain's line between the hero and the bitten enemy
	local seg = (far - home) * FLAT
	local len = seg.Magnitude
	if len < 1 then
		return
	end
	local unit = seg / len
	local mid = home + seg / 2
	local n = grid():QueryCircle(mid.X, mid.Z, len / 2 + p.ChainWidth + 2, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive and e ~= t then
			local rel = (e.Pos - home) * FLAT
			local along = rel:Dot(unit)
			if along > 0 and along < len then
				local off = (rel - unit * along).Magnitude
				if off <= p.ChainWidth + e.Radius then
					local kb = p.Barbed and pullSpeed((along - p.PullTo) * 0.5) or 0
					damageEnemy(owner, e, p.Damage * p.ChainShare, -unit, kb)
				end
			end
		end
	end
end

--[[
	TURRET / BASTION: builds a turret next to you (up to `amount`, MaxAmount 2; the oldest is
	rebuilt next to you). A turret lives `duration` s and shoots a bolt at the nearest enemy
	within Range x area every ShotEvery s (Bastion: EvoShotEvery). Flak Shells perk: every
	FlakEvery-th bolt bursts around the first enemy it hits.
]]
function Fire.Turret(rp, w, s, def)
	for _ = 1, deployCount(w, s.amount) do
		Fire.TurretOne(rp, w, s, def)
	end
end

function Fire.TurretOne(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local p = allocProjectile()
	if not p then
		return
	end
	w.Placed = (w.Placed or 0) + 1
	p.Kind = "Turret"
	p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
	p.ShotVisual = visualByte(params.ShotVisual, w)
	p.Owner = rp
	p.Weapon = w
	p.Pos = besideHero(rp, w.Placed)
	p.Vel = Vector3.zero
	p.Y = Config.ArenaOrigin.Y
	p.Yaw = yawOf(rp.Facing)
	p.Life = s.duration
	p.Damage = s.damage
	p.Pierce = 999
	p.Radius = 0
	p.Knockback = s.knockback
	p.BoltSpeed = math.max(30, s.speed)
	p.BoltPierce = s.pierce
	p.Range = params.Range * s.area
	p.ShotEvery = evo and params.EvoShotEvery or params.ShotEvery
	p.ShotTimer = 0.45
	p.Shots = 0
	p.Flak = WeaponData.HasPerk(w, "Flak")
	p.Born = ctx.RunManager.GetRunTime()
	w.Live[p] = true
	Fx.Sound("Hit")
end

local function turretShoot(p: Projectile, target)
	local params = WeaponData.Weapons.Turret.Params
	local dir = flatDir(target.Pos - p.Pos, Vector3.new(0, 0, -1))
	p.Yaw = yawOf(dir)
	p.Shots += 1
	local b = allocProjectile()
	if not b then
		return
	end
	b.Kind = "Straight"
	b.Visual = p.ShotVisual
	b.Owner = p.Owner
	b.Weapon = p.Weapon
	b.Pos = p.Pos + dir * 2.2 -- the muzzle of the turret model (drawn x1.6)
	b.Y = Config.ArenaOrigin.Y + 2.9
	b.Vel = dir * p.BoltSpeed
	b.Damage = p.Damage
	b.Pierce = p.BoltPierce
	b.Radius = params.BoltRadius
	b.Life = (p.Range + 6) / p.BoltSpeed
	b.Knockback = p.Knockback
	b.Yaw = p.Yaw
	if p.Flak and p.Shots % params.FlakEvery == 0 then
		b.FlakBurst = { Radius = params.FlakRadius, Share = params.FlakShare }
	end
end

-- Flak Shells (turret perk) / Dragon Lance tips: a burst around a point (proc damage:
-- no crits, no item procs).
local function burstAround(rp, at: Vector3, radius: number, damage: number, skip: any?)
	local n = grid():QueryCircle(at.X, at.Z, radius, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, o in ipairs(hits) do
		if o.Alive and o ~= skip then
			local d = (o.Pos - at) * FLAT
			damageEnemy(rp, o, damage, d.Magnitude > 1e-3 and d.Unit or Vector3.zAxis, 4, true)
		end
	end
end

local function flakBurst(p: Projectile, e, at: Vector3)
	local f = p.FlakBurst
	p.FlakBurst = nil
	burstAround(p.Owner, at, f.Radius, p.Damage * f.Share, e)
	pushFx("fk", { r1(at.X), r1(at.Z), r1(f.Radius) })
end

--[[
	SOUL BOLT / SOUL STORM: slow homing souls. Each soul picks its own target among the
	nearest enemies; when its target dies or was already hit it seeks the nearest enemy it
	has not hit (within Seek studs). Wandering Souls perk: a soul that kills gets one more
	hit. Soul Harvest (Necromancer) releases the same kind of soul from kills.
]]
local function launchSoul(rp, w, from: Vector3, target, damage: number, speed: number, pierce: number, life: number, radius: number, visual: number, knockback: number, seek: number): Projectile?
	local p = allocProjectile()
	if not p then
		return nil
	end
	local dir = flatDir(target.Pos - from, rp.Facing)
	-- souls curl out sideways first, then home in
	dir = rotateY(dir, rng:NextNumber(-0.9, 0.9))
	p.Kind = "Soul"
	p.Visual = visual
	p.Owner = rp
	p.Weapon = w
	p.Pos = from
	p.Y = Config.ArenaOrigin.Y + Config.Projectiles.Height + 0.6
	p.Vel = dir * speed
	p.Speed = speed
	p.Damage = damage
	p.Pierce = pierce
	p.Radius = radius
	p.Life = life
	p.Knockback = knockback
	p.Target = target
	p.TargetUid = target.Uid
	p.TurnRate = 5
	p.Seek = seek
	p.Yaw = yawOf(dir)
	return p
end

function Fire.Soul(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local targets = nearestEnemies(origin, params.Range, s.amount)
	if #targets == 0 then
		w.Timer = math.min(w.Timer, 0.3)
		return
	end
	local wander = WeaponData.HasPerk(w, "Wandering")
	local visual = visualByte(evo and params.EvoVisual or params.Visual, w)
	for i = 1, s.amount do
		local target = targets[((i - 1) % #targets) + 1]
		local side = rotateY(rp.Facing, i * TAU / s.amount)
		local p = launchSoul(rp, w, origin + side * 1.2, target, s.damage, s.speed, s.pierce, s.duration, params.Radius * s.area, visual, s.knockback, params.Seek)
		if not p then
			return
		end
		p.TurnRate = params.TurnRate
		p.Wander = wander or nil
	end
end

-- Soul Harvest (CharacterData SoulHarvest): a weapon kill may release a soul at the corpse
-- that seeks the nearest other enemy. Never from a harvested soul's own kill.
onWeaponKill = function(rp, pos: Vector3, dead)
	local hero = CharacterData.Characters[rp.CharacterId]
	local trait = hero and hero.SoulHarvest
	if not trait or not rp.Alive or not rp.Stats then
		return
	end
	local now = ctx.RunManager.GetRunTime()
	if now < (rp.SoulAt or 0) or rng:NextNumber() >= trait.Chance or #freeIds < EXTRA_MIN_FREE then
		return
	end
	local target = grid():Nearest(pos.X, pos.Z, 30, function(x)
		return x == dead or not x.Alive
	end)
	if not target then
		return
	end
	rp.SoulAt = now + trait.Gap
	local damage = (trait.Damage + trait.PerLevel * (rp.Level or 1)) * rp.Stats.Might
	local soul = launchSoul(rp, nil, ground(pos), target, damage, 34, 1, 3, 0.9, WeaponData.VisualByte(WeaponData.Weapons.SoulBolt.Params.Visual, 1), 2, 30)
	if soul then
		soul.NoHarvest = true
	end
	pushFx("sh", { r1(pos.X), r1(pos.Z) })
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
	local boss = ctx.EnemySpawner.Boss
	p.Cause = boss and boss.BossData and (boss.BossData.DisplayName .. " projectile") or "Enemy projectile"
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

-- Splitting Orbs perk: an orb's first kill splits off two small orbs (half damage, short
-- life) flying off at ±50 degrees. The orb is marked so it splits only once, the children
-- never split, and no split happens while fewer than SPLIT_MIN_FREE projectile ids are
-- free, so a big orb build can never drain the shared pool.
local SPLIT_ANGLE = math.rad(50)
local SPLIT_MIN_FREE = 100
local function splitOrb(p: Projectile, e, now: number)
	p.Split = nil
	if #freeIds < SPLIT_MIN_FREE then
		return
	end
	local base = p.Vel.Magnitude > 1e-3 and (p.Vel * FLAT).Unit or Vector3.new(0, 0, -1)
	for _, sign in ipairs({ -1, 1 }) do
		local c = allocProjectile()
		if not c then
			return
		end
		local d = rotateY(base, sign * SPLIT_ANGLE)
		c.Kind = "Straight"
		c.Visual = p.Visual
		c.Owner = p.Owner
		c.Weapon = p.Weapon
		c.Pos = e.Pos
		c.Vel = d * math.max(20, p.Speed or 38)
		c.Damage = p.Damage * 0.5
		c.Pierce = 1
		c.Radius = p.Radius * 0.7
		c.Life = 0.7
		c.Knockback = p.Knockback
		c.Yaw = yawOf(d)
		c.Hits[e.Uid] = now
	end
end

-- Ricochet perk: a knife that would stop turns toward the nearest enemy it hasn't hit
-- (within RICOCHET_RANGE). Returns true when it bounced (keep it alive).
local RICOCHET_RANGE = 20
local function ricochet(p: Projectile): boolean
	if not p.Bounces or p.Bounces <= 0 then
		return false
	end
	p.Bounces -= 1
	local nextE = grid():Nearest(p.Pos.X, p.Pos.Z, RICOCHET_RANGE, function(x)
		return p.Hits[x.Uid] ~= nil or not x.Alive
	end)
	if not nextE then
		return false
	end
	local speed = math.max(20, p.Vel.Magnitude)
	if p.BounceGain then
		p.Damage *= 1 + p.BounceGain -- Sling: a stone hits harder with every bounce
	end
	local d = flatDir(nextE.Pos - p.Pos, p.Vel.Unit)
	p.Vel = d * speed
	p.Yaw = yawOf(d)
	p.Pierce = 1
	p.Age = math.min(p.Age, p.Life - RICOCHET_RANGE / speed - 0.05)
	return true
end

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
				local died
				local amount = p.Damage
				if p.FirstBonus then
					-- Impale (Spear perk): the first enemy each spear hits takes more
					amount *= 1 + p.FirstBonus
					p.FirstBonus = nil
				end
				local at = e.Pos
				if dir then
					died = damageEnemy(p.Owner, e, amount, dir, p.Knockback, false, p.NoHarvest)
				else
					local d = (e.Pos - p.Pos) * FLAT
					died = damageEnemy(p.Owner, e, amount, d.Magnitude > 1e-3 and d.Unit or Vector3.zAxis, p.Knockback, false, p.NoHarvest)
				end
				if p.Stagger and e.Alive then
					slowEnemy(e, p.Stagger[1], p.Stagger[2], now) -- Sling's Stagger perk
				end
				if died and p.Split then
					splitOrb(p, e, now)
				end
				if p.FlakBurst then
					flakBurst(p, e, at)
				end
				if died and p.Wander then
					-- Wandering Souls (Soul Bolt perk): a soul that kills flies on once
					p.Wander = nil
					p.Pierce += 1
				end
				if p.Pierce < 999 then
					p.Pierce -= 1
					if p.Pierce <= 0 then
						return not ricochet(p)
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
				ctx.RunManager.DamagePlayer(rp, p.Damage, p.Cause)
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

------------------------------------------------------------------------------------------
-- Armoury batch: Ward Shields, Earthsplitter, Starfall, Sling, Plague Censer, Sawblade,
-- Vine Snare, War Horn, Spirit Wisps, Vortex. Helpers live in `Arm` (one local: this
-- module is close to Luau's 200-locals limit). Per-kind data sits in p.X (cleared on alloc).
------------------------------------------------------------------------------------------

local Arm = {}

-- Live projectiles of one weapon (persistent shields / wisps), oldest first.
function Arm.liveList(w): { Projectile }
	local list = {}
	for p in pairs(w.Live) do
		if p.Active and not p.Cancelled then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		return a.Id < b.Id
	end)
	return list
end

-- The enemy (of the `samples` nearest within range) with the most others within `radius`,
-- skipping enemies within `radius` of a spot in `taken`.
function Arm.densest(origin: Vector3, range: number, samples: number, radius: number, taken: { Vector3 }?)
	local cands = nearestEnemies(origin, range, samples)
	local best, bestN = nil, -1
	for _, e in ipairs(cands) do
		local free = true
		for _, at in ipairs(taken or {}) do
			local d = (e.Pos - at) * FLAT
			if d.Magnitude < radius then
				free = false
				break
			end
		end
		if free then
			local n = grid():QueryCircle(e.Pos.X, e.Pos.Z, radius, queryBuf)
			if n > bestN then
				best, bestN = e, n
			end
		end
	end
	return best
end

-- Direction from `origin` to the nearest enemy within range (else the hero's facing).
function Arm.aim(rp, origin: Vector3, range: number): (Vector3, any)
	local t = grid():Nearest(origin.X, origin.Z, range, skipDead)
	return t and flatDir(t.Pos - origin, rp.Facing) or rp.Facing, t
end

--[[
	WARD SHIELDS / AEGIS RING: persistent shields circling the hero (OrbitRadius x area) at
	`speed` studs/s. Every attack tops them up to `amount`, spaces them evenly and refreshes
	their stats; an enemy can be hit by each shield once per `cooldown` s. Bulwark: shields
	smash hostile projectiles (Aegis Ring: the smashed shot bursts for full damage).
]]
function Fire.Shields(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local list = Arm.liveList(w)
	for i = #list, s.amount + 1, -1 do -- fewer allowed (never normally): drop the extras
		list[i].Cancelled = true
		table.remove(list, i)
	end
	local base = list[1] and list[1].Angle or 0
	for _ = #list + 1, s.amount do
		local p = allocProjectile()
		if not p then
			break
		end
		p.Kind = "Ward"
		p.Owner = rp
		p.Weapon = w
		p.Pos = ground(rp.Root.Position)
		p.Vel = Vector3.zero
		p.Life = math.huge
		p.Pierce = 999
		p.X = {}
		w.Live[p] = true
		table.insert(list, p)
	end
	local block = WeaponData.HasPerk(w, "Bulwark")
	local orbit = params.OrbitRadius * s.area
	for i, p in ipairs(list) do
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Angle = base + (i - 1) * TAU / #list
		p.Damage = s.damage
		p.Radius = params.ShieldRadius * s.area
		p.Rehit = s.cooldown
		p.Knockback = s.knockback
		p.X.Orbit = orbit
		p.X.Spin = s.speed / math.max(1, orbit)
		p.X.Reflect = evo ~= nil and evo.Reflect == true
		p.X.ReflectRadius = params.ReflectRadius * s.area
		wards[p] = block or nil
	end
end

function Arm.stepWard(p: Projectile, dt: number, now: number): boolean
	local owner = p.Owner
	if not owner.Alive or not owner.Root then
		return true
	end
	local x = p.X
	if now >= (x.ClearAt or 0) then
		x.ClearAt = now + 10 -- forget old enemy ids now and then (shields never end)
		table.clear(p.Hits)
	end
	p.Angle += x.Spin * dt
	local dir = Vector3.new(math.cos(p.Angle), 0, math.sin(p.Angle))
	p.Pos = ground(owner.Root.Position) + dir * x.Orbit
	p.Vel = dir -- knockback pushes outward
	p.Yaw = yawOf(dir)
	return collideEnemies(p, now)
end

-- Bulwark: a hostile projectile touching a shield is smashed (true = remove it).
function Arm.wardBlock(h: Projectile): boolean
	for ward in pairs(wards) do
		if ward.Active and not ward.Cancelled then
			local d = (ward.Pos - h.Pos) * FLAT
			if d.Magnitude <= ward.Radius + h.Radius + 0.3 then
				if ward.X.Reflect and ward.Owner.Alive then
					burstAround(ward.Owner, h.Pos, ward.X.ReflectRadius, ward.Damage)
				end
				pushFx("wb", { r1(h.Pos.X), r1(h.Pos.Z), ward.X.Reflect and 1 or 0 })
				return true
			end
		end
	end
	return false
end

--[[
	EARTHSPLITTER / WORLDBREAKER: fissures race along the floor (speed x duration studs)
	toward the nearest enemy, fanned FanAngle degrees apart (Worldbreaker: evenly all around).
	Every StepDist studs stone spikes burst (SpikeRadius x area); each enemy is hit once per
	fissure. Aftershock perk: the end of each fissure erupts (AftershockRadius x area).
]]
function Fire.Quake(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local aim = Arm.aim(rp, origin, params.Range)
	local after = WeaponData.HasPerk(w, "Aftershock")
	for i = 1, s.amount do
		local p = allocProjectile()
		if not p then
			return
		end
		local dir
		if evo and evo.Ring then
			dir = rotateY(aim, (i - 1) * TAU / s.amount)
		else
			dir = rotateY(aim, math.rad((i - (s.amount + 1) / 2) * params.FanAngle))
		end
		p.Kind = "Fissure"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin + dir * 1.5
		p.Y = Config.ArenaOrigin.Y + 0.6
		p.Vel = dir * s.speed
		p.Damage = s.damage
		p.Pierce = 999
		p.Radius = 0
		p.Life = s.duration
		p.Knockback = s.knockback
		p.Yaw = yawOf(dir)
		p.X = {
			Step = params.StepDist * math.sqrt(s.area),
			Next = 0,
			Dist = 0,
			R = params.SpikeRadius * s.area,
			Evo = evo and 1 or 0,
			After = after and params.AftershockRadius * s.area or nil,
			AfterShare = params.AftershockShare,
		}
	end
	Fx.Sound("Hit")
end

-- Stone spikes at a point of a fissure: every enemy there it has not hit yet.
function Arm.spikes(p: Projectile, at: Vector3, radius: number, damage: number, now: number)
	local n = grid():QueryCircle(at.X, at.Z, radius, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive and p.Hits[e.Uid] == nil then
			p.Hits[e.Uid] = now
			hitEnemy(p.Owner, e, damage, at, p.Knockback)
		end
	end
end

function Arm.stepFissure(p: Projectile, dt: number, now: number): boolean
	if not p.Owner.Alive then
		return true
	end
	local x = p.X
	p.Pos += p.Vel * dt
	x.Dist += p.Vel.Magnitude * dt
	if x.Dist >= x.Next then
		x.Next += x.Step
		Arm.spikes(p, p.Pos, x.R, p.Damage, now)
		pushFx("qk", { r1(p.Pos.X), r1(p.Pos.Z), r1(x.R), x.Evo })
	end
	return outOfArena(p.Pos)
end

--[[
	STARFALL / CATACLYSM: each meteor picks the densest crowd in Range (spread out: never two
	on the same crowd), shows a warning ring and lands FallTime s later: full damage and a
	push to everything within BlastRadius x area (crits and procs as a normal hit), then a
	crater burns CraterShare of the damage every CraterTick s for `duration` s (Molten Core:
	MoltenScale wider).
]]
function Fire.Meteor(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local radius = params.BlastRadius * s.area
	local taken = {}
	local molten = WeaponData.HasPerk(w, "Molten")
	for i = 1, s.amount do
		local t = Arm.densest(origin, params.Range, 10, radius, taken)
		if not t then
			if i == 1 then
				w.Timer = math.min(w.Timer, 0.4) -- nothing in range: look again soon
			end
			return
		end
		local at = ground(t.Pos)
		table.insert(taken, at)
		local p = allocProjectile()
		if not p then
			return
		end
		local fall = params.FallTime + (i - 1) * 0.12
		p.Kind = "Meteor"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = at + Vector3.new(-9, 0, -5)
		p.Vel = Vector3.zero
		p.Y = Config.ArenaOrigin.Y + 36
		p.Life = fall
		p.Damage = s.damage
		p.Pierce = 999
		p.Radius = 0
		p.Knockback = s.knockback
		p.Yaw = yawOf(Vector3.new(9, 0, 5).Unit)
		p.X = {
			From = p.Pos,
			To = at,
			R = radius,
			Crater = s.duration,
			CraterR = radius * params.CraterScale * (molten and params.MoltenScale or 1),
			CraterDamage = s.damage * params.CraterShare,
			CraterTick = params.CraterTick,
		}
		pushFx("mt", { r1(at.X), r1(at.Z), r1(radius), r1(fall), evo and 1 or 0 })
	end
end

function Arm.stepMeteor(p: Projectile, _dt: number, _now: number): boolean
	local x = p.X
	local u = math.clamp(p.Age / p.Life, 0, 1)
	p.Pos = x.From:Lerp(x.To, u)
	p.Y = Config.ArenaOrigin.Y + 0.8 + 35 * (1 - u * u)
	return false
end

function Arm.landMeteor(p: Projectile)
	local x = p.X
	local owner = p.Owner
	if not owner.Alive then
		return
	end
	local at = x.To
	local n = grid():QueryCircle(at.X, at.Z, x.R, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive then
			hitEnemy(owner, e, p.Damage, at, p.Knockback)
		end
	end
	Fx.Explosion(at, x.R)
	if x.Crater > 0 then
		table.insert(zones, { Pos = at, Radius = x.CraterR, Life = x.Crater, Tick = x.CraterTick, Timer = x.CraterTick, Damage = x.CraterDamage, Owner = owner })
		Fx.Pool(at, x.CraterR, x.Crater, true)
	end
	Fx.Sound("Hit")
end

--[[
	SLING / GIANTFELLER: stones at the nearest enemies; a stone bounces on to the nearest
	enemy it has not hit until it has hit `pierce` enemies (the Ricochet code), each bounce
	BounceGain harder (Giantfeller EvoBounceGain). Stagger perk: hit enemies (not bosses)
	almost stop for StaggerSeconds.
]]
function Fire.Sling(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local targets = nearestEnemies(origin, s.speed * s.duration * 1.2, s.amount)
	local stagger = WeaponData.HasPerk(w, "Stagger") and { params.StaggerSlow, params.StaggerSeconds } or nil
	for i = 1, s.amount do
		local p = allocProjectile()
		if not p then
			return
		end
		local target = targets[((i - 1) % math.max(1, #targets)) + 1]
		local dir = target and flatDir(target.Pos - origin, rp.Facing) or rotateY(rp.Facing, (i - (s.amount + 1) / 2) * math.rad(15))
		if target and i > #targets then
			dir = rotateY(dir, (i % 2 == 0 and 1 or -1) * math.rad(8))
		end
		p.Kind = "Straight"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin + dir * 1.5
		p.Vel = dir * s.speed
		p.Damage = s.damage
		p.Pierce = 1
		p.Bounces = math.max(0, s.pierce - 1)
		p.BounceGain = evo and params.EvoBounceGain or params.BounceGain
		p.Stagger = stagger
		p.Radius = params.Radius * s.area
		p.Life = s.duration
		p.Knockback = s.knockback
		p.Yaw = yawOf(dir)
	end
	Fx.Sound("Hit")
end

--[[
	PLAGUE CENSER / PESTILENCE: a cloud (Radius x area) opens on each of the nearest
	enemies and drifts after the nearest enemy at `speed`, hurting everything inside every
	Tick s for `duration` s. Choking Fumes: enemies inside are slowed (ChokeSlow).
	Pestilence: enemies it hurts keep taking PoisonShare per tick for PoisonSeconds (the
	Phoenix Stride burn list).
]]
function Fire.Cloud(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local targets = nearestEnemies(origin, params.Range, s.amount)
	if #targets == 0 then
		w.Timer = math.min(w.Timer, 0.4)
		return
	end
	local choke = WeaponData.HasPerk(w, "Choking")
	for i = 1, s.amount do
		local target = targets[((i - 1) % #targets) + 1]
		local p = allocProjectile()
		if not p then
			return
		end
		local off = i > #targets and rotateY(Vector3.xAxis, i * 2.4) * 3 or Vector3.zero
		p.Kind = "Cloud"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = ground(target.Pos) + off
		p.Y = Config.ArenaOrigin.Y + 1.2
		p.Vel = Vector3.zero
		p.Speed = s.speed
		p.Target = target
		p.TargetUid = target.Uid
		p.Damage = s.damage
		p.Pierce = 999
		p.Radius = 0
		p.Life = s.duration
		p.Knockback = 0
		p.X = {
			R = params.Radius * s.area,
			Tick = params.Tick,
			T = 0.2,
			Choke = choke and params.ChokeSlow or nil,
			Poison = evo ~= nil and evo.Poison == true,
			PoisonSeconds = params.PoisonSeconds,
			PoisonShare = params.PoisonShare,
		}
	end
end

function Arm.stepCloud(p: Projectile, dt: number, now: number): boolean
	local owner = p.Owner
	if not owner.Alive then
		return true
	end
	local x = p.X
	local t = p.Target
	if not (t and t.Alive and t.Uid == p.TargetUid) then
		t = nil
		if now >= (p.SeekAt or 0) then
			p.SeekAt = now + 0.3
			t = grid():Nearest(p.Pos.X, p.Pos.Z, 14, skipDead)
		end
		p.Target = t
		p.TargetUid = t and t.Uid or nil
	end
	if t then
		local to = (t.Pos - p.Pos) * FLAT
		local d = to.Magnitude
		if d > 0.5 then
			p.Pos += to / d * math.min(d, p.Speed * dt)
			p.Yaw = yawOf(to / d)
		end
	end
	x.T -= dt
	if x.T <= 0 then
		x.T = x.Tick
		local n = grid():QueryCircle(p.Pos.X, p.Pos.Z, x.R, queryBuf)
		local hits = table.move(queryBuf, 1, n, 1, {})
		for _, e in ipairs(hits) do
			if e.Alive then
				if x.Choke then
					slowEnemy(e, x.Choke, x.Tick + 0.15, now)
				end
				damageEnemy(owner, e, p.Damage, nil, 0)
				if x.Poison and e.Alive then
					burns[e] = { Uid = e.Uid, Until = now + x.PoisonSeconds, Next = now + x.Tick, Tick = x.Tick, Damage = p.Damage * x.PoisonShare, Owner = owner, Weapon = p.Weapon }
				end
			end
		end
	end
	return false
end

--[[
	SAWBLADE / RUINWHEEL: saws roll at the nearest enemies, biting every enemy they touch
	every Rehit s and slowing to GrindSlow of their speed while touching any (they chew
	through crowds). Rebound perk: at the end of its run a saw turns to the nearest enemy
	within ReboundRange for half a run more (Ruinwheel: Rebounds times).
]]
function Fire.Saw(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local targets = nearestEnemies(origin, params.Range, s.amount)
	local rebounds = (evo and evo.Rebounds) or (WeaponData.HasPerk(w, "Rebound") and 1 or 0)
	for i = 1, s.amount do
		local p = allocProjectile()
		if not p then
			return
		end
		local target = targets[((i - 1) % math.max(1, #targets)) + 1]
		local dir = target and flatDir(target.Pos - origin, rp.Facing) or rotateY(rp.Facing, (i - 1) * TAU / s.amount)
		if target and i > #targets then
			dir = rotateY(dir, (i % 2 == 0 and 1 or -1) * math.rad(18))
		end
		p.Kind = "Saw"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin + dir * 1.5
		p.Y = Config.ArenaOrigin.Y + 1.4
		p.Vel = dir * s.speed
		p.Damage = s.damage
		p.Pierce = 999
		p.Rehit = params.Rehit
		p.Radius = params.Radius * s.area
		p.Life = s.duration
		p.Knockback = s.knockback
		p.Yaw = yawOf(dir)
		p.X = { Grind = params.GrindSlow, Rebounds = rebounds, Range = params.ReboundRange }
	end
	Fx.Sound("Hit")
end

function Arm.stepSaw(p: Projectile, dt: number, now: number): boolean
	local n = grid():QueryCircle(p.Pos.X, p.Pos.Z, p.Radius, queryBuf)
	local grinding = false
	for i = 1, n do
		if queryBuf[i].Alive then
			grinding = true
			break
		end
	end
	p.Pos += p.Vel * dt * (grinding and p.X.Grind or 1)
	if outOfArena(p.Pos) then
		return true
	end
	return collideEnemies(p, now)
end

-- Rebound: true = the saw keeps going (re-aimed, half a run left).
function Arm.reboundSaw(p: Projectile): boolean
	local x = p.X
	if x.Rebounds <= 0 or not p.Owner.Alive then
		return false
	end
	local t = grid():Nearest(p.Pos.X, p.Pos.Z, x.Range, skipDead)
	if not t then
		return false
	end
	x.Rebounds -= 1
	local dir = flatDir(t.Pos - p.Pos, -p.Vel.Unit)
	p.Vel = dir * p.Vel.Magnitude
	p.Yaw = yawOf(dir)
	p.Age = p.Life * 0.5
	return true
end

--[[
	VINE SNARE / STRANGLEROOT: vines burst up under the nearest enemies: every Tick s for
	`duration` s everything in the ring (Radius x area) is rooted (RootSlow; bosses are never
	slowed) and hurt. Thornbloom perk: an enemy that dies there bursts into thorns (ThornShare
	damage around it, at most ThornsPerTick per tick). Strangleroot: enemies in the ring are
	dragged toward its middle (PullShare of the way per tick).
]]
function Fire.Vines(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local radius = params.Radius * s.area
	local taken = {}
	local thorn = WeaponData.HasPerk(w, "Thornbloom")
	local n = grid():QueryCircle(origin.X, origin.Z, params.Range, queryBuf)
	if n == 0 then
		w.Timer = math.min(w.Timer, 0.4)
		return
	end
	for _ = 1, s.amount do
		local t = Arm.densest(origin, params.Range, 8, radius, taken)
		if not t then
			break
		end
		local at = ground(t.Pos)
		table.insert(taken, at)
		local p = allocProjectile()
		if not p then
			return
		end
		p.Kind = "Snare"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = at
		p.Y = Config.ArenaOrigin.Y
		p.Vel = Vector3.zero
		p.Damage = s.damage
		p.Pierce = 999
		p.Radius = 0
		p.Life = s.duration
		p.Knockback = 0
		p.Yaw = rng:NextNumber(0, TAU)
		p.X = {
			R = radius,
			Tick = params.Tick,
			T = 0,
			Root = params.RootSlow,
			Thorn = thorn and params.ThornRadius * s.area or nil,
			ThornShare = params.ThornShare,
			ThornsPerTick = params.ThornsPerTick,
			Pull = evo ~= nil and evo.Pull == true and params.PullShare or nil,
		}
		pushFx("vn", { r1(at.X), r1(at.Z), r1(radius), evo and 1 or 0 })
	end
end

function Arm.stepSnare(p: Projectile, dt: number, now: number): boolean
	local owner = p.Owner
	if not owner.Alive then
		return true
	end
	local x = p.X
	x.T -= dt
	if x.T > 0 then
		return false
	end
	x.T = x.Tick
	local c = p.Pos
	local n = grid():QueryCircle(c.X, c.Z, x.R, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	local thorns = 0
	for _, e in ipairs(hits) do
		if e.Alive then
			slowEnemy(e, x.Root, x.Tick + 0.15, now)
			local rel = (c - e.Pos) * FLAT
			local d = rel.Magnitude
			local kb = (x.Pull and d > 1) and pullSpeed(d * x.Pull) or 0
			local at = e.Pos
			if damageEnemy(owner, e, p.Damage, d > 1e-3 and rel / d or nil, kb) and x.Thorn and thorns < x.ThornsPerTick then
				thorns += 1
				burstAround(owner, at, x.Thorn, p.Damage * x.ThornShare)
				pushFx("vt", { r1(at.X), r1(at.Z), r1(x.Thorn) })
			end
		end
	end
	return false
end

--[[
	WAR HORN / TITAN'S ROAR: a shockwave cone (Range x area studs, HalfAngle degrees each
	side) toward the nearest enemy; more blasts point evenly around. Everything in it is hit,
	pushed hard (knockback) and dazed (DazeSlow for `duration` s, not bosses). Echo perk: a
	second blast EchoDelay s later with EchoShare damage. Titan's Roar: full-circle blasts,
	one after another, each a little wider.
]]
function Arm.hornBlast(rp, origin: Vector3, dir: Vector3, range: number, half: number, damage: number, knockback: number, daze: number, slow: number, evo: boolean)
	local now = ctx.RunManager.GetRunTime()
	local cosHalf = math.cos(half)
	local n = grid():QueryCircle(origin.X, origin.Z, range, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive then
			local rel = (e.Pos - origin) * FLAT
			local d = rel.Magnitude
			if half >= math.pi or d <= 1.5 + e.Radius or (rel / d):Dot(dir) >= cosHalf then
				slowEnemy(e, slow, daze, now)
				hitEnemy(rp, e, damage, origin, knockback)
			end
		end
	end
	pushFx("hn", { r1(origin.X), r1(origin.Z), r1(yawOf(dir)), r1(range), math.floor(math.deg(math.min(half, math.pi)) + 0.5), evo and 1 or 0 })
end

function Fire.Horn(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local range = params.Range * s.area
	local origin = ground(rp.Root.Position)
	local aim = Arm.aim(rp, origin, range * 1.6)
	local echo = WeaponData.HasPerk(w, "Echo")
	local shots = {}
	if evo and evo.Roar then
		for i = 1, s.amount do
			table.insert(shots, { Delay = (i - 1) * 0.18, Dir = aim, Half = math.pi, Range = range * (1 + (i - 1) * 0.15), Share = 1 })
		end
	else
		for i = 1, s.amount do
			table.insert(shots, { Delay = 0, Dir = rotateY(aim, (i - 1) * TAU / s.amount), Half = math.rad(params.HalfAngle), Range = range, Share = 1 })
		end
	end
	if echo then
		local n = #shots
		for i = 1, n do
			local sh = shots[i]
			table.insert(shots, { Delay = sh.Delay + params.EchoDelay, Dir = sh.Dir, Half = sh.Half, Range = sh.Range * 0.85, Share = params.EchoShare })
		end
	end
	for _, sh in ipairs(shots) do
		local function blast()
			if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() then
				return
			end
			Arm.hornBlast(rp, ground(rp.Root.Position), sh.Dir, sh.Range, sh.Half, s.damage * sh.Share, s.knockback * sh.Share, s.duration, params.DazeSlow, evo ~= nil)
		end
		if sh.Delay <= 0 then
			blast()
		else
			task.delay(sh.Delay, blast)
		end
	end
	Fx.Sound("Hit")
end

--[[
	SPIRIT WISPS / WISP CHOIR: persistent wisps circling the hero (OrbitRadius). Every
	attack tops them up to `amount` and sends each resting wisp at a different near enemy
	(within Range x area): it hits `pierce` enemies (re-targeting the nearest unhit one within
	Retarget studs) or flies for `duration` s, then floats back. Glow perk: resting wisps sting
	touching enemies for GlowShare damage every GlowEvery s (Wisp Choir EvoGlowShare).
]]
function Fire.Wisps(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local list = Arm.liveList(w)
	for i = #list, s.amount + 1, -1 do
		list[i].Cancelled = true
		table.remove(list, i)
	end
	for _ = #list + 1, s.amount do
		local p = allocProjectile()
		if not p then
			break
		end
		p.Kind = "Wisp"
		p.Owner = rp
		p.Weapon = w
		p.Pos = ground(rp.Root.Position)
		p.Vel = Vector3.zero
		p.Life = math.huge
		p.Pierce = 999
		p.Phase = "Back"
		p.X = { Glow = 0 }
		w.Live[p] = true
		table.insert(list, p)
	end
	local glow = WeaponData.HasPerk(w, "Glow") and (evo and params.EvoGlowShare or params.GlowShare) or nil
	local resting = {}
	for i, p in ipairs(list) do
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Damage = s.damage
		p.Radius = params.Radius * s.area
		p.Knockback = s.knockback
		p.Speed = s.speed
		local x = p.X
		x.Slot = (i - 1) * TAU / #list
		x.OrbitR = params.OrbitRadius
		x.Spin = params.OrbitSpin
		x.GlowShare = glow
		x.GlowEvery = params.GlowEvery
		x.Pierce = s.pierce
		x.MaxDart = s.duration
		x.Retarget = params.Retarget
		if p.Phase ~= "Dart" then
			table.insert(resting, p)
		end
	end
	if #resting == 0 then
		return
	end
	local origin = ground(rp.Root.Position)
	local targets = nearestEnemies(origin, params.Range * s.area, #resting)
	if #targets == 0 then
		w.Timer = math.min(w.Timer, 0.3)
		return
	end
	for i, p in ipairs(resting) do
		local t = targets[((i - 1) % #targets) + 1]
		p.Phase = "Dart"
		p.Target = t
		p.TargetUid = t.Uid
		p.X.Left = p.X.Pierce
		p.X.Dart = 0
		table.clear(p.Hits)
	end
end

function Arm.stepWisp(p: Projectile, dt: number, now: number): boolean
	local owner = p.Owner
	if not owner.Alive or not owner.Root then
		return true
	end
	local x = p.X
	local home = ground(owner.Root.Position)
	local t = (now * x.Spin) + x.Slot
	local slot = home + Vector3.new(math.cos(t), 0, math.sin(t)) * x.OrbitR
	if p.Phase == "Dart" then
		x.Dart += dt
		local e = p.Target
		if not (e and e.Alive and e.Uid == p.TargetUid) then
			e = grid():Nearest(p.Pos.X, p.Pos.Z, x.Retarget, function(o)
				return p.Hits[o.Uid] ~= nil or not o.Alive
			end)
			p.Target = e
			p.TargetUid = e and e.Uid or nil
		end
		if not e or x.Dart > x.MaxDart then
			p.Phase = "Back"
		else
			local to = (e.Pos - p.Pos) * FLAT
			local d = to.Magnitude
			if d <= p.Radius + e.Radius then
				p.Hits[e.Uid] = now
				damageEnemy(owner, e, p.Damage, d > 1e-3 and to / d or nil, p.Knockback)
				x.Left -= 1
				p.Target = nil
				p.TargetUid = nil
				if x.Left <= 0 then
					p.Phase = "Back"
				end
			elseif d > 1e-3 then
				p.Vel = to / d * p.Speed
				p.Pos += p.Vel * math.min(dt, d / p.Speed)
				p.Yaw = yawOf(to / d)
			end
		end
	else
		local to = (slot - p.Pos) * FLAT
		local d = to.Magnitude
		if p.Phase == "Back" and d <= 1.5 then
			p.Phase = "Orbit"
		end
		if p.Phase == "Orbit" then
			p.Pos = slot
			if x.GlowShare and now >= x.Glow then
				x.Glow = now + x.GlowEvery
				local n = grid():QueryCircle(p.Pos.X, p.Pos.Z, p.Radius + 0.6, queryBuf)
				for i = 1, math.min(n, 3) do
					local e = queryBuf[i]
					if e.Alive then
						damageEnemy(owner, e, p.Damage * x.GlowShare, nil, 0, true)
					end
				end
			end
		elseif d > 1e-3 then
			p.Pos += to / d * math.min(d, p.Speed * 1.2 * dt)
		end
	end
	p.Y = Config.ArenaOrigin.Y + Config.Projectiles.Height + 0.4 + math.sin(now * 3 + p.Id) * 0.3
	return false
end

--[[
	VORTEX / SINGULARITY: rifts open on the densest crowds (Radius x area): every Tick s for
	`duration` s everything inside is hurt and dragged toward the middle (at most Pull studs
	a tick; Singularity EvoPull). Implosion perk: it collapses at the end for ImplodeMult x
	the tick damage (Singularity EvoImplodeMult).
]]
function Fire.Vortex(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local radius = params.Radius * s.area
	local taken = {}
	local implode = WeaponData.HasPerk(w, "Implosion")
	for i = 1, s.amount do
		local t = Arm.densest(origin, params.Range, 10, radius * 1.5, taken)
		if not t then
			if i == 1 then
				w.Timer = math.min(w.Timer, 0.4)
			end
			return
		end
		local at = ground(t.Pos)
		table.insert(taken, at)
		local p = allocProjectile()
		if not p then
			return
		end
		p.Kind = "Vortex"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = at
		p.Y = Config.ArenaOrigin.Y + 0.15
		p.Vel = Vector3.zero
		p.Damage = s.damage
		p.Pierce = 999
		p.Radius = 0
		p.Life = s.duration
		p.Knockback = 0
		p.X = {
			R = radius,
			Tick = params.Tick,
			T = 0.1,
			Pull = evo and params.EvoPull or params.Pull,
			Implode = implode and (evo and params.EvoImplodeMult or params.ImplodeMult) or nil,
			Evo = evo and 1 or 0,
		}
		pushFx("vx", { r1(at.X), r1(at.Z), r1(radius), r1(s.duration), evo and 1 or 0 })
	end
end

function Arm.stepVortex(p: Projectile, dt: number, now: number): boolean
	local owner = p.Owner
	if not owner.Alive then
		return true
	end
	local x = p.X
	p.Yaw += dt * 4
	x.T -= dt
	if x.T > 0 then
		return false
	end
	x.T = x.Tick
	local c = p.Pos
	local n = grid():QueryCircle(c.X, c.Z, x.R, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive then
			local rel = (c - e.Pos) * FLAT
			local d = rel.Magnitude
			local kb = d > 0.8 and pullSpeed(math.min(d * 0.6, x.Pull)) or 0
			damageEnemy(owner, e, p.Damage, d > 1e-3 and rel / d or nil, kb)
		end
	end
	return false
end

function Arm.implode(p: Projectile)
	local x = p.X
	if not x.Implode or not p.Owner.Alive then
		return
	end
	local c = p.Pos
	local n = grid():QueryCircle(c.X, c.Z, x.R, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	for _, e in ipairs(hits) do
		if e.Alive then
			hitEnemy(p.Owner, e, p.Damage * x.Implode, c, 6)
		end
	end
	pushFx("vi", { r1(c.X), r1(c.Z), r1(x.R), x.Evo })
end

-- Kind → step function for the armoury batch (true = remove the projectile).
Arm.Step = {
	Ward = Arm.stepWard,
	Fissure = Arm.stepFissure,
	Meteor = Arm.stepMeteor,
	Cloud = Arm.stepCloud,
	Saw = Arm.stepSaw,
	Snare = Arm.stepSnare,
	Wisp = Arm.stepWisp,
	Vortex = Arm.stepVortex,
}

-- A projectile of the batch reached its Life: true = it keeps going (a saw's rebound).
function Arm.expire(p: Projectile): boolean
	local kind = p.Kind
	if kind == "Fissure" then
		local x = p.X
		if x.After and p.Owner.Alive then
			burstAround(p.Owner, p.Pos, x.After, p.Damage * x.AfterShare)
			pushFx("qk", { r1(p.Pos.X), r1(p.Pos.Z), r1(x.After), 2 + x.Evo })
		end
	elseif kind == "Meteor" then
		Arm.landMeteor(p)
	elseif kind == "Saw" then
		return Arm.reboundSaw(p)
	elseif kind == "Vortex" then
		Arm.implode(p)
	end
	return false
end

local function stepProjectile(p: Projectile, dt: number, now: number): boolean -- true = remove
	if p.Cancelled then
		return true
	end
	p.Age += dt
	if p.Age >= p.Life then
		if p.X and Arm.expire(p) then
			return false -- a saw's rebound
		end
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
	local armStep = Arm.Step[kind]
	if armStep then
		return armStep(p, dt, now)
	end
	if kind == "Thrust" then
		-- spear: out to full reach and back (sin curve), riding along with its thrower
		local owner = p.Owner
		if not owner.Alive or not owner.Root then
			return true
		end
		local u = math.clamp(p.Age / p.Life, 0, 1)
		local base = ground(owner.Root.Position) + p.Dir * 1.2
		p.Pos = base + p.Dir * (p.Reach * math.sin(math.pi * u))
		if p.Burst and u >= 0.5 then
			local b = p.Burst
			p.Burst = nil
			burstAround(owner, p.Pos, b.Radius, p.Damage * b.Share)
			pushFx("lb", { r1(p.Pos.X), r1(p.Pos.Z), r1(b.Radius) })
		end
		-- hits only while going out (Vel stays the outward push direction)
		if not p.Spent and u <= 0.55 and collideEnemies(p, now) then
			p.Spent = true
		end
		return false
	elseif kind == "Hook" then
		local owner = p.Owner
		if not owner.Alive or not owner.Root then
			return true
		end
		local home = ground(owner.Root.Position)
		if p.Phase == "Out" then
			local t = p.Target
			if not (t and t.Alive and t.Uid == p.TargetUid) or p.Age > p.OutLimit then
				p.Phase = "Back"
			else
				local to = (t.Pos - p.Pos) * FLAT
				if to.Magnitude <= p.Radius + t.Radius + 0.6 then
					hookBite(p, t, home)
					p.Phase = "Back"
				else
					p.Vel = to.Unit * p.Speed
					p.Pos += p.Vel * dt
					p.Yaw = yawOf(p.Vel)
				end
			end
		else
			-- reel back in, the point still facing away from the hero
			local to = (home - p.Pos) * FLAT
			local d = to.Magnitude
			if d <= 2.5 then
				return true
			end
			p.Vel = to / d * p.Speed * 1.3
			p.Pos += p.Vel * dt
			p.Yaw = yawOf(-to)
		end
		return false
	elseif kind == "Soul" then
		local t = p.Target
		if not (t and t.Alive and t.Uid == p.TargetUid and p.Hits[t.Uid] == nil) then
			t = nil
			if now >= (p.SeekAt or 0) then
				p.SeekAt = now + 0.15
				t = grid():Nearest(p.Pos.X, p.Pos.Z, p.Seek or 30, function(x)
					return p.Hits[x.Uid] ~= nil or not x.Alive
				end)
			end
			p.Target = t
			p.TargetUid = t and t.Uid or nil
		end
		if t then
			local cur = p.Vel.Unit
			local want = flatDir(t.Pos - p.Pos, cur)
			p.Vel = flatDir(cur:Lerp(want, math.min(1, p.TurnRate * dt)), cur) * p.Speed
		end
		p.Pos += p.Vel * dt
		p.Yaw = yawOf(p.Vel)
		if outOfArena(p.Pos) then
			return true
		end
		return collideEnemies(p, now)
	elseif kind == "Totem" then
		p.PulseTimer -= dt
		if p.PulseTimer <= 0 then
			p.PulseTimer = p.Pulse
			if p.Owner.Alive then
				totemPulse(p, now)
			end
		end
		return false
	elseif kind == "Turret" then
		p.ShotTimer -= dt
		if p.ShotTimer <= 0 then
			local target = p.Owner.Alive and grid():Nearest(p.Pos.X, p.Pos.Z, p.Range, function(x)
				return not x.Alive
			end) or nil
			if target then
				p.ShotTimer = p.ShotEvery
				turretShoot(p, target)
			else
				p.ShotTimer = 0.2
			end
		end
		return false
	end
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
		if next(wards) ~= nil and Arm.wardBlock(p) then
			return true -- smashed by a Ward Shield (Bulwark)
		end
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
					damageEnemy(z.Owner, e, z.Damage, nil, 0)
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
	-- Fire Trail patches and their ignites
	for i = #patches, 1, -1 do
		if rp == nil or patches[i].Owner == rp then
			table.remove(patches, i)
		end
	end
	for e, b in pairs(burns) do
		if rp == nil or b.Owner == rp then
			burns[e] = nil
		end
	end
end

-- Removes every hostile (boss) projectile (the portal opening).
function WeaponSystem.ClearHostile()
	for i = #live, 1, -1 do
		local p = live[i]
		if p.Hostile then
			p.Cancelled = true
		end
	end
end

-- Live counts for tests (preview weapons-sim): projectiles by kind, flame patches, ignites.
function WeaponSystem.DebugCounts(): { [string]: number }
	local out: { [string]: number } = {}
	for _, p in ipairs(live) do
		local k = p.Hostile and "Hostile" or tostring(p.Kind)
		out[k] = (out[k] or 0) + 1
	end
	out.Patches = #patches
	local n = 0
	for _ in pairs(burns) do
		n += 1
	end
	out.Burning = n
	out.Pools = #zones
	return out
end

function WeaponSystem.Clear()
	WeaponSystem.ClearOwner(nil)
	sync()
end

--[[
	Steady Aim (CharacterData SteadyAim, the Ranger): standing still for Delay seconds turns
	on +Damage (Longbow) / +OtherDamage (every other weapon) for new shots until the hero
	moves again. Stillness is decided from the server-observed root position
	(rp.LastStillPos: moving more than STILL_EPS studs flat breaks it); the client-owned
	velocity (rp.MoveDir, RunManager) is only an extra check, so a spoofed zero velocity
	cannot keep the bonus while walking. The player attribute SteadyAim drives the HUD chip.
]]
local STILL_EPS = 0.3

local function setSteadyAim(rp, on: boolean)
	if rp.SteadyAim == nil or (rp.SteadyAim == true) ~= on then
		rp.SteadyAim = on
		rp.Player:SetAttribute("SteadyAim", on)
	end
end

local function updateSteadyAim(rp, dt: number)
	local char = CharacterData.Characters[rp.CharacterId]
	local trait = char and char.SteadyAim
	if not trait then
		return
	end
	local root = rp.Root
	if not root then
		rp.StillTime = 0
		rp.LastStillPos = nil
		setSteadyAim(rp, false)
		return
	end
	local pos = root.Position
	local last = rp.LastStillPos
	local moved = true
	if last then
		local dx, dz = pos.X - last.X, pos.Z - last.Z
		moved = dx * dx + dz * dz > STILL_EPS * STILL_EPS
	end
	if moved or rp.MoveDir.Magnitude > 0.1 then
		rp.StillTime = 0
		rp.LastStillPos = pos
		setSteadyAim(rp, false)
	else
		rp.StillTime = (rp.StillTime or 0) + dt
		if rp.StillTime >= trait.Delay then
			rp.SteadyAimBonus = trait.Damage
			rp.SteadyAimOther = trait.OtherDamage or trait.Damage
			setSteadyAim(rp, true)
		end
	end
end

function WeaponSystem.Step(dt: number)
	if ctx.RunManager.IsSimulating() then
		local now = ctx.RunManager.GetRunTime()
		-- 1) fire weapons
		for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
			if rp.Alive and not rp.Paused then
				updateSteadyAim(rp, dt)
			end
			if rp.Alive and not rp.Paused and rp.Root then
				for _, id in ipairs(rp.WeaponOrder) do
					local w = rp.Weapons[id]
					w.Timer -= dt
					if w.Timer <= 0 then
						local def = WeaponData.Weapons[id]
						local s = weaponStats(rp, w)
						w.Timer = s.cooldown
						-- Spare Quiver (per weapon); turrets / totems never pass their cap
						s.amount = WeaponData.CapAmount(id, s.amount + ctx.ItemSystem.ExtraShot(rp, w))
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
		-- 3) pools, Fire Trail patches and ignites
		stepZones(dt)
		stepPatches(dt, now)
	end

	syncTimer += dt
	if syncTimer >= 1 / Config.Net.ProjectileSyncHz then
		syncTimer = 0
		sync()
		flushFx()
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
