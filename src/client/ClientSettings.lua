--[[
	ClientSettings.lua
	The player's settings on this client (Config.Settings.Defaults: Music, Sfx, Shake,
	ReducedEffects, DamageNumbers, Tips, Minimap) and who wants to know when they change.

	The profile (ProfileSync) is the source: UIBuilder calls Apply(profile.Settings). The
	settings menu calls Set(key, value), which applies at once and saves (debounced:
	one SaveSettings call shortly after the last change, so dragging a slider or tapping
	toggles never runs into the server's rate limit). The server validates every value.

	Readers: Audio (volumes), CameraController (Shake), VFX / Hud (ReducedEffects),
	DamageText (DamageNumbers), Tutorial (Tips), MiniMap (Minimap).
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local ClientSettings = {}

local values: { [string]: any } = table.clone(Config.Settings.Defaults)
local listeners: { (string, any) -> () } = {}
local dirty: { [string]: any } = {}
-- values sent to the server a moment ago: a ProfileSync the server wrote before it
-- received them must not switch the setting back (the server has the new value)
local sent: { [string]: { Value: any, At: number } } = {}
local SENT_GRACE = 5
local saveToken = 0

local SAVE_DELAY = 0.6

local function notify(key: string, value: any)
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn, key, value)
		if not ok then
			warn("[ClientSettings] listener: " .. tostring(err))
		end
	end
end

function ClientSettings.Get(key: string): any
	return values[key]
end

function ClientSettings.Reduced(): boolean
	return values.ReducedEffects == true
end

function ClientSettings.Flashes(): boolean
	return values.ReduceFlashes == true or ClientSettings.Reduced()
end

-- [stream L1] Derived settings. Sliders are stored as 0-1 (Config.ValidateSetting); these map them to what
-- the game reads. 0.5 is "normal" for sensitivity and UI size, so the default changes nothing.
-- Camera: (look multiplier 0.5x..2x, horizontal sign, vertical sign) for CameraController.rotate.
function ClientSettings.CameraTuning(): (number, number, number)
	local v = math.clamp(tonumber(values.CameraSensitivity) or 0.5, 0, 1)
	return 2 ^ ((v - 0.5) * 2), values.InvertCameraX == true and -1 or 1, values.InvertCameraY == true and -1 or 1
end
-- The readout of a sensitivity slider value, e.g. 0.5 -> "1.0x".
function ClientSettings.SensitivityText(v: number): string
	return string.format("%.1fx", 2 ^ ((math.clamp(v, 0, 1) - 0.5) * 2))
end
-- UI size multiplier 0.8x..1.2x (UIBuilder.updateScale and the lobby UI).
function ClientSettings.UIScaleMult(): number
	return 0.8 + 0.4 * math.clamp(tonumber(values.UIScale) or 0.5, 0, 1)
end
function ClientSettings.UIScaleText(v: number): string
	return string.format("%d%%", math.floor((0.8 + 0.4 * math.clamp(v, 0, 1)) * 100 + 0.5))
end
-- Cosmetic effect budget multiplier 0.25..1 (VFX / CombatFx; telegraphs and warnings never use it).
function ClientSettings.EffectsMult(): number
	return 0.25 + 0.75 * math.clamp(tonumber(values.EffectsIntensity) or 1, 0, 1)
end
-- Overall volume 0..1 (Audio.SetVolumes).
function ClientSettings.MasterVolume(): number
	return math.clamp(tonumber(values.MasterVolume) or 1, 0, 1)
end

local function valid(key: string, value: any): boolean
	return Config.ValidateSetting(key, value) ~= nil
end

-- fn(key, value) after every change (also from the profile).
function ClientSettings.OnChanged(fn: (string, any) -> ())
	table.insert(listeners, fn)
end

-- Values from the save (ProfileSync). Unknown keys and wrong types are ignored.
function ClientSettings.Apply(saved: { [string]: any }?)
	if type(saved) ~= "table" then
		return
	end
	for key, default in pairs(Config.Settings.Defaults) do
		local v = saved[key]
		local pending = sent[key]
		if pending and (pending.Value == v or os.clock() - pending.At > SENT_GRACE) then
			sent[key] = nil -- the server echoed it (or the grace ran out): profile values rule again
			pending = nil
		end
		if valid(key, v) and dirty[key] == nil and pending == nil and values[key] ~= v then
			if type(v) == "number" then v = math.clamp(v, 0, 1) end
			values[key] = v
			notify(key, v)
		end
	end
end

-- A change from the settings menu: applied now, saved a moment later.
function ClientSettings.Set(key: string, value: any)
	if not valid(key, value) then
		return
	end
	if type(value) == "number" then
		value = math.clamp(value, 0, 1)
	end
	if values[key] ~= value then
		values[key] = value
		notify(key, value)
	end
	dirty[key] = value
	saveToken += 1
	local token = saveToken
	task.delay(SAVE_DELAY, function()
		if token ~= saveToken or next(dirty) == nil then
			return
		end
		local payload = dirty
		dirty = {}
		local now = os.clock()
		for k, v in pairs(payload) do
			sent[k] = { Value = v, At = now }
		end
		Remotes.Get("SaveSettings"):FireServer(payload)
	end)
end

return ClientSettings
