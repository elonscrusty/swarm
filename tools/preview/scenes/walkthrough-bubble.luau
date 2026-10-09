-- walkthrough-bubble: the first-run walkthrough's speech bubble (client WalkthroughClient.lua in
-- TutorialBubble.lua) on a beacon run, for check_layout on phones: the step in --set step=Move
-- (default; the longest line on a touch screen) | Dash | Fight | Gems | Chest | Beacon. The
-- line must fit the bubble (no cut text) and the bubble must sit clear of the ability tray.
-- Prints PASS / FAIL lines. Registered as a layout check on iphone and phone-portrait.
local A = lib("arena")
local C = lib("common")
local Players = game:GetService("Players")
for _, n in ipairs({ "SwarmGems", "SwarmPickups", "SwarmEnemies" }) do
	if not workspace:FindFirstChild(n) then
		local f = Instance.new("Folder")
		f.Name = n
		f.Parent = workspace
	end
end
A.build({ enemies = 0, swarm = false, seconds = 20, stage = 1, stagePhase = "Explore", lockLeft = 0 })
C.settle(1)
local Tutorial = preview.client("Tutorial")
local WC = preview.client("WalkthroughClient")
local Hud = preview.client("Hud")
local me = Players.LocalPlayer
local fails = 0
local function check(ok: any, label: string)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label)
end
local settings = { Music = 0.6, Sfx = 0.8, Shake = 1, ReducedEffects = false, DamageNumbers = false, Tips = true }
C.sendProfile(C.profile({ TutorialDone = false, TutorialStep = 0, SeenTips = {}, Settings = settings, Stats = { BestTime = 0, TotalKills = 0, Wins = 0, Runs = 0, BestStage = 0 } }))
C.settle(0.2)
local step = preview.args.step or "Move"
local root = me.Character and me.Character.PrimaryPart
local here = root and root.Position or Vector3.new(0, 0, 0)
C.setState({ StagePhase = "Explore", RunStage = "Survive" })
C.setPlayer({
	InRun = true,
	WalkMode = "Beacon",
	Walkthrough = step,
	WalkCount = 2,
	WalkTotal = 5,
	WalkFree = step == "Chest" or nil,
	WalkTarget = (step == "Move" or step == "Chest") and (here + Vector3.new(12, 0, 6)) or nil,
})
for _ = 1, 30 do
	preview.advance(0.1, 10)
end
local shown, text = WC.Current()
check(shown == step, "the walkthrough owns the bubble: " .. tostring(shown))
check(text == WC.LineFor(step), "the bubble shows the step's line: " .. text)
check(not string.find(string.lower(text), "portal", 1, true), "no portal on a beacon run")
local b = Tutorial.Elements().Bubble or {}
local card = b.Card
check(card ~= nil and card.Visible, "the bubble is on screen")
if card then
	local bottom = card.Position.Y.Offset
	local top = bottom - card.Size.Y.Offset
	local trayTop, trayBottom = Hud.BarTop(), Hud.BarBottom()
	check(bottom <= trayTop + 1 or top >= trayBottom - 1, string.format("bubble %d..%d clear of the tray %d..%d", top, bottom, trayTop, trayBottom))
end
preview.log(fails == 0 and "PASS walkthrough-bubble" or ("FAIL walkthrough-bubble (" .. fails .. ")"))
