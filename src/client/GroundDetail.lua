--[[
	GroundDetail.lua
	Fine ground detail for the arenas: small grass tufts, a few flowers, clover / moss
	discs and pebbles (frost tufts and snow clumps on Snow, dry grass on Desert, ash
	pebbles on Lava). The floor stops looking flat without the server building thousands
	more parts: every client draws only the pieces inside its own camera footprint, from a
	fixed pool of one-part pieces that is recycled as the camera moves. Nothing replicates.

	Layout is deterministic: the arena floor is an 8-stud grid (Config.Graphics.GroundDetail
	.Cell); a hash of the cell and the arena name decides how many pieces a cell holds
	(0-4), what they are and where they sit, so every player sees the same floor and a cell
	looks the same each time the camera comes back to it. Density follows the map:
	  * low inside the spawn clearing (combat, gems and telegraphs stay readable);
	  * none on paths, hazard pools, landmark keepouts, bare floor (Ruins plaza) and
	    inside colliders; higher just beside obstacles and path edges, where clutter
	    gathers naturally;
	  * a thinner scatter on the outer ground past the boundary walls.
	The server describes the floor on the arena model (MapBuilder.writeDetailLayout:
	DetailPaths / DetailBare attributes); colliders are read from its Obstacles folder.

	Budget: MaxParts (desktop) / MaxPartsTouch (phones and tablets) pooled Parts, halved
	with Settings > Reduced effects (ReducedShare); anchored, CanCollide / CanQuery /
	CanTouch off, CastShadow off, SmoothPlastic. The footprint is re-checked UpdateHz times
	a second; pieces move with BulkMoveTo. Init() watches workspace.SwarmMap for Arena_*
	models (built and destroyed by MapBuilder); Stats() reports the live counts.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Palette = require(Shared:WaitForChild("Palette"))
local ClientSettings = require(script.Parent:WaitForChild("ClientSettings"))
local ClientPerformance = require(script.Parent:WaitForChild("ClientPerformance"))

local GroundDetail = {}

local P = Palette :: { [string]: Color3 }
local S = (Config.Graphics :: any).GroundDetail or {}
local CELL: number = S.Cell or 8
local MAX_PARTS: number = S.MaxParts or 300
local MAX_PARTS_TOUCH: number = S.MaxPartsTouch or 170
local REDUCED_SHARE: number = S.ReducedShare or 0.5
local UPDATE_EVERY = 1 / math.max(1, S.UpdateHz or 8)
local CLEARING_DENSITY: number = S.ClearingDensity or 0.4
local EDGE_BOOST: number = S.EdgeBoost or 1.7
local OUTER_DENSITY: number = S.OuterDensity or 0.55
local MAX_PER_CELL = 4
local OUTER_REACH = 44 -- studs past the boundary the outer scatter goes
local EDGE_NEAR = 6 -- studs from a collider / path edge that count as "beside it"
local PARK = CFrame.new(0, -600, 0) -- idle pool pieces wait here
local TAU = math.pi * 2

local FLOOR_Y: number = Config.ArenaOrigin.Y
local HALF: number = (Config.Arenas.Size or 400) / 2
local CLEAR: number = Config.Arenas.ClearRadius or 40

local function mix(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, t)
end

------------------------------------------------------------------------------------------
-- RECIPES: what grows on each floor. Kinds: Tuft (upright blade cluster), Flower (small
-- ball on the grass), Disc (flat clover / moss / snow / ash patch), Pebble (tilted block).
-- Tones stay one step from the floor so creatures and gems keep their contrast.
------------------------------------------------------------------------------------------

type Kind = { K: string, W: number, C: { Color3 }, S: number, M: Enum.Material? } -- weight, colours, size mult, material (default SmoothPlastic)
type Recipe = { Density: number, Kinds: { Kind }, Total: number }

local function recipe(density: number, kinds: { Kind }): Recipe
	local total = 0
	for _, k in ipairs(kinds) do
		total += k.W
	end
	return { Density = density, Kinds = kinds, Total = total }
end

local RECIPES: { [string]: Recipe } = {
	-- Forest (owner's meadow reference): tufts in related greens around the lawn floor, white
	-- and buttercup flowers, moss / clover discs on the floor's Grass material, few pebbles
	Forest = recipe(1.0, {
		{ K = "Tuft", W = 48, C = { P.lawn_600, mix(P.lawn_500, P.lawn_olive, 0.4), P.lawn_400, P.lawn_700 }, S = 1 },
		{ K = "Flower", W = 10, C = { P.ivory_100, P.ivory_100, P.bloom_yellow }, S = 1 },
		{ K = "Disc", W = 10, C = { mix(P.lawn_500, P.lawn_600, 0.5), mix(P.lawn_500, P.lawn_olive, 0.3) }, S = 1.2, M = Enum.Material.Grass },
		{ K = "Pebble", W = 5, C = { P.stone_400, P.stone_300 }, S = 1 },
	}),
	Ruins = recipe(0.85, {
		{ K = "Tuft", W = 44, C = { P.meadow_600, mix(P.meadow_600, P.meadow_700, 0.4), mix(P.meadow_300, P.meadow_400, 0.5) }, S = 1 },
		{ K = "Flower", W = 10, C = { P.ivory_100, P.ivory_100, P.gold_300 }, S = 1 },
		{ K = "Disc", W = 12, C = { mix(P.meadow_600, P.meadow_700, 0.3), mix(P.meadow_400, P.pave_300, 0.3) }, S = 1 },
		{ K = "Pebble", W = 16, C = { P.pave_400, P.pave_300, P.stone_400 }, S = 1 },
	}),
	Swamp = recipe(1.0, {
		{ K = "Tuft", W = 50, C = { mix(P.fen_700, P.murk_600, 0.3), P.fen_600, P.fen_300 }, S = 1.15 },
		{ K = "Disc", W = 22, C = { mix(P.fen_600, P.peat_500, 0.35), mix(P.fen_400, P.fen_300, 0.5) }, S = 1.1 },
		{ K = "Pebble", W = 9, C = { mix(P.stone_600, P.murk_600, 0.3), P.stone_500 }, S = 1 },
	}),
	Snow = recipe(0.6, {
		{ K = "Tuft", W = 26, C = { mix(P.snow_200, P.ice_300, 0.3), mix(P.snow_400, P.stone_400, 0.3) }, S = 0.85 },
		{ K = "Disc", W = 30, C = { P.snow_100, mix(P.snow_200, P.snow_100, 0.5) }, S = 1 },
		{ K = "Pebble", W = 14, C = { mix(P.stone_400, P.snow_400, 0.4), P.stone_500 }, S = 1 },
	}),
	Desert = recipe(0.55, {
		{ K = "Tuft", W = 32, C = { P.sand_600, mix(P.sand_600, P.dirt_300, 0.5), mix(P.sand_700, P.dirt_400, 0.4) }, S = 0.9 },
		{ K = "Disc", W = 14, C = { mix(P.sand_300, P.sand_200, 0.4), mix(P.sand_500, P.clay_500, 0.15) }, S = 1 },
		{ K = "Pebble", W = 26, C = { P.sand_600, mix(P.sand_700, P.stone_500, 0.4), P.stone_400 }, S = 1 },
	}),
	Lava = recipe(0.5, {
		{ K = "Pebble", W = 44, C = { P.basalt_600, P.basalt_500, mix(P.cinder_600, P.basalt_700, 0.4) }, S = 1.1 },
		{ K = "Disc", W = 24, C = { mix(P.cinder_300, P.cinder_200, 0.4), mix(P.cinder_500, P.cinder_600, 0.4) }, S = 1 },
		{ K = "Tuft", W = 6, C = { mix(P.cinder_500, P.murk_500, 0.5) }, S = 0.8 }, -- a rare burnt tuft
	}),
}

------------------------------------------------------------------------------------------
-- ARENA CONTEXT (read once per arena model)
------------------------------------------------------------------------------------------

type Seg = { AX: number, AZ: number, BX: number, BZ: number, W: number }
type Circle = { X: number, Z: number, R: number }
type Box = { MinX: number, MaxX: number, MinZ: number, MaxZ: number }

type Ctx = {
	Model: Model,
	Name: string,
	Recipe: Recipe,
	Seed: number,
	CX: number,
	CZ: number,
	Paths: { Seg },
	Bare: { Circle },
	Circles: { Circle }, -- cylinder colliders (arena-relative)
	Boxes: { Box }, -- box colliders (arena-relative)
	Cliffs: boolean, -- rock cliffs line the north / west / east edges (MapBuilder)
}

local player = Players.LocalPlayer
local ctx: Ctx? = nil

local function parseSegs(s: any): { Seg }
	local out = {}
	if type(s) ~= "string" then
		return out
	end
	for ax, az, bx, bz, w in string.gmatch(s, "([%d.%-]+),([%d.%-]+),([%d.%-]+),([%d.%-]+),([%d.%-]+)") do
		table.insert(out, { AX = tonumber(ax) or 0, AZ = tonumber(az) or 0, BX = tonumber(bx) or 0, BZ = tonumber(bz) or 0, W = tonumber(w) or 0 })
	end
	return out
end

local function parseCircles(s: any): { Circle }
	local out = {}
	if type(s) ~= "string" then
		return out
	end
	for x, z, r in string.gmatch(s, "([%d.%-]+),([%d.%-]+),([%d.%-]+)") do
		table.insert(out, { X = tonumber(x) or 0, Z = tonumber(z) or 0, R = tonumber(r) or 0 })
	end
	return out
end

local function hashSeed(name: string): number
	local h = 5381
	for i = 1, #name do
		h = (h * 33 + string.byte(name, i)) % 2147483647
	end
	return h
end

local function readArena(model: Model): Ctx
	local name = string.sub(model.Name, 7) -- "Arena_Forest"
	local c = Config.ArenaOrigin
	local circles, boxes = {}, {}
	local folder = model:FindFirstChild("Obstacles")
	if folder then
		for _, p in ipairs(folder:GetChildren()) do
			if p:IsA("BasePart") then
				local pos = p.Position
				local size = p.Size
				if p:IsA("Part") and p.Shape == Enum.PartType.Cylinder then
					-- MapBuilder turns the cylinder upright: Size.X is its height
					table.insert(circles, { X = pos.X - c.X, Z = pos.Z - c.Z, R = size.Y / 2 })
				else
					local hx, hz = size.X / 2, size.Z / 2
					table.insert(boxes, { MinX = pos.X - c.X - hx, MaxX = pos.X - c.X + hx, MinZ = pos.Z - c.Z - hz, MaxZ = pos.Z - c.Z + hz })
				end
			end
		end
	end
	return {
		Model = model,
		Name = name,
		Recipe = RECIPES[name] or RECIPES.Forest,
		Seed = hashSeed(name),
		CX = c.X,
		CZ = c.Z,
		Paths = parseSegs(model:GetAttribute("DetailPaths")),
		Bare = parseCircles(model:GetAttribute("DetailBare")),
		Circles = circles,
		Boxes = boxes,
		Cliffs = model:GetAttribute("Cliffs") == true,
	}
end

-- Signed distance from (x, z) to the nearest path edge (negative = on the path).
local function pathDistance(a: Ctx, x: number, z: number): number
	local best = math.huge
	for _, seg in ipairs(a.Paths) do
		local dx, dz = seg.BX - seg.AX, seg.BZ - seg.AZ
		local len2 = dx * dx + dz * dz
		local t = len2 > 0 and math.clamp(((x - seg.AX) * dx + (z - seg.AZ) * dz) / len2, 0, 1) or 0
		local px, pz = seg.AX + dx * t - x, seg.AZ + dz * t - z
		local d = math.sqrt(px * px + pz * pz) - seg.W
		if d < best then
			best = d
		end
	end
	return best
end

-- Signed distance to the nearest collider edge (negative = inside one).
local function obstacleDistance(a: Ctx, x: number, z: number): number
	local best = math.huge
	for _, ob in ipairs(a.Circles) do
		local dx, dz = ob.X - x, ob.Z - z
		local d = math.sqrt(dx * dx + dz * dz) - ob.R
		if d < best then
			best = d
		end
	end
	for _, b in ipairs(a.Boxes) do
		local dx = math.max(b.MinX - x, 0, x - b.MaxX)
		local dz = math.max(b.MinZ - z, 0, z - b.MaxZ)
		local d
		if dx == 0 and dz == 0 then
			d = -math.min(x - b.MinX, b.MaxX - x, z - b.MinZ, b.MaxZ - z)
		else
			d = math.sqrt(dx * dx + dz * dz)
		end
		if d < best then
			best = d
		end
	end
	return best
end

local function inBare(a: Ctx, x: number, z: number): boolean
	for _, k in ipairs(a.Bare) do
		local dx, dz = k.X - x, k.Z - z
		if dx * dx + dz * dz < k.R * k.R then
			return true
		end
	end
	return false
end

-- Density share at an arena-relative point: 0 where nothing may grow, up to EDGE_BOOST.
local function densityAt(a: Ctx, x: number, z: number): number
	local ax, az = math.abs(x), math.abs(z)
	if ax > HALF + OUTER_REACH or az > HALF + OUTER_REACH then
		return 0
	end
	local outer = ax > HALF - 2 or az > HALF - 2
	if not outer then
		if inBare(a, x, z) then
			return 0
		end
	end
	local pd = pathDistance(a, x, z)
	if pd < 0.6 then
		return 0
	end
	if outer then
		-- past the cliffs (north / west / east) the floor is under rock, and so is the strip
		-- under the camera-side rim and the stepped corners (MapBuilder.cliffs): nothing to draw
		if a.Cliffs and (z < HALF - 2 or (z > HALF + 0.3 and z < HALF + 10) or (ax > HALF and z < HALF + 31)) then
			return 0
		end
		return OUTER_DENSITY
	end
	local od = obstacleDistance(a, x, z)
	if od < 0.8 then
		return 0
	end
	local d = 1
	local r = math.sqrt(x * x + z * z)
	if r < CLEAR * 0.8 then
		d = CLEARING_DENSITY
	elseif r < CLEAR * 1.1 then
		d = CLEARING_DENSITY + (1 - CLEARING_DENSITY) * (r - CLEAR * 0.8) / (CLEAR * 0.3)
	end
	if od < EDGE_NEAR or pd < EDGE_NEAR then
		d *= EDGE_BOOST
	end
	return d
end

------------------------------------------------------------------------------------------
-- DETERMINISTIC CELL CONTENT
------------------------------------------------------------------------------------------

-- Small integer hash → 0..1 (fixed per cell / slot / arena).
local function frac(a: Ctx, cx: number, cz: number, slot: number): number
	local h = bit32.bxor(cx * 73856093, cz * 19349663, slot * 83492791, a.Seed)
	h = (h * 1664525 + 1013904223) % 4294967296
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return (h % 1000003) / 1000003
end

type Piece = { Kind: Kind, CF: CFrame, Size: Vector3, Color: Color3, Shape: Enum.PartType, Material: Enum.Material? }

local function pickKind(a: Ctx, roll: number): Kind
	local acc = roll * a.Recipe.Total
	for _, k in ipairs(a.Recipe.Kinds) do
		acc -= k.W
		if acc <= 0 then
			return k
		end
	end
	return a.Recipe.Kinds[#a.Recipe.Kinds]
end

local function makePiece(a: Ctx, kind: Kind, x: number, z: number, r1: number, r2: number, r3: number): Piece
	local wx, wz = a.CX + x, a.CZ + z
	local yaw = r1 * TAU
	local s = kind.S * (0.8 + r2 * 0.5)
	if kind.K == "Tuft" then
		-- Slim upright blades, rooted together and splayed slightly. Their narrow depth
		-- avoids the broad triangular faces of the old single-wedge decoration.
		local height = (0.65 + r3 * 0.55) * s
		local size = Vector3.new((0.10 + r2 * 0.05) * s, height, 0.09 * s)
		local cf = CFrame.new(wx, FLOOR_Y + 0.07, wz) * CFrame.Angles(0, yaw, (r3 - 0.5) * 0.45) * CFrame.new(0, height / 2, 0)
		return { Kind = kind, CF = cf, Size = size, Color = kind.C[1 + math.floor(r3 * #kind.C) % #kind.C], Shape = Enum.PartType.Block }
	elseif kind.K == "Flower" then
		local d = (0.42 + r3 * 0.2) * s
		local cf = CFrame.new(wx, FLOOR_Y + 0.3 + d * 0.3, wz)
		return { Kind = kind, CF = cf, Size = Vector3.new(d, d, d), Color = kind.C[1 + math.floor(r2 * #kind.C) % #kind.C], Shape = Enum.PartType.Ball }
	elseif kind.K == "Disc" then
		local d = (0.7 + r3 * 0.8) * s
		-- an upright-axis cylinder: Size.X is the thickness
		local cf = CFrame.new(wx, FLOOR_Y + 0.1 - 0.03, wz) * CFrame.Angles(0, yaw, math.rad(90))
		return { Kind = kind, CF = cf, Size = Vector3.new(0.06, d, d), Color = kind.C[1 + math.floor(r2 * #kind.C) % #kind.C], Shape = Enum.PartType.Cylinder, Material = kind.M }
	end
	local size = Vector3.new((0.5 + r3 * 0.35) * s, 0.32 * s, (0.4 + r2 * 0.3) * s)
	local cf = CFrame.new(wx, FLOOR_Y + 0.06 + size.Y * 0.3, wz) * CFrame.Angles(0.15, yaw, 0.1)
	return { Kind = kind, CF = cf, Size = size, Color = kind.C[1 + math.floor(r3 * #kind.C) % #kind.C], Shape = Enum.PartType.Block }
end

------------------------------------------------------------------------------------------
-- PATH DETAIL (owner: "make the pathways more detailed"): stones lining the path edges and
-- wear on the path itself, per arena: ruts, pebbles and roots in the Forest, puddles and
-- boards in the Swamp, footprints in the Snow, cart tracks in the Desert, cinders on Lava.
-- Same pool and the same deterministic cells as the rest; only cells on a path get them.
------------------------------------------------------------------------------------------

-- Fringe (optional): grass that grows over the soft path margin, so the edge reads
-- gently irregular instead of a ruled line: flat grass-coloured lobes (material M, under
-- the path core) and short tufts, FringeChance per margin sample.
type PathRecipe = {
	Edge: { Color3 },
	EdgeChance: number,
	Worn: { { K: string, C: { Color3 } } },
	WornChance: number,
	Fringe: { C: { Color3 }, Tuft: { Color3 }, M: Enum.Material? }?,
	FringeChance: number?,
}

local PATH_RECIPES: { [string]: PathRecipe } = {
	Forest = {
		-- occasional small pebbles at the margin (was a near-continuous stone line)
		Edge = { P.stone_400, P.stone_300, mix(P.stone_400, P.soil_500, 0.3) },
		EdgeChance = 0.18,
		-- soft soil variation on the path: darker and lighter worn spots, a few pebbles
		-- and an odd root (all flat or low; the path stays smooth to walk)
		Worn = { { K = "Rut", C = { P.soil_500, mix(P.soil_400, P.soil_600, 0.35) } }, { K = "Rut", C = { P.soil_300 } }, { K = "Pebble", C = { P.stone_400, P.soil_300 } }, { K = "Root", C = { P.wood_600, P.wood_700 } } },
		WornChance = 0.5,
		Fringe = { C = { P.lawn_500, mix(P.lawn_500, P.lawn_600, 0.4) }, Tuft = { P.lawn_600, P.lawn_400, mix(P.lawn_500, P.lawn_olive, 0.4) }, M = Enum.Material.Grass },
		FringeChance = 0.7,
	},
	Ruins = {
		Edge = { P.pave_300, P.pave_400, P.stone_400 },
		EdgeChance = 0.7,
		Worn = { { K = "Rut", C = { mix(P.pave_400, P.dirt_400, 0.5) } }, { K = "Pebble", C = { P.pave_400, P.pave_300 } } },
		WornChance = 0.4,
	},
	Swamp = {
		Edge = { mix(P.stone_600, P.murk_600, 0.3), mix(P.stone_500, P.fen_600, 0.4) },
		EdgeChance = 0.6,
		Worn = { { K = "Puddle", C = { mix(P.fen_700, P.slate_600, 0.55), mix(P.murk_700, P.slate_500, 0.4) } }, { K = "Plank", C = { mix(P.wood_600, P.murk_600, 0.3), P.wood_700 } }, { K = "Rut", C = { mix(P.peat_500, P.fen_600, 0.3) } } },
		WornChance = 0.55,
	},
	Snow = {
		Edge = { mix(P.stone_400, P.snow_400, 0.4), P.snow_100, mix(P.stone_500, P.slate_400, 0.3) },
		EdgeChance = 0.6,
		Worn = { { K = "Print", C = { mix(P.snow_300, P.slate_400, 0.25) } }, { K = "Print", C = { mix(P.snow_300, P.slate_400, 0.25) } }, { K = "Rut", C = { mix(P.snow_300, P.ice_300, 0.4) } } },
		WornChance = 0.6,
	},
	Desert = {
		Edge = { P.sand_600, mix(P.sand_700, P.stone_500, 0.4), mix(P.sand_600, P.clay_500, 0.3) },
		EdgeChance = 0.55,
		Worn = { { K = "Track", C = { mix(P.sand_600, P.dirt_400, 0.35) } }, { K = "Pebble", C = { P.sand_700, P.stone_400 } } },
		WornChance = 0.55,
	},
	Lava = {
		Edge = { P.basalt_600, P.basalt_500, mix(P.cinder_600, P.basalt_700, 0.4) },
		EdgeChance = 0.7,
		Worn = { { K = "Rut", C = { mix(P.cinder_600, P.basalt_600, 0.5) } }, { K = "Pebble", C = { P.basalt_600, P.cinder_500 } } },
		WornChance = 0.45,
	},
}
local PATH_KIND: Kind = { K = "Path", W = 0, C = {}, S = 1 }
-- the highest path slab top above the floor (MapBuilder dirtPath: cores 0.28 .. 0.34);
-- worn pieces sit 0.02+ above it so none shares a height with a core slab (flicker)
local PATH_TOP = 0.36
local FRINGE_TOP = 0.25 -- above the margin slabs (0.12 .. 0.18) and under the cores (0.28+)

-- Nearest path: signed distance to its outer edge and the segment's heading (radians).
local function pathNear(a: Ctx, x: number, z: number): (number, number)
	local best, heading = math.huge, 0
	for _, seg in ipairs(a.Paths) do
		local dx, dz = seg.BX - seg.AX, seg.BZ - seg.AZ
		local len2 = dx * dx + dz * dz
		local t = len2 > 0 and math.clamp(((x - seg.AX) * dx + (z - seg.AZ) * dz) / len2, 0, 1) or 0
		local px, pz = seg.AX + dx * t - x, seg.AZ + dz * t - z
		local d = math.sqrt(px * px + pz * pz) - seg.W
		if d < best then
			best, heading = d, math.atan2(dx, dz)
		end
	end
	return best, heading
end

local function pathPiece(a: Ctx, kind: string, color: Color3, x: number, z: number, heading: number, r1: number, r2: number, out: { Piece }, material: Enum.Material?)
	local wx, wz = a.CX + x, a.CZ + z
	local y = FLOOR_Y + PATH_TOP
	local along = CFrame.Angles(0, heading, 0) -- local Z runs along the path
	local function add(size: Vector3, cf: CFrame, shape: Enum.PartType?)
		table.insert(out, { Kind = PATH_KIND, CF = cf, Size = size, Color = color, Shape = shape or Enum.PartType.Block })
	end
	if kind == "Edge" then
		local s = 0.75 + r1 * 0.55
		add(Vector3.new(1.0 * s, 0.45 * s, 0.8 * s), CFrame.new(wx, y + 0.02, wz) * CFrame.Angles(0.12, r2 * TAU, 0.1))
	elseif kind == "Rut" then
		local d = 1.0 + r1 * 1.1
		add(Vector3.new(0.04, d, d), CFrame.new(wx, y + 0.02, wz) * CFrame.Angles(0, r2 * TAU, math.rad(90)), Enum.PartType.Cylinder)
	elseif kind == "Pebble" then
		local s = 0.35 + r1 * 0.3
		add(Vector3.new(s, s * 0.5, s * 0.8), CFrame.new(wx, y + s * 0.15, wz) * CFrame.Angles(0.2, r2 * TAU, 0.15))
	elseif kind == "Root" then
		-- a root crossing the path, half buried
		add(Vector3.new(3.2 + r1 * 2, 0.28, 0.32), CFrame.new(wx, y + 0.04, wz) * along * CFrame.Angles(0, (r2 - 0.5) * 0.8, (r1 - 0.5) * 0.08))
	elseif kind == "Plank" then
		-- boards laid across the soft track
		local yaw = (r2 - 0.5) * 0.3
		add(Vector3.new(3.4 + r1, 0.18, 0.75), CFrame.new(wx, y + 0.06, wz) * along * CFrame.Angles(0, yaw, 0))
		add(Vector3.new(3.1 + r2, 0.18, 0.7), CFrame.new(wx, y + 0.06, wz) * along * CFrame.Angles(0, yaw + (r1 - 0.5) * 0.2, 0) * CFrame.new(0.2, 0, 0.95))
	elseif kind == "Puddle" then
		local d = 1.6 + r1 * 1.6
		add(Vector3.new(0.05, d, d), CFrame.new(wx, y + 0.03, wz) * CFrame.Angles(0, r2 * TAU, math.rad(90)), Enum.PartType.Cylinder)
	elseif kind == "Print" then
		-- a pair of boot prints, heading along the path either way
		local flip = r2 < 0.5 and 0 or math.pi
		local base = CFrame.new(wx, y + 0.02, wz) * along * CFrame.Angles(0, flip + (r1 - 0.5) * 0.3, 0)
		add(Vector3.new(0.42, 0.04, 0.75), base * CFrame.new(-0.3, 0, 0))
		add(Vector3.new(0.42, 0.04, 0.75), base * CFrame.new(0.3, 0, 1.1))
	elseif kind == "Fringe" then
		-- a flat grass lobe over the margin (under the core: it only eats the margin band)
		local d = 1.6 + r1 * 1.6
		table.insert(out, { Kind = PATH_KIND, CF = CFrame.new(wx, FLOOR_Y + FRINGE_TOP - 0.02, wz) * CFrame.Angles(0, r2 * TAU, math.rad(90)), Size = Vector3.new(0.04, d, d), Color = color, Shape = Enum.PartType.Cylinder, Material = material })
	elseif kind == "Track" then
		-- two cart-wheel grooves along the path
		local len = 4 + r1 * 3
		add(Vector3.new(0.3, 0.04, len), CFrame.new(wx, y + 0.02, wz) * along * CFrame.new(-1.1, 0, 0))
		add(Vector3.new(0.3, 0.04, len), CFrame.new(wx, y + 0.02, wz) * along * CFrame.new(1.1, 0, 0))
	end
end

-- Path detail of one cell (appended to `out`).
local function pathCellPieces(a: Ctx, cx: number, cz: number, out: { Piece })
	local pr = PATH_RECIPES[a.Name]
	if not pr or #a.Paths == 0 then
		return
	end
	local x0, z0 = cx * CELL, cz * CELL
	local near = pathDistance(a, x0 + CELL / 2, z0 + CELL / 2)
	if near > CELL * 0.75 then
		return
	end
	for i = 1, 3 do
		local x = x0 + frac(a, cx, cz, 40 + i * 5) * CELL
		local z = z0 + frac(a, cx, cz, 41 + i * 5) * CELL
		local ax, az = math.abs(x), math.abs(z)
		if ax > HALF - 1 or az > HALF - 1 then
			continue
		end
		local pd, heading = pathNear(a, x, z)
		local r0, r1, r2 = frac(a, cx, cz, 42 + i * 5), frac(a, cx, cz, 43 + i * 5), frac(a, cx, cz, 44 + i * 5)
		local fringe = pr.Fringe
		if fringe and pd > -1.0 and pd < 0.4 and r0 >= pr.EdgeChance and r0 < pr.EdgeChance + (pr.FringeChance or 0) then
			if r2 < 0.6 then
				pathPiece(a, "Fringe", fringe.C[1 + math.floor(r1 * #fringe.C) % #fringe.C], x, z, heading, r1, r2, out, fringe.M)
			else
				-- a short tuft leaning over the margin
				local tuft: Kind = { K = "Tuft", W = 0, C = fringe.Tuft, S = 0.85 }
				for blade = 1, 3 do
					local angle = r1 * TAU + blade * 2.4
					table.insert(out, makePiece(a, tuft, x + math.cos(angle) * 0.15, z + math.sin(angle) * 0.15, (r1 + blade * 0.27) % 1, (r2 + blade * 0.31) % 1, (r0 + blade * 0.23) % 1))
				end
			end
		elseif pd > -1.8 and pd < -0.5 then
			if r0 < pr.EdgeChance then
				pathPiece(a, "Edge", pr.Edge[1 + math.floor(r1 * #pr.Edge) % #pr.Edge], x, z, heading, r1, r2, out)
			end
		elseif pd < -2.4 and r0 < pr.WornChance and not inBare(a, x, z) then
			local w = pr.Worn[1 + math.floor(r1 * 7.3 * #pr.Worn) % #pr.Worn]
			pathPiece(a, w.K, w.C[1 + math.floor(r2 * #w.C) % #w.C], x, z, heading, r1, r2, out)
		end
	end
end

-- The pieces of one grid cell (empty when the floor there is bare).
local function cellPieces(a: Ctx, cx: number, cz: number): { Piece }
	local out = {}
	pathCellPieces(a, cx, cz, out)
	local x0, z0 = cx * CELL, cz * CELL
	local density = a.Recipe.Density * densityAt(a, x0 + CELL / 2, z0 + CELL / 2)
	if density <= 0 then
		return out
	end
	-- about 1.3 pieces per open cell at density 1 (a piece per ~50 studs²)
	local n = math.floor(density * 1.3 + frac(a, cx, cz, 0))
	n = math.min(MAX_PER_CELL, n)
	for i = 1, n do
		local x = x0 + frac(a, cx, cz, i * 4 + 1) * CELL
		local z = z0 + frac(a, cx, cz, i * 4 + 2) * CELL
		if densityAt(a, x, z) > 0 then
			local kind = pickKind(a, frac(a, cx, cz, i * 4 + 3))
				local r1, r2, r3 = frac(a, cx, cz, i * 4 + 4), frac(a, cx, cz, i * 4 + 5), frac(a, cx, cz, i * 4 + 6)
				if kind.K == "Tuft" then
					for blade = 1, 4 do
						local angle = r1 * TAU + blade * 2.4
						local spread = 0.12 + 0.07 * (blade % 3)
						table.insert(out, makePiece(a, kind, x + math.cos(angle) * spread, z + math.sin(angle) * spread,
							(r1 + blade * 0.27) % 1, (r2 + blade * 0.31) % 1, (r3 + blade * 0.23) % 1))
					end
				else
					table.insert(out, makePiece(a, kind, x, z, r1, r2, r3))
				end
		end
	end
	return out
end

------------------------------------------------------------------------------------------
-- POOL AND FOOTPRINT
------------------------------------------------------------------------------------------

local folder: Folder? = nil
local pool: { Part } = {}
local free: { Part } = {}
local active: { [number]: { Part } } = {} -- cell key → parts placed there
local activeCount = 0
local budget = MAX_PARTS

local function cellKey(cx: number, cz: number): number
	return (cx + 32768) * 65536 + (cz + 32768)
end

local function isTouchDevice(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function refreshBudget()
	local max = isTouchDevice() and MAX_PARTS_TOUCH or MAX_PARTS
	if ClientSettings.Reduced() or ClientPerformance.Reduced() then
		max = math.floor(max * REDUCED_SHARE)
	end
	budget = math.max(0, max)
end

local function ensureFolder(): Folder
	if folder and folder.Parent then
		return folder
	end
	local f = Instance.new("Folder")
	f.Name = "SwarmGroundDetail"
	f.Parent = workspace
	folder = f
	return f
end

local function newPart(): Part
	local p = Instance.new("Part")
	p.Name = "Detail"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = PARK
	p.Parent = ensureFolder()
	return p
end

-- A pooled part for `used` pieces already placed this update, or nil at the budget.
-- Parts are never destroyed: a budget that shrank (Reduced effects, a slow device) only
-- stops them being handed out, so a device at the edge never churns Instances.
local function claim(used: number): Part?
	if used >= budget then
		return nil
	end
	local p = table.remove(free)
	if p then
		return p
	end
	p = newPart()
	table.insert(pool, p)
	return p
end

local parkParts: { Part } = {}
local parkCFs: { CFrame } = {}

local function releaseCell(key: number)
	local list = active[key]
	if not list then
		return
	end
	for _, p in ipairs(list) do
		table.insert(parkParts, p)
		table.insert(parkCFs, PARK)
		table.insert(free, p)
	end
	activeCount -= #list
	active[key] = nil
end

local function releaseAll()
	for key in pairs(active) do
		releaseCell(key)
	end
	if #parkParts > 0 then
		workspace:BulkMoveTo(parkParts, parkCFs, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(parkParts)
		table.clear(parkCFs)
	end
end

-- Camera footprint on the floor, in cells: the view trapezoid of the run camera (pitch
-- ~55°, looking along -Z) approximated by a rectangle in camera-yaw space, padded by a cell.
local function footprint(cam: Camera): (number?, number?, number?, number?, Vector3?, Vector3?, Vector3?)
	local cf = cam.CFrame
	local eye = cf.Position
	local look = cf.LookVector
	if look.Y >= -0.05 or eye.Y <= FLOOR_Y + 2 then
		return nil, nil, nil, nil, nil, nil, nil
	end
	local t = (eye.Y - FLOOR_Y) / -look.Y
	local focus = eye + look * t
	local h = eye.Y - FLOOR_Y
	local fov = math.rad(cam.FieldOfView) / 2
	local vp = cam.ViewportSize
	local aspect = vp.Y > 0 and vp.X / vp.Y or 1.78
	local pitch = math.asin(-look.Y)
	-- far / near edge of the view on the floor, along the camera's forward direction
	local farAng = math.max(math.rad(8), pitch - fov)
	local nearAng = math.min(math.rad(89), pitch + fov)
	local far = h / math.tan(farAng) - t * math.cos(pitch)
	local near = h / math.tan(nearAng) - t * math.cos(pitch)
	local halfW = (h / math.sin(farAng)) * math.tan(fov) * aspect
	local fwd = Vector3.new(look.X, 0, look.Z)
	fwd = fwd.Magnitude > 0.01 and fwd.Unit or Vector3.new(0, 0, -1)
	local right = Vector3.new(-fwd.Z, 0, fwd.X)
	return near - CELL, far + CELL, halfW + CELL, 0, focus, fwd, right
end

local function update(cam: Camera)
	local a = ctx
	if not a then
		return
	end
	local near, far, halfW, _, focus, fwd, right = footprint(cam)
	if not near or not far or not halfW or not focus or not fwd or not right then
		releaseAll()
		return
	end
	-- AABB of the footprint (arena-relative) → candidate cells
	local corners = {
		focus + fwd * near - right * halfW,
		focus + fwd * near + right * halfW,
		focus + fwd * far - right * halfW,
		focus + fwd * far + right * halfW,
	}
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(corners) do
		local x, z = p.X - a.CX, p.Z - a.CZ
		minX, maxX = math.min(minX, x), math.max(maxX, x)
		minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
	end
	local limit = HALF + OUTER_REACH
	minX, maxX = math.max(minX, -limit), math.min(maxX, limit)
	minZ, maxZ = math.max(minZ, -limit), math.min(maxZ, limit)
	local cx0, cx1 = math.floor(minX / CELL), math.floor(maxX / CELL)
	local cz0, cz1 = math.floor(minZ / CELL), math.floor(maxZ / CELL)

	local wanted: { [number]: boolean } = {}
	local toPlace: { { number } } = {}
	local fx, fz = focus.X - a.CX, focus.Z - a.CZ
	for cx = cx0, cx1 do
		for cz = cz0, cz1 do
			-- inside the trapezoid (in camera space)?
			local mx, mz = (cx + 0.5) * CELL - fx, (cz + 0.5) * CELL - fz
			local along = mx * fwd.X + mz * fwd.Z
			local side = mx * right.X + mz * right.Z
			if along >= near and along <= far and math.abs(side) <= halfW then
				local key = cellKey(cx, cz)
				wanted[key] = true
				if not active[key] then
					table.insert(toPlace, { cx, cz, key, along * along + side * side })
				end
			end
		end
	end
	for key in pairs(active) do
		if not wanted[key] then
			releaseCell(key)
		end
	end
	-- nearest new cells first, so the budget is spent where the player looks
	table.sort(toPlace, function(p, q)
		return p[4] < q[4]
	end)
	local moveParts: { Part } = parkParts
	local moveCFs: { CFrame } = parkCFs
	local used = activeCount
	for _, cell in ipairs(toPlace) do
		local pieces = cellPieces(a, cell[1], cell[2])
		local placed = {}
		for _, piece in ipairs(pieces) do
			local p = claim(used)
			if not p then
				break
			end
			used += 1
			p.Shape = piece.Shape
			p.Size = piece.Size
			p.Color = piece.Color
			p.Material = piece.Material or Enum.Material.SmoothPlastic
			table.insert(moveParts, p)
			table.insert(moveCFs, piece.CF)
			table.insert(placed, p)
		end
		active[cell[3]] = placed
		activeCount += #placed
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCFs, Enum.BulkMoveMode.FireCFrameChanged)
		table.clear(moveParts)
		table.clear(moveCFs)
	end
end

------------------------------------------------------------------------------------------
-- ARENA WATCH
------------------------------------------------------------------------------------------

local function setArena(model: Model?)
	releaseAll()
	if model then
		ctx = readArena(model)
	else
		ctx = nil
	end
end

local function isArena(inst: Instance): boolean
	return inst:IsA("Model") and string.sub(inst.Name, 1, 6) == "Arena_"
end

local function watchMap(map: Instance)
	map.ChildAdded:Connect(function(child)
		if isArena(child) then
			-- the model arrives with its attributes and children; read it next frame anyway
			task.defer(function()
				if child.Parent == map then
					setArena(child :: Model)
				end
			end)
		end
	end)
	map.ChildRemoved:Connect(function(child)
		if ctx and ctx.Model == child then
			setArena(nil)
		end
	end)
	for _, child in ipairs(map:GetChildren()) do
		if isArena(child) then
			setArena(child :: Model)
		end
	end
end

local started = false

local function resizeBudget()
	local before = budget
	refreshBudget()
	if budget < before and activeCount > budget then
		releaseAll() -- the next update refills nearest-first within the new budget
	end
end

function GroundDetail.Init()
	if started then
		return
	end
	started = true
	refreshBudget()
	ClientSettings.OnChanged(function(key)
		if key == "ReducedEffects" then
			resizeBudget()
		end
	end)

	local map = workspace:FindFirstChild("SwarmMap")
	if map then
		watchMap(map)
	else
		workspace.ChildAdded:Connect(function(child)
			if child.Name == "SwarmMap" and child:IsA("Folder") then
				watchMap(child)
			end
		end)
	end

	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		acc += dt
		if acc < UPDATE_EVERY then
			return
		end
		acc = 0
		resizeBudget()
		local cam = workspace.CurrentCamera
		if ctx and cam and player:GetAttribute("InRun") == true then
			update(cam)
		elseif activeCount > 0 then
			releaseAll()
		end
	end)
end

-- Live counts (dev / preview checks): pooled parts, placed pieces, the budget.
function GroundDetail.Stats(): { Pool: number, Active: number, Budget: number, Arena: string? }
	return { Pool = #pool, Active = activeCount, Budget = budget, Arena = ctx and ctx.Name or nil }
end

return GroundDetail
