--!strict
--[[
	HeightGrid.lua
	Ground height and navigation for maps with terraces, ramps, caves and bridges
	(docs/redesign/gameplay/DESIGN.md section 3). Tuning: SwarmV2.Run.RunConfig.Nav.

	HeightGrid.Build(arena), after the map is built, casts one ray straight down per 4-stud
	cell over the arena bounds. The rays hit only parts tagged NavGround (floors, terraces,
	ramps, bridge decks, cave floors) or NavBlock (cliff faces, water, gaps: never walkable),
	so an untagged cave roof or overhang is seen through. Each cell stores its ground Y and
	whether it is walkable (one layer per cell: under a bridge deck the cell is the deck).

	Flow fields: for each living run player a Dijkstra fill (8 neighbours, only steps of at
	most StepMax between neighbour cells, no diagonal corner cutting) out to FieldRadius
	cells. One field rebuilds at a time, spread over frames (FieldBudget cells per frame),
	and a new one starts every FieldRebuild seconds, round robin over the players. Enemies
	(EnemyAI) follow the field's gradient; spawns (EnemySpawner) read its path distances.

	No grid (no part tagged NavGround: every arena built before the redesign): every query
	falls back to today's flat floor. GroundY = Config.ArenaOrigin.Y, everything is
	walkable and steppable, FlowDir is zero (enemies seek directly) and PathDistance is the
	straight XZ distance, so the existing game runs unchanged.

	The grid logic is in HeightGrid.Core: plain numbers and arrays, no Roblox calls, so it is
	unit-tested offline (tools/preview/scenes/heightgrid-regression.luau). Build is the only
	part that raycasts.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))

local Nav: { [string]: any } = RunConfig.Nav

local HeightGrid = {}

------------------------------------------------------------------------------------------
-- Core (pure logic)
------------------------------------------------------------------------------------------

export type Grid = {
	MinX: number,
	MinZ: number,
	Cols: number,
	Rows: number,
	Cell: number,
	StepMax: number, -- per cell
	FallbackY: number,
	Y: { number }, -- ground top per cell (index j * Cols + i + 1)
	Walk: { boolean },
}

-- A field window: Dist[k] is valid only where Stamp[k] == Id (no clearing between builds).
export type Field = {
	Dist: { number }, -- path cost (10 per straight cell, 14 per diagonal)
	Stamp: { number },
	Id: number,
	I0: number,
	J0: number,
	W: number,
	H: number,
	Ready: boolean,
}

-- One Dijkstra fill in progress (Dial's bucket queue: edge costs are 10 / 14, so a ring of
-- 16 buckets holds every pending cost).
export type Builder = {
	Grid: Grid?,
	Field: Field?,
	Buckets: { { number } },
	Counts: { number },
	Cost: number,
	Queued: number,
}

local Core = {}
HeightGrid.Core = Core

local STRAIGHT, DIAGONAL = 10, 14
local RING = 16
local fieldIds = 0

function Core.NewGrid(minX: number, minZ: number, cols: number, rows: number, cell: number, stepMax: number, fallbackY: number): Grid
	local n = cols * rows
	return {
		MinX = minX,
		MinZ = minZ,
		Cols = cols,
		Rows = rows,
		Cell = cell,
		StepMax = stepMax,
		FallbackY = fallbackY,
		Y = table.create(n, fallbackY),
		Walk = table.create(n, false),
	}
end

-- Cell (i, j) (0-based): its ground Y and whether it is walkable.
function Core.Set(g: Grid, i: number, j: number, y: number, walk: boolean)
	local idx = j * g.Cols + i + 1
	g.Y[idx] = y
	g.Walk[idx] = walk
end

-- World XZ of a cell's centre.
function Core.CellCentre(g: Grid, i: number, j: number): (number, number)
	return g.MinX + (i + 0.5) * g.Cell, g.MinZ + (j + 0.5) * g.Cell
end

-- 0-based cell of a world point (may be outside the grid).
local function cellOf(g: Grid, x: number, z: number): (number, number)
	return math.floor((x - g.MinX) / g.Cell), math.floor((z - g.MinZ) / g.Cell)
end
Core.CellOf = cellOf

local function inside(g: Grid, i: number, j: number): boolean
	return i >= 0 and j >= 0 and i < g.Cols and j < g.Rows
end

-- Bilinear between cell centres. Corners that are a cliff away from the cell the point is
-- in (more than StepMax) are replaced by that cell's own height, so a cliff edge stays a
-- crisp edge instead of a smeared slope; ramps interpolate smoothly. Outside the grid the
-- nearest edge cell is used.
function Core.GroundY(g: Grid, x: number, z: number): number
	local cols, rows, cell = g.Cols, g.Rows, g.Cell
	local ci = math.clamp(math.floor((x - g.MinX) / cell), 0, cols - 1)
	local cj = math.clamp(math.floor((z - g.MinZ) / cell), 0, rows - 1)
	local Y = g.Y
	local base = Y[cj * cols + ci + 1]
	local fx = (x - g.MinX) / cell - 0.5
	local fz = (z - g.MinZ) / cell - 0.5
	local i0 = math.floor(fx)
	local j0 = math.floor(fz)
	local tx = math.clamp(fx - i0, 0, 1)
	local tz = math.clamp(fz - j0, 0, 1)
	local i1 = math.clamp(i0 + 1, 0, cols - 1)
	local j1 = math.clamp(j0 + 1, 0, rows - 1)
	i0 = math.clamp(i0, 0, cols - 1)
	j0 = math.clamp(j0, 0, rows - 1)
	local step = g.StepMax
	local y00 = Y[j0 * cols + i0 + 1]
	local y10 = Y[j0 * cols + i1 + 1]
	local y01 = Y[j1 * cols + i0 + 1]
	local y11 = Y[j1 * cols + i1 + 1]
	if math.abs(y00 - base) > step then
		y00 = base
	end
	if math.abs(y10 - base) > step then
		y10 = base
	end
	if math.abs(y01 - base) > step then
		y01 = base
	end
	if math.abs(y11 - base) > step then
		y11 = base
	end
	local a = y00 + (y10 - y00) * tx
	local b = y01 + (y11 - y01) * tx
	return a + (b - a) * tz
end

function Core.IsWalkable(g: Grid, x: number, z: number): boolean
	local i, j = cellOf(g, x, z)
	if not inside(g, i, j) then
		return false
	end
	return g.Walk[j * g.Cols + i + 1]
end

-- One step between neighbour cells (indices): the target is walkable and the height change
-- is at most StepMax. From an unwalkable cell any walkable neighbour is allowed (a way out).
local function stepOK(g: Grid, a: number, b: number): boolean
	local W = g.Walk
	if not W[b] then
		return false
	end
	if not W[a] then
		return true
	end
	return math.abs(g.Y[b] - g.Y[a]) <= g.StepMax
end

-- One move between neighbour cells (i, j) -> (i + di, j + dj), |di|, |dj| <= 1. A diagonal
-- needs one of its two orthogonal routes to be steppable too (no corner cutting).
local function moveOK(g: Grid, i: number, j: number, di: number, dj: number): boolean
	local cols = g.Cols
	local a = j * cols + i + 1
	local bi, bj = i + di, j + dj
	if not inside(g, bi, bj) then
		return false
	end
	local b = bj * cols + bi + 1
	if not stepOK(g, a, b) then
		return false
	end
	if di ~= 0 and dj ~= 0 then
		local c1 = j * cols + bi + 1
		local c2 = bj * cols + i + 1
		return (stepOK(g, a, c1) and stepOK(g, c1, b)) or (stepOK(g, a, c2) and stepOK(g, c2, b))
	end
	return true
end

--[[
	Can something walk from a to b? Within one cell: always. Otherwise every cell the
	straight line crosses must be walkable and each cell-to-cell step at most StepMax (long
	moves are walked cell by cell, at most 64 cells).
]]
function Core.CanStep(g: Grid, ax: number, az: number, bx: number, bz: number): boolean
	local ia, ja = cellOf(g, ax, az)
	local ib, jb = cellOf(g, bx, bz)
	if ia == ib and ja == jb then
		return true
	end
	if not inside(g, ib, jb) then
		return false
	end
	if not inside(g, ia, ja) then
		return g.Walk[jb * g.Cols + ib + 1]
	end
	local di, dj = ib - ia, jb - ja
	local n = math.max(math.abs(di), math.abs(dj))
	if n == 1 then
		return moveOK(g, ia, ja, di, dj)
	end
	if n > 64 then
		return false
	end
	local pi, pj = ia, ja
	for s = 1, n do
		local ci = ia + math.floor(di * s / n + 0.5)
		local cj = ja + math.floor(dj * s / n + 0.5)
		if ci ~= pi or cj ~= pj then
			if not moveOK(g, pi, pj, ci - pi, cj - pj) then
				return false
			end
			pi, pj = ci, cj
		end
	end
	return true
end

function Core.NewField(): Field
	return { Dist = {}, Stamp = {}, Id = 0, I0 = 0, J0 = 0, W = 0, H = 0, Ready = false }
end

function Core.NewBuilder(): Builder
	local buckets = table.create(RING)
	local counts = table.create(RING, 0)
	for b = 1, RING do
		buckets[b] = {}
	end
	return { Grid = nil, Field = nil, Buckets = buckets, Counts = counts, Cost = 0, Queued = 0 }
end

local function push(bd: Builder, k: number, cost: number)
	local b = cost % RING + 1
	local c = bd.Counts[b] + 1
	bd.Counts[b] = c
	bd.Buckets[b][c] = k
	bd.Queued += 1
end

--[[
	Starts a fill of `field` from the walkable cell at (x, z) (or the nearest walkable cell
	within 2 cells), limited to a (2 radius + 1)^2 window. Returns false when there is no
	walkable cell to start from (the field is left not ready).
]]
function Core.BeginField(bd: Builder, g: Grid, field: Field, x: number, z: number, radius: number): boolean
	local ci, cj = cellOf(g, x, z)
	ci = math.clamp(ci, 0, g.Cols - 1)
	cj = math.clamp(cj, 0, g.Rows - 1)
	local si, sj = -1, -1
	if g.Walk[cj * g.Cols + ci + 1] then
		si, sj = ci, cj
	else
		local best = math.huge
		for dj = -2, 2 do
			for di = -2, 2 do
				local i, j = ci + di, cj + dj
				if inside(g, i, j) and g.Walk[j * g.Cols + i + 1] then
					local d = di * di + dj * dj
					if d < best then
						best, si, sj = d, i, j
					end
				end
			end
		end
	end
	for b = 1, RING do
		bd.Counts[b] = 0
	end
	bd.Queued = 0
	bd.Cost = 0
	bd.Grid = nil
	bd.Field = nil
	field.Ready = false
	if si < 0 then
		return false
	end
	fieldIds += 1
	field.Id = fieldIds
	field.I0 = math.max(0, si - radius)
	field.J0 = math.max(0, sj - radius)
	field.W = math.min(g.Cols - 1, si + radius) - field.I0 + 1
	field.H = math.min(g.Rows - 1, sj + radius) - field.J0 + 1
	local k = (sj - field.J0) * field.W + (si - field.I0) + 1
	field.Dist[k] = 0
	field.Stamp[k] = field.Id
	bd.Grid = g
	bd.Field = field
	push(bd, k, 0)
	return true
end

-- Settles up to `budget` cells. Returns true when the fill is complete (field.Ready).
function Core.RunField(bd: Builder, budget: number): boolean
	local g, field = bd.Grid, bd.Field
	if not g or not field then
		return true
	end
	local cols = g.Cols
	local Y, Walk, stepMax = g.Y, g.Walk, g.StepMax
	local Dist, Stamp, id = field.Dist, field.Stamp, field.Id
	local I0, J0, W, H = field.I0, field.J0, field.W, field.H
	local buckets, counts = bd.Buckets, bd.Counts
	local cost = bd.Cost
	local done = 0
	while bd.Queued > 0 and done < budget do
		local b = cost % RING + 1
		local c = counts[b]
		if c == 0 then
			cost += 1
			continue
		end
		local k = buckets[b][c]
		counts[b] = c - 1
		bd.Queued -= 1
		if Dist[k] < cost then
			continue -- stale entry (a shorter route was found after it was queued)
		end
		done += 1
		local wi = (k - 1) % W
		local wj = (k - 1 - wi) // W
		local i, j = wi + I0, wj + J0
		local a = j * cols + i + 1
		local ya = Y[a]
		for dj = -1, 1 do
			local nwj = wj + dj
			if nwj >= 0 and nwj < H then
				for di = -1, 1 do
					local nwi = wi + di
					if (di ~= 0 or dj ~= 0) and nwi >= 0 and nwi < W then
						local nb = (j + dj) * cols + (i + di) + 1
						if Walk[nb] and math.abs(Y[nb] - ya) <= stepMax then
							local diag = di ~= 0 and dj ~= 0
							local ok = true
							if diag then
								-- no corner cutting: one orthogonal route must be steppable
								local c1 = j * cols + (i + di) + 1
								local c2 = (j + dj) * cols + i + 1
								ok = (Walk[c1] and math.abs(Y[c1] - ya) <= stepMax and math.abs(Y[nb] - Y[c1]) <= stepMax)
									or (Walk[c2] and math.abs(Y[c2] - ya) <= stepMax and math.abs(Y[nb] - Y[c2]) <= stepMax)
							end
							if ok then
								local nk = nwj * W + nwi + 1
								local nc = cost + (diag and DIAGONAL or STRAIGHT)
								if Stamp[nk] ~= id or nc < Dist[nk] then
									Stamp[nk] = id
									Dist[nk] = nc
									push(bd, nk, nc)
								end
							end
						end
					end
				end
			end
		end
	end
	bd.Cost = cost
	if bd.Queued == 0 then
		field.Ready = true
		bd.Grid = nil
		bd.Field = nil
		return true
	end
	return false
end

-- A whole fill at once (tests, the first field of a player).
function Core.BuildField(g: Grid, field: Field, x: number, z: number, radius: number, bd: Builder?): boolean
	local builder = bd or Core.NewBuilder()
	if not Core.BeginField(builder, g, field, x, z, radius) then
		return false
	end
	Core.RunField(builder, math.huge)
	return true
end

-- Path cost at a cell of a ready field, or nil (outside the window / not reached).
local function fieldCost(field: Field, i: number, j: number): number?
	local wi, wj = i - field.I0, j - field.J0
	if wi < 0 or wj < 0 or wi >= field.W or wj >= field.H then
		return nil
	end
	local k = wj * field.W + wi + 1
	if field.Stamp[k] ~= field.Id then
		return nil
	end
	return field.Dist[k]
end

--[[
	The way to go from (x, z) down the field: toward the centre of the neighbour cell with
	the lowest path cost that can be stepped into. Returns 0, 0 in the target's own cell,
	outside the field or where nothing is lower.
]]
function Core.FlowDir(g: Grid, field: Field, x: number, z: number): (number, number)
	if not field.Ready then
		return 0, 0
	end
	local i, j = cellOf(g, x, z)
	local here = fieldCost(field, i, j)
	if not here or here == 0 then
		return 0, 0
	end
	local best, bi, bj = here, 0, 0
	for dj = -1, 1 do
		for di = -1, 1 do
			if di ~= 0 or dj ~= 0 then
				local c = fieldCost(field, i + di, j + dj)
				if c and c < best and moveOK(g, i, j, di, dj) then
					best, bi, bj = c, di, dj
				end
			end
		end
	end
	if bi == 0 and bj == 0 then
		return 0, 0
	end
	local tx, tz = Core.CellCentre(g, i + bi, j + bj)
	local dx, dz = tx - x, tz - z
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 1e-3 then
		return 0, 0
	end
	return dx / d, dz / d
end

-- Path distance in studs from (x, z) to the field's start, or math.huge if not reached.
function Core.PathDistance(g: Grid, field: Field, x: number, z: number): number
	if not field.Ready then
		return math.huge
	end
	local i, j = cellOf(g, x, z)
	local c = fieldCost(field, i, j)
	if not c then
		return math.huge
	end
	return c / STRAIGHT * g.Cell
end

------------------------------------------------------------------------------------------
-- Module state
------------------------------------------------------------------------------------------

local ctx: any = nil
local grid: Grid? = nil
local builtArena: any = nil
-- arena bounds (the fence): arena.Bounds when the map gives them, else today's square
local bMinX, bMinZ, bMaxX, bMaxZ = 0, 0, 0, 0

type Record = { Live: Field, Work: Field }
local fields: { [any]: Record } = {}
local builder = Core.NewBuilder()
local building: any = nil -- the rp whose Work field is filling
local rebuildTimer = 0
local pruneTimer = 0
local robin = 0

local function squareBounds()
	local c = Config.ArenaOrigin
	local h = (Config.Arenas :: any).Size / 2
	bMinX, bMinZ, bMaxX, bMaxZ = c.X - h, c.Z - h, c.X + h, c.Z + h
end
squareBounds()

--[[
	Reads arena.Bounds: { MinX, MinZ, MaxX, MaxZ } (numbers), { Min = Vector3, Max = Vector3 }
	or { Center = Vector3, Half = number }. Anything else keeps today's square.
]]
local function readBounds(arena: any)
	squareBounds()
	local b = arena and arena.Bounds
	if type(b) ~= "table" then
		return
	end
	if type(b.MinX) == "number" and type(b.MinZ) == "number" and type(b.MaxX) == "number" and type(b.MaxZ) == "number" then
		bMinX, bMinZ, bMaxX, bMaxZ = b.MinX, b.MinZ, b.MaxX, b.MaxZ
	elseif typeof(b.Min) == "Vector3" and typeof(b.Max) == "Vector3" then
		bMinX, bMinZ, bMaxX, bMaxZ = b.Min.X, b.Min.Z, b.Max.X, b.Max.Z
	elseif typeof(b.Center) == "Vector3" and type(b.Half) == "number" then
		bMinX, bMinZ, bMaxX, bMaxZ = b.Center.X - b.Half, b.Center.Z - b.Half, b.Center.X + b.Half, b.Center.Z + b.Half
	end
	if not (bMinX < bMaxX and bMinZ < bMaxZ) then
		squareBounds()
	end
end

------------------------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------------------------

-- Drops the grid and every field: every query is flat again.
function HeightGrid.Clear()
	grid = nil
	builtArena = nil
	table.clear(fields)
	building = nil
	builder.Grid = nil
	builder.Field = nil
	builder.Queued = 0
	squareBounds()
end

-- True while a height grid is built (a map with NavGround parts).
function HeightGrid.IsActive(): boolean
	return grid ~= nil
end

-- The arena fence: minX, minZ, maxX, maxZ.
function HeightGrid.Bounds(): (number, number, number, number)
	return bMinX, bMinZ, bMaxX, bMaxZ
end

-- Clamps a point inside the fence by `margin` studs.
function HeightGrid.ClampXZ(x: number, z: number, margin: number): (number, number)
	return math.clamp(x, bMinX + margin, math.max(bMinX + margin, bMaxX - margin)), math.clamp(z, bMinZ + margin, math.max(bMinZ + margin, bMaxZ - margin))
end

local function isBlock(inst: Instance?): boolean
	local tag = Nav.BlockTag
	local depth = 0
	while inst and depth < 3 do
		if CollectionService:HasTag(inst, tag) then
			return true
		end
		inst = inst.Parent
		depth += 1
	end
	return false
end

--[[
	Builds the grid for a freshly built arena (StageManager, after MapBuilder.BuildArena).
	Returns true when a grid was built; false (flat fallback) when nothing is tagged
	NavGround. The same arena table is not rebuilt twice.
]]
function HeightGrid.Build(arena: any): boolean
	if arena ~= nil and arena == builtArena and grid ~= nil then
		return true
	end
	HeightGrid.Clear()
	readBounds(arena)
	if not arena then
		return false
	end
	local include: { Instance } = {}
	local top, bottom = -math.huge, math.huge
	local function addTagged(tag: string)
		for _, inst in ipairs(CollectionService:GetTagged(tag)) do
			if inst:IsDescendantOf(workspace) then
				table.insert(include, inst)
				local parts: { BasePart } = {}
				if inst:IsA("BasePart") then
					parts[1] = inst
				else
					for _, d in ipairs(inst:GetDescendants()) do
						if d:IsA("BasePart") then
							table.insert(parts, d)
						end
					end
				end
				for _, p in ipairs(parts) do
					local r = p.Size.Magnitude / 2
					top = math.max(top, p.Position.Y + r)
					bottom = math.min(bottom, p.Position.Y - r)
				end
			end
		end
	end
	addTagged(Nav.GroundTag)
	if #include == 0 or top == -math.huge then
		return false -- no tagged ground: flat fallback
	end
	addTagged(Nav.BlockTag)
	local cell = Nav.CellSize
	local cols = math.max(1, math.ceil((bMaxX - bMinX) / cell))
	local rows = math.max(1, math.ceil((bMaxZ - bMinZ) / cell))
	if cols * rows > Nav.MaxCells then
		warn(string.format("[HeightGrid] %d x %d cells is over MaxCells; flat floor kept", cols, rows))
		return false
	end
	local g = Core.NewGrid(bMinX, bMinZ, cols, rows, cell, Nav.StepMax * cell / 4, Config.ArenaOrigin.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = include
	local startY = top + Nav.RayPad
	local down = Vector3.new(0, -(startY - bottom + Nav.RayPad), 0)
	local hits = 0
	debug.profilebegin("HeightGrid.Build")
	for j = 0, rows - 1 do
		for i = 0, cols - 1 do
			local x, z = Core.CellCentre(g, i, j)
			local hit = workspace:Raycast(Vector3.new(x, startY, z), down, params)
			if hit then
				local walk = not isBlock(hit.Instance)
				Core.Set(g, i, j, hit.Position.Y, walk)
				if walk then
					hits += 1
				end
			end
		end
	end
	debug.profileend()
	if hits == 0 then
		return false
	end
	grid = g
	builtArena = arena
	return true
end

-- Test / tool hook: use a grid made with HeightGrid.Core directly (nil = flat again).
function HeightGrid.SetGrid(g: Grid?, arena: any?)
	HeightGrid.Clear()
	readBounds(arena)
	grid = g
	builtArena = arena
end

function HeightGrid.GetGrid(): Grid?
	return grid
end

-- Ground top at (x, z).
function HeightGrid.GroundY(x: number, z: number): number
	local g = grid
	if not g then
		return Config.ArenaOrigin.Y
	end
	return Core.GroundY(g, x, z)
end

-- The same point on the ground.
function HeightGrid.Ground(v: Vector3): Vector3
	local g = grid
	if not g then
		return Vector3.new(v.X, Config.ArenaOrigin.Y, v.Z)
	end
	return Vector3.new(v.X, Core.GroundY(g, v.X, v.Z), v.Z)
end

function HeightGrid.IsWalkable(x: number, z: number): boolean
	local g = grid
	if not g then
		return true
	end
	return Core.IsWalkable(g, x, z)
end

function HeightGrid.CanStep(ax: number, az: number, bx: number, bz: number): boolean
	local g = grid
	if not g then
		return true
	end
	return Core.CanStep(g, ax, az, bx, bz)
end

-- The centre of the nearest walkable cell within `rings` cells of (x, z) (the point itself
-- when it is walkable or there is no grid), or nil.
function HeightGrid.NearestWalkable(x: number, z: number, rings: number): (number?, number?)
	local g = grid
	if not g or Core.IsWalkable(g, x, z) then
		return x, z
	end
	local ci, cj = cellOf(g, x, z)
	for ring = 1, rings do
		local best, bi, bj = math.huge, 0, 0
		for dj = -ring, ring do
			for di = -ring, ring do
				if math.abs(di) == ring or math.abs(dj) == ring then
					local i, j = ci + di, cj + dj
					if inside(g, i, j) and g.Walk[j * g.Cols + i + 1] then
						local d = di * di + dj * dj
						if d < best then
							best, bi, bj = d, i, j
						end
					end
				end
			end
		end
		if best < math.huge then
			return Core.CellCentre(g, bi, bj)
		end
	end
	return nil, nil
end

-- |dy| check between two ground heights (always true without a grid).
function HeightGrid.InBand(y1: number, y2: number, band: number): boolean
	if not grid then
		return true
	end
	return math.abs(y1 - y2) <= band
end

-- True when rp has a finished flow field.
function HeightGrid.HasField(rp: any): boolean
	local rec = fields[rp]
	return rec ~= nil and rec.Live.Ready
end

-- Unit XZ direction down rp's flow field at (x, z), or Vector3.zero (no grid, no field,
-- outside it, or already in rp's cell: seek directly).
function HeightGrid.FlowDir(rp: any, x: number, z: number): Vector3
	local g = grid
	if not g then
		return Vector3.zero
	end
	local rec = fields[rp]
	if not rec then
		return Vector3.zero
	end
	local dx, dz = Core.FlowDir(g, rec.Live, x, z)
	if dx == 0 and dz == 0 then
		return Vector3.zero
	end
	return Vector3.new(dx, 0, dz)
end

-- Walking distance (studs) from (x, z) to rp: the flow field's path distance, math.huge
-- where the field does not reach (or rp has no field yet). Without a grid: the straight XZ
-- distance to rp's root (math.huge without a root).
function HeightGrid.PathDistance(rp: any, x: number, z: number): number
	local g = grid
	if not g then
		local root = rp and rp.Root
		if not root then
			return math.huge
		end
		local p = root.Position
		local dx, dz = p.X - x, p.Z - z
		return math.sqrt(dx * dx + dz * dz)
	end
	local rec = fields[rp]
	if not rec then
		return math.huge
	end
	return Core.PathDistance(g, rec.Live, x, z)
end

-- Builds rp's field right now in one go (tests and tools; Step spreads it over frames).
function HeightGrid.BuildFieldNow(rp: any, x: number, z: number): boolean
	local g = grid
	if not g then
		return false
	end
	local rec = fields[rp]
	if not rec then
		rec = { Live = Core.NewField(), Work = Core.NewField() }
		fields[rp] = rec
	end
	if building == rp then
		building = nil
		builder.Grid = nil
		builder.Field = nil
		builder.Queued = 0
	end
	local ok = Core.BuildField(g, rec.Work, x, z, Nav.FieldRadius)
	if ok then
		rec.Live, rec.Work = rec.Work, rec.Live
	end
	return ok
end

local function liveRoot(rp: any): BasePart?
	if rp and rp.Alive and rp.Root and rp.Root.Parent then
		return rp.Root
	end
	return nil
end

function HeightGrid.Step(dt: number)
	local g = grid
	if not g or not ctx then
		return
	end
	debug.profilebegin("HeightGrid.Fields")
	local runPlayers = ctx.RunManager.GetRunPlayers()
	pruneTimer += dt
	if pruneTimer >= 2 then
		pruneTimer = 0
		for rp in pairs(fields) do
			if not table.find(runPlayers, rp) then
				fields[rp] = nil
				if building == rp then
					building = nil
					builder.Grid = nil
					builder.Field = nil
					builder.Queued = 0
				end
			end
		end
	end
	rebuildTimer += dt
	if building == nil and rebuildTimer >= Nav.FieldRebuild and #runPlayers > 0 then
		-- next living player, round robin
		for _ = 1, #runPlayers do
			robin = robin % #runPlayers + 1
			local rp = runPlayers[robin]
			local root = liveRoot(rp)
			if root then
				rebuildTimer = 0
				local rec = fields[rp]
				if not rec then
					rec = { Live = Core.NewField(), Work = Core.NewField() }
					fields[rp] = rec
				end
				local p = root.Position
				if Core.BeginField(builder, g, rec.Work, p.X, p.Z, Nav.FieldRadius) then
					building = rp
				end
				break
			end
		end
	end
	if building ~= nil then
		if Core.RunField(builder, Nav.FieldBudget) then
			local rec = fields[building]
			if rec and rec.Work.Ready then
				rec.Live, rec.Work = rec.Work, rec.Live
			end
			building = nil
		end
	end
	debug.profileend()
end

function HeightGrid.Init(c)
	ctx = c
end

function HeightGrid.Start() end

return HeightGrid
