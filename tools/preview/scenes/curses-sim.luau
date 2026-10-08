-- curses-sim: boots the REAL server and checks every curse (CurseData / RunModifiers) and
-- the Daily Challenge through the remotes, headless. Run it with --studio (the dev-taint
-- check uses a DEV command): render.sh curses-sim --studio --devices pc --max-time 400
--   1. SetCurses validation: junk ignored, unknown ids dropped, duplicates merged, at most
--      CurseData.MaxActive kept in CurseData.Order; the Duo countdown shows the starter's pick.
--   2. A clean baseline Solo run, then one Solo run per curse and three stacks. Each run is
--      measured against the baseline: max HP (and full HP at the start), damage dealt
--      (Might), damage taken (a real DamagePlayer hit), enemy speed (a real spawn; bosses
--      excluded), the spawn multiplier, the elite chance multiplier, floor pickups (no
--      Roast Chicken under Famine), and run gold (AddRunGold pays base x pass x curse gold
--      exactly once; the results' GoldEarned is the run counter, not multiplied again).
--      Curses are fixed for the run (SetCurses mid-run is ignored) and cleared afterwards.
--   3. The Daily Challenge: today's fixed curses replace the player's own, the scored
--      attempt, a practice run (unscored), the Daily board; then other UTC days (one per
--      starting bonus) through RunModifiers.Today: each day resets the attempt, its bonus
--      applies, and a DEV-tainted daily spends the attempt but scores nothing.
--   4. CurseData.Daily over 400 days: valid, deterministic, two distinct curses.
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local st = C.state()
local me = Players.LocalPlayer
local advance = preview.advance
local function pickLevels()
	for _ = 1, 40 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
		advance(0.3)
	end
end
local function send(name, ...)
	preview.remote(name):FireServer(...)
	advance(0.2)
	pickLevels()
end
local function wait(t)
	local left = t
	while left > 0 do
		local step = math.min(left, 0.5)
		advance(step)
		left -= step
		pickLevels()
	end
end
local Config = C.shared("Config")
local CurseData = C.shared("CurseData")
local Spawner = preview.server("EnemySpawner")
local Stage = preview.server("StageManager")
local RM = preview.server("RunManager")
local Mods = preview.server("RunModifiers")
local DS = preview.server("DataService")
local Gold = preview.server("GoldSystem")
local XP = preview.server("XPSystem")
local results, boards = {}, {}
preview.remote("RunResult").OnClientEvent:Connect(function(d)
	table.insert(results, d)
end)
preview.remote("LeaderboardData").OnClientEvent:Connect(function(d)
	boards[d.Board] = d
end)
local fails = 0
local function check(label, ok)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local function near(a, b, tol)
	return type(a) == "number" and type(b) == "number" and math.abs(a - b) <= (tol or 1e-6)
end
local function join(list)
	return table.concat(list or {}, ",")
end
local function sameList(a, b)
	return join(a) == join(b)
end

------------------------------------------------------------------------------------------
-- 1. SetCurses validation
------------------------------------------------------------------------------------------
local data = DS.GetData(me)
send("SetCurses", "Frenzy")
send("SetCurses", { Frenzy = true })
send("SetCurses", { 1, 2 })
check("junk SetCurses ignored (attr '" .. tostring(me:GetAttribute("Curses")) .. "')", (me:GetAttribute("Curses") or "") == "" and #(data.Curses or {}) == 0)
send("SetCurses", { "Horde", "Nope", "Horde", "Frenzy" })
check("unknown dropped, duplicates merged, Order kept: " .. tostring(me:GetAttribute("Curses")), me:GetAttribute("Curses") == "Frenzy,Horde" and sameList(data.Curses, { "Frenzy", "Horde" }))
send("SetCurses", { "EliteSurge", "GlassCannon", "Famine", "Horde", "Fragile", "Frenzy" })
check("at most MaxActive (" .. CurseData.MaxActive .. ") kept: " .. tostring(me:GetAttribute("Curses")), me:GetAttribute("Curses") == "Frenzy,Fragile,Horde")
send("StartRun", "Duo")
wait(0.6)
check("Duo countdown shows the starter's curses: " .. tostring(st:GetAttribute("Curses")) .. " gold x" .. tostring(st:GetAttribute("CurseGold")),
	st:GetAttribute("Phase") == "Countdown" and st:GetAttribute("Curses") == "Frenzy,Fragile,Horde" and near(st:GetAttribute("CurseGold"), 1.65))
wait(Config.Run.CountdownSeconds + 2)
if st:GetAttribute("Phase") == "Running" then
	send("AbandonRun")
	wait(1.5)
end

------------------------------------------------------------------------------------------
-- 2. one run per curse set, measured against a clean baseline
------------------------------------------------------------------------------------------
local function protectLevelUps(rp)
	pickLevels()
	if rp then
		rp.Paused = false
		rp.RewardUntil = nil
	end
end

local function measure(list)
	send("SetCurses", list)
	send("StartRun", "Solo")
	wait(1.5)
	local rp = RM.GetRunPlayer(me)
	local m = { List = list }
	if not rp or st:GetAttribute("Phase") ~= "Running" then
		m.Error = "no run (phase " .. tostring(st:GetAttribute("Phase")) .. ")"
		return m
	end
	m.Active = table.clone(Mods.Active())
	m.GoldMult = Mods.GoldMult()
	m.StateCurses = st:GetAttribute("Curses")
	m.StateGold = st:GetAttribute("CurseGold")
	m.MaxHP = rp.Stats.MaxHP
	m.HPFull = rp.HP == rp.Stats.MaxHP
	m.Might = rp.Stats.Might
	m.DamageTaken = rp.Stats.DamageTaken
	m.SpawnMult = Stage.SpawnMult()
	m.SpeedMult = Mods.EnemySpeedMult()
	m.EliteMult = Mods.EliteChanceMult()
	-- a real enemy spawn (tier 0 at this point of the run)
	local pos = Spawner.SpawnPoint(2)
	local e = pos and Spawner.Spawn("Slime", pos, { Force = true })
	m.SlimeSpeed = e and e.Speed or -1
	if e then
		Spawner.Kill(e, rp)
	end
	-- a real hit
	protectLevelUps(rp)
	rp.InvulnUntil = 0
	local before = rp.HP
	RM.DamagePlayer(rp, 40, "curses-sim")
	m.HitLoss = before - rp.HP
	m.HitExpected = math.max(Config.Player.MinDamagePerHit, 40 * rp.Stats.DamageTaken - rp.Stats.Armor)
	rp.InvulnUntil = math.huge
	-- floor pickups: 400 forced rolls
	local chickens, rolls = 0, 0
	for _ = 1, 400 do
		local kind = XP.RollFloorPickup(Vector3.zero, 1e6)
		if kind then
			rolls += 1
			if kind == "Chicken" then
				chickens += 1
			end
		end
	end
	m.Chickens, m.Rolls = chickens, rolls
	-- run gold: one AddRunGold of 100
	local pass = Gold.PublishGoldMult(me)
	local g0 = rp.Gold
	local paid = Gold.AddRunGold(rp, 100)
	m.GoldPaid = paid
	m.GoldExpected = math.floor(100 * pass * m.GoldMult + 0.5)
	m.GoldCounter = rp.Gold - g0
	-- a few seconds of play (elites / live count are logged, not asserted: random)
	local elites = 0
	for _ = 1, 8 do
		rp.InvulnUntil = math.huge
		wait(0.5)
		for _, x in ipairs(Spawner.Active) do
			if x.Elite and not x.CountedBySim then
				x.CountedBySim = true
				elites += 1
			end
		end
	end
	m.Elites, m.Live = elites, #Spawner.Active
	-- curses are fixed for the run
	send("SetCurses", { "Famine" })
	m.FixedAfterSet = sameList(Mods.Active(), m.Active)
	m.GoldBeforeEnd = rp.Gold
	send("AbandonRun")
	wait(1.5)
	local d = results[#results] or {}
	m.Result = d
	m.ClearedAfter = #Mods.Active() == 0 and Mods.GoldMult() == 1 and (st:GetAttribute("Curses") or "") == ""
	wait(0.5)
	return m
end

local base = measure({})
if base.Error then
	check("baseline run: " .. base.Error, false)
end
preview.log(string.format("baseline: MaxHP %d Might %.2f DT %.2f spawn x%.2f speed x%.2f slime %.2f hit %.1f chickens %d/%d gold %d live %d elites %d",
	base.MaxHP or -1, base.Might or -1, base.DamageTaken or -1, base.SpawnMult or -1, base.SpeedMult or -1, base.SlimeSpeed or -1,
	base.HitLoss or -1, base.Chickens or -1, base.Rolls or -1, base.GoldPaid or -1, base.Live or -1, base.Elites or -1))
check("baseline: no curses, gold x1, chickens drop", base.GoldMult == 1 and #(base.Active or { 1 }) == 0 and (base.Chickens or 0) > 0)

local sets = {
	{ "Frenzy" }, { "Fragile" }, { "Horde" }, { "Famine" }, { "GlassCannon" }, { "EliteSurge" },
	{ "Frenzy", "Fragile", "Horde" },
	{ "Fragile", "GlassCannon", "EliteSurge" },
	{ "Horde", "Famine", "EliteSurge" },
}
local verdict = {}
for _, list in ipairs(sets) do
	local name = join(list)
	local m = measure(list)
	if m.Error then
		check(name .. ": " .. m.Error, false)
		continue
	end
	local e = CurseData.Effects(list)
	local wantGold = CurseData.GoldMult(list)
	local okAll = true
	local function c(label, ok)
		check(name .. ": " .. label, ok)
		okAll = okAll and ok
	end
	preview.log(string.format("%s: MaxHP %d Might %.2f DT %.2f spawn x%.2f speed x%.2f slime %.2f hit %.1f/%.1f chickens %d/%d gold %d (x%.2f) live %d elites %d",
		name, m.MaxHP, m.Might, m.DamageTaken, m.SpawnMult, m.SpeedMult, m.SlimeSpeed, m.HitLoss, m.HitExpected, m.Chickens, m.Rolls, m.GoldPaid, m.GoldMult, m.Live, m.Elites))
	c("active " .. join(m.Active) .. ", state '" .. tostring(m.StateCurses) .. "'", sameList(m.Active, list) and m.StateCurses == name)
	c(string.format("gold x%.2f = 1 + sum (%.2f), shown %.2f", m.GoldMult, wantGold, m.StateGold or -1), near(m.GoldMult, wantGold) and near(m.StateGold, wantGold))
	c(string.format("max HP %d = baseline %d x %.2f, starts full", m.MaxHP, base.MaxHP, e.MaxHP), m.MaxHP == math.max(1, math.floor(base.MaxHP * e.MaxHP + 0.5)) and m.HPFull)
	c(string.format("damage dealt x%.2f", m.Might / base.Might), near(m.Might, base.Might * e.Might, 1e-4))
	c(string.format("damage taken x%.2f, hit %.1f = %.1f", m.DamageTaken / base.DamageTaken, m.HitLoss, m.HitExpected), near(m.DamageTaken, base.DamageTaken * e.DamageTaken, 1e-4) and near(m.HitLoss, m.HitExpected, 0.01))
	c(string.format("enemy speed x%.2f (slime %.2f vs %.2f)", m.SpeedMult, m.SlimeSpeed, base.SlimeSpeed), near(m.SpeedMult, e.EnemySpeed) and near(m.SlimeSpeed, base.SlimeSpeed * e.EnemySpeed, 1e-3))
	c(string.format("spawn x%.2f vs baseline x%.2f", m.SpawnMult, base.SpawnMult), near(m.SpawnMult, base.SpawnMult * e.SpawnMult, 1e-4))
	c(string.format("elite chance x%.2f", m.EliteMult), near(m.EliteMult, e.EliteChance))
	if e.NoHealPickups then
		c(string.format("no chickens (%d of %d pickups)", m.Chickens, m.Rolls), m.Chickens == 0 and m.Rolls > 0)
	else
		c(string.format("chickens still drop (%d of %d)", m.Chickens, m.Rolls), m.Chickens > 0)
	end
	c(string.format("AddRunGold(100) paid %d = %d once, counter +%d", m.GoldPaid, m.GoldExpected, m.GoldCounter), m.GoldPaid == m.GoldExpected and m.GoldCounter == m.GoldPaid)
	c("curses fixed for the run (SetCurses mid-run ignored)", m.FixedAfterSet)
	local d = m.Result
	c(string.format("results: curses %s, CurseGold %.2f, GoldEarned %s = run counter %d", join(d.Curses), d.CurseGold or -1, tostring(d.GoldEarned), m.GoldBeforeEnd),
		sameList(d.Curses, list) and near(d.CurseGold, wantGold) and d.GoldEarned == m.GoldBeforeEnd)
	c("cleared after the run", m.ClearedAfter)
	verdict[name] = okAll
end

------------------------------------------------------------------------------------------
-- 3. the Daily Challenge
------------------------------------------------------------------------------------------
send("SetCurses", { "Frenzy", "Horde" })
local realToday = Mods.Today()
local today = CurseData.Daily(realToday)
preview.log("daily", today.Date, "curses", join(today.Curses), "bonus", today.Bonus, tostring(today.BonusWeapon), join(today.BonusItems), "arenas", join(today.Arenas), "bosses", join(today.Bosses))
local baseRevives = nil
local function dailyRun(label, opts)
	opts = opts or {}
	local d = CurseData.Daily(Mods.Today())
	send("StartRun", "Daily")
	wait(1.5)
	local rp = RM.GetRunPlayer(me)
	if not rp or st:GetAttribute("Phase") ~= "Running" then
		check(label .. ": daily started", false)
		return nil
	end
	local info = {
		Scored = rp.DailyScored, Curses = table.clone(Mods.Active()), Endless = Mods.IsEndless(),
		DailyRun = st:GetAttribute("DailyRun"), Weapons = #(rp.WeaponOrder or {}), Level = rp.Level,
		Revives = rp.RevivesLeft, Items = 0, Difficulty = Mods.DifficultyId(),
	}
	for _ in pairs(rp.Items or {}) do
		info.Items += 1
	end
	check(string.format("%s (%s): daily curses %s replace the player's own, gold x%.2f, DailyRun %s", label, d.Date, join(info.Curses), Mods.GoldMult(), tostring(info.DailyRun)),
		sameList(info.Curses, d.Curses) and near(Mods.GoldMult(), CurseData.GoldMult(d.Curses)) and info.DailyRun == true and not info.Endless and info.Difficulty == "Standard")
	if d.Bonus == "Armory" then
		check(label .. ": Armory bonus gives a second weapon (" .. info.Weapons .. ")", info.Weapons == 2)
	elseif d.Bonus == "Treasure" then
		check(label .. ": Treasure bonus gives two items (" .. info.Items .. ")", info.Items >= 2)
	elseif d.Bonus == "HeadStart" then
		check(label .. ": Head Start reaches level " .. tostring(info.Level), (info.Level or 0) >= CurseData.HeadStartLevel)
	elseif d.Bonus == "SecondWind" and baseRevives then
		check(label .. ": Second Wind revives " .. tostring(info.Revives) .. " = " .. (baseRevives + 1), info.Revives == baseRevives + 1)
		-- a lethal hit spends the extra life instead of ending the run
		protectLevelUps(rp)
		rp.InvulnUntil = 0
		RM.DamagePlayer(rp, 1e6, "curses-sim")
		wait(0.5)
		check(label .. ": a lethal hit uses the extra life (alive " .. tostring(rp.Alive) .. ", left " .. tostring(rp.RevivesLeft) .. ")", rp.Alive == true and rp.RevivesLeft == baseRevives and st:GetAttribute("Phase") == "Running")
	end
	if opts.Dev then
		send("DevCommand", "AddLevels", 2)
		wait(0.5)
	end
	rp.InvulnUntil = math.huge
	wait(opts.Seconds or 3)
	send("AbandonRun")
	wait(1.5)
	info.Result = results[#results] or {}
	return info
end

-- the Second Wind baseline: a plain run's revives
do
	send("StartRun", "Solo")
	wait(1)
	local rp = RM.GetRunPlayer(me)
	baseRevives = rp and rp.RevivesLeft
	send("AbandonRun")
	wait(1.5)
end

local first = dailyRun("today's daily")
data = DS.GetData(me)
if first then
	local r = first.Result.Daily or {}
	check(string.format("first daily of the day is scored: scored %s, result %s %s", tostring(first.Scored), tostring(r.Scored), tostring(r.Text)), first.Scored == true and r.Scored == true and (r.Score or 0) > 0)
	check(string.format("save: Day %s Used %s Score %s Plays %s Best %s", tostring(data.Daily.Day), tostring(data.Daily.Used), tostring(data.Daily.Score), tostring(data.Daily.Plays), tostring(data.Daily.BestScore)),
		data.Daily.Day == realToday and data.Daily.Used == true and data.Daily.Score == r.Score and data.Daily.BestScore >= r.Score and data.Daily.Plays == 1)
end
local firstScore = data.Daily.Score
local practice = dailyRun("practice daily", { Seconds = 6 })
if practice then
	local r = practice.Result.Daily or {}
	check(string.format("second daily is practice: scored %s, result %s, saved score %s unchanged, plays %s", tostring(practice.Scored), tostring(r.Scored), tostring(data.Daily.Score), tostring(data.Daily.Plays)),
		practice.Scored == false and r.Scored == false and data.Daily.Score == firstScore and data.Daily.Plays == 2)
end
check("the player's own curses are kept for normal runs: " .. join(data.Curses), sameList(data.Curses, { "Frenzy", "Horde" }))

-- the Daily board (today's store) holds the first attempt only
wait(8)
for _ = 1, 2 do
	send("LeaderboardRequest", "Daily")
	send("LeaderboardRequest", "Playtime")
	wait(3)
end
local b = boards.Daily
local rows = {}
for _, r in ipairs(b and b.Rows or {}) do
	table.insert(rows, string.format("#%d %s=%d", r.Rank, r.Name, r.Value))
end
preview.log("board Daily", b and b.Status or "none", "day", b and tostring(b.Day) or "-", "myBest", b and tostring(b.MyBest) or "-", table.concat(rows, " "))
check("Daily board: today's scored attempt (" .. tostring(firstScore) .. ")", b and b.Day == realToday and b.Rows[1] and b.Rows[1].Value == firstScore and b.MyBest == firstScore and #b.Rows == 1)

local pt = boards.Playtime
preview.log("board Playtime", pt and pt.Status or "none", "myBest", pt and tostring(pt.MyBest) or "-", "TimePlayed", tostring(data.Stats.TimePlayed), "top", pt and pt.Rows[1] and tostring(pt.Rows[1].Value) or "-")
check("Playtime board: a clean-run total so far, own best = the save", pt and pt.Rows[1] and pt.Rows[1].Value > 0 and pt.Rows[1].Value <= data.Stats.TimePlayed and pt.MyBest == data.Stats.TimePlayed)
-- the newest total waits for the per-board write throttle, then the read cache refresh
wait(Config.Leaderboards.WriteThrottleSeconds + Config.Leaderboards.RefreshSeconds + 2 * Config.Leaderboards.FlushSeconds)
for _ = 1, 2 do
	send("LeaderboardRequest", "Playtime")
	wait(3)
end
pt = boards.Playtime
check("Playtime board after the throttle: " .. tostring(pt and pt.Rows[1] and pt.Rows[1].Value) .. " = " .. tostring(data.Stats.TimePlayed), pt and pt.Rows[1] and pt.Rows[1].Value == data.Stats.TimePlayed)

-- other UTC days: one per starting bonus, then a DEV-tainted day
local wantBonus = { Armory = true, Treasure = true, HeadStart = true, SecondWind = true }
wantBonus[today.Bonus] = nil
local realTodayFn = Mods.Today
local day = realToday + 1
local cursesSeen = {}
for _, id in ipairs(today.Curses) do
	cursesSeen[id] = true
end
while next(wantBonus) and day < realToday + 60 do
	local d = CurseData.Daily(day)
	if wantBonus[d.Bonus] then
		wantBonus[d.Bonus] = nil
		local thisDay = day
		Mods.Today = function()
			return thisDay
		end
		local info = dailyRun("day +" .. (day - realToday) .. " " .. d.Bonus)
		if info then
			local r = info.Result.Daily or {}
			check(string.format("day +%d: a new day resets the attempt (scored %s, save day %s plays %s)", day - realToday, tostring(r.Scored), tostring(data.Daily.Day), tostring(data.Daily.Plays)),
				info.Scored == true and r.Scored == true and data.Daily.Day == day and data.Daily.Plays == 1)
		end
		for _, id in ipairs(d.Curses) do
			cursesSeen[id] = true
		end
	end
	day += 1
end
check("a day for every starting bonus found", next(wantBonus) == nil)
-- a DEV-tainted daily on a fresh day: the attempt is spent, nothing is scored
local devDay = realToday + 100
Mods.Today = function()
	return devDay
end
local best = data.Daily.BestScore
local dev = dailyRun("dev-tainted daily", { Dev = true })
if dev then
	local r = dev.Result
	check(string.format("dev-tainted daily: DevRun %s, no daily line, attempt spent (Used %s), score %s, best unchanged", tostring(r.DevRun), tostring(data.Daily.Used), tostring(data.Daily.Score)),
		r.DevRun == true and r.Daily == nil and data.Daily.Day == devDay and data.Daily.Used == true and data.Daily.Score == 0 and data.Daily.BestScore == best)
end
Mods.Today = realTodayFn

------------------------------------------------------------------------------------------
-- 4. CurseData.Daily over many days
------------------------------------------------------------------------------------------
local bad = 0
for dd = realToday - 30, realToday + 370 do
	local a, a2 = CurseData.Daily(dd), CurseData.Daily(dd)
	local ok = #a.Curses == CurseData.DailyCurseCount and a.Curses[1] ~= a.Curses[2] and sameList(a.Curses, a2.Curses)
		and a.Bonus == a2.Bonus and sameList(a.Arenas, a2.Arenas) and a.Bosses[1] == "ScorpionQueen" and #a.Arenas == CurseData.DailyStages
		and CurseData.Bonuses[a.Bonus] ~= nil
	for _, id in ipairs(a.Curses) do
		ok = ok and CurseData.Curses[id] ~= nil
		cursesSeen[id] = true
	end
	if not ok then
		bad += 1
	end
end
check("CurseData.Daily: 400 days valid and deterministic (" .. bad .. " bad)", bad == 0)
local missing = {}
for _, id in ipairs(CurseData.Order) do
	if not cursesSeen[id] then
		table.insert(missing, id)
	end
end
check("every curse appears in some daily (" .. (#missing == 0 and "all" or join(missing)) .. ")", #missing == 0)

------------------------------------------------------------------------------------------
-- summary
------------------------------------------------------------------------------------------
for _, list in ipairs(sets) do
	local name = join(list)
	preview.log(string.format("CURSE %-32s %s", name, verdict[name] and "OK" or "BAD"))
end
preview.log(fails == 0 and "curses-sim: all checks passed" or ("curses-sim: " .. fails .. " FAILED"))
