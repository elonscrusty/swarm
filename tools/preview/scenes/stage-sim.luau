-- stage-sim: boots the REAL server (GameServer, all modules) and plays the stage loop
-- headlessly for a solo player through the remotes: start, dev "Spawn portal boss",
-- kill the Queen, the surge, the open portal, NEXT STAGE, travel to stage 2, then
-- RETURN TO LOBBY. Prints the state after each step (render.sh prints the log) and
-- renders the final lobby. A logic smoke test, not a picture. Run it with --studio (the
-- dev commands are Studio only): render.sh stage-sim --studio --devices pc
-- Level-up offers are answered at once (card 1) so the run never stays frozen.
-- --set weapons=new adds the dev loadout of the eight newer weapons (evolved on stage 2),
-- --set character=<hero> plays as that hero.
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
-- --set character=<hero>: play the loop as that hero (owned for the test)
if preview.args.character then
	local data = preview.server("DataService").GetData(me)
	if data then
		data.OwnedCharacters[preview.args.character] = true
		data.SelectedCharacter = preview.args.character
	end
end
send("StartRun", "Solo")
preview.advance(2)
log("started")
local rp = RM.GetRunPlayer(me)
if rp then
	rp.InvulnUntil = math.huge -- the smoke test is about the loop, not survival
end
-- --set weapons=new: the dev loadout of every weapon added with the Alchemist / Engineer /
-- Necromancer (all at level 8; evolved after the travel) runs through the whole loop
local newWeapons = preview.args.weapons == "new"
if newWeapons then
	send("DevCommand", "NewWeapons")
	local r = RM.GetRunPlayer(me)
	preview.log("loadout", r and #r.WeaponOrder or 0, "weapons")
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
if newWeapons then
	send("DevCommand", "EvolveWeapons")
	preview.advance(4)
	local WS = preview.server("WeaponSystem")
	local parts = {}
	for k, v in pairs(WS.DebugCounts()) do
		table.insert(parts, k .. "=" .. v)
	end
	table.sort(parts)
	preview.log("evolved loadout live:", table.concat(parts, " "))
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

-- Every biome: stand in this stage's first floor hazard (BiomeHazards) and print what it
-- did (Terrain attribute, WalkSpeed, HP), then go on through the portal. --set stages=N
-- (default 6: stage 1 + a full tour of the rotation, so every arena gets built).
local BH = preview.server("BiomeHazards")
local MB = preview.server("MapBuilder")
local function hazardCheck()
	local arena = MB.GetArena()
	local now = RM.GetRunPlayer(me)
	local hz = arena and arena.Hazards and arena.Hazards[1]
	preview.log("arena", tostring(st:GetAttribute("StageArena")), "hazards", arena and #(arena.Hazards or {}) or 0, "BiomeHazards", BH and BH.Count() or -1)
	if not (hz and now and now.Root) then
		return
	end
	local hpBefore = now.HP
	now.InvulnUntil = 0
	RM.TeleportPlayer(now, hz.Pos)
	preview.advance(0.7)
	local hum = now.Humanoid
	preview.log("  in", hz.Kind, "Terrain", tostring(me:GetAttribute("Terrain")), "WalkSpeed", hum and math.floor(hum.WalkSpeed * 10 + 0.5) / 10, "base", now.Stats.Speed, "HP", math.floor(hpBefore), "->", math.floor(now.HP))
	now.InvulnUntil = math.huge
	RM.TeleportPlayer(now, hz.Pos + Vector3.new(0, 0, hz.Radius + 12))
	preview.advance(0.2)
	preview.log("  out", "Terrain", tostring(me:GetAttribute("Terrain")), "WalkSpeed", hum and math.floor(hum.WalkSpeed * 10 + 0.5) / 10)
end
hazardCheck()
local stages = tonumber(preview.args.stages) or 6
-- drive the loop by phase until stage n is reached (the boss may need several hits)
local function reach(n)
	for _ = 1, 40 do
		if (st:GetAttribute("Stage") or 0) >= n and st:GetAttribute("StagePhase") == "Explore" then
			return true
		end
		local sub = st:GetAttribute("StagePhase")
		rp = RM.GetRunPlayer(me)
		if rp then
			rp.InvulnUntil = math.huge
		end
		if sub == "Explore" then
			send("DevCommand", "SpawnPortalBoss")
		elseif sub == "Boss" then
			if Spawner.Boss then
				Spawner.Damage(Spawner.Boss, 1e9, rp)
			end
		elseif sub == "Surge" then
			for _, e in ipairs(table.clone(Spawner.Active)) do
				Spawner.Kill(e, rp)
			end
		elseif sub == "Open" then
			send("PortalChoice", "Next")
		end
		preview.advance(0.6)
	end
	return false
end
for n = 3, stages do
	local ok = reach(n)
	log("stage " .. n .. (ok and "" or " NOT REACHED"))
	hazardCheck()
end
-- clear the last stage so RETURN TO LOBBY is offered
for _ = 1, 20 do
	local sub = st:GetAttribute("StagePhase")
	if sub == "Open" then
		break
	elseif sub == "Explore" then
		send("DevCommand", "SpawnPortalBoss")
	elseif sub == "Boss" and Spawner.Boss then
		Spawner.Damage(Spawner.Boss, 1e9, rp)
	elseif sub == "Surge" then
		for _, e in ipairs(table.clone(Spawner.Active)) do
			Spawner.Kill(e, rp)
		end
	end
	preview.advance(0.6)
end
log("last stage open")
send("PortalChoice", "Return")
preview.advance(1)
log("returned")
local DS = preview.server("DataService")
local data = DS.GetData(me)
if data then
	preview.log("stats", "Wins", data.Stats.Wins, "BestStage", data.Stats.BestStage, "Runs", data.Stats.Runs, "Gold", data.Gold, "Version", data.Version)
end
preview.advance(2)
