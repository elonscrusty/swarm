--[[
	FeatureHud.lua
	Reserved HUD slots for the 30-features batch, so new HUD pieces never touch Hud.lua or
	UIBuilder internals (docs/features/FOUNDATION.md). Its own ScreenGui, real pixels, the
	same safe-area settings as the main gui; drawn over the HUD (DisplayOrder 11).

	  Badges     top-right row under the counters / minimap: FeatureHud.Badge(id, opts),
	             FeatureHud.RemoveBadge(id)  (weather, event, curse-timer badges ...)
	  Announcer  one centred line in the upper third: FeatureHud.Announce(text, opts)
	             (kill streaks, combo counter; the newest text replaces the old one)
	  Ultimate   a round touch button beside / above JUMP plus a keybind (Config.FeatureHud
	             UltimateKey / UltimatePad): FeatureHud.SetUltimate({ OnActivate, Charge,
	             Label, Icon }) shows it; FeatureHud.SetUltimate(nil) hides it again.
	             Charging: the move's icon dimmed, a gold fill rising and "40%"; ready: a
	             gold face, the icon bright, "READY" and a soft pulsing halo (static with
	             Reduced effects). FeatureHud.UltimateCallout(text, seconds) shows a short
	             non-blocking note next to the button (the first-ready explanation).
	  PingWheel  an empty centred holder the TEAM feature fills: FeatureHud.Slot("PingWheel"),
	             FeatureHud.SetPingWheel(open)

	FeatureHud.Slot(name) returns the raw holder Frame ("Badges", "Announcer", "Ultimate",
	"PingWheel") for custom content. Everything is hidden outside a run, while dead for
	the ultimate, and while any panel is shown (UIState.Covered or UIState.Owner: level-up,
	rewards, the run menu drawer, results, travel ...). Nothing shows until a feature uses a slot.
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
local Icons = require(script.Parent.Icons)
local ClientSettings = require(script.Parent.ClientSettings)

local FeatureHud = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local F = Config.FeatureHud

local gui: ScreenGui? = nil
local slots: { [string]: Frame } = {}
local badges: { [string]: Frame } = {}
local announceLabel: TextLabel? = nil
local announceUntil = 0
export type UltimateCfg = { OnActivate: (() -> ())?, Charge: number?, Label: string?, Icon: string? }
local ultimate: UltimateCfg? = nil
local ultButton: TextButton? = nil
local ultFill: Frame? = nil
local ultLabel: TextLabel? = nil
local ultIcon: CanvasGroup? = nil
local ultIconKey: string? = nil
local ultGlow: Frame? = nil
local ultScale: UIScale? = nil
local ultReady: boolean? = nil
local ultLastFire = 0
local callout: Frame? = nil
local calloutLabel: TextLabel? = nil
local calloutUntil = 0
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

-- The badge row / announcer / ultimate placement reads AbsoluteSize / AbsolutePosition,
-- which forces a GUI layout pass whenever anything on screen changed that frame. So it runs
-- only when something of ours changed (layoutDirty) and otherwise once a second to
-- follow the HUD around it (minimap, team rows), not every frame.
local layoutDirty = true
local nextLayout = 0
local LAYOUT_EVERY = 1

-- Hides the highest orders beyond the cap (fewer on phones, Config.FeatureHud.MaxBadgesCompact).
local function applyCap()
	local list = {}
	for _, f in pairs(badges) do
		table.insert(list, f)
	end
	table.sort(list, function(a, c)
		return a.LayoutOrder < c.LayoutOrder or (a.LayoutOrder == c.LayoutOrder and a.Name < c.Name)
	end)
	local cap = UIKit.IsCompact() and (F.MaxBadgesCompact or F.MaxBadges) or F.MaxBadges
	for i, f in ipairs(list) do
		local on = i <= cap
		if f.Visible ~= on then
			f.Visible = on
		end
	end
end

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
	applyCap()
	layoutDirty = true
	return frame
end

function FeatureHud.RemoveBadge(id: string)
	local b = badges[id]
	if b then
		b:Destroy()
		badges[id] = nil
		applyCap()
		layoutDirty = true
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
	layoutDirty = true
end

------------------------------------------------------------------------------------------
-- Ultimate button
------------------------------------------------------------------------------------------

--[[
	cfg = { OnActivate = fn, Charge = 0..1 (1 = ready), Label = "ULT", Icon = icon name
	(Icons.Draw) } shows the button (touch) and binds the key; nil hides it and unbinds.
	Call again to update the charge.
]]
function FeatureHud.SetUltimate(cfg: UltimateCfg?)
	if (cfg == nil) ~= (ultimate == nil) then
		layoutDirty = true
	end
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
	-- a touch fires on press (InputBegan) and Activated follows on release: one request
	local now = os.clock()
	if now - ultLastFire < 0.35 then
		return
	end
	ultLastFire = now
	if u.OnActivate then
		local ok, err = pcall(u.OnActivate)
		if not ok then
			warn("[FeatureHud] ultimate: " .. tostring(err))
		end
	end
end
FeatureHud.FireUltimate = fireUltimate

-- A short note beside the ultimate button for `seconds` (default 5); never blocks input.
-- "" hides it.
function FeatureHud.UltimateCallout(text: string, seconds: number?)
	local label = calloutLabel
	if not label then
		return
	end
	label.Text = text
	calloutUntil = text == "" and 0 or os.clock() + (seconds or 5)
	layoutDirty = true
end

-- How a player fires the ultimate on this device: "Tap ULT", "Press Q", "Press RB".
function FeatureHud.UltimateHow(): string
	if UserInputService.GamepadEnabled and not UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Press RB"
	elseif UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
		return "Press " .. F.UltimateKey.Name
	end
	return "Tap ULT"
end

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

-- Screen rects (absolute pixels) the badge row must keep clear of: the HUD's top pieces,
-- the minimap, the team rows and a tutorial tip card. Refreshed by the layout below.
local function addRect(out: { Rect }, g: any)
	if typeof(g) == "table" then
		g = g.Instance
	end
	if typeof(g) == "Instance" and g:IsA("GuiObject") and g.Visible and g.Parent then
		local sg = g:FindFirstAncestorOfClass("ScreenGui")
		if sg and not sg.Enabled then
			return
		end
		local p, sz = g.AbsolutePosition, g.AbsoluteSize
		if sz.X > 1 and sz.Y > 1 then
			table.insert(out, Rect.new(p.X, p.Y, p.X + sz.X, p.Y + sz.Y))
		end
	end
end

local hudMod: any, teamMod: any = nil, nil
local function elementsOf(name: string): { [string]: any }?
	local mod = name == "Hud" and hudMod or teamMod
	if mod == nil then
		local ok, m = pcall(require, (script.Parent :: any):FindFirstChild(name))
		mod = ok and m or false
		if name == "Hud" then
			hudMod = mod
		else
			teamMod = mod
		end
	end
	return mod and mod.Elements and mod.Elements() or nil
end

local cachedFinds: { [string]: Instance? } = {}
local nextFind = 0
local function refreshFinds(playerGui: Instance)
	local now = os.clock()
	if now >= nextFind then
		nextFind = now + 1
		local main = playerGui:FindFirstChild("SwarmUI")
		cachedFinds.MiniMap = main and main:FindFirstChild("MiniMap", true)
		cachedFinds.TipCard = playerGui:FindFirstChild("TipCard", true)
		local spectate = playerGui:FindFirstChild("Spectate")
		cachedFinds.Spectate = spectate and spectate:FindFirstChild("Row")
	end
end

local function obstacles(playerGui: Instance): { Rect }
	refreshFinds(playerGui)
	local out = {}
	local els = elementsOf("Hud")
	if els then
		for _, key in ipairs({ "Counters", "Pause", "TimerPill", "Stage", "Plate", "Boss", "Bar" }) do
			addRect(out, els[key])
		end
	end
	addRect(out, cachedFinds.MiniMap)
	addRect(out, cachedFinds.TipCard)
	addRect(out, cachedFinds.Spectate)
	addRect(out, slots.Ultimate)
	local combo = slots.Ultimate and slots.Ultimate.Parent and slots.Ultimate.Parent:FindFirstChild("TeamCombo")
	addRect(out, combo)
	local team = elementsOf("TeamUI")
	local list = team and team.List
	if typeof(list) == "Instance" and list:IsA("GuiObject") and list.Visible then
		for _, row in ipairs(list:GetChildren()) do
			addRect(out, row)
		end
	end
	return out
end

-- The pieces right above the row (counters / pause): the row starts under them.
local function topRightBottom(): number
	local els = elementsOf("Hud")
	local bottom = 0
	if els then
		for _, key in ipairs({ "Counters", "Pause" }) do
			local g = els[key]
			if typeof(g) == "table" then
				g = g.Instance
			end
			if typeof(g) == "Instance" and g:IsA("GuiObject") and g.Visible then
				bottom = math.max(bottom, g.AbsolutePosition.Y + g.AbsoluteSize.Y)
			end
		end
	end
	return bottom
end

-- The ultimate button's spot (root pixels, anchor 1,1) and the side its neighbours (the
-- TEAM combo button) go: above JUMP on PC / portrait / tablets; LEFT of JUMP on landscape
-- phones (above it there is the minimap and the badge row); right of it for left-handed.
local ultAt = UDim2.fromOffset(0, 0)
local ultDir = -1 -- -1: neighbours to the left, 1: to the right
local shownCharge = -1
local calloutRight = 0 -- right edge (root pixels) of the ULT + JUMP pair: the callout lines up with it
local jumpButton: GuiObject? = nil
local nextJumpFind = 0
local function placeUltimate()
	local holder = slots.Ultimate
	local root = holder and holder.Parent :: GuiObject?
	if not holder or not root then
		return
	end
	local origin, size = root.AbsolutePosition, root.AbsoluteSize
	local s = F.UltimateSize
	local margin = Config.Movement.ButtonMargin or 26
	local x, y = size.X - margin, size.Y - (Config.Movement.ButtonSize or 84) - margin - 12
	ultDir = -1
	local now = os.clock()
	if now >= nextJumpFind or (jumpButton and not jumpButton.Parent) then
		nextJumpFind = now + 1
		local pg = player:FindFirstChild("PlayerGui")
		jumpButton = pg and pg:FindFirstChild("JumpButton", true) :: GuiObject?
	end
	local jump = jumpButton
	local jumpGui = jump and jump:FindFirstAncestorOfClass("ScreenGui")
	if jump and jump.Visible and jump.AbsoluteSize.X > 1 and (not jumpGui or jumpGui.Enabled) then
		local jx, jy = jump.AbsolutePosition.X - origin.X, jump.AbsolutePosition.Y - origin.Y
		local jw, jh = jump.AbsoluteSize.X, jump.AbsoluteSize.Y
		local leftSide = jx + jw / 2 < size.X / 2
		if size.X > size.Y and UIKit.IsCompact() then
			-- beside JUMP, bottoms level
			y = jy + jh
			if leftSide then
				x, ultDir = jx + jw + 12 + s, 1
			else
				x = jx - 12
			end
		else
			y = jy - 12
			x = leftSide and (jx + s) or (jx + jw)
			ultDir = leftSide and 1 or -1
		end
	end
	local at = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	ultAt = at
	calloutRight = x
	if jump and jump.Visible and jump.AbsoluteSize.X > 1 then
		calloutRight = math.max(x, jump.AbsolutePosition.X - origin.X + jump.AbsoluteSize.X)
	end
	if holder.Position ~= at then
		holder.Position = at
	end
end

-- Where a neighbour button `size` px wide goes next to the ultimate (anchor 1,1, root
-- pixels of the FeatureHud root): the TEAM combo button uses it.
function FeatureHud.NextToUltimate(size: number): UDim2
	local x = ultAt.X.Offset
	if ultDir < 0 then
		x -= F.UltimateSize + 12
	else
		x += size + 12
	end
	return UDim2.fromOffset(x, ultAt.Y.Offset)
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
	local rowScale = UIKit.new("UIScale", { Scale = 1 }, badgeRow) :: UIScale

	-- announcer / combo line (upper third, centred)
	local announce = UIKit.new("Frame", { Name = "Announcer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.26), Size = UDim2.new(0.9, 0, 0, 40) }, root) :: Frame
	announceLabel = UIKit.text(announce, "Title", "", { Name = "Line", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.35, TextScaled = true, Visible = false }, 26) :: any
	slots.Announcer = announce

	-- ultimate button (touch), beside / above JUMP (placeUltimate)
	local size = F.UltimateSize
	local ult = UIKit.new("Frame", { Name = "Ultimate", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(size, size), Visible = false }, root) :: Frame
	slots.Ultimate = ult
	-- ready halo: a soft gold ring just outside the button (pulses while ready)
	local glow = UIKit.new("Frame", { Name = "Halo", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 10, 1, 10), Visible = false }, ult) :: Frame
	UIKit.corner(glow, 999)
	UIKit.stroke(glow, P.gold_200, 3, 0.25)
	ultGlow = glow
	local button = UIKit.new("TextButton", { Name = "Button", Text = "", AutoButtonColor = true, BackgroundColor3 = P.slate_900, BackgroundTransparency = 0.1, Size = UDim2.fromScale(1, 1) }, ult) :: TextButton
	UIKit.corner(button, 999)
	UIKit.stroke(button, P.gold_400, 2, 0.1)
	ultScale = UIKit.new("UIScale", { Scale = 1 }, ult) :: UIScale
	-- the charge: a round gold fill rising from the bottom (a UIGradient cut-off: Roblox's
	-- ClipsDescendants clips to the square, not the round corners); see-through so the
	-- icon stays readable over it
	local fill = UIKit.new("Frame", { Name = "Charge", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.55, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, button) :: Frame
	UIKit.corner(fill, 999)
	UIKit.new("UIGradient", { Name = "Level", Rotation = -90, Transparency = NumberSequence.new(1) }, fill)
	ultFill = fill
	-- the move's icon (dimmed while charging): a CanvasGroup fades picture and drawing alike
	local iconSize = math.floor(size * 0.46)
	local iconGroup = UIKit.new("CanvasGroup", { Name = "Icon", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.4), Size = UDim2.fromOffset(iconSize, iconSize), GroupTransparency = 0.3, ZIndex = 2 }, button) :: CanvasGroup
	ultIcon = iconGroup
	-- "40%" / "READY" under the icon; its own size cap (the Roblox Text size setting must
	-- not push it out of the round button)
	local label = UIKit.text(button, "Label", "ULT", { Name = "Label", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.66, 0), Size = UDim2.new(0.8, 0, 0.2, 0), TextXAlignment = Enum.TextXAlignment.Center, TextScaled = true, ZIndex = 3, TextStrokeTransparency = 0.5 }, 13) :: TextLabel
	label:SetAttribute("NoTextFit", true)
	UIKit.new("UITextSizeConstraint", { MaxTextSize = UIKit.TS(13), MinTextSize = 8 }, label)
	ultLabel = label
	button.Activated:Connect(function(input: InputObject?)
		-- touches already fired on press (below)
		if input and input.UserInputType == Enum.UserInputType.Touch then
			return
		end
		fireUltimate()
	end)
	-- touch: fire on press, like JUMP (a thumb already holding the stick never delays it)
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			fireUltimate()
		end
	end)
	ultButton = button

	-- first-ready callout: a small dark card above the button (right-aligned with it)
	local note = UIKit.new("Frame", { Name = "UltCallout", BackgroundColor3 = P.slate_900, BackgroundTransparency = 0.1, AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(260, 0), AutomaticSize = Enum.AutomaticSize.Y, Visible = false, Active = false }, root) :: Frame
	UIKit.corner(note, Theme.Radius.M)
	UIKit.stroke(note, P.gold_400, 1.5, 0.2)
	UIKit.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, note)
	local noteText = UIKit.text(note, "Label", "", { Name = "Text", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = P.ivory_100 }, 14) :: TextLabel
	noteText:SetAttribute("NoTextFit", true)
	UIKit.new("UITextSizeConstraint", { MaxTextSize = UIKit.TS(14), MinTextSize = 10 }, noteText)
	callout, calloutLabel = note, noteText

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
		-- hidden under ANY shown panel, not only the covering ones: the run menu drawer leaves
		-- the HUD in view, and the ULT button drew on top of it (owner's iPhone, 2026-10-06)
		local on = inRun() and not UIState.Covered() and UIState.Owner() == nil
		setVisible(on)
		if screen.Enabled ~= on then
			screen.Enabled = on
			layoutDirty = true
		end
		if not on then
			return
		end
		local now = os.clock()
		local doLayout = layoutDirty or now >= nextLayout
		-- (the announcer line hides on time even between layout passes)
		local doAnnounce = announceLabel ~= nil and announceLabel.Visible and now >= announceUntil
		if doLayout or doAnnounce then
			layoutDirty = false
			nextLayout = now + LAYOUT_EVERY
			-- badges: right-aligned inside the safe area (root), under the counters and clear
			-- of the minimap, team rows and tip card; the row shrinks before badges are dropped
			applyCap()
			local origin, rootSize = root.AbsolutePosition, root.AbsoluteSize
			local w = rootSize.X
			local margin = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
			local scale = rowScale.Scale
			local natural = badgeRow.AbsoluteSize.X / math.max(scale, 0.01)
			local maxW = math.max(80, (UIKit.IsCompact() and w * 0.62 or w * 0.45) - margin)
			local fit = math.clamp(maxW / math.max(natural, 1), F.BadgeMinScale or 0.7, 1)
			if math.abs(fit - scale) > 0.01 then
				rowScale.Scale = fit
				scale = fit
			end
			local rw, rh = natural * scale, F.BadgeSize * scale
			local right = origin.X + w - margin
			local top = math.max(topRightBottom() + 8, origin.Y + 8)
			local y = top
			if natural > 1 then
				local rects = obstacles(playerGui)
				-- drops `y` under every rect the row at (rx, y) would touch; nil = no room left
				local function settle(rx: number, y0: number): number?
					local yy = y0
					for _ = 1, 8 do
						local moved = false
						for _, r in ipairs(rects) do
							if r.Max.X > rx - rw - 6 and r.Min.X < rx + 6 and r.Max.Y > yy - 4 and r.Min.Y < yy + rh + 4 then
								yy = r.Max.Y + 8
								moved = true
							end
						end
						if not moved then
							return yy + rh <= origin.Y + rootSize.Y * 0.75 and yy or nil
						end
					end
					return nil
				end
				local found = settle(right, top)
				if not found then
					-- the right column is full (team rows, minimap, tip card): sit at the top,
					-- left of whatever fills the column under the counters
					local colLeft = right
					for _, r in ipairs(rects) do
						if r.Max.X > right - rw - 6 and r.Min.Y >= top - 4 and r.Min.Y < top + 3 * rh then
							colLeft = math.min(colLeft, r.Min.X)
						end
					end
					if colLeft - 8 - rw > origin.X + margin then
						found = settle(colLeft - 8, top)
						if found then
							right = colLeft - 8
						end
					end
				end
				y = found or top
			end
			local at = UDim2.fromOffset(math.floor(right - origin.X + 0.5), math.floor(y - origin.Y + 0.5))
			if badgeRow.Position ~= at then
				badgeRow.Position = at
			end
			local line = announceLabel
			if line then
				local show = line.Text ~= "" and now < announceUntil
				if line.Visible ~= show then
					line.Visible = show
				end
				if show then
					-- the upper third, but under the HUD's top cluster (timer, objective, boss
					-- bar; portrait: vitals and abilities) and the portrait minimap
					local holder = slots.Announcer
					local ah = 40
					local aw = math.floor(rootSize.X * 0.9)
					local ay = origin.Y + rootSize.Y * 0.26 - ah / 2
					local rects = {}
					refreshFinds(playerGui)
					local els = elementsOf("Hud")
					if els then
						for _, key in ipairs({ "TimerPill", "Stage", "Plate", "Boss", "Bar" }) do
							addRect(rects, els[key])
						end
					end
					if natural > 1 then
						addRect(rects, badgeRow) -- the feature badges (placed above, this frame)
					end
					local map = {}
					addRect(map, cachedFinds.MiniMap)
					local mapRect = map[1]
					local left = origin.X + (rootSize.X - aw) / 2
					local edge = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
					for _ = 1, 4 do
						for _, r in ipairs(rects) do
							if r.Max.X > left and r.Min.X < left + aw and r.Max.Y > ay - 2 and r.Min.Y < ay + ah + 2 then
								ay = r.Max.Y + 4
							end
						end
					end
					-- the minimap (portrait: left edge under the cluster): a narrower line beside it
					-- (TextScaled shrinks the words) rather than one over the hero
					if mapRect and mapRect.Max.X > left and mapRect.Min.X < left + aw and mapRect.Max.Y > ay - 2 and mapRect.Min.Y < ay + ah + 2 then
						-- first: a centred line narrowed to clear it; then: beside it; last: under it
						local centre = origin.X + rootSize.X / 2
						local half = mapRect.Min.X > centre and (mapRect.Min.X - 8 - centre) or (centre - mapRect.Max.X - 8)
						local room = origin.X + rootSize.X - edge - (mapRect.Max.X + 8)
						if half * 2 >= 240 then
							aw = math.floor(math.min(aw, half * 2))
							left = centre - aw / 2
							for _, r in ipairs(rects) do
								if r.Max.X > left and r.Min.X < left + aw and r.Max.Y > ay - 2 and r.Min.Y < ay + ah + 2 then
									ay = r.Max.Y + 4
								end
							end
						elseif room >= 170 then
							left = mapRect.Max.X + 8
							aw = math.floor(room)
							ah = 30
							-- and under whatever else sits in that band (the badge row)
							for _ = 1, 2 do
								for _, r in ipairs(rects) do
									if r.Max.X > left and r.Min.X < left + aw and r.Max.Y > ay - 2 and r.Min.Y < ay + ah + 2 then
										ay = r.Max.Y + 4
									end
								end
							end
						else
							ay = mapRect.Max.Y + 4
						end
					end
					ay = math.min(ay, origin.Y + rootSize.Y * 0.6)
					local size = UDim2.fromOffset(aw, ah)
					if holder.Size ~= size then
						holder.Size = size
					end
					local want = UDim2.fromOffset(math.floor(left - origin.X + aw / 2), math.floor(ay - origin.Y + ah / 2))
					if holder.Position ~= want then
						holder.Position = want
					end
				end
			end
			placeUltimate()
		end
		-- ultimate: shown while a feature set it, the player is alive and on touch screens
		-- (keyboard / gamepad players use the key; the button still shows the charge on PC)
		local u = ultimate
		local showUlt = u ~= nil and player:GetAttribute("Alive") == true
		if ult.Visible ~= showUlt then
			ult.Visible = showUlt
			placeUltimate()
		end
		if showUlt and u then
			local charge = math.clamp(u.Charge or 0, 0, 1)
			local ready = charge >= 0.999
			local fill = ultFill :: Frame
			if math.abs(charge - shownCharge) > 0.004 then
				shownCharge = charge
				local grad = fill:FindFirstChild("Level") :: UIGradient?
				if grad then
					-- gold up to `charge` (from the bottom), clear above it; none once ready
					-- (the whole face turns gold instead)
					if charge <= 0.001 or ready then
						grad.Transparency = NumberSequence.new(1)
					else
						grad.Transparency = NumberSequence.new({
							NumberSequenceKeypoint.new(0, 0),
							NumberSequenceKeypoint.new(charge, 0),
							NumberSequenceKeypoint.new(math.min(charge + 0.001, 0.999), 1),
							NumberSequenceKeypoint.new(1, 1),
						})
					end
				end
			end
			local label = ultLabel :: TextLabel
			local text = ready and "READY" or string.format("%d%%", math.floor(charge * 100))
			if label.Text ~= text then
				label.Text = text
			end
			local iconKey = u.Icon or "sparkle"
			local group = ultIcon :: CanvasGroup
			if ultIconKey ~= iconKey then
				ultIconKey = iconKey
				group:ClearAllChildren()
				Icons.Draw(group, iconKey, { Size = group.Size.X.Offset, Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5) })
			end
			if ultReady ~= ready then
				ultReady = ready
				local b = ultButton :: TextButton
				b.BackgroundColor3 = ready and P.gold_400 or P.slate_900
				b.BackgroundTransparency = ready and 0 or 0.1
				group.GroupTransparency = ready and 0 or 0.3
				label.TextColor3 = ready and P.slate_950 or P.ivory_200
				label.TextStrokeTransparency = ready and 1 or 0.5
				local stroke = b:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Color = ready and P.ivory_100 or P.gold_400
					stroke.Thickness = ready and 3 or 2
				end
				;(ultGlow :: Frame).Visible = ready
				if not ready then
					(ultScale :: UIScale).Scale = 1
				end
			end
			if ready then
				-- a gentle pulse (1.0 - 1.06) and a breathing halo; still with Reduced effects
				local reduced = ClientSettings.Reduced()
				local wave = reduced and 0 or (0.5 + 0.5 * math.sin(now * 5))
				local sc = math.floor((1 + 0.06 * wave) * 100 + 0.5) / 100
				local us = ultScale :: UIScale
				if us.Scale ~= sc then
					us.Scale = sc
				end
				local st = (ultGlow :: Frame):FindFirstChildOfClass("UIStroke")
				local tr = math.floor((0.15 + 0.5 * (1 - wave)) * 20 + 0.5) / 20
				if st and st.Transparency ~= tr then
					st.Transparency = tr
				end
			end
		end
		-- first-ready callout: above the ultimate button, right edges level, inside the screen
		local note = callout
		if note then
			local showNote = showUlt and calloutUntil > now and (calloutLabel :: TextLabel).Text ~= ""
			if note.Visible ~= showNote then
				note.Visible = showNote
			end
			if showNote then
				local rs = root.AbsoluteSize
				local w = math.min(260, rs.X - 24)
				local x = math.max(calloutRight, w + 12)
				x = math.min(x, rs.X - 12)
				local y = ultAt.Y.Offset - F.UltimateSize - 14
				local want = UDim2.fromOffset(x, y)
				if note.Position ~= want then
					note.Position = want
				end
				local sz = UDim2.fromOffset(w, 0)
				if note.Size ~= sz then
					note.Size = sz
				end
			end
		end
		local wheelOn = pingOpen
		if wheel.Visible ~= wheelOn then
			wheel.Visible = wheelOn
		end
	end)
end

return FeatureHud
