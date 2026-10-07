--[[
	MenuDaily.lua
	The DAILY CHALLENGE screen (lobby DAILY card): today's fixed setup, the same for every
	player (CurseData.Daily(day), day = SwarmState "DailyDay", UTC), laid out as one
	dashboard panel:
	  header    calendar, the date ("OCT 02, 2026"), "NEW TRY IN 4H 27M · 00:00 UTC", a status
	            pill (READY / USED)
	  hero      "Your scored attempt is ready" (or your scored result), the rules line, an
	            info card ("counts as soon as the run starts" / practice wording, best ever)
	  ROUTE     the first stages as numbered cards (arena picture art/arenas/<Arena> with a
	            drawn stand-in, arena name, the stage boss) joined by chevrons
	  CURSES    crimson curse cards and the real gold multiplier chip
	  BONUS     the green starting-bonus card
	  footer    PLAY DAILY (StartRun "Daily": the first run of the day is scored, later ones
	            are practice) and LEADERBOARD (the Ranks screen on its Daily tab)
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
local CHEVRON = 22 -- room for the ">" between route cards
local MONTHS = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" }

-- A cached board must describe this exact result before it can supply its rank.
function MenuDaily.RankText(board: any, day: number, score: number, elapsed: number?): string?
	if type(board) ~= "table" or board.Board ~= "Daily" or board.Day ~= day or board.Status ~= "ok" or score <= 0 or board.MyBest ~= score then
		return nil
	end
	local rank = board.MyRank
	if type(rank) ~= "number" or rank < 1 or rank == math.huge or rank % 1 ~= 0 or type(board.Rows) ~= "table" then return nil end
	if type(board.Age) ~= "number" or board.Age < 0 or board.Age + (elapsed or 0) > Config.Leaderboards.RefreshSeconds then return nil end
	for _, row in ipairs(board.Rows) do
		if row.Me == true and row.Rank == rank and row.Value == score then return string.format("Global rank: #%d.", rank) end
	end
	return nil
end

-- Stand-in colours of each arena picture (sky, ground) while / if art is missing.
local ARENA_TINT: { [string]: { Color3 } } = {
	Forest = { P.moss_400, P.moss_700 },
	Ruins = { P.amber_300, P.stone_600 },
	Swamp = { P.murk_400, P.bog_700 },
	Snow = { P.ice_100, P.snow_400 },
	Desert = { P.sand_300, P.sand_600 },
	Lava = { P.basalt_600, P.lava_700 },
}

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

local function wrappedLines(value: string, pixels: number, width: number): number
	local count = 0
	for _, line in ipairs(string.split(value, "\n")) do
		count += math.max(1, math.ceil(#line * pixels * 0.53 / math.max(1, width)))
	end
	return count
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

-- The header line: "NEW TRY IN 5H 12M · 00:00 UTC" (the countdown reads the same in every
-- time zone; the UTC reset stays as a small note).
function MenuDaily.ResetLine(): string
	return UIKit.track("New try in " .. MenuDaily.TimeLeft()) .. "  ·  00:00 UTC"
end

-- "2026-10-02" -> "OCT 02, 2026".
function MenuDaily.LongDate(iso: string): string
	local y, m, d = string.match(iso, "^(%d+)-(%d+)-(%d+)$")
	local month = m and MONTHS[tonumber(m) or 0]
	if not (y and month and d) then
		return iso
	end
	return string.format("%s %s, %s", month, d, y)
end

-- A charcoal card with a coloured hairline (route stops, curses, the bonus).
local function card(parent: Instance, name: string, edge: Color3, edgeT: number?): Frame
	local f = new("Frame", { Name = name, BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.25, BorderSizePixel = 0 }, parent)
	UIKit.corner(f, Theme.Radius.M)
	UIKit.stroke(f, edge, 1.5, edgeT or 0.35)
	return f
end

-- Name (caps, accent colour) over a wrapped effect line, right of the card's icon.
local function cardText(f: Frame, name: string, effect: string, color: Color3)
	text(f, "Label", name, { Name = "Name", Position = UDim2.fromOffset(58, 10), Size = UDim2.new(1, -68, 0, TS(15) + 4), TextColor3 = color, TextTruncate = Enum.TextTruncate.AtEnd }, 15)
	text(f, "Small", effect, {
		Name = "Effect",
		Position = UDim2.fromOffset(58, 14 + TS(15)),
		Size = UDim2.new(1, -68, 1, -(TS(15) + 20)),
		TextColor3 = C.Text,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
end

-- Height of an icon card whose effect text must fit `width` (rough: ~0.48 em a character).
local function cardHeight(effects: { string }, width: number): number
	local lines = 1
	for _, e in ipairs(effects) do
		lines = math.max(lines, math.ceil(#e * TS(14) * 0.48 / math.max(1, width - 68)))
	end
	return math.max(62, 24 + TS(15) + math.min(lines, 3) * (TS(14) + 3))
end

-- Arena picture with a painted stand-in (sky / ground bands + the arena icon).
local function arenaPicture(parent: Instance, arena: string): Frame
	local tint = ARENA_TINT[arena] or { P.slate_500, P.slate_700 }
	local pic = UIKit.ArtPicture(parent, "arenas/" .. arena, { Name = "Picture" }, function(fb: Frame)
		local sky = new("Frame", { Name = "Sky", BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1) }, fb)
		new("UIGradient", { Rotation = 90, Color = ColorSequence.new(tint[1], tint[2]) }, sky)
		UIKit.corner(sky, Theme.Radius.S)
		Icons.Draw(fb, "arena_" .. arena, { Size = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	end)
	local img = pic:FindFirstChild("Image")
	if img then
		UIKit.corner(img, Theme.Radius.S)
	end
	return pic
end

function MenuDaily.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = { Stops = {}, Chevrons = {}, CurseCards = {} }
	ui.Header = UIKit.ScreenHeader(screen, "DAILY CHALLENGE", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35 })
	ui.Panel = holder
	UIKit.padding(face, 18, 20, 18, 20)

	-- header row: calendar, date / reset, status pill, hairline
	local top = new("Frame", { Name = "Top", BackgroundTransparency = 1 }, face)
	ui.Top = top
	local well = new("Frame", { Name = "Well", BackgroundColor3 = P.slate_950, BackgroundTransparency = 0.2, Size = UDim2.fromOffset(48, 48) }, top)
	UIKit.corner(well, Theme.Radius.M)
	UIKit.stroke(well, P.gold_500, 1, 0.5)
	Icons.Draw(well, "calendar", { Size = 30, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Back = P.slate_950 })
	ui.Date = text(top, "H2", "", { Name = "Date", Position = UDim2.fromOffset(62, 0), Size = UDim2.new(1, -180, 0, TS(22) + 4) })
	ui.Reset = text(top, "Caption", "", { Name = "Reset", Position = UDim2.fromOffset(62, TS(22) + 6), Size = UDim2.new(1, -180, 0, TS(12) + 4), TextColor3 = P.gold_300 })
	ui.Pill = UIKit.StatusPill(top, "READY", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0) })
	ui.Rule = UIKit.Hairline(face)

	local body = new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	ui.Body = body

	-- hero: heading, rules line, info card
	ui.Heading = text(body, "H1", "", { Name = "Heading", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top }, 26)
	ui.Sub = text(body, "Body", "", { Name = "Sub", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = C.TextMuted })
	ui.Info = card(body, "Info", P.gold_400, 0.45)
	Icons.Draw(ui.Info, "info", { Size = 22, Position = UDim2.fromOffset(12, 12), Back = P.slate_950 })
	ui.InfoText = text(ui.Info, "Small", "", { Name = "Text", Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -54, 1, 0), TextWrapped = true, TextColor3 = C.Text }, 15)

	ui.RouteLabel = UIKit.SectionLabel(body, "Today's shared route")
	ui.CursesLabel = UIKit.SectionLabel(body, "Modifiers")
	ui.BonusLabel = UIKit.SectionLabel(body, "Starting bonus", P.moss_200)
	-- the gold multiplier chip (beside the CURSES label)
	ui.GoldChip = UIKit.IconPill(body, "coin", "")

	-- footer
	local foot = new("Frame", { Name = "Footer", BackgroundTransparency = 1 }, face)
	ui.Footer = foot
	ui.Play = UIKit.Button(foot, {
		Kind = "Primary",
		Glow = true,
		Title = "PLAY DAILY",
		TitleStyle = "Label",
		TitleSize = 18,
		Subtitle = "Scored · 1 try today",
		Icon = "play",
		IconSize = 26,
		Align = "Center",
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
		Title = "DAILY LEADERBOARD",
		Icon = "podium",
		IconSize = 22,
		Align = "Center",
		Name = "DailyBoard",
		OnClick = function()
			ctx.ShowScreen("Ranks", "Daily")
		end,
	})

	local shownDay = -1
	local rankData = nil
	local rankReceivedAt = 0
	local displayedRank: string? = nil
	local askedAt = -math.huge
	local resultKey = ""
	local function askRank()
		if not screen.Visible or os.clock() - askedAt < 3 then return end
		askedAt = os.clock()
		Remotes.Get("LeaderboardRequest"):FireServer("Daily")
	end

	local function clearDayCards()
		for _, list in ipairs({ ui.Stops, ui.Chevrons, ui.CurseCards }) do
			for _, f in ipairs(list) do
				f:Destroy()
			end
			table.clear(list)
		end
		if ui.BonusCard then
			ui.BonusCard:Destroy()
			ui.BonusCard = nil
		end
	end

	-- route stops, curses, bonus: fixed for the day
	local function buildDay(d)
		clearDayCards()
		for i = 1, ROUTE_STAGES do
			local id = d.Arenas[i]
			local boss = BossData.Get(d.Bosses[i])
			local f = card(body, "Stop" .. i, i == 1 and P.gold_400 or P.gold_500, i == 1 and 0.2 or 0.55)
			arenaPicture(f, id)
			local num = text(f, "Number", tostring(i), {
				Name = "Num",
				BackgroundColor3 = i == 1 and P.gold_400 or P.slate_900,
				BackgroundTransparency = 0.05,
				TextColor3 = i == 1 and P.gold_900 or P.gold_200,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.fromOffset(24, 24),
				ZIndex = 4,
			}, 14)
			UIKit.corner(num, 999)
			UIKit.stroke(num, P.gold_300, 1, 0.3)
			text(f, "H3", id, { Name = "Arena", TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd }, 16)
			text(f, "Small", "Boss: " .. (boss and boss.DisplayName or "?"), { Name = "Boss", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.crimson_300, TextWrapped = true }, 13)
			table.insert(ui.Stops, f)
			if i < ROUTE_STAGES then
				local chev = Icons.Draw(body, "chevronRight", { Size = 16, Color = P.gold_400 })
				table.insert(ui.Chevrons, chev)
			end
		end
		for i, id in ipairs(d.Curses) do
			local def = CurseData.Curses[id]
			local f = card(body, "Curse" .. i, P.crimson_400, 0.25)
			f.BackgroundColor3 = P.crimson_900
			f.BackgroundTransparency = 0.45
			Icons.Draw(f, def.Icon, { Size = 34, Position = UDim2.new(0, 12, 0.5, -17), Back = P.slate_950 })
			cardText(f, string.upper(def.Name), def.Short, P.crimson_300)
			table.insert(ui.CurseCards, f)
		end
		ui.GoldChip.SetText(UIKit.track(CurseData.GoldText(CurseData.GoldMult(d.Curses)) .. " gold"))
		ui.GoldChip.Frame.Visible = #d.Curses > 0
		ui.CursesLabel.Visible = #d.Curses > 0
		local bdef = CurseData.Bonuses[d.Bonus]
		local b = card(body, "Bonus", P.moss_300, 0.3)
		b.BackgroundColor3 = P.moss_900
		b.BackgroundTransparency = 0.4
		Icons.Draw(b, bdef and bdef.Icon or "gift", { Size = 34, Position = UDim2.new(0, 12, 0.5, -17), Back = P.slate_950 })
		cardText(b, string.upper(bdef and bdef.Name or d.Bonus), CurseData.BonusText(d, MenuDaily.NameOf), P.moss_200)
		ui.BonusCard = b
	end

	local function fill()
		local p = ctx.Profile()
		local day = MenuDaily.Today()
		local d = CurseData.Daily(day)
		ui.Date.Text = MenuDaily.LongDate(d.Date)
		ui.Reset.Text = MenuDaily.ResetLine()
		local used, score, best, bestDay = MenuDaily.Status(p)
		local key = tostring(day) .. ":" .. tostring(score)
		if key ~= resultKey then resultKey = key; askRank() end
		local bestLine = best > 0 and string.format("\nPersonal best: %s (%s).", CurseData.ScoreText(best), CurseData.DateText(bestDay)) or ""
		local rankLine = MenuDaily.RankText(rankData, day, score, os.clock() - rankReceivedAt)
		displayedRank = rankLine
		if used then
			UIKit.SetStatus(ui.Pill, "PRACTICE")
			ui.Heading.Text = "Practice today's challenge"
			ui.InfoText.Text = (score > 0 and ("Scored result: " .. CurseData.ScoreText(score) .. ". ") or "Today's scored attempt is used. ")
				.. "Practice runs never change your scored result. New scored try in " .. MenuDaily.TimeLeft() .. " (00:00 UTC)." .. bestLine
				.. (rankLine and ("\n" .. rankLine) or "")
		else
			UIKit.SetStatus(ui.Pill, "READY")
			ui.Heading.Text = "Your scored attempt is ready"
			ui.InfoText.Text = "One scored try today. It is used once the run starts, even if you lose or leave. "
				.. "If the run never starts (for example, the trip to the run server fails), you keep it. New try in "
				.. MenuDaily.TimeLeft() .. " (00:00 UTC)." .. bestLine
		end
		ui.Sub.Text = string.format("1. Play solo on today's shared route.\n2. Clear %d stages; more clears rank higher.\n3. Ties: faster last boss kill wins. No clears? Longer survival wins.", Config.Stages.WinMinStages)
		ui.Play.SetKind(used and "Secondary" or "Primary")
		ui.Play.SetText(used and "PRACTICE RUN" or "PLAY DAILY", used and "No leaderboard score" or "Scored · 1 try today")
		if shownDay ~= day then
			shownDay = day
			buildDay(d)
		end
		MenuDaily._layout()
	end

	-- every position is set here (the stop count and text sizes are known)
	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(620, W - 2 * M), 56)
		local topY = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local maxH = H - topY - M
		local w = math.min(W - 2 * M, maxH < 520 and 1160 or 1000) -- short phones: use the width
		local iw = w - 40 -- inside the face padding
		local narrow = iw < 640

		-- header row
		local topH = math.max(48, TS(22) + TS(12) + 12)
		place(ui.Top, 0, 0, iw, topH)
		place(ui.Rule, 0, topH + 10, iw, 1)
		local bodyY = topH + 22

		-- Short landscape screens keep the actions beside the scrolling explanation.
		local side = not narrow and maxH < 520
		local sideW = side and math.clamp(math.floor(iw * 0.3), 220, 300) or 0
		local playH = side and 64 or 70
		local boardH = Theme.Size.Button
		local footH = side and 0 or (narrow and (playH + 10 + boardH) or playH)
		ui.Info.Parent = body

		-- body content (scroll canvas coordinates)
		local bw = (side and (iw - sideW - 18) or iw) - 8 -- room for the scroll bar
		local y = 2
		local infoW, textW = bw, bw
		local headPx = TS(26)
		local headLines = wrappedLines(ui.Heading.Text, headPx, textW)
		place(ui.Heading, 0, y, textW, headLines * (headPx + 4) + 4)
		local subPx = TS(16)
		local subLines = wrappedLines(ui.Sub.Text, subPx, textW)
		place(ui.Sub, 0, y + ui.Heading.Size.Y.Offset + 4, textW, subLines * (subPx + 3) + 4)
		local heroH = ui.Heading.Size.Y.Offset + 4 + ui.Sub.Size.Y.Offset
		local infoLines = wrappedLines(ui.InfoText.Text, TS(15), infoW - 54)
		local infoH = math.max(48, infoLines * (TS(15) + 4) + 18)
		place(ui.Info, 0, y + heroH + 10, infoW, infoH)
		y += heroH + 10 + infoH + 16

		-- route: one row, or balanced rows (3 + 2) when the cards would get too small
		local labelH = TS(12) + 6
		place(ui.RouteLabel, 0, y, bw, labelH)
		y += labelH + 6
		local n = #ui.Stops
		local perRow = math.max(1, n)
		while perRow > 2 and (bw - (perRow - 1) * CHEVRON) / perRow < 152 do
			perRow -= 1
		end
		if perRow < n then
			perRow = math.ceil(n / math.ceil(n / perRow))
		end
		local sw = math.floor((bw - (perRow - 1) * CHEVRON) / perRow)
		local picH = math.clamp(math.floor(sw * 0.48), side and 44 or 52, side and 64 or 86)
		local stopH = picH + 12 + TS(16) + 2 * (TS(13) + 3) + 10
		for i, f in ipairs(ui.Stops) do
			local col = (i - 1) % perRow
			local rowI = (i - 1) // perRow
			local x = col * (sw + CHEVRON)
			local sy = y + rowI * (stopH + 10)
			place(f, x, sy, sw, stopH)
			local pic = f:FindFirstChild("Picture") :: Frame
			place(pic, 6, 6, sw - 12, picH)
			local num = f:FindFirstChild("Num") :: TextLabel
			place(num, 10, 10, 24, 24)
			local an = f:FindFirstChild("Arena") :: TextLabel
			place(an, 6, picH + 10, sw - 12, TS(16) + 4)
			local bn = f:FindFirstChild("Boss") :: TextLabel
			place(bn, 6, picH + 12 + TS(16), sw - 12, 2 * (TS(13) + 3))
			bn.TextSize = TS(13)
			local chev = ui.Chevrons[i]
			if chev then
				chev.Visible = col < perRow - 1
				chev.Position = UDim2.fromOffset(x + sw + math.floor((CHEVRON - 16) / 2), sy + 6 + math.floor(picH / 2) - 8)
			end
		end
		local routeRows = math.ceil(n / perRow)
		y += math.max(0, routeRows * stopH + (routeRows - 1) * 10) + 16

		-- curses (left) and the bonus (right); stacked when narrow
		local stacked = narrow or bw < 700
		local cursesW = stacked and bw or math.floor((bw - 20) * 0.64)
		local bonusX = stacked and 0 or (cursesW + 20)
		local bonusW = stacked and bw or (bw - cursesW - 20)
		local nc = #ui.CurseCards
		local perRowC = (nc > 0 and (cursesW - (nc - 1) * 10) / nc >= 190) and nc or 1
		local cw = math.floor((cursesW - (perRowC - 1) * 10) / perRowC)
		local curseTexts, bonusTexts = {}, {}
		for _, f in ipairs(ui.CurseCards) do
			table.insert(curseTexts, (f:FindFirstChild("Effect") :: TextLabel).Text)
		end
		if ui.BonusCard then
			table.insert(bonusTexts, (ui.BonusCard:FindFirstChild("Effect") :: TextLabel).Text)
		end
		local curseH = cardHeight(curseTexts, cw)
		local bonusH = cardHeight(bonusTexts, bonusW)
		if not stacked then
			curseH = math.max(curseH, bonusH)
			bonusH = curseH
		end
		local chipH = Theme.Size.Badge + 14
		local rowH = math.max(labelH, chipH) -- the label row holds the gold chip
		local cy = y
		if nc > 0 then
			place(ui.CursesLabel, 0, cy + math.floor((rowH - labelH) / 2), cursesW, labelH)
			ui.GoldChip.Frame.AnchorPoint = Vector2.new(1, 0)
			ui.GoldChip.Frame.Position = UDim2.fromOffset(cursesW, cy + math.floor((rowH - chipH) / 2))
			cy += rowH + 8
			for i, f in ipairs(ui.CurseCards) do
				local col = (i - 1) % perRowC
				local rowI = (i - 1) // perRowC
				place(f, col * (cw + 10), cy + rowI * (curseH + 10), cw, curseH)
			end
			local rowsC = math.ceil(nc / perRowC)
			cy += rowsC * curseH + (rowsC - 1) * 10
		end
		local by = stacked and (nc > 0 and cy + 16 or y) or y
		local labelY = stacked and by or (by + math.floor((rowH - labelH) / 2))
		place(ui.BonusLabel, bonusX, labelY, bonusW, labelH)
		local bonusTop = stacked and (by + labelH + 8) or (by + rowH + 8)
		if ui.BonusCard then
			place(ui.BonusCard, bonusX, bonusTop, bonusW, bonusH)
		end
		y = math.max(cy, bonusTop + bonusH) + 8
		body.CanvasSize = UDim2.fromOffset(0, y)

		-- panel: as tall as the content needs, the body scrolls when it cannot fit
		local sideNeed = side and (playH + 10 + boardH) or 0
		local chrome = 36 + bodyY + (side and 0 or (16 + footH))
		local h = math.min(maxH, chrome + math.max(y, sideNeed))
		local bodyH = h - chrome
		place(ui.Panel, (W - w) / 2, topY, w, h)
		place(body, 0, bodyY, side and (iw - sideW - 18) or iw, bodyH)
		body.ScrollBarThickness = y > bodyH + 1 and 4 or 0
		if side then
			place(foot, iw - sideW, bodyY, sideW, bodyH)
			place(ui.Play.Instance, 0, 0, sideW, playH)
			place(ui.Board.Instance, 0, playH + 10, sideW, boardH)
		else
			place(foot, 0, h - 36 - footH, iw, footH)
			if narrow then
				place(ui.Play.Instance, 0, 0, iw, playH)
				place(ui.Board.Instance, 0, playH + 10, iw, boardH)
			else
				local pw = math.min(400, math.floor(iw * 0.48))
				local bw2 = math.min(260, math.floor(iw * 0.3))
				local x0 = math.floor((iw - (pw + 14 + bw2)) / 2)
				place(ui.Play.Instance, x0, 0, pw, playH)
				place(ui.Board.Instance, x0 + pw + 14, math.floor((playH - boardH) / 2), bw2, boardH)
			end
		end
	end
	MenuDaily._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end
	Remotes.Get("LeaderboardData").OnClientEvent:Connect(function(data)
		if type(data) ~= "table" or data.Board ~= "Daily" or data.Day ~= MenuDaily.Today() then return end
		rankData = data
		rankReceivedAt = os.clock()
		if screen.Visible then fill() end
	end)

	local clock = 0
	return {
		Layout = layout,
		Refresh = function(_p)
			-- (OnShow fills a hidden screen when it opens; the home card reads Status() itself)
			if screen.Visible then
				fill()
			end
		end,
		OnShow = function(_p)
			shownDay = -1
			fill()
			askRank()
			UIAnim.Pop(holder, 0, 0.92)
			holder.ClipsDescendants = true
			UIAnim.Sweep(holder, 0.2, 0.8, 0.8)
			local pops = table.clone(ui.Stops)
			for _, f in ipairs(ui.CurseCards) do
				table.insert(pops, f)
			end
			if ui.BonusCard then
				table.insert(pops, ui.BonusCard)
			end
			UIAnim.Cascade(pops, 0.04, 0.85)
		end,
		Update = function(dt: number)
			clock += dt
			if clock >= 1 then
				clock = 0
				if screen.Visible then
					if os.clock() - askedAt >= 30 then askRank(); fill() end
					local _, score = MenuDaily.Status(ctx.Profile())
					if displayedRank and not MenuDaily.RankText(rankData, MenuDaily.Today(), score, os.clock() - rankReceivedAt) then fill() end
					ui.Reset.Text = MenuDaily.ResetLine()
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
