--[[
	PortalBeacon.lua
	The stage portal's landmark, client side: ONE pooled beacon that makes the portal
	unmistakable from the moment it is revealed (SwarmState PortalReveal, StageManager):

	  pillar    a tall neon light pillar over the portal with a glowing cap, breathing
	  ring      a pulsing floor ring (two rings of 16 slabs expanding from the rune circle)
	  burst     at the reveal the pillar rises out of the ground and a bright shockwave
	            ring runs out across the floor (skipped with Reduce flashes)

	Colours follow the stage phase like the world portal (arcane while exploring, gold
	while charging / open, crimson during the boss and the surge) through
	Accessibility.Color, so the colorblind palettes apply. Reduced effects (or a slow
	device, ClientPerformance): the pillar and one steady ring, no pulsing, no burst.
	Everything is built once (anchored, no collision / query / touch) and parked when
	there is no portal; the rings move with BulkMoveTo. StageUI calls Update every frame.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Theme = require(Shared:WaitForChild("Theme"))
local ClientSettings = require(script.Parent.ClientSettings)
local ClientPerformance = require(script.Parent.ClientPerformance)
local Accessibility = require(script.Parent.Accessibility)

local PortalBeacon = {}

local player = Players.LocalPlayer
local P = Theme.Palette
local TAU = math.pi * 2
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- a cylinder's axis is X: stand it up

local PILLAR_H = 140
local PILLAR_D = 2.4
local HALO_D = 7
local RING_SLABS = 16
local RING_FROM = Config.Stages.PortalRadius + 0.5
local RING_TO = Config.Stages.PortalRadius + 14
local PULSE_SECONDS = 2.2
local BURST_SECONDS = 1.1
local BURST_RADIUS = 46
local PARK = CFrame.new(0, -400, 0)

local folder: Folder? = nil
local pillar: Part? = nil
local halo: Part? = nil
local cap: Part? = nil
local rings: { { Part } } = {}
local burst: { Part } = {}
local ringCFrames: { CFrame } = {}
local ringParts: { BasePart } = {}
local shown = false
local lastReveal = 0
local burstAt = -math.huge
local pos: Vector3? = nil
local lastColorKey = ""
local lastReduced: boolean? = nil

local function part(name: string, shape: Enum.PartType, size: Vector3, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.CFrame = PARK
	p.Parent = folder
	return p
end

local function build()
	if folder then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "SwarmPortalBeacon"
	f.Parent = workspace
	folder = f
	pillar = part("Pillar", Enum.PartType.Cylinder, Vector3.new(PILLAR_H, PILLAR_D, PILLAR_D), P.fx_arcane, 0.25)
	halo = part("Halo", Enum.PartType.Cylinder, Vector3.new(PILLAR_H * 0.6, HALO_D, HALO_D), P.fx_arcane, 0.84)
	cap = part("Cap", Enum.PartType.Ball, Vector3.new(6, 6, 6), P.ivory_100, 0.15)
	for r = 1, 2 do
		rings[r] = {}
		for i = 1, RING_SLABS do
			local slab = part("Ring", Enum.PartType.Block, Vector3.new(2.2, 0.16, 0.5), P.fx_arcane, 0.3)
			rings[r][i] = slab
			table.insert(ringParts, slab)
		end
	end
	for i = 1, RING_SLABS do
		local slab = part("Burst", Enum.PartType.Block, Vector3.new(4, 0.2, 0.7), P.ivory_100, 1)
		burst[i] = slab
		table.insert(ringParts, slab)
	end
end

local function reduced(): boolean
	return ClientSettings.Reduced() or ClientPerformance.Reduced()
end

-- The beacon's colour for the stage phase (the world portal's palette, colorblind-safe).
local function colorFor(state: Configuration): (Color3, string)
	local phase = state:GetAttribute("StagePhase") or "None"
	if phase == "Boss" or phase == "Surge" then
		return Accessibility.Color(P.crimson_400, "Danger"), "danger"
	elseif phase == "Open" then
		return Accessibility.Color(P.gold_200, "Loot"), "open"
	elseif (state:GetAttribute("PortalCharge") or 0) > 0 then
		return Accessibility.Color(P.gold_300, "Loot"), "charge"
	end
	return Accessibility.Color(P.fx_arcane, "Magic"), "idle"
end

local function park()
	if not shown then
		return
	end
	shown = false
	local list = {}
	local cfs = {}
	for _, p in ipairs(ringParts) do
		table.insert(list, p)
		table.insert(cfs, PARK)
	end
	for _, p in ipairs({ pillar, halo, cap }) do
		if p then
			table.insert(list, p)
			table.insert(cfs, PARK)
		end
	end
	if #list > 0 then
		workspace:BulkMoveTo(list, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end
	pos = nil
	lastColorKey = ""
end

-- Places a ring of slabs at `radius` around `centre` (tangent slabs, like the rune circle).
local function ringAt(slabs: { Part }, centre: Vector3, radius: number, y: number, transparency: number, list: { BasePart }, cfs: { CFrame })
	for i, slab in ipairs(slabs) do
		local a = (i - 0.5) / RING_SLABS * TAU
		local at = Vector3.new(centre.X + math.cos(a) * radius, y, centre.Z + math.sin(a) * radius)
		table.insert(list, slab)
		table.insert(cfs, CFrame.new(at) * CFrame.Angles(0, -a, 0))
		if slab.Transparency ~= transparency then
			slab.Transparency = transparency
		end
	end
end

function PortalBeacon.Update(state: Configuration, inRun: boolean)
	local ppos = state:GetAttribute("PortalPos")
	local reveal = state:GetAttribute("PortalReveal") or 0
	local phase = state:GetAttribute("StagePhase") or "None"
	local on = inRun and typeof(ppos) == "Vector3" and reveal > 0 and phase ~= "Travel" and phase ~= "None"
	if not on then
		lastReveal = inRun and reveal or 0
		park()
		return
	end
	build()
	local now = os.clock()
	local isReduced = reduced()
	if reveal ~= lastReveal then
		-- a new reveal (not a mid-run join: lastReveal is 0 only before the first one)
		if lastReveal ~= 0 or player:GetAttribute("InRun") == true then
			burstAt = ClientSettings.Flashes() and -math.huge or now
		end
		lastReveal = reveal
	end
	shown = true
	pos = ppos
	local base: Vector3 = ppos
	local color, key = colorFor(state)
	if key ~= lastColorKey or isReduced ~= lastReduced then
		lastColorKey, lastReduced = key, isReduced
		for _, p in ipairs(ringParts) do
			if p.Name == "Ring" then
				p.Color = color
			end
		end
		if pillar then pillar.Color = color end
		if halo then halo.Color = color end
		if cap then cap.Color = key == "idle" and P.ivory_100 or color end
	end
	local list: { BasePart } = {}
	local cfs: { CFrame } = {}
	-- the pillar rises at the reveal (0.7 s), then breathes
	local rise = math.clamp((now - burstAt) / 0.7, 0, 1)
	local breathe = isReduced and 0 or math.sin(now * 2.1) * 0.5 + 0.5
	local h = PILLAR_H * rise
	local y = base.Y + 1
	if pillar and halo and cap then
		local size = Vector3.new(math.max(0.1, h), PILLAR_D, PILLAR_D)
		if (pillar.Size - size).Magnitude > 0.05 then
			pillar.Size = size
			halo.Size = Vector3.new(math.max(0.1, h * 0.6), HALO_D, HALO_D)
		end
		table.insert(list, pillar)
		table.insert(cfs, CFrame.new(base.X, y + h / 2, base.Z) * UPRIGHT)
		table.insert(list, halo)
		table.insert(cfs, CFrame.new(base.X, y + h * 0.3, base.Z) * UPRIGHT)
		table.insert(list, cap)
		table.insert(cfs, CFrame.new(base.X, y + h + 2, base.Z))
		local t = 0.22 + breathe * 0.2
		if math.abs(pillar.Transparency - t) > 0.01 then
			pillar.Transparency = t
			halo.Transparency = 0.8 + breathe * 0.08
			cap.Transparency = 0.1 + breathe * 0.25
		end
	end
	-- the floor rings: two pulses running outward, or one steady ring (reduced)
	if isReduced then
		ringAt(rings[1], base, RING_FROM + 1.5, base.Y + 0.12, 0.3, list, cfs)
		ringAt(rings[2], base, RING_FROM + 1.5, base.Y + 0.12, 1, list, cfs)
	else
		for r = 1, 2 do
			local f = ((now / PULSE_SECONDS) + (r - 1) * 0.5) % 1
			local radius = RING_FROM + (RING_TO - RING_FROM) * f
			ringAt(rings[r], base, radius, base.Y + 0.12, 0.2 + f * 0.8, list, cfs)
		end
	end
	-- the reveal shockwave
	local b = (now - burstAt) / BURST_SECONDS
	if b >= 0 and b <= 1 then
		ringAt(burst, base, 2 + BURST_RADIUS * b, base.Y + 0.2, b * b, list, cfs)
	else
		for _, slab in ipairs(burst) do
			if slab.Transparency < 1 then
				slab.Transparency = 1
			end
			table.insert(list, slab)
			table.insert(cfs, PARK)
		end
	end
	workspace:BulkMoveTo(list, cfs, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Leaving a run: park everything (the parts stay pooled for the next run).
function PortalBeacon.Clear()
	lastReveal = 0
	burstAt = -math.huge
	park()
end

-- For the preview tool / tests.
function PortalBeacon.Shown(): boolean
	return shown
end

return PortalBeacon
