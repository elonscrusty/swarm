--[[
	TerrainFx.lua
	Client side of the biome floor hazards (server: BiomeHazards.lua, numbers in
	Config.Arenas.Hazards). The server decides everything that matters (speed, damage);
	this module only adds feel and readability:

	  * Ice: while the player attribute "Terrain" is "Ice" (set by the server), the move
	    input is smoothed (MobileControls.Filter) so turning and stopping drift like on a
	    frozen pond. Off the ice the input goes straight through.
	  * Lava: the warning glow rings around lava pools (parts tagged "SwarmHazardGlow" by
	    MapBuilder) breathe slowly, so the danger reads at a glance.

	Init(MobileControls) is called by MobileControls.Init.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local TerrainFx = {}

local GLOW_TAG = "SwarmHazardGlow"
local H = (Config.Arenas :: any).Hazards or {}
local DRIFT: number = (H.Ice and H.Ice.DriftSeconds) or 0.35

local player = Players.LocalPlayer
local smoothed = Vector3.zero

-- Move input filter (world-space direction, magnitude 0..1).
function TerrainFx.Filter(world: Vector3, dt: number): Vector3
	if player:GetAttribute("Terrain") ~= "Ice" or DRIFT <= 0 then
		smoothed = world
		return world
	end
	local k = 1 - math.exp(-math.max(dt, 0) / DRIFT)
	smoothed = smoothed:Lerp(world, k)
	if smoothed.Magnitude < 0.02 then
		smoothed = Vector3.zero
	end
	return smoothed
end

local glows: { [BasePart]: number } = {} -- part -> base transparency

local function addGlow(inst: Instance)
	if inst:IsA("BasePart") then
		glows[inst] = inst.Transparency
	end
end

function TerrainFx.Init(controls: any?)
	if controls then
		controls.Filter = TerrainFx.Filter
	end
	for _, inst in ipairs(CollectionService:GetTagged(GLOW_TAG)) do
		addGlow(inst)
	end
	CollectionService:GetInstanceAddedSignal(GLOW_TAG):Connect(addGlow)
	CollectionService:GetInstanceRemovedSignal(GLOW_TAG):Connect(function(inst)
		glows[inst :: BasePart] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 1 / 20 then
			return
		end
		acc = 0
		local t = os.clock()
		for p, base in pairs(glows) do
			if p.Parent then
				-- slow breathing: base .. base + 0.3
				p.Transparency = math.clamp(base + 0.15 + 0.15 * math.sin(t * 3.2 + p.Position.X * 0.05), 0, 1)
			else
				glows[p] = nil
			end
		end
	end)
end

return TerrainFx
