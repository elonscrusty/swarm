--!nocheck
--[[
	classes/core.luau - DataModel, scripts, values, bindables, remotes and small services
	(CollectionService, Debris, HttpService).
]]

local serde = require("@lune/serde")
local R = require("../R")
local D = require("../datatypes")
local S = require("../scheduler")

local states = R.states

------------------------------------------------------------------------------------------
-- DataModel
------------------------------------------------------------------------------------------

R.services = {}

local SERVICE_ALIASES = { workspace = "Workspace" }

local function getService(game, name)
	name = SERVICE_ALIASES[name] or name
	local existing = R.services[name]
	if existing then
		return existing
	end
	local info = R.classInfo(name)
	if not info or not info.service then
		error(string.format("'%s' is not a valid Service name", tostring(name)), 2)
	end
	local svc = R.create(name)
	R.services[name] = svc
	local st = states[svc]
	st.name = name
	R.setParent(svc, st, game)
	return svc
end
R.getService = getService

R.defineClass("DataModel", {
	events = { "Loaded", "Close", "GraphicsQualityChangeRequest", "ItemChanged" },
	defaults = { PlaceId = 0, GameId = 0, CreatorId = 0, JobId = "preview-job", PlaceVersion = 1 },
	methods = {
		GetService = getService,
		getService = getService,
		service = getService,
		FindService = function(_, name)
			return R.services[name]
		end,
		IsLoaded = function()
			return true
		end,
		BindToClose = function() end,
		GetJobsInfo = function()
			return {}
		end,
		SetPlaceId = function() end,
	},
	getters = {
		Workspace = function(game)
			return getService(game, "Workspace")
		end,
		workspace = function(game)
			return getService(game, "Workspace")
		end,
		Lighting = function(game)
			return getService(game, "Lighting")
		end,
		CreatorId = function()
			return R.options.creatorId or 0
		end,
		CreatorType = function()
			return D.Enum.CreatorType.User
		end,
		PrivateServerId = function()
			return ""
		end,
		PrivateServerOwnerId = function()
			return 0
		end,
	},
})

------------------------------------------------------------------------------------------
-- Scripts (source is private; require() runs it, see datamodel.luau)
------------------------------------------------------------------------------------------

R.defineClass("LuaSourceContainer", {
	onClone = function(_, _, src, dst)
		dst.x.source = src.x.source
		dst.x.path = src.x.path
	end,
})

------------------------------------------------------------------------------------------
-- Bindables and remotes
------------------------------------------------------------------------------------------

-- Remote payloads are copied like Roblox does (tables copied, functions dropped).
local function copyValue(v, seen)
	if type(v) ~= "table" then
		if type(v) == "function" or type(v) == "thread" then
			return nil
		end
		return v
	end
	seen = seen or {}
	if seen[v] then
		error("tables with cycles cannot be sent through remotes", 3)
	end
	seen[v] = true
	local out = {}
	for k, x in pairs(v) do
		out[k] = copyValue(x, seen)
	end
	seen[v] = nil
	return out
end
R.copyValue = copyValue

local function copyArgs(...)
	local n = select("#", ...)
	local args = table.pack(...)
	for i = 1, n do
		args[i] = copyValue(args[i])
	end
	return args
end

local function summarize(v, depth): string
	depth = depth or 0
	local t = D.typeof(v)
	if t == "table" then
		if depth > 1 then
			return "{...}"
		end
		local parts, n = {}, 0
		for k, x in pairs(v) do
			n += 1
			if n > 6 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, tostring(k) .. "=" .. summarize(x, depth + 1))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif t == "string" then
		return string.format("%q", v)
	elseif t == "Instance" then
		return "<" .. tostring(v) .. ">"
	end
	return tostring(v)
end

local function logRemote(remote, direction: string, args)
	local parts = {}
	for i = 1, args.n do
		table.insert(parts, summarize(args[i]))
	end
	table.insert(R.log.fired, { remote = states[remote].name, direction = direction, args = table.concat(parts, ", "), t = S.now })
end

R.defineClass("BindableEvent", {
	events = { "Event" },
	methods = {
		Fire = function(self, ...)
			R.fire(states[self], "Event", ...)
		end,
	},
})

R.defineClass("BindableFunction", {
	props = { OnInvoke = { type = "Function" } },
	getters = {
		OnInvoke = function(_, st)
			return st.x.callback
		end,
	},
	setters = {
		OnInvoke = function(_, st, fn)
			st.x.callback = fn
		end,
	},
	methods = {
		Invoke = function(self, ...)
			local fn = states[self].x.callback
			if not fn then
				error("BindableFunction has no OnInvoke callback (preview mock)", 2)
			end
			return fn(...)
		end,
	},
})

local function remoteEventDef()
	return {
		events = { "OnServerEvent", "OnClientEvent" },
		methods = {
			FireServer = function(self, ...)
				local args = copyArgs(...)
				logRemote(self, "toServer", args)
				local player = R.localPlayer
				R.fire(states[self], "OnServerEvent", player, table.unpack(args, 1, args.n))
			end,
			FireClient = function(self, player, ...)
				if not R.isInstance(player) or not states[player].info.isA.Player then
					error("FireClient: argument 1 must be a Player", 2)
				end
				local args = copyArgs(...)
				logRemote(self, "toClient", args)
				if player == R.localPlayer then
					R.fire(states[self], "OnClientEvent", table.unpack(args, 1, args.n))
				end
			end,
			FireAllClients = function(self, ...)
				local args = copyArgs(...)
				logRemote(self, "toAllClients", args)
				R.fire(states[self], "OnClientEvent", table.unpack(args, 1, args.n))
			end,
		},
	}
end
R.defineClass("RemoteEvent", remoteEventDef())
R.defineClass("UnreliableRemoteEvent", remoteEventDef())

R.defineClass("RemoteFunction", {
	props = { OnServerInvoke = { type = "Function" }, OnClientInvoke = { type = "Function" } },
	getters = {
		OnServerInvoke = function(_, st)
			return st.x.server
		end,
		OnClientInvoke = function(_, st)
			return st.x.client
		end,
	},
	setters = {
		OnServerInvoke = function(_, st, fn)
			st.x.server = fn
		end,
		OnClientInvoke = function(_, st, fn)
			st.x.client = fn
		end,
	},
	methods = {
		InvokeServer = function(self, ...)
			local fn = states[self].x.server
			local args = copyArgs(...)
			logRemote(self, "invokeServer", args)
			if not fn then
				error(string.format("RemoteFunction %s has no OnServerInvoke in the preview (scene must set one)", states[self].name), 2)
			end
			return fn(R.localPlayer, table.unpack(args, 1, args.n))
		end,
		InvokeClient = function(self, _player, ...)
			local fn = states[self].x.client
			if not fn then
				error("RemoteFunction has no OnClientInvoke (preview mock)", 2)
			end
			return fn(...)
		end,
	},
})

------------------------------------------------------------------------------------------
-- CollectionService
------------------------------------------------------------------------------------------

local tagSignals = { added = {}, removed = {} }

local function tagSignal(kind, tag)
	local list = tagSignals[kind]
	local s = list[tag]
	if not s then
		s = R.Signal.new(kind .. ":" .. tag)
		list[tag] = s
	end
	return s
end

R.onTagAdded = function(inst, tag)
	local s = tagSignals.added[tag]
	if s and R.game and inst:IsDescendantOf(R.game) then
		s:_fire(inst)
	end
end
R.onTagRemoved = function(inst, tag)
	local s = tagSignals.removed[tag]
	if s then
		s:_fire(inst)
	end
end

R.defineClass("CollectionService", {
	events = { "TagAdded", "TagRemoved" },
	methods = {
		GetTagged = function(_, tag)
			local out = {}
			R.walk(R.game, function(d)
				local tags = states[d].tags
				if tags and tags[tag] then
					table.insert(out, d)
				end
			end)
			return out
		end,
		AddTag = function(_, inst, tag)
			inst:AddTag(tag)
		end,
		RemoveTag = function(_, inst, tag)
			inst:RemoveTag(tag)
		end,
		HasTag = function(_, inst, tag)
			return inst:HasTag(tag)
		end,
		GetTags = function(_, inst)
			return inst:GetTags()
		end,
		GetAllTags = function()
			local set, out = {}, {}
			R.walk(R.game, function(d)
				for t in pairs(states[d].tags or {}) do
					if not set[t] then
						set[t] = true
						table.insert(out, t)
					end
				end
			end)
			return out
		end,
		GetInstanceAddedSignal = function(_, tag)
			return tagSignal("added", tag)
		end,
		GetInstanceRemovedSignal = function(_, tag)
			return tagSignal("removed", tag)
		end,
	},
})

------------------------------------------------------------------------------------------
-- Debris, HttpService
------------------------------------------------------------------------------------------

R.defineClass("Debris", {
	methods = {
		AddItem = function(_, inst, lifetime)
			S.delay(lifetime or 10, function()
				if R.isInstance(inst) then
					R.destroy(inst)
				end
			end)
		end,
	},
})

local guidRng = nil
R.defineClass("HttpService", {
	defaults = { HttpEnabled = false },
	methods = {
		JSONEncode = function(_, value)
			return serde.encode("json", value)
		end,
		JSONDecode = function(_, text)
			return serde.decode("json", text)
		end,
		GenerateGUID = function(_, wrap)
			guidRng = guidRng or D.Random.new(42)
			local hex = "0123456789ABCDEF"
			local out = {}
			for i = 1, 32 do
				local n = guidRng:NextInteger(1, 16)
				table.insert(out, string.sub(hex, n, n))
				if i == 8 or i == 12 or i == 16 or i == 20 then
					table.insert(out, "-")
				end
			end
			local g = table.concat(out)
			if wrap == false then
				return g
			end
			return "{" .. g .. "}"
		end,
		UrlEncode = function(_, text)
			return (string.gsub(text, "[^%w%-_%.~]", function(c)
				return string.format("%%%02X", string.byte(c))
			end))
		end,
		GetAsync = function()
			error("Http requests are not enabled (preview mock)", 2)
		end,
		PostAsync = function()
			error("Http requests are not enabled (preview mock)", 2)
		end,
		RequestAsync = function()
			error("Http requests are not enabled (preview mock)", 2)
		end,
	},
})

return true
