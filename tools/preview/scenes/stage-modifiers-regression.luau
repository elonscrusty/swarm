-- stage-modifiers-regression: stage modifiers (StageModifierData, server RunModifiers,
-- Config.StageModifiers, switch Config.Features.StageModifiers, docs/next/STAGE_MODIFIERS.md)
-- against the REAL server, solo.
--
-- Default (regression): the pool (>= 8, trade-offs), the deterministic roll (same seed =
--   same list, no stage-1 modifier, no repeat in a row, Daily / Weekly fixed seeds), every
--   modifier's effects through the live hooks and their clearing (stat sheet, enemy HP /
--   damage, speed, spawns, elites, XP, kill gold, elite-chest rolls), the travel clearing it,
--   Gem Rain's fewer small chests on a real stage 2, SwarmState StageModifier for the card
--   and badge, the cap against the same curse effect and the switch off. PASS / FAIL lines.
-- Measure mode (--set measure=on --set mod=<Id>|none): a solo Knight walks a circle (no
--   dodging, cards auto-picked, no shopping) through `stages` stages (default 2), exploring
--   `explore` s (default 150) before the portal and the boss. Stage 2+ get modifier <Id>
--   (none = the switch off). NOT invulnerable: a would-be lethal hit is counted and HP
--   refilled ("undying"). Prints a MEASURE line per stage: clear time, damage taken, min HP,
--   would-be deaths, run gold earned, gem XP, level.
-- Headless:
--   lune run tools/preview/runtime/main.luau -- --scene stage-modifiers-regression --studio --device pc \
--     --out <json> --set headless=on --max-time 3000 [--seed N] [--set measure=on --set mod=GlassArena]
local Config = preview.shared("Config")
local SMD = preview.shared("StageModifierData")
local CurseData = preview.shared("CurseData")
local MetaData = preview.shared("MetaData")
local measure = preview.args.measure == "on"
local SMC = (Config :: any).StageModifiers
local failures = 0
local function check(name: string, good: boolean, detail: string?)
	if not good then
		failures += 1
	end
	preview.log((good and "PASS " or "FAIL ") .. name .. (detail and (" (" .. detail .. ")") or ""))
end
local function near(a: number?, b: number?, eps: number?): boolean
	return a ~= nil and b ~= nil and math.abs(a - b) <= (eps or 1e-3) * math.max(1, math.abs(b))
end

-- forced modifiers (stage -> id) before the server boots: the roll is replaced
local forced: { [number]: string }? = nil
if measure then
	local id = tostring(preview.args.mod or "none")
	if id == "none" then
		(Config.Features :: any).StageModifiers = false
	else
		assert(SMC.Pool[id], "unknown modifier " .. id)
		local rawRoll = SMD.Roll
		SMD.Roll = function(seed, stage)
			if rawRoll(seed, stage) == nil then
				return nil
			end
			return id
		end
	end
else
	forced = { [2] = "GemRain", [3] = "GlassArena" }
end

----------------------------------------------------------------------------------------
-- 1. pure data: pool, roll, combine (before the run)
----------------------------------------------------------------------------------------
local rawRoll = SMD.Roll
if not measure then
	check("pool has at least 8 modifiers", #SMC.Order >= 8, tostring(#SMC.Order))
	local tradeOffs = true
	for _, id in ipairs(SMC.Order) do
		local def = SMC.Pool[id]
		local e = SMD.Effects(id)
		-- a trade-off: at least one effect that helps the player and one that hurts
		local good = (e.XP > 1) or (e.Gold > 1) or (e.KillGold > 1) or (e.Might > 1) or (e.Speed > 1) or (e.ChestRolls > 0) or (e.SpawnMult < 1)
		local bad = (e.EnemySpeed > 1) or (e.EnemyHP > 1) or (e.EnemyDamage > 1) or (e.DamageTaken > 1) or (e.SmallChests < 1) or (e.EliteChance > 1) or (e.XP < 1) or (e.CooldownMult > 1)
		if not (def and def.Name and good and bad and #SMD.Lines(id) >= 2) then
			tradeOffs = false
			preview.log("  not a trade-off: " .. id)
		end
	end
	check("every modifier is a trade-off with readable lines", tradeOffs)
	preview.log("  e.g. " .. SMD.Name("SwiftFoes") .. ": " .. SMD.Short("SwiftFoes"))
	check("stage 1 has no modifier", rawRoll(12345, 1) == nil)
	local same, repeats, seen = true, 0, {}
	for seed = 1, 40 do
		local prev = nil
		for stage = 2, 12 do
			local a, b = rawRoll(seed * 7919, stage), rawRoll(seed * 7919, stage)
			if a ~= b or a == nil then
				same = false
			end
			if a == prev then
				repeats += 1
			end
			prev = a
			if a then
				seen[a] = true
			end
		end
	end
	local kinds = 0
	for _ in pairs(seen) do
		kinds += 1
	end
	check("deterministic: the same seed rolls the same modifier", same)
	check("never the same modifier two stages in a row", repeats == 0, tostring(repeats))
	check("every modifier comes up across seeds", kinds == #SMC.Order, kinds .. " of " .. #SMC.Order)
	local d = CurseData.Daily(CurseData.DayOf(os.time()))
	check("daily: one fixed list for the day", rawRoll(d.Seed, 3) == rawRoll(CurseData.Daily(d.Day).Seed, 3))
	check("cap: Glass Cannon x Glass Arena damage capped", near(SMD.Combine(1.3, 1.2, SMC.Caps.Might), SMC.Caps.Might))
	check("cap: Frenzy x Swift Foes speed capped", near(SMD.Combine(1.25, 1.15, SMC.Caps.EnemySpeed), SMC.Caps.EnemySpeed))
	check("cap: a lowering modifier always applies (Horde x Calm)", near(SMD.Combine(1.4, 0.85, SMC.Caps.SpawnMult), 1.4 * 0.85))
	check("cap: no curse, modifier alone", near(SMD.Combine(1, 1.15, SMC.Caps.EnemySpeed), 1.15))
	-- forced list for the live part
	SMD.Roll = function(seed, stage)
		if rawRoll(seed, stage) == nil then
			return nil
		end
		return forced and forced[stage] or rawRoll(seed, stage)
	end
end

preview.startServer()
preview.advance(2)
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local Mods = preview.server("RunModifiers")
local DS = preview.server("DataService")
local Loot = preview.server("LootSystem")
local Spawner = preview.server("EnemySpawner")
local XPS = preview.server("XPSystem")
local me = game:GetService("Players").LocalPlayer
local st = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState") :: any
local data = DS.GetData(me)
if data then
	data.TutorialDone = true
	data.Stats.Runs = math.max(3, tonumber(data.Stats.Runs) or 0)
	data.Curses = {}
end

preview.remote("StartRun"):FireServer("Solo")
preview.advance(1.5)
local rp = RM.GetRunPlayers()[1]
assert(rp, "no run player")
local rawAdvance = preview.advance
local function advance(t: number)
	local left = t
	while left > 0 do
		local step = math.min(left, 0.25)
		rawAdvance(step)
		left -= step
		if rp.Offer then
			rp.OfferDeadline = 0
		end
	end
end
local function nextStage(): boolean
	local s0 = SM.GetStage()
	SM.DevNextStage()
	for _ = 1, 40 do
		rp.InvulnUntil = math.huge
		if SM.GetStage() > s0 and SM.GetPhase() == "Explore" then
			return true
		end
		advance(0.5)
	end
	return false
end

if not measure then
	rp.InvulnUntil = math.huge
	advance(1)
	----------------------------------------------------------------------------------------
	-- 2. stage 1: nothing; a real stage 2 with Gem Rain
	----------------------------------------------------------------------------------------
	check("run seed set", type(Mods.RunSeed()) == "number")
	check("stage 1: no modifier live", Mods.StageModifier() == nil and st:GetAttribute("StageModifier") == "")
	check("stage 1: hooks neutral", Mods.StageMod("XP") == 1 and Mods.StageMod("KillGold") == 1 and Mods.StageModCount("ChestRolls") == 0)
	check("reached stage 2", nextStage(), "stage " .. SM.GetStage())
	advance(0.5)
	check("stage 2: Gem Rain live", Mods.StageModifier() == "GemRain", tostring(Mods.StageModifier()))
	check("stage 2: SwarmState StageModifier for the card / badge", st:GetAttribute("StageModifier") == "GemRain", tostring(st:GetAttribute("StageModifier")))
	check("Gem Rain: XP x1.3", near(Mods.StageMod("XP"), SMC.Pool.GemRain.XP))
	local small = 0
	for _, obj in ipairs(Loot.Objects and Loot.Objects() or {}) do
		if obj.Kind == "Chest" and obj.Type == "Small" then
			small += 1
		end
	end
	local C = Config.Chests
	local lo = math.floor(C.SmallCount[1] * SMC.Pool.GemRain.SmallChests + 0.5)
	local hi = math.floor(C.SmallCount[2] * SMC.Pool.GemRain.SmallChests + 0.5)
	check("Gem Rain: fewer small chests placed", small >= math.max(0, lo - 2) and small <= hi, string.format("%d small (expected <= %d of %d-%d)", small, hi, C.SmallCount[1], C.SmallCount[2]))
	----------------------------------------------------------------------------------------
	-- 3. stage 3: Glass Arena through the real stat sheet; the travel clears it
	----------------------------------------------------------------------------------------
	local rawPhase = SM.GetPhase
	SM.GetPhase = function()
		return "Travel"
	end
	check("during the travel (stage end) no modifier is live", Mods.StageModifier() == nil and Mods.StageMod("XP") == 1)
	SM.GetPhase = rawPhase
	check("reached stage 3", nextStage(), "stage " .. SM.GetStage())
	advance(0.5)
	local s3 = SM.GetStage()
	check("stage 3: Glass Arena live", Mods.StageModifier() == "GlassArena", tostring(Mods.StageModifier()))
	local glass = { Might = rp.Stats.Might, DamageTaken = rp.Stats.DamageTaken }
	----------------------------------------------------------------------------------------
	-- 4. every modifier through the live hooks (the live id swapped), then cleared
	----------------------------------------------------------------------------------------
	local rawLive = Mods.StageModifier
	local function live(id: string?)
		Mods.StageModifier = function()
			return id
		end
		Mods.Step(0) -- the stat sheets follow the change
	end
	live(nil)
	local neutral = {
		Might = rp.Stats.Might, DamageTaken = rp.Stats.DamageTaken, Speed = rp.Stats.Speed, Cooldown = rp.Stats.CooldownMult, Gold = rp.Stats.GoldMult,
		HP = SM.EnemyHPMult(), Damage = SM.DamageMult(), EnemySpeed = Mods.EnemySpeedMult(), Spawn = Mods.SpawnMult(), Elite = Mods.EliteChanceMult(),
	}
	-- the real stage-3 sheet (Glass Arena) against the same build with no modifier
	check("Glass Arena: you deal x1.2 (stat sheet)", near(glass.Might, neutral.Might * SMC.Pool.GlassArena.Might), string.format("%.3f -> %.3f", neutral.Might, glass.Might))
	check("Glass Arena: you take x1.2 (stat sheet)", near(glass.DamageTaken, neutral.DamageTaken * SMC.Pool.GlassArena.DamageTaken), string.format("%.3f -> %.3f", neutral.DamageTaken, glass.DamageTaken))
	local allOk = true
	for _, id in ipairs(SMC.Order) do
		live(id)
		local e = SMD.Effects(id)
		local okId = near(SM.EnemyHPMult(), neutral.HP * e.EnemyHP)
			and near(SM.DamageMult(), neutral.Damage * e.EnemyDamage)
			and near(Mods.EnemySpeedMult(), neutral.EnemySpeed * e.EnemySpeed)
			and near(Mods.SpawnMult(), neutral.Spawn * e.SpawnMult)
			and near(Mods.EliteChanceMult(), neutral.Elite * e.EliteChance)
			and near(Mods.StageMod("XP"), e.XP)
			and near(Mods.StageMod("KillGold"), e.KillGold)
			and Mods.StageModCount("ChestRolls") == e.ChestRolls
			and near(rp.Stats.Might, neutral.Might * e.Might)
			and near(rp.Stats.DamageTaken, neutral.DamageTaken * e.DamageTaken)
			and near(rp.Stats.CooldownMult, neutral.Cooldown * e.CooldownMult)
			and near(rp.Stats.GoldMult, neutral.Gold * e.Gold)
			and (e.Speed == 1 and near(rp.Stats.Speed, neutral.Speed) or rp.Stats.Speed > neutral.Speed or neutral.Speed >= Config.Player.BaseSpeed * Config.Items.MaxSpeedMult - 1e-3)
		preview.log(string.format("  %-11s hp x%.2f dmg x%.2f espeed x%.2f spawn x%.2f elite x%.2f xp x%.2f killgold x%.2f rolls %d | might x%.2f taken x%.2f speed x%.2f cd x%.2f gold x%.2f  %s",
			id, SM.EnemyHPMult() / neutral.HP, SM.DamageMult() / neutral.Damage, Mods.EnemySpeedMult() / neutral.EnemySpeed, Mods.SpawnMult() / neutral.Spawn, Mods.EliteChanceMult() / neutral.Elite,
			Mods.StageMod("XP"), Mods.StageMod("KillGold"), Mods.StageModCount("ChestRolls"), rp.Stats.Might / neutral.Might, rp.Stats.DamageTaken / neutral.DamageTaken,
			rp.Stats.Speed / neutral.Speed, rp.Stats.CooldownMult / neutral.Cooldown, rp.Stats.GoldMult / neutral.Gold, okId and "ok" or "WRONG"))
		allOk = allOk and okId
	end
	check("every modifier applies through the live hooks", allOk)
	live(nil)
	check("cleared: every hook back to neutral", near(rp.Stats.Might, neutral.Might) and near(rp.Stats.Speed, neutral.Speed) and near(rp.Stats.CooldownMult, neutral.Cooldown)
		and near(SM.EnemyHPMult(), neutral.HP) and near(Mods.EnemySpeedMult(), neutral.EnemySpeed) and Mods.StageMod("XP") == 1)
	Mods.StageModifier = rawLive
	Mods.Step(0)
	----------------------------------------------------------------------------------------
	-- 5. switch off: nothing anywhere
	----------------------------------------------------------------------------------------
	;(Config.Features :: any).StageModifiers = false
	Mods.Step(0)
	Mods.Publish()
	check("switch off: no modifier, neutral hooks", Mods.StageModifierFor(s3) == nil and Mods.StageModifier() == nil and Mods.StageMod("XP") == 1 and st:GetAttribute("StageModifier") == "" and near(rp.Stats.Might, neutral.Might))
	;(Config.Features :: any).StageModifiers = true
	Mods.Step(0)
	----------------------------------------------------------------------------------------
	-- 6. the run's end clears it; the cap against the same curse (Glass Cannon)
	----------------------------------------------------------------------------------------
	RM.AbandonRun(rp)
	advance(1)
	check("run end: no modifier on show", st:GetAttribute("StageModifier") == "" and Mods.StageModifier() == nil, tostring(st:GetAttribute("StageModifier")))
	if data then
		data.Curses = { "GlassCannon", "Frenzy" }
	end
	Mods.BeginRun("Solo", me)
	Mods.StageModifier = function()
		return "GlassArena"
	end
	local m = Mods.StatMults()
	check("cap: Glass Cannon + Glass Arena damage dealt / taken stop at the cap", m ~= nil and near(m.Might, SMC.Caps.Might) and near(m.DamageTaken, SMC.Caps.DamageTaken), m and string.format("%.3f / %.3f", m.Might, m.DamageTaken) or "nil")
	Mods.StageModifier = function()
		return "SwiftFoes"
	end
	check("cap: Frenzy + Swift Foes enemy speed stops at the cap", near(Mods.EnemySpeedMult() / Mods.DifficultyMultiplier("Speed"), SMC.Caps.EnemySpeed), string.format("%.3f", Mods.EnemySpeedMult()))
	Mods.StageModifier = rawLive
	Mods.EndRun()
	if data then
		data.Curses = {}
	end
	-- Daily / Weekly: the fixed seed
	Mods.BeginRun("Daily", me)
	local dailySeed = Mods.RunSeed()
	Mods.EndRun()
	Mods.BeginRun("Daily", me)
	check("daily runs use the day's fixed seed", dailySeed == CurseData.Daily(Mods.Today()).Seed and Mods.RunSeed() == dailySeed)
	Mods.EndRun()
	if Config.FeatureOn("WeeklyChallenge") then
		Mods.BeginRun(MetaData.WeeklyMode, me)
		check("weekly runs use the week's fixed seed", Mods.RunSeed() == MetaData.Weekly(MetaData.WeekOf(os.time())).Seed)
		Mods.EndRun()
	end
	Mods.BeginRun("Solo", me)
	local a = Mods.RunSeed()
	Mods.EndRun()
	Mods.BeginRun("Solo", me)
	check("normal runs get their own seed", Mods.RunSeed() ~= a)
	Mods.EndRun()
	SMD.Roll = rawRoll
	preview.log(string.format("RESULT stage-modifiers failures %d", failures))
	return
end

----------------------------------------------------------------------------------------
-- MEASURE
----------------------------------------------------------------------------------------
local modName = Config.FeatureOn("StageModifiers") and tostring(preview.args.mod) or "none"
local t = 0
local dmg, deaths, minHP, gold, xp = {}, {}, {}, {}, {}
local rawDamage = RM.DamagePlayer
RM.DamagePlayer = function(r, amount, cause, ...)
	if r ~= rp or not r.Alive then
		return rawDamage(r, amount, cause, ...)
	end
	local s = SM.GetStage()
	local d = (amount == amount and amount > 0 and r.Stats) and math.max(Config.Player.MinDamagePerHit, amount * r.Stats.DamageTaken - r.Stats.Armor) or 0
	if d > 0 and r.HP - d <= 0 and RM.IsSimulating() and not (r.Paused and r.Offer ~= nil) and RM.GetRunTime() >= r.InvulnUntil then
		deaths[s] = (deaths[s] or 0) + 1
		preview.log(string.format("DEATH %d:%02d S%d %s %s", t // 60, t % 60, s, SM.GetPhase(), tostring(cause)))
		r.HP = r.Stats.MaxHP
	end
	local before = r.HP
	local res = rawDamage(r, amount, cause, ...)
	if r.HP < before then
		dmg[s] = (dmg[s] or 0) + (before - r.HP)
	end
	minHP[s] = math.min(minHP[s] or 1, r.HP / math.max(1, r.Stats.MaxHP))
	return res
end
local Gold = preview.server("GoldSystem")
local rawAdd = Gold.AddRunGold
Gold.AddRunGold = function(r, amount, ...)
	local paid = rawAdd(r, amount, ...)
	if r == rp and type(paid) == "number" then
		local s = SM.GetStage()
		gold[s] = (gold[s] or 0) + paid
	end
	return paid
end
local rawGive = XPS.GiveXP
XPS.GiveXP = function(r, amount, ...)
	if r == rp and amount == amount and amount > 0 and amount < math.huge then
		local s = SM.GetStage()
		xp[s] = (xp[s] or 0) + amount
	end
	return rawGive(r, amount, ...)
end

local centre = Config.ArenaOrigin
local radius, angle = 24, 0
local function tick(dt: number)
	advance(dt)
	t += dt
	angle += dt * 5 / 24
	local root = rp.Root
	if root and rp.Alive then
		local pos = Vector3.new(centre.X + math.cos(angle) * radius, root.Position.Y, centre.Z + math.sin(angle) * radius)
		local dir = Vector3.new(-math.sin(angle), 0, math.cos(angle))
		rp.MoveDir, rp.Facing = dir, dir
		root.CFrame = CFrame.lookAt(pos, pos + dir)
		rp.LastValidPos, rp.SpeedCheckTimer = root.Position, 0
	end
end
local stages = tonumber(preview.args.stages) or 2
local explore = tonumber(preview.args.explore) or 150
local stageStart, stageEnd, levelAt, live = {}, {}, {}, {}
for s = 1, stages do
	if SM.GetStage() ~= s or RM.GetRunPlayers()[1] ~= rp then
		break
	end
	stageStart[s] = t
	centre, radius = Config.ArenaOrigin, 24
	local e0 = t
	while t - e0 < explore and SM.GetStage() == s do
		tick(0.25)
		live[s] = live[s] or Mods.StageModifier()
	end
	local p = SM.PortalPosition()
	if p then
		centre, radius = p, 2
	end
	local c0 = t
	while not SM.IsBossFight() and t - c0 < 40 and SM.GetStage() == s do
		tick(0.25)
	end
	if not SM.IsBossFight() and SM.GetStage() == s then
		SM.DevActivate()
	end
	local b0 = t
	while SM.GetStage() == s and t - b0 < 300 do
		local boss = Spawner.Boss
		if boss and boss.Alive then
			centre, radius = boss.Pos, 12
		else
			radius = 24
		end
		if SM.GetPhase() == "Open" then
			preview.remote("PortalChoice"):FireServer(s < stages and "Next" or "Return")
		end
		tick(0.25)
		if s == stages and SM.GetPhase() == "Open" then
			break
		end
	end
	stageEnd[s] = t
	levelAt[s] = rp.Level
end
for s = 1, stages do
	if stageStart[s] then
		preview.log(string.format("MEASURE mod=%s S%d live=%s clear=%.0f dmg=%.0f minHP=%.0f%% deaths=%d gold=%.0f xp=%.0f level=%d",
			modName, s, tostring(live[s] or "-"), stageEnd[s] and (stageEnd[s] - stageStart[s]) or 0, dmg[s] or 0, (minHP[s] or 1) * 100, deaths[s] or 0, gold[s] or 0, xp[s] or 0, levelAt[s] or rp.Level))
	end
end
preview.log(string.format("MEASURE mod=%s DONE seed=%s", modName, tostring(preview.seed)))
