-- Behavioral checks for preview intent and authoritative discovery/rank data.
local process = require("@lune/process")
local Mock = require("./preview/runtime/mock")
local R, S = Mock.R, Mock.S
local preview = Mock.boot({ device = process.args[1] or "phone", seed = 7, repo = process.cwd, root = process.cwd .. "/tools/preview", fontMetrics = nil })
local failures = 0
local function check(name, good)
	print((good and "PASS " or "FAIL ") .. name)
	if not good then failures += 1 end
end
local ok, err = S.runMain(function()
	preview.startClient(false)
	local remotes = preview.shared("Remotes")
	remotes.Setup()
	local env = R.envFor(nil)
	local screen = env.Instance.new("Frame")
	screen.Size = env.UDim2.fromOffset(1000, 700)
	screen.Parent = preview.playerGui()
	-- the twelve classes, as ClientMain registers them (the 11 old heroes and their skins are
	-- hidden, docs/redesign/DECISIONS.md); a class has Default + the Starter Pack's Gold Trim
	local CharacterData = preview.shared("CharacterData")
	preview.require(env.game:GetService("ReplicatedStorage").SwarmV2.Run.ClassRoster).Register(CharacterData, preview.shared("MetaUpgradeData"))
	local hero = CharacterData.Default
	local p = { Gold = 100, OwnedCharacters = { [hero] = true }, SelectedCharacter = hero, OwnedSkins = {}, Skins = { [hero] = "Default" }, Achievements = { Progress = {} } }
	local host = { VirtualSize = function() return env.Vector2.new(1000, 700) end, IsPortrait = function() return false end, Insets = function() return { Top = 0, Bottom = 0, Left = 0, Right = 0 } end, Scale = function() return 1 end }
	local equips = {}
	remotes.Get("EquipSkin").OnServerEvent:Connect(function(_, character, skin) table.insert(equips, { character, skin }) end)
	preview.client("Showcase").Show = function() end
	local chars = preview.client("MenuCharacters")
	local menu = chars.Build(screen, { Host = host, Profile = function() return p end, Back = function() end, Toast = function() end, Current = function() return "Characters" end })
	menu.OnShow(p)
	check("old hero skins are not offered", screen:FindFirstChild("Knight_Crimson", true) == nil)
	local lockedSkin = screen:FindFirstChild("GoldTrim", true)
	check("the class lists its Gold Trim skin", lockedSkin ~= nil)
	if lockedSkin then lockedSkin.Activated:_fire() end
	preview.advance(0.05)
	check("unowned skin can preview without equip or purchase", #equips == 0 and p.Skins[hero] == "Default")
	p.OwnedSkins.GoldTrim = true
	menu.OnShow(p)
	local swatch = screen:FindFirstChild("GoldTrim", true)
	if swatch then swatch.Activated:_fire() end
	preview.advance(0.05)
	check("owned skin click previews without equipping", swatch ~= nil and #equips == 0 and p.Skins[hero] == "Default")
	local equip
	for _, d in ipairs(screen:GetDescendants()) do
		if d:IsA("TextLabel") and d.Text == "EQUIP SKIN" then
			local ancestor = d.Parent
			while ancestor and not ancestor:IsA("GuiButton") do ancestor = ancestor.Parent end
			equip = ancestor
		end
	end
	check("preview exposes explicit equip action", equip ~= nil)
	if equip then equip.Activated:_fire(); preview.advance(0.05) end
	check("equip sends inspected character and skin once", #equips == 1 and equips[1][1] == hero and equips[1][2] == "GoldTrim")
	local daily = preview.client("MenuDaily")
	if daily.RankText then
		local board = { Board = "Daily", Day = 44, Status = "ok", Age = 0, MyBest = 500, MyRank = 7, Rows = { { Me = true, Rank = 7, Value = 500 } } }
		check("daily rank accepts matching day and score", daily.RankText(board, 44, 500) == "Global rank: #7.")
		check("daily rank rejects yesterday", daily.RankText(board, 45, 500) == nil)
		check("daily rank rejects obsolete personal score", daily.RankText(board, 44, 600) == nil)
		board.Status = "local"
		check("local board never claims global rank", daily.RankText(board, 44, 500) == nil)
		board.Status = "ok"; board.Rows[1].Value = 400
		check("daily rank rejects stale cached row", daily.RankText(board, 44, 500) == nil)
		board.Rows[1].Value = 500; board.Age = 10000
		check("daily rank rejects expired board", daily.RankText(board, 44, 500) == nil)
		board.Age = 59
		check("daily rank expires while screen remains open", daily.RankText(board, 44, 500, 2) == nil)
		board.Age = 0; board.MyRank = nil
		check("missing rank stays unavailable", daily.RankText(board, 44, 500) == nil)
	else check("daily rank validation exists", false) end
	local dailyScreen = env.Instance.new("Frame")
	dailyScreen.Parent = preview.playerGui()
	remotes.State():SetAttribute("DailyDay", 44)
	p.Daily = { Day = 44, Used = true, Score = 500, BestScore = 600, BestDay = 43 }
	local dailyMenu = daily.Build(dailyScreen, { Host = host, Profile = function() return p end, Back = function() end, Toast = function() end, ShowScreen = function() end })
	dailyMenu.OnShow(p)
	local resultText = dailyScreen:FindFirstChild("Info", true):FindFirstChild("Text")
	remotes.Get("LeaderboardData").OnClientEvent:_fire({ Board = "Daily", Day = 44, Status = "ok", Age = 0, MyBest = 500, MyRank = 7, Rows = { { Me = true, Rank = 7, Value = 500 } } })
	preview.advance(0.05)
	check("daily UI displays validated completed result rank", string.find(resultText.Text, "Global rank: #7.", 1, true) ~= nil)
	p.Daily.Score = 700
	dailyMenu.Refresh(p)
	check("profile score update removes old displayed rank", string.find(resultText.Text, "Global rank", 1, true) == nil)
	remotes.Get("LeaderboardData").OnClientEvent:_fire({ Board = "Daily", Day = 43, Status = "ok", Age = 0, MyBest = 700, MyRank = 1, Rows = { { Me = true, Rank = 1, Value = 700 } } })
	preview.advance(0.05)
	check("yesterday response never repaints today's rank", string.find(resultText.Text, "Global rank", 1, true) == nil)
	local journal = preview.shared("EnemyJournalData")
	local unknown = journal.Entry({}, "Slime")
	check("undiscovered enemy conceals name and drops", unknown.Name == "Undiscovered enemy" and #unknown.Drops == 0)
	local known = journal.Entry({ Journal = { Enemies = { Slime = true }, Drops = { Slime = { XP = true, Gold = false, Chest = true, Invented = true } } } }, "Slime")
	check("journal shows only observed whitelisted drops", #known.Drops == 2 and known.Drops[1] == "XP gems" and known.Drops[2] == "Chest")
	check("discovered enemy exposes manual attack clue", known.Name == "Mite" and #known.Clue > 0)
	local journalScreen = env.Instance.new("Frame")
	journalScreen.Parent = preview.playerGui()
	local journalMenu = preview.client("MenuJournal").Build(journalScreen, { Host = host, Profile = function() return { Journal = { Enemies = { Slime = true }, Drops = { Slime = { XP = true } } } } end, Back = function() end })
	journalMenu.OnShow()
	local slime = journalScreen:FindFirstChild("Slime", true)
	local bat = journalScreen:FindFirstChild("Bat", true)
	check("journal UI conceals undiscovered attack and drops", bat.EnemyName.Text == "Undiscovered enemy" and bat.ObservedDrops.Visible == false and not string.find(bat.AttackClue.Text, "Wasp"))
	check("journal UI renders only recorded drops", slime.ObservedDrops.Text == "Observed drops: XP gems")
	local lowestUnknown = math.huge
	for _, row in ipairs(slime.Parent:GetChildren()) do
		if row:IsA("Frame") and row ~= slime then
			lowestUnknown = math.min(lowestUnknown, row.LayoutOrder)
		end
	end
	check("journal UI lists discovered entries before unknown placeholders", slime.LayoutOrder < lowestUnknown)
end, 10)
assert(ok, err)
assert(#R.log.errors == 0, "mock runtime errors")
assert(failures == 0, tostring(failures) .. " menu regressions")
