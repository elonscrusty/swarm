-- meta-regression: the META features (docs/features/META.md) against the real server.
--   1) switches off: no Weekly run, the Meta remote does nothing, Sigils change no stat,
--      the META boards are not served
--   2) Sigils: equip validation (unowned, slot 2 locked until Mastery 3, no duplicates,
--      refused in a run), the stat sheet step (Hare's Foot, Lone Wolf, Ember Heart), Clove
--      Bulb (Garlic + one card fewer on the first offer), Haggler's Coin refund, drops
--      (elite cap per run), kept on a loss by KeepOnLoss, a copy pays gold, Daily ignores
--      Sigils, a DEV-tainted run rolls and commits nothing
--   3) Weekly Challenge: the week's hero and curses, data.Weekly best, the Weekly board
--   4) weekly team board: a Duo run lands on TeamDuo as one team row with both names
--   5) season: claim one tier (cosmetic), claim all (gold), no double claims, locked tiers
--      refused, a season change pays the old unclaimed tiers once
--   6) login streak: once per UTC day, next day +1, one missed day forgiven, two reset,
--      the day-7 title
--   7) titles: a META title can be worn, an unowned one cannot; the Title attribute
--   8) collection: hero played and boss beaten recorded; CollectionData counts
-- PASS / FAIL lines; any FAIL fails the regression.
local C = lib("common")
local Players = game:GetService("Players")
local me = Players.LocalPlayer
local ben = preview.addPlayer("Ben", 3)
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(2)
C.startClient()
preview.advance(1)

local st = C.state()
local Config = C.shared("Config")
local SigilData = C.shared("SigilData")
local MetaData = C.shared("MetaData")
local CurseData = C.shared("CurseData")
local StatSheet = C.shared("StatSheet")
local CollectionData = C.shared("CollectionData")
local Meta = C.shared("MetaUpgradeData")
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local MS = preview.server("MetaService")
local Mods = preview.server("RunModifiers")
local XP = preview.server("XPSystem")
local LB = preview.server("LeaderboardService")
local Events = preview.server("Events")

local fails = 0
local function check(label: string, ok: boolean, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s  %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. detail .. ")") or ""))
end
local boards, offers = {}, {}
preview.remote("LeaderboardData").OnClientEvent:Connect(function(d)
	boards[d.Board] = d
end)
preview.remote("LevelUpOffer").OnClientEvent:Connect(function(d)
	table.insert(offers, d)
end)
local function pickLevels()
	for _ = 1, 40 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1, game:GetService("Players").LocalPlayer:GetAttribute("ChoiceOfferId"))
		preview.advance(0.3)
	end
end
local function send(...)
	preview.remote("Meta"):FireServer(...)
	preview.advance(0.4)
end
local function as(p: Player, remote: string, ...)
	if p == me then
		preview.remote(remote):FireServer(...)
	else
		preview.fireServerAs(p, remote, ...)
	end
	preview.advance(0.4)
end
local function startSolo(mode: string?)
	preview.remote("StartRun"):FireServer(mode or "Solo")
	preview.advance(2)
	local rp = RM.GetRunPlayer(me)
	if rp then
		rp.InvulnUntil = 1e9
	end
	return rp
end
local function leave(p: Player)
	local rp = RM.GetRunPlayer(p)
	if rp then
		RM.AbandonRun(rp)
	end
end
local function backToLobby()
	leave(me)
	leave(ben)
	preview.advance(Config.Run.ResultsSeconds + 3)
end

local data = assert(DS.GetData(me), "profile missing")
-- these checks are about the old heroes: let a run play a hidden one (SwarmV2 RunConfig)
require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Classes.MapLegacyToDefault = false
data.OwnedCharacters = { Knight = true }
data.SelectedCharacter = "Knight"
data.Heroes = { Knight = { XP = 0, Runs = 0 } }
data.Gold = 1000
local today = CurseData.DayOf(os.time())
-- a season that runs now, whatever the machine's date
Config.Season.List = { { Id = "T1", Name = "Test Season", Start = CurseData.DateText(today - 1), End = CurseData.DateText(today + 30) } }

------------------------------------------------------------------------------------------
-- 1) switches off
------------------------------------------------------------------------------------------
local META_FLAGS = { "Sigils", "TeamBoard", "WeeklyChallenge", "SeasonTrack", "Titles", "CollectionBook", "LoginStreak" }
for _, f in ipairs(META_FLAGS) do
	Config.Features[f] = false
end
local goldBefore = data.Gold
send("ClaimStreak")
send("ClaimSeason", "All")
data.Sigils.Owned.HaresFoot = os.time()
send("EquipSigil", 1, "HaresFoot")
check("off: the Meta remote changes nothing", data.Gold == goldBefore and data.LoginStreak.Day == 0 and #data.Sigils.Equipped == 0)
preview.remote("StartRun"):FireServer("Weekly")
preview.advance(1)
check("off: no Weekly run", st:GetAttribute("Phase") == "Lobby" and not RM.IsParticipant(me))
local base = StatSheet.Compute({ CharacterId = "Knight" })
local withSigil = StatSheet.Compute({ CharacterId = "Knight", Sigils = { HaresFoot = true } })
check("off: Sigils change no stat", base.Speed == withSigil.Speed and base.MaxHP == withSigil.MaxHP)
boards.Weekly = nil
preview.remote("LeaderboardRequest"):FireServer("Weekly")
preview.advance(0.5)
check("off: the Weekly board is not served", boards.Weekly == nil)
for _, f in ipairs(META_FLAGS) do
	Config.Features[f] = true
end

------------------------------------------------------------------------------------------
-- 2) Sigils
------------------------------------------------------------------------------------------
data.Sigils.Owned = {}
data.Sigils.Equipped = {}
send("EquipSigil", 1, "HaresFoot")
check("unowned Sigil refused", #data.Sigils.Equipped == 0)
data.Sigils.Owned.HaresFoot = os.time()
data.Sigils.Owned.LoneWolf = os.time()
data.Sigils.Owned.CloveBulb = os.time()
send("EquipSigil", 1, "HaresFoot")
check("owned Sigil worn", data.Sigils.Equipped[1] == "HaresFoot")
send("EquipSigil", 2, "LoneWolf")
check("slot 2 locked below Mastery " .. SigilData.SlotUnlockMastery, #data.Sigils.Equipped == 1)
local xp3 = 0
for l = 1, SigilData.SlotUnlockMastery - 1 do
	xp3 += Meta.MasteryToNext(l)
end
data.Heroes.Knight.XP = xp3
check("Mastery 3 opens slot 2", MS.SigilSlots(data) == 2)
send("EquipSigil", 2, "LoneWolf")
check("slot 2 worn", data.Sigils.Equipped[1] == "HaresFoot" and data.Sigils.Equipped[2] == "LoneWolf")
send("EquipSigil", 2, "HaresFoot")
check("one Sigil never in two slots", #data.Sigils.Equipped == 1 and data.Sigils.Equipped[1] == "HaresFoot", table.concat(data.Sigils.Equipped, ","))
send("EquipSigil", 3, "LoneWolf")
send("EquipSigil", 1, "NotASigil")
send("EquipSigil", "1", "LoneWolf")
check("junk equips ignored", #data.Sigils.Equipped == 1)
send("EquipSigil", 2, "LoneWolf")

-- stat sheet maths (pure)
withSigil = StatSheet.Compute({ CharacterId = "Knight", Sigils = { HaresFoot = true } })
local alone = StatSheet.Compute({ CharacterId = "Knight", Sigils = { LoneWolf = true }, SigilAlone = true })
local crowd = StatSheet.Compute({ CharacterId = "Knight", Sigils = { LoneWolf = true }, SigilAlone = false })
check("Hare's Foot: +15% speed, -10% max HP", math.abs(withSigil.Speed / base.Speed - 1.15) < 1e-6 and withSigil.MaxHP < base.MaxHP, string.format("%.2f/%.2f hp %d/%d", withSigil.Speed, base.Speed, withSigil.MaxHP, base.MaxHP))
check("Lone Wolf: +10% alone, -10% with an ally", math.abs(alone.Might - base.Might - 0.10) < 1e-6 and math.abs(base.Might - crowd.Might - 0.10) < 1e-6)
local ember = StatSheet.Compute({ CharacterId = "Knight", Sigils = { EmberHeart = true }, Items = { HealingHerb = 2 } })
check("Ember Heart: no regen", ember.Regen == 0 and math.abs(ember.Might - base.Might - 0.10) < 1e-6)

-- a run with the worn Sigils
local rp = assert(startSolo(), "solo run")
check("run: worn Sigils applied", rp.Sigils and rp.Sigils.HaresFoot and rp.Sigils.LoneWolf and rp.SigilAlone == true and me:GetAttribute("Sigils") == "HaresFoot,LoneWolf")
check("run: the sheet carries them", math.abs(rp.Stats.Speed / base.Speed - 1.15) < 0.02, string.format("%.2f", rp.Stats.Speed))
send("EquipSigil", 1, "CloveBulb")
check("equip refused in a run", data.Sigils.Equipped[1] == "HaresFoot")
-- elite drops: capped per run
local oldElite = SigilData.EliteChance
SigilData.EliteChance = 1
MS.OnEliteKilled(rp)
MS.OnEliteKilled(rp)
check("elite Sigil: one per run", #rp.SigilFound == 1, tostring(#rp.SigilFound))
SigilData.EliteChance = oldElite
-- Haggler's Coin refund
rp.Sigils.HagglersCoin = true
local escrow, runGold = data.RunEscrow.Gold, rp.Gold
MS.OnGoldPaid(rp, 100)
check("Haggler's Coin pays 10% back", data.RunEscrow.Gold == escrow + 10 and rp.Gold == runGold + 10)
rp.Sigils.HagglersCoin = nil
-- the found Sigil is kept on a loss when KeepOnLoss hits
local foundId = rp.SigilFound[1]
local hadIt = data.Sigils.Owned[foundId] ~= nil
local oldKeep = SigilData.KeepOnLoss
SigilData.KeepOnLoss = 1
local goldPre = data.Gold
preview.advance(3)
backToLobby()
SigilData.KeepOnLoss = oldKeep
if hadIt then
	check("a copy turns into gold", data.Gold >= goldPre + SigilData.DupeGold[SigilData.Sigils[foundId].Rarity], foundId)
else
	check("found Sigil kept (loss, KeepOnLoss = 1)", data.Sigils.Owned[foundId] ~= nil, foundId)
end
-- a duplicate on purpose
SigilData.EliteChance = 1
rp = assert(startSolo(), "solo run 2")
MS.OnEliteKilled(rp)
local dupId = rp.SigilFound[1]
data.Sigils.Owned[dupId] = os.time()
SigilData.KeepOnLoss = 1
goldPre = data.Gold
preview.advance(3)
backToLobby()
SigilData.KeepOnLoss = oldKeep
SigilData.EliteChance = oldElite
check("duplicate pays DupeGold", data.Gold >= goldPre + SigilData.DupeGold[SigilData.Sigils[dupId].Rarity], string.format("%s %d -> %d", dupId, goldPre, data.Gold))
-- found but lost (KeepOnLoss = 0)
SigilData.EliteChance = 1
SigilData.KeepOnLoss = 0
data.Sigils.Owned = { HaresFoot = os.time(), LoneWolf = os.time(), CloveBulb = os.time() }
rp = assert(startSolo(), "solo run 3")
MS.OnEliteKilled(rp)
local lostId = rp.SigilFound[1]
local ownedBefore = data.Sigils.Owned[lostId] ~= nil
preview.advance(3)
backToLobby()
check("lost on a loss when KeepOnLoss misses", (data.Sigils.Owned[lostId] ~= nil) == ownedBefore, lostId)
SigilData.KeepOnLoss = oldKeep
-- Clove Bulb: Garlic at the start, one card fewer on the first offer
send("EquipSigil", 1, "CloveBulb")
table.clear(offers)
rp = assert(startSolo(), "clove run")
check("Clove Bulb: Garlic Aura at the start", rp.Weapons.Garlic ~= nil)
XP.GiveXP(rp, math.max(1, rp.XPNeeded - rp.XP))
preview.advance(0.5)
local first = offers[1]
check("Clove Bulb: first offer one card fewer", first ~= nil and #first.Choices == Config.LevelUp.Choices - 1, first and tostring(#first.Choices) or "no offer")
pickLevels()
XP.GiveXP(rp, math.max(1, rp.XPNeeded - rp.XP))
preview.advance(0.5)
local second = offers[#offers]
check("Clove Bulb: later offers are full", second ~= first and #second.Choices == Config.LevelUp.Choices, tostring(#second.Choices))
pickLevels()
backToLobby()
-- Daily ignores Sigils
rp = assert(startSolo("Daily"), "daily run")
check("Daily: no Sigils", rp.Sigils == nil and rp.Daily == true)
SigilData.EliteChance = 1
MS.OnEliteKilled(rp)
check("Daily: no Sigil drops", #rp.SigilFound == 0)
SigilData.EliteChance = oldElite
backToLobby()
-- DEV-tainted runs roll and commit nothing
data.DevBoosted = true
SigilData.EliteChance = 1
rp = assert(startSolo(), "tainted run")
MS.OnEliteKilled(rp)
check("DEV-tainted: no Sigil roll", rp.DevTainted == true and #rp.SigilFound == 0)
check("DEV-tainted: commit gives nothing", MS.CommitRun(rp, { Won = true, Score = 5000, Cleared = 5, AccountXP = 900 }) == nil)
SigilData.EliteChance = oldElite
backToLobby()
data.DevBoosted = false
preview.log("PASS Sigils")

------------------------------------------------------------------------------------------
-- 3) Weekly Challenge
------------------------------------------------------------------------------------------
local week = MetaData.WeekOf(os.time())
local setup = MetaData.Weekly(week)
check("weekly setup is deterministic", MetaData.Weekly(week).Hero == setup.Hero and table.concat(MetaData.Weekly(week).Curses, ",") == table.concat(setup.Curses, ","))
local seenHeroes = {}
for w = week, week + 60 do
	local s = MetaData.Weekly(w)
	seenHeroes[s.Hero] = true
	assert(#s.Curses == MetaData.WeeklyCurseCount and s.Curses[1] ~= s.Curses[2], "two distinct curses")
end
local nHeroes = 0
for _ in pairs(seenHeroes) do
	nHeroes += 1
end
check("weekly heroes vary over weeks", nHeroes >= 4, tostring(nHeroes))
data.Weekly = { Week = 0, Score = 0, Plays = 0, BestScore = 0, BestWeek = 0 }
rp = assert(startSolo("Weekly"), "weekly run")
check("weekly: the week's hero (lent)", rp.CharacterId == setup.Hero and rp.Weekly == true, rp.CharacterId)
check("weekly: the week's curses", table.concat(Mods.Active(), ",") == table.concat(setup.Curses, ","), table.concat(Mods.Active(), ","))
check("weekly: no Sigils", rp.Sigils == nil)
check("weekly: the selected hero is unchanged", data.SelectedCharacter == "Knight")
preview.advance(20)
pickLevels()
backToLobby()
check("weekly: best recorded", data.Weekly.Week == week and data.Weekly.Plays == 1 and data.Weekly.Score > 0 and data.Weekly.BestScore == data.Weekly.Score, string.format("week %d plays %d score %d", data.Weekly.Week, data.Weekly.Plays, data.Weekly.Score))
preview.advance(LB and Config.Leaderboards.FlushSeconds + 1 or 1)
preview.remote("LeaderboardRequest"):FireServer("Weekly")
preview.advance(1)
local wb = boards.Weekly
check("weekly board answers with my row", wb ~= nil and wb.Week == week and #wb.Rows >= 1 and wb.Rows[1].Me == true and wb.MyBest == data.Weekly.Score, wb and (tostring(wb.Status) .. " rows " .. #wb.Rows) or "no answer")

------------------------------------------------------------------------------------------
-- 4) weekly team board (Duo)
------------------------------------------------------------------------------------------
local benData = assert(DS.GetData(ben), "Ben's profile")
benData.OwnedCharacters = { Knight = true }
benData.SelectedCharacter = "Knight"
as(me, "StartRun", "Duo")
as(ben, "JoinRun")
preview.advance(2)
check("duo run started", RM.IsParticipant(me) and RM.IsParticipant(ben))
local r1, r2 = RM.GetRunPlayer(me), RM.GetRunPlayer(ben)
if r1 then r1.InvulnUntil = 1e9 end
if r2 then r2.InvulnUntil = 1e9 end
preview.advance(20)
pickLevels()
backToLobby()
preview.advance(Config.Leaderboards.FlushSeconds + 1)
preview.remote("LeaderboardRequest"):FireServer("TeamDuo")
preview.advance(1)
local tb = boards.TeamDuo
local row = tb and tb.Rows[1]
check("team board: one row for the team, both named, me in it", row ~= nil and #tb.Rows == 1 and row.Me == true and type(row.Members) == "table" and #row.Members == 2 and string.find(row.Name, "+", 1, true) ~= nil, row and row.Name or "no row")
preview.remote("LeaderboardRequest"):FireServer("TeamTrio")
preview.advance(1)
check("team board: the Trio board is separate (empty)", boards.TeamTrio ~= nil and #boards.TeamTrio.Rows == 0)

------------------------------------------------------------------------------------------
-- 5) season track
------------------------------------------------------------------------------------------
local per = MetaData.SeasonXPPerTier()
data.Season = { Id = "T1", XP = per * 5 + 10, Claimed = {} }
data.Cosmetics.Owned.Nameplate_Ember = nil
send("ClaimSeason", 5)
check("season: tier 5 gives its nameplate", data.Cosmetics.Owned.Nameplate_Ember == true and data.Season.Claimed["5"] == true)
goldBefore = data.Gold
send("ClaimSeason", 5)
check("season: no double claim", data.Gold == goldBefore)
send("ClaimSeason", 6)
check("season: a tier not reached is refused", data.Season.Claimed["6"] == nil and data.Gold == goldBefore)
send("ClaimSeason", "All")
local expect = 0
for t = 1, 4 do
	expect += MetaData.SeasonReward(t).Gold
end
check("season: claim all pays tiers 1-4", data.Gold == goldBefore + expect, string.format("%d vs %d", data.Gold - goldBefore, expect))
send("ClaimSeason", "All")
check("season: claim all twice pays once", data.Gold == goldBefore + expect)
send("ClaimSeason", 0)
send("ClaimSeason", 2.5)
send("ClaimSeason", "x")
check("season: junk claims ignored", data.Gold == goldBefore + expect)
data.Season = { Id = "OLD", XP = per * 2, Claimed = { ["1"] = true } }
goldBefore = data.Gold
send("ClaimSeason", "All")
check("season change: old unclaimed tier paid once, new track", data.Gold == goldBefore + MetaData.SeasonReward(2).Gold and data.Season.Id == "T1" and data.Season.XP == 0, string.format("+%d id %s", data.Gold - goldBefore, data.Season.Id))
-- season XP from a clean run
rp = assert(startSolo(), "season run")
preview.advance(30)
pickLevels()
backToLobby()
check("season: a run adds season XP", data.Season.XP > 0, tostring(data.Season.XP))

------------------------------------------------------------------------------------------
-- 6) login streak
------------------------------------------------------------------------------------------
data.LoginStreak = { Day = 0, LastDay = 0, Best = 0 }
goldBefore = data.Gold
send("ClaimStreak")
check("streak: day 1 paid", data.LoginStreak.Day == 1 and data.LoginStreak.LastDay == today and data.Gold == goldBefore + MetaData.StreakGold(1))
send("ClaimStreak")
check("streak: once per day", data.Gold == goldBefore + MetaData.StreakGold(1))
data.LoginStreak.LastDay = today - 1
send("ClaimStreak")
check("streak: next day +1", data.LoginStreak.Day == 2)
data.LoginStreak.LastDay = today - 2
send("ClaimStreak")
check("streak: one missed day forgiven", data.LoginStreak.Day == 3)
data.LoginStreak.LastDay = today - 3
send("ClaimStreak")
check("streak: two missed days reset", data.LoginStreak.Day == 1 and data.LoginStreak.Best == 3)
data.Title = ""
data.Titles.Owned["Title_Faithful"] = nil
data.LoginStreak = { Day = 6, LastDay = today - 1, Best = 6 }
send("ClaimStreak")
check("streak: day 7 gives the Faithful title (worn when none is)", data.Titles.Owned["Title_Faithful"] == true and data.Title == "Faithful")

------------------------------------------------------------------------------------------
-- 7) titles
------------------------------------------------------------------------------------------
preview.advance(1.5)
check("title attribute published", me:GetAttribute("Title") == "Faithful", tostring(me:GetAttribute("Title")))
preview.remote("EquipCosmetic"):FireServer("Title", "Devoted")
preview.advance(0.4)
check("an unowned META title cannot be worn", data.Title == "Faithful")
preview.remote("EquipCosmetic"):FireServer("Title", "")
preview.advance(0.4)
preview.remote("EquipCosmetic"):FireServer("Title", "Faithful")
preview.advance(0.4)
check("an owned META title can be worn", data.Title == "Faithful")
Config.Features.Titles = false
preview.remote("EquipCosmetic"):FireServer("Title", "")
preview.advance(0.4)
preview.remote("EquipCosmetic"):FireServer("Title", "Faithful")
preview.advance(1.5)
check("Titles off: META title refused, attribute cleared", data.Title == "" and me:GetAttribute("Title") == nil)
Config.Features.Titles = true

------------------------------------------------------------------------------------------
-- 8) collection
------------------------------------------------------------------------------------------
check("collection: the hero played is recorded", data.Collection.Seen["Hero:Knight"] == true and data.Collection.Seen["Hero:" .. setup.Hero] == true)
Events.Fire("BossDefeated", me, { Boss = "HiveMother", Stage = 4 })
check("collection: a beaten boss is recorded", data.Collection.Seen["Boss:HiveMother"] == true and CollectionData.Categories.Bosses.Known(data, "HiveMother"))
local seen, total = CollectionData.Progress(data)
check("collection: counts", total > 50 and seen >= 2 and seen <= total, string.format("%d/%d", seen, total))

if fails > 0 then
	error(string.format("meta-regression: %d check(s) failed", fails))
end
preview.log("PASS meta-regression: Sigils, weekly + team boards, season, streak, titles, collection")
