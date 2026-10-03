-- Real loot holds must activate optional encounters deliberately and award them once.
local C = lib("common")
local s = C.bootServer()
preview.startClient(false)
local arena = s.MapBuilder.BuildArena("Forest")
local player = game:GetService("Players").LocalPlayer
local root = Instance.new("Part")
root.Parent = workspace
local rp = { Player = player, Root = root, Alive = true, Stats = { Luck = 1 } }
local rewards, uid = 0, 0
local Loot = C.server("LootSystem")
Loot.Init({
 RunManager = {
  GetRunPlayers = function() return { rp } end, GetRunPlayer = function() return rp end,
  IsRunning = function() return true end, IsSimulating = function() return true end,
  GetRunTime = function() return 30 end, Notify = function() end, Broadcast = function() end, HoldReward = function() end,
 },
 StageManager = { GetPhase = function() return "Explore" end },
 MonetizationService = { GoldMultiplier = function() return 1 end },
 GoldSystem = { RunWallet = function() return 1000 end, SpendRunGold = function() return true end },
 ItemSystem = { Roll = function() return "HealingHerb" end, Grant = function() rewards += 1 return true, false end },
 EnemyAI = { IsBlocked = function() return false end },
 EnemySpawner = { ProgressionTime = function() return 30 end, ClampToArena = function(x, z) return x, z end, Spawn = function() uid += 1 return { Uid = uid } end },
})
Loot.Start()
local function build(kind)
 s.Config.Encounters.Types = { kind }
 s.Config.Encounters.Count = { 1, 1 }
 Loot.BuildStage(arena, 1)
 local found = {}
 for _, obj in ipairs(Loot.Objects()) do
  if obj.Type == kind or (kind == "Runes" and obj.Type == "Rune") then table.insert(found, obj) end
 end
 return found
end
local function hold(obj)
 root.Position = obj.Pos
 s.Remotes.Get("LootHold"):FireServer(obj.Id, true)
 preview.advance(0.2)
 Loot.Step(2)
end
local altar = build("Guarded")[1]
assert(altar, "guarded encounter should spawn")
root.Position = altar.Pos
Loot.Step(1)
assert(altar.State == "Dormant", "walking near the altar must not activate elites")
hold(altar)
assert(altar.State == "Guarded", "deliberate hold must activate guards")
local guards = {}
for e in pairs(altar.Guards) do table.insert(guards, e) end
for _, e in ipairs(guards) do Loot.OnGuardDown(e, true) end
assert(altar.State == "Claimable")
hold(altar)
assert(rewards == 1 and altar.State == "Claimed")
hold(altar)
assert(rewards == 1, "claimed altar cannot reward twice")
local runes = build("Runes")
assert(#runes == 3, "rune encounter needs three linked stones")
local puzzle = runes[1].Puzzle
local byRune = {}
for _, obj in ipairs(runes) do byRune[obj.Rune] = obj end
hold(byRune[puzzle.Order[2]])
assert(puzzle.Progress == 0, "wrong first rune resets sequence")
for _, id in ipairs(puzzle.Order) do hold(byRune[id]) end
assert(puzzle.Solved and rewards == 2, "solved sequence awards one run item")
hold(runes[1])
assert(rewards == 2)
local treasure = build("Treasure")[1]
assert(treasure and treasure.Price == 0, "treasure should be free")
hold(treasure)
assert(rewards == 3 and treasure.State == "Opened")
Loot.Clear()
assert(#Loot.Objects() == 0, "secrets must disappear with this run")
local Items = C.server("ItemSystem")
local ItemData = C.shared("ItemData")
Items.Init({ LevelUpSystem = { RecomputeStats = function() end }, WeaponSystem = { OnInventoryChanged = function() end } })
rp.Items, rp.ItemOrder = {}, {}
local granted, dramatic = Items.Grant(rp, ItemData.ByRarity.Common[1], "Small chest", true)
assert(granted and not dramatic, "ordinary item rewards must let combat continue")
granted, dramatic = Items.Grant(rp, ItemData.ByRarity.Legendary[1], "Rare find", true)
assert(granted and dramatic, "legendary rewards should showcase")
granted, dramatic = Items.Grant(rp, ItemData.ByRarity.Common[1], "Rune stones", true, true)
assert(granted and dramatic, "encounter finale may showcase an uncommon roll")
preview.log("PASS deliberate elites, rune order/reset, free treasure, single rewards and cleanup")
