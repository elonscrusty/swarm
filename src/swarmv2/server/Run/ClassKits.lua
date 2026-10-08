--[[
	SwarmV2/Run/ClassKits.lua  (ServerScriptService.SwarmV2.Run.ClassKits)
	OWNER: gameplay track (Chat 2). The four class kits: passives and movement reactions.
	Numbers: RunConfig.Classes. Table of rules: docs/redesign/gameplay/CLASSES.md.

	  Ruckus         Loot Rush      every PickupsPerCharge chest / shrine / item pickups load one Scrap
	                                Barrage (max 1); the next Scrap Toss volley adds a ring of scraps
	                 dash           drops rolling cans that explode (OnDash)
	  Toastmaster    Overheat       3 Toast Volley hits on one enemy within 4 s = Burn 3 s (refresh only)
	                 landing blast  OnLanded after >= 0.35 s in the air, 2 s cooldown
	  Captain Croak  Big Splash     a leap landing (OnLeapLanded) with an enemy within 10 empowers the
	                                next bubble (x1.8 damage, x1.4 burst radius), max 1
	  Granny Boom    Tangled Up     a yarn explosion tangles (SlowUntil / SlowMult), capped per enemy
	                 boost scorch   the Rocket Boost leaves fire patches along its path (OnDash)

	Every derived hit (burn, can, blast, scorch, tangle) is dealt through WeaponSystem as NoProc.

	Called from other modules (all through ctx.ClassKits, which RunBoot sets):
	  ItemSystem.Grant (reward pickups) -> OnLootPickup;   WeaponSystem -> TakeBarrage, TakeSplash,
	  OnToastHit, OnYarnHit, Config.   Dash (movement helper) -> OnDash(rp, kind, dir),
	  OnLeapLanded(rp), OnLanded(rp, airtime): Init() wires them onto the Dash module when
	  src/swarmv2/server/Run/Dash.lua exists and calls Dash.OnDash / .OnLeapLanded / .OnLanded
	  through its module table; without Dash nothing here runs and nothing errors.

	HUD state (player attributes, set by the server, UI only):
	  ClassKit    "LootRush" | "Overheat" | "BigSplash" | "TangledUp"
	  ClassCharge 0..1 progress (Ruckus pickups/5, 1 when a barrage is stored; Toastmaster heat of
	              the hottest target; Croak 1 when empowered; Granny 1 while the boost scorches)
	  ClassReady  true = a charge is stored / the effect is active (barrage ready, burning target,
	              empowered bubble, scorching)
	  ClassStored whole number stored (barrages / empowered bubbles), 0 otherwise
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RunConfig = require(ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run"):WaitForChild("RunConfig"))
local K = RunConfig.Classes

local FLAT = Vector3.new(1, 0, 1)
local KIT_NAMES = { ruckus = "LootRush", toastmaster = "Overheat", captain_croak = "BigSplash", granny_boom = "TangledUp" }

local ClassKits = {}

local ctx: any
local Dash: any = nil

-- per-run-player state; weak so a finished run's state is collected
local states: { [any]: any } = setmetatable({} :: { [any]: any }, { __mode = "k" }) :: any

local function state(rp): any
	local s = states[rp]
	if not s then
		s = {
			Player = rp.Player,
			Picks = 0,
			Barrage = 0,
			Splash = 0,
			Heat = setmetatable({}, { __mode = "k" }), -- enemy -> { Uid, T = {hit times} }
			Top = 0, -- hottest target's heat 0..1
			TopUntil = 0,
			BurnUntil = 0,
			LandCd = 0,
			BoostUntil = 0,
			LastScorch = nil,
		}
		states[rp] = s
	end
	return s
end

local function now(): number
	return ctx.RunManager.GetRunTime()
end

local function rotateY(v: Vector3, angle: number): Vector3
	local c, s = math.cos(angle), math.sin(angle)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function flat(v: Vector3, fallback: Vector3): Vector3
	local f = v * FLAT
	if f.Magnitude < 1e-3 then
		return fallback
	end
	return f.Unit
end

local function skipDead(e): boolean
	return not e.Alive
end

function ClassKits.Config()
	return K
end

------------------------------------------------------------------------------------------
-- Ruckus: Loot Rush
------------------------------------------------------------------------------------------

-- A reward pickup (chest, shrine, merchant item, caravan ...): ItemSystem.Grant with reward = true.
-- XP gems never reach this.
function ClassKits.OnLootPickup(rp, _source: string?)
	if rp.CharacterId ~= "ruckus" then
		return
	end
	local L = K.LootRush
	local s = state(rp)
	if s.Barrage >= L.MaxStored then
		return -- already loaded: pickups do not bank up beyond it
	end
	s.Picks += 1
	if s.Picks >= L.PickupsPerCharge then
		s.Picks = 0
		s.Barrage += 1
		if rp.Root then
			ctx.Fx.Ring(rp.Root.Position, 6, Color3.fromRGB(240, 200, 90))
		end
	end
end

-- Scrap Toss asks at each volley: true = fire the stored barrage ring too (consumes it).
function ClassKits.TakeBarrage(rp): boolean
	if rp.CharacterId ~= "ruckus" then
		return false
	end
	local s = states[rp]
	if s and s.Barrage > 0 then
		s.Barrage -= 1
		return true
	end
	return false
end

------------------------------------------------------------------------------------------
-- Toastmaster: Overheat
------------------------------------------------------------------------------------------

-- A Toast Volley slice hit enemy `e` (alive after the hit) for `damage`.
function ClassKits.OnToastHit(rp, e, damage: number, weapon: any, t: number)
	if rp.CharacterId ~= "toastmaster" then
		return
	end
	local O = K.Overheat
	local s = state(rp)
	local h = s.Heat[e]
	if not h or h.Uid ~= e.Uid then
		h = { Uid = e.Uid, T = {} }
		s.Heat[e] = h
	end
	local list = h.T
	for i = #list, 1, -1 do
		if t - list[i] > O.Window then
			table.remove(list, i)
		end
	end
	table.insert(list, t)
	if #list >= O.Hits then
		table.clear(list)
		ctx.WeaponSystem.Ignite(rp, e, O.BurnSeconds, damage * O.TickShare, O.TickEvery, weapon)
		s.BurnUntil = t + O.BurnSeconds
		s.Top = 1
		s.TopUntil = t + 0.6
	else
		local frac = #list / O.Hits
		if frac >= s.Top or t >= s.TopUntil then
			s.Top = frac
			s.TopUntil = t + O.Window
		end
	end
end

------------------------------------------------------------------------------------------
-- Captain Croak: Big Splash
------------------------------------------------------------------------------------------

-- Bubble Bomb asks at each volley: the empowerment (consumed) or nil.
function ClassKits.TakeSplash(rp): any?
	if rp.CharacterId ~= "captain_croak" then
		return nil
	end
	local s = states[rp]
	if s and s.Splash > 0 then
		s.Splash -= 1
		return K.BigSplash
	end
	return nil
end

-- Dash hook: the leap landed.
function ClassKits.OnLeapLanded(rp)
	if rp.CharacterId ~= "captain_croak" or not rp.Alive or not rp.Root then
		return
	end
	local B = K.BigSplash
	local s = state(rp)
	if s.Splash >= B.MaxStored then
		return
	end
	local p = rp.Root.Position
	local grid = ctx.EnemySpawner.Grid
	local near = grid:Nearest(p.X, p.Z, B.EnemyRange, skipDead)
	if near then
		s.Splash = B.MaxStored
		ctx.Fx.Ring(p, 7, Color3.fromRGB(130, 215, 235))
	end
end

------------------------------------------------------------------------------------------
-- Granny Boom: Tangled Up
------------------------------------------------------------------------------------------

-- A yarn explosion hit enemy `e` (alive): tangle it. EnemyAI scales speed by SlowMult until
-- SlowUntil. Bosses are tangled shorter and weaker; per enemy at most CapSeconds of tangle per
-- CapWindow seconds.
function ClassKits.OnYarnHit(rp, e, t: number)
	if rp.CharacterId ~= "granny_boom" or not e.Alive then
		return
	end
	local T = K.TangledUp
	local seconds = e.Boss and T.BossSeconds or T.Seconds
	local slow = e.Boss and T.BossSlow or T.Slow
	local win = e.TangleWin
	if type(win) ~= "table" or win.Uid ~= e.Uid or t - win.Start >= T.CapWindow then
		win = { Uid = e.Uid, Start = t, Used = 0 }
		e.TangleWin = win
	end
	local add = math.min(seconds, T.CapSeconds - win.Used)
	if add <= 0 then
		return
	end
	win.Used += add
	local mult = 1 - slow
	if e.SlowUntil and e.SlowUntil > t and (e.SlowMult or 1) < mult then
		return -- a stronger slow is already running: never weakened
	end
	e.SlowMult = mult
	e.SlowUntil = math.max(e.SlowUntil or 0, t + add)
	e.TerrainSlow = nil
end

------------------------------------------------------------------------------------------
-- Movement reactions (Dash hooks)
------------------------------------------------------------------------------------------

-- Dash hook: rp dashed / boosted / leapt (`kind`) along unit direction `dir`.
function ClassKits.OnDash(rp, _kind: string?, dir: Vector3)
	if not rp.Alive or not rp.Root then
		return
	end
	local id = rp.CharacterId
	if id == "ruckus" then
		local C = K.DashCans
		local stats = ctx.WeaponSystem.ClassWeaponStats(rp, "ScrapToss")
		if not stats then
			return
		end
		local back = -flat(dir, rp.Facing or Vector3.new(0, 0, -1))
		local spread = math.rad(C.SpreadDegrees)
		for i = 1, C.Count do
			local sign = (i % 2 == 0) and 1 or -1
			local d = rotateY(back, sign * spread * math.ceil(i / 2))
			ctx.WeaponSystem.DropCan(rp, rp.Root.Position, d, stats.damage * C.DamageMult, C.Radius, C.Fuse, C.RollSpeed, C.MaxLive)
		end
	elseif id == "granny_boom" then
		local S = K.Scorch
		local s = state(rp)
		s.BoostUntil = now() + S.Duration
		s.LastScorch = nil -- the first patch drops at once (Step)
	end
end

-- Dash hook: landed after `airtime` seconds in the air (jump or spring jump).
function ClassKits.OnLanded(rp, airtime: number)
	if rp.CharacterId ~= "toastmaster" or not rp.Alive or not rp.Root then
		return
	end
	local B = K.LandingBlast
	if type(airtime) ~= "number" or airtime < B.MinAirtime then
		return
	end
	local s = state(rp)
	local t = now()
	if t < s.LandCd then
		return
	end
	local stats, w = ctx.WeaponSystem.ClassWeaponStats(rp, "ToastVolley")
	if not stats then
		return
	end
	s.LandCd = t + B.Cooldown
	ctx.WeaponSystem.ClassBurst(rp, rp.Root.Position, B.Radius, stats.damage * B.DamageMult, w)
end

------------------------------------------------------------------------------------------
-- Per frame: Granny's scorch trail, HUD attributes, cleanup
------------------------------------------------------------------------------------------

local ATTRS = { "ClassKit", "ClassCharge", "ClassReady", "ClassStored" }

local function clearAttrs(player: Player?)
	if player and player.Parent then
		for _, a in ipairs(ATTRS) do
			player:SetAttribute(a, nil)
		end
	end
end

local function round2(n: number): number
	return math.floor(n * 100 + 0.5) / 100
end

local function publish(rp, s, t: number)
	local id = rp.CharacterId
	local kit = KIT_NAMES[id]
	local player = rp.Player
	if not kit or not player then
		return
	end
	local charge, ready, stored = 0, false, 0
	if id == "ruckus" then
		stored = s.Barrage
		ready = stored > 0
		charge = ready and 1 or s.Picks / K.LootRush.PickupsPerCharge
	elseif id == "toastmaster" then
		ready = t < s.BurnUntil
		charge = (t < s.TopUntil) and s.Top or 0
	elseif id == "captain_croak" then
		stored = s.Splash
		ready = stored > 0
		charge = ready and 1 or 0
	elseif id == "granny_boom" then
		ready = t < s.BoostUntil
		charge = ready and 1 or 0
	end
	player:SetAttribute("ClassKit", kit)
	player:SetAttribute("ClassCharge", round2(charge))
	player:SetAttribute("ClassReady", ready)
	player:SetAttribute("ClassStored", stored)
end

function ClassKits.Step(_dt: number)
	local seen: { [any]: boolean } = {}
	if ctx.RunManager.IsSimulating() then
		local t = now()
		for _, rp in ipairs(ctx.RunManager.GetRunPlayers()) do
			if KIT_NAMES[rp.CharacterId] then
				local s = state(rp)
				seen[rp] = true
				-- Granny's Rocket Boost leaves fire along its path
				if rp.CharacterId == "granny_boom" and rp.Alive and rp.Root and t < s.BoostUntil then
					local S = K.Scorch
					local pos = rp.Root.Position
					if not s.LastScorch or ((pos - s.LastScorch) * FLAT).Magnitude >= S.Spacing then
						s.LastScorch = pos
						local stats = ctx.WeaponSystem.ClassWeaponStats(rp, "YarnBomb")
						if stats then
							ctx.WeaponSystem.Scorch(rp, pos, S.Radius, stats.damage * S.DamageMult, S.Life, S.Tick, S.MaxPatches)
						end
					end
				end
				publish(rp, s, t)
			end
		end
	end
	for rp, s in pairs(states) do
		if not seen[rp] then
			clearAttrs(s.Player)
			states[rp] = nil
		end
	end
end

------------------------------------------------------------------------------------------
-- Boot
------------------------------------------------------------------------------------------

-- Hooks `fn` onto Dash[name]: a signal (Connect) is connected, a function is chained after the
-- existing one, nothing there means Dash calls fn directly.
local function hook(name: string, fn: (...any) -> ())
	local safe = function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			warn("[ClassKits] " .. name .. " error: " .. tostring(err))
		end
	end
	local prev = Dash[name]
	if type(prev) == "table" and type(prev.Connect) == "function" then
		prev:Connect(safe)
	elseif type(prev) == "function" then
		Dash[name] = function(...)
			prev(...)
			safe(...)
		end
	else
		Dash[name] = safe
	end
end

function ClassKits.Init(c: any)
	ctx = c
	ctx.ClassKits = ClassKits
	-- the movement helper's module; optional
	local mod = script.Parent:FindFirstChild("Dash")
	if mod and mod:IsA("ModuleScript") then
		local ok, result = pcall(require, mod)
		if ok and type(result) == "table" then
			Dash = result
		else
			warn("[ClassKits] Dash module failed to load: " .. tostring(result))
		end
	end
	if Dash then
		hook("OnDash", ClassKits.OnDash)
		hook("OnLeapLanded", ClassKits.OnLeapLanded)
		hook("OnLanded", ClassKits.OnLanded)
	end
	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(ClassKits.Step, math.min(dt, 0.1))
		if not ok then
			warn("[ClassKits] Step error: " .. tostring(err))
		end
	end)
end

return ClassKits
