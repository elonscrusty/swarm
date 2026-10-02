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
	Pose: src/shared/HeroPoses.lua (HeroPoses.Apply(model, "Showcase", t): the stance plus
	idle breathing; the copy is fully anchored and re-placed from its rest pose each
	frame). If that module is missing, a small built-in idle drives the Motor6Ds.

	Real lobby characters near the dais (and always your own) are hidden locally with
	LocalTransparencyModifier while the menu shows, so only the showcase hero stands there.

	Showcase.Init()                     once (UIBuilder)
	Showcase.SetVisible(on)             menu shown / hidden
	Showcase.Show(characterId, skinId)  what to show (selection, browsing, skin preview)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local ViewportPreview = require(script.Parent.ViewportPreview)

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

local function sourceFor(characterId: string, skinId: string): Model?
	local own = player.Character
	if own and own.PrimaryPart and own:GetAttribute("CharacterId") == characterId and (own:GetAttribute("SkinId") or "Default") == skinId then
		return own
	end
	return ViewportPreview.Template(characterId, skinId)
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
		return -- template not built yet; CharacterPreviews.ChildAdded calls again
	end
	local key = wantChar .. "|" .. wantSkin .. "|" .. tostring(idOf(source))
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
	m:PivotTo(stand * CFrame.new(0, rootOffset, 0))
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
-- Public
------------------------------------------------------------------------------------------

function Showcase.SetVisible(on: boolean)
	if visible == on then
		return
	end
	visible = on
	if on then
		nextStandSearch = 0
		refresh()
	else
		dropModel(false)
	end
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
		if m and m.Parent then
			local stand = standCF
			if appearStart > 0 and stand then
				-- rise onto the dais
				local a = math.clamp((os.clock() - appearStart) / 0.42, 0, 1)
				local e = 1 - (1 - a) ^ 4
				m:PivotTo(stand * CFrame.new(0, rootOffset - 0.9 * (1 - e), 0))
				if a >= 1 then
					appearStart = 0
				end
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
				model:PivotTo(standCF * CFrame.new(0, rootOffset, 0))
			end
			if not model or not model.Parent then
				refresh()
			end
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
