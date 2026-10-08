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
-- Read by src/server/Modules/HeightGrid.lua (and the run modules that ask it). With no part
-- tagged GroundTag in the arena, none of this is used: every run module keeps today's flat
-- floor at Config.ArenaOrigin.Y.
RunConfig.Nav = {
	GroundTag = "NavGround", -- CollectionService tag: floors, terraces, ramps, bridge decks, cave floors
	BlockTag = "NavBlock", -- tag (on a part or its model): cliff faces, water, gaps; never walkable
	CellSize = 4, -- studs per grid cell
	StepMax = 3.2, -- most height change between neighbour cells (per 4 studs, about 38 degrees)
	MaxCells = 160000, -- safety cap on the grid size (1100 x 1100 studs at 4 = ~76k)
	RayPad = 20, -- the down rays start this far above the highest tagged part
	-- flow fields (one Dijkstra fill per living run player)
	FieldRadius = 72, -- cells (288 studs)
	FieldRebuild = 0.25, -- seconds between starting field rebuilds (round robin, one player each)
	FieldBudget = 6000, -- cells settled per server frame while a field builds (spreads the cost)
	-- enemy steering (EnemyAI.think)
	DirectSeekRange = 10, -- closer than this with a steppable straight line: seek directly
	-- vertical bands (|dy| between ground heights)
	ContactBand = 6, -- enemy contact damage
	HitBand = 7, -- weapon hits and weapon targeting (a weapon's Params.HitBand overrides)
	HazardBand = 6, -- enemy ground strikes, patches and waves
	RootHeight = 3, -- a standing hero's root above the ground
	-- spawning (EnemySpawner.SpawnPoint)
	SpawnMinPath = 45, -- path distance from the hero, studs
	SpawnMaxPath = 80,
	SpawnTries = 10,
	-- fall rescue (RunManager): below GroundY - RescueBelow, back to the last good ground spot
	RescueBelow = 40,
	SafeAbove = 8, -- a root at most this high above the ground counts as standing on it
}

-- [Cliffwood Basin map] -----------------------------------------------------------------
RunConfig.Map = {}

-- [Class kits] --------------------------------------------------------------------------
RunConfig.Classes = {}

-- [Run entry + admission] ---------------------------------------------------------------
RunConfig.Entry = {}

return RunConfig
