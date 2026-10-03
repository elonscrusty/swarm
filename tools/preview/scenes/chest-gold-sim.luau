-- chest-gold-sim: regression for the false "Not enough gold." at a chest.
-- Boots the REAL server, starts a solo run, then makes the gamepass gold multiplier change
-- mid-run (a pass lookup that finishes late on a fresh server, or a pass bought during the
-- run). The client prices chests with the GoldMult attribute the server published, so the
-- server must charge that same price: a player holding exactly the shown price opens the
-- chest, never sees "Not enough gold.", and one gold short is still refused.
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local Loot = preview.server("LootSystem")
local Gold = preview.server("GoldSystem")
local Monetization = preview.server("MonetizationService")
local ItemData = C.shared("ItemData")
local Config = C.shared("Config")
local advance = preview.advance

local feedback = {}
preview.remote("LootFeedback").OnClientEvent:Connect(function(msg)
	table.insert(feedback, msg)
end)

-- no pass yet (the lookup has not answered when the run starts)
local passOn = false
local realOwnsPass = Monetization.OwnsPass
Monetization.OwnsPass = function(player, key)
	if key == "DoubleGold" then
		return passOn
	end
	return false
end

assert(RM.StartTeamRun({ me }, "Solo", "Forest", me), "run starts")
advance(2)
for _ = 1, 20 do
	if not me:GetAttribute("Paused") then break end
	preview.remote("LevelUpChoose"):FireServer(1)
	advance(0.3)
end
local rp = assert(RM.GetRunPlayer(me), "run player")
rp.InvulnUntil = math.huge

local function readyChest()
	for _, obj in pairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.State == "Ready" and (obj.Price or 0) > 0 then
			return obj
		end
	end
	return nil
end

local function standAt(obj)
	local root = rp.Root
	if root then
		root.CFrame = CFrame.new(obj.Pos + Vector3.new(2, 3, 0))
		rp.LastValidPos = root.Position
		rp.SpeedCheckTimer = 0
	end
end

-- what the client shows (LootUI.priceOf / canAfford)
local function shownPrice(obj): number
	return ItemData.PlayerPrice(tonumber(obj.Model:GetAttribute("Price")) or 0, tonumber(me:GetAttribute("GoldMult")) or 1)
end

local function setRunGold(n: number)
	local data = preview.server("DataService").GetData(me)
	data.RunEscrow.Gold = n
	rp.Gold = n
	me:SetAttribute("RunGold", n)
end

local function tryOpen(obj): (boolean, string?)
	table.clear(feedback)
	standAt(obj)
	advance(0.1)
	preview.remote("LootHold"):FireServer(obj.Id, true)
	advance((Config.Chests.HoldSeconds[obj.Type] or 0.4) + 0.2)
	preview.remote("LootHold"):FireServer(obj.Id, false)
	advance(0.2)
	local reason
	for _, f in ipairs(feedback) do
		if f.State == "Cancel" then reason = f.Reason end
	end
	return obj.State == "Opened", reason
end

local failures = 0
local function check(ok, label)
	preview.log((ok and "PASS " or "FAIL ") .. label)
	if not ok then failures += 1 end
end

-- 1) the pass lookup answers mid-run: the server's live multiplier is now x2
passOn = true
local chest = assert(readyChest(), "a priced chest on stage 1")
local shown = shownPrice(chest)
setRunGold(shown) -- the HUD shows exactly the price on the chest
check(Gold.RunWallet(rp) >= shown, string.format("HUD gold %d covers the shown price %d", rp.Gold, shown))
local opened, reason = tryOpen(chest)
check(opened and reason == nil, string.format("chest opens with the shown price (opened=%s reason=%s gold left=%d)", tostring(opened), tostring(reason), rp.Gold))
advance(6)
for _ = 1, 20 do
	if not me:GetAttribute("Paused") then break end
	preview.remote("LevelUpChoose"):FireServer(1)
	advance(0.3)
end

-- 2) the next gold earned publishes the new multiplier; prices and display move together
Gold.AddRunGold(rp, 1)
check(me:GetAttribute("GoldMult") == Monetization.GoldMultiplier(me), "GoldMult attribute follows the live multiplier after the next earn")
local chest2 = readyChest()
if chest2 then
	local shown2 = shownPrice(chest2)
	check(shown2 == ItemData.PlayerPrice(chest2.Price, Monetization.GoldMultiplier(me)), "shown price now uses the new multiplier")
	setRunGold(shown2 - 1)
	local opened2, reason2 = tryOpen(chest2)
	check(not opened2 and reason2 == "gold", "one gold short is still refused (" .. tostring(reason2) .. ")")
	setRunGold(shown2)
	advance(1)
	local opened3, reason3 = tryOpen(chest2)
	check(opened3 and reason3 == nil, "exact shown price opens it (" .. tostring(reason3) .. ")")
else
	preview.log("SKIP second chest (none left on the stage)")
end

-- 3) a pass lookup / purchase refreshes the attributes: the shown price moves at once
passOn = false
Monetization.RefreshAttributes(me)
check(me:GetAttribute("GoldMult") == 1 and Gold.PriceMult(me) == 1, "RefreshAttributes publishes the new multiplier during the run")
passOn = true
Monetization.RefreshAttributes(me)
check(me:GetAttribute("GoldMult") == Monetization.GoldMultiplier(me), "and again when the pass turns on")

Monetization.OwnsPass = realOwnsPass
preview.log(failures == 0 and "PASS chest-gold-sim" or ("FAIL chest-gold-sim: " .. failures .. " check(s)"))
