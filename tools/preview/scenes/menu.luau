-- menu: the lobby world at dusk, the lobby home screen, camera at the MenuCamera part.
--   --set save=failing|memory   the server says progress isn't being saved (SaveStatus):
--                               the lobby's save notice
--   --set drag=90               the hero turned by this many degrees (Showcase.Spin, as a drag would)
--   --set drag=input            a real drag over the hero through UserInputService events
--                               (right across the hero; prints whether the press was taken)
--   --set endless=on             the ENDLESS switch is on (player attribute Endless)
--   --set lastrun=won|fell|left  the profile carries a LastRun (the PLAY sheet's LAST RUN card +
--                               RETRY); --set lastmode=Duo its mode; --set retry=on opens the
--                               PLAY sheet, taps RETRY and prints the StartRun the server received
--   --set screen=Play|More|...   open that lobby screen (LobbyScreen.Show) before the shot
--   --set phase=countdown|busy  a DUO countdown (the queue panel replaces PLAY) / a run in progress
--   --set play=tap               taps the home PLAY button (opens the run-setup step), then its
--                               START, and prints the StartRun it sent
--   --set hero=<Id>              that hero selected / on the dais (owned, some mastery XP)
--   --set skin=<SkinId>          the selected hero wears that skin (owned), e.g. GoldTrim
--   --set dots=on                notice dots: gold for a hero + upgrades, the daily not played,
--                               then a second profile with a new achievement and account level;
--                               --set dots=seen also opens HEROES, then MORE's ACHIEVEMENTS row,
--                               and checks those dots cleared (PASS lines)
local C = lib("common")
-- --set hero=Necromancer   the selected (and shown) hero; owned, mastery level 5
local hero = preview.args.hero
C.lobby(hero and { character = hero } or nil)
C.startClient()
local profile = C.profile()
if hero then
	profile.SelectedCharacter = hero
	profile.OwnedCharacters[hero] = true
	profile.Heroes[hero] = profile.Heroes[hero] or { XP = 900, Runs = 14 }
	profile.Skins[hero] = "Default"
end
if preview.args.skin then
	local id = profile.SelectedCharacter or "Knight"
	profile.Skins[id] = preview.args.skin
	profile.OwnedSkins = profile.OwnedSkins or {}
	profile.OwnedSkins[preview.args.skin] = true
end
if preview.args.lastrun then
	local kind = preview.args.lastrun
	profile.LastRun = {
		Won = kind == "won", Portal = kind == "won", Mode = preview.args.lastmode or "Solo", CharacterId = "Knight",
		Time = 754, Stage = kind == "won" and 5 or 3, StagesCleared = kind == "won" and 5 or 2, Kills = 1284, Level = 19,
		Gold = 215, Difficulty = "Standard", DeathCause = kind == "fell" and "Briar Sentinel" or nil,
	}
end
if preview.args.dots == "on" or preview.args.dots == "seen" then
	profile.Gold = 25000
	profile.Daily = { Day = 0, Used = false }
	profile.Achievements = { Progress = {}, Unlocked = {} }
	profile.Account = { XP = 0, Level = 1, Into = 0, Need = 100 }
	C.sendProfile(profile)
	C.settle(0.5)
	profile = table.clone(profile)
	profile.Achievements = { Progress = {}, Unlocked = { QueenSlayer = 1 } }
	profile.Account = { XP = 5000, Level = 6, Into = 0, Need = 100 }
end
C.sendProfile(profile)
-- --set board=rows|empty|error|loading|out|first   the home TOP SCORES panel's High Score
--                               answer (default rows: you are #12; out: not in the top 50;
--                               first: you are #1; none: no answer)
local boardArg = preview.args.board or "rows"
if boardArg ~= "none" then
	local names = { "Ava", "Bramblewick", "Kestrel_TheVeryLongName", "Moonpetal", "Ironjaw", "Thistle", "Pip", "Rook", "Wren", "Fable", "Odo" }
	local rows = {}
	local d = { Board = "Score", Rows = rows, Status = "ok", Age = 5, Top = 50, MyBest = 0 }
	if boardArg == "rows" or boardArg == "out" or boardArg == "first" then
		for i, n in ipairs(names) do
			-- a tie at #4 (shares the rank, as LeaderboardService.RankRows does)
			local v = i == 5 and (98000 - 4 * 8500) or (98000 - i * 8500)
			if i == #names then
				v = 2245 -- the row just above you: "Beat #11 by 36"
			end
			table.insert(rows, { Rank = i == 5 and 4 or i, UserId = 2000 + i, Name = n, Value = v, Me = false })
		end
		if boardArg == "rows" then
			table.insert(rows, { Rank = 12, UserId = 1, Name = "PreviewPlayer", Value = 2210, Me = true })
			d.MyRank, d.MyBoard, d.MyBest = 12, 2210, 2210
		elseif boardArg == "first" then
			rows[1].Name, rows[1].Me, rows[1].UserId = "PreviewPlayer", true, 1
			d.MyRank, d.MyBoard, d.MyBest = 1, rows[1].Value, rows[1].Value
		else
			d.MyBest = 1500
		end
	elseif boardArg == "error" or boardArg == "loading" then
		d.Status = boardArg
	end
	C.fire("LeaderboardData", d)
end
if preview.args.play == "tap" then
	local got = nil
	preview.remote("StartRun").OnServerEvent:Connect(function(_player, mode)
		got = mode
	end)
	C.settle(1)
	local play = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "Play" and preview.isShown(g) end)
	assert(play[1], "the home screen must show the PLAY button")
	preview.click(play[1])
	C.settle(0.5)
	assert(got == nil, "PLAY opens the run-setup step; it must not start a run by itself")
	assert(preview.client("LobbyScreen").Current() == "Play", "PLAY must open the run-setup step")
	local start = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "Start" and preview.isShown(g) end)
	assert(start[1], "the run-setup step must show START")
	preview.click(start[1])
	C.settle(0.3)
	assert(got == "Solo", "START must fire StartRun(Solo) by default, got " .. tostring(got))
	preview.log("PASS PLAY opened the run setup; START fired StartRun(" .. tostring(got) .. ")")
end
if preview.args.retry == "on" or preview.args.screen then
	C.settle(1)
	preview.client("LobbyScreen").Show(preview.args.retry == "on" and "Play" or preview.args.screen)
end
if preview.args.retry == "on" then
	local got = nil
	preview.remote("StartRun").OnServerEvent:Connect(function(_player, mode)
		got = mode
	end)
	C.settle(1)
	local retry = preview.findGui(function(g) return g:IsA("GuiButton") and g.Name == "Retry" and preview.isShown(g) end)
	assert(retry[1], "the PLAY sheet's LAST RUN card must show a RETRY button")
	preview.click(retry[1])
	C.settle(0.5)
	assert(got == (preview.args.lastmode or "Solo"), "RETRY must fire StartRun with the last mode, got " .. tostring(got))
	preview.log("PASS RETRY fired StartRun(" .. tostring(got) .. ")")
end
if preview.args.dots == "seen" then
	local Dots = preview.client("NoticeDots")
	local LS = preview.client("LobbyScreen")
	C.settle(1)
	for _, id in ipairs({ "Heroes", "Shop", "More", "Daily", "Achievements", "Track" }) do
		assert(Dots.Visible(id), "notice dot " .. id .. " must show before it is seen")
	end
	LS.Show("Characters")
	C.settle(0.5)
	LS.Show("Home")
	C.settle(0.5)
	assert(not Dots.Visible("Heroes") and Dots.Visible("Shop"), "HEROES dot clears once HEROES is viewed, SHOP stays")
	LS.Show("More")
	LS.Show("Stats", "Achievements")
	C.settle(0.5)
	assert(not Dots.Visible("More") and not Dots.Visible("Achievements") and Dots.Visible("Daily"), "MORE / ACHIEVEMENTS dots clear when viewed, DAILY row stays")
	C.sendProfile(profile)
	C.settle(0.5)
	assert(not Dots.Visible("Heroes") and not Dots.Visible("More"), "a resync with nothing new keeps seen dots hidden")
	preview.log("PASS notice dots: show, clear when viewed, stay cleared on resync")
	LS.Show("Home")
end
if preview.args.save then
	C.setPlayer({ SaveStatus = preview.args.save })
end
if preview.args.phase == "countdown" then
	C.setState({ Phase = "Countdown", Mode = "Duo", Countdown = 7, Joined = 1, MaxJoin = 2, JoinedNames = "PreviewPlayer" })
elseif preview.args.phase == "busy" then
	C.setState({ Phase = "Running", Mode = "Solo", Stage = 2, RunTime = 312 })
end
if preview.args.endless == "on" then
	C.setPlayer({ Endless = true })
end
C.settle(3)
if preview.args.drag then
	local Showcase = preview.client("Showcase")
	local UIS = game:GetService("UserInputService")
	local cam = workspace.CurrentCamera
	if preview.args.drag == "input" then
		-- press on the hero's middle, drag 150 px right, hold still
		local folder = workspace:FindFirstChild("SwarmShowcase")
		local m = folder and folder:FindFirstChild("ShowcaseHero")
		local p = cam:WorldToViewportPoint((m :: Model):GetPivot().Position)
		local touch = { UserInputType = Enum.UserInputType.Touch, KeyCode = Enum.KeyCode.Unknown, Position = Vector3.new(p.X, p.Y, 0) }
		UIS.InputBegan:_fire(touch, false)
		for i = 1, 10 do
			preview.advance(0.02, 60)
			touch.Position = Vector3.new(p.X + i * 15, p.Y, 0)
			UIS.InputChanged:_fire(touch, false)
		end
		UIS.InputEnded:_fire(touch, false)
		preview.advance(0.05, 60)
		preview.note("simulated drag fired at " .. tostring(p.X) .. "," .. tostring(p.Y))
	else
		Showcase.Spin(tonumber(preview.args.drag) or 0)
		preview.advance(0.1, 60)
	end
end
