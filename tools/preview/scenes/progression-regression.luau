-- Real-module progression assertions. Run with Lune's preview runtime, no renderer needed.
local C = lib("common")
local WeaponData = C.shared("WeaponData")
local PassiveData = C.shared("PassiveData")
local Config = C.shared("Config")
assert(WeaponData.MaxLevel == 12, "weapons must have twelve base ranks")
for _, id in ipairs(WeaponData.Order) do
	local def = WeaponData.Weapons[id]
	assert(#def.Levels == 12, id .. " needs twelve stat rows")
	for level = 2, 12 do
		assert(#WeaponData.CardLines(id, level - 1, level) > 0, id .. " has an empty rank " .. level)
	end
	assert(def.Evolution.Stats.damage > def.Levels[12].damage, id .. " evolution must strengthen damage")
end
preview.startServer()
preview.advance(1)
local XP = preview.server("XPSystem")
assert(XP.XPNeeded(1) == 42 and XP.XPNeeded(20) == 270, "early XP must make level-ups harder without timers")
assert(XP.XPNeeded(21) == 276 and XP.XPNeeded(50) == 450, "late XP costs must keep growing")
assert(XP.CoopShare() == 1, "a solo hero gets every gem's full XP")
assert(Config.XP.CoopShare[2] < 1 and Config.XP.CoopShare[3] < Config.XP.CoopShare[2], "shared gem XP must shrink with the team size")
local RM = preview.server("RunManager")
local LU = preview.server("LevelUpSystem")
local player = game:GetService("Players").LocalPlayer
preview.remote("StartRun"):FireServer("Solo")
preview.advance(2)
local rp = assert(RM.GetRunPlayer(player), "run player missing")
rp.InvulnUntil = math.huge
local coins, holds = 0, 0
local runTime = 0
local testRun = {
	GetRunPlayers = function() return { rp } end,
	GetRunPlayer = function() return rp end,
	GetRunTime = function() return runTime end,
	IsMenuPaused = function() return false end,
	IsFrozen = function() return false end,
	IsRunning = function() return true end,
	ApplyMovement = function() end,
	RefreshFrozen = function() end,
	GrantChoiceGrace = function() end,
	Notify = function() end,
	HoldReward = function(_, dramatic) if dramatic ~= false then holds += 1 end end,
}
LU.Init({ RunManager = testRun, WeaponSystem = { OnInventoryChanged = function() end },
	StageManager = { IsHolding = function() return false end, GetStage = function() return 1 end },
	GoldSystem = { AddRunGold = function(_, amount) local paid = amount * 1.35; coins += paid; return paid end },
	RunModifiers = { StatMults = function() return nil end, DifficultyMultiplier = function() return 1.35 end },
})
rp.PendingLevels, rp.Offer, rp.UpgradeCombatTime = 0, nil, 0
rp.Level = 8
LU.QueueLevels(rp, 7)
assert(rp.PendingLevels == 7 and rp.Offer and rp.Paused, "earned levels must open immediately without a timer")
assert(rp.Offer and rp.BatchRemaining == 4, "first panel must contain at most four choices")
for _, choice in ipairs(rp.Offer) do
	assert(choice.Synergy == nil and choice.SynergyReady == nil, "cards must not reveal hidden synergy recipes")
end
local panel, deadline = rp.PanelId, rp.OfferDeadline
for i = 1, 4 do
	preview.remote("LevelUpChoose"):FireServer(1)
	preview.advance(0.25)
	if i < 4 then
		assert(rp.Offer and rp.PanelId == panel and rp.OfferDeadline == deadline, "choices must share one panel and deadline")
	end
end
assert(rp.Offer and rp.Paused and rp.PendingLevels == 3 and rp.PanelId > panel and rp.BatchRemaining == 3,
	"remaining earned levels resume immediately after four conserved choices")
LU.Cancel(rp, true)
assert(rp.PendingLevels == 3 and not rp.Offer and not rp.Paused, "temporary death must preserve earned levels")
rp.Alive = false
local combatTime = rp.UpgradeCombatTime
LU.Step(100)
assert(not rp.Offer and rp.UpgradeCombatTime == combatTime, "fallen players cannot open choices")
rp.Alive = true
rp.NextUpgradeCombatTime = 0
LU.QueueLevels(rp, 4)
local timeoutPanel = rp.PanelId
rp.OfferDeadline = os.clock() - 1
LU.Step(0)
assert(not rp.Offer and not rp.Paused and rp.PendingLevels == 3 and rp.PanelId == timeoutPanel,
	"one shared deadline must resolve four choices without reopening or discarding bank")
LU.Cancel(rp)
rp.Weapons, rp.WeaponOrder, rp.Passives, rp.PassiveOrder = {}, {}, {}, {}
for _, id in ipairs({ "Whip", "MagicOrb", "Knives", "Garlic", "HolyWater", "Lightning" }) do
	rp.Weapons[id] = { Id = id, Level = 12, Evolved = true, Timer = 0, Live = {}, Growth = 0 }
	table.insert(rp.WeaponOrder, id)
end
for _, id in ipairs({ "Heart", "SpeedBoots", "Ammo", "Vacuum", "Candle", "Duplicator" }) do
	rp.Passives[id] = PassiveData.MaxLevelOf(id)
	table.insert(rp.PassiveOrder, id)
end
rp.Weapons.Whip.Evolved = false
rp.Passives.Heart = 2
rp.NextUpgradeCombatTime = 0
LU.QueueLevels(rp, 1)
for _, c in ipairs(rp.Offer or {}) do
	assert(c.Type ~= "Evolve", "rank-two partner cannot evolve")
end
LU.Cancel(rp)
rp.Passives.Heart = 3
rp.NextUpgradeCombatTime = 0
LU.QueueLevels(rp, 1)
local hasEvolution = false
for _, c in ipairs(rp.Offer or {}) do if c.Type == "Evolve" then hasEvolution = true end end
assert(hasEvolution, "rank-three partner must permit evolution")
LU.Cancel(rp)
rp.Weapons.Whip.Evolved = true
rp.Passives.Heart = PassiveData.MaxLevelOf("Heart")
rp.Passives.Candle = nil
rp.PassiveOrder[5] = "Precision"
rp.Passives.Precision = PassiveData.MaxLevelOf("Precision") - 1
local oldItems = rp.Items
rp.Items = { KeenLens = 20 }
LU.RecomputeStats(rp)
rp.NextUpgradeCombatTime = 0
LU.QueueLevels(rp, 1)
assert(rp.Offer and coins == 0, "owned passives must finish even when their stats are capped")
LU.Cancel(rp)
rp.Passives.Precision = nil
rp.PassiveOrder[5] = "Candle"
rp.Passives.Candle = PassiveData.MaxLevelOf("Candle")
rp.Items = oldItems
LU.RecomputeStats(rp)
rp.Passives.Heart = PassiveData.MaxLevelOf("Heart") - 1
rp.NextUpgradeCombatTime = 0
LU.QueueLevels(rp, 3)
assert(coins == 0 and rp.PendingLevels == 3, "weapons alone must not trigger coin conversion")
preview.remote("LevelUpChoose"):FireServer(1)
preview.advance(0.25)
assert(rp.Passives.Heart == PassiveData.MaxLevelOf("Heart") and coins == 2 * 25 * 1.35,
	"final passive must drain remaining bank as coins immediately")
coins = 0
rp.LastDownTime = 0
runTime = 1200
LU.QueueLevels(rp, 7)
assert(math.abs(coins - 7 * 25 * 1.35 * 3) < 1e-6, "post-max coins must use capped streak and tier: " .. coins)
assert(rp.PendingLevels == 0 and not rp.Offer and not rp.Paused, "post-max levels drain without chooser")
rp.LastDownTime = runTime
LU.QueueLevels(rp, 1)
assert(math.abs(coins - (7 * 25 * 1.35 * 3 + 25 * 1.35)) < 1e-6, "knockdown resets survival bonus")
LU.OpenChest(rp)
assert(holds == 0, "ordinary chest must not pause combat")
rp.Level, rp.XP, rp.XPNeeded = 20, 0, XP.XPNeeded(20)
local before = coins
XP.GiveXP(rp, 270 + 276 + 2)
assert(rp.Level == 22 and rp.XP == 2 and rp.XPNeeded == 282, "bulk XP must conserve remainder across late costs")
assert(math.abs(coins - before - 2 * 25 * 1.35) < 1e-6 and not rp.Offer and not rp.Paused,
	"future bulk XP must become coins without any panel")
preview.log("PASS: twelve ranks, harder XP, immediate choices, evolution, coins and ordinary chest")
