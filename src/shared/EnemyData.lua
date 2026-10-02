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
	  Burrow      { TunnelSpeed, SurfaceRange, MaxTunnel, Warn, Radius, Damage }: travels
	              underground as a dust trail (untargetable, harmless), stops near a player,
	              a circle warns for Warn s, it bursts out (Damage in Radius) and fights on
	  Support     { MinRange, MaxRange, Every, Windup, Radius, HealShare }: keeps its distance
	              behind the swarm; every Every s it glows for Windup s, then a green pulse
	              heals nearby enemies (not bosses, not nests) by HealShare of their max HP
	  Static      true = never moves (nests, the War Banner, Brood Eggs); never recycled
	  Spawner     { Every, Count, Type, MaxChildren, Warn }: a nest; mites climb out of its
	              openings every Every s (a small ring warns first) until it is destroyed
	  Hatch       { Seconds, Type, Count }: a Brood Egg hatches after Seconds unless destroyed
	  Rally       true = the War Banner: beetles near it are rallied (BossData WarBanner)
	  Beetle      true = rallied by a War Banner
	  ShowHP      true = a small HP bar over it (nests, banner, eggs)
	  NoWave      true = never in mini-waves (a ring of them would be neither fair nor useful)
	  Reward      { Gold, GoldPerStage, Gems }: a nest's reward to every living player
	  IsBoss      a boss body (BossData entry); Object = made by a boss (cleared with it)

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
	-- the rotating bosses of later stages (HP comes from Config.Boss x BossData HPMult)
	MothBoss = {
		Id = "MothBoss",
		DisplayName = "Moth Matriarch",
		HP = 9000,
		Speed = 9.5,
		Damage = 26,
		Radius = 5,
		Size = Vector3.new(10, 6, 10),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.6, 1) },
		Color = Palette.moth_300,
		Material = "SmoothPlastic",
		Gem = { Large = 100 },
		GemChance = 1,
		KnockbackResist = 1,
		XPScale = 20,
		IsBoss = true,
		FlyHeight = 0.5, -- the model itself hovers ~4 studs up; this adds the bob
		Role = "Boss: flies; dust waves with a gap, a swooping dive, glimmer mines, moths",
	},
	RhinoBoss = {
		Id = "RhinoBoss",
		DisplayName = "Rhino Warlord",
		HP = 9000,
		Speed = 7.5,
		Damage = 32,
		Radius = 6,
		Size = Vector3.new(11, 10, 12),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.8, 1.1) },
		Color = Palette.slate_600,
		Material = "SmoothPlastic",
		Gem = { Large = 100 },
		GemChance = 1,
		KnockbackResist = 1,
		XPScale = 20,
		IsBoss = true,
		Role = "Boss: heavy; horn charge (sticks in obstacles), ground pound, war banner",
	},
	HiveBoss = {
		Id = "HiveBoss",
		DisplayName = "Hive Mother",
		HP = 9000,
		Speed = 5.5,
		Damage = 26,
		Radius = 5.5,
		Size = Vector3.new(6, 5, 14),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.8, 1) },
		Color = Palette.ivory_300,
		Material = "SmoothPlastic",
		Gem = { Large = 100 },
		GemChance = 1,
		KnockbackResist = 1,
		XPScale = 20,
		IsBoss = true,
		Role = "Boss: slow; egg barrage, acid pools, brood call, pulses when hit hard",
	},

	-- creatures of the later minutes / stages
	Burrower = {
		Id = "Burrower",
		DisplayName = "Burrower",
		HP = 22,
		Speed = 7.5, -- above ground
		Damage = 8,
		Radius = 1.6,
		Size = Vector3.new(3.2, 1.6, 3.6),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.7, 1.1) },
		Color = Palette.dirt_300,
		Material = "SmoothPlastic",
		Gem = { Small = 70, Medium = 30 },
		GemChance = 1,
		KnockbackResist = 0.3,
		NoWave = true,
		Role = "Ambusher: tunnels to you as a dust trail, bursts out of a warned circle, then bites",
		Intro = "watch for the dust trail",
		Burrow = { TunnelSpeed = 12, SurfaceRange = 5, MaxTunnel = 8, Warn = 0.9, Radius = 3.2, Damage = 10 },
	},
	Healer = {
		Id = "Healer",
		DisplayName = "Healer",
		HP = 12,
		Speed = 8,
		Damage = 3,
		Radius = 1.3,
		Size = Vector3.new(2.6, 2.4, 3.2),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(0.9, 0.8, 1.1) },
		Color = Palette.ivory_300,
		Material = "SmoothPlastic",
		Gem = { Small = 50, Medium = 50 },
		GemChance = 1,
		KnockbackResist = 0,
		NoWave = true,
		Role = "Support: hangs back and heals the swarm with a green pulse; fragile, kill it first",
		Intro = "it heals the swarm, kill it first",
		Support = { MinRange = 16, MaxRange = 26, Every = 3.5, Windup = 0.6, Radius = 14, HealShare = 0.15 },
	},
	Nest = {
		Id = "Nest",
		DisplayName = "Nest",
		HP = 140,
		Speed = 0,
		Damage = 0,
		Radius = 2.6,
		Size = Vector3.new(5, 4, 5),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 0.9, 1) },
		Color = Palette.wood_500,
		Material = "SmoothPlastic",
		Gem = { Medium = 60, Large = 40 },
		GemChance = 1,
		KnockbackResist = 1,
		Static = true,
		ShowHP = true,
		NoWave = true,
		Role = "Spawner: mites climb out every few seconds until you destroy it (reward)",
		Intro = "destroy it to stop the mites",
		Spawner = { Every = 4.5, Count = 2, Type = "Slime", MaxChildren = 8, Warn = 0.7 },
		Reward = { Gold = 12, GoldPerStage = 6, Gems = 3 },
	},
	-- objects a boss makes (cleared when the boss dies)
	WarBanner = {
		Id = "WarBanner",
		DisplayName = "War Banner",
		HP = 260, -- replaced by BossData WarBanner.HPShare of the boss's max HP
		Speed = 0,
		Damage = 0,
		Radius = 1.8,
		Size = Vector3.new(3, 8, 3),
		Shape = "Block",
		Color = Palette.crimson_500,
		Material = "SmoothPlastic",
		Gem = { Medium = 100 },
		GemChance = 1,
		KnockbackResist = 1,
		Static = true,
		ShowHP = true,
		Rally = true,
		Object = true,
		NoWave = true,
		Role = "The Rhino Warlord's banner: beetles near it are faster and hit harder",
	},
	BroodEgg = {
		Id = "BroodEgg",
		DisplayName = "Brood Egg",
		HP = 30,
		Speed = 0,
		Damage = 0,
		Radius = 1.2,
		Size = Vector3.new(2, 2.6, 2),
		Shape = "Ball",
		Mesh = { Type = "Sphere", Scale = Vector3.new(1, 1.2, 1) },
		Color = Palette.ivory_200,
		Material = "SmoothPlastic",
		Gem = { Small = 100 },
		GemChance = 0.4,
		KnockbackResist = 1,
		Static = true,
		ShowHP = true,
		Object = true,
		NoWave = true,
		Role = "The Hive Mother's egg: hatches Mites unless destroyed in time",
		Hatch = { Seconds = 3.5, Type = "Slime", Count = 3 },
	},
}

-- Beetles a War Banner rallies (the Warlord's kin).
for _, id in ipairs({ "Skeleton", "Brute", "Slime", "Burrower" }) do
	(EnemyData.Enemies :: any)[id].Beetle = true
end

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
	{ Target = 82, Weights = { Slime = 20, Bat = 20, Skeleton = 25, Ghost = 15, Bomber = 10, Brute = 10, Spitter = 8, Healer = 3 } },
	{ Target = 92, Weights = { Slime = 15, Bat = 20, Skeleton = 25, Ghost = 20, Bomber = 10, Brute = 10, Spitter = 9, Healer = 4, Burrower = 4 } },
	{ Target = 100, Weights = { Slime = 15, Bat = 15, Skeleton = 25, Ghost = 20, Bomber = 12, Brute = 13, Spitter = 10, Healer = 4, Burrower = 5 } },
	{ Target = 110, Weights = { Slime = 10, Bat = 20, Skeleton = 25, Ghost = 20, Bomber = 12, Brute = 13, Spitter = 10, Healer = 5, Burrower = 6 } },
	{ Target = 120, Weights = { Slime = 10, Bat = 15, Skeleton = 25, Ghost = 20, Bomber = 15, Brute = 15, Spitter = 11, Healer = 5, Burrower = 6 } },
	{ Target = 130, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 25, Bomber = 15, Brute = 15, Spitter = 11, Healer = 5, Burrower = 7 } },
	{ Target = 140, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 15, Brute = 20, Spitter = 12, Healer = 6, Burrower = 7 } },
	{ Target = 150, Weights = { Slime = 10, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 15, Brute = 20, Spitter = 12, Healer = 6, Burrower = 8 } },
	{ Target = 160, Weights = { Slime = 5, Bat = 15, Skeleton = 20, Ghost = 20, Bomber = 20, Brute = 20, Spitter = 12, Healer = 6, Burrower = 8 } },
}

-- Row for a run time in seconds (clamped to the last row).
function EnemyData.GetSpawnRow(seconds: number)
	local index = math.clamp(math.floor(seconds / 60) + 1, 1, #EnemyData.SpawnTable)
	return EnemyData.SpawnTable[index]
end

return EnemyData
