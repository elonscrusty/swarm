--[[
	MenuCollection.lua
	The COLLECTION book (feature 24, Config.Features.CollectionBook): enemies, bosses,
	weapons, passives, items and heroes (CollectionData). What you have met, owned or played
	shows in colour with its name; the rest are dark silhouettes marked "???". Nothing is
	counted here: the server records it (JournalService, DiscoveryService) and the book
	reads the profile. Half the book and the full book each earn a title (MetaService).
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local CollectionData = require(Shared:WaitForChild("CollectionData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MetaUI = require(script.Parent.MetaUI)

local MenuCollection = {}

local new, TS = UIKit.new, UIKit.TS
local C = Theme.Color

function MenuCollection.Summary(p: { [string]: any }?): string
	local seen, total = CollectionData.Progress(p)
	return string.format("%d / %d found", seen, total)
end

local ROWS = {
	{ { Id = "Enemies", Title = "Enemies" }, { Id = "Bosses", Title = "Bosses" }, { Id = "Weapons", Title = "Weapons" } },
	{ { Id = "Passives", Title = "Passives" }, { Id = "Items", Title = "Items" }, { Id = "Heroes", Title = "Heroes" } },
}

function MenuCollection.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "COLLECTION")
	local progress = MetaUI.Line(ui.Head, "Label", "", 16, { Name = "Progress", TextColor3 = C.BlueDeep })
	local selected = "Enemies"
	local fill: () -> ()
	local tabRows = {}
	for i, items in ipairs(ROWS) do
		tabRows[i] = UIKit.Tabs(ui.Head, items, function(id: string)
			selected = id
			for j, t in ipairs(tabRows) do
				if j ~= i then
					t.Select("") -- the other row shows nothing picked
				end
			end
			fill()
		end, { Name = "Tabs" .. i })
	end
	tabRows[2].Select("")
	local grid = new("UIGridLayout", { CellPadding = UDim2.fromOffset(8, 8), CellSize = UDim2.fromOffset(96, 96), SortOrder = Enum.SortOrder.LayoutOrder }, ui.Body)
	UIKit.padding(ui.Body, 2, 2, 2, 2)

	fill = function()
		local p = ctx.Profile()
		local c = CollectionData.Categories[selected]
		local seen, total = CollectionData.Progress(p, selected)
		local all, allTotal = CollectionData.Progress(p)
		progress.Text = string.format("%s %d/%d · BOOK %d/%d", c.Title, seen, total, all, allTotal)
		MetaUI.Clear(ui.Body)
		for i, id in ipairs(c.Ids) do
			local known = c.Known(p, id)
			MetaUI.Tile(ui.Body, {
				Name = id,
				Order = i + (known and 0 or 1000),
				Icon = c.Icon(id),
				Character = selected == "Heroes" and id or nil,
				Text = c.Name(id),
				Known = known,
			})
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local lineH = TS(16) + 6
		local tabH = Theme.Size.TapMin
		ui.Layout(v, portrait, ins, lineH + 8 + tabH * 2 + 6, 0)
		local w = ui.Head.Size.X.Offset
		MetaUI.place(progress, 0, 0, w, lineH)
		MetaUI.place(tabRows[1].Frame, 0, lineH + 8, w, tabH)
		MetaUI.place(tabRows[2].Frame, 0, lineH + 8 + tabH + 6, w, tabH)
		local bw = w - 10
		local cols = math.max(3, math.floor((bw + 8) / (96 + 8)))
		local cell = math.floor((bw - (cols - 1) * 8) / cols)
		grid.CellSize = UDim2.fromOffset(cell, math.max(92, cell))
	end

	return {
		Layout = layout,
		Refresh = function(_p)
			if screen.Visible then
				fill()
			end
		end,
		OnShow = function(_p)
			fill()
			layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
			UIAnim.Pop(ui.Panel, 0, 0.96)
		end,
	}
end

return MenuCollection
