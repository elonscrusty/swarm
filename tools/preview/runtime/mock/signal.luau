--!nocheck
--[[
	signal.luau - RBXScriptSignal / RBXScriptConnection.

	Immediate mode: _fire runs every handler right away, each in its own thread
	(task.spawn semantics), so a handler that yields never blocks the others.
]]

local R = require("./R")
local S = require("./scheduler")

local Connection = {}
Connection.__index = Connection
Connection.__type = "RBXScriptConnection"
Connection.__tostring = function()
	return "Connection"
end

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local list = self._signal._conns
	local i = table.find(list, self)
	if i then
		table.remove(list, i)
	end
	local onDisconnect = self._signal._onDisconnect
	if onDisconnect then
		onDisconnect(self._signal)
	end
end

local Signal = {}
Signal.__index = Signal
Signal.__type = "RBXScriptSignal"
Signal.__tostring = function(self)
	return "Signal " .. tostring(self._name)
end

function Signal.new(name: string?, onConnect: ((any) -> ())?)
	return setmetatable({ _conns = {}, _name = name or "Signal", _onConnect = onConnect }, Signal)
end

function Signal:Connect(fn)
	if type(fn) ~= "function" then
		error("Attempt to connect failed: Passed value is not a function", 2)
	end
	local c = setmetatable({ Connected = true, _fn = fn, _signal = self }, Connection)
	table.insert(self._conns, c)
	if self._onConnect then
		self._onConnect(self)
	end
	return c
end

Signal.connect = Signal.Connect
Signal.ConnectParallel = Signal.Connect

function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end

function Signal:Wait()
	local thread = coroutine.running()
	if not coroutine.isyieldable() then
		error("Signal:Wait() called from a thread that cannot yield", 2)
	end
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		S.resume(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:HasConnections(): boolean
	return #self._conns > 0
end

-- Internal: fire every connected handler.
function Signal:_fire(...)
	local conns = self._conns
	local n = #conns
	if n == 0 then
		return
	end
	if n == 1 then
		local c = conns[1]
		S.spawn(c._fn, ...)
		return
	end
	local list = table.clone(conns)
	for _, c in ipairs(list) do
		if c.Connected then
			S.spawn(c._fn, ...)
		end
	end
end

-- Internal: call handlers synchronously in this thread (used for callbacks that must
-- finish before the caller continues, e.g. BindToRenderStep).
function Signal:_fireSync(...)
	local list = table.clone(self._conns)
	for _, c in ipairs(list) do
		if c.Connected then
			local ok, err = xpcall(c._fn, debug.traceback, ...)
			if not ok then
				R.error(tostring(err))
			end
		end
	end
end

R.Signal = Signal
return Signal
