-- fast-start-regression: the faster stage-1 opening (Config.FastStart, switch
-- Config.Features.FastStart, docs/next/FAST_START.md) against the REAL server. A solo
-- Knight walks a circle near the spawn while the waves come; level-up cards are auto-picked.
-- The hero is NOT invulnerable: damage is real, but a hit that would down him counts as a
-- would-be death and refills his HP instead ("undying"), so the run always goes on.
--
-- Default (regression, ~2-3 min): stage 1 until wave 4 is announced, then checks that
--   waves 1-3 are faster and bigger than the plain numbers, wave 4 and the never-shrink
--   floor are untouched, the first level-up comes by Config.FastStart.FirstLevelUpBy, and
--   the switch off (or stage 2) gives multiplier 1 everywhere. PASS / FAIL lines.
-- Measure mode (--set measure=on): plays stage 1 (leave for the portal once wave `leave`
--   is announced, default 4, cap `explore` s) through the boss and surge, then stage 2
--   (`explore2` s, default 120) and prints a MEASURE line per stage. --set faststart=off
--   measures the old opening. --set stages=1 stops after stage 1.
-- Headless:
--   lune run tools/preview/runtime/main.luau -- --scene fast-start-regression --studio --device pc \
--     --out <json> --set headless=on --max-time 400 [--seed N] [--set measure=on --set faststart=off]
local Config = preview.shared("Config")
local measure = preview.args.measure == "on"
if preview.args.faststart == "off" then
	(Config.Features :: any).FastStart = false
end
local fsOn = Config.FeatureOn("FastStart")
local FS = (Config :: any).FastStart
-- --set fs=SizeMult:1.3,BreatherMult:0.4 overrides Config.FastStart values (tuning)
for pair in string.gmatch(tostring(preview.args.fs or ""), "[^,]+") do
	local k, v = string.match(pair, "^(%w+):([%d%.]+)$")
	if k and FS then
		FS[k] = tonumber(v)
	end
end
local failures = 0
local function check(name: string, good: boolean, detail: string?)
	if not good then
		failures += 1
	end
	preview.log((good and "PASS " or "FAIL ") .. name .. (detail and (" (" .. detail .. ")") or ""))
end

preview.startServer()
preview.advance(2)
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local Spawner = preview.server("EnemySpawner")
local XPS = preview.server("XPSystem")
local st = game:GetService("ReplicatedStorage"):FindFirstChild("SwarmState") :: any

preview.remote("StartRun"):FireServer("Solo")
preview.advance(1.5)
local rp = RM.GetRunPlayers()[1]
assert(rp, "no run player")

-- XP gained (after pacing / growth) by run time
local xpTotal, xp90 = 0, nil
local t = 0
local rawGive = XPS.GiveXP
XPS.GiveXP = function(r, amount, ...)
	if r == rp and amount == amount and amount > 0 and amount < math.huge then
		xpTotal += amount
	end
	return rawGive(r, amount, ...)
end
-- undying: damage per stage, min HP share, would-be deaths
local dmg, deaths, minHP = {}, {}, {}
local dmg90 = 0 -- damage taken in the first 90 s of the run
local rawDamage = RM.DamagePlayer
RM.DamagePlayer = function(r, amount, cause, ...)
	if r ~= rp or not r.Alive then
		return rawDamage(r, amount, cause, ...)
	end
	local s = SM.GetStage()
	local d = (amount == amount and amount > 0 and r.Stats) and math.max(Config.Player.MinDamagePerHit, amount * r.Stats.DamageTaken - r.Stats.Armor) or 0
	if d > 0 and r.HP - d <= 0 and RM.IsSimulating() and not (r.Paused and r.Offer ~= nil) and RM.GetRunTime() >= r.InvulnUntil then
		deaths[s] = (deaths[s] or 0) + 1
		preview.log(string.format("DEATH %d:%02d S%d %s %s", t // 60, t % 60, s, SM.GetPhase(), typeof(cause) == "table" and tostring(cause.Type or (cause.Def and cause.Def.Id)) or tostring(cause)))
		r.HP = r.Stats.MaxHP
	end
	local before = r.HP
	local res = rawDamage(r, amount, cause, ...)
	if r.HP < before then
		dmg[s] = (dmg[s] or 0) + (before - r.HP)
		if t < 90 then
			dmg90 += before - r.HP
		end
	end
	minHP[s] = math.min(minHP[s] or 1, r.HP / math.max(1, r.Stats.MaxHP))
	return res
end

local centre = Config.ArenaOrigin
local radius, angle = 24, 0
local firstUp, lastLevel = nil, rp.Level
local level120 = nil
local lastSeq = 0
local waves = {} -- n -> { T, Size, Clear }
local curN = nil
local counted = {}
local function tick(dt: number)
	preview.advance(dt)
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
	if rp.Offer then
		rp.OfferDeadline = 0
	end
	if rp.Level > lastLevel then
		if not firstUp then
			firstUp = t
		end
		preview.log(string.format("UP %d:%02d S%d L%d", t // 60, t % 60, SM.GetStage(), rp.Level))
		lastLevel = rp.Level
	end
	if not xp90 and t >= 90 then
		xp90 = xpTotal
	end
	if not level120 and t >= 120 then
		level120 = rp.Level + rp.XP / math.max(1, rp.XPNeeded)
	end
	local seq = st:GetAttribute("WaveSeq") or 0
	if seq ~= lastSeq then
		lastSeq = seq
		curN = st:GetAttribute("Wave") or 0
		waves[curN] = { T = t, Size = 0, Stage = SM.GetStage() }
	end
	local w = curN and waves[curN]
	if w and not w.Clear then
		for _, e in ipairs(Spawner.Active) do
			if e.Alive and e.WaveId == curN and not counted[e.Uid] and not (e.Def and e.Def.Spawner) then
				counted[e.Uid] = true
				w.Size += 1
			end
		end
		if (st:GetAttribute("WaveNext") or 0) > 0 or SM.GetPhase() ~= "Explore" then
			w.Clear = t - w.T
		end
	end
end

local leave = tonumber(preview.args.leave) or 4
local exploreCap = tonumber(preview.args.explore) or 150
local stage1T0 = t
while t - stage1T0 < exploreCap and not waves[leave] do
	tick(0.25)
end
local wave4At = waves[leave] and waves[leave].T or nil
if not measure and wave4At then
	-- let wave 4 pour in fully so its size can be compared with the plain one
	local w0 = t
	while t - w0 < 12 and not waves[leave].Clear do
		tick(0.25)
	end
end
local function waveLine(): string
	local parts = {}
	for n = 1, 12 do
		local w = waves[n]
		if w then
			table.insert(parts, string.format("w%d@%.0fs size %d %s", n, w.T, w.Size, w.Clear and string.format("%.0fs", w.Clear) or "-"))
		end
	end
	return table.concat(parts, " | ")
end
preview.log("WAVES " .. waveLine())

if not measure then
	-- 1. the multipliers (switch on: waves 1..Waves on stage 1 only)
	local m = Spawner.FastStartMult
	check("FastStartMult exported", type(m) == "function")
	if type(m) == "function" then
		if fsOn then
			check("wave 1 size mult", m(1, "SizeMult") == FS.SizeMult, tostring(m(1, "SizeMult")))
			check("wave 3 timer mult", m(3, "MaxSecondsMult") == FS.MaxSecondsMult, tostring(m(3, "MaxSecondsMult")))
			check("wave 4 untouched", m(4, "SizeMult") == 1 and m(4, "MaxSecondsMult") == 1)
		end
		;(Config.Features :: any).FastStart = false
		check("switch off: mult 1", m(1, "SizeMult") == 1 and m(1, "BreatherMult") == 1 and m(1, "MaxSecondsMult") == 1)
		;(Config.Features :: any).FastStart = fsOn
	end
	-- 2. the live waves: bigger, quicker
	local W = Config.Waves
	for n = 1, 3 do
		local w = waves[n]
		if w and fsOn then
			-- WaveSize(n) is the plain size; the wave is SizeMult x that (live cap aside)
			local plain = Spawner.WaveSize(n)
			check(string.format("wave %d bigger (%d vs plain %d)", n, w.Size, plain), w.Size >= math.floor(plain * FS.SizeMult + 0.5) - 1)
			check(string.format("wave %d within the shorter cap", n), (w.Clear or 999) <= W.MaxSeconds * FS.MaxSecondsMult + 0.5, string.format("%.1fs", w.Clear or -1))
		end
	end
	check("wave 4 reached", wave4At ~= nil, wave4At and string.format("%.0fs", wave4At) or "not reached")
	if waves[4] and fsOn then
		local plain = Spawner.WaveSize(4)
		check(string.format("wave 4 size plain (%d vs %d)", waves[4].Size, plain), math.abs(waves[4].Size - plain) <= 1)
		check("waves 1-3 sooner than the plain cap", wave4At < W.FirstDelay + 3 * (W.MaxSeconds + W.BreatherSeconds))
	end
	-- the redesign economy (stream E2: personal shards at the kill spot, 8-stud pickup, the
	-- 20 + 12(L-1) + 3(L-1)^2 curve) changes the opening's XP: this bot walks a fixed circle and
	-- never goes for its shards, so its first level-up is reported as a measurement against the
	-- brief's 20-35 s target (pacing belongs to the run director pass), not as a regression
	local economy = preview.require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Economy
	if fsOn and economy and economy.Enabled then
		preview.log(string.format("MEASURE first level-up %s (redesign economy; brief target 20-35 s; circle bot, no shard chasing)", firstUp and string.format("%.1fs", firstUp) or "none"))
		check("a first level-up happens in the opening", firstUp ~= nil and firstUp <= 60, firstUp and string.format("%.1fs", firstUp) or "none")
	elseif fsOn then
		check("first level-up by FirstLevelUpBy", firstUp ~= nil and firstUp <= FS.FirstLevelUpBy, firstUp and string.format("%.1fs", firstUp) or "none")
	end
	-- 3. stage 2: no fast start
	if type(Spawner.FastStartMult) == "function" then
		local rawStage = SM.GetStage
		SM.GetStage = function()
			return 2
		end
		check("stage 2: mult 1", Spawner.FastStartMult(1, "SizeMult") == 1)
		SM.GetStage = rawStage
	end
	preview.log(string.format("RESULT faststart=%s first level-up %s wave4 %s failures %d", tostring(fsOn), firstUp and string.format("%.1fs", firstUp) or "-", wave4At and string.format("%.0fs", wave4At) or "-", failures))
	return
end

-- MEASURE: stage 1 through the boss and the surge, then stage 2
local stages = tonumber(preview.args.stages) or 2
local explore2 = tonumber(preview.args.explore2) or 120
local stageStart = { [1] = stage1T0 }
local stageEnd, levelAt = {}, {}
local function bossAndSurge(s: number)
	local p = SM.PortalPosition()
	if p then
		centre = p
	end
	radius = 2
	local c0 = t
	while not SM.IsBossFight() and t - c0 < 40 and SM.GetStage() == s do
		tick(0.25)
	end
	radius = 24
	if not SM.IsBossFight() then
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
		tick(0.25)
	end
	stageEnd[s] = t
	levelAt[s] = rp.Level
	centre, radius = Config.ArenaOrigin, 24
end
bossAndSurge(1)
if stages >= 2 and SM.GetStage() == 2 then
	stageStart[2] = t
	local e0 = t
	while t - e0 < explore2 do
		tick(0.25)
	end
	bossAndSurge(2)
end
local xpm90 = (xp90 or xpTotal) / 1.5
preview.log(string.format("MEASURE faststart=%s firstLevelUp=%s xpPerMin90=%.0f levelAt2min=%.2f wave4At=%s dmg90=%.0f",
	tostring(fsOn), firstUp and string.format("%.1f", firstUp) or "-", xpm90, level120 or -1, wave4At and string.format("%.0f", wave4At) or "-", dmg90))
for s = 1, stages do
	if stageStart[s] then
		preview.log(string.format("MEASURE S%d clear=%s dmg=%.0f minHP=%.0f%% deaths=%d level=%d",
			s, stageEnd[s] and string.format("%.0f", stageEnd[s] - stageStart[s]) or "-", dmg[s] or 0, (minHP[s] or 1) * 100, deaths[s] or 0, levelAt[s] or rp.Level))
	end
end
preview.log("WAVES " .. waveLine())
