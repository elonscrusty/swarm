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

	[stream F, continuation brief] On the authored Cliffwood map (arena ground tagged NavGround) the
	map is a north-up drawing of the ground the team has revealed (MapReveal: a heightless top-down
	grid, everything within 80 studs of any teammate, shared by position, reset between runs): the
	player's heading arrow, teammate markers, DISCOVERED chests only (a chest whose ground is still
	unknown is not drawn) and the objective marker (BeaconPos while the beacon is live, else the
	portal). A MAP button beside the panel (and the M key) opens the big map (BigMap) while the run
	stays live. Older arenas keep the obstacle silhouette and the loot-in-range markers.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local UserInputService = game:GetService("UserInputService")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local UIKit = require(script.Parent.UIKit)
local Hud = require(script.Parent.Hud)
local ClientSettings = require(script.Parent.ClientSettings)
local Accessibility = require(script.Parent.Accessibility)
local AffixIcons = require(script.Parent.AffixIcons) -- EnemyBodies: the cached enemy pool list
-- [stream F]
local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local RunClientFolder = script.Parent.Parent:WaitForChild("SwarmV2Client"):WaitForChild("Run")
local K = require(RunClientFolder:WaitForChild("RunTheme"))
local RunWidgets = require(RunClientFolder:WaitForChild("RunWidgets"))
local MapReveal = require(RunClientFolder:WaitForChild("MapReveal"))
local BigMap = require(RunClientFolder:WaitForChild("BigMap"))
local RunUI = RunConfig.UI

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
local arenaSize: number = ARENA_SIZE -- studs across the drawn map (the mapped ground on Cliffwood)
local BTN_GAP = 6
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
local revealAt = 0
local revealModel = nil -- the arena model MapReveal was loaded for
local canvas = nil -- MapReveal canvas over the world frame
local discoveredLoot: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local findAt = 0
local foundModel = nil

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
	UIKit.stroke(pin.Arrow, K.Navy, 1, 0.2)
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
			new("Frame", { Name = "Grid", AnchorPoint = Vector2.new(0.5, 0.5), Position = vertical and UDim2.fromScale(i / 4, 0.5) or UDim2.fromScale(0.5, i / 4), Size = vertical and UDim2.new(0, 1, 1, 0) or UDim2.new(1, 0, 0, 1), BackgroundColor3 = K.NavyEdge, BackgroundTransparency = i == 2 and 0.5 or 0.7, BorderSizePixel = 0, ZIndex = 2 }, world)
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
	local nose = new("Frame", { Name = "Heading", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -3), Size = UDim2.fromOffset(7, 7), Rotation = 45, BackgroundColor3 = K.Gold, BorderSizePixel = 0, ZIndex = 20 }, pivot)
	UIKit.stroke(nose, K.Navy, 1.5, 0)
	local body = new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 1), Size = UDim2.fromOffset(9, 9), BackgroundColor3 = K.Gold, BorderSizePixel = 0, ZIndex = 21 }, pivot)
	UIKit.corner(body, 999)
	UIKit.stroke(body, K.Navy, 1.5, 0)
	-- covers the nose's inner stroke so the outline reads as one teardrop
	local fill = new("Frame", { Name = "Fill", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -1), Size = UDim2.fromOffset(5, 5), BackgroundColor3 = K.Gold, BorderSizePixel = 0, ZIndex = 22 }, pivot)
	UIKit.corner(fill, 999)
end

local function buildLegend(face: Frame)
	local legend = new("Frame", { Name = "Legend", BackgroundTransparency = 1, Size = UDim2.new(1, -2 * MAP_INSET, 0, FOOTER_PC), ZIndex = 3 }, face)
	ui.Legend = legend
	local keys = {
		-- the stage's way on is called the PORTAL everywhere (objective panel, edge marker,
		-- banners); its key is the marker's own diamond-in-a-ring
		{ Name = "Portal", Color = K.Gold, Diamond = true, Size = 6, Ring = true },
		{ Name = "Boss", Color = Accessibility.Color(P.crimson_500, "Danger"), Diamond = true, Size = 6 },
		{ Name = "Loot", Color = K.Gold, Size = 5 },
		{ Name = "Ally", Color = K.Cyan, Round = true, Size = 5 },
	}
	-- each cell as wide as its word needs (equal quarters ran "Portal" into the Boss key)
	local weight, total = {}, 0
	for i, entry in ipairs(keys) do
		weight[i] = #entry.Name + (entry.Ring and 4 or 3)
		total += weight[i]
	end
	local at = 0
	for i, entry in ipairs(keys) do
		local cell = new("Frame", { Name = entry.Name, BackgroundTransparency = 1, Position = UDim2.fromScale(at / total, 0), Size = UDim2.fromScale(weight[i] / total, 1), ZIndex = 3 }, legend)
		at += weight[i]
		local marker = new("Frame", { Name = "Key", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 4, 0.5, 0), Size = UDim2.fromOffset(entry.Size, entry.Size), Rotation = entry.Diamond and 45 or 0, BackgroundColor3 = entry.Color, BorderSizePixel = 0, ZIndex = 4 }, cell)
		UIKit.corner(marker, entry.Round and 999 or 1)
		if entry.Ring then
			local ring = new("Frame", { Name = "Ring", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 4, 0.5, 0), Size = UDim2.fromOffset(11, 11), BackgroundTransparency = 1, ZIndex = 4 }, cell)
			UIKit.corner(ring, 999)
			UIKit.stroke(ring, entry.Color, 1, 0.1)
		end
		UIKit.text(cell, "Small", entry.Name, { Position = UDim2.fromOffset(entry.Ring and 13 or 11, 0), Size = UDim2.new(1, -(entry.Ring and 13 or 11), 1, 0), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = K.CreamMuted, ZIndex = 4 }, 10)
	end
end

function MiniMap.Build(root: Frame, k: { [string]: any })
	kit = k
	local holder, face = RunWidgets.Panel(root, { Name = "MiniMap", Radius = K.Radius.Panel, Size = UDim2.fromOffset(SIZE_PC, SIZE_PC + HEADER_PC + FOOTER_PC), ZIndex = Theme.Z.Hud, Visible = false })
	holder.Active = false
	face.Active = false
	ui.Holder, ui.Face = holder, face
	Hud.AvoidInPortrait(holder) -- portrait: the centre banners drop below the map
	-- the clipped viewport (the dark "outside" of the arena), inset so the corners stay clean
	local view = new("Frame", { Name = "View", BackgroundColor3 = K.NavyDeep, BackgroundTransparency = 0, BorderSizePixel = 0, ClipsDescendants = true, Position = UDim2.fromOffset(MAP_INSET, HEADER_PC), Size = UDim2.fromOffset(viewPx, viewPx), ZIndex = 2 }, face)
	UIKit.corner(view, 5)
	UIKit.stroke(view, K.NavyEdge, 1.5, 0)
	ui.View = view
	-- the world: the whole arena at map scale; its stroke is the fence
	local world = new("Frame", { Name = "World", AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = K.NavyRaised, BackgroundTransparency = 0, BorderSizePixel = 0, Size = UDim2.fromOffset(1, 1), ZIndex = 2 }, view)
	ui.WorldStroke = UIKit.stroke(world, K.Cyan, 2, 0.55)
	ui.World = world
	buildMarkers(world)
	buildPins(view)
	buildPlayer(view)
	ui.Title = UIKit.text(face, "Label", "MAP", { Position = UDim2.fromOffset(MAP_INSET + 1, 2), Size = UDim2.new(1, -30, 0, 16), TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = K.CreamMuted, ZIndex = 3 }, 10)
	ui.North = UIKit.text(face, "Label", "N", { Name = "North", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -MAP_INSET, 0, 2), Size = UDim2.fromOffset(14, 16), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = K.Cyan, ZIndex = 3 }, 13)
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
	-- the MAP button beside the panel (touch + mouse); the M key is BigMap's
	local btn = RunWidgets.Button(root, {
		Name = "MapButton",
		Text = "MAP",
		Kind = "Secondary",
		TextSize = 16,
		Size = UDim2.fromOffset(RunUI.Layout.TouchMin, RunUI.Layout.TouchMin),
		ZIndex = Theme.Z.Hud,
		OnClick = function()
			BigMap.Toggle()
		end,
	})
	btn.Instance.Visible = false
	ui.MapButton = btn
	ui.Canvas = MapReveal.NewCanvas(world, scale)
	canvas = ui.Canvas
	BigMap.Build(root, kit)
	BigMap.BossProvider = function()
		return bossBody
	end
	kit.OnRelayout(MiniMap.Layout)
	Hud.OnLayout(function()
		if ui.Holder then
			MiniMap.Place()
		end
	end)
	MiniMap.Layout()
end

------------------------------------------------------------------------------------------
-- Layout / visibility
------------------------------------------------------------------------------------------

-- Where the map sits: the shared run layout (Hud.RunRect "Map": upper right on desktop, 82% / 17%
-- of the safe area on a phone). The panel is followed by the MAP button on its left; both report
-- their size to the layout so the party stack, the touch controls and the equipment keep clear.
local function place()
	local touch = UserInputService.TouchEnabled
	local btnW = touch and Hud.TouchPx() or 40
	local panelW, panelH = ui.Holder.Size.X.Offset, ui.Holder.Size.Y.Offset
	Hud.SetPieceSize("Map", panelW + BTN_GAP + btnW, panelH)
	local r = Hud.RunRect("Map")
	local v: Vector2 = kit.VirtualSize()
	local x, y = v.X - panelW - 16, 90
	if r then
		x, y = r.X + r.W - panelW, r.Y
	end
	local at = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	if ui.Holder.Position ~= at then
		ui.Holder.Position = at
	end
	local b = ui.MapButton.Instance
	b.Size = UDim2.fromOffset(btnW, btnW)
	local bat = UDim2.fromOffset(math.floor(x - BTN_GAP - btnW + 0.5), math.floor(y + 0.5))
	if b.Position ~= bat then
		b.Position = bat
	end
	cramped = false
	MiniMap.Refresh()
end
MiniMap.Place = place

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
		ui.World.Size = UDim2.fromOffset(math.floor(arenaSize * scale + 0.5), math.floor(arenaSize * scale + 0.5))
		if canvas then
			canvas.SetScale(scale)
		end
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
		local on = shown and enabled and not covered and not cramped
		ui.Holder.Visible = on
		if ui.MapButton then
			ui.MapButton.Instance.Visible = on and MapReveal.Loaded()
		end
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
	local half = arenaSize * scale / 2
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
	local runStage = state:GetAttribute("RunStage")
	if type(runStage) == "string" then
		if runStage == "Boss" or runStage == "Defeat" then
			return Accessibility.Color(P.crimson_400, "Danger")
		elseif runStage == "Charge" or runStage == "BeaconAvailable" then
			return Accessibility.Color(P.gold_300, "Loot")
		end
		return P.ivory_100
	end
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
	-- the objective marker: the beacon while the new run flow is on (RunStage), else the portal
	local runStage = state:GetAttribute("RunStage")
	local ppos
	if type(runStage) == "string" then
		ppos = state:GetAttribute("BeaconPos")
	else
		ppos = state:GetAttribute("PortalPos")
	end
	local portalOn = typeof(ppos) == "Vector3"
	-- the legend names the objective marker the way the run does (director run: the beacon)
	local legendCell = ui.Legend and ui.Legend:FindFirstChild("Portal")
	local legendText = legendCell and legendCell:FindFirstChildOfClass("TextLabel")
	local objectiveWord = type(runStage) == "string" and "Beacon" or "Portal"
	if legendText and legendText.Text ~= objectiveWord then
		legendText.Text = objectiveWord
	end
	setVisible(portal.Frame, portalOn)
	if portalOn then
		placePin(portal, ppos.X, ppos.Z, pos.X, pos.Z)
		setPinColor(portal, portalColor(state))
		local reveal = if type(runStage) == "string" then (runStage == "BeaconAvailable" and 1 or 0) else (state:GetAttribute("PortalReveal") or 0)
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
				m.BackgroundTransparency = (p:GetAttribute("Alive") == false or p:GetAttribute("Downed") == true or p:GetAttribute("Eliminated") == true) and 0.55 or 0
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
			local known = true
			if typeof(lpos) == "Vector3" and MapReveal.Loaded() then
				-- the revealed map never shows loot the team has not walked near
				known = discoveredLoot[m] == true or MapReveal.Discovered(lpos.X, lpos.Z)
				if known then
					discoveredLoot[m] = true
				end
			end
			if typeof(lpos) == "Vector3" and known and st ~= "Opened" and st ~= "Spent" and st ~= "Claimed" then
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
	local shownDots = MapReveal.Loaded() and 0 or math.min(count, MAX_ENEMY_DOTS)
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
	MapReveal.Reset()
	table.clear(discoveredLoot)
	arenaModel = nil
	revealModel = nil
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

-- The arena's ground and the team's reveal. Runs every frame in a run whether or not the map is
-- showing (a panel covering the HUD does not stop the team exploring). Returns true while the
-- revealed map is the one being drawn.
local function trackReveal(now: number)
	if now >= findAt or (foundModel and not foundModel.Parent) then
		findAt = now + 0.5
		foundModel = findArena()
	end
	local model = foundModel
	if model ~= revealModel then
		revealModel = model
		if model and MapReveal.Load(model) then
			local cx, cz, size = MapReveal.Bounds()
			arenaCentre = Vector3.new(cx, 0, cz)
			arenaSize = size
			ui.World.BackgroundColor3 = K.NavyDeep
			ui.World.Size = UDim2.fromOffset(math.floor(arenaSize * scale + 0.5), math.floor(arenaSize * scale + 0.5))
			canvas.Clear()
			canvas.SetScale(scale)
			clearChildren(ui.Obstacles)
			clearChildren(ui.Hazards)
			arenaModel = model -- no obstacle silhouette on the revealed map
		else
			arenaSize = ARENA_SIZE
			ui.World.BackgroundColor3 = K.NavyRaised
			ui.World.Size = UDim2.fromOffset(math.floor(arenaSize * scale + 0.5), math.floor(arenaSize * scale + 0.5))
			canvas.Clear()
			arenaModel = nil -- rebuilt below as the older silhouette
		end
	end
	if not MapReveal.Loaded() then
		return false
	end
	MapReveal.Raster()
	if now >= revealAt then
		revealAt = now + 1 / RunUI.Map.RevealHz
		local radius = RunUI.Map.RevealRadius
		for _, p in ipairs(Players:GetPlayers()) do
			if p:GetAttribute("InRun") == true and p:GetAttribute("Eliminated") ~= true then
				local char = p.Character
				local r = char and char.PrimaryPart
				if r then
					MapReveal.RevealAround(r.Position.X, r.Position.Z, radius)
				end
			end
		end
		BigMap.Step()
		canvas.Update(40)
		MapReveal.EndPass()
	end
	return true
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
			BigMap.Close()
		else
			-- a new run starts with an unexplored map (opening or closing a map never resets it)
			MapReveal.ResetKnown()
			table.clear(discoveredLoot)
		end
	end
	if shown then
		trackReveal(os.clock())
		BigMap.Update(dt, state)
	end
	-- off by the setting or under a modal: nothing to draw. (The reveal above still ran.)
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
		if model ~= arenaModel and not MapReveal.Loaded() then
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
