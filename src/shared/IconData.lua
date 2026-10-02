--[[
	IconData.lua
	Upgrade icons: one picture per weapon, evolution and passive, shown in the in-run
	ability bar, on the level-up cards, chest rewards and the character / upgrade screens.

	Every id already has a vector icon drawn in code (src/client/Icons.lua, the same style
	as the menu icons), so all entries below can stay nil. A picture pasted here replaces
	that id's vector icon (tools/gen_icon_data.py fills the table from art/icons/uploaded_ids.json). An id with neither (a new weapon / passive) shows its Glyph text.

	HOW TO FILL IT
	  1. Make a square PNG per id (256x256 is plenty; transparent background, the item
	     centred, no text). Name each file after its id, e.g. "Whip.png", "Bloodwhip.png".
	  2. Upload them (Creator Dashboard → Development Items → Decals, or Claude can upload
	     them with the Open Cloud key). Each upload gives an asset id (a number).
	  3. Paste the number next to its id below, e.g.  Whip = 1234567890,
	     (a full "rbxassetid://..." string works too). Leave unknown ones as nil.
	A new weapon / passive with no entry here simply gets a placeholder.
]]

local IconData = {}

IconData.Icons = {
	-- Weapons
	Whip = 107847975036746,
	MagicOrb = 92101671072138,
	Knives = 91498299133628,
	Garlic = 75185524104987,
	HolyWater = 92821230712801,
	Lightning = 70637239297099,
	Axe = 130497049367652,
	Boomerang = 107158281500524,
	Longbow = 94030467174643,
	Spear = 97093342321426,
	Crossbow = 119446419342461,
	FrostNova = 97835676479383,
	FireTrail = 92462222921176,
	HealingTotem = 136514241879103,
	ChainHook = 106304288264190,
	Turret = 121840094086682,
	SoulBolt = 109900195027304,
	-- Evolutions (shown once the weapon has evolved, and on EVOLUTION cards)
	Bloodwhip = 91623779348927,
	TwinOrbs = 122663734182849,
	ThousandEdge = 87029690144547,
	SoulEater = 103388404301706,
	Hellfire = 87778137198245,
	ThunderLoop = 140517911511278,
	DeathSpiral = 81570729537262,
	InfiniteReturn = 119481487167302,
	Windpiercer = 76482273261744,
	DragonLance = 132009689421810,
	Heartseeker = 101464484989572,
	AbsoluteZero = 118391220122569,
	PhoenixStride = 121304693016417,
	Lifebloom = 110483720969076,
	ReapersChain = 129844731766201,
	Bastion = 76640644670505,
	SoulStorm = 88673930007129,
	-- Passives
	Might = 140676653398092,
	Armor = 111339312081287,
	Heart = 95537303748350,
	SpeedBoots = 108980143980067,
	Cooldown = 80452243646190,
	Area = 105963955962038,
	Duplicator = 129309796615609,
	Vacuum = 80388248755943,
	Luck = 90711845797584,
	Ammo = 117117767354320,
	Candle = 85522736292459,
	Growth = 84926265269882,
	Fletching = 98689586490863,
	Precision = 98037335035662,
	Renewal = 120768913650728,
	-- Fallback level-up cards (every slot maxed)
	Gold = 140106250613505,
	Heal = 81721198350930,
	-- Run items: common
	Whetstone = 124127171305250,
	QuickGloves = 113366982203506,
	SwiftFeather = 71689577168506,
	HeartyBread = 74829162260713,
	Bandage = 123971994126648,
	Lodestone = 99785811475519,
	KeenLens = 124398895143681,
	SpareQuiver = 113650709012670,
	-- Run items: uncommon
	HealingHerb = 86161878747360,
	IronPlate = 131736167457310,
	BarbedMail = 84311400650109,
	GuardianWard = 98409975402889,
	HuntersEye = 116752033146232,
	MagnetTotem = 112322538022434,
	StormCharm = 136660411629881,
	VolatileSpore = 71812106664176,
	-- Run items: legendary
	PhoenixFeather = 72562424318271,
	SunMedallion = 121368790279251,
	CrownOfAges = 116984345174167,
	-- Loot / run markers
	chest = 102564255284031,
	shrine = 118314946884299,
	altar = 76272553564152,
	portal = 126782693482750,
	revive = 140117129153655,
} :: { [string]: (number | string)? }

-- Last-resort text (1-2 letters) for an id that has neither a picture nor a vector icon.
IconData.Glyphs = {
	Whip = "Wh",
	MagicOrb = "Or",
	Knives = "Kn",
	Garlic = "Ga",
	HolyWater = "HW",
	Lightning = "Lt",
	Axe = "Ax",
	Boomerang = "Bo",
	Longbow = "Lb",
	Bloodwhip = "BW",
	TwinOrbs = "TO",
	ThousandEdge = "TE",
	SoulEater = "SE",
	Hellfire = "HF",
	ThunderLoop = "TL",
	DeathSpiral = "DS",
	InfiniteReturn = "IR",
	Windpiercer = "WP",
	Might = "Mi",
	Armor = "Ar",
	Heart = "He",
	SpeedBoots = "Sp",
	Cooldown = "Cd",
	Area = "Ae",
	Duplicator = "Du",
	Vacuum = "Va",
	Luck = "Lu",
	Ammo = "Am",
	Candle = "Ca",
	Growth = "Gr",
	Fletching = "Fl",
	Precision = "Pr",
	Renewal = "Rn",
	Spear = "Sp",
	Crossbow = "Cb",
	FrostNova = "FN",
	FireTrail = "FT",
	HealingTotem = "HT",
	ChainHook = "CH",
	Turret = "Tu",
	SoulBolt = "SB",
	DragonLance = "DL",
	Heartseeker = "HS",
	AbsoluteZero = "AZ",
	PhoenixStride = "PS",
	Lifebloom = "LB",
	ReapersChain = "RC",
	Bastion = "Ba",
	SoulStorm = "SS",
	Gold = "$",
	Heal = "+",
} :: { [string]: string }

-- "rbxassetid://..." for an id, or nil when it has no picture yet.
function IconData.Image(id: string?): string?
	if not id then
		return nil
	end
	local v = IconData.Icons[id]
	if type(v) == "number" and v > 0 then
		return "rbxassetid://" .. tostring(v)
	elseif type(v) == "string" and v ~= "" then
		return v
	end
	return nil
end

-- Placeholder text for an id (falls back to the first two letters of its name).
function IconData.Glyph(id: string?, name: string?): string
	local g = id and IconData.Glyphs[id]
	if g then
		return g
	end
	return string.sub(name or id or "?", 1, 2)
end

return IconData
