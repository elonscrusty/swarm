--[[
	DevAllowlist.lua  (server only: ServerScriptService is never sent to clients)
	UserIds that are developers in live servers (DevAccess.lua): the DEV button and panel,
	every DEV command and the bug inbox. Studio is always dev. Add a UserId here to give
	someone dev access; nothing on the client can grant it.
]]

return {
	[20194281] = true, -- owner
}
