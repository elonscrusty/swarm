-- portal-reveal-sim: the stage-1 portal reveal against the REAL server with the first-run
-- flow on (Config.FirstRun.AutoStart, as live; other scenes keep it off). Checks that:
--   1. a brand-new save's Solo run (the tutorial run) keeps the portal hidden (PortalHint
--      false, no charging in its ring) until the first level-up card is picked, then
--      reveals it ~Config.FirstRun.RevealAfterPickSeconds later with ONE portal message
--      (no "Find the portal" notice at the run start);
--   2. a returning save (TutorialDone) reveals at Config.Stages.RevealDelaySeconds;
--   3. Settings > Replay tips (TutorialDone false again) with no level-up waits at most
--      Config.FirstRun.RevealCapSeconds;
--   4. co-op with a brand-new teammate reveals at the usual moment.
-- Prints PASS / FAIL lines. Headless:
--   lune run tools/preview/runtime/main.luau -- --scene portal-reveal-sim --studio --device pc --out <json> --set headless=on
preview.args.firstrun = "on"
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local Config = preview.shared("Config")
Config.FirstRun.AutoStart = true
preview.shared("Config").Features.Walkthrough = false -- this scene checks the flow without the interactive walkthrough (walkthrough-regression covers it)
local st = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState") :: any
local RM = preview.server("RunManager")
local Data = preview.server("DataService")
local failures = 0
local function check(name: string, good: boolean, detail: string?)
	if not good then
		failures += 1
	end
	preview.log((good and "PASS " or "FAIL ") .. name .. (detail and (" (" .. detail .. ")") or ""))
end
local notices: { string } = {}
preview.remote("Notify").OnClientEvent:Connect(function(d)
	if type(d) == "table" and type(d.Text) == "string" then
		table.insert(notices, d.Text)
	end
end)
local function count(find: string): number
	local n = 0
	for _, t in ipairs(notices) do
		if string.find(string.lower(t), string.lower(find), 1, true) then
			n += 1
		end
	end
	return n
end
local function hint(): boolean
	return st:GetAttribute("PortalHint") == true
end
local function startSolo(): any
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(0.2)
	local rp = RM.GetRunPlayer(me)
	if rp then
		rp.InvulnUntil = math.huge
	end
	return rp
end
local c = Config.ArenaOrigin
local angle = 0
local function walk(rp)
	if rp and rp.Root then
		angle += 0.1 * 5 / 24
		local pos = Vector3.new(c.X + math.cos(angle) * 24, rp.Root.Position.Y, c.Z + math.sin(angle) * 24)
		local dir = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		rp.MoveDir, rp.Facing = dir, dir
		rp.Root.CFrame = CFrame.lookAt(pos, pos + dir)
		rp.LastValidPos = rp.Root.Position
		rp.SpeedCheckTimer = 0
	end
end
local function standAt(rp, pos: Vector3)
	rp.MoveDir = Vector3.zero
	rp.Root.CFrame = CFrame.new(Vector3.new(pos.X, rp.Root.Position.Y, pos.Z))
	rp.Root.AssemblyLinearVelocity = Vector3.zero
	rp.LastValidPos = rp.Root.Position
	rp.SpeedCheckTimer = 0
end
-- run seconds until the reveal (nil = not within `limit`)
local function timeToReveal(rp, limit: number): number?
	local t0 = RM.GetRunTime()
	for _ = 1, math.floor(limit / 0.1) do
		walk(rp)
		preview.advance(0.1)
		if hint() then
			return RM.GetRunTime() - t0
		end
	end
	return nil
end

-- 1. the tutorial run
local data = Data.GetData(me)
check("new save: tutorial not done", data ~= nil and data.TutorialDone ~= true, tostring(data and data.TutorialDone))
table.clear(notices)
local rp = startSolo()
check("solo run started", rp ~= nil and st:GetAttribute("StagePhase") == "Explore", tostring(st:GetAttribute("StagePhase")))
check("tutorial run holds the reveal", RM.TutorialRevealHold() == true)
preview.log(string.format("welcome=%s XPNeeded=%s", tostring(rp and rp.FirstRun), tostring(rp and rp.XPNeeded)))
local firstAt = nil
local portalPos = st:GetAttribute("PortalPos")
local blockedCharge = nil
for _ = 1, 450 do
	walk(rp)
	preview.advance(0.1)
	-- at ~6 s, stand in the hidden portal's ring for a second: it must not charge
	if blockedCharge == nil and RM.GetRunTime() >= 6 and rp.Root and typeof(portalPos) == "Vector3" and not rp.Offer then
		standAt(rp, portalPos)
		preview.advance(1)
		blockedCharge = tonumber(st:GetAttribute("PortalCharge")) or 0
		walk(rp)
	end
	if rp and rp.Offer then
		firstAt = RM.GetRunTime()
		break
	end
	if hint() then
		break
	end
end
preview.log(string.format("tutorial run: first offer at %s s, reveal before it = %s", tostring(firstAt), tostring(hint())))
check("no reveal before the first pick", firstAt ~= nil and not hint(), "offer at " .. tostring(firstAt))
check("hidden portal does not charge", blockedCharge == 0, tostring(blockedCharge))
check("no run-start portal notice", count("find the portal") == 0 and count("summon the") == 0, table.concat(notices, " | "))
check("no reveal notice yet", count("portal has appeared") == 0)
preview.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
preview.advance(0.3)
check("pick resolved", rp.Offer == nil and RM.TutorialRevealHold() == false, "pending=" .. tostring(rp.PendingLevels))
check("reveal waits a moment after the pick", not hint())
local after = timeToReveal(rp, 3)
check("reveal right after the pick", after ~= nil and after <= Config.FirstRun.RevealAfterPickSeconds + 0.5, tostring(after))
check("one reveal message", count("portal has appeared") == 1, table.concat(notices, " | "))
-- now the ring charges
standAt(rp, portalPos)
preview.advance(0.5)
check("revealed portal charges", (tonumber(st:GetAttribute("PortalCharge")) or 0) > 0, tostring(st:GetAttribute("PortalCharge")))
preview.remote("AbandonRun"):FireServer()
preview.advance(2)
check("tutorial done after the first run", data.TutorialDone == true)

-- 2. a returning save: the usual reveal
preview.advance(1.5)
table.clear(notices)
rp = startSolo()
check("returning run does not hold", RM.TutorialRevealHold() == false)
local t2 = timeToReveal(rp, 10)
check("returning reveal at the usual delay", t2 ~= nil and math.abs(t2 - Config.Stages.RevealDelaySeconds) <= 0.6, tostring(t2))
check("returning run: one portal message, no objective notice", count("portal has appeared") == 1 and count("find the portal") == 0, table.concat(notices, " | "))
preview.remote("AbandonRun"):FireServer()
preview.advance(2)

-- 3. Replay tips, no level-up in reach: the cap
preview.advance(1.5)
preview.remote("Tutorial"):FireServer("Replay")
preview.advance(0.3)
check("replay clears TutorialDone", data.TutorialDone == false)
rp = startSolo()
rp.XPNeeded = 1e9
me:SetAttribute("XPNeeded", rp.XPNeeded)
local t3 = timeToReveal(rp, 60)
check("replay run reveal at the cap", t3 ~= nil and math.abs(t3 - Config.FirstRun.RevealCapSeconds) <= 1, tostring(t3))
preview.remote("AbandonRun"):FireServer()
preview.advance(2)

-- 4. co-op with a brand-new teammate: normal reveal
preview.advance(1.5)
local avaData = Data.GetData(ava)
check("teammate is brand new", avaData ~= nil and avaData.TutorialDone ~= true)
data.TutorialDone = false
assert(RM.StartTeamRun({ me, ava }, "Duo", "Forest", me))
preview.advance(0.2)
rp = RM.GetRunPlayer(me)
local arp = RM.GetRunPlayer(ava)
if rp then
	rp.InvulnUntil = math.huge
end
if arp then
	arp.InvulnUntil = math.huge
end
check("co-op does not hold", RM.TutorialRevealHold() == false)
local t4 = timeToReveal(rp, 10)
check("co-op reveal at the usual delay", t4 ~= nil and math.abs(t4 - Config.Stages.RevealDelaySeconds) <= 0.6, tostring(t4))
preview.log(failures == 0 and "PASS portal-reveal-sim: all checks" or ("FAIL portal-reveal-sim: " .. failures .. " checks failed"))
