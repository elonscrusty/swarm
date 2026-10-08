--!strict
--[[
	SwarmV2/MatchAdmission.lua  (ServerScriptService.SwarmV2.MatchAdmission)
	OWNER: lobby track (Chat 1). Contract: docs/redesign/OWNERSHIP.md and SwarmV2.Types.

	PLACEHOLDER from the shared base: it rejects everyone with NOT_READY. Chat 1 replaces
	the body with the real ticket check and return teleport, keeping these two functions
	and their result shapes. Gameplay tests use their own dev provider (SwarmV2.Run), never
	this file.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Types"))

type AdmissionResult = Types.AdmissionResult
type ReturnResult = Types.ReturnResult

local MatchAdmission = {}

-- "lobby": public lobby server. "match": reserved run server reached by teleport.
-- "local": Studio / unpublished / transfer switched off: lobby and run share this server and
-- the lobby hands its match straight to SwarmV2.Run.RunEntry.BeginLocalMatch.
export type ServerRole = "lobby" | "match" | "local"

function MatchAdmission.ServerRole(): ServerRole
	return "local"
end

function MatchAdmission.ResolvePlayer(_player: Player): AdmissionResult
	return { ok = false, errorCode = "NOT_READY", message = "Match admission is not set up yet." }
end

function MatchAdmission.ReturnToLobby(players: { Player }): { ReturnResult }
	local out: { ReturnResult } = {}
	for _, p in ipairs(players) do
		table.insert(out, { userId = p.UserId, ok = false, errorCode = "NOT_READY", message = "Return is not set up yet." })
	end
	return out
end

return MatchAdmission
