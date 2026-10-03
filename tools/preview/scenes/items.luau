-- items: the pause menu's ITEMS list (LootUI.OpenItems) with a run's items.
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 60 })
local list = {}
for i, id in ipairs({ "Whetstone", "QuickGloves", "SwiftFeather", "HeartyBread", "Bandage", "KeenLens", "IronPlate", "StormCharm", "VolatileSpore", "PhoenixFeather" }) do
	table.insert(list, { Id = id, Count = (i % 3) + 1 })
end
C.fire("Items", list)
-- --set synergies=on   the synergy rows (Inventory remote field Synergies, LevelUpSystem.
--                      SynergyClues): Deadeye complete, Bulwark in progress with a known
--                      missing piece, an undiscovered synergy as a "???" clue
if preview.args.synergies == "on" then
	C.fire("Inventory", {
		Weapons = {}, Passives = {}, Rerolls = 2, Skips = 1, WeaponSlots = 6, PassiveSlots = 6,
		Synergies = {
			{ Id = "Deadeye", Name = "Deadeye", Text = "+5% crit chance, +25% crit damage", Have = 3, Need = 3, Active = true, Pieces = { { Label = "a bow", Owned = true }, { Label = "Precision", Owned = true }, { Label = "Keen Lens or Hunter's Eye", Owned = true } } },
			{ Id = "Bulwark", Name = "Bulwark", Text = "+1 armor, +10% max HP", Have = 2, Need = 3, Active = false, Pieces = { { Label = "a close weapon", Owned = true }, { Label = "Armor", Owned = false }, { Label = "Iron Plate or Barbed Mail", Owned = true } } },
			{ Name = "???", Text = "+15% duration, +8% area", Have = 1, Need = 3, Active = false, Pieces = { { Label = "a fire weapon", Owned = true }, { Label = "???", Owned = false }, { Label = "???", Owned = false } } },
		},
	})
end
C.settle(0.5)
local LootUI = C.try("require LootUI", preview.client, "LootUI")
if LootUI then
	C.try("LootUI.OpenItems", LootUI.OpenItems)
end
C.settle(1.5)
