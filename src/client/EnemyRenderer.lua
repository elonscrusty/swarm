--[[
	EnemyRenderer.lua
	Puts a detailed, animated ModelLibrary model on every live enemy, on this client only.

	The server moves one plain Part per enemy ("Body", the hit body). Here we hide that
	part (LocalTransparencyModifier) and draw the model in its place, smoothing between
	network updates so movement looks fluid even at a low replication rate. All model
	pieces move with a single workspace:BulkMoveTo per frame.

	Detail budget (Config.Graphics.MaxDetailedEnemies): when more enemies are alive than
	the budget, the ones nearest the camera focus get the full model (ranked a few times a
	second) and the rest show their plain body, restyled locally in the creature's palette
	colour. The boss and elites are always detailed. Models are pooled per enemy type, so
	a recycled body reuses parts instead of building new ones.

	Readability: Flash() gives a brief white hit flash (model or plain body); elites stand
	on a soft gold ground ring on top of their bigger, gold-tinted model with its crown.
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Palette = require(Shared:WaitForChild("Palette"))
local ModelLibrary = require(script.Parent.ModelLibrary)

local EnemyRenderer = {}

type Slot = {
	Body: BasePart,
	Type: string?,
	Elite: boolean,
	Pieces: { any },
	Motion: string,
	Scale: number,
	Phase: number,
	Render: CFrame?,
	LastPos: Vector3?,
	Move: number,
	Parked: boolean,
	FlashUntil: number,
	Dist: number,
	Halo: BasePart?,
}

type PooledModel = { Pieces: { any }, Motion: string, Scale: number }

local slots: { [number]: Slot } = {}
local PARK = CFrame.new(0, -150, 0)
local ACTIVE_Y = -100
local FLOOR_Y = Config.ArenaOrigin.Y
local DISC = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X → Y (a flat disc)
local FLAT = Vector3.new(1, 0, 1)
local WHITE = Color3.new(1, 1, 1)
local RANK_EVERY = 0.3 -- seconds between nearest-first detail rankings
local POOL_CAP = 48 -- spare models kept per enemy type

local partsBuf: { BasePart } = {}
local cframesBuf: { CFrame } = {}
local clock = 0
local modelFolder: Instance? = nil

-- Plain bodies (over the detail budget) in the creature colours of the art direction.
local PLAIN: { [string]: Color3 } = {
	Slime = Palette.beetle_300,
	Bat = Palette.wasp_500,
	Skeleton = Palette.beetle_600,
	Ghost = Palette.moth_300,
	Brute = Palette.slate_400,
	Bomber = Palette.tick_500,
	Boss = Palette.crimson_500,
}
local ELITE_GOLD = Palette.gold_400

------------------------------------------------------------------------------------------
-- Model pool (per enemy type + elite)
------------------------------------------------------------------------------------------

local modelPool: { [string]: { PooledModel } } = {}

local function modelKey(typeId: string, elite: boolean): string
	return elite and (typeId .. "*") or typeId
end

local function restoreColors(pieces: { any })
	for _, piece in ipairs(pieces) do
		piece.Part.Color = piece.Color
	end
end

-- Takes the slot's model away: kept for reuse when it is built from the uploaded meshes
-- (its final look); part-built fallbacks are dropped so they get replaced by meshes.
local function releaseModel(slot: Slot)
	local pieces = slot.Pieces
	if #pieces == 0 then
		return
	end
	slot.Pieces = {}
	local key = slot.Type and modelKey(slot.Type, slot.Elite) or nil
	local list = key and modelPool[key] or nil
	if key and not list then
		list = {}
		modelPool[key] = list
	end
	if list and #list < POOL_CAP and pieces[1].Part:IsA("MeshPart") then
		if slot.FlashUntil > 0 then
			restoreColors(pieces)
		end
		for _, piece in ipairs(pieces) do
			piece.Part.CFrame = PARK
		end
		table.insert(list, { Pieces = pieces, Motion = slot.Motion, Scale = slot.Scale })
	else
		for _, piece in ipairs(pieces) do
			piece.Part:Destroy()
		end
	end
end

local function rebuild(slot: Slot, typeId: string, elite: boolean)
	releaseModel(slot)
	local list = modelPool[modelKey(typeId, elite)]
	local spare = list and table.remove(list)
	if spare then
		slot.Pieces, slot.Motion, slot.Scale = spare.Pieces, spare.Motion, spare.Scale
	else
		local pieces, motion, scale = ModelLibrary.Enemy(typeId, elite)
		slot.Pieces, slot.Motion, slot.Scale = pieces, motion, scale
	end
	slot.Type = typeId
	slot.Elite = elite
	slot.Render = nil
	slot.FlashUntil = 0
	slot.Phase = math.random() * math.pi * 2
	slot.Parked = false
end

local function park(slot: Slot)
	if slot.Parked then
		return
	end
	slot.Parked = true
	slot.Render = nil
	for _, piece in ipairs(slot.Pieces) do
		piece.Part.CFrame = PARK
	end
end

------------------------------------------------------------------------------------------
-- Elite ground ring
------------------------------------------------------------------------------------------

local haloPool: { BasePart } = {}

local function takeHalo(): BasePart
	local p = table.remove(haloPool)
	if p then
		return p
	end
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = ELITE_GOLD
	part.Transparency = 0.6
	part.CFrame = PARK
	part.Parent = modelFolder
	return part
end

local function dropHalo(slot: Slot)
	local halo = slot.Halo
	if halo then
		slot.Halo = nil
		halo.CFrame = PARK
		table.insert(haloPool, halo)
	end
end

------------------------------------------------------------------------------------------
-- Plain bodies
------------------------------------------------------------------------------------------

local function plainLook(slot: Slot, typeId: string, elite: boolean, now: number)
	local body = slot.Body
	if body.LocalTransparencyModifier ~= 0 then
		body.LocalTransparencyModifier = 0
	end
	if now < slot.FlashUntil then
		return -- white hit flash on the body
	end
	local color = PLAIN[typeId]
	if not color then
		-- unknown type: keep the server's colour (undo a finished hit flash)
		local base = body:GetAttribute("BaseColor")
		if typeof(base) == "Color3" and body.Color ~= base then
			body.Color = base
		end
		return
	end
	if elite then
		color = color:Lerp(ELITE_GOLD, 0.4)
	end
	-- the server restyles recycled bodies; re-apply the local look whenever it differs
	if body.Color ~= color then
		body.Color = color
	end
	if body.Material ~= Enum.Material.SmoothPlastic then
		body.Material = Enum.Material.SmoothPlastic
	end
end

------------------------------------------------------------------------------------------
-- Tracking
------------------------------------------------------------------------------------------

local function track(model: Instance)
	local id = tonumber(string.sub(model.Name, 2))
	if not id then
		return
	end
	local body = model:WaitForChild("Body", 10) :: BasePart?
	if not body then
		return
	end
	slots[id] = {
		Body = body,
		Type = nil,
		Elite = false,
		Pieces = {},
		Motion = "Walk",
		Scale = 1,
		Phase = 0,
		Render = nil,
		LastPos = nil,
		Move = 0,
		Parked = true,
		FlashUntil = 0,
		Dist = 0,
		Halo = nil,
	}
end

-- White hit flash on enemy `id` (its model, or its plain body over the detail budget).
function EnemyRenderer.Flash(id: number): boolean
	local slot = slots[id]
	if not slot then
		return false -- not tracked yet: VFX flashes the body itself
	end
	local now = os.clock()
	if not slot.Parked and #slot.Pieces > 0 then
		if now >= slot.FlashUntil then
			for _, piece in ipairs(slot.Pieces) do
				piece.Part.Color = WHITE
			end
		end
	else
		local body = slot.Body
		if not body.Parent or body.CFrame.Y < ACTIVE_Y then
			return true
		end
		body.Color = WHITE
	end
	slot.FlashUntil = now + Config.Enemies.HitFlashSeconds
	return true
end

-- Where enemy `id` is drawn right now (body centre), or nil when it is not alive.
function EnemyRenderer.Position(id: number): Vector3?
	local slot = slots[id]
	if not slot then
		return nil
	end
	local body = slot.Body
	if not body.Parent or body.CFrame.Y < ACTIVE_Y then
		return nil
	end
	local render = slot.Render
	if render and not slot.Parked then
		return render.Position
	end
	return body.Position
end

------------------------------------------------------------------------------------------
-- Detail ranking: nearest to the camera focus first
------------------------------------------------------------------------------------------

local detailed: { [Slot]: boolean } = {}
local rankList: { Slot } = {}
local rankTimer = 0

local function rank()
	local cam = workspace.CurrentCamera
	local focus = cam and cam.Focus.Position or Vector3.zero
	table.clear(rankList)
	for _, slot in pairs(slots) do
		local body = slot.Body
		if body.Parent and body.CFrame.Y >= ACTIVE_Y then
			slot.Dist = ((body.Position - focus) * FLAT).Magnitude
			table.insert(rankList, slot)
		end
	end
	table.sort(rankList, function(a, b)
		return a.Dist < b.Dist
	end)
	table.clear(detailed)
	local limit = Config.Graphics.MaxDetailedEnemies
	for i, slot in ipairs(rankList) do
		if i > limit then
			break
		end
		detailed[slot] = true
	end
end

------------------------------------------------------------------------------------------
-- Frame
------------------------------------------------------------------------------------------

local function step(dt: number)
	clock += dt
	local now = os.clock()
	local alpha = 1 - math.exp(-dt * 18)
	table.clear(partsBuf)
	table.clear(cframesBuf)
	local n = 0

	-- the budget only matters when more enemies are alive than it allows
	local live = 0
	for _, slot in pairs(slots) do
		if slot.Body.Parent and slot.Body.CFrame.Y >= ACTIVE_Y then
			live += 1
		end
	end
	local budgeted = live > Config.Graphics.MaxDetailedEnemies
	rankTimer -= dt
	if budgeted and rankTimer <= 0 then
		rankTimer = RANK_EVERY
		rank()
	end

	for _, slot in pairs(slots) do
		local body = slot.Body
		local cf = body.CFrame
		local typeId = body:GetAttribute("Type")
		if cf.Y < ACTIVE_Y or not body.Parent or typeof(typeId) ~= "string" then
			park(slot)
			dropHalo(slot)
		else
			local elite = body:GetAttribute("Elite") == true
			if budgeted and not detailed[slot] and typeId ~= "Boss" and not elite then
				-- over the detail budget: the plain server body in the creature's colour
				park(slot)
				dropHalo(slot)
				plainLook(slot, typeId, elite, now)
			else
				if slot.Type ~= typeId or slot.Elite ~= elite or #slot.Pieces == 0 then
					rebuild(slot, typeId, elite)
				end
				if body.LocalTransparencyModifier ~= 1 then
					body.LocalTransparencyModifier = 1
				end
				slot.Parked = false

				-- smooth toward the server position; snap on big jumps (spawn, recycle)
				local render = slot.Render
				if not render or (render.Position - cf.Position).Magnitude > 12 then
					render = cf
				else
					render = render:Lerp(cf, alpha)
				end
				slot.Render = render

				local last = slot.LastPos
				local speed = last and ((cf.Position - last) * FLAT).Magnitude / math.max(dt, 1e-3) or 0
				slot.LastPos = cf.Position
				slot.Move += (math.clamp(speed / 10, 0, 1) - slot.Move) * math.min(1, dt * 6)

				if slot.FlashUntil > 0 and now >= slot.FlashUntil then
					slot.FlashUntil = 0
					restoreColors(slot.Pieces)
				end

				local bodyCF = render * ModelLibrary.Motion(slot.Motion, clock, slot.Phase, slot.Move, slot.Scale)
				for _, piece in ipairs(slot.Pieces) do
					n += 1
					partsBuf[n] = piece.Part
					cframesBuf[n] = ModelLibrary.PieceCFrame(bodyCF, piece, clock, slot.Phase, slot.Move)
				end

				-- elites: soft gold ring on the ground under them
				if elite then
					local halo = slot.Halo
					if not halo then
						halo = takeHalo()
						slot.Halo = halo
						local d = math.max(body.Size.X, body.Size.Z) * 1.3 + 1.2
						halo.Size = Vector3.new(0.06, d, d)
					end
					halo.Transparency = 0.62 + 0.08 * math.sin(clock * 3 + slot.Phase)
					n += 1
					partsBuf[n] = halo
					local p = render.Position
					cframesBuf[n] = CFrame.new(p.X, FLOOR_Y + 0.07, p.Z) * DISC
				elseif slot.Halo then
					dropHalo(slot)
				end
			end
		end
	end
	if n > 0 then
		workspace:BulkMoveTo(partsBuf, cframesBuf, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function EnemyRenderer.Init()
	local folder = Instance.new("Folder")
	folder.Name = "SwarmEnemyModels"
	folder.Parent = workspace
	modelFolder = folder
	ModelLibrary.SetFolder(folder)
	task.spawn(function()
		local enemies = workspace:WaitForChild("SwarmEnemies")
		enemies.ChildAdded:Connect(function(m)
			task.spawn(track, m)
		end)
		for _, m in ipairs(enemies:GetChildren()) do
			task.spawn(track, m)
		end
	end)
	RunService.RenderStepped:Connect(step)
end

return EnemyRenderer
