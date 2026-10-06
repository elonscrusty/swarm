-- lobby-sweep: every lobby screen in one Lune run, each captured with preview.snapshot
-- as <screen>-<device>.json next to --out (docs/MOBILE_FIX.md). A profile like the
-- owner's (20,927 gold, account LV 7, a used daily, a party with a friend on the server).
--   --set screens=Home,Party,...   only these (default: all below)
--   --set textsize=Medium|Large|Larger|Largest   the Roblox Text size setting (iphone
--                                  defaults to Largest, the owner's phone)
-- Render the PNGs with tools/preview/sweep.sh (it runs this scene and the renderer).
local C = lib("common")
C.lobby()
local ava = preview.addPlayer("VinyLucifer", 2)
preview.addPlayer("MaximilianTheVeryLongName", 7)
C.startClient()
local CurseData = C.shared("CurseData")
local day = CurseData and CurseData.DayOf(os.time()) or 0
C.setState({ DailyDay = day })
local profile = C.profile({
	Gold = 20927,
	Account = { XP = 2350 },
	Title = "Swarmbreaker",
	Ring = "Frost",
	Frame = "Bronze",
	Daily = { Day = day, Used = false, Score = 0, Plays = 0, BestScore = CurseData.DailyScore(4, 801, 900), BestDay = day - 3 },
	Achievements = {
		Progress = { Survivor5 = 300, Survivor10 = 482, QueenSlayer = 1, Veteran = 22, DeepDelver = 2, Reaper = 318 },
		Unlocked = { Survivor5 = 1, QueenSlayer = 1 },
	},
	Journal = { Enemies = { Slime = true, Boss = true }, Drops = { Slime = { XP = true }, Boss = { XP = true, Chest = true } } },
})
profile.Stats.BestStage = 4
profile.LastRun = {
	Won = false, Portal = false, Mode = "Solo", CharacterId = "Knight", Time = 754, Stage = 3, StagesCleared = 2,
	Kills = 1284, Level = 19, Gold = 215, Difficulty = "Standard", DeathCause = "Briar Sentinel",
}
C.sendProfile(profile)
C.fire("PartyState", { LeaderId = 0, Members = {}, Max = 3, Invites = {}, Sent = {} })
ava:SetAttribute("PartyId", nil)
C.settle(2)

local LS = preview.client("LobbyScreen")
local all = {
	"Home", "Play", "Characters", "Upgrades", "Store", "Arenas", "More", "Stats", "Journal", "Curses", "Daily",
	"Ranks", "Track", "Party", "Sigils", "Weekly", "Season", "Titles", "Collection", "Streak", "Settings",
}
local want = all
if preview.args.screens then
	want = string.split(preview.args.screens, ",")
end
for _, name in ipairs(want) do
	if name == "Settings" then
		LS.Show("Home")
		C.settle(1)
		local cog = preview.findGui(function(g)
			return g:IsA("GuiButton") and preview.isShown(g) and (g.Name == "Cog" or g.Name == "Settings" or g.Name == "SETTINGS")
		end)[1] or C.findText("SETTINGS", "GuiButton")
		if cog then
			preview.click(cog)
		else
			preview.warn("lobby-sweep: no settings button")
		end
	elseif name == "Ranks" then
		LS.Show("Ranks")
		C.settle(0.5)
		local rows = {}
		for i, n in ipairs({ "Ava", "Bramblewick", "Kestrel", "Moonpetal", "Ironjaw", "Thistle", "Wren", "Corvid" }) do
			table.insert(rows, { Rank = i, UserId = 2000 + i, Name = n, Value = 98000 - i * 9300, Me = false })
		end
		C.fire("LeaderboardData", { Board = "Score", Rows = rows, Status = "ok", Age = 5, MyRank = 12, MyBest = 11160, Top = 50 })
	else
		local ok, err = pcall(LS.Show, name)
		if not ok then
			preview.warn("lobby-sweep: Show(" .. name .. ") failed: " .. tostring(err))
		end
	end
	C.settle(2.5)
	preview.snapshot(string.lower(name))
	if name == "Settings" then
		-- close the panel again (gamepad B / its close button)
		local close = preview.findGui(function(g)
			return g:IsA("GuiButton") and preview.isShown(g) and (g.Name == "Close" or g.Name == "Back")
		end)
		for _, b in ipairs(close) do
			preview.click(b)
			break
		end
		C.settle(1)
	end
end
LS.Show("Home")
C.settle(1)
