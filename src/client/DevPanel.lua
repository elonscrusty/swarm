--[[
	DevPanel.lua
	A small "DEV" button (bottom-left) for testing, shown only in Studio or to the game's
	creator (user-owned games: game.CreatorId). Hidden for everyone else.

	  Lobby:  Start solo now (no countdown)
	  In run: +5 levels, Skip to 14:30 (boss)

	The button is only a shortcut: the server (RunManager "DevCommand") checks Studio /
	creator again and ignores everyone else. Config.Dev.Enabled = false removes it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)

local DevPanel = {}

local player = Players.LocalPlayer
local new, corner, stroke, pad, button = UIKit.new, UIKit.corner, UIKit.stroke, UIKit.pad, UIKit.button

local panel: Frame? = nil
local lobbyButtons: { GuiObject } = {}
local runButtons: { GuiObject } = {}

-- Same rule as the server (RunManager.isDev); the server is the one that decides.
function DevPanel.IsDev(): boolean
	if not Config.Dev.Enabled then
		return false
	end
	if RunService:IsStudio() then
		return true
	end
	return game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
end

local function refresh()
	local inRun = player:GetAttribute("InRun") == true
	for _, b in ipairs(lobbyButtons) do
		b.Visible = not inRun
	end
	for _, b in ipairs(runButtons) do
		b.Visible = inRun
	end
end

local function send(command: string)
	Remotes.Get("DevCommand"):FireServer(command)
	if panel then
		panel.Visible = false
	end
end

function DevPanel.Init(root: Instance)
	if not DevPanel.IsDev() then
		return
	end
	local toggle = button(root, "DEV", Color3.fromRGB(150, 40, 150), function()
		if panel then
			panel.Visible = not panel.Visible
			if panel.Visible then
				refresh()
				UIAnim.Pop(panel, 0, 0.7)
			end
		end
	end, {
		Name = "DevButton",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -8),
		Size = UDim2.fromOffset(64, 48),
		TextSize = 18,
		BackgroundTransparency = 0.25,
		ZIndex = 60,
	})
	stroke(toggle, Color3.fromRGB(255, 160, 255), 2)

	local p = new("Frame", {
		Name = "DevPanel",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -64),
		Size = UDim2.fromOffset(250, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(30, 15, 35),
		BackgroundTransparency = 0.05,
		Visible = false,
		ZIndex = 60,
	}, root)
	corner(p, 12)
	stroke(p, Color3.fromRGB(255, 160, 255), 2)
	pad(p, 8)
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, p)
	UIKit.label(p, "DEV TOOLS (Studio / owner)", 14, { LayoutOrder = 0, TextColor3 = Color3.fromRGB(255, 180, 255), ZIndex = 61 })
	local function item(text: string, command: string, order: number): TextButton
		return button(p, text, Color3.fromRGB(110, 50, 130), function()
			send(command)
		end, { LayoutOrder = order, Size = UDim2.new(1, 0, 0, 48), TextSize = 18, ZIndex = 61 })
	end
	table.insert(lobbyButtons, item("Start solo now", "StartSolo", 1))
	table.insert(runButtons, item("+" .. Config.Dev.AddLevels .. " levels", "AddLevels", 2))
	table.insert(runButtons, item(string.format("Skip to %s (boss)", UIKit.formatTime(Config.Dev.SkipToTime)), "SkipToBoss", 3))
	panel = p
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if panel then
			panel.Visible = false
		end
		refresh()
	end)
	refresh()
end

return DevPanel
