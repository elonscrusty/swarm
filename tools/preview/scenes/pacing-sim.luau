-- pacing-sim: the complete beacon run measured offline (Lune mock of the REAL server, headless,
-- NOT Studio, NOT a device). A scripted player bot per hero plays a Cliffwood director run the
-- way a player would (docs/redesign/continuation/Swarm-Complete-Continuation-Prompt.md "Full-loop
-- quality targets", "Progression and personal choices", "Enemy pressure and final objective"):
--   * walks at its Humanoid.WalkSpeed on the real height grid (cliffs block; far goals follow a
--     flow field built on the grid, like the enemies' own fields)
--   * walks to the nearest ready team chest and holds it open whenever the team gold covers the
--     shared price
--   * otherwise walks to its nearest own XP shard within 30 studs
--   * otherwise walks toward the nearest enemy (stops ~6 studs short and circles it)
--   * picks the first card of every level / chest choice at once
--   * after the beacon reveal (12:30) walks to it, lights it, stays in the ring for the charge
--     and fights the Basin Breaker (fight time = its spawn -> its death)
-- Heroes are invulnerable; the damage they WOULD have taken (after the shared 0.35 s hit
-- protection, before armor) is logged per minute as the pressure.
-- Parts (--set part=solo,party,boss; default solo,party,boss):
--   solo   one Solo run per class (--set classes=all|id,id; default all twelve) to --set
--          minutes=6 (default), or the whole run with the boss for the classes in --set
--          full=id,id|all (default ruckus,granny_boom)
--   party  one 4-player run (--set partyclasses=..., default the first four classes) to the boss
--   boss   the Basin Breaker against the builds the full runs had at 13:00 (N = 1, and all four
--          together at N = 4), spawned at 13:30 near the beacon and fought by the bot
-- Per run: first enemy in reach, first hit, first kill, first level choice, first affordable
-- chest, first chest opened, the build at every minute, XP / kills / damage / chests per
-- minute, team gold per minute, chests by 12:30, the boss fight.
-- Targets print PASS / WARN (tuning measurements, not regressions); the scene FAILs only when a
-- run could not be started or measured, or a step / remote handler failed.
--   lune run tools/preview/runtime/main.luau -- --scene pacing-sim --studio --device pc
--     --max-time 40000 --set headless=on [--set part=solo --set classes=ruckus --set minutes=3]
--   --set fps=30 (simulated server frames per second; projectiles need >= 30)
--   --set maxminutes=22 (a run still going at this director minute stops there, reported)
local MapRay = lib("mapray")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local args = preview.args
local parts = {}
for _, p in ipairs(string.split(args.part or "solo,party,boss", ",")) do
	parts[p] = true
end
local FPS = tonumber(args.fps) or 30
-- tuning experiments without editing RunConfig: --set opening=Seconds:Start:FirstEnemies,
-- --set startgold=N
do
	local RC = require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig)
	if args.opening then
		local a = string.split(args.opening, ":")
		RC.Director.Spawn.Opening = { Seconds = tonumber(a[1]) or 0, Start = tonumber(a[2]) or 1, FirstEnemies = tonumber(a[3]) or 0, PartyRamp = a[4] == "1" }
	end
	if args.startgold then
		RC.Economy.Gold.StartGold = tonumber(args.startgold) or 0
	end
	local O = RC.Director.Spawn.Opening or {}
	if args.bosshpb then
		RC.Director.Boss.HPB = tonumber(args.bosshpb) or RC.Director.Boss.HPB
	end
	preview.log(string.format("tuning: opening %s s from x%s, %s first enemies, party ramp %s; start gold %s; boss HPB %s", tostring(O.Seconds), tostring(O.Start),
		tostring(O.FirstEnemies), tostring(O.PartyRamp == true), tostring(RC.Economy.Gold.StartGold), tostring(RC.Director.Boss.HPB)))
end

local me = Players.LocalPlayer
local mates = {}
for i = 2, 4 do
	table.insert(mates, preview.addPlayer("Mate" .. i, i))
end
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)

local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local HG = preview.server("HeightGrid")
local Spawner = preview.server("EnemySpawner")
local MapBuilder = preview.server("MapBuilder")
local DS = preview.server("DataService")
local XP = preview.server("XPSystem")
local Gold = preview.server("GoldSystem")
local Loot = preview.server("LootSystem")
local LU = preview.server("LevelUpSystem")
local EnemyAI = preview.server("EnemyAI")
local Config = require(ReplicatedStorage.Shared.Config)
local RunConfig = require(ReplicatedStorage.SwarmV2.Run.RunConfig)
local Beacon = preview.require(ServerScriptService.SwarmV2.Run.Beacon)
local Core = HG.Core
local st = ReplicatedStorage:WaitForChild("SwarmState")
MapRay.install(function()
	return MapBuilder.GetArena()
end)

local fails = 0
local function check(name: string, ok: boolean, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
end
local function target(name: string, ok: boolean, detail: any?)
	preview.log(string.format("%s %s%s", ok and "PASS" or "WARN", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
end
local function out(s: string)
	preview.log(s)
end
local function flat(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end
local function clock(): number
	return SM.DirectorClock()
end
local function mmss(t: number?): string
	if t == nil then
		return "never"
	end
	return string.format("%d:%04.1f", math.floor(t / 60), t % 60)
end
local function sum(t: { [any]: number }?): number
	local s = 0
	for _, v in pairs(t or {}) do
		s += v
	end
	return s
end

------------------------------------------------------------------------------------------
-- Measurement hooks (per player, by UserId: reconnect-proof)
------------------------------------------------------------------------------------------
local M: { [number]: any } = {}
local team: any = {}
local function rec(rp): any
	local id = rp and rp.Player and rp.Player.UserId
	return id and M[id] or nil
end
local function addMinute(r, field: string, amount: number)
	r[field] = r[field] or {}
	local m = math.floor(clock() / 60) + 1
	r[field][m] = (r[field][m] or 0) + amount
end

local realDamage = Spawner.Damage
Spawner.Damage = function(e, amount, rp, ...)
	local hp0 = e.Alive and e.HP or 0
	local died = realDamage(e, amount, rp, ...)
	local r = rp and rec(rp)
	if r and amount == amount and amount > 0 then
		if args.debug == "hits" and clock() < 15 then
			out(string.format("  hit t %.2f %s#%d hp %.1f -> %.1f (amount %.1f) dist %.1f", clock(), tostring(e.Type or (e.Def and e.Def.Id)), e.Uid or 0, hp0, e.HP or 0, amount, flat(e.Pos, rp.Root.Position)))
		end
		r.FirstHit = r.FirstHit or clock()
		local dealt = math.max(0, hp0 - math.max(0, e.HP or 0))
		addMinute(r, "Dealt", dealt)
		if e.Boss then
			r.BossDealt = (r.BossDealt or 0) + dealt
		end
	end
	return died
end
local realKill = Spawner.Kill
Spawner.Kill = function(e, rp, ...)
	local counted = e.Alive and not e.Boss
	local res = realKill(e, rp, ...)
	local r = rp and rec(rp)
	if r and counted then
		r.FirstKill = r.FirstKill or clock()
		addMinute(r, "Kills", 1)
	end
	return res
end
local realShard = XP.GiveShardXP
XP.GiveShardXP = function(rp, value)
	local r = rec(rp)
	if r then
		addMinute(r, "XP", value)
	end
	return realShard(rp, value)
end
local realAward = XP.Award
XP.Award = function(pos, amount, kind)
	local list = realAward(pos, amount, kind)
	for _, rp in ipairs(list or {}) do
		local r = rec(rp)
		if r then
			r.Awarded = (r.Awarded or 0) + amount
		end
	end
	return list
end
local realCredit = Gold.CreditKill
Gold.CreditKill = function(kind)
	local paid = realCredit(kind)
	if team.Gold then
		local m = math.floor(clock() / 60) + 1
		team.Gold[m] = (team.Gold[m] or 0) + paid
	end
	return paid
end
local realBuy = Gold.BuyChest
Gold.BuyChest = function()
	local ok, cost = realBuy()
	if ok and team.Chests then
		table.insert(team.Chests, { T = clock(), Cost = cost })
	end
	return ok, cost
end
local realHurt = RM.DamagePlayer
RM.DamagePlayer = function(rp, amount, cause, kind, ...)
	local r = rec(rp)
	if r and amount == amount and amount > 0 and amount < 1e6 and RM.IsSimulating() and rp.Alive then
		local now = RM.GetRunTime()
		if kind == "fall" or now >= (r.ProtUntil or 0) then
			r.ProtUntil = now + (RunConfig.Survival.HitProtectSeconds or 0.35)
			addMinute(r, "Taken", amount)
		end
	end
	return realHurt(rp, amount, cause, kind, ...)
end

------------------------------------------------------------------------------------------
-- The player bot
------------------------------------------------------------------------------------------
local SHARD_RANGE = 30
local STANDOFF = 6
local ANGLES = { 0, 0.5, -0.5, 1.0, -1.0, 1.5, -1.5, 2.1, -2.1 }

-- a flow field toward a far goal (chest, beacon) on the real grid
local function goalField(goal: Vector3): any?
	local g = HG.GetGrid()
	if not g then
		return nil
	end
	local f = Core.NewField()
	if Core.BuildField(g, f, goal.X, goal.Z, 320) then
		return f
	end
	return nil
end

local function rotate(v: Vector3, a: number): Vector3
	local c, s = math.cos(a), math.sin(a)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function place(rp, b, x: number, z: number, dir: Vector3?)
	local root = rp.Root
	local p = Vector3.new(x, HG.GroundY(x, z) + b.RootOffset, z)
	if dir and dir.Magnitude > 0.01 then
		root.CFrame = CFrame.lookAt(p, p + dir)
		rp.MoveDir, rp.Facing = dir, dir
	else
		root.CFrame = CFrame.new(p) * root.CFrame.Rotation
		rp.MoveDir = Vector3.zero
	end
	root.AssemblyLinearVelocity = Vector3.zero
	rp.LastValidPos = root.Position
	rp.SpeedCheckTimer = 0
end

-- one step toward `goal` (field: follow its gradient); returns the studs moved
local function stepToward(rp, b, goal: Vector3, dt: number, stopAt: number, field: any?): number
	local root = rp.Root
	local hum = rp.Humanoid
	local speed = hum and hum.WalkSpeed or 0
	if not root or speed <= 0 then
		rp.MoveDir = Vector3.zero
		return 0
	end
	local p = root.Position
	local dist = flat(goal, p)
	if dist <= stopAt then
		rp.MoveDir = Vector3.zero
		return 0
	end
	local dir = Vector3.new(goal.X - p.X, 0, goal.Z - p.Z).Unit
	local g = HG.GetGrid()
	if field and g then
		local fx, fz = Core.FlowDir(g, field, p.X, p.Z)
		if fx ~= 0 or fz ~= 0 then
			dir = Vector3.new(fx, 0, fz).Unit
		end
	end
	local step = math.min(dist - stopAt, speed * dt)
	for _, a in ipairs(ANGLES) do
		local d = a == 0 and dir or rotate(dir, a)
		local nx, nz = p.X + d.X * step, p.Z + d.Z * step
		if HG.IsWalkable(nx, nz) and HG.CanStep(p.X, p.Z, nx, nz) and not EnemyAI.IsBlocked(nx, nz, 1) then
			place(rp, b, nx, nz, d)
			b.Walked += step
			return step
		end
	end
	rp.MoveDir = Vector3.zero
	return 0
end

local function nearestEnemy(rp): (any?, number)
	local p = rp.Root.Position
	local best, bd = nil, math.huge
	for _, e in ipairs(Spawner.Active) do
		if e.Alive and not (e.Def and (e.Def.Object or e.Def.Static)) then
			local d = flat(e.Pos, p)
			if d < bd then
				best, bd = e, d
			end
		end
	end
	return best, bd
end

local function nearestShard(rp, range: number): Vector3?
	local folder = workspace:FindFirstChild("SwarmGems")
	if not folder then
		return nil
	end
	local id = rp.Player.UserId
	local p = rp.Root.Position
	local best, bd = nil, range
	for _, g in ipairs(folder:GetChildren()) do
		if g:GetAttribute("Active") == true and g:GetAttribute("Owner") == id and g:GetAttribute("Fly") == nil then
			local at = g:GetAttribute("Base")
			if typeof(at) == "Vector3" then
				local d = flat(at, p)
				if d < bd then
					best, bd = at, d
				end
			end
		end
	end
	return best
end

local function readyChests(): { any }
	local list = {}
	for _, obj in ipairs(Loot.Objects()) do
		if obj.Kind == "Chest" and obj.TeamChest and obj.State == "Ready" then
			table.insert(list, obj)
		end
	end
	return list
end

local function fire(rp, remote: string, ...)
	if rp.Player == me then
		preview.remote(remote):FireServer(...)
	else
		preview.fireServerAs(rp.Player, remote, ...)
	end
end

-- picks the first card of an open choice (level or chest); closes a chest reel
local function answer(rp)
	if rp.Offer and rp.OfferSeq then
		local r = rec(rp)
		if r then
			local meta = rp.OfferMeta or {}
			if meta.Source == "Chest" then
				r.ChestChoices = (r.ChestChoices or 0) + 1
			else
				r.FirstChoice = r.FirstChoice or clock()
				r.LevelChoices = (r.LevelChoices or 0) + 1
			end
		end
		fire(rp, "LevelUpChoose", 1, rp.OfferSeq)
	end
	if rp.RewardUntil and RM.EndReward then
		pcall(RM.EndReward, rp)
	end
end

local function newBot(rp)
	local root = rp.Root
	return {
		Rp = rp,
		RootOffset = root.Position.Y - HG.GroundY(root.Position.X, root.Position.Z),
		Walked = 0,
		Goal = nil :: any, -- { Kind, Obj?, Pos, Field }
		Hold = nil :: any, -- { Obj, Until }
		Skip = nil :: any,
		Orbit = (rp.Player.UserId % 2 == 0) and 1 or -1,
		Stuck = 0,
	}
end

local function circle(rp, b, centre: Vector3, dt: number, radius: number)
	local p = rp.Root.Position
	local to = Vector3.new(centre.X - p.X, 0, centre.Z - p.Z)
	local side = to.Magnitude > 0.1 and rotate(to.Unit, b.Orbit * math.pi / 2) or Vector3.new(1, 0, 0)
	if stepToward(rp, b, p + side * radius, dt, 0.5, nil) == 0 then
		b.Orbit = -b.Orbit
	end
end

-- one bot decision + move for dt
local function botStep(b, dt: number)
	local rp = b.Rp
	local r = rec(rp)
	if not rp.Root or not rp.Alive then
		return
	end
	answer(rp)
	-- a chest hold in progress
	if b.Hold then
		rp.MoveDir = Vector3.zero
		if os.clock() >= b.Hold.Until then
			fire(rp, "LootHold", b.Hold.Obj.Id, false)
			if b.Hold.Obj.State == "Opened" and r and b.Hold.Obj.OpenedBy == nil then
				b.Hold.Obj.OpenedBy = rp
				r.ChestsOpened = (r.ChestsOpened or 0) + 1
				r.FirstChest = r.FirstChest or clock()
				addMinute(r, "Chests", 1)
			end
			b.Hold = nil
			b.Goal = nil
		end
		return
	end
	local p = rp.Root.Position
	-- the objective (after the reveal)
	local stage = st:GetAttribute("RunStage")
	local bpos = Beacon.Position()
	if bpos and (stage == "BeaconAvailable" or stage == "Rally" or stage == "Charge") then
		local d = flat(bpos, p)
		if stage == "BeaconAvailable" and d <= (RunConfig.Director.Beacon.ActivateRadius or 20) - 2 then
			Beacon.TryActivate(rp)
		end
		local inner = stage == "BeaconAvailable" and 12 or 18
		if d > inner then
			if not b.Goal or b.Goal.Kind ~= "Beacon" then
				b.Goal = { Kind = "Beacon", Pos = bpos, Field = goalField(bpos) }
				if r then
					r.BeaconWalkFrom = r.BeaconWalkFrom or { T = clock(), D = d }
				end
			end
			if b.Detour and os.clock() < b.Detour.Until then
				if stepToward(rp, b, p + b.Detour.Dir * 4, dt, 0.5, nil) == 0 then
					b.Detour.Dir = -b.Detour.Dir
				end
				return
			end
			if stepToward(rp, b, bpos, dt, inner - 2, b.Goal.Field) == 0 then
				-- blocked (a tree or rock the grid does not know): side-step for a moment
				b.Stuck += dt
				if b.Stuck > 1 then
					local to = Vector3.new(bpos.X - p.X, 0, bpos.Z - p.Z)
					b.Detour = { Dir = rotate(to.Unit, (math.random() < 0.5 and 1 or -1) * math.pi / 2), Until = os.clock() + 1.2 }
				end
			else
				b.Stuck = 0
			end
			-- still far 40 s after setting off: the bot is lost (blocked, or circling a collider the
			-- grid does not know); it is put beside the beacon, and the report says so
			if r and clock() - (r.BeaconWalkFrom and r.BeaconWalkFrom.T or clock()) > 40 and not r.BeaconMoved then
				r.BeaconMoved = true
				local x, z = HG.NearestWalkable(bpos.X + 10, bpos.Z, 6)
				if x and z then
					RM.TeleportPlayer(rp, Vector3.new(x, HG.GroundY(x, z), z))
					rp.LastValidPos = rp.Root.Position
				end
			end
			return
		end
		if r and r.BeaconWalkFrom and not r.BeaconArrived then
			r.BeaconArrived = clock()
		end
		local e, ed = nearestEnemy(rp)
		if e and ed < 18 and flat(e.Pos, bpos) < inner then
			stepToward(rp, b, e.Pos, dt, STANDOFF, nil)
		end
		return
	end
	-- the boss: close in and circle it
	local boss = Spawner.Boss
	if boss and boss.Alive then
		if flat(boss.Pos, p) > 10 then
			stepToward(rp, b, boss.Pos, dt, 8, nil)
		else
			circle(rp, b, boss.Pos, dt, 6)
		end
		return
	end
	-- a chest the team can pay for
	if Gold.TeamGold() >= Gold.ChestCost() then
		if r and not r.FirstAfford then
			r.FirstAfford = clock()
		end
		if not b.Goal or b.Goal.Kind ~= "Chest" or b.Goal.Obj.State ~= "Ready" then
			local best, bd = nil, math.huge
			for _, obj in ipairs(readyChests()) do
				local d = flat(obj.Pos, p)
				if d < bd and obj ~= b.Skip then
					best, bd = obj, d
				end
			end
			b.Goal = best and { Kind = "Chest", Obj = best, Pos = best.Pos, Field = goalField(best.Pos), Since = clock() } or nil
			if r and best and not r.FirstChestDist then
				r.FirstChestDist = bd
			end
		end
		local goal = b.Goal
		if goal then
			if flat(goal.Pos, p) <= Config.Chests.InteractRadius - 1 then
				fire(rp, "LootHold", goal.Obj.Id, true)
				b.Hold = { Obj = goal.Obj, Until = os.clock() + (goal.Obj.Model:GetAttribute("Hold") or 0.4) + 0.15 }
				return
			end
			if stepToward(rp, b, goal.Pos, dt, Config.Chests.InteractRadius - 1.5, goal.Field) == 0 then
				b.Stuck += dt
				if b.Stuck > 3 then
					b.Skip = goal.Obj -- unreachable from here: another one next time
					b.Goal = nil
					b.Stuck = 0
				end
			else
				b.Stuck = 0
			end
			return
		end
	elseif b.Goal and b.Goal.Kind == "Chest" then
		b.Goal = nil
	end
	-- my shards nearby
	local shard = nearestShard(rp, SHARD_RANGE)
	if shard then
		stepToward(rp, b, shard, dt, 0.5, nil)
		return
	end
	-- the nearest enemy: walk up to it, then circle it
	local e, ed = nearestEnemy(rp)
	if e then
		if r and not r.FirstReach and ed <= 20 then
			r.FirstReach = clock()
		end
		if ed > STANDOFF + 2 then
			stepToward(rp, b, e.Pos, dt, STANDOFF, nil)
		else
			circle(rp, b, e.Pos, dt, 4)
		end
		return
	end
	rp.MoveDir = Vector3.zero
end

------------------------------------------------------------------------------------------
-- Runs
------------------------------------------------------------------------------------------
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
		pcall(function()
			preview.remote("ReturnToLobby"):FireServer("menu")
		end)
		for _, p in ipairs(mates) do
			pcall(preview.fireServerAs, p, "ReturnToLobby", "menu")
		end
		preview.advance(1, 10)
	end
	return st:GetAttribute("Phase") == "Lobby"
end

local function startRun(players: { Player }, classes: { string }): { any }?
	backToLobby()
	for i, p in ipairs(players) do
		local data = DS.GetData(p)
		if data then
			data.OwnedCharacters[classes[i]] = true
		end
		RM.SetAdmittedClass(p, classes[i])
	end
	local modes = { "Solo", "Duo", "Trio", "Squad" }
	local ok = false
	for _ = 1, 20 do
		ok = RM.StartTeamRun(players, modes[#players] or "Squad", "Cliffwood", players[1])
		if ok then
			break
		end
		preview.advance(0.5, 10)
	end
	if not ok then
		return nil
	end
	team = { Gold = {}, Chests = {}, Boss = nil }
	local rps = {}
	for _, p in ipairs(players) do
		local rp = RM.GetRunPlayer(p)
		if not rp then
			return nil
		end
		rp.InvulnUntil = math.huge
		M[p.UserId] = { Class = rp.CharacterId, Player = p.Name, Snap = {} }
		table.insert(rps, rp)
	end
	return rps
end

local function buildOf(rp): any
	local w, ps = {}, {}
	for _, id in ipairs(rp.WeaponOrder or {}) do
		local inst = rp.Weapons[id]
		if inst then
			table.insert(w, { Id = id, Rank = inst.Rank or inst.Level or 1, Evolved = inst.Evolved == true })
		end
	end
	for _, id in ipairs(rp.PassiveOrder or {}) do
		local rk = rp.Passives and rp.Passives[id]
		if type(rk) == "number" then
			table.insert(ps, { Id = id, Rank = rk })
		end
	end
	return { Weapons = w, Passives = ps, Level = rp.Level }
end

local function buildText(build): (string, number)
	local w, ranks = {}, 0
	for _, x in ipairs(build.Weapons) do
		ranks += x.Rank
		table.insert(w, x.Id .. (x.Evolved and "*" or "") .. x.Rank)
	end
	local ps = {}
	for _, x in ipairs(build.Passives) do
		ranks += x.Rank
		table.insert(ps, x.Id .. x.Rank)
	end
	return table.concat(w, " ") .. " | " .. table.concat(ps, " "), ranks
end

local function snapshot(rp, label: string)
	local r = rec(rp)
	if r then
		local b = buildOf(rp)
		local text, ranks = buildText(b)
		r.Snap[label] = { Level = rp.Level, Ranks = ranks, Build = text, Weapons = #b.Weapons, Raw = b, Kills = sum(r.Kills) }
	end
end

-- Plays until `stopAt` director seconds, the run's end or `realStop` simulated seconds.
local function play(rps: { any }, stopAt: number, realStop: number?)
	local bots = {}
	for _, rp in ipairs(rps) do
		table.insert(bots, newBot(rp))
	end
	local nextSnap = 60
	local dt = 1 / FPS
	local t0 = os.clock()
	local bossAt = nil
	local hardStop = (tonumber(args.maxminutes) or 22) * 60
	while st:GetAttribute("Phase") == "Running" and clock() < stopAt do
		if realStop and os.clock() - t0 > realStop then
			break
		end
		if clock() >= hardStop then
			out(string.format("  stopped at %s: the run did not end (beacon %s, stage %s)", mmss(clock()), tostring(Beacon.Phase()), tostring(st:GetAttribute("RunStage"))))
			break
		end
		for _, b in ipairs(bots) do
			local rp = RM.GetRunPlayer(b.Rp.Player) or b.Rp
			b.Rp = rp
			if rp.Root and rp.Root.Parent then
				botStep(b, dt)
			end
		end
		preview.advance(dt, FPS)
		if clock() >= nextSnap then
			for _, b in ipairs(bots) do
				snapshot(b.Rp, tostring(math.floor(nextSnap / 60)))
			end
			nextSnap += 60
		end
		local boss = Spawner.Boss
		if boss and boss.Alive and not team.Boss then
			team.Boss = { At = clock(), Sim = os.clock(), HP = boss.MaxHP, N = SM.PartyN(), Minute = boss.SpawnMinute }
			for _, b in ipairs(bots) do
				snapshot(b.Rp, "boss")
			end
			bossAt = os.clock()
		end
		if team.Boss and not team.Boss.Done and (st:GetAttribute("RunStage") == "Victory" or not (boss and boss.Alive)) then
			team.Boss.Done = os.clock() - team.Boss.Sim
			team.Boss.Won = st:GetAttribute("RunStage") == "Victory"
		end
		if team.Boss and bossAt and not team.Boss.Done and os.clock() - bossAt > 400 then
			local b = Spawner.Boss
			team.Boss.Left = b and b.Alive and b.HP or 0
			break -- a boss alive after 400 s: reported with its HP left
		end
		if not team.ChestsAtReveal and clock() >= (RunConfig.Director.Beacon.RevealAt or 750) then
			team.ChestsAtReveal = #team.Chests
		end
	end
	for _, b in ipairs(bots) do
		local r = rec(b.Rp)
		if r then
			r.Walked = b.Walked
		end
	end
	return bots
end

------------------------------------------------------------------------------------------
-- Reports
------------------------------------------------------------------------------------------
local function minuteRow(t: { [number]: number }?, upTo: number): string
	local cells = {}
	for m = 1, upTo do
		table.insert(cells, string.format("%d", math.floor(((t or {})[m] or 0) + 0.5)))
	end
	return table.concat(cells, " ")
end

local summary = {}
local function report(rp, label: string, upTo: number)
	local r = rec(rp)
	if not r then
		return
	end
	out(string.format("== %s [%s] (offline Lune, NOT Studio)", label, r.Class))
	local combat = r.FirstKill and (r.FirstKill - (r.FirstReach or r.FirstHit or r.FirstKill)) or nil
	out(string.format("  first enemy within 20 studs %s, first hit %s, first kill %s (combat-to-kill %s s)",
		mmss(r.FirstReach), mmss(r.FirstHit), mmss(r.FirstKill), combat and string.format("%.1f", combat) or "-"))
	out(string.format("  first level choice %s, first affordable chest %s (nearest ready chest %.0f studs), first chest opened %s",
		mmss(r.FirstChoice), mmss(r.FirstAfford), r.FirstChestDist or -1, mmss(r.FirstChest)))
	local labels = {}
	for k in pairs(r.Snap) do
		if tonumber(k) then
			table.insert(labels, tonumber(k))
		end
	end
	table.sort(labels)
	for _, m in ipairs(labels) do
		local s = r.Snap[tostring(m)]
		out(string.format("  min %2d: level %2d, ranks %2d, weapons %d, kills %4d  %s", m, s.Level, s.Ranks, s.Weapons, s.Kills, s.Build))
	end
	if r.Snap.boss then
		out(string.format("  at the boss: level %d, ranks %d  %s", r.Snap.boss.Level, r.Snap.boss.Ranks, r.Snap.boss.Build))
	end
	out("  XP collected / min:   " .. minuteRow(r.XP, upTo))
	out("  kills / min:          " .. minuteRow(r.Kills, upTo))
	out("  damage dealt / min:   " .. minuteRow(r.Dealt, upTo))
	out("  damage taken / min:   " .. minuteRow(r.Taken, upTo) .. string.format("  (after hit protection, before armor; max HP %d)", rp.Stats and rp.Stats.MaxHP or 0))
	out("  chests opened / min:  " .. minuteRow(r.Chests, upTo))
	local collected = sum(r.XP)
	out(string.format("  XP awarded %d, collected %d (%.0f%%); level choices %d, chest choices %d; walked %.0f studs",
		r.Awarded or 0, collected, (r.Awarded or 0) > 0 and collected / r.Awarded * 100 or 0, r.LevelChoices or 0, r.ChestChoices or 0, r.Walked or 0))
	if r.BeaconWalkFrom then
		out(string.format("  beacon: walked from %.0f studs at %s, arrived %s%s", r.BeaconWalkFrom.D, mmss(r.BeaconWalkFrom.T), mmss(r.BeaconArrived),
			r.BeaconMoved and " (the bot got stuck on the way and was moved beside it after 40 s)" or ""))
	end
	table.insert(summary, {
		Label = label,
		Class = r.Class,
		Kill = r.FirstKill,
		Combat = combat,
		Choice = r.FirstChoice,
		Afford = r.FirstAfford,
		Chest = r.FirstChest,
		L3 = r.Snap["3"] and r.Snap["3"].Level,
		L6 = r.Snap["6"] and r.Snap["6"].Level,
		R6 = r.Snap["6"] and r.Snap["6"].Ranks,
		W6 = r.Snap["6"] and r.Snap["6"].Weapons,
	})
end

local function teamReport(upTo: number)
	out("  team gold earned / min: " .. minuteRow(team.Gold, upTo))
	local times = {}
	for _, c in ipairs(team.Chests) do
		table.insert(times, string.format("%s(%d)", mmss(c.T), c.Cost))
	end
	out(string.format("  chests bought: %d [%s]; by 12:30: %s", #team.Chests, table.concat(times, " "), tostring(team.ChestsAtReveal or #team.Chests)))
end

local bossRows = {}
local function bossReport(label: string)
	local B = team.Boss
	if not B then
		out("  boss: not reached")
		return
	end
	local fight = B.Done
	out(string.format("  boss: spawned %s, N %d, minute %.2f, HP %.0f; fight %s%s", mmss(B.At), B.N, B.Minute or -1, B.HP,
		fight and string.format("%.1f s", fight) or "unfinished", B.Left and string.format(" (HP left %.0f after 400 s)", B.Left) or (B.Won and ", victory" or "")))
	table.insert(bossRows, { Label = label, N = B.N, HP = B.HP, Fight = fight, Minute = B.Minute, Left = B.Left })
end

------------------------------------------------------------------------------------------
-- Part solo
------------------------------------------------------------------------------------------
local lateBuilds = {} -- class -> build at 13:00 (full runs)
local fullSet = {}
for _, id in ipairs(string.split(string.gsub(args.full or "ruckus,granny_boom", "%+", ","), ",")) do
	fullSet[id] = true
end
if parts.solo then
	-- (ids separated by "," or "+": run_regressions splits its --only list on commas)
	local list = (args.classes == nil or args.classes == "all") and table.clone(RunConfig.Classes.Order) or string.split(string.gsub(args.classes, "%+", ","), ",")
	local minutes = tonumber(args.minutes) or 6
	for _, cls in ipairs(list) do
		local t0 = os.clock()
		local full = fullSet[cls] or args.full == "all"
		local rps = startRun({ me }, { cls })
		check(cls .. ": solo Cliffwood director run started", rps ~= nil and SM.IsDirector())
		if not rps then
			continue
		end
		play(rps, full and 1e9 or minutes * 60)
		local r = M[me.UserId]
		if r.Snap["13"] then
			lateBuilds[cls] = r.Snap["13"].Raw
		end
		report(RM.GetRunPlayer(me) or rps[1], (full and "solo full " or "solo ") .. cls, full and 16 or minutes)
		teamReport(full and 16 or minutes)
		if full then
			bossReport("solo " .. cls)
		end
		out(string.format("  (%.0f simulated s)", os.clock() - t0))
	end
end

------------------------------------------------------------------------------------------
-- Part party: four players to the boss
------------------------------------------------------------------------------------------
local partyBuilds = nil
if parts.party then
	local classes = args.partyclasses and string.split(string.gsub(args.partyclasses, "%+", ","), ",") or { RunConfig.Classes.Order[1], RunConfig.Classes.Order[2], RunConfig.Classes.Order[3], RunConfig.Classes.Order[4] }
	local players = { me, mates[1], mates[2], mates[3] }
	local rps = startRun(players, classes)
	check("party: 4-player Cliffwood director run started", rps ~= nil and SM.IsDirector() and SM.PartyN() == 4, tostring(SM.PartyN()))
	if rps then
		play(rps, tonumber(args.partyminutes) and tonumber(args.partyminutes) * 60 or 1e9)
		partyBuilds = {}
		for i, p in ipairs(players) do
			local rp = RM.GetRunPlayer(p) or rps[i]
			report(rp, "party " .. classes[i], 16)
			if M[p.UserId].Snap["13"] then
				table.insert(partyBuilds, { Class = classes[i], Build = M[p.UserId].Snap["13"].Raw })
			end
		end
		teamReport(16)
		bossReport("party of 4")
		-- the team's view: the first kill by anyone, everyone's first level choice, the first chest
		local firstKill, firstReach, lastChoice, firstChoice = math.huge, math.huge, 0, math.huge
		for _, p in ipairs(players) do
			local r = M[p.UserId]
			firstKill = math.min(firstKill, r.FirstKill or math.huge)
			firstReach = math.min(firstReach, r.FirstReach or r.FirstHit or math.huge)
			firstChoice = math.min(firstChoice, r.FirstChoice or math.huge)
			lastChoice = math.max(lastChoice, r.FirstChoice or math.huge)
		end
		local chest1 = team.Chests[1] and team.Chests[1].T or nil
		out(string.format("== party team: first kill %s (combat-to-kill %.1f s), first level choices %s..%s, first chest bought %s",
			mmss(firstKill < math.huge and firstKill or nil), firstKill - firstReach, mmss(firstChoice), mmss(lastChoice < math.huge and lastChoice or nil), mmss(chest1)))
		table.insert(summary, {
			Label = "party team (any hero)",
			Class = "party",
			Kill = firstKill < math.huge and firstKill or nil,
			Combat = firstKill < math.huge and (firstKill - firstReach) or nil,
			Choice = firstChoice < math.huge and firstChoice or nil,
			Afford = nil,
			Chest = chest1,
		})
	end
end

------------------------------------------------------------------------------------------
-- Part boss: the Basin Breaker against 13:00 builds (fresh runs, clock moved to 13:30)
------------------------------------------------------------------------------------------
local function applyBuild(rp, build)
	for id in pairs(rp.Weapons) do
		rp.Weapons[id] = nil
	end
	table.clear(rp.WeaponOrder)
	for _, w in ipairs(build.Weapons) do
		rp.Weapons[w.Id] = { Id = w.Id, Level = w.Rank, Rank = w.Rank, Evolved = w.Evolved, Timer = 0.3, Live = {}, Growth = 0 }
		table.insert(rp.WeaponOrder, w.Id)
	end
	for id in pairs(rp.Passives) do
		rp.Passives[id] = nil
	end
	table.clear(rp.PassiveOrder)
	for _, x in ipairs(build.Passives) do
		rp.Passives[x.Id] = x.Rank
		table.insert(rp.PassiveOrder, x.Id)
	end
	rp.Level = build.Level or rp.Level
	LU.DevWeapons(rp, false, {}) -- recomputes the stat sheet and the inventory
end

local function bossFight(players: { Player }, entries: { any }, label: string)
	local classes = {}
	for i, en in ipairs(entries) do
		classes[i] = en.Class
	end
	local rps = startRun(players, classes)
	if not rps then
		check(label .. ": boss run started", false)
		return
	end
	for i, rp in ipairs(rps) do
		applyBuild(rp, entries[i].Build)
		rp.XPNeeded = 1e12 -- no new levels during the measurement
	end
	SM.SetDirectorClock(13.5 * 60 - 1)
	preview.advance(1.2, FPS)
	Beacon.DevActivate()
	preview.advance(0.5, FPS)
	Beacon.ForceCharge(1) -- ends the rally
	preview.advance(0.2, FPS)
	Beacon.ForceCharge(1) -- fills the charge: the boss spawns next frame
	local bpos = Beacon.Position()
	if bpos then
		for i, rp in ipairs(rps) do
			local a = i * math.pi / 2
			local x, z = HG.NearestWalkable(bpos.X + math.cos(a) * 10, bpos.Z + math.sin(a) * 10, 6)
			if x and z then
				RM.TeleportPlayer(rp, Vector3.new(x, HG.GroundY(x, z), z))
				rp.LastValidPos = rp.Root.Position
			end
		end
	end
	play(rps, 1e9, 480)
	for _, rp in ipairs(rps) do
		out(string.format("  %s %s: %s", label, rp.CharacterId, (buildText(buildOf(rp)))))
	end
	bossReport(label)
end

if parts.boss then
	out("== Basin Breaker against 13:00 builds (offline Lune, NOT Studio)")
	local entries = {}
	for _, cls in ipairs(RunConfig.Classes.Order) do
		if lateBuilds[cls] then
			table.insert(entries, { Class = cls, Build = lateBuilds[cls] })
		end
	end
	for _, en in ipairs(entries) do
		bossFight({ me }, { en }, "boss N=1 " .. en.Class)
	end
	local four = partyBuilds and #partyBuilds == 4 and partyBuilds or nil
	if four then
		bossFight({ me, mates[1], mates[2], mates[3] }, four, "boss N=4 party builds")
	end
	check("boss: at least one late build measured", #entries > 0 or four ~= nil, #entries .. " solo builds")
end

------------------------------------------------------------------------------------------
-- Summary and targets
------------------------------------------------------------------------------------------
out("== SUMMARY (offline Lune mock, NOT Studio; bot player, invulnerable)")
out("  run                          first kill  combat->kill  1st choice  chest affordable  1st chest  lvl@3  lvl@6  ranks@6  weapons@6")
for _, s in ipairs(summary) do
	out(string.format("  %-28s %9s  %11s  %10s  %16s  %9s  %5s  %5s  %7s  %9s", s.Label, mmss(s.Kill), s.Combat and string.format("%.1f s", s.Combat) or "-",
		mmss(s.Choice), mmss(s.Afford), mmss(s.Chest), tostring(s.L3 or "-"), tostring(s.L6 or "-"), tostring(s.R6 or "-"), tostring(s.W6 or "-")))
end
for _, s in ipairs(summary) do
	target(s.Label .. ": first kill within 5 s of active combat", s.Combat ~= nil and s.Combat <= 5, s.Combat and string.format("%.1f s", s.Combat) or "no kill")
	target(s.Label .. ": first level choice at 20-35 s", s.Choice ~= nil and s.Choice >= 20 and s.Choice <= 35, mmss(s.Choice))
	target(s.Label .. ": first chest opened within 30 s", s.Chest ~= nil and s.Chest <= 30, mmss(s.Chest))
end
for _, b in ipairs(bossRows) do
	target(string.format("%s: Basin Breaker fight 45-90 s (N %d, HP %.0f)", b.Label, b.N, b.HP), b.Fight ~= nil and b.Fight >= 45 and b.Fight <= 90, b.Fight and string.format("%.1f s", b.Fight) or "unfinished")
end

local errs = 0
do
	local R = preview.Mock.R
	for _, list in ipairs({ R.log.warnings, R.log.errors }) do
		for _, entry in ipairs(list) do
			local msg = tostring(entry.message)
			if string.find(msg, "Step error", 1, true) or string.find(msg, "handler error", 1, true) then
				errs += entry.count or 1
				out("  logged: " .. msg)
			end
		end
	end
end
check("no step or remote-handler failures logged", errs == 0, errs)
preview.log(fails == 0 and "PASS pacing-sim" or ("FAIL pacing-sim (" .. fails .. ")"))
