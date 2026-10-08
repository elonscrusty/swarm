--[[
	MenuDaily.lua
	The DAILY CHALLENGE screen (lobby DAILY card): today's fixed setup, the same for every
	player (CurseData.Daily(day), day = SwarmState "DailyDay", UTC), laid out as one
	dashboard panel:
	  header    Back + "Daily Challenge", then calendar, the date ("OCT 02, 2026"), "RESETS IN
	            4H 27M (00:00 UTC)" (live) and a status pill (READY / DONE)
	  rules     "Today's challenge": three icon rows (bold line + muted line), your scored
	            result / best / rank card
	  actions   PLAY DAILY (yellow) and VIEW LEADERBOARD (outlined) with the scored attempts left
	  notice    pinned: when the attempt is used, plus the "How scoring works" toggle
	  ROUTE     the first stages as numbered cards (arena picture art/arenas/<Arena> with a
	            drawn stand-in, arena name, the stage boss) joined by chevrons
	  CURSES    crimson curse cards and the real gold multiplier chip (coin gold)
	  BONUS     the green starting-bonus card
	  PLAY DAILY fires StartRun "Daily": the first run of the day is scored, later ones are
	  practice; the leaderboard button opens the Ranks screen on its Daily tab.
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
local TravelOverlay = require(script.Parent.TravelOverlay)

local MenuDaily = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette

local ROUTE_STAGES = 5 -- stages shown on the route row
local INSET, BASE = 4, 6 -- the body scroll clips: room for card outlines (sides / top) and below
local RULE_ICON = 36 -- the rule rows' icon badges
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

local function wrappedLines(value: string, pixels: number, width: number, factor: number?): number
	local count = 0
	for _, line in ipairs(string.split(value, "\n")) do
		count += math.max(1, math.ceil(#line * pixels * (factor or 0.53) / math.max(1, width)))
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

-- The header line: "RESETS IN 5H 12M (00:00 UTC)" (the countdown reads the same in every
-- time zone; the UTC reset stays as a small note).
function MenuDaily.ResetLine(): string
	return UIKit.track("Resets in " .. MenuDaily.TimeLeft()) .. "  (00:00 UTC)"
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
	local f = new("Frame", { Name = name, BackgroundColor3 = C.PanelRaised, BackgroundTransparency = 0, BorderSizePixel = 0 }, parent)
	UIKit.corner(f, Theme.Radius.M)
	UIKit.stroke(f, edge, 2, edgeT or 0)
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
	local tint = ARENA_TINT[arena] or { C.BluePale, C.Blue }
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
	-- one raised panel: header (BACK + the title plate, and the date row beside it when it
	-- fits), the scrolling rules / route, the PLAY DAILY column and the pinned notice
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0, EdgeThickness = Theme.Stroke.Medium, Depth = 4 })
	ui.Panel = holder
	ui.Pad = UIKit.padding(face, 18, 20, 18, 20)
	ui.Header = UIKit.ScreenHeader(face, "Daily Challenge", ctx.Back, true)

	-- header row: calendar, date / reset, status pill, hairline
	local top = new("Frame", { Name = "Top", BackgroundTransparency = 1 }, face)
	ui.Top = top
	ui.Well = UIKit.IconBadge(top, "calendar", Theme.IconTint.Orange, 46, { Name = "Well", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0) })
	ui.Date = text(top, "H2", "", { Name = "Date", Position = UDim2.fromOffset(62, 0), Size = UDim2.new(1, -180, 0, TS(22) + 4) })
	ui.Reset = text(top, "Caption", "", { Name = "Reset", Position = UDim2.fromOffset(62, TS(22) + 6), Size = UDim2.new(1, -180, 0, TS(12) + 4), TextColor3 = C.BlueDeep })
	ui.Pill = UIKit.StatusPill(top, "READY", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, 0, 0.5, 0) })
	ui.Rule = UIKit.Hairline(face)

	local bodyScroll = new("ScrollingFrame", {
		Name = "Body",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.Blue,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	ui.Body = bodyScroll
	-- the scroll clips: the cards sit in a content frame INSET px in from its left edge so
	-- their outlines are never cut (the layout keeps INSET at the top and BASE below)
	local body = new("Frame", { Name = "Content", BackgroundTransparency = 1, Position = UDim2.fromOffset(INSET, 0) }, bodyScroll)

	-- rules: heading, three icon rows, your result card
	ui.Heading = text(body, "H1", "Today's challenge", { Name = "Heading", TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top }, 26)
	ui.Rows = {}
	local T = Theme.IconTint
	for i, look in ipairs({ { "person", T.Blue }, { "flag", T.Red }, { "trophy", T.Gold } }) do
		local row = card(body, "Rule" .. i, C.Blue)
		UIKit.IconBadge(row, look[1], look[2], RULE_ICON, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0) })
		text(row, "Label", "", { Name = "Line", Position = UDim2.fromOffset(54, 0), TextTruncate = Enum.TextTruncate.AtEnd }, 17)
		text(row, "Small", "", { Name = "Detail", TextColor3 = C.TextMuted, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top }, 15)
		table.insert(ui.Rows, row)
	end
	ui.Info = card(body, "Info", C.Blue)
	Icons.Draw(ui.Info, "trophy", { Size = 22, Position = UDim2.fromOffset(12, 12), Back = C.PanelRaised })
	ui.InfoText = text(ui.Info, "Small", "", { Name = "Text", Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -54, 1, 0), TextWrapped = true, TextColor3 = C.Text }, 15)

	ui.RouteLabel = UIKit.SectionLabel(body, "Today's shared route")
	ui.CursesLabel = UIKit.SectionLabel(body, "Modifiers")
	ui.BonusLabel = UIKit.SectionLabel(body, "Starting bonus", C.Success)
	-- the gold multiplier chip (beside the CURSES label)
	ui.GoldChip = UIKit.IconPill(body, "coin", "")

	-- footer
	local foot = new("Frame", { Name = "Footer", BackgroundTransparency = 1 }, face)
	ui.Footer = foot
	ui.Play = UIKit.Button(foot, {
		Kind = "Primary",
		Glow = false,
		Title = "PLAY DAILY",
		TitleStyle = "H1",
		TitleSize = 24,
		Subtitle = "1 scored attempt left",
		Icon = "play",
		IconSize = 28,
		Align = "Center",
		Shrink = true,
		Depth = "Strong",
		Radius = Theme.Radius.L,
		Name = "PlayDaily",
		OnClick = function()
			local phase = Remotes.State():GetAttribute("Phase") or "Lobby"
			if phase ~= "Lobby" then
				ctx.Toast("Wait for the current run to end.")
				return
			end
			Remotes.Get("StartRun"):FireServer("Daily")
		end,
	})
	ui.Board = UIKit.Button(foot, {
		Kind = "Secondary",
		Title = "VIEW LEADERBOARD",
		Icon = "podium",
		IconSize = 22,
		Align = "Center",
		Name = "DailyBoard",
		Shrink = true,
		Depth = "Medium",
		OnClick = function()
			ctx.ShowScreen("Ranks", "Daily")
		end,
	})

	ui.Attempts = text(foot, "Small", "", { Name = "Attempts", TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, TextColor3 = C.BlueDeep }, 15)

	-- pinned notice: when the attempt is used, and the "How scoring works" toggle
	local scoringOpen = false
	local warn = card(face, "Notice", C.Blue)
	ui.Warn = warn
	Icons.Draw(warn, "info", { Size = 22, Color = C.Blue, Position = UDim2.fromOffset(12, 11), Back = C.PanelRaised })
	ui.WarnText = text(warn, "Small", "", { Name = "Text", TextWrapped = true, TextColor3 = C.Text, TextYAlignment = Enum.TextYAlignment.Top }, 14)
	ui.WarnText.Text = "Your scored attempt is used when the run starts, even if you lose or leave. If the run never starts (for example, the trip to the run server fails), you keep it."
	ui.Toggle = new("TextButton", { Name = "ScoringToggle", BackgroundTransparency = 1, Text = "", AutoButtonColor = false }, warn)
	ui.ToggleText = text(ui.Toggle, "Label", "How scoring works", { Name = "Text", TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.BlueDeep }, 14)
	ui.ToggleChevron = Icons.Draw(ui.Toggle, "chevronRight", { Size = 16, Color = C.BlueDeep, AnchorPoint = Vector2.new(1, 0.5) })
	ui.ToggleChevron.Rotation = 90
	ui.DetailsScroll = new("ScrollingFrame", {
		Name = "DetailsScroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = C.Blue,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
	}, warn)
	ui.Details = text(ui.DetailsScroll, "Small", "", { Name = "Details", TextWrapped = true, TextColor3 = C.TextMuted, TextYAlignment = Enum.TextYAlignment.Top }, 14)
	ui.Details.Text = "Only your first Daily run each UTC day is scored; later runs are practice and never change your scored result.\n"
		.. "Stages cleared come first: more cleared stages always rank higher.\n"
		.. "Tie-break: with at least one stage cleared, the faster last boss kill ranks higher.\n"
		.. "No stages cleared: the longer you survived ranks higher.\n"
		.. "The Daily leaderboard lists the scored attempt only."
	ui.Toggle.Activated:Connect(function()
		scoringOpen = not scoringOpen
		ui.DetailsScroll.Visible = scoringOpen
		ui.ToggleChevron.Rotation = scoringOpen and -90 or 90
		MenuDaily._layout()
	end)

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
			local f = card(body, "Stop" .. i, i == 1 and C.SelectedEdge or C.Blue)
			arenaPicture(f, id)
			local num = text(f, "Number", tostring(i), {
				Name = "Num",
				BackgroundColor3 = i == 1 and C.Selected or C.Blue,
				BackgroundTransparency = 0.05,
				TextColor3 = i == 1 and C.Text or C.TextOnBlue,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.fromOffset(24, 24),
				ZIndex = 4,
			}, 14)
			UIKit.corner(num, 999)
			UIKit.stroke(num, i == 1 and C.SelectedEdge or C.BlueDeep, 1.5, 0)
			text(f, "H3", id, { Name = "Arena", TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd }, 16)
			text(f, "Small", "Boss: " .. (boss and boss.DisplayName or "?"), { Name = "Boss", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextDanger, TextWrapped = true }, 13)
			table.insert(ui.Stops, f)
			if i < ROUTE_STAGES then
				local chev = Icons.Draw(body, "chevronRight", { Size = 16, Color = C.Blue })
				table.insert(ui.Chevrons, chev)
			end
		end
		for i, id in ipairs(d.Curses) do
			local def = CurseData.Curses[id]
			local f = card(body, "Curse" .. i, C.Danger)
			f.BackgroundColor3 = C.Danger:Lerp(Color3.new(1, 1, 1), 0.9)
			f.BackgroundTransparency = 0
			Icons.Draw(f, def.Icon, { Size = 34, Position = UDim2.new(0, 12, 0.5, -17), Back = C.PanelRaised })
			cardText(f, string.upper(def.Name), def.Short, C.TextDanger)
			table.insert(ui.CurseCards, f)
		end
		ui.GoldChip.SetText(UIKit.track(CurseData.GoldText(CurseData.GoldMult(d.Curses)) .. " gold"))
		ui.GoldChip.Frame.Visible = #d.Curses > 0
		ui.CursesLabel.Visible = #d.Curses > 0
		local bdef = CurseData.Bonuses[d.Bonus]
		local b = card(body, "Bonus", C.SelectedEdge)
		b.BackgroundColor3 = C.SelectedPale
		b.BackgroundTransparency = 0
		Icons.Draw(b, bdef and bdef.Icon or "gift", { Size = 34, Position = UDim2.new(0, 12, 0.5, -17), Back = C.PanelRaised })
		cardText(b, string.upper(bdef and bdef.Name or d.Bonus), CurseData.BonusText(d, MenuDaily.NameOf), C.Success)
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
		local bestLine = best > 0 and string.format("Personal best: %s (%s).", CurseData.ScoreText(best), CurseData.DateText(bestDay)) or ""
		local rankLine = MenuDaily.RankText(rankData, day, score, os.clock() - rankReceivedAt)
		displayedRank = rankLine
		local infoParts = {}
		if used then
			UIKit.SetStatus(ui.Pill, "DONE")
			table.insert(infoParts, (score > 0 and ("Scored result: " .. CurseData.ScoreText(score) .. ".") or "Today's scored attempt is used.") .. " Practice runs never change it.")
		else
			UIKit.SetStatus(ui.Pill, "READY")
		end
		if bestLine ~= "" then table.insert(infoParts, bestLine) end
		if used and rankLine then table.insert(infoParts, rankLine) end
		ui.InfoText.Text = table.concat(infoParts, "\n")
		ui.Info.Visible = #infoParts > 0
		local rules = {
			{ "Solo \u{B7} Shared route", "Play solo on today's shared route." },
			{ string.format("Clear %d stages", Config.Stages.WinMinStages), "Every stage you clear adds to your score." },
			{ "More clears rank higher", "Faster last boss kill breaks ties." },
		}
		for i, row in ipairs(ui.Rows) do
			(row:FindFirstChild("Line") :: TextLabel).Text = rules[i][1];
			(row:FindFirstChild("Detail") :: TextLabel).Text = rules[i][2]
		end
		ui.Attempts.Text = used and "Scored attempts left: 0 of 1" or "Scored attempts left: 1 of 1"
		ui.Play.SetKind(used and "Secondary" or "Primary")
		ui.Play.SetText(used and "PRACTICE RUN" or "PLAY DAILY", used and "No leaderboard score" or "1 scored attempt left")
		if shownDay ~= day then
			shownDay = day
			buildDay(d)
		end
		MenuDaily._layout()
	end

	-- every position is set here (the stop count and text sizes are known)
	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local compact = UIKit.IsCompact()
		local M = compact and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		local short = not portrait and (H < 520 or (compact and H < 640))
		local topY = headY + (portrait and 130 or (short and 6 or 46))
		-- the go-home notice owns the bottom-right corner while it shows: stay clear of it
		local reserve = TravelOverlay.NoticeReserve()
		local maxH = H - topY - M - reserve
		local w = math.min(W - 2 * M, maxH < 520 and 1160 or 1000) -- short phones: use the width
		local padV = short and 10 or (compact and 12 or 18)
		local padH = short and 12 or (compact and 14 or 20)
		ui.Pad.PaddingTop, ui.Pad.PaddingBottom = UDim.new(0, padV), UDim.new(0, padV)
		ui.Pad.PaddingLeft, ui.Pad.PaddingRight = UDim.new(0, padH), UDim.new(0, padH)
		local PV = 2 * padV -- the face padding, top + bottom
		local iw = w - 2 * padH -- inside the face padding
		local narrow = iw < 640

		-- header: BACK + the title plate; the date row sits beside it when it fits (wide
		-- screens), else under it with a hairline
		local headH = short and 50 or 52
		place(ui.Header.Frame, 0, 0, iw, headH)
		-- phones: a smaller title so the date row fits beside it
		ui.Header.Title.TextSize = TS(compact and 26 or Theme.TextSize.H1)
		local plate = ui.Header.Plate and ui.Header.Plate.Frame
		local plateW
		if plate and plate.AbsoluteSize.X > 0 and holder.AbsoluteSize.X > 0 then
			plateW = plate.AbsoluteSize.X * w / holder.AbsoluteSize.X -- screen px back to layout px
		else
			plateW = ui.Header.Title.TextSize * 0.62 * #ui.Header.Title.Text + 36
		end
		local topH = math.max(48, TS(22) + TS(12) + 12)
		local dateX = 144 + math.floor(plateW) + 18
		local textNeed = math.max(#ui.Date.Text * TS(22) * 0.62, #ui.Reset.Text * TS(12) * 0.62)
		local pillNeed = #(ui.Pill.Text or "") * TS(12) * 0.7 + 34
		-- beside the title with the calendar badge, or (phones) without it, or under the title
		local room = iw - dateX - textNeed - 16 - pillNeed
		local inline = room >= 0
		local badge = room >= 60 or not inline
		ui.Well.Visible = badge
		local tx = badge and 60 or 0
		ui.Date.Position = UDim2.fromOffset(tx, 0)
		ui.Reset.Position = UDim2.fromOffset(tx, TS(22) + 6)
		ui.Date.Size = UDim2.new(1, -(tx + pillNeed + 8), 0, TS(22) + 4)
		ui.Reset.Size = UDim2.new(1, -(tx + pillNeed + 8), 0, TS(12) + 4)
		local bodyY
		if inline then
			place(ui.Top, dateX, math.floor((headH - topH) / 2), iw - dateX, topH)
			ui.Rule.Visible = false
			bodyY = headH + 14
		else
			place(ui.Top, 0, headH + 10, iw, topH)
			ui.Rule.Visible = true
			place(ui.Rule, 0, headH + 10 + topH + 8, iw, 2)
			bodyY = headH + 10 + topH + 20
		end

		-- Short landscape screens keep the actions beside the scrolling explanation.
		local side = not narrow
		local sideW = side and math.clamp(math.floor(iw * 0.3), 220, 300) or 0
		local playH = (side and maxH < 520) and 56 or (side and 64 or 70)
		local boardH = Theme.Size.Button
		local attemptsH = TS(15) + 6
		local footH = side and 0 or (playH + 10 + boardH + 6 + attemptsH)

		-- pinned notice: the attempt rule, the scoring toggle, the expanded details
		local open = ui.DetailsScroll.Visible
		local warnW = iw
		local togW = math.ceil(#ui.ToggleText.Text * TS(14) * 0.55) + 30
		local stackToggle = iw < 560
		local warnTextW = stackToggle and (warnW - 56) or (warnW - 56 - togW - 12)
		local warnLines = wrappedLines(ui.WarnText.Text, TS(14), warnTextW, 0.42)
		local warnTextH = warnLines * (TS(14) + 3)
		local stripH = math.max(44, warnTextH + 16) + (stackToggle and 34 or 0)
		local detailLines = open and wrappedLines(ui.Details.Text, TS(14), warnW - 28, 0.42) or 0
		local detailH = open and (detailLines * (TS(14) + 3) + 8) or 0
		local avail = maxH - PV - bodyY - 12
		-- no room for the details beside a usable body (short phone screens): they take the panel
		local focus = open and (avail - stripH - 8 - 90 < detailH)
		local warnH = focus and avail or (stripH + detailH + (open and 8 or 0))
		local viewH = focus and math.max(40, avail - stripH - 8) or detailH
		bodyScroll.Visible = not focus
		foot.Visible = not focus
		place(ui.Warn, 0, 0, warnW, warnH)
		place(ui.WarnText, 44, 10, warnTextW, warnTextH)
		local togY = stackToggle and (10 + warnTextH) or math.floor((stripH - 34) / 2)
		place(ui.Toggle, stackToggle and 44 or (warnW - togW - 10), togY, togW, 34)
		place(ui.ToggleText, 0, 0, togW - 22, 34)
		ui.ToggleText.TextXAlignment = Enum.TextXAlignment.Left
		ui.ToggleChevron.Position = UDim2.new(1, 0, 0.5, 0)
		place(ui.DetailsScroll, 14, stripH + 4, warnW - 28, viewH)
		place(ui.Details, 0, 0, warnW - 28 - 6, detailH)
		ui.DetailsScroll.CanvasSize = UDim2.fromOffset(0, detailH)

		-- body content (scroll canvas coordinates)
		local bw = (side and (iw - sideW - 18) or iw) - 6 - 2 * INSET -- room for the scroll bar and the outlines
		local y = INSET
		local infoW, textW = bw, bw
		-- (the page title and the date row already say what this is: no "Today's challenge" heading)
		ui.Heading.Visible = false
		local detailW = textW - 58 - 10
		for _, row in ipairs(ui.Rows) do
			local line = row:FindFirstChild("Line") :: TextLabel
			local detail = row:FindFirstChild("Detail") :: TextLabel
			local dLines = wrappedLines(detail.Text, TS(15), detailW)
			local lineH = TS(17) + 4
			local dH = dLines * (TS(15) + 3)
			place(row, 0, y, textW, lineH + dH + 20)
			place(line, 58, 10, detailW, lineH)
			place(detail, 58, 10 + lineH, detailW, dH)
			y += row.Size.Y.Offset + 8
		end
		if ui.Info.Visible then
			local infoLines = wrappedLines(ui.InfoText.Text, TS(15), infoW - 54)
			local infoH = math.max(48, infoLines * (TS(15) + 4) + 18)
			place(ui.Info, 0, y + 2, infoW, infoH)
			y += infoH + 2
		end
		y += 16

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
		y += BASE
		body.Size = UDim2.fromOffset(bw, y)
		bodyScroll.CanvasSize = UDim2.fromOffset(0, y)

		-- panel: as tall as the content needs, the body scrolls when it cannot fit
		local sideNeed = side and (playH + 10 + boardH + 6 + attemptsH) or 0
		local chrome = PV + bodyY + warnH + 12 + (side and 0 or (16 + footH))
		local h = focus and maxH or math.min(maxH, chrome + math.max(y, sideNeed))
		local bodyH = h - chrome
		place(ui.Panel, (W - w) / 2, topY, w, h)
		place(bodyScroll, 0, bodyY, side and (iw - sideW - 18) or iw, bodyH)
		bodyScroll.ScrollBarThickness = y > bodyH + 1 and 4 or 0
		place(ui.Warn, 0, h - PV - warnH, warnW, warnH)
		if side then
			place(foot, iw - sideW, bodyY, sideW, bodyH)
			if sideNeed > bodyH then
				-- short screen: the two buttons share the column; the attempts stay in the
				-- PLAY DAILY subtitle ("1 scored attempt left")
				local pH = math.max(48, math.floor((bodyH - 8) * 0.6))
				local bH = math.max(36, bodyH - 8 - pH)
				ui.Attempts.Visible = false
				place(ui.Play.Instance, 0, 0, sideW, pH)
				place(ui.Board.Instance, 0, pH + 8, sideW, bH)
			else
				ui.Attempts.Visible = true
				place(ui.Play.Instance, 0, 0, sideW, playH)
				place(ui.Board.Instance, 0, playH + 10, sideW, boardH)
				place(ui.Attempts, 0, playH + 10 + boardH + 6, sideW, attemptsH)
			end
		else
			place(foot, 0, h - PV - warnH - 12 - footH, iw, footH)
			place(ui.Play.Instance, 0, 0, iw, playH)
			place(ui.Board.Instance, 0, playH + 10, iw, boardH)
			ui.Attempts.Visible = true
			place(ui.Attempts, 0, playH + 10 + boardH + 6, iw, attemptsH)
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
	local lastReserve = 0
	return {
		Layout = layout,
		Refresh = function(_p)
			-- (OnShow fills a hidden screen when it opens; the home card reads Status() itself)
			if screen.Visible then
				fill()
			end
		end,
		OnShow = function(_p)
			-- once the title plate has its real width, place what sits after it
			task.delay(0.1, function()
				if screen.Visible then
					MenuDaily._layout()
				end
			end)
			shownDay = -1
			scoringOpen = false
			ui.DetailsScroll.Visible = false
			ui.DetailsScroll.CanvasPosition = Vector2.new()
			ui.ToggleChevron.Rotation = 90
			fill()
			askRank()
			UIAnim.Pop(holder, 0, 0.92)
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
					local reserve = TravelOverlay.NoticeReserve()
					if reserve ~= lastReserve then
						lastReserve = reserve
						MenuDaily._layout()
					end
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
