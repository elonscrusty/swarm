--!strict
--[[
	SwarmV2Client/Lobby/MenuBar.lua
	OWNER: lobby track (Chat 1). Small labelled buttons (STORE, BOARDS, QUESTS, SETTINGS, MORE)
	that open the existing lobby screens through LobbyScreen.Show. A button is only shown when
	its screen exists in this build (feature switches).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local UIKit, Theme, C = Kit.UIKit, Kit.Theme, Kit.C

local MenuBar = {}

export type Panel = {
	Frame: Frame,
	Layout: (ctx: Kit.Ctx) -> number, -- places the bar, returns its bottom edge
}

type Entry = { Title: string, Icon: string, Go: () -> () }

function MenuBar.Build(ctx: Kit.Ctx, open: (screen: string) -> (), openSettings: () -> ()): Panel
	local entries: { Entry } = {}
	if Config.FeatureOn("Store") then
		table.insert(entries, { Title = "STORE", Icon = "bag", Go = function() open("Store") end })
	end
	table.insert(entries, { Title = "BOARDS", Icon = "podium", Go = function() open("Ranks") end })
	if Config.FeatureOn("DailyQuests") then
		table.insert(entries, { Title = "QUESTS", Icon = "flag", Go = function() open("Quests") end })
	end
	table.insert(entries, { Title = "SETTINGS", Icon = "gear", Go = openSettings })
	table.insert(entries, { Title = "MORE", Icon = "bars", Go = function() open("More") end })

	local bar = UIKit.new("Frame", {
		Name = "MenuBar",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(400, 66),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 3,
	}, ctx.Root)
	local list = UIKit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 6),
	}, bar)
	local buttons: { Frame } = {}
	for i, e in ipairs(entries) do
		local holder, face = Kit.tapPanel(bar, {
			Name = e.Title,
			Size = UDim2.fromOffset(86, 66),
			LayoutOrder = i,
			Radius = Theme.Radius.M,
			Depth = 3,
			Transparency = 0,
			ZIndex = 4,
		}, e.Go)
		Kit.Icons.Draw(face, e.Icon, {
			Size = 26,
			Color = C.Blue,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 6),
			ZIndex = 5,
			Name = "Icon",
		})
		Kit.txt(face, "Label", e.Title, {
			Name = "Label",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -4),
			Size = UDim2.new(1, -6, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = C.Text,
			ZIndex = 5,
		}, 12)
		table.insert(buttons, holder)
	end
	return {
		Frame = bar,
		Layout = function(c: Kit.Ctx): number
			local n = #entries
			if c.Portrait then
				-- a full-width row under the class chip
				local w = (c.W - 2 * Kit.M - (n - 1) * 6) / n
				bar.AnchorPoint = Vector2.new(0, 0)
				bar.Position = UDim2.fromOffset(Kit.M, Kit.M + 64 + 8)
				bar.Size = UDim2.fromOffset(c.W - 2 * Kit.M, 60)
				list.HorizontalAlignment = Enum.HorizontalAlignment.Left
				for _, b in ipairs(buttons) do
					b.Size = UDim2.fromOffset(math.floor(w), 60)
				end
				return Kit.M + 64 + 8 + 60
			end
			bar.AnchorPoint = Vector2.new(1, 0)
			bar.Position = UDim2.fromOffset(c.W - Kit.M, Kit.M)
			bar.Size = UDim2.fromOffset(n * 92, 66)
			list.HorizontalAlignment = Enum.HorizontalAlignment.Right
			for _, b in ipairs(buttons) do
				b.Size = UDim2.fromOffset(86, 66)
			end
			return Kit.M + 66
		end,
	}
end

return MenuBar
