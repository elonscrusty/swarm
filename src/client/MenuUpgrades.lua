--[[
	MenuUpgrades.lua
	The UPGRADES screen: two tabs in one panel.
	  PERMANENT  the gold upgrades (MetaUpgradeData): icon, name, rank (LV 2/5), level pips,
	             NOW / NEXT effect in plain words, the price (BUY, gold when affordable,
	             "Need N more gold" when not) or MAXED. A tap marks the row BUYING... until
	             the server's ProfileSync (the gold and levels always come from the server);
	             BuyMeta carries the level the player saw, so a double tap buys one level.
	  SHOP       Robux: gold packs (developer products) and gamepasses (Starter Pack, VIP,
	             2x Gold) with their Robux price, OWNED, or "not set up yet" for ids left 0
	Gold and cosmetics only (never power for Robux). With DataStores off (Studio) a red note
	says progress will not be saved.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local MenuUpgrades = {}

local player = Players.LocalPlayer
local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local SHOP = {
	{ Name = "500 Gold", Kind = "Product", Key = "Gold500", Icon = "pouch", Desc = "A pouch of gold." },
	{ Name = "1,500 Gold", Kind = "Product", Key = "Gold1500", Icon = "Gold", Desc = "A sack of gold." },
	{ Name = "5,000 Gold", Kind = "Product", Key = "Gold5000", Icon = "chest", Desc = "A chest of gold." },
	{ Name = "Starter Pack", Kind = "Pass", Key = "StarterPack", Icon = "gift", Desc = "+25% gold forever + Gold Trim skins." },
	{ Name = "VIP", Kind = "Pass", Key = "VIP", Icon = "crown", Desc = "+1 reroll per run, chat tag, lobby crown." },
	{ Name = "2x Gold", Kind = "Pass", Key = "DoubleGold", Icon = "coin", Desc = "Double gold from runs." },
}

local prices: { [number]: number } = {}

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

local function itemId(item): number
	if item.Kind == "Pass" then
		return (Config.Monetization.GamePasses :: any)[item.Key] or 0
	end
	return (Config.Monetization.Products :: any)[item.Key] or 0
end

function MenuUpgrades.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = {}
	local tab = "Permanent"

	ui.Header = UIKit.ScreenHeader(screen, "UPGRADES", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	UIKit.padding(face, 14, 16, 14, 16)
	ui.Tabs = UIKit.Tabs(face, {
		{ Id = "Permanent", Title = "Permanent", Icon = "chevronsUp" },
		{ Id = "Shop", Title = "Shop", Icon = "robux" },
	}, function(id)
		tab = id
		MenuUpgrades._rebuild(true)
	end)
	ui.Note = text(face, "Small", "", { Position = UDim2.fromOffset(0, Theme.Size.TapMin + 6), Size = UDim2.new(1, 0, 0, TS(14) + 6), TextColor3 = C.TextMuted })
	ui.Scroll = new("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, Theme.Size.TapMin + 14 + TS(14) + 6),
		Size = UDim2.new(1, 0, 1, -(Theme.Size.TapMin + 14 + TS(14) + 6)),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	UIKit.padding(ui.Scroll, 4, 8, 8, 4)
	ui.Grid = new("UIGridLayout", {
		CellSize = UDim2.fromOffset(280, 176),
		CellPadding = UDim2.fromOffset(12, 12),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}, ui.Scroll)

	local function card(order: number): Frame
		local f = UIKit.Panel(ui.Scroll, { LayoutOrder = order, Name = "Card" .. order })
		f.BackgroundColor3 = P.slate_800
		f.BackgroundTransparency = 0.2
		UIKit.pad(f, 12)
		return f
	end

	-- purchase state: a tap marks the row pending (button reads BUYING..., taps ignored)
	-- until the server's ProfileSync arrives; a level that went up flashes its row
	local pending: { [string]: number } = {}
	local lastLevels: { [string]: number } = {}

	local function metaCard(p, id: string, order: number)
		local def = MetaUpgradeData.Upgrades[id]
		local level = p.Meta[id] or 0
		local cost = MetaUpgradeData.CostOf(id, level)
		local maxed = cost == nil
		local f = card(order)
		UIKit.Tile(f, { Id = Icons.MetaIcon(id), Size = 52 })
		text(f, "H3", def.Name, { Position = UDim2.fromOffset(64, 0), Size = UDim2.new(1, -64 - 74, 0, TS(18) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
		local rank = UIKit.Badge(f, maxed and "MAX" or string.format("LV %d/%d", level, def.MaxLevel), maxed and "Gold" or "Slate", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 2) })
		rank.Name = "Rank"
		text(f, "Small", def.Description, { Position = UDim2.fromOffset(64, 6 + TS(18)), Size = UDim2.new(1, -64, 0, TS(14) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
		-- level pips
		local pips = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(64, 12 + TS(18) + TS(14)), Size = UDim2.new(1, -64, 0, 10) }, f)
		UIKit.list(pips, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), VerticalAlignment = Enum.VerticalAlignment.Center })
		for i = 1, def.MaxLevel do
			local pip = new("Frame", { BackgroundColor3 = i <= level and P.gold_400 or P.slate_950, Size = UDim2.fromOffset(math.min(26, math.floor(140 / def.MaxLevel)), 8), LayoutOrder = i }, pips)
			UIKit.corner(pip, 999)
			UIKit.stroke(pip, i <= level and P.gold_200 or P.slate_600, 1, 0.3)
		end
		-- now / next effect (what the next level really gives)
		local now = MetaUpgradeData.EffectText(id, level)
		local nextText = maxed and "Fully upgraded" or MetaUpgradeData.EffectText(id, level + 1)
		local lines = {
			string.format('<font color="%s">NOW</font>  %s', UIKit.hex(C.TextMuted), now),
			string.format('<font color="%s">NEXT</font>  <font color="%s"><b>%s</b></font>', UIKit.hex(C.TextMuted), UIKit.hex(maxed and P.gold_300 or P.moss_200), nextText),
		}
		local affordable = cost ~= nil and p.Gold >= cost
		if cost and not affordable then
			table.insert(lines, string.format('<font color="%s">Need %s more gold</font>', UIKit.hex(P.crimson_300), UIKit.formatNumber(cost - p.Gold)))
		end
		text(f, "Small", table.concat(lines, "\n"), {
			Position = UDim2.fromOffset(0, 62),
			Size = UDim2.new(1, 0, 1, -62 - 52),
			RichText = true,
			TextWrapped = true,
			TextColor3 = C.Text,
			TextYAlignment = Enum.TextYAlignment.Top,
			LineHeight = 1.1,
		})
		if cost then
			local busy = pending[id] ~= nil
			local b
			b = UIKit.Button(f, {
				Kind = affordable and "Primary" or "Outline",
				Title = busy and "BUYING..." or ("BUY  " .. UIKit.formatNumber(cost)),
				Icon = "coin",
				IconSize = 20,
				Align = "Center",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, 46),
				Shadow = false,
				OnClick = function()
					if pending[id] then
						return -- double tap: the first purchase is still on its way
					end
					local pr = ctx.Profile()
					if pr and pr.Gold < cost then
						ctx.Toast("Not enough gold yet: " .. UIKit.formatNumber(cost) .. " needed.", P.crimson_300)
						return
					end
					pending[id] = os.clock()
					b.SetText("BUYING...")
					b.SetEnabled(false)
					Remotes.Get("BuyMeta"):FireServer(id, level)
					-- no answer (dropped / rejected): ask for the real profile and free the row
					task.delay(3, function()
						if pending[id] and os.clock() - pending[id] >= 2.9 then
							pending[id] = nil
							Remotes.Get("RequestProfile"):FireServer()
						end
					end)
				end,
			})
			b.SetEnabled(affordable and not busy)
		else
			local done = UIKit.Badge(f, "MAXED", "Gold", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12) })
			done.Size = UDim2.fromOffset(0, 26)
		end
		if lastLevels[id] ~= nil and level > lastLevels[id] then
			UIAnim.Punch(f, 0.06)
			UIAnim.Pop(rank, 0, 1.4)
			UIAnim.Flash(f, P.gold_300)
			UIAnim.Burst(f, UDim2.fromScale(0.5, 0.45), { P.gold_300, P.gold_500, P.ivory_100 }, 18, 80)
		end
		lastLevels[id] = level
		return f
	end

	local function shopCard(p, item, order: number)
		local f = card(order)
		local id = itemId(item)
		Icons.Draw(f, item.Icon, { Size = 52 })
		if item.Key == "DoubleGold" then
			UIKit.Badge(f, "2x", "Gold", { Position = UDim2.fromOffset(30, 34) })
		end
		text(f, "H3", item.Name, { Position = UDim2.fromOffset(64, 2), Size = UDim2.new(1, -64, 0, TS(18) + 4) })
		text(f, "Small", item.Desc, { Position = UDim2.fromOffset(64, 6 + TS(18)), Size = UDim2.new(1, -64, 0, TS(14) * 2 + 4), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
		local ownedPass = item.Kind == "Pass" and p.Passes[item.Key] == true
		if ownedPass then
			UIKit.Badge(f, "OWNED", "Moss", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -14) })
		elseif id == 0 then
			text(f, "Caption", UIKit.track("Not set up yet"), { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -14), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextFaint })
		else
			local b = UIKit.Button(f, {
				Kind = "Outline",
				Title = prices[id] and ("R$ " .. UIKit.formatNumber(prices[id])) or "BUY",
				Icon = "robux",
				IconSize = 20,
				Align = "Center",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, 50),
				Shadow = false,
				OnClick = function()
					if item.Kind == "Pass" then
						MarketplaceService:PromptGamePassPurchase(player, id)
					else
						MarketplaceService:PromptProductPurchase(player, id)
					end
				end,
			})
			if not prices[id] then
				task.spawn(function()
					local ok, info = pcall(function()
						return MarketplaceService:GetProductInfo(id, item.Kind == "Pass" and Enum.InfoType.GamePass or Enum.InfoType.Product)
					end)
					if ok and info and info.PriceInRobux then
						prices[id] = info.PriceInRobux
						if b.Instance.Parent then
							b.SetText("R$ " .. UIKit.formatNumber(info.PriceInRobux))
						end
					end
				end)
			end
		end
		return f
	end

	local function rebuild(animate: boolean)
		for _, c in ipairs(ui.Scroll:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local p = ctx.Profile()
		if not p then
			return
		end
		-- a fresh profile answers every purchase in flight
		table.clear(pending)
		if tab == "Permanent" then
			ui.Note.Text = "Permanent upgrades are bought with gold and last forever."
		else
			ui.Note.Text = "Gold and cosmetics only: nothing here makes you stronger in a run."
		end
		ui.Note.TextColor3 = C.TextMuted
		if p.MemoryOnly then
			ui.Note.Text = "Studio test: DataStores are off, progress will not be saved."
			ui.Note.TextColor3 = C.TextDanger
		end
		local n = 0
		if tab == "Permanent" then
			for order, id in ipairs(MetaUpgradeData.Order) do
				local f = metaCard(p, id, order)
				n += 1
				if animate then
					UIAnim.Pop(f, 0.03 * n, 0.7)
				end
			end
		else
			for order, item in ipairs(SHOP) do
				local f = shopCard(p, item, order)
				n += 1
				if animate then
					UIAnim.Pop(f, 0.03 * n, 0.7)
				end
			end
		end
	end
	MenuUpgrades._rebuild = rebuild

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		local top = headY + 66 + (portrait and 58 or 0)
		if not portrait then
			top = math.max(top, 76)
		end
		local w = math.min(W - 2 * M, 960)
		ui.Panel.Position = UDim2.fromOffset((W - w) / 2, top)
		ui.Panel.Size = UDim2.fromOffset(w, H - top - M)
		local inner = w - 32 - 12
		local cols = math.max(1, math.floor((inner + 12) / (portrait and 270 or 290)))
		local cw = math.floor((inner - (cols - 1) * 12) / cols)
		ui.Grid.CellSize = UDim2.fromOffset(cw, UIKit.IsCompact() and 206 or 190)
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			if screen.Visible then
				rebuild(false)
			end
		end,
		OnShow = function(_p)
			rebuild(true)
			UIAnim.Pop(ui.Panel, 0, 0.92)
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end,
	}
end

MenuUpgrades._rebuild = function(_animate: boolean) end

return MenuUpgrades
