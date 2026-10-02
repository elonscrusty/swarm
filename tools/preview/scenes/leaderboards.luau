-- leaderboards: the lobby LEADERBOARDS screen with a LeaderboardData answer (as
-- LeaderboardService sends it).
--   --set board=Score|BestStage|Daily|Kills   the tab (default Score, the first tab)
--   --set status=ok|local|loading|error the board's status (local = no DataStores)
--   --set rank=out                      you are not in the top 50 (your best shows)
--   --set rows=N                        N rows (default 12, 3 for local); rows=1 is you alone
local C = lib("common")
C.lobby()
C.startClient()
C.sendProfile()
C.settle(1)
local button = C.findText("^%s*RANKS%s*$", "GuiButton")
if button then
	preview.click(button)
else
	preview.warn("leaderboards scene: no RANKS button")
end
C.settle(0.5)
local board = preview.args.board or "Score"
if board ~= "Score" then
	-- the tab inside the Ranks screen (the home screen has a DAILY card too)
	local want = board == "Kills" and "MOST KILLS" or (board == "BestStage" and "BEST STAGE" or "DAILY")
	local screen = preview.findGui(function(obj)
		return obj.Name == "Ranks" and obj:IsA("Frame")
	end)[1]
	local tab = nil
	for _, g in ipairs(preview.findGui(function(obj)
		local ok, t = pcall(function()
			return obj.Text
		end)
		return ok and t == want and obj:IsA("GuiButton") and screen ~= nil and obj:IsDescendantOf(screen)
	end)) do
		tab = g
	end
	if tab then
		preview.click(tab)
	else
		preview.warn("leaderboards scene: no " .. want .. " tab")
	end
end
local CurseData = C.shared("CurseData")
local status = preview.args.status or "ok"
local names = { "Ava", "Bramblewick", "Kestrel", "Moonpetal", "Ironjaw", "Thistle", "Corvin", "Saffi", "Rook", "Elowen", "Dax", "Pip" }
local rows = {}
local out = preview.args.rank == "out"
local n = tonumber(preview.args.rows) or (status == "local" and 3 or 12)
local meAt = n < 4 and 1 or 4
for i = 1, n do
	local value
	if board == "Score" then
		value = 15400 - i * 870
	elseif board == "BestStage" then
		value = 14 - i
	elseif board == "Kills" then
		value = 4200 - i * 213
	else
		value = CurseData.DailyScore(math.max(0, 6 - math.floor(i / 2)), 420 + i * 37, 600)
	end
	local me = i == meAt and not out
	local lp = game:GetService("Players").LocalPlayer
	table.insert(rows, { Rank = i, UserId = me and lp.UserId or 1000 + i, Name = me and lp.DisplayName or names[i], Value = value, Me = me })
end
if status == "loading" then
	rows = {}
end
C.fire("LeaderboardData", {
	Board = board,
	Rows = rows,
	Status = status,
	Age = 12,
	MyRank = (not out and status ~= "loading" and #rows >= meAt) and meAt or nil,
	MyBest = board == "Score" and (out and 2100 or 11920) or board == "BestStage" and (out and 3 or 10) or (board == "Kills" and 3348 or CurseData.DailyScore(4, 568, 600)),
	Top = 50,
})
C.settle(2)
