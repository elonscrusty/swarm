--[[
	FeatureHud.lua
	Reserved HUD slots for the 30-features batch, so new HUD pieces never touch Hud.lua or
	UIBuilder internals (docs/features/FOUNDATION.md). Its own ScreenGui, real pixels, the
	same safe-area settings as the main gui; drawn over the HUD (DisplayOrder 11).

	  Badges     top-right row under the counters / minimap: FeatureHud.Badge(id, opts),
	             FeatureHud.RemoveBadge(id)  (weather, event, curse-timer badges ...)
	  Announcer  one centred line in the upper third: FeatureHud.Announce(text, opts)
	             (kill streaks, combo counter; the newest text replaces the old one)
	  Ultimate   a round touch button above JUMP plus a keybind (Config.FeatureHud
	             UltimateKey / UltimatePad): FeatureHud.SetUltimate({ OnActivate, Charge,
	             Label }) shows it; FeatureHud.SetUltimate(nil) hides it again
	  PingWheel  an empty centred holder the TEAM feature fills: FeatureHud.Slot("PingWheel"),
	             FeatureHud.SetPingWheel(open)

	FeatureHud.Slot(name) returns the raw holder Frame ("Badges", "Announcer", "Ultimate",
	"PingWheel") for custom content. Everything is hidden outside a run, while dead for
	the ultimate, and while a panel covers the HUD (UIState.Covered: level-up, rewards,
	pause, results, travel ...). Nothing shows until a feature uses a slot.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIState = require(script.Parent.UIState)

local FeatureHud = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local F = Config.FeatureHud

local gui: ScreenGui? = nil
local slots: { [string]: Frame } = {}
local badges: { [string]: Frame } = {}
local announceLabel: TextLabel? = nil
local announceUntil = 0
local ultimate: { OnActivate: (() -> ())?, Charge: number?, Label: string? }? = nil
local ultButton: TextButton? = nil
local ultFill: Frame? = nil
local ultLabel: TextLabel? = nil
local pingOpen = false
local visible = false
local visibilityListeners: { (boolean) -> () } = {}

local function inRun(): boolean
	return player:GetAttribute("InRun") == true and Remotes.State():GetAttribute("Phase") == "Running"
end

-- True while the feature slots may show (in a run, nothing covering the HUD).
function FeatureHud.Visible(): boolean
	return visible
end

function FeatureHud.OnVisibility(fn: (boolean) -> ())
	table.insert(visibilityListeners, fn)
end

function FeatureHud.Slot(name: string): Frame?
	return slots[name]
end

------------------------------------------------------------------------------------------
-- Badges
------------------------------------------------------------------------------------------

--[[
	Adds or updates badge `id`: opts = { Text = "SNOW", Color = Color3, Order = number }.
	At most Config.FeatureHud.MaxBadges show (lowest Order first).
]]
function FeatureHud.Badge(id: string, opts: { Text: string?, Color: Color3?, Order: number? }): Frame?
	local row = slots.Badges
	if not row then
		return nil
	end
	local b = badges[id]
	if not b then
		b = UIKit.new("Frame", { Name = "Badge_" .. id, BackgroundColor3 = P.slate_900, BackgroundTransparency = 0.15, Size = UDim2.fromOffset(0, F.BadgeSize), AutomaticSize = Enum.AutomaticSize.X }, row) :: Frame
		UIKit.corner(b, Theme.Radius.M)
		UIKit.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, b)
		UIKit.text(b, "Label", "", { Name = "Text", Size = UDim2.fromOffset(0, F.BadgeSize), AutomaticSize = Enum.AutomaticSize.X, TextXAlignment = Enum.TextXAlignment.Center }, 14)
		badges[id] = b
	end
	local frame = b :: Frame
	local label = frame:FindFirstChild("Text") :: TextLabel?
	if label then
		label.Text = opts.Text or ""
	end
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = opts.Color or P.gold_400
	else
		UIKit.stroke(frame, opts.Color or P.gold_400, 1, 0.3)
	end
	frame.LayoutOrder = opts.Order or 100
	-- the cap: hide the highest orders beyond MaxBadges
	local list = {}
	for _, f in pairs(badges) do
		table.insert(list, f)
	end
	table.sort(list, function(a, c)
		return a.LayoutOrder < c.LayoutOrder or (a.LayoutOrder == c.LayoutOrder and a.Name < c.Name)
	end)
	for i, f in ipairs(list) do
		f.Visible = i <= F.MaxBadges
	end
	return frame
end

function FeatureHud.RemoveBadge(id: string)
	local b = badges[id]
	if b then
		b:Destroy()
		badges[id] = nil
	end
end

------------------------------------------------------------------------------------------
-- Announcer line
------------------------------------------------------------------------------------------

-- Shows `text` for opts.Seconds (default Config.FeatureHud.AnnounceSeconds); "" clears it.
function FeatureHud.Announce(text: string, opts: { Color: Color3?, Seconds: number? }?)
	local label = announceLabel
	if not label then
		return
	end
	local o = opts or {}
	label.Text = text
	label.TextColor3 = o.Color or P.gold_200
	announceUntil = text == "" and 0 or os.clock() + (o.Seconds or F.AnnounceSeconds)
end

------------------------------------------------------------------------------------------
-- Ultimate button
------------------------------------------------------------------------------------------

--[[
	cfg = { OnActivate = fn, Charge = 0..1 (1 = ready), Label = "ULT" } shows the button
	(touch) and binds the key; nil hides it and unbinds. Call again to update the charge.
]]
function FeatureHud.SetUltimate(cfg: { OnActivate: (() -> ())?, Charge: number?, Label: string? }?)
	ultimate = cfg
end

function FeatureHud.UltimateReady(): boolean
	local u = ultimate
	return u ~= nil and (u.Charge or 0) >= 1
end

local function fireUltimate()
	local u = ultimate
	if not u or not visible or player:GetAttribute("Alive") ~= true or (u.Charge or 0) < 1 then
		return
	end
	if u.OnActivate then
		local ok, err = pcall(u.OnActivate)
		if not ok then
			warn("[FeatureHud] ultimate: " .. tostring(err))
		end
	end
end
FeatureHud.FireUltimate = fireUltimate

------------------------------------------------------------------------------------------
-- Ping wheel holder
------------------------------------------------------------------------------------------

function FeatureHud.SetPingWheel(open: boolean)
	pingOpen = open == true
end

function FeatureHud.PingWheelOpen(): boolean
	return pingOpen and visible
end

------------------------------------------------------------------------------------------
-- Layout + per-frame state
------------------------------------------------------------------------------------------

-- The lowest bottom edge (pixels) of the HUD's top-right pieces, so badges sit under them.
local function rightColumnBottom(main: Instance?): number
	local bottom = 0
	if main then
		for _, name in ipairs({ "Counters", "MiniMap" }) do
			local f = main:FindFirstChild(name, true)
			if f and f:IsA("GuiObject") and f.Visible then
				bottom = math.max(bottom, f.AbsolutePosition.Y + f.AbsoluteSize.Y)
			end
		end
	end
	return bottom
end

local function setVisible(on: boolean)
	if visible == on then
		return
	end
	visible = on
	for _, fn in ipairs(visibilityListeners) do
		task.spawn(fn, on)
	end
end

function FeatureHud.Init()
	if gui then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = UIKit.new("ScreenGui", { Name = "FeatureHud", ResetOnSpawn = false, IgnoreGuiInset = true, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, DisplayOrder = 11, Enabled = false }, playerGui) :: ScreenGui
	gui = screen
	local root = UIKit.new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, screen)

	-- top-right badge row (right-aligned, wraps nothing: MaxBadges keeps it short)
	local badgeRow = UIKit.new("Frame", { Name = "Badges", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Size = UDim2.fromOffset(0, F.BadgeSize), AutomaticSize = Enum.AutomaticSize.X }, root) :: Frame
	UIKit.list(badgeRow, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	slots.Badges = badgeRow

	-- announcer / combo line (upper third, centred)
	local announce = UIKit.new("Frame", { Name = "Announcer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.26), Size = UDim2.new(0.9, 0, 0, 40) }, root) :: Frame
	announceLabel = UIKit.text(announce, "Title", "", { Name = "Line", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.35, TextScaled = true, Visible = false }, 26) :: any
	slots.Announcer = announce

	-- ultimate button (touch), above the JUMP button column
	local size = F.UltimateSize
	local ult = UIKit.new("Frame", { Name = "Ultimate", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(size, size), Visible = false }, root) :: Frame
	slots.Ultimate = ult
	local button = UIKit.new("TextButton", { Name = "Button", Text = "", AutoButtonColor = true, BackgroundColor3 = P.slate_900, BackgroundTransparency = 0.1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true }, ult) :: TextButton
	UIKit.corner(button, 999)
	UIKit.stroke(button, P.gold_400, 2, 0.1)
	ultFill = UIKit.new("Frame", { Name = "Charge", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.45, BorderSizePixel = 0, AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0) }, button) :: any
	ultLabel = UIKit.text(button, "Label", "ULT", { Name = "Label", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 2 }, 15) :: any
	button.Activated:Connect(fireUltimate)
	ultButton = button

	-- ping wheel holder (centre; TEAM fills it)
	local wheel = UIKit.new("Frame", { Name = "PingWheel", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(260, 260), Visible = false }, root) :: Frame
	slots.PingWheel = wheel

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == F.UltimateKey or input.KeyCode == F.UltimatePad then
			fireUltimate()
		end
	end)

	-- per frame: only writes that change something (no churn in the lobby)
	RunService.RenderStepped:Connect(function()
		local on = inRun() and not UIState.Covered()
		setVisible(on)
		if screen.Enabled ~= on then
			screen.Enabled = on
		end
		if not on then
			return
		end
		local now = os.clock()
		-- badges under the counters / minimap
		local main = playerGui:FindFirstChild("SwarmUI") or playerGui
		local cam = workspace.CurrentCamera
		local w = cam and cam.ViewportSize.X or 800
		local margin = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local y = math.max(rightColumnBottom(main) + 8, 64)
		local at = UDim2.fromOffset(w - margin, y)
		if badgeRow.Position ~= at then
			badgeRow.Position = at
		end
		local line = announceLabel
		if line then
			local show = line.Text ~= "" and now < announceUntil
			if line.Visible ~= show then
				line.Visible = show
			end
		end
		-- ultimate: shown while a feature set it, the player is alive and on touch screens
		-- (keyboard / gamepad players use the key; the button still shows the charge on PC)
		local u = ultimate
		local showUlt = u ~= nil and player:GetAttribute("Alive") == true
		if ult.Visible ~= showUlt then
			ult.Visible = showUlt
		end
		if showUlt and u then
			local jump = (Config.Movement.ButtonSize or 84) + (Config.Movement.ButtonMargin or 26)
			local vh = cam and cam.ViewportSize.Y or 600
			local pos = UDim2.fromOffset(w - (Config.Movement.ButtonMargin or 26), vh - jump - 12)
			if ult.Position ~= pos then
				ult.Position = pos
			end
			local charge = math.clamp(u.Charge or 0, 0, 1)
			local fill = ultFill :: Frame
			local want = UDim2.fromScale(1, charge)
			if fill.Size ~= want then
				fill.Size = want
			end
			local label = ultLabel :: TextLabel
			local text = u.Label or "ULT"
			if label.Text ~= text then
				label.Text = text
			end
			local b = ultButton :: TextButton
			local tint = charge >= 1 and P.gold_300 or P.slate_900
			if b.BackgroundColor3 ~= tint then
				b.BackgroundColor3 = tint
			end
		end
		local wheelOn = pingOpen
		if wheel.Visible ~= wheelOn then
			wheel.Visible = wheelOn
		end
	end)
end

return FeatureHud
