-- run-entry-regression (SwarmV2 redesign, docs/redesign/gameplay/DESIGN.md section 7):
--   A  ArrivalBarrier (pure): group start when all are in, start after the group wait with
--      someone missing, late join inside the grace, reject after it, reject a stranger /
--      another match, duplicate arrivals, start fires exactly once
--   B  RunEntry "local" role with the DEV admission provider: BeginLocalMatch starts the
--      run on this server with the ticket's class (not the save's), a player not on the
--      ticket is refused, a second call while running does nothing
--   C  the return hook runs once per player after the run ends (rewards already committed)
-- Lune sim, NOT Studio. Prints PASS/FAIL lines; any FAIL fails tools/run_regressions.py.
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local results = {}
local function check(name: string, ok: boolean, detail: string?)
	table.insert(results, { name, ok })
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail and (": " .. detail) or ""))
end

------------------------------------------------------------------------------------------
-- A. ArrivalBarrier
------------------------------------------------------------------------------------------
preview.startServer()
preview.advance(1)
local Run = ServerScriptService:WaitForChild("SwarmV2"):WaitForChild("Run")
local ArrivalBarrier = require(Run:WaitForChild("ArrivalBarrier"))

do
	local b = ArrivalBarrier.new(20, 60)
	check("A1 first arrival waits", b:Arrive("m1", 1, { 1, 2 }, 0) == "wait")
	check("A2 no start with one of two", not b:ShouldStart(5))
	check("A3 stranger rejected", b:Arrive("m1", 9, { 1, 2, 9 }, 6) == "reject")
	check("A4 other match rejected", b:Arrive("m2", 2, { 1, 2 }, 6) == "reject")
	check("A5 second arrival waits", b:Arrive("m1", 2, { 1, 2 }, 7) == "wait")
	check("A6 starts once all are in", b:ShouldStart(7))
	check("A7 start fires exactly once", not b:ShouldStart(8))
	check("A8 duplicate arrival", b:Arrive("m1", 2, { 1, 2 }, 9) == "duplicate")
end
do
	local b = ArrivalBarrier.new(20, 60)
	b:Arrive("m1", 1, { 1, 2, 3 }, 100)
	check("A9 waits before the group timeout", not b:ShouldStart(119))
	check("A10 starts at the group timeout", b:ShouldStart(120))
	check("A11 late join inside the grace", b:Arrive("m1", 2, { 1, 2, 3 }, 170) == "late")
	check("A12 rejected after the grace", b:Arrive("m1", 3, { 1, 2, 3 }, 181) == "reject")
	check("A13 grace over", b:GraceOver(181))
end

------------------------------------------------------------------------------------------
-- B. RunEntry local role with DevAdmission
------------------------------------------------------------------------------------------
local okClient = pcall(preview.startClient)
preview.advance(2)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local DevAdmission = require(Run:WaitForChild("DevAdmission"))
local RunEntry = require(Run:WaitForChild("RunEntry"))

local ctx = {
	RunManager = RM,
	DataService = preview.server("DataService"),
}
local returned = 0
DevAdmission.Setup("local", "match-local-1", { [me.UserId] = "Mage" })
RunEntry.Init(ctx, DevAdmission)
local hookWrapped = RM.OnReturnHome
RM.OnReturnHome = function(p, how)
	returned += 1
	if hookWrapped then
		hookWrapped(p, how)
	end
end
check("B0 client started", okClient)
check("B1 role is local", RunEntry.Role() == "local")

local refused = RunEntry.BeginLocalMatch("other-match", { me })
check("B2 wrong match id refused", refused == false and not RM.IsRunning())

local started = RunEntry.BeginLocalMatch("match-local-1", { me })
preview.advance(1)
local rp = RM.GetRunPlayer(me)
check("B3 run started", started == true and RM.IsRunning())
check("B4 admitted class used", rp ~= nil and rp.CharacterId == "Mage", rp and rp.CharacterId or "no run player")
check("B5 context kept", RunEntry.Context(me) ~= nil and (RunEntry.Context(me) :: any).classId == "Mage")
check("B6 second start ignored", RunEntry.BeginLocalMatch("match-local-1", { me }) == false)

------------------------------------------------------------------------------------------
-- C. Return after the run
------------------------------------------------------------------------------------------
RM.EndRun(false)
preview.advance(2)
pcall(function()
	for _ = 1, 10 do
		if returned > 0 then
			break
		end
		RM.EndRun(false)
		preview.advance(3)
	end
end)
-- the results screen sends the player home through the ReturnToLobby remote
local rpAfter = RM.GetRunPlayer(me)
if returned == 0 and rpAfter then
	pcall(function()
		preview.fireServerAs(me, "ReturnToLobby", "menu")
	end)
	preview.advance(2)
end
check("C1 return hook ran once", returned == 1, "calls " .. returned)

local failed = 0
for _, r in ipairs(results) do
	if not r[2] then
		failed += 1
	end
end
preview.log(string.format("run-entry-regression: %d/%d passed", #results - failed, #results))
