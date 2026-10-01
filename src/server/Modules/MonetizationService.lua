--[[
	MonetizationService.lua
	Gamepasses, developer products and receipt handling.

	Paste IDs into Config.Monetization (0 = not configured; the item is hidden/greyed).

	Gamepasses
	  StarterPack  +25% gold (GoldSystem multiplier) + "Gold Trim" skin on every character
	  VIP          +1 reroll per run, [VIP] chat tag (client), crown in the lobby
	  DoubleGold   2x gold
	  Skin passes  one per cosmetic skin (Config.Monetization.SkinPasses)
	Developer products
	  Gold500 / Gold1500 / Gold5000  add gold to the save
	  Revive       adds a revive token; RunManager spends it at once if the buyer is
	               waiting to be revived, otherwise it is kept for the next death

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

-- key = "StarterPack" | "VIP" | "DoubleGold"
function MonetizationService.OwnsPass(player: Player, key: string): boolean
	return MonetizationService.OwnsPassId(player, Config.Monetization.GamePasses[key])
end

function MonetizationService.OwnsSkin(player: Player, skinId: string): boolean
	if skinId == "Default" then
		return true
	end
	local skin = CharacterData.Skins[skinId]
	if not skin then
		return false
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
end

local function processReceipt(info): Enum.ProductPurchaseDecision
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
	if not profile then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseId = tostring(info.PurchaseId)
	if ctx.DataService.HasPurchase(player, purchaseId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted -- already granted earlier
	end
	local handler = productHandlers[info.ProductId]
	if not handler then
		warn("[Monetization] no handler for product " .. tostring(info.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local ok, err = pcall(handler, player, profile.Data)
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

function MonetizationService.Start()
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		if not purchased then
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
