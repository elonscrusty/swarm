--[[
	Showcase.lua
	The hero on the lobby dais. While the menu is open, a CLIENT-ONLY clone of the selected
	character (with its skin) stands on the dais of the castle courtyard, facing the menu
	camera; the menu UI sits around it.

	Where it stands: the part "MenuStand" inside workspace.SwarmMap.Lobby (any part on the
	dais: the hero's feet go on the surface found straight below its centre). Until the map
	has one, the lobby spawn emblem (SwarmState "LobbySpawn") is used.
	Which model: the player's own live character when it matches (it carries the VIP crown),
	otherwise the server-built template ReplicatedStorage.CharacterPreviews["<Id>|<Skin>"].
	A source is only copied once its whole rig is there (six body parts + their Motor6Ds),
	and it is copied again when its parts / joints change: after a run the new lobby
	character is still replicating when the menu shows, and a copy taken then kept the
	hero without arms for good.
	Pose: src/shared/HeroPoses.lua (HeroPoses.Apply(model, "Showcase", t): the stance plus
	idle breathing; the copy is fully anchored and re-placed from its rest pose each
	frame). If that module is missing, a small built-in idle drives the Motor6Ds.
	Drag to turn: pressing on empty screen over the hero (touch, mouse; the right stick on a
	gamepad) and dragging spins it around its vertical axis with a little inertia; after
	SPIN.IdleSeconds without input it eases back to its idle stance. A press that lands on a
	button, panel, list or text box is never taken (checked with GetGuiObjectsAtPosition),
	and the camera / menu are not touched. The input hooks live only while the menu shows.
	"Reduced effects" shortens the inertia and the ease back.

	Real lobby characters near the dais (and always your own) are hidden locally with
	LocalTransparencyModifier while the menu shows, so only the showcase hero stands there.

	Showcase.Init()                     once (UIBuilder)
	Showcase.SetVisible(on)             menu shown / hidden
	Showcase.Show(characterId, skinId)  what to show (selection, browsing, skin preview)
	Showcase.SetRing(ringId)            the worn dais ring from the level track
	                                    (AccountData.Rings; "" = none): a ring of glowing
	                                    segments on the dais around the hero, optional
	                                    rising sparkles and a soft light (your screen only)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local AccountData = require(Shared:WaitForChild("AccountData"))
local ViewportPreview = require(script.Parent.ViewportPreview)
local ClientSettings = require(script.Parent.ClientSettings)

local Showcase = {}

local player = Players.LocalPlayer

local folder: Folder? = nil
local visible = false
local wantChar = CharacterData.Default
local wantSkin = "Default"

local model: Model? = nil
local modelKey = "" -- "<char>|<skin>|<source instance>"
local modelChar = ""
local modelSkin = ""
local rootOffset = 3 -- root height above the feet
local standCF: CFrame? = nil
local nextStandSearch = 0
local appearStart = 0
local poseClock = 0
local hidden: { [Model]: boolean } = {}

-- Drag to turn
local SPIN = {
	RadPerPixel = 0.012, -- turn per pixel dragged
	StickRadPerSec = 3.2, -- gamepad right stick at full tilt
	IdleSeconds = 2.5, -- no input this long, then ease back to the idle stance
	IdleSecondsReduced = 1,
	Friction = 3.5, -- inertia decay per second
	FrictionReduced = 9,
	EaseRate = 3, -- ease-back speed per second
	EaseRateReduced = 8,
	MaxSpeed = 14, -- rad/s cap on the flick
}
local yaw = 0 -- extra turn about the vertical axis (radians)
local spinVel = 0 -- rad/s while coasting
local lastInput = 0 -- os.clock() of the last drag / stick input
local dragInput: InputObject? = nil
local dragLast = Vector2.zero
local dragSamples: { { number } } = {} -- { time, dx } of the last moments, for the flick
local stickX = 0
local spinConns: { RBXScriptConnection } = {}

------------------------------------------------------------------------------------------
-- HeroPoses (optional shared module, made by the models pass)
------------------------------------------------------------------------------------------

local heroPoses: any = nil
local posesChecked = false

local function poses(): any
	if not posesChecked then
		posesChecked = true
		local mod = Shared:FindFirstChild("HeroPoses")
		if mod and mod:IsA("ModuleScript") then
			local ok, result = pcall(require, mod)
			if ok and type(result) == "table" then
				heroPoses = result
			else
				warn("[Showcase] HeroPoses failed to load: " .. tostring(result))
			end
		end
	end
	return heroPoses
end

local function joint(m: Model, name: string): Motor6D?
	local j = m:FindFirstChild(name, true)
	if j and j:IsA("Motor6D") then
		return j
	end
	return nil
end

-- Built-in stance + breathing (used when HeroPoses is missing or has no showcase pose).
local function fallbackPose(m: Model, t: number)
	local breath = math.sin(t * 1.7)
	local root = joint(m, "RootJoint")
	if root then
		root.Transform = CFrame.new(0, breath * 0.03, 0)
	end
	local neck = joint(m, "Neck")
	if neck then
		neck.Transform = CFrame.Angles(-0.04 + math.sin(t * 0.9) * 0.02, math.sin(t * 0.45) * 0.08, 0)
	end
	local ls, rs = joint(m, "Left Shoulder"), joint(m, "Right Shoulder")
	if ls then
		ls.Transform = CFrame.Angles(0.08, 0, -0.16 - breath * 0.025)
	end
	if rs then
		rs.Transform = CFrame.Angles(-0.18, 0, 0.2 + breath * 0.025)
	end
	local lh, rh = joint(m, "Left Hip"), joint(m, "Right Hip")
	if lh then
		lh.Transform = CFrame.Angles(0, 0, -0.07)
	end
	if rh then
		rh.Transform = CFrame.Angles(0, 0, 0.07)
	end
end

--[[
	Applies the showcase pose for time t. HeroPoses is called through whichever entry point
	it offers (it is written in parallel); any error falls back to the built-in idle.
]]
local function applyPose(m: Model, t: number)
	local hp = poses()
	if hp then
		local ok = false
		local fn = hp.ApplyShowcase or hp.Showcase or hp.Apply or hp.Pose or hp.Update
		if type(fn) == "function" then
			if fn == hp.Apply or fn == hp.Pose then
				ok = pcall(fn, m, "Showcase", t)
			else
				ok = pcall(fn, m, t)
			end
		end
		if ok then
			return
		end
	end
	fallbackPose(m, t)
end

------------------------------------------------------------------------------------------
-- Where the hero stands
------------------------------------------------------------------------------------------

local function lobbyModel(): Instance?
	local map = workspace:FindFirstChild("SwarmMap")
	return (map and map:FindFirstChild("Lobby")) or workspace:FindFirstChild("Lobby")
end

local function excludeList(): { Instance }
	local list: { Instance } = {}
	if folder then
		table.insert(list, folder)
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

-- First solid, visible surface below `from` (skips invisible helpers like MenuStand itself).
local function groundBelow(from: Vector3, depth: number): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = excludeList()
	for _ = 1, 6 do
		params.FilterDescendantsInstances = exclude
		local hit = workspace:Raycast(from, Vector3.new(0, -depth, 0), params)
		if not hit then
			return nil
		end
		local part = hit.Instance
		if part:IsA("BasePart") and part.Transparency < 0.95 then
			return hit.Position
		end
		table.insert(exclude, part)
	end
	return nil
end

local function cameraPosition(lobby: Instance?): Vector3
	local cam = lobby and lobby:FindFirstChild("MenuCamera", true)
	if cam and cam:IsA("BasePart") then
		return cam.Position
	end
	return workspace.CurrentCamera.CFrame.Position
end

-- Feet CFrame on the dais, facing the menu camera (cached, searched again every 2 s).
local function findStand(): CFrame?
	local now = os.clock()
	if standCF and now < nextStandSearch then
		return standCF
	end
	nextStandSearch = now + 2
	local lobby = lobbyModel()
	local base: Vector3? = nil
	local stand = lobby and lobby:FindFirstChild("MenuStand", true)
	if stand and stand:IsA("BasePart") then
		base = stand.Position
	else
		local spawn = Remotes.State():GetAttribute("LobbySpawn")
		if typeof(spawn) == "CFrame" then
			base = spawn.Position - Vector3.new(0, 3, 0)
		end
	end
	if not base then
		return standCF
	end
	local feet = groundBelow(base + Vector3.new(0, 4, 0), 12) or base
	local camPos = cameraPosition(lobby)
	local flat = Vector3.new(camPos.X, feet.Y, camPos.Z)
	if (flat - feet).Magnitude < 0.1 then
		flat = feet + Vector3.new(0, 0, 1)
	end
	standCF = CFrame.lookAt(feet, flat) * CFrame.Angles(0, math.rad(Config.UI.ShowcaseYawDegrees or 0), 0)
	return standCF
end

------------------------------------------------------------------------------------------
-- The clone
------------------------------------------------------------------------------------------

-- A number per source instance (a respawned character is a new instance with the same name).
local sourceIds: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local nextSourceId = 0
local function idOf(inst: Instance): number
	local id = sourceIds[inst]
	if not id then
		nextSourceId += 1
		id = nextSourceId
		sourceIds[inst] = id
	end
	return id
end

-- The six body parts and the Motor6D that joins each one (ModelBuilder's hero rig).
local RIG_JOINTS = {
	RootJoint = "Torso",
	Neck = "Head",
	["Left Shoulder"] = "Left Arm",
	["Right Shoulder"] = "Right Arm",
	["Left Hip"] = "Left Leg",
	["Right Hip"] = "Right Leg",
}

--[[
	True when every body part of the rig is there and joined. A model can be seen while it
	is still arriving: right after a run the new lobby character replicates in the same
	moment the menu shows again, and a copy taken then has no arms (or no shoulder joints).
]]
local function rigReady(source: Model): boolean
	for jointName, partName in pairs(RIG_JOINTS) do
		local j = source:FindFirstChild(jointName, true)
		if not (j and j:IsA("Motor6D") and j.Part0 and j.Part1 and j.Part1.Name == partName and j.Part1:IsDescendantOf(source)) then
			return false
		end
	end
	return true
end

-- Parts and joints of a source: when this grows (pieces still arriving), copy it again.
local function signature(source: Model): number
	local n = 0
	for _, d in ipairs(source:GetDescendants()) do
		if d:IsA("BasePart") or d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			n += 1
		end
	end
	return n
end

local function sourceFor(characterId: string, skinId: string): Model?
	local own = player.Character
	if own and own.PrimaryPart and own:GetAttribute("CharacterId") == characterId and (own:GetAttribute("SkinId") or "Default") == skinId and rigReady(own) then
		return own
	end
	local template = ViewportPreview.Template(characterId, skinId)
	if template and rigReady(template) then
		return template
	end
	return nil
end

local function cloneOf(source: Model): Model?
	local was = source.Archivable
	source.Archivable = true
	local ok, result = pcall(function()
		return source:Clone()
	end)
	source.Archivable = was
	if not ok or not result then
		return nil
	end
	local m = result :: Model
	-- HeroPoses poses an all-anchored copy by placing each part from its rest pose; the
	-- built-in idle needs live joints (only the root anchored)
	local allAnchored = poses() ~= nil
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BaseScript") or d:IsA("Humanoid") or d:IsA("BillboardGui") or d:IsA("ProximityPrompt") or d:IsA("Sound") or d:IsA("ForceField") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = allAnchored or d.Name == "HumanoidRootPart"
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.LocalTransparencyModifier = 0
		end
	end
	if not m.PrimaryPart then
		local root = m:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			m.PrimaryPart = root
		end
	end
	if not m.PrimaryPart then
		m:Destroy()
		return nil
	end
	return m
end

local function setModelTransparency(m: Model, t: number)
	for _, d in ipairs(m:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			d.LocalTransparencyModifier = t
		end
	end
end

-- Gold ring + light flash on the dais when a new hero appears.
local function appearEffect(at: CFrame)
	local f = folder
	if not f then
		return
	end
	local ring = Instance.new("Part")
	ring.Name = "AppearRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Theme.Palette.gold_300
	ring.Transparency = 0.35
	ring.Size = Vector3.new(0.08, 2, 2)
	ring.CFrame = at * CFrame.new(0, 0.06, 0) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = f
	local light = Instance.new("PointLight")
	light.Color = Theme.Palette.gold_300
	light.Range = 14
	light.Brightness = 2.2
	light.Shadows = false
	light.Parent = ring
	local sparks = Instance.new("ParticleEmitter")
	sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	sparks.Color = ColorSequence.new(Theme.Palette.gold_200)
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	sparks.Lifetime = NumberRange.new(0.5, 0.9)
	sparks.Speed = NumberRange.new(3, 6)
	sparks.SpreadAngle = Vector2.new(25, 25)
	sparks.Acceleration = Vector3.new(0, -4, 0)
	sparks.EmissionDirection = Enum.NormalId.Right -- the ring's local +X points up
	sparks.Rate = 0
	sparks.Parent = ring
	sparks:Emit(14)
	TweenService:Create(ring, TweenInfo.new(0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), { Size = Vector3.new(0.08, 9, 9), Transparency = 1 }):Play()
	TweenService:Create(light, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Brightness = 0 }):Play()
	task.delay(1.2, function()
		ring:Destroy()
	end)
end

-- Hero pivot on the dais: feet on the stand, turned by the drag yaw.
local function placeAt(stand: CFrame, lift: number): CFrame
	return stand * CFrame.Angles(0, yaw, 0) * CFrame.new(0, lift, 0)
end

local function dropModel(fade: boolean)
	local old = model
	model = nil
	modelKey = ""
	if not old then
		return
	end
	if fade then
		local m = old
		task.spawn(function()
			for i = 1, 5 do
				if not m.Parent then
					return
				end
				setModelTransparency(m, i / 5)
				task.wait(0.03)
			end
			m:Destroy()
		end)
	else
		old:Destroy()
	end
end

-- Makes the clone match the wanted character / skin (and the best source for it).
local function refresh()
	if not visible or not folder then
		dropModel(false)
		return
	end
	local source = sourceFor(wantChar, wantSkin)
	if not source then
		return -- not built / not fully arrived yet; the 0.25 s check calls again
	end
	local key = wantChar .. "|" .. wantSkin .. "|" .. tostring(idOf(source)) .. "|" .. tostring(signature(source))
	if model and modelKey == key and model.Parent then
		return
	end
	local stand = findStand()
	if not stand then
		return
	end
	local m = cloneOf(source)
	if not m then
		return
	end
	-- same hero from a better source (template → live character with the VIP crown):
	-- swap quietly; a different hero or skin gets the appear effect
	local sameLook = model ~= nil and modelChar == wantChar and modelSkin == wantSkin
	dropModel(not sameLook)
	local root = m.PrimaryPart :: BasePart
	local bbCF, bbSize = m:GetBoundingBox()
	rootOffset = math.clamp(root.Position.Y - (bbCF.Position.Y - bbSize.Y / 2), 2.4, 4.2)
	m.Name = "ShowcaseHero"
	m:PivotTo(placeAt(stand, rootOffset))
	-- a soft warm key light so the hero is the brightest thing on screen
	local keyLight = Instance.new("PointLight")
	keyLight.Name = "ShowcaseLight"
	keyLight.Color = Theme.Palette.fx_ivory
	keyLight.Range = 9
	keyLight.Brightness = 0.9
	keyLight.Shadows = false
	keyLight.Parent = root
	-- a front fill (towards the camera) so the face / armour front is not lost against
	-- the torch-lit gate behind
	local fill = Instance.new("Attachment")
	fill.Name = "ShowcaseFill"
	fill.Position = Vector3.new(0, 1.5, -5)
	fill.Parent = root
	local fillLight = Instance.new("PointLight")
	fillLight.Color = Theme.Palette.gold_200
	fillLight.Range = 12
	fillLight.Brightness = 1.6
	fillLight.Shadows = false
	fillLight.Parent = fill
	m.Parent = folder
	model = m
	modelKey = key
	modelChar, modelSkin = wantChar, wantSkin
	if not sameLook then
		appearStart = os.clock()
		appearEffect(stand)
	else
		appearStart = 0
	end
	applyPose(m, poseClock)
end

------------------------------------------------------------------------------------------
-- Hiding the real lobby characters near the dais
------------------------------------------------------------------------------------------

local function setHidden(char: Model, on: boolean)
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") or d:IsA("Decal") then
			local want = on and 1 or 0
			if d.LocalTransparencyModifier ~= want then
				d.LocalTransparencyModifier = want
			end
		end
	end
end

local function updateHidden()
	local stand = standCF
	local radius = Config.UI.ShowcaseClearRadius or 8
	local keep: { [Model]: boolean } = {}
	if visible then
		for _, p in ipairs(Players:GetPlayers()) do
			local char = p.Character
			local root = char and char.PrimaryPart
			if char and root and p:GetAttribute("InRun") ~= true then
				local near = stand ~= nil and ((root.Position - stand.Position) * Vector3.new(1, 0, 1)).Magnitude <= radius
				if p == player or near then
					keep[char] = true
					setHidden(char, true)
				end
			end
		end
	end
	for char in pairs(hidden) do
		if not keep[char] then
			if char.Parent then
				setHidden(char, false)
			end
		end
	end
	hidden = keep
end

------------------------------------------------------------------------------------------
-- Dais ring (level-track cosmetic)
------------------------------------------------------------------------------------------

local wantRing = ""
local ringModel: Model? = nil
local ringKey = ""
local RING_SEGMENTS = 28

local function dropRing()
	if ringModel then
		ringModel:Destroy()
		ringModel = nil
	end
	ringKey = ""
end

local function ringPart(parent: Instance, size: Vector3, cf: CFrame, color: Color3, transparency: number): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
	return p
end

-- Builds / moves / removes the ring to match wantRing and the stand.
local function refreshRing()
	local def = AccountData.Rings[wantRing]
	local stand = standCF
	if not visible or not folder or not def or not stand then
		dropRing()
		return
	end
	local key = wantRing .. "|" .. tostring(stand.Position)
	if ringModel and ringKey == key and ringModel.Parent then
		return
	end
	dropRing()
	local m = Instance.new("Model")
	m.Name = "DaisRing"
	local function circle(radius: number, thick: number, transparency: number)
		local step = math.pi * 2 / RING_SEGMENTS
		local len = 2 * radius * math.tan(step / 2) + 0.05
		for i = 1, RING_SEGMENTS do
			local a = i * step
			local pos = stand * CFrame.new(math.cos(a) * radius, 0.07, math.sin(a) * radius)
			ringPart(m, Vector3.new(len, 0.08, thick), CFrame.new(pos.Position) * CFrame.Angles(0, -a + math.pi / 2, 0), def.Color, transparency)
		end
	end
	circle(3.3, 0.22, 0.15)
	if def.Double then
		circle(3.9, 0.1, 0.4)
	end
	local core = ringPart(m, Vector3.new(0.2, 0.2, 0.2), stand * CFrame.new(0, 0.3, 0), def.Color, 1)
	core.Name = "Core"
	local light = Instance.new("PointLight")
	light.Color = def.Color
	light.Range = 10
	light.Brightness = def.Glow or 0.6
	light.Shadows = false
	light.Parent = core
	if def.Sparkles then
		local sparks = Instance.new("ParticleEmitter")
		sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparks.Color = ColorSequence.new(def.Color)
		sparks.LightEmission = 1
		sparks.LightInfluence = 0
		sparks.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(1, 0) })
		sparks.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		sparks.Lifetime = NumberRange.new(1.2, 2)
		sparks.Speed = NumberRange.new(0.8, 1.6)
		sparks.SpreadAngle = Vector2.new(10, 10)
		sparks.Rate = 6
		sparks.EmissionDirection = Enum.NormalId.Top
		sparks.Shape = Enum.ParticleEmitterShape.Disc
		sparks.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		sparks.Parent = core
		core.Size = Vector3.new(6.6, 0.05, 6.6)
	end
	m.Parent = folder
	ringModel = m
	ringKey = key
end

------------------------------------------------------------------------------------------
-- Drag to turn
------------------------------------------------------------------------------------------

-- The hero's rectangle on screen (viewport pixels), widened so a thumb can start beside the
-- figure. nil when it is off screen.
local function heroRegion(): (Vector2?, Vector2?)
	local m = model
	local cam = workspace.CurrentCamera
	if not m or not m.Parent or not cam then
		return nil, nil
	end
	local cf, size = m:GetBoundingBox()
	local lo, hi = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
	for ix = -1, 1, 2 do
		for iy = -1, 1, 2 do
			for iz = -1, 1, 2 do
				local p = cam:WorldToViewportPoint((cf * CFrame.new(size.X / 2 * ix, size.Y / 2 * iy, size.Z / 2 * iz)).Position)
				if p.Z > 0 then
					lo = Vector2.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y))
					hi = Vector2.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y))
				end
			end
		end
	end
	if lo.X == math.huge then
		return nil, nil
	end
	local h = hi.Y - lo.Y
	local cx = (lo.X + hi.X) / 2
	local halfW = math.max((hi.X - lo.X) / 2 + h * 0.35, h * 0.6)
	return Vector2.new(cx - halfW, lo.Y - h * 0.12), Vector2.new(cx + halfW, hi.Y + h * 0.12)
end

-- True when something that wants the press is under this point: a button, list, text box, an
-- Active panel, or a dimmed full-screen cover. Transparent full-screen frames are ignored.
local function blockedAt(pos: Vector2): boolean
	local pg = player:FindFirstChildOfClass("PlayerGui")
	local cam = workspace.CurrentCamera
	if not pg or not cam then
		return false
	end
	local view = cam.ViewportSize
	local inset = GuiService:GetGuiInset()
	-- ScreenGuis may or may not ignore the top inset: look at both readings
	for _, q in ipairs({ pos, pos - inset }) do
		local ok, objs = pcall(function()
			return pg:GetGuiObjectsAtPosition(q.X, q.Y)
		end)
		if ok and type(objs) == "table" then
			for _, o in ipairs(objs) do
				local gui = o :: GuiObject
				if gui:IsA("GuiButton") or gui:IsA("TextBox") or gui:IsA("ScrollingFrame") then
					return true
				end
				if gui.Active then
					local big = gui.AbsoluteSize.X >= view.X * 0.9 and gui.AbsoluteSize.Y >= view.Y * 0.9
					if not big or gui.BackgroundTransparency < 0.9 then
						return true
					end
				end
			end
		end
	end
	return false
end

local function stopDrag(flick: boolean)
	if dragInput == nil then
		return
	end
	dragInput = nil
	spinVel = 0
	if flick then
		local now = os.clock()
		local sum, first = 0, now
		for _, s in ipairs(dragSamples) do
			if now - s[1] <= 0.12 then
				sum += s[2]
				first = math.min(first, s[1])
			end
		end
		if sum ~= 0 then
			spinVel = math.clamp(sum * SPIN.RadPerPixel / math.max(now - first, 1 / 30), -SPIN.MaxSpeed, SPIN.MaxSpeed)
		end
	end
	table.clear(dragSamples)
	lastInput = os.clock()
end

local function dragBy(dx: number)
	yaw += dx * SPIN.RadPerPixel
	local now = os.clock()
	lastInput = now
	table.insert(dragSamples, { now, dx })
	while #dragSamples > 0 and now - dragSamples[1][1] > 0.25 do
		table.remove(dragSamples, 1)
	end
end

local function onInputBegan(input: InputObject, _processed: boolean)
	if dragInput or not visible or not model then
		return
	end
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	local lo, hi = heroRegion()
	if not lo or not hi or pos.X < lo.X or pos.X > hi.X or pos.Y < lo.Y or pos.Y > hi.Y then
		return
	end
	if blockedAt(pos) then
		return
	end
	dragInput = input
	dragLast = pos
	spinVel = 0
	table.clear(dragSamples)
	lastInput = os.clock()
end

local function onInputChanged(input: InputObject, _processed: boolean)
	if input.KeyCode == Enum.KeyCode.Thumbstick2 then
		stickX = math.abs(input.Position.X) > 0.15 and input.Position.X or 0
		return
	end
	local d = dragInput
	if not d then
		return
	end
	local moved = input == d or (d.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseMovement)
	if not moved then
		return
	end
	local pos = Vector2.new(input.Position.X, input.Position.Y)
	dragBy(pos.X - dragLast.X)
	dragLast = pos
end

local function onInputEnded(input: InputObject, _processed: boolean)
	local d = dragInput
	if d and (input == d or (d.UserInputType == Enum.UserInputType.MouseButton1 and input.UserInputType == Enum.UserInputType.MouseButton1)) then
		stopDrag(true)
	end
	if input.KeyCode == Enum.KeyCode.Thumbstick2 then
		stickX = 0
	end
end

-- Hooks the drag input (only while the menu shows) / releases it and the turn.
local function setSpinInput(on: boolean)
	for _, c in ipairs(spinConns) do
		c:Disconnect()
	end
	table.clear(spinConns)
	dragInput = nil
	stickX = 0
	spinVel = 0
	table.clear(dragSamples)
	if on then
		table.insert(spinConns, UserInputService.InputBegan:Connect(onInputBegan))
		table.insert(spinConns, UserInputService.InputChanged:Connect(onInputChanged))
		table.insert(spinConns, UserInputService.InputEnded:Connect(onInputEnded))
	else
		yaw = 0
	end
end

-- Per frame: stick turn, inertia, then the ease back to the idle stance. True while turned.
local function stepSpin(dt: number): boolean
	if dragInput ~= nil then
		return true
	end
	local reduced = ClientSettings.Reduced()
	if stickX ~= 0 then
		yaw += stickX * SPIN.StickRadPerSec * dt
		spinVel = 0
		lastInput = os.clock()
	elseif spinVel ~= 0 then
		yaw += spinVel * dt
		spinVel *= math.exp(-dt * (reduced and SPIN.FrictionReduced or SPIN.Friction))
		if math.abs(spinVel) < 0.02 then
			spinVel = 0
		end
	end
	local idle = reduced and SPIN.IdleSecondsReduced or SPIN.IdleSeconds
	if stickX == 0 and spinVel == 0 and yaw ~= 0 and os.clock() - lastInput >= idle then
		-- shortest way round to the idle stance
		local a = (yaw + math.pi) % (math.pi * 2) - math.pi
		a *= math.exp(-dt * (reduced and SPIN.EaseRateReduced or SPIN.EaseRate))
		yaw = math.abs(a) < 0.002 and 0 or a
		return true
	end
	return yaw ~= 0
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

-- Turns the hero by this many degrees as if dragged (for the preview scenes and tools); it
-- then eases back like a real drag.
function Showcase.Spin(degrees: number)
	yaw += math.rad(degrees)
	spinVel = 0
	lastInput = os.clock()
end

function Showcase.SetRing(ringId: string?)
	local id = type(ringId) == "string" and ringId or ""
	if id == wantRing then
		return
	end
	wantRing = id
	refreshRing()
end

function Showcase.SetVisible(on: boolean)
	if visible == on then
		return
	end
	visible = on
	setSpinInput(on)
	if on then
		nextStandSearch = 0
		refresh()
	else
		dropModel(false)
	end
	refreshRing()
	updateHidden()
end

function Showcase.IsVisible(): boolean
	return visible
end

-- Shows this character + skin on the dais (no-op when it already does).
function Showcase.Show(characterId: string?, skinId: string?)
	local c = characterId or CharacterData.Default
	if not CharacterData.Characters[c] then
		c = CharacterData.Default
	end
	local s = skinId or "Default"
	if c == wantChar and s == wantSkin and model then
		return
	end
	wantChar, wantSkin = c, s
	refresh()
end

function Showcase.Current(): (string, string)
	return wantChar, wantSkin
end

function Showcase.Init()
	local f = Instance.new("Folder")
	f.Name = "SwarmShowcase"
	f.Parent = workspace
	folder = f

	local checkTimer = 0
	RunService.RenderStepped:Connect(function(dt)
		if not visible then
			return
		end
		poseClock += dt
		local m = model
		local turned = stepSpin(dt)
		if m and m.Parent then
			local stand = standCF
			if appearStart > 0 and stand then
				-- rise onto the dais
				local a = math.clamp((os.clock() - appearStart) / 0.42, 0, 1)
				local e = 1 - (1 - a) ^ 4
				m:PivotTo(placeAt(stand, rootOffset - 0.9 * (1 - e)))
				if a >= 1 then
					appearStart = 0
				end
			end
			if turned and standCF and appearStart == 0 then
				m:PivotTo(placeAt(standCF, rootOffset))
			end
			applyPose(m, poseClock)
		end
		checkTimer += dt
		if checkTimer >= 0.25 then
			checkTimer = 0
			-- the stand may move (map rebuilt) and templates / characters may change
			local before = standCF
			findStand()
			if model and standCF and before and (standCF.Position - before.Position).Magnitude > 0.05 then
				model:PivotTo(placeAt(standCF, rootOffset))
			end
			-- also picks up a source that was still arriving (more parts / joints now) and
			-- the live character once it is complete
			refresh()
			refreshRing()
			updateHidden()
		end
	end)

	-- your own character respawns when you change character, skin or buy VIP
	player.CharacterAdded:Connect(function()
		task.delay(0.4, refresh)
	end)
	-- the server rebuilds the templates once the uploaded meshes have loaded
	task.spawn(function()
		local previews = ReplicatedStorage:WaitForChild("CharacterPreviews", 30)
		if previews then
			previews.ChildAdded:Connect(function()
				task.defer(function()
					modelKey = "" -- force a rebuild from the new template
					refresh()
				end)
			end)
			refresh()
		end
	end)
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if player:GetAttribute("InRun") then
			setSpinInput(false)
			-- the run spawns a fresh character; never leave anything hidden
			for char in pairs(hidden) do
				if char.Parent then
					setHidden(char, false)
				end
			end
			hidden = {}
		end
	end)
end

return Showcase
