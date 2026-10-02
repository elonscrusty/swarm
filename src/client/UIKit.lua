--[[
	UIKit.lua
	The SWARM interface system: Theme tokens turned into components. Every screen (menu,
	HUD, modals, dev panel) is built from these so they share one look and one set of
	interaction states.

	Primitives  new, corner, stroke, pad, padding, list, text (Theme type styles), label,
	            formatTime / formatClock / formatNumber, track (letter-spaced caps)
	Surfaces    Surface (shadow + face), Panel, Divider, Bleed (full-screen layers)
	Controls    Button (Primary / Secondary / Outline / Ghost), IconButton, Card,
	            Chip, Meter, Tile (upgrade icon + level badge), Badge, Tabs, Slider,
	            Toggle, Modal, ScreenHeader
	Dashboard   TitleRule, SegmentBar, Avatar (head shot), Medal (ranks 1-3), Hairline
	Lobby look  ArtPicture (art/ picture with a drawn stand-in), StatusPill / SetStatus,
	            SectionLabel, IconPill

	States: hover lifts 2 px and brightens, press scales to 0.96, disabled desaturates,
	selected gets a strong gold border, gamepad focus shows a gold outline. Buttons keep a
	48 px minimum hit area (the visual can be smaller).

	Text sizes are reference pixels (Theme.TextSize); on phones UIKit makes them
	Theme.TextScaleCompact bigger so they stay readable at the phone's small UI scale.
]]

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local UIKit = {}

local C = Theme.Color
local P = Theme.Palette

UIKit.Theme = Theme

-- Legacy names (older code); every value now comes from the palette.
UIKit.COLORS = {
	Panel = C.Panel,
	PanelLight = C.PanelRaised,
	Text = C.Text,
	Dim = C.TextMuted,
	Gold = C.GoldLight,
	Green = C.Success,
	Red = C.Danger,
	Blue = C.SlateLight,
	Gray = C.Locked,
	XP = C.XP,
	Orange = C.Warning,
	Purple = P.slate_300,
}

local audio: any = nil
local compact = false

-- Click sounds for every button (Audio module, set once by UIBuilder.Init).
function UIKit.SetAudio(a: any)
	audio = a
end

local function click()
	if audio then
		audio.Play("Click")
	end
end
UIKit.Click = click

-- Phones: bigger reference text (see header).
function UIKit.SetCompact(on: boolean)
	compact = on
end

function UIKit.IsCompact(): boolean
	return compact
end

-- Text size for the current device.
function UIKit.TS(size: number): number
	if compact then
		return math.floor(size * Theme.TextScaleCompact + 0.5)
	end
	return size
end
local TS = UIKit.TS

------------------------------------------------------------------------------------------
-- Primitives
------------------------------------------------------------------------------------------

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

function UIKit.corner(obj: Instance, radius: number?): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, radius or Theme.Radius.M) }, obj)
end
local corner = UIKit.corner

function UIKit.stroke(obj: Instance, color: Color3, thickness: number?, transparency: number?): UIStroke
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or Theme.Stroke.Thin,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, obj)
end
local stroke = UIKit.stroke

function UIKit.padding(obj: Instance, top: number, right: number, bottom: number, left: number): UIPadding
	return new("UIPadding", {
		PaddingTop = UDim.new(0, top),
		PaddingRight = UDim.new(0, right),
		PaddingBottom = UDim.new(0, bottom),
		PaddingLeft = UDim.new(0, left),
	}, obj)
end

function UIKit.pad(obj: Instance, p: number): UIPadding
	return UIKit.padding(obj, p, p, p, p)
end
local padding = UIKit.padding

-- A UIListLayout (vertical by default, sorted by LayoutOrder).
function UIKit.list(parent: Instance, props: { [string]: any }?): UIListLayout
	local l = new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, Theme.Space.S) }, parent)
	if props then
		for k, v in pairs(props) do
			(l :: any)[k] = v
		end
	end
	return l
end

-- Type styles: font + size + colour.
local STYLES: { [string]: { Font: Font, Size: number, Color: Color3 } } = {
	Hero = { Font = Theme.Font.Display, Size = Theme.TextSize.Hero, Color = C.Text },
	Display = { Font = Theme.Font.Display, Size = Theme.TextSize.Display, Color = C.Text },
	H1 = { Font = Theme.Font.Heading, Size = Theme.TextSize.H1, Color = C.Text },
	H2 = { Font = Theme.Font.Title, Size = Theme.TextSize.H2, Color = C.Text },
	H3 = { Font = Theme.Font.Title, Size = Theme.TextSize.H3, Color = C.Text },
	Body = { Font = Theme.Font.Body, Size = Theme.TextSize.Body, Color = C.TextMuted },
	BodyStrong = { Font = Theme.Font.BodyStrong, Size = Theme.TextSize.Body, Color = C.Text },
	Small = { Font = Theme.Font.Body, Size = Theme.TextSize.Small, Color = C.TextMuted },
	Caption = { Font = Theme.Font.Label, Size = Theme.TextSize.Caption, Color = C.TextMuted },
	Label = { Font = Theme.Font.Label, Size = Theme.TextSize.Small, Color = C.Text },
	Number = { Font = Theme.Font.Number, Size = Theme.TextSize.H3, Color = C.Text },
}
UIKit.Styles = STYLES

--[[
	A TextLabel in a type style. `size` overrides the style's size (reference px; the
	compact boost is applied either way). Extra props are applied last.
]]
function UIKit.text(parent: Instance?, style: string, str: string, props: { [string]: any }?, size: number?): TextLabel
	local s = STYLES[style] or STYLES.Body
	local px = TS(size or s.Size)
	local l = new("TextLabel", {
		Name = style,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = str,
		FontFace = s.Font,
		TextSize = px,
		TextColor3 = s.Color,
		Size = UDim2.new(1, 0, 0, px + 6),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Active = false,
	})
	if props then
		for k, v in pairs(props) do
			(l :: any)[k] = v
		end
	end
	l.Parent = parent
	return l
end
local text = UIKit.text

-- Older helper: centred bold label of `size` px.
function UIKit.label(parent: Instance, str: string, size: number, props: { [string]: any }?): TextLabel
	local l = text(nil, "Label", str, { TextXAlignment = Enum.TextXAlignment.Center }, size)
	if props then
		for k, v in pairs(props) do
			if k == "Font" then
				-- old Enum.Font values map onto the Theme fonts
				l.FontFace = (v == Enum.Font.Gotham or v == Enum.Font.SourceSans) and Theme.Font.Body or Theme.Font.Label
			else
				(l :: any)[k] = v
			end
		end
	end
	l.Parent = parent
	return l
end

function UIKit.formatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- Two-digit minutes ("02:14"), the run timer.
function UIKit.formatClock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d", seconds // 60, seconds % 60)
end

-- 1250 → "1,250"
function UIKit.formatNumber(n: number): string
	local s = tostring(math.floor(n + 0.5))
	local sign = ""
	if string.sub(s, 1, 1) == "-" then
		sign, s = "-", string.sub(s, 2)
	end
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return sign .. out
end

-- Letter-spaced capitals for small labels ("BEST TIME" → "B E S T  T I M E" with thin spaces).
-- "#RRGGBB" of a colour, for RichText <font color="...">.
function UIKit.hex(c: Color3): string
	return string.format("#%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

function UIKit.track(str: string): string
	local upper = string.upper(str)
	local chars = {}
	for _, code in utf8.codes(upper) do
		table.insert(chars, utf8.char(code))
	end
	return table.concat(chars, "")
end

-- Vertical light-to-dark sheen (older helper).
function UIKit.sheen(obj: Instance, strength: number?)
	local k = strength or 0.25
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.new(1 - k, 1 - k, 1 - k)) }, obj)
end

------------------------------------------------------------------------------------------
-- Full-bleed layers (modal dimmers that must also cover notches / the home bar)
------------------------------------------------------------------------------------------

local bleeds: { GuiObject } = {}
local bleedOffset = Vector2.zero
local bleedSize = Vector2.new(1280, 720)

-- Keeps `obj` covering the whole physical screen (root coordinates, set by UIBuilder).
function UIKit.Bleed(obj: GuiObject)
	table.insert(bleeds, obj)
	obj.Position = UDim2.fromOffset(bleedOffset.X, bleedOffset.Y)
	obj.Size = UDim2.fromOffset(bleedSize.X, bleedSize.Y)
end

-- offset = top-left of the screen relative to the safe-area root, size = screen size.
function UIKit.SetBleed(offset: Vector2, size: Vector2)
	bleedOffset, bleedSize = offset, size
	for i = #bleeds, 1, -1 do
		local b = bleeds[i]
		if b.Parent then
			b.Position = UDim2.fromOffset(offset.X, offset.Y)
			b.Size = UDim2.fromOffset(size.X, size.Y)
		else
			table.remove(bleeds, i)
		end
	end
end

------------------------------------------------------------------------------------------
-- Surfaces
------------------------------------------------------------------------------------------

-- Soft drop shadow: two dark layers behind a face (both inside `holder`).
function UIKit.Shadow(holder: Instance, radius: number, depth: number?, z: number?): Frame
	local d = depth or 4
	local wide = new("Frame", {
		Name = "ShadowWide",
		BackgroundColor3 = C.Shadow,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(-d, -d / 2),
		Size = UDim2.new(1, d * 2, 1, d * 2),
		ZIndex = z or 0,
		Active = false,
	}, holder)
	corner(wide, radius + d)
	local near = new("Frame", {
		Name = "Shadow",
		BackgroundColor3 = C.Shadow,
		BackgroundTransparency = Theme.Alpha.Shadow,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, d),
		Size = UDim2.fromScale(1, 1),
		ZIndex = z or 0,
		Active = false,
	}, holder)
	corner(near, radius)
	return near
end

export type SurfaceOpts = {
	Name: string?,
	Radius: number?,
	Color: Color3?,
	Transparency: number?,
	Edge: Color3?,
	EdgeTransparency: number?,
	EdgeThickness: number?,
	Shadow: boolean?,
	Gradient: boolean?,
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	ZIndex: number?,
	Visible: boolean?,
}

--[[
	A panel surface: a transparent holder (what layouts position) with an optional soft
	shadow and the visible face (slate, gold hairline, 10 px corners). Content goes in the
	returned face.
]]
function UIKit.Surface(parent: Instance?, o: SurfaceOpts?): (Frame, Frame)
	local opts: SurfaceOpts = o or {}
	local radius = opts.Radius or Theme.Radius.M
	local holder = new("Frame", {
		Name = opts.Name or "Surface",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = opts.Size or UDim2.fromScale(1, 1),
		Position = opts.Position or UDim2.new(),
		AnchorPoint = opts.AnchorPoint or Vector2.zero,
		LayoutOrder = opts.LayoutOrder or 0,
		ZIndex = opts.ZIndex or 1,
		Visible = if opts.Visible == nil then true else opts.Visible,
	})
	if opts.Shadow ~= false then
		UIKit.Shadow(holder, radius, 4, 0)
	end
	local face = new("Frame", {
		Name = "Face",
		BackgroundColor3 = opts.Gradient == false and (opts.Color or C.Panel) or Color3.new(1, 1, 1),
		BackgroundTransparency = opts.Transparency or Theme.Alpha.Panel,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, holder)
	corner(face, radius)
	if opts.Gradient ~= false then
		local base = opts.Color or C.Panel
		new("UIGradient", { Rotation = 90, Color = ColorSequence.new(base:Lerp(P.slate_700, 0.45), base) }, face)
	end
	stroke(face, opts.Edge or C.PanelEdge, opts.EdgeThickness or Theme.Stroke.Thin, opts.EdgeTransparency or Theme.Alpha.Edge)
	holder.Parent = parent
	return holder, face
end

-- A plain panel face (no holder / shadow) for nested wells and plates.
function UIKit.Panel(parent: Instance?, props: { [string]: any }?, soft: boolean?): Frame
	local f = new("Frame", {
		Name = "Panel",
		BackgroundColor3 = soft and C.PanelInset or C.Panel,
		BackgroundTransparency = soft and Theme.Alpha.PanelSoft or Theme.Alpha.Panel,
		BorderSizePixel = 0,
	})
	corner(f, Theme.Radius.M)
	stroke(f, C.PanelEdge, Theme.Stroke.Thin, soft and 0.75 or Theme.Alpha.Edge)
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

-- Thin gold ornament line with a diamond in the middle (under titles).
function UIKit.Divider(parent: Instance?, width: number, props: { [string]: any }?): Frame
	local f = new("Frame", { Name = "Divider", BackgroundTransparency = 1, Size = UDim2.fromOffset(width, 10) })
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
	}, f)
	local g = new("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}, f:FindFirstChildOfClass("Frame") :: Frame)
	local _ = g
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(6, 6),
		Rotation = 45,
		BackgroundColor3 = C.GoldLight,
		BorderSizePixel = 0,
	}, f)
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

------------------------------------------------------------------------------------------
-- Gamepad focus outline (one shared selection image)
------------------------------------------------------------------------------------------

local focusImage = new("Frame", {
	Name = "SwarmFocus",
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 8, 1, 8),
	Position = UDim2.fromOffset(-4, -4),
})
corner(focusImage, Theme.Radius.L)
stroke(focusImage, C.Focus, 2.5, 0)

function UIKit.Focusable(b: GuiObject)
	b.Selectable = true
	b.SelectionImageObject = focusImage
end

-- Moves gamepad selection to `obj` when the player is using a gamepad.
function UIKit.FocusIfGamepad(obj: GuiObject?)
	if not obj then
		return
	end
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Gamepad1 or last == Enum.UserInputType.Gamepad2 then
		GuiService.SelectedObject = obj
	end
end

local function mouseInput(): boolean
	local last = UserInputService:GetLastInputType()
	return last == Enum.UserInputType.MouseMovement or last == Enum.UserInputType.MouseButton1 or last == Enum.UserInputType.MouseWheel
end

--[[
	Hover / press states for a custom clickable (level-up cards, swatches): `hit` takes the
	input, `face` lifts 2 px and brightens on hover and scales to 0.96 while pressed.
	Returns a function that tells whether it is hovered.
]]
function UIKit.AttachStates(hit: GuiButton, face: GuiObject, radius: number?, onHover: ((boolean) -> ())?): () -> boolean
	local hovered = false
	local press = new("UIScale", { Name = "Press" }, face)
	local sheen = new("Frame", {
		Name = "Hover",
		BackgroundColor3 = C.Hover,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 50,
		Active = false,
	}, face)
	corner(sheen, radius or Theme.Radius.M)
	local base = face.Position
	local function set(on: boolean)
		if hovered == on then
			return
		end
		hovered = on
		UIAnim.Tween(face, Theme.Motion.Fast, { Position = on and (base + UDim2.fromOffset(0, -Theme.Motion.HoverLift)) or base })
		UIAnim.Tween(sheen, Theme.Motion.Fast, { BackgroundTransparency = on and Theme.Alpha.Hover or 1 })
		if onHover then
			onHover(on)
		end
	end
	hit.MouseEnter:Connect(function()
		if mouseInput() then
			set(true)
		end
	end)
	hit.MouseLeave:Connect(function()
		set(false)
		UIAnim.Tween(press, Theme.Motion.Fast, { Scale = 1 })
	end)
	hit.SelectionGained:Connect(function()
		set(true)
	end)
	hit.SelectionLost:Connect(function()
		set(false)
	end)
	hit.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			UIAnim.Tween(press, 0.08, { Scale = Theme.Motion.PressScale })
		end
	end)
	hit.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			UIAnim.Tween(press, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
			if t == Enum.UserInputType.Touch then
				set(false)
			end
		end
	end)
	return function(): boolean
		return hovered
	end
end

------------------------------------------------------------------------------------------
-- Buttons
------------------------------------------------------------------------------------------

export type ButtonOpts = {
	Kind: string?, -- "Primary" | "Secondary" | "Outline" | "Ghost"
	Title: string?,
	Subtitle: string?,
	Icon: string?, -- Icons name, drawn left of the text
	IconSize: number?,
	IconRight: string?, -- e.g. "chevronRight"
	Chevron: boolean?,
	TitleStyle: string?, -- text style of the title (default H2 for big, Label otherwise)
	TitleSize: number?,
	Align: string?, -- "Left" | "Center" (default Center unless an icon / subtitle is set)
	Size: UDim2?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	ZIndex: number?,
	Radius: number?,
	Shadow: boolean?,
	Glow: boolean?,
	Name: string?,
	OnClick: (() -> ())?,
	Sound: boolean?,
}

export type Button = {
	Instance: TextButton,
	Face: Frame,
	Content: Frame,
	Title: TextLabel?,
	Subtitle: TextLabel?,
	SetText: (title: string?, subtitle: string?) -> (),
	SetEnabled: (on: boolean) -> (),
	SetSelected: (on: boolean) -> (),
	SetKind: (kind: string) -> (),
	SetIcon: (name: string?) -> (),
	IsEnabled: () -> boolean,
	Kind: () -> string,
}

local KIND = {
	Primary = { Text = C.TextOnGold, Sub = C.TextOnGoldMuted, Icon = P.gold_900, IconBack = P.gold_400, Edge = C.PrimaryEdge, EdgeT = 0.15 },
	Secondary = { Text = C.Text, Sub = C.TextMuted, Icon = P.gold_400, IconBack = C.Panel, Edge = C.PanelEdge, EdgeT = Theme.Alpha.Edge },
	Outline = { Text = P.gold_200, Sub = C.TextMuted, Icon = P.gold_300, IconBack = C.Panel, Edge = P.gold_400, EdgeT = 0.05 },
	Ghost = { Text = C.TextMuted, Sub = C.TextFaint, Icon = C.TextMuted, IconBack = C.Panel, Edge = C.PanelEdge, EdgeT = 1 },
	Disabled = { Text = C.DisabledText, Sub = P.stone_400, Icon = P.stone_400, IconBack = C.Disabled, Edge = P.stone_500, EdgeT = 0.5 },
}

--[[
	The button component. The TextButton is the hit area (what layouts place, at least
	TapMin tall); inside it sit an optional glow / shadow and the Face that carries the
	visuals and the content (icon, title, subtitle, chevron).
]]
function UIKit.Button(parent: Instance?, o: ButtonOpts): Button
	local kind = o.Kind or "Secondary"
	local radius = o.Radius or Theme.Radius.M
	local enabled = true
	local selected = false
	local hovered = false
	local iconName = o.Icon
	local iconSize = o.IconSize or Theme.Size.Icon

	local hit = new("TextButton", {
		Name = o.Name or (o.Title or "Button"),
		-- the label lives in the face; the hit area carries it invisibly (tools, a11y)
		Text = o.Title or "",
		TextTransparency = 1,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = o.Size or UDim2.fromOffset(200, Theme.Size.Button),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
		ClipsDescendants = false,
	})
	UIKit.Focusable(hit)

	local glow: Frame? = nil
	if o.Glow then
		local g = new("Frame", {
			Name = "Glow",
			BackgroundColor3 = P.gold_300,
			BackgroundTransparency = Theme.Alpha.Glow,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(-6, -6),
			Size = UDim2.new(1, 12, 1, 12),
			ZIndex = 0,
			Active = false,
		}, hit)
		corner(g, radius + 6)
		local g2 = new("Frame", {
			Name = "GlowWide",
			BackgroundColor3 = P.gold_400,
			BackgroundTransparency = 0.9,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(-14, -14),
			Size = UDim2.new(1, 28, 1, 28),
			ZIndex = 0,
			Active = false,
		}, hit)
		corner(g2, radius + 14)
		UIAnim.Glow(g, "BackgroundTransparency", Theme.Alpha.Glow, 0.86, 1.8)
		glow = g
	end
	if o.Shadow ~= false and kind ~= "Ghost" then
		UIKit.Shadow(hit, radius, 3, 0)
	end

	local face = new("Frame", {
		Name = "Face",
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Active = false,
	}, hit)
	corner(face, radius)
	local faceStroke = stroke(face, C.PanelEdge, Theme.Stroke.Thin, Theme.Alpha.Edge)
	local gradient = new("UIGradient", { Rotation = 90 }, face)
	local press = new("UIScale", { Name = "Press" }, face)
	local hover = new("Frame", {
		Name = "Hover",
		BackgroundColor3 = C.Hover,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Active = false,
	}, face)
	corner(hover, radius)
	-- a hairline of light along the top edge (bevel)
	local bevel = new("Frame", {
		Name = "Bevel",
		BackgroundColor3 = C.Hover,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Position = UDim2.new(0, radius, 0, 1),
		Size = UDim2.new(1, -2 * radius, 0, 1),
		ZIndex = 2,
		Active = false,
	}, face)

	local content = new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 3,
		Active = false,
	}, face)
	local hasSide = o.Icon ~= nil or o.Chevron == true or o.IconRight ~= nil
	local align = o.Align or ((o.Icon or o.Subtitle) and "Left" or "Center")
	local sidePad = Theme.Space.L
	padding(content, 0, sidePad, 0, sidePad)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		HorizontalAlignment = align == "Left" and Enum.HorizontalAlignment.Left or Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, Theme.Space.M),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, content)

	local iconHolder = new("Frame", {
		Name = "IconHolder",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(iconSize, iconSize),
		LayoutOrder = 1,
		Visible = o.Icon ~= nil,
	}, content)

	-- text column
	local big = o.Subtitle ~= nil or (o.TitleStyle == "H2") or (o.TitleStyle == "H1")
	local titleStyle = o.TitleStyle or (big and "H2" or "Label")
	local titleSize = o.TitleSize or (titleStyle == "Label" and Theme.TextSize.Body or nil)
	local column = new("Frame", {
		Name = "Text",
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.None,
	}, content)
	local titleLabel: TextLabel? = nil
	local subLabel: TextLabel? = nil
	if o.Title then
		titleLabel = text(column, titleStyle, o.Title, {
			Name = "Title",
			TextXAlignment = align == "Left" and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, titleSize)
	end
	if o.Subtitle then
		subLabel = text(column, "BodyStrong", o.Subtitle, {
			Name = "Subtitle",
			TextXAlignment = align == "Left" and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, Theme.TextSize.Small)
	end
	new("UIListLayout", {
		VerticalAlignment = Enum.VerticalAlignment.Center,
		HorizontalAlignment = align == "Left" and Enum.HorizontalAlignment.Left or Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 0),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, column)
	if titleLabel then
		titleLabel.LayoutOrder = 1
	end
	if subLabel then
		subLabel.LayoutOrder = 2
	end

	local rightName = o.IconRight or (o.Chevron and "chevronRight" or nil)
	local rightHolder = new("Frame", {
		Name = "Right",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(rightName and 20 or 0, 20),
		LayoutOrder = 3,
		Visible = rightName ~= nil,
	}, content)

	-- the text column takes the room the icons leave
	local function fitColumn()
		local used = 0
		local items = 0
		if iconHolder.Visible then
			used += iconHolder.Size.X.Offset
			items += 1
		end
		if rightHolder.Visible then
			used += rightHolder.Size.X.Offset
			items += 1
		end
		column.Size = UDim2.new(1, -(used + items * Theme.Space.M), 1, 0)
		if not hasSide and align == "Center" then
			column.Size = UDim2.fromScale(1, 1)
		end
	end
	fitColumn()

	local function look(): typeof(KIND.Primary)
		if not enabled then
			return KIND.Disabled
		end
		return (KIND :: any)[kind] or KIND.Secondary
	end

	local function drawIcons()
		local k = look()
		for _, ch in ipairs(iconHolder:GetChildren()) do
			ch:Destroy()
		end
		for _, ch in ipairs(rightHolder:GetChildren()) do
			ch:Destroy()
		end
		if iconName then
			Icons.Draw(iconHolder, iconName, { Size = iconSize, Color = k.Icon, Back = k.IconBack })
		end
		if rightName then
			Icons.Draw(rightHolder, rightName, { Size = 20, Color = k.Icon, Back = k.IconBack })
		end
	end

	local function paint()
		local k = look()
		local primary = enabled and kind == "Primary"
		face.BackgroundTransparency = (kind == "Ghost" and enabled) and 1 or (primary and 0 or Theme.Alpha.Panel)
		if primary then
			face.BackgroundColor3 = Color3.new(1, 1, 1)
			gradient.Color = Theme.Gradient.Primary
			gradient.Enabled = true
		elseif not enabled then
			face.BackgroundColor3 = C.Disabled
			gradient.Enabled = false
		else
			face.BackgroundColor3 = Color3.new(1, 1, 1)
			gradient.Color = ColorSequence.new(P.slate_800, P.slate_900)
			gradient.Enabled = true
		end
		bevel.Visible = kind ~= "Ghost"
		bevel.BackgroundTransparency = primary and 0.55 or 0.85
		faceStroke.Color = selected and C.Selected or k.Edge
		faceStroke.Thickness = selected and Theme.Stroke.Thick or Theme.Stroke.Thin
		faceStroke.Transparency = selected and 0 or (hovered and math.max(0, k.EdgeT - 0.35) or k.EdgeT)
		if glow then
			glow.Visible = primary
			local wide = hit:FindFirstChild("GlowWide")
			if wide and wide:IsA("GuiObject") then
				wide.Visible = primary
			end
		end
		if titleLabel then
			titleLabel.TextColor3 = (selected and kind ~= "Primary" and enabled) and P.gold_200 or k.Text
		end
		if subLabel then
			subLabel.TextColor3 = k.Sub
		end
	end

	local function setHover(on: boolean)
		hovered = on and enabled
		UIAnim.Tween(face, Theme.Motion.Fast, { Position = UDim2.fromOffset(0, hovered and -Theme.Motion.HoverLift or 0) })
		UIAnim.Tween(hover, Theme.Motion.Fast, { BackgroundTransparency = hovered and Theme.Alpha.Hover or 1 })
		paint()
	end

	hit.MouseEnter:Connect(function()
		if mouseInput() then
			setHover(true)
		end
	end)
	hit.MouseLeave:Connect(function()
		setHover(false)
		UIAnim.Tween(press, Theme.Motion.Fast, { Scale = 1 })
	end)
	hit.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if enabled and (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) then
			UIAnim.Tween(press, 0.08, { Scale = Theme.Motion.PressScale })
		end
	end)
	hit.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			UIAnim.Tween(press, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
			if t == Enum.UserInputType.Touch then
				setHover(false)
			end
		end
	end)
	hit.SelectionGained:Connect(function()
		setHover(true)
	end)
	hit.SelectionLost:Connect(function()
		setHover(false)
	end)
	hit.Activated:Connect(function()
		if not enabled then
			return
		end
		if o.Sound ~= false then
			click()
		end
		if o.OnClick then
			o.OnClick()
		end
	end)

	local b: Button = {
		Instance = hit,
		Face = face,
		Content = content,
		Title = titleLabel,
		Subtitle = subLabel,
		SetText = function(title: string?, subtitle: string?)
			if title and titleLabel then
				titleLabel.Text = title
				hit.Text = title
			end
			if subtitle and subLabel then
				subLabel.Text = subtitle
			end
		end,
		SetEnabled = function(on: boolean)
			if enabled == on then
				return
			end
			enabled = on
			hit.Selectable = on
			if not on then
				hovered = false
				face.Position = UDim2.new()
				hover.BackgroundTransparency = 1
			end
			paint()
			drawIcons()
		end,
		SetSelected = function(on: boolean)
			selected = on
			paint()
		end,
		SetKind = function(k: string)
			if kind ~= k then
				kind = k
				paint()
				drawIcons()
			end
		end,
		SetIcon = function(name: string?)
			iconName = name
			iconHolder.Visible = name ~= nil
			fitColumn()
			drawIcons()
		end,
		IsEnabled = function(): boolean
			return enabled
		end,
		Kind = function(): string
			return kind
		end,
	}
	paint()
	drawIcons()
	hit.Parent = parent
	return b
end

-- Older helper: a plain secondary button with a centred label.
function UIKit.button(parent: Instance, str: string, _color: Color3, onClick: () -> (), props: { [string]: any }?): TextButton
	local b = UIKit.Button(parent, { Title = str, OnClick = onClick, Kind = "Secondary" })
	if props then
		for k, v in pairs(props) do
			if k == "TextSize" or k == "TextColor3" or k == "Text" or k == "BackgroundTransparency" or k == "BackgroundColor3" then
				-- visual props are owned by the component now
				if k == "Text" then
					b.SetText(v)
				end
			else
				(b.Instance :: any)[k] = v
			end
		end
	end
	return b.Instance
end

export type IconButtonOpts = {
	Icon: string,
	Caption: string?, -- small label under the icon (inside the button)
	Size: number?, -- square size (default Theme.Size.IconButton)
	IconSize: number?,
	Kind: string?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
	ZIndex: number?,
	Name: string?,
	OnClick: (() -> ())?,
	Round: boolean?,
}

-- Square icon button (Settings, Stats, Pause, arrows). Hit area is at least TapMin.
function UIKit.IconButton(parent: Instance?, o: IconButtonOpts): Button
	local size = o.Size or Theme.Size.IconButton
	local b = UIKit.Button(parent, {
		Kind = o.Kind or "Secondary",
		Size = UDim2.fromOffset(size, size),
		Position = o.Position,
		AnchorPoint = o.AnchorPoint,
		LayoutOrder = o.LayoutOrder,
		ZIndex = o.ZIndex,
		Name = o.Name or o.Icon,
		OnClick = o.OnClick,
		Radius = o.Round and math.floor(size / 2) or Theme.Radius.M,
	})
	b.Instance.Text = o.Caption or o.Icon
	-- replace the row content with a centred icon (+ caption)
	for _, ch in ipairs(b.Content:GetChildren()) do
		ch:Destroy()
	end
	local iconSize = o.IconSize or math.floor(size * (o.Caption and 0.42 or 0.46))
	local function draw(enabled: boolean)
		local old = b.Content:FindFirstChild("Glyph")
		if old then
			old:Destroy()
		end
		local kind = o.Kind or "Secondary"
		local color = not enabled and KIND.Disabled.Icon or (kind == "Primary" and P.gold_900 or P.gold_400)
		Icons.Draw(b.Content, o.Icon, {
			Name = "Glyph",
			Size = iconSize,
			Color = color,
			Back = kind == "Primary" and P.gold_400 or C.Panel,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = o.Caption and UDim2.new(0.5, 0, 0.5, -TS(Theme.TextSize.Caption) / 2 - 2) or UDim2.fromScale(0.5, 0.5),
		})
	end
	draw(true)
	if o.Caption then
		text(b.Content, "Caption", string.upper(o.Caption), {
			Name = "Caption",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -6),
			Size = UDim2.new(1, -4, 0, TS(Theme.TextSize.Caption) + 2),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = C.TextMuted,
		})
	end
	local baseEnabled = b.SetEnabled
	b.SetEnabled = function(on: boolean)
		baseEnabled(on)
		draw(on)
	end
	b.SetIcon = function(_name: string?) end
	-- keep the hit area finger-sized even when the visual is small
	if size < Theme.Size.TapMin then
		local grow = Theme.Size.TapMin - size
		local extra = new("TextButton", {
			Name = "HitPad",
			Text = "",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(-grow / 2, -grow / 2),
			Size = UDim2.new(1, grow, 1, grow),
			ZIndex = 5,
			Selectable = false,
		}, b.Instance)
		extra.Activated:Connect(function()
			if b.IsEnabled() then
				click()
				if o.OnClick then
					o.OnClick()
				end
			end
		end)
	end
	return b
end

export type CardOpts = {
	Icon: string,
	Title: string,
	Subtitle: string?,
	Size: UDim2?,
	LayoutOrder: number?,
	OnClick: (() -> ())?,
	Name: string?,
}

-- Wide feature card (CHARACTERS / UPGRADES / ARENA): gold icon well, serif title,
-- small subtitle and a chevron.
function UIKit.Card(parent: Instance?, o: CardOpts): Button
	local b = UIKit.Button(parent, {
		Kind = "Secondary",
		Title = o.Title,
		Subtitle = o.Subtitle,
		TitleStyle = "H2",
		Chevron = true,
		Size = o.Size or UDim2.fromOffset(Theme.Layout.MenuColumn, Theme.Size.BigButton),
		LayoutOrder = o.LayoutOrder,
		OnClick = o.OnClick,
		Name = o.Name or o.Title,
		Align = "Left",
	})
	-- icon well: a darker rounded square with a gold hairline
	local holder = b.Content:FindFirstChild("IconHolder") :: Frame
	holder.Visible = true
	holder.Size = UDim2.fromOffset(46, 46)
	local well = new("Frame", {
		Name = "Well",
		BackgroundColor3 = C.PanelInset,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
	}, holder)
	corner(well, Theme.Radius.S + 2)
	stroke(well, C.Gold, 1, 0.5)
	Icons.Draw(well, o.Icon, { Size = 28, Color = P.gold_400, Back = C.PanelInset, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	local column = b.Content:FindFirstChild("Text") :: Frame
	column.Size = UDim2.new(1, -(46 + 20 + 2 * Theme.Space.M), 1, 0)
	if b.Title then
		b.Title.Text = o.Title
	end
	return b
end

------------------------------------------------------------------------------------------
-- Chips, badges, meters, tiles
------------------------------------------------------------------------------------------

export type Chip = { Frame: Frame, Value: TextLabel, Caption: TextLabel?, SetValue: (string) -> () }

-- Small stat: [icon] CAPTION value  (auto width).
function UIKit.Chip(parent: Instance?, icon: string?, caption: string?, value: string, props: { [string]: any }?, iconOpts: Icons.Opts?): Chip
	local h = Theme.Size.Chip
	local f = new("Frame", {
		Name = caption or "Chip",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(0, h),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, f)
	if icon then
		local io: Icons.Opts = iconOpts or {}
		io.Size = io.Size or 22
		io.LayoutOrder = 1
		Icons.Draw(f, icon, io)
	end
	local cap: TextLabel? = nil
	if caption then
		cap = text(f, "Caption", UIKit.track(caption), {
			LayoutOrder = 2,
			Size = UDim2.fromOffset(0, h),
			AutomaticSize = Enum.AutomaticSize.X,
		})
	end
	local val = text(f, "Number", value, {
		Name = "Value",
		LayoutOrder = 3,
		Size = UDim2.fromOffset(0, h),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return {
		Frame = f,
		Value = val,
		Caption = cap,
		SetValue = function(s: string)
			val.Text = s
		end,
	}
end

-- Small pill: "x2", "NEW", "OWNED"... kind = "Gold" | "Dark" | "Crimson" | "Slate".
function UIKit.Badge(parent: Instance?, str: string, kind: string?, props: { [string]: any }?): TextLabel
	local k = kind or "Dark"
	local bg, fg = C.PanelInset, C.Text
	if k == "Gold" then
		bg, fg = P.gold_400, P.gold_900
	elseif k == "Crimson" then
		bg, fg = P.crimson_600, P.ivory_100
	elseif k == "Slate" then
		bg, fg = P.slate_600, P.ivory_100
	elseif k == "Moss" then
		bg, fg = P.moss_600, P.ivory_100
	end
	local l = text(nil, "Label", str, {
		Name = "Badge",
		BackgroundColor3 = bg,
		BackgroundTransparency = 0,
		TextColor3 = fg,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(0, Theme.Size.Badge),
		AutomaticSize = Enum.AutomaticSize.X,
	}, Theme.TextSize.Caption)
	padding(l, 0, 7, 0, 7)
	corner(l, 999)
	if k == "Dark" then
		stroke(l, C.PanelEdge, 1, 0.5)
	end
	if props then
		for key, v in pairs(props) do
			(l :: any)[key] = v
		end
	end
	l.Parent = parent
	return l
end

export type MeterOpts = {
	Size: UDim2?,
	Gradient: ColorSequence?,
	Color: Color3?,
	Trail: boolean?,
	TextStyle: string?,
	TextSize: number?,
	Radius: number?,
	Position: UDim2?,
	AnchorPoint: Vector2?,
	LayoutOrder: number?,
}

export type Meter = { Frame: Frame, Fill: Frame, Trail: Frame?, Label: TextLabel?, Set: (frac: number, label: string?) -> (), SetTrail: (frac: number) -> () }

-- Bar with a dark track, gradient fill, optional lagging "damage" trail and centred text.
function UIKit.Meter(parent: Instance?, o: MeterOpts): Meter
	local radius = o.Radius or 999
	local f = new("Frame", {
		Name = "Meter",
		BackgroundColor3 = C.Track,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Size = o.Size or UDim2.new(1, 0, 0, 14),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ClipsDescendants = true,
	})
	corner(f, radius)
	stroke(f, P.slate_600, 1, 0.3)
	local trail: Frame? = nil
	if o.Trail then
		local t = new("Frame", { Name = "Trail", BackgroundColor3 = C.HealthTrail, BackgroundTransparency = 0.25, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, f)
		corner(t, radius)
		trail = t
	end
	local fill = new("Frame", { Name = "Fill", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, f)
	corner(fill, radius)
	if o.Gradient then
		new("UIGradient", { Rotation = 90, Color = o.Gradient }, fill)
	else
		fill.BackgroundColor3 = o.Color or C.Gold
	end
	-- top highlight on the fill
	new("Frame", {
		Name = "Shine",
		BackgroundColor3 = C.Hover,
		BackgroundTransparency = 0.78,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 3, 0, 2),
		Size = UDim2.new(1, -6, 0.28, 0),
	}, fill)
	local label: TextLabel? = nil
	if o.TextStyle then
		label = text(f, o.TextStyle, "", {
			Name = "Value",
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = C.Text,
			TextStrokeColor3 = C.Shadow,
			TextStrokeTransparency = 0.55,
			ZIndex = 3,
		}, o.TextSize)
	end
	f.Parent = parent
	return {
		Frame = f,
		Fill = fill,
		Trail = trail,
		Label = label,
		Set = function(frac: number, str: string?)
			fill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
			fill.Visible = frac > 0.002
			if str and label then
				label.Text = str
			end
		end,
		SetTrail = function(frac: number)
			if trail then
				trail.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
			end
		end,
	}
end

export type TileOpts = {
	Id: string?, -- upgrade id (icon); nil = empty slot
	Size: number,
	Level: number?, -- "x2" badge when above 1
	Evolved: boolean?, -- gold border + gold badge
	Max: boolean?, -- gold badge without the border
	Name: string?,
	Color: Color3?, -- unused (kept for older callers)
	Empty: boolean?,
}
export type IconOpts = TileOpts

--[[
	Upgrade icon tile (ability bar, level-up cards, character info): dark slate square with
	the vector icon, a level badge in the corner and a gold border once evolved. Nothing
	in it is Active, so touches pass through to the thumbstick underneath.
]]
function UIKit.Tile(parent: Instance?, o: TileOpts): Frame
	local size = o.Size
	local radius = math.max(6, math.floor(size * 0.2))
	local empty = o.Empty or o.Id == nil
	local tile = new("Frame", {
		Name = "Tile",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = empty and 0.6 or 0.05,
		BorderSizePixel = 0,
		Active = false,
	})
	corner(tile, radius)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.slate_700, P.slate_900) }, tile)
	if o.Evolved then
		stroke(tile, P.gold_400, math.max(2, size / 22), 0)
	else
		stroke(tile, empty and P.slate_600 or P.slate_500, 1, empty and 0.5 or 0.2)
	end
	if not empty then
		local inset = math.floor(size * 0.13)
		Icons.Upgrade(tile, o.Id, {
			Size = size - inset * 2,
			Position = UDim2.fromOffset(inset, inset),
			Back = P.slate_800,
			Name = "Icon",
		})
	end
	if o.Level and o.Level > 1 and not empty then
		local gold = o.Evolved or o.Max
		local bh = math.max(14, math.floor(size * 0.36))
		local badge = new("TextLabel", {
			Name = "Badge",
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, 3, 1, 3),
			Size = UDim2.fromOffset(0, bh),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = gold and P.gold_400 or P.slate_950,
			BorderSizePixel = 0,
			Text = "x" .. tostring(o.Level),
			FontFace = Theme.Font.Number,
			TextSize = math.floor(bh * 0.78),
			TextColor3 = gold and P.gold_900 or C.Text,
			ZIndex = 5,
			Active = false,
		}, tile)
		padding(badge, 0, 4, 0, 4)
		corner(badge, 999)
		stroke(badge, gold and P.gold_200 or P.slate_500, 1, 0.2)
	end
	tile.Parent = parent
	return tile
end

-- Older name.
function UIKit.IconTile(parent: Instance, o: TileOpts): Frame
	return UIKit.Tile(parent, o)
end

------------------------------------------------------------------------------------------
-- Tabs / segmented control
------------------------------------------------------------------------------------------

export type Tabs = { Frame: Frame, Select: (id: string) -> (), Selected: () -> string }

-- A row of segments in a dark track; the selected one is gold. items = { {Id, Title, Icon?} }.
function UIKit.Tabs(parent: Instance?, items: { { Id: string, Title: string, Icon: string? } }, onSelect: (string) -> (), props: { [string]: any }?): Tabs
	local f = new("Frame", {
		Name = "Tabs",
		BackgroundColor3 = C.PanelInset,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.Size.TapMin),
	})
	corner(f, Theme.Radius.M)
	stroke(f, C.PanelEdge, 1, 0.7)
	padding(f, 4, 4, 4, 4)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalFlex = Enum.UIFlexAlignment.Fill,
	}, f)
	local buttons: { [string]: Button } = {}
	local current = items[1] and items[1].Id or ""
	local function refresh()
		for id, b in pairs(buttons) do
			b.SetKind(id == current and "Primary" or "Ghost")
		end
	end
	for i, item in ipairs(items) do
		buttons[item.Id] = UIKit.Button(f, {
			Kind = "Ghost",
			Title = string.upper(item.Title),
			Icon = item.Icon,
			IconSize = 18,
			Size = UDim2.new(1 / #items, -4, 1, 0),
			LayoutOrder = i,
			Shadow = false,
			Radius = Theme.Radius.S,
			Align = "Center",
			OnClick = function()
				if current ~= item.Id then
					current = item.Id
					refresh()
					onSelect(item.Id)
				end
			end,
		})
	end
	refresh()
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return {
		Frame = f,
		Select = function(id: string)
			current = id
			refresh()
		end,
		Selected = function(): string
			return current
		end,
	}
end

------------------------------------------------------------------------------------------
-- Slider
------------------------------------------------------------------------------------------

export type Slider = { Frame: Frame, Set: (v: number) -> (), Get: () -> number }

-- Labelled 0-1 slider: [icon] NAME ............ 60%  over a gold track with a knob.
function UIKit.Slider(parent: Instance?, title: string, icon: string?, value: number, onChange: (number) -> (), onRelease: (number) -> (), props: { [string]: any }?): Slider
	local v = math.clamp(value, 0, 1)
	local f = new("Frame", { Name = title, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 72) })
	local head = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28) }, f)
	if icon then
		Icons.Draw(head, icon, { Size = 20, Color = P.gold_400, Position = UDim2.fromOffset(0, 4) })
	end
	text(head, "Label", string.upper(title), { Position = UDim2.fromOffset(icon and 28 or 0, 0), Size = UDim2.new(1, -100, 1, 0) })
	local valueLabel = text(head, "Number", "", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 80, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_300 })
	local track = new("Frame", {
		Name = "Track",
		BackgroundColor3 = C.Track,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 44),
		Size = UDim2.new(1, 0, 0, 10),
	}, f)
	corner(track, 999)
	stroke(track, P.slate_600, 1, 0.3)
	local fill = new("Frame", { Name = "Fill", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(v, 1) }, track)
	corner(fill, 999)
	new("UIGradient", { Color = ColorSequence.new(P.gold_600, P.gold_300) }, fill)
	local knob = new("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(v, 0.5),
		Size = UDim2.fromOffset(Theme.Size.Slider, Theme.Size.Slider),
		BackgroundColor3 = P.ivory_100,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, track)
	corner(knob, 999)
	stroke(knob, P.gold_500, 2, 0)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(P.ivory_100, P.ivory_300) }, knob)

	local function show()
		fill.Size = UDim2.fromScale(v, 1)
		knob.Position = UDim2.fromScale(v, 0.5)
		valueLabel.Text = string.format("%d%%", math.floor(v * 100 + 0.5))
	end
	show()

	local dragging: InputObject? = nil
	local function setFromX(x: number)
		v = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		show()
		onChange(v)
	end
	local hit = new("TextButton", {
		Name = "Hit",
		Text = "",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, -14, 0, 28),
		Size = UDim2.new(1, 28, 0, 44),
		ZIndex = 5,
	}, f)
	UIKit.Focusable(hit)
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = input
			setFromX(input.Position.X)
			UIAnim.Tween(knob, Theme.Motion.Fast, { Size = UDim2.fromOffset(Theme.Size.Slider + 6, Theme.Size.Slider + 6) })
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input == dragging or input.UserInputType == Enum.UserInputType.MouseMovement) then
			setFromX(input.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if dragging and (input == dragging or input.UserInputType == Enum.UserInputType.MouseButton1) then
			dragging = nil
			UIAnim.Tween(knob, Theme.Motion.Fast, { Size = UDim2.fromOffset(Theme.Size.Slider, Theme.Size.Slider) })
			onRelease(v)
		end
	end)
	-- gamepad: left / right nudges while the slider is selected
	hit.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.DPadLeft or input.KeyCode == Enum.KeyCode.DPadRight then
			v = math.clamp(v + (input.KeyCode == Enum.KeyCode.DPadRight and 0.1 or -0.1), 0, 1)
			show()
			onChange(v)
			onRelease(v)
		end
	end)
	if props then
		for k, val in pairs(props) do
			(f :: any)[k] = val
		end
	end
	f.Parent = parent
	return {
		Frame = f,
		Set = function(nv: number)
			v = math.clamp(nv, 0, 1)
			show()
		end,
		Get = function(): number
			return v
		end,
	}
end

------------------------------------------------------------------------------------------
-- Toggle
------------------------------------------------------------------------------------------

export type Toggle = { Frame: TextButton, Set: (on: boolean) -> (), Get: () -> boolean }

--[[
	Labelled on / off switch: [icon] NAME + a short description, and a pill switch on the
	right that also says ON / OFF (never colour alone). The whole row is the tap target
	(at least TapMin tall); gamepad A toggles it.
]]
function UIKit.Toggle(parent: Instance?, title: string, icon: string?, description: string?, value: boolean, onChange: (boolean) -> (), props: { [string]: any }?): Toggle
	local on = value == true
	local h = description and 60 or 48
	local row = new("TextButton", {
		Name = title,
		Text = title,
		TextTransparency = 1,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, h),
	})
	UIKit.Focusable(row)
	local x = 0
	if icon then
		Icons.Draw(row, icon, { Size = 20, Color = P.gold_400, Position = UDim2.fromOffset(0, description and 6 or 14) })
		x = 28
	end
	text(row, "Label", string.upper(title), {
		Position = UDim2.fromOffset(x, description and 2 or 0),
		Size = UDim2.new(1, -x - 84, 0, description and (TS(Theme.TextSize.Caption) + 14) or h),
		TextTruncate = Enum.TextTruncate.AtEnd,
	})
	if description then
		text(row, "Small", description, {
			Name = "Description",
			Position = UDim2.fromOffset(x, TS(Theme.TextSize.Caption) + 14),
			Size = UDim2.new(1, -x - 84, 0, h - TS(Theme.TextSize.Caption) - 14),
			TextColor3 = C.TextMuted,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, 13)
	end
	local track = new("Frame", {
		Name = "Switch",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0, description and 22 or h / 2),
		Size = UDim2.fromOffset(72, 30),
		BackgroundColor3 = C.Track,
		BorderSizePixel = 0,
	}, row)
	corner(track, 999)
	local edge = stroke(track, P.slate_600, 1.5, 0.2)
	local knob = new("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 3, 0.5, 0),
		Size = UDim2.fromOffset(24, 24),
		BackgroundColor3 = P.ivory_200,
		BorderSizePixel = 0,
		ZIndex = 3,
	}, track)
	corner(knob, 999)
	local word = text(track, "Label", "OFF", {
		Name = "State",
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 2,
	}, 11)
	local function show(animate: boolean)
		local goal = { Position = on and UDim2.new(1, -27, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) }
		if animate then
			UIAnim.Tween(knob, Theme.Motion.Fast, goal)
		else
			knob.Position = goal.Position
		end
		track.BackgroundColor3 = on and P.gold_500 or C.Track
		edge.Color = on and P.gold_300 or P.slate_600
		knob.BackgroundColor3 = on and P.ivory_100 or P.stone_300
		word.Text = on and "ON" or "OFF"
		word.TextColor3 = on and P.gold_900 or C.TextMuted
		-- the word sits on the side the knob left
		word.Position = UDim2.fromOffset(on and -12 or 12, 0)
	end
	show(false)
	row.Activated:Connect(function()
		on = not on
		show(true)
		if audio then
			audio.Play("Toggle")
		end
		onChange(on)
	end)
	if props then
		for k, v in pairs(props) do
			(row :: any)[k] = v
		end
	end
	row.Parent = parent
	return {
		Frame = row,
		Set = function(v: boolean)
			if on ~= (v == true) then
				on = v == true
				show(false)
			end
		end,
		Get = function(): boolean
			return on
		end,
	}
end

------------------------------------------------------------------------------------------
-- Modal
------------------------------------------------------------------------------------------

export type Modal = { Overlay: Frame, Dim: Frame, Panel: Frame, Face: Frame, Content: Frame }

--[[
	Full-screen modal: a dimmer that covers the whole screen (also under notches) and
	swallows touches, and a centred panel ("Panel" holder → Face → Content). UIBuilder's
	show() / hide() animate it.
]]
function UIKit.Modal(root: Instance, name: string, width: number, height: number, z: number): Modal
	local overlay = new("Frame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Active = true,
		Visible = false,
		ZIndex = z,
	}, root)
	overlay:SetAttribute("BackdropTransparency", Theme.Alpha.Backdrop)
	local dim = new("Frame", {
		Name = "Dim",
		BackgroundColor3 = C.Backdrop,
		BackgroundTransparency = Theme.Alpha.Backdrop,
		BorderSizePixel = 0,
		Active = true,
		ZIndex = 1,
	}, overlay)
	UIKit.Bleed(dim)
	local holder, face = UIKit.Surface(overlay, {
		Name = "Panel",
		Size = UDim2.fromOffset(width, height),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Radius = Theme.Radius.L,
		Transparency = 0.04,
		ZIndex = 2,
	})
	local content = new("Frame", { Name = "Content", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2 }, face)
	UIKit.pad(content, Theme.Space.XL)
	return { Overlay = overlay, Dim = dim, Panel = holder, Face = face, Content = content }
end

------------------------------------------------------------------------------------------
-- Screen header (lobby sub-screens): [< BACK]  TITLE
------------------------------------------------------------------------------------------

export type Header = { Frame: Frame, Back: Button, Title: TextLabel }

function UIKit.ScreenHeader(parent: Instance, title: string, onBack: () -> ()): Header
	local f = new("Frame", { Name = "Header", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56) }, parent)
	local back = UIKit.Button(f, {
		Kind = "Secondary",
		Title = "BACK",
		Icon = "chevronLeft",
		IconSize = 18,
		Size = UDim2.fromOffset(128, 52),
		Align = "Center",
		OnClick = onBack,
		Name = "Back",
	})
	local t = text(f, "H1", title, {
		Name = "Title",
		Position = UDim2.fromOffset(148, 0),
		Size = UDim2.new(1, -148, 1, 0),
		TextColor3 = C.Text,
	})
	return { Frame = f, Back = back, Title = t }
end

------------------------------------------------------------------------------------------
-- Lobby redesign pieces: art pictures, status pills, section labels, icon pills
------------------------------------------------------------------------------------------

local ArtData = require(Shared:WaitForChild("ArtData"))

local ART_FALLBACK_DELAY = 0.6
local ART_POLL = 0.25
local ART_GIVE_UP = 20

--[[
	An owner-made picture from art/ (ArtData key, e.g. "arenas/Forest", "portraits/Mage")
	filling a new frame (cropped to fill unless `scaleType` says otherwise). `fallback(f)`
	draws the stand-in into a frame under the picture: shown at once when the key has no
	upload, otherwise only when the picture has not loaded after 0.6 s (IsLoaded is polled,
	as in Icons). The picture is the frame's "Image" child (dim it with ImageTransparency /
	ImageColor3), the stand-in its "Fallback" child.
]]
function UIKit.ArtPicture(parent: Instance?, key: string, props: { [string]: any }?, fallback: ((Frame) -> ())?, scaleType: Enum.ScaleType?): Frame
	local f = new("Frame", { Name = "Art", BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true, Size = UDim2.fromScale(1, 1) })
	local fb = new("Frame", { Name = "Fallback", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Active = false }, f)
	local image = ArtData.Image(key)
	if not image then
		if fallback then
			fallback(fb)
		end
	else
		fb.Visible = false
		local img = new("ImageLabel", {
			Name = "Image",
			BackgroundTransparency = 1,
			Image = image,
			ScaleType = scaleType or Enum.ScaleType.Crop,
			Size = UDim2.fromScale(1, 1),
			Active = false,
			ZIndex = 2,
		}, f)
		task.spawn(function()
			local waited = 0
			local drawn = false
			while fb.Parent and img.Parent and waited < ART_GIVE_UP do
				if img.IsLoaded then
					fb:Destroy()
					return
				end
				if waited >= ART_FALLBACK_DELAY and not drawn then
					drawn = true
					if fallback then
						fallback(fb)
					end
					fb.Visible = true
				end
				task.wait(ART_POLL)
				waited += ART_POLL
			end
		end)
	end
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

-- Status pill looks: OWNED slate, LOCKED crimson outline, SELECTED / READY / EQUIPPED gold,
-- UNLOCKED green; anything else (USED, PRACTICE, SOON ...) dark.
local STATUS: { [string]: { Back: Color3, Text: Color3, Edge: Color3?, Fill: boolean } } = {
	OWNED = { Back = P.slate_600, Text = P.ivory_100, Fill = true },
	LOCKED = { Back = P.slate_950, Text = P.crimson_300, Edge = P.crimson_500, Fill = true },
	SELECTED = { Back = P.gold_400, Text = P.gold_900, Fill = true },
	READY = { Back = P.gold_400, Text = P.gold_900, Fill = true },
	EQUIPPED = { Back = P.gold_400, Text = P.gold_900, Fill = true },
	UNLOCKED = { Back = P.moss_600, Text = P.ivory_100, Fill = true },
}

-- Restyles a StatusPill for `status` (upper-case key); `label` overrides the shown text.
function UIKit.SetStatus(pill: TextLabel, status: string, label: string?)
	local s = STATUS[status] or { Back = C.PanelInset, Text = C.TextMuted, Edge = C.PanelEdge, Fill = true }
	pill.Text = label or status
	pill.BackgroundColor3 = s.Back
	pill.TextColor3 = s.Text
	local edge = pill:FindFirstChild("StatusEdge") :: UIStroke?
	if edge then
		edge.Color = s.Edge or s.Back
		edge.Transparency = s.Edge and 0.1 or 1
	end
	pill:SetAttribute("Status", status)
end

-- Rounded small-caps status pill ("OWNED", "LOCKED", "SELECTED", "UNLOCKED", "READY").
function UIKit.StatusPill(parent: Instance?, status: string, props: { [string]: any }?): TextLabel
	local l = text(nil, "Label", status, {
		Name = "Status",
		BackgroundTransparency = 0,
		TextXAlignment = Enum.TextXAlignment.Center,
		Size = UDim2.fromOffset(0, Theme.Size.Badge + 6),
		AutomaticSize = Enum.AutomaticSize.X,
	}, Theme.TextSize.Caption)
	padding(l, 0, 10, 0, 10)
	corner(l, 999)
	local edge = stroke(l, C.PanelEdge, 1.5, 1)
	edge.Name = "StatusEdge"
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	UIKit.SetStatus(l, status)
	if props then
		for k, v in pairs(props) do
			(l :: any)[k] = v
		end
	end
	l.Parent = parent
	return l
end

-- Small gold letter-spaced caps over a section ("EFFECT", "SKINS", "ROUTE").
function UIKit.SectionLabel(parent: Instance?, str: string, color: Color3?, props: { [string]: any }?): TextLabel
	local l = text(nil, "Caption", UIKit.track(str), { Name = "Section", TextColor3 = color or P.gold_300 })
	if props then
		for k, v in pairs(props) do
			(l :: any)[k] = v
		end
	end
	l.Parent = parent
	return l
end

export type IconPill = { Frame: Frame, Label: TextLabel, SetText: (s: string) -> () }

-- Dark pill with a thin gold border, an icon and a short caps text ("BEST STAGE 2").
-- Its width follows the text.
function UIKit.IconPill(parent: Instance?, icon: string?, str: string, props: { [string]: any }?): IconPill
	local h = Theme.Size.Badge + 14
	local f = new("Frame", {
		Name = "IconPill",
		BackgroundColor3 = P.slate_900,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, h),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	corner(f, 999)
	stroke(f, P.gold_400, 1.5, 0.15)
	padding(f, 0, 12, 0, icon and 8 or 12)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, f)
	if icon then
		local iconFrame = Icons.Draw(f, icon, { Size = h - 10 })
		iconFrame.LayoutOrder = 1
	end
	local l = text(f, "Label", str, {
		Name = "Text",
		Size = UDim2.fromOffset(0, h),
		AutomaticSize = Enum.AutomaticSize.X,
		TextColor3 = P.gold_200,
		LayoutOrder = 2,
	})
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return {
		Frame = f,
		Label = l,
		SetText = function(s: string)
			l.Text = s
		end,
	}
end

------------------------------------------------------------------------------------------
-- Lobby dashboard pieces (Daily / Leaderboards / Stats / Upgrades redesign)
------------------------------------------------------------------------------------------

export type TitleRule = { Frame: Frame, Title: TextLabel, Set: (str: string) -> () }

-- A centred serif title with a thin gold rule on each side ("—— GLOBAL HIGH SCORES ——").
function UIKit.TitleRule(parent: Instance?, str: string, props: { [string]: any }?, size: number?): TitleRule
	local px = TS(size or Theme.TextSize.H2)
	local f = new("Frame", { Name = "TitleRule", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, px + 10) })
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 14),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, f)
	local function rule(order: number, fadeLeft: boolean)
		local r = new("Frame", { Name = "Rule", BackgroundColor3 = P.gold_400, BorderSizePixel = 0, Size = UDim2.fromOffset(72, 2), LayoutOrder = order }, f)
		new("UIGradient", {
			Transparency = NumberSequence.new(fadeLeft and 1 or 0.1, fadeLeft and 0.1 or 1),
		}, r)
	end
	rule(1, true)
	local t = text(f, "H2", str, {
		Name = "Title",
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, px + 10),
		AutomaticSize = Enum.AutomaticSize.X,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Text,
	}, size or Theme.TextSize.H2)
	rule(3, false)
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return {
		Frame = f,
		Title = t,
		Set = function(s: string)
			t.Text = s
		end,
	}
end

-- A segmented level bar: `max` equal segments, the first `level` gold.
function UIKit.SegmentBar(parent: Instance?, level: number, max: number, props: { [string]: any }?): Frame
	local f = new("Frame", { Name = "Segments", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 8) })
	local n = math.max(1, max)
	local gap = 4
	for i = 1, n do
		local on = i <= level
		local s = new("Frame", {
			Name = "Seg" .. i,
			BackgroundColor3 = on and P.gold_400 or P.slate_950,
			BorderSizePixel = 0,
			Position = UDim2.new((i - 1) / n, (i == 1) and 0 or gap / 2, 0, 0),
			Size = UDim2.new(1 / n, -gap + ((i == 1 or i == n) and gap / 2 or 0), 1, 0),
		}, f)
		corner(s, 999)
		stroke(s, on and P.gold_200 or P.slate_600, 1, on and 0.4 or 0.3)
	end
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

-- Round player avatar: the Roblox head shot (cached, pcall'd), a neutral silhouette under
-- it until it arrives or when it cannot be fetched.
local avatarCache: { [number]: string } = {}
function UIKit.Avatar(parent: Instance?, userId: number?, size: number, props: { [string]: any }?): Frame
	local f = new("Frame", {
		Name = "Avatar",
		BackgroundColor3 = P.slate_700,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
		ClipsDescendants = true,
		Active = false,
	})
	corner(f, 999)
	stroke(f, P.gold_500, 1, 0.45)
	-- silhouette: head + shoulders
	local head = new("Frame", { Name = "Head", BackgroundColor3 = P.slate_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.2), Size = UDim2.fromScale(0.38, 0.38) }, f)
	corner(head, 999)
	local body = new("Frame", { Name = "Shoulders", BackgroundColor3 = P.slate_400, BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0.64), Size = UDim2.fromScale(0.72, 0.6) }, f)
	corner(body, 999)
	local img = new("ImageLabel", { Name = "HeadShot", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Active = false }, f)
	corner(img, 999)
	if type(userId) == "number" and userId > 0 then
		local cached = avatarCache[userId]
		if cached then
			img.Image = cached
		else
			task.spawn(function()
				local ok, content = pcall(function()
					return game:GetService("Players"):GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
				end)
				if ok and type(content) == "string" and content ~= "" then
					avatarCache[userId] = content
					if img.Parent then
						img.Image = content
					end
				end
			end)
		end
	end
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

-- Rank medal for places 1-3 (gold / silver / bronze disc with a laurel ring and the number).
function UIKit.Medal(parent: Instance?, rank: number, size: number, props: { [string]: any }?): Frame
	local tint = ({ P.gold_300, P.steel_200, Color3.fromRGB(205, 140, 88) })[rank] or P.slate_500
	local dark = ({ P.gold_700, P.steel_500, Color3.fromRGB(122, 74, 40) })[rank] or P.slate_700
	local f = new("Frame", { Name = "Medal", BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size), Active = false })
	-- laurel: two leaf arcs behind the disc
	for side = -1, 1, 2 do
		for i = 0, 2 do
			local leaf = new("Frame", {
				Name = "Leaf",
				BackgroundColor3 = tint,
				BackgroundTransparency = 0.15,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5 + side * (0.44 - i * 0.05), 0.72 - i * 0.24),
				Size = UDim2.fromScale(0.16, 0.3),
				Rotation = side * (25 + i * 20),
			}, f)
			corner(leaf, 999)
		end
	end
	local disc = new("Frame", {
		Name = "Disc",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		ZIndex = 2,
	}, f)
	corner(disc, 999)
	new("UIGradient", { Rotation = 90, Color = ColorSequence.new(tint:Lerp(Color3.new(1, 1, 1), 0.25), tint:Lerp(dark, 0.45)) }, disc)
	stroke(disc, dark, 1.5, 0.1)
	text(disc, "Number", tostring(rank), {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = P.slate_950,
		TextScaled = false,
		ZIndex = 3,
	}, math.max(10, math.floor(size * 0.36)))
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

-- A thin horizontal hairline (dividers inside cards and panels).
function UIKit.Hairline(parent: Instance?, props: { [string]: any }?): Frame
	local f = new("Frame", { Name = "Hairline", BackgroundColor3 = P.gold_500, BackgroundTransparency = 0.7, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 1) })
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

return UIKit
