-- Real economy and receipt modules with deterministic storage failures.
local C = lib("common")
local player = game:GetService("Players").LocalPlayer
local Config = C.shared("Config")
local Gold = preview.server("GoldSystem")
local Monetization = preview.server("MonetizationService")
local data = { Gold = 1000, PurchaseIds = {} }
local profile = { Data = data }
local saved = false
local saveCalls = 0
local DS = {
	GetData = function() return data end,
	GetProfile = function() return profile end,
	HasPurchase = function(_, id) return table.find(data.PurchaseIds, id) ~= nil end,
	RecordPurchase = function(_, id) table.insert(data.PurchaseIds, id) end,
	ForceSave = function() saveCalls += 1; return saved end,
	IsMemoryOnly = function() return false end,
}
local context = {
	DataService = DS,
	MonetizationService = { GoldMultiplier = function() return 1 end },
	RunModifiers = { GoldMult = function() return 1 end },
	GoldSystem = { SyncProfile = function() end },
	RunManager = { Notify = function() end },
}
Monetization.Init(context)
local receipt = { PlayerId = player.UserId, ProductId = Config.Monetization.Products.Gold500, PurchaseId = "retry-save" }
local processReceipt = game:GetService("MarketplaceService").ProcessReceipt
for _, field in ipairs({ "Released", "LockLost" }) do
	profile[field] = true
	assert(processReceipt(receipt) == Enum.ProductPurchaseDecision.NotProcessedYet, "unowned profile must defer receipt")
	assert(data.Gold == 1000 and #data.PurchaseIds == 0 and saveCalls == 0, "handoff receipt must not mutate profile")
	profile[field] = false
end
assert(processReceipt(receipt) == Enum.ProductPurchaseDecision.NotProcessedYet, "failed save must defer receipt")
assert(data.Gold == 1500, "first receipt grants once")
assert(processReceipt(receipt) == Enum.ProductPurchaseDecision.NotProcessedYet, "retry must not acknowledge unsaved reward")
assert(data.Gold == 1500, "retry must not grant twice")
saved = true
assert(processReceipt(receipt) == Enum.ProductPurchaseDecision.PurchaseGranted, "durable retry acknowledges")
assert(saveCalls == 3, "each attempt must prove persistence")
preview.log("PASS receipt retry durability")

Gold.Init(context)
local rp = { Player = player, RunId = "economy-test", Gold = 0, GoldSpent = 0 }
Gold.BeginRun(rp)
Gold.AddRunGold(rp, 200)
assert(data.Gold == 1500, "run earnings must not mix with savings or purchases")
assert(Gold.SpendRunGold(rp, 40), "can spend run earnings")
assert(not Gold.SpendRunGold(rp, 161), "cannot spend savings in a run")
data.Gold += 500 -- a purchased pack during combat
local result = Gold.SettleRun(rp, false, 0)
assert(result.Retained == 56 and result.Lost == 104, "early defeat retains 35% of unspent earnings")
assert(data.Gold == 2056, "defeat preserves bought and old gold")
Gold.SettleRun(rp, false, 0)
assert(data.Gold == 2056, "settlement is idempotent")
local nextRun = { Player = player, RunId = "extraction-test", Gold = 0, GoldSpent = 0 }
Gold.BeginRun(nextRun)
Gold.AddRunGold(nextRun, 100)
Gold.SettleRun(nextRun, true, 1)
assert(data.Gold == 2156, "safe extraction retains all earnings")
assert(data.RunEscrow == nil, "completed ledger clears")
data.RunEscrow = { Id = "crashed", Gold = 100, Stages = 2 }
assert(Gold.RecoverEscrow(data) == 65, "crash recovery retains stage-based earnings")
assert(Gold.RecoverEscrow(data) == 0, "crash recovery runs once")
assert(data.Gold == 2221, "crash recovery preserves separate balance")
preview.log("PASS escrow spending, retention, purchases and repeated settlement")

-- survival gold (owner): 40 per whole minute up to 30, straight to the save, never in the
-- run purse and never cut by the loss rule
assert(Config.Gold.KillGoldChance == 0.25 and Config.Gold.StageClearBonus == 300, "owner gold income values")
assert(Config.Gold.SurvivalPerMinute == 40 and Config.Gold.SurvivalMaxMinutes == 30, "survival gold values")
local mult = Gold.PublishGoldMult(player)
local survivalRun = { Player = player, RunId = "survival-test", Gold = 0, GoldSpent = 0 }
Gold.BeginRun(survivalRun)
Gold.AddRunGold(survivalRun, 100)
local before = data.Gold
local walletBefore = Gold.RunWallet(survivalRun)
local settled = Gold.SettleRun(survivalRun, false, 0, 4 * 60 + 59)
local escrowKept = math.floor(math.floor(100 * mult + 0.5) * 0.35)
assert(walletBefore == math.floor(100 * mult + 0.5), "survival gold never enters the run purse")
assert(settled.Survival == math.floor(160 * mult + 0.5), "4 min 59 s pays 4 whole minutes: " .. tostring(settled.Survival))
assert(settled.Retained == escrowKept and data.Gold == before + escrowKept + settled.Survival, "survival gold is kept in full on a loss")
assert(Gold.SettleRun(survivalRun, false, 0, 600).Survival == settled.Survival and data.Gold == before + escrowKept + settled.Survival, "survival gold is paid once")
assert(Gold.SurvivalGold(player, 3 * 3600) == math.floor(1200 * mult + 0.5), "survival gold stops at 30 minutes")
assert(Gold.SurvivalGold(player, 59) == 0 and Gold.SurvivalGold(player, 0 / 0) == 0 and Gold.SurvivalGold(player, nil) == 0, "no survival gold under a minute or for bad input")
preview.log("PASS survival gold (per minute, capped, outside the purse and the loss rule)")
