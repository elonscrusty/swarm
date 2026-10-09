--!strict
--[[
	SwarmV2/Run/ClassRoster.lua  (ReplicatedStorage.SwarmV2.Run.ClassRoster)
	OWNER: gameplay track (Chat 2), stream C. The twelve playable classes as CharacterData entries
	(continuation brief "Twelve approved classes"; docs/redesign/DECISIONS.md C1-C3).

	ClassRoster.Register(CharacterData, MetaUpgradeData) inserts the twelve class ids
	(RunConfig.Classes.Order) into CharacterData.Characters (only ids that are missing; an existing
	entry is never overwritten), puts them first in CharacterData.Order, takes the 11 old heroes out
	of Order (their Characters entries stay, so saves keep working: a hidden hero is never
	selectable or listed, never deleted) and makes `ruckus` the default hero (free for every
	account). It also gives each class a hero-mastery Signature upgrade, an Ultimate and a second
	skill. Safe to call more than once. The server calls it from ClassRegistry at RunBoot; the
	client may call the same function so its own CharacterData copy knows the ids.

	Entry fields beyond the old hero shape:
	  MeshName    the class model (category "Classes", MeshCatalog; stream A)
	  Class       true (a SwarmV2 class, not an old hero)
	  Goal        { Stat, Need, Text, Any? }: the pack's earnable unlock goal (DECISIONS C2 / C3).
	              The lobby track owns the grant (ClassOwnership.RefreshEarned); this copy exists
	              because ClassCatalog had no goal table yet (same field name and shape).
	  Unlock      { Goal = Goal } on the 8 goal-only classes: the old gold buy path
	              (GoldSystem BuyCharacter) refuses any entry with Unlock, so they have no price.
	  CritBase    base crit chance (Swolverine 0; StatSheet reads it)
	  KitName     the class passive's name (HUD attribute ClassKit)

	Numbers (prices, HP / speed modifiers, goals) come from RunConfig.Classes.Roster.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunConfig = require(script.Parent.RunConfig)
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared:WaitForChild("Palette"))
local Config = require(Shared:WaitForChild("Config"))

local ClassRoster = {}

ClassRoster.LegacyIds = {
	"Knight", "Mage", "Rogue", "Priest", "Ranger", "Alchemist",
	"Engineer", "Necromancer", "Archer", "Bard", "Golem",
}

local function colors(t: { [string]: Color3 }): { [string]: Color3 }
	return t
end

local PINK = Color3.fromRGB(226, 126, 170)

-- Presentation + identity of each class (numbers are in RunConfig.Classes.Roster).
local Defs: { [string]: { [string]: any } } = {
	ruckus = {
		Name = "Ruckus",
		MeshName = "Ruckus",
		KitName = "JunkCollector",
		Role = "Scrap raider",
		Description = "Mischievous raccoon. Starts with Scrap Shot: bouncing scrap.",
		BonusText = "Normal HP",
		Trait = { Name = "Junk Collector", Text = "Every 5 chest or item rewards turn your next Scrap Shot into a 3-scrap barrage. Dashing drops 2 exploding cans." },
		Strengths = "Ricochets and exploration fuel damage.",
		Tradeoff = "Needs rewards to charge the barrage.",
		SignatureName = "Scavenger",
		SignatureFormat = "+%d%% pickup radius",
		Hat = "Beanie",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.steel_400, MetalDark = Palette.steel_600, Cloth = Palette.slate_500, Cloth2 = Palette.slate_700,
			Accent = Palette.crimson_500, AccentDark = Palette.crimson_700, Gold = Palette.gold_500,
			Hat = Palette.crimson_600, HatAccent = Palette.ivory_200, Skin = Palette.slate_300,
		}),
	},
	toastmaster = {
		Name = "Toastmaster",
		MeshName = "Toastmaster",
		KitName = "Overheat",
		Role = "Ricochet gunner",
		Description = "Angry walking toaster. Starts with Toast Toss: ricocheting toast.",
		BonusText = "90% HP",
		Trait = { Name = "Overheat", Text = "3 direct toast hits on one enemy within 5 s scorch it. Spring jumps reach 12 studs and land with a blast." },
		Strengths = "Ricochets and heat melt targets; a high spring jump.",
		Tradeoff = "Fragile under contact pressure (90% HP).",
		SignatureName = "Sturdy Casing",
		SignatureFormat = "+%d%% max HP",
		Hat = "Tophat",
		Swatch = "Metal",
		Colors = colors({
			Metal = Palette.steel_300, MetalDark = Palette.steel_500, Cloth = Palette.sand_400, Cloth2 = Palette.slate_700,
			Accent = Palette.crimson_500, AccentDark = Palette.crimson_700, Gold = Palette.gold_500,
			Hat = Palette.slate_800, HatAccent = Palette.gold_400, Skin = Palette.ivory_300,
		}),
	},
	captain_croak = {
		Name = "Captain Croak",
		MeshName = "CaptainCroak",
		KitName = "BigSplash",
		Role = "Leaping bomber",
		Description = "Round frog explorer. Starts with Bubble Bomb: bursting bubbles.",
		BonusText = "Normal HP",
		Trait = { Name = "Big Splash", Text = "A leap that lands near an enemy makes your next bubble burst 30% harder (6 s). Leap replaces dash." },
		Strengths = "Traversal and burst damage.",
		Tradeoff = "Slower firing.",
		SignatureName = "Quick Study",
		SignatureFormat = "+%d%% XP",
		Hat = "Miner",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.leather_500, MetalDark = Palette.leather_700, Cloth = Palette.moss_500, Cloth2 = Palette.moss_700,
			Accent = Palette.amber_500, AccentDark = Palette.amber_300, Gold = Palette.gold_500,
			Hat = Palette.leather_600, HatAccent = Palette.amber_500, Skin = Palette.moss_300,
		}),
	},
	granny_boom = {
		Name = "Granny Boom",
		MeshName = "GrannyBoom",
		KitName = "TangledUp",
		Role = "Crowd bomber",
		Description = "Furious grandmother with a rocket walker. Starts with Yarn Bomb.",
		BonusText = "110% HP, slower walk",
		Trait = { Name = "Tangled Up", Text = "Yarn damage slows enemies 35% for 0.75 s. Rocket boost replaces dash." },
		Strengths = "Strong area control.",
		Tradeoff = "Less agile without the boost (walks at 20).",
		SignatureName = "Big Boom",
		SignatureFormat = "+%d%% area",
		Hat = "Hood",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.steel_400, MetalDark = Palette.steel_600, Cloth = PINK, Cloth2 = Palette.slate_600,
			Accent = Palette.ivory_200, AccentDark = Palette.ivory_300, Gold = Palette.gold_500,
			Hat = Color3.fromRGB(190, 190, 205), HatAccent = Palette.crimson_400, Skin = Palette.skin_400,
		}),
	},
	coach_crunch = {
		Name = "Coach Crunch",
		MeshName = "CoachCrunch",
		KitName = "WarmUp",
		Role = "Dodgeball coach",
		Description = "Loud gym teacher. Starts with Dodgeball: bouncing balls.",
		BonusText = "Normal HP",
		Trait = { Name = "Warm-Up", Text = "Run fast for 2 s to charge your next shoulder-tackle dash (stronger hit). Tackles stagger enemies." },
		Strengths = "Simple ranged clearing and aggressive mobility.",
		Tradeoff = "The strong tackle needs a run-up.",
		SignatureName = "Cardio",
		SignatureFormat = "+%d%% move speed",
		Hat = "Cap",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.ivory_200, MetalDark = Palette.ivory_400, Cloth = Palette.crimson_500, Cloth2 = Palette.slate_800,
			Accent = Palette.gold_400, AccentDark = Palette.gold_600, Gold = Palette.gold_500,
			Hat = Palette.crimson_600, HatAccent = Palette.ivory_200, Skin = Palette.skin_400,
		}),
	},
	doug_janitor = {
		Name = "Doug the Janitor",
		MeshName = "DougJanitor",
		KitName = "CleanRoute",
		Role = "Cleanup crew",
		Description = "Unimpressed cleanup professional. Starts with Mop Sweep.",
		BonusText = "110% HP, +4 pickup",
		Trait = { Name = "Clean Route", Text = "+4 studs pickup radius (your own shards). Dashing leaves a wet trail that slows enemies." },
		Strengths = "Collection and control.",
		Tradeoff = "Weaker burst damage.",
		SignatureName = "Deep Clean",
		SignatureFormat = "+%d%% pickup radius",
		Hat = "Cap",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.steel_400, MetalDark = Palette.steel_600, Cloth = Palette.ice_300, Cloth2 = Palette.slate_600,
			Accent = Palette.amber_500, AccentDark = Palette.amber_300, Gold = Palette.gold_500,
			Hat = Palette.slate_700, HatAccent = Palette.ivory_200, Skin = Palette.skin_400,
		}),
	},
	peter_parkour = {
		Name = "Peter Parkour",
		MeshName = "PeterParkour",
		KitName = "Stride",
		Role = "Free runner",
		Description = "Springy free runner. Starts with Returning Sneakers.",
		BonusText = "95% HP",
		Trait = { Name = "Stride", Text = "Keep running fast for 2 s: your next sneaker hits 30% harder. Once every 6 s a jump reaches 11 studs." },
		Strengths = "Route timing and returning hits.",
		Tradeoff = "Weaker when standing still (95% HP).",
		SignatureName = "Light Feet",
		SignatureFormat = "+%d%% move speed",
		Hat = "Beanie",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.steel_300, MetalDark = Palette.steel_500, Cloth = Palette.amber_500, Cloth2 = Palette.slate_700,
			Accent = Palette.ice_300, AccentDark = Palette.ice_500, Gold = Palette.gold_500,
			Hat = Palette.slate_800, HatAccent = Palette.amber_300, Skin = Palette.skin_400,
		}),
	},
	barry_plotter = {
		Name = "Barry Plotter",
		MeshName = "BarryPlotter",
		KitName = "GardenCompany",
		Role = "Gardener",
		Description = "Gardening wizard. Starts with Seed Slinger: seeds grow shooting plants.",
		BonusText = "Normal HP",
		Trait = { Name = "Garden Company", Text = "Your plants hit 15% harder while you stand within 12 studs. Dashing plants an extra seed (every 6 s)." },
		Strengths = "Location control.",
		Tradeoff = "Limited burst while moving.",
		SignatureName = "Green Thumb",
		SignatureFormat = "+%d%% area",
		Hat = "Hood",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.wood_500, MetalDark = Palette.wood_700, Cloth = Palette.moss_600, Cloth2 = Palette.leather_600,
			Accent = Palette.gold_400, AccentDark = Palette.gold_600, Gold = Palette.gold_500,
			Hat = Palette.moss_700, HatAccent = Palette.gold_300, Skin = Palette.skin_400,
		}),
	},
	rambozo = {
		Name = "Rambozo",
		MeshName = "Rambozo",
		KitName = "Punchline",
		Role = "Commando clown",
		Description = "Squat commando-clown. Starts with Confetti Minigun.",
		BonusText = "Normal HP",
		Trait = { Name = "Punchline", Text = "+10% crit chance against enemies above 70% HP. Dashing drops a balloon grenade." },
		Strengths = "Rapid ranged fire and silly explosives.",
		Tradeoff = "Spread lowers damage at long range.",
		SignatureName = "Big Finish",
		SignatureFormat = "+%d%% crit chance",
		Hat = "Bandana",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.steel_500, MetalDark = Palette.steel_700, Cloth = Palette.moss_600, Cloth2 = Palette.slate_700,
			Accent = Palette.crimson_500, AccentDark = Palette.crimson_700, Gold = Palette.gold_500,
			Hat = Palette.crimson_500, HatAccent = Palette.gold_300, Skin = Palette.ivory_200,
		}),
	},
	swolverine = {
		Name = "Swolverine",
		MeshName = "Swolverine",
		KitName = "Gains",
		Role = "Gym brawler",
		Description = "Excessively muscular scratcher. Starts with Protein Claws.",
		BonusText = "115% HP, no base crit",
		Trait = { Name = "Gains", Text = "Every 10 kills heal 1% max HP. After a dash you deal 15% more damage for 2 s." },
		Strengths = "Durable close combat.",
		Tradeoff = "No ranged attack of his own; no base crit chance.",
		SignatureName = "Bulk",
		SignatureFormat = "+%d%% max HP",
		Hat = "Beanie",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.steel_600, MetalDark = Palette.steel_800, Cloth = Palette.gold_400, Cloth2 = Palette.slate_800,
			Accent = Palette.slate_900, AccentDark = Palette.slate_950, Gold = Palette.gold_500,
			Hat = Palette.slate_800, HatAccent = Palette.gold_400, Skin = Palette.leather_500,
		}),
	},
	crash_cassidy = {
		Name = "Crash Cassidy",
		MeshName = "CrashCassidy",
		KitName = "Momentum",
		Role = "Derby bruiser",
		Description = "Roller-derby bruiser on huge skates. Starts with Ricochet Puck.",
		BonusText = "90% HP",
		Trait = { Name = "Momentum", Text = "Up to +15% weapon damage the faster you skate. Dashing body-checks enemies." },
		Strengths = "Fast routing and multi-target shots.",
		Tradeoff = "Vulnerable in collisions (90% HP).",
		SignatureName = "Skate Wax",
		SignatureFormat = "+%d%% move speed",
		Hat = "Helmet",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.ice_300, MetalDark = Palette.ice_500, Cloth = Palette.slate_600, Cloth2 = Palette.slate_800,
			Accent = Palette.crimson_400, AccentDark = Palette.crimson_600, Gold = Palette.gold_500,
			Hat = Color3.fromRGB(40, 170, 170), HatAccent = Palette.ivory_200, Skin = Palette.skin_400,
		}),
	},
	knuckles_mcgee = {
		Name = "Knuckles McGee",
		MeshName = "KnucklesMcGee",
		KitName = "HeavyHands",
		Role = "Boxer",
		Description = "Tiny confident boxer with enormous gloves. Starts with Glove Combo.",
		BonusText = "Normal HP",
		Trait = { Name = "Heavy Hands", Text = "Punches knock normal enemies 25% further. A dash that ends next to an enemy adds a combo charge." },
		Strengths = "Punch combos and close dodges.",
		Tradeoff = "The shortest range.",
		SignatureName = "Iron Chin",
		SignatureFormat = "+%d%% max HP",
		Hat = "Beanie",
		Swatch = "Cloth",
		Colors = colors({
			Metal = Palette.crimson_500, MetalDark = Palette.crimson_700, Cloth = Palette.slate_700, Cloth2 = Palette.slate_900,
			Accent = Palette.gold_400, AccentDark = Palette.gold_600, Gold = Palette.gold_500,
			Hat = Palette.crimson_600, HatAccent = Palette.gold_300, Skin = Palette.skin_400,
		}),
	},
}
ClassRoster.Defs = Defs

-- HUD kit names (player attribute ClassKit) by class id.
ClassRoster.KitNames = {} :: { [string]: string }
for id, def in pairs(Defs) do
	ClassRoster.KitNames[id] = def.KitName
end

local SIGNATURE_LEVELS = 5

--[[
	The ultimate and the second (mastery-unlocked) skill of each class, built from the existing
	effects (CharacterData.Ultimates / SecondSkills shape; the Look names are Ultimate.lua's:
	Quake, Stars, Blades, Nova, Arrows, Fire, Sparks, Souls). The first four are unchanged; the
	8 newer classes reuse the same generic effects with their own names (no new mechanics).
]]
local Ultimates: { [string]: { [string]: any } } = {
	ruckus = { Name = "Trash Avalanche", Text = "Tips the can: a shockwave of junk hurls back everything near you, and you take no damage for 1 s.", Damage = 1.0, Radius = 0.9, Look = "Quake", Color = Palette.steel_300, Guard = 1.0, Knock = 1.8 },
	toastmaster = { Name = "Burnt Offering", Text = "Every toaster coil flares: flames burst all around you.", Damage = 1.1, Radius = 1.0, Look = "Fire", Color = Palette.amber_500 },
	captain_croak = { Name = "Tidal Splash", Text = "A wave of bubbles bursts all around you and chills the survivors.", Damage = 1.0, Radius = 1.0, Look = "Stars", Color = Palette.ice_300, Slow = { Mult = 0.6, Seconds = 2 } },
	granny_boom = { Name = "Knitting Needles", Text = "A whirl of flying needles cuts every enemy around you.", Damage = 1.15, Radius = 0.85, Look = "Blades", Color = Color3.fromRGB(240, 120, 175) },
	coach_crunch = { Name = "Full-Court Press", Text = "A blast of the whistle: a wall of dodgeballs hurls back everything near you.", Damage = 1.0, Radius = 0.9, Look = "Quake", Color = Palette.crimson_400, Knock = 1.8 },
	doug_janitor = { Name = "Spill Cleanup", Text = "A wave of soapy water bursts all around you and slows the survivors.", Damage = 1.0, Radius = 1.0, Look = "Stars", Color = Palette.ice_100, Slow = { Mult = 0.6, Seconds = 2 } },
	peter_parkour = { Name = "Sneaker Storm", Text = "A whirl of flying sneakers hits every enemy around you.", Damage = 1.15, Radius = 0.85, Look = "Blades", Color = Palette.amber_500 },
	barry_plotter = { Name = "Overgrowth", Text = "Roots burst out of the ground around you and heal you and nearby allies for 10% max HP.", Damage = 0.9, Radius = 1.0, Look = "Nova", Color = Palette.moss_300, Heal = 0.10 },
	rambozo = { Name = "Grand Finale", Text = "Confetti cannons explode all around you.", Damage = 1.1, Radius = 1.0, Look = "Fire", Color = Color3.fromRGB(240, 110, 200) },
	swolverine = { Name = "Max Rep", Text = "Slams the floor: everything near you is hurled back, and you take no damage for 1 s.", Damage = 1.0, Radius = 0.9, Look = "Quake", Color = Palette.gold_400, Guard = 1.0, Knock = 2.0 },
	crash_cassidy = { Name = "Power Play", Text = "Pucks ricochet from you to every enemy close by.", Damage = 1.0, Radius = 1.0, Look = "Sparks", Color = Color3.fromRGB(40, 170, 170) },
	knuckles_mcgee = { Name = "Haymaker", Text = "One huge swing: a shockwave hurls back everything near you.", Damage = 1.15, Radius = 0.8, Look = "Quake", Color = Palette.crimson_500, Knock = 2.2 },
}
local SecondSkills: { [string]: { [string]: any } } = {
	ruckus = { Name = "Quick Paws", Text = "+5% move speed.", Bonus = { speed = 0.05 } },
	toastmaster = { Name = "Crisp Edge", Text = "+5% crit chance.", Bonus = { critChance = 0.05 } },
	captain_croak = { Name = "Long Legs", Text = "+20% pickup radius.", Bonus = { pickup = 0.20 } },
	granny_boom = { Name = "Tough Old Bird", Text = "+1 armor: every hit does 1 less damage.", Bonus = { armor = 1 } },
	coach_crunch = { Name = "Second Wind", Text = "+5% move speed.", Bonus = { speed = 0.05 } },
	doug_janitor = { Name = "Mop Up", Text = "+20% pickup radius.", Bonus = { pickup = 0.20 } },
	peter_parkour = { Name = "Fresh Laces", Text = "+5% move speed.", Bonus = { speed = 0.05 } },
	barry_plotter = { Name = "Compost Armor", Text = "+1 armor: every hit does 1 less damage.", Bonus = { armor = 1 } },
	rambozo = { Name = "Lucky Nose", Text = "+5% crit chance.", Bonus = { critChance = 0.05 } },
	swolverine = { Name = "Iron Grip", Text = "+1 armor: every hit does 1 less damage.", Bonus = { armor = 1 } },
	crash_cassidy = { Name = "Fresh Wheels", Text = "+5% move speed.", Bonus = { speed = 0.05 } },
	knuckles_mcgee = { Name = "Footwork", Text = "+5% move speed.", Bonus = { speed = 0.05 } },
}

-- The Hero Mastery signature's description: "+4% pickup radius per level (+20% at level 5)."
local function signatureText(format: string, base: number, per: number): string
	local top = string.format(format, base + per * SIGNATURE_LEVELS)
	if base == 0 then
		return string.format(format, per) .. " per level (" .. top .. " at level " .. SIGNATURE_LEVELS .. ")."
	end
	return string.format(format, base) .. " now; " .. top .. " at level " .. SIGNATURE_LEVELS .. "."
end

-- The CharacterData entry of class `id` (a new table), or nil when the class is unknown.
function ClassRoster.Entry(id: string): { [string]: any }?
	local def = Defs[id]
	local num = RunConfig.Classes.Roster[id]
	if not def or not num then
		return nil
	end
	local entry = table.clone(def)
	entry.Id = id
	entry.Class = true -- a SwarmV2 class (not one of the old heroes)
	entry.Cost = num.GoalOnly and 0 or (num.Cost or 0)
	entry.StartWeapon = num.StartWeapon
	local bonus = table.clone(num.Bonus or {})
	local base = Config.Player.BaseSpeed
	if type(num.BaseSpeed) == "number" and base > 0 then
		-- walking speed: Speed = BaseSpeed x (1 + speed bonus)
		bonus.speed = (bonus.speed or 0) + num.BaseSpeed / base - 1
	end
	entry.Bonus = bonus
	if type(num.CritBase) == "number" then
		entry.CritBase = num.CritBase
	end
	if num.Goal then
		entry.Goal = table.clone(num.Goal)
	end
	if num.GoalOnly then
		-- earned by the goal only: the old gold buy path refuses an entry with Unlock
		entry.Unlock = { Goal = entry.Goal }
	end
	return entry
end

function ClassRoster.Register(CharacterData: any, MetaUpgradeData: any?): { string }
	local added = {}
	local C = RunConfig.Classes
	for _, id in ipairs(C.Order) do
		local def = Defs[id]
		local num = C.Roster[id]
		if CharacterData.Characters[id] == nil and def and num then
			CharacterData.Characters[id] = ClassRoster.Entry(id)
			table.insert(added, id)
		end
		if CharacterData.Ultimates and CharacterData.Ultimates[id] == nil and Ultimates[id] then
			CharacterData.Ultimates[id] = table.clone(Ultimates[id])
		end
		if CharacterData.SecondSkills and CharacterData.SecondSkills[id] == nil and SecondSkills[id] then
			CharacterData.SecondSkills[id] = table.clone(SecondSkills[id])
		end
		local sigs = MetaUpgradeData and MetaUpgradeData.Signature
		if sigs and sigs[id] == nil and def and num and num.Signature then
			local s = num.Signature
			sigs[id] = {
				Id = "Signature",
				Hero = id,
				Name = def.SignatureName,
				Description = signatureText(def.SignatureFormat, s.Base, s.Per),
				MaxLevel = SIGNATURE_LEVELS,
				BaseCost = 500,
				CostGrowth = 1.6,
				Trait = { Base = s.Base, Per = s.Per },
				Effect = { Format = def.SignatureFormat },
				PerLevel = table.clone(s.PerLevel),
			}
		end
	end
	-- Order: the classes first (in class order), the old heroes hidden
	local order: { string } = CharacterData.Order
	for i = #order, 1, -1 do
		if table.find(ClassRoster.LegacyIds, order[i]) then
			table.remove(order, i)
		end
	end
	local at = 1
	for _, id in ipairs(C.Order) do
		if CharacterData.Characters[id] then
			local have = table.find(order, id)
			if have then
				table.remove(order, have)
			end
			table.insert(order, at, id)
			at += 1
		end
	end
	if CharacterData.Characters[C.Default] then
		CharacterData.Default = C.Default
	end
	return added
end

function ClassRoster.IsLegacy(id: any): boolean
	return type(id) == "string" and table.find(ClassRoster.LegacyIds, id) ~= nil
end

-- Is `id` one of the twelve classes?
function ClassRoster.IsClass(id: any): boolean
	return type(id) == "string" and Defs[id] ~= nil
end

return ClassRoster
