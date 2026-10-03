local C = lib("common")
C.bootServer()
preview.startClient(false)
local Stage = C.server("StageManager")
local player = game:GetService("Players").LocalPlayer
local rp = { Player = player, Alive = true }
local finished, endless = 0, false
local function noop() end
Stage.Init({
 RunManager = {
  GetRunPlayers = function() return { rp } end, IsRunning = function() return true end,
  IsSimulating = function() return true end, IsFrozen = function() return false end,
  GetRunTime = function() return 100 end, ApplyMovementAll = noop, Broadcast = noop,
  TravelPlayers = function() rp.PortalChoice = nil end,
  FinishFromPortal = function() finished += 1 Stage.EndRun() end,
 },
 RunModifiers = { IsEndless = function() return endless end },
 LootSystem = { BuildStage = noop, Clear = noop, TeamBonus = function() return {} end },
 EnemyAI = { SetArena = noop }, EnemySpawner = { KillInRadius = noop, DespawnAll = noop },
 XPSystem = { MagnetAll = noop, CollectAll = noop, Clear = noop },
 WeaponSystem = { ClearHostile = noop, Clear = noop },
})
local function advanceStage()
 assert(Stage.DevNextStage())
 Stage.Step(2)
 Stage.Step(2)
end
Stage.BeginRun("Forest")
for _ = 1, 4 do advanceStage() end
assert(Stage.GetStage() == 5 and finished == 0, "four clears must continue")
advanceStage()
assert(finished == 1 and Stage.GetPhase() == "None", "fifth clear must return the expedition")
endless = true
Stage.BeginRun("Forest")
for _ = 1, 5 do advanceStage() end
assert(Stage.GetStage() == 6 and finished == 1, "Endless must continue beyond five clears")
preview.log("PASS five-stage expedition boundary and unbounded Endless portals")
