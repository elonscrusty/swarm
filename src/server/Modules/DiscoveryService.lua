--[[
	DiscoveryService.lua
	What a player has discovered across runs: weapons, passives and run items they owned
	or saw on a card, the evolutions they reached and the synergies they completed. Saved
	in the profile as Discovered {Weapons, Passives, Items, Evolutions, Synergies}
	({id → true}; DataService fills missing tables, nothing is ever wiped).

	Presentation only: LevelUpSystem names a combination's other ingredient or result on a
	card (and the ITEMS list names a synergy and its missing pieces) only once it has been
	discovered; otherwise it shows "???". The server stays authoritative for the bonuses.
]]

local WeaponData = require(game:GetService("ReplicatedStorage").Shared.WeaponData)
local PassiveData = require(game:GetService("ReplicatedStorage").Shared.PassiveData)
local ItemData = require(game:GetService("ReplicatedStorage").Shared.ItemData)
local SynergyData = require(game:GetService("ReplicatedStorage").Shared.SynergyData)

local DiscoveryService = {}
local ctx
local pending: { [Player]: boolean } = {}

DiscoveryService.Kinds = { "Weapons", "Passives", "Items", "Evolutions", "Synergies" }

local VALID = {
	Weapons = function(id: string): boolean return WeaponData.Weapons[id] ~= nil end,
	Passives = function(id: string): boolean return PassiveData.Passives[id] ~= nil end,
	Items = function(id: string): boolean return ItemData.Items[id] ~= nil end,
	Evolutions = function(id: string): boolean -- keyed by the base weapon id
		local def = WeaponData.Weapons[id]
		return def ~= nil and def.Evolution ~= nil
	end,
	Synergies = function(id: string): boolean return SynergyData.Synergies[id] ~= nil end,
}

-- A fresh, empty record (DataService defaults).
function DiscoveryService.Empty(): { [string]: { [string]: boolean } }
	local out = {}
	for _, kind in ipairs(DiscoveryService.Kinds) do
		out[kind] = {}
	end
	return out
end

-- The player's record, with every table present (older saves, hand edits), or nil
-- while the profile is not loaded.
local function recordOf(player: Player): { [string]: { [string]: boolean } }?
	local data = ctx.DataService.GetData(player)
	if not data then
		return nil
	end
	if type(data.Discovered) ~= "table" then
		data.Discovered = DiscoveryService.Empty()
	end
	for _, kind in ipairs(DiscoveryService.Kinds) do
		if type(data.Discovered[kind]) ~= "table" then
			data.Discovered[kind] = {}
		end
	end
	return data.Discovered
end

-- Has the player discovered `id` of `kind` ("Weapons" | "Passives" | "Items" |
-- "Evolutions" (base weapon id) | "Synergies")? Unknown kinds / no profile: false.
function DiscoveryService.Known(player: Player, kind: string, id: string): boolean
	local rec = recordOf(player)
	local t = rec and rec[kind]
	return t ~= nil and t[id] == true
end

-- Records a discovery; returns true when it is new. The profile is re-sent to the client
-- a moment later (debounced) so the lobby can show it.
function DiscoveryService.Record(player: Player, kind: string, id: string): boolean
	local valid = VALID[kind]
	if not valid or type(id) ~= "string" or not valid(id) then
		return false
	end
	local rec = recordOf(player)
	if not rec or rec[kind][id] == true then
		return false
	end
	rec[kind][id] = true
	if not pending[player] then
		pending[player] = true
		task.delay(1, function()
			pending[player] = nil
			if player.Parent and ctx.GoldSystem then
				ctx.GoldSystem.SyncProfile(player)
			end
		end)
	end
	return true
end

-- Has any id that would fill this synergy piece been discovered?
function DiscoveryService.PieceKnown(player: Player, piece: SynergyData.Piece): boolean
	local rec = recordOf(player)
	if not rec then
		return false
	end
	local kind = piece.Kind .. "s" -- "Weapon" → "Weapons"
	for id in pairs(rec[kind] or {}) do
		if SynergyData.PieceTakes(piece, piece.Kind, id) then
			return true
		end
	end
	return false
end

function DiscoveryService.Init(c)
	ctx = c
end

return DiscoveryService
