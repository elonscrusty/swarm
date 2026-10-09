--!nonstrict
--[[
	SwarmV2/Run/RunCards.lua  (StarterPlayerScripts.SwarmV2Client.Run.RunCards)
	OWNER: stream F (run UI).

	The live upgrade / chest cards of the continuation brief. A compact panel docked under the
	objective strip: three cards, a deadline ring and a reroll button. It never dims or freezes the
	screen, owns no input but its own rectangle (movement, camera orbit and every other button keep
	working), and says "Combat continues". Used whenever the LevelUpOffer payload carries the new
	fields; the previous full-screen panel (UIBuilder) still serves payloads without them.

	Payload (LevelUpOffer, docs/redesign/continuation/GAMEPLAY_PLAN.md "Builds"): the existing shape
	(Choices, OfferId, ...) plus per card Category / Rarity / RankFrom / RankTo / Slot / Lines /
	Synergy and per offer Deadline (server time), RerollsLeft, Source ("Level" | "Chest"). Every field
	is optional: a card from an older server falls back to what it has (Type, Level, Rank text, Lines
	rows, RarityLabel) and the missing line is simply left out.

	A card shows: rarity SYMBOL + WORD (a shape and a word, never colour alone), name, category and
	slot, the current -> next lines, the synergy line. No "Recommended" tag exists (there is no rule
	for one). Choosing: click / tap the card, keys 1 / 2 / 3, gamepad focus + A; R or the REROLL button
	rerolls. Safe input: nothing counts before ArmSeconds after the cards appear, a held key never
	confirms, and a touch must be a whole tap (TouchHoldSeconds, TouchSlop) that began after
	TouchArmSeconds, so a thumb resting from play never picks a card.

	Deadline: the ring follows the payload's server deadline (or the older ChoiceProtectedUntil
	attribute, or the offer's own Seconds); it freezes with "Paused while you are down" while the
	server holds the timer. Reduced motion: no pop-ins, no pulse.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local Client = script.Parent.Parent.Parent:WaitForChild("SwarmClient")
local UIKit = require(Client:WaitForChild("UIKit"))
local UIAnim = require(Client:WaitForChild("UIAnim"))
local UIState = require(Client:WaitForChild("UIState"))
local Icons = require(Client:WaitForChild("Icons"))
local ClientSettings = require(Client:WaitForChild("ClientSettings"))
local InputPrompts = require(Client:WaitForChild("InputPrompts"))
local RunTheme = require(script.Parent.RunTheme)
local W = require(script.Parent.RunWidgets)

local RunCards = {}

local CFG = RunConfig.UI.Cards
local LAYOUT = RunConfig.UI.Layout
local player = Players.LocalPlayer
local new, corner, stroke = UIKit.new, UIKit.corner, UIKit.stroke

local ui: { [string]: any } = {}
local kit: { [string]: any } = {}
local offer: { [string]: any }? = nil
local cards: { any } = {} -- normalized cards
local items: { any } = {} -- card widgets
local open = false
local shownAt = math.huge
local armAt = math.huge
local totalSeconds = CFG.DefaultSeconds
local frozenLeft: number? = nil
local picked = false
local rerollPendingUntil = 0
local touches: { [any]: { At: number, Pos: Vector2, Moved: number } } = setmetatable({}, { __mode = "k" }) :: any
local ring: any = nil
local keyBadges: { [number]: Frame } = {}
local rerollKey = ""
local stacked = false -- portrait: one card per row, the full width
local emptySlots = 0 -- missing card slots the server reported (payload.Empty): drawn as quiet placeholders
local emptyText = ""

------------------------------------------------------------------------------------------
-- Payload -> card (pure, also used by the tests)
------------------------------------------------------------------------------------------

local function str(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

-- Normalizes one card of the payload (new fields first, the older ones as fallback).
function RunCards.Normalize(card: any, index: number): { [string]: any }
	local out: { [string]: any } = { Index = index }
	out.Name = str(card.Name) or str(card.Id) or "Upgrade"
	out.Id = card.Id
	-- category
	local category = str(card.Category) or CFG.LegacyCategory[card.Type] or nil
	out.Category = category
	out.CategoryLabel = category and (CFG.CategoryLabel[category] or category) or nil
	-- rarity: the new names, the older ones mapped, Evolution for an evolution card
	local rarity = str(card.Rarity)
	if rarity and not CFG.Rarity[rarity] then
		rarity = CFG.LegacyRarity[rarity]
	end
	if category == "Evolution" then
		rarity = "Evolution"
	end
	rarity = rarity or "Common"
	out.Rarity = rarity
	out.RarityLabel = CFG.Rarity[rarity].Label
	-- ranks
	local from, to = tonumber(card.RankFrom), tonumber(card.RankTo)
	if not to and (card.Type == "WeaponUp" or card.Type == "PassiveUp") and tonumber(card.Level) then
		to = tonumber(card.Level)
		from = to - 1
	elseif not to and (card.Type == "WeaponNew" or card.Type == "PassiveNew") then
		from, to = 0, tonumber(card.Level) or 1
	end
	out.RankFrom, out.RankTo = from, to
	-- slot
	local slot = card.Slot
	if type(slot) == "number" then
		local weaponish = category == "WeaponUpgrade" or category == "NewWeapon" or category == "Evolution"
		out.Slot = string.format("%s slot %d", weaponish and "Weapon" or "Passive", slot)
	elseif str(slot) then
		out.Slot = slot
	elseif category == "NewWeapon" then
		out.Slot = "Takes a free weapon slot"
	elseif category == "NewPassive" then
		out.Slot = "Takes a free passive slot"
	elseif category == "Heal" then
		out.Slot = "Needs no slot"
	end
	-- current -> next lines
	local lines = {}
	if type(card.Lines) == "table" then
		for _, line in ipairs(card.Lines) do
			if type(line) == "string" then
				table.insert(lines, { Text = line })
			elseif type(line) == "table" then
				if line.Text then
					table.insert(lines, { Text = tostring(line.Text) })
				elseif line.From ~= nil or line.To ~= nil then
					table.insert(lines, { Label = line.Label and tostring(line.Label) or nil, From = line.From ~= nil and tostring(line.From) or nil, To = line.To ~= nil and tostring(line.To) or nil })
				end
			end
		end
	end
	if #lines == 0 and str(card.Summary) then
		table.insert(lines, { Text = card.Summary })
	elseif #lines == 0 and str(card.Description) then
		table.insert(lines, { Text = card.Description })
	end
	out.Lines = lines
	-- synergy
	local syn = card.Synergy
	if type(syn) == "table" then
		syn = syn.Text or syn.Name
	end
	if str(syn) then
		out.Synergy = (string.gsub(syn, "^Synergy:%s*", ""))
	end
	-- icon
	local icon = card.Id
	if category == "Evolution" then
		local def = WeaponData.Weapons[card.Id]
		icon = def and def.Evolution and def.Evolution.Id or card.Id
	elseif card.Type == "Gold" or card.Type == "Heal" or category == "Heal" then
		icon = "Heal"
	end
	out.IconId = str(card.IconId) or icon
	return out
end

-- Does this payload use the new contract (compact live cards)? Older payloads keep the previous panel.
function RunCards.Wants(payload: any): boolean
	if not CFG.Live or type(payload) ~= "table" or type(payload.Choices) ~= "table" then
		return false
	end
	if payload.Deadline ~= nil or payload.Source ~= nil or payload.RerollsLeft ~= nil then
		return true
	end
	for _, c in ipairs(payload.Choices) do
		if type(c) == "table" and (c.Category ~= nil or c.RankTo ~= nil or c.Slot ~= nil) then
			return true
		end
	end
	return false
end

------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------

local CARD_MIN_H = 150
local HEAD_H = 52
local headH = HEAD_H -- the header grows with the touch size of the reroll button
local cardH = CARD_MIN_H -- the tallest card's content (set per offer)

-- The body lines (current -> next) are what people read: on a phone they are sized so they come out
-- at 16 pt on the device whatever the UI scale is (design px x scale = points).
local function lineSize(): number
	if not UIKit.IsCompact() then
		return 16
	end
	local scale = math.max(0.3, kit.Scale and kit.Scale() or 1)
	return math.clamp(math.ceil(RunConfig.UI.Cards.BodyPoints / (scale * Theme.TextScaleCompact)), 16, 24)
end

local function lineHeight(): number
	return UIKit.TS(lineSize()) + 4
end

-- A small label's design size so it comes out at `pt` points on a phone, never under its normal size.
local function labelSize(base: number, pt: number): number
	if not UIKit.IsCompact() then
		return base
	end
	local scale = math.max(0.3, kit.Scale and kit.Scale() or 1)
	return math.max(base, math.ceil(pt / (scale * Theme.TextScaleCompact)))
end

-- Portrait: one card per row at the full width (see Layout).
local function isStacked(): boolean
	return UIKit.IsCompact() and kit.IsPortrait ~= nil and kit.IsPortrait() == true
end

-- A synergy line is one row when the card is wide, two when it is a narrow column card and the text is long.
local function synergyRows(c: any): number
	if not c.Synergy or isStacked() then
		return c.Synergy and 1 or 0
	end
	return (utf8.len("SYNERGY  " .. c.Synergy) or 0) > 24 and 2 or 1
end

-- Height one card needs for its rows (rarity, name, category, up to three lines, slot, synergy).
local function needHeight(c: any): number
	local rows = { 24, 34, UIKit.TS(labelSize(13, 12)) + 4 }
	for _ = 1, math.min(#c.Lines, 3) do
		table.insert(rows, lineHeight())
	end
	if c.Slot and not isStacked() then
		table.insert(rows, UIKit.TS(labelSize(14, 12)) + 4)
	end
	local syn = synergyRows(c)
	if syn > 0 then
		table.insert(rows, syn * (UIKit.TS(labelSize(13, 12)) + 2) + 6)
	end
	local h = 0
	for _, r in ipairs(rows) do
		h += r
	end
	return h + (#rows - 1) * 2 + 8 + 12
end

local function sound(name: string)
	UIKit.Sound(name)
end

function RunCards.Build(root: Instance, k: any)
	kit = k
	local holder, face = W.Panel(root, { Name = "RunCards", Visible = false, ZIndex = Theme.Z.LevelUp - 2 })
	holder.Active = true -- taps inside the panel never start the stick or orbit the camera
	face.Active = true
	ui.Panel, ui.Face = holder, face
	-- header: deadline ring, title line, status line, reroll
	ring = W.Ring(face, { Name = "Deadline", Size = 44, Segments = 24, Color = RunTheme.Cyan, Position = UDim2.fromOffset(10, 6), ZIndex = 3 })
	ui.Ring = ring
	ui.Seconds = W.Text(ring.Frame, "10", { Name = "Seconds", Size = 18, Font = "Number", Align = "Center", Box = UDim2.fromScale(1, 1), ZIndex = 5, Color = RunTheme.Cream })
	ui.Title = W.Text(face, "LEVEL UP", { Name = "Title", Size = 20, Font = "Heading", Position = UDim2.fromOffset(62, 4), Box = UDim2.new(0.5, -62, 0, 26), Fit = 13, Color = RunTheme.Gold })
	ui.StatusSize = labelSize(14, 12)
	ui.Status = W.Text(face, "Combat continues", { Name = "Status", Size = ui.StatusSize, Font = "Label", Position = UDim2.fromOffset(62, 29), Box = UDim2.new(0.6, -62, 0, 20), Fit = 11, Color = RunTheme.CreamMuted })
	ui.Cards = new("Frame", { Name = "Cards", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, HEAD_H), Size = UDim2.new(1, -16, 0, CARD_MIN_H), Active = false }, face)
	ui.CardsList = UIKit.list(ui.Cards, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, 8) })
	ui.Reroll = W.Button(face, {
		Name = "Reroll",
		Text = "REROLL",
		Sub = "R",
		Kind = "Secondary",
		TextSize = 18,
		Size = UDim2.fromOffset(150, LAYOUT.TouchMin),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 2),
		ZIndex = 3,
		OnClick = function(input)
			RunCards.Reroll(input)
		end,
	})
	kit.OnRelayout(function()
		RunCards.Layout()
	end)

	-- keys: 1 / 2 / 3 choose, R rerolls; none of them is "processed" away from movement keys
	UserInputService.InputBegan:Connect(function(input, processed)
		if not open or picked or UserInputService:GetFocusedTextBox() then
			return
		end
		local code = input.KeyCode
		local n = (code == Enum.KeyCode.One or code == Enum.KeyCode.KeypadOne) and 1
			or (code == Enum.KeyCode.Two or code == Enum.KeyCode.KeypadTwo) and 2
			or (code == Enum.KeyCode.Three or code == Enum.KeyCode.KeypadThree) and 3
			or nil
		if n and not processed then
			RunCards.Choose(n, input)
		elseif code == CFG.RerollKey and not processed then
			RunCards.Reroll(input)
		elseif code == Enum.KeyCode.ButtonX and open then
			RunCards.Reroll(input)
		end
		if input.UserInputType == Enum.UserInputType.Touch then
			touches[input] = { At = os.clock(), Pos = Vector2.new(input.Position.X, input.Position.Y), Moved = 0 }
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		local rec = touches[input]
		if rec then
			rec.Moved = math.max(rec.Moved, (Vector2.new(input.Position.X, input.Position.Y) - rec.Pos).Magnitude)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local rec = touches[input]
		if rec then
			rec.EndedAt = os.clock()
		end
	end)
end

------------------------------------------------------------------------------------------
-- Cards
------------------------------------------------------------------------------------------

local function cardWidth(): number
	local v = kit.VirtualSize()
	local phone = UIKit.IsCompact()
	local margin = phone and LAYOUT.MarginPhone or LAYOUT.MarginDesktop
	local room = v.X - 2 * margin - 16 - 16
	return math.clamp(math.floor(room / 3), CFG.MinCardWidth, CFG.MaxCardWidth)
end

local function lineRow(parent: Instance, line: any, order: number)
	local size = lineSize()
	local row = new("Frame", { Name = "Line", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, lineHeight()), LayoutOrder = order, Active = false }, parent)
	if line.Text then
		W.Text(row, line.Text, { Name = "Text", Size = size, Font = "Body", Box = UDim2.fromScale(1, 1), Fit = 11, Color = RunTheme.Cream })
		return
	end
	local label = line.Label
	if line.From and line.To then
		-- "Damage  12 -> 14": the label, the current value muted, an arrow, the next value bright
		local text = string.format('%s<font color="%s">%s</font>  →  <font color="%s"><b>%s</b></font>', label and (label .. "   ") or "", UIKit.hex(RunTheme.CreamMuted), line.From, UIKit.hex(RunTheme.Gold), line.To)
		W.Text(row, text, { Name = "Change", Size = size, Font = "Body", Box = UDim2.fromScale(1, 1), Fit = 11, Color = RunTheme.Cream, RichText = true })
	else
		local value = line.To or line.From or ""
		W.Text(row, (label and (label .. "  ") or "") .. tostring(value), { Name = "Stat", Size = size, Font = "Body", Box = UDim2.fromScale(1, 1), Fit = 11, Color = RunTheme.Cream })
	end
end

local function buildCard(c: any, index: number, count: number, w: number): Frame
	local rarityColor = RunTheme.Rarity[c.Rarity] or RunTheme.CreamMuted
	local holder = new("Frame", { Name = "Card" .. index, BackgroundTransparency = 1, Size = UDim2.fromOffset(w, cardH), LayoutOrder = index, Active = false })
	local btn = new("TextButton", { Name = "Hit", Text = "", AutoButtonColor = false, BackgroundColor3 = RunTheme.NavyRaised, BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, -3), Selectable = true, Active = true, ZIndex = 2 }, holder)
	corner(btn, RunTheme.Radius.Panel)
	local edge = stroke(btn, c.Rarity == "Evolution" and RunTheme.Gold or RunTheme.NavyEdge, c.Rarity == "Evolution" and 3 or 2, 0)
	new("Frame", { Name = "Base", BackgroundColor3 = RunTheme.Scrim, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 3), Size = UDim2.new(1, 0, 1, -3), ZIndex = 1, Active = false }, holder)
	corner(holder.Base, RunTheme.Radius.Panel)
	-- the same cyan outline for gamepad focus as the other run buttons
	local focus = new("Frame", { Name = "Focus", BackgroundTransparency = 1, Size = UDim2.new(1, 8, 1, 8), Position = UDim2.fromOffset(-4, -4) })
	corner(focus, 14)
	stroke(focus, RunTheme.Cyan, 3, 0)
	btn.SelectionImageObject = focus

	local pad = 10
	local inner = new("Frame", { Name = "Inner", BackgroundTransparency = 1, Position = UDim2.fromOffset(pad, 8), Size = UDim2.new(1, -2 * pad, 1, -14), ZIndex = 3, Active = false }, btn)
	UIKit.list(inner, { Padding = UDim.new(0, 2) })
	-- row 1: rarity symbol + word, key cap
	local r1 = new("Frame", { Name = "Rarity", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = 1, Active = false }, inner)
	local sym = W.RaritySymbol(r1, c.Rarity, 18)
	sym.AnchorPoint = Vector2.new(0, 0.5)
	sym.Position = UDim2.new(0, 0, 0.5, 0)
	W.Text(r1, string.upper(c.RarityLabel), { Name = "RarityWord", Size = labelSize(14, 12), Font = "Label", Position = UDim2.fromOffset(24, 0), Box = UDim2.new(1, -24 - 36, 1, 0), Fit = 11, Color = rarityColor })
	local key = W.KeyCap(r1, tostring(index), { Height = 24, Width = 28, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0), ZIndex = 4 })
	key.Name = "KeyBadge"
	key.Visible = InputPrompts.Mode() ~= "Touch"
	keyBadges[index] = key
	-- row 2: icon + name
	local r2 = new("Frame", { Name = "NameRow", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 2, Active = false }, inner)
	local iconBox = new("Frame", { Name = "Icon", BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, Size = UDim2.fromOffset(32, 32), Active = false }, r2)
	corner(iconBox, 8)
	stroke(iconBox, rarityColor, 1.5, 0)
	Icons.Upgrade(iconBox, c.IconId, { Size = 26, Position = UDim2.fromOffset(3, 3), Back = RunTheme.NavyDeep })
	W.Text(r2, c.Name, { Name = "Name", Size = 20, Font = "Heading", Position = UDim2.fromOffset(40, 0), Box = UDim2.new(1, -40, 1, 0), Fit = 12, Color = RunTheme.Cream })
	-- row 3: category, slot
	local meta = {}
	if c.CategoryLabel then
		table.insert(meta, string.upper(c.CategoryLabel))
	end
	if c.RankTo and c.RankFrom then
		table.insert(meta, string.format("RANK %d → %d", c.RankFrom, c.RankTo))
	end
	if c.Slot and isStacked() then
		table.insert(meta, string.upper(c.Slot))
	end
	W.Text(inner, table.concat(meta, "  ·  "), { Name = "Category", Size = labelSize(13, 12), Font = "Label", Box = UDim2.new(1, 0, 0, UIKit.TS(labelSize(13, 12)) + 4), LayoutOrder = 3, Fit = 11, Color = RunTheme.CreamMuted })
	-- current -> next lines (at most three)
	local shown = math.min(#c.Lines, 3)
	for i = 1, shown do
		lineRow(inner, c.Lines[i], 10 + i)
	end
	-- slot, synergy
	if c.Slot and not isStacked() then
		W.Text(inner, c.Slot, { Name = "Slot", Size = labelSize(14, 12), Font = "Label", Box = UDim2.new(1, 0, 0, UIKit.TS(labelSize(14, 12)) + 4), LayoutOrder = 20, Fit = 11, Color = RunTheme.Cyan })
	end
	if c.Synergy then
		local sRows = synergyRows(c)
		local syn = new("Frame", { Name = "Synergy", BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, sRows * (UIKit.TS(labelSize(13, 12)) + 2) + 6), LayoutOrder = 21, Active = false }, inner)
		corner(syn, 6)
		stroke(syn, RunTheme.Gold, 1, 0.4)
		W.Text(syn, "SYNERGY  " .. c.Synergy, { Name = "SynergyText", Size = labelSize(13, 12), Font = "Label", Box = UDim2.new(1, -10, 1, 0), Position = UDim2.fromOffset(6, 0), Fit = 11, Color = RunTheme.Gold, Wrap = sRows > 1 })
	end

	-- states: hover, pressed, focus (the cyan outline), picked
	btn.MouseEnter:Connect(function()
		if not picked then
			btn.BackgroundColor3 = RunTheme.NavyDeep
			edge.Color = RunTheme.Cyan
		end
	end)
	btn.MouseLeave:Connect(function()
		if not picked then
			btn.BackgroundColor3 = RunTheme.NavyRaised
			edge.Color = c.Rarity == "Evolution" and RunTheme.Gold or RunTheme.NavyEdge
		end
	end)
	btn.Activated:Connect(function(input)
		RunCards.Choose(index, input)
	end)
	holder.Parent = ui.Cards
	items[index] = { Holder = holder, Hit = btn, Edge = edge, Card = c, Count = count }
	return holder
end

-- A quiet placeholder for a slot the server had nothing to put in (payload.Empty / EmptyText): the
-- first one says why in the server's words, the others just say there is nothing more. Not a button.
local function buildEmpty(order: number, w: number, first: boolean)
	local holder = new("Frame", { Name = "Empty" .. order, BackgroundTransparency = 1, Size = UDim2.fromOffset(w, cardH), LayoutOrder = order, Active = false })
	local plate = new("Frame", { Name = "Plate", BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, -3), ZIndex = 2, Active = false }, holder)
	corner(plate, RunTheme.Radius.Panel)
	stroke(plate, RunTheme.NavyEdge, 2, 0.45)
	local inner = new("Frame", { Name = "Inner", BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 12), Size = UDim2.new(1, -24, 1, -24), ZIndex = 3, Active = false }, plate)
	UIKit.list(inner, { Padding = UDim.new(0, 6), HorizontalAlignment = Enum.HorizontalAlignment.Center })
	W.Text(inner, "EMPTY SLOT", { Name = "Title", Size = 14, Font = "Label", Align = "Center", Box = UDim2.new(1, 0, 0, 20), LayoutOrder = 1, Fit = 10, Color = RunTheme.CreamMuted })
	W.Text(inner, first and emptyText or "Nothing else to offer here.", { Name = "Why", Size = 16, Font = "Body", Align = "Center", Box = UDim2.new(1, 0, 0, 64), LayoutOrder = 2, Fit = 11, Color = RunTheme.CreamMuted, Wrap = true, VAlign = "Top" })
	holder.Parent = ui.Cards
	return holder
end

local function clearCards()
	table.clear(keyBadges)
	for _, c in ipairs(ui.Cards:GetChildren()) do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	table.clear(items)
end

------------------------------------------------------------------------------------------
-- Layout (docked under the objective strip, clear of the touch controls)
------------------------------------------------------------------------------------------

function RunCards.Layout()
	if not ui.Panel or not offer then
		return
	end
	local v = kit.VirtualSize()
	local count = math.max(1, #cards + emptySlots)
	local cw = cardWidth()
	local touch = W.TouchPx(kit.Scale and kit.Scale() or 1)
	headH = math.max(HEAD_H, touch + 6)
	ui.Reroll.Instance.Size = UDim2.fromOffset(150, touch)
	ui.Reroll.Instance.Position = UDim2.new(1, -10, 0, 2)
	stacked = isStacked()
	ui.CardsList.FillDirection = stacked and Enum.FillDirection.Vertical or Enum.FillDirection.Horizontal
	ui.Cards.Position = UDim2.fromOffset(8, headH)
	if stacked then
		-- portrait: one card per row at the full width, under the health / counters / timer cluster (the
		-- objective strip, equipment, party and map are covered for the few seconds the offer is open)
		local margin = LAYOUT.MarginPhone
		local panelW = math.min(v.X - 2 * margin, 560)
		local cardW = panelW - 16
		local total, n = 0, 0
		for i = 1, #cards do
			local it = items[i]
			if it then
				local h = it.Card.NeedH or cardH
				it.Holder.Size = UDim2.fromOffset(cardW, h)
				total += h
				n += 1
			end
		end
		for _, c in ipairs(ui.Cards:GetChildren()) do
			if c:IsA("Frame") and string.sub(c.Name, 1, 5) == "Empty" then
				c.Size = UDim2.fromOffset(cardW, 84)
				total += 84
				n += 1
			end
		end
		total += math.max(0, n - 1) * 6
		ui.Cards.Size = UDim2.new(1, -16, 0, total)
		local panelH = headH + total + 10
		local top = (kit.TopBottom and kit.TopBottom() or 140) + 8
		local hud = kit.Hud
		if hud then
			top = 6
			for _, name in ipairs({ "Health", "Counters", "Timer" }) do
				local r = hud.RunRect(name)
				if r and r.H > 0 then
					top = math.max(top, r.Y + r.H + 8)
				end
			end
		end
		ui.Panel.Position = UDim2.fromOffset(math.floor((v.X - panelW) / 2 + 0.5), math.floor(top + 0.5))
		ui.Panel.Size = UDim2.fromOffset(panelW, panelH)
		return
	end
	local panelH = headH + cardH + 10
	ui.Cards.Size = UDim2.new(1, -16, 0, cardH)
	local top = (kit.TopBottom and kit.TopBottom() or 140) + 8
	-- stay between the party column and the map when the screen is wide enough to (a phone has no
	-- room: the cards then cover them for the few seconds the offer is open)
	local left, right = 0, v.X
	if kit.Avoid and not UIKit.IsCompact() then
		for _, r in ipairs(kit.Avoid()) do
			if r.Y < top + panelH and r.Y + r.H > top then
				if r.X + r.W / 2 < v.X / 2 then
					left = math.max(left, r.X + r.W + 6)
				else
					right = math.min(right, r.X - 6)
				end
			end
		end
		local fit = math.floor((right - left - 16 - (count - 1) * 8) / count)
		if fit >= 200 and fit < cw then
			cw = fit
		elseif fit < 200 then
			left, right = 0, v.X
		end
	end
	local panelW = count * cw + (count - 1) * 8 + 16
	local x = math.clamp((v.X - panelW) / 2, left, math.max(left, right - panelW))
	-- keep off the touch controls (the resting joystick, JUMP, DASH): 1. under the objective strip, 2. right
	-- under the timer (covering the strip for the few seconds the offer is open), 3. squeezed into the widest
	-- gap between them. The REVIVE button is adopted above this panel (RunInteract), so it never needs room.
	local thumbs = kit.Thumbs and kit.Thumbs() or nil
	local function blocked(t0: number, t1: number, withHud: boolean?): { { number } }
		local out = {}
		if thumbs then
			for _, name in ipairs({ "Stick", "Jump", "Dash" }) do
				local t = thumbs[name]
				if t and t.W > 0 and t.Y - 4 < t1 and t.Y + t.H + 4 > t0 then
					table.insert(out, { t.X - 6, t.X + t.W + 6 })
				end
			end
		end
		if withHud and kit.Hud then
			for _, name in ipairs({ "Health", "Party" }) do
				local r = kit.Hud.RunRect(name)
				if r and r.W > 0 and r.Y - 4 < t1 and r.Y + r.H + 4 > t0 then
					table.insert(out, { r.X - 6, r.X + r.W + 6 })
				end
			end
		end
		return out
	end
	local function hits(x0: number, x1: number, list: { { number } }): boolean
		for _, b in ipairs(list) do
			if x0 < b[2] and x1 > b[1] then
				return true
			end
		end
		return false
	end
	if hits(x, x + panelW, blocked(top, top + panelH)) then
		top = math.max((kit.TimerBottom and kit.TimerBottom() or 70) + 6, 6)
		local band = blocked(top, top + panelH, true)
		if hits(x, x + panelW, band) then
			table.sort(band, function(a, b)
				return a[1] < b[1]
			end)
			local bestL, bestR, cursor = 0, 0, left + 6
			for _, b in ipairs(band) do
				if b[1] - cursor > bestR - bestL then
					bestL, bestR = cursor, b[1]
				end
				cursor = math.max(cursor, b[2])
			end
			if (right - 6) - cursor > bestR - bestL then
				bestL, bestR = cursor, right - 6
			end
			local fit = math.floor((bestR - bestL - 16 - (count - 1) * 8) / count)
			if fit >= CFG.SqueezeCardWidth then
				cw = math.min(cw, fit)
				panelW = count * cw + (count - 1) * 8 + 16
				x = bestL + ((bestR - bestL) - panelW) / 2
			end
		end
	end
	top = math.max(top, 6)
	ui.Panel.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(top + 0.5))
	ui.Panel.Size = UDim2.fromOffset(panelW, panelH)
	ui.Reroll.Instance.Position = UDim2.new(1, -10, 0, 2)
	for _, it in pairs(items) do
		it.Holder.Size = UDim2.fromOffset(cw, cardH)
	end
	for _, c in ipairs(ui.Cards:GetChildren()) do
		if c:IsA("Frame") and string.sub(c.Name, 1, 5) == "Empty" then
			c.Size = UDim2.fromOffset(cw, cardH)
		end
	end
end

------------------------------------------------------------------------------------------
-- Show / close
------------------------------------------------------------------------------------------

local function offerSeconds(o: any): number
	local deadline = o.Deadline
	if type(deadline) ~= "number" then
		local attr = player:GetAttribute("ChoiceProtectedUntil")
		deadline = type(attr) == "number" and attr or nil
	end
	if type(deadline) == "number" then
		local ok, now = pcall(function()
			return workspace:GetServerTimeNow()
		end)
		if ok then
			return deadline - now
		end
	end
	return (tonumber(o.Seconds) or CFG.DefaultSeconds) - (os.clock() - shownAt)
end

local function rerollsLeft(o: any): number
	return math.max(0, math.floor(tonumber(o.RerollsLeft) or tonumber(o.Rerolls) or 0))
end

local function titleFor(o: any): string
	local source = o.Source
	local base
	if source == "Chest" then
		base = "CHEST REWARD"
	else
		local level = tonumber(o.Level)
		base = level and ("LEVEL " .. level) or "LEVEL UP"
	end
	local total, remaining = tonumber(o.BatchTotal), tonumber(o.BatchRemaining)
	if total and remaining and total > 1 then
		base ..= string.format("  ·  %d OF %d", total - remaining + 1, total)
	end
	if o.Kind == "PassiveOnly" then
		base ..= "  ·  PASSIVES"
	end
	return base .. "  ·  PICK ONE"
end

local function refreshReroll()
	if not offer then
		return
	end
	local n = rerollsLeft(offer)
	local pending = os.clock() < rerollPendingUntil
	local key = string.format("%d|%s|%s", n, tostring(pending), tostring(picked))
	if key == rerollKey then
		return
	end
	rerollKey = key
	ui.Reroll.SetText("REROLL", n > 0 and string.format("%d left  ·  R", n) or "None left")
	ui.Reroll.SetEnabled(n > 0 and not picked)
	ui.Reroll.SetPending(pending)
end

function RunCards.Show(payload: any)
	local first = not open or (offer and payload.OfferId ~= offer.OfferId)
	offer = payload
	cards = {}
	for i, c in ipairs(payload.Choices) do
		if type(c) == "table" then
			table.insert(cards, RunCards.Normalize(c, i))
		end
	end
	-- the status label is built at the size that comes out at 12 pt on this device (the UI scale is known by now)
	if ui.StatusSize ~= labelSize(14, 12) then
		local parent = ui.Status.Parent
		ui.Status:Destroy()
		ui.StatusSize = labelSize(14, 12)
		ui.Status = W.Text(parent, "Combat continues", { Name = "Status", Size = ui.StatusSize, Font = "Label", Position = UDim2.fromOffset(62, 29), Box = UDim2.new(0.6, -62, 0, 20), Fit = 11, Color = RunTheme.CreamMuted })
	end
	emptySlots = math.clamp(math.floor(tonumber(payload.Empty) or 0), 0, math.max(0, 3 - #cards))
	emptyText = str(payload.EmptyText) or "Nothing left to offer."
	picked = false
	rerollPendingUntil = 0
	rerollKey = ""
	if not open then
		open = true
		shownAt = os.clock()
		frozenLeft = nil
	end
	armAt = os.clock() + CFG.ArmSeconds
	clearCards()
	local cw = cardWidth()
	cardH = CARD_MIN_H
	for _, c in ipairs(cards) do
		c.NeedH = needHeight(c)
		cardH = math.max(cardH, c.NeedH)
	end
	for i, c in ipairs(cards) do
		buildCard(c, i, #cards, cw)
	end
	for k = 1, emptySlots do
		buildEmpty(#cards + k, cw, k == 1)
	end
	ui.Title.Text = titleFor(payload)
	local left = offerSeconds(payload)
	totalSeconds = math.max(1, left, tonumber(payload.Seconds) or 0)
	ui.Panel.Visible = true
	UIState.SetHold("Cards", true)
	RunCards.Layout()
	refreshReroll()
	if first and not ClientSettings.Reduced() then
		UIAnim.Pop(ui.Panel, 0, 0.9)
	end
	sound(first and "ChoiceOpen" or "CardAppear")
	-- gamepad: focus the first card
	local firstItem = items[1]
	if firstItem then
		UIKit.FocusIfGamepad(firstItem.Hit)
	end
	RunCards.Update(0)
end

function RunCards.Close()
	if not open then
		return
	end
	open = false
	offer = nil
	picked = false
	if ui.Panel then
		ui.Panel.Visible = false
	end
	UIState.SetHold("Cards", false)
	clearCards()
	local sel = GuiService.SelectedObject
	if sel and not sel.Parent then
		GuiService.SelectedObject = nil
	end
end

function RunCards.IsOpen(): boolean
	return open
end

------------------------------------------------------------------------------------------
-- Input
------------------------------------------------------------------------------------------

local function touchOk(input: any): boolean
	local rec = touches[input]
	if not rec then
		return false
	end
	local began = rec.At
	if began < shownAt + CFG.TouchArmSeconds or began < armAt - CFG.ArmSeconds + CFG.TouchArmSeconds then
		return false
	end
	if (rec.EndedAt or os.clock()) - began > CFG.TouchHoldSeconds then
		return false
	end
	return rec.Moved <= CFG.TouchSlop
end

-- May this press confirm? Not before the arm time; a touch must be a whole fresh tap.
local function armed(input: any): boolean
	if not open or picked or not offer then
		return false
	end
	if os.clock() < armAt then
		return false
	end
	if input and input.UserInputType == Enum.UserInputType.Keyboard then
		-- jump (Space), Enter and the movement keys never confirm a card: only 1 / 2 / 3 do
		local code = input.KeyCode
		if not (code == Enum.KeyCode.One or code == Enum.KeyCode.Two or code == Enum.KeyCode.Three or code == Enum.KeyCode.KeypadOne or code == Enum.KeyCode.KeypadTwo or code == Enum.KeyCode.KeypadThree or code == CFG.RerollKey) then
			return false
		end
	end
	if input and input.UserInputType == Enum.UserInputType.Touch then
		return touchOk(input)
	end
	-- a key / click held since before the cards showed never confirms
	if input and input.UserInputState == Enum.UserInputState.Begin then
		return true
	end
	return input ~= nil
end

function RunCards.Choose(index: number, input: any?)
	if not offer or not items[index] or not armed(input) then
		return
	end
	picked = true
	local it = items[index]
	sound("ChoicePick")
	it.Edge.Color = RunTheme.Gold
	it.Edge.Thickness = 4
	for i, other in pairs(items) do
		if i ~= index then
			other.Hit.BackgroundTransparency = 0.5
		end
	end
	if not ClientSettings.Reduced() then
		UIAnim.Punch(it.Holder, 0.12)
	end
	ui.Status.Text = "Picked  ·  combat continues"
	Remotes.Get("LevelUpChoose"):FireServer(index, offer.OfferId)
	local id = offer.OfferId
	-- the server answers with a close or the next set; if nothing came, release the panel
	task.delay(2.5, function()
		if open and picked and offer and offer.OfferId == id then
			RunCards.Close()
		end
	end)
end

function RunCards.Reroll(input: any?)
	if not offer or picked or rerollsLeft(offer) <= 0 or os.clock() < rerollPendingUntil or not armed(input) then
		return
	end
	rerollPendingUntil = os.clock() + 1.5
	sound("Click")
	Remotes.Get("LevelUpReroll"):FireServer(offer.OfferId)
	refreshReroll()
end

------------------------------------------------------------------------------------------
-- Per frame
------------------------------------------------------------------------------------------

function RunCards.Update(_dt: number)
	if not open or not offer then
		return
	end
	-- the deadline ring (frozen while the server holds the timer: a downed hero's choices wait)
	local held = player:GetAttribute("ChoiceTimerPaused") == true or player:GetAttribute("Downed") == true
	local left = offerSeconds(offer)
	if held then
		frozenLeft = frozenLeft or left
		left = frozenLeft
	else
		frozenLeft = nil
	end
	left = math.max(0, left)
	ring.Set(left / totalSeconds)
	local color = left <= 2.5 and RunTheme.Danger or (left <= 5 and RunTheme.Warn or RunTheme.Cyan)
	if ring.Color ~= color then
		ring.SetColor(color)
	end
	W.Set(ui.Seconds, tostring(math.ceil(left)))
	if not picked then
		local status = player:GetAttribute("Downed") == true and "Paused while you are down" or (offer.Live == false and "Game paused while you choose" or "Combat continues")
		local pending = tonumber(player:GetAttribute("PendingChoices")) or 0
		if pending > 1 then
			status ..= string.format("  ·  %d more waiting", pending - 1)
		end
		W.Set(ui.Status, status)
	end
	-- the key badges follow the device
	local showKeys = InputPrompts.Mode() ~= "Touch"
	for _, badge in pairs(keyBadges) do
		if badge.Visible ~= showKeys then
			badge.Visible = showKeys
		end
	end
	refreshReroll()
end

function RunCards.Elements(): { [string]: any }
	return { Panel = ui.Panel, Cards = items, Ring = ring, Reroll = ui.Reroll, Title = ui.Title, Status = ui.Status, Seconds = ui.Seconds }
end

return RunCards
