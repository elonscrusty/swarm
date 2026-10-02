--!nocheck
--[[
	profile.luau - optional cost and traffic profiler for perf scenes (scenes/perf-sim.luau).

	Off by default (zero cost beyond one nil check per hook). preview.profile(true) turns it
	on; preview.profileReport() returns the counters since the last reset and clears them.

	Time is exclusive per frame label: a label's time excludes nested labels, so a client
	handler fired inside a server step (FireAllClients delivers OnClientEvent at once in the
	mock, SetAttribute fires AttributeChanged at once) is charged to the client handler,
	not to the server system that triggered it. Labels:
	  * anything a scene opens with preview.profileEnter(name) / profileLeave()
	    (perf-sim wraps the server systems' Step functions this way)
	  * every signal handler: "<Script>:<line> <Signal>" (RenderStepped, Heartbeat,
	    OnClientEvent, AttributeChanged ...), and BindToRenderStep callbacks
	  * "[resume] <Script>:<line>": threads woken by task.wait / task.delay
	  * "[mock] tweens", "[mock] gui layout": the mock's own TweenService and GUI layout
	Counters: RemoteEvent fires per remote (+ estimated payload bytes), attribute writes
	that changed a value (= what Roblox replicates) per attribute name, property writes per
	property, BulkMoveTo parts, workspace queries (Raycast / GetPartBounds*), instances
	created / destroyed.
	Lune is not Roblox: compare numbers between runs of the same scene, never with a device.
]]

local R = require("./R")

local P = {
	on = false,
	stack = {},
	time = {}, -- label -> { excl, incl, calls }
	counters = {}, -- name -> number
	remotes = {}, -- name -> { calls, args (payload refs, sized at report time) }
	attrs = {}, -- attribute name -> changed writes
	props = {}, -- property name -> writes
	created = 0,
	destroyed = 0,
}

local clock = os.clock
local labelCache = setmetatable({}, { __mode = "k" })

-- '[string "src/client/VFX.lua"]' / 'src/client/VFX.lua' -> 'VFX'
local function shortSource(src): string
	src = tostring(src or "?")
	src = string.match(src, '^%[string "(.*)"%]$') or src
	return string.match(src, "([^/]+)%.lua$") or string.match(src, "([^/]+)%.luau$") or string.match(src, "([^/]+)$") or src
end

-- "EnemyRenderer:745" for a function (debugName is the source path).
function P.fnLabel(fn): string
	local l = labelCache[fn]
	if l then
		return l
	end
	local src, line = debug.info(fn, "sl")
	l = shortSource(src) .. ":" .. tostring(line or "?")
	labelCache[fn] = l
	return l
end

function P.threadLabel(thread): string
	local src, line = debug.info(thread, 1, "sl")
	return shortSource(src) .. ":" .. tostring(line or "?")
end

function P.enter(name: string)
	local st = P.stack
	st[#st + 1] = { name, clock(), 0 }
end

function P.leave()
	local st = P.stack
	local top = st[#st]
	if not top then
		return
	end
	st[#st] = nil
	local elapsed = clock() - top[2]
	local rec = P.time[top[1]]
	if not rec then
		rec = { 0, 0, 0 }
		P.time[top[1]] = rec
	end
	rec[1] += elapsed - top[3]
	rec[2] += elapsed
	rec[3] += 1
	local parent = st[#st]
	if parent then
		parent[3] += elapsed
	end
end

function P.top(): string
	local top = P.stack[#P.stack]
	return top and top[1] or "-"
end

function P.count(name: string, n: number?)
	P.counters[name] = (P.counters[name] or 0) + (n or 1)
end

function P.remote(name: string, args)
	local rec = P.remotes[name]
	if not rec then
		rec = { calls = 0, args = {} }
		P.remotes[name] = rec
	end
	rec.calls += 1
	rec.args[#rec.args + 1] = args
end

function P.attr(name: string)
	P.attrs[name] = (P.attrs[name] or 0) + 1
end

function P.prop(name: string)
	P.props[name] = (P.props[name] or 0) + 1
	local key = "prop " .. name .. " in " .. P.top()
	P.counters[key] = (P.counters[key] or 0) + 1
end

-- Rough wire size of a value (numbers 4-8, strings their length, Color3 12, Vector3 12).
local function sizeOf(v, depth): number
	local t = typeof(v)
	if t == "number" then
		return (v == math.floor(v) and math.abs(v) < 32768) and 3 or 9
	elseif t == "string" then
		return #v + 2
	elseif t == "boolean" or t == "nil" then
		return 1
	elseif t == "table" then
		if depth > 8 then
			return 0
		end
		local n = 2
		for k, x in pairs(v) do
			n += sizeOf(k, depth + 1) + sizeOf(x, depth + 1)
		end
		return n
	elseif t == "Color3" or t == "Vector3" then
		return 13
	elseif t == "CFrame" then
		return 25
	end
	return 4
end

function P.reset()
	table.clear(P.time)
	table.clear(P.counters)
	table.clear(P.remotes)
	table.clear(P.attrs)
	table.clear(P.props)
	P.created = 0
	P.destroyed = 0
end

-- Snapshot since the last reset (payload bytes are measured now), then reset.
function P.report()
	local out = { time = {}, counters = table.clone(P.counters), remotes = {}, attrs = table.clone(P.attrs), props = table.clone(P.props), created = P.created, destroyed = P.destroyed }
	for k, v in pairs(P.time) do
		out.time[k] = { excl = v[1], incl = v[2], calls = v[3] }
	end
	for name, rec in pairs(P.remotes) do
		local bytes = 0
		for _, a in ipairs(rec.args) do
			bytes += sizeOf(a, 0)
		end
		out.remotes[name] = { calls = rec.calls, bytes = bytes }
	end
	P.reset()
	return out
end

R.prof = P
return P
