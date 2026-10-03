--[[
	MenuPlaytime.lua
	The lobby home's always-visible PLAYTIME board (owner: "a playtime leaderboard on the
	main menu, not one you have to open"): the top players by total time played (server
	board "Playtime" = Stats.TimePlayed, seconds of clean runs, LeaderboardService) and your
	own rank and time.

	  full   a small panel: "PLAYTIME" header, up to five rows (medal / #n, name, time),
	         then your row ("YOU #12 · 3h 05m") when you are not among them
	  chip   one line "PLAYTIME #12 · 3h 05m" where there is no room for rows (portrait
	         phones, short landscape phones)

	It asks with the same LeaderboardRequest remote as the RANKS screen (the server caches
	every board for Config.Leaderboards.RefreshSeconds), when the home screen shows and then
	at most once a minute while it stays open. A tap opens RANKS on the PLAYTIME tab.
	LobbyScreen places it (Place) and hides it while the home screen is not showing.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Theme = require(Shared:WaitForChild("Theme"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)
local UIAnim = require(script.Parent.UIAnim)
local Icons = require(script.Parent.Icons)

local MenuPlaytime = {}

local new, text, TS = UIKit.new, UIKit.text, UIKit.TS
local C, P = Theme.Color, Theme.Palette
local player = Players.LocalPlayer

local ASK_SECONDS = 60
local ROW_H = 24
local HEAD_H = 30

-- 4h 05m / 12m / 0m
function MenuPlaytime.TimeText(seconds: number): string
	local s = math.max(0, math.floor(seconds or 0))
	local h = s // 3600
	local m = (s % 3600) // 60
	if h > 0 then
		return string.format("%dh %02dm", h, m)
	end
	return string.format("%dm", m)
end

export type Board = {
	Frame: Frame,
	-- full: rows that fit (0 = the one-line chip)
	Place: (x: number, y: number, w: number, rows: number) -> number, -- returns the height used
	Shown: (on: boolean) -> (),
	Update: (dt: number) -> (),
}

function MenuPlaytime.Build(parent: Instance, ctx: { [string]: any }): Board
	local holder, face = UIKit.Surface(parent, { Name = "Playtime", Radius = Theme.Radius.M, Transparency = 0.12, Edge = P.gold_400, EdgeTransparency = 0.45 })
	local hit = new("TextButton", { Name = "Open", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 1 }, face)
	hit.Activated:Connect(function()
		UIKit.Click()
		ctx.ShowScreen("Ranks", "Playtime")
	end)
	UIKit.padding(face, 6, 12, 6, 12)
	local icon = Icons.Draw(face, "clock", { Size = 18, Color = P.gold_300, Position = UDim2.fromOffset(0, 6) })
	local title = text(face, "Label", UIKit.track("Playtime"), { Name = "Title", Position = UDim2.fromOffset(24, 0), Size = UDim2.new(1, -24, 0, HEAD_H), TextColor3 = P.gold_300, TextTruncate = Enum.TextTruncate.AtEnd }, 13)
	local list = new("Frame", { Name = "Rows", BackgroundTransparency = 1, Position = UDim2.fromOffset(0, HEAD_H), Size = UDim2.new(1, 0, 1, -HEAD_H) }, face)
	UIKit.list(list, { Padding = UDim.new(0, 0) })

	local data: { [string]: any }? = nil
	local askedAt = -math.huge
	local visible = false
	local rowsWanted = 5
	local chip = false
	local clock = 0
	local shownKey = ""

	local function ask(force: boolean?)
		if force or os.clock() - askedAt >= ASK_SECONDS then
			askedAt = os.clock()
			Remotes.Get("LeaderboardRequest"):FireServer("Playtime")
		end
	end

	local function row(order: number, rank: string, name: string, value: string, me: boolean)
		local f = new("Frame", { Name = "Row" .. order, BackgroundTransparency = 1, LayoutOrder = order, Size = UDim2.new(1, 0, 0, ROW_H) }, list)
		local color = me and P.gold_200 or C.Text
		text(f, "Number", rank, { Name = "Rank", Size = UDim2.new(0, 34, 1, 0), TextColor3 = (order <= 3 and not me) and P.gold_300 or C.TextMuted }, 14)
		text(f, "BodyStrong", name, { Name = "Name", Position = UDim2.fromOffset(36, 0), Size = UDim2.new(1, -36 - 74, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd, TextColor3 = color }, 14)
		text(f, "Number", value, { Name = "Value", AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0, 72, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = P.gold_300 }, 14)
	end

	local function fill()
		local d = data
		local rows = d and type(d.Rows) == "table" and d.Rows or {}
		local myRank = d and tonumber(d.MyRank)
		local mine = d and tonumber(d.MyBest) or 0
		local status = d and d.Status or "loading"
		local mineText = MenuPlaytime.TimeText(mine)
		-- rebuild only when what is shown changes (no churn on repeated answers)
		local key = table.concat({ status, tostring(myRank), mineText, tostring(rowsWanted), tostring(chip), tostring(#rows) }, "|")
		for i = 1, math.min(#rows, rowsWanted) do
			key ..= "|" .. tostring(rows[i].UserId) .. ":" .. tostring(rows[i].Value)
		end
		if key == shownKey then
			return
		end
		local first = shownKey == ""
		shownKey = key
		for _, ch in ipairs(list:GetChildren()) do
			if ch:IsA("GuiObject") then
				ch:Destroy()
			end
		end
		if chip then
			-- one line: your rank and time
			local where = myRank and ("#" .. myRank .. "  ·  ") or ""
			title.Text = UIKit.track("Playtime") .. "   " .. where .. mineText
			list.Visible = false
			return
		end
		title.Text = UIKit.track(status == "local" and "Playtime · this server" or "Playtime")
		list.Visible = true
		local n = math.min(#rows, rowsWanted)
		local youShown = false
		for i = 1, n do
			local r = rows[i]
			local me = r.Me == true or r.UserId == player.UserId
			youShown = youShown or me
			row(i, "#" .. tostring(r.Rank or i), tostring(r.Name or "?") .. (me and "  (you)" or ""), MenuPlaytime.TimeText(tonumber(r.Value) or 0), me)
		end
		if n == 0 then
			local msg = status == "loading" and "Loading..." or "Play a run to get on the board!"
			text(list, "Small", msg, { Name = "Empty", LayoutOrder = 1, Size = UDim2.new(1, 0, 0, ROW_H), TextColor3 = C.TextMuted }, 13)
		end
		if not youShown and rowsWanted > 0 then
			row(99, myRank and ("#" .. myRank) or "-", "You", mineText, true)
		end
		if not first and visible then
			UIAnim.Bump(icon, 0.2)
		end
	end

	Remotes.Get("LeaderboardData").OnClientEvent:Connect(function(d)
		if type(d) ~= "table" or d.Board ~= "Playtime" then
			return
		end
		data = d
		fill()
		if d.Status == "loading" and visible then
			task.delay(2, function()
				if visible then
					ask(true)
				end
			end)
		end
	end)

	local placed = ""
	local function place(x: number, y: number, w: number, rows: number): number
		local pkey = string.format("%d|%d|%d|%d", math.floor(x + 0.5), math.floor(y + 0.5), math.floor(w + 0.5), rows)
		if pkey == placed then
			return holder.Size.Y.Offset -- relayouts are frequent: nothing changed
		end
		placed = pkey
		local wasShape = tostring(chip) .. tostring(rowsWanted)
		chip = rows <= 0
		rowsWanted = math.max(0, math.min(5, rows))
		-- (one more row for "You" when you are not in the top rows)
		local h = chip and 40 or (12 + HEAD_H + (rowsWanted + 1) * ROW_H)
		holder.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
		holder.Size = UDim2.fromOffset(math.floor(w + 0.5), h)
		icon.Position = UDim2.fromOffset(0, chip and 5 or 6)
		title.Size = UDim2.new(1, -24, 0, chip and 28 or HEAD_H)
		if wasShape ~= tostring(chip) .. tostring(rowsWanted) then
			fill() -- the shape changed (the key includes it): rebuild
		end
		return h
	end

	return {
		Frame = holder,
		Place = place,
		Shown = function(on: boolean)
			visible = on
			if on then
				ask(false)
			end
		end,
		Update = function(dt: number)
			clock += dt
			if clock >= 5 then
				clock = 0
				if visible then
					ask(false)
				end
			end
		end,
	}
end

return MenuPlaytime
