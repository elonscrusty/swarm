-- daily-quests-regression: daily quests (docs/next/DAILY_QUESTS.md) against the real server.
--   1) pick: deterministic per UTC day, 3 distinct, slot tiers, a pool of 15+, varies by day
--   2) switch off: the Quests remote and the run commit change nothing
--   3) counting: progress from real run fields across two runs, capped at the goal;
--      in-run notices at most one per Config.DailyQuests.ToastGap seconds
--   4) DEV taint: a DevBoosted (tainted) run adds nothing
--   5) claims: refused when not done / unknown / in a run; paid once; the all-three bonus
--      gives the first look once, then nothing more that day
--   6) day rollover: a new UTC day starts empty and yesterday's quests can't be claimed
-- PASS / FAIL lines; any FAIL fails the regression.
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)

local Config = C.shared("Config")
local QuestData = C.shared("QuestData")
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local DQ = preview.server("DailyQuests")

local data = assert(DS.GetData(me), "profile missing")
data.OwnedCharacters = { Knight = true }
data.SelectedCharacter = "Knight"
data.TutorialDone = true
data.FirstRunBonus = true
data.Stats.Runs = 5
data.Gold = 1000
C.startClient()
preview.advance(1)

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end
local notices = {}
preview.remote("Notify").OnClientEvent:Connect(function(d)
	if type(d) == "table" and d.Id == "quest.progress" then
		table.insert(notices, { At = preview.now(), Text = d.Text })
	end
end)
local function send(...)
	preview.remote("Quests"):FireServer(...)
	preview.advance(0.4)
end
local function pickLevels()
	for _ = 1, 40 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
		preview.advance(0.3)
	end
end
local function startSolo()
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(2)
	local rp = RM.GetRunPlayer(me)
	if rp then
		rp.InvulnUntil = 1e9
	end
	return rp
end
local function backToLobby()
	local rp = RM.GetRunPlayer(me)
	if rp then
		RM.AbandonRun(rp)
	end
	preview.advance(Config.Run.ResultsSeconds + 3)
end

------------------------------------------------------------------------------------------
-- 1) the day's pick
------------------------------------------------------------------------------------------
check("pool has 15+ quests", #QuestData.Quests >= 15, tostring(#QuestData.Quests))
local base = 20500
local a, b = QuestData.Pick(base), QuestData.Pick(base)
check("pick is deterministic", #a == 3 and table.concat(a, ",") == table.concat(b, ","), table.concat(a, ","))
local seen = {}
local okTiers, okDistinct = true, true
for d = base, base + 59 do
	local list = QuestData.Pick(d)
	local used = {}
	for i, id in ipairs(list) do
		seen[id] = true
		okTiers = okTiers and QuestData.ById[id].Tier == Config.DailyQuests.Slots[i]
		okDistinct = okDistinct and not used[id]
		used[id] = true
	end
end
local nSeen = 0
for _ in pairs(seen) do
	nSeen += 1
end
check("slots follow their tiers, quests distinct", okTiers and okDistinct)
check("the pick varies over days", nSeen >= 10, tostring(nSeen))

-- a day whose three quests all count from live run fields (and include the kills quest)
local FIELD = { Kills = "Kills", Chests = "ChestsOpened", Gems = "GemsPicked", Ultimates = "UltUses", SecretRooms = "SecretRoomsOpened", Stage = "QuestStage", Time = "QuestTime", Bosses = "QuestBosses", Trials = "TrialsWon", Rescues = "VillagersSaved", Gold = "GoldSpent" }
local day = nil
for d = base, base + 2000 do
	local ok, hasKills = true, false
	for _, id in ipairs(QuestData.Pick(d)) do
		local q = QuestData.ById[id]
		ok = ok and FIELD[q.Metric] ~= nil
		hasKills = hasKills or id == "Kills500"
	end
	if ok and hasKills then
		day = d
		break
	end
end
assert(day, "no test day found")
local now = day * 86400 + 3600
DQ._SetClock(function()
	return now
end)
local picks = QuestData.Pick(day)
preview.log("test day " .. day .. ": " .. table.concat(picks, ","))
local function setRun(rp, frac: number)
	for _, id in ipairs(picks) do
		local q = QuestData.ById[id]
		local field = FIELD[q.Metric]
		local v = math.floor(q.Goal * frac)
		if field == "GoldSpent" then
			v = math.max(0, v - math.floor(rp.Gold or 0))
		end
		rp[field] = math.max(rp[field] or 0, v)
	end
end

------------------------------------------------------------------------------------------
-- 2) switch off
------------------------------------------------------------------------------------------
Config.Features.DailyQuests = false
data.DailyQuests = nil
local rp = assert(startSolo(), "run (off)")
setRun(rp, 1)
backToLobby()
send("Claim", picks[1])
send("ClaimBonus")
check("off: nothing saved, nothing paid", data.DailyQuests == nil and data.Gold >= 1000)
local goldOff = data.Gold
Config.Features.DailyQuests = true

------------------------------------------------------------------------------------------
-- 3) counting across runs + in-run notices
------------------------------------------------------------------------------------------
rp = assert(startSolo(), "run 1")
table.clear(notices)
local killsQuest = QuestData.ById.Kills500
for i = 1, 40 do
	rp.Kills = math.max(rp.Kills, math.floor(killsQuest.Goal * 0.6 * i / 40))
	preview.advance(1)
	pickLevels()
end
local okGap = true
for i = 2, #notices do
	okGap = okGap and (notices[i].At - notices[i - 1].At) >= Config.DailyQuests.ToastGap - 0.05
end
check("in-run notices: at least one, at most one per " .. Config.DailyQuests.ToastGap .. " s", #notices >= 1 and okGap, string.format("%d notices", #notices))
check("live progress is not saved during the run", data.DailyQuests == nil or (data.DailyQuests.Progress or {}).Kills500 == nil)
backToLobby()
local q1 = data.DailyQuests
local after1 = q1 and q1.Progress.Kills500 or -1
check("run 1: kills counted for today", q1 ~= nil and q1.Day == day and after1 >= math.floor(killsQuest.Goal * 0.6) and after1 < killsQuest.Goal, tostring(after1))
rp = assert(startSolo(), "run 2")
rp.Kills = math.floor(killsQuest.Goal * 0.6)
preview.advance(1)
pickLevels()
backToLobby()
check("run 2: progress adds up, capped at the goal", data.DailyQuests.Progress.Kills500 == killsQuest.Goal, tostring(data.DailyQuests.Progress.Kills500))

------------------------------------------------------------------------------------------
-- 4) DEV taint
------------------------------------------------------------------------------------------
local before = {}
for _, id in ipairs(picks) do
	before[id] = data.DailyQuests.Progress[id] or 0
end
data.DevBoosted = true
rp = assert(startSolo(), "tainted run")
check("tainted run flagged", rp.DevTainted == true)
setRun(rp, 1)
preview.advance(1)
pickLevels()
backToLobby()
data.DevBoosted = false
local same = true
for _, id in ipairs(picks) do
	same = same and (data.DailyQuests.Progress[id] or 0) == before[id]
end
check("DEV-tainted run adds no progress", same)

------------------------------------------------------------------------------------------
-- 5) claims
------------------------------------------------------------------------------------------
local notDone = nil
for _, id in ipairs(picks) do
	if (data.DailyQuests.Progress[id] or 0) < QuestData.ById[id].Goal then
		notDone = id
	end
end
local g0 = data.Gold
if notDone then
	send("Claim", notDone)
	check("claim refused while not done", data.Gold == g0 and not data.DailyQuests.Claimed[notDone])
end
send("Claim", "NotAQuest")
send("Claim", 5)
local other = nil
for _, q in ipairs(QuestData.Quests) do
	if not table.find(picks, q.Id) then
		other = q.Id
		break
	end
end
data.DailyQuests.Progress[other] = 99999
send("Claim", other)
check("junk / not-today claims refused", data.Gold == g0 and not data.DailyQuests.Claimed[other])
data.DailyQuests.Progress[other] = nil
-- finish all three with a clean run, then claim
rp = assert(startSolo(), "finishing run")
setRun(rp, 1)
preview.advance(1)
pickLevels()
send("Claim", "Kills500") -- done since run 2: refused only because this is a run
check("claim refused in a run", not data.DailyQuests.Claimed.Kills500)
backToLobby()
local allDone = true
for _, id in ipairs(picks) do
	allDone = allDone and data.DailyQuests.Progress[id] == QuestData.ById[id].Goal
end
check("a clean run finishes all three", allDone)
g0 = data.Gold
send("ClaimBonus")
check("bonus refused before all three are claimed", data.Gold == g0 and not data.DailyQuests.Claimed.Bonus)
send("Claim", picks[1])
send("Claim", picks[1])
check("claim pays once", data.Gold == g0 + QuestData.RewardGold(1) and data.DailyQuests.Claimed[picks[1]] == true, string.format("+%d", data.Gold - g0))
send("Claim", picks[2])
send("Claim", picks[3])
local expect = QuestData.RewardGold(1) + QuestData.RewardGold(2) + QuestData.RewardGold(3)
check("slot rewards 300 / 300 / 600 paid", data.Gold == g0 + expect, string.format("+%d vs %d", data.Gold - g0, expect))
data.Cosmetics.Owned[Config.DailyQuests.BonusCosmetics[1]] = nil
g0 = data.Gold
send("ClaimBonus")
check("bonus gives the first look", data.Cosmetics.Owned[Config.DailyQuests.BonusCosmetics[1]] == true and data.DailyQuests.Claimed.Bonus == true and data.Gold == g0)
send("ClaimBonus")
check("bonus once per day", data.Gold == g0)

------------------------------------------------------------------------------------------
-- 6) day rollover
------------------------------------------------------------------------------------------
now += 86400
g0 = data.Gold
send("Claim", picks[1])
check("new day: yesterday's quests can't be claimed again", data.Gold == g0)
rp = assert(startSolo(), "next-day run")
preview.advance(1)
pickLevels()
backToLobby()
local nextPicks = QuestData.Pick(day + 1)
local fresh = data.DailyQuests.Day == day + 1 and next(data.DailyQuests.Claimed) == nil
for id in pairs(data.DailyQuests.Progress) do
	fresh = fresh and table.find(nextPicks, id) ~= nil
end
check("new day: the save starts over for today", fresh, tostring(data.DailyQuests.Day))
check("goldOff sanity", goldOff >= 1000)

DQ._SetClock(nil)
if fails > 0 then
	error(string.format("daily-quests-regression: %d check(s) failed", fails))
end
preview.log("PASS daily-quests-regression: pick, counting, notices, taint, claims, rollover")
