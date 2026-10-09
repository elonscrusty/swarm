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
local MetaUpgradeData = require(game:GetService("ReplicatedStorage").Shared.MetaUpgradeData)
local Fx = require(script.Parent.Fx)
local HeightGrid = require(script.Parent.HeightGrid)
local RunCfg = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig)
local Nav = RunCfg.Nav
local BuildRules = require(game:GetService("ReplicatedStorage").SwarmV2.Run.BuildRules)

local WeaponSystem = {}

--[[
	[stream B] Rank system combat core (RunConfig.Builds.Enabled; RunConfig.Combat; BuildRules;
	docs/redesign/gameplay/BUILDS.md). Helpers live in `Rk` (one local: this module is close to
	Luau's 200-locals limit). Public API for the class kits (stream C):
	  WeaponSystem.Damage(rp, enemy, coefficient, weaponId, rank, opts) -> (died, dealt)
	  WeaponSystem.HasLineOfSight(fromPos, toPos) -> boolean
	  WeaponSystem.NearestTarget(rp, range, opts) -> enemy?
	  WeaponSystem.CanEmit(rp, parentOpts?) -> boolean   (secondary budget + chain depth)
	  WeaponSystem.NewCast() -> castId                   (per-target hit ledger key)
	  WeaponSystem.ApplyScorch / ApplySlow / Stagger     (status rules)
]]
local Rk: { [string]: any } = {}
local Combat: { [string]: any } = RunCfg.Combat

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

--[[
	Ground level of the hits being resolved now (maps with height, HeightGrid): set around
	each weapon's fire (the hero's ground), each projectile (its launch ground, p.Ground),
	each pool / patch and each delayed hit. New projectiles start at this ground, and while
	a height grid is active the enemy grid's vertical band (SpatialGrid BandY) keeps every
	hit and every target pick on this level (|dy| <= Nav.HitBand). Flat arenas: the floor
	height and no band, exactly as before.
]]
local curGround = Config.ArenaOrigin.Y
local function useGround(y: number?)
	curGround = y or Config.ArenaOrigin.Y
	local g = ctx.EnemySpawner.Grid
	if y and HeightGrid.IsActive() then
		g.BandY = y
		g.Band = Nav.HitBand
	else
		g.BandY = nil
	end
end

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
	p.Ground = curGround -- the launch ground (hit band, flight height)
	p.Floor = nil -- a ballistic shot's landing ground (Lob)
	p.Y = curGround + Config.Projectiles.Height
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
	p.Seeking = nil
	p.Gravity = nil
	-- armoury batch: per-kind data, Sling stagger / bounce gain
	p.X = nil
	p.Stagger = nil
	p.BounceGain = nil
	-- class signature weapons: derived hits never proc (NoProc), hit hook name
	p.NoProc = nil
	p.NoProcOnBounce = nil
	p.Hook = nil
	-- [stream B] rank shots: bounce range / damage, bounces done, terrain stop, last-impact hook
	p.BounceRange = nil
	p.BounceDamage = nil
	p.Bounced = nil
	p.Terrain = nil
	p.LastGround = nil
	p.Final = nil
	p.Impacted = nil
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

-- The hero's trait value with its Signature upgrade (Hero Mastery; rp.Meta.Signature =
-- the level bought for this hero), or `fallback` when the hero has no signature entry.
local function traitValue(rp, fallback: number): number
	return MetaUpgradeData.TraitValue(rp.CharacterId, rp.Meta and rp.Meta.Signature or 0) or fallback
end
WeaponSystem._TraitValue = traitValue -- (tests)

-- Effective stats of one weapon for one player (WeaponData row × stat sheet).
local function weaponStats(rp, w)
	local row = WeaponData.GetStats(w.Id, w.Level, w.Evolved)
	local def = WeaponData.Weapons[w.Id]
	local s = rp.Stats
	local hero = CharacterData.Characters[rp.CharacterId]
	-- Steady Aim (Ranger): standing still gives +SteadyAimBonus damage to the Longbow and
	-- +SteadyAimOther to every other weapon until you move
	local mult = s.Might * (rp.SteadyAim and (1 + ((w.Id == "Longbow" and rp.SteadyAimBonus or rp.SteadyAimOther) or 0)) or 1)
	-- Rally Song (Bard, HEROES): server-decided team buff (HeroSong; 0 when off)
	if rp.SongBuff and rp.SongBuff > 0 then
		mult *= 1 + rp.SongBuff
	end
	-- Volatile Mix (Alchemist): burning / area weapons hit harder
	if hero and hero.AreaDamage and def and def.Area then
		mult *= 1 + traitValue(rp, hero.AreaDamage)
	end
	local duration = row.duration * s.DurationMult
	-- Tinkerer (Engineer): turrets and totems last longer
	if hero and hero.DeployLife and def and def.Deployable then
		duration *= 1 + traitValue(rp, hero.DeployLife)
	end
	if def and def.Rank and BuildRules.On() then
		-- [stream B] rank system: row.damage = B x coeff x rank multiplier, row.cooldown = the
		-- rank interval; Might = 1 + the clamped damage bonus, CooldownMult = 1 / (1 + attack
		-- speed); never faster than Combat.MinInterval. `mult` turns any other coefficient of this
		-- weapon into damage (B x coeff x mult), `spec` is its rank spec with milestones.
		local rank = BuildRules.ClampRank(w.Evolved and BuildRules.MaxRank() or w.Level)
		return {
			damage = row.damage * mult,
			cooldown = math.max(Combat.MinInterval, row.cooldown * s.CooldownMult),
			amount = WeaponData.CapAmount(w.Id, math.max(1, row.amount + s.Amount)),
			area = s.AreaMult,
			speed = row.speed,
			pierce = row.pierce,
			duration = duration,
			knockback = row.knockback,
			heal = 0,
			rank = rank,
			mult = BuildRules.RankMult(rank) * mult,
			spec = WeaponData.RankSpec(w.Id, rank),
		}
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
	return HeightGrid.Ground(v)
end

local function grid()
	return ctx.EnemySpawner.Grid
end

-- k nearest living enemies to a point (small k: a sort over a grid query; k = 1 walks the
-- grid outward instead, so a long-range single target never sorts the whole swarm).
local function skipDead(e): boolean
	return not e.Alive
end

-- The boss a single-target weapon aims at first (Config.Boss.Targeting.PreferBoss): it
-- can be hit now, and its body edge is inside the weapon's range and within PreferWithin
-- studs of the hero. nil = no preference (aim at the nearest as always).
local function preferredBoss(pos: Vector3, range: number): any?
	local T = Config.Boss.Targeting
	local b = ctx.EnemySpawner.Boss
	if not (T and T.PreferBoss and b and b.Alive) or b.Invulnerable or b.Dying or b.Untargetable then
		return nil
	end
	if not HeightGrid.InBand(b.Pos.Y, curGround, Nav.HitBand) then
		return nil -- on another level (height grid): not a target from here
	end
	local edge = ((b.Pos - pos) * FLAT).Magnitude - b.Radius
	if edge <= math.min(range, T.PreferWithin) then
		return b
	end
	return nil
end

--[[
	Range checks use the target's body edge: a big body (a boss, an elite) whose centre is
	past the range but whose edge is inside still counts (the projectile then reaches it;
	the hit itself is still decided by the projectile touching the body). preferBoss: a
	single-target weapon puts preferredBoss first.
]]
local function nearestEnemies(pos: Vector3, range: number, k: number, preferBoss: boolean?): { any }
	local result = {}
	if BuildRules.On() then
		-- [stream B] rank system: only enemies in sight (terrain blocks), nearest first, ties by
		-- Uid, a bounded number of sight checks
		local exclude = {}
		for _ = 1, k do
			local e = Rk.pick(pos, range, exclude, preferBoss and #result == 0)
			if not e then
				break
			end
			exclude[e.Uid] = true
			table.insert(result, e)
		end
		return result
	end
	local boss = preferBoss and preferredBoss(pos, range) or nil
	if k <= 1 then
		if boss then
			result[1] = boss
			return result
		end
		local e = grid():Nearest(pos.X, pos.Z, range, skipDead)
		if not e then
			-- no centre in range: the nearest body EDGE in range (QueryCircle adds radii)
			local n = grid():QueryCircle(pos.X, pos.Z, range, queryBuf)
			local best = math.huge
			for i = 1, n do
				local c = queryBuf[i]
				if c.Alive then
					local edge = ((c.Pos - pos) * FLAT).Magnitude - c.Radius
					if edge < best then
						e, best = c, edge
					end
				end
			end
		end
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
		if e.Alive and e ~= boss then
			list[#list + 1] = e
		end
	end
	local px, pz = pos.X, pos.Z
	table.sort(list, function(a, b)
		local ax, az = a.Pos.X - px, a.Pos.Z - pz
		local bx, bz = b.Pos.X - px, b.Pos.Z - pz
		return ax * ax + az * az < bx * bx + bz * bz
	end)
	if boss then
		result[1] = boss
	end
	for i = 1, math.min(k - #result, #list) do
		result[#result + 1] = list[i]
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
--   ob = { {userId, id, seq, radius, growth, spin, angle} } an orbiting projectile: the client
--                                           draws it around the owner's live character (radius < 0 = stop)
--   cl = { {id, seq, radius, evo} }         a Plague Censer cloud: the client draws the cloud on that marker
--   vx = { {x, z, radius, life, evo} }      a Vortex opens            vi = { {x, z, radius, evo} } implosion
------------------------------------------------------------------------------------------

local wfx: { [string]: { any } } = {}
local wfxAny = false
local WFX_CAPS = { nv = 12, fp = 48, tp = 16, hk = 16, fk = 16, lb = 16, sh = 16, qk = 40, ob = 96, cl = 16, mt = 12, vn = 16, vt = 12, hn = 12, wb = 8, vx = 8, vi = 8 }

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

-- The weapon whose hit is being resolved now (set by Step around each weapon's fire,
-- projectile, pool and burn), so a kill can be credited to it: WeaponSystem.OnKill
-- listeners (weapon mastery, feature 15). Cosmetic bookkeeping only.
local killSource: any = nil
local killListeners: { (any, any, any) -> () } = {}

--[[
	Every weapon hit goes through here: EnemySpawner.Damage (crits, item procs, kills), then
	the hero's kill trait. noHarvest = a soul from Soul Harvest itself (souls never chain).
]]
local function damageEnemy(rp, e, amount: number, dir: Vector3?, knockback: number, isProc: boolean?, noHarvest: boolean?, critIn: boolean?): boolean
	local pos = e.Pos
	local ranked = BuildRules.On()
	if ranked then
		-- [stream B] armor A / (100 + A) (A clamped 0..100), knockback by kind (bosses none,
		-- elites half) and capped
		amount *= BuildRules.ArmorMult(e.Armor or (e.Def and e.Def.Armor))
		-- [stream C] Heavy Hands (Knuckles, rp.KitKnockMult): more knockback on normal enemies; the
		-- per-kind rule and the per-target cap below still apply
		local km = rp and rp.KitKnockMult
		if km and knockback > 0 and not e.Boss and not e.Elite then
			knockback *= km
		end
		knockback = BuildRules.Knockback(BuildRules.KindOf(e), knockback)
	end
	-- [stream C] Punchline (Rambozo, rp.KitCritHigh = { Share, Bonus }): + crit chance on a direct hit
	-- against an enemy above Share of its max HP (the server roll in ItemSystem.ModifyHit, capped)
	local punch = rp and not isProc and critIn == nil and rp.KitCritHigh
	local critSaved: number? = nil
	if punch and rp.Stats and (e.MaxHP or 0) > 0 and e.HP > e.MaxHP * punch.Share then
		critSaved = rp.Stats.CritChance
		rp.Stats.CritChance = math.min(Combat.CritMax, (critSaved or 0) + punch.Bonus)
	end
	local died = ctx.EnemySpawner.Damage(e, amount, rp, dir, knockback, isProc, critIn)
	if critSaved ~= nil then
		rp.Stats.CritChance = critSaved
	end
	if ranked then
		local k = e.Knock
		if k and k.Magnitude > Combat.KnockbackCap then
			e.Knock = k.Unit * Combat.KnockbackCap -- per-target horizontal knockback cap
		end
		-- Splinter Badge: a direct (non-proc) hit may throw two splinters (secondary, no chain)
		local chance = rp and not isProc and rp.Stats and rp.Stats.SplinterChance or 0
		if chance > 0 and rng:NextNumber() < chance then
			Rk.splinter(rp, e, pos)
		end
	end
	if died and rp and not noHarvest then
		onWeaponKill(rp, pos, e)
	end
	if died and rp and killSource and #killListeners > 0 then
		for _, fn in ipairs(killListeners) do
			fn(rp, killSource, e)
		end
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
	if BuildRules.On() then
		-- [stream B] the strongest slow only, at most 40 % (bosses 10 %, not immune)
		mult = BuildRules.SlowMult(1 - mult, e.Boss == true)
	elseif e.Boss then
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

-- SwarmV2 class signature weapons (Scrap Toss, Toast Volley, Bubble Bomb, Yarn Bomb): helpers,
-- hit hooks and the extra projectile kinds live in `Class` (defined near Arm, below); declared
-- here because collideEnemies and ricochet call into it.
local Class = { Hit = {}, Final = {}, Expire = {} } -- [stream C] Expire: kind -> fn(p) when its Life ends

-- Visual tier sent with projectiles and slashes (0 = levels 1-3, 1 = 4-6, 2 = 7-8, 3 = evolved).
-- Purely cosmetic: the client draws stronger trails/glows for higher tiers.
local function visualTier(w): number
	if w.Evolved then
		return 3
	elseif WeaponData.IsRanked(w.Id) then
		return w.Level >= 5 and 2 or (w.Level >= 3 and 1 or 0) -- [stream B] ranks: 1-2 / 3-4 / 5
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
local SWING_AIM_CANDIDATES = 24 -- in-reach enemies tried as the aim direction

-- True when enemy e (its body circle) is inside a swing from origin toward dir.
local function inSwing(e, origin: Vector3, dir: Vector3, reach: number, half: number, full: boolean?): boolean
	local rel = (e.Pos - origin) * FLAT
	local d = rel.Magnitude
	if d > reach + e.Radius then
		return false
	end
	if d <= SWING_INNER + e.Radius or full then
		return true
	end
	local off = math.acos(math.clamp(rel:Dot(dir) / d, -1, 1)) - half
	-- inside the sector, or overlapping one of its edges
	return off <= 0 or (off < math.pi / 2 and d * math.sin(off) <= e.Radius)
end

-- An enemy a weapon hit can actually hurt (a boss's collapse / a tunnelling Burrower can't).
local function hittable(e): boolean
	return e.Alive and not e.Invulnerable and not e.Dying and not e.Untargetable
end
-- A chased target is still worth chasing: alive, the same spawn, and still in the grid (a
-- burrowed or rising boss leaves it: homing shots retarget or fly straight on, hooks and
-- darts turn back, clouds stop following).
local function chaseable(t, uid: number?): boolean
	return t ~= nil and t.Alive and t.Uid == uid and not t.Untargetable
end

local function skipUnhittable(e): boolean
	return not hittable(e)
end
local function skipUnhittableOrStatic(e): boolean
	return not hittable(e) or e.Def.Static == true
end

--[[
	Auto aim for a swing (owner): the direction whose cut hits the most enemies that are in
	reach NOW, measured by their body edge (a boss or a Nest whose centre is past the reach
	still counts; the old aim at the nearest CENTRE turned the cut toward a small enemy just
	out of reach and hit nothing). Each in-reach enemy's direction is a candidate; ties go
	to the closer edge. `both`: the backhand cut (opposite) also lands. Nothing in reach:
	the nearest hittable moving enemy within `look` studs, so the swing visibly turns toward
	incoming enemies; nil = keep the facing.
]]
local function swingAim(origin: Vector3, reach: number, half: number, both: boolean, look: number): Vector3?
	local n = grid():QueryCircle(origin.X, origin.Z, reach, queryBuf)
	local cands = {}
	for i = 1, n do
		local e = queryBuf[i]
		if hittable(e) then
			cands[#cands + 1] = e
		end
	end
	if #cands > 0 then
		local function edge(e)
			return ((e.Pos - origin) * FLAT).Magnitude - e.Radius
		end
		table.sort(cands, function(a, b)
			return edge(a) < edge(b)
		end)
		local bestDir, bestScore = nil, -1
		for i = 1, math.min(#cands, SWING_AIM_CANDIDATES) do
			local dir = flatDir(cands[i].Pos - origin, Vector3.zero)
			if dir.Magnitude > 0 then
				local score = 0
				for _, e in ipairs(cands) do
					if inSwing(e, origin, dir, reach, half) or (both and inSwing(e, origin, -dir, reach, half)) then
						score += 1
					end
				end
				if score > bestScore then
					bestDir, bestScore = dir, score
				end
			end
		end
		if bestDir then
			return bestDir
		end
	end
	local target = grid():Nearest(origin.X, origin.Z, look, skipUnhittableOrStatic)
		or grid():Nearest(origin.X, origin.Z, look, skipUnhittable)
	if target then
		local dir = flatDir(target.Pos - origin, Vector3.zero)
		return dir.Magnitude > 0 and dir or nil
	end
	return nil
end
WeaponSystem._SwingAim = swingAim -- (tests)

function Fire.Whip(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local reach = params.Reach * s.area
	local half = math.rad(params.Arc) / 2
	-- auto aim (owner): the forehand cut faces the enemies it can hit (swingAim), else
	-- turns toward the nearest one within max(3 x reach, 30) studs, else the facing
	local facing = rp.Facing
	if rp.Root then
		local origin = ground(rp.Root.Position)
		facing = swingAim(origin, reach, half, s.amount >= 2, math.max(reach * 3, 30)) or rp.Facing
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
				killSource = w -- a delayed hit: credit the sword (OnKill)
				local origin = ground(rp.Root.Position)
				local healed = 0
				useGround(origin.Y)
				local n = grid():QueryCircle(origin.X, origin.Z, reach, queryBuf)
				local hits = table.move(queryBuf, 1, n, 1, {})
				for _, e in ipairs(hits) do
					if e.Alive then
						if inSwing(e, origin, dir, reach, half, full) then
							hitEnemy(rp, e, s.damage, origin, s.knockback)
							if evo and healed < evo.LifestealCapPerSwing then
								healed += evo.Lifesteal
							end
						end
					end
				end
				useGround(nil)
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
	local targets = nearestEnemies(origin, 60, s.amount, true)
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
		p.Y = p.Ground + 3
		p.VY = 30 -- the arc is purely visual
		-- gravity chosen so the bottle comes back down to ~0.5 studs above the landing
		-- ground exactly at landing (2.5 below the throw height on a flat floor)
		p.Floor = HeightGrid.GroundY(dest.X, dest.Z)
		p.Gravity = 2 * (p.VY * flight + math.max(-p.VY * flight * 0.5, p.Y - (p.Floor + 0.5))) / (flight * flight)
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
			-- drawn around the hero's live position on clients (VFX K.setOrbit)
			pushFx("ob", { rp.Player.UserId, p.Id, p.Seq, r1(p.OrbitRadius), r1(p.OrbitGrowth), p.OrbitSpin, math.floor((p.Angle % TAU) * 1000 + 0.5) / 1000 })
		else
			p.Kind = "Arc"
			p.Visual = visualByte(params.Visual, w)
			local spread = (i - (s.amount + 1) / 2) * math.rad(22) + rng:NextNumber(-0.15, 0.15)
			local dir = rotateY(rp.Facing, spread)
			p.Pos = origin
			p.Vel = dir * s.speed
			p.Y = p.Ground + 3
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
	local target = nearestEnemies(origin, s.speed * s.duration, 1, true)[1]
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
	local targets = nearestEnemies(origin, s.speed * s.duration, s.amount, true)
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
				useGround(z.Pos.Y)
				local n = grid():QueryCircle(z.Pos.X, z.Pos.Z, z.Radius, queryBuf)
				local hits = table.move(queryBuf, 1, n, 1, {})
				for _, e in ipairs(hits) do
					if e.Alive and burnReady(z.Weapon, e, z.Tick, now) then
						killSource = z.Weapon
						damageEnemy(owner, e, z.Damage, nil, 0, z.NoProc)
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
			if b.Ticks then
				-- [stream B] scorch: exact ticks on the run clock (3 s / 0.5 s = 6), then it ends
				b.Next += b.Tick
				b.Ticks -= 1
				if b.Ticks <= 0 then
					b.Until = now
				end
			else
				b.Next = now + b.Tick
			end
			if burnReady(b.Weapon, e, b.Tick, now) then
				killSource = b.Weapon
				damageEnemy(b.Owner, e, b.Damage, nil, 0, b.NoProc)
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
	p.Ground = p.Pos.Y
	p.Y = p.Ground
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
			-- overlapping totems of one weapon hurt an enemy once per pulse (no stacking)
			if p.Weapon and burnReady(p.Weapon, e, p.Pulse, now) then
				hitEnemy(p.Owner, e, p.Damage, p.Pos, p.Knockback)
			end
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
	p.Ground = p.Pos.Y
	p.Y = p.Ground
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
	b.Ground = p.Ground
	b.Y = b.Ground + 2.9
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
	p.Ground = HeightGrid.GroundY(from.X, from.Z)
	p.Y = p.Ground + Config.Projectiles.Height + 0.6
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
	local targets = nearestEnemies(origin, params.Range, s.amount, true)
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
	if now < (rp.SoulAt or 0) or rng:NextNumber() >= traitValue(rp, trait.Chance) or #freeIds < EXTRA_MIN_FREE then
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
	p.Ground = p.Pos.Y
	p.Y = p.Ground + Config.Projectiles.Height
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
	-- [stream B] rank shots: a different, not-yet-hit, VISIBLE target within BounceRange (bounded
	-- sight checks), paid from the owner's secondary budget, dealing BounceDamage
	local range = p.BounceRange or RICOCHET_RANGE
	local from, checks = p.Pos, 0
	local nextE = grid():Nearest(p.Pos.X, p.Pos.Z, range, function(x)
		if p.Hits[x.Uid] ~= nil or not x.Alive then
			return true
		end
		if p.BounceRange then
			checks += 1
			return checks > Combat.LOSMaxChecks or not WeaponSystem.HasLineOfSight(from, x.Pos)
		end
		return false
	end)
	if not nextE then
		return false
	end
	if p.BounceRange and not Rk.tryEmit(p.Owner) then
		return false
	end
	p.Bounced = (p.Bounced or 0) + 1
	local speed = math.max(20, p.Vel.Magnitude)
	if p.BounceGain then
		p.Damage *= 1 + p.BounceGain -- Sling: a stone hits harder with every bounce
	end
	if p.BounceDamage then
		p.Damage = p.BounceDamage
	end
	local d = flatDir(nextE.Pos - p.Pos, p.Vel.Unit)
	p.Vel = d * speed
	p.Yaw = yawOf(d)
	if p.NoProcOnBounce then
		p.NoProc = true -- a bounced hit is a derived hit: no crit, no item procs
	end
	p.Pierce = 1
	p.Age = math.min(p.Age, p.Life - range / speed - 0.05)
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
					died = damageEnemy(p.Owner, e, amount, dir, p.Knockback, p.NoProc == true, p.NoHarvest)
				else
					local d = (e.Pos - p.Pos) * FLAT
					died = damageEnemy(p.Owner, e, amount, d.Magnitude > 1e-3 and d.Unit or Vector3.zAxis, p.Knockback, p.NoProc == true, p.NoHarvest)
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
				if p.Hook then
					local hook = Class.Hit[p.Hook]
					if hook then
						hook(p, e, now, died, at)
					end
				end
				if died and p.Wander then
					-- Wandering Souls (Soul Bolt perk): a soul that kills flies on once
					p.Wander = nil
					p.Pierce += 1
				end
				if p.Pierce < 999 then
					p.Pierce -= 1
					if p.Pierce <= 0 then
						local bounced = ricochet(p)
						if not bounced and p.Final then
							-- [stream B] the projectile's last impact (final burst / evolution pulse)
							local fin = Class.Final[p.Final]
							if fin then
								fin(p, e, at)
							end
						end
						return not bounced
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
			local rpos = rp.Root.Position
			local d = (rpos - p.Pos) * FLAT
			if d.Magnitude <= p.Radius + PLAYER_RADIUS and HeightGrid.InBand(HeightGrid.GroundY(rpos.X, rpos.Z), p.Ground, Nav.HitBand) then
				ctx.RunManager.DamagePlayer(rp, p.Damage, p.Cause)
				return true
			end
		end
	end
	return false
end

local function outOfArena(pos: Vector3): boolean
	local minX, minZ, maxX, maxZ = HeightGrid.Bounds()
	return pos.X < minX - 20 or pos.X > maxX + 20 or pos.Z < minZ - 20 or pos.Z > maxZ + 20
end

------------------------------------------------------------------------------------------
-- Armoury batch: Ward Shields, Earthsplitter, Starfall, Sling, Plague Censer, Sawblade,
-- Vine Snare, War Horn, Spirit Wisps, Vortex. Helpers live in `Arm` (one local: this
-- module is close to Luau's 200-locals limit). Per-kind data sits in p.X (cleared on alloc).
------------------------------------------------------------------------------------------

local Arm = {}

-- Tell clients to draw projectile `p` orbiting its owner (VFX K.setOrbit): angle now (rad),
-- spin (rad/s), radius and radius growth per second. radius < 0 = stop (back to synced).
function Arm.orbitFx(p: Projectile, radius: number, growth: number, spin: number, angle: number)
	local owner = p.Owner
	if not owner or not owner.Player then
		return
	end
	local function q(n: number): number
		return math.floor(n * 1000 + 0.5) / 1000
	end
	pushFx("ob", { owner.Player.UserId, p.Id, p.Seq, q(radius), q(growth), q(spin), q(angle % TAU) })
end

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
		Arm.orbitFx(p, orbit, 0, p.X.Spin, p.Angle)
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
		p.Y = p.Ground + 0.6
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
		p.Ground = at.Y -- it lands (and hits) on the target's ground
		p.Y = p.Ground + 36
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
	p.Y = p.Ground + 0.8 + 35 * (1 - u * u)
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
		table.insert(zones, { Pos = at, Radius = x.CraterR, Life = x.Crater, Tick = x.CraterTick, Timer = x.CraterTick, Damage = x.CraterDamage, Owner = owner, Weapon = p.Weapon })
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
	local targets = nearestEnemies(origin, s.speed * s.duration * 1.2, s.amount, true)
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
		p.Ground = p.Pos.Y
		p.Y = p.Ground + 1.2
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
		pushFx("cl", { p.Id, p.Seq, r1(p.X.R), evo and 1 or 0 })
	end
end

function Arm.stepCloud(p: Projectile, dt: number, now: number): boolean
	local owner = p.Owner
	if not owner.Alive then
		return true
	end
	local x = p.X
	local t = p.Target
	if not chaseable(t, p.TargetUid) then
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
			-- overlapping clouds of one censer hurt an enemy once per tick (they used to
			-- stack: 3-4 clouds on the same clump multiplied the damage)
			if e.Alive and burnReady(p.Weapon, e, x.Tick, now) then
				if x.Choke then
					slowEnemy(e, x.Choke, x.Tick + 0.15, now)
				end
				damageEnemy(owner, e, p.Damage, nil, 0)
				-- (poison starts 1.5 ticks later, so it only hurts after leaving the cloud
				-- and never takes the cloud's own tick)
				if x.Poison and e.Alive then
					burns[e] = { Uid = e.Uid, Until = now + x.PoisonSeconds, Next = now + x.Tick * 1.5, Tick = x.Tick, Damage = p.Damage * x.PoisonShare, Owner = owner, Weapon = p.Weapon }
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
		p.Y = p.Ground + 1.4
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
		p.Ground = HeightGrid.GroundY(at.X, at.Z)
		p.Y = p.Ground
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
			-- overlapping snares of one weapon hurt an enemy once per tick (no stacking)
			if burnReady(p.Weapon, e, x.Tick, now) and damageEnemy(owner, e, p.Damage, d > 1e-3 and rel / d or nil, kb) and x.Thorn and thorns < x.ThornsPerTick then
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
	-- the cone faces the enemies it can hit now (by body edge, like the Whip), else the
	-- nearest hittable one within 1.6 x range, else the facing
	local aim = swingAim(origin, range, math.rad(params.HalfAngle), s.amount == 2, range * 1.6) or rp.Facing
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
			killSource = w -- a delayed blast: credit the horn (OnKill)
			local at = ground(rp.Root.Position)
			local prev = curGround
			useGround(at.Y)
			Arm.hornBlast(rp, at, sh.Dir, sh.Range, sh.Half, s.damage * sh.Share, s.knockback * sh.Share, s.duration, params.DazeSlow, evo ~= nil)
			if sh.Delay <= 0 then
				useGround(prev) -- fired inside the weapon step: back to the hero's ground
			else
				useGround(nil)
			end
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
		if p.Phase == "Orbit" then
			-- slots may have moved (a new wisp): re-send the client-drawn orbit
			Arm.orbitFx(p, x.OrbitR, 0, x.Spin, ctx.RunManager.GetRunTime() * x.Spin + x.Slot)
		end
	end
	if #resting == 0 then
		return
	end
	local origin = ground(rp.Root.Position)
	local targets = nearestEnemies(origin, params.Range * s.area, #resting, true)
	if #targets == 0 then
		w.Timer = math.min(w.Timer, 0.3)
		return
	end
	for i, p in ipairs(resting) do
		local t = targets[((i - 1) % #targets) + 1]
		if p.Phase == "Orbit" then
			Arm.orbitFx(p, -1, 0, 0, 0) -- darting: the client draws the synced flight again
		end
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
		if not chaseable(e, p.TargetUid) then
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
			Arm.orbitFx(p, x.OrbitR, 0, x.Spin, t)
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
	if HeightGrid.IsActive() then
		p.Ground = HeightGrid.GroundY(p.Pos.X, p.Pos.Z) -- a cloud drifts with its target
	end
	p.Y = p.Ground + Config.Projectiles.Height + 0.4 + math.sin(now * 3 + p.Id) * 0.3
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
		p.Ground = HeightGrid.GroundY(at.X, at.Z)
		p.Y = p.Ground + 0.15
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
	if x.Rank then
		return Rk.stepVortex(p, dt, now) -- [stream B] rank system rift
	end
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
		-- overlapping rifts of one weapon hurt an enemy once per tick (no stacking)
		if e.Alive and burnReady(p.Weapon, e, x.Tick, now) then
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

------------------------------------------------------------------------------------------
-- SwarmV2 class signature weapons: SCRAP TOSS (Ruckus), TOAST VOLLEY (Toastmaster), BUBBLE
-- BOMB (Captain Croak), YARN BOMB (Granny Boom). Server-simulated pooled projectiles like
-- every other weapon; the kit passives (Junk Collector, Overheat, Big Splash, Tangled Up ...) are in
-- ClassKits (reached through ctx.ClassKits). Every derived hit (bounce, ricochet, burst, can,
-- burn, scorch, landing blast, tangle) is dealt with isProc = true ("NoProc"): no crit, no
-- item procs, so nothing can trigger itself. WeaponData ClassOnly keeps them to their class.
------------------------------------------------------------------------------------------

-- A straight shot that bounces (ricochet) `bounces` more times; bounced hits are NoProc.
function Class.Shot(rp, w, pos: Vector3, dir: Vector3, visual: number, speed: number, damage: number, radius: number, life: number, knockback: number, bounces: number): Projectile?
	local p = allocProjectile()
	if not p then
		return nil
	end
	p.Kind = "Straight"
	p.Visual = visual
	p.Owner = rp
	p.Weapon = w
	p.Pos = pos
	p.Vel = dir * speed
	p.Damage = damage
	p.Pierce = 1
	p.Bounces = bounces
	p.NoProcOnBounce = true
	p.Radius = radius
	p.Life = life
	p.Knockback = knockback
	p.Yaw = yawOf(dir)
	return p
end

-- The direction of shot i of n at the nearest enemies `targets`; extra shots fan out.
function Class.Aim(rp, origin: Vector3, targets: { any }, i: number, n: number, spreadDeg: number): Vector3
	local target = targets[((i - 1) % math.max(1, #targets)) + 1]
	if target then
		local dir = flatDir(target.Pos - origin, rp.Facing)
		if i > #targets then
			dir = rotateY(dir, (i % 2 == 0 and 1 or -1) * math.rad(spreadDeg))
		end
		return dir
	end
	return rotateY(rp.Facing, (i - (n + 1) / 2) * math.rad(spreadDeg))
end

-- SCRAP TOSS / JUNKYARD BARRAGE: scrap at the nearest enemies, bouncing on (row pierce =
-- bounces + 1). Junk Collector: a stored barrage adds a ring of scraps to this volley (old system).
function Fire.ScrapToss(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local visual = visualByte(evo and params.EvoVisual or params.Visual, w)
	local radius = params.Radius * s.area
	local gain = evo and params.EvoBounceGain or params.BounceGain
	local targets = nearestEnemies(origin, s.speed * s.duration * 1.2, s.amount, true)
	for i = 1, s.amount do
		local dir = Class.Aim(rp, origin, targets, i, s.amount, 8)
		local p = Class.Shot(rp, w, origin + dir * 1.5, dir, visual, s.speed, s.damage, radius, s.duration, s.knockback, math.max(0, s.pierce - 1))
		if not p then
			return
		end
		p.BounceGain = gain
	end
	local kits = ctx.ClassKits
	local K = kits and kits.TakeBarrage(rp) -- (old 12-level system: the barrage is a ring of Shots scraps)
	if K then
		for i = 1, K.Shots do
			local dir = rotateY(rp.Facing, (i - 1) * TAU / K.Shots)
			local p = Class.Shot(rp, w, origin + dir * 1.5, dir, visual, s.speed, s.damage, radius, s.duration, s.knockback, 0)
			if not p then
				break
			end
		end
		Fx.Ring(origin, 5, Color3.fromRGB(240, 200, 90))
	end
	Fx.Sound("Hit")
end

-- TOAST VOLLEY / DOUBLE DECKER: slices at the nearest enemies that ricochet on. Every hit
-- feeds Overheat (ClassKits).
function Fire.ToastVolley(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local visual = visualByte(evo and params.EvoVisual or params.Visual, w)
	local radius = params.Radius * s.area
	local targets = nearestEnemies(origin, s.speed * s.duration * 1.2, s.amount, true)
	for i = 1, s.amount do
		local dir = Class.Aim(rp, origin, targets, i, s.amount, params.Spread)
		local p = Class.Shot(rp, w, origin + dir * 1.5, dir, visual, s.speed, s.damage, radius, s.duration, s.knockback, math.max(0, s.pierce - 1))
		if not p then
			return
		end
		p.Hook = "Toast"
	end
	Fx.Sound("Hit")
end

function Class.Hit.Toast(p: Projectile, e, now: number, died: boolean, _at: Vector3)
	local kits = ctx.ClassKits
	if kits and not died then
		-- [stream C] Overheat counts direct toast hits only (not ricochets or follow-ups)
		local direct = (p.Bounced or 0) == 0 and not p.NoProc
		kits.OnToastHit(p.Owner, e, p.Damage, p.Weapon, now, direct)
	end
end

-- BUBBLE BOMB / TIDAL BURST: a bubble that bursts around every enemy it hits (BurstShare of
-- the hit to the others within BurstRadius x area) and bounces once. Big Splash (ClassKits)
-- makes the first bubble of the next volley hit harder and burst wider.
function Fire.BubbleBomb(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local baseVisual = evo and params.EvoVisual or params.Visual
	local radius = params.Radius * s.area
	local share = evo and params.EvoBurstShare or params.BurstShare
	local burst = params.BurstRadius * s.area
	local targets = nearestEnemies(origin, s.speed * s.duration * 1.2, s.amount, true)
	local kits = ctx.ClassKits
	local splash = kits ~= nil and kits.TakeSplash(rp) or nil
	for i = 1, s.amount do
		local dir = Class.Aim(rp, origin, targets, i, s.amount, 9)
		local big = splash ~= nil and i == 1
		local damage = s.damage * (big and splash.DamageMult or 1)
		local visual = WeaponData.VisualByte(baseVisual, big and 3 or visualTier(w))
		local p = Class.Shot(rp, w, origin + dir * 1.5, dir, visual, s.speed, damage, radius * (big and 1.2 or 1), s.duration, s.knockback, math.max(0, s.pierce - 1))
		if not p then
			return
		end
		p.Hook = "Bubble"
		p.X = { R = burst * (big and splash.RadiusMult or 1), Share = share }
	end
	Fx.Sound("Hit")
end

function Class.Hit.Bubble(p: Projectile, e, _now: number, _died: boolean, at: Vector3)
	local x = p.X
	if not x or not p.Owner.Alive then
		return
	end
	burstAround(p.Owner, at, x.R, p.Damage * x.Share, e)
	pushFx("fk", { r1(at.X), r1(at.Z), r1(x.R) })
end

-- YARN BOMB / GRAND KNITWORK: a yarn ball lobbed at the thickest crowd; it explodes on
-- landing (the Starfall warning ring shows where). Tangled Up (ClassKits) tangles what it hits.
function Fire.YarnBomb(rp, w, s, def)
	local params = def.Params
	local evo = w.Evolved and def.Evolution or nil
	local origin = ground(rp.Root.Position)
	local radius = params.BlastRadius * s.area
	local taken = {}
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
		local dist = ((at - origin) * FLAT).Magnitude
		local flight = math.clamp(dist / math.max(1, s.speed), params.MinFlight, params.MaxFlight) + (i - 1) * 0.1
		p.Kind = "Yarn"
		p.Visual = visualByte(evo and params.EvoVisual or params.Visual, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin
		p.Vel = Vector3.zero
		p.Life = flight
		p.Damage = s.damage
		p.Pierce = 999
		p.Radius = 0
		p.Knockback = s.knockback
		p.Yaw = yawOf(flatDir(at - origin, rp.Facing))
		p.X = { From = origin, To = at, R = radius }
		pushFx("mt", { r1(at.X), r1(at.Z), r1(radius), r1(flight), evo and 1 or 0 })
	end
	Fx.Sound("Hit")
end

function Class.stepYarn(p: Projectile, dt: number, _now: number): boolean
	local x = p.X
	local u = math.clamp(p.Age / p.Life, 0, 1)
	p.Pos = x.From:Lerp(x.To, u)
	-- (rank system: the arc runs between the two ground heights)
	local base = x.Rank and (x.From.Y + (x.To.Y - x.From.Y) * u) or Config.ArenaOrigin.Y
	p.Y = base + 1.2 + 9 * math.sin(math.pi * u)
	p.Yaw += dt * 9
	return false
end

function Class.landYarn(p: Projectile)
	local x = p.X
	local owner = p.Owner
	if not owner.Alive then
		return
	end
	if x.Rank then
		Rk.landYarn(p, x) -- [stream B] rank system blast
		return
	end
	local at = x.To
	local now = ctx.RunManager.GetRunTime()
	local n = grid():QueryCircle(at.X, at.Z, x.R, queryBuf)
	local hits = table.move(queryBuf, 1, n, 1, {})
	local kits = ctx.ClassKits
	for _, e in ipairs(hits) do
		if e.Alive then
			local died = hitEnemy(owner, e, p.Damage, at, p.Knockback)
			if not died and e.Alive and kits then
				kits.OnYarnHit(owner, e, now)
			end
		end
	end
	Fx.Explosion(at, x.R)
	Fx.Sound("Hit")
end

-- A rolling can (Ruckus dash): rolls on its dash momentum, then explodes after its fuse.
function Class.stepCan(p: Projectile, dt: number, _now: number): boolean
	local before = p.Pos
	p.Pos += p.Vel * dt
	if p.X and p.X.Coeff and Rk.terrainBlocked(p) then
		p.Pos = before -- [stream C] a cliff stops the can (it never rolls through terrain)
		p.Vel = Vector3.zero
	end
	p.Vel *= math.max(0, 1 - 2.4 * dt)
	p.Yaw += dt * 10
	return false
end

function Class.popCan(p: Projectile)
	local x = p.X
	if not p.Owner.Alive then
		return
	end
	if x.Coeff then
		-- [stream C] rank system: Coeff x B at the signature's rank, one can hit per target per dash
		-- (the dash's cast ledger), terrain blocks the blast
		WeaponSystem.KitBurst(p.Owner, p.Pos, x.R, x.Coeff, x.WeaponId, { CastId = x.CastId, Dash = true, Fx = false })
	else
		burstAround(p.Owner, p.Pos, x.R, p.Damage)
	end
	Fx.Explosion(p.Pos, x.R)
end

------------------------------------------------------------------------------------------
-- API for ClassKits (server/Run/ClassKits.lua). All damage here is NoProc.
------------------------------------------------------------------------------------------

-- Damage to everything within `radius` of `at` (a landing blast). Never procs.
function WeaponSystem.ClassBurst(rp, at: Vector3, radius: number, damage: number, weapon: any?)
	local prev = killSource
	killSource = weapon or killSource
	burstAround(rp, at, radius, damage)
	killSource = prev
	Fx.Explosion(at, radius)
end

-- Sets enemy `e` burning for `seconds` (refresh only: an enemy that already burns just gets
-- its timer pushed out, never a second burn). tickDamage every `tick` s, NoProc.
function WeaponSystem.Ignite(rp, e, seconds: number, tickDamage: number, tick: number, weapon: any): boolean
	if not e.Alive then
		return false
	end
	local now = ctx.RunManager.GetRunTime()
	local b = burns[e]
	if b and b.Uid == e.Uid and now < b.Until then
		b.Until = math.max(b.Until, now + seconds)
		return false
	end
	burns[e] = { Uid = e.Uid, Until = now + seconds, Next = now + tick, Tick = tick, Damage = tickDamage, Owner = rp, Weapon = weapon, NoProc = true }
	return true
end

-- Drops a rolling can at `pos` rolling along `dir`; it explodes after `fuse` s for `damage`
-- within `radius`. At most `maxLive` of the hero's cans exist at once.
function WeaponSystem.DropCan(rp, pos: Vector3, dir: Vector3, damage: number, radius: number, fuse: number, speed: number, maxLive: number): boolean
	local w = rp.Weapons.ScrapToss
	if not w then
		return false
	end
	local mine = 0
	for _, o in ipairs(live) do
		if o.Kind == "Can" and o.Owner == rp then
			mine += 1
		end
	end
	if mine >= maxLive then
		return false
	end
	local p = allocProjectile()
	if not p then
		return false
	end
	p.Kind = "Can"
	p.Visual = visualByte(61, w)
	p.Owner = rp
	p.Weapon = w
	p.Pos = ground(pos)
	p.Y = Config.ArenaOrigin.Y + 0.7
	p.Vel = flatDir(dir, rp.Facing) * speed
	p.Life = fuse
	p.Damage = damage
	p.Pierce = 999
	p.Radius = 0
	p.Knockback = 0
	p.Yaw = yawOf(flatDir(dir, rp.Facing))
	p.X = { R = radius }
	return true
end

-- A fire patch that burns enemies in it (Granny's boost scorch); harmless to heroes. NoProc.
function WeaponSystem.Scorch(rp, pos: Vector3, radius: number, damage: number, life: number, tick: number, maxPatches: number)
	local mine, oldest = 0, nil
	for i, z in ipairs(patches) do
		if z.Owner == rp and z.NoProc then
			mine += 1
			oldest = oldest or i
		end
	end
	if mine >= maxPatches and oldest then
		table.remove(patches, oldest)
	end
	rp.ClassFxWeapon = rp.ClassFxWeapon or {}
	local at = ground(pos)
	table.insert(patches, {
		Pos = at,
		Radius = radius,
		Life = life,
		Tick = tick,
		Timer = 0.1,
		Damage = damage,
		Owner = rp,
		Weapon = rp.ClassFxWeapon,
		NoProc = true,
	})
	pushFx("fp", { r1(at.X), r1(at.Z), r1(radius), r1(life), 0 })
end

-- The effective stats row of one of the hero's weapons (nil when not owned), and the weapon.
function WeaponSystem.ClassWeaponStats(rp, weaponId: string)
	local w = rp.Weapons[weaponId]
	if not w then
		return nil, nil
	end
	return weaponStats(rp, w), w
end

------------------------------------------------------------------------------------------
-- [stream B] RANK SYSTEM COMBAT CORE (RunConfig.Builds.Enabled): line of sight, targeting,
-- the shared damage rules, statuses, the secondary budget and the catalog behaviours.
------------------------------------------------------------------------------------------

function Rk.now(): number
	return ctx.RunManager.GetRunTime()
end

--[[
	Line of sight over the terrain (HeightGrid): the ground between the two points must stay below
	a sight line Combat.LOSHeight above the ground at both ends (+ LOSTolerance), sampled every
	LOSStep studs. Cliffs, ridges and NavBlock walls (their top is the cell height) block it; water
	and gaps do not. No grid (a flat arena): always clear.
]]
function WeaponSystem.HasLineOfSight(fromPos: Vector3, toPos: Vector3): boolean
	if not HeightGrid.IsActive() then
		return true
	end
	local ax, az, bx, bz = fromPos.X, fromPos.Z, toPos.X, toPos.Z
	local dx, dz = bx - ax, bz - az
	local n = math.floor(math.sqrt(dx * dx + dz * dz) / Combat.LOSStep)
	if n < 2 then
		return true
	end
	local h, tol = Combat.LOSHeight, Combat.LOSTolerance
	local ay = HeightGrid.GroundY(ax, az) + h
	local by = HeightGrid.GroundY(bx, bz) + h
	for i = 1, n - 1 do
		local t = i / n
		if HeightGrid.GroundY(ax + dx * t, az + dz * t) > ay + (by - ay) * t + tol then
			return false
		end
	end
	return true
end

-- A rank shot over terrain: a cliff rise ends it (true); ramps carry it up.
function Rk.terrainBlocked(p: Projectile): boolean
	if not HeightGrid.IsActive() then
		return false
	end
	local gy = HeightGrid.GroundY(p.Pos.X, p.Pos.Z)
	local last = p.LastGround or p.Ground
	if gy - last > Nav.StepMax and gy > p.Y - 0.5 then
		return true
	end
	p.LastGround = gy
	if gy + 1.2 > p.Y then
		p.Y = gy + 1.2
	end
	return false
end

--[[
	The nearest hittable enemy whose body edge is within `range` of `origin`, ties by the stable
	enemy Uid, that is in sight (at most Combat.LOSMaxChecks sight checks: the search is bounded by
	the range query and never global). exclude = { [uid] = true }. preferBoss: the existing boss
	preference (Config.Boss.Targeting) when that boss is in sight.
]]
function Rk.pick(origin: Vector3, range: number, exclude: { [number]: boolean }?, preferBoss: boolean?): any?
	if preferBoss then
		local b = preferredBoss(origin, range)
		if b and not (exclude and exclude[b.Uid]) and WeaponSystem.HasLineOfSight(origin, b.Pos) then
			return b
		end
	end
	local n = grid():QueryCircle(origin.X, origin.Z, range, queryBuf)
	if n == 0 then
		return nil
	end
	local cands, dists = {}, {}
	for i = 1, n do
		local e = queryBuf[i]
		if hittable(e) and not (exclude and exclude[e.Uid]) then
			local edge = ((e.Pos - origin) * FLAT).Magnitude - e.Radius
			if edge <= range then
				table.insert(cands, e)
				table.insert(dists, edge)
			end
		end
	end
	for _ = 1, Combat.LOSMaxChecks do
		local bi, best, bestUid = 0, math.huge, math.huge
		for i, e in ipairs(cands) do
			local d = dists[i]
			if d < best or (d == best and d < math.huge and e.Uid < bestUid) then
				bi, best, bestUid = i, d, e.Uid
			end
		end
		if bi == 0 then
			return nil
		end
		local e = cands[bi]
		if WeaponSystem.HasLineOfSight(origin, e.Pos) then
			return e
		end
		dists[bi] = math.huge
	end
	return nil
end

--[[
	WeaponSystem.NearestTarget(rp, range, opts) -> enemy or nil: the brief's automatic targeting.
	opts = { Key = weapon id (the per-weapon target memory), From = origin (default: the hero's
	ground), Exclude = { [uid] = true }, PreferBoss = false to skip the boss preference }.
	With a Key, a still-valid target (alive, in range, on this level, in sight) is kept for
	Combat.TargetHold s after it was picked and is only reconsidered every Combat.Retarget s.
]]
function WeaponSystem.NearestTarget(rp, range: number, opts: any?): any?
	local o = opts or {}
	local origin: Vector3? = o.From
	if not origin then
		if not rp or not rp.Root then
			return nil
		end
		origin = ground(rp.Root.Position)
	end
	local from = origin :: Vector3
	local now = Rk.now()
	local cache = nil
	if o.Key and rp then
		rp.TargetCache = rp.TargetCache or {}
		cache = rp.TargetCache[o.Key]
		if cache and (cache.Checked or 0) > now + 1 then
			cache = nil -- a new run (the clock went back)
		end
	end
	local g = grid()
	local saved, savedBand, savedGround = g.BandY, g.Band, curGround
	useGround(from.Y)
	local result = nil
	if cache then
		local t = cache.Target
		local keep = t ~= nil and hittable(t) and t.Uid == cache.Uid
			and ((t.Pos - from) * FLAT).Magnitude - t.Radius <= range
			and HeightGrid.InBand(t.Pos.Y, from.Y, Nav.HitBand)
			and not (o.Exclude and o.Exclude[t.Uid])
		if keep and now - cache.At >= Combat.TargetHold and now - cache.Checked >= Combat.Retarget then
			keep = false -- time to reconsider: the nearest visible one wins (maybe the same)
		end
		if keep and now - cache.Checked >= Combat.Retarget then
			keep = WeaponSystem.HasLineOfSight(from, t.Pos)
		end
		if keep then
			result = t
		end
	end
	if not result then
		result = Rk.pick(from, range, o.Exclude, o.PreferBoss ~= false)
		if o.Key and rp then
			cache = cache or {}
			rp.TargetCache[o.Key] = cache
			if result ~= cache.Target or (result and result.Uid ~= cache.Uid) then
				cache.At = now
			end
			cache.Target = result
			cache.Uid = result and result.Uid or nil
			cache.Checked = now
		end
	end
	g.BandY, g.Band, curGround = saved, savedBand, savedGround
	return result
end

-- Aim point at `target` from `origin`: its centre plus a small capped lead (travel time at
-- `speed`, or `seconds` for a lob), never a guaranteed curved hit.
function Rk.aimPoint(origin: Vector3, target: any, speed: number?, seconds: number?): Vector3
	local pos = target.Pos
	local t = seconds
	if not t then
		if not speed or speed <= 0 then
			return pos
		end
		t = ((pos - origin) * FLAT).Magnitude / speed
	end
	local dir = target.Dir
	local v = (dir and typeof(dir) == "Vector3") and (dir * FLAT) * (tonumber(target.Speed) or 0) or Vector3.zero
	local lead = v * math.min(t :: number, Combat.LeadMaxSeconds)
	if lead.Magnitude > Combat.LeadMaxStuds then
		lead = lead.Unit * Combat.LeadMaxStuds
	end
	return pos + lead
end

-- Per-player secondary-emission budget (Combat.SecondaryPerSecond, token bucket on the run clock).
function Rk.tryEmit(rp): boolean
	if not rp then
		return false
	end
	local cap = Combat.SecondaryPerSecond
	local now = Rk.now()
	local tokens = rp.EmitTokens
	if tokens == nil then
		tokens = cap
	end
	local last = rp.EmitAt or now
	if now > last then
		tokens = math.min(cap, tokens + (now - last) * cap)
	end
	rp.EmitAt = now
	if tokens < 1 then
		rp.EmitTokens = tokens
		rp.EmitDropped = (rp.EmitDropped or 0) + 1
		return false
	end
	rp.EmitTokens = tokens - 1
	rp.Emitted = (rp.Emitted or 0) + 1
	return true
end

-- May an effect emit a secondary now? No when the parent is terminal (fragments, pulses, small
-- bubbles, splinters) or already at Combat.MaxChainDepth; else it pays one budget token.
function WeaponSystem.CanEmit(rp, parent: any?): boolean
	if parent and (parent.Terminal or (tonumber(parent.Depth) or 0) >= Combat.MaxChainDepth) then
		return false
	end
	return Rk.tryEmit(rp)
end

-- Per-target hit ledgers by cast id (a cast hits a target once; WeaponSystem.Damage opts.CastId).
Rk.casts = {} :: { [number]: { At: number, Hits: { [number]: boolean } } }
Rk.castSeq = 0
Rk.cleanAt = 0
function WeaponSystem.NewCast(): number
	Rk.castSeq += 1
	Rk.casts[Rk.castSeq] = { At = Rk.now(), Hits = {} }
	return Rk.castSeq
end

function Rk.ledger(castId: number): { [number]: boolean }
	local c = Rk.casts[castId]
	if not c then
		c = { At = Rk.now(), Hits = {} }
		Rk.casts[castId] = c
	end
	return c.Hits
end

-- Slows `e` by `share` (0.2 = 20 % slower) for `seconds`: strongest only, capped (bosses 10 %).
function WeaponSystem.ApplySlow(e, share: number, seconds: number)
	if e and e.Alive then
		slowEnemy(e, 1 - share, seconds, Rk.now())
	end
end

-- Staggers `e` (it stops moving) for `seconds`: bosses never, elites at most 0.15 s, then the
-- enemy is immune for Combat.StaggerImmunity s. True when it was staggered.
function WeaponSystem.Stagger(e, seconds: number): boolean
	if not e or not e.Alive then
		return false
	end
	local s = BuildRules.Stagger(BuildRules.KindOf(e), seconds)
	local now = Rk.now()
	local immune = e.StaggerImmuneUntil
	-- (an immunity far ahead of the clock is from an earlier run: the run clock restarted)
	if s <= 0 or (immune and now < immune and immune - now <= Combat.StaggerImmunity + 1) then
		return false
	end
	e.StaggerUntil = now + s
	e.StaggerImmuneUntil = now + s + Combat.StaggerImmunity
	return true
end

--[[
	Scorch on `e`: 0.12 B per second (x mult) for 3 s in 0.5 s ticks. Reapplying refreshes the
	duration and keeps the strongest source; it never stacks. Ticks are status damage (no crit, no
	procs). True when a new scorch started.
]]
function WeaponSystem.ApplyScorch(rp, e, mult: number?, weapon: any?): boolean
	if not rp or not e or not e.Alive then
		return false
	end
	local now = Rk.now()
	local tick = Combat.ScorchTick
	local dmg = BuildRules.ScorchTickDamage(mult)
	local src = weapon
	if not src then
		src = rp.ScorchSource or {}
		rp.ScorchSource = src
	end
	local ticks = math.max(1, math.floor(Combat.ScorchSeconds / tick + 0.5))
	local b = burns[e]
	if b and b.Uid == e.Uid and now < b.Until then
		-- refresh: the full duration again from now (ticks keep their rhythm), strongest source kept
		b.Until = now + Combat.ScorchSeconds + tick
		b.Ticks = ticks
		if dmg > b.Damage then
			b.Damage, b.Owner, b.Weapon = dmg, rp, src
		end
		return false
	end
	burns[e] = { Uid = e.Uid, Until = now + Combat.ScorchSeconds + tick, Next = now + tick, Tick = tick, Ticks = ticks, Damage = dmg, Owner = rp, Weapon = src, NoProc = true, Scorch = true }
	return true
end

--[[
	WeaponSystem.Damage(rp, enemy, coefficient, weaponId, rank, opts) -> (died, dealt)
	The brief's hit: B x coefficient x (1 + 0.20 (rank - 1)) x (1 + the player's damage bonus) x
	opts.Mult, armor A / (100 + A), knockback by kind and capped, and the crit / proc rules:
	  primary hit (default): may crit (server roll, x1.75) and proc (Splinter Badge, item procs)
	  opts.Secondary = true: a bounce / burst / pulse / fragment: no procs, no crit unless Crit = true
	  opts.Status = true: status damage: never crits, never procs ("Scorch": scorch after the hit)
	  opts.Crit = false: never crits; opts.Proc = false: no procs
	opts also: CastId (hit each target once per cast id; Rehit = true allows more), From (origin:
	sight check unless LOS = false, knockback direction), Dir, Knock (studs/s), Stagger (s), Slow
	(share) + SlowSeconds, Scorch (mult: applies scorch after the hit), Amount (absolute damage
	instead of the formula), NoHarvest. rank defaults to the player's rank of weaponId.
]]
function WeaponSystem.Damage(rp, e, coefficient: number, weaponId: string?, rank: number?, opts: any?): (boolean, number)
	local o = opts or {}
	if not e or not hittable(e) then
		return false, 0
	end
	if o.CastId then
		local hits = Rk.ledger(o.CastId)
		if hits[e.Uid] and not o.Rehit then
			return false, 0
		end
		hits[e.Uid] = true
	end
	if o.From and o.LOS ~= false and not WeaponSystem.HasLineOfSight(o.From, e.Pos) then
		return false, 0
	end
	local s = rp and rp.Stats
	local w = (weaponId and rp and rp.Weapons) and rp.Weapons[weaponId] or nil
	local r = rank or (w and (w.Evolved and BuildRules.MaxRank() or w.Level)) or 1
	local bonus = s and (s.DamageBonus or ((s.Might or 1) - 1)) or 0
	local amount = (tonumber(o.Amount) or BuildRules.HitDamage(coefficient, r, bonus)) * (tonumber(o.Mult) or 1)
	if not (amount > 0 and amount < math.huge) then
		return false, 0
	end
	-- Status = true: this hit IS status damage; Status = "Scorch": apply scorch after the hit (the
	-- shared contract's spelling; Scorch = mult does the same)
	local status = o.Status == true
	local applyScorch = o.Scorch or (o.Status == "Scorch" and 1) or nil
	local secondary = o.Secondary == true
	local procs = not status and not secondary and o.Proc ~= false
	local critOk = not status and (o.Crit == true or (o.Crit == nil and not secondary))
	local critIn: boolean? = nil
	if procs then
		if not critOk then
			critIn = false
		end -- else nil: EnemySpawner rolls it (ItemSystem.ModifyHit, server-side)
	else
		critIn = false
		if critOk and s and rng:NextNumber() < (s.CritChance or 0) then
			amount *= s.CritDamage or Combat.CritMult
			critIn = true
		end
	end
	local dir: Vector3? = o.Dir
	if not dir and o.From then
		local d = (e.Pos - o.From) * FLAT
		dir = d.Magnitude > 1e-3 and d.Unit or nil
	end
	local prevSource = killSource
	if w then
		killSource = w
	end
	local hp0 = e.HP
	local died = damageEnemy(rp, e, amount, dir, tonumber(o.Knock) or 0, not procs, o.NoHarvest, critIn)
	killSource = prevSource
	if e.Alive and not died then
		if o.Stagger then
			WeaponSystem.Stagger(e, o.Stagger)
		end
		if o.Slow then
			WeaponSystem.ApplySlow(e, o.Slow, o.SlowSeconds or 1)
		end
		if applyScorch then
			WeaponSystem.ApplyScorch(rp, e, tonumber(applyScorch) or 1, w)
		end
	end
	return died, math.max(0, hp0 - e.HP)
end

-- Damage to every hittable enemy in sight within `radius` of `at` (each once), nearest first, at
-- most `maxTargets`; primary = a main hit component (crit and procs), else secondary (neither).
-- after(e) runs for each enemy hit that survived. Returns the number hit.
function Rk.burst(rp, at: Vector3, radius: number, damage: number, skip: any?, maxTargets: number?, primary: boolean?, after: ((any) -> ())?): number
	local n = grid():QueryCircle(at.X, at.Z, radius, queryBuf)
	local list = {}
	for i = 1, n do
		local o = queryBuf[i]
		if o ~= skip and hittable(o) then
			table.insert(list, o)
		end
	end
	if maxTargets then
		table.sort(list, function(a, b)
			local da, db = ((a.Pos - at) * FLAT).Magnitude - a.Radius, ((b.Pos - at) * FLAT).Magnitude - b.Radius
			if da ~= db then
				return da < db
			end
			return a.Uid < b.Uid
		end)
	end
	local hit, cap = 0, maxTargets or math.huge
	for _, o in ipairs(list) do
		if hit >= cap then
			break
		end
		if o.Alive and WeaponSystem.HasLineOfSight(at, o.Pos) then
			hit += 1
			local d = (o.Pos - at) * FLAT
			local died = damageEnemy(rp, o, damage, d.Magnitude > 1e-3 and d.Unit or Vector3.zAxis, 4, not primary)
			if after and not died and o.Alive then
				after(o)
			end
		end
	end
	return hit
end

-- Splinter Badge: two 0.15 B splinters at different visible enemies within 8 studs of the hit
-- (secondary and terminal: they never proc or splinter again). Rank of the weapon that hit.
function Rk.splinter(rp, e, at: Vector3)
	local w = killSource
	local rank = tonumber(w and w.Level) or 1
	local dmg = BuildRules.HitDamage(Combat.SplinterCoeff, rank, rp.Stats and rp.Stats.DamageBonus or 0)
	local exclude = { [e.Uid] = true }
	for _ = 1, Combat.SplinterCount do
		local o = Rk.pick(at, Combat.SplinterRange, exclude, false)
		if not o or not Rk.tryEmit(rp) then
			break
		end
		exclude[o.Uid] = true
		local d = (o.Pos - at) * FLAT
		damageEnemy(rp, o, dmg, d.Magnitude > 1e-3 and d.Unit or nil, 0, true)
		pushFx("fk", { r1(o.Pos.X), r1(o.Pos.Z), 1.2 })
	end
	rp.Splinters = (rp.Splinters or 0) + 1
end

-- A rank shot: a straight projectile that stops at its first enemy (Pierce) and may bounce on.
function Rk.shot(rp, w, s, pos: Vector3, dir: Vector3, damage: number, o: any): Projectile?
	local spec = s.spec
	local p = allocProjectile()
	if not p then
		return nil
	end
	p.Kind = "Straight"
	p.Visual = o.Visual
	p.Owner = rp
	p.Weapon = w
	p.Pos = pos
	p.Vel = dir * spec.Speed
	p.Damage = damage
	p.Pierce = o.Pierce or 1
	p.Radius = (spec.Radius or 1) * s.area
	p.Life = spec.Range / spec.Speed + 0.1
	p.Knockback = s.knockback
	p.Yaw = yawOf(dir)
	p.Terrain = true
	p.NoProc = o.Secondary or nil
	if (o.Bounces or 0) > 0 then
		p.Bounces = o.Bounces
		p.BounceRange = spec.BounceRange or 10
		p.BounceDamage = BuildRules.B() * (spec.BounceCoeff or spec.Coeff) * s.mult
		p.NoProcOnBounce = true
	end
	return p
end

-- The weapon's class passive / kit hooks only work for that class (cross-class weapons give the
-- weapon behaviour only).
function Rk.own(rp, def): boolean
	return def.ClassOnly ~= nil and def.ClassOnly == rp.CharacterId
end

--[[
	RANK SHOT (Scrap Shot, Toast Toss; Dodgeball and Ricochet Puck through Fire.RankDodgeball /
	RankPuck, [stream C]): Amount projectiles at the nearest visible target (small capped
	lead), each stopping at its first enemy and bouncing Bounces times to different visible targets
	within BounceRange (secondary hits). Milestones / evolutions: ExtraShots (Scrap rank 5),
	FinalBurst (Toast rank 5), Pulse (Junkyard Cyclone), FollowUp (Toaststorm).
]]
function Fire.RankShot(rp, w, s, def)
	local spec = s.spec
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, spec.Range, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15) -- nothing in sight and range: look again soon
		return
	end
	local evo = w.Evolved and def.Evolution or nil
	local own = Rk.own(rp, def)
	local visual = visualByte((evo and spec.EvoVisual) or spec.Visual or (def.Params and def.Params.Visual) or 1, w)
	local dir = flatDir(Rk.aimPoint(origin, target, spec.Speed) - origin, rp.Facing)
	local B = BuildRules.B()
	local burst = spec.FinalBurst and { R = spec.FinalBurst.Radius * s.area, Damage = B * spec.FinalBurst.Coeff * s.mult } or nil
	local pulse = (evo and evo.Pulse) and { R = evo.Pulse.Radius * s.area, Damage = B * evo.Pulse.Coeff * s.mult } or nil
	local n = s.amount
	local damage = s.damage
	-- [stream C] Junk Collector (Ruckus's class passive): a stored charge turns this Scrap Shot into a
	-- barrage of Shots scraps (Coeff each, the weapon's bounces), each at another visible target
	-- when there is one (RunConfig.Classes.JunkCollector)
	local kits = ctx.ClassKits
	local barrage = (own and def.Id == "ScrapToss" and kits ~= nil) and kits.TakeBarrage(rp) or nil
	local aims: { any }? = nil
	if barrage then
		n = barrage.Shots + math.max(0, s.amount - 1)
		damage = B * barrage.Coeff * s.mult
		local list, ex = { target }, { [target.Uid] = true }
		for _ = 2, n do
			local o = WeaponSystem.NearestTarget(rp, spec.Range, { From = origin, Exclude = ex })
			if not o then
				break
			end
			ex[o.Uid] = true
			table.insert(list, o)
		end
		aims = list
		Fx.Ring(origin, 5, Color3.fromRGB(240, 200, 90))
	end
	for i = 1, n do
		local d = n > 1 and rotateY(dir, (i - (n + 1) / 2) * math.rad(spec.Spread or 6)) or dir
		if aims then
			local a = aims[i]
			d = a and flatDir(Rk.aimPoint(origin, a, spec.Speed) - origin, dir)
				or rotateY(dir, (i % 2 == 0 and 1 or -1) * math.rad((barrage :: any).Spread) * math.ceil((i - 1) / 2))
		end
		local p = Rk.shot(rp, w, s, origin + d * 1.5, d, damage, { Visual = visual, Pierce = spec.Pierce, Bounces = spec.Bounces })
		if not p then
			break
		end
		if burst or pulse then
			p.Final = "Rank"
			p.X = { Burst = burst, Pulse = pulse }
		end
		if own and def.Id == "ToastVolley" then
			p.Hook = "Toast" -- Overheat (Toastmaster's class passive)
		end
	end
	-- Scrap Shot rank 5: one more 0.40 B scrap at another visible target (a secondary projectile)
	if (spec.ExtraShots or 0) > 0 then
		local other = WeaponSystem.NearestTarget(rp, spec.Range, { From = origin, Exclude = { [target.Uid] = true } }) or target
		for _ = 1, spec.ExtraShots do
			if not Rk.tryEmit(rp) then
				break
			end
			local d = flatDir(Rk.aimPoint(origin, other, spec.Speed) - origin, dir)
			Rk.shot(rp, w, s, origin + d * 1.5, d, B * spec.ExtraCoeff * s.mult, { Visual = visual, Secondary = true })
		end
	end
	-- Toaststorm: a second 0.35 B toast follows 0.12 s later (secondary, no bounce)
	if evo and evo.FollowUp then
		local follow = evo.FollowUp
		local uid = target.Uid
		task.delay(follow.Delay, function()
			if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() or not Rk.tryEmit(rp) then
				return
			end
			local from = ground(rp.Root.Position)
			useGround(from.Y)
			local t = (target.Alive and target.Uid == uid) and target or WeaponSystem.NearestTarget(rp, spec.Range, { From = from })
			if t then
				local d = flatDir(Rk.aimPoint(from, t, spec.Speed) - from, rp.Facing)
				Rk.shot(rp, w, s, from + d * 1.5, d, B * follow.Coeff * s.mult, { Visual = visual, Secondary = true })
			end
			useGround(nil)
		end)
	end
	Fx.Sound("Hit")
end

-- A rank shot's last impact: Toast rank 5's burst and Junkyard Cyclone's pulse (after a bounce).
-- Both are secondary and terminal (they never emit anything).
function Class.Final.Rank(p: Projectile, e, at: Vector3)
	local x = p.X
	local owner = p.Owner
	if not x or not owner or not owner.Alive then
		return
	end
	if x.Burst and Rk.tryEmit(owner) then
		Rk.burst(owner, at, x.Burst.R, x.Burst.Damage, e)
		pushFx("fk", { r1(at.X), r1(at.Z), r1(x.Burst.R) })
	end
	if x.Pulse and (p.Bounced or 0) >= 1 and Rk.tryEmit(owner) then
		Rk.burst(owner, at, x.Pulse.R, x.Pulse.Damage, e)
		pushFx("fk", { r1(at.X), r1(at.Z), r1(x.Pulse.R) })
	end
end

--[[
	RANK SWING (Sword; Mop Sweep; placeholder for Protein Claws, Glove Combo): one arc in front
	(Reach x area studs, Arc degrees) turned gently toward the selected nearby enemy, hitting the
	nearest MaxTargets enemies in it that are in sight; Slow = { Share, Seconds } slows them.
]]
function Fire.RankSwing(rp, w, s, def)
	local spec = s.spec
	local reach = spec.Reach * s.area
	local half = math.rad(spec.Arc) / 2
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, reach * 1.5, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	local dir = flatDir(target.Pos - origin, rp.Facing)
	w.Attacks = (w.Attacks or 0) + 1
	local sweep = (spec.Alternate and w.Attacks % 2 == 0) and -1 or 1
	Fx.Slash(origin, yawOf(dir), reach, sweep, visualTier(w), rp.Player.UserId)
	task.delay(SWING_HIT_DELAY, function()
		if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() then
			return
		end
		killSource = w -- a delayed hit: credit this weapon (OnKill)
		local at = ground(rp.Root.Position)
		useGround(at.Y)
		local n = grid():QueryCircle(at.X, at.Z, reach, queryBuf)
		local list = {}
		for i = 1, n do
			local e = queryBuf[i]
			if hittable(e) and inSwing(e, at, dir, reach, half) then
				table.insert(list, e)
			end
		end
		table.sort(list, function(a, b)
			local da, db = ((a.Pos - at) * FLAT).Magnitude - a.Radius, ((b.Pos - at) * FLAT).Magnitude - b.Radius
			if da ~= db then
				return da < db
			end
			return a.Uid < b.Uid
		end)
		local hits, now = 0, Rk.now()
		for _, e in ipairs(list) do
			if hits >= spec.MaxTargets then
				break
			end
			if e.Alive and WeaponSystem.HasLineOfSight(at, e.Pos) then
				hits += 1
				local died = hitEnemy(rp, e, s.damage, at, s.knockback)
				if spec.Slow and not died and e.Alive then
					slowEnemy(e, 1 - spec.Slow.Share, spec.Slow.Seconds, now)
				end
			end
		end
		useGround(nil)
		killSource = nil
	end)
	Fx.Sound("Hit")
end

--[[
	RANK BUBBLE (Bubble Bomb): a bubble flying at the nearest visible target: ImpactCoeff to the
	first enemy it touches, then a BurstCoeff burst (BurstRadius) after its ground bounce or the
	Fuse, whichever comes first (two documented hit components; each target once per burst). Rank
	5: a second bubble at half damage (secondary). Bubble Torrent: a primary burst leaves two small
	bubbles (0.25 B each, separate visible enemies within 8, terminal). Big Splash (the class
	passive): the next bubble's burst is stronger / wider (RunConfig.Classes.BigSplash).
]]
function Fire.RankBubble(rp, w, s, def)
	local spec = s.spec
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, spec.Range, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	local kits = ctx.ClassKits
	local splash = (Rk.own(rp, def) and kits ~= nil) and kits.TakeSplash(rp) or nil
	Rk.bubble(rp, w, def, s, origin, target, splash, 1, false)
	local second = spec.SecondBubble
	if second then
		local uid = target.Uid
		task.delay(second.Delay, function()
			if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() or not Rk.tryEmit(rp) then
				return
			end
			local from = ground(rp.Root.Position)
			useGround(from.Y)
			local t = (target.Alive and target.Uid == uid) and target or WeaponSystem.NearestTarget(rp, spec.Range, { From = from })
			if t then
				Rk.bubble(rp, w, def, s, from, t, nil, second.Share, true)
			end
			useGround(nil)
		end)
	end
	Fx.Sound("Hit")
end

function Rk.bubble(rp, w, def, s, origin: Vector3, target, splash: any?, share: number, secondary: boolean)
	local spec = s.spec
	local evo = w.Evolved and def.Evolution or nil
	local to = (Rk.aimPoint(origin, target, spec.Speed) - origin) * FLAT
	local dist = math.min(to.Magnitude, spec.Range)
	local dir = flatDir(to, rp.Facing)
	local p = allocProjectile()
	if not p then
		return
	end
	local B = BuildRules.B()
	local big = splash ~= nil
	local flight = math.max(0.05, (dist - 1.5) / spec.Speed)
	p.Kind = "RBubble"
	p.Visual = WeaponData.VisualByte((evo and spec.EvoVisual) or spec.Visual, big and 3 or visualTier(w))
	p.Owner = rp
	p.Weapon = w
	p.Pos = origin + dir * 1.5
	p.Vel = dir * spec.Speed
	p.Damage = B * spec.ImpactCoeff * s.mult * share
	p.Pierce = 1
	p.Radius = (spec.Radius or 1) * s.area * (big and 1.2 or 1)
	p.Life = math.min(spec.Fuse, flight + (spec.BounceTime or 0.15))
	p.Knockback = s.knockback
	p.Yaw = yawOf(dir)
	p.Terrain = true
	p.NoProc = secondary or nil
	p.X = {
		Flight = flight,
		R = spec.BurstRadius * s.area * ((big and splash.RadiusMult) or 1),
		Burst = B * spec.Coeff * s.mult * share * ((big and splash.DamageMult) or 1),
		Secondary = secondary,
		Evo = (not secondary and evo) and evo.SmallBubbles or nil,
		Mult = s.mult,
	}
end

function Rk.stepBubble(p: Projectile, dt: number, now: number): boolean
	local x = p.X
	if p.Age < x.Flight then
		local before = p.Pos
		p.Pos += p.Vel * dt
		p.Yaw += dt * 6
		if Rk.terrainBlocked(p) then
			p.Pos = before -- a cliff: it stops here and bursts on its fuse
			x.Flight = p.Age
		end
	else
		-- the ground bounce: one small hop on the spot before the burst
		local u = math.clamp((p.Age - x.Flight) / 0.15, 0, 1)
		p.Y = (p.LastGround or p.Ground) + 1.2 + 1.2 * math.sin(u * math.pi)
	end
	if not p.Impacted then
		local n = grid():QueryCircle(p.Pos.X, p.Pos.Z, p.Radius, queryBuf)
		for i = 1, n do
			local e = queryBuf[i]
			if hittable(e) then
				p.Impacted = true -- the direct impact: the first enemy it touches, once
				p.Hits[e.Uid] = now
				local d = p.Vel * FLAT
				damageEnemy(p.Owner, e, p.Damage, d.Magnitude > 1e-3 and d.Unit or nil, p.Knockback, p.NoProc == true)
				break
			end
		end
	end
	return false
end

function Rk.popBubble(p: Projectile)
	local x = p.X
	local owner = p.Owner
	if not x or not owner or not owner.Alive then
		return
	end
	local at = p.Pos
	Rk.burst(owner, at, x.R, x.Burst, nil, nil, not x.Secondary)
	pushFx("fk", { r1(at.X), r1(at.Z), r1(x.R) })
	local evo = x.Evo
	if evo then
		local exclude = {}
		local dmg = BuildRules.B() * evo.Coeff * x.Mult
		for _ = 1, evo.Count do
			local o = Rk.pick(at, evo.Range, exclude, false)
			if not o or not Rk.tryEmit(owner) then
				break
			end
			exclude[o.Uid] = true
			local d = (o.Pos - at) * FLAT
			damageEnemy(owner, o, dmg, d.Magnitude > 1e-3 and d.Unit or nil, 0, true)
			pushFx("fk", { r1(o.Pos.X), r1(o.Pos.Z), 1.5 })
		end
	end
end

--[[
	RANK YARN (Yarn Bomb): a yarn ball thrown at the nearest visible target (small capped lead); it
	bursts after Fuse s for the full hit on at most MaxTargets enemies in BlastRadius that the
	blast can see (terrain blocks it). Tangled Up (Granny's class passive) tangles what survives.
	Knitting Nightmare: three radial 0.15 B fragments, each hitting once (secondary, terminal).
]]
function Fire.RankYarn(rp, w, s, def)
	local spec = s.spec
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, spec.Range, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	local evo = w.Evolved and def.Evolution or nil
	local fuse = spec.Fuse
	local radius = spec.BlastRadius * s.area
	local at = ground(Rk.aimPoint(origin, target, nil, fuse))
	for i = 1, s.amount do
		local p = allocProjectile()
		if not p then
			return
		end
		p.Kind = "Yarn"
		p.Visual = visualByte(spec.Visual or 60, w)
		p.Owner = rp
		p.Weapon = w
		p.Pos = origin
		p.Vel = Vector3.zero
		p.Life = fuse + (i - 1) * 0.1
		p.Damage = s.damage
		p.Pierce = 999
		p.Radius = 0
		p.Knockback = s.knockback
		p.Yaw = yawOf(flatDir(at - origin, rp.Facing))
		p.X = { From = origin, To = at, R = radius, Rank = true, Max = spec.MaxTargets, Own = Rk.own(rp, def), Frag = evo and evo.Fragments or nil, Mult = s.mult }
		pushFx("mt", { r1(at.X), r1(at.Z), r1(radius), r1(fuse), evo and 1 or 0 })
	end
	Fx.Sound("Hit")
end

function Rk.landYarn(p: Projectile, x: any)
	local owner = p.Owner
	local at = x.To
	local now = Rk.now()
	local kits = ctx.ClassKits
	local tangle = (x.Own and kits) and function(e)
		kits.OnYarnHit(owner, e, now)
	end or nil
	Rk.burst(owner, at, x.R, p.Damage, nil, x.Max, true, tangle)
	Fx.Explosion(at, x.R)
	local f = x.Frag
	if f then
		local base = rng:NextNumber() * TAU
		for i = 1, f.Count do
			if not Rk.tryEmit(owner) then
				break
			end
			local q = allocProjectile()
			if not q then
				break
			end
			local a = base + (i - 1) * TAU / f.Count
			local d = Vector3.new(math.cos(a), 0, math.sin(a))
			q.Kind = "Straight"
			q.Visual = p.Visual
			q.Owner = owner
			q.Weapon = p.Weapon
			q.Pos = at + d
			q.Ground = at.Y
			q.Y = at.Y + Config.Projectiles.Height
			q.Vel = d * f.Speed
			q.Damage = BuildRules.B() * f.Coeff * x.Mult
			q.Pierce = 1
			q.Radius = 0.8
			q.Life = f.Range / f.Speed
			q.Knockback = 2
			q.Yaw = yawOf(d)
			q.NoProc = true -- a fragment: secondary, no procs, never another fragment
			q.Terrain = true
		end
	end
	Fx.Sound("Hit")
end

--[[
	RANK ORB (Magic Orb): Amount orbs circling the hero (OrbitRadius x area, RevPerSecond turns per
	second), each hitting an enemy at most once per interval (its own contact ledger, p.Hits).
	The Ward Shields orbit (Arm.stepWard) without Bulwark.
]]
function Fire.RankOrb(rp, w, s, _def)
	local spec = s.spec
	local list = Arm.liveList(w)
	for i = #list, s.amount + 1, -1 do
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
	local orbit = spec.OrbitRadius * s.area
	local spin = TAU * spec.RevPerSecond
	for i, p in ipairs(list) do
		p.Visual = visualByte(spec.Visual or 1, w)
		p.Angle = base + (i - 1) * TAU / #list
		p.Damage = s.damage
		p.Radius = (spec.Radius or 1.2) * s.area
		p.Rehit = s.cooldown
		p.Knockback = s.knockback
		p.X.Orbit = orbit
		p.X.Spin = spin
		p.X.Reflect = false
		p.X.ReflectRadius = 0
		wards[p] = nil
		Arm.orbitFx(p, orbit, 0, spin, p.Angle)
	end
end

--[[
	RANK VORTEX (Vortex): a rift at the densest visible spot within Range (the existing rift look),
	VortexRadius x area, lasting Duration s: Coeff pulses every Tick s (fixed, not attack speed) on
	at most MaxTargets enemies it can see, each once per pulse; ordinary enemies (not elites or
	bosses) drift inward at Pull studs/s. One rift per owner: a new one closes the old.
]]
function Fire.RankVortex(rp, w, s, _def)
	local spec = s.spec
	local origin = ground(rp.Root.Position)
	local radius = spec.VortexRadius * s.area
	local t = Arm.densest(origin, spec.Range, 10, radius * 1.5)
	if not t then
		w.Timer = math.min(w.Timer, 0.4)
		return
	end
	for q in pairs(w.Live) do
		if q.Active and q.Kind == "Vortex" then
			q.Cancelled = true
		end
	end
	local at = ground(t.Pos)
	local p = allocProjectile()
	if not p then
		return
	end
	p.Kind = "Vortex"
	p.Visual = visualByte(spec.Visual or 55, w)
	p.Owner = rp
	p.Weapon = w
	p.Pos = at
	p.Ground = HeightGrid.GroundY(at.X, at.Z)
	p.Y = p.Ground + 0.15
	p.Vel = Vector3.zero
	p.Damage = s.damage
	p.Pierce = 999
	p.Radius = 0
	p.Life = s.duration
	p.Knockback = 0
	p.X = { R = radius, Tick = spec.Tick, T = 0.1, Pull = spec.Pull, Max = spec.MaxTargets, Rank = true, Evo = 0 }
	w.Live[p] = true
	pushFx("vx", { r1(at.X), r1(at.Z), r1(radius), r1(s.duration), 0 })
end

function Rk.stepVortex(p: Projectile, dt: number, _now: number): boolean
	local owner = p.Owner
	if not owner.Alive then
		return true
	end
	local x = p.X
	local c = p.Pos
	p.Yaw += dt * 4
	local n = grid():QueryCircle(c.X, c.Z, x.R, queryBuf)
	local list = table.move(queryBuf, 1, n, 1, {})
	-- the inward pull: ordinary enemies only (velocity floor along the inward direction), and only
	-- those the rift could see at its last pulse (it never drags anything across terrain)
	local seen = x.Seen
	for _, e in ipairs(list) do
		if seen and seen[e] and e.Alive and not e.Boss and not e.Elite and e.Knock then
			local rel = (c - e.Pos) * FLAT
			local d = rel.Magnitude
			if d > 0.8 then
				local inward = rel / d
				local along = e.Knock:Dot(inward)
				if along < x.Pull then
					e.Knock += inward * (x.Pull - along)
				end
			end
		end
	end
	x.T -= dt
	if x.T > 0 then
		return false
	end
	x.T = x.Tick
	Rk.burst(owner, c, x.R, p.Damage, nil, x.Max, true)
	-- who the rift can see now (the pull set until the next pulse)
	local vis = {}
	for _, e in ipairs(list) do
		if e.Alive and WeaponSystem.HasLineOfSight(c, e.Pos) then
			vis[e] = true
		end
	end
	x.Seen = vis
	return false
end

-- Per frame (WeaponSystem.Step): forget cast ledgers older than 10 s.
function Rk.step(_dt: number, now: number)
	if now < Rk.cleanAt and Rk.cleanAt - now < 5 then
		return
	end
	Rk.cleanAt = now + 2
	for id, c in pairs(Rk.casts) do
		if now - c.At > 10 or c.At > now + 1 then
			Rk.casts[id] = nil
		end
	end
end

-- (tests) the secondary budget and the projectile counts by kind.
WeaponSystem._Rank = Rk

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
	Yarn = Class.stepYarn,
	Can = Class.stepCan,
	RBubble = Rk.stepBubble, -- [stream B] Bubble Bomb (rank system)
}

------------------------------------------------------------------------------------------
-- [stream C] CLASS KITS: the 8 newer signature behaviours (Fire.RankDodgeball, RankSneakers,
-- RankSeed, RankConfetti, RankClaws, RankPuck, RankGlove; Mop Sweep is RankSwing) and the kit
-- helpers ClassKits uses (KitQuery, KitBurst, KitDamageFactor, KitCan, KitBalloon, KitPlant,
-- GloveCharge). Numbers: WeaponData rank specs and RunConfig.Classes. Shared rules (stream B):
-- WeaponSystem.Damage / NearestTarget / HasLineOfSight / CanEmit, the per-player secondary budget
-- (Rk.tryEmit). Every secondary here (bounces, second ball, return leg, plant shots, claw pulse,
-- shockwave, kit blasts, mini-pops) never crits or procs and never emits anything itself.
-- Docs: docs/redesign/gameplay/CLASSES.md.
------------------------------------------------------------------------------------------

-- Hittable enemies within `radius` of `pos` on pos's level, nearest body edge first (ties by Uid).
function WeaponSystem.KitQuery(pos: Vector3, radius: number): { any }
	local g = grid()
	local saved, savedBand, savedGround = g.BandY, g.Band, curGround
	local at = ground(pos)
	useGround(at.Y)
	local n = g:QueryCircle(at.X, at.Z, radius, queryBuf)
	local list = {}
	for i = 1, n do
		local e = queryBuf[i]
		if hittable(e) then
			table.insert(list, e)
		end
	end
	g.BandY, g.Band, curGround = saved, savedBand, savedGround
	table.sort(list, function(a, b)
		local da, db = ((a.Pos - at) * FLAT).Magnitude - a.Radius, ((b.Pos - at) * FLAT).Magnitude - b.Radius
		if da ~= db then
			return da < db
		end
		return a.Uid < b.Uid
	end)
	return list
end

-- The factor that adds `extra` to the player's additive damage bonus inside the shared 0..2 clamp:
-- (1 + clamp(bonus + extra)) / (1 + clamp(bonus)). Stride, Garden Company.
function WeaponSystem.KitDamageFactor(rp, extra: number): number
	local st = rp and rp.Stats
	local b = st and (st.DamageBonus or ((st.Might or 1) - 1)) or 0
	return (1 + BuildRules.DamageBonus(b + extra)) / (1 + BuildRules.DamageBonus(b))
end

--[[
	A kit blast: coeff x B at the rank of `weaponId` (the hero's signature) to every hittable enemy in
	sight within `radius` of `at`, nearest first (WeaponSystem.Damage: armor, knockback rules, statuses).
	opts: Max (targets), CastId (each target once per cast: the cans of one dash, the mini-pops of one
	grenade, one tackle), Exclude ({ [uid] = true }), Primary (crit + procs; default: a secondary,
	neither), Knock, Stagger, Slow + SlowSeconds, Mult, Rank, Fx (false: no burst effect), Dash (a dash
	effect) / Close (a close-range effect): the kill source the OnKill listeners get is then
	{ Id = weaponId, Dash = true | Close = true } (stream E2's CloseKills class goal), not the weapon.
	Returns the number hit and the enemies hit.
]]
function WeaponSystem.KitBurst(rp, at: Vector3, radius: number, coeff: number, weaponId: string?, opts: any?): (number, { any })
	local o = opts or {}
	local list = WeaponSystem.KitQuery(at, radius)
	local ledger = o.CastId and Rk.ledger(o.CastId) or nil
	local rank, damageWeapon, source = o.Rank, weaponId, nil
	if o.Dash or o.Close then
		-- a movement / landing effect: credited to a source marked Dash / Close at the weapon's rank
		local w = weaponId and rp and rp.Weapons and rp.Weapons[weaponId] or nil
		rank = rank or (w and (w.Evolved and BuildRules.MaxRank() or w.Level)) or 1
		damageWeapon = nil
		source = { Id = weaponId, Level = rank, Dash = o.Dash == true or nil, Close = o.Close == true or nil }
	end
	local dopts = {
		Secondary = if o.Primary then nil else true,
		CastId = o.CastId,
		LOS = false, -- checked below, so a blocked target is never marked in the cast ledger
		From = at,
		Knock = o.Knock,
		Stagger = o.Stagger,
		Slow = o.Slow,
		SlowSeconds = o.SlowSeconds,
		Mult = o.Mult,
	}
	local hit, hits = 0, {}
	local cap = o.Max or math.huge
	for _, e in ipairs(list) do
		if hit >= cap then
			break
		end
		if e.Alive and not (ledger and ledger[e.Uid]) and not (o.Exclude and o.Exclude[e.Uid]) and WeaponSystem.HasLineOfSight(at, e.Pos) then
			hit += 1
			table.insert(hits, e)
			local prevSource = killSource
			if source then
				killSource = source
			end
			WeaponSystem.Damage(rp, e, coeff, damageWeapon, rank, dopts)
			killSource = prevSource
		end
	end
	if o.Fx ~= false and radius > 0 then
		pushFx("fk", { r1(at.X), r1(at.Z), r1(radius) })
	end
	return hit, hits
end

-- The signature weapon record of the hero's class (nil when not held) and its id.
function Class.signature(rp): (any?, string?)
	local id = WeaponData.Signatures[rp.CharacterId]
	return id and rp.Weapons[id] or nil, id
end

-- Ruckus's dash: one rolling can from `pos` along `dir`; it explodes after cfg.Fuse (KitBurst with the
-- dash's cast `castId`: one can hit per target per dash). At most cfg.MaxLive cans of the hero at once.
function WeaponSystem.KitCan(rp, pos: Vector3, dir: Vector3, castId: number, cfg: any): boolean
	local w, weaponId = Class.signature(rp)
	local mine = 0
	for _, o in ipairs(live) do
		if o.Kind == "Can" and o.Owner == rp and not o.Cancelled then
			mine += 1
		end
	end
	if mine >= cfg.MaxLive then
		return false
	end
	local p = allocProjectile()
	if not p then
		return false
	end
	local at = ground(pos)
	local d = flatDir(dir, rp.Facing)
	p.Kind = "Can"
	p.Visual = WeaponData.VisualByte(61, w and visualTier(w) or 0)
	p.Owner = rp
	p.Weapon = w
	p.Pos = at
	p.Ground = at.Y
	p.Y = at.Y + 0.7
	p.Vel = d * cfg.RollSpeed
	p.Life = cfg.Fuse
	p.Damage = 0
	p.Pierce = 999
	p.Radius = 0
	p.Knockback = 0
	p.Yaw = yawOf(d)
	p.X = { R = cfg.Radius, Coeff = cfg.Coeff, CastId = castId, WeaponId = weaponId or "ScrapToss" }
	return true
end

-- Rambozo's dash: one balloon grenade at `pos` (RunConfig.Classes.BalloonGrenade).
function WeaponSystem.KitBalloon(rp, pos: Vector3, dir: Vector3, cfg: any): boolean
	local w, weaponId = Class.signature(rp)
	local p = allocProjectile()
	if not p then
		return false
	end
	local at = ground(pos)
	local d = flatDir(dir, rp.Facing)
	p.Kind = "Balloon"
	p.Visual = WeaponData.VisualByte(59, 0)
	p.Owner = rp
	p.Weapon = w
	p.Pos = at
	p.Ground = at.Y
	p.Y = at.Y + 2.2
	p.Vel = Vector3.zero
	p.Life = cfg.Fuse
	p.Damage = 0
	p.Pierce = 999
	p.Radius = 0
	p.Knockback = 0
	p.Yaw = yawOf(d)
	p.X = { Cfg = cfg, WeaponId = weaponId or "ConfettiMinigun", Dir = d }
	return true
end

function Class.stepBalloon(p: Projectile, dt: number, _now: number): boolean
	p.Yaw += dt * 2
	p.Y = p.Ground + 2.2 + 0.3 * math.sin(p.Age * 9)
	return false
end

-- The grenade pops: the Coeff blast, then MiniCount mini-pops MiniDelay later (fixed fragments of
-- this grenade: each pays one budget token, each target takes at most one of them, they never
-- explode again).
Class.Expire.Balloon = function(p: Projectile)
	local owner, x = p.Owner, p.X
	if not owner or not owner.Alive or not x then
		return
	end
	local c = x.Cfg
	local at = p.Pos
	WeaponSystem.KitBurst(owner, at, c.Radius, c.Coeff, x.WeaponId, { Dash = true, Fx = false })
	Fx.Explosion(at, c.Radius)
	Fx.Sound("Hit")
	local cast = WeaponSystem.NewCast()
	local d = x.Dir
	task.delay(c.MiniDelay, function()
		if not owner.Alive or not ctx.RunManager.IsSimulating() then
			return
		end
		owner.MiniPops = owner.MiniPops or 0
		for i = 1, c.MiniCount do
			if not WeaponSystem.CanEmit(owner, { Depth = 1 }) then
				break
			end
			local spot = ground(at + rotateY(d, math.pi / 2 + (i - 1) * TAU / c.MiniCount) * c.MiniOffset)
			WeaponSystem.KitBurst(owner, spot, c.MiniRadius, c.MiniCoeff, x.WeaponId, { CastId = cast, Dash = true })
			owner.MiniPops += 1
		end
	end)
end

------------------------------------------------------------------------------------------
-- Seed Slinger (Barry Plotter): seeds that grow stationary shooting plants
------------------------------------------------------------------------------------------

-- The live plants of seed weapon `w`, oldest first.
function Class.plants(w): { Projectile }
	local list = {}
	for p in pairs(w.Live) do
		if p.Active and not p.Cancelled and p.Kind == "Plant" then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		if a.X.Born ~= b.X.Born then
			return a.X.Born < b.X.Born
		end
		return a.Id < b.Id
	end)
	return list
end

-- Grows a plant of seed weapon `w` at `pos` (reachable ground only: no plant on water, a cliff face
-- or a gap). The cap (PlantCap) replaces the oldest plant. Plants never plant anything.
function Class.plant(rp, w, pos: Vector3): Projectile?
	if HeightGrid.IsActive() and not HeightGrid.IsWalkable(pos.X, pos.Z) then
		return nil
	end
	local s = weaponStats(rp, w)
	local spec = s.spec
	if not spec or not spec.PlantCoeff then
		return nil
	end
	local list = Class.plants(w)
	for i = 1, #list - (spec.PlantCap or 3) + 1 do
		list[i].Cancelled = true -- the oldest plant goes
	end
	local p = allocProjectile()
	if not p then
		return nil
	end
	local at = ground(pos)
	p.Kind = "Plant"
	p.Visual = visualByte(spec.PlantVisual or 51, w)
	p.Owner = rp
	p.Weapon = w
	p.Pos = at
	p.Ground = at.Y
	p.Y = at.Y
	p.Vel = Vector3.zero
	p.Life = spec.PlantSeconds
	p.Damage = BuildRules.B() * spec.PlantCoeff * s.mult
	p.Pierce = 999
	p.Radius = 0
	p.Knockback = 0
	local def = WeaponData.Weapons[w.Id]
	p.X = {
		Born = Rk.now(),
		T = spec.PlantFireEvery,
		Every = spec.PlantFireEvery,
		Range = spec.PlantRange,
		Own = def ~= nil and def.ClassOnly == rp.CharacterId, -- Garden Company: Barry's own plants only
		Shots = 0,
	}
	w.Live[p] = true
	pushFx("vn", { r1(at.X), r1(at.Z), 1.5, 0 })
	return p
end

-- Live plants of the hero's signature Seed Slinger and its cap (HUD): count, cap.
function WeaponSystem.KitPlants(rp): (number, number)
	local w, id = Class.signature(rp)
	if not w or not id or WeaponData.BehaviorOf(id) ~= "RankSeed" then
		return 0, 0
	end
	local spec = WeaponData.RankSpec(id, w.Evolved and BuildRules.MaxRank() or w.Level)
	return #Class.plants(w), spec and spec.PlantCap or 3
end

-- A cosmetic weapon effect for the clients (the WeaponFx keys listed at pushFx), e.g. Doug's wet trail.
function WeaponSystem.KitFx(key: string, value: { any })
	pushFx(key, value)
end

-- Barry's dash: one extra seed at `pos` from his Seed Slinger (shares the plant cap).
function WeaponSystem.KitPlant(rp, pos: Vector3): boolean
	local w, id = Class.signature(rp)
	if not w or not id or WeaponData.BehaviorOf(id) ~= "RankSeed" then
		return false
	end
	return Class.plant(rp, w, pos) ~= nil
end

-- A plant: once per Every s it shoots a seed pellet (PlantCoeff, secondary: one budget token) at the
-- nearest visible enemy within Range; Garden Company adds its bonus while Barry stands close.
function Class.stepPlant(p: Projectile, dt: number, _now: number): boolean
	local owner = p.Owner
	local x = p.X
	x.T -= dt
	if x.T > 0 or not owner or not owner.Alive then
		return false
	end
	local target = Rk.pick(p.Pos, x.Range, nil, false)
	if not target or not Rk.tryEmit(owner) then
		x.T = 0.2 -- nothing in sight (or no budget): look again soon
		return false
	end
	x.T = x.Every
	x.Shots += 1
	local factor = 1
	local kits = ctx.ClassKits
	if x.Own and kits and owner.Root then
		local G = kits.Config().GardenCompany
		if ((owner.Root.Position - p.Pos) * FLAT).Magnitude <= G.Range then
			factor = WeaponSystem.KitDamageFactor(owner, G.DamageBonus)
		end
	end
	local speed = 60
	local dir = flatDir(Rk.aimPoint(p.Pos, target, speed) - p.Pos, Vector3.zAxis)
	local q = allocProjectile()
	if not q then
		return false
	end
	q.Kind = "Straight"
	q.Visual = WeaponData.VisualByte(45, 0)
	q.Owner = owner
	q.Weapon = p.Weapon
	q.Pos = p.Pos + dir * 0.8
	q.Ground = p.Ground
	q.Y = p.Ground + Config.Projectiles.Height
	q.Vel = dir * speed
	q.Damage = p.Damage * factor
	q.Pierce = 1
	q.Radius = 0.8
	q.Life = x.Range / speed + 0.15
	q.Knockback = 0
	q.Yaw = yawOf(dir)
	q.NoProc = true -- a plant shot: secondary, never a seed or another plant
	q.Terrain = true
	q.PlantShot = true
	return false
end

function Fire.RankSeed(rp, w, s, _def)
	local spec = s.spec
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, spec.Range, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	local to = (Rk.aimPoint(origin, target, spec.Speed) - origin) * FLAT
	local dist = math.min(to.Magnitude, spec.Range)
	local dir = flatDir(to, rp.Facing)
	local p = Rk.shot(rp, w, s, origin + dir * 1.5, dir, s.damage, { Visual = visualByte(spec.Visual or 45, w) })
	if not p then
		return
	end
	p.Kind = "Seed"
	p.Life = math.max(0.05, (dist - 1.5) / spec.Speed)
	p.X = { Landed = false }
	Fx.Sound("Hit")
end

-- The seed lands: a plant at its spot (once).
function Class.landSeed(p: Projectile)
	local x = p.X
	if not x or x.Landed or not p.Owner or not p.Owner.Alive or not p.Weapon then
		return
	end
	x.Landed = true
	Class.plant(p.Owner, p.Weapon, p.Pos)
end

-- A flying seed: the impact (Coeff, the first enemy it touches, primary) or a cliff lands it early.
function Class.stepSeed(p: Projectile, dt: number, now: number): boolean
	local before = p.Pos
	p.Pos += p.Vel * dt
	p.Yaw += dt * 10
	if Rk.terrainBlocked(p) then
		p.Pos = before
		Class.landSeed(p)
		return true
	end
	if collideEnemies(p, now) then
		Class.landSeed(p)
		return true
	end
	return false
end
Class.Expire.Seed = Class.landSeed

------------------------------------------------------------------------------------------
-- Returning Sneakers (Peter Parkour)
------------------------------------------------------------------------------------------

--[[
	A shoe out to Range and back to the thrower: Coeff to the first OutTargets enemies it touches on
	the way out (primary hits), ReturnCoeff to the first ReturnTargets on the way back (secondary);
	one hit per target per leg. Terrain ends the blocked leg (out: it turns back; back: it is gone).
	Stride (Peter's class passive): a stored charge makes this throw deal +30 %.
]]
function Fire.RankSneakers(rp, w, s, def)
	local spec = s.spec
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, spec.Range, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	local factor = 1
	local kits = ctx.ClassKits
	if Rk.own(rp, def) and kits then
		local bonus = kits.TakeStride(rp)
		if bonus then
			factor = WeaponSystem.KitDamageFactor(rp, bonus)
		end
	end
	local dir = flatDir(Rk.aimPoint(origin, target, spec.Speed) - origin, rp.Facing)
	local p = Rk.shot(rp, w, s, origin + dir * 1.5, dir, s.damage * factor, { Visual = visualByte(spec.Visual or 5, w) })
	if not p then
		return
	end
	local out = spec.Range / spec.Speed
	p.Kind = "Shoe"
	p.Life = out + (spec.ReturnMaxSeconds or 2.5) + 0.5
	p.X = {
		Leg = "Out",
		OutTime = out,
		BackAt = 0,
		MaxBack = spec.ReturnMaxSeconds or 2.5,
		Speed = spec.Speed,
		OutLeft = spec.OutTargets or 2,
		BackLeft = spec.ReturnTargets or 2,
		OutHits = {},
		BackHits = {},
		BackDamage = BuildRules.B() * (spec.ReturnCoeff or 0.35) * s.mult * factor,
		Stride = factor > 1,
	}
	Fx.Sound("Hit")
end

function Class.stepShoe(p: Projectile, dt: number, _now: number): boolean
	local owner = p.Owner
	local x = p.X
	if not owner or not owner.Alive or not owner.Root then
		return true
	end
	if x.Leg == "Out" then
		local before = p.Pos
		p.Pos += p.Vel * dt
		if Rk.terrainBlocked(p) then
			p.Pos = before -- a cliff ends the way out: the shoe turns back here
			x.Leg, x.BackAt = "Back", p.Age
		elseif p.Age >= x.OutTime then
			x.Leg, x.BackAt = "Back", p.Age
		end
	else
		local home = ground(owner.Root.Position)
		local to = (home - p.Pos) * FLAT
		local d = to.Magnitude
		if d <= 2.5 or p.Age - x.BackAt > x.MaxBack then
			return true -- caught (or lost)
		end
		p.Vel = to / d * x.Speed
		local before = p.Pos
		p.Pos += p.Vel * math.min(dt, d / x.Speed)
		if Rk.terrainBlocked(p) then
			p.Pos = before
			return true -- terrain ends the way back
		end
	end
	p.Yaw += dt * 15
	local out = x.Leg == "Out"
	if (out and x.OutLeft <= 0) or (not out and x.BackLeft <= 0) then
		return false
	end
	local n = grid():QueryCircle(p.Pos.X, p.Pos.Z, p.Radius, queryBuf)
	if n == 0 then
		return false
	end
	local list = table.move(queryBuf, 1, n, 1, {})
	local dir = (p.Vel * FLAT).Magnitude > 1e-3 and (p.Vel * FLAT).Unit or nil
	for _, e in ipairs(list) do
		if hittable(e) then
			if out and x.OutLeft > 0 and not x.OutHits[e.Uid] then
				x.OutHits[e.Uid] = true
				x.OutLeft -= 1
				damageEnemy(owner, e, p.Damage, dir, p.Knockback, false)
			elseif not out and x.BackLeft > 0 and not x.BackHits[e.Uid] then
				x.BackHits[e.Uid] = true
				x.BackLeft -= 1
				damageEnemy(owner, e, x.BackDamage, dir, p.Knockback * 0.5, true)
			end
		end
	end
	return false
end

------------------------------------------------------------------------------------------
-- Dodgeball, Ricochet Puck, Confetti Minigun
------------------------------------------------------------------------------------------

-- DODGEBALL: the rank shot (bounces to a different not-yet-hit visible target within 10 studs);
-- rank 5: a second ball SecondBall.Delay s later at Share damage (secondary: one budget token, no
-- bounce).
function Fire.RankDodgeball(rp, w, s, def)
	local spec = s.spec
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, spec.Range, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	Fire.RankShot(rp, w, s, def)
	local second = spec.SecondBall
	if not second then
		return
	end
	local uid = target.Uid
	task.delay(second.Delay, function()
		if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() or not Rk.tryEmit(rp) then
			return
		end
		local from = ground(rp.Root.Position)
		useGround(from.Y)
		local t = (target.Alive and target.Uid == uid) and target or WeaponSystem.NearestTarget(rp, spec.Range, { From = from })
		if t then
			local d = flatDir(Rk.aimPoint(from, t, spec.Speed) - from, rp.Facing)
			local q = Rk.shot(rp, w, s, from + d * 1.5, d, s.damage * second.Share, { Visual = visualByte(spec.Visual or 45, w), Secondary = true })
			if q then
				q.SecondBall = true
			end
		end
		useGround(nil)
	end)
end

-- RICOCHET PUCK: the rank shot (1 / 2 / 3 bounces to different not-yet-hit visible targets within 10).
function Fire.RankPuck(rp, w, s, def)
	Fire.RankShot(rp, w, s, def)
end

-- CONFETTI MINIGUN: Amount pellets (3 / 4 / 5) at one target in a small fixed fan (Spread degrees
-- apart): up close every pellet can hit the same enemy; far away the outer ones miss small targets.
-- Each pellet is a primary hit (its own hit ledger).
function Fire.RankConfetti(rp, w, s, _def)
	local spec = s.spec
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, spec.Range, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	local visual = visualByte(spec.Visual or 24, w)
	local dir = flatDir(Rk.aimPoint(origin, target, spec.Speed) - origin, rp.Facing)
	local n = s.amount
	for i = 1, n do
		local d = rotateY(dir, (i - (n + 1) / 2) * math.rad(spec.Spread or 4))
		if not Rk.shot(rp, w, s, origin + d * 1.5, d, s.damage, { Visual = visual }) then
			break
		end
	end
	Fx.Sound("Hit")
end

------------------------------------------------------------------------------------------
-- Protein Claws (Swolverine), Glove Combo (Knuckles McGee)
------------------------------------------------------------------------------------------

-- The nearest `maxTargets` hittable enemies in sight inside the forward sector (the RankSwing shape).
function Class.swingHits(at: Vector3, dir: Vector3, reach: number, half: number, maxTargets: number): { any }
	local g = grid()
	local saved, savedBand, savedGround = g.BandY, g.Band, curGround
	useGround(at.Y)
	local n = g:QueryCircle(at.X, at.Z, reach, queryBuf)
	local list = {}
	for i = 1, n do
		local e = queryBuf[i]
		if hittable(e) and inSwing(e, at, dir, reach, half) then
			table.insert(list, e)
		end
	end
	g.BandY, g.Band, curGround = saved, savedBand, savedGround
	table.sort(list, function(a, b)
		local da, db = ((a.Pos - at) * FLAT).Magnitude - a.Radius, ((b.Pos - at) * FLAT).Magnitude - b.Radius
		if da ~= db then
			return da < db
		end
		return a.Uid < b.Uid
	end)
	local out = {}
	for _, e in ipairs(list) do
		if #out >= maxTargets then
			break
		end
		if WeaponSystem.HasLineOfSight(at, e.Pos) then
			table.insert(out, e)
		end
	end
	return out
end

-- PROTEIN CLAWS: alternating forward swipes (no lunge) at the selected nearby enemy, MaxTargets
-- (3 / 4) nearest in the sector; rank 5: every ThirdPulse.Every-th swipe adds a pulse (Radius, Coeff;
-- secondary, one budget token) where the swipe landed.
function Fire.RankClaws(rp, w, s, _def)
	local spec = s.spec
	local reach = spec.Reach * s.area
	local half = math.rad(spec.Arc) / 2
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, reach, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	local dir = flatDir(target.Pos - origin, rp.Facing)
	w.Attacks = (w.Attacks or 0) + 1
	local attack = w.Attacks
	Fx.Slash(origin, yawOf(dir), reach, attack % 2 == 0 and -1 or 1, visualTier(w), rp.Player.UserId)
	local pulse = spec.ThirdPulse
	task.delay(SWING_HIT_DELAY, function()
		if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() then
			return
		end
		local at = ground(rp.Root.Position)
		local hits = Class.swingHits(at, dir, reach, half, spec.MaxTargets)
		killSource = w
		for _, e in ipairs(hits) do
			if e.Alive then
				hitEnemy(rp, e, s.damage, at, s.knockback)
			end
		end
		killSource = nil
		w.ClawHits = (w.ClawHits or 0) + #hits
		if pulse and attack % pulse.Every == 0 and Rk.tryEmit(rp) then
			local center = hits[1] and ground(hits[1].Pos) or ground(at + dir * math.min(reach, 7))
			WeaponSystem.KitBurst(rp, center, pulse.Radius * s.area, pulse.Coeff, w.Id, {})
			w.Pulses = (w.Pulses or 0) + 1
		end
	end)
	Fx.Sound("Hit")
end

--[[
	GLOVE COMBO: a punch at the nearest target within Reach (alternating hands). Each punch that
	lands adds one charge to the WEAPON (w.Charge, any holder); with ChargeAfter (5 / 4 / 3) charges
	the next punch is an uppercut instead: UppercutCoeff on the target (primary) plus a ShockRadius
	shockwave of ShockCoeff on up to ShockTargets other enemies (secondary, one budget token), and the
	charge is spent. A punch that misses (the target died first) adds nothing.
]]
function Fire.RankGlove(rp, w, s, _def)
	local spec = s.spec
	local reach = spec.Reach * s.area
	local origin = ground(rp.Root.Position)
	local target = WeaponSystem.NearestTarget(rp, reach, { Key = w.Id, From = origin })
	if not target then
		w.Timer = math.min(w.Timer, 0.15)
		return
	end
	local need = spec.ChargeAfter or 5
	w.Charge = math.min(w.Charge or 0, need)
	local upper = w.Charge >= need
	local dir = flatDir(target.Pos - origin, rp.Facing)
	w.Attacks = (w.Attacks or 0) + 1
	Fx.Slash(origin, yawOf(dir), math.min(reach, 6), w.Attacks % 2 == 0 and -1 or 1, upper and 3 or visualTier(w), rp.Player.UserId)
	local uid = target.Uid
	task.delay(SWING_HIT_DELAY, function()
		if not rp.Alive or not rp.Root or not ctx.RunManager.IsSimulating() then
			return
		end
		local t = target
		local at = ground(rp.Root.Position)
		if not (t.Alive and t.Uid == uid and hittable(t)) then
			return -- the punch whiffs
		end
		if ((t.Pos - at) * FLAT).Magnitude - t.Radius > reach + 1 or not WeaponSystem.HasLineOfSight(at, t.Pos) then
			return
		end
		killSource = w
		if upper and (w.Charge or 0) >= need then
			w.Charge = 0
			w.Uppercuts = (w.Uppercuts or 0) + 1
			hitEnemy(rp, t, BuildRules.B() * spec.UppercutCoeff * s.mult, at, s.knockback * 3)
			if Rk.tryEmit(rp) then
				WeaponSystem.KitBurst(rp, ground(t.Pos), spec.ShockRadius * s.area, spec.ShockCoeff, w.Id, { Max = spec.ShockTargets, Exclude = { [uid] = true }, Knock = 8 })
			end
			Fx.Explosion(t.Pos, spec.ShockRadius)
		else
			hitEnemy(rp, t, s.damage, at, s.knockback)
			w.Charge = math.min(need, (w.Charge or 0) + 1)
		end
		killSource = nil
	end)
	Fx.Sound("Hit")
end

-- Adds `n` charges to the hero's Glove Combo (Knuckles's close dodge), capped at its ChargeAfter.
-- Returns the charge and the charge needed (nil when the hero holds no Glove Combo).
function WeaponSystem.GloveCharge(rp, n: number): (number?, number?)
	local w = rp.Weapons and rp.Weapons.GloveCombo
	if not w then
		return nil, nil
	end
	local spec = WeaponData.RankSpec("GloveCombo", w.Evolved and BuildRules.MaxRank() or w.Level)
	local need = spec and spec.ChargeAfter or 5
	w.Charge = math.clamp((w.Charge or 0) + n, 0, need)
	return w.Charge, need
end

-- The projectile kinds above (Arm.Step: true = remove the projectile).
Arm.Step.Shoe = Class.stepShoe
Arm.Step.Seed = Class.stepSeed
Arm.Step.Plant = Class.stepPlant
Arm.Step.Balloon = Class.stepBalloon

-- A projectile of the batch reached its Life: true = it keeps going (a saw's rebound).
function Arm.expire(p: Projectile): boolean
	local kind = p.Kind
	local classExpire = Class.Expire[kind] -- [stream C] seeds, balloons
	if classExpire then
		classExpire(p)
		return false
	end
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
	elseif kind == "Yarn" then
		Class.landYarn(p)
	elseif kind == "Can" then
		Class.popCan(p)
	elseif kind == "RBubble" then
		Rk.popBubble(p)
	end
	return false
end

local function stepProjectile(p: Projectile, dt: number, now: number): boolean -- true = remove
	if p.Cancelled then
		return true
	end
	-- [stream H] a straight shot is tested where it appears before its first move: an enemy
	-- already touching the hero (inside the 1.5-stud muzzle offset plus one frame's travel)
	-- was skipped and point-blank shots never hit it (pacing-sim; worse on a slow frame)
	if p.Age == 0 and p.Kind == "Straight" and not p.Hostile and collideEnemies(p, now) then
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
				Pos = ground(p.Pos),
				Radius = p.PoolRadius,
				Life = p.PoolLife,
				Tick = p.PoolTick,
				Timer = 0,
				Damage = p.Damage,
				Owner = p.Owner,
				Weapon = p.Weapon, -- overlapping pools of one weapon hurt once per tick
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
			if not chaseable(t, p.TargetUid) or p.Age > p.OutLimit then
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
		if not (chaseable(t, p.TargetUid) and p.Hits[(t :: any).Uid] == nil) then
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
		if (t ~= nil or p.Seeking) and not chaseable(t, p.TargetUid) then
			-- the target left the grid (a burrowed / rising boss): pick the nearest enemy
			-- still in the grid (looked for every 0.2 s), else fly straight on until the
			-- shot's life runs out. A target that died: straight on, as always.
			local left = t ~= nil and t.Alive and t.Uid == p.TargetUid
			t = nil
			p.Target = nil
			p.TargetUid = nil
			p.Seeking = p.Seeking or left
			if p.Seeking and now >= (p.SeekAt or 0) then
				p.SeekAt = now + 0.2
				t = grid():Nearest(p.Pos.X, p.Pos.Z, 30, skipDead)
				if t then
					p.Target = t
					p.TargetUid = t.Uid
					p.Seeking = nil
				end
			end
		end
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
		p.Y = math.max(p.Ground + 0.5, p.Y + p.VY * dt)
		p.Yaw += dt * 12
	elseif kind == "Lob" then
		p.Pos += p.Vel * dt
		p.VY -= p.Gravity * dt
		p.Y = math.max((p.Floor or p.Ground) + 0.5, p.Y + p.VY * dt)
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

	if p.Terrain and Rk.terrainBlocked(p) then
		return true -- [stream B] a cliff ends a rank shot (no attacks through terrain)
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
	local now = ctx.RunManager.GetRunTime()
	for i = #zones, 1, -1 do
		local z = zones[i]
		z.Life -= dt
		z.Timer -= dt
		if z.Timer <= 0 then
			z.Timer = z.Tick
			useGround(z.Pos.Y)
			local n = grid():QueryCircle(z.Pos.X, z.Pos.Z, z.Radius, queryBuf)
			local hits = table.move(queryBuf, 1, n, 1, {})
			for _, e in ipairs(hits) do
				-- overlapping pools / craters of one weapon hurt an enemy once per tick
				-- (four bottles on one clump used to deal four times the damage)
				if e.Alive and (not z.Weapon or burnReady(z.Weapon, e, z.Tick, now)) then
					killSource = z.Weapon
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
			-- the Signature upgrade raises the Longbow bonus; other weapons scale with it
			local bonus = traitValue(rp, trait.Damage)
			rp.SteadyAimBonus = bonus
			rp.SteadyAimOther = (trait.OtherDamage or trait.Damage) * bonus / trait.Damage
			rp.Player:SetAttribute("SteadyAimBonus", bonus) -- the HUD chip's numbers (before SteadyAim flips)
			setSteadyAim(rp, true)
		end
	end
end

WeaponSystem._UpdateSteadyAim = updateSteadyAim -- (tests)

--[[
	Feature hook (docs/features/EXPLORE.md): fn(rp, w, stats) runs after every weapon
	attack a player makes (stats = WeaponStats: damage, amount, area ...). Listeners must
	be cheap and must not error (the fire loop does not pcall them); SecretRoom wraps its
	own in pcall. No listeners = nothing changes.
]]
local fireListeners: { (any, any, any) -> () } = {}
function WeaponSystem.OnFired(fn: (any, any, any) -> ())
	table.insert(fireListeners, fn)
end

--[[
	Kill hook: fn(rp, w, enemy) runs when a weapon hit kills an enemy, with the weapon
	(w.Id) that dealt it (weapon mastery, feature 15). Item procs and kills with no weapon
	behind them are not reported. Listeners must be cheap and never change the fight.
]]
function WeaponSystem.OnKill(fn: (any, any, any) -> ())
	table.insert(killListeners, fn)
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
				local rpos = rp.Root.Position
				useGround(HeightGrid.GroundY(rpos.X, rpos.Z))
				for _, id in ipairs(rp.WeaponOrder) do
					local w = rp.Weapons[id]
					w.Timer -= dt
					if w.Timer <= 0 then
						local def = WeaponData.Weapons[id]
						local s = weaponStats(rp, w)
						-- carry the time past zero into the next cooldown so attacks keep
						-- their exact cadence (owner OK 2026-10-05, audit MATH-13); the carry
						-- is capped at one cooldown, so a long hitch gives at most one extra
						-- attack (on the next frame), never a burst, and still one per frame
						w.Timer = s.cooldown - math.min(-w.Timer, s.cooldown)
						-- Spare Quiver (per weapon); turrets / totems never pass their cap
						s.amount = WeaponData.CapAmount(id, s.amount + ctx.ItemSystem.ExtraShot(rp, w))
						local fn = Fire[WeaponData.BehaviorOf(id)] -- [stream B] rank behaviours while ranked
						killSource = w
						if fn then
							fn(rp, w, s, def)
						end
						-- feature hook (WeaponSystem.OnFired): e.g. the secret-room wall
						for _, listener in ipairs(fireListeners) do
							listener(rp, w, s)
						end
					end
				end
			end
		end
		-- 2) simulate projectiles (iterate backwards: freeing swap-removes)
		for i = #live, 1, -1 do
			local p = live[i]
			killSource = p and p.Weapon
			if p and p.Active then
				useGround(p.Ground)
			end
			if p and p.Active and stepProjectile(p, dt, now) then
				freeProjectile(p)
			end
		end
		-- 3) pools, Fire Trail patches and ignites
		stepZones(dt)
		stepPatches(dt, now)
		-- 4) [stream B] rank system: vortex pulls, old cast ledgers
		Rk.step(dt, now)
		killSource = nil
		useGround(nil)
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
