--[[
	scenes/lib/perfcliff.luau - perf-sim's "cliffwood" scenario (perf-sim --set scenario=cliffwood).
	The redesign's worst case on the REAL server: a 4-player party (Squad) on the Cliffwood beacon
	run (the real height grid through lib/mapray), the director at minute 10 (its roster), about
	`enemies` (default 200 = the N = 4 alive cap) ordinary enemies kept alive, every hero with a
	maximum build: 4 weapons at rank 5 with every evolution that exists (Scrap Shot, Toast Toss,
	Bubble Bomb, Yarn Bomb), Seed Slinger plants, Magic Orb orbits, Vortex pulls, and 4 loot
	passives at rank 5 (crit, splinter procs, damage, attack speed). The heroes walk circles on
	walkable ground (invulnerable: the scene measures cost, not survival).

	Prints (Lune mock numbers, NOT device FPS, NOT Studio; compare runs of this scene only):
	  * server ms per frame per module (exclusive: GameServer Step wrappers "S <Module>", the
	    debug.profilebegin labels inside them, and every server signal handler by file:line)
	  * replication per second: RemoteEvent calls and bytes (ProjectileBatch buffers counted by
	    length), the XP shard part attributes (Active / Base / Fly / Owner / Fade), every changed
	    attribute, property writes, BulkMoveTo parts
	  * instances (tree / all), connections, waiting threads, Lua heap every `window` seconds
	  * worst single-call spikes (host clock): run start (StartTeamRun), map build
	    (MapBuilder.BuildArena), HeightGrid.Build, the boss spawn (SpawnBoss), a chest reward
	    (LootSystem.Step frame with a purchase + QueueChoice for 4 heroes), level choices
	  * `cycles` (default 10) run / return cycles (start a Squad run, play 15 s, everyone back to
	    the lobby): instances, connections, threads and heap per cycle (the leak check; the lobby
	    queue / teleport itself has no mock here: StartTeamRun is the run server's entry)
	Arguments: --set seconds=120 (measured seconds), enemies=200, window=30, cycles=10,
	client=on (also run the client scripts; default off), top=25.
]]

local M = {}

function M.run()
	local P = preview
	local args = P.args
	local seconds = tonumber(args.seconds) or 120
	local target = tonumber(args.enemies) or 200
	local window = tonumber(args.window) or 30
	local cycles = tonumber(args.cycles) or 10
	local top = tonumber(args.top) or 25
	local withClient = args.client == "on"
	local MapRay = lib("mapray")
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local ServerScriptService = game:GetService("ServerScriptService")

	local function line(s: string)
		P.log(s)
	end
	local fails = 0
	local function check(name: string, ok: boolean, detail: any?)
		if not ok then
			fails += 1
		end
		line(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
	end

	local me = Players.LocalPlayer
	local players = { me }
	for i = 2, 4 do
		table.insert(players, P.addPlayer("Perf" .. i, i))
	end

	-- every GameServer Step, wrapped before GameServer captures them
	local function wrap(mod, field: string, label: string)
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
	for _, name in ipairs({ "RunManager", "StageManager", "Walkthrough", "HeightGrid", "EnemySpawner", "EnemyAI", "WeaponSystem", "XPSystem", "ItemSystem",
		"FinalStand", "LootSystem", "CaravanEvent", "LevelUpSystem", "AchievementService", "RunModifiers", "LeaderboardService", "DamageNumbers",
		"Ultimate", "MetaService", "DailyQuests", "ComebackGift", "TeamCombo", "HeroSong", "Fx" }) do
		local ok, mod = pcall(P.server, name)
		if ok and type(mod) == "table" then
			wrap(mod, "Step", "S " .. name)
		end
	end
	-- the LootSystem frame that completes a chest hold (purchase + 4 choices + feedback); wrapped
	-- before GameServer captures the Step function
	local chestFrame = { Max = 0, N = 0 }
	do
		local LootMod, GoldMod = P.server("LootSystem"), P.server("GoldSystem")
		local stepFn = LootMod.Step
		LootMod.Step = function(...)
			local bought0 = GoldMod.ChestsBought()
			local t0 = P.realClock()
			local out = table.pack(stepFn(...))
			if GoldMod.ChestsBought() ~= bought0 then
				chestFrame.Max = math.max(chestFrame.Max, (P.realClock() - t0) * 1000)
				chestFrame.N += 1
			end
			return table.unpack(out, 1, out.n)
		end
	end
	wrap(P.server("Hazards"), "Step", "S Hazards (in EnemyAI)")
	wrap(P.server("BiomeHazards"), "Step", "S BiomeHazards (in StageManager)")
	wrap(P.server("BossAI"), "Step", "S BossAI (in EnemyAI)")

	-- worst single calls (host clock, inclusive)
	local spikes: { [string]: { Max: number, N: number, Sum: number } } = {}
	local function spike(mod, field: string, label: string)
		local f = mod[field]
		if type(f) ~= "function" then
			return
		end
		mod[field] = function(...)
			local t0 = P.realClock()
			local out = table.pack(f(...))
			local d = (P.realClock() - t0) * 1000
			local s = spikes[label] or { Max = 0, N = 0, Sum = 0 }
			s.Max = math.max(s.Max, d)
			s.N += 1
			s.Sum += d
			spikes[label] = s
			return table.unpack(out, 1, out.n)
		end
	end

	P.setFrameLayout(false)
	P.forceMeshesUploaded()
	P.startServer()
	P.advance(1)
	if withClient then
		P.startClient()
		P.advance(1)
	end
	local RM = P.server("RunManager")
	local SM = P.server("StageManager")
	local HG = P.server("HeightGrid")
	local Spawner = P.server("EnemySpawner")
	local MapBuilder = P.server("MapBuilder")
	local DS = P.server("DataService")
	local LU = P.server("LevelUpSystem")
	local Loot = P.server("LootSystem")
	local Gold = P.server("GoldSystem")
	local EnemyAI = P.server("EnemyAI")
	local Config = require(ReplicatedStorage.Shared.Config)
	local RunConfig = require(ReplicatedStorage.SwarmV2.Run.RunConfig)
	local Beacon = P.require(ServerScriptService.SwarmV2.Run.Beacon)
	local st = ReplicatedStorage:WaitForChild("SwarmState")
	MapRay.install(function()
		return MapBuilder.GetArena()
	end)
	spike(RM, "StartTeamRun", "run start (RunManager.StartTeamRun)")
	spike(MapBuilder, "BuildArena", "map build (MapBuilder.BuildArena)")
	spike(HG, "Build", "HeightGrid.Build")
	spike(Spawner, "SpawnBoss", "boss spawn (EnemySpawner.SpawnBoss)")
	spike(LU, "QueueChoice", "a queued level / chest choice (LevelUpSystem.QueueChoice)")
	spike(Gold, "BuyChest", "chest purchase (GoldSystem.BuyChest)")
	local CLASSES = { "ruckus", "toastmaster", "captain_croak", "barry_plotter" }
	local BUILDS = {
		ruckus = { "ScrapToss", "YarnBomb", "MagicOrb", "Vortex" },
		toastmaster = { "ToastVolley", "BubbleBomb", "Whip", "MagicOrb" },
		captain_croak = { "BubbleBomb", "ScrapToss", "Vortex", "Whip" },
		barry_plotter = { "SeedSlinger", "ToastVolley", "YarnBomb", "MagicOrb" },
	}
	local PASSIVES = { "PocketDynamo", "RatchetTimer", "LuckyButton", "SplinterBadge" }

	local function backToLobby()
		for _ = 1, 60 do
			if st:GetAttribute("Phase") == "Lobby" then
				return true
			end
			for _, rp in ipairs(RM.GetRunPlayers()) do
				if st:GetAttribute("Phase") == "Running" then
					pcall(RM.AbandonRun, rp)
				end
			end
			for _, p in ipairs(players) do
				if p == me then
					pcall(function()
						P.remote("ReturnToLobby"):FireServer("menu")
					end)
				else
					pcall(P.fireServerAs, p, "ReturnToLobby", "menu")
				end
			end
			P.advance(1, 10)
		end
		return st:GetAttribute("Phase") == "Lobby"
	end

	local function startSquad(): { any }?
		backToLobby()
		for i, p in ipairs(players) do
			local data = DS.GetData(p)
			if data then
				data.OwnedCharacters[CLASSES[i]] = true
			end
			RM.SetAdmittedClass(p, CLASSES[i])
		end
		if not RM.StartTeamRun(players, "Squad", "Cliffwood", me) then
			return nil
		end
		P.advance(0.5, 30)
		local rps = {}
		for _, p in ipairs(players) do
			local rp = RM.GetRunPlayer(p)
			if not rp then
				return nil
			end
			rp.InvulnUntil = math.huge
			table.insert(rps, rp)
		end
		return rps
	end

	local function maxBuild(rp)
		local list = BUILDS[rp.CharacterId] or BUILDS.ruckus
		for id in pairs(rp.Weapons) do
			rp.Weapons[id] = nil
		end
		table.clear(rp.WeaponOrder)
		for _, id in ipairs(list) do
			rp.Weapons[id] = { Id = id, Level = 5, Rank = 5, Evolved = false, Timer = 0.3, Live = {}, Growth = 0 }
			table.insert(rp.WeaponOrder, id)
		end
		for id in pairs(rp.Passives) do
			rp.Passives[id] = nil
		end
		table.clear(rp.PassiveOrder)
		for _, id in ipairs(PASSIVES) do
			rp.Passives[id] = 5
			table.insert(rp.PassiveOrder, id)
		end
		LU.DevWeapons(rp, true) -- every weapon with an evolution evolves; recomputes the sheet
		rp.XPNeeded = 1e12 -- no level panels during the measurement
	end

	-- heroes walk 30-stud circles around their own anchors on walkable ground
	local anchors = {}
	local function walk(rps, dt: number)
		for i, rp in ipairs(rps) do
			local root = rp.Root
			if root and rp.Alive then
				local a = anchors[i]
				if not a then
					a = { C = root.Position, Ang = i * math.pi / 2, Dir = 1, Off = root.Position.Y - HG.GroundY(root.Position.X, root.Position.Z) }
					anchors[i] = a
				end
				local nextAng = a.Ang + a.Dir * dt * 16 / 30
				local x, z = a.C.X + math.cos(nextAng) * 30, a.C.Z + math.sin(nextAng) * 30
				if not HG.IsWalkable(x, z) then
					a.Dir = -a.Dir
				else
					a.Ang = nextAng
					local p = Vector3.new(x, HG.GroundY(x, z) + a.Off, z)
					local dir = Vector3.new(-math.sin(nextAng), 0, math.cos(nextAng)) * a.Dir
					root.CFrame = CFrame.lookAt(p, p + dir)
					rp.MoveDir, rp.Facing = dir, dir
				end
				rp.LastValidPos = root.Position
				rp.SpeedCheckTimer = 0
				if rp.Offer and rp.OfferSeq then
					if rp.Player == me then
						P.remote("LevelUpChoose"):FireServer(1, rp.OfferSeq)
					else
						P.fireServerAs(rp.Player, "LevelUpChoose", 1, rp.OfferSeq)
					end
				end
			end
		end
	end

	-- keeps `target` ordinary enemies alive (the director spawns too; this tops it up)
	local weights = Spawner.DirectorWeights(10)
	local mix, total = {}, 0
	for id, w in pairs(weights) do
		table.insert(mix, { id, w })
		total += w
	end
	table.sort(mix, function(a, b)
		return a[1] < b[1]
	end)
	local rng = Random.new(7)
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
	local topped = 0
	local function topUp(rps)
		local tries = 0
		while Spawner.OrdinaryAlive() < target and tries < 40 do
			tries += 1
			local rp = rps[rng:NextInteger(1, #rps)]
			local typeId = pickType()
			local def = require(ReplicatedStorage.Shared.EnemyData).Enemies[typeId]
			local pos = Spawner.SpawnPoint(def and def.Radius or 1.5, nil, rp)
			if pos and Spawner.Spawn(typeId, pos, { Elite = rng:NextNumber() < 0.05 }) then
				topped += 1
			end
		end
	end

	local function play(rps, t: number, onTick: (() -> ())?)
		local left = t
		local dt = 1 / 30
		local acc = 0
		while left > 0 and st:GetAttribute("Phase") == "Running" do
			walk(rps, dt)
			P.advance(dt, 30)
			left -= dt
			acc += dt
			if acc >= 0.2 then
				acc = 0
				topUp(rps)
				if onTick then
					onTick()
				end
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
	local function activeShards(): number
		local n = 0
		local folder = workspace:FindFirstChild("SwarmGems")
		for _, g in ipairs(folder and folder:GetChildren() or {}) do
			if g:GetAttribute("Active") == true then
				n += 1
			end
		end
		return n
	end
	local function probe(): string
		local inTree, all = P.liveInstances()
		local lc = P.liveCounts()
		return string.format("tree %6d  all %6d  conns %5d  waiting %4d  deferred %3d  tweens %3d  heap %6.1f MB", inTree, all, lc.connections, lc.waiting, lc.deferred, lc.tweens, collectgarbage("count") / 1024)
	end

	------------------------------------------------------------------------------------------
	-- the dense fight
	------------------------------------------------------------------------------------------
	line("perf-sim cliffwood (offline Lune mock of the real server, NOT Studio, NOT device FPS)")
	local rps = startSquad()
	check("squad Cliffwood director run started (N = 4)", rps ~= nil and SM.IsDirector() and SM.PartyN() == 4 and HG.IsActive(), rps and SM.PartyN() or "no run")
	if not rps then
		return fails
	end
	SM.SetDirectorClock(10 * 60)
	for _, rp in ipairs(rps) do
		maxBuild(rp)
	end
	local loadouts = {}
	for _, rp in ipairs(rps) do
		local w = {}
		for _, id in ipairs(rp.WeaponOrder) do
			table.insert(w, id .. (rp.Weapons[id].Evolved and "*" or "") .. rp.Weapons[id].Rank)
		end
		table.insert(loadouts, rp.CharacterId .. ": " .. table.concat(w, " "))
	end
	line("builds: " .. table.concat(loadouts, " | ") .. " | passives " .. table.concat(PASSIVES, " ") .. " (rank 5)")
	topUp(rps)
	play(rps, 5) -- settle: the swarm closes in, plants and orbits come up
	line("start: " .. probe())

	P.profile(true)
	local frames0 = 0
	local kills0 = 0
	for _, rp in ipairs(rps) do
		kills0 += rp.Kills or 0
	end
	local t0 = P.realClock()
	local aliveSum, aliveN, aliveMin, aliveMax = 0, 0, math.huge, 0
	local liveFx = { proj = 0, patches = 0, pools = 0, burning = 0 }
	local WS = P.server("WeaponSystem")
	local done = 0
	while done < seconds do
		local stepT = math.min(window, seconds - done)
		play(rps, stepT, function()
			local n = Spawner.OrdinaryAlive()
			aliveSum += n
			aliveN += 1
			aliveMin = math.min(aliveMin, n)
			aliveMax = math.max(aliveMax, n)
			local dc = WS.DebugCounts()
			local proj = 0
			for k, v in pairs(dc) do
				if k ~= "Patches" and k ~= "Pools" and k ~= "Burning" then
					proj += v
				end
			end
			liveFx.proj = math.max(liveFx.proj, proj)
			liveFx.patches = math.max(liveFx.patches, dc.Patches or 0)
			liveFx.pools = math.max(liveFx.pools, dc.Pools or 0)
			liveFx.burning = math.max(liveFx.burning, dc.Burning or 0)
		end)
		done += stepT
		line(string.format("  t+%4ds alive %3d  shards %3d  %s", done, Spawner.OrdinaryAlive(), activeShards(), probe()))
	end
	local real = P.realClock() - t0
	local rep = P.profileReport()
	P.profile(false)
	local frames = seconds * 30
	local per = 1000 / frames
	local kills = -kills0
	for _, rp in ipairs(rps) do
		kills += rp.Kills or 0
	end
	line(string.format("\n=== cliffwood: 4 heroes, %d target, %.0f alive avg (%d..%d), %d frames, %.1f s host (%.1f ms/frame all-in), kills %d (%.0f/s), top-ups %d ===",
		target, aliveSum / math.max(1, aliveN), aliveMin, aliveMax, frames, real, real * 1000 / frames, kills, kills / seconds, topped))
	line(string.format("live peaks: hero projectiles %d, patches %d, pools %d, burning %d", liveFx.proj, liveFx.patches, liveFx.pools, liveFx.burning))
	local server, other = 0, 0
	local rows = {}
	for name, v in pairs(rep.time) do
		if string.sub(name, 1, 6) == "[mock]" then
			other += v.excl
		else
			server += v.excl
			table.insert(rows, { string.sub(name, 1, 2) == "S " and string.sub(name, 3) or name, v.excl * per, v.calls / frames })
		end
	end
	table.sort(rows, function(a, b)
		return a[2] > b[2]
	end)
	line(string.format("server (and %s) ms per frame, exclusive: %.3f   (mock tween+GUI layout %.3f, not game code)", withClient and "client" or "no client", server * per, other * per))
	for i = 1, math.min(top, #rows) do
		line(string.format("  %-60s %8.3f ms/frame  %6.2f calls/frame", rows[i][1], rows[i][2], rows[i][3]))
	end
	local rlist = {}
	for name, r in pairs(rep.remotes) do
		table.insert(rlist, { name, r.calls, r.bytes })
	end
	table.sort(rlist, function(a, b)
		return a[3] > b[3]
	end)
	line("replication: remotes per second (calls, ~KB; to every client unless personal):")
	local totalKB = 0
	for i, r in ipairs(rlist) do
		totalKB += r[3] / 1024 / seconds
		if i <= top then
			line(string.format("  %-36s %7.1f/s  %7.2f KB/s", r[1], r[2] / seconds, r[3] / 1024 / seconds))
		end
	end
	line(string.format("  remotes total ~%.2f KB/s", totalKB))
	local gemAttrs = { "Active", "Base", "Fly", "Owner", "Fade" }
	local gems = {}
	for _, a in ipairs(gemAttrs) do
		table.insert(gems, string.format("%s %s/s", a, fmt((rep.attrs[a] or 0) / seconds)))
	end
	line("XP shard part attributes: " .. table.concat(gems, ", ") .. " (Base / Owner = Vector3 / number, ~13 / 3 bytes each)")
	local alist, attrTotal = {}, 0
	for name, n in pairs(rep.attrs) do
		table.insert(alist, { name, n })
		attrTotal += n
	end
	table.sort(alist, function(a, b)
		return a[2] > b[2]
	end)
	local parts = {}
	for i = 1, math.min(14, #alist) do
		table.insert(parts, alist[i][1] .. " " .. fmt(alist[i][2] / seconds))
	end
	line(string.format("attribute changes: %.0f/s [%s]", attrTotal / seconds, table.concat(parts, ", ")))
	local plist = {}
	for name, n in pairs(rep.props) do
		table.insert(plist, { name, n })
	end
	table.sort(plist, function(a, b)
		return a[2] > b[2]
	end)
	parts = {}
	for i = 1, math.min(10, #plist) do
		table.insert(parts, plist[i][1] .. " " .. fmt(plist[i][2] / seconds))
	end
	line("property writes/s: [" .. table.concat(parts, ", ") .. "]")
	parts = {}
	local news = {}
	for k, v in pairs(rep.counters) do
		if string.sub(k, 1, 4) == "new " then
			table.insert(news, { string.sub(k, 5), v })
		elseif string.sub(k, 1, 5) ~= "prop " then
			table.insert(parts, k .. " " .. fmt(v / seconds) .. "/s")
		end
	end
	table.sort(parts)
	line("counters: " .. table.concat(parts, ", "))
	table.sort(news, function(a, b)
		return a[2] > b[2]
	end)
	parts = {}
	for i = 1, math.min(8, #news) do
		table.insert(parts, news[i][1] .. " " .. fmt(news[i][2] / seconds))
	end
	line("instances created/s by class and frame: [" .. table.concat(parts, ", ") .. "]")
	line(string.format("instances: created %.0f/s, destroyed %.0f/s", rep.created / seconds, rep.destroyed / seconds))

	------------------------------------------------------------------------------------------
	-- spikes: a chest reward for the 4 heroes, the boss spawn
	------------------------------------------------------------------------------------------
	local chest = nil
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.TeamChest and obj.State == "Ready" then
			chest = obj
			break
		end
	end
	if chest then
		Gold.AddTeamGold(5000)
		local rp = rps[1]
		RM.TeleportPlayer(rp, chest.Pos + Vector3.new(2, 0, 0))
		rp.LastValidPos = rp.Root.Position
		anchors[1] = nil
		P.advance(0.1, 30)
		P.remote("LootHold"):FireServer(chest.Id, true)
		P.advance((chest.Model:GetAttribute("Hold") or 0.4) + 0.3, 30)
		P.remote("LootHold"):FireServer(chest.Id, false)
		P.advance(0.5, 30)
	end
	check("a chest reward was measured", chestFrame.N > 0, chestFrame.N)
	SM.SetDirectorClock(13.5 * 60)
	P.advance(0.2, 30)
	if Beacon.Phase() == "Hidden" or Beacon.Phase() == "None" then
		SM.SetDirectorClock(12.5 * 60 + 1)
		P.advance(0.5, 30)
	end
	Beacon.DevActivate()
	P.advance(0.3, 30)
	Beacon.ForceCharge(1)
	P.advance(0.1, 30)
	Beacon.ForceCharge(1)
	play(rps, 3)
	check("the boss spawned once for the spike", Spawner.Boss ~= nil and spikes["boss spawn (EnemySpawner.SpawnBoss)"] ~= nil)
	play(rps, 5) -- the boss plus the swarm

	------------------------------------------------------------------------------------------
	-- run / return cycles (leak check)
	------------------------------------------------------------------------------------------
	line(string.format("\n=== %d run / return cycles (Squad on Cliffwood, 15 s each; lobby probes after each return) ===", cycles))
	backToLobby()
	P.advance(2, 10)
	local base = probe()
	line("  lobby before: " .. base)
	local first, last = nil, nil
	for c = 1, cycles do
		table.clear(anchors)
		local r2 = startSquad()
		if not r2 then
			check("cycle " .. c .. " started", false)
			break
		end
		play(r2, 15)
		backToLobby()
		P.advance(3, 10)
		local inTree, all = P.liveInstances()
		local lc = P.liveCounts()
		local row = { Tree = inTree, All = all, Conns = lc.connections, Waiting = lc.waiting, Heap = collectgarbage("count") / 1024, BySignal = lc.bySignal }
		first = first or row
		last = row
		line(string.format("  cycle %2d lobby: %s", c, probe()))
	end
	if first and last then
		local grew = {}
		for name, n in pairs(last.BySignal) do
			local d = n - (first.BySignal[name] or 0)
			if d ~= 0 then
				table.insert(grew, string.format("%s %+d", name, d))
			end
		end
		table.sort(grew)
		line(string.format("  growth cycle 1 -> %d: tree %+d, connections %+d, waiting threads %+d [%s]", cycles, last.Tree - first.Tree, last.Conns - first.Conns, last.Waiting - first.Waiting, table.concat(grew, ", ")))
		check(string.format("no per-cycle connection growth over %d cycles (<= 2 per cycle)", cycles), last.Conns - first.Conns <= 2 * math.max(1, cycles - 1), last.Conns - first.Conns)
		check(string.format("no per-cycle instance growth over %d cycles (<= 50 per cycle)", cycles), last.Tree - first.Tree <= 50 * math.max(1, cycles - 1), last.Tree - first.Tree)
	end

	line("\nworst single calls (host clock ms, inclusive; Lune mock, compare runs of this scene only):")
	local slist = {}
	for name, s in pairs(spikes) do
		table.insert(slist, { name, s })
	end
	table.sort(slist, function(a, b)
		return a[2].Max > b[2].Max
	end)
	for _, e in ipairs(slist) do
		line(string.format("  %-60s max %8.2f ms  avg %7.2f ms  calls %d", e[1], e[2].Max, e[2].Sum / math.max(1, e[2].N), e[2].N))
	end
	line(string.format("  %-60s max %8.2f ms  calls %d", "chest reward frame (LootSystem.Step with a purchase)", chestFrame.Max, chestFrame.N))
	P.metrics.perfCliffwood = { serverMs = server * per, kills = kills, seconds = seconds }
	return fails
end

return M
