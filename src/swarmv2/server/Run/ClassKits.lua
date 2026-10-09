--[[
	SwarmV2/Run/ClassKits.lua  (ServerScriptService.SwarmV2.Run.ClassKits)
	OWNER: gameplay track (Chat 2), stream C. The twelve class kits: passives and movement hooks
	(continuation brief "Twelve approved classes"). Numbers: RunConfig.Classes. Rules table:
	docs/redesign/gameplay/CLASSES.md. Signature weapons: WeaponSystem (Fire.Rank*).

	  Ruckus         Junk Collector  5 chest / item rewards (not XP shards) store 1 barrage: the next
	                                 Scrap Shot fires 3 scraps of 0.60 B (TakeBarrage)
	                 dash            2 rolling cans, 0.40 B r5 after 0.90 s, one can hit per target per dash
	  Toastmaster    Overheat        3 direct toast hits on one target within 5 s = scorch, counter reset
	                 spring jump     apex 12 (client); landing after an intentional jump: r6 0.35 B blast,
	                                 2 s cooldown (stairs / slopes / falls / pads never count)
	  Captain Croak  Big Splash      a leap landing within 10 of an enemy stores 1 empowered bubble
	                                 (+30 % burst), expires after 6 s (TakeSplash); leap = Dash variant
	  Granny Boom    Tangled Up      yarn damage slows 35 % for 0.75 s (refresh only, bosses 10 %)
	  Coach Crunch   Warm-Up         2 s above 18 studs/s charges the tackle: the dash hits up to 4
	                                 enemies once, 0.60 B charged / 0.30 B uncharged, 0.25 s stagger
	  Doug           Clean Route     +4 pickup (roster bonus); dash: a 16-stud wet trail, 2 s, 25 % slow
	  Peter Parkour  Stride          2 s above 20 studs/s: the next Returning Sneakers throw +30 %
	                                 (TakeStride), expires after 6 s; charged jump 11 (client, 6 s)
	  Barry Plotter  Garden Company  plants within 12 of Barry +15 % (WeaponSystem); dash: an extra
	                                 seed at the dash origin, 6 s cooldown, shares the plant cap
	  Rambozo        Punchline       +10 crit points vs enemies above 70 % HP (rp.KitCritHigh, read by
	                                 WeaponSystem); dash: a balloon grenade 0.40 B r6 + 2 mini-pops 0.15 B
	  Swolverine     Gains           1 % max HP per 10 credited kills, at most 1 heal per s; a dash end
	                                 gives +15 % damage for 2 s (refreshed, never stacked)
	  Crash Cassidy  Momentum        +0..15 % damage as speed goes 12 -> 30 studs/s; body-check dash
	                                 0.35 B to up to 4 enemies with knockback (cooldown 2.20: variant)
	  Knuckles       Heavy Hands     +25 % knockback on normal enemies (rp.KitKnockMult); a dash ending
	                                 within 6 of an enemy adds 1 Glove Combo charge (once per dash)

	Kit damage goes through WeaponSystem.KitBurst / Damage with the rank of the class signature
	(secondary: no crit, no procs). Damage bonuses (Momentum, dash recovery) are added to the stat
	sheet's additive damage bonus inside the shared 0..2 clamp. Cross-class signatures never bring
	these hooks: every hook checks rp.CharacterId.

	Called from other modules (through ctx.ClassKits, which RunBoot sets):
	  ItemSystem.Grant (item rewards) / LootSystem (a chest choice, stream E2) -> OnLootPickup
	  WeaponSystem -> TakeBarrage, TakeSplash, TakeStride, OnToastHit, OnYarnHit, Config
	  Dash (signals) -> OnDash(rp, kind, dir), OnLeapLanded(rp), OnLanded(rp, airtime)

	HUD state (player attributes, server-set, UI only):
	  ClassKit         the passive id (RunConfig / ClassRoster KitName: "JunkCollector", ...)
	  ClassCharge      0..1 progress          ClassReady   a charge is stored / the effect is on
	  ClassStored      whole number stored    ClassChargeText  "3/5", "Ready", "+8%", "2/3" ...
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RunFolder = ReplicatedStorage:WaitForChild("SwarmV2"):WaitForChild("Run")
local RunConfig = require(RunFolder:WaitForChild("RunConfig"))
local BuildRules = require(RunFolder:WaitForChild("BuildRules"))
local ClassRoster = require(RunFolder:WaitForChild("ClassRoster"))
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))
local K = RunConfig.Classes

local FLAT = Vector3.new(1, 0, 1)
local PUBLISH_EVERY = 0.1

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
			Id = rp.CharacterId,
			-- measured horizontal speed (studs/s) and since when it is above the class threshold
			Speed = 0,
			FastSince = nil,
			-- damage bonus patch (Momentum, dash recovery)
			Sheet = nil,
			KitDB = 0,
			-- the current dash
			DashEnd = nil,
			-- Ruckus
			Picks = 0,
			Barrage = 0,
			-- Toastmaster
			Heat = setmetatable({}, { __mode = "k" }),
			Top = 0,
			TopUntil = 0,
			FlashUntil = 0,
			LandCd = 0,
			JumpAt = nil,
			Blasts = 0,
			Scorches = 0,
			-- Captain Croak
			Splash = 0,
			SplashUntil = 0,
			-- Granny Boom
			Tangled = setmetatable({}, { __mode = "k" }),
			-- Coach Crunch
			WarmCharged = false,
			-- Doug
			Trail = nil,
			-- Peter
			Stride = false,
			StrideUntil = 0,
			-- Barry
			SeedCd = 0,
			-- Swolverine
			KillsSeen = nil,
			KillCount = 0,
			HealBank = 0,
			HealAt = -math.huge,
			Heals = 0,
			RecoveryUntil = 0,
			-- Crash
			Momentum = 0,
			-- HUD
			PublishAt = 0,
		}
		states[rp] = s
		-- passives read by WeaponSystem's shared hit code
		if rp.CharacterId == "knuckles_mcgee" then
			rp.KitKnockMult = K.HeavyHands.KnockMult
		elseif rp.CharacterId == "rambozo" then
			rp.KitCritHigh = { Share = K.Punchline.HpShare, Bonus = K.Punchline.CritBonus }
		end
	end
	return s
end

local function now(): number
	return ctx.RunManager.GetRunTime()
end

local function living(rp): boolean
	return rp.Alive == true and not rp.Downed and rp.Root ~= nil
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

local function signatureOf(rp): string?
	return WeaponData.Signatures[rp.CharacterId]
end

function ClassKits.Config()
	return K
end

-- (tests) the kit state of a run player.
function ClassKits.State(rp): any
	return state(rp)
end

------------------------------------------------------------------------------------------
-- Damage bonus inside the shared clamp (Momentum, Swolverine's dash recovery)
------------------------------------------------------------------------------------------

-- Sets the kit's extra additive damage bonus: the sheet's DamageBonus becomes clamp(own + bonus)
-- (0..2) and Might follows. A recomputed sheet (LevelUpSystem.RecomputeStats makes a new table) is
-- noticed and patched again on the next step.
local function setKitBonus(rp, s, bonus: number)
	local sheet = rp.Stats
	if type(sheet) ~= "table" then
		return
	end
	if s.Sheet ~= sheet then
		s.Sheet = sheet
		s.BaseDB = sheet.DamageBonus or ((sheet.Might or 1) - 1)
		s.BaseMight = sheet.Might or 1
		s.KitDB = 0
	end
	if math.abs(bonus - s.KitDB) < 1e-3 then
		return
	end
	s.KitDB = bonus
	local base = BuildRules.DamageBonus(s.BaseDB)
	local db = BuildRules.DamageBonus(s.BaseDB + bonus)
	if sheet.DamageBonus ~= nil then
		sheet.DamageBonus = db
	end
	sheet.Might = s.BaseMight * (1 + db) / (1 + base)
	rp.KitDamageBonus = bonus
end

------------------------------------------------------------------------------------------
-- Ruckus: Junk Collector
------------------------------------------------------------------------------------------

-- An eligible reward: a chest (LootSystem's chest choice), a shrine / merchant / encounter
-- item (ItemSystem.Grant reward = true). XP shards never reach this. Rewards while a barrage is
-- already stored do not count.
function ClassKits.OnLootPickup(rp, _source: string?)
	if rp.CharacterId ~= "ruckus" then
		return
	end
	local J = K.JunkCollector
	local s = state(rp)
	if s.Barrage >= J.MaxStored then
		return
	end
	s.Picks += 1
	if s.Picks >= J.RewardsPerCharge then
		s.Picks = 0
		s.Barrage += 1
		if rp.Root then
			ctx.Fx.Ring(rp.Root.Position, 6, Color3.fromRGB(240, 200, 90))
		end
	end
	s.PublishAt = 0
end

-- Scrap Shot asks at each attack: the barrage config (one stored charge consumed) or nil.
function ClassKits.TakeBarrage(rp): any?
	if rp.CharacterId ~= "ruckus" then
		return nil
	end
	local s = states[rp]
	if s and s.Barrage > 0 then
		s.Barrage -= 1
		s.PublishAt = 0
		return K.JunkCollector
	end
	return nil
end

------------------------------------------------------------------------------------------
-- Toastmaster: Overheat + landing blast
------------------------------------------------------------------------------------------

-- A toast hit enemy `e` (alive after the hit). direct = false for ricochets and follow-ups.
function ClassKits.OnToastHit(rp, e, _damage: number, weapon: any, t: number, direct: boolean?)
	if rp.CharacterId ~= "toastmaster" or direct == false or not e.Alive then
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
		if t - list[i] > O.Window or list[i] > t then
			table.remove(list, i)
		end
	end
	table.insert(list, t)
	if #list >= O.Hits then
		table.clear(list) -- the target's heat counter resets
		ctx.WeaponSystem.ApplyScorch(rp, e, O.ScorchMult, weapon)
		s.Scorches += 1
		s.Top = 1
		s.TopUntil = t + 0.6
		s.FlashUntil = t + 0.6
	else
		local frac = #list / O.Hits
		if frac >= s.Top or t >= s.TopUntil then
			s.Top = frac
			s.TopUntil = t + O.Window
		end
	end
	s.PublishAt = 0
end

-- The server saw the Toastmaster's root rise like a jump (Step, or tests).
function ClassKits.NoteJump(rp)
	state(rp).JumpAt = now()
end

-- Dash hook: landed after `airtime` s in the air. Toastmaster: the landing blast, only after an
-- intentional jump (a rise noted since the last landing), at most once per Cooldown.
function ClassKits.OnLanded(rp, airtime: number)
	if rp.CharacterId ~= "toastmaster" or not living(rp) then
		return
	end
	local B = K.LandingBlast
	local s = state(rp)
	local t = now()
	local jumped = s.JumpAt
	s.JumpAt = nil -- one landing per jump
	if type(airtime) ~= "number" or airtime < B.MinAirtime or not jumped or t - jumped > B.JumpMaxAir then
		return
	end
	if t < s.LandCd then
		return
	end
	s.LandCd = t + B.Cooldown
	s.Blasts += 1
	local at = rp.Root.Position
	ctx.WeaponSystem.KitBurst(rp, at, B.Radius, B.Coeff, signatureOf(rp), { Close = true, Fx = false })
	ctx.Fx.Explosion(at, B.Radius)
end

------------------------------------------------------------------------------------------
-- Captain Croak: Big Splash
------------------------------------------------------------------------------------------

-- Bubble Bomb asks at each attack: the empowerment (consumed) or nil. It expires after Expiry s.
function ClassKits.TakeSplash(rp): any?
	if rp.CharacterId ~= "captain_croak" then
		return nil
	end
	local s = states[rp]
	if s and s.Splash > 0 then
		s.Splash = 0
		s.PublishAt = 0
		if now() <= s.SplashUntil then
			return K.BigSplash
		end
	end
	return nil
end

-- Dash hook: the leap landed (once per leap). A living enemy within EnemyRange stores the splash.
function ClassKits.OnLeapLanded(rp)
	if rp.CharacterId ~= "captain_croak" or not living(rp) then
		return
	end
	local B = K.BigSplash
	local s = state(rp)
	local p = rp.Root.Position
	if #ctx.WeaponSystem.KitQuery(p, B.EnemyRange) > 0 then
		s.Splash = B.MaxStored
		s.SplashUntil = now() + B.Expiry
		s.PublishAt = 0
		ctx.Fx.Ring(p, 7, Color3.fromRGB(130, 215, 235))
	end
end

------------------------------------------------------------------------------------------
-- Granny Boom: Tangled Up
------------------------------------------------------------------------------------------

-- Yarn damage on enemy `e` (alive): a 35 % slow for 0.75 s (WeaponSystem.ApplySlow: strongest slow
-- only, refresh never extends past Seconds from now, bosses capped at 10 %).
function ClassKits.OnYarnHit(rp, e, t: number)
	if rp.CharacterId ~= "granny_boom" or not e.Alive then
		return
	end
	local T = K.TangledUp
	ctx.WeaponSystem.ApplySlow(e, T.Slow, T.Seconds)
	state(rp).Tangled[e] = t + T.Seconds
end

------------------------------------------------------------------------------------------
-- Peter Parkour: Stride
------------------------------------------------------------------------------------------

-- Returning Sneakers asks at each throw: the extra damage bonus (charge consumed) or nil.
function ClassKits.TakeStride(rp): number?
	if rp.CharacterId ~= "peter_parkour" then
		return nil
	end
	local s = states[rp]
	if s and s.Stride then
		s.Stride = false
		s.FastSince = nil -- a new charge needs a new 2 s run
		s.PublishAt = 0
		if now() <= s.StrideUntil then
			return K.Stride.DamageBonus
		end
	end
	return nil
end

------------------------------------------------------------------------------------------
-- Movement hooks (Dash signals)
------------------------------------------------------------------------------------------

-- Dash hook: rp dashed / leapt (`kind`) along unit direction `dir`.
function ClassKits.OnDash(rp, kind: string?, dir: Vector3)
	if not living(rp) then
		return
	end
	local id = rp.CharacterId
	local s = state(rp)
	local origin = rp.Root.Position
	local d = flat(typeof(dir) == "Vector3" and dir or Vector3.zero, rp.Facing or Vector3.new(0, 0, -1))
	local WS = ctx.WeaponSystem
	s.DashEnd = (type(rp.DashUntil) == "number" and rp.DashUntil > os.clock()) and rp.DashUntil or (os.clock() + 0.22)
	s.DashOrigin = origin
	s.DashDir = d
	s.DashKind = kind
	s.DashCast = nil
	s.Dashes = (s.Dashes or 0) + 1
	if id == "ruckus" then
		-- two rolling cans to the sides, behind the dash; one cast ledger = one can hit per target
		local C = K.DashCans
		local cast = WS.NewCast()
		local back = -d
		local spread = math.rad(C.SpreadDegrees)
		for i = 1, C.Count do
			local sign = (i % 2 == 0) and 1 or -1
			WS.KitCan(rp, origin, rotateY(back, sign * spread * math.ceil(i / 2)), cast, C)
		end
	elseif id == "coach_crunch" then
		local T = K.Tackle
		s.DashCast = WS.NewCast()
		s.DashHitsLeft = T.MaxTargets
		s.DashCoeff = s.WarmCharged and T.ChargedCoeff or T.Coeff
		s.DashCharged = s.WarmCharged
		s.DashKnock = nil
		s.DashStagger = T.Stagger
		s.DashRadius = T.HitRadius
		s.WarmCharged = false -- the tackle uses the charge, landed or not
		s.FastSince = nil
	elseif id == "crash_cassidy" then
		local B = K.BodyCheck
		s.DashCast = WS.NewCast()
		s.DashHitsLeft = B.MaxTargets
		s.DashCoeff = B.Coeff
		s.DashKnock = B.Knock
		s.DashStagger = nil
		s.DashRadius = B.HitRadius
	elseif id == "barry_plotter" then
		local t = now()
		if t >= s.SeedCd and WS.KitPlant(rp, origin) then
			s.SeedCd = t + K.DashSeed.Cooldown
		end
	elseif id == "rambozo" then
		WS.KitBalloon(rp, origin, d, K.BalloonGrenade)
	end
	s.PublishAt = 0
end

-- The dash's movement time ended (Step): Doug's trail, Swolverine's recovery, Knuckles's dodge.
local function onDashEnd(rp, s, t: number)
	local id = rp.CharacterId
	local WS = ctx.WeaponSystem
	if not living(rp) then
		return
	end
	local pos = rp.Root.Position
	if id == "doug_janitor" then
		local W = K.WetTrail
		local a = s.DashOrigin or pos
		local span = (pos - a) * FLAT
		local b
		if span.Magnitude >= 2 then
			b = a + span.Unit * math.min(span.Magnitude, W.Length)
		else
			b = a + (s.DashDir or Vector3.zAxis) * W.Length
		end
		s.Trail = { A = a, B = b, Until = t + W.Seconds, Next = 0 }
		for i = 0, 3 do
			local p = a:Lerp(b, i / 3)
			WS.KitFx("nv", { math.floor(p.X * 10 + 0.5) / 10, math.floor(p.Z * 10 + 0.5) / 10, W.Width, 0 })
		end
	elseif id == "swolverine" then
		s.RecoveryUntil = t + K.DashRecovery.Seconds
	elseif id == "knuckles_mcgee" then
		if #WS.KitQuery(pos, K.CloseDodge.Range) > 0 then
			WS.GloveCharge(rp, 1)
			s.Dodges = (s.Dodges or 0) + 1
		end
	end
	s.PublishAt = 0
end

-- (tests) ends the current dash now.
function ClassKits.EndDash(rp)
	local s = state(rp)
	if s.DashEnd then
		s.DashEnd = nil
		onDashEnd(rp, s, now())
	end
end

-- Coach / Crash: while the dash moves, enemies touched take the tackle once (cast ledger), at most
-- MaxTargets per dash.
local function stepContact(rp, s)
	if not s.DashCast or (s.DashHitsLeft or 0) <= 0 or not living(rp) then
		return
	end
	local n = ctx.WeaponSystem.KitBurst(rp, rp.Root.Position, s.DashRadius, s.DashCoeff, signatureOf(rp), {
		CastId = s.DashCast,
		Max = s.DashHitsLeft,
		Stagger = s.DashStagger,
		Knock = s.DashKnock,
		Dash = true, -- a dash hit (CloseKills goal source)
		Fx = false,
	})
	s.DashHitsLeft -= n
	s.DashTargets = (s.DashTargets or 0) + n
end

------------------------------------------------------------------------------------------
-- Per frame: speed, charges, dash windows, trails, heals, HUD attributes, cleanup
------------------------------------------------------------------------------------------

local ATTRS = { "ClassKit", "ClassCharge", "ClassReady", "ClassStored", "ClassChargeText" }

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

-- Horizontal speed measured from the root over SpeedWindow s (a teleport-sized jump reads 0).
local function measure(rp, s, t: number)
	local root = rp.Root
	if not root then
		return
	end
	local pos = root.Position
	if not s.SpeedPos or t < (s.SpeedT or 0) then
		s.SpeedPos, s.SpeedT = pos, t
		return
	end
	local dt = t - s.SpeedT
	if dt >= K.SpeedWindow then
		local v = ((pos - s.SpeedPos) * FLAT).Magnitude / dt
		s.Speed = if v > 120 then 0 else v
		s.SpeedPos, s.SpeedT = pos, t
	end
end

-- Seconds continuously above `threshold` studs/s (0 when below).
local function fastFor(rp, s, threshold: number, t: number): number
	if living(rp) and s.Speed > threshold then
		s.FastSince = s.FastSince or t
		return t - s.FastSince
	end
	s.FastSince = nil
	return 0
end

local function publish(rp, s, t: number)
	local id = rp.CharacterId
	local player = rp.Player
	local kit = ClassRoster.KitNames[id]
	if not kit or not player then
		return
	end
	local charge, ready, stored, text = 0, false, 0, ""
	if id == "ruckus" then
		local need = K.JunkCollector.RewardsPerCharge
		stored = s.Barrage
		ready = stored > 0
		charge = ready and 1 or s.Picks / need
		text = ready and "Ready" or string.format("%d/%d", s.Picks, need)
	elseif id == "toastmaster" then
		local heat = (t < s.TopUntil) and s.Top or 0
		charge = heat
		ready = t < s.FlashUntil
		text = ready and "Scorch!" or string.format("%d/%d", math.floor(heat * K.Overheat.Hits + 0.5), K.Overheat.Hits)
	elseif id == "captain_croak" then
		ready = s.Splash > 0 and t <= s.SplashUntil
		stored = ready and 1 or 0
		charge = ready and math.clamp((s.SplashUntil - t) / K.BigSplash.Expiry, 0, 1) or 0
		text = ready and "Ready" or "0/1"
	elseif id == "granny_boom" then
		local n = 0
		for e, untilT in pairs(s.Tangled) do
			if t < untilT and e.Alive then
				n += 1
			else
				s.Tangled[e] = nil
			end
		end
		stored = n
		ready = n > 0
		charge = math.min(1, n / 8)
		text = string.format("%d", n)
	elseif id == "coach_crunch" then
		ready = s.WarmCharged
		charge = ready and 1 or math.clamp((s.FastSince and (t - s.FastSince) or 0) / K.WarmUp.Seconds, 0, 1)
		stored = ready and 1 or 0
		text = ready and "Ready" or string.format("%d%%", math.floor(charge * 100 + 0.5))
	elseif id == "doug_janitor" then
		ready = s.Trail ~= nil and t < s.Trail.Until
		charge = ready and math.clamp((s.Trail.Until - t) / K.WetTrail.Seconds, 0, 1) or 0
		text = ready and "Wet" or "Clean"
	elseif id == "peter_parkour" then
		ready = s.Stride and t <= s.StrideUntil
		stored = ready and 1 or 0
		charge = ready and 1 or math.clamp((s.FastSince and (t - s.FastSince) or 0) / K.Stride.Seconds, 0, 1)
		text = ready and "Ready" or string.format("%d%%", math.floor(charge * 100 + 0.5))
	elseif id == "barry_plotter" then
		local n, cap = ctx.WeaponSystem.KitPlants(rp)
		stored = n
		ready = n > 0
		charge = cap > 0 and n / cap or 0
		text = string.format("%d/%d", n, cap)
	elseif id == "rambozo" then
		text = string.format("+%d%%", math.floor(K.Punchline.CritBonus * 100 + 0.5))
	elseif id == "swolverine" then
		local G = K.Gains
		stored = s.HealBank
		ready = t < s.RecoveryUntil
		charge = s.KillCount / G.KillsPerHeal
		text = string.format("%d/%d", s.KillCount, G.KillsPerHeal)
	elseif id == "crash_cassidy" then
		charge = K.Momentum.MaxBonus > 0 and s.Momentum / K.Momentum.MaxBonus or 0
		ready = charge >= 0.99
		text = string.format("+%d%%", math.floor(s.Momentum * 100 + 0.5))
	elseif id == "knuckles_mcgee" then
		local c, need = ctx.WeaponSystem.GloveCharge(rp, 0)
		c, need = c or 0, need or 5
		stored = c
		ready = c >= need
		charge = need > 0 and c / need or 0
		text = ready and "Ready" or string.format("%d/%d", c, need)
	end
	player:SetAttribute("ClassKit", kit)
	player:SetAttribute("ClassCharge", round2(math.clamp(charge, 0, 1)))
	player:SetAttribute("ClassReady", ready)
	player:SetAttribute("ClassStored", stored)
	player:SetAttribute("ClassChargeText", text)
end

local function stepPlayer(rp, s, t: number)
	local id = rp.CharacterId
	measure(rp, s, t)
	local clock = os.clock()
	-- the dash: contact hits while it moves, then its end
	if s.DashEnd then
		if clock < s.DashEnd + 0.05 then
			stepContact(rp, s)
		end
		if clock >= s.DashEnd then
			s.DashEnd = nil
			onDashEnd(rp, s, t)
			s.DashCast = nil
		end
	end
	if id == "toastmaster" then
		-- an intentional jump: the root rises fast (stairs, slopes and falls never do; a launch pad's
		-- arc is a leap, not a jump)
		local root = rp.Root
		local v = root and root.AssemblyLinearVelocity
		if v and v.Y > K.LandingBlast.JumpRiseSpeed and not rp.LeapUntil and living(rp) then
			if not s.JumpAt or t - s.JumpAt > 0.5 then
				s.JumpAt = t
			end
		end
	elseif id == "coach_crunch" then
		if not s.WarmCharged and fastFor(rp, s, K.WarmUp.Speed, t) >= K.WarmUp.Seconds then
			s.WarmCharged = true
			s.PublishAt = 0
		end
	elseif id == "peter_parkour" then
		if s.Stride and t > s.StrideUntil then
			s.Stride = false -- expired unused
			s.FastSince = nil
		end
		if not s.Stride and fastFor(rp, s, K.Stride.Speed, t) >= K.Stride.Seconds then
			s.Stride = true
			s.StrideUntil = t + K.Stride.Expiry
			s.PublishAt = 0
		end
	elseif id == "doug_janitor" then
		local tr = s.Trail
		if tr then
			if t >= tr.Until then
				s.Trail = nil
			elseif t >= tr.Next then
				local W = K.WetTrail
				tr.Next = t + W.Tick
				local mid = tr.A:Lerp(tr.B, 0.5)
				local seg = (tr.B - tr.A) * FLAT
				local len = seg.Magnitude
				local u = len > 1e-3 and seg / len or Vector3.zero
				for _, e in ipairs(ctx.WeaponSystem.KitQuery(mid, len / 2 + W.Width)) do
					local rel = (e.Pos - tr.A) * FLAT
					local along = math.clamp(rel:Dot(u), 0, len)
					local off = (rel - u * along).Magnitude
					if off <= W.Width + (e.Radius or 1) then
						ctx.WeaponSystem.ApplySlow(e, W.Slow, W.Tick + 0.15)
						s.Wetted = (s.Wetted or 0) + 1
					end
				end
			end
		end
	elseif id == "swolverine" then
		local G = K.Gains
		local kills = tonumber(rp.Kills) or 0
		if s.KillsSeen == nil or kills < s.KillsSeen then
			s.KillsSeen = kills
		end
		local delta = kills - s.KillsSeen
		if delta > 0 then
			s.KillsSeen = kills
			s.KillCount += delta
			while s.KillCount >= G.KillsPerHeal do
				s.KillCount -= G.KillsPerHeal
				s.HealBank = math.min(G.MaxBanked, s.HealBank + 1)
			end
			s.PublishAt = 0
		end
		if s.HealBank > 0 and t - s.HealAt >= G.MinGap and living(rp) and rp.Stats then
			s.HealBank -= 1
			s.HealAt = t
			s.Heals += 1
			ctx.RunManager.Heal(rp, rp.Stats.MaxHP * G.HealShare, true)
		end
		setKitBonus(rp, s, t < s.RecoveryUntil and K.DashRecovery.DamageBonus or 0)
	elseif id == "crash_cassidy" then
		local M = K.Momentum
		local u = living(rp) and math.clamp((s.Speed - M.MinSpeed) / math.max(1e-3, M.MaxSpeed - M.MinSpeed), 0, 1) or 0
		local bonus = math.floor(M.MaxBonus * u * 100 + 0.5) / 100 -- whole percents (fewer sheet writes)
		if bonus ~= s.Momentum then
			s.Momentum = bonus
			s.PublishAt = 0
		end
		setKitBonus(rp, s, bonus)
	end
	if t >= s.PublishAt or t < s.PublishAt - 5 then
		s.PublishAt = t + PUBLISH_EVERY
		publish(rp, s, t)
	end
end

-- Kit state lives as long as the run player is in a running run (a frozen world, e.g. a solo
-- choice, keeps it: nothing steps, nothing is lost); a run end or a departure clears it.
function ClassKits.Step(_dt: number)
	local seen: { [any]: boolean } = {}
	local RM = ctx.RunManager
	if RM.IsRunning() then
		local sim = RM.IsSimulating()
		local t = now()
		for _, rp in ipairs(RM.GetRunPlayers()) do
			if ClassRoster.KitNames[rp.CharacterId] and not rp.Returned then
				local s = state(rp)
				seen[rp] = true
				if sim then
					stepPlayer(rp, s, t)
				end
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
