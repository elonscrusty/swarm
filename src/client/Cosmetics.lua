--[[
	Cosmetics.lua
	Draws the level-track cosmetics (AccountData.lua) on the client:
	  Cosmetics.Frame(medal, frameId)    a portrait frame around a round hero medallion
	                                      (results screen, TRACK screen): coloured ring,
	                                      an optional second hairline and small gems
	  Cosmetics.NameColor(id)            nameplate colour (achievement or track), or nil
	  Cosmetics.LevelBadge(parent, lvl)  the small gold "LV 7" pill
	Rings on the lobby dais are drawn by Showcase.SetRing.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local AccountData = require(Shared:WaitForChild("AccountData"))
local UIKit = require(script.Parent.UIKit)

local Cosmetics = {}

local P = Theme.Palette
local new = UIKit.new

-- Decorates a round medallion frame (removes an earlier decoration). Returns the main
-- ring stroke so callers may tint it (defeat = crimson when no frame is worn).
function Cosmetics.Frame(medal: GuiObject, frameId: string?): UIStroke?
	for _, ch in ipairs(medal:GetChildren()) do
		if ch.Name == "CosmeticFrame" then
			ch:Destroy()
		end
	end
	local def = frameId and AccountData.Frames[frameId]
	if not def then
		return nil
	end
	local holder = new("Frame", { Name = "CosmeticFrame", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 3 }, medal)
	local main = new("Frame", { Name = "Ring", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 6, 1, 6), ZIndex = 3 }, holder)
	UIKit.corner(main, 999)
	local stroke = UIKit.stroke(main, def.Color, def.Thickness, 0)
	if def.Double then
		local outer = new("Frame", { Name = "Outer", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 14, 1, 14), ZIndex = 3 }, holder)
		UIKit.corner(outer, 999)
		UIKit.stroke(outer, def.Color, 1.2, 0.35)
	end
	local gems = def.Gems or 0
	for i = 1, gems do
		local a = (i - 1) / gems * math.pi * 2 - math.pi / 2
		local gem = new("Frame", {
			Name = "Gem",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5 + math.cos(a) * 0.5, math.cos(a) * 3, 0.5 + math.sin(a) * 0.5, math.sin(a) * 3),
			Size = UDim2.fromOffset(9, 9),
			Rotation = 45,
			BackgroundColor3 = i % 2 == 1 and P.crimson_400 or P.gold_200,
			BorderSizePixel = 0,
			ZIndex = 4,
		}, holder)
		UIKit.stroke(gem, P.slate_950, 1, 0.2)
	end
	return stroke
end

function Cosmetics.NameColor(id: string?): Color3?
	local c = AccountData.ColorOf(id)
	return c and c.Color or nil
end

-- "LV 7" pill (gold) for nameplates and headers.
function Cosmetics.LevelBadge(parent: Instance?, level: number, props: { [string]: any }?): TextLabel
	return UIKit.Badge(parent, "LV " .. tostring(level), "Gold", props)
end

return Cosmetics
