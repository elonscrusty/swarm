-- Manual journal presentation. Rewards are revealed only by authoritative observations.
local EnemyData = require(script.Parent.EnemyData)
local EnemyJournalData = {}
local dropOrder = { "XP", "Gold", "Chest", "Chicken", "Magnet", "Bomb" }
local dropNames = { XP = "XP gems", Gold = "Gold", Chest = "Chest", Chicken = "Chicken", Magnet = "Magnet", Bomb = "Bomb" }

EnemyJournalData.Order = {}
for id in pairs(EnemyData.Enemies) do table.insert(EnemyJournalData.Order, id) end
table.sort(EnemyJournalData.Order, function(a, b)
	return EnemyData.Enemies[a].DisplayName < EnemyData.Enemies[b].DisplayName
end)

function EnemyJournalData.Entry(profile: any, id: string): { [string]: any }
	local def = EnemyData.Enemies[id]
	local journal = type(profile) == "table" and profile.Journal
	local known = def ~= nil and type(journal) == "table" and type(journal.Enemies) == "table" and journal.Enemies[id] == true
	local drops = {}
	if known then
		local observed = type(journal.Drops) == "table" and journal.Drops[id]
		if type(observed) == "table" then
			for _, drop in ipairs(dropOrder) do if observed[drop] == true then table.insert(drops, dropNames[drop]) end end
		end
	end
	return {
		Known = known,
		Name = known and def.DisplayName or "Undiscovered enemy",
		Clue = known and (id == "Boss" and "Scorpion Queen: watch the ground warnings for stomps, dodge charge lanes, and clear her summoned beetles." or def.Role or "Watch its approach and ground warnings.") or "Encounter this enemy to record its attack clues.",
		Drops = drops,
	}
end

return EnemyJournalData
