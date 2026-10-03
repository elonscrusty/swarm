-- Shared combat colours and optional readable sound cues. Hazard outlines are cosmetic,
-- bounded, and never replace the real damaging area or the enemy's attack telegraph.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Settings = require(script.Parent.ClientSettings)
local Accessibility = {}
local player = Players.LocalPlayer
local colors = {
	Danger = Color3.fromRGB(255, 155, 62), Heal = Color3.fromRGB(80, 225, 220),
	Ally = Color3.fromRGB(105, 190, 255), Loot = Color3.fromRGB(250, 215, 95),
	Magic = Color3.fromRGB(205, 155, 255), Neutral = Color3.fromRGB(242, 240, 226),
}

function Accessibility.Color(color: Color3, role: string?): Color3
	local mode = Settings.Get("Colorblind")
	if mode == nil or mode == "Off" then return color end
	if not role then
		local h, s, v = color:ToHSV()
		if s < 0.18 or v < 0.28 then return color end
		role = (h < 0.06 or h > 0.85) and "Danger" or h < 0.19 and "Loot"
			or h < 0.46 and "Heal" or h < 0.70 and "Ally" or "Magic"
	end
	if mode == "Tritanopia" then
		if role == "Danger" then return Color3.fromRGB(255, 105, 105) end
		if role == "Heal" then return Color3.fromRGB(245, 245, 235) end
		if role == "Loot" then return Color3.fromRGB(255, 175, 190) end
	end
	return colors[role] or color
end

local labels = { FuseTick = "BOMB FUSE", SpitterWindup = "ACID ATTACK", Lunge = "CHARGE",
	BossWarn = "BOSS ATTACK", BossSummon = "ENEMIES SUMMONED", BurrowWarn = "BURROW ATTACK",
	Hurt = "HIT", Revive = "REVIVED", LevelUp = "LEVEL UP", Death = "FALLEN" }
local cue: TextLabel? = nil
local lastCue = -math.huge
local cueToken = 0
local started = false

function Accessibility.Cue(name: string, position: Vector3?)
	if Settings.Get("VisualAudioCues") ~= true or player:GetAttribute("InRun") ~= true then return end
	local label = labels[name]
	if not label or os.clock() - lastCue < 0.3 then return end
	lastCue = os.clock()
	if not cue then
		local gui = Instance.new("ScreenGui")
		gui.Name = "SwarmSoundCues"
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 12
		gui.Parent = player:WaitForChild("PlayerGui")
		local text = Instance.new("TextLabel")
		text.Name = "Cue"
		text.AnchorPoint = Vector2.new(0.5, 1)
		text.Position = UDim2.new(0.5, 0, 1, -120)
		text.Size = UDim2.fromOffset(210, 28)
		text.BackgroundColor3 = Color3.fromRGB(20, 27, 35)
		text.BackgroundTransparency = 0.1
		text.TextColor3 = colors.Neutral
		text.TextSize = 15
		text.Font = Enum.Font.SourceSansBold
		text.Active = false
		text.Parent = gui
		cue = text
	end
	local char = player.Character
	local root = char and char.PrimaryPart
	if position and root then
		local delta = position - root.Position
		label ..= math.abs(delta.X) > math.abs(delta.Z) and (delta.X > 0 and " • EAST" or " • WEST")
			or (delta.Z > 0 and " • SOUTH" or " • NORTH")
	end
	local display = cue :: TextLabel
	display.Text = label
	display.Visible = true
	cueToken += 1
	local token = cueToken
	task.delay(1.2, function()
		if token == cueToken and cue then cue.Visible = false end
	end)
end

type Hazard = { Model: Model, Parts: { BasePart }, Label: TextLabel, Kind: string }
local hazards: { Hazard } = {}
local arena: Instance? = nil
local detailFolder: Folder? = nil
local function clearHazards()
	for _, hazard in ipairs(hazards) do
		for _, p in ipairs(hazard.Parts) do p:Destroy() end
	end
	table.clear(hazards)
	if detailFolder then detailFolder:Destroy(); detailFolder = nil end
end

local function readHazards(model: Instance)
	clearHazards()
	local folder = Instance.new("Folder")
	folder.Name = "SwarmHazardOutlines"
	folder.Parent = workspace
	detailFolder = folder
	for _, child in ipairs(model:GetChildren()) do
		local kind, radius = child:GetAttribute("HazardKind"), child:GetAttribute("HazardRadius")
		if child:IsA("Model") and type(kind) == "string" and type(radius) == "number" and #hazards < 16 then
			local pos = child:GetPivot().Position
			local pieces = {}
			for i = 1, 12 do
				local a = i * math.pi / 6
				local p = Instance.new("Part")
				p.Name = "DangerOutline"
				p.Size = Vector3.new(0.13, 0.05, radius * 0.40)
				p.CFrame = CFrame.new(pos.X + math.cos(a) * radius, pos.Y + 0.43, pos.Z + math.sin(a) * radius) * CFrame.Angles(0, -a, 0)
				p.Anchored = true
				p.CanCollide, p.CanTouch, p.CanQuery, p.CastShadow = false, false, false, false
				p.Parent = folder
				table.insert(pieces, p)
			end
			local gui = Instance.new("BillboardGui")
			gui.Name = "HazardName"
			gui.Adornee = pieces[1]
			gui.Size = UDim2.fromOffset(90, 18)
			gui.StudsOffsetWorldSpace = Vector3.new(0, 0.4, 0)
			gui.MaxDistance = 100
			gui.Parent = pieces[1]
			local text = Instance.new("TextLabel")
			text.Size = UDim2.fromScale(1, 1)
			text.BackgroundTransparency = 1
			text.Text = "! " .. string.upper(kind)
			text.TextColor3 = colors.Neutral
			text.TextStrokeTransparency = 0.15
			text.Font, text.TextSize = Enum.Font.SourceSansBold, 12
			text.Parent = gui
			table.insert(hazards, { Model = child, Parts = pieces, Label = text, Kind = kind })
		end
	end
end

function Accessibility.Init()
	if started then return end
	started = true
	Settings.OnChanged(function(key, value)
		if key == "VisualAudioCues" and value ~= true and cue then cue.Visible = false end
	end)
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		acc += dt
		if acc < 0.5 then return end
		acc = 0
		local map = workspace:FindFirstChild("SwarmMap")
		local current = nil
		if map and player:GetAttribute("InRun") == true then
			for _, child in ipairs(map:GetChildren()) do
				if string.sub(child.Name, 1, 6) == "Arena_" then current = child; break end
			end
		end
		if current ~= arena then
			arena = current
			if current then readHazards(current) else clearHazards() end
		end
		for _, hazard in ipairs(hazards) do
			local color = Accessibility.Color(Color3.fromRGB(240, 143, 80), "Danger")
			for _, p in ipairs(hazard.Parts) do p.Color = color end
		end
	end)
end

return Accessibility
