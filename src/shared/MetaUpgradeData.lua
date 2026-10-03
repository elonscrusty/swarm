--[[
	MetaUpgradeData.lua
	Permanent upgrades bought with gold in the lobby.

	Two kinds (Hero Mastery, save schema 7):
	  StatOrder     MaxHP, Might, Armor, Speed, Luck, Growth: bought PER HERO on the
	                Characters screen (data.HeroUpgrades[heroId][id]); a hero's levels only
	                go up to its mastery cap (HeroCap). Same prices / max levels as before.
	  AccountOrder  Revive, Reroll, Skip: account-wide (data.Meta[id], Upgrades screen).
	  Signature     one per hero (Signature[heroId], upgrade id "Signature"): 5 levels that
	                strengthen the hero's trait (TraitValue). The stat ones carry PerLevel
	                (StatSheet adds them); the others are read by WeaponSystem.
	Mastery: Config.HeroMastery (MasteryFor turns a hero's XP into its level). Robux never
	buys any of this.

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
MetaUpgradeData.StatOrder = { "MaxHP", "Might", "Armor", "Speed", "Luck", "Growth" }
MetaUpgradeData.AccountOrder = { "Revive", "Reroll", "Skip" }

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
		Description = "+2 rerolls per run for every level.",
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

local Config = require(script.Parent.Config)

--[[
	Signature upgrades: Trait = { Base, Per } in whole percent: the trait's value at signature
	level L is (Base + Per * L) / 100 (Base = the hero's own trait today). Effect.Format
	prints that percent. PerLevel (stat traits only): what StatSheet adds per level.
]]
local SIGNATURE_COST = { MaxLevel = 5, BaseCost = 500, CostGrowth = 1.6 }
local function signature(hero: string, name: string, base: number, per: number, format: string, perLevel: { [string]: number }?)
	return {
		Id = "Signature",
		Hero = hero,
		Name = name,
		Description = string.format(format, base) .. " now; " .. string.format(format, base + per * SIGNATURE_COST.MaxLevel) .. " at level " .. SIGNATURE_COST.MaxLevel .. ".",
		MaxLevel = SIGNATURE_COST.MaxLevel,
		BaseCost = SIGNATURE_COST.BaseCost,
		CostGrowth = SIGNATURE_COST.CostGrowth,
		Trait = { Base = base, Per = per },
		Effect = { Format = format },
		PerLevel = perLevel,
	}
end
MetaUpgradeData.Signature = {
	Knight = signature("Knight", "Iron Skin", 10, 2, "-%d%% damage taken", { damageTaken = -0.02 }),
	Mage = signature("Mage", "Arcane Reach", 10, 3, "+%d%% area", { area = 0.03 }),
	Rogue = signature("Rogue", "Fleet Foot", 15, 2, "+%d%% move speed", { speed = 0.02 }),
	Priest = signature("Priest", "Blessed", 20, 3, "+%d%% max HP", { maxHpMult = 0.03 }),
	Ranger = signature("Ranger", "Steady Aim", 30, 5, "+%d%% Longbow damage standing still"),
	Alchemist = signature("Alchemist", "Volatile Mix", 20, 3, "+%d%% fire and area damage"),
	Engineer = signature("Engineer", "Tinkerer", 30, 5, "+%d%% turret and totem time"),
	Necromancer = signature("Necromancer", "Soul Harvest", 15, 2, "%d%% soul chance per kill"),
}

function MetaUpgradeData.IsStat(upgradeId: any): boolean
	return type(upgradeId) == "string" and table.find(MetaUpgradeData.StatOrder, upgradeId) ~= nil
end

function MetaUpgradeData.IsAccount(upgradeId: any): boolean
	return type(upgradeId) == "string" and table.find(MetaUpgradeData.AccountOrder, upgradeId) ~= nil
end

-- The definition of one of a hero's own upgrades (a stat id or "Signature"), or nil.
function MetaUpgradeData.HeroDef(heroId: string, upgradeId: any): { [string]: any }?
	if upgradeId == "Signature" then
		return MetaUpgradeData.Signature[heroId]
	end
	if MetaUpgradeData.IsStat(upgradeId) then
		return MetaUpgradeData.Upgrades[upgradeId]
	end
	return nil
end

-- A hero's upgrade ids in screen order: the six stats, then its signature.
function MetaUpgradeData.HeroOrder(): { string }
	local out = table.clone(MetaUpgradeData.StatOrder)
	table.insert(out, "Signature")
	return out
end

-- Gold price of a hero upgrade's next level, or nil when maxed / unknown.
function MetaUpgradeData.HeroCostOf(heroId: string, upgradeId: string, ownedLevel: number): number?
	local def = MetaUpgradeData.HeroDef(heroId, upgradeId)
	if not def or ownedLevel >= def.MaxLevel then
		return nil
	end
	return math.floor(def.BaseCost * def.CostGrowth ^ ownedLevel + 0.5)
end

-- The trait value of a hero at a signature level (0.10 = 10%), or nil for no signature.
function MetaUpgradeData.TraitValue(heroId: string, level: number?): number?
	local def = MetaUpgradeData.Signature[heroId]
	if not def then
		return nil
	end
	local l = math.clamp(math.floor(tonumber(level) or 0), 0, def.MaxLevel)
	return (def.Trait.Base + def.Trait.Per * l) / 100
end

-- A hero upgrade's total effect at a level, in plain words.
function MetaUpgradeData.HeroEffectText(heroId: string, upgradeId: string, level: number): string
	if upgradeId == "Signature" then
		local def = MetaUpgradeData.Signature[heroId]
		if not def then
			return ""
		end
		return string.format(def.Effect.Format, def.Trait.Base + def.Trait.Per * level)
	end
	return MetaUpgradeData.EffectText(upgradeId, level)
end

-- Mastery level needed to buy `nextLevel` of a hero upgrade.
function MetaUpgradeData.RequiredMastery(upgradeId: string, nextLevel: number): number
	local M = Config.HeroMastery
	if upgradeId == "Signature" then
		return M.SignatureEvery * nextLevel
	end
	return math.ceil(nextLevel / M.StatPerLevel)
end

-- Highest level of a hero upgrade its mastery allows (never above the upgrade's max).
function MetaUpgradeData.HeroCap(mastery: number, upgradeId: string, heroId: string?): number
	local M = Config.HeroMastery
	local def = MetaUpgradeData.HeroDef(heroId or "Knight", upgradeId)
	local maxLevel = def and def.MaxLevel or 0
	if upgradeId == "Signature" then
		return math.min(maxLevel, math.floor(mastery / M.SignatureEvery))
	end
	return math.min(maxLevel, mastery * M.StatPerLevel)
end

-- XP from mastery `level` to level + 1.
function MetaUpgradeData.MasteryToNext(level: number): number
	local M = Config.HeroMastery
	return M.Base + M.PerLevel * (math.max(1, level) - 1)
end

-- Mastery level for a hero's total XP, the XP into that level and the XP it needs (0 at max).
function MetaUpgradeData.MasteryFor(totalXP: number?): (number, number, number)
	local xp = math.max(0, math.floor(tonumber(totalXP) or 0))
	local level = 1
	while level < Config.HeroMastery.MaxLevel do
		local need = MetaUpgradeData.MasteryToNext(level)
		if xp < need then
			return level, xp, need
		end
		xp -= need
		level += 1
	end
	return Config.HeroMastery.MaxLevel, 0, 0
end

return MetaUpgradeData
