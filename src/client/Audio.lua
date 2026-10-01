--[[
	Audio.lua
	Plays sound effects and music from Config.Sounds. Each effect has a small pool of
	Sound instances and a minimum gap so 200 enemies dying can't make 200 sounds.
	Volumes come from the pause-menu sliders (saved in the profile).
]]

local SoundService = game:GetService("SoundService")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

local Audio = {}

local POOL = 3
local sfxGroup: SoundGroup
local musicGroup: SoundGroup
local pools: { [string]: { Sound } } = {}
local nextIndex: { [string]: number } = {}
local lastPlayed: { [string]: number } = {}
local musicSounds: { [string]: Sound } = {}
local currentMusic: string? = nil

function Audio.Init()
	sfxGroup = Instance.new("SoundGroup")
	sfxGroup.Name = "SwarmSFX"
	sfxGroup.Volume = 0.8
	sfxGroup.Parent = SoundService
	musicGroup = Instance.new("SoundGroup")
	musicGroup.Name = "SwarmMusic"
	musicGroup.Volume = 0.6
	musicGroup.Parent = SoundService

	for name, def in pairs(Config.Sounds) do
		if def.Id ~= "" then
			if string.find(name, "Music") then
				local s = Instance.new("Sound")
				s.Name = name
				s.SoundId = def.Id
				s.Volume = def.Volume or 0.5
				s.Looped = true
				s.SoundGroup = musicGroup
				s.Parent = SoundService
				musicSounds[name] = s
			else
				local list = {}
				for i = 1, POOL do
					local s = Instance.new("Sound")
					s.Name = name .. i
					s.SoundId = def.Id
					s.Volume = def.Volume or 0.5
					s.SoundGroup = sfxGroup
					s.Parent = SoundService
					list[i] = s
				end
				pools[name] = list
				nextIndex[name] = 1
			end
		end
	end
end

function Audio.Play(name: string, pitch: number?)
	local list = pools[name]
	if not list then
		return
	end
	local def = Config.Sounds[name]
	local now = os.clock()
	if def.MinGap and now - (lastPlayed[name] or 0) < def.MinGap then
		return
	end
	lastPlayed[name] = now
	local i = nextIndex[name]
	nextIndex[name] = (i % #list) + 1
	local s = list[i]
	s.PlaybackSpeed = pitch or (0.95 + math.random() * 0.1)
	s.TimePosition = 0
	s:Play()
end

-- "LobbyMusic" | "BattleMusic" | "BossMusic" | nil
function Audio.SetMusic(name: string?)
	if name == currentMusic then
		return
	end
	if currentMusic and musicSounds[currentMusic] then
		musicSounds[currentMusic]:Stop()
	end
	currentMusic = name
	if name and musicSounds[name] then
		musicSounds[name]:Play()
	end
end

function Audio.SetVolumes(music: number, sfx: number)
	musicGroup.Volume = math.clamp(music, 0, 1)
	sfxGroup.Volume = math.clamp(sfx, 0, 1)
end

return Audio
