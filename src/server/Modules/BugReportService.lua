--[[
	BugReportService.lua
	Player bug reports and the DEV inbox (shared rules: BugReportData).

	Reports (remote BugReport({ Category, Text, Client })):
	  1. arguments are checked and cleaned (BugReportData.CleanText / CleanClientContext);
	  2. one report at a time per player, a per-server cooldown, then a per-player quota
	     record in the DataStore ("Q_<userId>": day, count, last time) enforces
	     BugReportData.CooldownSeconds and PerDay across servers;
	  3. the text goes through TextService:FilterStringAsync +
	     GetNonChatStringForBroadcastAsync. If filtering fails the report is rejected and
	     nothing is stored: raw player text is never saved or shown;
	  4. the record (filtered text, the server's own context, the client's cleaned claims
	     kept apart under "Client") is saved under "<unix ms>_<userId>", and indexed in an
	     OrderedDataStore (value = unix ms) for newest-first paging.
	  The player gets BugReportResult { Ok, Message }: a failure says the report could not
	  be saved, never a fake success. Without DataStores (Studio without API access) every
	  report fails honestly.

	Inbox (remote BugInbox("Page", cursor?) | ("SetStatus", id, status)):
	  only for players that pass canViewInbox (server-side DevAllowlist UserIds, or the dev
	  rule: Studio / the creator with Config.Dev.ShowInLiveGame). Everyone else is ignored.
	  Answers come back on BugInboxData. Player attribute "BugInbox" = true tells the client
	  to show the inbox button; it grants nothing by itself.

	BugReportPlus (Config.Features.BugReportPlus, shared rules BugSnapshotData,
	docs/next/BUG_REPORT_PLUS.md): the report may carry a client Snapshot; it is cleaned
	field by field (known ids, fixed name lists, clamped numbers), its log lines have player
	names removed and go through the text filter (dropped when the filter fails), and it is
	stored as record.Snapshot next to the server's own build (record.ServerBuild) and wave.
	Reports are limited to BugSnapshotData.HourLimit per rolling hour (this server's memory
	plus the quota record "Recent" list, so all servers). The inbox pages hold the latest
	BugSnapshotData.InboxRows rows with their snapshots. Off: everything works as before.

	Stores are "SwarmBugReports_v1" / "SwarmBugIndex_v1", with "_Studio" appended in Studio.
	Every DataStore and filter call is pcall'd; there is no external HTTP and no webhook.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local B = require(Shared.BugReportData)
local S = require(Shared.BugSnapshotData)
local DevAccess = require(script.Parent.DevAccess)

local BugReportService = {}

local ctx
local reports: DataStore? = nil
local index: OrderedDataStore? = nil

local busy: { [Player]: boolean } = {}
local lastSent: { [number]: number } = {} -- userId → os.clock() of the last saved report
local lastTry: { [number]: number } = {} -- userId → os.clock() of the last attempt (any result)
local cache: { [string]: { [string]: any } } = {} -- report id → record (inbox reads)
local cacheCount = 0
local sentTimes: { [number]: { number } } = {} -- userId → os.time() of saved reports (BugReportPlus)

local function pageSize(): number
	return S.On() and S.InboxRows or B.PageSize
end

------------------------------------------------------------------------------------------
-- Access
------------------------------------------------------------------------------------------

function BugReportService.CanViewInbox(player: Player): boolean
	return DevAccess.IsDev(player)
end

------------------------------------------------------------------------------------------
-- DataStore helpers
------------------------------------------------------------------------------------------

local function storeName(base: string): string
	return RunService:IsStudio() and (base .. B.StudioSuffix) or base
end

local function available(): boolean
	return reports ~= nil and index ~= nil
end

local function budget(kind: Enum.DataStoreRequestType): number
	local ok, n = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(kind)
	end)
	return ok and n or 0
end

local function remember(id: string, record: { [string]: any })
	if not cache[id] then
		cacheCount += 1
		if cacheCount > 400 then
			cache = {}
			cacheCount = 1
		end
	end
	cache[id] = record
end

------------------------------------------------------------------------------------------
-- Context the server knows itself
------------------------------------------------------------------------------------------

local function serverContext(player: Player): { [string]: any }
	local state = Remotes.State()
	local rm = ctx.RunManager
	local rp = rm and rm.GetRunPlayer(player)
	local inRun = rp ~= nil and rm.IsParticipant(player) and player:GetAttribute("InRun") == true
	local data = ctx.DataService and ctx.DataService.GetData(player)
	local c: { [string]: any } = {
		InRun = inRun,
		Mode = state:GetAttribute("Mode"),
		Phase = state:GetAttribute("Phase"),
		Version = Config.Version,
		PlaceVersion = game.PlaceVersion,
		Players = #Players:GetPlayers(),
		AccountLevel = player:GetAttribute("AccountLevel"),
	}
	if inRun then
		c.Stage = state:GetAttribute("Stage")
		c.Arena = state:GetAttribute("Arena")
		c.Character = rp.CharacterId
		c.Level = player:GetAttribute("Level")
		c.RunTime = math.floor(rm.GetRunTime())
		if S.On() then
			c.Wave = state:GetAttribute("Wave")
		end
	elseif data then
		c.Arena = data.SelectedArena
		c.Character = data.SelectedCharacter
	end
	-- only plain values go into the record
	for k, v in pairs(c) do
		local t = type(v)
		if t ~= "string" and t ~= "number" and t ~= "boolean" then
			c[k] = nil
		end
	end
	return c
end

------------------------------------------------------------------------------------------
-- Reports
------------------------------------------------------------------------------------------

local function reply(player: Player, ok: boolean, message: string)
	if player.Parent then
		Remotes.FireClient("BugReportResult", player, { Ok = ok, Message = message })
	end
end

-- Filtered for everyone to read; nil when the filter could not run.
local function filter(text: string, userId: number): string?
	local ok, result = pcall(function()
		local r = TextService:FilterStringAsync(text, userId, Enum.TextFilterContext.PublicChat)
		return r:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" then
		return result
	end
	warn("[BugReportService] text filter failed: " .. tostring(result))
	return nil
end

-- Reserves one report in the player's quota (all servers). Returns ok, reason and the
-- previous Last time (for refundQuota).
local function reserveQuota(userId: number): (boolean, string?, number?)
	local store = reports :: DataStore
	local now = os.time()
	local day = math.floor(now / 86400)
	local reason: string? = nil
	local prevLast = 0
	local ok, err = pcall(function()
		store:UpdateAsync("Q_" .. userId, function(old)
			reason = nil
			prevLast = type(old) == "table" and old.Day == day and tonumber(old.Last) or 0
			local q = type(old) == "table" and old or {}
			if q.Day ~= day then
				q = { Day = day, Count = 0, Last = 0, Recent = q.Recent }
			end
			local recent: { number }? = nil
			if S.On() then
				local fits, kept = S.HourCheck(q.Recent, now)
				if not fits then
					reason = string.format("You've sent %d reports this hour. Thanks! Try again later.", S.HourLimit)
					return nil
				end
				recent = kept
			end
			if (tonumber(q.Count) or 0) >= B.PerDay then
				reason = string.format("You've sent %d reports today. Thanks! Try again tomorrow.", B.PerDay)
				return nil
			end
			if now - (tonumber(q.Last) or 0) < B.CooldownSeconds then
				reason = "Please wait a minute between reports."
				return nil
			end
			q.Count = (tonumber(q.Count) or 0) + 1
			q.Last = now
			if recent then
				table.insert(recent, now)
				q.Recent = recent
			end
			return q
		end)
	end)
	if not ok then
		warn("[BugReportService] quota update failed: " .. tostring(err))
		return false, "Report could not be saved. Please try again later.", nil
	end
	if reason then
		return false, reason, nil
	end
	return true, nil, prevLast
end

-- Gives the reserved slot back when the report could not be saved.
local function refundQuota(userId: number, prevLast: number)
	local day = math.floor(os.time() / 86400)
	local ok, err = pcall(function()
		(reports :: DataStore):UpdateAsync("Q_" .. userId, function(old)
			if type(old) ~= "table" or old.Day ~= day then
				return nil
			end
			old.Count = math.max(0, (tonumber(old.Count) or 0) - 1)
			old.Last = prevLast
			if type(old.Recent) == "table" and #old.Recent > 0 then
				table.remove(old.Recent, #old.Recent)
			end
			return old
		end)
	end)
	if not ok then
		warn("[BugReportService] quota refund failed: " .. tostring(err))
	end
end

-- BugReportPlus: the client's snapshot, cleaned, with log lines name-scrubbed and filtered.
local function buildSnapshot(player: Player, raw: any): { [string]: any }
	local snap = S.CleanSnapshot(raw)
	local logs = snap.Logs
	if #logs > 0 then
		local names = {}
		for _, p in ipairs(Players:GetPlayers()) do
			table.insert(names, p.Name)
			table.insert(names, p.DisplayName)
		end
		local texts = {}
		for i, e in ipairs(logs) do
			texts[i] = S.RedactNames(e.Text, names)
		end
		local filtered = filter(table.concat(texts, "\n"), player.UserId)
		local lines = filtered and string.split(filtered, "\n") or {}
		if filtered and #lines == #logs then
			for i, e in ipairs(logs) do
				e.Text = S.CleanLogText(lines[i]) or "?"
			end
		else
			snap.Logs = {}
			snap.LogsDropped = true
		end
	end
	return snap
end

local function submit(player: Player, payload: any)
	if type(payload) ~= "table" or busy[player] then
		return
	end
	if not B.IsCategory(payload.Category) then
		reply(player, false, "Pick a category first.")
		return
	end
	local text, why = B.CleanText(payload.Text)
	if not text then
		reply(player, false, why or "Write what happened first.")
		return
	end
	local userId = player.UserId
	local last = lastSent[userId]
	if last and os.clock() - last < B.CooldownSeconds then
		reply(player, false, "Please wait a minute between reports.")
		return
	end
	if S.On() then
		local fits = S.HourCheck(sentTimes[userId], os.time())
		if not fits then
			reply(player, false, string.format("You've sent %d reports this hour. Thanks! Try again later.", S.HourLimit))
			return
		end
	end
	local tried = lastTry[userId]
	if tried and os.clock() - tried < 5 then
		reply(player, false, "One moment, then try again.")
		return
	end
	if not available() then
		reply(player, false, "Report could not be saved: saving is offline on this server.")
		return
	end
	if budget(Enum.DataStoreRequestType.UpdateAsync) < 2 or budget(Enum.DataStoreRequestType.SetIncrementSortedAsync) < 1 then
		reply(player, false, "Report could not be saved: the server is busy. Try again in a minute.")
		return
	end

	busy[player] = true
	lastTry[userId] = os.clock()
	local ok, err = pcall(function()
		local filtered = filter(text, userId)
		if not filtered then
			reply(player, false, "Report could not be checked by the text filter, so it wasn't saved. Try again soon.")
			return
		end
		local quotaOk, reason, prevLast = reserveQuota(userId)
		if not quotaOk then
			reply(player, false, reason or "Report could not be saved.")
			return
		end
		local ms = DateTime.now().UnixTimestampMillis
		local id = string.format("%d_%d", ms, userId)
		local record = {
			Id = id,
			Time = os.time(),
			UserId = userId,
			Name = player.Name,
			Category = payload.Category,
			Text = filtered,
			Status = "New",
			Server = serverContext(player),
			Client = B.CleanClientContext(payload.Client),
			JobId = game.JobId,
		}
		if S.On() then
			record.Snapshot = buildSnapshot(player, payload.Snapshot)
			local rm = ctx.RunManager
			local rp = rm and rm.GetRunPlayer(player)
			if rp and rm.IsParticipant(player) then
				record.ServerBuild = S.ServerBuild(rp)
			end
		end
		local saved = pcall(function()
			(reports :: DataStore):SetAsync(id, record, { userId })
		end)
		local indexed = saved and pcall(function()
			(index :: OrderedDataStore):SetAsync(id, ms)
		end)
		if not (saved and indexed) then
			if saved then
				pcall(function()
					(reports :: DataStore):RemoveAsync(id)
				end)
			end
			refundQuota(userId, prevLast or 0)
			warn("[BugReportService] could not save report " .. id)
			reply(player, false, "Report could not be saved. Please try again later.")
			return
		end
		lastSent[userId] = os.clock()
		if S.On() then
			local _, kept = S.HourCheck(sentTimes[userId], os.time())
			table.insert(kept, os.time())
			sentTimes[userId] = kept
		end
		remember(id, record)
		reply(player, true, "Thanks! Your report was sent to the developer.")
	end)
	busy[player] = nil
	if not ok then
		warn("[BugReportService] submit error: " .. tostring(err))
		reply(player, false, "Report could not be saved. Please try again later.")
	end
end

------------------------------------------------------------------------------------------
-- Inbox (DEV only)
------------------------------------------------------------------------------------------

type Cursor = { V: number, K: { string } }

local function cleanCursor(c: any): Cursor?
	if type(c) ~= "table" or type(c.V) ~= "number" or c.V ~= c.V or c.V < 0 or c.V > 1e15 then
		return nil
	end
	local keys = {}
	if type(c.K) == "table" then
		for i = 1, math.min(#c.K, pageSize()) do
			if B.IsReportId(c.K[i]) then
				table.insert(keys, c.K[i])
			end
		end
	end
	return { V = math.floor(c.V), K = keys }
end

-- The row the client shows (only plain fields; the text is already filtered).
local function rowOf(id: string, r: { [string]: any }?): { [string]: any }
	if type(r) ~= "table" then
		return { Id = id, Missing = true }
	end
	return {
		Id = id,
		Time = r.Time,
		UserId = r.UserId,
		Name = r.Name,
		Category = r.Category,
		Text = type(r.Text) == "string" and r.Text or "[filter failed]",
		Status = B.IsStatus(r.Status) and r.Status or "New",
		Context = B.ContextLine(r.Server),
		ClientLine = B.ContextLine(r.Client),
		RunTime = type(r.Server) == "table" and r.Server.RunTime or nil,
		Mode = type(r.Server) == "table" and r.Server.Mode or nil,
		PlaceVersion = type(r.Server) == "table" and r.Server.PlaceVersion or nil,
		-- BugReportPlus: cleaned again on the way out (already filtered when stored)
		Snapshot = (S.On() and type(r.Snapshot) == "table") and S.CleanSnapshot(r.Snapshot) or nil,
		ServerBuild = (S.On() and type(r.ServerBuild) == "table") and {
			Wave = type(r.Server) == "table" and tonumber(r.Server.Wave) or nil,
			Weapons = S.CleanBuild(r.ServerBuild.Weapons, "Weapon"),
			Passives = S.CleanBuild(r.ServerBuild.Passives, "Passive"),
		} or nil,
	}
end

local function sendPage(player: Player, cursorIn: any)
	if not available() then
		Remotes.FireClient("BugInboxData", player, { Kind = "Page", Status = "offline", Rows = {}, Message = "DataStores are unavailable on this server." })
		return
	end
	if budget(Enum.DataStoreRequestType.GetSortedAsync) < 1 then
		Remotes.FireClient("BugInboxData", player, { Kind = "Page", Status = "error", Rows = {}, Message = "DataStore budget is low. Try again in a moment." })
		return
	end
	local cursor = cleanCursor(cursorIn)
	local skip: { [string]: boolean } = {}
	if cursor then
		for _, k in ipairs(cursor.K) do
			skip[k] = true
		end
	end
	local size = pageSize()
	local want = size + (cursor and #cursor.K or 0) + 1
	local ok, entries = pcall(function()
		local pages = (index :: OrderedDataStore):GetSortedAsync(false, want, nil, cursor and cursor.V or nil)
		return pages:GetCurrentPage()
	end)
	if not ok or type(entries) ~= "table" then
		warn("[BugReportService] inbox read failed: " .. tostring(entries))
		Remotes.FireClient("BugInboxData", player, { Kind = "Page", Status = "error", Rows = {}, Message = "Could not read the inbox. Try again." })
		return
	end
	local picked = {}
	local more = false
	for _, e in ipairs(entries) do
		if not skip[e.key] then
			if #picked >= size then
				more = true
				break
			end
			table.insert(picked, e)
		end
	end
	local rows = {}
	for _, e in ipairs(picked) do
		local id = e.key
		local r = cache[id]
		if not r and budget(Enum.DataStoreRequestType.GetAsync) >= 1 then
			local gotOk, got = pcall(function()
				return (reports :: DataStore):GetAsync(id)
			end)
			if gotOk and type(got) == "table" then
				r = got
				remember(id, got)
			end
		end
		table.insert(rows, rowOf(id, r))
	end
	local nextCursor: Cursor? = nil
	if more and #picked > 0 then
		local lastV = picked[#picked].value
		local keys = {}
		for _, e in ipairs(picked) do
			if e.value == lastV then
				table.insert(keys, e.key)
			end
		end
		-- entries tied with the previous boundary are already shown too
		if cursor and cursor.V == lastV then
			for _, k in ipairs(cursor.K) do
				table.insert(keys, k)
			end
		end
		nextCursor = { V = lastV, K = keys }
	end
	Remotes.FireClient("BugInboxData", player, { Kind = "Page", Status = "ok", Rows = rows, Next = nextCursor })
end

local function setStatus(player: Player, id: any, status: any)
	if not B.IsReportId(id) or not B.IsStatus(status) then
		return
	end
	local result = { Kind = "Status", Id = id, Status = status, Ok = false }
	if available() and budget(Enum.DataStoreRequestType.UpdateAsync) >= 1 then
		local updated: { [string]: any }? = nil
		local ok, err = pcall(function()
			(reports :: DataStore):UpdateAsync(id, function(old)
				if type(old) ~= "table" then
					return nil
				end
				old.Status = status
				old.StatusBy = player.UserId
				old.StatusAt = os.time()
				updated = old
				return old
			end)
		end)
		if ok and updated then
			remember(id, updated :: { [string]: any })
			result.Ok = true
		elseif not ok then
			warn("[BugReportService] status update failed: " .. tostring(err))
		end
	end
	Remotes.FireClient("BugInboxData", player, result)
end

local function inbox(player: Player, action: any, a: any, b: any)
	if not BugReportService.CanViewInbox(player) then
		return
	end
	if action == "Page" then
		sendPage(player, a)
	elseif action == "SetStatus" then
		setStatus(player, a, b)
	end
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function BugReportService.Init(c)
	ctx = c
	if ctx.DataService and ctx.DataService.IsMemoryOnly() then
		warn("[BugReportService] DataStores unavailable: bug reports can't be saved on this server")
		return
	end
	local ok, err = pcall(function()
		reports = DataStoreService:GetDataStore(storeName(B.StoreName))
		index = DataStoreService:GetOrderedDataStore(storeName(B.IndexName))
	end)
	if not ok then
		reports, index = nil, nil
		warn("[BugReportService] DataStores unavailable: " .. tostring(err))
	end
end

function BugReportService.Start()
	local function onPlayer(player: Player)
		if BugReportService.CanViewInbox(player) then
			player:SetAttribute("BugInbox", true)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayer, p)
	end
	Players.PlayerRemoving:Connect(function(player)
		busy[player] = nil
	end)
	Remotes.Listen("BugReport", submit, 1)
	Remotes.Listen("BugInbox", inbox, 2)
end

return BugReportService
