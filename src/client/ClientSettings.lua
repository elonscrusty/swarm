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
		if type(v) == type(default) and dirty[key] == nil and values[key] ~= v then
			values[key] = v
			notify(key, v)
		end
	end
end

-- A change from the settings menu: applied now, saved a moment later.
function ClientSettings.Set(key: string, value: any)
	local default = Config.Settings.Defaults[key]
	if default == nil or type(value) ~= type(default) then
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
		Remotes.Get("SaveSettings"):FireServer(payload)
	end)
end

return ClientSettings
