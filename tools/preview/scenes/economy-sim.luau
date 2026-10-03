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
