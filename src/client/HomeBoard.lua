--[[
	HomeBoard.lua
	The home screen's TOP SCORES panel: the cross-server High Score board ("Score",
	LeaderboardService.RunScore) so players see who to beat.
	  landscape  a slim panel on the right, under the account / PARTY row: a header, the top
	             3-5 rows (rank, name, score; ties share a rank as the server sends them)
	             and your line ("You #128 · 4,210" over "Beat #127 by 36")
	  portrait   a two-line strip under the hero caption (#1 and your line), or hidden when
	             there is no room
	A tap opens the RANKS screen on HIGH SCORE. Data comes from the same LeaderboardRequest /
	LeaderboardData path as MenuLeaderboards (the server answers from its cache and re-reads
	the DataStore at most every Config.Leaderboards.RefreshSeconds); the panel asks when the
	home screen shows and at most every ASK_SECONDS while it stays up.
	States: loading (a faint line), empty ("Be the first on the board!"), error with no rows
	(a short line), local (this server's runs, labelled). Hidden while a UIState panel owns
	the screen; it lives on the Home screen frame, so other lobby screens hide it too.
	Labels are TextScaled under a size cap (shrink to fit at any Roblox Text size).
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local UIState = require(script.Parent.UIState)
local Icons = require(script.Parent.Icons)

local HomeBoard = {}

local new = UIKit.new
local C = Theme.Color
local BOARD = "Score"
local ASK_SECONDS = 20
local MAX_ROWS = 5
local RANK_COLORS = { C.CoinDeep, C.TextFaint, C.Warning }

local fmt = UIKit.formatNumber

-- Your line for one LeaderboardData answer: (main, hook). Pure, for tests.
--   ranked      "You #128 · 4,210", "Beat #127 by 36" (points to pass the next better score)
--   #1          "You #1 · 9,000", "You hold the top spot!"
--   not ranked  "You · 4,210", "#50 needs 5,001"
--   no score    "You · no score yet", "Finish a run to get on the board"
function HomeBoard.OwnLine(d: { [string]: any }?): (string, string)
	local rows = d and type(d.Rows) == "table" and d.Rows or {}
	local myRank = d and tonumber(d.MyRank)
	local mine = d and (tonumber(d.MyBoard) or 0) or 0
	local saved = d and tonumber(d.MyBest) or 0
	if myRank and mine > 0 then
		-- the closest row scoring more than you (ties share your rank and need no passing)
		local target = nil
		for _, r in ipairs(rows) do
			if (tonumber(r.Value) or 0) > mine then
				target = r
			end
		end
		local main = "You #" .. myRank .. " · " .. fmt(mine)
		if not target then
			return main, "You hold the top spot!"
		end
		local need = (tonumber(target.Value) or 0) - mine + 1
		return main, "Beat #" .. tostring(target.Rank) .. " by " .. fmt(need)
	end
	if saved > 0 then
		local last = rows[#rows]
		local top = d and tonumber(d.Top) or 50
		if last and #rows >= top then
			return "You · " .. fmt(saved), "#" .. tostring(last.Rank) .. " needs " .. fmt((tonumber(last.Value) or 0) + 1)
		end
		return "You · " .. fmt(saved), "Not on the board yet"
	end
	return "You · no score yet", "Finish a run to get on the board"
end

-- The line shown instead of rows: nil when there are rows to show.
function HomeBoard.StateText(d: { [string]: any }?): string?
	local rows = d and type(d.Rows) == "table" and d.Rows or {}
	if #rows > 0 then
		return nil
	end
	local status = d and d.Status or "loading"
	if status == "loading" then
		return "Loading scores..."
	elseif status == "error" then
		return "Scores are resting. Back soon!"
	elseif status == "local" then
		return "No runs here yet. Be the first!"
	end
	return "Be the first on the board!"
end

-- scaled = false: a fixed size cut with "..." (player names: long names truncate, never wrap)
local function label(parent: Instance, name: string, size: number, font: Font, color: Color3, align: Enum.TextXAlignment?, scaled: boolean?): TextLabel
	local l = new("TextLabel", {
		Name = name,
		BackgroundTransparency = 1,
		Text = "",
		FontFace = font,
		TextSize = size,
		TextScaled = scaled ~= false,
		TextWrapped = false,
		TextColor3 = color,
		TextXAlignment = align or Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextStrokeTransparency = 1,
	}, parent)
	if scaled ~= false then
		new("UITextSizeConstraint", { Name = "Fit", MaxTextSize = size, MinTextSize = 8 }, l)
	end
	return l
end

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

function HomeBoard.Build(parent: Frame, onOpen: () -> ())
	local api = {}
	local data: { [string]: any }? = nil
	local askedAt = -math.huge
	local covered = false
	local wanted = false -- the layout found room for the panel

	local b = new("TextButton", { Name = "HomeBoard", Text = "", AutoButtonColor = false, BackgroundColor3 = C.Panel, BackgroundTransparency = 0, BorderSizePixel = 0, ClipsDescendants = true, Visible = false }, parent)
	UIKit.corner(b, 10)
	UIKit.stroke(b, C.PanelEdge, 2, 0)
	UIKit.Focusable(b)
	UIAnim.Button(b)
	b.Activated:Connect(function()
		UIKit.Click()
		onOpen()
	end)
	local icon = Icons.Draw(b, "trophy", { Size = 18, Back = C.Panel })
	local title = label(b, "Title", 15, Theme.Font.Title, C.Text)
	local chev = label(b, "More", 15, Theme.Font.Title, C.BlueDeep, Enum.TextXAlignment.Right)
	chev.Text = "›"
	local rule = new("Frame", { Name = "Rule", BackgroundColor3 = C.Divider, BackgroundTransparency = 0, BorderSizePixel = 0 }, b)
	local rows = {}
	for i = 1, MAX_ROWS do
		local f = new("Frame", { Name = "Row" .. i, BackgroundTransparency = 1, Visible = false }, b)
		rows[i] = {
			Frame = f,
			Rank = label(f, "Rank", 14, Theme.Font.Number, RANK_COLORS[i] or C.TextMuted),
			Name = label(f, "Name", 14, Theme.Font.BodyStrong, C.Text, nil, false),
			Value = label(f, "Value", 14, Theme.Font.Number, C.BlueDeep, Enum.TextXAlignment.Right),
		}
	end
	local stateLine = label(b, "State", 13, Theme.Font.Body, C.TextMuted, Enum.TextXAlignment.Center)
	local you = label(b, "You", 14, Theme.Font.BodyStrong, C.Text)
	local hook = label(b, "Hook", 13, Theme.Font.Label, C.BlueDeep)
	api.Button = b

	local shownRows = 0 -- rows the layout has room for
	local function fill()
		local d = data
		local list = d and type(d.Rows) == "table" and d.Rows or {}
		local isLocal = d and d.Status == "local"
		title.Text = isLocal and "TOP SCORES · HERE" or "TOP SCORES"
		local msg = HomeBoard.StateText(d)
		stateLine.Text = msg or ""
		stateLine.Visible = msg ~= nil and shownRows > 0
		for i, r in ipairs(rows) do
			local e = list[i]
			r.Frame.Visible = e ~= nil and i <= shownRows
			if e then
				local rank = tonumber(e.Rank) or i
				r.Rank.Text = "#" .. rank
				r.Rank.TextColor3 = RANK_COLORS[rank] or C.TextMuted
				r.Name.Text = tostring(e.Name or "?")
				r.Name.TextColor3 = e.Me and C.BlueDeep or C.Text
				r.Value.Text = fmt(tonumber(e.Value) or 0)
			end
		end
		local main, sub = HomeBoard.OwnLine(d)
		-- still loading: no "no score yet" guess before the answer
		local known = d ~= nil and d.Status ~= "loading"
		you.Text = known and main or ""
		hook.Text = known and sub or ""
	end

	local function sync()
		b.Visible = wanted and not covered
	end

	function api.Request(force: boolean?)
		if force or os.clock() - askedAt >= ASK_SECONDS then
			askedAt = os.clock()
			Remotes.Get("LeaderboardRequest"):FireServer(BOARD)
		end
	end

	-- Places the panel in (x, y, w, maxH). portrait = the two-line strip. Hides it when even
	-- the strip does not fit.
	local lastLayout: { any }? = nil
	function api.Layout(x: number, y: number, w: number, maxH: number, portrait: boolean)
		lastLayout = { x, y, w, maxH, portrait }
		local pad = 10
		if portrait then
			wanted = maxH >= 58 and w >= 220
			shownRows = 1
			if wanted then
				local h = 58
				place(b, x, y, w, h)
				icon.Position = UDim2.fromOffset(pad, 8)
				place(title, pad + 24, 6, 104, 20)
				local row = rows[1]
				place(row.Frame, pad + 130, 6, w - pad * 2 - 130 - 14, 20)
				place(row.Rank, 0, 0, 34, 20)
				place(row.Name, 36, 0, row.Frame.Size.X.Offset - 36 - 70, 20)
				place(row.Value, row.Frame.Size.X.Offset - 68, 0, 68, 20)
				place(stateLine, pad + 130, 6, w - pad * 2 - 130 - 14, 20)
				stateLine.TextXAlignment = Enum.TextXAlignment.Left
				place(chev, w - pad - 12, 6, 12, 20)
				rule.Visible = false
				local half = math.floor((w - pad * 2) * 0.48)
				place(you, pad, 31, half, 20)
				place(hook, pad + half + 8, 31, w - pad * 2 - half - 8, 20)
				hook.TextXAlignment = Enum.TextXAlignment.Right
			end
		else
			local headH, rowH, youH = 26, 22, 20
			local fixed = 8 + headH + 6 + youH * 2 + 10
			-- only as many rows as the board has (one line for the loading / empty text)
			local have = data and type(data.Rows) == "table" and #data.Rows or 0
			local n = math.clamp(math.floor((maxH - fixed) / rowH), 0, math.max(1, math.min(MAX_ROWS, have)))
			wanted = w >= 150 and n >= 1
			shownRows = n
			if wanted then
				local h = fixed + n * rowH
				place(b, x, y, w, h)
				icon.Position = UDim2.fromOffset(pad, 8 + 4)
				place(title, pad + 24, 8, w - pad * 2 - 24 - 16, headH - 4)
				place(chev, w - pad - 14, 8, 14, headH - 4)
				rule.Visible = true
				place(rule, pad, 8 + headH, w - pad * 2, 1)
				local ry = 8 + headH + 4
				for i, r in ipairs(rows) do
					place(r.Frame, pad, ry + (i - 1) * rowH, w - pad * 2, rowH)
					local fw = w - pad * 2
					place(r.Rank, 0, 0, 30, rowH)
					local vw = math.floor(fw * 0.36)
					place(r.Name, 32, 0, fw - 32 - vw - 4, rowH)
					place(r.Value, fw - vw, 0, vw, rowH)
				end
				place(stateLine, pad, ry, w - pad * 2, math.max(rowH, n * rowH))
				stateLine.TextXAlignment = Enum.TextXAlignment.Center
				local yy = ry + n * rowH + 4
				place(you, pad, yy, w - pad * 2, youH)
				place(hook, pad, yy + youH, w - pad * 2, youH)
				hook.TextXAlignment = Enum.TextXAlignment.Left
			end
		end
		fill()
		sync()
	end

	function api.Pop(delay: number?)
		if b.Visible then
			UIAnim.Pop(b, delay or 0, 0.85)
		end
	end

	Remotes.Get("LeaderboardData").OnClientEvent:Connect(function(d)
		if type(d) ~= "table" or d.Board ~= BOARD then
			return
		end
		-- a failed read keeps the last good rows (the server sends them too when it has any)
		if d.Status == "error" and data and type(data.Rows) == "table" and #data.Rows > 0 and (type(d.Rows) ~= "table" or #d.Rows == 0) then
			return
		end
		data = d
		if lastLayout then
			api.Layout(table.unpack(lastLayout))
		else
			fill()
		end
		-- the server is still reading: ask again shortly (once per answer)
		if d.Status == "loading" then
			task.delay(2, function()
				if parent.Visible and b.Visible then
					api.Request(true)
				end
			end)
		end
	end)
	UIState.OnOwnerChanged(function(owner: string?)
		covered = owner ~= nil
		sync()
	end)
	covered = UIState.Owner() ~= nil
	fill()
	return api
end

return HomeBoard
