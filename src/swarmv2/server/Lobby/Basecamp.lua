--!strict
--[[
	SwarmV2/Lobby/Basecamp.lua  (ServerScriptService.SwarmV2.Lobby.Basecamp)
	OWNER: lobby track (Chat 1). Builds the walk-around social basecamp from plain Parts (no meshes,
	no asset ids) under workspace.SwarmV2Lobby: a compact forest clearing ringed by huge stone cliffs,
	a bonfire spawn, four class pedestals (temporary part-built previews) on the east side and the
	queue gates (stone arch, glowing pad, sign) on the north side. Lighting is not touched here.

	Layout (x east, z south, ground top = LobbyConfig.Origin.Y):
	  bonfire (0, 0) ... gates along z = -82 (x -56, 0, 56) ... pedestals along x = 78 (z -36 .. 36).
	Everything is anchored. Design notes: docs/redesign/lobby/DESIGN.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LobbyConfig = require(ReplicatedStorage.SwarmV2.Lobby.LobbyConfig)
local ClassCatalog = require(ReplicatedStorage.SwarmV2.ClassCatalog)

export type GateInfo = { Id: string, Center: Vector3, Size: Vector3, Exit: CFrame, Board: TextLabel }
export type Built = { Model: Model, Gates: { [string]: GateInfo }, Pedestals: { [string]: BasePart }, SpawnPoints: { CFrame } }

local Basecamp = {}

local ORIGIN: Vector3 = LobbyConfig.Origin
local HALF = LobbyConfig.Size / 2 -- walkable half width (110)
local GATE_Z = -82
local GATE_SPACING = 56
local PAD = 16 -- pad footprint
local PAD_TOP = 0.6
local PED_X = 78
local PED_SPACING = 24
local PAD_SLOTS = 8

local STONE = Color3.fromRGB(138, 140, 146)
local STONE_DARK = Color3.fromRGB(104, 106, 114)
local STONE_LIGHT = Color3.fromRGB(166, 166, 168)
local GRASS = Color3.fromRGB(92, 158, 62)
local DIRT = Color3.fromRGB(168, 136, 86)
local WOOD = Color3.fromRGB(104, 70, 42)
local PUBLIC_COLOR = Color3.fromRGB(70, 150, 255)
local PARTY_COLOR = Color3.fromRGB(255, 196, 60)
local STATUS_COLOR = Color3.fromRGB(226, 238, 255)

local SLAB = Enum.Material.SmoothPlastic
local ROCK = Enum.Material.Slate

local built: Built? = nil
local boardLabels: { [string]: string } = {}

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

local function P(x: number, y: number, z: number): Vector3
	return Vector3.new(ORIGIN.X + x, ORIGIN.Y + y, ORIGIN.Z + z)
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(P(x, y, z))
end

local function mk(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, collide: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or SLAB
	p.CanCollide = collide ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function ball(parent: Instance, name: string, diameter: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local p = mk(parent, name, diameter, cf, color, material, false)
	p.Shape = Enum.PartType.Ball
	return p
end

-- Cylinder whose axis is X in its own frame (Roblox default). `cf` is the centre.
local function cyl(parent: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, collide: boolean?): Part
	local p = mk(parent, name, size, cf, color, material, collide)
	p.Shape = Enum.PartType.Cylinder
	return p
end

-- Flat round disc on the ground, top at topY (studs above the origin), thickness t.
local function disc(parent: Instance, name: string, x: number, z: number, diameter: number, topY: number, t: number, color: Color3, material: Enum.Material?, collide: boolean?): Part
	return cyl(parent, name, Vector3.new(t, diameter, diameter), at(x, topY - t / 2, z) * CFrame.Angles(0, 0, math.pi / 2), color, material, collide)
end

local function folder(parent: Instance, name: string): Folder
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end

local function tint(c: Color3, k: number): Color3
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local out = s
	while true do
		local r, k = string.gsub(out, "^(-?%d+)(%d%d%d)", "%1,%2")
		out = r
		if k == 0 then
			break
		end
	end
	return out
end

local function escapeRich(s: string): string
	local r = string.gsub(s, "&", "&amp;")
	r = string.gsub(r, "<", "&lt;")
	r = string.gsub(r, ">", "&gt;")
	return r
end

local function hex(c: Color3): string
	return string.format("#%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function gateX(index: number): number
	local n = #LobbyConfig.Gates
	return (index - (n + 1) / 2) * GATE_SPACING
end

local function gateIndex(gateId: string): number?
	for i, g in ipairs(LobbyConfig.Gates) do
		if g.Id == gateId then
			return i
		end
	end
	return nil
end

local function gateColor(mode: string): Color3
	return if mode == "Party" then PARTY_COLOR else PUBLIC_COLOR
end

local function pedestalZ(index: number, count: number): number
	return (index - (count + 1) / 2) * PED_SPACING
end

-- Distance from (x, z) to segment a-b (flat).
local function segDist(x: number, z: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local t = if len2 > 0 then math.clamp(((x - ax) * dx + (z - az) * dz) / len2, 0, 1) else 0
	local px, pz = ax + dx * t, az + dz * t
	return math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
end

----------------------------------------------------------------------------------------------------
-- Layout facts shared by the builders
----------------------------------------------------------------------------------------------------

type Seg = { number }
local function pathSegments(): { Seg }
	local segs: { Seg } = {}
	for i = 1, #LobbyConfig.Gates do
		local gx = gateX(i)
		table.insert(segs, { 0, 0, gx, GATE_Z + PAD / 2 + 1.5 })
	end
	table.insert(segs, { 0, 0, PED_X - 17, 0 }) -- east trunk to the pedestal row
	table.insert(segs, { PED_X - 17, -(#ClassCatalog.Order * PED_SPACING) / 2, PED_X - 17, (#ClassCatalog.Order * PED_SPACING) / 2 })
	return segs
end

local function blockedForScenery(x: number, z: number, margin: number): boolean
	if x * x + z * z < (24 + margin) ^ 2 then
		return true
	end
	if z < GATE_Z + 24 and math.abs(x) < 92 then -- gate yard
		return true
	end
	if x > PED_X - 24 and math.abs(z) < (#ClassCatalog.Order * PED_SPACING) / 2 + 14 then -- pedestal yard
		return true
	end
	if (x + 52) ^ 2 + (z - 58) ^ 2 < (13 + margin) ^ 2 then -- the old arch
		return true
	end
	for _, s in ipairs(pathSegments()) do
		if segDist(x, z, s[1], s[2], s[3], s[4]) < 6 + margin then
			return true
		end
	end
	return false
end

----------------------------------------------------------------------------------------------------
-- Ground: floor, tone patches, dirt paths, plaza
----------------------------------------------------------------------------------------------------

local function buildGround(parent: Instance)
	local f = folder(parent, "Ground")
	mk(f, "Floor", Vector3.new(360, 8, 360), at(0, -4, 0), GRASS, Enum.Material.Grass)
	-- tone patches: unique heights where they could overlap (>= 0.05 apart), tops all under the paths
	local patches: { { any } } = {
		{ -70, -30, 32, 0.05, Color3.fromRGB(116, 176, 72) },
		{ 60, 60, 34, 0.05, Color3.fromRGB(78, 142, 58) },
		{ -20, 60, 30, 0.10, Color3.fromRGB(80, 146, 60) },
		{ 30, -45, 28, 0.10, Color3.fromRGB(118, 178, 74) },
		{ -85, 40, 26, 0.15, Color3.fromRGB(124, 182, 78) },
		{ 98, 10, 24, 0.15, Color3.fromRGB(76, 138, 56) },
		{ -5, -20, 22, 0.20, Color3.fromRGB(112, 172, 70) },
		{ 70, -10, 20, 0.20, Color3.fromRGB(82, 148, 60) },
	}
	for i, p in ipairs(patches) do
		disc(f, "TonePatch" .. i, p[1], p[2], p[3] * 2, p[4], 0.04, p[5], Enum.Material.Grass, false)
	end
	-- dirt paths: each segment on its own height (0.25 + 0.05 k), plaza on top where they meet
	local segs = pathSegments()
	local width = 7
	for k, s in ipairs(segs) do
		local ax, az, bx, bz = s[1], s[2], s[3], s[4]
		local len = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
		local top = 0.25 + 0.05 * (k - 1)
		local mid = Vector3.new((ax + bx) / 2, 0, (az + bz) / 2)
		local cf = CFrame.lookAt(P(mid.X, top - 0.1, mid.Z), P(bx, top - 0.1, bz))
		local seg = mk(f, "Path" .. k, Vector3.new(width, 0.2, len), cf, DIRT, Enum.Material.Ground, false)
		seg.Color = if k % 2 == 0 then tint(DIRT, 0.98) else DIRT
	end
	-- trampled round ends and the plaza around the bonfire
	disc(f, "PlazaCobble", 0, 0, 27, 0.70, 0.3, Color3.fromRGB(150, 144, 134), ROCK, false)
	disc(f, "PlazaInner", 0, 0, 20, 0.78, 0.2, Color3.fromRGB(128, 122, 114), ROCK, false)
	disc(f, "Ash", 0, 0, 9.5, 0.86, 0.2, Color3.fromRGB(56, 50, 48), SLAB, false)
	-- pedestal yard: flagstone strip under the row
	local count = #ClassCatalog.Order
	mk(f, "PedestalYard", Vector3.new(30, 0.2, count * PED_SPACING + 8), at(PED_X - 1, 0.55, 0), Color3.fromRGB(138, 132, 120), ROCK, false)
end

----------------------------------------------------------------------------------------------------
-- Cliffs
----------------------------------------------------------------------------------------------------

local function buildCliffs(parent: Instance, rng: Random)
	local f = folder(parent, "Cliffs")
	local sides = {
		{ Vector3.new(0, 0, -1), Vector3.new(1, 0, 0) },
		{ Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0) },
		{ Vector3.new(1, 0, 0), Vector3.new(0, 0, 1) },
		{ Vector3.new(-1, 0, 0), Vector3.new(0, 0, -1) },
	}
	local capCount = 0
	for si, side in ipairs(sides) do
		local normal, tangent = side[1], side[2]
		for row = 1, 2 do
			local t = -156
			while t < 156 do
				local w = rng:NextNumber(30, 48)
				local depth = rng:NextNumber(26, 46)
				local h = if row == 1 then rng:NextNumber(60, 112) else rng:NextNumber(90, 120)
				local n = HALF + 8 + (if row == 1 then 0 else 38) + depth / 2 + rng:NextNumber(-1, 5)
				local along = t + w / 2
				local centre = normal * n + tangent * along
				local yaw = math.rad(rng:NextNumber(-7, 7))
				local g = rng:NextNumber(0.86, 1.1)
				local color = tint(Color3.fromRGB(128, 130, 138), g)
				local size = Vector3.new(
					if math.abs(normal.X) > 0 then depth else w,
					h + 24,
					if math.abs(normal.X) > 0 then w else depth
				)
				local cf = at(centre.X, (h - 24) / 2, centre.Z) * CFrame.Angles(0, yaw, 0)
				mk(f, "Cliff" .. si .. "_" .. row, size, cf, color, ROCK)
				-- a lighter ledge in front of some blocks gives the chunky stepped look
				if row == 1 and rng:NextNumber() < 0.5 then
					local lh = rng:NextNumber(14, 34)
					local lw = w * rng:NextNumber(0.4, 0.7)
					local ld = rng:NextNumber(7, 12)
					local lc = normal * (HALF + 8 - ld / 2 + rng:NextNumber(0, 3)) + tangent * (along + rng:NextNumber(-6, 6))
					local lsize = Vector3.new(if math.abs(normal.X) > 0 then ld else lw, lh + 6, if math.abs(normal.X) > 0 then lw else ld)
					mk(f, "Ledge", lsize, at(lc.X, lh / 2 - 6, lc.Z) * CFrame.Angles(0, yaw * 1.5, 0), tint(color, 1.08), ROCK)
				end
				-- some tops get a grass cap
				if row == 1 and rng:NextNumber() < 0.4 then
					capCount += 1
					local capSize = Vector3.new(size.X - 1.5, 2.2, size.Z - 1.5)
					mk(f, "GrassTop", capSize, cf * CFrame.new(0, size.Y / 2 + 0.1, 0), Color3.fromRGB(94, 150, 62), Enum.Material.Grass, false)
				end
				t += w - rng:NextNumber(0, 5)
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Trees, rocks, ruins
----------------------------------------------------------------------------------------------------

local GREENS = {
	Color3.fromRGB(34, 94, 52),
	Color3.fromRGB(40, 106, 56),
	Color3.fromRGB(30, 84, 52),
	Color3.fromRGB(48, 114, 58),
}

local function pine(parent: Instance, x: number, z: number, scale: number, rng: Random)
	local s = scale
	local m = Instance.new("Model")
	m.Name = "Pine"
	local green = GREENS[rng:NextInteger(1, #GREENS)]
	mk(m, "Trunk", Vector3.new(1.8 * s, 5 * s, 1.8 * s), at(x, 2.5 * s, z), WOOD, Enum.Material.Wood)
	local tiers = { { 11, 4.2, 3.4 }, { 8.6, 4.2, 6.6 }, { 6.2, 3.8, 9.6 }, { 3.6, 3.4, 12.4 } }
	local yaw0 = rng:NextNumber(0, math.pi / 2)
	for i, t in ipairs(tiers) do
		local w = t[1] * s
		local part = mk(m, "Tier" .. i, Vector3.new(w, t[2] * s, w), at(x, t[3] * s + t[2] * s / 2 - 1.0 * s, z) * CFrame.Angles(0, yaw0 + (i % 2) * math.pi / 4, 0), tint(green, 0.88 + 0.07 * i), SLAB, false)
		part.CanQuery = false
	end
	m.Parent = parent
end

local function rock(parent: Instance, x: number, z: number, s: number, rng: Random)
	local sz = Vector3.new(s * rng:NextNumber(0.9, 1.4), s * rng:NextNumber(0.6, 1.0), s * rng:NextNumber(0.9, 1.4))
	local cf = at(x, sz.Y * 0.32, z) * CFrame.Angles(rng:NextNumber(-0.18, 0.18), rng:NextNumber(0, math.pi), rng:NextNumber(-0.18, 0.18))
	mk(parent, "Rock", sz, cf, tint(Color3.fromRGB(132, 134, 140), rng:NextNumber(0.85, 1.12)), ROCK)
end

local function buildTrees(parent: Instance, rng: Random)
	local f = folder(parent, "Trees")
	local placed = 0
	local tries = 0
	while placed < 125 and tries < 800 do
		tries += 1
		local side = rng:NextInteger(1, 4)
		local along = rng:NextNumber(-HALF - 6, HALF + 6)
		local edge = rng:NextNumber(HALF - 16, HALF + 7)
		local x, z
		if side == 1 then
			x, z = along, -edge
		elseif side == 2 then
			x, z = along, edge
		elseif side == 3 then
			x, z = edge, along
		else
			x, z = -edge, along
		end
		if not blockedForScenery(x, z, 3) then
			pine(f, x, z, rng:NextNumber(1.1, 1.9), rng)
			placed += 1
		end
	end
	-- a few loose trees in the field
	local inner = 0
	tries = 0
	while inner < 12 and tries < 400 do
		tries += 1
		local x, z = rng:NextNumber(-95, 95), rng:NextNumber(-60, 95)
		if not blockedForScenery(x, z, 8) then
			pine(f, x, z, rng:NextNumber(0.8, 1.2), rng)
			inner += 1
		end
	end
end

-- Stone arch from blocks around a semicircle. `broken` drops one segment.
local function archBuild(parent: Instance, base: CFrame, r: number, pillarH: number, n: number, color: Color3, depth: number, crown: Color3?, broken: number?)
	local pw = 3.6
	for _, sx in ipairs({ -1, 1 }) do
		mk(parent, "Pillar", Vector3.new(pw, pillarH, depth), base * CFrame.new(sx * (r + pw / 2), pillarH / 2, 0), color, ROCK)
		mk(parent, "PillarFoot", Vector3.new(pw + 1.2, 1.2, depth + 1.2), base * CFrame.new(sx * (r + pw / 2), 0.6, 0), tint(color, 0.88), ROCK)
	end
	local rm = r + pw / 2
	local len = 2 * rm * math.tan(math.pi / (2 * n)) * 1.1
	for i = 1, n do
		if broken ~= i then
			local phi = (i - 0.5) * math.pi / n
			local c = if crown ~= nil and i == (n + 1) / 2 then crown else tint(color, 0.92 + 0.12 * ((i * 7) % 3) / 2)
			mk(parent, "ArchStone", Vector3.new(pw, len, depth), base * CFrame.new(rm * math.cos(phi), pillarH + rm * math.sin(phi), 0) * CFrame.Angles(0, 0, phi), c, ROCK)
		end
	end
end

local function buildRuins(parent: Instance, rng: Random)
	local f = folder(parent, "Ruins")
	-- the old arch, south-west, one stone missing and fallen
	local baseCF = at(-52, 0, 58) * CFrame.Angles(0, math.rad(35), 0)
	archBuild(f, baseCF, 5.6, 7, 5, Color3.fromRGB(150, 150, 150), 3.6, nil, 4)
	mk(f, "FallenStone", Vector3.new(3.6, 5.6, 3.6), baseCF * CFrame.new(11, 1.8, -4) * CFrame.Angles(0.2, 0.5, 1.3), Color3.fromRGB(138, 138, 138), ROCK)
	-- standing stones and broken pillars
	local stones = {
		{ -76, 44, 8.5 }, { -66, 30, 7 }, { -84, 62, 6 }, { -38, 74, 9 }, { -24, 82, 5.5 },
		{ -64, 78, 7.5 }, { -92, 22, 8 }, { 26, 84, 7 }, { 44, 76, 9 }, { 14, 92, 5 },
	}
	for _, s in ipairs(stones) do
		local h = s[3]
		mk(f, "StandingStone", Vector3.new(2.6, h, 2.0), at(s[1], h / 2, s[2]) * CFrame.Angles(rng:NextNumber(-0.05, 0.05), rng:NextNumber(0, math.pi), rng:NextNumber(-0.05, 0.05)), tint(Color3.fromRGB(150, 150, 152), rng:NextNumber(0.88, 1.08)), ROCK)
	end
	local pillars: { { any } } = { { -30, 52, 12, false }, { -22, 56, 5, true }, { 54, 62, 11, false }, { 62, 70, 4, true } }
	for _, p in ipairs(pillars) do
		local h = p[3]
		mk(f, "BrokenPillar", Vector3.new(4, h, 4), at(p[1], h / 2, p[2]), Color3.fromRGB(154, 152, 148), ROCK)
		mk(f, "PillarBase", Vector3.new(5.2, 1.2, 5.2), at(p[1], 0.6, p[2]), tint(Color3.fromRGB(154, 152, 148), 0.86), ROCK)
		if p[4] then
			mk(f, "PillarDrum", Vector3.new(3.4, 3, 3.4), at(p[1] + 5, 1.4, p[2] + 2) * CFrame.Angles(0.3, 0.7, 1.2), Color3.fromRGB(146, 144, 140), ROCK)
		end
	end
	-- low ruined wall, south-east
	for i = 0, 5 do
		local h = 3 + (i * 37 % 5)
		mk(f, "WallBlock", Vector3.new(5, h, 3), at(40 + i * 5.2, h / 2, 96) * CFrame.Angles(0, rng:NextNumber(-0.05, 0.05), 0), tint(Color3.fromRGB(144, 142, 138), rng:NextNumber(0.88, 1.06)), ROCK)
	end
end

local function buildRocks(parent: Instance, rng: Random)
	local f = folder(parent, "Rocks")
	local placed = 0
	local tries = 0
	while placed < 34 and tries < 600 do
		tries += 1
		local x, z = rng:NextNumber(-105, 105), rng:NextNumber(-100, 105)
		if not blockedForScenery(x, z, 2) then
			rock(f, x, z, rng:NextNumber(2.5, 6), rng)
			placed += 1
			if rng:NextNumber() < 0.45 then
				rock(f, x + rng:NextNumber(-4, 4), z + rng:NextNumber(-4, 4), rng:NextNumber(1.5, 3), rng)
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Bonfire, benches, spawn points
----------------------------------------------------------------------------------------------------

local function buildBonfire(parent: Instance, spawnPoints: { CFrame })
	local f = folder(parent, "Bonfire")
	for i = 1, 10 do
		local a = (i - 1) / 10 * math.pi * 2
		local x, z = math.cos(a) * 4.5, math.sin(a) * 4.5
		mk(f, "RingStone", Vector3.new(2.2, 1.5, 2.8), at(x, 1.05, z) * CFrame.Angles(0, -a + math.pi / 2, 0), tint(STONE, 0.9 + 0.2 * ((i * 5) % 3) / 2), ROCK)
	end
	for i = 1, 5 do
		local yaw = i * 1.256
		mk(f, "Log", Vector3.new(1.0, 1.0, 6.4), at(0, 1.55, 0) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(-0.28, 0, 0), WOOD, Enum.Material.Wood, false)
	end
	mk(f, "FlameOuter", Vector3.new(2.6, 3.4, 2.6), at(0, 3.2, 0) * CFrame.Angles(0, 0.4, 0), Color3.fromRGB(255, 120, 30), Enum.Material.Neon, false).Transparency = 0.15
	mk(f, "FlameInner", Vector3.new(1.4, 2.4, 1.4), at(0, 3.9, 0) * CFrame.Angles(0, 0.9, 0), Color3.fromRGB(255, 214, 90), Enum.Material.Neon, false)
	local emitter = mk(f, "FireSource", Vector3.new(3, 1, 3), at(0, 2.4, 0), Color3.fromRGB(255, 140, 40), SLAB, false)
	emitter.Transparency = 1
	emitter.CanQuery = false
	local fire = Instance.new("Fire")
	fire.Size = 11
	fire.Heat = 9
	fire.Color = Color3.fromRGB(255, 150, 40)
	fire.SecondaryColor = Color3.fromRGB(255, 70, 10)
	fire.Parent = emitter
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 60)
	light.Brightness = 3
	light.Range = 48
	light.Shadows = false
	light.Parent = emitter

	-- log benches around the fire (south and west, clear of the paths)
	for _, deg in ipairs({ 55, 100, 145, 190 }) do
		local a = math.rad(deg)
		local x, z = math.cos(a) * 15.5, math.sin(a) * 15.5
		local yaw = math.atan2(-math.cos(a), -math.sin(a))
		cyl(f, "BenchLog", Vector3.new(7.5, 1.9, 1.9), at(x, 1.3, z) * CFrame.Angles(0, yaw, 0), WOOD, Enum.Material.Wood)
		cyl(f, "BenchSeat", Vector3.new(7.5, 1.1, 1.1), at(x * 1.13, 0.95, z * 1.13) * CFrame.Angles(0, yaw, 0), tint(WOOD, 0.85), Enum.Material.Wood, false)
	end

	-- spawn points: 12 around the fire, facing it
	local spawns = folder(parent, "Spawns")
	for i = 1, 12 do
		local a = (i - 1) / 12 * math.pi * 2 + 0.26
		local x, z = math.cos(a) * 10.5, math.sin(a) * 10.5
		local cf = CFrame.lookAt(P(x, 3, z), P(0, 3, 0))
		table.insert(spawnPoints, cf)
		if i % 3 == 1 then
			local s = Instance.new("SpawnLocation")
			s.Name = "SpawnPoint" .. i
			s.Anchored = true
			s.CanCollide = false
			s.Transparency = 1
			s.Neutral = true
			s.Duration = 0
			s.Size = Vector3.new(5, 1, 5)
			s.CFrame = CFrame.lookAt(P(x, 0.5, z), P(0, 0.5, 0))
			s.Parent = spawns
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Gates
----------------------------------------------------------------------------------------------------

local function signPlate(parent: Instance, name: string, size: Vector3, cf: CFrame, canvas: Vector2): (Part, SurfaceGui)
	-- cf faces +Z (towards the bonfire): the sign's front (-Z) is turned round
	local plate = mk(parent, name, size, cf * CFrame.Angles(0, math.pi, 0), Color3.fromRGB(30, 40, 62), SLAB, false)
	local gui = Instance.new("SurfaceGui")
	gui.Name = name .. "Gui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = canvas
	gui.LightInfluence = 0.2
	gui.Parent = plate
	return plate, gui
end

local function boardText(label: string, status: string, color: Color3): string
	return string.format('<b>%s</b>\n<font size="54" color="%s">%s</font>', escapeRich(label), hex(color), escapeRich(status))
end

local function buildGates(parent: Instance, gates: { [string]: GateInfo })
	local f = folder(parent, "Gates")
	for i, def in ipairs(LobbyConfig.Gates) do
		local gx = gateX(i)
		local color = gateColor(def.Mode)
		local g = Instance.new("Model")
		g.Name = "Gate_" .. def.Id
		g:SetAttribute("GateId", def.Id)

		-- floor: stone frame + glowing pad
		mk(g, "PadFrame", Vector3.new(PAD + 3, 0.3, PAD + 3), at(gx, 0.3, GATE_Z), tint(STONE_DARK, 0.9), ROCK, false)
		local pad = mk(g, "Pad", Vector3.new(PAD, 0.3, PAD), at(gx, PAD_TOP - 0.15, GATE_Z), color, Enum.Material.Neon, false)
		pad.Name = "Pad"
		pad:SetAttribute("GateId", def.Id)
		pad.TopSurface = Enum.SurfaceType.Smooth
		local ring = mk(g, "PadCore", Vector3.new(PAD - 5, 0.1, PAD - 5), at(gx, PAD_TOP + 0.05, GATE_Z), tint(color, 1.15), Enum.Material.Neon, false)
		ring.Transparency = 0.45

		-- arch behind the pad
		local archCF = at(gx, 0, GATE_Z - PAD / 2 - 1.5)
		archBuild(g, archCF, PAD / 2 + 1, 6, 7, STONE, 4.6, color)
		-- glowing curtain between the pillars
		local curtain = { { 18, 6, 0.6 }, { 14, 3, 6.6 }, { 8, 2, 9.6 } }
		for k, c in ipairs(curtain) do
			local w = mk(g, "Curtain" .. k, Vector3.new(c[1], c[2], 0.4), archCF * CFrame.new(0, c[3] + c[2] / 2, 0.3), color, Enum.Material.Neon, false)
			w.Transparency = 0.62
		end

		-- the big sign on posts over the arch
		local signW, signH = 22, 7.5
		local signY = 24
		for _, sx in ipairs({ -1, 1 }) do
			mk(g, "SignPost", Vector3.new(1.4, 8, 1.4), archCF * CFrame.new(sx * 8, 16.5, 0), WOOD, Enum.Material.Wood, false)
		end
		mk(g, "SignFrame", Vector3.new(signW + 1.6, signH + 1.6, 1.0), archCF * CFrame.new(0, signY, 0), WOOD, Enum.Material.Wood, false)
		local plate, gui = signPlate(g, "Sign", Vector3.new(signW, signH, 0.5), archCF * CFrame.new(0, signY, 0.6), Vector2.new(880, 300))
		plate.Color = Color3.fromRGB(28, 38, 60)
		local stripe = mk(g, "SignTrim", Vector3.new(signW, 0.5, 0.2), archCF * CFrame.new(0, signY + signH / 2 - 0.3, 0.95), color, Enum.Material.Neon, false)
		stripe.Name = "SignTrim"
		local board = Instance.new("TextLabel")
		board.Name = "Board"
		board.BackgroundTransparency = 1
		board.Size = UDim2.fromScale(1, 1)
		board.Font = Enum.Font.GothamBlack
		board.TextSize = 80
		board.RichText = true
		board.TextColor3 = Color3.fromRGB(255, 255, 255)
		board.TextWrapped = true
		board.TextXAlignment = Enum.TextXAlignment.Center
		board.TextYAlignment = Enum.TextYAlignment.Center
		board.TextStrokeTransparency = 0.6
		boardLabels[def.Id] = def.Label
		board.Text = boardText(def.Label, "", STATUS_COLOR)
		board.Parent = gui

		-- small hint sign on a post beside the pad
		local hx, hz = gx + PAD / 2 + 7, GATE_Z + 4
		mk(g, "HintPost", Vector3.new(1, 5, 1), at(hx, 2.5, hz), WOOD, Enum.Material.Wood, false)
		mk(g, "HintFrame", Vector3.new(11.2, 5.4, 0.8), at(hx, 6.2, hz), WOOD, Enum.Material.Wood, false)
		local hplate, hgui = signPlate(g, "HintSign", Vector3.new(10.4, 4.6, 0.4), at(hx, 6.2, hz + 0.5), Vector2.new(520, 230))
		hplate.Color = Color3.fromRGB(236, 232, 218)
		hgui.Name = "HintGui"
		local hint = Instance.new("TextLabel")
		hint.Name = "Hint"
		hint.BackgroundTransparency = 1
		hint.Size = UDim2.new(1, -24, 1, -16)
		hint.Position = UDim2.fromOffset(12, 8)
		hint.Font = Enum.Font.GothamBold
		hint.TextSize = 40
		hint.TextWrapped = true
		hint.TextColor3 = Color3.fromRGB(40, 36, 30)
		hint.Text = def.Hint
		hint.Parent = hgui

		-- two small corner torches' bases (stone cairns) frame the pad front
		for _, sx in ipairs({ -1, 1 }) do
			mk(g, "Cairn", Vector3.new(2.6, 1.8, 2.6), at(gx + sx * (PAD / 2 + 2.6), 0.9, GATE_Z + PAD / 2 + 1), tint(STONE, 0.95), ROCK)
		end

		g.Parent = f

		gates[def.Id] = {
			Id = def.Id,
			Center = P(gx, PAD_TOP, GATE_Z),
			Size = Vector3.new(PAD, 10, PAD),
			Exit = CFrame.lookAt(P(gx, 3, GATE_Z + PAD / 2 + 6), P(0, 3, 0)),
			Board = board,
		}
	end
end

----------------------------------------------------------------------------------------------------
-- Class previews (temporary part-built placeholders)
----------------------------------------------------------------------------------------------------

type Maker = (name: string, size: Vector3, offset: Vector3, color: Color3, mat: Enum.Material?, rot: CFrame?) -> Part

local function previewRuckus(b: Maker, ball: (string, Vector3, Vector3, Color3) -> Part, cyl: (string, Vector3, Vector3, Color3, CFrame?) -> Part, p: Color3, a: Color3)
	local dark = Color3.fromRGB(60, 58, 64)
	local light = Color3.fromRGB(196, 194, 198)
	local teal = Color3.fromRGB(56, 148, 150)
	for _, s in ipairs({ -1, 1 }) do
		b("Boot", Vector3.new(1.5, 0.9, 2.0), Vector3.new(s * 0.95, 0.45, -0.2), dark)
		b("Leg", Vector3.new(1.2, 1.4, 1.3), Vector3.new(s * 0.95, 1.6, 0), tint(p, 0.7))
		b("Arm", Vector3.new(1.0, 2.3, 1.1), Vector3.new(s * 2.2, 3.9, -0.1), p)
		b("Fist", Vector3.new(1.3, 1.1, 1.3), Vector3.new(s * 2.2, 2.55, -0.2), dark)
		b("Ear", Vector3.new(0.9, 1.0, 0.5), Vector3.new(s * 1.15, 7.9, 0.1), dark)
		b("EarIn", Vector3.new(0.5, 0.6, 0.2), Vector3.new(s * 1.15, 7.9, -0.2), light)
		b("Eye", Vector3.new(0.55, 0.55, 0.1), Vector3.new(s * 0.7, 6.6, -1.28), Color3.fromRGB(255, 255, 255))
		b("Pupil", Vector3.new(0.28, 0.3, 0.1), Vector3.new(s * 0.7, 6.55, -1.34), Color3.fromRGB(20, 20, 24))
		cyl("GoggleLens", Vector3.new(0.5, 1.2, 1.2), Vector3.new(s * 0.85, 7.35, -0.95), a, CFrame.Angles(0, math.pi / 2, 0))
	end
	b("Torso", Vector3.new(3.2, 2.8, 2.2), Vector3.new(0, 3.8, 0), p)
	b("Vest", Vector3.new(3.5, 2.0, 2.4), Vector3.new(0, 3.6, 0), teal)
	b("Belt", Vector3.new(3.6, 0.4, 2.5), Vector3.new(0, 2.85, 0), Color3.fromRGB(110, 76, 46))
	b("Head", Vector3.new(3.0, 2.4, 2.4), Vector3.new(0, 6.4, 0), tint(p, 1.2))
	b("Mask", Vector3.new(3.1, 0.8, 0.12), Vector3.new(0, 6.55, -1.2), dark)
	b("Snout", Vector3.new(1.4, 1.0, 1.0), Vector3.new(0, 5.95, -1.55), light)
	b("Nose", Vector3.new(0.55, 0.4, 0.3), Vector3.new(0, 6.2, -2.1), Color3.fromRGB(24, 24, 28))
	b("GoggleStrap", Vector3.new(3.1, 0.3, 2.5), Vector3.new(0, 7.3, 0), Color3.fromRGB(110, 76, 46))
	-- trash can backpack + striped tail
	cyl("TrashCan", Vector3.new(3.0, 2.1, 2.1), Vector3.new(0, 4.5, 1.95), Color3.fromRGB(142, 148, 154), CFrame.Angles(0, 0, math.pi / 2))
	cyl("CanLid", Vector3.new(0.45, 2.4, 2.4), Vector3.new(0, 6.15, 1.95), dark, CFrame.Angles(0, 0, math.pi / 2))
	b("CanHandle", Vector3.new(0.9, 0.3, 0.3), Vector3.new(0, 6.5, 1.95), dark)
	for i = 1, 4 do
		b("Tail" .. i, Vector3.new(1.9 - i * 0.12, 1.9 - i * 0.12, 1.5), Vector3.new(1.0 + i * 0.5, 1.5 + i * 0.6, 2.4 + i * 1.2), if i % 2 == 0 then dark else light)
	end
end

local function previewToaster(b: Maker, ball: (string, Vector3, Vector3, Color3) -> Part, cyl: (string, Vector3, Vector3, Color3, CFrame?) -> Part, p: Color3, a: Color3)
	local dark = Color3.fromRGB(70, 72, 80)
	for _, s in ipairs({ -1, 1 }) do
		b("Boot", Vector3.new(1.9, 1.1, 2.4), Vector3.new(s * 1.5, 0.55, -0.1), dark)
		b("Arm", Vector3.new(0.8, 2.2, 0.8), Vector3.new(s * 3.5, 3.2, 0), dark)
		b("Fist", Vector3.new(1.3, 1.3, 1.3), Vector3.new(s * 3.5, 1.7, 0), tint(dark, 0.8))
		b("Slice", Vector3.new(2.0, 1.7, 0.8), Vector3.new(s * 1.2, 6.5, 0), Color3.fromRGB(236, 190, 100))
		b("Crust", Vector3.new(2.2, 0.35, 0.95), Vector3.new(s * 1.2, 7.4, 0), Color3.fromRGB(196, 130, 56))
		b("EyeWhite", Vector3.new(1.2, 0.9, 0.12), Vector3.new(s * 1.2, 4.4, -1.72), Color3.fromRGB(250, 250, 250))
		b("Pupil", Vector3.new(0.5, 0.55, 0.1), Vector3.new(s * 1.1, 4.35, -1.8), Color3.fromRGB(20, 20, 24))
		b("Brow", Vector3.new(1.6, 0.35, 0.16), Vector3.new(s * 1.2, 5.0, -1.76), dark, nil, CFrame.Angles(0, 0, -s * 0.35))
	end
	b("Body", Vector3.new(5.6, 4.2, 3.4), Vector3.new(0, 3.1, 0), p)
	b("Rim", Vector3.new(5.8, 0.35, 3.6), Vector3.new(0, 5.35, 0), tint(p, 0.78))
	b("MouthRecess", Vector3.new(4.2, 1.6, 0.2), Vector3.new(0, 2.1, -1.68), Color3.fromRGB(46, 36, 34))
	for i = -2, 2 do
		b("Coil", Vector3.new(0.45, 1.3, 0.12), Vector3.new(i * 0.8, 2.1, -1.82), a, Enum.Material.Neon)
	end
	b("Knob", Vector3.new(0.7, 0.7, 0.7), Vector3.new(2.95, 4.6, -0.2), Color3.fromRGB(204, 52, 44))
end

local function previewFrog(b: Maker, ball: (string, Vector3, Vector3, Color3) -> Part, cyl: (string, Vector3, Vector3, Color3, CFrame?) -> Part, p: Color3, a: Color3)
	local belly = Color3.fromRGB(226, 226, 160)
	local brown = Color3.fromRGB(128, 90, 52)
	local tan = Color3.fromRGB(206, 178, 120)
	for _, s in ipairs({ -1, 1 }) do
		b("Foot", Vector3.new(1.8, 0.6, 2.4), Vector3.new(s * 2.0, 0.3, -0.5), tint(p, 0.9))
		b("Arm", Vector3.new(1.1, 2.4, 1.1), Vector3.new(s * 3.1, 3.0, -0.4), tint(p, 0.95))
		b("Hand", Vector3.new(1.4, 0.7, 1.5), Vector3.new(s * 3.1, 1.55, -0.6), tint(p, 0.9))
		ball("Eye", Vector3.new(1.5, 1.5, 1.5), Vector3.new(s * 1.5, 8.2, -0.5), Color3.fromRGB(250, 250, 250))
		ball("Pupil", Vector3.new(0.8, 0.8, 0.8), Vector3.new(s * 1.5, 8.2, -1.2), Color3.fromRGB(20, 22, 20))
		cyl("GoggleLens", Vector3.new(0.4, 1.7, 1.7), Vector3.new(s * 1.55, 8.9, -1.1), Color3.fromRGB(60, 100, 150), CFrame.Angles(0, math.pi / 2, 0))
		cyl("GoggleRim", Vector3.new(0.35, 2.1, 2.1), Vector3.new(s * 1.55, 8.9, -0.95), a, CFrame.Angles(0, math.pi / 2, 0))
	end
	ball("Body", Vector3.new(6.0, 5.4, 5.0), Vector3.new(0, 3.2, 0), p)
	ball("Belly", Vector3.new(3.8, 3.8, 2.6), Vector3.new(0, 2.9, -1.5), belly)
	ball("Head", Vector3.new(5.2, 3.4, 4.2), Vector3.new(0, 6.3, -0.3), tint(p, 1.08))
	b("Mouth", Vector3.new(3.0, 0.22, 0.1), Vector3.new(0, 5.6, -2.35), Color3.fromRGB(40, 70, 34))
	b("GoggleStrap", Vector3.new(5.3, 0.4, 0.5), Vector3.new(0, 8.9, -0.4), brown)
	b("Scarf", Vector3.new(5.0, 1.0, 3.9), Vector3.new(0, 4.6, -0.2), a)
	b("ScarfTail", Vector3.new(1.9, 1.9, 0.5), Vector3.new(0, 3.7, -2.1), a, nil, CFrame.Angles(0, 0, math.pi / 4))
	b("Pack", Vector3.new(3.0, 3.2, 1.7), Vector3.new(0, 3.6, 2.6), brown)
	b("PackFlap", Vector3.new(3.2, 0.5, 1.9), Vector3.new(0, 5.1, 2.6), tint(brown, 0.8))
	cyl("Bedroll", Vector3.new(3.8, 1.3, 1.3), Vector3.new(0, 5.9, 2.6), tan, nil)
	ball("BubbleBomb", Vector3.new(1.9, 1.9, 1.9), Vector3.new(-3.8, 1.0, -2.0), Color3.fromRGB(90, 196, 232))
end

local function previewGranny(b: Maker, ball: (string, Vector3, Vector3, Color3) -> Part, cyl: (string, Vector3, Vector3, Color3, CFrame?) -> Part, p: Color3, a: Color3)
	local steel = Color3.fromRGB(72, 76, 84)
	local skin = Color3.fromRGB(238, 198, 168)
	local hair = Color3.fromRGB(206, 206, 214)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			b("WalkerLeg", Vector3.new(0.9, 2.4, 0.9), Vector3.new(sx * 2.7, 1.5, sz * 1.8), steel)
			b("WalkerFoot", Vector3.new(1.6, 0.5, 2.0), Vector3.new(sx * 2.7, 0.25, sz * 1.8), tint(steel, 0.7))
		end
		cyl("Tank", Vector3.new(3.6, 1.4, 1.4), Vector3.new(sx * 3.0, 4.6, 0.4), a, CFrame.Angles(0, 0, math.pi / 2))
		cyl("Nozzle", Vector3.new(1.4, 1.0, 1.0), Vector3.new(sx * 3.0, 3.6, 2.6), steel, CFrame.Angles(0, math.pi / 2, 0))
		b("Flame", Vector3.new(0.8, 0.8, 1.6), Vector3.new(sx * 3.0, 3.6, 3.9), Color3.fromRGB(255, 160, 40), Enum.Material.Neon)
		b("Arm", Vector3.new(0.8, 0.8, 2.0), Vector3.new(sx * 1.4, 5.0, -1.6), p)
		cyl("Goggle", Vector3.new(0.6, 1.1, 1.1), Vector3.new(sx * 0.6, 6.95, -1.0), Color3.fromRGB(255, 160, 50), CFrame.Angles(0, math.pi / 2, 0))
	end
	b("Platform", Vector3.new(5.2, 0.9, 4.6), Vector3.new(0, 2.75, 0), steel)
	b("HazardPlate", Vector3.new(3.4, 1.5, 0.3), Vector3.new(0, 3.5, -2.45), Color3.fromRGB(240, 196, 40))
	b("HazardStripe", Vector3.new(0.6, 1.6, 0.35), Vector3.new(0.6, 3.5, -2.5), Color3.fromRGB(40, 40, 44), nil, CFrame.Angles(0, 0, 0.6))
	b("Handlebar", Vector3.new(4.8, 0.3, 0.3), Vector3.new(0, 5.0, -2.7), steel)
	b("GrannyBody", Vector3.new(2.7, 2.4, 2.1), Vector3.new(0, 4.6, 0.2), p)
	b("Head", Vector3.new(2.1, 1.9, 1.9), Vector3.new(0, 6.7, 0.1), skin)
	b("GoggleBand", Vector3.new(2.2, 0.5, 0.2), Vector3.new(0, 6.95, -0.95), steel)
	b("Mouth", Vector3.new(0.7, 0.15, 0.1), Vector3.new(0, 6.15, -1.0), Color3.fromRGB(150, 90, 80))
	ball("Hair", Vector3.new(2.6, 2.1, 2.4), Vector3.new(0, 7.4, 0.4), hair)
	ball("Bun", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 8.2, 1.2), hair)
	ball("YarnBomb", Vector3.new(1.9, 1.9, 1.9), Vector3.new(-1.9, 3.7, -2.4), Color3.fromRGB(226, 70, 160))
end

local previewMakers: { [string]: any } = {
	ruckus = previewRuckus,
	toastmaster = previewToaster,
	captain_croak = previewFrog,
	granny_boom = previewGranny,
}

local function buildPreview(parent: Instance, classId: string, root: CFrame, primary: Color3, accent: Color3)
	local model = Instance.new("Model")
	model.Name = "Preview_" .. classId
	model:SetAttribute("Placeholder", true)
	local K = 1.4 -- preview scale (the shapes are authored ~9 studs tall)
	local function b(name: string, size: Vector3, offset: Vector3, color: Color3, mat: Enum.Material?, rot: CFrame?): Part
		return mk(model, name, size * K, root * CFrame.new(offset * K) * (rot or CFrame.new()), color, mat, false)
	end
	local function bl(name: string, size: Vector3, offset: Vector3, color: Color3): Part
		return ball(model, name, size * K, root * CFrame.new(offset * K), color, nil)
	end
	local function cy(name: string, size: Vector3, offset: Vector3, color: Color3, rot: CFrame?): Part
		return cyl(model, name, size * K, root * CFrame.new(offset * K) * (rot or CFrame.new()), color, nil, false)
	end
	local maker = previewMakers[classId]
	if maker then
		maker(b, bl, cy, primary, accent)
	else
		b("Body", Vector3.new(3, 4, 3), Vector3.new(0, 2, 0), primary)
	end
	model.Parent = parent
end

----------------------------------------------------------------------------------------------------
-- Pedestals
----------------------------------------------------------------------------------------------------

local function priceText(cost: number): (string, Color3)
	if cost <= 0 then
		return "FREE", Color3.fromRGB(130, 236, 130)
	end
	return commas(cost) .. " GOLD", Color3.fromRGB(255, 214, 80)
end

local function label(parent: Instance, name: string, y: number, h: number, text: string, color: Color3, font: Enum.Font, maxSize: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromScale(0.04, y)
	l.Size = UDim2.fromScale(0.92, h)
	l.Font = font
	l.TextScaled = true
	l.TextColor3 = color
	l.Text = text
	l.TextStrokeTransparency = 0.5
	l.TextStrokeColor3 = Color3.fromRGB(10, 14, 24)
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = maxSize
	cap.MinTextSize = 8
	cap.Parent = l
	l.Parent = parent
	return l
end

local function buildPedestals(parent: Instance, pedestals: { [string]: BasePart })
	local f = folder(parent, "Pedestals")
	local order = ClassCatalog.Order
	for i, id in ipairs(order) do
		local info = ClassCatalog.Get(id)
		local primary = (info and info.Primary) or Color3.fromRGB(160, 160, 160)
		local accent = (info and info.Accent) or Color3.fromRGB(240, 200, 60)
		local name = (info and info.Name) or id
		local role = (info and info.Role) or ""
		local cost = (info and info.Cost) or 0
		local z = pedestalZ(i, #order)
		local m = Instance.new("Model")
		m.Name = "Pedestal_" .. id
		m:SetAttribute("ClassId", id)

		mk(m, "Base", Vector3.new(13.6, 1.2, 13.6), at(PED_X, 0.6, z), tint(STONE_DARK, 0.92), ROCK)
		local plinth = mk(m, "Plinth", Vector3.new(11, 2.0, 11), at(PED_X, 2.2, z), STONE, ROCK)
		plinth.Name = "Plinth_" .. id
		plinth:SetAttribute("ClassId", id)
		local trim = mk(m, "Trim", Vector3.new(11.8, 0.5, 11.8), at(PED_X, 3.45, z), accent, SLAB)
		trim.Material = Enum.Material.SmoothPlastic
		mk(m, "TopSlab", Vector3.new(10, 0.4, 10), at(PED_X, 3.9, z), tint(STONE_LIGHT, 0.95), ROCK)
		for _, sz in ipairs({ -1, 1 }) do
			mk(m, "CornerStone", Vector3.new(1.8, 1.6, 1.8), at(PED_X - 5.9, 0.8, z + sz * 5.9), tint(STONE_DARK, 1.0), ROCK)
		end

		-- the temporary preview, facing the bonfire (west)
		local root = at(PED_X, 4.1, z) * CFrame.Angles(0, math.rad(90), 0)
		buildPreview(m, id, root, primary, accent)

		-- prompt
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ChoosePrompt"
		prompt.ActionText = "Choose"
		prompt.ObjectText = name
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt:SetAttribute("ClassId", id)
		prompt.Parent = plinth

		-- billboard
		local anchor = mk(m, "SignAnchor", Vector3.new(1, 1, 1), at(PED_X, 22.5, z), primary, SLAB, false)
		anchor.Transparency = 1
		anchor.CanQuery = false
		local bb = Instance.new("BillboardGui")
		bb.Name = "ClassInfo"
		bb.Adornee = anchor
		bb.Size = UDim2.fromScale(17, 7.2) -- studs: scales with distance
		bb.StudsOffset = Vector3.new(0, 0, 0)
		bb.AlwaysOnTop = false
		bb.MaxDistance = 220
		bb.LightInfluence = 0
		bb.Parent = anchor
		local back = Instance.new("Frame")
		back.Name = "Back"
		back.Size = UDim2.fromScale(1, 1)
		back.BackgroundColor3 = Color3.fromRGB(20, 28, 46)
		back.BackgroundTransparency = 0.18
		back.BorderSizePixel = 0
		back.Parent = bb
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 12)
		corner.Parent = back
		local stroke = Instance.new("UIStroke")
		stroke.Color = accent
		stroke.Thickness = 3
		stroke.Parent = back
		label(back, "ClassName", 0.05, 0.30, string.upper(name), Color3.fromRGB(255, 255, 255), Enum.Font.GothamBlack, 60)
		label(back, "Role", 0.36, 0.20, role, tint(accent, 1.15), Enum.Font.GothamBold, 36)
		local ptext, pcolor = priceText(cost)
		label(back, "Price", 0.56, 0.24, ptext, pcolor, Enum.Font.GothamBlack, 48)
		local tag = label(back, "PreviewTag", 0.81, 0.14, "PREVIEW", Color3.fromRGB(168, 180, 204), Enum.Font.GothamBold, 24)
		tag.TextTransparency = 0.15

		m.Parent = f
		pedestals[id] = plinth
	end
end

----------------------------------------------------------------------------------------------------
-- Invisible boundary
----------------------------------------------------------------------------------------------------

local function buildWalls(parent: Instance)
	local f = folder(parent, "Boundary")
	local h = 90
	local span = HALF * 2 + 6
	local defs: { { any } } = {
		{ Vector3.new(span, h, 2), 0, -HALF - 1 },
		{ Vector3.new(span, h, 2), 0, HALF + 1 },
		{ Vector3.new(2, h, span), HALF + 1, 0 },
		{ Vector3.new(2, h, span), -HALF - 1, 0 },
	}
	for i, d in ipairs(defs) do
		local w = mk(f, "Wall" .. i, d[1] :: Vector3, at(d[2] :: number, h / 2, d[3] :: number), Color3.fromRGB(255, 255, 255), SLAB, true)
		w.Transparency = 1
		w.CanQuery = false
	end
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

function Basecamp.Build(): Built
	local old = Workspace:FindFirstChild("SwarmV2Lobby")
	if old then
		old:Destroy()
	end
	boardLabels = {}

	local rng = Random.new(4711)
	local model = Instance.new("Model")
	model.Name = "SwarmV2Lobby"

	local gates: { [string]: GateInfo } = {}
	local pedestals: { [string]: BasePart } = {}
	local spawnPoints: { CFrame } = {}

	buildGround(model)
	buildCliffs(model, rng)
	buildTrees(model, rng)
	buildRuins(model, rng)
	buildRocks(model, rng)
	buildBonfire(model, spawnPoints)
	buildGates(model, gates)
	buildPedestals(model, pedestals)
	buildWalls(model)

	for id, info in pairs(gates) do
		info.Board.Text = boardText(boardLabels[id] or id, "", STATUS_COLOR)
	end

	model.Parent = Workspace
	local result: Built = { Model = model, Gates = gates, Pedestals = pedestals, SpawnPoints = spawnPoints }
	built = result
	return result
end

function Basecamp.SpawnCFrame(i: number): CFrame
	local list = if built then built.SpawnPoints else nil
	if list and #list > 0 then
		local idx = ((math.floor(i) - 1) % #list) + 1
		return list[idx]
	end
	local a = (i - 1) / 12 * math.pi * 2 + 0.26
	return CFrame.lookAt(P(math.cos(a) * 10.5, 3, math.sin(a) * 10.5), P(0, 3, 0))
end

function Basecamp.InGate(pos: Vector3): string?
	local dy = pos.Y - ORIGIN.Y
	if dy < 0 or dy > 10 then
		return nil
	end
	for i, def in ipairs(LobbyConfig.Gates) do
		local cx, cz = ORIGIN.X + gateX(i), ORIGIN.Z + GATE_Z
		if math.abs(pos.X - cx) <= PAD / 2 and math.abs(pos.Z - cz) <= PAD / 2 then
			return def.Id
		end
	end
	return nil
end

function Basecamp.PadCFrame(gateId: string, slot: number): CFrame
	local index = gateIndex(gateId)
	if not index then
		return Basecamp.SpawnCFrame(slot)
	end
	local s = ((math.floor(slot) - 1) % PAD_SLOTS) + 1
	-- 3 x 3 grid without the middle cell
	local cells = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }
	local c = cells[s]
	local x, z = gateX(index) + c[1] * 4.6, GATE_Z + c[2] * 4.6
	return CFrame.lookAt(P(x, 3, z), P(0, 3, 0))
end

function Basecamp.SetBoard(gateId: string, status: string, color: Color3?)
	local label = boardLabels[gateId]
	local info = if built then built.Gates[gateId] else nil
	if not label or not info then
		return
	end
	info.Board.Text = boardText(label, status, color or STATUS_COLOR)
end

function Basecamp.Bounds(): (Vector3, Vector3)
	return P(-HALF, 0, -HALF), P(HALF, 60, HALF)
end

return Basecamp
