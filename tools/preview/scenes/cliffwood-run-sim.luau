-- cliffwood-run-sim: the redesign streams TOGETHER on the real server (docs/redesign/gameplay/DESIGN.md).
-- For each of the twelve classes (RunConfig.Classes.Order) a Solo run on arena "Cliffwood"
-- started with the admitted class (RunManager.SetAdmittedClass + StartTeamRun), ~40 s at a coarse step:
--   HeightGrid active; the hero is the class rig (mesh Torso, Motor6Ds, Humanoid); it starts with
--   the class weapon; the weapon deals damage and kills; enemies stand on HeightGrid.GroundY and
--   never in unwalkable cells; XP gems rest on the ground; the portal sits on the ground; a launch
--   pad throws the hero toward its Target (Dash.Launch) and the arc is not snapped back; a dash
--   request through the server handler sets rp.DashUntil (class variant) and the dash move is not
--   snapped back by the speed check. For the first class: DevNextStage goes to stage 2 on the same
--   arena table with the portal at another landmark. No "Step error" / handler errors logged.
-- The mock has no physics and its raycasts hit nothing, so this scene answers workspace:Raycast
-- against the map's parts (oriented boxes, the current arena model). Prints PASS / FAIL lines.
--   lune run tools/preview/runtime/main.luau -- --scene cliffwood-run-sim --studio --device pc
--     --max-time 3000 --set headless=on   [--set character=<class id>] [--set seconds=40]
local C = lib("common")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local fails = 0
local function check(name: string, ok: boolean, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
end

------------------------------------------------------------------------------------------
-- Raycasts against the arena's parts (oriented boxes; spatial buckets, built per arena)
------------------------------------------------------------------------------------------
local MapBuilder -- set after the server starts
local BUCKET = 32
local index: any = nil
local indexArena: any = nil
local includeCache = setmetatable({}, { __mode = "k" })
local stamp = 0

local function bucketKey(bx: number, bz: number): number
	return bx * 65536 + bz
end

local function buildIndex(arena)
	local buckets = {}
	local count = 0
	for _, p in ipairs(arena.Model:GetDescendants()) do
		if p:IsA("BasePart") and p.CanQuery ~= false then
			local cf, s = p.CFrame, p.Size
			local ax, ay, az = cf.RightVector, cf.UpVector, -cf.LookVector
			local hx, hy, hz = s.X / 2, s.Y / 2, s.Z / 2
			local pos = cf.Position
			local ex = math.abs(ax.X) * hx + math.abs(ay.X) * hy + math.abs(az.X) * hz
			local ez = math.abs(ax.Z) * hx + math.abs(ay.Z) * hy + math.abs(az.Z) * hz
			local e = { Part = p, Pos = pos, Ax = ax, Ay = ay, Az = az, H = { hx, hy, hz }, Collide = p.CanCollide, Seen = 0 }
			for bx = math.floor((pos.X - ex) / BUCKET), math.floor((pos.X + ex) / BUCKET) do
				for bz = math.floor((pos.Z - ez) / BUCKET), math.floor((pos.Z + ez) / BUCKET) do
					local k = bucketKey(bx, bz)
					local list = buckets[k]
					if not list then
						list = {}
						buckets[k] = list
					end
					table.insert(list, e)
				end
			end
			count += 1
		end
	end
	return { Buckets = buckets, Count = count }
end

-- slab test in the box's frame: entry t in [0, 1] and the world normal, or nil
local function rayBox(e, origin: Vector3, dir: Vector3): (number?, Vector3?)
	local rel = origin - e.Pos
	local axes = { e.Ax, e.Ay, e.Az }
	local tmin, tmax = -math.huge, math.huge
	local nAxis, nSign = 1, 1
	for i = 1, 3 do
		local a = axes[i]
		local o = rel:Dot(a)
		local d = dir:Dot(a)
		local h = e.H[i]
		if math.abs(d) < 1e-9 then
			if o < -h or o > h then
				return nil
			end
		else
			local t1, t2 = (-h - o) / d, (h - o) / d
			local s = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				s = 1
			end
			if t1 > tmin then
				tmin, nAxis, nSign = t1, i, s
			end
			if t2 < tmax then
				tmax = t2
			end
			if tmin > tmax then
				return nil
			end
		end
	end
	if tmin < 0 or tmin > 1 then
		return nil -- behind the origin, starts inside, or past the ray's end
	end
	return tmin, axes[nAxis] * nSign
end

local function allowedSet(list)
	local cached = includeCache[list]
	if cached and cached.N == #list then
		return cached.Set
	end
	local set = {}
	for _, inst in ipairs(list) do
		set[inst] = true
		for _, d in ipairs(inst:GetDescendants()) do
			set[d] = true
		end
	end
	includeCache[list] = { N = #list, Set = set }
	return set
end

local rayCount = 0
preview.setRaycast(function(origin: Vector3, direction: Vector3, params)
	rayCount += 1
	local arena = MapBuilder and MapBuilder.GetArena()
	if not arena or not arena.Model or not arena.Model.Parent then
		return nil
	end
	if arena ~= indexArena then
		index = buildIndex(arena)
		indexArena = arena
	end
	local include, exclude = nil, nil
	local respect = false
	if params then
		respect = params.RespectCanCollide
		local list = params.FilterDescendantsInstances
		if params.FilterType == Enum.RaycastFilterType.Include then
			include = allowedSet(list)
		elseif #list > 0 then
			exclude = allowedSet(list)
		end
	end
	stamp += 1
	local e = origin + direction
	local bx0, bx1 = math.floor(math.min(origin.X, e.X) / BUCKET), math.floor(math.max(origin.X, e.X) / BUCKET)
	local bz0, bz1 = math.floor(math.min(origin.Z, e.Z) / BUCKET), math.floor(math.max(origin.Z, e.Z) / BUCKET)
	local best, bestN, bestPart = math.huge, nil, nil
	for bx = bx0, bx1 do
		for bz = bz0, bz1 do
			local list = index.Buckets[bucketKey(bx, bz)]
			if list then
				for _, ent in ipairs(list) do
					if ent.Seen ~= stamp then
						ent.Seen = stamp
						local p = ent.Part
						if (not include or include[p]) and (not exclude or not exclude[p]) and (not respect or ent.Collide) then
							local t, n = rayBox(ent, origin, direction)
							if t and t < best then
								best, bestN, bestPart = t, n, p
							end
						end
					end
				end
			end
		end
	end
	if not bestPart then
		return nil
	end
	local hit = origin + direction * best
	return { Instance = bestPart, Position = hit, Normal = bestN, Distance = direction.Magnitude * best, Material = bestPart.Material }
end)

------------------------------------------------------------------------------------------
-- Boot
------------------------------------------------------------------------------------------
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)

local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local HG = preview.server("HeightGrid")
local WS = preview.server("WeaponSystem")
local DS = preview.server("DataService")
local Spawner = preview.server("EnemySpawner")
MapBuilder = preview.server("MapBuilder")
local CharacterData = require(ReplicatedStorage.Shared.CharacterData)
local MeshCatalog = require(ReplicatedStorage.Shared.MeshCatalog)
local Dash = preview.require(ServerScriptService.SwarmV2.Run.Dash)
local Config = require(ReplicatedStorage.Shared.Config)
local st = C.state()
local XP_HEIGHT = Config.XP.GemHeight

local launches = {}
local realLaunch = Dash.Launch
Dash.Launch = function(rp, from, target, extraApex)
	local ok = realLaunch(rp, from, target, extraApex)
	table.insert(launches, { Rp = rp, From = from, Target = target, Extra = extraApex, Ok = ok })
	return ok
end

local advance = preview.advance
local function pickLevels()
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, me:GetAttribute("ChoiceOfferId"))
		advance(0.3)
	end
end
-- coarse simulation: 0.5 s slices at 10 frames a second
local function run(seconds: number, onSlice: (() -> ())?)
	local left = seconds
	while left > 0 do
		local dt = math.min(left, 0.5)
		advance(dt, 10)
		left -= dt
		pickLevels()
		if onSlice then
			onSlice()
		end
	end
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
local function flatDist(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
local function nearestLandmark(arena, pos: Vector3): string?
	local best, bestD = nil, math.huge
	for _, lm in ipairs(arena.Landmarks or {}) do
		local d = flatDist(lm.Pos, pos)
		if d < bestD then
			best, bestD = lm.Name, d
		end
	end
	return best
end
local function waitPhase(want: string, seconds: number): boolean
	for _ = 1, math.ceil(seconds / 0.5) do
		if st:GetAttribute("Phase") == want then
			return true
		end
		advance(0.5, 10)
		pickLevels()
	end
	return st:GetAttribute("Phase") == want
end
local function rootFree(rp)
	-- out of a chest reel / level-up so the dash is allowed
	if rp.RewardUntil and RM.EndReward then
		pcall(RM.EndReward, rp)
	end
	pickLevels()
end
-- moves the root along a path for `duration` s in 1/30 s frames (the client would fly it)
local function fly(rp, duration: number, at: (number) -> Vector3)
	local t = 0
	while t < duration do
		local dt = math.min(1 / 30, duration - t)
		advance(dt, 30)
		t += dt
		local root = rp.Root
		if root and preview.args.debug == "on" then
			preview.log(string.format("  fly t %.2f pos %s last %s timer %.2f", t, tostring(root.Position), tostring(rp.LastValidPos), rp.SpeedCheckTimer or -1))
		end
		if root then
			root.CFrame = CFrame.new(at(math.min(1, t / duration))) * root.CFrame.Rotation
		end
	end
end

local SIGNATURE = require(ReplicatedStorage.Shared.WeaponData).Signatures
local classes = table.clone(require(ReplicatedStorage.SwarmV2.Run.RunConfig).Classes.Order)
if preview.args.character then
	classes = { preview.args.character }
end
local SECONDS = tonumber(preview.args.seconds) or 40
local dashRemote = ReplicatedStorage:WaitForChild("SwarmV2Net"):WaitForChild("Run"):WaitForChild("Dash")

for ci, cls in ipairs(classes) do
	preview.log("---- " .. cls)
	if not waitPhase("Lobby", 30) then
		check(cls .. ": back in the lobby before the run", false, st:GetAttribute("Phase"))
	end
	local data = DS.GetData(me)
	if data then
		data.OwnedCharacters[cls] = true
	end
	RM.SetAdmittedClass(me, cls)
	local started = RM.StartTeamRun({ me }, "Solo", "Cliffwood", me)
	advance(1, 10)
	pickLevels()
	local rp = RM.GetRunPlayer(me)
	check(cls .. ": run started on Cliffwood", started and rp ~= nil and st:GetAttribute("Arena") == "Cliffwood", st:GetAttribute("Arena"))
	if not rp then
		continue
	end
	rp.InvulnUntil = math.huge
	local arena = MapBuilder.GetArena()
	check(cls .. ": HeightGrid active", HG.IsActive(), "rays " .. rayCount)

	-- the class rig
	local model = rp.Character
	local def = CharacterData.Characters[cls]
	local hum = model and model:FindFirstChildOfClass("Humanoid")
	local torso = model and model:FindFirstChild("Torso")
	local motors = 0
	if model then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("Motor6D") then
				motors += 1
			end
		end
	end
	local meshExpected = def and def.MeshName and MeshCatalog.Models[def.MeshName] ~= nil
	check(cls .. ": hero is the class rig with a Humanoid", rp.CharacterId == cls and model ~= nil and model:GetAttribute("CharacterId") == cls
		and hum ~= nil and rp.Root ~= nil and motors >= 5 and torso ~= nil and (not meshExpected or torso:IsA("MeshPart")),
		string.format("id %s, humanoid %s, motors %d, torso %s, mesh %s", tostring(rp.CharacterId), tostring(hum ~= nil), motors,
			torso and torso.ClassName or "none", tostring(def and def.MeshName)))
	local root0 = rp.Root and rp.Root.Position
	check(cls .. ": hero spawned on the ground", root0 ~= nil and math.abs(root0.Y - HG.GroundY(root0.X, root0.Z) - 3.5) < 1.6,
		root0 and string.format("y %.1f ground %.1f", root0.Y, HG.GroundY(root0.X, root0.Z)))

	-- the class weapon
	local sig = SIGNATURE[cls]
	check(cls .. ": starts with " .. sig, rp.Weapons[sig] ~= nil and rp.WeaponOrder[1] == sig, table.concat(rp.WeaponOrder, ","))

	-- the portal on the ground
	local portalPos = SM.PortalPosition()
	check(cls .. ": portal on the ground", portalPos ~= nil and math.abs(portalPos.Y - HG.GroundY(portalPos.X, portalPos.Z)) < 0.6,
		portalPos and string.format("%.1f vs ground %.1f at %s", portalPos.Y, HG.GroundY(portalPos.X, portalPos.Z), nearestLandmark(arena, portalPos) or "?"))

	-- ~40 s of play
	local kills0 = tonumber(me:GetAttribute("Kills")) or 0
	local dmg0 = rp.DamageDealt or 0
	local samples, offGround, unwalk, worst = 0, 0, 0, 0
	local gemSamples, gemOff = 0, 0
	local sliceN = 0
	run(SECONDS, function()
		sliceN += 1
		rp.InvulnUntil = math.huge
		if sliceN % 4 ~= 0 then
			return
		end
		for _, e in ipairs(Spawner.Active) do
			if e.Alive and e.Pos then
				samples += 1
				local g = HG.GroundY(e.Pos.X, e.Pos.Z)
				local dy = math.abs(e.Pos.Y - g)
				if dy >= 1.5 then
					offGround += 1
					worst = math.max(worst, dy)
				end
				if not HG.IsWalkable(e.Pos.X, e.Pos.Z) then
					unwalk += 1
				end
			end
		end
		local folder = workspace:FindFirstChild("SwarmGems")
		if folder then
			for _, gem in ipairs(folder:GetChildren()) do
				if gem:GetAttribute("Active") == true and gem:GetAttribute("Fly") == nil then
					local base = gem:GetAttribute("Base")
					if typeof(base) == "Vector3" then
						gemSamples += 1
						if math.abs(base.Y - XP_HEIGHT - HG.GroundY(base.X, base.Z)) > 1.5 then
							gemOff += 1
						end
					end
				end
			end
		end
	end)
	local kills = (tonumber(me:GetAttribute("Kills")) or 0) - kills0
	local counts = {}
	for k, v in pairs(WS.DebugCounts()) do
		table.insert(counts, k .. "=" .. v)
	end
	table.sort(counts)
	preview.log(string.format("%s: %d s, enemies %d, kills %d, damage %d, live %s", cls, SECONDS, #Spawner.Active, kills,
		math.floor((rp.DamageDealt or 0) - dmg0), table.concat(counts, " ")))
	check(cls .. ": the class weapon fires and deals damage", (rp.DamageDealt or 0) > dmg0, math.floor((rp.DamageDealt or 0) - dmg0))
	check(cls .. ": the weapon kills enemies", kills > 0, kills)
	check(cls .. ": enemies stand on the ground (|dy| < 1.5)", samples > 0 and offGround == 0,
		string.format("%d of %d samples off, worst %.1f", offGround, samples, worst))
	check(cls .. ": no enemy in an unwalkable cell", samples > 0 and unwalk == 0, string.format("%d of %d", unwalk, samples))
	check(cls .. ": XP gems rest on the ground", gemSamples > 0 and gemOff == 0, string.format("%d of %d off", gemOff, gemSamples))

	-- a dash through the server handler (class variant), then the client's move
	rootFree(rp)
	advance(3, 10) -- past any earlier cooldown
	pickLevels()
	rootFree(rp)
	local from = rp.Root.Position
	local dashDef = Dash.GetDef(cls)
	local reach = dashDef.Kind == "Leap" and (dashDef.Horizontal or 31) or dashDef.Speed * dashDef.Duration
	local dir: Vector3? = nil
	for k = 0, 15 do
		local a = k * math.pi / 8
		local d = Vector3.new(math.cos(a), 0, math.sin(a))
		local to = from + d * reach
		if HG.IsWalkable(to.X, to.Z) and HG.CanStep(from.X, from.Z, to.X, to.Z) then
			dir = d
			break
		end
	end
	if not dir then
		check(cls .. ": a clear dash line", false)
	else
		local before = rp.DashUntil
		dashRemote:FireServer(dir)
		advance(1 / 30, 30)
		local okDash = rp.DashUntil ~= nil and rp.DashUntil ~= before and rp.DashKind == dashDef.Kind
		check(cls .. ": dash request sets rp.DashUntil (" .. dashDef.Kind .. ")", okDash,
			string.format("kind %s speed %.1f", tostring(rp.DashKind), rp.DashSpeed or 0))
		if okDash then
			local speed, dur = rp.DashSpeed, rp.DashUntil - os.clock()
			local g0 = HG.GroundY(from.X, from.Z)
			fly(rp, math.max(0.05, dur), function(f)
				local p = from + dir * (speed * dur * f)
				local lift = dashDef.Kind == "Leap" and (dashDef.Apex or 7) * 4 * f * (1 - f) or 0
				return Vector3.new(p.X, HG.GroundY(p.X, p.Z) + 3.5 + lift, p.Z)
			end)
			local want = from + dir * (speed * dur)
			run(1)
			local now = rp.Root.Position
			check(cls .. ": the dash move is not snapped back", flatDist(now, want) < 2 and flatDist(now, from) > reach * 0.7,
				string.format("moved %.1f of %.1f, %.1f from the end, ground %.1f", flatDist(now, from), reach, flatDist(now, want), g0))
		end
	end

	-- a launch pad
	local pad = arena.LaunchPads and arena.LaunchPads[1]
	check(cls .. ": the map has a launch pad", pad ~= nil)
	if pad then
		rootFree(rp)
		table.clear(launches)
		RM.TeleportPlayer(rp, pad.Pos)
		local fired = nil
		for _ = 1, 10 do
			advance(0.1, 30)
			if launches[1] and launches[1].Ok then
				fired = launches[1]
				break
			end
		end
		if preview.args.debug == "on" then
			local parts = {}
			for k = 0, 131 do
				local p = pad.Pos:Lerp(pad.Target, k / 131)
				table.insert(parts, string.format("%d:%.0f%s", math.floor(p.X), HG.GroundY(p.X, p.Z), HG.IsWalkable(p.X, p.Z) and "" or "x"))
			end
			preview.log("pad line ground: " .. table.concat(parts, " "))
		end
		local toward = fired and (pad.Target - pad.Pos) * Vector3.new(1, 0, 1)
		check(cls .. ": standing on the pad launches toward its Target", fired ~= nil and toward ~= nil and rp.DashKind == "Leap"
			and rp.DashDir ~= nil and rp.DashDir:Dot(toward.Unit) > 0.99,
			fired and string.format("dir %s", tostring(rp.DashDir)) or (launches[1] and "Launch refused" or "no launch"))
		if fired then
			-- the client's flight: Dash.Launch's ballistic arc (the root rides 3.5 over it)
			local target = pad.Target
			local g = workspace.Gravity
			local rise = math.max(0, target.Y - fired.From.Y)
			local vy = math.sqrt(2 * g * (rise + math.max(4, fired.Extra)))
			local total = vy / g + math.sqrt(2 * (rise + math.max(4, fired.Extra) - rise) / g)
			local dur = math.max(0.05, rp.DashUntil - os.clock())
			local t0 = total - dur
			local minClear = math.huge
			fly(rp, dur, function(f)
				local t = t0 + dur * f
				local p = fired.From:Lerp(target, t / total)
				local y = fired.From.Y + vy * t - g * t * t / 2
				minClear = math.min(minClear, y - HG.GroundY(p.X, p.Z))
				return Vector3.new(p.X, y + 3.5, p.Z)
			end)
			check(cls .. ": the pad arc clears the ground under it", minClear > -0.5, string.format("lowest %.1f over the ground, apex +%d", minClear, fired.Extra))
			if preview.args.debug == "on" then
				preview.log(string.format("pad: dur %.2f speed %.1f allow %.1f, after fly %s, paused %s reward %s frozen %s",
					dur, rp.DashSpeed or 0, rp.DashAllow or 0, tostring(rp.Root.Position), tostring(rp.Paused), tostring(rp.RewardUntil), tostring(RM.IsFrozen())))
				for _ = 1, 10 do
					advance(0.1, 30)
					local p = rp.Root.Position
					preview.log(string.format("  t+ pos %s ground %.1f walk %s lastValid %s safe %s timer %.2f dashUntil-now %.2f", tostring(p), HG.GroundY(p.X, p.Z),
						tostring(HG.IsWalkable(p.X, p.Z)), tostring(rp.LastValidPos), tostring(rp.SafePos), rp.SpeedCheckTimer or -1, (rp.DashUntil or 0) - os.clock()))
				end
			end
			run(1)
			local now = rp.Root.Position
			check(cls .. ": the pad arc lands at the Target (not snapped back)", flatDist(now, target) < 6,
				string.format("%.1f from the target, %.1f from the pad", flatDist(now, target), flatDist(now, pad.Pos)))
		end
	end

	-- stage 2 on the same map (first class only: the travel takes a while)
	if ci == 1 then
		local p1 = SM.PortalPosition()
		local lm1 = p1 and nearestLandmark(arena, p1)
		local okDev = SM.DevNextStage()
		local reached = false
		for _ = 1, 60 do
			advance(0.5, 10)
			pickLevels()
			if st:GetAttribute("Stage") == 2 and not SM.IsHolding() then
				reached = true
				break
			end
		end
		run(1)
		local p2 = SM.PortalPosition()
		local lm2 = p2 and nearestLandmark(arena, p2)
		check(cls .. ": DevNextStage reaches stage 2", okDev and reached, "stage " .. tostring(st:GetAttribute("Stage")))
		check(cls .. ": stage 2 keeps the same arena table (no rebuild)", MapBuilder.GetArena() == arena and arena.Model.Parent ~= nil)
		check(cls .. ": stage 2 portal at another landmark", lm1 ~= nil and lm2 ~= nil and lm1 ~= lm2, tostring(lm1) .. " -> " .. tostring(lm2))
		check(cls .. ": stage 2 portal on the ground", p2 ~= nil and math.abs(p2.Y - HG.GroundY(p2.X, p2.Z)) < 0.6)
		check(cls .. ": HeightGrid still active on stage 2", HG.IsActive())
	end

	-- leave the run
	RM.AbandonRun(rp)
	advance(1, 10)
	for _ = 1, 10 do
		if st:GetAttribute("Phase") == "Lobby" then
			break
		end
		pcall(function()
			preview.remote("ReturnToLobby"):FireServer("menu")
		end)
		advance(1, 10)
	end
	RM.SetAdmittedClass(me, nil)
end

local logged = errorCount()
-- (worded so tools/run_regressions.py's error scan does not match this line itself)
check("no step or remote-handler failures logged", logged == 0, logged)
preview.setRaycast(nil)
preview.log(if fails == 0 then "PASS cliffwood-run-sim" else string.format("FAIL: cliffwood-run-sim (%d checks)", fails))
