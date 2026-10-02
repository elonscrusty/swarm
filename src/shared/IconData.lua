--[[
	IconData.lua
	Upgrade icons: one picture per weapon, evolution and passive, shown in the in-run
	ability bar, on the level-up cards, chest rewards and the character / upgrade screens.

	Every id already has a vector icon drawn in code (src/client/Icons.lua, the same style
	as the menu icons), so all entries below can stay nil. A picture pasted here replaces
	that id's vector icon. An id with neither (a new weapon / passive) shows its Glyph text.

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
	Whip = nil,
	MagicOrb = nil,
	Knives = nil,
	Garlic = nil,
	HolyWater = nil,
	Lightning = nil,
	Axe = nil,
	Boomerang = nil,
	Longbow = nil,
	-- Evolutions (shown once the weapon has evolved, and on EVOLUTION cards)
	Bloodwhip = nil,
	TwinOrbs = nil,
	ThousandEdge = nil,
	SoulEater = nil,
	Hellfire = nil,
	ThunderLoop = nil,
	DeathSpiral = nil,
	InfiniteReturn = nil,
	Windpiercer = nil,
	-- Passives
	Might = nil,
	Armor = nil,
	Heart = nil,
	SpeedBoots = nil,
	Cooldown = nil,
	Area = nil,
	Duplicator = nil,
	Vacuum = nil,
	Luck = nil,
	Ammo = nil,
	Candle = nil,
	Growth = nil,
	Fletching = nil,
	-- Fallback level-up cards (every slot maxed)
	Gold = nil,
	Heal = nil,
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
