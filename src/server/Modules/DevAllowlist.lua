--[[
	DevAllowlist.lua  (server only: ServerScriptService is never sent to clients)
	UserIds that may open the DEV bug inbox in live servers, on top of the normal dev rule
	(Studio, or the creator when Config.Dev.ShowInLiveGame is on). Add a UserId here to give
	someone inbox access; nothing on the client can grant it.
]]

return {
	[20194281] = true, -- owner
}
