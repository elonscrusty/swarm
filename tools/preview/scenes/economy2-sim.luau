-- economy2-sim: the redesign's loot economy (stream E2; RunConfig.Economy, DECISIONS C3 / C7 / C9)
-- on the REAL server (headless, Lune mock, NOT Studio). A Trio run (me, Ava, Ben; Cal arrives late):
--   A  XP curve 20 + 12(L-1) + 3(L-1)^2
--   B  an eligible kill: a personal shard of the full kind value for every eligible player
--      within 120 studs, downed included; eliminated, far (121 studs) and no-killer kills get
--      none; shards carry their owner; crowds merge per owner without changing the total
--   C  a shard is collected once, by its owner only; uncollected shards fade, then expire
--      after 30 s with no XP
--   D  the boss's XP is granted directly, once, to every eligible participant
--   E  team run gold per kind (3 / 6 / 20, none without a killer); chest prices 40, 54, 73,
--      ... capped at 400
--   F  chests: proximity never buys; two heroes finishing the same hold pay once; without
--      stream B's QueueChoice the opener gets the existing item; with it every snapshot
--      recipient (downed included; eliminated, disconnected, not-yet-arrived excluded) gets
--      one Chest / PassiveOnly choice and no item; late arrivals never inherit
--   G  class goals: dashes (validated only), distance (teleports excluded), close kills,
--      revives (deduped), elites, chests, weapons, XP; settlement once (repeat finish, replay
--      and partial + final commits add once; DEV runs add nothing); NewUnlocks and the save
--      state in the results
-- Prints PASS / FAIL lines; any FAIL fails tools/run_regressions.py.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
local ben = preview.addPlayer("Ben", 3)
local cal = preview.addPlayer("Cal", 4)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local RM = preview.server("RunManager")
local XP = preview.server("XPSystem")
local Gold = preview.server("GoldSystem")
local Loot = preview.server("LootSystem")
local LU = preview.server("LevelUpSystem")
local ES = preview.server("EnemySpawner")
local Items = preview.server("ItemSystem")
local DS = preview.server("DataService")
local Events = preview.server("Events")
local Remotes = preview.shared("Remotes")
local Config = preview.shared("Config")
local EnemyData = preview.shared("EnemyData")
local RunConfig = preview.require(ReplicatedStorage.SwarmV2.Run.RunConfig)
local Goals = preview.require(SSS.SwarmV2.Run.ClassGoals)
local E = RunConfig.Economy
local state = Remotes.State()

local fails = 0
local function check(label: string, ok: any, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

check("economy switch on", E.Enabled == true)

------------------------------------------------------------------------------------------
-- A  XP curve
------------------------------------------------------------------------------------------
do
	local got = {}
	for L = 1, 6 do
		table.insert(got, XP.XPNeeded(L))
	end
	check("A XPNeeded L1..6 = 20,35,56,83,116,155", table.concat(got, ",") == "20,35,56,83,116,155", table.concat(got, ","))
	check("A XPNeeded L10 = 371", XP.XPNeeded(10) == 371, XP.XPNeeded(10))
	check("A CoopShare off (1)", XP.CoopShare() == 1)
end

------------------------------------------------------------------------------------------
-- helpers
------------------------------------------------------------------------------------------
-- only the kills this scene makes reach the economy (the heroes' weapons keep killing the
-- background swarm: those are ignored here so every count below is exact)
local accept = false
local realOnKill = XP.OnEnemyKilled
XP.OnEnemyKilled = function(e, rp, pos)
	if accept then
		return realOnKill(e, rp, pos)
	end
	return true
end
-- every personal grant
local grants: { { Who: any, Value: number } } = {}
local realShardXP = XP.GiveShardXP
XP.GiveShardXP = function(rp, value)
	table.insert(grants, { Who = rp, Value = value })
	return realShardXP(rp, value)
end
local function granted(rp): (number, number)
	local n, v = 0, 0
	for _, g in ipairs(grants) do
		if g.Who == rp then
			n += 1
			v += g.Value
		end
	end
	return n, v
end
-- item grants (old chest reward)
local itemGrants: { [any]: number } = {}
local realGrant = Items.Grant
Items.Grant = function(rp, id, ...)
	local ok, dramatic = realGrant(rp, id, ...)
	if ok then
		itemGrants[rp] = (itemGrants[rp] or 0) + 1
	end
	return ok, dramatic
end
-- RunResult payloads
local results: { [Player]: any } = {}
local feedback: { [Player]: { any } } = {}
local origFire = Remotes.FireClient
Remotes.FireClient = function(name, p, payload, ...)
	if name == "RunResult" then
		results[p] = payload
	elseif name == "LootFeedback" then
		feedback[p] = feedback[p] or {}
		table.insert(feedback[p], payload)
	end
	return origFire(name, p, payload, ...)
end

assert(RM.StartTeamRun({ me, ava, ben }, "Trio", "Forest", me), "trio run starts")
preview.advance(2)
local rM, rA, rB = assert(RM.GetRunPlayer(me)), assert(RM.GetRunPlayer(ava)), assert(RM.GetRunPlayer(ben))
for _, rp in ipairs({ rM, rA, rB }) do
	rp.InvulnUntil = math.huge
end
ES.SetHold("economy2", true)

local rA0 = nil -- (Ava's record, set below)
local function clearOffers()
	-- Ava stays downed through the long sections (stream E1 eliminates after BleedSeconds)
	if rA0 and rA0.Downed == true then
		rA0.BleedLeft = 20
	end
	for _, rp in ipairs(RM.GetRunPlayers()) do
		if rp.Offer or rp.Paused or (rp.PendingLevels or 0) > 0 then
			LU.Cancel(rp)
		end
	end
end
local arena = preview.server("MapBuilder").GetArena()
local C0 = (arena and arena.Center) or Config.ArenaOrigin
local groundY = C0.Y
local K = Vector3.new(C0.X - 60, groundY, C0.Z) -- the kill spot
local function place(rp, at: Vector3)
	rp.Root.CFrame = CFrame.new(Vector3.new(at.X, groundY + 3, at.Z))
	rp.Root.AssemblyLinearVelocity = Vector3.zero
	rp.LastValidPos = rp.Root.Position
	rp.SpeedCheckTimer = 0
end
local function killAt(typeId: string, at: Vector3, killer, opts)
	local o = opts or {}
	o.Force = true
	local e = assert(ES.Spawn(typeId, at, o), "spawn " .. typeId)
	e.Pos = Vector3.new(at.X, e.Pos.Y, at.Z)
	accept = true
	ES.Kill(e, killer)
	accept = false
	return e
end

-- Ava goes down far from everyone (a teammate standing next to her would revive her)
place(rM, K + Vector3.new(80, 0, 0))
place(rB, K + Vector3.new(135, 0, 0))
place(rA, K + Vector3.new(40, 0, 0))
rA.InvulnUntil = 0
rA.RevivesLeft, rA.ProductReviveUsed = 0, true
RM.DamagePlayer(rA, 1e7, "economy2 test")
preview.advance(0.5)
check("setup Ava is downed and still in the run", rA.Alive == false and table.find(RM.GetRunPlayers(), rA) ~= nil)
rA0 = rA
check("setup downed Ava is eligible", XP.IsEligible(rA) == true)
ES.DespawnAll()
clearOffers()

------------------------------------------------------------------------------------------
-- B  personal shards and team gold per kill
------------------------------------------------------------------------------------------
place(rM, K + Vector3.new(80, 0, 0)) -- 80 studs away: in range, out of pickup reach
place(rB, K + Vector3.new(135, 0, 0)) -- out of range
local gold0 = Gold.TeamGold()
killAt("Slime", K, rM)
local nM, vM = XP.ShardsOf(rM)
local nA, vA = XP.ShardsOf(rA)
local nB = XP.ShardsOf(rB)
check("B Normal kill: my shard of 4", nM == 1 and vM == E.XP.ByKind.Normal, nM .. "/" .. vM)
check("B Normal kill: downed Ava gets her own shard of 4", nA == 1 and vA == 4, nA .. "/" .. vA)
check("B Normal kill: Ben 135 studs away gets none", nB == 0, nB)
check("B a replaced run record (reconnect) still owns its shards (by UserId)", (XP.ShardsOf(table.clone(rA))) == nA)
check("B team gold +3 for a Normal kill", Gold.TeamGold() - gold0 == 3, Gold.TeamGold() - gold0)
-- the shard parts carry their owner (other clients hide them)
do
	local owners = {}
	for _, part in ipairs(workspace.SwarmGems:GetChildren()) do
		if part:GetAttribute("Active") == true then
			owners[part:GetAttribute("Owner") or 0] = true
		end
	end
	check("B shard parts carry Owner = UserId (me, Ava)", owners[me.UserId] == true and owners[ava.UserId] == true and owners[ben.UserId] == nil)
end

-- the 120-stud cutoff (3D distance from the kill to the root)
place(rB, K + Vector3.new(119, 0, 0))
killAt("Slime", K, rM)
check("B Ben at 119 studs gets a shard", (XP.ShardsOf(rB)) == 1)
place(rB, K + Vector3.new(121, 0, 0))
local nB1 = XP.ShardsOf(rB)
killAt("Slime", K + Vector3.new(0, 0, 20), rM) -- a new spot (no merge)
check("B Ben at 121+ studs gets none (no catch-up)", (XP.ShardsOf(rB)) == nB1)

-- eliminated players get nothing
place(rB, K + Vector3.new(60, 0, 0))
ben:SetAttribute("Eliminated", true)
local nB2 = XP.ShardsOf(rB)
killAt("Slime", K + Vector3.new(0, 0, -20), rM)
check("B eliminated Ben gets no shard", (XP.ShardsOf(rB)) == nB2 and XP.IsEligible(rB) == false)
do
	local xpB, lvB = rB.XP, rB.Level
	XP.GiveXP(rB, 5)
	check("B GiveXP: an eliminated hero gets nothing", rB.XP == xpB and rB.Level == lvB)
end
ben:SetAttribute("Eliminated", nil)

-- a kill without a killer (sweep, self-destruct): no XP, no gold
local before = { XP.ShardsOf(rM) }
local g1 = Gold.TeamGold()
killAt("Slime", K + Vector3.new(0, 0, 40), nil)
check("B no-killer kill: no shard, no gold", (XP.ShardsOf(rM)) == before[1] and Gold.TeamGold() == g1)

-- Tough and Elite
place(rB, K + Vector3.new(135, 0, 0))
local g2 = Gold.TeamGold()
local _, vm0 = XP.ShardsOf(rM)
killAt("Brute", K + Vector3.new(0, 0, 60), rM)
local _, vm1 = XP.ShardsOf(rM)
check("B Tough (Brute): shard 8, team gold +6", vm1 - vm0 == 8 and Gold.TeamGold() - g2 == 6, (vm1 - vm0) .. " / " .. (Gold.TeamGold() - g2))
local elitesM0, elitesA0, elitesB0 = Goals.For(rM).Elites, Goals.For(rA).Elites, Goals.For(rB).Elites
killAt("Slime", K + Vector3.new(0, 0, -60), rM, { Elite = true })
local _, vm2 = XP.ShardsOf(rM)
check("B Elite: shard 20, team gold +20", vm2 - vm1 == 20 and Gold.TeamGold() - g2 == 26, (vm2 - vm1) .. " / " .. (Gold.TeamGold() - g2))
check("B Elite goal: cooperative for eligible players in range only (me, Ava; not far Ben)",
	Goals.For(rM).Elites == elitesM0 + 1 and Goals.For(rA).Elites == elitesA0 + 1 and Goals.For(rB).Elites == elitesB0)

-- crowds: a second kill on the same spot inside the merge window joins my shard
local nm3, vm3 = XP.ShardsOf(rM)
killAt("Slime", K, rM)
local nm4, vm4 = XP.ShardsOf(rM)
check("B crowd merge: same shard count, +4 value", nm4 == nm3 and vm4 == vm3 + 4, string.format("%d->%d, %d->%d", nm3, nm4, vm3, vm4))
preview.advance(0.3)
check("B TeamRunGold / ChestCost attributes published", state:GetAttribute("TeamRunGold") == Gold.TeamGold() and state:GetAttribute("ChestCost") == Gold.ChestCost(),
	tostring(state:GetAttribute("TeamRunGold")) .. " / " .. tostring(state:GetAttribute("ChestCost")))

------------------------------------------------------------------------------------------
-- C  collection once, owner only; expiry
------------------------------------------------------------------------------------------
clearOffers()
local _, myValue = XP.ShardsOf(rM)
local nAva, vAva = XP.ShardsOf(rA)
local gN0, gV0 = granted(rM)
local goalXP0 = Goals.For(rM).XP
-- walk over every shard spot (mine and Ava's lie on the same spots)
for _, off in ipairs({ Vector3.zero, Vector3.new(0, 0, 20), Vector3.new(0, 0, -20), Vector3.new(0, 0, 60), Vector3.new(0, 0, -60) }) do
	place(rM, K + off)
	preview.advance(0.6)
	clearOffers()
end
local nMine = XP.ShardsOf(rM)
local _, gV1 = granted(rM)
check("C my shards collected", nMine == 0, nMine)
check("C collected value = my entitlement, granted once", gV1 - gV0 == myValue, (gV1 - gV0) .. " vs " .. myValue)
check("C class-goal XP counts the base value", Goals.For(rM).XP - goalXP0 == myValue, Goals.For(rM).XP - goalXP0)
local nAva2, vAva2 = XP.ShardsOf(rA)
check("C Ava's shards untouched by me (owner only)", nAva2 == nAva and vAva2 == vAva and select(1, granted(rA)) == 0)
preview.advance(1)
local _, gV2 = granted(rM)
check("C nothing granted again", gV2 == gV1)
-- expiry: Ava is downed 40 studs from her shards: they fade, then vanish with no XP
place(rM, K + Vector3.new(80, 0, 0))
local faded = false
local fadeAtRun = nil
local t0 = RM.GetRunTime()
for _ = 1, 80 do
	preview.advance(0.5)
	clearOffers()
	if not faded then
		for _, part in ipairs(workspace.SwarmGems:GetChildren()) do
			if part:GetAttribute("Active") == true and part:GetAttribute("Owner") == ava.UserId and part:GetAttribute("Fade") ~= nil then
				faded = true
				fadeAtRun = RM.GetRunTime() - t0
			end
		end
	end
	if (XP.ShardsOf(rA)) == 0 then
		break
	end
end
check("C Ava's shards announced a fade before expiring", faded, fadeAtRun and string.format("%.1f s", fadeAtRun))
check("C Ava's shards expired (about 30 s of run clock)", (XP.ShardsOf(rA)) == 0, string.format("%.1f s", RM.GetRunTime() - t0))
check("C expired shards gave no XP", select(1, granted(rA)) == 0)

------------------------------------------------------------------------------------------
-- D  boss XP: directly, once, to every eligible participant
------------------------------------------------------------------------------------------
do
	clearOffers()
	check("D Ava is still downed, not eliminated", rA.Alive == false and not (RM.IsEliminated and RM.IsEliminated(rA)))
	local fake = { Def = EnemyData.Enemies.Boss, Boss = true, Uid = 987654, Pos = K, Alive = false }
	local b0 = { granted(rM) }
	local bA = { granted(rA) }
	local bB = { granted(rB) }
	local bossesA = Goals.For(rA).Bosses
	local goldB = Gold.TeamGold()
	accept = true
	XP.OnEnemyKilled(fake, nil, K)
	XP.OnEnemyKilled(fake, rM, K) -- a repeated boss event
	accept = false
	local a0 = { granted(rM) }
	local aA = { granted(rA) }
	local aB = { granted(rB) }
	check("D boss XP 100 directly to me, once", a0[1] - b0[1] == 1 and a0[2] - b0[2] == 100)
	check("D boss XP to downed Ava and far Ben too, once each", aA[1] - bA[1] == 1 and aB[1] - bB[1] == 1)
	check("D boss: no shard, no team gold", (XP.ShardsOf(rB)) == 0 and Gold.TeamGold() == goldB)
	check("D Bosses goal +1 (cooperative)", Goals.For(rA).Bosses == bossesA + 1)
	clearOffers()
end

------------------------------------------------------------------------------------------
-- E  chest prices
------------------------------------------------------------------------------------------
do
	local got = {}
	for k = 0, 9 do
		table.insert(got, Gold.ChestCostAt(k))
	end
	check("E chest cost 40,54,73,98,133,179,242,327,400,400", table.concat(got, ",") == "40,54,73,98,133,179,242,327,400,400", table.concat(got, ","))
end

------------------------------------------------------------------------------------------
-- F  chests
------------------------------------------------------------------------------------------
local function readyTeamChest(skip)
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.TeamChest and obj.State == "Ready" and obj ~= skip then
			return obj
		end
	end
	return nil
end
local function holdAll(holders: { Player }, obj)
	for _, p in ipairs(holders) do
		local rp = RM.GetRunPlayer(p)
		place(rp, obj.Pos + Vector3.new(1.5, 0, 0))
	end
	preview.advance(0.1)
	for _, p in ipairs(holders) do
		if p == me then
			preview.remote("LootHold"):FireServer(obj.Id, true)
		else
			preview.fireServerAs(p, "LootHold", obj.Id, true)
		end
	end
	preview.advance((obj.Model:GetAttribute("Hold") or 1) + 0.4)
	for _, p in ipairs(holders) do
		if p == me then
			preview.remote("LootHold"):FireServer(obj.Id, false)
		else
			preview.fireServerAs(p, "LootHold", obj.Id, false)
		end
	end
	preview.advance(0.2)
end

clearOffers()
ES.DespawnAll()
local realQueueChoice = LU.QueueChoice -- (stream B's, once merged: restored at the end)
LU.QueueChoice = nil
local chest = readyTeamChest()
check("F team chests exist (TeamGold attribute, shared price)", chest ~= nil and chest.Model:GetAttribute("TeamGold") == true and chest.Model:GetAttribute("Price") == Gold.ChestCost())
if chest then
	-- proximity never buys
	Gold.AddTeamGold(5000)
	local before = Gold.TeamGold()
	place(rM, chest.Pos + Vector3.new(1, 0, 0))
	preview.advance(3)
	check("F standing at a chest buys nothing", chest.State == "Ready" and Gold.TeamGold() == before)

	-- fallback: no QueueChoice yet -> the existing item for the opener, team gold paid once
	check("F without QueueChoice the chest keeps its item reward", LU.QueueChoice == nil and Items.ChestItemsHidden() == false)
	local escrow0 = Gold.RunWallet(rM)
	local bought0, cost0 = Gold.ChestsBought(), Gold.ChestCost()
	local itemsM0, itemsA0 = itemGrants[rM] or 0, itemGrants[rA] or 0
	holdAll({ me }, chest)
	check("F opened with team gold: one debit of the shown price", chest.State == "Opened" and Gold.TeamGold() == before - cost0 and Gold.ChestsBought() == bought0 + 1,
		string.format("%d -> %d (cost %d)", before, Gold.TeamGold(), cost0))
	check("F the personal escrow is not spent", Gold.RunWallet(rM) == escrow0)
	check("F fallback: one item for the opener only", (itemGrants[rM] or 0) == itemsM0 + 1 and (itemGrants[rA] or 0) == itemsA0)
	check("F next price shown on every team chest", (function()
		for _, obj in ipairs(Loot.Objects()) do
			if obj.TeamChest and obj.State == "Ready" and obj.Model:GetAttribute("Price") ~= Gold.ChestCost() then
				return false
			end
		end
		return true
	end)())
	RM.EndReward(rM)
	clearOffers()
	-- re-holding the opened chest: nothing
	local g3 = Gold.TeamGold()
	holdAll({ me }, chest)
	check("F holding an opened chest again pays nothing", Gold.TeamGold() == g3)
end

-- with stream B's QueueChoice: passive choices for the recipient snapshot, no item
local queued: { [any]: { { Source: string, Kind: string } } } = {}
LU.QueueChoice = function(rp, source, kind)
	queued[rp] = queued[rp] or {}
	table.insert(queued[rp], { Source = source, Kind = kind })
end
local function nQueued(rp): number
	return queued[rp] and #queued[rp] or 0
end
check("F with QueueChoice chests hide the old items", Items.ChestItemsHidden() == true)
local chest2 = readyTeamChest(chest)
if chest2 then
	clearOffers()
	-- two heroes finish the same hold together: one debit, one opening
	local g4, cost4, bought4 = Gold.TeamGold(), Gold.ChestCost(), Gold.ChestsBought()
	local items0 = (itemGrants[rM] or 0) + (itemGrants[rB] or 0) + (itemGrants[rA] or 0)
	local chestsM, chestsB = Goals.For(rM).Chests, Goals.For(rB).Chests
	feedback[me], feedback[ben] = {}, {}
	holdAll({ me, ben }, chest2)
	check("F double interact: opened once, paid once", chest2.State == "Opened" and Gold.TeamGold() == g4 - cost4 and Gold.ChestsBought() == bought4 + 1,
		string.format("gold %d -> %d, bought %d -> %d", g4, Gold.TeamGold(), bought4, Gold.ChestsBought()))
	local cancels = 0
	for _, p in ipairs({ me, ben }) do
		for _, f in ipairs(feedback[p] or {}) do
			if f.State == "Cancel" then
				cancels += 1
			end
		end
	end
	check("F the slower hold was cancelled", cancels >= 1, cancels)
	check("F one Chests goal for the opener only", (Goals.For(rM).Chests - chestsM) + (Goals.For(rB).Chests - chestsB) == 1)
	check("F every recipient got exactly one Chest/PassiveOnly choice (me, Ben, downed Ava)",
		nQueued(rM) == 1 and nQueued(rB) == 1 and nQueued(rA) == 1 and queued[rM][1].Source == "Chest" and queued[rM][1].Kind == "PassiveOnly")
	check("F no old item from the chest", (itemGrants[rM] or 0) + (itemGrants[rB] or 0) + (itemGrants[rA] or 0) == items0)
end

-- eliminated Ben is not in the snapshot; Cal (not arrived) neither, and never inherits
local chest3 = readyTeamChest(chest2)
if chest3 then
	clearOffers()
	ben:SetAttribute("Eliminated", true)
	local qM, qA, qB = nQueued(rM), nQueued(rA), nQueued(rB)
	holdAll({ me }, chest3)
	check("F eliminated Ben excluded, me and downed Ava included", nQueued(rM) == qM + 1 and nQueued(rA) == qA + 1 and nQueued(rB) == qB)
	ben:SetAttribute("Eliminated", nil)
	check("F Cal joins late", RM.AddLatePlayer(cal) == true)
	preview.advance(0.5)
	local rC = RM.GetRunPlayer(cal)
	check("F the late arrival inherits no earlier chest", rC ~= nil and nQueued(rC) == 0)
	local chest4 = readyTeamChest(chest3)
	if chest4 and rC then
		clearOffers()
		holdAll({ me }, chest4)
		check("F a later purchase includes the arrived Cal", nQueued(rC) == 1)
	end
end

-- stream B's real QueueChoice (once merged): the chest choice lands in each recipient's queue
if realQueueChoice then
	LU.QueueChoice = realQueueChoice
	clearOffers()
	local chest5
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.TeamChest and obj.State == "Ready" and (obj.Price or 0) > 0 then
			chest5 = obj
			break
		end
	end
	if chest5 then
		local function chestQueued(rp): number
			local n = 0
			for _, q in ipairs(rp.ChoiceQueue or {}) do
				if q.Source == "Chest" and q.Kind == "PassiveOnly" then
					n += 1
				end
			end
			return n
		end
		local qA0 = chestQueued(rA)
		rM.XPNeeded = 1e12 -- (no level choice gets in the way of the count)
		holdAll({ me }, chest5)
		check("F real QueueChoice: downed Ava holds one queued Chest/PassiveOnly choice", chestQueued(rA) == qA0 + 1, chestQueued(rA) - qA0)
		check("F real QueueChoice: my chest choice is offered (or queued)", (rM.Offer ~= nil and LU.PendingCount(rM) >= 1) or chestQueued(rM) >= 1, LU.PendingCount(rM))
		clearOffers()
	end
	LU.QueueChoice = nil
end

------------------------------------------------------------------------------------------
-- G  class goals and the settlement
------------------------------------------------------------------------------------------
clearOffers()
ES.DespawnAll()
-- dashes: the real Dash remote (server-validated); one too early is refused and not counted
do
	local dash = ReplicatedStorage:FindFirstChild("SwarmV2Net") and ReplicatedStorage.SwarmV2Net.Run:FindFirstChild("Dash")
	local d0 = Goals.For(rM).Dashes
	place(rM, C0 + Vector3.new(0, 0, 40))
	if dash then
		for i = 1, 3 do
			rM.LastValidPos, rM.SpeedCheckTimer = nil, 0
			dash:FireServer(Vector3.new(1, 0, 0))
			preview.advance(0.3)
			if i == 1 then
				dash:FireServer(Vector3.new(1, 0, 0)) -- inside the cooldown: refused
				preview.advance(0.1)
			end
			preview.advance(2.5)
			clearOffers()
		end
	end
	check("G Dashes: 3 validated dashes counted, the early one not", Goals.For(rM).Dashes - d0 == 3, Goals.For(rM).Dashes - d0)
end
-- distance: 10 steps of 5 studs at 4 Hz count; a teleport does not
do
	place(rM, C0 + Vector3.new(-40, 0, -40))
	preview.advance(0.6)
	local g = Goals.For(rM)
	local d0 = g.Distance
	for i = 1, 10 do
		place(rM, C0 + Vector3.new(-40 + i * 5, 0, -40))
		preview.advance(0.25)
	end
	preview.advance(0.3)
	local walked = g.Distance - d0
	check("G Distance counts legitimate movement (about 50 studs)", walked >= 40 and walked <= 55, string.format("%.1f", walked))
	local d1 = g.Distance
	place(rM, C0 + Vector3.new(120, 0, 100)) -- a teleport
	preview.advance(0.6)
	check("G Distance ignores a teleport", g.Distance - d1 < 5, string.format("%.1f", g.Distance - d1))
end
-- close kills: Sword / melee / dash sources within 10 studs only
do
	local g = Goals.For(rM)
	local c0 = g.CloseKills
	local root = rM.Root.Position
	Goals.OnWeaponKill(rM, { Id = "Whip" }, { Pos = root + Vector3.new(6, 0, 0) })
	Goals.OnWeaponKill(rM, { Id = "Whip" }, { Pos = root + Vector3.new(20, 0, 0) })
	Goals.OnWeaponKill(rM, { Id = "Knives" }, { Pos = root + Vector3.new(3, 0, 0) })
	Goals.OnWeaponKill(rM, { Id = "ScrapToss", Dash = true }, { Pos = root + Vector3.new(4, 0, 0) })
	check("G CloseKills: Sword near + dash near count; far and ranged do not", g.CloseKills - c0 == 2, g.CloseKills - c0)
end
-- revives: the real event, deduped
do
	local r0 = Goals.For(rB).Revives
	Events.Fire("PartnerRevive", ben)
	Goals.OnRevive(rB) -- the same completion reported again (stream E1 hook)
	check("G Revives: one completion counts once", Goals.For(rB).Revives == r0 + 1, Goals.For(rB).Revives - r0)
	-- stream E1 also counts it on rp.Revives: the settlement takes one of them, never both
	local saveRevives = rB.Revives
	rB.Revives = Goals.For(rB).Revives
	check("G Revives: rp.Revives and the event counter are not added together", Goals.Snapshot(rB, 0).Revives == Goals.For(rB).Revives)
	rB.Revives = saveRevives
end
-- weapons held
do
	LU.AddWeapon(rM, "Whip")
	preview.advance(0.6)
	check("G MostWeapons follows the weapons held", Goals.For(rM).MostWeapons >= 2 and Goals.For(rM).MostWeapons == #rM.WeaponOrder, Goals.For(rM).MostWeapons)
end

-- the lobby grant: ClassOwnership.RefreshEarned (stubbed here: the lobby track adds it)
local CO = preview.require(SSS.SwarmV2.Lobby.ClassOwnership)
local hadRefresh = CO.RefreshEarned
local refreshCalls = 0
CO.RefreshEarned = function(player)
	refreshCalls += 1
	return player == me and { "toastmaster" } or {}
end

clearOffers()
local data = assert(DS.GetData(me))
data.Stats.ClassGoals = { XP = 5, Unknown = "kept" } -- an older partial table: added to, never reset
local snap = Goals.Snapshot(rM, RM.GetRunTime())
local kills = rM.Kills
RM.AbandonRun(rM)
preview.advance(0.5)
local saved = data.Stats.ClassGoals
check("G settlement writes data.Stats.ClassGoals", type(saved) == "table")
if type(saved) == "table" then
	check("G XP added to the old value (5 + run XP)", saved.XP == 5 + math.floor(snap.XP), tostring(saved.XP) .. " vs " .. (5 + math.floor(snap.XP)))
	check("G unknown keys kept", saved.Unknown == "kept")
	check("G Kills = credited kills", saved.Kills == kills, tostring(saved.Kills) .. " vs " .. kills)
	check("G Dashes / Chests / CloseKills / Elites / Bosses", saved.Dashes == snap.Dashes and saved.Chests == snap.Chests and saved.CloseKills == snap.CloseKills
		and saved.Elites == snap.Elites and saved.Bosses == snap.Bosses,
		string.format("D%s C%s CK%s E%s B%s", tostring(saved.Dashes), tostring(saved.Chests), tostring(saved.CloseKills), tostring(saved.Elites), tostring(saved.Bosses)))
	check("G Distance whole studs", saved.Distance == math.floor(snap.Distance) or saved.Distance == math.floor(Goals.For(rM).Distance), tostring(saved.Distance))
	check("G BestSurvive / MostWeapons", (saved.BestSurvive or 0) >= math.floor(snap.BestSurvive) - 1 and saved.MostWeapons == snap.MostWeapons,
		tostring(saved.BestSurvive) .. " / " .. tostring(saved.MostWeapons))
end
check("G RefreshEarned called once after the commit", refreshCalls == 1, refreshCalls)
check("G CommitInfo.NewUnlocks = the lobby's answer", rM.CommitInfo and rM.CommitInfo.NewUnlocks and rM.CommitInfo.NewUnlocks[1] == "toastmaster")
local res = results[me]
check("G RunResult carries NewUnlocks", res ~= nil and type(res.NewUnlocks) == "table" and res.NewUnlocks[1] == "toastmaster")
local saveState = me:GetAttribute("RunSaveState")
check("G save state honest (never Saved without a store)", res ~= nil and res.SaveState ~= nil
	and ((DS.IsMemoryOnly() and saveState == "NotSaved") or (not DS.IsMemoryOnly() and (saveState == "Saved" or saveState == "Failed" or saveState == "Pending"))),
	tostring(res and res.SaveState) .. " -> " .. tostring(saveState))
-- repeat finish, replay, duplicate commit
local copy = table.clone(saved)
RM.AbandonRun(rM)
preview.advance(0.3)
local again = Goals.Commit(rM, data, copy.BestSurvive) -- a replay of the same settlement
local same = true
for k, v in pairs(copy) do
	if saved[k] ~= v then
		same = false
	end
end
check("G a repeated finish and a replayed commit add nothing", same and refreshCalls == 1 and again ~= nil and again.XP == 0 and again.Kills == 0 and again.Dashes == 0,
	string.format("same=%s refresh=%d", tostring(same), refreshCalls))
-- partial (disconnect) + final commits add once
do
	local dataA = assert(DS.GetData(ava))
	dataA.Stats.ClassGoals = nil
	local gA = Goals.For(rA)
	local e0 = gA.Elites
	Goals.Commit(rA, dataA, 10)
	gA.Elites += 2
	Goals.Commit(rA, dataA, 20)
	Goals.Commit(rA, dataA, 20)
	check("G partial + final commits: each elite counted once", dataA.Stats.ClassGoals.Elites == e0 + 2 and dataA.Stats.ClassGoals.BestSurvive == 20,
		tostring(dataA.Stats.ClassGoals.Elites) .. " vs " .. (e0 + 2))
end
-- a DEV-tainted run adds nothing
do
	local dataB = assert(DS.GetData(ben))
	dataB.Stats.ClassGoals = nil
	rB.DevTainted = true
	check("G DEV-tainted run: no class-goal progress", Goals.Commit(rB, dataB, 100) == nil and dataB.Stats.ClassGoals == nil)
	rB.DevTainted = false
end
CO.RefreshEarned = hadRefresh
LU.QueueChoice = realQueueChoice
ES.SetHold("economy2", false)

preview.log(fails == 0 and "ALL PASS economy2-sim" or (fails .. " FAIL economy2-sim"))
