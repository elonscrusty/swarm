-- receipt-regression: developer-product receipts, game-pass entitlement and the profile
-- lifecycle against the real server modules (MonetizationService, DataService, StoreService,
-- RunManager) with the mock live DataStore (docs/redesign/continuation/COMMERCE_AUDIT.md).
-- Runs WITHOUT --studio (live store rules). Balances and the stored ledger are asserted, not
-- constants. Prints PASS / FAIL per check.
--   1) cancelled prompt grants nothing; a paid prompt close never grants (pending line only)
--   2) one product, two distinct PurchaseIds -> two grants; a replayed PurchaseId -> one
--   3) save failure -> NotProcessedYet, no second credit on the retries, live effect only
--      after the commit; unknown product / malformed info -> NotProcessedYet
--   4) revive product: a durable token; consuming it waits for the saved receipt
--   5) concurrent callbacks for one player (slow DataStore): one grant per PurchaseId
--   6) player left before / during fulfilment -> fulfillable later, granted exactly once
--   7) a second server took the save and granted the receipt -> this server grants nothing
--   8) receipt history keeps recent ids past the old 150 cap (no replay window by count)
--   9) passes: lookup outage keeps a recorded entitlement, a failure is not "not owned",
--      a confirmed "no" clears the record, negative answers are asked again, the server
--      purchase event grants (a cancel / unknown pass does not)
--  10) lifecycle: loading / failed / released states; no empty profile after a failed load;
--      store prompts closing: Pending -> Granted, Cancelled neutral
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
assert(not RunService:IsStudio(), "receipt-regression must run without --studio (live store rules)")

local fails = 0
local function check(label: string, ok: boolean, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

-- pass lookups (section 9): per user, a failing web call or the owned pass ids
local lookupFails: { [number]: boolean } = {}
local owns: { [number]: { [number]: boolean } } = {}
preview.setPassLookup(function(userId, passId)
	if lookupFails[userId] then
		error("web outage (test)")
	end
	return owns[userId] ~= nil and owns[userId][passId] == true
end)

preview.startServer()
preview.advance(1)

local player = Players.LocalPlayer
local Config = preview.shared("Config")
local MS = preview.server("MonetizationService")
local DS = preview.server("DataService")
local Decision = Enum.ProductPurchaseDecision
local products = Config.Monetization.Products
local passes = Config.Monetization.GamePasses
local store = game:GetService("DataStoreService"):GetDataStore(Config.Data.StoreName)

local data = assert(DS.GetData(player), "profile missing")
data.Gold = 1000

local notices: { string } = {}
preview.remote("Notify").OnClientEvent:Connect(function(n)
	if type(n) == "table" and type(n.Text) == "string" then
		table.insert(notices, n.Text)
	end
end)
local function countNotices(pattern: string): number
	local c = 0
	for _, t in ipairs(notices) do
		if string.find(t, pattern, 1, true) then
			c += 1
		end
	end
	return c
end

local function receipt(productId: number, purchaseId: string, who: any?)
	return MS._ProcessReceipt({
		PlayerId = (who or player).UserId,
		ProductId = productId,
		PurchaseId = purchaseId,
		CurrencySpent = 0,
		PlaceIdWherePurchased = 0,
	})
end
local function countId(list: { string }?, id: string): number
	local c = 0
	for _, v in ipairs(list or {}) do
		if v == id then
			c += 1
		end
	end
	return c
end
local function stored(userId: number): { [string]: any }
	local record = store:GetAsync(Config.Data.KeyPrefix .. userId)
	return type(record) == "table" and type(record.Data) == "table" and record.Data or {}
end
local function join(name: string, userId: number)
	local p = preview.addPlayer(name, userId)
	preview.playerJoined(p)
	preview.advance(0.5)
	return p
end

------------------------------------------------------------------------------------------
-- 1) cancelled prompt / paid prompt close
------------------------------------------------------------------------------------------
do
	local gold, ids = data.Gold, #data.PurchaseIds
	preview.marketEvent("PromptProductPurchaseFinished", player.UserId, products.Gold500, false)
	preview.advance(0.3)
	check("cancelled prompt grants nothing", data.Gold == gold and #data.PurchaseIds == ids, data.Gold)
	check("cancelled prompt shows no purchase line", countNotices("Payment received") == 0)
	preview.marketEvent("PromptProductPurchaseFinished", player.UserId, products.Gold500, true)
	preview.advance(0.3)
	check("paid prompt close alone grants nothing (receipt only)", data.Gold == gold and #data.PurchaseIds == ids, data.Gold)
	check("paid prompt close shows the pending line", countNotices("Payment received") == 1, countNotices("Payment received"))
end

------------------------------------------------------------------------------------------
-- 2) distinct PurchaseIds and replays
------------------------------------------------------------------------------------------
do
	local gold = data.Gold
	local d1 = receipt(products.Gold500, "a-1")
	local d2 = receipt(products.Gold500, "a-2")
	check("same product, two PurchaseIds: both granted", d1 == Decision.PurchaseGranted and d2 == Decision.PurchaseGranted)
	check("two grants credited", data.Gold == gold + 1000, data.Gold - gold)
	local s = stored(player.UserId)
	check("stored ledger: gold and both ids committed", s.Gold == data.Gold and countId(s.PurchaseIds, "a-1") == 1 and countId(s.PurchaseIds, "a-2") == 1, s.Gold)
	check("stored receipt times recorded", type(s.PurchaseTimes) == "table" and type(s.PurchaseTimes["a-1"]) == "number")
	preview.advance(0.3)
	check("thank-you line once per grant, after the save", countNotices("+500 gold") == 2, countNotices("+500 gold"))
	local replays = 0
	for _ = 1, 3 do
		if receipt(products.Gold500, "a-1") == Decision.PurchaseGranted then
			replays += 1
		end
	end
	preview.advance(0.3)
	check("replayed PurchaseId acknowledged", replays == 3)
	check("replayed PurchaseId never grants again", data.Gold == gold + 1000 and countId(data.PurchaseIds, "a-1") == 1, data.Gold - gold)
	check("replay shows no second thank-you", countNotices("+500 gold") == 2)
	preview.marketEvent("PromptProductPurchaseFinished", player.UserId, products.Gold500, true)
	preview.advance(0.3)
	check("no pending line when the receipt was already granted", countNotices("Payment received") == 1)
end

------------------------------------------------------------------------------------------
-- 3) save failure, unknown product, malformed info
------------------------------------------------------------------------------------------
do
	local attempts = Config.Data.SaveAttempts
	Config.Data.SaveAttempts = 1
	local gold = data.Gold
	local storedGold = stored(player.UserId).Gold
	local thanks = countNotices("+1500 gold")
	preview.failDataStores(false, true)
	check("failed save: NotProcessedYet", receipt(products.Gold1500, "f-1") == Decision.NotProcessedYet)
	check("failed save: granted once in memory, id held", data.Gold == gold + 1500 and countId(data.PurchaseIds, "f-1") == 1, data.Gold - gold)
	check("failed save: nothing committed", stored(player.UserId).Gold == storedGold and countId(stored(player.UserId).PurchaseIds, "f-1") == 0)
	preview.advance(0.3)
	check("failed save: no thank-you before the commit", countNotices("+1500 gold") == thanks)
	check("still failing: still NotProcessedYet", receipt(products.Gold1500, "f-1") == Decision.NotProcessedYet)
	check("still failing: no second credit", data.Gold == gold + 1500, data.Gold - gold)
	preview.failDataStores(false, false)
	check("after recovery: the retry is acknowledged", receipt(products.Gold1500, "f-1") == Decision.PurchaseGranted)
	preview.advance(0.3)
	check("after recovery: credited exactly once", data.Gold == gold + 1500 and countId(data.PurchaseIds, "f-1") == 1, data.Gold - gold)
	local s = stored(player.UserId)
	check("after recovery: grant and id committed together", s.Gold == data.Gold and countId(s.PurchaseIds, "f-1") == 1, s.Gold)
	check("after recovery: thank-you once", countNotices("+1500 gold") == thanks + 1)
	Config.Data.SaveAttempts = attempts

	local before, ids = data.Gold, #data.PurchaseIds
	check("unknown product: NotProcessedYet", receipt(424242, "u-1") == Decision.NotProcessedYet)
	check("malformed info: NotProcessedYet", MS._ProcessReceipt(nil) == Decision.NotProcessedYet
		and MS._ProcessReceipt({ PlayerId = "x", PurchaseId = "m" }) == Decision.NotProcessedYet
		and MS._ProcessReceipt({ PlayerId = player.UserId }) == Decision.NotProcessedYet)
	check("unknown / malformed: nothing granted or recorded", data.Gold == before and #data.PurchaseIds == ids)
end

------------------------------------------------------------------------------------------
-- 4) revive product: durable token, consumption after the commit
------------------------------------------------------------------------------------------
do
	data.ReviveTokens = 0
	local attempts = Config.Data.SaveAttempts
	Config.Data.SaveAttempts = 1
	local kept = countNotices("Revive saved")
	preview.failDataStores(false, true)
	check("revive, save failing: NotProcessedYet", receipt(products.Revive, "r-1") == Decision.NotProcessedYet)
	preview.advance(0.3)
	check("revive, save failing: token granted in memory", data.ReviveTokens == 1, data.ReviveTokens)
	check("revive, save failing: not consumed / announced before the commit", countNotices("Revive saved") == kept)
	preview.failDataStores(false, false)
	check("revive retry acknowledged", receipt(products.Revive, "r-1") == Decision.PurchaseGranted)
	preview.advance(0.3)
	check("revive: one durable token in the save", data.ReviveTokens == 1 and stored(player.UserId).ReviveTokens == 1, stored(player.UserId).ReviveTokens)
	check("revive: kept for the next fall (lobby), announced once after the commit", countNotices("Revive saved") == kept + 1)
	Config.Data.SaveAttempts = attempts
	data.ReviveTokens = 0
end

------------------------------------------------------------------------------------------
-- 5) concurrent callbacks for one player (slow DataStore)
------------------------------------------------------------------------------------------
do
	preview.setDataStoreLatency(0.4)
	local gold = data.Gold
	local results = {}
	for i, args in ipairs({ { products.Gold500, "c-1" }, { products.Gold500, "c-1" }, { products.Gold1500, "c-2" }, { products.Gold500, "c-1" } }) do
		task.spawn(function()
			results[i] = receipt(args[1], args[2])
		end)
	end
	preview.advance(6)
	preview.setDataStoreLatency(nil)
	local granted = 0
	for i = 1, 4 do
		if results[i] == Decision.PurchaseGranted then
			granted += 1
		end
	end
	check("concurrent callbacks all answered PurchaseGranted", granted == 4, granted)
	check("concurrent callbacks: one grant per PurchaseId", data.Gold == gold + 2000, data.Gold - gold)
	check("concurrent callbacks: each id recorded once", countId(data.PurchaseIds, "c-1") == 1 and countId(data.PurchaseIds, "c-2") == 1)
	check("concurrent callbacks: stored ledger matches", stored(player.UserId).Gold == data.Gold)
end

------------------------------------------------------------------------------------------
-- 6) player left before / during fulfilment
------------------------------------------------------------------------------------------
do
	-- left before the receipt arrived
	local leaver = join("Leaver", 70001)
	local base = assert(DS.GetData(leaver), "leaver profile").Gold
	preview.removePlayer(leaver)
	preview.advance(1)
	check("player gone: NotProcessedYet", receipt(products.Gold500, "l-1", leaver) == Decision.NotProcessedYet)
	check("player gone: nothing written", (stored(70001).Gold or 0) == base and countId(stored(70001).PurchaseIds, "l-1") == 0)
	local back = join("Leaver", 70001)
	check("rejoined: the same receipt is granted", receipt(products.Gold500, "l-1", back) == Decision.PurchaseGranted)
	check("rejoined: credited once", DS.GetData(back).Gold == base + 500, DS.GetData(back).Gold - base)
	check("rejoined: replay grants nothing", receipt(products.Gold500, "l-1", back) == Decision.PurchaseGranted and DS.GetData(back).Gold == base + 500)
	preview.removePlayer(back)
	preview.advance(1)

	-- leaves while the receipt's save is in flight
	local runner = join("Runner", 70002)
	local start = assert(DS.GetData(runner), "runner profile").Gold
	preview.setDataStoreLatency(0.5)
	local first
	task.spawn(function()
		first = receipt(products.Gold500, "l-2", runner)
	end)
	preview.advance(0.2)
	preview.removePlayer(runner)
	preview.advance(4)
	preview.setDataStoreLatency(nil)
	check("left mid-save: the callback answered", first == Decision.PurchaseGranted or first == Decision.NotProcessedYet, tostring(first))
	local s = stored(70002)
	check("left mid-save: grant and id committed together, once", s.Gold == start + 500 and countId(s.PurchaseIds, "l-2") == 1, tostring(s.Gold) .. " vs " .. start)
	local again = join("Runner", 70002)
	check("left mid-save: the later callback is acknowledged", receipt(products.Gold500, "l-2", again) == Decision.PurchaseGranted)
	check("left mid-save: never credited twice", DS.GetData(again).Gold == start + 500, DS.GetData(again).Gold - start)
	preview.removePlayer(again)
	preview.advance(1)

	-- the save fails while they leave: nothing is half-kept, the receipt grants once later
	local quitter = join("Quitter", 70003)
	local q0 = assert(DS.GetData(quitter), "quitter profile").Gold
	Config.Data.SaveAttempts = 1
	preview.failDataStores(false, true)
	check("quitter, save failing: NotProcessedYet", receipt(products.Gold500, "l-3", quitter) == Decision.NotProcessedYet)
	preview.removePlayer(quitter)
	preview.advance(40) -- the leave save retries, then gives up
	preview.failDataStores(false, false)
	Config.Data.SaveAttempts = 4
	check("quitter: nothing committed", (stored(70003).Gold or 0) == q0 and countId(stored(70003).PurchaseIds, "l-3") == 0, stored(70003).Gold)
	local q = join("Quitter", 70003)
	check("quitter rejoined: granted", receipt(products.Gold500, "l-3", q) == Decision.PurchaseGranted)
	check("quitter rejoined: credited exactly once", DS.GetData(q).Gold == q0 + 500, DS.GetData(q).Gold - q0)
	preview.removePlayer(q)
	preview.advance(1)
end

------------------------------------------------------------------------------------------
-- 7) a second server holds the save and granted the same receipt
------------------------------------------------------------------------------------------
do
	local twin = join("Twin", 70004)
	local base = assert(DS.GetData(twin), "twin profile").Gold
	check("second server: first save written", DS.ForceSave(twin))
	-- server B: took the (stale) lock, granted receipt t-1 and saved it
	local key = Config.Data.KeyPrefix .. 70004
	local record = store:GetAsync(key)
	record.Lock = { JobId = "server-B", Time = os.time() }
	record.LastJob = "server-B"
	record.Data.Gold = base + 500
	table.insert(record.Data.PurchaseIds, "t-1")
	store:SetAsync(key, record)
	local decision = receipt(products.Gold500, "t-1", twin)
	check("second server: this server does not acknowledge", decision == Decision.NotProcessedYet, tostring(decision))
	check("second server: this profile stops (lock lost)", DS.GetProfile(twin) ~= nil and DS.GetProfile(twin).LockLost == true and DS.State(twin) == "lost")
	local s = stored(70004)
	check("second server: exactly one grant in the save", s.Gold == base + 500 and countId(s.PurchaseIds, "t-1") == 1, s.Gold)
	check("second server: a later callback here grants nothing", receipt(products.Gold500, "t-1", twin) == Decision.NotProcessedYet and stored(70004).Gold == base + 500)
	preview.removePlayer(twin)
	preview.advance(1)
	check("second server: leaving never overwrites its save", stored(70004).Gold == base + 500 and store:GetAsync(key).Lock.JobId == "server-B")
end

------------------------------------------------------------------------------------------
-- 8) receipt history keeps recent ids (no replay window by count)
------------------------------------------------------------------------------------------
do
	local now = os.time()
	-- 200 newer purchases after r-old: the old 150 cap would have forgotten it
	data.PurchaseIds = { "r-old" }
	data.PurchaseTimes = { ["r-old"] = now }
	for i = 1, 200 do
		table.insert(data.PurchaseIds, "bulk-" .. i)
		data.PurchaseTimes["bulk-" .. i] = now
	end
	local gold = data.Gold
	check("a new purchase on a long history is granted", receipt(products.Gold500, "r-new") == Decision.PurchaseGranted and data.Gold == gold + 500)
	check("replay after 200 newer purchases is still recognised", receipt(products.Gold500, "r-old") == Decision.PurchaseGranted and data.Gold == gold + 500, data.Gold - gold)
	check("the saved history still holds it", countId(stored(player.UserId).PurchaseIds, "r-old") == 1)
	-- above the soft cap only ids older than the keep window go, oldest first
	local soft = Config.Data.MaxStoredPurchaseIds
	local ids, times = {}, {}
	for i = 1, soft + 50 do
		local id = "h-" .. i
		ids[i] = id
		times[id] = i <= 20 and (now - (Config.Data.PurchaseIdKeepDays + 1) * 86400) or now
	end
	local t = { PurchaseIds = ids, PurchaseTimes = times }
	DS.TrimPurchases(t, now)
	check("trim drops only ids past the keep window", #t.PurchaseIds == soft + 30 and t.PurchaseIds[1] == "h-21" and t.PurchaseTimes["h-1"] == nil, #t.PurchaseIds)
	local hard = Config.Data.PurchaseIdHardCap
	local big = { PurchaseIds = {}, PurchaseTimes = {} }
	for i = 1, hard + 5 do
		big.PurchaseIds[i] = "x-" .. i
		big.PurchaseTimes["x-" .. i] = now
	end
	DS.TrimPurchases(big, now)
	check("hard cap bounds the save size", #big.PurchaseIds == hard and big.PurchaseIds[1] == "x-6", #big.PurchaseIds)
	-- a save from before receipt times: every id is kept and stamped as recent
	local migrated = DS.Migrate({ Version = 7, PurchaseIds = { "old-1", "old-2", "old-1", 5 } })
	check("migration keeps ids, drops junk / duplicates, stamps times", #migrated.PurchaseIds == 2
		and type(migrated.PurchaseTimes["old-1"]) == "number" and type(migrated.PurchaseTimes["old-2"]) == "number")
	data.PurchaseIds = { "a-1", "a-2", "f-1", "c-1", "c-2", "r-1", "r-old" }
	data.PurchaseTimes = {}
	for _, id in ipairs(data.PurchaseIds) do
		data.PurchaseTimes[id] = now
	end
end

------------------------------------------------------------------------------------------
-- 9) game passes
------------------------------------------------------------------------------------------
do
	local DG, VIP = passes.DoubleGold, passes.VIP
	-- Patron: a pass Roblox confirmed in an earlier session is recorded; today the lookup fails
	local key = Config.Data.KeyPrefix .. 70010
	local seed = DS.DefaultData()
	seed.PassesOwned = { [tostring(DG)] = os.time() - 3600 }
	store:SetAsync(key, { Data = seed })
	lookupFails[70010] = true
	local patron = join("Patron", 70010)
	preview.advance(1)
	check("outage: recorded pass still owned", MS.OwnsPass(patron, "DoubleGold") == true)
	check("outage: its benefit still applies (x2 gold)", MS.GoldMultiplier(patron) == Config.Monetization.DoubleGoldMult, MS.GoldMultiplier(patron))
	check("outage: an unrecorded pass is not granted", MS.OwnsPass(patron, "VIP") == false)
	check("outage: failure is not a confirmed answer", MS.PassesKnown(patron) == false)
	-- Roblox answers again: not owned (refund) -> the record goes
	lookupFails[70010] = nil
	MS._QueryPass(patron, DG)
	check("confirmed not owned: entitlement removed", MS.OwnsPass(patron, "DoubleGold") == false)
	check("confirmed not owned: record cleared", DS.GetData(patron).PassesOwned[tostring(DG)] == nil)
	preview.removePlayer(patron)
	preview.advance(1)

	-- Fresh: outage and no record -> not owned for now, still unknown (asked again later)
	lookupFails[70011] = true
	local fresh = join("Fresh", 70011)
	preview.advance(1)
	check("outage, no record: not owned for now", MS.OwnsPass(fresh, "VIP") == false)
	check("outage, no record: still unknown", MS.PassesKnown(fresh) == false)
	-- the server purchase event: a cancel and an unknown pass change nothing; a purchase grants
	preview.marketEvent("PromptGamePassPurchaseFinished", fresh, VIP, false)
	preview.marketEvent("PromptGamePassPurchaseFinished", fresh, 424242, true)
	preview.advance(0.3)
	check("pass prompt cancelled / unknown id: nothing granted", MS.OwnsPass(fresh, "VIP") == false)
	preview.marketEvent("PromptGamePassPurchaseFinished", fresh, VIP, true)
	preview.advance(0.3)
	check("server purchase event grants the pass", MS.OwnsPass(fresh, "VIP") == true and MS.ExtraRerolls(fresh) == Config.Monetization.VIPExtraRerolls)
	check("server purchase event records it", type(DS.GetData(fresh).PassesOwned[tostring(VIP)]) == "number")
	lookupFails[70011] = nil
	MS._QueryPass(fresh, VIP) -- a stale "no" right after buying must not take it back
	check("a stale answer after buying never revokes", MS.OwnsPass(fresh, "VIP") == true)
	preview.removePlayer(fresh)
	preview.advance(1)

	-- Browser: "not owned", then bought on the website: asked again after the re-check time
	local browser = join("Browser", 70012)
	preview.advance(1)
	check("confirmed not owned", MS.OwnsPass(browser, "DoubleGold") == false and MS.PassesKnown(browser))
	owns[70012] = { [DG] = true }
	MS.OwnsPass(browser, "DoubleGold")
	preview.advance(10)
	check("negative answer kept for a short while", MS.OwnsPass(browser, "DoubleGold") == false)
	preview.advance(125)
	MS.OwnsPass(browser, "DoubleGold") -- starts the re-check
	preview.advance(1)
	check("negative answer asked again: new ownership seen", MS.OwnsPass(browser, "DoubleGold") == true)
	check("new ownership recorded", type(DS.GetData(browser).PassesOwned[tostring(DG)]) == "number")
	preview.removePlayer(browser)
	preview.advance(1)
end

------------------------------------------------------------------------------------------
-- 10) profile lifecycle and store prompt states
------------------------------------------------------------------------------------------
do
	-- loading: a receipt waits for the profile; buying is refused while loading
	preview.setDataStoreLatency(2)
	local slow = preview.addPlayer("Slow", 70020)
	preview.playerJoined(slow)
	preview.advance(0.3)
	check("loading: state", DS.State(slow) == "loading" and slow:GetAttribute("ProfileState") == "loading", DS.State(slow))
	check("loading: no profile to change", DS.GetData(slow) == nil and not DS.IsReady(slow))
	local decision
	task.spawn(function()
		decision = receipt(products.Gold500, "s-1", slow)
	end)
	preview.advance(8)
	preview.setDataStoreLatency(nil)
	check("loading: the waiting receipt is granted after the load", decision == Decision.PurchaseGranted, tostring(decision))
	check("ready: state", DS.State(slow) == "ready" and slow:GetAttribute("ProfileState") == "ready")
	-- released for a teleport: no grant, no store purchase; reclaimed: ready again
	check("release for teleport", DS.ReleaseForTeleport(slow) and DS.State(slow) == "released" and slow:GetAttribute("ProfileState") == "released")
	local g = DS.GetData(slow).Gold
	check("released: receipt left for the next server", receipt(products.Gold500, "s-2", slow) == Decision.NotProcessedYet and DS.GetData(slow).Gold == g)
	check("reclaim", DS.Reclaim(slow) and DS.State(slow) == "ready")
	check("reclaimed: the receipt is granted once", receipt(products.Gold500, "s-2", slow) == Decision.PurchaseGranted and DS.GetData(slow).Gold == g + 500)
	preview.removePlayer(slow)
	preview.advance(1)

	-- failed load: never an empty replacement profile; the stored save is untouched
	local key = Config.Data.KeyPrefix .. 70021
	local seed = DS.DefaultData()
	seed.Gold = 777
	store:SetAsync(key, { Data = seed })
	local loads = Config.Data.LoadAttempts
	Config.Data.LoadAttempts = 1
	Config.Data.SaveAttempts = 1
	preview.failDataStores(false, true)
	local broken = join("Broken", 70021)
	preview.advance(1)
	preview.failDataStores(false, false)
	Config.Data.LoadAttempts = loads
	Config.Data.SaveAttempts = 4
	check("failed load: state failed, no profile", DS.State(broken) == "failed" and DS.GetData(broken) == nil, DS.State(broken))
	check("failed load: a receipt is not acknowledged", receipt(products.Gold500, "b-1", broken) == Decision.NotProcessedYet)
	check("failed load: the stored save is untouched", stored(70021).Gold == 777)
	preview.removePlayer(broken)
	preview.advance(1)
	check("failed load: leaving writes nothing", stored(70021).Gold == 777 and store:GetAsync(key).Lock == nil)

	-- store prompt states (fake product id at run time, never shipped)
	if Config.FeatureOn("Store") then
		Config.Monetization.Cosmetics.Trail_Frost = 9301
		MS._RebuildProducts()
		local answers = {}
		preview.remote("StoreResult").OnClientEvent:Connect(function(r)
			table.insert(answers, r)
		end)
		local function last()
			return answers[#answers] or {}
		end
		preview.remote("StoreBuy"):FireServer("Trail_Frost")
		preview.advance(0.6)
		preview.marketEvent("PromptProductPurchaseFinished", player.UserId, 9301, false)
		preview.advance(0.3)
		check("store cancel: neutral Cancelled line, nothing granted", last().Kind == "Cancelled" and not data.Cosmetics.Owned.Trail_Frost, last().Kind)
		preview.advance(2.5)
		preview.remote("StoreBuy"):FireServer("Trail_Frost")
		preview.advance(0.6)
		preview.marketEvent("PromptProductPurchaseFinished", player.UserId, 9301, true)
		preview.advance(0.3)
		check("store paid prompt: Pending, not a success, nothing granted", last().Kind == "Pending" and last().Item == "Trail_Frost" and not data.Cosmetics.Owned.Trail_Frost, last().Kind)
		check("store receipt granted", receipt(9301, "st-1") == Decision.PurchaseGranted and data.Cosmetics.Owned.Trail_Frost == true)
		preview.advance(0.3)
		check("store: Granted line after the save", last().Kind == "Granted" and last().Item == "Trail_Frost", last().Kind)
		Config.Monetization.Cosmetics.Trail_Frost = 0
		MS._RebuildProducts()
	end
end

-- the one ProcessReceipt owner is still MonetizationService's
check("ProcessReceipt is MonetizationService's callback", game:GetService("MarketplaceService").ProcessReceipt == MS._ProcessReceipt)

if fails == 0 then
	preview.log("PASS receipt-regression")
else
	preview.log(string.format("FAIL receipt-regression: %d check(s) failed", fails))
end
