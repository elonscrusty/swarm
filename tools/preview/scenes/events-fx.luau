-- events-fx: the client side of MAP EVENTS + WEATHER (src/client/WorldFx.lua,
-- docs/features/EVENTS.md) on the real client over an arena with a swarm. The server's
-- workspace.WorldFx attributes are set by hand (events-regression covers the server).
--   0) switches off: no particles, no badge, no fog filter
--   1) weather: Snow storm = snowfall + SNOW STORM badge + a notice; Reduced effects =
--      a lighter snowfall; Lava = embers; Ruins = motes (off with Reduced effects)
--   2) Meteor: headline (event.meteor, headline lane), countdown badge, a fireball falls
--      onto a marker and is gone after it lands
--   3) Gold rush: headline + badge "GOLD RUSH 60s"
--   4) Fog: enemies far from the hero hidden by the renderer filter (bosses / elites never
--      passed), near ones drawn, the mist fades in; the event ending clears it all
--   5) leaving the run hides everything
-- --set show=snow|lava|meteor|goldrush|fog ends on that state for the render.
-- run: render.sh events-fx --device pc|phone|phone-portrait [--set show=fog]
local A = lib("arena")
local C = lib("common")
local Players = game:GetService("Players")

local show = preview.args.show
local arenaName = (show == "lava" and "Lava") or (show == "snow" and "Snow") or "Ruins"
local F = Instance.new("Folder")
F.Name = "WorldFx"
F.Parent = workspace

local Config = C.shared("Config")
local s = A.build({ arena = arenaName, enemies = 90, seconds = 300 })
C.settle(1.5)
local me = Players.LocalPlayer
local WorldFx = preview.client("WorldFx")
local EnemyRenderer = preview.client("EnemyRenderer")
local Settings = preview.client("ClientSettings")
local UIState = preview.client("UIState")
local fails = 0
local function check(ok: boolean, label: string, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end
local function badge(id: string): string?
	local gui = me.PlayerGui:FindFirstChild("FeatureHud")
	local b = gui and gui:FindFirstChild("Badge_" .. id, true)
	local t = b and b:FindFirstChild("Text")
	return t and t.Text or nil
end
local function headline(id: string): boolean
	local h = UIState.HeadlineShowing()
	return UIState.HeadlineSeen(id) or (h ~= nil and h.Id == id)
end
local function step(t: number)
	preview.advance(t, 30)
end

if not show then
	-- 0) switches off
	Config.Features.Weather = false
	F:SetAttribute("World", "Snow")
	F:SetAttribute("Storm", true)
	step(0.3)
	check(WorldFx.State().Emitter == nil and badge("weather") == nil, "off: no snowfall, no badge")
	F:SetAttribute("World", nil)
	F:SetAttribute("Storm", nil)
	Config.Features.Weather = true
	step(0.2)
end

-- 1) weather ---------------------------------------------------------------------------
F:SetAttribute("World", arenaName == "Ruins" and "Snow" or arenaName)
F:SetAttribute("Storm", arenaName ~= "Lava" or nil)
step(0.5)
if arenaName ~= "Lava" then
	local st = WorldFx.State()
	check(st.Emitter == "Snow" and st.Rate == Config.Weather.Ambient.Snow.Rate, "snow: snowfall", st.Rate)
	check(badge("weather") == "SNOW STORM", "snow: SNOW STORM badge", badge("weather"))
	Settings.Set("ReducedEffects", true)
	step(0.2)
	check(math.abs(WorldFx.State().Rate - Config.Weather.Ambient.Snow.Rate * 0.4) < 0.01, "snow: Reduced effects = lighter", WorldFx.State().Rate)
	Settings.Set("ReducedEffects", false)
	step(0.2)
	if show == "snow" then
		step(3)
		preview.log("show snow")
		return
	end
	F:SetAttribute("Storm", nil)
	F:SetAttribute("World", "Lava")
	step(0.3)
	check(badge("weather") == nil, "snow: badge gone outside a storm")
end
check(WorldFx.State().Emitter == "Embers", "lava: embers", WorldFx.State().Emitter)
if show == "lava" then
	step(3)
	preview.log("show lava")
	return
end
F:SetAttribute("World", "Ruins")
step(0.3)
check(WorldFx.State().Emitter == "Motes", "ruins: motes", WorldFx.State().Emitter)
Settings.Set("ReducedEffects", true)
step(0.2)
check(WorldFx.State().Emitter == nil, "ruins: decoration off with Reduced effects")
Settings.Set("ReducedEffects", false)
step(0.2)

-- 2) meteor ----------------------------------------------------------------------------
local hero = s.centre
F:SetAttribute("MapEvent", "Meteor")
F:SetAttribute("MapEventLeft", 24)
step(0.4)
check(headline("event.meteor"), "meteor: headline lane")
check(badge("mapevent") == "METEORS 24s", "meteor: countdown badge", badge("mapevent"))
local function marker(at: Vector3, land: number)
	local p = Instance.new("Part")
	p.Name = "Meteor"
	p.Anchored = true
	p.Transparency = 1
	p.Size = Vector3.one
	p.CFrame = CFrame.new(at)
	p:SetAttribute("Land", land)
	p.Parent = F
	return p
end
marker(hero + Vector3.new(9, 0, 4), 1.3)
marker(hero + Vector3.new(-12, 0, -6), 1.3)
step(0.5)
check(WorldFx.State().Falling == 2, "meteor: fireballs falling", WorldFx.State().Falling)
if show == "meteor" then
	preview.log("show meteor")
	return
end
step(1.2)
check(WorldFx.State().Falling == 0, "meteor: fireballs gone after impact", WorldFx.State().Falling)

-- 3) gold rush -------------------------------------------------------------------------
F:SetAttribute("MapEvent", "GoldRush")
F:SetAttribute("MapEventLeft", 60)
step(0.4)
check(headline("event.goldrush"), "goldrush: headline")
check(badge("mapevent") == "GOLD RUSH 60s", "goldrush: badge", badge("mapevent"))
if show == "goldrush" then
	step(1)
	preview.log("show goldrush")
	return
end

-- 4) fog -------------------------------------------------------------------------------
-- a second crowd off to the east, mostly beyond the fog radius
A.swarm(s, hero + Vector3.new(75, 0, 0), 30, 300)
step(0.3)
F:SetAttribute("FogRadius", Config.WorldEvents.Fog.Radius)
F:SetAttribute("MapEvent", "Fog")
F:SetAttribute("MapEventLeft", 45)
step(1.3)
local st = WorldFx.State()
check(st.Fog and st.FogAlpha > 0.95, "fog: on, mist faded in", st.FogAlpha)
local filter = EnemyRenderer.HideFilter
local R = Config.WorldEvents.Fog.Radius
local root = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
local here = root and root.Position or hero
check(filter ~= nil and filter(here + Vector3.new(R - 3, 0, 0), false) == false, "fog: near enemy drawn")
check(filter ~= nil and filter(here + Vector3.new(R + 10, 0, 0), false) == true, "fog: far enemy hidden")
check(filter ~= nil and filter(here + Vector3.new(R + 2, 0, 0), true) == false, "fog: hysteresis")
-- the renderer really hides the far ones (models parked, counted as culled)
local far, farShown = 0, 0
local ef = workspace:FindFirstChild("SwarmEnemies")
for _, m in ipairs(ef and ef:GetChildren() or {}) do
	local body = m:FindFirstChild("Body") or (m:IsA("BasePart") and m)
	if body and body:IsA("BasePart") and body:GetAttribute("Elite") ~= true then
		local d = (body.Position - here) * Vector3.new(1, 0, 1)
		if d.Magnitude > R + 8 then
			far += 1
		end
	end
end
local rs = EnemyRenderer.Stats()
preview.log(string.format("fog: far normal enemies %d, renderer live %d on screen %d culled %d", far, rs.live, rs.onScreen, rs.culled))
check(far == 0 or rs.culled >= far * 0.8, "fog: renderer hides the far enemies", string.format("%d of %d", rs.culled, far))
local gui = me.PlayerGui:FindFirstChild("WorldFxFog")
check(gui ~= nil and gui.Enabled and #gui:GetChildren() == 3, "fog: mist rings")
if show == "fog" then
	step(1)
	preview.log("show fog")
	return
end
F:SetAttribute("MapEvent", nil)
F:SetAttribute("MapEventLeft", nil)
F:SetAttribute("FogRadius", nil)
step(1.2)
check(EnemyRenderer.HideFilter == nil and not WorldFx.State().Fog and badge("mapevent") == nil, "fog: cleared when it ends")
check(gui == nil or not gui.Enabled, "fog: mist gone")

-- 5) leave the run ---------------------------------------------------------------------
F:SetAttribute("MapEvent", "GoldRush")
F:SetAttribute("MapEventLeft", 30)
step(0.2)
me:SetAttribute("InRun", false)
step(0.3)
check(badge("mapevent") == nil and badge("weather") == nil and WorldFx.State().Emitter == nil, "left the run: nothing shows")
preview.log(fails == 0 and "PASS events-fx: map event + weather visuals" or string.format("FAIL events-fx: %d check(s) failed", fails))
