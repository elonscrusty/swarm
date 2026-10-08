--[[
	Occlusion.lua
	Tall scenery never hides the action. Parts or Models tagged "SwarmOccluder"
	(CollectionService; the map tags tree canopies, tall ruins, ...) fade to a see-through
	LocalTransparencyModifier while they stand between the camera and the area around the
	followed player, and fade back once they no longer do.

	"The area around the player" = the player (feet, chest, above the head where the health
	bar is) plus two small ground rings around them (Config.Graphics.Occlusion InnerRadius,
	OuterRadius) where enemies, attacks and pickups close to the player are. An item covers
	that area when a line from the camera to one of those points passes through its box.

	Cheap by design:
	  * tagged items are bucketed once in a 32-stud grid (scenery does not move);
	  * about 10 checks per second, only for items in the cells between the camera and
	    the player; each check is pure maths (segment vs box), no raycasts;
	  * transparency is written only while an item is fading in or out.
	Faded items use a larger box to come back than to fade (no flicker at the edge).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local GroundHeight = require(script.Parent.GroundHeight) -- ground under effects on maps with height

local Occlusion = {}

local SETTINGS = (Config.Graphics :: any).Occlusion or {}
local TAG: string = SETTINGS.Tag or "SwarmOccluder"
local FADE: number = SETTINGS.Fade or 0.65
local CHECK_EVERY = 1 / math.max(1, SETTINGS.CheckHz or 10)
local FADE_RATE = 1 / math.max(0.05, SETTINGS.FadeSeconds or 0.25)
local INNER: number = SETTINGS.InnerRadius or 6
local OUTER: number = SETTINGS.OuterRadius or 11
local CELL = 32
local PAD_FADE = 0.4 -- box padding when deciding to fade
local PAD_KEEP = 1.6 -- larger padding to stay faded

local player = Players.LocalPlayer

type Item = {
	Inst: Instance,
	Parts: { BasePart },
	Min: Vector3,
	Max: Vector3,
	Keys: { number },
	Alpha: number, -- 0 = solid, 1 = faded (LocalTransparencyModifier = Alpha * FADE)
	Target: number,
	Stamp: number,
	Conns: { RBXScriptConnection },
}

local items: { [Instance]: Item } = {}
local cells: { [number]: { Item } } = {}
local fading: { [Item]: boolean } = {} -- items whose Alpha is moving toward Target
local covering: { [Item]: boolean } = {} -- items whose Target is 1
local stamp = 0

local function cellKey(cx: number, cz: number): number
	return (cx + 32768) * 65536 + (cz + 32768)
end

local function collectParts(inst: Instance): { BasePart }
	local list = {}
	if inst:IsA("BasePart") then
		table.insert(list, inst)
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

-- World-axis bounding box of a set of (possibly rotated) parts.
local function bounds(parts: { BasePart }): (Vector3?, Vector3?)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, p in ipairs(parts) do
		local cf, half = p.CFrame, p.Size / 2
		local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
		local ex = math.abs(r.X) * half.X + math.abs(u.X) * half.Y + math.abs(l.X) * half.Z
		local ey = math.abs(r.Y) * half.X + math.abs(u.Y) * half.Y + math.abs(l.Y) * half.Z
		local ez = math.abs(r.Z) * half.X + math.abs(u.Z) * half.Y + math.abs(l.Z) * half.Z
		local c = cf.Position
		minX, maxX = math.min(minX, c.X - ex), math.max(maxX, c.X + ex)
		minY, maxY = math.min(minY, c.Y - ey), math.max(maxY, c.Y + ey)
		minZ, maxZ = math.min(minZ, c.Z - ez), math.max(maxZ, c.Z + ez)
	end
	if minX > maxX then
		return nil, nil
	end
	return Vector3.new(minX, minY, minZ), Vector3.new(maxX, maxY, maxZ)
end

local function unplace(item: Item)
	for _, key in ipairs(item.Keys) do
		local list = cells[key]
		if list then
			local i = table.find(list, item)
			if i then
				list[i] = list[#list]
				list[#list] = nil
			end
			if #list == 0 then
				cells[key] = nil
			end
		end
	end
	table.clear(item.Keys)
end

local function place(item: Item)
	unplace(item)
	local mn, mx = bounds(item.Parts)
	if not mn or not mx then
		return
	end
	item.Min, item.Max = mn, mx
	for cx = math.floor(mn.X / CELL), math.floor(mx.X / CELL) do
		for cz = math.floor(mn.Z / CELL), math.floor(mx.Z / CELL) do
			local key = cellKey(cx, cz)
			local list = cells[key]
			if not list then
				list = {}
				cells[key] = list
			end
			table.insert(list, item)
			table.insert(item.Keys, key)
		end
	end
end

local function apply(item: Item)
	local ltm = item.Alpha * FADE
	for _, p in ipairs(item.Parts) do
		p.LocalTransparencyModifier = ltm
	end
end

local function setTarget(item: Item, target: number)
	if item.Target ~= target then
		item.Target = target
		fading[item] = true
		if target > 0 then
			covering[item] = true
		else
			covering[item] = nil
		end
	end
end

local function unregister(inst: Instance)
	local item = items[inst]
	if not item then
		return
	end
	items[inst] = nil
	fading[item] = nil
	covering[item] = nil
	unplace(item)
	for _, c in ipairs(item.Conns) do
		c:Disconnect()
	end
	for _, p in ipairs(item.Parts) do
		p.LocalTransparencyModifier = 0
	end
end

local function register(inst: Instance)
	if items[inst] or not inst:IsDescendantOf(workspace) then
		return
	end
	if not (inst:IsA("BasePart") or inst:IsA("Model") or inst:IsA("Folder")) then
		return
	end
	local item: Item = {
		Inst = inst,
		Parts = collectParts(inst),
		Min = Vector3.zero,
		Max = Vector3.zero,
		Keys = {},
		Alpha = 0,
		Target = 0,
		Stamp = 0,
		Conns = {},
	}
	items[inst] = item
	place(item)
	if not inst:IsA("BasePart") then
		-- a model whose parts change (mesh swap, late parts): refresh parts and box once
		local queued = false
		local function refresh(d: Instance)
			if queued or not d:IsA("BasePart") then
				return
			end
			queued = true
			task.defer(function()
				queued = false
				if items[inst] == item then
					item.Parts = collectParts(inst)
					place(item)
					apply(item)
				end
			end)
		end
		table.insert(item.Conns, inst.DescendantAdded:Connect(refresh))
		table.insert(item.Conns, inst.DescendantRemoving:Connect(refresh))
	end
end

-- Does the segment o → p pass through the box (min - pad, max + pad)?
local function crosses(o: Vector3, p: Vector3, mn: Vector3, mx: Vector3, pad: number): boolean
	local t0, t1 = 0, 1
	local d = p.X - o.X
	local lo, hi = mn.X - pad, mx.X + pad
	if math.abs(d) < 1e-6 then
		if o.X < lo or o.X > hi then
			return false
		end
	else
		local a, b = (lo - o.X) / d, (hi - o.X) / d
		if a > b then
			a, b = b, a
		end
		t0, t1 = math.max(t0, a), math.min(t1, b)
		if t0 > t1 then
			return false
		end
	end
	d = p.Y - o.Y
	lo, hi = mn.Y - pad, mx.Y + pad
	if math.abs(d) < 1e-6 then
		if o.Y < lo or o.Y > hi then
			return false
		end
	else
		local a, b = (lo - o.Y) / d, (hi - o.Y) / d
		if a > b then
			a, b = b, a
		end
		t0, t1 = math.max(t0, a), math.min(t1, b)
		if t0 > t1 then
			return false
		end
	end
	d = p.Z - o.Z
	lo, hi = mn.Z - pad, mx.Z + pad
	if math.abs(d) < 1e-6 then
		if o.Z < lo or o.Z > hi then
			return false
		end
	else
		local a, b = (lo - o.Z) / d, (hi - o.Z) / d
		if a > b then
			a, b = b, a
		end
		t0, t1 = math.max(t0, a), math.min(t1, b)
		if t0 > t1 then
			return false
		end
	end
	return true
end

-- Points that must stay visible: the player's body, then two ground rings around them.
local OFFSETS: { Vector3 } = {
	Vector3.new(0, 0.6, 0),
	Vector3.new(0, 3, 0),
	Vector3.new(0, 7.5, 0), -- above the head (health bar)
}
for i = 0, 7 do
	local a = i * math.pi / 4
	table.insert(OFFSETS, Vector3.new(math.cos(a) * INNER, 1.5, math.sin(a) * INNER))
	local b = a + math.pi / 8
	table.insert(OFFSETS, Vector3.new(math.cos(b) * OUTER, 1, math.sin(b) * OUTER))
end
local points: { Vector3 } = table.create(#OFFSETS, Vector3.zero)

local function subject(cam: Camera): Vector3?
	-- the run camera focuses the followed player (or the spectated teammate)
	local focus = cam.Focus.Position
	if focus.Magnitude > 1e-3 then
		return focus
	end
	local char = player.Character
	local root = char and char.PrimaryPart
	return root and root.Position or nil
end

local function check()
	stamp += 1
	local cam = workspace.CurrentCamera
	local focus = cam and player:GetAttribute("InRun") == true and subject(cam) or nil
	if cam and focus then
		local eye = cam.CFrame.Position
		local floorY = GroundHeight.At(focus.X, focus.Z)
		local ground = Vector3.new(focus.X, floorY, focus.Z)
		for i, off in ipairs(OFFSETS) do
			points[i] = ground + off
		end
		-- only the grid cells between the camera and the protected area
		local reach = OUTER + 2
		local x0 = math.floor((math.min(eye.X, focus.X - reach)) / CELL)
		local x1 = math.floor((math.max(eye.X, focus.X + reach)) / CELL)
		local z0 = math.floor((math.min(eye.Z, focus.Z - reach)) / CELL)
		local z1 = math.floor((math.max(eye.Z, focus.Z + reach)) / CELL)
		for cx = x0, x1 do
			for cz = z0, z1 do
				local list = cells[cellKey(cx, cz)]
				if list then
					for _, item in ipairs(list) do
						if item.Stamp ~= stamp then
							item.Stamp = stamp
							local pad = item.Target > 0 and PAD_KEEP or PAD_FADE
							local cover = false
							-- anything entirely below knee height hides nothing worth seeing
							if item.Max.Y > floorY + 1.2 then
								for _, p in ipairs(points) do
									if crosses(eye, p, item.Min, item.Max, pad) then
										cover = true
										break
									end
								end
							end
							setTarget(item, cover and 1 or 0)
						end
					end
				end
			end
		end
	end
	-- faded items that were not looked at this time (player moved away, run ended)
	for item in pairs(covering) do
		if item.Stamp ~= stamp then
			setTarget(item, 0)
		end
	end
end

local started = false

function Occlusion.Init()
	if started then
		return
	end
	started = true
	CollectionService:GetInstanceAddedSignal(TAG):Connect(register)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unregister)
	for _, inst in ipairs(CollectionService:GetTagged(TAG)) do
		register(inst)
	end

	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		acc += dt
		if acc >= CHECK_EVERY then
			acc = 0
			check()
		end
		local step = dt * FADE_RATE
		for item in pairs(fading) do
			local a, t = item.Alpha, item.Target
			a = a < t and math.min(t, a + step) or math.max(t, a - step)
			item.Alpha = a
			apply(item)
			if a == t then
				fading[item] = nil
			end
		end
	end)
end

-- Number of tagged items currently faded (dev / preview checks).
function Occlusion.FadedCount(): number
	local n = 0
	for _ in pairs(covering) do
		n += 1
	end
	return n
end

return Occlusion
