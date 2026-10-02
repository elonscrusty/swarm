-- boss-sim: boots the REAL server and plays one full stage boss encounter plus the enemy
-- behaviours headlessly (solo), printing every boss state change, hazards and the player's
-- HP. --set boss=ScorpionQueen|MothMatriarch|RhinoWarlord|HiveMother picks the boss
-- (StageManager.ForceBoss); --set behaviours=off skips the regular-enemy part.
-- Checks: the creatures (Spitter glob, Bomb Tick fuse, Rhino lunge, elite affixes, a
-- Burrower tunnelling and surfacing, a Healer's pulse, a Nest spawning mites and paying
-- its reward), the boss entrance (invulnerable, no damage during entrance + grace), the
-- attack cycle, phase 2 at 50% (roar + twist), a kill in the middle of an attack (the
-- collapse clears every hazard / stinger / banner / egg at once, then the surge), a
-- simultaneous second hit (no double kill), and travel cleanup. A logic smoke test:
--   render.sh boss-sim --studio --devices pc --set boss=RhinoWarlord
local C = lib("common")
local Players = game:GetService("Players")
local bossId = preview.args.boss or "ScorpionQueen"
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
local seenStates = {}
local lastState, lastAct = nil, nil
local function watch()
	local b = Spawner.Boss
	local s = b and b.BossState or "-"
	local a = b and tostring(b.Act) or "-"
	if b then
		seenStates[s] = (seenStates[s] or 0) + (s ~= lastState and 1 or 0)
	end
	if s ~= lastState or a ~= lastAct then
		lastState, lastAct = s, a
		preview.log(string.format("t=%5.1f boss state=%-13s act=%-10s hp=%s/%s phase=%s invuln=%s harmless=%s hazards=%d warnsOnClient=%d enemies=%d playerHP=%s",
			st:GetAttribute("RunTime") or 0, s, a, b and math.floor(b.HP) or 0, b and math.floor(b.MaxHP) or 0, tostring(st:GetAttribute("BossPhase")),
			tostring(b and b.Invulnerable), tostring(b and b.Harmless), Hazards.Count(), Telegraphs and Telegraphs.Count() or -1, #Spawner.Active, tostring(me:GetAttribute("HP"))))
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
local function countObjects(): number
	local n = 0
	for _, e in ipairs(Spawner.Active) do
		if e.Alive and e.Def and e.Def.Object then
			n += 1
		end
	end
	return n
end
send("StartRun", "Solo")
run(2)
local rp = RM.GetRunPlayer(me)
preview.log("run started; boss", bossId, "stage boss attr", tostring(st:GetAttribute("StageBoss")), "enemies", #Spawner.Active)

-- regular enemies with behaviours and the new creatures, next to the player
local root = rp and rp.Root
local function near(dx, dz)
	local p = root.Position
	return Vector3.new(p.X + dx, 0, p.Z + dz)
end
if root and preview.args.behaviours ~= "off" then
	local spit = Spawner.Spawn("Spitter", near(26, 0))
	local tick = Spawner.Spawn("Bomber", near(-4, 3))
	local rhino = Spawner.Spawn("Brute", near(0, -12))
	local burrow = Spawner.Spawn("Burrower", near(22, 14))
	local healer = Spawner.Spawn("Healer", near(-22, -6))
	local hurt = Spawner.Spawn("Skeleton", near(-26, -2))
	local e1 = Spawner.Spawn("Skeleton", near(30, 30), { Elite = true, Affix = "Burning" })
	local e2 = Spawner.Spawn("Slime", near(-30, 30), { Elite = true, Affix = "Shielded" })
	local e3 = Spawner.Spawn("Bat", near(-30, -30), { Elite = true, Affix = "Swift" })
	if hurt then
		hurt.HP = hurt.MaxHP * 0.3
	end
	local hurtBefore = hurt and hurt.HP or 0
	local acts = {}
	taken = 0
	for k = 1, 60 do
		rawAdvance(0.1)
		topUp()
		pickLevels()
		for name, e in pairs({ Spitter = spit, Bomber = tick, Rhino = rhino, Burrower = burrow, Healer = healer }) do
			local a = e and (e.Alive and (tostring(e.Act) .. (e.Untargetable and " (untargetable)" or "")) or "dead") or "none"
			if acts[name] ~= a then
				acts[name] = a
				preview.log(string.format("  t+%.1f %s act=%s", k * 0.1, name, a))
			end
		end
	end
	preview.log("behaviours: damage taken", math.floor(taken), "hazards", Hazards.Count())
	preview.log("healer pulse: hurt beetle HP", math.floor(hurtBefore), "->", hurt and math.floor(hurt.HP) or -1, "of", hurt and math.floor(hurt.MaxHP) or -1)
	preview.log("elite affixes:", e1 and e1.Affix, e2 and e2.Affix, e3 and e3.Affix, "shield", e2 and math.floor(e2.Shield), "swift speed", e3 and math.floor(e3.Speed * 10) / 10)
	if e2 then
		local before = e2.HP
		Spawner.Damage(e2, e2.Shield * 0.5, rp)
		preview.log("shield soaks: HP", math.floor(before), "->", math.floor(e2.HP), "shield left", math.floor(e2.Shield))
		Spawner.Damage(e2, e2.Shield + 5, rp)
		preview.log("shield broke: attr", tostring(e2.Part:GetAttribute("Shield")), "HP", math.floor(e2.HP))
	end
	-- a nest: mites climb out of its openings, then it is destroyed for its reward
	local nest = Spawner.SpawnNest()
	preview.log("nest spawned:", nest ~= nil, "HPFrac", nest and tostring(nest.Part:GetAttribute("HPFrac")))
	run(10)
	local kids = 0
	if nest and nest.Children then
		for _, item in ipairs(nest.Children) do
			if item[1].Alive and item[1].Uid == item[2] then
				kids += 1
			end
		end
	end
	local goldBefore = me:GetAttribute("RunGold") or 0
	if nest then
		Spawner.Damage(nest, nest.MaxHP * 0.5, rp)
		preview.log("nest half: HPFrac", tostring(nest.Part:GetAttribute("HPFrac")), "mites alive", kids, "mites made", nest.SpawnedCount or 0)
		Spawner.Damage(nest, nest.MaxHP, rp)
	end
	run(0.3)
	preview.log("nest destroyed: alive", nest and nest.Alive, "run gold", goldBefore, "->", me:GetAttribute("RunGold"))
	heal()
end

-- the boss
Stage.ForceBoss(bossId)
send("DevCommand", "TeleportToPortal")
send("DevCommand", "SpawnPortalBoss")
local boss = Spawner.Boss
preview.log("boss spawned:", boss ~= nil, "type", boss and boss.Type, "BossName", st:GetAttribute("BossName"), "pill", st:GetAttribute("StageBoss"), "HP", boss and math.floor(boss.MaxHP), "enemies", #Spawner.Active)
if boss then
	-- a sturdier boss for the test (the hero's weapons would kill it before every
	-- pattern showed); the real HP is printed above
	boss.MaxHP *= 12
	boss.HP = boss.MaxHP
	local hpBefore = boss.HP
	Spawner.Damage(boss, 500, rp)
	preview.log("hit during entrance: HP", math.floor(hpBefore), "->", math.floor(boss.HP), "(must be unchanged)")
end
taken = 0
local entrance = boss and (boss.BossData.Entrance.Seconds + boss.BossData.Entrance.Grace) or 4.5
run(entrance - 0.3)
preview.log("damage during entrance + grace:", math.floor(taken), "(boss attacks: none; any is from minions)")
taken = 0
run(26)
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
taken = 0
run(34)
preview.log("phase 2 damage taken", math.floor(taken), "objects (banner / eggs) alive", countObjects())
-- kill it in the middle of an attack (wait for a hazard to be live)
for _ = 1, 120 do
	if Hazards.Count() > 0 or (Spawner.Boss and Spawner.Boss.BossState == "Ring") then
		break
	end
	run(0.1)
end
boss = Spawner.Boss
preview.log("killing mid-attack: state", boss and boss.BossState, "hazards", Hazards.Count(), "objects", countObjects())
if boss then
	Spawner.Damage(boss, 1e9, rp)
	Spawner.Damage(boss, 1e9, rp) -- simultaneous second hit must not double-kill
end
run(0.2)
preview.log("collapse: hazards", Hazards.Count(), "objects", countObjects(), "phase", Stage.GetPhase(), "boss alive", Spawner.Boss ~= nil)
run(1.8)
preview.log("after collapse: phase", Stage.GetPhase(), "gold", me:GetAttribute("RunGold"), "hazards", Hazards.Count(), "warnsOnClient", Telegraphs and Telegraphs.Count() or -1)
local states = {}
for name, n in pairs(seenStates) do
	table.insert(states, name .. "x" .. n)
end
table.sort(states)
preview.log("boss states seen:", table.concat(states, " "))
for _, e in ipairs(table.clone(Spawner.Active)) do
	Spawner.Kill(e, rp)
end
run(6)
preview.log("portal:", Stage.GetPhase())
send("PortalChoice", "Next")
run(3)
preview.log("travelled: stage", Stage.GetStage(), "phase", Stage.GetPhase(), "next boss", tostring(st:GetAttribute("StageBoss")), "hazards", Hazards.Count(), "warnsOnClient", Telegraphs and Telegraphs.Count() or -1)
run(4)
preview.log("stage 2 start calm: enemies", #Spawner.Active, "hazards", Hazards.Count())
