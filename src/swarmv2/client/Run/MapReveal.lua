--!nonstrict
--[[
	SwarmV2/Run/MapReveal.lua  (StarterPlayerScripts.SwarmV2Client.Run.MapReveal)
	OWNER: stream F (run UI).

	What the minimap and the big map know about the ground, for the current run.

	The authored layout: the arena model's ground is Parts tagged "NavGround" (floors, terraces,
	ramps, the bridge deck, the cave floor; CliffwoodBuilder), which replicate to the client, so the
	map is read from them: a heightless top-down grid (RunConfig.UI.Map.CellStuds studs a cell),
	built in slices (RasterBudget parts a frame) so a 1100 x 1100 map never costs a frame spike.
	No second copy of the plan is shipped and no terrain engine is used.

	Reveal: every cell within RunConfig.UI.Map.RevealRadius (80 studs) of a team member becomes
	known and stays known for this run. Every client sees every teammate's character, so each
	computes the same shared set from the same positions: "shared per team" without a remote.
	A client that joins late learns the ground only from when it joined (the reconnect gap is the
	documented limit). Reset() runs between runs, never when a map is opened or closed.

	Never shows what was not discovered: a loot position only counts as discovered once its cell
	is known (Discovered(x, z)); the draw code asks that before it places a chest marker.

	Drawing: a Canvas draws the known cells into a Frame as one frame per run of cells in a row
	(ground = light tile, known rock / drop = dark tile), only re-drawing the rows that changed.
	The small map and the big map are two canvases over the same data.
]]

local CollectionService = game:GetService("CollectionService")

local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local RunTheme = require(script.Parent.RunTheme)

local MapReveal = {}

local CFG = RunConfig.UI.Map
local CELL = CFG.CellStuds
local GROUND_TAG = (RunConfig.Nav and RunConfig.Nav.GroundTag) or "NavGround"

-- grid state
local loaded = false -- the ground tag was found for this arena
local model = nil -- the arena model the grid was built from
local minX, minZ = 0, 0 -- world position of the grid's corner
local nx, nz = 0, 0 -- cells per row / column
local ground = {} -- [row * nx + col + 1] = true for walkable ground
local known = {} -- [row * nx + col + 1] = true once revealed
local parts = {} -- ground parts still to rasterise
local partAt = 1
local dirtyRows = {} -- [row] = true: rows a canvas must redraw
local canvases = {}
local revealed = 0

function MapReveal.Loaded(): boolean
	return loaded
end

-- Centre (x, z) and the larger side (studs) of the mapped area.
function MapReveal.Bounds(): (number, number, number)
	return minX + nx * CELL / 2, minZ + nz * CELL / 2, math.max(nx, nz) * CELL
end

function MapReveal.Cell(): number
	return CELL
end

function MapReveal.RevealedCount(): number
	return revealed
end

function MapReveal.Ready(): boolean
	return loaded and partAt > #parts
end

local function idx(col: number, row: number): number
	return row * nx + col + 1
end

local function markRow(row: number)
	dirtyRows[row] = true
end

-- A whole new arena (or none): forget everything.
function MapReveal.Reset()
	loaded, model = false, nil
	ground, known, parts, partAt = {}, {}, {}, 1
	nx, nz, revealed = 0, 0, 0
	dirtyRows = {}
	for _, c in ipairs(canvases) do
		c.Clear()
	end
end

-- Forget what was revealed but keep the ground (a new run on the same arena).
function MapReveal.ResetKnown()
	known, revealed = {}, 0
	for row = 0, nz - 1 do
		markRow(row)
	end
end

--[[
	Reads the arena's ground parts. Returns true when the arena has tagged ground (the map can
	draw); false for the older arenas (the minimap keeps its obstacle silhouette there). Safe to
	call every refresh: it only rebuilds for a different model.
]]
function MapReveal.Load(arena: Instance?): boolean
	if arena == model then
		return loaded
	end
	MapReveal.Reset()
	model = arena
	if not arena then
		return false
	end
	local list = {}
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, inst in ipairs(CollectionService:GetTagged(GROUND_TAG)) do
		if inst:IsA("BasePart") and inst:IsDescendantOf(arena) then
			table.insert(list, inst)
			local cf, size = inst.CFrame, inst.Size
			-- the part's footprint corners (a tilted ramp is wider than its top face)
			for sx = -1, 1, 2 do
				for sz = -1, 1, 2 do
					local p = cf:PointToWorldSpace(Vector3.new(sx * size.X / 2, 0, sz * size.Z / 2))
					x0, x1 = math.min(x0, p.X), math.max(x1, p.X)
					z0, z1 = math.min(z0, p.Z), math.max(z1, p.Z)
				end
			end
		end
	end
	if #list == 0 then
		return false
	end
	minX, minZ = math.floor(x0 / CELL) * CELL, math.floor(z0 / CELL) * CELL
	nx, nz = math.ceil((x1 - minX) / CELL), math.ceil((z1 - minZ) / CELL)
	parts, partAt = list, 1
	loaded = true
	return true
end

-- Rasterises ground parts into the grid, at most RasterBudget parts and RasterCells cell tests per
-- call (call once a frame while not Ready). A cell is ground when its centre lies on a ground
-- part's top face (seen from above, so a ramp counts where it really is), a little forgiving at
-- the edges so a narrow road never vanishes between cells.
function MapReveal.Raster()
	if not loaded or partAt > #parts then
		return
	end
	local stop = math.min(#parts, partAt + CFG.RasterBudget - 1)
	local tested = 0
	local i = partAt
	while i <= stop and tested < CFG.RasterCells do
		local part = parts[i]
		i += 1
		if part.Parent then
			local cf, size = part.CFrame, part.Size
			local up = cf.UpVector
			if up.Y > 0.2 then
				local px0, px1, pz0, pz1 = math.huge, -math.huge, math.huge, -math.huge
				for sx = -1, 1, 2 do
					for sz = -1, 1, 2 do
						local p = cf:PointToWorldSpace(Vector3.new(sx * size.X / 2, 0, sz * size.Z / 2))
						px0, px1 = math.min(px0, p.X), math.max(px1, p.X)
						pz0, pz1 = math.min(pz0, p.Z), math.max(pz1, p.Z)
					end
				end
				local c0, c1 = math.max(0, math.floor((px0 - minX) / CELL)), math.min(nx - 1, math.floor((px1 - minX) / CELL))
				local r0, r1 = math.max(0, math.floor((pz0 - minZ) / CELL)), math.min(nz - 1, math.floor((pz1 - minZ) / CELL))
				local origin = cf.Position
				local slack = CELL * 0.45
				for row = r0, r1 do
					for col = c0, c1 do
						local gi = idx(col, row)
						if not ground[gi] then
							tested += 1
							local wx, wz = minX + (col + 0.5) * CELL, minZ + (row + 0.5) * CELL
							-- the point of the part's top plane straight above / below this cell
							local y = origin.Y - ((wx - origin.X) * up.X + (wz - origin.Z) * up.Z) / up.Y
							local lp = cf:PointToObjectSpace(Vector3.new(wx, y, wz))
							if math.abs(lp.X) <= size.X / 2 + slack and math.abs(lp.Z) <= size.Z / 2 + slack then
								ground[gi] = true
								if known[gi] then
									markRow(row)
								end
							end
						end
					end
				end
			end
		end
	end
	partAt = i
end

-- Marks every cell within `radius` studs of (x, z) known. Returns true if anything was new.
function MapReveal.RevealAround(x: number, z: number, radius: number): boolean
	if not loaded then
		return false
	end
	local c0, c1 = math.max(0, math.floor((x - radius - minX) / CELL)), math.min(nx - 1, math.floor((x + radius - minX) / CELL))
	local r0, r1 = math.max(0, math.floor((z - radius - minZ) / CELL)), math.min(nz - 1, math.floor((z + radius - minZ) / CELL))
	local fresh = false
	local r2 = radius * radius
	for row = r0, r1 do
		for col = c0, c1 do
			local gi = idx(col, row)
			if not known[gi] then
				local dx, dz = minX + (col + 0.5) * CELL - x, minZ + (row + 0.5) * CELL - z
				if dx * dx + dz * dz <= r2 then
					known[gi] = true
					revealed += 1
					markRow(row)
					fresh = true
				end
			end
		end
	end
	return fresh
end

-- Is the ground at (x, z) known? (loot is "discovered" only then)
function MapReveal.Discovered(x: number, z: number): boolean
	if not loaded then
		return false
	end
	local col, row = math.floor((x - minX) / CELL), math.floor((z - minZ) / CELL)
	if col < 0 or row < 0 or col >= nx or row >= nz then
		return false
	end
	return known[idx(col, row)] == true
end

------------------------------------------------------------------------------------------
-- Canvas: draws the known cells into a Frame
------------------------------------------------------------------------------------------

local GROUND_COLOR = RunTheme.CreamMuted:Lerp(RunTheme.Navy, 0.45)
local ROCK_COLOR = RunTheme.NavyRaised

--[[
	A canvas over `frame` (the world frame of a map, sized arena * pxPerStud): one frame per run of
	cells in a row. pxPerStud may change (SetScale); Update(budgetRows) redraws up to that many
	dirty rows and returns how many it drew. Frames are pooled per row and re-used.
]]
function MapReveal.NewCanvas(frame: Frame, pxPerStud: number)
	local canvas = { Frame = frame, Scale = pxPerStud, Rows = {}, Dirty = {}, All = true }
	local function clearRow(row: number)
		local list = canvas.Rows[row]
		if list then
			for _, f in ipairs(list) do
				f:Destroy()
			end
		end
		canvas.Rows[row] = nil
	end
	local function drawRow(row: number)
		clearRow(row)
		local list = {}
		local px = CELL * canvas.Scale
		local col = 0
		while col < nx do
			local gi = idx(col, row)
			local kind = known[gi] and (ground[gi] and "G" or "R") or nil
			if kind then
				local start = col
				while col + 1 < nx do
					local nk = known[idx(col + 1, row)] and (ground[idx(col + 1, row)] and "G" or "R") or nil
					if nk ~= kind then
						break
					end
					col += 1
				end
				local f = Instance.new("Frame")
				f.BorderSizePixel = 0
				f.BackgroundColor3 = kind == "G" and GROUND_COLOR or ROCK_COLOR
				f.BackgroundTransparency = kind == "G" and 0 or 0.35
				f.Position = UDim2.fromOffset(math.floor(start * px), math.floor(row * px))
				f.Size = UDim2.fromOffset(math.ceil((col - start + 1) * px) + 1, math.ceil(px) + 1)
				f.ZIndex = kind == "G" and 2 or 1
				f.Active = false
				f.Name = kind
				f.Parent = frame
				table.insert(list, f)
			end
			col += 1
		end
		canvas.Rows[row] = list
	end
	function canvas.Clear()
		for row in pairs(canvas.Rows) do
			clearRow(row)
		end
		canvas.All = true
	end
	function canvas.SetScale(s: number)
		if math.abs(s - canvas.Scale) > 1e-6 then
			canvas.Scale = s
			canvas.All = true
		end
	end
	function canvas.Update(budgetRows: number): number
		local drawn = 0
		if canvas.All then
			canvas.All = false
			for row = 0, nz - 1 do
				canvas.Dirty[row] = true
			end
		end
		for row in pairs(dirtyRows) do
			canvas.Dirty[row] = true
		end
		for row in pairs(canvas.Dirty) do
			if drawn >= budgetRows then
				break
			end
			canvas.Dirty[row] = nil
			drawRow(row)
			drawn += 1
		end
		return drawn
	end
	table.insert(canvases, canvas)
	return canvas
end

-- After the open canvases have taken the dirty rows (call at the end of a refresh pass). A canvas
-- that was closed redraws everything when it opens, so it never needs the rows it missed.
function MapReveal.EndPass()
	dirtyRows = {}
end

function MapReveal.Rows(): number
	return nz
end

-- For tests: how many cells are ground / known.
function MapReveal.Stats(): (number, number, number, number)
	local g = 0
	for _ in pairs(ground) do
		g += 1
	end
	return nx, nz, g, revealed
end

return MapReveal
