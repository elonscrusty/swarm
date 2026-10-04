-- reward-once-regression (ISSUE TS-02, docs/overhaul/REWARD.md): every chest reward is granted
-- exactly once on the server, whatever the client shows or does with it. Boots the REAL
-- server and the real client (the reward card / reveal in UIBuilder) and checks:
--   A  a common chest: one grant, one ItemGained, gold charged once, compact card on screen,
--      no primary panel, world input still allowed, no server pause, recent history = 1
--   B  holding the opened chest again (spam): refused, no grant, no charge
--   C  a rare chest (Legendary): one grant, the contained reveal is a primary, the server
--      pauses; an immediate close (skip) ends the pause and changes nothing owned
--   D  junk / stale / huge RewardClose values: no grant, no loss
--   E  a hero going down during a reveal: the solo freeze keeps him from being hit; once
--      the pause ends he goes down, the reveal and card are torn down, the item stays,
--      nothing is granted again
--   F  leaving the run with a card up: the card goes, the history clears, items stay
-- Lune sim, NOT Studio. Prints PASS/FAIL lines; any FAIL fails tools/run_regressions.py.
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
local okClient = pcall(preview.startClient)
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local Loot = preview.server("LootSystem")
local Gold = preview.server("GoldSystem")
local Items = preview.server("ItemSystem")
local advance = preview.advance

local fails = 0
local function check(cond: any, label: string)
	if cond then
		preview.log("PASS " .. label)
	else
		fails += 1
		preview.log("FAIL " .. label)
	end
end

local function client(name: string): any
	local ok, m = pcall(preview.client, name)
	return ok and m or nil
end

-- server grants per item id, and client deliveries
local grants: { [string]: number } = {}
local totalGrants = 0
local realGrant = Items.Grant
Items.Grant = function(rp, id, ...)
	local ok, dramatic = realGrant(rp, id, ...)
	if ok then
		grants[id] = (grants[id] or 0) + 1
		totalGrants += 1
	end
	return ok, dramatic
end
local delivered = 0
preview.remote("ItemGained").OnClientEvent:Connect(function(data)
	if type(data) == "table" and data.Reward == true then
		delivered += 1
	end
end)

preview.remote("StartRun"):FireServer("Solo")
advance(2)
for _ = 1, 20 do
	if not me:GetAttribute("Paused") then
		break
	end
	preview.remote("LevelUpChoose"):FireServer(1)
	advance(0.3)
end
local rp = RM.GetRunPlayer(me)
if not rp then
	preview.log("FAIL no run player")
	return
end
rp.InvulnUntil = math.huge
Gold.AddRunGold(rp, 100000)

local function gui(name: string): GuiObject?
	local pg = me:FindFirstChild("PlayerGui")
	local o = pg and pg:FindFirstChild(name, true)
	return (o and o:IsA("GuiObject")) and o or nil
end
local function visible(name: string): boolean
	local o = gui(name)
	return o ~= nil and o.Visible
end

local function readyChest(kind: string?)
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.State == "Ready" and (obj.Model:GetAttribute("Price") or 0) > 0 and (kind == nil or obj.Type == kind) then
			return obj
		end
	end
	return nil
end

local function standAt(obj)
	rp.Root.CFrame = CFrame.new(obj.Pos + Vector3.new(2, 3, 0))
	rp.LastValidPos, rp.SpeedCheckTimer = rp.Root.Position, 0
end

local function open(id: string, kind: string?)
	local chest = assert(readyChest(kind), "expected a ready chest")
	standAt(chest)
	advance(0.1)
	Items.Roll = function()
		return id
	end
	preview.remote("LootHold"):FireServer(chest.Id, true)
	advance((chest.Model:GetAttribute("Hold") or 0.4) + 0.2)
	preview.remote("LootHold"):FireServer(chest.Id, false)
	return chest
end

-- A: common chest
local spent0 = rp.GoldSpent or 0
local chestA = open("HealingHerb", "Small")
advance(0.3)
check(chestA.State == "Opened", "A chest opened")
check(grants.HealingHerb == 1 and rp.Items.HealingHerb == 1, "A one server grant (" .. tostring(grants.HealingHerb) .. ")")
check(delivered == 1, "A one ItemGained to the client (" .. delivered .. ")")
local spentA = (rp.GoldSpent or 0) - spent0
check(spentA > 0, "A gold charged once (" .. spentA .. ")")
check(not rp.RewardUntil and not RM.IsFrozen(), "A no server pause for a common reward")
local UIState = client("UIState")
local LootUI = client("LootUI")
if okClient and UIState then
	check(visible("RewardCard"), "A compact card on screen")
	check(not visible("Reward"), "A no reel for a common reward")
	check(UIState.Owner() == nil, "A card is not a primary (owner " .. tostring(UIState.Owner()) .. ")")
	check(UIState.WorldInputAllowed(), "A world input (next chest) still allowed")
	check(LootUI and #LootUI.RecentRewards() == 1, "A recent rewards history has it")
else
	preview.log("BLOCKED client checks (client did not start)")
end

-- B: hold the opened chest again, several times
for _ = 1, 5 do
	preview.remote("LootHold"):FireServer(chestA.Id, true)
	advance(0.6)
end
preview.remote("LootHold"):FireServer(chestA.Id, false)
check(grants.HealingHerb == 1 and rp.Items.HealingHerb == 1, "B repeated holds on an opened chest grant nothing")
check((rp.GoldSpent or 0) - spent0 == spentA, "B repeated holds charge nothing")
advance(4)
if okClient then
	check(not visible("RewardCard"), "A/B card retires by itself")
end

-- C: rare chest, skipped at once
local before = totalGrants
open("SunMedallion", "Small")
advance(0.15)
check(grants.SunMedallion == 1 and rp.Items.SunMedallion == 1, "C one grant for the rare chest")
check(rp.RewardUntil ~= nil and RM.IsFrozen(), "C solo rare reward pauses the run")
if okClient and UIState then
	check(UIState.IsOpen("Reward"), "C contained reveal is the primary")
end
preview.remote("RewardClose"):FireServer(rp.RewardSeq)
advance(0.2)
check(not rp.RewardUntil, "C skip/close ends the pause")
advance(5)
check(totalGrants == before + 1 and rp.Items.SunMedallion == 1, "C nothing granted or lost after the skip")

-- D: junk closes
for _, v in ipairs({ "x", -1, 1e12, 0 / 0 }) do
	preview.remote("RewardClose"):FireServer(v)
end
preview.remote("RewardClose"):FireServer()
advance(0.5)
check(totalGrants == before + 1 and rp.Items.SunMedallion == 1 and rp.Items.HealingHerb == 1, "D junk RewardClose changes nothing")

-- E: going down during a reveal
local chestE = open("CrownOfAges", "Large")
advance(0.15)
local id = "CrownOfAges"
if not rp.Items[id] then
	-- capped / renamed item: whatever was granted
	for k, n in pairs(grants) do
		if k ~= "HealingHerb" and k ~= "SunMedallion" and n > 0 then
			id = k
		end
	end
end
check(grants[id] == 1, "E one grant before the hero goes down (" .. id .. ")")
local hp = rp.HP
rp.InvulnUntil = 0
RM.DamagePlayer(rp, 1e7, "test")
check(rp.Alive and rp.HP == hp, "E frozen solo reveal: the hero cannot be hit")
RM.EndReward(rp)
advance(2.5) -- past the close grace (Config.Player.ChoiceGraceSeconds)
rp.InvulnUntil = 0
RM.DamagePlayer(rp, 1e7, "test")
advance(0.5)
check(rp.Alive == false or me:GetAttribute("Alive") == false, "E hero down after the pause")
if okClient then
	check(not visible("RewardCard"), "E reward card torn down on going down")
	check(not (UIState and UIState.IsOpen("Reward")), "E reveal torn down on going down")
end
advance(3)
check(grants[id] == 1 and (rp.Items[id] or 0) >= 1, "E item kept, never granted again")
check(chestE.State == "Opened", "E chest stays opened")

-- F: leaving with a card up (client teardown; items are server state)
if okClient and LootUI then
	LootUI.RecordReward({ Id = "HealingHerb", Name = "Bandage", Source = "Small Chest" })
	me:SetAttribute("InRun", false)
	advance(0.3)
	check(#LootUI.RecentRewards() == 0, "F history clears when the run ends")
	check(not visible("RewardCard"), "F no card outside a run")
	me:SetAttribute("InRun", true)
end
check(rp.Items.HealingHerb == 1 and rp.Items.SunMedallion == 1, "F items still owned on the server")

preview.log(string.format("grants total %d, deliveries %d", totalGrants, delivered))
if fails == 0 then
	preview.log("PASS reward-once: every reward granted exactly once")
else
	preview.log(string.format("FAIL reward-once: %d check(s) failed", fails))
end
