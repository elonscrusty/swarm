--[[
	MenuStats.lua
	The STATS screen (replaces the old in-world stats sign), two tabs:
	  STATS         tiles with everything the profile knows: best time, best stage, wins,
	                runs, win rate, total kills, gold, characters and skins owned, permanent
	                upgrade levels, saved revives and passes
	  ACHIEVEMENTS  every AchievementData milestone: icon, name, what to do, the reward,
	                a progress bar (or DONE), plus the earned titles / name colours to wear
	                (EquipCosmetic; shown on the lobby nameplate)
]]

local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"))

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
local AchievementData = require(Shared:WaitForChild("AchievementData"))
local AccountData = require(Shared:WaitForChild("AccountData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local MenuStats = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

local TILES = {
	{ Key = "Best", Icon = "crown", Caption = "Best time" },
	{ Key = "Stage", Icon = "portal", Caption = "Best stage" },
	{ Key = "Wins", Icon = "trophy", Caption = "Wins" },
	{ Key = "Runs", Icon = "flag", Caption = "Runs played" },
	{ Key = "Rate", Icon = "chevronsUp", Caption = "Win rate" },
	{ Key = "Kills", Icon = "skull", Caption = "Total kills" },
	{ Key = "Gold", Icon = "coin", Caption = "Gold" },
	{ Key = "Heroes", Icon = "helmet", Caption = "Characters" },
	{ Key = "Skins", Icon = "sparkle", Caption = "Skins owned" },
	{ Key = "Meta", Icon = "sword", Caption = "Upgrade levels" },
	{ Key = "Revives", Icon = "revive", Caption = "Saved revives" },
	{ Key = "Ach", Icon = "trophy", Caption = "Achievements" },
}

function MenuStats.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Values = {} }
	ui.Header = UIKit.ScreenHeader(screen, "YOUR STATS", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	UIKit.padding(face, 16, 16, 16, 16)
	local tab = "Stats"
	local TABS_H = Theme.Size.TapMin + 10
	ui.Tabs = UIKit.Tabs(face, {
		{ Id = "Stats", Title = "Stats", Icon = "bars" },
		{ Id = "Achievements", Title = "Achievements", Icon = "trophy" },
	}, function(id)
		tab = id
		MenuStats._show(true)
	end)
	local scroll = new("ScrollingFrame", {
		Name = "StatsScroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, TABS_H),
		Size = UDim2.new(1, 0, 1, -40 - TABS_H),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
	}, face)
	UIKit.padding(scroll, 4, 6, 4, 4)
	ui.Grid = new("UIGridLayout", { CellSize = UDim2.fromOffset(200, 112), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, scroll)
	ui.Tiles = {}
	for i, t in ipairs(TILES) do
		local f = UIKit.Panel(scroll, { Name = t.Key, LayoutOrder = i }, true)
		Icons.Draw(f, t.Icon, { Size = 28, Position = UDim2.fromOffset(14, 14), Color = if t.Icon == "coin" or t.Icon == "revive" or t.Icon == "portal" then nil else P.gold_400, Back = P.slate_950 })
		ui.Values[t.Key] = text(f, "Number", "-", { Position = UDim2.fromOffset(14, 48), Size = UDim2.new(1, -28, 0, TS(28) + 4) }, 28)
		text(f, "Caption", UIKit.track(t.Caption), { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 14, 1, -10), Size = UDim2.new(1, -28, 0, TS(12) + 2) })
		ui.Tiles[i] = f
	end
	ui.Passes = text(face, "Small", "", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 30), TextXAlignment = Enum.TextXAlignment.Center })
	ui.StatsScroll = scroll

	-- achievements tab
	local ach = new("ScrollingFrame", {
		Name = "AchievementsScroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, TABS_H),
		Size = UDim2.new(1, 0, 1, -TABS_H),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
	}, face)
	UIKit.padding(ach, 2, 8, 8, 2)
	ui.AchList = UIKit.list(ach, { Padding = UDim.new(0, 8) })
	ui.Ach = ach

	local function refresh()
		local p = ctx.Profile()
		if not p then
			return
		end
		local s = p.Stats
		local V = ui.Values
		V.Best.Text = UIKit.formatTime(s.BestTime)
		V.Stage.Text = (s.BestStage or 0) > 0 and ("Stage " .. tostring(s.BestStage)) or "-"
		V.Wins.Text = UIKit.formatNumber(s.Wins)
		V.Runs.Text = UIKit.formatNumber(s.Runs)
		V.Rate.Text = s.Runs > 0 and string.format("%d%%", math.floor(s.Wins / s.Runs * 100 + 0.5)) or "-"
		V.Kills.Text = UIKit.formatNumber(s.TotalKills)
		V.Gold.Text = UIKit.formatNumber(p.Gold)
		local heroes = 0
		for _, id in ipairs(CharacterData.Order) do
			if p.OwnedCharacters[id] then
				heroes += 1
			end
		end
		V.Heroes.Text = heroes .. " / " .. #CharacterData.Order
		local skins, total = 0, 0
		for skinId in pairs(CharacterData.Skins) do
			total += 1
			if p.OwnedSkins and p.OwnedSkins[skinId] then
				skins += 1
			end
		end
		V.Skins.Text = skins .. " / " .. total
		local levels, maxLevels = 0, 0
		for _, id in ipairs(MetaUpgradeData.Order) do
			levels += p.Meta[id] or 0
			maxLevels += MetaUpgradeData.Upgrades[id].MaxLevel
		end
		V.Meta.Text = levels .. " / " .. maxLevels
		V.Revives.Text = tostring(p.ReviveTokens or 0)
		local done = 0
		for _, id in ipairs(AchievementData.Order) do
			if p.Achievements and p.Achievements.Unlocked and p.Achievements.Unlocked[id] then
				done += 1
			end
		end
		V.Ach.Text = done .. " / " .. #AchievementData.Order
		local passes = {}
		for _, key in ipairs({ "StarterPack", "VIP", "DoubleGold" }) do
			if p.Passes and p.Passes[key] then
				table.insert(passes, key == "DoubleGold" and "2x Gold" or (key == "StarterPack" and "Starter Pack" or key))
			end
		end
		ui.Passes.Text = #passes > 0 and ("Passes: " .. table.concat(passes, " · ")) or "No passes yet."
		ui.Passes.TextColor3 = #passes > 0 and P.gold_300 or C.TextFaint
	end

	-- one row per achievement; built fresh on every refresh (12 rows)
	local function cosmeticRow(p, kind: string, order: number)
		local row = new("Frame", { Name = kind, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, ui.Ach)
		text(row, "Caption", UIKit.track(kind == "Title" and "Wear title" or "Name colour"), { Size = UDim2.new(1, 0, 0, TS(12) + 4) })
		local chips = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, TS(12) + 8), Size = UDim2.new(1, 0, 0, 40), AutomaticSize = Enum.AutomaticSize.Y }, row)
		UIKit.list(chips, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), Wraps = true })
		local unlocked = p.Achievements and p.Achievements.Unlocked or {}
		local options = { { Id = "", Name = "None" } }
		if kind == "Title" then
			for _, id in ipairs(AchievementData.Order) do
				local r = AchievementData.Achievements[id].Reward
				if r.Title and unlocked[id] then
					table.insert(options, { Id = r.Title, Name = r.Title })
				end
			end
		else
			for _, cid in ipairs(AchievementData.ColorOrder) do
				local src = AchievementData.Source("Color", cid)
				if src and unlocked[src] then
					table.insert(options, { Id = cid, Name = AchievementData.Colors[cid].Name, Color = AchievementData.Colors[cid].Color })
				end
			end
		end
		-- the account level track's titles / colours (TRACK screen)
		local level = (p.Account and AccountData.LevelFor(tonumber(p.Account.XP) or 0)) or 1
		for _, lv in ipairs(AccountData.RewardLevels) do
			for _, r in ipairs(AccountData.Rewards[lv]) do
				if r.Kind == kind and level >= lv then
					local c = kind == "Color" and AccountData.Colors[r.Id] or nil
					table.insert(options, { Id = r.Id, Name = c and c.Name or r.Id, Color = c and c.Color or nil })
				end
			end
		end
		local worn = (kind == "Title" and p.Title or p.NameColor) or ""
		for i, o in ipairs(options) do
			local b = UIKit.Button(chips, {
				Kind = o.Id == worn and "Primary" or "Ghost",
				Title = string.upper(o.Name),
				Size = UDim2.fromOffset(math.max(100, 44 + #o.Name * 14), 40),
				LayoutOrder = i,
				Shadow = false,
				Radius = Theme.Radius.S,
				Align = "Center",
				OnClick = function()
					Remotes.Get("EquipCosmetic"):FireServer(kind, o.Id)
				end,
			})
			if o.Color and b.Title and o.Id ~= worn then
				b.Title.TextColor3 = o.Color
			end
		end
		if #options == 1 then
			text(row, "Small", kind == "Title" and "Earn titles from achievements and the TRACK." or "Earn name colours from achievements and the TRACK.", {
				Position = UDim2.fromOffset(112, TS(12) + 8),
				Size = UDim2.new(1, -112, 0, 40),
				TextColor3 = C.TextFaint,
			})
		end
	end

	local function achievementRow(p, id: string, order: number)
		local def = AchievementData.Achievements[id]
		local unlocked = p.Achievements and p.Achievements.Unlocked and p.Achievements.Unlocked[id] ~= nil
		local progress = p.Achievements and p.Achievements.Progress and tonumber(p.Achievements.Progress[id]) or 0
		if unlocked then
			progress = def.Goal
		end
		-- the row grows with its text (narrow phones wrap the description / reward)
		local right = ui.Narrow and 112 or 150
		local f = UIKit.Panel(ui.Ach, { Name = id, LayoutOrder = order, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, true)
		if unlocked then
			UIKit.stroke(f, P.gold_400, 1.5, 0.25)
		end
		Icons.Draw(f, def.Icon or "trophy", { Size = 36, Position = UDim2.fromOffset(14, 14), Color = (not unlocked) and P.stone_400 or nil, Back = P.slate_950 })
		local column = new("Frame", { Name = "Text", BackgroundTransparency = 1, Position = UDim2.fromOffset(64, 0), Size = UDim2.new(1, -64 - right, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, f)
		UIKit.list(column, { Padding = UDim.new(0, 2) })
		UIKit.padding(column, 10, 0, 12, 0)
		text(column, "H3", def.Name, { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, TS(18) + 4), TextColor3 = unlocked and P.gold_200 or C.Text, TextTruncate = Enum.TextTruncate.AtEnd })
		text(column, "Small", def.Description, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true })
		text(column, "Small", "Reward: " .. AchievementData.RewardText(id), {
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			TextColor3 = P.gold_300,
		})
		if unlocked then
			UIKit.Badge(f, "DONE", "Gold", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0) })
		else
			local meter = UIKit.Meter(f, {
				Gradient = ColorSequence.new(P.gold_500, P.gold_300),
				TextStyle = "Number",
				TextSize = Theme.TextSize.Small,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -14, 0.5, 0),
				Size = UDim2.fromOffset(right - 20, 22),
			})
			meter.Set(progress / math.max(1, def.Goal), AchievementData.ProgressText(id, progress))
		end
		return f
	end

	local function refreshAchievements(animate: boolean)
		for _, c in ipairs(ui.Ach:GetChildren()) do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local p = ctx.Profile()
		if not p then
			return
		end
		local done = 0
		for _, id in ipairs(AchievementData.Order) do
			if p.Achievements and p.Achievements.Unlocked and p.Achievements.Unlocked[id] then
				done += 1
			end
		end
		text(ui.Ach, "Label", string.format("%d / %d ACHIEVEMENTS", done, #AchievementData.Order), { LayoutOrder = 0, Size = UDim2.new(1, 0, 0, TS(15) + 6), TextColor3 = P.gold_300 })
		cosmeticRow(p, "Title", 1)
		cosmeticRow(p, "Color", 2)
		for i, id in ipairs(AchievementData.Order) do
			local f = achievementRow(p, id, 10 + i)
			if animate then
				UIAnim.Pop(f, 0.02 * i, 0.85)
			end
		end
	end

	MenuStats._show = function(animate: boolean)
		ui.StatsScroll.Visible = tab == "Stats"
		ui.Passes.Visible = tab == "Stats"
		ui.Ach.Visible = tab == "Achievements"
		if tab == "Achievements" then
			refreshAchievements(animate)
		end
		MenuStats._layout()
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local w = math.min(W - 2 * M, 1100)
		local inner = w - 32 - 10
		local cols = math.clamp(math.floor((inner + 12) / 200), 2, 5)
		local cellH = UIKit.IsCompact() and 124 or 112
		ui.Narrow = w < 700
		ui.Grid.CellSize = UDim2.fromOffset(math.floor((inner - (cols - 1) * 12) / cols), cellH)
		local rows = math.ceil(#TILES / cols)
		local fit = rows * (cellH + 12) + 32 + 8 + 40 + Theme.Size.TapMin + 10
		if tab == "Achievements" then
			fit = H -- the list scrolls: use the room there is
		end
		place(ui.Panel, (W - w) / 2, top, w, math.min(fit, H - top - M))
	end
	MenuStats._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			refresh()
			if tab == "Achievements" and screen.Visible then
				refreshAchievements(false)
			end
		end,
		OnShow = function(_p)
			refresh()
			MenuStats._show(true)
			for i, f in ipairs(ui.Tiles) do
				UIAnim.Pop(f, 0.025 * i, 0.75)
			end
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end,
	}
end

MenuStats._show = function(_animate: boolean) end
MenuStats._layout = function() end

return MenuStats
