--!strict
--[[
	SwarmV2Client/Lobby/ClassPanel.lua
	OWNER: lobby track (Chat 1). The CLASSES entry on the home screen (a chip with the class in use)
	and the class browser it opens (ClassBrowser: twelve classes, filters, details, server-confirmed
	selection). Buttons only send ClassAction; the server decides (ownership, gold, lock) and answers
	with a new LobbyState (ClassAck).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local Brief = require(script.Parent.Brief)
local ClassBrowser = require(script.Parent.ClassBrowser)
local V2 = ReplicatedStorage:WaitForChild("SwarmV2")
local ClassCatalog = require(V2:WaitForChild("ClassCatalog"))

local UIKit = Kit.UIKit
local new = UIKit.new
local T = Brief.T

local ClassPanel = {}

export type Panel = {
	Chip: Frame,
	Sheet: ClassBrowser.Sheet,
	Layout: (ctx: Kit.Ctx) -> (),
	Render: (ctx: Kit.Ctx) -> (),
	Step: (ctx: Kit.Ctx) -> (),
	Back: () -> boolean,
	Browser: ClassBrowser.Panel,
}

function ClassPanel.Build(ctx: Kit.Ctx): Panel
	local chip = new("Frame", {
		Name = "ClassChip",
		BackgroundColor3 = T.Navy,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(260, 72),
		Position = UDim2.fromOffset(Kit.M, Kit.M),
		ZIndex = 3,
	}, ctx.Root)
	UIKit.corner(chip, 14)
	UIKit.stroke(chip, T.Line, 2, 0)
	local swatch = new("Frame", {
		Name = "Swatch",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(44, 44),
		BackgroundColor3 = T.NavyRaised,
		BorderSizePixel = 0,
		ZIndex = 4,
	}, chip)
	UIKit.corner(swatch, 999)
	local swatchStroke = UIKit.stroke(swatch, T.Cream, 3, 0)
	Brief.label(chip, "Caption", "CLASSES", {
		Name = "Caption",
		Position = UDim2.fromOffset(66, 6),
		Size = UDim2.new(1, -108, 0, 18),
		TextColor3 = T.Gold,
		ZIndex = 4,
	}, ctx.Compact)
	local name = Brief.label(chip, "Body", "", {
		Name = "Name",
		FontFace = Brief.Weight.Black,
		TextSize = 20,
		Position = UDim2.fromOffset(66, 23),
		Size = UDim2.new(1, -108, 0, 26),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, ctx.Compact)
	local role = Brief.label(chip, "Label", "", {
		Name = "Role",
		Position = UDim2.fromOffset(66, 47),
		Size = UDim2.new(1, -108, 0, 20),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, ctx.Compact)
	Kit.Icons.Draw(chip, "chevronRight", {
		Name = "Caret",
		Size = 24,
		Color = T.Cream,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		ZIndex = 4,
	})
	local hit = new("TextButton", {
		Name = "Hit",
		Text = "",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 20,
		AutoButtonColor = false,
	}, chip)
	Brief.focusable(hit)
	hit.Activated:Connect(Kit.debounced(function()
		ctx.OpenSheet("Classes")
	end))

	local browser = ClassBrowser.Build(ctx)

	local panel: Panel
	panel = {
		Chip = chip,
		Sheet = browser.Sheet,
		Browser = browser,
		Layout = function(c: Kit.Ctx)
			chip.Size = UDim2.fromOffset(c.Portrait and math.min(300, c.W - 2 * Kit.M) or 260, 72)
			browser.Layout(c)
		end,
		Render = function(c: Kit.Ctx)
			local v = c.View
			if v == nil then
				-- the save has not answered yet: never show a guess as the player's class
				name.Text = "Loading class..."
				role.Text = "Please wait"
				swatch.BackgroundColor3 = T.NavyRaised
				swatchStroke.Color = T.Line
			else
				local info = ClassCatalog.Get(v.Selected) or ClassCatalog.Get(ClassCatalog.Default)
				name.Text = info and info.Name or "Class"
				role.Text = v.ClassLocked and "Class locked" or (info and info.Role or "")
				swatch.BackgroundColor3 = info and info.Primary or T.NavyRaised
				swatchStroke.Color = info and info.Accent or T.Cream
			end
			browser.Render(c)
		end,
		Step = function(c: Kit.Ctx)
			browser.Step(c)
		end,
		Back = function(): boolean
			return browser.Back()
		end,
	}
	return panel
end

return ClassPanel
