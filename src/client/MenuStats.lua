--[[
	MenuStats.lua
	The STATS screen (replaces the old in-world stats sign), two tabs:
	  STATS         everything the profile knows in three aligned groups of tiles (icon,
	                gold caps caption, big value): RUN RECORDS (best time, best stage, wins,
	                runs, win rate, total kills), COLLECTION (characters, skins, permanent
	                upgrade levels, achievements, each with a proportional bar), RESOURCES
	                (gold, saved revives) and the passes line
	  ACHIEVEMENTS  every AchievementData milestone: icon, name, what to do, the reward,
	                a progress bar (or DONE), plus the earned titles / name colours to wear
	                (EquipCosmetic; shown on the lobby nameplate)
]]

local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Remotes"))

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Config = require(Shared:WaitForChild("Config"))
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

-- The STATS tab's three groups; Bar = a proportional bar under the value (have / total).
local GROUPS = {
	{
		Caption = "Run records",
		Tiles = {
			{ Key = "Best", Icon = "stat_BestTime", Caption = "Best time" },
			{ Key = "Stage", Icon = "portal", Caption = "Best stage" },
			{ Key = "Wins", Icon = "stat_Wins", Caption = "Wins" },
			{ Key = "Runs", Icon = "stat_Runs", Caption = "Runs played" },
			{ Key = "Rate", Icon = "stat_WinRate", Caption = "Win rate" },
			{ Key = "Kills", Icon = "stat_Kills", Caption = "Total kills" },
		},
	},
	{
		Caption = "Collection",
		Bars = true,
		Tiles = {
			{ Key = "Heroes", Icon = "stat_Heroes", Caption = "Characters" },
			{ Key = "Skins", Icon = "stat_Skins", Caption = "Skins owned" },
			{ Key = "Meta", Icon = "stat_Upgrades", Caption = "Upgrade levels" },
			{ Key = "Ach", Icon = "ach_Badge", Caption = "Achievements" },
		},
	},
	{
		Caption = "Resources",
		Tiles = {
			{ Key = "Gold", Icon = "stat_Gold", Caption = "Gold" },
			{ Key = "Revives", Icon = "revive", Caption = "Saved revives" },
		},
	},
}
local TILE_H = 88 -- a stat tile; +16 with a bar
local GAP = 12

function MenuStats.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Values = {} }
	ui.Header = UIKit.ScreenHeader(screen, "YOUR STATS", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35 })
	ui.Panel = holder
	UIKit.padding(face, 16, 16, 16, 16)
	local tab = "Stats"
	local TABS_H = Theme.Size.TapMin + 10
	ui.Tabs = UIKit.Tabs(face, {
		{ Id = "Stats", Title = "Stats", Icon = "bars" },
		{ Id = "Achievements", Title = "Achievements", Icon = "ach_Badge" },
		{ Id = "Journal", Title = "Journal", Icon = "skull" }, -- the enemy journal (not the stats bars)
	}, function(id)
		if id == "Journal" then
			ui.Tabs.Select(tab)
			ctx.ShowScreen("Journal")
			return
		end
		tab = id
		MenuStats._show(true)
	end)
	local scroll = new("ScrollingFrame", {
		Name = "StatsScroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, TABS_H),
		Size = UDim2.new(1, 0, 1, -TABS_H),
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	ui.Tiles = {}
	ui.Bars = {}
	ui.Groups = {}
	for gi, g in ipairs(GROUPS) do
		local group = { Label = UIKit.SectionLabel(scroll, g.Caption), Tiles = {}, Bars = g.Bars == true }
		for _, t in ipairs(g.Tiles) do
			local f = UIKit.Panel(scroll, { Name = t.Key }, true)
			f.BackgroundColor3 = P.slate_950
			f.BackgroundTransparency = 0.3
			Icons.Draw(f, t.Icon, { Name = "Icon", Size = 30, Position = UDim2.fromOffset(14, 12), Back = P.slate_950 })
			text(f, "Caption", UIKit.track(t.Caption), { Name = "Caption", Position = UDim2.fromOffset(52, 12), Size = UDim2.new(1, -60, 0, 30), TextColor3 = P.gold_300, TextTruncate = Enum.TextTruncate.AtEnd })
			ui.Values[t.Key] = text(f, "Number", "-", { Name = "Value", Position = UDim2.fromOffset(14, 46), Size = UDim2.new(1, -28, 0, TS(26) + 4), TextTruncate = Enum.TextTruncate.AtEnd }, 26)
			if g.Bars then
				ui.Bars[t.Key] = UIKit.Meter(f, {
					Gradient = ColorSequence.new(P.gold_500, P.gold_300),
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.new(0, 14, 1, -14),
					Size = UDim2.new(1, -28, 0, 8),
				})
			end
			table.insert(group.Tiles, f)
			table.insert(ui.Tiles, f)
		end
		ui.Groups[gi] = group
	end
	ui.Passes = text(scroll, "Small", "", { Name = "Passes", TextXAlignment = Enum.TextXAlignment.Center })
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
		ui.Bars.Heroes.Set(heroes / math.max(1, #CharacterData.Order))
		local skins, total = 0, 0
		for skinId in pairs(CharacterData.Skins) do
			total += 1
			if p.OwnedSkins and p.OwnedSkins[skinId] then
				skins += 1
			end
		end
		V.Skins.Text = skins .. " / " .. total
		ui.Bars.Skins.Set(skins / math.max(1, total))
		local levels, maxLevels = 0, 0
		-- account upgrades + the selected hero's own track (Hero Mastery)
		for _, id in ipairs(MetaUpgradeData.AccountOrder) do
			levels += tonumber(p.Meta[id]) or 0
			maxLevels += MetaUpgradeData.Upgrades[id].MaxLevel
		end
		local heroId = p.SelectedCharacter or "Knight"
		local track = type(p.HeroUpgrades) == "table" and type(p.HeroUpgrades[heroId]) == "table" and p.HeroUpgrades[heroId] or {}
		for _, id in ipairs(MetaUpgradeData.HeroOrder()) do
			local def = MetaUpgradeData.HeroDef(heroId, id)
			if def then
				levels += tonumber(track[id]) or 0
				maxLevels += def.MaxLevel
			end
		end
		V.Meta.Text = levels .. " / " .. maxLevels
		ui.Bars.Meta.Set(levels / math.max(1, maxLevels))
		V.Revives.Text = tostring(p.ReviveTokens or 0)
		local done = 0
		for _, id in ipairs(AchievementData.Order) do
			if p.Achievements and p.Achievements.Unlocked and p.Achievements.Unlocked[id] then
				done += 1
			end
		end
		V.Ach.Text = done .. " / " .. #AchievementData.Order
		ui.Bars.Ach.Set(done / math.max(1, #AchievementData.Order))
		local passes = {}
		for _, key in ipairs({ "StarterPack", "VIP", "DoubleGold" }) do
			if p.Passes and p.Passes[key] then
				table.insert(passes, key == "DoubleGold" and "2x Gold" or (key == "StarterPack" and "Starter Pack" or key))
			end
		end
		ui.Passes.Text = #passes > 0 and ("Passes: " .. table.concat(passes, " · ")) or "No passes yet."
		ui.Passes.TextColor3 = #passes > 0 and P.gold_300 or C.TextFaint
	end

	-- Earned cosmetics remain explicit equip actions; rewards themselves need no claim.
	local function cosmeticRow(p, kind: string, order: number)
		local row = new("Frame", { Name = kind, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, ui.Ach)
		text(row, "Caption", UIKit.track(kind == "Title" and "Choose your title" or "Choose your name color"), { Size = UDim2.new(1, 0, 0, TS(12) + 4) })
		local chips = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, TS(12) + 8), Size = UDim2.new(1, 0, 0, Theme.Size.TapMin), AutomaticSize = Enum.AutomaticSize.Y }, row)
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
				Size = UDim2.fromOffset(math.clamp(36 + #o.Name * TS(13) * 0.7, 112, 260), Theme.Size.TapMin),
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
				text(row, "Small", "Unlock more through achievements or ACCOUNT LEVEL.", {
					Position = UDim2.fromOffset(124, TS(12) + 8),
					Size = UDim2.new(1, -124, 0, Theme.Size.TapMin),
					TextColor3 = C.TextFaint,
					TextWrapped = true,
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
		local f = UIKit.Panel(ui.Ach, { Name = id, LayoutOrder = order, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, true)
		if unlocked then
			UIKit.stroke(f, P.gold_400, 1.5, 0.25)
		end
		local column = new("Frame", { Name = "Text", BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -28, 0, 0), AutomaticSize = Enum.AutomaticSize.Y }, f)
		UIKit.list(column, { Padding = UDim.new(0, 7) })
		UIKit.padding(column, 12, 0, 14, 0)
		local heading = new("Frame", { Name = "Heading", LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40) }, column)
		Icons.Draw(heading, def.Icon or "ach_Badge", { Size = 34, Position = UDim2.fromOffset(0, 2), Back = P.slate_950 })
		text(heading, "H3", def.Name, { Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -44, 1, 0), TextColor3 = unlocked and P.gold_200 or C.Text, TextWrapped = true }, 18)
		local goal = def.Event == "RunWon" and string.format("Clear %d stages and return through the portal to win.", Config.Stages.WinMinStages) or def.Description
		text(column, "Small", goal, { Name = "Goal", LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true })
		text(column, "Small", (unlocked and "Earned: " or "Reward: ") .. AchievementData.RewardText(id), {
			Name = "Reward",
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			TextColor3 = P.gold_300,
		})
		if unlocked then
			text(column, "Caption", "COMPLETED · REWARDS ADDED", { LayoutOrder = 4, Size = UDim2.new(1, 0, 0, TS(12) + 4), TextColor3 = P.moss_200 })
		else
			text(column, "Small", (def.Kind == "Max" and "Best run: " or "Progress: ") .. AchievementData.ProgressText(id, progress), { Name = "Progress", LayoutOrder = 4, Size = UDim2.new(1, 0, 0, TS(14) + 4), TextColor3 = C.Text })
			local meter = UIKit.Meter(column, {
				Gradient = ColorSequence.new(P.gold_500, P.gold_300),
				LayoutOrder = 5,
				Size = UDim2.new(1, 0, 0, 8),
			})
			meter.Set(progress / math.max(1, def.Goal))
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
		local pending, completed = {}, {}
		for _, id in ipairs(AchievementData.Order) do
			if p.Achievements and p.Achievements.Unlocked and p.Achievements.Unlocked[id] then
				table.insert(completed, id)
			else
				table.insert(pending, id)
			end
		end
		local progress = p.Achievements and p.Achievements.Progress or {}
		table.sort(pending, function(a, b)
			local pa = (tonumber(progress[a]) or 0) / AchievementData.Achievements[a].Goal
			local pb = (tonumber(progress[b]) or 0) / AchievementData.Achievements[b].Goal
			if pa ~= pb then return pa > pb end
			return (table.find(AchievementData.Order, a) or 0) < (table.find(AchievementData.Order, b) or 0)
		end)
		local cosmeticsHeading: GuiObject?
		local summary = new("Frame", { Name = "AchievementSummary", BackgroundTransparency = 1, LayoutOrder = 0, Size = UDim2.new(1, 0, 0, Theme.Size.TapMin + 4) }, ui.Ach)
		text(summary, "Label", string.format("%d / %d UNLOCKED", #completed, #AchievementData.Order), { Size = UDim2.new(1, -230, 1, 0), TextColor3 = P.gold_300 }, 14)
		text(ui.Ach, "Small", "Rewards are added automatically. Equip earned titles and name colors with WEAR REWARDS.", { Name = "RewardHelp", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true })
		UIKit.Button(summary, { Title = "WEAR REWARDS", Kind = "Secondary", Size = UDim2.fromOffset(220, Theme.Size.TapMin), AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Icon = "sparkle", TitleSize = 14, OnClick = function()
			if cosmeticsHeading then
				ui.Ach.CanvasPosition = Vector2.new(0, math.max(0, cosmeticsHeading.AbsolutePosition.Y - ui.Ach.AbsolutePosition.Y + ui.Ach.CanvasPosition.Y))
			end
		end })
		text(ui.Ach, "Caption", #pending > 0 and "NEXT GOALS · CLOSEST FIRST" or "ALL GOALS COMPLETE", { LayoutOrder = 3, Size = UDim2.new(1, 0, 0, TS(12) + 8), TextColor3 = P.gold_300 })
		for i, id in ipairs(pending) do
			local f = achievementRow(p, id, 10 + i)
			if animate then
				UIAnim.Pop(f, math.min(0.2, 0.02 * i), 0.85)
			end
		end
		cosmeticsHeading = text(ui.Ach, "Label", "YOUR COSMETICS", { Name = "CosmeticsHeading", LayoutOrder = 100, Size = UDim2.new(1, 0, 0, TS(15) + 8), TextColor3 = P.gold_300 })
		text(ui.Ach, "Small", "Tap to equip. Gold and character rewards are already yours; cosmetic choices change your lobby nameplate.", { LayoutOrder = 101, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true })
		cosmeticRow(p, "Title", 102)
		cosmeticRow(p, "Color", 103)
		text(ui.Ach, "Label", "COMPLETED · " .. #completed, { Name = "CompletedHeading", LayoutOrder = 110, Size = UDim2.new(1, 0, 0, TS(15) + 8), TextColor3 = P.moss_200 })
		for i, id in ipairs(completed) do achievementRow(p, id, 110 + i) end
	end

	MenuStats._show = function(animate: boolean)
		ui.Header.Title.Text = tab == "Achievements" and "ACHIEVEMENTS" or "YOUR STATS"
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
		local inner = w - 32 - 10 -- face padding and the scroll bar
		ui.Narrow = w < 700
		ui.Header.Title.TextSize = TS(tab == "Achievements" and (ui.Narrow and 22 or 26) or 30)
		-- groups: every tile row lines up on one column grid (6 / 3 / 2 columns)
		local cols = inner >= 960 and 6 or (inner >= 520 and 3 or 2)
		local colsC = inner >= 640 and 4 or 2 -- collection / resources
		local y = 6
		local labelH = TS(12) + 6
		for gi, g in ipairs(ui.Groups) do
			local n = gi == 1 and cols or colsC
			local tw = math.floor((inner - (n - 1) * GAP) / n)
			local th = TILE_H + (g.Bars and 16 or 0) + (UIKit.IsCompact() and 8 or 0)
			place(g.Label, 2, y, inner, labelH)
			y += labelH + 6
			for i, f in ipairs(g.Tiles) do
				local col = (i - 1) % n
				local row = (i - 1) // n
				place(f, 2 + col * (tw + GAP), y + row * (th + GAP), tw, th)
				local value = f:FindFirstChild("Value") :: TextLabel
				value.Position = UDim2.fromOffset(14, 14 + 30 + (UIKit.IsCompact() and 4 or 2))
			end
			local rows = math.ceil(#g.Tiles / n)
			y += rows * th + (rows - 1) * GAP + 14
		end
		place(ui.Passes, 0, y - 4, inner, TS(14) + 10)
		y += TS(14) + 8
		ui.StatsScroll.CanvasSize = UDim2.fromOffset(0, y)
		local TABS_H = Theme.Size.TapMin + 10
		local fit = y + TABS_H + 34
		if tab == "Achievements" then
			fit = H -- the list scrolls: use the room there is
		end
		local h = math.min(fit, H - top - M)
		place(ui.Panel, (W - w) / 2, top, w, h)
		ui.StatsScroll.ScrollBarThickness = (tab == "Stats" and y > h - TABS_H - 32) and 4 or 0
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
		OnShow = function(_p, arg)
			-- the MORE list opens a tab directly ("Achievements" / "Stats")
			if arg == "Achievements" or arg == "Stats" then
				tab = arg
				ui.Tabs.Select(arg)
			end
			refresh()
			MenuStats._show(true)
			UIAnim.Cascade(ui.Tiles, 0.025, 0.8)
			for i = 1, 3 do
				ui.Tiles[i].ClipsDescendants = true
				UIAnim.Sweep(ui.Tiles[i], 0.2 + 0.1 * i, 0.8, 0.5)
			end
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end,
	}
end

MenuStats._show = function(_animate: boolean) end
MenuStats._layout = function() end

return MenuStats
