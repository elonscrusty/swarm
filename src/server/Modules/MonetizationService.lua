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
	  Revive       adds a revive token; RunManager spends it at once if the buyer is
	               waiting to be revived, otherwise it is kept for the next death
	  Cosmetics / HeroUnlocks  the cosmetic store (StoreService): one look into
	               data.Cosmetics.Owned, or an early unlock of a hero also earned by play.
	               A store gift (StoreBuy with a target) is granted into the recipient's
	               save when they are still here (StoreService.GiftRoute / GrantGift).

	ProcessReceipt is idempotent: every PurchaseId is stored in the profile and a receipt
	is only acknowledged after the profile (with that id) was saved. Nothing for sale
	changes combat numbers: gold and cosmetics only, no loot boxes.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)

local MonetizationService = {}

local ctx
local passCache: { [Player]: { [number]: boolean } } = {}

------------------------------------------------------------------------------------------
-- Gamepasses
------------------------------------------------------------------------------------------

local inFlight: { [Player]: { [number]: boolean } } = {}

-- Asks Roblox (yields). Only called from background threads, never from the game loop.
local function queryPass(player: Player, passId: number)
	local flights = inFlight[player]
	if not flights then
		flights = {}
		inFlight[player] = flights
	end
	if flights[passId] then
		return
	end
	flights[passId] = true
	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
	end)
	flights[passId] = nil
	if ok and player.Parent then
		local cache = passCache[player]
		if not cache then
			cache = {}
			passCache[player] = cache
		end
		local before = cache[passId]
		cache[passId] = owns == true
		if before ~= cache[passId] then
			MonetizationService.RefreshAttributes(player)
		end
	end
end

--[[
	Never yields: answers from the cache. Unknown (not yet loaded, or the web call
	failed) counts as "not owned" for now and a background lookup is started, so the
	server loop can call this on every gold drop safely.
]]
function MonetizationService.OwnsPassId(player: Player, passId: number?): boolean
	if not passId or passId == 0 then
		return false
	end
	local cache = passCache[player]
	local cached = cache and cache[passId]
	if cached == nil then
		task.spawn(queryPass, player, passId)
		return false
	end
	return cached
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

-- productId → function(player, data). Must only change `data` (and live state through ctx).
local productHandlers: { [number]: (Player, { [string]: any }) -> () } = {}

local function buildProductHandlers()
	table.clear(productHandlers)
	for key, gold in pairs(Config.Monetization.ProductGold) do
		local id = Config.Monetization.Products[key]
		if id and id ~= 0 then
			productHandlers[id] = function(player, data)
				data.Gold += gold
				task.defer(function()
					ctx.GoldSystem.SyncProfile(player)
					ctx.RunManager.Notify(player, string.format("+%d gold. Thank you!", gold), Color3.fromRGB(255, 215, 80))
				end)
			end
		end
	end
	local reviveId = Config.Monetization.Products.Revive
	if reviveId and reviveId ~= 0 then
		productHandlers[reviveId] = function(player, data)
			data.ReviveTokens = (data.ReviveTokens or 0) + 1
			task.defer(function()
				ctx.RunManager.OnReviveTokenGranted(player)
			end)
		end
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

local function processReceipt(info): Enum.ProductPurchaseDecision
	if type(info) ~= "table" or type(info.PlayerId) ~= "number" or info.PurchaseId == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player = Players:GetPlayerByUserId(info.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- The profile may still be loading right after joining.
	local profile = ctx.DataService.GetProfile(player)
	local waited = 0
	while not profile and waited < 10 and player.Parent do
		task.wait(0.5)
		waited += 0.5
		profile = ctx.DataService.GetProfile(player)
	end
	if not profile or profile.Released or profile.LockLost then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = tostring(info.PurchaseId)
	if ctx.DataService.HasPurchase(player, purchaseId) then
		-- An earlier attempt may have granted in memory but failed to save.
		return ctx.DataService.ForceSave(player) and Enum.ProductPurchaseDecision.PurchaseGranted
			or Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local handler = productHandlers[info.ProductId]
	if not handler then
		warn("[Monetization] no handler for product " .. tostring(info.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	-- a store gift goes to the recipient picked on the server (StoreService.GiftRoute)
	local store = ctx.StoreService
	local gift = store and Config.FeatureOn("Store") and store.GiftRoute(player, info.ProductId, purchaseId)
	local ok, err
	if gift then
		ok, err = pcall(store.GrantGift, player, profile.Data, gift)
		if ok and err == false then
			return Enum.ProductPurchaseDecision.NotProcessedYet -- the recipient's save failed: retry
		end
	else
		ok, err = pcall(handler, player, profile.Data)
	end
	if not ok then
		warn("[Monetization] product handler failed: " .. tostring(err))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	ctx.DataService.RecordPurchase(player, purchaseId)
	-- Only acknowledge once it is saved. If the save fails Roblox retries the receipt;
	-- the id is already recorded in memory so this session won't grant it twice.
	if ctx.DataService.ForceSave(player) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function MonetizationService.Init(c)
	ctx = c
	buildProductHandlers()
	MarketplaceService.ProcessReceipt = processReceipt
end
MonetizationService._ProcessReceipt = processReceipt -- (tests: safety-sim)
MonetizationService._RebuildProducts = buildProductHandlers -- (tests: store-regression, ids set at run time)

function MonetizationService.Start()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		-- only a finished purchase of one of this game's configured passes counts (a cancel,
		-- a failed payment or an unknown id changes nothing); the pass itself is never saved:
		-- every join asks Roblox again (warm), so this only unlocks it for this session
		if purchased ~= true or not MonetizationService.IsConfiguredPass(passId) then
			return
		end
		local cache = passCache[player]
		if not cache then
			cache = {}
			passCache[player] = cache
		end
		cache[passId] = true
		MonetizationService.RefreshAttributes(player)
		ctx.GoldSystem.SyncProfile(player)
		ctx.RunManager.Notify(player, "Purchase complete. Thank you!", Color3.fromRGB(255, 215, 80))
		if passId == Config.Monetization.GamePasses.VIP then
			ctx.RunManager.RefreshLobbyCharacter(player)
		end
	end)

	local function warm(player: Player)
		-- Look up every configured pass in the background so later checks are instant.
		-- Failed lookups are retried a few times (RefreshAttributes runs when one changes).
		task.spawn(function()
			for _ = 1, 3 do
				for _, id in pairs(Config.Monetization.GamePasses) do
					if id ~= 0 then
						queryPass(player, id)
					end
				end
				for _, id in pairs(Config.Monetization.SkinPasses) do
					if id ~= 0 then
						queryPass(player, id)
					end
				end
				for _, id in pairs((Config.Monetization :: any).CosmeticPasses or {}) do
					if id ~= 0 then
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
	Players.PlayerRemoving:Connect(function(player)
		passCache[player] = nil
		inFlight[player] = nil
	end)
end

return MonetizationService
