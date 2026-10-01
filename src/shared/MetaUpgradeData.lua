--[[
	MetaUpgradeData.lua
	Permanent upgrades bought with gold in the lobby shop.

	Fields:
	  MaxLevel     number of levels
	  BaseCost     price of level 1
	  CostGrowth   each next level costs BaseCost * CostGrowth^(owned levels)
	  PerLevel     stat bonus per level (same keys as PassiveData values), or
	  Special      "Revive" | "Reroll" | "Skip" (handled by RunManager / LevelUpSystem)
]]

local MetaUpgradeData = {}

MetaUpgradeData.Order = { "MaxHP", "Might", "Armor", "Speed", "Luck", "Growth", "Revive", "Reroll", "Skip" }

MetaUpgradeData.Upgrades = {
	MaxHP = {
		Id = "MaxHP",
		Name = "Max HP",
		Description = "+10 max HP per level.",
		MaxLevel = 5,
		BaseCost = 200,
		CostGrowth = 1.5,
		PerLevel = { maxHpFlat = 10 },
		Color = Color3.fromRGB(255, 90, 110),
	},
	Might = {
		Id = "Might",
		Name = "Might",
		Description = "+5% damage per level.",
		MaxLevel = 5,
		BaseCost = 300,
		CostGrowth = 1.5,
		PerLevel = { might = 0.05 },
		Color = Color3.fromRGB(230, 70, 60),
	},
	Armor = {
		Id = "Armor",
		Name = "Armor",
		Description = "-1 damage taken per hit per level.",
		MaxLevel = 3,
		BaseCost = 400,
		CostGrowth = 1.8,
		PerLevel = { armor = 1 },
		Color = Color3.fromRGB(150, 150, 165),
	},
	Speed = {
		Id = "Speed",
		Name = "Speed",
		Description = "+5% move speed per level.",
		MaxLevel = 3,
		BaseCost = 300,
		CostGrowth = 1.6,
		PerLevel = { speed = 0.05 },
		Color = Color3.fromRGB(80, 200, 255),
	},
	Luck = {
		Id = "Luck",
		Name = "Luck",
		Description = "+10% luck per level.",
		MaxLevel = 3,
		BaseCost = 350,
		CostGrowth = 1.6,
		PerLevel = { luck = 0.10 },
		Color = Color3.fromRGB(110, 230, 80),
	},
	Growth = {
		Id = "Growth",
		Name = "Growth",
		Description = "+5% XP per level.",
		MaxLevel = 3,
		BaseCost = 400,
		CostGrowth = 1.6,
		PerLevel = { growth = 0.05 },
		Color = Color3.fromRGB(60, 200, 120),
	},
	Revive = {
		Id = "Revive",
		Name = "Revive",
		Description = "One extra life every run.",
		MaxLevel = 1,
		BaseCost = 2500,
		CostGrowth = 1,
		Special = "Revive",
		PerRun = 1, -- extra lives per run per level
		Color = Color3.fromRGB(255, 215, 90),
	},
	Reroll = {
		Id = "Reroll",
		Name = "Reroll",
		Description = "+2 level-up rerolls every run per level.",
		MaxLevel = 2,
		BaseCost = 800,
		CostGrowth = 2,
		Special = "Reroll",
		PerRun = 2, -- rerolls per run per level
		Color = Color3.fromRGB(120, 180, 255),
	},
	Skip = {
		Id = "Skip",
		Name = "Skip",
		Description = "Skip up to 5 level-ups per run (each skip gives a little gold).",
		MaxLevel = 1,
		BaseCost = 600,
		CostGrowth = 1,
		Special = "Skip",
		PerRun = 5, -- skips per run per level
		Color = Color3.fromRGB(200, 200, 200),
	},
}

-- Gold price of the next level, or nil when maxed.
function MetaUpgradeData.CostOf(upgradeId: string, ownedLevel: number): number?
	local def = MetaUpgradeData.Upgrades[upgradeId]
	if not def or ownedLevel >= def.MaxLevel then
		return nil
	end
	return math.floor(def.BaseCost * def.CostGrowth ^ ownedLevel + 0.5)
end

return MetaUpgradeData
