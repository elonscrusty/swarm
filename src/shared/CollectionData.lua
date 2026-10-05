--[[
	CollectionData.lua
	The collection book (feature 24, Config.Features.CollectionBook; docs/features/META.md).
	Everything is read from what the save already records, so nothing is counted twice:
	  Enemies   Journal.Enemies (JournalService: enemies observed in runs)
	  Bosses    Journal.Enemies[boss body] or Collection.Seen["Boss:<id>"] (beaten)
	  Weapons   Discovered.Weapons    Passives  Discovered.Passives    Items  Discovered.Items
	            (DiscoveryService: owned or seen on a card)
	  Heroes    Collection.Seen["Hero:<id>"] (played a run) or owned
	A save (server) and the ProfileSync (client: Journal, Discovered, Features.Collection,
	OwnedCharacters) both work as `p`.
]]

local EnemyData = require(script.Parent.EnemyData)
local BossData = require(script.Parent.BossData)
local WeaponData = require(script.Parent.WeaponData)
local PassiveData = require(script.Parent.PassiveData)
local ItemData = require(script.Parent.ItemData)
local CharacterData = require(script.Parent.CharacterData)

local CollectionData = {}

CollectionData.Order = { "Enemies", "Bosses", "Weapons", "Passives", "Items", "Heroes" }

local bossBodies: { [string]: boolean } = {}
for _, id in ipairs(BossData.Rotation) do
	local def = BossData.Bosses[id]
	if def and def.EnemyType then
		bossBodies[def.EnemyType] = true
	end
end

local enemies = {}
for id, def in pairs(EnemyData.Enemies) do
	if not bossBodies[id] and type(def.DisplayName) == "string" then
		table.insert(enemies, id)
	end
end
table.sort(enemies, function(a, b)
	return EnemyData.Enemies[a].DisplayName < EnemyData.Enemies[b].DisplayName
end)

local function set(p: any, ...: string): { [string]: any }
	local t = p
	for _, k in ipairs({ ... }) do
		if type(t) ~= "table" then
			return {}
		end
		t = t[k]
	end
	return type(t) == "table" and t or {}
end

-- The collection sets of a save / profile: Collection.Seen lives in data.Collection on the
-- server and in profile.Features.Collection on the client.
local function seen(p: any): { [string]: any }
	local direct = set(p, "Collection", "Seen")
	if next(direct) ~= nil then
		return direct
	end
	return set(p, "Features", "Collection", "Seen")
end

export type Category = { Id: string, Title: string, Ids: { string }, Name: (string) -> string, Icon: (string) -> string, Known: (any, string) -> boolean }

CollectionData.Categories = {
	Enemies = {
		Id = "Enemies",
		Title = "ENEMIES",
		Ids = enemies,
		Name = function(id: string): string
			return EnemyData.Enemies[id].DisplayName
		end,
		Icon = function(_id: string): string
			return "skull"
		end,
		Known = function(p: any, id: string): boolean
			return set(p, "Journal", "Enemies")[id] == true
		end,
	},
	Bosses = {
		Id = "Bosses",
		Title = "BOSSES",
		Ids = table.clone(BossData.Rotation),
		Name = function(id: string): string
			return BossData.Bosses[id].DisplayName
		end,
		Icon = function(_id: string): string
			return "crown"
		end,
		Known = function(p: any, id: string): boolean
			local def = BossData.Bosses[id]
			return seen(p)["Boss:" .. id] == true or (def ~= nil and set(p, "Journal", "Enemies")[def.EnemyType] == true)
		end,
	},
	Weapons = {
		Id = "Weapons",
		Title = "WEAPONS",
		Ids = table.clone(WeaponData.Order),
		Name = function(id: string): string
			return WeaponData.Weapons[id].Name
		end,
		Icon = function(id: string): string
			return id
		end,
		Known = function(p: any, id: string): boolean
			return set(p, "Discovered", "Weapons")[id] == true
		end,
	},
	Passives = {
		Id = "Passives",
		Title = "PASSIVES",
		Ids = table.clone(PassiveData.Order),
		Name = function(id: string): string
			return PassiveData.Passives[id].Name
		end,
		Icon = function(id: string): string
			return id
		end,
		Known = function(p: any, id: string): boolean
			return set(p, "Discovered", "Passives")[id] == true
		end,
	},
	Items = {
		Id = "Items",
		Title = "ITEMS",
		Ids = table.clone(ItemData.Order),
		Name = function(id: string): string
			return ItemData.Items[id].Name
		end,
		Icon = function(id: string): string
			return id
		end,
		Known = function(p: any, id: string): boolean
			return set(p, "Discovered", "Items")[id] == true
		end,
	},
	Heroes = {
		Id = "Heroes",
		Title = "HEROES",
		Ids = table.clone(CharacterData.Order),
		Name = function(id: string): string
			return CharacterData.Characters[id].Name
		end,
		Icon = function(id: string): string
			return id
		end,
		Known = function(p: any, id: string): boolean
			return seen(p)["Hero:" .. id] == true or set(p, "OwnedCharacters")[id] == true
		end,
	},
} :: { [string]: Category }

-- (seen, total) for one category, or for the whole book when `category` is nil.
function CollectionData.Progress(p: any, category: string?): (number, number)
	local n, total = 0, 0
	for _, cid in ipairs(CollectionData.Order) do
		if category == nil or category == cid then
			local c = CollectionData.Categories[cid]
			for _, id in ipairs(c.Ids) do
				total += 1
				if c.Known(p, id) then
					n += 1
				end
			end
		end
	end
	return n, total
end

return CollectionData
