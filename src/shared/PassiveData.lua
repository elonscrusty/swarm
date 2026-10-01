--[[
	PassiveData.lua
	12 passive items, 5 levels each. `Values[level]` is the TOTAL bonus at that level
	(not the increment), so stat calculation is a single lookup.

	Stat keys (summed into the player's stat sheet by LevelUpSystem.RecomputeStats):
	  might          +damage multiplier (0.1 = +10%)
	  armor          flat damage reduction per hit
	  maxHpMult      +max HP multiplier
	  speed          +move speed multiplier
	  cooldown       cooldown reduction (0.06 = -6%)
	  area           +area multiplier
	  amount         +projectiles per attack
	  pickup         +pickup radius multiplier
	  luck           +luck
	  projSpeed      +projectile speed multiplier
	  duration       +duration multiplier
	  growth         +XP multiplier
]]

local PassiveData = {}

PassiveData.MaxLevel = 5

PassiveData.Order = {
	"Might",
	"Armor",
	"Heart",
	"SpeedBoots",
	"Cooldown",
	"Area",
	"Duplicator",
	"Vacuum",
	"Luck",
	"Ammo",
	"Candle",
	"Growth",
}

PassiveData.Passives = {
	Might = {
		Id = "Might",
		Name = "Might",
		Color = Color3.fromRGB(230, 70, 60),
		Description = "+10% damage per level.",
		Values = {
			{ might = 0.10 },
			{ might = 0.20 },
			{ might = 0.30 },
			{ might = 0.40 },
			{ might = 0.50 },
		},
	},
	Armor = {
		Id = "Armor",
		Name = "Armor",
		Color = Color3.fromRGB(150, 150, 160),
		Description = "Take 1 less damage from every hit per level.",
		Values = {
			{ armor = 1 },
			{ armor = 2 },
			{ armor = 3 },
			{ armor = 4 },
			{ armor = 5 },
		},
	},
	Heart = {
		Id = "Heart",
		Name = "Heart",
		Color = Color3.fromRGB(255, 90, 130),
		Description = "+20% max HP per level.",
		Values = {
			{ maxHpMult = 0.20 },
			{ maxHpMult = 0.40 },
			{ maxHpMult = 0.60 },
			{ maxHpMult = 0.80 },
			{ maxHpMult = 1.00 },
		},
	},
	SpeedBoots = {
		Id = "SpeedBoots",
		Name = "Speed Boots",
		Color = Color3.fromRGB(80, 200, 255),
		Description = "+8% move speed per level.",
		Values = {
			{ speed = 0.08 },
			{ speed = 0.16 },
			{ speed = 0.24 },
			{ speed = 0.32 },
			{ speed = 0.40 },
		},
	},
	Cooldown = {
		Id = "Cooldown",
		Name = "Cooldown",
		Color = Color3.fromRGB(120, 230, 160),
		Description = "Weapons fire 6% more often per level.",
		Values = {
			{ cooldown = 0.06 },
			{ cooldown = 0.12 },
			{ cooldown = 0.18 },
			{ cooldown = 0.24 },
			{ cooldown = 0.30 },
		},
	},
	Area = {
		Id = "Area",
		Name = "Area",
		Color = Color3.fromRGB(255, 170, 60),
		Description = "+10% attack area per level.",
		Values = {
			{ area = 0.10 },
			{ area = 0.20 },
			{ area = 0.30 },
			{ area = 0.40 },
			{ area = 0.50 },
		},
	},
	Duplicator = {
		Id = "Duplicator",
		Name = "Duplicator",
		Color = Color3.fromRGB(200, 120, 255),
		Description = "+1 projectile on levels 1, 3 and 5.",
		Values = {
			{ amount = 1 },
			{ amount = 1 },
			{ amount = 2 },
			{ amount = 2 },
			{ amount = 3 },
		},
	},
	Vacuum = {
		Id = "Vacuum",
		Name = "Vacuum",
		Color = Color3.fromRGB(90, 255, 220),
		Description = "+30% pickup radius per level.",
		Values = {
			{ pickup = 0.30 },
			{ pickup = 0.60 },
			{ pickup = 0.90 },
			{ pickup = 1.20 },
			{ pickup = 1.50 },
		},
	},
	Luck = {
		Id = "Luck",
		Name = "Luck",
		Color = Color3.fromRGB(110, 230, 80),
		Description = "+10% luck per level (rare drops, better cards).",
		Values = {
			{ luck = 0.10 },
			{ luck = 0.20 },
			{ luck = 0.30 },
			{ luck = 0.40 },
			{ luck = 0.50 },
		},
	},
	Ammo = {
		Id = "Ammo",
		Name = "Ammo",
		Color = Color3.fromRGB(240, 220, 120),
		Description = "+10% projectile speed per level, +1 projectile at level 5.",
		Values = {
			{ projSpeed = 0.10 },
			{ projSpeed = 0.20 },
			{ projSpeed = 0.30 },
			{ projSpeed = 0.40 },
			{ projSpeed = 0.50, amount = 1 },
		},
	},
	Candle = {
		Id = "Candle",
		Name = "Candle",
		Color = Color3.fromRGB(255, 140, 40),
		Description = "+10% effect duration per level.",
		Values = {
			{ duration = 0.10 },
			{ duration = 0.20 },
			{ duration = 0.30 },
			{ duration = 0.40 },
			{ duration = 0.50 },
		},
	},
	Growth = {
		Id = "Growth",
		Name = "Growth",
		Color = Color3.fromRGB(60, 200, 120),
		Description = "+8% XP gained per level.",
		Values = {
			{ growth = 0.08 },
			{ growth = 0.16 },
			{ growth = 0.24 },
			{ growth = 0.32 },
			{ growth = 0.40 },
		},
	},
}

-- Text for a level-up card when the passive goes to `level`.
function PassiveData.DescribeLevel(passiveId: string, level: number): string
	local def = PassiveData.Passives[passiveId]
	if not def then
		return ""
	end
	if level <= 1 then
		return def.Description
	end
	return string.format("Level %d: %s", level, def.Description)
end

return PassiveData
