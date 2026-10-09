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

-- { [classId] = true } for the classes this save owns.
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
	if info.GoalOnly then
		return "GOAL_ONLY" -- earned by play only (DECISIONS C2)
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

------------------------------------------------------------------------------------------
-- [integration, continuation pack] earnable goals (DECISIONS C2/C3). The run settlement fills
-- data.Stats.ClassGoals (SwarmV2.Run.ClassGoals); a met goal unlocks its class once, for free.
------------------------------------------------------------------------------------------

local function goalCount(data: any, stat: string): number
	local goals = type(data) == "table" and type(data.Stats) == "table" and data.Stats.ClassGoals
	local v = type(goals) == "table" and goals[stat]
	return (type(v) == "number" and v == v) and v or 0
end

-- True when this save meets the class's goal (any one of Goal.Any when present).
function ClassOwnership.GoalMet(data: any, classId: any): boolean
	local info = ClassCatalog.Get(classId)
	local goal = info and info.Goal
	if not goal then
		return false
	end
	if type(goal.Any) == "table" then
		for _, g in ipairs(goal.Any) do
			if type(g.Stat) == "string" and type(g.Need) == "number" and goalCount(data, g.Stat) >= g.Need then
				return true
			end
		end
		return false
	end
	return goalCount(data, goal.Stat) >= goal.Need
end

-- Progress toward a class goal for the class browser: (have, need) of the main stat.
function ClassOwnership.GoalProgress(data: any, classId: any): (number, number)
	local info = ClassCatalog.Get(classId)
	local goal = info and info.Goal
	if not goal then
		return 0, 0
	end
	return math.min(goalCount(data, goal.Stat), goal.Need), goal.Need
end

-- [stream L1] Goal progress for the class browser (LobbyView.Progress). One entry per class that
-- has a goal and is not owned yet: Have / Need of the main stat (Have capped at Need), and Parts
-- (every stat of an "any one of" goal, e.g. Knuckles: a boss OR a revive) when the goal has them.
-- Pure: reads data.Stats.ClassGoals only, never writes.
export type Progress = { Have: number, Need: number, Stat: string, Parts: { { Stat: string, Have: number, Need: number } }? }
function ClassOwnership.ProgressOf(data: any, classId: any): Progress?
	local info = ClassCatalog.Get(classId)
	local goal = info and info.Goal
	if not goal then
		return nil
	end
	local out: Progress = {
		Have = math.min(goalCount(data, goal.Stat), goal.Need),
		Need = goal.Need,
		Stat = goal.Stat,
	}
	if type(goal.Any) == "table" then
		local parts = {}
		for _, g in ipairs(goal.Any) do
			if type(g.Stat) == "string" and type(g.Need) == "number" then
				table.insert(parts, { Stat = g.Stat, Have = math.min(goalCount(data, g.Stat), g.Need), Need = g.Need })
			end
		end
		out.Parts = parts
	end
	return out
end

function ClassOwnership.ProgressAll(data: any): { [string]: Progress }
	local out: { [string]: Progress } = {}
	for _, id in ipairs(ClassCatalog.Order) do
		if not ClassOwnership.Owns(data, id) then
			local p = ClassOwnership.ProgressOf(data, id)
			if p then
				out[id] = p
			end
		end
	end
	return out
end

-- Unlocks every class whose goal is met and that this save doesn't own yet. Pure; returns the
-- newly unlocked ids (never removes anything, never charges gold).
function ClassOwnership.EarnGoals(data: any): { string }
	local out = {}
	if type(data) ~= "table" then
		return out
	end
	for _, id in ipairs(ClassCatalog.Order) do
		if not ClassOwnership.Owns(data, id) and ClassOwnership.GoalMet(data, id) then
			ClassOwnership.EnsureDefault(data)
			data.OwnedCharacters[id] = true
			table.insert(out, id)
		end
	end
	return out
end

-- The run side's call after its settlement (ClassGoals.RefreshEarned): grants met goals on the
-- player's loaded save; the normal DataService save persists them. Newly unlocked ids.
function ClassOwnership.RefreshEarned(player: Player): { string }
	local modules = game:GetService("ServerScriptService"):FindFirstChild("Modules")
	local ds = modules and modules:FindFirstChild("DataService")
	if not ds or not ds:IsA("ModuleScript") then
		return {}
	end
	local DataService = require(ds) :: any
	local data = DataService.GetData(player)
	return ClassOwnership.EarnGoals(data)
end

return ClassOwnership
