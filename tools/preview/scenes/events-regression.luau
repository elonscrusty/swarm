-- events-regression: MAP EVENTS (feature 2) and WEATHER (feature 9) on the REAL server and
-- client (docs/features/EVENTS.md). Every check prints PASS / FAIL; the last line sums up.
--   0) both switches off: no attributes, no weather mult, no ambient, GoldChance untouched
--   1) Snow storm: players and walking enemies x the Snow mults, no ambient slot taken,
--      cleanup on stage end puts every speed back
--   2) Lava: fire patches erupt (telegraphed: harmless Arm seconds), burn players / enemies
--   3) Meteor shower: warning >= 1.2 s, impacts hurt the player and enemies, no kill gold,
--      fall markers for the clients
--   4) Gold rush: kill-gold chance x2 capped at MaxChance, never lowered, ends after 60 s
--   5) Fog: attributes for the clients, ends when the boss phase starts
--   6) director: map events take the ambient slot, weather never does; travel + run end
--      clean up everything (attributes, hazards, markers)
-- Server only (headless); the client side is events-fx.
-- run: render.sh events-regression --studio --device pc --max-time 400 --set headless=on
local C = lib("common")
local Players = game:GetService("Players")
preview.forceMeshesUploaded()
preview.startServer()
preview.advance(1)
C.startClient()
preview.advance(1)
local me = Players.LocalPlayer
local RM = preview.server("RunManager")
local SM = preview.server("StageManager")
local ES = preview.server("EnemySpawner")
local EAI = preview.server("EnemyAI")
local ED = preview.server("EncounterDirector")
local WE = preview.server("WorldEvents")
local WX = preview.server("Weather")
local Config = C.shared("Config")
local advance = preview.advance

local fails = 0
local function check(ok: boolean, label: string, detail: any?)
	if not ok then
		fails += 1
	end
	preview.log((ok and "PASS " or "FAIL ") .. label .. (detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

local function levelUps()
	for _ = 1, 30 do
		if not me:GetAttribute("Paused") then
			return
		end
		preview.remote("LevelUpChoose"):FireServer(1)
		advance(0.3)
	end
end

-- damage the player took, by cause (HP kept topped up so the run goes on)
local taken: { [string]: number } = {}
local realDamage = RM.DamagePlayer
RM.DamagePlayer = function(rp, amount, cause)
	local before = rp.HP
	realDamage(rp, amount, cause)
	if rp.HP and before and rp.HP < before then
		taken[cause or "?"] = (taken[cause or "?"] or 0) + (before - rp.HP)
	end
	rp.HP = rp.MaxHP or rp.HP
end

local F = workspace:WaitForChild("WorldFx")

-- re-run the director's stage start on the live arena as world `name`, stage `n`
local live: any = nil -- the run's real arena + portal (kept across our StageEnd calls)
local function asWorld(name: string, n: number)
	local i = ED.Stage() or live
	live = { Arena = i.Arena, PortalPos = i.PortalPos }
	ED.StageStart(live.Arena, n, live.PortalPos, name)
	advance(0.3)
end

local function spawnRing(count: number, centre: Vector3, r: number, typeId: string?): { any }
	local out = {}
	for k = 1, count do
		local a = k / count * math.pi * 2
		local e = ES.Spawn(typeId or "Slime", centre + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r), { Force = true })
		if e then
			table.insert(out, e)
		end
	end
	return out
end

local function standAt(rp, pos: Vector3)
	rp.HP = rp.MaxHP or rp.HP -- (contact hits go around the DamagePlayer wrapper)
	local root = rp.Root
	if root then
		root.CFrame = CFrame.new(pos + Vector3.new(0, 3, 0))
		rp.LastValidPos = root.Position
		rp.SpeedCheckTimer = 0
	end
end

-- 0) switches off ---------------------------------------------------------------------
Config.Features.MapEvents = false
Config.Features.Weather = false
preview.remote("StartRun"):FireServer("Solo")
advance(2)
levelUps()
local rp = RM.GetRunPlayer(me)
if not rp then
	preview.log("FAIL: no run player")
	return
end
local centre = Vector3.new(Config.ArenaOrigin.X, Config.ArenaOrigin.Y, Config.ArenaOrigin.Z)
standAt(rp, centre)
asWorld("Snow", 3)
advance(1)
check(F:GetAttribute("World") == nil and F:GetAttribute("MapEvent") == nil, "off: no WorldFx attributes")
check(rp.WeatherSpeedMult == nil and EAI.WorldSpeedMult == 1, "off: no speed change")
check(WE.GoldChance(0.25) == 0.25, "off: kill-gold chance untouched")
check(WE.Force("GoldRush") == false, "off: a map event cannot be forced")
Config.Features.MapEvents = true
Config.Features.Weather = true

-- 1) Snow storm -------------------------------------------------------------------------
asWorld("Snow", 3)
advance(0.5)
local S = Config.Weather.Snow
check(WX.World() == "Snow" and F:GetAttribute("Storm") == true, "snow: world set", WX.World())
check(rp.WeatherSpeedMult == S.PlayerSpeed, "snow: player mult", rp.WeatherSpeedMult)
local hum = rp.Humanoid
local expect = rp.Stats.Speed * (rp.TerrainSpeedMult or 1) * (rp.RushMult or 1) * S.PlayerSpeed
check(hum and math.abs(hum.WalkSpeed - expect) < 0.01, "snow: WalkSpeed slowed", hum and hum.WalkSpeed)
check(EAI.WorldSpeedMult == S.EnemySpeed, "snow: enemy mult", EAI.WorldSpeedMult)
check(not ED.IsActive("Weather"), "snow: weather takes no ambient slot")
advance(0.5)
advance(0.2)
ED.StageEnd("Travel")
advance(0.2)
check(rp.WeatherSpeedMult == nil and EAI.WorldSpeedMult == 1 and F:GetAttribute("World") == nil, "snow: travel cleans up")
check(hum and math.abs(hum.WalkSpeed - rp.Stats.Speed * (rp.TerrainSpeedMult or 1) * (rp.RushMult or 1)) < 0.01, "snow: speed back", hum and hum.WalkSpeed)

-- 2) Lava eruptions --------------------------------------------------------------------
asWorld("Lava", 3)
local w0 = WX.Stats()
local L = Config.Weather.Lava
for _ = 1, math.ceil(L.FirstAfter + L.Every[2] + 2) do
	advance(1)
	levelUps()
	standAt(rp, centre)
end
local w1 = WX.Stats()
check(w1.Eruptions > w0.Eruptions and w1.Patches >= w0.Patches + L.Patches, "lava: eruptions", w1.Eruptions - w0.Eruptions)
check(L.Arm >= 1.2, "lava: patches glow at least 1.2 s before they burn", L.Arm)
check(w1.EnemyBurns >= 0, "lava: enemy burns counted", w1.EnemyBurns)
preview.log(string.format("lava damage taken standing still: %.0f", taken["Lava eruption"] or 0))

-- 3) Meteor shower ---------------------------------------------------------------------
asWorld("Ruins", 3)
local M = Config.WorldEvents.Meteor
check(M.Warn >= 1.2, "meteor: warning ring >= 1.2 s", M.Warn)
check(WE.Force("Meteor") == true and ED.IsActive("MapEvents"), "meteor: started in the ambient slot")
check(F:GetAttribute("MapEvent") == "Meteor", "meteor: attribute")
advance(0.3)
local e0 = WE.Stats()
local gold0 = rp.Gold
local victims = spawnRing(10, centre + Vector3.new(30, 0, 0), 3)
-- an impact right on the enemies (the shower aims near players; this one is placed)
local hits = WE.HurtEnemies(centre + Vector3.new(30, 0, 0), M.Radius, 1.01, 1.01)
check(hits >= 8, "meteor: enemies inside the circle are hit", hits)
local dead = 0
for _, e in ipairs(victims) do
	if not e.Alive then
		dead += 1
	end
end
check(dead >= 8 and rp.Gold == gold0, "meteor: kills by a meteor give no kill gold", string.format("dead %d gold +%d", dead, rp.Gold - gold0))
local markers = 0
for t = 1, 8 do
	advance(1)
	levelUps()
	standAt(rp, centre)
	markers = math.max(markers, WE.MarkerCount())
end
local e1 = WE.Stats()
check(e1.Volleys > e0.Volleys and e1.Impacts > e0.Impacts, "meteor: volleys land", string.format("volleys %d impacts %d", e1.Volleys - e0.Volleys, e1.Impacts - e0.Impacts))
check(markers > 0, "meteor: markers in WorldFx", markers)
preview.log(string.format("meteor damage taken in 8 s standing still: %.0f", taken.Meteor or 0))
-- the boss phase ends it at once
ED.StageEnd("Travel")
advance(0.2)
check(F:GetAttribute("MapEvent") == nil and WE.MarkerCount() == 0 and WE.Current() == nil, "meteor: travel cleans up")

rp.InvulnUntil = math.huge -- (the long waits below: the swarm must not end the run)

-- 4) Gold rush -----------------------------------------------------------------------
asWorld("Forest", 3)
check(WE.Force("GoldRush"), "goldrush: started")
local G = Config.WorldEvents.GoldRush
check(WE.GoldChance(0.25) == math.min(0.25 * G.ChanceMult, G.MaxChance), "goldrush: chance x mult", WE.GoldChance(0.25))
check(WE.GoldChance(0.375) == G.MaxChance, "goldrush: capped (wave kills)", WE.GoldChance(0.375))
check(WE.GoldChance(0.9) == 0.9, "goldrush: never lowers a chance")
advance(1.2)
for _ = 1, G.Seconds + 40 do -- (level-up choices freeze the run, and the event with it)
	advance(1)
	levelUps()
	standAt(rp, centre)
	if WE.Current() == nil then
		break
	end
end
check(WE.Current() == nil and WE.GoldChance(0.25) == 0.25 and not ED.IsActive("MapEvents"), "goldrush: ends after its time", WE.Current())
check(F:GetAttribute("MapEvent") == nil and F:GetAttribute("MapEventLeft") == nil, "goldrush: attributes cleared")

-- 5) Fog -------------------------------------------------------------------------------
check(WE.Force("Fog"), "fog: started")
advance(1)
check(F:GetAttribute("MapEvent") == "Fog" and F:GetAttribute("FogRadius") == Config.WorldEvents.Fog.Radius, "fog: attributes (radius)")
-- the boss phase ends it
local bossOk = SM.DevActivate and SM.DevActivate()
for _ = 1, 20 do
	advance(0.5)
	levelUps()
	if SM.GetPhase() ~= "Explore" then
		break
	end
end
advance(1.5)
check(SM.GetPhase() == "Explore" or WE.Current() == nil, "fog: ends when the boss phase starts", SM.GetPhase() .. " / " .. tostring(bossOk))
check(SM.GetPhase() == "Explore" or F:GetAttribute("FogRadius") == nil, "fog: radius cleared")

-- 6) run end ----------------------------------------------------------------------------
preview.remote("AbandonRun"):FireServer()
advance(2)
check(F:GetAttribute("MapEvent") == nil and F:GetAttribute("World") == nil and EAI.WorldSpeedMult == 1, "run end: everything cleared")
check(not ED.IsActive("MapEvents") and WE.MarkerCount() == 0, "run end: director slot free")
local damage = {}
for k, v in pairs(taken) do
	table.insert(damage, string.format("%s=%.0f", k, v))
end
table.sort(damage)
preview.log("damage taken by cause: " .. table.concat(damage, " "))
preview.log(fails == 0 and "PASS events-regression: map events + weather" or string.format("FAIL events-regression: %d check(s) failed", fails))
