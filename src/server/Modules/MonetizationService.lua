--[[
	MonetizationService.lua
	Gamepasses, developer products and receipt handling.

	Paste IDs into Config.Monetization (0 = not configured; the item is hidden/greyed).

	Gamepasses
	  StarterPack  +25% gold (GoldSystem multiplier) + "Gold Trim" skin on every character
	  VIP          +1 reroll per run, [VIP] chat tag (client), crown in the lobby
	  DoubleGold   2x gold
	  Skin passes  one per cosmetic skin (Config.Monetization.SkinPasses)
	  Supporter    Config.Monetization.CosmeticPasses: badge, glowing plate, lobby banner
	               (StoreService / StoreFx; looks only)
	Developer products
	  Gold500 / Gold1500 / Gold5000  add gold to the save
	  StarterBundle  once per account: Pioneer skin + gold + title (StarterBundle.lua)
	  Revive       adds a revive token; RunManager spends it at once if the buyer is
	               waiting to be revived, otherwise it is kept for the next death
	  Cosmetics / HeroUnlocks  the cosmetic store (StoreService): one look into
	               data.Cosmetics.Owned, or an early unlock of a hero also earned by play.
	               A store gift (StoreBuy with a target) is granted into the recipient's
	               save when they are still here (StoreService.GiftRoute / GrantGift).

	ProcessReceipt (the game's only receipt callback, set in Init) is idempotent per
	PurchaseId (never per ProductId: buying the same pack twice is two grants):
	  * one receipt at a time per player (a duplicate callback waits, then finds its id);
	  * the grant and the PurchaseId go into the same save table and are committed by one
	    DataService save (UpdateAsync under the session lock); PurchaseGranted only after that
	    save succeeded, or when the id is already in a save that a save just confirmed;
	  * NotProcessedYet for a player who is not here, a profile still loading / handed off /
	    lock lost, an unknown product, a handler error (the grant is rolled back) or a failed
	    save (the grant stays in memory with its id, so a retry never adds it twice);
	  * live effects (spend a revive at once, the thank-you line, the profile sync) are the
	    handler's `after` function and run only after the commit, so a crash before the save
	    cannot leave an effect without its saved receipt (granting stays apart from consuming).
	A second server can only grant from its own load of the save, after this server's lock
	is released or stale (DataService), and then sees the id this server committed.
	Game passes are asked of Roblox on the server (UserOwnsGamePassAsync), never trusted from
	a client: see OwnsPassId. Nothing for sale changes combat numbers: gold and cosmetics only,
	no loot boxes. Inventory and decisions: docs/redesign/continuation/COMMERCE_AUDIT.md.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)

local MonetizationService = {}

local ctx
-- player → passId → Roblox's confirmed answer this session (nil = not known yet)
local passCache: { [Player]: { [number]: boolean } } = {}

------------------------------------------------------------------------------------------
-- Gamepasses
--   Known:   Roblox answered (UserOwnsGamePassAsync); a "yes" is kept for the session, a
--            "no" is asked again after NEGATIVE_RECHECK_SECONDS (bought on the website or on
--            another server), so no long-lived negative cache hides a new purchase.
--   Failed:  the lookup errored (web outage). That is not "not owned": the save's record of
--            a pass Roblox confirmed before (data.PassesOwned) keeps the benefit until
--            Roblox answers again; without a record it counts as not owned for now. Retried
--            at most every RETRY_SECONDS.
--   Pending: asked, no answer yet: not owned for now (GoldSystem pays back early gold when
--            the answer arrives, EC-A21).
--   Bought:  the server's PromptGamePassPurchaseFinished (purchased = true, a configured
--            pass) marks it owned for the session and records it; a later stale "no" never
--            takes that back. A client message never grants a pass.
--   Lookups are coalesced: one request per player and pass at a time.
------------------------------------------------------------------------------------------

local inFlight: { [Player]: { [number]: boolean } } = {}
-- player → passId → os.clock() of a failed lookup: OwnsPassId does not start another one for
-- RETRY_SECONDS (a web outage must not turn every gold drop into a new request)
local failedAt: { [Player]: { [number]: number } } = {}
local RETRY_SECONDS = 15
-- player → passId → os.clock() of the last confirmed answer (negative re-check timer)
local answeredAt: { [Player]: { [number]: number } } = {}
local NEGATIVE_RECHECK_SECONDS = 120
-- player → passId → true: bought in this session (server purchase event)
local bought: { [Player]: { [number]: boolean } } = {}

local function slot(t: { [Player]: { [number]: any } }, player: Player): { [number]: any }
	local s = t[player]
	if not s then
		s = {}
		t[player] = s
	end
	return s
end

-- The save's record of a pass Roblox confirmed owned before (survives a lookup outage).
local function recorded(player: Player, passId: number): boolean
	local data = ctx and ctx.DataService.GetData(player)
	local passes = data and data.PassesOwned
	return type(passes) == "table" and type(passes[tostring(passId)]) == "number"
end

-- Keeps data.PassesOwned in step with a confirmed answer (only a save this server owns).
local function writeRecord(player: Player, passId: number, owns: boolean)
	local DS = ctx and ctx.DataService
	local profile = DS and DS.GetProfile(player)
	if not profile or profile.Released or profile.LockLost then
		return
	end
	local data = profile.Data
	if type(data.PassesOwned) ~= "table" then
		data.PassesOwned = {}
	end
	local key = tostring(passId)
	if owns then
		if data.PassesOwned[key] == nil then
			data.PassesOwned[key] = os.time()
		end
	else
		data.PassesOwned[key] = nil
	end
end

-- What the game uses right now: a confirmed answer, else the record after a failed lookup.
local function effective(player: Player, passId: number): boolean
	local cached = passCache[player] and passCache[player][passId]
	if cached ~= nil then
		return cached
	end
	local failed = failedAt[player] and failedAt[player][passId]
	return failed ~= nil and recorded(player, passId)
end

-- Asks Roblox (yields). Only called from background threads, never from the game loop.
local function queryPass(player: Player, passId: number)
	local flights = slot(inFlight, player)
	if flights[passId] then
		return
	end
	flights[passId] = true
	local before = effective(player, passId)
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	flights[passId] = nil
	if not player.Parent then
		return
	end
	if ok then
		if failedAt[player] then
			failedAt[player][passId] = nil
		end
		slot(answeredAt, player)[passId] = os.clock()
		local yes = owns == true or (bought[player] ~= nil and bought[player][passId] == true)
		slot(passCache, player)[passId] = yes
		writeRecord(player, passId, yes)
	else
		local failed = slot(failedAt, player)
		if failed[passId] == nil then -- once per outage, not on every retry
			warn(string.format("[Monetization] pass %d lookup failed for %d: %s", passId, player.UserId, tostring(owns)))
		end
		failed[passId] = os.clock()
	end
	if effective(player, passId) ~= before then
		MonetizationService.RefreshAttributes(player)
	end
end

--[[
	Never yields: answers from what is known (see the section header). A missing or stale
	answer starts one background lookup, so the server loop can call this on every gold
	drop safely.
]]
function MonetizationService.OwnsPassId(player: Player, passId: number?): boolean
	if not passId or passId == 0 then
		return false
	end
	local cache = passCache[player]
	local cached = cache and cache[passId]
	if cached == true then
		return true
	end
	-- a player who has left gets no new web call (the leave commit still reads the cache)
	if player.Parent then
		if cached == nil then
			local failed = failedAt[player]
			local lastFail = failed and failed[passId]
			if not (lastFail and os.clock() - lastFail < RETRY_SECONDS) then
				task.spawn(queryPass, player, passId)
			end
		else
			local at = answeredAt[player] and answeredAt[player][passId]
			if not at or os.clock() - at >= NEGATIVE_RECHECK_SECONDS then
				slot(answeredAt, player)[passId] = os.clock() -- one re-check per window
				task.spawn(queryPass, player, passId)
			end
		end
	end
	if cached == false then
		return false
	end
	return effective(player, passId)
end

-- True once every configured gameplay pass (Config.Monetization.GamePasses) has an answer
-- for this player. Until then earnings are paid with the passes known so far and the
-- difference is paid back when the lookup answers (GoldSystem.CorrectEarlyGold, audit
-- EC-A21): a slow lookup never holds up the run.
function MonetizationService.PassesKnown(player: Player): boolean
	local cache = passCache[player]
	for _, id in pairs(Config.Monetization.GamePasses) do
		if id ~= 0 and (not cache or cache[id] == nil) then
			return false
		end
	end
	return true
end

-- True for a non-zero id listed in Config.Monetization.GamePasses, SkinPasses or
-- CosmeticPasses (the store's Supporter pass).
function MonetizationService.IsConfiguredPass(passId: any): boolean
	if type(passId) ~= "number" or passId == 0 then
		return false
	end
	for _, list in ipairs({ Config.Monetization.GamePasses, Config.Monetization.SkinPasses, (Config.Monetization :: any).CosmeticPasses or {} }) do
		for _, id in pairs(list) do
			if id == passId then
				return true
			end
		end
	end
	return false
end

-- key = "StarterPack" | "VIP" | "DoubleGold"
function MonetizationService.OwnsPass(player: Player, key: string): boolean
	return MonetizationService.OwnsPassId(player, Config.Monetization.GamePasses[key])
end

-- Dev panel "Unlock everything" in Studio: every skin for this session (never saved, never
-- in live servers; the skins are Robux items).
local devSkins: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

function MonetizationService.DevGrantSkins(player: Player, on: boolean)
	devSkins[player] = (on and game:GetService("RunService"):IsStudio()) or nil
end

function MonetizationService.OwnsSkin(player: Player, skinId: string): boolean
	if skinId == "Default" then
		return true
	end
	local skin = CharacterData.Skins[skinId]
	if not skin then
		return false
	end
	if devSkins[player] then
		return true
	end
	if skin.Pass == "StarterPack" then
		return MonetizationService.OwnsPass(player, "StarterPack")
	end
	if skin.Pass == "StarterBundle" then
		-- the Starter Bundle's skin (StarterBundle.lua): owned through the save flag
		local data = ctx and ctx.DataService.GetData(player)
		return Config.FeatureOn("StarterBundle") and data ~= nil and data.StarterBundleOwned == true
	end
	return MonetizationService.OwnsPassId(player, Config.Monetization.SkinPasses[skinId])
end

-- Every skin id this player owns (for the lobby UI).
function MonetizationService.OwnedSkins(player: Player): { [string]: boolean }
	local owned = { Default = true }
	for skinId in pairs(CharacterData.Skins) do
		if MonetizationService.OwnsSkin(player, skinId) then
			owned[skinId] = true
		end
	end
	return owned
end

function MonetizationService.GoldMultiplier(player: Player): number
	local mult = 1
	if MonetizationService.OwnsPass(player, "StarterPack") then
		mult *= Config.Monetization.StarterPackGoldMult
	end
	if MonetizationService.OwnsPass(player, "DoubleGold") then
		mult *= Config.Monetization.DoubleGoldMult
	end
	return mult
end

function MonetizationService.ExtraRerolls(player: Player): number
	return MonetizationService.OwnsPass(player, "VIP") and Config.Monetization.VIPExtraRerolls or 0
end

-- Attributes the client reads for the chat tag and shop state.
function MonetizationService.RefreshAttributes(player: Player)
	player:SetAttribute("VIP", MonetizationService.OwnsPass(player, "VIP"))
	player:SetAttribute("StarterPack", MonetizationService.OwnsPass(player, "StarterPack"))
	player:SetAttribute("DoubleGold", MonetizationService.OwnsPass(player, "DoubleGold"))
	-- the cosmetic store's Supporter flag and worn looks (no-op with Store off)
	if ctx and ctx.StoreService then
		ctx.StoreService.Apply(player)
	end
	-- in a run, chest / shrine prices follow the new multiplier at once (GoldSystem.PriceMult);
	-- through ctx, so no require cycle
	local gold, run = ctx and ctx.GoldSystem, ctx and ctx.RunManager
	local rp = run and run.GetRunPlayer and run.GetRunPlayer(player)
	if gold and gold.PublishGoldMult and rp then
		gold.PublishGoldMult(player)
		-- a lookup that answered after the run began: pay back what the first seconds
		-- earned without the pass, and hand over the VIP rerolls (EC-A21)
		if MonetizationService.PassesKnown(player) then
			if gold.CorrectEarlyGold then
				gold.CorrectEarlyGold(rp)
			end
			local extra = MonetizationService.ExtraRerolls(player)
			local given = tonumber(rp.PassRerolls) or 0
			if extra > given and type(rp.Rerolls) == "number" then
				rp.Rerolls += extra - given
				rp.RerollsMax = (tonumber(rp.RerollsMax) or 0) + extra - given
				rp.PassRerolls = extra
			end
		end
	end
end

-- Revive product configured?
function MonetizationService.ReviveAvailable(): boolean
	return (Config.Monetization.Products.Revive or 0) ~= 0
end

function MonetizationService.PromptRevive(player: Player): boolean
	local id = Config.Monetization.Products.Revive
	if not id or id == 0 then
		return false
	end
	local ok = pcall(function()
		MarketplaceService:PromptProductPurchase(player, id)
	end)
	return ok
end

------------------------------------------------------------------------------------------
-- Developer products
------------------------------------------------------------------------------------------

local GOLD = Color3.fromRGB(255, 215, 80)
local Decision = Enum.ProductPurchaseDecision

--[[
	productId → handler(player, data) → after?. A handler only changes `data` (the save table)
	and may return `after`: the live part (spend a revive now, the thank-you line, the profile
	sync), run once the grant and its PurchaseId are saved. Older handlers that return nothing
	(StarterBundle) keep their own task.defer.
]]
type Handler = (Player, { [string]: any }) -> any
local productHandlers: { [number]: Handler } = {}

local function buildProductHandlers()
	table.clear(productHandlers)
	for key, gold in pairs(Config.Monetization.ProductGold) do
		local id = Config.Monetization.Products[key]
		if id and id ~= 0 then
			productHandlers[id] = function(player, data)
				data.Gold += gold
				return function()
					ctx.GoldSystem.SyncProfile(player)
					ctx.RunManager.Notify(player, string.format("+%d gold. Thank you!", gold), GOLD)
				end
			end
		end
	end
	local reviveId = Config.Monetization.Products.Revive
	if reviveId and reviveId ~= 0 then
		-- granting (a durable token in the save) stays apart from consuming it: the token is
		-- spent by RunManager only after the receipt is saved, so a crash in between can
		-- never both revive the hero and leave the receipt to grant the token again
		productHandlers[reviveId] = function(player, data)
			data.ReviveTokens = (data.ReviveTokens or 0) + 1
			return function()
				ctx.RunManager.OnReviveTokenGranted(player)
			end
		end
	end
	-- the Starter Bundle (Config.Features.StarterBundle; StarterBundle.lua): once per account
	local starter = ctx and ctx.StarterBundle
	if starter and Config.FeatureOn("StarterBundle") and starter.ProductId() ~= 0 then
		productHandlers[starter.ProductId()] = starter.Handler
	end
	-- the cosmetic store: looks and early hero unlocks (Config.Features.Store)
	local store = ctx and ctx.StoreService
	if store and Config.FeatureOn("Store") then
		for productId in pairs(store.ProductMap()) do
			if not productHandlers[productId] then
				productHandlers[productId] = store.Handler(productId)
			end
		end
	end
end

-- Plain-data copy / in-place restore of the save, so a handler that errors half way does
-- not leave a partial grant behind for the retried receipt to add to.
local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = deepCopy(v)
	end
	return copy
end

local function restoreInto(dst: { [any]: any }, src: { [any]: any })
	for k in pairs(dst) do
		if src[k] == nil then
			dst[k] = nil
		end
	end
	for k, v in pairs(src) do
		local cur = dst[k]
		if type(v) == "table" and type(cur) == "table" then
			restoreInto(cur, v)
		else
			dst[k] = deepCopy(v)
		end
	end
end

-- UserId → a receipt of this player is being processed (one at a time per player)
local receiptBusy: { [number]: boolean } = {}
local RECEIPT_QUEUE_SECONDS = 30
-- PurchaseId → the live part still owed for a grant whose save failed (run on the retry
-- that saves it); dropped when the player leaves (the saved token / item stays)
local owedAfter: { [string]: { UserId: number, Fn: () -> () } } = {}
-- UserId → productId → os.clock() of the last grant (the "payment received" line is skipped
-- when the grant already happened)
local lastGrant: { [number]: { [number]: number } } = {}

local function runAfter(player: Player, purchaseId: string)
	local owed = owedAfter[purchaseId]
	owedAfter[purchaseId] = nil
	if owed and player.Parent then
		task.spawn(function()
			local ok, err = pcall(owed.Fn)
			if not ok then
				warn("[Monetization] after-grant step failed: " .. tostring(err))
			end
		end)
	end
end

local function fulfil(info: { [string]: any }): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(info.PlayerId)
	if not player then
		return Decision.NotProcessedYet -- not here: Roblox calls again when they join a server
	end
	local DS = ctx.DataService
	-- The profile may still be loading right after joining.
	local profile = DS.GetProfile(player)
	local waited = 0
	while not profile and waited < 10 and player.Parent do
		task.wait(0.5)
		waited += 0.5
		profile = DS.GetProfile(player)
	end
	if not profile or profile.Released or profile.LockLost or not player.Parent then
		return Decision.NotProcessedYet
	end

	local purchaseId = tostring(info.PurchaseId)
	if DS.HasPurchase(player, purchaseId) then
		-- Granted before. It may only be in memory (an earlier save failed): acknowledge once a
		-- save holding it succeeded; the grant itself is never repeated.
		if not DS.ForceSave(player) then
			return Decision.NotProcessedYet
		end
		runAfter(player, purchaseId)
		return Decision.PurchaseGranted
	end
	local handler = productHandlers[info.ProductId]
	if not handler then
		warn("[Monetization] no handler for product " .. tostring(info.ProductId) .. " (receipt left unprocessed)")
		return Decision.NotProcessedYet
	end
	-- a store gift goes to the recipient picked on the server (StoreService.GiftRoute)
	local store = ctx.StoreService
	local gift = store and Config.FeatureOn("Store") and store.GiftRoute(player, info.ProductId, purchaseId)
	local before = deepCopy(profile.Data)
	local ok, result, after
	if gift then
		ok, result, after = pcall(store.GrantGift, player, profile.Data, gift)
		if ok and result == false then
			return Decision.NotProcessedYet -- the recipient's save failed: retry
		end
	else
		ok, after = pcall(handler, player, profile.Data)
		result = after
	end
	if not ok then
		restoreInto(profile.Data, before)
		warn("[Monetization] product handler failed: " .. tostring(result))
		return Decision.NotProcessedYet
	end
	if profile.Released or profile.LockLost or not player.Parent then
		-- handed off / lost while a gift was being saved: this server must not commit it
		restoreInto(profile.Data, before)
		return Decision.NotProcessedYet
	end
	DS.RecordPurchase(player, purchaseId)
	if type(after) == "function" then
		owedAfter[purchaseId] = { UserId = player.UserId, Fn = after }
	end
	local grants = lastGrant[player.UserId] or {}
	lastGrant[player.UserId] = grants
	grants[info.ProductId] = os.clock()
	-- One save commits the grant and its PurchaseId together. If it fails the receipt stays
	-- unacknowledged; the id is recorded in memory, so a retry here never grants twice, and
	-- a later save (autosave / leave) writes both or neither.
	if DS.ForceSave(player) then
		runAfter(player, purchaseId)
		return Decision.PurchaseGranted
	end
	return Decision.NotProcessedYet
end

local function processReceipt(info): Enum.ProductPurchaseDecision
	if type(info) ~= "table" or type(info.PlayerId) ~= "number" or info.PurchaseId == nil then
		return Decision.NotProcessedYet
	end
	-- One receipt at a time per player: a duplicate callback (or a second product) waits for
	-- the running one, then sees its PurchaseId. Bounded: Roblox calls again later.
	local userId = info.PlayerId
	local started = os.clock()
	while receiptBusy[userId] do
		if os.clock() - started > RECEIPT_QUEUE_SECONDS then
			warn("[Monetization] receipt " .. tostring(info.PurchaseId) .. " waited too long; left for a later callback")
			return Decision.NotProcessedYet
		end
		task.wait(0.1)
	end
	receiptBusy[userId] = true
	local ok, decision = pcall(fulfil, info)
	receiptBusy[userId] = nil
	if not ok then
		warn("[Monetization] receipt " .. tostring(info.PurchaseId) .. " failed: " .. tostring(decision))
		return Decision.NotProcessedYet
	end
	return decision
end

-- A developer-product prompt closed with a payment, before its receipt was saved: say it
-- is on its way (the grant itself only ever comes from ProcessReceipt). Store products have
-- their own line (StoreService); a cancel says nothing here.
local function onProductPromptFinished(userId: number, productId: number, purchased: boolean)
	if purchased ~= true or type(productId) ~= "number" or not productHandlers[productId] then
		return
	end
	local store = ctx.StoreService
	if store and Config.FeatureOn("Store") and store.ProductMap()[productId] then
		return
	end
	local grants = lastGrant[userId]
	if grants and grants[productId] and os.clock() - grants[productId] < 30 then
		return -- already granted (the receipt can arrive before this event)
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		ctx.RunManager.Notify(player, "Payment received. Adding it to your save...", GOLD, { Id = "purchase.pending" })
	end
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

-- The game's one ProcessReceipt assignment (C4): only here, once per server.
function MonetizationService.Init(c)
	ctx = c
	buildProductHandlers()
	MarketplaceService.ProcessReceipt = processReceipt
end
MonetizationService._ProcessReceipt = processReceipt -- (tests: safety-sim, receipt-regression)
MonetizationService._RebuildProducts = buildProductHandlers -- (tests: store-regression, ids set at run time)
MonetizationService._QueryPass = queryPass -- (tests: receipt-regression)

-- Every configured pass id (gameplay, skin and cosmetic passes).
local function configuredPasses(): { number }
	local ids = {}
	for _, list in ipairs({ Config.Monetization.GamePasses, Config.Monetization.SkinPasses, (Config.Monetization :: any).CosmeticPasses or {} }) do
		for _, id in pairs(list) do
			if type(id) == "number" and id ~= 0 then
				table.insert(ids, id)
			end
		end
	end
	return ids
end

function MonetizationService.Start()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		-- the server's own purchase event (never a client message): only a finished purchase of
		-- one of this game's configured passes counts (a cancel, a failed payment or an unknown
		-- id changes nothing). It is owned for this session and recorded in the save
		-- (PassesOwned); every join still asks Roblox again (warm).
		if purchased ~= true or not MonetizationService.IsConfiguredPass(passId) then
			return
		end
		slot(bought, player)[passId] = true
		slot(passCache, player)[passId] = true
		slot(answeredAt, player)[passId] = os.clock()
		if failedAt[player] then
			failedAt[player][passId] = nil
		end
		writeRecord(player, passId, true)
		MonetizationService.RefreshAttributes(player)
		ctx.GoldSystem.SyncProfile(player)
		ctx.RunManager.Notify(player, "Purchase complete. Thank you!", GOLD)
		if passId == Config.Monetization.GamePasses.VIP then
			ctx.RunManager.RefreshLobbyCharacter(player)
		end
	end)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		onProductPromptFinished(userId, productId, purchased == true)
	end)

	local function warm(player: Player)
		-- Look up every configured pass in the background so later checks are instant. A pass
		-- still unknown (the lookup failed) is asked again a few times; answered ones are not
		-- asked twice (RefreshAttributes runs when an answer changes what the game uses).
		task.spawn(function()
			for _ = 1, 3 do
				for _, id in ipairs(configuredPasses()) do
					local cache = passCache[player]
					if not (cache and cache[id] ~= nil) then
						queryPass(player, id)
					end
				end
				if not player.Parent then
					return
				end
				MonetizationService.RefreshAttributes(player)
				local cache = passCache[player] or {}
				local missing = false
				for _, id in pairs(Config.Monetization.GamePasses) do
					if id ~= 0 and cache[id] == nil then
						missing = true
					end
				end
				if not missing then
					return
				end
				task.wait(10)
			end
		end)
	end
	Players.PlayerAdded:Connect(warm)
	for _, p in ipairs(Players:GetPlayers()) do
		warm(p)
	end
	-- the save's pass record needs the profile: re-publish once it is loaded (a lookup that
	-- failed before the load answers from the record from now on)
	ctx.DataService.OnProfileLoaded(function(player)
		if player.Parent then
			MonetizationService.RefreshAttributes(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		-- deferred: RunManager's leave commit reads pass ownership after this handler runs
		task.defer(function()
			passCache[player] = nil
			inFlight[player] = nil
			failedAt[player] = nil
			answeredAt[player] = nil
			bought[player] = nil
			lastGrant[player.UserId] = nil
			for id, owed in pairs(owedAfter) do
				if owed.UserId == player.UserId then
					owedAfter[id] = nil -- the saved token / item stays; only the live part is dropped
				end
			end
		end)
	end)
end

return MonetizationService
