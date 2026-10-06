--[[
	Merchant.lua
	Feature 6, MERCHANT CART (Config.Features.Merchant, Config.Explore.Merchant,
	docs/features/EXPLORE.md). A placed EncounterDirector encounter: at most one cart per
	stage, on a spot the director reserved. It leaves when the stage ends.

	Stock is PER PLAYER: each run player gets their own Slots (3) items, rolled the first
	time they come near (ItemSystem.Roll with Merchant.Weights and their luck, all
	different). Each item can be bought once, for RUN gold only.

	Price = what a chest of the item's rarity costs on this stage, through the existing
	helpers: ItemData.StagePrice(chest cost of the rarity's PriceChest, stage,
	Config.Chests.CostExponent) x ItemData.PlayerPrice(GoldSystem.PriceMult) (Common = the
	Small chest, Uncommon = the Large chest, Legendary = the Golden chest). The client
	computes the shown price with the same helpers and the GoldMult attribute it was sent
	(like LootUI), so shown price = charged price. No new price formula.

	Buying: remote MerchantBuy(merchantId, slot). The server checks the run (simulating),
	the player (alive, not returned, not choosing a card), the range, the slot (unsold) and
	the wallet; then takes the gold, marks the slot sold (exactly once) and grants the item
	(ItemSystem.Grant + the reward reel, like a chest). Every answer re-sends the stock
	(remote MerchantStock) so the client's panel never drifts.

	World: model "Merchant" in workspace.SwarmEvents: EventKind = "Merchant", Title, State
	("Open"), Pos, Radius, MerchantId.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local ItemData = require(game:GetService("ReplicatedStorage").Shared.ItemData)
local Remotes = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)
local ModelBuilder = require(script.Parent.ModelBuilder)
local MapBuilder = require(script.Parent.MapBuilder)
local Fx = require(script.Parent.Fx)
local EncounterDirector = require(script.Parent.EncounterDirector)

local Merchant = {}

local NAME = "Merchant"
local P = Palette :: { [string]: Color3 }
local part = ModelBuilder.Part
local FLAT = Vector3.new(1, 0, 1)
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

type Offer = { Id: string, Rarity: string, Price: number, Sold: boolean }
type Cart = {
	Id: number,
	Pos: Vector3,
	Stage: number,
	Model: Model,
	Stock: { [any]: { Offer } }, -- the player's UserId (rp for a test record) -> offers
}

local ctx
local cart: Cart? = nil
local nextId = 0
local sentNear: { [any]: boolean } = {} -- rp -> stock sent while near (re-sent on approach)

local function K()
	return Config.Explore.Merchant
end

local function eventsFolder(): Folder
	local f = workspace:FindFirstChild("SwarmEvents")
	if not f then
		f = Instance.new("Folder")
		f.Name = "SwarmEvents"
		f.Parent = workspace
	end
	return f :: Folder
end

------------------------------------------------------------------------------------------
-- Prices
------------------------------------------------------------------------------------------

-- This stage's price of an item of `rarity`, before the player's gold multiplier: the
-- chest of that rarity (Config.Explore.Merchant.PriceChest → Config.Chests.Cost).
function Merchant.StagePrice(rarity: string, stage: number): number
	local chest = K().PriceChest[rarity] or "Small"
	return ItemData.StagePrice(Config.Chests.Cost[chest] or 25, stage, Config.Chests.CostExponent)
end

local function priceFor(rp, offer: Offer): number
	return ItemData.PlayerPrice(offer.Price, ctx.GoldSystem.PriceMult(rp.Player))
end

------------------------------------------------------------------------------------------
-- Model
------------------------------------------------------------------------------------------

local function add(m: Model, cf: CFrame, name: string, size: Vector3, at: Vector3, color: Color3, material: Enum.Material?, shape: Enum.PartType?, rot: CFrame?): BasePart
	local p = part({ Name = name, Shape = shape, Size = size, CFrame = cf * CFrame.new(at) * (rot or CFrame.identity), Color = color, Material = material, CastShadow = name == "Bed" or name == "Awning" })
	p.Parent = m
	return p
end

-- A part-built market cart: a wooden bed on two wheels, a striped awning on four posts,
-- goods (crates, a sack, three item orbs in the rarity colours), a hanging lantern and a
-- hooded trader beside it.
local function buildCart(m: Model, cf: CFrame)
	local wood, dark = P.wood_500, P.wood_700
	add(m, cf, "Bed", Vector3.new(6, 0.7, 3.4), Vector3.new(0, 1.8, 0), wood)
	add(m, cf, "Rail", Vector3.new(6, 0.5, 0.2), Vector3.new(0, 2.35, -1.6), dark)
	add(m, cf, "Rail", Vector3.new(6, 0.5, 0.2), Vector3.new(0, 2.35, 1.6), dark)
	local axle = CFrame.Angles(0, math.rad(90), 0)
	add(m, cf, "Wheel", Vector3.new(0.35, 2.4, 2.4), Vector3.new(1.2, 1.2, -1.9), dark, nil, Enum.PartType.Cylinder, axle)
	add(m, cf, "Wheel", Vector3.new(0.35, 2.4, 2.4), Vector3.new(1.2, 1.2, 1.9), dark, nil, Enum.PartType.Cylinder, axle)
	add(m, cf, "Leg", Vector3.new(0.3, 1.5, 0.3), Vector3.new(-2.6, 0.75, -1.3), dark)
	add(m, cf, "Leg", Vector3.new(0.3, 1.5, 0.3), Vector3.new(-2.6, 0.75, 1.3), dark)
	for _, x in ipairs({ -2.8, 2.8 }) do
		for _, z in ipairs({ -1.6, 1.6 }) do
			add(m, cf, "Post", Vector3.new(0.22, 3.4, 0.22), Vector3.new(x, 3.85, z), dark)
		end
	end
	-- striped awning (crimson / ivory)
	for i = 0, 5 do
		local color = i % 2 == 0 and P.crimson_500 or P.ivory_200
		add(m, cf, "Awning", Vector3.new(1.05, 0.18, 4.2), Vector3.new(-2.65 + i * 1.06, 5.7, 0), color, Enum.Material.Fabric, nil, CFrame.Angles(math.rad(-8), 0, 0))
	end
	-- goods
	add(m, cf, "Crate", Vector3.new(1.2, 1.0, 1.2), Vector3.new(-1.8, 2.65, 0.6), P.wood_400)
	add(m, cf, "Sack", Vector3.new(1.1, 1.1, 1.1), Vector3.new(1.9, 2.65, 0.7), P.sand_400, Enum.Material.Fabric, Enum.PartType.Ball)
	for i, c in ipairs({ P.ivory_200, P.slate_300, P.gold_300 }) do
		add(m, cf, "Orb", Vector3.new(0.7, 0.7, 0.7), Vector3.new(-0.9 + (i - 1) * 0.9, 2.55, -0.9), c, Enum.Material.Neon, Enum.PartType.Ball)
	end
	-- lantern
	local lantern = add(m, cf, "Lantern", Vector3.new(0.7, 0.7, 0.7), Vector3.new(2.8, 4.6, -1.6), P.gold_300, Enum.Material.Neon, Enum.PartType.Ball)
	local l = Instance.new("PointLight")
	l.Color = P.gold_300
	l.Range = 14
	l.Brightness = 1
	l.Shadows = false
	l.Parent = lantern
	-- the trader: a hooded figure on the camera side
	local tcf = cf * CFrame.new(-3.9, 0, -1.8)
	add(m, tcf, "Robe", Vector3.new(1.6, 2.6, 1.6), Vector3.new(0, 1.3, 0), P.moss_600, Enum.Material.Fabric, Enum.PartType.Cylinder, UPRIGHT)
	add(m, tcf, "Head", Vector3.new(1.0, 1.0, 1.0), Vector3.new(0, 3.05, 0), P.skin_400, nil, Enum.PartType.Ball)
	add(m, tcf, "Hood", Vector3.new(1.25, 0.9, 1.25), Vector3.new(0, 3.35, 0.1), P.moss_700, Enum.Material.Fabric, Enum.PartType.Ball)
	add(m, tcf, "Pack", Vector3.new(1.0, 1.2, 0.6), Vector3.new(0, 2.0, 0.9), P.leather_600)
	-- the "shop here" ring on the floor
	local r = K().InteractRadius
	local ring = part({ Name = "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, r * 2, r * 2), CFrame = CFrame.new(cf.Position + Vector3.new(0, 0.06, 0)) * UPRIGHT, Color = P.gold_300, Transparency = 0.9 })
	ring.Parent = m
	local anchor = part({ Name = "Anchor", Size = Vector3.new(0.2, 0.2, 0.2), CFrame = cf * CFrame.new(0, 7.4, 0), Transparency = 1 })
	anchor.Parent = m
end

------------------------------------------------------------------------------------------
-- Stock
------------------------------------------------------------------------------------------

local function rollStock(rp, c: Cart): { Offer }
	local list: { Offer } = {}
	local taken: { [string]: boolean } = {}
	local luck = rp.Stats and rp.Stats.Luck or 0
	for _ = 1, K().Slots do
		local id: string? = nil
		for _ = 1, 12 do
			local pick = ctx.ItemSystem.Roll(K().Weights, luck)
			if not taken[pick] then
				id = pick
				break
			end
		end
		if id then
			taken[id] = true
			local def = ItemData.Items[id]
			local rarity = def and def.Rarity or "Common"
			table.insert(list, { Id = id, Rarity = rarity, Price = Merchant.StagePrice(rarity, c.Stage), Sold = false })
		end
	end
	return list
end

-- The stock key of a run player: its UserId, so a reconnected player (RunManager makes a
-- new record from a copy) keeps its stock and its sold slots (REVIEW R-01).
local function stockKey(rp): any
	local player = rp.Player
	return (typeof(player) == "Instance" and player:IsA("Player")) and player.UserId or rp
end

local function stockOf(rp): { Offer }?
	local c = cart
	if not c then
		return nil
	end
	local key = stockKey(rp)
	local s = c.Stock[key]
	if not s then
		s = rollStock(rp, c)
		c.Stock[key] = s
	end
	return s
end

local function send(rp)
	local player: Player = rp.Player
	if not player or not player.Parent then
		return
	end
	local c = cart
	if not c then
		Remotes.FireClient("MerchantStock", player, { Id = 0 })
		return
	end
	local items = {}
	for i, o in ipairs(stockOf(rp) or {}) do
		items[i] = { Id = o.Id, Rarity = o.Rarity, Price = o.Price, Sold = o.Sold }
	end
	Remotes.FireClient("MerchantStock", player, { Id = c.Id, Stage = c.Stage, Items = items })
end

local function near(rp, c: Cart, pad: number?): boolean
	local root: BasePart? = rp.Root
	if not root or not rp.Alive or rp.Returned then
		return false
	end
	return ((root.Position - c.Pos) * FLAT).Magnitude <= K().InteractRadius + (pad or 0)
end

------------------------------------------------------------------------------------------
-- Buying
------------------------------------------------------------------------------------------

local function refuse(rp, text: string)
	ctx.RunManager.Notify(rp.Player, text, Color3.fromRGB(255, 120, 120))
	send(rp)
end

-- Returns true when the item was bought (tests use it directly).
function Merchant.Buy(rp, merchantId: any, slot: any): (boolean, string?)
	local c = cart
	if type(merchantId) ~= "number" or type(slot) ~= "number" or slot ~= math.floor(slot) then
		return false, "bad"
	end
	if not c or c.Id ~= merchantId then
		send(rp)
		return false, "gone"
	end
	if not ctx.RunManager.IsSimulating() or rp.Paused then
		send(rp)
		return false, "paused"
	end
	if not near(rp, c, 1.5) then
		refuse(rp, "Walk up to the merchant first.")
		return false, "far"
	end
	local stock = stockOf(rp)
	local offer = stock and stock[slot]
	if not offer then
		send(rp)
		return false, "bad"
	end
	if offer.Sold then
		send(rp)
		return false, "sold"
	end
	local price = priceFor(rp, offer)
	if ctx.GoldSystem.RunWallet(rp) < price or not ctx.GoldSystem.SpendRunGold(rp, price) then
		refuse(rp, "Not enough gold.")
		return false, "gold"
	end
	-- exactly once: sold before the grant, so no second request can buy it again
	offer.Sold = true
	local granted, dramatic = ctx.ItemSystem.Grant(rp, offer.Id, "Merchant", true)
	if granted then
		ctx.RunManager.HoldReward(rp, dramatic == true)
	else
		warn(string.format("[Merchant] %s paid %d for %s but no item could be granted", rp.Player.Name, price, offer.Id))
	end
	Fx.Sound("Chest")
	send(rp)
	return true, nil
end

local function onBuy(player: Player, merchantId: any, slot: any)
	local rp = ctx.RunManager.GetRunPlayer(player)
	if not rp or rp.Returned then
		return
	end
	Merchant.Buy(rp, merchantId, slot)
end

------------------------------------------------------------------------------------------
-- Director callbacks
------------------------------------------------------------------------------------------

local function cleanup(_reason: string?)
	local c = cart
	cart = nil
	if c then
		c.Model:Destroy()
		for rp in pairs(sentNear) do
			if rp.Player and rp.Player.Parent then
				Remotes.FireClient("MerchantStock", rp.Player, { Id = 0 })
			end
		end
	end
	table.clear(sentNear)
end

local function start(info): boolean
	cleanup("Restart")
	local spot = EncounterDirector.FindSpot(NAME, { Clearance = K().Clearance })
	if not spot then
		return false
	end
	nextId += 1
	local cf = CFrame.new(spot) * CFrame.Angles(0, math.pi + info.Rng:NextNumber(-0.4, 0.4), 0)
	local m = Instance.new("Model")
	m.Name = NAME
	buildCart(m, cf)
	local c: Cart = { Id = nextId, Pos = spot, Stage = math.max(1, info.Stage or 1), Model = m, Stock = {} }
	MapBuilder.AddCollider(info.Arena, { Kind = "Circle", Radius = 3.2, Height = 5 }, CFrame.new(spot))
	MapBuilder.ClearDecor(info.Arena, spot, K().InteractRadius)
	m:SetAttribute("EventKind", NAME)
	m:SetAttribute("Title", "Merchant")
	m:SetAttribute("State", "Open")
	m:SetAttribute("Pos", spot)
	m:SetAttribute("Radius", K().InteractRadius)
	m:SetAttribute("MerchantId", c.Id)
	m.Parent = eventsFolder()
	cart = c
	return true
end

-- Per frame: send each player their stock when they walk up (rolled then).
local function tick(_dt: number)
	local c = cart
	if not c then
		return
	end
	for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
		local isNear = near(rp, c, 4)
		if isNear and not sentNear[rp] then
			sentNear[rp] = true
			send(rp)
		elseif not isNear and sentNear[rp] then
			sentNear[rp] = nil
		end
	end
end

function Merchant.Get(): Cart?
	return cart
end

-- Tests: the offers of one run player (rolled on first use).
function Merchant.StockOf(rp): { Offer }?
	return stockOf(rp)
end

function Merchant.Init(c)
	ctx = c
	EncounterDirector.Register(NAME, {
		Feature = "Merchant",
		Weight = Config.Explore.Merchant.Weight,
		OnStageStart = start,
		OnTick = tick,
		OnCleanup = cleanup,
		OnPlayerOut = function(rp)
			sentNear[rp] = nil
		end,
	})
end

function Merchant.Start()
	Remotes.Listen("MerchantBuy", onBuy, 4)
end

return Merchant
