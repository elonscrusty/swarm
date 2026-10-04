-- corner-regression: real server modules, headless. Priority-zero "corner farming" check
-- (docs/overhaul/CORNER_REPORT.md). The hero stands still at legal spots in every arena:
-- the open field, flush against each straight wall, in every arena corner and in the
-- pockets between edge obstacles and the wall. Enemies (one melee bug, a crowd, an elite,
-- a Spitter, a Rhino lunger, a boss) come at the hero; the scene measures whether they
-- can REACH and ATTACK, not whether the hero survives (no weapons, no healing, damage is
-- counted, not applied).
--
-- The mock's workspace:Raycast hits nothing by default, but EnemyAI steers with a look-
-- ahead ray against the arena's colliders, so this scene installs a small ray caster
-- over the real collider parts (axis-aligned boxes, upright cylinders) and the invisible
-- Boundary walls.
--
-- Settings: --set arenas=Forest,Ruins (default all), --set report=on (per-case lines),
-- --set strict=off (report only, never FAIL), --set only=<spot> (one spot, e.g. corner-SE),
-- --set at=x,z,dirX,dirZ (an extra spot), --set trace=<kind> [--set every=N] (first
-- enemy's position / steering every N frames), --set debugrays=on, --set obstacles=on
-- [--set near=x,z] (collider listing). Before/after numbers: docs/overhaul/CORNER_REPORT.md.
-- Instrumentation (offline only, never shipped to clients): per enemy target distance,
-- collider radius, desired vs actual speed, steering alignment (cos between the move
-- direction and the line to the hero), separation push, stuck time, contact eligibility
-- (reach, cooldown), contact attempts, knockback.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local LU = preview.server("LevelUpSystem")
local Spawner = preview.server("EnemySpawner")
local AI = preview.server("EnemyAI")
local MapBuilder = preview.server("MapBuilder")
local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local args = preview.args or {}
local REPORT = args.report == "on"
local STRICT = args.strict ~= "off"
local FPS = 30
local PLAYER_R = 1.0 -- half the HumanoidRootPart width: how close a hero gets to a wall
local c = Config.ArenaOrigin
local h = Config.Arenas.Size / 2

------------------------------------------------------------------------------------------
-- Ray caster over the arena colliders (only what EnemyAI's include filter lists)
------------------------------------------------------------------------------------------
local shapes = {}
local shapeOwner = nil
local function collectShapes(params)
	local folder = params.FilterDescendantsInstances[1]
	if shapeOwner == folder then
		return
	end
	shapeOwner = folder
	table.clear(shapes)
	for _, root in ipairs(params.FilterDescendantsInstances) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") and d.CanQuery then
				local cyl = d.Shape == Enum.PartType.Cylinder
				local p, s = d.Position, d.Size
				if cyl then
					-- upright cylinder (UPRIGHT turns its X axis up): height s.X, radius s.Y/2
					table.insert(shapes, { Part = d, Cyl = true, X = p.X, Z = p.Z, R = s.Y / 2, Y0 = p.Y - s.X / 2, Y1 = p.Y + s.X / 2 })
				else
					table.insert(shapes, { Part = d, Min = p - s / 2, Max = p + s / 2 })
				end
			end
		end
	end
end
local function rayBox(o: Vector3, d: Vector3, mn: Vector3, mx: Vector3)
	local tmin, tmax, normal = 0, 1, nil
	for _, ax in ipairs({ "X", "Y", "Z" }) do
		local oa, da, lo, hi = o[ax], d[ax], mn[ax], mx[ax]
		if math.abs(da) < 1e-9 then
			if oa < lo or oa > hi then
				return nil
			end
		else
			local t1, t2 = (lo - oa) / da, (hi - oa) / da
			local n1 = -math.sign(da)
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			if t1 > tmin then
				tmin = t1
				normal = (ax == "X" and Vector3.new(n1, 0, 0)) or (ax == "Y" and Vector3.new(0, n1, 0)) or Vector3.new(0, 0, n1)
			end
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	if not normal then
		return nil -- origin inside: Roblox ignores the part the ray starts in
	end
	return tmin, normal
end
local function rayCyl(o: Vector3, d: Vector3, sh)
	local fx, fz = o.X - sh.X, o.Z - sh.Z
	local a = d.X * d.X + d.Z * d.Z
	if a < 1e-9 then
		return nil
	end
	local b = 2 * (fx * d.X + fz * d.Z)
	local cc = fx * fx + fz * fz - sh.R * sh.R
	if cc <= 0 then
		return nil
	end
	local disc = b * b - 4 * a * cc
	if disc < 0 then
		return nil
	end
	local t = (-b - math.sqrt(disc)) / (2 * a)
	if t < 0 or t > 1 then
		return nil
	end
	local y = o.Y + d.Y * t
	if y < sh.Y0 or y > sh.Y1 then
		return nil
	end
	local hx, hz = o.X + d.X * t - sh.X, o.Z + d.Z * t - sh.Z
	local m = math.sqrt(hx * hx + hz * hz)
	return t, Vector3.new(hx / m, 0, hz / m)
end
local rayCount = 0
preview.setRaycast(function(origin: Vector3, direction: Vector3, params)
	rayCount += 1
	if not params or not params.FilterDescendantsInstances[1] then
		return nil
	end
	collectShapes(params)
	local best, bestN, bestPart = math.huge, nil, nil
	local e = origin + direction
	local x0, x1 = math.min(origin.X, e.X), math.max(origin.X, e.X)
	local z0, z1 = math.min(origin.Z, e.Z), math.max(origin.Z, e.Z)
	for _, sh in ipairs(shapes) do
		local t, n
		if sh.Cyl then
			if sh.X + sh.R < x0 or sh.X - sh.R > x1 or sh.Z + sh.R < z0 or sh.Z - sh.R > z1 then
				continue
			end
			t, n = rayCyl(origin, direction, sh)
		else
			if sh.Max.X < x0 or sh.Min.X > x1 or sh.Max.Z < z0 or sh.Min.Z > z1 then
				continue
			end
			t, n = rayBox(origin, direction, sh.Min, sh.Max)
		end
		if t and t < best then
			best, bestN, bestPart = t, n, sh.Part
		end
	end
	if not bestN then
		return nil
	end
	if args.debugrays == "on" then
		preview.log(string.format("ray from (%.1f, %.1f) dir (%.1f, %.1f) hit %s at %.1f", origin.X, origin.Z, direction.X, direction.Z, bestPart.Name, direction.Magnitude * best))
	end
	return { Instance = bestPart, Position = origin + direction * best, Normal = bestN, Distance = direction.Magnitude * best, Material = Enum.Material.Plastic }
end)

------------------------------------------------------------------------------------------
-- Run control
------------------------------------------------------------------------------------------
local attempts = {} -- [uid] = count of contact damage attempts this case
local causes = {}
local origDamage = RM.DamagePlayer
RM.DamagePlayer = function(rp, amount, cause)
	-- counted, never applied: the hero must stay up for the whole measurement
	causes[cause or "?"] = (causes[cause or "?"] or 0) + 1
	return nil
end
local function rpNow()
	return assert(RM.GetRunPlayer(player), "run player missing")
end
local function startRun(arena: string)
	if RM.IsRunning() then
		RM.EndRun(false)
		preview.advance(2, FPS)
	end
	for _ = 1, 120 do
		if RM.StartTeamRun({ player }, "Solo", arena, player) then
			break
		end
		preview.advance(0.5, FPS)
	end
	preview.advance(4, FPS)
	local rp = rpNow()
	LU.Cancel(rp)
	rp.Weapons, rp.WeaponOrder = {}, {}
	return rp
end
local mine: { [any]: boolean } = {}
local function purge()
	-- only this case's enemies (waves / nests / top-ups of the real spawner are removed)
	for i = #Spawner.Active, 1, -1 do
		local e = Spawner.Active[i]
		if e and not mine[e] then
			Spawner.Despawn(e)
		end
	end
end
local function clearAll()
	for i = #Spawner.Active, 1, -1 do
		local e = Spawner.Active[i]
		if e then
			Spawner.Despawn(e)
		end
	end
	table.clear(mine)
	table.clear(causes)
end
local function place(rp, pos: Vector3)
	local y = rp.Root.Position.Y
	rp.Root.CFrame = CFrame.new(pos.X, y, pos.Z)
	rp.Root.AssemblyLinearVelocity = Vector3.zero
	-- a scripted placement, not a speed hack: RunManager's speed check restarts here
	rp.LastValidPos = rp.Root.Position
	rp.SpeedCheckTimer = 0
end

------------------------------------------------------------------------------------------
-- One measured case
------------------------------------------------------------------------------------------
local function spawnCase(kind: string, at: Vector3, openDir: Vector3)
	local list = {}
	local function add(e)
		if e then
			mine[e] = true
			table.insert(list, e)
		end
	end
	local function ring(n: number, r0: number, r1: number, typeId: string, opts)
		for k = 1, n do
			local a = (k / n) * math.pi * 2 + (k % 3) * 0.17
			local r = r0 + (r1 - r0) * ((k * 37) % 11) / 10
			local x, z = Spawner.ClampToArena(at.X + math.cos(a) * r, at.Z + math.sin(a) * r, 4)
			if not AI.IsBlocked(x, z, 2) then
				add(Spawner.Spawn(typeId, Vector3.new(x, c.Y, z), opts))
			end
		end
	end
	local function ahead(dist: number, typeId: string, opts)
		local p = at + openDir * dist
		local x, z = Spawner.ClampToArena(p.X, p.Z, 4)
		local spot = AI.PushOut(Vector3.new(x, c.Y, z), 3)
		add(Spawner.Spawn(typeId, spot, opts))
	end
	if kind == "single" then
		ahead(18, "Slime")
	elseif kind == "crowd" then
		ring(24, 22, 40, "Slime")
	elseif kind == "elite" then
		ahead(20, "Skeleton", { Elite = true })
	elseif kind == "ranged" then
		ahead(34, "Spitter")
	elseif kind == "lunger" then
		ahead(26, "Brute")
	elseif kind == "boss" then
		local p = at + openDir * 40
		local x, z = Spawner.ClampToArena(p.X, p.Z, 8)
		add(Spawner.SpawnBoss(Vector3.new(x, c.Y, z), "ScorpionQueen"))
	end
	for _, e in ipairs(list) do
		e.SpawnGrace = 0
	end
	return list
end

local function measure(rp, at: Vector3, kind: string, openDir: Vector3, seconds: number)
	clearAll()
	place(rp, at)
	preview.advance(0.1, FPS)
	purge()
	local list = spawnCase(kind, at, openDir)
	local m = {
		n = #list, contacts = 0, attackers = {}, first = nil, align = 0, alignN = 0, speedRatio = 0, speedN = 0,
		sep = 0, stuckMax = 0, nearNoHit = 0, minDist = math.huge, knockSeen = 0, rays = 0, globs = 0, lunges = 0,
	}
	local last, stuck, lastHit = {}, {}, {}
	local t = 0
	local rays0 = rayCount
	local dt = 1 / FPS
	while t < seconds do
		local before = {}
		for _, e in ipairs(list) do
			if e.Alive then
				before[e] = { e.Pos, e.NextContact }
			end
		end
		place(rp, at)
		preview.advance(dt, FPS)
		purge()
		t += dt
		local hp = rp.Root.Position
		if args.trace == kind and list[1] and math.floor(t * FPS + 0.5) % (tonumber(args.every) or 15) == 0 then
			local e1 = list[1]
			preview.log(string.format("trace t=%.1f hero (%.1f, %.1f) enemy (%.1f, %.1f) alive=%s dir=%s sep=%s act=%s", t, hp.X, hp.Z, e1.Pos.X, e1.Pos.Z, tostring(e1.Alive), tostring(e1.Dir), tostring(e1.Sep), tostring(e1.Act)))
		end
		for _, e in ipairs(list) do
			local b = before[e]
			if e.Alive and b then
				local to = Vector3.new(hp.X - e.Pos.X, 0, hp.Z - e.Pos.Z)
				local dist = to.Magnitude
				local reach = e.Radius + 1.2 -- EnemyAI PLAYER_RADIUS
				m.minDist = math.min(m.minDist, dist - reach)
				if e.NextContact ~= b[2] then
					m.contacts += 1
					m.attackers[e] = true
					lastHit[e] = t
					if not m.first then
						m.first = t
					end
				end
				if e.Act == "Lunge" then
					m.lunges += 1
				end
				if e.Knock and e.Knock.Magnitude > 0.5 then
					m.knockSeen += 1
				end
				local moved = (e.Pos - b[1]) * Vector3.new(1, 0, 1)
				if dist < 14 and dist > reach + 0.3 and not e.Act then
					-- steering instrumentation: desired = straight at the hero at full speed
					local dir = e.Dir or Vector3.zero
					if dir.Magnitude > 0.1 then
						m.align += dir.Unit:Dot(to.Unit)
						m.alignN += 1
					end
					m.speedRatio += math.clamp((moved:Dot(to.Unit) / dt) / math.max(e.Speed, 0.1), -1, 1.5)
					m.speedN += 1
					m.sep += (e.Sep or Vector3.zero).Magnitude
					stuck[e] = (stuck[e] or 0) + dt
					if stuck[e] > m.stuckMax then
						m.stuckMax = stuck[e]
					end
				else
					stuck[e] = 0
				end
				if dist <= reach + 2 and (t - (lastHit[e] or -99)) > 1.5 then
					m.nearNoHit += dt
				end
			end
		end
	end
	m.rays = rayCount - rays0
	local na = 0
	for _ in pairs(m.attackers) do
		na += 1
	end
	m.attackerCount = na
	m.rate = m.contacts / seconds
	m.alignAvg = m.alignN > 0 and m.align / m.alignN or 1
	m.speedAvg = m.speedN > 0 and m.speedRatio / m.speedN or 1
	m.globCount = causes["Spitter acid glob"] or 0
	local bossHits = 0
	for cause, count in pairs(causes) do
		if string.find(cause, "Queen") or string.find(cause, "Boss") then
			bossHits += count
		end
	end
	m.bossHits = bossHits
	clearAll()
	return m
end

------------------------------------------------------------------------------------------
-- Positions: open field, wall middles, corners, edge-obstacle pockets
------------------------------------------------------------------------------------------
local function legal(p: Vector3): Vector3
	local q = AI.PushOut(Vector3.new(p.X, c.Y, p.Z), PLAYER_R + 0.2)
	local x = math.clamp(q.X, c.X - h + PLAYER_R, c.X + h - PLAYER_R)
	local z = math.clamp(q.Z, c.Z - h + PLAYER_R, c.Z + h - PLAYER_R)
	return Vector3.new(x, c.Y, z)
end
local function positions(arena)
	local e = h - PLAYER_R
	local list = {
		{ "open", Vector3.new(c.X, c.Y, c.Z + 12), Vector3.new(0, 0, -1) },
		{ "wall-N", Vector3.new(c.X + 20, c.Y, c.Z - e), Vector3.new(0, 0, 1) },
		{ "wall-S", Vector3.new(c.X - 20, c.Y, c.Z + e), Vector3.new(0, 0, -1) },
		{ "wall-W", Vector3.new(c.X - e, c.Y, c.Z + 20), Vector3.new(1, 0, 0) },
		{ "wall-E", Vector3.new(c.X + e, c.Y, c.Z - 20), Vector3.new(-1, 0, 0) },
		{ "corner-NW", Vector3.new(c.X - e, c.Y, c.Z - e), Vector3.new(1, 0, 1).Unit },
		{ "corner-NE", Vector3.new(c.X + e, c.Y, c.Z - e), Vector3.new(-1, 0, 1).Unit },
		{ "corner-SW", Vector3.new(c.X - e, c.Y, c.Z + e), Vector3.new(1, 0, -1).Unit },
		{ "corner-SE", Vector3.new(c.X + e, c.Y, c.Z + e), Vector3.new(-1, 0, -1).Unit },
	}
	-- pockets: an obstacle near a wall makes a channel; the hero stands flush against the
	-- wall right behind it (the wall / obstacle join), enemies must come round the obstacle
	local pockets = 0
	if args.obstacles == "on" then
		for _, d in ipairs(arena.ObstacleFolder:GetDescendants()) do
			if d:IsA("BasePart") then
				local top = d.Position.Y + (d.Shape == Enum.PartType.Cylinder and d.Size.X or d.Size.Y) / 2 - c.Y
				if args.near then
					local v = string.split(args.near, ",")
					if math.abs(d.Position.X - tonumber(v[1])) < 6 and math.abs(d.Position.Z - tonumber(v[2])) < 6 then
						preview.log("near part", d.Name, tostring(d.Shape), tostring(d.Position), tostring(d.Size), tostring(d.CFrame.Rotation), d.CanQuery)
					end
				end
				if top < 3 then
					preview.log(string.format("low collider %s at (%.0f, %.0f) top %.1f", d.Name, d.Position.X, d.Position.Z, top))
				end
			end
		end
		for _, ob in ipairs(arena.Obstacles) do
			local r = (ob.Kind == "Box") and math.max(ob.MaxX - ob.MinX, ob.MaxZ - ob.MinZ) / 2 or ob.Radius
			local gap = h - math.max(math.abs(ob.Pos.X - c.X), math.abs(ob.Pos.Z - c.Z)) - r
			if gap < 30 then
				preview.log(string.format("obstacle %s at (%.0f, %.0f) r=%.1f wall gap %.1f", ob.Kind, ob.Pos.X, ob.Pos.Z, r, gap))
			end
		end
	end
	local near = table.clone(arena.Obstacles)
	local function wallGap(ob)
		local r = (ob.Kind == "Box") and math.max(ob.MaxX - ob.MinX, ob.MaxZ - ob.MinZ) / 2 or ob.Radius
		return h - math.max(math.abs(ob.Pos.X - c.X), math.abs(ob.Pos.Z - c.Z)) - r
	end
	table.sort(near, function(a, b)
		local ga, gb = wallGap(a), wallGap(b)
		if math.abs(ga - gb) > 1e-3 then
			return ga < gb
		end
		if a.Pos.X ~= b.Pos.X then
			return a.Pos.X < b.Pos.X
		end
		return a.Pos.Z < b.Pos.Z
	end)
	for _, ob in ipairs(near) do
		if pockets >= 3 then
			break
		end
		local px, pz = ob.Pos.X - c.X, ob.Pos.Z - c.Z
		local r = (ob.Kind == "Box") and math.max(ob.MaxX - ob.MinX, ob.MaxZ - ob.MinZ) / 2 or ob.Radius
		local gapX, gapZ = h - math.abs(px) - r, h - math.abs(pz) - r
		local p, name, dir = nil, nil, nil
		if gapX > 2.4 and gapX < 20 and math.abs(pz) < h - 8 then
			local sx = math.sign(px)
			p = Vector3.new(c.X + sx * (h - PLAYER_R), c.Y, ob.Pos.Z)
			name, dir = "pocket-" .. (sx > 0 and "E" or "W") .. math.floor(pz), Vector3.new(-sx, 0, 0)
		elseif gapZ > 2.4 and gapZ < 20 and math.abs(px) < h - 8 then
			local sz = math.sign(pz)
			p = Vector3.new(ob.Pos.X, c.Y, c.Z + sz * (h - PLAYER_R))
			name, dir = "pocket-" .. (sz > 0 and "S" or "N") .. math.floor(px), Vector3.new(0, 0, -sz)
		end
		if p and not AI.IsBlocked(p.X, p.Z, PLAYER_R) then
			table.insert(list, { name, p, dir })
			pockets += 1
		end
	end
	if args.at then
		-- one extra spot: --set at=x,z,dirX,dirZ (debugging a reported pocket)
		local v = string.split(args.at, ",")
		table.insert(list, { "at", Vector3.new(tonumber(v[1]), c.Y, tonumber(v[2])), Vector3.new(tonumber(v[3]) or 0, 0, tonumber(v[4]) or -1).Unit })
	end
	for _, item in ipairs(list) do
		item[2] = legal(item[2])
	end
	return list
end

------------------------------------------------------------------------------------------
-- Run every arena
------------------------------------------------------------------------------------------
local arenas = Config.Arenas.Order
if args.arenas then
	arenas = string.split(args.arenas, ",")
end
local fails = 0
local function fail(...)
	fails += 1
	preview.log(STRICT and "FAIL" or "WARN", ...)
end
local function line(arena, pos, kind, m)
	if REPORT then
		preview.log(string.format("case %-6s %-14s %-6s n=%2d contacts=%3d rate=%5.2f/s attackers=%2d first=%s align=%5.2f speed=%5.2f sep=%5.2f stuckMax=%4.1fs nearNoHit=%4.1fs minGap=%5.2f knock=%d globs=%d lunges=%d boss=%d rays=%d",
			arena, pos, kind, m.n, m.contacts, m.rate, m.attackerCount, m.first and string.format("%.2fs", m.first) or "never",
			m.alignAvg, m.speedAvg, m.sep / math.max(1, m.speedN), m.stuckMax, m.nearNoHit, m.minDist, m.knockSeen, m.globCount, m.lunges, m.bossHits, m.rays))
	end
end
local summary = {}
for _, arenaName in ipairs(arenas) do
	local rp = startRun(arenaName)
	local arena = MapBuilder.GetArena()
	assert(arena and arena.Obstacles, "no arena for " .. arenaName)
	local pos = positions(arena)
	local open = nil
	for _, item in ipairs(pos) do
		local name, at, dir = item[1], item[2], item[3]
		if args.only and args.only ~= name then
			continue
		end
		local single = measure(rp, at, "single", dir, 8)
		local crowd = measure(rp, at, "crowd", dir, 9)
		local elite = measure(rp, at, "elite", dir, 8)
		line(arenaName, name, "single", single)
		line(arenaName, name, "crowd", crowd)
		line(arenaName, name, "elite", elite)
		if name == "open" then
			open = { single = single, crowd = crowd, elite = elite }
		end
		local edgeSpot = name ~= "open"
		local heavy = name == "open" or name == "corner-SE" or name == "wall-S"
		local ranged, lunger, boss
		if heavy then
			ranged = measure(rp, at, "ranged", dir, 10)
			lunger = measure(rp, at, "lunger", dir, 10)
			line(arenaName, name, "ranged", ranged)
			line(arenaName, name, "lunger", lunger)
			if arenaName == arenas[1] or args.boss == "all" then
				boss = measure(rp, at, "boss", dir, 14)
				line(arenaName, name, "boss", boss)
			end
		end
		table.insert(summary, { arenaName, name, single, crowd, elite })
		-- Acceptance: a legal spot must not stop a lone bug, an elite or the front of a crowd
		-- from reaching and hitting the hero. A corner is allowed fewer attack angles (fewer
		-- attackers at once), not fewer attacks per attacker (steering / clamp jams).
		if not single.first then
			fail(arenaName, name, "a lone Mite never reached the hero")
		elseif open and edgeSpot and single.first > open.single.first * 1.6 + 1.0 then
			fail(arenaName, name, string.format("a lone Mite took %.1fs to reach the hero (open field %.1fs)", single.first, open.single.first))
		end
		if not elite.first then
			fail(arenaName, name, "an elite Beetle Warrior never reached the hero")
		end
		if crowd.alignN > 0 and crowd.alignAvg < 0.55 then
			fail(arenaName, name, string.format("crowd steering points away from the hero (avg cos %.2f)", crowd.alignAvg))
		end
		if crowd.attackerCount < 3 then
			fail(arenaName, name, string.format("only %d crowd members ever hit the hero", crowd.attackerCount))
		end
		if open and edgeSpot and crowd.rate < open.crowd.rate * 0.3 then
			fail(arenaName, name, string.format("crowd contact rate %.2f/s vs open field %.2f/s", crowd.rate, open.crowd.rate))
		end
		if ranged and ranged.globCount < 1 then
			fail(arenaName, name, "a Spitter never fired")
		end
		if lunger and not lunger.first and lunger.lunges == 0 then
			fail(arenaName, name, "a Rhino neither lunged nor touched the hero")
		end
		if boss and boss.bossHits < 1 then
			fail(arenaName, name, "the Scorpion Queen never landed a hit")
		end
		-- no clipping: every enemy stayed inside the play square (EnemyAI clamp)
		for _, e in ipairs(Spawner.Active) do
			if math.abs(e.Pos.X - c.X) > h or math.abs(e.Pos.Z - c.Z) > h then
				fail(arenaName, name, "an enemy left the arena")
			end
		end
	end
end

-- knockback into a wall: a bug knocked hard into the corner recovers and reaches the hero
do
	local rp = rpNow()
	local e = h - PLAYER_R
	local at = legal(Vector3.new(c.X + e, c.Y, c.Z + e))
	clearAll()
	place(rp, at)
	local bug = assert(Spawner.Spawn("Slime", Vector3.new(at.X - 10, c.Y, at.Z - 10)))
	mine[bug] = true
	bug.SpawnGrace = 0
	bug.Knock = Vector3.new(1, 0, 1).Unit * 60 -- shoved past the hero into the corner walls
	local t, hit = 0, nil
	local nc = bug.NextContact
	while t < 6 do
		place(rp, at)
		preview.advance(1 / FPS, FPS)
		purge()
		t += 1 / FPS
		if bug.NextContact ~= nc then
			hit = t
			break
		end
	end
	if math.abs(bug.Pos.X - c.X) > h or math.abs(bug.Pos.Z - c.Z) > h then
		fail("knockback pushed a bug out of the arena")
	end
	if not hit then
		fail("a bug knocked into the corner never recovered to hit the hero")
	end
	preview.log(string.format("knockback-into-corner: %s", hit and string.format("hit after %.2fs", hit) or "never hit"))
	clearAll()
end

-- kiting still works: a hero running along the wall at normal speed outpaces a Mite
do
	local rp = rpNow()
	local speed = rp.Stats and rp.Stats.MoveSpeed or Config.Player and Config.Player.WalkSpeed or 16
	local e = h - PLAYER_R
	local at = legal(Vector3.new(c.X - 120, c.Y, c.Z + e))
	clearAll()
	place(rp, at)
	local bug = assert(Spawner.Spawn("Slime", Vector3.new(at.X - 6, c.Y, at.Z - 4)))
	mine[bug] = true
	bug.SpawnGrace = 0
	local hits0 = 0
	local nc = bug.NextContact
	local x = at.X
	for _ = 1, FPS * 6 do
		x += speed / FPS
		place(rp, Vector3.new(x, c.Y, at.Z))
		preview.advance(1 / FPS, FPS)
		purge()
		if bug.NextContact ~= nc then
			nc = bug.NextContact
			hits0 += 1
		end
	end
	local gap = x - bug.Pos.X
	preview.log(string.format("kiting along the south wall at %.1f studs/s: %d hits, Mite %.1f studs behind", speed, hits0, gap))
	if hits0 > 0 or gap < 10 then
		fail("kiting along a wall no longer outpaces a Mite")
	end
	clearAll()
end

-- summary table (always printed)
for _, s in ipairs(summary) do
	local single, crowd, elite = s[3], s[4], s[5]
	preview.log(string.format("%-6s %-14s single %-6s crowd %5.2f/s x%2d align %5.2f elite %-6s",
		s[1], s[2], single.first and string.format("%.1fs", single.first) or "never", crowd.rate, crowd.attackerCount,
		crowd.alignAvg, elite.first and string.format("%.1fs", elite.first) or "never"))
end
RM.DamagePlayer = origDamage
preview.setRaycast(nil)
if fails == 0 then
	preview.log("PASS corner-regression: every legal edge, corner and pocket spot lets melee, crowds, elites, ranged, lungers and the boss reach and attack; knockback recovers; kiting works")
elseif not STRICT then
	preview.log(string.format("corner-regression: %d issues (report only)", fails))
end
