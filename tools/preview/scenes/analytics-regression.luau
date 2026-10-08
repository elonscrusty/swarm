-- analytics-regression: the new-player funnel and first-milestone events (server
-- Analytics.lua, docs/ANALYTICS.md) against the AnalyticsService mock (preview.analytics()).
-- Boots the real server as a published lobby (PlaceId set, run servers off so runs play
-- here) and checks, as PASS / FAIL lines:
--   step 1 only for accounts that never started a run, and never on a run server;
--   ClientReady (step 2): ignored before the save loads, from veterans and on repeats,
--   junk arguments ignored, accepted once;
--   an AnalyticsService error never blocks the save, the run or later steps;
--   step 3 + "Started Second Run" from the save's Stats.Runs at a real run start;
--   "First Wave Completed" only for wave 1 of the account's first run when it is cleared,
--   never when it times out;
--   "First Evolution" from a real chest evolution and a real level-up card, once per account.
-- With --studio nothing reaches AnalyticsService (Roblox drops Studio events) but the
-- module's local log holds the same entries.
-- Run: lune run tools/preview/runtime/main.luau -- --scene analytics-regression --device pc --out <json> --set headless=on [--studio]
local Players = game:GetService("Players")
local studio = game:GetService("RunService"):IsStudio()
local me = Players.LocalPlayer
local T = preview.teleport()
T.placeId = 4242
local A = preview.analytics()
local Config = preview.shared("Config")
Config.RunServers.Enabled = false -- runs play on this server (the run-server path is RunServers' own sims)
Config.Features.Walkthrough = false -- its wave hold is not what this scene checks
local DS = preview.server("DataService")
local storeName = studio and (Config.Data.StudioStoreName or (Config.Data.StoreName .. "_Studio")) or Config.Data.StoreName
local store = game:GetService("DataStoreService"):GetDataStore(storeName)

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end

-- a veteran: runs played and an evolution discovered
local ava = preview.addPlayer("Ava", 2)
local vet = DS.DefaultData()
vet.Stats.Runs = 4
vet.TutorialDone = true
vet.Discovered.Evolutions.Whip = true
store:SetAsync(Config.Data.KeyPrefix .. ava.UserId, { Data = vet })

preview.startServer()
preview.advance(3)
local Analytics = preview.server("Analytics")
local RM = preview.server("RunManager")
local ES = preview.server("EnemySpawner")
local LU = preview.server("LevelUpSystem")
local WeaponData = preview.shared("WeaponData")
local PassiveData = preview.shared("PassiveData")

-- what reached AnalyticsService (published) or would have (Studio: the module's log)
local function sentTo(p: Player): { string }
	local out = {}
	if studio then
		for _, e in ipairs(Analytics.Log) do
			if e.UserId == p.UserId then
				table.insert(out, e.Kind == "Step" and (e.Step .. ":" .. e.Name) or e.Name)
			end
		end
	else
		for _, c in ipairs(A.calls) do
			if c.UserId == p.UserId then
				table.insert(out, c.Method == "Onboarding" and (c.Step .. ":" .. c.Name) or c.Name)
			end
		end
	end
	return out
end
local function list(p: Player): string
	return table.concat(sentTo(p), ", ")
end
local function count(p: Player, name: string): number
	local n = 0
	for _, s in ipairs(sentTo(p)) do
		if s == name then
			n += 1
		end
	end
	return n
end

check("new account: step 1 on join", list(me) == "1:Joined Game", list(me))
check("veteran: nothing on join", list(ava) == "", list(ava))

-- step 2: the client's ready report
preview.fireServerAs(ava, "ClientReady")
preview.advance(1.1)
check("veteran ClientReady ignored", list(ava) == "", list(ava))
for i = 1, 6 do
	preview.remote("ClientReady"):FireServer("junk", i, { Step = 3 })
	preview.advance(0.6)
end
check("ClientReady accepted once, arguments ignored", list(me) == "1:Joined Game, 2:Ready to Play", list(me))

-- a new player whose ClientReady comes before the save loads, and whose step 1 call fails
local ben = preview.addPlayer("Ben", 3)
preview.fireServerAs(ben, "ClientReady")
preview.advance(1.1)
check("ClientReady before the save loads is dropped", list(ben) == "", list(ben))
if not studio then
	A.fails = 1
end
preview.playerJoined(ben)
preview.advance(3)
check("an AnalyticsService error does not block the save", DS.GetData(ben) ~= nil)
check(studio and "step 1 recorded (Studio log)" or "failed step 1 not retried", list(ben) == (studio and "1:Joined Game" or ""), list(ben))
preview.fireServerAs(ben, "ClientReady")
preview.advance(1.1)
check("step 2 still sent after a failed step 1", count(ben, "2:Ready to Play") == 1, list(ben))

-- run servers never send step 1 (their players came from a lobby)
local RS = preview.server("RunServers")
local realRole = RS.IsRunServer
RS.IsRunServer = function()
	return true
end
local cal = preview.addPlayer("Cal", 4)
preview.playerJoined(cal)
preview.advance(3)
preview.fireServerAs(cal, "ClientReady")
preview.advance(1.1)
RS.IsRunServer = realRole
check("run server: no step 1 / 2", list(cal) == "", list(cal))

-- run 1: Duo, me (first run) + Ava (veteran); wave 1 made unkillable so it times out
local function protect(rp)
	rp.InvulnUntil = math.huge
end
local function waitFor(cond: () -> boolean, seconds: number): boolean
	local t = 0
	while t < seconds do
		if cond() then
			return true
		end
		preview.advance(0.5)
		t += 0.5
	end
	return cond()
end
local state = game:GetService("ReplicatedStorage"):WaitForChild("SwarmState")
check("run 1 starts", RM.StartTeamRun({ me, ava }, "Duo", "Forest", me))
preview.advance(0.5)
protect(RM.GetRunPlayer(me))
protect(RM.GetRunPlayer(ava))
check("first run start: step 3", count(me, "3:Started First Run") == 1, list(me))
check("veteran run start: nothing", list(ava) == "", list(ava))
local function keepAlive(seconds: number)
	local t = 0
	while t < seconds do
		for _, e in ipairs(ES.Active) do
			if e.Alive then
				e.HP = 1e9
			end
		end
		for _, p in ipairs({ me, ava }) do
			local rp = RM.GetRunPlayer(p)
			if rp then
				protect(rp)
				if rp.Offer then
					LU.Cancel(rp)
				end
			end
		end
		preview.advance(0.5)
		t += 0.5
	end
end
check("wave 1 begins", waitFor(function()
	return (state:GetAttribute("Wave") or 0) >= 1
end, 20), tostring(state:GetAttribute("Wave")))
keepAlive(Config.Waves.MaxSeconds + Config.Waves.BurstSeconds + 2)
check("wave 1 timed out (wave 2 or its breather follows)", (state:GetAttribute("WaveNext") or 0) > 0 or (state:GetAttribute("Wave") or 0) >= 2)
check("timed-out wave 1: no First Wave Completed", count(me, "First Wave Completed") == 0, list(me))
RM.AbandonRun(RM.GetRunPlayer(me))
RM.AbandonRun(RM.GetRunPlayer(ava))
preview.advance(12)

-- run 2: Solo, Ben's first run: clear wave 1 for real, then a chest evolution
check("run 2 starts", RM.StartTeamRun({ ben }, "Solo", "Forest", ben), tostring(state:GetAttribute("Phase")))
preview.advance(0.5)
local brp = RM.GetRunPlayer(ben)
protect(brp)
check("Ben's first run: step 3", count(ben, "3:Started First Run") == 1, list(ben))
check("wave 1 begins", waitFor(function()
	return (state:GetAttribute("Wave") or 0) >= 1
end, 20))
local cleared = waitFor(function()
	for _, e in ipairs(ES.Active) do
		if e.Alive and e.WaveId == 1 then
			ES.Kill(e, brp)
		end
	end
	if brp.Offer then
		LU.Cancel(brp)
	end
	return count(ben, "First Wave Completed") > 0
end, 20)
check("cleared wave 1 of the first run: First Wave Completed once", cleared and count(ben, "First Wave Completed") == 1, list(ben))
local wid = brp.WeaponOrder[1]
local evo = WeaponData.Weapons[wid].Evolution
brp.Weapons[wid].Level = WeaponData.MaxLevel
brp.Passives[evo.Passive] = PassiveData.MaxLevelOf(evo.Passive)
if not table.find(brp.PassiveOrder, evo.Passive) then
	table.insert(brp.PassiveOrder, evo.Passive)
end
LU.OpenChest(brp)
preview.advance(0.5)
check("chest evolution", brp.Weapons[wid].Evolved == true)
check("first evolution: First Evolution once", count(ben, "First Evolution") == 1, list(ben))
Analytics.OnEvolution(ben)
check("a later evolution: nothing more (Discovered.Evolutions has one)", count(ben, "First Evolution") == 1, list(ben))
RM.AbandonRun(brp)
preview.advance(12)

-- run 3: Solo, my second run: Started Second Run, no second step 3, a card evolution
check("run 3 starts", RM.StartTeamRun({ me }, "Solo", "Forest", me))
preview.advance(0.5)
local mrp = RM.GetRunPlayer(me)
protect(mrp)
check("second run: Started Second Run, no new step 3", count(me, "Started Second Run") == 1 and count(me, "3:Started First Run") == 1, list(me))
local mw = mrp.WeaponOrder[1]
local mevo = WeaponData.Weapons[mw].Evolution
mrp.Weapons[mw].Level = WeaponData.MaxLevel
mrp.Passives[mevo.Passive] = PassiveData.MaxLevelOf(mevo.Passive)
if not table.find(mrp.PassiveOrder, mevo.Passive) then
	table.insert(mrp.PassiveOrder, mevo.Passive)
end
local picked = false
for _ = 1, 8 do
	LU.QueueLevels(mrp, 1)
	preview.advance(2)
	if type(mrp.Offer) == "table" then
		for i, card in ipairs(mrp.Offer) do
			if card.Type == "Evolve" then
				preview.remote("LevelUpChoose"):FireServer(i, mrp.OfferSeq)
				picked = true
				break
			end
		end
		if not picked then
			LU.Cancel(mrp)
		end
	end
	if picked then
		break
	end
end
preview.advance(1)
check("an Evolve card offered and picked", picked and mrp.Weapons[mw].Evolved == true)
check("card evolution: First Evolution once", count(me, "First Evolution") == 1, list(me))
check("veteran: still nothing", list(ava) == "", list(ava))
if studio then
	check("Studio: nothing reached AnalyticsService", #A.calls == 0, tostring(#A.calls))
end
preview.log("ME   " .. list(me))
preview.log("BEN  " .. list(ben))
preview.log(string.format("analytics-regression: %s", fails == 0 and "PASS all" or ("FAIL " .. fails)))
