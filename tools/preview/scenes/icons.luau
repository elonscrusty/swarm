-- icons: a sheet of icon tiles through the single lookup path (UIKit.Tile -> Icons.Upgrade) and
-- the vector fallback under each picture; prints Icons.PreloadList().
--   --set keys=Vacuum,Might,Spear   which ids (default: every weapon, passive and item)
--   --set fallback=on                show the vector fallbacks only (pictures treated as not loaded)
local C = lib("common")
local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local ItemData = C.shared("ItemData")
C.startClient()
local Icons = preview.client("Icons")
local UIKit = preview.client("UIKit")
local Players = game:GetService("Players")
local keys = {}
if preview.args.keys then
	for k in string.gmatch(preview.args.keys, "[^,]+") do
		table.insert(keys, k)
	end
else
	for _, w in ipairs(WeaponData.Order) do
		table.insert(keys, w)
		table.insert(keys, WeaponData.Weapons[w].Evolution.Id)
	end
	for _, p in ipairs(PassiveData.Order) do
		table.insert(keys, p)
	end
	for _, i in ipairs(ItemData.Order) do
		table.insert(keys, i)
	end
	table.insert(keys, "Gold")
	table.insert(keys, "Heal")
end
local gui = Instance.new("ScreenGui")
gui.Name = "IconSheet"
gui.Parent = Players.LocalPlayer.PlayerGui
local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
bg.Parent = gui
local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.fromOffset(64, 64)
grid.CellPadding = UDim2.fromOffset(8, 8)
grid.Parent = bg
for _, k in ipairs(keys) do
	UIKit.Tile(bg, { Id = k, Size = 64 })
end
local list = Icons.PreloadList()
print("[icons] PreloadList: " .. #list .. " ids, first " .. tostring(list[1]) .. ", last " .. tostring(list[#list]))
C.settle(0.5)
