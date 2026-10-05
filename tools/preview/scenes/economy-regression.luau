-- economy-regression: audit 2026-10-05 (docs/audit/ECONOMY.md). The real LeaderboardService on
-- the mock OrderedDataStores (global mode, --studio = the Studio_ prefix stores), plus
-- NextGoal's difficulty card. Prints PASS / FAIL per check.
--   EC-A01 ties share a rank (1, 2, 2, 4) and your rank is the shared one
--   EC-A02 a lower later run never lowers a board; one run id is submitted once per board
--   EC-A03 a player's row reads the same name while on this server and after leaving; an
--          off-server id gets one name lookup, not "Player <id>" forever
--   EC-A04 a failed read: status "error", the last good rows kept, Age = their real age,
--          no re-read before RefreshSeconds
--   EC-A05 NextGoal: "5 / 5 stages" with the tier still locked now says what is missing
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ava = preview.addPlayer("Ava", 7001)
preview.startServer()
preview.advance(2)
local LB = preview.server("LeaderboardService")
local DS = preview.server("DataService")
local Remotes = preview.shared("Remotes")
local Config = preview.shared("Config")
local NextGoal = preview.shared("NextGoal")
local L = Config.Leaderboards

local fails = 0
local function check(label: string, ok: boolean, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

-- every LeaderboardData answer, per player
local answers: { [any]: { any } } = {}
local origFire = Remotes.FireClient
Remotes.FireClient = function(name, p, payload, ...)
	if name == "LeaderboardData" then
		answers[p] = answers[p] or {}
		table.insert(answers[p], payload)
	end
	return origFire(name, p, payload, ...)
end
local function ask(p, board: string)
	answers[p] = {}
	preview.fireServerAs(p, "LeaderboardRequest", board)
	preview.advance(0.5)
	local list = answers[p]
	return list[#list]
end

check("global boards available (mock OrderedDataStore)", LB.IsAvailable() == true)

------------------------------------------------------------------------------------------
-- EC-A01 ties
------------------------------------------------------------------------------------------
do
	local ranks = LB.RankRows({ { UserId = 1, Value = 9 }, { UserId = 2, Value = 7 }, { UserId = 3, Value = 7 }, { UserId = 4, Value = 5 }, { UserId = 5, Value = 5 }, { UserId = 6, Value = 5 }, { UserId = 7, Value = 1 } })
	check("RankRows 1,2,2,4,4,4,7", table.concat(ranks, ",") == "1,2,2,4,4,4,7", table.concat(ranks, ","))
	local offline = { UserId = 9001 }
	LB.Submit(offline :: any, "BestStage", 6, nil, "runX")
	LB.Submit(me, "BestStage", 4, nil, "runMe1")
	LB.Submit(ava, "BestStage", 4, nil, "runAva1")
	preview.advance(L.FlushSeconds + 2)
	local d = ask(me, "BestStage")
	local rows = d and d.Rows or {}
	local got = {}
	for _, r in ipairs(rows) do
		table.insert(got, string.format("%s=%d#%d", tostring(r.UserId), r.Value, r.Rank))
	end
	check("BestStage answer is global (ok)", d ~= nil and d.Status == "ok", d and d.Status)
	check("three rows written", #rows == 3, table.concat(got, " "))
	check("leader #1, tied players both #2", #rows == 3 and rows[1].Rank == 1 and rows[2].Rank == 2 and rows[3].Rank == 2, table.concat(got, " "))
	check("my rank is the shared #2", d ~= nil and d.MyRank == 2 and d.MyBoard == 4, d and tostring(d.MyRank))
end

------------------------------------------------------------------------------------------
-- EC-A02 best-score semantics
------------------------------------------------------------------------------------------
do
	LB.Submit(me, "Score", 5000, nil, "r1")
	preview.advance(L.WriteThrottleSeconds + L.FlushSeconds + 2)
	LB.Submit(me, "Score", 3000, nil, "r2") -- a worse later run
	LB.Submit(me, "Score", 99999, nil, "r1") -- the same run again (must be ignored)
	preview.advance(L.WriteThrottleSeconds + L.FlushSeconds + 2)
	preview.advance(L.RefreshSeconds + 1)
	local d = ask(me, "Score")
	check("board keeps the best value (5000)", d ~= nil and d.MyBoard == 5000, d and tostring(d.MyBoard))
	check("one run id is submitted once", d ~= nil and d.MyBoard ~= 99999)
	check("nothing left queued", d ~= nil and d.MyQueued == nil, d and tostring(d.MyQueued))
end

------------------------------------------------------------------------------------------
-- EC-A03 names
------------------------------------------------------------------------------------------
do
	preview.advance(L.RefreshSeconds + 1)
	local d = ask(me, "BestStage")
	local function nameIn(answer, uid)
		for _, r in ipairs(answer and answer.Rows or {}) do
			if r.UserId == uid then
				return r.Name
			end
		end
		return nil
	end
	check("on-server row = display name", nameIn(d, ava.UserId) == ava.DisplayName, nameIn(d, ava.UserId))
	preview.advance(1)
	local d2 = ask(me, "BestStage")
	local off = nameIn(d2, 9001)
	check("off-server id resolved after one lookup", off ~= nil and off ~= "Player 9001", off)
	preview.removePlayer(ava)
	preview.advance(1)
	local d3 = ask(me, "BestStage")
	check("same name after the player left", nameIn(d3, ava.UserId) == ava.DisplayName, nameIn(d3, ava.UserId))
end

------------------------------------------------------------------------------------------
-- EC-A04 read failure
------------------------------------------------------------------------------------------
do
	-- the watched board is re-read in the background every RefreshSeconds: fail the store
	-- first, so that background read is the one that fails
	preview.failDataStores(true, false)
	preview.advance(L.RefreshSeconds + 1)
	local d = ask(me, "BestStage")
	check("failed read -> status error", d ~= nil and d.Status == "error", d and d.Status)
	check("last good rows kept", d ~= nil and #d.Rows == 3, d and #d.Rows)
	check("age = age of the kept rows (> RefreshSeconds)", d ~= nil and d.Age >= L.RefreshSeconds, d and d.Age)
	preview.failDataStores(false, false)
	preview.advance(2)
	local d2 = ask(me, "BestStage")
	check("no re-read right after a failure", d2 ~= nil and d2.Status == "error", d2 and d2.Status)
	preview.advance(L.RefreshSeconds + 1)
	local d3 = ask(me, "BestStage")
	check("re-read after RefreshSeconds -> ok", d3 ~= nil and d3.Status == "ok" and d3.Age < L.FlushSeconds + 2, d3 and (d3.Status .. " age " .. d3.Age))
end

------------------------------------------------------------------------------------------
-- EC-A05 NextGoal difficulty card
------------------------------------------------------------------------------------------
do
	local function goalFor(bestStage: number)
		-- only the difficulty candidate can win: every hero owned, mastery maxed, daily used
		local owned = {}
		for id in pairs(preview.shared("CharacterData").Characters) do
			owned[id] = true
		end
		local data = {
			Gold = 0, OwnedCharacters = owned, Stats = { BestStage = bestStage, Runs = 10 },
			Daily = { Day = preview.shared("CurseData").DayOf(os.time()), Used = true },
			DifficultyClears = {},
		}
		return NextGoal.Pick(data, {})
	end
	local g = goalFor(6) -- reached stage 6, never returned through the portal
	check("cleared 5, not won: no '5 / 5' bar", g ~= nil and g.Kind == "Difficulty" and g.ProgressText ~= "Best: 5 / 5 stages", g and g.ProgressText)
	check("cleared 5, not won: says what is missing", g ~= nil and type(g.Sub) == "string" and string.find(g.Sub, "portal", 1, true) ~= nil, g and g.Sub)
	local g2 = goalFor(3) -- reached stage 3 = cleared 2
	check("reached 3: 'Best: 2 / 5 stages'", g2 ~= nil and g2.ProgressText == "Best: 2 / 5 stages", g2 and g2.ProgressText)
end

preview.log(fails == 0 and "ALL PASS" or (fails .. " FAIL"))
