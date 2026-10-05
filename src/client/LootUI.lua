--[[
	LootUI.lua
	The client side of run items and map loot (server: ItemSystem, LootSystem):

	  items strip    a compact wrap of item tiles with stack counts (HUD, top left under the
	                 Roblox buttons; portrait: under the ability bar). Not Active, so the
	                 thumbstick works on top of it. Under it: the run's curse chips (and
	                 DAILY on a Daily Challenge run, the curses' gold bonus), then a
	                 "BARGAIN" chip while this stage's Bargain Shrine is sealed, then a
	                 "SYNERGY" chip naming the build synergies that are active (player
	                 attribute Synergies, SynergyData).
	  item popup     remote ItemGained: icon tile in the rarity colour, name, rarity, what it
	                 does and where it came from; stacks up to 3 under the strip. Items
	                 from a chest / shrine / altar (Reward = true) go to UIBuilder instead
	                 (LootUI.OnReward): the compact reward card, or the contained reveal for
	                 a rare reward in a solo run; each is kept in the recent-rewards
	                 history (LootUI.RecordReward) shown at the top of the items list
	  purse hint     the price of the loot in reach goes to the HUD purse
	                 (Hud.SetPurseHint; red "NEED N" after a press without enough gold)
	  loot prompt    next to the nearest chest / shrine / altar in reach: title, state,
	                 "+ benefit" / "- tradeoff" lines, the price (red when you can't afford
	                 it) and HOLD (E, gamepad X, or press and hold the button on touch; a
	                 short hold, the model's Hold attribute from Config.Chests.HoldSeconds);
	                 the ring around the icon fills while holding. The server decides (LootHold /
	                 LootFeedback); nothing is opened by the client.
	                 Opaque panel, the lines in an inset well, phone-sized type. A Shrine of
	                 Chance shows its odds as three big numbers (model attributes Odds /
	                 ItemsLeft / TriesLeft) and, for a moment after each try, the outcome
	                 (ITEM FOUND! / NO LUCK THIS TIME).
	  altar marker   a small floating pill over the guarded altar on screen (dormant /
	                 guards left / unguarded / claimed)
	  items list     LootUI.OpenItems() (pause menu "ITEMS" button): the synergies first
	                 (Inventory remote field Synergies, LevelUpSystem.SynergyClues): the
	                 active ones (what they give, what they need), then the ones in
	                 progress as clues (pieces held / "???" for pieces and names the
	                 player has not discovered yet), then every item with its stack count
	                 and full text
	  caravan        the Lost Caravan (server CaravanEvent, workspace.SwarmEvents): a pill
	                 over the cart on screen (LOST CARAVAN / DEFEND / SAVED / LOST), an
	                 edge arrow when it is off screen (while defending, or within
	                 CARAVAN_HINT studs before), and a defence bar under the top HUD while
	                 it is defended: time still to hold, or "RETURN TO THE CARAVAN" with the
	                 seconds left before it is lost.
	UIBuilder builds it (LootUI.Build) and calls LootUI.Update every frame.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local SynergyData = require(Shared:WaitForChild("SynergyData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local ClientSettings = require(script.Parent.ClientSettings)
local Icons = require(script.Parent.Icons)
local Hud = require(script.Parent.Hud)
local UIState = require(script.Parent.UIState)

local LootUI = {}

-- UIBuilder's chest reward reel: items with Reward = true go there instead of a popup.
LootUI.OnReward = nil :: ((any) -> ())?

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local R = Theme.ItemRarity

local SEGMENTS = 20
local RING_R = 24
local FLAT = Vector3.new(1, 0, 1)

local kit: { [string]: any } = {}
local ui: { [string]: any } = {}
local items: { { Id: string, Count: number } } = {}
local popups: { GuiObject } = {}
local popupOrder = 0
local maxPopups = 3 -- fewer when the column would run into the ability panel (Layout)

-- the hold in progress (client view; the server completes it)
local hold = { Id = 0, Start = 0, Seconds = 1, Waiting = false }
local target: Model? = nil
local lastTouch = false

local KIND_ICON = { Chest = "reward_ChestLarge", Shrine = "shrine", Altar = "altar" }
-- chests by tier (the vector chest for the small / free ones, the painted art for the big ones)
local CHEST_ICON = { Small = "chest", Treasure = "chest", Large = "reward_ChestLarge", Golden = "reward_ChestGolden" }
local LINE_PX = 16 -- benefit / tradeoff text (reference px; phones get the compact boost)
local function ODDS_H(): number
	return TS(24) + TS(12) + 12
end
local CARAVAN_HINT = 110 -- studs: the caravan's edge arrow shows this close before it starts
local synergies: { string } = {}
-- Shrine of Chance: the last try's outcome, shown in its prompt for a moment. The item
-- (ItemGained, Source "Shrine of Chance") reaches the client before the try's "Done".
local CHANCE_SOURCE = "Shrine of Chance"
local CHANCE_RESULT_SECONDS = 2.6
local chanceItemAt = -math.huge
local chanceResult = { Id = 0, Win = false, Until = 0 }
local clues: { { [string]: any } }? = nil -- Inventory.Synergies rows (nil: older server)

-- Recent rewards (chests, shrines, the altar, elite chests): newest first, this run only.
-- Filled by UIBuilder when a reward arrives (LootUI.RecordReward), whatever shows it
-- (compact card or reveal), so a skipped or closed reward can still be read later.
local HISTORY_MAX = 8
local history: { { [string]: any } } = {}

local function rarityOf(id: string): string
	local def = ItemData.Items[id]
	return def and def.Rarity or "Common"
end

------------------------------------------------------------------------------------------
-- Item tiles
------------------------------------------------------------------------------------------

-- An item tile: the vector icon on slate, a rarity rim and an "xN" badge.
local function itemTile(parent: Instance?, id: string, size: number, n: number): Frame
	local tile = UIKit.Tile(parent, { Id = id, Size = size, Level = n })
	local stroke = tile:FindFirstChildOfClass("UIStroke")
	local r = R[rarityOf(id)] or R.Common
	if stroke then
		stroke.Color = r.Color
		stroke.Thickness = math.max(1.5, size / 20)
		stroke.Transparency = rarityOf(id) == "Common" and 0.45 or 0.05
	end
	return tile
end
LootUI.ItemTile = itemTile

-- A row of item tiles (results screen). Returns the frame.
function LootUI.ItemRow(parent: Instance, list: { any }, size: number, props: { [string]: any }?): Frame
	local f = new("Frame", { Name = "Items", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, size + 6) }, parent)
	UIKit.list(f, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6), Wraps = true })
	for i, it in ipairs(list) do
		if type(it) == "table" and type(it.Id) == "string" and ItemData.Items[it.Id] then
			itemTile(f, it.Id, size, tonumber(it.Count) or 1).LayoutOrder = i
		end
	end
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	return f
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local function buildStrip(screen: Frame)
	-- the strip and its chips share one full-size layer (same coordinates as the screen) so a
	-- covering modal (ITEMS, pause, level-up, reel, results) hides them all at once
	local root = new("Frame", { Name = "RunChips", BackgroundTransparency = 1, Active = false, Size = UDim2.fromScale(1, 1), ZIndex = Theme.Z.Hud }, screen)
	ui.ChipLayer = root
	local strip = new("Frame", { Name = "ItemStrip", BackgroundTransparency = 1, Active = false, Visible = false, ZIndex = Theme.Z.Hud }, root)
	ui.Strip = strip
	ui.StripGrid = new("UIGridLayout", {
		CellSize = UDim2.fromOffset(30, 30),
		CellPadding = UDim2.fromOffset(5, 5),
		SortOrder = Enum.SortOrder.LayoutOrder,
		FillDirection = Enum.FillDirection.Horizontal,
	}, strip)
	-- the stage's bargain (a pill under the strip)
	local holder, face = UIKit.Surface(root, { Name = "BargainChip", Radius = 999, Transparency = 0.15, Edge = P.crimson_400, EdgeTransparency = 0.25, Shadow = false, Visible = false, ZIndex = Theme.Z.Hud, Size = UDim2.fromOffset(0, 28) })
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 12, 0, 8)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	Icons.Draw(face, "shrine", { Size = 18, LayoutOrder = 1, Color = P.crimson_300 })
	ui.BargainText = text(face, "Label", "BARGAIN", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.crimson_300 }, 12)
	ui.Bargain = holder
	-- the active build synergies (a pill under the bargain)
	local sh, sf = UIKit.Surface(root, { Name = "SynergyChip", Radius = 999, Transparency = 0.15, Edge = P.moss_400, EdgeTransparency = 0.25, Shadow = false, Visible = false, ZIndex = Theme.Z.Hud, Size = UDim2.fromOffset(0, 28) })
	sh.AutomaticSize = Enum.AutomaticSize.X
	sh.Active = false
	sf.AutomaticSize = Enum.AutomaticSize.X
	sf.Size = UDim2.fromScale(0, 1)
	UIKit.padding(sf, 0, 12, 0, 8)
	UIKit.list(sf, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	Icons.Draw(sf, "sparkle", { Size = 18, LayoutOrder = 1, Color = P.moss_200 })
	ui.SynergyText = text(sf, "Label", "SYNERGY", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.moss_200 }, 12)
	ui.Synergy = sh
	-- the run's curses (and DAILY): small chips under the strip (SwarmState Curses / DailyRun)
	local row = new("Frame", { Name = "CurseChips", BackgroundTransparency = 1, Active = false, Visible = false, ZIndex = Theme.Z.Hud, Size = UDim2.fromOffset(400, 26) }, root)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 5), Wraps = true })
	ui.Curses = row
	ui.CurseKey = ""
end

-- One small chip: [icon] NAME (crimson for curses, gold for the daily / the gold bonus).
local function curseChip(parent: Instance, icon: string, str: string, color: Color3, order: number)
	local holder, face = UIKit.Surface(parent, { Name = "Chip", Radius = 999, Transparency = 0.15, Edge = color, EdgeTransparency = 0.35, Shadow = false, Size = UDim2.fromOffset(0, 26), LayoutOrder = order })
	holder.AutomaticSize = Enum.AutomaticSize.X
	holder.Active = false
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 9, 0, 6)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 4) })
	Icons.Draw(face, icon, { Size = 16, LayoutOrder = 1, Color = color })
	text(face, "Label", str, { LayoutOrder = 2, Size = UDim2.fromOffset(0, 26), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = color }, 11)
end

-- Rebuilds the chips when the run's curses change (keyed on the raw attribute: a frame
-- without a change parses nothing).
local function refreshCurses(inRun: boolean)
	local state = Remotes.State()
	local raw = inRun and tostring(state:GetAttribute("Curses") or "") or ""
	local daily = inRun and state:GetAttribute("DailyRun") == true
	local key = (daily and "D|" or "") .. raw
	if key == ui.CurseKey then
		return
	end
	ui.CurseKey = key
	local list = inRun and CurseData.FromString(state:GetAttribute("Curses")) or {}
	for _, ch in ipairs(ui.Curses:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	local order = 0
	if daily then
		order += 1
		curseChip(ui.Curses, "calendar", "DAILY", P.gold_300, order)
	end
	for _, id in ipairs(list) do
		local def = CurseData.Curses[id]
		order += 1
		curseChip(ui.Curses, def.Icon, string.upper(def.Name), P.crimson_300, order)
	end
	if #list > 0 then
		order += 1
		curseChip(ui.Curses, "coin", CurseData.GoldText(CurseData.GoldMult(list)) .. " GOLD", P.gold_300, order)
	end
	ui.Curses.Visible = order > 0
	LootUI.Layout()
end

local function buildPopups(root: Frame)
	ui.Popups = new("Frame", { Name = "ItemPopups", BackgroundTransparency = 1, Size = UDim2.fromOffset(320, 300), ZIndex = Theme.Z.Loot }, root)
	UIKit.list(ui.Popups, { Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Left })
end

local function buildPrompt(root: Frame)
	local holder, face = UIKit.Surface(root, { Name = "LootPrompt", Radius = Theme.Radius.L, Transparency = 0.02, Edge = P.gold_400, EdgeTransparency = 0.25, Visible = false, ZIndex = Theme.Z.Loot, Size = UDim2.fromOffset(300, 150), AnchorPoint = Vector2.new(0, 0.5) })
	ui.Prompt = holder
	ui.PromptFace = face
	local c = RING_R + 8
	-- icon in a ring of segments (the hold progress)
	local ringBox = new("Frame", { Name = "Ring", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(c * 2, c * 2) }, face)
	local disc = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(RING_R * 2 - 10, RING_R * 2 - 10), BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.1, BorderSizePixel = 0 }, ringBox)
	UIKit.corner(disc, 999)
	ui.PromptIconHolder = disc
	ui.PromptIcon = ""
	ui.Segments = {}
	for i = 1, SEGMENTS do
		local a = (i - 1) / SEGMENTS * math.pi * 2 - math.pi / 2
		local seg = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(c + math.cos(a) * RING_R, c + math.sin(a) * RING_R),
			Size = UDim2.fromOffset(4, 8),
			Rotation = math.deg(a) + 90,
			BackgroundColor3 = P.slate_500,
			BorderSizePixel = 0,
		}, ringBox)
		UIKit.corner(seg, 999)
		ui.Segments[i] = seg
	end
	local x0 = c * 2 + 18
	ui.PromptTitle = text(face, "H3", "Small Chest", { Position = UDim2.fromOffset(x0, 8), Size = UDim2.new(1, -x0 - 10, 0, TS(18) + 4), TextColor3 = P.gold_200 })
	ui.PromptDetail = text(face, "Caption", "", { Position = UDim2.fromOffset(x0, 10 + TS(18) + 2), Size = UDim2.new(1, -x0 - 10, 0, TS(12) + 4) })
	ui.PromptDetailColor = ui.PromptDetail.TextColor3
	-- an inset well behind the benefit / tradeoff lines (and the Shrine of Chance odds)
	ui.PromptWell = new("Frame", { Name = "Well", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.05, BorderSizePixel = 0, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 0, 10), Visible = false }, face)
	UIKit.corner(ui.PromptWell, Theme.Radius.M)
	ui.PromptBenefit = text(face, "BodyStrong", "", { Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -36, 0, TS(LINE_PX) + 4), TextColor3 = P.moss_100, TextWrapped = true }, LINE_PX)
	ui.PromptTradeoff = text(face, "BodyStrong", "", { Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -36, 0, TS(LINE_PX) + 4), TextColor3 = P.crimson_300:Lerp(P.ivory_100, 0.3), TextWrapped = true }, LINE_PX)
	-- Shrine of Chance: three big numbers (odds, items left, tries left)
	local odds = new("Frame", { Name = "Odds", BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -36, 0, ODDS_H()), Visible = false }, face)
	ui.Odds = odds
	ui.OddsCells = {}
	for i, cap in ipairs({ "ODDS", "ITEMS LEFT", "TRIES LEFT" }) do
		local cell = new("Frame", { Name = "Cell" .. i, BackgroundTransparency = 1, Position = UDim2.new((i - 1) / 3, 0, 0, 0), Size = UDim2.new(1 / 3, 0, 1, 0) }, odds)
		local value = UIKit.Role(cell, "Number", "", { Name = "Value", Size = UDim2.new(1, 0, 0, TS(24) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200 })
		value.TextSize = TS(24)
		local caption = UIKit.Role(cell, "Caption", cap, { Name = "Caption", Position = UDim2.fromOffset(0, TS(24) + 4), Size = UDim2.new(1, 0, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_200 })
		if i > 1 then
			new("Frame", { Name = "Divider", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.6, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0.15, 0), Size = UDim2.new(0, 1, 0.7, 0) }, cell)
		end
		ui.OddsCells[i] = { Value = value, Caption = caption }
	end
	-- the last try's outcome (ITEM FOUND! / NO LUCK THIS TIME)
	ui.PromptResult = UIKit.Role(face, "Heading", "", { Name = "Result", Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 0, TS(20) + 6), TextXAlignment = Enum.TextXAlignment.Center, Visible = false })
	ui.PromptResult.TextSize = TS(20)
	-- price + hold button
	ui.Price = UIKit.Chip(face, "coin", nil, "25", { Position = UDim2.fromOffset(14, 0), Size = UDim2.fromOffset(0, 36) }, { Size = 18 })
	local btn = new("TextButton", {
		Name = "Hold",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0),
		Size = UDim2.fromOffset(138, 40),
		Active = true,
	}, face)
	UIKit.corner(btn, 10)
	new("UIGradient", { Rotation = 90, Color = Theme.Gradient.Primary }, btn)
	UIKit.stroke(btn, P.gold_200, 1.5, 0.2)
	ui.HoldButton = btn
	ui.HoldLabel = text(btn, "Label", "HOLD  E", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextOnGold }, 15)
	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			lastTouch = input.UserInputType == Enum.UserInputType.Touch
			LootUI.Press()
		end
	end)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			LootUI.Release()
		end
	end)
	ui.PromptNote = text(face, "Caption", "", { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -24, 0, TS(12) + 6), TextXAlignment = Enum.TextXAlignment.Center })
end

local function buildMarker(root: Frame)
	local holder, face = UIKit.Surface(root, { Name = "AltarMarker", Radius = 999, Transparency = 0.15, Shadow = false, Visible = false, ZIndex = Theme.Z.Hud, Size = UDim2.fromOffset(0, 30), AnchorPoint = Vector2.new(0.5, 1) })
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 12, 0, 8)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	Icons.Draw(face, "altar", { Size = 18, LayoutOrder = 1 })
	ui.MarkerText = text(face, "Label", "", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X }, 13)
	ui.Marker = holder
	ui.MarkerFace = face
end

-- Lost Caravan: the world pill, the edge arrow and the defence bar.
local function buildCaravan(root: Frame)
	local holder, face = UIKit.Surface(root, { Name = "CaravanMarker", Radius = 999, Transparency = 0.15, Shadow = false, Visible = false, ZIndex = Theme.Z.Hud, Size = UDim2.fromOffset(0, 30), AnchorPoint = Vector2.new(0.5, 1) })
	holder.AutomaticSize = Enum.AutomaticSize.X
	face.AutomaticSize = Enum.AutomaticSize.X
	face.Size = UDim2.fromScale(0, 1)
	UIKit.padding(face, 0, 12, 0, 8)
	UIKit.list(face, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	Icons.Draw(face, "flag", { Size = 18, LayoutOrder = 1 })
	ui.CaravanText = text(face, "Label", "", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X }, 13)
	ui.CaravanMarker = holder
	ui.CaravanMarkerFace = face
	-- edge arrow: a badge with the banner icon and a diamond tip that turns toward the cart
	local arrow = new("Frame", { Name = "CaravanArrow", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(52, 52), Visible = false, ZIndex = Theme.Z.Hud }, root)
	local pivot = new("Frame", { Name = "Pivot", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(52, 52) }, arrow)
	local tip = new("Frame", { Name = "Tip", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(18, 18), Rotation = 45, BackgroundColor3 = P.crimson_400, BorderSizePixel = 0 }, pivot)
	UIKit.corner(tip, 3)
	local _, bface = UIKit.Surface(arrow, { Name = "Badge", Radius = 999, Transparency = 0.1, Edge = P.crimson_400, EdgeTransparency = 0.2, Size = UDim2.fromOffset(40, 40), AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	Icons.Draw(bface, "flag", { Size = 24, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
	ui.CaravanArrowDist = text(arrow, "Label", "", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, -2), Size = UDim2.fromOffset(80, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center, TextStrokeTransparency = 0.4 }, 12)
	ui.CaravanArrow = arrow
	ui.CaravanPivot = pivot
	ui.CaravanTip = tip
	-- defence bar
	local bar, bf = UIKit.Surface(root, { Name = "CaravanBar", Radius = Theme.Radius.M, Transparency = 0.1, Edge = P.gold_400, EdgeTransparency = 0.3, Visible = false, ZIndex = Theme.Z.Hud, Size = UDim2.fromOffset(340, 50), AnchorPoint = Vector2.new(0.5, 0) })
	bar.Active = false
	Icons.Draw(bf, "flag", { Size = 26, Position = UDim2.fromOffset(10, 8) })
	ui.CaravanBarTitle = text(bf, "Label", "DEFEND THE CARAVAN", { Position = UDim2.fromOffset(44, 5), Size = UDim2.new(1, -110, 0, TS(13) + 6), TextColor3 = P.gold_200 }, 13)
	ui.CaravanBarTime = text(bf, "Label", "", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 5), Size = UDim2.fromOffset(70, TS(13) + 6), TextXAlignment = Enum.TextXAlignment.Right }, 13)
	local track = new("Frame", { Name = "Track", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.2, BorderSizePixel = 0, Position = UDim2.new(0, 44, 1, -16), Size = UDim2.new(1, -56, 0, 8) }, bf)
	UIKit.corner(track, 999)
	local fill = new("Frame", { Name = "Fill", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1) }, track)
	UIKit.corner(fill, 999)
	ui.CaravanBar = bar
	Hud.ReserveCentre(bar) -- centre banners stack under the defence bar
	ui.CaravanFill = fill
end

local function buildItemsModal(root: Frame)
	local m = UIKit.Modal(root, "Items", 560, 520, Theme.Z.Pause + 2)
	ui.Items = m
	local content = m.Content
	text(content, "H1", "ITEMS", { Size = UDim2.new(1, 0, 0, TS(30) + 6), TextXAlignment = Enum.TextXAlignment.Center })
	ui.ItemsSub = text(content, "Caption", "", { Position = UDim2.fromOffset(0, TS(30) + 8), Size = UDim2.new(1, 0, 0, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Center })
	local top = TS(30) + TS(12) + 20
	local scroll = new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, top),
		Size = UDim2.new(1, 0, 1, -top - 62),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
	}, content)
	UIKit.list(scroll, { Padding = UDim.new(0, 6) })
	ui.ItemsList = scroll
	ui.ItemsClose = UIKit.Button(content, {
		Kind = "Primary",
		Title = "BACK",
		Icon = "chevronLeft",
		IconSize = 18,
		Align = "Center",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.fromOffset(200, 50),
		OnClick = function()
			kit.Hide(m.Overlay, "Items")
		end,
	})
	kit.OnRelayout(function()
		local v: Vector2 = kit.VirtualSize()
		m.Panel.Size = UDim2.fromOffset(math.min(560, v.X - 32), math.min(520, v.Y - 40))
	end)
end

------------------------------------------------------------------------------------------
-- Items strip, list, popups
------------------------------------------------------------------------------------------

local function refreshStrip()
	for _, ch in ipairs(ui.Strip:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	for i, it in ipairs(items) do
		itemTile(ui.Strip, it.Id, 30, it.Count).LayoutOrder = i
	end
end

local function refreshList()
	for _, ch in ipairs(ui.ItemsList:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	-- synergy rows: the server's clues (active first, then in progress), or, from an
	-- older server, the active ids of the Synergies attribute
	local rows = clues
	if not rows then
		rows = {}
		for _, id in ipairs(synergies) do
			local s = SynergyData.Synergies[id]
			table.insert(rows, { Id = id, Name = s.Name, Text = s.Text, Have = #s.Pieces, Need = #s.Pieces, Active = true })
		end
	end
	for i, clue in ipairs(rows) do
		local s = type(clue.Id) == "string" and SynergyData.Synergies[clue.Id] or nil
		local active = clue.Active == true
		local color = active and P.moss_200 or P.ivory_300
		local accent = s and s.Color or P.slate_400
		local name = s and s.Name or (type(clue.Name) == "string" and clue.Name or "???")
		local row = UIKit.Panel(ui.ItemsList, { Name = "Synergy_" .. (s and s.Id or tostring(i)), LayoutOrder = i - 100, Size = UDim2.new(1, -8, 0, 62) }, true)
		local tile = new("Frame", { BackgroundColor3 = P.slate_900, BorderSizePixel = 0, Position = UDim2.fromOffset(8, 8), Size = UDim2.fromOffset(46, 46) }, row)
		UIKit.corner(tile, Theme.Radius.M)
		UIKit.stroke(tile, accent, 1.5, active and 0.2 or 0.5)
		Icons.Draw(tile, s and s.Icon or "sparkle", { Size = 34, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900, Color = if s then nil else P.slate_400 })
		text(row, "BodyStrong", name, { Position = UDim2.fromOffset(64, 6), Size = UDim2.new(1, -150, 0, TS(16) + 4), TextColor3 = color })
		local tag = active and "SYNERGY" or string.format("%d / %d", tonumber(clue.Have) or 0, tonumber(clue.Need) or 0)
		text(row, "Caption", UIKit.track(tag), { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8), Size = UDim2.fromOffset(90, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = color })
		local body
		if active then
			body = tostring(clue.Text or (s and s.Text) or "") .. (s and ("  ·  " .. s.Desc) or "")
		else
			-- what the player holds and what is missing (the server hides undiscovered names)
			local have, missing = {}, {}
			for _, piece in ipairs(type(clue.Pieces) == "table" and clue.Pieces or {}) do
				table.insert(piece.Owned and have or missing, tostring(piece.Label or "???"))
			end
			body = string.format("%s  ·  Have: %s  ·  Missing: %s", tostring(clue.Text or ""), #have > 0 and table.concat(have, ", ") or "-", #missing > 0 and table.concat(missing, ", ") or "-")
		end
		text(row, "Small", body, { Position = UDim2.fromOffset(64, 8 + TS(16)), Size = UDim2.new(1, -72, 0, 62 - 12 - TS(16)), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = active and C.Text or C.TextMuted })
	end
	-- recent rewards: one short row each, newest first, above the synergies
	if #history > 0 then
		text(ui.ItemsList, "Caption", UIKit.track("RECENT REWARDS"), { Name = "RecentHead", LayoutOrder = -300, Size = UDim2.new(1, -8, 0, TS(12) + 6), TextColor3 = P.gold_300 })
		local now = os.clock()
		for i, h in ipairs(history) do
			local row = UIKit.Panel(ui.ItemsList, { Name = "Recent" .. i, LayoutOrder = -300 + i, Size = UDim2.new(1, -8, 0, 40) }, true)
			local tile = new("Frame", { BackgroundColor3 = P.slate_900, BorderSizePixel = 0, Position = UDim2.fromOffset(6, 4), Size = UDim2.fromOffset(32, 32) }, row)
			UIKit.corner(tile, 999)
			UIKit.stroke(tile, typeof(h.Color) == "Color3" and h.Color or P.slate_400, 1.5, 0.2)
			if h.Id == "Gold" then
				Icons.Draw(tile, "coin", { Size = 22, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
			elseif type(h.Id) == "string" then
				Icons.Upgrade(tile, h.Id, { Size = 24, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_900 })
			end
			local ago = math.max(0, math.floor(now - (h.At or now)))
			local when = ago < 60 and (ago .. "s ago") or (math.floor(ago / 60) .. "m ago")
			text(row, "BodyStrong", h.Name .. (h.Count > 1 and ("  x" .. h.Count) or ""), { Position = UDim2.fromOffset(46, 2), Size = UDim2.new(1, -150, 0, TS(16) + 2), TextColor3 = typeof(h.Color) == "Color3" and h.Color or C.Text, TextTruncate = Enum.TextTruncate.AtEnd })
			text(row, "Caption", tostring(h.Source or "Reward"), { Position = UDim2.fromOffset(46, 4 + TS(16)), Size = UDim2.new(1, -150, 0, TS(12) + 2), TextColor3 = C.TextMuted, TextTruncate = Enum.TextTruncate.AtEnd })
			text(row, "Caption", UIKit.track(when), { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(96, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.TextMuted })
		end
	end
	local total = 0
	for i, it in ipairs(items) do
		local def = ItemData.Items[it.Id]
		if def then
			total += it.Count
			local r = R[def.Rarity] or R.Common
			local row = UIKit.Panel(ui.ItemsList, { Name = it.Id, LayoutOrder = i, Size = UDim2.new(1, -8, 0, 62) }, true)
			itemTile(row, it.Id, 46, it.Count).Position = UDim2.fromOffset(8, 8)
			text(row, "BodyStrong", def.Name .. (it.Count > 1 and ("  x" .. it.Count) or ""), { Position = UDim2.fromOffset(64, 6), Size = UDim2.new(1, -150, 0, TS(16) + 4), TextColor3 = r.Color })
			text(row, "Caption", UIKit.track(r.Label), { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8), Size = UDim2.fromOffset(90, TS(12) + 4), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = r.Color })
			text(row, "Small", def.Desc, { Position = UDim2.fromOffset(64, 8 + TS(16)), Size = UDim2.new(1, -72, 0, 62 - 12 - TS(16)), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
		end
	end
	ui.ItemsSub.Text = UIKit.track(total == 0 and "No items yet: open chests and shrines" or string.format("%d item%s this run · lost when the run ends", total, total == 1 and "" or "s"))
end

function LootUI.RecordReward(e: { [string]: any })
	if type(e) ~= "table" or type(e.Name) ~= "string" then
		return
	end
	table.insert(history, 1, { Id = e.Id, Name = e.Name, Sub = e.Sub, Source = e.Source, Color = e.Color, Count = tonumber(e.Count) or 1, At = os.clock() })
	while #history > HISTORY_MAX do
		table.remove(history)
	end
	if ui.Items and ui.Items.Overlay.Visible then
		refreshList()
	end
end

-- The history, newest first (tests / preview).
function LootUI.RecentRewards(): { { [string]: any } }
	return history
end

function LootUI.OpenItems()
	refreshList()
	kit.Show(ui.Items.Overlay, "Items", true)
end

function LootUI.ItemCount(): number
	local n = 0
	for _, it in ipairs(items) do
		n += it.Count
	end
	return n
end

local function onItems(list)
	if type(list) ~= "table" then
		return
	end
	items = {}
	for _, it in ipairs(list) do
		if type(it) == "table" and type(it.Id) == "string" and ItemData.Items[it.Id] then
			table.insert(items, { Id = it.Id, Count = tonumber(it.Count) or 1 })
		end
	end
	refreshStrip()
	if ui.Items.Overlay.Visible then
		refreshList()
	end
	LootUI.Layout()
end

local function onGained(data)
	if type(data) ~= "table" or type(data.Id) ~= "string" then
		return
	end
	local def = ItemData.Items[data.Id]
	if not def then
		return
	end
	if data.Source == CHANCE_SOURCE then
		chanceItemAt = os.clock()
	end
	if data.Reward == true and LootUI.OnReward then
		LootUI.OnReward(data)
		return
	end
	local r = R[def.Rarity] or R.Common
	popupOrder += 1
	local holder, face = UIKit.Surface(ui.Popups, { Name = "ItemPopup", Size = UDim2.fromOffset(320, 84), Edge = r.Color, EdgeTransparency = def.Rarity == "Common" and 0.4 or 0.05, Transparency = 0.05, LayoutOrder = popupOrder })
	local n = tonumber(data.Count) or 1
	itemTile(face, def.Id, 60, n).Position = UDim2.fromOffset(12, 12)
	text(face, "H3", def.Name, { Position = UDim2.fromOffset(84, 8), Size = UDim2.new(1, -94, 0, TS(18) + 4), TextColor3 = r.Color, TextTruncate = Enum.TextTruncate.AtEnd })
	local src = type(data.Source) == "string" and ("  ·  " .. data.Source) or ""
	text(face, "Caption", UIKit.track(r.Label .. (n > 1 and (" · x" .. n) or "")) .. src, { Position = UDim2.fromOffset(84, 10 + TS(18)), Size = UDim2.new(1, -94, 0, TS(12) + 4), TextColor3 = r.Color:Lerp(C.TextMuted, 0.4), TextTruncate = Enum.TextTruncate.AtEnd })
	text(face, "BodyStrong", def.Text, { Position = UDim2.fromOffset(84, 14 + TS(18) + TS(12)), Size = UDim2.new(1, -94, 0, TS(16) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
	if def.Rarity ~= "Common" then
		-- a short sheen over uncommon / legendary popups
		local glow = new("Frame", { BackgroundColor3 = r.Color, BackgroundTransparency = 0.7, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, face)
		UIKit.corner(glow, Theme.Radius.M)
		TweenService:Create(glow, TweenInfo.new(0.8), { BackgroundTransparency = 1 }):Play()
	end
	UIAnim.Pop(holder, 0, 0.6)
	table.insert(popups, holder)
	while #popups > maxPopups do
		local old = table.remove(popups, 1)
		if old then
			old:Destroy()
		end
	end
	task.delay(Config.Items.PopupSeconds, function()
		if holder.Parent then
			UIAnim.PopOut(holder, function()
				holder:Destroy()
			end)
		end
		local i = table.find(popups, holder)
		if i then
			table.remove(popups, i)
		end
	end)
end

------------------------------------------------------------------------------------------
-- Holding
------------------------------------------------------------------------------------------

local function priceOf(model: Model): number
	local price = tonumber(model:GetAttribute("Price")) or 0
	if price <= 0 then
		return 0
	end
	return ItemData.PlayerPrice(price, tonumber(player:GetAttribute("GoldMult")) or 1)
end

local function usable(model: Model): boolean
	local st = model:GetAttribute("State")
	if model:GetAttribute("LootKind") == "Altar" then
		return st == "Claimable" or st == "Dormant"
	end
	return st == "Ready"
end

local function canAfford(model: Model): boolean
	return (tonumber(player:GetAttribute("RunGold")) or 0) >= priceOf(model)
end

function LootUI.Press()
	local t = target
	-- a panel or reward feedback owns the screen: no hold, no purchase (UIState contract §4)
	if not t or hold.Id ~= 0 or not usable(t) or not UIState.WorldInputAllowed() then
		return
	end
	if not canAfford(t) then
		UIAnim.Punch(ui.Price.Frame, 0.3)
		Hud.SetPurseHint(priceOf(t), false, true)
		return
	end
	hold.Id = tonumber(t:GetAttribute("LootId")) or 0
	hold.Start = os.clock()
	hold.Seconds = tonumber(t:GetAttribute("Hold")) or 1
	hold.Waiting = false
	Remotes.Get("LootHold"):FireServer(hold.Id, true)
end

function LootUI.Release()
	if hold.Id ~= 0 and not hold.Waiting then
		Remotes.Get("LootHold"):FireServer(hold.Id, false)
		hold.Id = 0
	end
end

local function onFeedback(data)
	if type(data) ~= "table" then
		return
	end
	-- a Shrine of Chance try finished: an item arrived just before "Done", or nothing did
	if data.State == "Done" and type(data.Id) == "number" and data.Id ~= 0 then
		local folder = workspace:FindFirstChild("SwarmLoot")
		local model: Instance? = nil
		if folder then
			for _, m in ipairs(folder:GetChildren()) do
				if m:GetAttribute("LootId") == data.Id then
					model = m
					break
				end
			end
		end
		if model and model:GetAttribute("LootType") == "Chance" then
			local win = os.clock() - chanceItemAt < 1.5
			chanceResult.Id, chanceResult.Win, chanceResult.Until = data.Id, win, os.clock() + CHANCE_RESULT_SECONDS
			chanceItemAt = -math.huge
			if ui.PromptResult then
				UIAnim.Punch(ui.Prompt, win and 0.08 or 0.04)
			end
		end
	end
	if hold.Id ~= 0 and (data.Id == hold.Id or data.Id == 0) then
		hold.Id = 0
		hold.Waiting = false
	end
	if data.State == "Cancel" and data.Reason == "gold" then
		UIAnim.Punch(ui.Price.Frame, 0.3)
		local t = target
		Hud.SetPurseHint(t and priceOf(t) or 0, false, true)
	end
end

local function isHoldKey(input: InputObject): boolean
	return input.KeyCode == Enum.KeyCode.E or input.KeyCode == Enum.KeyCode.ButtonX
end

------------------------------------------------------------------------------------------
-- Layout + per frame
------------------------------------------------------------------------------------------

function LootUI.Layout()
	if not ui.Strip then
		return
	end
	local v: Vector2 = kit.VirtualSize()
	local W = v.X
	local portrait: boolean = kit.IsPortrait()
	local ins = kit.Insets()
	local compact = UIKit.IsCompact()
	local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
	local els = Hud.Elements()
	local x, y, w
	if portrait then
		x, w = M, W - 2 * M
		y = (els.BarBottom or 400) + 8
	else
		-- the HUD's left column: under the vitals panel (HP / level / XP), as wide as it
		x = M + 4
		w = math.max(140, (els.LeftWidth or 300) - 8)
		y = math.max(math.max(ins.Top, 0) + 10, (els.LeftBottom or 0) + 8)
	end
	local per = math.max(1, math.floor((w + 5) / 35))
	local rows = math.max(1, math.ceil(#items / per))
	ui.Strip.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	ui.Strip.Size = UDim2.fromOffset(math.floor(w), rows * 35)
	-- under the strip: the curse chips, then the bargain chip, then the popups
	local yy = y + (#items > 0 and rows * 35 + 4 or 0)
	ui.Curses.Position = UDim2.fromOffset(math.floor(x), math.floor(yy))
	ui.Curses.Size = UDim2.fromOffset(math.floor(math.max(w, 260)), 26)
	if ui.Curses.Visible then
		yy += 31
	end
	ui.Bargain.Position = UDim2.fromOffset(math.floor(x), math.floor(yy))
	-- the synergy chip under the bargain (or in its place); the popups below both
	local chipY = yy + (ui.Bargain.Visible and 33 or 0)
	ui.Synergy.Position = UDim2.fromOffset(math.floor(x), math.floor(chipY))
	if ui.Synergy.Visible then
		yy = math.max(yy, chipY + 33 - 36)
	end
	-- popups: left column under the strip / bargain chip (landscape; the right side is the
	-- loot prompt's), centre (portrait)
	if portrait then
		ui.Popups.AnchorPoint = Vector2.new(0.5, 0)
		ui.Popups.Position = UDim2.fromOffset(W / 2, math.floor(yy + 36))
	else
		ui.Popups.AnchorPoint = Vector2.new(0, 0)
		ui.Popups.Position = UDim2.fromOffset(math.floor(x), math.floor(yy + 36))
	end
	-- landscape phones: the 320-wide column must stop above the bottom ability panel when
	-- the two share columns (only as many popups as fit; the newest stay)
	maxPopups = 3
	local bar = els.Bar
	if not portrait and bar and els.BarTop then
		local barLeft = bar.Position.X.Offset - bar.AnchorPoint.X * bar.Size.X.Offset
		if x + 320 > barLeft then
			local room = els.BarTop - 8 - (yy + 36)
			maxPopups = math.clamp(math.floor((room + 8) / 92), 1, 3)
		end
	end
end

local function project(world: Vector3): (Vector2, boolean)
	local cam = workspace.CurrentCamera
	local vp, onScreen = cam:WorldToViewportPoint(world)
	local s = math.max(0.01, kit.Scale())
	local off: Vector2 = kit.GuiOffset()
	return Vector2.new((vp.X - off.X) / s, (vp.Y - off.Y) / s), onScreen and vp.Z > 0
end

local function lootFolder(): Instance?
	return workspace:FindFirstChild("SwarmLoot")
end

local function setIcon(name: string)
	if ui.PromptIcon == name then
		return
	end
	ui.PromptIcon = name
	for _, ch in ipairs(ui.PromptIconHolder:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
	Icons.Draw(ui.PromptIconHolder, name, { Size = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_950 })
end

local STATE_TEXT = {
	Opened = "Opened",
	Spent = "The shrine has gone dark",
	Active = "Bargain sealed for this stage",
	Claimed = "Claimed",
}

-- Fills the prompt for `model`; returns its height.
-- tight = a short landscape screen: the try's outcome goes in the detail line instead
-- of its own row and the well pads less, so the prompt stays clear of the weapons bar.
local function fillPrompt(model: Model, progress: number, tight: boolean?): number
	local kind = model:GetAttribute("LootKind") or "Chest"
	setIcon(kind == "Chest" and (CHEST_ICON[tostring(model:GetAttribute("LootType"))] or "chest") or KIND_ICON[kind] or "chest")
	ui.PromptTitle.Text = tostring(model:GetAttribute("Title") or "")
	local st = model:GetAttribute("State")
	local ok = usable(model)
	local detail = tostring(model:GetAttribute("Detail") or "")
	if kind == "Altar" and st == "Dormant" then
		detail = "Hold to awaken elite guards"
	end
	if not ok then
		detail = (kind == "Altar" and detail ~= "") and detail or (STATE_TEXT[st] or detail)
	end
	if ok and model:GetAttribute("LootType") == "Chance" and model:GetAttribute("Odds") ~= nil then
		detail = "Pay gold · maybe an item" -- the odds row below has the numbers
	end
	if ok and kind == "Chest" then
		-- what it costs, in which money, before the hold (the odds are the benefit line)
		local cost = priceOf(model)
		detail = cost > 0 and string.format("Costs %s run gold · hold to open", UIKit.formatNumber(cost)) or "Free · hold to open"
	end
	local id = tonumber(model:GetAttribute("LootId")) or 0
	local result = chanceResult.Id ~= 0 and chanceResult.Id == id and os.clock() < chanceResult.Until
	local resultText = chanceResult.Win and "ITEM FOUND!" or "NO LUCK THIS TIME"
	local resultColor = chanceResult.Win and P.gold_200 or P.ivory_200
	if result and tight then
		detail = resultText
	end
	ui.PromptDetail.Text = UIKit.track(detail)
	ui.PromptDetail.TextColor3 = (result and tight) and resultColor or (ui.PromptDetailColor or ui.PromptDetail.TextColor3)
	local benefit = tostring(model:GetAttribute("Benefit") or "")
	local tradeoff = tostring(model:GetAttribute("Tradeoff") or "")
	local showLines = ok or st == "Dormant" or st == "Guarded"
	local y = 10 + (RING_R + 8) * 2 + 4
	-- the last Shrine of Chance try's outcome, big, right under the header
	ui.PromptResult.Visible = result and not tight
	if result and not tight then
		ui.PromptResult.Text = resultText
		ui.PromptResult.TextColor3 = resultColor
		ui.PromptResult.Position = UDim2.fromOffset(12, y - 2)
		y += TS(20) + 8
	end
	-- Shrine of Chance: the odds as three big numbers instead of the benefit sentence
	local odds = tonumber(model:GetAttribute("Odds"))
	local oddsRow = showLines and odds ~= nil and model:GetAttribute("LootType") == "Chance"
	ui.Odds.Visible = oddsRow
	ui.PromptBenefit.Visible = showLines and benefit ~= "" and not oddsRow
	ui.PromptTradeoff.Visible = showLines and tradeoff ~= ""
	local wellTop = y
	ui.PromptWell.Visible = oddsRow or ui.PromptBenefit.Visible or ui.PromptTradeoff.Visible
	local wellPad = tight and 3 or 6
	if ui.PromptWell.Visible then
		y += wellPad
	end
	if oddsRow then
		local cells = ui.OddsCells
		cells[1].Value.Text = string.format("%d%%", math.floor((odds :: number) * 100 + 0.5))
		cells[2].Value.Text = tostring(tonumber(model:GetAttribute("ItemsLeft")) or 0)
		cells[3].Value.Text = tostring(tonumber(model:GetAttribute("TriesLeft")) or 0)
		ui.Odds.Position = UDim2.fromOffset(18, y)
		ui.Odds.Size = UDim2.new(1, -36, 0, ODDS_H())
		y += ODDS_H() + (tight and 0 or 4)
	end
	local px = TS(LINE_PX)
	local lineH = px + 4
	local lineW = math.max(60, (ui.Prompt.Size.X.Offset > 0 and ui.Prompt.Size.X.Offset or 300) - 36)
	local function place(label: TextLabel, str: string)
		label.Text = str
		label.Position = UDim2.fromOffset(18, y)
		local ok2, size = pcall(function()
			return TextService:GetTextSize(str, px, Enum.Font.SourceSansSemibold, Vector2.new(lineW, 1000))
		end)
		local n = (ok2 and typeof(size) == "Vector2") and math.clamp(math.ceil(size.Y / px - 0.2), 1, 3) or 2
		if #str * px * 0.46 <= lineW * 0.95 then
			n = 1 -- clearly fits on one line (average glyph width): no measuring quirk gap
		end
		label.Size = UDim2.new(1, -36, 0, lineH * n)
		y += lineH * n
	end
	if ui.PromptBenefit.Visible then
		place(ui.PromptBenefit, "+  " .. benefit)
	end
	if ui.PromptTradeoff.Visible then
		place(ui.PromptTradeoff, "-  " .. tradeoff)
	end
	if ui.PromptWell.Visible then
		y += wellPad
		ui.PromptWell.Position = UDim2.fromOffset(10, wellTop)
		ui.PromptWell.Size = UDim2.new(1, -20, 0, y - wellTop)
		y += 2
	end
	local price = priceOf(model)
	ui.Price.Frame.Visible = ok
	ui.HoldButton.Visible = ok
	if ok then
		y += 6
		ui.Price.Frame.Position = UDim2.fromOffset(14, y + 2)
		ui.Price.SetValue(price > 0 and UIKit.formatNumber(price) or "FREE")
		ui.Price.Value.TextColor3 = (price > 0 and not canAfford(model)) and P.crimson_300 or P.gold_200
		ui.HoldButton.Position = UDim2.new(1, -12, 0, y)
		-- label by the input actually used last (GamepadEnabled alone is true on many PCs and in
		-- Studio, which showed "HOLD X" to keyboard players)
		local last = UserInputService:GetLastInputType()
		local touch = lastTouch or last == Enum.UserInputType.Touch
			or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
		local pad = not touch and string.sub(last.Name, 1, 7) == "Gamepad"
		ui.HoldLabel.Text = touch and "HOLD" or (pad and "HOLD  X" or "HOLD  E")
		y += 44
		local note = ""
		if price > 0 and not canAfford(model) then
			note = string.format("Need %s more gold", UIKit.formatNumber(price - (tonumber(player:GetAttribute("RunGold")) or 0)))
		elseif progress > 0 then
			note = string.format("Opening %d%%", math.floor(progress * 100))
		end
		ui.PromptNote.Visible = note ~= ""
		if note ~= "" then
			ui.PromptNote.Text = UIKit.track(note)
			ui.PromptNote.Position = UDim2.fromOffset(12, y)
			ui.PromptNote.TextColor3 = progress > 0 and P.gold_200 or P.crimson_300
			y += TS(12) + 6
		end
	else
		ui.PromptNote.Visible = false
	end
	local lit = math.floor(progress * SEGMENTS + 0.001)
	for i, seg in ipairs(ui.Segments) do
		local on = i <= lit
		seg.BackgroundColor3 = on and P.gold_300 or (ok and P.slate_400 or P.stone_600)
		seg.BackgroundTransparency = on and 0 or 0.2
	end
	return y + 10
end

local function updateMarker(altar: Model?, promptShown: boolean)
	if not altar or (promptShown and target == altar) then
		ui.Marker.Visible = false
		return
	end
	local st = altar:GetAttribute("State")
	local pos = altar:GetAttribute("Pos")
	if typeof(pos) ~= "Vector3" then
		ui.Marker.Visible = false
		return
	end
	local p, on = project(pos + Vector3.new(0, 9, 0))
	local v: Vector2 = kit.VirtualSize()
	if not on or p.X < 40 or p.X > v.X - 40 or p.Y < Hud.TopBottom() or p.Y > v.Y - 30 then
		ui.Marker.Visible = false
		return
	end
	local label, color, edge
	if st == "Guarded" then
		label, color, edge = string.upper(tostring(altar:GetAttribute("Detail") or "Guarded")), P.crimson_300, P.crimson_400
	elseif st == "Claimable" then
		label, color, edge = "UNGUARDED: OPEN IT", P.gold_200, P.gold_400
	elseif st == "Claimed" then
		ui.Marker.Visible = false
		return
	else
		label, color, edge = "GUARDED ALTAR", P.ivory_200, P.slate_400
	end
	ui.MarkerText.Text = label
	ui.MarkerText.TextColor3 = color
	local stroke = ui.MarkerFace:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = edge
		stroke.Transparency = 0.15
	end
	ui.Marker.Visible = true
	ui.Marker.Position = UDim2.fromOffset(math.floor(p.X + 0.5), math.floor(p.Y + math.sin(os.clock() * 2.5) * 3 + 0.5))
end

-- The active synergies changed (player attribute Synergies): chip text, the ITEMS list.
local function refreshSynergies()
	synergies = SynergyData.FromString(player:GetAttribute("Synergies"))
	local names = {}
	for _, id in ipairs(synergies) do
		table.insert(names, string.upper(SynergyData.Synergies[id].Name))
	end
	ui.SynergyText.Text = #names > 0 and ("SYNERGY  " .. table.concat(names, "  ·  ")) or "SYNERGY"
	if ui.Items.Overlay.Visible then
		refreshList()
	end
end

local function caravanModel(): Model?
	local f = workspace:FindFirstChild("SwarmEvents")
	local m = f and f:FindFirstChild("Caravan")
	return (m and m:IsA("Model")) and m or nil
end

-- Edge arrow toward world point `pos` when it is off screen (false when on screen).
local function caravanArrow(pos: Vector3, root: BasePart?): boolean
	local v: Vector2 = kit.VirtualSize()
	local W, H = v.X, v.Y
	local p, on = project(pos + Vector3.new(0, 4, 0))
	local portrait: boolean = kit.IsPortrait()
	local els = Hud.Elements()
	local yMin = math.max(70, Hud.TopBottom() + 44)
	if portrait and els.BarBottom then
		yMin = math.max(yMin, els.BarBottom + 44)
	end
	local yMax = portrait and (H - 110) or (Hud.BarTop() - 40)
	local xMin, xMax = 48, W - 48
	if on and p.X > xMin and p.X < xMax and p.Y > yMin and p.Y < yMax then
		return false
	end
	local c = Vector2.new(W / 2, (yMin + yMax) / 2)
	local d = p - c
	if not on and root then
		-- behind the camera: use the ground direction
		local cam = workspace.CurrentCamera
		local flat = (pos - root.Position) * FLAT
		local right = cam.CFrame.RightVector * FLAT
		local fwd = cam.CFrame.LookVector * FLAT
		if right.Magnitude > 0.01 and fwd.Magnitude > 0.01 then
			d = Vector2.new(flat:Dot(right.Unit), -flat:Dot(fwd.Unit))
		end
	end
	if d.Magnitude < 1 then
		d = Vector2.new(0, -1)
	end
	local kx = d.X ~= 0 and ((d.X > 0 and (xMax - c.X) or (xMin - c.X)) / d.X) or math.huge
	local ky = d.Y ~= 0 and ((d.Y > 0 and (yMax - c.Y) or (yMin - c.Y)) / d.Y) or math.huge
	local at = c + d * math.min(kx, ky)
	ui.CaravanArrow.Position = UDim2.fromOffset(math.floor(at.X + 0.5), math.floor(at.Y + 0.5))
	ui.CaravanPivot.Rotation = math.deg(math.atan2(d.Y, d.X))
	return true
end

-- The Lost Caravan's pill, edge arrow and defence bar.
local function updateCaravan(root: BasePart?, alive: boolean)
	local m = caravanModel()
	local pos = m and m:GetAttribute("Pos")
	if not m or typeof(pos) ~= "Vector3" then
		ui.CaravanMarker.Visible = false
		ui.CaravanArrow.Visible = false
		ui.CaravanBar.Visible = false
		return
	end
	local st = m:GetAttribute("State")
	local grace = tonumber(m:GetAttribute("Grace")) or -1
	local dist = root and ((root.Position - pos) * FLAT).Magnitude or math.huge
	local defending = st == "Defending"
	-- defence bar
	if defending ~= ui.CaravanBar.Visible then
		ui.CaravanBar.Visible = defending
		if defending then
			UIAnim.Pop(ui.CaravanBar, 0, 0.6)
		end
	end
	if defending then
		local v: Vector2 = kit.VirtualSize()
		local w = math.min(360, v.X - 32)
		local top = Hud.TopBottom() + 8
		if kit.IsPortrait() then
			local els = Hud.Elements()
			top = math.max(top, (els.BarBottom or 0) + 8)
		end
		ui.CaravanBar.Size = UDim2.fromOffset(w, 50)
		ui.CaravanBar.Position = UDim2.fromOffset(math.floor(v.X / 2), math.floor(top))
		local away = grace >= 0
		-- the caravan is a side objective (COPY CP-05): say so when the title fits
		ui.CaravanBarTitle.Text = away and "RETURN TO THE CARAVAN!" or (w - 110 >= 250 and "OPTIONAL · DEFEND THE CARAVAN" or "OPTIONAL · DEFEND")
		ui.CaravanBarTitle.TextColor3 = away and P.crimson_300 or P.gold_200
		ui.CaravanBarTime.Text = away and string.format("LOST IN %d", grace) or string.format("%d s", tonumber(m:GetAttribute("Left")) or 0)
		ui.CaravanBarTime.TextColor3 = away and P.crimson_300 or P.ivory_100
		ui.CaravanFill.Size = UDim2.fromScale(math.clamp(tonumber(m:GetAttribute("Progress")) or 0, 0, 1), 1)
		ui.CaravanFill.BackgroundColor3 = away and P.crimson_400 or P.gold_400
	end
	-- world pill over the cart
	local label, color, edge
	if defending then
		label, color, edge = grace >= 0 and "UNDEFENDED" or "DEFEND", grace >= 0 and P.crimson_300 or P.gold_200, P.crimson_400
	elseif st == "Saved" then
		label, color, edge = "SAVED", P.gold_200, P.gold_400
	elseif st == "Lost" then
		label, color, edge = "LOST", C.TextMuted, P.stone_600
	else
		label, color, edge = "LOST CARAVAN · STAND IN THE RING", P.ivory_200, P.gold_400
	end
	local p, on = project(pos + Vector3.new(0, 9, 0))
	local v: Vector2 = kit.VirtualSize()
	local onScreen = on and p.X > 40 and p.X < v.X - 40 and p.Y > Hud.TopBottom() and p.Y < v.Y - 30
	ui.CaravanMarker.Visible = onScreen and st ~= "Lost"
	if ui.CaravanMarker.Visible then
		ui.CaravanText.Text = label
		ui.CaravanText.TextColor3 = color
		local stroke = ui.CaravanMarkerFace:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = edge
			stroke.Transparency = 0.15
		end
		local bob = ClientSettings.Reduced() and 0 or math.sin(os.clock() * 2.5) * 3
		ui.CaravanMarker.Position = UDim2.fromOffset(math.floor(p.X + 0.5), math.floor(p.Y + bob + 0.5))
	end
	-- edge arrow: while defending (from outside the ring), or near it before it starts
	local want = alive and ((defending and dist > Config.Caravan.ZoneRadius) or (st == "Waiting" and dist < CARAVAN_HINT))
	local shown = want and caravanArrow(pos, root) or false
	if shown and not ui.CaravanArrow.Visible then
		UIAnim.Pop(ui.CaravanArrow, 0, 0.5)
	end
	ui.CaravanArrow.Visible = shown
	if shown then
		ui.CaravanArrowDist.Text = string.format("%d m", math.floor(dist + 0.5))
		ui.CaravanTip.BackgroundColor3 = defending and P.crimson_400 or P.gold_400
	end
end

function LootUI.Update(_dt: number, inRun: boolean)
	local folder = lootFolder()
	local char = player.Character
	local root = char and char.PrimaryPart
	local alive = player:GetAttribute("Alive") ~= false
	ui.Strip.Visible = inRun and #items > 0
	refreshCurses(inRun)
	if not inRun then
		UIState.SetHold("Prompt", false)
		UIState.SetHold("ItemPopup", false)
		ui.Prompt.Visible = false
		ui.Marker.Visible = false
		ui.Bargain.Visible = false
		ui.Synergy.Visible = false
		ui.CaravanMarker.Visible = false
		ui.CaravanArrow.Visible = false
		ui.CaravanBar.Visible = false
		Hud.SetPurseHint(0, true)
		target = nil
		if hold.Id ~= 0 then
			hold.Id = 0
		end
		return
	end
	-- nearest loot in reach; the altar (for its marker); a sealed bargain
	local best, bestD = nil, math.huge
	local altar: Model? = nil
	local bargain = false
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("Model") then
				local pos = m:GetAttribute("Pos")
				if m:GetAttribute("LootKind") == "Altar" then
					altar = m
				end
				if m:GetAttribute("LootType") == "Bargain" and m:GetAttribute("State") == "Active" then
					bargain = true
				end
				if root and alive and typeof(pos) == "Vector3" then
					local d = ((root.Position - pos) * FLAT).Magnitude
					if d <= Config.Chests.InteractRadius and d < bestD then
						best, bestD = m, d
					end
				end
			end
		end
	end
	if ui.Bargain.Visible ~= bargain then
		ui.Bargain.Visible = bargain
		if bargain then
			local S = Config.Shrines
			ui.BargainText.Text = string.format("BARGAIN  +%d%% DMG BONUS  +%d%% GOLD", math.floor(S.BargainDamage * 100 + 0.5), math.floor(S.BargainGold * 100 + 0.5))
			UIAnim.Pop(ui.Bargain, 0, 0.7)
		end
		LootUI.Layout()
	end
	local syn = #synergies > 0
	if ui.Synergy.Visible ~= syn then
		ui.Synergy.Visible = syn
		if syn then
			UIAnim.Pop(ui.Synergy, 0, 0.7)
		end
		LootUI.Layout()
	end
	updateCaravan(root, alive)
	if best ~= target then
		-- walked to another one (or away): drop the hold
		if hold.Id ~= 0 then
			LootUI.Release()
		end
		target = best
		if best then
			UIAnim.Pop(ui.Prompt, 0, 0.8)
		end
	end
	-- hidden while a panel or reward feedback is on screen (the opened chest's prompt must
	-- not sit beside its own reward); a hold in progress lets go
	local allowed = UIState.WorldInputAllowed()
	if not allowed and hold.Id ~= 0 then
		LootUI.Release()
	end
	local shown = target ~= nil and target.Parent ~= nil and allowed
	ui.Prompt.Visible = shown
	if shown and usable(target :: Model) then
		local t = target :: Model
		Hud.SetPurseHint(priceOf(t), canAfford(t))
	else
		Hud.SetPurseHint(0, true)
	end
	if shown then
		local t = target :: Model
		local progress = 0
		if hold.Id ~= 0 then
			progress = math.clamp((os.clock() - hold.Start) / math.max(0.1, hold.Seconds), 0, 1)
			if progress >= 1 then
				hold.Waiting = true -- the server finishes it; LootFeedback resets
				if os.clock() - hold.Start > hold.Seconds + 1.5 then
					hold.Id = 0
					hold.Waiting = false
				end
			end
		end
		local v: Vector2 = kit.VirtualSize()
		local w = math.min(kit.IsPortrait() and 360 or 340, v.X - 24)
		ui.Prompt.Size = UDim2.fromOffset(w, ui.Prompt.Size.Y.Offset) -- fillPrompt wraps lines to this width
		local h = fillPrompt(t, progress)
		-- landscape: the prompt must fit between the top HUD and the weapons bar
		local hudEls = Hud.Elements()
		local barTop = hudEls.BarTop
		local room = barTop and (barTop - 8 - (Hud.TopBottom() + 4)) or math.huge
		if not kit.IsPortrait() and h > room then
			h = fillPrompt(t, progress, true)
		end
		ui.Prompt.Size = UDim2.fromOffset(w, h)
		local pos = t:GetAttribute("Pos")
		local p = typeof(pos) == "Vector3" and project(pos + Vector3.new(0, 3, 0)) or Vector2.new(v.X / 2, v.Y / 2)
		local x, y
		if kit.IsPortrait() then
			-- portrait: under the hero, in thumb reach (the top holds the HUD)
			x = (v.X - w) / 2
			y = math.max(p.Y + 90 + h / 2, v.Y * 0.74)
			y = math.min(y, v.Y - h / 2 - 24)
		else
			x = p.X + 60
			if x + w > v.X - 16 then
				x = p.X - 60 - w
			end
			x = math.clamp(x, 16, v.X - 16 - w)
			y = math.clamp(p.Y, Hud.TopBottom() + h / 2 + 4, v.Y - h / 2 - 16)
			-- phones: a prompt on the right that would lie over the minimap goes left of
			-- the loot instead (the map is a sibling in the same root)
			local map = ui.Prompt.Parent and ui.Prompt.Parent:FindFirstChild("MiniMap")
			if map and map:IsA("GuiObject") and map.Visible then
				local mx, my = map.Position.X.Offset, map.Position.Y.Offset
				local mw, mh = map.Size.X.Offset, map.Size.Y.Offset
				local top, bottom = y - h / 2, y + h / 2
				if x + w > mx and x < mx + mw and bottom > my and top < my + mh then
					local below = my + mh + 8 + h / 2
					if below <= v.Y - h / 2 - 16 then
						y = below -- under the map, still beside the loot
					else
						x = math.clamp(math.min(x, p.X - 60 - w), 16, math.max(16, mx - 8 - w))
					end
				end
			end
			-- touch: never under the JUMP button (bottom right); slide left of it instead
			if UserInputService.TouchEnabled then
				local Mv = Config.Movement
				local ins = kit.Insets()
				local jump = Mv.ButtonSize + Mv.ButtonMargin + math.max(0, ins.Right or 0) + 8
				if x + w > v.X - jump and y + h / 2 > v.Y - jump then
					x = math.max(16, v.X - jump - w)
				end
			end
			-- never over the weapons bar: lift above it; a lifted prompt that now meets
			-- the minimap goes left of the map
			local bar = hudEls.Bar
			if bar and bar.Visible and barTop then
				local bl = bar.Position.X.Offset - bar.AnchorPoint.X * bar.Size.X.Offset
				local br = bl + bar.Size.X.Offset
				if x < br and x + w > bl and y + h / 2 > barTop - 8 then
					y = math.max(Hud.TopBottom() + h / 2 + 4, barTop - 8 - h / 2)
					local map2 = ui.Prompt.Parent and ui.Prompt.Parent:FindFirstChild("MiniMap")
					if map2 and map2:IsA("GuiObject") and map2.Visible then
						local mx, my = map2.Position.X.Offset, map2.Position.Y.Offset
						local mw, mh = map2.Size.X.Offset, map2.Size.Y.Offset
						if x + w > mx and x < mx + mw and y - h / 2 < my + mh and y + h / 2 > my then
							x = math.max(16, mx - 8 - w)
						end
					end
				end
			end
		end
		ui.Prompt.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	end
	updateMarker(altar, shown)
	-- informational centre headlines (stage banner, portal reveal) wait while a loot prompt
	-- or an item popup is on screen, so they never land on top of them (UIState holds;
	-- threat headlines still show)
	UIState.SetHold("Prompt", shown)
	UIState.SetHold("ItemPopup", #popups > 0)
end

-- For the preview tool / tests.
-- UIBuilder: a HUD-covering modal opened or closed (the strip and chips hide under it).
function LootUI.SetCovered(on: boolean)
	if ui.ChipLayer then
		ui.ChipLayer.Visible = not on
	end
end

function LootUI.Elements(): { [string]: any }
	return ui
end

function LootUI.Build(root: Frame, k: { [string]: any })
	kit = k
	buildStrip(root)
	buildPopups(root)
	buildPrompt(root)
	buildMarker(root)
	buildCaravan(root)
	buildItemsModal(root)
	kit.OnRelayout(LootUI.Layout)
	Remotes.Get("Items").OnClientEvent:Connect(onItems)
	Remotes.Get("Inventory").OnClientEvent:Connect(function(data)
		if type(data) ~= "table" then
			return
		end
		clues = type(data.Synergies) == "table" and data.Synergies or nil
		if ui.Items.Overlay.Visible then
			refreshList()
		end
	end)
	Remotes.Get("ItemGained").OnClientEvent:Connect(onGained)
	Remotes.Get("LootFeedback").OnClientEvent:Connect(onFeedback)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and isHoldKey(input) and not (kit.CanRevive and kit.CanRevive()) then
			lastTouch = false
			LootUI.Press()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if isHoldKey(input) then
			LootUI.Release()
		end
	end)
	player:GetAttributeChangedSignal("Synergies"):Connect(refreshSynergies)
	refreshSynergies()
	player:GetAttributeChangedSignal("InRun"):Connect(function()
		if not player:GetAttribute("InRun") then
			items = {}
			clues = nil
			table.clear(history)
			refreshStrip()
			kit.Hide(ui.Items.Overlay, "Items")
		end
	end)
end

return LootUI
