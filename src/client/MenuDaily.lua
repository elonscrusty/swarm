--[[
	MenuDaily.lua
	The DAILY CHALLENGE screen (lobby DAILY card): today's fixed setup, the same for every
	player (CurseData.Daily(day), day = SwarmState "DailyDay", UTC): the arena route with
	its bosses, the curses, the starting bonus; your scored attempt (or "ready"), your best
	ever; PLAY (StartRun "Daily": the first run of the day is scored, later ones are
	practice) and LEADERBOARD (the Daily board).
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local BossData = require(Shared:WaitForChild("BossData"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local MenuDaily = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local ROUTE_STAGES = 5 -- stages shown on the route row

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

-- Today's UTC day (the server's, so every player sees the same daily).
function MenuDaily.Today(): number
	local day = Remotes.State():GetAttribute("DailyDay")
	if type(day) == "number" then
		return day
	end
	return CurseData.DayOf(os.time())
end

-- Display name of a weapon / item id for the bonus line.
function MenuDaily.NameOf(id: string): string
	local w = WeaponData.Weapons[id]
	if w then
		return w.Name
	end
	local it = ItemData.Items[id]
	if it then
		return it.Name
	end
	return id
end

-- The profile's daily view for today: (used, score, best, bestDay).
function MenuDaily.Status(profile: { [string]: any }?): (boolean, number, number, number)
	local d = profile and profile.Daily
	if type(d) ~= "table" then
		return false, 0, 0, 0
	end
	local today = MenuDaily.Today()
	local isToday = d.Day == today
	return isToday and d.Used == true, isToday and (tonumber(d.Score) or 0) or 0, tonumber(d.BestScore) or 0, tonumber(d.BestDay) or 0
end

-- "7h 12m" until the next UTC midnight.
function MenuDaily.TimeLeft(): string
	local now = workspace:GetServerTimeNow()
	local left = CurseData.SecondsLeft(now)
	local h = left // 3600
	local m = (left % 3600) // 60
	if h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	return string.format("%dm", math.max(1, m))
end

local function chip(parent: Instance, icon: string, str: string, color: Color3?, order: number): Frame
	local f = new("Frame", { Name = "Chip", BackgroundColor3 = C.PanelInset, BackgroundTransparency = 0.15, Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order }, parent)
	UIKit.corner(f, 999)
	UIKit.stroke(f, color or C.PanelEdge, 1, 0.35)
	UIKit.padding(f, 0, 12, 0, 8)
	UIKit.list(f, { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 6) })
	Icons.Draw(f, icon, { Size = 20, LayoutOrder = 1, Color = color, Back = C.PanelInset })
	text(f, "Label", str, { LayoutOrder = 2, Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = C.Text }, 13)
	return f
end

local function section(parent: Instance, caption: string, order: number): Frame
	local f = new("Frame", { Name = caption, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, parent)
	UIKit.list(f, { Padding = UDim.new(0, 6) })
	text(f, "Caption", UIKit.track(caption), { LayoutOrder = 0, Size = UDim2.new(1, 0, 0, TS(12) + 4), TextColor3 = P.gold_300 })
	return f
end

local function row(parent: Instance, order: number): Frame
	local r = new("Frame", { Name = "Row", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order }, parent)
	UIKit.list(r, { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 8), Wraps = true })
	return r
end

function MenuDaily.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = {}
	ui.Header = UIKit.ScreenHeader(screen, "DAILY CHALLENGE", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35 })
	ui.Panel = holder
	UIKit.padding(face, 16, 16, 16, 16)

	-- top: date + reset, status badge
	local top = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 56) }, face)
	ui.Top = top
	Icons.Draw(top, "calendar", { Size = 44, Position = UDim2.fromOffset(0, 4), Back = C.Panel })
	ui.Date = text(top, "H2", "", { Name = "Date", Position = UDim2.fromOffset(56, 2), Size = UDim2.new(1, -56, 0, TS(22) + 6) })
	ui.Reset = text(top, "Caption", "", { Name = "Reset", Position = UDim2.fromOffset(56, 8 + TS(22)), Size = UDim2.new(1, -56, 0, TS(12) + 4) })

	local body = new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	UIKit.padding(body, 4, 8, 4, 2)
	UIKit.list(body, { Padding = UDim.new(0, 14) })
	ui.Body = body

	-- your attempt
	local status = section(body, "Your attempt", 1)
	ui.StatusRow = row(status, 1)
	ui.StatusNote = text(status, "Small", "", { LayoutOrder = 2, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextColor3 = C.TextMuted })
	-- the route
	local route = section(body, "Route", 2)
	ui.Route = row(route, 1)
	-- curses
	local curses = section(body, "Curses", 3)
	ui.Curses = row(curses, 1)
	-- starting bonus
	local bonus = section(body, "Starting bonus", 4)
	ui.Bonus = row(bonus, 1)

	-- buttons
	local foot = new("Frame", { Name = "Footer", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64) }, face)
	ui.Footer = foot
	ui.Play = UIKit.Button(foot, {
		Kind = "Primary",
		Glow = true,
		Title = "PLAY",
		Subtitle = "Scored attempt",
		Icon = "play",
		IconSize = 26,
		Align = "Left",
		Name = "PlayDaily",
		OnClick = function()
			local phase = Remotes.State():GetAttribute("Phase") or "Lobby"
			if phase ~= "Lobby" then
				ctx.Toast("Wait for the current run to end.", P.gold_300)
				return
			end
			Remotes.Get("StartRun"):FireServer("Daily")
		end,
	})
	ui.Board = UIKit.Button(foot, {
		Kind = "Secondary",
		Title = "LEADERBOARD",
		Icon = "podium",
		IconSize = 22,
		Align = "Center",
		Name = "DailyBoard",
		OnClick = function()
			ctx.ShowScreen("Ranks", "Daily")
		end,
	})

	local shownDay = -1

	local function fill()
		local p = ctx.Profile()
		local day = MenuDaily.Today()
		local d = CurseData.Daily(day)
		ui.Date.Text = "Daily · " .. d.Date
		ui.Reset.Text = UIKit.track("UTC · new challenge in " .. MenuDaily.TimeLeft())
		local used, score, best, bestDay = MenuDaily.Status(p)
		-- status
		for _, ch in ipairs(ui.StatusRow:GetChildren()) do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		if used then
			UIKit.Badge(ui.StatusRow, "SCORED", "Moss", { LayoutOrder = 1, Size = UDim2.fromOffset(0, 30) })
			text(ui.StatusRow, "H3", score > 0 and CurseData.ScoreText(score) or "Played (no stage cleared yet)", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X, TextColor3 = P.gold_200 })
			ui.StatusNote.Text = "Today's scored attempt is used. You can still practise: practice runs are not scored."
		else
			UIKit.Badge(ui.StatusRow, "READY", "Gold", { LayoutOrder = 1, Size = UDim2.fromOffset(0, 30) })
			text(ui.StatusRow, "H3", "Your scored attempt is waiting", { LayoutOrder = 2, Size = UDim2.fromOffset(0, 30), AutomaticSize = Enum.AutomaticSize.X })
			ui.StatusNote.Text = "Solo. Your first daily run today is scored (stages cleared, then time); it counts the moment it starts."
		end
		if best > 0 then
			ui.StatusNote.Text ..= string.format("  Best ever: %s (%s).", CurseData.ScoreText(best), CurseData.DateText(bestDay))
		end
		ui.Play.SetText(used and "PRACTICE" or "PLAY", used and "Unscored run" or "Scored attempt")
		ui.Play.SetKind(used and "Secondary" or "Primary")
		if shownDay == day then
			return
		end
		shownDay = day
		-- route, curses, bonus (fixed for the day)
		for _, f in ipairs({ ui.Route, ui.Curses, ui.Bonus }) do
			for _, ch in ipairs(f:GetChildren()) do
				if ch:IsA("GuiObject") then
					ch:Destroy()
				end
			end
		end
		for i = 1, ROUTE_STAGES do
			local arena = (Config.Arenas :: any)[d.Arenas[i]]
			local boss = BossData.Get(d.Bosses[i])
			chip(ui.Route, i == 1 and "flag" or "portal", string.format("%d · %s · %s", i, arena and arena.DisplayName or d.Arenas[i], boss and boss.DisplayName or "?"), i == 1 and P.gold_400 or nil, i)
		end
		for i, id in ipairs(d.Curses) do
			local def = CurseData.Curses[id]
			chip(ui.Curses, def.Icon, def.Name .. " · " .. def.Short, P.crimson_300, i)
		end
		chip(ui.Curses, "coin", CurseData.GoldText(CurseData.GoldMult(d.Curses)) .. " gold", P.gold_400, 10)
		local bdef = CurseData.Bonuses[d.Bonus]
		chip(ui.Bonus, bdef and bdef.Icon or "gift", (bdef and bdef.Name or d.Bonus) .. " · " .. CurseData.BonusText(d, MenuDaily.NameOf), P.moss_300, 1)
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(620, W - 2 * M), 56)
		local topY = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local w = math.min(W - 2 * M, 900)
		local narrow = w < 600
		local h = math.min(H - topY - M, portrait and 900 or 600)
		local playH = h < 520 and 60 or 76 -- short landscape phones: a slimmer footer
		local footH = narrow and (playH + 10 + Theme.Size.Button) or playH
		local topH = TS(22) + TS(12) + 20
		ui.Top.Size = UDim2.new(1, 0, 0, topH)
		place(ui.Panel, (W - w) / 2, topY, w, h)
		ui.Body.Position = UDim2.fromOffset(0, topH + 8)
		ui.Body.Size = UDim2.new(1, 0, 1, -(topH + 8 + footH + 12))
		ui.Footer.Position = UDim2.new(0, 0, 1, -footH)
		ui.Footer.Size = UDim2.new(1, 0, 0, footH)
		local inner = w - 32
		if narrow then
			place(ui.Play.Instance, 0, 0, inner, playH)
			place(ui.Board.Instance, 0, playH + 10, inner, Theme.Size.Button)
		else
			local bw = math.min(320, math.floor((inner - 12) / 2))
			local x0 = math.floor((inner - (2 * bw + 12)) / 2)
			place(ui.Play.Instance, x0, 0, bw, playH)
			place(ui.Board.Instance, x0 + bw + 12, math.floor((playH - Theme.Size.Button) / 2), bw, Theme.Size.Button)
		end
	end
	MenuDaily._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	local clock = 0
	return {
		Layout = layout,
		Refresh = function(_p)
			fill()
		end,
		OnShow = function(_p)
			shownDay = -1
			fill()
			UIAnim.Pop(holder, 0, 0.9)
			holder.ClipsDescendants = true
			UIAnim.Sweep(holder, 0.2, 0.8, 0.8)
			MenuDaily._layout()
		end,
		Update = function(dt: number)
			clock += dt
			if clock >= 1 then
				clock = 0
				if screen.Visible then
					ui.Reset.Text = UIKit.track("UTC · new challenge in " .. MenuDaily.TimeLeft())
					if MenuDaily.Today() ~= shownDay then
						fill()
					end
				end
			end
		end,
	}
end

MenuDaily._layout = function() end

return MenuDaily
