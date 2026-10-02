--[[
	MenuCurses.lua
	The CURSES screen: pick up to CurseData.MaxActive run modifiers before a run. Every
	card shows the curse, what it does and its gold bonus; tapping toggles it. The pick is
	sent with SetCurses and the server's answer (player attribute "Curses") is what the
	screen shows (a tap shows at once, the attribute confirms or corrects it).
	A run uses the curses of whoever starts it: during someone else's countdown the screen
	says so (your pick is still saved for your own runs).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local MenuCurses = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local player = Players.LocalPlayer

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

-- The pick on show: a recent tap (until the server answers), else the attribute.
local optimistic: { string }? = nil
local optimisticUntil = 0

function MenuCurses.Current(): { string }
	if optimistic and os.clock() < optimisticUntil then
		return optimistic
	end
	optimistic = nil
	return CurseData.FromString(player:GetAttribute("Curses"))
end

function MenuCurses.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Cards = {} }
	ui.Header = UIKit.ScreenHeader(screen, "CURSES", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	UIKit.padding(face, 16, 16, 16, 16)
	ui.Intro = text(face, "Body", string.format("Pick up to %d curses before a run. They make the run harder for everyone in it, and each one adds gold.", CurseData.MaxActive), {
		Name = "Intro",
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, 0, 0, TS(16) * 2 + 8),
	})
	ui.Note = text(face, "Small", "", { Name = "Note", TextColor3 = P.gold_300, TextWrapped = true, Visible = false })
	local scroll = new("ScrollingFrame", {
		Name = "Cards",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	UIKit.padding(scroll, 4, 6, 4, 4)
	ui.Scroll = scroll
	ui.Grid = new("UIGridLayout", { CellSize = UDim2.fromOffset(300, 132), CellPadding = UDim2.fromOffset(12, 12), SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center }, scroll)

	local function send(list: { string })
		optimistic = list
		optimisticUntil = os.clock() + 2
		Remotes.Get("SetCurses"):FireServer(list)
		MenuCurses._refresh()
	end

	local function toggle(id: string)
		local cur = MenuCurses.Current()
		local list = {}
		local had = false
		for _, c in ipairs(cur) do
			if c == id then
				had = true
			else
				table.insert(list, c)
			end
		end
		if not had then
			if #cur >= CurseData.MaxActive then
				ctx.Toast(string.format("Up to %d curses: drop one first.", CurseData.MaxActive), P.gold_300)
				return
			end
			table.insert(list, id)
		end
		send(CurseData.Sanitize(list) or {})
	end

	for i, id in ipairs(CurseData.Order) do
		local def = CurseData.Curses[id]
		local b = UIKit.Button(scroll, { Kind = "Secondary", Name = id, LayoutOrder = i, Size = UDim2.fromOffset(300, 132), OnClick = function()
			toggle(id)
		end })
		b.Instance.Text = def.Name
		for _, ch in ipairs(b.Content:GetChildren()) do
			if not ch:IsA("UIPadding") then
				ch:Destroy()
			end
		end
		local well = new("Frame", { Name = "Well", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.2, Position = UDim2.fromOffset(0, 14), Size = UDim2.fromOffset(46, 46) }, b.Content)
		UIKit.corner(well, Theme.Radius.S + 2)
		UIKit.stroke(well, P.crimson_400, 1, 0.4)
		Icons.Draw(well, def.Icon, { Size = 28, Color = P.crimson_300, Back = C.PanelInset, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
		local name = text(b.Content, "H3", def.Name, { Name = "CurseName", Position = UDim2.fromOffset(58, 12), Size = UDim2.new(1, -58, 0, TS(18) + 4), TextTruncate = Enum.TextTruncate.AtEnd })
		text(b.Content, "Small", def.Short, { Name = "Short", Position = UDim2.fromOffset(58, 16 + TS(18)), Size = UDim2.new(1, -58, 0, TS(14) * 2 + 6), TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.TextMuted })
		local gold = UIKit.Badge(b.Content, "+" .. math.floor(def.Gold * 100 + 0.5) .. "% GOLD", "Gold", { Name = "Gold", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, -12) })
		local state = UIKit.Badge(b.Content, "OFF", "Dark", { Name = "State", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, 0, 1, -12) })
		ui.Cards[id] = { Button = b, Name = name, State = state, Gold = gold }
	end

	-- footer: the total, CLEAR, DONE
	local foot = new("Frame", { Name = "Footer", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.Size.Button) }, face)
	ui.Footer = foot
	ui.Total = text(foot, "BodyStrong", "", { Name = "Total", Size = UDim2.new(1, -330, 1, 0), TextColor3 = P.gold_200, TextTruncate = Enum.TextTruncate.AtEnd, RichText = true })
	ui.Clear = UIKit.Button(foot, { Kind = "Secondary", Title = "CLEAR", Icon = "close", IconSize = 18, Align = "Center", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -170, 0, 0), Size = UDim2.fromOffset(150, Theme.Size.Button), OnClick = function()
		send({})
	end })
	ui.Done = UIKit.Button(foot, { Kind = "Primary", Title = "DONE", Icon = "check", IconSize = 20, Align = "Center", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(160, Theme.Size.Button), OnClick = ctx.Back })

	MenuCurses._refresh = function()
		local cur = MenuCurses.Current()
		local on: { [string]: boolean } = {}
		for _, id in ipairs(cur) do
			on[id] = true
		end
		for id, card in pairs(ui.Cards) do
			local was = card.On
			card.On = on[id] == true
			card.Button.SetSelected(card.On)
			card.State.Text = card.On and "ON" or "OFF"
			card.State.BackgroundColor3 = card.On and P.crimson_600 or C.PanelInset
			card.Name.TextColor3 = card.On and P.crimson_300 or C.Text
			if was ~= nil and was ~= card.On and card.On then
				UIAnim.Punch(card.Button.Instance, 0.06)
				UIAnim.Flash(card.Button.Instance, P.crimson_300)
				UIAnim.Burst(card.Button.Instance, UDim2.fromScale(0.5, 0.5), { P.crimson_300, P.gold_300 }, 10, 60)
			end
		end
		local mult = CurseData.GoldMult(cur)
		if #cur == 0 then
			ui.Total.Text = "No curses · normal gold"
		else
			ui.Total.Text = string.format('%d / %d curses  ·  <font color="%s">%s gold</font>', #cur, CurseData.MaxActive, UIKit.hex(P.gold_300), CurseData.GoldText(mult))
		end
		ui.Clear.SetEnabled(#cur > 0)
		-- someone else's countdown: their curses are the run's
		local state = Remotes.State()
		local starter = state:GetAttribute("Starter")
		local note = ""
		if state:GetAttribute("Phase") == "Countdown" then
			if starter == player.UserId then
				note = "Your countdown is running: these curses apply to everyone who joins."
			else
				note = "This countdown uses the curses of the player who started it. Your pick is used when you start a run."
			end
		end
		ui.Note.Text = note
		if ui.Note.Visible ~= (note ~= "") then
			ui.Note.Visible = note ~= ""
			MenuCurses._layout()
		end
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(520, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local w = math.min(W - 2 * M, 1040)
		local inner = w - 32 - 10
		local cols = math.clamp(math.floor((inner + 12) / 290), 1, 3)
		local cellW = math.floor((inner - (cols - 1) * 12) / cols)
		local cellH = UIKit.IsCompact() and 118 or 112
		ui.Grid.CellSize = UDim2.fromOffset(cellW, cellH)
		local rows = math.ceil(#CurseData.Order / cols)
		local introH = TS(16) * (w < 640 and 3 or 2) + 10
		ui.Intro.Size = UDim2.new(1, 0, 0, introH)
		local noteH = ui.Note.Visible and (TS(14) * 2 + 8) or 0
		ui.Note.Position = UDim2.fromOffset(0, introH)
		ui.Note.Size = UDim2.new(1, 0, 0, noteH)
		local gridTop = introH + noteH + 6
		local narrow = w < 560
		local footH = narrow and (Theme.Size.Button * 2 + 10 + TS(16)) or Theme.Size.Button
		local gridH = rows * (cellH + 12) + 8
		local fit = 32 + gridTop + gridH + 12 + footH
		local h = math.min(fit, H - top - M)
		place(ui.Panel, (W - w) / 2, top, w, h)
		ui.Scroll.Position = UDim2.fromOffset(0, gridTop)
		ui.Scroll.Size = UDim2.new(1, 0, 1, -(gridTop + footH + 12))
		ui.Footer.Position = UDim2.new(0, 0, 1, -footH)
		ui.Footer.Size = UDim2.new(1, 0, 0, footH)
		if narrow then
			ui.Total.Size = UDim2.new(1, 0, 0, TS(16) + 6)
			ui.Total.TextXAlignment = Enum.TextXAlignment.Center
			local bw = math.floor((w - 32 - 10) / 2)
			ui.Clear.Instance.AnchorPoint = Vector2.new(0, 1)
			ui.Clear.Instance.Position = UDim2.fromScale(0, 1)
			ui.Clear.Instance.Size = UDim2.fromOffset(bw, Theme.Size.Button)
			ui.Done.Instance.AnchorPoint = Vector2.new(1, 1)
			ui.Done.Instance.Position = UDim2.fromScale(1, 1)
			ui.Done.Instance.Size = UDim2.fromOffset(bw, Theme.Size.Button)
		else
			ui.Total.Size = UDim2.new(1, -330, 1, 0)
			ui.Total.TextXAlignment = Enum.TextXAlignment.Left
			ui.Clear.Instance.AnchorPoint = Vector2.new(1, 0)
			ui.Clear.Instance.Position = UDim2.new(1, -170, 0, 0)
			ui.Clear.Instance.Size = UDim2.fromOffset(150, Theme.Size.Button)
			ui.Done.Instance.AnchorPoint = Vector2.new(1, 0)
			ui.Done.Instance.Position = UDim2.fromScale(1, 0)
			ui.Done.Instance.Size = UDim2.fromOffset(160, Theme.Size.Button)
		end
	end
	MenuCurses._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	player:GetAttributeChangedSignal("Curses"):Connect(function()
		optimistic = nil
		MenuCurses._refresh()
	end)
	Remotes.State():GetAttributeChangedSignal("Phase"):Connect(function()
		MenuCurses._refresh()
	end)
	MenuCurses._refresh()

	return {
		Layout = layout,
		Refresh = function(_p)
			MenuCurses._refresh()
		end,
		OnShow = function(_p)
			MenuCurses._refresh()
			local i = 0
			for _, id in ipairs(CurseData.Order) do
				i += 1
				UIAnim.Pop(ui.Cards[id].Button.Instance, 0.03 * i, 0.8)
			end
			MenuCurses._layout()
		end,
	}
end

MenuCurses._refresh = function() end
MenuCurses._layout = function() end

return MenuCurses
