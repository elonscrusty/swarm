-- levelup: the level-up offer over the arena (LevelUpOffer remote with three real cards:
-- a weapon upgrade, a new passive and an evolution, described by the game's own data).
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 90 })
C.settle(1.5)
local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local Config = C.shared("Config")
local function rarity(name)
	local r = Config.LevelUp.Rarities[name]
	return r.Label, r.Color
end
local choices = {}
if WeaponData and PassiveData and Config then
	local w2 = WeaponData.Order[2]
	local wdef = WeaponData.Weapons[w2]
	local label, color = rarity("Common")
	table.insert(choices, { Type = "WeaponUp", Id = w2, Level = 6, Name = wdef.Name, Description = WeaponData.DescribeLevel(w2, 6), Color = wdef.Color, Rarity = "Common", RarityLabel = label, RarityColor = color })
	local p = PassiveData.Order[5]
	local pdef = PassiveData.Passives[p]
	label, color = rarity("Rare")
	table.insert(choices, { Type = "PassiveNew", Id = p, Level = 1, Name = pdef.Name, Description = PassiveData.DescribeLevel(p, 1), Color = pdef.Color, Rarity = "Rare", RarityLabel = label, RarityColor = color })
	local w1 = WeaponData.Order[3]
	local edef = WeaponData.Weapons[w1]
	label, color = rarity("Legendary")
	table.insert(choices, { Type = "Evolve", Id = w1, Level = WeaponData.MaxLevel, Name = edef.Evolution.Name, Description = edef.Evolution.Description, Color = edef.Color, Rarity = "Legendary", RarityLabel = label, RarityColor = color })
end
C.fire("LevelUpOffer", { Choices = choices, Rerolls = 1, Skips = 1, Seconds = 25, Level = 14, Pending = 1 })
C.setState({ Frozen = true, LevelUpPause = true })
C.settle(1.5)
