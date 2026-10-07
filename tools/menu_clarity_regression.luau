local process = require("@lune/process")
local Mock = require("./preview/runtime/mock")
local R, S = Mock.R, Mock.S
local device = process.args[1] or "phone"
local preview = Mock.boot({ device = device, seed = 7, repo = process.cwd, root = process.cwd .. "/tools/preview", fontMetrics = nil })
local ok, err = S.runMain(function()
	preview.startClient(false)
	local env = R.envFor(nil)
	local Remotes = preview.shared("Remotes")
	Remotes.Setup()
	Remotes.State():SetAttribute("DailyDay", 20000)
	local profile = { Daily = { Day = 20000, Used = false }, Achievements = { Unlocked = { Survivor5 = 1 }, Progress = { Survivor10 = 480 } }, Account = { XP = 0 }, Title = "", NameColor = "", Stats = { BestTime = 0, Wins = 0, Runs = 0, TotalKills = 0 }, Gold = 0, OwnedCharacters = {}, Meta = {} }
	local gui = env.Instance.new("ScreenGui")
	gui.Parent = preview.playerGui()
	local screen = env.Instance.new("Frame")
	screen.Size = env.UDim2.fromOffset(800, 600)
	screen.Parent = gui
	local portrait = device == "phone-portrait"
	local size = portrait and env.Vector2.new(420, 900) or env.Vector2.new(1000, 500)
	local host = { VirtualSize = function() return size end, IsPortrait = function() return portrait end, Insets = function() return { Top = 0, Bottom = 0, Left = 0, Right = 0 } end }
	local ctx = { Host = host, Profile = function() return profile end, Back = function() end, Toast = function() end, ShowScreen = function() end }
	local daily = preview.client("MenuDaily").Build(screen, ctx)
	daily.Refresh(profile)
	local function hasText(root, fragment)
		for _, child in ipairs(root:GetDescendants()) do
			if child:IsA("TextLabel") and string.find(child.Text, fragment, 1, true) then return true end
		end
		return false
	end
	-- the button subtitle was shortened to fit phones (cb71f89): "Scored · 1 try today"
	assert(hasText(screen, "PLAY DAILY") and hasText(screen, "Scored"), "ready Daily should name its scored action")
	assert(hasText(screen, "starts") and hasText(screen, "leave"), "Daily must explain when the try is consumed")
	assert(hasText(screen, "last boss") and hasText(screen, "survival"), "Daily must explain both scoring ties")
	assert(hasText(screen, "1. Play") and hasText(screen, "2. Clear") and hasText(screen, "3. Ties"), "Daily should guide players in three numbered steps")
	profile.Daily.Used = true
	daily.Refresh(profile)
	assert(hasText(screen, "PRACTICE RUN") and hasText(screen, "No leaderboard score"), "practice must be explicit")
	profile.Daily.Day = 19999
	daily.Refresh(profile)
	assert(hasText(screen, "PLAY DAILY"), "previous-day attempt must not block today")
	screen:Destroy()
	screen = env.Instance.new("Frame")
	screen.Size = env.UDim2.fromOffset(size.X, size.Y)
	screen.Parent = gui
	local stats = preview.client("MenuStats").Build(screen, ctx)
	stats.Layout(size, portrait, host.Insets())
	stats.OnShow(profile)
	for _, child in ipairs(screen:GetDescendants()) do
		if child:IsA("TextLabel") and child.Text == "ACHIEVEMENTS" then
			local parent = child.Parent
			while parent and not parent:IsA("GuiButton") do parent = parent.Parent end
			if parent then parent.Activated:_fire() break end
		end
	end
	preview.advance(0.2)
	local ach = screen:FindFirstChild("AchievementsScroll", true)
	assert(ach and ach.Visible, "achievements tab should open")
	local pending, completed = ach:FindFirstChild("Survivor10"), ach:FindFirstChild("Survivor5")
	assert(pending and completed and pending.LayoutOrder < completed.LayoutOrder, "unfinished goals must precede completed achievements")
	assert(pending.LayoutOrder < ach.QueenSlayer.LayoutOrder and ach.QueenSlayer.LayoutOrder < ach.Conqueror.LayoutOrder, "closest goals lead, tied goals keep definition order")
	assert(hasText(ach, "automatically") and hasText(ach, "COMPLETED"), "rewards and completed group need plain labels")
	assert(hasText(pending, "8:00 / 10:00"), "progress should stay visible in the goal card")
	for _, child in ipairs(ach:GetDescendants()) do
		if child:IsA("GuiButton") and child.Text == "WEAR REWARDS" then child.Activated:_fire() break end
	end
	preview.advance(0.1)
	assert(ach.CanvasPosition.Y > 0, "wear rewards action must jump to the cosmetic controls")
	print("PASS Daily ranked/practice/reset rules and actionable achievement grouping", device)

	-- the title screen (overhaul 01_Title): logo + hero caption, PLAY (opens the run-setup
	-- step), the account pill, PARTY, CHARACTERS / SHOP / WORLDS / DAILY, MORE and the cog;
	-- BACK returns to where a screen was opened from; MORE lists the rest
	local Showcase = preview.client("Showcase")
	Showcase.Show = function() end
	Showcase.SetRing = function() end
	local root = env.Instance.new("Frame")
	root.Size = env.UDim2.fromOffset(size.X, size.Y)
	root.Parent = gui
	local fx = env.Instance.new("ScreenGui")
	fx.Parent = preview.playerGui()
	local relayouts = {}
	local lobbyHost = {
		Root = root, FxGui = fx, VirtualSize = host.VirtualSize, IsPortrait = host.IsPortrait, Insets = host.Insets,
		Scale = function() return 1 end, OnRelayout = function(fn) table.insert(relayouts, fn) end,
		OpenSettings = function() end, Toast = function() end,
	}
	local Lobby = preview.client("LobbyScreen")
	Lobby.Init(lobbyHost)
	profile.OwnedCharacters = { Knight = true }
	profile.SelectedCharacter = "Knight"
	profile.Skins = { Knight = "GoldTrim" }
	profile.OwnedSkins = { GoldTrim = true }
	profile.Heroes = { Knight = { XP = 0, Runs = 0 } }
	profile.TutorialDone = true
	profile.Stats.Runs = 3
	profile.Curses = {}
	profile.Gold = 16743
	Lobby.SetVisible(true)
	Lobby.SetProfile(profile)
	Lobby.Update(0.1)
	preview.advance(0.5)
	local home = root:FindFirstChild("Home", true)
	local function shown(obj)
		local o = obj
		while o and o ~= root do
			if o:IsA("GuiObject") and not o.Visible then return false end
			o = o.Parent
		end
		return true
	end
	local allowed = { Play = true, HeroCaption = true, AccountPill = true, PartyButton = true, Characters = true, Shop = true, Worlds = true, Daily = true, More = true, HitPad = true, HomeBoard = true, QuestChip = true } -- HomeBoard: TOP SCORES (owner 2026-10-07); QuestChip: "Quests 1/3" (DailyQuests, docs/next)
	local extra = {}
	for _, d in ipairs(home:GetDescendants()) do
		if d:IsA("GuiButton") and shown(d) and not allowed[d.Name] then
			table.insert(extra, d.Name)
		end
	end
	assert(#extra == 0, "home shows only PLAY, the caption, the account pill, PARTY, TOP SCORES, the bottom row and MORE; also: " .. table.concat(extra, ", "))
	for _, name in ipairs({ "Play", "HeroCaption", "AccountPill", "PartyButton", "Characters", "Shop", "Worlds", "Daily", "More" }) do
		local b = home:FindFirstChild(name, true)
		assert(b and shown(b), "home must show " .. name)
	end
	local cog = root:FindFirstChild("SettingsCog", true)
	assert(cog and shown(cog), "home must show the settings cog")
	local caption = home:FindFirstChild("HeroCaption", true)
	assert(hasText(caption, "K N I G H T") and hasText(caption, "G O L D   T R I M"), "the caption names the selected hero and its equipped skin")
	assert(hasText(home:FindFirstChild("AccountPill", true), "LV 1") and hasText(home:FindFirstChild("AccountPill", true), "16,743"), "the account pill shows the account level and the gold")
	assert(hasText(home, "Choose your mode next."), "PLAY says the mode comes next")
	local started = nil
	Remotes.Get("StartRun").OnServerEvent:Connect(function(_, mode) started = mode end)
	home:FindFirstChild("Play", true).Activated:_fire()
	preview.advance(0.4)
	assert(Lobby.Current() == "Play" and started == nil, "PLAY opens the run-setup step without starting")
	local sheet = root.Lobby.Screens.Play
	for _, name in ipairs({ "Solo", "Duo", "Trio", "Hero", "Arena", "Difficulty", "Curses", "EndlessRow", "Daily", "Start" }) do
		local b = sheet:FindFirstChild(name, true)
		assert(b, "the run-setup step must have " .. name)
	end
	assert(hasText(sheet, "HERO · KNIGHT") and hasText(sheet, "Gold Trim"), "the run-setup step names the hero and skin")
	assert(hasText(sheet, "One scored try") and hasText(sheet, "resets in"), "the Daily row discloses the scored try and the reset")
	assert(hasText(sheet, "Just you"), "the rule line explains SOLO")
	sheet:FindFirstChild("Start", true).Activated:_fire()
	preview.advance(0.3)
	assert(started == "Solo", "START starts SOLO, got " .. tostring(started))
	Lobby.Show("Play")
	preview.advance(0.3)
	sheet:FindFirstChild("Duo", true).Activated:_fire()
	preview.advance(0.1)
	assert(preview.client("MenuPlay").Mode() == "Duo", "picking DUO on the sheet sets the mode")
	assert(hasText(sheet, "countdown"), "the rule line explains a DUO countdown")
	sheet:FindFirstChild("Arena", true).Activated:_fire()
	preview.advance(0.3)
	assert(Lobby.Current() == "Arenas", "the WORLD row opens the worlds")
	root.Lobby.Screens.Arenas:FindFirstChild("Back", true).Activated:_fire()
	preview.advance(0.3)
	assert(Lobby.Current() == "Play", "BACK from WORLDS opened on the sheet returns to the sheet")
	Lobby.Show("Curses")
	preview.advance(0.3)
	root:FindFirstChild("Curses", true):FindFirstChild("Back", true).Activated:_fire()
	preview.advance(0.3)
	assert(Lobby.Current() == "Play", "BACK from CURSES returns to the PLAY sheet")
	root.Lobby.Screens.Play:FindFirstChild("Back", true).Activated:_fire()
	preview.advance(0.3)
	assert(Lobby.Current() == "Home", "BACK from the sheet returns home")
	assert(hasText(home, "DUO"), "the line under PLAY shows the picked mode")
	local routes = { Worlds = "Arenas", Daily = "Daily", PartyButton = "Party", AccountPill = "Track", Characters = "Characters", Shop = "Upgrades", HeroCaption = "Characters" }
	for button, screenName in pairs(routes) do
		Lobby.Show("Home")
		preview.advance(0.3)
		home:FindFirstChild(button, true).Activated:_fire()
		preview.advance(0.3)
		assert(Lobby.Current() == screenName, button .. " opens " .. screenName .. ", got " .. Lobby.Current())
		if screenName == "Arenas" or screenName == "Daily" or screenName == "Party" or screenName == "Track" then
			root.Lobby.Screens[screenName]:FindFirstChild("Back", true).Activated:_fire()
			preview.advance(0.3)
			assert(Lobby.Current() == "Home", "BACK from " .. screenName .. " opened on home returns home, got " .. Lobby.Current())
		end
	end
	Lobby.Show("Home")
	preview.advance(0.3)
	home:FindFirstChild("More", true).Activated:_fire()
	preview.advance(0.4)
	assert(Lobby.Current() == "More", "MORE opens the list")
	local more = root.Lobby.Screens.More
	for _, name in ipairs({ "Daily", "Party", "Ranks", "Stats", "Track", "Journal", "Achievements", "Settings", "BugReport" }) do
		local b = more:FindFirstChild(name, true)
		assert(b and shown(b), "MORE must list " .. name)
	end
	more:FindFirstChild("Achievements", true).Activated:_fire()
	preview.advance(0.4)
	assert(Lobby.Current() == "Stats", "ACHIEVEMENTS opens the stats screen")
	root.Lobby.Screens.Stats:FindFirstChild("Back", true).Activated:_fire()
	preview.advance(0.3)
	assert(Lobby.Current() == "More", "BACK from STATS opened in MORE returns to MORE")
	print("PASS title home: PLAY -> run setup, caption, account pill, party, bottom row, MORE, back routes", device)
end, 20)
assert(ok, tostring(err))
