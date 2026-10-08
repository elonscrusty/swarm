--!strict
--[[
	SwarmV2/Run/EntryOverlay.lua  (StarterPlayerScripts.SwarmV2Client.Run.EntryOverlay)
	OWNER: gameplay track (Chat 2).

	Full-screen loading cover while the server admits the player into a run.

	Reads (LocalPlayer attributes, set by SwarmV2.Run.RunEntry):
	  SwarmV2Entry      "Admitting" | "Waiting" | "Starting" | "InRun" | "Rejected" | nil
	  SwarmV2EntryMsg   string, detail line (the Rejected reason is shown in a warning colour)
	  SwarmV2EntryWait  number: seconds left when small (counted down locally from the moment it
	                    changed), or a server-time deadline (GetServerTimeNow) when > 1e6
	  SwarmClass / CharacterId   selected class id; the display name comes from ClassCatalog

	Shown for Admitting / Waiting / Starting / Rejected; fades out for InRun / nil.
	Two ScreenGuis: the cover (whole screen, behind the notch) and the text (device safe area),
	both above the HUD (DisplayOrder 10). Text is run through TextFit for large text sizes.

	Init() is called once from RunClient.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local Theme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Theme"))
local TextFit = require(Client:WaitForChild("TextFit"))

local EntryOverlay = {}

local player = Players.LocalPlayer
local C = Theme.Color

local TITLES: { [string]: string } = {
	Admitting = "CHECKING IN",
	Waiting = "WAITING FOR PARTY",
	Starting = "STARTING RUN",
	Rejected = "CAN'T JOIN",
}
local DEFAULT_MSG: { [string]: string } = {
	Admitting = "Checking your ticket...",
	Waiting = "Waiting for everyone to arrive...",
	Starting = "Get ready!",
	Rejected = "Something went wrong. Going back.",
}

local cover: Frame? = nil
local content: CanvasGroup? = nil
local titleLabel: TextLabel? = nil
local classLabel: TextLabel? = nil
local msgLabel: TextLabel? = nil
local countLabel: TextLabel? = nil
local dots: TextLabel? = nil

local shown = false
local waitDeadline: number? = nil -- os.clock() based
local fadeTween: { Tween } = {}

local function className(): string?
	local id = player:GetAttribute("SwarmClass")
	if type(id) ~= "string" or id == "" then
		id = player:GetAttribute("CharacterId")
	end
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local ok, name = pcall(function()
		local cat = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("ClassCatalog")) :: any
		local info = cat.Get(id)
		return info and info.Name
	end)
	if ok and type(name) == "string" then
		return name
	end
	return nil
end

local function label(parent: Instance, name: string, font: Font, y: number, h: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0)
	l.Position = UDim2.fromScale(0.5, y)
	l.Size = UDim2.fromScale(0.9, h)
	l.FontFace = font
	l.TextColor3 = color
	l.TextScaled = true
	l.TextWrapped = true
	l.Text = ""
	l.Parent = parent
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 64
	cap.MinTextSize = 10
	cap.Parent = l
	return l
end

local function build()
	if cover then
		return
	end
	local coverGui = Instance.new("ScreenGui")
	coverGui.Name = "SwarmV2EntryCover"
	coverGui.DisplayOrder = 60
	coverGui.IgnoreGuiInset = true
	coverGui.ScreenInsets = Enum.ScreenInsets.None
	coverGui.ResetOnSpawn = false
	coverGui.Enabled = false
	local bg = Instance.new("Frame")
	bg.Name = "Cover"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = C.Text
	bg.BackgroundTransparency = 0
	bg.BorderSizePixel = 0
	bg.Active = true -- swallow taps while covered
	bg.Parent = coverGui
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Theme.Arcade.BlueDeep, C.Text)
	grad.Parent = bg
	coverGui.Parent = player:WaitForChild("PlayerGui")

	local textGui = Instance.new("ScreenGui")
	textGui.Name = "SwarmV2EntryText"
	textGui.DisplayOrder = 61
	textGui.ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets
	textGui.ResetOnSpawn = false
	textGui.Enabled = false
	local group = Instance.new("CanvasGroup")
	group.Name = "Content"
	group.Size = UDim2.fromScale(1, 1)
	group.BackgroundTransparency = 1
	group.GroupTransparency = 1
	group.Parent = textGui

	classLabel = label(group, "Class", Theme.Font.Label, 0.2, 0.07, C.BlueLight)
	titleLabel = label(group, "Title", Theme.Font.Display, 0.3, 0.16, C.Panel)
	msgLabel = label(group, "Message", Theme.Font.Body, 0.5, 0.1, C.BluePale)
	countLabel = label(group, "Countdown", Theme.Font.Display, 0.63, 0.14, Theme.Arcade.PrimaryTop)
	dots = label(group, "Dots", Theme.Font.Display, 0.8, 0.06, C.BluePale)
	textGui.Parent = player:WaitForChild("PlayerGui")
	TextFit.Watch(textGui)

	cover = bg
	content = group
end

local function fade(toShown: boolean)
	build()
	local bg, group = cover :: Frame, content :: CanvasGroup
	local coverGui = (bg.Parent :: ScreenGui)
	local textGui = (group.Parent :: ScreenGui)
	for _, t in fadeTween do
		t:Cancel()
	end
	fadeTween = {}
	if toShown then
		coverGui.Enabled = true
		textGui.Enabled = true
		local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		table.insert(fadeTween, TweenService:Create(bg, info, { BackgroundTransparency = 0 }))
		table.insert(fadeTween, TweenService:Create(group, info, { GroupTransparency = 0 }))
	else
		local info = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		local t1 = TweenService:Create(bg, info, { BackgroundTransparency = 1 })
		local t2 = TweenService:Create(group, info, { GroupTransparency = 1 })
		table.insert(fadeTween, t1)
		table.insert(fadeTween, t2)
		t1.Completed:Connect(function(state)
			if state == Enum.PlaybackState.Completed and not shown then
				coverGui.Enabled = false
				textGui.Enabled = false
			end
		end)
	end
	for _, t in fadeTween do
		t:Play()
	end
end

local function readWait()
	local w = player:GetAttribute("SwarmV2EntryWait")
	if type(w) ~= "number" or w ~= w then
		waitDeadline = nil
	elseif w > 1e6 then
		waitDeadline = os.clock() + (w - workspace:GetServerTimeNow())
	else
		waitDeadline = os.clock() + math.max(0, w)
	end
end

local function refresh()
	build()
	local state = player:GetAttribute("SwarmV2Entry")
	local active = type(state) == "string" and TITLES[state] ~= nil
	if not active then
		if shown then
			shown = false
			fade(false)
		end
		return
	end
	local s = state :: string
	local rejected = s == "Rejected"
	local msg = player:GetAttribute("SwarmV2EntryMsg")
	if type(msg) ~= "string" or msg == "" then
		msg = DEFAULT_MSG[s]
	end
	local tl, ml, cl, kl, dl = titleLabel :: TextLabel, msgLabel :: TextLabel, classLabel :: TextLabel, countLabel :: TextLabel, dots :: TextLabel
	tl.Text = TITLES[s]
	tl.TextColor3 = if rejected then C.Danger else C.Panel
	ml.Text = msg :: string
	ml.TextColor3 = if rejected then Color3.fromRGB(255, 190, 120) else C.BluePale
	local cn = className()
	cl.Text = if cn then string.upper(cn) else ""
	readWait()
	kl.Visible = s == "Waiting" and waitDeadline ~= nil
	dl.Visible = not rejected
	if not shown then
		shown = true
		fade(true)
	end
end

local started = false

function EntryOverlay.Init()
	if started then
		return
	end
	started = true
	build()
	for _, a in { "SwarmV2Entry", "SwarmV2EntryMsg", "SwarmV2EntryWait", "SwarmClass", "CharacterId" } do
		player:GetAttributeChangedSignal(a):Connect(refresh)
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		if not shown then
			return
		end
		acc += dt
		if acc < 0.2 then
			return
		end
		acc = 0
		local d = dots :: TextLabel
		d.Text = string.rep(".", 1 + math.floor(os.clock() * 2) % 3)
		local cl = countLabel :: TextLabel
		if cl.Visible and waitDeadline then
			cl.Text = tostring(math.max(0, math.ceil(waitDeadline - os.clock()))) .. "s"
		end
	end)
	refresh()
end

return EntryOverlay
