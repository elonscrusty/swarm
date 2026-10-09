--!nonstrict
--[[
	SwarmV2/Run/RunWidgets.lua  (StarterPlayerScripts.SwarmV2Client.Run.RunWidgets)
	OWNER: stream F (run UI).

	The small building blocks of the run screens, in the brief's tokens (RunTheme): an opaque
	navy panel, text in the existing Theme fonts at the brief's sizes, a bar, a segmented
	ring (deadline, hold and bleed-out timers), rank pips, the rarity symbol, a gold / navy
	button with every state, a key cap. The existing UIKit helpers (new, corner, stroke,
	TS) do the plumbing, so the phone text boost and the TextFit pass apply as everywhere.

	Nothing here is Active unless it is a button, so a thumb landing on a HUD piece still
	drives the floating thumbstick.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local UIKit = require(script.Parent.Parent.Parent:WaitForChild("SwarmClient"):WaitForChild("UIKit"))
local RunTheme = require(script.Parent.RunTheme)
local RunConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local RunLayout = require(game:GetService("ReplicatedStorage"):WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunLayout"))

local new, corner, stroke, TS = UIKit.new, UIKit.corner, UIKit.stroke, UIKit.TS

local Widgets = {}

local FONTS = {
	Body = Theme.Font.BodyStrong,
	Soft = Theme.Font.Body,
	Strong = Theme.Font.BodyStrong,
	Label = Theme.Font.Label,
	Heading = Theme.Font.Heading,
	Number = Theme.Font.Number,
}

-- The side of a touch target in design px at this UI scale (48 device points on a phone).
function Widgets.TouchPx(scale: number?): number
	return RunLayout.TouchPx(scale or 1, RunConfig.UI.Layout, UIKit.IsCompact())
end

------------------------------------------------------------------------------------------
-- Panel + text
------------------------------------------------------------------------------------------

--[[
	An opaque navy panel (holder positions it, face is where content goes). o: Name, Size,
	Position, AnchorPoint, ZIndex, Visible, LayoutOrder, Radius, Color, Edge, EdgeThickness,
	Transparency (default RunTheme.PanelAlpha), Base (false: no dark base under the face).
]]
function Widgets.Panel(parent: Instance?, o: any): (Frame, Frame)
	o = o or {}
	local radius = o.Radius or RunTheme.Radius.Panel
	local holder = new("Frame", {
		Name = o.Name or "Panel",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = o.Size or UDim2.fromScale(1, 1),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
		Visible = if o.Visible == nil then true else o.Visible,
		Active = false,
	})
	if o.Base ~= false then
		local base = new("Frame", {
			Name = "Base",
			BackgroundColor3 = RunTheme.Scrim,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, 3),
			Size = UDim2.fromScale(1, 1),
			ZIndex = 0,
			Active = false,
		}, holder)
		corner(base, radius)
	end
	local face = new("Frame", {
		Name = "Face",
		BackgroundColor3 = o.Color or RunTheme.Navy,
		BackgroundTransparency = o.Transparency or RunTheme.PanelAlpha,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
		Active = false,
	}, holder)
	corner(face, radius)
	stroke(face, o.Edge or RunTheme.NavyEdge, o.EdgeThickness or 2, 0)
	holder.Parent = parent
	return holder, face
end

--[[
	A text label in the brief's colours. o: Size (design px, default 18; the phone boost is
	added), Font ("Body" | "Strong" | "Label" | "Heading" | "Number" | "Soft"), Color, Align
	("Left" | "Center" | "Right"), Wrap, Truncate, Fit (a minimum size: the text shrinks to its
	box instead of truncating), plus any property in Props.
]]
function Widgets.Text(parent: Instance?, str: string, o: any): TextLabel
	o = o or {}
	local px = TS(o.Size or RunTheme.Size.Body)
	local align = o.Align or "Left"
	local l = new("TextLabel", {
		Name = o.Name or "Text",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Text = str,
		FontFace = FONTS[o.Font or "Body"] or FONTS.Body,
		TextSize = px,
		TextColor3 = o.Color or RunTheme.Cream,
		TextXAlignment = if align == "Center" then Enum.TextXAlignment.Center elseif align == "Right" then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
		TextYAlignment = o.VAlign == "Top" and Enum.TextYAlignment.Top or (o.VAlign == "Bottom" and Enum.TextYAlignment.Bottom or Enum.TextYAlignment.Center),
		TextWrapped = o.Wrap == true,
		RichText = o.RichText == true,
		Size = o.Box or UDim2.new(1, 0, 0, px + 6),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
		Active = false,
		Visible = if o.Visible == nil then true else o.Visible,
	})
	if o.Truncate then
		l.TextTruncate = Enum.TextTruncate.AtEnd
	end
	if o.Props then
		for k, v in pairs(o.Props) do
			l[k] = v
		end
	end
	if o.Fit then
		Widgets.Fit(l, o.Fit)
	end
	l.Parent = parent
	return l
end

-- The label shrinks to its box (never below `minSize` points) instead of running over a neighbour.
function Widgets.Fit(label: TextLabel, minSize: number?): TextLabel
	local max = label.TextSize
	label.TextScaled = true
	local tf = label:FindFirstChild("TextFit")
	if tf then
		tf:Destroy()
	end
	label:SetAttribute("NoTextFit", true)
	local c = label:FindFirstChild("Fit") or new("UITextSizeConstraint", { Name = "Fit" }, label)
	c.MaxTextSize = max
	c.MinTextSize = math.min(max, minSize or 12)
	return label
end

-- Re-sizes a label made by Text with Fit (design size, the phone boost applies): the box limit follows.
function Widgets.SetSize(label: TextLabel, designSize: number)
	local px = TS(designSize)
	if label.TextSize ~= px then
		label.TextSize = px
	end
	local c = label:FindFirstChild("Fit")
	if c and c:IsA("UITextSizeConstraint") then
		c.MaxTextSize = px
		c.MinTextSize = math.min(px, c.MinTextSize)
	end
end

-- Sets text only when it changed.
function Widgets.Set(label: TextLabel, str: string)
	if label.Text ~= str then
		label.Text = str
	end
end

------------------------------------------------------------------------------------------
-- Bar
------------------------------------------------------------------------------------------

--[[
	A flat bar: dark track, coloured fill, optional trail (the damage chip) and a label on
	top. o: Name, Size, Position, AnchorPoint, Color, Radius, Label (text size; nil = none).
]]
function Widgets.Bar(parent: Instance?, o: any)
	o = o or {}
	local frame = new("Frame", {
		Name = o.Name or "Bar",
		BackgroundColor3 = RunTheme.NavyDeep,
		BorderSizePixel = 0,
		Size = o.Size or UDim2.new(1, 0, 0, 16),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
		ClipsDescendants = true,
		Active = false,
	})
	corner(frame, o.Radius or 999)
	stroke(frame, o.Edge or RunTheme.NavyEdge, 1.5, 0)
	local trail = new("Frame", { Name = "Trail", BackgroundColor3 = o.TrailColor or RunTheme.HealthTrail, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 1, Visible = o.Trail == true, Active = false }, frame)
	corner(trail, 999)
	local fill = new("Frame", { Name = "Fill", BackgroundColor3 = o.Color or RunTheme.Cyan, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 2, Active = false }, frame)
	corner(fill, 999)
	local label = nil
	if o.Label then
		label = Widgets.Text(frame, "", { Name = "Label", Size = o.Label, Font = "Number", Align = "Center", Box = UDim2.fromScale(1, 1), ZIndex = 4, Fit = 9, Color = o.LabelColor or RunTheme.Cream, Props = { TextStrokeColor3 = RunTheme.Scrim, TextStrokeTransparency = 0.45 } })
	end
	local bar = { Frame = frame, Fill = fill, Trail = trail, Label = label }
	function bar.Set(frac: number)
		fill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
	end
	function bar.SetTrail(frac: number)
		trail.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
	end
	function bar.SetColor(c: Color3)
		if fill.BackgroundColor3 ~= c then
			fill.BackgroundColor3 = c
		end
	end
	frame.Parent = parent
	return bar
end

------------------------------------------------------------------------------------------
-- Segmented ring (deadline, hold and bleed-out timers)
------------------------------------------------------------------------------------------

--[[
	A ring of segments that light clockwise from the top. o: Size (diameter px), Segments
	(default 28), Color (lit), Off (unlit colour), Name, Position, AnchorPoint. Returns
	{ Frame, Set(frac 0..1), SetColor(c) }; Set only touches segments whose state changed.
]]
function Widgets.Ring(parent: Instance?, o: any)
	o = o or {}
	local d = o.Size or 56
	local n = o.Segments or 28
	local holder = new("Frame", {
		Name = o.Name or "Ring",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(d, d),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
		Active = false,
	})
	local lit, off = o.Color or RunTheme.Cyan, o.Off or RunTheme.NavyRaised
	local r = d / 2 - 4
	local segW = math.max(3, math.floor(2 * math.pi * r / n * 0.6))
	local segs = {}
	for i = 1, n do
		local a = (i - 1) / n * math.pi * 2 - math.pi / 2
		segs[i] = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(d / 2 + math.cos(a) * r, d / 2 + math.sin(a) * r),
			Size = UDim2.fromOffset(segW, 8),
			Rotation = math.deg(a) + 90,
			BackgroundColor3 = off,
			BorderSizePixel = 0,
			Active = false,
		}, holder)
		corner(segs[i], 3)
	end
	local ring = { Frame = holder, Lit = -1, Color = lit, Off = off, Segments = segs }
	function ring.Set(frac: number)
		local count = math.floor(math.clamp(frac, 0, 1) * n + 0.001)
		if count == ring.Lit then
			return
		end
		local from, to = math.min(count, math.max(ring.Lit, 0)), math.max(count, math.max(ring.Lit, 0))
		if ring.Lit < 0 then
			from, to = 0, n
		end
		for i = from + 1, to do
			segs[i].BackgroundColor3 = if i <= count then ring.Color else ring.Off
		end
		ring.Lit = count
	end
	function ring.SetColor(c: Color3)
		ring.Color = c
		for i = 1, math.max(ring.Lit, 0) do
			segs[i].BackgroundColor3 = c
		end
	end
	ring.Set(0)
	holder.Parent = parent
	return ring
end

------------------------------------------------------------------------------------------
-- Rank pips + rarity symbol
------------------------------------------------------------------------------------------

--[[
	Rank pips under an equipment tile: `max` small squares, `rank` of them filled, gold once
	the item is maxed. o: Size (pip px), Gap, Max. Returns { Frame, Set(rank, max, gold) }.
]]
function Widgets.Pips(parent: Instance?, o: any)
	o = o or {}
	local size = o.Size or 7
	local gap = o.Gap or 3
	local holder = new("Frame", {
		Name = o.Name or "Pips",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, size),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		ZIndex = o.ZIndex or 2,
		Active = false,
	})
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, gap), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
	local pips = {}
	local pipSet = { Frame = holder, Pips = pips, Rank = -1, Max = -1, Gold = false }
	local function ensure(max: number)
		for i = #pips + 1, max do
			local p = new("Frame", { Name = "Pip" .. i, LayoutOrder = i, Size = UDim2.fromOffset(size, size), BackgroundColor3 = RunTheme.NavyDeep, BorderSizePixel = 0, Active = false }, holder)
			corner(p, 2)
			stroke(p, RunTheme.CreamMuted, 1, 0.35)
			pips[i] = p
		end
		for i, p in ipairs(pips) do
			p.Visible = i <= max
		end
	end
	function pipSet.Set(rank: number, max: number, gold: boolean?)
		rank = math.max(0, math.floor(rank))
		max = math.max(1, math.floor(max))
		if rank == pipSet.Rank and max == pipSet.Max and (gold == true) == pipSet.Gold then
			return
		end
		pipSet.Rank, pipSet.Max, pipSet.Gold = rank, max, gold == true
		ensure(max)
		for i = 1, max do
			local on = i <= rank
			pips[i].BackgroundColor3 = if on then (if gold then RunTheme.Gold else RunTheme.Cyan) else RunTheme.NavyDeep
		end
	end
	holder.Parent = parent
	return pipSet
end

--[[
	The rarity symbol, drawn from shapes (a font may lack the glyphs): Common a disc, Uncommon
	a diamond, Rare a four-point star, Epic an eight-point star, Evolution a ringed disc. The
	word always sits next to it; the shape is the second carrier besides colour.
]]
function Widgets.RaritySymbol(parent: Instance?, rarity: string, size: number?): Frame
	local d = size or 18
	local color = RunTheme.Rarity[rarity] or RunTheme.CreamMuted
	local f = new("Frame", { Name = "Symbol_" .. rarity, BackgroundTransparency = 1, Size = UDim2.fromOffset(d, d), Active = false })
	local function shape(w: number, h: number, rot: number, round: boolean?, fill: boolean?): Frame
		local s = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(w, h),
			Rotation = rot,
			BackgroundColor3 = color,
			BackgroundTransparency = if fill == false then 1 else 0,
			BorderSizePixel = 0,
			Active = false,
		}, f)
		if round then
			corner(s, 999)
		end
		if fill == false then
			stroke(s, color, 2, 0)
		end
		return s
	end
	if rarity == "Common" then
		shape(d * 0.62, d * 0.62, 0, true)
	elseif rarity == "Uncommon" then
		shape(d * 0.6, d * 0.6, 45)
	elseif rarity == "Rare" then
		shape(d * 0.34, d * 0.96, 0)
		shape(d * 0.96, d * 0.34, 0)
	elseif rarity == "Epic" then
		shape(d * 0.62, d * 0.62, 0)
		shape(d * 0.62, d * 0.62, 45)
	elseif rarity == "Evolution" then
		shape(d * 0.94, d * 0.94, 0, true, false)
		shape(d * 0.38, d * 0.38, 45)
	else
		shape(d * 0.5, d * 0.5, 0, true)
	end
	f.Parent = parent
	return f
end

------------------------------------------------------------------------------------------
-- Key cap
------------------------------------------------------------------------------------------

-- A small rounded key hint ("E", "1", "TAB"). Returns the frame.
function Widgets.KeyCap(parent: Instance?, label: string, o: any): Frame
	o = o or {}
	local h = o.Height or 24
	local px = TS(o.Size or 14)
	local w = o.Width or math.max(h, #label * (px * 0.62) + 14)
	local f = new("Frame", {
		Name = "KeyCap",
		BackgroundColor3 = o.Color or RunTheme.NavyRaised,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(w, h),
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 3,
		Active = false,
	})
	corner(f, 6)
	stroke(f, o.Edge or RunTheme.Cyan, 1.5, 0)
	Widgets.Text(f, label, { Name = "Key", Size = o.Size or 14, Font = "Number", Align = "Center", Box = UDim2.fromScale(1, 1), Color = o.TextColor or RunTheme.Cream, ZIndex = (o.ZIndex or 3) + 1 })
	f.Parent = parent
	return f
end

------------------------------------------------------------------------------------------
-- Button (every state: default, hover, focus, pressed, disabled with a reason, pending)
------------------------------------------------------------------------------------------

local focusImage = nil
local function focusOutline()
	if not focusImage then
		focusImage = new("Frame", { Name = "RunFocus", BackgroundTransparency = 1, Size = UDim2.new(1, 8, 1, 8), Position = UDim2.fromOffset(-4, -4) })
		corner(focusImage, 14)
		stroke(focusImage, RunTheme.Cyan, 3, 0)
	end
	return focusImage
end

--[[
	A button. o: Text, Kind ("Primary" gold / "Secondary" navy / "Danger"), Size (UDim2; the
	height is never under 48), Position, AnchorPoint, LayoutOrder, ZIndex, OnClick(input),
	TextSize, Name, Sub (a second small line), SubSize (its design size). Returns { Instance, Face, Label, SetText,
	SetEnabled(on, reason?), SetPending(on), IsEnabled }.
]]
function Widgets.Button(parent: Instance?, o: any): any
	local kind = o.Kind or "Secondary"
	local size = o.Size or UDim2.fromOffset(180, RunTheme.Size.MainAction)
	local fill, textColor, edge
	if kind == "Primary" then
		fill, textColor, edge = RunTheme.Gold, RunTheme.OnGold, RunTheme.GoldDeep
	elseif kind == "Danger" then
		fill, textColor, edge = RunTheme.DangerDeep, RunTheme.Cream, RunTheme.Danger
	else
		fill, textColor, edge = RunTheme.NavyRaised, RunTheme.Cream, RunTheme.NavyEdge
	end
	local btn = new("TextButton", {
		Name = o.Name or "Button",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = size,
		Position = o.Position or UDim2.new(),
		AnchorPoint = o.AnchorPoint or Vector2.zero,
		LayoutOrder = o.LayoutOrder or 0,
		ZIndex = o.ZIndex or 1,
		Selectable = true,
		SelectionImageObject = focusOutline(),
		Active = true,
	})
	local face = new("Frame", { Name = "Face", BackgroundColor3 = fill, BorderSizePixel = 0, Size = UDim2.new(1, 0, 1, -3), ZIndex = (o.ZIndex or 1), Active = false }, btn)
	corner(face, RunTheme.Radius.Panel)
	local faceStroke = stroke(face, edge, 2, 0)
	local shade = new("Frame", { Name = "Base", BackgroundColor3 = RunTheme.Scrim, BackgroundTransparency = 0.3, BorderSizePixel = 0, Position = UDim2.fromOffset(0, 3), Size = UDim2.new(1, 0, 1, -3), ZIndex = (o.ZIndex or 1) - 1, Active = false }, btn)
	corner(shade, RunTheme.Radius.Panel)
	local sub = o.Sub
	local label = Widgets.Text(face, o.Text or "", {
		Name = "Label",
		Size = o.TextSize or 20,
		Font = "Heading",
		Align = "Center",
		Color = textColor,
		Box = if sub then UDim2.new(1, -12, 0.58, 0) else UDim2.new(1, -12, 1, 0),
		Position = UDim2.fromOffset(6, 0),
		Fit = 12,
		ZIndex = (o.ZIndex or 1) + 1,
	})
	local subLabel = nil
	if sub then
		subLabel = Widgets.Text(face, sub, { Name = "Sub", Size = o.SubSize or 14, Font = "Label", Align = "Center", Color = textColor, Box = UDim2.new(1, -12, 0.4, 0), Position = UDim2.new(0, 6, 0.58, 0), Fit = 10, ZIndex = (o.ZIndex or 1) + 1 })
	end
	local state = { Enabled = true, Pending = false, Hover = false, Down = false }
	local function paint()
		local dim = (not state.Enabled) or state.Pending
		face.BackgroundColor3 = if dim then RunTheme.NavyDeep else (if state.Down then fill:Lerp(Color3.new(0, 0, 0), 0.18) elseif state.Hover then fill:Lerp(Color3.new(1, 1, 1), 0.14) else fill)
		label.TextColor3 = if dim then RunTheme.CreamFaint else textColor
		if subLabel then
			subLabel.TextColor3 = if dim then RunTheme.CreamFaint else textColor
		end
		faceStroke.Color = if dim then RunTheme.NavyEdge else edge
		face.Position = UDim2.fromOffset(0, if state.Down and state.Enabled then 2 else 0)
	end
	btn.MouseEnter:Connect(function()
		state.Hover = true
		paint()
	end)
	btn.MouseLeave:Connect(function()
		state.Hover = false
		state.Down = false
		paint()
	end)
	btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			state.Down = true
			paint()
		end
	end)
	btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			state.Down = false
			paint()
		end
	end)
	btn.Activated:Connect(function(input)
		if state.Enabled and not state.Pending and o.OnClick then
			o.OnClick(input)
		end
	end)
	local api = { Instance = btn, Face = face, Label = label, Sub = subLabel }
	function api.SetText(str: string, subText: string?)
		label.Text = str
		if subLabel and subText then
			subLabel.Text = subText
		end
	end
	function api.SetEnabled(on: boolean, reason: string?)
		state.Enabled = on
		btn.Selectable = on
		if subLabel and not on and reason then
			subLabel.Text = reason
		end
		paint()
	end
	function api.SetPending(on: boolean)
		state.Pending = on
		paint()
	end
	function api.IsEnabled(): boolean
		return state.Enabled and not state.Pending
	end
	btn.Parent = parent
	return api
end

return Widgets
