--[[
	MenuUpgrades.lua
	The UPGRADES screen: two tabs in one panel.
	  PERMANENT  the account-wide gold upgrades (MetaUpgradeData.AccountOrder: Revive,
	             Reroll, Skip) and a HERO UPGRADES card: the stat upgrades are bought per
	             hero on the Characters screen now (Hero Mastery), its button goes there.
	             Cards:
	             icon tile, name, what one level gives, LV n / max with rank tally marks,
	             CURRENT / NEXT effect in plain words and a gold BUY • N GOLD button (an
	             outlined "N GOLD • NEED M MORE" when short, MAXED when done). A tap marks the
	             card BUYING... until the server's ProfileSync (the gold and levels always
	             come from the server); BuyMeta carries the level the player saw, so a double
	             tap buys one level.
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
	{ Name = "500 Gold", Kind = "Product", Key = "Gold500", Icon = "shop_GoldPouch", Desc = "A pouch of gold." },
	{ Name = "1,500 Gold", Kind = "Product", Key = "Gold1500", Icon = "stat_Gold", Desc = "A sack of gold." },
	{ Name = "5,000 Gold", Kind = "Product", Key = "Gold5000", Icon = "reward_ChestGolden", Desc = "A chest of gold." },
	{ Name = "Starter Pack", Kind = "Pass", Key = "StarterPack", Icon = "shop_StarterPack", Desc = "+25% gold forever + Gold Trim skins." },
	{ Name = "VIP", Kind = "Pass", Key = "VIP", Icon = "shop_VIP", Desc = "+1 reroll per run, chat tag, lobby crown." },
	{ Name = "2x Gold", Kind = "Pass", Key = "DoubleGold", Icon = "shop_DoubleGold", Desc = "Double gold from runs." },
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
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35 })
	ui.Panel = holder
	UIKit.padding(face, 14, 16, 14, 16)
	ui.Tabs = new("Frame", { Name = "Tabs", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.Size.TapMin) }, face)
	UIKit.Hairline(ui.Tabs, { Position = UDim2.new(0, 0, 1, -1) })
	local tabButtons: { [string]: TextButton } = {}
	-- one gold underline that slides to the picked tab
	local underline = new("Frame", { Name = "Selected", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.25, 1), Size = UDim2.new(0.25, 0, 0, 2), ZIndex = 2 }, ui.Tabs)
	for i, id in ipairs({ "Permanent", "Shop" }) do
		local button = new("TextButton", {
			Name = id,
			BackgroundTransparency = 1,
			AutoButtonColor = false,
			Text = string.upper(id),
			FontFace = Theme.Font.Label,
			TextSize = TS(16),
			TextColor3 = id == tab and P.gold_300 or C.TextMuted,
			Position = UDim2.fromScale((i - 1) / 2, 0),
			Size = UDim2.fromScale(0.5, 1),
		}, ui.Tabs)
		UIKit.Focusable(button)
		tabButtons[id] = button
		button.Activated:Connect(function()
			if tab == id then return end
			tab = id
			for key, other in pairs(tabButtons) do
				other.TextColor3 = key == tab and P.gold_300 or C.TextMuted
			end
			UIAnim.SlideTo(underline, UDim2.fromScale((i - 0.5) / 2, 1))
			-- the new cards pop in (staggered) in place of the old ones
			MenuUpgrades._rebuild(true)
		end)
	end
	ui.Note = text(face, "Small", "", { Position = UDim2.fromOffset(0, Theme.Size.TapMin + 6), Size = UDim2.new(1, 0, 0, TS(14) + 6), TextColor3 = C.TextMuted, TextXAlignment = Enum.TextXAlignment.Center }, 15)
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
		f.BackgroundColor3 = P.slate_950
		f.BackgroundTransparency = 0.25
		UIKit.pad(f, 14)
		return f
	end

	local HERO_DESC = "Hero stats are now on each hero: Max HP, Might, Armor, Speed, Luck, Growth and a signature trait."

	-- lines a description needs in a card of the current width (narrow phone cards wrap
	-- to 3-4 lines instead of cutting the sentence off)
	local function descLines(desc: string): number
		local room = math.max(60, (ui.CellW or 280) - 28 - 70)
		return math.clamp(math.ceil(#desc * TS(14) * 0.5 / room), 1, 4)
	end
	local function metaDescLines(): number
		local n = 2
		for _, id in ipairs(MetaUpgradeData.AccountOrder) do
			n = math.max(n, descLines(MetaUpgradeData.Upgrades[id].Description))
		end
		return math.max(n, descLines(HERO_DESC))
	end

	-- icon tile, serif name and the description (both card kinds); a long name shrinks to
	-- fit the card instead of reading "HERO UPGRA..."
	local function cardTop(f: Frame, iconTile: () -> (), name: string, desc: string, rightW: number, lines: number?)
		iconTile()
		local title = string.upper(name)
		local room = (ui.CellW or 280) - 28 - 70 - rightW
		local size = 20
		while size > 14 and #title * TS(size) * 0.62 > room do
			size -= 1
		end
		text(f, "H2", title, { Name = "Name", Position = UDim2.fromOffset(70, 0), Size = UDim2.new(1, -70 - rightW, 0, TS(20) + 6), TextTruncate = Enum.TextTruncate.AtEnd }, size)
		local n = lines or 2
		text(f, "Small", desc, { Name = "Desc", Position = UDim2.fromOffset(70, TS(20) + 8), Size = UDim2.new(1, -70, 0, TS(14) * n + 4), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextTruncate = Enum.TextTruncate.AtEnd })
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
		local affordable = cost ~= nil and p.Gold >= cost
		local f = card(order)
		local lines = metaDescLines()
		cardTop(f, function()
			UIKit.Tile(f, { Id = Icons.MetaIcon(id), Size = 56 })
		end, def.Name, def.Description, 0, lines)
		-- one segment per level: gold = bought, ivory = the next one is affordable, dark = left
		local barY = math.max(64, TS(20) + 12 + lines * TS(14)) -- under the description
		local rank = text(f, "Label", string.format("LV %d / %d", level, def.MaxLevel), {
			Name = "Rank",
			Position = UDim2.fromOffset(0, barY),
			Size = UDim2.new(0, 90, 0, TS(13) + 4),
			TextColor3 = maxed and P.gold_300 or C.TextMuted,
		}, 13)
		local marks = new("Frame", { Name = "RankMarks", BackgroundTransparency = 1, Position = UDim2.fromOffset(92, barY + math.floor((TS(13) + 4 - 8) / 2)), Size = UDim2.new(1, -92, 0, 8) }, f)
		for i = 1, def.MaxLevel do
			local bought = i <= level
			local available = i == level + 1 and affordable
			local seg = new("Frame", {
				Name = "Rank" .. i,
				BackgroundColor3 = bought and P.gold_400 or available and P.ivory_100 or P.slate_600,
				BackgroundTransparency = (bought or available) and 0 or 0.2,
				BorderSizePixel = 0,
				Position = UDim2.new((i - 1) / def.MaxLevel, 2, 0, 1),
				Size = UDim2.new(1 / def.MaxLevel, -4, 0, 6),
			}, marks)
			UIKit.corner(seg, 3)
		end
		UIKit.Hairline(f, { Position = UDim2.fromOffset(0, barY + TS(13) + 14) })
		-- current / next effect (what the next level really gives)
		local rowY = barY + TS(13) + 22
		local rowH = TS(15) + 6
		local function effectRow(y: number, caption: string, value: string, color: Color3)
			local capW = UIKit.IsCompact() and 70 or 76
			text(f, "Caption", UIKit.track(caption), { Position = UDim2.fromOffset(0, y), Size = UDim2.new(0, capW, 0, rowH), TextColor3 = C.TextFaint })
			text(f, "BodyStrong", value, { Name = caption, Position = UDim2.fromOffset(capW, y), Size = UDim2.new(1, -capW, 0, rowH), TextColor3 = color, TextTruncate = Enum.TextTruncate.AtEnd }, UIKit.IsCompact() and 13 or 15)
		end
		effectRow(rowY, "Current", MetaUpgradeData.EffectText(id, level), C.Text)
		effectRow(rowY + rowH, "Next", maxed and "Fully upgraded" or MetaUpgradeData.EffectText(id, level + 1), maxed and P.gold_300 or P.moss_200)
		if cost then
			local busy = pending[id] ~= nil
			local b
			b = UIKit.Button(f, {
				Kind = affordable and "Primary" or "Outline",
				-- narrow phone cards: "2,500 · NEED 660" instead of a cut "2,500 GOLD · NEED 6..."
				Title = busy and "BUYING..." or (affordable and ("BUY · " .. UIKit.formatNumber(cost) .. " GOLD") or (UIKit.formatNumber(cost) .. ((ui.CellW or 280) >= 330 and " GOLD · NEED " or " · NEED ") .. UIKit.formatNumber(cost - p.Gold) .. ((ui.CellW or 280) >= 330 and " MORE" or ""))),
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
					-- no answer (dropped / rejected): ask for the real profile and free the card
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
			local done = UIKit.Button(f, {
				Kind = "Outline",
				Title = "MAXED",
				Icon = "check",
				IconSize = 20,
				Align = "Center",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.new(1, 0, 0, 46),
				Shadow = false,
				Name = "Maxed",
			})
			done.Instance.Active = false
			done.Instance.AutoButtonColor = false
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

	-- the stat upgrades moved to each hero (Characters screen, Hero Mastery)
	local function heroCard(p, order: number)
		local f = card(order)
		local selected = p.SelectedCharacter or "Knight"
		cardTop(f, function()
			Icons.Character(f, selected, { Size = 56 })
		end, "Hero upgrades", HERO_DESC, 0, metaDescLines())
		UIKit.Button(f, {
			Kind = "Primary",
			Title = "OPEN CHARACTERS",
			Icon = "chevronsUp",
			IconSize = 20,
			Align = "Center",
			Name = "HeroUpgrades",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 46),
			Shadow = false,
			OnClick = function()
				ctx.ShowScreen("Characters")
			end,
		})
		return f
	end

	local function shopCard(p, item, order: number)
		local f = card(order)
		local id = itemId(item)
		cardTop(f, function()
			Icons.Draw(f, item.Icon, { Size = 56, Idle = (item.Icon == "stat_Gold" or item.Icon == "shop_DoubleGold") and "Coin" or "Glint" })
			if item.Key == "DoubleGold" then
				UIKit.Badge(f, "2x", "Gold", { Position = UDim2.fromOffset(34, 38) })
			end
		end, item.Name, item.Desc, 0)
		local ownedPass = item.Kind == "Pass" and p.Passes[item.Key] == true
		if ownedPass then
			UIKit.Badge(f, "OWNED", "Moss", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -14) })
		elseif id == 0 then
			text(f, "Caption", UIKit.track("Coming soon"), { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -14), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextFaint })
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
		MenuUpgrades._cell()
		local p = ctx.Profile()
		if not p then
			return
		end
		-- a fresh profile answers every purchase in flight
		table.clear(pending)
		if tab == "Permanent" then
			ui.Note.Text = "Account upgrades for every hero. Hero stats are bought on each hero."
		else
			ui.Note.Text = "Gold packs, gold boosts and VIP perks. Purchases go through Roblox."
		end
		ui.Note.TextColor3 = C.TextMuted
		if p.MemoryOnly then
			ui.Note.Text = "Studio test: DataStores are off, progress will not be saved."
			ui.Note.TextColor3 = C.TextDanger
		end
		local n = 0
		if tab == "Permanent" then
			for order, id in ipairs(MetaUpgradeData.AccountOrder) do
				local f = metaCard(p, id, order)
				n += 1
				if animate then
					UIAnim.Pop(f, 0.03 * n, 0.7)
				end
			end
			local f = heroCard(p, #MetaUpgradeData.AccountOrder + 1)
			if animate then
				UIAnim.Pop(f, 0.03 * (n + 1), 0.7)
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

	-- card height: the PERMANENT cards hold the level bar and CURRENT / NEXT, the SHOP
	-- cards only the description and the button
	MenuUpgrades._cell = function()
		local metaH = math.max(64, TS(20) + 12 + metaDescLines() * TS(14)) + TS(13) + 22 + 2 * (TS(15) + 6) + 12 + 46 + 28
		local shopH = TS(20) + 8 + 2 * TS(14) + 16 + 50 + 28 + 8
		ui.Grid.CellSize = UDim2.fromOffset(ui.CellW or 280, tab == "Shop" and shopH or metaH)
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
		local w = math.min(W - 2 * M, 960)
		ui.Panel.Position = UDim2.fromOffset((W - w) / 2, top)
		ui.Panel.Size = UDim2.fromOffset(w, H - top - M)
		local inner = w - 32 - 12
		local cols = math.clamp(math.floor((inner + 12) / 264), 1, 3)
		local cw = math.floor((inner - (cols - 1) * 12) / cols)
		local changed = ui.CellW ~= cw
		ui.CellW = cw
		MenuUpgrades._cell()
		-- card text (description lines, title size, button label) follows the card width
		if changed and screen.Visible then
			rebuild(false)
		end
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
MenuUpgrades._cell = function() end

return MenuUpgrades
