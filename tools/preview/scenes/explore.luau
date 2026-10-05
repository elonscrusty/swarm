-- explore: the EXPLORE features in the arena (docs/features/EXPLORE.md), placed by the real
-- server modules (EncounterDirector + SecretRoom / Merchant / Rescue on stage 2), with the
-- client's ExploreUI: the world pills and the merchant's shop panel.
--   --set focus=merchant (default) the hero at the cart: the panel with 3 offers (one sold,
--                        one too expensive with --set gold=N, default 120)
--   --set focus=wall     the hero in front of the cracked wall (shimmer, HP bar at 60%)
--                        --set wall=open  the wall broken open (secret cache inside)
--   --set focus=villager the lost villager following the hero (OPTIONAL tag, HP bar)
local A = lib("arena")
local C = lib("common")
local focus = preview.args.focus or "merchant"
local Config = C.shared("Config")
local ED = C.server("EncounterDirector")
local Loot = C.server("LootSystem")
local Items = C.server("ItemSystem")
local SR = C.server("SecretRoom")
local MC = C.server("Merchant")
local RS = C.server("Rescue")
local FLAT = Vector3.new(1, 0, 1)

local fakeRp = { Stats = { Luck = 0 } }
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
SR.Init(ctx)
MC.Init(ctx)
RS.Init(ctx)
for k in pairs(Config.Features) do
	if k ~= "SecretRooms" and k ~= "Merchant" and k ~= "Rescue" then
		Config.Features[k] = false
	end
end
Config.Encounters.Director.MaxActive = 3

local s = A.build({
	enemies = 30,
	stage = 2,
	portal = true,
	place = function(s, arena, centre)
		ED.StageStart(arena, 2, s.portal and s.portal.Pos or nil, "Forest")
		if focus == "wall" then
			local r = SR.Get()
			if r then
				if preview.args.wall == "open" then
					Config.Explore.SecretRoom.ChallengeChance = 0
					SR.DebugHit(r.HP + 1)
					return r.WallPos - r.Out * 7
				end
				r.Model:SetAttribute("HPFrac", 0.6)
				return r.WallPos - r.Out * 9
			end
		elseif focus == "villager" then
			local v = RS.Get()
			if v then
				v.Model:SetAttribute("State", "Following")
				v.Model:SetAttribute("HPFrac", 0.7)
				return v.Pos + Vector3.new(4, 0, -3)
			end
		else
			local cart = MC.Get()
			if cart then
				return cart.Pos + Vector3.new(3, 0, -5)
			end
		end
		preview.warn("explore: nothing placed for focus " .. focus)
		return centre
	end,
})
C.setPlayer({ RunGold = tonumber(preview.args.gold) or 120, GoldMult = 1 })
local cart = MC.Get()
if cart then
	local stock = MC.StockOf(fakeRp) or {}
	local items = {}
	for i, o in ipairs(stock) do
		items[i] = { Id = o.Id, Rarity = o.Rarity, Price = o.Price, Sold = i == 1 }
	end
	C.fire("MerchantStock", { Id = cart.Id, Stage = 2, Items = items })
	preview.log(string.format("merchant at %.0f studs from the hero, offers: %s", ((cart.Pos - s.centre) * FLAT).Magnitude, #items))
end
C.settle(tonumber(preview.args.at) or 6) -- after the stage-start card
local panel = C.findText("^MERCHANT$")
preview.log("merchant panel title shown: " .. tostring(panel ~= nil))

-- --set pad=on: a gamepad player at the cart: D-pad right moves the gold rim to the next
-- offer ("X  BUY"), X sends MerchantBuy for that slot (PASS / FAIL lines)
if preview.args.pad == "on" and panel then
	local UIS = game:GetService("UserInputService")
	preview.setLastInput(Enum.UserInputType.Gamepad1)
	local sent: { number } = {}
	preview.remote("MerchantBuy").OnServerEvent:Connect(function(_p, _id, slot)
		table.insert(sent, slot)
	end)
	local function pad(key)
		UIS.InputBegan:_fire({ UserInputType = Enum.UserInputType.Gamepad1, UserInputState = Enum.UserInputState.Begin, KeyCode = key, Position = Vector3.zero, Delta = Vector3.zero }, false)
		C.settle(0.3)
	end
	C.settle(0.3)
	local first = C.findText("^X  BUY$")
	preview.log((first and "PASS" or "FAIL") .. " pad: one offer shows X  BUY")
	pad(Enum.KeyCode.DPadRight)
	local after = C.findText("^X  BUY$")
	preview.log(((after and after ~= first) and "PASS" or "FAIL") .. " pad: D-pad right moves the pick")
	pad(Enum.KeyCode.ButtonX)
	preview.log((#sent >= 1 and "PASS" or "FAIL") .. " pad: X sends MerchantBuy (slot " .. tostring(sent[1]) .. ")")
end
