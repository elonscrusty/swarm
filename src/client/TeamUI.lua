--[[
	TeamUI.lua
	Duo / Trio on the local client: who is on the team and who needs help.

	  team list     one compact row per teammate (other players in the run): hero portrait (painted bust, class icon fallback),
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
	                each revivable fallen player: a living teammate standing inside it
	                revives them (no button; the server fills ReviveProgress, RunManager);
	                its segments light up with the progress. The screen marker's label
	                says "Stand here to revive" while you are inside.
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
local ArtImage = require(script.Parent.ArtImage)
local Hud = require(script.Parent.Hud)
local LootUI = require(script.Parent.LootUI)
local ClientSettings = require(script.Parent.ClientSettings)
local GroundHeight = require(script.Parent.GroundHeight) -- ground under effects on maps with height
-- [stream F] the continuation brief's run tokens + widgets (compact party indicators down the left)
local RunClientFolder = script.Parent.Parent:WaitForChild("SwarmV2Client"):WaitForChild("Run")
local K = require(RunClientFolder:WaitForChild("RunTheme"))
local RunWidgets = require(RunClientFolder:WaitForChild("RunWidgets"))

local TeamUI = {}

local player = Players.LocalPlayer
local new, TS = UIKit.new, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local MARK_SEGMENTS = 20
local MARK_R = 24
local WORLD_SEGMENTS = 28
local PARK = CFrame.new(0, -150, 0)
local FLAT = Vector3.new(1, 0, 1)

type Row = { Last: number?, Player: Player, Holder: Frame, Name: TextLabel, State: TextLabel, Meter: UIKit.Meter, IconHolder: Frame, Icon: string, Bust: ImageLabel?, StateKey: string }
type Marker = { Holder: Frame, Segments: { Frame }, Label: TextLabel, Arrow: Frame, Pivot: Frame, Ring: Frame }
type WorldRing = { Segments: { BasePart }, Disc: BasePart, Lit: number }

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local rows: { [Player]: Row } = {}
local rosterKey = ""
local markers: { [Player]: Marker } = {}
local worldRings: { [Player]: WorldRing } = {}
local worldFolder: Folder? = nil
-- [stream E1] Reviving is holding interact beside a downed teammate (continuation pack:
-- SwarmV2 Run.ReviveHoldClient sends it). LootUI's E / X key gate asks this (UIBuilder passes
-- it as CanRevive): with a downed teammate in reach, interact revives instead of opening a chest.
local reviveHold: any = nil
function TeamUI.CanRevive(): boolean
	if reviveHold == nil then
		local folder = script.Parent.Parent:FindFirstChild("SwarmV2Client")
		local run = folder and folder:FindFirstChild("Run")
		local mod = run and run:FindFirstChild("ReviveHoldClient")
		if not (mod and mod:IsA("ModuleScript")) then
			return false
		end
		local ok, m = pcall(require, mod)
		reviveHold = ok and m or false
	end
	return reviveHold ~= false and reviveHold.HasTarget() == true
end

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
	-- [stream F] the new survival rules: Downed (bleeding out, can be revived), Eliminated (spectating)
	if p:GetAttribute("Eliminated") == true then
		return "out"
	elseif p:GetAttribute("Downed") == true then
		return (tonumber(p:GetAttribute("ReviveProgress")) or 0) > 0 and "reviving" or "down"
	elseif p:GetAttribute("Downed") == false and p:GetAttribute("Alive") ~= false then
		local ids = state:GetAttribute("ChoosingIds") or ""
		if string.find(ids, "," .. tostring(p.UserId) .. ",", 1, true) then
			return "choosing"
		end
		return "alive"
	end
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
	local compact = UIKit.IsCompact()
	return compact and 196 or 214, compact and 60 or 52
end

local function buildRow(p: Player, order: number): Row
	local w, h = rowSize()
	local holder, face = RunWidgets.Panel(ui.List, { Name = "Mate_" .. p.Name, Radius = K.Radius.Panel, Size = UDim2.fromOffset(w, h), LayoutOrder = order })
	holder.Active = false
	UIKit.padding(face, 5, 10, 5, 8)
	local iconHolder = new("Frame", { Name = "Hero", BackgroundColor3 = K.NavyDeep, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(32, 32) }, face)
	UIKit.corner(iconHolder, 999)
	UIKit.stroke(iconHolder, Theme.Fx.TeamRing, 1.5, 0.2)
	local nameLabel = UIKit.Role(face, "Label", p.DisplayName, {
		Name = "Name",
		Position = UDim2.fromOffset(40, 0),
		Size = UDim2.new(1, -40, 0, TS(Theme.Type.Label.Size) + 2),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = K.Cream,
	})
	-- the state word sits on its own line under the name ("DOWN · 12 m", "REVIVING 40%"), so a long
	-- name and a long state never run into each other
	local stateLabel = UIKit.Role(face, "Caption", "", {
		Name = "State",
		Position = UDim2.fromOffset(40, TS(Theme.Type.Label.Size) + 3),
		Size = UDim2.new(1, -40, 0, TS(Theme.Type.Caption.Size) + 2),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = K.CreamMuted,
	})
	local meter = UIKit.Meter(face, {
		Gradient = Theme.Gradient.Health,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 40, 1, -1),
		Size = UDim2.new(1, -40, 0, 7),
	})
	meter.Frame.BackgroundColor3 = K.NavyDeep
	meter.Frame.BackgroundTransparency = 0
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

------------------------------------------------------------------------------------------
-- [stream F] Teammates inside their disconnect window (stream E1: SwarmState AwayIds ",id,id," and
-- AwayUntil, the server time the last window ends). They are no Player any more, so their row is
-- built from the id: a name looked up once, "RECONNECTING 0:42" counting to AwayUntil.
------------------------------------------------------------------------------------------

local awayRows: { [number]: any } = {}
local awayNames: { [number]: string } = {}

local function awayName(uid: number): string
	local cached = awayNames[uid]
	if cached then
		return cached
	end
	awayNames[uid] = "Teammate"
	task.spawn(function()
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(uid)
		end)
		if ok and type(name) == "string" and name ~= "" then
			awayNames[uid] = name
		end
	end)
	return "Teammate"
end

-- The user ids in AwayIds that are not in this server right now (a hero who came back is a Player again).
local function awayList(state: Configuration): { number }
	local out = {}
	local text = state:GetAttribute("AwayIds")
	if type(text) == "string" and text ~= "" then
		for id in string.gmatch(text, "%d+") do
			local uid = tonumber(id)
			if uid and uid ~= player.UserId and not Players:GetPlayerByUserId(uid) then
				table.insert(out, uid)
			end
		end
	end
	table.sort(out)
	return out
end
TeamUI.AwayList = awayList

local function buildAwayRow(uid: number, order: number): any
	local w, h = rowSize()
	local holder, face = RunWidgets.Panel(ui.List, { Name = "Away_" .. uid, Radius = K.Radius.Panel, Size = UDim2.fromOffset(w, h), LayoutOrder = order })
	holder.Active = false
	UIKit.padding(face, 5, 10, 5, 8)
	local iconHolder = new("Frame", { Name = "Hero", BackgroundColor3 = K.NavyDeep, BackgroundTransparency = 0, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(32, 32) }, face)
	UIKit.corner(iconHolder, 999)
	UIKit.stroke(iconHolder, K.Warn, 1.5, 0.3)
	Icons.Draw(iconHolder, "hourglass", { Size = 18, Color = K.Warn, Back = K.NavyDeep, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	local nameLabel = UIKit.Role(face, "Label", awayName(uid), {
		Name = "Name",
		Position = UDim2.fromOffset(40, 0),
		Size = UDim2.new(1, -40, 0, TS(Theme.Type.Label.Size) + 2),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = K.CreamMuted,
	})
	local stateLabel = UIKit.Role(face, "Caption", "RECONNECTING", {
		Name = "State",
		Position = UDim2.fromOffset(40, TS(Theme.Type.Label.Size) + 3),
		Size = UDim2.new(1, -40, 0, TS(Theme.Type.Caption.Size) + 2),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = K.Warn,
	})
	return { Uid = uid, Holder = holder, Name = nameLabel, State = stateLabel }
end

-- Builds, updates and removes the reconnecting rows; true when the number of rows changed.
local function updateAway(state: Configuration, meInRun: boolean): boolean
	local list = meInRun and awayList(state) or {}
	local changed = false
	local wanted: { [number]: boolean } = {}
	local untilAt = tonumber(state:GetAttribute("AwayUntil")) or 0
	local ok, now = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	local left = (ok and untilAt > 0) and math.max(0, math.ceil(untilAt - now)) or nil
	for i, uid in ipairs(list) do
		wanted[uid] = true
		local r = awayRows[uid]
		if not r then
			r = buildAwayRow(uid, 100 + i)
			awayRows[uid] = r
			changed = true
		end
		r.Holder.LayoutOrder = 100 + i
		local name = awayName(uid)
		if r.Name.Text ~= name then
			r.Name.Text = name
		end
		local word = left and string.format("RECONNECTING · %d:%02d", left // 60, left % 60) or "RECONNECTING"
		if r.State.Text ~= word then
			r.State.Text = word
		end
	end
	for uid, r in pairs(awayRows) do
		if not wanted[uid] then
			r.Holder:Destroy()
			awayRows[uid] = nil
			changed = true
		end
	end
	return changed
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
local REVIVE = Theme.Gradient.Primary
local GREY = ColorSequence.new(C.TextFaint, C.TextFaint)

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
		local icon = Icons.Character(r.IconHolder, heroId, { Size = 22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelInset })
		-- the hero's painted bust in the ring (the class icon while it loads / without one)
		r.Bust = ArtImage.RoundPortrait(r.IconHolder, ArtImage.Portrait(heroId), { icon })
	end
	if r.Bust then
		-- greyed while down / out
		r.Bust.ImageColor3 = (s == "down" or s == "out" or s == "deciding") and Color3.fromRGB(150, 160, 175) or Color3.new(1, 1, 1)
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
	if r.State.Text ~= word then
		r.State.Text = word
	end
	if r.StateKey ~= s then
		local old = r.StateKey
		r.StateKey = s
		local grad = r.Meter.Fill:FindFirstChildOfClass("UIGradient")
		if grad then
			grad.Color = (s == "reviving" or s == "down") and REVIVE or ((s == "out" or s == "deciding") and GREY or HEALTH)
		end
		r.State.TextColor3 = (s == "down") and K.Danger or ((s == "reviving") and K.Gold or K.CreamMuted)
		r.Name.TextColor3 = (s == "out" or s == "deciding") and K.CreamMuted or K.Cream
		if old ~= "" and (s == "down" or (old ~= "alive" and old ~= "choosing" and s == "alive")) then
			UIAnim.Punch(r.Holder, 0.12)
			if not ClientSettings.Reduced() then
				local down = s == "down"
				local face = r.Holder:FindFirstChild("Face")
				local f = new("Frame", { Name = "Glow", BackgroundColor3 = down and C.Danger or C.Selected, BackgroundTransparency = 0.4, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, r.Holder)
				local corner = face and face:FindFirstChildWhichIsA("UICorner")
				if corner then
					corner:Clone().Parent = f
				end
				UIAnim.Tween(f, 0.6, { BackgroundTransparency = 1 }).Completed:Once(function()
					f:Destroy()
				end)
				if not down then
					UIAnim.Sparks(r.Holder, UDim2.new(0, 24, 0.5, 0), C.Selected, 8, 36, 0.5)
				end
			end
		end
	end
	if r.Last and value > r.Last + 0.04 and (s == "alive" or s == "choosing") then
		UIAnim.SweepOnce(r.Meter.Frame, C.Selected, 0.45, 0.4)
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
	local disc = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(MARK_R * 2 - 10, MARK_R * 2 - 10), BackgroundColor3 = C.Panel, BackgroundTransparency = 0.05, BorderSizePixel = 0 }, ring)
	UIKit.corner(disc, 999)
	UIKit.stroke(disc, P.crimson_400, 1.5, 0.2)
	Icons.Draw(disc, "revive", { Size = 22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.Panel })
	local segs = {}
	local c = MARK_R + 8
	for i = 1, MARK_SEGMENTS do
		local a = (i - 1) / MARK_SEGMENTS * math.pi * 2 - math.pi / 2
		local seg = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(c + math.cos(a) * MARK_R, c + math.sin(a) * MARK_R),
			Size = UDim2.fromOffset(4, 8),
			Rotation = math.deg(a) + 90,
			BackgroundColor3 = C.BluePale,
			BorderSizePixel = 0,
		}, ring)
		UIKit.stroke(seg, C.Blue, 1, 0.3)
		UIKit.corner(seg, 999)
		segs[i] = seg
	end
	-- off-screen pointer: a crimson diamond on the ring's edge, turned toward the player
	local pivot = new("Frame", { Name = "Pivot", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), ZIndex = 0 }, holder)
	local arrow = new("Frame", { Name = "Tip", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(18, 18), Rotation = 45, BackgroundColor3 = P.crimson_400, BorderSizePixel = 0, Visible = false }, pivot)
	UIKit.corner(arrow, 3)
	UIKit.stroke(arrow, P.crimson_300, 1.5, 0.1)
	local label = UIKit.Role(holder, "Label", "", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.fromOffset(200, TS(Theme.Type.Label.Size) + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.TextOnBlue,
		TextStrokeTransparency = 0.3,
	}, true)
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

local function updateMarker(m: Marker, p: Player, root: BasePart, progress: number, radius: number)
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
		seg.BackgroundColor3 = on and C.Primary or C.BluePale
		seg.BackgroundTransparency = on and 0 or 0.25
	end
	local name = isMe and "You" or p.DisplayName
	if progress > 0 then
		m.Label.Text = UIKit.track(string.format("%s · reviving %d%%", name, math.floor(progress * 100)))
	elseif isMe then
		m.Label.Text = UIKit.track("Waiting for a teammate")
	elseif dist <= radius then
		m.Label.Text = UIKit.track("Stand here to revive")
	else
		m.Label.Text = UIKit.track(string.format("Revive %s · %d m", name, math.floor(dist + 0.5)))
	end
	local p2, on = project(pos + Vector3.new(0, 5.5, 0))
	local top = math.max(60, Hud.TopBottom() + 30)
	local bottom = H - 70
	-- landscape: the ability panel takes the bottom centre; the ring and its label stay
	-- above it there (the ring is 64 px tall, the label ~20 px under it)
	local els = Hud.Elements()
	local barTop, barL, barR = math.huge, 0, 0
	if not kit.IsPortrait() and els.Bar and els.BarTop then
		barTop = els.BarTop - 58
		barL = els.Bar.Position.X.Offset - 40
		barR = barL + els.Bar.Size.X.Offset + 80
	end
	local function settle(x: number, y: number)
		if y > barTop and x > barL and x < barR then
			y = barTop
		end
		-- the 200 px label is centred under the ring; near a screen edge it slides in so
		-- it never runs off screen
		local labelAbove = false
		local portrait = kit.IsPortrait()
		if portrait then
			-- portrait: the ring itself slides right of the left-edge minimap when it would
			-- sit under it (the map is painted over the markers)
			local half = m.Holder.Size.X.Offset / 2
			for _, g in ipairs(Hud.PortraitBars()) do
				if g.Visible and g.Parent then
					local gx = g.Position.X.Offset - g.AnchorPoint.X * g.Size.X.Offset
					local gy = g.Position.Y.Offset - g.AnchorPoint.Y * g.Size.Y.Offset
					local gr, gb = gx + g.Size.X.Offset, gy + g.Size.Y.Offset
					if x - half < gr + 4 and x + half > gx - 4 and y - half < gb + 4 and y + half > gy - 4 then
						x = math.min(gr + 6 + half, W - half - 4)
					end
				end
			end
		end
		local lx = math.clamp(x, 108, W - 108)
		if portrait then
			-- portrait: the left-edge minimap sits about mid-screen, right where the downed
			-- hero's "You · reviving" label lands; the label slides right of the map, or
			-- goes above the ring when there is no room beside it
			local lh = m.Label.Size.Y.Offset
			local ly = y + MARK_R + 8
			for _, g in ipairs(Hud.PortraitBars()) do
				if g.Visible and g.Parent then
					local gx = g.Position.X.Offset - g.AnchorPoint.X * g.Size.X.Offset
					local gy = g.Position.Y.Offset - g.AnchorPoint.Y * g.Size.Y.Offset
					local gr, gb = gx + g.Size.X.Offset, gy + g.Size.Y.Offset
					local function hits(cx: number, top: number): boolean
						return cx - 100 < gr + 4 and cx + 100 > gx - 4 and top < gb + 4 and top + lh > gy - 4
					end
					if hits(lx, ly) then
						local shifted = gr + 8 + 100
						if shifted <= W - 8 - 100 + 0.5 then
							lx = shifted
						elseif not hits(lx, y - MARK_R - 8 - lh) then
							labelAbove = true
						end
					end
				end
			end
		end
		m.Label.AnchorPoint = if labelAbove then Vector2.new(0.5, 1) else Vector2.new(0.5, 0)
		m.Label.Position = UDim2.new(0.5, lx - x, if labelAbove then 0 else 1, 0)
		m.Holder.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	end
	local inside = on and p2.X > 50 and p2.X < W - 50 and p2.Y > top and p2.Y < bottom
	m.Holder.Visible = true
	if inside or isMe then
		m.Arrow.Visible = false
		-- near a screen edge the ring slides in so its label stays readable
		settle(math.clamp(p2.X, 104, W - 104), p2.Y - 42)
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
	settle(at.X, at.Y)
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
	local y = GroundHeight.At(pos.X, pos.Z) + 0.26
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
	local w, h = rowSize()
	local n = 0
	for _ in pairs(rows) do
		n += 1
	end
	for _ in pairs(awayRows) do
		n += 1
	end
	-- the shared run layout (Hud.RunRect): the compact party stack down the left, under the health
	-- plate (phones: 4% / 25% of the safe area); it tells the layout how tall the stack is
	local gap = 6
	Hud.SetPieceSize("Party", n > 0 and w or 0, n > 0 and (n * (h + gap) - gap) or 0)
	local r = Hud.RunRect("Party")
	local v: Vector2 = kit.VirtualSize()
	local portrait: boolean = kit.IsPortrait()
	local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
	local x, y = M, 120
	if r then
		x, y = r.X, r.Y
	end
	-- the older item strip, chips and popups (LootUI) sit in the same left column: the party stack
	-- starts under them
	if not portrait then
		local loot = LootUI.Elements()
		local strip = loot.Strip :: Frame?
		if strip and strip.Visible and strip.Size.Y.Offset > 0 and #strip:GetChildren() > 1 then
			y = math.max(y, strip.Position.Y.Offset + strip.Size.Y.Offset + 8)
		end
		for _, key in ipairs({ "Curses", "Bargain", "Synergy" }) do
			local chip = loot[key] :: Frame?
			if chip and chip.Visible then
				y = math.max(y, chip.Position.Y.Offset + chip.Size.Y.Offset + 8)
			end
		end
		y = math.min(y, math.max(0, v.Y - (n * (h + gap)) - 8))
	end
	ui.List.AnchorPoint = Vector2.new(0, 0)
	ui.List.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	ui.List.Size = UDim2.fromOffset(w, 3 * (h + gap))
	for _, row in pairs(rows) do
		row.Holder.Size = UDim2.fromOffset(w, h)
	end
	for _, row in pairs(awayRows) do
		row.Holder.Size = UDim2.fromOffset(w, h)
	end
end

function TeamUI.Update(_dt: number, state: Configuration, meInRun: boolean)
	if not ui.List then
		return
	end
	local list = meInRun and teammates() or {}
	local radius = reviveRadius(state)
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
	local awayChanged = updateAway(state, meInRun)
	if awayChanged then
		TeamUI.Layout()
	end
	local anyAway = next(awayRows) ~= nil
	ui.List.Visible = #list > 0 or anyAway
	for _, r in pairs(rows) do
		updateRow(r, state)
	end

	-- revive markers / world rings: every revivable fallen player in the run (also me)
	local wanted: { [Player]: boolean } = {}
	if meInRun and state:GetAttribute("Phase") == "Running" and (state:GetAttribute("Participants") or 1) > 1 then
		for _, p in ipairs(Players:GetPlayers()) do
			local root = rootOf(p)
			if inRun(p) and root and revivable(p, state) then
				wanted[p] = true
				local progress = math.clamp(tonumber(p:GetAttribute("ReviveProgress")) or 0, 0, 1)
				local m = markers[p] or buildMarker(p)
				markers[p] = m
				updateMarker(m, p, root, progress, radius)
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
	return { List = ui.List, Rows = rows, Away = awayRows, Markers = markers, Rings = worldRings }
end

function TeamUI.Build(root: Frame, k: { [string]: any })
	kit = k
	local list = new("Frame", { Name = "Team", BackgroundTransparency = 1, Active = false, Visible = false, ZIndex = Theme.Z.Hud }, root)
	UIKit.list(list, { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Left })
	ui.List = list
	ui.Markers = new("Frame", { Name = "ReviveMarkers", BackgroundTransparency = 1, Active = false, Size = UDim2.fromScale(1, 1), ZIndex = Theme.Z.Hud }, root)
	kit.OnRelayout(TeamUI.Layout)
	Hud.OnLayout(function()
		TeamUI.Layout()
	end)
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
