--[[
	MenuStats.lua
	The STATS screen (replaces the old in-world stats sign): a panel of tiles with
	everything the profile knows: best time, wins, runs, win rate, total kills, gold,
	characters and skins owned, permanent upgrade levels, saved revives and passes.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local CharacterData = require(Shared:WaitForChild("CharacterData"))
local MetaUpgradeData = require(Shared:WaitForChild("MetaUpgradeData"))
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
	{ Key = "Wins", Icon = "trophy", Caption = "Wins" },
	{ Key = "Runs", Icon = "flag", Caption = "Runs played" },
	{ Key = "Rate", Icon = "chevronsUp", Caption = "Win rate" },
	{ Key = "Kills", Icon = "skull", Caption = "Total kills" },
	{ Key = "Gold", Icon = "coin", Caption = "Gold" },
	{ Key = "Heroes", Icon = "helmet", Caption = "Characters" },
	{ Key = "Skins", Icon = "sparkle", Caption = "Skins owned" },
	{ Key = "Meta", Icon = "sword", Caption = "Upgrade levels" },
	{ Key = "Revives", Icon = "revive", Caption = "Saved revives" },
}

function MenuStats.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Values = {} }
	ui.Header = UIKit.ScreenHeader(screen, "YOUR STATS", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	UIKit.padding(face, 16, 16, 16, 16)
	local scroll = new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 1, -40),
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
		Icons.Draw(f, t.Icon, { Size = 28, Position = UDim2.fromOffset(14, 14), Color = if t.Icon == "coin" or t.Icon == "revive" then nil else P.gold_400, Back = P.slate_950 })
		ui.Values[t.Key] = text(f, "Number", "-", { Position = UDim2.fromOffset(14, 48), Size = UDim2.new(1, -28, 0, TS(28) + 4) }, 28)
		text(f, "Caption", UIKit.track(t.Caption), { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 14, 1, -10), Size = UDim2.new(1, -28, 0, TS(12) + 2) })
		ui.Tiles[i] = f
	end
	ui.Passes = text(face, "Small", "", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 30), TextXAlignment = Enum.TextXAlignment.Center })

	local function refresh()
		local p = ctx.Profile()
		if not p then
			return
		end
		local s = p.Stats
		local V = ui.Values
		V.Best.Text = UIKit.formatTime(s.BestTime)
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
		local passes = {}
		for _, key in ipairs({ "StarterPack", "VIP", "DoubleGold" }) do
			if p.Passes and p.Passes[key] then
				table.insert(passes, key == "DoubleGold" and "2x Gold" or (key == "StarterPack" and "Starter Pack" or key))
			end
		end
		ui.Passes.Text = #passes > 0 and ("Passes: " .. table.concat(passes, " · ")) or "No passes yet."
		ui.Passes.TextColor3 = #passes > 0 and P.gold_300 or C.TextFaint
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
		ui.Grid.CellSize = UDim2.fromOffset(math.floor((inner - (cols - 1) * 12) / cols), cellH)
		local rows = math.ceil(#TILES / cols)
		local fit = rows * (cellH + 12) + 32 + 8 + 40
		place(ui.Panel, (W - w) / 2, top, w, math.min(fit, H - top - M))
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			refresh()
		end,
		OnShow = function(_p)
			refresh()
			for i, f in ipairs(ui.Tiles) do
				UIAnim.Pop(f, 0.025 * i, 0.75)
			end
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
		end,
	}
end

return MenuStats
