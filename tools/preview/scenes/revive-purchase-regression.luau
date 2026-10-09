-- revive-purchase-regression (studio review SW-07, stream R5): the paid revive's purchase states on the
-- REAL server (RunManager eliminate / RequestRevivePurchase / OnRevivePromptFinished /
-- OnReviveTokenGranted, MonetizationService receipts). Runs WITHOUT --studio (live-server rules).
--   A  elimination offers the revive with its real benefit (HP share, protection, clear radius, one
--      per run) and does NOT open Roblox's dialog by itself
--   B  REVIVE tap (ReviveBuy) opens exactly one dialog; a second tap while it is open opens none;
--      the offer's clock waits while the dialog is open
--   C  cancelled: run unchanged (not revived, no token, still awaiting, time left restored), the
--      player can tap again
--   D  bought: Pending until the receipt; NO THANKS is ignored while pending; the receipt revives
--      once ("Fulfilled"); a retried receipt grants nothing more
--   E  pending without a receipt: the offer ends honestly; a late receipt is kept / spent once
--   F  unavailable (the run's paid revive was used, or no product): no offer, ReviveBuy opens nothing
--   G  junk ReviveBuy outside an offer: nothing
-- Lune sim, NOT Studio: prints PASS / FAIL lines.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer
assert(not RunService:IsStudio(), "run without --studio")

preview.startServer()
preview.advance(1)
local Config = preview.shared("Config")
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local MS = preview.server("MonetizationService")
local data = assert(DS.GetData(player), "profile missing")
local Decision = Enum.ProductPurchaseDecision
local REVIVE = Config.Monetization.Products.Revive

local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

local offers = {}
preview.remote("ReviveOffer").OnClientEvent:Connect(function(msg)
	table.insert(offers, msg)
end)
local function lastOffer()
	return offers[#offers] or {}
end
local function prompts(): number
	local n = 0
	for _, p in ipairs(preview.marketPrompts()) do
		if p.id == REVIVE then
			n += 1
		end
	end
	return n
end
local n = 0
local function receipt(purchaseId)
	n += 1
	return MS._ProcessReceipt({ PlayerId = player.UserId, ProductId = REVIVE, PurchaseId = purchaseId or ("rv-" .. n), CurrencySpent = 0, PlaceIdWherePurchased = 0 })
end
local function startSolo()
	preview.advance(Config.Run.ResultsSeconds + 2)
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(3)
	local rp = assert(RM.GetRunPlayer(player), "run player missing")
	rp.RevivesLeft = 0
	rp.InvulnUntil = 0
	return rp
end
local function fall(rp)
	rp.InvulnUntil = 0
	rp.HitProtectUntil = 0
	rp.Paused, rp.RewardUntil = false, nil
	RM.DamagePlayer(rp, 1e7, "test")
	preview.advance(0.2)
end
local function finished(purchased: boolean)
	preview.marketEvent("PromptProductPurchaseFinished", player.UserId, REVIVE, purchased)
	preview.advance(0.2)
end

data.ReviveTokens = 0
-- A
local rp = startSolo()
local p0 = prompts()
fall(rp)
local o = lastOffer()
check(rp.AwaitingRevive and not rp.Alive, "A elimination opens the revive offer")
check(prompts() == p0, "A the offer does not open Roblox's dialog by itself (" .. (prompts() - p0) .. " prompts)")
check(o.ProductId == REVIVE and o.HPShare == Config.Player.ReviveHPFraction and o.Protect == Config.Player.ReviveInvulnSeconds and o.PerRun == 1 and o.ClearRadius == Config.Player.ReviveClearRadius,
	"A the offer carries the real benefit (HP " .. tostring(o.HPShare) .. ", protect " .. tostring(o.Protect) .. ", per run " .. tostring(o.PerRun) .. ")")

-- B
preview.remote("ReviveBuy"):FireServer()
preview.advance(0.2)
check(prompts() == p0 + 1 and lastOffer().State == "Prompting", "B REVIVE tap opens one dialog (Prompting)")
preview.advance(0.6)
preview.remote("ReviveBuy"):FireServer()
preview.advance(0.2)
check(prompts() == p0 + 1, "B a second tap while the dialog is open opens no other")
preview.advance(Config.Monetization.RevivePromptSeconds + 3)
check(rp.AwaitingRevive and not rp.Eliminated, "B the offer's clock waits while the dialog is open")

-- C
local tokens0 = data.ReviveTokens
finished(false)
o = lastOffer()
check(o.State == "Cancelled" and rp.AwaitingRevive and not rp.Alive and data.ReviveTokens == tokens0 and not rp.ProductReviveUsed, "C cancelled: run unchanged, still on the offer, nothing granted")
check((o.Seconds or 0) >= 3.5 and (o.Seconds or 0) <= Config.Monetization.RevivePromptSeconds + 0.5, "C the offer runs on with its time left (" .. tostring(o.Seconds) .. " s)")
preview.advance(1.6) -- the ReviveBuy limiter (2 / s)
preview.remote("ReviveBuy"):FireServer()
preview.advance(0.2)
check(prompts() == p0 + 2 and lastOffer().State == "Prompting", "C after a cancel the player can tap REVIVE again")

-- D
finished(true)
check(lastOffer().State == "Pending" and rp.AwaitingRevive and not rp.Alive, "D Roblox says bought: Pending, not revived yet")
preview.remote("ReviveDecline"):FireServer()
preview.advance(0.3)
check(rp.AwaitingRevive and not rp.Eliminated, "D NO THANKS is ignored while the purchase is pending")
check(receipt("rv-D") == Decision.PurchaseGranted, "D the receipt is acknowledged")
preview.advance(0.3)
o = lastOffer()
check(rp.Alive and rp.ProductReviveUsed and data.ReviveTokens == 0 and o.Close == true and o.State == "Fulfilled", "D the receipt revives once and closes the offer as Fulfilled")
check(math.abs(rp.HP - rp.Stats.MaxHP * Config.Player.ReviveHPFraction) < 1, "D back with the offered HP share (" .. tostring(rp.HP) .. ")")
check(receipt("rv-D") == Decision.PurchaseGranted and data.ReviveTokens == 0 and rp.Alive, "D a retried receipt grants nothing more")

-- F (the run's paid revive is used): next fall, no offer, a tap opens nothing
local before = #offers
fall(rp)
check(not rp.AwaitingRevive and not rp.Alive, "F one paid revive per run: no second offer")
local pf = prompts()
preview.remote("ReviveBuy"):FireServer()
preview.advance(0.3)
check(prompts() == pf, "F unavailable: ReviveBuy opens no dialog")
local offeredAgain = false
for i = before + 1, #offers do
	if offers[i].Seconds and not offers[i].State and not offers[i].Close then
		offeredAgain = true
	end
end
check(not offeredAgain, "F no new offer sent")
if not RM.IsRunning() or rp.Returned then
	-- solo defeat ended the run
else
	RM.AbandonRun(rp)
end
preview.advance(1)

-- E
rp = startSolo()
fall(rp)
preview.advance(1.6)
preview.remote("ReviveBuy"):FireServer()
preview.advance(0.2)
finished(true)
check(lastOffer().State == "Pending", "E pending after Roblox confirms")
preview.advance(Config.Monetization.RevivePendingSeconds + 2)
check(not rp.AwaitingRevive and not rp.Alive and data.ReviveTokens == 0, "E no receipt: the offer ends, nothing claimed as revived")
check(receipt("rv-E") == Decision.PurchaseGranted, "E the late receipt is acknowledged")
preview.advance(0.3)
check(data.ReviveTokens == 1 or rp.ProductReviveUsed, "E the late purchase is kept as one token (or spent once)")
check(receipt("rv-E") == Decision.PurchaseGranted and (data.ReviveTokens <= 1), "E a retried late receipt adds nothing")

-- G junk (outside a run / no offer)
local pg = prompts()
preview.advance(1.6)
preview.remote("ReviveBuy"):FireServer("junk", 123, { 1 })
preview.advance(0.3)
check(prompts() == pg, "G ReviveBuy without an open offer opens nothing")

preview.log(fails == 0 and "PASS revive-purchase-regression" or ("FAIL revive-purchase-regression: " .. fails .. " failed"))
