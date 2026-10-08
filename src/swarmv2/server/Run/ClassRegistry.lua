--!strict
--[[
	SwarmV2/Run/ClassRegistry.lua  (ServerScriptService.SwarmV2.Run.ClassRegistry)
	OWNER: gameplay track (Chat 2). Registers the four playable classes at RunBoot time.

	ClassRegistry.Init() inserts ruckus, toastmaster, captain_croak and granny_boom into
	CharacterData.Characters (only ids that are missing, never overwriting), so Hero Mastery,
	hero upgrades, stats, leaderboards, AccountService and DataService all accept the ids.
	The old 11 heroes leave CharacterData.Order (hidden everywhere the run side lists heroes);
	their Characters entries and all their save data stay. See ClassRoster (shared) for the
	data and RunConfig.Classes for the numbers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CharacterData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CharacterData"))
local MetaUpgradeData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MetaUpgradeData"))
local V2 = ReplicatedStorage:WaitForChild("SwarmV2")
local ClassRoster = require(V2:WaitForChild("Run"):WaitForChild("ClassRoster"))
local RunConfig = require(V2:WaitForChild("Run"):WaitForChild("RunConfig"))

local ClassRegistry = {}

local done = false

-- Registers the classes (idempotent). Returns the ids added this call.
function ClassRegistry.Init(): { string }
	local added = ClassRoster.Register(CharacterData, MetaUpgradeData)
	if not done then
		done = true
		print(string.format("[SwarmV2] classes registered: %s", table.concat(RunConfig.Classes.Order, ", ")))
	end
	return added
end

-- Is `id` one of the four playable classes?
function ClassRegistry.IsClass(id: any): boolean
	return type(id) == "string" and table.find(RunConfig.Classes.Order, id) ~= nil
end

-- Is `id` one of the hidden old heroes?
function ClassRegistry.IsLegacy(id: any): boolean
	return ClassRoster.IsLegacy(id)
end

-- The hero a run actually plays for a saved / requested id: a hidden old hero becomes the
-- default class; anything else is returned as is (RunManager already falls back to the
-- default for an unknown id).
function ClassRegistry.RunHero(id: any): any
	if RunConfig.Classes.MapLegacyToDefault and ClassRoster.IsLegacy(id) then
		return RunConfig.Classes.Default
	end
	return id
end

return ClassRegistry
