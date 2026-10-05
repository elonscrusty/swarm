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
local FeatureHud = require(script.Parent.FeatureHud)
local TeamPings = require(script.Parent.TeamPings)

local PingWheel = {}

local P = Theme.Palette
local Q = Config.QuickPings
local started = false
local open = false
local highlight = 1
local buttons: { [string]: TextButton } = {}
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
			FeatureHud.Announce("NO CHEST NEARBY", { Seconds = 1.2, Color = P.stone_300 })
		elseif kind == "Portal" then
			FeatureHud.Announce("NO PORTAL YET", { Seconds = 1.2, Color = P.stone_300 })
		end
	end
	PingWheel.SetOpen(false)
	return sent
end

local function paintHighlight()
	for i, kind in ipairs(Q.Order) do
		local b = buttons[kind]
		local stroke = b and b:FindFirstChildOfClass("UIStroke")
		if stroke then
			local want = i == highlight and P.gold_300 or P.gold_400
			local thick = i == highlight and 3 or 1
			if stroke.Color ~= want then stroke.Color = want end
			if stroke.Thickness ~= thick then stroke.Thickness = thick end
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
	-- and a tap outside it closes it
	local dim = UIKit.new("TextButton", {
		Name = "Dim",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = P.slate_950,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(4000, 4000),
		ZIndex = 0,
	}, slot) :: TextButton
	dim.Activated:Connect(function()
		PingWheel.SetOpen(false)
	end)
	local b = Q.ButtonSize
	local radius = size / 2 - b / 2
	local n = #Q.Order
	for i, kind in ipairs(Q.Order) do
		local a = -math.pi / 2 + (i - 1) / n * math.pi * 2
		local emote = Q.Emotes[kind] == true
		local button = UIKit.new("TextButton", {
			Name = kind,
			Text = "",
			AutoButtonColor = true,
			BackgroundColor3 = emote and P.slate_800 or P.slate_900,
			BackgroundTransparency = 0.08,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(size / 2 + math.cos(a) * radius, size / 2 + math.sin(a) * radius),
			Size = UDim2.fromOffset(b, b),
		}, slot) :: TextButton
		UIKit.corner(button, 999)
		UIKit.stroke(button, P.gold_400, 1, 0.2)
		UIKit.text(button, "Label", Q.Labels[kind] or string.upper(kind), {
			Name = "Label",
			Size = UDim2.new(1, -10, 1, -10),
			Position = UDim2.fromOffset(5, 5),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = emote and P.gold_200 or P.stone_100,
		}, 13)
		UIKit.text(button, "Caption", tostring(i), {
			Name = "Key",
			Size = UDim2.fromOffset(16, 14),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 2),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = P.stone_400,
			Visible = not UserInputService.TouchEnabled,
		}, 10)
		button.Activated:Connect(function()
			PingWheel.Send(kind)
		end)
		buttons[kind] = button
	end
	local close = UIKit.new("TextButton", {
		Name = "Close",
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = P.slate_950,
		BackgroundTransparency = 0.1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(52, 52),
	}, slot) :: TextButton
	UIKit.corner(close, 999)
	UIKit.stroke(close, P.stone_400, 1, 0.3)
	UIKit.text(close, "Label", "X", { Name = "Label", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center }, 16)
	close.Activated:Connect(function()
		PingWheel.SetOpen(false)
	end)
	paintHighlight()

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
