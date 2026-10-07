--[[
	StarterBundle.lua (Config.Features.StarterBundle; docs/next/STARTER_BUNDLE.md)
	One developer product, once per account: the "Pioneer" Knight skin (CharacterData skin
	Pass = "StarterBundle"; PENDING owner OK), Config.StarterBundle.Gold gold and the
	"Pioneer" title. Cosmetic + gold only, never power.

	  Product id  Config.Monetization.StarterBundle; 0 = hidden (no card, no prompt, no
	              handler). The owner creates the product and sets its price on Roblox; the
	              client shows the price from GetProductInfo only.
	  Offer       open while: switch on, id set, not owned (save flag StarterBundleOwned) and
	              the save is younger than Config.StarterBundle.OfferDays (save field
	              FirstJoin; 0 = an account from before this field: never offered).
	              Published as player attributes for the lobby: StarterOffer (bool),
	              StarterEnds (unix end of the offer, 0 = none), StarterOwned (bool).
	  Buying      remote "StarterBundle" ("Buy"): the server checks the offer and opens the
	              Roblox prompt FROM THE SERVER.
	  Receipt     MonetizationService routes the product id to StarterBundle.Handler (its
	              PurchaseId idempotency and save-before-acknowledge apply as for every
	              product). The flag is set before anything is paid; the skin is owned through
	              the flag (MonetizationService.OwnsSkin), the title goes into Titles.Owned.
	              A second purchase can only happen through a race between two servers: it
	              is acknowledged and pays the gold again (the cosmetics are already owned),
	              so nobody pays for nothing.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Config = require(Shared.Config)
local Remotes = require(Shared.Remotes)
local MetaData = require(Shared.MetaData)

local StarterBundle = {}

local ctx
local GOLD = Color3.fromRGB(255, 215, 80)
local DAY = 86400

local function cfg(): { [string]: any }
	return (Config :: any).StarterBundle or {}
end

function StarterBundle.On(): boolean
	return Config.FeatureOn("StarterBundle")
end

-- The product id (0 = not created yet: everything is hidden).
function StarterBundle.ProductId(): number
	local id = (Config.Monetization :: any).StarterBundle
	return (type(id) == "number" and id == id and id > 0) and math.floor(id) or 0
end

function StarterBundle.Owned(data: { [string]: any }?): boolean
	return data ~= nil and data.StarterBundleOwned == true
end

-- The unix time the offer ends for this save (0 = never offered: an older account).
function StarterBundle.EndsAt(data: { [string]: any }?): number
	local first = data and tonumber(data.FirstJoin) or 0
	if not first or first ~= first or first <= 0 or first == math.huge then
		return 0
	end
	return math.floor(first + (tonumber(cfg().OfferDays) or 7) * DAY)
end

-- True while the home card / store card may offer the bundle to this save.
function StarterBundle.OfferOpen(data: { [string]: any }?, now: number?): boolean
	if not StarterBundle.On() or StarterBundle.ProductId() == 0 or not data or StarterBundle.Owned(data) then
		return false
	end
	local ends = StarterBundle.EndsAt(data)
	return ends > 0 and (now or os.time()) < ends
end

-- Player attributes the lobby reads (StarterCard, MenuStarter, MenuStore).
function StarterBundle.Publish(player: Player)
	if not player.Parent then
		return
	end
	local data = ctx and ctx.DataService.GetData(player)
	local open = StarterBundle.OfferOpen(data)
	local function set(name: string, value: any)
		if player:GetAttribute(name) ~= value then
			player:SetAttribute(name, value)
		end
	end
	set("StarterOffer", open)
	set("StarterEnds", open and StarterBundle.EndsAt(data) or 0)
	set("StarterOwned", StarterBundle.On() and StarterBundle.Owned(data))
end

-- The receipt handler (MonetizationService): only changes `data`; the rest is deferred.
function StarterBundle.Handler(player: Player, data: { [string]: any })
	local c = cfg()
	local gold = math.max(0, math.floor(tonumber(c.Gold) or 0))
	local again = data.StarterBundleOwned == true
	data.StarterBundleOwned = true
	data.Gold += gold
	-- the title (worn at once when none is worn, like the other titles)
	local titleId = type(c.Title) == "string" and c.Title or "Title_Pioneer"
	if type(data.Titles) ~= "table" then
		data.Titles = { Owned = {} }
	end
	if type(data.Titles.Owned) ~= "table" then
		data.Titles.Owned = {}
	end
	data.Titles.Owned[titleId] = true
	if data.Title == nil or data.Title == "" then
		local def = MetaData.TitleById[titleId]
		data.Title = def and def.Name or (string.gsub(titleId, "^Title_", ""))
	end
	task.defer(function()
		if not player.Parent then
			return
		end
		StarterBundle.Publish(player)
		if ctx.MonetizationService then
			ctx.MonetizationService.RefreshAttributes(player) -- worn looks / title plates
		end
		if ctx.GoldSystem then
			ctx.GoldSystem.SyncProfile(player)
		end
		if ctx.RunManager then
			local text = again and string.format("+%d gold. Thank you!", gold)
				or string.format("Starter Bundle: Pioneer skin, Pioneer title and +%d gold. Thank you!", gold)
			ctx.RunManager.Notify(player, text, GOLD, { Id = "starter.bundle" })
		end
	end)
end

local prompted: { [Player]: number } = {}

local function onRemote(player: Player, action: any)
	if action ~= "Buy" or not StarterBundle.On() then
		return
	end
	local data = ctx.DataService.GetData(player)
	local id = StarterBundle.ProductId()
	if id == 0 or not data then
		return
	end
	if not StarterBundle.OfferOpen(data) then
		StarterBundle.Publish(player)
		if ctx.RunManager then
			ctx.RunManager.Notify(player, StarterBundle.Owned(data) and "You already own the Starter Bundle." or "The Starter Bundle offer has ended.", GOLD, { Id = "starter.closed" })
		end
		return
	end
	-- one prompt at a time (a double tap opens one)
	local last = prompted[player]
	if last and os.clock() - last < 2 then
		return
	end
	prompted[player] = os.clock()
	pcall(function()
		MarketplaceService:PromptProductPurchase(player, id)
	end)
end

function StarterBundle.Init(c)
	ctx = c
end

function StarterBundle.Start()
	Remotes.Listen("StarterBundle", onRemote, 2)
	ctx.DataService.OnProfileLoaded(function(player)
		StarterBundle.Publish(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		prompted[player] = nil
	end)
	-- the offer ends while a player is online: the card goes away within a minute
	task.spawn(function()
		while true do
			task.wait(30)
			for _, player in ipairs(Players:GetPlayers()) do
				pcall(StarterBundle.Publish, player)
			end
		end
	end)
end

return StarterBundle
