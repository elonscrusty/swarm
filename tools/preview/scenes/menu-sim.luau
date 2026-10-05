-- menu-sim: boots the REAL server and client and checks the pause menu's MAIN MENU
-- (remote AbandonRun) over repeated lobby → run → lobby cycles, plus a death and a run
-- after it. Each cycle prints the phase, InRun, live enemies, workspace and PlayerGui
-- instance counts and the RunResult it got, so leftovers (enemies, projectiles, gems,
-- duplicate UI) show up as growing numbers. Run: render.sh menu-sim --studio --devices pc
-- --set cycles=N (default 4).
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local st = C.state()
local me = Players.LocalPlayer
local Spawner = preview.server("EnemySpawner")
local RM = preview.server("RunManager")
local advance = preview.advance
local function pickLevels()
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
		advance(0.3)
	end
end
local function wait(t: number)
	local left = t
	while left > 0 do
		local step = math.min(left, 0.5)
		advance(step)
		left -= step
		pickLevels()
	end
end
local results = {}
preview.remote("RunResult").OnClientEvent:Connect(function(d)
	table.insert(results, d)
end)
local function count(root: Instance): number
	return #root:GetDescendants()
end
local gui = me:FindFirstChild("PlayerGui") or me
local probes: { any }? = nil
local function log(label: string)
	local r = results[#results]
	preview.log(string.format("%-26s phase=%s InRun=%s Alive=%s enemies=%d workspace=%d gui=%d frozen=%s result=%s",
		label, tostring(st:GetAttribute("Phase")), tostring(me:GetAttribute("InRun")), tostring(me:GetAttribute("Alive")),
		Spawner.LiveCount(function()
			return true
		end), count(workspace), count(gui), tostring(st:GetAttribute("Frozen")),
		r and string.format("%s/%s kills=%s abandoned=%s", tostring(r.Won), tostring(r.Portal), tostring(r.Kills), tostring(r.Abandoned)) or "-"))
	-- leak probes (mock): connections, waiting / deferred threads, tweens, Sounds, Lua heap
	if preview.liveCounts then
		local lc = preview.liveCounts()
		local inTree, all = preview.liveInstances()
		pcall(collectgarbage, "collect")
		preview.log(string.format("%-26s   probes conns=%d waiting=%d deferred=%d tweens=%d sounds=%d/%d tree=%d all=%d heap=%.1fMB",
			"", lc.connections, lc.waiting, lc.deferred, lc.tweens, lc.soundsPlaying, lc.sounds, inTree, all, collectgarbage("count") / 1024))
		probes = probes or {}
		table.insert(probes, { label = label, lc = lc })
	end
end

log("boot (lobby)")
local cycles = tonumber(preview.args.cycles) or 4
for i = 1, cycles do
	preview.remote("StartRun"):FireServer("Solo")
	wait(1)
	preview.remote("DevCommand"):FireServer("SpawnEnemy", "Slime")
	preview.remote("DevCommand"):FireServer("SpawnElite", "Brute")
	wait(6)
	log(string.format("cycle %d in run", i))
	-- pause, then MAIN MENU → LEAVE RUN (what the confirmed button sends)
	preview.remote("SetPause"):FireServer(true)
	wait(0.5)
	log(string.format("cycle %d paused", i))
	preview.remote("AbandonRun"):FireServer()
	preview.remote("SetPause"):FireServer(false)
	wait(1)
	log(string.format("cycle %d after MAIN MENU", i))
	-- a second AbandonRun in the lobby is ignored
	preview.remote("AbandonRun"):FireServer()
	wait(0.5)
end

-- a death, then another run started cleanly
preview.remote("StartRun"):FireServer("Solo")
wait(1)
local rp = RM.GetRunPlayer and RM.GetRunPlayer(me)
if rp then
	RM.DamagePlayer(rp, 1e6)
end
wait(2)
log("after death")
-- solo death opens the revive offer (Config.Monetization.RevivePromptSeconds) and the run
-- waits on it: decline it as the offer's button does, then the results arrive
preview.remote("ReviveDecline"):FireServer()
wait(2)
log("revive declined")
-- the results screen's MAIN MENU (ReturnToLobby), as a player taps it
preview.remote("ReturnToLobby"):FireServer()
wait(1)
log("results closed")
preview.remote("StartRun"):FireServer("Solo")
wait(3)
log("new run after death")
local ok = me:GetAttribute("InRun") == true and me:GetAttribute("Alive") == true and #results >= 2 and results[#results].Abandoned ~= true
preview.log((ok and "PASS" or "FAIL") .. " new run after death: alive in a fresh run, the death's results arrived")
wait(5)
log("new run +5 s")
local spawned = Spawner.LiveCount(function()
	return true
end)
preview.log((spawned > 0 and "PASS" or "FAIL") .. " new run after death spawns enemies (" .. spawned .. ")")
preview.remote("AbandonRun"):FireServer()
wait(1)
log("final lobby")
-- connection growth by signal name between the first return to the lobby and the final lobby
if probes then
	local a, b
	for _, p in ipairs(probes) do
		if p.label == "cycle 1 after MAIN MENU" then
			a = p.lc
		end
	end
	b = probes[#probes].lc
	if a and b then
		local rows = {}
		for k, v in pairs(b.bySignal) do
			local d = v - (a.bySignal[k] or 0)
			if d ~= 0 then
				table.insert(rows, { k, d })
			end
		end
		for k, v in pairs(a.bySignal) do
			if b.bySignal[k] == nil then
				table.insert(rows, { k, -v })
			end
		end
		table.sort(rows, function(x, y)
			return math.abs(x[2]) > math.abs(y[2])
		end)
		local parts = {}
		for i = 1, math.min(12, #rows) do
			table.insert(parts, string.format("%s %+d", rows[i][1], rows[i][2]))
		end
		preview.log(string.format("connections: cycle-1 lobby %d -> final lobby %d; by signal: %s", a.connections, b.connections, table.concat(parts, ", ")))
	end
end
