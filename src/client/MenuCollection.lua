--[[
	MenuCollection.lua  (stream L1, docs/redesign/lobby/L1_STATUS.md)
	The CODEX (the lobby's COLLECTION screen, Config.Features.CollectionBook): what the redesigned game
	contains, from the real data modules (SwarmV2.Lobby.CodexData): the 12 classes, the 15 weapons, the
	8 loot passives, the 4 evolutions, the run's enemies (beetle, floating eye, root runner, stump brute,
	sap lobber, the elite marker, the Basin Breaker) and the controls of each device.

	Tap an entry to open or close its details. Discovery follows the rules that already exist: an entry
	the player has not found shows "???" and how to find it, never its details (CodexData.Known:
	CollectionData / DiscoveryService / Journal). Nothing is counted here: the server records it and the
	book reads the profile. Categories that do not exist in this build are simply not listed.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local V2 = game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2")
local Theme = require(Shared:WaitForChild("Theme"))
local CodexData = require(V2:WaitForChild("Lobby"):WaitForChild("CodexData"))
local ClassCatalog = require(V2:WaitForChild("ClassCatalog"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)
local MetaUI = require(script.Parent.MetaUI)

local MenuCollection = {}

local new, TS = UIKit.new, UIKit.TS
local C = Theme.Color

function MenuCollection.Summary(p: { [string]: any }?): string
	local seen, total = CodexData.Progress(p)
	return string.format("%d / %d found", seen, total)
end

-- the tab rows: three categories each
local ROWS = { { "Classes", "Weapons", "Passives" }, { "Evolutions", "Enemies", "Controls" } }

-- A round picture for an entry: the class colours, a drawn icon, or a plain disc with its initial.
local function picture(well: Frame, categoryId: string, entry: { [string]: any }, known: boolean)
	local size = 44
	if not known then
		local disc = new("Frame", { Name = "Unknown", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size, size), BackgroundColor3 = C.Disabled, BorderSizePixel = 0 }, well)
		UIKit.corner(disc, 999)
		UIKit.text(disc, "Label", "?", { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextFaint }, 22)
		return
	end
	if categoryId == "Classes" then
		local info = ClassCatalog.Get(entry.Id)
		local disc = new("Frame", { Name = "Swatch", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size, size), BackgroundColor3 = info and info.Primary or C.PanelInset, BorderSizePixel = 0 }, well)
		UIKit.corner(disc, 999)
		UIKit.stroke(disc, info and info.Accent or C.PanelEdge, 3, 0)
		return
	end
	local icon: string? = entry.Icon
	if icon and Icons.Has(icon) then
		if icon == "skull" or icon == "crown" or icon == "info" then
			local tint: Color3? = if icon ~= "info" then C.Danger else nil
			Icons.Draw(well, icon, { Size = size, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelRaised, Color = tint })
		else
			Icons.Upgrade(well, icon, { Size = size, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelRaised })
		end
		return
	end
	local disc = new("Frame", { Name = "Disc", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size, size), BackgroundColor3 = C.BluePale, BorderSizePixel = 0 }, well)
	UIKit.corner(disc, 999)
	UIKit.stroke(disc, C.PanelEdge, 3, 0)
	UIKit.text(disc, "Label", string.upper(string.sub(entry.Name, 1, 1)), { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.BlueDeep }, 22)
end

function MenuCollection.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui = MetaUI.Screen(screen, ctx, "CODEX", 900)
	local progress = MetaUI.Line(ui.Head, "Label", "", 16, { Name = "Progress", TextColor3 = C.BlueDeep })
	local selected = "Classes"
	local openId: string? = nil
	local fill: () -> ()
	local tabRows = {}
	for i, ids in ipairs(ROWS) do
		local items = {}
		for _, id in ipairs(ids) do
			local cat = CodexData.Category(id)
			if cat then
				table.insert(items, { Id = id, Title = cat.Title })
			end
		end
		tabRows[i] = UIKit.Tabs(ui.Head, items, function(id: string)
			selected = id
			openId = nil
			for j, t in ipairs(tabRows) do
				if j ~= i then
					t.Select("") -- the other row shows nothing picked
				end
			end
			fill()
		end, { Name = "Tabs" .. i })
	end
	tabRows[2].Select("")
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 8) }, ui.Body)
	UIKit.padding(ui.Body, 2, 8, 2, 2)

	local function entryRow(cat: any, entry: any, order: number, known: boolean)
		local isOpen = openId == entry.Id
		local holder = new("Frame", { Name = "Entry_" .. entry.Id, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 10), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, ui.Body)
		new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, holder)
		local head = new("TextButton", {
			Name = "Head",
			Text = "",
			AutoButtonColor = false,
			BackgroundColor3 = known and C.PanelRaised or C.Disabled,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 64),
			LayoutOrder = 1,
		}, holder)
		UIKit.Focusable(head)
		UIKit.corner(head, Theme.Radius.M)
		UIKit.stroke(head, known and C.PanelEdge or C.Divider, 2, 0)
		local well = new("Frame", { Name = "Well", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 8), Size = UDim2.fromOffset(48, 48) }, head)
		picture(well, cat.Id, entry, known)
		MetaUI.Line(head, "Label", known and entry.Name or "???", 17, { Name = "EntryName", Position = UDim2.fromOffset(68, 8), Size = UDim2.new(1, -112, 0, TS(17) + 4), TextColor3 = known and C.Text or C.TextFaint })
		MetaUI.Line(head, "Small", known and entry.Sub or ("Not found yet. " .. cat.Hint), 13, { Name = "EntrySub", Position = UDim2.fromOffset(68, 12 + TS(17)), Size = UDim2.new(1, -112, 0, TS(13) + 4), TextColor3 = known and C.TextMuted or C.TextFaint })
		Icons.Draw(head, isOpen and "chevronsUp" or "chevronRight", { Name = "Caret", Size = 22, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Color = C.BlueDeep })
		head.Activated:Connect(function()
			if openId == entry.Id then
				openId = nil
			else
				openId = entry.Id
			end
			fill()
		end)
		if isOpen then
			local box = new("Frame", { Name = "Detail", BackgroundColor3 = C.PanelInset, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 10), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2 }, holder)
			UIKit.corner(box, Theme.Radius.M)
			UIKit.padding(box, 10, 12, 10, 12)
			UIKit.list(box, { Padding = UDim.new(0, 6) })
			if known then
				local d = CodexData.Detail(cat.Id, entry.Id)
				for i, line in ipairs(d.Lines) do
					UIKit.text(box, "Body", line, { Name = "Line" .. i, LayoutOrder = i, Size = UDim2.new(1, 0, 0, 10), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.Text }, 15)
				end
				for i, r in ipairs(d.Rows) do
					UIKit.text(box, "Small", r.Label .. ": " .. r.Value, { Name = "Row" .. i, LayoutOrder = 100 + i, Size = UDim2.new(1, 0, 0, 10), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.TextMuted }, 14)
				end
			else
				UIKit.text(box, "Body", "Not found yet. " .. cat.Hint .. " Details appear once you have found it.", { Name = "Line1", Size = UDim2.new(1, 0, 0, 10), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.TextMuted }, 15)
			end
		end
	end

	fill = function()
		local p = ctx.Profile()
		local cat = CodexData.Category(selected)
		if not cat then
			return
		end
		local all, allTotal = CodexData.Progress(p)
		if cat.Counts then
			local seen, total = CodexData.Progress(p, cat.Id)
			progress.Text = string.format("%s %d/%d found | CODEX %d/%d", cat.Title, seen, total, all, allTotal)
		else
			progress.Text = string.format("%s | CODEX %d/%d found", cat.Title, all, allTotal)
		end
		for _, ch in ipairs(ui.Body:GetChildren()) do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		for i, entry in ipairs(cat.Entries) do
			local known = CodexData.Known(p, cat.Id, entry.Id)
			-- found entries first, the "???" ones after them (same order within each)
			entryRow(cat, entry, i + (known and 0 or 1000), known)
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
