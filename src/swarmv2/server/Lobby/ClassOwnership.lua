--!strict
--[[
	SwarmV2/Lobby/ClassOwnership.lua  (ServerScriptService.SwarmV2.Lobby.ClassOwnership)
	OWNER: lobby track (Chat 1). Class ownership and selection on a loaded save table
	(DataService.GetData). Pure: no Roblox calls, so the queue, the shop and MatchAdmission
	all apply the same rules and the regressions can test them directly.

	Persistence (docs/redesign/DECISIONS.md, additive, no new save key):
	  OwnedCharacters {id → true}  the same set the old heroes use; the four class ids are added
	                               to it. "ruckus" is owned by every account (DataService also
	                               fills it in on load). Old hero ids stay in it untouched.
	  SelectedCharacter            the selected class id. An old hero id still stored there is
	                               read as "ruckus" and left as it is until the player picks.
	  Gold                         class prices (ClassCatalog.Cost) are paid from the same gold.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ClassCatalog = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("ClassCatalog"))

local ClassOwnership = {}

local function owned(data: any): { [string]: any }?
	local set = type(data) == "table" and data.OwnedCharacters
	return type(set) == "table" and set or nil
end

-- True when this save may play `classId` (a canonical id only; legacy ids never pass).
function ClassOwnership.Owns(data: any, classId: any): boolean
	if not ClassCatalog.IsClassId(classId) or type(data) ~= "table" then
		return false
	end
	if classId == ClassCatalog.Default then
		return true
	end
	local set = owned(data)
	return set ~= nil and set[classId] == true
end

-- The class this save plays: the stored selection when it is an owned class, else the default.
function ClassOwnership.Selected(data: any): string
	local sel = type(data) == "table" and data.SelectedCharacter or nil
	if ClassCatalog.IsClassId(sel) and ClassOwnership.Owns(data, sel) then
		return sel :: string
	end
	return ClassCatalog.Default
end

-- { [classId] = true } for the four classes this save owns.
function ClassOwnership.OwnedSet(data: any): { [string]: boolean }
	local out = {}
	for _, id in ipairs(ClassCatalog.Order) do
		if ClassOwnership.Owns(data, id) then
			out[id] = true
		end
	end
	return out
end

-- Fills in the free class (old saves; called on profile load). Never removes anything.
function ClassOwnership.EnsureDefault(data: any)
	if type(data) ~= "table" then
		return
	end
	if type(data.OwnedCharacters) ~= "table" then
		data.OwnedCharacters = {}
	end
	data.OwnedCharacters[ClassCatalog.Default] = true
end

-- Selects an owned class. Returns nil on success, else an error code.
function ClassOwnership.Select(data: any, classId: any): string?
	if not ClassCatalog.IsClassId(classId) then
		return "UNKNOWN_CLASS"
	end
	if not ClassOwnership.Owns(data, classId) then
		return "NOT_OWNED"
	end
	data.SelectedCharacter = classId
	return nil
end

-- Buys a class with gold and selects it. Returns nil on success, else an error code
-- ("UNKNOWN_CLASS" | "OWNED" | "NO_GOLD" | "NO_SAVE").
function ClassOwnership.Buy(data: any, classId: any): string?
	if type(data) ~= "table" then
		return "NO_SAVE"
	end
	local info = ClassCatalog.Get(classId)
	if not info then
		return "UNKNOWN_CLASS"
	end
	if ClassOwnership.Owns(data, classId) then
		return "OWNED"
	end
	local gold = type(data.Gold) == "number" and data.Gold == data.Gold and data.Gold or 0
	if gold < info.Cost then
		return "NO_GOLD"
	end
	ClassOwnership.EnsureDefault(data)
	data.Gold = gold - info.Cost
	data.OwnedCharacters[info.Id] = true
	data.SelectedCharacter = info.Id
	return nil
end

return ClassOwnership
