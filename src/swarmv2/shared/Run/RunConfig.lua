--!strict
--[[
	RunConfig.lua
	Run numbers of the gameplay track (docs/redesign/OWNERSHIP.md). One section per system.
]]

local RunConfig = {}

-- One continuous map for every stage of a run (docs/redesign/gameplay/DESIGN.md section 5).
RunConfig.Map = {
	MapName = "Cliffwood", -- the single-map arena
	SingleMap = true, -- false: every stage builds its own arena as before
	BossLandmark = "Stone Circle", -- portal landmark of stage 5 and the Endless boss-milestone stages
	TransitionSeconds = 0.7, -- the burst effect plays, then the old stage is cleared and the new one placed
	PortalLandmarkMargin = 14, -- portal spot stays this far inside the landmark radius
}

return RunConfig
