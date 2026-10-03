-- Difficulty choices are additive to existing curses and stage scaling.
local DifficultyData = {}

DifficultyData.Order = { "Standard", "Veteran", "Nightmare" }
DifficultyData.Tiers = {
	Standard = { Name = "Standard", Requires = "", HP = 1, Damage = 1, Speed = 1, Density = 1, Gold = 1 },
	Veteran = { Name = "Veteran", Requires = "Standard", HP = 1.35, Damage = 1.15, Speed = 1.05, Density = 1.15, Gold = 1.35 },
	Nightmare = { Name = "Nightmare", Requires = "Veteran", HP = 1.75, Damage = 1.35, Speed = 1.12, Density = 1.25, Gold = 1.75 },
}

function DifficultyData.IsUnlocked(profile: any, id: string): boolean
	local tier = DifficultyData.Tiers[id]
	if not tier then
		return false
	end
	if tier.Requires == "" then
		return true
	end
	if type(profile) ~= "table" then
		return false
	end
	local clears = profile.DifficultyClears
	if type(clears) == "table" and clears[tier.Requires] == true then
		return true
	end
	return false -- historical winners receive a clear flag once during save migration
end

function DifficultyData.Selected(profile: any): string
	local id = type(profile) == "table" and profile.Difficulty or "Standard"
	return type(id) == "string" and DifficultyData.IsUnlocked(profile, id) and id or "Standard"
end

return DifficultyData
