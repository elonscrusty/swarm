-- final-stand-regression: Final Stand (server FinalStand.lua, Config.FinalStand, switch
-- Config.Features.FinalStand, docs/next/FINAL_STAND.md) against the REAL server, solo.
--
-- Default (regression): the stat math (StatSheet temporary multipliers), the trigger under
--   Config.FinalStand.HPShare once per stage, its re-arm on the next stage (a real travel),
--   not while protected / choosing / within the revive grace, per player, buffs removed
--   after Seconds, on a down (extra life), at the stage's end and on leaving the run, and the
--   switch off. PASS / FAIL lines.
-- Measure mode (--set measure=on): a solo Knight walks a circle (no dodging, cards auto
--   picked, no shopping) through `stages` stages (default 3): explore `explore` s (default
--   150), then the portal, the boss (it circles the boss) and the surge. NOT invulnerable:
--   a hit that would down the hero counts as a would-be death and refills HP ("undying").
--   Prints a MEASURE line per stage (clear time, damage taken, min HP share, would-be deaths,
--   Final Stand triggers, level). --set fs=off measures the game without Final Stand.
--   Stage modifiers are switched off in measure mode (--set sm=on keeps them).
-- Headless:
--   lune run tools/preview/runtime/main.luau -- --scene final-stand-regression --studio --device pc \
--     --out <json> --set headless=on --max-time 3000 [--seed N] [--set measure=on --set fs=off]
local Config = preview.shared("Config")
local StatSheet = preview.shared("StatSheet")
local measure = preview.args.measure == "on"
if preview.args.fs == "off" then
	(Config.Features :: any).FinalStand = false
end
if measure and preview.args.sm ~= "on" then
	-- one change at a time: the stage modifiers' random run seed would differ between runs
	(Config.Features :: any).StageModifiers = false
end
local FSC = (Config :: any).FinalStand
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

preview.startServer()
preview.advance(2)
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local FS = preview.server("FinalStand")
local DS = preview.server("DataService")
local Spawner = preview.server("EnemySpawner")
local me = game:GetService("Players").LocalPlayer
local data = DS.GetData(me)
if data then
	-- a returning player: no first-run walkthrough / welcome holds in the way
	data.TutorialDone = true
	data.Stats.Runs = math.max(3, tonumber(data.Stats.Runs) or 0)
end

preview.remote("StartRun"):FireServer("Solo")
preview.advance(1.5)
local rp = RM.GetRunPlayers()[1]
assert(rp, "no run player")

local rawAdvance = preview.advance
local function answer()
	if rp.Offer then
		rp.OfferDeadline = 0 -- auto-pick on the next LevelUpSystem step
	end
end
local function advance(t: number)
	local left = t
	while left > 0 do
		local step = math.min(left, 0.25)
		rawAdvance(step)
		left -= step
		answer()
	end
end

if not measure then
	------------------------------------------------------------------------------------
	-- 1. stat math (pure)
	------------------------------------------------------------------------------------
	local input = { CharacterId = "Knight", Meta = {}, Passives = {}, Items = {} }
	local plain = StatSheet.Compute(input :: any)
	local temp = table.clone(input) :: any
	temp.Temp = { FinalStand = FS.Mults() }
	local boosted = StatSheet.Compute(temp)
	check("stat math: damage x(1 + Damage)", near(boosted.Might, plain.Might * (1 + FSC.Damage)), string.format("%.3f -> %.3f", plain.Might, boosted.Might))
	check("stat math: speed x(1 + Speed)", near(boosted.Speed, plain.Speed * (1 + FSC.Speed)), string.format("%.2f -> %.2f", plain.Speed, boosted.Speed))
	check("stat math: no healing, max HP / armor unchanged", boosted.MaxHP == plain.MaxHP and boosted.Armor == plain.Armor and boosted.Regen == plain.Regen)
	local curse = table.clone(temp)
	curse.Curse = { Might = 1.3 }
	check("stat math: after curses (x1.3 x1.4)", near(StatSheet.Compute(curse).Might, plain.Might * 1.3 * (1 + FSC.Damage)))

	------------------------------------------------------------------------------------
	-- 2. the live trigger
	------------------------------------------------------------------------------------
	-- the swarm must not land its own hits while HP is set low: protected between test hits
	rp.InvulnUntil = math.huge
	advance(1)
	local baseMight, baseSpeed = rp.Stats.Might, rp.Stats.Speed
	local max = rp.Stats.MaxHP
	-- a hit that leaves the hero at `share` of max HP (area damage: no contact grace)
	local function hitTo(share: number)
		for _ = 1, 16 do
			if not rp.Offer and not rp.Paused then
				break
			end
			advance(0.25)
		end
		rp.InvulnUntil = 0
		rp.ContactGraceUntil = 0
		local want = rp.HP - max * share
		local amount = (want + rp.Stats.Armor) / math.max(0.01, rp.Stats.DamageTaken)
		RM.DamagePlayer(rp, math.max(1, amount), "test", "area")
		rp.InvulnUntil = math.huge
	end
	rp.HP = max * 0.6
	hitTo(0.3)
	check("no trigger at 30% HP", not FS.IsActive(rp), string.format("HP %.0f / %.0f", rp.HP, max))
	rp.HP = max * 0.2
	hitTo(0.06)
	check("triggers under 10% HP", FS.IsActive(rp), string.format("HP %.0f / %.0f", rp.HP, max))
	check("no healing on trigger", rp.HP < max * FSC.HPShare)
	check("player attribute FinalStand = Seconds", me:GetAttribute("FinalStand") == FSC.Seconds, tostring(me:GetAttribute("FinalStand")))
	check("live damage x1.4", near(rp.Stats.Might, baseMight * (1 + FSC.Damage)), string.format("%.3f -> %.3f", baseMight, rp.Stats.Might))
	check("live speed x1.3", near(rp.Stats.Speed, baseSpeed * (1 + FSC.Speed)), string.format("%.2f -> %.2f", baseSpeed, rp.Stats.Speed))
	local hum = rp.Humanoid
	check("walk speed follows", hum ~= nil and (hum.WalkSpeed == 0 or hum.WalkSpeed >= baseSpeed * (1 + FSC.Speed) - 0.01), hum and string.format("%.2f", hum.WalkSpeed) or "no humanoid")
	-- it never blocks lethal damage: the down check runs before Final Stand
	local downed = false
	local rawDowned = rp.RevivesLeft
	rp.RevivesLeft = 1 -- an extra life, so the solo run goes on
	rp.InvulnUntil = 0
	RM.DamagePlayer(rp, 1e6, "test lethal", "area")
	downed = rp.LastDownTime ~= nil and RM.GetRunTime() - rp.LastDownTime < 0.5
	check("a lethal hit still downs the hero during Final Stand", downed)
	rp.InvulnUntil = math.huge
	advance(0.2)
	check("cleared on a down (extra life revive)", not FS.IsActive(rp) and me:GetAttribute("FinalStand") == nil)
	check("buffs removed on a down", near(rp.Stats.Might, baseMight) and near(rp.Stats.Speed, baseSpeed), string.format("might %.3f speed %.2f", rp.Stats.Might, rp.Stats.Speed))
	rp.RevivesLeft = rawDowned
	-- used this stage: no second trigger
	advance(FSC.ReviveGrace + 0.5)
	rp.HP = max * 0.2
	hitTo(0.05)
	local ok, why = FS.CanTrigger(rp)
	check("once per stage", not FS.IsActive(rp) and why == "used", why)

	------------------------------------------------------------------------------------
	-- 3. limits (asked directly: the reasons)
	------------------------------------------------------------------------------------
	local stage = SM.GetStage()
	rp.FinalStandStage = nil -- pretend unused for the limit checks
	rp.HP = max * 0.05
	rp.InvulnUntil = RM.GetRunTime() + 5
	ok, why = FS.CanTrigger(rp)
	check("not while protected", not ok and why == "protected", why)
	check("OnHurt while protected does nothing", FS.OnHurt(rp) == false and not FS.IsActive(rp))
	rp.InvulnUntil = 0
	rp.Paused, rp.Offer = true, { Id = -1 }
	ok, why = FS.CanTrigger(rp)
	check("not while choosing an upgrade", not ok and why == "choosing", why)
	rp.Paused, rp.Offer = false, nil
	rp.RevivedAt = RM.GetRunTime() - (FSC.ReviveGrace - 0.5)
	ok, why = FS.CanTrigger(rp)
	check("not within the revive grace", not ok and why == "revive", why)
	rp.RevivedAt = RM.GetRunTime() - (FSC.ReviveGrace + 0.5)
	ok, why = FS.CanTrigger(rp)
	check("allowed after the revive grace", ok, why)
	-- per player: another hero's state is their own
	local other = { Alive = true, HP = 5, Stats = { MaxHP = 120 }, InvulnUntil = 0, Player = me }
	rp.FinalStandStage = stage
	local okOther = FS.CanTrigger(other)
	ok, why = FS.CanTrigger(rp)
	check("per player: a teammate can still trigger after this hero used it", okOther == true and not ok and why == "used")

	------------------------------------------------------------------------------------
	-- 4. timeout (5 s of run time)
	------------------------------------------------------------------------------------
	rp.FinalStandStage = nil
	rp.RevivedAt = -math.huge
	rp.HP = max * 0.2
	hitTo(0.06)
	check("re-triggered for the timeout check", FS.IsActive(rp))
	local t0 = RM.GetRunTime()
	for _ = 1, 80 do
		if RM.GetRunTime() - t0 >= FSC.Seconds - 1 then
			break
		end
		advance(0.25)
	end
	check("still active before Seconds", FS.IsActive(rp), string.format("run time +%.1f s", RM.GetRunTime() - t0))
	for _ = 1, 80 do
		if RM.GetRunTime() - t0 >= FSC.Seconds + 0.3 then
			break
		end
		advance(0.25)
	end
	advance(0.1)
	check("buffs removed after Seconds", not FS.IsActive(rp) and near(rp.Stats.Might, baseMight) and me:GetAttribute("FinalStand") == nil, string.format("run time +%.1f s", RM.GetRunTime() - t0))

	------------------------------------------------------------------------------------
	-- 5. stage end clears it, the next stage re-arms it (a real travel)
	------------------------------------------------------------------------------------
	rp.FinalStandStage = nil
	rp.HP = max * 0.2
	hitTo(0.06)
	local activeBefore = FS.IsActive(rp)
	local s0 = SM.GetStage()
	local moved = SM.DevNextStage()
	advance(0.3)
	check("cleared at the stage's end (travel)", activeBefore and not FS.IsActive(rp), "moved=" .. tostring(moved) .. " phase=" .. SM.GetPhase())
	for _ = 1, 40 do
		rp.InvulnUntil = math.huge -- the travel sets its own short grace
		if SM.GetStage() > s0 and SM.GetPhase() == "Explore" then
			break
		end
		advance(0.5)
	end
	check("reached the next stage", SM.GetStage() == s0 + 1, "stage " .. SM.GetStage())
	rp.InvulnUntil = math.huge
	advance(1)
	rp.RevivedAt = -math.huge
	rp.HP = max * 0.2
	hitTo(0.06)
	check("re-armed on the next stage", FS.IsActive(rp), "stage " .. SM.GetStage())

	------------------------------------------------------------------------------------
	-- 6. switch off
	------------------------------------------------------------------------------------
	advance(FSC.Seconds + 0.5)
	rp.FinalStandStage = nil
	;(Config.Features :: any).FinalStand = false
	rp.HP = max * 0.2
	hitTo(0.06)
	check("switch off: never triggers", not FS.IsActive(rp) and rp.TempMods == nil)
	;(Config.Features :: any).FinalStand = true

	------------------------------------------------------------------------------------
	-- 7. leaving the run clears it
	------------------------------------------------------------------------------------
	rp.FinalStandStage = nil
	rp.HP = max * 0.2
	hitTo(0.06)
	local wasActive = FS.IsActive(rp)
	RM.AbandonRun(rp)
	advance(0.5)
	check("cleared on leaving the run", wasActive and not FS.IsActive(rp) and (rp.TempMods == nil or rp.TempMods.FinalStand == nil) and me:GetAttribute("FinalStand") == nil)
	preview.log(string.format("RESULT final-stand failures %d", failures))
	return
end

----------------------------------------------------------------------------------------
-- MEASURE
----------------------------------------------------------------------------------------
local fsOn = Config.FeatureOn("FinalStand")
local t = 0
local dmg, deaths, minHP, triggers = {}, {}, {}, {}
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
	local wasActive = FS.IsActive(r)
	local res = rawDamage(r, amount, cause, ...)
	if r.HP < before then
		dmg[s] = (dmg[s] or 0) + (before - r.HP)
	end
	if not wasActive and FS.IsActive(r) then
		triggers[s] = (triggers[s] or 0) + 1
		preview.log(string.format("FINALSTAND %d:%02d S%d", t // 60, t % 60, s))
	end
	minHP[s] = math.min(minHP[s] or 1, r.HP / math.max(1, r.Stats.MaxHP))
	return res
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
local stages = tonumber(preview.args.stages) or 3
local explore = tonumber(preview.args.explore) or 150
local stageStart, stageEnd, levelAt, bossTime = {}, {}, {}, {}
for s = 1, stages do
	if SM.GetStage() ~= s or RM.GetRunPlayers()[1] ~= rp then
		break
	end
	stageStart[s] = t
	centre, radius = Config.ArenaOrigin, 24
	local e0 = t
	while t - e0 < explore and SM.GetStage() == s do
		tick(0.25)
	end
	-- to the portal ring, then the boss
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
	local bossDown = nil
	while SM.GetStage() == s and t - b0 < 300 do
		local boss = Spawner.Boss
		if boss and boss.Alive then
			centre, radius = boss.Pos, 12
		else
			if not bossDown then
				bossDown = t
			end
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
	bossTime[s] = bossDown and (bossDown - b0) or nil
	levelAt[s] = rp.Level
end
local totalDeaths, totalTriggers, totalClear = 0, 0, 0
for s = 1, stages do
	if stageStart[s] then
		local clear = stageEnd[s] and (stageEnd[s] - stageStart[s]) or 0
		totalDeaths += deaths[s] or 0
		totalTriggers += triggers[s] or 0
		totalClear += clear
		preview.log(string.format("MEASURE fs=%s S%d clear=%.0f boss=%s dmg=%.0f minHP=%.0f%% deaths=%d triggers=%d level=%d",
			tostring(fsOn), s, clear, bossTime[s] and string.format("%.0f", bossTime[s]) or "-", dmg[s] or 0, (minHP[s] or 1) * 100, deaths[s] or 0, triggers[s] or 0, levelAt[s] or rp.Level))
	end
end
preview.log(string.format("MEASURE fs=%s TOTAL clear=%.0f deaths=%d triggers=%d seed=%s", tostring(fsOn), totalClear, totalDeaths, totalTriggers, tostring(preview.seed)))
