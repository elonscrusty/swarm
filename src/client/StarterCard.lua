--[[
	StarterCard.lua (Config.Features.StarterBundle; docs/next/STARTER_BUNDLE.md)
	The Starter Bundle's small home-screen card and the shared client helpers (offer state,
	the Robux price, the BUY request). The server decides everything (StarterBundle.lua):
	the card shows only while the player attribute StarterOffer is true, i.e. the switch is
	on, Config.Monetization.StarterBundle is set, the bundle is not owned and the account is
	in its first Config.StarterBundle.OfferDays days. A tap opens the STARTER BUNDLE screen
	(MenuStarter).

	The card sits in the TOP SCORES column on landscape screens (the board moves down under
	it) and under the TOP SCORES strip in portrait, only where the hero keeps its room
	(LobbyScreen.relayout): it never covers PLAY, the hero or TOP SCORES.
	The price only ever comes from MarketplaceService:GetProductInfo.
]]

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local Workspace = game:GetService("Workspace")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(script.Parent.UIKit)

local StarterCard = {}

local player = Players.LocalPlayer
StarterCard.Height = 58

local price: number? = nil
local asking = false
local priceListeners: { () -> () } = {}

-- The product id (0 = hidden).
function StarterCard.ProductId(): number
	local id = (Config.Monetization :: any).StarterBundle
	return (type(id) == "number" and id > 0) and id or 0
end

-- True while the server offers the bundle to this player.
function StarterCard.Offered(): boolean
	return Config.FeatureOn("StarterBundle") and StarterCard.ProductId() ~= 0 and player:GetAttribute("StarterOffer") == true
end

function StarterCard.Owned(): boolean
	return Config.FeatureOn("StarterBundle") and player:GetAttribute("StarterOwned") == true
end

local function now(): number
	local ok, t = pcall(function()
		return Workspace:GetServerTimeNow()
	end)
	return (ok and type(t) == "number" and t > 0) and t or os.time()
end

-- "6d left" / "5h left" for the offer (server end time), "" when unknown.
function StarterCard.TimeLeft(): string
	local ends = tonumber(player:GetAttribute("StarterEnds")) or 0
	local left = ends - now()
	if ends <= 0 or left <= 0 then
		return ""
	end
	if left >= 86400 then
		return string.format("%dd left", math.floor(left / 86400))
	elseif left >= 3600 then
		return string.format("%dh left", math.floor(left / 3600))
	end
	return string.format("%dm left", math.max(1, math.floor(left / 60)))
end

-- "R$ 99" once Roblox answered, else nil (asks once in the background; onPrice is called
-- when the answer arrives).
function StarterCard.Price(onPrice: (() -> ())?): string?
	if price then
		return "R$ " .. UIKit.formatNumber(price)
	end
	if onPrice then
		table.insert(priceListeners, onPrice)
	end
	local id = StarterCard.ProductId()
	if id ~= 0 and not asking then
		asking = true
		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(id, Enum.InfoType.Product)
			end)
			asking = false
			if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
				price = info.PriceInRobux
				local list = priceListeners
				priceListeners = {}
				for _, fn in ipairs(list) do
					pcall(fn)
				end
			end
		end)
	end
	return nil
end

-- Asks the server to open the Roblox prompt (it checks the offer again).
function StarterCard.Buy()
	Remotes.Get("StarterBundle"):FireServer("Buy")
end

-- One line of what is inside ("Pioneer Knight skin · 2,000 gold · Pioneer title").
function StarterCard.Contents(): string
	local c = (Config :: any).StarterBundle or {}
	return string.format("Pioneer Knight skin · %s gold · Pioneer title", UIKit.formatNumber(tonumber(c.Gold) or 0))
end

--[[
	The home card. opts = { Open = () -> (), Relayout = () -> () }. Returns
	{ Wanted, Place(x, y, w, portrait) -> bottom y (y when hidden), Hide }.
]]
function StarterCard.Build(parent: Instance, opts: { [string]: any })
	local btn = UIKit.Button(parent, {
		Kind = "Outline",
		Title = "STARTER BUNDLE",
		Subtitle = "",
		Icon = "gift",
		IconSize = 26,
		TitleStyle = "Label",
		TitleSize = 15,
		Chevron = true,
		Align = "Left",
		Shrink = true,
		Name = "StarterCard",
		Shadow = false,
		OnClick = function()
			if opts.Open then
				opts.Open()
			end
		end,
	})
	btn.Instance.Visible = false
	local api = {}
	local function subText(): string
		local left = StarterCard.TimeLeft()
		local c = (Config :: any).StarterBundle or {}
		local s = string.format("Skin + %s gold", UIKit.formatNumber(tonumber(c.Gold) or 0))
		return left ~= "" and (s .. " · " .. left) or s
	end
	function api.Wanted(): boolean
		return StarterCard.Offered()
	end
	function api.Place(x: number, y: number, w: number, _portrait: boolean?): number
		if not api.Wanted() or w < 150 then
			btn.Instance.Visible = false
			return y
		end
		btn.SetText(nil, subText())
		btn.Instance.Position = UDim2.fromOffset(math.floor(x + 0.5), math.floor(y + 0.5))
		btn.Instance.Size = UDim2.fromOffset(math.floor(w + 0.5), StarterCard.Height)
		btn.Instance.Visible = true
		return y + StarterCard.Height
	end
	function api.Hide()
		btn.Instance.Visible = false
	end
	api.Button = btn
	local function changed()
		if opts.Relayout then
			opts.Relayout()
		end
	end
	player:GetAttributeChangedSignal("StarterOffer"):Connect(changed)
	player:GetAttributeChangedSignal("StarterEnds"):Connect(function()
		if btn.Instance.Visible then
			btn.SetText(nil, subText())
		end
	end)
	-- the "6d left" line follows the clock
	task.spawn(function()
		while btn.Instance.Parent do
			task.wait(60)
			if btn.Instance.Visible then
				btn.SetText(nil, subText())
			end
		end
	end)
	return api
end

return StarterCard
