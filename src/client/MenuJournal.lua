-- Manually opened field notes; no automatic introductions or build recommendations.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Journal = require(Shared:WaitForChild("EnemyJournalData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local MenuJournal = {}
local C = Theme.Color

function MenuJournal.Build(screen: Frame, ctx: { [string]: any })
	-- opened from the STATS screen's JOURNAL tab: BACK returns there, not to the home screen
	local header = UIKit.ScreenHeader(screen, "Enemy journal", function()
		ctx.ShowScreen("Stats")
	end)
	local holder, face = UIKit.Surface(screen, { Name = "Journal", Radius = Theme.Radius.L })
	UIKit.padding(face, 20, 20, 20, 20)
	local count = UIKit.text(face, "H3", "", { Name = "DiscoveryCount", Size = UDim2.new(1, 0, 0, 28), TextColor3 = C.BlueDeep }, 18)
	local note = UIKit.text(face, "Small", "Attack clues from enemies you have encountered. Drops appear only after you observe them.", { Position = UDim2.fromOffset(0, 34), Size = UDim2.new(1, 0, 0, 44), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top }, 14)
	local scroll = UIKit.new("ScrollingFrame", { Name = "Entries", BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 84), Size = UDim2.new(1, 0, 1, -84), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 5, ScrollBarImageColor3 = C.PanelEdge }, face)
	UIKit.list(scroll, { Padding = UDim.new(0, 16) })
	local entries = {}
	for i, id in ipairs(Journal.Order) do
		local row = UIKit.new("Frame", { Name = id, BackgroundTransparency = 1, Size = UDim2.new(1, -10, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i }, scroll)
		UIKit.list(row, { Padding = UDim.new(0, 6) })
		local name = UIKit.text(row, "H3", "", { Name = "EnemyName", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, LayoutOrder = 1 }, 18)
		local clue = UIKit.text(row, "Body", "", { Name = "AttackClue", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, LineHeight = 1.15, LayoutOrder = 2 }, 15)
		local drops = UIKit.text(row, "Small", "", { Name = "ObservedDrops", Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextColor3 = C.BlueDeep, LayoutOrder = 3 }, 14)
		UIKit.Hairline(row, { LayoutOrder = 4 })
		entries[id] = { Frame = row, Order = i, Name = name, Clue = clue, Drops = drops }
	end
	local function refresh()
		local discovered = 0
		local profile = ctx.Profile()
		for id, row in pairs(entries) do
			local entry = Journal.Entry(profile, id)
			if entry.Known then discovered += 1 end
			-- recorded enemies first, the unknown placeholders after them (same order within each)
			row.Frame.LayoutOrder = row.Order + (entry.Known and 0 or #Journal.Order)
			row.Name.Text = entry.Name
			row.Name.TextColor3 = entry.Known and C.Text or C.TextFaint
			row.Clue.Text = entry.Clue
			row.Clue.TextColor3 = entry.Known and C.Text or C.TextFaint
			row.Drops.Text = entry.Known and (#entry.Drops > 0 and "Observed drops: " .. table.concat(entry.Drops, " · ") or "No drops observed yet.") or ""
			row.Drops.Visible = entry.Known
		end
		count.Text = string.format("%d / %d ENEMIES RECORDED", discovered, #Journal.Order)
	end
	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local margin = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		header.Frame.Position = UDim2.fromOffset(margin, headY)
		header.Frame.Size = UDim2.fromOffset(v.X - 2 * margin, 56)
		local y = headY + 66 + (portrait and 58 or 0)
		local w = math.min(1000, v.X - 2 * margin)
		holder.Position = UDim2.fromOffset((v.X - w) / 2, y)
		holder.Size = UDim2.fromOffset(w, math.max(100, v.Y - y - margin))
		note.TextSize = UIKit.TS(14)
	end
	return {
		Layout = layout,
		Refresh = function(_profile) refresh() end,
		OnShow = function(_profile)
			refresh()
			layout(ctx.Host.VirtualSize(), ctx.Host.IsPortrait(), ctx.Host.Insets())
			UIAnim.Pop(holder, 0, 0.96)
		end,
	}
end

return MenuJournal
