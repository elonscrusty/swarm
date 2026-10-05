--[[
	ExploreUI.lua
	Client side of the EXPLORE features (docs/features/EXPLORE.md; server SecretRoom.lua,
	Merchant.lua, Rescue.lua). Its own ScreenGui and world billboards: nothing in UIBuilder
	or Hud changes.

	  markers    a small pill over each EXPLORE model in workspace.SwarmEvents (attribute
	             EventKind = SecretRoom | Merchant | Rescue), shown within MARKER_RANGE studs:
	               cracked wall  "CRACKED WALL" / "Attack it to break it" + a crack bar
	               merchant      "MERCHANT" / "3 items for run gold"
	               villager      "OPTIONAL" tag + "LOST VILLAGER" / "Lead me to the portal!"
	                             + an HP bar while it follows
	  shimmer    the cracked wall's crack parts (named "Crack") pulse locally (the hint)
	  merchant   the shop panel while you stand at the cart: your own 3 offers (remote
	             MerchantStock), each with its tile, name, rarity, price and BUY / SOLD. The
	             price is shown with ItemData.PlayerPrice and your GoldMult attribute, like
	             the loot prompt (LootUI), so it is the price the server charges; red when
	             you can't afford it, and a press then shows "NEED N" on the purse
	             (Hud.SetPurseHint). BUY sends MerchantBuy(merchantId, slot); the server
	             decides. Keys 1 / 2 / 3 buy on a keyboard.
	Everything hides outside a run and while a panel covers the HUD (UIState.Covered).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local UIKit = require(script.Parent.UIKit)
local UIState = require(script.Parent.UIState)
local UIAnim = require(script.Parent.UIAnim)
local Hud = require(script.Parent.Hud)

local ExploreUI = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local R = Theme.ItemRarity
local FLAT = Vector3.new(1, 0, 1)
local MARKER_RANGE = 140 -- studs: markers show this close
local KINDS = { SecretRoom = true, Merchant = true, Rescue = true }
local CARD_H = 150 -- offer card height (compact: CARD_H_COMPACT, no tile)
local CARD_H_COMPACT = 112
local compact = false

type Marker = { Model: Model, Billboard: BillboardGui, Title: TextLabel, Sub: TextLabel, Tag: TextLabel, Bar: Frame, Fill: Frame, Cracks: { BasePart } }

local markers: { [Model]: Marker } = {}
local stock: { [string]: any } = { Id = 0, Items = {} }
local gui: ScreenGui? = nil
local panel: Frame? = nil
local cards: { { [string]: any } } = {}
local panelFor = 0 -- merchant id the panel was built for
local clock = 0

local function inRun(): boolean
	return player:GetAttribute("InRun") == true and Remotes.State():GetAttribute("Phase") == "Running"
end

local function myRoot(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return (root and root:IsA("BasePart")) and root or nil
end

------------------------------------------------------------------------------------------
-- Markers
------------------------------------------------------------------------------------------

local function makeMarker(m: Model): Marker?
	local anchor = m:FindFirstChild("Anchor")
	if not anchor or not anchor:IsA("BasePart") then
		return nil
	end
	local bb = UIKit.new("BillboardGui", { Name = "ExploreMarker", Adornee = anchor, Size = UDim2.fromOffset(190, 64), StudsOffsetWorldSpace = Vector3.new(0, 1, 0), AlwaysOnTop = true, MaxDistance = MARKER_RANGE, Enabled = false, ResetOnSpawn = false }, player:WaitForChild("PlayerGui")) :: BillboardGui
	local face = UIKit.new("Frame", { Name = "Face", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.15, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromOffset(180, 46) }, bb)
	UIKit.corner(face, Theme.Radius.M)
	UIKit.stroke(face, P.gold_400, 1.5, 0.25)
	local title = UIKit.text(face, "Label", "", { Name = "Title", Position = UDim2.fromOffset(8, 3), Size = UDim2.new(1, -16, 0, 18), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200 }, 14)
	local sub = UIKit.text(face, "Caption", "", { Name = "Sub", Position = UDim2.fromOffset(8, 21), Size = UDim2.new(1, -16, 0, 14), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_200 }, 12)
	local bar = UIKit.new("Frame", { Name = "Bar", BackgroundColor3 = P.slate_800, BorderSizePixel = 0, Position = UDim2.new(0, 12, 1, -7), Size = UDim2.new(1, -24, 0, 4), Visible = false }, face)
	UIKit.corner(bar, 999)
	local fill = UIKit.new("Frame", { Name = "Fill", BackgroundColor3 = P.gold_300, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, bar)
	UIKit.corner(fill, 999)
	local tag = UIKit.text(bb, "Caption", "OPTIONAL", { Name = "Tag", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(84, 16), TextXAlignment = Enum.TextXAlignment.Center, BackgroundColor3 = P.gold_500, BackgroundTransparency = 0, TextColor3 = P.slate_950, Visible = false }, 11)
	UIKit.corner(tag, 999)
	local cracks = {}
	for _, d in ipairs(m:GetChildren()) do
		if d:IsA("BasePart") and d.Name == "Crack" then
			table.insert(cracks, d)
		end
	end
	return { Model = m, Billboard = bb, Title = title, Sub = sub, Tag = tag, Bar = bar, Fill = fill, Cracks = cracks }
end

local function set(obj: Instance, key: string, value: any)
	if (obj :: any)[key] ~= value then
		(obj :: any)[key] = value
	end
end

local function fillMarker(mk: Marker)
	local m = mk.Model
	local kind = m:GetAttribute("EventKind")
	local st = m:GetAttribute("State")
	local frac = tonumber(m:GetAttribute("HPFrac"))
	local title, sub, bar, tag = "", "", false, false
	if kind == "SecretRoom" then
		if st == "Open" then
			title = "SECRET ALCOVE"
			sub = m:GetAttribute("Reward") == "Challenge" and "Elites inside!" or "A free cache inside"
		else
			title = "CRACKED WALL"
			sub = "Attack it to break it"
			bar = frac ~= nil and frac < 1
		end
	elseif kind == "Merchant" then
		title = "MERCHANT"
		sub = "3 items for run gold"
	elseif kind == "Rescue" then
		tag = st == "Waiting" or st == "Following"
		if st == "Following" then
			title = "LOST VILLAGER"
			sub = "Lead me to the portal!"
			bar = true
		elseif st == "Lost" then
			title = "VILLAGER LOST"
			sub = ""
		else
			title = "LOST VILLAGER"
			sub = "Help! Come find me"
		end
	end
	set(mk.Title, "Text", title)
	set(mk.Sub, "Text", sub)
	set(mk.Tag, "Visible", tag)
	set(mk.Bar, "Visible", bar)
	if bar then
		local f = math.clamp(frac or 1, 0, 1)
		set(mk.Fill, "Size", UDim2.fromScale(f, 1))
		set(mk.Fill, "BackgroundColor3", kind == "Rescue" and (f > 0.35 and P.moss_300 or P.crimson_300) or P.gold_300)
	end
end

local function track(m: Instance)
	if not m:IsA("Model") or markers[m] then
		return
	end
	local kind = m:GetAttribute("EventKind")
	if not KINDS[kind] then
		return
	end
	local mk = makeMarker(m)
	if mk then
		markers[m] = mk
	end
end

local function untrack(m: Instance)
	local mk = markers[m :: Model]
	if mk then
		markers[m :: Model] = nil
		mk.Billboard:Destroy()
	end
end

------------------------------------------------------------------------------------------
-- Merchant panel
------------------------------------------------------------------------------------------

local function priceOf(item): number
	return ItemData.PlayerPrice(tonumber(item.Price) or 0, tonumber(player:GetAttribute("GoldMult")) or 1)
end

local function buy(slot: number)
	local item = stock.Items and stock.Items[slot]
	local card = cards[slot]
	if not item or item.Sold or not card or not UIState.WorldInputAllowed() then
		return
	end
	local price = priceOf(item)
	if (tonumber(player:GetAttribute("RunGold")) or 0) < price then
		UIAnim.Punch(card.Price, 0.3)
		Hud.SetPurseHint(price, false, true)
		return
	end
	Remotes.Get("MerchantBuy"):FireServer(stock.Id, slot)
end

local function buildPanel(root: Frame)
	local p = UIKit.new("Frame", { Name = "MerchantPanel", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.06, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -150), Size = UDim2.fromOffset(420, CARD_H + 42), Visible = false }, root) :: Frame
	UIKit.corner(p, Theme.Radius.L)
	UIKit.stroke(p, P.gold_400, 1.5, 0.2)
	UIKit.text(p, "Label", "MERCHANT", { Name = "Title", Position = UDim2.fromOffset(12, 6), Size = UDim2.new(0.5, -12, 0, 20), TextColor3 = P.gold_200 }, 16)
	UIKit.text(p, "Caption", "Your own offers · run gold", { Name = "Note", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 8), Size = UDim2.new(0.5, -12, 0, 16), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.ivory_300 }, 12)
	local row = UIKit.new("Frame", { Name = "Row", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 34), Size = UDim2.new(1, -16, 0, CARD_H) }, p)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6) })
	for i = 1, Config.Explore.Merchant.Slots do
		local card = UIKit.new("Frame", { Name = "Offer" .. i, LayoutOrder = i, BackgroundColor3 = P.slate_900, BorderSizePixel = 0, Size = UDim2.new(1 / 3, -4, 1, 0) }, row)
		UIKit.corner(card, Theme.Radius.M)
		local stroke = UIKit.stroke(card, P.ivory_200, 1.5, 0.4)
		local tileBox = UIKit.new("Frame", { Name = "TileBox", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(36, 36) }, card)
		local name = UIKit.text(card, "Label", "", { Name = "ItemName", Position = UDim2.fromOffset(4, 44), Size = UDim2.new(1, -8, 0, 16), TextXAlignment = Enum.TextXAlignment.Center, TextScaled = true }, 13)
		local rarity = UIKit.text(card, "Caption", "", { Name = "Rarity", Position = UDim2.fromOffset(4, 60), Size = UDim2.new(1, -8, 0, 13), TextXAlignment = Enum.TextXAlignment.Center }, 11)
		local desc = UIKit.text(card, "Caption", "", { Name = "Desc", Position = UDim2.fromOffset(4, 72), Size = UDim2.new(1, -8, 0, 26), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, TextScaled = true, TextColor3 = P.ivory_200 }, 11)
		local price = UIKit.text(card, "Label", "", { Name = "Price", Position = UDim2.fromOffset(4, 98), Size = UDim2.new(1, -8, 0, 16), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200 }, 14)
		local btn = UIKit.Button(card, { Name = "Buy", Title = "BUY", Kind = "Primary", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.new(1, -12, 0, 34), Shadow = false, OnClick = function() buy(i) end })
		cards[i] = { Card = card, Stroke = stroke, TileBox = tileBox, Name = name, Rarity = rarity, Desc = desc, Price = price, Button = btn, Shown = "" }
	end
	return p
end

local function fillCards()
	for i, card in ipairs(cards) do
		local item = stock.Items and stock.Items[i]
		local def = item and ItemData.Items[item.Id]
		card.Card.Visible = def ~= nil
		if def then
			local key = item.Id .. (item.Sold and ":sold" or "")
			if card.Shown ~= key then
				card.Shown = key
				for _, ch in ipairs(card.TileBox:GetChildren()) do
					ch:Destroy()
				end
				UIKit.Tile(card.TileBox, { Id = item.Id, Size = 36 })
				local r = R[def.Rarity] or R.Common
				card.Name.Text = def.Name
				card.Rarity.Text = r.Label
				card.Desc.Text = def.Text or ""
				card.Rarity.TextColor3 = r.Color
				card.Stroke.Color = r.Color
				card.Button.SetText(item.Sold and "SOLD" or "BUY")
				card.Button.SetEnabled(not item.Sold)
			end
			local price = priceOf(item)
			local afford = (tonumber(player:GetAttribute("RunGold")) or 0) >= price
			set(card.Price, "Text", item.Sold and "Bought" or (UIKit.formatNumber(price) .. " gold"))
			set(card.Price, "TextColor3", (item.Sold or afford) and P.gold_200 or P.crimson_300)
		end
	end
end

local function merchantModel(): Model?
	local f = workspace:FindFirstChild("SwarmEvents")
	local m = f and f:FindFirstChild("Merchant")
	return (m and m:IsA("Model")) and m or nil
end

-- The main gui's root (UIBuilder: "Root" with a UIScale), to place the panel between the
-- HUD's top cluster and its bottom bar in real pixels.
local function hudSpace(myRoot: GuiObject): (number?, number?)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return nil, nil
	end
	for _, g in ipairs(pg:GetChildren()) do
		local r = g:IsA("ScreenGui") and g ~= gui and g:FindFirstChild("Root")
		local sc = r and r:FindFirstChildOfClass("UIScale")
		if r and sc and r:FindFirstChild("HUD", true) then
			local off = (r :: GuiObject).AbsolutePosition.Y - myRoot.AbsolutePosition.Y
			return off + Hud.TopBottom() * sc.Scale, off + Hud.BarTop() * sc.Scale
		end
	end
	return nil, nil
end

local function placeCard(card, small: boolean)
	local y = small and 4 or 44
	card.TileBox.Visible = not small
	card.Name.Position = UDim2.fromOffset(4, y)
	card.Rarity.Position = UDim2.fromOffset(4, y + 16)
	card.Desc.Position = UDim2.fromOffset(4, y + 28)
	card.Price.Position = UDim2.fromOffset(4, y + 54)
	card.Button.Instance.Size = UDim2.new(1, -12, 0, small and 30 or 34)
end

local function layoutPanel(p: Frame)
	local holder = p.Parent :: GuiObject
	local w, h = holder.AbsoluteSize.X, holder.AbsoluteSize.Y
	if w < 50 then
		local cam = workspace.CurrentCamera
		w, h = cam and cam.ViewportSize.X or 800, cam and cam.ViewportSize.Y or 600
	end
	local width = math.min(420, w - 32)
	local bottom = h - 150
	local top = 0
	if h > w then
		bottom = h - 210 -- portrait: above the JUMP button
	else
		local t, b = hudSpace(holder)
		if t and b and b > t + 100 then
			top, bottom = t + 6, b - 6
		end
	end
	local small = bottom - top < CARD_H + 42
	if small ~= compact or p:GetAttribute("Laid") ~= true then
		compact = small
		p:SetAttribute("Laid", true)
		for _, card in ipairs(cards) do
			placeCard(card, small)
		end
	end
	local cardH = small and CARD_H_COMPACT or CARD_H
	set(p, "Size", UDim2.fromOffset(width, cardH + 42))
	local row = p:FindFirstChild("Row")
	if row then
		set(row, "Size", UDim2.new(1, -16, 0, cardH))
	end
	set(p, "Position", UDim2.fromOffset(w / 2, bottom))
	set(p, "AnchorPoint", Vector2.new(0.5, 1))
end

------------------------------------------------------------------------------------------
-- Per frame
------------------------------------------------------------------------------------------

local scanTimer = 0

local function update(dt: number)
	clock += dt
	-- new EXPLORE models (scanned, so one whose parts arrive late is picked up next time)
	scanTimer -= dt
	if scanTimer <= 0 then
		scanTimer = 0.5
		local events = workspace:FindFirstChild("SwarmEvents")
		if events then
			for _, m in ipairs(events:GetChildren()) do
				track(m)
			end
		end
	end
	local on = inRun() and not UIState.Covered()
	local root = myRoot()
	for m, mk in pairs(markers) do
		if not m.Parent then
			untrack(m)
		else
			local pos = m:GetAttribute("Pos")
			local show = on and typeof(pos) == "Vector3" and m:GetAttribute("State") ~= "Saved"
			set(mk.Billboard, "Enabled", show)
			if show then
				fillMarker(mk)
			end
			-- the hint shimmer on a sealed wall
			if #mk.Cracks > 0 and m:GetAttribute("State") == "Sealed" then
				local t = 0.15 + 0.35 * (0.5 + 0.5 * math.sin(clock * 3.2))
				for _, c in ipairs(mk.Cracks) do
					if c.Parent then
						c.Transparency = t
					end
				end
			end
		end
	end
	-- the shop panel
	local p = panel
	if not p then
		return
	end
	local cart = merchantModel()
	local cartId = cart and tonumber(cart:GetAttribute("MerchantId")) or 0
	local pos = cart and cart:GetAttribute("Pos")
	local radius = cart and tonumber(cart:GetAttribute("Radius")) or 0
	local near = on and root ~= nil and typeof(pos) == "Vector3" and ((root.Position - pos) * FLAT).Magnitude <= radius
	local show = near and stock.Id ~= 0 and stock.Id == cartId and player:GetAttribute("Paused") ~= true
	if show then
		if panelFor ~= cartId then
			panelFor = cartId
			for _, card in ipairs(cards) do
				card.Shown = ""
			end
		end
		layoutPanel(p)
		fillCards()
	end
	set(p, "Visible", show)
	if gui then
		set(gui, "Enabled", inRun())
	end
end

-- Tests / scenes: the stock the panel shows.
function ExploreUI.Stock(): { [string]: any }
	return stock
end

function ExploreUI.Init()
	if gui then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = UIKit.new("ScreenGui", { Name = "ExploreUI", ResetOnSpawn = false, IgnoreGuiInset = true, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, DisplayOrder = 9, Enabled = false }, playerGui) :: ScreenGui
	gui = screen
	local root = UIKit.new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, screen)
	panel = buildPanel(root)
	Remotes.Get("MerchantStock").OnClientEvent:Connect(function(data)
		if type(data) ~= "table" or type(data.Id) ~= "number" then
			return
		end
		local items = {}
		if type(data.Items) == "table" then
			for i, it in ipairs(data.Items) do
				if type(it) == "table" and type(it.Id) == "string" and ItemData.Items[it.Id] then
					items[i] = { Id = it.Id, Rarity = it.Rarity, Price = tonumber(it.Price) or 0, Sold = it.Sold == true }
				end
			end
		end
		stock = { Id = data.Id, Items = items }
		for _, card in ipairs(cards) do
			card.Shown = ""
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or UserInputService:GetFocusedTextBox() or not (panel and panel.Visible) then
			return
		end
		local slot = input.KeyCode == Enum.KeyCode.One and 1 or input.KeyCode == Enum.KeyCode.Two and 2 or input.KeyCode == Enum.KeyCode.Three and 3 or nil
		if slot then
			buy(slot)
		end
	end)
	RunService.RenderStepped:Connect(update)
end

return ExploreUI
