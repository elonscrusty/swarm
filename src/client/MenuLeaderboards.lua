--[[
	MenuLeaderboards.lua
	The LEADERBOARDS screen: one compact panel, only as tall as its rows need.
	  tabs      HIGH SCORE, BEST STAGE, DAILY, MOST KILLS, TOP LEVEL (narrow panels: one-word
	            titles, no icons). HIGH SCORE has a STANDARD / ENDLESS switch under its
	            title: the boards "Score" and "ScoreEndless" (Config.Endless).
	  title     the board's name between two gold rules, a subtitle and a short line on
	            what the value means
	  table     RANK / PLAYER / SCORE: a gold / silver / bronze medal for places 1-3 ("#n"
	            after), the player's round head shot (UIKit.Avatar; a neutral silhouette
	            until it loads or when it cannot), the name, the value in gold; your row is
	            outlined. Only real rows (no filler), then a quiet "N ranked players" line
	  YOUR BEST a pinned card: your rank, head shot, name and your own best
	Opening a tab asks the server (LeaderboardRequest); LeaderboardService answers with
	LeaderboardData: the top 50 rows (Rank, UserId, Name, Value, Me), your rank when you
	are in them, your own best, and a status. "loading" asks again shortly; "local" (no
	DataStores, e.g. Studio without API access) shows this server's runs with a clear
	note; "error" keeps the last rows.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local CurseData = require(Shared:WaitForChild("CurseData"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local MenuLeaderboards = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local player = Players.LocalPlayer

local BOARDS = {
	{ Id = "Score", Title = "High score", Short = "SCORE", Icon = "trophy", Heading = "Global high scores", Sub = "Best Standard run score across all servers", Explain = "Score reflects stages, bosses, kills, level and time.", Column = "Score" },
	-- not a tab: the HIGH SCORE tab's ENDLESS side
	{ Id = "ScoreEndless", Tab = "Score", Title = "High score", Short = "SCORE", Icon = "trophy", Heading = "Endless high scores", Sub = "Best Endless run score across all servers", Explain = "Same score as Standard; Endless runs go on until you fall.", Column = "Score" },
	{ Id = "BestStage", Title = "Best stage", Short = "STAGE", Icon = "portal", Heading = "Best stage", Sub = "Furthest stage reached in one run", Explain = "All time, across all servers.", Column = "Stage" },
	{ Id = "Daily", Title = "Daily", Short = "DAILY", Icon = "calendar", Heading = "Today's daily", Sub = "Today's scored Daily Challenge attempts (UTC)", Explain = "Ranked by stages cleared, then time. One scored attempt a day.", Column = "Result" },
	{ Id = "Kills", Title = "Most kills", Short = "KILLS", Icon = "stat_Kills", Heading = "Most kills", Sub = "Most enemies defeated in one run", Explain = "All time, across all servers.", Column = "Kills" },
	{ Id = "Level", Title = "Top level", Short = "LEVEL", Icon = "chevronsUp", Heading = "Highest level", Sub = "Highest level reached in one run", Explain = "Any mode, all time, across all servers.", Column = "Level" },
}

local ROW_H = 52
local ROW_GAP = 4
local RANK_W = 84
local SCORE_W = 170

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

local function boardOf(id: string)
	for _, b in ipairs(BOARDS) do
		if b.Id == id then
			return b
		end
	end
	return BOARDS[1]
end

-- A board value as text.
function MenuLeaderboards.ValueText(board: string, value: number): string
	if board == "BestStage" then
		return "Stage " .. UIKit.formatNumber(value)
	elseif board == "Level" then
		return "Lv " .. UIKit.formatNumber(value)
	elseif board == "Daily" then
		return CurseData.ScoreText(value)
	end
	return UIKit.formatNumber(value)
end

-- A board value with its unit, for the YOUR BEST card ("143 POINTS", "STAGE 5").
function MenuLeaderboards.BestText(board: string, value: number): string
	if board == "Score" or board == "ScoreEndless" then
		return UIKit.formatNumber(value) .. " POINTS"
	elseif board == "Level" then
		return "LEVEL " .. UIKit.formatNumber(value)
	elseif board == "Kills" then
		return UIKit.formatNumber(value) .. " KILLS"
	end
	return string.upper(MenuLeaderboards.ValueText(board, value))
end

function MenuLeaderboards.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = {}
	local board = "Score"
	local data: { [string]: any } = {} -- last answer per board
	local asked: { [string]: number } = {}
	local rowCount = 0

	ui.Header = UIKit.ScreenHeader(screen, "LEADERBOARDS", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06, Edge = P.gold_400, EdgeTransparency = 0.35 })
	ui.Panel = holder
	UIKit.padding(face, 16, 20, 16, 20)
	local items = {}
	for _, b in ipairs(BOARDS) do
		if not b.Tab then
			table.insert(items, { Id = b.Id, Title = b.Title, Icon = b.Icon })
		end
	end
	local scoreSide = "Score" -- the HIGH SCORE tab's side: "Score" | "ScoreEndless"
	local function ask(id: string, force: boolean?)
		if force or os.clock() - (asked[id] or -100) > 4 then
			asked[id] = os.clock()
			Remotes.Get("LeaderboardRequest"):FireServer(id)
		end
	end
	ui.Tabs = UIKit.Tabs(face, items, function(id)
		board = id == "Score" and scoreSide or id
		MenuLeaderboards._fill(true)
		ask(board)
	end)
	-- HIGH SCORE: STANDARD / ENDLESS
	ui.Side = UIKit.Tabs(face, { { Id = "Score", Title = "Standard" }, { Id = "ScoreEndless", Title = "Endless", Icon = "cycle" } }, function(id)
		scoreSide = id
		board = id
		MenuLeaderboards._fill(true)
		ask(id)
	end)
	ui.Side.Frame.Name = "ScoreSide"
	ui.Title = UIKit.TitleRule(face, "")
	ui.Sub = text(face, "Body", "", { Name = "BoardSub", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.Text })
	ui.Explain = text(face, "Small", "", { Name = "BoardCaption", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextFaint, TextWrapped = true })
	-- status note (loading / local / error)
	local noteHolder, noteFace = UIKit.Surface(face, { Name = "Note", Radius = Theme.Radius.M, Transparency = 0.2, Edge = P.gold_400, EdgeTransparency = 0.5, Shadow = false, Visible = false })
	ui.Note = noteHolder
	ui.NoteIcon = Icons.Draw(noteFace, "info", { Size = 22, Position = UDim2.new(0, 12, 0.5, -11) })
	ui.NoteText = text(noteFace, "Small", "", { Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -54, 1, 0), TextWrapped = true, TextColor3 = C.Text })

	-- table header
	local head = new("Frame", { Name = "TableHead", BackgroundTransparency = 1 }, face)
	ui.Head = head
	UIKit.SectionLabel(head, "Rank", nil, { Position = UDim2.fromOffset(14, 0), Size = UDim2.new(0, RANK_W, 1, -2) })
	UIKit.SectionLabel(head, "Player", nil, { Position = UDim2.fromOffset(14 + RANK_W, 0), Size = UDim2.new(1, -(RANK_W + SCORE_W + 28), 1, -2) })
	ui.ScoreHead = UIKit.SectionLabel(head, "Score", nil, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 0), Size = UDim2.new(0, SCORE_W, 1, -2), TextXAlignment = Enum.TextXAlignment.Right })
	UIKit.Hairline(head, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })

	local list = new("ScrollingFrame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = P.gold_500,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, face)
	UIKit.padding(list, 2, 8, 2, 2)
	UIKit.list(list, { Padding = UDim.new(0, ROW_GAP) })
	ui.List = list
	ui.Empty = text(face, "Body", "", { Name = "Empty", TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, Visible = false })
	ui.Count = text(face, "Small", "", { Name = "Count", TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = C.TextFaint })

	-- YOUR BEST: pinned personal card
	local youHolder, youFace = UIKit.Surface(face, { Name = "You", Radius = Theme.Radius.M, Transparency = 0.1, Edge = P.gold_400, EdgeTransparency = 0.15, Shadow = false })
	ui.You = youHolder
	Icons.Draw(youFace, "crown", { Size = 26, Position = UDim2.new(0, 14, 0.5, -13) })
	ui.YouCaption = UIKit.SectionLabel(youFace, "Your best", nil, { Name = "Caption", Position = UDim2.fromOffset(48, 0), Size = UDim2.new(0, 90, 1, 0) })
	ui.YouRank = text(youFace, "Number", "-", { Name = "Rank", Position = UDim2.fromOffset(140, 0), Size = UDim2.new(0, 64, 1, 0), TextColor3 = P.gold_200 }, 22)
	ui.YouAvatarSlot = new("Frame", { Name = "AvatarSlot", BackgroundTransparency = 1, Position = UDim2.new(0, 206, 0.5, -18), Size = UDim2.fromOffset(36, 36) }, youFace)
	UIKit.Avatar(ui.YouAvatarSlot, player.UserId, 36)
	ui.YouName = text(youFace, "BodyStrong", "", { Name = "Name", Position = UDim2.fromOffset(252, 0), Size = UDim2.new(0.4, -252, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
	ui.YouValue = text(youFace, "Number", "", { Name = "Value", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 0), Size = UDim2.new(0.6, -16, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_300, TextTruncate = Enum.TextTruncate.AtEnd }, 18)

	local function rowFor(r: { [string]: any }, order: number)
		local me = r.Me == true
		local f = UIKit.Panel(list, { Name = "Row" .. order, LayoutOrder = order, Size = UDim2.new(1, 0, 0, ROW_H) }, true)
		f.BackgroundColor3 = me and P.slate_800 or P.slate_950
		f.BackgroundTransparency = me and 0.05 or 0.35
		if me then
			UIKit.stroke(f, P.gold_400, 1.5, 0.1)
		end
		local rank = tonumber(r.Rank) or order
		if rank <= 3 then
			UIKit.Medal(f, rank, 40, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0) })
		else
			text(f, "Number", "#" .. rank, { Name = "Rank", Position = UDim2.fromOffset(14, 0), Size = UDim2.new(0, RANK_W - 14, 1, 0), TextColor3 = C.TextMuted }, 17)
		end
		UIKit.Avatar(f, tonumber(r.UserId), 36, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 14 + RANK_W, 0.5, 0) })
		text(f, "BodyStrong", tostring(r.Name or "?"), {
			Name = "Name",
			Position = UDim2.fromOffset(14 + RANK_W + 48, 0),
			Size = UDim2.new(1, -(14 + RANK_W + 48 + SCORE_W + 20), 1, 0),
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextColor3 = me and P.gold_200 or C.Text,
		}, 17)
		text(f, "Number", MenuLeaderboards.ValueText(board, tonumber(r.Value) or 0), {
			Name = "Value",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -16, 0, 0),
			Size = UDim2.new(0, SCORE_W, 1, 0),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = P.gold_300,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, 18)
		return f
	end

	MenuLeaderboards._fill = function(animate: boolean?)
		local b = boardOf(board)
		ui.Title.Set(string.upper(b.Heading))
		ui.Sub.Text = b.Sub
		ui.Explain.Text = b.Explain
		ui.ScoreHead.Text = UIKit.track(b.Column)
		for _, ch in ipairs(list:GetChildren()) do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		local d = data[board]
		local status = d and d.Status or "loading"
		local note = ""
		if status == "local" then
			note = "Global leaderboards need DataStores, which are off in this session (Studio: Game Settings → Security → Enable Studio Access to API Services). Showing runs on this server only."
		elseif status == "error" then
			note = "The leaderboard could not be read right now. Showing the last rows we had; it tries again in a minute."
		elseif status == "loading" then
			note = "Loading the leaderboard..."
		end
		ui.Note.Visible = note ~= ""
		ui.NoteText.Text = note
		local rows = d and type(d.Rows) == "table" and d.Rows or {}
		rowCount = #rows
		local made = {}
		for i, r in ipairs(rows) do
			local f = rowFor(r, i)
			table.insert(made, f)
			if animate and i <= 3 then
				f.ClipsDescendants = true
				UIAnim.Sweep(f, 0.25 + 0.15 * i, 0.55, 0.6)
			end
		end
		if animate then
			UIAnim.Cascade(made, 0.025, 0.88, 12)
		end
		ui.Head.Visible = #rows > 0
		ui.Empty.Visible = #rows == 0 and status ~= "loading"
		ui.Empty.Text = status == "local" and "No runs finished on this server yet. Play one!" or "Nobody is on this board yet. Be the first!"
		ui.Count.Visible = #rows > 0
		if status == "local" then
			ui.Count.Text = #rows == 1 and "1 player on this server" or (#rows .. " players on this server")
		else
			ui.Count.Text = #rows == 1 and "1 ranked player" or (UIKit.formatNumber(#rows) .. " ranked players")
		end
		-- you
		ui.YouName.Text = player.DisplayName
		local myRank = d and tonumber(d.MyRank)
		local best = d and tonumber(d.MyBest) or 0
		ui.YouRank.Text = myRank and ("#" .. myRank) or "-"
		if best > 0 then
			ui.YouValue.Text = (myRank and "" or ("Not in the top " .. tostring(d and d.Top or 50) .. " · ")) .. MenuLeaderboards.BestText(board, best)
		elseif board == "Daily" then
			ui.YouValue.Text = "No scored attempt today"
		else
			ui.YouValue.Text = "No runs yet"
		end
		MenuLeaderboards._layout()
	end

	local function layout(v: Vector2, portrait: boolean, ins: { [string]: number })
		local W, H = v.X, v.Y
		local M = UIKit.IsCompact() and Theme.Layout.MarginCompact or Theme.Layout.Margin
		local headY = math.max(ins.Top + 4, 12)
		place(ui.Header.Frame, M, headY, math.min(560, W - 2 * M), 56)
		local top = math.max(headY + 66 + (portrait and 58 or 0), portrait and 0 or 76)
		local maxH = H - top - M
		local w = math.min(W - 2 * M, 780)
		local iw = w - 40
		local narrow = iw < 660
		local short = maxH < 470 -- phones in landscape: drop the explanation line
		local tabsH = Theme.Size.TapMin + 4
		ui.Tabs.Frame.Position = UDim2.new()
		ui.Tabs.Frame.Size = UDim2.new(1, 0, 0, tabsH)
		local y = tabsH + (short and 8 or 14)
		local titleH = TS(22) + 10
		place(ui.Title.Frame, 0, y, iw, titleH)
		y += titleH
		place(ui.Sub, 0, y, iw, TS(16) + 6)
		y += TS(16) + 6
		-- the STANDARD / ENDLESS switch on the HIGH SCORE tab
		local scoreTab = boardOf(board).Id == "Score" or boardOf(board).Tab == "Score"
		ui.Side.Frame.Visible = scoreTab
		if scoreTab then
			local sideW = math.min(iw, 300)
			place(ui.Side.Frame, (iw - sideW) / 2, y + 6, sideW, 40)
			y += 50
		end
		ui.Explain.Visible = not short
		if not short then
			local lines = narrow and 2 or 1
			place(ui.Explain, 0, y, iw, lines * (TS(14) + 2) + 4)
			y += ui.Explain.Size.Y.Offset
		end
		y += short and 6 or 12
		if ui.Note.Visible then
			local noteH = TS(14) * (narrow and 5 or 2) + 22
			place(ui.Note, 0, y, iw, noteH)
			y += noteH + 10
		end
		local headH = TS(12) + 12
		if ui.Head.Visible then
			place(ui.Head, 0, y, iw, headH)
			y += headH + 6
		end
		-- rows: as many as fit, the rest scroll
		local youH = narrow and 64 or 60
		local countH = TS(14) + 8
		local tail = (rowCount > 0 and countH or 0) + 10 + youH
		local want = rowCount * (ROW_H + ROW_GAP) + 4
		local room = maxH - 32 - y - tail
		local listH = math.max(ROW_H + 8, math.min(want, room))
		if rowCount == 0 then
			listH = ui.Empty.Visible and (TS(16) * 2 + 24) or 24
		end
		place(ui.List, 0, y, iw, listH)
		place(ui.Empty, 0, y + 6, iw, TS(16) * 2 + 8)
		ui.List.ScrollBarThickness = want > listH + 1 and 4 or 0
		y += listH
		if rowCount > 0 then
			place(ui.Count, 0, y + 2, iw, countH)
			y += countH
		end
		y += 10
		place(ui.You, 0, y, iw, youH)
		y += youH
		-- the YOUR BEST card: on narrow panels the caption goes and the value moves under
		-- the name
		ui.YouCaption.Visible = not narrow
		local nameX = narrow and 154 or 252
		ui.YouRank.Position = UDim2.fromOffset(narrow and 48 or 140, 0)
		ui.YouAvatarSlot.Position = UDim2.new(0, narrow and 108 or 206, 0.5, -18)
		if narrow then
			ui.YouName.AnchorPoint = Vector2.zero
			ui.YouName.Position = UDim2.fromOffset(nameX, 6)
			ui.YouName.Size = UDim2.new(1, -nameX - 12, 0.5, -6)
			ui.YouValue.AnchorPoint = Vector2.zero
			ui.YouValue.Position = UDim2.new(0, nameX, 0.5, 0)
			ui.YouValue.Size = UDim2.new(1, -nameX - 12, 0.5, -6)
			ui.YouValue.TextXAlignment = Enum.TextXAlignment.Left
		else
			ui.YouName.Position = UDim2.fromOffset(nameX, 0)
			ui.YouName.Size = UDim2.new(0.5, -nameX + 40, 1, 0)
			ui.YouValue.AnchorPoint = Vector2.new(1, 0)
			ui.YouValue.Position = UDim2.new(1, -16, 0, 0)
			ui.YouValue.Size = UDim2.new(0.5, -56, 1, 0)
			ui.YouValue.TextXAlignment = Enum.TextXAlignment.Right
		end
		-- narrow panels: tabs without icons and with one-word titles, so all five fit
		for _, b in ipairs(BOARDS) do
			local hit = not b.Tab and ui.Tabs.Frame:FindFirstChild(string.upper(b.Title))
			local icon = hit and hit:FindFirstChild("IconHolder", true)
			local title = hit and hit:FindFirstChild("Title", true)
			if icon and icon:IsA("GuiObject") then
				icon.Visible = not narrow
			end
			if title and title:IsA("TextLabel") then
				title.Text = narrow and b.Short or string.upper(b.Title)
			end
		end
		place(ui.Panel, (W - w) / 2, top, w, math.min(maxH, y + 32))
	end
	MenuLeaderboards._layout = function()
		layout(host.VirtualSize(), host.IsPortrait(), host.Insets())
	end

	Remotes.Get("LeaderboardData").OnClientEvent:Connect(function(d)
		if type(d) ~= "table" or type(d.Board) ~= "string" then
			return
		end
		data[d.Board] = d
		if d.Board == board then
			MenuLeaderboards._fill(false)
		end
		if d.Status == "loading" and screen.Visible then
			task.delay(1.5, function()
				if screen.Visible and board == d.Board then
					ask(d.Board, true)
				end
			end)
		end
	end)

	local clock = 0
	return {
		Layout = layout,
		OnShow = function(_p, arg: string?)
			if type(arg) == "string" then
				for _, b in ipairs(BOARDS) do
					if b.Id == arg then
						board = arg
						ui.Tabs.Select(b.Tab or arg)
						if b.Tab == "Score" or arg == "Score" then
							scoreSide = arg
							ui.Side.Select(arg)
						end
					end
				end
			end
			MenuLeaderboards._fill(true)
			ask(board, true)
			UIAnim.Pop(holder, 0, 0.94)
		end,
		Update = function(dt: number)
			-- keep an open board fresh (the server caches; this is cheap)
			clock += dt
			if clock >= 30 then
				clock = 0
				if screen.Visible then
					ask(board, true)
				end
			end
		end,
	}
end

MenuLeaderboards._fill = function(_animate: boolean?) end
MenuLeaderboards._layout = function() end

return MenuLeaderboards
