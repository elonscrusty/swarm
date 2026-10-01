--[[
	UIKit.lua
	Shared building blocks for every screen: instance helper, corners, strokes, labels,
	buttons (with press feedback + click sound), the colour palette and the upgrade icon
	tile used by the in-run upgrade bar and the level-up cards.

	UIBuilder, LobbyScreen and DevPanel all build their UI with these.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local IconData = require(Shared:WaitForChild("IconData"))
local UIAnim = require(script.Parent.UIAnim)

local UIKit = {}

local audio: any = nil

UIKit.COLORS = {
	Panel = Color3.fromRGB(24, 24, 34),
	PanelLight = Color3.fromRGB(40, 40, 56),
	Text = Color3.fromRGB(240, 240, 245),
	Dim = Color3.fromRGB(170, 170, 185),
	Gold = Color3.fromRGB(255, 210, 70),
	Green = Color3.fromRGB(70, 200, 110),
	Red = Color3.fromRGB(220, 70, 70),
	Blue = Color3.fromRGB(70, 140, 230),
	Gray = Color3.fromRGB(90, 90, 105),
	XP = Color3.fromRGB(90, 170, 255),
	Orange = Color3.fromRGB(200, 140, 40),
	Purple = Color3.fromRGB(150, 90, 230),
}
local COLORS = UIKit.COLORS

-- Click sounds for every button (Audio module, set once by UIBuilder.Init).
function UIKit.SetAudio(a: any)
	audio = a
end

function UIKit.new(className: string, props: { [string]: any }, parent: Instance?): any
	local obj = Instance.new(className)
	for k, v in pairs(props) do
		(obj :: any)[k] = v
	end
	if parent then
		obj.Parent = parent
	end
	return obj
end
local new = UIKit.new

function UIKit.corner(obj: Instance, radius: number?)
	new("UICorner", { CornerRadius = UDim.new(0, radius or 10) }, obj)
end

function UIKit.stroke(obj: Instance, color: Color3, thickness: number?): UIStroke
	return new("UIStroke", { Color = color, Thickness = thickness or 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, obj)
end

function UIKit.pad(obj: Instance, p: number)
	new("UIPadding", { PaddingTop = UDim.new(0, p), PaddingBottom = UDim.new(0, p), PaddingLeft = UDim.new(0, p), PaddingRight = UDim.new(0, p) }, obj)
end

function UIKit.label(parent: Instance, text: string, size: number, props: { [string]: any }?): TextLabel
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		TextSize = size,
		Font = Config.UI.Font,
		TextColor3 = COLORS.Text,
		Size = UDim2.new(1, 0, 0, size + 6),
	}, parent)
	if props then
		for k, v in pairs(props) do
			(l :: any)[k] = v
		end
	end
	return l
end

function UIKit.button(parent: Instance, text: string, color: Color3, onClick: () -> (), props: { [string]: any }?): TextButton
	local b = new("TextButton", {
		Text = text,
		TextSize = 22,
		Font = Config.UI.Font,
		TextColor3 = Color3.new(1, 1, 1),
		BackgroundColor3 = color,
		AutoButtonColor = true,
		Size = UDim2.fromOffset(180, 50),
	}, parent)
	UIKit.corner(b, 10)
	if props then
		for k, v in pairs(props) do
			(b :: any)[k] = v
		end
	end
	UIAnim.Button(b)
	b.Activated:Connect(function()
		if audio then
			audio.Play("Click")
		end
		onClick()
	end)
	return b
end

function UIKit.formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- Vertical light-to-dark sheen on a frame (makes flat panels and buttons look less flat).
function UIKit.sheen(obj: Instance, strength: number?)
	local k = strength or 0.25
	new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1 - k, 1 - k, 1 - k)),
	}, obj)
end

------------------------------------------------------------------------------------------
-- Upgrade icon tile
------------------------------------------------------------------------------------------

export type IconOpts = {
	Id: string?, -- IconData key (weapon, evolution or passive id)
	Name: string?, -- used for the placeholder letters when the id has no glyph
	Color: Color3?, -- item colour (placeholder tile + border tint)
	Size: number,
	Level: number?, -- shows a "xN" badge when above 1
	Evolved: boolean?, -- gold border
}

--[[
	An icon tile: the uploaded picture (IconData) when there is one, otherwise a coloured
	tile with 1-2 letters. Nothing in it is Active, so touches pass through to the
	thumbstick underneath.
]]
function UIKit.IconTile(parent: Instance, o: IconOpts): Frame
	local color = o.Color or COLORS.Gray
	local size = o.Size
	local tile = new("Frame", {
		Name = "Icon",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = color:Lerp(Color3.new(0, 0, 0), 0.35),
		Active = false,
	}, parent)
	UIKit.corner(tile, math.max(6, math.floor(size * 0.18)))
	UIKit.sheen(tile, 0.35)
	if o.Evolved then
		UIKit.stroke(tile, COLORS.Gold, math.max(2, math.floor(size / 16)))
	else
		UIKit.stroke(tile, Color3.fromRGB(15, 15, 20), 2)
	end
	local image = IconData.Image(o.Id)
	if image then
		new("ImageLabel", {
			Name = "Image",
			BackgroundTransparency = 1,
			Image = image,
			ScaleType = Enum.ScaleType.Fit,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.86, 0.86),
		}, tile)
	else
		-- placeholder: a lighter inner disc with the glyph
		local disc = new("Frame", {
			Name = "Disc",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.74, 0.74),
			BackgroundColor3 = color,
		}, tile)
		UIKit.corner(disc, size)
		UIKit.sheen(disc, 0.3)
		UIKit.label(disc, IconData.Glyph(o.Id, o.Name), math.floor(size * 0.36), {
			Size = UDim2.fromScale(1, 1),
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.35,
		})
	end
	if o.Level and o.Level > 1 then
		local badgeSize = math.max(18, math.floor(size * 0.42))
		local badge = new("Frame", {
			Name = "Badge",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 4, 0, -4),
			Size = UDim2.fromOffset(badgeSize + 4, badgeSize - 2),
			BackgroundColor3 = o.Evolved and COLORS.Gold or Color3.fromRGB(20, 20, 28),
			ZIndex = 3,
		}, tile)
		UIKit.corner(badge, badgeSize)
		UIKit.stroke(badge, o.Evolved and Color3.fromRGB(120, 80, 0) or Color3.new(1, 1, 1), 1)
		UIKit.label(badge, "x" .. tostring(o.Level), math.floor(badgeSize * 0.62), {
			Size = UDim2.fromScale(1, 1),
			TextColor3 = o.Evolved and Color3.fromRGB(50, 30, 0) or Color3.new(1, 1, 1),
			ZIndex = 3,
		})
	end
	return tile
end

return UIKit
