--!strict
--[[
	SwarmV2/Lobby/LobbyBoot.lua  (ServerScriptService.SwarmV2.Lobby.LobbyBoot)
	OWNER: lobby track (Chat 1). Boot hook from the shared base: called once at startup, after the
	existing modules. Empty until this track fills it. See docs/redesign/OWNERSHIP.md.
]]

local LobbyBoot = {}

function LobbyBoot.Init(ctx: any) end

return LobbyBoot
