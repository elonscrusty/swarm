-- chest-purchase-regression (studio review SW-04 / SW-05, stream R5): the team chest purchase on the
-- REAL server (LootSystem hold -> GoldSystem.BuyChest -> one reward per recipient) in a Duo run:
--   1  balance below / equal / above the price: refused with nothing taken, or one debit of the
--      shown price; Done carries Paid and Next (the next chest's price), TeamChestsBought counts
--   2  rapid holds (repeated LootHold true) pay once and reward once
--   3  two players finishing the same chest: one debit, one Done, the other Cancel "used",
--      exactly one reward per recipient
--   4  gold gained during the approach: refused while short, opens once the gold arrived
--   5  multiple chests: after one purchase every team chest shows the next price; the next one is
--      refused when the balance no longer covers it (no wrong debit)
--   6  delayed update: a teammate's purchase raises the price mid-hold; the hold is refused at the
--      end with nothing taken and the chest stays Ready (recoverable)
--   7  no "Done" ever follows a refusal for the same hold
-- Lune sim, NOT Studio: prints PASS / FAIL lines.
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local RM = preview.server("RunManager")
local Gold = preview.server("GoldSystem")
local Loot = preview.server("LootSystem")
local LU = preview.server("LevelUpSystem")
local ES = preview.server("EnemySpawner")
local Items = preview.server("ItemSystem")
local Remotes = preview.shared("Remotes")
local Config = preview.shared("Config")
local state = Remotes.State()

local fails = 0
local function check(label: string, ok: any, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

assert(RM.StartTeamRun({ me, ava }, "Duo", "Forest", me), "duo run starts")
preview.advance(2)
local rM, rA = assert(RM.GetRunPlayer(me)), assert(RM.GetRunPlayer(ava))
for _, rp in ipairs({ rM, rA }) do
	rp.InvulnUntil = math.huge
end
ES.SetHold("chest-purchase", true)
ES.DespawnAll()

-- rewards: count every chest choice / item per recipient (the choice itself is not opened, so the
-- world never freezes in this scene)
local rewards: { [any]: number } = {}
LU.QueueChoice = function(rp, source)
	if source == "Chest" then
		rewards[rp] = (rewards[rp] or 0) + 1
	end
end
local realGrant = Items.Grant
Items.Grant = function(rp, id, ...)
	local ok, d = realGrant(rp, id, ...)
	if ok then
		rewards[rp] = (rewards[rp] or 0) + 1
	end
	return ok, d
end
local function rewardTotal(): number
	local n = 0
	for _, v in pairs(rewards) do
		n += v
	end
	return n
end
local function clearOffers()
	for _, rp in ipairs(RM.GetRunPlayers()) do
		if rp.Offer or rp.Paused or (rp.PendingLevels or 0) > 0 then
			LU.Cancel(rp)
		end
		rp.Paused, rp.RewardUntil = false, nil
	end
end

-- feedback per player (mine through the client remote, Ava's through the server fire log)
local mine = {}
preview.remote("LootFeedback").OnClientEvent:Connect(function(msg)
	table.insert(mine, msg)
end)

local arena = preview.server("MapBuilder").GetArena()
local C0 = (arena and arena.Center) or Config.ArenaOrigin
local groundY = C0.Y
local spot = 0
local function newChest()
	spot += 1
	local pos = Vector3.new(C0.X + 40 + spot * 14, groundY, C0.Z + 40)
	local obj = Loot.AddFeatureChest(arena, "Small", pos, false)
	return obj
end
local function place(rp, at: Vector3)
	rp.Root.CFrame = CFrame.new(Vector3.new(at.X, groundY + 3, at.Z))
	rp.Root.AssemblyLinearVelocity = Vector3.zero
	rp.LastValidPos = rp.Root.Position
	rp.SpeedCheckTimer = 0
end
local function holdOn(p, obj, on)
	if p == me then
		preview.remote("LootHold"):FireServer(obj.Id, on)
	else
		preview.fireServerAs(p, "LootHold", obj.Id, on)
	end
end
local function holdTime(obj): number
	return (obj.Model:GetAttribute("Hold") or 1) + 0.4
end
local function hold(holders, obj, extra)
	clearOffers()
	for _, p in ipairs(holders) do
		place(RM.GetRunPlayer(p), obj.Pos + Vector3.new(1.5, 0, 0))
	end
	preview.advance(0.1)
	for _, p in ipairs(holders) do
		holdOn(p, obj, true)
	end
	if extra then
		extra()
	end
	preview.advance(holdTime(obj))
	for _, p in ipairs(holders) do
		holdOn(p, obj, false)
	end
	preview.advance(0.2)
end
local function answersFor(id): { any }
	local out = {}
	for _, m in ipairs(mine) do
		if m.Id == id then
			table.insert(out, m)
		end
	end
	return out
end
local function last(list)
	return list[#list] or {}
end

check("setup team chests are bought with team gold", (function()
	local c = newChest()
	local ok = c.TeamChest == true and c.Model:GetAttribute("TeamGold") == true and c.Model:GetAttribute("Price") == Gold.ChestCost()
	return ok
end)())

------------------------------------------------------------------------------------------
-- 1 below / equal / above
------------------------------------------------------------------------------------------
do
	local c = newChest()
	local cost = Gold.ChestCost()
	Gold.SetTeamGold(cost - 1)
	local r0 = rewardTotal()
	hold({ me }, c)
	local a = answersFor(c.Id)
	check("1 below: refused with 'gold', nothing taken, chest still Ready", c.State == "Ready" and Gold.TeamGold() == cost - 1 and rewardTotal() == r0 and last(a).State == "Cancel" and last(a).Reason == "gold",
		string.format("gold %d, state %s, answer %s/%s", Gold.TeamGold(), c.State, tostring(last(a).State), tostring(last(a).Reason)))
	check("7 no Done after the refusal", (function()
		for _, m in ipairs(a) do
			if m.State == "Done" then
				return false
			end
		end
		return true
	end)())

	local bought0 = Gold.ChestsBought()
	Gold.SetTeamGold(cost)
	hold({ me }, c)
	a = answersFor(c.Id)
	local d = last(a)
	check("1 equal: opened, exactly the price taken (balance 0)", c.State == "Opened" and Gold.TeamGold() == 0 and Gold.ChestsBought() == bought0 + 1, string.format("gold %d", Gold.TeamGold()))
	check("1 Done carries Paid = the price and Next = the raised price", d.State == "Done" and d.Paid == cost and d.Team == true and d.Next == Gold.ChestCost() and d.Next > cost,
		string.format("Paid %s Next %s", tostring(d.Paid), tostring(d.Next)))
	check("1 SwarmState publishes the next price and the purchase count", state:GetAttribute("ChestCost") == Gold.ChestCost() and state:GetAttribute("TeamChestsBought") == Gold.ChestsBought() and state:GetAttribute("TeamRunGold") == 0)
	check("1 one reward per recipient", (rewards[rM] or 0) + (rewards[rA] or 0) >= 1 and (rewards[rM] or 0) <= 1 and (rewards[rA] or 0) <= 1, string.format("me %d ava %d", rewards[rM] or 0, rewards[rA] or 0))

	local c2 = newChest()
	local cost2 = Gold.ChestCost()
	Gold.SetTeamGold(cost2 + 50)
	hold({ me }, c2)
	check("1 above: one debit, the rest kept", c2.State == "Opened" and Gold.TeamGold() == 50, Gold.TeamGold())
end

------------------------------------------------------------------------------------------
-- 2 rapid holds
------------------------------------------------------------------------------------------
do
	local c = newChest()
	local cost = Gold.ChestCost()
	Gold.SetTeamGold(cost * 3)
	local r0, b0 = rewardTotal(), Gold.ChestsBought()
	hold({ me }, c, function()
		for _ = 1, 6 do
			holdOn(me, c, true)
			preview.advance(0.03)
		end
		-- and once more after the hold time (a second completion attempt)
	end)
	holdOn(me, c, true)
	preview.advance(holdTime(c))
	holdOn(me, c, false)
	preview.advance(0.2)
	local dones = 0
	for _, m in ipairs(answersFor(c.Id)) do
		if m.State == "Done" then
			dones += 1
		end
	end
	check("2 rapid holds: paid once, one purchase, one Done", Gold.TeamGold() == cost * 2 and Gold.ChestsBought() == b0 + 1 and dones == 1, string.format("gold %d of %d, Done x%d", Gold.TeamGold(), cost * 3, dones))
	check("2 rapid holds: one reward set (one per recipient)", rewardTotal() - r0 <= 2 and rewardTotal() - r0 >= 1, rewardTotal() - r0)
end

------------------------------------------------------------------------------------------
-- 3 two players on one chest
------------------------------------------------------------------------------------------
do
	local c = newChest()
	local cost = Gold.ChestCost()
	Gold.SetTeamGold(cost * 3)
	local before = {}
	before[rM], before[rA] = rewards[rM] or 0, rewards[rA] or 0
	local b0 = Gold.ChestsBought()
	hold({ me, ava }, c)
	check("3 two holders: one debit, one purchase", Gold.TeamGold() == cost * 2 and Gold.ChestsBought() == b0 + 1, Gold.TeamGold())
	local gm, ga = (rewards[rM] or 0) - before[rM], (rewards[rA] or 0) - before[rA]
	check("3 exactly one reward per recipient", gm <= 1 and ga <= 1 and gm + ga >= 1, string.format("me +%d ava +%d", gm, ga))
	local mineAns = answersFor(c.Id)
	local st = last(mineAns)
	check("3 my answer is Done (I paid) or Cancel 'used' (Ava was faster), never both", (st.State == "Done") or (st.State == "Cancel" and st.Reason == "used"), tostring(st.State) .. "/" .. tostring(st.Reason))
end

------------------------------------------------------------------------------------------
-- 4 gold gained during the approach
------------------------------------------------------------------------------------------
do
	local c = newChest()
	local cost = Gold.ChestCost()
	Gold.SetTeamGold(cost - 3)
	hold({ me }, c)
	check("4 short while approaching: refused, nothing taken", c.State == "Ready" and Gold.TeamGold() == cost - 3)
	Gold.AddTeamGold(3) -- a kill lands
	hold({ me }, c)
	check("4 once the gold arrived the hold opens it (one debit)", c.State == "Opened" and Gold.TeamGold() == 0, Gold.TeamGold())
end

------------------------------------------------------------------------------------------
-- 5 multiple chests
------------------------------------------------------------------------------------------
do
	local a, b = newChest(), newChest()
	local cost = Gold.ChestCost()
	Gold.SetTeamGold(cost + 5)
	hold({ me }, a)
	local nextCost = Gold.ChestCost()
	check("5 the other chest shows the next price", b.Model:GetAttribute("Price") == nextCost and nextCost > cost, string.format("%s vs %d", tostring(b.Model:GetAttribute("Price")), nextCost))
	hold({ me }, b)
	check("5 the next chest is refused with the balance left (no wrong debit)", b.State == "Ready" and Gold.TeamGold() == 5, Gold.TeamGold())
end

------------------------------------------------------------------------------------------
-- 6 delayed update: the price rises mid-hold
------------------------------------------------------------------------------------------
do
	local mineC, other = newChest(), newChest()
	local cost = Gold.ChestCost()
	Gold.SetTeamGold(cost * 2)
	clearOffers()
	place(rA, other.Pos + Vector3.new(1.5, 0, 0))
	place(rM, mineC.Pos + Vector3.new(1.5, 0, 0))
	preview.advance(0.1)
	-- Ava starts first; my hold starts 0.3 s later on another chest at the price I was shown
	holdOn(ava, other, true)
	preview.advance(0.3)
	holdOn(me, mineC, true)
	preview.advance(holdTime(mineC) + 0.3)
	holdOn(ava, other, false)
	holdOn(me, mineC, false)
	preview.advance(0.2)
	local a = answersFor(mineC.Id)
	check("6 setup: Ava's purchase landed first", other.State == "Opened", other.State)
	check("6 the raised price refuses my hold, nothing taken, chest still Ready (recoverable)", mineC.State == "Ready" and Gold.TeamGold() == cost and last(a).State == "Cancel" and last(a).Reason == "gold",
		string.format("gold %d, state %s, answer %s/%s", Gold.TeamGold(), mineC.State, tostring(last(a).State), tostring(last(a).Reason)))
end

preview.log(fails == 0 and "PASS chest-purchase-regression" or ("FAIL chest-purchase-regression: " .. fails .. " failed"))
