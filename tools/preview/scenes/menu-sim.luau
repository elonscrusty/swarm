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
local gui = me:WaitForChild("PlayerGui")
local function log(label: string)
	local r = results[#results]
	preview.log(string.format("%-26s phase=%s InRun=%s Alive=%s enemies=%d workspace=%d gui=%d frozen=%s result=%s",
		label, tostring(st:GetAttribute("Phase")), tostring(me:GetAttribute("InRun")), tostring(me:GetAttribute("Alive")),
		Spawner.LiveCount(function()
			return true
		end), count(workspace), count(gui), tostring(st:GetAttribute("Frozen")),
		r and string.format("%s/%s kills=%s abandoned=%s", tostring(r.Won), tostring(r.Portal), tostring(r.Kills), tostring(r.Abandoned)) or "-"))
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
wait(12)
log("results over")
preview.remote("StartRun"):FireServer("Solo")
wait(3)
log("new run after death")
preview.remote("AbandonRun"):FireServer()
wait(1)
log("final lobby")
