-- arena-dressing-regression: builds every arena with the real MapBuilder and checks the
-- environment dressing rules (scenery clusters in one "ArenaDressing" folder):
--   * every dressing part is decoration: CanCollide / CanQuery / CanTouch off, anchored;
--   * nothing in the dressing stands in a collider, on a hazard pool or on a path core;
--   * the central combat area stays light (few pieces inside the spawn clearing);
--   * a rebuild (same arena, same variant) gives the same pieces in the same places and
--     never leaves a second folder or duplicates behind;
--   * MapBuilder.ClearDecor also clears dressing around a chest spot.
-- Prints per arena the instance counts (arena model parts / mesh parts / models, dressing
-- pieces) and "FAIL: ..." on a broken rule (tools/run_regressions.py).
-- run: lune run tools/preview/runtime/main.luau -- --scene arena-dressing-regression --device pc
--      --out <file>.json --set headless=on
local C = lib("common")
local s = C.bootServer()
local MapBuilder = s.MapBuilder
local Config = s.Config
local fails = 0
local function check(ok: boolean, label: string)
	if ok then
		preview.log("ok   " .. label)
	else
		fails += 1
		preview.log("FAIL: " .. label)
	end
end

local function counts(root: Instance): (number, number, number, number)
	local parts, meshes, models, all = 0, 0, 0, 0
	for _, d in ipairs(root:GetDescendants()) do
		all += 1
		if d:IsA("MeshPart") then
			meshes += 1
		elseif d:IsA("BasePart") then
			parts += 1
		elseif d:IsA("Model") then
			models += 1
		end
	end
	return parts, meshes, models, all
end

local function snapshot(folder: Instance?): { string }
	local out = {}
	if not folder then
		return out
	end
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d.Position
			table.insert(out, string.format("%s@%.2f,%.2f,%.2f", d.Name, p.X, p.Y, p.Z))
		end
	end
	table.sort(out)
	return out
end

local origin = Config.ArenaOrigin
local clear = Config.Arenas.ClearRadius or 40
for _, name in ipairs({ "Forest", "Ruins", "Swamp", "Snow", "Desert", "Lava" }) do
	local arena = MapBuilder.BuildArena(name)
	local model = arena.Model
	local p, mp, mo, all = counts(model)
	local dress = model:FindFirstChild("ArenaDressing")
	local dp, dmp, dmo, dall = 0, 0, 0, 0
	if dress then
		dp, dmp, dmo, dall = counts(dress)
	end
	preview.log(string.format("COUNT %s arena: parts %d, meshParts %d, models %d, instances %d | dressing: parts %d, meshParts %d, models %d, instances %d",
		name, p, mp, mo, all, dp, dmp, dmo, dall))
	if not dress then
		continue
	end
	local folders = 0
	for _, ch in ipairs(model:GetChildren()) do
		if ch.Name == "ArenaDressing" then
			folders += 1
		end
	end
	check(folders == 1, name .. ": one ArenaDressing folder")
	local bad, inCollider, inClear, onPath = 0, 0, 0, 0
	local obstacles = model:FindFirstChild("Obstacles")
	for _, d in ipairs(dress:GetDescendants()) do
		if d:IsA("BasePart") then
			if d.CanCollide or d.CanQuery or d.CanTouch or not d.Anchored then
				bad += 1
			end
		end
	end
	for _, m in ipairs(dress:GetChildren()) do
		local at = m:IsA("Model") and m:GetPivot().Position or (m :: BasePart).Position
		local x, z = at.X - origin.X, at.Z - origin.Z
		if math.sqrt(x * x + z * z) < clear then
			inClear += 1
		end
		-- path core: deeper than the soft margin (1.4 studs) inside a path's outer edge
		for _, seg in ipairs(arena.Paths) do
			local ax, az, bx, bz = seg.A.X, seg.A.Z, seg.B.X, seg.B.Z
			local dx, dz = bx - ax, bz - az
			local len2 = dx * dx + dz * dz
			local t = if len2 > 0 then math.clamp(((x - ax) * dx + (z - az) * dz) / len2, 0, 1) else 0
			local px, pz = ax + dx * t - x, az + dz * t - z
			if math.sqrt(px * px + pz * pz) - seg.W < -1.4 then
				onPath += 1
				break
			end
		end
		if obstacles then
			for _, ob in ipairs(obstacles:GetChildren()) do
				if ob:IsA("BasePart") then
					local op, os = ob.Position, ob.Size
					if ob:IsA("Part") and ob.Shape == Enum.PartType.Cylinder then
						local dx, dz = op.X - at.X, op.Z - at.Z
						if dx * dx + dz * dz < (os.Y / 2) ^ 2 then
							inCollider += 1
						end
					elseif math.abs(op.X - at.X) < os.X / 2 and math.abs(op.Z - at.Z) < os.Z / 2 then
						inCollider += 1
					end
				end
			end
		end
	end
	local pieces = #dress:GetChildren()
	preview.log(string.format("DRESS %s: %d pieces, %d inside the clearing, %d in colliders", name, pieces, inClear, inCollider))
	check(bad == 0, name .. ": dressing never collides / is queried / touched (" .. bad .. " bad parts)")
	check(inCollider == 0, name .. ": no dressing inside a collider (" .. inCollider .. ")")
	check(inClear <= math.max(4, pieces * 0.08), name .. ": the centre stays light (" .. inClear .. " of " .. pieces .. " inside the clearing)")
	check(onPath == 0, name .. ": no dressing on a path core (" .. onPath .. ")")
	-- rebuild: same pieces, same places, no duplicates
	local before = snapshot(dress)
	local again = MapBuilder.BuildArena(name)
	local after = snapshot(again.Model:FindFirstChild("ArenaDressing"))
	local same = #before == #after
	if same then
		for i = 1, #before do
			if before[i] ~= after[i] then
				same = false
				break
			end
		end
	end
	check(same, name .. ": a rebuild gives the same dressing (" .. #before .. " vs " .. #after .. " parts)")
	local maps = 0
	for _, ch in ipairs(again.Root:GetChildren()) do
		if string.sub(ch.Name, 1, 6) == "Arena_" then
			maps += 1
		end
	end
	check(maps == 1, name .. ": one arena model after a rebuild (" .. maps .. ")")
	-- ClearDecor clears dressing too
	local d2 = again.Model:FindFirstChild("ArenaDressing")
	local first = d2 and d2:GetChildren()[1]
	if first then
		local at = first:IsA("Model") and first:GetPivot().Position or (first :: BasePart).Position
		MapBuilder.ClearDecor(again, at, 1.5)
		check(first.Parent == nil, name .. ": ClearDecor removes dressing at a loot spot")
	end
end
preview.log(fails == 0 and "PASS arena dressing" or ("FAIL: " .. fails .. " arena dressing checks failed"))
