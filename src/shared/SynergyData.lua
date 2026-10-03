--[[
	SynergyData.lua
	Build SYNERGIES: small bonuses for carrying a set of pieces that belong together
	(weapons, passives and run items). A synergy is active while the player owns every
	piece; it needs no card of its own and is never lost for the run unless a piece is
	(run items and weapons are kept, so in practice it stays once complete).

	The package (6 synergies, each needs 3 pieces). Bonuses are modest on purpose: about
	one level of a passive each, so a synergy rewards a plan without being the only way
	to win, and none of them touch the hard caps (crit 60%, cooldown floor, speed cap):
	  Elemental Trinity   a fire weapon + Frost Nova + Lightning
	                      +10% damage, +10% area (three of six weapon slots committed)
	  Ember Field         a fire weapon + Area + Candle
	                      +15% duration, +8% area (fire pools / trails stay and spread)
	  Deadeye             Longbow or Crossbow + Precision + Keen Lens or Hunter's Eye
	                      +5% crit chance, +25% crit damage (the crit build gets its kick)
	  Bulwark             a close weapon (Whip, Garlic Aura, Spear) + Armor + Iron Plate or
	                      Barbed Mail: +1 armor, +10% max HP (the stand-your-ground build)
	  Inferno             a fire weapon + Ember Oil + Volatile Spore or Storm Charm
	                      +8% burn chance, +10% damage (everything catches fire)
	  Iron Thicket        Thornhide + Stoneskin + Iron Plate or Barbed Mail
	                      +60% thorns, +1 armor (let them hit you)
	Elements come from WeaponData (`Element` = "Fire" | "Frost" | "Storm"); "a fire weapon"
	is any weapon with Element = "Fire" (Holy Water, Fire Trail). Evolved weapons count.

	Pieces: { Kind = "Weapon" | "Passive" | "Item", Any = { ids } } or
	        { Kind = "Weapon", Element = "Fire" }; Label = how a card / the list names it.
	Bonus keys are the stat sheet's additive keys (StatSheet.BonusKeys: might, area, ...).

	Server: LevelUpSystem adds SynergyData.Bonus(active) to the stat sheet, sets the player
	attribute "Synergies" (comma list of active ids) and names the synergy a NEW card would
	complete or advance (card field Synergy / SynergyReady). Client: LootUI shows the active
	ones as a chip under the item strip and at the top of the pause ITEMS list.
]]

local WeaponData = require(script.Parent.WeaponData)

local SynergyData = {}

export type Piece = { Kind: string, Any: { string }?, Element: string?, Label: string }
export type Synergy = {
	Id: string,
	Name: string,
	Text: string, -- the bonus in a few words (chip, notify)
	Desc: string, -- what it needs (ITEMS list)
	Color: Color3,
	Icon: string, -- Icons.lua name
	Pieces: { Piece },
	Bonus: { [string]: number },
}

local LIST: { Synergy } = {
	{
		Id = "Trinity",
		Name = "Elemental Trinity",
		Text = "+10% damage, +10% area",
		Desc = "A fire weapon, Frost Nova and Lightning.",
		Color = Color3.fromRGB(255, 170, 90),
		Icon = "sparkle",
		Pieces = {
			{ Kind = "Weapon", Element = "Fire", Label = "a fire weapon" },
			{ Kind = "Weapon", Element = "Frost", Label = "Frost Nova" },
			{ Kind = "Weapon", Element = "Storm", Label = "Lightning" },
		},
		Bonus = { might = 0.10, area = 0.10 },
	},
	{
		Id = "EmberField",
		Name = "Ember Field",
		Text = "+15% duration, +8% area",
		Desc = "A fire weapon, the Area passive and the Candle passive.",
		Color = Color3.fromRGB(240, 120, 50),
		Icon = "Hellfire",
		Pieces = {
			{ Kind = "Weapon", Element = "Fire", Label = "a fire weapon" },
			{ Kind = "Passive", Any = { "Area" }, Label = "Area" },
			{ Kind = "Passive", Any = { "Candle" }, Label = "Candle" },
		},
		Bonus = { duration = 0.15, area = 0.08 },
	},
	{
		Id = "Deadeye",
		Name = "Deadeye",
		Text = "+5% crit chance, +25% crit damage",
		Desc = "Longbow or Crossbow, the Precision passive and Keen Lens or Hunter's Eye.",
		Color = Color3.fromRGB(220, 120, 110),
		Icon = "aim",
		Pieces = {
			{ Kind = "Weapon", Any = { "Longbow", "Crossbow" }, Label = "a bow" },
			{ Kind = "Passive", Any = { "Precision" }, Label = "Precision" },
			{ Kind = "Item", Any = { "KeenLens", "HuntersEye" }, Label = "Keen Lens or Hunter's Eye" },
		},
		Bonus = { critChance = 0.05, critDamage = 0.25 },
	},
	{
		Id = "Bulwark",
		Name = "Bulwark",
		Text = "+1 armor, +10% max HP",
		Desc = "Whip, Garlic Aura or Spear, the Armor passive and Iron Plate or Barbed Mail.",
		Color = Color3.fromRGB(170, 175, 190),
		Icon = "shield",
		Pieces = {
			{ Kind = "Weapon", Any = { "Whip", "Garlic", "Spear" }, Label = "a close weapon" },
			{ Kind = "Passive", Any = { "Armor" }, Label = "Armor" },
			{ Kind = "Item", Any = { "IronPlate", "BarbedMail" }, Label = "Iron Plate or Barbed Mail" },
		},
		Bonus = { armor = 1, maxHpMult = 0.10 },
	},
	{
		Id = "Inferno",
		Name = "Inferno",
		Text = "+8% burn chance, +10% damage",
		Desc = "A fire weapon, the Ember Oil passive and Volatile Spore or Storm Charm.",
		Color = Color3.fromRGB(255, 110, 40),
		Icon = "EmberOil",
		Pieces = {
			{ Kind = "Weapon", Element = "Fire", Label = "a fire weapon" },
			{ Kind = "Passive", Any = { "EmberOil" }, Label = "Ember Oil" },
			{ Kind = "Item", Any = { "VolatileSpore", "StormCharm" }, Label = "Volatile Spore or Storm Charm" },
		},
		Bonus = { burnChance = 0.08, might = 0.10 },
	},
	{
		Id = "IronThicket",
		Name = "Iron Thicket",
		Text = "+60% thorns, +1 armor",
		Desc = "The Thornhide and Stoneskin passives and Iron Plate or Barbed Mail.",
		Color = Color3.fromRGB(130, 150, 100),
		Icon = "Thornhide",
		Pieces = {
			{ Kind = "Passive", Any = { "Thornhide" }, Label = "Thornhide" },
			{ Kind = "Passive", Any = { "Stoneskin" }, Label = "Stoneskin" },
			{ Kind = "Item", Any = { "IronPlate", "BarbedMail" }, Label = "Iron Plate or Barbed Mail" },
		},
		Bonus = { thorns = 0.6, armor = 1 },
	},
}

SynergyData.Order = {} :: { string }
SynergyData.Synergies = {} :: { [string]: Synergy }
for _, s in ipairs(LIST) do
	table.insert(SynergyData.Order, s.Id)
	SynergyData.Synergies[s.Id] = s
end

-- What a player owns: weapons / passives / items as { [id] = anything truthy (> 0) }.
export type Owned = { Weapons: { [string]: any }, Passives: { [string]: any }, Items: { [string]: any } }

local function has(t: { [string]: any }?, id: string): boolean
	local v = t and t[id]
	if type(v) == "number" then
		return v > 0
	end
	return v ~= nil and v ~= false
end

-- Does `owned` cover this piece?
function SynergyData.PieceOwned(piece: Piece, owned: Owned): boolean
	if piece.Kind == "Weapon" and piece.Element then
		for id in pairs(owned.Weapons or {}) do
			local def = WeaponData.Weapons[id]
			if def and def.Element == piece.Element and has(owned.Weapons, id) then
				return true
			end
		end
		return false
	end
	local t = piece.Kind == "Weapon" and owned.Weapons or piece.Kind == "Passive" and owned.Passives or owned.Items
	for _, id in ipairs(piece.Any or {}) do
		if has(t, id) then
			return true
		end
	end
	return false
end

-- Would weapon / passive / item `id` (kind) fill this piece?
function SynergyData.PieceTakes(piece: Piece, kind: string, id: string): boolean
	if piece.Kind ~= kind then
		return false
	end
	if piece.Element then
		local def = WeaponData.Weapons[id]
		return def ~= nil and def.Element == piece.Element
	end
	return table.find(piece.Any or {}, id) ~= nil
end

-- (pieces owned, pieces needed) of one synergy.
function SynergyData.Progress(id: string, owned: Owned): (number, number)
	local s = SynergyData.Synergies[id]
	if not s then
		return 0, 0
	end
	local n = 0
	for _, piece in ipairs(s.Pieces) do
		if SynergyData.PieceOwned(piece, owned) then
			n += 1
		end
	end
	return n, #s.Pieces
end

-- Ids of every complete synergy, in SynergyData.Order.
function SynergyData.Active(owned: Owned): { string }
	local out = {}
	for _, id in ipairs(SynergyData.Order) do
		local n, need = SynergyData.Progress(id, owned)
		if n >= need then
			table.insert(out, id)
		end
	end
	return out
end

-- Summed stat bonus of a list of synergy ids (additive stat-sheet keys).
function SynergyData.Bonus(ids: { string }): { [string]: number }
	local b: { [string]: number } = {}
	for _, id in ipairs(ids) do
		local s = SynergyData.Synergies[id]
		if s then
			for k, v in pairs(s.Bonus) do
				b[k] = (b[k] or 0) + v
			end
		end
	end
	return b
end

--[[
	The best synergy a NEW piece (kind "Weapon" | "Passive" | "Item", id) would help:
	returns (synergy, have after, need) for the one it completes, else the one it brings
	closest (only when the player already holds another of its pieces), else nil.
]]
function SynergyData.Advances(owned: Owned, kind: string, id: string): (Synergy?, number, number)
	local best, bestHave, bestNeed = nil, 0, 0
	for _, sid in ipairs(SynergyData.Order) do
		local s = SynergyData.Synergies[sid]
		local have, need = SynergyData.Progress(sid, owned)
		if have < need then
			local fills = false
			for _, piece in ipairs(s.Pieces) do
				if not SynergyData.PieceOwned(piece, owned) and SynergyData.PieceTakes(piece, kind, id) then
					fills = true
					break
				end
			end
			if fills and have >= 1 then
				local after = have + 1
				if not best or (after >= need and bestHave < bestNeed) or (need - after < bestNeed - bestHave) then
					best, bestHave, bestNeed = s, after, need
				end
			end
		end
	end
	return best, bestHave, bestNeed
end

-- "Ember Field, Deadeye" → { ids } (the "Synergies" attribute is a comma list of ids).
function SynergyData.FromString(str: any): { string }
	local out = {}
	if type(str) ~= "string" then
		return out
	end
	for id in string.gmatch(str, "[^,]+") do
		if SynergyData.Synergies[id] then
			table.insert(out, id)
		end
	end
	return out
end

return SynergyData
