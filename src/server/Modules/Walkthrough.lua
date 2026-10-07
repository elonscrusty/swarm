--[[
	Walkthrough.lua
	The interactive first-run walkthrough (Config.Features.Walkthrough, Config.Walkthrough,
	docs/next/WALKTHROUGH.md). A server step machine that WAITS for the player:

	  Move     a gold ground ring ~RingDistance studs away in open ground; no enemies yet.
	           Done when the hero stands in it.
	  Fight    EnemyCount weak, slow enemies around the hero; done when all are beaten.
	  Gems     their gems: done when the first level-up opens (a top-up gem is dropped
	           when the floor gems are not enough for that level).
	  Upgrade  done when a card is picked (skipped when no level is waiting).
	  Chest    a free chest ~ChestDistance studs away (LootSystem.AddFeatureChest, normal
	           reward, opened exactly once by the loot system); done when it is opened.
	  Go       "Waves are coming!": the held waves and the portal reveal are released; the
	           walkthrough ends GoSeconds later.

	Who: RunManager.beginRun calls Consider for each run player before Stats.Runs counts the
	run. Only Solo, Standard, no curses / Endless / Daily, not DEV-tainted, tips on, the
	first-run flow on (Config.FirstRun.AutoStart), and either the account's very first run
	(Stats.Runs 0, TutorialDone false) or Settings > Replay tips (save WalkthroughReplay).
	It is marked done (save WalkthroughDone) when it starts, so it never runs twice.

	Holds: EnemySpawner.SetHold("Walkthrough", on) keeps the first wave back; StageManager
	asks HoldsReveal() before the stage-1 portal reveal. Both let go at Go, or whenever the
	walkthrough ends early (death, leaving, run end, DEV tools, tips switched off).

	Timers: each step auto-completes after Config.Walkthrough.Timeouts[step] seconds of
	run time (only while RunManager.IsSimulating: pause, panels and travel stop it).

	Client view (player attributes, WalkthroughClient.lua): Walkthrough = step name or nil,
	WalkCount / WalkTotal (Fight progress), WalkTarget (Vector3 the bubble and the world
	marker point at, or nil).
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

local Walkthrough = {}

local ctx
local arena: any = nil -- the current stage's arena (LootSystem.OnBuilt)

local STEPS = { "Move", "Fight", "Gems", "Upgrade", "Chest", "Go" }
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

-- Open ground at `dist` studs from `from` (EnemyAI obstacles, inside the arena, away from
-- other loot); tries 16 angles from a random start, then shorter rings.
local function openSpot(from: Vector3, dist: number, clearance: number): Vector3
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
			if ok then
				return Vector3.new(x, c.Y, z)
			end
		end
	end
	return Vector3.new(from.X, c.Y, from.Z) + Vector3.new(dist * 0.4, 0, 0)
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
	if rp.DevTainted or rp.Endless or rp.Daily then
		return false
	end
	if type(data.Settings) == "table" and data.Settings.Tips == false then
		return false
	end
	-- the very first run (never run before), or Settings > Replay tips (overrides Done)
	local first = data.WalkthroughDone ~= true and data.TutorialDone ~= true and type(data.Stats) == "table" and (tonumber(data.Stats.Runs) or 0) == 0
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
	if ctx.EnemySpawner.SetHold then
		ctx.EnemySpawner.SetHold(HOLD, false, cfg().ReleaseWaveDelay)
	end
end

local function clearAttrs(rp)
	setAttr(rp, "Walkthrough", nil)
	setAttr(rp, "WalkCount", nil)
	setAttr(rp, "WalkTotal", nil)
	setAttr(rp, "WalkTarget", nil)
end

-- Ends the walkthrough (finished or cut short); leaves no hold behind.
local function finish(reason: string)
	local w = active
	if not w then
		return
	end
	active = nil
	releaseHolds()
	-- its enemies stay (they are normal enemies by now); its chest stays openable
	clearAttrs(w.Rp)
	table.insert(log, { Step = "End", How = reason })
end

local function spawnFoes(w)
	local C = cfg()
	local hp = heroPos(w.Rp) or Config.ArenaOrigin
	local n = math.max(1, math.floor(C.EnemyCount or 5))
	w.Foes = {}
	local offset = math.random() * math.pi * 2
	local c = arena and arena.Center or Config.ArenaOrigin
	local half = (arena and arena.Half or Config.Arenas.Size / 2) - 6
	for i = 1, n do
		for try = 0, 5 do
			local a = offset + (i / n) * math.pi * 2 + try * 0.35
			local d = (C.EnemyDistance or 20) * (1 - try * 0.08)
			local x = math.clamp(hp.X + math.cos(a) * d, c.X - half, c.X + half)
			local z = math.clamp(hp.Z + math.sin(a) * d, c.Z - half, c.Z + half)
			if not ctx.EnemyAI.IsBlocked(x, z, 1.6) or try == 5 then
				local e = ctx.EnemySpawner.Spawn(C.EnemyType or "Slime", Vector3.new(x, c.Y, z), { HP = C.EnemyHP or 4, Force = true })
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
	local ok, obj = pcall(ctx.LootSystem.AddFeatureChest, arena, C.ChestType or "Small", at, true)
	if not ok or not obj then
		warn("[Walkthrough] chest failed: " .. tostring(obj))
		return
	end
	ctx.LootSystem.SetObjState(obj, "Ready", { Title = "Gift Chest", Detail = "Free · hold to open" })
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
	elseif step == "Fight" then
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
	elseif step == "Go" then
		releaseHolds()
		w.Reveal = false -- the portal reveal follows now (StageManager)
	end
	setAttr(rp, "Walkthrough", step)
	setAttr(rp, "WalkTarget", w.Target)
end

local function nextStep(w)
	local i = table.find(STEPS, w.Step) or #STEPS
	if i >= #STEPS then
		table.insert(log, { Step = w.Step, How = w.How or "done" })
		finish("done")
		return
	end
	enter(STEPS[i + 1])
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
	elseif step == "Go" then
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
	data.WalkthroughDone = true
	data.WalkthroughReplay = false
	active = { Rp = rp, Step = nil, Time = 0, Reveal = true, Level0 = rp.Level or 1 }
	rp.Walkthrough = true
	table.clear(log)
	if ctx.EnemySpawner.SetHold then
		ctx.EnemySpawner.SetHold(HOLD, true)
	end
	enter("Move")
	return true
end

-- True while the walkthrough keeps the stage-1 portal hidden (steps before Go).
function Walkthrough.HoldsReveal(): boolean
	local w = active
	return w ~= nil and w.Reveal == true
end

-- True while a walkthrough is running (waves held until Go).
function Walkthrough.Active(): boolean
	return active ~= nil
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
	local limit = (cfg().Timeouts or {})[w.Step]
	if limit and w.Time >= limit then
		timeout(w)
	end
end

function Walkthrough.Init(c)
	ctx = c
	if ctx.LootSystem and ctx.LootSystem.OnBuilt then
		ctx.LootSystem.OnBuilt(function(a)
			arena = a
		end)
	end
end

function Walkthrough.Start() end

return Walkthrough
