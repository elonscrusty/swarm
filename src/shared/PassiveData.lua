--[[
	PassiveData.lua
	25 passive items, 3-5 levels each (PassiveData.MaxLevelOf). `Values[level]` is the TOTAL bonus at that level
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
	  eliteDamage    +damage to elites and bosses (Giant's Bane; ItemSystem.ModifyHit)
	  thorns         share of a hit dealt back around you (Thornhide; ItemSystem.OnHurt)
	  critHeal       HP healed by a critical hit (Blood Rune; ItemSystem.ModifyHit)
	  ward           seconds for the one-hit ward to recharge (Aegis Charm; ItemSystem.AbsorbHit)
	  killRush       +move speed for a moment after a kill (Windstep; ItemSystem.OnKill)
	  goldGain       +gold (Gilded Purse; an item stat too)
	  damageTaken    -damage taken (Stoneskin; negative = less)
	  levelHeal      share of max HP healed on level-up (Second Wind; ItemSystem.OnLevelUp)
	  burnChance     chance a hit sets the enemy burning (Ember Oil; ItemSystem.OnHit)
	  stillHeal      share of max HP healed per second while standing still (Still Waters)
	  lowHpMight     +damage while below Tuning.LionheartHp of max HP (Lionheart)

	Synergies: Area, Candle, Precision, Armor, Ember Oil, Thornhide and Stoneskin are pieces of the build synergies in
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
	"GiantsBane",
	"Thornhide",
	"BloodRune",
	"AegisCharm",
	"Windstep",
	"GildedPurse",
	"Stoneskin",
	"SecondWind",
	"EmberOil",
	"Lionheart",
	"StillWaters",
}

-- Held for a later update: ids built and tested but kept out of Order (none right now).
PassiveData.HeldOrder = {} :: { string }


-- Behaviour numbers of the passives that hook into ItemSystem (not stat bumps).
PassiveData.Tuning = {
	WindstepSeconds = 1.5, -- how long the speed lasts after a kill
	BloodRuneCooldown = 0.2, -- seconds between two crit heals
	BurnSeconds = 3, -- Ember Oil burn length
	BurnTick = 0.5, -- seconds between burn ticks
	BurnShare = 0.3, -- burn damage per second, as a share of the igniting hit
	MaxBurns = 80, -- burning enemies at once (server-wide), so huge swarms stay cheap
	MaxBurnChance = 0.5,
	LionheartHp = 0.4, -- Lionheart works below this share of max HP
	StillDelay = 0.75, -- Still Waters: seconds standing still before it heals
	StillMoveStuds = 0.3, -- moving more than this (flat) resets the timer
	StillHurtPause = 1, -- no Still Waters healing for this long after a hit
	StillCueEvery = 1, -- seconds between the soft green rings while it heals
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
		Benefit = { might = "deal {n} more damage with every weapon" },
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
		Benefit = { armor = "take {n} less damage from every hit" },
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
		Benefit = { maxHpMult = "gain {n} more max HP" },
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
		Benefit = { speed = "move {n} faster" },
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
		Benefit = { cooldown = "weapon cooldowns get {n} shorter" },
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
		Benefit = { area = "every attack gets {n} bigger" },
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
		Description = "+1 shot, swing or strike per level (not auras).",
		Benefit = { amount = "every weapon fires {n} more shot, swing or strike (not auras)" },
		Note = "Auras and bursts are not boosted; turrets and totems stop at their cap.",
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
		Benefit = { pickup = "pick things up from {n} farther away" },
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
		Description = "More luck: rarer items, better cards.",
		Benefit = { luck = "gain {n} luck: rarer items and better cards" },
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
		Benefit = { projSpeed = "projectiles fly {n} faster", amount = "every weapon fires {n} more shot, swing or strike (not auras)" },
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
		Benefit = { duration = "projectiles fly and pools burn {n} longer" },
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
		Benefit = { growth = "earn {n} more XP from every gem" },
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
		Benefit = { pierce = "orbs, knives, axes and arrows pierce {n} more enemy" },
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
		Benefit = { critChance = "gain {n} crit chance (crits deal double damage)" },
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
		BenefitNew = { regen = "regenerate {n} HP every second" },
		Benefit = { regen = "regenerate {n} more HP every second" },
		Values = {
			{ regen = 0.6 },
			{ regen = 1.2 },
			{ regen = 2.0 },
		},
	},
	-- Damage against the big ones: elites (any affix) and bosses.
	GiantsBane = {
		Id = "GiantsBane",
		Name = "Giant's Bane",
		Color = Color3.fromRGB(200, 90, 70),
		Description = "+15% damage to elites and bosses per level.",
		Benefit = { eliteDamage = "deal {n} more damage to elites and bosses" },
		Values = {
			{ eliteDamage = 0.15 },
			{ eliteDamage = 0.30 },
			{ eliteDamage = 0.45 },
		},
	},
	-- Thorns without the item: adds to Barbed Mail and shares its short cooldown.
	Thornhide = {
		Id = "Thornhide",
		Name = "Thornhide",
		Color = Color3.fromRGB(120, 160, 80),
		Description = "When hit, strike back at foes close to you.",
		BenefitNew = { thorns = "when hit, strike back at foes close to you for {n} of the hit" },
		Benefit = { thorns = "strike back {n} harder when hit" },
		Values = {
			{ thorns = 0.8 },
			{ thorns = 1.6 },
			{ thorns = 2.5 },
		},
	},
	BloodRune = {
		Id = "BloodRune",
		Name = "Blood Rune",
		Color = Color3.fromRGB(200, 50, 70),
		Description = "Critical hits heal you a little.",
		BenefitNew = { critHeal = "critical hits heal you {n} HP" },
		Benefit = { critHeal = "critical hits heal {n} more HP" },
		Values = {
			{ critHeal = 1 },
			{ critHeal = 2 },
			{ critHeal = 3 },
		},
	},
	-- A ward that swallows one whole hit, then recharges.
	AegisCharm = {
		Id = "AegisCharm",
		Name = "Aegis Charm",
		Color = Color3.fromRGB(240, 200, 90),
		Description = "A ward blocks one whole hit, then recharges.",
		BenefitNew = { ward = "a ward blocks one whole hit, recharging after {n} s" },
		Benefit = { ward = "the ward recharges {n} s sooner" },
		Values = {
			{ ward = 14 },
			{ ward = 11 },
			{ ward = 8 },
		},
	},
	Windstep = {
		Id = "Windstep",
		Name = "Windstep",
		Color = Color3.fromRGB(150, 220, 230),
		Description = "Each kill gives extra speed for 1.5 s.", -- Tuning.WindstepSeconds
		BenefitNew = { killRush = "each kill gives {n} extra speed for 1.5 s" },
		Benefit = { killRush = "each kill gives {n} more speed for 1.5 s" },
		Values = {
			{ killRush = 0.08 },
			{ killRush = 0.15 },
			{ killRush = 0.22 },
		},
	},
	GildedPurse = {
		Id = "GildedPurse",
		Name = "Gilded Purse",
		Color = Color3.fromRGB(255, 200, 70),
		Description = "More gold from kills, chests and bosses.",
		Benefit = { goldGain = "earn {n} more gold from kills, chests and bosses" },
		Values = {
			{ goldGain = 0.15 },
			{ goldGain = 0.30 },
			{ goldGain = 0.50 },
		},
	},
	Stoneskin = {
		Id = "Stoneskin",
		Name = "Stoneskin",
		Color = Color3.fromRGB(160, 150, 135),
		Description = "Take 6% less damage per level.",
		Benefit = { damageTaken = "take {n} less damage" },
		Values = {
			{ damageTaken = -0.06 },
			{ damageTaken = -0.12 },
			{ damageTaken = -0.18 },
		},
	},
	SecondWind = {
		Id = "SecondWind",
		Name = "Second Wind",
		Color = Color3.fromRGB(130, 220, 170),
		Description = "Every level-up heals a share of your max HP.",
		BenefitNew = { levelHeal = "every level-up heals {n} of your max HP" },
		Benefit = { levelHeal = "every level-up heals {n} more of your max HP" },
		Values = {
			{ levelHeal = 0.08 },
			{ levelHeal = 0.14 },
			{ levelHeal = 0.20 },
		},
	},
	-- Burns deal BurnShare of the igniting hit per second for BurnSeconds (never crit).
	EmberOil = {
		Id = "EmberOil",
		Name = "Ember Oil",
		Color = Color3.fromRGB(255, 120, 40),
		Description = "Hits may set foes on fire for 3 s.",
		BenefitNew = { burnChance = "hits get a {n} chance to set foes on fire for 3 s" },
		Benefit = { burnChance = "hits get {n} more chance to set foes on fire" },
		Values = {
			{ burnChance = 0.08 },
			{ burnChance = 0.14 },
			{ burnChance = 0.20 },
		},
	},
	Lionheart = {
		Id = "Lionheart",
		Name = "Lionheart",
		Color = Color3.fromRGB(230, 150, 60),
		Description = "Deal more damage while below 40% max HP.", -- Tuning.LionheartHp
		Benefit = { lowHpMight = "deal {n} more damage while below 40% max HP" },
		Values = {
			{ lowHpMight = 0.20 },
			{ lowHpMight = 0.35 },
			{ lowHpMight = 0.50 },
		},
	},
	-- Heal by standing still: good in quiet moments; any hit pauses it for a second, so
	-- standing inside the swarm is not the way to use it.
	StillWaters = {
		Id = "StillWaters",
		Name = "Still Waters",
		Color = Color3.fromRGB(110, 200, 190),
		Description = "Stand still to heal. A hit pauses it.",
		BenefitNew = { stillHeal = "standing still heals {n} of your max HP per second" },
		Benefit = { stillHeal = "standing still heals {n} more of your max HP per second" },
		Values = {
			{ stillHeal = 0.02 },
			{ stillHeal = 0.035 },
			{ stillHeal = 0.05 },
		},
	},
}

-- Number of levels of one passive.
function PassiveData.MaxLevelOf(passiveId: string): number
	local def = PassiveData.Passives[passiveId]
	return def and #def.Values or PassiveData.MaxLevel
end

--[[
	Card text for one pick, from the real Values (never the whole "15/30/50%" ladder):
	  PassiveData.BenefitText(id, level)  "Earn 15% more gold from kills, chests and bosses."
	    the gain of going from level-1 to `level` (level 1 = the whole first level), from the
	    passive's Benefit clauses ({n} = that gain; BenefitNew is used at level 1 when set)
	  PassiveData.GainText(id, level)     "+15%" / "+1" / "-3 s": the same gain, short
	  PassiveData.TiersText(id, level)    "Next: Lv 2 +15% · Lv 3 +20%" or "Final level"
]]
local PCT_KEYS = {
	might = true, maxHpMult = true, speed = true, cooldown = true, area = true, pickup = true, luck = true,
	projSpeed = true, duration = true, growth = true, critChance = true, eliteDamage = true, thorns = true,
	killRush = true, goldGain = true, damageTaken = true, levelHeal = true, burnChance = true,
	lowHpMight = true, stillHeal = true,
}
local COUNT_KEYS = { amount = true, pierce = true }
local WORDS = { "one", "two", "three", "four", "five" }
local KEY_ORDER = {
	"might", "armor", "maxHpMult", "speed", "cooldown", "area", "amount", "pickup", "luck", "projSpeed",
	"duration", "growth", "pierce", "critChance", "regen", "eliteDamage", "thorns", "critHeal", "ward",
	"killRush", "goldGain", "damageTaken", "levelHeal", "burnChance", "lowHpMight", "stillHeal",
}

local function trimNum(v: number): string
	if math.abs(v - math.floor(v + 0.5)) < 1e-6 then
		return tostring(math.floor(v + 0.5))
	end
	local s = string.format("%.1f", v)
	return s
end

-- The size of a gain `d` of stat `key`, for a sentence ("15%", "one", "0.6", "3").
local function amountWord(key: string, d: number): string
	d = math.abs(d)
	if PCT_KEYS[key] then
		return trimNum(d * 100) .. "%"
	elseif COUNT_KEYS[key] then
		local i = math.floor(d + 0.5)
		return WORDS[i] or tostring(i)
	end
	return trimNum(d)
end

-- The gains of going to `level`: { { Key, Delta } } in a fixed order.
local function gains(def, level: number): { { Key: string, Delta: number } }
	local after = def.Values[math.clamp(level, 1, #def.Values)] or {}
	local before = level > 1 and def.Values[level - 1] or {}
	local out = {}
	for _, key in ipairs(KEY_ORDER) do
		local a, b = before[key] or 0, after[key] or 0
		if math.abs(b - a) > 1e-6 then
			table.insert(out, { Key = key, Delta = b - a })
		end
	end
	return out
end

function PassiveData.BenefitText(passiveId: string, level: number): string?
	local def = PassiveData.Passives[passiveId]
	if not def or not def.Benefit then
		return nil
	end
	local templates = (level <= 1 and def.BenefitNew) or def.Benefit
	local clauses = {}
	for _, g in ipairs(gains(def, level)) do
		local t = templates[g.Key] or def.Benefit[g.Key]
		if t then
			local i, j = string.find(t, "{n}", 1, true)
			if i and j then
				t = string.sub(t, 1, i - 1) .. amountWord(g.Key, g.Delta) .. string.sub(t, j + 1)
			end
			table.insert(clauses, t)
		end
	end
	if #clauses == 0 then
		return nil
	end
	local s = table.concat(clauses, " and ")
	return string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2) .. "."
end

function PassiveData.GainText(passiveId: string, level: number): string
	local def = PassiveData.Passives[passiveId]
	local parts = {}
	for _, g in ipairs(def and gains(def, level) or {}) do
		local d = g.Delta
		if g.Key == "ward" then
			table.insert(parts, (d < 0 and "-" or "+") .. trimNum(math.abs(d)) .. " s")
		elseif g.Key == "damageTaken" then
			table.insert(parts, "-" .. trimNum(math.abs(d) * 100) .. "% dmg taken")
		else
			local size = PCT_KEYS[g.Key] and (trimNum(math.abs(d) * 100) .. "%") or trimNum(math.abs(d))
			table.insert(parts, (d < 0 and "-" or "+") .. size)
		end
	end
	return table.concat(parts, ", ")
end

function PassiveData.TiersText(passiveId: string, level: number): string?
	local def = PassiveData.Passives[passiveId]
	if not def then
		return nil
	end
	local max = #def.Values
	if level >= max then
		return "Final level"
	end
	local parts = {}
	for l = level + 1, max do
		table.insert(parts, string.format("Lv %d %s", l, PassiveData.GainText(passiveId, l)))
	end
	return "Next: " .. table.concat(parts, " · ")
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
