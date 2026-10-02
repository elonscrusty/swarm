--[[
	TeamUI.lua
	Duo / Trio on the local client: who is on the team and who needs help.

	  team list     one compact row per teammate (other players in the run): hero icon,
	                name, a bar and a state word (never colour alone):
	                  health bar (crimson)          alive; "CHOOSING" while they pick a card
	                  "DOWN · 12 m" (crimson)       fallen, can be revived
	                  "REVIVING 60%" (gold bar)     someone stands next to them
	                  "DECIDING" (stone)            on the revive-product offer
	                  "OUT" (stone)                 no partner revives left: spectating
	                Landscape: right edge under the kill / gold counters. Portrait: right edge
	                under the ability bar and the items strip. Nothing is Active, so a thumb
	                landing on it still drives the floating thumbstick.
	  revive marker every revivable fallen player (teammates, and yourself) gets a ring of
	                segments over them that fills with ReviveProgress; off screen, a
	                crimson arrow at the screen edge points at a fallen teammate with the
	                distance
	  revive ring   in the world: a dashed gold circle of PartnerRevive.Radius around
	                each revivable fallen player (stand inside it to revive); its segments
	                light up with the progress
	Motion (event-driven, short, off with Reduced effects): a row flashes crimson with a
	punch when its owner goes down, and gold sparks + a green flash when they
	are back up; revive-marker segments pop as they light; the health bar glints when a
	teammate heals.
	Rows appear / disappear with the roster: a teammate who leaves the game is removed at
	once (the server also toasts "<Name> left the run.").

	Reads replicated attributes only: player InRun / Alive / HP / MaxHP / CharacterId /
	ReviveProgress / PartnerRevivesLeft / AwaitingRevive, SwarmState Mode / ChoosingIds.
	UIBuilder builds it (TeamUI.Build) and calls TeamUI.Update every frame.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local LootUI = require(script.Parent.LootUI)
local ClientSettings = require(script.Parent.ClientSettings)

local TeamUI = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local MARK_SEGMENTS = 20
local MARK_R = 24
local WORLD_SEGMENTS = 28
local PARK = CFrame.new(0, -150, 0)
local FLAT = Vector3.new(1, 0, 1)

type Row = { Last: number?, Player: Player, Holder: Frame, Name: TextLabel, State: TextLabel, Meter: UIKit.Meter, IconHolder: Frame, Icon: string, StateKey: string }
type Marker = { Holder: Frame, Segments: { Frame }, Label: TextLabel, Arrow: Frame, Pivot: Frame, Ring: Frame }
type WorldRing = { Segments: { BasePart }, Disc: BasePart, Lit: number }

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local rows: { [Player]: Row } = {}
local rosterKey = ""
local markers: { [Player]: Marker } = {}
local worldRings: { [Player]: WorldRing } = {}
local worldFolder: Folder? = nil

------------------------------------------------------------------------------------------
-- Who is who
------------------------------------------------------------------------------------------

local function inRun(p: Player): boolean
	return p.Parent ~= nil and p:GetAttribute("InRun") == true
end

local function teammates(): { Player }
	local list = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= player and inRun(p) then
			table.insert(list, p)
		end
	end
	table.sort(list, function(a, b)
		return a.UserId < b.UserId
	end)
	return list
end

local function rootOf(p: Player): BasePart?
	local char = p.Character
	return char and char.PrimaryPart or nil
end

-- "alive" | "choosing" | "down" | "reviving" | "deciding" | "out"
local function stateOf(p: Player, state: Configuration): string
	if p:GetAttribute("Alive") ~= false then
		local ids = state:GetAttribute("ChoosingIds") or ""
		if string.find(ids, "," .. tostring(p.UserId) .. ",", 1, true) then
			return "choosing"
		end
		return "alive"
	end
	if p:GetAttribute("AwaitingRevive") == true then
		return "deciding"
	end
	if (tonumber(p:GetAttribute("PartnerRevivesLeft")) or 0) <= 0 then
		return "out"
	end
	if (tonumber(p:GetAttribute("ReviveProgress")) or 0) > 0 then
		return "reviving"
	end
	return "down"
end

local function revivable(p: Player, state: Configuration): boolean
	local s = stateOf(p, state)
	return s == "down" or s == "reviving"
end

local function reviveRadius(state: Configuration): number
	local modeDef = (Config.Modes :: any)[state:GetAttribute("Mode") or ""]
	local rules = modeDef and modeDef.PartnerRevive
	return rules and rules.Radius or 7
end

------------------------------------------------------------------------------------------
-- Team list
------------------------------------------------------------------------------------------

local function rowSize(): (number, number)
	local portrait: boolean = kit.IsPortrait()
	return portrait and 210 or 236, UIKit.IsCompact() and 52 or 46
end

local function buildRow(p: Player, order: number): Row
	local w, h = rowSize()
	local holder, face = UIKit.Surface(ui.List, { Name = "Mate_" .. p.Name, Radius = Theme.Radius.M, Transparency = 0.18, Shadow = false, Size = UDim2.fromOffset(w, h), LayoutOrder = order })
	holder.Active = false
	UIKit.padding(face, 5, 10, 5, 8)
	local iconHolder = new("Frame", { Name = "Hero", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(32, 32) }, face)
	UIKit.corner(iconHolder, 999)
	UIKit.stroke(iconHolder, Theme.Fx.TeamRing, 1.5, 0.2)
	local nameLabel = text(face, "BodyStrong", p.DisplayName, {
		Name = "Name",
		Position = UDim2.fromOffset(40, 0),
		Size = UDim2.new(1, -40, 0, TS(15) + 2),
		TextTruncate = Enum.TextTruncate.AtEnd,
	}, 15)
	local stateLabel = text(face, "Label", "", {
		Name = "State",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0.6, 0, 0, TS(15) + 2),
		TextXAlignment = Enum.TextXAlignment.Right,
	}, 12)
	local meter = UIKit.Meter(face, {
		Gradient = Theme.Gradient.Health,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 40, 1, -1),
		Size = UDim2.new(1, -40, 0, 7),
	})
	return { Player = p, Holder = holder, Name = nameLabel, State = stateLabel, Meter = meter, IconHolder = iconHolder, Icon = "", StateKey = "" }
end

local function clearRows()
	for _, r in pairs(rows) do
		r.Holder:Destroy()
	end
	table.clear(rows)
end

local function rebuildRows(list: { Player })
	clearRows()
	for i, p in ipairs(list) do
		rows[p] = buildRow(p, i)
		UIAnim.Pop(rows[p].Holder, 0.05 * (i - 1), 0.8)
	end
end

local STATE_TEXT = {
	alive = "",
	choosing = "CHOOSING",
	down = "DOWN",
	reviving = "REVIVING",
	deciding = "DECIDING",
	out = "OUT",
}
local HEALTH = Theme.Gradient.Health
local REVIVE = ColorSequence.new(P.gold_300, P.gold_500)
local GREY = ColorSequence.new(P.stone_400, P.stone_600)

local function updateRow(r: Row, state: Configuration)
	local p = r.Player
	local s = stateOf(p, state)
	local heroId = tostring(p:GetAttribute("CharacterId") or "")
	if r.Icon ~= heroId then
		r.Icon = heroId
		for _, c in ipairs(r.IconHolder:GetChildren()) do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		Icons.Character(r.IconHolder, heroId, { Size = 22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_950 })
	end
	local word = STATE_TEXT[s] or ""
	local value: number
	if s == "alive" or s == "choosing" then
		value = math.clamp((tonumber(p:GetAttribute("HP")) or 0) / math.max(1, tonumber(p:GetAttribute("MaxHP")) or 1), 0, 1)
	elseif s == "reviving" then
		value = math.clamp(tonumber(p:GetAttribute("ReviveProgress")) or 0, 0, 1)
		word = string.format("REVIVING %d%%", math.floor(value * 100))
	else
		value = s == "down" and 0 or 1
	end
	if s == "down" then
		local mine, theirs = rootOf(player), rootOf(p)
		if mine and theirs then
			word = string.format("DOWN · %d m", math.floor(((theirs.Position - mine.Position) * FLAT).Magnitude + 0.5))
		end
	end
	r.State.Text = word
	if r.StateKey ~= s then
		local old = r.StateKey
		r.StateKey = s
		local grad = r.Meter.Fill:FindFirstChildOfClass("UIGradient")
		if grad then
			grad.Color = (s == "reviving" or s == "down") and REVIVE or ((s == "out" or s == "deciding") and GREY or HEALTH)
		end
		r.State.TextColor3 = (s == "down") and P.crimson_300 or ((s == "reviving") and P.gold_300 or ((s == "choosing") and P.slate_300 or C.TextMuted))
		r.Name.TextColor3 = (s == "out" or s == "deciding") and C.TextMuted or C.Text
		if old ~= "" and (s == "down" or (old ~= "alive" and old ~= "choosing" and s == "alive")) then
			UIAnim.Punch(r.Holder, 0.12)
			if not ClientSettings.Reduced() then
				local down = s == "down"
				local face = r.Holder:FindFirstChild("Face")
				local f = new("Frame", { Name = "Glow", BackgroundColor3 = down and P.crimson_400 or P.moss_300, BackgroundTransparency = 0.4, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, r.Holder)
				local corner = face and face:FindFirstChildWhichIsA("UICorner")
				if corner then
					corner:Clone().Parent = f
				end
				UIAnim.Tween(f, 0.6, { BackgroundTransparency = 1 }).Completed:Once(function()
					f:Destroy()
				end)
				if not down then
					UIAnim.Sparks(r.Holder, UDim2.new(0, 24, 0.5, 0), P.moss_200, 8, 36, 0.5)
				end
			end
		end
	end
	if r.Last and value > r.Last + 0.04 and (s == "alive" or s == "choosing") then
		UIAnim.SweepOnce(r.Meter.Frame, P.moss_200, 0.45, 0.4)
	end
	r.Last = value
	r.Meter.Set(value)
end

------------------------------------------------------------------------------------------
-- Revive markers (screen) and rings (world)
------------------------------------------------------------------------------------------

local function buildMarker(p: Player): Marker
	local holder = new("Frame", { Name = "Revive_" .. p.Name, BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(MARK_R * 2 + 16, MARK_R * 2 + 16), ZIndex = Theme.Z.Hud, Visible = false }, ui.Markers)
	local ring = new("Frame", { Name = "Ring", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, holder)
	local disc = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(MARK_R * 2 - 10, MARK_R * 2 - 10), BackgroundColor3 = C.Panel, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, ring)
	UIKit.corner(disc, 999)
	UIKit.stroke(disc, P.crimson_400, 1.5, 0.2)
	Icons.Draw(disc, "revive", { Size = 22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
	local segs = {}
	local c = MARK_R + 8
	for i = 1, MARK_SEGMENTS do
		local a = (i - 1) / MARK_SEGMENTS * math.pi * 2 - math.pi / 2
		local seg = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(c + math.cos(a) * MARK_R, c + math.sin(a) * MARK_R),
			Size = UDim2.fromOffset(4, 8),
			Rotation = math.deg(a) + 90,
			BackgroundColor3 = P.slate_500,
			BorderSizePixel = 0,
		}, ring)
		UIKit.corner(seg, 999)
		segs[i] = seg
	end
	-- off-screen pointer: a crimson diamond on the ring's edge, turned toward the player
	local pivot = new("Frame", { Name = "Pivot", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = 0 }, holder)
	local arrow = new("Frame", { Name = "Tip", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(18, 18), Rotation = 45, BackgroundColor3 = P.crimson_400, BorderSizePixel = 0, Visible = false }, pivot)
	UIKit.corner(arrow, 3)
	UIKit.stroke(arrow, P.crimson_300, 1.5, 0.1)
	local label = text(holder, "Label", "", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.fromOffset(200, TS(13) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.ivory_100,
		TextStrokeColor3 = C.Shadow,
		TextStrokeTransparency = 0.3,
	}, 13)
	return { Holder = holder, Segments = segs, Label = label, Arrow = arrow, Pivot = pivot, Ring = ring }
end

local function project(world: Vector3): (Vector2, boolean)
	local cam = workspace.CurrentCamera
	local vp, onScreen = cam:WorldToViewportPoint(world)
	local s = math.max(0.01, kit.Scale())
	local off: Vector2 = kit.GuiOffset()
	return Vector2.new((vp.X - off.X) / s, (vp.Y - off.Y) / s), onScreen and vp.Z > 0
end

local markLit: { [Frame]: number } = setmetatable({}, { __mode = "k" }) :: any

local function updateMarker(m: Marker, p: Player, root: BasePart, progress: number)
	local v: Vector2 = kit.VirtualSize()
	local W, H = v.X, v.Y
	local isMe = p == player
	local pos = root.Position
	local mine = rootOf(player)
	local dist = (mine and not isMe) and ((pos - mine.Position) * FLAT).Magnitude or 0
	local lit = math.floor(progress * MARK_SEGMENTS + 0.001)
	if lit > (markLit[m.Holder] or 0) and not ClientSettings.Reduced() then
		UIAnim.Punch(m.Segments[math.min(lit, MARK_SEGMENTS)], 0.8)
	end
	markLit[m.Holder] = lit
	for i, seg in ipairs(m.Segments) do
		local on = i <= lit
		seg.BackgroundColor3 = on and P.gold_300 or P.slate_500
		seg.BackgroundTransparency = on and 0 or 0.25
	end
	local name = isMe and "You" or p.DisplayName
	if progress > 0 then
		m.Label.Text = UIKit.track(string.format("%s · reviving %d%%", name, math.floor(progress * 100)))
	elseif isMe then
		m.Label.Text = UIKit.track("Waiting for a teammate")
	else
		m.Label.Text = UIKit.track(string.format("Revive %s · %d m", name, math.floor(dist + 0.5)))
	end
	local p2, on = project(pos + Vector3.new(0, 5.5, 0))
	local top = math.max(60, Hud.TopBottom() + 30)
	local bottom = H - 70
	local inside = on and p2.X > 50 and p2.X < W - 50 and p2.Y > top and p2.Y < bottom
	m.Holder.Visible = true
	if inside or isMe then
		m.Arrow.Visible = false
		-- near a screen edge the ring slides in so its label stays readable
		local x = math.clamp(p2.X, 104, W - 104)
		m.Holder.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(p2.Y - 42 + 0.5))
		return
	end
	-- off screen: clamp the direction from the screen centre onto the safe rectangle
	local c = Vector2.new(W / 2, (top + bottom) / 2)
	local d = p2 - c
	if not on and mine then
		local cam = workspace.CurrentCamera
		local right = cam.CFrame.RightVector * FLAT
		local fwd = cam.CFrame.LookVector * FLAT
		local flat = (pos - mine.Position) * FLAT
		if right.Magnitude > 0.01 and fwd.Magnitude > 0.01 then
			d = Vector2.new(flat:Dot(right.Unit), -flat:Dot(fwd.Unit))
		end
	end
	if d.Magnitude < 1 then
		d = Vector2.new(0, -1)
	end
	local xMin, xMax = 56, W - 56
	local kx = d.X ~= 0 and ((d.X > 0 and (xMax - c.X) or (xMin - c.X)) / d.X) or math.huge
	local ky = d.Y ~= 0 and ((d.Y > 0 and (bottom - c.Y) or (top - c.Y)) / d.Y) or math.huge
	local at = c + d * math.min(kx, ky)
	m.Arrow.Visible = true
	m.Pivot.Rotation = math.deg(math.atan2(d.Y, d.X))
	m.Holder.Position = UDim2.fromOffset(math.floor(at.X + 0.5), math.floor(at.Y + 0.5))
end

local function worldPart(shape: Enum.PartType): BasePart
	local part = Instance.new("Part")
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.CFrame = PARK
	part.Parent = worldFolder
	return part
end

local function buildWorldRing(): WorldRing
	if not worldFolder then
		local f = Instance.new("Folder")
		f.Name = "SwarmTeamFx"
		f.Parent = workspace
		worldFolder = f
	end
	local segs = {}
	for i = 1, WORLD_SEGMENTS do
		local s = worldPart(Enum.PartType.Block)
		s.Name = "ReviveSeg" .. i
		s.Color = P.ivory_200
		s.Transparency = 0.35
		segs[i] = s
	end
	local disc = worldPart(Enum.PartType.Cylinder)
	disc.Name = "ReviveDisc"
	disc.Color = P.gold_300
	disc.Transparency = 0.86
	return { Segments = segs, Disc = disc, Lit = -1 }
end

local function placeWorldRing(r: WorldRing, pos: Vector3, radius: number, progress: number)
	-- above the dirt paths (their top is ~0.18 over the floor)
	local y = Config.ArenaOrigin.Y + 0.26
	local n = #r.Segments
	local arc = 2 * math.pi * radius / n
	local lit = math.floor(progress * n + 0.001)
	local t = os.clock()
	for i, s in ipairs(r.Segments) do
		local a = (i - 1) / n * math.pi * 2 - math.pi / 2
		local on = i <= lit
		if r.Lit ~= lit then
			-- unlit: pale gold dashes; lit (revive progress): solid bright ivory, wider
			s.Color = on and P.ivory_100 or P.gold_300
			s.Transparency = on and 0 or 0.4
		end
		s.Size = Vector3.new(arc * (on and 0.75 or 0.55), 0.06, on and 0.6 or 0.4)
		-- tangent along the circle; the unlit dashes breathe very slightly so the circle reads
		local lift = on and 0 or 0.01 * math.sin(t * 3 + i)
		s.CFrame = CFrame.new(pos.X + math.cos(a) * radius, y + lift, pos.Z + math.sin(a) * radius) * CFrame.Angles(0, -a - math.pi / 2, 0)
	end
	r.Lit = lit
	r.Disc.Size = Vector3.new(0.04, radius * 2, radius * 2)
	r.Disc.CFrame = CFrame.new(pos.X, y - 0.02, pos.Z) * CFrame.Angles(0, 0, math.rad(90))
end

local function dropWorldRing(p: Player)
	local r = worldRings[p]
	if r then
		for _, s in ipairs(r.Segments) do
			s:Destroy()
		end
		r.Disc:Destroy()
		worldRings[p] = nil
	end
end

local function dropMarker(p: Player)
	local m = markers[p]
	if m then
		m.Holder:Destroy()
		markers[p] = nil
	end
end

------------------------------------------------------------------------------------------
-- Layout + per frame
------------------------------------------------------------------------------------------

function TeamUI.Layout()
	if not ui.List then
		return
	end
	local v: Vector2 = kit.VirtualSize()
	local W = v.X
	local portrait: boolean = kit.IsPortrait()
	local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
	local w, h = rowSize()
	local els = Hud.Elements()
	local y
	if portrait then
		-- under the ability bar, the status line's spot and the items strip
		y = (els.BarBottom or 400) + 80
		local loot = LootUI.Elements()
		local strip = loot.Strip :: Frame?
		if strip and strip.Visible and strip.Size.Y.Offset > 0 and #strip:GetChildren() > 1 then
			y = math.max(y, strip.Position.Y.Offset + strip.Size.Y.Offset + 44)
		end
	else
		-- under the kill / gold counters (top right)
		local counters = els.Counters :: Frame?
		local top = counters and (counters.Position.Y.Offset + 44) or 70
		y = top + 12
	end
	ui.List.Position = UDim2.fromOffset(math.floor(W - M - w), math.floor(y))
	ui.List.Size = UDim2.fromOffset(w, 3 * (h + 6))
	for _, r in pairs(rows) do
		r.Holder.Size = UDim2.fromOffset(w, h)
	end
end

function TeamUI.Update(_dt: number, state: Configuration, meInRun: boolean)
	if not ui.List then
		return
	end
	local list = meInRun and teammates() or {}
	local keyParts = {}
	for _, p in ipairs(list) do
		table.insert(keyParts, tostring(p.UserId))
	end
	local key = table.concat(keyParts, ",")
	if key ~= rosterKey then
		rosterKey = key
		rebuildRows(list)
		TeamUI.Layout()
	end
	ui.List.Visible = #list > 0
	for _, r in pairs(rows) do
		updateRow(r, state)
	end

	-- revive markers / world rings: every revivable fallen player in the run (also me)
	local wanted: { [Player]: boolean } = {}
	if meInRun and state:GetAttribute("Phase") == "Running" and (state:GetAttribute("Participants") or 1) > 1 then
		local radius = reviveRadius(state)
		for _, p in ipairs(Players:GetPlayers()) do
			local root = rootOf(p)
			if inRun(p) and root and revivable(p, state) then
				wanted[p] = true
				local progress = math.clamp(tonumber(p:GetAttribute("ReviveProgress")) or 0, 0, 1)
				local m = markers[p] or buildMarker(p)
				markers[p] = m
				updateMarker(m, p, root, progress)
				local wr = worldRings[p] or buildWorldRing()
				worldRings[p] = wr
				placeWorldRing(wr, root.Position, radius, progress)
			end
		end
	end
	for p in pairs(markers) do
		if not wanted[p] then
			dropMarker(p)
		end
	end
	for p in pairs(worldRings) do
		if not wanted[p] then
			dropWorldRing(p)
		end
	end
end

-- For the preview tool / tests.
function TeamUI.Elements(): { [string]: any }
	return { List = ui.List, Rows = rows, Markers = markers, Rings = worldRings }
end

function TeamUI.Build(root: Frame, k: { [string]: any })
	kit = k
	local list = new("Frame", { Name = "Team", BackgroundTransparency = 1, Active = false, Visible = false, ZIndex = Theme.Z.Hud }, root)
	UIKit.list(list, { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Right })
	ui.List = list
	ui.Markers = new("Frame", { Name = "ReviveMarkers", BackgroundTransparency = 1, Active = false, Size = UDim2.fromScale(1, 1), ZIndex = Theme.Z.Hud }, root)
	kit.OnRelayout(TeamUI.Layout)
	Players.PlayerRemoving:Connect(function(p)
		-- a teammate who leaves disappears at once (not on the next roster check)
		if rows[p] then
			rosterKey = ""
		end
		dropMarker(p)
		dropWorldRing(p)
	end)
end

return TeamUI
