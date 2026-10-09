--!strict
--[[
	SwarmV2/Lobby/QueueService.lua  (ServerScriptService.SwarmV2.Lobby.QueueService)
	OWNER: lobby track (Chat 1). The gate queues of the basecamp. Gate pads (walking on or off)
	and the touch UI (JOIN / LEAVE / READY) call the SAME functions (Join, Leave, SetReady),
	so they share one state machine and one set of server checks.

	Gates (LobbyConfig.Gates):
	  Public  recruiting: one forming queue per gate; solos and WHOLE parties of this lobby
	          server fill its free slots (LobbyConfig.MaxPlayers). A party that doesn't fit is
	          refused, never split. No cross-server matchmaking.
	  Party   party-only: each leader (or solo) gets a private queue nobody else can join.
	A player is in at most one queue. Only a party's leader enters a gate, and the whole party
	comes along (members are moved onto the pad). Anyone of an entry leaving (LEAVE, walking
	off the pad, disconnecting, the party changing) takes the whole entry out.

	Queue state: Waiting → Countdown → (commit) → Transfer. Every member taps READY; when all
	are ready (1..MaxPlayers players) the roster and classes are frozen and a
	LobbyConfig.CountdownSeconds countdown runs. During it the gate takes nobody new; any
	membership change, an UNREADY, or a class change cancels it and clears every READY (the
	snapshot is dropped, never edited). At zero everything is checked again (each player
	still here, loaded, not elsewhere, still owns the frozen class and still has it
	selected); then the queue is committed to Transfer (Transfer.lua) and the gate opens
	a fresh queue. Cancelling is possible only before the commit.

	Pads: Step polls who stands on which pad (Basecamp.InGate). Entering a pad = Join; leaving
	the pad you joined = Leave, but only after the player was seen on it once (a UI join moves
	the avatar onto the pad first) and never within LobbyConfig.PadCooldownSeconds of the
	player's last queue change (no flicker spam). A refused pad join is not retried until the
	player steps off and on again.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SwarmV2Shared = ReplicatedStorage:WaitForChild("SwarmV2")
local LobbyConfig = require(SwarmV2Shared:WaitForChild("Lobby"):WaitForChild("LobbyConfig"))
local ClassCatalog = require(SwarmV2Shared:WaitForChild("ClassCatalog"))
local ClassOwnership = require(script.Parent:WaitForChild("ClassOwnership"))
local Transfer = require(script.Parent:WaitForChild("Transfer"))
local Clock = require(script.Parent:WaitForChild("Clock"))

local QueueService = {}

type Entry = { Leader: Player, Players: { Player } }
export type Queue = {
	Id: number,
	GateId: string,
	Mode: string,
	Capacity: number,
	Entries: { Entry },
	Ready: { [Player]: boolean },
	State: string, -- "Waiting" | "Countdown" | "Committed"
	EndsAt: number, -- Clock.Mono() when the countdown ends
	EndsAtServer: number, -- the same moment in server time (clients count down to it)
	Snapshot: { Players: { Player }, Classes: { [Player]: string } }?,
	Match: Transfer.Match?,
	Message: string?,
}

local deps = {
	DataService = nil :: any,
	PartyService = nil :: any,
	Role = function(): string
		return "local"
	end,
	Push = nil :: ((Player) -> ())?, -- send this player a fresh LobbyView
	Notify = nil :: ((Player, string, string) -> ())?,
	Move = nil :: ((Player, CFrame) -> ())?, -- put the avatar there
	PadCFrame = nil :: ((string, number) -> CFrame)?,
	ExitCFrame = nil :: ((string) -> CFrame)?,
	InGate = nil :: ((Player) -> string?)?, -- the gate pad this player's avatar stands on
	Board = nil :: ((string, { [string]: any }) -> ())?, -- gate sign / board attributes
	InMatch = nil :: ((Player) -> boolean)?, -- local role: away in a local run
}

function QueueService._SetDeps(overrides: { [string]: any })
	for k, v in pairs(overrides) do
		(deps :: any)[k] = v
	end
end

local gateDefs: { [string]: LobbyConfig.GateDef } = {}
for _, g in ipairs(LobbyConfig.Gates) do
	gateDefs[g.Id] = g
end

local nextId = 0
local publicQueue: { [string]: Queue } = {} -- the forming queue of each public gate
local partyQueues: { [Queue]: boolean } = {} -- live party-only queues
local queueOf: { [Player]: Queue } = {}
local lastChange: { [Player]: number } = {}
local padGate: { [Player]: string } = {} -- last pad the poll saw the player on
local seenOnPad: { [Player]: boolean } = {} -- seen on their queue's pad since joining
local padRefused: { [Player]: string } = {} -- refused pad join: wait for step off

local function capacity(): number
	local cap = LobbyConfig.MaxPlayers
	local ps = deps.PartyService
	if ps and ps.MaxSize then
		cap = math.min(cap, ps.MaxSize())
	end
	return math.max(LobbyConfig.MinPlayers, cap)
end

local function notify(p: Player, text: string, kind: string)
	if deps.Notify and p.Parent == Players then
		pcall(deps.Notify :: any, p, text, kind)
	end
end

local function push(p: Player)
	if deps.Push and p.Parent == Players then
		pcall(deps.Push :: any, p)
	end
end

local function members(q: Queue): { Player }
	local list = {}
	for _, e in ipairs(q.Entries) do
		for _, p in ipairs(e.Players) do
			table.insert(list, p)
		end
	end
	return list
end

local function count(q: Queue): number
	local n = 0
	for _, e in ipairs(q.Entries) do
		n += #e.Players
	end
	return n
end

local function pushQueue(q: Queue)
	for _, p in ipairs(members(q)) do
		push(p)
	end
end

local function board(gateId: string)
	if not deps.Board then
		return
	end
	local def = gateDefs[gateId]
	local q = publicQueue[gateId]
	local info: { [string]: any } = { Mode = def.Mode, Label = def.Label, Capacity = capacity(), Count = 0, State = "Open", EndsAt = 0 }
	if def.Mode == "Public" and q then
		info.Count = count(q)
		if q.State == "Countdown" then
			info.State = "Countdown"
			info.EndsAt = q.EndsAtServer
		elseif info.Count >= info.Capacity then
			info.State = "Full"
		end
	elseif def.Mode == "Party" then
		local n = 0
		for pq in pairs(partyQueues) do
			if pq.State ~= "Committed" then
				n += 1
			end
		end
		info.Count = n -- parties getting ready here
	end
	pcall(deps.Board :: any, gateId, info)
end

local function touch(p: Player)
	lastChange[p] = Clock.Mono()
end

-- Why this player can't take part right now, or nil.
local function unavailable(p: Player): string?
	if p.Parent ~= Players then
		return "gone"
	end
	local ds = deps.DataService
	if ds and ds.GetData(p) == nil then
		return "Your save is still loading."
	end
	if Transfer.IsBusy(p) then
		return "You're already heading to a run."
	end
	if deps.InMatch and (deps.InMatch :: any)(p) then
		return "You're in a run."
	end
	if p:GetAttribute("InRun") == true then
		return "You're in a run."
	end
	return nil
end

local function classOf(p: Player): string
	local ds = deps.DataService
	local data = ds and ds.GetData(p)
	return data and ClassOwnership.Selected(data) or ClassCatalog.Default
end

-- Clears every READY of a queue (the line-up or a class changed).
local function clearReady(q: Queue)
	table.clear(q.Ready)
end

-- Countdown → Waiting (the snapshot is dropped, never edited).
local function cancelCountdown(q: Queue, why: string)
	if q.State ~= "Countdown" then
		clearReady(q)
		return
	end
	q.State = "Waiting"
	q.Snapshot = nil
	q.EndsAt, q.EndsAtServer = 0, 0
	q.Message = why
	clearReady(q)
	for _, p in ipairs(members(q)) do
		notify(p, why .. " Tap READY again.", "warn")
	end
end

local function dropQueue(q: Queue)
	if publicQueue[q.GateId] == q then
		publicQueue[q.GateId] = nil
	end
	partyQueues[q] = nil
end

-- The players of the entry `p` belongs to, after removing that entry from its queue.
local function removeEntryOf(p: Player, why: string?, moveOut: boolean): { Player }
	local q = queueOf[p]
	if not q or q.State == "Committed" then
		return {}
	end
	local removed: { Player } = {}
	for i, e in ipairs(q.Entries) do
		if table.find(e.Players, p) then
			table.remove(q.Entries, i)
			removed = e.Players
			break
		end
	end
	for _, m in ipairs(removed) do
		queueOf[m] = nil
		seenOnPad[m] = nil
		touch(m)
		if moveOut and m.Parent == Players and deps.Move and deps.ExitCFrame and padGate[m] == q.GateId then
			pcall(deps.Move :: any, m, (deps.ExitCFrame :: any)(q.GateId))
		end
	end
	if q.State == "Countdown" then
		cancelCountdown(q, (why or (p.DisplayName .. " left the gate.")))
	else
		clearReady(q)
	end
	if #q.Entries == 0 then
		dropQueue(q)
	end
	for _, m in ipairs(removed) do
		push(m)
	end
	pushQueue(q)
	board(q.GateId)
	return removed
end

------------------------------------------------------------------------------------------
-- Actions (UI and pads)
------------------------------------------------------------------------------------------

--[[
	Join a gate. `via` = "ui" | "pad". Returns nil on success, else the text shown to the
	player. Atomic: either the whole entry (party) is added or nothing changes.
]]
function QueueService.Join(p: Player, gateId: any, via: string?): string?
	local role = deps.Role()
	if role ~= "lobby" and role ~= "local" then
		return "Gates are closed on this server."
	end
	local def = type(gateId) == "string" and gateDefs[gateId] or nil
	if not def then
		return "That gate doesn't exist."
	end
	if queueOf[p] then
		if queueOf[p].GateId == gateId then
			return nil
		end
		return "You're already in another gate."
	end
	local why = unavailable(p)
	if why then
		return why
	end
	-- the entry: a solo, or the leader's whole party
	local group: { Player } = { p }
	local ps = deps.PartyService
	local party = ps and ps.PartyOf and ps.PartyOf(p)
	if party and #party.Members > 1 then
		if party.Leader ~= p then
			return "Only your party leader can enter a gate."
		end
		group = {}
		for _, m in ipairs(party.Members) do
			table.insert(group, m)
		end
		for _, m in ipairs(group) do
			if m ~= p then
				if queueOf[m] then
					return m.DisplayName .. " is in another gate."
				end
				local mWhy = unavailable(m)
				if mWhy then
					return m.DisplayName .. " can't join now."
				end
			end
		end
	end
	local cap = capacity()
	if #group > cap then
		return "Your party is too big for one run."
	end
	local q: Queue
	if def.Mode == "Public" then
		local existing = publicQueue[gateId]
		if existing and existing.State == "Countdown" then
			return "This gate is launching. Try the next one."
		end
		if existing and count(existing) + #group > cap then
			return #group > 1 and "Not enough room for your whole party here." or "This gate is full."
		end
		if not existing then
			nextId += 1
			existing = { Id = nextId, GateId = gateId, Mode = "Public", Capacity = cap, Entries = {}, Ready = {}, State = "Waiting", EndsAt = 0, EndsAtServer = 0, Snapshot = nil, Match = nil, Message = nil }
			publicQueue[gateId] = existing
		end
		q = existing :: Queue
	else
		nextId += 1
		q = { Id = nextId, GateId = gateId, Mode = "Party", Capacity = cap, Entries = {}, Ready = {}, State = "Waiting", EndsAt = 0, EndsAtServer = 0, Snapshot = nil, Match = nil, Message = nil }
		partyQueues[q] = true
	end
	table.insert(q.Entries, { Leader = p, Players = group })
	q.Message = nil
	clearReady(q) -- a new line-up: everyone readies again
	for i, m in ipairs(group) do
		queueOf[m] = q
		seenOnPad[m] = padGate[m] == gateId
		padRefused[m] = nil
		touch(m)
		-- party mates (and a UI join) are put on the pad, so pad and UI agree
		if (via ~= "pad" or m ~= p) and padGate[m] ~= gateId and deps.Move and deps.PadCFrame then
			pcall(deps.Move :: any, m, (deps.PadCFrame :: any)(gateId, count(q) - #group + i))
		end
		if m ~= p then
			notify(m, p.DisplayName .. " took the party to " .. def.Label .. ".", "good")
		end
	end
	pushQueue(q)
	board(gateId)
	return nil
end

-- Leave the queue (the whole entry leaves). Returns nil, or why not.
function QueueService.Leave(p: Player, why: string?): string?
	local q = queueOf[p]
	if not q then
		return nil
	end
	if q.State == "Committed" then
		return "Too late: your team is already travelling."
	end
	removeEntryOf(p, why, true)
	return nil
end

local function startCountdown(q: Queue)
	local list = members(q)
	local classes: { [Player]: string } = {}
	for _, p in ipairs(list) do
		local why = unavailable(p)
		if why then
			cancelCountdown(q, p.DisplayName .. " can't start now.")
			return
		end
		classes[p] = classOf(p)
	end
	q.Snapshot = { Players = list, Classes = classes }
	q.State = "Countdown"
	q.EndsAt = Clock.Mono() + LobbyConfig.CountdownSeconds
	q.EndsAtServer = Clock.ServerTime() + LobbyConfig.CountdownSeconds
	q.Message = nil
	pushQueue(q)
	board(q.GateId)
end

-- READY toggle. Returns nil, or why not.
function QueueService.SetReady(p: Player, on: any): string?
	local q = queueOf[p]
	if not q or type(on) ~= "boolean" then
		return nil
	end
	if q.State == "Committed" then
		return nil
	end
	if not on then
		if q.Ready[p] then
			if q.State == "Countdown" then
				cancelCountdown(q, p.DisplayName .. " isn't ready.")
			else
				q.Ready[p] = nil
			end
			pushQueue(q)
			board(q.GateId)
		end
		return nil
	end
	if q.Ready[p] then
		return nil
	end
	q.Ready[p] = true
	local all = true
	for _, m in ipairs(members(q)) do
		if not q.Ready[m] then
			all = false
			break
		end
	end
	if all and count(q) >= LobbyConfig.MinPlayers and q.State == "Waiting" then
		startCountdown(q)
	else
		pushQueue(q)
	end
	return nil
end

-- A class change: a frozen countdown can't silently take the new class.
function QueueService.OnClassChanged(p: Player)
	local q = queueOf[p]
	if not q or q.State == "Committed" then
		return
	end
	if q.State == "Countdown" then
		cancelCountdown(q, p.DisplayName .. " changed class.")
	else
		q.Ready[p] = nil
	end
	pushQueue(q)
	board(q.GateId)
end

-- Party membership or leader changed for these players: entries that no longer match leave.
function QueueService.OnPartyChanged(changed: { Player })
	for _, p in ipairs(changed) do
		local q = queueOf[p]
		if q and q.State ~= "Committed" then
			local ps = deps.PartyService
			local party = ps and ps.PartyOf and ps.PartyOf(p)
			local entry: Entry? = nil
			for _, e in ipairs(q.Entries) do
				if table.find(e.Players, p) then
					entry = e
				end
			end
			local same = entry ~= nil
			if entry then
				local e = entry :: Entry
				if party and #party.Members > 1 then
					same = party.Leader == e.Leader and #party.Members == #e.Players
					for _, m in ipairs(party.Members) do
						same = same and table.find(e.Players, m) ~= nil
					end
				else
					same = #e.Players == 1
				end
			end
			if not same then
				for _, m in ipairs(removeEntryOf(p, "The party changed.", false)) do
					notify(m, "Your party changed: enter the gate again.", "warn")
				end
			end
		end
	end
end

function QueueService.OnPlayerRemoving(p: Player)
	if queueOf[p] then
		removeEntryOf(p, p.DisplayName .. " left the game.", false)
	end
	queueOf[p] = nil
	lastChange[p] = nil
	padGate[p] = nil
	seenOnPad[p] = nil
	padRefused[p] = nil
end

-- One pad reading for a player (Step, or a regression). gateId = the pad they stand on.
function QueueService.PadUpdate(p: Player, gateId: string?)
	local before = padGate[p]
	padGate[p] = gateId :: any
	if gateId == nil then
		padRefused[p] = nil
	end
	local q = queueOf[p]
	if q and gateId == q.GateId then
		seenOnPad[p] = true
		return
	end
	local recent = Clock.Mono() - (lastChange[p] or -math.huge) < LobbyConfig.PadCooldownSeconds
	if q and q.State ~= "Committed" and seenOnPad[p] and gateId ~= q.GateId then
		if not recent then
			QueueService.Leave(p, p.DisplayName .. " stepped off the gate.")
		end
		return
	end
	if not q and gateId and recent then
		padGate[p] = before :: any -- too soon: read this pad again on the next poll
		return
	end
	if not q and gateId and gateId ~= before and padRefused[p] ~= gateId then
		local why = QueueService.Join(p, gateId, "pad")
		if why then
			padRefused[p] = gateId
			notify(p, why, "warn")
		end
	end
end

------------------------------------------------------------------------------------------
-- Commit
------------------------------------------------------------------------------------------

local function commit(q: Queue)
	local snap = q.Snapshot
	if not snap then
		cancelCountdown(q, "The start was cancelled.")
		return
	end
	-- everything again, right before departure
	local now = members(q)
	if #now ~= #snap.Players then
		cancelCountdown(q, "The team changed.")
		return
	end
	for _, p in ipairs(snap.Players) do
		if not table.find(now, p) or unavailable(p) then
			cancelCountdown(q, p.DisplayName .. " can't start now.")
			return
		end
		local ds = deps.DataService
		local data = ds and ds.GetData(p)
		local frozen = snap.Classes[p]
		if not data or not ClassOwnership.Owns(data, frozen) or ClassOwnership.Selected(data) ~= frozen then
			cancelCountdown(q, p.DisplayName .. "'s class changed.")
			return
		end
	end
	q.State = "Committed"
	dropQueue(q) -- the gate opens a fresh queue
	board(q.GateId)
	for _, p in ipairs(snap.Players) do
		queueOf[p] = nil
		seenOnPad[p] = nil
		touch(p)
	end
	q.Match = Transfer.Begin({ Players = snap.Players, Classes = snap.Classes, GateId = q.GateId }, deps.Role(), function(m)
		q.Message = m.State
		for _, p in ipairs(m.Players) do
			push(p)
		end
	end)
end

-- Countdowns and pads; called every LobbyConfig.PadPollSeconds by LobbyBoot.
function QueueService.Step()
	local now = Clock.Mono()
	local due: { Queue } = {}
	for _, q in pairs(publicQueue) do
		if q.State == "Countdown" and now >= q.EndsAt then
			table.insert(due, q)
		end
	end
	for q in pairs(partyQueues) do
		if q.State == "Countdown" and now >= q.EndsAt then
			table.insert(due, q)
		end
	end
	for _, q in ipairs(due) do
		commit(q)
	end
	if deps.InGate then
		for _, p in ipairs(Players:GetPlayers()) do
			local ok, gate = pcall(deps.InGate :: any, p)
			QueueService.PadUpdate(p, ok and gate or nil)
		end
	end
end

------------------------------------------------------------------------------------------
-- Views
------------------------------------------------------------------------------------------

function QueueService.QueueOf(p: Player): Queue?
	return queueOf[p]
end

function QueueService.IsQueued(p: Player): boolean
	return queueOf[p] ~= nil
end

-- The player's queue as LobbyNet.QueueView (or the travelling match), nil when neither.
function QueueService.View(p: Player): { [string]: any }?
	local q = queueOf[p]
	local m = Transfer.MatchOf(p)
	if not q and not m then
		return nil
	end
	if not q and m then
		local list = {}
		for _, mp in ipairs(m.Players) do
			table.insert(list, { UserId = mp.UserId, Name = mp.DisplayName, ClassId = "", Ready = true, Leader = false })
		end
		return {
			GateId = "",
			Mode = "",
			State = m.State == "teleporting" and "Teleporting" or "Committed",
			Capacity = #m.Players,
			Members = list,
			EndsAt = 0,
			Message = (m.Tries[p] or 0) > 0 and "Retrying the teleport…" or nil,
		}
	end
	local qq = q :: Queue
	local list = {}
	local ps = deps.PartyService
	for _, e in ipairs(qq.Entries) do
		for _, mp in ipairs(e.Players) do
			local frozen = qq.Snapshot and qq.Snapshot.Classes[mp]
			local party = ps and ps.PartyOf and ps.PartyOf(mp)
			table.insert(list, {
				UserId = mp.UserId,
				Name = mp.DisplayName,
				ClassId = frozen or classOf(mp),
				Ready = qq.Ready[mp] == true,
				Leader = party ~= nil and party.Leader == mp and #party.Members > 1,
			})
		end
	end
	return {
		GateId = qq.GateId,
		Mode = qq.Mode,
		State = qq.State,
		Capacity = qq.Capacity,
		Members = list,
		EndsAt = qq.State == "Countdown" and qq.EndsAtServer or 0,
		Message = qq.Message,
	}
end

-- Gate boards for every gate (boot).
function QueueService.RefreshBoards()
	for _, g in ipairs(LobbyConfig.Gates) do
		board(g.Id)
	end
end

function QueueService.Init(ctx: any)
	deps.DataService = ctx and ctx.DataService or deps.DataService
	deps.PartyService = ctx and ctx.PartyService or deps.PartyService
end

return QueueService
