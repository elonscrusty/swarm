-- photo-mode: the results screen's PHOTO button (feature 29, docs/features/LOBBY.md) over
-- the arena: every other GUI hidden, the posed hero copy, the orbit camera, the control bar.
--   --set pose=Showcase|Cheer|Idle   the pose shown (default Cheer)
--   --set frame=None|Gold|Crimson|Frost  the overlay frame (default Gold)
--   --set faded=on                   wait until the bar fades (the screenshot look)
--   --set at=results                 stop on the results screen (the PHOTO button in the footer)
local A = lib("arena")
local C = lib("common")
local Config = C.shared("Config")
A.build({ enemies = 20, seconds = 900 })
C.settle(1)
C.setState({ Phase = "Results" })
C.sendProfile(C.profile())
C.fire("RunResult", { Curses = {}, CurseGold = 1, Account = { Gained = 120, From = 7, To = 7, Into = 300, Need = 500, Rewards = {} }, Won = true, Mode = "Solo", CharacterId = "Knight",
	Build = { Weapons = { { Id = "Whip", Level = 8, Evolved = false } }, Passives = {} }, BossKills = 5, BossFight = false, Time = 1500, Kills = 3874, Gold = 1412, GoldEarned = 1412, GoldLost = 0,
	GoldRetention = 1, Difficulty = "Standard", WinMinStages = 5, Level = 31, Damage = 286400, Arena = "Forest", Seconds = 25, Portal = true, StagesCleared = 5, Stage = 5, Items = {} })
C.settle(3)
local gui = game:GetService("Players").LocalPlayer.PlayerGui
local btn = gui:FindFirstChild("Photo", true)
preview.log((btn and "PASS" or "FAIL") .. " PHOTO button on the results")
if preview.args.at == "results" or not btn then
	return
end
preview.click(btn)
C.settle(0.4)
local pg = gui:FindFirstChild("PhotoMode")
local poses = Config.PhotoMode.Poses
local want = preview.args.pose or "Cheer"
for _ = 1, #poses do
	local cur = pg and pg:FindFirstChild("Pose", true)
	if not cur or string.find(cur.Text, string.upper(Config.PhotoMode.PoseNames[want] or want), 1, true) then
		break
	end
	preview.click(cur)
	preview.advance(0.05)
end
local frameWant = preview.args.frame or "Gold"
for _ = 1, #Config.PhotoMode.Frames do
	local fb = pg and pg.Bar:FindFirstChild("Frame")
	if not fb or string.find(fb.Text, string.upper(frameWant), 1, true) then
		break
	end
	preview.click(fb)
	preview.advance(0.05)
end
C.settle(preview.args.faded == "on" and (Config.PhotoMode.HintSeconds + 1) or 0.8)
