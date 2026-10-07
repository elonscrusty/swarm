--[[
	EvolutionPreview.lua (shared)
	Batch B item B5, show weapon evolutions early (Config.Features.EvolutionPreview;
	docs/next/EVOLUTION_PREVIEW.md).

	Pure helpers over WeaponData / PassiveData (no new combining system): a weapon evolves at
	WeaponData.MaxLevel with its Evolution.Passive at min(3, that passive's max level), the
	same rule LevelUpSystem.canEvolve uses. The server decorates level-up cards with these
	(LevelUpSystem decorate: card fields Hint / HintReady / EvoIcon / EvoName) and the HUD's
	BUILD details list (Hud refreshDetails) shows EvolutionPreview.List of the Inventory.

	  EvolutionPreview.On()                          the feature switch
	  EvolutionPreview.PassiveNeed(passiveId)        level the partner passive needs
	  EvolutionPreview.Status(weaponId, wLv, pLv)    { WeaponId, EvoId, Name, WeaponName,
	                                                   PassiveId, PassiveName, WeaponNeed,
	                                                   PassiveNeed, WeaponHave, PassiveHave,
	                                                   WeaponOk, PassiveOk, Ready } or nil
	  EvolutionPreview.WeaponLine(status)            "Bloodblade: Sword Lv 12 + Heart Lv 3 (you: Heart 1)"
	  EvolutionPreview.PassiveLine(status)           "Needed for Bloodblade (Heart Lv 3)"
	  EvolutionPreview.Missing(status)               "Sword Lv 9 → 12, Heart Lv 3 (not owned)" | ""
	  EvolutionPreview.List(weapons, passives, slotsFree)
	      every evolution the current build can reach: an owned weapon not evolved yet, or an
	      owned passive whose weapon is released and could still be taken (slotsFree). Ready
	      ones first, then by how little is missing. Each row is a Status plus Owned (the
	      weapon is in the build) and Missing (the text above).
	      weapons:  { { Id, Level, Evolved } }  (the Inventory payload's Weapons)
	      passives: { { Id, Level } }           (the Inventory payload's Passives)
]]

local Config = require(script.Parent.Config)
local WeaponData = require(script.Parent.WeaponData)
local PassiveData = require(script.Parent.PassiveData)

local EvolutionPreview = {}

export type Status = {
	WeaponId: string,
	EvoId: string,
	Name: string,
	WeaponName: string,
	PassiveId: string,
	PassiveName: string,
	WeaponNeed: number,
	PassiveNeed: number,
	WeaponHave: number,
	PassiveHave: number,
	WeaponOk: boolean,
	PassiveOk: boolean,
	Ready: boolean,
	Owned: boolean?,
	Missing: string?,
}

function EvolutionPreview.On(): boolean
	return Config.FeatureOn("EvolutionPreview")
end

function EvolutionPreview.PassiveNeed(passiveId: string): number
	return math.min(3, PassiveData.MaxLevelOf(passiveId))
end

-- weaponLevel / passiveLevel: what the player has (0 = not owned).
function EvolutionPreview.Status(weaponId: string, weaponLevel: number, passiveLevel: number): Status?
	local def = WeaponData.Weapons[weaponId]
	local evo = def and def.Evolution
	if not evo or not PassiveData.Passives[evo.Passive] then
		return nil
	end
	local pNeed = EvolutionPreview.PassiveNeed(evo.Passive)
	local wOk = weaponLevel >= WeaponData.MaxLevel
	local pOk = passiveLevel >= pNeed
	return {
		WeaponId = weaponId,
		EvoId = evo.Id,
		Name = evo.Name,
		WeaponName = def.Name,
		PassiveId = evo.Passive,
		PassiveName = PassiveData.Passives[evo.Passive].Name,
		WeaponNeed = WeaponData.MaxLevel,
		PassiveNeed = pNeed,
		WeaponHave = weaponLevel,
		PassiveHave = passiveLevel,
		WeaponOk = wOk,
		PassiveOk = pOk,
		Ready = wOk and pOk,
	}
end

-- The weapon card line: the recipe, then the live progress of the partner passive (the card
-- itself shows the weapon's level).
function EvolutionPreview.WeaponLine(s: Status): string
	local recipe = string.format("%s: %s Lv %d + %s Lv %d", s.Name, s.WeaponName, s.WeaponNeed, s.PassiveName, s.PassiveNeed)
	local progress
	if s.Ready then
		progress = "ready!"
	elseif s.PassiveOk then
		progress = string.format("%s done", s.PassiveName)
	elseif s.PassiveHave <= 0 then
		progress = string.format("you: no %s", s.PassiveName)
	else
		progress = string.format("you: %s %d", s.PassiveName, s.PassiveHave)
	end
	return string.format("%s (%s)", recipe, progress)
end

-- The ingredient passive card line.
function EvolutionPreview.PassiveLine(s: Status): string
	return string.format("Needed for %s (%s Lv %d)", s.Name, s.PassiveName, s.PassiveNeed)
end

-- What is still missing, in words ("" when ready).
function EvolutionPreview.Missing(s: Status): string
	local parts = {}
	if not s.WeaponOk then
		if s.WeaponHave <= 0 then
			table.insert(parts, string.format("%s (not owned)", s.WeaponName))
		else
			table.insert(parts, string.format("%s Lv %d → %d", s.WeaponName, s.WeaponHave, s.WeaponNeed))
		end
	end
	if not s.PassiveOk then
		if s.PassiveHave <= 0 then
			table.insert(parts, string.format("%s Lv %d (not owned)", s.PassiveName, s.PassiveNeed))
		else
			table.insert(parts, string.format("%s Lv %d → %d", s.PassiveName, s.PassiveHave, s.PassiveNeed))
		end
	end
	return table.concat(parts, ", ")
end

local function released(weaponId: string): boolean
	return table.find(WeaponData.Order, weaponId) ~= nil
end

-- How far a row is from ready (levels still to gain; a missing piece counts its full need).
local function gap(s: Status): number
	return math.max(0, s.WeaponNeed - s.WeaponHave) + math.max(0, s.PassiveNeed - s.PassiveHave)
end

function EvolutionPreview.List(weapons: { any }?, passives: { any }?, slotsFree: boolean?): { Status }
	local wLevel: { [string]: number } = {}
	local evolved: { [string]: boolean } = {}
	local pLevel: { [string]: number } = {}
	for _, w in ipairs(weapons or {}) do
		if type(w) == "table" and type(w.Id) == "string" then
			wLevel[w.Id] = tonumber(w.Level) or 0
			evolved[w.Id] = w.Evolved == true
		end
	end
	for _, p in ipairs(passives or {}) do
		if type(p) == "table" and type(p.Id) == "string" then
			pLevel[p.Id] = tonumber(p.Level) or 0
		end
	end
	local out: { Status } = {}
	local seen: { [string]: boolean } = {}
	local function add(weaponId: string, owned: boolean)
		if seen[weaponId] or evolved[weaponId] then
			return
		end
		local def = WeaponData.Weapons[weaponId]
		local evo = def and def.Evolution
		if not evo then
			return
		end
		local s = EvolutionPreview.Status(weaponId, wLevel[weaponId] or 0, pLevel[evo.Passive] or 0)
		if s then
			seen[weaponId] = true
			s.Owned = owned
			s.Missing = EvolutionPreview.Missing(s)
			table.insert(out, s)
		end
	end
	-- owned weapons in build order
	for _, w in ipairs(weapons or {}) do
		if type(w) == "table" and type(w.Id) == "string" then
			add(w.Id, true)
		end
	end
	-- owned passives that evolve a weapon the player could still take
	if slotsFree ~= false then
		for _, id in ipairs(WeaponData.Order) do
			local evo = WeaponData.Weapons[id] and WeaponData.Weapons[id].Evolution
			if evo and not wLevel[id] and (pLevel[evo.Passive] or 0) > 0 and released(id) then
				add(id, false)
			end
		end
	end
	-- ready first, then owned weapons, then the smallest gap (stable: original order)
	local index: { [Status]: number } = {}
	for i, s in ipairs(out) do
		index[s] = i
	end
	table.sort(out, function(a: Status, b: Status): boolean
		if a.Ready ~= b.Ready then
			return a.Ready
		end
		if (a.Owned == true) ~= (b.Owned == true) then
			return a.Owned == true
		end
		local ga, gb = gap(a), gap(b)
		if ga ~= gb then
			return ga < gb
		end
		return index[a] < index[b]
	end)
	return out
end

return EvolutionPreview
