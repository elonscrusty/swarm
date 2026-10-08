--[[
	MiniMap.lua
	A north-up minimap during runs (the overhead camera is fixed at yaw 0, so map-up is
	screen-up), centred on the player, in a slim HUD panel with the HUD pills' gold edge:

	  field         the arena floor (a lighter square with a faint quarter grid) inside a
	                darker "outside" so the fence reads as the arena's edge, plus every
	                obstacle collider (workspace.SwarmMap.Arena_<Name>.Obstacles) and the
	                biome hazard pools, built ONCE per arena model into one "World" frame
	  player        a gold teardrop pointing along the root's facing, always at the centre
	  portal        the loudest marker: a diamond in a ring in the stage's colour, with a
	                soft breathing halo; ivory while dormant / to find, gold while charging,
	                crimson during the boss and the surge, bright gold once open. Pinned to
	                the map's edge with an outward pointer while out of range, and pinged
	                with expanding rings when revealed (SwarmState PortalReveal)
	  boss          an ivory-edged red diamond on the live boss (EnemyData IsBoss), also
	                pinned to the edge with a pointer, pinged once when it appears
	  caravan       the Lost Caravan (workspace.SwarmEvents.Caravan): wood square, gold
	                edge while defended, pinned to the edge, pinged when the defence starts
	  loot          paid chests (gold squares), free chests (Price 0: white squares), shrines
	                (ivory diamonds), the altar (amber ring),
	                in range only; gone once opened / spent / claimed
	  teammates     blue discs (dimmed while fallen), eased between updates
	  enemies       at most MAX_ENEMY_DOTS faint red dots sampled evenly from the enemies
	                in range (diamonds with a colourblind mode), refreshed at ENEMY_HZ

	Pings and the halo pulse are skipped with Reduced effects. Reads only what the client
	already has (replicated parts / models, SwarmState and player attributes): no remotes.
	Performance: every marker is pooled at Build; per frame only the World scroll, the
	player heading, the three edge pins and up to five teammates move; loot / caravan /
	teammate targets refresh at MOVE_HZ and the enemy pass at ENEMY_HZ.

	Placement (from Hud.Elements()): landscape top right under the gold / kills pills (and
	under the team list when it has rows); portrait at the left edge under the top cluster
	and the items strip, away from the thumbs. Phones draw a slimmer panel with no legend
	(the shapes carry the meaning) and a bigger map in the same footprint. Hidden in the
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
local AffixIcons = require(script.Parent.AffixIcons) -- EnemyBodies: the cached enemy pool list

local MiniMap = {}

local player = Players.LocalPlayer
local new = UIKit.new
local P = Theme.Palette
local C = Theme.Color

local SIZE_PC, SIZE_COMPACT = 180, 128 -- panel width (px, design space)
local MAP_INSET = 7
local HEADER_PC, HEADER_COMPACT, FOOTER_PC = 20, 16, 18
local VIEW_STUDS = 200 -- studs across the map
local MAX_ENEMY_DOTS = 40
-- Each optional location has at most three rune nodes; altar/caravan use separate markers.
local MAX_LOOT = Config.Chests.SmallCount[2] + Config.Chests.LargeCount[2] + Config.Chests.GoldenCount
	+ Config.Shrines.ChanceCount[2] + Config.Shrines.BargainCount + Config.Encounters.Count[2] * 3
local MAX_MATES = 5
local MOVE_HZ, ENEMY_HZ = 10, 8
local PARKED_Y = -100 -- pooled enemy bodies are parked under this height (EnemyRenderer)
local ARENA_SIZE: number = Config.Arenas.Size or 400
local PING_SECONDS = 2.4

local HAZARD_COLOR: { [string]: Color3 } = {
	Mud = P.murk_600,
	Ice = P.ice_300,
	Quicksand = P.sand_400,
	Lava = P.lava_500,
}

type Pin = {
	Frame: Frame,
	Body: Frame,
	BodyStroke: UIStroke,
	Ring: Frame?,
	RingStroke: UIStroke?,
	Halo: UIStroke?,
	Pointer: Frame,
	Arrow: Frame,
	Pings: { { Frame: Frame, Stroke: UIStroke } },
	Size: number,
	PingAt: number,
	Color: Color3?,
}

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local mapPx = SIZE_PC
local viewPx = SIZE_PC - 2 * MAP_INSET -- the square map viewport
local scale = viewPx / VIEW_STUDS -- px per stud
local arenaModel: Instance? = nil
local arenaCentre = Vector3.zero
local moveAt, enemyAt = 0, 0
local shown, covered, enabled = false, false, ClientSettings.Get("Minimap") ~= false
local cramped = false -- phones: no room beside the JUMP button (place)
local candidates: { BasePart } = {} -- reused per enemy pass
local bossBody: BasePart? = nil
local caravanPos: Vector3? = nil
local mateTarget: { Vector2? } = {} -- eased teammate markers (map px inside World)
local mateAt: { Vector2? } = {}
local lastReveal = 0
local lastCaravan: string? = nil

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

-- Hollow ring whose colour is changed through its stroke.
local function ring(parent: Instance, name: string, size: number, color: Color3, z: number): (Frame, UIStroke)
	local f = new("Frame", { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(size, size), BackgroundColor3 = color, BackgroundTransparency = 0.75, BorderSizePixel = 0, ZIndex = z, Visible = false }, parent)
	UIKit.corner(f, 999)
	local s = UIKit.stroke(f, color, 2, 0)
	return f, s
end

--[[
	An edge pin (portal, boss, caravan): a body (diamond or square) that sits on its target
	while it is in range and slides to the map's edge, with an outward pointer, while it is
	not. `ringed` adds the portal's ring and breathing halo. Lives in the View (not the
	World), so it is placed in view pixels every frame.
]]
local function makePin(parent: Instance, name: string, size: number, color: Color3, edge: Color3, diamond: boolean, ringed: boolean, pings: number, z: number): Pin
	local box = size + 18
	local f = new("Frame", { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(box, box), BackgroundTransparency = 1, ZIndex = z, Visible = false }, parent)
	local pin: Pin = { Frame = f } :: any
	pin.Size = size
	pin.PingAt = -math.huge
	local pointer = new("Frame", { Name = "Pointer", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = z, Visible = false }, f)
	pin.Pointer = pointer
	pin.Arrow = new("Frame", { Name = "Arrow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 3), Size = UDim2.fromOffset(7, 7), Rotation = 45, BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = z }, pointer)
	UIKit.stroke(pin.Arrow, C.Text, 1, 0.2)
	if ringed then
		local r, rs = ring(f, "Ring", size + 4, color, z)
		r.Position = UDim2.fromScale(0.5, 0.5)
		r.BackgroundTransparency = 0.8
		r.Visible = true
		pin.Ring, pin.RingStroke = r, rs
		-- the breathing halo: a second, soft stroke on a slightly larger ring
		local h = new("Frame", { Name = "Halo", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size + 8, size + 8), BackgroundTransparency = 1, ZIndex = z }, f)
		UIKit.corner(h, 999)
		pin.Halo = UIKit.stroke(h, color, 2, 0.55)
	end
	local bodySize = diamond and math.floor(size * 0.62 + 0.5) or math.floor(size * 0.75 + 0.5)
	local body = new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(bodySize, bodySize), Rotation = diamond and 45 or 0, BackgroundColor3 = color, BorderSizePixel = 0, ZIndex = z + 1 }, f)
	UIKit.corner(body, 1)
	pin.Body = body
	pin.BodyStroke = UIKit.stroke(body, edge, 1.5, 0)
	pin.Pings = {}
	for i = 1, pings do
		local pf, ps = ring(f, "Ping", size, color, z)
		pf.Position = UDim2.fromScale(0.5, 0.5)
		pf.BackgroundTransparency = 1
		pin.Pings[i] = { Frame = pf, Stroke = ps }
	end
	return pin
end

local function buildMarkers(world: Frame)
	-- a faint quarter grid on the arena floor: shows movement even in an empty field
	for i = 1, 3 do
		for _, vertical in ipairs({ true, false }) do
			new("Frame", { Name = "Grid", AnchorPoint = Vector2.new(0.5, 0.5), Position = vertical and UDim2.fromScale(i / 4, 0.5) or UDim2.fromScale(0.5, i / 4), Size = vertical and UDim2.new(0, 1, 1, 0) or UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.BlueLight, BackgroundTransparency = i == 2 and 0.7 or 0.82, BorderSizePixel = 0, ZIndex = 2 }, world)
		end
	end
	ui.Hazards = new("Frame", { Name = "Hazards", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2 }, world)
	ui.Obstacles = new("Frame", { Name = "Obstacles", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, world)
	ui.Enemies = {}
	for i = 1, MAX_ENEMY_DOTS do
		ui.Enemies[i] = dot(world, "Enemy", 3, P.crimson_400, 4, true)
		ui.Enemies[i].BackgroundTransparency = 0.25
	end
	ui.Loot = {}
	for i = 1, MAX_LOOT do
		ui.Loot[i] = dot(world, "Loot", 6, P.gold_300, 5, false)
		UIKit.corner(ui.Loot[i], 1)
		UIKit.stroke(ui.Loot[i], C.Text, 1, 0)
	end
	ui.Altar, ui.AltarStroke = ring(world, "Altar", 9, P.amber_300, 5)
	ui.Mates = {}
	for i = 1, MAX_MATES do
		local m = dot(world, "Mate", 7, P.ice_300, 7, true)
		UIKit.stroke(m, C.Text, 1, 0)
		ui.Mates[i] = m
	end
end

local function buildPins(view: Frame)
	local pins = new("Frame", { Name = "Pins", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 10 }, view)
	ui.Pins = pins
	ui.CaravanPin = makePin(pins, "Caravan", 9, P.wood_400, P.ivory_300, false, false, 1, 10)
	ui.BossPin = makePin(pins, "Boss", 12, Accessibility.Color(P.crimson_500, "Danger"), P.ivory_100, true, false, 1, 12)
	ui.PortalPin = makePin(pins, "Portal", 12, P.ivory_100, C.Text, true, true, 3, 14)
	-- compatibility names (tests / preview tools)
	ui.Portal, ui.PortalStroke = ui.PortalPin.Frame, ui.PortalPin.RingStroke
	ui.Boss, ui.Caravan = ui.BossPin.Frame, ui.CaravanPin.Frame
	ui.CaravanStroke = ui.CaravanPin.BodyStroke
	ui.Pings = ui.PortalPin.Pings
end

-- The player: a gold teardrop (disc + a diamond nose) in a pivot that turns with the heading.
local function buildPlayer(view: Frame)
	local pivot = new("Frame", { Name = "Player", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1, ZIndex = 20 }, view)
	ui.Player = pivot
	local nose = new("Frame", { Name = "Heading", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -3), Size = UDim2.fromOffset(7, 7), Rotation = 45, BackgroundColor3 = C.PrimaryTop, BorderSizePixel = 0, ZIndex = 20 }, pivot)
	UIKit.stroke(nose, C.Text, 1.5, 0)
	local body = new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 1), Size = UDim2.fromOffset(9, 9), BackgroundColor3 = C.Primary, BorderSizePixel = 0, ZIndex = 21 }, pivot)
	UIKit.corner(body, 999)
	UIKit.stroke(body, C.Text, 1.5, 0)
	-- covers the nose's inner stroke so the outline reads as one teardrop
	local fill = new("Frame", { Name = "Fill", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -1), Size = UDim2.fromOffset(5, 5), BackgroundColor3 = C.Primary, BorderSizePixel = 0, ZIndex = 22 }, pivot)
	UIKit.corner(fill, 999)
end

local function buildLegend(face: Frame)
	local legend = new("Frame", { Name = "Legend", BackgroundTransparency = 1, Size = UDim2.new(1, -2 * MAP_INSET, 0, FOOTER_PC), ZIndex = 3 }, face)
	ui.Legend = legend
	local keys = {
		-- the stage's way on is called the PORTAL everywhere (objective panel, edge marker,
		-- banners); its key is the marker's own diamond-in-a-ring
		{ Name = "Portal", Color = C.Blue, Diamond = true, Size = 6, Ring = true },
		{ Name = "Boss", Color = Accessibility.Color(P.crimson_500, "Danger"), Diamond = true, Size = 6 },
		{ Name = "Loot", Color = C.CoinDeep, Size = 5 },
		{ Name = "Ally", Color = C.BlueLight, Round = true, Size = 5 },
	}
	for i, entry in ipairs(keys) do
		local cell = new("Frame", { Name = entry.Name, BackgroundTransparency = 1, Position = UDim2.fromScale((i - 1) / #keys, 0), Size = UDim2.fromScale(1 / #keys, 1), ZIndex = 3 }, legend)
		local marker = new("Frame", { Name = "Key", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 4, 0.5, 0), Size = UDim2.fromOffset(entry.Size, entry.Size), Rotation = entry.Diamond and 45 or 0, BackgroundColor3 = entry.Color, BorderSizePixel = 0, ZIndex = 4 }, cell)
		UIKit.corner(marker, entry.Round and 999 or 1)
		if entry.Ring then
			local ring = new("Frame", { Name = "Ring", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 4, 0.5, 0), Size = UDim2.fromOffset(11, 11), BackgroundTransparency = 1, ZIndex = 4 }, cell)
			UIKit.corner(ring, 999)
			UIKit.stroke(ring, entry.Color, 1, 0.1)
		end
		UIKit.text(cell, "Small", entry.Name, { Position = UDim2.fromOffset(entry.Ring and 13 or 11, 0), Size = UDim2.new(1, -(entry.Ring and 13 or 11), 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.TextMuted, ZIndex = 4 }, 10)
	end
end

function MiniMap.Build(root: Frame, k: { [string]: any })
	kit = k
	local holder, face = UIKit.Surface(root, { Name = "MiniMap", Radius = Theme.Radius.M, Edge = C.PanelEdge, EdgeThickness = 2, Transparency = 0.04, Shadow = false, Size = UDim2.fromOffset(SIZE_PC, SIZE_PC + HEADER_PC + FOOTER_PC), ZIndex = Theme.Z.Hud, Visible = false })
	holder.Active = false
	face.Active = false
	ui.Holder, ui.Face = holder, face
	Hud.AvoidInPortrait(holder) -- portrait: the centre banners drop below the map
	-- the clipped viewport (the dark "outside" of the arena), inset so the corners stay clean
	local view = new("Frame", { Name = "View", BackgroundColor3 = C.Text, BackgroundTransparency = 0.05, BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.fromOffset(MAP_INSET, HEADER_PC), Size = UDim2.fromOffset(viewPx, viewPx), ZIndex = 2 }, face)
	UIKit.corner(view, 5)
	UIKit.stroke(view, C.BlueDeep, 1.5, 0)
	ui.View = view
	-- the world: the whole arena at map scale; its stroke is the fence
	local world = new("Frame", { Name = "World", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.BlueDeep:Lerp(C.Text, 0.55), BackgroundTransparency = 0.1, BorderSizePixel = 0, Size = UDim2.fromOffset(1, 1), ZIndex = 2 }, view)
	ui.WorldStroke = UIKit.stroke(world, C.BlueLight, 2, 0.35)
	ui.World = world
	buildMarkers(world)
	buildPins(view)
	buildPlayer(view)
	ui.Title = UIKit.text(face, "Label", "MAP", { Position = UDim2.fromOffset(MAP_INSET + 1, 2), Size = UDim2.new(1, -30, 0, 16), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.TextMuted, ZIndex = 3 }, 10)
	ui.North = UIKit.text(face, "Label", "N", { Name = "North", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -MAP_INSET, 0, 2), Size = UDim2.fromOffset(14, 16), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.BlueDeep, ZIndex = 3 }, 13)
	buildLegend(face)
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
			local boss = Accessibility.Color(P.crimson_500, "Danger")
			ui.BossPin.Body.BackgroundColor3 = boss
			ui.BossPin.Arrow.BackgroundColor3 = boss
			ui.PortalPin.Color = nil -- recoloured on the next frame
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
		viewPx = mapPx - 2 * MAP_INSET
		scale = viewPx / VIEW_STUDS
		-- phones: a slim header and no legend (the marker shapes carry the meaning), so the
		-- map itself gets the room
		local header = compact and HEADER_COMPACT or HEADER_PC
		local footer = compact and 0 or FOOTER_PC
		ui.Holder.Size = UDim2.fromOffset(mapPx, header + viewPx + (compact and MAP_INSET or footer + 4))
		ui.View.Position = UDim2.fromOffset(MAP_INSET, header)
		ui.View.Size = UDim2.fromOffset(viewPx, viewPx)
		ui.Legend.Visible = not compact
		ui.Title.Visible = not compact -- too small to read on a phone; the N stays
		ui.Legend.Position = UDim2.fromOffset(MAP_INSET, header + viewPx + 2)
		ui.Title.Position = UDim2.fromOffset(MAP_INSET + 1, compact and 0 or 2)
		ui.North.Position = UDim2.new(1, -MAP_INSET, 0, compact and 0 or 2)
		ui.Title.Size = UDim2.new(1, -30, 0, header - 2)
		ui.North.Size = UDim2.fromOffset(14, header - 2)
		ui.World.Size = UDim2.fromOffset(math.floor(ARENA_SIZE * scale + 0.5), math.floor(ARENA_SIZE * scale + 0.5))
		-- the silhouette is drawn at map scale: rebuild it for the new scale
		arenaModel = nil
		for i = 1, MAX_MATES do
			mateAt[i] = nil
		end
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
					local f = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(mx, my), Size = UDim2.fromOffset(d, d), BackgroundColor3 = P.stone_500, BackgroundTransparency = 0.15, BorderSizePixel = 0, ZIndex = 3 }, ui.Obstacles)
					UIKit.corner(f, 999)
				else
					new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(mx, my), Size = UDim2.fromOffset(math.max(2, size.X * scale), math.max(2, size.Z * scale)), BackgroundColor3 = P.stone_500, BackgroundTransparency = 0.15, BorderSizePixel = 0, ZIndex = 3 }, ui.Obstacles)
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
	local at = UDim2.fromOffset(math.floor(mx + 0.5), math.floor(my + 0.5))
	if f.Position ~= at then
		f.Position = at
	end
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
		return Accessibility.Color(P.crimson_400, "Danger")
	elseif phase == "Open" then
		return Accessibility.Color(P.gold_200, "Loot")
	end
	if (state:GetAttribute("PortalCharge") or 0) > 0 then
		return Accessibility.Color(P.gold_300, "Loot")
	elseif (state:GetAttribute("PortalLockLeft") or 0) > 0 then
		return P.ivory_400
	end
	return P.ivory_100
end

local function setPinColor(pin: Pin, c: Color3)
	if pin.Color == c then
		return
	end
	pin.Color = c
	pin.Body.BackgroundColor3 = c
	pin.Arrow.BackgroundColor3 = c
	if pin.Ring and pin.RingStroke then
		pin.Ring.BackgroundColor3 = c
		pin.RingStroke.Color = c
	end
	if pin.Halo then
		pin.Halo.Color = c
	end
	for _, ping in ipairs(pin.Pings) do
		ping.Stroke.Color = c
	end
end

-- Start a pin's ping (expanding rings); never with Reduced effects.
local function ping(pin: Pin)
	if not ClientSettings.Reduced() then
		pin.PingAt = os.clock()
	end
end

-- The rings, 0.4 s apart, grow from the marker to ~3.5x and fade.
local function updatePings(pin: Pin, now: number)
	local n = #pin.Pings
	local span = PING_SECONDS - 0.4 * (n - 1)
	for i, p in ipairs(pin.Pings) do
		local t = (now - pin.PingAt - (i - 1) * 0.4) / span
		local on = t >= 0 and t <= 1
		setVisible(p.Frame, on)
		if on then
			local d = math.floor(pin.Size + pin.Size * 2.6 * t + 0.5)
			p.Frame.Size = UDim2.fromOffset(d, d)
			p.Stroke.Transparency = t * t
		end
	end
end

--[[
	Places a pin in view pixels: on its target while that is in range, otherwise on the
	map's edge in the target's direction with the pointer showing the way.
]]
local function placePin(pin: Pin, wx: number, wz: number, px: number, pz: number)
	local half = viewPx / 2
	local dx, dz = (wx - px) * scale, (wz - pz) * scale
	local edge = half - pin.Size / 2 - 8
	local m = math.max(math.abs(dx), math.abs(dz))
	local pinned = m > edge
	if pinned then
		dx, dz = dx * edge / m, dz * edge / m
	end
	local at = UDim2.fromOffset(math.floor(half + dx + 0.5), math.floor(half + dz + 0.5))
	if pin.Frame.Position ~= at then
		pin.Frame.Position = at
	end
	setVisible(pin.Pointer, pinned)
	if pinned then
		pin.Pointer.Rotation = math.floor(math.deg(math.atan2(dx, -dz)) + 0.5)
	end
end

-- Every frame: the world scroll, the player heading, the edge pins, the eased teammates.
local function updateFast(state: Configuration, root: BasePart, dt: number, now: number)
	local pos = root.Position
	local half = viewPx / 2
	local at = UDim2.fromOffset(math.floor(half - (pos.X - arenaCentre.X) * scale + 0.5), math.floor(half - (pos.Z - arenaCentre.Z) * scale + 0.5))
	if ui.World.Position ~= at then
		ui.World.Position = at
	end
	local look = root.CFrame.LookVector
	if math.abs(look.X) + math.abs(look.Z) > 0.05 then
		ui.Player.Rotation = math.floor(math.deg(math.atan2(look.X, -look.Z)) + 0.5)
	end
	local calm = ClientSettings.Reduced()

	-- portal
	local portal: Pin = ui.PortalPin
	local ppos = state:GetAttribute("PortalPos")
	local portalOn = typeof(ppos) == "Vector3"
	setVisible(portal.Frame, portalOn)
	if portalOn then
		placePin(portal, ppos.X, ppos.Z, pos.X, pos.Z)
		setPinColor(portal, portalColor(state))
		local reveal = state:GetAttribute("PortalReveal") or 0
		if reveal ~= lastReveal then
			lastReveal = reveal
			if reveal > 0 then
				ping(portal)
			end
		end
		updatePings(portal, now)
		if portal.Halo then
			local t = calm and 0.5 or (math.sin(now * 3.2) + 1) / 2
			portal.Halo.Transparency = 0.35 + 0.45 * t
			portal.Halo.Thickness = calm and 2 or 1.5 + 1.5 * (1 - t)
		end
	end

	-- boss
	local boss: Pin = ui.BossPin
	local b = bossBody
	local bossOn = b ~= nil and b.Parent ~= nil and b.Position.Y > PARKED_Y
	setVisible(boss.Frame, bossOn)
	if bossOn and b then
		placePin(boss, b.Position.X, b.Position.Z, pos.X, pos.Z)
		updatePings(boss, now)
	end

	-- caravan
	local caravan: Pin = ui.CaravanPin
	local cpos = caravanPos
	setVisible(caravan.Frame, cpos ~= nil)
	if cpos then
		placePin(caravan, cpos.X, cpos.Z, pos.X, pos.Z)
		updatePings(caravan, now)
	end

	-- teammates ease toward their last sampled positions
	local k = math.min(1, dt * 14)
	for i = 1, MAX_MATES do
		local target, cur = mateTarget[i], mateAt[i]
		if target then
			cur = cur and cur:Lerp(target, k) or target
			mateAt[i] = cur
			local p = UDim2.fromOffset(math.floor(cur.X + 0.5), math.floor(cur.Y + 0.5))
			local m = ui.Mates[i]
			if m.Position ~= p then
				m.Position = p
			end
		end
	end
end

-- At MOVE_HZ: teammate targets, loot, the altar and the caravan's state.
local function updateSlow()
	-- teammates
	local n = 0
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and p:GetAttribute("InRun") == true and n < MAX_MATES then
			local char = p.Character
			local r = char and char.PrimaryPart
			if r then
				n += 1
				local mx, my = toMap(r.Position.X, r.Position.Z)
				mateTarget[n] = Vector2.new(mx, my)
				local m = ui.Mates[n]
				m.BackgroundTransparency = p:GetAttribute("Alive") == false and 0.55 or 0
				setVisible(m, true)
			end
		end
	end
	for i = n + 1, MAX_MATES do
		mateTarget[i], mateAt[i] = nil, nil
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
					-- paid chests gold squares, free ones (caches, Price 0) ivory squares,
					-- shrines ivory diamonds
					local shrine = kind == "Shrine"
					local paid = not shrine and (tonumber(m:GetAttribute("Price")) or 0) > 0
					local c = if shrine then Accessibility.Color(P.ivory_200, "Neutral") elseif paid then Accessibility.Color(P.gold_400, "Loot") else P.ivory_100
					if f.BackgroundColor3 ~= c then
						f.BackgroundColor3 = c
					end
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

	-- the Lost Caravan (an objective: pinned to the edge, pinged when the defence starts)
	local events = workspace:FindFirstChild("SwarmEvents")
	local caravan = events and events:FindFirstChild("Caravan")
	local cpos = caravan and caravan:GetAttribute("Pos")
	local cst = caravan and caravan:GetAttribute("State")
	local on = typeof(cpos) == "Vector3" and (cst == "Waiting" or cst == "Defending")
	caravanPos = on and cpos or nil
	if on and cst ~= lastCaravan then
		ui.CaravanPin.BodyStroke.Color = cst == "Defending" and P.gold_300 or P.ivory_300
		ui.CaravanPin.BodyStroke.Thickness = cst == "Defending" and 2 or 1.5
		if cst == "Defending" then
			ping(ui.CaravanPin)
		end
	end
	lastCaravan = on and cst or nil
end

-- At ENEMY_HZ: the boss body and an even sample of the enemies in range.
local function updateEnemies(root: BasePart)
	local count = 0
	local boss: BasePart? = nil
	local here = root.Position
	local reach = (viewPx / 2) / scale + 2 -- studs from the player to the view's edge
	for _, body in ipairs(AffixIcons.EnemyBodies()) do
		local pos = body.Position
		if pos.Y > PARKED_Y then
			local typeId = body:GetAttribute("Type")
			local def = type(typeId) == "string" and EnemyData.Enemies[typeId] or nil
			if def and def.IsBoss then
				boss = body
			elseif def and math.abs(pos.X - here.X) < reach and math.abs(pos.Z - here.Z) < reach then
				count += 1
				candidates[count] = body
			end
		end
	end
	if boss ~= bossBody then
		if boss and not bossBody then
			ping(ui.BossPin)
		end
		bossBody = boss
	end
	-- every k-th enemy in range, so the dots follow the swarm's density
	local stride = count / MAX_ENEMY_DOTS
	local shownDots = math.min(count, MAX_ENEMY_DOTS)
	for i = 1, shownDots do
		local body = candidates[math.floor((i - 1) * math.max(1, stride)) + 1]
		local d = ui.Enemies[i]
		placeAt(d, body.Position.X, body.Position.Z)
		setVisible(d, true)
	end
	for j = shownDots + 1, MAX_ENEMY_DOTS do
		setVisible(ui.Enemies[j], false)
	end
	for j = 1, count do
		candidates[j] = nil
	end
end

local function resetRun()
	arenaModel = nil
	lastReveal = 0
	lastCaravan = nil
	bossBody = nil
	caravanPos = nil
	for _, pin in ipairs({ ui.PortalPin, ui.BossPin, ui.CaravanPin }) do
		pin.PingAt = -math.huge
		for _, p in ipairs(pin.Pings) do
			setVisible(p.Frame, false)
		end
	end
	for i = 1, MAX_MATES do
		mateTarget[i], mateAt[i] = nil, nil
	end
end

function MiniMap.Update(dt: number, state: Configuration, inRun: boolean)
	if not ui.Holder then
		return
	end
	if shown ~= inRun then
		shown = inRun
		MiniMap.Refresh()
		if not inRun then
			resetRun()
		end
	end
	-- off by the setting or under a modal: nothing to do. Hidden only because the team rows
	-- pushed it onto the ability panel (cramped): keep placing it, so it comes back as soon
	-- as there is room again (a teammate left, the rows went)
	if not (shown and enabled and not covered) then
		return
	end
	local now = os.clock()
	local root = localRoot()
	if now >= moveAt then
		moveAt = now + 1 / MOVE_HZ
		place()
		if not ui.Holder.Visible then
			return
		end
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
		if root then
			updateSlow()
		end
	end
	if root and ui.Holder.Visible then
		if now >= enemyAt then
			enemyAt = now + 1 / ENEMY_HZ
			updateEnemies(root)
		end
		updateFast(state, root, dt, now)
	end
end

-- For the preview tool / tests.
function MiniMap.Elements(): { [string]: any }
	return ui
end

return MiniMap
