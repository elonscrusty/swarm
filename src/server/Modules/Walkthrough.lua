--[[
	Walkthrough.lua
	The interactive first-run walkthrough (Config.Features.Walkthrough, Config.Walkthrough,
	docs/next/WALKTHROUGH.md). A server step machine that WAITS for the player.

	On a Cliffwood beacon run (StageManager.IsDirector; the live game) the steps are:
	  Move     a gold ground ring ~RingDistance studs away in open ground (the client line
	           teaches walking and the camera for the device in hand). Done in the ring.
	  Dash     jump and dash (Space / Shift, A / B, JUMP / DASH): done on a server-validated
	           dash (rp.DashUntil moves), or after its timeout.
	  Fight    DirectorEnemyCount weak, slow beetles around the hero; the weapons attack by
	           themselves. Done when all are beaten.
	  Gems     their personal XP shards: done when the first level choice opens (a top-up
	           shard is dropped when the floor shards are not enough for that level).
	  Upgrade  done when a card is picked (skipped when no level is waiting).
	  Chest    chests are paid with the team's run gold from kills; the account's first
	           walkthrough places a free gift chest ~ChestDistance studs away (a replay's chest
	           is a normal team chest at the shared price). Done when it is opened.
	  Beacon   the objective: survive, grow strong, light the beacon at 12:30, beat the boss.
	           The walkthrough ends GoSeconds later.
	The director's spawns are held only for a short opening: until the Fight step starts or
	OpeningHold seconds of run time, whichever comes first (the walkthrough never holds the
	director beyond that).

	On the old stage loop (other arenas, Daily Challenges with old arenas) the steps are the
	original Move, Fight, Gems, Upgrade, Chest, Go ("Waves are coming!", portal): the held
	waves and the portal reveal are released at Go.

	Who: RunManager.beginRun calls Consider for each run player before Stats.Runs counts the
	run. Only Solo, Standard, no curses / Endless / Daily, not DEV-tainted, tips on, the
	first-run flow on (Config.FirstRun.AutoStart), and either the account's very first run
	(Stats.Runs 0, TutorialDone false) or Settings > Replay tips (save WalkthroughReplay).
	It is marked done (save WalkthroughDone) when it starts, so it never runs twice. It is
	skippable: Settings > Show tips off (or SKIP TIPS) ends it at once.

	Holds: EnemySpawner.SetHold("Walkthrough", on) keeps the spawns back (see above);
	StageManager asks HoldsReveal() before the stage-1 portal reveal (old stage loop only).
	Both let go whenever the walkthrough ends early (death, leaving, run end, DEV tools,
	tips switched off).

	Timers: each step auto-completes after Config.Walkthrough.Timeouts[step] seconds of
	run time (only while RunManager.IsSimulating: pause, panels and travel stop it).

	Client view (player attributes, WalkthroughClient.lua): Walkthrough = step name or nil,
	WalkCount / WalkTotal (Fight progress), WalkTarget (Vector3 the bubble and the world
	marker point at, or nil), WalkFree (the Chest step's chest is the free gift chest),
	WalkMode = "Beacon" on a beacon run (nil on the old stage loop).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local Walkthrough = {}

local ctx
local MapBuilder = require(script.Parent.MapBuilder)

local arenaSeen: any = nil -- the last stage arena LootSystem.OnBuilt reported (old stage loop)

-- The arena the run is on now: the map builder's current one (a beacon run's BuildStage skips
-- the OnBuilt hooks), else the last one LootSystem reported.
local function currentArena(): any
	return MapBuilder.GetArena() or arenaSeen
end

local STEPS = { "Move", "Fight", "Gems", "Upgrade", "Chest", "Go" } -- the old stage loop
local BEACON_STEPS = { "Move", "Dash", "Fight", "Gems", "Upgrade", "Chest", "Beacon" } -- a beacon run
local HOLD = "Walkthrough"

-- the one active walkthrough (Solo only) or nil
local active: { [string]: any }? = nil
-- for tests: every step entered, in order, and how each one ended ("done" | "timeout")
local log: { { Step: string, How: string? } } = {}

local function cfg(): { [string]: any }
	return (Config :: any).Walkthrough or {}
end

local function enabled(): boolean
	return (Config :: any).Features.Walkthrough == true
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- A Cliffwood beacon run (StageManager's run director)?
local function beaconRun(): boolean
	local SM = ctx and ctx.StageManager
	return SM ~= nil and SM.IsDirector ~= nil and SM.IsDirector() == true
end

local function heroPos(rp): Vector3?
	local root = rp and rp.Root
	if root and root.Parent then
		return root.Position
	end
	return nil
end

local function setAttr(rp, name: string, value: any)
	local player: Player = rp.Player
	if player and player.Parent and player:GetAttribute(name) ~= value then
		player:SetAttribute(name, value)
	end
end

-- The ground height at (x, z) (the height grid on Cliffwood, else the flat arena's).
local function groundY(x: number, z: number, fallback: number): number
	local HG = ctx.HeightGrid
	if HG and HG.IsActive() then
		return HG.GroundY(x, z)
	end
	return fallback
end

-- Open ground at `dist` studs from `from` (EnemyAI obstacles, inside the arena, away from
-- other loot); tries 16 angles from a random start, then shorter rings.
local function openSpot(from: Vector3, dist: number, clearance: number): Vector3
	local arena = currentArena()
	local c = arena and arena.Center or Config.ArenaOrigin
	local half = (arena and arena.Half or Config.Arenas.Size / 2) - clearance - 4
	local loot = ctx.LootSystem.Objects()
	local portal = ctx.Remotes.State():GetAttribute("PortalPos")
	local start = math.random() * math.pi * 2
	for _, scale in ipairs({ 1, 0.75, 0.5 }) do
		for i = 0, 15 do
			local a = start + i * (math.pi * 2 / 16)
			local x = math.clamp(from.X + math.cos(a) * dist * scale, c.X - half, c.X + half)
			local z = math.clamp(from.Z + math.sin(a) * dist * scale, c.Z - half, c.Z + half)
			local ok = not ctx.EnemyAI.IsBlocked(x, z, clearance)
			if ok and typeof(portal) == "Vector3" and Vector3.new(portal.X - x, 0, portal.Z - z).Magnitude < 12 then
				ok = false -- keep clear of the (hidden) portal ring
			end
			if ok then
				for _, obj in ipairs(loot) do
					local dx, dz = obj.Pos.X - x, obj.Pos.Z - z
					if dx * dx + dz * dz < (clearance + 3) ^ 2 then
						ok = false
						break
					end
				end
			end
			if ok and ctx.HeightGrid and ctx.HeightGrid.IsActive() then
				-- a map with height: walkable ground the hero can walk to (no ledge, no cliff top)
				local HG = ctx.HeightGrid
				ok = HG.IsWalkable(x, z) and HG.IsWalkable(x + clearance * 0.5, z) and HG.IsWalkable(x - clearance * 0.5, z)
					and HG.IsWalkable(x, z + clearance * 0.5) and HG.IsWalkable(x, z - clearance * 0.5)
					and math.abs(HG.GroundY(x, z) - HG.GroundY(from.X, from.Z)) <= 4
			end
			if ok then
				return Vector3.new(x, groundY(x, z, c.Y), z)
			end
		end
	end
	return Vector3.new(from.X, groundY(from.X, from.Z, c.Y), from.Z) + Vector3.new(dist * 0.4, 0, 0)
end

------------------------------------------------------------------------------------------
-- Eligibility
------------------------------------------------------------------------------------------

-- Would this run player get the walkthrough? (Called before Stats.Runs counts the run.)
local function eligible(rp, data, teamSize: number, mode: string?): boolean
	if not enabled() or teamSize ~= 1 or active ~= nil then
		return false
	end
	local FR = (Config :: any).FirstRun
	if not FR or FR.AutoStart ~= true or mode ~= FR.Mode then
		return false
	end
	-- done once already: only Settings > Replay tips (WalkthroughReplay) brings it back
	if rp.DevTainted or rp.Endless or rp.Daily or (data.WalkthroughDone == true and data.WalkthroughReplay ~= true) then
		return false
	end
	if type(data.Settings) == "table" and data.Settings.Tips == false then
		return false
	end
	local first = data.TutorialDone ~= true and type(data.Stats) == "table" and (tonumber(data.Stats.Runs) or 0) == 0
	if not first and data.WalkthroughReplay ~= true then
		return false
	end
	local RM = ctx.RunModifiers
	if RM and ((#RM.Active() > 0) or RM.IsEndless()) then
		return false
	end
	local difficulty = RM and RM.DifficultyId and RM.DifficultyId() or "Standard"
	return difficulty == "Standard"
end

------------------------------------------------------------------------------------------
-- Steps
------------------------------------------------------------------------------------------

local enter: (string) -> ()

local function releaseHolds()
	if ctx.EnemySpawner.SetHold and ctx.EnemySpawner.Holds and ctx.EnemySpawner.Holds[HOLD] then
		ctx.EnemySpawner.SetHold(HOLD, false, cfg().ReleaseWaveDelay)
	end
	local w = active
	if w then
		w.Released = true
	end
end

local function clearAttrs(rp)
	setAttr(rp, "Walkthrough", nil)
	setAttr(rp, "WalkCount", nil)
	setAttr(rp, "WalkTotal", nil)
	setAttr(rp, "WalkTarget", nil)
	setAttr(rp, "WalkFree", nil)
	setAttr(rp, "WalkMode", nil)
end

-- Ends the walkthrough (finished or cut short); leaves no hold behind.
local function finish(reason: string)
	local w = active
	if not w then
		return
	end
	releaseHolds()
	active = nil
	-- its enemies stay (they are normal enemies by now); its chest stays openable
	clearAttrs(w.Rp)
	table.insert(log, { Step = "End", How = reason })
end

local function spawnFoes(w)
	local C = cfg()
	local hp = heroPos(w.Rp) or Config.ArenaOrigin
	local n = math.max(1, math.floor((w.Beacon and C.DirectorEnemyCount) or C.EnemyCount or 5))
	-- a beacon run's walkthrough bugs are the Cliffwood roster's beetle (the director's look)
	local typeId = (w.Beacon and C.DirectorEnemyType) or C.EnemyType or "Slime"
	w.Foes = {}
	local offset = math.random() * math.pi * 2
	local arena = currentArena()
	local c = arena and arena.Center or Config.ArenaOrigin
	local half = (arena and arena.Half or Config.Arenas.Size / 2) - 6
	for i = 1, n do
		for try = 0, 5 do
			local a = offset + (i / n) * math.pi * 2 + try * 0.35
			local d = (C.EnemyDistance or 20) * (1 - try * 0.08)
			local x = math.clamp(hp.X + math.cos(a) * d, c.X - half, c.X + half)
			local z = math.clamp(hp.Z + math.sin(a) * d, c.Z - half, c.Z + half)
			if not ctx.EnemyAI.IsBlocked(x, z, 1.6) or try == 5 then
				local e = ctx.EnemySpawner.Spawn(typeId, Vector3.new(x, groundY(x, z, c.Y), z), { HP = C.EnemyHP or 4, Force = true })
				if e then
					e.Speed *= C.EnemySpeedMult or 0.45
					e.Damage *= C.EnemyDamageMult or 0.3
					e.DmgScale = (e.DmgScale or 1) * (C.EnemyDamageMult or 0.3)
					table.insert(w.Foes, { E = e, Uid = e.Uid })
				end
				break
			end
		end
	end
	w.Total = #w.Foes
end

local function foesLeft(w): (number, Vector3?)
	local left, nearest, best = 0, nil, math.huge
	local hp = heroPos(w.Rp)
	for _, f in ipairs(w.Foes or {}) do
		local e = f.E
		if e.Alive and e.Uid == f.Uid then
			left += 1
			if hp then
				local d = (flat(e.Pos) - flat(hp)).Magnitude
				if d < best then
					nearest, best = e.Pos, d
				end
			end
		end
	end
	return left, nearest
end

-- The floor gems near the hero are worth less than the first level: drop a top-up gem.
local function topUpGems(w)
	local rp = w.Rp
	if rp.Level > w.Level0 then
		return
	end
	local hp = heroPos(rp)
	if not hp then
		return
	end
	local X = ctx.XPSystem
	local mult = X.CoopShare() * X.PaceMult() * ((rp.Stats and rp.Stats.Growth) or 1)
	if not (mult > 0) then
		mult = 1
	end
	local floor = X.ValueNear and X.ValueNear(hp, cfg().GemRadius or 45) or 0
	local need = rp.XPNeeded - rp.XP
	local missing = need - floor * mult
	if missing > 0 then
		local at = openSpot(hp, 5, 1.5)
		X.SpawnGem(at, math.ceil(missing / mult) + 1)
		w.TopUp = math.ceil(missing / mult) + 1
	end
end

local function spawnChest(w)
	local C = cfg()
	local hp = heroPos(w.Rp) or Config.ArenaOrigin
	local at = openSpot(hp, C.ChestDistance or 12, C.RingClearance or 5)
	-- free on the account's first walkthrough only; a replay's chest has the normal price,
	-- so Replay tips can't be used for a free chest every run
	local free = w.First == true
	local ok, obj = pcall(ctx.LootSystem.AddFeatureChest, currentArena(), C.ChestType or "Small", at, free)
	if not ok or not obj then
		warn("[Walkthrough] chest failed: " .. tostring(obj))
		return
	end
	ctx.LootSystem.SetObjState(obj, "Ready", free and { Title = "Gift Chest", Detail = "Free · hold to open" } or { Title = "Chest", Detail = "Hold to open" })
	obj.OnOpened = function()
		if active == w then
			w.ChestOpened = true
		end
	end
	w.Chest = obj
	w.Target = at
end

enter = function(step: string)
	local w = active
	if not w then
		return
	end
	if w.Step then
		table.insert(log, { Step = w.Step, How = w.How or "done" })
	end
	w.Step = step
	w.How = nil
	w.Time = 0
	w.Target = nil
	local rp = w.Rp
	local C = cfg()
	if step == "Move" then
		local hp = heroPos(rp) or Config.ArenaOrigin
		w.Target = openSpot(hp, C.RingDistance or 15, C.RingClearance or 5)
	elseif step == "Dash" then
		w.Dash0 = rp.DashUntil or 0
	elseif step == "Fight" then
		if w.Beacon then
			releaseHolds() -- the director's opening hold ends here at the latest
		end
		w.Level0 = rp.Level
		spawnFoes(w)
		setAttr(rp, "WalkTotal", w.Total)
		setAttr(rp, "WalkCount", 0)
	elseif step == "Gems" then
		setAttr(rp, "WalkCount", nil)
		setAttr(rp, "WalkTotal", nil)
		topUpGems(w)
	elseif step == "Upgrade" then
		-- nothing waiting (the gems step timed out short of a level): nothing to pick
		if rp.Level <= w.Level0 and not rp.Offer then
			w.Skip = true
		end
	elseif step == "Chest" then
		spawnChest(w)
		setAttr(rp, "WalkFree", w.First == true)
	elseif step == "Go" or step == "Beacon" then
		releaseHolds()
		w.Reveal = false -- the portal reveal follows now (StageManager; old stage loop)
	end
	setAttr(rp, "Walkthrough", step)
	setAttr(rp, "WalkTarget", w.Target)
end

local function nextStep(w)
	local steps = w.Steps or STEPS
	local i = table.find(steps, w.Step) or #steps
	if i >= #steps then
		table.insert(log, { Step = w.Step, How = w.How or "done" })
		finish("done")
		return
	end
	enter(steps[i + 1])
end

-- A step's fallback: finish its job so the next step makes sense, then move on.
local function timeout(w)
	w.How = "timeout"
	local rp = w.Rp
	if w.Step == "Fight" then
		for _, f in ipairs(w.Foes or {}) do
			if f.E.Alive and f.E.Uid == f.Uid then
				ctx.EnemySpawner.Kill(f.E, rp) -- their gems drop as usual
			end
		end
	elseif w.Step == "Gems" then
		ctx.XPSystem.MagnetAll(rp) -- the floor gems fly in (normal XP, no extra)
	end
	nextStep(w)
end

-- Is the current step's action done?
local function stepDone(w): boolean
	local rp = w.Rp
	local step = w.Step
	if step == "Move" then
		local hp = heroPos(rp)
		return hp ~= nil and w.Target ~= nil and (flat(hp) - flat(w.Target)).Magnitude <= (cfg().RingRadius or 4.5)
	elseif step == "Fight" then
		local left, nearest = foesLeft(w)
		setAttr(rp, "WalkCount", (w.Total or 0) - left)
		if nearest and (not w.Target or (flat(nearest) - flat(w.Target)).Magnitude > 1.5) then
			w.Target = nearest
			setAttr(rp, "WalkTarget", nearest)
		end
		return left == 0
	elseif step == "Gems" then
		return rp.Level > w.Level0
	elseif step == "Upgrade" then
		return w.Skip == true or ((rp.Level - (rp.PendingLevels or 0)) > w.Level0 and not rp.Offer)
	elseif step == "Chest" then
		return w.ChestOpened == true or (w.Chest ~= nil and w.Chest.State ~= "Ready") or w.Chest == nil
	elseif step == "Dash" then
		return (rp.DashUntil or 0) > (w.Dash0 or 0)
	elseif step == "Go" or step == "Beacon" then
		return w.Time >= (cfg().GoSeconds or 6)
	end
	return true
end

------------------------------------------------------------------------------------------
-- Public
------------------------------------------------------------------------------------------

--[[
	RunManager.beginRun, for each run player before Stats.Runs counts the run: starts the
	walkthrough when the player qualifies (see the header). Marks it done in the save at
	once (never twice, even when the run is cut short).
]]
function Walkthrough.Consider(rp, data, teamSize: number, mode: string?)
	if not data or not eligible(rp, data, teamSize, mode) then
		return false
	end
	local first = data.WalkthroughDone ~= true
	data.WalkthroughDone = true
	data.WalkthroughReplay = false
	local beacon = beaconRun()
	active = {
		Rp = rp,
		Step = nil,
		Time = 0,
		Clock = 0, -- run time since the start (the director's opening hold)
		Reveal = not beacon, -- a beacon run has no portal reveal to hold
		Level0 = rp.Level or 1,
		First = first,
		Beacon = beacon,
		Steps = beacon and BEACON_STEPS or STEPS,
	}
	rp.Walkthrough = true
	table.clear(log)
	if ctx.EnemySpawner.SetHold then
		ctx.EnemySpawner.SetHold(HOLD, true)
	end
	setAttr(rp, "WalkMode", beacon and "Beacon" or nil)
	enter("Move")
	return true
end

-- True while the walkthrough keeps the stage-1 portal hidden (steps before Go).
function Walkthrough.HoldsReveal(): boolean
	local w = active
	return w ~= nil and w.Reveal == true
end

-- True while a walkthrough is running (on the old stage loop its waves are held until Go).
function Walkthrough.Active(): boolean
	return active ~= nil
end

-- True while the walkthrough holds the spawns (a beacon run: only its short opening).
function Walkthrough.Holding(): boolean
	local w = active
	return w ~= nil and not w.Released
end

-- For tests: the current step (nil when none), the log, and the live state.
function Walkthrough.Current(): (string?, { { Step: string, How: string? } }, { [string]: any }?)
	return active and active.Step or nil, log, active
end

function Walkthrough.Step(dt: number)
	local w = active
	if not w then
		return
	end
	local rp = w.Rp
	local RM = ctx.RunManager
	-- cut short: the run ended, the player left / fell, DEV tools, tips switched off
	if not RM.IsRunning() or not table.find(RM.GetRunPlayers(), rp) or not rp.Player.Parent then
		finish("run")
		return
	end
	if not rp.Alive or rp.Returned then
		finish("down")
		return
	end
	if rp.DevTainted then
		finish("dev")
		return
	end
	local data = ctx.DataService.GetData(rp.Player)
	if data and type(data.Settings) == "table" and data.Settings.Tips == false then
		finish("tips")
		return
	end
	if not enabled() or ctx.StageManager.GetStage() ~= 1 then
		finish("off")
		return
	end
	-- actions count even while the world is frozen (the level-up panel opens and closes
	-- behind a freeze); the fallback clock only runs with the run clock
	if stepDone(w) then
		nextStep(w)
		return
	end
	if not RM.IsSimulating() then
		return
	end
	w.Time += dt
	w.Clock += dt
	-- a beacon run: the director's spawns wait at most OpeningHold seconds of run time
	if w.Beacon and not w.Released and w.Clock >= (cfg().OpeningHold or 10) then
		releaseHolds()
	end
	local limit = (cfg().Timeouts or {})[w.Step]
	if limit and w.Time >= limit then
		timeout(w)
	end
end

function Walkthrough.Init(c)
	ctx = c
	if ctx.LootSystem and ctx.LootSystem.OnBuilt then
		ctx.LootSystem.OnBuilt(function(a)
			arenaSeen = a
		end)
	end
end

function Walkthrough.Start() end

return Walkthrough
