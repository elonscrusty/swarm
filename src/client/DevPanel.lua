--[[
	DevPanel.lua
	A small "DEV" button for testing. Shown in Studio only; in live servers only when
	Config.Dev.ShowInLiveGame is on, and then only to the creator of a user-owned game.
	Normal players never see it. Config.Dev.Enabled = false removes it everywhere.

	  Lobby:  Start solo now (no countdown)
	  In run: +5 levels, Spawn portal boss (charges this stage's portal), Teleport to portal

	The button is only a shortcut: the server (RunManager "DevCommand") applies the same
	rule again and ignores everyone else.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)

local DevPanel = {}

local player = Players.LocalPlayer
local P = Theme.Palette

local panel: Frame? = nil
local toggle: GuiObject? = nil
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
	return Config.Dev.ShowInLiveGame == true and game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId
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

function DevPanel.Init(root: Instance, host: { [string]: any }?)
	if not DevPanel.IsDev() then
		return
	end
	local t = UIKit.Button(root, {
		Kind = "Secondary",
		Title = "DEV",
		Name = "DevButton",
		Size = UDim2.fromOffset(88, 48),
		ZIndex = Theme.Z.Dev,
		Align = "Center",
		OnClick = function()
			if panel then
				panel.Visible = not panel.Visible
				if panel.Visible then
					refresh()
					UIAnim.Pop(panel, 0, 0.8)
				end
			end
		end,
	})
	local st = t.Face:FindFirstChildOfClass("UIStroke")
	if st then
		st.Color = P.crimson_400
		st.Transparency = 0.1
	end
	toggle = t.Instance

	local holder, face = UIKit.Surface(root, { Name = "DevPanel", Size = UDim2.fromOffset(260, 0), Visible = false, ZIndex = Theme.Z.Dev, Edge = P.crimson_400, EdgeTransparency = 0.2 })
	holder.AutomaticSize = Enum.AutomaticSize.Y
	face.AutomaticSize = Enum.AutomaticSize.Y
	face.Size = UDim2.fromScale(1, 0)
	UIKit.pad(face, 10)
	UIKit.list(face, { Padding = UDim.new(0, 6) })
	UIKit.text(face, "Caption", UIKit.track("Dev tools · Studio only"), { LayoutOrder = 0, TextColor3 = P.crimson_300 })
	local function item(str: string, command: string, order: number): GuiObject
		return UIKit.Button(face, {
			Title = str,
			Size = UDim2.new(1, 0, 0, 48),
			LayoutOrder = order,
			Shadow = false,
			Align = "Center",
			OnClick = function()
				send(command)
			end,
		}).Instance
	end
	table.insert(lobbyButtons, item("Start solo now", "StartSolo", 1))
	table.insert(runButtons, item("+" .. Config.Dev.AddLevels .. " levels", "AddLevels", 2))
	table.insert(runButtons, item("Spawn portal boss", "SpawnPortalBoss", 3))
	table.insert(runButtons, item("Teleport to portal", "TeleportToPortal", 4))
	panel = holder

	-- bottom right in landscape (clear of the menu columns and the ability bar), left edge
	-- in portrait
	local function layout()
		if not host or not toggle or not panel then
			return
		end
		local v: Vector2 = host.VirtualSize()
		local portrait: boolean = host.IsPortrait()
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		if portrait then
			toggle.AnchorPoint = Vector2.new(0, 0)
			toggle.Position = UDim2.fromOffset(M, math.floor(v.Y * 0.4))
			panel.AnchorPoint = Vector2.new(0, 0)
			panel.Position = UDim2.fromOffset(M, math.floor(v.Y * 0.4) + 56)
		else
			toggle.AnchorPoint = Vector2.new(1, 1)
			toggle.Position = UDim2.fromOffset(v.X - M, v.Y - M)
			panel.AnchorPoint = Vector2.new(1, 1)
			panel.Position = UDim2.fromOffset(v.X - M, v.Y - M - 56)
		end
	end
	if host then
		host.OnRelayout(layout)
		layout()
	end
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if panel then
			panel.Visible = false
		end
		refresh()
	end)
	refresh()
end

return DevPanel
