-- journey-regression (audit 2026-10-05, docs/audit/JOURNEY.md): combinations of the run's
-- interruptions on the REAL server (solo, headless), checked against the server state:
--   A  levels banked when the stage-clear dialog opens: no panel over the dialog
--      (ChoiceDeferred "Portal"), none during the travel ("Travel"), one panel after it,
--      no level lost
--   B  a panel already open when the portal opens: the dialog's countdown stops while the
--      solo choice freezes the world, and runs again after the pick
--   C  several rare rewards queued: one hold, never longer than Config.Chests.RewardPauseMax
--      even if the client never answers; a stale RewardClose keeps the hold, the latest
--      one ends it
--   D  a rare reward with levels banked: the panel waits for the reward (no stacked
--      blocking panels), then opens once
--   E  lethal damage during a reward hold: nothing lands while frozen; after the hold the
--      hero falls, the run ends once, no panel or hold is left behind
--   F  restart after a victory (WinMinStages forced to 1): the next run starts clean
--      (stage 1, Explore, no offer / hold / deferral / portal state, fresh run player,
--      no enemies or frozen flag carried over)
--   G  (SEC-15) a DEV command by a player outside the run does not taint it; one by a
--      run player does
-- Lune sim, NOT Studio. Prints PASS / FAIL lines; any FAIL fails tools/run_regressions.py.
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local Config = preview.shared("Config")
-- G: a second player on the same server who never joins the run (a dev in Studio)
local watcher = preview.addPlayer("Watcher", 2)
preview.startServer()
preview.advance(1)
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local LUS = preview.server("LevelUpSystem")
local Spawner = preview.server("EnemySpawner")
local st = game:GetService("ReplicatedStorage"):WaitForChild("SwarmState")

local fails = 0
local function check(cond: any, label: string)
	if cond then
		preview.log("PASS " .. label)
	else
		fails += 1
		preview.log("FAIL " .. label)
	end
end

local results = 0
local lastResult: any = nil
preview.remote("RunResult").OnClientEvent:Connect(function(data)
	results += 1
	lastResult = data
end)
local DS = preview.server("DataService")

local function start()
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(1.5)
	local rp = assert(RM.GetRunPlayer(me), "a run player")
	LUS.Cancel(rp) -- no first-level noise
	rp.InvulnUntil = math.huge
	return rp
end

-- boss → surge → Open, without the DEV taint (DevActivate is what pacing-sim uses)
local function clearStage(rp, pick: boolean?)
	for _ = 1, 120 do
		local sub = SM.GetPhase()
		if sub == "Open" then
			return true
		elseif sub == "Explore" then
			SM.DevActivate()
		elseif sub == "Boss" and Spawner.Boss then
			Spawner.Damage(Spawner.Boss, 1e9, rp)
		elseif sub == "Surge" then
			for _, e in ipairs(table.clone(Spawner.Active)) do
				Spawner.Kill(e, rp)
			end
		end
		if pick and rp.Offer then
			LUS.Cancel(rp, true)
		end
		preview.advance(0.5)
	end
	return SM.GetPhase() == "Open"
end

local rp = start()
local stage0 = SM.GetStage()

-- A) levels banked as the stage-clear dialog opens
check(clearStage(rp, true), "A stage 1 reaches the open portal")
preview.advance(0.3)
check(rp.PortalOffered == true, "A the stage-clear dialog is offered")
local before = rp.PendingLevels
LUS.QueueLevels(rp, 2)
preview.advance(0.5)
check(rp.Offer == nil and not rp.Paused, "A no level-up panel opens over the stage-clear dialog")
check(me:GetAttribute("ChoiceDeferred") == "Portal", "A deferral says Portal (got " .. tostring(me:GetAttribute("ChoiceDeferred")) .. ")")
check(rp.PendingLevels >= before + 2, "A banked levels kept while the dialog is up (" .. tostring(before) .. " -> " .. tostring(rp.PendingLevels) .. ", portal vacuum XP adds more)")
preview.fireServerAs(me, "PortalChoice", "Next")
local sawTravelPanel, sawTravel = false, false
for _ = 1, 30 do
	preview.advance(0.1)
	if SM.IsHolding() then
		sawTravel = true
		if rp.Offer then
			sawTravelPanel = true
		end
	end
end
check(sawTravel, "A NEXT STAGE starts the travel")
check(not sawTravelPanel, "A no panel opens during the travel fade")
check(SM.GetStage() == stage0 + 1, "A stage 2 reached")
check(rp.Offer ~= nil and rp.Paused, "A the banked levels open one panel after the travel")
check((rp.BatchTotal or 0) >= 2, "A the panel carries both banked levels")
local panelId, banked = rp.PanelId, rp.PendingLevels
local picks = 0
for _ = 1, 40 do
	if not rp.Offer then
		break
	end
	preview.fireServerAs(me, "LevelUpChoose", 1, rp.OfferSeq)
	picks += 1
	preview.advance(0.1)
end
check(rp.Offer == nil and rp.PendingLevels == 0 and picks >= banked, string.format("A every banked level resolved by a pick (%d banked, %d picks, %d panels)", banked, picks, rp.PanelId - panelId + 1))

-- B) a panel open when the portal opens: the dialog countdown stops while choosing (solo)
local okB = clearStage(rp, true)
check(okB, "B stage 2 reaches the open portal (stage " .. SM.GetStage() .. " " .. SM.GetPhase() .. ", frozen " .. tostring(RM.IsFrozen()) .. ", offer " .. tostring(rp.Offer ~= nil) .. ")")
-- reopen on a fresh clear is not possible here; open a panel now (solo freezes the world)
-- and check the dialog clock
preview.advance(0.3)
local left0 = st:GetAttribute("ChoiceLeft")
-- the dialog defers new panels; force one open the way a panel already open before the
-- portal behaves: the offer survives (only the solo freeze matters for the countdown)
rp.PortalOffered = false
LUS.QueueLevels(rp, 1)
local opened = rp.Offer ~= nil
rp.PortalOffered = true
check(opened and RM.IsFrozen(), "B a solo panel freezes the world over the open portal")
preview.advance(3)
check(st:GetAttribute("ChoiceLeft") == left0, "B the stage-clear countdown waits while the solo choice is open (" .. tostring(left0) .. " -> " .. tostring(st:GetAttribute("ChoiceLeft")) .. ")")
preview.fireServerAs(me, "LevelUpChoose", 1, rp.OfferSeq)
preview.advance(2.2)
check(not RM.IsFrozen() and (st:GetAttribute("ChoiceLeft") or 99) < left0, "B after the pick the countdown runs again")
-- leave through NEXT for the next checks
preview.fireServerAs(me, "PortalChoice", "Next")
preview.advance(3)
LUS.Cancel(rp)

-- C) several rare rewards queued: one bounded hold
local C = Config.Chests
RM.HoldReward(rp, true)
local t0 = os.clock()
RM.HoldReward(rp, true)
RM.HoldReward(rp, true)
check(RM.IsFrozen(), "C a rare reward freezes the solo run")
check(rp.RewardUntil and rp.RewardUntil - t0 <= C.RewardPauseMax + 0.01, "C three queued rewards stay inside RewardPauseMax")
preview.fireServerAs(me, "RewardClose", rp.RewardSeq - 1)
preview.advance(0.2)
check(rp.RewardUntil ~= nil, "C a close that has not seen the latest reward keeps the hold")
local frozenFor = 0
while RM.IsFrozen() and frozenFor < 15 do
	preview.advance(0.1)
	frozenFor += 0.1
end
check(frozenFor <= C.RewardPauseMax + 0.3, string.format("C a silent client is released by the server in %.1fs (max %.1f)", frozenFor + 0.3, C.RewardPauseMax))
RM.HoldReward(rp, true)
preview.fireServerAs(me, "RewardClose", rp.RewardSeq)
preview.advance(0.2)
check(rp.RewardUntil == nil and not RM.IsFrozen(), "C the latest close ends the hold at once")
preview.advance(2)

-- D) a rare reward with levels banked: sequenced, not stacked
RM.HoldReward(rp, true)
LUS.QueueLevels(rp, 1)
preview.advance(0.3)
check(rp.Offer == nil, "D no level-up panel while the reward reveal holds")
preview.fireServerAs(me, "RewardClose", rp.RewardSeq)
preview.advance(0.3)
check(rp.Offer ~= nil and rp.Paused, "D the panel opens right after the reveal")
local pid = rp.PanelId
preview.fireServerAs(me, "LevelUpChoose", 1, rp.OfferSeq)
preview.advance(0.3)
check(rp.Offer == nil and rp.PanelId == pid, "D one panel for the banked level")
preview.advance(2)

-- E) lethal damage during a reward hold
rp.InvulnUntil = 0
rp.RevivesLeft = 0
rp.Items = rp.Items or {}
rp.ProductReviveUsed = true
local hp = rp.HP
-- J-09: an old personal best of 1 point: this run's result must say NEW BEST SCORE
DS.GetData(me).Stats.BestScore = 1
RM.HoldReward(rp, true)
RM.DamagePlayer(rp, 1e9, "Test")
check(rp.HP == hp and rp.Alive, "E no damage lands during the solo reward hold")
local r0 = results
for _ = 1, 100 do
	if not rp.RewardUntil then
		break
	end
	preview.advance(0.1)
end
preview.advance((Config.Player.ChoiceGraceSeconds or 0) + 0.2)
for _ = 1, 3 do
	RM.DamagePlayer(rp, 1e9, "Test")
end
preview.advance(0.5)
check(not rp.Alive, "E after the hold and its grace the hero can fall")
check(results == r0 + 1, "E the run ends with one result (" .. tostring(results - r0) .. ")")
check(rp.Offer == nil and not RM.IsFrozen(), "E no panel or freeze left after the defeat")
check(lastResult and lastResult.NewBestScore == true and (lastResult.Score or 0) > 1, "E (J-09) beating the saved best score sets NewBestScore (score " .. tostring(lastResult and lastResult.Score) .. ")")

-- back to the lobby
preview.fireServerAs(me, "ReturnToLobby")
preview.advance(1)

-- F) restart after a victory
Config.Stages.WinMinStages = 1
rp = start()
check(clearStage(rp, true), "F stage 1 reaches the open portal")
preview.advance(0.5)
LUS.QueueLevels(rp, 3) -- banked levels at the win must not leak into the next run
RM.HoldReward(rp, false)
DS.GetData(me).Stats.BestScore = 1e12 -- J-09: a best this run cannot beat
r0 = results
preview.fireServerAs(me, "PortalChoice", "Return")
preview.advance(1)
check(results == r0 + 1, "F the victory sends one result")
check(lastResult and lastResult.Won == true and lastResult.NewBestScore ~= true, "F (J-09) a score under the saved best is not called a new best")
check(st:GetAttribute("Phase") == "Lobby" and me:GetAttribute("InRun") ~= true, "F back in the lobby after the win")
local old = rp
rp = start()
check(rp ~= old, "F a fresh run player")
check(SM.GetStage() == 1 and SM.GetPhase() == "Explore", "F the new run starts at stage 1 Explore")
check(rp.PendingLevels == 0 and rp.Offer == nil and rp.RewardUntil == nil and not rp.PortalOffered and not rp.PortalChoice, "F no levels, offer, hold or portal state carried over")
check(me:GetAttribute("ChoiceDeferred") == nil and me:GetAttribute("ChoiceOpen") ~= true and (me:GetAttribute("PendingUpgrades") or 0) == 0, "F choice attributes clean")
check(not RM.IsFrozen() and st:GetAttribute("Frozen") ~= true and (st:GetAttribute("ChoiceLeft") or 0) == 0, "F no freeze or stage-clear countdown carried over")
check(rp.Level == 1 and rp.Gold == 0 and rp.Kills == 0, "F level 1, no gold, no kills")
local bossLeft = false
for _, e in ipairs(Spawner.Active) do
	if e.Boss then
		bossLeft = true
	end
end
check(not bossLeft, "F no boss carried over")
preview.advance(3)
check(RM.GetRunTime() > 1, "F the new run's clock runs")

-- G) SEC-15: a DEV command from someone outside the run does not taint it; one from a
-- player in the run does (every Studio player counts as a dev)
check(not RM.IsParticipant(watcher) and not RM.IsDevTainted(me), "G a clean run, the watcher is not in it")
preview.fireServerAs(watcher, "DevCommand", "DamageNumbers")
preview.advance(0.3)
check(not RM.IsDevTainted(me), "G a DEV command from outside the run leaves it untainted")
preview.fireServerAs(me, "DevCommand", "DamageNumbers")
preview.advance(0.3)
check(RM.IsDevTainted(me), "G a DEV command from a run player taints the run")

preview.log(fails == 0 and "journey-regression: ALL PASS" or ("journey-regression: " .. fails .. " FAIL"))
