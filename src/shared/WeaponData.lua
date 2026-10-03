--[[
	WeaponData.lua
	All 27 weapons, their 12 per-level stat rows, their evolutions, their
	behaviour perks and the projectile visuals.

	Stat row fields (every level row has all of them):
	  damage     damage per hit (before Might)
	  cooldown   seconds between attacks (before Cooldown passive)
	  amount     projectiles / slashes / strikes per attack (before Duplicator / Ammo)
	  area       size multiplier (slash length, aura radius, pool radius, projectile size)
	  speed      projectile speed in studs/s (0 = not a projectile)
	  pierce     enemies a projectile can hit before it disappears (999 = unlimited)
	  duration   projectile lifetime / pool lifetime / boomerang outbound time (seconds)
	  knockback  push strength in studs/s added to the enemy
	  heal       optional (Healing Totem): HP a pulse gives each player in range

	Behaviour constants that never change with level live in `Params`.
	An evolution needs the weapon at level 12 plus its `Passive` at rank 3 (or its maximum). It replaces the
	level-12 row with `Evolution.Stats` and switches on the evolution flags.

	Legacy mastery helpers below remain unused; no mastery cards or combat bonuses are wired.
	Evolution ends the weapon's progression chain.

	Perks: behaviour changes unlocked at a weapon level (and kept when evolved), e.g. the
	Whip's Riposte. `Perks = { { Level, Id, Name, Text } }`; WeaponSystem asks
	WeaponData.HasPerk(w, "Riposte"). Level-up cards show the perk as a NEW line.
	AmountLabel names the amount stat on cards ("Swings", "Arrows", ...); DurationLabel and
	CooldownLabel rename those two the same way.
	Flags read by the hero traits (CharacterData): Area = true for burning / area weapons
	(the Alchemist's Volatile Mix), Deployable = true for things you plant (the Engineer's
	Tinkerer). Params.MaxAmount caps the amount (turrets, totems: Duplicator can't go past it).
	Element = "Fire" | "Frost" | "Storm" tags the elemental weapons for the build synergies
	(SynergyData.lua); it changes nothing else.

	To add a weapon: add an entry to Weapons + its id to Order, then add a behaviour
	function in ServerScriptService/Modules/WeaponSystem.lua (Fire[Behavior]) and list
	the stats it uses in WeaponData.StatUse.
]]

local WeaponData = {}

WeaponData.MaxLevel = 12

-- Mastery ranks after max level: cumulative bonus at each rank (see the header).
WeaponData.MaxMastery = 10
WeaponData.Mastery = {
	--  damage  cooldown  area  amount
	{ damage = 0.08, cooldown = 0.00, area = 0.00, amount = 0 },
	{ damage = 0.08, cooldown = 0.03, area = 0.00, amount = 0 },
	{ damage = 0.08, cooldown = 0.03, area = 0.06, amount = 0 },
	{ damage = 0.15, cooldown = 0.03, area = 0.06, amount = 0 },
	{ damage = 0.15, cooldown = 0.06, area = 0.06, amount = 0 },
	{ damage = 0.15, cooldown = 0.06, area = 0.12, amount = 0 },
	{ damage = 0.21, cooldown = 0.06, area = 0.12, amount = 0 },
	{ damage = 0.21, cooldown = 0.09, area = 0.12, amount = 0 },
	{ damage = 0.26, cooldown = 0.09, area = 0.16, amount = 0 },
	{ damage = 0.30, cooldown = 0.12, area = 0.20, amount = 1 },
}

WeaponData.Order = {
	"Whip",
	"MagicOrb",
	"Knives",
	"Garlic",
	"HolyWater",
	"Lightning",
	"Axe",
	"Boomerang",
	"Longbow",
	"Spear",
	"Crossbow",
	"FrostNova",
	"FireTrail",
	"HealingTotem",
	"ChainHook",
	"Turret",
	"SoulBolt",
	"WardShields",
	"Earthsplitter",
	"Starfall",
	"Sling",
	"PlagueCenser",
	"Sawblade",
	"VineSnare",
	"WarHorn",
	"SpiritWisps",
	"Vortex",
}

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
	heal = "Heal",
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
	--[[
		22+: the weapons added with the Alchemist / Engineer / Necromancer (meshes Shot_Spear,
		Shot_Bolt, Shot_FrostShard, Shot_Totem, Shot_Hook, Shot_Soul, Ability_Turret, Shot_Fire).
		Indexes 32-63 are sent with bit 7 set (WeaponData.VisualByte), so the u8 still carries
		the 2-bit tier. Styles: "Spear" points along its thrust, "Bolt" straight, "Shard"
		tumbling ice, "Totem" / "Turret" stand on the floor (Ground = true: drawn at floor
		height; the turret's head pieces turn toward its target), "Hook" points outward with
		a chain back to its thrower (VFX), "Soul" faces where it flies with a slow bob.
		NoPose = true: spawning one next to a hero is not that hero's attack (turret bolts).
	]]
	[22] = { Name = "Spear", Shape = "Block", Size = Vector3.new(0.4, 0.22, 3.04), Color = Palette.wood_500, Material = "Wood", Style = "Spear", Trail = { Color = Palette.ivory_100, Tail = Palette.steel_300, Width = 0.28, Life = 0.08 }, Impact = Palette.ivory_200 },
	[23] = { Name = "DragonLance", Shape = "Block", Size = Vector3.new(0.4, 0.22, 3.04), Color = Palette.crimson_500, Material = "Metal", Style = "Spear", Trail = { Color = Palette.gold_200, Tail = Palette.crimson_400, Width = 0.36, Life = 0.1 }, Impact = Palette.gold_200 },
	[24] = { Name = "Bolt", Shape = "Block", Size = Vector3.new(0.4, 0.34, 1.74), Color = Palette.wood_600, Material = "Wood", Style = "Bolt", Trail = { Color = Palette.ivory_100, Tail = Palette.crimson_300, Width = 0.12, Life = 0.07 }, Impact = Palette.ivory_200 },
	[25] = { Name = "HeartBolt", Shape = "Block", Size = Vector3.new(0.4, 0.34, 1.74), Color = Palette.crimson_400, Material = "Neon", Style = "Bolt", Trail = { Color = Palette.crimson_300, Tail = Palette.gold_300, Width = 0.18, Life = 0.1 }, Impact = Palette.crimson_300 },
	[26] = { Name = "FrostShard", Shape = "Block", Size = Vector3.new(0.65, 0.46, 1.6), Color = Palette.ice_300, Material = "Glass", Style = "Shard", Tumble = 14, Trail = { Color = Palette.ice_100, Tail = Palette.ice_300, Width = 0.16, Life = 0.08 }, Impact = Palette.ice_100 },
	[27] = { Name = "Totem", Shape = "Block", Size = Vector3.new(1.8, 3.65, 0.95), Color = Palette.wood_500, Material = "Wood", Style = "Totem", Ground = true, NoPose = true, Impact = Palette.fx_heal },
	[28] = { Name = "GroveTotem", Shape = "Block", Size = Vector3.new(1.8, 3.65, 0.95), Color = Palette.gold_500, Material = "Wood", Style = "Totem", Ground = true, NoPose = true, Impact = Palette.fx_heal },
	[29] = { Name = "Hook", Shape = "Block", Size = Vector3.new(0.88, 0.25, 2.19), Color = Palette.steel_400, Material = "Metal", Style = "Hook", Impact = Palette.steel_200 },
	[30] = { Name = "ReaperHook", Shape = "Block", Size = Vector3.new(0.88, 0.25, 2.19), Color = Palette.crimson_500, Material = "Metal", Style = "Hook", Impact = Palette.crimson_300 },
	[31] = { Name = "Soul", Shape = "Ball", Size = Vector3.new(0.92, 0.95, 2.74), Color = Palette.ivory_200, Material = "SmoothPlastic", Style = "Soul", Trail = { Color = Palette.fx_heal, Tail = Palette.slate_400, Width = 0.5, Life = 0.22 }, Impact = Palette.fx_heal },
	[32] = { Name = "SoulStorm", Shape = "Ball", Size = Vector3.new(0.92, 0.95, 2.74), Color = Palette.ivory_200, Material = "SmoothPlastic", Style = "Soul", Trail = { Color = Palette.crimson_300, Tail = Palette.slate_600, Width = 0.6, Life = 0.24 }, Impact = Palette.crimson_300 },
	[33] = { Name = "Turret", Shape = "Block", Size = Vector3.new(2.28, 2.33, 2.6), Color = Palette.steel_600, Material = "Metal", Style = "Turret", Ground = true, NoPose = true, Impact = Palette.stone_300 },
	[34] = { Name = "Bastion", Shape = "Block", Size = Vector3.new(2.28, 2.33, 2.6), Color = Palette.gold_500, Material = "Metal", Style = "Turret", Ground = true, NoPose = true, Impact = Palette.gold_200 },
	[35] = { Name = "TurretShot", Shape = "Block", Size = Vector3.new(0.3, 0.26, 1.3), Color = Palette.gold_400, Material = "Metal", Style = "Bolt", NoPose = true, Trail = { Color = Palette.fx_gold, Tail = Palette.gold_500, Width = 0.12, Life = 0.06 }, Impact = Palette.fx_gold },
	[36] = { Name = "ZeroShard", Shape = "Block", Size = Vector3.new(0.65, 0.46, 1.6), Color = Palette.ice_100, Material = "Glass", Style = "Shard", Tumble = 18, Trail = { Color = Palette.fx_holy, Tail = Palette.fx_arcane, Width = 0.22, Life = 0.1 }, Impact = Palette.fx_holy },
	-- flames on the Fire Trail's burning patches (drawn by VFX from WeaponFx, never synced)
	[37] = { Name = "Flame", Shape = "Ball", Size = Vector3.new(1.08, 0.82, 1.65), Color = Palette.fx_fire, Material = "Neon", Style = "Flame", Ground = true },
	[38] = { Name = "PhoenixFlame", Shape = "Ball", Size = Vector3.new(1.08, 0.82, 1.65), Color = Palette.gold_300, Material = "Neon", Style = "Flame", Ground = true },
	--[[
		39-56: the armoury batch (Ward Shields ... Vortex), part-built in ModelLibrary (SHOTS).
		"Spear" style for shields (face outward along the synced yaw), "Rock" for fissure heads,
		"Meteor" falls tumbling, "Knife" stones, "Cloud" / "Vortex" turn slowly in place,
		"Saw" buzz saws, "Totem" vines rising out of the floor, "Orb" wisps.
	]]
	[39] = { Name = "WardShield", Shape = "Block", Size = Vector3.new(2.2, 2.4, 0.5), Color = Palette.steel_300, Material = "Metal", Style = "Spear", NoPose = true, Impact = Palette.ivory_200 },
	[40] = { Name = "AegisShield", Shape = "Block", Size = Vector3.new(2.6, 2.8, 0.5), Color = Palette.gold_400, Material = "Metal", Style = "Spear", NoPose = true, Impact = Palette.gold_200 },
	[41] = { Name = "Fissure", Shape = "Block", Size = Vector3.new(1.4, 1.2, 1.4), Color = Palette.stone_400, Material = "Slate", Style = "Rock", Tumble = 6, NoPose = true, Impact = Palette.stone_200 },
	[42] = { Name = "WorldbreakerRock", Shape = "Block", Size = Vector3.new(1.6, 1.4, 1.6), Color = Palette.basalt_600, Material = "Slate", Style = "Rock", Tumble = 8, NoPose = true, Impact = Palette.lava_300 },
	[43] = { Name = "Meteor", Shape = "Ball", Size = Vector3.new(2.4, 2.4, 2.4), Color = Palette.lava_500, Material = "Neon", Style = "Meteor", Tumble = 7, NoPose = true, Trail = { Color = Palette.amber_300, Tail = Palette.fx_fire, Width = 1.0, Life = 0.22 } },
	[44] = { Name = "Comet", Shape = "Ball", Size = Vector3.new(3.0, 3.0, 3.0), Color = Palette.gold_300, Material = "Neon", Style = "Meteor", Tumble = 8, NoPose = true, Trail = { Color = Palette.ivory_100, Tail = Palette.amber_500, Width = 1.3, Life = 0.26 } },
	[45] = { Name = "SlingStone", Shape = "Ball", Size = Vector3.new(0.9, 0.8, 0.9), Color = Palette.stone_300, Material = "Slate", Style = "Knife", Tumble = 18, Trail = { Color = Palette.ivory_200, Tail = Palette.stone_400, Width = 0.22, Life = 0.08 }, Impact = Palette.stone_200 },
	[46] = { Name = "Starstone", Shape = "Ball", Size = Vector3.new(1.1, 1.0, 1.1), Color = Palette.gold_400, Material = "Neon", Style = "Knife", Tumble = 20, Trail = { Color = Palette.gold_200, Tail = Palette.crimson_400, Width = 0.3, Life = 0.1 }, Impact = Palette.gold_200 },
	[47] = { Name = "PlagueCloud", Shape = "Ball", Size = Vector3.new(6, 3, 6), Color = Palette.moss_300, Material = "SmoothPlastic", Style = "Cloud", Spin = 0.8, NoPose = true },
	[48] = { Name = "Pestilence", Shape = "Ball", Size = Vector3.new(7, 3.4, 7), Color = Palette.moss_200, Material = "SmoothPlastic", Style = "Cloud", Spin = 1.1, NoPose = true },
	[49] = { Name = "Sawblade", Shape = "Cylinder", Size = Vector3.new(0.3, 2.6, 2.6), Color = Palette.steel_200, Material = "Metal", Style = "Saw", Spin = 26, Trail = { Color = Palette.ivory_100, Tail = Palette.steel_300, Width = 0.3, Life = 0.08 }, Impact = Palette.ivory_200 },
	[50] = { Name = "Ruinwheel", Shape = "Cylinder", Size = Vector3.new(0.3, 3.2, 3.2), Color = Palette.crimson_400, Material = "Metal", Style = "Saw", Spin = 30, Trail = { Color = Palette.crimson_300, Tail = Palette.gold_400, Width = 0.4, Life = 0.1 }, Impact = Palette.crimson_300 },
	[51] = { Name = "Snare", Shape = "Block", Size = Vector3.new(3, 2, 3), Color = Palette.moss_500, Material = "Grass", Style = "Totem", Ground = true, NoPose = true },
	[52] = { Name = "Strangleroot", Shape = "Block", Size = Vector3.new(3.6, 2.4, 3.6), Color = Palette.moss_700, Material = "Grass", Style = "Totem", Ground = true, NoPose = true },
	[53] = { Name = "Wisp", Shape = "Ball", Size = Vector3.new(0.9, 0.9, 0.9), Color = Palette.fx_holy, Material = "Neon", Style = "Orb", NoPose = true, Trail = { Color = Palette.fx_holy, Tail = Palette.ice_300, Width = 0.35, Life = 0.16 }, Impact = Palette.fx_holy },
	[54] = { Name = "ChoirWisp", Shape = "Ball", Size = Vector3.new(1.1, 1.1, 1.1), Color = Palette.gold_200, Material = "Neon", Style = "Orb", NoPose = true, Trail = { Color = Palette.gold_200, Tail = Palette.fx_holy, Width = 0.45, Life = 0.18 }, Impact = Palette.gold_200 },
	[55] = { Name = "Vortex", Shape = "Cylinder", Size = Vector3.new(0.3, 5, 5), Color = Palette.fx_arcane, Material = "Neon", Style = "Vortex", Spin = 5, Ground = true, NoPose = true },
	[56] = { Name = "Singularity", Shape = "Cylinder", Size = Vector3.new(0.3, 6, 6), Color = Palette.slate_900, Material = "Neon", Style = "Vortex", Spin = 7, Ground = true, NoPose = true },
}

-- Projectile visual byte: index 1-31 in the low 5 bits, 32-63 as (index - 32) with bit 7
-- set; bits 5-6 carry the cosmetic tier (0-3). VisualIndex / VisualTier decode it.
function WeaponData.VisualByte(index: number, tier: number): number
	local i = math.clamp(math.floor(index), 0, 63)
	return (i % 32) + math.clamp(tier, 0, 3) * 32 + (i >= 32 and 128 or 0)
end

function WeaponData.VisualIndex(raw: number): number
	return raw % 32 + (raw >= 128 and 32 or 0)
end

function WeaponData.VisualTier(raw: number): number
	return (raw // 32) % 4
end

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

-- A stat row with the Healing Totem's heal per pulse.
local function healing(r, heal: number)
	r.heal = heal
	return r
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
		Perks = { { Level = 9, Id = "Riposte", Name = "Riposte", Text = "Every 3rd attack also cuts all around you." } },
		-- hit shape: a sector Reach studs long and Arc degrees wide (same area as the old 13 x 4.5 box)
		Params = { Reach = 7, Arc = 150 },
		Levels = {
			row(10, 1.35, 1, 1.0, 0, 999, 0.25, 14),
			row(10, 1.35, 2, 1.0, 0, 999, 0.25, 14),
			row(15, 1.35, 2, 1.0, 0, 999, 0.25, 14),
			row(15, 1.35, 2, 1.05, 0, 999, 0.25, 15),
			row(15, 1.35, 2, 1.1, 0, 999, 0.25, 16),
			row(17.5, 1.35, 2, 1.1, 0, 999, 0.25, 16),
			row(20, 1.35, 2, 1.1, 0, 999, 0.25, 16),
			row(20, 1.325, 2, 1.15, 0, 999, 0.25, 17),
			row(20, 1.30, 2, 1.2, 0, 999, 0.25, 18),
			row(22.5, 1.3, 2, 1.2, 0, 999, 0.25, 18),
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
		Perks = { { Level = 7, Id = "Split", Name = "Splitting Orbs", Text = "An orb's first kill splits off 2 small orbs (half damage)." } },
		Params = { Radius = 1.0, TurnRate = 7, Visual = 1, EvoVisual = 6 },
		Levels = {
			row(10, 1.20, 1, 1.0, 38, 1, 3, 4),
			row(10, 1.20, 2, 1.0, 38, 1, 3, 4),
			row(10, 1.00, 2, 1.0, 38, 1, 3, 4),
			row(10, 1, 2, 1, 39, 1, 3, 4),
			row(10, 1.00, 3, 1.0, 40, 1, 3, 4),
			row(12.5, 1, 3, 1, 40, 1, 3, 4.5),
			row(15, 1.00, 3, 1.0, 40, 1, 3, 5),
			row(15, 1.00, 3, 1.0, 40, 2, 3, 5),
			row(15, 0.925, 3, 1, 41, 2, 3, 5),
			row(15, 0.85, 3, 1.0, 42, 2, 3, 5),
			row(17.5, 0.85, 3, 1.05, 42, 2, 3, 5.5),
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
			row(9, 1, 3, 1, 82.5, 1, 1, 2.5),
			row(9, 1.00, 3, 1.0, 85, 2, 1.0, 3),
			row(9, 0.975, 3, 1, 85, 2, 1, 3),
			row(9, 0.95, 4, 1.0, 85, 2, 1.0, 3),
			row(10, 0.95, 4, 1, 85, 2, 1, 3),
			row(11, 0.95, 4, 1.0, 85, 2, 1.0, 3),
			row(11, 0.9, 4, 1, 87.5, 2, 1, 3),
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
		Perks = { { Level = 6, Id = "Chill", Name = "Chilling Aura", Text = "Enemies inside the aura move 25% slower." } },
		Params = { Radius = 5.5 },
		Levels = {
			row(5, 1.10, 1, 1.0, 0, 999, 0, 6),
			row(5, 1.10, 1, 1.2, 0, 999, 0, 6),
			row(6, 1.1, 1, 1.2, 0, 999, 0, 6),
			row(7, 1.10, 1, 1.2, 0, 999, 0, 6),
			row(7, 1.025, 1, 1.2, 0, 999, 0, 6.5),
			row(7, 0.95, 1, 1.2, 0, 999, 0, 7),
			row(7, 0.95, 1, 1.3, 0, 999, 0, 7),
			row(7, 0.95, 1, 1.4, 0, 999, 0, 7),
			row(8, 0.95, 1, 1.4, 0, 999, 0, 7),
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
		Element = "Fire", -- SynergyData (Elemental Trinity, Ember Field)
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
			row(9.5, 4.2, 2, 1.2, 30, 999, 2.75, 0),
			row(11, 4.2, 2, 1.2, 30, 999, 3.0, 0),
			row(11, 4.2, 3, 1.2, 30, 999, 3.0, 0),
			row(11, 4.1, 3, 1.3, 30, 999, 3, 0),
			row(11, 4.0, 3, 1.4, 30, 999, 3.0, 0),
			row(12.5, 4, 3, 1.4, 30, 999, 3.25, 0),
			row(14, 4.0, 3, 1.4, 30, 999, 3.5, 0),
			row(14, 3.8, 3, 1.4, 30, 999, 3.5, 0),
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
		Element = "Storm", -- SynergyData (Elemental Trinity)
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
			row(20, 3, 3, 1.15, 0, 999, 0, 0),
			row(20, 3.0, 3, 1.3, 0, 999, 0, 0),
			row(20, 3.0, 4, 1.3, 0, 999, 0, 0),
			row(23, 2.8, 4, 1.3, 0, 999, 0, 0),
			row(26, 2.6, 4, 1.3, 0, 999, 0, 0),
			row(26, 2.6, 4, 1.45, 0, 999, 0, 0),
			row(26, 2.6, 4, 1.6, 0, 999, 0, 0),
			row(29, 2.6, 4, 1.6, 0, 999, 0, 0),
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
			row(30, 2.5, 2, 1, 22, 4, 3, 11),
			row(30, 2.5, 2, 1.0, 22, 5, 3.0, 12),
			row(30, 2.5, 2, 1, 23, 5, 3, 12),
			row(30, 2.5, 3, 1.0, 24, 5, 3.0, 12),
			row(35, 2.5, 3, 1.1, 24, 5, 3, 12),
			row(40, 2.5, 3, 1.2, 24, 5, 3.0, 12),
			row(40, 2.5, 3, 1.2, 24, 6, 3, 13),
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
			row(14, 2.2, 2, 1, 39, 999, 0.8, 6.5),
			row(14, 2.2, 2, 1.0, 42, 999, 0.8, 7),
			row(16, 2.2, 2, 1.1, 42, 999, 0.8, 7),
			row(18, 2.2, 2, 1.2, 42, 999, 0.8, 7),
			row(18, 2.2, 3, 1.2, 42, 999, 0.8, 7),
			row(18, 2.05, 3, 1.2, 42, 999, 0.8, 7.5),
			row(18, 1.9, 3, 1.2, 42, 999, 0.8, 8),
			row(21, 1.9, 3, 1.2, 43, 999, 0.85, 8),
			row(24, 1.9, 4, 1.2, 44, 999, 0.9, 8),
		},
		Evolution = {
			Id = "InfiniteReturn",
			Name = "Infinite Return",
			Passive = "Cooldown",
			Description = "Boomerangs that never stop, bouncing between foes and you.",
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
		Description = "Heavy arrows that pierce and fly far, aimed at the nearest enemy.",
		Color = Color3.fromRGB(150, 190, 110),
		Behavior = "Longbow",
		AmountLabel = "Arrows",
		DurationLabel = "Range",
		Params = { Radius = 0.9, Spread = 1.1, Visual = 20, EvoVisual = 21, VolleyEvery = 3, VolleyAngle = 12 },
		Perks = { { Level = 10, Id = "Volley", Name = "Volley", Text = "Every 3rd shot also fires 2 arrows to the sides." } },
		Levels = {
			row(18, 1.70, 1, 1.0, 100, 2, 0.90, 8),
			row(24, 1.70, 1, 1.0, 100, 2, 0.90, 8),
			row(24, 1.7, 1, 1, 102.5, 2, 0.925, 8.5),
			row(24, 1.70, 1, 1.0, 105, 3, 0.95, 9),
			row(24, 1.65, 1, 1, 105, 3, 0.95, 9),
			row(24, 1.60, 2, 1.0, 105, 3, 0.95, 9),
			row(27, 1.6, 2, 1, 107.5, 3, 0.975, 9.5),
			row(30, 1.60, 2, 1.0, 110, 3, 1.00, 10),
			row(30, 1.55, 2, 1.05, 110, 3, 1, 10),
			row(30, 1.50, 2, 1.1, 110, 4, 1.00, 10),
			row(36, 1.50, 2, 1.1, 115, 4, 1.00, 11),
			row(42, 1.40, 2, 1.2, 115, 5, 1.00, 12),
		},
		Evolution = {
			Id = "Windpiercer",
			Name = "Windpiercer",
			Passive = "Fletching",
			Description = "Every shot is a volley of wind arrows piercing everything.",
			Stats = row(52, 1.25, 2, 1.3, 125, 999, 1.10, 12),
			Fan = true, -- every shot adds the two side arrows (the Volley perk on every shot)
		},
	},

	--[[
		The weapons below came with the Alchemist (Fire Trail), the Engineer (Turret) and the
		Necromancer (Soul Bolt); every hero can find them on level-up cards. Per-target DPS
		(damage x amount / cooldown, the same measure as the Longbow note above; area weapons
		hit everything in range, so their per-target number is lower on purpose):
		  Spear        L1 11.7  L8 64   Dragon Lance 140 + tip bursts (≈ 160)
		  Crossbow     L1 8.4   L8 65   Heartseeker 131 + 3 ricochets (≈ 165)
		  Frost Nova   L1 4.0   L8 13.6 Absolute Zero 22 (area + slow; Garlic L8 13, Soul Eater 19)
		  Fire Trail   L1 8     L8 24   Phoenix Stride 32 + ignite (≈ 40) while in the flames
		               (per 0.5 s tick; Holy Water L8 28, Hellfire 36)
		  Healing Totem L1 4.7  L8 18   Lifebloom 32 (area pulses + heals; Garlic L8 13)
		  Chain Hook   L1 7.5   L8 44 + the chain's 60% on the line   Reaper's Chain 118 + chain (≈ 160)
		  Turret       L1 7.8   L8 62   Bastion 145 (bolts per turret every 0.55 s / 0.33 s,
		               x turrets x uptime = min(1, life / rebuild))
		  Soul Bolt    L1 6.4   L8 65   Soul Storm 153 (homing: every soul finds a target)
		Reference: Longbow 10.6 / 60 / 166, Knives 7 / 65 / 150, Death Spiral 160.
	]]

	-- SPEAR: thrusts out and back in the direction you face, piercing a line of enemies.
	Spear = {
		Id = "Spear",
		Name = "Spear",
		Description = "Thrusts a spear forward, piercing a line of enemies.",
		Color = Color3.fromRGB(190, 150, 90),
		Behavior = "Spear",
		AmountLabel = "Spears",
		Perks = { { Level = 6, Id = "Impale", Name = "Impale", Text = "The first enemy each spear hits takes +50% damage." } },
		-- Reach studs at area 1, Width = hit radius along the shaft, ThrustTime = out and back
		Params = { Reach = 11, Width = 1.3, ThrustTime = 0.26, FanAngle = 14, ImpaleBonus = 0.5, BurstRadius = 4.5, BurstShare = 0.6, Visual = 22, EvoVisual = 23 },
		Levels = {
			row(14, 1.20, 1, 1.0, 0, 3, 0, 10),
			row(18, 1.20, 1, 1.0, 0, 3, 0, 10),
			row(18, 1.20, 2, 1.0, 0, 3, 0, 10),
			row(20, 1.175, 2, 1.05, 0, 3, 0, 10.5),
			row(22, 1.15, 2, 1.1, 0, 4, 0, 11),
			row(22, 1.15, 2, 1.1, 0, 5, 0, 11),
			row(24, 1.125, 2, 1.15, 0, 5, 0, 11.5),
			row(26, 1.10, 2, 1.2, 0, 5, 0, 12),
			row(27.5, 1.075, 2, 1.2, 0, 5, 0, 12),
			row(29, 1.05, 2, 1.2, 0, 6, 0, 12),
			row(30.5, 1.025, 2, 1.25, 0, 6, 0, 12.5),
			row(32, 1.00, 2, 1.3, 0, 6, 0, 13),
		},
		Evolution = {
			Id = "DragonLance",
			Name = "Dragon Lance",
			Passive = "Might",
			Description = "Three crimson lances that pierce all and burst at the tip.",
			Stats = row(42, 0.90, 3, 1.5, 0, 999, 0, 14),
			Burst = true, -- each thrust bursts at its full reach (BurstShare of the damage)
		},
	},

	-- CROSSBOW: fast straight bolts at the nearest enemies.
	Crossbow = {
		Id = "Crossbow",
		Name = "Crossbow",
		Description = "Fast bolts at the nearest enemies.",
		Color = Color3.fromRGB(170, 120, 90),
		Behavior = "Crossbow",
		AmountLabel = "Bolts",
		DurationLabel = "Range",
		Perks = { { Level = 6, Id = "Ricochet", Name = "Ricochet", Text = "A bolt that would stop bounces once to the nearest other enemy." } },
		Params = { Radius = 0.7, Visual = 24, EvoVisual = 25 },
		Levels = {
			row(8, 0.95, 1, 1.0, 120, 1, 0.65, 3),
			row(11, 0.95, 1, 1.0, 120, 1, 0.65, 3),
			row(11, 0.925, 1, 1, 122.5, 1, 0.65, 3),
			row(11, 0.90, 2, 1.0, 125, 1, 0.65, 3),
			row(12, 0.9, 2, 1, 125, 1, 0.65, 3),
			row(13, 0.90, 2, 1.0, 125, 1, 0.65, 3),
			row(13, 0.875, 2, 1, 127.5, 1, 0.65, 3),
			row(13, 0.85, 3, 1.0, 130, 1, 0.65, 3),
			row(14, 0.85, 3, 1, 130, 1, 0.675, 3.5),
			row(15, 0.85, 3, 1.0, 130, 2, 0.70, 4),
			row(16, 0.80, 3, 1.0, 135, 2, 0.70, 4),
			row(17, 0.78, 3, 1.1, 140, 2, 0.70, 4),
		},
		Evolution = {
			Id = "Heartseeker",
			Name = "Heartseeker",
			Passive = "Precision",
			Description = "Crimson bolts that ricochet three times.",
			Stats = row(24, 0.55, 3, 1.1, 150, 2, 0.75, 4),
			Bounces = 3,
		},
	},

	-- FROST NOVA: a periodic burst of ice around you that damages and slows (not bosses).
	FrostNova = {
		Id = "FrostNova",
		Element = "Frost", -- SynergyData (Elemental Trinity)
		Name = "Frost Nova",
		Description = "A frost burst around you that damages and slows enemies.",
		Color = Color3.fromRGB(150, 200, 230),
		Behavior = "Nova",
		Area = true,
		AmountLabel = nil, -- one burst: Amount does nothing for the nova
		DurationLabel = "Slow time",
		Perks = { { Level = 8, Id = "Shatter", Name = "Shatter", Text = "Enemies the nova kills burst into 3 ice shards (half damage)." } },
		-- Slow = enemy speed multiplier while chilled (EnemyAI SlowMult)
		Params = { Radius = 8, Slow = 0.6, EvoSlow = 0.3, ShardCount = 3, ShardShare = 0.5, ShardSpeed = 48, MaxShards = 12, Visual = 26, EvoVisual = 36 },
		Levels = {
			row(12, 3.0, 1, 1.0, 0, 999, 1.5, 4),
			row(12, 3.0, 1, 1.15, 0, 999, 1.5, 4),
			row(14, 3, 1, 1.15, 0, 999, 1.65, 4),
			row(16, 3.0, 1, 1.15, 0, 999, 1.8, 4),
			row(16, 2.85, 1, 1.15, 0, 999, 1.8, 4.5),
			row(16, 2.7, 1, 1.15, 0, 999, 1.8, 5),
			row(18, 2.7, 1, 1.225, 0, 999, 1.9, 5),
			row(20, 2.7, 1, 1.3, 0, 999, 2.0, 5),
			row(22, 2.6, 1, 1.3, 0, 999, 2, 5),
			row(24, 2.5, 1, 1.3, 0, 999, 2.0, 5),
			row(26, 2.4, 1, 1.45, 0, 999, 2.2, 6),
			row(30, 2.2, 1, 1.6, 0, 999, 2.5, 6),
		},
		Evolution = {
			Id = "AbsoluteZero",
			Name = "Absolute Zero",
			Passive = "Area",
			Description = "A huge blizzard burst that nearly freezes the swarm.",
			Stats = row(42, 1.9, 1, 2.0, 0, 999, 3.0, 6),
			DeepFreeze = true, -- slow to EvoSlow instead of Slow
		},
	},

	-- FIRE TRAIL: burning ground behind you as you move. Never hurts players.
	FireTrail = {
		Id = "FireTrail",
		Element = "Fire", -- SynergyData (Elemental Trinity, Ember Field)
		Name = "Fire Trail",
		Description = "Burning ground follows your steps. It never hurts heroes.",
		Color = Color3.fromRGB(230, 130, 60),
		Behavior = "FireTrail",
		Area = true,
		AmountLabel = nil,
		DurationLabel = "Burn time",
		CooldownLabel = "Flame every",
		Perks = { { Level = 8, Id = "Wildfire", Name = "Wildfire", Text = "Every 3rd flame patch is 60% wider." } },
		-- damage per Tick to enemies in a patch; Spacing = studs walked between patches
		Params = { Radius = 3.2, Tick = 0.5, Arm = 0.15, Spacing = 2.2, MaxPatches = 16, WildfireEvery = 3, WildfireScale = 1.6, IgniteSeconds = 2, IgniteShare = 0.5, Visual = 37, EvoVisual = 38 },
		Levels = {
			row(4, 0.45, 1, 1.0, 0, 999, 2.0, 0),
			row(5, 0.45, 1, 1.0, 0, 999, 2.2, 0),
			row(5, 0.425, 1, 1.075, 0, 999, 2.2, 0),
			row(5, 0.40, 1, 1.15, 0, 999, 2.2, 0),
			row(6, 0.4, 1, 1.15, 0, 999, 2.35, 0),
			row(7, 0.40, 1, 1.15, 0, 999, 2.5, 0),
			row(7, 0.4, 1, 1.2, 0, 999, 2.5, 0),
			row(7, 0.40, 1, 1.25, 0, 999, 2.5, 0),
			row(8, 0.375, 1, 1.25, 0, 999, 2.65, 0),
			row(9, 0.35, 1, 1.25, 0, 999, 2.8, 0),
			row(10, 0.35, 1, 1.35, 0, 999, 2.8, 0),
			row(12, 0.30, 1, 1.4, 0, 999, 3.0, 0),
		},
		Evolution = {
			Id = "PhoenixStride",
			Name = "Phoenix Stride",
			Passive = "SpeedBoots",
			Description = "Golden flames that keep burning enemies for 2 seconds.",
			Stats = row(16, 0.25, 1, 1.7, 0, 999, 3.5, 0),
			Ignite = true,
		},
	},

	-- HEALING TOTEM: plants a totem that pulses small heals to heroes and hurts enemies.
	HealingTotem = {
		Id = "HealingTotem",
		Name = "Healing Totem",
		Description = "Plants a totem that heals allies and hurts enemies near it.",
		Color = Color3.fromRGB(140, 190, 110),
		Behavior = "Totem",
		Area = true,
		Deployable = true,
		AmountLabel = "Totems",
		DurationLabel = "Totem life",
		CooldownLabel = "Plant every",
		Perks = { { Level = 8, Id = "Rooting", Name = "Rooting Pulse", Text = "Every 3rd pulse roots enemies in the ring for 0.5 s." } },
		-- Pulse = seconds between pulses; a hero is healed by at most one totem per HealGap
		Params = { Radius = 7, Pulse = 1.0, EvoPulse = 0.8, HealGap = 0.9, RootEvery = 3, RootSeconds = 0.5, MaxAmount = 3, Visual = 27, EvoVisual = 28 },
		Levels = {
			healing(row(6, 9.0, 1, 1.0, 0, 999, 7.0, 2), 1),
			healing(row(8, 9.0, 1, 1.0, 0, 999, 7.0, 2), 1),
			healing(row(8, 8.5, 1, 1.075, 0, 999, 7.5, 2), 1.25),
			healing(row(8, 8.0, 1, 1.15, 0, 999, 8.0, 2), 1.5),
			healing(row(9, 8, 1, 1.15, 0, 999, 8, 2), 1.5),
			healing(row(10, 8.0, 1, 1.15, 0, 999, 8.0, 2), 1.5),
			healing(row(10, 8, 1, 1.15, 0, 999, 8, 2), 1.75),
			healing(row(10, 8.0, 2, 1.15, 0, 999, 8.0, 2), 2),
			healing(row(11.5, 7.75, 2, 1.225, 0, 999, 8.25, 2.5), 2),
			healing(row(13, 7.5, 2, 1.3, 0, 999, 8.5, 3), 2),
			healing(row(15, 7.5, 2, 1.3, 0, 999, 9.0, 3), 2.5),
			healing(row(18, 7.0, 2, 1.4, 0, 999, 9.0, 3), 2.5),
		},
		Evolution = {
			Id = "Lifebloom",
			Name = "Lifebloom",
			Passive = "Renewal",
			Description = "Three golden totems that pulse faster and heal more.",
			Stats = healing(row(26, 6.0, 3, 1.7, 0, 999, 10, 3), 4),
		},
	},

	-- CHAIN HOOK: hooks the furthest enemy in front of you and drags it in.
	ChainHook = {
		Id = "ChainHook",
		Name = "Chain Hook",
		Description = "Hooks a far enemy and drags it in, hurting all along the chain.",
		Color = Color3.fromRGB(150, 160, 175),
		Behavior = "Hook",
		AmountLabel = "Hooks",
		DurationLabel = "Reach time",
		Perks = { { Level = 6, Id = "Barbed", Name = "Barbed Chain", Text = "Enemies along the chain are dragged in too." } },
		-- Cone = half-angle (degrees) around your facing; reach = speed x duration
		Params = { Cone = 40, Radius = 1.0, PullTo = 5, ChainWidth = 1.6, ChainShare = 0.6, Visual = 29, EvoVisual = 30 },
		Levels = {
			row(18, 2.4, 1, 1.0, 75, 999, 0.42, 0),
			row(22, 2.4, 1, 1.0, 75, 999, 0.42, 0),
			row(22, 2.3, 1, 1.05, 77.5, 999, 0.435, 0),
			row(22, 2.2, 1, 1.1, 80, 999, 0.45, 0),
			row(24, 2.2, 1, 1.1, 80, 999, 0.45, 0),
			row(26, 2.2, 1, 1.1, 80, 999, 0.45, 0),
			row(26, 2.1, 1, 1.1, 82.5, 999, 0.45, 0),
			row(26, 2.0, 2, 1.1, 85, 999, 0.45, 0),
			row(29, 2, 2, 1.15, 85, 999, 0.465, 0),
			row(32, 2.0, 2, 1.2, 85, 999, 0.48, 0),
			row(36, 1.9, 2, 1.2, 90, 999, 0.50, 0),
			row(40, 1.8, 2, 1.3, 90, 999, 0.50, 0),
		},
		Evolution = {
			Id = "ReapersChain",
			Name = "Reaper's Chain",
			Passive = "Vacuum",
			Description = "Three crimson hooks reel in whole lines of the swarm.",
			Stats = row(55, 1.4, 3, 1.5, 100, 999, 0.55, 0),
		},
	},

	-- TURRET (the Engineer's weapon): builds turrets that shoot the nearest enemies.
	Turret = {
		Id = "Turret",
		Name = "Turret",
		Description = "Builds a turret beside you that shoots nearby enemies (max 2).",
		Color = Color3.fromRGB(190, 160, 90),
		Behavior = "Turret",
		Deployable = true,
		AmountLabel = "Turrets",
		DurationLabel = "Turret life",
		CooldownLabel = "Rebuild",
		Perks = { { Level = 8, Id = "Flak", Name = "Flak Shells", Text = "Every 4th turret shot bursts for half damage around its target." } },
		-- damage / speed / pierce are the turret's bolts; ShotEvery = seconds between shots
		Params = { ShotEvery = 0.55, EvoShotEvery = 0.33, Range = 30, BoltRadius = 0.6, FlakEvery = 4, FlakRadius = 3.5, FlakShare = 0.5, MaxAmount = 2, Visual = 33, EvoVisual = 34, ShotVisual = 35 },
		Levels = {
			row(6, 7.0, 1, 1.0, 90, 1, 5.0, 2),
			row(8, 7.0, 1, 1.0, 90, 1, 5.0, 2),
			row(8, 6.75, 1, 1.05, 92.5, 1, 5.25, 2),
			row(8, 6.5, 1, 1.1, 95, 1, 5.5, 2),
			row(9, 6.5, 1, 1.1, 95, 1, 5.5, 2),
			row(10, 6.5, 1, 1.1, 95, 1, 5.5, 2),
			row(10, 6.5, 1, 1.1, 95, 1, 5.75, 2),
			row(10, 6.5, 2, 1.1, 95, 1, 6.0, 2),
			row(11.5, 6.25, 2, 1.15, 97.5, 1, 6, 2.5),
			row(13, 6.0, 2, 1.2, 100, 2, 6.0, 3),
			row(15, 6.0, 2, 1.2, 100, 2, 6.0, 3),
			row(17, 6.0, 2, 1.3, 105, 2, 6.0, 3),
		},
		Evolution = {
			Id = "Bastion",
			Name = "Bastion",
			Passive = "Armor",
			Description = "Gilded turrets, almost twice as fast, with piercing bolts.",
			Stats = row(24, 5.0, 2, 1.5, 120, 3, 7.0, 3),
		},
	},

	-- SOUL BOLT (the Necromancer's weapon): slow homing souls that find a new target.
	SoulBolt = {
		Id = "SoulBolt",
		Name = "Soul Bolt",
		Description = "Releases homing souls that seek out enemies around you.",
		Color = Color3.fromRGB(170, 210, 160),
		Behavior = "Soul",
		AmountLabel = "Souls",
		Perks = { { Level = 5, Id = "Wandering", Name = "Wandering Souls", Text = "A soul that kills its target flies on to another enemy." } },
		Params = { Radius = 0.9, TurnRate = 5, Range = 55, Seek = 30, Visual = 31, EvoVisual = 32 },
		Levels = {
			row(9, 1.40, 1, 1.0, 30, 1, 4.0, 2),
			row(9, 1.40, 2, 1.0, 30, 1, 4.0, 2),
			row(12, 1.40, 2, 1.0, 32, 1, 4.0, 2),
			row(12, 1.35, 2, 1, 32, 1, 4, 2),
			row(12, 1.30, 2, 1.0, 32, 1, 4.0, 2),
			row(12, 1.3, 2, 1, 33, 1, 4, 2),
			row(12, 1.30, 3, 1.0, 34, 1, 4.0, 2),
			row(13.5, 1.25, 3, 1, 34, 1, 4, 2.5),
			row(15, 1.20, 3, 1.0, 34, 2, 4.0, 3),
			row(16, 1.2, 3, 1.05, 35, 2, 4, 3),
			row(17, 1.20, 3, 1.1, 36, 2, 4.0, 3),
			row(18, 1.10, 4, 1.1, 36, 2, 4.5, 3),
		},
		Evolution = {
			Id = "SoulStorm",
			Name = "Soul Storm",
			Passive = "Growth",
			Description = "A storm of crimson souls that pass through three enemies each.",
			Stats = row(26, 0.85, 5, 1.2, 42, 3, 5.0, 3),
		},
	},

	--[[
		The ten weapons of the "armoury" batch (every hero can find them on level-up cards).
		Per-target DPS at L1 / L6 / L12 / evolved (same measure as the notes above; line and
		area weapons are per target inside the effect):
		  Ward Shields   6.8 / 20 / 51 / 125   orbiting, hits all around, Bulwark eats shots
		  Earthsplitter  7 / 13 / 30 / 49      line of spikes (+ Aftershock eruptions)
		  Starfall       10 / 17 / 30 / 50     delayed blast on the densest crowd + crater
		  Sling          6.9 / 25 / 67 / 149   one stone bounces through 3-8 enemies
		  Plague Censer  6 / 12 / 22 / 30      drifting cloud (+ Pestilence poison)
		  Sawblade       7.5 / 30 / 70 / 160   grinds slowly through crowds (3 bites a pass)
		  Vine Snare     8 / 14 / 22 / 30      roots a spot (inside the snare)
		  War Horn       5 / 10 / 19 / 32      cone with big knockback (+ Echo 60%)
		  Spirit Wisps   5.7 / 30 / 67 / 147   darting wisps that come back to orbit you
		  Vortex         6 / 10 / 17.5 / 25    pulls a crowd together (+ Implosion)
	]]

	-- WARD SHIELDS: shields always circle you, hitting what they pass (cooldown = how often
	-- the same enemy can be hit). Bulwark: they smash enemy projectiles.
	WardShields = {
		Id = "WardShields",
		Name = "Ward Shields",
		Description = "Shields circle you and bash every enemy they pass.",
		Color = Color3.fromRGB(120, 160, 210),
		Behavior = "Shields",
		AmountLabel = "Shields",
		CooldownLabel = "Hit every",
		Perks = { { Level = 7, Id = "Bulwark", Name = "Bulwark", Text = "Shields smash enemy projectiles they touch." } },
		-- OrbitRadius / ShieldRadius at area 1; speed = studs per second along the orbit
		Params = { OrbitRadius = 4.2, ShieldRadius = 1.4, MaxAmount = 8, ReflectRadius = 4, Visual = 39, EvoVisual = 40 },
		Levels = {
			row(9, 0.90, 1, 1.0, 20, 999, 0, 6),
			row(9, 0.90, 2, 1.0, 20, 999, 0, 6),
			row(12, 0.90, 2, 1.0, 21, 999, 0, 6),
			row(12, 0.85, 2, 1.1, 22, 999, 0, 7),
			row(14, 0.85, 3, 1.1, 22, 999, 0, 7),
			row(16, 0.80, 3, 1.1, 23, 999, 0, 7),
			row(16, 0.80, 3, 1.15, 24, 999, 0, 8),
			row(19, 0.75, 3, 1.15, 24, 999, 0, 8),
			row(19, 0.70, 4, 1.2, 25, 999, 0, 8),
			row(22, 0.65, 4, 1.2, 26, 999, 0, 9),
			row(25, 0.60, 4, 1.25, 27, 999, 0, 9),
			row(28, 0.55, 5, 1.3, 28, 999, 0, 10),
		},
		Evolution = {
			Id = "AegisRing",
			Name = "Aegis Ring",
			Passive = "AegisCharm",
			Description = "Six golden shields; every shot they smash bursts back at the swarm.",
			Stats = row(50, 0.40, 6, 1.5, 32, 999, 0, 12),
			Reflect = true, -- a smashed projectile bursts for full damage around it
		},
	},

	-- EARTHSPLITTER: fissures race along the ground toward the nearest enemy, spikes bursting
	-- up every few studs (each enemy is hit once per fissure). Aftershock: the end erupts.
	Earthsplitter = {
		Id = "Earthsplitter",
		Name = "Earthsplitter",
		Description = "Splits the ground toward enemies; stone spikes burst along the crack.",
		Color = Color3.fromRGB(170, 130, 90),
		Behavior = "Quake",
		Area = true,
		AmountLabel = "Fissures",
		DurationLabel = "Length",
		Perks = { { Level = 8, Id = "Aftershock", Name = "Aftershock", Text = "Each fissure ends in a big eruption." } },
		-- reach = speed x duration; StepDist studs between spike bursts of SpikeRadius
		Params = { StepDist = 2.4, SpikeRadius = 2.2, FanAngle = 25, Range = 40, AftershockRadius = 5, AftershockShare = 1.0, Visual = 41, EvoVisual = 42 },
		Levels = {
			row(14, 2.0, 1, 1.0, 30, 999, 0.8, 8),
			row(18, 2.0, 1, 1.0, 30, 999, 0.8, 8),
			row(18, 2.0, 2, 1.0, 30, 999, 0.8, 8),
			row(21, 1.9, 2, 1.05, 31, 999, 0.85, 9),
			row(24, 1.9, 2, 1.1, 32, 999, 0.9, 9),
			row(24, 1.8, 3, 1.1, 32, 999, 0.9, 9),
			row(28, 1.8, 3, 1.15, 33, 999, 0.95, 10),
			row(31, 1.7, 3, 1.15, 34, 999, 1.0, 10),
			row(34, 1.7, 3, 1.2, 35, 999, 1.0, 10),
			row(37, 1.6, 3, 1.25, 36, 999, 1.05, 11),
			row(41, 1.55, 3, 1.3, 37, 999, 1.1, 11),
			row(45, 1.5, 4, 1.35, 38, 999, 1.1, 12),
		},
		Evolution = {
			Id = "Worldbreaker",
			Name = "Worldbreaker",
			Passive = "Stoneskin",
			Description = "Five fissures split the ground all around you.",
			Stats = row(64, 1.3, 5, 1.6, 42, 999, 1.25, 14),
			Ring = true, -- fissures spread evenly all around instead of a fan
		},
	},

	-- STARFALL: meteors fall on the densest crowds near you after a short warning ring, then
	-- leave a burning crater for `duration` s. Molten Core: craters are wider.
	Starfall = {
		Id = "Starfall",
		Element = "Fire", -- SynergyData (Elemental Trinity, Ember Field)
		Name = "Starfall",
		Description = "Calls meteors down on the thickest crowds.",
		Color = Color3.fromRGB(240, 140, 60),
		Behavior = "Meteor",
		Area = true,
		AmountLabel = "Meteors",
		DurationLabel = "Crater time",
		Perks = { { Level = 7, Id = "Molten", Name = "Molten Core", Text = "Craters burn 50% wider." } },
		-- crater: CraterShare of the damage every CraterTick s
		Params = { BlastRadius = 4.5, FallTime = 0.7, Range = 36, CraterShare = 0.08, CraterTick = 0.5, CraterScale = 0.8, MoltenScale = 1.5, Visual = 43, EvoVisual = 44 },
		Levels = {
			row(30, 3.6, 1, 1.0, 0, 999, 1.5, 10),
			row(33, 3.6, 1, 1.0, 0, 999, 1.5, 10),
			row(33, 3.6, 2, 1.0, 0, 999, 1.5, 10),
			row(36, 3.4, 2, 1.05, 0, 999, 1.75, 11),
			row(39, 3.4, 2, 1.1, 0, 999, 1.75, 11),
			row(42, 3.2, 2, 1.15, 0, 999, 2.0, 12),
			row(45, 3.1, 2, 1.15, 0, 999, 2.0, 12),
			row(45, 3.0, 3, 1.2, 0, 999, 2.0, 12),
			row(49, 2.9, 3, 1.2, 0, 999, 2.25, 13),
			row(52, 2.8, 3, 1.25, 0, 999, 2.25, 13),
			row(56, 2.7, 3, 1.3, 0, 999, 2.5, 14),
			row(60, 2.6, 3, 1.35, 0, 999, 2.5, 14),
		},
		Evolution = {
			Id = "Cataclysm",
			Name = "Cataclysm",
			Passive = "EmberOil",
			Description = "A rain of five great meteors that leave long-burning craters.",
			Stats = row(80, 2.3, 5, 1.6, 0, 999, 3.0, 16),
		},
	},

	-- SLING: a stone at the nearest enemy that bounces on to the next one (pierce = enemies
	-- hit), a little harder each bounce. Stagger: hits stop enemies for a moment.
	Sling = {
		Id = "Sling",
		Name = "Sling",
		Description = "Hurls stones that bounce from enemy to enemy.",
		Color = Color3.fromRGB(160, 150, 130),
		Behavior = "Sling",
		AmountLabel = "Stones",
		DurationLabel = "Range",
		Perks = { { Level = 6, Id = "Stagger", Name = "Stagger", Text = "Stones stop the enemies they hit for a moment." } },
		Params = { Radius = 0.8, BounceGain = 0.1, EvoBounceGain = 0.2, StaggerSlow = 0.15, StaggerSeconds = 0.4, Visual = 45, EvoVisual = 46 },
		Levels = {
			row(9, 1.30, 1, 1.0, 55, 3, 0.6, 5),
			row(11, 1.30, 1, 1.0, 55, 3, 0.6, 5),
			row(11, 1.25, 2, 1.0, 57, 3, 0.6, 5),
			row(12, 1.20, 2, 1.0, 58, 4, 0.6, 6),
			row(13, 1.15, 2, 1.05, 60, 4, 0.65, 6),
			row(14, 1.10, 2, 1.05, 60, 4, 0.65, 6),
			row(14, 1.05, 3, 1.1, 62, 4, 0.65, 6),
			row(16, 1.00, 3, 1.1, 62, 5, 0.7, 7),
			row(17, 1.00, 3, 1.15, 64, 5, 0.7, 7),
			row(18, 0.95, 3, 1.15, 65, 5, 0.7, 7),
			row(19, 0.95, 3, 1.2, 66, 6, 0.75, 8),
			row(20, 0.90, 3, 1.2, 68, 6, 0.75, 8),
		},
		Evolution = {
			Id = "Giantfeller",
			Name = "Giantfeller",
			Passive = "GiantsBane",
			Description = "Four heavy stones that hit 20% harder with every bounce.",
			Stats = row(28, 0.75, 4, 1.4, 75, 8, 0.8, 10),
		},
	},

	-- PLAGUE CENSER: a sickly cloud opens on an enemy and drifts after the crowd, hurting
	-- everything inside every Tick s. Choking Fumes: enemies inside are slowed.
	PlagueCenser = {
		Id = "PlagueCenser",
		Name = "Plague Censer",
		Description = "Swings out a poison cloud that drifts after enemies.",
		Color = Color3.fromRGB(140, 180, 80),
		Behavior = "Cloud",
		Area = true,
		AmountLabel = "Clouds",
		DurationLabel = "Cloud time",
		Perks = { { Level = 6, Id = "Choking", Name = "Choking Fumes", Text = "Enemies inside a cloud move 30% slower." } },
		-- speed = drift speed (studs/s); Pestilence: PoisonShare damage per Tick for PoisonSeconds after leaving
		Params = { Radius = 4, Tick = 0.5, Range = 30, ChokeSlow = 0.7, PoisonSeconds = 2, PoisonShare = 0.5, Visual = 47, EvoVisual = 48 },
		Levels = {
			row(3, 4.5, 1, 1.0, 4, 999, 4.0, 0),
			row(4, 4.5, 1, 1.0, 4, 999, 4.0, 0),
			row(4, 4.5, 1, 1.1, 4, 999, 4.5, 0),
			row(5, 4.3, 1, 1.1, 4.5, 999, 4.5, 0),
			row(5, 4.3, 2, 1.1, 4.5, 999, 4.5, 0),
			row(6, 4.1, 2, 1.15, 4.5, 999, 4.75, 0),
			row(7, 4.0, 2, 1.2, 5, 999, 5.0, 0),
			row(7, 3.9, 2, 1.25, 5, 999, 5.0, 0),
			row(8, 3.8, 2, 1.3, 5.5, 999, 5.0, 0),
			row(9, 3.7, 3, 1.3, 5.5, 999, 5.25, 0),
			row(10, 3.6, 3, 1.35, 6, 999, 5.5, 0),
			row(11, 3.5, 3, 1.4, 6, 999, 5.5, 0),
		},
		Evolution = {
			Id = "Pestilence",
			Name = "Pestilence",
			Passive = "Candle",
			Description = "Four great clouds whose poison keeps hurting after enemies escape.",
			Stats = row(15, 3.0, 4, 1.8, 7, 999, 7.0, 0),
			Poison = true,
		},
	},

	-- SAWBLADE: a spinning blade rolls at an enemy and slows down to grind through crowds
	-- (each enemy is bitten every Rehit s). Rebound: at the end it spins back at an enemy.
	Sawblade = {
		Id = "Sawblade",
		Name = "Sawblade",
		Description = "Rolls a buzzing saw that grinds slowly through crowds.",
		Color = Color3.fromRGB(190, 195, 205),
		Behavior = "Saw",
		AmountLabel = "Saws",
		DurationLabel = "Spin time",
		Perks = { { Level = 7, Id = "Rebound", Name = "Rebound", Text = "A saw at the end of its run spins back at the nearest enemy." } },
		Params = { Radius = 1.5, Rehit = 0.2, GrindSlow = 0.3, Range = 40, ReboundRange = 25, Visual = 49, EvoVisual = 50 },
		Levels = {
			row(4, 1.6, 1, 1.0, 30, 999, 1.2, 2),
			row(5, 1.6, 1, 1.0, 30, 999, 1.2, 2),
			row(5, 1.6, 2, 1.0, 30, 999, 1.2, 2),
			row(6, 1.5, 2, 1.05, 31, 999, 1.25, 2),
			row(6, 1.45, 2, 1.1, 32, 999, 1.3, 2),
			row(7, 1.4, 2, 1.1, 32, 999, 1.3, 2.5),
			row(7, 1.35, 2, 1.15, 33, 999, 1.35, 2.5),
			row(7, 1.3, 3, 1.15, 34, 999, 1.4, 2.5),
			row(8, 1.25, 3, 1.2, 34, 999, 1.4, 3),
			row(8, 1.2, 3, 1.25, 35, 999, 1.45, 3),
			row(9, 1.15, 3, 1.25, 36, 999, 1.5, 3),
			row(9, 1.15, 3, 1.3, 37, 999, 1.5, 3),
		},
		Evolution = {
			Id = "Ruinwheel",
			Name = "Ruinwheel",
			Passive = "Thornhide",
			Description = "Four great saws that rebound three times.",
			Stats = row(12, 0.9, 4, 1.6, 40, 999, 1.8, 3),
			Rebounds = 3,
		},
	},

	-- VINE SNARE: thorny vines burst up under enemies and root everything in the ring (not
	-- bosses) while hurting it every Tick s. Thornbloom: enemies that die there burst.
	VineSnare = {
		Id = "VineSnare",
		Name = "Vine Snare",
		Description = "Thorny vines root enemies to the spot and hurt them.",
		Color = Color3.fromRGB(110, 160, 80),
		Behavior = "Vines",
		Area = true,
		AmountLabel = "Snares",
		DurationLabel = "Root time",
		Perks = { { Level = 8, Id = "Thornbloom", Name = "Thornbloom", Text = "Enemies that die in a snare burst into thorns (half damage)." } },
		Params = { Radius = 2.6, Tick = 0.5, Range = 32, RootSlow = 0.1, ThornRadius = 3.5, ThornShare = 0.5, ThornsPerTick = 2, PullShare = 0.4, Visual = 51, EvoVisual = 52 },
		Levels = {
			row(4, 3.5, 1, 1.0, 0, 999, 2.0, 0),
			row(5, 3.5, 1, 1.0, 0, 999, 2.0, 0),
			row(5, 3.5, 2, 1.0, 0, 999, 2.0, 0),
			row(6, 3.4, 2, 1.1, 0, 999, 2.25, 0),
			row(6, 3.3, 2, 1.1, 0, 999, 2.5, 0),
			row(7, 3.2, 2, 1.15, 0, 999, 2.5, 0),
			row(7, 3.1, 3, 1.15, 0, 999, 2.5, 0),
			row(8, 3.0, 3, 1.2, 0, 999, 2.75, 0),
			row(9, 3.0, 3, 1.25, 0, 999, 2.75, 0),
			row(9, 2.9, 3, 1.3, 0, 999, 3.0, 0),
			row(10, 2.85, 3, 1.35, 0, 999, 3.0, 0),
			row(11, 2.8, 4, 1.4, 0, 999, 3.0, 0),
		},
		Evolution = {
			Id = "Strangleroot",
			Name = "Strangleroot",
			Passive = "Growth",
			Description = "Five wide snares that drag nearby enemies into the thorns.",
			Stats = row(15, 2.4, 5, 1.8, 0, 999, 3.5, 0),
			Pull = true,
		},
	},

	-- WAR HORN: a shockwave cone toward the nearest enemy: damage, a big push and a daze
	-- (slow, not bosses) for `duration` s. More blasts point around you. Echo: a second blast.
	WarHorn = {
		Id = "WarHorn",
		Name = "War Horn",
		Description = "A booming blast that hurls enemies back and dazes them.",
		Color = Color3.fromRGB(210, 170, 90),
		Behavior = "Horn",
		Area = true,
		AmountLabel = "Blasts",
		DurationLabel = "Daze time",
		Perks = { { Level = 7, Id = "Echo", Name = "Echo", Text = "A second, softer blast follows each one (60% damage)." } },
		-- Range studs at area 1, HalfAngle degrees each side of the aim
		Params = { Range = 9, HalfAngle = 55, DazeSlow = 0.5, EchoDelay = 0.35, EchoShare = 0.6 },
		Levels = {
			row(12, 2.4, 1, 1.0, 0, 999, 0.8, 24),
			row(15, 2.4, 1, 1.0, 0, 999, 0.8, 24),
			row(15, 2.3, 1, 1.1, 0, 999, 0.9, 26),
			row(18, 2.3, 1, 1.1, 0, 999, 1.0, 26),
			row(18, 2.2, 2, 1.1, 0, 999, 1.0, 26),
			row(21, 2.1, 2, 1.15, 0, 999, 1.0, 28),
			row(21, 2.0, 2, 1.2, 0, 999, 1.1, 28),
			row(24, 2.0, 2, 1.2, 0, 999, 1.2, 30),
			row(26, 1.9, 2, 1.25, 0, 999, 1.2, 30),
			row(28, 1.85, 2, 1.3, 0, 999, 1.3, 32),
			row(30, 1.8, 2, 1.35, 0, 999, 1.4, 32),
			row(33, 1.7, 3, 1.4, 0, 999, 1.5, 34),
		},
		Evolution = {
			Id = "TitansRoar",
			Name = "Titan's Roar",
			Passive = "Lionheart",
			Description = "A roar that blasts the whole ring around you.",
			Stats = row(48, 1.5, 3, 1.7, 0, 999, 2.0, 38),
			Roar = true, -- one full-circle blast (per amount: a little later, a little wider)
		},
	},

	-- SPIRIT WISPS: wisps float around you; every cooldown each one darts at an enemy, hits
	-- `pierce` enemies (or runs out of `duration`) and floats back. Glow: resting wisps sting.
	SpiritWisps = {
		Id = "SpiritWisps",
		Name = "Spirit Wisps",
		Description = "Wisps circle you and dart out at enemies, then come back.",
		Color = Color3.fromRGB(150, 220, 230),
		Behavior = "Wisps",
		AmountLabel = "Wisps",
		DurationLabel = "Dart time",
		Perks = { { Level = 6, Id = "Glow", Name = "Glow", Text = "Resting wisps sting enemies that touch them (30% damage)." } },
		Params = { Radius = 0.9, OrbitRadius = 3.2, OrbitSpin = 2.4, Range = 34, Retarget = 14, GlowShare = 0.3, EvoGlowShare = 0.6, GlowEvery = 0.6, MaxAmount = 8, Visual = 53, EvoVisual = 54 },
		Levels = {
			row(8, 1.4, 1, 1.0, 45, 1, 1.0, 3),
			row(8, 1.4, 2, 1.0, 45, 1, 1.0, 3),
			row(10, 1.35, 2, 1.0, 46, 1, 1.0, 3),
			row(10, 1.3, 2, 1.05, 47, 2, 1.0, 3),
			row(11, 1.25, 3, 1.05, 48, 2, 1.0, 3),
			row(12, 1.2, 3, 1.1, 48, 2, 1.05, 3.5),
			row(13, 1.15, 3, 1.1, 50, 2, 1.05, 3.5),
			row(13, 1.1, 4, 1.15, 50, 2, 1.1, 3.5),
			row(14, 1.05, 4, 1.15, 52, 2, 1.1, 4),
			row(15, 1.0, 4, 1.2, 52, 3, 1.15, 4),
			row(15, 0.975, 4, 1.2, 54, 3, 1.2, 4),
			row(16, 0.95, 4, 1.25, 55, 3, 1.2, 4),
		},
		Evolution = {
			Id = "WispChoir",
			Name = "Wisp Choir",
			Passive = "Luck",
			Description = "Five bright wisps that dart through four enemies and sting hard at rest.",
			Stats = row(22, 0.75, 5, 1.4, 60, 4, 1.4, 5),
		},
	},

	-- VORTEX: a swirling rift opens on the densest crowd, dragging enemies to its centre and
	-- hurting them every Tick s. Implosion: it collapses for a big hit when it ends.
	Vortex = {
		Id = "Vortex",
		Name = "Vortex",
		Description = "Opens a swirling rift that drags enemies together.",
		Color = Color3.fromRGB(130, 100, 210),
		Behavior = "Vortex",
		Area = true,
		AmountLabel = "Vortices",
		DurationLabel = "Rift time",
		Perks = { { Level = 8, Id = "Implosion", Name = "Implosion", Text = "The rift collapses at the end for 4x its damage." } },
		-- Pull = most studs an enemy is dragged per tick
		Params = { Radius = 5.5, Tick = 0.4, Range = 30, Pull = 3.5, EvoPull = 5.5, ImplodeMult = 4, EvoImplodeMult = 8, MaxAmount = 4, Visual = 55, EvoVisual = 56 },
		Levels = {
			row(2.5, 5.0, 1, 1.0, 0, 999, 2.5, 0),
			row(3, 5.0, 1, 1.0, 0, 999, 2.5, 0),
			row(3, 4.8, 1, 1.1, 0, 999, 2.75, 0),
			row(3.5, 4.6, 1, 1.1, 0, 999, 2.75, 0),
			row(4, 4.6, 1, 1.15, 0, 999, 3.0, 0),
			row(4, 4.4, 2, 1.15, 0, 999, 3.0, 0),
			row(4.5, 4.3, 2, 1.2, 0, 999, 3.0, 0),
			row(5, 4.2, 2, 1.2, 0, 999, 3.25, 0),
			row(5.5, 4.1, 2, 1.25, 0, 999, 3.25, 0),
			row(6, 4.0, 2, 1.3, 0, 999, 3.5, 0),
			row(6.5, 3.9, 2, 1.35, 0, 999, 3.5, 0),
			row(7, 3.8, 3, 1.4, 0, 999, 3.5, 0),
		},
		Evolution = {
			Id = "Singularity",
			Name = "Singularity",
			Passive = "Vacuum",
			Description = "Three deep rifts that drag harder and collapse for 8x damage.",
			Stats = row(10, 3.2, 3, 1.8, 0, 999, 4.0, 0),
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
	-- the thrust has a fixed out-and-back time: no speed / duration
	Spear = { damage = true, cooldown = true, amount = true, area = true, pierce = true, knockback = true },
	Crossbow = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
	-- duration = how long enemies stay slowed
	Nova = { damage = true, cooldown = true, area = true, duration = true, knockback = true },
	-- cooldown = how often a flame patch is left, duration = how long it burns
	FireTrail = { damage = true, cooldown = true, area = true, duration = true },
	Totem = { damage = true, cooldown = true, amount = true, area = true, duration = true, knockback = true, heal = true },
	-- reach = speed x duration; the chain hits everything on its line (no pierce)
	Hook = { damage = true, cooldown = true, amount = true, area = true, speed = true, duration = true },
	Turret = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
	Soul = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
	-- armoury batch. Shields: cooldown = re-hit time, speed = orbit speed (they never end)
	Shields = { damage = true, cooldown = true, amount = true, area = true, speed = true, knockback = true },
	-- fissure reach = speed x duration; every enemy on the line is hit once (no pierce)
	Quake = { damage = true, cooldown = true, amount = true, area = true, speed = true, duration = true, knockback = true },
	-- duration = how long the crater burns
	Meteor = { damage = true, cooldown = true, amount = true, area = true, duration = true, knockback = true },
	-- pierce = enemies one stone hits (bounces + 1); duration = flight time per bounce
	Sling = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
	-- damage per tick; speed = drift speed
	Cloud = { damage = true, cooldown = true, amount = true, area = true, speed = true, duration = true },
	Saw = { damage = true, cooldown = true, amount = true, area = true, speed = true, duration = true, knockback = true },
	-- damage per tick; duration = how long the snare roots
	Vines = { damage = true, cooldown = true, amount = true, area = true, duration = true },
	-- duration = daze time
	Horn = { damage = true, cooldown = true, amount = true, area = true, duration = true, knockback = true },
	Wisps = { damage = true, cooldown = true, amount = true, area = true, speed = true, pierce = true, duration = true, knockback = true },
	-- damage per tick; the pull strength is fixed (Params)
	Vortex = { damage = true, cooldown = true, amount = true, area = true, duration = true },
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
	local cap = def.Params and def.Params.MaxAmount
	if stat == "amount" and cap and row and row.amount >= cap then
		return false -- already at its turret / totem cap
	end
	return true
end

-- Amount after bonuses, never past the weapon's MaxAmount (turrets, totems).
function WeaponData.CapAmount(weaponId: string, amount: number): number
	local def = WeaponData.Weapons[weaponId]
	local cap = def and def.Params and def.Params.MaxAmount
	return cap and math.min(amount, cap) or amount
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
	elseif stat == "cooldown" then
		return def.CooldownLabel or "Cooldown"
	end
	return WeaponData.StatLabels[stat]
end

local DIFF_ORDER = { "damage", "heal", "amount", "cooldown", "area", "pierce", "speed", "duration", "knockback" }

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
		for _, stat in ipairs({ "damage", "heal", "amount", "cooldown" }) do
			if use[stat] and r[stat] then
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
		local used = use[stat] and (not evolve or WeaponData.UsesStat(weaponId, stat, true) or (stat == "pierce" and after.pierce >= 999) or (stat == "amount" and after.amount ~= before.amount))
		if used and after[stat] and before[stat] and math.abs(after[stat] - before[stat]) > 1e-6 then
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

-- Stat row `r` with mastery rank `rank` applied (a new table; rank 0 / nil = a copy).
function WeaponData.MasteryBonus(weaponId: string, r, rank: number?)
	local m = WeaponData.Mastery[math.clamp(rank or 0, 0, WeaponData.MaxMastery)]
	local out = table.clone(r)
	if not m then
		return out
	end
	out.damage = r.damage * (1 + m.damage)
	out.cooldown = r.cooldown * (1 - m.cooldown)
	out.area = r.area * (1 + m.area)
	out.amount = WeaponData.CapAmount(weaponId, r.amount + m.amount)
	return out
end

-- Card lines for a weapon's mastery going from rank `fromRank` to `toRank` (same shape as
-- CardLines; the base row is the evolution row or the max-level row).
function WeaponData.MasteryLines(weaponId: string, fromRank: number, toRank: number, evolved: boolean?): { { [string]: string } }
	local def = WeaponData.Weapons[weaponId]
	local out = {}
	local base = WeaponData.GetStats(weaponId, WeaponData.MaxLevel, evolved)
	if not def or not base then
		return out
	end
	local before = WeaponData.MasteryBonus(weaponId, base, fromRank)
	local after = WeaponData.MasteryBonus(weaponId, base, toRank)
	for _, stat in ipairs({ "damage", "amount", "cooldown", "area" }) do
		if WeaponData.UsesStat(weaponId, stat, evolved) and math.abs(after[stat] - before[stat]) > 1e-6 then
			local from, to = fmt(stat, before[stat]), fmt(stat, after[stat])
			if from ~= to then
				table.insert(out, { Label = labelOf(def, stat), From = from, To = to })
			end
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

-- One card line as a short gain: {Label, From, To} → "+10 damage" / "-0.1s cooldown" /
-- "all pierce"; a perk line → "New: Riposte"; nil when nothing changed.
function WeaponData.DeltaText(line: { [string]: string }): string?
	local label = tostring(line.Label or "")
	-- "Damage" → "damage" but "HP regen" / "XP gain" keep their acronym
	local second = string.sub(label, 2, 2)
	if second ~= "" and second == string.lower(second) then
		label = string.lower(string.sub(label, 1, 1)) .. string.sub(label, 2)
	end
	if line.Text then
		local perk = string.match(tostring(line.Text), "^([^:]+):") or tostring(line.Text)
		return "New: " .. perk
	end
	local to = tostring(line.To or "")
	if not line.From then
		return string.format("%s %s", to, label)
	end
	local a = tonumber(string.match(tostring(line.From), "^[+-]?%d+%.?%d*"))
	local b, unit = string.match(to, "^([+-]?%d+%.?%d*)(.*)$")
	local bn = tonumber(b)
	if not a or not bn then
		return string.format("%s %s", to, label) -- "all pierce"
	end
	local d = bn - a
	if math.abs(d) < 1e-6 then
		return nil
	end
	local num = math.abs(d - math.floor(d + 0.5)) < 1e-6 and tostring(math.floor(d + 0.5)) or string.format("%.2f", d):gsub("0+$", ""):gsub("%.$", "")
	if math.abs(d) == 1 and string.sub(label, -1) == "s" and not string.find(label, " ") then
		label = string.sub(label, 1, -2) -- "+1 arrow"
	end
	return string.format("%s%s%s %s", d > 0 and "+" or "", num, unit or "", label) -- num carries its own minus
end

-- "+10 damage, +1 arrow, -0.1s cooldown": one short line of what a card gives now (at
-- most three gains), or `fallback` when the lines carry no change.
function WeaponData.SummaryText(lines: { { [string]: string } }?, fallback: string?): string
	local parts = {}
	for _, line in ipairs(lines or {}) do
		local t = WeaponData.DeltaText(line)
		if t then
			table.insert(parts, t)
		end
		if #parts >= 3 then
			break
		end
	end
	if #parts == 0 then
		return fallback or ""
	end
	return table.concat(parts, ", ")
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
