--[[
	CombatFx.lua
	Combat "juice" on top of VFX.lua: short, bright accents that make hits, kills and
	milestones read at a glance. Nothing here affects gameplay; VFX (and the Inventory /
	SwarmState listeners below) call in, this module only draws.

	* Impact star: two crossed ivory blades that snap open and vanish on a sparked hit.
	* Crit star (FxBatch "k", Fx.Crit): a larger gold star with sparks.
	* Kill shards: a white pop and colour-matched shards bursting out of a dead enemy.
	  Big kills (elites, large creatures) add radial streaks and a floor flash; huge kills
	  (bosses, large elites) add a short camera kick (the "hit-stop" punch) and a sound.
	* Swing glint: a few sparks flung off the blade tip as a sword swing ends.
	* Level-up: a gold pillar of light with spiralling motes (the ring is VFX's).
	* Evolution: a white-gold flash, radial rays, a pillar and a gold screen-edge glow when
	  one of the local hero's weapons evolves (seen in the Inventory remote).
	* Pickup sparkle: a small star when a floor pickup next to the local hero is taken.
	* Boss phase change: a crimson screen-edge flash and a camera kick (SwarmState BossPhase).

	Budget (Config.Graphics.CombatFx): its own pooled parts (no Instance churn once warm,
	never a light), at most MaxParts alive, new parts drawn from a token bucket
	(PartsPerSecond, Burst per frame); slow frames shrink the budget; effects far from the
	hero use fewer parts or none. Everything that does not fit is skipped, not queued.
	Reduced effects: only the milestone effects (level-up, evolution, elite / boss kills)
	play, smaller, with no screen flash or camera kick.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Theme = require(Shared:WaitForChild("Theme"))
local Audio = require(script.Parent.Audio)
local ClientSettings = require(script.Parent.ClientSettings)
local CameraController = require(script.Parent.CameraController)

local CombatFx = {}

local C = (Config.Graphics :: any).CombatFx or {}
local P = Theme.Palette
local FX = Theme.Fx
local player = Players.LocalPlayer

local MAX_PARTS: number = C.MaxParts or 110
local RATE: number = C.PartsPerSecond or 320
local BURST: number = C.Burst or 48
local MID: number = C.MidDistance or 45
local FAR: number = C.FarDistance or 85
local SLOW: number = C.SlowFrame or 1 / 40
local BIG: number = C.BigKillSize or 4.6
local HUGE: number = C.HugeKillSize or 9.5
local REDUCED: number = C.ReducedBudget or 0.25

local PARK = CFrame.new(0, -150, 0)
local FLOOR_Y = Config.ArenaOrigin.Y
local TAU = math.pi * 2
local NEON = Enum.Material.Neon
local SMOOTH = Enum.Material.SmoothPlastic
local DISC = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y: a flat disc
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- same turn: a standing column
local WHITE = Color3.new(1, 1, 1)

local folder: Folder? = nil

------------------------------------------------------------------------------------------
-- Pools, budget and the animator
------------------------------------------------------------------------------------------

local SHAPES = { Ball = Enum.PartType.Ball, Block = Enum.PartType.Block, Cylinder = Enum.PartType.Cylinder }
local pools: { [string]: { BasePart } } = { Ball = {}, Block = {}, Cylinder = {}, Wedge = {} }

type Anim = {
	Part: BasePart,
	Shape: string,
	Start: number,
	Dur: number,
	CF0: CFrame,
	CF1: CFrame?,
	S0: Vector3,
	S1: Vector3,
	A0: number,
	A1: number,
	Arc: number,
}

local anims: { Anim } = {}
local spare: { Anim } = {}
local tokens = BURST
local avgDt = 1 / 60
local stats = { Alive = 0, Peak = 0, Started = 0, Skipped = 0, PoolSize = 0 }

local function newPart(shape: string): BasePart
	local p: BasePart
	if shape == "Wedge" then
		p = Instance.new("WedgePart")
	else
		local part = Instance.new("Part")
		part.Shape = SHAPES[shape] or Enum.PartType.Block
		p = part
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = PARK
	p.Parent = folder
	stats.PoolSize += 1
	return p
end

-- Budget multiplier now: Reduced effects and slow frames shrink it.
local function scale(): number
	local s = ClientSettings.Reduced() and REDUCED or 1
	if avgDt > SLOW * 1.6 then
		s *= 0.25
	elseif avgDt > SLOW then
		s *= 0.5
	end
	return s
end

-- Room for `n` more parts this frame? Takes them from the bucket when there is. Minor
-- effects (hits, small kills, sparks) stop at 70% of the cap and leave a third of the
-- bucket, so elite / boss kills and milestones still fit; a major one may borrow from the
-- bucket (it refills before the next minor effect plays) but never passes MaxParts.
local function claim(n: number, major: boolean?): boolean
	local s = scale()
	local ok
	if major then
		ok = #anims + n <= MAX_PARTS * s and tokens > 0
	else
		ok = #anims + n <= MAX_PARTS * s * 0.7 and n <= tokens - BURST * 0.35
	end
	if not ok then
		stats.Skipped += 1
		return false
	end
	tokens = math.max(tokens - n, -BURST)
	return true
end

-- Local hero position (for the distance falloff), or nil outside a run / without a body.
local function heroPos(): Vector3?
	local char = player.Character
	local root = char and char.PrimaryPart
	return root and root.Position
end

-- Part count multiplier for an effect at pos: 1 near, 0.5 mid range, 0 far away.
local function lod(pos: Vector3): number
	local hp = heroPos()
	if not hp then
		return 1
	end
	local dx, dz = pos.X - hp.X, pos.Z - hp.Z
	local d2 = dx * dx + dz * dz
	if d2 > FAR * FAR then
		return 0
	elseif d2 > MID * MID then
		return 0.5
	end
	return 1
end

local function towardCamera(pos: Vector3, dist: number): Vector3
	local cam = workspace.CurrentCamera
	if not cam then
		return pos
	end
	local d = cam.CFrame.Position - pos
	local m = d.Magnitude
	return m > 1e-3 and pos + d / m * dist or pos
end

-- A camera-facing frame at pos (blades and stars lie in the screen plane).
local function facing(pos: Vector3): CFrame
	local cam = workspace.CurrentCamera
	if not cam then
		return CFrame.new(pos)
	end
	return CFrame.lookAt(pos, pos + cam.CFrame.LookVector)
end

--[[
	One pooled part: from cf0 (to cf1 when given, plus `arc` studs of hop), size s0 -> s1
	(ease-out), transparency a0 -> a1 (quadratic: bright, then gone) over dur seconds. The caller claims first.
]]
local function spawn(shape: string, color: Color3, material: Enum.Material, cf0: CFrame, cf1: CFrame?, s0: Vector3, s1: Vector3, a0: number, a1: number, dur: number, arc: number?)
	local p = table.remove(pools[shape]) or newPart(shape)
	p.Color = color
	p.Material = material
	p.Size = s0
	p.Transparency = a0
	p.CFrame = cf0
	local a: Anim = table.remove(spare) or ({} :: any)
	a.Part = p
	a.Shape = shape
	a.Start = os.clock()
	a.Dur = math.max(dur, 0.02)
	a.CF0 = cf0
	a.CF1 = cf1
	a.S0 = s0
	a.S1 = s1
	a.A0 = a0
	a.A1 = a1
	a.Arc = arc or 0
	anims[#anims + 1] = a
	stats.Started += 1
end

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local function step(now: number)
	local n = 0
	local i = 1
	while i <= #anims do
		local a = anims[i]
		local u = (now - a.Start) / a.Dur
		if u >= 1 then
			local p = a.Part
			p.CFrame = PARK
			table.insert(pools[a.Shape], p)
			anims[i] = anims[#anims]
			anims[#anims] = nil
			spare[#spare + 1] = a
		else
			local v = 1 - u
			local e = 1 - v * v * v
			local p = a.Part
			p.Size = a.S0:Lerp(a.S1, e)
			p.Transparency = a.A0 + (a.A1 - a.A0) * u * u -- holds bright, then drops
			local cf1 = a.CF1
			if cf1 then
				local cf = a.CF0:Lerp(cf1, e)
				if a.Arc ~= 0 then
					cf += Vector3.new(0, a.Arc * 4 * u * v, 0)
				end
				n += 1
				moveParts[n] = p
				moveCFrames[n] = cf
			end
			i += 1
		end
	end
	for k = #moveParts, n + 1, -1 do
		moveParts[k] = nil
		moveCFrames[k] = nil
	end
	if n > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	stats.Alive = #anims
	if #anims > stats.Peak then
		stats.Peak = #anims
	end
end

------------------------------------------------------------------------------------------
-- Screen-edge flash (one ScreenGui, four gradient strips; off with Reduced effects)
------------------------------------------------------------------------------------------

local edge: any = nil -- { Gui, Strips, Start, Dur, Peak } once built

local function buildEdge()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SwarmEdgeFlash"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None -- to the true screen edge (past phone notches)
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 2 -- above the world, under the HUD panels
	gui.Enabled = false
	local strips = {}
	-- {anchor, position, size, gradient rotation (transparent toward the centre)}
	local sides = {
		{ Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.16), 90 },
		{ Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.fromScale(1, 0.16), -90 },
		{ Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.fromScale(0.12, 1), 0 },
		{ Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.fromScale(0.12, 1), 180 },
	}
	for _, s in ipairs(sides) do
		local f = Instance.new("Frame")
		f.AnchorPoint = s[1]
		f.Position = s[2]
		f.Size = s[3]
		f.BorderSizePixel = 0
		f.BackgroundColor3 = WHITE
		f.BackgroundTransparency = 1
		local g = Instance.new("UIGradient")
		g.Rotation = s[4]
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
		f.Parent = gui
		table.insert(strips, f)
	end
	gui.Parent = player:WaitForChild("PlayerGui")
	edge = { Gui = gui, Strips = strips, Start = 0, Dur = 0, Peak = 0 }
end

local function edgeFlash(color: Color3, peak: number, dur: number)
	if ClientSettings.Flashes() then
		return
	end
	if not edge then
		buildEdge()
	end
	local e = edge
	for _, f in ipairs(e.Strips) do
		f.BackgroundColor3 = color
	end
	e.Gui.Enabled = true
	e.Start = os.clock()
	e.Dur = dur
	e.Peak = peak
end

local function stepEdge(now: number)
	local e = edge
	if not e or not e.Gui.Enabled then
		return
	end
	local u = (now - e.Start) / e.Dur
	if u >= 1 or ClientSettings.Flashes() then
		e.Gui.Enabled = false
		return
	end
	-- fast attack (first 15%), smooth release
	local k = u < 0.15 and u / 0.15 or (1 - (u - 0.15) / 0.85) ^ 2
	local alpha = 1 - e.Peak * k
	for _, f in ipairs(e.Strips) do
		f.BackgroundTransparency = alpha
	end
end

------------------------------------------------------------------------------------------
-- Effects
------------------------------------------------------------------------------------------

-- Camera punch scaled by the Screen shake setting (CameraController); none when Reduced.
local function kick(amount: number)
	if ClientSettings.Reduced() then
		return
	end
	CameraController.Kick(amount)
end

-- Crossed blades that snap open (impact / crit / pickup star).
local function star(at: Vector3, color: Color3, size: number, dur: number)
	local cf = facing(at)
	local s0 = Vector3.new(size * 0.16, size * 0.35, 0.05)
	local s1 = Vector3.new(size * 0.07, size, 0.05)
	spawn("Block", color, NEON, cf * CFrame.Angles(0, 0, math.rad(45)), nil, s0, s1, 0.05, 1, dur)
	spawn("Block", color, NEON, cf * CFrame.Angles(0, 0, math.rad(-45)), nil, s0, s1, 0.05, 1, dur)
end

-- Thin sparks flung outward from `at` (count of them, length len, reach dist).
local function sparks(at: Vector3, color: Color3, count: number, len: number, dist: number, dur: number, up: number)
	for _ = 1, count do
		local a = math.random() * TAU
		local dir = Vector3.new(math.cos(a), up + math.random() * 0.4, math.sin(a)).Unit
		local cf0 = CFrame.lookAt(at, at + dir)
		spawn("Block", color, NEON, cf0, cf0 + dir * dist * (0.7 + math.random() * 0.6), Vector3.new(0.1, 0.1, len), Vector3.new(0.04, 0.04, len * 0.3), 0.05, 1, dur)
	end
end

-- A sparked enemy hit (VFX already thins these to a few per batch).
function CombatFx.Impact(pos: Vector3)
	if ClientSettings.Reduced() or lod(pos) < 1 or not claim(2) then
		return
	end
	star(towardCamera(pos + Vector3.new(0, 0.3, 0), 1.6), FX.Hit, 3.2, 0.1)
end

-- A critical hit (or another big hit) on an enemy at pos.
function CombatFx.Crit(pos: Vector3)
	if ClientSettings.Reduced() or lod(pos) < 1 then
		return
	end
	local n = 3
	if not claim(2 + n) then
		return
	end
	local at = towardCamera(pos + Vector3.new(0, 0.5, 0), 1.8)
	star(at, FX.Gold, 5, 0.15)
	sparks(at, P.gold_200, n, 0.9, 3, 0.18, 0.3)
end

--[[
	An enemy died at (x, z) (y = its body centre). color = its tint, size = its diameter;
	rank = its place in the FxBatch (VFX passes it so only the first few get shards).
]]
function CombatFx.Kill(x: number, z: number, color: Color3, size: number, rank: number)
	local pos = Vector3.new(x, FLOOR_Y + math.clamp(size * 0.35, 0.8, 3), z)
	local big = size >= BIG
	local huge = size >= HUGE
	local reduced = ClientSettings.Reduced()
	local l = lod(pos)
	if not big and (reduced or rank > 8 or l <= 0) then
		return
	end
	local tint = color:Lerp(WHITE, 0.25)
	if not big then
		local shards = l >= 1 and 3 or 2
		if not claim(1 + shards) then
			return
		end
		local pop = math.clamp(size * 0.5, 1.2, 2.6)
		spawn("Ball", tint:Lerp(WHITE, 0.6), NEON, CFrame.new(towardCamera(pos, 1)), nil, Vector3.one * pop * 0.5, Vector3.one * pop * 1.5, 0.1, 1, 0.09)
		for i = 1, shards do
			local a = (i / shards) * TAU + math.random() * 1.4
			local dist = size * 0.4 + 1.5 + math.random() * 1.5
			local to = Vector3.new(x + math.cos(a) * dist, FLOOR_Y + 0.2, z + math.sin(a) * dist)
			local turn = CFrame.Angles(math.random() * 3, math.random() * 3, 0)
			spawn("Wedge", tint, SMOOTH, CFrame.new(pos) * turn, CFrame.new(to) * turn * CFrame.Angles(2.2, 1.1, 0), Vector3.new(0.55, 0.3, 0.85), Vector3.new(0.3, 0.18, 0.45), 0, 1, 0.36, 1.4 + size * 0.1)
		end
		return
	end
	-- elites and big creatures: a burst you notice from across the arena
	local rays = reduced and 0 or (huge and 10 or 6)
	local shards = reduced and 2 or (huge and 8 or 5)
	if l < 1 then
		rays = math.floor(rays / 2)
		shards = math.floor(shards / 2)
	end
	-- a busy moment trims the burst instead of dropping it (flash + floor ring stay)
	local free = math.floor(MAX_PARTS * scale() - #anims) - 2
	if free < rays + shards then
		local k = math.max(free, 0) / math.max(rays + shards, 1)
		rays = math.floor(rays * k)
		shards = math.floor(shards * k)
	end
	if not claim(2 + rays + shards, true) then
		return
	end
	local flash = math.min(size * 0.6, 8)
	spawn("Ball", tint:Lerp(WHITE, 0.75), NEON, CFrame.new(towardCamera(pos, 1.5)), nil, Vector3.one * flash * 0.4, Vector3.one * flash * 1.3, 0.25, 1, huge and 0.2 or 0.14)
	spawn("Cylinder", tint:Lerp(FX.Gold, 0.4), SMOOTH, CFrame.new(x, FLOOR_Y + 0.08, z) * DISC, nil, Vector3.new(0.05, size * 0.6, size * 0.6), Vector3.new(0.05, size * 3.2, size * 3.2), 0.45, 1, huge and 0.5 or 0.32)
	for i = 1, rays do
		local a = (i / rays) * TAU + math.random() * 0.3
		local dir = Vector3.new(math.cos(a), 0.15 + math.random() * 0.25, math.sin(a)).Unit
		local from = pos + dir * size * 0.3
		local cf0 = CFrame.lookAt(from, from + dir)
		spawn("Block", i % 2 == 0 and FX.Gold or FX.Hit, NEON, cf0, cf0 + dir * (size * 1.2 + 4), Vector3.new(0.22, 0.22, size * 0.5), Vector3.new(0.06, 0.06, size * 0.9), 0.05, 1, huge and 0.3 or 0.22)
	end
	for i = 1, shards do
		local a = (i / shards) * TAU + math.random() * 0.8
		local dist = size * 0.8 + 2 + math.random() * 3
		local to = Vector3.new(x + math.cos(a) * dist, FLOOR_Y + 0.3, z + math.sin(a) * dist)
		local turn = CFrame.Angles(math.random() * 3, math.random() * 3, 0)
		local b = math.clamp(size * 0.12, 0.6, 1.4)
		spawn("Wedge", tint, SMOOTH, CFrame.new(pos) * turn, CFrame.new(to) * turn * CFrame.Angles(2.6, 1.4, 0), Vector3.new(b * 0.8, b * 0.4, b * 1.2), Vector3.new(b * 0.5, b * 0.25, b * 0.6), 0, 1, 0.5, 2 + size * 0.15)
	end
	if huge then
		kick(3.5)
		CameraController.Shake(0.4)
		Audio.Play("BigKill")
	elseif l >= 1 then
		kick(1.5)
	end
end

-- Sparks off the blade tip as a sword swing ends (tip = blade tip, tier 0-3, 3 = evolved).
function CombatFx.SwingTip(tip: Vector3, tier: number)
	local n = 2 + math.min(tier, 2)
	if ClientSettings.Reduced() or lod(tip) < 1 or not claim(n) then
		return
	end
	sparks(tip, tier >= 3 and P.crimson_300 or FX.Spark, n, 0.7, 2.4, 0.15, 0.1)
end

-- Gold pillar of light with spiralling motes (pos = hero root).
function CombatFx.LevelUp(pos: Vector3, isLocal: boolean)
	local reduced = ClientSettings.Reduced()
	local motes = reduced and 0 or 6
	if not claim(2 + motes, true) then
		return
	end
	local base = Vector3.new(pos.X, FLOOR_Y, pos.Z)
	-- the pillar: a tall thin neon core that shoots up and thins, inside a soft column
	spawn("Cylinder", P.gold_200, NEON, CFrame.new(base + Vector3.new(0, 7, 0)) * UPRIGHT, nil, Vector3.new(4, 1.6, 1.6), Vector3.new(14, 0.3, 0.3), 0.15, 1, 0.5)
	spawn("Cylinder", FX.Gold, SMOOTH, CFrame.new(base + Vector3.new(0, 5, 0)) * UPRIGHT, nil, Vector3.new(10, 3.2, 3.2), Vector3.new(12, 4.6, 4.6), 0.55, 1, 0.55)
	for i = 1, motes do
		local a = (i / motes) * TAU
		local from = base + Vector3.new(math.cos(a) * 2.6, 0.5, math.sin(a) * 2.6)
		local to = base + Vector3.new(math.cos(a + 1.6) * 1.2, 7 + (i % 3), math.sin(a + 1.6) * 1.2)
		spawn("Ball", i % 2 == 0 and WHITE or P.gold_200, NEON, CFrame.new(from), CFrame.new(to), Vector3.one * 0.45, Vector3.one * 0.15, 0.1, 1, 0.6)
	end
	if isLocal then
		kick(1.2)
	end
end

-- One of the local hero's weapons just evolved.
function CombatFx.Evolve()
	local hp = heroPos()
	if not hp then
		return
	end
	local reduced = ClientSettings.Reduced()
	local rays = reduced and 0 or 12
	if claim(3 + rays, true) then
		local base = Vector3.new(hp.X, FLOOR_Y, hp.Z)
		local at = base + Vector3.new(0, 2, 0)
		spawn("Ball", WHITE, NEON, CFrame.new(towardCamera(at, 2)), nil, Vector3.one * 2, Vector3.one * 9, 0.05, 1, 0.22)
		spawn("Cylinder", P.gold_200, NEON, CFrame.new(base + Vector3.new(0, 9, 0)) * UPRIGHT, nil, Vector3.new(18, 2.4, 2.4), Vector3.new(20, 0.4, 0.4), 0.1, 1, 0.7)
		spawn("Cylinder", FX.Gold, NEON, CFrame.new(base + Vector3.new(0, 0.1, 0)) * DISC, nil, Vector3.new(0.05, 3, 3), Vector3.new(0.05, 22, 22), 0.3, 1, 0.55)
		for i = 1, rays do
			local a = (i / rays) * TAU
			local dir = Vector3.new(math.cos(a), 0.12, math.sin(a)).Unit
			local cf0 = CFrame.lookAt(at, at + dir)
			spawn("Block", i % 2 == 0 and WHITE or FX.Gold, NEON, cf0, cf0 + dir * 11, Vector3.new(0.3, 0.3, 1.5), Vector3.new(0.08, 0.08, 4.5), 0.05, 1, 0.4)
		end
	end
	edgeFlash(FX.Gold, 0.55, 0.7)
	kick(3)
	Audio.Play("Evolve")
end

-- A floor pickup next to the local hero was taken (pos = where it sat).
function CombatFx.Pickup(pos: Vector3, chest: boolean)
	if ClientSettings.Reduced() or not claim(chest and 6 or 4) then
		return
	end
	local at = pos + Vector3.new(0, 1, 0)
	star(towardCamera(at, 1), chest and FX.Gold or WHITE, chest and 6 or 4, 0.2)
	sparks(at, FX.Gold, chest and 4 or 2, 0.4, 2.2, 0.3, 0.8)
end

-- The boss entered a new phase.
function CombatFx.BossPhase()
	edgeFlash(P.crimson_400, 0.6, 0.85)
	kick(3)
	CameraController.Shake(0.5)
end

-- Debug / preview counters: parts alive now, peak, started, skipped (budget), pool size.
function CombatFx.Stats(): { [string]: number }
	return table.clone(stats)
end

------------------------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------------------------

function CombatFx.Init(parent: Instance)
	local f = Instance.new("Folder")
	f.Name = "SwarmCombatFx"
	f.Parent = parent
	folder = f

	-- evolution: a weapon whose Evolved flag turns on in this player's Inventory
	local evolved: { [string]: boolean } = {}
	local seeded = false
	Remotes.Get("Inventory").OnClientEvent:Connect(function(data)
		if type(data) ~= "table" or type(data.Weapons) ~= "table" then
			table.clear(evolved)
			seeded = false
			return
		end
		local fresh = false
		local now: { [string]: boolean } = {}
		for _, w in ipairs(data.Weapons) do
			if type(w) == "table" and w.Evolved == true and type(w.Id) == "string" then
				now[w.Id] = true
				fresh = fresh or not evolved[w.Id]
			end
		end
		evolved = now
		-- the first inventory after joining is the state, not a change
		if fresh and seeded then
			CombatFx.Evolve()
		end
		seeded = true
	end)

	-- boss phase change: BossPhase counts up during a fight (1 = first phase, 0 = no boss)
	local state = Remotes.State()
	local lastPhase = tonumber(state:GetAttribute("BossPhase")) or 0
	state:GetAttributeChangedSignal("BossPhase"):Connect(function()
		local phase = tonumber(state:GetAttribute("BossPhase")) or 0
		if lastPhase >= 1 and phase > lastPhase and player:GetAttribute("InRun") == true then
			CombatFx.BossPhase()
		end
		lastPhase = phase
	end)

	RunService.RenderStepped:Connect(function(dt)
		avgDt += (math.min(dt, 0.25) - avgDt) * 0.1
		tokens = math.min(BURST, tokens + RATE * dt)
		local now = os.clock()
		step(now)
		stepEdge(now)
	end)
end

return CombatFx
