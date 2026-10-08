--[[
	MetaUI.lua
	Shared building blocks for the META lobby screens (MenuSigils, MenuWeekly, MenuSeason,
	MenuTitles, MenuCollection, MenuStreak; docs/features/META.md): the screen frame
	(header, panel with a fixed head, a scrolling body and an optional footer), list rows
	with an icon, two lines and an optional action button, grid tiles with silhouettes for
	what is not found yet, and the server clock.
]]

local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)
local Icons = require(script.Parent.Icons)

local MetaUI = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C = Theme.Color

function MetaUI.place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end
local place = MetaUI.place

-- The server's clock (weeks, days and seasons follow it, not the device's).
function MetaUI.Now(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return (ok and type(t) == "number" and t > 0) and t or os.time()
end

-- The profile's META fields (ProfileSync.Features), never nil.
function MetaUI.Features(p: { [string]: any }?): { [string]: any }
	local f = p and p.Features
	return type(f) == "table" and f or {}
end

function MetaUI.Send(...: any)
	Remotes.Get("Meta"):FireServer(...)
end

export type ScreenFrame = {
	Header: any,
	Panel: Frame,
	Face: Frame,
	Head: Frame,
	Body: ScrollingFrame,
	Foot: Frame,
	Layout: (v: Vector2, portrait: boolean, ins: { [string]: number }, headH: number, footH: number) -> (),
}

-- The screen frame: header + panel (Head on top, Body scrolling, Foot at the bottom).
function MetaUI.Screen(screen: Frame, ctx: { [string]: any }, title: string, maxW: number?): ScreenFrame
	local header = UIKit.ScreenHeader(screen, title, ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L })
	local head = new("Frame", { Name = "Head", BackgroundTransparency = 1 }, face)
	local body = new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 5,
		ScrollBarImageColor3 = C.PanelEdge,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	local foot = new("Frame", { Name = "Foot", BackgroundTransparency = 1 }, face)
	local f: ScreenFrame
	f = {
		Header = header,
		Panel = holder,
		Face = face,
		Head = head,
		Body = body,
		Foot = foot,
		Layout = function(v: Vector2, portrait: boolean, ins: { [string]: number }, headH: number, footH: number)
			local W, H = v.X, v.Y
			local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
			local headY = math.max(ins.Top + 4, 12)
			place(header.Frame, M, headY, math.min(580, W - 2 * M), 56)
			local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
			local w = math.min(W - 2 * M, maxW or 900)
			local h = math.max(160, H - top - M)
			place(holder, (W - w) / 2, top, w, h)
			local pad = 14
			local inner = w - 2 * pad
			place(head, pad, pad, inner, headH)
			local footY = h - pad - footH
			foot.Visible = footH > 0
			place(foot, pad, footY, inner, footH)
			local bodyY = pad + headH + (headH > 0 and 8 or 0)
			place(body, pad, bodyY, inner + 6, math.max(40, footY - bodyY - (footH > 0 and 8 or 0)))
		end,
	}
	return f
end

-- A one-line label that shrinks a little before it truncates.
function MetaUI.Line(parent: Instance?, style: string, str: string, size: number, props: { [string]: any }?): TextLabel
	local l = text(parent, style, str, props, size)
	l.TextTruncate = Enum.TextTruncate.AtEnd
	return l
end

export type Row = {
	Frame: Frame,
	Icon: Frame,
	Title: TextLabel,
	Sub: TextLabel,
	Action: any?,
	SetDim: (on: boolean) -> (),
	SetDone: (on: boolean) -> (),
}

--[[
	A list row: [icon] TITLE / sub line, an optional action button on the right.
	o = { Name, Order, Icon, Title, Sub, Action = { Title, Kind, OnClick }?, Height? }
]]
function MetaUI.Row(parent: Instance, o: { [string]: any }): Row
	local h = o.Height or 64
	local f = new("Frame", {
		Name = o.Name or "Row",
		BackgroundColor3 = C.PanelRaised,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -8, 0, h),
		LayoutOrder = o.Order or 0,
	}, parent)
	UIKit.corner(f, Theme.Radius.M)
	local stroke = UIKit.stroke(f, C.PanelEdge, 2, 0)
	local iconHolder = new("Frame", { Name = "IconHolder", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, (h - 40) // 2), Size = UDim2.fromOffset(40, 40) }, f)
	if o.Icon then
		Icons.Draw(iconHolder, o.Icon, { Size = 36, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelRaised })
	end
	local actionW = o.Action and 112 or 0
	local textW = -(60 + actionW + (o.Action and 12 or 8))
	local title = MetaUI.Line(f, "Label", o.Title or "", 16, { Name = "RowTitle", Position = UDim2.fromOffset(60, 8), Size = UDim2.new(1, textW, 0, TS(16) + 4), TextColor3 = C.Text })
	local sub = MetaUI.Line(f, "Small", o.Sub or "", 13, { Name = "RowSub", Position = UDim2.fromOffset(60, 10 + TS(16) + 4), Size = UDim2.new(1, textW, 0, TS(13) + 4), TextColor3 = C.TextMuted })
	local action = nil
	if o.Action then
		action = UIKit.Button(f, {
			Kind = o.Action.Kind or "Primary",
			Title = o.Action.Title,
			TitleStyle = "Label",
			TitleSize = 15,
			Align = "Center",
			Shrink = true,
			Name = "Action",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(actionW, math.max(Theme.Size.TapMin, h - 16)),
			Shadow = false,
			OnClick = o.Action.OnClick,
		})
	end
	return {
		Frame = f,
		Icon = iconHolder,
		Title = title,
		Sub = sub,
		Action = action,
		SetDim = function(on: boolean)
			f.BackgroundColor3 = on and C.Disabled or C.PanelRaised
			title.TextColor3 = on and C.DisabledText or C.Text
			stroke.Color = on and C.Divider or C.PanelEdge
		end,
		-- finished / claimed / equipped: pale lime with a green edge (the row's own text says why)
		SetDone = function(on: boolean)
			f.BackgroundColor3 = on and C.SelectedPale or C.PanelRaised
			stroke.Color = on and C.SelectedEdge or C.PanelEdge
		end,
	}
end

-- Darkens everything drawn in `frame` into a silhouette (not found yet).
function MetaUI.Silhouette(frame: Instance)
	local dark = C.TextMuted
	for _, d in ipairs(frame:GetDescendants()) do
		if d:IsA("ImageLabel") or d:IsA("ImageButton") then
			d.ImageColor3 = dark
		elseif d:IsA("TextLabel") then
			d.TextColor3 = dark
			d.TextStrokeTransparency = 1
		elseif d:IsA("UIStroke") then
			d.Color = dark
		elseif d:IsA("UIGradient") then
			d.Enabled = false
		elseif d:IsA("GuiObject") and d.BackgroundTransparency < 1 then
			d.BackgroundColor3 = dark
		end
	end
end

--[[
	A grid tile: an icon (silhouette when not known) and a name under it ("???" when not
	known). o = { Name, Order, Icon, Character?, Text, Known, Size }.
]]
function MetaUI.Tile(parent: Instance, o: { [string]: any }): Frame
	local f = new("Frame", { Name = o.Name or "Tile", BackgroundColor3 = o.Known and C.PanelRaised or C.Disabled, BackgroundTransparency = 0, BorderSizePixel = 0, LayoutOrder = o.Order or 0 }, parent)
	UIKit.corner(f, Theme.Radius.M)
	UIKit.stroke(f, o.Known and C.PanelEdge or C.Divider, 2, 0)
	local well = new("Frame", { Name = "Well", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.new(0, 48, 0, 48) }, f)
	local icon
	if o.Character then
		icon = Icons.Character(well, o.Character, { Size = 44, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelRaised })
	elseif o.Icon == "skull" or o.Icon == "crown" then
		icon = Icons.Draw(well, o.Icon, { Size = 44, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelRaised, Color = o.Known and C.Danger or nil })
	else
		icon = Icons.Upgrade(well, o.Icon, { Size = 44, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = C.PanelRaised })
	end
	if not o.Known then
		MetaUI.Silhouette(icon)
		-- pictures load later: keep them dark when they arrive
		icon.DescendantAdded:Connect(function()
			MetaUI.Silhouette(icon)
		end)
	end
	local name = text(f, "Small", o.Known and (o.Text or "") or "???", {
		Name = "TileName",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.new(1, -8, 0, TS(12) * 2 + 4),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextColor3 = o.Known and C.Text or C.TextFaint,
	}, 12)
	name.TextTruncate = Enum.TextTruncate.AtEnd
	return f
end

-- Removes the children made by earlier fills (keeps layouts and padding).
function MetaUI.Clear(holder: Instance)
	for _, ch in ipairs(holder:GetChildren()) do
		if ch:IsA("GuiObject") then
			ch:Destroy()
		end
	end
end

return MetaUI
