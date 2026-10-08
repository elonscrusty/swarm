--[[
	SpatialGrid.lua
	Uniform grid of buckets on the XZ plane for fast "what is near this point" queries.
	Used for enemies (rebuilt every frame by EnemyAI) and for static arena obstacles.

	Items must have `Pos: Vector3` and `Radius: number` fields.
	Cell tables are reused between frames so a rebuild allocates nothing.

	Vertical band (maps with height, HeightGrid): while `grid.BandY` is set, QueryCircle and
	Nearest skip items whose Pos.Y is more than `grid.Band` away from it. WeaponSystem sets
	it around each weapon's hits and clears it after; nil (the default) = no filter.
]]

local SpatialGrid = {}
SpatialGrid.__index = SpatialGrid

local OFFSET = 32768 -- keeps cell coordinates positive so keys are unique integers

export type Item = { Pos: Vector3, Radius: number, [any]: any }

function SpatialGrid.new(cellSize: number)
	local self = setmetatable({}, SpatialGrid)
	self.CellSize = cellSize
	self.Cells = {} :: { [number]: { Item } }
	self.Used = {} :: { number } -- keys of non-empty cells (for cheap clearing)
	self.Count = 0
	self.BandY = nil :: number?
	self.Band = 7
	return self
end

local function key(cx: number, cz: number): number
	return (cx + OFFSET) * 65536 + (cz + OFFSET)
end

function SpatialGrid:Clear()
	for i = 1, #self.Used do
		local cell = self.Cells[self.Used[i]]
		if cell then
			table.clear(cell)
		end
	end
	table.clear(self.Used)
	self.Count = 0
end

-- Insert an item into the single cell containing its centre.
function SpatialGrid:Insert(item: Item)
	local size = self.CellSize
	local k = key(math.floor(item.Pos.X / size), math.floor(item.Pos.Z / size))
	local cell = self.Cells[k]
	if not cell then
		cell = {}
		self.Cells[k] = cell
	end
	if #cell == 0 then
		table.insert(self.Used, k)
	end
	cell[#cell + 1] = item
	self.Count += 1
end

-- Insert an item into every cell its bounding box touches (for big static obstacles).
function SpatialGrid:InsertBox(item: any, minX: number, minZ: number, maxX: number, maxZ: number)
	local size = self.CellSize
	for cx = math.floor(minX / size), math.floor(maxX / size) do
		for cz = math.floor(minZ / size), math.floor(maxZ / size) do
			local k = key(cx, cz)
			local cell = self.Cells[k]
			if not cell then
				cell = {}
				self.Cells[k] = cell
			end
			if #cell == 0 then
				table.insert(self.Used, k)
			end
			cell[#cell + 1] = item
		end
	end
	self.Count += 1
end

--[[
	Fill `out` with every item whose circle overlaps the query circle (x, z, r).
	Items are only stored in the cell of their centre, so the search widens by `pad`
	(the largest item radius you expect, default 6 studs) to catch big enemies.
	Returns the number of results.
]]
function SpatialGrid:QueryCircle(x: number, z: number, r: number, out: { Item }, pad: number?): number
	table.clear(out)
	local size = self.CellSize
	local reach = r + (pad or 6)
	local n = 0
	local bandY, band = self.BandY, self.Band
	for cx = math.floor((x - reach) / size), math.floor((x + reach) / size) do
		for cz = math.floor((z - reach) / size), math.floor((z + reach) / size) do
			local cell = self.Cells[key(cx, cz)]
			if cell then
				for i = 1, #cell do
					local item = cell[i]
					local ip = item.Pos
					local dx, dz = ip.X - x, ip.Z - z
					local rr = r + item.Radius
					if dx * dx + dz * dz <= rr * rr and (bandY == nil or math.abs(ip.Y - bandY) <= band) then
						n += 1
						out[n] = item
					end
				end
			end
		end
	end
	return n
end

-- Fill `out` with the raw contents of the cells around (x, z) (no distance check).
function SpatialGrid:QueryCells(x: number, z: number, r: number, out: { any }): number
	table.clear(out)
	local size = self.CellSize
	local n = 0
	for cx = math.floor((x - r) / size), math.floor((x + r) / size) do
		for cz = math.floor((z - r) / size), math.floor((z + r) / size) do
			local cell = self.Cells[key(cx, cz)]
			if cell then
				for i = 1, #cell do
					n += 1
					out[n] = cell[i]
				end
			end
		end
	end
	return n
end

--[[
	Nearest item to (x, z) within maxRange, skipping items for which `skip(item)` is true.
	Searches outward ring by ring so it stays cheap when something is close.
]]
function SpatialGrid:Nearest(x: number, z: number, maxRange: number, skip: ((any) -> boolean)?): (any?, number)
	local size = self.CellSize
	local ccx, ccz = math.floor(x / size), math.floor(z / size)
	local maxRing = math.ceil(maxRange / size) + 1
	local best, bestD2 = nil, maxRange * maxRange
	local bandY, band = self.BandY, self.Band
	for ring = 0, maxRing do
		for cx = ccx - ring, ccx + ring do
			for cz = ccz - ring, ccz + ring do
				-- only the border of this ring (inner cells were done already)
				if math.abs(cx - ccx) == ring or math.abs(cz - ccz) == ring then
					local cell = self.Cells[key(cx, cz)]
					if cell then
						for i = 1, #cell do
							local item = cell[i]
							if not (skip and skip(item)) and (bandY == nil or math.abs(item.Pos.Y - bandY) <= band) then
								local dx, dz = item.Pos.X - x, item.Pos.Z - z
								local d2 = dx * dx + dz * dz
								if d2 < bestD2 then
									best, bestD2 = item, d2
								end
							end
						end
					end
				end
			end
		end
		-- anything in a further ring is at least (ring * size) away
		if best and bestD2 <= (ring * size) * (ring * size) then
			break
		end
	end
	return best, math.sqrt(bestD2)
end

return SpatialGrid
