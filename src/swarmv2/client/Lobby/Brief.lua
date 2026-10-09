--!strict
--[[
	SwarmV2Client/Lobby/Brief.lua
	OWNER: lobby track (Chat 1), stream L1. The redesign brief's visual tokens and the few widgets the
	new lobby screens share (class browser, first-time guide, loading card, confirmations).

	Tokens (continuation brief "Visual system and screen behavior"):
	  navy   #162438  opaque panel backgrounds           cream  #FFF3DC  primary text
	  gold   #EFC46E  the one main action                cyan   #65DDE0  selection and focus
	One font family (Nunito, installed), 36-40 px screen titles, 24 px section titles, 18 px body
	(at least 16 px on phones), touch targets at least 48 px (56 for the main action), content
	margins 24 px desktop / 12 px mobile. Errors always carry an icon and words, never colour alone.

	Every actionable control has default, hover, focused (gamepad / keyboard selection, a cyan
	outline), pressed, disabled-with-reason (the caller shows the reason as text beside it) and
	pending states. Nothing here talks to the server.
]]

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Kit = require(script.Parent.Kit)
local UIKit, Theme = Kit.UIKit, Kit.Theme
local new = UIKit.new

local hex = Color3.fromHex

local Brief = {}

Brief.T = {
	Navy = hex("#162438"), -- panel
	NavyDeep = hex("#0E1826"), -- wells and the screen dimmer
	NavyRaised = hex("#223653"), -- cards on a panel
	NavyHover = hex("#2C4466"), -- a hovered card
	Line = hex("#3B5578"), -- hairlines and quiet borders
	Cream = hex("#FFF3DC"), -- primary text
	CreamMuted = hex("#C9C2B0"), -- secondary text (about 8:1 on navy)
	CreamFaint = hex("#9DA7B8"), -- hints, disabled text (still 5:1)
	Gold = hex("#EFC46E"), -- the main action
	GoldPressed = hex("#CBA24F"),
	OnGold = hex("#162438"), -- navy text on gold
	Cyan = hex("#65DDE0"), -- selection, focus
	CyanDeep = hex("#2F9FA4"),
	Danger = hex("#FF8F85"), -- error text / icon on navy
	DangerFill = hex("#5A2430"),
	Good = hex("#8FE3A4"),
	Disabled = hex("#2A3A52"), -- disabled button face
}

Brief.Margin = { Desktop = 24, Mobile = 12 }
Brief.TapMin = 48
Brief.TapMain = 56

local T = Brief.T

local NUNITO = Theme.Font.Body.Family
-- Only the Nunito weights the rest of the game already uses (Theme.Font), so every one exists in Roblox's family file.
local WEIGHT = {
	Regular = Font.new(NUNITO, Enum.FontWeight.SemiBold),
	Bold = Font.new(NUNITO, Enum.FontWeight.Bold),
	Heavy = Font.new(NUNITO, Enum.FontWeight.ExtraBold),
	Black = Font.new(NUNITO, Enum.FontWeight.ExtraBold),
}
Brief.Weight = WEIGHT

-- Sizes by role (virtual px; the lobby UI scales them with its UIScale). Phones get a little more.
local SIZES = {
	Desktop = { Title = 36, Section = 24, Body = 18, Label = 15, Caption = 13 },
	Phone = { Title = 32, Section = 24, Body = 19, Label = 16, Caption = 14 },
}
function Brief.size(role: string, compact: boolean?): number
	local set = (compact == true) and SIZES.Phone or SIZES.Desktop
	return (set :: any)[role] or set.Body
end

-- A TextLabel in the brief's look. role: Title | Section | Body | Label | Caption.
function Brief.label(parent: Instance?, role: string, str: string, props: { [string]: any }?, compact: boolean?): TextLabel
	local size = Brief.size(role, compact)
	local heavy = role == "Title" or role == "Section" or role == "Label" or role == "Caption"
	local l = new("TextLabel", {
		Name = role,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = str,
		FontFace = heavy and WEIGHT.Heavy or WEIGHT.Bold,
		TextSize = size,
		TextColor3 = (role == "Caption" or role == "Label") and T.CreamMuted or T.Cream,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, size + 6),
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

-- An opaque navy panel (rounded, a quiet line border). Returns the frame.
function Brief.panel(parent: Instance?, props: { [string]: any }?): Frame
	local f = new("Frame", {
		Name = "Panel",
		BackgroundColor3 = T.Navy,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
	})
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	UIKit.corner(f, 14)
	UIKit.stroke(f, T.Line, 2, 0)
	f.Parent = parent
	return f
end

-- One shared cyan outline: the selection image of every focusable control (gamepad / keyboard focus).
local focusImage = new("Frame", {
	Name = "BriefFocus",
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 8, 1, 8),
	Position = UDim2.fromOffset(-4, -4),
})
UIKit.corner(focusImage, 16)
UIKit.stroke(focusImage, T.Cyan, 3, 0)

function Brief.focusable(b: GuiObject)
	b.Selectable = true
	b.SelectionImageObject = focusImage
end

local function mouseInput(): boolean
	local last = UserInputService:GetLastInputType()
	return last == Enum.UserInputType.MouseMovement or last == Enum.UserInputType.MouseButton1 or last == Enum.UserInputType.MouseWheel
end

-- Moves gamepad selection to `obj` when the player is on a gamepad (keyboard / mouse / touch: no change).
function Brief.focusIfGamepad(obj: GuiObject?)
	if not obj then
		return
	end
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Gamepad1 or last == Enum.UserInputType.Gamepad2 then
		local ok = pcall(function()
			game:GetService("GuiService").SelectedObject = obj
		end)
		if not ok then
			return
		end
	end
end

local KINDS = {
	Primary = { Fill = T.Gold, Text = T.OnGold, Line = T.Gold },
	Secondary = { Fill = T.NavyRaised, Text = T.Cream, Line = T.Line },
	Quiet = { Fill = T.Navy, Text = T.CreamMuted, Line = T.Line },
	Danger = { Fill = T.DangerFill, Text = T.Cream, Line = T.Danger },
	Selected = { Fill = T.Cyan, Text = T.OnGold, Line = T.Cyan },
}

export type Button = {
	Instance: TextButton,
	Face: Frame,
	Label: TextLabel,
	SetText: (text: string) -> (),
	SetKind: (kind: string) -> (),
	SetEnabled: (on: boolean) -> (),
	SetPending: (on: boolean, text: string?) -> (),
	IsEnabled: () -> boolean,
	IsPending: () -> boolean,
}

--[[
	A button. o: Kind (Primary gold | Secondary | Quiet | Danger | Selected), Title, Size (default
	160 x 48; the main action 56 high), Name, Icon (Icons name), LayoutOrder, ZIndex, Position,
	AnchorPoint, TitleSize, OnClick. Clicks are ignored while disabled or pending (and for 0.35 s
	after one went through, so a double tap cannot send twice). Disabled keeps the title readable:
	say why in a text line beside it.
]]
function Brief.button(parent: Instance?, o: { [string]: any }): Button
	local kind = o.Kind or "Secondary"
	local enabled = true
	local pending = false
	local hover = false
	local pressed = false
	local busyUntil = 0
	local title: string = o.Title or ""
	local pendingText: string? = nil

	local hit = new("TextButton", {
		Name = o.Name or "Button",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = o.Size or UDim2.fromOffset(160, Brief.TapMin),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
	})
	Brief.focusable(hit)
	local face = new("Frame", {
		Name = "Face",
		BackgroundColor3 = T.NavyRaised,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = hit.ZIndex,
		Active = false,
	}, hit)
	UIKit.corner(face, 12)
	local stroke = UIKit.stroke(face, T.Line, 2, 0)
	local scale = new("UIScale", { Scale = 1 }, face)
	local label = new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = title,
		FontFace = WEIGHT.Black,
		TextSize = o.TitleSize or 18,
		TextColor3 = T.Cream,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		ZIndex = hit.ZIndex + 1,
		Active = false,
	}, face)
	if o.Icon and Kit.Icons.Has(o.Icon) then
		Kit.Icons.Draw(face, o.Icon, {
			Size = 22,
			Color = kind == "Primary" and T.OnGold or T.Cream,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 14, 0.5, 0),
			ZIndex = hit.ZIndex + 1,
			Name = "Icon",
		})
		label.Size = UDim2.new(1, -52, 1, 0)
		label.Position = UDim2.fromOffset(42, 0)
	end

	local function paint()
		local k = (KINDS :: any)[kind] or KINDS.Secondary
		local fill: Color3 = k.Fill
		local ink: Color3 = k.Text
		local line: Color3 = k.Line
		if not enabled then
			fill, ink, line = T.Disabled, T.CreamFaint, T.Line
		elseif pending then
			fill, ink = fill:Lerp(T.Navy, 0.35), ink
		elseif pressed then
			fill = kind == "Primary" and T.GoldPressed or fill:Lerp(Color3.new(0, 0, 0), 0.15)
		elseif hover then
			fill = fill:Lerp(Color3.new(1, 1, 1), 0.12)
		end
		face.BackgroundColor3 = fill
		stroke.Color = line
		label.TextColor3 = ink
		label.Text = (pending and pendingText) or title
		hit.Active = enabled and not pending
	end
	paint()

	hit.MouseEnter:Connect(function()
		if mouseInput() then
			hover = true
			paint()
		end
	end)
	hit.MouseLeave:Connect(function()
		hover = false
		pressed = false
		scale.Scale = 1
		paint()
	end)
	hit.SelectionGained:Connect(function()
		hover = true
		paint()
	end)
	hit.SelectionLost:Connect(function()
		hover = false
		paint()
	end)
	hit.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) and enabled and not pending then
			pressed = true
			scale.Scale = 0.97
			paint()
		end
	end)
	hit.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			pressed = false
			scale.Scale = 1
			if t == Enum.UserInputType.Touch then
				hover = false
			end
			paint()
		end
	end)
	hit.Activated:Connect(function()
		if not enabled or pending then
			return
		end
		local now = os.clock()
		if now < busyUntil then
			return
		end
		busyUntil = now + 0.35
		if o.OnClick then
			o.OnClick()
		end
	end)
	hit.Parent = parent

	local self: Button
	self = {
		Instance = hit,
		Face = face,
		Label = label,
		SetText = function(text: string)
			title = text
			paint()
		end,
		SetKind = function(k: string)
			kind = k
			paint()
		end,
		SetEnabled = function(on: boolean)
			enabled = on
			paint()
		end,
		SetPending = function(on: boolean, text: string?)
			pending = on
			pendingText = text
			paint()
		end,
		IsEnabled = function(): boolean
			return enabled
		end,
		IsPending = function(): boolean
			return pending
		end,
	}
	return self
end

-- A small pill badge: kind Owned | Selected | Locked | Starter | Info | Error. Icon + words, never colour alone.
function Brief.badge(parent: Instance?, kind: string, text: string, props: { [string]: any }?, compact: boolean?): Frame
	local fill, ink, line = T.Navy, T.Cream, T.Line
	local icon: string? = nil
	if kind == "Selected" then
		fill, ink, line, icon = T.Cyan, T.OnGold, T.Cyan, "check"
	elseif kind == "Owned" or kind == "Starter" then
		fill, ink, line, icon = T.NavyRaised, T.Cream, T.Cream, nil
	elseif kind == "Locked" then
		fill, ink, line, icon = T.NavyDeep, T.CreamMuted, T.Line, "lock"
	elseif kind == "Error" then
		fill, ink, line, icon = T.DangerFill, T.Cream, T.Danger, "warning"
	elseif kind == "Info" then
		fill, ink, line, icon = T.NavyDeep, T.Cream, T.Cyan, "info"
	end
	local size = Brief.size("Caption", compact)
	local f = new("Frame", {
		Name = "Badge_" .. kind,
		BackgroundColor3 = fill,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(60, size + 10),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	UIKit.corner(f, 999)
	UIKit.stroke(f, line, 1.5, 0)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
	}, f)
	UIKit.padding(f, 0, 9, 0, 9)
	if icon and Kit.Icons.Has(icon) then
		local ic = Kit.Icons.Draw(f, icon, { Size = size, Color = ink, Name = "Icon", LayoutOrder = 1 })
		ic.LayoutOrder = 1
	end
	new("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = text,
		FontFace = WEIGHT.Black,
		TextSize = size,
		TextColor3 = ink,
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, size + 6),
		LayoutOrder = 2,
		Active = false,
	}, f)
	if props then
		for k, v in pairs(props) do
			(f :: any)[k] = v
		end
	end
	f.Parent = parent
	return f
end

-- A thin progress bar; returns the track and a setter (0..1).
function Brief.bar(parent: Instance?, props: { [string]: any }?): (Frame, (fraction: number) -> ())
	local track = new("Frame", {
		Name = "Bar",
		BackgroundColor3 = T.NavyDeep,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 10),
	})
	if props then
		for k, v in pairs(props) do
			(track :: any)[k] = v
		end
	end
	UIKit.corner(track, 5)
	UIKit.stroke(track, T.Line, 1, 0)
	local fill = new("Frame", {
		Name = "Fill",
		BackgroundColor3 = T.Gold,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(0, 1),
	}, track)
	UIKit.corner(fill, 5)
	track.Parent = parent
	return track, function(fraction: number)
		fill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	end
end

-- A message line with an icon and words (errors never rely on colour alone). kind: Error | Info | Good
function Brief.note(parent: Instance?, kind: string, text: string, props: { [string]: any }?, compact: boolean?): Frame
	local ink = kind == "Error" and T.Danger or (kind == "Good" and T.Good or T.Cyan)
	local icon = kind == "Error" and "warning" or (kind == "Good" and "check" or "info")
	local size = Brief.size("Body", compact)
	local row = new("Frame", {
		Name = "Note",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, size + 8),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	if props then
		for k, v in pairs(props) do
			(row :: any)[k] = v
		end
	end
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 8),
	}, row)
	local ic = Kit.Icons.Draw(row, icon, { Size = size, Color = ink, Name = "Icon" })
	ic.LayoutOrder = 1
	new("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = text,
		FontFace = WEIGHT.Bold,
		TextSize = size,
		TextColor3 = T.Cream,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, -(size + 10), 0, size + 6),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Active = false,
	}, row)
	row.Parent = parent
	return row
end

-- Tweens unless reduced motion is on (ClientSettings.ReducedEffects); a plain set then.
function Brief.tween(obj: Instance, seconds: number, props: { [string]: any }, reduced: boolean?)
	if reduced == true then
		for k, v in pairs(props) do
			(obj :: any)[k] = v
		end
		return
	end
	TweenService:Create(obj, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

return Brief
