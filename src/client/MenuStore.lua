--[[
	MenuStore.lua (Config.Features.Store; docs/features/STORE.md)
	The STORE screen: cosmetics only. A row of section chips (Skins, Trails, Death bursts,
	Pets, Emotes and poses, Nameplates, Lobby dais, Supporter, Hero early unlocks, Gift) over
	a grid of cards. Every item comes from CosmeticData / StoreCatalog:
	  earned items   show their goal and the progress ("Win 10 runs · 3 / 10")
	  store items    show the Robux price from MarketplaceService:GetProductInfo (never a
	                 number from the game), or "Coming soon" while the Config id is 0
	  owned items    WEAR / TAKE OFF (StoreEquip; skins: the existing EquipSkin), the worn
	                 emote PLAY
	Buying goes through the server (StoreBuy): it checks the item and opens the Roblox
	prompt; a cancel or a failed payment shows a calm line. GIFT picks another player in
	this server; the server checks the target again when the receipt arrives.
	The gold packs, passes and Revive stay on the UPGRADES screen's SHOP tab.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local StoreCatalog = require(Shared:WaitForChild("StoreCatalog"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local AchievementData = require(Shared:WaitForChild("AchievementData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local MenuStore = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

-- price cache: "Product:123" / "GamePass:123" → Robux
local prices: { [string]: number } = {}

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

local function storeGroup(e: any): string?
	return type(e.StoreKey) == "string" and string.match(e.StoreKey, "^(%w+)%.") or nil
end

local function isPass(e: any): boolean
	local g = storeGroup(e)
	return g == "SkinPasses" or g == "GamePasses" or g == "CosmeticPasses"
end

local function heroProduct(heroId: string): number
	local t = (Config.Monetization :: any).HeroUnlocks
	local id = t and t[heroId]
	return type(id) == "number" and id or 0
end

local function heroBuyable(heroId: string): boolean
	return StoreCatalog.HeroEarnable(CharacterData.Characters[heroId])
end

-- The price label for an id; fetches it once (async) and calls back to refresh the button.
local function priceText(id: number, pass: boolean, onPrice: (string) -> ()): string
	local key = (pass and "GamePass:" or "Product:") .. id
	if prices[key] then
		return "R$ " .. UIKit.formatNumber(prices[key])
	end
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, pass and Enum.InfoType.GamePass or Enum.InfoType.Product)
		end)
		if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
			prices[key] = info.PriceInRobux
			onPrice("R$ " .. UIKit.formatNumber(info.PriceInRobux))
		end
	end)
	return "BUY"
end

function MenuStore.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = {}
	local section = "Skins"
	local giftTarget: number? = nil
	local message: string? = nil

	ui.Header = UIKit.ScreenHeader(screen, "STORE", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35 })
	ui.Panel = holder
	UIKit.padding(face, 12, 14, 12, 14)
	-- section chips (scroll sideways on phones)
	ui.Chips = new("ScrollingFrame", {
		Name = "Sections",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.Size.TapMin + 6),
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.X,
		ElasticBehavior = Enum.ElasticBehavior.Never,
	}, face)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Top }, ui.Chips)
	local chips: { [string]: any } = {}
	ui.Note = text(face, "Small", "", { Name = "Note", Size = UDim2.new(1, 0, 0, TS(14) + 6), TextColor3 = C.TextMuted, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd }, 14)
	ui.Scroll = new("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	UIKit.padding(ui.Scroll, 4, 8, 8, 4)
	ui.Grid = new("UIGridLayout", {
		CellSize = UDim2.fromOffset(260, 170),
		CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}, ui.Scroll)

	local rebuild: (animate: boolean) -> ()

	for i, s in ipairs(StoreCatalog.Sections) do
		local title = string.upper(s.Title)
		local w = math.floor(#title * TS(14) * 0.7 + 64)
		chips[s.Id] = UIKit.Button(ui.Chips, {
			Kind = s.Id == section and "Primary" or "Ghost",
			Title = title,
			Icon = s.Icon,
			IconSize = 16,
			Name = "Section_" .. s.Id,
			LayoutOrder = i,
			Size = UDim2.fromOffset(w, Theme.Size.TapMin),
			Shadow = false,
			Radius = Theme.Radius.S,
			Align = "Center",
			Shrink = true,
			OnClick = function()
				if section == s.Id then
					return
				end
				section = s.Id
				message = nil
				for id, b in pairs(chips) do
					b.SetKind(id == section and "Primary" or "Ghost")
				end
				rebuild(true)
			end,
		})
	end

	local function card(order: number): Frame
		local f = UIKit.Panel(ui.Scroll, { LayoutOrder = order, Name = "Card" .. order })
		f.BackgroundColor3 = P.slate_950
		f.BackgroundTransparency = 0.25
		UIKit.pad(f, 12)
		return f
	end

	-- icon tile + name + one or two lines of description
	local function cardTop(f: Frame, tile: () -> (), name: string, desc: string, badge: string?)
		tile()
		local title = string.upper(name)
		local room = (ui.CellW or 260) - 24 - 64 - (badge and 64 or 0)
		local size = 18
		while size > 13 and #title * TS(size) * 0.7 > room do
			size -= 1
		end
		text(f, "H2", title, { Name = "Name", Position = UDim2.fromOffset(64, 0), Size = UDim2.new(1, -64 - (badge and 64 or 0), 0, TS(18) + 6), TextTruncate = Enum.TextTruncate.AtEnd }, size)
		text(f, "Small", desc, { Name = "Desc", Position = UDim2.fromOffset(64, TS(18) + 8), Size = UDim2.new(1, -64, 0, TS(13) * 3 + 4), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextTruncate = Enum.TextTruncate.AtEnd }, 13)
		if badge then
			UIKit.Badge(f, badge, badge == "WORN" and "Gold" or "Moss", { Name = "State", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 2) })
		end
	end

	local function swatch(f: Frame, icon: string, color: Color3?)
		local tile = new("Frame", { Name = "Swatch", Size = UDim2.fromOffset(52, 52), BackgroundColor3 = P.slate_800, BorderSizePixel = 0 }, f)
		UIKit.corner(tile, Theme.Radius.M)
		UIKit.stroke(tile, color or P.gold_400, 2, 0.1)
		Icons.Draw(tile, icon, { Size = 34, Color = color, Position = UDim2.fromScale(0.5, 0.5), AnchorPoint = Vector2.new(0.5, 0.5) })
	end

	local function bottomButton(f: Frame, o: { [string]: any }): any
		o.AnchorPoint = Vector2.new(0, 1)
		o.Position = UDim2.fromScale(0, 1)
		o.Size = UDim2.new(1, 0, 0, 44)
		o.Shadow = false
		o.Align = "Center"
		o.IconSize = 18
		o.Shrink = true
		return UIKit.Button(f, o)
	end

	local function bottomCaption(f: Frame, str: string, color: Color3?)
		text(f, "Caption", UIKit.track(str), { Name = "Status", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -12), Size = UDim2.new(1, 0, 0, TS(13) + 6), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = color or C.TextFaint, TextTruncate = Enum.TextTruncate.AtEnd }, 13)
	end

	-- price button (R$ from Roblox) → StoreBuy; "Coming soon" for an id of 0
	local function buyButton(f: Frame, itemId: string, robuxId: number, pass: boolean, title: string?, target: number?)
		if robuxId == 0 then
			bottomCaption(f, "Coming soon")
			return
		end
		local b
		local function label(price: string): string
			return title and (title .. " · " .. price) or price
		end
		b = bottomButton(f, {
			Kind = "Outline",
			Title = label(priceText(robuxId, pass, function(price)
				if b and b.Instance.Parent then
					b.SetText(label(price))
				end
			end)),
			Icon = "robux",
			Name = "Buy",
			OnClick = function()
				Remotes.Get("StoreBuy"):FireServer(itemId, target)
			end,
		})
		-- the price may have arrived before the button existed (an answer without a yield)
		local cached = prices[(pass and "GamePass:" or "Product:") .. robuxId]
		if cached then
			b.SetText(label("R$ " .. UIKit.formatNumber(cached)))
		end
		return b
	end

	local function equipButton(f: Frame, kind: string, id: string, worn: boolean)
		if worn and kind == "Emote" then
			bottomButton(f, { Kind = "Primary", Title = "PLAY", Icon = "play", Name = "Play", OnClick = function()
				Remotes.Get("StoreEmote"):FireServer()
			end })
			return
		end
		bottomButton(f, {
			Kind = worn and "Outline" or "Primary",
			Title = worn and "TAKE OFF" or "WEAR",
			Icon = worn and "close" or "check",
			Name = worn and "TakeOff" or "Wear",
			OnClick = function()
				Remotes.Get("StoreEquip"):FireServer(kind, worn and "" or id)
			end,
		})
	end

	local function earnedCaption(f: Frame, e: any, p: any)
		local have, need = StoreCatalog.Progress(e.Earn, p)
		bottomCaption(f, string.format("%s / %s", UIKit.formatNumber(math.min(have, need)), UIKit.formatNumber(need)), P.gold_300)
	end

	local function view(p: any): any
		return type(p.Store) == "table" and p.Store or { Owned = {}, Equipped = {}, Supporter = false }
	end

	local function itemCard(p: any, e: any, order: number)
		local v = view(p)
		local owned = v.Owned[e.Id] == true
		local worn = (v.Equipped[e.Kind] or "") == e.Id
		local l = e.Look or {}
		local f = card(order)
		local sec
		for _, s in ipairs(StoreCatalog.Sections) do
			if s.Kind == e.Kind then
				sec = s
			end
		end
		local desc = e.Desc or ""
		if not owned and e.Source == "Earned" then
			desc = "Earn it: " .. (e.Condition or "")
		end
		cardTop(f, function()
			swatch(f, (l.Icon or (sec and sec.Icon) or "sparkle"), l.Color)
		end, e.Name, desc, worn and "WORN" or (owned and "OWNED" or nil))
		if owned then
			equipButton(f, e.Kind, e.Id, worn)
		elseif e.Source == "Earned" then
			earnedCaption(f, e, p)
		else
			buyButton(f, e.Id, CosmeticData.StoreId(e.Id), isPass(e))
		end
		return f
	end

	local function skinCard(p: any, e: any, order: number)
		local owned = type(p.OwnedSkins) == "table" and p.OwnedSkins[e.Id] == true
		local hero = e.Character
		local worn = owned and type(p.Skins) == "table" and p.Skins[hero] == e.Id
		local heroDef = hero and CharacterData.Characters[hero]
		local f = card(order)
		cardTop(f, function()
			if heroDef then
				Icons.Character(f, hero, { Size = 52 })
			else
				swatch(f, "sparkle")
			end
		end, e.Name, (heroDef and (heroDef.Name .. " skin. ") or "") .. "Looks only.", worn and "WORN" or (owned and "OWNED" or nil))
		if owned then
			if not worn and heroDef and type(p.OwnedCharacters) == "table" and p.OwnedCharacters[hero] then
				bottomButton(f, { Kind = "Primary", Title = "WEAR", Icon = "check", Name = "Wear", OnClick = function()
					Remotes.Get("EquipSkin"):FireServer(hero, e.Id)
				end })
			elseif not worn then
				bottomCaption(f, "Unlock the hero to wear it")
			end
		else
			buyButton(f, e.Id, CosmeticData.StoreId(e.Id), true)
		end
		return f
	end

	local function supporterCard(p: any, order: number)
		local v = view(p)
		local f = card(order)
		cardTop(f, function()
			swatch(f, "crown", P.gold_300)
		end, StoreCatalog.Supporter.Name, StoreCatalog.Supporter.Desc, v.Supporter and "OWNED" or nil)
		if v.Supporter then
			local plate = StoreCatalog.Supporter.Plate
			equipButton(f, "Nameplate", plate, (v.Equipped.Nameplate or "") == plate)
		else
			buyButton(f, StoreCatalog.Supporter.Plate, CosmeticData.StoreId(StoreCatalog.Supporter.Plate), true)
		end
		return f
	end

	local function heroCard(p: any, heroId: string, order: number)
		local def = CharacterData.Characters[heroId]
		local f = card(order)
		local owned = def and type(p.OwnedCharacters) == "table" and p.OwnedCharacters[heroId] == true
		local desc = "A new hero. Coming soon."
		if def then
			local unlock = (def :: any).Unlock
			local ach = type(unlock) == "table" and AchievementData.Achievements[unlock.Achievement]
			if ach then
				desc = "Unlock early, or earn it free: " .. ach.Name .. "."
			elseif type((def :: any).Cost) == "number" and (def :: any).Cost > 0 then
				desc = "Unlock early, or buy it with " .. UIKit.formatNumber((def :: any).Cost) .. " gold from runs."
			end
		end
		cardTop(f, function()
			if def then
				Icons.Character(f, heroId, { Size = 52 })
			else
				swatch(f, "helmet")
			end
		end, def and def.Name or heroId, desc, owned and "OWNED" or nil)
		if owned then
			bottomCaption(f, "Yours", P.moss_200)
		elseif not def or not heroBuyable(heroId) then
			bottomCaption(f, "Coming soon")
		else
			buyButton(f, "Hero_" .. heroId, heroProduct(heroId), false)
		end
		return f
	end

	local function others(): { Player }
		local list = {}
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl ~= player then
				table.insert(list, pl)
			end
		end
		table.sort(list, function(a, b)
			return a.UserId < b.UserId
		end)
		return list
	end

	local function targetPlayer(): Player?
		if not giftTarget then
			return nil
		end
		local pl = Players:GetPlayerByUserId(giftTarget)
		if not pl then
			giftTarget = nil
		end
		return pl
	end

	local function giftPicker(order: number)
		local list = others()
		local f = card(order)
		local target = targetPlayer()
		if not target and list[1] then
			giftTarget = list[1].UserId
			target = list[1]
		end
		cardTop(f, function()
			swatch(f, "gift", P.gold_300)
		end, "Send to", target and target.DisplayName or "Nobody else is here right now.", nil)
		if #list > 1 then
			bottomButton(f, { Kind = "Outline", Title = "NEXT PLAYER", Icon = "chevronRight", Name = "NextPlayer", OnClick = function()
				local i = 0
				for k, pl in ipairs(list) do
					if pl.UserId == giftTarget then
						i = k
					end
				end
				giftTarget = list[i % #list + 1].UserId
				rebuild(false)
			end })
		else
			bottomCaption(f, #list == 1 and "Gifts go to this player" or "Invite a friend to gift")
		end
		return f
	end

	local function giftCard(e: any, order: number)
		local f = card(order)
		local l = e.Look or {}
		local sec
		for _, s in ipairs(StoreCatalog.Sections) do
			if s.Kind == e.Kind then
				sec = s
			end
		end
		cardTop(f, function()
			swatch(f, (l.Icon or (sec and sec.Icon) or "gift"), l.Color)
		end, e.Name, e.Desc or "", nil)
		local target = targetPlayer()
		if not target then
			bottomCaption(f, CosmeticData.StoreId(e.Id) == 0 and "Coming soon" or "Pick a player first")
			return f
		end
		buyButton(f, e.Id, CosmeticData.StoreId(e.Id), false, "GIFT", target.UserId)
		return f
	end

	local function noteText(): string
		if message then
			return message
		end
		local s = section
		if s == "Gift" then
			return "Buy a look for a player in this server. Looks only."
		elseif s == "Heroes" then
			return "Every hero here can also be earned by playing."
		elseif s == "Bursts" then
			return "How foes burst on your screen. Looks only."
		elseif s == "Pets" then
			return "Pets follow you. No stats, no pickup help."
		end
		return "Looks only. Nothing here changes a run."
	end

	local cellH = 170
	local count = 0

	rebuild = function(animate: boolean)
		for _, c in ipairs(ui.Scroll:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local p = ctx.Profile()
		ui.Note.Text = noteText()
		ui.Note.TextColor3 = message and P.gold_200 or C.TextMuted
		if not p then
			return
		end
		local made: { GuiObject } = {}
		local sec
		for _, s in ipairs(StoreCatalog.Sections) do
			if s.Id == section then
				sec = s
			end
		end
		if section == "Skins" then
			for i, e in ipairs(CosmeticData.OfKind("Skin")) do
				table.insert(made, skinCard(p, e, i))
			end
		elseif section == "Supporter" then
			table.insert(made, supporterCard(p, 1))
		elseif section == "Heroes" then
			for i, id in ipairs(StoreCatalog.HeroUnlocks) do
				table.insert(made, heroCard(p, id, i))
			end
		elseif section == "Gift" then
			table.insert(made, giftPicker(0))
			for i, e in ipairs(StoreCatalog.Entries) do
				if e.Source == "Store" and storeGroup(e) == "Cosmetics" then
					table.insert(made, giftCard(e, i))
				end
			end
		elseif sec and sec.Kind then
			for i, e in ipairs(CosmeticData.OfKind(sec.Kind)) do
				if e.Source ~= "Default" and not (e :: any).Weapon then
					table.insert(made, itemCard(p, e, i))
				end
			end
		end
		count = #made
		MenuStore._cell()
		if animate then
			for i, f in ipairs(made) do
				UIAnim.Pop(f, 0.02 * math.min(i, 8), 0.8)
			end
		end
	end

	MenuStore._cell = function()
		cellH = TS(18) + 8 + 3 * TS(13) + 12 + 44 + 24
		ui.Grid.CellSize = UDim2.fromOffset(ui.CellW or 260, cellH)
		if ui.PanelMaxH then
			local rows = math.max(1, math.ceil(count / (ui.Cols or 1)))
			local need = 24 + ui.ScrollTop + 12 + rows * cellH + (rows - 1) * 12 + 8
			ui.Panel.Size = UDim2.fromOffset(ui.Panel.Size.X.Offset, math.min(ui.PanelMaxH, need))
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		local top = headY + 66 + (portrait and 58 or 0)
		if not portrait then
			top = math.max(top, 76)
		end
		local w = math.min(W - 2 * M - ins.Left - ins.Right, 980)
		ui.Panel.Position = UDim2.fromOffset((W - w) / 2, top)
		ui.Panel.Size = UDim2.fromOffset(w, H - top - M)
		ui.PanelMaxH = H - top - M
		local chipsH = Theme.Size.TapMin + 6
		ui.Chips.Position = UDim2.fromOffset(0, 0)
		local noteY = chipsH + 4
		ui.Note.Position = UDim2.fromOffset(0, noteY)
		ui.ScrollTop = noteY + TS(14) + 10
		ui.Scroll.Position = UDim2.fromOffset(0, ui.ScrollTop)
		ui.Scroll.Size = UDim2.new(1, 0, 1, -ui.ScrollTop)
		local inner = w - 28 - 12
		local cols = math.clamp(math.floor((inner + 12) / 250), 1, 3)
		ui.Cols = cols
		local cw = math.floor((inner - (cols - 1) * 12) / cols)
		local changed = ui.CellW ~= cw
		ui.CellW = cw
		MenuStore._cell()
		if changed and screen.Visible then
			rebuild(false)
		end
	end

	Remotes.Get("StoreResult").OnClientEvent:Connect(function(r)
		if type(r) ~= "table" or type(r.Text) ~= "string" then
			return
		end
		message = r.Text
		if screen.Visible then
			ui.Note.Text = r.Text
			ui.Note.TextColor3 = r.Ok and P.moss_200 or P.gold_200
			UIAnim.Pop(ui.Note, 0, 0.9)
		else
			ctx.Toast(r.Text, r.Ok and P.moss_200 or P.gold_200)
		end
	end)
	Players.PlayerAdded:Connect(function()
		if screen.Visible and section == "Gift" then
			rebuild(false)
		end
	end)
	Players.PlayerRemoving:Connect(function(pl)
		if screen.Visible and section == "Gift" then
			if pl.UserId == giftTarget then
				giftTarget = nil
			end
			task.defer(rebuild, false)
		end
	end)

	return {
		Layout = layout,
		Refresh = function(_p)
			if screen.Visible then
				rebuild(false)
			end
		end,
		OnShow = function(_p, arg)
			if type(arg) == "string" then
				for _, s in ipairs(StoreCatalog.Sections) do
					if s.Id == arg then
						section = arg
					end
				end
				for id, b in pairs(chips) do
					b.SetKind(id == section and "Primary" or "Ghost")
				end
			end
			message = nil
			-- earned looks are re-checked on the server (the answer is a fresh ProfileSync)
			Remotes.Get("StoreEquip"):FireServer("Sync")
			rebuild(true)
			UIAnim.Pop(ui.Panel, 0, 0.94)
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end,
	}
end

MenuStore._cell = function() end

return MenuStore
