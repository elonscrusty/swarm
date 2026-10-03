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
	  * 3D: sounds marked World can be played at a world position (PlayAt): full volume
	    near the hero (the camera is ~78 studs up), quieter far away.
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

type Voice = { Sound: Sound, Category: string, Priority: number, Ends: number }
local voices: { Voice } = {}

local duckUntil = 0
local ducked = false

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
		g.Parent = channels[name == "UI" and "Interface" or (name == "Warning" or name == "Boss") and "Warning" or "Combat"]
		groups[name] = g
	end

	for name, def in pairs(Config.Sounds) do
		if def.Id ~= "" then
			if def.Category == "Music" or string.find(name, "Music") then
				local s = newSound(name, def, SoundService, musicGroup)
				s.Looped = true
				musicSounds[name] = s
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
	for _, v in ipairs(voices) do
		if v.Category == category then
			inCat += 1
		end
	end
	local catFull = inCat >= catMax
	if not catFull and #voices < A.MaxVoices then
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
	local target = groups[A.Duck.Target]
	if target then
		local base = (A.Categories[A.Duck.Target].Volume or 1) * (crowdLevel[A.Duck.Target] or 1)
		if crowdTween[A.Duck.Target] then
			crowdTween[A.Duck.Target]:Cancel()
		end
		-- kept in crowdTween so the next crowd update cancels it (two tweens on one group
		-- would fight over its volume)
		local t = TweenService:Create(target, TweenInfo.new(on and 0.08 or 0.4), { Volume = on and base * A.Duck.Volume or base })
		crowdTween[A.Duck.Target] = t
		t:Play()
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

local function startVoice(s: Sound, def, category: string, priority: number, pitch: number?)
	-- A pool slot may still be playing while a different slot finished first.
	-- Restarting that Sound replaces its voice; it cannot count twice against the mix.
	for i = #voices, 1, -1 do
		if voices[i].Sound == s then
			table.remove(voices, i)
		end
	end
	local now = os.clock()
	local var = def.PitchVar or A.DefaultPitchVar
	local speed = pitch or ((def.Pitch or 1) + (math.random() * 2 - 1) * var)
	s.PlaybackSpeed = math.max(0.1, speed)
	s.TimePosition = 0
	s:Play()
	local length = s.TimeLength > 0 and s.TimeLength / s.PlaybackSpeed or 1.5
	table.insert(voices, { Sound = s, Category = category, Priority = priority, Ends = now + math.min(length, 4) })
	if A.Crowd and table.find(A.Crowd.Categories, category) then
		table.insert(crowdStarts, now)
		updateCrowd()
	end
	if table.find(A.Duck.Triggers, category) then
		duckUntil = math.max(duckUntil, now + A.Duck.Seconds)
		setDuck(true)
		task.delay(A.Duck.Seconds + 0.05, function()
			if os.clock() >= duckUntil then
				setDuck(false)
			end
		end)
	end
end

-- Gate shared by Play / PlayAt: MinGap, then a voice. Returns the def and its category.
local function gate(name: string): (any, string, number)
	local def = Config.Sounds[name]
	if not def then
		return nil, "", 0
	end
	local now = os.clock()
	if def.MinGap and now - (lastPlayed[name] or -math.huge) < def.MinGap then
		return nil, "", 0
	end
	pruneVoices(now)
	local category = categoryOf(def)
	local priority = priorityOf(def)
	if not claimVoice(category, priority) then
		return nil, "", 0
	end
	lastPlayed[name] = now
	return def, category, priority
end

-- Plays an effect (2D). pitch overrides the playback speed (no random variation).
function Audio.Play(name: string, pitch: number?)
	Accessibility.Cue(name, nil)
	local list = pools[name]
	if not list then
		return
	end
	local def, category, priority = gate(name)
	if not def then
		return
	end
	local i = nextIndex[name]
	nextIndex[name] = (i % #list) + 1
	startVoice(list[i], def, category, priority, pitch)
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
function Audio.PlayAt(name: string, position: Vector3, pitch: number?)
	Accessibility.Cue(name, position)
	local def0 = Config.Sounds[name]
	if not def0 or def0.Id == "" then
		return
	end
	if not def0.World then
		Audio.Play(name, pitch)
		return
	end
	local def, category, priority = gate(name)
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
		s.Volume = def.Volume or 0.5
	end
	s.SoundGroup = groups[category]
	e.Part.CFrame = CFrame.new(position)
	startVoice(s, def, category, priority, pitch)
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
		local def = Config.Sounds[name]
		if not s.IsPlaying then
			s.Volume = 0
			s.TimePosition = (M.Resume and musicPositions[name]) or 0
			s:Play()
		end
		fadeMusic(name, s, def and def.Volume or 0.3, M.Fade)
	end
end

function Audio.SetVolumes(music: number, sfx: number)
	local muted = ClientSettings.Get("MuteAll") == true
	musicGroup.Volume = muted and 0 or math.clamp(music, 0, 1)
	sfxGroup.Volume = muted and 0 or math.clamp(sfx, 0, 1)
	for name, group in pairs(channels) do
		group.Volume = math.clamp(tonumber(ClientSettings.Get(name .. "Volume")) or 1, 0, 1)
	end
end

-- Stops every effect (run end / travel: no stray warning ticks).
function Audio.StopEffects()
	for _, v in ipairs(voices) do
		v.Sound:Stop()
	end
	table.clear(voices)
	setDuck(false)
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
