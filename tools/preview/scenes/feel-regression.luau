-- feel-regression: the FEEL features (docs/features/FEEL.md) on the real client over the arena.
--   0) every FEEL switch off: no card, no camera move, no combo line, no hit-stop or burst,
--      the music is the old BattleMusic / BossMusic
--   1) MusicSlots: an empty world slot falls back to BattleMusic, a slot with an id plays,
--      boss phase 2 falls back to BossMusic
--   2) BossIntro solo: name card in the headline lane, the camera slides toward the boss
--      (same angle) for <= 1.2 s and comes back; the world is not paused; phase change card
--   3) BossIntro co-op: no camera move, a zoom + vignette only; Reduced effects: card only
--   4) Announcer: combo counter, reset after ~3 s, one callout per milestone with its sound,
--      a milestone during a headline goes to the notice lane
--   5) HitFeel: death bursts pooled and bounded under stress, hit-stop held <= 40 ms, capped
--      per second, crits only near the hero, off with Reduced effects
-- Prints PASS / FAIL lines.
local A = lib("arena")
local C = lib("common")
local Players = game:GetService("Players")

local Config = C.shared("Config")
-- a real id in one world slot (the lobby track) so a slot with its own track is exercised
Config.Sounds.WorldMusic_Snow.Id = Config.Sounds.LobbyMusic.Id
for _, f in ipairs({ "BossIntro", "Announcer", "HitFeel", "MusicSlots" }) do
	Config.Features[f] = false
end

local headless = preview.args.headless == "on"
local s = A.build({ enemies = 40, seconds = 300 })
local me = Players.LocalPlayer
if headless then
	-- no ClientMain (and no GUI layout, which makes this scene ~50x slower): start the pieces
	-- FEEL needs like ClientMain does, and a stand-in headline renderer (Hud's draws it)
	preview.client("Audio").Init()
	preview.client("CameraController").Init()
	preview.client("EnemyRenderer").Init()
	preview.client("FeatureHud").Init()
	preview.client("UIState").SetRenderer("Headline", function(_item, done)
		task.delay(2, done)
		return function() end
	end)
	preview.client("Audio").FollowRun(me, C.state())
	preview.client("BossIntro").Init()
	preview.client("Announcer").Init()
	preview.client("HitFeel").Init()
end
C.settle(2)
local fails = 0
local function check(ok: boolean, label: string, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

local BossIntro = preview.client("BossIntro")
local Announcer = preview.client("Announcer")
local HitFeel = preview.client("HitFeel")
local Audio = preview.client("Audio")
local UIState = preview.client("UIState")
local Settings = preview.client("ClientSettings")
local EnemyRenderer = preview.client("EnemyRenderer")
local EnemyData = C.shared("EnemyData")
local H = Config.Feel.HitFeel

local root = me.Character and me.Character.PrimaryPart
local hero = root and root.Position or s.centre
local cam = workspace.CurrentCamera

-- a boss body in the enemy folder (EnemyData IsBoss), 40 studs east of the hero
local bossType
for id, def in pairs(EnemyData.Enemies) do
	if def.IsBoss then
		bossType = id
		break
	end
end
local folder = workspace:FindFirstChild("SwarmEnemies")
local bossModel = Instance.new("Model")
bossModel.Name = "BossFake"
local bossBody = Instance.new("Part")
bossBody.Name = "Body"
bossBody.Anchored = true
bossBody.Size = Vector3.new(8, 6, 8)
bossBody.CFrame = CFrame.new(hero.X + 40, Config.ArenaOrigin.Y + 3, hero.Z)
bossBody:SetAttribute("Type", bossType)
bossBody.Parent = bossModel
bossModel.Parent = folder

local function camOffset(): Vector3
	return cam.CFrame.Position - hero
end
local function line(): string
	local gui = me.PlayerGui:FindFirstChild("FeatureHud")
	local l = gui and gui:FindFirstChild("Line", true)
	return (l and l.Visible and l.Text) or ""
end
local function bossArrive(name: string, id: string)
	C.setState({ BossId = id, BossMaxHP = 5000, BossHP = 5000, BossPhase = 0 })
	C.setState({ BossName = name })
	C.setState({ BossPhase = 1 })
end
local function bossGone()
	C.state():SetAttribute("BossName", nil)
	C.setState({ BossMaxHP = 0, BossHP = 0, BossPhase = 0 })
	preview.advance(0.1, 60)
end
local kills = tonumber(me:GetAttribute("Kills")) or 0
local function addKills(n: number)
	kills += n
	me:SetAttribute("Kills", kills)
	preview.advance(0.1, 30)
end
local function huge(dx: number)
	C.fire("FxBatch", { d = { { hero.X + dx, hero.Z, Color3.fromRGB(180, 60, 60), 11 } } })
end

local base = camOffset()

------------------------------------------------------------------------------------------
-- 0) switches off
------------------------------------------------------------------------------------------
C.setState({ Arena = "Forest" })
preview.advance(0.2, 60)
bossArrive("Scorpion Queen", "ScorpionQueen")
preview.advance(0.5, 60)
check(BossIntro.Stats().Cards == 0 and BossIntro.Active() == nil, "off: no boss card, no camera move")
check((camOffset() - base).Magnitude < 0.5, "off: camera where the controller put it", string.format("%.2f", (camOffset() - base).Magnitude))
for _ = 1, 8 do
	addKills(8)
end
check(Announcer.Combo() == 0 and line() == "", "off: no combo line", line())
huge(4)
preview.advance(0.1, 60)
local hs = HitFeel.Stats()
check(hs.Stops == 0 and hs.Bursts == 0 and hs.PoolSize == 0, "off: no hit-stop, no burst, no parts", string.format("stops %d bursts %d pool %d", hs.Stops, hs.Bursts, hs.PoolSize))
check(Audio.CurrentMusic() == "BossMusic", "off: boss music as before", Audio.CurrentMusic())
C.setState({ BossPhase = 2 })
preview.advance(0.2, 60)
check(Audio.CurrentMusic() == "BossMusic" and BossIntro.Stats().Cards == 0, "off: phase 2 changes nothing", Audio.CurrentMusic())
bossGone()
C.setState({ Arena = "Snow" })
preview.advance(0.2, 60)
check(Audio.CurrentMusic() == "BattleMusic", "off: a world slot with an id is ignored", Audio.CurrentMusic())

for _, f in ipairs({ "BossIntro", "Announcer", "HitFeel", "MusicSlots" }) do
	Config.Features[f] = true
end
UIState.Reset("test")

------------------------------------------------------------------------------------------
-- 1) music slots
------------------------------------------------------------------------------------------
C.setState({ Arena = "Snow" }) -- re-read with the switch on
me:SetAttribute("InRun", false)
preview.advance(0.1, 60)
check(Audio.CurrentMusic() == "LobbyMusic", "music: lobby outside a run", Audio.CurrentMusic())
me:SetAttribute("InRun", true)
preview.advance(0.2, 60)
check(Audio.CurrentMusic() == "WorldMusic_Snow", "music: a world slot with an id plays", Audio.CurrentMusic())
C.setState({ Arena = "Forest" })
preview.advance(0.2, 60)
check(Audio.CurrentMusic() == "BattleMusic", "music: an empty world slot falls back to BattleMusic", Audio.CurrentMusic())
check(Audio.ResolveMusic("BossPhaseMusic") == "BossMusic" and Audio.ResolveMusic("Nope") == nil, "music: fallback chain")
base = camOffset()
-- the third-person run camera aims a little above the hero: compare against its own angle
local baseLook = cam.CFrame.LookVector

------------------------------------------------------------------------------------------
-- 2) boss intro, solo
------------------------------------------------------------------------------------------
local frozenBefore = C.state():GetAttribute("Frozen")
C.setState({ Stage = 2 })
bossArrive("Scorpion Queen", "ScorpionQueen")
preview.advance(0.05, 60)
check(BossIntro.Stats().Cards == 1 and UIState.HeadlineSeen("boss.arrive"), "solo: name card in the headline lane (boss.arrive)")
local shown = UIState.HeadlineShowing()
check(shown ~= nil and shown.Id == "boss.arrive" and string.find(shown.Sub or "", "STAGE 2 BOSS", 1, true) ~= nil, "solo: card shows the boss line", shown and shown.Sub)
check(Audio.CurrentMusic() == "BossMusic", "music: boss slot", Audio.CurrentMusic())
preview.advance(0.45, 60)
local off = camOffset() - base
local toBoss = (bossBody.Position - hero) * Vector3.new(1, 0, 1)
check(BossIntro.Active() == "Push" and off.Magnitude > 4 and off:Dot(toBoss) > 0, "solo: camera slides toward the boss", string.format("%.1f studs", off.Magnitude))
check(cam.CFrame.LookVector:Dot(baseLook) > 0.999, "solo: camera angle unchanged (controls stay the same)")
check(UIState.Blocking() == false and C.state():GetAttribute("Frozen") == frozenBefore, "solo: the world is not paused, input free")
preview.advance(0.8, 60) -- 1.3 s after the arrival
check(BossIntro.Active() == nil, "solo: push over within 1.2 s")
preview.advance(0.3, 60)
check((camOffset() - base).Magnitude < 1, "solo: camera back on the hero", string.format("%.2f", (camOffset() - base).Magnitude))
C.setState({ BossPhase = 2 })
preview.advance(0.05, 60)
check(BossIntro.Stats().Cards == 2 and UIState.HeadlineSeen("big:the queen is enraged!"), "phase: card merges with the server's phase banner id")
check(Audio.CurrentMusic() == "BossMusic", "music: phase 2 slot falls back to BossMusic", Audio.CurrentMusic())
preview.advance(1.5, 60)
bossGone()
UIState.Reset("test")

------------------------------------------------------------------------------------------
-- 3) co-op and reduced
------------------------------------------------------------------------------------------
local mate = preview.addPlayer("Mate", 2)
mate:SetAttribute("InRun", true)
mate:SetAttribute("Alive", true)
preview.advance(0.2, 60)
-- the redesign's run camera (CameraController: RunConfig.Camera.FieldOfView in a run)
local runFov = preview.require(game:GetService("ReplicatedStorage").SwarmV2.Run.RunConfig).Camera.FieldOfView
bossArrive("Moth Matriarch", "MothMatriarch")
preview.advance(0.45, 60)
local vg = me.PlayerGui:FindFirstChild("SwarmBossVignette")
check(BossIntro.Active() == "Zoom" and (camOffset() - base).Magnitude < 0.5, "co-op: no camera move", string.format("%.2f", (camOffset() - base).Magnitude))
check(cam.FieldOfView < runFov - 1 and vg ~= nil and vg.Enabled, "co-op: zoom + vignette instead", string.format("fov %.1f", cam.FieldOfView))
preview.advance(1, 60)
check(BossIntro.Active() == nil and math.abs(cam.FieldOfView - runFov) < 0.1 and not (vg and vg.Enabled), "co-op: zoom and vignette end")
bossGone()
mate:SetAttribute("InRun", false)
UIState.Reset("test")
Settings.Set("ReducedEffects", true)
local cardOnly = BossIntro.Stats().CardOnly
bossArrive("Rhino Warlord", "RhinoWarlord")
preview.advance(0.45, 60)
check(BossIntro.Active() == nil and BossIntro.Stats().CardOnly == cardOnly + 1 and UIState.HeadlineSeen("boss.arrive"), "reduced: card only, no camera")
bossGone()
Settings.Set("ReducedEffects", false)
UIState.Reset("test")
preview.advance(2, 30)

------------------------------------------------------------------------------------------
-- 4) announcer
------------------------------------------------------------------------------------------
for _ = 1, 4 do
	addKills(2)
end
check(Announcer.Combo() == 8 and line() == "", "combo: hidden under ShowFrom", line())
for _ = 1, 6 do
	addKills(2)
end
check(string.find(line(), "COMBO", 1, true) ~= nil, "combo: counter shows", line())
for _ = 1, 15 do
	addKills(2)
end
local st = Announcer.Stats()
check(st.Callouts == 1 and string.find(line(), "KILLING SPREE", 1, true) ~= nil, "combo: one callout at 50", line())
local playing = false
for _, v in ipairs(Audio.Voices()) do
	playing = playing or v.Name:find("ComboMilestone") ~= nil
end
check(playing, "combo: milestone sound plays")
for _ = 1, 10 do
	addKills(1)
end
check(Announcer.Stats().Callouts == 1, "combo: no repeat callout for the same milestone")
preview.advance(3.4, 30)
check(Announcer.Combo() == 0 and line() == "", "combo: resets after ~3 s without a kill")
addKills(260) -- crosses 50, 100 and 250 at once: only the highest is called
check(Announcer.Stats().Callouts == 2 and string.find(line(), "UNSTOPPABLE", 1, true) ~= nil, "combo: one callout for several milestones at once", line())
UIState.Headline({ Id = "test.banner", Title = "TEST", Sub = "", Class = "Critical" })
preview.advance(0.1, 30)
addKills(250) -- 510: the 500 milestone while a banner shows
check(Announcer.Stats().Notices == 1 and Announcer.Stats().Callouts == 2, "combo: milestone under a headline goes to the notice lane")
check(line() == "" or UIState.HeadlineShowing() == nil, "combo: counter steps aside for the headline")
me:SetAttribute("Alive", false)
preview.advance(0.1, 30)
check(Announcer.Combo() == 0, "combo: death ends it")
me:SetAttribute("Alive", true)
UIState.Reset("test")
preview.advance(1, 30)

------------------------------------------------------------------------------------------
-- 5) hit feel
------------------------------------------------------------------------------------------
local d = {}
for i = 1, 8 do
	d[i] = { hero.X + math.cos(i) * 8, hero.Z + math.sin(i) * 8, Color3.fromRGB(120, 160, 70), 2.8 }
end
C.fire("FxBatch", { d = d })
preview.advance(1 / 60, 60)
hs = HitFeel.Stats()
check(hs.Bursts == H.BurstsPerBatch and hs.Alive > 0, "burst: chunks fly (BurstsPerBatch per batch)", string.format("bursts %d alive %d", hs.Bursts, hs.Alive))
preview.advance(1.5, 60)
check(HitFeel.Stats().Alive == 0, "burst: chunks gone after their life")
-- hit-stop: a huge kill holds the view
local mover = me.Character and me.Character.PrimaryPart
huge(6)
preview.advance(1 / 60, 60) -- capture frame
local held = cam.CFrame
if mover then
	mover.CFrame = mover.CFrame + Vector3.new(6, 0, 0)
end
preview.advance(1 / 60, 60)
check(HitFeel.Holding() and (cam.CFrame.Position - held.Position).Magnitude < 1e-4, "hit-stop: the view holds")
preview.advance(0.05, 60)
check(not HitFeel.Holding(), "hit-stop: over within 40 ms")
preview.advance(0.2, 60)
check((cam.CFrame.Position - held.Position).Magnitude > 0.05, "hit-stop: the camera follows again")
if mover then
	mover.CFrame = mover.CFrame - Vector3.new(6, 0, 0)
end
preview.advance(1.2, 60)
local before = HitFeel.Stats().Stops
for _ = 1, 20 do
	huge(5)
	preview.advance(0.05, 60)
end
local made = HitFeel.Stats().Stops - before
check(made <= H.MaxPerSecond, "hit-stop: capped per second", made)
preview.advance(1.2, 60)
-- crits: only near the hero (EnemyRenderer.Position stubbed for two fake ids)
local realPos = EnemyRenderer.Position
EnemyRenderer.Position = function(id)
	if id == 9001 then
		return hero + Vector3.new(200, 0, 0)
	elseif id == 9002 then
		return hero + Vector3.new(10, 0, 0)
	end
	return realPos(id)
end
before = HitFeel.Stats().Stops
C.fire("FxBatch", { k = { 9001 } })
preview.advance(0.1, 60)
check(HitFeel.Stats().Stops == before, "hit-stop: a far crit does nothing")
preview.advance(0.5, 60)
C.fire("FxBatch", { k = { 9002 } })
preview.advance(0.05, 60)
check(HitFeel.Stats().Stops == before + 1, "hit-stop: a crit next to the hero")
EnemyRenderer.Position = realPos
preview.advance(1.2, 60)
-- stress: 15 heavy batches a second for 4 s
local peak = 0
for _ = 1, 60 do
	local dd = {}
	for i = 1, 60 do
		dd[i] = { hero.X + math.cos(i) * 12, hero.Z + math.sin(i) * 12, Color3.fromRGB(110, 90, 150), i % 10 == 0 and 6 or 2.8 }
	end
	C.fire("FxBatch", { d = dd })
	preview.advance(1 / 15, 4)
	peak = math.max(peak, HitFeel.Stats().Alive)
end
hs = HitFeel.Stats()
local hf = workspace:FindFirstChild("SwarmHitFeel")
check(peak <= H.MaxPieces and hs.PoolSize <= H.MaxPieces and hf and #hf:GetChildren() == hs.PoolSize, "stress: chunks bounded and pooled", string.format("peak %d pool %d skipped %d", peak, hs.PoolSize, hs.PiecesSkipped))
preview.log(string.format("hitfeel stats: stops %d skipped %d bursts %d pieces %d", hs.Stops, hs.StopsSkipped, hs.Bursts, hs.Pieces))
preview.advance(1.5, 60)
-- reduced effects: no hit-stop, no small-kill bursts
Settings.Set("ReducedEffects", true)
before = HitFeel.Stats().Stops
local bursts = HitFeel.Stats().Bursts
huge(5)
C.fire("FxBatch", { d = d })
preview.advance(0.1, 60)
check(HitFeel.Stats().Stops == before and HitFeel.Stats().Bursts == bursts + 1, "reduced: no hit-stop, only the big kill bursts")
Settings.Set("ReducedEffects", false)
-- leaving the run parks everything
C.fire("FxBatch", { d = d })
preview.advance(1 / 60, 60)
me:SetAttribute("InRun", false)
preview.advance(0.1, 60)
check(HitFeel.Stats().Alive == 0 and BossIntro.Active() == nil and Announcer.Combo() == 0, "run end: everything cleared")

preview.log(fails == 0 and "feel-regression: all PASS" or string.format("feel-regression: %d FAIL", fails))
