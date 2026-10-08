-- heightgrid-regression: the server HeightGrid (ground height + flow fields for maps with
-- terraces, ramps, a cave and a bridge; docs/redesign/gameplay/DESIGN.md section 3).
--   A. flat fallback: no NavGround parts = today's flat floor everywhere
--   B. a ramp is steppable, a cliff is not; GroundY is smooth on the ramp, crisp at a cliff
--   C. a flow field routes an enemy round a cliff to the ramp (moving like EnemyAI: slide
--      on a blocked step), path distance > straight distance, an isolated plateau is
--      unreachable
--   D. Build with raycasts: a cave floor under an untagged roof, a NavBlock pool, a terrace
-- PASS / FAIL lines. run: lune run tools/preview/runtime/main.luau -- --scene
-- heightgrid-regression --studio --device pc --max-time 400 --set headless=on
local C = lib("common")
local CollectionService = game:GetService("CollectionService")
local Config = C.shared("Config")
local HG = C.server("HeightGrid")
local Core = HG.Core
local FLOOR = Config.ArenaOrigin.Y

local fails = 0
local function check(name: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail and (": " .. detail) or ""))
end
local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-3)
end

------------------------------------------------------------------------------------------
-- A. Flat fallback
------------------------------------------------------------------------------------------
HG.Clear()
local rpA = { Alive = true, Root = { Position = Vector3.new(10, 3, 0) } }
local half = Config.Arenas.Size / 2
local minX, minZ, maxX, maxZ = HG.Bounds()
check("A1 no grid: not active", HG.IsActive() == false)
check("A2 no grid: GroundY is the flat floor", HG.GroundY(123, -45) == FLOOR and HG.GroundY(-500, 900) == FLOOR)
check("A3 no grid: walkable and steppable everywhere", HG.IsWalkable(1e4, -1e4) and HG.CanStep(0, 0, 300, 300))
check("A4 no grid: FlowDir zero", HG.FlowDir(rpA, 50, 50) == Vector3.zero)
check("A5 no grid: PathDistance = straight XZ distance", near(HG.PathDistance(rpA, 13, 4), 5), tostring(HG.PathDistance(rpA, 13, 4)))
check("A6 no grid: bounds = today's square", near(minX, Config.ArenaOrigin.X - half) and near(maxZ, Config.ArenaOrigin.Z + half),
	string.format("%.1f %.1f %.1f %.1f", minX, minZ, maxX, maxZ))
local gx, gz = HG.ClampXZ(1e4, -1e4, 4)
check("A7 no grid: ClampXZ = today's clamp", near(gx, Config.ArenaOrigin.X + half - 4) and near(gz, Config.ArenaOrigin.Z - half + 4))
check("A8 no grid: Ground(v) keeps x, z on the floor", HG.Ground(Vector3.new(7, 99, 8)) == Vector3.new(7, FLOOR, 8))
-- an arena with no tagged ground stays flat
check("A9 Build without NavGround parts: flat", HG.Build({ Name = "Plain" }) == false and HG.IsActive() == false)

------------------------------------------------------------------------------------------
-- B / C. A built grid: basin (y 0, i < 20), terrace (y 30, i >= 20), a ramp (rows 30-35,
-- i 10-19, +3 per cell), an isolated plateau (i 2-3, j 2-3, y 50). Cells are 4 studs.
------------------------------------------------------------------------------------------
local N, CELL = 40, 4
local g = Core.NewGrid(0, 0, N, N, CELL, 3.2, FLOOR)
for j = 0, N - 1 do
	for i = 0, N - 1 do
		local y = i >= 20 and 30 or 0
		if j >= 30 and j <= 35 and i >= 10 and i <= 19 then
			y = (i - 9) * 3
		end
		if i >= 2 and i <= 3 and j >= 2 and j <= 3 then
			y = 50
		end
		Core.Set(g, i, j, y, true)
	end
end
local function centre(i: number, j: number): (number, number)
	return Core.CellCentre(g, i, j)
end

local rx, rz = centre(14, 32)
check("B1 GroundY at a ramp cell centre", near(Core.GroundY(g, rx, rz), 15), tostring(Core.GroundY(g, rx, rz)))
check("B2 GroundY between ramp cells interpolates", near(Core.GroundY(g, rx + 2, rz), 16.5), tostring(Core.GroundY(g, rx + 2, rz)))
check("B3 cliff edge stays crisp (basin side)", near(Core.GroundY(g, 79.9, 22), 0), tostring(Core.GroundY(g, 79.9, 22)))
check("B4 cliff edge stays crisp (terrace side)", near(Core.GroundY(g, 80.1, 22), 30), tostring(Core.GroundY(g, 80.1, 22)))
check("B5 up the ramp is steppable", Core.CanStep(g, 38, rz, 42, rz) and Core.CanStep(g, rx, rz, rx + 4, rz) and Core.CanStep(g, 78, rz, 82, rz))
check("B6 the whole ramp in one line is steppable", Core.CanStep(g, 30, rz, 90, rz))
check("B7 the cliff is not steppable (either way)", not Core.CanStep(g, 78, 22, 82, 22) and not Core.CanStep(g, 82, 22, 78, 22))
local sx, sz = centre(14, 30) -- the ramp's edge row; row 29 beside it is basin 15 below
check("B8 off the ramp's side is not steppable", not Core.CanStep(g, sx, sz, sx, sz - 4) and not Core.CanStep(g, sx, sz - 4, sx, sz))
check("B9 a long line over the cliff is not steppable", not Core.CanStep(g, 10, 22, 150, 22))
check("B10 moves inside one cell are always allowed", Core.CanStep(g, 78.5, 22, 79.5, 23))

-- C. the flow field from a player on the terrace
local field = Core.NewField()
local px, pz = centre(30, 5)
check("C1 field builds", Core.BuildField(g, field, px, pz, 72) and field.Ready)
local ex, ez = centre(5, 5)
local straight = math.sqrt((px - ex) ^ 2 + (pz - ez) ^ 2)
local pathD = Core.PathDistance(g, field, ex, ez)
check("C2 path distance is finite and longer than the straight line (round the cliff)", pathD < math.huge and pathD > straight * 1.5,
	string.format("path %.0f, straight %.0f", pathD, straight))
local hx, hz = centre(2, 2)
check("C3 an isolated plateau is unreachable", Core.PathDistance(g, field, hx, hz) == math.huge)
check("C4 the player's own cell is 0 and has no flow", Core.PathDistance(g, field, px, pz) == 0 and select(1, Core.FlowDir(g, field, px, pz)) == 0)

-- walk an enemy down the field like EnemyAI does (2 studs a step, slide on a blocked step)
local x, z = ex, ez
local usedRamp, badStep, blocked, steps = false, false, 0, 0
local lastY = Core.GroundY(g, x, z)
for _ = 1, 800 do
	local dx, dz = Core.FlowDir(g, field, x, z)
	if dx == 0 and dz == 0 then
		break
	end
	steps += 1
	local nx, nz = x + dx * 2, z + dz * 2
	if not Core.CanStep(g, x, z, nx, nz) then
		blocked += 1
		if Core.CanStep(g, x, z, nx, z) then
			nz = z
		elseif Core.CanStep(g, x, z, x, nz) then
			nx = x
		else
			nx, nz = x, z
		end
	end
	x, z = nx, nz
	local y = Core.GroundY(g, x, z)
	if math.abs(y - lastY) > 3.2 then
		badStep = true
	end
	lastY = y
	local ci, cj = Core.CellOf(g, x, z)
	if ci >= 10 and ci <= 19 and cj >= 30 and cj <= 35 then
		usedRamp = true
	end
end
local ci, cj = Core.CellOf(g, x, z)
check("C5 the enemy reaches the player's cell on the terrace", ci == 30 and cj == 5, string.format("ended in cell %d, %d after %d steps", ci, cj, steps))
check("C6 its route goes up the ramp", usedRamp)
check("C7 no step changes height by more than StepMax", not badStep)
check("C8 following the field almost never hits a blocked step", blocked <= 4, tostring(blocked) .. " blocked steps")

-- C9-C11: the public wrappers with a set grid
local rpC = { Alive = true, Root = { Position = Vector3.new(px, 33, pz) } }
HG.SetGrid(g, { Bounds = { MinX = 0, MinZ = 0, MaxX = N * CELL, MaxZ = N * CELL } })
check("C9 SetGrid: active, bounds from arena.Bounds", HG.IsActive() and select(3, HG.Bounds()) == N * CELL)
check("C10 BuildFieldNow + FlowDir gives a unit XZ direction", HG.BuildFieldNow(rpC, px, pz) and near(HG.FlowDir(rpC, ex, ez).Magnitude, 1) and HG.FlowDir(rpC, ex, ez).Y == 0)
check("C11 no field for another player: FlowDir zero, PathDistance huge", HG.FlowDir({}, ex, ez) == Vector3.zero and HG.PathDistance({}, ex, ez) == math.huge)
local wx, wz = HG.NearestWalkable(ex, ez, 2)
check("C12 NearestWalkable keeps a walkable point", wx == ex and wz == ez)
HG.Clear()
check("C13 Clear: flat again", not HG.IsActive() and HG.GroundY(px, pz) == FLOOR)

------------------------------------------------------------------------------------------
-- D. Build with raycasts (vertical rays against axis-aligned parts in the Include list)
------------------------------------------------------------------------------------------
local model = Instance.new("Model")
model.Name = "Arena_HeightTest"
model.Parent = workspace
local function block(name: string, pos: Vector3, size: Vector3, tag: string?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Position = pos
	p.Size = size
	p.Parent = model
	if tag then
		CollectionService:AddTag(p, tag)
	end
	return p
end
block("Floor", Vector3.new(40, -1, 40), Vector3.new(80, 2, 80), "NavGround") -- top 0
local roof = block("CaveRoof", Vector3.new(40, 20, 40), Vector3.new(20, 4, 20), nil) -- untagged, over x/z 30-50
block("Terrace", Vector3.new(70, 14, 40), Vector3.new(20, 28, 80), "NavGround") -- top 28, x 60-80
block("Pool", Vector3.new(15, 0.5, 15), Vector3.new(10, 1, 10), "NavBlock") -- top 1, x/z 10-20

local roofInFilter = false
local rays = 0
preview.setRaycast(function(origin: Vector3, direction: Vector3, params)
	rays += 1
	if not params then
		return nil
	end
	local list = {}
	for _, inst in ipairs(params.FilterDescendantsInstances) do
		if inst == roof then
			roofInFilter = true
		end
		if inst:IsA("BasePart") then
			table.insert(list, inst)
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(list, d)
			end
		end
	end
	local best, bestTop = nil, -math.huge
	local bottom = origin.Y + direction.Y
	for _, p in ipairs(list) do
		local pp, s = p.Position, p.Size
		local top = pp.Y + s.Y / 2
		if math.abs(origin.X - pp.X) <= s.X / 2 and math.abs(origin.Z - pp.Z) <= s.Z / 2 and top <= origin.Y and top >= bottom and top > bestTop then
			best, bestTop = p, top
		end
	end
	if not best then
		return nil
	end
	return { Instance = best, Position = Vector3.new(origin.X, bestTop, origin.Z), Normal = Vector3.yAxis, Distance = origin.Y - bestTop, Material = Enum.Material.Plastic }
end)
local arenaD = { Name = "HeightTest", Model = model, Bounds = { MinX = 0, MinZ = 0, MaxX = 80, MaxZ = 80 } }
local built = HG.Build(arenaD)
local raysFirst = rays
check("D1 Build with NavGround parts makes a grid", built and HG.IsActive(), string.format("%d rays", rays))
check("D2 the untagged cave roof is not in the ray filter", not roofInFilter)
check("D3 cave floor under the roof: ground 0, walkable", near(HG.GroundY(40, 40), 0) and HG.IsWalkable(40, 40), tostring(HG.GroundY(40, 40)))
check("D4 terrace top: ground 28", near(HG.GroundY(70, 40), 28) and HG.IsWalkable(70, 40), tostring(HG.GroundY(70, 40)))
check("D5 terrace edge is a cliff (not steppable)", not HG.CanStep(56, 40, 62, 40))
check("D6 the NavBlock pool is not walkable", not HG.IsWalkable(15, 15) and HG.IsWalkable(30, 15))
check("D7 Build again with the same arena keeps the grid (no second pass)", HG.Build(arenaD) and rays == raysFirst)
preview.setRaycast(nil)
HG.Clear()
model:Destroy()

preview.log(if fails == 0 then "PASS heightgrid-regression" else string.format("FAIL: heightgrid-regression (%d checks)", fails))
