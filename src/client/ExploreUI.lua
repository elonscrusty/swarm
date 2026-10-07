--[[
	ExploreUI.lua
	Client side of the EXPLORE features (docs/features/EXPLORE.md; server SecretRoom.lua,
	Merchant.lua, Rescue.lua). Its own ScreenGui and world billboards: nothing in UIBuilder
	or Hud changes.

	  markers    a small pill over each EXPLORE model in workspace.SwarmEvents (attribute
	             EventKind = SecretRoom | Merchant | Rescue), shown within MARKER_RANGE studs:
	               cracked wall  "CRACKED WALL" / "Attack it to break it" + a crack bar
	               merchant      "MERCHANT" / "3 items for run gold"
	               villager      a small label (120 x 34): "OPTIONAL" tag, the name and one
	                             short status ("Find me" / "Following you" / why it can't
	                             start yet) + an HP bar while it follows; a speech line
	                             (model Say / SaySeq: found, falling behind, delivered)
	                             replaces the status for SAY_SECONDS. Delivered = only that
	                             last line, then nothing.
	  shimmer    the cracked wall's crack parts (named "Crack") pulse locally (the hint)
	  merchant   the shop panel while you stand at the cart: "MERCHANT", your run gold
	             ("RUN GOLD 27") and a close X; your own 3 offers (remote MerchantStock),
	             each with its tile, name, rarity, effect, price and BUY / SOLD. The price
	             is shown with ItemData.PlayerPrice and your GoldMult attribute, like the
	             loot prompt (LootUI), so it is the price the server charges. An offer you
	             can't afford has a dimmed button "NEED 36 MORE" (price minus run gold,
	             live as gold comes in) and a red price; when none is affordable the foot
	             line says how to earn gold. BUY sends MerchantBuy(merchantId, slot); the
	             server decides (range, slot, wallet, sold-before-grant) and answers with
	             a fresh MerchantStock; a second press of the same offer is ignored until
	             that answer (at least 0.5 s, at most 2 s). X closes the panel until you
	             walk out of the cart's range and back. Keys 1 / 2 / 3 buy on a keyboard.
	             Gamepad: D-pad left / right picks an offer (gold rim, "X BUY"), X buys it;
	             no GUI selection, so the left stick keeps moving the hero. Not while the
	             ping wheel is open or a chest prompt owns X (LootUI), and only while
	             UIState.WorldInputAllowed(). Its ScreenGui draws over the HUD and notice
	             pills (DisplayOrder 11) and it sits under the banner lane
	             (Hud.BannerLane); while it shows it is a UIState side panel, so the
	             portal edge marker hides, and the merchant's own world label fades out.
	World labels fade (WorldLabelFade) while they would sit on the HUD, the minimap, the
	banner or the open panel. Everything hides outside a run and while any panel is open
	(UIState.Owner: level-up, reward, portal choice, run menu ...).
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
local LootUI = require(script.Parent.LootUI)
local FeatureHud = require(script.Parent.FeatureHud)
local WorldLabelFade = require(script.Parent.WorldLabelFade)

local ExploreUI = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local R = Theme.ItemRarity
local FLAT = Vector3.new(1, 0, 1)
local MARKER_RANGE = 140 -- studs: markers show this close
local KINDS = { SecretRoom = true, Merchant = true, Rescue = true }
local CARD_H = 158 -- offer card height (compact: CARD_H_COMPACT, no tile)
local CARD_H_COMPACT = 100
local HEAD_H = 38 -- title row: MERCHANT, RUN GOLD, close X
local FOOT_H = 20 -- the foot line under the offers
local PENDING_MIN, PENDING_MAX = 0.5, 2 -- a sent buy blocks its offer this long (seconds)
local compact = false

local SAY_SECONDS = 2.5 -- the villager's speech line replaces its status this long

type Marker = { Model: Model, Billboard: BillboardGui, Face: Frame, Title: TextLabel, Sub: TextLabel, Tag: TextLabel, Bar: Frame, Fill: Frame, Cracks: { BasePart }, Alpha: number, Applied: number, SaySeq: number?, SayUntil: number? }

local markers: { [Model]: Marker } = {}
local stock: { [string]: any } = { Id = 0, Items = {} }
local gui: ScreenGui? = nil
local panel: Frame? = nil
local cards: { { [string]: any } } = {}
local panelFor = 0 -- merchant id the panel was built for
local padSlot = 1 -- gamepad: the highlighted offer
local clock = 0
local pending: { [number]: number } = {} -- slot -> clock when its buy was sent
local dismissedFor = 0 -- merchant id closed with X (until the player walks away)
local balance: TextLabel? = nil
local footLine: TextLabel? = nil

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
	-- the villager walks among the heroes all escort long: a small label (name + one status),
	-- not the 180 x 46 pill of the static merchant / wall
	local small = m:GetAttribute("EventKind") == "Rescue"
	local fw, fh = small and 120 or 180, small and 34 or 46
	local bb = UIKit.new("BillboardGui", { Name = "ExploreMarker", Adornee = anchor, Size = UDim2.fromOffset(fw + 10, fh + (small and 16 or 18)), StudsOffsetWorldSpace = Vector3.new(0, 5, 0), AlwaysOnTop = true, MaxDistance = MARKER_RANGE, Enabled = false, ResetOnSpawn = false }, player:WaitForChild("PlayerGui")) :: BillboardGui
	local face = UIKit.new("Frame", { Name = "Face", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.15, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1), Size = UDim2.fromOffset(fw, fh) }, bb)
	UIKit.corner(face, Theme.Radius.M)
	UIKit.stroke(face, P.gold_400, small and 1 or 1.5, 0.25)
	local title = UIKit.text(face, "Label", "", { Name = "Title", Position = UDim2.fromOffset(6, small and 2 or 3), Size = UDim2.new(1, -12, 0, small and 14 or 18), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200, TextTruncate = Enum.TextTruncate.AtEnd }, small and 12 or 14)
	local sub = UIKit.text(face, "Caption", "", { Name = "Sub", Position = UDim2.fromOffset(6, small and 16 or 21), Size = UDim2.new(1, -12, 0, small and 12 or 14), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_200, TextTruncate = Enum.TextTruncate.AtEnd }, small and 11 or 12)
	local bar = UIKit.new("Frame", { Name = "Bar", BackgroundColor3 = P.slate_800, BorderSizePixel = 0, Position = UDim2.new(0, 10, 1, small and -4 or -7), Size = UDim2.new(1, -20, 0, small and 3 or 4), Visible = false }, face)
	UIKit.corner(bar, 999)
	local fill = UIKit.new("Frame", { Name = "Fill", BackgroundColor3 = P.gold_300, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, bar)
	UIKit.corner(fill, 999)
	local tag = UIKit.text(bb, "Caption", "OPTIONAL", { Name = "Tag", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromOffset(small and 64 or 84, small and 14 or 16), TextXAlignment = Enum.TextXAlignment.Center, BackgroundColor3 = P.gold_500, BackgroundTransparency = 0, TextColor3 = P.slate_950, Visible = false }, small and 10 or 11)
	UIKit.corner(tag, 999)
	local cracks = {}
	for _, d in ipairs(m:GetChildren()) do
		if d:IsA("BasePart") and d.Name == "Crack" then
			table.insert(cracks, d)
		end
	end
	return { Model = m, Billboard = bb, Face = face, Title = title, Sub = sub, Tag = tag, Bar = bar, Fill = fill, Cracks = cracks, Alpha = 0, Applied = 0, SaySeq = tonumber(m:GetAttribute("SaySeq")) or 0, SayUntil = nil }
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
		-- name + one short status; a fresh speech line (Say / SaySeq) replaces the status
		local seq = tonumber(m:GetAttribute("SaySeq")) or 0
		if seq ~= (mk.SaySeq or 0) then
			mk.SaySeq = seq
			mk.SayUntil = clock + SAY_SECONDS
		end
		local speech = (mk.SayUntil and clock < mk.SayUntil) and tostring(m:GetAttribute("Say") or "") or ""
		local blocked = tostring(m:GetAttribute("Blocked") or "")
		tag = st == "Waiting" or st == "Following"
		if st == "Following" then
			title = "VILLAGER"
			sub = "Following you"
			bar = true
		elseif st == "Lost" then
			title = "VILLAGER LOST"
			sub = ""
		elseif st == "Saved" then
			title = "VILLAGER"
			tag = false
		else
			title = "LOST VILLAGER"
			sub = blocked ~= "" and blocked or "Help! Find me"
		end
		if speech ~= "" then
			sub = "\"" .. speech .. "\""
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

-- World pills sit under every ScreenGui: when the default spot (5 studs over the anchor)
-- lands under the HUD's top cluster (portrait: timer, objective, vitals, abilities), the
-- pill slides toward the camera (down the screen) in 3-stud steps until it is clear. If it
-- still touches the HUD, the minimap, the banner or an open panel there, it fades out
-- (WorldLabelFade) instead of popping. Returns whether it should be hidden.
local function clearOfHud(mk: Marker): boolean
	local cam = workspace.CurrentCamera
	local anchor = mk.Billboard.Adornee :: any
	if not cam or not anchor then
		return false
	end
	local look = cam.CFrame.LookVector * FLAT
	local back = look.Magnitude > 0.01 and -look.Unit or Vector3.zero
	local rects = WorldLabelFade.Rects()
	local base = Vector3.new(0, 5, 0)
	local chosen = base
	local hit = false
	for k = 0, 24, 3 do
		local off = base + back * k
		local sp, onScreen = cam:WorldToScreenPoint(anchor.Position + off)
		chosen = off
		if not onScreen then
			hit = false
			break
		end
		-- the face (180 x 46 px; the villager's 120 x 34), its bottom 32 px under the point
		local half = mk.Face.Size.X.Offset / 2
		hit = WorldLabelFade.Hits(sp.X - half, sp.Y + 32 - mk.Face.Size.Y.Offset, sp.X + half, sp.Y + 32, rects)
		if not hit then
			break
		end
	end
	set(mk.Billboard, "StudsOffsetWorldSpace", chosen)
	return hit
end

-- The pill's fade (0 shown .. 1 gone): face, rim, texts, tag and bar together.
local function applyFade(mk: Marker)
	local a = mk.Alpha
	if mk.Applied == a then
		return
	end
	mk.Applied = a
	mk.Face.BackgroundTransparency = 0.15 + 0.85 * a
	local stroke = mk.Face:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = 0.25 + 0.75 * a
	end
	mk.Title.TextTransparency = a
	mk.Sub.TextTransparency = a
	mk.Tag.TextTransparency = a
	mk.Tag.BackgroundTransparency = a
	mk.Bar.BackgroundTransparency = a
	mk.Fill.BackgroundTransparency = a
end

------------------------------------------------------------------------------------------
-- Merchant panel
------------------------------------------------------------------------------------------

local function priceOf(item): number
	return ItemData.PlayerPrice(tonumber(item.Price) or 0, tonumber(player:GetAttribute("GoldMult")) or 1)
end

local function wallet(): number
	return tonumber(player:GetAttribute("RunGold")) or 0
end

local function buy(slot: number)
	local item = stock.Items and stock.Items[slot]
	local card = cards[slot]
	if not item or item.Sold or not card or not UIState.WorldInputAllowed() then
		return
	end
	-- a double tap: the first press is still on its way (the server answers every buy
	-- with a fresh MerchantStock, which clears this); never a second request meanwhile
	local sent = pending[slot]
	if sent and clock - sent < PENDING_MAX then
		return
	end
	local price = priceOf(item)
	if wallet() < price then
		UIAnim.Punch(card.Price, 0.3)
		Hud.SetPurseHint(price, false, true)
		return
	end
	pending[slot] = clock
	Remotes.Get("MerchantBuy"):FireServer(stock.Id, slot)
end

local function usingPad(): boolean
	local last = UserInputService:GetLastInputType()
	return last == Enum.UserInputType.Gamepad1 or last == Enum.UserInputType.Gamepad2
end

-- Offers the gamepad can pick: shown and not sold.
local function padSlots(): { number }
	local out = {}
	for i, card in ipairs(cards) do
		local item = stock.Items and stock.Items[i]
		if item and not item.Sold and card.Card.Visible then
			table.insert(out, i)
		end
	end
	return out
end

-- Moves the highlight by `dir` (0 = keep it on a buyable offer).
local function padMove(dir: number)
	local list = padSlots()
	if #list == 0 then
		return
	end
	local at = table.find(list, padSlot)
	if not at then
		padSlot = list[1]
		return
	end
	padSlot = list[(at - 1 + dir) % #list + 1]
end

-- Each offer's button: SOLD; "NEED 36 MORE" dimmed while you can't afford it; BUY (a
-- gamepad's highlighted offer: "X  BUY", the gold rim; X on a dear one punches its price).
local function refreshButtons()
	local pad = usingPad()
	if pad then
		padMove(0)
	end
	local gold = wallet()
	for i, card in ipairs(cards) do
		local item = stock.Items and stock.Items[i]
		local on = pad and i == padSlot and item ~= nil and not item.Sold
		local def = item and ItemData.Items[item.Id]
		local r = def and (R[def.Rarity] or R.Common)
		set(card.Stroke, "Thickness", on and 3 or 1.5)
		set(card.Stroke, "Transparency", on and 0 or 0.4)
		set(card.Stroke, "Color", on and P.gold_300 or (r and r.Color or P.ivory_200))
		local short = item and not item.Sold and math.max(0, priceOf(item) - gold) or 0
		local label
		if not item or item.Sold then
			label = "SOLD"
		elseif on then
			label = "X  BUY"
		elseif short > 0 then
			label = "NEED " .. UIKit.formatNumber(short) .. " MORE"
		else
			label = "BUY"
		end
		if card.Label ~= label then
			card.Label = label
			card.Button.SetText(label)
		end
		local enabled = item ~= nil and not item.Sold and (short == 0 or on)
		if card.Enabled ~= enabled then
			card.Enabled = enabled
			card.Button.SetEnabled(enabled)
		end
	end
end

local function buildPanel(root: Frame)
	local p = UIKit.new("Frame", { Name = "MerchantPanel", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.06, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -150), Size = UDim2.fromOffset(420, CARD_H + HEAD_H + FOOT_H + 6), Visible = false }, root) :: Frame
	UIKit.corner(p, Theme.Radius.L)
	UIKit.stroke(p, P.gold_400, 1.5, 0.2)
	UIKit.text(p, "Label", "MERCHANT", { Name = "Title", Position = UDim2.fromOffset(12, 9), Size = UDim2.new(0.4, -12, 0, 20), TextColor3 = P.gold_200 }, 16)
	-- the run gold you can spend here, beside the close button
	balance = UIKit.text(p, "Label", "RUN GOLD 0", { Name = "Balance", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -50, 0, 9), Size = UDim2.new(0.6, -50, 0, 20), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_200 }, 15)
	UIKit.IconButton(p, {
		Icon = "close",
		Kind = "Outline",
		Size = 32,
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 4),
		OnClick = function()
			-- closed until the player walks out of range and comes back
			dismissedFor = panelFor
		end,
	})
	local row = UIKit.new("Frame", { Name = "Row", BackgroundTransparency = 1, Position = UDim2.fromOffset(8, HEAD_H), Size = UDim2.new(1, -16, 0, CARD_H) }, p)
	UIKit.list(row, { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 6) })
	footLine = UIKit.text(p, "Caption", "Your own offers · this cart stays all stage", { Name = "Foot", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.new(1, -24, 0, FOOT_H - 4), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.ivory_300, TextScaled = true }, 12)
	UIKit.new("UITextSizeConstraint", { MaxTextSize = (footLine :: TextLabel).TextSize, MinTextSize = 10 }, footLine)
	for i = 1, Config.Explore.Merchant.Slots do
		local card = UIKit.new("Frame", { Name = "Offer" .. i, LayoutOrder = i, BackgroundColor3 = P.slate_900, BorderSizePixel = 0, Size = UDim2.new(1 / 3, -4, 1, 0) }, row)
		UIKit.corner(card, Theme.Radius.M)
		local stroke = UIKit.stroke(card, P.ivory_200, 1.5, 0.4)
		local tileBox = UIKit.new("Frame", { Name = "TileBox", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(36, 36) }, card)
		local name = UIKit.text(card, "Label", "", { Name = "ItemName", Position = UDim2.fromOffset(4, 44), Size = UDim2.new(1, -8, 0, 16), TextXAlignment = Enum.TextXAlignment.Center, TextScaled = true }, 13)
		local rarity = UIKit.text(card, "Caption", "", { Name = "Rarity", Position = UDim2.fromOffset(4, 60), Size = UDim2.new(1, -8, 0, 13), TextXAlignment = Enum.TextXAlignment.Center }, 11)
		local desc = UIKit.text(card, "Caption", "", { Name = "Desc", Position = UDim2.fromOffset(4, 72), Size = UDim2.new(1, -8, 0, 26), TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, TextColor3 = P.ivory_200 }, 11)
		local price = UIKit.text(card, "Label", "", { Name = "Price", Position = UDim2.fromOffset(4, 98), Size = UDim2.new(1, -8, 0, 16), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.gold_200 }, 14)
		local btn = UIKit.Button(card, { Name = "Buy", Title = "BUY", Kind = "Primary", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.new(1, -12, 0, 34), Shadow = false, OnClick = function() buy(i) end })
		cards[i] = { Card = card, Stroke = stroke, TileBox = tileBox, Name = name, Rarity = rarity, Desc = desc, Price = price, Button = btn, Shown = "", Enabled = true }
	end
	return p
end

local function fillCards()
	local gold = wallet()
	local anyAffordable, anyLeft = false, false
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
			end
			local price = priceOf(item)
			local afford = gold >= price
			if not item.Sold then
				anyLeft = true
				anyAffordable = anyAffordable or afford
			end
			set(card.Price, "Text", item.Sold and "Bought" or (UIKit.formatNumber(price) .. " gold"))
			set(card.Price, "TextColor3", (item.Sold or afford) and P.gold_200 or P.crimson_300)
		end
	end
	if balance then
		set(balance, "Text", "RUN GOLD " .. UIKit.formatNumber(gold))
	end
	if footLine then
		set(footLine, "Text", (anyLeft and not anyAffordable) and "Earn run gold from kills · this cart stays all stage" or "Your own offers · this cart stays all stage")
	end
	refreshButtons()
end

local function merchantModel(): Model?
	local f = workspace:FindFirstChild("SwarmEvents")
	local m = f and f:FindFirstChild("Merchant")
	return (m and m:IsA("Model")) and m or nil
end

-- The main gui's root (UIBuilder: "Root" with a UIScale), to place the panel between the
-- HUD's banner lane (under the top cluster) and its bottom bar in real pixels.
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
			local _, laneBottom = Hud.BannerLane()
			local top = math.max(Hud.TopBottom(), laneBottom or 0)
			return off + top * sc.Scale, off + Hud.BarTop() * sc.Scale
		end
	end
	return nil, nil
end

-- Full: the item tile on top, then name, rarity, effect, price. Compact (short screens):
-- no tile, rarity and price share one row.
local function placeCard(card, small: boolean)
	card.TileBox.Visible = not small
	if small then
		card.Name.Position = UDim2.fromOffset(4, 4)
		card.Rarity.Position = UDim2.fromOffset(6, 21)
		card.Rarity.Size = UDim2.new(0.5, -6, 0, 14)
		card.Rarity.TextXAlignment = Enum.TextXAlignment.Left
		card.Price.AnchorPoint = Vector2.new(1, 0)
		card.Price.Position = UDim2.new(1, -6, 0, 20)
		card.Price.Size = UDim2.new(0.5, -6, 0, 16)
		card.Price.TextXAlignment = Enum.TextXAlignment.Right
		card.Desc.Position = UDim2.fromOffset(4, 36)
	else
		card.Name.Position = UDim2.fromOffset(4, 44)
		card.Rarity.Position = UDim2.fromOffset(4, 60)
		card.Rarity.Size = UDim2.new(1, -8, 0, 13)
		card.Rarity.TextXAlignment = Enum.TextXAlignment.Center
		card.Price.AnchorPoint = Vector2.zero
		card.Price.Position = UDim2.fromOffset(4, 98)
		card.Price.Size = UDim2.new(1, -8, 0, 16)
		card.Price.TextXAlignment = Enum.TextXAlignment.Center
		card.Desc.Position = UDim2.fromOffset(4, 72)
	end
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
	local fullH, smallH = CARD_H + HEAD_H + FOOT_H + 6, CARD_H_COMPACT + HEAD_H + FOOT_H + 6
	local bottom = h - 150
	local small = false
	if h > w then
		bottom = h - 122 -- portrait: just above the JUMP button, under the minimap
	else
		local t, b = hudSpace(holder)
		if t and b then
			local top = t + 6
			bottom = b - 6
			if bottom - top < fullH then
				small = true
				if bottom - top < smallH then
					-- short phones: under the banner lane, over the top of the ability panel
					-- (this gui draws above the HUD; the panel stays clear of the screen edge)
					bottom = math.min(h - 6, top + smallH)
				end
			end
		end
	end
	if small ~= compact or p:GetAttribute("Laid") ~= true then
		compact = small
		p:SetAttribute("Laid", true)
		for _, card in ipairs(cards) do
			placeCard(card, small)
		end
	end
	local cardH = small and CARD_H_COMPACT or CARD_H
	set(p, "Size", UDim2.fromOffset(width, small and smallH or fullH))
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
	-- any panel (level-up, reward, portal choice, run menu ...) hides all of this: the
	-- shop's gui draws above the main gui, so it must never sit over one of them
	local on = inRun() and not UIState.Covered() and UIState.Owner() == nil
	local root = myRoot()
	local p = panel
	-- the shop panel: at the cart, unless closed with X (until the player walks away)
	local cart = merchantModel()
	local cartId = cart and tonumber(cart:GetAttribute("MerchantId")) or 0
	local pos = cart and cart:GetAttribute("Pos")
	local radius = cart and tonumber(cart:GetAttribute("Radius")) or 0
	local inRange = root ~= nil and typeof(pos) == "Vector3" and ((root.Position - pos) * FLAT).Magnitude <= radius
	local near = on and inRange
	if not inRange and inRun() and root ~= nil then
		dismissedFor = 0
	end
	local show = p ~= nil and near and stock.Id ~= 0 and stock.Id == cartId and player:GetAttribute("Paused") ~= true and dismissedFor ~= cartId
	if p and show then
		if panelFor ~= cartId then
			panelFor = cartId
			table.clear(pending)
			for _, card in ipairs(cards) do
				card.Shown = ""
			end
		end
		-- a sent buy unblocks after the server's answer (MerchantStock) or the safety time
		for slot, at in pairs(pending) do
			if clock - at >= PENDING_MAX then
				pending[slot] = nil
			end
		end
		layoutPanel(p)
		fillCards()
	end
	if p then
		set(p, "Visible", show)
	end
	UIState.SetSidePanel("Merchant", show)
	if gui then
		set(gui, "Enabled", inRun())
	end
	-- world pills (after the panel, so the merchant's own label knows it is open)
	for m, mk in pairs(markers) do
		if not m.Parent then
			untrack(m)
		else
			local mpos = m:GetAttribute("Pos")
			local saved = m:GetAttribute("State") == "Saved"
			-- delivered: every escort label stops; only the villager's last line shows briefly
			if saved and m:GetAttribute("EventKind") == "Rescue" then
				local seq = tonumber(m:GetAttribute("SaySeq")) or 0
				if seq ~= (mk.SaySeq or 0) then
					mk.SaySeq = seq
					mk.SayUntil = clock + SAY_SECONDS
				end
				saved = not (mk.SayUntil and clock < mk.SayUntil)
			end
			local want = on and typeof(mpos) == "Vector3" and not saved
			local hidden = true
			if want then
				fillMarker(mk)
				hidden = clearOfHud(mk)
				if show and m:GetAttribute("EventKind") == "Merchant" then
					hidden = true -- its panel is open: the label would only repeat it
				end
			end
			mk.Alpha = want and WorldLabelFade.Step(mk.Alpha, hidden, dt) or 1
			set(mk.Billboard, "Enabled", want and mk.Alpha < 0.99)
			applyFade(mk)
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
end

-- Tests / scenes: the stock the panel shows.
function ExploreUI.Stock(): { [string]: any }
	return stock
end

-- Tests / scenes: the shop panel (nil before Init).
function ExploreUI.Panel(): Frame?
	return panel
end

function ExploreUI.Init()
	if gui then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	-- DisplayOrder 11: over the main gui (10: HUD, notice pills), so nothing covers the
	-- shop's buttons; it hides whenever a panel of the main gui opens (update)
	local screen = UIKit.new("ScreenGui", { Name = "ExploreUI", ResetOnSpawn = false, IgnoreGuiInset = true, ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, DisplayOrder = 11, Enabled = false }, playerGui) :: ScreenGui
	gui = screen
	local root = UIKit.new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, screen)
	panel = buildPanel(root)
	WorldLabelFade.Avoid(panel :: Frame)
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
		-- the server's answer: a pending buy unblocks once its minimum time has passed
		for slot, at in pairs(pending) do
			if clock - at >= PENDING_MIN then
				pending[slot] = nil
			else
				pending[slot] = at + PENDING_MIN - PENDING_MAX -- frees at the minimum
			end
		end
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
			return
		end
		-- gamepad: D-pad picks, X buys (the D-pad belongs to the ping wheel while it is open;
		-- X belongs to a chest / shrine prompt while one shows)
		if not UIState.WorldInputAllowed() or FeatureHud.PingWheelOpen() or player:GetAttribute("Alive") == false then
			return
		end
		if input.KeyCode == Enum.KeyCode.DPadLeft or input.KeyCode == Enum.KeyCode.DPadRight then
			padMove(input.KeyCode == Enum.KeyCode.DPadRight and 1 or -1)
			refreshButtons()
		elseif input.KeyCode == Enum.KeyCode.ButtonX then
			local prompt = LootUI.Elements().Prompt :: GuiObject?
			if prompt and prompt.Visible then
				return
			end
			padMove(0)
			buy(padSlot)
		end
	end)
	RunService.RenderStepped:Connect(update)
end

return ExploreUI
