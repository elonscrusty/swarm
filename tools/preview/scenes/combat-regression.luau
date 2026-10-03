-- Assertions against real boss, terrain and hazard modules; no image renderer required.
local C = lib("common")
local BossData = C.shared("BossData")
local Config = C.shared("Config")
for id, def in pairs(BossData.Bosses) do
	assert(BossData.PhaseFor(def, 0.41) == 1, id .. " must keep opening pattern above forty percent")
	assert(BossData.PhaseFor(def, 0.39) == 2, id .. " must enhance below forty percent")
	assert(def.Phases[2].FollowUps and next(def.Phases[2].FollowUps), id .. " needs an enhanced attack combination")
	for first, second in pairs(def.Phases[2].FollowUps) do
		assert(def.Attacks[first] and def.Attacks[second], id .. " has invalid combination")
	end
end
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local player = game:GetService("Players").LocalPlayer
preview.remote("StartRun"):FireServer("Solo")
preview.advance(2)
local rp = assert(RM.GetRunPlayer(player), "run player missing")
rp.InvulnUntil = math.huge
local BossAI = preview.server("BossAI")
local Spawner = preview.server("EnemySpawner")
local Stage = preview.server("StageManager")
local savedTime, savedStage = RM.GetRunTime, Stage.GetStage
RM.GetRunTime, Stage.GetStage = function() return 5 end, function() return 5 end
assert(Spawner.ProgressionTime() == 480, "rushed later stages must still unlock varied enemy behaviors")
Stage.GetStage = function() return 1 end
assert(Spawner.ProgressionTime() == 5, "opening stage must keep gentle original enemy mix")
RM.GetRunTime, Stage.GetStage = savedTime, savedStage
for id, def in pairs(BossData.Bosses) do
	local boss = assert(Spawner.SpawnBoss(rp.Root.Position + Vector3.new(35, 0, 0), id))
	boss.HP, boss.BossState, boss.BossTimer = boss.MaxHP * 0.39, "Chase", 0
	BossAI.Step(boss, 0)
	assert(boss.PhaseIndex == 2 and boss.BossState == "Roar", id .. " must announce phase before enhancing")
	local first, second = next(def.Phases[2].FollowUps)
	local index = assert(table.find(def.Phases[2].Cycle, first))
	boss.BossState, boss.BossTimer, boss.BossCycle = "Chase", 0, index - 1
	BossAI.Step(boss, 0)
	assert(boss.BossFollowup == second, id .. " must queue one readable follow-up")
	boss.BossState, boss.BossTimer = "Recover", 0
	BossAI.Step(boss, 0)
	assert(not boss.BossFollowup and boss.BossState ~= "Chase", id .. " must start follow-up after full recovery")
	BossAI.StartCollapse(boss, rp)
	assert(not boss.BossFollowup, "collapse must cancel queued attacks")
	Spawner.Despawn(boss)
end
-- Exercise the real slow producer with a combat clock far from wall time.
local Weapons = preview.server("WeaponSystem")
local AI = preview.server("EnemyAI")
local slowed = assert(Spawner.Spawn("Ghost", rp.Root.Position + Vector3.new(5, 0, 0)))
AI.Step(0.01)
RM.GetRunTime = function() return 500 end
rp.Weapons = { Garlic = { Id = "Garlic", Level = 12, Evolved = false, Timer = 0, Live = {}, Growth = 0 } }
rp.WeaponOrder = { "Garlic" }
Weapons.Step(0.01)
assert(slowed.SlowUntil and slowed.SlowUntil > 500 and slowed.SlowUntil < 502,
	"weapon slow expiry must use the same active clock as enemy movement")
RM.GetRunTime = savedTime
Spawner.Despawn(slowed)
local Hazards = preview.server("Hazards")
local terrain = preview.server("BiomeHazards")
local running, time, hits, cause = true, 0, 0, nil
local ctx = {
	RunManager = { IsSimulating = function() return running end, GetRunTime = function() return time end,
		GetRunPlayers = function() return { rp } end, GetRunPlayer = function() return rp end,
		ApplyMovement = function() end, DamagePlayer = function(_, _, why) hits += 1; cause = why end },
	EnemySpawner = { Active = {} },
	StageManager = { GetStage = function() return 3 end, GetPhase = function() return "Explore" end, DamageMult = function() return 1 end },
}
Hazards.Clear()
Hazards.Init(ctx)
terrain.Init(ctx)
terrain.SetArena({ Name = "Lava", Hazards = { { Kind = "Lava", Pos = rp.Root.Position, Radius = 8 } } })
terrain.Step(0.1)
assert(hits == 0, "lava entry grace must be respected")
running = false
terrain.Step(30)
Hazards.Step(30)
assert(hits == 0, "paused lava and hazards cannot damage or age")
running, time = true, 0.3
terrain.Step(0.1)
assert(hits == 1 and cause == "Lava", "lava must resume with readable damage cause")
terrain.Clear()
local stage = 1
ctx.StageManager.GetStage = function() return stage end
terrain.SetArena({ Name = "Snow", Hazards = {} })
terrain.Step(Config.Enemies.StageHazards.Every)
assert(Hazards.Count() == 0, "gentle opening cannot create later-stage eruptions")
stage = 3
terrain.Step(Config.Enemies.StageHazards.Every)
assert(Hazards.Count() == 1, "later stages must add a telegraphed movement challenge")
terrain.Clear()
assert(Hazards.Count() == 0, "stage travel must cancel biome warnings and damage")
Hazards.Patch(rp.Root.Position, 6, 0, 4, 1, 3, "Boss", "acid")
Hazards.Step(0.1)
assert(cause == "Acid pool", "patch damage needs readable cause")
local before = hits
running = false
time = 20
Hazards.Step(20)
assert(hits == before and Hazards.Count() == 1, "patch life and tick must freeze on pause")
running, time = true, 0.5
Hazards.Step(0.1)
assert(hits == before, "patch cooldown must not expire during wall-clock pause")
for _ = 1, Config.Enemies.MaxHazards + 8 do
	Hazards.Strike(rp.Root.Position, 3, 2, 1, { Cause = "Test eruption" })
end
assert(Hazards.Count() <= Config.Enemies.MaxHazards, "combined hazard count must remain bounded")
Hazards.Clear()
terrain.Clear()
preview.log("PASS: six enhanced boss patterns, phase boundary, pause-safe terrain/hazards, causes and caps")
