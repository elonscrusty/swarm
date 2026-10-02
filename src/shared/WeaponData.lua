--[[
	WeaponData.lua
	All 8 weapons, their 8 per-level stat rows, their evolutions and the projectile visuals.

	Stat row fields (every level row has all of them):
	  damage     damage per hit (before Might)
	  cooldown   seconds between attacks (before Cooldown passive)
	  amount     projectiles / slashes / strikes per attack (before Duplicator / Ammo)
	  area       size multiplier (slash length, aura radius, pool radius, projectile size)
	  speed      projectile speed in studs/s (0 = not a projectile)
	  pierce     enemies a projectile can hit before it disappears (999 = unlimited)
	  duration   projectile lifetime / pool lifetime / boomerang outbound time (seconds)
	  knockback  push strength in studs/s added to the enemy

	Behaviour constants that never change with level live in `Params`.
	An evolution needs the weapon at level 8 plus its `Passive` (any level). It replaces the
	level-8 row with `Evolution.Stats` and switches on the evolution flags.

	To add a weapon: add an entry to Weapons + its id to Order, then add a behaviour
	function in ServerScriptService/Modules/WeaponSystem.lua (Fire[Behavior]).
]]

local WeaponData = {}

WeaponData.MaxLevel = 8

WeaponData.Order = { "Whip", "MagicOrb", "Knives", "Garlic", "HolyWater", "Lightning", "Axe", "Boomerang" }

-- Display names for stat diffs on level-up cards.
WeaponData.StatLabels = {
	damage = "Damage",
	cooldown = "Cooldown",
	amount = "Amount",
	area = "Area",
	speed = "Speed",
	pierce = "Pierce",
	duration = "Duration",
	knockback = "Knockback",
}

--[[
	Projectile visuals. The server only sends a visual index + position; the client builds
	pooled parts from these definitions. Shapes use built-in Part shapes / SpecialMesh types.
	Everything below is cosmetic (client only):
	  Style   how VFX moves the model in flight:
	          "Orb" wobble, "Knife" end-over-end tumble, "Dart" straight with a roll,
	          "Axe" heavy tumble, "Bottle" lazy tumble, "Boomerang" flat spin + bank,
	          "Saw" flat buzz-saw spin, "Stinger" spin
	  Spin    flat spin speed (rad/s), Tumble = end-over-end speed (rad/s)
	  Trail   { Color, Tail?, Width, Life } thin, short ribbon behind the projectile
	          (Color at the projectile, fading to Tail; Width grows a little with tier)
	  Impact  colour of the small puff where the projectile disappears (nil = none)
	  Shatter true = glass shards + splash when it lands
	Colours come from the shared palette (Theme.Fx) and match the projectile meshes:
	orb arcane, knife steel/ivory, bottle holy, axe steel, boomerang wood/gold; evolutions
	twin orb gold, edge knife gold, spiral axe crimson, infinite boomerang gold, hell bottle
	fire; the boss stinger crimson + amber.
]]
local Palette = require(script.Parent.Palette)

WeaponData.Visuals = {
	[1] = { Name = "Orb", Shape = "Ball", Size = Vector3.new(1.6, 1.6, 1.6), Color = Palette.fx_arcane, Material = "Neon", Style = "Orb", Trail = { Color = Palette.fx_arcane, Width = 0.5, Life = 0.14 }, Impact = Palette.fx_arcane },
	[2] = { Name = "Knife", Shape = "Block", Size = Vector3.new(0.4, 0.3, 2.4), Color = Palette.steel_200, Material = "Metal", Style = "Knife", Tumble = 26, Trail = { Color = Palette.fx_ivory, Tail = Palette.steel_300, Width = 0.18, Life = 0.08 }, Impact = Palette.fx_ivory },
	[3] = { Name = "Bottle", Shape = "Ball", Size = Vector3.new(1.2, 1.6, 1.2), Color = Palette.fx_holy, Material = "Glass", Style = "Bottle", Tumble = 9, Trail = { Color = Palette.fx_holy, Width = 0.22, Life = 0.12 }, Shatter = true },
	[4] = { Name = "Axe", Shape = "Block", Size = Vector3.new(2.6, 0.4, 2.0), Color = Palette.steel_400, Material = "Metal", Spin = 14, Style = "Axe", Tumble = 15, Trail = { Color = Palette.steel_200, Tail = Palette.steel_400, Width = 0.4, Life = 0.1 }, Impact = Palette.steel_200 },
	[5] = { Name = "Boomerang", Shape = "Block", Size = Vector3.new(2.6, 0.3, 0.8), Color = Palette.wood_400, Material = "Wood", Spin = 18, Style = "Boomerang", Trail = { Color = Palette.gold_300, Tail = Palette.wood_400, Width = 0.35, Life = 0.1 } },
	[6] = { Name = "TwinOrb", Shape = "Ball", Size = Vector3.new(1.8, 1.8, 1.8), Color = Palette.gold_300, Material = "Neon", Style = "Orb", Trail = { Color = Palette.gold_300, Width = 0.55, Life = 0.16 }, Impact = Palette.gold_200 },
	[7] = { Name = "BossOrb", Shape = "Ball", Size = Vector3.new(2.6, 2.6, 2.6), Color = Palette.crimson_400, Material = "Neon", Style = "Stinger", Spin = 6, Trail = { Color = Palette.amber_500, Tail = Palette.crimson_500, Width = 0.6, Life = 0.14 }, Impact = Palette.crimson_300 },
	[8] = { Name = "EdgeKnife", Shape = "Block", Size = Vector3.new(0.4, 0.3, 2.6), Color = Palette.gold_400, Material = "Metal", Style = "Dart", Spin = 18, Trail = { Color = Palette.gold_200, Tail = Palette.gold_400, Width = 0.22, Life = 0.09 }, Impact = Palette.gold_200 },
	[9] = { Name = "SpiralAxe", Shape = "Block", Size = Vector3.new(3.2, 0.4, 2.4), Color = Palette.crimson_500, Material = "Metal", Spin = 20, Style = "Saw", Trail = { Color = Palette.crimson_300, Tail = Palette.crimson_500, Width = 0.5, Life = 0.12 }, Impact = Palette.crimson_300 },
	[10] = { Name = "InfiniteBoomerang", Shape = "Block", Size = Vector3.new(3.0, 0.3, 0.9), Color = Palette.gold_400, Material = "Metal", Spin = 22, Style = "Boomerang", Trail = { Color = Palette.gold_200, Tail = Palette.gold_400, Width = 0.4, Life = 0.12 } },
	[11] = { Name = "HellBottle", Shape = "Ball", Size = Vector3.new(1.4, 1.8, 1.4), Color = Palette.fx_fire, Material = "Glass", Style = "Bottle", Tumble = 11, Trail = { Color = Palette.amber_300, Tail = Palette.fx_fire, Width = 0.3, Life = 0.14 }, Shatter = true },
}

-- Shorthand for building a stat row.
local function row(damage, cooldown, amount, area, speed, pierce, duration, knockback)
	return {
		damage = damage,
		cooldown = cooldown,
		amount = amount,
		area = area,
		speed = speed,
		pierce = pierce,
		duration = duration,
		knockback = knockback,
	}
end

WeaponData.Weapons = {
	Whip = {
		Id = "Whip",
		Name = "Whip",
		Description = "Swings a wide sword arc in the direction you face.",
		Color = Color3.fromRGB(200, 70, 60),
		Behavior = "Whip",
		-- hit shape: a sector Reach studs long and Arc degrees wide (same area as the old 13 x 4.5 box)
		Params = { Reach = 7, Arc = 150 },
		Levels = {
			--   dmg  cd    amt area spd prc dur  kb
			row(10, 1.35, 1, 1.0, 0, 999, 0.25, 14),
			row(10, 1.35, 2, 1.0, 0, 999, 0.25, 14),
			row(15, 1.35, 2, 1.0, 0, 999, 0.25, 14),
			row(15, 1.35, 2, 1.1, 0, 999, 0.25, 16),
			row(20, 1.35, 2, 1.1, 0, 999, 0.25, 16),
			row(20, 1.30, 2, 1.2, 0, 999, 0.25, 18),
			row(25, 1.30, 2, 1.2, 0, 999, 0.25, 18),
			row(30, 1.20, 2, 1.3, 0, 999, 0.25, 20),
		},
		Evolution = {
			Id = "Bloodwhip",
			Name = "Bloodwhip",
			Passive = "Heart",
			Description = "Huge crimson slashes that heal you on every hit.",
			Stats = row(40, 1.10, 2, 1.5, 0, 999, 0.25, 22),
			Lifesteal = 1, -- HP per enemy hit
			LifestealCapPerSwing = 8,
		},
	},

	MagicOrb = {
		Id = "MagicOrb",
		Name = "Magic Orb",
		Description = "Fires a homing orb at the nearest enemy.",
		Color = Color3.fromRGB(150, 80, 255),
		Behavior = "Orb",
		Params = { Radius = 1.0, TurnRate = 7, Visual = 1, EvoVisual = 6 },
		Levels = {
			row(10, 1.20, 1, 1.0, 38, 1, 3, 4),
			row(10, 1.20, 2, 1.0, 38, 1, 3, 4),
			row(10, 1.00, 2, 1.0, 38, 1, 3, 4),
			row(10, 1.00, 3, 1.0, 40, 1, 3, 4),
			row(15, 1.00, 3, 1.0, 40, 1, 3, 5),
			row(15, 1.00, 3, 1.0, 40, 2, 3, 5),
			row(15, 0.85, 3, 1.0, 42, 2, 3, 5),
			row(20, 0.85, 4, 1.1, 42, 2, 3, 6),
		},
		Evolution = {
			Id = "TwinOrbs",
			Name = "Twin Orbs",
			Passive = "SpeedBoots",
			Description = "Every shot fires twin orbs that pierce through crowds.",
			Stats = row(25, 0.70, 4, 1.2, 48, 4, 3.5, 6),
			Twin = true, -- each shot spawns two orbs side by side
		},
	},

	Knives = {
		Id = "Knives",
		Name = "Throwing Knives",
		Description = "Fast knives thrown in your movement direction.",
		Color = Color3.fromRGB(210, 215, 225),
		Behavior = "Knives",
		Params = { Radius = 0.7, Spread = 1.2, Visual = 2, EvoVisual = 8 },
		Levels = {
			row(7, 1.00, 1, 1.0, 80, 1, 1.0, 2),
			row(7, 1.00, 2, 1.0, 80, 1, 1.0, 2),
			row(9, 1.00, 2, 1.0, 80, 1, 1.0, 2),
			row(9, 1.00, 3, 1.0, 80, 1, 1.0, 2),
			row(9, 1.00, 3, 1.0, 85, 2, 1.0, 3),
			row(9, 0.95, 4, 1.0, 85, 2, 1.0, 3),
			row(11, 0.95, 4, 1.0, 85, 2, 1.0, 3),
			row(11, 0.85, 5, 1.0, 90, 3, 1.0, 3),
		},
		Evolution = {
			Id = "ThousandEdge",
			Name = "Thousand Edge",
			Passive = "Ammo",
			Description = "An unending stream of golden blades.",
			Stats = row(12, 0.08, 1, 1.0, 100, 3, 1.0, 2),
			Stream = true, -- amount bonuses add sideways spread instead of a burst
		},
	},

	Garlic = {
		Id = "Garlic",
		Name = "Garlic Aura",
		Description = "Damages and pushes back enemies near you.",
		Color = Color3.fromRGB(235, 235, 200),
		Behavior = "Aura",
		Params = { Radius = 5.5 },
		Levels = {
			row(5, 1.10, 1, 1.0, 0, 999, 0, 6),
			row(5, 1.10, 1, 1.2, 0, 999, 0, 6),
			row(7, 1.10, 1, 1.2, 0, 999, 0, 6),
			row(7, 0.95, 1, 1.2, 0, 999, 0, 7),
			row(7, 0.95, 1, 1.4, 0, 999, 0, 7),
			row(9, 0.95, 1, 1.4, 0, 999, 0, 7),
			row(9, 0.85, 1, 1.4, 0, 999, 0, 8),
			row(11, 0.85, 1, 1.6, 0, 999, 0, 8),
		},
		Evolution = {
			Id = "SoulEater",
			Name = "Soul Eater",
			Passive = "Vacuum",
			Description = "A hungry ring that grows with every kill and pulls in XP.",
			Stats = row(14, 0.75, 1, 2.0, 0, 999, 0, 9),
			PullsXP = true,
			GrowthPerKill = 0.004, -- +0.4% radius per kill inside the ring
			GrowthCap = 0.6, -- up to +60%
		},
	},

	HolyWater = {
		Id = "HolyWater",
		Name = "Holy Water",
		Description = "Throws bottles that leave burning pools.",
		Color = Color3.fromRGB(80, 160, 255),
		Behavior = "HolyWater",
		Params = { PoolRadius = 4.5, TickSeconds = 0.5, ThrowRange = 22, Visual = 3, EvoVisual = 11 },
		Levels = {
			row(8, 4.2, 1, 1.0, 30, 999, 2.5, 0),
			row(8, 4.2, 2, 1.0, 30, 999, 2.5, 0),
			row(8, 4.2, 2, 1.2, 30, 999, 2.5, 0),
			row(11, 4.2, 2, 1.2, 30, 999, 3.0, 0),
			row(11, 4.2, 3, 1.2, 30, 999, 3.0, 0),
			row(11, 4.0, 3, 1.4, 30, 999, 3.0, 0),
			row(14, 4.0, 3, 1.4, 30, 999, 3.5, 0),
			row(14, 3.6, 4, 1.4, 30, 999, 3.5, 0),
		},
		Evolution = {
			Id = "Hellfire",
			Name = "Hellfire",
			Passive = "Candle",
			Description = "Huge, long-lasting pools of holy fire.",
			Stats = row(18, 3.2, 4, 2.0, 34, 999, 6.0, 0),
		},
	},

	Lightning = {
		Id = "Lightning",
		Name = "Lightning",
		Description = "Strikes random enemies around you.",
		Color = Color3.fromRGB(255, 240, 90),
		Behavior = "Lightning",
		Params = { StrikeRadius = 3, Range = 42 },
		Levels = {
			row(15, 3.0, 2, 1.0, 0, 999, 0, 0),
			row(15, 3.0, 3, 1.0, 0, 999, 0, 0),
			row(20, 3.0, 3, 1.0, 0, 999, 0, 0),
			row(20, 3.0, 3, 1.3, 0, 999, 0, 0),
			row(20, 3.0, 4, 1.3, 0, 999, 0, 0),
			row(26, 2.6, 4, 1.3, 0, 999, 0, 0),
			row(26, 2.6, 4, 1.6, 0, 999, 0, 0),
			row(32, 2.6, 5, 1.6, 0, 999, 0, 0),
		},
		Evolution = {
			Id = "ThunderLoop",
			Name = "Thunder Loop",
			Passive = "Duplicator",
			Description = "Every strike chains to nearby enemies.",
			Stats = row(36, 2.2, 6, 1.8, 0, 999, 0, 0),
			ChainJumps = 3,
			ChainRange = 18,
		},
	},

	Axe = {
		Id = "Axe",
		Name = "Axe",
		Description = "Thrown upward in an arc. Heavy damage.",
		Color = Color3.fromRGB(170, 170, 180),
		Behavior = "Axe",
		Params = { Radius = 1.6, UpSpeed = 48, Gravity = 80, Visual = 4, EvoVisual = 9, OrbitRadius = 6, OrbitGrowth = 7, OrbitSpin = 4.5 },
		Levels = {
			row(20, 2.5, 1, 1.0, 22, 3, 3.0, 10),
			row(20, 2.5, 2, 1.0, 22, 3, 3.0, 10),
			row(30, 2.5, 2, 1.0, 22, 3, 3.0, 10),
			row(30, 2.5, 2, 1.0, 22, 5, 3.0, 12),
			row(30, 2.5, 3, 1.0, 24, 5, 3.0, 12),
			row(40, 2.5, 3, 1.2, 24, 5, 3.0, 12),
			row(40, 2.5, 3, 1.2, 24, 7, 3.0, 14),
			row(50, 2.2, 4, 1.2, 26, 7, 3.0, 14),
		},
		Evolution = {
			Id = "DeathSpiral",
			Name = "Death Spiral",
			Passive = "Might",
			Description = "Axes orbit you and spiral outward through everything.",
			Stats = row(60, 3.0, 8, 1.5, 0, 999, 3.5, 14),
			Orbit = true,
		},
	},

	Boomerang = {
		Id = "Boomerang",
		Name = "Boomerang",
		Description = "Flies out and comes back, piercing everything.",
		Color = Color3.fromRGB(205, 160, 90),
		Behavior = "Boomerang",
		Params = { Radius = 1.4, RehitSeconds = 0.4, Visual = 5, EvoVisual = 10 },
		Levels = {
			row(10, 2.2, 1, 1.0, 36, 999, 0.8, 6),
			row(14, 2.2, 1, 1.0, 36, 999, 0.8, 6),
			row(14, 2.2, 2, 1.0, 36, 999, 0.8, 6),
			row(14, 2.2, 2, 1.0, 42, 999, 0.8, 7),
			row(18, 2.2, 2, 1.2, 42, 999, 0.8, 7),
			row(18, 2.2, 3, 1.2, 42, 999, 0.8, 7),
			row(18, 1.9, 3, 1.2, 42, 999, 0.8, 8),
			row(24, 1.9, 4, 1.2, 44, 999, 0.9, 8),
		},
		Evolution = {
			Id = "InfiniteReturn",
			Name = "Infinite Return",
			Passive = "Cooldown",
			Description = "Boomerangs that never stop: they bounce between enemies and you forever.",
			Stats = row(30, 1.0, 4, 1.4, 46, 999, 0.9, 8),
			Persistent = true,
		},
	},
}

-- Returns the stat row for a weapon at a level (evolved overrides the row).
function WeaponData.GetStats(weaponId: string, level: number, evolved: boolean?)
	local def = WeaponData.Weapons[weaponId]
	if not def then
		return nil
	end
	if evolved and def.Evolution then
		return def.Evolution.Stats
	end
	return def.Levels[math.clamp(level, 1, WeaponData.MaxLevel)]
end

local function formatDelta(stat: string, before: number, after: number): string?
	local d = after - before
	if math.abs(d) < 1e-6 then
		return nil
	end
	local label = WeaponData.StatLabels[stat]
	if stat == "area" then
		return string.format("%s %+d%%", label, math.floor(d * 100 + 0.5))
	elseif stat == "cooldown" or stat == "duration" then
		return string.format("%s %+.2fs", label, d)
	elseif stat == "pierce" and after >= 999 then
		return "Pierce: unlimited"
	end
	return string.format("%s %+d", label, math.floor(d + 0.5))
end

local DIFF_ORDER = { "damage", "amount", "area", "cooldown", "speed", "pierce", "duration", "knockback" }

-- Text for a level-up card: what changes when going to `level` (1 = the weapon is new).
function WeaponData.DescribeLevel(weaponId: string, level: number): string
	local def = WeaponData.Weapons[weaponId]
	if not def then
		return ""
	end
	if level <= 1 then
		return def.Description
	end
	local before, after = def.Levels[level - 1], def.Levels[level]
	local parts = {}
	for _, stat in ipairs(DIFF_ORDER) do
		local text = formatDelta(stat, before[stat], after[stat])
		if text then
			table.insert(parts, text)
		end
	end
	return table.concat(parts, ", ")
end

return WeaponData
