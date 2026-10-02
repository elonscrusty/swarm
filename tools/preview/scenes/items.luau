-- items: the pause menu's ITEMS list (LootUI.OpenItems) with a run's items.
local A = lib("arena")
local C = lib("common")
A.build({ enemies = 60 })
local list = {}
for i, id in ipairs({ "Whetstone", "QuickGloves", "SwiftFeather", "HeartyBread", "Bandage", "KeenLens", "IronPlate", "StormCharm", "VolatileSpore", "PhoenixFeather" }) do
	table.insert(list, { Id = id, Count = (i % 3) + 1 })
end
C.fire("Items", list)
C.settle(0.5)
local LootUI = C.try("require LootUI", preview.client, "LootUI")
if LootUI then
	C.try("LootUI.OpenItems", LootUI.OpenItems)
end
C.settle(1.5)
