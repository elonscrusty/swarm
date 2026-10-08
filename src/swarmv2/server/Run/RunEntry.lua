--!strict
--[[
	SwarmV2/Run/RunEntry.lua  (ServerScriptService.SwarmV2.Run.RunEntry)
	OWNER: gameplay track (Chat 2). Contract: docs/redesign/OWNERSHIP.md.

	BeginLocalMatch(matchId, players): called by the lobby track only when
	MatchAdmission.ServerRole() == "local" (Studio, unpublished place, transfer off). The
	lobby has already frozen the roster and written the in-memory local ticket, so the run
	side resolves each player through MatchAdmission.ResolvePlayer exactly as on a match
	server. Returns false when a run can't start (the lobby then releases the queue).

	PLACEHOLDER from the shared base: returns false until Chat 2 fills it in.
]]

local RunEntry = {}

function RunEntry.BeginLocalMatch(_matchId: string, _players: { Player }): boolean
	return false
end

return RunEntry
