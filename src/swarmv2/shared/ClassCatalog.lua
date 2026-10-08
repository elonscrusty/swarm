--!strict
--[[
	SwarmV2/ClassCatalog.lua  (ReplicatedStorage.SwarmV2.ClassCatalog)
	OWNER: lobby track (Chat 1). Read-only presentation metadata for the four playable
	classes. Visible to clients, so it holds no admission, ticket or ownership state:
	seeing a class here never means owning it (the server checks the save).

	Gameplay (models, kits, tuning) lives in ServerScriptService.SwarmV2.Run (Chat 2), keyed
	by the same ids. Owner decisions 2026-10-08 (docs/redesign/DECISIONS.md): the old 11
	heroes are hidden; Ruckus is free; the others reuse the existing 10k / 20k / 30k gold
	hero tiers.
]]

export type ClassInfo = {
	Id: string,
	Name: string,
	Tagline: string,
	Cost: number, -- gold; 0 = owned by every account
	Order: number,
}

local Classes: { [string]: ClassInfo } = {
	ruckus = { Id = "ruckus", Name = "Ruckus", Tagline = "Raccoon with a trash-can backpack. Bouncing scrap.", Cost = 0, Order = 1 },
	toastmaster = { Id = "toastmaster", Name = "Toastmaster", Tagline = "Very serious toaster. Ricocheting toast.", Cost = 10000, Order = 2 },
	captain_croak = { Id = "captain_croak", Name = "Captain Croak", Tagline = "Explorer frog. Bubble bombs and long leaps.", Cost = 20000, Order = 3 },
	granny_boom = { Id = "granny_boom", Name = "Granny Boom", Tagline = "Rocket walker grandma. Explosive yarn.", Cost = 30000, Order = 4 },
}

local ClassCatalog = {}

ClassCatalog.Order = { "ruckus", "toastmaster", "captain_croak", "granny_boom" }
ClassCatalog.Default = "ruckus"
-- Old hero ids still stored in saves (CharacterData). Hidden, never selectable, never deleted.
ClassCatalog.LegacyIds = {
	"Knight", "Mage", "Rogue", "Priest", "Ranger", "Alchemist",
	"Engineer", "Necromancer", "Archer", "Bard", "Golem",
}

function ClassCatalog.Get(id: string): ClassInfo?
	return Classes[id]
end

function ClassCatalog.IsClassId(id: any): boolean
	return type(id) == "string" and Classes[id] ~= nil
end

return ClassCatalog
