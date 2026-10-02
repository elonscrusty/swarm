-- endless-sim: boots the REAL server and plays an ENDLESS solo run (Config.Endless) through
-- the remotes past the normal last stage, then checks the boards. Run it with --studio
-- (the last part uses a DEV command): render.sh endless-sim --studio --devices pc
--   1. SetEndless validation (non-boolean ignored), the switch on the countdown (Duo).
--   2. An Endless solo run: every stage is cleared WITHOUT dev commands (server calls:
--      StageManager.DevActivate, boss / surge kills) so the run stays untainted; per stage
--      it prints arena, boss, the difficulty multipliers and the boss's max HP, and checks
--      that the portal offer is NEXT-only and a "Return" choice is refused.
--   3. The run ends from the pause menu (AbandonRun): the result, the save (BestScoreEndless,
--      BestLevel, Wins unchanged), then a Standard run (defeat), a dev-tainted Endless run
--      (nothing recorded) and a Daily start with the switch on (never Endless).
--   4. The boards: Score, ScoreEndless, Level, BestStage, Kills (LeaderboardData answers).
-- --set stages=N (default 12) how deep the Endless run goes.
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
	for _ = 1, 30 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
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
local Spawner = preview.server("EnemySpawner")
local Stage = preview.server("StageManager")
local RM = preview.server("RunManager")
local Mods = preview.server("RunModifiers")
local DS = preview.server("DataService")
local results, offers, boards = {}, {}, {}
preview.remote("RunResult").OnClientEvent:Connect(function(d)
	table.insert(results, d)
end)
preview.remote("PortalOffer").OnClientEvent:Connect(function(d)
	if not d.Close and not d.Chosen then
		table.insert(offers, d)
	end
end)
preview.remote("LeaderboardData").OnClientEvent:Connect(function(d)
	boards[d.Board] = d
end)
local function check(label, ok)
	preview.log((ok and "PASS " or "FAIL ") .. label)
end

-- the documented formula (Config.Endless) on top of the Standard per-stage curve
local E = Config.Endless
local S = Config.Stages
preview.log(string.format("Config.Endless: from stage %d, HP +%.2f, dmg +%.2f, bossHP +%.2f, spawn +%.2f (cap x%.2f), max %d extra stages", E.LastNormalStage, E.HPPerStage, E.DamagePerStage, E.BossHPPerStage, E.SpawnPerStage, E.SpawnMultCap, E.MaxExtraStages))
for _, n in ipairs({ 1, 5, 6, 10, 15, 20, 35, 50 }) do
	local extra = math.clamp(n - E.LastNormalStage, 0, E.MaxExtraStages)
	local list = S.BossHPByStage
	local bossStd = n <= #list and list[n] or (list[#list] + (n - #list) * S.BossHPPerExtraStage)
	preview.log(string.format("  formula stage %2d: std HP x%.2f dmg x%.2f spawn x%.2f boss x%.2f | endless HP x%.2f dmg x%.2f spawn x%.2f boss x%.2f",
		n, 1 + S.EnemyHPPerStage * (n - 1), 1 + S.EnemyDamagePerStage * (n - 1), 1 + S.SpawnTargetPerStage * (n - 1), bossStd,
		(1 + S.EnemyHPPerStage * (n - 1)) * (1 + E.HPPerStage * extra), (1 + S.EnemyDamagePerStage * (n - 1)) * (1 + E.DamagePerStage * extra),
		(1 + S.SpawnTargetPerStage * (n - 1)) * math.min(1 + E.SpawnPerStage * extra, E.SpawnMultCap), bossStd * (1 + E.BossHPPerStage * extra)))
end

-- 1. the switch
send("SetEndless", "yes")
send("SetEndless", 1)
check("non-boolean SetEndless ignored (attr " .. tostring(me:GetAttribute("Endless")) .. ")", me:GetAttribute("Endless") ~= true)
send("SetEndless", true)
local data = DS.GetData(me)
check("SetEndless(true): attr " .. tostring(me:GetAttribute("Endless")) .. " save " .. tostring(data and data.Endless), me:GetAttribute("Endless") == true and data and data.Endless == true)
send("StartRun", "Duo")
wait(0.6)
check("countdown shows Endless (Phase " .. tostring(st:GetAttribute("Phase")) .. ", Endless " .. tostring(st:GetAttribute("Endless")) .. ")", st:GetAttribute("Phase") == "Countdown" and st:GetAttribute("Endless") == true)
wait(Config.Run.CountdownSeconds or 12)
wait(2)
-- the countdown ran out with one player: a run started (or the lobby came back)
if st:GetAttribute("Phase") == "Running" then
	local r = RM.GetRunPlayer(me)
	check("Duo countdown run is Endless", Mods.IsEndless() and r and r.Endless == true)
	send("AbandonRun")
	wait(1)
end
wait(1)

-- 2. the Endless solo run
local bestBefore = data and data.Stats.BestScore or 0
local winsBefore = data and data.Stats.Wins or 0
send("StartRun", "Solo")
wait(2)
local rp = RM.GetRunPlayer(me)
check("Solo run is Endless: IsEndless " .. tostring(Mods.IsEndless()) .. " rp.Endless " .. tostring(rp and rp.Endless) .. " state " .. tostring(st:GetAttribute("Endless")), Mods.IsEndless() and rp and rp.Endless == true and st:GetAttribute("Endless") == true)
local stages = tonumber(preview.args.stages) or 12
local refusedOk, nextOnly = true, true
local function protect()
	rp = RM.GetRunPlayer(me)
	if rp then
		rp.InvulnUntil = math.huge
	end
end
local function clearStage(n)
	local bossHP = 0
	for _ = 1, 60 do
		protect()
		local sub = st:GetAttribute("StagePhase")
		if (st:GetAttribute("Stage") or 0) > n then
			break
		end
		if sub == "Explore" then
			Stage.DevActivate()
			if Spawner.Boss then
				bossHP = math.floor(Spawner.Boss.MaxHP)
			end
		elseif sub == "Boss" then
			if Spawner.Boss then
				bossHP = math.max(bossHP, math.floor(Spawner.Boss.MaxHP))
				Spawner.Damage(Spawner.Boss, 1e12, rp)
			end
		elseif sub == "Surge" then
			for _, e in ipairs(table.clone(Spawner.Active)) do
				Spawner.Kill(e, rp)
			end
		elseif sub == "Open" then
			local o = offers[#offers]
			if o and (o.Endless ~= true or o.CountsAsWin == true or (o.ReturnBonus or 0) ~= 0) then
				nextOnly = false
			end
			send("PortalChoice", "Return")
			if not RM.GetRunPlayer(me) or st:GetAttribute("Phase") ~= "Running" then
				refusedOk = false
				return bossHP
			end
			send("PortalChoice", "Next")
		end
		wait(0.6)
	end
	return bossHP
end
for n = 1, stages do
	protect()
	wait(3) -- a few seconds of the stage: regular spawning at this stage's target
	local live = #Spawner.Active
	local line = string.format("stage %2d %-8s boss %-15s extra %2d | HP x%.2f dmg x%.2f spawn x%.2f bossHP x%.2f | live %3d (MaxLive %d) | pill %s",
		n, tostring(st:GetAttribute("StageArena")), tostring(st:GetAttribute("StageBoss")), Mods.EndlessStage(n),
		Stage.EnemyHPMult(), Stage.DamageMult(), Stage.SpawnMult(), Stage.BossHPMult(), live, Config.Enemies.MaxLive,
		(st:GetAttribute("Endless") and "ENDLESS · STAGE " or "STAGE ") .. tostring(st:GetAttribute("Stage")))
	local bossHP = clearStage(n)
	preview.log(line .. string.format(" | boss max HP %d", bossHP))
	if st:GetAttribute("Phase") ~= "Running" then
		break
	end
end
check("portal offers were NEXT-only (Endless, no win, no return bonus)", nextOnly and #offers > 0)
check("RETURN refused in Endless (still running on stage " .. tostring(st:GetAttribute("Stage")) .. ")", refusedOk and st:GetAttribute("Phase") == "Running")
check("reached stage " .. tostring(st:GetAttribute("Stage")) .. " > LastNormalStage", (st:GetAttribute("Stage") or 0) > E.LastNormalStage)
protect()
local levelNow = rp and rp.Level or 0
send("AbandonRun")
wait(1.5)
local d = results[#results] or {}
preview.log("result", "Endless", tostring(d.Endless), "Won", tostring(d.Won), "Abandoned", tostring(d.Abandoned), "Stage", tostring(d.Stage), "Cleared", tostring(d.StagesCleared), "Score", tostring(d.Score), "Board", tostring(d.ScoreBoard), "Level", tostring(d.Level), "Arena", tostring(d.Arena), "DevRun", tostring(d.DevRun))
check("result is an Endless loss on ScoreEndless", d.Endless == true and d.Won == false and d.ScoreBoard == "ScoreEndless" and type(d.Score) == "number")
data = DS.GetData(me)
if data then
	preview.log("save", "BestScore", data.Stats.BestScore, "BestScoreEndless", data.Stats.BestScoreEndless, "BestLevel", data.Stats.BestLevel, "BestStage", data.Stats.BestStage, "Wins", data.Stats.Wins, "Endless", tostring(data.Endless))
	check("save: BestScoreEndless = result score, BestScore and Wins untouched, BestLevel " .. levelNow, data.Stats.BestScoreEndless == d.Score and data.Stats.BestScore == bestBefore and data.Stats.Wins == winsBefore and data.Stats.BestLevel == levelNow)
end

-- 3b. a Standard run (defeat): the "Score" board
send("SetEndless", false)
send("StartRun", "Solo")
wait(2)
check("Standard run: IsEndless false, state Endless " .. tostring(st:GetAttribute("Endless")), not Mods.IsEndless() and st:GetAttribute("Endless") == false)
protect()
for _ = 1, 3 do
	for _, e in ipairs(table.clone(Spawner.Active)) do
		Spawner.Kill(e, rp)
	end
	wait(2)
end
RM.EndRun(false)
wait(1)
local d2 = results[#results] or {}
preview.log("standard result", "Endless", tostring(d2.Endless), "Score", tostring(d2.Score), "Board", tostring(d2.ScoreBoard))
check("Standard run scored on Score", d2.ScoreBoard == "Score" and d2.Endless == false)
wait(Config.Run.ResultsSeconds + 2)

-- 3c. a dev-tainted Endless run: nothing recorded
send("SetEndless", true)
local snapshot = data and table.clone(data.Stats) or {}
send("StartRun", "Solo")
wait(2)
send("DevCommand", "AddLevels", 30)
wait(1)
send("AbandonRun")
wait(1.5)
local d3 = results[#results] or {}
data = DS.GetData(me)
check("dev-tainted Endless run: DevRun " .. tostring(d3.DevRun) .. ", no score, bests unchanged", d3.DevRun == true and d3.Score == nil and data and data.Stats.BestLevel == snapshot.BestLevel and data.Stats.BestScoreEndless == snapshot.BestScoreEndless)

-- 3d. the Daily Challenge never runs Endless (the switch stays on)
send("StartRun", "Daily")
wait(2)
check("Daily with the switch on: IsEndless " .. tostring(Mods.IsEndless()), st:GetAttribute("Phase") == "Running" and not Mods.IsEndless() and st:GetAttribute("Endless") == false)
send("AbandonRun")
wait(1.5)

-- 4. the boards (the writes flush on a timer, then the reads)
wait(8)
local ids = { "Score", "ScoreEndless", "Level", "BestStage", "Kills" }
for _, id in ipairs(ids) do
	send("LeaderboardRequest", id)
end
wait(3)
for _, id in ipairs(ids) do
	send("LeaderboardRequest", id)
end
wait(1)
for _, id in ipairs(ids) do
	local b = boards[id]
	local rows = {}
	for _, r in ipairs(b and b.Rows or {}) do
		table.insert(rows, string.format("#%d %s=%d%s", r.Rank, r.Name, r.Value, r.Me and "(me)" or ""))
	end
	preview.log("board", id, "status", b and b.Status or "none", "myRank", b and tostring(b.MyRank) or "-", "myBest", b and tostring(b.MyBest) or "-", table.concat(rows, " "))
end
local se, sc, lv = boards.ScoreEndless, boards.Score, boards.Level
check("ScoreEndless board holds the Endless score", se and se.Rows[1] and se.Rows[1].Value == d.Score and se.MyBest == d.Score)
check("Score board holds the Standard score only", sc and sc.Rows[1] and sc.Rows[1].Value == d2.Score)
check("Level board: the best untainted level", lv and lv.Rows[1] and lv.Rows[1].Value == math.max(levelNow, d2.Level or 0) and lv.MyBest == (data and data.Stats.BestLevel))
