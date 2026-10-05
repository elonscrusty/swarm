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

	META boards (docs/features/META.md), only while their switch is on; NEW store names,
	the boards above are never touched:
	  Weekly        best Weekly Challenge run score of the UTC week       SwarmLB_Weekly_<week>
	                (Config.Features.WeeklyChallenge; MetaData.WeekOf)
	  TeamDuo       best Duo run score of the week, one row per team      SwarmLB_TeamDuo_<week>
	  TeamTrio      best Trio run score of the week, one row per team     SwarmLB_TeamTrio_<week>
	                (Config.Features.TeamBoard; SubmitTeam: the key is the team's sorted
	                UserIds "12_34", the value the best member's run score)

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
local MetaData = require(game:GetService("ReplicatedStorage").Shared.MetaData)

local LeaderboardService = {}

local L = Config.Leaderboards
-- Studio (tests, DEV commands) never reads or writes the live boards
local PREFIX = if RunService:IsStudio() then (L.StudioStorePrefix or (L.StorePrefix .. "Studio_")) else L.StorePrefix
local ctx

type Entry = { UserId: number, Value: number, Key: string?, Members: { number }? }
type Cache = {
	Rows: { Entry },
	Time: number, -- os.clock() of the last good read (0 = never)
	Tried: number, -- os.clock() of the last read attempt, good or failed (refresh throttle)
	Status: string,
	Loading: boolean,
	Asked: number, -- os.clock() of the last request
}
type Pending = { Board: string, Day: number, UserId: number, Key: string?, Value: number, Retries: number }

local available = false -- OrderedDataStores can be used
local stores: { [string]: OrderedDataStore } = {}
local caches: { [string]: Cache } = {}
local pending: { [string]: Pending } = {} -- key = storeName .. "|" .. userId
local lastWrite: { [string]: number } = {}
local localBoards: { [string]: { [any]: number } } = {} -- "local" mode (and recent writes); team boards use the team key
local names: { [number]: string } = {}
local submitted: { [string]: boolean } = {} -- runId .. "|" .. board .. "|" .. userId already queued
local submittedCount = 0 -- entries in `submitted` (cleared past MaxSubmitted: a long-lived lobby)
local MaxSubmitted = 4096
local flushTimer = 0
local flushing = false

local function today(): number
	return CurseData.DayOf(os.time())
end

local function thisWeek(): number
	return MetaData.WeekOf(os.time())
end

-- META boards: board id → its Config.Features switch (weekly stores, one per UTC week)
local FEATURE_BOARDS: { [string]: string } = { Weekly = "WeeklyChallenge", TeamDuo = "TeamBoard", TeamTrio = "TeamBoard" }
local TEAM_BOARDS: { [string]: boolean } = { TeamDuo = true, TeamTrio = true }
LeaderboardService.FeatureBoards = FEATURE_BOARDS

-- Store name of a board (the daily board is one store per UTC day, the META boards one
-- per UTC week: `day` is then the week number).
local function storeName(board: string, day: number?): string
	if board == "Daily" then
		return PREFIX .. "Daily_" .. tostring(day or today())
	elseif FEATURE_BOARDS[board] then
		return PREFIX .. board .. "_" .. tostring(day or thisWeek())
	end
	return PREFIX .. board
end

local function isBoard(board: any): boolean
	if type(board) ~= "string" then
		return false
	end
	local feature = FEATURE_BOARDS[board]
	if feature then
		return Config.FeatureOn(feature)
	end
	return table.find(L.Order, board) ~= nil
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

local function remember(name: string, userId: any, value: number)
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
	if not L.Enabled or not isBoard(board) or TEAM_BOARDS[board] or type(value) ~= "number" or value ~= value or value <= 0 then
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

--[[
	A team's run on a weekly team board (TeamDuo / TeamTrio): one row per team, keyed by
	the members' sorted UserIds. Every member's commit may call this; the queue keeps the
	best value, and each (run, member) counts once.
]]
function LeaderboardService.SubmitTeam(board: string, userIds: { number }, value: number, week: number?, runId: string?, fromUserId: number?)
	if not L.Enabled or not TEAM_BOARDS[board] or not isBoard(board) or type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
		return
	end
	if type(userIds) ~= "table" or #userIds < 2 or #userIds > 3 then
		return
	end
	local ids = {}
	for _, id in ipairs(userIds) do
		if type(id) ~= "number" or id ~= id or table.find(ids, id) then
			return
		end
		table.insert(ids, id)
	end
	table.sort(ids)
	local key = table.concat(ids, "_")
	if runId then
		local once = runId .. "|" .. board .. "|" .. key .. "|" .. tostring(fromUserId or 0)
		if submitted[once] then
			return
		end
		if submittedCount >= MaxSubmitted then
			table.clear(submitted)
			submittedCount = 0
		end
		submitted[once] = true
		submittedCount += 1
	end
	value = math.floor(value)
	local name = storeName(board, week)
	if not available then
		remember(name, key, value)
	end
	local pkey = name .. "|" .. key
	local p = pending[pkey]
	if p then
		p.Value = math.max(p.Value, value)
	else
		pending[pkey] = { Board = name, Day = week or thisWeek(), UserId = ids[1], Key = key, Value = value, Retries = 0 }
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
					store:UpdateAsync(p.Key or tostring(p.UserId), function(old)
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
		c = { Rows = {}, Time = 0, Tried = 0, Status = available and "loading" or "local", Loading = false, Asked = 0 }
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
	c.Tried = os.clock()
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
				elseif v and type(item.key) == "string" then
					-- a team row ("12_34"): its members
					local members = {}
					for part in string.gmatch(item.key, "%d+") do
						table.insert(members, tonumber(part) :: number)
					end
					if #members >= 2 then
						table.insert(list, { UserId = members[1], Value = v, Key = item.key, Members = members })
					end
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
			-- Time stays at the last good read (Age = how old the kept rows are); Tried
			-- keeps a failing store from being hammered: next try after RefreshSeconds
			c.Status = "error"
			c.Tried = os.clock()
			warn("[Leaderboard] read " .. name .. " failed: " .. tostring(rows))
		end
	end)
end

--[[
	Row names are display names everywhere (the YOUR BEST card shows yours too): players on
	this server from their Player, everyone else from one batched UserService lookup per
	answer (pcall'd), falling back to the username and then "Player <id>". A player's row
	used to read as their display name while they were on this server and as their username
	elsewhere (or after they left), so one person showed under two names.
]]
local looking: { [number]: boolean } = {}
local function lookupNames(ids: { number })
	if #ids == 0 then
		return
	end
	for _, id in ipairs(ids) do
		looking[id] = true
	end
	task.spawn(function()
		local ok, infos = pcall(function()
			return game:GetService("UserService"):GetUserInfosByUserIdsAsync(ids)
		end)
		if ok and type(infos) == "table" then
			for _, info in ipairs(infos) do
				local id = type(info) == "table" and tonumber(info.Id)
				local display = id and info.DisplayName
				if id and type(display) == "string" and display ~= "" then
					names[id] = display
				end
			end
		end
		for _, id in ipairs(ids) do
			if not names[id] then
				local okName, result = pcall(function()
					return Players:GetNameFromUserIdAsync(id)
				end)
				if okName and type(result) == "string" then
					names[id] = result
				end
			end
			names[id] = names[id] or ("Player " .. id) -- no answer: don't ask again every time
			looking[id] = nil
		end
	end)
end

local function nameOf(userId: number, unknown: { number }?): string
	local p = Players:GetPlayerByUserId(userId)
	if p then
		names[userId] = p.DisplayName
		return p.DisplayName
	end
	local known = names[userId]
	if known then
		return known
	end
	if unknown and not looking[userId] and not table.find(unknown, userId) then
		table.insert(unknown, userId)
	end
	return "Player " .. userId -- until the lookup answers (the next refresh shows the name)
end

--[[
	Ranks with ties: equal values share a rank and the next value skips the shared places
	(1, 2, 2, 4), so two players on Stage 5 both get the same medal instead of #1 and #2
	decided by the store's key order.
]]
function LeaderboardService.RankRows(rows: { Entry }): { number }
	local ranks = {}
	for i, e in ipairs(rows) do
		local prev = rows[i - 1]
		ranks[i] = (prev and prev.Value == e.Value) and ranks[i - 1] or i
	end
	return ranks
end

-- Rows of a board for the client: the global cache, or this server's runs ("local").
local function rowsOf(name: string): ({ Entry }, string, number)
	local c = cacheFor(name)
	if not available then
		local list: { Entry } = {}
		for uid, v in pairs(localBoards[name] or {}) do
			if type(uid) == "number" then
				table.insert(list, { UserId = uid, Value = v })
			elseif type(uid) == "string" then
				local members = {}
				for part in string.gmatch(uid, "%d+") do
					table.insert(members, tonumber(part) :: number)
				end
				if #members >= 2 then
					table.insert(list, { UserId = members[1], Value = v, Key = uid, Members = members })
				end
			end
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
	elseif board == "Weekly" then
		local W = type(data.Weekly) == "table" and data.Weekly or {}
		return W.Week == thisWeek() and (tonumber(W.Score) or 0) or 0
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
	if available and (c.Tried == 0 or os.clock() - c.Tried >= L.RefreshSeconds) then
		refresh(name)
	end
	local rows, status, age = rowsOf(name)
	local out = {}
	local myRank, myBoard = nil, nil
	local ranks = LeaderboardService.RankRows(rows)
	local unknown = {}
	for i, e in ipairs(rows) do
		local rowName = nameOf(e.UserId, unknown)
		local me = e.UserId == player.UserId
		if e.Members then
			-- a team row: every member's name, "you" when you are one of them
			local names = {}
			for _, uid in ipairs(e.Members) do
				table.insert(names, nameOf(uid, unknown))
			end
			rowName = table.concat(names, " + ")
			me = table.find(e.Members, player.UserId) ~= nil
		end
		table.insert(out, { Rank = ranks[i], UserId = e.UserId, Name = rowName, Value = e.Value, Me = me, Members = e.Members })
		if me and not myRank then
			myRank, myBoard = ranks[i], e.Value
		end
	end
	lookupNames(unknown)
	-- a better run of yours still waiting in this server's write queue
	local queued = pending[name .. "|" .. player.UserId]
	Remotes.FireClient("LeaderboardData", player, {
		Board = board,
		Day = board == "Daily" and today() or nil,
		Week = FEATURE_BOARDS[board] and thisWeek() or nil,
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
		if available and now - c.Asked < L.WatchSeconds and now - c.Tried >= L.RefreshSeconds then
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
