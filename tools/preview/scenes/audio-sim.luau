-- audio-sim: exercises client Audio.lua headlessly (sounds are silent in the mock): a dense
-- swarm burst (hits, deaths, gems, coins as the server would send them) must stay inside
-- the voice caps and pull the Combat / Pickup groups down to the crowd floor, then recover;
-- a warning must duck Combat; music must crossfade lobby -> battle -> boss -> battle and
-- resume the battle track where it stopped. Prints PASS / FAIL lines.
--   render.sh audio-sim --devices pc
local C = lib("common")
local SoundService = game:GetService("SoundService")
preview.forceMeshesUploaded()
C.lobby({})
C.startClient()
preview.advance(0.5)
local Audio = C.try("require Audio", preview.client, "Audio")
local Config = C.shared("Config")
if not Audio then
	return
end
if preview.args.headless == "on" then Audio.Init() end

local fails = 0
local function check(ok: boolean, label: string, detail: string?)
	if not ok then
		fails += 1
	end
	preview.log(string.format("%s %s%s", ok and "PASS" or "FAIL", label, detail and (" (" .. detail .. ")") or ""))
end

local sfx = SoundService:FindFirstChild("SwarmSFX")
local function group(name: string): SoundGroup?
	return sfx and sfx:FindFirstChild(name, true) :: SoundGroup?
end
local function groupVolume(name: string): number
	local g = group(name)
	return g and g.Volume or -1
end

-- every configured sound id is an rbxasset or a numeric rbxassetid (never a guess)
local badIds = {}
for name, def in pairs(Config.Sounds) do
	if def.Id ~= "" and not (string.match(def.Id, "^rbxasset://") or string.match(def.Id, "^rbxassetid://%d+$")) then
		table.insert(badIds, name)
	end
end
check(#badIds == 0, "sound ids are rbxasset:// or rbxassetid://<digits>", table.concat(badIds, ","))

-- 1. a dense burst: 30 FxBatch ticks (one Hit each), 60 deaths, 40 gems, 20 coins in 1 s
local combatBase = Config.Audio.Categories.Combat.Volume
local pickupBase = Config.Audio.Categories.Pickup.Volume
local peakVoices = 0
local minCombat, minPickup = math.huge, math.huge
for tick = 1, 30 do
	Audio.Play("Hit")
	Audio.Play("EnemyDeath")
	Audio.Play("EnemyDeath")
	if tick % 2 == 0 then
		Audio.Play("GemPickup")
		Audio.Play("GemPickup")
		Audio.Play("Coin")
	end
	if tick % 10 == 0 then
		Audio.Play("Lightning")
		Audio.PlayAt("Explosion", Vector3.new(tick, 2, 0))
	end
	preview.advance(1 / 30)
	peakVoices = math.max(peakVoices, #Audio.Voices())
	minCombat = math.min(minCombat, groupVolume("Combat"))
	minPickup = math.min(minPickup, groupVolume("Pickup"))
end
check(peakVoices <= Config.Audio.MaxVoices, "voices stay under MaxVoices", string.format("peak %d / %d", peakVoices, Config.Audio.MaxVoices))
local floor = Config.Audio.Crowd.Floor
check(minCombat < combatBase * 0.75, "crowd ceiling pulls Combat down", string.format("min %.2f of base %.2f, floor %.2f", minCombat, combatBase, combatBase * floor))
check(minPickup < pickupBase * 0.75, "crowd ceiling pulls Pickup down", string.format("min %.2f of base %.2f", minPickup, pickupBase))
check(minCombat >= combatBase * floor - 0.02, "Combat never below the floor", string.format("%.2f", minCombat))
preview.advance(Config.Audio.Crowd.Window + 1.2)
check(math.abs(groupVolume("Combat") - combatBase) < 0.03, "Combat recovers after the swarm", string.format("%.2f", groupVolume("Combat")))
check(math.abs(groupVolume("Pickup") - pickupBase) < 0.03, "Pickup recovers after the swarm", string.format("%.2f", groupVolume("Pickup")))

-- 2. MinGap: 20 Hit calls in one frame are one voice
Audio.StopEffects()
for _ = 1, 20 do
	Audio.Play("Hit")
end
local hits = 0
for _, v in ipairs(Audio.Voices()) do
	if v.Name:match("^Hit") then
		hits += 1
	end
end
check(hits == 1, "MinGap collapses a burst of Hit to one voice", tostring(hits))

-- 3. ducking: a warning turns Combat down, then it comes back
Audio.PlayAt("FuseTick", Vector3.new(0, 2, 0))
preview.advance(0.15)
check(groupVolume("Combat") < combatBase * 0.6, "warning ducks Combat", string.format("%.2f", groupVolume("Combat")))
preview.advance(Config.Audio.Duck.Seconds + 0.6)
check(math.abs(groupVolume("Combat") - combatBase) < 0.03, "Combat returns after the duck", string.format("%.2f", groupVolume("Combat")))

-- 4. music: crossfade and resume
local function music(name: string): Sound?
	return SoundService:FindFirstChild(name) :: Sound?
end
local fade = Config.Audio.Music.Fade
local lobby, battle, boss = music("LobbyMusic"), music("BattleMusic"), music("BossMusic")
check(lobby ~= nil and battle ~= nil and boss ~= nil, "three music slots are filled")
if lobby and battle and boss then
	Audio.SetMusic("LobbyMusic")
	preview.advance(fade + 0.2)
	check(lobby.IsPlaying and math.abs(lobby.Volume - Config.Sounds.LobbyMusic.Volume) < 0.02, "lobby music fades in", string.format("%.2f", lobby.Volume))
	Audio.SetMusic("BattleMusic")
	preview.advance(fade * 0.4)
	check(lobby.IsPlaying and battle.IsPlaying and lobby.Volume < Config.Sounds.LobbyMusic.Volume and battle.Volume > 0, "lobby and battle overlap mid-fade", string.format("lobby %.2f battle %.2f", lobby.Volume, battle.Volume))
	preview.advance(fade)
	check(not lobby.IsPlaying, "lobby music stopped after the fade")
	battle.TimePosition = 42 -- pretend the run has been going for a while
	Audio.SetMusic("BossMusic")
	preview.advance(fade + 0.2)
	check(boss.IsPlaying and not battle.IsPlaying, "boss music replaces battle")
	Audio.SetMusic("BattleMusic")
	preview.advance(0.05)
	check(battle.IsPlaying and math.abs(battle.TimePosition - 42) < 1, "battle music resumes where it stopped", string.format("%.1f", battle.TimePosition))
	preview.advance(fade + 0.2)
	check(not boss.IsPlaying, "boss music stopped after the fade")
	-- 5. music ducks under a big moment (LevelUp has DuckMusic) and comes back
	local duck = SoundService:FindFirstChild("SwarmMusicDuck", true) :: SoundGroup?
	check(duck ~= nil and battle.SoundGroup == duck, "music plays through the duck group")
	if duck and Config.Audio.MusicDuck and Config.Sounds.LevelUp.DuckMusic then
		Audio.Play("LevelUp")
		preview.advance(Config.Audio.MusicDuck.Attack + 0.1)
		check(math.abs(duck.Volume - Config.Audio.MusicDuck.Volume) < 0.05, "LevelUp ducks the music", string.format("%.2f", duck.Volume))
		preview.advance(Config.Sounds.LevelUp.DuckMusic + Config.Audio.MusicDuck.Release + 0.3)
		check(math.abs(duck.Volume - 1) < 0.03, "music recovers after the duck", string.format("%.2f", duck.Volume))
	end
	Audio.SetMusic(nil)
	preview.advance(fade + 0.2)
	check(not battle.IsPlaying, "SetMusic(nil) fades everything out")
end

-- 6. gem chimes climb their scale on quick repeats and reset after a pause
local gem = Config.Sounds.GemPickup
if gem.Steps and gem.Climb then
	Audio.StopEffects()
	local speeds = {}
	for i = 1, 4 do
		Audio.Play("GemPickup")
		local best = 0
		for _, s in ipairs(SoundService:GetChildren()) do
			if s:IsA("Sound") and s.Name:match("^GemPickup") and s.IsPlaying then
				best = math.max(best, s.PlaybackSpeed)
			end
		end
		speeds[i] = best
		preview.advance(math.max(gem.MinGap or 0, 0.05) + 0.02)
	end
	check(speeds[4] > speeds[1] * 1.15, "quick gem pickups climb the scale", string.format("%.2f -> %.2f", speeds[1], speeds[4]))
	preview.advance(gem.Climb + 0.5)
	Audio.StopEffects()
	Audio.Play("GemPickup")
	local first = 0
	for _, s in ipairs(SoundService:GetChildren()) do
		if s:IsA("Sound") and s.Name:match("^GemPickup") and s.IsPlaying then
			first = math.max(first, s.PlaybackSpeed)
		end
	end
	check(math.abs(first - (gem.Pitch or 1)) < 0.03, "the climb resets after a pause", string.format("%.2f", first))
end

preview.log(fails == 0 and "audio-sim: all PASS" or string.format("audio-sim: %d FAIL", fails))
