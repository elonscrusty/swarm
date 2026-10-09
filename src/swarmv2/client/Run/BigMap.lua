--!nonstrict
--[[
	SwarmV2/Run/BigMap.lua  (StarterPlayerScripts.SwarmV2Client.Run.BigMap)
	OWNER: stream F (run UI).

	The larger map: M on a keyboard, the MAP button beside the minimap on touch and mouse, and the
	same button on a gamepad focus. It shows what MapReveal knows (the whole revealed ground, north
	up) with the player's heading arrow, the teammates, the DISCOVERED chests and the objective
	(the beacon, else the portal; the boss while it lives).

	It is a HUD-level panel, not a modal: the run keeps going while it is open ("The run continues"
	says so), nothing pauses, and it closes by itself when a panel that owns input opens (level-up,
	run menu, results) or the run ends. Exploration is not touched by opening or closing it
	(MapReveal resets between runs only). Reduced motion: no pop.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local UIKit = require(Client:WaitForChild("UIKit"))
local UIAnim = require(Client:WaitForChild("UIAnim"))
local UIState = require(Client:WaitForChild("UIState"))
local ClientSettings = require(Client:WaitForChild("ClientSettings"))
local RunTheme = require(script.Parent.RunTheme)
local W = require(script.Parent.RunWidgets)
local MapReveal = require(script.Parent.MapReveal)

local BigMap = {}
-- MiniMap sets this: the live boss's body (or nil)
BigMap.BossProvider = nil

local UI = RunConfig.UI
local player = Players.LocalPlayer
local new, corner, stroke = UIKit.new, UIKit.corner, UIKit.stroke

local ui: { [string]: any } = {}
local kit: { [string]: any } = {}
local open = false
local canvas = nil
local scale = 1 -- px per stud
local worldPx = 0
local MAX_MATES, MAX_CHESTS = 5, 40
local markAt = 0
local discovered = setmetatable({}, { __mode = "k" })

local function toMap(wx: number, wz: number): (number, number)
	local cx, cz = MapReveal.Bounds()
	return worldPx / 2 + (wx - cx) * scale, worldPx / 2 + (wz - cz) * scale
end

local function dot(parent: Instance, name: string, d: number, color: Color3, round: boolean, z: number): Frame
	local f = new("Frame", { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(d, d), BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = z, Visible = false, Active = false }, parent)
	if round then
		corner(f, 999)
	end
	stroke(f, RunTheme.Navy, 1.5, 0)
	return f
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

function BigMap.Build(root: Instance, k: any)
	kit = k
	local overlay = new("Frame", { Name = "BigMap", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, Active = false, ZIndex = Theme.Z.Hud + 3 }, root)
	ui.Overlay = overlay
	local holder, face = W.Panel(overlay, { Name = "Panel", ZIndex = Theme.Z.Hud + 3, AnchorPoint = Vector2.new(0.5, 0.5) })
	holder.Active = true -- taps on the open map never walk the hero
	face.Active = true
	ui.Panel, ui.Face = holder, face
	ui.Title = W.Text(face, "MAP", { Name = "Title", Size = RunTheme.Size.Section, Font = "Heading", Position = UDim2.fromOffset(14, 6), Box = UDim2.new(0.4, 0, 0, 34), Fit = 14, Color = RunTheme.Gold })
	ui.Note = W.Text(face, "The run continues while this is open", { Name = "Note", Size = 14, Font = "Label", Color = RunTheme.CreamMuted, Position = UDim2.fromOffset(14, 38), Box = UDim2.new(1, -90, 0, 20), Fit = 10 })
	ui.NorthKey = W.KeyCap(face, UI.Map.BigKey.Name, { Height = 26, Position = UDim2.new(1, -66, 0, 14), AnchorPoint = Vector2.new(1, 0) })
	ui.Close = W.Button(face, {
		Name = "Close",
		Text = "X",
		Kind = "Secondary",
		TextSize = 22,
		Size = UDim2.fromOffset(UI.Layout.TouchMin, UI.Layout.TouchMin),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 6),
		ZIndex = Theme.Z.Hud + 4,
		OnClick = function()
			BigMap.Close()
		end,
	})
	local view = new("Frame", { Name = "View", BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, ClipsDescendants = true, Active = false, ZIndex = Theme.Z.Hud + 3 }, face)
	corner(view, 8)
	stroke(view, RunTheme.NavyEdge, 2, 0)
	ui.View = view
	local world = new("Frame", { Name = "World", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, Size = UDim2.fromOffset(10, 10), ZIndex = Theme.Z.Hud + 3, Active = false }, view)
	ui.World = world
	canvas = MapReveal.NewCanvas(world, 1)
	-- markers
	ui.Chests = {}
	for i = 1, MAX_CHESTS do
		local c = dot(world, "Chest", 10, RunTheme.Gold, false, Theme.Z.Hud + 5)
		ui.Chests[i] = c
	end
	ui.Mates = {}
	for i = 1, MAX_MATES do
		ui.Mates[i] = dot(world, "Mate", 12, RunTheme.Cyan, true, Theme.Z.Hud + 6)
	end
	ui.Objective = new("Frame", { Name = "Objective", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1, Visible = false, ZIndex = Theme.Z.Hud + 7, Active = false }, world)
	local ring = new("Frame", { Name = "Ring", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = Theme.Z.Hud + 7, Active = false }, ui.Objective)
	corner(ring, 999)
	ui.ObjectiveStroke = stroke(ring, RunTheme.Gold, 3, 0)
	ui.ObjectiveBody = new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(12, 12), Rotation = 45, BackgroundColor3 = RunTheme.Gold, BorderSizePixel = 0, ZIndex = Theme.Z.Hud + 8, Active = false }, ui.Objective)
	ui.Boss = dot(world, "Boss", 16, RunTheme.Danger, false, Theme.Z.Hud + 7)
	ui.Boss.Rotation = 45
	-- the player: a gold teardrop turned along the heading
	local pivot = new("Frame", { Name = "Player", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(28, 28), BackgroundTransparency = 1, Visible = false, ZIndex = Theme.Z.Hud + 9, Active = false }, world)
	ui.Player = pivot
	local nose = new("Frame", { Name = "Nose", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -5), Size = UDim2.fromOffset(11, 11), Rotation = 45, BackgroundColor3 = RunTheme.Gold, BorderSizePixel = 0, ZIndex = Theme.Z.Hud + 9, Active = false }, pivot)
	stroke(nose, RunTheme.Navy, 2, 0)
	local body = new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 2), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = RunTheme.Gold, BorderSizePixel = 0, ZIndex = Theme.Z.Hud + 10, Active = false }, pivot)
	corner(body, 999)
	stroke(body, RunTheme.Navy, 2, 0)
	-- north marker + legend (words next to every symbol)
	ui.NorthMark = W.Text(view, "N", { Name = "North", Size = 16, Font = "Number", Align = "Center", Color = RunTheme.Cyan, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4), Box = UDim2.fromOffset(24, 22), ZIndex = Theme.Z.Hud + 11 })
	ui.Legend = new("Frame", { Name = "Legend", BackgroundTransparency = 1, Active = false, ZIndex = Theme.Z.Hud + 3 }, face)
	UIKit.list(ui.Legend, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 14) })
	local keys = { { "You", RunTheme.Gold, true }, { "Team", RunTheme.Cyan, true }, { "Chest", RunTheme.Gold, false }, { "Objective", RunTheme.Gold, false } }
	for i, key in ipairs(keys) do
		local cell = new("Frame", { Name = key[1], BackgroundTransparency = 1, Size = UDim2.fromOffset(#key[1] * 9 + 24, 22), LayoutOrder = i, Active = false }, ui.Legend)
		local sw = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(12, 12), BackgroundColor3 = key[2], BorderSizePixel = 0, Rotation = key[1] == "Objective" and 45 or 0, Active = false }, cell)
		if key[3] then
			corner(sw, 999)
		end
		W.Text(cell, key[1], { Size = 14, Font = "Label", Color = RunTheme.CreamMuted, Position = UDim2.fromOffset(18, 0), Box = UDim2.new(1, -18, 1, 0), Fit = 10 })
	end

	-- M opens / closes it; Escape closes it
	UserInputService.InputBegan:Connect(function(input, processed)
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == UI.Map.BigKey and not processed then
			BigMap.Toggle()
		elseif input.KeyCode == Enum.KeyCode.Escape and open then
			BigMap.Close()
		end
	end)
	kit.OnRelayout(function()
		BigMap.Layout()
	end)
	BigMap.Layout()
end

------------------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------------------

function BigMap.Layout()
	if not ui.Panel then
		return
	end
	local v = kit.VirtualSize()
	local phone = UIKit.IsCompact()
	local margin = phone and UI.Layout.MarginPhone or UI.Layout.MarginDesktop
	local legendH = 30
	local header = 62
	-- the map is square: it takes UI.Map.BigFraction of the short side and what the header + legend leave
	local avail = math.min(v.X - 2 * margin, v.Y - 2 * margin)
	local side = math.floor(math.min(avail, math.min(v.X, v.Y) * UI.Map.BigFraction + header + legendH))
	local viewPx = math.max(120, side - header - legendH - 16)
	local panelW, panelH = viewPx + 24, viewPx + header + legendH + 16
	ui.Panel.Size = UDim2.fromOffset(panelW, panelH)
	ui.Panel.Position = UDim2.fromOffset(math.floor(v.X / 2 + 0.5), math.floor(v.Y / 2 + 0.5))
	ui.View.Position = UDim2.fromOffset(12, header)
	ui.View.Size = UDim2.fromOffset(viewPx, viewPx)
	ui.Legend.Position = UDim2.fromOffset(12, header + viewPx + 8)
	ui.Legend.Size = UDim2.fromOffset(viewPx, legendH)
	local _, _, size = MapReveal.Bounds()
	if size <= 0 then
		size = 1100
	end
	scale = viewPx / size
	worldPx = math.floor(size * scale + 0.5)
	ui.World.Size = UDim2.fromOffset(worldPx, worldPx)
	if canvas then
		canvas.SetScale(scale)
	end
end

------------------------------------------------------------------------------------------
-- Open / close
------------------------------------------------------------------------------------------

function BigMap.IsOpen(): boolean
	return open
end

local function runLive(): boolean
	return player:GetAttribute("InRun") == true and MapReveal.Loaded()
end

function BigMap.Open()
	if open or not runLive() or UIState.Owner() ~= nil then
		return
	end
	open = true
	BigMap.Layout()
	if canvas then
		canvas.Clear()
		canvas.Update(1000)
	end
	ui.Overlay.Visible = true
	if not ClientSettings.Reduced() then
		UIAnim.Pop(ui.Panel, 0, 0.9)
	end
end

local closedAt = -math.huge

-- Closed in the last moment? (Escape closes the map first and must not also open the run menu.)
function BigMap.RecentlyClosed(): boolean
	return os.clock() - closedAt < 0.25
end

function BigMap.Close()
	if not open then
		return
	end
	open = false
	closedAt = os.clock()
	if ui.Overlay then
		ui.Overlay.Visible = false
	end
end

function BigMap.Toggle()
	if open then
		BigMap.Close()
	else
		BigMap.Open()
	end
end

------------------------------------------------------------------------------------------
-- Per pass / per frame
------------------------------------------------------------------------------------------

-- At the minimap's reveal rate: redraw the changed rows of the big map.
function BigMap.Step()
	if open and canvas then
		canvas.Update(80)
	end
end

local function setVis(f: GuiObject, on: boolean)
	if f.Visible ~= on then
		f.Visible = on
	end
end

local function place(f: GuiObject, wx: number, wz: number)
	local x, y = toMap(wx, wz)
	f.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
end

function BigMap.Update(_dt: number, state: Instance)
	if not open then
		return
	end
	if not runLive() or UIState.Owner() ~= nil then
		BigMap.Close()
		return
	end
	local now = os.clock()
	local root = player.Character and player.Character.PrimaryPart
	if root then
		setVis(ui.Player, true)
		place(ui.Player, root.Position.X, root.Position.Z)
		local look = root.CFrame.LookVector
		if math.abs(look.X) + math.abs(look.Z) > 0.05 then
			ui.Player.Rotation = math.floor(math.deg(math.atan2(look.X, -look.Z)) + 0.5)
		end
	else
		setVis(ui.Player, false)
	end
	if now < markAt then
		return
	end
	markAt = now + 0.2
	-- teammates
	local n = 0
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and p:GetAttribute("InRun") == true and n < MAX_MATES then
			local r = p.Character and p.Character.PrimaryPart
			if r then
				n += 1
				place(ui.Mates[n], r.Position.X, r.Position.Z)
				ui.Mates[n].BackgroundTransparency = (p:GetAttribute("Downed") == true or p:GetAttribute("Eliminated") == true or p:GetAttribute("Alive") == false) and 0.55 or 0
				setVis(ui.Mates[n], true)
			end
		end
	end
	for i = n + 1, MAX_MATES do
		setVis(ui.Mates[i], false)
	end
	-- discovered chests (never an undiscovered one)
	local used = 0
	local loot = workspace:FindFirstChild("SwarmLoot")
	if loot then
		for _, m in ipairs(loot:GetChildren()) do
			local lpos, st = m:GetAttribute("Pos"), m:GetAttribute("State")
			if typeof(lpos) == "Vector3" and st ~= "Opened" and st ~= "Spent" and st ~= "Claimed" and used < MAX_CHESTS then
				if discovered[m] or MapReveal.Discovered(lpos.X, lpos.Z) then
					discovered[m] = true
					used += 1
					place(ui.Chests[used], lpos.X, lpos.Z)
					setVis(ui.Chests[used], true)
				end
			end
		end
	end
	for i = used + 1, MAX_CHESTS do
		setVis(ui.Chests[i], false)
	end
	-- the objective: the beacon while the run flow is on, else the portal
	local stage = state:GetAttribute("RunStage")
	local target = type(stage) == "string" and state:GetAttribute("BeaconPos") or (type(stage) ~= "string" and state:GetAttribute("PortalPos") or nil)
	if typeof(target) == "Vector3" then
		place(ui.Objective, target.X, target.Z)
		setVis(ui.Objective, true)
		local color = (stage == "Boss") and RunTheme.Danger or RunTheme.Gold
		ui.ObjectiveStroke.Color = color
		ui.ObjectiveBody.BackgroundColor3 = color
	else
		setVis(ui.Objective, false)
	end
	-- the boss, while its bar is up
	local bossMax = tonumber(state:GetAttribute("BossMaxHP")) or 0
	local body = BigMap.BossProvider and BigMap.BossProvider() or nil
	if bossMax > 0 and body and body.Parent then
		place(ui.Boss, body.Position.X, body.Position.Z)
		setVis(ui.Boss, true)
	else
		setVis(ui.Boss, false)
	end
end

function BigMap.Elements(): { [string]: any }
	return ui
end

return BigMap
