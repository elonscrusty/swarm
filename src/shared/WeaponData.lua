--[[
	WeaponData.lua
	All 9 weapons, their 8 per-level stat rows, their evolutions, their behaviour perks and
	the projectile visuals.

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

	Perks: behaviour changes unlocked at a weapon level (and kept when evolved), e.g. the
	Whip's Riposte. `Perks = { { Level, Id, Name, Text } }`; WeaponSystem asks
	WeaponData.HasPerk(w, "Riposte"). Level-up cards show the perk as a NEW line.
	AmountLabel names the amount stat on cards ("Swings", "Arrows", ...).

	To add a weapon: add an entry to Weapons + its id to Order, then add a behaviour
	function in ServerScriptService/Modules/WeaponSystem.lua (Fire[Behavior]) and list
	the stats it uses in WeaponData.StatUse.
]]

local WeaponData = {}

WeaponData.MaxLevel = 8

WeaponData.Order = { "Whip", "MagicOrb", "Knives", "Garlic", "HolyWater", "Lightning", "Axe", "Boomerang", "Longbow" }

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
	-- 12-19 are left free for enemy / boss shots; player arrows use 20+
	[20] = { Name = "Arrow", Shape = "Block", Size = Vector3.new(0.73, 0.63, 3.24), Color = Palette.wood_400, Material = "Wood", Style = "Dart", Spin = 0, Trail = { Color = Palette.ivory_100, Tail = Palette.moss_300, Width = 0.16, Life = 0.1 }, Impact = Palette.ivory_200 },
	[21] = { Name = "WindArrow", Shape = "Block", Size = Vector3.new(0.73, 0.63, 3.24), Color = Palette.moss_300, Material = "Neon", Style = "Dart", Spin = 0, Trail = { Color = Palette.moss_200, Tail = Palette.gold_300, Width = 0.24, Life = 0.14 }, Impact = Palette.moss_200 },
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
		AmountLabel = "Swings",
		-- every 3rd attack the forehand cut becomes a full circle around you
		Perks = { { Level = 6, Id = "Riposte", Name = "Riposte", Text = "Every 3rd attack also cuts all around you." } },
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
		AmountLabel = "Orbs",
		Perks = { { Level = 5, Id = "Split", Name = "Splitting Orbs", Text = "An orb's first kill splits off 2 small orbs (half damage)." } },
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
		AmountLabel = "Knives",
		Perks = { { Level = 4, Id = "Ricochet", Name = "Ricochet", Text = "A knife that would stop bounces once to the nearest other enemy." } },
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
		AmountLabel = nil, -- one ring: Amount does nothing for the aura
		Perks = { { Level = 4, Id = "Chill", Name = "Chilling Aura", Text = "Enemies inside the aura move 25% slower." } },
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
		AmountLabel = "Bottles",
		DurationLabel = "Pool time",
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
		AmountLabel = "Strikes",
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
		AmountLabel = "Axes",
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
		AmountLabel = "Boomerangs",
		DurationLabel = "Throw time",
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

	--[[
		LONGBOW (the Ranger's weapon): slow, heavy arrows in the direction you move (or face
		when standing still), long range (speed x duration ≈ 90-125 studs), piercing a line of
		enemies. Per-target DPS (damage x arrows / cooldown): L1 10.6 (Whip 7.4, Knives 7.0,
		each arrow passes 2 enemies), L8 60 (+1/3 with the Volley perk ≈ 80; Knives 65 + their
		Ricochet), Windpiercer 4 arrows ≈ 166 (Death Spiral 160, Thousand Edge 150): few big
		hits that matter against elites and the Queen, but only in one direction. Steady Aim
		(Ranger trait, CharacterData) adds +30% Longbow damage while standing still.
	]]
	Longbow = {
		Id = "Longbow",
		Name = "Longbow",
		Description = "Heavy piercing arrows fly far where you move, or at the nearest enemy while you stand still.",
		Color = Color3.fromRGB(150, 190, 110),
		Behavior = "Longbow",
		AmountLabel = "Arrows",
		DurationLabel = "Range",
		Params = { Radius = 0.9, Spread = 1.1, Visual = 20, EvoVisual = 21, VolleyEvery = 3, VolleyAngle = 12 },
		Perks = { { Level = 6, Id = "Volley", Name = "Volley", Text = "Every 3rd shot also fires 2 arrows to the sides." } },
		Levels = {
			--   dmg  cd    amt area spd  prc dur   kb
			row(18, 1.70, 1, 1.0, 100, 2, 0.90, 8),
			row(24, 1.70, 1, 1.0, 100, 2, 0.90, 8),
			row(24, 1.70, 1, 1.0, 105, 3, 0.95, 9),
			row(24, 1.60, 2, 1.0, 105, 3, 0.95, 9),
			row(30, 1.60, 2, 1.0, 110, 3, 1.00, 10),
			row(30, 1.50, 2, 1.1, 110, 4, 1.00, 10),
			row(36, 1.50, 2, 1.1, 115, 4, 1.00, 11),
			row(42, 1.40, 2, 1.2, 115, 5, 1.00, 12),
		},
		Evolution = {
			Id = "Windpiercer",
			Name = "Windpiercer",
			Passive = "Fletching",
			Description = "Every shot is a volley of wind arrows that pierce everything.",
			Stats = row(52, 1.25, 2, 1.3, 125, 999, 1.10, 12),
			Fan = true, -- every shot adds the two side arrows (the Volley perk on every shot)
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

--[[
	Stats each behaviour really uses (a stat it ignores never shows on a card, and passives
	that only change ignored stats are not offered: LevelUpSystem). Keys are stat-row keys.
	Evolved Death Spiral axes orbit (speed is not used), Infinite Return never ends.
]]
WeaponData.StatUse = {
	Whip = { damage = true, cooldown = true, amount = true, area = true, knockback = true },
	Orb = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
	Knives = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
	Aura = { damage = true, cooldown = true, area = true, knockback = true },
	HolyWater = { damage = true, cooldown = true, amount = true, area = true, speed = true, duration = true },
	Lightning = { damage = true, cooldown = true, amount = true, area = true },
	Axe = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
	Boomerang = { damage = true, cooldown = true, amount = true, area = true, speed = true, duration = true, knockback = true },
	Longbow = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
}

-- True when the weapon (id, level, evolved) uses stat-row key `stat`.
function WeaponData.UsesStat(weaponId: string, stat: string, evolved: boolean?): boolean
	local def = WeaponData.Weapons[weaponId]
	if not def then
		return false
	end
	local use = WeaponData.StatUse[def.Behavior]
	if not use or not use[stat] then
		return false
	end
	local row = WeaponData.GetStats(weaponId, WeaponData.MaxLevel, evolved)
	if stat == "pierce" and row and row.pierce >= 999 then
		return false -- already unlimited
	end
	if stat == "speed" and evolved and row and row.speed <= 0 then
		return false -- Death Spiral orbits
	end
	return true
end

-- Perk unlocked at exactly `level` (nil if none).
function WeaponData.PerkAt(weaponId: string, level: number)
	local def = WeaponData.Weapons[weaponId]
	for _, perk in ipairs(def and def.Perks or {}) do
		if perk.Level == level then
			return perk
		end
	end
	return nil
end

-- True when a weapon record { Id, Level, Evolved } has the perk (evolutions keep perks).
function WeaponData.HasPerk(w, perkId: string): boolean
	local def = WeaponData.Weapons[w.Id]
	for _, perk in ipairs(def and def.Perks or {}) do
		if perk.Id == perkId then
			return w.Evolved == true or w.Level >= perk.Level
		end
	end
	return false
end

local function fmt(stat: string, v: number): string
	if stat == "area" then
		return math.floor(v * 100 + 0.5) .. "%"
	elseif stat == "cooldown" or stat == "duration" then
		return string.format("%.2fs", v)
	elseif stat == "pierce" and v >= 999 then
		return "all"
	end
	if math.abs(v - math.floor(v + 0.5)) < 1e-6 then
		return tostring(math.floor(v + 0.5))
	end
	return string.format("%.1f", v)
end

local function labelOf(def, stat: string): string
	if stat == "amount" then
		return def.AmountLabel or "Amount"
	elseif stat == "duration" then
		return def.DurationLabel or "Duration"
	elseif stat == "pierce" then
		return "Pierce"
	end
	return WeaponData.StatLabels[stat]
end

local DIFF_ORDER = { "damage", "amount", "cooldown", "area", "pierce", "speed", "duration", "knockback" }

--[[
	Card lines for a weapon going from one stat row to the next, in plain words:
	  { Label = "Damage", From = "10", To = "15" }   a stat change
	  { Label = "NEW", Text = "Riposte: ..." }        a perk unlocked at this level
	fromLevel 0 = the weapon is new (lines show the starting stats, From = nil).
	evolve = true: the max-level row → the evolution row.
]]
function WeaponData.CardLines(weaponId: string, fromLevel: number, toLevel: number, evolve: boolean?): { { [string]: string } }
	local def = WeaponData.Weapons[weaponId]
	local out = {}
	if not def then
		return out
	end
	local use = WeaponData.StatUse[def.Behavior] or {}
	if fromLevel <= 0 then
		local r = def.Levels[1]
		for _, stat in ipairs({ "damage", "amount", "cooldown" }) do
			if use[stat] then
				table.insert(out, { Label = labelOf(def, stat), To = fmt(stat, r[stat]) })
			end
		end
		if use.pierce and r.pierce > 1 then
			table.insert(out, { Label = "Pierce", To = fmt("pierce", r.pierce) })
		end
		return out
	end
	local before = def.Levels[math.clamp(fromLevel, 1, WeaponData.MaxLevel)]
	local after = evolve and def.Evolution and def.Evolution.Stats or def.Levels[math.clamp(toLevel, 1, WeaponData.MaxLevel)]
	for _, stat in ipairs(DIFF_ORDER) do
		-- an evolution can stop using a stat (Death Spiral orbits: speed 0); never show it,
		-- but keep "Pierce 5 → all" (unlimited pierce is a real change)
		local used = use[stat] and (not evolve or WeaponData.UsesStat(weaponId, stat, true) or (stat == "pierce" and after.pierce >= 999))
		if used and math.abs(after[stat] - before[stat]) > 1e-6 then
			local from, to = fmt(stat, before[stat]), fmt(stat, after[stat])
			if from ~= to then
				table.insert(out, { Label = labelOf(def, stat), From = from, To = to })
			end
		end
	end
	if not evolve then
		local perk = WeaponData.PerkAt(weaponId, toLevel)
		if perk then
			table.insert(out, { Label = "NEW", Text = perk.Name .. ": " .. perk.Text })
		end
	end
	return out
end

-- One line of card text ("Damage 10 → 15").
function WeaponData.LineText(line: { [string]: string }): string
	if line.Text then
		return line.Text
	elseif line.From then
		return string.format("%s %s → %s", line.Label, line.From, line.To)
	end
	return string.format("%s %s", line.Label, line.To)
end

-- Plain text for a level-up card: what changes when going to `level` (1 = the weapon is new).
function WeaponData.DescribeLevel(weaponId: string, level: number): string
	local def = WeaponData.Weapons[weaponId]
	if not def then
		return ""
	end
	if level <= 1 then
		return def.Description
	end
	local parts = {}
	for _, line in ipairs(WeaponData.CardLines(weaponId, level - 1, level)) do
		table.insert(parts, WeaponData.LineText(line))
	end
	return table.concat(parts, ", ")
end

return WeaponData
