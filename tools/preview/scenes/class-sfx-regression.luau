-- class-sfx-regression: stream G (class cues, run-stage cues, crit feedback, shake caps) on the real
-- client modules over the arena. Headless (the scene starts the pieces ClientMain would). Prints PASS / FAIL.
--   1) every cue ClassSfx plays exists in Config.Sounds (numeric id, Weapon / UI / Player / Pickup / Stage group)
--   2) each of the 12 classes: its signature projectile (or slash) next to the hero plays its cue, the generic
--      throw sound is replaced; another weapon of that class and a non-class hero keep the generic sound
--   3) limits: a swarm of spawns plays a handful of cues, the Weapon group never holds more than 3 voices, a
--      burst of pellets is one cue, teammates play quieter and only when near, MaxPerSecond holds
--   4) movement hooks: the local dash cue per class, a teammate's dash from DashReadyAt, a jump / landing
--   5) RunStage: the stingers, the charge hum following BeaconCharge, the music intensity, Victory / Defeat holding
--      the results sounds back, joining mid-run is quiet, leaving the run clears everything
--   6) Downed / ReviveProgress cues and the chest purchase cue
--   7) crits: only the local hero's own crit ticks (server "ku"), a bigger burst, Reduced effects keep the tick
--      only; camera shake: ordinary < 0.12 s and capped, boss capped and short, off with Reduced effects
--   8) the attacker's recoil moves the rig briefly and is off with Reduced effects
local A = lib("arena")
local C = lib("common")
local Players = game:GetService("Players")

local Config = C.shared("Config")
local F = Config.Feel.ClassSfx
local me = Players.LocalPlayer

-- teammates exist before ClassSfx starts watching players
local s -- (set below; the teammates are built from the arena's ModelBuilder)
local function mate(name: string, userId: number, offset: Vector3, attrs)
	local p = preview.addPlayer(name, userId)
	local model = C.try("BuildCharacter", s.ModelBuilder.BuildCharacter, "Knight", "Default")
	if model then
		model.Name = name
		model:PivotTo(CFrame.new(s.centre + offset + Vector3.new(0, 3.5, 0)))
		model.Parent = workspace
		p.Character = model
	end
	p:SetAttribute("InRun", true)
	p:SetAttribute("Alive", true)
	for k, v in pairs(attrs or {}) do
		p:SetAttribute(k, v)
	end
	return p, model
end

s = A.build({ enemies = 10, seconds = 300 })
local near = mate("Near", 2, Vector3.new(12, 0, 0), { CharacterId = "rambozo" })
local far = mate("Far", 3, Vector3.new(160, 0, 0), { CharacterId = "rambozo" })
local down = mate("Down", 4, Vector3.new(-6, 0, 0), { CharacterId = "knuckles_mcgee" })
local headless = preview.args.headless == "on"
local Audio = preview.client("Audio")
local Settings = preview.client("ClientSettings")
local CameraController = preview.client("CameraController")
local EnemyRenderer = preview.client("EnemyRenderer")
local CombatFx = preview.client("CombatFx")
if headless then
	Audio.Init()
	CameraController.Init()
	EnemyRenderer.Init()
	preview.client("VFX").Init()
end
local ClassSfx = preview.client("ClassSfx")
ClassSfx.Init()
local Accessibility = preview.client("Accessibility")
C.settle(1)

local fails = 0
local function check(ok: boolean, label: string, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

-- every Audio.Play call, in order
local log: { { Name: string, Pitch: number?, Gain: number?, Started: boolean } } = {}
local realPlay = Audio.Play
Audio.Play = function(name: string, pitch: number?, gain: number?)
	local started = realPlay(name, pitch, gain)
	table.insert(log, { Name = name, Pitch = pitch, Gain = gain, Started = started })
	return started
end
local function names(from: number?): string
	local out = {}
	for i = from or 1, #log do
		if log[i].Started then
			table.insert(out, log[i].Name)
		end
	end
	return table.concat(out, ",")
end
local function count(name: string, from: number?): number
	local n = 0
	for i = from or 1, #log do
		if log[i].Name == name and log[i].Started then
			n += 1
		end
	end
	return n
end
local function mark(): number
	return #log + 1
end

local root = me.Character.PrimaryPart
local hero = root.Position
local function wait(seconds: number)
	preview.advance(seconds, 60)
end

------------------------------------------------------------------------------------------
-- 1) the cue table
------------------------------------------------------------------------------------------
local used = { "PortalAppear", "BeaconActivate", "BeaconCharge", "BossSpawn", "RunVictory", "RunDefeat", "Downed", "ReviveBeat", "ChestBuy", "CritTick", "Swing" }
for id, kit in pairs(ClassSfx.Kits()) do
	for _, key in ipairs({ "Fire", "Impact", "Melee", "Uppercut", "Accent", "Dash", "Jump", "Land", "Plant" }) do
		if kit[key] then
			table.insert(used, kit[key].Name)
		end
	end
end
local bad = {}
for _, n in ipairs(used) do
	local def = Config.Sounds[n]
	if not def or not string.match(def.Id, "^rbxassetid://%d+$") then
		table.insert(bad, n)
	end
end
check(#bad == 0, "every cue is a Config.Sounds entry with a numeric asset id", table.concat(bad, ","))
local classes = 0
for _ in pairs(ClassSfx.Kits()) do
	classes += 1
end
check(classes == 12, "a kit for each of the 12 classes", classes)
local groupsOk = true
for _, n in ipairs({ "ScrapClatter", "ToastPop", "BubbleBloop", "YarnPop", "DodgeballThump", "DodgeballWhistle", "MopSwoosh", "MopSqueak", "ConfettiRattle", "ConfettiHonk", "GymScrape", "PuckClack", "SkateRoll", "GloveThud", "GloveBell", "ShoeBoing", "SeedSprout", "CritTick" }) do
	groupsOk = groupsOk and Config.Sounds[n].Category == "Weapon"
end
check(groupsOk, "class cues and the crit tick are in the Weapon group")
check(Config.Audio.Categories.Weapon.MaxVoices <= 3 and Config.Audio.Duck.Also.Weapon ~= nil, "Weapon group: at most 3 voices, ducked by warnings", Config.Audio.Categories.Weapon.MaxVoices)
check(Config.Sounds.BeaconCharge.Loop == true and Audio.Loops().BeaconCharge ~= nil, "the charge hum is a loop Sound")
check(Accessibility ~= nil, "the audio-cue labels load")

------------------------------------------------------------------------------------------
-- 2) one signature per class
------------------------------------------------------------------------------------------
local projId = 100
local function spawnAt(visual: number, pos: Vector3, count_: number?, tier: number?)
	local n = count_ or 1
	local b = buffer.create(2 + n * 11)
	buffer.writeu16(b, 0, n)
	local o = 2
	for i = 1, n do
		projId += 1
		buffer.writeu16(b, o, projId)
		buffer.writeu8(b, o + 2, preview.shared("WeaponData").VisualByte(visual, tier or 0))
		buffer.writeu8(b, o + 3, 1)
		buffer.writei16(b, o + 4, math.floor(pos.X * 10 + 0.5))
		buffer.writei16(b, o + 6, math.floor(pos.Y * 10 + 0.5))
		buffer.writei16(b, o + 8, math.floor(pos.Z * 10 + 0.5))
		buffer.writeu8(b, o + 10, 0)
		o += 11
	end
	C.fire("ProjectileBatch", b)
end
local function slash(userId: number, tier: number, at: Vector3)
	C.fire("FxBatch", { s = { { at.X, at.Z, 0.3, 7, 1, tier, userId } } })
end
local function setClass(id: string)
	me:SetAttribute("CharacterId", id)
	ClassSfx.ResetLimits()
	wait(0.35) -- past every MinGap
end

local signature = {
	{ "ruckus", 57, "ScrapClatter" }, { "toastmaster", 58, "ToastPop" }, { "captain_croak", 59, "BubbleBloop" },
	{ "granny_boom", 60, "YarnPop" }, { "coach_crunch", 45, "DodgeballThump" }, { "peter_parkour", 5, "ShoeBoing" },
	{ "barry_plotter", 45, "SeedSprout" }, { "rambozo", 24, "ConfettiRattle" }, { "crash_cassidy", 49, "PuckClack" },
}
for _, row in ipairs(signature) do
	local class, visual, cueName = row[1], row[2], row[3]
	setClass(class)
	local m = mark()
	spawnAt(visual, hero + Vector3.new(0.5, 0, 0))
	wait(0.1)
	check(count(cueName, m) == 1 and count("Throw", m) == 0, class .. ": visual " .. visual .. " plays " .. cueName .. " instead of the generic throw", names(m))
end
local melee = { { "doug_janitor", "MopSwoosh" }, { "swolverine", "GymScrape" }, { "knuckles_mcgee", "GloveThud" } }
for _, row in ipairs(melee) do
	setClass(row[1])
	local m = mark()
	slash(me.UserId, 0, hero)
	wait(0.1)
	check(count(row[2], m) == 1 and count("Swing", m) == 0, row[1] .. ": a swing plays " .. row[2] .. " instead of the sword whoosh", names(m))
end
setClass("knuckles_mcgee")
local m0 = mark()
slash(me.UserId, 3, hero)
wait(0.1)
check(count("GloveBell", m0) == 1 and count("GloveThud", m0) == 1, "knuckles_mcgee: the uppercut (tier 3) rings the bell and thuds", names(m0))
-- the accents: every 6th confetti burst honks, every 3rd mop sweep squeaks
setClass("rambozo")
m0 = mark()
for _ = 1, F.HonkEvery do
	spawnAt(24, hero)
	wait(0.35)
end
check(count("ConfettiHonk", m0) == 1 and count("ConfettiRattle", m0) == F.HonkEvery, "rambozo: a honk on every " .. F.HonkEvery .. "th burst", names(m0))
setClass("doug_janitor")
m0 = mark()
for _ = 1, F.SqueakEvery do
	slash(me.UserId, 0, hero)
	wait(0.35)
end
check(count("MopSqueak", m0) == 1 and count("MopSwoosh", m0) == F.SqueakEvery, "doug_janitor: a squeak on every " .. F.SqueakEvery .. "rd sweep", names(m0))

-- another weapon of the class, and a hero without a kit, keep the generic sound
setClass("ruckus")
m0 = mark()
spawnAt(2, hero) -- a knife
wait(0.1)
check(count("ScrapClatter", m0) == 0 and count("Throw", m0) == 1, "ruckus: a knife keeps the generic throw sound", names(m0))
setClass("Knight")
m0 = mark()
spawnAt(57, hero)
wait(0.1)
check(count("ScrapClatter", m0) == 0 and count("Throw", m0) == 1, "a hero without a class kit keeps the generic throw sound", names(m0))
m0 = mark()
slash(me.UserId, 0, hero)
wait(0.1)
check(count("Swing", m0) == 1, "... and the sword whoosh", names(m0))

-- impact: the local class's own projectile ending; the Seed Slinger's plant sprouting
setClass("crash_cassidy")
m0 = mark()
spawnAt(49, hero + Vector3.new(0.5, 0, 0))
wait(0.2)
C.fire("ProjectileBatch", buffer.create(2)) -- an empty batch: the puck is gone (its impact)
wait(0.1)
check(count("PuckClack", m0) == 2, "crash_cassidy: a puck's end plays the impact clack (fire + impact)", names(m0))
setClass("barry_plotter")
m0 = mark()
spawnAt(51, hero + Vector3.new(0, 0, 14)) -- a plant appears away from the hero
wait(0.1)
check(count("SeedSprout", m0) == 1, "barry_plotter: a new plant sprouts", names(m0))

------------------------------------------------------------------------------------------
-- 3) limits
------------------------------------------------------------------------------------------
setClass("ruckus")
m0 = mark()
local t0 = os.clock()
for _ = 1, 40 do
	spawnAt(57, hero)
	wait(0.0075)
end
local elapsed = os.clock() - t0
local scrap = count("ScrapClatter", m0)
check(scrap >= 1 and scrap <= math.floor(elapsed / F.PerUserGap) + 1, "40 scrap shots in " .. string.format("%.2f", elapsed) .. " s are one cue per PerUserGap (" .. F.PerUserGap .. ")", scrap)
local weaponVoices = 0
for _, v in ipairs(Audio.Voices()) do
	if v.Category == "Weapon" then
		weaponVoices += 1
	end
end
check(weaponVoices <= Config.Audio.Categories.Weapon.MaxVoices, "the Weapon group never holds more than " .. Config.Audio.Categories.Weapon.MaxVoices .. " voices", weaponVoices)
setClass("rambozo")
m0 = mark()
spawnAt(24, hero, 5)
wait(0.1)
check(count("ConfettiRattle", m0) == 1, "rambozo: five pellets in one batch are one rattle", names(m0))
-- teammates: near plays quieter, far plays nothing
ClassSfx.ResetLimits()
wait(0.4)
m0 = mark()
local nearRoot = near.Character.PrimaryPart.Position
spawnAt(24, nearRoot + Vector3.new(0.5, 0, 0))
wait(0.1)
local nearLog
for i = m0, #log do
	if log[i].Name == "ConfettiRattle" and log[i].Started then
		nearLog = log[i]
	end
end
check(nearLog ~= nil and nearLog.Gain ~= nil and math.abs(nearLog.Gain - F.OtherGain) < 0.01, "a teammate's cue plays at OtherGain (" .. F.OtherGain .. ")", nearLog and nearLog.Gain)
wait(0.35)
m0 = mark()
spawnAt(24, far.Character.PrimaryPart.Position + Vector3.new(0.5, 0, 0))
wait(0.1)
check(count("ConfettiRattle", m0) == 0, "a teammate " .. math.floor((far.Character.PrimaryPart.Position - hero).Magnitude) .. " studs away is not heard (OtherRange " .. F.OtherRange .. ")", names(m0))
-- MaxPerSecond: the cap on all class cues together (twelve different cues in one instant, no per-hero gap)
local gap = F.PerUserGap
F.PerUserGap = 0
ClassSfx.ResetLimits()
wait(0.4)
for _, row in ipairs({ "ruckus", "toastmaster", "captain_croak", "granny_boom", "coach_crunch", "doug_janitor", "peter_parkour", "barry_plotter", "rambozo", "swolverine", "crash_cassidy", "knuckles_mcgee" }) do
	me:SetAttribute("CharacterId", row)
	ClassSfx.Dash(me.UserId, "Dash", hero)
end
local capped = ClassSfx.Stats()
F.PerUserGap = gap
check(capped.Played == F.MaxPerSecond and capped.Capped == 12 - F.MaxPerSecond, "twelve different cues in an instant: only MaxPerSecond (" .. F.MaxPerSecond .. ") start", string.format("played %d, capped %d", capped.Played, capped.Capped))

------------------------------------------------------------------------------------------
-- 4) movement
------------------------------------------------------------------------------------------
local dashes = {
	{ "ruckus", "ScrapClatter" }, { "captain_croak", "BubbleBloop" }, { "granny_boom", "YarnPop" }, { "coach_crunch", "DodgeballWhistle" },
	{ "doug_janitor", "MopSqueak" }, { "peter_parkour", "ShoeBoing" }, { "barry_plotter", "SeedSprout" }, { "rambozo", "ConfettiHonk" },
	{ "swolverine", "GymScrape" }, { "crash_cassidy", "SkateRoll" }, { "knuckles_mcgee", "GloveThud" }, { "toastmaster", "Swing" }, { "Knight", "Swing" },
}
for _, row in ipairs(dashes) do
	setClass(row[1])
	local m = mark()
	ClassSfx.Dash(me.UserId, "Dash", hero)
	check(count(row[2], m) == 1, row[1] .. ": the dash plays " .. row[2], names(m))
end
setClass("ruckus")
m0 = mark()
near:SetAttribute("CharacterId", "swolverine")
near:SetAttribute("DashReadyAt", workspace:GetServerTimeNow() + 2.5)
wait(0.1)
check(count("GymScrape", m0) == 1, "a teammate's dash (DashReadyAt rising) plays their class cue", names(m0))
m0 = mark()
near:SetAttribute("DashReadyAt", 0)
wait(0.1)
check(count("GymScrape", m0) == 0, "... a reset of DashReadyAt to 0 is not a dash", names(m0))
setClass("toastmaster")
m0 = mark()
ClassSfx.Jump(false)
ClassSfx.Landed(0.2)
check(count("ToastPop", m0) == 1, "toastmaster: a jump springs, a short hop does not pop on landing", names(m0))
wait(0.35)
ClassSfx.Landed(0.5)
check(count("ToastPop", m0) == 2, "toastmaster: a landing after 0.5 s in the air pops", names(m0))
setClass("peter_parkour")
m0 = mark()
ClassSfx.Jump(true)
local boing = log[#log]
check(boing.Name == "ShoeBoing" and boing.Started, "peter_parkour: the charged jump boings", names(m0))
setClass("ruckus")
m0 = mark()
ClassSfx.Jump(false)
ClassSfx.Landed(1)
check(#log < m0, "a class without a jump cue stays silent on jumps and landings", names(m0))

------------------------------------------------------------------------------------------
-- 5) run stage
------------------------------------------------------------------------------------------
setClass("Knight")
local state = C.state()
local function stage(name: string)
	state:SetAttribute("RunStage", name)
	wait(0.05)
end
local beaconPos = hero + Vector3.new(10, 0, 0)
C.setState({ RunStage = "Survive", BeaconPos = beaconPos, BeaconCharge = 0 })
wait(0.2)
check(Audio.Intensity() == 0, "Survive: no extra music intensity", Audio.Intensity())
m0 = mark()
stage("BeaconAvailable")
check(count("PortalAppear", m0) == 1 and math.abs(Audio.Intensity() - F.StageIntensity.BeaconAvailable) < 0.01, "BeaconAvailable: the reveal cue, a little pressure", names(m0))
m0 = mark()
stage("Rally")
check(count("BeaconActivate", m0) == 1 and math.abs(Audio.Intensity() - F.StageIntensity.Rally) < 0.01, "Rally: the beacon activation stinger", names(m0))
m0 = mark()
state:SetAttribute("BeaconCharge", 0.25)
stage("Charge")
wait(Config.Sounds.BeaconCharge.Fade + 0.3)
local loop = Audio.Loops().BeaconCharge
check(loop.On and loop.Playing and loop.Volume > 0 and loop.Volume <= Config.Sounds.BeaconCharge.Volume, "Charge: the hum loop plays", string.format("vol %.3f", loop.Volume))
local low = loop.Volume
state:SetAttribute("BeaconCharge", 0.95)
wait(F.ChargeRefresh + Config.Sounds.BeaconCharge.Fade + 0.3)
loop = Audio.Loops().BeaconCharge
check(loop.Volume > low * 1.3 and loop.Speed > Config.Sounds.BeaconCharge.SpeedLow, "... louder and higher as BeaconCharge fills", string.format("%.3f -> %.3f, speed %.2f", low, loop.Volume, loop.Speed))
-- far from the beacon the hum is quieter
state:SetAttribute("BeaconPos", beaconPos + Vector3.new(200, 0, 0))
wait(F.ChargeRefresh + Config.Sounds.BeaconCharge.Fade + 0.3)
check(Audio.Loops().BeaconCharge.Volume < loop.Volume * 0.8, "... and quieter when the hero is far from the beacon", string.format("%.3f", Audio.Loops().BeaconCharge.Volume))
state:SetAttribute("BeaconPos", beaconPos)
m0 = mark()
stage("Boss")
local st1 = CameraController.ShakeState() -- right after the stage change: the shake is running
wait(Config.Sounds.BeaconCharge.Fade + 0.2)
check(count("BossSpawn", m0) == 1, "Boss: the boss sting plays", names(m0))
check(not Audio.Loops().BeaconCharge.Playing, "Boss: the charge hum fades out and stops")
check(math.abs(Audio.Intensity() - 1) < 0.01, "Boss: full music pressure", Audio.Intensity())
check(st1.Length <= Config.Camera.BossShakeSeconds + 0.001 and st1.Amount <= Config.Camera.BossShakeMax + 0.001 and st1.Amount > 0, "Boss: a short, capped boss shake", string.format("%.2f s, %.2f studs", st1.Length, st1.Amount))
-- the music rises, a warning dips it
local music = game:GetService("SoundService"):FindFirstChild("BattleMusic") :: Sound?
Audio.SetMusic("BattleMusic")
wait(Config.Audio.Music.Fade + Config.Audio.Music.IntensityFade + 0.3)
local base = Config.Sounds.BattleMusic.Volume
if music then
	check(music.Volume > base * 1.05 and music.Volume <= base * (1 + Config.Audio.Music.IntensityBoost) + 0.002, "the music settles a little louder at full pressure", string.format("%.3f of %.3f", music.Volume, base))
end
local duck = game:GetService("SoundService"):FindFirstChild("SwarmMusicDuck", true) :: SoundGroup?
Audio.PlayAt("BossWarn", hero + Vector3.new(10, 0, 0))
wait(Config.Audio.MusicDuck.Attack + 0.05)
check(duck ~= nil and duck.Volume < 0.9 and duck.Volume >= Config.Audio.Music.IntensityDip - 0.05, "... and a boss warning dips it so the warning stays clear", duck and string.format("%.2f", duck.Volume))
wait(2.2)
m0 = mark()
stage("Victory")
check(count("RunVictory", m0) == 1, "Victory: the run's victory stinger plays", names(m0))
check(Audio.Play("Victory") == false, "... and the results fanfare waits for it")
check(Audio.Intensity() == 0, "... the music pressure is gone", Audio.Intensity())
Audio.StopEffects() -- the run ends right after the stinger starts: it plays out
local keeps = false
for _, v in ipairs(Audio.Voices()) do
	keeps = keeps or string.find(v.Name, "RunVictory") ~= nil
end
check(keeps, "... and the end-of-run sound sweep leaves the stinger playing")
wait(F.VictoryHold + 0.2)
check(Audio.Play("Victory") == true, "... after VictoryHold the results fanfare plays again")
m0 = mark()
stage("Defeat")
check(count("RunDefeat", m0) == 1 and Audio.Play("ResultsLose") == false, "Defeat: the defeat stinger, the loss sting waits", names(m0))
-- joining mid-run: the first reading is quiet
state:SetAttribute("RunStage", "Survive")
wait(0.1)
C.setPlayer({ InRun = false })
wait(0.1)
state:SetAttribute("RunStage", "Charge")
m0 = mark()
C.setPlayer({ InRun = true })
wait(Config.Sounds.BeaconCharge.Fade + 0.3)
check(count("BeaconActivate", m0) == 0 and count("BossSpawn", m0) == 0 and Audio.Loops().BeaconCharge.On, "joining mid-Charge: the hum starts, no stinger", names(m0))
C.setPlayer({ InRun = false })
wait(Config.Sounds.BeaconCharge.Fade + 0.3)
check(not Audio.Loops().BeaconCharge.On and not Audio.Loops().BeaconCharge.Playing and Audio.Intensity() == 0, "leaving the run: the hum stops, the pressure resets")
C.setPlayer({ InRun = true })
state:SetAttribute("RunStage", "Survive")
wait(0.2)

------------------------------------------------------------------------------------------
-- 6) down, up, chests
------------------------------------------------------------------------------------------
m0 = mark()
me:SetAttribute("Downed", true)
wait(0.1)
check(count("Downed", m0) == 1, "the local hero going down plays the Downed cue", names(m0))
m0 = mark()
down:SetAttribute("Downed", true)
wait(0.1)
check(count("Downed", m0) == 0, "a teammate going down adds nothing (the global Death sound is theirs)", names(m0))
local function reviveTo(p, v: number)
	p:SetAttribute("ReviveProgress", v)
	wait(F.ReviveBeatGap + 0.05)
end
m0 = mark()
reviveTo(down, 0.2)
reviveTo(down, 0.6)
reviveTo(down, 0.9)
local beats = {}
for i = m0, #log do
	if log[i].Name == "ReviveBeat" and log[i].Started then
		table.insert(beats, log[i].Pitch)
	end
end
check(#beats == 3 and beats[1] < beats[2] and beats[2] < beats[3], "revive hold: a beat per step, rising in pitch", table.concat(beats, ", "))
m0 = mark()
reviveTo(down, 1)
check(count("ReviveBeat", m0) == 0, "... none at completion (the Revive sound is the global one)", names(m0))
m0 = mark()
far:SetAttribute("Downed", true)
reviveTo(far, 0.4)
check(count("ReviveBeat", m0) == 0, "a revive 160 studs away is not heard", names(m0))
me:SetAttribute("Downed", false)
down:SetAttribute("Downed", false)
state:SetAttribute("ChestCost", 40)
state:SetAttribute("TeamRunGold", 100)
wait(0.5)
m0 = mark()
state:SetAttribute("ChestCost", 54)
state:SetAttribute("TeamRunGold", 62)
wait(0.1)
check(count("ChestBuy", m0) == 1, "buying a chest (price steps up, balance drops): one purchase cue", names(m0))
wait(0.5)
m0 = mark()
state:SetAttribute("TeamRunGold", 120) -- kills pay in
wait(0.1)
check(count("ChestBuy", m0) == 0, "gold coming in is silent", names(m0))

------------------------------------------------------------------------------------------
-- 7) crits and shake
------------------------------------------------------------------------------------------
local realPos = EnemyRenderer.Position
EnemyRenderer.Position = function(id)
	if id >= 9001 and id <= 9020 then
		return hero + Vector3.new(8, 0, 0)
	end
	return realPos(id)
end
Settings.Set("ReducedEffects", false)
ClassSfx.ResetLimits()
wait(0.4)
local fx0 = CombatFx.Stats().Started
m0 = mark()
C.fire("FxBatch", { k = { 9001 }, ku = { me.UserId } })
wait(0.05)
local ownParts = CombatFx.Stats().Started - fx0
check(count("CritTick", m0) == 1, "the local hero's own crit plays the crit tick", names(m0))
wait(0.4)
fx0 = CombatFx.Stats().Started
m0 = mark()
C.fire("FxBatch", { k = { 9002 }, ku = { near.UserId } })
wait(0.05)
local otherParts = CombatFx.Stats().Started - fx0
check(count("CritTick", m0) == 0, "a teammate's crit is silent", names(m0))
check(ownParts > otherParts and otherParts > 0, "an own crit draws a bigger burst than a teammate's", string.format("%d vs %d parts", ownParts, otherParts))
wait(0.4)
m0 = mark()
C.fire("FxBatch", { k = { 9003 } }) -- an older server batch without ku
wait(0.05)
check(count("CritTick", m0) == 0, "a batch without ku (nobody's crit) is silent", names(m0))
m0 = mark()
local manyK, manyU = {}, {}
for i = 1, 8 do
	manyK[i], manyU[i] = 9000 + i, me.UserId
end
C.fire("FxBatch", { k = manyK, ku = manyU })
wait(0.05)
check(count("CritTick", m0) == 1, "eight own crits in one batch tick once", names(m0))
wait(0.4)
Settings.Set("ReducedEffects", true)
wait(0.1)
fx0 = CombatFx.Stats().Started
m0 = mark()
C.fire("FxBatch", { k = { 9001 }, ku = { me.UserId } })
wait(0.05)
check(count("CritTick", m0) == 1 and CombatFx.Stats().Started == fx0, "Reduced effects: the crit tick stays, the burst is gone", string.format("%d parts", CombatFx.Stats().Started - fx0))
EnemyRenderer.Position = realPos

-- shake
Settings.Set("ReducedEffects", false)
local function settleShake()
	wait(0.5)
end
settleShake()
CameraController.Shake(2)
local o = CameraController.ShakeState()
check(o.Length < 0.12 and o.Amount <= Config.Camera.OrdinaryShakeMax + 0.001 and o.Amount > 0, "ordinary shake: shorter than 0.12 s and capped", string.format("%.3f s, %.2f studs", o.Length, o.Amount))
wait(0.14)
check(CameraController.ShakeState().Left == 0, "... gone within 0.14 s")
CameraController.Shake(5, "boss")
local b = CameraController.ShakeState()
check(b.Length <= Config.Camera.BossShakeSeconds + 0.001 and b.Length > 0.12 and b.Amount <= Config.Camera.BossShakeMax + 0.001, "boss shake: capped in size and length", string.format("%.3f s, %.2f studs", b.Length, b.Amount))
wait(Config.Camera.BossShakeSeconds + 0.1)
check(CameraController.ShakeState().Left == 0, "... gone within BossShakeSeconds")
CameraController.Shake(0.2)
CameraController.Shake(0.05)
check(CameraController.ShakeState().Amount > 0.15, "a weaker shake does not replace a stronger one")
wait(0.3)
Settings.Set("Shake", 0)
CameraController.Shake(1, "boss")
check(CameraController.ShakeState().Left == 0, "Shake setting 0: no shake")
Settings.Set("Shake", 1)
Settings.Set("ReducedEffects", true)
CameraController.Shake(1, "boss")
check(CameraController.ShakeState().Left == 0, "Reduced effects: no shake")
Settings.Set("ReducedEffects", false)

------------------------------------------------------------------------------------------
-- 8) recoil
------------------------------------------------------------------------------------------
local function rootJoint(): Motor6D?
	local hrp = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	local j = hrp and hrp:FindFirstChild("RootJoint")
	return j and j:IsA("Motor6D") and j or nil
end
local joint = rootJoint()
if joint then
	setClass("ruckus")
	wait(0.3)
	local rest = joint.Transform.Position.Y
	spawnAt(57, hero)
	preview.advance(F.RecoilSeconds * 0.5, 60)
	local peakY = joint.Transform.Position.Y
	preview.advance(F.RecoilSeconds + 0.1, 60)
	local backY = joint.Transform.Position.Y
	check(rest - peakY > F.RecoilSquash * 0.3 and math.abs(backY - rest) < 0.05, "a throw squashes the attacker briefly and it settles", string.format("rest %.3f, peak %.3f, after %.3f", rest, peakY, backY))
	Settings.Set("ReducedEffects", true)
	wait(0.3)
	spawnAt(57, hero)
	preview.advance(F.RecoilSeconds * 0.5, 60)
	check(math.abs(joint.Transform.Position.Y - rest) < 0.05, "Reduced effects: no recoil", string.format("%.3f", joint.Transform.Position.Y))
	Settings.Set("ReducedEffects", false)
else
	preview.log("SKIP recoil: the preview rig has no RootJoint")
end

------------------------------------------------------------------------------------------
-- 9) the switch (Config.Features.ClassSfx): off = the old generic sounds, nothing new plays
------------------------------------------------------------------------------------------
Config.Features.ClassSfx = false
setClass("ruckus")
m0 = mark()
spawnAt(57, hero)
wait(0.1)
ClassSfx.Dash(me.UserId, "Dash", hero)
state:SetAttribute("RunStage", "Rally")
state:SetAttribute("RunStage", "Boss")
me:SetAttribute("Downed", true)
wait(0.1)
me:SetAttribute("Downed", false)
EnemyRenderer.Position = function(id)
	return hero + Vector3.new(8, 0, 0)
end
C.fire("FxBatch", { k = { 9001 }, ku = { me.UserId } })
wait(0.1)
EnemyRenderer.Position = realPos
local quiet = true
for i = m0, #log do
	if log[i].Started and log[i].Name ~= "Throw" and log[i].Name ~= "Hit" then
		quiet = false
	end
end
check(count("Throw", m0) == 1 and quiet, "switch off: the generic throw sound, no class / stage / down / crit cues", names(m0))
Config.Features.ClassSfx = true
state:SetAttribute("RunStage", "Survive")

preview.log(fails == 0 and "class-sfx-regression: all PASS" or string.format("class-sfx-regression: %d FAIL", fails))
