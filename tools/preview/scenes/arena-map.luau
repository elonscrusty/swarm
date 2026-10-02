-- arena-map: top-down orthographic view of an arena (--set arena=Ruins) with the obstacle
-- shapes (arena.Obstacles) in red, the spawn clear radius and the 40 / 100 / 200 stud
-- rings, plus layout metrics (deterministic for a seed; --set runs=N adds the spread over
-- N consecutive builds, like N server starts):
--   obstacle count, blocked area (union) and % of the 400x400 play square, open area,
--   obstacles / blocked area per ring, part / MeshPart / light / shadow-caster counts,
--   triangle estimate, instance counts.
local C = lib("common")
local arenaName = preview.args.arena or "Forest"
local runs = tonumber(preview.args.runs) or 1
local s = C.bootServer()
if not s.MapBuilder or not s.Config then
	return
end
local Config = s.Config
local SIZE = Config.Arenas.Size
local HALF = SIZE / 2
local CELL = 0.5
local RINGS = { { 0, 40 }, { 40, 100 }, { 100, 200 }, { 200, math.huge } }

local function measure(arena)
	local c = arena.Center
	local n = math.floor(SIZE / CELL)
	local blocked = {} -- set of cell indices
	local function mark(ix, iz)
		if ix >= 0 and ix < n and iz >= 0 and iz < n then
			blocked[ix * n + iz] = true
		end
	end
	local kinds = { Circle = 0, Box = 0 }
	local ringCount = { 0, 0, 0, 0 }
	for _, ob in ipairs(arena.Obstacles) do
		kinds[ob.Kind] = (kinds[ob.Kind] or 0) + 1
		local d = math.sqrt((ob.Pos.X - c.X) ^ 2 + (ob.Pos.Z - c.Z) ^ 2)
		for i, r in ipairs(RINGS) do
			if d >= r[1] and d < r[2] then
				ringCount[i] += 1
			end
		end
		local minX, maxX, minZ, maxZ
		if ob.Kind == "Circle" then
			minX, maxX, minZ, maxZ = ob.Pos.X - ob.Radius, ob.Pos.X + ob.Radius, ob.Pos.Z - ob.Radius, ob.Pos.Z + ob.Radius
		else
			minX, maxX, minZ, maxZ = ob.MinX, ob.MaxX, ob.MinZ, ob.MaxZ
		end
		local x0 = math.floor((minX - (c.X - HALF)) / CELL)
		local x1 = math.floor((maxX - (c.X - HALF)) / CELL)
		local z0 = math.floor((minZ - (c.Z - HALF)) / CELL)
		local z1 = math.floor((maxZ - (c.Z - HALF)) / CELL)
		for ix = math.max(0, x0), math.min(n - 1, x1) do
			local cx = c.X - HALF + (ix + 0.5) * CELL
			for iz = math.max(0, z0), math.min(n - 1, z1) do
				local cz = c.Z - HALF + (iz + 0.5) * CELL
				if ob.Kind == "Circle" then
					if (cx - ob.Pos.X) ^ 2 + (cz - ob.Pos.Z) ^ 2 <= ob.Radius * ob.Radius then
						mark(ix, iz)
					end
				elseif cx >= minX and cx <= maxX and cz >= minZ and cz <= maxZ then
					mark(ix, iz)
				end
			end
		end
	end
	local cellArea = CELL * CELL
	local ringArea, ringBlocked = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
	local total = 0
	for ix = 0, n - 1 do
		local dx = -HALF + (ix + 0.5) * CELL
		for iz = 0, n - 1 do
			local dz = -HALF + (iz + 0.5) * CELL
			local d = math.sqrt(dx * dx + dz * dz)
			local ring = d < 40 and 1 or (d < 100 and 2 or (d < 200 and 3 or 4))
			ringArea[ring] += cellArea
			if blocked[ix * n + iz] then
				ringBlocked[ring] += cellArea
				total += cellArea
			end
		end
	end
	local rings = {}
	for i, r in ipairs(RINGS) do
		rings[i] = {
			from = r[1],
			to = r[2] == math.huge and "corners" or r[2],
			obstacles = ringCount[i],
			blockedArea = math.floor(ringBlocked[i] + 0.5),
			ringArea = math.floor(ringArea[i] + 0.5),
			blockedPercent = math.floor(ringBlocked[i] / math.max(ringArea[i], 1) * 10000 + 0.5) / 100,
		}
	end
	return {
		obstacles = #arena.Obstacles,
		circles = kinds.Circle,
		boxes = kinds.Box,
		blockedArea = math.floor(total + 0.5),
		playArea = SIZE * SIZE,
		blockedPercent = math.floor(total / (SIZE * SIZE) * 10000 + 0.5) / 100,
		openArea = math.floor(SIZE * SIZE - total + 0.5),
		rings = rings,
		trees = arena.Trees,
		rocks = arena.Rocks,
		parts = preview.worldCounts(arena.Model),
	}
end

local all = {}
local arena
for i = 1, runs do
	arena = C.try("MapBuilder.BuildArena", s.MapBuilder.BuildArena, arenaName)
	if not arena then
		return
	end
	table.insert(all, measure(arena))
end
local m = all[#all]
local first = all[1]
preview.metrics.arena = arenaName
preview.metrics.seed = preview.seed
preview.metrics.layout = first
if runs > 1 then
	local function spread(key, sub)
		local lo, hi, sum = math.huge, -math.huge, 0
		for _, r in ipairs(all) do
			local v = sub and r[sub][key] or r[key]
			lo, hi, sum = math.min(lo, v), math.max(hi, v), sum + v
		end
		return { min = lo, max = hi, mean = math.floor(sum / #all * 100 + 0.5) / 100 }
	end
	preview.metrics.spread = {
		runs = runs,
		obstacles = spread("obstacles"),
		blockedArea = spread("blockedArea"),
		blockedPercent = spread("blockedPercent"),
		parts = spread("parts", "parts"),
		meshParts = spread("meshParts", "parts"),
		triangles = spread("triangles", "parts"),
		shadowCasters = spread("shadowCasters", "parts"),
		lights = spread("lights", "parts"),
	}
end

-- --set loot=1: this stage's portal + loot (LootSystem.BuildStage) with markers per type
local lootMarks = {}
if preview.args.loot and arena then
	local spot = C.try("FindPortalSpot", s.MapBuilder.FindPortalSpot, arena, Random.new(preview.seed * 13 + 5), nil)
	if spot then
		C.try("BuildPortal", s.MapBuilder.BuildPortal, arena, spot)
		table.insert(lootMarks, { spot, "#7fb2ff", "Portal" })
	end
	local loot = C.server("LootSystem")
	if loot then
		C.try("LootSystem.Init", loot.Init, {
			RunManager = { GetRunPlayers = function() return {} end, GetRunTime = function() return 0 end },
			MonetizationService = { GoldMultiplier = function() return 1 end },
		})
		C.try("LootSystem.BuildStage", loot.BuildStage, arena, tonumber(preview.args.stage) or 1, spot)
		local colors = { Small = "#d9b77a", Large = "#b07a3a", Golden = "#ffd23f", Chance = "#ffe28a", Bargain = "#ff5a5a", Guarded = "#c8d6ff" }
		for _, obj in ipairs(loot.Objects()) do
			table.insert(lootMarks, { obj.Pos, colors[obj.Type] or "#ffffff", obj.Type })
		end
		preview.metrics.loot = #loot.Objects()
	end
end

-- overlays (the arena drawn last is the one shown)
local c = arena.Center
for _, ob in ipairs(arena.Obstacles) do
	if ob.Kind == "Circle" then
		preview.overlay({ kind = "circle", x = ob.Pos.X, z = ob.Pos.Z, y = c.Y + 0.3, r = ob.Radius, color = "#ff2a2a", fill = "rgba(255,40,40,0.35)", width = 1.5 })
	else
		preview.overlay({ kind = "box", minX = ob.MinX, maxX = ob.MaxX, minZ = ob.MinZ, maxZ = ob.MaxZ, y = c.Y + 0.3, color = "#ff2a2a", fill = "rgba(255,40,40,0.35)", width = 1.5 })
	end
end
preview.overlay({ kind = "box", minX = c.X - HALF, maxX = c.X + HALF, minZ = c.Z - HALF, maxZ = c.Z + HALF, color = "#ffffff", width = 2, dash = "10 6" })
preview.overlay({ kind = "circle", x = c.X, z = c.Z, r = Config.Arenas.ClearRadius or 40, color = "#ffe066", width = 2.5, fill = "rgba(255,224,102,0.12)" })
for _, r in ipairs({ 100, 200 }) do
	preview.overlay({ kind = "circle", x = c.X, z = c.Z, r = r, color = "rgba(255,255,255,0.7)", width = 1.2, dash = "4 6" })
end
for _, r in ipairs({ 40, 100, 200 }) do
	preview.overlay({ kind = "label", x = c.X + r * 0.7071 + 6, z = c.Z + r * 0.7071 + 6, text = tostring(r), color = "#ffffff", size = 15 })
end
preview.overlay({ kind = "label", x = c.X, z = c.Z - HALF - 14, size = 20, color = "#ffffff", text = string.format("%s  seed %d%s  |  %d obstacles  |  blocked %.2f%% (%d of %d studs\u{B2})  |  parts %d, MeshParts %d, shadow casters %d", arenaName, preview.seed, runs > 1 and string.format(" (build %d of %d)", runs, runs) or "", m.obstacles, m.blockedPercent, m.blockedArea, m.playArea, m.parts.parts, m.parts.meshParts, m.parts.shadowCasters) })
for _, mk in ipairs(lootMarks) do
	preview.overlay({ kind = "circle", x = mk[1].X, z = mk[1].Z, y = c.Y + 0.4, r = 4, color = mk[2], fill = mk[2], width = 2 })
	preview.overlay({ kind = "label", x = mk[1].X, z = mk[1].Z - 8, text = mk[3], color = mk[2], size = 13 })
end
preview.camera = { cf = CFrame.lookAt(c + Vector3.new(0, 600, 0), c, Vector3.new(0, 0, -1)), ortho = { height = SIZE + 70 }, near = 1, far = 2000 }
preview.render.hideCoreUi = true
preview.advance(0.1)
