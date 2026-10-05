-- world-regression (WORLD audit 2026-10-05, docs/audit/WORLD.md): boots the REAL server and
-- checks three world lifecycle rules in one solo run (the hero is invulnerable throughout;
-- this measures rules, not survival):
--   W-03 portal hold   standing just OUTSIDE the portal ring (11 studs, ring 9) must not hold
--                      the waves off; standing INSIDE it charges the boss within ChargeSeconds
--   W-06 caravan       step into the caravan ring, run off and charge the portal: the boss
--                      arriving must NOT save the caravan (no item); it is lost after the
--                      grace. A ring held >= half the hold when the boss comes is still saved
--                      at once (the designed "scattered the raiders"); a ring held less goes on
--                      and is saved by the full hold.
--   W-04/05 sweep      the open portal's sweep: a leftover elite gives gems but no free chest,
--                      a tunnelling Burrower is removed too, pending enemy hazards are cleared;
--                      an elite killed by the hero still drops its chest (control)
-- Prints "FAIL: ..." on any broken rule (tools/run_regressions.py), "RESULT ..." lines.
-- run: lune run tools/preview/runtime/main.luau -- --scene world-regression --studio --device pc
--      --out <file>.json --max-time 600 --set headless=on
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local Config = preview.shared("Config")
Config.Encounters.Types = { "Caravan" } -- one caravan on every stage (caravan-sim does the same)
Config.Encounters.Count = { 1, 1 }
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local ES = preview.server("EnemySpawner")
local CE = preview.server("CaravanEvent")
local XP = preview.server("XPSystem")
local Hazards = preview.server("Hazards")
local state = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState", true)
local fails = 0
local function check(ok: boolean, label: string)
	if ok then
		preview.log("ok   " .. label)
	else
		fails += 1
		preview.log("FAIL: " .. label)
	end
end

local chests = 0
local rawChest = XP.SpawnChest
XP.SpawnChest = function(pos)
	chests += 1
	return rawChest(pos)
end

preview.remote("StartRun"):FireServer("Solo")
preview.advance(1.5)
local rp = RM.GetRunPlayer(me)
assert(rp, "solo run player")

local function guard()
	rp.InvulnUntil = math.huge
	if rp.Offer then
		preview.remote("LevelUpChoose"):FireServer(1)
	end
	if rp.RewardSeq then
		preview.remote("RewardClose"):FireServer(rp.RewardSeq)
	end
end
local function standAt(pos: Vector3)
	local root = rp.Root
	if root then
		root.CFrame = CFrame.new(Vector3.new(pos.X, Config.ArenaOrigin.Y + 3, pos.Z))
		rp.LastValidPos = root.Position
		rp.SpeedCheckTimer = 0
	end
end
local function step(seconds: number, at: Vector3?)
	for _ = 1, math.max(1, math.floor(seconds / 0.1 + 0.5)) do
		guard()
		if at then
			standAt(at)
		end
		preview.advance(0.1)
	end
end
local function clearEnemies()
	for _, e in ipairs(table.clone(ES.Active)) do
		if not e.Boss then
			ES.Despawn(e)
		end
	end
end
local function wave(): number
	return tonumber(state:GetAttribute("Wave")) or 0
end
local function items(): number
	local n = 0
	for _, c in pairs(rp.Items or {}) do
		n += c
	end
	return n
end
-- a point `d` studs from the portal centre, on the arena-centre side
local function nearPortal(d: number): Vector3
	local p = assert(SM.PortalPosition(), "portal")
	local to = (Config.ArenaOrigin - p) * Vector3.new(1, 0, 1)
	local dir = to.Magnitude > 1 and to.Unit or Vector3.new(0, 0, 1)
	return p + dir * d
end
local function nextStage()
	SM.DevNextStage()
	for _ = 1, 80 do
		step(0.5)
		if SM.GetPhase() == "Explore" then
			break
		end
	end
	step(0.5)
end

------------------------------------------------------------------------------------------
-- W-03: the portal hold (stage 1)
------------------------------------------------------------------------------------------
local outside = nearPortal(Config.Stages.PortalRadius + 2)
local w0 = wave()
for _ = 1, 45 do
	step(1, outside)
	clearEnemies() -- the hero idles: no wave left alive, nothing to fight
end
local w1 = wave()
preview.log(string.format("RESULT W-03 outside the ring for 45 s: waves %d -> %d, phase %s", w0, w1, SM.GetPhase()))
check(SM.GetPhase() == "Explore", "W-03 standing outside the ring does not charge the portal")
check(w1 - w0 >= 3, "W-03 waves keep coming next to the portal (got " .. (w1 - w0) .. ", want >= 3)")

------------------------------------------------------------------------------------------
-- W-06a: start the caravan, leave, charge the portal (stage 1)
------------------------------------------------------------------------------------------
local c = CE.Get()
check(c ~= nil, "W-06 a caravan on stage 1")
if c then
	local items0, gold0 = items(), rp.Gold
	step(1, c.Pos + Vector3.new(3, 0, 0))
	check(c.State == "Defending", "W-06 stepping into the ring starts the defence")
	local inside = nearPortal(2)
	local t = 0
	while not SM.IsBossFight() and t < 6 do
		step(0.1, inside)
		t += 0.1
	end
	check(SM.IsBossFight(), string.format("W-03 standing inside the ring summons the boss (%.1f s)", t))
	check(t <= Config.Stages.ChargeSeconds + 1, string.format("W-03 the charge takes about ChargeSeconds (%.1f s)", t))
	step(1, inside)
	preview.log(string.format("RESULT W-06a boss arrived %.0f studs from the caravan: state=%s items +%d gold +%d",
		((c.Pos - SM.PortalPosition()) * Vector3.new(1, 0, 1)).Magnitude, c.State, items() - items0, rp.Gold - gold0))
	check(c.State == "Defending", "W-06 the boss arriving does not save an abandoned caravan (state " .. c.State .. ")")
	check(items() == items0, "W-06 no caravan item without a defence")
	step(Config.Caravan.LeaveGrace + 1, inside)
	preview.log(string.format("RESULT W-06a after the grace: state=%s items +%d", c.State, items() - items0))
	check(c.State == "Lost", "W-06 the abandoned caravan is lost after LeaveGrace (state " .. c.State .. ")")
	check(items() == items0, "W-06 still no caravan item")
end

------------------------------------------------------------------------------------------
-- W-04/05: the open portal's sweep (stage 1 boss, then the surge)
------------------------------------------------------------------------------------------
local boss = ES.Boss
check(boss ~= nil, "a stage boss is up")
if boss then
	step(4) -- past the entrance
	ES.Damage(boss, 1e12, rp)
	for _ = 1, 60 do
		step(0.1)
		if SM.GetPhase() == "Surge" then
			break
		end
	end
	check(SM.GetPhase() == "Surge", "the surge starts after the boss")
	step(Config.Stages.SurgeSpawnSeconds + 0.5)
	local root = rp.Root.Position
	-- control: an elite the hero kills drops its chest
	local before = chests
	local ctl = ES.Spawn("Slime", root + Vector3.new(30, 0, 0), { Elite = true, Force = true })
	if ctl then
		ES.Kill(ctl, rp)
	end
	check(chests == before + 1, "W-04 control: an elite killed by the hero drops a chest")
	-- leftovers for the sweep: an elite, a tunnelling Burrower far away, a pending strike
	local elite = ES.Spawn("Slime", root + Vector3.new(-30, 0, 0), { Elite = true, Force = true })
	local burrower = ES.Spawn("Burrower", root + Vector3.new(0, 0, 70), { Force = true })
	step(0.3)
	check(burrower ~= nil and burrower.Alive and burrower.Invulnerable == true, "W-05 the Burrower is tunnelling (invulnerable)")
	Hazards.Strike(root + Vector3.new(0, 0, -20), 4, 30, 10)
	local hazardsBefore = Hazards.Count()
	local burrowerUid = burrower and burrower.Uid
	before = chests
	-- the surge itself is beaten: only the leftovers remain, the portal opens
	for _, e in ipairs(table.clone(ES.Active)) do
		if e ~= elite and e ~= burrower then
			ES.Kill(e, rp)
		end
	end
	for _ = 1, 40 do
		step(0.1)
		if SM.GetPhase() == "Open" then
			break
		end
	end
	local burrowerGone = burrower == nil or not burrower.Alive or burrower.Uid ~= burrowerUid
	preview.log(string.format("RESULT W-04/05 sweep: phase=%s chests +%d elite alive=%s burrower gone=%s enemies left=%d hazards %d -> %d",
		SM.GetPhase(), chests - before, tostring(elite ~= nil and elite.Alive), tostring(burrowerGone), #ES.Active, hazardsBefore, Hazards.Count()))
	check(SM.GetPhase() == "Open", "the portal opened")
	check(elite ~= nil and not elite.Alive, "W-04 the sweep removes the leftover elite")
	check(chests == before, "W-04 a swept elite drops no chest (got +" .. (chests - before) .. ")")
	check(burrowerGone, "W-05 the sweep removes a tunnelling Burrower")
	check(#ES.Active == 0, "W-05 nothing is left alive at the open portal (" .. #ES.Active .. ")")
	check(hazardsBefore > 0 and Hazards.Count() == 0, "W-05 pending enemy hazards are cleared")
	step(3)
	check(#ES.Active == 0, "W-05 still nothing alive 3 s into the choice (" .. #ES.Active .. ")")
end

------------------------------------------------------------------------------------------
-- W-06b/c: a held caravan when the boss comes (stages 2 and 3)
------------------------------------------------------------------------------------------
local function heldCase(label: string, holdSeconds: number, wantSavedAtBoss: boolean)
	nextStage()
	local cv = CE.Get()
	check(cv ~= nil, label .. " a caravan on stage " .. SM.GetStage())
	if not cv then
		return
	end
	local ring = cv.Pos + Vector3.new(3, 0, 0)
	local items0 = items()
	step(holdSeconds, ring)
	check(cv.State == "Defending", label .. " defending after " .. holdSeconds .. " s")
	SM.DevActivate() -- the boss comes while the hero holds the ring
	step(0.5, ring)
	preview.log(string.format("RESULT %s held %.0f s, boss arrived: state=%s items +%d", label, holdSeconds, cv.State, items() - items0))
	if wantSavedAtBoss then
		check(cv.State == "Saved", label .. " a ring held past half is saved when the boss comes")
		check(items() == items0 + 1, label .. " one item")
	else
		check(cv.State == "Defending", label .. " a ring held under half goes on")
		local t = 0
		while cv.State == "Defending" and t < Config.Caravan.HoldSeconds + 5 do
			step(0.5, ring)
			t += 0.5
		end
		preview.log(string.format("RESULT %s kept holding %.1f s: state=%s items +%d", label, t, cv.State, items() - items0))
		check(cv.State == "Saved", label .. " the full hold saves it during the boss fight")
		check(items() == items0 + 1, label .. " exactly one item")
	end
end
heldCase("W-06b", Config.Caravan.HoldSeconds * 0.55, true)
heldCase("W-06c", 3, false)

preview.log(fails == 0 and "world-regression: all checks passed" or ("world-regression: " .. fails .. " FAIL"))
