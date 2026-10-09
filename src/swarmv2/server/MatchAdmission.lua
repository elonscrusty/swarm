--!strict
--[[
	SwarmV2/MatchAdmission.lua  (ServerScriptService.SwarmV2.MatchAdmission)
	OWNER: lobby track (Chat 1). Contract: docs/redesign/OWNERSHIP.md, SwarmV2.Types and
	docs/redesign/reference/Swarm-Claude-Chat-1-Lobby.md ("Shared contract"). Integration
	notes for the gameplay track: docs/redesign/lobby/HANDOFF.md.

	ServerRole()  "lobby"  public lobby server (basecamp, queues, transfers out)
	              "match"  a reserved server of this place (PrivateServerId set, owner 0)
	              "local"  Studio, an unpublished place (PlaceId 0) or LobbyConfig.TransferEnabled
	                       off: lobby and run share this server; tickets live in memory.

	ResolvePlayer(player) → { ok = true, context } | { ok = false, errorCode, message }
	  Match server: the player's join data names a match (TeleportData.SwarmV2 = { schemaVersion
	  = 1, matchId }: a lookup hint only, it grants nothing) and must come from this place
	  (JoinData.SourcePlaceId). The server-only ticket is read from the MemoryStore and
	  checked: schema, expiry, this place, THIS reserved server (game.PrivateServerId), the
	  player on the frozen roster, a canonical class, and current ownership from the player's
	  loaded save (waits at most LobbyConfig.ProfileWaitSeconds). The first admission marks
	  (matchId, userId) for this server atomically (TicketStore.MarkAdmitted): another server
	  holding the same ticket is refused (REPLAY). The ticket itself is never deleted on
	  arrival, so the rest of the roster can still come. The server binds to the first
	  match it admits; any other matchId is WRONG_MATCH. Repeated calls return the same
	  context; a call while another is resolving the same player waits for it (bounded).
	  Local role: the lobby registered the ticket in memory (RegisterLocalMatch); the same
	  checks run against it (reserved id "local").
	  Error codes: BAD_PLAYER, WRONG_ROLE, NO_TICKET, BAD_ORIGIN, WRONG_MATCH, STORE_UNAVAILABLE,
	  TICKET_MISSING, BAD_TICKET, TICKET_EXPIRED, WRONG_PLACE, WRONG_SERVER, NOT_EXPECTED,
	  BAD_CLASS, PLAYER_LEFT, PROFILE_UNAVAILABLE, NOT_OWNED, REPLAY, TIMEOUT. Recoverable
	  (worth one more call later): STORE_UNAVAILABLE, PROFILE_UNAVAILABLE, TIMEOUT.

	ReturnToLobby(players) → { { userId, ok, errorCode?, message? } }
	  Match server: each player must be a real Player still on this server. Their save is
	  written and released first (DataService.ReleaseForTeleport), then ONE TeleportAsync to
	  the configured lobby place (game.PlaceId: a public server), retried with the same
	  group; a player whose teleport fails later (TeleportInitFailed) is retried alone
	  LobbyConfig.ReturnRetries times, then gets their save back and a notice. ok = the
	  teleport was accepted. Awards nothing; run rewards are the gameplay track's.
	  Local role: the player goes back to the basecamp avatar at the bonfire on this server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")

local SwarmV2Shared = ReplicatedStorage:WaitForChild("SwarmV2")
local Types = require(SwarmV2Shared:WaitForChild("Types"))
local ClassCatalog = require(SwarmV2Shared:WaitForChild("ClassCatalog"))
local LobbyConfig = require(SwarmV2Shared:WaitForChild("Lobby"):WaitForChild("LobbyConfig"))
local LobbyFolder = script.Parent:WaitForChild("Lobby")
local TicketStore = require(LobbyFolder:WaitForChild("TicketStore"))
local ClassOwnership = require(LobbyFolder:WaitForChild("ClassOwnership"))
local Clock = require(LobbyFolder:WaitForChild("Clock"))
local PartyReturn = require(LobbyFolder:WaitForChild("PartyReturn"))

type AdmissionResult = Types.AdmissionResult
type ReturnResult = Types.ReturnResult
type PlayerRunContext = Types.PlayerRunContext
type MatchTicket = Types.MatchTicket

local MatchAdmission = {}

export type ServerRole = "lobby" | "match" | "local"

local MESSAGES: { [string]: string } = {
	BAD_PLAYER = "That player isn't on this server.",
	WRONG_ROLE = "This server doesn't host matches.",
	NO_TICKET = "You arrived without a match. Back to the camp.",
	BAD_ORIGIN = "That match link didn't come from SWARM's camp.",
	WRONG_MATCH = "This server is running a different match.",
	STORE_UNAVAILABLE = "Couldn't check your match right now. Trying again.",
	TICKET_MISSING = "Your match ticket wasn't found. Back to the camp.",
	BAD_TICKET = "Your match ticket couldn't be read. Back to the camp.",
	TICKET_EXPIRED = "Your match ticket ran out of time. Back to the camp.",
	WRONG_PLACE = "That match ticket is for another place.",
	WRONG_SERVER = "That match ticket is for another server.",
	NOT_EXPECTED = "You're not on this match's team.",
	BAD_CLASS = "Your class choice couldn't be read.",
	PLAYER_LEFT = "The player left.",
	PROFILE_UNAVAILABLE = "Your save didn't load in time.",
	NOT_OWNED = "You don't own that class anymore.",
	REPLAY = "That match ticket was already used on another server.",
	TIMEOUT = "Checking your match took too long.",
	NOT_PRESENT = "That player isn't on this server.",
	ALREADY = "Already on the way back.",
	SAVE_BUSY = "Couldn't save before travelling.",
	TELEPORT_FAILED = "Couldn't reach the camp.",
}

local function fail(code: string): AdmissionResult
	return { ok = false, errorCode = code, message = MESSAGES[code] or code }
end

------------------------------------------------------------------------------------------
-- Dependencies (real by default; the regressions replace them with _SetDeps)
------------------------------------------------------------------------------------------

local deps = {
	DataService = nil :: any,
	IsStudio = function(): boolean
		return RunService:IsStudio()
	end,
	PlaceId = function(): number
		return game.PlaceId
	end,
	PrivateServerId = function(): string
		return game.PrivateServerId
	end,
	PrivateServerOwnerId = function(): number
		return game.PrivateServerOwnerId
	end,
	JobId = function(): string
		return game.JobId
	end,
	JoinData = function(player: Player): any
		return player:GetJoinData()
	end,
	Teleport = function(placeId: number, players: { Player }, options: Instance)
		TeleportService:TeleportAsync(placeId, players, options :: TeleportOptions)
	end,
	-- local role: back to the basecamp on this server (set by LobbyBoot)
	LocalReturn = nil :: ((Player) -> boolean)?,
	Notify = nil :: ((Player, string, string) -> ())?,
	Wait = function(seconds: number)
		task.wait(seconds)
	end,
}

-- Tests only: replace dependencies (fields as in `deps`).
function MatchAdmission._SetDeps(overrides: { [string]: any })
	for k, v in pairs(overrides) do
		(deps :: any)[k] = v
	end
end

------------------------------------------------------------------------------------------
-- Role
------------------------------------------------------------------------------------------

function MatchAdmission.ServerRole(): ServerRole
	if not LobbyConfig.TransferEnabled or deps.IsStudio() or deps.PlaceId() == 0 then
		return "local"
	end
	if deps.PrivateServerId() ~= "" and deps.PrivateServerOwnerId() == 0 then
		return "match"
	end
	return "lobby"
end

local function storeKind(role: ServerRole): string
	return role == "local" and "memory" or "live"
end

------------------------------------------------------------------------------------------
-- Tickets
------------------------------------------------------------------------------------------

local function validId(id: any): boolean
	return type(id) == "number" and id == id and id > 0 and id % 1 == 0 and id < 2 ^ 53
end

local function validMatchId(id: any): boolean
	return type(id) == "string" and #id >= 8 and #id <= 64 and string.match(id, "^[%w%-_]+$") ~= nil
end

-- A stored ticket rebuilt field by field; nil when anything is off.
function MatchAdmission.SanitizeTicket(raw: any): MatchTicket?
	if type(raw) ~= "table" or raw.schemaVersion ~= Types.SchemaVersion then
		return nil
	end
	if not validMatchId(raw.matchId) or type(raw.reservedPrivateServerId) ~= "string" or raw.reservedPrivateServerId == "" then
		return nil
	end
	for _, k in ipairs({ "targetMatchPlaceId", "lobbyPlaceId", "createdAt", "expiresAt" }) do
		local v = raw[k]
		if type(v) ~= "number" or v ~= v or v < 0 then
			return nil
		end
	end
	if raw.expiresAt <= raw.createdAt or type(raw.expectedUserIds) ~= "table" or type(raw.classesByUserId) ~= "table" then
		return nil
	end
	local ids: { number } = {}
	for i = 1, LobbyConfig.MaxPlayers + 1 do
		local id = raw.expectedUserIds[i]
		if id == nil then
			break
		end
		if not validId(id) or table.find(ids, id) or i > LobbyConfig.MaxPlayers then
			return nil
		end
		table.insert(ids, id)
	end
	if #ids == 0 then
		return nil
	end
	local classes: { [string]: string } = {}
	for _, id in ipairs(ids) do
		local c = raw.classesByUserId[tostring(id)]
		if not ClassCatalog.IsClassId(c) then
			return nil
		end
		classes[tostring(id)] = c
	end
	return {
		schemaVersion = raw.schemaVersion,
		party = MatchAdmission.CleanParty(raw.party, ids),
		matchId = raw.matchId,
		targetMatchPlaceId = raw.targetMatchPlaceId,
		reservedPrivateServerId = raw.reservedPrivateServerId,
		createdAt = raw.createdAt,
		expiresAt = raw.expiresAt,
		expectedUserIds = ids,
		classesByUserId = classes,
		lobbyPlaceId = raw.lobbyPlaceId,
	}
end

-- Lobby side: a fresh ticket for a frozen roster. Server only; never sent to a client.
-- A party record reduced to what is valid: a leader and at least one other member, all of them in
-- `ids` (the roster / the members of the match). nil when nothing valid is left.
function MatchAdmission.CleanParty(raw: any, ids: { number }): { leader: number, members: { number } }?
	if type(raw) ~= "table" or not validId(raw.leader) or not table.find(ids, raw.leader) or type(raw.members) ~= "table" then
		return nil
	end
	local members: { number } = { raw.leader }
	for i = 1, LobbyConfig.MaxPlayers + 1 do
		local id = raw.members[i]
		if id == nil then
			break
		end
		if i > LobbyConfig.MaxPlayers then
			return nil
		end
		if validId(id) and table.find(ids, id) and not table.find(members, id) then
			table.insert(members, id)
		end
	end
	if #members < 2 then
		return nil
	end
	return { leader = raw.leader, members = members }
end

function MatchAdmission.BuildTicket(matchId: string, reservedPrivateServerId: string, roster: { { userId: number, classId: string } }, party: { leader: number, members: { number } }?): MatchTicket
	local now = Clock.Unix()
	local ids, classes = {}, {}
	for _, r in ipairs(roster) do
		table.insert(ids, r.userId)
		classes[tostring(r.userId)] = r.classId
	end
	local ticket: MatchTicket = {
		schemaVersion = Types.SchemaVersion,
		matchId = matchId,
		targetMatchPlaceId = deps.PlaceId(),
		reservedPrivateServerId = reservedPrivateServerId,
		createdAt = now,
		expiresAt = now + LobbyConfig.TicketTTLSeconds,
		expectedUserIds = ids,
		classesByUserId = classes,
		lobbyPlaceId = deps.PlaceId(),
	}
	if party then
		ticket.party = MatchAdmission.CleanParty(party, ids)
	end
	return ticket
end

-- local role: matchId each user is heading to (in-memory "teleport hint")
local localHint: { [number]: string } = {}

-- Local role only: stores the ticket in memory and points its players at it. Refused
-- (false) on lobby / match servers, so the in-memory path can never stand in for a live one.
function MatchAdmission.RegisterLocalMatch(ticket: MatchTicket): boolean
	if MatchAdmission.ServerRole() ~= "local" or MatchAdmission.SanitizeTicket(ticket) == nil then
		return false
	end
	if not TicketStore.Write("memory", ticket) then
		return false
	end
	for _, id in ipairs(ticket.expectedUserIds) do
		localHint[id] = ticket.matchId
	end
	return true
end

-- matchId → the party the ticket recorded (kept for the way home; dropped after the record's lifetime)
local matchParty: { [string]: { leader: number, members: { number } } } = {}

local cache: { [string]: PlayerRunContext } = {} -- matchId/userId → admitted context
local pending: { [string]: boolean } = {}
local bound: string? = nil -- match server: the one match this server runs

-- Local role: the match is over or never started; its players are free again.
function MatchAdmission.EndLocalMatch(matchId: string)
	for id, m in pairs(localHint) do
		if m == matchId then
			localHint[id] = nil
			cache[matchId .. "/" .. id] = nil
		end
	end
	TicketStore.Remove("memory", matchId)
end

-- Local role: the match this user is in (registered and not yet returned), or nil.
function MatchAdmission.LocalMatchOf(userId: number): string?
	return localHint[userId]
end

------------------------------------------------------------------------------------------
-- ResolvePlayer
------------------------------------------------------------------------------------------

-- The SwarmV2 hint from real join data, or nil + why.
local function readHint(player: Player): (string?, string?)
	local ok: boolean, data: any = pcall(deps.JoinData, player)
	if not ok or type(data) ~= "table" then
		return nil, "NO_TICKET"
	end
	local td = data.TeleportData
	local hint = type(td) == "table" and td.SwarmV2 or nil
	if type(hint) ~= "table" or hint.schemaVersion ~= Types.SchemaVersion or not validMatchId(hint.matchId) then
		return nil, "NO_TICKET"
	end
	-- the trusted origin: a teleport from this same place (the public lobby)
	if data.SourcePlaceId ~= deps.PlaceId() then
		return nil, "BAD_ORIGIN"
	end
	return hint.matchId, nil
end

local function waitForSave(player: Player): (any, string?)
	local ds = deps.DataService
	local waited = 0
	while true do
		if player.Parent ~= Players then
			return nil, "PLAYER_LEFT"
		end
		local data = ds and ds.GetData(player)
		if data then
			return data, nil
		end
		if waited >= LobbyConfig.ProfileWaitSeconds then
			return nil, "PROFILE_UNAVAILABLE"
		end
		deps.Wait(0.25)
		waited += 0.25
	end
end

local function resolveNow(player: Player, role: ServerRole, matchId: string): AdmissionResult
	if role == "match" and bound ~= nil and bound ~= matchId then
		return fail("WRONG_MATCH")
	end
	local kind = storeKind(role)
	local raw, err = TicketStore.Read(kind, matchId)
	if err == "UNAVAILABLE" then
		return fail("STORE_UNAVAILABLE")
	elseif raw == nil then
		return fail("TICKET_MISSING")
	end
	local t = MatchAdmission.SanitizeTicket(raw)
	if not t or t.matchId ~= matchId then
		return fail("BAD_TICKET")
	end
	if Clock.Unix() >= t.expiresAt then
		return fail("TICKET_EXPIRED")
	end
	if t.targetMatchPlaceId ~= deps.PlaceId() or t.lobbyPlaceId ~= deps.PlaceId() then
		return fail("WRONG_PLACE")
	end
	local here = role == "local" and "local" or deps.PrivateServerId()
	if t.reservedPrivateServerId ~= here then
		return fail("WRONG_SERVER")
	end
	local userId = player.UserId
	if not table.find(t.expectedUserIds, userId) then
		return fail("NOT_EXPECTED")
	end
	local classId = t.classesByUserId[tostring(userId)]
	if not ClassCatalog.IsClassId(classId) then
		return fail("BAD_CLASS")
	end
	local data, saveErr = waitForSave(player)
	if not data then
		return fail(saveErr or "PROFILE_UNAVAILABLE")
	end
	if not ClassOwnership.Owns(data, classId) then
		return fail("NOT_OWNED")
	end
	if role == "match" then
		local markErr = TicketStore.MarkAdmitted(kind, matchId, userId, deps.JobId(), t.expiresAt - Clock.Unix() + 3600)
		if markErr then
			return fail(markErr == "REPLAY" and "REPLAY" or "STORE_UNAVAILABLE")
		end
		if bound ~= nil and bound ~= matchId then
			return fail("WRONG_MATCH") -- another match bound this server while we waited
		end
		bound = matchId
	end
	if t.party and matchParty[matchId] == nil then
		matchParty[matchId] = t.party
		task.delay(LobbyConfig.PartyReturnTTLSeconds, function()
			matchParty[matchId] = nil
		end)
	end
	local roster = table.clone(t.expectedUserIds)
	table.freeze(roster)
	local context: PlayerRunContext = {
		schemaVersion = Types.SchemaVersion,
		matchId = matchId,
		userId = userId,
		classId = classId,
		expectedUserIds = roster,
		lobbyPlaceId = t.lobbyPlaceId,
	}
	table.freeze(context)
	return { ok = true, context = context }
end

function MatchAdmission.ResolvePlayer(player: Player): AdmissionResult
	if typeof(player) ~= "Instance" or not player:IsA("Player") or player.Parent ~= Players then
		return fail("BAD_PLAYER")
	end
	local role = MatchAdmission.ServerRole()
	if role == "lobby" then
		return fail("WRONG_ROLE")
	end
	local matchId: string?, why: string?
	if role == "local" then
		matchId = localHint[player.UserId]
		why = matchId == nil and "NO_TICKET" or nil
	else
		matchId, why = readHint(player)
	end
	if not matchId then
		return fail(why or "NO_TICKET")
	end
	local key = matchId .. "/" .. tostring(player.UserId)
	local waited = 0
	while pending[key] do
		if waited >= LobbyConfig.ResolveWaitSeconds then
			return fail("TIMEOUT")
		end
		deps.Wait(0.1)
		waited += 0.1
	end
	local known = cache[key]
	if known then
		return { ok = true, context = known }
	end
	pending[key] = true
	local ok: boolean, result: any = pcall(resolveNow, player, role :: ServerRole, matchId)
	pending[key] = nil
	if not ok then
		warn("[SwarmV2 MatchAdmission] resolve error: " .. tostring(result))
		return fail("STORE_UNAVAILABLE")
	end
	if result.ok and result.context then
		cache[key] = result.context
	end
	return result
end

------------------------------------------------------------------------------------------
-- ReturnToLobby
------------------------------------------------------------------------------------------

type Trip = { Options: Instance, Tries: { [Player]: number } }
local returning: { [Player]: Trip } = {}

local function takeBack(player: Player)
	local ds = deps.DataService
	if ds and player.Parent == Players and ds.IsReleased and ds.IsReleased(player) then
		if not ds.Reclaim(player) and player.Parent then
			player:Kick("Couldn't reach the camp. Please rejoin: your progress is saved.")
		end
	end
end

local function notify(player: Player, text: string, kind: string)
	if deps.Notify then
		pcall(deps.Notify, player, text, kind)
	end
end

-- TeleportData is only a lookup hint: the party itself goes into the store (PartyReturn.Record).
local function makeReturnOptions(matchId: string?): Instance
	local options = Instance.new("TeleportOptions")
	local hint: { [string]: any } = { schemaVersion = Types.SchemaVersion }
	if matchId and matchParty[matchId] and PartyReturn.Record("live", matchId, matchParty[matchId]) then
		hint.matchId = matchId
	end
	options:SetTeleportData({ SwarmV2Return = hint })
	return options
end

-- One TeleportAsync for these players, tried 1 + ReturnRetries times. True when accepted.
local function sendGroup(list: { Player }, options: Instance): boolean
	local delays = LobbyConfig.TeleportRetryDelays
	for i = 1, 1 + LobbyConfig.ReturnRetries do
		local here = {}
		for _, p in ipairs(list) do
			if p.Parent == Players then
				table.insert(here, p)
			end
		end
		if #here == 0 then
			return true
		end
		local ok: boolean, err: any = pcall(deps.Teleport, deps.PlaceId(), here, options)
		if ok then
			return true
		end
		warn("[SwarmV2 MatchAdmission] return teleport failed: " .. tostring(err))
		if i <= LobbyConfig.ReturnRetries then
			deps.Wait(delays[i] or 2)
		end
	end
	return false
end

-- TeleportInitFailed on a match server: our return trips only.
function MatchAdmission.OnTeleportFailed(player: Player)
	local trip = returning[player]
	if not trip then
		return
	end
	local n = (trip.Tries[player] or 0) + 1
	trip.Tries[player] = n
	if n <= LobbyConfig.ReturnRetries then
		task.spawn(function()
			deps.Wait(LobbyConfig.TeleportRetryDelays[n] or 2)
			if returning[player] == trip and player.Parent == Players then
				local ok = pcall(deps.Teleport, deps.PlaceId(), { player }, trip.Options)
				if not ok then
					MatchAdmission.OnTeleportFailed(player)
				end
			end
		end)
		return
	end
	returning[player] = nil
	takeBack(player)
	notify(player, "Couldn't reach the camp. You can keep playing here or rejoin.", "warn")
end

function MatchAdmission.ReturnToLobby(players: { Player }): { ReturnResult }
	local out: { ReturnResult } = {}
	local role = MatchAdmission.ServerRole()
	local group: { Player } = {}
	local seen: { [Player]: boolean } = {}
	if type(players) ~= "table" then
		return out
	end
	for _, p in ipairs(players) do
		if typeof(p) ~= "Instance" or not (p :: Instance):IsA("Player") then
			table.insert(out, { userId = 0, ok = false, errorCode = "BAD_PLAYER", message = MESSAGES.BAD_PLAYER })
		elseif seen[p] then
			continue
		elseif p.Parent ~= Players then
			seen[p] = true
			table.insert(out, { userId = p.UserId, ok = false, errorCode = "NOT_PRESENT", message = MESSAGES.NOT_PRESENT })
		elseif role == "lobby" then
			seen[p] = true
			table.insert(out, { userId = p.UserId, ok = false, errorCode = "WRONG_ROLE", message = MESSAGES.WRONG_ROLE })
		elseif role == "local" then
			seen[p] = true
			local matchId = localHint[p.UserId]
			local ok = deps.LocalReturn ~= nil and (deps.LocalReturn :: (Player) -> boolean)(p) == true
			if ok then
				if matchId and matchParty[matchId] then
					PartyReturn.Arrive(p, matchId, matchParty[matchId], "memory")
				end
				localHint[p.UserId] = nil
				if matchId then
					cache[matchId .. "/" .. tostring(p.UserId)] = nil
				end
				table.insert(out, { userId = p.UserId, ok = true })
			else
				table.insert(out, { userId = p.UserId, ok = false, errorCode = "TELEPORT_FAILED", message = MESSAGES.TELEPORT_FAILED })
			end
		elseif returning[p] then
			seen[p] = true
			table.insert(out, { userId = p.UserId, ok = false, errorCode = "ALREADY", message = MESSAGES.ALREADY })
		else
			seen[p] = true
			table.insert(group, p)
		end
	end
	if #group == 0 then
		return out
	end
	-- the destination is this place's public lobby; never a 0 / unknown place
	if deps.PlaceId() == 0 then
		for _, p in ipairs(group) do
			table.insert(out, { userId = p.UserId, ok = false, errorCode = "WRONG_PLACE", message = MESSAGES.WRONG_PLACE })
		end
		return out
	end
	local trip: Trip = { Options = makeReturnOptions(bound), Tries = {} }
	local ready: { Player } = {}
	local ds = deps.DataService
	for _, p in ipairs(group) do
		if ds == nil or ds.GetData(p) == nil or ds.ReleaseForTeleport(p) then
			returning[p] = trip
			table.insert(ready, p)
		else
			table.insert(out, { userId = p.UserId, ok = false, errorCode = "SAVE_BUSY", message = MESSAGES.SAVE_BUSY })
		end
	end
	if #ready == 0 then
		return out
	end
	local sent = sendGroup(ready, trip.Options)
	for _, p in ipairs(ready) do
		if sent then
			table.insert(out, { userId = p.UserId, ok = true })
		else
			returning[p] = nil
			takeBack(p)
			table.insert(out, { userId = p.UserId, ok = false, errorCode = "TELEPORT_FAILED", message = MESSAGES.TELEPORT_FAILED })
		end
	end
	return out
end

------------------------------------------------------------------------------------------
-- Lifecycle (LobbyBoot)
------------------------------------------------------------------------------------------

local started = false

-- Lobby server: the matchId a player came home from when the match server recorded their party
-- (a lookup hint only; PartyReturn checks the stored record), else nil.
function MatchAdmission.ReturnHint(player: Player): string?
	local ok: boolean, data: any = pcall(deps.JoinData, player)
	if not ok or type(data) ~= "table" or data.SourcePlaceId == nil then
		return nil
	end
	local td = data.TeleportData
	local hint = type(td) == "table" and td.SwarmV2Return or nil
	if type(hint) ~= "table" or hint.schemaVersion ~= Types.SchemaVersion or not validMatchId(hint.matchId) then
		return nil
	end
	return hint.matchId
end

function MatchAdmission.Init(ctx: any)
	deps.DataService = ctx and ctx.DataService or deps.DataService
end

-- Match servers: watch our return trips' late failures and forget players who leave.
function MatchAdmission.Start()
	if started then
		return
	end
	started = true
	pcall(function()
		TeleportService.TeleportInitFailed:Connect(function(player)
			MatchAdmission.OnTeleportFailed(player)
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		returning[player] = nil
	end)
end

return MatchAdmission
