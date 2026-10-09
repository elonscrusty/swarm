--[[
	Audio.lua
	Sound effects and music from Config.Sounds, mixed by the rules in Config.Audio.

	Hierarchy (so the important sounds always get through a 200-enemy fight):
	  * Every effect belongs to a category (Combat, Pickup, UI, Player, Warning, Boss) with
	    its own SoundGroup under the Effects group, a voice limit and a priority.
	  * At most Config.Audio.MaxVoices effects play at once. A new sound that finds its
	    category or the whole mix full steals the oldest voice of a lower priority, or is
	    dropped when nothing lower is playing. Warnings and the Queen outrank combat noise.
	  * MinGap per sound: the same sound can't restart faster than that (200 deaths are
	    one crunch, not 200).
	  * Ducking: while a Warning or Boss sound plays, the Combat group is turned down.
	  * Crowd ceiling (Config.Audio.Crowd): the more Combat / Pickup sounds start inside a
	    short window, the further those groups fade towards a floor, so a dense swarm is a
	    murmur instead of a wall of clicks; they recover as soon as it thins out.
	  * Pitch variation (Pitch +/- PitchVar) so repeats don't sound mechanical.
	    Sounds with Steps (semitones) pick a note from that scale instead; with Climb, quick
	    repeats walk up the scale (a gem stream rises like a run of chimes), reset after a pause.
	  * Music ducking: sounds with DuckMusic = seconds (level-up, chest, portal, boss roar,
	    victory...) dip the music (Config.Audio.MusicDuck) so the big moments land.
	  * 3D: sounds marked World can be played at a world position (PlayAt): full volume
	    near the hero (the camera is ~78 studs up), quieter far away.
	* Gain (Play / PlayAt third argument): a one-off volume multiplier, so a teammate's class cue
	  (ClassSfx) is the same sound at a lower level.
	* Loops (Config.Sounds entries with Loop = true, Audio.SetLoop): the beacon charge hum. One
	  looping Sound per entry whose volume and speed follow a 0..1 level; not part of the voice mix.
	* Hold (Audio.Hold): skips a named effect for a while (the results fanfare while the run's
	  Victory / Defeat stinger is still playing).
	* Intensity (Audio.SetIntensity, Config.Audio.Music): the music rises by up to IntensityBoost at
	  the Rally / Charge / Boss stages; while it is raised a warning / boss cue dips the music to
	  IntensityDip for its duck, so the louder music never masks a telegraph.
	Music: LobbyMusic / BattleMusic / BossMusic slots (empty Id = silent), looped, in their
	own group. SetMusic crossfades (Config.Audio.Music.Fade) and a track resumes where it
	stopped (Resume), so battle music carries on after a boss instead of restarting.
	Volumes come from the settings (Music / Effects sliders, saved); nothing here changes
	what those sliders mean.
]]

local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local ClientSettings = require(script.Parent.ClientSettings)
local Accessibility = require(script.Parent.Accessibility)

local Audio = {}

local A = Config.Audio
local sfxGroup: SoundGroup
local musicGroup: SoundGroup
local musicDuckGroup: SoundGroup
local musicDuckUntil = 0
local musicDuckDepth = 1 -- the deepest dip of the one running (Audio.DuckMusic)
local musicDuckTween: Tween? = nil
local intensity = 0 -- Audio.SetIntensity, 0..1
local held: { [string]: number } = {} -- Audio.Hold: effect name -> os.clock() until which it is skipped
type Loop = { Sound: Sound, Level: number, On: boolean, Tween: Tween? }
local loops: { [string]: Loop } = {}
local climbStep: { [string]: number } = {}
local groups: { [string]: SoundGroup } = {}
local channels: { [string]: SoundGroup } = {}
local pools: { [string]: { Sound } } = {}
local nextIndex: { [string]: number } = {}
local lastPlayed: { [string]: number } = {}
local musicSounds: { [string]: Sound } = {}
local currentMusic: string? = nil

-- world emitters: invisible anchored parts that carry a 3D Sound each
type Emitter = { Part: BasePart, Sound: Sound, Name: string }
local emitters: { Emitter } = {}
local nextEmitter = 1
local emitterFolder: Folder? = nil

type Voice = { Sound: Sound, Category: string, Priority: number, Ends: number, Keep: boolean? }
local voices: { Voice } = {}

local duckUntil = 0
local ducked = false

-- Defaults for mix rules not (yet) in Config.Audio, so Config stays untouched here.
--   Reserve: voices only critical sounds (priority >= CriticalPriority) may use, so a boss
--            telegraph or the low-HP heartbeat never finds the mix full of pickups.
--   DuckAlso: extra groups turned down (x volume) while a Warning / Boss sound plays.
local RESERVE = A.Reserve or 3
local CRITICAL_PRIORITY = A.CriticalPriority or 4
local DUCK_ALSO: { [string]: number } = A.Duck.Also or { Pickup = 0.6, Player = 0.8 }
local function duckScale(cat: string): number
	if not ducked then
		return 1
	end
	if cat == A.Duck.Target then
		return A.Duck.Volume
	end
	return DUCK_ALSO[cat] or 1
end

-- crowd ceiling: start times of recent Combat / Pickup sounds, current fade per group
local crowdStarts: { number } = {}
local crowdLevel: { [string]: number } = {}
local crowdTween: { [string]: Tween } = {}
local crowdPending = false

-- music crossfades: the running tween per track and where each track was stopped
local musicTweens: { [string]: Tween } = {}
local musicPositions: { [string]: number } = {}

local function categoryOf(def): string
	local cat = def.Category
	if cat and A.Categories[cat] then
		return cat
	end
	return "Combat"
end

local function priorityOf(def): number
	return def.Priority or A.Categories[categoryOf(def)].Priority or 1
end

local function newSound(name: string, def, parent: Instance, group: SoundGroup): Sound
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = def.Id
	s.Volume = def.Volume or 0.5
	s.SoundGroup = group
	s.Parent = parent
	return s
end

function Audio.Init()
	sfxGroup = Instance.new("SoundGroup")
	sfxGroup.Name = "SwarmSFX"
	sfxGroup.Volume = Config.Settings.Defaults.Sfx
	sfxGroup.Parent = SoundService
	musicGroup = Instance.new("SoundGroup")
	musicGroup.Name = "SwarmMusic"
	musicGroup.Volume = Config.Settings.Defaults.Music
	musicGroup.Parent = SoundService
	-- inner group: the settings slider sets musicGroup, ducking only ever touches this one
	musicDuckGroup = Instance.new("SoundGroup")
	musicDuckGroup.Name = "SwarmMusicDuck"
	musicDuckGroup.Volume = 1
	musicDuckGroup.Parent = musicGroup
	for _, name in ipairs({ "Combat", "Interface", "Warning" }) do
		local group = Instance.new("SoundGroup")
		group.Name = "Swarm" .. name
		group.Parent = sfxGroup
		channels[name] = group
	end
	for name, cat in pairs(A.Categories) do
		local g = Instance.new("SoundGroup")
		g.Name = name
		g.Volume = cat.Volume or 1
		g.Parent = channels[cat.Channel or (name == "UI" and "Interface" or (name == "Warning" or name == "Boss") and "Warning" or "Combat")]
		groups[name] = g
	end

	for name, def in pairs(Config.Sounds) do
		if def.Id ~= "" then
			if def.Category == "Music" or string.find(name, "Music") then
				local s = newSound(name, def, SoundService, musicDuckGroup)
				s.Looped = true
				musicSounds[name] = s
			elseif def.Loop then
				local s = newSound(name, def, SoundService, groups[categoryOf(def)])
				s.Looped = true
				s.Volume = 0
				loops[name] = { Sound = s, Level = 0, On = false }
			else
				local cat = categoryOf(def)
				local list = {}
				for i = 1, math.clamp(A.Categories[cat].MaxVoices or 3, 1, 3) do
					list[i] = newSound(name .. i, def, SoundService, groups[cat])
				end
				pools[name] = list
				nextIndex[name] = 1
			end
		end
	end
	Audio.SetVolumes(ClientSettings.Get("Music"), ClientSettings.Get("Sfx"))
	ClientSettings.OnChanged(function(key)
		if key == "Music" or key == "Sfx" or key == "MuteAll" or string.find(key, "Volume") then
			Audio.SetVolumes(ClientSettings.Get("Music"), ClientSettings.Get("Sfx"))
		end
	end)
end

-- Drops voices that have finished (Sound.IsPlaying, or their expected length is over).
local function pruneVoices(now: number)
	for i = #voices, 1, -1 do
		local v = voices[i]
		if now >= v.Ends or not v.Sound.IsPlaying then
			table.remove(voices, i)
		end
	end
end

--[[
	Makes room for a sound of `priority` in `category`: true when it may play (a lower
	priority voice is stopped if the category or the whole mix is full).
]]
local function claimVoice(category: string, priority: number): boolean
	local catMax = A.Categories[category].MaxVoices or 3
	local inCat = 0
	-- non-critical sounds leave RESERVE voices free for warnings
	local mixMax = priority >= CRITICAL_PRIORITY and A.MaxVoices or math.max(1, A.MaxVoices - RESERVE)
	for _, v in ipairs(voices) do
		if v.Category == category then
			inCat += 1
		end
	end
	local catFull = inCat >= catMax
	if not catFull and #voices < mixMax then
		return true
	end
	local victim: number? = nil
	if catFull then
		-- the category is full: its oldest voice of the same or a lower priority gives way
		for i, v in ipairs(voices) do
			if v.Category == category and v.Priority <= priority then
				victim = i
				break
			end
		end
	else
		-- the whole mix is full: the oldest voice of a lower priority gives way
		for i, v in ipairs(voices) do
			if v.Priority < priority then
				victim = i
				break
			end
		end
	end
	if not victim then
		return false
	end
	local v = table.remove(voices, victim) :: Voice
	v.Sound:Stop()
	return true
end

local function setDuck(on: boolean)
	if ducked == on then
		return
	end
	ducked = on
	local targets = { A.Duck.Target }
	for cat in pairs(DUCK_ALSO) do
		table.insert(targets, cat)
	end
	for _, cat in ipairs(targets) do
		local target = groups[cat]
		if target then
			local base = (A.Categories[cat].Volume or 1) * (crowdLevel[cat] or 1)
			if crowdTween[cat] then
				crowdTween[cat]:Cancel()
			end
			-- kept in crowdTween so the next crowd update cancels it (two tweens on one group
			-- would fight over its volume)
			local t = TweenService:Create(target, TweenInfo.new(on and 0.08 or 0.4), { Volume = base * duckScale(cat) })
			crowdTween[cat] = t
			t:Play()
		end
	end
end

--[[
	Crowd ceiling. Counts how many crowd-category sounds started inside the last Window
	seconds and sets each listed group's volume between its base (<= Start sounds) and
	base * Floor (>= Full sounds). Called on every such start and again once the window
	has passed, so the groups come back up by themselves.
]]
local function updateCrowd()
	local C = A.Crowd
	if not C then
		return
	end
	local now = os.clock()
	for i = #crowdStarts, 1, -1 do
		if now - crowdStarts[i] > C.Window then
			table.remove(crowdStarts, i)
		end
	end
	local n = #crowdStarts
	local load = math.clamp((n - C.Start) / math.max(1, C.Full - C.Start), 0, 1)
	local scale = 1 - (1 - C.Floor) * load
	for _, cat in ipairs(C.Categories) do
		local g = groups[cat]
		if g and math.abs((crowdLevel[cat] or 1) - scale) > 0.02 then
			crowdLevel[cat] = scale
			local base = A.Categories[cat].Volume or 1
			if ducked and cat == A.Duck.Target then
				base *= A.Duck.Volume
			end
			if crowdTween[cat] then
				crowdTween[cat]:Cancel()
			end
			local t = TweenService:Create(g, TweenInfo.new(scale < (crowdLevel[cat] or 1) and 0.12 or 0.5), { Volume = base * scale })
			crowdTween[cat] = t
			t:Play()
		end
	end
	if n > 0 and not crowdPending then
		crowdPending = true
		task.delay(C.Window + 0.05, function()
			crowdPending = false
			updateCrowd()
		end)
	end
end

--[[
	Dips the music for `seconds` (Config.Audio.MusicDuck: fast down, slow recovery) to `depth`
	(default MusicDuck.Volume). Overlapping calls extend the dip instead of stacking, and a
	deeper dip wins while they overlap.
]]
function Audio.DuckMusic(seconds: number, depth: number?)
	local D = A.MusicDuck
	if not D or not musicDuckGroup then
		return
	end
	local vol = math.clamp(depth or D.Volume, 0, 1)
	local now = os.clock()
	local untilT = now + seconds
	local wasDucked = musicDuckUntil > now
	local deeper = wasDucked and vol < musicDuckDepth - 0.001
	if untilT <= musicDuckUntil and not deeper then
		return
	end
	musicDuckUntil = math.max(musicDuckUntil, untilT)
	if not wasDucked or deeper then
		musicDuckDepth = wasDucked and math.min(vol, musicDuckDepth) or vol
		if musicDuckTween then
			musicDuckTween:Cancel()
		end
		local t = TweenService:Create(musicDuckGroup, TweenInfo.new(D.Attack), { Volume = musicDuckDepth })
		musicDuckTween = t
		t:Play()
	end
	task.delay(seconds + 0.02, function()
		if os.clock() + 0.01 >= musicDuckUntil and musicDuckGroup then
			if musicDuckTween then
				musicDuckTween:Cancel()
			end
			musicDuckDepth = 1
			local t = TweenService:Create(musicDuckGroup, TweenInfo.new(D.Release, Enum.EasingStyle.Sine), { Volume = 1 })
			musicDuckTween = t
			t:Play()
		end
	end)
end

-- Playback speed for a sound: Steps (a scale, optionally climbing) or Pitch +/- PitchVar.
local function pickSpeed(name: string, def, now: number): number
	local base = def.Pitch or 1
	local steps = def.Steps
	if steps and #steps > 0 then
		local idx
		if def.Climb then
			local last = lastPlayed[name] or -math.huge
			idx = if now - last <= def.Climb then math.min((climbStep[name] or 0) + 1, #steps) else 1
			climbStep[name] = idx
		else
			idx = math.random(1, #steps)
		end
		local jitter = (math.random() * 2 - 1) * (def.PitchVar or 0)
		return base * 2 ^ (steps[idx] / 12) + jitter
	end
	local var = def.PitchVar or A.DefaultPitchVar
	return base + (math.random() * 2 - 1) * var
end

local function startVoice(s: Sound, def, category: string, priority: number, pitch: number?, speed: number?, gain: number?)
	-- A pool slot may still be playing while a different slot finished first.
	-- Restarting that Sound replaces its voice; it cannot count twice against the mix.
	for i = #voices, 1, -1 do
		if voices[i].Sound == s then
			table.remove(voices, i)
		end
	end
	local now = os.clock()
	local var = def.PitchVar or A.DefaultPitchVar
	s.PlaybackSpeed = math.max(0.1, pitch or speed or ((def.Pitch or 1) + (math.random() * 2 - 1) * var))
	s.Volume = (def.Volume or 0.5) * math.clamp(gain or 1, 0, 2)
	s.TimePosition = 0
	s:Play()
	local length = s.TimeLength > 0 and s.TimeLength / s.PlaybackSpeed or 1.5
	table.insert(voices, { Sound = s, Category = category, Priority = priority, Ends = now + math.min(length, 4), Keep = def.Keep == true })
	if A.Crowd and table.find(A.Crowd.Categories, category) then
		table.insert(crowdStarts, now)
		updateCrowd()
	end
	if def.DuckMusic then
		Audio.DuckMusic(def.DuckMusic)
	end
	if table.find(A.Duck.Triggers, category) then
		duckUntil = math.max(duckUntil, now + A.Duck.Seconds)
		setDuck(true)
		local dip = A.Music and A.Music.IntensityDip
		-- (a swarm of fuse ticks does not queue a dip each: skipped while one at least as deep still has 0.4 s to run)
		if intensity > 0 and dip and not (musicDuckDepth <= dip + 0.001 and musicDuckUntil > now + 0.4) then
			Audio.DuckMusic(A.Duck.Seconds + 0.3, dip)
		end
		task.delay(A.Duck.Seconds + 0.05, function()
			if os.clock() >= duckUntil then
				setDuck(false)
			end
		end)
	end
end

-- Gate shared by Play / PlayAt: MinGap, then a voice. Returns the def and its category.
local function gate(name: string): (any, string, number, number)
	local def = Config.Sounds[name]
	if not def then
		return nil, "", 0, 1
	end
	local now = os.clock()
	if def.MinGap and now - (lastPlayed[name] or -math.huge) < def.MinGap then
		return nil, "", 0, 1
	end
	local holdUntil = held[name]
	if holdUntil and now < holdUntil then
		return nil, "", 0, 1
	end
	pruneVoices(now)
	local category = categoryOf(def)
	local priority = priorityOf(def)
	if not claimVoice(category, priority) then
		return nil, "", 0, 1
	end
	local speed = pickSpeed(name, def, now) -- before lastPlayed moves (Climb reads it)
	lastPlayed[name] = now
	return def, category, priority, speed
end

-- Plays an effect (2D). pitch overrides the playback speed (no random variation); gain
-- multiplies its volume once (a teammate's cue). Returns true when it started.
function Audio.Play(name: string, pitch: number?, gain: number?): boolean
	Accessibility.Cue(name, nil)
	local list = pools[name]
	if not list then
		return false
	end
	local def, category, priority, speed = gate(name)
	if not def then
		return false
	end
	local i = nextIndex[name]
	nextIndex[name] = (i % #list) + 1
	startVoice(list[i], def, category, priority, pitch, speed, gain)
	return true
end

local function getEmitter(): Emitter
	if not emitterFolder then
		local f = Instance.new("Folder")
		f.Name = "SwarmAudio"
		f.Parent = workspace
		emitterFolder = f
		for i = 1, A.World.Emitters do
			local p = Instance.new("Part")
			p.Name = "Emitter" .. i
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Transparency = 1
			p.Size = Vector3.new(0.2, 0.2, 0.2)
			p.CFrame = CFrame.new(0, -150, 0)
			p.Parent = f
			local s = Instance.new("Sound")
			s.RollOffMode = Enum.RollOffMode.InverseTapered
			s.RollOffMinDistance = A.World.RollOffMin
			s.RollOffMaxDistance = A.World.RollOffMax
			s.Parent = p
			emitters[i] = { Part = p, Sound = s, Name = "" }
		end
	end
	local e = emitters[nextEmitter]
	nextEmitter = (nextEmitter % #emitters) + 1
	return e
end

--[[
	Plays an effect at a world position (sounds marked World in Config.Sounds; others fall
	back to Play). Telegraph cues use this, so a far-away warning is quieter.
]]
function Audio.PlayAt(name: string, position: Vector3, pitch: number?, gain: number?)
	Accessibility.Cue(name, position)
	local def0 = Config.Sounds[name]
	if not def0 or def0.Id == "" then
		return
	end
	if not def0.World then
		Audio.Play(name, pitch, gain)
		return
	end
	local def, category, priority, speed = gate(name)
	if not def then
		return
	end
	local e = getEmitter()
	local s = e.Sound
	if s.IsPlaying then
		-- this emitter's voice is reused: forget it in the voice list
		for i, v in ipairs(voices) do
			if v.Sound == s then
				table.remove(voices, i)
				break
			end
		end
		s:Stop()
	end
	if e.Name ~= name then
		e.Name = name
		s.Name = name
		s.SoundId = def.Id
	end
	s.SoundGroup = groups[category]
	e.Part.CFrame = CFrame.new(position)
	startVoice(s, def, category, priority, pitch, speed, gain)
end

-- The volume a track settles at: its own Volume, lifted by the stage intensity (SetIntensity).
local function musicTarget(name: string): number
	local def = Config.Sounds[name]
	local boost = (A.Music and A.Music.IntensityBoost) or 0
	return (def and def.Volume or 0.3) * (1 + boost * intensity)
end

local function fadeMusic(name: string, s: Sound, target: number, seconds: number, onDone: (() -> ())?)
	if musicTweens[name] then
		musicTweens[name]:Cancel()
	end
	local t = TweenService:Create(s, TweenInfo.new(math.max(0.05, seconds), Enum.EasingStyle.Linear), { Volume = target })
	musicTweens[name] = t
	t.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			if musicTweens[name] == t then
				musicTweens[name] = nil
			end
			if onDone then
				onDone()
			end
		end
		t:Destroy() -- a cancelled or finished crossfade tween is not kept around
	end)
	t:Play()
end

--[[
	"LobbyMusic" | "BattleMusic" | "BossMusic" | nil. The old track fades out over
	Config.Audio.Music.Fade seconds (and remembers its position), the new one fades in,
	continuing where it last stopped when Resume is on.
]]
function Audio.SetMusic(name: string?)
	if name == currentMusic then
		return
	end
	local M = A.Music or { Fade = 1, Resume = true }
	local old = currentMusic
	if old and musicSounds[old] then
		local s = musicSounds[old]
		musicPositions[old] = s.TimePosition
		fadeMusic(old, s, 0, M.Fade, function()
			if currentMusic ~= old then
				s:Stop()
			end
		end)
	end
	currentMusic = name
	if name and musicSounds[name] then
		local s = musicSounds[name]
		if not s.IsPlaying then
			s.Volume = 0
			s.TimePosition = (M.Resume and musicPositions[name]) or 0
			s:Play()
		end
		fadeMusic(name, s, musicTarget(name), M.Fade)
	end
end

--[[
	Music slots (feature 28, Config.Features.MusicSlots). A slot is a Config.Sounds music
	entry; one with no id of its own plays its Fallback (followed up to 4 steps), so an
	empty slot sounds exactly like before. Returns the track that really plays, or nil.
]]
function Audio.ResolveMusic(name: string?): string?
	local n = name
	for _ = 1, 5 do
		if n == nil or musicSounds[n] then
			return n
		end
		local def = Config.Sounds[n]
		n = def and def.Fallback or nil
	end
	return nil
end

--[[
	The track for the run state: the lobby, the world's slot (state attribute Arena) or the
	boss (phase 2+ = BossPhaseMusic). With MusicSlots off: LobbyMusic / BattleMusic /
	BossMusic as before.
]]
function Audio.RunTrack(inRun: boolean, state: Instance): string?
	if not inRun then
		return "LobbyMusic"
	end
	local boss = (tonumber(state:GetAttribute("BossMaxHP")) or 0) > 0
	if not Config.FeatureOn("MusicSlots") then
		return boss and "BossMusic" or "BattleMusic"
	end
	if boss then
		local phase = tonumber(state:GetAttribute("BossPhase")) or 0
		return Audio.ResolveMusic(phase >= 2 and "BossPhaseMusic" or "BossMusic")
	end
	return Audio.ResolveMusic("WorldMusic_" .. tostring(state:GetAttribute("Arena") or "")) or "BattleMusic"
end

-- Keeps the music on Audio.RunTrack: called once by ClientMain (InRun, boss, phase, world).
function Audio.FollowRun(player: Player, state: Instance)
	local function update()
		Audio.SetMusic(Audio.RunTrack(player:GetAttribute("InRun") == true, state))
	end
	player:GetAttributeChangedSignal("InRun"):Connect(update)
	for _, name in ipairs({ "BossMaxHP", "BossPhase", "Arena" }) do
		state:GetAttributeChangedSignal(name):Connect(update)
	end
	update()
end

-- The track playing (or fading in) now, for tests.
function Audio.CurrentMusic(): string?
	return currentMusic
end

--[[
	Run pressure for the music (0 = calm .. 1 = the boss): the playing track settles up to
	Config.Audio.Music.IntensityBoost louder over IntensityFade seconds. Warnings stay on top: see
	startVoice (the dip). Called by ClassSfx from RunStage; 0 again outside a run.
]]
function Audio.SetIntensity(level: number)
	level = math.clamp(tonumber(level) or 0, 0, 1)
	if math.abs(level - intensity) < 0.001 then
		return
	end
	intensity = level
	local name = currentMusic
	local s = name and musicSounds[name]
	if name and s and s.IsPlaying then
		fadeMusic(name, s, musicTarget(name), (A.Music and A.Music.IntensityFade) or 2)
	end
end

function Audio.Intensity(): number
	return intensity
end

-- Skips the effect `name` for `seconds` (the results fanfare while the run stinger plays).
function Audio.Hold(name: string, seconds: number)
	held[name] = os.clock() + seconds
end

--[[
	A looping effect (Config.Sounds entry with Loop = true): on at `level` (0..1), off with nil / 0.
	The volume goes from Volume x LevelLow up to Volume, the speed from SpeedLow up to SpeedHigh,
	both eased over Fade seconds. Not part of the voice mix, but its group (Stage) is ducked by warnings.
]]
function Audio.SetLoop(name: string, level: number?)
	local L = loops[name]
	local def = Config.Sounds[name]
	if not L or not def then
		return
	end
	local lv = math.clamp(tonumber(level) or 0, 0, 1)
	local fade = math.max(0.05, def.Fade or 0.4)
	local s = L.Sound
	if L.Tween then
		L.Tween:Cancel()
		L.Tween = nil
	end
	if lv <= 0 then
		if L.On then
			L.On = false
			L.Level = 0
			local t = TweenService:Create(s, TweenInfo.new(fade), { Volume = 0 })
			L.Tween = t
			t.Completed:Connect(function(state)
				if state == Enum.PlaybackState.Completed and not L.On then
					s:Stop()
				end
			end)
			t:Play()
		end
		return
	end
	local low = def.LevelLow or 0.4
	local volume = (def.Volume or 0.1) * (low + (1 - low) * lv)
	local speed = (def.SpeedLow or 1) + ((def.SpeedHigh or 1) - (def.SpeedLow or 1)) * lv
	if not L.On or not s.IsPlaying then
		L.On = true
		s.Volume = 0
		s.PlaybackSpeed = speed
		s.TimePosition = 0
		s:Play()
	end
	L.Level = lv
	local t = TweenService:Create(s, TweenInfo.new(fade), { Volume = volume, PlaybackSpeed = speed })
	L.Tween = t
	t:Play()
end

-- For tests: the loops' state { [name] = { On, Level, Playing, Volume, Speed } }.
function Audio.Loops(): { [string]: { On: boolean, Level: number, Playing: boolean, Volume: number, Speed: number } }
	local out = {}
	for name, L in pairs(loops) do
		out[name] = { On = L.On, Level = L.Level, Playing = L.Sound.IsPlaying, Volume = L.Sound.Volume, Speed = L.Sound.PlaybackSpeed }
	end
	return out
end

function Audio.SetVolumes(music: number, sfx: number)
	local muted = ClientSettings.Get("MuteAll") == true
	local master = ClientSettings.MasterVolume() -- [stream L1] Settings > Master volume
	musicGroup.Volume = muted and 0 or math.clamp(music, 0, 1) * master
	sfxGroup.Volume = muted and 0 or math.clamp(sfx, 0, 1) * master
	for name, group in pairs(channels) do
		group.Volume = math.clamp(tonumber(ClientSettings.Get(name .. "Volume")) or 1, 0, 1)
	end
end

-- Stops every effect (run end / travel: no stray warning ticks).
function Audio.StopEffects()
	-- (a run's Victory / Defeat stinger, Keep = true, plays out: the run often ends right after it starts)
	local kept: { Voice } = {}
	for _, v in ipairs(voices) do
		if v.Keep and v.Sound.IsPlaying then
			table.insert(kept, v)
		else
			v.Sound:Stop()
		end
	end
	table.clear(voices)
	for _, v in ipairs(kept) do
		table.insert(voices, v)
	end
	for _, L in pairs(loops) do
		L.On = false
		L.Level = 0
		if L.Tween then
			L.Tween:Cancel()
			L.Tween = nil
		end
		L.Sound.Volume = 0
		L.Sound:Stop()
	end
	setDuck(false)
	musicDuckUntil = 0
	musicDuckDepth = 1
	if musicDuckGroup then
		if musicDuckTween then
			musicDuckTween:Cancel()
			musicDuckTween = nil
		end
		musicDuckGroup.Volume = 1
	end
end

-- For the preview tool / tests: effects playing now (name, category).
function Audio.Voices(): { { Name: string, Category: string } }
	pruneVoices(os.clock())
	local out = {}
	for _, v in ipairs(voices) do
		table.insert(out, { Name = v.Sound.Name, Category = v.Category })
	end
	return out
end

return Audio
