-- explore-regression: the EXPLORE features (docs/features/EXPLORE.md) on the REAL server
-- (GameServer, all modules), a solo run, printing PASS / FAIL lines:
--   secret room  placed at an arena edge inside the fence, walls are colliders, weapons
--                fired next to it chip it (WeaponSystem.OnFired), it opens exactly once,
--                the front collider is gone, Treasure = one "Secret Cache" chest, Challenge
--                = an elite pack (both branches forced), removed on travel
--   merchant     3 different offers per player, price = the chest of the item's rarity
--                (ItemData.StagePrice / PlayerPrice), buy grants once and takes exactly that
--                gold, sold / far / no-gold / bad slot are refused with nothing granted,
--                stock is per player
--   rescue       waits, follows the nearest hero once found, saved in the portal ring
--                (item for the hero, exactly once); next stage it is hurt by enemies and lost
--   flags off    no EXPLORE model on the next stage
-- run: render.sh explore-regression --studio --devices pc --max-time 400 --set headless=on
local C = lib("common")
local Players = game:GetService("Players")
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local ES = preview.server("EnemySpawner")
local EAI = preview.server("EnemyAI")
local Loot = preview.server("LootSystem")
local Gold = preview.server("GoldSystem")
local SR = preview.server("SecretRoom")
local MC = preview.server("Merchant")
local RS = preview.server("Rescue")
local MapBuilder = preview.server("MapBuilder")
local Config = C.shared("Config")
local ItemData = C.shared("ItemData")
local advance = preview.advance
local FLAT = Vector3.new(1, 0, 1)

local fails = 0
local function check(ok: any, label: string)
	if ok then
		preview.log("PASS " .. label)
	else
		fails += 1
		preview.log("FAIL " .. label)
	end
end

-- only the EXPLORE encounters, all three every stage
local mine = { SecretRooms = true, Merchant = true, Rescue = true }
for name in pairs(Config.Features) do
	if not mine[name] and (name == "MiniBosses" or name == "TrialShrine" or name == "CursedChests" or name == "MapEvents" or name == "Weather") then
		Config.Features[name] = false
	end
end
Config.Encounters.Director.MaxActive = 3
Config.Explore.SecretRoom.ChallengeChance = 0 -- stage 1: treasure

local function levelUps()
	for _ = 1, 30 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
		advance(0.3)
	end
end
local function closeRewards(rp)
	if rp.RewardSeq then
		preview.remote("RewardClose"):FireServer(rp.RewardSeq)
	end
end
local function itemCount(rp): number
	local n = 0
	for _, c in pairs(rp.Items or {}) do
		n += c
	end
	return n
end

preview.remote("StartRun"):FireServer("Solo")
advance(2)
levelUps()
local rp = RM.GetRunPlayer(me)
if not rp then
	preview.log("FAIL no run player")
	return
end
rp.InvulnUntil = math.huge

local function standAt(pos: Vector3)
	local root = rp.Root
	if root then
		root.CFrame = CFrame.new(Vector3.new(pos.X, Config.ArenaOrigin.Y + 3, pos.Z))
		rp.LastValidPos = root.Position
		rp.SpeedCheckTimer = 0
	end
end

local function nextStage(label: string)
	SM.DevNextStage()
	for _ = 1, 60 do
		advance(0.5)
		levelUps()
		closeRewards(rp)
		if SM.GetPhase() == "Explore" then
			break
		end
	end
	rp.InvulnUntil = math.huge
	preview.log(string.format("%s: stage=%d phase=%s", label, SM.GetStage(), SM.GetPhase()))
end

------------------------------------------------------------------------------------------
-- secret room
------------------------------------------------------------------------------------------
local function secretRoom(stageLabel: string, expect: string)
	local r = SR.Get()
	check(r ~= nil, stageLabel .. " secret room placed")
	if not r then
		return
	end
	local arena = MapBuilder.GetArena()
	local c = Config.ArenaOrigin
	local gap = arena.Half - math.max(math.abs(r.Pos.X - c.X), math.abs(r.Pos.Z - c.Z))
	local K = Config.Explore.SecretRoom
	check(gap >= K.EdgeMargin - 0.01 and gap <= K.EdgeMargin + K.EdgeBand + 0.01, string.format("%s alcove at an edge inside the fence (gap %.1f)", stageLabel, gap))
	check(r.Model.Parent and r.Model.Parent.Name == "SwarmEvents" and r.Model:GetAttribute("State") == "Sealed", stageLabel .. " model Sealed in SwarmEvents")
	check(EAI.IsBlocked(r.WallPos.X, r.WallPos.Z, 0.5), stageLabel .. " cracked wall blocks (collider)")
	local back = r.Pos + r.Out * (K.Depth / 2 + K.Wall / 2)
	check(EAI.IsBlocked(back.X, back.Z, 0.5), stageLabel .. " back wall blocks")
	-- while sealed the inside counts as blocked, so no enemy spawns or is pushed in there
	-- (it could never get out: corner-regression pocket next to an alcove)
	check(EAI.IsBlocked(r.Pos.X, r.Pos.Z, 0.5), stageLabel .. " sealed alcove inside is closed to enemies")
	-- stand in front of the wall and let the weapons fire
	standAt(r.WallPos - r.Out * 6)
	local hp0 = r.HP
	for _ = 1, 20 do
		advance(0.5)
		levelUps()
		closeRewards(rp)
		standAt(r.WallPos - r.Out * 6)
		if r.State ~= "Sealed" then
			break
		end
	end
	check(r.HP < hp0, string.format("%s weapon attacks chip the wall (%d -> %d of %d)", stageLabel, hp0, math.max(0, math.floor(r.HP)), r.MaxHP))
	if r.State == "Sealed" then
		SR.DebugHit(r.HP + 1)
	end
	check(r.State == "Open" and r.Model:GetAttribute("State") == "Open", stageLabel .. " wall opens")
	check(not EAI.IsBlocked(r.WallPos.X, r.WallPos.Z, 0.5), stageLabel .. " front collider removed")
	check(not EAI.IsBlocked(r.Pos.X, r.Pos.Z, 0.5), stageLabel .. " open alcove inside is free")
	check(EAI.IsBlocked(back.X, back.Z, 0.5), stageLabel .. " back wall still blocks")
	check(r.Reward == expect, stageLabel .. " reward " .. tostring(r.Reward) .. " (want " .. expect .. ")")
	local caches, elites = 0, 0
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Model:GetAttribute("Title") == "Secret Cache" then
			caches += 1
		end
	end
	for _, e in ipairs(ES.Active) do
		if e.Elite and ((e.Pos - r.Pos) * FLAT).Magnitude < 12 then
			elites += 1
		end
	end
	if expect == "Treasure" then
		check(caches == 1, stageLabel .. " one Secret Cache chest (" .. caches .. ")")
	else
		check(elites >= K.PackBase, stageLabel .. " elite pack climbed out (" .. elites .. ")")
	end
	-- exactly once
	SR.DebugHit(9999)
	local caches2 = 0
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Model:GetAttribute("Title") == "Secret Cache" then
			caches2 += 1
		end
	end
	check(caches2 == caches and r.State == "Open", stageLabel .. " a second break does nothing")
	-- the hero can stand inside the alcove (not pushed out, on the floor height)
	standAt(r.Pos)
	advance(0.5)
	local root = rp.Root
	check(root and root.Position.Y > Config.ArenaOrigin.Y + 1 and ((root.Position - r.Pos) * FLAT).Magnitude < 3, stageLabel .. " hero stands in the alcove")
	if expect == "Treasure" then
		for _, obj in ipairs(Loot.Objects()) do
			if obj.Model:GetAttribute("Title") == "Secret Cache" then
				local items = itemCount(rp)
				standAt(obj.Pos + Vector3.new(0, 0, 0.5))
				preview.remote("LootHold"):FireServer(obj.Id, true)
				advance(1)
				closeRewards(rp)
				check(itemCount(rp) == items + 1 and obj.State == "Opened", stageLabel .. " cache gives one item")
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- merchant
------------------------------------------------------------------------------------------
local function merchant(stageLabel: string)
	local cart = MC.Get()
	check(cart ~= nil, stageLabel .. " merchant placed")
	if not cart then
		return
	end
	standAt(cart.Pos + Vector3.new(4, 0, 0))
	advance(0.3)
	local stock = MC.StockOf(rp)
	check(stock and #stock == Config.Explore.Merchant.Slots, stageLabel .. " 3 offers")
	local seen, okPrice = {}, true
	for _, o in ipairs(stock or {}) do
		check(not seen[o.Id], stageLabel .. " offer " .. o.Id .. " is unique")
		seen[o.Id] = true
		local chest = Config.Explore.Merchant.PriceChest[o.Rarity]
		local want = ItemData.StagePrice(Config.Chests.Cost[chest], SM.GetStage(), Config.Chests.CostExponent)
		okPrice = okPrice and o.Price == want and o.Rarity == ItemData.Items[o.Id].Rarity
	end
	check(okPrice, stageLabel .. " prices = chest of the same rarity on this stage")
	local other = { Stats = { Luck = 0 } }
	check(MC.StockOf(other) ~= stock, stageLabel .. " another player gets their own stock")
	-- no gold
	local wallet = Gold.RunWallet(rp)
	if wallet > 0 then
		Gold.SpendRunGold(rp, wallet)
	end
	local items = itemCount(rp)
	local ok, why = MC.Buy(rp, cart.Id, 1)
	check(not ok and why == "gold" and itemCount(rp) == items and not stock[1].Sold, stageLabel .. " no gold: refused, nothing granted")
	Gold.AddRunGold(rp, 100000)
	advance(0.1)
	local before = Gold.RunWallet(rp)
	local price = ItemData.PlayerPrice(stock[1].Price, Gold.PriceMult(me))
	ok, why = MC.Buy(rp, cart.Id, 1)
	closeRewards(rp)
	check(ok and itemCount(rp) == items + 1 and Gold.RunWallet(rp) == before - price, string.format("%s buy: +1 item, -%d gold (shown price)", stageLabel, price))
	check(stock[1].Sold, stageLabel .. " slot marked sold")
	ok, why = MC.Buy(rp, cart.Id, 1)
	check(not ok and why == "sold" and itemCount(rp) == items + 1, stageLabel .. " second buy of the same slot refused")
	-- REVIEW R-01: a reconnect makes a new record (a copy); it keeps the same stock, so a
	-- rejoin never rerolls the cart or reopens sold slots
	local copy = table.clone(rp)
	check(MC.StockOf(copy) == stock, stageLabel .. " reconnected record keeps its stock")
	ok, why = MC.Buy(copy, cart.Id, 1)
	check(not ok and why == "sold", stageLabel .. " reconnected record can't rebuy a sold slot")
	ok, why = MC.Buy(rp, cart.Id, 9)
	check(not ok and why == "bad", stageLabel .. " bad slot refused")
	ok, why = MC.Buy(rp, cart.Id + 99, 2)
	check(not ok and why == "gone", stageLabel .. " stale merchant id refused")
	standAt(cart.Pos + Vector3.new(40, 0, 0))
	advance(0.2)
	ok, why = MC.Buy(rp, cart.Id, 2)
	check(not ok and why == "far" and not stock[2].Sold, stageLabel .. " buying from afar refused")
	-- through the remote (rate-limited listener) while near
	standAt(cart.Pos + Vector3.new(4, 0, 0))
	advance(0.2)
	local n = itemCount(rp)
	preview.remote("MerchantBuy"):FireServer(cart.Id, 2)
	advance(0.3)
	closeRewards(rp)
	check(stock[2].Sold and itemCount(rp) == n + 1, stageLabel .. " MerchantBuy remote buys slot 2")
	preview.remote("MerchantBuy"):FireServer("x", {})
	advance(0.1)
	check(not stock[3].Sold, stageLabel .. " junk remote arguments ignored")
end

------------------------------------------------------------------------------------------
-- rescue
------------------------------------------------------------------------------------------
local function rescueSaved(stageLabel: string)
	local v = RS.Get()
	check(v ~= nil, stageLabel .. " villager placed")
	if not v then
		return
	end
	check(v.Model:GetAttribute("Optional") == true and v.State == "Waiting", stageLabel .. " villager waits, Optional")
	standAt(v.Pos + Vector3.new(3, 0, 0))
	advance(0.5)
	check(v.State == "Following", stageLabel .. " found: follows")
	local portal = SM.PortalPosition()
	if not portal then
		check(false, stageLabel .. " portal position")
		return
	end
	local items = itemCount(rp)
	-- walk the hero to the portal in steps; the villager walks after
	for _ = 1, 120 do
		local here = rp.Root.Position
		local to = (portal - here) * FLAT
		local stepLen = math.min(8, to.Magnitude)
		if stepLen > 0.1 then
			standAt(here + to.Unit * stepLen)
		end
		advance(0.5)
		levelUps()
		closeRewards(rp)
		if v.State ~= "Following" then
			break
		end
	end
	closeRewards(rp)
	check(v.State == "Saved", stageLabel .. " villager saved in the portal ring (" .. v.State .. ")")
	check(itemCount(rp) == items + 1, stageLabel .. " saved: one item")
	advance(1)
	check(itemCount(rp) == items + 1, stageLabel .. " reward granted exactly once")
end

local function rescueLost(stageLabel: string)
	local v = RS.Get()
	check(v ~= nil, stageLabel .. " villager placed")
	if not v then
		return
	end
	standAt(v.Pos + Vector3.new(3, 0, 0))
	advance(0.5)
	check(v.State == "Following", stageLabel .. " found: follows")
	local hp = v.HP
	for _ = 1, 40 do
		if v.State ~= "Following" then
			break
		end
		local e = ES.Spawn("Slime", Vector3.new(v.Pos.X + 0.5, Config.ArenaOrigin.Y, v.Pos.Z), { Force = true })
		if e then
			e.SpawnGrace = 0
		end
		advance(0.3)
		levelUps()
		closeRewards(rp)
	end
	check(v.HP < hp, stageLabel .. " enemies hurt the villager")
	check(v.State == "Lost" and v.Model:GetAttribute("State") == "Lost", stageLabel .. " villager lost at 0 HP")
end

------------------------------------------------------------------------------------------
-- run
------------------------------------------------------------------------------------------
secretRoom("stage 1", "Treasure")
merchant("stage 1")
rescueSaved("stage 1")
local oldModels = {}
for _, m in ipairs(workspace.SwarmEvents:GetChildren()) do
	table.insert(oldModels, m)
end
Config.Explore.SecretRoom.ChallengeChance = 1
nextStage("stage 2")
local gone = true
for _, m in ipairs(oldModels) do
	if m.Parent and (m.Name == "SecretRoom" or m.Name == "Merchant" or m.Name == "Rescue") then
		gone = false
	end
end
check(gone, "stage 2: last stage's EXPLORE models removed on travel")
secretRoom("stage 2", "Challenge")
rescueLost("stage 2")
for k in pairs(mine) do
	Config.Features[k] = false
end
nextStage("stage 3 (flags off)")
local any = false
for _, m in ipairs(workspace.SwarmEvents:GetChildren()) do
	if m.Name == "SecretRoom" or m.Name == "Merchant" or m.Name == "Rescue" then
		any = true
	end
end
check(not any and SR.Get() == nil and MC.Get() == nil and RS.Get() == nil, "flags off: no EXPLORE encounter")
preview.remote("AbandonRun"):FireServer()
advance(2)
check(SR.Get() == nil and MC.Get() == nil and RS.Get() == nil, "run end: everything cleaned up")
preview.log(fails == 0 and "PASS explore-regression: secret room, merchant, rescue" or ("FAIL explore-regression: " .. fails .. " checks failed"))
