--[[
	StoreService.lua (Config.Features.Store; docs/features/STORE.md)
	The cosmetic store's server side. Looks only: nothing here touches stats, gold, items,
	XP or a run's power.

	  StoreBuy (itemId, giftToUserId?)  checks the item (a store cosmetic, a skin pass, the
	        Supporter pass or an early hero unlock with a real id), that the buyer (or the
	        gift target) does not own it yet, and opens the Roblox prompt FROM THE SERVER.
	        A gift remembers { Target, ProductId } for the buyer for Config.Store.GiftSeconds.
	  ProcessReceipt (MonetizationService) asks GiftRoute(buyer, productId, purchaseId):
	        a gift is granted into the recipient's save while they are still in this server
	        (checked again at receipt time, saved before the receipt is acknowledged); when
	        they left it goes to the buyer instead. The route is kept per PurchaseId, so a
	        retried receipt goes to the same player; owned looks are a set, so a retry never
	        grants twice, and the buyer's PurchaseIds stay the idempotency record.
	  StoreEquip (kind, id)   wears an owned Trail / Burst / Pet / Emote / Nameplate / Dais
	        ("" = none); ("Sync") re-checks earned looks. Ownership is decided here only.
	  StoreEmote ()           plays the worn emote (attribute CosEmoteAt), with a cooldown.

	Ownership never comes from the client: products are recorded in data.Cosmetics.Owned by
	the receipt, earned looks by the save's own stats (StoreCatalog.Earned; never for a
	DEV-boosted profile), skins and the Supporter plate by the live pass lookup.
	The worn ids go to every client as player attributes (StoreCatalog.Attr, Supporter);
	StoreFx draws them. With the switch off nothing is set and nothing is offered.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local CosmeticData = require(Shared.CosmeticData)
local StoreCatalog = require(Shared.StoreCatalog)
local CharacterData = require(Shared.CharacterData)

local StoreService = {}

local ctx
local GOLD = Color3.fromRGB(255, 215, 80)

type Gift = { Target: number, TargetName: string, ProductId: number, Item: string, At: number, Delivered: boolean? }
local pendingGift: { [Player]: Gift } = {}
local routes: { [string]: Gift } = {} -- purchaseId → the gift it was routed as
local prompted: { [Player]: { Id: number, At: number } } = {}
local lastEmote: { [Player]: number } = {}

local function on(): boolean
	return Config.FeatureOn("Store")
end

local function store(): any
	return Config.Store or {}
end

local function cosmetics(data: { [string]: any }): { Owned: { [string]: boolean }, Equipped: { [string]: string } }
	local c = data.Cosmetics
	if type(c) ~= "table" then
		c = { Owned = {}, Equipped = {} }
		data.Cosmetics = c
	end
	if type(c.Owned) ~= "table" then
		c.Owned = {}
	end
	if type(c.Equipped) ~= "table" then
		c.Equipped = {}
	end
	return c
end

local function result(player: Player, kind: string, ok: boolean, text: string)
	Remotes.FireClient("StoreResult", player, { Kind = kind, Ok = ok, Text = text })
end

local function notify(player: Player, text: string, color: Color3?)
	if ctx and ctx.RunManager and ctx.RunManager.Notify then
		ctx.RunManager.Notify(player, text, color or GOLD)
	end
end

local function sync(player: Player)
	if ctx and ctx.GoldSystem and ctx.GoldSystem.SyncProfile then
		ctx.GoldSystem.SyncProfile(player)
	end
end

------------------------------------------------------------------------------------------
-- Items and ownership
------------------------------------------------------------------------------------------

-- The Config.Monetization group of a Store entry ("Cosmetics", "SkinPasses", ...).
local function group(e: any): string?
	return type(e.StoreKey) == "string" and string.match(e.StoreKey, "^(%w+)%.") or nil
end

local function isPassEntry(e: any): boolean
	local g = group(e)
	return g == "SkinPasses" or g == "GamePasses" or g == "CosmeticPasses"
end

-- A hero that may be unlocked early: listed, shipped in CharacterData (NewHeroes on), and
-- also earned by play (an achievement unlock or a gold price earned in runs). Never a
-- starting hero.
function StoreService.HeroBuyable(heroId: string): boolean
	return table.find(StoreCatalog.HeroUnlocks, heroId) ~= nil and StoreCatalog.HeroEarnable(CharacterData.Characters[heroId])
end

local function heroProduct(heroId: string): number
	local id = (Config.Monetization :: any).HeroUnlocks and (Config.Monetization :: any).HeroUnlocks[heroId]
	return type(id) == "number" and id or 0
end

-- productId → { Kind = "Cosmetic" | "Hero", Id } for every configured store product.
function StoreService.ProductMap(): { [number]: { Kind: string, Id: string } }
	local map = {}
	for _, e in ipairs(StoreCatalog.Entries) do
		if e.Source == "Store" and group(e) == "Cosmetics" then
			local pid = CosmeticData.StoreId(e.Id)
			if pid ~= 0 then
				map[pid] = { Kind = "Cosmetic", Id = e.Id }
			end
		end
	end
	for _, heroId in ipairs(StoreCatalog.HeroUnlocks) do
		local pid = heroProduct(heroId)
		if pid ~= 0 then
			map[pid] = { Kind = "Hero", Id = heroId }
		end
	end
	return map
end

function StoreService.IsSupporter(player: Player, data: { [string]: any }?): boolean
	local M = ctx and ctx.MonetizationService
	local id = (Config.Monetization :: any).CosmeticPasses and (Config.Monetization :: any).CosmeticPasses.Supporter or 0
	if M and id ~= 0 and M.OwnsPassId(player, id) then
		return true
	end
	-- the pass was seen owned before (data.Supporter is never cleared on load)
	return data ~= nil and data.Supporter == true
end

-- True when this player owns cosmetic `id` (any kind but Title).
function StoreService.Owns(player: Player, data: { [string]: any }, id: string): boolean
	local e = CosmeticData.Get(id)
	if not e or e.Kind == "Title" or (e :: any).Weapon then
		return false -- titles: AchievementService; weapon mastery glows: LOBBY (per weapon)
	end
	if e.Source == "Default" then
		return true
	end
	if e.Kind == "Skin" then
		local M = ctx and ctx.MonetizationService
		return M ~= nil and M.OwnsSkin(player, id)
	end
	if cosmetics(data).Owned[id] == true then
		return true
	end
	if e.Source == "Earned" then
		return data.DevBoosted ~= true and StoreCatalog.Earned(id, data)
	end
	if group(e) == "CosmeticPasses" then
		return StoreService.IsSupporter(player, data)
	end
	return false
end

-- Records every earned look the save has reached (never for a DEV-boosted profile).
-- Returns true when something new was added.
function StoreService.SyncEarned(data: { [string]: any }): boolean
	if not on() or data.DevBoosted == true then
		return false
	end
	local owned = cosmetics(data).Owned
	local added = false
	for _, e in ipairs(StoreCatalog.Entries) do
		if e.Source == "Earned" and not owned[e.Id] and StoreCatalog.Earned(e.Id, data) then
			owned[e.Id] = true
			added = true
		end
	end
	return added
end

-- Publishes the worn looks (and the Supporter flag) as player attributes for StoreFx.
-- A worn id the player no longer owns shows as nothing (the save keeps it).
function StoreService.Apply(player: Player)
	if not on() or not player.Parent then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	local worn = cosmetics(data).Equipped
	for _, kind in ipairs(StoreCatalog.Slots) do
		local id = type(worn[kind]) == "string" and worn[kind] or ""
		if id ~= "" and not StoreService.Owns(player, data, id) then
			id = ""
		end
		player:SetAttribute(StoreCatalog.Attr[kind], id)
	end
	local supporter = StoreService.IsSupporter(player, data)
	if supporter then
		data.Supporter = true
	end
	player:SetAttribute("Supporter", supporter)
end

-- The lobby view (GoldSystem.SyncProfile sends it as ProfileSync.Store).
function StoreService.View(player: Player, data: { [string]: any }): { [string]: any }?
	if not on() then
		return nil
	end
	local owned = {}
	for _, id in ipairs(CosmeticData.Order) do
		local e = CosmeticData.Items[id]
		if e.Kind ~= "Title" and e.Kind ~= "Skin" and StoreService.Owns(player, data, id) then
			owned[id] = true
		end
	end
	local worn = {}
	local saved = cosmetics(data).Equipped
	for _, kind in ipairs(StoreCatalog.Slots) do
		local id = type(saved[kind]) == "string" and saved[kind] or ""
		worn[kind] = (id ~= "" and owned[id]) and id or ""
	end
	return { Owned = owned, Equipped = worn, Supporter = StoreService.IsSupporter(player, data) }
end

------------------------------------------------------------------------------------------
-- Grants (receipts)
------------------------------------------------------------------------------------------

-- Gives a store item to the player whose save `data` is (a cosmetic or an early hero).
-- Returns the name shown in the thank-you line.
function StoreService.GrantItem(player: Player, data: { [string]: any }, item: { Kind: string, Id: string }): string
	if item.Kind == "Hero" then
		assert(CharacterData.Characters[item.Id], "unknown hero " .. tostring(item.Id))
		data.OwnedCharacters = type(data.OwnedCharacters) == "table" and data.OwnedCharacters or {}
		data.OwnedCharacters[item.Id] = true
		return CharacterData.Characters[item.Id].Name or item.Id
	end
	local e = assert(CosmeticData.Get(item.Id), "unknown cosmetic " .. tostring(item.Id))
	cosmetics(data).Owned[item.Id] = true
	return e.Name
end

local function afterGrant(player: Player, text: string)
	task.defer(function()
		if not player.Parent then
			return
		end
		StoreService.Apply(player)
		sync(player)
		if ctx.RunManager.RefreshLobbyCharacter then
			pcall(ctx.RunManager.RefreshLobbyCharacter, player)
		end
		notify(player, text)
	end)
end

-- Product handler for one productId (MonetizationService builds these).
function StoreService.Handler(productId: number): ((Player, { [string]: any }) -> ())?
	local item = StoreService.ProductMap()[productId]
	if not item then
		return nil
	end
	return function(player, data)
		local name = StoreService.GrantItem(player, data, item)
		afterGrant(player, name .. " is yours. Thank you!")
	end
end

-- The gift this receipt pays for, if any: (gift) when the buyer picked a target for this
-- product shortly before; nil = a normal purchase for the buyer.
function StoreService.GiftRoute(buyer: Player, productId: number, purchaseId: string): Gift?
	local known = routes[purchaseId]
	if known then
		return known
	end
	local g = pendingGift[buyer]
	if not g or g.ProductId ~= productId or os.clock() - g.At > (store().GiftSeconds or 300) then
		return nil
	end
	pendingGift[buyer] = nil
	routes[purchaseId] = g
	return g
end

--[[
	Grants a gift (called from ProcessReceipt with the buyer's save). Returns false when it
	could not be saved yet (the receipt stays unacknowledged and Roblox retries).
	The recipient is looked up again here: still in this server with a loaded profile →
	their save (saved first); gone → the buyer's own save.
]]
function StoreService.GrantGift(buyer: Player, buyerData: { [string]: any }, g: Gift): boolean
	local item = StoreService.ProductMap()[g.ProductId]
	if not item then
		return false
	end
	local recipient = Players:GetPlayerByUserId(g.Target)
	local profile = recipient and ctx.DataService.GetProfile(recipient)
	-- the recipient got this look some other way after the prompt opened (bought or was
	-- gifted it): the buyer keeps it instead of paying for nothing (REVIEW R-04)
	-- (a retried receipt of a gift already delivered keeps its route: g.Delivered)
	local already = not g.Delivered and recipient ~= nil and profile ~= nil and item.Kind == "Cosmetic"
		and StoreService.Owns(recipient, profile.Data, item.Id)
	if recipient and recipient ~= buyer and profile and not profile.Released and not profile.LockLost and not already then
		local name = StoreService.GrantItem(recipient, profile.Data, item)
		g.Delivered = true
		if not ctx.DataService.ForceSave(recipient) then
			return false
		end
		afterGrant(recipient, buyer.DisplayName .. " sent you a gift: " .. name .. "!")
		task.defer(function()
			notify(buyer, "Gift sent: " .. name .. " to " .. g.TargetName .. ". Thank you!")
			result(buyer, "Gift", true, "Gift sent to " .. g.TargetName .. ".")
		end)
		return true
	end
	-- the recipient left (or owns it already) before the purchase finished: the buyer keeps it
	local name = StoreService.GrantItem(buyer, buyerData, item)
	afterGrant(buyer, g.TargetName .. (already and " owns it already" or " left") .. ", so " .. name .. " is yours. Thank you!")
	return true
end

------------------------------------------------------------------------------------------
-- Remotes
------------------------------------------------------------------------------------------

local function prompt(player: Player, id: number, isPass: boolean)
	prompted[player] = { Id = id, At = os.clock() }
	local ok = pcall(function()
		if isPass then
			MarketplaceService:PromptGamePassPurchase(player, id)
		else
			MarketplaceService:PromptProductPurchase(player, id)
		end
	end)
	if not ok then
		prompted[player] = nil
		result(player, "Buy", false, "The store could not open. Please try again.")
	end
end

local function onBuy(player: Player, itemId: any, target: any)
	if not on() or type(itemId) ~= "string" or #itemId > 64 then
		return
	end
	if target ~= nil and (type(target) ~= "number" or target ~= target or target % 1 ~= 0) then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	local pid, isPass, owned = 0, false, false
	local heroId = string.match(itemId, "^Hero_(%w+)$")
	if heroId then
		if not StoreService.HeroBuyable(heroId) then
			result(player, "Buy", false, "That hero is coming soon.")
			return
		end
		pid = heroProduct(heroId)
		owned = type(data.OwnedCharacters) == "table" and data.OwnedCharacters[heroId] == true
		if target ~= nil then
			result(player, "Gift", false, "Heroes can't be gifted.")
			return
		end
	else
		local e = CosmeticData.Get(itemId)
		if not e or e.Source ~= "Store" then
			return
		end
		pid = CosmeticData.StoreId(itemId)
		isPass = isPassEntry(e)
		owned = StoreService.Owns(player, data, itemId)
		if target ~= nil and isPass then
			result(player, "Gift", false, "Passes can't be gifted.")
			return
		end
	end
	if pid == 0 then
		result(player, "Buy", false, "Coming soon.")
		return
	end
	if target == nil then
		pendingGift[player] = nil
		if owned then
			result(player, "Buy", false, "You own this already.")
			return
		end
		prompt(player, pid, isPass)
		return
	end
	-- gift: a real player in this server, not the buyer, profile loaded, not owning it
	local recipient = Players:GetPlayerByUserId(target)
	if not recipient or recipient == player then
		result(player, "Gift", false, "Pick a player in this server.")
		return
	end
	local rdata = ctx.DataService.GetData(recipient)
	if not rdata then
		result(player, "Gift", false, recipient.DisplayName .. " is still loading. Try again soon.")
		return
	end
	if StoreService.Owns(recipient, rdata, itemId) then
		result(player, "Gift", false, recipient.DisplayName .. " owns this already.")
		return
	end
	pendingGift[player] = { Target = recipient.UserId, TargetName = recipient.DisplayName, ProductId = pid, Item = itemId, At = os.clock() }
	prompt(player, pid, false)
end

local function onEquip(player: Player, kind: any, id: any)
	if not on() then
		return
	end
	local data = ctx.DataService.GetData(player)
	if not data then
		return
	end
	if kind == "Sync" then
		StoreService.SyncEarned(data)
		StoreService.Apply(player)
		sync(player)
		return
	end
	if type(kind) ~= "string" or not StoreCatalog.Attr[kind] or type(id) ~= "string" or #id > 64 then
		return
	end
	if id == kind .. "_None" then
		id = ""
	end
	if id ~= "" then
		local e = CosmeticData.Get(id)
		if not e or e.Kind ~= kind or (e :: any).Weapon or not StoreService.Owns(player, data, id) then
			result(player, "Equip", false, "You don't own that yet.")
			sync(player)
			return
		end
		if e.Source == "Earned" then
			cosmetics(data).Owned[id] = true
		end
	end
	cosmetics(data).Equipped[kind] = id
	StoreService.Apply(player)
	sync(player)
end

local function onEmote(player: Player)
	if not on() then
		return
	end
	local id = player:GetAttribute("CosEmote")
	if type(id) ~= "string" or id == "" then
		return
	end
	local now = os.clock()
	if lastEmote[player] and now - lastEmote[player] < (store().EmoteCooldown or 3) then
		return
	end
	lastEmote[player] = now
	player:SetAttribute("CosEmoteAt", workspace:GetServerTimeNow())
end

-- A store prompt closed without a purchase: a calm line (nothing was charged).
local function onPromptClosed(player: Player?, id: number, purchased: boolean)
	if not player or purchased then
		return
	end
	local p = prompted[player]
	if not p or p.Id ~= id then
		return
	end
	prompted[player] = nil
	local g = pendingGift[player]
	if g and g.ProductId == id then
		pendingGift[player] = nil
	end
	result(player, "Buy", false, "No purchase made. Nothing was charged.")
end

------------------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------------------

function StoreService.Init(c)
	ctx = c
end

function StoreService.Start()
	Remotes.Listen("StoreBuy", onBuy, 2)
	Remotes.Listen("StoreEquip", onEquip, 6)
	Remotes.Listen("StoreEmote", onEmote, 2)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		onPromptClosed(Players:GetPlayerByUserId(userId), productId, purchased == true)
	end)
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		onPromptClosed(player, passId, purchased == true)
	end)
	ctx.DataService.OnProfileLoaded(function(player)
		if not on() then
			return
		end
		local data = ctx.DataService.GetData(player)
		if data then
			StoreService.SyncEarned(data)
		end
		StoreService.Apply(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		pendingGift[player] = nil
		prompted[player] = nil
		lastEmote[player] = nil
	end)
end

-- (tests)
StoreService._Pending = pendingGift
StoreService._OnBuy = onBuy
StoreService._OnEquip = onEquip

return StoreService
