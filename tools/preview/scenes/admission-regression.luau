-- admission-regression: SwarmV2 MatchAdmission + TicketStore against injected fakes (no server boot).
-- Roles (studio / place 0 / transfer off / reserved / VIP), ticket admission and every refusal code,
-- hostile tickets, replay across servers, one match per server, ReturnToLobby (match / local /
-- lobby role, failures, late TeleportInitFailed retries) and RegisterLocalMatch. Prints PASS / FAIL.
-- Run: render.sh admission-regression --devices pc --max-time 400
local SSS = game:GetService("ServerScriptService")
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local MAmod = SSS.SwarmV2.MatchAdmission
local TicketStore = preview.require(SSS.SwarmV2.Lobby.TicketStore)
local Clock = preview.require(SSS.SwarmV2.Lobby.Clock)
local LobbyConfig = preview.require(RS.SwarmV2.Lobby.LobbyConfig)
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

-- every test gets its own copy of the module (its own cache / bound match / return trips);
-- TicketStore and Clock stay the shared singletons.
local seq = 0
local function freshMA()
	seq += 1
	local c = MAmod:Clone()
	c.Name = "MatchAdmission_" .. seq
	c.Parent = MAmod.Parent
	return preview.require(c)
end

local T0 = 1_000_000
local nowUnix = T0
Clock._Set(function()
	return nowUnix
end, nil)

local PLACE = 4242
local M1 = "match-aaaa-0001"
local M2 = "match-bbbb-0002"

-- fake DataService
local function newDS()
	local ds: any = { saves = {}, released = {}, log = {}, releaseFail = false, reclaimFail = false, getCalls = 0 }
	function ds.GetData(p)
		ds.getCalls += 1
		return ds.saves[p]
	end
	function ds.ReleaseForTeleport(p)
		if ds.releaseFail then
			return false
		end
		ds.released[p] = true
		table.insert(ds.log, "release:" .. p.UserId)
		return true
	end
	function ds.IsReleased(p)
		return ds.released[p] == true
	end
	function ds.Reclaim(p)
		table.insert(ds.log, "reclaim:" .. p.UserId)
		if ds.reclaimFail then
			return false
		end
		ds.released[p] = nil
		return true
	end
	return ds
end

local ds = newDS()
local joinData: { [Player]: any } = {}
local jobId = "job-A"
local privateId = "ps-1"
local ownerId = 0
local studio = false
local placeId = PLACE
local waits = 0
local teleports: { any } = {}
local teleportFails = 0
local notes: { string } = {}
local localReturned: { Player } = {}

local function configure(MA: any)
	MA._SetDeps({
		DataService = ds,
		IsStudio = function()
			return studio
		end,
		PlaceId = function()
			return placeId
		end,
		PrivateServerId = function()
			return privateId
		end,
		PrivateServerOwnerId = function()
			return ownerId
		end,
		JobId = function()
			return jobId
		end,
		JoinData = function(p)
			return joinData[p]
		end,
		Teleport = function(pid, players, options)
			table.insert(teleports, { placeId = pid, players = players, options = options, data = options:GetTeleportData() })
			if teleportFails > 0 then
				teleportFails -= 1
				error("teleport refused (test)")
			end
		end,
		LocalReturn = function(p)
			table.insert(localReturned, p)
			return true
		end,
		Notify = function(p, text)
			table.insert(notes, text)
		end,
		Wait = function()
			waits += 1
		end,
	})
end

local function resetWorld()
	ds = newDS()
	joinData = {}
	jobId = "job-A"
	privateId = "ps-1"
	ownerId = 0
	studio = false
	placeId = PLACE
	waits = 0
	teleports = {}
	teleportFails = 0
	notes = {}
	localReturned = {}
	nowUnix = T0
	TicketStore.UseBackend("live", TicketStore.MemoryBackend())
	TicketStore.UseBackend("memory", TicketStore.MemoryBackend())
end

local function player(name: string, id: number): Player
	local p = preview.addPlayer(name, id)
	return p
end

local function hintFor(p: Player, matchId: string, source: number?)
	joinData[p] = { SourcePlaceId = source or PLACE, TeleportData = { SwarmV2 = { schemaVersion = 1, matchId = matchId } } }
end

local function saveOf(p: Player, owned: { string }?, selected: string?)
	local set = {}
	for _, id in ipairs(owned or {}) do
		set[id] = true
	end
	ds.saves[p] = { OwnedCharacters = set, SelectedCharacter = selected, Gold = 0 }
end

-- writes a valid ticket for these (player, class) pairs to the live store
local function writeTicket(MA: any, matchId: string, roster: { { p: Player, class: string } }, over: any?)
	local list = {}
	for _, r in ipairs(roster) do
		table.insert(list, { userId = r.p.UserId, classId = r.class })
	end
	local t = MA.BuildTicket(matchId, privateId, list)
	for k, v in pairs(over or {}) do
		t[k] = v
	end
	check("setup: ticket stored " .. matchId, TicketStore.Write("live", t))
	return t
end

local function code(r: any): string
	return r.ok and "ok" or tostring(r.errorCode)
end

local function keys(t: any): number
	local n = 0
	for _ in pairs(t) do
		n += 1
	end
	return n
end

------------------------------------------------------------------------------------------
-- 1. ServerRole
------------------------------------------------------------------------------------------
do
	resetWorld()
	local MA = freshMA()
	configure(MA)
	privateId = ""
	check("role: published lobby (no private server)", MA.ServerRole() == "lobby", MA.ServerRole())
	privateId, ownerId = "ps-1", 0
	check("role: reserved server, owner 0 → match", MA.ServerRole() == "match", MA.ServerRole())
	privateId, ownerId = "ps-1", 777
	check("role: VIP server (owner ~= 0) → lobby", MA.ServerRole() == "lobby", MA.ServerRole())
	privateId, ownerId = "", 0
	check("role: empty private id, owner 0 → lobby", MA.ServerRole() == "lobby", MA.ServerRole())
	privateId, ownerId = "ps-1", 0
	studio = true
	check("role: Studio → local", MA.ServerRole() == "local", MA.ServerRole())
	studio, placeId = false, 0
	check("role: placeId 0 → local", MA.ServerRole() == "local", MA.ServerRole())
	placeId = PLACE
	local was = LobbyConfig.TransferEnabled
	LobbyConfig.TransferEnabled = false
	check("role: TransferEnabled off → local", MA.ServerRole() == "local", MA.ServerRole())
	LobbyConfig.TransferEnabled = was
	check("role: back to match", MA.ServerRole() == "match")
end

------------------------------------------------------------------------------------------
-- 2. Valid admission
------------------------------------------------------------------------------------------
do
	resetWorld()
	local MA = freshMA()
	configure(MA)
	local a, b = player("Ava", 11), player("Ben", 12)
	saveOf(a, { "toastmaster" }, "toastmaster")
	saveOf(b, {}, nil)
	local t = writeTicket(MA, M1, { { p = a, class = "toastmaster" }, { p = b, class = "ruckus" } })
	check("ticket: schema fields", t.schemaVersion == 1 and t.matchId == M1 and t.reservedPrivateServerId == "ps-1" and t.targetMatchPlaceId == PLACE and t.lobbyPlaceId == PLACE and t.expiresAt - t.createdAt == LobbyConfig.TicketTTLSeconds and t.createdAt == T0)
	check("ticket: SanitizeTicket accepts the built ticket", MA.SanitizeTicket(t) ~= nil)
	hintFor(a, M1)
	hintFor(b, M1)
	local r = MA.ResolvePlayer(a)
	check("admit: valid ticket", r.ok == true and r.context ~= nil, code(r))
	local c = r.context
	if c then
		check("context: exact fields", c.schemaVersion == 1 and c.matchId == M1 and c.userId == 11 and c.classId == "toastmaster" and c.lobbyPlaceId == PLACE and #c.expectedUserIds == 2 and c.expectedUserIds[1] == 11 and c.expectedUserIds[2] == 12 and keys(c) == 6, "keys=" .. keys(c))
		check("context: frozen (table and roster)", table.isfrozen(c) and table.isfrozen(c.expectedUserIds))
		check("context: write is refused", not pcall(function()
			c.classId = "granny_boom"
		end))
	end
	local r2 = MA.ResolvePlayer(a)
	check("admit: repeated call returns the SAME table", r2.ok and r2.context == c)
	local rb = MA.ResolvePlayer(b)
	check("admit: second expected member also admitted (ticket not consumed)", rb.ok and rb.context ~= nil and rb.context.userId == 12 and rb.context.classId == "ruckus", code(rb))
	local stillThere = TicketStore.Read("live", M1)
	check("admit: ticket still stored after admissions", stillThere ~= nil)
	check("admit: no TeleportData secrets (hint has only schemaVersion + matchId)", keys(joinData[a].TeleportData.SwarmV2) == 2)
end

------------------------------------------------------------------------------------------
-- 3. Refusals
------------------------------------------------------------------------------------------
local function setup3()
	resetWorld()
	local MA = freshMA()
	configure(MA)
	local a = player("Ava", 11)
	saveOf(a, { "toastmaster" }, "toastmaster")
	hintFor(a, M1)
	return MA, a
end

do
	local MA, a = setup3()
	joinData[a] = nil
	check("refuse: no join data → NO_TICKET", code(MA.ResolvePlayer(a)) == "NO_TICKET")
	joinData[a] = { SourcePlaceId = PLACE }
	check("refuse: no TeleportData → NO_TICKET", code(MA.ResolvePlayer(a)) == "NO_TICKET")
	joinData[a] = { SourcePlaceId = PLACE, TeleportData = { SwarmV2 = { schemaVersion = 1, matchId = "short" } } }
	check("refuse: bad matchId in hint → NO_TICKET", code(MA.ResolvePlayer(a)) == "NO_TICKET")
	joinData[a] = { SourcePlaceId = PLACE, TeleportData = { SwarmV2 = { schemaVersion = 2, matchId = M1 } } }
	check("refuse: hint schema 2 → NO_TICKET", code(MA.ResolvePlayer(a)) == "NO_TICKET")
	joinData[a] = { SourcePlaceId = PLACE, TeleportData = { AccessCode = "x" } }
	check("refuse: foreign TeleportData → NO_TICKET", code(MA.ResolvePlayer(a)) == "NO_TICKET")
	hintFor(a, M1, 999)
	check("refuse: SourcePlaceId wrong → BAD_ORIGIN", code(MA.ResolvePlayer(a)) == "BAD_ORIGIN")
	joinData[a] = { TeleportData = { SwarmV2 = { schemaVersion = 1, matchId = M1 } } }
	check("refuse: SourcePlaceId missing → BAD_ORIGIN", code(MA.ResolvePlayer(a)) == "BAD_ORIGIN")
	hintFor(a, M1)
	check("refuse: ticket not stored → TICKET_MISSING", code(MA.ResolvePlayer(a)) == "TICKET_MISSING")
end

do
	-- store outage
	local MA, a = setup3()
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } })
	local failures = { count = 0 }
	local backing = TicketStore.Backend("live") -- keep the data
	local flaky = TicketStore.MemoryBackend(failures)
	-- copy the ticket into the flaky backend
	flaky.Set("t/" .. M1, backing.Get("t/" .. M1), 600)
	TicketStore.UseBackend("live", flaky)
	failures.count = LobbyConfig.StoreAttempts
	local r = MA.ResolvePlayer(a)
	check("outage: StoreAttempts failures → STORE_UNAVAILABLE", code(r) == "STORE_UNAVAILABLE", code(r))
	check("outage: all attempts used, none left", failures.count == 0, failures.count)
	local r2 = MA.ResolvePlayer(a)
	check("outage over: success after recovery (error not cached)", r2.ok == true, code(r2))
	-- shorter blip within the attempts still succeeds
	local MA2 = freshMA()
	configure(MA2)
	failures.count = LobbyConfig.StoreAttempts - 1
	local r3 = MA2.ResolvePlayer(a)
	check("outage: blip shorter than StoreAttempts is retried through", r3.ok == true, code(r3))
end

do
	local MA, a = setup3()
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } })
	nowUnix = T0 + LobbyConfig.TicketTTLSeconds - 1
	check("expiry: still valid 1 s before", MA.ResolvePlayer(a).ok)
	local MA2 = freshMA()
	configure(MA2)
	nowUnix = T0 + LobbyConfig.TicketTTLSeconds
	local r = MA2.ResolvePlayer(a)
	-- the memory backend drops expired rows itself, so either code is "the ticket is gone"
	check("expiry: at TTL the ticket is refused", code(r) == "TICKET_EXPIRED" or code(r) == "TICKET_MISSING", code(r))
end

do
	-- expiry judged by the ticket field, not the store's TTL: a store that kept the row
	local MA, a = setup3()
	local t = MA.BuildTicket(M1, "ps-1", { { userId = 11, classId = "toastmaster" } })
	TicketStore.Backend("live").Set("t/" .. M1, t, 100000) -- store row outlives the ticket
	nowUnix = T0 + LobbyConfig.TicketTTLSeconds + 5
	check("expiry: store row kept but expiresAt passed → TICKET_EXPIRED", code(MA.ResolvePlayer(a)) == "TICKET_EXPIRED")
end

do
	local MA, a = setup3()
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } }, { reservedPrivateServerId = "ps-OTHER" })
	check("refuse: wrong reservedPrivateServerId → WRONG_SERVER", code(MA.ResolvePlayer(a)) == "WRONG_SERVER")
end

do
	local MA, a = setup3()
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } }, { targetMatchPlaceId = 999 })
	check("refuse: wrong targetMatchPlaceId → WRONG_PLACE", code(MA.ResolvePlayer(a)) == "WRONG_PLACE")
	local MA2, a2 = setup3()
	writeTicket(MA2, M1, { { p = a2, class = "toastmaster" } }, { lobbyPlaceId = 999 })
	check("refuse: wrong lobbyPlaceId → WRONG_PLACE", code(MA2.ResolvePlayer(a2)) == "WRONG_PLACE")
end

do
	local MA, a = setup3()
	local c = player("Cy", 13)
	saveOf(c, { "toastmaster" }, "toastmaster")
	hintFor(c, M1)
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } })
	check("refuse: user not on the roster → NOT_EXPECTED", code(MA.ResolvePlayer(c)) == "NOT_EXPECTED")
	check("refuse: ... and the rostered user is fine", MA.ResolvePlayer(a).ok)
end

do
	local MA, a = setup3()
	saveOf(a, {}, nil) -- the save lacks toastmaster
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } })
	check("refuse: class not owned → NOT_OWNED", code(MA.ResolvePlayer(a)) == "NOT_OWNED")
	ds.saves[a] = { OwnedCharacters = { toastmaster = false }, Gold = 0 }
	check("refuse: owned flag false → NOT_OWNED", code(MA.ResolvePlayer(a)) == "NOT_OWNED")
	ds.saves[a] = { Gold = 0 }
	check("refuse: no OwnedCharacters at all → NOT_OWNED", code(MA.ResolvePlayer(a)) == "NOT_OWNED")
	ds.saves[a] = { OwnedCharacters = { Knight = true, Mage = true }, Gold = 0 }
	check("refuse: only legacy heroes owned → NOT_OWNED", code(MA.ResolvePlayer(a)) == "NOT_OWNED")
	ds.saves[a] = { OwnedCharacters = { toastmaster = true }, Gold = 0 }
	check("admit: ownership granted → ok", MA.ResolvePlayer(a).ok)
end

do
	local MA, a = setup3()
	ds.saves[a] = { Gold = 0 } -- brand new save: nothing owned
	writeTicket(MA, M1, { { p = a, class = "ruckus" } })
	local r = MA.ResolvePlayer(a)
	check("admit: ruckus is always owned", r.ok and r.context.classId == "ruckus", code(r))
end

------------------------------------------------------------------------------------------
-- 4. Hostile tickets
------------------------------------------------------------------------------------------
do
	local MA, a = setup3()
	local base = MA.BuildTicket(M1, "ps-1", { { userId = 11, classId = "toastmaster" } })
	local function variant(mut: (any) -> ())
		local t = table.clone(base)
		t.expectedUserIds = table.clone(base.expectedUserIds)
		t.classesByUserId = table.clone(base.classesByUserId)
		mut(t)
		return t
	end
	local cases: { { any } } = {
		{ "schemaVersion 2", variant(function(t) t.schemaVersion = 2 end) },
		{ "schemaVersion missing", variant(function(t) t.schemaVersion = nil end) },
		{ "legacy class id Knight", variant(function(t) t.classesByUserId["11"] = "Knight" end) },
		{ "unknown class id", variant(function(t) t.classesByUserId["11"] = "ruckus2" end) },
		{ "class missing for the id", variant(function(t) t.classesByUserId = {} end) },
		{ "duplicate ids", variant(function(t) t.expectedUserIds = { 11, 11 }; t.classesByUserId = { ["11"] = "ruckus" } end) },
		{ "more than 4 ids", variant(function(t)
			t.expectedUserIds = { 11, 12, 13, 14, 15 }
			t.classesByUserId = { ["11"] = "ruckus", ["12"] = "ruckus", ["13"] = "ruckus", ["14"] = "ruckus", ["15"] = "ruckus" }
		end) },
		{ "string ids", variant(function(t) t.expectedUserIds = { "11" } end) },
		{ "NaN id", variant(function(t) t.expectedUserIds = { 0 / 0 } end) },
		{ "negative id", variant(function(t) t.expectedUserIds = { -11 }; t.classesByUserId = { ["-11"] = "ruckus" } end) },
		{ "zero id", variant(function(t) t.expectedUserIds = { 0 }; t.classesByUserId = { ["0"] = "ruckus" } end) },
		{ "fractional id", variant(function(t) t.expectedUserIds = { 1.5 }; t.classesByUserId = { ["1.5"] = "ruckus" } end) },
		{ "empty roster", variant(function(t) t.expectedUserIds = {} end) },
		{ "roster not a table", variant(function(t) t.expectedUserIds = "11" end) },
		{ "expiresAt <= createdAt", variant(function(t) t.expiresAt = t.createdAt end) },
		{ "expiresAt NaN", variant(function(t) t.expiresAt = 0 / 0 end) },
		{ "empty reserved id", variant(function(t) t.reservedPrivateServerId = "" end) },
		{ "short matchId", variant(function(t) t.matchId = "abc" end) },
		{ "matchId with slash", variant(function(t) t.matchId = "match/../0001" end) },
	}
	for _, case in ipairs(cases) do
		check("sanitize: " .. case[1] .. " → nil", MA.SanitizeTicket(case[2]) == nil)
	end
	check("sanitize: non-table → nil", MA.SanitizeTicket(nil) == nil and MA.SanitizeTicket("x") == nil and MA.SanitizeTicket(5) == nil)
	for _, case in ipairs(cases) do
		-- planted straight into the store under the hinted key
		local m = freshMA()
		configure(m)
		TicketStore.UseBackend("live", TicketStore.MemoryBackend())
		TicketStore.Backend("live").Set("t/" .. M1, case[2], 600)
		ds.saves[a] = { OwnedCharacters = { toastmaster = true } }
		local r = m.ResolvePlayer(a)
		check("hostile stored ticket (" .. case[1] .. ") → BAD_TICKET", code(r) == "BAD_TICKET", code(r))
	end
	-- a good ticket stored under another match's key
	local m = freshMA()
	configure(m)
	TicketStore.UseBackend("live", TicketStore.MemoryBackend())
	TicketStore.Backend("live").Set("t/" .. M1, m.BuildTicket(M2, "ps-1", { { userId = 11, classId = "ruckus" } }), 600)
	check("hostile: ticket whose matchId differs from the key → BAD_TICKET", code(m.ResolvePlayer(a)) == "BAD_TICKET")
	-- sanitise output is rebuilt: unknown extra fields do not survive
	local extra = variant(function(t) t.evil = "x"; t.classesByUserId["99"] = "granny_boom" end)
	local clean = MA.SanitizeTicket(extra)
	check("sanitize: extra fields dropped", clean ~= nil and (clean :: any).evil == nil and (clean :: any).classesByUserId["99"] == nil)
end

------------------------------------------------------------------------------------------
-- 5. Profile wait, player left, replay, wrong match, wrong role, bad player
------------------------------------------------------------------------------------------
do
	local MA, a = setup3()
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } })
	ds.saves[a] = nil
	waits = 0
	local r = MA.ResolvePlayer(a)
	check("profile: never loads → PROFILE_UNAVAILABLE", code(r) == "PROFILE_UNAVAILABLE", code(r))
	check("profile: wait is bounded (ProfileWaitSeconds / 0.25 steps)", waits == math.floor(LobbyConfig.ProfileWaitSeconds / 0.25), waits)
	ds.saves[a] = { OwnedCharacters = { toastmaster = true } }
	check("profile: recoverable → ok once the save is there", MA.ResolvePlayer(a).ok)
end

do
	local MA, a = setup3()
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } })
	ds.saves[a] = nil
	local MA2 = MA
	MA2._SetDeps({ Wait = function()
		waits += 1
		if waits == 3 then
			preview.removePlayer(a)
		end
	end })
	local r = MA2.ResolvePlayer(a)
	check("profile: player leaves while waiting → PLAYER_LEFT", code(r) == "PLAYER_LEFT", code(r))
end

do
	local MA, a = setup3()
	local b = player("Ben", 12)
	saveOf(b, {}, nil)
	hintFor(b, M1)
	writeTicket(MA, M1, { { p = a, class = "toastmaster" }, { p = b, class = "ruckus" } })
	check("replay: first server (job-A) admits Ava", MA.ResolvePlayer(a).ok)
	local MB = freshMA()
	configure(MB)
	MB._SetDeps({ JobId = function()
		return "job-B"
	end })
	local r = MB.ResolvePlayer(a)
	check("replay: same ticket on ANOTHER server → REPLAY", code(r) == "REPLAY", code(r))
	check("replay: another roster member on server B is still fine", MB.ResolvePlayer(b).ok)
	local MC = freshMA()
	configure(MC) -- job-A again (e.g. a retry on the same server)
	check("replay: the same server (job-A) re-admitting is fine", MC.ResolvePlayer(a).ok)
end

do
	local MA, a = setup3()
	local b = player("Ben", 12)
	saveOf(b, {}, nil)
	hintFor(b, M2)
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } })
	writeTicket(MA, M2, { { p = b, class = "ruckus" } })
	check("bound: match A admitted", MA.ResolvePlayer(a).ok)
	local r = MA.ResolvePlayer(b)
	check("bound: server bound to A refuses match B → WRONG_MATCH", code(r) == "WRONG_MATCH", code(r))
	-- the other order: B first
	local MB = freshMA()
	configure(MB)
	check("bound: fresh server takes B", MB.ResolvePlayer(b).ok)
	check("bound: ... and then refuses A", code(MB.ResolvePlayer(a)) == "WRONG_MATCH")
end

do
	local MA, a = setup3()
	writeTicket(MA, M1, { { p = a, class = "toastmaster" } })
	privateId, ownerId = "", 0
	check("role: lobby server refuses → WRONG_ROLE", code(MA.ResolvePlayer(a)) == "WRONG_ROLE")
	ownerId, privateId = 5, "ps-1"
	check("role: VIP server refuses → WRONG_ROLE", code(MA.ResolvePlayer(a)) == "WRONG_ROLE")
	privateId, ownerId = "ps-1", 0
	check("role: match again → ok", MA.ResolvePlayer(a).ok)
	check("bad player: string", code(MA.ResolvePlayer("Ava" :: any)) == "BAD_PLAYER")
	check("bad player: nil", code(MA.ResolvePlayer(nil :: any)) == "BAD_PLAYER")
	check("bad player: number", code(MA.ResolvePlayer(11 :: any)) == "BAD_PLAYER")
	check("bad player: non-Player Instance", code(MA.ResolvePlayer(Instance.new("Part") :: any)) == "BAD_PLAYER")
	local gone = player("Gone", 40)
	preview.removePlayer(gone)
	check("bad player: removed player", code(MA.ResolvePlayer(gone)) == "BAD_PLAYER")
end

------------------------------------------------------------------------------------------
-- 6. Local role + RegisterLocalMatch
------------------------------------------------------------------------------------------
do
	resetWorld()
	local MA = freshMA()
	configure(MA)
	studio = true
	local a = player("Ava", 11)
	saveOf(a, { "toastmaster" }, "toastmaster")
	local t = MA.BuildTicket(M1, "local", { { userId = 11, classId = "toastmaster" } })
	check("local: ResolvePlayer before registration → NO_TICKET", code(MA.ResolvePlayer(a)) == "NO_TICKET")
	check("local: RegisterLocalMatch accepted", MA.RegisterLocalMatch(t) == true)
	check("local: LocalMatchOf reports the match", MA.LocalMatchOf(11) == M1)
	local r = MA.ResolvePlayer(a)
	check("local: admitted through the in-memory ticket", r.ok and r.context.matchId == M1 and r.context.classId == "toastmaster", code(r))
	check("local: ticket lives in the memory backend, not the live one", TicketStore.Read("memory", M1) ~= nil and TicketStore.Read("live", M1) == nil)
	check("local: repeated call same table", MA.ResolvePlayer(a).context == r.context)
	check("local: bad ticket refused", MA.RegisterLocalMatch({ schemaVersion = 9 } :: any) == false)
	MA.EndLocalMatch(M1)
	check("local: EndLocalMatch frees the player", MA.LocalMatchOf(11) == nil and code(MA.ResolvePlayer(a)) == "NO_TICKET")
	check("local: ... and drops the ticket", TicketStore.Read("memory", M1) == nil)
	-- local ticket for a class not owned
	saveOf(a, {}, nil)
	MA.RegisterLocalMatch(MA.BuildTicket(M2, "local", { { userId = 11, classId = "granny_boom" } }))
	check("local: unowned class → NOT_OWNED", code(MA.ResolvePlayer(a)) == "NOT_OWNED")
	-- a local ticket written for a real reserved server id is not accepted locally
	MA.EndLocalMatch(M2)
	saveOf(a, { "toastmaster" }, "toastmaster")
	MA.RegisterLocalMatch(MA.BuildTicket("match-cccc-0003", "ps-1", { { userId = 11, classId = "toastmaster" } }))
	check("local: ticket for a reserved server id → WRONG_SERVER", code(MA.ResolvePlayer(a)) == "WRONG_SERVER")

	MA.EndLocalMatch("match-cccc-0003")
	-- refused on lobby / match
	studio = false
	privateId, ownerId = "", 0
	check("RegisterLocalMatch refused on a lobby server", MA.RegisterLocalMatch(MA.BuildTicket("match-dddd-0004", "local", { { userId = 11, classId = "ruckus" } })) == false)
	privateId, ownerId = "ps-1", 0
	check("RegisterLocalMatch refused on a match server", MA.RegisterLocalMatch(MA.BuildTicket("match-dddd-0004", "local", { { userId = 11, classId = "ruckus" } })) == false)
	check("RegisterLocalMatch left nothing in memory when refused", TicketStore.Read("memory", "match-dddd-0004") == nil and MA.LocalMatchOf(11) == nil)
end

------------------------------------------------------------------------------------------
-- 7. ReturnToLobby
------------------------------------------------------------------------------------------
local function setup7()
	resetWorld()
	local MA = freshMA()
	configure(MA)
	local a, b = player("Ava", 11), player("Ben", 12)
	saveOf(a, { "toastmaster" }, "toastmaster")
	saveOf(b, {}, nil)
	return MA, a, b
end

do
	local MA, a, b = setup7()
	local res = MA.ReturnToLobby({ a, b })
	check("return: both ok", #res == 2 and res[1].ok and res[2].ok and res[1].userId == 11 and res[2].userId == 12)
	check("return: exactly ONE teleport for the group", #teleports == 1 and #teleports[1].players == 2)
	check("return: destination is PlaceId", teleports[1] and teleports[1].placeId == PLACE)
	local td = teleports[1] and teleports[1].data
	check("return: TeleportData has only SwarmV2Return", td ~= nil and keys(td) == 1 and td.SwarmV2Return ~= nil and td.SwarmV2Return.schemaVersion == Types.SchemaVersion and keys(td.SwarmV2Return) == 1)
	check("return: no access code / ticket in the options", teleports[1].options.ReservedServerAccessCode == "")
	check("return: saves released (before the teleport)", ds.log[1] == "release:11" and ds.log[2] == "release:12" and ds.released[a] and ds.released[b], table.concat(ds.log, ","))
	-- second call while on the way
	local again = MA.ReturnToLobby({ a })
	check("return: second call while travelling → ALREADY", again[1].errorCode == "ALREADY" and #teleports == 1)
	-- duplicates in one call
	local MB, c = nil, nil
	MB = freshMA()
	configure(MB)
	c = player("Cy", 13)
	saveOf(c, {}, nil)
	local dup = MB.ReturnToLobby({ c, c })
	check("return: duplicate player in the list handled once", #dup == 1 and dup[1].ok and #teleports == 2 and #teleports[2].players == 1)
end

do
	local MA, a, b = setup7()
	-- order proof: release happens before the Teleport call
	local order = {}
	MA._SetDeps({ Teleport = function(pid, players)
		table.insert(order, "teleport")
		for _, p in ipairs(players) do
			table.insert(order, ds.released[p] and "released" or "NOT-RELEASED")
		end
	end })
	MA.ReturnToLobby({ a })
	check("return: save released before TeleportAsync runs", order[1] == "teleport" and order[2] == "released", table.concat(order, ","))
end

do
	local MA, a, b = setup7()
	preview.removePlayer(b)
	local res = MA.ReturnToLobby({ a, b })
	local byId = {}
	for _, r in ipairs(res) do
		byId[r.userId] = r
	end
	check("return: gone player → NOT_PRESENT, present one ok", #res == 2 and byId[11] and byId[11].ok and byId[12] and byId[12].errorCode == "NOT_PRESENT", #res)
	check("return: only the present player teleported", #teleports == 1 and #teleports[1].players == 1 and teleports[1].players[1] == a)
	local res2 = MA.ReturnToLobby({ "x" :: any, 5 :: any, Instance.new("Part") :: any })
	check("return: non-Player values → BAD_PLAYER each", #res2 == 3 and res2[1].errorCode == "BAD_PLAYER" and res2[2].errorCode == "BAD_PLAYER" and res2[3].errorCode == "BAD_PLAYER" and res2[1].userId == 0)
	check("return: non-table argument → empty", #MA.ReturnToLobby(nil :: any) == 0)
	check("return: nothing extra teleported for bad input", #teleports == 1)
end

do
	local MA, a, b = setup7()
	ds.releaseFail = true
	local res = MA.ReturnToLobby({ a })
	check("return: save won't release → SAVE_BUSY, no teleport", res[1].errorCode == "SAVE_BUSY" and #teleports == 0)
end

do
	local MA, a, b = setup7()
	teleportFails = 99
	local res = MA.ReturnToLobby({ a, b })
	check("return: sync teleport failing every try → TELEPORT_FAILED for all", res[1].errorCode == "TELEPORT_FAILED" and res[2].errorCode == "TELEPORT_FAILED")
	check("return: tried 1 + ReturnRetries times", #teleports == 1 + LobbyConfig.ReturnRetries, #teleports)
	check("return: saves reclaimed", not ds.released[a] and not ds.released[b], table.concat(ds.log, ","))
	teleportFails = 0
	local res2 = MA.ReturnToLobby({ a })
	check("return: after a failed trip a new attempt is allowed", res2[1].ok)
end

do
	local MA, a, b = setup7()
	teleportFails = 1
	local res = MA.ReturnToLobby({ a })
	check("return: one sync failure then success → ok", res[1].ok and #teleports == 2)
end

do
	-- late TeleportInitFailed
	local MA, a, b = setup7()
	local res = MA.ReturnToLobby({ a })
	check("late failure: trip accepted", res[1].ok and #teleports == 1)
	MA.OnTeleportFailed(a)
	check("late failure 1: retried alone to the same options", #teleports == 2 and #teleports[2].players == 1 and teleports[2].options == teleports[1].options and ds.released[a])
	MA.OnTeleportFailed(a)
	check("late failure 2: retried again", #teleports == 3 and ds.released[a])
	MA.OnTeleportFailed(a)
	check("late failure 3 (ReturnRetries spent): no more teleports, save reclaimed", #teleports == 1 + LobbyConfig.ReturnRetries and not ds.released[a], #teleports)
	check("late failure: player told", #notes == 1)
	MA.OnTeleportFailed(a)
	check("late failure: forgotten trip ignores a 4th", #teleports == 1 + LobbyConfig.ReturnRetries and #notes == 1)
	local other = MA.ReturnToLobby({ a })
	check("late failure: player may start a new trip", other[1].ok)
	MA.OnTeleportFailed(b)
	check("late failure: a player with no trip is ignored", #teleports == 2 + LobbyConfig.ReturnRetries)
end

do
	local MA, a, b = setup7()
	teleportFails = 0
	MA.ReturnToLobby({ a })
	teleportFails = 99 -- the retry's TeleportAsync throws synchronously
	MA.OnTeleportFailed(a)
	check("late failure: retry that throws counts as another failure and ends in reclaim", not ds.released[a] and #teleports == 1 + LobbyConfig.ReturnRetries, #teleports)
end

do
	-- local + lobby roles
	local MA, a, b = setup7()
	studio = true
	local res = MA.ReturnToLobby({ a, b })
	check("local role: LocalReturn called for both, ok", #localReturned == 2 and res[1].ok and res[2].ok and #teleports == 0)
	check("local role: no save release", #ds.log == 0)
	MA._SetDeps({ LocalReturn = function()
		return false
	end })
	local res2 = MA.ReturnToLobby({ a })
	check("local role: LocalReturn false → TELEPORT_FAILED", res2[1].errorCode == "TELEPORT_FAILED")
	studio = false
	privateId, ownerId = "", 0
	local res3 = MA.ReturnToLobby({ a })
	check("lobby role: ReturnToLobby → WRONG_ROLE, nothing sent", res3[1].errorCode == "WRONG_ROLE" and #teleports == 0)
end

do
	-- placeId 0 on a non-local role is refused (cannot happen through ServerRole, so force via IsStudio false + transfer on: placeId 0 → local)
	local MA, a = setup7()
	placeId = 0
	check("placeId 0 is local, never a teleport to place 0", MA.ServerRole() == "local")
end

preview.log(string.format("admission-regression: %d checks, %d passed, %d failed", passes + fails, passes, fails))
Clock._Set(function()
	return os.time()
end, nil)
preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
assert(fails == 0, tostring(fails) .. " admission checks failed")
