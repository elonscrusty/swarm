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
RunConfig.Entry = {}

return RunConfig
