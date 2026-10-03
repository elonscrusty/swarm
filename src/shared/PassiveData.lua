--[[
	PassiveData.lua
	15 passive items, 3-5 levels each (PassiveData.MaxLevelOf). `Values[level]` is the TOTAL bonus at that level
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
	  pierce         +enemies a stopping projectile passes through
	  critChance     +chance for a hit to crit (an item stat, also used by Precision)
	  regen          HP per second (an item stat, also used by Renewal)

	Synergies: Area, Candle, Precision and Armor are pieces of the build synergies in
	SynergyData.lua (a small extra bonus once the whole set is owned).
]]

local PassiveData = {}

-- Highest level any passive has (each passive has its own MaxLevel: see MaxLevelOf).
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
	"Fletching",
	"Precision",
	"Renewal",
}

--[[
	Levels: every level must be a step a player can feel. Passives that used to grow in tiny
	5-8% steps (or, like Duplicator, had empty levels) now have fewer, bigger levels with the
	same total at max. Description = the short summary on a NEW card; level cards print the
	real stat change (StatSheet.Lines, e.g. "Max HP 120 → 144").
]]
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
		Description = "+10% move speed per level.",
		Values = {
			{ speed = 0.10 },
			{ speed = 0.20 },
			{ speed = 0.30 },
			{ speed = 0.40 },
		},
	},
	Cooldown = {
		Id = "Cooldown",
		Name = "Cooldown",
		Color = Color3.fromRGB(120, 230, 160),
		Description = "Weapons attack about 8% more often per level.",
		Values = {
			{ cooldown = 0.08 },
			{ cooldown = 0.15 },
			{ cooldown = 0.22 },
			{ cooldown = 0.30 },
		},
	},
	Area = {
		Id = "Area",
		Name = "Area",
		Color = Color3.fromRGB(255, 170, 60),
		Description = "+12% attack area per level.",
		Values = {
			{ area = 0.12 },
			{ area = 0.25 },
			{ area = 0.37 },
			{ area = 0.50 },
		},
	},
	Duplicator = {
		Id = "Duplicator",
		Name = "Duplicator",
		Color = Color3.fromRGB(200, 120, 255),
		Description = "+1 projectile, swing or strike per level (not the aura).",
		Values = {
			{ amount = 1 },
			{ amount = 2 },
			{ amount = 3 },
		},
	},
	Vacuum = {
		Id = "Vacuum",
		Name = "Vacuum",
		Color = Color3.fromRGB(90, 255, 220),
		Description = "+50% pickup radius per level.",
		Values = {
			{ pickup = 0.50 },
			{ pickup = 1.00 },
			{ pickup = 1.50 },
		},
	},
	Luck = {
		Id = "Luck",
		Name = "Luck",
		Color = Color3.fromRGB(110, 230, 80),
		Description = "+15/30/50% luck: rarer items, better cards.",
		Values = {
			{ luck = 0.15 },
			{ luck = 0.30 },
			{ luck = 0.50 },
		},
	},
	Ammo = {
		Id = "Ammo",
		Name = "Ammo",
		Color = Color3.fromRGB(240, 220, 120),
		Description = "Faster projectiles; +1 projectile at max level.",
		Values = {
			{ projSpeed = 0.15 },
			{ projSpeed = 0.30 },
			{ projSpeed = 0.50, amount = 1 },
		},
	},
	Candle = {
		Id = "Candle",
		Name = "Candle",
		Color = Color3.fromRGB(255, 140, 40),
		Description = "Projectiles fly longer, pools burn longer.",
		Values = {
			{ duration = 0.15 },
			{ duration = 0.30 },
			{ duration = 0.50 },
		},
	},
	Growth = {
		Id = "Growth",
		Name = "Growth",
		Color = Color3.fromRGB(60, 200, 120),
		Description = "More XP from every gem.",
		Values = {
			{ growth = 0.12 },
			{ growth = 0.25 },
			{ growth = 0.40 },
		},
	},
	-- Behaviour change: projectiles that stop on a hit (orbs, knives, thrown axes, arrows)
	-- pass through one more enemy per level. Evolves the Longbow.
	Fletching = {
		Id = "Fletching",
		Name = "Fletching",
		Color = Color3.fromRGB(150, 200, 120),
		Description = "Orbs, knives, axes and arrows pierce +1 enemy per level.",
		Values = {
			{ pierce = 1 },
			{ pierce = 2 },
			{ pierce = 3 },
		},
	},
	-- Critical hits for every weapon (crits deal Config.Items.BaseCritDamage, x2; the total
	-- chance is capped by Config.Items.MaxCritChance). Evolves the Crossbow.
	Precision = {
		Id = "Precision",
		Name = "Precision",
		Color = Color3.fromRGB(220, 120, 110),
		Description = "+5% crit chance per level (crits deal double damage).",
		Values = {
			{ critChance = 0.05 },
			{ critChance = 0.10 },
			{ critChance = 0.15 },
		},
	},
	-- Slow, steady healing (the same regeneration as the Bandage Roll item). Evolves the
	-- Healing Totem.
	Renewal = {
		Id = "Renewal",
		Name = "Renewal",
		Color = Color3.fromRGB(150, 210, 120),
		Description = "Regenerate health over time.",
		Values = {
			{ regen = 0.6 },
			{ regen = 1.2 },
			{ regen = 2.0 },
		},
	},
}

-- Number of levels of one passive.
function PassiveData.MaxLevelOf(passiveId: string): number
	local def = PassiveData.Passives[passiveId]
	return def and #def.Values or PassiveData.MaxLevel
end

-- Text for a level-up card when the passive goes to `level` (cards add the real stat change).
function PassiveData.DescribeLevel(passiveId: string, level: number): string
	local def = PassiveData.Passives[passiveId]
	if not def then
		return ""
	end
	return def.Description
end

return PassiveData
