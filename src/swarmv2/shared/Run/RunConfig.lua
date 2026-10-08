--!strict
--[[
	SwarmV2/Run/RunConfig.lua  (ReplicatedStorage.SwarmV2.Run.RunConfig)
	OWNER: gameplay track. Tuning for the redesign (docs/redesign/gameplay/DESIGN.md). All
	numbers are starting proposals. Each section belongs to one work stream; keep edits
	inside your own section so parallel work merges cleanly.
]]

local RunConfig = {}

-- [Camera + movement + dash] ------------------------------------------------------------
RunConfig.Camera = {}
RunConfig.Movement = {}
RunConfig.Dash = {}

-- [Ground height + navigation] ----------------------------------------------------------
RunConfig.Nav = {}

-- [Cliffwood Basin map] -----------------------------------------------------------------
RunConfig.Map = {}

-- [Class kits] --------------------------------------------------------------------------
RunConfig.Classes = {}

-- [Run entry + admission] ---------------------------------------------------------------
RunConfig.Entry = {
	Arena = "Cliffwood", -- the run map (falls back to the lobby's arena until it exists)
	GroupWaitSeconds = 20, -- after the first admitted arrival
	LateGraceSeconds = 60, -- after the run starts, for missing expected players
	ProfileWaitSeconds = 30, -- save load before admission gives up
	ResolveRetryDelays = { 1, 2, 4 }, -- transient admission failures
	-- error codes that never succeed on retry (anything else is retried)
	TerminalCodes = { "NOT_EXPECTED", "WRONG_SERVER", "WRONG_PLACE", "EXPIRED", "NOT_OWNED", "BAD_CLASS", "NO_TICKET", "UNAUTHORIZED" },
	RejectShowSeconds = 4, -- the reason stays on screen this long before the return
	ReturnAttempts = 2,
}

return RunConfig
