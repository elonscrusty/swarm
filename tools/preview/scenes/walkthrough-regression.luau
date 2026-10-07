-- walkthrough-regression: the interactive first-run walkthrough (server Walkthrough.lua,
-- Config.Features.Walkthrough / Config.Walkthrough, docs/next/WALKTHROUGH.md) against the
-- REAL server with the first-run flow on (Config.FirstRun.AutoStart, as live). Checks:
--   1. a brand-new save's Solo run walks Move -> Fight -> Gems -> Upgrade -> Chest -> Go in
--      order, each step waiting for its action (ring reached by teleport, the 5 enemies
--      killed, gems collected into the first level-up, a card picked, the free chest held
--      open); normal waves and the portal reveal are held until Go, then released;
--   2. the free chest pays exactly once (a second hold does nothing) and costs no gold;
--   3. the same save's next run never runs it again (save WalkthroughDone);
--   4. Settings > Replay tips runs it again; doing nothing, every step times out in order
--      and the walkthrough still ends with the holds released; the pause menu stops its
--      clock;
--   5. leaving mid-walkthrough (MAIN MENU) ends it cleanly (no hold left behind);
--   6. co-op with a brand-new teammate never runs it.
-- Prints PASS / FAIL lines. Headless:
--   lune run tools/preview/runtime/main.luau -- --scene walkthrough-regression --studio --device pc --out <json> --set headless=on
preview.args.firstrun = "on"
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local Config = preview.shared("Config")
Config.FirstRun.AutoStart = true
local WC = Config.Walkthrough
local st = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState") :: any
local RM = preview.server("RunManager")
local Data = preview.server("DataService")
local W = preview.server("Walkthrough")
local Spawner = preview.server("EnemySpawner")
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
local function hint(): boolean
	return st:GetAttribute("PortalHint") == true
end
local function wave(): number
	return tonumber(st:GetAttribute("Wave")) or 0
end
local function step(): string?
	return (W.Current())
end
local function startSolo(): any
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(0.2)
	local rp = RM.GetRunPlayer(me)
	if rp then
		rp.InvulnUntil = math.huge
	end
	local d = Data.GetData(me)
	preview.log(string.format("startSolo: phase=%s rp=%s runs=%s done=%s replay=%s tdone=%s", tostring(st:GetAttribute("Phase")), tostring(rp ~= nil), tostring(d and d.Stats.Runs), tostring(d and d.WalkthroughDone), tostring(d and d.WalkthroughReplay), tostring(d and d.TutorialDone)))
	return rp
end
local function standAt(rp, pos: Vector3)
	rp.MoveDir = Vector3.zero
	rp.Root.CFrame = CFrame.new(Vector3.new(pos.X, rp.Root.Position.Y, pos.Z))
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
end

-- 1. the first run
local data = Data.GetData(me)
check("new save: no runs, walkthrough not done", data ~= nil and data.Stats.Runs == 0 and data.WalkthroughDone == false)
local rp = startSolo()
check("solo run started", rp ~= nil and st:GetAttribute("StagePhase") == "Explore", tostring(st:GetAttribute("StagePhase")))
check("1 Move first", step() == "Move" and me:GetAttribute("Walkthrough") == "Move", tostring(step()))
check("marked done at its start", data.WalkthroughDone == true)
local ring = me:GetAttribute("WalkTarget")
check("ring target replicated", typeof(ring) == "Vector3")
local start = rp.Root.Position
local ringD = typeof(ring) == "Vector3" and flatDist(ring, start) or -1
check("ring ~RingDistance from the hero", ringD >= 5 and ringD <= WC.RingDistance + 1, string.format("%.1f", ringD))
check("ring in open ground", typeof(ring) == "Vector3" and not preview.server("EnemyAI").IsBlocked(ring.X, ring.Z, 2))
check("waves held", held())
preview.advance(Config.Waves.FirstDelay + 4)
check("Move waits for the ring", step() == "Move")
check("no wave while held", wave() == 0 and #Spawner.Active == 0, "wave=" .. wave() .. " active=" .. #Spawner.Active)
check("no portal reveal while held", not hint())
standAt(rp, ring)
preview.advance(0.3)
check("2 Fight after standing in the ring", step() == "Fight", tostring(step()))
local _, _, live = W.Current()
local foes = live and live.Foes or {}
check("EnemyCount enemies spawned", #foes == WC.EnemyCount and me:GetAttribute("WalkTotal") == WC.EnemyCount, "#" .. #foes)
local okDist, okWeak = true, true
for _, f in ipairs(foes) do
	local d = flatDist(f.E.Pos, rp.Root.Position)
	if d > WC.EnemyDistance + 2 or d < 5 then
		okDist = false
	end
	if f.E.MaxHP > WC.EnemyHP + 0.01 or f.E.Type ~= WC.EnemyType then
		okWeak = false
	end
end
check("enemies ~EnemyDistance away", okDist)
check("enemies weak", okWeak)
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
check("3 Gems after all are beaten", step() == "Gems" or step() == "Upgrade", tostring(step()))
check("still held during Gems", held() and wave() == 0)
-- collect: stand on each gem in turn (the gems fly in from the pickup radius)
local gemsFolder = workspace:FindFirstChild("SwarmGems")
local offered = false
for _ = 1, 80 do
	if rp.Offer then
		offered = true
		break
	end
	local target = nil
	if gemsFolder then
		for _, g in ipairs(gemsFolder:GetChildren()) do
			if g:GetAttribute("Active") == true and typeof(g:GetAttribute("Base")) == "Vector3" then
				target = g:GetAttribute("Base")
				break
			end
		end
	end
	if target then
		standAt(rp, target)
	end
	preview.advance(0.1)
end
check("5 kills + gems (and top-up) reach the first level", offered, "level=" .. rp.Level .. " xp=" .. tostring(rp.XP) .. "/" .. tostring(rp.XPNeeded) .. " topup=" .. tostring(live and live.TopUp))
preview.advance(0.1)
check("4 Upgrade while the cards are open", step() == "Upgrade", tostring(step()))
check("no reveal before the pick", not hint())
preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
preview.advance(0.3)
for _ = 1, 10 do -- a merged panel may have more rounds
	if not rp.Offer then
		break
	end
	preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
	preview.advance(0.3)
end
check("5 Chest after the pick", step() == "Chest", tostring(step()))
_, _, live = W.Current()
local chest = live and live.Chest
check("free chest placed", chest ~= nil and chest.State == "Ready" and chest.Price == 0 and chest.Kind == "Chest")
if chest then
	local cd = flatDist(chest.Pos, rp.Root.Position)
	check("chest ~ChestDistance away", cd >= 4 and cd <= WC.ChestDistance + 1, string.format("%.1f", cd))
	check("chest target replicated", typeof(me:GetAttribute("WalkTarget")) == "Vector3" and flatDist(me:GetAttribute("WalkTarget"), chest.Pos) < 0.5)
	check("still held during Chest", held() and not hint())
	local Gold = preview.server("GoldSystem")
	local gold0 = Gold.RunWallet(rp)
	local opened0 = rp.ChestsOpened or 0
	standAt(rp, chest.Pos + Vector3.new(2, 0, 0))
	preview.advance(0.2)
	preview.remote("LootHold"):FireServer(chest.Id, true)
	preview.advance((chest.Model:GetAttribute("Hold") or 1) + 0.6)
	check("chest opened by the hold", chest.State == "Opened" and (rp.ChestsOpened or 0) == opened0 + 1, tostring(chest.State))
	check("free: no gold taken", Gold.RunWallet(rp) >= gold0, gold0 .. " -> " .. Gold.RunWallet(rp))
	preview.remote("RewardClose"):FireServer(rp.RewardSeq)
	preview.advance(0.3)
	preview.remote("LootHold"):FireServer(chest.Id, true)
	preview.advance((chest.Model:GetAttribute("Hold") or 1) + 0.6)
	check("exactly once: a second hold pays nothing", (rp.ChestsOpened or 0) == opened0 + 1)
end
check("6 Go after the chest", step() == "Go", tostring(step()))
check("waves released at Go", not held())
local revealAt, waveAt = nil, nil
for i = 1, 150 do
	preview.advance(0.1)
	if not revealAt and hint() then
		revealAt = i * 0.1
	end
	if not waveAt and wave() >= 1 then
		waveAt = i * 0.1
	end
	if revealAt and waveAt and step() == nil then
		break
	end
end
check("portal reveal follows Go", revealAt ~= nil and revealAt <= (Config.FirstRun.RevealAfterPickSeconds or 1) + 2, tostring(revealAt))
check("first wave within ReleaseWaveDelay", waveAt ~= nil and waveAt <= WC.ReleaseWaveDelay + 1.5, tostring(waveAt))
check("walkthrough ends after Go", step() == nil and me:GetAttribute("Walkthrough") == nil and me:GetAttribute("WalkTarget") == nil)
local _, log = W.Current()
local order = {}
for _, e in ipairs(log) do
	table.insert(order, e.Step .. ":" .. tostring(e.How))
end
local orderText = table.concat(order, " ")
check("steps in order, all by action", orderText == "Move:done Fight:done Gems:done Upgrade:done Chest:done Go:done End:done", orderText)
leave()

-- 3. the next run: never again
rp = startSolo()
check("second run: no walkthrough", step() == nil and me:GetAttribute("Walkthrough") == nil and not held())
leave()

-- 4. Replay tips: again; doing nothing, every step times out
preview.remote("Tutorial"):FireServer("Replay")
preview.advance(0.3)
check("Replay asks for it again", data.WalkthroughReplay == true)
rp = startSolo()
check("replay run: Move", step() == "Move" and data.WalkthroughReplay == false)
-- the pause menu freezes the step clock
preview.remote("SetPause"):FireServer(true)
preview.advance(WC.Timeouts.Move + 5)
check("pause freezes the walkthrough", step() == "Move", tostring(step()))
preview.remote("SetPause"):FireServer(false)
preview.advance(0.2)
local limit = 0
for _, s in pairs(WC.Timeouts) do
	limit += s
end
limit += WC.GoSeconds + 60
local spawnPos = rp.Root.Position
local t = 0
while t < limit and step() ~= nil do
	-- stand still at the spawn (never in the ring); pick cards so panels don't wait
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
_, log = W.Current()
order = {}
for _, e in ipairs(log) do
	table.insert(order, e.Step .. ":" .. tostring(e.How))
end
orderText = table.concat(order, " ")
check("timeouts: the walkthrough still ends", step() == nil and not held(), string.format("%.0f s, %s", t, orderText))
check("timeouts: Move timed out first", order[1] == "Move:timeout", orderText)
local seq = {}
for _, e in ipairs(log) do
	table.insert(seq, e.Step)
end
check("timeouts: steps in order", table.concat(seq, ",") == "Move,Fight,Gems,Upgrade,Chest,Go,End", table.concat(seq, ","))
check("timeouts: Chest timed out, chest still openable", string.find(orderText, "Chest:timeout", 1, true) ~= nil)
leave()

-- 5. leaving mid-walkthrough ends it cleanly
preview.remote("Tutorial"):FireServer("Replay")
preview.advance(0.3)
rp = startSolo()
check("leave test: started", step() == "Move" and held())
leave()
check("leaving ends it, no hold left", step() == nil and not held() and me:GetAttribute("Walkthrough") == nil)

-- 6. co-op with a brand-new teammate: never
local avaData = Data.GetData(ava)
check("teammate is brand new", avaData ~= nil and avaData.Stats.Runs == 0 and avaData.WalkthroughDone == false)
assert(RM.StartTeamRun({ ava, me }, "Duo", "Forest", ava))
preview.advance(0.3)
check("co-op: no walkthrough", step() == nil and not held() and ava:GetAttribute("Walkthrough") == nil and avaData.WalkthroughDone == false)
preview.log(failures == 0 and "PASS walkthrough-regression: all checks" or ("FAIL walkthrough-regression: " .. failures .. " checks failed"))
