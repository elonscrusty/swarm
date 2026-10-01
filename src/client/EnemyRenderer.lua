--[[
	EnemyRenderer.lua
	Puts a detailed, animated ModelLibrary model on every live enemy, on this client only.

	The server moves one plain Part per enemy ("Body", the hit body). Here we hide that
	part (LocalTransparencyModifier) and draw the model in its place, smoothing between
	network updates so movement looks fluid even at a low replication rate. All model
	pieces move with a single workspace:BulkMoveTo per frame.
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
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
}

local slots: { [number]: Slot } = {}
local PARK = CFrame.new(0, -150, 0)
local ACTIVE_Y = -100
local partsBuf: { BasePart } = {}
local cframesBuf: { CFrame } = {}
local clock = 0

local function destroyPieces(slot: Slot)
	for _, piece in ipairs(slot.Pieces) do
		piece.Part:Destroy()
	end
	table.clear(slot.Pieces)
end

local function rebuild(slot: Slot, typeId: string, elite: boolean)
	destroyPieces(slot)
	local pieces, motion, scale = ModelLibrary.Enemy(typeId, elite)
	slot.Pieces = pieces
	slot.Motion = motion
	slot.Scale = scale
	slot.Type = typeId
	slot.Elite = elite
	slot.Render = nil
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
	}
end

-- White hit flash on the model of enemy `id`.
function EnemyRenderer.Flash(id: number): boolean
	local slot = slots[id]
	if not slot or #slot.Pieces == 0 or slot.Parked then
		return false -- no model drawn: VFX flashes the plain body instead
	end
	if os.clock() >= slot.FlashUntil then
		for _, piece in ipairs(slot.Pieces) do
			piece.Part.Color = Color3.new(1, 1, 1)
		end
	end
	slot.FlashUntil = os.clock() + Config.Enemies.HitFlashSeconds
	return true
end

local function step(dt: number)
	clock += dt
	local now = os.clock()
	local alpha = 1 - math.exp(-dt * 18)
	table.clear(partsBuf)
	table.clear(cframesBuf)
	local n = 0
	local detailed = 0
	local limit = Config.Graphics.MaxDetailedEnemies
	for _, slot in pairs(slots) do
		local body = slot.Body
		local cf = body.CFrame
		if cf.Y < ACTIVE_Y or not body.Parent then
			park(slot)
		else
			local typeId = body:GetAttribute("Type")
			if typeof(typeId) == "string" and detailed >= limit and typeId ~= "Boss" then
				-- over the detail budget: show the plain server body instead
				park(slot)
				body.LocalTransparencyModifier = 0
			elseif typeof(typeId) == "string" then
				detailed += 1
				local elite = body:GetAttribute("Elite") == true
				if slot.Type ~= typeId or slot.Elite ~= elite or #slot.Pieces == 0 then
					rebuild(slot, typeId, elite)
				end
				body.LocalTransparencyModifier = 1
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
				local speed = last and ((cf.Position - last) * Vector3.new(1, 0, 1)).Magnitude / math.max(dt, 1e-3) or 0
				slot.LastPos = cf.Position
				slot.Move += (math.clamp(speed / 10, 0, 1) - slot.Move) * math.min(1, dt * 6)

				if slot.FlashUntil > 0 and now >= slot.FlashUntil then
					slot.FlashUntil = 0
					for _, piece in ipairs(slot.Pieces) do
						piece.Part.Color = piece.Color
					end
				end

				local bodyCF = render * ModelLibrary.Motion(slot.Motion, clock, slot.Phase, slot.Move, slot.Scale)
				for _, piece in ipairs(slot.Pieces) do
					n += 1
					partsBuf[n] = piece.Part
					cframesBuf[n] = ModelLibrary.PieceCFrame(bodyCF, piece, clock, slot.Phase, slot.Move)
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
