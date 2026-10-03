--[[
	MiniMap.lua
	A small north-up minimap during runs, in the HUD's look (charcoal rounded square, thin
	gold rim), centred on the player:

	  silhouette    the arena fence (the square boundary) and every obstacle collider
	                (workspace.SwarmMap.Arena_<Name>.Obstacles: cylinders as discs, blocks
	                as rectangles) plus the biome hazard pools, built ONCE per arena model
	                into one "World" frame; scrolling the map moves only that frame
	  player        a gold disc with a facing tick at the centre (the root's look direction)
	  teammates     blue dots (dimmed while fallen)
	  portal        a ring in the stage's colour: ivory while dormant / to find, gold while
	                charging, crimson during the boss and the surge, bright gold once open
	  loot          chests (gold squares), shrines (ivory), the altar (amber ring); gone
	                once opened / spent / claimed
	  caravan       the Lost Caravan (workspace.SwarmEvents.Caravan: wood square, gold
	                while it is being defended)
	  boss          a red skull on the live boss (EnemyData IsBoss)
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
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local UIKit = require(script.Parent.UIKit)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local TeamUI = require(script.Parent.TeamUI)
local LootUI = require(script.Parent.LootUI)
local ClientSettings = require(script.Parent.ClientSettings)

local MiniMap = {}

local player = Players.LocalPlayer
local new = UIKit.new
local P = Theme.Palette

local SIZE_PC, SIZE_COMPACT = 150, 112 -- map square (px, design space)
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
local candidates: { BasePart } = {} -- reused per enemy pass

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local function dot(parent: Instance, name: string, size: number, color: Color3, z: number, round: boolean): Frame
	local f = new("Frame", { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(size, size), BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = z, Visible = false }, parent)
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
		ui.Enemies[i] = dot(world, "Enemy", 3, P.crimson_500, 4, true)
		ui.Enemies[i].BackgroundTransparency = 0.35
	end
	ui.Loot = {}
	for i = 1, MAX_LOOT do
		ui.Loot[i] = dot(world, "Loot", 6, P.gold_400, 5, false)
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
	ui.Altar, ui.AltarStroke = ring(world, "Altar", 9, P.amber_300, 5)
	ui.Boss = Icons.Draw(world, "skull", { Name = "Boss", Size = 16, Color = P.crimson_400, Back = P.slate_950, AnchorPoint = Vector2.new(0.5, 0.5), ZIndex = 8 })
	ui.Boss.Visible = false
end

function MiniMap.Build(root: Frame, k: { [string]: any })
	kit = k
	local holder, face = UIKit.Surface(root, { Name = "MiniMap", Transparency = 0.12, Radius = Theme.Radius.M, Edge = P.gold_500, EdgeTransparency = 0.25, Shadow = false, Size = UDim2.fromOffset(SIZE_PC, SIZE_PC), ZIndex = Theme.Z.Hud, Visible = false })
	holder.Active = false
	face.Active = false
	ui.Holder, ui.Face = holder, face
	-- the clipped viewport, inset so the rounded corners stay clean
	local view = new("Frame", { Name = "View", BackgroundTransparency = 1, ClipsDescendants = true, Position = UDim2.fromOffset(3, 3), Size = UDim2.new(1, -6, 1, -6), ZIndex = 2 }, face)
	ui.View = view
	-- the world: the whole arena at map scale; its stroke is the fence
	local world = new("Frame", { Name = "World", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = P.slate_800, BackgroundTransparency = 0.55, BorderSizePixel = 0, Size = UDim2.fromOffset(1, 1), ZIndex = 2 }, view)
	ui.WorldStroke = UIKit.stroke(world, P.gold_400, 1.5, 0.15)
	ui.World = world
	buildMarkers(world)
	-- the player: gold disc + facing tick in a pivot that turns with the heading
	local pivot = new("Frame", { Name = "Player", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1, ZIndex = 9 }, view)
	ui.Player = pivot
	local body = new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = P.gold_300, BorderSizePixel = 0, ZIndex = 9 }, pivot)
	UIKit.corner(body, 999)
	UIKit.stroke(body, P.slate_950, 1.5, 0)
	new("Frame", { Name = "Tick", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 0.5, -4), Size = UDim2.fromOffset(3, 7), BackgroundColor3 = P.gold_200, BorderSizePixel = 0, ZIndex = 10 }, pivot)
	-- "N" in the corner
	UIKit.Role(face, "Label", "N", { Name = "North", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 1), Size = UDim2.fromOffset(16, 12), TextColor3 = P.gold_300, TextTransparency = 0.25, ZIndex = 3 })
	ClientSettings.OnChanged(function(key, value)
		if key == "Minimap" then
			enabled = value ~= false
			MiniMap.Refresh()
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
		local strip = LootUI.Elements().Strip :: Frame?
		if strip and strip.Visible and strip.Size.Y.Offset > 0 and #strip:GetChildren() > 1 then
			y = math.max(y, strip.Position.Y.Offset + strip.Size.Y.Offset + 8)
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
	end
	local at = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	if ui.Holder.Position ~= at then
		ui.Holder.Position = at
	end
end

function MiniMap.Layout()
	if not ui.Holder then
		return
	end
	local compact = UIKit.IsCompact()
	local px = compact and SIZE_COMPACT or SIZE_PC
	if px ~= mapPx or ui.World.Size.X.Offset <= 1 then
		mapPx = px
		scale = (mapPx - 6) / VIEW_STUDS
		ui.Holder.Size = UDim2.fromOffset(mapPx, mapPx)
		ui.World.Size = UDim2.fromOffset(math.floor(ARENA_SIZE * scale + 0.5), math.floor(ARENA_SIZE * scale + 0.5))
		-- the silhouette is drawn at map scale: rebuild it for the new scale
		arenaModel = nil
	end
	place()
end

function MiniMap.Refresh()
	if ui.Holder then
		ui.Holder.Visible = shown and enabled and not covered
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
					local f = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(mx, my), Size = UDim2.fromOffset(d, d), BackgroundColor3 = P.slate_400, BackgroundTransparency = 0.35, BorderSizePixel = 0, ZIndex = 3 }, ui.Obstacles)
					UIKit.corner(f, 999)
				else
					new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(mx, my), Size = UDim2.fromOffset(math.max(2, size.X * scale), math.max(2, size.Z * scale)), BackgroundColor3 = P.slate_400, BackgroundTransparency = 0.35, BorderSizePixel = 0, ZIndex = 3 }, ui.Obstacles)
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

local function updateMoving(state: Configuration, root: BasePart)
	-- scroll the world so the player sits at the centre; turn the player tick
	local pos = root.Position
	local half = (mapPx - 6) / 2
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
		placeAt(ui.Portal, ppos.X, ppos.Z)
		local c = portalColor(state)
		if ui.PortalStroke.Color ~= c then
			ui.PortalStroke.Color = c
			ui.Portal.BackgroundColor3 = c
			ui.PortalCore.BackgroundColor3 = c
		end
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
					f.BackgroundColor3 = shrine and P.ivory_200 or P.gold_400
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
