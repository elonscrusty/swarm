--!strict
--[[
	SwarmV2Client/Lobby/PartyStrip.lua
	OWNER: lobby track (Chat 1). A small, unobtrusive party strip under the class chip: party
	size, who leads, and a PARTY button that opens the existing Party screen.
]]

local Kit = require(script.Parent.Kit)

local UIKit, Theme = Kit.UIKit, Kit.Theme

local PartyStrip = {}

export type Panel = {
	Frame: Frame,
	Layout: (ctx: Kit.Ctx, x: number, y: number) -> (),
	Render: (ctx: Kit.Ctx) -> (),
}

function PartyStrip.Build(ctx: Kit.Ctx, openParty: () -> ()): Panel
	local holder, face = UIKit.Surface(ctx.Root, {
		Name = "PartyStrip",
		Size = UDim2.fromOffset(250, 66),
		Radius = Theme.Radius.M,
		Depth = 3,
		Transparency = 0.1,
		ZIndex = 3,
	})
	local title = Kit.txt(face, "H3", "PARTY", {
		Name = "Title",
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -124, 0, 26),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, 18)
	local sub = Kit.txt(face, "Small", "", {
		Name = "Sub",
		Position = UDim2.fromOffset(12, 34),
		Size = UDim2.new(1, -120, 0, 22),
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
	}, 14)
	Kit.btn(face, {
		Kind = "Secondary",
		Title = "PARTY",
		Size = UDim2.fromOffset(104, 50),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Name = "PartyButton",
		Depth = "Light",
		Shrink = true,
		ZIndex = 5,
		OnClick = openParty,
	})
	return {
		Frame = holder,
		Layout = function(c: Kit.Ctx, x: number, y: number)
			holder.Position = UDim2.fromOffset(x, y)
			holder.Size = UDim2.fromOffset(c.Portrait and math.min(260, c.W - 2 * Kit.M) or 250, 66)
		end,
		Render = function(c: Kit.Ctx)
			local v = c.View
			local size = v and v.PartySize or 0
			if size > 1 then
				title.Text = "PARTY  " .. tostring(size)
				sub.Text = v.IsLeader and "You lead" or "You are a member"
			else
				title.Text = "PARTY"
				sub.Text = "With friends"
			end
		end,
	}
end

return PartyStrip
