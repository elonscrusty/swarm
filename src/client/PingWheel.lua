--[[
	PingWheel.lua
	Feature 17, quick pings and emotes (Config.Features.QuickPings; docs/features/TEAM.md).

	Fills the FeatureHud "PingWheel" slot with six preset options on a ring
	(Config.QuickPings.Order): HELP HERE, CHEST HERE, GO PORTAL, ON MY WAY and two emotes
	(HELLO!, NICE!), plus a centre close button. Only presets, no typed text, so nothing
	needs filtering. Every option goes through TeamPings.Send, so the server's rules apply
	(TeamPingService: group run, alive, cooldown, rate limit, server-resolved position).

	Opening: the existing PING button and keyboard G (TeamPings hands its toggle to this
	module while the switch is on), gamepad DPadUp. Keyboard 1-6 send an option while the
	wheel is open; gamepad DPadLeft / DPadRight move the highlight and DPadDown sends it.
	Touch: tap an option. The wheel closes after a send, on death, outside a team run and
	whenever a panel covers the HUD (FeatureHud). With the switch off TeamPings keeps its
	old five-option panel and this module does nothing.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local Icons = require(script.Parent.Icons)
local FeatureHud = require(script.Parent.FeatureHud)
local TeamPings = require(script.Parent.TeamPings)

local PingWheel = {}

local C = Theme.Color
local Q = Config.QuickPings
local started = false
local open = false
local highlight = 1
local buttons: { [string]: TextButton } = {}
local labels: { [string]: TextLabel } = {}
local layoutWheel: () -> () = function() end
local DIGITS = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six }

local function digitOf(key: Enum.KeyCode): number?
	for i, code in ipairs(DIGITS) do
		if code == key then
			return i
		end
	end
	return nil
end

local function on(): boolean
	return Config.FeatureOn("QuickPings")
end

-- The wheel may open: switch on, a team run, alive, not paused (TeamPings' rule).
function PingWheel.Usable(): boolean
	return on() and TeamPings.Usable()
end

function PingWheel.IsOpen(): boolean
	return open
end

function PingWheel.SetOpen(want: boolean)
	open = want == true and PingWheel.Usable()
	FeatureHud.SetPingWheel(open)
	if open then
		layoutWheel()
	end
end

function PingWheel.Toggle()
	PingWheel.SetOpen(not open)
end

-- Sends option `kind` (a Config.QuickPings.Order id). Returns true when it went out.
function PingWheel.Send(kind: string): boolean
	if not table.find(Q.Order, kind) or not PingWheel.Usable() then
		return false
	end
	local sent = TeamPings.Send(kind)
	if not sent then
		if kind == "Loot" then
			FeatureHud.Announce("NO CHEST NEARBY", { Seconds = 1.2, Color = C.TextOnBlue })
		elseif kind == "Portal" then
			FeatureHud.Announce("NO PORTAL YET", { Seconds = 1.2, Color = C.TextOnBlue })
		end
	end
	PingWheel.SetOpen(false)
	return sent
end

-- Icons for the six presets (Icons.Draw names on a UIKit.IconBadge; the labels carry the
-- meaning, the picture helps) and their badge colours (Theme.IconTint)
local ICONS: { [string]: string } = {
	Help = "warning",
	Loot = "chest",
	Portal = "portal",
	OnMyWay = "boot",
	Wave = "people2",
	Cheer = "sparkle",
}
local TINTS: { [string]: Color3 } = {
	Help = Theme.IconTint.Red,
	Loot = Theme.IconTint.Orange,
	Portal = Theme.IconTint.Purple,
	OnMyWay = Theme.IconTint.Blue,
	Wave = Theme.IconTint.Teal,
	Cheer = Theme.IconTint.Green,
}
local DEPTH = 4 -- the dark-blue base under each raised option (px)

local hovered: string? = nil
local faces: { [string]: { Gradient: UIGradient, Stroke: UIStroke } } = {}

-- Lime = the highlighted option (gamepad / first) or the one under the pointer; royal blue
-- rim and white face otherwise. The label is always there too (colour is never the only cue).
local function paintHighlight()
	for i, kind in ipairs(Q.Order) do
		local f = faces[kind]
		if f then
			local sel = i == highlight or hovered == kind
			f.Gradient.Color = sel and Theme.Gradient.Selected or Theme.Gradient.Panel
			local want = sel and C.SelectedEdge or C.Blue
			local thick = sel and 4 or 3
			if f.Stroke.Color ~= want then f.Stroke.Color = want end
			if f.Stroke.Thickness ~= thick then f.Stroke.Thickness = thick end
		end
	end
end

function PingWheel.Init()
	if started then
		return
	end
	started = true
	local slot = FeatureHud.Slot("PingWheel")
	if not slot then
		return
	end
	local size = Q.WheelSize
	slot.Size = UDim2.fromOffset(size, size)
	-- a dimmer behind the options (full screen): the wheel reads as the one thing to answer,
	-- and a tap outside it closes it (nothing is sent). Just dark enough: the HUD stays visible.
	local dim = UIKit.new("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = 0.62,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4000, 4000),
		ZIndex = 0,
	}, slot) :: TextButton
	dim.Activated:Connect(function()
		PingWheel.SetOpen(false)
	end)
	local n = #Q.Order
	local icons: { [string]: GuiObject } = {}
	for i, kind in ipairs(Q.Order) do
		local button = UIKit.new("TextButton", {
			Name = kind,
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(Q.ButtonSize, Q.ButtonSize),
			Selectable = true,
			ZIndex = 2,
		}, slot) :: TextButton
		-- raised arcade face: dark-blue base under a white face with a royal blue rim
		local face, grad, stroke = UIKit.RoundFace(button, Theme.Gradient.Panel, C.Blue, 3, DEPTH)
		faces[kind] = { Gradient = grad, Stroke = stroke }
		local holder = UIKit.new("Frame", { Name = "Icon", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.12, 0), Size = UDim2.fromOffset(28, 28), ZIndex = 4 }, face) :: Frame
		icons[kind] = holder
		-- the label wraps inside its own button (scaled down rather than cut)
		local label = UIKit.text(face, "Label", Q.Labels[kind] or string.upper(kind), {
			Name = "Label",
			AnchorPoint = Vector2.new(0.5, 1),
			Size = UDim2.new(1, -16, 0.4, 0),
			Position = UDim2.new(0.5, 0, 1, -7),
			TextWrapped = true,
			TextScaled = true,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			TextColor3 = C.Text,
			FontFace = Theme.Font.Title,
			ZIndex = 4,
		}, 14)
		label:SetAttribute("NoTextFit", true)
		UIKit.new("UITextSizeConstraint", { MaxTextSize = UIKit.TS(14), MinTextSize = 8 }, label)
		labels[kind] = label
		UIKit.text(face, "Caption", tostring(i), {
			Name = "Key",
			Size = UDim2.fromOffset(16, 14),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 2),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = C.TextFaint,
			Visible = not UserInputService.TouchEnabled,
			ZIndex = 4,
		}, 10)
		button.MouseEnter:Connect(function()
			hovered = kind
			paintHighlight()
		end)
		button.MouseLeave:Connect(function()
			if hovered == kind then
				hovered = nil
				paintHighlight()
			end
		end)
		button.SelectionGained:Connect(function()
			highlight = i
			paintHighlight()
		end)
		button.Activated:Connect(function()
			PingWheel.Send(kind)
		end)
		buttons[kind] = button
	end
	-- the small close control in the middle (sends nothing)
	local close = UIKit.new("TextButton", {
		Name = "Close",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(44, 44),
		Selectable = true,
		ZIndex = 3,
	}, slot) :: TextButton
	local closeFace = UIKit.RoundFace(close, ColorSequence.new(C.BlueDeep, C.Shadow), C.Panel, 2.5, 3)
	Icons.Draw(closeFace, "close", { Name = "Glyph", Size = 20, Color = C.TextOnBlue, Back = C.BlueDeep, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) }).ZIndex = 5
	close.Activated:Connect(function()
		PingWheel.SetOpen(false)
	end)
	paintHighlight()

	--[[
		Fit: the wheel is a ring of six round buttons around the close control, sized to
		the space between the top plate and the ability panel (about 60% of the height);
		on a very short screen (height < 300 or width < 420) it becomes a 3 x 2 grid with the
		close control above it, so nothing leaves the safe area or overlaps.
	]]
	local function setRadius(b: GuiObject, r: UDim)
		for _, part in ipairs({ b:FindFirstChild("Face"), b:FindFirstChild("Base") }) do
			local c = part and part:FindFirstChildOfClass("UICorner")
			if c and c.CornerRadius ~= r then
				c.CornerRadius = r
			end
		end
	end
	layoutWheel = function()
		local root = slot.Parent :: GuiObject?
		local rs = root and root.AbsoluteSize or Vector2.zero
		if rs.X < 50 or rs.Y < 50 then
			return
		end
		local grid = rs.Y < 300 or rs.X < 420
		local btn = Q.ButtonSize
		local grow = 1
		if not grid then
			-- Q.WheelSize on phones; a big screen grows it with its height (to ~42%), so the
			-- options stay readable at desktop size
			local cap = math.max(Q.WheelSize, math.floor(rs.Y * 0.42))
			local side = math.clamp(math.min(cap, rs.Y * 0.6, rs.X * 0.9), 190, cap)
			grow = side / Q.WheelSize
			-- a clear gap between neighbours (six on a ring: neighbour distance = radius)
			btn = math.clamp(math.floor(side * 0.25), 52, math.floor(Q.ButtonSize * math.max(1, grow)))
			local radius = side / 2 - btn / 2
			slot.Size = UDim2.fromOffset(side, side)
			slot.Position = UDim2.fromScale(0.5, 0.47)
			for i, kind in ipairs(Q.Order) do
				local a = -math.pi / 2 + (i - 1) / n * math.pi * 2
				local b = buttons[kind]
				b.Size = UDim2.fromOffset(btn, btn)
				b.Position = UDim2.fromOffset(side / 2 + math.cos(a) * radius, side / 2 + math.sin(a) * radius)
				setRadius(b, UDim.new(0, 999))
			end
			close.AnchorPoint = Vector2.new(0.5, 0.5)
			close.Position = UDim2.fromScale(0.5, 0.5)
			local cs = math.floor(44 * math.max(1, grow))
			close.Size = UDim2.fromOffset(cs, cs)
		else
			local bw = math.floor(math.clamp((rs.X * 0.9 - 16) / 3, 70, 100))
			local bh = math.floor(math.clamp((rs.Y - 90) / 2.4, 52, 64))
			local w, h = bw * 3 + 16, bh * 2 + 8 + 40
			slot.Size = UDim2.fromOffset(w, h)
			slot.Position = UDim2.fromScale(0.5, 0.5)
			for i, kind in ipairs(Q.Order) do
				local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
				local b = buttons[kind]
				b.Size = UDim2.fromOffset(bw, bh)
				b.Position = UDim2.fromOffset(col * (bw + 8) + bw / 2, 40 + row * (bh + 8) + bh / 2)
				setRadius(b, UDim.new(0, Theme.Radius.L))
			end
			close.AnchorPoint = Vector2.new(1, 0)
			close.Position = UDim2.fromOffset(w, 0)
		end
		for kind, holder in pairs(icons) do
			-- the badge shrinks with a shorter button; the label keeps its own room
			local px = grid and 22 or math.clamp(math.floor(btn * 0.4), 20, math.floor(30 * math.max(1, grow)))
			if holder.Size.X.Offset ~= px or not holder:FindFirstChild("IconBadge") then
				holder.Size = UDim2.fromOffset(px, px)
				local old = holder:FindFirstChild("IconBadge")
				if old then
					old:Destroy()
				end
				UIKit.IconBadge(holder, ICONS[kind] or "info", TINTS[kind] or Theme.IconTint.Blue, px, { ZIndex = 4 })
			end
			local top = grid and 5 or math.max(6, math.floor(btn * 0.11))
			holder.Position = UDim2.new(0.5, 0, 0, top)
			-- the label takes the room under the badge (never over it)
			local label = labels[kind]
			if label then
				local bh = grid and buttons[kind].Size.Y.Offset or btn
				local y = top + px + 2
				label.AnchorPoint = Vector2.new(0.5, 0)
				label.Position = UDim2.new(0.5, 0, 0, y)
				label.Size = UDim2.new(1, grid and -10 or -12, 0, math.max(12, bh - y - (grid and 4 or 7)))
				local fit = label:FindFirstChildOfClass("UITextSizeConstraint")
				if fit then
					fit.MaxTextSize = math.floor(UIKit.TS(14) * math.max(1, grow))
				end
			end
		end
	end
	local rootGui = slot.Parent :: GuiObject?
	if rootGui then
		rootGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(layoutWheel)
	end
	layoutWheel()

	-- the PING button and G open the wheel instead of the old panel (switch on only)
	TeamPings.ToggleHook = function()
		PingWheel.Toggle()
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() or not on() then
			return
		end
		local key = input.KeyCode
		if key == Q.PadOpen then
			if PingWheel.Usable() then
				PingWheel.Toggle()
			end
			return
		end
		if not open then
			return
		end
		local digit = digitOf(key)
		if digit and Q.Order[digit] then
			PingWheel.Send(Q.Order[digit])
		elseif key == Q.PadNext or key == Q.PadPrev then
			highlight = (highlight - 1 + (key == Q.PadNext and 1 or -1)) % n + 1
			paintHighlight()
		elseif key == Q.PadSend then
			PingWheel.Send(Q.Order[highlight])
		end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		PingWheel.SetOpen(false)
	end)
	RunService.RenderStepped:Connect(function()
		if open and (not PingWheel.Usable() or not FeatureHud.Visible()) then
			PingWheel.SetOpen(false)
		end
	end)
end

return PingWheel
