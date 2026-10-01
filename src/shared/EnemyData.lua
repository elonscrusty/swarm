--[[
	EnemyData.lua
	Enemy definitions and the per-minute spawn table.

	Enemy fields:
	  HP, Speed (studs/s), Damage (contact damage), Radius (hit radius in studs)
	  Size        body part size; Shape: "Ball" | "Block" | "Cylinder"
	  Mesh        optional built-in SpecialMesh { Type = "Sphere"|"Head"|"Wedge"|..., Scale }
	  Color, Material, Transparency
	  Gem         chance table for the XP gem it drops { Small = w, Medium = w, Large = w }
	  GemChance   0-1 chance to drop a gem at all
	  KnockbackResist 0-1 (1 = immune)
	  Ghost       true = ignores other enemies and obstacles
	  Erratic     0-1 sideways wobble strength (bats)
	  Explode     { Radius, Damage } = blows up on contact
	  XPScale     multiplies gem value (bosses)

	To add an enemy: add an entry to Enemies and give it weight in SpawnTable rows.
]]

local EnemyData = {}

EnemyData.Enemies = {
	Slime = {
		Id = "Slime",
		HP = 8,
		Speed = 7,
		Damage = 5,
		Radius = 1.4,
		Size = Vector3.new(2.8, 2.2, 2.8),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.75, 1) },
		Color = Color3.fromRGB(90, 210, 90),
		Material = "SmoothPlastic",
		Gem = { Small = 95, Medium = 5 },
		GemChance = 1,
		KnockbackResist = 0,
	},
	Bat = {
		Id = "Bat",
		HP = 5,
		Speed = 13,
		Damage = 4,
		Radius = 1.2,
		Size = Vector3.new(2.6, 1, 1.4),
		Shape = "Block",
		Mesh = { Type = "Wedge", Scale = Vector3.new(1, 1, 1) },
		Color = Color3.fromRGB(70, 50, 90),
		Material = "SmoothPlastic",
		Gem = { Small = 97, Medium = 3 },
		GemChance = 0.9,
		KnockbackResist = 0,
		Erratic = 0.9,
		FlyHeight = 2.5,
	},
	Skeleton = {
		Id = "Skeleton",
		HP = 20,
		Speed = 9,
		Damage = 8,
		Radius = 1.4,
		Size = Vector3.new(2, 4.2, 1.4),
		Shape = "Block",
		Mesh = { Type = "Torso", Scale = Vector3.new(1, 1, 1) },
		Color = Color3.fromRGB(230, 225, 205),
		Material = "SmoothPlastic",
		Gem = { Small = 80, Medium = 20 },
		GemChance = 1,
		KnockbackResist = 0.2,
	},
	Ghost = {
		Id = "Ghost",
		HP = 15,
		Speed = 10.5,
		Damage = 7,
		Radius = 1.4,
		Size = Vector3.new(2.6, 3.2, 2.6),
		Shape = "Ball",
		Mesh = { Type = "Head", Scale = Vector3.new(1.1, 1.3, 1.1) },
		Color = Color3.fromRGB(200, 230, 255),
		Material = "Neon",
		Transparency = 0.45,
		Gem = { Small = 85, Medium = 15 },
		GemChance = 1,
		KnockbackResist = 0.1,
		Ghost = true,
		FlyHeight = 1,
	},
	Brute = {
		Id = "Brute",
		HP = 90,
		Speed = 6,
		Damage = 16,
		Radius = 2.4,
		Size = Vector3.new(4.6, 5, 4.6),
		Shape = "Block",
		Color = Color3.fromRGB(150, 90, 60),
		Material = "Slate",
		Gem = { Medium = 70, Large = 30 },
		GemChance = 1,
		KnockbackResist = 0.9,
	},
	Bomber = {
		Id = "Bomber",
		HP = 12,
		Speed = 11.5,
		Damage = 0, -- damage comes from the explosion
		Radius = 1.3,
		Size = Vector3.new(2.4, 2.4, 2.4),
		Shape = "Ball",
		Color = Color3.fromRGB(255, 70, 40),
		Material = "Neon",
		Gem = { Small = 70, Medium = 30 },
		GemChance = 1,
		KnockbackResist = 0.3,
		Explode = { Radius = 8, Damage = 22 },
	},
	Boss = {
		Id = "Boss",
		HP = 9000, -- overridden by Config.Boss.HP (kept here for reference)
		Speed = 8,
		Damage = 30,
		Radius = 6,
		Size = Vector3.new(12, 12, 12),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.9, 1) },
		Color = Color3.fromRGB(120, 20, 40),
		Material = "Neon",
		Gem = { Large = 100 },
		GemChance = 1,
		KnockbackResist = 1,
		XPScale = 20,
		IsBoss = true,
	},
}

-- Small XP gem bonus for elites (they also drop a chest).
EnemyData.EliteGem = { Large = 100 }

--[[
	Spawn table, one row per minute (index 1 = 0:00-0:59 ... index 15 = 14:00-14:59).
	  Target   living enemies the spawner keeps topped up (before player-count scaling)
	  Weights  relative spawn chance per enemy type this minute
]]
EnemyData.SpawnTable = {
	{ Target = 22, Weights = { Slime = 85, Bat = 15 } },
	{ Target = 32, Weights = { Slime = 65, Bat = 25, Skeleton = 10 } },
	{ Target = 42, Weights = { Slime = 50, Bat = 25, Skeleton = 25 } },
	{ Target = 52, Weights = { Slime = 40, Bat = 25, Skeleton = 25, Ghost = 10 } },
	{ Target = 62, Weights = { Slime = 30, Bat = 25, Skeleton = 25, Ghost = 15, Bomber = 5 } },
	{ Target = 72, Weights = { Slime = 25, Bat = 20, Skeleton = 25, Ghost = 15, Bomber = 10, Brute = 5 } },
	{ Target = 82, Weights = { Slime = 20, Bat = 20, Skeleton = 25, Ghost = 15, Bomber = 10, Brute = 10 } },
	{ Target = 92, Weights = { Slime = 15, Bat = 20, Skeleton = 25, Ghost = 20, Bomber = 10, Brute = 10 } },
	{ Target = 100, Weights = { Slime = 15, Bat = 15, Skeleton = 25, Ghost = 20, Bomber = 12, Brute = 13 } },
	{ Target = 110, Weights = { Slime = 10, Bat = 20, Skeleton = 25, Ghost = 20, Bomber = 12, Brute = 13 } },
	{ Target = 120, Weights = { Slime = 10, Bat = 15, Skeleton = 25, Ghost = 20, Bomber = 15, Brute = 15 } },
	{ Target = 130, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 25, Bomber = 15, Brute = 15 } },
	{ Target = 140, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 15, Brute = 20 } },
	{ Target = 150, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 15, Brute = 20 } },
	{ Target = 160, Weights = { Slime = 5, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 20, Brute = 20 } },
}

-- Row for a run time in seconds (clamped to the last row).
function EnemyData.GetSpawnRow(seconds: number)
	local index = math.clamp(math.floor(seconds / 60) + 1, 1, #EnemyData.SpawnTable)
	return EnemyData.SpawnTable[index]
end

return EnemyData
