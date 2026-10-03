-- minimap: the in-run minimap (MiniMap.lua) with every marker kind at once: stage 2 with the
-- portal far off range (pinned to the map's edge with its pointer), two chests, a shrine and
-- the altar nearby, one teammate (eased blue disc), the Lost Caravan being defended (edge pin)
-- and a light swarm. Asserts the pooled markers are shown. Markers are driven through the
-- same replicated attributes the game uses (SwarmLoot / SwarmEvents models, SwarmState).
--   --set portal=near        the portal in range instead (no pointer)
local A = lib("arena")
local C = lib("common")
local s = A.build({ enemies = 50, seconds = 400, stage = 2, portalHint = true })
local centre = s.centre
local near = preview.args.portal == "near"
C.setState({ PortalPos = centre + (near and Vector3.new(30, 0, -25) or Vector3.new(-160, 0, -130)) })

local function marker(folderName: string, name: string, attrs)
	local folder = workspace:FindFirstChild(folderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = folderName
		folder.Parent = workspace
	end
	local m = Instance.new("Model")
	m.Name = name
	for k, v in pairs(attrs) do
		m:SetAttribute(k, v)
	end
	m.Parent = folder
	return m
end
marker("SwarmLoot", "ChestA", { Pos = centre + Vector3.new(22, 0, 18), LootKind = "Chest", State = "Idle" })
marker("SwarmLoot", "ChestB", { Pos = centre + Vector3.new(-40, 0, 35), LootKind = "Chest", State = "Idle" })
marker("SwarmLoot", "ChestOpened", { Pos = centre + Vector3.new(10, 0, -10), LootKind = "Chest", State = "Opened" })
marker("SwarmLoot", "Shrine", { Pos = centre + Vector3.new(45, 0, -30), LootKind = "Shrine", State = "Idle" })
marker("SwarmLoot", "Altar", { Pos = centre + Vector3.new(-30, 0, -45), LootKind = "Altar", State = "Idle" })
marker("SwarmEvents", "Caravan", { Pos = centre + Vector3.new(170, 0, 60), State = "Defending" })

local p = preview.addPlayer("Ava", 2)
local model = C.try("BuildCharacter Mage", s.ModelBuilder.BuildCharacter, "Mage", "Default")
if model then
	model.Name = "Ava"
	model:PivotTo(CFrame.new(centre + Vector3.new(-18, 3.5, 12)))
	model.Parent = workspace
	p.Character = model
end
p:SetAttribute("InRun", true)
p:SetAttribute("Alive", true)
p:SetAttribute("CharacterId", "Mage")
C.settle(1.5)

local MiniMap = preview.client("MiniMap")
local ui = MiniMap.Elements()
assert(ui.Holder and ui.Holder.Visible, "minimap shown in a run")
assert(ui.PortalPin.Frame.Visible, "portal marker shown")
assert(ui.PortalPin.Pointer.Visible == not near, "portal pointer only while out of range")
assert(ui.CaravanPin.Frame.Visible and ui.CaravanPin.Pointer.Visible, "defended caravan pinned to the edge")
local loot = 0
for _, f in ipairs(ui.Loot) do
	if f.Visible then loot += 1 end
end
assert(loot == 3, "two chests + a shrine shown, the opened chest hidden (got " .. loot .. ")")
assert(ui.Altar.Visible, "altar ring shown")
assert(ui.Mates[1].Visible and not ui.Mates[2].Visible, "one teammate marker")
print("[minimap] markers ok")
