--[[
	ViewportPreview.lua
	Turning 3D character previews for the lobby screens (ViewportFrame + its own camera).

	Models come from ReplicatedStorage.CharacterPreviews ("<CharacterId>|<SkinId>", built by
	the server's RunManager from the same ModelBuilder as the real characters) or from a
	clone of the player's own character.

	Cheap on phones: the model never moves; each visible preview only turns its camera
	around the model and bobs it a little, all in one RenderStepped loop. Hidden previews
	(screen not shown) are skipped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local ViewportPreview = {}

export type Preview = {
	Frame: ViewportFrame,
	Camera: Camera,
	Model: Model?,
	Center: Vector3,
	Radius: number,
	Height: number,
	Phase: number,
	Speed: number,
	Source: Instance?,
}

local previews: { Preview } = {}
local loopStarted = false

-- Template for a character + skin, or nil while the server hasn't built it yet.
function ViewportPreview.Template(characterId: string, skinId: string?): Model?
	local folder = ReplicatedStorage:FindFirstChild("CharacterPreviews")
	if not folder then
		return nil
	end
	local m = folder:FindFirstChild(characterId .. "|" .. (skinId or "Default"))
		or folder:FindFirstChild(characterId .. "|Default")
	if m and m:IsA("Model") then
		return m
	end
	return nil
end

-- True when the frame and all its GUI ancestors are visible.
local function shown(obj: Instance): boolean
	local o: Instance? = obj
	while o do
		if o:IsA("GuiObject") then
			if not o.Visible then
				return false
			end
		elseif o:IsA("LayerCollector") then
			return o.Enabled
		end
		o = o.Parent
	end
	return false
end

local function startLoop()
	if loopStarted then
		return
	end
	loopStarted = true
	RunService.RenderStepped:Connect(function()
		local t = os.clock()
		local spin = (math.pi * 2) / math.max(1, Config.UI.PreviewSpinSeconds)
		for i = #previews, 1, -1 do
			local p = previews[i]
			if not p.Frame.Parent then
				table.remove(previews, i)
			elseif p.Model then
				-- only work for previews that are actually on screen
				if shown(p.Frame) then
					local a = t * spin * p.Speed + p.Phase
					local bob = math.sin(t * 2 + p.Phase) * 0.12 * p.Height
					local eye = p.Center + Vector3.new(math.sin(a) * p.Radius, p.Height * 0.15 - bob, math.cos(a) * p.Radius)
					p.Camera.CFrame = CFrame.lookAt(eye, p.Center + Vector3.new(0, -bob, 0))
				end
			end
		end
	end)
end

-- Creates an empty preview frame. Size / position it like any other GuiObject.
function ViewportPreview.Create(parent: Instance, props: { [string]: any }?): Preview
	local vf = Instance.new("ViewportFrame")
	vf.Name = "Preview"
	vf.BackgroundTransparency = 1
	vf.Ambient = Color3.fromRGB(170, 170, 185)
	vf.LightColor = Color3.fromRGB(255, 245, 230)
	vf.LightDirection = Vector3.new(-1, -1.4, -0.8)
	vf.Active = false
	if props then
		for k, v in pairs(props) do
			(vf :: any)[k] = v
		end
	end
	local cam = Instance.new("Camera")
	cam.FieldOfView = 30
	cam.Parent = vf
	vf.CurrentCamera = cam
	vf.Parent = parent
	local p: Preview = {
		Frame = vf,
		Camera = cam,
		Model = nil,
		Center = Vector3.zero,
		Radius = 10,
		Height = 5,
		Phase = math.random() * math.pi * 2,
		Speed = 1,
		Source = nil,
	}
	table.insert(previews, p)
	startLoop()
	return p
end

--[[
	Shows a copy of `source` (a template or a live character). Setting the same source
	again does nothing (profile refreshes happen often); a rebuilt template or a respawned
	character is a new instance, so it refreshes.
]]
function ViewportPreview.SetModel(p: Preview, source: Model?)
	if source and p.Source == source and p.Model then
		return
	end
	if p.Model then
		p.Model:Destroy()
		p.Model = nil
	end
	p.Source = nil
	if not source then
		return
	end
	local wasArchivable = source.Archivable
	source.Archivable = true
	local ok, clone = pcall(function()
		return source:Clone()
	end)
	source.Archivable = wasArchivable
	if not ok or not clone then
		return
	end
	local model = clone :: Model
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BaseScript") or d:IsA("Humanoid") or d:IsA("BillboardGui") or d:IsA("ProximityPrompt") or d:IsA("Sound") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	-- centre the bounding box on the origin (the camera orbits around it)
	local cf, size = model:GetBoundingBox()
	model:PivotTo(model:GetPivot() - cf.Position)
	model.Parent = p.Frame
	p.Model = model
	p.Source = source
	local height = math.max(size.Y, 1)
	p.Height = height
	p.Center = Vector3.new(0, 0, 0)
	-- distance so the whole body fits the 30° camera with a little margin
	p.Radius = (height * 0.5 + 0.6) / math.tan(math.rad(15)) * 1.05
end

-- Preview of the local player's own character (live clone), or nil if not spawned.
function ViewportPreview.OwnCharacter(): Model?
	local char = Players.LocalPlayer.Character
	if char and char:IsDescendantOf(workspace) and char.PrimaryPart then
		return char
	end
	return nil
end

return ViewportPreview
