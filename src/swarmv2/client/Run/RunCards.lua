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
local cardH = CARD_MIN_H -- the tallest card's content (set per offer)

-- Height one card needs for its rows (rarity, name, category, up to three lines, slot, synergy).
local function needHeight(c: any): number
	local rows = { 24, 34, 18 }
	for _ = 1, math.min(#c.Lines, 3) do
		table.insert(rows, 21)
	end
	if c.Slot then
		table.insert(rows, 20)
	end
	if c.Synergy then
		table.insert(rows, 22)
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
	ui.Status = W.Text(face, "Combat continues", { Name = "Status", Size = 14, Font = "Label", Position = UDim2.fromOffset(62, 29), Box = UDim2.new(0.5, -62, 0, 20), Fit = 10, Color = RunTheme.CreamMuted })
	ui.Cards = new("Frame", { Name = "Cards", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, HEAD_H), Size = UDim2.new(1, -16, 0, CARD_MIN_H), Active = false }, face)
	UIKit.list(ui.Cards, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Top, Padding = UDim.new(0, 8) })
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
	local row = new("Frame", { Name = "Line", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 21), LayoutOrder = order, Active = false }, parent)
	if line.Text then
		W.Text(row, line.Text, { Name = "Text", Size = 16, Font = "Body", Box = UDim2.fromScale(1, 1), Fit = 11, Color = RunTheme.Cream })
		return
	end
	local label = line.Label
	if line.From and line.To then
		-- "Damage  12 -> 14": the label, the current value muted, an arrow, the next value bright
		local text = string.format('%s<font color="%s">%s</font>  →  <font color="%s"><b>%s</b></font>', label and (label .. "   ") or "", UIKit.hex(RunTheme.CreamMuted), line.From, UIKit.hex(RunTheme.Gold), line.To)
		W.Text(row, text, { Name = "Change", Size = 16, Font = "Body", Box = UDim2.fromScale(1, 1), Fit = 11, Color = RunTheme.Cream, RichText = true })
	else
		local value = line.To or line.From or ""
		W.Text(row, (label and (label .. "  ") or "") .. tostring(value), { Name = "Stat", Size = 16, Font = "Body", Box = UDim2.fromScale(1, 1), Fit = 11, Color = RunTheme.Cream })
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
	W.Text(r1, string.upper(c.RarityLabel), { Name = "RarityWord", Size = 14, Font = "Label", Position = UDim2.fromOffset(24, 0), Box = UDim2.new(1, -24 - 36, 1, 0), Fit = 10, Color = rarityColor })
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
	W.Text(inner, table.concat(meta, "  ·  "), { Name = "Category", Size = 13, Font = "Label", Box = UDim2.new(1, 0, 0, 18), LayoutOrder = 3, Fit = 9, Color = RunTheme.CreamMuted })
	-- current -> next lines (at most three)
	local shown = math.min(#c.Lines, 3)
	for i = 1, shown do
		lineRow(inner, c.Lines[i], 10 + i)
	end
	-- slot, synergy
	if c.Slot then
		W.Text(inner, c.Slot, { Name = "Slot", Size = 14, Font = "Label", Box = UDim2.new(1, 0, 0, 20), LayoutOrder = 20, Fit = 10, Color = RunTheme.Cyan })
	end
	if c.Synergy then
		local syn = new("Frame", { Name = "Synergy", BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 22), LayoutOrder = 21, Active = false }, inner)
		corner(syn, 6)
		stroke(syn, RunTheme.Gold, 1, 0.4)
		W.Text(syn, "SYNERGY  " .. c.Synergy, { Name = "SynergyText", Size = 13, Font = "Label", Box = UDim2.new(1, -10, 1, 0), Position = UDim2.fromOffset(6, 0), Fit = 9, Color = RunTheme.Gold })
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
	local count = math.max(1, #cards)
	local cw = cardWidth()
	local panelH = HEAD_H + cardH + 10
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
	-- keep off the touch controls: above them when the panel would sit on one
	local thumbs = kit.Thumbs and kit.Thumbs() or nil
	if thumbs then
		for _, name in ipairs({ "Stick", "Jump", "Dash" }) do
			local t = thumbs[name]
			if t and x < t.X + t.W + 4 and x + panelW > t.X - 4 and top + panelH > t.Y - 4 and top < t.Y + t.H then
				top = math.max((kit.TimerBottom and kit.TimerBottom() or 70) + 6, t.Y - 6 - panelH)
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
		cardH = math.max(cardH, needHeight(c))
	end
	for i, c in ipairs(cards) do
		buildCard(c, i, #cards, cw)
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
		local status = player:GetAttribute("Downed") == true and "Paused while you are down" or "Combat continues"
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
