-- perf-sim: a repeatable dense-swarm benchmark. Boots the REAL server and client (like
-- weapons-sim), starts a solo run with every weapon maxed then evolved, keeps exactly N
-- enemies alive around a hero walking a circle, and prints per phase:
--   * server ms per frame for every GameServer system (exclusive time: nested work such as
--     Hazards inside EnemyAI, or a client handler fired by a remote, is charged to itself)
--   * client callbacks ms per frame (EnemyRenderer / VFX / DamageText / Telegraphs / Hud ...)
--   * traffic per second: RemoteEvent calls + estimated KB, changed attributes (= what
--     Roblox replicates) by name, property writes, BulkMoveTo parts, workspace queries
--   * instances created / destroyed, instances alive (DataModel tree / all), Lua heap
-- The mock profiler is mock/profile.luau. Lune on Linux is not Roblox on a phone: compare
-- runs of this scene with each other (before / after a change), never with a device.
--   render.sh perf-sim --studio --max-time 400
--   --set enemies=200,400,600   phases (enemy counts; the pool and MaxLive are raised to fit)
--   --set seconds=10            simulated seconds measured per phase (after 2 s settling)
--   --set soak=120              then a soak at the last count: instance / heap growth every 20 s
--   --set client=off            server only (no client scripts)
--   --set weapons=Whip,Garlic   the build (default six classic weapons, evolved; all = every weapon)
--   --set top=14                rows per table
--   --set scenario=swarm        what to measure, comma list (default swarm; all = every one):
--       swarm     the N-enemy ring phases above (stage 1)
--       caravan   the Lost Caravan defence with its waves, the hero in the ring
--       boss      each new boss (BriarSentinel, FrostboundColossus; --set bosses=Id,Id)
--                 held in phase 2 (HP kept at 40%) with its hazards live
--       endless   an Endless run moved to stage --set stage=12 (DEV next stage), the real
--                 spawner at its Endless multipliers
--     these use the real spawner (the normal MaxLive) instead of the benchmark ring, and
--     add live counts per phase: server hazards, client telegraphs, CombatFx parts.
local Players = game:GetService("Players")
local Config = preview.shared("Config")
local args = preview.args
local counts = {}
for n in string.gmatch(args.enemies or "200,400,600", "%d+") do
	table.insert(counts, tonumber(n))
end
local maxN = 0
for _, n in ipairs(counts) do
	maxN = math.max(maxN, n)
end
local seconds = tonumber(args.seconds) or 10
local soak = tonumber(args.soak) or 0
local top = tonumber(args.top) or 14
local withClient = args.client ~= "off"
local scenario = args.scenario or "swarm"
local function want(name: string): boolean
	return scenario == "all" or string.find("," .. scenario .. ",", "," .. name .. ",", 1, true) ~= nil
end
local normalMaxLive = Config.Enemies.MaxLive

-- room for the benchmark swarm (the real game caps MaxLive at 200)
Config.Enemies.PoolSize = math.max(Config.Enemies.PoolSize, maxN + 10)
Config.Enemies.MaxLive = maxN

-- time every server system: wrapped before GameServer captures the Step functions
local P = preview
local Hazards = preview.server("Hazards")
local Telegraphs, CombatFx = nil, nil
local function wrap(mod, field, label)
	local f = mod[field]
	if type(f) ~= "function" then
		return
	end
	mod[field] = function(...)
		P.profileEnter(label)
		local out = table.pack(f(...))
		P.profileLeave()
		return table.unpack(out, 1, out.n)
	end
end
for _, name in ipairs({ "RunManager", "StageManager", "EnemySpawner", "EnemyAI", "WeaponSystem", "XPSystem", "ItemSystem", "LootSystem", "LevelUpSystem", "AchievementService", "RunModifiers", "LeaderboardService", "DamageNumbers", "Fx" }) do
	wrap(preview.server(name), "Step", "S " .. name)
end
wrap(preview.server("Hazards"), "Step", "S Hazards (in EnemyAI)")
wrap(preview.server("BiomeHazards"), "Step", "S BiomeHazards (in StageManager)")
wrap(preview.server("BossAI"), "Step", "S BossAI (in EnemyAI)")
local Spawner = preview.server("EnemySpawner")
wrap(Spawner, "Spawn", "S EnemySpawner.Spawn")
wrap(Spawner, "Damage", "S EnemySpawner.Damage")
wrap(Spawner, "Kill", "S EnemySpawner.Kill")
wrap(preview.server("XPSystem"), "SpawnGem", "S XPSystem.SpawnGem")
wrap(preview.server("GoldSystem"), "OnKill", "S GoldSystem.OnKill")

preview.setFrameLayout(false) -- the mock's GUI layout is not game code (and very slow)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
if withClient then
	preview.startClient()
	preview.advance(1)
	-- client helpers called from the frame callbacks (time shows inside the callback rows'
	-- totals as these separate rows; calls/frame tells how often models are built)
	wrap(preview.client("ModelLibrary"), "Enemy", "C ModelLibrary.Enemy (new enemy model)")
	wrap(preview.client("Telegraphs"), "Puff", "C Telegraphs.Puff (spawn dust)")
	Telegraphs = preview.client("Telegraphs")
	CombatFx = preview.client("CombatFx")
end
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local EnemyAI = preview.server("EnemyAI")
local EnemyData = preview.shared("EnemyData")
local data = DS.GetData(me)
if data then
	data.SelectedCharacter = "Knight"
	data.Settings.DamageNumbers = true -- measure the floating numbers too
end

local function pickLevels()
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
		preview.advance(0.1)
	end
end
local function send(name, ...)
	preview.remote(name):FireServer(...)
	preview.advance(0.2)
	pickLevels()
end

if want("endless") then
	send("SetEndless", true)
end
send("StartRun", "Solo")
preview.advance(1)
pickLevels()
me:SetAttribute("DamageNumbers", true)
local rp = RM.GetRunPlayer(me)
if not rp then
	preview.warn("perf-sim: no run player")
	return
end
-- a full late-run build: six evolved weapons (Config.Slots.Weapons), or --set weapons=all
local build = args.weapons == "all" and nil or string.split(args.weapons or "Whip,MagicOrb,Knives,Garlic,Lightning,HolyWater", ",")
preview.server("LevelUpSystem").DevWeapons(rp, false, build or preview.shared("WeaponData").Order)
send("DevCommand", "EvolveWeapons")
rp.InvulnUntil = math.huge -- the test is about cost, not survival
rp.XPNeeded = 1e12 -- no level-up pauses during the measurement
local loadout = {}
for _, id in ipairs(rp.WeaponOrder) do
	table.insert(loadout, id .. (rp.Weapons[id].Evolved and "*" or tostring(rp.Weapons[id].Level)))
end

-- the swarm: this minute's melee mix (no stationary / support / ranged types, their
-- caps belong to the spawner) in a ring 14-55 studs around the hero
local mix, total = {}, 0
for id, w in pairs(EnemyData.GetSpawnRow(8 * 60).Weights) do
	local def = EnemyData.Enemies[id]
	if def and not def.Static and not def.Support and not def.Ranged and not def.IsBoss then
		table.insert(mix, { id, w })
		total += w
	end
end
table.sort(mix, function(a, b)
	return a[1] < b[1]
end)
local rng = Random.new(preview.seed * 31 + 7)
local function pickType(): string
	local roll = rng:NextNumber() * total
	for _, m in ipairs(mix) do
		roll -= m[2]
		if roll <= 0 then
			return m[1]
		end
	end
	return mix[#mix][1]
end
local target = 0
local spawnedByBench = 0
local function topUp()
	local root = rp.Root
	if not root then
		return
	end
	local p = root.Position
	local tries = 0
	while #Spawner.Active < target and tries < target * 3 do
		tries += 1
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(14, 55)
		local x, z = Spawner.ClampToArena(p.X + math.cos(a) * r, p.Z + math.sin(a) * r, 4)
		local typeId = pickType()
		if not EnemyAI.IsBlocked(x, z, EnemyData.Enemies[typeId].Radius) then
			if Spawner.Spawn(typeId, Vector3.new(x, Config.ArenaOrigin.Y, z)) then
				spawnedByBench += 1
			end
		end
	end
end

-- the hero walks a 40-stud circle around the arena centre at ~16 studs/s
local angle = 0
local c = Config.ArenaOrigin
local holdAt: Vector3? = nil -- scenarios: stand here instead of walking
local function moveHero(dt: number)
	local root = rp.Root
	if not root then
		return
	end
	if holdAt then
		rp.MoveDir = Vector3.zero
		root.CFrame = CFrame.new(holdAt + Vector3.new(0, 3, 0))
		rp.LastValidPos = root.Position
		rp.SpeedCheckTimer = 0
		return
	end
	angle += dt * 16 / 40
	local pos = Vector3.new(c.X + math.cos(angle) * 40, root.Position.Y, c.Z + math.sin(angle) * 40)
	local dir = Vector3.new(-math.sin(angle), 0, math.cos(angle))
	rp.MoveDir = dir
	rp.Facing = dir
	root.CFrame = CFrame.lookAt(pos, pos + dir)
end
local frames = 0
local onTick: (() -> ())? = nil -- scenarios: per-0.1 s hook (keep the boss alive ...)
local function run(t: number)
	local left = t
	while left > 0 do
		moveHero(0.1)
		preview.advance(0.1)
		frames += 6
		left -= 0.1
		if me:GetAttribute("Paused") then
			pickLevels()
		end
		topUp()
		if onTick then
			onTick()
		end
	end
end

local function fmt(n: number): string
	if n >= 100 then
		return string.format("%.0f", n)
	elseif n >= 10 then
		return string.format("%.1f", n)
	end
	return string.format("%.2f", n)
end
local function sorted(map, value)
	local list = {}
	for k, v in pairs(map) do
		table.insert(list, { k, value(v) })
	end
	table.sort(list, function(a, b)
		return a[2] > b[2]
	end)
	return list
end
local function line(s)
	print(s)
end

-- what the warnings in the FxBatch are (Telegraphs draws each one; kind/style per second)
local warnKinds = {}
if withClient then
	preview.remote("FxBatch").OnClientEvent:Connect(function(batch)
		if type(batch) == "table" and type(batch.w) == "table" then
			for _, w in ipairs(batch.w) do
				local key = tostring(w[2]) .. (w[2] == "circle" and ("/" .. tostring(w[7])) or (w[2] == "pop" and ("/" .. tostring(w[6])) or ""))
				warnKinds[key] = (warnKinds[key] or 0) + 1
			end
		end
	end)
end

local results = {}
local function phase(label: string, n: number, t: number)
	target = n
	topUp()
	run(2) -- settle: the swarm closes in, weapons start killing
	preview.profile(true)
	table.clear(warnKinds)
	frames = 0
	local kills0 = rp.Kills
	local alive, aliveSamples = 0, 0
	local live = { haz = 0, tel = 0, fx = {} }
	local t0 = preview.realClock()
	local left = t
	while left > 0 do
		run(math.min(1, left))
		left -= 1
		alive += #Spawner.Active
		aliveSamples += 1
		live.haz = math.max(live.haz, Hazards.Count())
		if Telegraphs then
			live.tel = math.max(live.tel, Telegraphs.Count())
		end
		if CombatFx then
			local st = CombatFx.Stats()
			for k, v in pairs(st) do
				if type(v) == "number" then
					live.fx[k] = math.max(live.fx[k] or 0, v)
				end
			end
		end
	end
	local real = preview.realClock() - t0
	local wk = {}
	for k, v in pairs(warnKinds) do
		table.insert(wk, string.format("%s %.1f", k, v / t))
	end
	table.sort(wk)
	table.clear(warnKinds)
	local rep = preview.profileReport()
	preview.profile(false)
	local inTree, all = preview.liveInstances()
	local heap = collectgarbage("count")
	local kills = rp.Kills - kills0
	local per = 1000 / frames -- ms per frame from seconds
	line(string.format("\n=== %s: %d enemies target, %.0f alive avg, %d frames, %.1f s real (%.1f ms/frame all-in), kills %d (%.0f/s) ===",
		label, n, alive / math.max(1, aliveSamples), frames, real, real * 1000 / frames, kills, kills / t))
	local server, client, mock = 0, 0, 0
	local srows, crows = {}, {}
	for name, v in pairs(rep.time) do
		if string.sub(name, 1, 2) == "S " or string.sub(name, 1, 8) == "[label] " then
			-- server systems, and the MicroProfiler labels (debug.profilebegin) inside them
			server += v.excl
			table.insert(srows, { string.sub(name, 1, 2) == "S " and string.sub(name, 3) or name, v.excl * per, v.calls / frames })
		elseif string.sub(name, 1, 6) == "[mock]" then
			mock += v.excl
		else
			client += v.excl
			table.insert(crows, { name, v.excl * per, v.calls / frames })
		end
	end
	table.sort(srows, function(a, b)
		return a[2] > b[2]
	end)
	table.sort(crows, function(a, b)
		return a[2] > b[2]
	end)
	local fxParts = {}
	for k, v in pairs(live.fx) do
		table.insert(fxParts, k .. " " .. fmt(v))
	end
	table.sort(fxParts)
	line(string.format("live peaks: server hazards %d, client telegraphs %d, CombatFx [%s]", live.haz, live.tel, table.concat(fxParts, ", ")))
	line(string.format("server systems: %.3f ms/frame (exclusive)", server * per))
	for i = 1, math.min(top, #srows) do
		line(string.format("  %-36s %8.3f ms/frame  %6.2f calls/frame", srows[i][1], srows[i][2], srows[i][3]))
	end
	line(string.format("client callbacks: %.3f ms/frame   (mock tween+GUI layout: %.3f ms/frame, not game code)", client * per, mock * per))
	for i = 1, math.min(top, #crows) do
		line(string.format("  %-52s %8.3f ms/frame  %6.2f calls/frame", crows[i][1], crows[i][2], crows[i][3]))
	end
	local rrows = sorted(rep.remotes, function(v)
		return v.bytes
	end)
	line("remotes per second (calls, ~KB):")
	for i = 1, math.min(top, #rrows) do
		local r = rep.remotes[rrows[i][1]]
		line(string.format("  %-40s %7.1f/s  %7.2f KB/s", rrows[i][1], r.calls / t, r.bytes / 1024 / t))
	end
	local arows = sorted(rep.attrs, function(v)
		return v
	end)
	local attrTotal = 0
	for _, v in pairs(rep.attrs) do
		attrTotal += v
	end
	local parts = {}
	for i = 1, math.min(top, #arows) do
		table.insert(parts, arows[i][1] .. " " .. fmt(arows[i][2] / t))
	end
	line(string.format("warnings/s (Fx.Warn kinds): [%s]", table.concat(wk, ", ")))
	line(string.format("attribute changes: %.0f/s  [%s]", attrTotal / t, table.concat(parts, ", ")))
	local prows = sorted(rep.props, function(v)
		return v
	end)
	parts = {}
	for i = 1, math.min(10, #prows) do
		table.insert(parts, prows[i][1] .. " " .. fmt(prows[i][2] / t))
	end
	line(string.format("property writes/s: [%s]", table.concat(parts, ", ")))
	parts = {}
	local news, propBy = {}, {}
	for k, v in pairs(rep.counters) do
		if string.sub(k, 1, 4) == "new " then
			news[string.sub(k, 5)] = v
		elseif string.sub(k, 1, 5) == "prop " then
			propBy[string.sub(k, 6)] = v
		else
			table.insert(parts, k .. " " .. fmt(v / t) .. "/s")
		end
	end
	table.sort(parts)
	line(string.format("counters: %s", table.concat(parts, ", ")))
	local nrows = sorted(news, function(v)
		return v
	end)
	parts = {}
	for i = 1, math.min(8, #nrows) do
		table.insert(parts, nrows[i][1] .. " " .. fmt(nrows[i][2] / t))
	end
	line(string.format("instances created/s by class and frame: [%s]", table.concat(parts, ", ")))
	local wrows = sorted(propBy, function(v)
		return v
	end)
	parts = {}
	for i = 1, math.min(10, #wrows) do
		table.insert(parts, wrows[i][1] .. " " .. fmt(wrows[i][2] / t))
	end
	line(string.format("property writes/s by frame: [%s]", table.concat(parts, ", ")))
	line(string.format("instances: created %.0f/s, destroyed %.0f/s; alive in tree %d, alive all %d; Lua heap %.1f MB",
		rep.created / t, rep.destroyed / t, inTree, all, heap / 1024))
	table.insert(results, { label = label, n = n, server = server * per, client = client * per, tree = inTree, all = all, heap = heap })
end

line(string.format("perf-sim: hero %s, loadout %s; mix %d types; client %s", tostring(rp.CharacterId), table.concat(loadout, " "), #mix, withClient and "on" or "off"))
if want("swarm") then
	for _, n in ipairs(counts) do
		phase(tostring(n), n, seconds)
	end
end

-- the scenarios: the real spawner, normal cap
local SM = preview.server("StageManager")
local function clearSwarm()
	target = 0
	Config.Enemies.MaxLive = normalMaxLive
	for i = #Spawner.Active, 1, -1 do
		local e = Spawner.Active[i]
		if e and not e.Boss then
			Spawner.Despawn(e)
		end
	end
end
local function toExplore()
	for _ = 1, 80 do
		run(0.5)
		if SM.GetPhase() == "Explore" then
			return true
		end
	end
	return false
end

if want("caravan") then
	clearSwarm()
	local CE = preview.server("CaravanEvent")
	local cv = CE.Get()
	if not cv then
		line("\n=== caravan: BLOCKED (no caravan on this stage) ===")
	else
		holdAt = cv.Pos + Vector3.new(3, 0, 0)
		run(1)
		phase(string.format("caravan (%s)", tostring(cv.State)), 0, math.min(seconds, Config.Caravan.HoldSeconds - 4))
		line(string.format("caravan: state %s, waves %d", tostring(cv.State), cv.Waves))
		holdAt = nil
	end
end

if want("boss") then
	for _, id in ipairs(string.split(args.bosses or "BriarSentinel,FrostboundColossus", ",")) do
		clearSwarm()
		SM.ForceBoss(id)
		if SM.GetPhase() ~= "Explore" then
			SM.DevNextStage()
			toExplore()
		end
		if not SM.DevActivate() then
			line(string.format("\n=== boss %s: BLOCKED (phase %s) ===", id, SM.GetPhase()))
			continue
		end
		onTick = function()
			local b = Spawner.Boss
			if b and b.Alive then
				b.HP = math.max(b.HP, b.MaxHP * 0.4) -- phase 2, never dies
			end
		end
		run(6) -- entrance + first attacks
		phase("boss " .. id, 0, seconds)
		onTick = nil
		SM.DevNextStage() -- the boss and its hazards go with the stage
		toExplore()
	end
	SM.ForceBoss(nil)
end

if want("endless") then
	clearSwarm()
	local goal = tonumber(args.stage) or 12
	for _ = 1, goal + 2 do
		if SM.GetStage() >= goal then
			break
		end
		SM.DevNextStage()
		toExplore()
	end
	run(8) -- the spawner fills to its target
	line(string.format("\nendless: stage %d, HP x%.2f damage x%.2f spawn x%.2f (endless %s)", SM.GetStage(), SM.EnemyHPMult(), SM.DamageMult(), SM.SpawnMult(), tostring(SM.IsEndless())))
	phase("endless s" .. SM.GetStage(), 0, seconds)
end

if soak > 0 then
	local n = counts[#counts]
	line(string.format("\n=== soak: %d enemies for %d s (instances in tree / all / Lua heap MB every 20 s) ===", n, soak))
	target = n
	local done = 0
	while done < soak do
		local step = math.min(20, soak - done)
		run(step)
		done += step
		local inTree, all = preview.liveInstances()
		line(string.format("  t+%3ds  alive %3d  tree %6d  all %6d  heap %6.1f MB  kills %s", done, #Spawner.Active, inTree, all, collectgarbage("count") / 1024, tostring(rp.Kills)))
	end
end

line("\nsummary (ms per frame, exclusive):")
for _, r in ipairs(results) do
	line(string.format("  %-6s server %7.3f  client %7.3f  instances tree %d all %d  heap %.1f MB", r.label, r.server, r.client, r.tree, r.all, r.heap / 1024))
end
preview.metrics.perf = results
-- the picture: the swarm from the run camera
