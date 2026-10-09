--[[
	scenes/lib/mapray.luau - workspace:Raycast against the current arena's parts for scenes
	that need the real height grid (HeightGrid.Build casts its rays; the mock's rays hit
	nothing). Oriented boxes in 32-stud spatial buckets, rebuilt when the arena changes.
	The same code as cliffwood-run-sim's own copy.
	  local MapRay = lib("mapray")
	  MapRay.install(function() return MapBuilder.GetArena() end)   -- ... MapRay.uninstall()
	MapRay.count() = rays answered so far.
]]

local M = {}

local BUCKET = 32
local index: any = nil
local indexArena: any = nil
local includeCache = setmetatable({}, { __mode = "k" })
local stamp = 0
local rayCount = 0

local function bucketKey(bx: number, bz: number): number
	return bx * 65536 + bz
end

local function buildIndex(arena)
	local buckets = {}
	for _, p in ipairs(arena.Model:GetDescendants()) do
		if p:IsA("BasePart") and p.CanQuery ~= false then
			local cf, s = p.CFrame, p.Size
			local ax, ay, az = cf.RightVector, cf.UpVector, -cf.LookVector
			local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
			local pos = cf.Position
			local ex = math.abs(ax.X) * hx + math.abs(ay.X) * hy + math.abs(az.X) * hz
			local ez = math.abs(ax.Z) * hx + math.abs(ay.Z) * hy + math.abs(az.Z) * hz
			local e = { Part = p, Pos = pos, Ax = ax, Ay = ay, Az = az, H = { hx, hy, hz }, Collide = p.CanCollide, Seen = 0 }
			for bx = math.floor((pos.X - ex) / BUCKET), math.floor((pos.X + ex) / BUCKET) do
				for bz = math.floor((pos.Z - ez) / BUCKET), math.floor((pos.Z + ez) / BUCKET) do
					local k = bucketKey(bx, bz)
					local list = buckets[k]
					if not list then
						list = {}
						buckets[k] = list
					end
					table.insert(list, e)
				end
			end
		end
	end
	return { Buckets = buckets }
end

local function rayBox(e, origin: Vector3, dir: Vector3): (number?, Vector3?)
	local rel = origin - e.Pos
	local axes = { e.Ax, e.Ay, e.Az }
	local tmin, tmax = -math.huge, math.huge
	local nAxis, nSign = 1, 1
	for i = 1, 3 do
		local a = axes[i]
		local o = rel:Dot(a)
		local d = dir:Dot(a)
		local h = e.H[i]
		if math.abs(d) < 1e-9 then
			if o < -h or o > h then
				return nil
			end
		else
			local t1, t2 = (-h - o) / d, (h - o) / d
			local s = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				s = 1
			end
			if t1 > tmin then
				tmin, nAxis, nSign = t1, i, s
			end
			if t2 < tmax then
				tmax = t2
			end
			if tmin > tmax then
				return nil
			end
		end
	end
	if tmin < 0 or tmin > 1 then
		return nil
	end
	return tmin, axes[nAxis] * nSign
end

local function allowedSet(list)
	local cached = includeCache[list]
	if cached and cached.N == #list then
		return cached.Set
	end
	local set = {}
	for _, inst in ipairs(list) do
		set[inst] = true
		for _, d in ipairs(inst:GetDescendants()) do
			set[d] = true
		end
	end
	includeCache[list] = { N = #list, Set = set }
	return set
end

function M.install(getArena: () -> any)
	preview.setRaycast(function(origin: Vector3, direction: Vector3, params)
		rayCount += 1
		local arena = getArena()
		if not arena or not arena.Model or not arena.Model.Parent then
			return nil
		end
		if arena ~= indexArena then
			index = buildIndex(arena)
			indexArena = arena
		end
		local include, exclude = nil, nil
		local respect = false
		if params then
			respect = params.RespectCanCollide
			local list = params.FilterDescendantsInstances
			if params.FilterType == Enum.RaycastFilterType.Include then
				include = allowedSet(list)
			elseif #list > 0 then
				exclude = allowedSet(list)
			end
		end
		stamp += 1
		local e = origin + direction
		local bx0, bx1 = math.floor(math.min(origin.X, e.X) / BUCKET), math.floor(math.max(origin.X, e.X) / BUCKET)
		local bz0, bz1 = math.floor(math.min(origin.Z, e.Z) / BUCKET), math.floor(math.max(origin.Z, e.Z) / BUCKET)
		local best, bestN, bestPart = math.huge, nil, nil
		for bx = bx0, bx1 do
			for bz = bz0, bz1 do
				local list = index.Buckets[bucketKey(bx, bz)]
				if list then
					for _, ent in ipairs(list) do
						if ent.Seen ~= stamp then
							ent.Seen = stamp
							local p = ent.Part
							if (not include or include[p]) and (not exclude or not exclude[p]) and (not respect or ent.Collide) then
								local t, n = rayBox(ent, origin, direction)
								if t and t < best then
									best, bestN, bestPart = t, n, p
								end
							end
						end
					end
				end
			end
		end
		if not bestPart then
			return nil
		end
		local hit = origin + direction * best
		return { Instance = bestPart, Position = hit, Normal = bestN, Distance = direction.Magnitude * best, Material = bestPart.Material }
	end)
end

function M.uninstall()
	preview.setRaycast(nil)
	index = nil
	indexArena = nil
end

function M.count(): number
	return rayCount
end

return M
