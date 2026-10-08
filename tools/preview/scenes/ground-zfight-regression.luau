-- ground-zfight-regression: builds every arena with the real MapBuilder and looks for flat
-- ground pieces (floor slabs, tone patches, path slabs, inlays, pools) whose top faces
-- overlap within MIN_GAP studs of height (same-colour SmoothPlastic pairs excepted). Two such tops flicker ("z-fight") from the high
-- run camera, worst on phones. Prints "FAIL: ..." per arena with the worst pairs.
-- run: lune run tools/preview/runtime/main.luau -- --scene ground-zfight-regression --device pc
--      --out <file>.json --set headless=on
local C = lib("common")
local s = C.bootServer()
local MapBuilder = s.MapBuilder
local MIN_GAP = 0.0195 -- 0.02 studs apart is the closest designed spacing

type Flat = { Plain: string?, Name: string, Top: number, X: number, Z: number, Disc: boolean, R: number, HX: number, HZ: number, AX: number, AZ: number }

local function flatOf(p: BasePart): Flat?
	if p:IsA("MeshPart") or p.Transparency >= 0.99 then
		return nil
	end
	local cf, sz = p.CFrame, p.Size
	-- identical flat colour on SmoothPlastic cannot flicker: such pairs may share a height
	local plain = if p.Material == Enum.Material.SmoothPlastic then tostring(p.Color) else nil
	local isPart = p:IsA("Part")
	if isPart and (p :: Part).Shape == Enum.PartType.Cylinder then
		-- upright disc: the cylinder axis (local X) points up
		if math.abs(cf.RightVector.Y) < 0.999 or sz.X > 1.2 or sz.Y < sz.X * 3 then
			return nil
		end
		return { Plain = plain, Name = p.Name, Top = cf.Position.Y + sz.X / 2, X = cf.Position.X, Z = cf.Position.Z, Disc = true, R = math.min(sz.Y, sz.Z) / 2, HX = 0, HZ = 0, AX = 1, AZ = 0 }
	elseif isPart and (p :: Part).Shape ~= Enum.PartType.Block then
		return nil
	end
	if math.abs(cf.UpVector.Y) < 0.999 or sz.Y > 1.2 or math.min(sz.X, sz.Z) < sz.Y * 3 then
		return nil
	end
	local rv = cf.RightVector
	local l = math.sqrt(rv.X * rv.X + rv.Z * rv.Z)
	return { Plain = plain, Name = p.Name, Top = cf.Position.Y + sz.Y / 2, X = cf.Position.X, Z = cf.Position.Z, Disc = false, R = 0, HX = sz.X / 2, HZ = sz.Z / 2, AX = rv.X / l, AZ = rv.Z / l }
end

-- footprint overlap with a small inset (touching edges do not count)
local INSET = 0.1
local function boxProject(b: Flat, ax: number, az: number): number
	-- half extent of box b on axis (ax, az)
	local ux, uz = b.AX, b.AZ -- local X
	local vx, vz = -b.AZ, b.AX -- local Z
	return b.HX * math.abs(ux * ax + uz * az) + b.HZ * math.abs(vx * ax + vz * az)
end
local function overlaps(a: Flat, b: Flat): boolean
	local dx, dz = b.X - a.X, b.Z - a.Z
	if a.Disc and b.Disc then
		return dx * dx + dz * dz < (a.R + b.R - INSET) ^ 2
	end
	if a.Disc or b.Disc then
		local d, box = if a.Disc then a else b, if a.Disc then b else a
		local px, pz = d.X - box.X, d.Z - box.Z
		local lx = px * box.AX + pz * box.AZ
		local lz = px * -box.AZ + pz * box.AX
		local cx, cz = math.clamp(lx, -box.HX, box.HX), math.clamp(lz, -box.HZ, box.HZ)
		return (lx - cx) ^ 2 + (lz - cz) ^ 2 < (d.R - INSET) ^ 2 and d.R > INSET
	end
	for _, axis in ipairs({ { a.AX, a.AZ }, { -a.AZ, a.AX }, { b.AX, b.AZ }, { -b.AZ, b.AX } }) do
		local ax, az = axis[1], axis[2]
		if math.abs(dx * ax + dz * az) >= boxProject(a, ax, az) + boxProject(b, ax, az) - INSET then
			return false
		end
	end
	return true
end

local fails = 0
for _, build in ipairs({ "Forest", "Ruins", "Swamp", "Snow", "Desert", "Lava", "Forest#1", "Swamp#2", "Desert#3" }) do
	local name, variant = string.match(build, "^(%a+)#?(%d*)$")
	local arena = MapBuilder.BuildArena(name, tonumber(variant))
	name = build
	local flats: { Flat } = {}
	for _, d in ipairs(arena.Model:GetDescendants()) do
		if d:IsA("BasePart") then
			local f = flatOf(d)
			if f then
				table.insert(flats, f)
			end
		end
	end
	if preview.args.list == "on" then
		local inv: { [string]: { [string]: number } } = {}
		for _, f in ipairs(flats) do
			inv[f.Name] = inv[f.Name] or {}
			local k = string.format("%.3f", f.Top)
			inv[f.Name][k] = (inv[f.Name][k] or 0) + 1
		end
		for n, tops in pairs(inv) do
			local parts = {}
			for k, c in pairs(tops) do
				table.insert(parts, k .. "x" .. c)
			end
			table.sort(parts)
			preview.log(string.format("  LIST %s %s: %s", name, n, table.concat(parts, " ")))
		end
	end
	table.sort(flats, function(a, b)
		return a.Top < b.Top
	end)
	local bad = 0
	local kinds: { [string]: number } = {}
	for i = 1, #flats do
		local a = flats[i]
		local j = i + 1
		while j <= #flats and flats[j].Top - a.Top < MIN_GAP do
			local b = flats[j]
			if overlaps(a, b) and not (a.Plain and a.Plain == b.Plain) then
				bad += 1
				local key = string.format("%s %.3f vs %s %.3f", a.Name, a.Top, b.Name, b.Top)
				kinds[key] = (kinds[key] or 0) + 1
			end
			j += 1
		end
	end
	local keys = {}
	for k in pairs(kinds) do
		table.insert(keys, k)
	end
	table.sort(keys)
	for _, k in ipairs(keys) do
		preview.log(string.format("  %s: %s (x%d)", name, k, kinds[k]))
	end
	if bad > 0 then
		fails += 1
		preview.log(string.format("FAIL: %s: %d overlapping flat pairs closer than %.2f studs in height (%d flat parts)", name, bad, MIN_GAP, #flats))
	else
		preview.log(string.format("ok   %s: no coplanar ground overlaps (%d flat parts)", name, #flats))
	end
	MapBuilder.DestroyArena()
end
preview.log(if fails == 0 then "PASS ground-zfight-regression" else string.format("FAIL: ground-zfight-regression (%d arenas)", fails))
