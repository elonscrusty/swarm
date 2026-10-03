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
	assert(hasText(screen, "START RANKED"), "ready Daily should name its ranked action")
	assert(hasText(screen, "starts") and hasText(screen, "leave"), "Daily must explain when the try is consumed")
	assert(hasText(screen, "last boss") and hasText(screen, "survival"), "Daily must explain both scoring ties")
	assert(hasText(screen, "1. Play") and hasText(screen, "2. Clear") and hasText(screen, "3. Ties"), "Daily should guide players in three numbered steps")
	profile.Daily.Used = true
	daily.Refresh(profile)
	assert(hasText(screen, "PRACTICE RUN") and hasText(screen, "No leaderboard score"), "practice must be explicit")
	profile.Daily.Day = 19999
	daily.Refresh(profile)
	assert(hasText(screen, "START RANKED"), "previous-day attempt must not block today")
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
end, 8)
assert(ok, tostring(err))
