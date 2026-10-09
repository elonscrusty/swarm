-- swarm-v2-flow: the merged SwarmV2 game end to end on one server in the "local" role
-- (Studio-like: PlaceId 0, no transfer). Real server + real client, players' own avatars on.
--   A  basecamp built, the avatar spawns at the bonfire (not the old lobby hero), the standard
--      follow camera (not the old menu camera), walking allowed, the old Home screen hidden
--   B  classes through the lobby's ClassAction remote (ClassService): an owned class selects, an
--      unowned paid class is refused without gold, buying with enough gold works once
--   C  solo: join a gate, READY, countdown, RunEntry.BeginLocalMatch starts the run on Cliffwood
--      with the selected class rig + class weapon
--   D  the run ends (EndRun) -> results -> back at the bonfire with the avatar, InRun false,
--      rewards committed exactly once (Stats.Runs +1, gold settled once), can queue again
--   E  a 2-player party (Invite / Accept, the Party gate) enters together, each with their own class,
--      and both come back to the camp
--   F  (--set cycles=N) the leak check: N solo queue -> run -> camp cycles, counts per cycle
-- Lune sim, NOT Studio. Prints PASS/FAIL lines; any FAIL fails tools/run_regressions.py.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local results = {}
local function check(name: string, ok: boolean, detail: any?)
	table.insert(results, { name, ok })
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail ~= nil and (": " .. tostring(detail)) or ""))
end

------------------------------------------------------------------------------------------
-- Boot (a second player first, so the server loads both saves)
------------------------------------------------------------------------------------------
preview.enableAvatars(true)
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 2)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)
local okClient = pcall(preview.startClient)
preview.advance(3)

local R = preview.Mock.R
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local LobbyConfig = preview.require(ReplicatedStorage.SwarmV2.Lobby.LobbyConfig)
local MatchAdmission = preview.require(ServerScriptService.SwarmV2.MatchAdmission)
local LobbyBoot = preview.require(ServerScriptService.SwarmV2.Lobby.LobbyBoot)
local QueueService = preview.require(ServerScriptService.SwarmV2.Lobby.QueueService)
local RunEntry = preview.require(ServerScriptService.SwarmV2.Run.RunEntry)
local st = ReplicatedStorage:WaitForChild("SwarmState")
local net = ReplicatedStorage:WaitForChild("SwarmV2Net"):WaitForChild("Lobby")
local Origin = LobbyConfig.Origin

local advance = preview.advance
local function fireAs(p: Player, remoteName: string, ...)
	local remote = net:FindFirstChild(remoteName)
	if p == me then
		remote:FireServer(...)
	else
		R.fire(R.states[remote], "OnServerEvent", p, ...)
	end
	advance(0.3)
end
local function pickLevels()
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, me:GetAttribute("ChoiceOfferId"))
		advance(0.3)
	end
end
local function waitFor(seconds: number, cond: () -> boolean): boolean
	for _ = 1, math.ceil(seconds / 0.5) do
		if cond() then
			return true
		end
		advance(0.5, 10)
		pickLevels()
	end
	return cond()
end
local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
local function atBonfire(p: Player): (boolean, string)
	local char = p.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not char or not root then
		return false, "no character"
	end
	local d = flat((root :: BasePart).Position, Origin)
	local avatar = char:GetAttribute("SwarmV2Avatar") == true and char:GetAttribute("CharacterId") == nil
	return avatar and d < 25 and char:IsDescendantOf(workspace), string.format("avatar %s, %.0f studs from the bonfire", tostring(avatar), d)
end
local function errorCount(): number
	local n = 0
	for _, list in ipairs({ R.log.warnings, R.log.errors }) do
		for _, entry in ipairs(list) do
			local msg = tostring(entry.message)
			if string.find(msg, "Step error", 1, true) or string.find(msg, "handler error", 1, true) or string.find(msg, "BeginLocalMatch error", 1, true) then
				n += entry.count or 1
				preview.log("  logged: " .. msg)
			end
		end
	end
	return n
end

------------------------------------------------------------------------------------------
-- A. Basecamp, avatar, camera, old Home hidden
------------------------------------------------------------------------------------------
check("A0 client started", okClient)
check("A1 role is local", MatchAdmission.ServerRole() == "local", MatchAdmission.ServerRole())
check("A2 basecamp built", workspace:FindFirstChild("SwarmV2Lobby") ~= nil and LobbyBoot.Active() and workspace:GetAttribute("SwarmV2Lobby") == true
	and net:GetAttribute("Basecamp") == true)
waitFor(5, function()
	return (atBonfire(me))
end)
local okCamp, campInfo = atBonfire(me)
check("A3 own avatar at the bonfire (not the old lobby hero)", okCamp, campInfo)
local okAva, avaInfo = atBonfire(ava)
check("A4 second player's avatar at the bonfire", okAva, avaInfo)
check("A5 SwarmClass attribute on player and avatar", me:GetAttribute("SwarmClass") == "ruckus"
	and me.Character ~= nil and me.Character:GetAttribute("SwarmClass") == "ruckus", me:GetAttribute("SwarmClass"))
advance(0.5)
local cam = workspace.CurrentCamera
local hum = me.Character and me.Character:FindFirstChildOfClass("Humanoid")
check("A6 standard follow camera (not the old menu camera)", cam.CameraType == Enum.CameraType.Custom and hum ~= nil and cam.CameraSubject == hum,
	tostring(cam.CameraType))
local okLS, LobbyScreen = pcall(preview.client, "LobbyScreen")
check("A7 old Home screen hidden", okLS and LobbyScreen.HomeShown() == false)
local okMC, MobileControls = pcall(preview.client, "MobileControls")
check("A8 movement allowed in the basecamp", okMC and MobileControls.IsEnabled() == true)
check("A9 not in a run", me:GetAttribute("InRun") ~= true and st:GetAttribute("Phase") == "Lobby", st:GetAttribute("Phase"))

------------------------------------------------------------------------------------------
-- B. Classes through ClassService (ClassAction remote)
------------------------------------------------------------------------------------------
local data = DS.GetData(me)
data.Gold = 0
fireAs(me, "ClassAction", "Select", "ruckus")
check("B1 owned class selects", data.SelectedCharacter == "ruckus", data.SelectedCharacter)
fireAs(me, "ClassAction", "Select", "toastmaster")
check("B2 unowned paid class refused (select)", data.SelectedCharacter == "ruckus" and data.OwnedCharacters.toastmaster ~= true, data.SelectedCharacter)
fireAs(me, "ClassAction", "Buy", "toastmaster")
check("B3 buying without gold refused", data.OwnedCharacters.toastmaster ~= true and data.Gold == 0 and data.SelectedCharacter == "ruckus", data.Gold)
data.Gold = 15000
fireAs(me, "ClassAction", "Buy", "toastmaster")
check("B4 buy with enough gold: owned, selected, charged", data.OwnedCharacters.toastmaster == true and data.SelectedCharacter == "toastmaster"
	and data.Gold == 5000, data.Gold)
fireAs(me, "ClassAction", "Buy", "toastmaster")
fireAs(me, "ClassAction", "Buy", "toastmaster")
check("B5 buying again charges nothing", data.Gold == 5000, data.Gold)
check("B6 avatar class attribute follows", me:GetAttribute("SwarmClass") == "toastmaster", me:GetAttribute("SwarmClass"))

------------------------------------------------------------------------------------------
-- C. Solo gate -> local match on Cliffwood
------------------------------------------------------------------------------------------
local gold0 = data.Gold
local runs0 = data.Stats.Runs
local gate = LobbyConfig.Gates[1].Id
fireAs(me, "QueueAction", "Join", gate)
local q = QueueService.QueueOf(me)
check("C1 joined a gate", q ~= nil and q.GateId == gate, q and q.State)
fireAs(me, "QueueAction", "Ready", true)
q = QueueService.QueueOf(me)
check("C2 READY starts the countdown", q ~= nil and q.State == "Countdown", q and q.State)
local beginCalls = 0
local realBegin = RunEntry.BeginLocalMatch
RunEntry.BeginLocalMatch = function(...)
	beginCalls += 1
	return realBegin(...)
end
local started = waitFor(LobbyConfig.CountdownSeconds + 8, function()
	return RM.GetRunPlayer(me) ~= nil and st:GetAttribute("Phase") == "Running"
end)
check("C3 the local match starts after the countdown", started, st:GetAttribute("Phase"))
check("C4 started through RunEntry.BeginLocalMatch", beginCalls == 1 and RunEntry.Context(me) ~= nil, beginCalls)
local rp = RM.GetRunPlayer(me)
check("C5 run on Cliffwood", st:GetAttribute("Arena") == "Cliffwood", st:GetAttribute("Arena"))
local model = rp and rp.Character
check("C6 selected class rig", rp ~= nil and rp.CharacterId == "toastmaster" and model ~= nil and model:GetAttribute("CharacterId") == "toastmaster"
	and model:FindFirstChildOfClass("Humanoid") ~= nil and me.Character == model, rp and rp.CharacterId)
check("C7 class weapon", rp ~= nil and rp.WeaponOrder[1] == "ToastVolley", rp and table.concat(rp.WeaponOrder, ","))
check("C8 InRun set, the other player stays in the camp", me:GetAttribute("InRun") == true and RM.GetRunPlayer(ava) == nil and (atBonfire(ava)))
check("C9 Stats.Runs counted once at the start", data.Stats.Runs == runs0 + 1, tostring(runs0) .. " -> " .. tostring(data.Stats.Runs))

------------------------------------------------------------------------------------------
-- D. End -> results -> back at the bonfire, rewards once, queue again
------------------------------------------------------------------------------------------
if rp then
	rp.InvulnUntil = math.huge
	waitFor(20, function()
		return false
	end)
	-- [stream D] the director's opening (0.6 enemies/s, 35-70 studs out) can leave 20 s with
	-- almost no kill gold (a defeat keeps 35%, rounded down to 0): bank a known amount so D5
	-- checks the settlement, not the combat dice
	preview.server("GoldSystem").AddRunGold(rp, 100)
end
RM.EndRun(false)
advance(0.5)
check("D1 results phase", st:GetAttribute("Phase") == "Results", st:GetAttribute("Phase"))
local back = waitFor(30, function()
	return me:GetAttribute("InRun") ~= true and (atBonfire(me))
end)
local okBack, backInfo = atBonfire(me)
check("D2 back at the bonfire with the avatar", back and okBack, backInfo)
check("D3 InRun false, lobby phase", me:GetAttribute("InRun") ~= true and st:GetAttribute("Phase") == "Lobby", st:GetAttribute("Phase"))
check("D4 run committed", rp ~= nil and rp.Committed == true)
local settle = rp and rp.GoldSettlement
local paid = settle and (settle.Retained + settle.Survival) or 0
local gold1, runs1 = data.Gold, data.Stats.Runs
check("D5 gold settled", settle ~= nil and paid > 0 and gold1 - gold0 >= paid, string.format("delta %d, settled %d", gold1 - gold0, paid))
check("D6 Stats.Runs +1 exactly", runs1 == runs0 + 1, runs1)
pcall(preview.fireServerAs, me, "ReturnToLobby", "menu")
advance(10)
check("D7 no second commit (gold / runs unchanged later)", data.Gold == gold1 and data.Stats.Runs == runs1, string.format("%d -> %d", gold1, data.Gold))
advance(0.5)
check("D8 camera back on the avatar", workspace.CurrentCamera.CameraType == Enum.CameraType.Custom
	and me.Character ~= nil and workspace.CurrentCamera.CameraSubject == me.Character:FindFirstChildOfClass("Humanoid"))
check("D9 old Home screen still hidden", okLS and LobbyScreen.HomeShown() == false)
check("D10 no local match left", MatchAdmission.LocalMatchOf(me.UserId) == nil and RunEntry.Context(me) == nil)
fireAs(me, "QueueAction", "Join", gate)
check("D11 can queue again", QueueService.QueueOf(me) ~= nil)
fireAs(me, "QueueAction", "Leave")
check("D12 left the gate", QueueService.QueueOf(me) == nil)

------------------------------------------------------------------------------------------
-- E. A 2-player party, each with their own class
------------------------------------------------------------------------------------------
local avaData = DS.GetData(ava)
avaData.Gold = 20000
fireAs(ava, "ClassAction", "Buy", "captain_croak")
check("E1 second player bought + selected their class", avaData.SelectedCharacter == "captain_croak" and avaData.Gold == 0, avaData.SelectedCharacter)
preview.fireServerAs(me, "Party", "Invite", ava.UserId)
advance(0.3)
preview.fireServerAs(ava, "Party", "Accept", me.UserId)
advance(0.5)
local PS = preview.server("PartyService")
local party = PS.PartyOf(me)
check("E2 party formed", party ~= nil and #party.Members == 2 and party.Leader == me and PS.PartyOf(ava) == party)
local partyGate: string? = nil
for _, g in ipairs(LobbyConfig.Gates) do
	if g.Mode == "Party" then
		partyGate = g.Id
	end
end
fireAs(me, "QueueAction", "Join", partyGate)
check("E3 the party joined the Party gate", QueueService.QueueOf(me) ~= nil and QueueService.QueueOf(ava) == QueueService.QueueOf(me))
fireAs(me, "QueueAction", "Ready", true)
fireAs(ava, "QueueAction", "Ready", true)
local q2 = QueueService.QueueOf(me)
check("E4 both READY: countdown", q2 ~= nil and q2.State == "Countdown", q2 and q2.State)
local duo = waitFor(LobbyConfig.CountdownSeconds + 8, function()
	return RM.GetRunPlayer(me) ~= nil and RM.GetRunPlayer(ava) ~= nil and st:GetAttribute("Phase") == "Running"
end)
check("E5 both entered one run", duo and st:GetAttribute("Mode") == "Duo", st:GetAttribute("Mode"))
local rpMe, rpAva = RM.GetRunPlayer(me), RM.GetRunPlayer(ava)
check("E6 own classes", rpMe ~= nil and rpAva ~= nil and rpMe.CharacterId == "toastmaster" and rpAva.CharacterId == "captain_croak",
	(rpMe and rpMe.CharacterId or "-") .. " / " .. (rpAva and rpAva.CharacterId or "-"))
check("E7 own class weapons", rpMe ~= nil and rpAva ~= nil and rpMe.WeaponOrder[1] == "ToastVolley" and rpAva.WeaponOrder[1] == "BubbleBomb")
check("E8 on Cliffwood", st:GetAttribute("Arena") == "Cliffwood", st:GetAttribute("Arena"))
local runsMe, runsAva = data.Stats.Runs, avaData.Stats.Runs
if rpMe then
	rpMe.InvulnUntil = math.huge
end
if rpAva then
	rpAva.InvulnUntil = math.huge
end
advance(5, 10)
RM.EndRun(false)
local bothBack = waitFor(30, function()
	return me:GetAttribute("InRun") ~= true and ava:GetAttribute("InRun") ~= true and (atBonfire(me)) and (atBonfire(ava))
end)
check("E9 both back at the bonfire", bothBack, select(2, atBonfire(me)) .. " / " .. select(2, atBonfire(ava)))
check("E10 both committed once", rpMe ~= nil and rpMe.Committed == true and rpAva ~= nil and rpAva.Committed == true
	and data.Stats.Runs == runsMe and avaData.Stats.Runs == runsAva)
check("E11 the party is kept", PS.PartyOf(me) ~= nil and PS.PartyOf(me) == PS.PartyOf(ava))

------------------------------------------------------------------------------------------
-- F. (--set cycles=N, default off) the leak check: N solo queue -> run -> results -> camp
-- cycles through the real gate, countdown and RunEntry, with the client running; instances,
-- connections (by signal), waiting threads and the Lua heap in the camp after each cycle
------------------------------------------------------------------------------------------
local cycles = tonumber(preview.args.cycles) or 0
if cycles > 0 then
	if PS.PartyOf(me) then
		preview.fireServerAs(me, "Party", "Leave")
		advance(0.5)
	end
	local rows = {}
	for c = 1, cycles do
		fireAs(me, "QueueAction", "Join", gate)
		fireAs(me, "QueueAction", "Ready", true)
		local inRun = waitFor(LobbyConfig.CountdownSeconds + 8, function()
			return RM.GetRunPlayer(me) ~= nil and st:GetAttribute("Phase") == "Running"
		end)
		local r = RM.GetRunPlayer(me)
		if r then
			r.InvulnUntil = math.huge
		end
		advance(8, 10)
		pickLevels()
		RM.EndRun(false)
		local home = waitFor(30, function()
			return me:GetAttribute("InRun") ~= true and (atBonfire(me))
		end)
		pcall(preview.fireServerAs, me, "ReturnToLobby", "menu")
		advance(3, 10)
		local inTree, all = preview.liveInstances()
		local lc = preview.liveCounts()
		local row = { Tree = inTree, All = all, Conns = lc.connections, Waiting = lc.waiting, Tweens = lc.tweens, Heap = collectgarbage("count") / 1024, BySignal = lc.bySignal, Ok = inRun and home }
		table.insert(rows, row)
		preview.log(string.format("F cycle %2d %s: tree %6d  all %6d  conns %5d  waiting %4d  tweens %3d  heap %6.1f MB",
			c, (inRun and home) and "ok" or "STUCK", inTree, all, lc.connections, lc.waiting, lc.tweens, row.Heap))
	end
	local okAll = true
	for _, row in ipairs(rows) do
		okAll = okAll and row.Ok
	end
	check("F1 every queue -> run -> camp cycle completed", okAll and #rows == cycles)
	-- growth from the third cycle on (the first ones warm pools and caches)
	local a, b = rows[math.min(3, #rows)], rows[#rows]
	if a and b and #rows >= 4 then
		local grew = {}
		for name, n in pairs(b.BySignal) do
			local d = n - (a.BySignal[name] or 0)
			if d ~= 0 then
				table.insert(grew, string.format("%s %+d", name, d))
			end
		end
		table.sort(grew)
		local span = #rows - math.min(3, #rows)
		check(string.format("F2 connections flat from cycle 3 to %d (<= 2 per cycle)", #rows), b.Conns - a.Conns <= 2 * span,
			string.format("%+d [%s]", b.Conns - a.Conns, table.concat(grew, ", ")))
		check(string.format("F3 instances in the tree flat from cycle 3 to %d (<= 40 per cycle)", #rows), b.Tree - a.Tree <= 40 * span, string.format("%+d", b.Tree - a.Tree))
		check(string.format("F4 waiting threads flat from cycle 3 to %d (<= 5 per cycle)", #rows), b.Waiting - a.Waiting <= 5 * span, string.format("%+d", b.Waiting - a.Waiting))
	end
end

check("Z1 no step / handler errors logged", errorCount() == 0)

local failed = 0
for _, r in ipairs(results) do
	if not r[2] then
		failed += 1
	end
end
preview.log(string.format("swarm-v2-flow: %d/%d passed", #results - failed, #results))
