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
	assert(hasText(screen, "PLAY DAILY") and hasText(screen, "Scored attempt"), "ready Daily should name its scored action")
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

	-- the home screen ("One big PLAY"): only the logo, gold + cog, the hero pill, the
	-- HEROES / SHOP / MORE tiles, PLAY and its mode selector; PLAY starts SOLO in one tap,
	-- the selector opens the PLAY sheet, BACK from CURSES returns to it, MORE lists the rest
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
	profile.Skins = {}
	profile.Heroes = { Knight = { XP = 0, Runs = 0 } }
	profile.TutorialDone = true
	profile.Stats.Runs = 3
	profile.Curses = {}
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
	local allowed = { Play = true, ModeSelect = true, Heroes = true, Shop = true, More = true, Prev = true, Next = true, Open = true, HitPad = true }
	local extra = {}
	for _, d in ipairs(home:GetDescendants()) do
		if d:IsA("GuiButton") and shown(d) and not allowed[d.Name] then
			table.insert(extra, d.Name)
		end
	end
	assert(#extra == 0, "home shows only PLAY, the mode selector, the hero pill and three tiles; also: " .. table.concat(extra, ", "))
	for _, name in ipairs({ "Play", "ModeSelect", "Heroes", "Shop", "More" }) do
		local b = home:FindFirstChild(name, true)
		assert(b and shown(b), "home must show " .. name)
	end
	local cog = root:FindFirstChild("SettingsCog", true)
	assert(cog and shown(cog), "home must show the settings cog")
	local started = nil
	Remotes.Get("StartRun").OnServerEvent:Connect(function(_, mode) started = mode end)
	home:FindFirstChild("Play", true).Activated:_fire()
	preview.advance(0.1)
	assert(started == "Solo", "PLAY starts SOLO in one tap, got " .. tostring(started))
	home:FindFirstChild("ModeSelect", true).Activated:_fire()
	preview.advance(0.4)
	assert(Lobby.Current() == "Play", "the mode selector opens the PLAY sheet")
	local sheet = root:FindFirstChild("Play", true)
	sheet:FindFirstChild("Duo", true).Activated:_fire()
	preview.advance(0.1)
	assert(preview.client("MenuPlay").Mode() == "Duo", "picking DUO on the sheet sets the mode")
	Lobby.Show("Curses")
	preview.advance(0.3)
	root:FindFirstChild("Curses", true):FindFirstChild("Back", true).Activated:_fire()
	preview.advance(0.3)
	assert(Lobby.Current() == "Play", "BACK from CURSES returns to the PLAY sheet")
	Lobby.Show("Home")
	preview.advance(0.3)
	assert(hasText(home, "DUO"), "the selector shows the picked mode")
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
	print("PASS home: one PLAY, three tiles, PLAY sheet and MORE list", device)
end, 8)
assert(ok, tostring(err))
