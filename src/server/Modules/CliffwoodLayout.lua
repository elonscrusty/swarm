--[[
	CliffwoodLayout.lua
	The design of the Cliffwood Basin as plain numbers (no Roblox types, so it also runs in
	plain Lune: tools/cliffwood_metrics.luau). CliffwoodBuilder turns this plan into parts.

	Coordinates are arena-relative studs: x east, z south (north is -z), y up from the basin
	floor. The map is a 110 x 110 grid of 10 stud cells (1100 x 1100). Every cell is one of:
	  rock    solid cliff mass (never walkable); tops rise from ~30 above the walkable floor next
	          to the play space to 180 at the map edge
	  walk    a flat walkable level (T = its height: 0 basin floor, 14 Old Ruins, 30 Upper
	          Terrace, 36 Overlook, 9 / 19 ramp landings)
	  ramp    a sloped walkable surface (T = height at the cell centre)
	  cave    walkable floor under a roof (the Cave Shortcut)
	  void    a drop (the ravine under the bridge); nothing walkable

	Routes (all >= 24 studs wide, no essential jump):
	  main loop   Basin -> Stone Circle -> Old Ruins -> Upper Terrace -> Bramble Field -> Basin
	  loop A      Basin -> Cave Shortcut -> Hollow Spring -> south road -> Basin
	  loop B      Basin <-> Bramble Field by a north road (main loop) and a south road
	  spurs       winding ramp Basin -> Upper Terrace, stone bridge Basin -> Overlook,
	              three dead-end pockets
]]

local Layout = {}

local CELL = 10
local HALF = 550
local N = 110
local FLOOR_Y = -42

Layout.CELL = CELL
Layout.HALF = HALF
Layout.N = N
Layout.FLOOR_Y = FLOOR_Y
Layout.CAVE_ROOF = 16 -- height of the cave ceiling above its floor
Layout.WALK_SPEED = 22

------------------------------------------------------------------------------------------
-- DESIGN DATA
------------------------------------------------------------------------------------------

-- Round clearings (x, z, radius, floor height).
Layout.Clearings = {
	{ Name = "MainBasin", X = 0, Z = 0, R = 72, Y = 0 },
	{ Name = "StoneCircle", X = -10, Z = -330, R = 70, Y = 0 },
	{ Name = "OldRuins", X = 300, Z = -320, R = 58, Y = 14 },
	{ Name = "HollowSpring", X = -330, Z = 20, R = 58, Y = 0 },
	{ Name = "BrambleField", X = 290, Z = 300, R = 62, Y = 0 },
	{ Name = "Overlook", X = -330, Z = -330, R = 70, Y = 36 },
}

-- Small dead-end pockets (riskier, richer loot).
Layout.Pockets = {
	{ Name = "MossyPocket", X = 100, Z = 440, R = 38, Y = 0 },
	{ Name = "NorthPocket", X = 120, Z = -455, R = 36, Y = 0 },
	{ Name = "SunkenPocket", X = -240, Z = 345, R = 38, Y = 0 },
}

-- The Upper Terrace: a long raised bench on the east side.
Layout.UpperTerrace = { Name = "UpperTerrace", From = { 330, -120 }, To = { 350, 100 }, W = 112, Y = 30 }

-- The ground apron where the bridge starts (a stub of the basin toward the north-west).
Layout.BridgeApron = { X = -88, Z = -88, R = 55, Y = 0 }

-- Ground roads: centre lines (control points), width, main route flag.
Layout.Roads = {
	{ Name = "NorthRoad", Pts = { { 0, 0 }, { -18, -90 }, { 10, -170 }, { -20, -250 }, { -10, -330 } }, W = 44, Main = true },
	{ Name = "CircleEast", Pts = { { -10, -330 }, { 60, -345 }, { 135, -325 } }, W = 44, Main = true },
	{ Name = "NorthPocketRoad", Pts = { { 60, -345 }, { 90, -400 }, { 120, -455 } }, W = 36 },
	{ Name = "BrambleNorthRoad", Pts = { { 290, 300 }, { 232, 252 }, { 165, 190 }, { 105, 115 }, { 52, 48 }, { 0, 0 } }, W = 40, Main = true },
	{ Name = "BrambleSouthRoad", Pts = { { 290, 300 }, { 215, 338 }, { 128, 328 }, { 72, 255 }, { 50, 170 }, { 25, 100 }, { 8, 70 } }, W = 36 },
	{ Name = "MossyPocketRoad", Pts = { { 128, 328 }, { 110, 390 }, { 100, 440 } }, W = 36 },
	{ Name = "WestRoad", Pts = { { 0, 0 }, { -82, 5 } }, W = 40 },
	{ Name = "SpringRoad", Pts = { { -240, 5 }, { -285, 15 }, { -330, 20 } }, W = 40 },
	{ Name = "SouthLoop", Pts = { { -330, 20 }, { -335, 110 }, { -290, 210 }, { -195, 255 }, { -105, 200 }, { -52, 125 }, { -8, 70 } }, W = 40 },
	{ Name = "SunkenPocketRoad", Pts = { { -195, 255 }, { -222, 300 }, { -240, 345 } }, W = 36 },
}

-- The Cave Shortcut: a roofed tunnel through the ridge between the basin and Hollow Spring.
Layout.Cave = { Name = "CaveShortcut", Pts = { { -95, 5 }, { -225, 5 } }, W = 34 }

-- The ravine under the bridge: a drop along the north-west diagonal (s = distance from the
-- centre along it, perp = sideways distance from the diagonal).
Layout.Ravine = { From = 170, To = 420, Half = 40 }

-- Slopes. A and B are x, z, height; the ramp surface runs straight between them.
Layout.Ramps = {
	{ Name = "CircleRamp", A = { 135, -325, 0 }, B = { 250, -320, 14 }, W = 40, Main = true },
	{ Name = "RuinsRamp", A = { 300, -262, 14 }, B = { 318, -130, 30 }, W = 40, Main = true },
	{ Name = "BrambleRamp", A = { 342, 100, 30 }, B = { 305, 245, 0 }, W = 40, Main = true },
}

-- The winding ramp from the basin to the Upper Terrace: waypoints (x, z, landing height);
-- a round landing at each inner waypoint, ramps in between.
Layout.WindingRamp = {
	Name = "TerraceRamp",
	W = 36,
	LandingR = 36,
	Pts = { { 75, 10, 0 }, { 165, 40, 9 }, { 225, -25, 19 }, { 292, -65, 30 } },
}

-- The broad stone bridge: starts on the apron (ground) and ends on the Overlook.
Layout.Bridge = { Name = "StoneBridge", S0 = 100, S1 = 398, Y0 = 0, Y1 = 36.2, W = 36 }

-- The spring launch pad (optional shortcut basin -> terrace) and where it throws. The pad keeps
-- ~55 studs of basin floor before the 32-64 tall rock between the basin and the terrace, so the
-- arc (LaunchPads.ApexFor, about 85 studs high) clears it; at x 50 the rock face stood 8 studs
-- from the pad and no arc could clear it.
Layout.LaunchPad = { Pos = { 0, -44 }, Target = { 312, -40 }, Radius = 6 }

-- Main loop in walking order: control points of each leg (the legs reuse the roads above).
-- Legs flagged Ramp are straight sloped lines (3D length).
Layout.MainRoute = {
	{ Road = "NorthRoad" },
	{ Road = "CircleEast" },
	{ Ramp = "CircleRamp" },
	{ Line = { { 250, -320 }, { 300, -320 }, { 300, -262 } }, Y = 14 },
	{ Ramp = "RuinsRamp" },
	{ Line = { { 318, -130 }, { 335, -20 }, { 342, 100 } }, Y = 30 },
	{ Ramp = "BrambleRamp" },
	{ Line = { { 305, 245 }, { 290, 300 } }, Y = 0 },
	{ Road = "BrambleNorthRoad" },
}

------------------------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------------------------

local function smooth(ctrl: { { number } }, step: number): { { number } }
	local out = {}
	for i = 1, #ctrl - 1 do
		local p0 = ctrl[math.max(1, i - 1)]
		local p1, p2 = ctrl[i], ctrl[i + 1]
		local p3 = ctrl[math.min(#ctrl, i + 2)]
		local dx, dz = p2[1] - p1[1], p2[2] - p1[2]
		local n = math.max(1, math.floor(math.sqrt(dx * dx + dz * dz) / step + 0.5))
		for k = 0, n - 1 do
			local t = k / n
			local t2, t3 = t * t, t * t * t
			local function c(a: number, b: number, c2: number, d: number): number
				return 0.5 * (2 * b + (-a + c2) * t + (2 * a - 5 * b + 4 * c2 - d) * t2 + (-a + 3 * b - 3 * c2 + d) * t3)
			end
			table.insert(out, { c(p0[1], p1[1], p2[1], p3[1]), c(p0[2], p1[2], p2[2], p3[2]) })
		end
	end
	table.insert(out, { ctrl[#ctrl][1], ctrl[#ctrl][2] })
	return out
end
Layout.Smooth = smooth

local function polyLength(pts: { { number } }): number
	local len = 0
	for i = 1, #pts - 1 do
		local dx, dz = pts[i + 1][1] - pts[i][1], pts[i + 1][2] - pts[i][2]
		len += math.sqrt(dx * dx + dz * dz)
	end
	return len
end

local function cellCentre(i: number): number
	return -HALF + (i - 0.5) * CELL
end
Layout.CellCentre = cellCentre

local function cellIndex(v: number): number
	return math.clamp(math.floor((v + HALF) / CELL) + 1, 1, N)
end
Layout.CellIndex = cellIndex

local function segDist(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local t = len2 > 0 and math.clamp(((px - ax) * dx + (pz - az) * dz) / len2, 0, 1) or 0
	local qx, qz = ax + dx * t - px, az + dz * t - pz
	return math.sqrt(qx * qx + qz * qz)
end

-- Deterministic value noise in [-1, 1] for cell (i, j), smoothed over 3 cell blocks.
local function noise(i: number, j: number): number
	local function h(a: number, b: number): number
		local v = math.sin(a * 127.1 + b * 311.7) * 43758.5453
		return (v - math.floor(v)) * 2 - 1
	end
	local bi, bj = (i - 1) / 3, (j - 1) / 3
	local i0, j0 = math.floor(bi), math.floor(bj)
	local fi, fj = bi - i0, bj - j0
	local a = h(i0, j0) * (1 - fi) + h(i0 + 1, j0) * fi
	local b = h(i0, j0 + 1) * (1 - fi) + h(i0 + 1, j0 + 1) * fi
	return a * (1 - fj) + b * fj
end

------------------------------------------------------------------------------------------
-- DERIVED SHAPES
------------------------------------------------------------------------------------------

-- Ramp geometry: unit direction, length, yaw (the part's rotation about Y).
local function rampGeo(r: any)
	local ax, az, ay = r.A[1], r.A[2], r.A[3]
	local bx, bz, by = r.B[1], r.B[2], r.B[3]
	local dx, dz = bx - ax, bz - az
	local len = math.sqrt(dx * dx + dz * dz)
	return {
		Name = r.Name,
		Ax = ax, Az = az, Ay = ay, Bx = bx, Bz = bz, By = by,
		Dx = dx / len, Dz = dz / len, Len = len, W = r.W, Main = r.Main,
		Rise = by - ay,
		Slope = math.deg(math.atan2(by - ay, len)),
	}
end

local function windingRamps()
	local wr = Layout.WindingRamp
	local pts = wr.Pts
	local ramps, landings = {}, {}
	local lr = wr.LandingR
	for k = 1, #pts - 1 do
		local a, b = pts[k], pts[k + 1]
		local dx, dz = b[1] - a[1], b[2] - a[2]
		local len = math.sqrt(dx * dx + dz * dz)
		local ux, uz = dx / len, dz / len
		local ax, az, ay = a[1], a[2], a[3]
		if k > 1 then
			ax, az = a[1] + ux * (lr * 0.55), a[2] + uz * (lr * 0.55)
		end
		local bx, bz, by = b[1], b[2], b[3]
		if k < #pts - 1 then
			bx, bz = b[1] - ux * (lr * 0.55), b[2] - uz * (lr * 0.55)
		end
		table.insert(ramps, { Name = wr.Name .. k, A = { ax, az, ay }, B = { bx, bz, by }, W = wr.W })
		if k < #pts - 1 then
			table.insert(landings, { Name = wr.Name .. "Landing" .. k, X = b[1], Z = b[2], R = lr, Y = b[3] })
		end
	end
	return ramps, landings
end

-- Every ramp of the map in painting order.
local function allRamps()
	local list = {}
	for _, r in ipairs(Layout.Ramps) do
		table.insert(list, rampGeo(r))
	end
	local wr, landings = windingRamps()
	for _, r in ipairs(wr) do
		table.insert(list, rampGeo(r))
	end
	return list, landings
end

-- Ravine and bridge frame: along = unit vector toward the north-west.
local ALONG = { -0.70710678, -0.70710678 }
local SIDE = { 0.70710678, -0.70710678 }
Layout.Along = ALONG
Layout.Side = SIDE

local function ravineCoords(x: number, z: number): (number, number)
	return x * ALONG[1] + z * ALONG[2], x * SIDE[1] + z * SIDE[2]
end
Layout.RavineCoords = ravineCoords

------------------------------------------------------------------------------------------
-- THE PLAN
------------------------------------------------------------------------------------------

function Layout.Plan()
	local kind, T, rampOf = {}, {}, {}
	for i = 1, N do
		kind[i], T[i], rampOf[i] = {}, {}, {}
		for j = 1, N do
			kind[i][j] = "rock"
			T[i][j] = 0
		end
	end

	local function forCells(minX: number, maxX: number, minZ: number, maxZ: number, fn: (number, number, number, number) -> ())
		for i = cellIndex(minX), cellIndex(maxX) do
			for j = cellIndex(minZ), cellIndex(maxZ) do
				fn(i, j, cellCentre(i), cellCentre(j))
			end
		end
	end

	-- level paint: only where `can(i, j)` allows
	local function paintDisc(c: any, y: number, can: ((number, number) -> boolean)?)
		forCells(c.X - c.R - CELL, c.X + c.R + CELL, c.Z - c.R - CELL, c.Z + c.R + CELL, function(i, j, x, z)
			local dx, dz = x - c.X, z - c.Z
			if dx * dx + dz * dz <= c.R * c.R and (not can or can(i, j)) then
				kind[i][j], T[i][j] = "walk", y
			end
		end)
	end
	local function paintPoly(pts: { { number } }, w: number, y: number, k: string, can: ((number, number) -> boolean)?)
		local half = w / 2
		for s = 1, #pts - 1 do
			local a, b = pts[s], pts[s + 1]
			forCells(math.min(a[1], b[1]) - half - CELL, math.max(a[1], b[1]) + half + CELL, math.min(a[2], b[2]) - half - CELL, math.max(a[2], b[2]) + half + CELL, function(i, j, x, z)
				if segDist(x, z, a[1], a[2], b[1], b[2]) <= half and (not can or can(i, j)) then
					kind[i][j], T[i][j] = k, y
				end
			end)
		end
	end

	local groundOnly = function(i: number, j: number): boolean
		return not (kind[i][j] == "walk" and T[i][j] > 1)
	end

	-- 1. clearings and pockets (raised ones first, so roads never cut into them)
	for _, c in ipairs(Layout.Clearings) do
		paintDisc(c, c.Y, nil)
	end
	for _, c in ipairs(Layout.Pockets) do
		paintDisc(c, c.Y, groundOnly)
	end
	paintDisc(Layout.BridgeApron, 0, groundOnly)
	-- 2. roads (ground)
	for _, road in ipairs(Layout.Roads) do
		paintPoly(smooth(road.Pts, 10), road.W, 0, "walk", groundOnly)
	end
	-- 3. the Upper Terrace
	do
		local ut = Layout.UpperTerrace
		paintPoly({ ut.From, ut.To }, ut.W, ut.Y, "walk", nil)
		-- rounded ends
		paintDisc({ X = ut.From[1], Z = ut.From[2], R = ut.W / 2 }, ut.Y, nil)
		paintDisc({ X = ut.To[1], Z = ut.To[2], R = ut.W / 2 }, ut.Y, nil)
	end
	-- 4. the cave (over the ridge)
	paintPoly(smooth(Layout.Cave.Pts, 10), Layout.Cave.W, 0, "cave", nil)
	-- the ground at the cave mouths (so the roads meet it)
	-- 5. landings, then the ravine, then the ramps
	local ramps, landings = allRamps()
	for _, l in ipairs(landings) do
		paintDisc(l, l.Y, nil)
	end
	do
		local rv = Layout.Ravine
		forCells(-HALF, 0, -HALF, 0, function(i, j, x, z)
			local s, p = ravineCoords(x, z)
			if s >= rv.From and s <= rv.To and math.abs(p) <= rv.Half then
				local k = kind[i][j]
				if k == "rock" or (k == "walk" and T[i][j] <= 1) then
					kind[i][j], T[i][j] = "void", FLOOR_Y
				end
			end
		end)
	end
	for idx, r in ipairs(ramps) do
		local half = r.W / 2
		forCells(math.min(r.Ax, r.Bx) - half - CELL, math.max(r.Ax, r.Bx) + half + CELL, math.min(r.Az, r.Bz) - half - CELL, math.max(r.Az, r.Bz) + half + CELL, function(i, j, x, z)
			local ox, oz = x - r.Ax, z - r.Az
			local s = ox * r.Dx + oz * r.Dz
			local p = -ox * r.Dz + oz * r.Dx
			if s >= 0 and s <= r.Len and math.abs(p) <= half then
				kind[i][j] = "ramp"
				T[i][j] = r.Ay + r.Rise * s / r.Len
				rampOf[i][j] = idx
			end
		end)
	end

	-- 6. rock heights: distance to the nearest open cell (chamfer transform) and its level
	local INF = 1e9
	local dist, near = {}, {}
	for i = 1, N do
		dist[i], near[i] = {}, {}
		for j = 1, N do
			local k = kind[i][j]
			if k == "rock" then
				dist[i][j], near[i][j] = INF, 0
			else
				dist[i][j], near[i][j] = 0, (k == "void") and 0 or T[i][j]
			end
		end
	end
	local function relax(i: number, j: number, ni: number, nj: number, cost: number)
		if ni < 1 or nj < 1 or ni > N or nj > N then
			return
		end
		local d = dist[ni][nj] + cost
		if d < dist[i][j] then
			dist[i][j], near[i][j] = d, near[ni][nj]
		end
	end
	for i = 1, N do
		for j = 1, N do
			relax(i, j, i - 1, j, CELL)
			relax(i, j, i, j - 1, CELL)
			relax(i, j, i - 1, j - 1, CELL * 1.414)
			relax(i, j, i + 1, j - 1, CELL * 1.414)
		end
	end
	for i = N, 1, -1 do
		for j = N, 1, -1 do
			relax(i, j, i + 1, j, CELL)
			relax(i, j, i, j + 1, CELL)
			relax(i, j, i + 1, j + 1, CELL * 1.414)
			relax(i, j, i - 1, j + 1, CELL * 1.414)
		end
	end
	local H, roof = {}, {}
	local QUANT = 16
	for i = 1, N do
		H[i], roof[i] = {}, {}
		for j = 1, N do
			local x, z = cellCentre(i), cellCentre(j)
			-- three steps of height out from the open floor (a bank, a wall, the mass behind),
			-- a few raised blocks, and a steady climb to 180 at the map edge: few distinct
			-- heights, so the rock merges into big blocks
			local d = dist[i][j]
			local h = math.floor(near[i][j] / 8 + 0.5) * 8 + (d <= 25 and 30 or (d <= 60 and 46 or 62))
			if d > 25 and noise(math.floor(i / 6) * 6, math.floor(j / 6) * 6) > 0.35 then
				h += 16 -- a few raised shelves further back (whole 60 stud blocks, never next to the lanes)
			end
			local edge = math.min(HALF - math.abs(x), HALF - math.abs(z))
			if edge < 110 then
				h = math.max(h, 70 + (110 - edge))
			end
			H[i][j] = math.min(184, math.max(QUANT, math.floor(h / QUANT + 0.5) * QUANT))
		end
	end
	-- cave ceilings: the height of the ridge around them
	for i = 1, N do
		for j = 1, N do
			if kind[i][j] == "cave" then
				local best = 0
				for di = -1, 1 do
					for dj = -1, 1 do
						local ni, nj = i + di, j + dj
						if ni >= 1 and nj >= 1 and ni <= N and nj <= N and kind[ni][nj] == "rock" then
							best = math.max(best, H[ni][nj])
						end
					end
				end
				roof[i][j] = best > 0 and best or 48
			end
		end
	end

	local plan = {
		N = N, CELL = CELL, HALF = HALF,
		Kind = kind, T = T, H = H, Roof = roof, Dist = dist, RampOf = rampOf, Ramps = ramps, Landings = landings,
	}

	-- exact floor height at (x, z) (nil over rock / void)
	function plan.FloorAt(x: number, z: number): number?
		if math.abs(x) >= HALF or math.abs(z) >= HALF then
			return nil
		end
		local i, j = cellIndex(x), cellIndex(z)
		local k = kind[i][j]
		if k == "rock" or k == "void" then
			return nil
		end
		if k == "ramp" then
			local r = ramps[rampOf[i][j]]
			local s = math.clamp((x - r.Ax) * r.Dx + (z - r.Az) * r.Dz, 0, r.Len)
			return r.Ay + r.Rise * s / r.Len
		end
		return T[i][j]
	end

	-- "interior" walkable: the cell and its 8 neighbours are flat floor (portal / loot spots)
	function plan.Interior(x: number, z: number): boolean
		local i, j = cellIndex(x), cellIndex(z)
		local t = T[i][j]
		if kind[i][j] ~= "walk" then
			return false
		end
		for di = -1, 1 do
			for dj = -1, 1 do
				local ni, nj = i + di, j + dj
				if ni < 1 or nj < 1 or ni > N or nj > N or kind[ni][nj] ~= "walk" or math.abs(T[ni][nj] - t) > 0.5 then
					return false
				end
			end
		end
		return true
	end

	return plan
end

------------------------------------------------------------------------------------------
-- ROUTES (paths, main loop, metrics)
------------------------------------------------------------------------------------------

local function roadByName(name: string): any
	for _, r in ipairs(Layout.Roads) do
		if r.Name == name then
			return r
		end
	end
	return nil
end

-- Path segments for decoration / ground detail: { A = {x, z}, B = {x, z}, W = halfWidth,
-- Main, Flat }. Flat segments are drawn as a dirt strip; ramps / cave only keep decor off.
function Layout.Paths(plan: any): { any }
	local out = {}
	local function addPoly(pts: { { number } }, halfW: number, main: boolean?, flat: boolean)
		for i = 1, #pts - 1 do
			table.insert(out, { A = pts[i], B = pts[i + 1], W = halfW, Main = main, Flat = flat })
		end
	end
	for _, road in ipairs(Layout.Roads) do
		addPoly(smooth(road.Pts, 24), 13, road.Main, true)
	end
	addPoly(smooth(Layout.Cave.Pts, 24), 13, false, false)
	for _, r in ipairs(plan.Ramps) do
		addPoly({ { r.Ax, r.Az }, { r.Bx, r.Bz } }, 13, r.Main, false)
	end
	for _, l in ipairs(plan.Landings) do
		addPoly({ { l.X - 2, l.Z }, { l.X + 2, l.Z } }, 20, false, false)
	end
	-- terrace and ruins centre lines of the main loop
	addPoly({ { 250, -320 }, { 300, -320 }, { 300, -262 } }, 13, true, false)
	addPoly({ { 318, -130 }, { 335, -20 }, { 342, 100 } }, 13, true, false)
	addPoly({ { 305, 245 }, { 290, 300 } }, 13, true, false)
	-- the bridge
	local br = Layout.Bridge
	addPoly({
		{ ALONG[1] * br.S0, ALONG[2] * br.S0 },
		{ ALONG[1] * br.S1, ALONG[2] * br.S1 },
	}, 13, false, false)
	return out
end

-- The main loop as a 3D polyline { {x, z, y} } and its length (studs).
function Layout.MainLoop(plan: any): ({ { number } }, number)
	local pts = {}
	local rampsByName = {}
	for _, r in ipairs(plan.Ramps) do
		rampsByName[r.Name] = r
	end
	local function add(x: number, z: number, y: number)
		local last = pts[#pts]
		if not last or math.abs(last[1] - x) + math.abs(last[2] - z) > 0.01 then
			table.insert(pts, { x, z, y })
		end
	end
	for _, leg in ipairs(Layout.MainRoute) do
		if leg.Road then
			local road = roadByName(leg.Road)
			local sm = smooth(road.Pts, 12)
			local first = pts[#pts]
			-- walk the road in the direction that starts nearest to where we are
			local reverse = false
			if first then
				local a, b = sm[1], sm[#sm]
				local da = (a[1] - first[1]) ^ 2 + (a[2] - first[2]) ^ 2
				local db = (b[1] - first[1]) ^ 2 + (b[2] - first[2]) ^ 2
				reverse = db < da
			end
			if reverse then
				for k = #sm, 1, -1 do
					add(sm[k][1], sm[k][2], 0)
				end
			else
				for k = 1, #sm do
					add(sm[k][1], sm[k][2], 0)
				end
			end
		elseif leg.Ramp then
			local r = rampsByName[leg.Ramp]
			add(r.Ax, r.Az, r.Ay)
			add(r.Bx, r.Bz, r.By)
		else
			local sm = smooth(leg.Line, 12)
			for _, p in ipairs(sm) do
				add(p[1], p[2], leg.Y)
			end
		end
	end
	local len = 0
	for k = 1, #pts - 1 do
		local a, b = pts[k], pts[k + 1]
		len += math.sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2 + (b[3] - a[3]) ^ 2)
	end
	return pts, len
end

Layout.PolyLength = polyLength

return Layout
