--!strict
--[[
	SwarmV2/Lobby/Transfer.lua  (ServerScriptService.SwarmV2.Lobby.Transfer)
	OWNER: lobby track (Chat 1). Takes a committed queue snapshot to its match.

	State per match: committed → teleporting → completed | partial | failed. Member status:
	pending → departed (left this server through the teleport) | failed (save given back,
	free to queue again). One matchId, one reservation and one ticket per match, whatever
	retries happen; departed members are never teleported again.

	Lobby role (live game):
	  1. ReserveServerAsync(game.PlaceId) (LobbyConfig.ReserveAttempts tries) → access code
	     + PrivateServerId. The access code stays in this module's memory only.
	  2. MatchAdmission.BuildTicket → TicketStore.Write("live") with the ticket's own TTL.
	  3. Every member's save is written and released (DataService.ReleaseForTeleport) so the
	     match server loads the latest save. Any failure before the teleport cancels the whole
	     match: saves are taken back, nobody left, the queue can start again.
	  4. ONE TeleportAsync for the group: TeleportOptions { ReservedServerAccessCode,
	     TeleportData { SwarmV2 = { schemaVersion = 1, matchId } } } (a hint only). A
	     synchronous error retries the still-pending members (TeleportRetries, delays
	     TeleportRetryDelays). TeleportInitFailed or a timeout (TeleportTimeoutSeconds) retries
	     that one player to the same reservation; after the retries are spent they get their
	     save back and a notice ("failed"), the others carry on.
	Local role: the roster's ticket goes to MatchAdmission.RegisterLocalMatch and the match to
	  SwarmV2.Run.RunEntry.BeginLocalMatch on this server. false (or an error) = the run couldn't
	  start: the local ticket is dropped and everyone stays in the camp.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local SwarmV2Shared = ReplicatedStorage:WaitForChild("SwarmV2")
local Types = require(SwarmV2Shared:WaitForChild("Types"))
local LobbyConfig = require(SwarmV2Shared:WaitForChild("Lobby"):WaitForChild("LobbyConfig"))
local MatchAdmission = require(script.Parent.Parent:WaitForChild("MatchAdmission"))
local TicketStore = require(script.Parent:WaitForChild("TicketStore"))
local Clock = require(script.Parent:WaitForChild("Clock"))

local Transfer = {}

export type Snapshot = { Players: { Player }, Classes: { [Player]: string }, GateId: string }
export type Match = {
	Id: string,
	State: string, -- "committed" | "teleporting" | "completed" | "partial" | "failed"
	Players: { Player },
	Status: { [Player]: string }, -- "pending" | "departed" | "failed"
	Tries: { [Player]: number },
	CalledAt: { [Player]: number },
	Options: Instance?,
	Message: string?,
	OnUpdate: ((Match) -> ())?,
}

local deps = {
	DataService = nil :: any,
	Reserve = function(): (string, string)
		local code, privateId = TeleportService:ReserveServerAsync(game.PlaceId)
		return code, privateId
	end,
	Teleport = function(players: { Player }, options: Instance)
		TeleportService:TeleportAsync(game.PlaceId, players, options :: TeleportOptions)
	end,
	BeginLocalMatch = function(matchId: string, players: { Player }): boolean
		local entry = require(ServerScriptService:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunEntry")) :: any
		return entry.BeginLocalMatch(matchId, players) == true
	end,
	NewMatchId = function(): string
		return HttpService:GenerateGUID(false)
	end,
	Wait = function(seconds: number)
		task.wait(seconds)
	end,
	Notify = nil :: ((Player, string, string) -> ())?,
	-- the player leaves the camp (local match) / comes back (failed start)
	OnLocalStart = nil :: ((Player) -> ())?,
	OnLocalCancel = nil :: ((Player) -> ())?,
}

function Transfer._SetDeps(overrides: { [string]: any })
	for k, v in pairs(overrides) do
		(deps :: any)[k] = v
	end
end

local matchOf: { [Player]: Match } = {} -- members still pending (busy)
local matches: { [string]: Match } = {}

local function notify(p: Player, text: string, kind: string)
	if deps.Notify and p.Parent == Players then
		pcall(deps.Notify, p, text, kind)
	end
end

local function setTravel(p: Player, on: boolean)
	if p.Parent == Players then
		p:SetAttribute("Travel", on and "ToRun" or "")
	end
end

local function update(m: Match)
	if m.OnUpdate then
		local ok: boolean, err: any = pcall(m.OnUpdate :: (Match) -> (), m)
		if not ok then
			warn("[SwarmV2 Transfer] update callback: " .. tostring(err))
		end
	end
end

-- Recomputes the match state from member statuses once nobody is pending.
local function settle(m: Match)
	local pending, departed = 0, 0
	for _, p in ipairs(m.Players) do
		local s = m.Status[p]
		if s == "pending" then
			pending += 1
		elseif s == "departed" then
			departed += 1
		end
	end
	if pending == 0 then
		if departed == #m.Players then
			m.State = "completed"
		elseif departed == 0 then
			m.State = "failed"
		else
			m.State = "partial"
		end
		matches[m.Id] = nil
	end
	update(m)
end

local function takeBack(p: Player)
	local ds = deps.DataService
	if p.Parent ~= Players or not ds then
		return
	end
	if ds.IsReleased and ds.IsReleased(p) and not ds.Reclaim(p) then
		p:Kick("Couldn't reach your run. Please rejoin: your progress is saved.")
	end
end

-- One member failed for good: save back, free again.
local function failMember(m: Match, p: Player, why: string)
	if m.Status[p] ~= "pending" then
		return
	end
	m.Status[p] = "failed"
	matchOf[p] = nil
	setTravel(p, false)
	takeBack(p)
	notify(p, why, "bad")
	settle(m)
end

-- The whole match failed before anyone left.
local function failAll(m: Match, why: string)
	m.Message = why
	for _, p in ipairs(m.Players) do
		if m.Status[p] == "pending" then
			m.Status[p] = "failed"
			matchOf[p] = nil
			setTravel(p, false)
			takeBack(p)
			notify(p, why, "bad")
		end
	end
	settle(m)
end

local function pendingHere(m: Match): { Player }
	local list = {}
	for _, p in ipairs(m.Players) do
		if m.Status[p] == "pending" and p.Parent == Players then
			table.insert(list, p)
		end
	end
	return list
end

local function watchTimeout(m: Match, list: { Player })
	local at = Clock.Mono()
	for _, p in ipairs(list) do
		m.CalledAt[p] = at
	end
	task.delay(LobbyConfig.TeleportTimeoutSeconds, function()
		for _, p in ipairs(list) do
			if m.Status[p] == "pending" and p.Parent == Players and m.CalledAt[p] == at then
				warn("[SwarmV2 Transfer] teleport timed out for " .. p.Name)
				Transfer.OnTeleportFailed(p)
			end
		end
	end)
end

-- TeleportInitFailed (or a timeout): retry this player alone to the same reservation.
function Transfer.OnTeleportFailed(p: Player)
	local m = matchOf[p]
	if not m or m.State ~= "teleporting" or m.Status[p] ~= "pending" then
		return
	end
	local n = (m.Tries[p] or 0) + 1
	m.Tries[p] = n
	if n > LobbyConfig.TeleportRetries then
		failMember(m, p, "Couldn't reach your run's server. You can queue again.")
		return
	end
	update(m)
	m.CalledAt[p] = -1 -- an old timeout must not fire for this retry
	task.spawn(function()
		deps.Wait(LobbyConfig.TeleportRetryDelays[n] or 3)
		if matchOf[p] ~= m or m.Status[p] ~= "pending" or p.Parent ~= Players then
			return
		end
		local ok: boolean, err: any = pcall(deps.Teleport, { p }, m.Options :: Instance)
		if not ok then
			warn("[SwarmV2 Transfer] retry teleport failed: " .. tostring(err))
			Transfer.OnTeleportFailed(p)
		else
			watchTimeout(m, { p })
		end
	end)
end

-- A pending member left this server: the teleport took them.
function Transfer.OnPlayerRemoving(p: Player)
	local m = matchOf[p]
	if not m then
		return
	end
	matchOf[p] = nil
	if m.Status[p] == "pending" then
		-- before the teleport call they just quit: not departed to the match
		m.Status[p] = m.State == "teleporting" and "departed" or "failed"
		settle(m)
	end
end

local function runLive(m: Match, snap: Snapshot)
	-- 1. reservation
	local code: string?, privateId: string? = nil, nil
	for i = 1, LobbyConfig.ReserveAttempts do
		local ok: boolean, c: any, pid: any = pcall(deps.Reserve)
		if ok and type(c) == "string" and c ~= "" and type(pid) == "string" and pid ~= "" then
			code, privateId = c, pid
			break
		end
		warn("[SwarmV2 Transfer] ReserveServer failed: " .. tostring(c))
		if i < LobbyConfig.ReserveAttempts then
			deps.Wait(1)
		end
	end
	if not code or not privateId then
		failAll(m, "Couldn't reserve a run server. Try again.")
		return
	end
	-- 2. ticket (server-only store)
	local roster = {}
	for _, p in ipairs(m.Players) do
		table.insert(roster, { userId = p.UserId, classId = snap.Classes[p] })
	end
	local ticket = MatchAdmission.BuildTicket(m.Id, privateId, roster)
	if not TicketStore.Write("live", ticket :: any) then
		failAll(m, "Couldn't save the match ticket. Try again.")
		return
	end
	-- 3. saves released (anyone gone or failing cancels the whole match: nobody left yet)
	local ds = deps.DataService
	for _, p in ipairs(m.Players) do
		if p.Parent ~= Players or m.Status[p] ~= "pending" then
			failAll(m, "A player left before the teleport. Queue again.")
			TicketStore.Remove("live", m.Id)
			return
		end
		if ds and not ds.ReleaseForTeleport(p) then
			failAll(m, "Couldn't save before travelling. Queue again.")
			TicketStore.Remove("live", m.Id)
			return
		end
	end
	-- 4. one teleport for the group, retried for the still-pending members
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = code
	options:SetTeleportData({ SwarmV2 = { schemaVersion = Types.SchemaVersion, matchId = m.Id } })
	m.Options = options
	m.State = "teleporting"
	update(m)
	for i = 1, 1 + LobbyConfig.TeleportRetries do
		local here = pendingHere(m)
		if #here == 0 then
			return
		end
		local ok: boolean, err: any = pcall(deps.Teleport, here, options)
		if ok then
			watchTimeout(m, here)
			return
		end
		warn("[SwarmV2 Transfer] TeleportAsync failed: " .. tostring(err))
		if i <= LobbyConfig.TeleportRetries then
			deps.Wait(LobbyConfig.TeleportRetryDelays[i] or 3)
		end
	end
	-- nobody could be sent: everyone gets their save back
	failAll(m, "Couldn't reach a run server. Queue again.")
end

local function runLocal(m: Match, snap: Snapshot)
	local roster = {}
	for _, p in ipairs(m.Players) do
		table.insert(roster, { userId = p.UserId, classId = snap.Classes[p] })
	end
	local ticket = MatchAdmission.BuildTicket(m.Id, "local", roster)
	if not MatchAdmission.RegisterLocalMatch(ticket) then
		failAll(m, "Couldn't start the run. Try again.")
		return
	end
	m.State = "teleporting"
	for _, p in ipairs(m.Players) do
		if deps.OnLocalStart then
			pcall(deps.OnLocalStart :: (Player) -> (), p)
		end
	end
	local ok: boolean, started: any = pcall(deps.BeginLocalMatch, m.Id, m.Players)
	if not ok then
		warn("[SwarmV2 Transfer] BeginLocalMatch error: " .. tostring(started))
	end
	if ok and started == true then
		for _, p in ipairs(m.Players) do
			if m.Status[p] == "pending" then
				m.Status[p] = "departed"
				matchOf[p] = nil
			end
		end
		settle(m)
		return
	end
	MatchAdmission.EndLocalMatch(m.Id)
	for _, p in ipairs(m.Players) do
		if deps.OnLocalCancel then
			pcall(deps.OnLocalCancel :: (Player) -> (), p)
		end
	end
	m.State = "committed" -- failAll reports; nobody left the camp
	failAll(m, "The run couldn't start. Try again.")
end

--[[
	Starts a committed match. `snap` is the frozen roster (QueueService validated it just
	now). Returns the match (OnUpdate is called on every state / member change).
]]
function Transfer.Begin(snap: Snapshot, role: string, onUpdate: ((Match) -> ())?): Match
	local m: Match = {
		Id = deps.NewMatchId(),
		State = "committed",
		Players = table.clone(snap.Players),
		Status = {},
		Tries = {},
		CalledAt = {},
		Options = nil,
		Message = nil,
		OnUpdate = onUpdate,
	}
	for _, p in ipairs(m.Players) do
		m.Status[p] = "pending"
		matchOf[p] = m
		setTravel(p, role ~= "local")
	end
	matches[m.Id] = m
	update(m)
	task.spawn(function()
		local ok: boolean, err: any = pcall(role == "local" and runLocal or runLive, m, snap)
		if not ok then
			warn("[SwarmV2 Transfer] " .. tostring(err))
			if #pendingHere(m) > 0 and m.State ~= "teleporting" then
				failAll(m, "Something went wrong starting the run. Queue again.")
			end
		end
	end)
	return m
end

-- True while this player belongs to a match that hasn't settled for them (locked in).
function Transfer.IsBusy(p: Player): boolean
	return matchOf[p] ~= nil
end

function Transfer.MatchOf(p: Player): Match?
	return matchOf[p]
end

function Transfer.Init(ctx: any)
	deps.DataService = ctx and ctx.DataService or deps.DataService
end

local started = false
function Transfer.Start()
	if started then
		return
	end
	started = true
	pcall(function()
		TeleportService.TeleportInitFailed:Connect(function(p)
			Transfer.OnTeleportFailed(p)
		end)
	end)
	Players.PlayerRemoving:Connect(Transfer.OnPlayerRemoving)
end

return Transfer
