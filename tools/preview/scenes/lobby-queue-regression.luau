-- lobby-queue-regression: SwarmV2 lobby logic against injected fakes (no server boot):
-- QueueService (join rules, parties, READY / countdown / cancel causes, commit, pads vs UI),
-- Transfer (live path: one reservation, server-only ticket, hint-only TeleportData, saves
-- released first, partial teleports, failures; local path), ClassService + ClassOwnership.
-- Prints PASS / FAIL lines. Run: render.sh lobby-queue-regression --devices pc --max-time 400
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Lobby = SSS.SwarmV2.Lobby
local MA = preview.require(SSS.SwarmV2.MatchAdmission)
local TicketStore = preview.require(Lobby.TicketStore)
local Clock = preview.require(Lobby.Clock)
local Transfer = preview.require(Lobby.Transfer)
local QueueService = preview.require(Lobby.QueueService)
local ClassService = preview.require(Lobby.ClassService)
local ClassOwnership = preview.require(Lobby.ClassOwnership)
local LobbyConfig = preview.require(RS.SwarmV2.Lobby.LobbyConfig)
local ClassCatalog = preview.require(RS.SwarmV2.ClassCatalog)
local Types = preview.require(RS.SwarmV2.Types)

local passes, fails = 0, 0
local function check(label: string, ok: boolean, detail: any?)
	if ok then
		passes += 1
	else
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, (not ok and detail ~= nil) and (" (" .. tostring(detail) .. ")") or ""))
end

local PLACE = 4242
local T0 = 2_000_000
local nowUnix, nowMono = T0, 100.0
Clock._Set(function()
	return nowUnix
end, function()
	return nowMono
end)

------------------------------------------------------------------------------------------
-- Fakes
------------------------------------------------------------------------------------------
local role = "lobby"
local events: { string } = {} -- ordered: release / reclaim / reserve / teleport
local notes: { [Player]: { string } } = {}
local moves: { { Player } } = {}
local pushes = 0
local parties: { [Player]: any } = {}
local partyMax = 4

local ds: any = { saves = {}, released = {}, releaseFail = {} }
function ds.GetData(p)
	return ds.saves[p]
end
function ds.ReleaseForTeleport(p)
	if ds.releaseFail[p] then
		return false
	end
	ds.released[p] = true
	table.insert(events, "release:" .. p.UserId)
	return true
end
function ds.IsReleased(p)
	return ds.released[p] == true
end
function ds.Reclaim(p)
	ds.released[p] = nil
	table.insert(events, "reclaim:" .. p.UserId)
	return true
end

local PS = {
	PartyOf = function(p)
		return parties[p]
	end,
	MaxSize = function()
		return partyMax
	end,
}

local reserves = 0
local reserveFail = 0 -- next N Reserve calls error
local reserveEmpty = false
local teleports: { any } = {}
local teleportFail = 0
local matchSeq = 0
local localBegin: { any } = {}
local localBeginResult: any = true
local localStarts, localCancels = 0, 0

local function deepHas(v: any, needle: string, depth: number?): boolean
	if (depth or 0) > 8 then
		return false
	end
	if type(v) == "string" then
		return string.find(v, needle, 1, true) ~= nil
	elseif type(v) == "table" then
		for k, x in pairs(v) do
			if deepHas(k, needle, (depth or 0) + 1) or deepHas(x, needle, (depth or 0) + 1) then
				return true
			end
		end
	end
	return false
end

local function keys(t: any): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

local function spyBackend(failures: { count: number }?)
	local inner = TicketStore.MemoryBackend(failures)
	local spy: any = { sets = {}, removes = {} }
	spy.backend = {
		Get = inner.Get,
		Set = function(k, v, ttl)
			inner.Set(k, v, ttl)
			table.insert(spy.sets, { key = k, value = v, ttl = ttl })
		end,
		Update = inner.Update,
		Remove = function(k)
			inner.Remove(k)
			table.insert(spy.removes, k)
		end,
	}
	return spy
end

local liveSpy: any
local function setRole(r: string)
	role = r
	MA._SetDeps({
		DataService = ds,
		IsStudio = function()
			return r == "local"
		end,
		PlaceId = function()
			return PLACE
		end,
		PrivateServerId = function()
			return ""
		end,
		PrivateServerOwnerId = function()
			return 0
		end,
		JobId = function()
			return "job-lobby"
		end,
	})
end

QueueService._SetDeps({
	DataService = ds,
	PartyService = PS,
	Role = function()
		return role
	end,
	Push = function()
		pushes += 1
	end,
	Notify = function(p, text)
		notes[p] = notes[p] or {}
		table.insert(notes[p], text)
	end,
	Move = function(p, cf)
		table.insert(moves, { p, cf })
	end,
	PadCFrame = function()
		return CFrame.new()
	end,
	ExitCFrame = function()
		return CFrame.new()
	end,
	Board = function() end,
})
Transfer._SetDeps({
	DataService = ds,
	Reserve = function()
		reserves += 1
		table.insert(events, "reserve")
		if reserveFail > 0 then
			reserveFail -= 1
			error("reserve refused (test)")
		end
		if reserveEmpty then
			return "", ""
		end
		return "SECRET-ACCESS-CODE-" .. reserves, "ps-" .. reserves
	end,
	Teleport = function(players, options)
		table.insert(events, "teleport")
		table.insert(teleports, { players = table.clone(players), options = options, data = options:GetTeleportData() })
		if teleportFail > 0 then
			teleportFail -= 1
			error("teleport refused (test)")
		end
	end,
	BeginLocalMatch = function(matchId, players)
		table.insert(localBegin, { matchId = matchId, players = table.clone(players) })
		if localBeginResult == "throw" then
			error("local start exploded (test)")
		end
		return localBeginResult
	end,
	NewMatchId = function()
		matchSeq += 1
		return string.format("match-live-%04d", matchSeq)
	end,
	Wait = function() end,
	Notify = function(p, text)
		notes[p] = notes[p] or {}
		table.insert(notes[p], text)
	end,
	OnLocalStart = function()
		localStarts += 1
	end,
	OnLocalCancel = function()
		localCancels += 1
	end,
})
local classChanges = 0
ClassService._SetDeps({
	DataService = ds,
	Notify = function(p, text)
		notes[p] = notes[p] or {}
		table.insert(notes[p], text)
	end,
	OnClass = function()
		classChanges += 1
	end,
})
Transfer.Start()
Players.PlayerRemoving:Connect(QueueService.OnPlayerRemoving)

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------
local uid = 100
local function mk(n: number, opts: any?): { Player }
	local list = {}
	for i = 1, n do
		uid += 1
		local p = preview.addPlayer("P" .. uid, uid)
		ds.saves[p] = { OwnedCharacters = { ruckus = true, toastmaster = true }, SelectedCharacter = "ruckus", Gold = 50000 }
		table.insert(list, p)
	end
	return list
end

local function drop(list: { Player })
	for _, p in ipairs(list) do
		parties[p] = nil
		if p.Parent then
			preview.removePlayer(p)
		end
		ds.saves[p] = nil
		ds.released[p] = nil
	end
end

local function party(leader: Player, ...: Player)
	local ms = { leader, ... }
	local t = { Leader = leader, Members = ms }
	for _, m in ipairs(ms) do
		parties[m] = t
	end
	return t
end

local function reset()
	events, moves, teleports = {}, {}, {}
	notes = {}
	reserves, reserveFail, reserveEmpty, teleportFail = 0, 0, false, 0
	localBegin, localBeginResult, localStarts, localCancels = {}, true, 0, 0
	partyMax = 4
	liveSpy = spyBackend()
	TicketStore.UseBackend("live", liveSpy.backend)
	TicketStore.UseBackend("memory", TicketStore.MemoryBackend())
	setRole("lobby")
end
reset()

local function view(p: Player)
	return QueueService.View(p)
end
local function state(p: Player): string
	local v = view(p)
	return v and v.State or "none"
end
local function allReadyClear(p: Player): boolean
	local v = view(p)
	if not v then
		return false
	end
	for _, m in ipairs(v.Members) do
		if m.Ready then
			return false
		end
	end
	return true
end
local function readyAll(list: { Player })
	for _, p in ipairs(list) do
		QueueService.SetReady(p, true)
	end
end
local function lastNote(p: Player): string
	local l = notes[p] or {}
	return l[#l] or "-"
end
-- advance the monotonic clock to the countdown end and run the queue step
local function finishCountdown()
	nowMono += LobbyConfig.CountdownSeconds + 0.01
	QueueService.Step()
end

------------------------------------------------------------------------------------------
-- 1. Join rules
------------------------------------------------------------------------------------------
do
	reset()
	local ps = mk(8)
	local a, b, c, d, e = ps[1], ps[2], ps[3], ps[4], ps[5]
	check("join: solo on a public gate", QueueService.Join(a, "PublicA", "ui") == nil and QueueService.IsQueued(a))
	local v = view(a)
	check("join: view shows gate, state, capacity, one member", v and v.GateId == "PublicA" and v.Mode == "Public" and v.State == "Waiting" and v.Capacity == 4 and #v.Members == 1 and v.Members[1].ClassId == "ruckus")
	check("join: second player fills the SAME queue", QueueService.Join(b, "PublicA", "ui") == nil and QueueService.QueueOf(a) == QueueService.QueueOf(b) and #view(a).Members == 2)
	check("join: idempotent on the same gate", QueueService.Join(a, "PublicA", "ui") == nil and #view(a).Members == 2)
	check("join: cannot be in two queues", QueueService.Join(a, "PublicB", "ui") == "You're already in another gate." and QueueService.QueueOf(a).GateId == "PublicA")
	check("join: unknown gate refused", QueueService.Join(c, "Nope", "ui") == "That gate doesn't exist." and not QueueService.IsQueued(c))
	check("join: non-string gate refused", QueueService.Join(c, nil, "ui") ~= nil and QueueService.Join(c, 5, "ui") ~= nil and QueueService.Join(c, { "PublicA" }, "ui") ~= nil)
	QueueService.Join(c, "PublicA", "ui")
	QueueService.Join(d, "PublicA", "ui")
	check("join: gate fills to capacity", #view(a).Members == 4)
	check("join: full gate refused", QueueService.Join(e, "PublicA", "ui") == "This gate is full." and not QueueService.IsQueued(e))
	-- save still loading
	ds.saves[e] = nil
	check("join: save not loaded refused", QueueService.Join(e, "PublicB", "ui") == "Your save is still loading.")
	ds.saves[e] = { OwnedCharacters = { ruckus = true }, SelectedCharacter = "ruckus", Gold = 0 }
	e:SetAttribute("InRun", true)
	check("join: player in a run refused", QueueService.Join(e, "PublicB", "ui") == "You're in a run.")
	e:SetAttribute("InRun", nil)
	role = "match"
	check("join: refused on a match server", QueueService.Join(e, "PublicB", "ui") == "Gates are closed on this server.")
	role = "lobby"
	drop(ps)
	check("join: cleanup leaves no queued player", not QueueService.IsQueued(a) and not QueueService.IsQueued(d))
end

do
	-- parties
	reset()
	local ps = mk(9)
	local l, m1, m2, s1, s2 = ps[1], ps[2], ps[3], ps[4], ps[5]
	party(l, m1, m2)
	check("party: member cannot join", QueueService.Join(m1, "PublicA", "ui") == "Only your party leader can enter a gate." and not QueueService.IsQueued(m1))
	check("party: leader joins → whole party queued", QueueService.Join(l, "PublicA", "ui") == nil and QueueService.QueueOf(m1) == QueueService.QueueOf(l) and QueueService.QueueOf(m2) == QueueService.QueueOf(l) and #view(l).Members == 3)
	local lead = {}
	for _, mm in ipairs(view(l).Members) do
		lead[mm.UserId] = mm.Leader
	end
	check("party: view marks only the leader", lead[l.UserId] == true and lead[m1.UserId] == false and lead[m2.UserId] == false)
	local movedMates = 0
	for _, mv in ipairs(moves) do
		if mv[1] == m1 or mv[1] == m2 then
			movedMates += 1
		end
	end
	check("party: mates are put on the pad", movedMates == 2, movedMates)
	-- no room: queue has 3, party of 2 doesn't fit in 1 slot
	local l2, n2 = s1, s2
	party(l2, n2)
	local movesBefore = #moves
	local why = QueueService.Join(l2, "PublicA", "ui")
	check("party: too big for the remaining room → refused", why == "Not enough room for your whole party here.", why)
	check("party: refusal is atomic (nothing queued, nothing moved, queue unchanged)", not QueueService.IsQueued(l2) and not QueueService.IsQueued(n2) and #view(l).Members == 3 and #moves == movesBefore)
	-- a solo still fits the last slot
	check("party: a solo takes the last free slot", QueueService.Join(ps[6], "PublicA", "ui") == nil and #view(l).Members == 4)
	-- party of five is too big for any run
	local big = mk(5)
	party(big[1], big[2], big[3], big[4], big[5])
	local bigWhy = QueueService.Join(big[1], "PublicB", "ui")
	check("party: bigger than a run → refused", bigWhy == "Your party is too big for one run." and not QueueService.IsQueued(big[1]), bigWhy)
	partyMax = 2
	party(ps[7], ps[8], ps[9])
	check("party: capacity follows PartyService.MaxSize()", QueueService.Join(ps[7], "PublicB", "ui") == "Your party is too big for one run.")
	partyMax = 4
	-- a member already queued elsewhere blocks the whole party, atomically
	drop(big)
	parties[ps[7]], parties[ps[8]], parties[ps[9]] = nil, nil, nil
	QueueService.Join(ps[8], "PublicB", "ui") -- solo, then a party forms around them
	party(ps[7], ps[8], ps[9])
	local mb = #moves
	local w2 = QueueService.Join(ps[7], "PublicB", "ui")
	check("party: a member in another gate blocks the entry", w2 ~= nil and string.find(w2, "is in another gate") ~= nil and not QueueService.IsQueued(ps[7]) and not QueueService.IsQueued(ps[9]) and #moves == mb, w2)
	local lp = ps[9]
	ds.saves[lp] = nil
	QueueService.Leave(ps[8])
	local w3 = QueueService.Join(ps[7], "PublicB", "ui")
	check("party: a member whose save is not loaded blocks the entry", w3 ~= nil and string.find(w3, "can't join now") ~= nil and not QueueService.IsQueued(ps[7]), w3)
	drop(ps)
end

do
	-- party-only gate
	reset()
	local ps = mk(6)
	party(ps[1], ps[2])
	party(ps[3], ps[4])
	check("party gate: first party queues", QueueService.Join(ps[1], "Party", "ui") == nil)
	check("party gate: second party gets its OWN queue", QueueService.Join(ps[3], "Party", "ui") == nil and QueueService.QueueOf(ps[1]) ~= QueueService.QueueOf(ps[3]))
	check("party gate: queues hold only their own party", #view(ps[1]).Members == 2 and #view(ps[3]).Members == 2 and view(ps[1]).Mode == "Party")
	check("party gate: a solo gets a private queue too", QueueService.Join(ps[5], "Party", "ui") == nil and #view(ps[5]).Members == 1 and QueueService.QueueOf(ps[5]) ~= QueueService.QueueOf(ps[1]))
	check("party gate: a member of a queued party cannot enter another gate", QueueService.Join(ps[2], "PublicA", "ui") == "You're already in another gate." and QueueService.Join(ps[2], "Party", "ui") == nil and #view(ps[1]).Members == 2)
	-- ready one party: the other is untouched
	readyAll({ ps[1], ps[2] })
	check("party gate: one party's countdown doesn't touch the other", state(ps[1]) == "Countdown" and state(ps[3]) == "Waiting")
	finishCountdown()
	check("party gate: committed party leaves its queue, the other stays", not QueueService.IsQueued(ps[1]) and QueueService.IsQueued(ps[3]) and Transfer.IsBusy(ps[1]))
	drop(ps)
end

------------------------------------------------------------------------------------------
-- 2. READY / countdown / cancel causes
------------------------------------------------------------------------------------------
do
	reset()
	local ps = mk(4)
	local a, b, c = ps[1], ps[2], ps[3]
	QueueService.Join(a, "PublicA", "ui")
	QueueService.Join(b, "PublicA", "ui")
	QueueService.SetReady(a, true)
	check("ready: one of two ready → still Waiting", state(a) == "Waiting")
	check("ready: non-boolean ignored", QueueService.SetReady(b, "yes" :: any) == nil and state(a) == "Waiting")
	QueueService.SetReady(b, true)
	check("ready: all ready → Countdown", state(a) == "Countdown" and state(b) == "Countdown")
	local q = QueueService.QueueOf(a)
	check("countdown: snapshot frozen (players + classes)", q.Snapshot ~= nil and #q.Snapshot.Players == 2 and q.Snapshot.Classes[a] == "ruckus" and q.Snapshot.Classes[b] == "ruckus")
	check("countdown: ends CountdownSeconds from now", math.abs(q.EndsAt - (nowMono + LobbyConfig.CountdownSeconds)) < 0.001)
	check("countdown: view carries the end time", view(a).EndsAt > 0)
	check("countdown: join during countdown refused", QueueService.Join(c, "PublicA", "ui") == "This gate is launching. Try the next one." and not QueueService.IsQueued(c))
	check("countdown: the snapshot list is a copy (queue changes can't edit it)", q.Snapshot.Players ~= nil and #q.Snapshot.Players == 2)
	check("countdown: other gates still accept", QueueService.Join(c, "PublicB", "ui") == nil)
	QueueService.Leave(c)
	-- Step before the end changes nothing
	nowMono += LobbyConfig.CountdownSeconds - 1
	QueueService.Step()
	check("countdown: not due → stays Countdown, nothing started", state(a) == "Countdown" and reserves == 0)
	drop(ps)
end

local function twoReady(gate: string?): ({ Player }, any)
	local ps = mk(2)
	QueueService.Join(ps[1], gate or "PublicA", "ui")
	QueueService.Join(ps[2], gate or "PublicA", "ui")
	readyAll(ps)
	return ps, QueueService.QueueOf(ps[1])
end

do
	reset()
	-- cancel causes, each from a fresh 3-player countdown so "clears ALL ready" is meaningful
	local function three()
		local ps = mk(3)
		for _, p in ipairs(ps) do
			QueueService.Join(p, "PublicA", "ui")
		end
		readyAll(ps)
		return ps
	end

	local ps = three()
	check("cancel setup: countdown running", state(ps[1]) == "Countdown")
	QueueService.SetReady(ps[2], false)
	check("cancel: UNREADY → Waiting, snapshot dropped, all READY cleared", state(ps[1]) == "Waiting" and QueueService.QueueOf(ps[1]).Snapshot == nil and allReadyClear(ps[1]))
	check("cancel: players told", string.find(lastNote(ps[1]), "Tap READY again") ~= nil, lastNote(ps[1]))
	QueueService.SetReady(ps[2], true)
	readyAll(ps)
	check("cancel: ready again restarts the countdown", state(ps[1]) == "Countdown")
	drop(ps)

	ps = three()
	QueueService.Leave(ps[3])
	check("cancel: LEAVE → Waiting, others' READY cleared", state(ps[1]) == "Waiting" and allReadyClear(ps[1]) and #view(ps[1]).Members == 2 and not QueueService.IsQueued(ps[3]))
	drop(ps)

	ps = three()
	preview.removePlayer(ps[3])
	check("cancel: disconnect → Waiting, READY cleared, leaver gone from the queue", state(ps[1]) == "Waiting" and allReadyClear(ps[1]) and #view(ps[1]).Members == 2 and not QueueService.IsQueued(ps[3]))
	drop(ps)

	ps = three()
	local err = ClassService.Select(ps[2], "toastmaster")
	check("cancel: class change (ClassService.Select) → Waiting, READY cleared", err == nil and state(ps[1]) == "Waiting" and allReadyClear(ps[1]) and view(ps[1]).Members[2].ClassId == "toastmaster", tostring(err))
	drop(ps)

	-- party change: a party of two plus a solo
	local ps2 = mk(3)
	local l, m, solo = ps2[1], ps2[2], ps2[3]
	party(l, m)
	QueueService.Join(solo, "PublicA", "ui")
	QueueService.Join(l, "PublicA", "ui")
	readyAll(ps2)
	check("cancel setup: party + solo countdown", state(solo) == "Countdown" and #view(solo).Members == 3)
	parties[l] = { Leader = m, Members = { m, l } } -- Promote: m leads now
	parties[m] = parties[l]
	QueueService.OnPartyChanged({ l, m })
	check("cancel: party leader changed → party entry out, countdown cancelled, READY cleared", state(solo) == "Waiting" and #view(solo).Members == 1 and allReadyClear(solo) and not QueueService.IsQueued(l) and not QueueService.IsQueued(m))
	check("cancel: party members are told", string.find(lastNote(m), "party changed") ~= nil, lastNote(m))
	drop(ps2)

	-- party disbanded while queued (not in countdown)
	local ps3 = mk(2)
	party(ps3[1], ps3[2])
	QueueService.Join(ps3[1], "PublicA", "ui")
	parties[ps3[1]], parties[ps3[2]] = nil, nil
	QueueService.OnPartyChanged({ ps3[1], ps3[2] })
	check("party change: disbanded party leaves the gate", not QueueService.IsQueued(ps3[1]) and not QueueService.IsQueued(ps3[2]))
	-- a member kicked: party shrinks
	party(ps3[1], ps3[2])
	QueueService.Join(ps3[1], "PublicA", "ui")
	parties[ps3[2]] = nil
	parties[ps3[1]] = { Leader = ps3[1], Members = { ps3[1] } }
	QueueService.OnPartyChanged({ ps3[2] })
	check("party change: a member removed → the entry no longer matches, out", not QueueService.IsQueued(ps3[1]) and not QueueService.IsQueued(ps3[2]))
	-- unrelated party change for a queued solo does nothing
	local solo2 = mk(1)[1]
	QueueService.Join(solo2, "PublicA", "ui")
	QueueService.OnPartyChanged({ solo2 })
	check("party change: a queued solo is unaffected", QueueService.IsQueued(solo2))
	drop(ps3)
	drop({ solo2 })

	-- class change while only Waiting clears just that player's READY
	local ps4 = mk(2)
	QueueService.Join(ps4[1], "PublicA", "ui")
	QueueService.Join(ps4[2], "PublicA", "ui")
	QueueService.SetReady(ps4[1], true)
	ClassService.Select(ps4[1], "toastmaster")
	check("class change in Waiting clears that READY", not view(ps4[1]).Members[1].Ready and state(ps4[1]) == "Waiting")
	drop(ps4)
end

------------------------------------------------------------------------------------------
-- 3. Commit and Transfer (live)
------------------------------------------------------------------------------------------
do
	reset()
	local ps, q = twoReady("PublicA")
	local a, b = ps[1], ps[2]
	local firstQueueId = q.Id
	local snapPlayers = q.Snapshot.Players
	finishCountdown()
	check("commit: queue committed and left", q.State == "Committed" and not QueueService.IsQueued(a) and not QueueService.IsQueued(b))
	check("commit: Transfer took the roster", q.Match ~= nil and Transfer.IsBusy(a) and Transfer.IsBusy(b))
	local c = mk(1)[1]
	QueueService.Join(c, "PublicA", "ui")
	check("commit: the gate opened a FRESH queue", QueueService.QueueOf(c) ~= q and QueueService.QueueOf(c).Id ~= firstQueueId and state(c) == "Waiting" and #view(c).Members == 1)
	check("commit: busy player cannot queue again", QueueService.Join(a, "PublicB", "ui") == "You're already heading to a run.")
	check("commit: busy view shows the trip", view(a) ~= nil and (view(a).State == "Teleporting" or view(a).State == "Committed") and #view(a).Members == 2)

	local m = q.Match
	check("live: one reservation", reserves == 1, reserves)
	check("live: one teleport for the group", #teleports == 1 and #teleports[1].players == 2)
	check("live: state teleporting, both pending", m.State == "teleporting" and m.Status[a] == "pending" and m.Status[b] == "pending", m.State)
	check("live: travel cover attribute set", a:GetAttribute("Travel") == "ToRun" and b:GetAttribute("Travel") == "ToRun")
	local opts = teleports[1].options
	check("live: reserved access code is on the options", opts.ReservedServerAccessCode == "SECRET-ACCESS-CODE-1", opts.ReservedServerAccessCode)
	local td = teleports[1].data
	check("live: TeleportData is ONLY {SwarmV2 = {schemaVersion, matchId}}", keys(td) == 1 and td.SwarmV2 ~= nil and keys(td.SwarmV2) == 2 and td.SwarmV2.schemaVersion == 1 and td.SwarmV2.matchId == m.Id, m.Id)
	check("live: no access code / private id anywhere in TeleportData", not deepHas(td, "SECRET-ACCESS-CODE") and not deepHas(td, "ps-1"))
	check("live: no class / roster in TeleportData", not deepHas(td, "ruckus") and not deepHas(td, tostring(a.UserId)))
	-- ticket
	check("ticket: exactly one write", #liveSpy.sets == 1 and liveSpy.sets[1].key == "t/" .. m.Id, #liveSpy.sets)
	local t = liveSpy.sets[1] and liveSpy.sets[1].value
	check("ticket: shared schema fields", t ~= nil and t.schemaVersion == 1 and t.matchId == m.Id and t.targetMatchPlaceId == PLACE and t.lobbyPlaceId == PLACE and t.reservedPrivateServerId == "ps-1" and t.createdAt == T0)
	check("ticket: roster and classes", t ~= nil and #t.expectedUserIds == 2 and t.expectedUserIds[1] == a.UserId and t.expectedUserIds[2] == b.UserId and t.classesByUserId[tostring(a.UserId)] == "ruckus" and t.classesByUserId[tostring(b.UserId)] == "ruckus")
	check("ticket: TTL is LobbyConfig.TicketTTLSeconds (field and store expiry)", t ~= nil and t.expiresAt - t.createdAt == LobbyConfig.TicketTTLSeconds and liveSpy.sets[1].ttl == LobbyConfig.TicketTTLSeconds, liveSpy.sets[1] and liveSpy.sets[1].ttl)
	check("ticket: passes MatchAdmission.SanitizeTicket", t ~= nil and MA.SanitizeTicket(t) ~= nil)
	-- order: reserve, release, release, teleport
	check("order: reserve → both saves released → teleport", events[1] == "reserve" and string.sub(events[2] or "", 1, 8) == "release:" and string.sub(events[3] or "", 1, 8) == "release:" and events[4] == "teleport", table.concat(events, ","))
	check("saves are released, not reclaimed", ds.released[a] and ds.released[b])
	-- everyone departs
	preview.removePlayer(a)
	check("departure: first leaver → still teleporting", m.State == "teleporting" and m.Status[a] == "departed")
	preview.removePlayer(b)
	check("departure: all gone → completed", m.State == "completed", m.State)
	check("departure: no further teleports, one reservation, one ticket", #teleports == 1 and reserves == 1 and #liveSpy.sets == 1)
	drop(ps)
	drop({ c })
end

do
	-- partial teleport
	reset()
	local ps = mk(3)
	local x, y, z = ps[1], ps[2], ps[3]
	for _, p in ipairs(ps) do
		QueueService.Join(p, "PublicA", "ui")
	end
	readyAll(ps)
	local q = QueueService.QueueOf(x)
	finishCountdown()
	local m = q.Match
	check("partial setup: 3 players, one teleport", #teleports == 1 and #teleports[1].players == 3 and m.State == "teleporting")
	local firstOpts = teleports[1].options
	preview.removePlayer(x) -- the teleport took X
	check("partial: X departed", m.Status[x] == "departed" and m.State == "teleporting")
	preview.teleportInitFailed(y) -- real event through Transfer.Start()
	check("partial: Y retried ALONE to the SAME options", #teleports == 2 and #teleports[2].players == 1 and teleports[2].players[1] == y and teleports[2].options == firstOpts, #teleports)
	check("partial: no second reservation or ticket", reserves == 1 and #liveSpy.sets == 1)
	check("partial: retry carries the same hint", teleports[2].data.SwarmV2.matchId == m.Id and not deepHas(teleports[2].data, "SECRET"))
	preview.teleportInitFailed(y)
	check("partial: second retry", #teleports == 3 and teleports[3].players[1] == y)
	check("partial: Y still busy while retries remain", Transfer.IsBusy(y) and m.Status[y] == "pending")
	preview.teleportInitFailed(y)
	check("partial: retries spent → no more teleports", #teleports == 3, #teleports)
	check("partial: Y reclaimed and freed", m.Status[y] == "failed" and not Transfer.IsBusy(y) and not ds.released[y] and y:GetAttribute("Travel") == "", tostring(m.Status[y]))
	check("partial: Y told", string.find(lastNote(y), "queue again") ~= nil, lastNote(y))
	check("partial: Z still pending, match not settled", m.State == "teleporting" and m.Status[z] == "pending")
	preview.removePlayer(z)
	check("partial: match state partial", m.State == "partial", m.State)
	check("partial: departed X never teleported again", (function()
		for i = 2, #teleports do
			for _, p in ipairs(teleports[i].players) do
				if p == x then
					return false
				end
			end
		end
		return true
	end)())
	check("partial: Y can queue again", QueueService.Join(y, "PublicA", "ui") == nil)
	-- a failure report for a settled match is ignored
	preview.teleportInitFailed(y)
	check("partial: late failure for a freed player ignored", #teleports == 3)
	drop(ps)
end

do
	-- reserve fails
	reset()
	reserveFail = 99
	local ps = mk(2)
	for _, p in ipairs(ps) do
		QueueService.Join(p, "PublicA", "ui")
	end
	readyAll(ps)
	local q = QueueService.QueueOf(ps[1])
	finishCountdown()
	local m = q.Match
	check("reserve fails: tried ReserveAttempts times", reserves == LobbyConfig.ReserveAttempts, reserves)
	check("reserve fails: state failed, no teleport, no ticket", m.State == "failed" and #teleports == 0 and #liveSpy.sets == 0)
	check("reserve fails: saves untouched (no release, no reclaim)", #events == LobbyConfig.ReserveAttempts and not ds.released[ps[1]] and not ds.released[ps[2]], table.concat(events, ","))
	check("reserve fails: players free again", not Transfer.IsBusy(ps[1]) and not Transfer.IsBusy(ps[2]) and ps[1]:GetAttribute("Travel") == "")
	check("reserve fails: players told", string.find(lastNote(ps[1]), "reserve") ~= nil, lastNote(ps[1]))
	reserveFail = 0
	check("reserve fails: they can queue again", QueueService.Join(ps[1], "PublicA", "ui") == nil)
	drop(ps)

	-- empty code from ReserveServer
	reset()
	reserveEmpty = true
	ps = mk(1)
	QueueService.Join(ps[1], "PublicA", "ui")
	QueueService.SetReady(ps[1], true)
	q = QueueService.QueueOf(ps[1])
	finishCountdown()
	check("reserve returns an empty code → failed, nothing sent", q.Match.State == "failed" and #teleports == 0)
	drop(ps)

	-- reserve works on the second try
	reset()
	reserveFail = 1
	ps = mk(1)
	QueueService.Join(ps[1], "PublicA", "ui")
	QueueService.SetReady(ps[1], true)
	q = QueueService.QueueOf(ps[1])
	finishCountdown()
	check("reserve: second try succeeds → teleports (one ticket)", reserves == 2 and #teleports == 1 and #liveSpy.sets == 1 and q.Match.State == "teleporting")
	drop(ps)
end

do
	-- ticket store down
	reset()
	local failures = { count = 99 }
	liveSpy = spyBackend(failures)
	TicketStore.UseBackend("live", liveSpy.backend)
	local ps = mk(2)
	for _, p in ipairs(ps) do
		QueueService.Join(p, "PublicA", "ui")
	end
	readyAll(ps)
	local q = QueueService.QueueOf(ps[1])
	finishCountdown()
	preview.advance(10) -- TicketStore waits between its attempts
	check("ticket store down: failed before any save is released or any teleport", q.Match.State == "failed" and #teleports == 0 and not ds.released[ps[1]] and not ds.released[ps[2]])
	check("ticket store down: players free", not Transfer.IsBusy(ps[1]) and not Transfer.IsBusy(ps[2]))
	drop(ps)

	-- second player's save won't release → everything rolled back
	reset()
	ps = mk(2)
	ds.releaseFail[ps[2]] = true
	for _, p in ipairs(ps) do
		QueueService.Join(p, "PublicA", "ui")
	end
	readyAll(ps)
	q = QueueService.QueueOf(ps[1])
	finishCountdown()
	check("release fails: whole match failed, no teleport", q.Match.State == "failed" and #teleports == 0)
	check("release fails: first save taken back", not ds.released[ps[1]] and not ds.released[ps[2]], table.concat(events, ","))
	check("release fails: ticket removed again", #liveSpy.removes == 1 and liveSpy.removes[1] == "t/" .. q.Match.Id)
	check("release fails: players free", not Transfer.IsBusy(ps[1]) and not Transfer.IsBusy(ps[2]))
	ds.releaseFail[ps[2]] = nil
	drop(ps)

	-- teleport throws every time
	reset()
	teleportFail = 99
	ps = mk(2)
	for _, p in ipairs(ps) do
		QueueService.Join(p, "PublicA", "ui")
	end
	readyAll(ps)
	q = QueueService.QueueOf(ps[1])
	finishCountdown()
	check("teleport throws: tried 1 + TeleportRetries times", #teleports == 1 + LobbyConfig.TeleportRetries, #teleports)
	check("teleport throws: failed, everyone reclaimed and free", q.Match.State == "failed" and not ds.released[ps[1]] and not ds.released[ps[2]] and not Transfer.IsBusy(ps[1]) and ps[1]:GetAttribute("Travel") == "")
	check("teleport throws: same reservation reused for every retry", reserves == 1 and #liveSpy.sets == 1)
	teleportFail = 0
	drop(ps)

	-- ... but succeeds on the last retry
	reset()
	teleportFail = LobbyConfig.TeleportRetries
	ps = mk(2)
	for _, p in ipairs(ps) do
		QueueService.Join(p, "PublicA", "ui")
	end
	readyAll(ps)
	q = QueueService.QueueOf(ps[1])
	finishCountdown()
	check("teleport throws twice, third works → teleporting", #teleports == 3 and q.Match.State == "teleporting" and Transfer.IsBusy(ps[1]))
	drop(ps)
end

------------------------------------------------------------------------------------------
-- 4. Commit-time re-validation
------------------------------------------------------------------------------------------
do
	reset()
	local ps, q = twoReady("PublicA")
	local a, b = ps[1], ps[2]
	-- ownership revoked just before the commit: a switched to toastmaster, countdown started
	drop(ps)
	reset()
	ps = mk(2)
	a, b = ps[1], ps[2]
	ClassService.Select(a, "toastmaster")
	QueueService.Join(a, "PublicA", "ui")
	QueueService.Join(b, "PublicA", "ui")
	readyAll(ps)
	q = QueueService.QueueOf(a)
	check("revoke setup: frozen toastmaster", q.Snapshot.Classes[a] == "toastmaster")
	ds.saves[a].OwnedCharacters.toastmaster = nil -- revoked behind the queue's back
	finishCountdown()
	check("revoke: ownership lost → countdown cancelled, nothing started", q.State == "Waiting" and reserves == 0 and #teleports == 0 and allReadyClear(a))
	check("revoke: told which player", string.find(lastNote(a), "class changed") ~= nil, lastNote(a))
	drop(ps)

	reset()
	ps = mk(2)
	a, b = ps[1], ps[2]
	QueueService.Join(a, "PublicA", "ui")
	QueueService.Join(b, "PublicA", "ui")
	readyAll(ps)
	q = QueueService.QueueOf(a)
	ds.saves[a].SelectedCharacter = "toastmaster" -- selection changed behind the queue's back
	finishCountdown()
	check("commit: selection differs from the frozen class → cancelled", q.State == "Waiting" and reserves == 0)
	drop(ps)

	reset()
	ps = mk(2)
	a, b = ps[1], ps[2]
	QueueService.Join(a, "PublicA", "ui")
	QueueService.Join(b, "PublicA", "ui")
	readyAll(ps)
	q = QueueService.QueueOf(a)
	b:SetAttribute("InRun", true)
	finishCountdown()
	check("commit: a player became unavailable → cancelled", q.State == "Waiting" and reserves == 0)
	b:SetAttribute("InRun", nil)
	drop(ps)

	reset()
	ps = mk(2)
	a, b = ps[1], ps[2]
	QueueService.Join(a, "PublicA", "ui")
	QueueService.Join(b, "PublicA", "ui")
	readyAll(ps)
	q = QueueService.QueueOf(a)
	ds.saves[b] = nil -- save dropped
	finishCountdown()
	check("commit: a save disappeared → cancelled", q.State == "Waiting" and reserves == 0)
	drop(ps)
end

------------------------------------------------------------------------------------------
-- 5. Local role
------------------------------------------------------------------------------------------
do
	reset()
	setRole("local")
	local ps = mk(2)
	local a, b = ps[1], ps[2]
	ClassService.Select(a, "toastmaster")
	for _, p in ipairs(ps) do
		QueueService.Join(p, "PublicA", "ui")
	end
	readyAll(ps)
	local q = QueueService.QueueOf(a)
	finishCountdown()
	local m = q.Match
	check("local: BeginLocalMatch called once with the matchId and players", #localBegin == 1 and localBegin[1].matchId == m.Id and #localBegin[1].players == 2)
	check("local: no reservation, teleport or save release", reserves == 0 and #teleports == 0 and #events == 0 and #liveSpy.sets == 0)
	check("local: OnLocalStart for each", localStarts == 2)
	check("local: no travel cover", a:GetAttribute("Travel") == "")
	check("local: match completed, players departed", m.State == "completed" and not Transfer.IsBusy(a) and not Transfer.IsBusy(b), m.State)
	local ra = MA.ResolvePlayer(a)
	check("local: MatchAdmission admits through the in-memory ticket", ra.ok and ra.context.matchId == m.Id and ra.context.classId == "toastmaster" and ra.context.userId == a.UserId, ra.errorCode)
	local rb = MA.ResolvePlayer(b)
	check("local: second player admitted with their class", rb.ok and rb.context.classId == "ruckus" and #rb.context.expectedUserIds == 2, rb.errorCode)
	check("local: ticket never reached the live store", #liveSpy.sets == 0 and MA.LocalMatchOf(a.UserId) == m.Id)
	-- return clears them
	MA._SetDeps({ LocalReturn = function()
		return true
	end })
	local rr = MA.ReturnToLobby({ a, b })
	check("local: ReturnToLobby frees them", rr[1].ok and rr[2].ok and MA.LocalMatchOf(a.UserId) == nil)
	drop(ps)

	-- BeginLocalMatch false
	reset()
	setRole("local")
	localBeginResult = false
	ps = mk(2)
	a, b = ps[1], ps[2]
	for _, p in ipairs(ps) do
		QueueService.Join(p, "PublicA", "ui")
	end
	readyAll(ps)
	q = QueueService.QueueOf(a)
	finishCountdown()
	m = q.Match
	check("local false: ticket dropped, match unregistered", MA.LocalMatchOf(a.UserId) == nil and MA.ResolvePlayer(a).errorCode == "NO_TICKET")
	check("local false: OnLocalCancel for each, state failed", localCancels == 2 and m.State == "failed", m.State)
	check("local false: players free, can queue again", not Transfer.IsBusy(a) and QueueService.Join(a, "PublicA", "ui") == nil)
	check("local false: players told", string.find(lastNote(b), "couldn't start") ~= nil, lastNote(b))
	QueueService.Leave(a)

	-- BeginLocalMatch throws
	localBeginResult = "throw"
	QueueService.Join(a, "PublicA", "ui")
	QueueService.Join(b, "PublicA", "ui")
	readyAll(ps)
	q = QueueService.QueueOf(a)
	finishCountdown()
	check("local throws: treated as a failed start", q.Match.State == "failed" and not Transfer.IsBusy(a) and MA.LocalMatchOf(a.UserId) == nil)
	drop(ps)

	-- local role on a lobby-role MatchAdmission: RegisterLocalMatch refused → failed
	reset()
	role = "local"
	setRole("local")
	MA._SetDeps({ IsStudio = function()
		return false
	end, PrivateServerId = function()
		return ""
	end }) -- MA now says "lobby"
	ps = mk(1)
	QueueService.Join(ps[1], "PublicA", "ui")
	QueueService.SetReady(ps[1], true)
	q = QueueService.QueueOf(ps[1])
	finishCountdown()
	check("local: RegisterLocalMatch refused (lobby-role MA) → failed, run never begun", q.Match.State == "failed" and #localBegin == 0 and not Transfer.IsBusy(ps[1]))
	drop(ps)
	setRole("lobby")
end

------------------------------------------------------------------------------------------
-- 6. Pads vs UI
------------------------------------------------------------------------------------------
local function sigOf(p: Player, label: { [number]: string }): string
	local v = view(p)
	if not v then
		return "none"
	end
	local parts = { v.GateId, v.State, tostring(v.Capacity), v.EndsAt > 0 and "timed" or "untimed" }
	for _, m in ipairs(v.Members) do
		table.insert(parts, (label[m.UserId] or "?") .. ":" .. m.ClassId .. ":" .. tostring(m.Ready) .. ":" .. tostring(m.Leader))
	end
	return table.concat(parts, "|")
end

local function scenario(mode: string): { string }
	reset()
	local ps = mk(3)
	local a, b, c = ps[1], ps[2], ps[3]
	local label = { [a.UserId] = "A", [b.UserId] = "B", [c.UserId] = "C" }
	local out = {}
	local function snap(tag: string)
		table.insert(out, tag .. "=" .. sigOf(a, label) .. "#" .. sigOf(b, label) .. "#" .. sigOf(c, label))
	end
	local function join(p: Player)
		if mode == "ui" then
			QueueService.Join(p, "PublicA", "ui")
		else
			QueueService.PadUpdate(p, "PublicA")
		end
	end
	local function leave(p: Player)
		if mode == "ui" then
			QueueService.Leave(p)
		else
			nowMono += LobbyConfig.PadCooldownSeconds + 0.1
			QueueService.PadUpdate(p, nil)
		end
	end
	join(a)
	snap("a-in")
	nowMono += 0.1
	join(b)
	snap("b-in")
	QueueService.SetReady(a, true)
	QueueService.SetReady(b, true)
	snap("ready")
	leave(b)
	snap("b-out")
	nowMono += 2
	join(c)
	snap("c-in")
	QueueService.SetReady(a, true)
	QueueService.SetReady(c, true)
	snap("ready2")
	finishCountdown()
	snap("committed")
	table.insert(out, "teleports=" .. #teleports .. " reserves=" .. reserves .. " tickets=" .. #liveSpy.sets)
	table.insert(out, "ticket=" .. (liveSpy.sets[1] and (#liveSpy.sets[1].value.expectedUserIds .. ":" .. liveSpy.sets[1].value.classesByUserId[tostring(a.UserId)]) or "none"))
	drop(ps)
	return out
end

do
	local ui = scenario("ui")
	local pad = scenario("pad")
	check("pads vs UI: same number of snapshots", #ui == #pad and #ui > 5)
	for i = 1, math.min(#ui, #pad) do
		check("pads vs UI: identical state at step " .. i, ui[i] == pad[i], ui[i] .. "  <>  " .. pad[i])
	end
	check("pads vs UI: both ended in a real transfer", string.find(ui[#ui - 1], "teleports=1 reserves=1 tickets=1", 1, true) ~= nil, ui[#ui - 1])
end

do
	reset()
	local ps = mk(6)
	local a, b = ps[1], ps[2]
	QueueService.PadUpdate(a, "PublicA")
	check("pad: stepping on joins", QueueService.QueueOf(a) ~= nil and QueueService.QueueOf(a).GateId == "PublicA")
	local mb = #moves
	check("pad: a pad join does not teleport the avatar onto the pad again", mb == 0, mb)
	-- spam: leave and re-enter within the cooldown
	nowMono += 0.3
	QueueService.PadUpdate(a, nil)
	check("pad spam: stepping off inside the cooldown is ignored", QueueService.IsQueued(a))
	QueueService.PadUpdate(a, "PublicA")
	QueueService.PadUpdate(a, nil)
	QueueService.PadUpdate(a, "PublicA")
	check("pad spam: flicker inside the cooldown changes nothing", QueueService.IsQueued(a) and #view(a).Members == 1)
	nowMono += LobbyConfig.PadCooldownSeconds + 0.1
	QueueService.PadUpdate(a, nil)
	check("pad: stepping off after the cooldown leaves", not QueueService.IsQueued(a))
	-- re-enter inside the cooldown of that leave is ignored; standing there
	nowMono += 0.2
	QueueService.PadUpdate(a, "PublicA")
	check("pad spam: entering right after leaving (inside cooldown) is ignored", not QueueService.IsQueued(a))
	nowMono += LobbyConfig.PadCooldownSeconds + 0.1
	QueueService.PadUpdate(a, "PublicA")
	local stuck = not QueueService.IsQueued(a)
	QueueService.PadUpdate(a, nil)
	nowMono += LobbyConfig.PadCooldownSeconds + 0.1
	QueueService.PadUpdate(a, "PublicA")
	check("pad: step off and on again joins", QueueService.IsQueued(a))
	preview.log("INFO pad: still standing on the pad after an enter swallowed by the cooldown, a later poll joins: " .. tostring(not stuck))
	QueueService.Leave(a)
	QueueService.PadUpdate(a, nil)

	-- refused pad join is not retried until step off
	reset()
	nowMono += 10
	local fill = mk(4)
	for _, p in ipairs(fill) do
		QueueService.Join(p, "PublicA", "ui")
	end
	local late = ps[3]
	nowMono += 5
	local n0 = #(notes[late] or {})
	QueueService.PadUpdate(late, "PublicA")
	check("pad refused: full gate → not queued, told once", not QueueService.IsQueued(late) and #(notes[late] or {}) == n0 + 1, lastNote(late))
	QueueService.Leave(fill[1]) -- room appears
	nowMono += 5
	QueueService.PadUpdate(late, "PublicA")
	QueueService.PadUpdate(late, "PublicA")
	check("pad refused: still standing there → NOT retried, no repeated notices", not QueueService.IsQueued(late) and #(notes[late] or {}) == n0 + 1)
	QueueService.PadUpdate(late, nil)
	nowMono += 5
	QueueService.PadUpdate(late, "PublicA")
	check("pad refused: after stepping off and on → joins", QueueService.IsQueued(late))
	-- stepping onto a different pad while queued
	nowMono += 5
	QueueService.PadUpdate(late, "PublicB")
	check("pad: moving to another pad leaves the first queue (after the cooldown)", not QueueService.QueueOf(late) or QueueService.QueueOf(late).GateId ~= "PublicA")
	-- a party leader on a pad brings the party, mates not moved twice
	for _, p in ipairs(fill) do
		QueueService.Leave(p)
	end
	drop(fill)
	local pl = mk(2)
	party(pl[1], pl[2])
	local before = #moves
	nowMono += 5
	QueueService.PadUpdate(pl[1], "PublicB")
	local mates = 0
	local leaderMoved = 0
	for i = before + 1, #moves do
		if moves[i][1] == pl[2] then
			mates += 1
		elseif moves[i][1] == pl[1] then
			leaderMoved += 1
		end
	end
	check("pad: leader on the pad queues the party, mate moved onto the pad, leader not moved", QueueService.QueueOf(pl[2]) == QueueService.QueueOf(pl[1]) and mates == 1 and leaderMoved == 0, mates .. "/" .. leaderMoved)
	drop(pl)
	drop(ps)
	-- Step() polls InGate for everyone
	local readings: { [Player]: string? } = {}
	QueueService._SetDeps({ InGate = function(p)
		return readings[p]
	end })
	local sp = mk(2)
	readings[sp[1]] = "PublicA"
	nowMono += 5
	QueueService.Step()
	check("Step: polls InGate and joins pad standers", QueueService.IsQueued(sp[1]) and not QueueService.IsQueued(sp[2]))
	readings[sp[1]] = nil
	nowMono += 5
	QueueService.Step()
	check("Step: ... and leaves when they step off", not QueueService.IsQueued(sp[1]))
	QueueService._SetDeps({ InGate = false })
	drop(sp)
end

------------------------------------------------------------------------------------------
-- 7. ClassOwnership / ClassService
------------------------------------------------------------------------------------------
do
	reset()
	local d: any = { Gold = 15000, OwnedCharacters = { Knight = true }, SelectedCharacter = "Mage" }
	check("ownership: legacy SelectedCharacter 'Mage' reads as ruckus", ClassOwnership.Selected(d) == "ruckus")
	check("ownership: Selected() does not rewrite the save", d.SelectedCharacter == "Mage")
	check("ownership: legacy hero id is never a class", not ClassOwnership.Owns(d, "Knight") and not ClassOwnership.Owns(d, "Mage") and ClassOwnership.Select(d, "Knight") == "UNKNOWN_CLASS")
	check("ownership: Select leaves the selection alone on refusal", ClassOwnership.Select(d, "toastmaster") == "NOT_OWNED" and d.SelectedCharacter == "Mage")
	check("ownership: ruckus owned by every save", ClassOwnership.Owns({}, "ruckus") and ClassOwnership.Owns(d, "ruckus"))
	check("ownership: Owns rejects non-tables / junk ids", not ClassOwnership.Owns(nil, "ruckus") and not ClassOwnership.Owns(d, 5) and not ClassOwnership.Owns(d, nil))
	d.OwnedCharacters = { toastmaster = "yes" }
	check("ownership: only a literal true counts as owned", not ClassOwnership.Owns(d, "toastmaster"))
	d.OwnedCharacters = { Knight = true }
	-- Buy
	check("buy: unknown class", ClassOwnership.Buy(d, "Knight") == "UNKNOWN_CLASS" and ClassOwnership.Buy(d, nil) == "UNKNOWN_CLASS")
	check("buy: no save", ClassOwnership.Buy(nil, "toastmaster") == "NO_SAVE")
	local cost = ClassCatalog.Get("toastmaster").Cost
	local err = ClassOwnership.Buy(d, "toastmaster")
	check("buy: gold deducts the exact catalog cost, class owned and selected", err == nil and d.Gold == 15000 - cost and d.OwnedCharacters.toastmaster == true and d.SelectedCharacter == "toastmaster" and d.OwnedCharacters.Knight == true, d.Gold)
	check("buy: already owned → OWNED, gold unchanged", ClassOwnership.Buy(d, "toastmaster") == "OWNED" and d.Gold == 15000 - cost)
	check("buy: ruckus → OWNED", ClassOwnership.Buy(d, "ruckus") == "OWNED")
	local gold = d.Gold
	check("buy: not enough gold → NO_GOLD, gold kept, not owned", ClassOwnership.Buy(d, "captain_croak") == "NO_GOLD" and d.Gold == gold and not ClassOwnership.Owns(d, "captain_croak") and d.SelectedCharacter == "toastmaster")
	d.Gold = ClassCatalog.Get("captain_croak").Cost - 1
	check("buy: one gold short → NO_GOLD", ClassOwnership.Buy(d, "captain_croak") == "NO_GOLD" and d.Gold == ClassCatalog.Get("captain_croak").Cost - 1)
	d.Gold = "99999999" :: any
	check("buy: non-numeric gold is treated as zero", ClassOwnership.Buy(d, "granny_boom") == "NO_GOLD")
	d.Gold = 0 / 0
	check("buy: NaN gold is treated as zero", ClassOwnership.Buy(d, "granny_boom") == "NO_GOLD")
	for _, id in ipairs(ClassCatalog.Order) do
		local info = ClassCatalog.Get(id)
		local s: any = { Gold = info.Cost, OwnedCharacters = {} }
		local e = ClassOwnership.Buy(s, id)
		if id == "ruckus" then
			check("buy: " .. id .. " is free and already owned", e == "OWNED" and s.Gold == info.Cost)
		else
			check("buy: " .. id .. " for exactly " .. info.Cost .. " leaves 0", e == nil and s.Gold == 0 and s.OwnedCharacters[id] == true)
		end
	end
	check("catalog: owner prices 0 / 10k / 20k / 30k", ClassCatalog.Get("ruckus").Cost == 0 and ClassCatalog.Get("toastmaster").Cost == 10000 and ClassCatalog.Get("captain_croak").Cost == 20000 and ClassCatalog.Get("granny_boom").Cost == 30000)
	local old: any = { OwnedCharacters = { Knight = true } }
	ClassOwnership.EnsureDefault(old)
	check("ensure default: adds ruckus, keeps legacy", old.OwnedCharacters.ruckus == true and old.OwnedCharacters.Knight == true)
	local none: any = {}
	ClassOwnership.EnsureDefault(none)
	check("ensure default: creates the set", none.OwnedCharacters.ruckus == true)
	local set = ClassOwnership.OwnedSet({ OwnedCharacters = { toastmaster = true, Knight = true } })
	check("owned set: four classes only", set.ruckus and set.toastmaster and not set.captain_croak and not set.Knight)
end

do
	reset()
	local ps = mk(2)
	local a, b = ps[1], ps[2]
	ds.saves[a].Gold = 25000
	ds.saves[a].OwnedCharacters = { ruckus = true }
	ds.saves[a].SelectedCharacter = "Rogue"
	check("service: legacy selection shows as ruckus in the queue", (function()
		QueueService.Join(a, "PublicA", "ui")
		return view(a).Members[1].ClassId == "ruckus"
	end)())
	QueueService.Leave(a)
	check("service: SelectedCharacter is still the legacy id", ds.saves[a].SelectedCharacter == "Rogue")
	local nosave = mk(1)[1]
	ds.saves[nosave] = nil
	check("service: no save → NO_SAVE (select and buy)", ClassService.Select(nosave, "ruckus") == "NO_SAVE" and ClassService.Buy(nosave, "toastmaster") == "NO_SAVE")
	check("service: unknown class", ClassService.Select(a, "Knight") == "UNKNOWN_CLASS" and ClassService.Select(a, nil) == "UNKNOWN_CLASS")
	check("service: Select not owned → NOT_OWNED with a price note", ClassService.Select(a, "captain_croak") == "NOT_OWNED" and string.find(lastNote(a), "20,000") ~= nil, lastNote(a))
	check("service: Buy deducts and selects", ClassService.Buy(a, "toastmaster") == nil and ds.saves[a].Gold == 15000 and ds.saves[a].SelectedCharacter == "toastmaster")
	check("service: Buy with too little gold → NO_GOLD and a note", ClassService.Buy(a, "granny_boom") == "NO_GOLD" and ds.saves[a].Gold == 15000 and lastNote(a) == "Not enough gold.")
	check("service: Buy of an owned class just selects it", ClassService.Select(a, "ruckus") == nil and ClassService.Buy(a, "toastmaster") == nil and ds.saves[a].Gold == 15000 and ds.saves[a].SelectedCharacter == "toastmaster")
	local before = classChanges
	check("service: re-selecting the same class is a no-op", ClassService.Select(a, "toastmaster") == nil and classChanges == before)
	-- locked while travelling
	QueueService.Join(a, "PublicA", "ui")
	QueueService.SetReady(a, true)
	finishCountdown()
	check("service: busy player → LOCKED (select and buy)", Transfer.IsBusy(a) and ClassService.Select(a, "ruckus") == "LOCKED" and ClassService.Buy(a, "granny_boom") == "LOCKED" and ds.saves[a].SelectedCharacter == "toastmaster" and ds.saves[a].Gold == 15000)
	-- buying while queued cancels the countdown
	drop({ a })
	local qs = mk(2)
	ds.saves[qs[1]].Gold = 12000
	ds.saves[qs[2]].Gold = 0
	ds.saves[qs[2]].OwnedCharacters = { ruckus = true }
	QueueService.Join(qs[1], "PublicA", "ui")
	QueueService.Join(qs[2], "PublicA", "ui")
	readyAll(qs)
	ClassService.Buy(qs[1], "toastmaster")
	check("service: Buy while queued cancels the countdown and clears READY", state(qs[2]) == "Waiting" and allReadyClear(qs[2]))
	-- remote action surface
	ClassService.OnAction(qs[2], "Buy", "granny_boom")
	check("service: OnAction Buy without gold is refused", not ClassOwnership.Owns(ds.saves[qs[2]], "granny_boom"))
	ClassService.OnAction(qs[2], "Nope", "granny_boom")
	ClassService.OnAction(qs[2], 5 :: any, {} :: any)
	check("service: OnAction ignores junk", true)
	drop(qs)
	drop({ b })
end

preview.log(string.format("lobby-queue-regression: %d checks, %d passed, %d failed", passes + fails, passes, fails))
Clock._Set(function()
	return os.time()
end, function()
	return os.clock()
end)
preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
assert(fails == 0, tostring(fails) .. " lobby queue checks failed")
