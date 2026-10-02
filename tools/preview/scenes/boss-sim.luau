-- boss-sim: boots the REAL server and plays one full Scorpion Queen encounter plus the new
-- enemy behaviours headlessly (solo), printing every boss state change, hazards and the
-- player's HP. Checks: entrance (invulnerable, no attacks for the grace time), the
-- attack cycle, phase 2 at 50% (roar + double charge), a kill in the middle of an attack
-- (collapse clears every hazard / stinger at once, then the surge), a Spitter glob, a
-- Bomb Tick fuse, a Rhino lunge, elite affixes, and travel cleanup. A logic smoke test:
--   render.sh boss-sim --studio --devices pc
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(0.5)
local st = C.state()
local me = Players.LocalPlayer
local rawAdvance = preview.advance
local Spawner = preview.server("EnemySpawner")
local RM = preview.server("RunManager")
local Hazards = preview.server("Hazards")
local Stage = preview.server("StageManager")
local Telegraphs = preview.client("Telegraphs")
local function pickLevels()
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
		rawAdvance(0.2)
	end
end
local lastState, lastAct = nil, nil
local function watch()
	local b = Spawner.Boss
	local s = b and b.BossState or "-"
	local a = b and tostring(b.Act) or "-"
	if s ~= lastState or a ~= lastAct then
		lastState, lastAct = s, a
		preview.log(string.format("t=%5.1f boss state=%-13s act=%-9s hp=%s/%s phase=%s invuln=%s harmless=%s hazards=%d warnsOnClient=%d playerHP=%s",
			st:GetAttribute("RunTime") or 0, s, a, b and math.floor(b.HP) or 0, b and math.floor(b.MaxHP) or 0, tostring(st:GetAttribute("BossPhase")),
			tostring(b and b.Invulnerable), tostring(b and b.Harmless), Hazards.Count(), Telegraphs and Telegraphs.Count() or -1, tostring(me:GetAttribute("HP"))))
	end
end
local taken = 0 -- damage the player took (HP is topped up every step so the run goes on)
local function topUp()
	local rp = RM.GetRunPlayer(me)
	if rp and rp.Alive then
		taken += math.max(0, rp.Stats.MaxHP - rp.HP)
		RM.Heal(rp, 10000, true)
	end
end
local function run(seconds)
	local left = seconds
	while left > 0 do
		local step = math.min(left, 0.1)
		rawAdvance(step)
		left -= step
		topUp()
		pickLevels()
		watch()
	end
end
local function send(name, ...)
	preview.remote(name):FireServer(...)
	run(0.2)
end
local function heal()
	local rp = RM.GetRunPlayer(me)
	if rp then
		RM.Heal(rp, 1000, true)
	end
end
send("StartRun", "Solo")
run(2)
local rp = RM.GetRunPlayer(me)
preview.log("run started; pacing calm active, enemies", #Spawner.Active)

-- regular enemies with behaviours, next to the player
local root = rp and rp.Root
local function near(dx, dz)
	local p = root.Position
	return Vector3.new(p.X + dx, 0, p.Z + dz)
end
if root then
	local spit = Spawner.Spawn("Spitter", near(26, 0))
	local tick = Spawner.Spawn("Bomber", near(-4, 3))
	local rhino = Spawner.Spawn("Brute", near(0, -12))
	local e1 = Spawner.Spawn("Skeleton", near(30, 30), { Elite = true, Affix = "Burning" })
	local e2 = Spawner.Spawn("Slime", near(-30, 30), { Elite = true, Affix = "Shielded" })
	local e3 = Spawner.Spawn("Bat", near(-30, -30), { Elite = true, Affix = "Swift" })
	local acts = {}
	taken = 0
	for k = 1, 40 do
		rawAdvance(0.1)
		topUp()
		for name, e in pairs({ Spitter = spit, Bomber = tick, Rhino = rhino }) do
			local a = e and (e.Alive and tostring(e.Act) or "dead") or "none"
			if acts[name] ~= a then
				acts[name] = a
				preview.log(string.format("  t+%.1f %s act=%s", k * 0.1, name, a))
			end
		end
	end
	preview.log("behaviours: damage taken", math.floor(taken), "hazards", Hazards.Count())
	preview.log("elite affixes:", e1 and e1.Affix, e2 and e2.Affix, e3 and e3.Affix, "shield", e2 and math.floor(e2.Shield), "swift speed", e3 and math.floor(e3.Speed * 10) / 10)
	if e2 then
		local before = e2.HP
		Spawner.Damage(e2, e2.Shield * 0.5, rp)
		preview.log("shield soaks: HP", math.floor(before), "->", math.floor(e2.HP), "shield left", math.floor(e2.Shield))
		Spawner.Damage(e2, e2.Shield + 5, rp)
		preview.log("shield broke: attr", tostring(e2.Part:GetAttribute("Shield")), "HP", math.floor(e2.HP))
	end
	heal()
end

-- the Queen
send("DevCommand", "TeleportToPortal")
send("DevCommand", "SpawnPortalBoss")
local boss = Spawner.Boss
preview.log("boss spawned:", boss ~= nil, "BossName", st:GetAttribute("BossName"), "enemies", #Spawner.Active)
if boss then
	local hpBefore = boss.HP
	Spawner.Damage(boss, 500, rp)
	preview.log("hit during entrance: HP", math.floor(hpBefore), "->", math.floor(boss.HP), "(must be unchanged)")
end
taken = 0
run(24)
preview.log("phase 1 damage taken", math.floor(taken))
for _ = 1, 60 do
	if not (Spawner.Boss and Spawner.Boss.Invulnerable) then
		break
	end
	run(0.1)
end
boss = Spawner.Boss
if boss then
	Spawner.Damage(boss, boss.HP - boss.MaxHP * 0.45, rp)
	preview.log("boss hit to 45% -> phase 2 at the next chase")
end
run(18)
-- kill her in the middle of an attack (wait for a hazard to be live)
for _ = 1, 100 do
	if Hazards.Count() > 0 or (Spawner.Boss and Spawner.Boss.BossState == "Ring") then
		break
	end
	run(0.1)
end
boss = Spawner.Boss
preview.log("killing mid-attack: state", boss and boss.BossState, "hazards", Hazards.Count())
if boss then
	Spawner.Damage(boss, 1e9, rp)
	Spawner.Damage(boss, 1e9, rp) -- simultaneous second hit must not double-kill
end
run(0.2)
preview.log("collapse: hazards", Hazards.Count(), "phase", Stage.GetPhase(), "boss alive", Spawner.Boss ~= nil)
run(1.6)
preview.log("after collapse: phase", Stage.GetPhase(), "gold", me:GetAttribute("RunGold"))
for _, e in ipairs(table.clone(Spawner.Active)) do
	Spawner.Kill(e, rp)
end
run(6)
preview.log("portal:", Stage.GetPhase())
send("PortalChoice", "Next")
run(3)
preview.log("travelled: stage", Stage.GetStage(), "phase", Stage.GetPhase(), "hazards", Hazards.Count(), "warnsOnClient", Telegraphs and Telegraphs.Count() or -1)
run(4)
preview.log("stage 2 start calm: enemies", #Spawner.Active)
