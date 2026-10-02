-- stage-sim: boots the REAL server (GameServer, all modules) and plays the stage loop
-- headlessly for a solo player through the remotes: start, dev "Spawn portal boss",
-- kill the Queen, the surge, the open portal, NEXT STAGE, travel to stage 2, then
-- RETURN TO LOBBY. Prints the state after each step (render.sh prints the log) and
-- renders the final lobby. A logic smoke test, not a picture. Run it with --studio (the
-- dev commands are Studio only): render.sh stage-sim --studio --devices pc
-- Level-up offers are answered at once (card 1) so the run never stays frozen.
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local st = C.state()
local me = Players.LocalPlayer
local function log(label)
	preview.log(string.format("%-28s phase=%s stage=%s sub=%s charge=%s hint=%s InRun=%s Alive=%s HP=%s time=%s gold=%s", label,
		tostring(st:GetAttribute("Phase")), tostring(st:GetAttribute("Stage")), tostring(st:GetAttribute("StagePhase")),
		tostring(st:GetAttribute("PortalCharge")), tostring(st:GetAttribute("PortalHint")), tostring(me:GetAttribute("InRun")),
		tostring(me:GetAttribute("Alive")), tostring(me:GetAttribute("HP")), tostring(st:GetAttribute("RunTime")), tostring(me:GetAttribute("RunGold"))))
end
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
local function send(name, ...)
	preview.remote(name):FireServer(...)
	preview.advance(0.2)
	pickLevels()
end
preview.advance = function(t, ...)
	local left = t
	while left > 0 do
		local step = math.min(left, 0.5)
		advance(step, ...)
		left -= step
		pickLevels()
	end
end
local Spawner = preview.server("EnemySpawner")
local Stage = preview.server("StageManager")
local RM = preview.server("RunManager")
log("boot")
send("StartRun", "Solo")
preview.advance(2)
log("started")
local rp = RM.GetRunPlayer(me)
if rp then
	rp.InvulnUntil = math.huge -- the smoke test is about the loop, not survival
end
preview.advance(3)
log("explore 5s")
send("DevCommand", "TeleportToPortal")
preview.advance(1.5)
log("in circle (dormant)")
preview.log("lock left", st:GetAttribute("PortalLockLeft"), "(charge must stay 0)")
send("DevCommand", "SpawnPortalBoss")
preview.advance(0.5)
log("dev boss")
preview.log("boss alive:", Spawner.Boss ~= nil, "boss HP", Spawner.Boss and math.floor(Spawner.Boss.MaxHP) or 0, "enemies", #Spawner.Active)
if Spawner.Boss then
	Spawner.Damage(Spawner.Boss, 1e9, rp)
end
preview.advance(0.5)
log("queen dead")
preview.advance(2)
preview.log("surge enemies alive", #Spawner.Active)
for _, e in ipairs(table.clone(Spawner.Active)) do
	Spawner.Kill(e, rp)
end
preview.advance(5)
log("surge cleared")
preview.advance(1)
log("portal open")
-- drop loot right before travelling: it must reach the player anyway
local XP = preview.server("XPSystem")
local xpBefore = (me:GetAttribute("Level") or 0) * 1000 + (me:GetAttribute("XP") or 0)
local rpNow = RM.GetRunPlayer(me)
local root = rpNow and rpNow.Root
if root then
	for i = 1, 30 do
		XP.SpawnGem(root.Position + Vector3.new(60 + i, 0, 60), 25)
	end
	XP.SpawnChest(root.Position + Vector3.new(-70, 0, 70))
end
-- spam + invalid choices are ignored
send("PortalChoice", "Teleport")
send("PortalChoice", 42)
send("PortalChoice", "Next")
send("PortalChoice", "Next")
preview.advance(0.5)
log("chose next")
preview.advance(3)
log("travelled")
preview.log("level*1000+xp before", xpBefore, "after", (me:GetAttribute("Level") or 0) * 1000 + (me:GetAttribute("XP") or 0), "gold", me:GetAttribute("RunGold"))
preview.log("stage HP mult", Stage.EnemyHPMult(), "boss mult", Stage.BossHPMult(), "portal", tostring(Stage.PortalPosition()))
rp = RM.GetRunPlayer(me)
if rp then
	rp.InvulnUntil = math.huge
end
send("DevCommand", "SpawnPortalBoss")
preview.advance(0.5)
log("stage 2 boss")
if Spawner.Boss then
	preview.log("stage 2 boss HP", math.floor(Spawner.Boss.MaxHP))
	Spawner.Damage(Spawner.Boss, 1e9, rp)
end
preview.advance(25)
log("surge timed out")
send("PortalChoice", "Return")
preview.advance(1)
log("returned")
local DS = preview.server("DataService")
local data = DS.GetData(me)
if data then
	preview.log("stats", "Wins", data.Stats.Wins, "BestStage", data.Stats.BestStage, "Runs", data.Stats.Runs, "Gold", data.Gold, "Version", data.Version)
end
preview.advance(2)
