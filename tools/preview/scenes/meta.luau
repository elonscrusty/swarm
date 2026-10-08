-- meta: the META lobby screens (docs/features/META.md) with a sample profile, for screenshots
-- and the phone layout checks (check_layout.py):
--   --set screen=Sigils|Weekly|Season|Titles|Collection|Streak|Quests|Comeback|Play|More   (default Sigils)
--   --set tab=Bosses|Weapons|...  (Collection: the category; Weekly: TeamDuo / TeamTrio)
--   --set empty=on                a brand-new profile (nothing found, nothing claimed)
local C = lib("common")
C.lobby()
C.startClient()
local CurseData = C.shared("CurseData")
local MetaData = C.shared("MetaData")
local Config = C.shared("Config")
local now = os.time()
local today = CurseData.DayOf(now)
local week = MetaData.WeekOf(now)
-- a season that runs now, whatever the machine's date
Config.Season.List = { { Id = "T1", Name = "Season 1", Start = CurseData.DateText(today - 10), End = CurseData.DateText(today + 80) } }
local empty = preview.args.empty == "on"
local screen = preview.args.screen or "Sigils"
local p = C.profile()
p.Heroes.Knight.XP = 2000 -- Mastery 3+: both Sigil slots
p.Title = empty and "" or "Faithful"
p.Achievements = { Progress = {}, Unlocked = empty and {} or { QueenSlayer = 1 } }
p.Account = { XP = empty and 0 or 2400 }
p.Journal = { Enemies = empty and {} or { Mite = true, Wasp = true, BeetleWarrior = true, ScorpionQueen = true }, Drops = {} }
p.Discovered = { Weapons = empty and {} or { Whip = true, Garlic = true, MagicOrb = true }, Passives = empty and {} or { Might = true }, Items = empty and {} or { Whetstone = true } }
p.Features = {
	Sigils = { Owned = empty and {} or { HaresFoot = now, Lodestar = now, LoneWolf = now }, Equipped = empty and {} or { "HaresFoot", "LoneWolf" } },
	Weekly = { Week = week, Score = empty and 0 or 4210, Plays = 2, BestScore = empty and 0 or 6120, BestWeek = week - 1 },
	Season = { Id = "T1", XP = empty and 0 or 2650, Claimed = empty and {} or { ["1"] = true, ["2"] = true } },
	Titles = { Owned = empty and {} or { ["Title_Faithful"] = true } },
	Collection = { Seen = empty and {} or { ["Hero:Knight"] = true, ["Boss:HiveMother"] = true } },
	LoginStreak = { Day = empty and 0 or 4, LastDay = empty and 0 or today - 1, Best = empty and 0 or 9 },
	Cosmetics = { Owned = empty and {} or { Nameplate_Ember = true }, Equipped = { Nameplate = empty and "" or "Nameplate_Ember" } },
	-- next batch: daily quests (first one done, one claimed) and a waiting comeback gift
	DailyQuests = (not empty) and (function()
		local picks = C.shared("QuestData").Pick(today)
		local q1, q2 = C.shared("QuestData").ById[picks[1]], C.shared("QuestData").ById[picks[2]]
		return { Day = today, Progress = { [picks[1]] = q1.Goal, [picks[2]] = q2.Goal, [picks[3]] = 0 }, Claimed = { [picks[2]] = true } }
	end)() or nil,
	Comeback = { LastGift = now, Pending = (not empty and screen == "Comeback") and { Days = 8, Gold = 1000, Look = "Trail_Homecoming" } or nil },
}
C.sendProfile(p)
C.settle(1)
preview.client("LobbyScreen").Show(screen, preview.args.tab)
C.settle(1)
if screen == "Weekly" then
	local rows = {}
	for i, n in ipairs({ "Ava", "Bramblewick", "Kestrel", "Moonpetal", "Ironjaw", "Thistle" }) do
		table.insert(rows, { Rank = i, UserId = 2000 + i, Name = (preview.args.tab or "Weekly") == "Weekly" and n or (n .. " + Kestrel"), Value = 9000 - i * 700, Me = i == 3 })
	end
	C.fire("LeaderboardData", { Board = preview.args.tab or "Weekly", Week = week, Rows = rows, Status = "ok", Age = 5, MyRank = 3, MyBest = 4210, Top = 50 })
	C.settle(0.5)
end
if screen == "Collection" and preview.args.tab then
	local tab = preview.findGui(function(g)
		return g:IsA("GuiButton") and string.upper(g.Text) == string.upper(preview.args.tab) and preview.isShown(g)
	end)
	if tab[1] then
		preview.click(tab[1])
		C.settle(0.5)
	end
end
assert(preview.client("LobbyScreen").Current() == screen, "the screen must open: " .. screen)
preview.log("PASS meta screen " .. screen .. " opened")
