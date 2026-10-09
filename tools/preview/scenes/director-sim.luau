-- director-sim: the single-map run director (stream D; docs/redesign/DECISIONS.md C5) on the real
-- server, on arena "Cliffwood" with a real height grid (lib/mapray answers the grid's rays).
-- PASS / FAIL lines for:
--   A  the brief's formulas: ordinary HP / damage at N = 1 and 4, the Basin Breaker's HP at
--      N = 1 / 4, spawn rate, overtime ramp, alive caps 55/95/145/200, the roster and boss timings
--   B  a solo run: RunStage Survive, no portal and no stage choice, spawns 35-70 studs from the
--      hero on walkable ground (never within 35 of a hero), roster minute gates (beetle and eye
--      from 0, root runner 2, stump brute 4, sap lobber 6), director stats at spawn (N, minute),
--      the beetle's 0.8 s per-player contact cooldown, elites from minute 5 at ~5% (3x HP,
--      1.25x damage, marker, Kind Elite), the alive cap, overtime, stuck repath then despawn
--      without rewards, the beacon (reveal at 12:30 at the Stone Circle, one activation within
--      20 studs, the rally, a charge that pauses outside r35 and never goes back), the Basin
--      Breaker exactly once with its HP formula, its three telegraphed attacks (timings, radius,
--      lane, damage = coeff x H0 x party), the 50% phase (recoveries x 0.85), no knockback, the
--      slow cap, then victory once (terminal lock: offers cancelled, spawns cleared, a later
--      wipe cannot become a defeat)
--   C  a solo wipe = defeat once
--   D  a duo: N = 2 (cap 95, HP scaled for 2), a fallen teammate keeps N and cannot light or
--      charge the beacon, the ProximityPrompt lights it, a late admission raises N to 3 and a
--      leaver does not lower it
--   E  a Forest run and LegacyStages = true keep the old stage loop
-- Uses the Studio-only test clock (StageManager.SetDirectorClock / SetTimeScale).
--   lune run tools/preview/runtime/main.luau -- --scene director-sim --studio --device pc
--     --max-time 3000 --set headless=on   [--set part=A,B,C,D,E]
local MapRay = lib("mapray")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local fails = 0
local passes = 0
local function check(name: string, ok: boolean, detail: any?)
	if ok then
		passes += 1
	else
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
end
local function near(a: number, b: number, tol: number?): boolean
	return math.abs(a - b) <= (tol or 1e-6) * math.max(1, math.abs(b))
end
local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local parts = {}
for _, p in ipairs(string.split(preview.args.part or "A,B,C,D,E", ",")) do
	parts[p] = true
end

local friend = preview.addPlayer("DirectorMate", 2)
preview.startServer()
preview.advance(1)

local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local HG = preview.server("HeightGrid")
local Spawner = preview.server("EnemySpawner")
local MapBuilder = preview.server("MapBuilder")
local DS = preview.server("DataService")
local Fx = preview.server("Fx")
local Hazards = preview.server("Hazards")
local LU = preview.server("LevelUpSystem")
local Config = require(ReplicatedStorage.Shared.Config)
local EnemyData = require(ReplicatedStorage.Shared.EnemyData)
local BossData = require(ReplicatedStorage.Shared.BossData)
local RunConfig = require(ReplicatedStorage.SwarmV2.Run.RunConfig)
local Beacon = preview.require(ServerScriptService.SwarmV2.Run.Beacon)
local Dir = RunConfig.Director
local F = SM.Formula
local st = ReplicatedStorage:WaitForChild("SwarmState")
MapRay.install(function()
	return MapBuilder.GetArena()
end)

-- hooks: every DamagePlayer call (cause, amount, time), every SpawnBoss, every EndRun
local hits = {}
local realDamage = RM.DamagePlayer
RM.DamagePlayer = function(rp, amount, cause, kind)
	table.insert(hits, { Rp = rp, Amount = amount, Cause = tostring(cause), Kind = kind, T = os.clock() })
	return realDamage(rp, amount, cause, kind)
end
local bossSpawns = 0
local realSpawnBoss = Spawner.SpawnBoss
Spawner.SpawnBoss = function(...)
	bossSpawns += 1
	return realSpawnBoss(...)
end
local ends = {}
local realEnd = RM.EndRun
RM.EndRun = function(won)
	local before = st:GetAttribute("Phase")
	realEnd(won)
	if before == "Running" and st:GetAttribute("Phase") ~= "Running" then
		table.insert(ends, won)
	end
end
local warns = {}
local realWarn = Fx.Warn
Fx.Warn = function(kind, ...)
	local id = realWarn(kind, ...)
	table.insert(warns, { Kind = kind, Args = { ... }, T = os.clock(), Id = id })
	return id
end
local results = {}
preview.remote("RunResult").OnClientEvent:Connect(function(d)
	table.insert(results, d)
end)
local offers = 0
preview.remote("LevelUpOffer").OnClientEvent:Connect(function()
	offers += 1
end)

local advance = preview.advance
local function pickLevels(p: Player?)
	local who = p or me
	for _ = 1, 20 do
		if not who:GetAttribute("Paused") then
			return
		end
		if who == me then
			preview.remote("LevelUpChoose"):FireServer(1, me:GetAttribute("ChoiceOfferId"))
		else
			preview.fireServerAs(who, "LevelUpChoose", 1, who:GetAttribute("ChoiceOfferId"))
		end
		advance(0.2, 10)
	end
end
local function keepAlive()
	for _, rp in ipairs(RM.GetRunPlayers()) do
		if rp.Alive then
			rp.InvulnUntil = math.huge
			if rp.Stats and rp.HP < rp.Stats.MaxHP then
				RM.Heal(rp, 1e6, true)
			end
		end
		if rp.RewardUntil and RM.EndReward then
			pcall(RM.EndReward, rp)
		end
	end
end
-- coarse simulation: 0.5 s slices at `fps` frames a second
local function run(seconds: number, onSlice: (() -> ())?, fps: number?)
	local left = seconds
	while left > 0 do
		local dt = math.min(left, 0.5)
		advance(dt, fps or 10)
		left -= dt
		keepAlive()
		pickLevels()
		pickLevels(friend)
		if onSlice then
			onSlice()
		end
	end
end
local function waitPhase(want: string, seconds: number): boolean
	for _ = 1, math.ceil(seconds / 0.5) do
		if st:GetAttribute("Phase") == want then
			return true
		end
		advance(0.5, 10)
	end
	return st:GetAttribute("Phase") == want
end
local function backToLobby()
	for _ = 1, 40 do
		if st:GetAttribute("Phase") == "Lobby" then
			return
		end
		for _, rp in ipairs(RM.GetRunPlayers()) do
			if st:GetAttribute("Phase") == "Running" then
				pcall(RM.AbandonRun, rp)
			end
		end
		pcall(function()
			preview.remote("ReturnToLobby"):FireServer("menu")
		end)
		advance(1, 10)
	end
end
local function startRun(list: { Player }, arena: string): any
	backToLobby()
	for _, p in ipairs(list) do
		local data = DS.GetData(p)
		if data then
			data.OwnedCharacters.ruckus = true
		end
		RM.SetAdmittedClass(p, "ruckus")
	end
	local ok = false
	for _ = 1, 20 do
		ok = RM.StartTeamRun(list, #list == 1 and "Solo" or "Duo", arena, list[1])
		if ok then
			break
		end
		advance(0.5, 10)
	end
	advance(1, 10)
	keepAlive()
	return ok
end
local function ordinary(): { any }
	local out = {}
	for _, e in ipairs(Spawner.Active) do
		if e.Alive and not e.Boss and not e.Def.Object and not e.Def.Static then
			table.insert(out, e)
		end
	end
	return out
end
local function clearEnemies()
	for _, e in ipairs(ordinary()) do
		Spawner.Despawn(e)
	end
end
local function rosterEntry(typeId: string)
	for _, entry in ipairs(Dir.Roster) do
		if entry.Type == typeId then
			return entry
		end
	end
	return nil
end
local function errorCount(): number
	local n = 0
	local R = preview.Mock.R
	for _, list in ipairs({ R.log.warnings, R.log.errors }) do
		for _, entry in ipairs(list) do
			local msg = tostring(entry.message)
			if string.find(msg, "Step error", 1, true) or string.find(msg, "handler error", 1, true) or string.find(msg, "failed:", 1, true) then
				n += entry.count or 1
				preview.log("  logged: " .. msg)
			end
		end
	end
	return n
end

------------------------------------------------------------------------------------------
-- A. formulas and data
------------------------------------------------------------------------------------------
if parts.A then
	local B, H0 = SM.Baselines()
	check("A1 baselines B = 10 (starter weapons), H0 = 120 (Config.Player.BaseMaxHP)", B == 10 and H0 == Config.Player.BaseMaxHP and H0 == 120, B .. " / " .. H0)
	check("A2 ordinary HP at N=1, t=0: beetle 2B = 20", near(F.EnemyHP(2, 1, 0), 20), F.EnemyHP(2, 1, 0))
	check("A3 ordinary HP at N=4, t=10: 2B x 1.9 x 1.7", near(F.EnemyHP(2, 4, 10), 20 * 1.9 * 1.7), F.EnemyHP(2, 4, 10))
	check("A4 contact damage at N=1, t=0: 0.05 H0 = 6", near(F.EnemyDamage(0.05, 1, 0), 6), F.EnemyDamage(0.05, 1, 0))
	check("A5 contact damage at N=4, t=10: 6 x 1.3 x 1.25", near(F.EnemyDamage(0.05, 4, 10), 6 * 1.3 * 1.25), F.EnemyDamage(0.05, 4, 10))
	check("A6 boss HP N=1, t=13.5: 200B x 1 x 1.945", near(F.BossHP(1, 13.5), 2000 * 1.945), F.BossHP(1, 13.5))
	check("A7 boss HP N=4, t=13.5: 200B x 3.4 x 1.945", near(F.BossHP(4, 13.5), 2000 * 3.4 * 1.945), F.BossHP(4, 13.5))
	check("A8 spawn rate t=0 N=1: 0.60/s", near(F.SpawnRate(0, 1), 0.60), F.SpawnRate(0, 1))
	check("A9 spawn rate t=10 N=4: 2.0 x 2.35", near(F.SpawnRate(10, 4), 2.0 * 2.35), F.SpawnRate(10, 4))
	check("A10 overtime: x1 at 15:00, x1.2 at 17:00, capped x1.5 at 25:00", near(F.Overtime(15), 1) and near(F.Overtime(17), 1.2) and near(F.Overtime(25), 1.5) and near(F.Overtime(40), 1.5),
		string.format("%.2f %.2f %.2f", F.Overtime(15), F.Overtime(17), F.Overtime(25)))
	check("A11 overtime rate at 17:00 N=1: (0.6 + 0.14 x 17) x 1.2", near(F.SpawnRate(17, 1), (0.6 + 0.14 * 17) * 1.2), F.SpawnRate(17, 1))
	check("A12 alive caps 55/95/145/200", F.AliveCap(1) == 55 and F.AliveCap(2) == 95 and F.AliveCap(3) == 145 and F.AliveCap(4) == 200,
		F.AliveCap(1) .. "/" .. F.AliveCap(2) .. "/" .. F.AliveCap(3) .. "/" .. F.AliveCap(4))
	check("A13 alive caps fit the enemy pool", F.AliveCap(4) <= Config.Enemies.MaxLive and Config.Enemies.MaxLive <= Config.Enemies.PoolSize)
	local eye = EnemyData.Enemies.FloatingEye.Ranged
	check("A14 floating eye: 0.70 s shot warning, 2.80 s interval", near(eye.Windup + eye.Flight, 0.70) and near(eye.Cooldown + eye.Windup, 2.80))
	local sap = EnemyData.Enemies.SapLobber.Ranged
	check("A15 sap lobber: r4, 1.00 s warning, every 3.50 s", sap.Splash == 4 and near(sap.Windup + sap.Flight, 1.0) and near(sap.Cooldown + sap.Windup, 3.5))
	local slam = EnemyData.Enemies.StumpBrute.Slam
	check("A16 stump brute: r6 slam, 1 s warning, every 3 s", slam.Radius == 6 and slam.Warn == 1 and slam.Every == 3)
	local want = { Skeleton = { 2, 14, 0.05, 0 }, FloatingEye = { 3, 10, nil, 0 }, RootRunner = { 1.5, 20, 0.04, 2 }, StumpBrute = { 5, 8, nil, 4 }, SapLobber = { 3, 9, nil, 6 } }
	local rosterOk = true
	for typeId, w in pairs(want) do
		local e = rosterEntry(typeId)
		if not e or e.HP ~= w[1] or e.Speed ~= w[2] or (w[3] and e.Contact ~= w[3]) or e.FromMinute ~= w[4] or not EnemyData.Enemies[typeId] then
			rosterOk = false
			preview.log("  roster mismatch", typeId)
		end
	end
	check("A17 roster HP / speed / contact / minute gates (beetle = Skeleton Beetle Warrior)", rosterOk and rosterEntry("Skeleton").ContactCooldown == 0.8)
	check("A18 attack coefficients: eye 0.07, brute 0.10, lobber 0.06", rosterEntry("FloatingEye").Attack == 0.07 and rosterEntry("StumpBrute").Attack == 0.10 and rosterEntry("SapLobber").Attack == 0.06)
	local bb = BossData.Bosses.BasinBreaker
	local at = bb and bb.Attacks
	check("A19 Basin Breaker attacks: slam 1.20 s r12 0.15H0, charge 1.50 s 45 studs 0.20H0, 3 sap circles 1 s 0.12H0",
		at ~= nil and at.RootSlam.Windup == 1.2 and at.RootSlam.Radius == 12 and at.RootSlam.DamageH0 == 0.15
		and at.BreakerCharge.Windup == 1.5 and near(at.BreakerCharge.Speed * at.BreakerCharge.Duration, 45) and at.BreakerCharge.DamageH0 == 0.20
		and at.SapCircles.Count == 3 and at.SapCircles.Warn == 1 and at.SapCircles.DamageH0 == 0.12)
	check("A20 50% phase: recoveries x 0.85, telegraphs unchanged", bb.Phases[1].Above == 0.5 and near(1 / bb.Phases[2].Speed, 0.85) and EnemyData.Enemies[bb.EnemyType] ~= nil and EnemyData.Enemies[bb.EnemyType].KnockbackResist == 1)
	check("A21 the director is on, legacy stages off, live time scale 1", Dir.Enabled ~= false and Dir.LegacyStages == false and Dir.TimeScale == 1)
	local w0, w2, w4, w6 = Spawner.DirectorWeights(1.99), Spawner.DirectorWeights(2), Spawner.DirectorWeights(4), Spawner.DirectorWeights(6)
	check("A22 roster weights by minute", w0.Skeleton and w0.FloatingEye and not w0.RootRunner and not w0.StumpBrute and w2.RootRunner and not w2.StumpBrute
		and w4.StumpBrute and not w4.SapLobber and w6.SapLobber ~= nil)
	local old = 0
	for id in pairs(w6) do
		if not rosterEntry(id) then
			old += 1
		end
	end
	check("A23 no old enemy type in the Cliffwood roster", old == 0)
end


-- every director spawn (any path): { E, Type, Elite, Minute, N }
local spawns = {}
local realSpawn = Spawner.Spawn
Spawner.Spawn = function(typeId, pos, opts)
	local e = realSpawn(typeId, pos, opts)
	if e and Spawner.IsDirector() and not e.Boss then
		table.insert(spawns, { E = e, Uid = e.Uid, Type = typeId, Elite = e.Elite, Minute = e.SpawnMinute, N = e.SpawnN, MaxHP = e.MaxHP, Damage = e.Damage, Attack = e.AttackDamage, Speed = e.Speed, Kind = e.Kind, Affix = e.Affix })
	end
	return e
end
-- boss state changes, frame by frame: { State, Timer, Phase, T }
local BossAI = preview.server("BossAI")
local bossLog = {}
local chaseMoves = {}
local lastBossState, lastBossPos = nil, nil
local realBossStep = BossAI.Step
BossAI.Step = function(e, dt)
	if lastBossPos and e.BossState == "Chase" and e.SpeedOverride == nil and dt > 0 then
		table.insert(chaseMoves, { Speed = flat(e.Pos, lastBossPos) / dt, Want = e.Speed, Slowed = e.SlowUntil ~= nil and e.SlowUntil > RM.GetRunTime() })
	end
	realBossStep(e, dt)
	lastBossPos = e.Pos
	if e.BossState ~= lastBossState then
		lastBossState = e.BossState
		table.insert(bossLog, { State = e.BossState, Timer = e.BossTimer, Phase = e.PhaseIndex, T = os.clock() })
	end
end

local function landmarkNamed(arena, name: string)
	for _, lm in ipairs(arena.Landmarks or {}) do
		if lm.Name == name then
			return lm
		end
	end
	return nil
end
-- a walkable spot `from` + dist along some direction (tries 16), else nil
local function walkableAt(from: Vector3, dist: number): Vector3?
	for k = 0, 15 do
		local a = k * math.pi / 8 + math.pi / 2
		local x, z = from.X + math.cos(a) * dist, from.Z + math.sin(a) * dist
		if HG.IsWalkable(x, z) and HG.IsWalkable(x + 2, z) and HG.IsWalkable(x - 2, z) and HG.IsWalkable(x, z + 2) and HG.IsWalkable(x, z - 2) then
			return Vector3.new(x, HG.GroundY(x, z), z)
		end
	end
	return nil
end
local function put(rp, at: Vector3)
	RM.TeleportPlayer(rp, at)
	rp.LastValidPos = rp.Root.Position
end

------------------------------------------------------------------------------------------
-- B. solo run: spawns, roster, stats, beacon, boss, victory
------------------------------------------------------------------------------------------
if parts.B then
	preview.log("---- B solo run")
	local okStart = startRun({ me }, "Cliffwood")
	local rp = RM.GetRunPlayer(me)
	run(1)
	check("B1 Cliffwood starts a director run", okStart and rp ~= nil and SM.IsDirector() and Spawner.IsDirector() and st:GetAttribute("RunStage") == "Survive",
		tostring(st:GetAttribute("RunStage")))
	check("B2 no portal, the height grid is real", SM.PortalPosition() == nil and st:GetAttribute("PortalPos") == nil and HG.IsActive() and st:GetAttribute("StagePhase") == "Explore", MapRay.count() .. " rays")
	check("B3 RunClock / PartyN published", type(st:GetAttribute("RunClock")) == "number" and SM.PartyN() == 1 and st:GetAttribute("PartyN") == 1)
	local portalOffers = 0
	local conn = preview.remote("PortalOffer").OnClientEvent:Connect(function()
		portalOffers += 1
	end)
	preview.remote("PortalChoice"):FireServer("Next")
	preview.remote("PortalChoice"):FireServer("Return")
	run(1)
	check("B4 no stage choice and no exit (PortalChoice ignored)", st:GetAttribute("Phase") == "Running" and portalOffers == 0 and RM.GetRunPlayer(me) == rp)
	conn:Disconnect()

	-- 20 s at the start: the band, the ground, the minute-0 roster
	table.clear(spawns)
	local offGround, unwalk, samples = 0, 0, 0
	run(20, function()
		for _, e in ipairs(ordinary()) do
			samples += 1
			if not HG.IsWalkable(e.Pos.X, e.Pos.Z) then
				unwalk += 1
			end
			if math.abs(e.Pos.Y - HG.GroundY(e.Pos.X, e.Pos.Z)) > 1.5 then
				offGround += 1
			end
		end
	end)
	local S = Spawner.DirectorStats
	check("B5 the director spawns from the start", S.Spawned > 5, S.Spawned)
	check("B6 spawns 35-70 studs from their hero", S.MinDist >= 35 - 0.01 and S.MaxDist <= 70 + 0.01, string.format("%.1f..%.1f", S.MinDist, S.MaxDist))
	check("B7 never within 35 studs of any hero", S.MinToAnyHero >= 35 - 0.01, string.format("%.1f", S.MinToAnyHero))
	check("B8 enemies on walkable ground", samples > 0 and unwalk == 0 and offGround == 0, string.format("%d samples, %d unwalkable, %d off the ground", samples, unwalk, offGround))
	local early = {}
	for id in pairs(S.ByType) do
		table.insert(early, id)
	end
	table.sort(early)
	check("B9 minute 0: only beetles and floating eyes", (S.ByType.RootRunner or 0) + (S.ByType.StumpBrute or 0) + (S.ByType.SapLobber or 0) == 0 and (S.ByType.Skeleton or 0) > 0, table.concat(early, ","))
	check("B10 no elites before minute 5", S.Elites == 0)
	-- the director's stats at spawn
	local statOk, statN, firstBad = true, 0, nil
	for _, s in ipairs(spawns) do
		local entry = rosterEntry(s.Type)
		if entry and s.Minute then
			statN += 1
			local hp = F.EnemyHP(entry.HP, s.N, s.Minute) * SM.EnemyHPMult() * (s.Elite and Dir.Elite.HPMult or 1)
			local dmg = F.EnemyDamage(entry.Contact, s.N, s.Minute) * SM.DamageMult() * (s.Elite and Dir.Elite.DamageMult or 1)
			local atk = entry.Attack and F.EnemyDamage(entry.Attack, s.N, s.Minute) * SM.DamageMult() * (s.Elite and Dir.Elite.DamageMult or 1) or nil
			local ok = near(s.MaxHP, hp, 1e-6) and near(s.Damage, dmg, 1e-6) and s.Speed == entry.Speed and s.Kind == (s.Elite and "Elite" or entry.Kind)
				and (atk == nil or near(s.Attack, atk, 1e-6))
			if not ok then
				statOk = false
				firstBad = firstBad or string.format("%s hp %.2f/%.2f dmg %.2f/%.2f speed %s kind %s", s.Type, s.MaxHP, hp, s.Damage, dmg, tostring(s.Speed), tostring(s.Kind))
			end
		end
	end
	check("B11 HP / contact / attack / speed / Kind from the formula (N and minute at spawn)", statN > 0 and statOk, firstBad or (statN .. " spawns"))

	-- the beetle's contact cooldown: 0.8 s per player
	Spawner.SetHold("director-sim", true)
	clearEnemies()
	local root = rp.Root.Position
	local beetle = Spawner.Spawn("Skeleton", root + Vector3.new(1.5, 0, 0))
	table.clear(hits)
	run(4, function()
		if beetle and beetle.Alive then
			beetle.Pos = Vector3.new(rp.Root.Position.X + 1.4, beetle.Pos.Y, rp.Root.Position.Z)
		end
	end, 30)
	local times = {}
	for _, h in ipairs(hits) do
		if h.Rp == rp and string.find(h.Cause, "contact", 1, true) then
			table.insert(times, h.T)
		end
	end
	local minGap = math.huge
	for i = 2, #times do
		minGap = math.min(minGap, times[i] - times[i - 1])
	end
	check("B12 beetle contact cooldown 0.8 s per player", #times >= 3 and minGap >= 0.8 - 1 / 30 - 1e-6 and minGap <= 0.8 + 2 / 30 + 1e-6, string.format("%d hits, min gap %.3f", #times, minGap))
	check("B13 beetle contact damage = 0.05 H0 at N=1 (minute at spawn)", beetle ~= nil and #hits > 0 and near(hits[#hits].Amount, F.EnemyDamage(0.05, 1, beetle.SpawnMinute or 0) * SM.DamageMult(), 1e-6),
		#hits > 0 and hits[#hits].Amount or "-")
	if beetle then
		Spawner.Despawn(beetle)
	end
	Spawner.SetHold("director-sim", false)

	-- 11:30 -> past 12:30: the later roster, elites at ~5%, the reveal
	table.clear(spawns)
	SM.SetDirectorClock(11.5 * 60)
	local stages: { [string]: boolean } = {}
	local revealT = nil
	local maxAlive = 0
	run(75, function()
		stages[st:GetAttribute("RunStage")] = true
		if revealT == nil and st:GetAttribute("RunStage") == "BeaconAvailable" then
			revealT = SM.DirectorClock()
		end
		-- keep the swarm thin so the spawner keeps spawning
		for _, e in ipairs(ordinary()) do
			if (e.Uid % 2) == 0 then
				Spawner.Despawn(e)
			end
		end
		maxAlive = math.max(maxAlive, Spawner.OrdinaryAlive())
	end)
	local elites, total = 0, 0
	local eliteRec = nil
	for _, s in ipairs(spawns) do
		if s.Minute and s.Minute >= 5 then
			total += 1
			if s.Elite then
				elites += 1
				eliteRec = eliteRec or s
			end
		end
	end
	local share = total > 0 and elites / total or 0
	check("B14 elites from minute 5 at about 5% of spawns", total >= 80 and share >= 0.01 and share <= 0.12, string.format("%d of %d = %.1f%%", elites, total, share * 100))
	if eliteRec then
		local entry = rosterEntry(eliteRec.Type)
		local e = eliteRec.E
		check("B15 an elite: 3x HP, 1.25x damage, marker, Kind Elite, no affix", entry ~= nil
			and near(eliteRec.MaxHP, F.EnemyHP(entry.HP, eliteRec.N, eliteRec.Minute) * SM.EnemyHPMult() * 3, 1e-6)
			and near(eliteRec.Damage, F.EnemyDamage(entry.Contact, eliteRec.N, eliteRec.Minute) * SM.DamageMult() * 1.25, 1e-6)
			and eliteRec.Kind == "Elite" and eliteRec.Affix == nil and (e.Uid ~= eliteRec.Uid or e.Part:GetAttribute("Elite") == true),
			eliteRec.Type)
	else
		check("B15 an elite spawned", false)
	end
	local S2 = Spawner.DirectorStats
	local gatesOk = true
	for _, entry in ipairs(Dir.Roster) do
		local first = S2.FirstAt[entry.Type]
		if first == nil or first < entry.FromMinute then
			gatesOk = false
		end
	end
	local firsts = {}
	for id, m in pairs(S2.FirstAt) do
		table.insert(firsts, string.format("%s %.2f", id, m))
	end
	table.sort(firsts)
	check("B16 roster minute gates (runner 2, brute 4, lobber 6); every type spawned", gatesOk, table.concat(firsts, ", "))
	check("B17 alive cap 55 (solo) never passed", maxAlive <= 55 and S2.LastCap == 55, maxAlive .. " / " .. S2.LastCap)
	check("B18 the beacon is revealed at 12:30", revealT ~= nil and revealT >= 750 and revealT <= 750 + 0.6 and stages.Survive == true, revealT and string.format("%.2f", revealT) or "never")

	-- the beacon
	local arena = MapBuilder.GetArena()
	local lm = landmarkNamed(arena, Dir.Beacon.Landmark)
	local bpos = Beacon.Position()
	check("B19 one beacon at the Stone Circle with its marker data", bpos ~= nil and lm ~= nil and flat(bpos, lm.Pos) < 10 and st:GetAttribute("BeaconPos") == bpos
		and st:GetAttribute("PortalPos") == bpos and st:GetAttribute("PortalHint") == true and Beacon.Phase() == "Available",
		bpos and lm and string.format("%.1f from the landmark", flat(bpos, lm.Pos)) or "none")
	local model = arena.Model:FindFirstChild("SwarmBeacon")
	local prompt = model and model:FindFirstChild("BeaconPrompt", true)
	check("B20 the beacon model has a light pillar and an E prompt", model ~= nil and model:FindFirstChild("Pillar") ~= nil and prompt ~= nil and prompt.KeyboardKeyCode == Enum.KeyCode.E)
	local farSpot = bpos and walkableAt(bpos, 30) or nil
	if farSpot then
		put(rp, farSpot)
	end
	local okFar, whyFar = Beacon.TryActivate(rp)
	check("B21 too far (> 20 studs) cannot light it", okFar == false and whyFar == "TooFar", tostring(whyFar))
	local nearSpot = bpos and walkableAt(bpos, 12) or nil
	check("B22 a spot 12 studs from the beacon", nearSpot ~= nil)
	if not (bpos and nearSpot) then
		preview.log("FAIL: no beacon spot, part B stops")
	else
		put(rp, nearSpot)
		local clockAt = SM.DirectorClock()
		local ok1 = Beacon.TryActivate(rp)
		local ok2, why2 = Beacon.TryActivate(rp)
		check("B23 a living hero within 20 lights it once", ok1 == true and ok2 == false and why2 == "NotAvailable" and st:GetAttribute("RunStage") == "Rally" and st:GetAttribute("RallyLeft") == 30)
		local chargeT = nil
		local rallyLeftSeen = math.huge
		run(31, function()
			put(rp, nearSpot)
			rallyLeftSeen = math.min(rallyLeftSeen, st:GetAttribute("RallyLeft") or math.huge)
			if chargeT == nil and st:GetAttribute("RunStage") == "Charge" then
				chargeT = SM.DirectorClock()
			end
		end)
		check("B24 30 s rally, then the charge", chargeT ~= nil and math.abs(chargeT - clockAt - 30) <= 0.6 and rallyLeftSeen <= 1, chargeT and string.format("%.2f s", chargeT - clockAt) or "no charge")
		-- inside: it charges; outside: it pauses; it never goes back
		local samplesC = {}
		local decreased = false
		local last = -1
		local function sample()
			local c = st:GetAttribute("BeaconCharge") or 0
			if c < last then
				decreased = true
			end
			last = c
			table.insert(samplesC, c)
		end
		put(rp, nearSpot)
		run(12, sample)
		local afterIn = Beacon.Charge()
		local outSpot = walkableAt(bpos, 55)
		if outSpot then
			put(rp, outSpot)
		end
		run(8, sample)
		local afterOut = Beacon.Charge()
		put(rp, nearSpot)
		run(6, sample)
		local afterBack = Beacon.Charge()
		check("B25 the charge fills inside r35 (about 1/60 per s)", afterIn > 0.15 and afterIn < 0.25, string.format("%.3f", afterIn))
		check("B26 outside r35 it pauses (no progress, no loss)", outSpot ~= nil and math.abs(afterOut - afterIn) < 1e-9, string.format("%.3f -> %.3f", afterIn, afterOut))
		check("B27 back inside it resumes; it never went back", afterBack > afterOut and not decreased, string.format("%.3f", afterBack))
		check("B28 no boss before 100%", bossSpawns == 0 and Spawner.Boss == nil)
		-- finish the charge 6x faster (the Studio test clock)
		SM.SetTimeScale(6)
		local boss = nil
		run(12, function()
			put(rp, nearSpot)
			sample()
			boss = boss or Spawner.Boss
		end)
		SM.SetTimeScale(1)
		boss = Spawner.Boss
		check("B29 at 100% the Basin Breaker spawns, RunStage Boss", boss ~= nil and boss.Type == "BasinBoss" and st:GetAttribute("RunStage") == "Boss" and st:GetAttribute("BossName") == "Basin Breaker" and not decreased,
			string.format("charge %.2f, stage %s", Beacon.Charge(), tostring(st:GetAttribute("RunStage"))))
		check("B30 its HP = 200B x [1 + 0.8 (N-1)] x [1 + 0.07 t] at its spawn (N=1)", boss ~= nil and boss.SpawnN == 1 and near(boss.MaxHP, F.BossHP(1, boss.SpawnMinute), 1e-6)
			and st:GetAttribute("BossMaxHP") == math.ceil(boss.MaxHP), boss and string.format("%.0f at %.2f min", boss.MaxHP, boss.SpawnMinute) or "-")
		Beacon.ForceCharge(1)
		run(2)
		check("B31 exactly one boss (no second spawn, DevActivate refused)", bossSpawns == 1 and SM.DevActivate() == false and bossSpawns == 1, bossSpawns)

		-- the fight: stay beside it (invulnerable); every hit is logged
		table.clear(hits)
		table.clear(warns)
		table.clear(bossLog)
		local function stayClose()
			local b = Spawner.Boss
			if b and b.Alive and flat(rp.Root.Position, b.Pos) > 9 then
				local dir = (b.Pos - bpos) * Vector3.new(1, 0, 1)
				local spot = b.Pos - (dir.Magnitude > 1 and dir.Unit or Vector3.new(1, 0, 0)) * 8
				if HG.IsWalkable(spot.X, spot.Z) then
					put(rp, spot)
				end
			end
		end
		run(45, stayClose, 20)
		local seen = {}
		for _, b in ipairs(bossLog) do
			seen[b.State] = true
		end
		check("B32 its three attacks run (root slam, charge, sap circles)", seen.RootSlam and seen.ChargeWindup and seen.Charging and seen.SapWindup and seen.SapSeq,
			(function()
				local names = {}
				for k in pairs(seen) do
					table.insert(names, k)
				end
				table.sort(names)
				return table.concat(names, " ")
			end)())
		local slamWarn, laneWarn, sapWarns = nil, nil, {}
		for _, w in ipairs(warns) do
			if w.Kind == "circle" and w.Args[3] == 12 then
				slamWarn = slamWarn or w
			elseif w.Kind == "lane" then
				laneWarn = laneWarn or w
			elseif w.Kind == "circle" and w.Args[3] == 5 and w.Args[5] == "acid" then
				table.insert(sapWarns, w)
			end
		end
		check("B33 root slam telegraph: r12 circle for 1.20 s", slamWarn ~= nil and near(slamWarn.Args[4], 1.2))
		local reach = boss and (boss.Radius + 1.2) or 7.2
		check("B34 charge telegraph: 1.50 s lane, as wide as its reach, at most 45 studs + reach", laneWarn ~= nil and near(laneWarn.Args[6], 1.5)
			and near(laneWarn.Args[5], reach * 2, 1e-3) and laneWarn.Args[4] <= 45 + reach + 0.01,
			laneWarn and string.format("w %.2f len %.1f width %.1f", laneWarn.Args[6], laneWarn.Args[4], laneWarn.Args[5]) or "none")
		local spacedOk = #sapWarns >= 3
		for i = 2, math.min(3, #sapWarns) do
			if math.abs(sapWarns[i].T - sapWarns[i - 1].T - 1.0) > 0.11 then
				spacedOk = false
			end
		end
		check("B35 sap: three r5 circles, 1 s warning each, one after another", spacedOk and near(sapWarns[1].Args[4], 1.0), #sapWarns .. " circles")
		local dmgOk, kinds = true, {}
		local want = { ["Basin Breaker root slam"] = 0.15, ["Basin Breaker charge"] = 0.20, ["Basin Breaker sap"] = 0.12 }
		local _, H0 = SM.Baselines()
		local slamHitT = nil
		for _, h in ipairs(hits) do
			local coeff = want[h.Cause]
			if coeff then
				kinds[h.Cause] = true
				if not near(h.Amount, coeff * H0 * F.PartyDamage(1), 1e-6) then
					dmgOk = false
				end
				if h.Cause == "Basin Breaker root slam" and slamHitT == nil then
					slamHitT = h.T
				end
			end
		end
		local nk = 0
		for _ in pairs(kinds) do
			nk += 1
		end
		check("B36 hits = coeff x H0 x party damage (18 / 24 / 14.4 solo)", dmgOk and nk >= 2, nk .. " kinds landed")
		check("B37 the slam lands 1.20 s after its circle (server time)", slamWarn ~= nil and slamHitT ~= nil and math.abs(slamHitT - slamWarn.T - 1.2) <= 0.06,
			slamWarn and slamHitT and string.format("%.3f s", slamHitT - slamWarn.T) or "no slam hit")
		local recovers1 = {}
		for _, b in ipairs(bossLog) do
			if b.State == "Recover" and b.Phase == 1 then
				table.insert(recovers1, math.floor(b.Timer * 1000 + 0.5) / 1000)
			end
		end
		-- 50%: recoveries x 0.85, telegraphs as long
		boss = Spawner.Boss
		if boss then
			boss.HP = boss.MaxHP * 0.49
		end
		table.clear(bossLog)
		table.clear(warns)
		run(30, stayClose, 20)
		local p2, p2ok, timers = false, true, {}
		local allowed = { 1.1 * 0.85, 1.0 * 0.85, 0.9 * 0.85, 1.4 * 0.85 }
		for _, b in ipairs(bossLog) do
			if b.Phase == 2 then
				p2 = true
				if b.State == "Recover" then
					local okT = false
					for _, a in ipairs(allowed) do
						if math.abs(b.Timer - a) < 0.002 then
							okT = true
						end
					end
					if not okT then
						p2ok = false
					end
					table.insert(timers, string.format("%.3f", b.Timer))
				elseif b.State == "RootSlam" and math.abs(b.Timer - 1.2) > 0.002 then
					p2ok = false
				end
			end
		end
		check("B38 below 50%: phase 2, recoveries x 0.85, telegraphs unchanged", p2 and p2ok and #timers > 0, "phase 1 " .. table.concat(recovers1, ",") .. " | phase 2 " .. table.concat(timers, ","))
		-- no knockback, slow cap 10%
		boss = Spawner.Boss
		if boss then
			Spawner.Damage(boss, 1, rp, Vector3.new(1, 0, 0), 80)
			check("B39 the boss ignores knockback", boss.Knock.Magnitude == 0)
			table.clear(chaseMoves)
			boss.SlowUntil = RM.GetRunTime() + 30
			boss.SlowMult = 0.2
			-- keep the hero 25+ studs away so it walks (a boss on top of its target stands still)
			run(14, function()
				local b = Spawner.Boss
				if b and b.Alive and flat(rp.Root.Position, b.Pos) < 18 then
					local spot = walkableAt(b.Pos, 28)
					if spot then
						put(rp, spot)
					end
				end
			end, 20)
			local fast = {}
			for _, m in ipairs(chaseMoves) do
				if m.Slowed and m.Speed > 0.01 then
					table.insert(fast, m.Speed / m.Want)
				end
			end
			table.sort(fast)
			local median = #fast > 0 and fast[math.ceil(#fast / 2)] or 0
			check("B40 slows take at most 10% of the boss's speed", #fast >= 3 and median >= 0.85, string.format("%d chase frames, median %.2f of its speed", #fast, median))
		end
		-- victory
		local offersBefore = offers
		local endsBefore = #ends
		local resultsBefore = #results
		boss = Spawner.Boss
		if boss then
			Spawner.Damage(boss, boss.HP + 10, rp)
			Spawner.Damage(boss, 1e9, rp) -- a second hit in the same frame: no double kill
		end
		local victoryAt = nil
		for _ = 1, 40 do
			advance(0.1, 20)
			if st:GetAttribute("RunStage") == "Victory" then
				victoryAt = victoryAt or os.clock()
			end
			if #ends > endsBefore then
				break
			end
		end
		local res = results[#results]
		check("B41 the boss's death is the victory, once", #ends == endsBefore + 1 and ends[#ends] == true and st:GetAttribute("RunStage") == "Victory" and st:GetAttribute("Phase") == "Results",
			string.format("ends %d, stage %s, phase %s", #ends - endsBefore, tostring(st:GetAttribute("RunStage")), tostring(st:GetAttribute("Phase"))))
		check("B42 results say Won (a full expedition)", #results > resultsBefore and res and res.Won == true and res.StagesCleared == Config.Stages.WinMinStages, res and tostring(res.Won))
		local gs = rp.GoldSettlement
		check("B42b the victory settles once, as an extraction (all run gold kept, win bonus paid)", rp.Committed == true and rp.Extracted == true and rp.WinPaid == true and gs ~= nil and gs.Rate == 1,
			gs and string.format("earned %d kept %d", gs.Earned, gs.Retained) or "no settlement")
		check("B43 terminal lock: spawns and hazards cleared, offers cancelled, no new panel", #Spawner.Active == 0 and Hazards.Count() == 0 and rp.Offer == nil and rp.PendingLevels == 0
			and offers == offersBefore and not Spawner.IsDirector(), string.format("active %d hazards %d offers +%d", #Spawner.Active, Hazards.Count(), offers - offersBefore))
		-- a wipe after the victory changes nothing
		rp.InvulnUntil = 0
		RM.DamagePlayer(rp, 1e6, "Test")
		RM.EndRun(false)
		advance(0.5, 10)
		check("B44 a later wipe cannot turn it into a defeat", #ends == endsBefore + 1 and st:GetAttribute("RunStage") == "Victory")
		backToLobby()
		check("B45 back in the lobby the run stage is cleared", st:GetAttribute("RunStage") == nil and st:GetAttribute("BeaconPos") == nil and EnemyData.RowOverride == nil)
	end
end

------------------------------------------------------------------------------------------
-- C. solo wipe = defeat once; overtime; a stuck enemy
------------------------------------------------------------------------------------------
if parts.C then
	preview.log("---- C defeat")
	startRun({ me }, "Cliffwood")
	local rp = RM.GetRunPlayer(me)
	run(1)
	-- overtime
	SM.SetDirectorClock(17 * 60)
	run(2)
	local S = Spawner.DirectorStats
	local t = SM.DirectorMinutes()
	check("C1 overtime: labelled, spawn rate x min(1.5, 1 + 0.10 (t-15))", st:GetAttribute("Overtime") == true and near(S.LastRate, F.SpawnRate(t, 1), 0.01) and S.LastRate > F.SpawnRate(15, 1) * 1.15,
		string.format("%.3f/s at %.2f min", S.LastRate, t))
	check("C2 no timer defeat past 15:00", st:GetAttribute("Phase") == "Running")
	-- a stuck enemy: repath, then a quiet despawn
	Spawner.SetHold("director-sim", true)
	clearEnemies()
	local spot = walkableAt(rp.Root.Position, 60)
	local stuck = spot and Spawner.Spawn("Skeleton", spot)
	local kills0 = rp.Kills
	local uid = stuck and stuck.Uid
	local repath0, despawn0 = S.StuckRepaths, S.StuckDespawns
	if stuck then
		stuck.Speed = 0
		stuck.Invulnerable = true -- the hero's weapons must not kill it first
	end
	run(14)
	check("C3 a stuck enemy repaths, then is despawned without rewards", stuck ~= nil and (not stuck.Alive or stuck.Uid ~= uid) and S.StuckRepaths > repath0
		and S.StuckDespawns > despawn0 and rp.Kills == kills0, string.format("repaths +%d despawns +%d kills +%d", S.StuckRepaths - repath0, S.StuckDespawns - despawn0, rp.Kills - kills0))
	Spawner.SetHold("director-sim", false)
	-- the wipe (with some run gold banked: a defeat keeps the loss share)
	local endsBefore = #ends
	preview.server("GoldSystem").AddRunGold(rp, 100)
	rp.InvulnUntil = 0
	rp.RevivesLeft = 0
	rp.ProductReviveUsed = true
	RM.DamagePlayer(rp, 1e6, "Test")
	advance(0.5, 10)
	RM.DamagePlayer(rp, 1e6, "Test")
	RM.EndRun(false)
	advance(0.5, 10)
	local res = results[#results]
	check("C4 a full wipe is a defeat, once", #ends == endsBefore + 1 and ends[#ends] == false and st:GetAttribute("RunStage") == "Defeat" and res and res.Won == false,
		string.format("ends +%d, stage %s", #ends - endsBefore, tostring(st:GetAttribute("RunStage"))))
	local gs = rp.GoldSettlement
	check("C5 the defeat settles once with the loss share kept", rp.Committed == true and rp.Extracted ~= true and gs ~= nil and gs.Earned >= 100 and gs.Rate < 1 and gs.Retained > 0,
		gs and string.format("earned %d kept %d (x%.2f)", gs.Earned, gs.Retained, gs.Rate) or "no settlement")
	backToLobby()
end

------------------------------------------------------------------------------------------
-- D. duo: N, a fallen teammate, the prompt, a late admission
------------------------------------------------------------------------------------------
if parts.D then
	preview.log("---- D duo")
	startRun({ me, friend }, "Cliffwood")
	local rp, frp = RM.GetRunPlayer(me), RM.GetRunPlayer(friend)
	table.clear(spawns)
	run(6)
	check("D1 two heroes: N = 2, alive cap 95", rp ~= nil and frp ~= nil and SM.PartyN() == 2 and Spawner.DirectorStats.LastCap == 95, SM.PartyN() .. " / " .. tostring(Spawner.DirectorStats.LastCap))
	local s1 = nil
	for _, s in ipairs(spawns) do
		if s.Minute then
			s1 = s
			break
		end
	end
	local entry = s1 and rosterEntry(s1.Type)
	check("D2 ordinary HP scaled for N = 2 (x 1.30)", s1 ~= nil and entry ~= nil and s1.N == 2 and near(s1.MaxHP, F.EnemyHP(entry.HP, 2, s1.Minute) * SM.EnemyHPMult() * (s1.Elite and 3 or 1), 1e-6))
	if rp and frp then
		-- the teammate falls: N stays 2
		frp.InvulnUntil = 0
		frp.RevivesLeft = 0
		frp.ProductReviveUsed = true
		RM.DamagePlayer(frp, 1e6, "Test")
		run(1)
		check("D3 a fallen teammate does not lower N", not frp.Alive and SM.PartyN() == 2)
		SM.SetDirectorClock(750)
		run(1)
		local bpos = Beacon.Position()
		local fSpot = bpos and walkableAt(bpos, 15)
		local mSpot = bpos and walkableAt(bpos, 30)
		if bpos and fSpot and mSpot then
			-- the fallen one lies beside the beacon, the living one 30 studs off (out of the revive radius)
			put(frp, fSpot)
			put(rp, mSpot)
			local okF, whyF = Beacon.TryActivate(frp)
			local okM, whyM = Beacon.TryActivate(rp)
			check("D4 a fallen hero cannot light it; a distant one cannot either", okF == false and whyF == "NotEligible" and okM == false and whyM == "TooFar", tostring(whyF) .. " / " .. tostring(whyM))
			local inSpot = nil
			for k = 0, 15 do
				local a = k * math.pi / 8
				local x, z = bpos.X + math.cos(a) * 14, bpos.Z + math.sin(a) * 14
				if HG.IsWalkable(x, z) and Vector3.new(x - fSpot.X, 0, z - fSpot.Z).Magnitude > 12 then
					inSpot = Vector3.new(x, HG.GroundY(x, z), z)
					break
				end
			end
			if inSpot then
				put(rp, inSpot)
			end
			local prompt = MapBuilder.GetArena().Model:FindFirstChild("SwarmBeacon") and MapBuilder.GetArena().Model.SwarmBeacon:FindFirstChild("BeaconPrompt", true)
			if prompt then
				prompt.Triggered:_fire(me)
			end
			advance(0.1, 10)
			check("D5 the E prompt lights it (server rules)", inSpot ~= nil and prompt ~= nil and st:GetAttribute("RunStage") == "Rally" and Beacon.Activator() == rp)
			SM.DevNextStage() -- skip the rally
			advance(0.1, 10)
			-- only the fallen teammate inside: no progress (the living hero 55 studs off)
			local outSpot = walkableAt(bpos, 55) or mSpot
			put(rp, outSpot)
			local c0 = Beacon.Charge()
			run(5, function()
				put(rp, outSpot)
			end)
			check("D6 a fallen hero inside does not charge it", st:GetAttribute("RunStage") == "Charge" and Beacon.Charge() == c0 and not frp.Alive, string.format("%.3f", Beacon.Charge()))
			put(rp, inSpot or mSpot)
			run(3, function()
				put(rp, inSpot or mSpot)
			end)
			check("D7 the living hero inside charges it", Beacon.Charge() > c0)
		else
			check("D4 beacon spots", false)
		end
		-- a late admission raises N; a leaver does not lower it
		local late = preview.addPlayer("LateHero", 3)
		preview.playerJoined(late)
		for _ = 1, 20 do
			if DS.GetData(late) then
				break
			end
			advance(0.5, 10)
		end
		local added = RM.AddLatePlayer(late)
		advance(0.5, 10)
		check("D8 a late admission raises N to 3 (future spawns)", added == true and SM.PartyN() == 3 and st:GetAttribute("PartyN") == 3, tostring(added) .. " " .. SM.PartyN())
		preview.removePlayer(late)
		advance(1, 10)
		check("D9 a leaver does not lower N", SM.PartyN() == 3)
		-- the DEV path finishes the charge: the boss is scaled for N = 3 (the late admission)
		local spawnsBefore = bossSpawns
		SM.DevNextStage()
		run(1)
		local boss = Spawner.Boss
		check("D10 a full charge spawns the boss once, scaled for N = 3", bossSpawns == spawnsBefore + 1 and boss ~= nil and boss.SpawnN == 3
			and near(boss.MaxHP, F.BossHP(3, boss.SpawnMinute), 1e-6) and near(boss.DmgScale, F.PartyDamage(3), 1e-6), boss and string.format("%.0f HP", boss.MaxHP) or "none")
		-- the victory is shared with the fallen teammate who stayed
		local endsBefore = #ends
		SM.DevNextStage() -- kills the boss (no killer): its collapse, then the victory
		for _ = 1, 40 do
			advance(0.1, 10)
			if #ends > endsBefore then
				break
			end
		end
		check("D11 a fallen teammate who stayed shares the victory", #ends == endsBefore + 1 and ends[#ends] == true and frp.Extracted == true and rp.Extracted == true
			and frp.Committed == true, string.format("ends +%d", #ends - endsBefore))
	end
	backToLobby()
end

------------------------------------------------------------------------------------------
-- E. the old stage loop elsewhere
------------------------------------------------------------------------------------------
if parts.E then
	preview.log("---- E legacy")
	startRun({ me }, "Forest")
	run(1)
	check("E1 a Forest run keeps the stage loop (portal, no director)", not SM.IsDirector() and not Spawner.IsDirector() and SM.PortalPosition() ~= nil and st:GetAttribute("RunStage") == nil and EnemyData.RowOverride == nil)
	backToLobby()
	Dir.LegacyStages = true
	startRun({ me }, "Cliffwood")
	run(1)
	check("E2 LegacyStages = true: Cliffwood plays the stage loop again", not SM.IsDirector() and SM.PortalPosition() ~= nil and st:GetAttribute("Arena") == "Cliffwood")
	Dir.LegacyStages = false
	backToLobby()
end

local logged = errorCount()
check("Z no step or remote-handler failures logged", logged == 0, logged)
MapRay.uninstall()
preview.log(if fails == 0 then string.format("PASS director-sim (%d checks)", passes) else string.format("FAIL: director-sim (%d of %d checks)", fails, passes + fails))
