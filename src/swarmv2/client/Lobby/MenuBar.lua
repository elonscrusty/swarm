--!strict
--[[
	SwarmV2Client/Lobby/MenuBar.lua
	OWNER: lobby track (Chat 1). The home screen's entry buttons: SHOP, CODEX, SETTINGS, MORE. (CLASSES is
	the class chip, PARTY the party strip and PLAY the gold button, so the six entry points of the brief
	are all on screen; MORE holds boards, quests, the daily, stats and the rest.) A button shows only
	when its screen exists in this build (feature switches). Each is at least 48 px high with an icon
	and a word.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local Brief = require(script.Parent.Brief)
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local UIKit = Kit.UIKit
local T = Brief.T

local MenuBar = {}

export type Panel = {
	Frame: Frame,
	Layout: (ctx: Kit.Ctx) -> number, -- places the bar, returns its bottom edge
	Buttons: { [string]: TextButton },
}

type Entry = { Id: string, Title: string, Icon: string, Go: () -> () }

function MenuBar.Build(ctx: Kit.Ctx, open: (screen: string) -> (), openSettings: () -> ()): Panel
	local entries: { Entry } = {}
	if Config.FeatureOn("Store") then
		table.insert(entries, { Id = "Shop", Title = "SHOP", Icon = "bag", Go = function() open("Store") end })
	end
	if Config.FeatureOn("CollectionBook") then
		table.insert(entries, { Id = "Codex", Title = "CODEX", Icon = "gem", Go = function() open("Collection") end })
	end
	table.insert(entries, { Id = "Settings", Title = "SETTINGS", Icon = "gear", Go = openSettings })
	table.insert(entries, { Id = "More", Title = "MORE", Icon = "bars", Go = function() open("More") end })

	local bar = UIKit.new("Frame", {
		Name = "MenuBar",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(400, 68),
		AnchorPoint = Vector2.new(1, 0),
		ZIndex = 3,
	}, ctx.Root)
	local list = UIKit.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 8),
	}, bar)
	local buttons: { TextButton } = {}
	local byId: { [string]: TextButton } = {}
	for i, e in ipairs(entries) do
		local b = Brief.button(bar, {
			Name = e.Title,
			Title = "",
			Size = UDim2.fromOffset(96, 68),
			LayoutOrder = i,
			ZIndex = 4,
			Kind = "Secondary",
			OnClick = e.Go,
		})
		Kit.Icons.Draw(b.Face, e.Icon, {
			Size = 26,
			Color = T.Cream,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 7),
			ZIndex = 6,
			Name = "Icon",
		})
		b.Label.AnchorPoint = Vector2.new(0.5, 1)
		b.Label.Position = UDim2.new(0.5, 0, 1, -4)
		b.Label.Size = UDim2.new(1, -6, 0, 22)
		b.Label.TextSize = 14
		b.Label.TextXAlignment = Enum.TextXAlignment.Center
		b.SetText(e.Title)
		table.insert(buttons, b.Instance)
		byId[e.Id] = b.Instance
	end
	return {
		Frame = bar,
		Buttons = byId,
		Layout = function(c: Kit.Ctx): number
			local n = #entries
			local barH = c.Portrait and 64 or 68
			if c.Portrait then
				-- a full-width row under the class chip and the party strip
				local w = (c.W - 2 * Kit.M - (n - 1) * 8) / n
				bar.AnchorPoint = Vector2.new(0, 0)
				bar.Position = UDim2.fromOffset(Kit.M, Kit.M + 72 + 8 + 66 + 8)
				bar.Size = UDim2.fromOffset(c.W - 2 * Kit.M, barH)
				list.HorizontalAlignment = Enum.HorizontalAlignment.Left
				for _, b in ipairs(buttons) do
					b.Size = UDim2.fromOffset(math.floor(w), barH)
				end
				return Kit.M + 72 + 8 + 66 + 8 + barH
			end
			bar.AnchorPoint = Vector2.new(1, 0)
			bar.Position = UDim2.fromOffset(c.W - Kit.M, Kit.M)
			bar.Size = UDim2.fromOffset(n * 104 - 8, barH)
			list.HorizontalAlignment = Enum.HorizontalAlignment.Right
			for _, b in ipairs(buttons) do
				b.Size = UDim2.fromOffset(96, barH)
			end
			return Kit.M + barH
		end,
	}
end

return MenuBar
