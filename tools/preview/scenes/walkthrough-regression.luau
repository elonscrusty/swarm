-- walkthrough-regression: the interactive first-run walkthrough (server Walkthrough.lua,
-- Config.Features.Walkthrough / Config.Walkthrough, docs/next/WALKTHROUGH.md) against the
-- REAL server with the first-run flow on (Config.FirstRun.AutoStart, as live), on the live run:
-- a Cliffwood beacon run (StageManager's director, a real height grid from lib/mapray).
-- Checks:
--   1. a brand-new save's Solo run walks Move -> Dash -> Fight -> Gems -> Upgrade -> Chest ->
--      Beacon in order, each step waiting for its action (ring reached by teleport, a dash
--      through the real dash remote, the 5 weak beetles killed, shards collected into the
--      first level choice, a card picked, the free gift chest held open); the director's
--      spawns are held only for the short opening (Move / Dash) and released when Fight starts;
--   2. the free chest pays exactly once (a second hold does nothing) and costs no team gold;
--   3. the same save's next run never runs it again (save WalkthroughDone);
--   4. Settings > Replay tips runs it again; doing nothing, the director's opening hold still
--      ends after OpeningHold seconds of run time (the walkthrough never blocks the director
--      beyond it), every step times out in order and the walkthrough ends; the pause menu
--      stops its clock; the replay's chest is a normal team chest (not free);
--   5. leaving mid-walkthrough (MAIN MENU) ends it cleanly (no hold left behind);
--   6. co-op with a brand-new teammate never runs it;
--   7. the client lines (WalkthroughClient.LineFor) name the controls per device (WASD / Space /
--      Shift / right-drag, the stick / JUMP / DASH / swipe, the sticks / A / B), talk about XP
--      shards, team gold and the beacon on a beacon run, never about a portal or stages;
--   8. the old stage loop (Forest) keeps its original steps (Move first, no WalkMode).
-- Prints PASS / FAIL lines. Headless:
--   lune run tools/preview/runtime/main.luau -- --scene walkthrough-regression --studio --device pc --out <json> --set headless=on
preview.args.firstrun = "on"
local MapRay = lib("mapray")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local Config = preview.shared("Config")
Config.FirstRun.AutoStart = true
local WC = Config.Walkthrough
local st = ReplicatedStorage:FindFirstChild("SwarmState") :: any
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local Data = preview.server("DataService")
local W = preview.server("Walkthrough")
local Spawner = preview.server("EnemySpawner")
local Gold = preview.server("GoldSystem")
local MapBuilder = preview.server("MapBuilder")
MapRay.install(function()
	return MapBuilder.GetArena()
end)
local dashRemote = ReplicatedStorage:WaitForChild("SwarmV2Net"):WaitForChild("Run"):WaitForChild("Dash")
local failures = 0
local function check(name: string, good: boolean, detail: string?)
	if not good then
		failures += 1
	end
	preview.log((good and "PASS " or "FAIL ") .. name .. (detail and (" (" .. detail .. ")") or ""))
end
check("Walkthrough switch on by default", Config.Features.Walkthrough == true)

local function held(): boolean
	return Spawner.Holds ~= nil and Spawner.Holds.Walkthrough == true
end
local function directorSpawned(): number
	return Spawner.DirectorStats and Spawner.DirectorStats.Spawned or 0
end
local function step(): string?
	return (W.Current())
end
local function startSolo(arena: string?): any
	local where = arena or "Cliffwood"
	local data = Data.GetData(me)
	if data then
		data.OwnedCharacters.ruckus = true
	end
	RM.SetAdmittedClass(me, "ruckus")
	local ok = RM.StartTeamRun({ me }, "Solo", where, me)
	preview.advance(0.2)
	local rp = ok and RM.GetRunPlayer(me) or nil
	if rp then
		rp.InvulnUntil = math.huge
	end
	return rp
end
local function standAt(rp, pos: Vector3)
	rp.MoveDir = Vector3.zero
	rp.Root.CFrame = CFrame.new(Vector3.new(pos.X, pos.Y + 3, pos.Z))
	rp.Root.AssemblyLinearVelocity = Vector3.zero
	rp.LastValidPos = rp.Root.Position
	rp.SpeedCheckTimer = 0
end
local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
local function leave()
	preview.remote("AbandonRun"):FireServer()
	preview.advance(2)
	preview.advance(1.5)
	for _ = 1, 20 do
		if st:GetAttribute("Phase") == "Lobby" then
			break
		end
		pcall(function()
			preview.remote("ReturnToLobby"):FireServer("menu")
		end)
		preview.advance(0.5)
	end
end
local function logOrder(): (string, { string })
	local _, log = W.Current()
	local order, seq = {}, {}
	for _, e in ipairs(log) do
		table.insert(order, e.Step .. ":" .. tostring(e.How))
		table.insert(seq, e.Step)
	end
	return table.concat(order, " "), seq
end

------------------------------------------------------------------------------------------
-- 1. the first run (a Cliffwood beacon run)
------------------------------------------------------------------------------------------
local data = Data.GetData(me)
check("new save: no runs, walkthrough not done", data ~= nil and data.Stats.Runs == 0 and data.WalkthroughDone == false)
local rp = startSolo()
check("solo beacon run started", rp ~= nil and SM.IsDirector() and st:GetAttribute("RunStage") == "Survive", tostring(st:GetAttribute("RunStage")))
check("1 Move first, beacon mode", step() == "Move" and me:GetAttribute("Walkthrough") == "Move" and me:GetAttribute("WalkMode") == "Beacon", tostring(step()))
check("marked done at its start", data.WalkthroughDone == true)
local ring = me:GetAttribute("WalkTarget")
check("ring target replicated", typeof(ring) == "Vector3")
local start = rp.Root.Position
local ringD = typeof(ring) == "Vector3" and flatDist(ring, start) or -1
check("ring ~RingDistance from the hero", ringD >= 5 and ringD <= WC.RingDistance + 1, string.format("%.1f", ringD))
local HG = preview.server("HeightGrid")
check("ring on walkable ground, open, on the ground", typeof(ring) == "Vector3" and HG.IsWalkable(ring.X, ring.Z) and not preview.server("EnemyAI").IsBlocked(ring.X, ring.Z, 2)
	and math.abs(ring.Y - HG.GroundY(ring.X, ring.Z)) < 0.5)
check("director held at the start (opening hold)", held() and directorSpawned() == 0)
preview.advance(3)
check("Move waits for the ring", step() == "Move")
check("no director spawn during the opening hold", directorSpawned() == 0 and Spawner.OrdinaryAlive() == 0, "spawned " .. directorSpawned())
standAt(rp, ring)
preview.advance(0.3)
check("2 Dash after standing in the ring", step() == "Dash", tostring(step()))
check("Dash has no world target", me:GetAttribute("WalkTarget") == nil)
-- a real dash request (the server validates it and sets rp.DashUntil)
preview.advance(0.5)
dashRemote:FireServer(Vector3.new(1, 0, 0))
preview.advance(0.3)
check("3 Fight after a validated dash", step() == "Fight", tostring(step()))
check("the opening hold ends when Fight starts", not held())
local _, _, live = W.Current()
local foes = live and live.Foes or {}
check("DirectorEnemyCount beetles spawned", #foes == WC.DirectorEnemyCount and me:GetAttribute("WalkTotal") == WC.DirectorEnemyCount, "#" .. #foes)
local okDist, okWeak = true, true
for _, f in ipairs(foes) do
	local d = flatDist(f.E.Pos, rp.Root.Position)
	if d > WC.EnemyDistance + 2 or d < 5 then
		okDist = false
	end
	if f.E.MaxHP > WC.EnemyHP + 0.01 or f.E.Type ~= WC.DirectorEnemyType or f.E.Kind ~= "Normal" then
		okWeak = false
	end
end
check("beetles ~EnemyDistance away", okDist)
check("beetles weak (roster beetle, Normal kind)", okWeak)
for i = 1, 2 do
	local f = foes[i]
	if f and f.E.Alive and f.E.Uid == f.Uid then
		Spawner.Kill(f.E, rp)
	end
end
preview.advance(0.2)
check("counter counts kills", (tonumber(me:GetAttribute("WalkCount")) or 0) >= 2 and step() == "Fight", tostring(me:GetAttribute("WalkCount")))
for _, f in ipairs(foes) do
	if f.E.Alive and f.E.Uid == f.Uid then
		Spawner.Kill(f.E, rp)
	end
end
preview.advance(0.2)
check("4 Gems after all are beaten", step() == "Gems" or step() == "Upgrade", tostring(step()))
-- the director runs on (not held after the opening)
preview.advance(4)
check("the director spawns during the walkthrough", directorSpawned() > 0 and not held(), "spawned " .. directorSpawned())
-- collect: stand on each own shard in turn (shards fly in from the pickup radius)
local gemsFolder = workspace:FindFirstChild("SwarmGems")
local offered = rp.Offer ~= nil
for _ = 1, 120 do
	if rp.Offer then
		offered = true
		break
	end
	local target = nil
	if gemsFolder then
		for _, g in ipairs(gemsFolder:GetChildren()) do
			if g:GetAttribute("Active") == true and g:GetAttribute("Owner") == me.UserId and typeof(g:GetAttribute("Base")) == "Vector3" then
				target = g:GetAttribute("Base")
				break
			end
		end
	end
	if target then
		standAt(rp, Vector3.new(target.X, HG.GroundY(target.X, target.Z), target.Z))
	end
	preview.advance(0.1)
end
check("5 kills + shards (and top-up) reach the first level choice", offered, "level=" .. rp.Level .. " xp=" .. tostring(rp.XP) .. "/" .. tostring(rp.XPNeeded) .. " topup=" .. tostring(live and live.TopUp))
preview.advance(0.1)
check("5 Upgrade while the cards are open", step() == "Upgrade", tostring(step()))
for _ = 1, 10 do
	if not rp.Offer then
		break
	end
	preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
	preview.advance(0.3)
end
check("6 Chest after the pick", step() == "Chest", tostring(step()))
check("WalkFree set for the gift chest", me:GetAttribute("WalkFree") == true)
_, _, live = W.Current()
local chest = live and live.Chest
check("free chest placed", chest ~= nil and chest.State == "Ready" and chest.Price == 0 and chest.Kind == "Chest" and not chest.TeamChest)
if chest then
	local cd = flatDist(chest.Pos, rp.Root.Position)
	check("chest ~ChestDistance away", cd >= 4 and cd <= WC.ChestDistance + 1, string.format("%.1f", cd))
	check("chest on walkable ground", HG.IsWalkable(chest.Pos.X, chest.Pos.Z))
	check("chest target replicated", typeof(me:GetAttribute("WalkTarget")) == "Vector3" and flatDist(me:GetAttribute("WalkTarget"), chest.Pos) < 0.5)
	local team0, bought0 = Gold.TeamGold(), Gold.ChestsBought()
	local opened0 = rp.ChestsOpened or 0
	standAt(rp, chest.Pos + Vector3.new(2, 0, 0))
	preview.advance(0.2)
	preview.remote("LootHold"):FireServer(chest.Id, true)
	preview.advance((chest.Model:GetAttribute("Hold") or 1) + 0.6)
	check("chest opened by the hold", chest.State == "Opened" and (rp.ChestsOpened or 0) == opened0 + 1, tostring(chest.State))
	check("free: no team gold taken, no purchase counted", Gold.TeamGold() >= team0 and Gold.ChestsBought() == bought0, team0 .. " -> " .. Gold.TeamGold())
	preview.remote("RewardClose"):FireServer(rp.RewardSeq)
	preview.advance(0.3)
	-- the chest's reward is a passive choice (stream E2): pick it like a player
	for _ = 1, 5 do
		if not rp.Offer then
			break
		end
		preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
		preview.advance(0.3)
	end
	preview.remote("LootHold"):FireServer(chest.Id, true)
	preview.advance((chest.Model:GetAttribute("Hold") or 1) + 0.6)
	check("exactly once: a second hold pays nothing", (rp.ChestsOpened or 0) == opened0 + 1)
end
check("7 Beacon after the chest", step() == "Beacon", tostring(step()))
for _ = 1, 150 do
	preview.advance(0.1)
	if rp.Offer then
		preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
	end
	if step() == nil then
		break
	end
end
check("walkthrough ends after Beacon", step() == nil and me:GetAttribute("Walkthrough") == nil and me:GetAttribute("WalkTarget") == nil and me:GetAttribute("WalkMode") == nil)
check("no hold left", not held())
check("the beacon is not revealed early (it waits for 12:30)", st:GetAttribute("RunStage") == "Survive" and st:GetAttribute("BeaconPos") == nil)
local orderText = logOrder()
check("steps in order, all by action", orderText == "Move:done Dash:done Fight:done Gems:done Upgrade:done Chest:done Beacon:done End:done", orderText)
leave()

------------------------------------------------------------------------------------------
-- 3. the next run: never again
------------------------------------------------------------------------------------------
rp = startSolo()
check("second run: no walkthrough", rp ~= nil and step() == nil and me:GetAttribute("Walkthrough") == nil and not held())
leave()

------------------------------------------------------------------------------------------
-- 4. Replay tips: again; doing nothing, the opening hold ends on time and every step times out
------------------------------------------------------------------------------------------
preview.remote("Tutorial"):FireServer("Replay")
preview.advance(0.3)
check("Replay asks for it again", data.WalkthroughReplay == true)
rp = startSolo()
check("replay run: Move", rp ~= nil and step() == "Move" and data.WalkthroughReplay == false)
-- the pause menu freezes the step clock and the opening hold's clock
preview.remote("SetPause"):FireServer(true)
preview.advance(WC.Timeouts.Move + 5)
check("pause freezes the walkthrough", step() == "Move" and held(), tostring(step()))
preview.remote("SetPause"):FireServer(false)
preview.advance(0.2)
local spawnPos = rp.Root.Position
spawnPos = Vector3.new(spawnPos.X, HG.GroundY(spawnPos.X, spawnPos.Z), spawnPos.Z)
-- still on Move after OpeningHold seconds of run time: the director is released anyway
local t = 0
while t < (WC.OpeningHold or 10) + 3 do
	standAt(rp, spawnPos)
	preview.advance(0.2)
	t += 0.2
end
check("still on Move, the opening hold already ended (OpeningHold)", step() == "Move" and not held(), tostring(step()))
check("the director spawns while the walkthrough waits", directorSpawned() > 0, "spawned " .. directorSpawned())
local limit = 0
for _, s in pairs(WC.Timeouts) do
	limit += s
end
limit += WC.GoSeconds + 60
local replayChest = nil
while t < limit and step() ~= nil do
	if step() == "Chest" and not replayChest then
		local _, _, cur = W.Current()
		replayChest = cur and cur.Chest
	end
	-- stand still at the spawn (never in the ring, never dash); pick cards so panels don't wait
	if rp.Root then
		standAt(rp, spawnPos)
	end
	if rp.Offer then
		preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
	end
	if rp.RewardUntil then
		preview.remote("RewardClose"):FireServer(rp.RewardSeq)
	end
	preview.advance(0.2)
	t += 0.2
end
local order, seq = logOrder()
check("timeouts: the walkthrough still ends", step() == nil and not held(), string.format("%.0f s, %s", t, order))
local firstTwo = (seq[1] or "") .. "," .. (seq[2] or "")
check("timeouts: Move and Dash timed out first", firstTwo == "Move,Dash" and string.find(order, "Move:timeout", 1, true) == 1 and string.find(order, "Dash:timeout", 1, true) ~= nil, order)
check("timeouts: steps in order", table.concat(seq, ",") == "Move,Dash,Fight,Gems,Upgrade,Chest,Beacon,End", table.concat(seq, ","))
check("timeouts: Chest timed out", string.find(order, "Chest:timeout", 1, true) ~= nil, order)
check("replay chest is a normal team chest (no free chest per replay)", replayChest ~= nil and (replayChest.Price or 0) > 0 and replayChest.TeamChest == true,
	tostring(replayChest and replayChest.Price))
leave()

------------------------------------------------------------------------------------------
-- 5. leaving mid-walkthrough ends it cleanly
------------------------------------------------------------------------------------------
preview.remote("Tutorial"):FireServer("Replay")
preview.advance(0.3)
rp = startSolo()
check("leave test: started", rp ~= nil and step() == "Move" and held())
leave()
check("leaving ends it, no hold left", step() == nil and not held() and me:GetAttribute("Walkthrough") == nil)

------------------------------------------------------------------------------------------
-- 6. co-op with a brand-new teammate: never
------------------------------------------------------------------------------------------
local avaData = Data.GetData(ava)
check("teammate is brand new", avaData ~= nil and avaData.Stats.Runs == 0 and avaData.WalkthroughDone == false)
RM.SetAdmittedClass(ava, "ruckus")
RM.SetAdmittedClass(me, "ruckus")
assert(RM.StartTeamRun({ ava, me }, "Duo", "Cliffwood", ava))
preview.advance(0.3)
check("co-op: no walkthrough", step() == nil and not held() and ava:GetAttribute("Walkthrough") == nil and avaData.WalkthroughDone == false)
for _, p in ipairs({ ava, me }) do
	local r = RM.GetRunPlayer(p)
	if r then
		pcall(RM.AbandonRun, r)
	end
end
preview.advance(3)
leave()

------------------------------------------------------------------------------------------
-- 7. the client lines (WalkthroughClient.LineFor) on a beacon run
------------------------------------------------------------------------------------------
preview.startClient(false)
local okClient, WCl = pcall(preview.client, "WalkthroughClient")
check("client module loads", okClient and type(WCl) == "table" and type(WCl.LineFor) == "function", tostring(WCl))
if okClient and type(WCl) == "table" then
	me:SetAttribute("WalkMode", "Beacon")
	me:SetAttribute("WalkFree", true)
	me:SetAttribute("WalkCount", 2)
	me:SetAttribute("WalkTotal", 5)
	local want = {
		Mouse = { Move = { "WASD", "right-drag", "ring" }, Dash = { "Space", "Shift" }, Chest = { "team gold", "Hold E" } },
		Touch = { Move = { "Drag", "swipe", "ring" }, Dash = { "JUMP", "DASH" }, Chest = { "team gold", "Hold the button" } },
		Gamepad = { Move = { "Left stick", "right stick" }, Dash = { "A jumps", "B dashes" }, Chest = { "team gold", "Hold X" } },
	}
	for mode, steps in pairs(want) do
		for s, words in pairs(steps) do
			local line = WCl.LineFor(s, mode)
			local ok = true
			for _, wd in ipairs(words) do
				if not string.find(line, wd, 1, true) then
					ok = false
				end
			end
			check(string.format("line %s / %s names the controls", mode, s), ok, line)
		end
	end
	local all = {}
	for _, s in ipairs({ "Move", "Dash", "Fight", "Gems", "Upgrade", "Chest", "Beacon" }) do
		for _, mode in ipairs({ "Mouse", "Touch", "Gamepad" }) do
			table.insert(all, WCl.LineFor(s, mode))
		end
	end
	local joined = string.lower(table.concat(all, " | "))
	check("beacon-run lines never mention a portal or stages", not string.find(joined, "portal", 1, true) and not string.find(joined, "stage", 1, true) and not string.find(joined, "wave", 1, true))
	check("Fight line: auto attacks and the count", string.find(WCl.LineFor("Fight", "Mouse"), "attacks by itself", 1, true) ~= nil and string.find(WCl.LineFor("Fight", "Mouse"), "2/5", 1, true) ~= nil)
	check("Gems line: XP shards", string.find(WCl.LineFor("Gems", "Mouse"), "XP shards", 1, true) ~= nil)
	check("Beacon line: the beacon at 12:30 and the boss", string.find(WCl.LineFor("Beacon", "Mouse"), "beacon", 1, true) ~= nil and string.find(WCl.LineFor("Beacon", "Mouse"), "12:30", 1, true) ~= nil)
	me:SetAttribute("WalkFree", false)
	check("a replay's chest line: open it when the team gold covers it", string.find(WCl.LineFor("Chest", "Mouse"), "when you have enough", 1, true) ~= nil)
	me:SetAttribute("WalkMode", nil)
	check("old stage loop keeps its portal line", string.find(WCl.LineFor("Go", "Mouse"), "portal", 1, true) ~= nil)
	me:SetAttribute("WalkFree", nil)
	me:SetAttribute("WalkCount", nil)
	me:SetAttribute("WalkTotal", nil)
end

------------------------------------------------------------------------------------------
-- 8. the old stage loop (another arena) keeps the original steps
------------------------------------------------------------------------------------------
preview.remote("Tutorial"):FireServer("Replay")
preview.advance(0.3)
rp = startSolo("Forest")
check("old stage loop: Move first, no beacon mode, waves held", rp ~= nil and not SM.IsDirector() and step() == "Move" and me:GetAttribute("WalkMode") == nil and held(), tostring(step()))
local _, _, oldLive = W.Current()
check("old stage loop: the original step list", oldLive ~= nil and table.concat(oldLive.Steps or {}, ",") == "Move,Fight,Gems,Upgrade,Chest,Go")
leave()
check("old stage loop: leaving ends it, no hold left", step() == nil and not held())

preview.log(failures == 0 and "PASS walkthrough-regression: all checks" or ("FAIL walkthrough-regression: " .. failures .. " checks failed"))
