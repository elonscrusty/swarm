--[[
	EnemyData.lua
	Enemy definitions and the per-minute spawn table.
	Theme: an alien insect swarm (Spitter, a ranged beetle, joins from minute 4). The ids
	are kept from the first version (Slime = Mite,
	Bat = Wasp, Skeleton = Beetle Warrior, Ghost = Phase Moth, Brute = Rhino Beetle,
	Bomber = Bomb Tick, Boss = Scorpion Queen); DisplayName is what players see.

	Enemy fields:
	  HP, Speed (studs/s), Damage (contact damage), Radius (hit radius in studs)
	  Size        body part size; Shape: "Ball" | "Block" | "Cylinder"
	  Mesh        optional built-in SpecialMesh { Type = "Sphere"|"Head"|"Wedge"|..., Scale }
	  Color, Material, Transparency  (plain body look: palette colours, SmoothPlastic, no Neon)
	  Gem         chance table for the XP gem it drops { Small = w, Medium = w, Large = w }
	  GemChance   0-1 chance to drop a gem at all
	  KnockbackResist 0-1 (1 = immune)
	  Ghost       true = ignores other enemies and obstacles
	  Erratic     0-1 sideways wobble strength (bats)
	  Explode     { Radius, Damage } = blows up on contact
	  XPScale     multiplies gem value (bosses)
	  Role        one line: the tactical job of the type (README roster table)
	  Intro       short callout shown once per run the first time the type spawns
	              ("New: <DisplayName> - <Intro>"); nil = no callout (the starters)
	  Ranged      { MinRange, MaxRange, Windup, Cooldown, Flight, Splash, Damage }: keeps its
	              distance, stops, swells for Windup s (a ground marker shows where the glob
	              lands), then lobs a slow glob that lands after Flight s (EnemyAI + Hazards)
	  Lunge       { MinRange, Range, Windup, Speed, Duration, Recover, Cooldown }: a short
	              telegraphed charge (lane on the floor) followed by a recovery pause
	  Fuse        seconds a bomber stands, swells and blinks (blast ring on the floor) before
	              it explodes; killing it during the fuse defuses it

	To add an enemy: add an entry to Enemies and give it weight in SpawnTable rows.
]]

local Palette = require(script.Parent.Palette)

local EnemyData = {}

EnemyData.Enemies = {
	Slime = {
		Id = "Slime",
		DisplayName = "Mite",
		HP = 8,
		Speed = 7,
		Damage = 5,
		Radius = 1.4,
		Size = Vector3.new(2.8, 2.2, 2.8),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(0.9, 0.8, 1) },
		Color = Palette.beetle_300,
		Material = "SmoothPlastic",
		Gem = { Small = 95, Medium = 5 },
		GemChance = 1,
		KnockbackResist = 0,
		Role = "Basic melee: the standard threat, walks straight at you",
	},
	Bat = {
		Id = "Bat",
		DisplayName = "Wasp",
		HP = 5,
		Speed = 13,
		Damage = 4,
		Radius = 1.2,
		Size = Vector3.new(2.6, 1, 1.4),
		Shape = "Block",
		Mesh = { Type = "Sphere", Scale = Vector3.new(0.62, 0.75, 1.3) },
		Color = Palette.wasp_500,
		Material = "SmoothPlastic",
		Gem = { Small = 97, Medium = 3 },
		GemChance = 0.9,
		KnockbackResist = 0,
		Erratic = 0.9,
		FlyHeight = 2.5,
		Role = "Fast and fragile: wobbles in quickly, pressures you to keep moving",
	},
	Skeleton = {
		Id = "Skeleton",
		DisplayName = "Beetle Warrior",
		HP = 20,
		Speed = 9,
		Damage = 8,
		Radius = 1.4,
		Size = Vector3.new(2, 4.2, 1.4),
		Shape = "Block",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 1, 1) },
		Color = Palette.beetle_700,
		Material = "SmoothPlastic",
		Gem = { Small = 80, Medium = 20 },
		GemChance = 1,
		KnockbackResist = 0.2,
		Role = "Armoured melee: tougher grunt, the Queen's summons",
		Intro = "tougher, armoured grunts",
	},
	Ghost = {
		Id = "Ghost",
		DisplayName = "Phase Moth",
		HP = 15,
		Speed = 10.5,
		Damage = 7,
		Radius = 1.4,
		Size = Vector3.new(2.6, 3.2, 2.6),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1.15, 0.5, 0.85) },
		Color = Palette.moth_300,
		Material = "SmoothPlastic",
		Transparency = 0.3,
		Gem = { Small = 85, Medium = 15 },
		GemChance = 1,
		KnockbackResist = 0.1,
		Ghost = true,
		FlyHeight = 1,
		Role = "Flanker: flies straight through trees and walls",
		Intro = "it flies through walls",
	},
	Brute = {
		Id = "Brute",
		DisplayName = "Rhino Beetle",
		HP = 90,
		Speed = 6,
		Damage = 16,
		Radius = 2.4,
		Size = Vector3.new(4.6, 5, 4.6),
		Shape = "Block",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.9, 1.15) },
		Color = Palette.slate_400,
		Material = "SmoothPlastic",
		Gem = { Medium = 70, Large = 30 },
		GemChance = 1,
		KnockbackResist = 0.9,
		Role = "Slow and durable: blocks paths; rears up, then lunges a short way",
		Intro = "sidestep its lunge",
		Lunge = { MinRange = 4, Range = 15, Windup = 0.65, Speed = 30, Duration = 0.45, Recover = 0.8, Cooldown = 4.5 },
	},
	Bomber = {
		Id = "Bomber",
		DisplayName = "Bomb Tick",
		HP = 12,
		Speed = 11.5,
		Damage = 0, -- damage comes from the explosion
		Radius = 1.3,
		Size = Vector3.new(2.4, 2.4, 2.4),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(0.95, 0.85, 1.1) },
		Color = Palette.tick_500,
		Material = "SmoothPlastic",
		Gem = { Small = 70, Medium = 30 },
		GemChance = 1,
		KnockbackResist = 0.3,
		Explode = { Radius = 8, Damage = 22 },
		Fuse = 0.7,
		Role = "Suicide bomber: stops next to you, swells for 0.7 s, then bursts",
		Intro = "step out of its ring",
	},
	Spitter = {
		Id = "Spitter",
		DisplayName = "Spitter",
		HP = 14,
		Speed = 8.5,
		Damage = 4, -- weak bite if you walk into it; the acid glob is its real attack
		Radius = 1.3,
		Size = Vector3.new(2.4, 2.6, 2.4),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.9, 1.05) },
		Color = Palette.crimson_500:Lerp(Palette.slate_400, 0.5), -- mauve shell (the model's)
		Material = "SmoothPlastic",
		Gem = { Small = 75, Medium = 25 },
		GemChance = 1,
		KnockbackResist = 0.1,
		Role = "Ranged: keeps 22-30 studs away and lobs acid at where you stand",
		Intro = "dodge the acid",
		Ranged = { MinRange = 22, MaxRange = 30, Windup = 0.7, Cooldown = 3.2, Flight = 1.05, Splash = 4.5, Damage = 12 },
	},
	Boss = {
		Id = "Boss",
		DisplayName = "Scorpion Queen",
		HP = 9000, -- overridden by Config.Boss.HP (kept here for reference)
		Speed = 8,
		Damage = 30,
		Radius = 6,
		Size = Vector3.new(12, 12, 12),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.75, 1.15) },
		Color = Palette.crimson_500,
		Material = "SmoothPlastic",
		Gem = { Large = 100 },
		GemChance = 1,
		KnockbackResist = 1,
		XPScale = 20,
		IsBoss = true,
		Role = "Boss: the stage's portal guardian (patterns in BossData)",
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
	{ Target = 62, Weights = { Slime = 30, Bat = 25, Skeleton = 25, Ghost = 15, Bomber = 5, Spitter = 4 } },
	{ Target = 72, Weights = { Slime = 25, Bat = 20, Skeleton = 25, Ghost = 15, Bomber = 10, Brute = 5, Spitter = 6 } },
	{ Target = 82, Weights = { Slime = 20, Bat = 20, Skeleton = 25, Ghost = 15, Bomber = 10, Brute = 10, Spitter = 8 } },
	{ Target = 92, Weights = { Slime = 15, Bat = 20, Skeleton = 25, Ghost = 20, Bomber = 10, Brute = 10, Spitter = 9 } },
	{ Target = 100, Weights = { Slime = 15, Bat = 15, Skeleton = 25, Ghost = 20, Bomber = 12, Brute = 13, Spitter = 10 } },
	{ Target = 110, Weights = { Slime = 10, Bat = 20, Skeleton = 25, Ghost = 20, Bomber = 12, Brute = 13, Spitter = 10 } },
	{ Target = 120, Weights = { Slime = 10, Bat = 15, Skeleton = 25, Ghost = 20, Bomber = 15, Brute = 15, Spitter = 11 } },
	{ Target = 130, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 25, Bomber = 15, Brute = 15, Spitter = 11 } },
	{ Target = 140, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 15, Brute = 20, Spitter = 12 } },
	{ Target = 150, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 15, Brute = 20, Spitter = 12 } },
	{ Target = 160, Weights = { Slime = 5, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 20, Brute = 20, Spitter = 12 } },
}

-- Row for a run time in seconds (clamped to the last row).
function EnemyData.GetSpawnRow(seconds: number)
	local index = math.clamp(math.floor(seconds / 60) + 1, 1, #EnemyData.SpawnTable)
	return EnemyData.SpawnTable[index]
end

return EnemyData
