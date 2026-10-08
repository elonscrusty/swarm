--!strict
--[[
	SwarmV2/Lobby/Clock.lua  (ServerScriptService.SwarmV2.Lobby.Clock)
	OWNER: lobby track (Chat 1). The lobby's clocks in one place so regressions can drive them.
	  Unix()  whole UTC seconds (os.time): ticket createdAt / expiresAt. The same on every
	          Roblox server, so a ticket written by the lobby expires on time on the match server.
	  Mono()  this server's monotonic seconds (os.clock): countdowns, cooldowns, timeouts.
	  ServerTime()  workspace:GetServerTimeNow(): what clients count down to.
]]

local Clock = {}

local unix = function(): number
	return os.time()
end
local mono = function(): number
	return os.clock()
end

function Clock.Unix(): number
	return unix()
end

function Clock.Mono(): number
	return mono()
end

function Clock.ServerTime(): number
	local ok, t = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	return ok and t or os.time()
end

-- Tests only: replace a clock (nil keeps the current one).
function Clock._Set(newUnix: (() -> number)?, newMono: (() -> number)?)
	if newUnix then
		unix = newUnix
	end
	if newMono then
		mono = newMono
	end
end

return Clock
