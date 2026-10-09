--[[
	Spectate.lua
	Feature 20, spectate a teammate (Config.Features.Spectate; docs/features/TEAM.md).

	While the local player is down (or out of revives) in a Duo / Trio run, a small bar
	sits in the bottom-left corner (where the PING button is while alive; the move stick
	is gone while down): [<] WATCHING NAME [>] and, while a teammate can still revive you,
	a REVIVE ME button that sends the REVIVE ME ping at your body (TeamPings, server-checked
	and rate-limited like every ping). The arrows (or Left / Right, gamepad DPadLeft /
	DPadRight) move the camera to the previous / next living teammate through
	CameraController.SpectateCycle; G or gamepad DPadUp asks for a revive.

	The camera itself already follows a living teammate while you are down
	(CameraController); this only lets you pick which one. When you are revived it glides
	back to your hero, and when the run ends the lobby camera takes over: nothing here keeps
	any camera state. Hidden while a panel covers the HUD (UIState), outside group runs and
	with the switch off.
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
local CameraController = require(script.Parent.CameraController)
local TeamPings = require(script.Parent.TeamPings)

local Spectate = {}

local player = Players.LocalPlayer
local C = Theme.Color
local S = Config.Spectate
local started = false
local gui: ScreenGui? = nil
local nameLabel: TextLabel? = nil
local reviveButton: TextButton? = nil
local reviveLabel: TextLabel? = nil
local sentUntil = 0
local rowFrame: Frame? = nil

-- Where the [<] NAME [>] row goes: under the HUD timer in landscape, above the REVIVE ME
-- button (bottom-left) in portrait.
local function placeRow(screen: ScreenGui)
	local row = rowFrame
	if not row then
		return
	end
	local cam = workspace.CurrentCamera
	local w = cam and cam.ViewportSize.X or 800
	local h = cam and cam.ViewportSize.Y or 600
	local M = Theme.Layout.Margin
	local pos, anchor
	if w > h then
		local main = player.PlayerGui:FindFirstChild("SwarmUI")
		local timer = main and main:FindFirstChild("TimerPill", true)
		local top = 64
		if timer and timer:IsA("GuiObject") and timer.Visible then
			top = timer.AbsolutePosition.Y + timer.AbsoluteSize.Y + 8 - screen.AbsolutePosition.Y
		end
		pos, anchor = UDim2.new(0.5, 0, 0, math.floor(top)), Vector2.new(0.5, 0)
	else
		pos, anchor = UDim2.new(0, M, 1, -(M + 48 + 10)), Vector2.new(0, 1)
	end
	if row.Position ~= pos then
		row.Position = pos
	end
	if row.AnchorPoint ~= anchor then
		row.AnchorPoint = anchor
	end
end

local function on(): boolean
	return Config.FeatureOn("Spectate")
end

local function inTeamRun(): boolean
	local state = Remotes.State()
	local mode = (Config.Modes :: any)[state:GetAttribute("Mode")]
	return player:GetAttribute("InRun") == true and state:GetAttribute("Phase") == "Running" and type(mode) == "table" and (mode.MaxPlayers or 1) > 1
end

-- True while the spectate bar may show.
function Spectate.Active(): boolean
	return on() and inTeamRun() and player:GetAttribute("Alive") == false and not UIState.Covered()
end

function Spectate.Cycle(step: number): Player?
	if not Spectate.Active() then
		return nil
	end
	return CameraController.SpectateCycle(step)
end

function Spectate.AskRevive(): boolean
	if not Spectate.Active() or os.clock() < sentUntil then
		return false
	end
	local ok = TeamPings.Send("ReviveMe")
	if ok then
		sentUntil = os.clock() + Config.TeamPings.Cooldown
	end
	return ok
end

local function contains(list: { Enum.KeyCode }, key: Enum.KeyCode): boolean
	for _, code in ipairs(list) do
		if code == key then
			return true
		end
	end
	return false
end

local function arrow(parent: Instance, name: string, glyph: string, step: number): TextButton
	local b = UIKit.new("TextButton", {
		Name = name,
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = C.Panel,
		BackgroundTransparency = 0.04,
		Size = UDim2.fromOffset(S.ButtonSize, S.ButtonSize),
		LayoutOrder = step < 0 and 1 or 3,
	}, parent) :: TextButton
	UIKit.corner(b, 999)
	UIKit.stroke(b, C.PanelEdge, 2, 0)
	UIKit.text(b, "Label", glyph, { Name = "Label", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center }, 20)
	b.Activated:Connect(function()
		Spectate.Cycle(step)
	end)
	return b
end

function Spectate.Init()
	if started then
		return
	end
	started = true
	local screen = UIKit.new("ScreenGui", { Name = "Spectate", ResetOnSpawn = false, IgnoreGuiInset = true, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, DisplayOrder = 11, Enabled = false }, player:WaitForChild("PlayerGui")) :: ScreenGui
	gui = screen
	local M = Theme.Layout.Margin
	local size = S.ButtonSize
	local barW = size * 2 + 150 + 16
	-- [<] WATCHING NAME [>]: under the timer in landscape (the status line sits centre-low),
	-- above REVIVE ME in the bottom-left corner in portrait (placed every frame below)
	local row = UIKit.new("Frame", { Name = "Row", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Size = UDim2.fromOffset(barW, size) }, screen)
	rowFrame = row
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) })
	arrow(row, "Prev", "<", -1)
	local pill = UIKit.new("Frame", { Name = "Watching", BackgroundColor3 = C.Panel, BackgroundTransparency = 0.04, Size = UDim2.fromOffset(150, 40), LayoutOrder = 2 }, row)
	UIKit.corner(pill, 999)
	UIKit.stroke(pill, C.PanelEdge, 2, 0)
	nameLabel = UIKit.text(pill, "Label", "", { Name = "Who", Size = UDim2.new(1, -12, 1, 0), Position = UDim2.fromOffset(6, 0), TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd }, 13) :: any
	arrow(row, "Next", ">", 1)
	local revive = UIKit.new("TextButton", {
		Name = "ReviveMe",
		Text = "",
		AutoButtonColor = true,
		BackgroundColor3 = C.Primary,
		BackgroundTransparency = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, M, 1, -M),
		Size = UDim2.fromOffset(150, 48),
	}, screen) :: TextButton
	UIKit.corner(revive, Theme.Radius.M)
	UIKit.stroke(revive, C.PrimaryEdge, 2, 0)
	reviveLabel = UIKit.text(revive, "Label", Config.QuickPings.Labels.ReviveMe or "REVIVE ME", { Name = "Label", Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Text }, 15) :: any
	revive.Activated:Connect(function()
		Spectate.AskRevive()
	end)
	reviveButton = revive

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() or not Spectate.Active() then
			return
		end
		if contains(S.PrevKeys, input.KeyCode) then
			Spectate.Cycle(-1)
		elseif contains(S.NextKeys, input.KeyCode) then
			Spectate.Cycle(1)
		elseif contains(S.ReviveKeys, input.KeyCode) then
			Spectate.AskRevive()
		end
	end)

	RunService.RenderStepped:Connect(function()
		local active = Spectate.Active()
		if screen.Enabled ~= active then
			screen.Enabled = active
		end
		if not active then
			return
		end
		placeRow(screen)
		local watched = CameraController.Spectated()
		local text = watched and ("WATCHING " .. string.upper(watched.DisplayName)) or "NO TEAMMATE UP"
		local label = nameLabel :: TextLabel
		if label.Text ~= text then
			label.Text = text
		end
		local canAsk = TeamPings.CanAskRevive()
		local b = reviveButton :: TextButton
		if b.Visible ~= canAsk then
			b.Visible = canAsk
		end
		local words = os.clock() < sentUntil and "SENT" or (Config.QuickPings.Labels.ReviveMe or "REVIVE ME")
		local rl = reviveLabel :: TextLabel
		if rl.Text ~= words then
			rl.Text = words
		end
	end)
end

function Spectate.Gui(): ScreenGui?
	return gui
end

return Spectate
