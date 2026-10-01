--[[
	CharacterData.lua
	The 4 playable characters and their cosmetic skins.

	Character fields:
	  Cost          gold price in the lobby (0 = free)
	  StartWeapon   weapon id from WeaponData
	  Bonus         stat bonuses (same keys as PassiveData values) plus:
	                  damageTaken  -0.1 = take 10% less damage
	  Colors        Torso / Head / Arms / Legs / Hat / Accent
	  Hat           hat shape id built by ModelBuilder (see ModelBuilder.HatShapes)

	Skins only change colours and the hat shape (cosmetic). Each skin is sold as a
	gamepass; its id goes in Config.Monetization.SkinPasses[skin.Id]. "GoldTrim" is the
	Starter Pack skin and works on every character.
]]

local CharacterData = {}

CharacterData.Order = { "Knight", "Mage", "Rogue", "Priest" }
CharacterData.Default = "Knight"

local SKIN_TONE = Color3.fromRGB(255, 214, 170)

CharacterData.Characters = {
	Knight = {
		Id = "Knight",
		Name = "Knight",
		Description = "Sturdy fighter. Starts with the Whip. Takes 10% less damage.",
		Cost = 0,
		StartWeapon = "Whip",
		Bonus = { damageTaken = -0.10 },
		BonusText = "+10% armor",
		Colors = {
			Torso = Color3.fromRGB(150, 155, 170),
			Head = SKIN_TONE,
			Arms = Color3.fromRGB(120, 125, 140),
			Legs = Color3.fromRGB(70, 75, 95),
			Hat = Color3.fromRGB(175, 180, 195),
			Accent = Color3.fromRGB(200, 40, 40),
		},
		Hat = "Helmet",
	},
	Mage = {
		Id = "Mage",
		Name = "Mage",
		Description = "Arcane scholar. Starts with the Magic Orb. +10% area.",
		Cost = 500,
		StartWeapon = "MagicOrb",
		Bonus = { area = 0.10 },
		BonusText = "+10% area",
		Colors = {
			Torso = Color3.fromRGB(70, 60, 170),
			Head = SKIN_TONE,
			Arms = Color3.fromRGB(70, 60, 170),
			Legs = Color3.fromRGB(45, 40, 110),
			Hat = Color3.fromRGB(60, 50, 160),
			Accent = Color3.fromRGB(255, 215, 80),
		},
		Hat = "Wizard",
	},
	Rogue = {
		Id = "Rogue",
		Name = "Rogue",
		Description = "Quick and sharp. Starts with Throwing Knives. +15% speed.",
		Cost = 1000,
		StartWeapon = "Knives",
		Bonus = { speed = 0.15 },
		BonusText = "+15% speed",
		Colors = {
			Torso = Color3.fromRGB(60, 110, 60),
			Head = SKIN_TONE,
			Arms = Color3.fromRGB(80, 60, 45),
			Legs = Color3.fromRGB(50, 45, 40),
			Hat = Color3.fromRGB(45, 90, 45),
			Accent = Color3.fromRGB(200, 170, 110),
		},
		Hat = "Hood",
	},
	Priest = {
		Id = "Priest",
		Name = "Priest",
		Description = "Holy healer. Starts with the Garlic Aura. +20% max HP.",
		Cost = 1500,
		StartWeapon = "Garlic",
		Bonus = { maxHpMult = 0.20 },
		BonusText = "+20% HP",
		Colors = {
			Torso = Color3.fromRGB(240, 240, 235),
			Head = SKIN_TONE,
			Arms = Color3.fromRGB(240, 240, 235),
			Legs = Color3.fromRGB(200, 190, 160),
			Hat = Color3.fromRGB(245, 245, 240),
			Accent = Color3.fromRGB(230, 190, 60),
		},
		Hat = "Mitre",
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
		Colors = { Torso = Color3.fromRGB(160, 30, 35), Arms = Color3.fromRGB(130, 25, 30), Legs = Color3.fromRGB(60, 20, 25), Hat = Color3.fromRGB(180, 40, 45), Accent = Color3.fromRGB(240, 200, 90) },
		Hat = "Plume",
	},
	Knight_Shadow = {
		Id = "Knight_Shadow",
		Name = "Shadow Knight",
		Character = "Knight",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(35, 35, 45), Arms = Color3.fromRGB(25, 25, 35), Legs = Color3.fromRGB(20, 20, 25), Hat = Color3.fromRGB(40, 40, 55), Accent = Color3.fromRGB(150, 60, 255) },
		Hat = "Horns",
	},
	Knight_Paladin = {
		Id = "Knight_Paladin",
		Name = "Paladin",
		Character = "Knight",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(235, 235, 245), Arms = Color3.fromRGB(210, 215, 230), Legs = Color3.fromRGB(80, 110, 190), Hat = Color3.fromRGB(240, 240, 250), Accent = Color3.fromRGB(80, 140, 255) },
		Hat = "Crown",
	},
	-- Mage
	Mage_Frost = {
		Id = "Mage_Frost",
		Name = "Frost Mage",
		Character = "Mage",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(150, 210, 255), Arms = Color3.fromRGB(130, 195, 245), Legs = Color3.fromRGB(70, 120, 180), Hat = Color3.fromRGB(190, 230, 255), Accent = Color3.fromRGB(255, 255, 255) },
		Hat = "Wizard",
	},
	Mage_Ember = {
		Id = "Mage_Ember",
		Name = "Ember Mage",
		Character = "Mage",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(200, 70, 30), Arms = Color3.fromRGB(180, 60, 25), Legs = Color3.fromRGB(90, 30, 20), Hat = Color3.fromRGB(230, 100, 30), Accent = Color3.fromRGB(255, 220, 60) },
		Hat = "Tophat",
	},
	Mage_Void = {
		Id = "Mage_Void",
		Name = "Void Mage",
		Character = "Mage",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(25, 15, 40), Arms = Color3.fromRGB(35, 20, 55), Legs = Color3.fromRGB(15, 10, 25), Hat = Color3.fromRGB(40, 20, 70), Accent = Color3.fromRGB(200, 80, 255) },
		Hat = "Halo",
	},
	-- Rogue
	Rogue_Forest = {
		Id = "Rogue_Forest",
		Name = "Forest Ranger",
		Character = "Rogue",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(110, 150, 60), Arms = Color3.fromRGB(100, 80, 50), Legs = Color3.fromRGB(70, 60, 40), Hat = Color3.fromRGB(90, 140, 50), Accent = Color3.fromRGB(220, 60, 40) },
		Hat = "Cap",
	},
	Rogue_Pirate = {
		Id = "Rogue_Pirate",
		Name = "Pirate",
		Character = "Rogue",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(240, 240, 235), Arms = Color3.fromRGB(150, 30, 30), Legs = Color3.fromRGB(40, 40, 60), Hat = Color3.fromRGB(180, 30, 30), Accent = Color3.fromRGB(240, 210, 90) },
		Hat = "Bandana",
	},
	Rogue_Ninja = {
		Id = "Rogue_Ninja",
		Name = "Ninja",
		Character = "Rogue",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(30, 30, 35), Arms = Color3.fromRGB(30, 30, 35), Legs = Color3.fromRGB(25, 25, 30), Hat = Color3.fromRGB(35, 35, 40), Accent = Color3.fromRGB(220, 40, 40) },
		Hat = "Beanie",
	},
	-- Priest
	Priest_Sun = {
		Id = "Priest_Sun",
		Name = "Sun Priest",
		Character = "Priest",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(255, 200, 70), Arms = Color3.fromRGB(255, 220, 120), Legs = Color3.fromRGB(220, 140, 40), Hat = Color3.fromRGB(255, 230, 120), Accent = Color3.fromRGB(255, 255, 255) },
		Hat = "Crown",
	},
	Priest_Moon = {
		Id = "Priest_Moon",
		Name = "Moon Priest",
		Character = "Priest",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(60, 70, 120), Arms = Color3.fromRGB(80, 90, 140), Legs = Color3.fromRGB(40, 45, 80), Hat = Color3.fromRGB(190, 200, 230), Accent = Color3.fromRGB(200, 220, 255) },
		Hat = "Mitre",
	},
	Priest_Angel = {
		Id = "Priest_Angel",
		Name = "Angel",
		Character = "Priest",
		Pass = "Skin",
		Colors = { Torso = Color3.fromRGB(255, 255, 255), Arms = Color3.fromRGB(250, 250, 255), Legs = Color3.fromRGB(235, 235, 245), Hat = Color3.fromRGB(255, 240, 150), Accent = Color3.fromRGB(255, 230, 120) },
		Hat = "Halo",
	},
	-- Starter Pack exclusive (every character)
	GoldTrim = {
		Id = "GoldTrim",
		Name = "Gold Trim",
		Character = "*",
		Pass = "StarterPack",
		Colors = { Accent = Color3.fromRGB(255, 200, 40), Hat = Color3.fromRGB(255, 205, 60) },
		GoldTrim = true, -- ModelBuilder adds gold trim strips
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

--[[
	Slot colours for the Blender hero meshes (see MeshCatalog). Default skin = nil (the
	mesh's own palette). Skins map their colours onto the mesh slots:
	  Torso → Cloth, Legs → Cloth2, Hat → Metal, Accent → Accent (Gold Trim adds Gold).
]]
function CharacterData.MeshPalette(characterId: string, skinId: string?): { [string]: Color3 }?
	local skin = skinId and CharacterData.Skins[skinId]
	if not skin or (skin.Character ~= characterId and skin.Character ~= "*") then
		return nil
	end
	local c = skin.Colors
	local palette = {}
	palette.Cloth = c.Torso
	palette.Cloth2 = c.Legs
	palette.Metal = c.Hat
	palette.Accent = c.Accent
	if skin.GoldTrim then
		palette.Gold = Color3.fromRGB(255, 200, 40)
		palette.Accent = Color3.fromRGB(255, 200, 40)
	end
	return palette
end

-- Resolves the final look (colours + hat) for a character + skin pair.
function CharacterData.ResolveLook(characterId: string, skinId: string?)
	local char = CharacterData.Characters[characterId] or CharacterData.Characters[CharacterData.Default]
	local colors = table.clone(char.Colors)
	local hat = char.Hat
	local goldTrim = false
	local skin = skinId and CharacterData.Skins[skinId]
	if skin and (skin.Character == char.Id or skin.Character == "*") then
		for k, v in pairs(skin.Colors) do
			colors[k] = v
		end
		hat = skin.Hat or hat
		goldTrim = skin.GoldTrim == true
	end
	return { Colors = colors, Hat = hat, GoldTrim = goldTrim }
end

return CharacterData
