-- store-regression: the cosmetic store (docs/features/STORE.md) against the real server
-- with a mock MarketplaceService. Runs WITHOUT --studio (live DataStores, like safety-sim).
-- Store ids are 0 in Config, so the test sets fake ids at run time (never shipped).
--   1) purchase success: StoreBuy opens the prompt FROM THE SERVER, the receipt grants
--      the look once; a duplicate receipt is acknowledged without a second grant
--   2) cancel: the prompt closed without a purchase -> calm line, nothing granted
--   3) failure: the save fails -> not acknowledged; the retry grants once
--   4) refusals: id 0 ("Coming soon"), already owned, malformed payloads, switch off
--   5) equip: owned only, right kind, weapon-mastery glows refused, attributes published
--   6) gift: server-checked target, granted into the recipient's save; refused for self /
--      unknown / owner / a pass / a hero; a gift to someone who LEFT goes to the buyer;
--      a failed recipient save retries to the same recipient; a stale target is ignored
--   7) Supporter pass: the purchase signal sets Supporter + the plate; earned looks from
--      the save's stats (never for a DEV-boosted profile); early hero unlock (if shipped)
-- Every check errors on failure; each section logs PASS.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
assert(not RunService:IsStudio(), "store-regression must run without --studio (live DataStores)")

local friend = preview.addPlayer("Friend", 5001)
local gone = preview.addPlayer("Gone", 5002)
preview.startServer()
preview.advance(2)

local player = Players.LocalPlayer
local Config = preview.shared("Config")
local MS = preview.server("MonetizationService")
local DS = preview.server("DataService")
local Store = preview.server("StoreService")
local CharacterData = preview.shared("CharacterData")
local Decision = Enum.ProductPurchaseDecision

assert(Config.FeatureOn("Store"), "the Store switch must be on")
local IDS = { Trail_Ember = 9001, Pet_Fox = 9002, Emote_Cheer = 9003, Plate_Gold = 9004, Dais_Obsidian = 9005, Burst_Void = 9006 }
for k, v in pairs(IDS) do
	Config.Monetization.Cosmetics[k] = v
end
Config.Monetization.CosmeticPasses.Supporter = 9101
local heroShipped = CharacterData.Characters.Archer ~= nil
if heroShipped then
	Config.Monetization.HeroUnlocks.Archer = 9201
end
MS._RebuildProducts()

local data = assert(DS.GetData(player), "profile missing")
local fdata = assert(DS.GetData(friend), "friend profile missing")
assert(DS.GetData(gone), "second profile missing")

local answers = {}
preview.remote("StoreResult").OnClientEvent:Connect(function(r)
	table.insert(answers, r)
end)
local function lastAnswer(): string
	local r = answers[#answers]
	return r and r.Text or ""
end

local function prompts(): number
	return #preview.marketPrompts()
end
local function lastPrompt()
	local list = preview.marketPrompts()
	return list[#list]
end

local function buy(itemId, target)
	preview.remote("StoreBuy"):FireServer(itemId, target)
	preview.advance(0.6)
end
local function buyAs(who, itemId, target)
	preview.fireServerAs(who, "StoreBuy", itemId, target)
	preview.advance(0.6)
end
local function equip(kind, id)
	preview.remote("StoreEquip"):FireServer(kind, id)
	preview.advance(0.3)
end

local n = 0
local function receipt(productId, who, purchaseId)
	n += 1
	return MS._ProcessReceipt({
		PlayerId = (who or player).UserId,
		ProductId = productId,
		PurchaseId = purchaseId or ("store-" .. n),
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
-- 1) purchase success + duplicate receipt
------------------------------------------------------------------------------------------
do
	local before = prompts()
	buy("Trail_Ember")
	assert(prompts() == before + 1, "StoreBuy must open one prompt")
	local p = lastPrompt()
	assert(p.kind == "PromptProductPurchase" and p.id == IDS.Trail_Ember, "the prompt is the Trail_Ember product")
	assert(not data.Cosmetics.Owned.Trail_Ember, "nothing granted before the receipt")
	assert(receipt(IDS.Trail_Ember, nil, "s-1") == Decision.PurchaseGranted, "a store product is granted")
	assert(data.Cosmetics.Owned.Trail_Ember == true, "the look is in the save")
	for _ = 1, 3 do
		assert(receipt(IDS.Trail_Ember, nil, "s-1") == Decision.PurchaseGranted, "a duplicate receipt is acknowledged")
	end
	assert(countId(data.PurchaseIds, "s-1") == 1, "the PurchaseId is recorded once")
	preview.advance(0.5)
	preview.log("PASS purchase: server prompt, receipt grants once, duplicate receipts acknowledged without a second grant")
end

------------------------------------------------------------------------------------------
-- 2) cancel
------------------------------------------------------------------------------------------
do
	local before = #answers
	buy("Pet_Fox")
	assert(lastPrompt().id == IDS.Pet_Fox, "Pet_Fox prompt")
	preview.marketEvent("PromptProductPurchaseFinished", player.UserId, IDS.Pet_Fox, false)
	preview.advance(0.3)
	assert(#answers > before and string.find(lastAnswer(), "Nothing was charged") ~= nil, "a cancel shows a calm line: " .. lastAnswer())
	assert(not data.Cosmetics.Owned.Pet_Fox, "a cancel grants nothing")
	preview.log("PASS cancel: calm line, nothing granted")
end

------------------------------------------------------------------------------------------
-- 3) failure (save fails) + retry
------------------------------------------------------------------------------------------
do
	preview.failDataStores(false, true)
	local attempts = Config.Data.SaveAttempts
	Config.Data.SaveAttempts = 1
	assert(receipt(IDS.Pet_Fox, nil, "s-2") == Decision.NotProcessedYet, "an unsaved grant is not acknowledged")
	preview.failDataStores(false, false)
	assert(receipt(IDS.Pet_Fox, nil, "s-2") == Decision.PurchaseGranted, "the retry is acknowledged")
	assert(data.Cosmetics.Owned.Pet_Fox == true and countId(data.PurchaseIds, "s-2") == 1, "granted once")
	Config.Data.SaveAttempts = attempts
	assert(receipt(424242) == Decision.NotProcessedYet, "an unknown product is never acknowledged")
	preview.log("PASS failure: failed save not acknowledged, retry grants once, unknown product refused")
end

------------------------------------------------------------------------------------------
-- 4) refusals
------------------------------------------------------------------------------------------
do
	local before = prompts()
	buy("Trail_Frost") -- id 0
	assert(prompts() == before and lastAnswer() == "Coming soon.", "id 0 = Coming soon, no prompt")
	buy("Trail_Ember") -- owned
	assert(prompts() == before and string.find(lastAnswer(), "own this") ~= nil, "owned = no prompt")
	buy("Trail_Leaf") -- earned, not sold
	buy("Trail_None")
	buy("Title_Nope")
	for _, bad in ipairs({ { nil }, { {} }, { 12 }, { string.rep("x", 200) }, { "Pet_Owl", "5001" }, { "Pet_Owl", 1.5 }, { "Pet_Owl", 0 / 0 }, { "Pet_Owl", math.huge } }) do
		preview.remote("StoreBuy"):FireServer(bad[1], bad[2])
		preview.advance(0.6)
	end
	for _, bad in ipairs({ { nil, nil }, { "Trail", 5 }, { {}, "x" }, { "Skin", "Knight_Crimson" }, { "Title", "Title_X" }, { "Trail", string.rep("y", 100) } }) do
		preview.remote("StoreEquip"):FireServer(bad[1], bad[2])
		preview.advance(0.3)
	end
	preview.remote("StoreEmote"):FireServer({})
	assert(prompts() == before, "no malformed request opens a prompt")
	Config.Features.Store = false
	buy("Pet_Owl")
	equip("Trail", "")
	assert(prompts() == before and data.Cosmetics.Equipped.Trail == "", "switch off: nothing happens")
	Config.Features.Store = true
	preview.log("PASS refusals: Coming soon, owned, not for sale, malformed payloads, switch off")
end

------------------------------------------------------------------------------------------
-- 5) equip
------------------------------------------------------------------------------------------
do
	equip("Trail", "Trail_Ember")
	assert(data.Cosmetics.Equipped.Trail == "Trail_Ember" and player:GetAttribute("CosTrail") == "Trail_Ember", "owned trail worn + published")
	equip("Pet", "Pet_Owl")
	assert(data.Cosmetics.Equipped.Pet == "" , "an unowned pet is refused")
	equip("Pet", "Trail_Ember")
	assert(data.Cosmetics.Equipped.Pet == "", "a look of another kind is refused")
	equip("Pet", "Pet_Fox")
	assert(player:GetAttribute("CosPet") == "Pet_Fox", "owned pet worn")
	local CosmeticData = preview.shared("CosmeticData")
	for _, e in ipairs(CosmeticData.OfKind("Trail")) do
		if e.Weapon then
			equip("Trail", e.Id)
			assert(data.Cosmetics.Equipped.Trail == "Trail_Ember", "a weapon mastery glow never goes in the Trail slot")
			break
		end
	end
	equip("Trail", "Trail_None")
	assert(data.Cosmetics.Equipped.Trail == "" and player:GetAttribute("CosTrail") == "", "None takes it off")
	-- a forged save entry for an unknown id never shows
	data.Cosmetics.Equipped.Burst = "Burst_Void"
	Store.Apply(player)
	assert(player:GetAttribute("CosBurst") == "", "a worn id the player does not own is not published")
	data.Cosmetics.Equipped.Burst = ""
	preview.log("PASS equip: owned only, right kind, no weapon glows, None, forged worn ids hidden")
end

------------------------------------------------------------------------------------------
-- 6) gifts
------------------------------------------------------------------------------------------
do
	local before = prompts()
	buy("Emote_Cheer", player.UserId)
	assert(prompts() == before and string.find(lastAnswer(), "Pick a player") ~= nil, "no gift to yourself")
	buy("Emote_Cheer", 777777)
	assert(prompts() == before, "no gift to someone not in the server")
	buy("Plate_Supporter", friend.UserId)
	assert(prompts() == before and string.find(lastAnswer(), "Passes") ~= nil, "a pass can't be gifted")
	fdata.Cosmetics.Owned.Plate_Ember = true
	Config.Monetization.Cosmetics.Plate_Ember = 9007
	MS._RebuildProducts()
	buy("Plate_Ember", friend.UserId)
	assert(prompts() == before and string.find(lastAnswer(), "owns this") ~= nil, "no gift of a look they own")
	-- a real gift
	buy("Emote_Cheer", friend.UserId)
	assert(prompts() == before + 1 and lastPrompt().id == IDS.Emote_Cheer, "gift prompt (server side)")
	assert(receipt(IDS.Emote_Cheer, nil, "g-1") == Decision.PurchaseGranted, "gift receipt granted")
	assert(fdata.Cosmetics.Owned.Emote_Cheer == true, "the recipient owns it")
	assert(not data.Cosmetics.Owned.Emote_Cheer, "the buyer does not")
	assert(countId(data.PurchaseIds, "g-1") == 1, "the buyer's PurchaseIds hold the receipt")
	assert(receipt(IDS.Emote_Cheer, nil, "g-1") == Decision.PurchaseGranted and not data.Cosmetics.Owned.Emote_Cheer, "a duplicate gift receipt changes nothing")
	-- the friend cannot spoof: equip something not owned, or claim through a remote
	preview.fireServerAs(friend, "StoreEquip", "Pet", "Pet_Drake")
	preview.advance(0.3)
	assert(fdata.Cosmetics.Equipped.Pet == "" and not fdata.Cosmetics.Owned.Pet_Drake, "no ownership from a client call")
	preview.fireServerAs(friend, "StoreEquip", "Emote", "Emote_Cheer")
	preview.advance(0.3)
	assert(friend:GetAttribute("CosEmote") == "Emote_Cheer", "the gift can be worn")
	-- a later purchase of the same product by the buyer, with no gift picked, is the buyer's
	buy("Emote_Cheer")
	assert(receipt(IDS.Emote_Cheer, nil, "g-own") == Decision.PurchaseGranted and data.Cosmetics.Owned.Emote_Cheer == true, "no target = the buyer's own")
	-- a stale target is ignored (older than GiftSeconds)
	buy("Burst_Void", friend.UserId)
	preview.advance((Config.Store.GiftSeconds or 300) + 1)
	assert(receipt(IDS.Burst_Void, nil, "g-stale") == Decision.PurchaseGranted, "stale gift receipt granted")
	assert(data.Cosmetics.Owned.Burst_Void == true and not fdata.Cosmetics.Owned.Burst_Void, "a stale gift target goes to the buyer")
	-- recipient save fails: not acknowledged; the retry goes to the same recipient
	buy("Dais_Obsidian", friend.UserId)
	preview.failDataStores(false, true)
	local attempts = Config.Data.SaveAttempts
	Config.Data.SaveAttempts = 1
	assert(receipt(IDS.Dais_Obsidian, nil, "g-2") == Decision.NotProcessedYet, "recipient save failed: retry later")
	preview.failDataStores(false, false)
	Config.Data.SaveAttempts = attempts
	assert(receipt(IDS.Dais_Obsidian, nil, "g-2") == Decision.PurchaseGranted, "the retry is acknowledged")
	assert(fdata.Cosmetics.Owned.Dais_Obsidian == true and not data.Cosmetics.Owned.Dais_Obsidian, "the retry went to the same recipient")
	-- gift to someone who left
	buy("Plate_Gold", gone.UserId)
	assert(lastPrompt().id == IDS.Plate_Gold, "gift prompt for the second friend")
	preview.removePlayer(gone)
	preview.advance(0.5)
	assert(receipt(IDS.Plate_Gold, nil, "g-3") == Decision.PurchaseGranted, "a gift to someone who left is acknowledged")
	assert(data.Cosmetics.Owned.Plate_Gold == true, "the buyer keeps it")
	-- a hero can't be gifted
	buy("Hero_Archer", friend.UserId)
	assert(prompts() == before + 5, "no hero gift prompt (prompts: " .. prompts() - before .. ")")
	preview.log("PASS gifts: server-checked target, recipient save, no spoofing, self / unknown / pass / owner / hero refused, stale target, retry to the same recipient, recipient left -> buyer")
end

------------------------------------------------------------------------------------------
-- 7) Supporter pass, earned looks, hero unlock
------------------------------------------------------------------------------------------
do
	assert(player:GetAttribute("Supporter") ~= true, "not a supporter yet")
	buy("Plate_Supporter")
	assert(lastPrompt().kind == "PromptGamePassPurchase" and lastPrompt().id == 9101, "the Supporter pass prompt")
	preview.marketEvent("PromptGamePassPurchaseFinished", player, 9101, true)
	preview.advance(0.5)
	assert(player:GetAttribute("Supporter") == true and data.Supporter == true, "Supporter after the pass purchase")
	equip("Nameplate", "Plate_Supporter")
	assert(player:GetAttribute("CosPlate") == "Plate_Supporter", "the Supporter plate can be worn")
	-- earned
	data.Stats.Wins = 10
	equip("Sync")
	assert(data.Cosmetics.Owned.Pet_Slime == true and data.Cosmetics.Owned.Emote_Bow == true, "earned looks recorded from the save")
	equip("Pet", "Pet_Slime")
	assert(player:GetAttribute("CosPet") == "Pet_Slime", "earned pet worn")
	fdata.Stats.Wins = 10
	fdata.DevBoosted = true
	preview.fireServerAs(friend, "StoreEquip", "Pet", "Pet_Slime")
	preview.advance(0.3)
	assert(not fdata.Cosmetics.Owned.Pet_Slime and friend:GetAttribute("CosPet") == "", "a DEV-boosted profile earns nothing")
	if heroShipped then
		buy("Hero_Archer")
		assert(lastPrompt().id == 9201, "hero unlock prompt")
		data.OwnedCharacters.Archer = nil
		assert(receipt(9201, nil, "h-1") == Decision.PurchaseGranted and data.OwnedCharacters.Archer == true, "early hero unlock sets OwnedCharacters")
	else
		preview.note("Archer not in CharacterData (NewHeroes off): hero unlock purchase skipped")
	end
	local before = prompts()
	buy("Hero_Knight")
	assert(prompts() == before, "a hero not on the list is never sold")
	preview.log("PASS supporter pass, earned looks (not for DEV-boosted), early hero unlock")
end

preview.log("PASS store-regression")
