--!strict
--[[
	SwarmV2/Run/ClassHud.lua  (StarterPlayerScripts.SwarmV2Client.Run.ClassHud)
	OWNER: gameplay track (Chat 2).

	Small chip beside the ability / ULT panel showing the class passive:
	  ruckus Loot Rush, toastmaster Overheat, captain_croak Big Splash, granny_boom Tangled Up.

	Reads (LocalPlayer attributes): CharacterId (or SwarmClass), ClassCharge, InRun.
	ClassCharge may be a number 0..1 (fills the bar, shows a percentage) or a count / text
	(a number above 1 is shown as a count with a full bar, a string is shown as is).
	Hidden unless the player is in a run with a class character.

	Own ScreenGui (above the HUD, DisplayOrder 11, device safe insets). It is placed to the
	right of the HUD's "AbilityBar" frame when that is found in PlayerGui, otherwise at the
	bottom centre, nudged right. Hud.lua is not edited.

	Init() is called once from RunClient.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local Theme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Theme"))
local TextFit = require(Client:WaitForChild("TextFit"))

local ClassHud = {}

local player = Players.LocalPlayer
local C = Theme.Color
local A = Theme.Arcade

local PASSIVES: { [string]: string } = {
	ruckus = "LOOT RUSH",
	toastmaster = "OVERHEAT",
	captain_croak = "BIG SPLASH",
	granny_boom = "TANGLED UP",
}

local W, H = 150, 40

local gui: ScreenGui? = nil
local chip: Frame? = nil
local nameLabel: TextLabel? = nil
local valueLabel: TextLabel? = nil
local fill: Frame? = nil
local abilityBar: GuiObject? = nil
local lastFind = 0

local function classId(): string?
	local id = player:GetAttribute("CharacterId")
	if type(id) ~= "string" or not PASSIVES[id] then
		id = player:GetAttribute("SwarmClass")
	end
	if type(id) == "string" and PASSIVES[id] then
		return id
	end
	return nil
end

local function build()
	if gui then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "SwarmV2ClassHud"
	g.DisplayOrder = 11
	g.ResetOnSpawn = false
	g.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	g.Enabled = false

	local f = Instance.new("Frame")
	f.Name = "Chip"
	f.AnchorPoint = Vector2.new(0, 1)
	f.Size = UDim2.fromOffset(W, H)
	f.BackgroundColor3 = C.Panel
	f.BorderSizePixel = 0
	f.Parent = g
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.PanelEdge
	stroke.Thickness = 2
	stroke.Parent = f

	local nl = Instance.new("TextLabel")
	nl.Name = "Passive"
	nl.BackgroundTransparency = 1
	nl.Position = UDim2.fromOffset(8, 2)
	nl.Size = UDim2.new(1, -16, 0, 16)
	nl.FontFace = Theme.Font.Label
	nl.TextColor3 = C.TextMuted
	nl.TextSize = 12
	nl.TextXAlignment = Enum.TextXAlignment.Left
	nl.TextTruncate = Enum.TextTruncate.AtEnd
	nl.Parent = f

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(8, 22)
	track.Size = UDim2.new(1, -16, 0, 12)
	track.BackgroundColor3 = C.Track
	track.BorderSizePixel = 0
	track.Parent = f
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 6)
	tc.Parent = track

	local fl = Instance.new("Frame")
	fl.Name = "Fill"
	fl.Size = UDim2.fromScale(0, 1)
	fl.BackgroundColor3 = A.PrimaryBottom
	fl.BorderSizePixel = 0
	fl.Parent = track
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 6)
	fc.Parent = fl

	local vl = Instance.new("TextLabel")
	vl.Name = "Value"
	vl.BackgroundTransparency = 1
	vl.Size = UDim2.fromScale(1, 1)
	vl.FontFace = Theme.Font.Label
	vl.TextColor3 = C.Text
	vl.TextSize = 11
	vl.ZIndex = 3
	vl.Parent = track

	g.Parent = player:WaitForChild("PlayerGui")
	TextFit.Watch(g)
	gui, chip, nameLabel, valueLabel, fill = g, f, nl, vl, fl
end

local function findBar()
	local now = os.clock()
	if abilityBar and abilityBar.Parent then
		return
	end
	if now - lastFind < 1 then
		return
	end
	lastFind = now
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	for _, d in pg:GetDescendants() do
		if d.Name == "AbilityBar" and d:IsA("GuiObject") then
			abilityBar = d
			return
		end
	end
end

local function place()
	local f, g = chip :: Frame, gui :: ScreenGui
	findBar()
	local screen = g.AbsoluteSize
	local inset = g.AbsolutePosition
	local bar = abilityBar
	if bar and bar.Parent and bar.AbsoluteSize.X > 4 then
		-- right of the bar, same baseline; flip to the left if it would leave the screen
		local right = bar.AbsolutePosition.X + bar.AbsoluteSize.X - inset.X
		local bottom = bar.AbsolutePosition.Y + bar.AbsoluteSize.Y - inset.Y
		local x = right + 8
		if x + W > screen.X then
			x = bar.AbsolutePosition.X - inset.X - 8 - W
		end
		f.Position = UDim2.fromOffset(math.max(4, x), bottom)
	else
		f.Position = UDim2.fromOffset(screen.X / 2 + 220, screen.Y - 12)
	end
end

local function refresh()
	build()
	local id = classId()
	local inRun = player:GetAttribute("InRun") == true
	local g = gui :: ScreenGui
	if not id or not inRun then
		g.Enabled = false
		return
	end
	g.Enabled = true
	;(nameLabel :: TextLabel).Text = PASSIVES[id]
	local charge: any = player:GetAttribute("ClassCharge")
	local frac, text = 0, ""
	if type(charge) == "number" and charge == charge then
		if charge >= 0 and charge <= 1 then
			frac = charge
			text = string.format("%d%%", math.floor(charge * 100 + 0.5))
		else
			frac = 1
			text = tostring(math.floor(charge + 0.5))
		end
	elseif type(charge) == "string" then
		local n = tonumber(charge)
		frac = if n and n >= 0 and n <= 1 then n elseif n then 1 else 0
		text = charge
	end
	local fl = fill :: Frame
	fl.Size = UDim2.fromScale(frac, 1)
	fl.BackgroundColor3 = if frac >= 1 then A.Selected else A.PrimaryBottom
	;(valueLabel :: TextLabel).Text = text
end

local started = false

function ClassHud.Init()
	if started then
		return
	end
	started = true
	build()
	for _, a in { "ClassCharge", "CharacterId", "SwarmClass", "InRun" } do
		player:GetAttributeChangedSignal(a):Connect(refresh)
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.25 then
			return
		end
		acc = 0
		if (gui :: ScreenGui).Enabled then
			place()
		end
	end)
	refresh()
end

return ClassHud
