--[[
	LeaderboardService.lua
	Global leaderboards on OrderedDataStores (Config.Leaderboards):
	  Score         best Standard run score (all time; RunScore below)  SwarmLB_Score
	  ScoreEndless  best Endless run score (same formula; Config.Endless) SwarmLB_ScoreEndless
	  BestStage     furthest stage reached in a run (all time)          SwarmLB_BestStage
	  Daily         today's scored Daily Challenge attempts              SwarmLB_Daily_<UTC day>
	                (CurseData.DailyScore: stages cleared, then time)
	  Kills         most enemies defeated in one run (all time)          SwarmLB_Kills
	  Level         highest level reached in one run (any mode)          SwarmLB_Level
	  Playtime      total seconds played in clean runs (Stats.TimePlayed) SwarmLB_Playtime
	                (shown on the lobby home screen, MenuPlaytime)
	Your own best comes from the save: Stats.BestScore / BestScoreEndless / BestStage /
	MostKills / BestLevel, Daily.Score (today). The answer also carries your entry on the
	board itself (MyBoard, when you are in the rows): the two can differ (the board keeps
	the highest value ever written and is re-read at most every RefreshSeconds; a save
	can miss a run whose save write failed while its board write went through). The client
	shows the board entry next to its rank and labels any different save value instead of
	showing two numbers as one "best" (docs/overhaul/FLOW.md). Nothing here ever lowers,
	deletes or rewrites a stored score.

	Writes (Submit, called when a run is committed): a per player / board queue keeps the
	best value; a flush every FlushSeconds writes entries whose throttle passed, with
	UpdateAsync keeping the stored max, only while GetRequestBudgetForRequestType leaves
	MinBudget in reserve; failures are retried (MaxRetries). Everything is pcall'd.

	Reads (remote LeaderboardRequest(boardId)): the top Config.Leaderboards.Top from a cache
	refreshed at most every RefreshSeconds (in the background, only for boards someone asked
	for in the last WatchSeconds); the answer (remote LeaderboardData) carries the rows,
	your rank when you are in the list, your own best from your save, and a status:
	  "ok"       global board
	  "loading"  first read still running (the client asks again)
	  "local"    DataStores are unavailable (Studio without API access): this server's
	             runs only, with a note saying so
	  "error"    the read failed; the last good rows (if any) are kept

	Names come from players on this server, else Players:GetNameFromUserIdAsync (cached,
	pcall'd); unknown names show as "Player <id>". Rows carry the UserId too (the client
	shows the player's head shot).

	Studio uses its own stores (Config.Leaderboards.StudioStorePrefix): tests never write to
	the live boards. Submit takes the run's id: one run is submitted at most once per board,
	and RunManager never submits dev-tainted runs (a DEV command was used).
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CurseData = require(game:GetService("ReplicatedStorage").Shared.CurseData)

local LeaderboardService = {}

local L = Config.Leaderboards
-- Studio (tests, DEV commands) never reads or writes the live boards
local PREFIX = if RunService:IsStudio() then (L.StudioStorePrefix or (L.StorePrefix .. "Studio_")) else L.StorePrefix
local ctx

type Entry = { UserId: number, Value: number }
type Cache = {
	Rows: { Entry },
	Time: number, -- os.clock() of the last good read (0 = never)
	Status: string,
	Loading: boolean,
	Asked: number, -- os.clock() of the last request
}
type Pending = { Board: string, Day: number, UserId: number, Value: number, Retries: number }

local available = false -- OrderedDataStores can be used
local stores: { [string]: OrderedDataStore } = {}
local caches: { [string]: Cache } = {}
local pending: { [string]: Pending } = {} -- key = storeName .. "|" .. userId
local lastWrite: { [string]: number } = {}
local localBoards: { [string]: { [number]: number } } = {} -- "local" mode (and recent writes)
local names: { [number]: string } = {}
local submitted: { [string]: boolean } = {} -- runId .. "|" .. board .. "|" .. userId already queued
local submittedCount = 0 -- entries in `submitted` (cleared past MaxSubmitted: a long-lived lobby)
local MaxSubmitted = 4096
local flushTimer = 0
local flushing = false

local function today(): number
	return CurseData.DayOf(os.time())
end

-- Store name of a board (the daily board is one store per UTC day).
local function storeName(board: string, day: number?): string
	if board == "Daily" then
		return PREFIX .. "Daily_" .. tostring(day or today())
	end
	return PREFIX .. board
end

local function isBoard(board: any): boolean
	return type(board) == "string" and table.find(L.Order, board) ~= nil
end

local function storeFor(name: string): OrderedDataStore?
	if not available then
		return nil
	end
	local s = stores[name]
	if s then
		return s
	end
	local ok, result = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	if ok and result then
		stores[name] = result
		return result
	end
	return nil
end

local function budget(kind: Enum.DataStoreRequestType): number
	local ok, n = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(kind)
	end)
	return ok and tonumber(n) or 0
end

local function remember(name: string, userId: number, value: number)
	local board = localBoards[name]
	if not board then
		board = {}
		localBoards[name] = board
	end
	board[userId] = math.max(board[userId] or 0, value)
end

------------------------------------------------------------------------------------------
-- Writes
------------------------------------------------------------------------------------------

--[[
	Queues a player's value for a board (kept when it beats what is queued). day: the daily
	board's UTC day (the attempt's day, so a run crossing midnight scores on its own day).
	runId: the run's id (RunManager); a second submission for the same run and board is
	ignored.
]]
function LeaderboardService.Submit(player: Player, board: string, value: number, day: number?, runId: string?)
	if not L.Enabled or not isBoard(board) or type(value) ~= "number" or value ~= value or value <= 0 then
		return
	end
	if runId then
		local once = runId .. "|" .. board .. "|" .. player.UserId
		if submitted[once] then
			return
		end
		-- a run is committed once (RunManager), so this guard only matters within one
		-- commit: forgetting old runs keeps a server that runs for days from growing
		if submittedCount >= MaxSubmitted then
			table.clear(submitted)
			submittedCount = 0
		end
		submitted[once] = true
		submittedCount += 1
	end
	value = math.floor(value)
	local name = storeName(board, day)
	if not available then
		remember(name, player.UserId, value) -- "local" rows (no DataStores) only
	end
	local key = name .. "|" .. player.UserId
	local p = pending[key]
	if p then
		p.Value = math.max(p.Value, value)
	else
		pending[key] = { Board = name, Day = day or today(), UserId = player.UserId, Value = value, Retries = 0 }
	end
end

local function flush()
	if not available then
		table.clear(pending)
		return
	end
	local now = os.clock()
	-- throttle stamps older than the throttle no longer matter: a lobby that runs for days
	-- does not keep one per player and board forever
	for key, at in pairs(lastWrite) do
		if now - at >= L.WriteThrottleSeconds and not pending[key] then
			lastWrite[key] = nil
		end
	end
	local keys = {}
	for key in pairs(pending) do
		table.insert(keys, key)
	end
	for _, key in ipairs(keys) do
		local p = pending[key]
		if p and now - (lastWrite[key] or -math.huge) >= L.WriteThrottleSeconds then
			if budget(Enum.DataStoreRequestType.SetIncrementSortedAsync) <= L.MinBudget then
				return -- out of budget: the rest waits for the next flush
			end
			local store = storeFor(p.Board)
			pending[key] = nil
			lastWrite[key] = now
			if store then
				local value = p.Value
				local ok, err = pcall(function()
					store:UpdateAsync(tostring(p.UserId), function(old)
						local before = tonumber(old) or 0
						if value <= before then
							return nil -- keep the better stored value (no write)
						end
						return value
					end)
				end)
				if not ok then
					p.Retries += 1
					if p.Retries <= L.MaxRetries then
						local again = pending[key]
						if again then
							again.Value = math.max(again.Value, p.Value)
						else
							pending[key] = p
						end
					else
						warn("[Leaderboard] giving up on " .. key .. ": " .. tostring(err))
					end
				end
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Reads
------------------------------------------------------------------------------------------

local function cacheFor(name: string): Cache
	local c = caches[name]
	if not c then
		c = { Rows = {}, Time = 0, Status = available and "loading" or "local", Loading = false, Asked = 0 }
		caches[name] = c
	end
	return c
end

local function refresh(name: string)
	local c = cacheFor(name)
	if c.Loading or not available then
		return
	end
	if budget(Enum.DataStoreRequestType.GetSortedAsync) <= L.MinBudget then
		return
	end
	c.Loading = true
	task.spawn(function()
		local store = storeFor(name)
		local ok, rows = pcall(function()
			local list: { Entry } = {}
			if not store then
				error("no store")
			end
			local pages = (store :: OrderedDataStore):GetSortedAsync(false, L.Top)
			for _, item in ipairs(pages:GetCurrentPage()) do
				local uid = tonumber(item.key)
				local v = tonumber(item.value)
				if uid and v then
					table.insert(list, { UserId = uid, Value = v })
				end
			end
			return list
		end)
		c.Loading = false
		if ok then
			c.Rows = rows
			c.Time = os.clock()
			c.Status = "ok"
		else
			c.Status = "error"
			c.Time = os.clock() -- don't hammer a failing store; try again after RefreshSeconds
			warn("[Leaderboard] read " .. name .. " failed: " .. tostring(rows))
		end
	end)
end

local function nameOf(userId: number): string
	local p = Players:GetPlayerByUserId(userId)
	if p then
		names[userId] = p.DisplayName
		return p.DisplayName
	end
	local known = names[userId]
	if known then
		return known
	end
	names[userId] = "Player " .. userId -- until the lookup below answers
	task.spawn(function()
		local ok, result = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		if ok and type(result) == "string" then
			names[userId] = result
		end
	end)
	return names[userId]
end

-- Rows of a board for the client: the global cache, or this server's runs ("local").
local function rowsOf(name: string): ({ Entry }, string, number)
	local c = cacheFor(name)
	if not available then
		local list: { Entry } = {}
		for uid, v in pairs(localBoards[name] or {}) do
			table.insert(list, { UserId = uid, Value = v })
		end
		table.sort(list, function(a, b)
			return a.Value > b.Value
		end)
		while #list > L.Top do
			table.remove(list)
		end
		return list, "local", 0
	end
	if c.Time == 0 then
		return c.Rows, c.Loading and "loading" or c.Status, 0
	end
	return c.Rows, c.Status, math.floor(os.clock() - c.Time)
end

--[[
	The score of one run (Config.Leaderboards.Score): computed here from what the server
	counted itself (RunManager's run record), so a client can never send a score. run =
	{ Cleared, Bosses, Level, Kills, Seconds }.
]]
function LeaderboardService.RunScore(run: { [string]: number }): number
	local S = L.Score
	local score = S.Stage * math.max(0, run.Cleared or 0)
		+ S.Boss * math.max(0, run.Bosses or 0)
		+ S.Level * math.max(0, (run.Level or 1) - 1)
		+ S.Kill * math.max(0, run.Kills or 0)
		+ S.Second * math.max(0, math.floor(run.Seconds or 0))
	return math.floor(score)
end

-- The player's own best for a board, from the save.
local function ownBest(player: Player, board: string): number
	local data = ctx.DataService.GetData(player)
	if not data then
		return 0
	end
	if board == "Score" then
		return data.Stats.BestScore or 0
	elseif board == "ScoreEndless" then
		return data.Stats.BestScoreEndless or 0
	elseif board == "Level" then
		return data.Stats.BestLevel or 0
	elseif board == "BestStage" then
		return data.Stats.BestStage or 0
	elseif board == "Kills" then
		return data.Stats.MostKills or 0
	elseif board == "Playtime" then
		return data.Stats.TimePlayed or 0
	elseif board == "Daily" then
		local D = data.Daily or {}
		return D.Day == today() and (D.Score or 0) or 0
	end
	return 0
end

local function onRequest(player: Player, board: any)
	if not isBoard(board) then
		return
	end
	local name = storeName(board)
	local c = cacheFor(name)
	c.Asked = os.clock()
	if available and (c.Time == 0 or os.clock() - c.Time >= L.RefreshSeconds) then
		refresh(name)
	end
	local rows, status, age = rowsOf(name)
	local out = {}
	local myRank, myBoard = nil, nil
	for i, e in ipairs(rows) do
		table.insert(out, { Rank = i, UserId = e.UserId, Name = nameOf(e.UserId), Value = e.Value, Me = e.UserId == player.UserId })
		if e.UserId == player.UserId then
			myRank, myBoard = i, e.Value
		end
	end
	-- a better run of yours still waiting in this server's write queue
	local queued = pending[name .. "|" .. player.UserId]
	Remotes.FireClient("LeaderboardData", player, {
		Board = board,
		Day = board == "Daily" and today() or nil,
		Rows = out,
		Status = status,
		Age = age,
		MyRank = myRank,
		MyBoard = myBoard, -- your value in Rows (the ranked entry), nil when not in them
		MyBest = ownBest(player, board), -- your save's best (all your recorded runs)
		MyQueued = queued and queued.Value or nil, -- written to the board shortly
		Top = L.Top,
	})
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function LeaderboardService.IsAvailable(): boolean
	return available
end

function LeaderboardService.Step(dt: number)
	if not L.Enabled then
		return
	end
	flushTimer += dt
	if flushTimer < L.FlushSeconds then
		return
	end
	flushTimer = 0
	-- the writes yield: never inside the server's frame loop
	if not flushing and next(pending) ~= nil then
		flushing = true
		task.spawn(function()
			local ok, err = pcall(flush)
			flushing = false
			if not ok then
				warn("[Leaderboard] flush: " .. tostring(err))
			end
		end)
	end
	-- keep watched boards fresh in the background
	local now = os.clock()
	for name, c in pairs(caches) do
		if available and now - c.Asked < L.WatchSeconds and now - c.Time >= L.RefreshSeconds then
			refresh(name)
		end
	end
end

function LeaderboardService.Init(c)
	ctx = c
end

function LeaderboardService.Start()
	-- the same test DataService made: no DataStores (Studio without API access) = local
	available = L.Enabled and not ctx.DataService.IsMemoryOnly()
	if available then
		local ok = pcall(function()
			return DataStoreService:GetOrderedDataStore(storeName("BestStage"))
		end)
		available = ok
	end
	Remotes.Listen("LeaderboardRequest", onRequest, 3)
	game:BindToClose(function()
		-- last chance for queued writes (ignores the throttle, keeps the budget check)
		if available then
			table.clear(lastWrite)
			pcall(flush)
		end
	end)
end

return LeaderboardService
