--[[
	Events.lua
	A tiny server event bus. Game systems announce what happened to a player and don't need
	to know who listens (today: AchievementService).

	Events.Fire(name, player, data?)   e.g. Events.Fire("GoldenChest", rp.Player)
	Events.On(name, fn)                fn(player, data) - errors are caught and warned

	Event names and their data are listed in src/shared/AchievementData.lua.
]]

local Events = {}

local listeners: { [string]: { (Player, { [string]: any }) -> () } } = {}

function Events.On(name: string, fn: (Player, { [string]: any }) -> ())
	local list = listeners[name]
	if not list then
		list = {}
		listeners[name] = list
	end
	table.insert(list, fn)
end

function Events.Fire(name: string, player: Player?, data: { [string]: any }?)
	if not player then
		return
	end
	local list = listeners[name]
	if not list then
		return
	end
	local payload = data or {}
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn, player, payload)
		if not ok then
			warn(string.format("[Events] %s listener error: %s", name, tostring(err)))
		end
	end
end

return Events
