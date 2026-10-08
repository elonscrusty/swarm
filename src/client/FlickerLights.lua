--[[
	FlickerLights.lua (client)
	Torch / brazier lights flicker here, ~10 times a second. MapBuilder only tags the lights
	("SwarmFlickerLight") and stores their FlickerBase / FlickerPhase attributes; writing
	Brightness on the server replicated every change to every player, forever.
	Client-only writes: the server value stays the base brightness.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local FlickerLights = {}

local TAG = "SwarmFlickerLight"
local STEP = 0.1

local lights: { [Light]: { Base: number, Phase: number } } = {}
local started = false

local function add(inst: Instance)
	if inst:IsA("Light") then
		local base = inst:GetAttribute("FlickerBase")
		local phase = inst:GetAttribute("FlickerPhase")
		lights[inst] = {
			Base = type(base) == "number" and base or inst.Brightness,
			Phase = type(phase) == "number" and phase or 0,
		}
	end
end

function FlickerLights.Init()
	if started then
		return
	end
	started = true
	for _, inst in ipairs(CollectionService:GetTagged(TAG)) do
		add(inst)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(add)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(inst)
		lights[inst :: Light] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < STEP then
			return
		end
		acc = 0
		local t = os.clock()
		for light, f in pairs(lights) do
			if light.Parent == nil then
				lights[light] = nil
			else
				light.Brightness = f.Base * (0.86 + 0.09 * math.sin(t * 7.3 + f.Phase) + 0.05 * math.sin(t * 17.9 + f.Phase * 2))
			end
		end
	end)
end

return FlickerLights
