--[[
	CharacterData.lua
	The 8 playable characters and their cosmetic skins.

	Character fields:
	  Role          short tag shown on the character select card (descriptive only)
	  Cost          gold price in the lobby (0 = free)
	  Unlock        optional { Achievement = id }: unlocked by that achievement
	                (AchievementData), never sold for gold (Cost is ignored)
	  Trait         { Name, Text }: the passive trait (Bonus below, or SteadyAim)
	  Strengths     one line: what the character is good at
	  Tradeoff      one line: the real weakness (true to the numbers)
	  SteadyAim     optional { Delay, Damage, OtherDamage }: standing still Delay s gives
	                +Damage to the Longbow and +OtherDamage to every other weapon
	                until the hero moves (WeaponSystem; HUD buff chip)
	  AreaDamage    optional (Alchemist): +damage for weapons with WeaponData Area = true
	  DeployLife    optional (Engineer): +life for weapons with WeaponData Deployable = true
	  SoulHarvest   optional (Necromancer) { Chance, Damage, PerLevel, Gap }: a weapon kill
	                may release a homing soul (Damage + PerLevel x run level, x Might) that
	                seeks another enemy; at most one every Gap seconds (WeaponSystem)
	  StartWeapon   weapon id from WeaponData
	  Bonus         stat bonuses (same keys as PassiveData values) plus:
	                  damageTaken  -0.1 = take 10% less damage
	  Colors        colour SLOTS of the hero (the same slots as the Blender meshes,
	                blender/models/heroes.py; values come from the shared Palette):
	                  Metal      main armour (Rogue: leather armour)
	                  Cloth      main fabric        Cloth2  secondary fabric / legs
	                  Accent     cape, scarf, stole, mantle
	                  Gold       trims, guards, buckles
	                  Hat        headgear           HatAccent  plume, hat band, horns, jewels
	                  Skin       face and hands
	                MetalDark / AccentDark are optional: they default to a shade of Metal / Accent.
	  Swatch        the slot shown as the body colour on skin swatches
	  Hat           headgear shape (a "Hat_<Shape>" mesh, part-built ModelBuilder.HatShapes as
	                fallback). The character's own Hat is its built-in headgear.

	Skins only change colours and the hat shape (cosmetic). Each skin is sold as a
	gamepass; its id goes in Config.Monetization.SkinPasses[skin.Id]. "GoldTrim" is the
	Starter Pack skin and works on every character. A skin sets any of the slots above;
	the rest keep the character's own colours.
]]

local Palette = require(script.Parent.Palette)

local CharacterData = {}

CharacterData.Order = { "Knight", "Mage", "Rogue", "Priest", "Ranger", "Alchemist", "Engineer", "Necromancer" }
CharacterData.Default = "Knight"

-- Slots a skin recolours on the hero meshes (everything else on a mesh keeps its own colour).
local SKIN_SLOTS = { "Metal", "MetalDark", "Cloth", "Cloth2", "Accent", "AccentDark", "Gold", "Hat", "HatAccent" }

CharacterData.Characters = {
	Knight = {
		Id = "Knight",
		Name = "Knight",
		Role = "Tough tank", -- one-line tag on the character select card
		Description = "Sturdy fighter. Starts with the Whip. Takes 10% less damage.",
		Cost = 0,
		StartWeapon = "Whip",
		Bonus = { damageTaken = -0.10 },
		BonusText = "-10% damage taken",
		Trait = { Name = "Iron Skin", Text = "Takes 10% less damage from every hit." },
		Strengths = "Hard to kill; wide sword cuts clear the crowd in front and behind.",
		Tradeoff = "Short reach: the Whip only hits enemies within about 7 studs.",
		Colors = {
			Metal = Palette.steel_400,
			MetalDark = Palette.steel_600,
			Cloth = Palette.slate_600,
			Cloth2 = Palette.slate_700,
			Accent = Palette.crimson_500,
			AccentDark = Palette.crimson_700,
			Gold = Palette.gold_500,
			Hat = Palette.steel_400,
			HatAccent = Palette.crimson_500,
			Skin = Palette.skin_400,
		},
		Swatch = "Metal",
		Hat = "Helmet",
	},
	Mage = {
		Id = "Mage",
		Name = "Mage",
		Role = "Area caster", -- one-line tag on the character select card
		Description = "Arcane scholar. Starts with the Magic Orb. +10% area.",
		Cost = 500,
		StartWeapon = "MagicOrb",
		Bonus = { area = 0.10 },
		BonusText = "+10% area",
		Trait = { Name = "Arcane Reach", Text = "+10% area for every weapon." },
		Strengths = "Homing orbs find targets on their own; bigger area on every weapon.",
		Tradeoff = "Fragile: no defence bonus, and each orb stops at the first enemy early on.",
		Colors = {
			Metal = Palette.slate_500,
			MetalDark = Palette.slate_600,
			Cloth = Palette.slate_400,
			Cloth2 = Palette.slate_600,
			Accent = Palette.slate_700,
			AccentDark = Palette.slate_800,
			Gold = Palette.gold_500,
			Hat = Palette.slate_500,
			HatAccent = Palette.gold_500,
			Skin = Palette.skin_400,
		},
		Swatch = "Cloth",
		Hat = "Wizard",
	},
	Rogue = {
		Id = "Rogue",
		Name = "Rogue",
		Role = "Fast striker", -- one-line tag on the character select card
		Description = "Quick and sharp. Starts with Throwing Knives. +15% speed.",
		Cost = 1000,
		StartWeapon = "Knives",
		Bonus = { speed = 0.15 },
		BonusText = "+15% speed",
		Trait = { Name = "Fleet Foot", Text = "+15% move speed." },
		Strengths = "The fastest hero: outruns the swarm and reaches chests first.",
		Tradeoff = "Knives only fly the way you move: enemies behind you are safe.",
		Colors = {
			Metal = Palette.leather_500,
			MetalDark = Palette.leather_700,
			Cloth = Palette.moss_800,
			Cloth2 = Palette.stone_700,
			Accent = Palette.crimson_500,
			AccentDark = Palette.crimson_700,
			Gold = Palette.gold_600,
			Hat = Palette.moss_700,
			HatAccent = Palette.crimson_500,
			Skin = Palette.skin_500,
		},
		Swatch = "Cloth",
		Hat = "Hood",
	},
	Priest = {
		Id = "Priest",
		Name = "Priest",
		Role = "Holy survivor", -- one-line tag on the character select card
		Description = "Holy healer. Starts with the Garlic Aura. +20% max HP.",
		Cost = 1500,
		StartWeapon = "Garlic",
		Bonus = { maxHpMult = 0.20 },
		BonusText = "+20% HP",
		Trait = { Name = "Blessed", Text = "+20% max HP." },
		Strengths = "The most health; the aura hits everything around you at once.",
		Tradeoff = "No reach: the aura only hits enemies right next to you.",
		Colors = {
			Metal = Palette.ivory_200,
			MetalDark = Palette.ivory_400,
			Cloth = Palette.ivory_100,
			Cloth2 = Palette.ivory_300,
			Accent = Palette.gold_600,
			AccentDark = Palette.gold_700,
			Gold = Palette.gold_400,
			Hat = Palette.ivory_100,
			HatAccent = Palette.gold_500,
			Skin = Palette.skin_400,
		},
		Swatch = "Cloth",
		Hat = "Mitre",
	},
	-- Ranger: unlocked by the "Queen Slayer" achievement (AchievementData). Mesh "Ranger"
	-- (MeshCatalog) when uploaded, else the part-built fallback (ModelBuilder.ClassGear).
	Ranger = {
		Id = "Ranger",
		Name = "Ranger",
		Role = "Sharpshooter", -- one-line tag on the character select card
		Description = "Patient archer. Starts with the Longbow. Hits hardest standing still.",
		Cost = 0,
		Unlock = { Achievement = "QueenSlayer" },
		StartWeapon = "Longbow",
		Bonus = {},
		BonusText = "Steady Aim",
		Trait = { Name = "Steady Aim", Text = "Stand still for 0.8 s: +30% Longbow damage (+10% other weapons) until you move." },
		Strengths = "Longest reach: heavy arrows pierce whole lines of enemies.",
		Tradeoff = "Slow shots in one direction, and the bonus needs you to stand still.",
		SteadyAim = { Delay = 0.8, Damage = 0.30, OtherDamage = 0.10 },
		-- the same slots and colours as the "Ranger" mesh (blender heroes): leather jerkin,
		-- tan tunic, moss legs and hood, crimson scarf / fletching
		Colors = {
			Metal = Palette.leather_600,
			MetalDark = Palette.leather_700,
			Cloth = Palette.dirt_400,
			Cloth2 = Palette.moss_800,
			Accent = Palette.crimson_500,
			Gold = Palette.gold_500,
			Hat = Palette.moss_400,
			HatAccent = Palette.crimson_500,
			Skin = Palette.skin_500,
		},
		Swatch = "Hat",
		Hat = "Hood",
	},
	--[[
		The three heroes below are earned through achievements (never sold for gold). Their
		meshes ("Alchemist", "Engineer", "Necromancer") carry their own headgear; the
		part-built fallbacks are ModelBuilder.ClassGear + the hat shapes Goggles / Miner / Hood.
		Colours: the same slots and values as the meshes.
	]]
	-- Alchemist: unlocked by "Deep Delver" (reach stage 4).
	Alchemist = {
		Id = "Alchemist",
		Name = "Alchemist",
		Role = "Fire brewer", -- one-line tag on the character select card
		Description = "Brews trouble. Starts with the Fire Trail. Fire and area weapons hit 20% harder.",
		Cost = 0,
		Unlock = { Achievement = "DeepDelver" },
		StartWeapon = "FireTrail",
		Bonus = {},
		BonusText = "Volatile Mix",
		Trait = { Name = "Volatile Mix", Text = "+20% damage for burning and area weapons: Fire Trail, Frost Nova, Healing Totem, Holy Water, Garlic Aura, Lightning." },
		Strengths = "Kites the swarm through a wall of fire; every area weapon burns hotter.",
		Tradeoff = "Damage stays behind you: standing still or charging in leaves the flames idle.",
		AreaDamage = 0.20,
		Colors = {
			Metal = Palette.leather_500,
			Cloth = Palette.slate_600,
			Cloth2 = Palette.slate_800,
			Accent = Palette.crimson_600,
			Gold = Palette.gold_500,
			Hat = Palette.leather_600,
			HatAccent = Palette.gold_600,
			Skin = Palette.skin_400,
		},
		Swatch = "Cloth",
		Hat = "Goggles",
	},
	-- Engineer: unlocked by "Field Engineer" (3 optional events: Guarded Altars / Bargains).
	Engineer = {
		Id = "Engineer",
		Name = "Engineer",
		Role = "Turret builder", -- one-line tag on the character select card
		Description = "Builds what he needs. Starts with the Turret. Turrets and totems last 30% longer.",
		Cost = 0,
		Unlock = { Achievement = "FieldEngineer" },
		StartWeapon = "Turret",
		Bonus = {},
		BonusText = "Tinkerer",
		Trait = { Name = "Tinkerer", Text = "Turrets and Healing Totems last 30% longer." },
		Strengths = "Turrets hold a spot on their own: shooting while you loot, kite or revive.",
		Tradeoff = "Turrets stay where they were built: run off and you fight alone; a slow start.",
		DeployLife = 0.30,
		Colors = {
			Metal = Palette.steel_400,
			MetalDark = Palette.steel_600,
			Cloth = Palette.slate_500,
			Cloth2 = Palette.stone_600,
			Accent = Palette.crimson_500,
			Gold = Palette.gold_500,
			Hat = Palette.steel_400,
			HatAccent = Palette.gold_500,
			Skin = Palette.skin_500,
		},
		Swatch = "Cloth",
		Hat = "Miner",
	},
	-- Necromancer: unlocked by "Reaper" (defeat 500 enemies in one run).
	Necromancer = {
		Id = "Necromancer",
		Name = "Necromancer",
		Role = "Soul reaper", -- one-line tag on the character select card
		Description = "Commands the dead. Starts with the Soul Bolt. Kills can release hunting souls.",
		Cost = 0,
		Unlock = { Achievement = "Reaper" },
		StartWeapon = "SoulBolt",
		Bonus = {},
		BonusText = "Soul Harvest",
		Trait = { Name = "Soul Harvest", Text = "Every weapon kill has a 15% chance to release a soul that hunts another enemy." },
		Strengths = "Homing souls never miss, and big crowds feed a chain of new souls.",
		Tradeoff = "Slow souls and small hits: tough single targets (elites, the Queen) take long.",
		SoulHarvest = { Chance = 0.15, Damage = 10, PerLevel = 0.6, Gap = 0.12 },
		Colors = {
			Metal = Palette.ivory_300,
			Cloth = Palette.slate_800,
			Cloth2 = Palette.slate_700,
			Accent = Palette.crimson_600,
			AccentDark = Palette.crimson_800,
			Gold = Palette.gold_600,
			Hat = Palette.slate_900,
			HatAccent = Palette.crimson_600,
			Skin = Palette.stone_300,
		},
		Swatch = "Cloth",
		Hat = "Hood",
	},
}

--[[
	Skins. "Default" is implied for every character (its own Colors + Hat).
	Pass = "Skin" → owned through Config.Monetization.SkinPasses[Id]
	Pass = "StarterPack" → owned through the Starter Pack gamepass
]]
CharacterData.Skins = {
	-- Knight
	Knight_Crimson = {
		Id = "Knight_Crimson",
		Name = "Crimson Guard",
		Character = "Knight",
		Pass = "Skin",
		Colors = {
			Metal = Palette.crimson_600,
			MetalDark = Palette.crimson_800,
			Cloth = Palette.ivory_300,
			Cloth2 = Palette.stone_800,
			Accent = Palette.ivory_200,
			Gold = Palette.gold_400,
			Hat = Palette.crimson_600,
			HatAccent = Palette.ivory_100,
		},
		Hat = "Plume",
	},
	Knight_Shadow = {
		Id = "Knight_Shadow",
		Name = "Shadow Knight",
		Character = "Knight",
		Pass = "Skin",
		Colors = {
			Metal = Palette.steel_800,
			MetalDark = Palette.stone_900,
			Cloth = Palette.slate_800,
			Cloth2 = Palette.slate_900,
			Accent = Palette.crimson_600,
			Gold = Palette.crimson_400,
			Hat = Palette.steel_800,
			HatAccent = Palette.ivory_300,
		},
		Hat = "Horns",
	},
	Knight_Paladin = {
		Id = "Knight_Paladin",
		Name = "Paladin",
		Character = "Knight",
		Pass = "Skin",
		Colors = {
			Metal = Palette.steel_200,
			MetalDark = Palette.steel_400,
			Cloth = Palette.ivory_200,
			Cloth2 = Palette.slate_500,
			Accent = Palette.ivory_100,
			Gold = Palette.gold_400,
			Hat = Palette.steel_200,
			HatAccent = Palette.gold_400,
		},
		Hat = "Helmet",
	},
	-- Mage
	Mage_Frost = {
		Id = "Mage_Frost",
		Name = "Frost Mage",
		Character = "Mage",
		Pass = "Skin",
		Colors = {
			Metal = Palette.slate_300,
			Cloth = Palette.slate_200,
			Cloth2 = Palette.slate_400,
			Accent = Palette.ivory_100,
			Gold = Palette.steel_300,
			Hat = Palette.slate_300,
			HatAccent = Palette.ivory_100,
		},
		Hat = "Wizard",
	},
	Mage_Ember = {
		Id = "Mage_Ember",
		Name = "Ember Mage",
		Character = "Mage",
		Pass = "Skin",
		Colors = {
			Metal = Palette.crimson_700,
			Cloth = Palette.crimson_600,
			Cloth2 = Palette.crimson_800,
			Accent = Palette.gold_600,
			Gold = Palette.gold_400,
			Hat = Palette.crimson_700,
			HatAccent = Palette.gold_500,
		},
		Hat = "Tophat",
	},
	Mage_Void = {
		Id = "Mage_Void",
		Name = "Void Mage",
		Character = "Mage",
		Pass = "Skin",
		Colors = {
			Metal = Palette.slate_800,
			Cloth = Palette.slate_800,
			Cloth2 = Palette.slate_950,
			Accent = Palette.slate_600,
			Gold = Palette.slate_300,
			Hat = Palette.slate_900,
			HatAccent = Palette.slate_300,
		},
		Hat = "Hood",
	},
	-- Rogue
	Rogue_Forest = {
		Id = "Rogue_Forest",
		Name = "Woodland Rogue",
		Character = "Rogue",
		Pass = "Skin",
		Colors = {
			Metal = Palette.leather_500,
			Cloth = Palette.moss_600,
			Cloth2 = Palette.wood_700,
			Accent = Palette.gold_500,
			Gold = Palette.gold_500,
			Hat = Palette.moss_500,
			HatAccent = Palette.crimson_400,
		},
		Hat = "Cap",
	},
	Rogue_Pirate = {
		Id = "Rogue_Pirate",
		Name = "Pirate",
		Character = "Rogue",
		Pass = "Skin",
		Colors = {
			Metal = Palette.wood_600,
			Cloth = Palette.crimson_700,
			Cloth2 = Palette.slate_700,
			Accent = Palette.ivory_200,
			Gold = Palette.gold_400,
			Hat = Palette.crimson_500,
			HatAccent = Palette.ivory_100,
		},
		Hat = "Bandana",
	},
	Rogue_Ninja = {
		Id = "Rogue_Ninja",
		Name = "Ninja",
		Character = "Rogue",
		Pass = "Skin",
		Colors = {
			Metal = Palette.stone_800,
			Cloth = Palette.chitin_900,
			Cloth2 = Palette.chitin_800,
			Accent = Palette.crimson_500,
			Gold = Palette.steel_400,
			Hat = Palette.chitin_900,
			HatAccent = Palette.crimson_500,
		},
		Hat = "Beanie",
	},
	-- Priest
	Priest_Sun = {
		Id = "Priest_Sun",
		Name = "Sun Priest",
		Character = "Priest",
		Pass = "Skin",
		Colors = {
			Metal = Palette.gold_300,
			Cloth = Palette.gold_200,
			Cloth2 = Palette.gold_400,
			Accent = Palette.crimson_500,
			Gold = Palette.gold_300,
			Hat = Palette.gold_400,
			HatAccent = Palette.crimson_400,
		},
		Hat = "Crown",
	},
	Priest_Moon = {
		Id = "Priest_Moon",
		Name = "Moon Priest",
		Character = "Priest",
		Pass = "Skin",
		Colors = {
			Metal = Palette.slate_500,
			Cloth = Palette.slate_600,
			Cloth2 = Palette.slate_800,
			Accent = Palette.steel_300,
			Gold = Palette.steel_200,
			Hat = Palette.slate_300,
			HatAccent = Palette.steel_200,
		},
		Hat = "Mitre",
	},
	Priest_Angel = {
		Id = "Priest_Angel",
		Name = "Angel",
		Character = "Priest",
		Pass = "Skin",
		Colors = {
			Cloth = Palette.ivory_100,
			Cloth2 = Palette.ivory_200,
			Accent = Palette.gold_300,
			Gold = Palette.gold_300,
			Hat = Palette.gold_200,
			HatAccent = Palette.gold_200,
		},
		Hat = "Halo",
	},
	-- Starter Pack exclusive (every character): polished gold trims, gilded cape / scarf / stole
	GoldTrim = {
		Id = "GoldTrim",
		Name = "Gold Trim",
		Character = "*",
		Pass = "StarterPack",
		Colors = {
			Accent = Palette.gold_500,
			AccentDark = Palette.gold_700,
			Gold = Palette.gold_300,
			HatAccent = Palette.gold_400,
		},
		GoldTrim = true,
	},
}

-- Skins usable by a character, in display order ("Default" first).
function CharacterData.SkinsFor(characterId: string): { string }
	local list = { "Default" }
	for _, skinId in ipairs({ "_Crimson", "_Shadow", "_Paladin", "_Frost", "_Ember", "_Void", "_Forest", "_Pirate", "_Ninja", "_Sun", "_Moon", "_Angel" }) do
		local id = characterId .. skinId
		if CharacterData.Skins[id] then
			table.insert(list, id)
		end
	end
	table.insert(list, "GoldTrim")
	return list
end

-- A darker, slightly cooler tone (MetalDark / AccentDark when a skin doesn't give them).
local function shade(c: Color3): Color3
	return Color3.new(c.R * 0.7, c.G * 0.7, math.min(1, c.B * 0.74))
end

local function skinFor(characterId: string, skinId: string?)
	local skin = skinId and CharacterData.Skins[skinId]
	if skin and (skin.Character == characterId or skin.Character == "*") then
		return skin
	end
	return nil
end

--[[
	Slot colours a skin puts on the hero meshes (see MeshCatalog): the skin's own slots plus
	derived shades. Default skin = nil (each mesh keeps its own palette, which matches
	Characters[id].Colors). Slots the skin doesn't set keep the mesh's colours.
]]
function CharacterData.MeshPalette(characterId: string, skinId: string?): { [string]: Color3 }?
	local skin = skinFor(characterId, skinId)
	if not skin then
		return nil
	end
	local palette: { [string]: Color3 } = {}
	for _, slot in ipairs(SKIN_SLOTS) do
		palette[slot] = skin.Colors[slot]
	end
	if palette.Metal and not palette.MetalDark then
		palette.MetalDark = shade(palette.Metal)
	end
	if palette.Accent and not palette.AccentDark then
		palette.AccentDark = shade(palette.Accent)
	end
	return palette
end

--[[
	Resolves the final look for a character + skin pair:
	  Colors   every slot (character colours, skin overrides, derived shades) plus swatch
	           aliases for the UI: Torso (body), Head (skin), Arms, Legs, Hat, Accent
	  Hat      headgear shape; GoldTrim true for the Starter Pack skin
]]
function CharacterData.ResolveLook(characterId: string, skinId: string?)
	local char = CharacterData.Characters[characterId] or CharacterData.Characters[CharacterData.Default]
	local colors: { [string]: Color3 } = table.clone(char.Colors)
	local hat = char.Hat
	local goldTrim = false
	local skin = skinFor(char.Id, skinId)
	if skin then
		for k, v in pairs(skin.Colors) do
			colors[k] = v
		end
		if skin.Colors.Metal and not skin.Colors.MetalDark then
			colors.MetalDark = shade(skin.Colors.Metal)
		end
		if skin.Colors.Accent and not skin.Colors.AccentDark then
			colors.AccentDark = shade(skin.Colors.Accent)
		end
		hat = skin.Hat or hat
		goldTrim = skin.GoldTrim == true
	end
	colors.Torso = colors[char.Swatch] or colors.Cloth
	colors.Head = colors.Skin
	colors.Arms = colors.Torso
	colors.Legs = colors.Cloth2
	return { Colors = colors, Hat = hat, GoldTrim = goldTrim }
end

return CharacterData
