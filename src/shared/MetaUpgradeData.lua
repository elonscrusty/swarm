--[[
	MetaUpgradeData.lua
	Permanent upgrades bought with gold in the lobby shop.

	Fields:
	  MaxLevel     number of levels
	  BaseCost     price of level 1
	  CostGrowth   each next level costs BaseCost * CostGrowth^(owned levels)
	  PerLevel     stat bonus per level (same keys as PassiveData values), or
	  Special      "Revive" | "Reroll" | "Skip" (handled by RunManager / LevelUpSystem)
	  Effect       { Format, Per }: the total effect at a level for the shop rows,
	               string.format(Format, Per * level) ("+20 max HP")
]]

local MetaUpgradeData = {}

MetaUpgradeData.Order = { "MaxHP", "Might", "Armor", "Speed", "Luck", "Growth", "Revive", "Reroll", "Skip" }

MetaUpgradeData.Upgrades = {
	MaxHP = {
		Id = "MaxHP",
		Effect = { Format = "+%d max HP", Per = 10 },
		Name = "Max HP",
		Description = "+10 max HP per level.",
		MaxLevel = 20,
		BaseCost = 200,
		CostGrowth = 1.5,
		PerLevel = { maxHpFlat = 10 },
		Color = Color3.fromRGB(255, 90, 110),
	},
	Might = {
		Id = "Might",
		Effect = { Format = "+%d%% damage", Per = 5 },
		Name = "Might",
		Description = "+5% damage per level.",
		MaxLevel = 20,
		BaseCost = 300,
		CostGrowth = 1.5,
		PerLevel = { might = 0.05 },
		Color = Color3.fromRGB(230, 70, 60),
	},
	Armor = {
		Id = "Armor",
		Effect = { Format = "-%d damage taken per hit", Per = 1 },
		Name = "Armor",
		Description = "-1 damage taken per hit per level.",
		MaxLevel = 8,
		BaseCost = 400,
		CostGrowth = 1.8,
		PerLevel = { armor = 1 },
		Color = Color3.fromRGB(150, 150, 165),
	},
	Speed = {
		Id = "Speed",
		Effect = { Format = "+%d%% move speed", Per = 5 },
		Name = "Speed",
		Description = "+5% move speed per level.",
		MaxLevel = 6,
		BaseCost = 300,
		CostGrowth = 1.6,
		PerLevel = { speed = 0.05 },
		Color = Color3.fromRGB(80, 200, 255),
	},
	Luck = {
		Id = "Luck",
		Effect = { Format = "+%d%% luck", Per = 10 },
		Name = "Luck",
		Description = "+10% luck per level.",
		MaxLevel = 10,
		BaseCost = 350,
		CostGrowth = 1.6,
		PerLevel = { luck = 0.10 },
		Color = Color3.fromRGB(110, 230, 80),
	},
	Growth = {
		Id = "Growth",
		Effect = { Format = "+%d%% XP", Per = 5 },
		Name = "Growth",
		Description = "+5% XP per level.",
		MaxLevel = 10,
		BaseCost = 400,
		CostGrowth = 1.6,
		PerLevel = { growth = 0.05 },
		Color = Color3.fromRGB(60, 200, 120),
	},
	Revive = {
		Id = "Revive",
		Effect = { Format = "%d extra life per run", Per = 1 },
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
		Effect = { Format = "%d level-up rerolls per run", Per = 2 },
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
		Effect = { Format = "%d level-up skips per run", Per = 5 },
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

-- Total effect at a level in plain words ("+20 max HP"); "None yet" at level 0.
function MetaUpgradeData.EffectText(upgradeId: string, level: number): string
	local def = MetaUpgradeData.Upgrades[upgradeId]
	if not def or not def.Effect then
		return ""
	end
	if level <= 0 then
		return "None yet"
	end
	return string.format(def.Effect.Format, def.Effect.Per * level)
end

-- Gold price of the next level, or nil when maxed.
function MetaUpgradeData.CostOf(upgradeId: string, ownedLevel: number): number?
	local def = MetaUpgradeData.Upgrades[upgradeId]
	if not def or ownedLevel >= def.MaxLevel then
		return nil
	end
	return math.floor(def.BaseCost * def.CostGrowth ^ ownedLevel + 0.5)
end

return MetaUpgradeData
