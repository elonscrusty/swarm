--!nocheck
--[[
	scheduler.luau - simulated time and the task library.

	All game code (and the scene itself) runs in coroutines resumed by this scheduler.
	Time only moves when the scene advances it: S.step(dt) runs one frame
	(RenderStepped → resumed waits → Stepped → Heartbeat → tweens → deferred threads →
	GUI layout), so a scene is deterministic and never waits in real time.
]]

local R = require("./R")

local S = {
	now = 0, -- simulated seconds since start
	frame = 0,
	dt = 1 / 60,
	waiting = {}, -- { { t = wake time, thread = co, args = {...}? } }
	deferred = {},
	frameHooks = {}, -- functions(dt) run each frame (RunService fills these)
	stepping = false,
}

local EPOCH = 1767225600 -- fixed "real" time base (2026-01-01) so os.time()/tick() are stable

function R.epoch(): number
	return EPOCH + S.now
end

local function describe(thread, err): string
	local tb = debug.traceback(thread, tostring(err))
	return tb
end

-- Resumes a thread; errors are reported with the thread's stack (never propagate).
function S.resume(thread, ...)
	if coroutine.status(thread) ~= "suspended" then
		return false
	end
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		R.error(tostring(err), describe(thread, ""))
	end
	return ok
end

-- task.spawn semantics: run now (until it yields), return the thread.
function S.spawn(f, ...)
	local thread
	if type(f) == "thread" then
		thread = f
	elseif type(f) == "function" then
		thread = coroutine.create(f)
	else
		error("invalid argument #1 to 'spawn' (function or thread expected, got " .. typeof(f) .. ")", 2)
	end
	S.resume(thread, ...)
	return thread
end

function S.defer(f, ...)
	local thread = type(f) == "thread" and f or coroutine.create(f)
	table.insert(S.deferred, { thread = thread, args = table.pack(...) })
	return thread
end

local function schedule(thread, t, args)
	table.insert(S.waiting, { t = t, thread = thread, args = args })
end

function S.delay(seconds, f, ...)
	local thread = type(f) == "thread" and f or coroutine.create(f)
	schedule(thread, S.now + math.max(0, tonumber(seconds) or 0), table.pack(...))
	return thread
end

-- task.wait: yields the running thread for `seconds` of simulated time (at least a frame).
function S.wait(seconds)
	local thread = coroutine.running()
	if not coroutine.isyieldable() then
		error("task.wait called from a thread that cannot yield", 2)
	end
	local start = S.now
	schedule(thread, S.now + math.max(0, tonumber(seconds) or 0), nil)
	coroutine.yield()
	return S.now - start, S.now
end

function S.cancel(thread)
	for i = #S.waiting, 1, -1 do
		if S.waiting[i].thread == thread then
			table.remove(S.waiting, i)
		end
	end
	for i = #S.deferred, 1, -1 do
		if S.deferred[i].thread == thread then
			table.remove(S.deferred, i)
		end
	end
	if coroutine.status(thread) == "suspended" then
		pcall(coroutine.close, thread)
	end
end

-- Yields until `predicate()` is true (checked every frame) or `timeout` seconds pass.
function S.waitUntil(predicate, timeout): boolean
	local deadline = timeout and (S.now + timeout) or math.huge
	while not predicate() do
		if S.now >= deadline then
			return false
		end
		S.wait(0)
	end
	return true
end

function S.flushDeferred()
	local guard = 0
	while #S.deferred > 0 do
		guard += 1
		if guard > 10000 then
			R.error("deferred thread loop (more than 10000 task.defer calls in one frame)")
			table.clear(S.deferred)
			break
		end
		local item = table.remove(S.deferred, 1)
		if item.args then
			S.resume(item.thread, table.unpack(item.args, 1, item.args.n))
		else
			S.resume(item.thread)
		end
	end
end

local function resumeDue()
	if #S.waiting == 0 then
		return
	end
	local due = {}
	local keep = {}
	for _, w in ipairs(S.waiting) do
		if w.t <= S.now + 1e-9 then
			table.insert(due, w)
		else
			table.insert(keep, w)
		end
	end
	if #due == 0 then
		return
	end
	S.waiting = keep
	table.sort(due, function(a, b)
		return a.t < b.t
	end)
	for _, w in ipairs(due) do
		if w.args then
			S.resume(w.thread, table.unpack(w.args, 1, w.args.n))
		else
			S.resume(w.thread)
		end
	end
end

-- One simulated frame.
function S.step(dt)
	dt = dt or S.dt
	S.stepping = true
	S.now += dt
	S.frame += 1
	local hooks = S.frameHooks
	if hooks.render then
		hooks.render(dt)
	end
	resumeDue()
	if hooks.simulate then
		hooks.simulate(dt)
	end
	if hooks.tweens then
		hooks.tweens(dt)
	end
	S.flushDeferred()
	if hooks.layout then
		hooks.layout()
	end
	S.stepping = false
end

-- Runs `fn` as the main thread; steps frames until it finishes. Returns ok, err.
function S.runMain(fn, maxSeconds)
	local done, ok, err = false, true, nil
	local main = coroutine.create(function()
		local success, e = xpcall(fn, debug.traceback)
		if not success then
			ok, err = false, e
		end
		done = true
	end)
	S.resume(main)
	S.flushDeferred()
	local limit = S.now + (maxSeconds or 120)
	while not done do
		if S.now > limit then
			return false, string.format("scene did not finish within %d simulated seconds", maxSeconds or 120)
		end
		S.step(S.dt)
	end
	return ok, err
end

-- The task library given to game code.
function S.taskLibrary()
	return {
		spawn = S.spawn,
		defer = S.defer,
		delay = S.delay,
		wait = S.wait,
		cancel = S.cancel,
		synchronize = function() end,
		desynchronize = function() end,
	}
end

R.S = S
return S
