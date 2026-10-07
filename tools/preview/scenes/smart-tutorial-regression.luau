-- smart-tutorial-regression: the SmartTutorial tips (client Tutorial.lua + TutorialBubble.lua,
-- Config.Features.SmartTutorial, docs/next/SMART_TUTORIAL.md). A first-run profile walks the
-- seven steps on their own events: Move (until the hero walked 10 studs), Attack (first
-- kill), Gems (a gem near the hero; done when XP moves), LevelUp (the line under LEVEL UP!),
-- Chest (a ready chest within 12 studs; done when it opens), Portal (after the reveal; done
-- when the charge starts), Boss (the boss phase). Also: one tip at a time, each shown once,
-- the bubble sits above the ability tray and hides behind a panel, a finished tutorial
-- (TutorialDone, or TutorialStep = 2) shows nothing, a second tutorial run still shows tips.
-- Prints PASS / FAIL lines. Registered as a layout check on iphone, phone-portrait and pc
-- (the final frame shows the Move bubble for check_layout).
local A = lib("arena")
local C = lib("common")
local Players = game:GetService("Players")
-- the world folders the client waits for (no swarm in this scene)
for _, name in ipairs({ "SwarmEnemies", "SwarmPickups", "SwarmGems", "SwarmLoot" }) do
	if not workspace:FindFirstChild(name) then
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = workspace
	end
end
local s = A.build({ enemies = 0, swarm = false, seconds = 20, stage = 1, stagePhase = "Explore", lockLeft = 0 })
C.settle(1)
local Config = C.shared("Config")
local Tutorial = preview.client("Tutorial")
local Hud = preview.client("Hud")
local UIState = preview.client("UIState")
local me = Players.LocalPlayer
local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
check(Config.Features.SmartTutorial == true, "SmartTutorial switch on by default")

-- every id that reaches the screen, in order (a repeat is a FAIL)
local shownLog: { string } = {}
local last: string? = nil
local function poll()
	local id = Tutorial.Current()
	if id and id ~= last then
		table.insert(shownLog, id)
	end
	last = id
end
local function step(seconds: number)
	local t = 0
	while t < seconds do
		preview.advance(0.1, 10)
		t += 0.1
		poll()
	end
end
local function waitFor(id: string?, maxSeconds: number): boolean
	local t = 0
	while t < maxSeconds do
		if Tutorial.Current() == id then
			return true
		end
		preview.advance(0.1, 10)
		t += 0.1
		poll()
	end
	return Tutorial.Current() == id
end

local settings = { Music = 0.6, Sfx = 0.8, Shake = 1, ReducedEffects = false, DamageNumbers = false, Tips = true }
local function newRun(profile: { [string]: any })
	C.sendProfile(C.profile(profile))
	C.settle(0.2)
	C.setPlayer({ InRun = false, Kills = 0, Level = 1, XP = 0 })
	preview.advance(0.1)
	C.setState({ StagePhase = "Explore", PortalHint = false, PortalReveal = 0, PortalCharge = 0, BossHP = 0, BossMaxHP = 0 })
	C.setPlayer({ InRun = true })
	preview.advance(0.2)
	last = nil
end
local firstProfile = { TutorialDone = false, TutorialStep = 0, SeenTips = {}, Settings = settings, Stats = { BestTime = 0, TotalKills = 0, Wins = 0, Runs = 1, BestStage = 0 } }
newRun(firstProfile)

local function hero(): Model?
	return me.Character
end
local function els()
	return Tutorial.Elements().Bubble or {}
end

-- 1 Move (the stage-start card shows first: wait for it)
check(waitFor("Move", 15), "1 Move shows at the run start")
local b = els()
check(b.Card and b.Card.Visible, "the Move bubble is on screen")
local body = b.Body and b.Body.Text or ""
check(string.find(body, "to move") ~= nil, "Move uses the input prompt text: " .. body)
local card = b.Card
local vp = workspace.CurrentCamera.ViewportSize
if card and vp.Y > vp.X then
	-- portrait: the tray is at the top under the HUD stack; the bubble sits below all of it
	local top = card.Position.Y.Offset - card.Size.Y.Offset
	check(top >= Hud.TopBottom(), string.format("portrait: bubble top %d below the HUD stack %d", top, Hud.TopBottom()))
elseif card then
	local v = Hud.BarTop()
	check(card.Position.Y.Offset <= v + 1, string.format("bubble bottom %d above the tray top %d", card.Position.Y.Offset, v))
end
step(1)
check(Tutorial.Current() == "Move", "Move stays until the hero moves")
local h = hero()
if h then
	h:PivotTo(h:GetPivot() + Vector3.new(12, 0, 0))
end
check(waitFor(nil, 2), "Move fades once the hero walked 10 studs")
step(1.5)
check(Tutorial.Current() == nil, "no Attack tip before the first kill")

-- 2 Attack after the first kill
C.setPlayer({ Kills = 1 })
check(waitFor("Attack", 3), "2 Attack shows after the first kill")
check(string.find(els().Body.Text, "attacks by itself") ~= nil, "Attack text")
-- hidden behind a panel, back after it closes
if UIState then
	UIState.Open("SmartTutorialTest", { Covers = true })
	step(0.4)
	local id, _, hidden = Tutorial.Current()
	check(id == "Attack" and hidden and not els().Card.Visible, "the bubble hides behind a panel (tip kept)")
	UIState.Close("SmartTutorialTest")
	step(0.3)
	check(els().Card.Visible, "the bubble comes back when the panel closes")
end
check(waitFor(nil, 6), "Attack fades on its own")

-- 3 Gems: a gem lands near the hero
local gems = workspace:FindFirstChild("SwarmGems") or Instance.new("Folder")
gems.Name = "SwarmGems"
gems.Parent = workspace
local hp = h and h:GetPivot().Position or s.centre
local gem = Instance.new("Part")
gem.Anchored = true
gem.Size = Vector3.new(1, 1, 1)
gem.Position = hp + Vector3.new(8, 0, 6)
gem:SetAttribute("Base", gem.Position)
gem:SetAttribute("Active", true)
gem.Parent = gems
check(waitFor("Gems", 3), "3 Gems shows when a gem lands near the hero")
check(string.find(els().Body.Text, "blue gems") ~= nil, "Gems text")
check(Tutorial.Current() == "Gems" and select(2, Tutorial.Current())[1] == nil, "one tip at a time (nothing else queued)")
step(1)
C.setPlayer({ XP = 3 })
gem:SetAttribute("Active", false)
check(waitFor(nil, 2), "Gems fades once XP moves")

-- 4 LevelUp: the line under LEVEL UP!, once
local hint = Tutorial.LevelUpHint()
check(hint ~= nil and string.find(hint, "Choose an upgrade") ~= nil, "4 LevelUp line: " .. tostring(hint))
check(Tutorial.LevelUpHint() == nil, "the LevelUp line shows once")

-- 5 Chest: a ready chest within 12 studs
local loot = workspace:FindFirstChild("SwarmLoot") or Instance.new("Folder")
loot.Name = "SwarmLoot"
loot.Parent = workspace
local chest = Instance.new("Model")
chest.Name = "TestChest"
chest:SetAttribute("LootKind", "Chest")
chest:SetAttribute("State", "Ready")
chest:SetAttribute("Pos", hp + Vector3.new(-20, 0, 0))
chest.Parent = loot
step(1.5)
check(Tutorial.Current() == nil, "no Chest tip 20 studs away")
chest:SetAttribute("Pos", hp + Vector3.new(-9, 0, 0))
check(waitFor("Chest", 3), "5 Chest shows within 12 studs")
check(string.find(els().Body.Text, "to open chests") ~= nil, "Chest text: " .. els().Body.Text)
step(0.3)
check(els().Tail and els().Tail.Visible, "the Chest bubble's tail points at the chest")
chest:SetAttribute("State", "Opened")
check(waitFor(nil, 2), "Chest fades once it opens")

-- 6 Portal after the reveal
C.setState({ PortalHint = true, PortalReveal = 1, StageBoss = "Scorpion Queen" })
step(1)
check(Tutorial.Current() == nil, "no Portal tip during the reveal banner")
check(waitFor("Portal", 4), "6 Portal shows after the reveal")
check(string.find(els().Body.Text, "charge the portal") ~= nil, "Portal text")
C.setState({ PortalCharge = 1 })
check(waitFor(nil, 2), "Portal fades once the charge starts")

-- 7 Boss
C.setState({ StagePhase = "Boss", BossMaxHP = 9000, BossHP = 9000, BossName = "Scorpion Queen" })
check(waitFor("Boss", 3), "7 Boss shows on the first boss arrival")
check(string.find(els().Body.Text, "Bosses guard") ~= nil, "Boss text")
check(waitFor(nil, 10), "Boss fades after its time")

-- never twice
local count: { [string]: number } = {}
for _, id in ipairs(shownLog) do
	count[id] = (count[id] or 0) + 1
end
local twice = false
for _, n in pairs(count) do
	twice = twice or n > 1
end
check(not twice, "each tip shown once: " .. table.concat(shownLog, ","))
check(#shownLog == 6, "six bubble tips (LevelUp lives under LEVEL UP!)")
-- the same session's next run: everything seen, nothing again
newRun(firstProfile)
C.setPlayer({ Kills = 1 })
step(6)
check(Tutorial.Current() == nil and #shownLog == 6, "a seen tip never shows again")

-- a finished tutorial (two tutorial runs, or TutorialDone) shows nothing
Tutorial.Replay()
newRun({ TutorialDone = false, TutorialStep = 2, SeenTips = {}, Settings = settings })
step(8)
check(Tutorial.Current() == nil, "TutorialStep 2: no tips (two tutorial runs are over)")
Tutorial.Replay()
newRun({ TutorialDone = true, TutorialStep = 0, SeenTips = {}, Settings = settings })
step(8)
check(Tutorial.Current() == nil, "TutorialDone: no tips")
-- the second tutorial run (TutorialStep 1): tips not yet seen still show
Tutorial.Replay()
newRun({ TutorialDone = false, TutorialStep = 1, SeenTips = { Attack = true }, Settings = settings })
check(waitFor("Move", 15), "TutorialStep 1 (second run): Move shows")
step(0.6)
preview.log(string.format("smart-tutorial-regression: %d FAIL", fails))
