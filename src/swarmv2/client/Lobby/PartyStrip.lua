--!strict
--[[
	SwarmV2Client/Lobby/PartyStrip.lua
	OWNER: lobby track (Chat 1). The PARTY entry on the home screen, under the class chip: party size,
	who leads, and a PARTY button that opens the existing Party screen. While the lobby's profile has
	not answered it says so instead of guessing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Kit = require(script.Parent.Kit)
local Brief = require(script.Parent.Brief)
local LobbyConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Lobby"):WaitForChild("LobbyConfig"))

local UIKit = Kit.UIKit
local T = Brief.T

local PartyStrip = {}

export type Panel = {
	Frame: Frame,
	Layout: (ctx: Kit.Ctx, x: number, y: number) -> (),
	Render: (ctx: Kit.Ctx) -> (),
}

function PartyStrip.Build(ctx: Kit.Ctx, openParty: () -> ()): Panel
	local strip = UIKit.new("Frame", {
		Name = "PartyStrip",
		BackgroundColor3 = T.Navy,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(260, 66),
		ZIndex = 3,
	}, ctx.Root)
	UIKit.corner(strip, 14)
	UIKit.stroke(strip, T.Line, 2, 0)
	local title = Brief.label(strip, "Caption", "PARTY", {
		Name = "Title",
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.new(1, -132, 0, 20),
		TextColor3 = T.Gold,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, ctx.Compact)
	local sub = Brief.label(strip, "Label", "", {
		Name = "Sub",
		Position = UDim2.fromOffset(14, 30),
		Size = UDim2.new(1, -132, 0, 26),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, ctx.Compact)
	Brief.button(strip, {
		Name = "PartyButton",
		Title = "PARTY",
		Icon = "people2",
		Size = UDim2.fromOffset(112, 50),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		ZIndex = 5,
		Kind = "Secondary",
		TitleSize = 15,
		OnClick = openParty,
	})
	return {
		Frame = strip,
		Layout = function(c: Kit.Ctx, x: number, y: number)
			strip.Position = UDim2.fromOffset(x, y)
			strip.Size = UDim2.fromOffset(c.Portrait and math.min(300, c.W - 2 * Kit.M) or 260, 66)
		end,
		Render = function(c: Kit.Ctx)
			local v = c.View
			if v == nil then
				title.Text = "PARTY"
				sub.Text = "Loading..."
				return
			end
			local size = v.PartySize or 1
			if size > 1 then
				title.Text = string.format("PARTY  %d / %d", size, LobbyConfig.MaxPlayers)
				sub.Text = v.IsLeader and "You lead" or "You are a member"
			else
				title.Text = "PARTY"
				sub.Text = "Playing solo"
			end
		end,
	}
end

return PartyStrip
