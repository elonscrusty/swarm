--[[
	MiniMap.lua
	A north-up minimap during runs: a quiet charcoal field, thin slate frame, compass
	header and a compact landmark key, centred on the player:

	  silhouette    the arena fence (the square boundary) and every obstacle collider
	                (workspace.SwarmMap.Arena_<Name>.Obstacles: cylinders as discs, blocks
	                as rectangles) plus the biome hazard pools, built ONCE per arena model
	                into one "World" frame; scrolling the map moves only that frame
	  player        a gold disc with a facing tick at the centre (the root's look direction)
	  teammates     blue dots (dimmed while fallen)
	  portal        a ring in the stage's colour (clamped to the map's edge while the portal
	                is outside the view, so it is always on the map), pinged with expanding
	                rings when the portal is revealed (SwarmState PortalReveal; not with
	                Reduced effects): ivory while dormant / to find, gold while
	                charging, crimson during the boss and the surge, bright gold once open
	  loot          chests (gold squares), shrines (ivory), the altar (amber ring); gone
	                once opened / spent / claimed
	  caravan       the Lost Caravan (workspace.SwarmEvents.Caravan: wood square, gold
	                while it is being defended)
	  boss          an ivory-edged red diamond on the live boss (EnemyData IsBoss)
	  enemies       at most MAX_ENEMY_DOTS faint red dots sampled from the live swarm
	                (every k-th enemy in range), refreshed at ENEMY_HZ

	Reads only what the client already has: replicated parts and models, SwarmState
	attributes (StagePhase, PortalPos, PortalCharge, PortalLockLeft), player attributes
	(InRun, Alive), loot / caravan model attributes. No remotes, no per-frame instance
	churn: markers are pooled and only repositioned, at a throttled rate.

	Placement (from Hud.Elements()): landscape top right under the gold / kills pills (and
	under the team list when it has rows); portrait at the left edge under the top cluster
	and the items strip, away from the thumbs. Phones draw it smaller. Hidden in the
	lobby, under full-screen overlays (UIBuilder's SetCovered, like the HUD) and with the
	"Minimap" setting (Config.Settings.Defaults.Minimap, pause menu > Comfort). Nothing
	here is Active, so a thumb landing on it still drives the floating thumbstick.
	UIBuilder builds it (MiniMap.Build) and calls MiniMap.Update every frame in a run.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local UserInputService = game:GetService("UserInputService")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local UIKit = require(script.Parent.UIKit)
local Hud = require(script.Parent.Hud)
local TeamUI = require(script.Parent.TeamUI)
local LootUI = require(script.Parent.LootUI)
local ClientSettings = require(script.Parent.ClientSettings)
local Accessibility = require(script.Parent.Accessibility)

local MiniMap = {}

local player = Players.LocalPlayer
local new = UIKit.new
local P = Theme.Palette

local SIZE_PC, SIZE_COMPACT = 150, 112 -- map width (px, design space)
local MAP_INSET, HEADER_H, FOOTER_H = 7, 20, 18
local VIEW_STUDS = 200 -- studs across the map
local MAX_ENEMY_DOTS = 40
-- Each optional location has at most three rune nodes; altar/caravan use separate markers.
local MAX_LOOT = Config.Chests.SmallCount[2] + Config.Chests.LargeCount[2] + Config.Chests.GoldenCount
	+ Config.Shrines.ChanceCount[2] + Config.Shrines.BargainCount + Config.Encounters.Count[2] * 3
local MAX_MATES = 5
local MOVE_HZ, ENEMY_HZ = 10, 5
local PARKED_Y = -100 -- pooled enemy bodies are parked under this height (EnemyRenderer)
local ARENA_SIZE: number = Config.Arenas.Size or 400

local HAZARD_COLOR: { [string]: Color3 } = {
	Mud = P.murk_600,
	Ice = P.ice_300,
	Quicksand = P.sand_400,
	Lava = P.lava_500,
}

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local mapPx = SIZE_PC
local scale = SIZE_PC / VIEW_STUDS -- px per stud
local arenaModel: Instance? = nil
local arenaCentre = Vector3.zero
local moveAt, enemyAt = 0, 0
local shown, covered, enabled = false, false, ClientSettings.Get("Minimap") ~= false
local cramped = false -- phones: no room beside the JUMP button (place)
local candidates: { BasePart } = {} -- reused per enemy pass

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local function dot(parent: Instance, name: string, size: number, color: Color3, z: number, round: boolean): Frame
	color = Accessibility.Color(color, (name == "Enemy" or name == "Boss") and "Danger" or name == "Mate" and "Ally" or name == "Loot" and "Loot" or nil)
	local f = new("Frame", { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(size, size), BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = z, Visible = false }, parent)
	if name == "Enemy" and ClientSettings.Get("Colorblind") ~= "Off" then
		round = false
		f.Rotation = 45
	end
	if round then
		UIKit.corner(f, 999)
	end
	return f
end

-- Hollow ring marker whose colour is changed through its stroke.
local function ring(parent: Instance, name: string, size: number, color: Color3, z: number): (Frame, UIStroke)
	local f = new("Frame", { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(size, size), BackgroundColor3 = color, BackgroundTransparency = 0.75, BorderSizePixel = 0, ZIndex = z, Visible = false }, parent)
	UIKit.corner(f, 999)
	local s = UIKit.stroke(f, color, 2, 0)
	return f, s
end

local function buildMarkers(world: Frame)
	ui.Hazards = new("Frame", { Name = "Hazards", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2 }, world)
	ui.Obstacles = new("Frame", { Name = "Obstacles", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, world)
	ui.Enemies = {}
	for i = 1, MAX_ENEMY_DOTS do
		ui.Enemies[i] = dot(world, "Enemy", 3, P.crimson_400, 4, true)
		ui.Enemies[i].BackgroundTransparency = 0.3
	end
	ui.Loot = {}
	for i = 1, MAX_LOOT do
		ui.Loot[i] = dot(world, "Loot", 6, P.gold_300, 5, false)
		UIKit.corner(ui.Loot[i], 1)
		UIKit.stroke(ui.Loot[i], P.slate_950, 1, 0)
	end
	ui.Mates = {}
	for i = 1, MAX_MATES do
		local m = dot(world, "Mate", 7, P.ice_300, 7, true)
		UIKit.stroke(m, P.slate_950, 1, 0)
		ui.Mates[i] = m
	end
	ui.Caravan = dot(world, "Caravan", 8, P.wood_400, 6, false)
	ui.CaravanStroke = UIKit.stroke(ui.Caravan, P.gold_300, 1.5, 0)
	ui.Portal, ui.PortalStroke = ring(world, "Portal", 11, P.ivory_100, 6)
	ui.PortalCore = dot(ui.Portal, "Core", 3, P.ivory_100, 7, true)
	ui.PortalCore.Position = UDim2.fromScale(0.5, 0.5)
	ui.PortalCore.Visible = true
	-- the reveal ping: three rings that expand from the portal marker (pooled)
	ui.Pings = {}
	for i = 1, 3 do
		local f, st = ring(ui.Portal, "Ping", 11, P.ivory_100, 5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.BackgroundTransparency = 1
		ui.Pings[i] = { Frame = f, Stroke = st }
	end
	ui.Altar, ui.AltarStroke = ring(world, "Altar", 9, P.amber_300, 5)
	ui.Boss = dot(world, "Boss", 11, P.crimson_500, 8, false)
	ui.Boss.Rotation = 45
	UIKit.stroke(ui.Boss, P.ivory_100, 1, 0.15)
	ui.Boss.Visible = false
end

function MiniMap.Build(root: Frame, k: { [string]: any })
	kit = k
	local holder, face = UIKit.Surface(root, { Name = "MiniMap", Transparency = 0.03, Radius = Theme.Radius.M, Edge = P.slate_400, EdgeTransparency = 0.55, Shadow = false, Size = UDim2.fromOffset(SIZE_PC, SIZE_PC + HEADER_H + FOOTER_H), ZIndex = Theme.Z.Hud, Visible = false })
	holder.Active = false
	face.Active = false
	ui.Holder, ui.Face = holder, face
	-- the clipped viewport, inset so the rounded corners stay clean
	local view = new("Frame", { Name = "View", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.08, BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.fromOffset(MAP_INSET, HEADER_H), Size = UDim2.fromOffset(SIZE_PC - 2 * MAP_INSET, SIZE_PC - 2 * MAP_INSET), ZIndex = 2 }, face)
	UIKit.corner(view, 4)
	UIKit.stroke(view, P.slate_500, 1, 0.65)
	ui.View = view
	-- the world: the whole arena at map scale; its stroke is the fence
	local world = new("Frame", { Name = "World", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = P.slate_800, BackgroundTransparency = 0.25, BorderSizePixel = 0, Size = UDim2.fromOffset(1, 1), ZIndex = 2 }, view)
	ui.WorldStroke = UIKit.stroke(world, P.slate_400, 1, 0.3)
	ui.World = world
	buildMarkers(world)
	-- the player: gold disc + facing tick in a pivot that turns with the heading
	local pivot = new("Frame", { Name = "Player", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1, ZIndex = 9 }, view)
	ui.Player = pivot
	local body = new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = P.gold_300, BorderSizePixel = 0, ZIndex = 9 }, pivot)
	UIKit.corner(body, 999)
	UIKit.stroke(body, P.slate_950, 1.5, 0)
	for _, side in ipairs({ -1, 1 }) do
		new("Frame", { Name = "Heading", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, side * 2, 0.5, -7), Size = UDim2.fromOffset(2, 6), Rotation = side * 35, BackgroundColor3 = P.gold_200, BorderSizePixel = 0, ZIndex = 10 }, pivot)
	end
	UIKit.text(face, "Label", "MAP", { Position = UDim2.fromOffset(MAP_INSET + 1, 2), Size = UDim2.new(1, -30, 0, 16), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = P.ivory_400, ZIndex = 3 }, 10)
	UIKit.text(face, "Label", "N", { Name = "North", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -MAP_INSET, 0, 2), Size = UDim2.fromOffset(14, 16), TextColor3 = P.gold_300, ZIndex = 3 }, 11)
	local legend = new("Frame", { Name = "Legend", BackgroundTransparency = 1, Position = UDim2.new(0, MAP_INSET, 1, -FOOTER_H - 2), Size = UDim2.new(1, -2 * MAP_INSET, 0, FOOTER_H), ZIndex = 3 }, face)
	local keys = { { Name = "Loot", Color = P.gold_300 }, { Name = "Exit", Color = P.ivory_100 }, { Name = "Ally", Color = P.ice_300 } }
	for i, entry in ipairs(keys) do
		local cell = new("Frame", { Name = entry.Name, BackgroundTransparency = 1, Position = UDim2.fromScale((i - 1) / 3, 0), Size = UDim2.fromScale(1 / 3, 1) }, legend)
		local marker = i == 2 and ring(cell, "Key", 5, entry.Color, 4) or dot(cell, "Key", 4, entry.Color, 4, i ~= 1)
		marker.Position = UDim2.new(0, 3, 0.5, 0)
		marker.Visible = true
		UIKit.text(cell, "Small", entry.Name, { Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -8, 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = P.ivory_400 }, 9)
	end
	ClientSettings.OnChanged(function(key, value)
		if key == "Minimap" then
			enabled = value ~= false
			MiniMap.Refresh()
		elseif key == "Colorblind" then
			arenaModel = nil
			for _, marker in ipairs(ui.Enemies) do
				marker.BackgroundColor3 = Accessibility.Color(P.crimson_400, "Danger")
				marker.Rotation = value ~= "Off" and 45 or 0
				local corner = marker:FindFirstChildWhichIsA("UICorner")
				if corner then corner.CornerRadius = UDim.new(value ~= "Off" and 0 or 1, 0) end
			end
			for _, marker in ipairs(ui.Mates) do marker.BackgroundColor3 = Accessibility.Color(P.ice_300, "Ally") end
			ui.Boss.BackgroundColor3 = Accessibility.Color(P.crimson_500, "Danger")
		end
	end)
	kit.OnRelayout(MiniMap.Layout)
	MiniMap.Layout()
end

------------------------------------------------------------------------------------------
-- Layout / visibility
------------------------------------------------------------------------------------------

-- Where the map sits (from the HUD's elements; cheap, so the throttled update can
-- follow the team list as rows come and go).
local function place()
	local v: Vector2 = kit.VirtualSize()
	local W = v.X
	local portrait: boolean = kit.IsPortrait()
	local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
	local els = Hud.Elements()
	local x, y
	if portrait then
		-- left edge under the top cluster / ability bar and the items strip (the team list
		-- keeps the right edge)
		x = M
		y = math.max((els.BarBottom or 0), Hud.TopBottom()) + 8
		local loot = LootUI.Elements()
		local strip = loot.Strip :: Frame?
		if strip and strip.Visible and strip.Size.Y.Offset > 0 and #strip:GetChildren() > 1 then
			y = math.max(y, strip.Position.Y.Offset + strip.Size.Y.Offset + 8)
		end
		-- and under the curse / bargain / synergy chips that follow the strip
		for _, key in ipairs({ "Curses", "Bargain", "Synergy" }) do
			local chip = loot[key] :: Frame?
			if chip and chip.Visible then
				y = math.max(y, chip.Position.Y.Offset + chip.Size.Y.Offset + 8)
			end
		end
	else
		x = W - M - mapPx
		local counters = els.Counters :: Frame?
		y = (counters and (counters.Position.Y.Offset + 44) or 70) + 12
		-- under the team rows when there are any
		local team = TeamUI.Elements()
		local list = team.List :: Frame?
		if list and list.Visible then
			local n, h = 0, 0
			for _, r in pairs(team.Rows or {}) do
				n += 1
				h = math.max(h, r.Holder.Size.Y.Offset)
			end
			if n > 0 then
				y = math.max(y, list.Position.Y.Offset + n * (h + 6) + 6)
			end
		end
		-- phones: pushed down by the team rows, the map must not run under the JUMP button
		-- (bottom right, MobileControls); it moves left of the button's column, and if it
		-- then lands on the ability panel it hides until there is room again
		cramped = false
		if UserInputService.TouchEnabled and UIKit.IsCompact() then
			local H = v.Y
			local scale = math.max(0.01, kit.Scale())
			local jumpW = (Config.Movement.ButtonSize or 84) + (Config.Movement.ButtonMargin or 26) / scale + 12
			local jumpTop = H - jumpW
			local mapH = ui.Holder.Size.Y.Offset
			if y + mapH > jumpTop - 8 then
				x = W - M - jumpW - mapPx
				local bar = els.Bar :: Frame?
				if bar and els.BarTop and y + mapH > els.BarTop - 4 then
					local barRight = bar.Position.X.Offset + (1 - bar.AnchorPoint.X) * bar.Size.X.Offset
					if x < barRight then
						cramped = true
					end
				end
			end
		end
	end
	local at = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	if ui.Holder.Position ~= at then
		ui.Holder.Position = at
	end
	MiniMap.Refresh()
end

function MiniMap.Layout()
	if not ui.Holder then
		return
	end
	local compact = UIKit.IsCompact()
	local px = compact and SIZE_COMPACT or SIZE_PC
	if px ~= mapPx or ui.World.Size.X.Offset <= 1 then
		mapPx = px
			scale = (mapPx - 2 * MAP_INSET) / VIEW_STUDS
			ui.Holder.Size = UDim2.fromOffset(mapPx, mapPx - 2 * MAP_INSET + HEADER_H + FOOTER_H + 4)
			ui.View.Size = UDim2.fromOffset(mapPx - 2 * MAP_INSET, mapPx - 2 * MAP_INSET)
		ui.World.Size = UDim2.fromOffset(math.floor(ARENA_SIZE * scale + 0.5), math.floor(ARENA_SIZE * scale + 0.5))
		-- the silhouette is drawn at map scale: rebuild it for the new scale
		arenaModel = nil
	end
	place()
end

function MiniMap.Refresh()
	if ui.Holder then
		ui.Holder.Visible = shown and enabled and not covered and not cramped
	end
end

-- Hidden under full-screen modals (level-up, chest reel, pause, revive, results).
function MiniMap.SetCovered(on: boolean)
	covered = on
	MiniMap.Refresh()
end

------------------------------------------------------------------------------------------
-- The arena silhouette (once per arena model)
------------------------------------------------------------------------------------------

local function clearChildren(f: Instance)
	for _, ch in ipairs(f:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
end

-- Map pixel offset (inside the World frame) of a world x / z.
local function toMap(wx: number, wz: number): (number, number)
	local half = ARENA_SIZE * scale / 2
	return half + (wx - arenaCentre.X) * scale, half + (wz - arenaCentre.Z) * scale
end

local function findArena(): Instance?
	local map = workspace:FindFirstChild("SwarmMap")
	if not map then
		return nil
	end
	for _, ch in ipairs(map:GetChildren()) do
		if string.sub(ch.Name, 1, 6) == "Arena_" then
			return ch
		end
	end
	return nil
end

local function buildSilhouette(model: Instance)
	clearChildren(ui.Obstacles)
	clearChildren(ui.Hazards)
	arenaCentre = Config.ArenaOrigin
	local obstacles = model:FindFirstChild("Obstacles")
	if obstacles then
		for _, p in ipairs(obstacles:GetChildren()) do
			if p:IsA("BasePart") and p.Name ~= "Boundary" then
				local pos = p.Position
				local mx, my = toMap(pos.X, pos.Z)
				local size = p.Size
				if p:IsA("Part") and p.Shape == Enum.PartType.Cylinder then
					local d = math.max(3, size.Y * scale)
					local f = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(mx, my), Size = UDim2.fromOffset(d, d), BackgroundColor3 = P.slate_500, BackgroundTransparency = 0.25, BorderSizePixel = 0, ZIndex = 3 }, ui.Obstacles)
					UIKit.corner(f, 999)
				else
					new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(mx, my), Size = UDim2.fromOffset(math.max(2, size.X * scale), math.max(2, size.Z * scale)), BackgroundColor3 = P.slate_500, BackgroundTransparency = 0.25, BorderSizePixel = 0, ZIndex = 3 }, ui.Obstacles)
				end
			end
		end
	end
	for _, ch in ipairs(model:GetChildren()) do
		local kind = ch:GetAttribute("HazardKind")
		local r = tonumber(ch:GetAttribute("HazardRadius"))
		if type(kind) == "string" and r and ch:IsA("Model") then
			local pos = ch:GetPivot().Position
			local mx, my = toMap(pos.X, pos.Z)
			local d = math.max(3, r * 2 * scale)
				local f = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(mx, my), Size = UDim2.fromOffset(d, d), BackgroundColor3 = HAZARD_COLOR[kind] or P.slate_500, BackgroundTransparency = 0.45, BorderSizePixel = 0, ZIndex = 2 }, ui.Hazards)
				UIKit.corner(f, 999)
				UIKit.stroke(f, Accessibility.Color(P.amber_300, "Danger"), 1, 0.15)
				UIKit.text(f, "Label", "!", { Size = UDim2.fromScale(1, 1), TextColor3 = P.ivory_100 }, 9)
		end
	end
end

------------------------------------------------------------------------------------------
-- Per update
------------------------------------------------------------------------------------------

local function placeAt(f: GuiObject, wx: number, wz: number)
	local mx, my = toMap(wx, wz)
	f.Position = UDim2.fromOffset(math.floor(mx + 0.5), math.floor(my + 0.5))
end

local function setVisible(f: GuiObject, on: boolean)
	if f.Visible ~= on then
		f.Visible = on
	end
end

local function localRoot(): BasePart?
	local char = player.Character
	return char and char.PrimaryPart or nil
end

local function portalColor(state: Configuration): Color3
	local phase = state:GetAttribute("StagePhase") or "None"
	if phase == "Boss" or phase == "Surge" then
		return P.crimson_400
	elseif phase == "Open" then
		return P.gold_200
	end
	if (state:GetAttribute("PortalCharge") or 0) > 0 then
		return P.gold_300
	elseif (state:GetAttribute("PortalLockLeft") or 0) > 0 then
		return P.ivory_400
	end
	return P.ivory_100
end

local lastReveal = 0
local pingAt = -math.huge
local PING_SECONDS = 2.4

-- The portal reveal ping (three rings, 0.4 s apart, growing to ~40 px and fading).
local function updatePing(now: number, color: Color3)
	local pings = ui.Pings
	if not pings then
		return
	end
	for i, ping in ipairs(pings) do
		local t = (now - pingAt - (i - 1) * 0.4) / (PING_SECONDS - 0.8)
		local on = t >= 0 and t <= 1
		setVisible(ping.Frame, on)
		if on then
			local d = 11 + 34 * t
			ping.Frame.Size = UDim2.fromOffset(d, d)
			ping.Stroke.Color = color
			ping.Stroke.Transparency = t * t
		end
	end
end

local function updateMoving(state: Configuration, root: BasePart)
	-- scroll the world so the player sits at the centre; turn the player tick
	local pos = root.Position
	local half = (mapPx - 2 * MAP_INSET) / 2
	ui.World.Position = UDim2.fromOffset(math.floor(half - (pos.X - arenaCentre.X) * scale + 0.5), math.floor(half - (pos.Z - arenaCentre.Z) * scale + 0.5))
	local look = root.CFrame.LookVector
	if math.abs(look.X) + math.abs(look.Z) > 0.05 then
		ui.Player.Rotation = math.deg(math.atan2(look.X, -look.Z))
	end

	-- portal
	local ppos = state:GetAttribute("PortalPos")
	local portalOn = typeof(ppos) == "Vector3"
	setVisible(ui.Portal, portalOn)
	if portalOn then
		-- outside the view: pinned to the map's edge in the portal's direction
		local dx, dz = (ppos.X - pos.X) * scale, (ppos.Z - pos.Z) * scale
		local edge = half - 7
		local m = math.max(math.abs(dx), math.abs(dz))
		if m > edge then
			dx, dz = dx * edge / m, dz * edge / m
		end
		placeAt(ui.Portal, pos.X + dx / scale, pos.Z + dz / scale)
		local c = Accessibility.Color(portalColor(state), (state:GetAttribute("StagePhase") == "Boss" or state:GetAttribute("StagePhase") == "Surge") and "Danger" or "Loot")
		if ui.PortalStroke.Color ~= c then
			ui.PortalStroke.Color = c
			ui.Portal.BackgroundColor3 = c
			ui.PortalCore.BackgroundColor3 = c
		end
		local reveal = state:GetAttribute("PortalReveal") or 0
		if reveal ~= lastReveal then
			lastReveal = reveal
			if reveal > 0 and not ClientSettings.Reduced() then
				pingAt = os.clock()
			end
		end
		updatePing(os.clock(), c)
	end

	-- teammates
	local n = 0
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and p:GetAttribute("InRun") == true and n < MAX_MATES then
			local char = p.Character
			local r = char and char.PrimaryPart
			if r then
				n += 1
				local m = ui.Mates[n]
				placeAt(m, r.Position.X, r.Position.Z)
				m.BackgroundTransparency = p:GetAttribute("Alive") == false and 0.55 or 0
				setVisible(m, true)
			end
		end
	end
	for i = n + 1, MAX_MATES do
		setVisible(ui.Mates[i], false)
	end

	-- loot (chests, shrines, the altar)
	local used = 0
	local altarOn = false
	local loot = workspace:FindFirstChild("SwarmLoot")
	if loot then
		for _, m in ipairs(loot:GetChildren()) do
			local lpos = m:GetAttribute("Pos")
			local st = m:GetAttribute("State")
			if typeof(lpos) == "Vector3" and st ~= "Opened" and st ~= "Spent" and st ~= "Claimed" then
				local kind = m:GetAttribute("LootKind") or "Chest"
				if kind == "Altar" then
					altarOn = true
					placeAt(ui.Altar, lpos.X, lpos.Z)
				elseif used < MAX_LOOT then
					used += 1
					local f = ui.Loot[used]
					placeAt(f, lpos.X, lpos.Z)
					local shrine = kind == "Shrine"
						f.BackgroundColor3 = Accessibility.Color(shrine and P.ivory_200 or P.gold_400, shrine and "Neutral" or "Loot")
					f.Rotation = shrine and 45 or 0
					setVisible(f, true)
				end
			end
		end
	end
	setVisible(ui.Altar, altarOn)
	for i = used + 1, MAX_LOOT do
		setVisible(ui.Loot[i], false)
	end

	-- the Lost Caravan
	local events = workspace:FindFirstChild("SwarmEvents")
	local caravan = events and events:FindFirstChild("Caravan")
	local cpos = caravan and caravan:GetAttribute("Pos")
	local cst = caravan and caravan:GetAttribute("State")
	local caravanOn = typeof(cpos) == "Vector3" and (cst == "Waiting" or cst == "Defending")
	setVisible(ui.Caravan, caravanOn)
	if caravanOn then
		placeAt(ui.Caravan, cpos.X, cpos.Z)
		ui.CaravanStroke.Color = cst == "Defending" and P.gold_300 or P.ivory_300
	end
end

local function updateEnemies()
	local folder = workspace:FindFirstChild("SwarmEnemies")
	local count = 0
	local bossBody: BasePart? = nil
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			local body = m:FindFirstChild("Body")
			if body and body:IsA("BasePart") then
				local pos = body.Position
				if pos.Y > PARKED_Y then
					local typeId = body:GetAttribute("Type")
					local def = type(typeId) == "string" and EnemyData.Enemies[typeId] or nil
					if def and def.IsBoss then
						bossBody = body
					elseif def then
						count += 1
						candidates[count] = body
					end
				end
			end
		end
	end
	setVisible(ui.Boss, bossBody ~= nil)
	if bossBody then
		placeAt(ui.Boss, bossBody.Position.X, bossBody.Position.Z)
	end
	-- every k-th enemy, so the dots follow the swarm's density
	local stride = math.max(1, math.ceil(count / MAX_ENEMY_DOTS))
	local shownDots = 0
	local i = 1
	while i <= count and shownDots < MAX_ENEMY_DOTS do
		shownDots += 1
		local body = candidates[i]
		local d = ui.Enemies[shownDots]
		placeAt(d, body.Position.X, body.Position.Z)
		setVisible(d, true)
		i += stride
	end
	for j = shownDots + 1, MAX_ENEMY_DOTS do
		setVisible(ui.Enemies[j], false)
	end
	for j = 1, count do
		candidates[j] = nil
	end
end

function MiniMap.Update(_dt: number, state: Configuration, inRun: boolean)
	if not ui.Holder then
		return
	end
	if shown ~= inRun then
		shown = inRun
		MiniMap.Refresh()
		if not inRun then
			arenaModel = nil
			lastReveal = 0
			pingAt = -math.huge
		end
	end
	if not ui.Holder.Visible then
		return
	end
	local now = os.clock()
	if now < moveAt then
		return
	end
	moveAt = now + 1 / MOVE_HZ
	local model = findArena()
	if model ~= arenaModel then
		arenaModel = model
		if model then
			buildSilhouette(model)
		else
			clearChildren(ui.Obstacles)
			clearChildren(ui.Hazards)
		end
	end
	place()
	local root = localRoot()
	if not root then
		return
	end
	updateMoving(state, root)
	if now >= enemyAt then
		enemyAt = now + 1 / ENEMY_HZ
		updateEnemies()
	end
end

-- For the preview tool / tests.
function MiniMap.Elements(): { [string]: any }
	return ui
end

return MiniMap
