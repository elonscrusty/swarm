--[[
	MenuLeaderboards.lua
	The LEADERBOARDS screen: four tabs (HIGH SCORE, BEST STAGE, DAILY, MOST KILLS). Opening a tab
	asks the server (LeaderboardRequest); LeaderboardService answers with LeaderboardData:
	the top 50 rows (your row highlighted), your rank when you are in them, your own best,
	and a status. "loading" asks again shortly; "local" (no DataStores, e.g. Studio without
	API access) shows this server's runs with a clear note; "error" keeps the last rows.
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
	{ Id = "Score", Title = "High score", Icon = "trophy", Caption = "Best run score, all servers · stages, bosses, kills, level, time" },
	{ Id = "BestStage", Title = "Best stage", Icon = "portal", Caption = "Furthest stage reached in a run · all time" },
	{ Id = "Daily", Title = "Daily", Icon = "calendar", Caption = "Today's scored Daily Challenge attempts (UTC)" },
	{ Id = "Kills", Title = "Most kills", Icon = "skull", Caption = "Most enemies defeated in one run · all time" },
}

local function place(obj: GuiObject, x: number, y: number, w: number, h: number)
	obj.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
	obj.Size = UDim2.fromOffset(math.floor(w + 0.5), math.floor(h + 0.5))
end

-- A board value as text.
function MenuLeaderboards.ValueText(board: string, value: number): string
	if board == "BestStage" then
		return "Stage " .. UIKit.formatNumber(value)
	elseif board == "Daily" then
		return CurseData.ScoreText(value)
	end
	return UIKit.formatNumber(value)
end

function MenuLeaderboards.Build(screen: Frame, ctx: { [string]: any })
	local host = ctx.Host
	local ui: { [string]: any } = {}
	local board = "Score"
	local data: { [string]: any } = {} -- last answer per board
	local asked: { [string]: number } = {}

	ui.Header = UIKit.ScreenHeader(screen, "LEADERBOARDS", ctx.Back)
	local holder, face = UIKit.Surface(screen, { Name = "Panel", Radius = Theme.Radius.L, Transparency = 0.06 })
	ui.Panel = holder
	UIKit.padding(face, 16, 16, 16, 16)
	local items = {}
	for _, b in ipairs(BOARDS) do
		table.insert(items, { Id = b.Id, Title = b.Title, Icon = b.Icon })
	end
	local function ask(id: string, force: boolean?)
		if force or os.clock() - (asked[id] or -100) > 4 then
			asked[id] = os.clock()
			Remotes.Get("LeaderboardRequest"):FireServer(id)
		end
	end
	ui.Tabs = UIKit.Tabs(face, items, function(id)
		board = id
		MenuLeaderboards._fill(true)
		ask(id)
	end)
	ui.Caption = text(face, "Caption", "", { Name = "BoardCaption", TextXAlignment = Enum.TextXAlignment.Center })
	-- status note (loading / local / error)
	local noteHolder, noteFace = UIKit.Surface(face, { Name = "Note", Radius = Theme.Radius.M, Transparency = 0.2, Edge = P.gold_400, EdgeTransparency = 0.5, Shadow = false, Visible = false })
	ui.Note = noteHolder
	ui.NoteIcon = Icons.Draw(noteFace, "info", { Size = 22, Position = UDim2.fromOffset(12, 10) })
	ui.NoteText = text(noteFace, "Small", "", { Position = UDim2.fromOffset(44, 0), Size = UDim2.new(1, -54, 1, 0), TextWrapped = true, TextColor3 = C.Text })
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
	UIKit.list(list, { Padding = UDim.new(0, 4) })
	ui.List = list
	ui.Empty = text(face, "Body", "", { Name = "Empty", TextXAlignment = Enum.TextXAlignment.Center, TextWrapped = true, Visible = false })
	-- you: your rank / best
	local youHolder, youFace = UIKit.Surface(face, { Name = "You", Radius = Theme.Radius.M, Transparency = 0.1, Edge = P.gold_400, EdgeTransparency = 0.15, Shadow = false })
	ui.You = youHolder
	ui.YouRank = text(youFace, "Number", "-", { Name = "Rank", Position = UDim2.fromOffset(14, 0), Size = UDim2.new(0, 70, 1, 0), TextColor3 = P.gold_200 }, 22)
	ui.YouName = text(youFace, "BodyStrong", "", { Name = "Name", Position = UDim2.fromOffset(90, 0), Size = UDim2.new(0.5, -90, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
	ui.YouValue = text(youFace, "BodyStrong", "", { Name = "Value", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 0), Size = UDim2.new(0.5, -14, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_200, TextTruncate = Enum.TextTruncate.AtEnd })

	local function rowFor(r: { [string]: any }, order: number)
		local me = r.Me == true
		local f = UIKit.Panel(list, { Name = "Row" .. order, LayoutOrder = order, Size = UDim2.new(1, 0, 0, 44) }, true)
		if me then
			UIKit.stroke(f, P.gold_400, 1.5, 0.1)
			f.BackgroundTransparency = 0.05
		end
		local rank = tonumber(r.Rank) or order
		local medal = rank <= 3 and ({ P.gold_300, P.steel_200, Color3.fromRGB(196, 132, 82) })[rank] or nil
		if medal then
			local disc = new("Frame", { Name = "Medal", BackgroundColor3 = medal, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 10, 0.5, 0), Size = UDim2.fromOffset(30, 30) }, f)
			UIKit.corner(disc, 999)
			text(disc, "Number", tostring(rank), { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = P.slate_950 }, 16)
		else
			text(f, "Number", "#" .. rank, { Position = UDim2.fromOffset(10, 0), Size = UDim2.new(0, 56, 1, 0), TextColor3 = C.TextMuted }, 16)
		end
		text(f, "BodyStrong", tostring(r.Name or "?"), { Name = "Name", Position = UDim2.fromOffset(72, 0), Size = UDim2.new(0.55, -72, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = me and P.gold_200 or C.Text })
		text(f, "BodyStrong", MenuLeaderboards.ValueText(board, tonumber(r.Value) or 0), { Name = "Value", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0), Size = UDim2.new(0.45, -12, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = me and P.gold_200 or C.Text, TextTruncate = Enum.TextTruncate.AtEnd })
		return f
	end

	MenuLeaderboards._fill = function(animate: boolean?)
		for _, b in ipairs(BOARDS) do
			if b.Id == board then
				ui.Caption.Text = UIKit.track(b.Caption)
			end
		end
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
		elseif d and (tonumber(d.Age) or 0) > 0 then
			note = ""
		end
		ui.Note.Visible = note ~= ""
		ui.NoteText.Text = note
		local rows = d and type(d.Rows) == "table" and d.Rows or {}
		for i, r in ipairs(rows) do
			local f = rowFor(r, i)
			if animate and i <= 12 then
				UIAnim.Pop(f, 0.015 * i, 0.9)
			end
		end
		ui.Empty.Visible = #rows == 0 and status ~= "loading"
		ui.Empty.Text = status == "local" and "No runs finished on this server yet. Play one!" or "Nobody is on this board yet. Be the first!"
		-- you
		ui.YouName.Text = player.DisplayName
		local myRank = d and tonumber(d.MyRank)
		local best = d and tonumber(d.MyBest) or 0
		ui.YouRank.Text = myRank and ("#" .. myRank) or "-"
		if best > 0 then
			ui.YouValue.Text = (myRank and "" or ("Not in the top " .. tostring(d and d.Top or 50) .. " · ")) .. "Your best: " .. MenuLeaderboards.ValueText(board, best)
		elseif board == "Daily" then
			ui.YouValue.Text = "No scored daily attempt today"
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
		local w = math.min(W - 2 * M, 820)
		place(ui.Panel, (W - w) / 2, top, w, H - top - M)
		local tabsH = Theme.Size.TapMin + 4
		local y = tabsH + 8
		ui.Caption.Position = UDim2.fromOffset(0, y)
		ui.Caption.Size = UDim2.new(1, 0, 0, TS(12) + 6)
		y += TS(12) + 12
		if ui.Note.Visible then
			local noteH = TS(14) * (w < 600 and 4 or 2) + 18
			ui.Note.Position = UDim2.fromOffset(0, y)
			ui.Note.Size = UDim2.new(1, 0, 0, noteH)
			y += noteH + 8
		end
		local youH = 52
		ui.List.Position = UDim2.fromOffset(0, y)
		ui.List.Size = UDim2.new(1, 0, 1, -(y + youH + 10))
		ui.Empty.Position = UDim2.fromOffset(0, y + 20)
		ui.Empty.Size = UDim2.new(1, 0, 0, TS(16) * 2 + 8)
		ui.You.Position = UDim2.new(0, 0, 1, -youH)
		ui.You.Size = UDim2.new(1, 0, 0, youH)
		ui.YouName.Size = UDim2.new(w < 600 and 0.35 or 0.45, -90, 1, 0)
		ui.YouValue.Size = UDim2.new(w < 600 and 0.65 or 0.55, -14, 1, 0)
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
						ui.Tabs.Select(arg)
					end
				end
			end
			MenuLeaderboards._fill(true)
			ask(board, true)
			MenuLeaderboards._layout()
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
