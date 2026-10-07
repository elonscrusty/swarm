-- starter-bundle-regression: the Starter Bundle (docs/next/STARTER_BUNDLE.md) against the real
-- server with the mock MarketplaceService. Runs WITHOUT --studio (live DataStores, like
-- store-regression). The product id is 0 in Config, so the test sets a fake id at run time.
--   1) id 0 = hidden: no offer attribute, no prompt, no receipt handler
--   2) the offer: a new save (FirstJoin) is offered for OfferDays; BUY opens the prompt from
--      the server
--   3) mock purchase grants everything once (flag, gold, title, skin ownership); duplicate
--      receipts are acknowledged without a second grant; a failed save is not acknowledged
--   4) the card hides after the purchase (StarterOffer false, StarterOwned true) and the
--      server refuses a second prompt
--   5) the card hides after 7 days and for older accounts (FirstJoin 0)
--   6) the Pioneer skin is worn only when owned; switch off = everything off
-- Real purchases are BLOCKED offline (Studio / live server only).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
assert(not RunService:IsStudio(), "starter-bundle-regression must run without --studio (live DataStores)")

local friend = preview.addPlayer("Friend", 5101)
preview.startServer()
preview.advance(2)

local player = Players.LocalPlayer
local Config = preview.shared("Config")
local MS = preview.server("MonetizationService")
local DS = preview.server("DataService")
local SB = preview.server("StarterBundle")
local Decision = Enum.ProductPurchaseDecision
local ID = 9301
local DAY = 86400

local data = assert(DS.GetData(player), "profile missing")
local fdata = assert(DS.GetData(friend), "friend profile missing")
assert(Config.FeatureOn("StarterBundle"), "the StarterBundle switch must be on")
assert((Config.Monetization :: any).StarterBundle == 0, "the shipped id is 0 (the owner creates the product)")
assert(type(data.FirstJoin) == "number" and data.FirstJoin > 0, "a brand-new save gets FirstJoin")
assert(data.StarterBundleOwned == false, "a new save does not own the bundle")

local function prompts(): number
	return #preview.marketPrompts()
end
local function lastPrompt()
	local list = preview.marketPrompts()
	return list[#list]
end
local function buy(who)
	if who then
		preview.fireServerAs(who, "StarterBundle", "Buy")
	else
		preview.remote("StarterBundle"):FireServer("Buy")
	end
	preview.advance(2.2) -- past the double-tap guard
end
local function receipt(purchaseId, who)
	return MS._ProcessReceipt({
		PlayerId = (who or player).UserId,
		ProductId = ID,
		PurchaseId = purchaseId,
		CurrencySpent = 0,
		PlaceIdWherePurchased = 0,
	})
end
local function countId(list, id): number
	local c = 0
	for _, v in ipairs(list) do
		if v == id then
			c += 1
		end
	end
	return c
end

------------------------------------------------------------------------------------------
-- 1) id 0 = hidden
------------------------------------------------------------------------------------------
do
	SB.Publish(player)
	preview.advance(0.2)
	assert(player:GetAttribute("StarterOffer") == false, "id 0: no offer")
	local before = prompts()
	buy()
	assert(prompts() == before, "id 0: no prompt")
	MS._RebuildProducts()
	assert(receipt("sb-0") == Decision.NotProcessedYet, "id 0: no handler for the product")
	preview.log("PASS id 0 = hidden: no offer, no prompt, no handler")
end

------------------------------------------------------------------------------------------
-- 2) the offer + server prompt
------------------------------------------------------------------------------------------
;(Config.Monetization :: any).StarterBundle = ID
MS._RebuildProducts()
do
	data.FirstJoin = os.time() - DAY
	SB.Publish(player)
	assert(player:GetAttribute("StarterOffer") == true, "a new save is offered the bundle")
	local ends = player:GetAttribute("StarterEnds")
	assert(type(ends) == "number" and math.abs(ends - (data.FirstJoin + Config.StarterBundle.OfferDays * DAY)) < 2, "the offer ends OfferDays after FirstJoin")
	local before = prompts()
	buy()
	assert(prompts() == before + 1, "BUY opens one prompt")
	local p = lastPrompt()
	assert(p.kind == "PromptProductPurchase" and p.id == ID, "the prompt is the Starter Bundle product")
	assert(data.StarterBundleOwned == false, "nothing granted before the receipt")
	preview.log("PASS offer: FirstJoin window, prompt opened by the server")
end

------------------------------------------------------------------------------------------
-- 3) failed save, purchase, duplicates
------------------------------------------------------------------------------------------
do
	local gold0 = data.Gold
	preview.failDataStores(false, true)
	local attempts = Config.Data.SaveAttempts
	Config.Data.SaveAttempts = 1
	assert(receipt("sb-1") == Decision.NotProcessedYet, "an unsaved grant is not acknowledged")
	preview.failDataStores(false, false)
	Config.Data.SaveAttempts = attempts
	assert(receipt("sb-1") == Decision.PurchaseGranted, "the retry is acknowledged")
	for _ = 1, 3 do
		assert(receipt("sb-1") == Decision.PurchaseGranted, "a duplicate receipt is acknowledged")
	end
	assert(data.StarterBundleOwned == true, "the save flag is set")
	assert(data.Gold == gold0 + Config.StarterBundle.Gold, "the gold is paid exactly once: " .. (data.Gold - gold0))
	assert(countId(data.PurchaseIds, "sb-1") == 1, "the PurchaseId is recorded once")
	assert(data.Titles.Owned[Config.StarterBundle.Title] == true, "the Pioneer title is owned")
	assert(MS.OwnsSkin(player, Config.StarterBundle.Skin) == true, "the Pioneer skin is owned")
	assert(MS.OwnedSkins(player)[Config.StarterBundle.Skin] == true, "the lobby sees the skin")
	assert(not MS.OwnsSkin(friend, Config.StarterBundle.Skin), "nobody else owns the skin")
	preview.log("PASS purchase: grants flag + gold + title + skin once; duplicates and a failed save handled")
end

------------------------------------------------------------------------------------------
-- 4) the card hides after the purchase
------------------------------------------------------------------------------------------
do
	preview.advance(0.5)
	assert(player:GetAttribute("StarterOffer") == false, "the offer is gone after the purchase")
	assert(player:GetAttribute("StarterOwned") == true, "owned is published")
	local before = prompts()
	buy()
	assert(prompts() == before, "no second prompt once owned")
	preview.log("PASS after purchase: card hidden, no second prompt")
end

------------------------------------------------------------------------------------------
-- 5) 7 days and older accounts
------------------------------------------------------------------------------------------
do
	fdata.FirstJoin = os.time() - 6 * DAY
	SB.Publish(friend)
	assert(friend:GetAttribute("StarterOffer") == true, "day 6: still offered")
	fdata.FirstJoin = os.time() - (Config.StarterBundle.OfferDays * DAY + 60)
	SB.Publish(friend)
	assert(friend:GetAttribute("StarterOffer") == false, "after 7 days: hidden")
	local before = prompts()
	buy(friend)
	assert(prompts() == before, "after 7 days: the server refuses the prompt")
	fdata.FirstJoin = 0
	SB.Publish(friend)
	assert(friend:GetAttribute("StarterOffer") == false, "an older account (FirstJoin 0) is never offered")
	local old = DS.Migrate({ Version = Config.Data.SchemaVersion, Gold = 5 })
	assert(old.FirstJoin == 0 and old.StarterBundleOwned == false, "an old save loads with FirstJoin 0 and no bundle")
	preview.log("PASS window: shown for 7 days only, never for older accounts")
end

------------------------------------------------------------------------------------------
-- 6) skin wear + switch off
------------------------------------------------------------------------------------------
do
	preview.fireServerAs(friend, "EquipSkin", "Knight", Config.StarterBundle.Skin)
	preview.advance(0.3)
	assert((fdata.Skins.Knight or "Default") ~= Config.StarterBundle.Skin, "an unowned Pioneer skin is refused")
	preview.remote("EquipSkin"):FireServer("Knight", Config.StarterBundle.Skin)
	preview.advance(0.3)
	assert(data.Skins.Knight == Config.StarterBundle.Skin, "the owner can wear the Pioneer skin")
	Config.Features.StarterBundle = false
	fdata.FirstJoin = os.time()
	SB.Publish(friend)
	assert(friend:GetAttribute("StarterOffer") == false, "switch off: no offer")
	local before = prompts()
	buy(friend)
	assert(prompts() == before, "switch off: no prompt")
	Config.Features.StarterBundle = true
	preview.log("PASS skin: owned only; switch off hides everything")
end

preview.note("BLOCKED offline: a real Robux purchase needs Studio (test purchase) or the live game")
preview.log("PASS starter-bundle-regression")
