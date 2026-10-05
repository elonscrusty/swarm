-- lobby-regression: the LOBBY features (docs/features/LOBBY.md) against the real server and
-- the client modules (headless).
--   1) weapon mastery (15): sword kills (a delayed swing) and orb kills (projectiles) are
--      credited to their weapon in the save; nothing on a DEV-tainted run or with the switch
--      off; a milestone crossing sends one notice; SetMasteryGlow validation (bad weapon /
--      index / locked / switch off), a set glow survives DataService.Migrate; the client
--      tint answers for the sword and your own shots only, never with the switch off
--   2) photo mode (29): the PHOTO button only with the switch on; entering hides every other
--      GUI and the real hero, poses a copy, orbits the camera, cycles poses / frames; EXIT
--      and leaving the run restore everything
--   3) lobby fun (30): the courtyard builds only while you are in it, stays under MaxParts
--      and out of the title shot, the dummy DPS for every hero, the course clock (start,
--      finish + best, fail, reset, timeout), BACK restores the menu GUIs; switch off = no entry
-- Prints PASS / FAIL lines.
local Players = game:GetService("Players")
local player = Players.LocalPlayer
preview.startServer()
preview.startClient(false) -- the client modules, without ClientMain (headless)
preview.advance(1)
local RM = preview.server("RunManager")
local DS = preview.server("DataService")
local Spawner = preview.server("EnemySpawner")
local LevelUp = preview.server("LevelUpSystem")
local WMs = preview.server("WeaponMastery")
local Config = preview.shared("Config")
local WeaponData = preview.shared("WeaponData")
local CharacterData = preview.shared("CharacterData")
local CosmeticData = preview.shared("CosmeticData")
local M = Config.WeaponMastery

local fails = 0
local function check(ok: boolean, label: string, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

local data = assert(DS.GetData(player), "profile missing")
data.OwnedCharacters = { Knight = true }
data.SelectedCharacter = "Knight"
data.WeaponMastery = {}

local notices = {}
preview.remote("Notify").OnClientEvent:Connect(function(p)
	if type(p) == "table" and type(p.Id) == "string" and string.sub(p.Id, 1, 8) == "mastery:" then
		table.insert(notices, p.Text)
	end
end)

local function startRun()
	preview.remote("StartRun"):FireServer("Solo")
	preview.advance(3)
	local rp = assert(RM.GetRunPlayer(player), "run player missing")
	rp.InvulnUntil = 1e9
	return rp
end

local function endRun(rp)
	RM.AbandonRun(rp)
	preview.advance(Config.Run.ResultsSeconds + 2)
end

-- a ring of 1-HP skeletons around the hero; returns how many died within `seconds`
local function feed(rp, n: number, radius: number, seconds: number): number
	for i = #Spawner.Active, 1, -1 do
		Spawner.Despawn(Spawner.Active[i])
	end
	local root = rp.Root.Position
	local list = {}
	for i = 1, n do
		local a = i / n * math.pi * 2
		local e = Spawner.Spawn("Skeleton", root + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius), { Force = true, HP = 1 })
		if e then
			table.insert(list, e)
		end
	end
	local t = 0
	while t < seconds do
		LevelUp.Cancel(rp) -- level-ups would freeze the solo world: these checks are about kills
		preview.advance(0.25)
		t += 0.25
		for _, e in ipairs(list) do
			if e.Alive then
				e.Pos = root + (e.Pos - root).Unit * radius -- keep them in reach
			end
		end
	end
	local dead = 0
	for _, e in ipairs(list) do
		if not e.Alive then
			dead += 1
		end
	end
	return dead
end

------------------------------------------------------------------------------------------
-- 1) weapon mastery
------------------------------------------------------------------------------------------
local rp = startRun()
local dead = feed(rp, 8, 5, 4)
local swordKills = data.WeaponMastery.Whip or 0
check(dead > 0 and swordKills > 0, "sword kills counted in the save", string.format("%d died, Whip = %d", dead, swordKills))
check(swordKills <= rp.Kills, "never more mastery kills than kills", rp.Kills)
-- a projectile weapon: the Magic Orb
LevelUp.AddWeapon(rp, "MagicOrb")
rp.Weapons.Whip.Timer = 1e9 -- the sword rests so the orb lands the kills
local orbDead = feed(rp, 6, 9, 6)
check((data.WeaponMastery.MagicOrb or 0) > 0, "orb kills counted for the Magic Orb", string.format("%d died, MagicOrb = %s", orbDead, tostring(data.WeaponMastery.MagicOrb)))
-- DEV-tainted run: nothing
local before = data.WeaponMastery.MagicOrb or 0
rp.DevTainted = true
local k0 = rp.Kills
feed(rp, 6, 9, 6)
check(rp.Kills > k0 and (data.WeaponMastery.MagicOrb or 0) == before, "DEV-tainted run: no mastery kills", string.format("%d kills, MagicOrb = %d", rp.Kills - k0, data.WeaponMastery.MagicOrb or 0))
rp.DevTainted = false
-- switch off: nothing
Config.Features.WeaponMastery = false
k0 = rp.Kills
feed(rp, 6, 9, 6)
check(rp.Kills > k0 and (data.WeaponMastery.MagicOrb or 0) == before, "switch off: no mastery kills", string.format("%d kills, MagicOrb = %d", rp.Kills - k0, data.WeaponMastery.MagicOrb or 0))
Config.Features.WeaponMastery = true
-- a milestone crossing sends one notice
data.WeaponMastery.MagicOrb = M.Milestones[1].Kills - 1
table.clear(notices)
local mDead = feed(rp, 6, 9, 8)
preview.advance(0.5)
check(#notices == 1 and string.find(notices[1], M.Milestones[1].Name, 1, true) ~= nil, "one milestone notice", string.format("%d died, %d notice(s): %s, MagicOrb = %d", mDead, #notices, tostring(notices[1]), data.WeaponMastery.MagicOrb or 0))
endRun(rp)
-- AddKill caps
local probe = { WeaponMastery = { Whip = M.MaxCount } }
WMs.AddKill(probe, "Whip")
check(probe.WeaponMastery.Whip == M.MaxCount, "count stops at MaxCount")
local full = { WeaponMastery = {} }
for i = 1, Config.Data.Caps.WeaponMastery do
	full.WeaponMastery["W" .. i] = 1
end
WMs.AddKill(full, "Brandnew")
check(full.WeaponMastery.Brandnew == nil, "no new key past the cap")
-- SetMasteryGlow
data.WeaponMastery.Whip = M.Milestones[2].Kills
local function glow(w, i)
	return WMs.SetGlow(player, w, i)
end
local ok, why = glow("Nope", 1)
check(not ok and why == "weapon", "unknown weapon refused", why)
ok, why = glow("Whip", 1.5)
check(not ok and why == "index", "fractional index refused", why)
ok, why = glow("Whip", #M.Milestones + 1)
check(not ok and why == "index", "index past the last milestone refused", why)
ok, why = glow("Whip", 3)
check(not ok and why == "locked" and data.WeaponMastery["Glow:Whip"] == nil, "locked glow refused", why)
ok = glow("Whip", 2)
check(ok and data.WeaponMastery["Glow:Whip"] == 2, "earned glow worn")
preview.remote("SetMasteryGlow"):FireServer("Whip", 1)
preview.advance(0.3)
check(data.WeaponMastery["Glow:Whip"] == 1, "remote path sets the glow")
Config.Features.WeaponMastery = false
ok, why = glow("Whip", 2)
check(not ok and why == "off" and data.WeaponMastery["Glow:Whip"] == 1, "switch off: refused", why)
Config.Features.WeaponMastery = true
local migrated = DS.Migrate(table.clone(data))
check(migrated.WeaponMastery["Glow:Whip"] == 1 and migrated.WeaponMastery.Whip == M.Milestones[2].Kills, "glow and counts survive Migrate")
ok = glow("Whip", 0)
check(ok and data.WeaponMastery["Glow:Whip"] == nil, "0 = back to its own colour")
for _, m in ipairs(M.Milestones) do
	local e = CosmeticData.Get(m.Id)
	check(e ~= nil and e.Kind == "Trail" and e.Source == "Earned" and e.Weapon == true, "registry entry " .. m.Id)
end
-- client tint
local WMc = preview.client("WeaponMastery")
local orbVisual = WeaponData.Weapons.MagicOrb.Params.Visual
WMc._OnProfile({ Features = { WeaponMastery = { Whip = 1200, ["Glow:Whip"] = 2, MagicOrb = 300, ["Glow:MagicOrb"] = 1 } } })
check(WMc.ColorFor("Whip") == M.Milestones[2].Color, "client: the sword wears Silver")
player:SetAttribute("InRun", true)
check(WMc.ColorFor(orbVisual, Vector3.new(0, 0, 0)) == M.Milestones[1].Color, "client: solo orb shots wear Bronze")
check(WMc.ColorFor(WeaponData.Weapons.Knives.Params.Visual, Vector3.zero) == nil, "client: a weapon without a glow keeps its colour")
local mate = preview.addPlayer("Mate", 9001)
mate:SetAttribute("InRun", true)
check(WMc.ColorFor(orbVisual, Vector3.new(5000, 0, 5000)) == nil, "client co-op: a shot far from your hero is not yours")
mate:SetAttribute("InRun", false)
preview.removePlayer(mate)
Config.Features.WeaponMastery = false
check(WMc.ColorFor("Whip") == nil, "client: switch off = no tint")
Config.Features.WeaponMastery = true
player:SetAttribute("InRun", false)

------------------------------------------------------------------------------------------
-- 2) photo mode
------------------------------------------------------------------------------------------
local Photo = preview.client("PhotoMode")
local gui = player:WaitForChild("PlayerGui")
local holder = Instance.new("ScreenGui")
holder.Name = "FakeResults"
holder.Parent = gui
local row = Instance.new("Frame")
row.Size = UDim2.fromOffset(400, 44)
row.Parent = holder
Config.Features.PhotoMode = false
check(Photo.AttachButton(row, 3) == nil and row:FindFirstChild("Photo") == nil, "photo switch off: no PHOTO button")
Config.Features.PhotoMode = true
local held = false
local btn = Photo.AttachButton(row, 3, function()
	held = true
end)
check(btn ~= nil and row:FindFirstChild("Photo") ~= nil, "PHOTO button in the results footer")
-- a hero to pose: the lobby character
local char = player.Character
check(char ~= nil, "a character exists")
rp = startRun()
char = player.Character
preview.advance(0.5)
local cam = workspace.CurrentCamera
preview.click(btn.Instance)
preview.advance(0.2)
check(held and Photo.IsOn(), "PHOTO holds the results and enters photo mode")
check(not holder.Enabled, "other GUIs hidden")
local hero = workspace:FindFirstChild("PhotoHero")
check(hero ~= nil, "posed hero copy in the world")
local hiddenOk = true
for _, d in ipairs(char:GetDescendants()) do
	if d:IsA("BasePart") and d.LocalTransparencyModifier < 1 then
		hiddenOk = false
	end
end
check(hiddenOk, "the real hero hides locally")
local cf1 = cam.CFrame
preview.advance(1)
check((cam.CFrame.Position - cf1.Position).Magnitude > 0.05, "the camera orbits", (cam.CFrame.Position - cf1.Position).Magnitude)
local pg = gui:FindFirstChild("PhotoMode")
local poseBtn = pg and pg:FindFirstChild("Pose", true)
local frameBtn = pg and pg:FindFirstChild("Frame", true)
if poseBtn and poseBtn:IsA("GuiButton") then
	preview.click(poseBtn)
end
local frameObj = pg and pg:FindFirstChild("Frame")
local frameToggle = pg and pg:FindFirstChild("Bar") and pg.Bar:FindFirstChild("Frame")
if frameToggle then
	preview.click(frameToggle)
end
preview.advance(0.1)
check(frameObj ~= nil and frameObj.Visible, "FRAME shows the overlay")
check(poseBtn ~= nil and frameBtn ~= nil, "POSE and FRAME buttons")
preview.advance(Config.PhotoMode.HintSeconds + 0.5)
check(not pg.Bar.Visible, "the bar fades for the screenshot")
-- leaving the run exits
endRun(rp)
preview.advance(0.2)
check(not Photo.IsOn() and workspace:FindFirstChild("PhotoHero") == nil and holder.Enabled and gui:FindFirstChild("PhotoMode") == nil, "leaving the run exits and restores the GUIs")
-- EXIT button path
Photo.Enter()
preview.advance(0.2)
local exitBtn = gui:FindFirstChild("PhotoMode") and gui.PhotoMode:FindFirstChild("Exit", true)
if exitBtn then
	preview.click(exitBtn)
end
preview.advance(0.1)
check(not Photo.IsOn() and holder.Enabled, "EXIT restores the GUIs")
holder:Destroy()

------------------------------------------------------------------------------------------
-- 3) lobby fun
------------------------------------------------------------------------------------------
local Fun = preview.client("LobbyFun")
local LF = Config.LobbyFun
local CO = LF.Course
for _, id in ipairs(CharacterData.Order) do
	local name, dps = Fun.DummyDPS(id)
	check(dps > 0 and dps < 10000 and type(name) == "string", "dummy DPS " .. id, string.format("%s %.1f", name, dps))
end
-- course clock (pure)
local c = Fun.NewCourse()
local o = Vector3.zero
local ev, pad = Fun.CourseStep(c, CO.Start, true, 10)
check(ev == "launch" and pad == 1 and c.Running, "start pad launches and starts the clock")
ev = Fun.CourseStep(c, CO.Start + Vector3.new(0, 4, 0), false, 10.2)
check(ev == nil and c.Running, "in the air: running")
ev, pad = Fun.CourseStep(c, CO.Platforms[1].At, true, 11)
check(ev == "launch" and pad == 2, "platform pad launches")
ev = Fun.CourseStep(c, CO.Platforms[#CO.Platforms].At, true, 21.5)
check(ev == "finish" and math.abs((Fun.Best() or 0) - 11.5) < 1e-6, "finish stops the clock, best kept", Fun.Best())
Fun.CourseStep(c, CO.Start, true, 30)
ev = Fun.CourseStep(c, Vector3.new(10, 0, 70), true, 31)
check(ev == "fail" and not c.Running, "landing on the floor ends the try")
Fun.CourseStep(c, CO.Start, true, 40)
ev = Fun.CourseStep(c, Vector3.new(0, -20, 0), false, 41)
check(ev == "reset", "falling out of the world puts you back")
Fun.CourseStep(c, CO.Start, true, 50)
ev = Fun.CourseStep(c, CO.Platforms[1].At + Vector3.new(2, 0, 2), true, 50 + CO.MaxSeconds + 1)
check(ev == "timeout", "a try past MaxSeconds is dropped")
Fun.CourseStep(c, CO.Start, true, 300)
Fun.CourseStep(c, CO.Platforms[#CO.Platforms].At, true, 320)
check(math.abs((Fun.Best() or 0) - 11.5) < 1e-6, "a slower finish keeps the best")
_ = o
-- entering / leaving
Fun._SetProfile({ SelectedCharacter = "Knight", Skins = { Knight = "Default" }, Title = "", Features = { Cosmetics = { Equipped = { Trail = "", Burst = "", Pet = "", Nameplate = "", Dais = "", Emote = "" } }, WeaponMastery = { ["Glow:Whip"] = 1 } } })
local menuGui = Instance.new("ScreenGui")
menuGui.Name = "FakeMenu"
menuGui.Parent = gui
Config.Features.LobbyFun = false
Fun.Enter()
check(not Fun.IsOn() and workspace:FindFirstChild("LobbyFun") == nil, "fun switch off: no courtyard")
Config.Features.LobbyFun = true
check(workspace:FindFirstChild("LobbyFun") == nil, "nothing built before entering")
Fun.Enter()
preview.advance(0.3)
local folder = workspace:FindFirstChild("LobbyFun")
check(Fun.IsOn() and folder ~= nil, "courtyard built on entry")
check(Fun.PartCount() <= LF.MaxParts, "part count under MaxParts", Fun.PartCount())
check(not menuGui.Enabled and gui:FindFirstChild("LobbyFunUI") ~= nil, "menu GUIs hidden, courtyard UI shown")
local lobbyOrigin = Config.Lobby.Origin
local minZ = math.huge
for _, d in ipairs(folder:GetDescendants()) do
	if d:IsA("BasePart") then
		minZ = math.min(minZ, d.Position.Z - d.Size.Z / 2 - lobbyOrigin.Z)
	end
end
-- the menu camera looks toward -Z from about z = 16: everything here is behind it
local menuCam = workspace:FindFirstChild("MenuCamera", true)
local camZ = menuCam and (menuCam.Position.Z - lobbyOrigin.Z) or 16
check(minZ > camZ + 20, "the courtyard sits behind the menu camera", string.format("nearest z %.1f, camera z %.1f", minZ, camZ))
check(folder:FindFirstChild("MirrorHero") ~= nil, "the mirror shows the hero")
local root = player.Character and player.Character.PrimaryPart
check(root ~= nil and (root.Position - (lobbyOrigin + LF.Spawn)).Magnitude < 6, "you stand at the courtyard spawn")
check(player.Character:FindFirstChildOfClass("Humanoid").WalkSpeed == LF.WalkSpeed, "you can walk here")
local back = gui.LobbyFunUI:FindFirstChild("Back", true)
preview.click(back)
preview.advance(0.2)
check(not Fun.IsOn() and workspace:FindFirstChild("LobbyFun") == nil and menuGui.Enabled, "BACK removes the courtyard and restores the menu")
check(player.Character:FindFirstChildOfClass("Humanoid").WalkSpeed == 0, "back in the menu: no walking")
-- a run starting while you are there
Fun.Enter()
preview.advance(0.2)
rp = startRun()
preview.advance(0.3)
check(not Fun.IsOn() and workspace:FindFirstChild("LobbyFun") == nil, "a run start closes the courtyard")
endRun(rp)
menuGui:Destroy()

preview.log(fails == 0 and "PASS lobby-regression: all checks" or ("FAIL lobby-regression: " .. fails .. " check(s) failed"))
