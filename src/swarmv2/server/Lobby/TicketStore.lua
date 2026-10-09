--!strict
--[[
	SwarmV2/Lobby/TicketStore.lua  (ServerScriptService.SwarmV2.Lobby.TicketStore)
	OWNER: lobby track (Chat 1). Server-only storage of match tickets and admission marks.
	Nothing here is ever replicated or put in TeleportData.

	Backends (same four calls: Get / Set / Update / Remove, with an expiry in seconds):
	  "live"   MemoryStoreService hash map "SwarmV2Tickets" (shared by the lobby server that
	           writes the ticket and the reserved match server that reads it). Entries
	           expire on their own (LobbyConfig.TicketTTLSeconds), so nothing is locked forever.
	  "memory" an in-process table with the same expiry rules: the "local" role (Studio /
	           unpublished / transfer off, lobby and run on one server) and the regressions.
	Every call is tried LobbyConfig.StoreAttempts times with a doubling delay; a store that
	keeps failing reports "UNAVAILABLE" (recoverable), never a made-up ticket.

	Keys: "t/<matchId>" the ticket, "a/<matchId>/<userId>" the admission mark (which server
	admitted that user for that match: a second server can't reuse the ticket).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LobbyConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Lobby"):WaitForChild("LobbyConfig"))
local Clock = require(script.Parent:WaitForChild("Clock"))

export type Backend = {
	Get: (key: string) -> any,
	Set: (key: string, value: any, ttl: number) -> (),
	Update: (key: string, fn: (old: any) -> any, ttl: number) -> any,
	Remove: (key: string) -> (),
}

local TicketStore = {}

-- In-process backend (expiry from Clock.Unix). `failures` (tests): a table whose field
-- `count` makes the next N calls throw, like a MemoryStore outage.
function TicketStore.MemoryBackend(failures: { count: number }?): Backend
	local rows: { [string]: { value: any, expires: number } } = {}
	local function trip()
		if failures and failures.count > 0 then
			failures.count -= 1
			error("memory backend: simulated outage")
		end
	end
	local function live(key: string): any
		local row = rows[key]
		if row and row.expires <= Clock.Unix() then
			rows[key] = nil
			return nil
		end
		return row and row.value
	end
	return {
		Get = function(key)
			trip()
			return live(key)
		end,
		Set = function(key, value, ttl)
			trip()
			rows[key] = { value = value, expires = Clock.Unix() + ttl }
		end,
		Update = function(key, fn, ttl)
			trip()
			local new = fn(live(key))
			if new ~= nil then
				rows[key] = { value = new, expires = Clock.Unix() + ttl }
			end
			return new
		end,
		Remove = function(key)
			trip()
			rows[key] = nil
		end,
	}
end

-- MemoryStore backend (live game). Created lazily: the service exists on every server.
function TicketStore.LiveBackend(): Backend
	local map: any = nil
	local function get(): any
		if not map then
			map = game:GetService("MemoryStoreService"):GetHashMap("SwarmV2Tickets")
		end
		return map
	end
	return {
		Get = function(key)
			return get():GetAsync(key)
		end,
		Set = function(key, value, ttl)
			local ok = get():SetAsync(key, value, ttl)
			if ok == false then
				error("MemoryStore SetAsync refused")
			end
		end,
		Update = function(key, fn, ttl)
			return get():UpdateAsync(key, fn, ttl)
		end,
		Remove = function(key)
			get():RemoveAsync(key)
		end,
	}
end

local backends: { [string]: Backend } = {}

-- "live" | "memory". Tests may swap either with UseBackend.
function TicketStore.Backend(kind: string): Backend
	local b = backends[kind]
	if not b then
		b = kind == "live" and TicketStore.LiveBackend() or TicketStore.MemoryBackend()
		backends[kind] = b
	end
	return b
end

function TicketStore.UseBackend(kind: string, backend: Backend)
	backends[kind] = backend
end

-- Runs fn with bounded retries. (true, result) or (false, error text).
local function attempt(fn: () -> ...any): (boolean, any)
	local delay = LobbyConfig.StoreRetryDelay
	local lastErr: any = nil
	for i = 1, LobbyConfig.StoreAttempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		if i < LobbyConfig.StoreAttempts then
			task.wait(delay)
			delay *= 2
		end
	end
	warn("[SwarmV2 TicketStore] store call failed: " .. tostring(lastErr))
	return false, lastErr
end

local function ticketKey(matchId: string): string
	return "t/" .. matchId
end

-- Writes the ticket until its own expiresAt (at least 1 s). True on success.
function TicketStore.Write(kind: string, ticket: { [string]: any }): boolean
	local b = TicketStore.Backend(kind)
	local ttl = math.max(1, math.floor(ticket.expiresAt - Clock.Unix()))
	local ok = attempt(function()
		b.Set(ticketKey(ticket.matchId), ticket, ttl)
	end)
	return ok
end

-- The stored ticket (raw, the caller sanitises), or nil + "MISSING" | "UNAVAILABLE".
function TicketStore.Read(kind: string, matchId: string): (any, string?)
	local b = TicketStore.Backend(kind)
	local ok, value = attempt(function()
		return b.Get(ticketKey(matchId))
	end)
	if not ok then
		return nil, "UNAVAILABLE"
	end
	if value == nil then
		return nil, "MISSING"
	end
	return value, nil
end

function TicketStore.Remove(kind: string, matchId: string)
	local b = TicketStore.Backend(kind)
	attempt(function()
		b.Remove(ticketKey(matchId))
	end)
end

-- The "this party went home together" record, key "p/<matchId>": written by the match server's
-- return trip, read by the lobby server the players land on. Short lived.
function TicketStore.WriteParty(kind: string, matchId: string, party: { [string]: any }, ttl: number): boolean
	local b = TicketStore.Backend(kind)
	local ok = attempt(function()
		b.Set("p/" .. matchId, party, math.max(1, math.floor(ttl)))
	end)
	return ok
end

function TicketStore.ReadParty(kind: string, matchId: string): any
	local b = TicketStore.Backend(kind)
	local ok, value = attempt(function()
		return b.Get("p/" .. matchId)
	end)
	return ok and value or nil
end

--[[
	Atomic admission mark for (matchId, userId), held by `serverKey` (the match server's
	JobId). The first server to mark wins; the same server marking again is fine (retries,
	a second ResolvePlayer). nil on success, else "REPLAY" (another server holds it) or
	"UNAVAILABLE".
]]
function TicketStore.MarkAdmitted(kind: string, matchId: string, userId: number, serverKey: string, ttl: number): string?
	local b = TicketStore.Backend(kind)
	local holder: string? = nil
	local ok = attempt(function()
		holder = nil
		b.Update("a/" .. matchId .. "/" .. tostring(userId), function(old)
			if type(old) == "table" and type(old.server) == "string" and old.server ~= serverKey then
				holder = old.server
				return nil -- keep the other server's mark
			end
			return { server = serverKey, at = Clock.Unix() }
		end, math.max(1, math.floor(ttl)))
	end)
	if not ok then
		return "UNAVAILABLE"
	end
	return holder and "REPLAY" or nil
end

return TicketStore
