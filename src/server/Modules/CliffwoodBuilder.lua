--[[
	CliffwoodBuilder.lua
	Builds the Cliffwood Basin (arena name "Cliffwood", plugged into MapBuilder.BuildArena):
	one ~1100 x 1100 stud map of basins, terraces, ramps, a stone bridge over a ravine and a
	cave shortcut, walled by giant cliffs instead of a fence. Everything is Parts and the
	existing prop kit (no Terrain). The design (grid, roads, ramps, main loop) is
	CliffwoodLayout; this module turns it into parts and fills the arena table.

	Tags (HeightGrid.Build reads them):
	  NavGround  every walkable surface: basin / terrace slabs, ramp slabs, the bridge deck,
	             the cave floor
	  NavBlock   cliff faces (rock blocks and their caps, terrace bodies, ramp sides, bridge
	             rails, the rim of the ravine)
	  (untagged) cave roofs, the ravine floor, decoration
	  CaveRoof / SwarmOccluder  on the cave roofs (the client may fade them over the hero)
	  LaunchPad  the spring pad part; its attribute "LaunchPad" is the world Vector3 it throws to

	Arena fields (besides the usual Obstacles / Keepout / Paths / Half):
	  Half = 550, Bounds = { MinX, MaxX, MinZ, MaxZ } (world), Spawn, Landmarks = { { Name, Pos,
	  Radius, Portal } }, LootSpots = { Vector3 } (+ LootSpotInfo = { { Pos, Kind } }),
	  LaunchPads = { { Pos, Target, Radius, Part } }, MainRoute = { Vector3 }, RouteLength,
	  Walkable(x, z) / FloorAt(x, z) (arena-relative; used by MapBuilder.FindOpenSpot and
	  FindPortalSpot), CliffwoodPlan (the grid), Stats = { Parts, ... }.
]]

local CollectionService = game:GetService("CollectionService")

local Layout = require(script.Parent.CliffwoodLayout)

local CliffwoodBuilder = {}

local GROUND_TAG, BLOCK_TAG = "NavGround", "NavBlock"

function CliffwoodBuilder.Build(arena: { [string]: any }, K: any)
	local P, mix, deco = K.P, K.mix, K.deco
	local rng = Random.new(K.Seed(arena))
	local plan = Layout.Plan()
	local N, CELL, HALF, FLOOR = plan.N, plan.CELL, plan.HALF, Layout.FLOOR_Y
	local kindAt, TAt = plan.Kind, plan.T
	local c: Vector3 = arena.Center
	local SMOOTH = Enum.Material.SmoothPlastic
	local grassMat = K.materialNamed(K.Dress.GroundMaterial, SMOOTH)
	local pathMat = K.materialNamed(K.Dress.PathMaterial, SMOOTH)
	local STONE = Enum.Material.Slate

	arena.Half = HALF
	arena.Bounds = { MinX = c.X - HALF, MaxX = c.X + HALF, MinZ = c.Z - HALF, MaxZ = c.Z + HALF }
	arena.Model:SetAttribute("NoGroundDetail", true)

	local terrain = Instance.new("Folder")
	terrain.Name = "Terrain"
	terrain.Parent = arena.Model

	------------------------------------------------------------------------------------------
	-- helpers
	------------------------------------------------------------------------------------------

	local function wpos(x: number, z: number, y: number): Vector3
		return Vector3.new(c.X + x, c.Y + y, c.Z + z)
	end

	local function tagged(p: BasePart, tagName: string?): BasePart
		if tagName then
			CollectionService:AddTag(p, tagName)
		end
		return p
	end

	-- Axis-aligned block from (x0, y0, z0) to (x1, y1, z1), arena-relative.
	local function box(parent: Instance, name: string, x0: number, x1: number, z0: number, z1: number, y0: number, y1: number, color: Color3, material: Enum.Material?, tagName: string?, solid: boolean?): BasePart
		local p = deco(parent, {
			Name = name,
			Size = Vector3.new(x1 - x0, y1 - y0, z1 - z0),
			CFrame = CFrame.new(c.X + (x0 + x1) / 2, c.Y + (y0 + y1) / 2, c.Z + (z0 + z1) / 2),
			Color = color,
			Material = material,
			CanCollide = solid == true,
			CanQuery = solid == true,
		})
		return tagged(p, tagName)
	end

	-- Greedy rectangles of equal key over the cell grid: { I0, I1, J0, J1, Key }.
	local function merge(keyAt: (number, number) -> any): { any }
		local used = {}
		for i = 1, N do
			used[i] = {}
		end
		local out = {}
		for j = 1, N do
			for i = 1, N do
				local key = keyAt(i, j)
				if key ~= nil and not used[i][j] then
					local i1 = i
					while i1 < N and not used[i1 + 1][j] and keyAt(i1 + 1, j) == key do
						i1 += 1
					end
					local j1 = j
					local grow = true
					while grow and j1 < N do
						for ii = i, i1 do
							if used[ii][j1 + 1] or keyAt(ii, j1 + 1) ~= key then
								grow = false
								break
							end
						end
						if grow then
							j1 += 1
						end
					end
					for ii = i, i1 do
						for jj = j, j1 do
							used[ii][jj] = true
						end
					end
					table.insert(out, { I0 = i, I1 = i1, J0 = j, J1 = j1, Key = key })
				end
			end
		end
		return out
	end
	local function rx0(r: any): number
		return -HALF + (r.I0 - 1) * CELL
	end
	local function rx1(r: any): number
		return -HALF + r.I1 * CELL
	end
	local function rz0(r: any): number
		return -HALF + (r.J0 - 1) * CELL
	end
	local function rz1(r: any): number
		return -HALF + r.J1 * CELL
	end

	local function cellKind(i: number, j: number): string
		if i < 1 or j < 1 or i > N or j > N then
			return "rock"
		end
		return kindAt[i][j]
	end

	local function touches(r: any, what: string): boolean
		for i = r.I0 - 1, r.I1 + 1 do
			if cellKind(i, r.J0 - 1) == what or cellKind(i, r.J1 + 1) == what then
				return true
			end
		end
		for j = r.J0, r.J1 do
			if cellKind(r.I0 - 1, j) == what or cellKind(r.I1 + 1, j) == what then
				return true
			end
		end
		return false
	end

	local ROCKS = { mix(P.stone_500, P.moss_700, 0.12), P.stone_600, mix(P.stone_500, P.stone_400, 0.5) }
	local CAP = mix(P.moss_700, P.stone_500, 0.45) -- plateau tops: darker and greyer than the floor so the lanes read from above
	local GROUND_COLOR: { [number]: Color3 } = {
		[0] = P.lawn_500,
		[9] = P.lawn_500,
		[19] = mix(P.lawn_500, P.lawn_olive, 0.2),
		[14] = mix(P.stone_300, P.lawn_500, 0.5),
		[30] = mix(P.lawn_500, P.lawn_olive, 0.35),
		[36] = mix(P.lawn_400, P.lawn_500, 0.45),
	}
	local SOIL = P.soil_400

	------------------------------------------------------------------------------------------
	-- 1. flat floors (basin, terraces, landings): NavGround slab + a rock body under raised ones
	------------------------------------------------------------------------------------------

	local floorRects = merge(function(i, j)
		if kindAt[i][j] == "walk" then
			return TAt[i][j]
		end
		return nil
	end)
	for _, r in ipairs(floorRects) do
		local y = r.Key
		local x0, x1, z0, z1 = rx0(r), rx1(r), rz0(r), rz1(r)
		box(terrain, y > 1 and "Terrace" or "Ground", x0, x1, z0, z1, y - 2, y, GROUND_COLOR[y] or P.lawn_500, grassMat, GROUND_TAG, true)
		if y > 1 or touches(r, "void") then
			box(terrain, "TerraceBody", x0, x1, z0, z1, FLOOR, y - 2, ROCKS[(r.I0 + r.J0) % 3 + 1], STONE, BLOCK_TAG, true)
		end
	end

	------------------------------------------------------------------------------------------
	-- 2. cave floor and roof, ravine floor
	------------------------------------------------------------------------------------------

	for _, r in ipairs(merge(function(i, j)
		return kindAt[i][j] == "cave" and 0 or nil
	end)) do
		box(terrain, "CaveFloor", rx0(r), rx1(r), rz0(r), rz1(r), -2, 0, mix(P.soil_500, P.stone_500, 0.35), pathMat, GROUND_TAG, true)
	end
	for _, r in ipairs(merge(function(i, j)
		return kindAt[i][j] == "cave" and plan.Roof[i][j] or nil
	end)) do
		local roof = box(terrain, "CaveRoof", rx0(r), rx1(r), rz0(r), rz1(r), Layout.CAVE_ROOF, r.Key, ROCKS[(r.I0 + r.J0) % 3 + 1], STONE, nil, true)
		CollectionService:AddTag(roof, "CaveRoof")
		K.tag(roof)
	end
	for _, r in ipairs(merge(function(i, j)
		return kindAt[i][j] == "void" and 0 or nil
	end)) do
		box(terrain, "RavineFloor", rx0(r), rx1(r), rz0(r), rz1(r), FLOOR, FLOOR + 2, mix(P.stone_700, P.moss_800, 0.5), STONE, nil, true)
	end

	------------------------------------------------------------------------------------------
	-- 3. rock mass: stacked blocks (the cliff faces), capped with forest floor up to 128
	------------------------------------------------------------------------------------------

	for _, r in ipairs(merge(function(i, j)
		if kindAt[i][j] ~= "rock" then
			return nil
		end
		-- the band near the open floor gets a forest-floor cap, the mass behind it is one block
		return plan.H[i][j] + (plan.Dist[i][j] < 60 and 0.5 or 0)
	end)) do
		local h = math.floor(r.Key)
		local near = r.Key ~= h
		local x0, x1, z0, z1 = rx0(r), rx1(r), rz0(r), rz1(r)
		if near then
			box(terrain, "Cliff", x0, x1, z0, z1, FLOOR, h - 1.1, ROCKS[(r.I0 * 3 + r.J0) % 3 + 1], STONE, BLOCK_TAG, true)
			if h <= 128 then
				box(terrain, "CliffTop", x0, x1, z0, z1, h - 1.2, h, CAP, grassMat, BLOCK_TAG, true)
			end
		else
			box(terrain, "Mass", x0, x1, z0, z1, FLOOR, h, h <= 128 and CAP or ROCKS[(r.I0 * 3 + r.J0) % 3 + 1], STONE, BLOCK_TAG, true)
		end
	end

	-- rocks standing against the faces that look toward the camera (decoration, a little
	-- sunk into the face so nothing sticks out into the lane)
	do
		local facePal = { Stone = ROCKS[1], Stone2 = P.stone_600, Moss = CAP }
		local dirs = { { 1, 0 }, { -1, 0 }, { 0, 1 } } -- east, west, south (north faces look away from the camera)
		for i = 2, N - 1 do
			for j = 2, N - 1 do
				if kindAt[i][j] == "rock" then
					for _, d in ipairs(dirs) do
						local k = kindAt[i + d[1]][j + d[2]]
						if (k == "walk" or k == "ramp" or k == "cave") and rng:NextNumber() < 0.11 then
							local h = plan.H[i][j]
							local s = math.clamp(h * 0.085, 2.4, 4.6)
							local fx = -HALF + (i - 0.5) * CELL + d[1] * (CELL / 2 - 1.6)
							local fz = -HALF + (j - 0.5) * CELL + d[2] * (CELL / 2 - 1.6)
							local y = plan.T[i + d[1]][j + d[2]] or 0
							local cf = CFrame.new(wpos(fx, fz, y - 0.6)) * K.yawCF(rng:NextNumber(0, 360))
							K.prop(arena.Decor, "Rock", cf, s, facePal, { shadow = false })
						end
					end
				end
			end
		end
	end

	-- forest on the rock tops that the camera can see (decoration only)
	for i = 2, N - 1 do
		for j = 2, N - 1 do
			if kindAt[i][j] == "rock" and plan.H[i][j] <= 128 and plan.Dist[i][j] < 90 and rng:NextNumber() < 0.014 then
				local x = -HALF + (i - 0.5) * CELL + rng:NextNumber(-3, 3)
				local z = -HALF + (j - 0.5) * CELL + rng:NextNumber(-3, 3)
				local name = rng:NextNumber() < 0.7 and "Tree_PineTall" or "Tree_Round"
				local pal = name == "Tree_Round" and K.ForestRound[rng:NextInteger(1, 3)] or K.ForestPine[rng:NextInteger(1, 3)]
				K.prop(arena.Decor, name, CFrame.new(wpos(x, z, plan.H[i][j] - 0.8)) * K.yawCF(rng:NextNumber(0, 360)), rng:NextNumber(1.9, 2.7), pal, { occluder = true, shadow = false })
			end
		end
	end

	------------------------------------------------------------------------------------------
	-- 4. ramps (slab + solid sides) and the winding ramp's landings
	------------------------------------------------------------------------------------------

	local function surfaceCF(ax: number, az: number, ay: number, bx: number, bz: number, by: number): (CFrame, number)
		local a, b = wpos(ax, az, ay), wpos(bx, bz, by)
		local mid = (a + b) / 2
		return CFrame.lookAt(mid, b), (b - a).Magnitude
	end

	for _, r in ipairs(plan.Ramps) do
		local cf, len = surfaceCF(r.Ax, r.Az, r.Ay, r.Bx, r.Bz, r.By)
		local slabCF = cf * CFrame.new(0, -1.75, 0)
		local p = deco(terrain, { Name = "Ramp", Size = Vector3.new(r.W, 3.5, len + 1), CFrame = slabCF, Color = mix(P.soil_400, P.lawn_500, 0.25), Material = pathMat, CanCollide = true, CanQuery = true })
		tagged(p, GROUND_TAG)
		-- solid sides: one block per 8 studs under the slope
		local yaw = math.atan2(-r.Dx, -r.Dz)
		local step = 8
		local s = step / 2
		while s < r.Len do
			local sy = r.Ay + r.Rise * s / r.Len
			local top = sy - 3.1
			if top > -1 then
				local mx, mz = r.Ax + r.Dx * s, r.Az + r.Dz * s
				local side = deco(terrain, {
					Name = "RampSide",
					Size = Vector3.new(r.W, top + 2, step + 0.4),
					CFrame = CFrame.new(wpos(mx, mz, (top - 2) / 2)) * CFrame.Angles(0, yaw, 0),
					Color = ROCKS[(math.floor(s / step) % 3) + 1],
					Material = STONE,
					CanCollide = true,
					CanQuery = true,
				})
				tagged(side, BLOCK_TAG)
			end
			s += step
		end
	end

	------------------------------------------------------------------------------------------
	-- 5. the stone bridge over the ravine
	------------------------------------------------------------------------------------------

	local br = Layout.Bridge
	local ALONG, SIDE = Layout.Along, Layout.Side
	local function bridgeY(s: number): number
		return br.Y0 + (br.Y1 - br.Y0) * (s - br.S0) / (br.S1 - br.S0)
	end
	do
		local ax, az = ALONG[1] * br.S0, ALONG[2] * br.S0
		local bx, bz = ALONG[1] * br.S1, ALONG[2] * br.S1
		local cf, len = surfaceCF(ax, az, br.Y0, bx, bz, br.Y1)
		local deckColor = mix(P.stone_300, P.ivory_500, 0.25)
		local deck = deco(terrain, { Name = "BridgeDeck", Size = Vector3.new(br.W, 3.5, len + 0.5), CFrame = cf * CFrame.new(0, -1.75, 0), Color = deckColor, Material = Enum.Material.Cobblestone, CanCollide = true, CanQuery = true })
		tagged(deck, GROUND_TAG)
		-- stone arch band under the deck, rails on both sides
		deco(terrain, { Name = "BridgeBand", Size = Vector3.new(br.W - 6, 5, len - 6), CFrame = cf * CFrame.new(0, -5.5, 0), Color = mix(P.stone_400, P.stone_500, 0.5), Material = STONE, CanCollide = true, CanQuery = true })
		for _, side in ipairs({ -1, 1 }) do
			local rail = deco(terrain, { Name = "BridgeRail", Size = Vector3.new(1.8, 3.2, len), CFrame = cf * CFrame.new(side * (br.W / 2 - 0.9), 1.6, 0), Color = mix(P.stone_400, P.ivory_500, 0.3), Material = STONE, CanCollide = true, CanQuery = true })
			tagged(rail, BLOCK_TAG)
		end
		local yaw = math.atan2(-ALONG[1], -ALONG[2])
		local s = br.S0 + 14
		while s < br.S1 - 6 do
			local sy = bridgeY(s)
			local mx, mz = ALONG[1] * s, ALONG[2] * s
			-- posts on both rails
			for _, side in ipairs({ -1, 1 }) do
				local px, pz = mx + SIDE[1] * side * (br.W / 2 - 0.9), mz + SIDE[2] * side * (br.W / 2 - 0.9)
				deco(terrain, { Name = "BridgePost", Size = Vector3.new(3.2, 5.4, 3.2), CFrame = CFrame.new(wpos(px, pz, sy + 2.2)) * CFrame.Angles(0, yaw, 0), Color = mix(P.stone_300, P.ivory_500, 0.3), Material = STONE, CanCollide = true, CanQuery = false })
			end
			local k = plan.Kind[Layout.CellIndex(mx)][Layout.CellIndex(mz)]
			-- solid sides while the deck is still over the ground
			if k == "walk" and plan.T[Layout.CellIndex(mx)][Layout.CellIndex(mz)] <= 1 then
				local top = sy - 3.2
				if top > 0.5 then
					local p = deco(terrain, { Name = "BridgeSide", Size = Vector3.new(br.W, top + 2, 30), CFrame = CFrame.new(wpos(mx, mz, (top - 2) / 2)) * CFrame.Angles(0, yaw, 0), Color = ROCKS[1], Material = STONE, CanCollide = true, CanQuery = true })
					tagged(p, BLOCK_TAG)
				end
			elseif k == "void" then
				-- arch piers over the drop: two columns and a cross beam
				for _, side in ipairs({ -1, 1 }) do
					local px, pz = mx + SIDE[1] * side * 11, mz + SIDE[2] * side * 11
					deco(terrain, { Name = "BridgePier", Size = Vector3.new(7, sy - 8 - FLOOR, 7), CFrame = CFrame.new(wpos(px, pz, FLOOR + (sy - 8 - FLOOR) / 2)) * CFrame.Angles(0, yaw, 0), Color = mix(P.stone_400, P.stone_500, 0.4), Material = STONE, CanCollide = true, CanQuery = false })
				end
				deco(terrain, { Name = "BridgeBeam", Size = Vector3.new(br.W - 6, 4, 8), CFrame = CFrame.new(wpos(mx, mz, sy - 9)) * CFrame.Angles(0, yaw, 0), Color = mix(P.stone_400, P.stone_500, 0.4), Material = STONE, CanCollide = true, CanQuery = false })
			end
			s += 30
		end
	end

	-- a low invisible rim where the ground meets the drop (keeps the hero off the edge)
	do
		local bridgeAxis = function(x: number, z: number): boolean
			local s, p = Layout.RavineCoords(x, z)
			return s >= br.S0 - 20 and s <= br.S1 and math.abs(p) <= br.W / 2 + 6
		end
		for i = 2, N - 1 do
			for j = 2, N - 1 do
				if kindAt[i][j] == "walk" and TAt[i][j] <= 1 then
					local x, z = -HALF + (i - 0.5) * CELL, -HALF + (j - 0.5) * CELL
					if not bridgeAxis(x, z) then
						for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
							if kindAt[i + d[1]][j + d[2]] == "void" then
								local p = deco(terrain, { Name = "RavineRim", Size = Vector3.new(CELL, 14, CELL), CFrame = CFrame.new(wpos(x + d[1] * 2, z + d[2] * 2, 7)), Transparency = 1, CanCollide = true, CanQuery = false })
								tagged(p, BLOCK_TAG)
								break
							end
						end
					end
				end
			end
		end
	end

	------------------------------------------------------------------------------------------
	-- 6. paths (dirt strips on the flat roads, registered for decoration / ground detail)
	------------------------------------------------------------------------------------------

	local paths = Layout.Paths(plan)
	for _, seg in ipairs(paths) do
		local a, b = seg.A, seg.B
		table.insert(arena.Paths, { A = Vector3.new(a[1], 0, a[2]), B = Vector3.new(b[1], 0, b[2]), W = seg.W, Main = seg.Main })
		if seg.Flat then
			local mx, mz = (a[1] + b[1]) / 2, (a[2] + b[2]) / 2
			local fy = plan.FloorAt(mx, mz)
			local fa, fb = plan.FloorAt(a[1], a[2]), plan.FloorAt(b[1], b[2])
			local dx, dz = b[1] - a[1], b[2] - a[2]
			local len = math.sqrt(dx * dx + dz * dz)
			if fy and fa and fb and fy == fa and fa == fb and len > 0.5 then
				K.slab(arena.Decor, "Path", wpos(mx, mz, fy + 0.12), 14, len + 1.6, math.atan2(-dx, -dz), SOIL, 0.2, pathMat)
			end
		end
	end
	local pathSegs = paths
	local function laneDist(x: number, z: number): number
		local best = math.huge
		for _, seg in ipairs(pathSegs) do
			local a, b = seg.A, seg.B
			local dx, dz = b[1] - a[1], b[2] - a[2]
			local len2 = dx * dx + dz * dz
			local t = len2 > 0 and math.clamp(((x - a[1]) * dx + (z - a[2]) * dz) / len2, 0, 1) or 0
			local qx, qz = a[1] + dx * t - x, a[2] + dz * t - z
			best = math.min(best, math.sqrt(qx * qx + qz * qz) - seg.W)
		end
		return best
	end

	------------------------------------------------------------------------------------------
	-- 7. landmarks
	------------------------------------------------------------------------------------------

	local solids: { { number } } = {} -- { x, z, r } of everything that stands on the floor
	local function addSolid(x: number, z: number, r: number)
		table.insert(solids, { x, z, r })
	end
	local function spotFree(x: number, z: number, r: number): boolean
		for _, s in ipairs(solids) do
			local dx, dz = x - s[1], z - s[2]
			local rr = r + s[3]
			if dx * dx + dz * dz < rr * rr then
				return false
			end
		end
		return true
	end
	local function onFlat(x: number, z: number, y: number, pad: number): boolean
		for _, d in ipairs({ { 0, 0 }, { pad, 0 }, { -pad, 0 }, { 0, pad }, { 0, -pad } }) do
			local fy = plan.FloorAt(x + d[1], z + d[2])
			local i, j = Layout.CellIndex(x + d[1]), Layout.CellIndex(z + d[2])
			if fy ~= y or plan.Kind[i][j] ~= "walk" then
				return false
			end
		end
		return true
	end

	local function standingStone(x: number, z: number, y: number, hgt: number, yawDeg: number)
		local m = Instance.new("Model")
		m.Name = "StandingStone"
		local cf = CFrame.new(wpos(x, z, y + hgt / 2 - 0.3)) * CFrame.Angles(0, math.rad(yawDeg), 0) * CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), 0, math.rad(rng:NextNumber(-5, 5)))
		deco(m, { Name = "Stone", Size = Vector3.new(4.6, hgt, 2.8), CFrame = cf, Color = mix(P.stone_500, P.stone_600, rng:NextNumber(0, 0.6)), CastShadow = true })
		deco(m, { Name = "Cap", Size = Vector3.new(4.0, 1.0, 2.4), CFrame = cf * CFrame.new(0, hgt / 2 + 0.1, 0) * CFrame.Angles(0, 0, math.rad(rng:NextNumber(-10, 10))), Color = P.stone_400 })
		deco(m, { Name = "Moss", Size = Vector3.new(4.7, hgt * 0.35, 2.9), CFrame = cf * CFrame.new(0, -hgt * 0.3, 0), Color = P.moss_600 })
		K.tag(m)
		m.Parent = arena.Model
		K.circleCollider(arena, c.X + x, c.Z + z, 2.4, hgt, c.Y + y)
		addSolid(x, z, 3.5)
	end

	local function place(name: string, x: number, z: number, y: number, yaw: number, s: number, pal: any?, occ: boolean?, pad: number?)
		K.obstacleAt(arena, name, x, z, y, yaw, s, pal, { occluder = occ })
		addSolid(x, z, pad or (K.kitEntry(name) and 3 * s or 3))
	end

	local function decorProp(name: string, x: number, z: number, y: number, yaw: number, s: number, pal: any?)
		K.prop(arena.Decor, name, CFrame.new(wpos(x, z, y)) * K.yawCF(yaw), s, pal, { shadow = false })
	end

	local function torch(x: number, z: number, y: number, yaw: number)
		K.obstacleAt(arena, "Torch", x, z, y, yaw, 1.4, K.TorchFlame, nil)
		K.pointLight(arena.Model, wpos(x, z, y + 6), 22, 1.8, K.TorchFire, true)
		arena.Lights += 1
	end

	local landmarks: { any } = {}
	local function landmark(name: string, x: number, z: number, y: number, r: number, portal: boolean)
		table.insert(landmarks, { Name = name, Pos = wpos(x, z, y), Radius = r, Portal = portal })
	end
	-- exclusion circles for the scattered trees
	local excl: { { number } } = {}
	local function exclude(x: number, z: number, r: number)
		table.insert(excl, { x, z, r })
	end

	-- Stone Circle (boss landmark): a huge weathered arch, a ring of standing stones, an altar
	do
		local sc = Layout.Clearings[2]
		local cx, cz = sc.X, sc.Z
		for k = 0, 11 do
			local a = k / 12 * math.pi * 2 + 0.2
			-- gaps in the south (the road from the basin) and the east (the road on); leaning stones elsewhere
			local sx, sz = cx + math.cos(a) * 38, cz + math.sin(a) * 38
			local southGap = math.sin(a) > 0.7 and math.abs(math.cos(a)) < 0.45
			local eastGap = math.cos(a) > 0.75 and math.abs(math.sin(a)) < 0.5
			if not southGap and not eastGap then
				standingStone(sx, sz, 0, rng:NextNumber(8.5, 13), math.deg(-a) + 90 + rng:NextNumber(-8, 8))
			end
		end
		for k = 0, 5 do
			local a = k / 6 * math.pi * 2 + 0.5
			decorProp("Rock_Small", cx + math.cos(a) * 24, cz + math.sin(a) * 24, 0, rng:NextNumber(0, 360), 1.8, nil)
		end
		decorProp("Rock_Slab", cx, cz, -0.3, 20, 3.2, nil)
		K.disc(arena.Decor, "RuneRing", wpos(cx, cz, 0.3), 15, mix(P.stone_300, P.lawn_500, 0.3), 0.1)
		K.disc(arena.Decor, "RuneRing", wpos(cx, cz, 0.36), 10, mix(P.stone_400, P.lawn_500, 0.5), 0.1)
		-- the arch on the north rim, open at its base
		place("Ruin_Arch", cx + 4, cz - 56, 0, 0, 4.4, nil, true, 8)
		for _, dx in ipairs({ -34, 36 }) do
			place("Pillar", cx + dx, cz - 52, 0, rng:NextNumber(0, 360), 3.0, nil, true, 6)
		end
		place("Ruin_Wall", cx - 52, cz - 46, 0, 20, 2.6, nil, true, 10)
		place("Ruin_WallLow", cx + 56, cz - 44, 0, 160, 2.8, nil, false, 9)
		for _, p in ipairs({ { -46, 20 }, { 30, 44 } }) do
			place("Rock", cx + p[1], cz + p[2], 0, rng:NextNumber(0, 360), 2.4, nil, false, 6)
		end
		K.keepout(arena, cx, cz - 56, 24)
		K.keepout(arena, cx, cz, 14)
		exclude(cx, cz, 50)
		landmark("Stone Circle", cx, cz, 0, 60, true)
	end

	-- Old Ruins: a broken courtyard on a raised terrace
	do
		local oc = Layout.Clearings[3]
		local cx, cz, y = oc.X, oc.Z, oc.Y
		K.disc(arena.Decor, "Courtyard", wpos(cx, cz, y + 0.1), 34, mix(P.stone_300, P.ivory_500, 0.25), 0.1)
		K.disc(arena.Decor, "Courtyard", wpos(cx, cz, y + 0.16), 20, mix(P.stone_400, P.ivory_500, 0.3), 0.1)
		for k = 0, 9 do
			local a = k / 10 * math.pi * 2 + 0.15
			-- entrances: west (the ramp up) and south (the ramp on)
			local south = math.sin(a) > 0.75 and math.abs(math.cos(a)) < 0.5
			local west = math.cos(a) < -0.8
			if not south and not west then
				local px, pz = cx + math.cos(a) * 40, cz + math.sin(a) * 40
				if k % 3 == 0 then
					place("Pillar", px, pz, y, rng:NextNumber(0, 360), 2.2, nil, true, 5)
				else
					place(k % 2 == 0 and "Ruin_Wall" or "Ruin_WallLow", px, pz, y, math.deg(-a) + 90, 2.0, nil, k % 2 == 0, 9)
				end
			end
		end
		place("Ruin_Arch", cx - 6, cz - 38, y, 0, 2.4, nil, true, 8)
		for _, p in ipairs({ { 26, -16 }, { 30, 12 }, { -30, -30 }, { 22, -36 } }) do
			place("Ruin_Block", cx + p[1], cz + p[2], y, rng:NextNumber(0, 360), 1.6, nil, false, 3)
		end
		torch(cx - 22, cz - 26, y, 0)
		torch(cx + 22, cz - 26, y, 0)
		exclude(cx, cz, 46)
		landmark("Old Ruins", cx, cz, y, 50, true)
	end

	-- Hollow Spring: a pond with a shrine, mossy rocks and a deep grove
	do
		local hs = Layout.Clearings[4]
		local cx, cz = hs.X, hs.Z
		K.disc(arena.Decor, "PondBank", wpos(cx, cz, 0.08), 17, mix(P.dirt_600, P.moss_600, 0.35))
		K.disc(arena.Decor, "PondBed", wpos(cx, cz, 0.12), 14.6, P.slate_700)
		local water = K.disc(arena.Decor, "Water", wpos(cx, cz, 0.2), 14, mix(P.slate_500, P.moss_500, 0.25))
		water.Transparency = 0.12
		water.Reflectance = 0.06
		K.circleCollider(arena, c.X + cx, c.Z + cz, 14, 4, c.Y)
		addSolid(cx, cz, 17)
		for k = 0, 7 do
			local a = k / 8 * math.pi * 2 + 0.3
			if k % 2 == 0 then
				place("Rock", cx + math.cos(a) * 19, cz + math.sin(a) * 19, 0, rng:NextNumber(0, 360), rng:NextNumber(1.4, 2.0), nil, false, 5)
			else
				decorProp("Mushroom", cx + math.cos(a) * 18, cz + math.sin(a) * 18, 0, rng:NextNumber(0, 360), 1.6, nil)
			end
		end
		place("Shrine", cx, cz - 34, 0, 180, 1.8, nil, true, 6)
		torch(cx - 8, cz - 30, 0, 0)
		torch(cx + 8, cz - 30, 0, 0)
		exclude(cx, cz, 26)
		K.keepout(arena, cx, cz, 20)
		landmark("Hollow Spring", cx, cz, 0, 50, true)
	end

	-- Bramble Field: thorny thickets with gaps, fallen logs
	do
		local bf = Layout.Clearings[5]
		local cx, cz = bf.X, bf.Z
		local thorn = { Leaves = mix(P.moss_800, P.crimson_700 or P.moss_700, 0.28), Leaves2 = mix(P.moss_700, P.crimson_600 or P.moss_600, 0.2) }
		for k = 1, 9 do
			local a = k / 9 * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
			local d = rng:NextNumber(20, 46)
			local tx, tz = cx + math.cos(a) * d, cz + math.sin(a) * d
			if laneDist(tx, tz) > 6 then
				for _ = 1, 4 do
					local bx, bz = tx + rng:NextNumber(-6, 6), tz + rng:NextNumber(-6, 6)
					if onFlat(bx, bz, 0, 3) then
						decorProp("Bush", bx, bz, 0, rng:NextNumber(0, 360), rng:NextNumber(2.2, 3.0), thorn)
					end
				end
				addSolid(tx, tz, 8)
			end
		end
		for _, p in ipairs({ { 32, -16, 0 }, { 24, 30, 90 } }) do
			place("Log", cx + p[1], cz + p[2], 0, p[3], 1.5, nil, false, 5)
		end
		for _, p in ipairs({ { -38, 20 }, { 34, 30 } }) do
			place("Stump", cx + p[1], cz + p[2], 0, rng:NextNumber(0, 360), 1.5, nil, false, 3)
		end
		exclude(cx, cz, 22)
		landmark("Bramble Field", cx, cz, 0, 55, true)
	end

	-- Upper Terrace: a ruined arch and pillars on the bench, the landing mark of the launch pad
	do
		local ut = Layout.UpperTerrace
		local y = ut.Y
		place("Ruin_Arch", 376, -60, y, 90, 2.6, nil, true, 8)
		for _, p in ipairs({ { 305, -92 }, { 372, -92 }, { 298, 52 }, { 380, 40 } }) do
			place("Pillar", p[1], p[2], y, rng:NextNumber(0, 360), 2.0, nil, true, 5)
		end
		place("Ruin_WallLow", 376, 66, y, 90, 2.4, nil, false, 8)
		for _, p in ipairs({ { 356, 10 }, { 318, 26 } }) do
			place("Rock", p[1], p[2], y, rng:NextNumber(0, 360), 2.0, nil, false, 5)
		end
		local lp = Layout.LaunchPad
		K.disc(arena.Decor, "LandingMark", wpos(lp.Target[1], lp.Target[2], y + 0.12), 7.5, mix(P.gold_300, P.lawn_500, 0.4), 0.1)
		exclude(lp.Target[1], lp.Target[2], 12)
		exclude(376, -60, 22)
		landmark("Upper Terrace", 338, -10, y, 60, true)
	end

	-- Overlook: a lookout ring of pillars on the plateau at the end of the bridge
	do
		local ov = Layout.Clearings[6]
		local cx, cz, y = ov.X, ov.Z, ov.Y
		for k = 0, 7 do
			local a = k / 8 * math.pi * 2 + 0.4
			-- the bridge arrives from the south-east: leave that side open
			if not (math.cos(a) > 0.55 and math.sin(a) > 0.55) then
				place("Pillar", cx + math.cos(a) * 40, cz + math.sin(a) * 40, y, rng:NextNumber(0, 360), 2.2, nil, true, 5)
			end
		end
		decorProp("Rock_Slab", cx, cz, y - 0.3, 35, 2.6, nil)
		place("Banner", cx - 8, cz - 14, y, 180, 1.8, nil, true, 3)
		place("Banner", cx + 8, cz - 14, y, 180, 1.8, nil, true, 3)
		torch(cx - 14, cz - 10, y, 0)
		torch(cx + 14, cz - 10, y, 0)
		exclude(cx, cz, 46)
		landmark("Overlook", cx, cz, y, 58, true)
	end

	-- Cave Shortcut: torches inside, boulders at both mouths
	do
		for _, x in ipairs({ -110, -150, -190 }) do
			K.pointLight(arena.Model, wpos(x, 5 + (x % 20 == 0 and 11 or -11), 6), 30, 1.5, K.TorchFire, true)
			arena.Lights += 1
		end
		for _, x in ipairs({ -108, -212 }) do
			for _, sgn in ipairs({ -1, 1 }) do
				decorProp("Torch", x, 5 + sgn * 15, 0, 0, 1.3, K.TorchFlame)
			end
		end
		for _, p in ipairs({ { -88, -7 }, { -88, 17 }, { -234, -7 }, { -234, 17 } }) do
			decorProp("Rock", p[1], p[2], 0, rng:NextNumber(0, 360), 1.5, nil)
		end
		exclude(-160, 5, 70)
		landmark("CaveShortcut", -160, 5, 0, 22, false)
	end

	-- Main Basin: open meadow (the spawn); a few big stones at the rim
	do
		for _, p in ipairs({ { 34, -58, 2.2 }, { -54, 42, 2.0 } }) do
			if onFlat(p[1], p[2], 0, 3) then
				place("Rock", p[1], p[2], 0, rng:NextNumber(0, 360), p[3], nil, false, 6)
			end
		end
		exclude(0, 0, 46)
		K.keepout(arena, 0, 0, 12)
		landmark("Main Basin", 0, 0, 0, 72, false)
	end

	-- the spring launch pad: basin -> Upper Terrace (the run code throws the hero; this only
	-- places the pad and records where it points)
	do
		local lp = Layout.LaunchPad
		local x, z = lp.Pos[1], lp.Pos[2]
		local base = wpos(x, z, 0)
		K.disc(arena.Decor, "PadRing", wpos(x, z, 0.3), 8.5, P.stone_400, 0.2)
		for k = 1, 3 do
			K.disc(arena.Decor, "PadCoil", wpos(x, z, 0.35 + k * 0.5), 5.2 - k * 0.4, k % 2 == 0 and P.gold_500 or P.stone_300, 0.4)
		end
		local pad = deco(arena.Model, {
			Name = "LaunchPad",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.0, lp.Radius * 2, lp.Radius * 2),
			CFrame = CFrame.new(base + Vector3.new(0, 2.4, 0)) * K.UPRIGHT,
			Color = P.moss_300,
			Material = Enum.Material.Neon,
		})
		local floorY = plan.FloorAt(lp.Target[1], lp.Target[2]) or 30
		local target = wpos(lp.Target[1], lp.Target[2], floorY)
		pad:SetAttribute("LaunchPad", target)
		CollectionService:AddTag(pad, "LaunchPad")
		arena.LaunchPads = { { Pos = base, Target = target, Radius = lp.Radius, Part = pad } }
		exclude(x, z, 14)
		K.keepout(arena, x, z, 10)
	end

	------------------------------------------------------------------------------------------
	-- 8. trees, bushes, boulders on the open floor (nothing in the lanes or on the cliffs)
	------------------------------------------------------------------------------------------

	local ZONES = {
		{ Layout.Clearings[1], 0.30 },
		{ Layout.Clearings[2], 0.22 },
		{ Layout.Clearings[3], 0.22 },
		{ Layout.Clearings[4], 0.45 },
		{ Layout.Clearings[5], 0.30 },
		{ Layout.Clearings[6], 0.22 },
		{ Layout.Pockets[1], 0.36 },
		{ Layout.Pockets[2], 0.36 },
		{ Layout.Pockets[3], 0.36 },
	}
	local function density(x: number, z: number, y: number): number
		for _, zone in ipairs(ZONES) do
			local cl = zone[1]
			local dx, dz = x - cl.X, z - cl.Z
			if dx * dx + dz * dz <= (cl.R + 8) ^ 2 then
				return zone[2]
			end
		end
		return y == 30 and 0.18 or 0.30
	end

	local trees = 0
	for i = 2, N - 1 do
		for j = 2, N - 1 do
			if kindAt[i][j] == "walk" then
				local y = TAt[i][j]
				local x = -HALF + (i - 1) * CELL + rng:NextNumber(1.5, 8.5)
				local z = -HALF + (j - 1) * CELL + rng:NextNumber(1.5, 8.5)
				local roll = rng:NextNumber()
				local inExcl = false
				for _, e in ipairs(excl) do
					local dx, dz = x - e[1], z - e[2]
					if dx * dx + dz * dz < e[3] * e[3] then
						inExcl = true
						break
					end
				end
				if not inExcl and x * x + z * z > 52 * 52 and laneDist(x, z) > 4 and onFlat(x, z, y, 5) then
					local p = density(x, z, y)
					if roll < p then
						if spotFree(x, z, 5) then
							local k = rng:NextNumber()
							local name = k < 0.4 and "Tree_Pine" or (k < 0.65 and "Tree_PineTall" or "Tree_Round")
							local pal = name == "Tree_Round" and K.ForestRound[rng:NextInteger(1, 3)] or K.ForestPine[rng:NextInteger(1, 3)]
							local s = rng:NextNumber(1.35, 1.9)
							K.obstacleAt(arena, name, x, z, y, rng:NextNumber(0, 360), s, pal, { occluder = true })
							arena.Trees += 1
							trees += 1
							addSolid(x, z, 2.6 * s)
						end
					elseif roll < p + 0.035 then
						if spotFree(x, z, 5) then
							local s = rng:NextNumber(1.5, 2.6)
							K.obstacleAt(arena, "Rock", x, z, y, rng:NextNumber(0, 360), s, nil, nil)
							arena.Rocks += 1
							addSolid(x, z, 2.4 * s)
						end
					elseif roll < p + 0.035 + 0.10 and spotFree(x, z, 2) then
						decorProp("Bush", x, z, y, rng:NextNumber(0, 360), rng:NextNumber(1.3, 1.9), nil)
					end
				end
			end
		end
	end

	------------------------------------------------------------------------------------------
	-- 9. boundary walls for the enemies' raycasts, spawn, route, loot spots
	------------------------------------------------------------------------------------------

	for _, side in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
		local horizontal = side[1] == 0
		local wall = deco(arena.ObstacleFolder, {
			Name = "Boundary",
			Size = horizontal and Vector3.new(HALF * 2 + 4, 400, 2) or Vector3.new(2, 400, HALF * 2 + 4),
			CFrame = CFrame.new(c + Vector3.new(side[1] * (HALF + 1), 200, side[2] * (HALF + 1))),
			Transparency = 1,
			CanCollide = true,
			CanQuery = true,
		})
		wall.Parent = arena.ObstacleFolder
	end

	arena.Walkable = plan.Interior
	arena.FloorAt = plan.FloorAt
	arena.CliffwoodPlan = plan
	arena.Landmarks = landmarks
	arena.Spawn = wpos(0, 0, 3)

	local route, routeLen = Layout.MainLoop(plan)
	arena.MainRoute = {}
	for _, p in ipairs(route) do
		table.insert(arena.MainRoute, wpos(p[1], p[2], p[3]))
	end
	arena.RouteLength = routeLen

	-- loot: a spot beside the road about every 260 studs of the main loop, then the landmarks,
	-- the cave and the dead-end pockets (riskier, richer)
	local spots: { { Pos: Vector3, Kind: string } } = {}
	local function nearestFree(x: number, z: number, y: number?, allowCave: boolean?): Vector3?
		for ring = 0, 6 do
			for k = 0, (ring == 0 and 0 or 7) do
				local a = k / 8 * math.pi * 2
				local px, pz = x + math.cos(a) * ring * 7, z + math.sin(a) * ring * 7
				local fy = plan.FloorAt(px, pz)
				local ci, cj = Layout.CellIndex(px), Layout.CellIndex(pz)
				local okKind = plan.Interior(px, pz) or (allowCave and plan.Kind[ci][cj] == "cave")
				if fy and okKind and (y == nil or math.abs(fy - y) < 1) and px * px + pz * pz > 60 * 60 and spotFree(px, pz, 4.5) then
					return wpos(px, pz, fy)
				end
			end
		end
		return nil
	end
	local function addSpot(x: number, z: number, kind: string, y: number?, allowCave: boolean?)
		local p = nearestFree(x, z, y, allowCave)
		if p then
			for _, s in ipairs(spots) do
				if (s.Pos - p).Magnitude < 120 then
					return
				end
			end
			table.insert(spots, { Pos = p, Kind = kind })
		end
	end
	do
		-- along the main loop: offset to the side of the road, never on the centre line
		local acc, next = 0, 150
		for k = 2, #route do
			local a, b = route[k - 1], route[k]
			local seg = math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2 + (b[3] - a[3]) ^ 2)
			acc += seg
			if acc >= next then
				local dx, dz = b[1] - a[1], b[2] - a[2]
				local l = math.max(math.sqrt(dx * dx + dz * dz), 0.001)
				-- sideways to the road (try both sides)
				if seg > 0.1 and b[3] == a[3] then
					addSpot(b[1] - dz / l * 15, b[2] + dx / l * 15, "Route", b[3])
					addSpot(b[1] + dz / l * 15, b[2] - dx / l * 15, "Route", b[3])
				end
				next += 260
			end
		end
	end
	addSpot(300, -318, "Ruins", 14)
	addSpot(-10, -270, "Circle", 0)
	addSpot(338, -10, "Terrace", 30)
	addSpot(290, 300, "Bramble", 0)
	addSpot(-330, 62, "Spring", 0)
	addSpot(-330, -330, "Overlook", 36)
	addSpot(-160, 5, "Cave", 0, true)
	addSpot(-290, 210, "SouthRoad", 0)
	addSpot(70, 250, "SouthRoad", 0)
	for _, pk in ipairs(Layout.Pockets) do
		addSpot(pk.X, pk.Z, "Pocket", 0)
	end
	arena.LootSpots = {}
	arena.LootSpotInfo = {}
	for _, s in ipairs(spots) do
		table.insert(arena.LootSpots, s.Pos)
		table.insert(arena.LootSpotInfo, s)
	end

	-- counts for the metrics script
	local parts = 0
	for _, d in ipairs(arena.Model:GetDescendants()) do
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	arena.Stats = { Parts = parts, Trees = trees, Rects = #floorRects }
end

return CliffwoodBuilder
