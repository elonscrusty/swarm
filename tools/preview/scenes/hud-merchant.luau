-- hud-merchant: the busiest moment of the mobile HUD: the hero at the merchant's cart with
-- its shop panel open (27 run gold, three offers at 63 gold: base 25 x the gold passes'
-- GoldMult 2.5), the portal revealed far away and a "WAVE 6" banner in its lane under the
-- top-centre stack. Prints PASS / FAIL lines for: the stack, the banner and the panel never
-- overlap; "RUN GOLD 27", dimmed "NEED 36 MORE" buttons, the earn-gold foot line; the
-- portal edge marker and the merchant's world label hidden while the panel is open.
--   --set close=on   taps the panel's X: the panel stays shut at the cart, the edge marker
--                    ("PORTAL · N m") and the merchant label come back
--   --set taps=on    with 100 run gold: a double tap on BUY sends one MerchantBuy, a tap
--                    after the guard time sends the next
--   --set gold=N     run gold (default 27)
local A = lib("arena")
local C = lib("common")
local Config = C.shared("Config")
local ItemData = C.shared("ItemData")
local ED = C.server("EncounterDirector")
local Loot = C.server("LootSystem")
local Items = C.server("ItemSystem")
local MC = C.server("Merchant")
local FLAT = Vector3.new(1, 0, 1)

local fails = 0
local function check(ok: boolean, label: string)
	preview.log((ok and "PASS " or "FAIL ") .. label)
	if not ok then
		fails += 1
		preview.warn("hud-merchant: " .. label)
	end
end

local ctx = {
	RunManager = {
		GetRunPlayers = function() return {} end,
		Broadcast = function() end,
		Notify = function() end,
		IsRunning = function() return true end,
		IsSimulating = function() return true end,
		GetRunTime = function() return 0 end,
	},
	LootSystem = Loot,
	ItemSystem = Items,
}
Loot.Init(ctx)
Items.Init(ctx)
ED.Init(ctx)
MC.Init(ctx)
for k in pairs(Config.Features) do
	if k ~= "Merchant" then
		Config.Features[k] = false
	end
end

local taps = preview.args.taps == "on"
local gold = tonumber(preview.args.gold) or (taps and 100 or 27)
local s = A.build({
	enemies = 40,
	seconds = 400,
	stage = 2,
	portal = true,
	portalState = "Idle",
	portalHint = true,
	portalReveal = 1,
	place = function(s, arena, centre)
		ED.StageStart(arena, 2, s.portal and s.portal.Pos or nil, "Forest")
		local cart = MC.Get()
		if cart then
			return cart.Pos + Vector3.new(3, 0, -5)
		end
		preview.warn("hud-merchant: no merchant placed")
		return centre
	end,
})
C.setPlayer({ RunGold = gold, GoldMult = 2.5 })
local cart = MC.Get()
if cart then
	local list = {}
	for i, o in ipairs(MC.StockOf({ Stats = { Luck = 0 } }) or {}) do
		list[i] = { Id = o.Id, Rarity = o.Rarity, Price = 25, Sold = false }
	end
	C.fire("MerchantStock", { Id = cart.Id, Stage = 2, Items = list })
	if s.portal then
		preview.log(string.format("portal %.0f studs from the hero", ((s.portal.Pos - s.centre) * FLAT).Magnitude))
	end
end
check(ItemData.PlayerPrice(25, 2.5) == 63, "an offer costs 63 with both gold passes (PlayerPrice 25 x 2.5)")
C.settle(6) -- after the stage-start card and the portal reveal banner

local ExploreUI = preview.client("ExploreUI")
local Hud = preview.client("Hud")
local StageUI = preview.client("StageUI")
local panel = ExploreUI.Panel()

local function rectOf(g): { number }?
	if not g then
		return nil
	end
	local ok, l = pcall(preview.layoutOf, g)
	if not ok or not l or l.w <= 0 then
		return nil
	end
	return { l.x, l.y, l.x + l.w, l.y + l.h }
end
local function overlap(a, b): boolean
	return a ~= nil and b ~= nil and a[3] > b[1] + 1 and a[1] < b[3] - 1 and a[4] > b[2] + 1 and a[2] < b[4] - 1
end
local function shown(g): boolean
	if not g then
		return false
	end
	local obj = g
	while obj and obj:IsA("GuiObject") do
		if not obj.Visible then
			return false
		end
		obj = obj.Parent
	end
	return true
end
local function merchantLabel(): BillboardGui?
	local pg = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
	for _, bb in ipairs(pg and pg:GetChildren() or {}) do
		if bb:IsA("BillboardGui") and bb.Name == "ExploreMarker" then
			local title = bb:FindFirstChild("Title", true)
			if title and title.Text == "MERCHANT" then
				return bb
			end
		end
	end
	return nil
end

-- the wave arrives while the shop is open
C.setState({ Wave = 6, WaveNext = 0, WaveSides = "north", WaveAngle = -math.pi / 2, WaveBig = false, WaveLoud = true, WaveSeq = 1 })
C.settle(0.75)

local els = Hud.Elements()
check(panel ~= nil and panel.Visible, "the merchant panel is open at the cart")
local headline = preview.client("UIState").HeadlineShowing()
check(headline ~= nil and headline.Id == "wave.6", "the WAVE 6 banner shows (a threat cuts an informational banner short)")
local timer, stage, banner, shop = rectOf(els.TimerPill), rectOf(els.Stage), rectOf(els.Banner), rectOf(panel)
check(timer ~= nil and stage ~= nil and not overlap(timer, stage), "timer and objective do not overlap")
check(banner ~= nil and not overlap(banner, timer) and not overlap(banner, stage), "the banner sits in its lane under the top stack")
check(shop ~= nil and not overlap(shop, banner) and not overlap(shop, stage) and not overlap(shop, timer), "the merchant panel stays under the banner lane")
check(shop ~= nil and not overlap(shop, rectOf(els.Plate)), "the merchant panel clears the vitals")
check(C.findText("^RUN GOLD " .. gold .. "$") ~= nil, "the panel shows RUN GOLD " .. gold)
check(panel ~= nil and panel:FindFirstChild("Close", true) ~= nil, "the panel has a close button")
if not taps then
	check(C.findText("^NEED 36 MORE$") ~= nil, "an unaffordable offer's button reads NEED 36 MORE")
	check(C.findText("^EARN RUN GOLD FROM KILLS") ~= nil, "nothing affordable: the foot line says how to earn gold")
end
local arrow = StageUI.Elements().Arrow
check(not shown(arrow), "the portal edge marker hides while the shop is open")
local label = merchantLabel()
check(label == nil or not label.Enabled, "the merchant's world label hides while its panel is open")

if preview.args.close == "on" and panel then
	local close = panel:FindFirstChild("Close", true)
	if close then
		preview.click(close)
	end
	C.settle(1)
	check(not panel.Visible, "X closes the panel while the hero stays at the cart")
	check(shown(arrow) and string.find(StageUI.Elements().ArrowDistance.Text, "^PORTAL") ~= nil, "the edge marker returns with PORTAL and the distance")
	local back = merchantLabel()
	check(back ~= nil and back.Enabled, "the merchant's world label returns")
	local a = rectOf(arrow)
	check(not overlap(a, rectOf(els.TimerPill)) and not overlap(a, rectOf(els.Stage)) and not overlap(a, rectOf(els.Bar)), "the edge marker keeps off the top stack and the ability panel")
end

if taps and panel then
	local sent = 0
	preview.remote("MerchantBuy").OnServerEvent:Connect(function()
		sent += 1
	end)
	local offer = panel:FindFirstChild("Offer1", true)
	local btn = offer and offer:FindFirstChild("Buy", true)
	if btn then
		preview.click(btn)
		preview.click(btn)
		C.settle(0.1)
		check(sent == 1, "a double tap on BUY sends one MerchantBuy (" .. sent .. ")")
		C.settle(2.1)
		preview.click(btn)
		C.settle(0.1)
		check(sent == 2, "a tap after the guard time sends the next (" .. sent .. ")")
	else
		check(false, "found the first BUY button")
	end
end

preview.log(fails == 0 and "PASS hud-merchant" or ("FAIL hud-merchant: " .. fails .. " checks failed"))
