-- class-kits-sim: boots the REAL server and runs a solo run as each of the twelve SwarmV2 classes
-- (stream C, continuation brief "Twelve approved classes"). Per class, with natural spawns held and
-- enemies placed by hand (frozen in place), it checks the roster numbers (HP x H0, walk speed, crit
-- base), the signature weapon's exact hits (bounce / ricochet target rules, per-leg caps, target caps,
-- pellets, plants, the Glove Combo charge), the rank 3 / 5 milestones, the class passive and its
-- charge counter, the movement hook (called through ClassKits.OnDash / OnLanded / OnLeapLanded, as
-- the Dash signals do), the secondary budget, no recursion, kills, and the evolution of the first
-- four. Prints PASS / FAIL lines.
--   lune run tools/preview/runtime/main.luau -- --scene class-kits-sim --studio --device pc
--     --set headless=on [--set character=<class id>]
local C = lib("common")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local SSS = game:GetService("ServerScriptService")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local advance = preview.advance

local RM = preview.server("RunManager")
local WS = preview.server("WeaponSystem")
local DS = preview.server("DataService")
local Spawner = preview.server("EnemySpawner")
local LevelUp = preview.server("LevelUpSystem")
local Stage = preview.server("StageManager")
local ItemSystem = preview.server("ItemSystem")
local K = preview.require(SSS.SwarmV2.Run.ClassKits)
local Dash = preview.require(SSS.SwarmV2.Run.Dash)
local CharacterData = require(RS.Shared.CharacterData)
local WeaponData = require(RS.Shared.WeaponData)
local Config = require(RS.Shared.Config)
local MeshCatalog = require(RS.Shared.MeshCatalog)
local RunConfig = require(RS.SwarmV2.Run.RunConfig)
local BuildRules = require(RS.SwarmV2.Run.BuildRules)
local ClassRoster = require(RS.SwarmV2.Run.ClassRoster)
local KC = RunConfig.Classes
local B = RunConfig.Builds.B
local H0 = Config.Player.BaseMaxHP

local fails = 0
local function check(name: string, ok: boolean, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", name, detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
end
local function near(a: number?, b: number, tol: number?): boolean
	return type(a) == "number" and math.abs(a - b) <= (tol or 0.05)
end
local function f2(n: any): string
	return type(n) == "number" and string.format("%.2f", n) or tostring(n)
end

local function pickLevels()
	for _ = 1, 20 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, me:GetAttribute("ChoiceOfferId"))
		advance(0.3)
	end
end
local function step(t: number)
	local left = t
	while left > 0 do
		local dt = math.min(left, 0.25)
		advance(dt, 30)
		left -= dt
		pickLevels()
	end
end
local function send(name, ...)
	preview.remote(name):FireServer(...)
	advance(0.2)
	pickLevels()
end

------------------------------------------------------------------------------------------
-- registry (before any run)
------------------------------------------------------------------------------------------
local HP_MULT = { toastmaster = 0.90, granny_boom = 1.10, doug_janitor = 1.10, swolverine = 1.15, crash_cassidy = 0.90, peter_parkour = 0.95 }
local PRICE = { ruckus = 0, toastmaster = 10000, captain_croak = 20000, granny_boom = 30000 }
for i, id in ipairs(KC.Order) do
	local def = CharacterData.Characters[id]
	local sig = WeaponData.Signatures[id]
	check("registered " .. id, def ~= nil and def.StartWeapon == sig and WeaponData.Weapons[sig] ~= nil and CharacterData.Order[i] == id,
		def and def.StartWeapon)
	if def then
		check(id .. ": mesh " .. tostring(def.MeshName) .. " in MeshCatalog", MeshCatalog.Models[def.MeshName] ~= nil)
		local mult = 1 + ((def.Bonus and def.Bonus.maxHpMult) or 0)
		check(id .. ": HP x" .. f2(HP_MULT[id] or 1) .. " H0", near(mult, HP_MULT[id] or 1, 1e-6), mult)
		if PRICE[id] then
			check(id .. ": gold price " .. PRICE[id] .. ", no goal-only lock", def.Cost == PRICE[id] and def.Unlock == nil and (id == "ruckus" or def.Goal ~= nil))
		else
			check(id .. ": goal unlock only (no gold price)", def.Unlock ~= nil and def.Goal ~= nil and type(def.Goal.Stat) == "string" and (def.Goal.Need or 0) > 0,
				def.Goal and (def.Goal.Stat .. " " .. tostring(def.Goal.Need)))
		end
		check(id .. ": ultimate + second skill + mastery signature", CharacterData.Ultimates[id] ~= nil and CharacterData.SecondSkills[id] ~= nil
			and require(RS.Shared.MetaUpgradeData).Signature[id] ~= nil)
	end
end
check("old heroes hidden from Order", table.find(CharacterData.Order, "Knight") == nil and CharacterData.Characters.Knight ~= nil)
check("default hero is ruckus", CharacterData.Default == "ruckus")
check("knuckles goal: a boss OR a revive", CharacterData.Characters.knuckles_mcgee.Goal.Any ~= nil and #CharacterData.Characters.knuckles_mcgee.Goal.Any == 2)

-- milestones of the twelve signatures (data the behaviours read)
local function spec(id: string, r: number)
	return WeaponData.RankSpec(id, r)
end
check("milestones: Scrap 2 bounces / +1 scrap", spec("ScrapToss", 3).Bounces == 2 and spec("ScrapToss", 5).ExtraShots == 1)
check("milestones: Toast 2 ricochets / final burst", spec("ToastVolley", 3).Bounces == 2 and spec("ToastVolley", 5).FinalBurst ~= nil)
check("milestones: Bubble radius 7 / second bubble", spec("BubbleBomb", 3).BurstRadius == 7 and spec("BubbleBomb", 5).SecondBubble ~= nil)
check("milestones: Yarn fuse 0.85 / radius 10", spec("YarnBomb", 3).Fuse == 0.85 and spec("YarnBomb", 5).BlastRadius == 10)
check("milestones: Dodgeball 2 bounces / second ball", spec("Dodgeball", 3).Bounces == 2 and spec("Dodgeball", 5).SecondBall ~= nil and spec("Dodgeball", 5).BounceRange == 10)
check("milestones: Mop 130 degrees / 8 targets", spec("MopSweep", 3).Arc == 130 and spec("MopSweep", 5).MaxTargets == 8)
check("milestones: Sneakers 3 out / 3 back", spec("ReturningSneakers", 3).OutTargets == 3 and spec("ReturningSneakers", 5).ReturnTargets == 3)
check("milestones: Seed plants 8 s / cap 4", spec("SeedSlinger", 3).PlantSeconds == 8 and spec("SeedSlinger", 5).PlantCap == 4)
check("milestones: Confetti 4 / 5 pellets", spec("ConfettiMinigun", 3).Amount == 4 and spec("ConfettiMinigun", 5).Amount == 5)
check("milestones: Claws 4 targets / third pulse", spec("ProteinClaws", 3).MaxTargets == 4 and spec("ProteinClaws", 5).ThirdPulse ~= nil)
check("milestones: Puck 2 / 3 bounces", spec("RicochetPuck", 3).Bounces == 2 and spec("RicochetPuck", 5).Bounces == 3)
check("milestones: Glove uppercut after 4 / 3", spec("GloveCombo", 3).ChargeAfter == 4 and spec("GloveCombo", 5).ChargeAfter == 3)
for _, id in ipairs({ "Dodgeball", "ReturningSneakers", "SeedSlinger", "ConfettiMinigun", "ProteinClaws", "RicochetPuck", "GloveCombo" }) do
	check(id .. ": its own behaviour (no placeholder)", WeaponData.BehaviorOf(id) ~= "RankShot" and WeaponData.BehaviorOf(id) ~= "RankSwing", WeaponData.BehaviorOf(id))
end
check("dash variants: croak leap 30 studs / ~0.45 s / 3 s", (function()
	local d = Dash.GetDef("captain_croak")
	local dur = 2 * math.sqrt(2 * (d.Apex or 0) / workspace.Gravity)
	return d.Kind == "Leap" and d.Horizontal == 30 and d.Cooldown == 3 and math.abs(dur - 0.45) < 0.02
end)())
check("dash variants: granny boost 80 / 0.25 / 3", (function()
	local d = Dash.GetDef("granny_boom")
	return d.Speed == 80 and d.Duration == 0.25 and d.Cooldown == 3
end)())
check("dash variants: crash cooldown 2.20, others default", Dash.GetDef("crash_cassidy").Cooldown == 2.2 and Dash.GetDef("coach_crunch").Cooldown == RunConfig.Dash.Default.Cooldown)

------------------------------------------------------------------------------------------
-- per class
------------------------------------------------------------------------------------------
local classes = table.clone(KC.Order)
if preview.args.character then
	classes = { preview.args.character }
end

-- natural spawns and waves off: every enemy in a check is placed by the check
if Stage.AllowSpawning then
	Stage.AllowSpawning = function()
		return false
	end
end
if Spawner.SetHold then
	Spawner.SetHold("ClassKitsSim", true)
end

local rp: any = nil
local function now(): number
	return RM.GetRunTime()
end
local function clearEnemies()
	for i = #Spawner.Active, 1, -1 do
		local e = Spawner.Active[i]
		if e and not e.Boss then
			Spawner.Despawn(e)
		end
	end
end
local ENEMY = "Slime"
-- An enemy at hero + offset (flat), `hp` HP, frozen in place (SpeedOverride 0; knockback still moves it).
local function spawn(offset: Vector3, hp: number?, opts: any?)
	local root = rp.Root.Position
	local e = Spawner.Spawn(ENEMY, Vector3.new(root.X + offset.X, root.Y, root.Z + offset.Z), { Force = true, Elite = opts and opts.Elite or nil })
	if e then
		e.MaxHP = hp or 2000
		e.HP = e.MaxHP
		e.SpeedOverride = 0
		e.Knock = Vector3.zero
		e.Shield = 0
		-- (a pooled record keeps these from its last life: EnemySpawner.Spawn does not reset them)
		e.StaggerUntil, e.StaggerImmuneUntil = nil, nil
	end
	return e
end
local function loss(e): number
	return e and (e.MaxHP - e.HP) or -1
end
local function weapon(id: string)
	return rp.Weapons[id]
end
local function setRank(id: string, r: number)
	local w = rp.Weapons[id]
	w.Level = r
	w.Rank = r
	w.Charge = 0
end
local function noCrit()
	rp.Stats.CritChance = 0
end
local function hold(id: string)
	for wid, w in pairs(rp.Weapons) do
		w.Timer = 999
	end
end
local function fireOnce(id: string)
	local w = rp.Weapons[id]
	w.Timer = 0
	advance(1 / 30, 30)
	w.Timer = 999
end
-- the hit value of `coeff` at rank r for this hero (armor 0 enemies)
local function hit(coeff: number, r: number, extra: number?): number
	return BuildRules.HitDamage(coeff, r, (rp.Stats.DamageBonus or 0) + (extra or 0))
end
local function count(kind: string): number
	return WS.DebugCounts()[kind] or 0
end
local function fakeDash(dir: Vector3)
	rp.DashUntil = os.clock() + 0.22
	rp.DashKind = "Dash"
	K.OnDash(rp, "Dash", dir)
end
local function publishNow()
	K.State(rp).PublishAt = 0
	advance(1 / 30, 30)
end
-- walks the hero in a circle at `speed` studs/s for `seconds` (the server measures the speed)
local function circleRun(speed: number, seconds: number, radius: number?)
	local r = radius or 12
	local root = rp.Root
	local c = root.Position - Vector3.new(r, 0, 0)
	local w = speed / r
	local t = 0
	rp.Stats.Speed = math.max(rp.Stats.Speed, speed + 6) -- (the server speed check)
	while t < seconds do
		local dt = 1 / 30
		advance(dt, 30)
		t += dt
		local a = w * t
		root.CFrame = CFrame.new(c + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
	end
end
local function kills(): number
	return tonumber(rp.Kills) or 0
end

local function killTest(cls: string, sig: string)
	clearEnemies()
	for wid, w in pairs(rp.Weapons) do
		w.Timer = wid == sig and 0 or 999
	end
	local k0 = kills()
	local dmg0 = rp.DamageDealt
	for _ = 1, 6 do
		if kills() > k0 then
			break
		end
		for i = 1, 3 do
			spawn(Vector3.new(4 + i, 0, (i - 2) * 1.5), 1)
		end
		step(1.5)
	end
	check(cls .. ": the signature hits and kills", rp.DamageDealt > dmg0 and kills() > k0, string.format("dmg %.1f kills %d", rp.DamageDealt - dmg0, kills() - k0))
end

local TESTS: { [string]: (string) -> () } = {}

TESTS.ruckus = function(cls)
	local sig = "ScrapToss"
	-- (a chest reward reaches OnLootPickup from LootSystem's chest choice, stream E2)
	local s = K.State(rp)
	LevelUp.CancelAll(rp)
	step(0.3)
	-- bounce: a different visible target within 10 studs; a target 20 studs away is never chosen
	clearEnemies()
	hold(sig)
	setRank(sig, 1)
	noCrit()
	local a = spawn(Vector3.new(8, 0, 0))
	local b = spawn(Vector3.new(8, 0, 6))
	local far = spawn(Vector3.new(0, 0, -20))
	fireOnce(sig)
	step(0.75)
	check("ruckus: Scrap Shot 0.90 B on the target", near(loss(a), hit(0.90, 1)), f2(loss(a)))
	check("ruckus: bounce 0.45 B to another target within 10", near(loss(b), hit(0.45, 1)), f2(loss(b)))
	check("ruckus: no bounce to a target 20 studs away", loss(far) == 0, f2(loss(far)))
	-- the secondary budget: no tokens, no bounce
	clearEnemies()
	a = spawn(Vector3.new(8, 0, 0))
	b = spawn(Vector3.new(8, 0, 6))
	rp.EmitTokens, rp.EmitAt = -100, now()
	fireOnce(sig)
	step(0.75)
	check("ruckus: an empty secondary budget stops the bounce", loss(a) > 0 and loss(b) == 0, f2(loss(b)))
	rp.EmitTokens = nil
	-- Junk Collector: 5 rewards, max 1 stored, the barrage is 3 scraps of 0.60 B
	for _ = 1, 5 do
		K.OnLootPickup(rp, "test")
	end
	K.OnLootPickup(rp, "test")
	publishNow()
	check("ruckus: 5 rewards store a barrage (Ready), more do not count", s.Barrage == 1 and s.Picks == 0 and me:GetAttribute("ClassChargeText") == "Ready", me:GetAttribute("ClassChargeText"))
	clearEnemies()
	local t1, t2, t3 = spawn(Vector3.new(8, 0, 0)), spawn(Vector3.new(0, 0, 9)), spawn(Vector3.new(-9, 0, 0))
	local before = count("Straight")
	fireOnce(sig)
	local shots = count("Straight") - before
	step(0.75)
	publishNow()
	check("ruckus: the barrage fires 3 scraps", shots == 3, shots)
	check("ruckus: each barrage scrap 0.60 B", near(loss(t1), hit(0.60, 1)) and near(loss(t2), hit(0.60, 1)) and near(loss(t3), hit(0.60, 1)),
		f2(loss(t1)) .. " " .. f2(loss(t2)) .. " " .. f2(loss(t3)))
	check("ruckus: charge consumed, counter 0/5", s.Barrage == 0 and me:GetAttribute("ClassChargeText") == "0/5", me:GetAttribute("ClassChargeText"))
	-- dash cans: 2 cans, 0.40 B r5 after 0.90 s, one can hit per target per dash
	clearEnemies()
	local e = spawn(Vector3.new(0, 0, 4))
	local c0 = count("Can")
	fakeDash(Vector3.new(0, 0, -1))
	local cans = count("Can") - c0
	step(1.3)
	check("ruckus: dash drops 2 cans", cans == 2, cans)
	check("ruckus: both cans in reach, one hit (0.40 B)", near(loss(e), hit(0.40, 1)), f2(loss(e)))
	-- rank 5 milestone: one more 0.40 B scrap at another target
	clearEnemies()
	setRank(sig, 5)
	noCrit()
	a = spawn(Vector3.new(8, 0, 0))
	b = spawn(Vector3.new(-8, 0, 0))
	before = count("Straight")
	fireOnce(sig)
	shots = count("Straight") - before
	step(0.75)
	check("ruckus: rank 5 fires the extra scrap (secondary)", shots == 2 and near(loss(b), hit(0.40, 5)), string.format("%d shots, %s", shots, f2(loss(b))))
	setRank(sig, 1)
	-- a cross-class signature works for any holder (Glove Combo charge), the kit does not come with it
	local data = DS.GetData(me)
	data.OwnedCharacters.knuckles_mcgee = true
	rp.OwnedClasses = nil -- (the run's ownership snapshot, as if it was owned at the start)
	local added = LevelUp.AddWeapon(rp, "GloveCombo")
	if added then
		clearEnemies()
		hold(sig)
		local tgt = spawn(Vector3.new(3, 0, 0))
		local w = rp.Weapons.GloveCombo
		for _ = 1, 6 do
			w.Timer = 0
			advance(1 / 30, 30)
			w.Timer = 999
			step(0.25)
			tgt.Knock = Vector3.zero
		end
		check("ruckus holding Glove Combo: 5 punches charge it, the 6th is an uppercut", (w.Uppercuts or 0) == 1, w.Uppercuts)
		check("ruckus holding Glove Combo: no Heavy Hands", rp.KitKnockMult == nil)
		rp.Weapons.GloveCombo = nil
		table.remove(rp.WeaponOrder, table.find(rp.WeaponOrder, "GloveCombo") or #rp.WeaponOrder)
	else
		check("ruckus: Glove Combo added for an owner of knuckles_mcgee", false, "AddWeapon refused (entitlement snapshot)")
	end
end

TESTS.toastmaster = function(cls)
	local sig = "ToastVolley"
	setRank(sig, 1)
	clearEnemies()
	hold(sig)
	noCrit()
	local a = spawn(Vector3.new(8, 0, 0))
	local b = spawn(Vector3.new(8, 0, 6))
	fireOnce(sig)
	step(0.75)
	check("toastmaster: Toast Toss 0.65 B", near(loss(a), hit(0.65, 1)), f2(loss(a)))
	check("toastmaster: ricochet 0.35 B to another target within 10", near(loss(b), hit(0.35, 1)), f2(loss(b)))
	-- Overheat: ricochets never count; 3 direct hits within 5 s scorch and reset the counter
	clearEnemies()
	local s = K.State(rp)
	local e = spawn(Vector3.new(12, 0, 0))
	local w = weapon(sig)
	for _ = 1, 3 do
		K.OnToastHit(rp, e, 6.5, w, now(), false)
	end
	check("toastmaster: ricochet hits never heat", s.Scorches == 0)
	for _ = 1, 3 do
		K.OnToastHit(rp, e, 6.5, w, now(), true)
	end
	publishNow()
	check("toastmaster: 3 direct hits scorch", s.Scorches == 1 and (WS.DebugCounts().Burning or 0) >= 1 and me:GetAttribute("ClassReady") == true)
	K.OnToastHit(rp, e, 6.5, w, now(), true)
	K.OnToastHit(rp, e, 6.5, w, now(), true)
	check("toastmaster: the heat counter reset", s.Scorches == 1)
	local hp0 = e.HP
	step(1.6)
	check("toastmaster: scorch ticks 0.12 B/s (status, no crit)", near(hp0 - e.HP, RunConfig.Combat.ScorchDpsB * B * 1.5, 0.61), f2(hp0 - e.HP))
	-- landing blast: only after an intentional jump, airtime >= 0.35, r6 0.35 B, 2 s cooldown
	clearEnemies()
	local inn = spawn(Vector3.new(3, 0, 0))
	local out = spawn(Vector3.new(9, 0, 0))
	K.OnLanded(rp, 0.8)
	check("toastmaster: a landing without a jump (stairs, a fall) never blasts", s.Blasts == 0)
	K.NoteJump(rp)
	K.OnLanded(rp, 0.2)
	check("toastmaster: a short hop never blasts", s.Blasts == 0)
	K.NoteJump(rp)
	K.OnLanded(rp, 0.8)
	check("toastmaster: a jump landing blasts r6 0.35 B", s.Blasts == 1 and near(loss(inn), hit(0.35, 1)) and loss(out) == 0, f2(loss(inn)) .. " / " .. f2(loss(out)))
	K.NoteJump(rp)
	K.OnLanded(rp, 0.8)
	check("toastmaster: blast cooldown 2 s", s.Blasts == 1)
	step(2.1)
	K.NoteJump(rp)
	K.OnLanded(rp, 0.8)
	check("toastmaster: blast again after the cooldown", s.Blasts == 2)
	-- spring jump apex 12 (client)
	local ok, JC = pcall(preview.client, "JumpController")
	if ok and JC and JC.JumpPower then
		check("toastmaster: spring jump apex 12", near(JC.JumpPower(), math.sqrt(2 * workspace.Gravity * 12), 0.1), f2(JC.JumpPower()))
	end
end

TESTS.captain_croak = function(cls)
	local sig = "BubbleBomb"
	setRank(sig, 1)
	local s = K.State(rp)
	clearEnemies()
	hold(sig)
	noCrit()
	local e1 = spawn(Vector3.new(8, 0, 0))
	fireOnce(sig)
	step(1.2)
	local plain = loss(e1)
	check("captain_croak: bubble impact 0.20 B + burst 0.90 B", near(plain, hit(0.20, 1) + hit(0.90, 1), 0.1), f2(plain))
	clearEnemies()
	K.OnLeapLanded(rp)
	check("captain_croak: a landing with no enemy within 10 stores nothing", s.Splash == 0)
	local e2 = spawn(Vector3.new(7, 0, 0))
	K.OnLeapLanded(rp)
	publishNow()
	check("captain_croak: a landing near an enemy stores Big Splash", s.Splash == 1 and me:GetAttribute("ClassChargeText") == "Ready")
	step(6.4)
	check("captain_croak: Big Splash expires after 6 s", K.TakeSplash(rp) == nil)
	K.OnLeapLanded(rp)
	e2.HP = e2.MaxHP
	noCrit()
	fireOnce(sig)
	step(1.2)
	check("captain_croak: the empowered bubble's burst +30%", near(loss(e2), hit(0.20, 1) + hit(0.90, 1) * 1.3, 0.1) and s.Splash == 0, f2(loss(e2)))
end

TESTS.granny_boom = function(cls)
	local sig = "YarnBomb"
	setRank(sig, 1)
	check("granny_boom: walks at 20", near(rp.Stats.Speed, 20, 0.01), f2(rp.Stats.Speed))
	clearEnemies()
	hold(sig)
	noCrit()
	local list = {}
	table.insert(list, spawn(Vector3.new(14, 0, 0)))
	for i = 1, 9 do
		local a = i * math.pi * 2 / 9
		table.insert(list, spawn(Vector3.new(14 + math.cos(a) * 2.6, 0, math.sin(a) * 2.6)))
	end
	fireOnce(sig)
	step(1.4)
	local hitN, tangled = 0, 0
	for _, e in ipairs(list) do
		if loss(e) > 0 then
			hitN += 1
			if e.SlowUntil and e.SlowUntil > now() and near(e.SlowMult, 0.65, 1e-3) then
				tangled += 1
			end
		end
	end
	check("granny_boom: Yarn Bomb hits at most 8", hitN == 8, hitN)
	check("granny_boom: Tangled Up slows what the yarn hit 35%", tangled == hitN, tangled)
	-- terrain blocks the blast: a target the blast cannot see takes nothing
	clearEnemies()
	local tgt = spawn(Vector3.new(12, 0, 0))
	local hidden = spawn(Vector3.new(12, 0, 4))
	local real = WS.HasLineOfSight
	WS.HasLineOfSight = function(a, b)
		if hidden and ((b - hidden.Pos) * Vector3.new(1, 0, 1)).Magnitude < 0.5 then
			return false
		end
		return real(a, b)
	end
	fireOnce(sig)
	step(1.4)
	WS.HasLineOfSight = real
	check("granny_boom: terrain blocks the yarn blast", loss(tgt) > 0 and loss(hidden) == 0, f2(loss(hidden)))
	-- refresh only, bosses capped at 10 %
	clearEnemies()
	local e = spawn(Vector3.new(6, 0, 0))
	K.OnYarnHit(rp, e, now())
	K.OnYarnHit(rp, e, now())
	check("granny_boom: tangle refreshes, never extends", e.SlowUntil - now() <= 0.76, f2(e.SlowUntil - now()))
	e.SlowUntil, e.SlowMult = nil, nil
	e.Boss = true
	K.OnYarnHit(rp, e, now())
	e.Boss = nil
	check("granny_boom: a boss is slowed at most 10%", (e.SlowMult or 1) >= 0.9 - 1e-6, f2(e.SlowMult))
end

TESTS.coach_crunch = function(cls)
	local sig = "Dodgeball"
	local s = K.State(rp)
	-- rank 3 (two bounces): A -> B, then nothing new within 10 (A was already hit)
	setRank(sig, 3)
	clearEnemies()
	hold(sig)
	noCrit()
	local a = spawn(Vector3.new(8, 0, 0))
	local b = spawn(Vector3.new(8, 0, 6))
	local far = spawn(Vector3.new(8, 0, -20))
	fireOnce(sig)
	step(0.8)
	check("coach_crunch: Dodgeball 0.85 B", near(loss(a), hit(0.85, 3)), f2(loss(a)))
	check("coach_crunch: bounce 0.40 B to a different target within 10", near(loss(b), hit(0.40, 3)), f2(loss(b)))
	check("coach_crunch: a second bounce never returns to an already-hit target", near(loss(a), hit(0.85, 3)) and loss(far) == 0)
	-- rank 5: a second ball at half damage (secondary)
	setRank(sig, 5)
	clearEnemies()
	noCrit()
	a = spawn(Vector3.new(8, 0, 0))
	local em0 = rp.Emitted or 0
	fireOnce(sig)
	step(0.9)
	check("coach_crunch: rank 5 second ball at half damage", near(loss(a), hit(0.85, 5) * 1.5) and (rp.Emitted or 0) > em0, f2(loss(a)))
	setRank(sig, 1)
	-- Warm-Up: 2 s above 18 studs/s charges the tackle
	clearEnemies()
	circleRun(22, 2.4)
	publishNow()
	check("coach_crunch: Warm-Up charges after 2 s running", s.WarmCharged == true and me:GetAttribute("ClassChargeText") == "Ready", me:GetAttribute("ClassChargeText"))
	local ring = {}
	for i = 1, 6 do
		local ang = i * math.pi / 3
		table.insert(ring, spawn(Vector3.new(math.cos(ang) * 1.6, 0, math.sin(ang) * 1.6)))
	end
	local t = now()
	fakeDash(Vector3.new(1, 0, 0))
	step(0.3)
	local hits, staggered, right = 0, 0, 0
	for _, e in ipairs(ring) do
		if loss(e) > 0 then
			hits += 1
			if near(loss(e), hit(0.60, 1)) then
				right += 1
			end
			local st = e.StaggerUntil
			if st and st >= t + 0.25 - 0.01 and st <= t + 0.25 + 0.1 and e.StaggerImmuneUntil then
				staggered += 1
			end
		end
	end
	check("coach_crunch: charged tackle hits 4 enemies once for 0.60 B", hits == 4 and right == 4 and s.WarmCharged == false, string.format("%d hit, %d right", hits, right))
	check("coach_crunch: tackle staggers 0.25 s", staggered == 4, staggered)
	clearEnemies()
	local plain = spawn(Vector3.new(1.5, 0, 0))
	local elite = spawn(Vector3.new(-1.5, 0, 0), nil, { Elite = true })
	t = now()
	fakeDash(Vector3.new(1, 0, 0))
	step(0.3)
	check("coach_crunch: uncharged tackle 0.30 B", near(loss(plain), hit(0.30, 1)), f2(loss(plain)))
	local est = elite and elite.StaggerUntil
	check("coach_crunch: an elite staggers at most 0.15 s", elite ~= nil and loss(elite) > 0 and est ~= nil and est >= t + 0.14 and est <= t + 0.15 + 0.1,
		elite and f2((est or 0) - t))
end

TESTS.doug_janitor = function(cls)
	local sig = "MopSweep"
	setRank(sig, 1)
	check("doug_janitor: Clean Route +4 studs pickup", near(rp.Stats.PickupRadius, Config.Player.BasePickupRadius + 4, 0.01), f2(rp.Stats.PickupRadius))
	clearEnemies()
	hold(sig)
	noCrit()
	local list = { spawn(Vector3.new(3.5, 0, 0)) }
	for i = 1, 7 do
		local ang = math.rad(-36 + (i - 1) * 12)
		table.insert(list, spawn(Vector3.new(math.cos(ang) * 6.5, 0, math.sin(ang) * 6.5)))
	end
	fireOnce(sig)
	step(0.4)
	local hitN, slowed = 0, 0
	for _, e in ipairs(list) do
		if loss(e) > 0 then
			hitN += 1
			if near(e.SlowMult, 0.8, 1e-3) and e.SlowUntil > now() then
				slowed += 1
			end
		end
	end
	check("doug_janitor: Mop Sweep hits at most 6", hitN == 6, hitN)
	check("doug_janitor: Mop Sweep slows 20%", slowed == hitN, slowed)
	-- wet trail: 16 studs along the dash for 2 s, 25 % slow, no damage
	clearEnemies()
	local on = spawn(Vector3.new(8, 0, 1))
	local off = spawn(Vector3.new(8, 0, 9))
	fakeDash(Vector3.new(1, 0, 0))
	K.EndDash(rp)
	step(0.4)
	check("doug_janitor: wet trail slows 25% on the trail", on.SlowUntil ~= nil and on.SlowUntil > now() and near(on.SlowMult, 0.75, 1e-3), f2(on.SlowMult))
	check("doug_janitor: nothing off the trail, no damage", (off.SlowUntil == nil or off.SlowUntil < now()) and loss(on) == 0)
	step(2.2)
	check("doug_janitor: the trail dries after 2 s", K.State(rp).Trail == nil)
end

TESTS.peter_parkour = function(cls)
	local sig = "ReturningSneakers"
	local s = K.State(rp)
	setRank(sig, 1)
	clearEnemies()
	hold(sig)
	noCrit()
	local line = {}
	for i, d in ipairs({ 5, 8, 11, 14 }) do
		line[i] = spawn(Vector3.new(d, 0, 0))
	end
	fireOnce(sig)
	step(2.2)
	local out, back = hit(0.70, 1), hit(0.35, 1)
	check("peter_parkour: out leg hits the first 2 (0.70 B)", near(loss(line[1]), out) and near(loss(line[2]), out), f2(loss(line[1])) .. " " .. f2(loss(line[2])))
	check("peter_parkour: back leg hits 2 (0.35 B), one hit per target per leg", near(loss(line[3]), back) and near(loss(line[4]), back),
		f2(loss(line[3])) .. " " .. f2(loss(line[4])))
	-- terrain ends the blocked leg: a cliff 10 studs out turns the shoe back (the enemy behind it is
	-- never hit); a blocked way back ends the shoe (no return hits)
	local Rk = WS._Rank
	local realBlocked = Rk.terrainBlocked
	local origin = rp.Root.Position
	clearEnemies()
	local nearE, behind = spawn(Vector3.new(5, 0, 0)), spawn(Vector3.new(15, 0, 0))
	Rk.terrainBlocked = function(p)
		if p.Kind == "Shoe" and p.X and p.X.Leg == "Out" and ((p.Pos - origin) * Vector3.new(1, 0, 1)).Magnitude > 10 then
			return true
		end
		return realBlocked(p)
	end
	noCrit()
	fireOnce(sig)
	step(2.2)
	check("peter_parkour: a cliff ends the way out (it turns back)", loss(behind) == 0 and near(loss(nearE), hit(0.70, 1) + hit(0.35, 1)), f2(loss(nearE)) .. " / " .. f2(loss(behind)))
	clearEnemies()
	nearE = spawn(Vector3.new(5, 0, 0))
	Rk.terrainBlocked = function(p)
		if p.Kind == "Shoe" and p.X and p.X.Leg == "Back" then
			return true
		end
		return realBlocked(p)
	end
	fireOnce(sig)
	step(2.2)
	Rk.terrainBlocked = realBlocked
	check("peter_parkour: a blocked way back ends the shoe (no return hit)", near(loss(nearE), hit(0.70, 1)), f2(loss(nearE)))
	-- Stride: 2 s above 20 studs/s; the next throw +30 %; the charge is spent
	clearEnemies()
	circleRun(22, 2.4)
	publishNow()
	check("peter_parkour: Stride charges after 2 s running", s.Stride == true and me:GetAttribute("ClassChargeText") == "Ready", me:GetAttribute("ClassChargeText"))
	local e = spawn(Vector3.new(6, 0, 0))
	noCrit()
	fireOnce(sig)
	step(2.2)
	check("peter_parkour: the charged throw deals +30% (out + back)", near(loss(e), (hit(0.70, 1) + hit(0.35, 1)) * 1.3, 0.1) and s.Stride == false, f2(loss(e)))
	clearEnemies()
	circleRun(22, 2.4)
	step(6.3)
	check("peter_parkour: an unused Stride expires after 6 s", s.Stride == false)
	local ok, JC = pcall(preview.client, "JumpController")
	if ok and JC and JC.JumpPower then
		check("peter_parkour: charged jump apex 11", near(JC.JumpPower(), math.sqrt(2 * workspace.Gravity * 11), 0.1), f2(JC.JumpPower()))
	end
end

TESTS.barry_plotter = function(cls)
	local sig = "SeedSlinger"
	setRank(sig, 1)
	clearEnemies()
	hold(sig)
	noCrit()
	local tgt = spawn(Vector3.new(10, 0, 0))
	fireOnce(sig)
	step(0.5)
	local plants = select(1, WS.KitPlants(rp))
	check("barry_plotter: the seed hits 0.25 B and grows a plant", near(loss(tgt), hit(0.25, 1)) and plants == 1, string.format("%s, %d plants", f2(loss(tgt)), plants))
	-- plant shots: once per second at the nearest visible enemy, +15 % while Barry is within 12
	local l0 = loss(tgt)
	local maxPlants = plants
	for _ = 1, 3 do
		step(1)
		maxPlants = math.max(maxPlants, (WS.KitPlants(rp)))
	end
	local near3 = loss(tgt) - l0
	check("barry_plotter: plant fires 0.25 B per second, +15% with Barry near (Garden Company)", near(near3, 3 * hit(0.25, 1, 0.15), 0.05) or near(near3, 2 * hit(0.25, 1, 0.15), 0.05), f2(near3))
	local range = KC.GardenCompany.Range
	KC.GardenCompany.Range = 0 -- (Barry out of reach of the plant)
	l0 = loss(tgt)
	step(2)
	local far2 = loss(tgt) - l0
	KC.GardenCompany.Range = range
	check("barry_plotter: without Barry near the plant shot is 0.25 B", near(far2, 2 * hit(0.25, 1), 0.05) or near(far2, hit(0.25, 1), 0.05), f2(far2))
	step(1.5)
	check("barry_plotter: no recursion (plants never plant)", maxPlants == 1, maxPlants)
	check("barry_plotter: the plant is gone after 6 s", (WS.KitPlants(rp)) == 0)
	-- the cap: 3 plants, the oldest replaced; rank 5 cap 4
	local base = rp.Root.Position
	for i = 1, 5 do
		WS.KitPlant(rp, base + Vector3.new(-3 * i, 0, 4))
		advance(0.05, 30)
	end
	local n, cap = WS.KitPlants(rp)
	check("barry_plotter: plant cap 3 (oldest replaced)", n == 3 and cap == 3, n)
	setRank(sig, 5)
	n, cap = WS.KitPlants(rp)
	check("barry_plotter: rank 5 plant cap 4", cap == 4, cap)
	setRank(sig, 1)
	step(6.5)
	-- dash seed: one extra plant at the origin, 6 s cooldown, the shared cap
	fakeDash(Vector3.new(1, 0, 0))
	advance(0.1, 30)
	local d1 = (WS.KitPlants(rp))
	fakeDash(Vector3.new(1, 0, 0))
	advance(0.1, 30)
	local d2 = (WS.KitPlants(rp))
	check("barry_plotter: dash plants a seed, 6 s cooldown", d1 == 1 and d2 == 1, d1 .. " " .. d2)
end

TESTS.rambozo = function(cls)
	local sig = "ConfettiMinigun"
	setRank(sig, 1)
	-- Punchline: +10 crit points against enemies above 70 % HP (the server roll)
	clearEnemies()
	hold(sig)
	local e = spawn(Vector3.new(6, 0, 0))
	local seen = nil
	local realMod = ItemSystem.ModifyHit
	ItemSystem.ModifyHit = function(who, amount, en)
		if who == rp then
			seen = who.Stats.CritChance
		end
		return realMod(who, amount, en)
	end
	rp.Stats.CritChance = 0.05
	WS.Damage(rp, e, 0.01, sig, 1, {})
	local high = seen
	e.HP = e.MaxHP * 0.5
	WS.Damage(rp, e, 0.01, sig, 1, {})
	local low = seen
	ItemSystem.ModifyHit = realMod
	check("rambozo: Punchline +10% crit vs enemies above 70% HP", near(high, 0.15, 1e-6) and near(low, 0.05, 1e-6) and near(rp.Stats.CritChance, 0.05, 1e-6), f2(high) .. " / " .. f2(low))
	-- confetti: 3 pellets can all hit one target up close; far away the outer ones miss
	local punch = rp.KitCritHigh
	rp.KitCritHigh = nil
	clearEnemies()
	noCrit()
	e = spawn(Vector3.new(6, 0, 0))
	fireOnce(sig)
	step(0.6)
	check("rambozo: all 3 pellets can hit one target up close", near(loss(e), 3 * hit(0.20, 1)), f2(loss(e)))
	clearEnemies()
	e = spawn(Vector3.new(27, 0, 0))
	local before = count("Straight")
	fireOnce(sig)
	local pellets = count("Straight") - before
	step(0.8)
	check("rambozo: a burst is 3 pellets", pellets == 3, pellets)
	check("rambozo: spread lowers distant output", loss(e) > 0 and loss(e) < 3 * hit(0.20, 1) - 0.01, f2(loss(e)))
	setRank(sig, 3)
	before = count("Straight")
	fireOnce(sig)
	local p3 = count("Straight") - before
	step(0.8)
	setRank(sig, 5)
	before = count("Straight")
	fireOnce(sig)
	local p5 = count("Straight") - before
	step(0.8)
	check("rambozo: rank 3 = 4 pellets, rank 5 = 5", p3 == 4 and p5 == 5, p3 .. " " .. p5)
	setRank(sig, 1)
	rp.KitCritHigh = punch
	-- balloon grenade: 0.40 B r6 after 0.80 s, then 2 mini-pops of 0.15 B, at most one per target
	clearEnemies()
	e = spawn(Vector3.new(0.5, 0, 0))
	local b0 = count("Balloon")
	rp.MiniPops = 0
	fakeDash(Vector3.new(1, 0, 0))
	local balloons = count("Balloon") - b0
	step(1.4)
	check("rambozo: dash drops one balloon grenade", balloons == 1)
	check("rambozo: blast 0.40 B + one mini-pop 0.15 B (both pops in reach)", near(loss(e), hit(0.40, 1) + hit(0.15, 1)) and rp.MiniPops == 2, f2(loss(e)) .. " pops " .. tostring(rp.MiniPops))
	check("rambozo: mini-pops never explode again", count("Balloon") == 0)
	clearEnemies()
	e = spawn(Vector3.new(0.5, 0, 0))
	rp.MiniPops = 0
	fakeDash(Vector3.new(1, 0, 0))
	advance(0.5, 30)
	rp.EmitTokens, rp.EmitAt = -100, now()
	step(1.0)
	rp.EmitTokens = nil
	check("rambozo: an empty secondary budget stops the mini-pops", near(loss(e), hit(0.40, 1)) and rp.MiniPops == 0, f2(loss(e)))
end

TESTS.swolverine = function(cls)
	local sig = "ProteinClaws"
	local s = K.State(rp)
	check("swolverine: base crit chance 0", rp.Stats.CritChance == 0, rp.Stats.CritChance)
	setRank(sig, 1)
	clearEnemies()
	hold(sig)
	local front = {}
	for i, d in ipairs({ { 4, 0 }, { 6, 1 }, { 8, -1 }, { 10, 0 }, { 7, 2.5 } }) do
		front[i] = spawn(Vector3.new(d[1], 0, d[2]))
	end
	local function hitCount(): number
		local n = 0
		for _, e in ipairs(front) do
			if loss(e) > 0 then
				n += 1
			end
		end
		return n
	end
	fireOnce(sig)
	step(0.3)
	check("swolverine: Protein Claws hits at most 3 (0.65 B)", hitCount() == 3 and near(loss(front[1]), hit(0.65, 1)), hitCount())
	for _, e in ipairs(front) do
		e.HP = e.MaxHP
	end
	setRank(sig, 3)
	fireOnce(sig)
	step(0.3)
	check("swolverine: rank 3 hits 4", hitCount() == 4, hitCount())
	setRank(sig, 5)
	local w = weapon(sig)
	w.Attacks, w.Pulses = 0, 0
	for _ = 1, 3 do
		fireOnce(sig)
		step(0.3)
	end
	check("swolverine: rank 5 every 3rd swipe adds a pulse", w.Pulses == 1, w.Pulses)
	setRank(sig, 1)
	-- Gains: 1 % max HP per 10 credited kills, at most one heal per second
	local maxHP = rp.Stats.MaxHP
	rp.HP = 50
	rp.Kills = (rp.Kills or 0) + 25
	advance(0.1, 30)
	local h1 = rp.HP
	advance(0.5, 30)
	local h2 = rp.HP
	advance(0.6, 30)
	local h3 = rp.HP
	advance(1.5, 30)
	check("swolverine: Gains heals 1% per 10 kills, one heal per second", near(h1, 50 + maxHP * 0.01, 0.01) and near(h2, h1, 0.01) and near(h3, 50 + maxHP * 0.02, 0.01) and near(rp.HP, h3, 0.01),
		string.format("%s %s %s %s", f2(h1), f2(h2), f2(h3), f2(rp.HP)))
	publishNow()
	check("swolverine: Gains counter 5/10", me:GetAttribute("ClassChargeText") == "5/10", me:GetAttribute("ClassChargeText"))
	-- dash recovery: +15 % damage for 2 s, refreshed, never stacked
	local db0 = rp.Stats.DamageBonus or 0
	fakeDash(Vector3.new(1, 0, 0))
	K.EndDash(rp)
	advance(0.1, 30)
	local db1 = rp.Stats.DamageBonus
	fakeDash(Vector3.new(1, 0, 0))
	K.EndDash(rp)
	advance(0.1, 30)
	local db2 = rp.Stats.DamageBonus
	step(2.3)
	check("swolverine: dash recovery +15% for 2 s, no stacking", near(db1, db0 + 0.15, 1e-3) and near(db2, db0 + 0.15, 1e-3) and near(rp.Stats.DamageBonus, db0, 1e-3),
		string.format("%s %s %s", f2(db1), f2(db2), f2(rp.Stats.DamageBonus)))
end

TESTS.crash_cassidy = function(cls)
	local sig = "RicochetPuck"
	setRank(sig, 5)
	clearEnemies()
	hold(sig)
	noCrit()
	local chain = {}
	for i = 0, 4 do
		chain[i + 1] = spawn(Vector3.new(6, 0, i * 7))
	end
	fireOnce(sig)
	step(1.2)
	local hitN = 0
	for _, e in ipairs(chain) do
		if loss(e) > 0 then
			hitN += 1
		end
	end
	check("crash_cassidy: rank 5 puck bounces 3 times (4 targets), 0.70 B then 0.35 B", hitN == 4 and near(loss(chain[1]), hit(0.70, 5)) and near(loss(chain[2]), hit(0.35, 5)),
		string.format("%d hit %s %s", hitN, f2(loss(chain[1])), f2(loss(chain[2]))))
	setRank(sig, 1)
	-- Momentum: up to +15 % damage from 12 to 30 studs/s
	clearEnemies()
	local db0 = rp.Stats.DamageBonus or 0
	circleRun(30, 1.2, 14)
	local fast = (rp.Stats.DamageBonus or 0) - db0
	publishNow()
	local text = me:GetAttribute("ClassChargeText")
	advance(0.8, 30)
	local still = (rp.Stats.DamageBonus or 0) - db0
	check("crash_cassidy: Momentum ~+15% at 30 studs/s, 0 standing", fast >= 0.12 and fast <= 0.15 + 1e-6 and near(still, 0, 1e-6), f2(fast) .. " / " .. f2(still) .. " " .. tostring(text))
	-- body-check: 0.35 B once to each of at most 4 enemies, knockback
	clearEnemies()
	noCrit()
	local ring = {}
	for i = 1, 6 do
		local ang = i * math.pi / 3
		table.insert(ring, spawn(Vector3.new(math.cos(ang) * 1.6, 0, math.sin(ang) * 1.6)))
	end
	local starts = {}
	for i, e in ipairs(ring) do
		starts[i] = e.Pos
	end
	fakeDash(Vector3.new(1, 0, 0))
	step(0.4)
	local hits, right, knocked = 0, 0, 0
	for i, e in ipairs(ring) do
		if loss(e) > 0 then
			hits += 1
			if near(loss(e), hit(0.35, 1)) then
				right += 1
			end
			if ((e.Pos - starts[i]) * Vector3.new(1, 0, 1)).Magnitude > 1 then
				knocked += 1
			end
		end
	end
	check("crash_cassidy: body-check hits 4 once for 0.35 B", hits == 4 and right == 4, string.format("%d hit %d right", hits, right))
	check("crash_cassidy: body-check knocks normal enemies back", knocked >= 1, knocked)
end

TESTS.knuckles_mcgee = function(cls)
	local sig = "GloveCombo"
	check("knuckles_mcgee: Heavy Hands knockback x1.25", rp.KitKnockMult == KC.HeavyHands.KnockMult)
	setRank(sig, 1)
	clearEnemies()
	hold(sig)
	noCrit()
	local tgt = spawn(Vector3.new(3, 0, 0))
	local home = tgt.Pos
	local others = { spawn(Vector3.new(5.5, 0, 2.5)), spawn(Vector3.new(5.5, 0, -2.5)), spawn(Vector3.new(6.5, 0, 0)), spawn(Vector3.new(3, 0, 3.5)) }
	local w = weapon(sig)
	w.Charge, w.Uppercuts = 0, 0
	for _ = 1, 5 do
		fireOnce(sig)
		step(0.25)
		tgt.Knock = Vector3.zero
		tgt.Pos = home
	end
	publishNow()
	check("knuckles_mcgee: 5 punches (0.65 B) charge the weapon", w.Charge == 5 and near(loss(tgt), 5 * hit(0.65, 1), 0.05) and me:GetAttribute("ClassChargeText") == "Ready",
		string.format("charge %d loss %s %s", w.Charge, f2(loss(tgt)), tostring(me:GetAttribute("ClassChargeText"))))
	local before = loss(tgt)
	for _, o in ipairs(others) do
		o.HP = o.MaxHP
	end
	fireOnce(sig)
	step(0.3)
	local shocked, right = 0, 0
	for _, o in ipairs(others) do
		if loss(o) > 0 then
			shocked += 1
			if near(loss(o), hit(0.30, 1)) then
				right += 1
			end
		end
	end
	check("knuckles_mcgee: the uppercut 1.40 B replaces the punch", near(loss(tgt) - before, hit(1.40, 1)) and w.Charge == 0 and w.Uppercuts == 1, f2(loss(tgt) - before))
	check("knuckles_mcgee: shockwave 0.30 B on up to 3 others", shocked == 3 and right == 3, string.format("%d shocked %d right", shocked, right))
	setRank(sig, 3)
	local _, need3 = WS.GloveCharge(rp, 0)
	setRank(sig, 5)
	local _, need5 = WS.GloveCharge(rp, 0)
	check("knuckles_mcgee: rank 3 / 5 uppercut after 4 / 3", need3 == 4 and need5 == 3, tostring(need3) .. " " .. tostring(need5))
	setRank(sig, 1)
	-- close dodge: a dash ending within 6 of an enemy adds one charge, once per dash
	clearEnemies()
	w.Charge = 0
	spawn(Vector3.new(0, 0, 4))
	fakeDash(Vector3.new(1, 0, 0))
	K.EndDash(rp)
	K.EndDash(rp)
	local c1 = w.Charge
	clearEnemies()
	spawn(Vector3.new(0, 0, 12))
	fakeDash(Vector3.new(1, 0, 0))
	K.EndDash(rp)
	check("knuckles_mcgee: a close dodge adds 1 charge, once per dash, not from afar", c1 == 1 and w.Charge == 1, c1 .. " " .. w.Charge)
	-- Heavy Hands: normal enemies 25 % further (inside the cap), elites half without it
	clearEnemies()
	local n = spawn(Vector3.new(5, 0, 0))
	local el = spawn(Vector3.new(-5, 0, 0), nil, { Elite = true })
	WS.Damage(rp, n, 0.01, nil, 1, { Knock = 10, Secondary = true, From = rp.Root.Position })
	WS.Damage(rp, el, 0.01, nil, 1, { Knock = 10, Secondary = true, From = rp.Root.Position })
	check("knuckles_mcgee: Heavy Hands knockback 12.5 normal, elite 5", near(n.Knock.Magnitude, 12.5, 0.01) and (el == nil or near(el.Knock.Magnitude, 5, 0.01)),
		f2(n.Knock.Magnitude) .. " / " .. f2(el and el.Knock.Magnitude))
end

------------------------------------------------------------------------------------------
-- the runs
------------------------------------------------------------------------------------------
local first = true
for _, hero in ipairs(classes) do
	if not first then
		pcall(function()
			send("AbandonRun")
		end)
		step(2)
	end
	first = false
	local data = DS.GetData(me)
	if data then
		data.OwnedCharacters[hero] = true
		data.SelectedCharacter = hero
	end
	if RM.SetAdmittedClass then
		RM.SetAdmittedClass(me, hero)
	end
	send("StartRun", "Solo")
	step(1)
	rp = RM.GetRunPlayer(me)
	check(hero .. ": run started as the class", rp ~= nil and rp.CharacterId == hero, rp and rp.CharacterId)
	if rp then
		rp.InvulnUntil = math.huge
		LevelUp.CancelAll(rp) -- no level choices: the checks keep their exact build
		step(0.3)
		local sig = WeaponData.Signatures[hero]
		check(hero .. ": starts with " .. sig .. " in slot 1", rp.Weapons[sig] ~= nil and rp.WeaponOrder[1] == sig)
		check(hero .. ": max HP " .. f2(HP_MULT[hero] or 1) .. " H0", rp.Stats.MaxHP == math.floor(H0 * (HP_MULT[hero] or 1) + 0.5), rp.Stats.MaxHP)
		if hero ~= "swolverine" then
			check(hero .. ": base crit 5%", near(rp.Stats.CritChance, 0.05, 1e-6), rp.Stats.CritChance)
		end
		if hero ~= "granny_boom" then
			check(hero .. ": walks at 22", near(rp.Stats.Speed, 22, 0.01), f2(rp.Stats.Speed))
		end
		-- keep the loadout to the signature
		for i = #rp.WeaponOrder, 1, -1 do
			local id = rp.WeaponOrder[i]
			if id ~= sig then
				rp.Weapons[id] = nil
				table.remove(rp.WeaponOrder, i)
			end
		end
		local test = TESTS[hero]
		if test then
			local ok, err = pcall(test, hero)
			check(hero .. ": kit checks ran without errors", ok, not ok and tostring(err) or nil)
		end
		publishNow()
		check(hero .. ": HUD kit attribute " .. tostring(ClassRoster.KitNames[hero]), me:GetAttribute("ClassKit") == ClassRoster.KitNames[hero]
			and type(me:GetAttribute("ClassChargeText")) == "string", tostring(me:GetAttribute("ClassKit")) .. " " .. tostring(me:GetAttribute("ClassChargeText")))
		killTest(hero, sig)
		-- the first four evolve (stream B's evolutions still run with these behaviours)
		if WeaponData.Weapons[sig].Evolution and table.find(RunConfig.Builds.Evolutions, sig) then
			rp.ChoicesClosed = nil
			send("DevCommand", "GiveWeapon", sig)
			send("DevCommand", "EvolveWeapons")
			step(4)
			rp = RM.GetRunPlayer(me)
			check(hero .. ": evolved", rp ~= nil and rp.Weapons[sig] ~= nil and rp.Weapons[sig].Evolved == true)
			if rp then
				for wid, w in pairs(rp.Weapons) do
					w.Timer = wid == sig and 0 or 999
				end
				local d0 = rp.DamageDealt
				for i = 1, 3 do
					spawn(Vector3.new(6 + i, 0, 0), 50)
				end
				step(3)
				check(hero .. ": the evolved signature still deals damage", rp.DamageDealt > d0, math.floor(rp.DamageDealt - d0))
			end
		end
		check(hero .. ": still alive", rp ~= nil and rp.Alive)
	end
end
preview.log(fails == 0 and "class-kits-sim: ALL PASS" or ("class-kits-sim: " .. fails .. " FAIL"))
