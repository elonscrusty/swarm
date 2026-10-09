--!strict
--[[
	SwarmV2Client/Lobby/ClassPanel.lua
	OWNER: lobby track (Chat 1). The class chip (top-left) and the class sheet: four cards in
	ClassCatalog.Order with SELECT / BUY / LOCKED states. Buttons only send ClassAction; the
	server decides (ownership, gold, lock) and answers with a new LobbyState.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local V2 = ReplicatedStorage:WaitForChild("SwarmV2")
local ClassCatalog = require(V2:WaitForChild("ClassCatalog"))

local UIKit, Theme, C = Kit.UIKit, Kit.Theme, Kit.C
local new = UIKit.new

local ClassPanel = {}

export type Panel = {
	Chip: Frame,
	Sheet: Kit.Sheet,
	Layout: (ctx: Kit.Ctx) -> (),
	Render: (ctx: Kit.Ctx) -> (),
}

local function classOf(view: any?): ClassCatalog.ClassInfo
	local id = view and view.Selected or ClassCatalog.Default
	return ClassCatalog.Get(id) or ClassCatalog.Get(ClassCatalog.Default) :: ClassCatalog.ClassInfo
end

function ClassPanel.Build(ctx: Kit.Ctx): Panel
	local chip, chipFace = Kit.tapPanel(ctx.Root, {
		Name = "ClassChip",
		Size = UDim2.fromOffset(250, 64),
		Position = UDim2.fromOffset(Kit.M, Kit.M),
		Radius = Theme.Radius.M,
		Depth = 4,
		ZIndex = 3,
	}, function()
		ctx.OpenSheet("Classes")
	end)
	local swatch = new("Frame", {
		Name = "Swatch",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 10, 0.5, 0),
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, chipFace)
	UIKit.corner(swatch, 999)
	local swatchStroke = UIKit.stroke(swatch, C.Text, 3, 0)
	local name = Kit.txt(chipFace, "H2", "", {
		Name = "Name",
		Position = UDim2.fromOffset(62, 6),
		Size = UDim2.new(1, -108, 0, 28),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, 20)
	local role = Kit.txt(chipFace, "Label", "", {
		Name = "Role",
		Position = UDim2.fromOffset(62, 34),
		Size = UDim2.new(1, -108, 0, 22),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, 13)
	local caret = Kit.txt(chipFace, "H2", "v", {
		Name = "Caret",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(28, 28),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Blue,
		ZIndex = 4,
	}, 20)
	caret.Name = "Caret"

	local sheet: Kit.Sheet
	sheet = Kit.sheet(ctx.Root, "ClassSheet", "YOUR CLASS", function()
		ctx.OpenSheet(nil)
	end)
	local list = new("Frame", { Name = "Cards", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 1, -46), ZIndex = 12 }, sheet.Body)
	local grid = new("UIGridLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		CellPadding = UDim2.fromOffset(8, 8),
		CellSize = UDim2.fromOffset(200, 240),
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
	}, list)
	local note = Kit.txt(sheet.Body, "Small", "Your avatar stays yourself in camp. You become this class in the run.", {
		Name = "Note",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 42),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextWrapped = true,
		ZIndex = 12,
	}, 14)
	local gold = Kit.txt(sheet.Head, "BodyStrong", "", {
		Name = "Gold",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -66, 0.5, 0),
		Size = UDim2.fromOffset(150, 28),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = C.BlueDeep,
		ZIndex = 13,
	}, 18)

	local sig = ""
	local cols = 4

	local function card(ctxNow: Kit.Ctx, id: string, order: number)
		local info = ClassCatalog.Get(id)
		if not info then
			return
		end
		local view = ctxNow.View
		local selected = view ~= nil and view.Selected == id
		local owned = info.Cost <= 0 or (view ~= nil and view.Owned[id] == true)
		local locked = view ~= nil and view.ClassLocked == true
		local goldNow: number = view and view.Gold or 0
		local holder, face = UIKit.Surface(list, {
			Name = "Card_" .. id,
			LayoutOrder = order,
			Radius = Theme.Radius.M,
			Color = selected and C.SelectedPale or C.Panel,
			Edge = selected and C.SelectedEdge or C.PanelEdge,
			EdgeThickness = selected and 4 or 2,
			Transparency = 0,
			Depth = 4,
			ZIndex = 13,
		})
		local top = info.Primary or C.Panel
		local pic = new("Frame", {
			Name = "Pic",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 8),
			Size = UDim2.fromOffset(46, 46),
			BackgroundColor3 = top,
			BorderSizePixel = 0,
			ZIndex = 14,
		}, face)
		UIKit.corner(pic, 999)
		UIKit.stroke(pic, info.Accent or C.Text, 4, 0)
		Kit.txt(face, "H2", info.Name, {
			Name = "Name",
			Position = UDim2.fromOffset(6, 58),
			Size = UDim2.new(1, -12, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
			ZIndex = 14,
		}, 19)
		Kit.txt(face, "Label", info.Role or "", {
			Name = "Role",
			Position = UDim2.fromOffset(6, 84),
			Size = UDim2.new(1, -12, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = C.BlueDeep,
			ZIndex = 14,
		}, 13)
		Kit.txt(face, "Small", info.Tagline, {
			Name = "Tagline",
			Position = UDim2.fromOffset(8, 106),
			Size = UDim2.new(1, -16, 0, 76),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			ZIndex = 14,
		}, 14)
		local title, kind, enabled, action: string? = "SELECT", "Primary", true, nil
		if selected then
			title, kind, enabled = "SELECTED", "Selected", false
		elseif locked then
			title, kind, enabled = "LOCKED", "Disabled", false
		elseif owned then
			title, kind, action = "SELECT", "Primary", "Select"
		elseif goldNow >= info.Cost then
			title, kind, action = "BUY " .. Kit.gold(info.Cost), "Primary", "Buy"
		else
			title, kind, enabled = "NEED " .. Kit.gold(info.Cost - goldNow) .. " MORE", "Disabled", false
		end
		local b = Kit.btn(face, {
			Kind = kind,
			Title = title,
			Size = UDim2.new(1, -16, 0, 52),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Name = "Action",
			Depth = "Medium",
			Shrink = true,
			ZIndex = 15,
			OnClick = function()
				if action then
					ctxNow.Fire("ClassAction", action, id)
				end
			end,
		})
		if not enabled then
			b.SetEnabled(false)
		end
		holder.Parent = list
	end

	local panel: Panel
	panel = {
		Chip = chip,
		Sheet = sheet,
		Layout = function(c: Kit.Ctx)
			cols = c.Portrait and 2 or 4
			local avail = math.min(c.W - 2 * Kit.M, 960)
			local cellW = math.floor((avail - 28 - (cols - 1) * 8) / cols)
			local cellH = c.Portrait and 250 or 240
			local rows = math.ceil(4 / cols)
			grid.CellSize = UDim2.fromOffset(cellW, cellH)
			local bodyH = rows * cellH + (rows - 1) * 8 + 46
			sheet.Resize(avail, 28 + 58 + bodyH)
			if c.Portrait then
				chip.Size = UDim2.fromOffset(math.min(260, c.W - 2 * Kit.M), 64)
			else
				chip.Size = UDim2.fromOffset(250, 64)
			end
			sig = "" -- force a rebuild at the new size
		end,
		Render = function(c: Kit.Ctx)
			local v = c.View
			local info = classOf(v)
			name.Text = info.Name
			role.Text = (v and v.ClassLocked) and "CLASS LOCKED" or (info.Role or "")
			swatch.BackgroundColor3 = info.Primary or C.Panel
			swatchStroke.Color = info.Accent or C.Text
			gold.Text = v and ("GOLD " .. Kit.gold(v.Gold)) or ""
			local parts = { tostring(cols) }
			if v then
				table.insert(parts, tostring(v.Selected))
				table.insert(parts, tostring(math.floor(v.Gold)))
				table.insert(parts, tostring(v.ClassLocked == true))
				for _, id in ipairs(ClassCatalog.Order) do
					table.insert(parts, (v.Owned[id] and "1" or "0"))
				end
			end
			local s = table.concat(parts, "|")
			if s == sig then
				return
			end
			sig = s
			Kit.clear(list)
			for i, id in ipairs(ClassCatalog.Order) do
				card(c, id, i)
			end
		end,
	}
	note.Parent = sheet.Body
	return panel
end

return ClassPanel
