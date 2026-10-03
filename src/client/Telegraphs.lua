--[[
	Telegraphs.lua
	Every enemy warning on the floor, drawn on this client only. The server sends each one
	ONCE in the FxBatch (keys "w" = warnings, "x" = cancel by id, 0 = all; see server Fx.Warn)
	and decides the damage itself at the moment the warning ends, so what you see is what
	hits. Nothing here affects gameplay.

	Readability rules (docs/ART_DIRECTION.md §7 + the encounter brief):
	  * shape first, colour second: filled growing circles (the fill reaching the rim = the
	    hit), lanes with edge lines that fill toward their end, spokes with visible gaps,
	    a dashed ring + crosshair for acid, a blinking double ring for a bomb's blast, inward
	    ticks for the Queen's burrow;
	  * crimson / amber family from the palette, always over a dark outline so they read on
	    moss, dirt and stone; strong but never Neon-bright on big surfaces;
	  * drawn just above the ground decoration (y + 0.36 .. 0.43), under every character;
	  * pooled parts, one BulkMoveTo per frame, everything removed on its own timer and on
	    the server's cancel (boss death, travel, run end); a part's alpha is only rewritten
	    when it changed, and spawn puffs thin out in a big swarm (perf-sim scene).

	Kinds: circle (venom | acid | blast | burrow | pulse | hatch | nest | glimmer | frost), lane,
	spokes, glob (the Spitter's acid / the Hive Mother's eggs in flight), egg (the Queen's
	summons crack open), emerge (soil cracks: a summon climbs out), patch (a Burning elite's
	fire, the Hive Mother's acid pools), band (the Rhino Warlord's ground-pound rings, each
	fills outward), wave (the Moth Matriarch's dust ring rolling out with one safe gap; the
	gap lane is marked while it gathers), mine (her glimmer motes drifting down, blinking
	faster), gust (her wind cone: a push, no damage, so ivory instead of crimson), aura (the
	War Banner's rally zone), bramble (the Briar Sentinel's thorn ring closing in with one
	gap; the way out is marked while it gathers), pop (impact bursts: acid, venom, burrow,
	dust, shield, egg, pound, glimmer, gust, heal, slam, hatch, pulse, thorn, ice, frost).
	The Colossus's breath is a "gust" with style "frost" (crimson edges: it hurts); root
	lines and ice lanes are lanes whose eruption pops run along them.
	Sound cues for the new shapes play here (VFX plays the older ones).
	EnemyRenderer also calls Telegraphs.Puff (spawn dust) and Telegraphs.Dust (burrow trail).
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Palette = require(Shared:WaitForChild("Palette"))
local ModelLibrary = require(script.Parent.ModelLibrary)
local Audio = require(script.Parent.Audio)
local ClientSettings = require(script.Parent.ClientSettings)
local Accessibility = require(script.Parent.Accessibility)

local Telegraphs = {}

local P = Palette
local FLOOR_Y = Config.ArenaOrigin.Y
local PARK = CFrame.new(0, -150, 0)
local DISC = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X → Y: a flat disc
local TAU = math.pi * 2
local SMOOTH = Enum.Material.SmoothPlastic
local NEON = Enum.Material.Neon
local FADE_IN = 0.1
local FADE_OUT = 0.2

-- Heights above the floor: outline, zone, fill, edges, marks. Above the arena's ground
-- decoration (dirt paths top out at +0.32, plaza inlays +0.2) and under every character.
local Y_RIM, Y_ZONE, Y_FILL, Y_EDGE, Y_MARK = 0.36, 0.375, 0.39, 0.41, 0.425

-- Colours: dark outline under everything, crimson for the Queen and melee, amber / acid
-- for ranged and explosive things.
local C = {
	Outline = P.crimson_900:Lerp(P.chitin_900, 0.4),
	Acid = P.amber_500:Lerp(P.moss_300, 0.45),
	AcidLight = P.amber_300:Lerp(P.moss_200, 0.3),
	Dust = P.dirt_300,
	DustDark = P.dirt_600,
}
local STYLES = {
	venom = { Zone = P.crimson_700, Fill = P.crimson_400, Edge = P.crimson_300, Dash = 1 },
	acid = { Zone = C.Acid:Lerp(P.chitin_900, 0.35), Fill = C.AcidLight, Edge = P.amber_300, Dash = 0.55, Cross = true },
	blast = { Zone = P.crimson_700, Fill = P.amber_500, Edge = P.amber_300, Dash = 1, Inner = true, Blink = true },
	burrow = { Zone = P.crimson_800, Fill = P.crimson_400, Edge = P.crimson_300, Dash = 1, Ticks = 8 },
	-- the Hive Mother's pulse when hit hard (a double ring like a blast, no blinking)
	pulse = { Zone = P.crimson_800, Fill = P.amber_500, Edge = P.amber_300, Dash = 1, Inner = true },
	-- a glimmer mine: dashed, slow blink turning fast
	glimmer = { Zone = P.crimson_800:Lerp(P.moth_500, 0.35), Fill = P.crimson_400:Lerp(P.moth_300, 0.3), Edge = P.gold_300, Dash = 0.5, Blink = true },
	-- harmless timers (a Brood Egg about to hatch, a nest's opening): amber, thin
	hatch = { Zone = P.gold_800, Fill = P.amber_500, Edge = P.amber_300, Dash = 0.45 },
	nest = { Zone = P.dirt_700, Fill = P.amber_500, Edge = P.amber_300, Dash = 0.5 },
	pound = { Zone = P.crimson_700, Fill = P.crimson_400, Edge = P.crimson_300, Dash = 1 },
	-- an ice shard about to land (Frostbound Colossus): crimson like every hit, an icy rim
	frost = { Zone = P.crimson_700, Fill = P.crimson_400, Edge = P.ice_100, Dash = 0.7, Inner = true },
}

-- Sound for a new warning shape (the older shapes' cues are played by VFX).
local function cue(name: string, x: number, z: number)
	pcall(Audio.PlayAt, name, Vector3.new(x, FLOOR_Y + 1, z))
end

local folder: Folder
local recs: { [number]: any } = {}

------------------------------------------------------------------------------------------
-- Parts (pooled) and the bulk move
------------------------------------------------------------------------------------------

local SHAPES = { Ball = Enum.PartType.Ball, Block = Enum.PartType.Block, Cylinder = Enum.PartType.Cylinder }
local pools: { [string]: { BasePart } } = { Ball = {}, Block = {}, Cylinder = {}, Wedge = {} }

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
	p.Material = SMOOTH
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = PARK
	p.Parent = folder
	return p
end

-- Last alpha written per part by setT (cleared when the part is taken again).
local partAlpha: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any

local function take(shape: string, color: Color3, size: Vector3, alpha: number, material: Enum.Material?): BasePart
	local p = table.remove(pools[shape]) or newPart(shape)
	local h, s, v = color:ToHSV()
	local danger = s > 0.18 and v > 0.28 and (h < 0.19 or h > 0.85 or color == C.Acid or color == C.AcidLight)
	p.Color = Accessibility.Color(color, danger and "Danger" or nil)
	p.Material = material or SMOOTH
	p.Size = size
	p.Transparency = alpha
	partAlpha[p] = nil
	return p
end

-- Transparency of one warning part, written only when it changed (to 1/200).
local function setT(p: BasePart, alpha: number)
	alpha = math.floor(alpha * 200 + 0.5) / 200
	if partAlpha[p] ~= alpha then
		partAlpha[p] = alpha
		p.Transparency = alpha
	end
end

local function give(shape: string, p: BasePart)
	p.CFrame = PARK
	table.insert(pools[shape], p)
end

local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}
local bulkN = 0

local function bulk(p: BasePart, cf: CFrame)
	bulkN += 1
	bulkParts[bulkN] = p
	bulkCFrames[bulkN] = cf
end

local function flush()
	for i = #bulkParts, bulkN + 1, -1 do
		bulkParts[i] = nil
		bulkCFrames[i] = nil
	end
	if bulkN > 0 then
		workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	bulkN = 0
end

-- A flat disc of diameter d at (x, y, z).
local function disc(color: Color3, d: number, alpha: number, x: number, y: number, z: number): BasePart
	local p = take("Cylinder", color, Vector3.new(0.04, d, d), alpha)
	p.CFrame = CFrame.new(x, y, z) * DISC
	return p
end

local function setDisc(p: BasePart, d: number)
	p.Size = Vector3.new(0.04, math.max(0.05, d), math.max(0.05, d))
end

-- Ring of n thin segments (dash < 1 leaves gaps). Returns the segment parts.
local function ring(n: number, color: Color3, alpha: number, x: number, y: number, z: number, r: number, width: number, dash: number, spin: number?): { BasePart }
	local parts = table.create(n)
	local len = 2 * (r + width / 2) * math.tan(math.pi / n) * dash
	local step = TAU / n
	for i = 1, n do
		local a = (spin or 0) + (i - 0.5) * step
		local c, s = math.cos(a), math.sin(a)
		local p = take("Block", color, Vector3.new(math.max(0.05, len), 0.04, width), alpha)
		-- length (local X) along the tangent, width (local Z) along the radius
		p.CFrame = CFrame.new(x + c * r, y, z + s * r, s, 0, c, 0, 1, 0, -c, 0, s)
		parts[i] = p
	end
	return parts
end

-- One alpha for a whole group (ring segments, marks). Most warnings hold a steady alpha
-- for most of their life (a blinking edge only changes on its toggles), so an unchanged
-- (to 1/200) value is not written again: a crowd of Bomb Tick rings otherwise rewrote
-- every segment every frame.
local groupAlpha: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

local function setAlpha(parts: { BasePart }, alpha: number)
	alpha = math.floor(alpha * 200 + 0.5) / 200
	if groupAlpha[parts] == alpha then
		return
	end
	groupAlpha[parts] = alpha
	for _, p in ipairs(parts) do
		p.Transparency = alpha
	end
end

local function giveAll(shape: string, parts: { BasePart }?)
	if parts then
		for _, p in ipairs(parts) do
			give(shape, p)
		end
	end
end

------------------------------------------------------------------------------------------
-- One-shot effects (pops, puffs): a tiny pooled animator
------------------------------------------------------------------------------------------

type Anim = { Part: BasePart, Shape: string, Start: number, Dur: number, CF0: CFrame, CF1: CFrame?, Arc: number, S0: Vector3, S1: Vector3?, A0: number, A1: number }
local anims: { Anim } = {}
local MAX_ANIMS = 160
local PUFF_BUSY = 40 -- past this many live one-shots a spawn puff is its dust disc only

local function anim(shape: string, color: Color3, material: Enum.Material, cf0: CFrame, cf1: CFrame?, s0: Vector3, s1: Vector3?, a0: number, a1: number, dur: number, arc: number?)
	if #anims >= MAX_ANIMS then
		return
	end
	local p = take(shape, color, s0, a0, material)
	p.CFrame = cf0
	table.insert(anims, { Part = p, Shape = shape, Start = os.clock(), Dur = math.max(0.01, dur), CF0 = cf0, CF1 = cf1, Arc = arc or 0, S0 = s0, S1 = s1, A0 = a0, A1 = a1 })
end

local function stepAnims(now: number)
	for i = #anims, 1, -1 do
		local a = anims[i]
		local u = (now - a.Start) / a.Dur
		if u >= 1 then
			give(a.Shape, a.Part)
			anims[i] = anims[#anims]
			anims[#anims] = nil
		else
			local e = 1 - (1 - u) * (1 - u)
			local s1 = a.S1
			if s1 then
				a.Part.Size = a.S0:Lerp(s1, e)
			end
			a.Part.Transparency = a.A0 + (a.A1 - a.A0) * u
			local cf1 = a.CF1
			if cf1 then
				local cf = a.CF0:Lerp(cf1, e)
				if a.Arc ~= 0 then
					cf += Vector3.new(0, a.Arc * 4 * u * (1 - u), 0)
				end
				bulk(a.Part, cf)
			end
		end
	end
end

local function flatDisc(x: number, z: number, y: number): CFrame
	return CFrame.new(x, FLOOR_Y + 0.33 + y, z) * DISC
end

-- Small dust puff where an enemy climbs out (EnemyRenderer, on spawn, on screen only).
-- In a big swarm (many one-shots alive) or with Reduced effects it is the dust disc alone.
function Telegraphs.Puff(x: number, z: number, radius: number)
	local d = radius * 2
	anim("Cylinder", C.Dust, SMOOTH, flatDisc(x, z, 0.05), nil, Vector3.new(0.04, d * 0.5, d * 0.5), Vector3.new(0.04, d * 1.6, d * 1.6), 0.45, 1, 0.4)
	if #anims > PUFF_BUSY or ClientSettings.Reduced() then
		return
	end
	for i = 1, 3 do
		local a = i * TAU / 3 + math.random() * 0.8
		local from = Vector3.new(x + math.cos(a) * radius * 0.5, FLOOR_Y + 0.4, z + math.sin(a) * radius * 0.5)
		local to = from + Vector3.new(math.cos(a) * radius * 0.8, 0.9, math.sin(a) * radius * 0.8)
		anim("Ball", C.Dust, SMOOTH, CFrame.new(from), CFrame.new(to), Vector3.one * 0.7, Vector3.one * 1.3, 0.35, 1, 0.45)
	end
end

-- One puff of the burrow trail (EnemyRenderer, while the Queen is underground).
function Telegraphs.Dust(x: number, z: number, size: number)
	local a = math.random() * TAU
	local from = Vector3.new(x + math.cos(a) * size * 0.4, FLOOR_Y + 0.3, z + math.sin(a) * size * 0.4)
	anim("Ball", (math.random() < 0.5) and C.Dust or C.DustDark, SMOOTH, CFrame.new(from), CFrame.new(from + Vector3.new(0, 1.2, 0)), Vector3.one * size * 0.5, Vector3.one * size, 0.25, 1, 0.6)
	if math.random() < 0.35 then
		local to = from + Vector3.new(math.cos(a) * size, -0.2, math.sin(a) * size)
		anim("Block", C.DustDark, SMOOTH, CFrame.new(from), CFrame.new(to) * CFrame.Angles(math.random() * 3, math.random() * 3, 0), Vector3.one * 0.5, Vector3.one * 0.3, 0, 1, 0.45, 1.2)
	end
end

local POP: { [string]: (number, number, number, any?) -> () } = {}

POP.acid = function(x, z, r)
	local d = r * 2
	anim("Cylinder", C.AcidLight, SMOOTH, flatDisc(x, z, 0.14), nil, Vector3.new(0.04, d * 0.5, d * 0.5), Vector3.new(0.04, d * 1.1, d * 1.1), 0.25, 1, 0.35)
	for i = 1, 6 do
		local a = i * TAU / 6 + math.random() * 0.5
		local from = Vector3.new(x, FLOOR_Y + 0.6, z)
		local to = Vector3.new(x + math.cos(a) * r * 0.9, FLOOR_Y + 0.2, z + math.sin(a) * r * 0.9)
		anim("Ball", C.Acid, SMOOTH, CFrame.new(from), CFrame.new(to), Vector3.one * 0.55, Vector3.one * 0.3, 0.1, 1, 0.38, 1.6)
	end
end

POP.venom = function(x, z, r)
	local d = r * 2
	anim("Cylinder", P.crimson_300, SMOOTH, flatDisc(x, z, 0.14), nil, Vector3.new(0.04, d * 0.6, d * 0.6), Vector3.new(0.04, d * 1.05, d * 1.05), 0.2, 1, 0.3)
	for i = 1, 7 do
		local a = i * TAU / 7 + math.random() * 0.4
		local rr = (i == 7) and 0 or r * (0.35 + math.random() * 0.45)
		local px, pz = x + math.cos(a) * rr, z + math.sin(a) * rr
		local h = 2.2 + math.random() * 1.4
		local base = CFrame.new(px, FLOOR_Y - h / 2, pz) * CFrame.Angles(0, a, 0)
		anim("Wedge", (i % 2 == 0) and P.crimson_500 or P.crimson_600, SMOOTH, base, base + Vector3.new(0, h * 0.95, 0), Vector3.new(0.6, h, 0.9), nil, 0, 1, 0.5)
	end
end

POP.burrow = function(x, z, r)
	local d = r * 2
	anim("Cylinder", C.Dust, SMOOTH, flatDisc(x, z, 0.14), nil, Vector3.new(0.04, d * 0.4, d * 0.4), Vector3.new(0.04, d * 1.2, d * 1.2), 0.3, 1, 0.5)
	anim("Cylinder", P.crimson_300, SMOOTH, flatDisc(x, z, 0.15), nil, Vector3.new(0.04, d * 0.9, d * 0.9), Vector3.new(0.04, d * 1.1, d * 1.1), 0.35, 1, 0.25)
	for i = 1, 9 do
		local a = i * TAU / 9 + math.random() * 0.5
		local from = Vector3.new(x + math.cos(a) * 1.5, FLOOR_Y + 0.8, z + math.sin(a) * 1.5)
		local to = Vector3.new(x + math.cos(a) * r * 1.1, FLOOR_Y + 0.2, z + math.sin(a) * r * 1.1)
		anim("Block", (i % 2 == 0) and C.DustDark or P.dirt_500, SMOOTH, CFrame.new(from), CFrame.new(to) * CFrame.Angles(math.random() * 4, math.random() * 4, 0), Vector3.one * 0.9, Vector3.one * 0.5, 0, 1, 0.55, 3)
	end
end

POP.dust = function(x, z, r)
	for i = 1, 12 do
		local a = i * TAU / 12
		local from = Vector3.new(x + math.cos(a) * r * 0.25, FLOOR_Y + 0.6, z + math.sin(a) * r * 0.25)
		local to = Vector3.new(x + math.cos(a) * r, FLOOR_Y + 1.1, z + math.sin(a) * r)
		anim("Ball", (i % 3 == 0) and C.DustDark or C.Dust, SMOOTH, CFrame.new(from), CFrame.new(to), Vector3.one * 1.6, Vector3.one * 3.2, 0.3, 1, 0.9)
	end
	local d = r * 2
	anim("Cylinder", C.DustDark, SMOOTH, flatDisc(x, z, 0.05), nil, Vector3.new(0.04, d * 0.3, d * 0.3), Vector3.new(0.04, d, d), 0.5, 1, 0.8)
end

POP.shield = function(x, z, r)
	local y = FLOOR_Y + 2.2
	for i = 1, 7 do
		local a = i * TAU / 7 + math.random() * 0.4
		local from = Vector3.new(x + math.cos(a) * r * 0.7, y, z + math.sin(a) * r * 0.7)
		local to = Vector3.new(x + math.cos(a) * r * 1.6, FLOOR_Y + 0.3, z + math.sin(a) * r * 1.6)
		anim("Block", (i % 2 == 0) and P.slate_200 or P.gold_400, Enum.Material.Metal, CFrame.new(from), CFrame.new(to) * CFrame.Angles(math.random() * 4, math.random() * 4, 0), Vector3.new(0.7, 0.12, 0.6), Vector3.new(0.4, 0.1, 0.35), 0.1, 1, 0.5, 1.4)
	end
	anim("Ball", P.fx_arcane, NEON, CFrame.new(x, y, z), nil, Vector3.one * r, Vector3.one * r * 2.2, 0.6, 1, 0.25)
end

POP.pound = function(x, z, r, inner)
	local d = r * 2
	local i0 = (tonumber(inner) or 0)
	anim("Cylinder", C.Dust, SMOOTH, flatDisc(x, z, 0.12), nil, Vector3.new(0.04, math.max(1, i0 * 2), math.max(1, i0 * 2)), Vector3.new(0.04, d * 1.05, d * 1.05), 0.35, 1, 0.45)
	local n = math.clamp(math.floor(r * 0.8), 6, 18)
	for i = 1, n do
		local a = i * TAU / n + math.random() * 0.3
		local rr = i0 + (r - i0) * (0.3 + math.random() * 0.6)
		local from = Vector3.new(x + math.cos(a) * rr, FLOOR_Y + 0.2, z + math.sin(a) * rr)
		local to = from + Vector3.new(math.cos(a) * 1.2, 1.3 + math.random(), math.sin(a) * 1.2)
		anim("Block", (i % 2 == 0) and C.DustDark or P.stone_500, SMOOTH, CFrame.new(from), CFrame.new(to) * CFrame.Angles(math.random() * 4, math.random() * 4, 0), Vector3.one * 0.8, Vector3.one * 0.4, 0, 1, 0.5, 1.4)
	end
end

POP.slam = function(x, z, r)
	POP.dust(x, z, r)
	for i = 1, 6 do
		local a = i * TAU / 6 + math.random() * 0.5
		local from = Vector3.new(x, FLOOR_Y + 0.8, z)
		local to = Vector3.new(x + math.cos(a) * r * 0.8, FLOOR_Y + 0.2, z + math.sin(a) * r * 0.8)
		anim("Block", (i % 2 == 0) and P.stone_500 or C.DustDark, SMOOTH, CFrame.new(from), CFrame.new(to) * CFrame.Angles(math.random() * 4, math.random() * 4, 0), Vector3.one * 1.0, Vector3.one * 0.6, 0, 1, 0.55, 2.2)
	end
end

POP.glimmer = function(x, z, r)
	local d = r * 2
	anim("Cylinder", P.gold_300, SMOOTH, flatDisc(x, z, 0.14), nil, Vector3.new(0.04, d * 0.4, d * 0.4), Vector3.new(0.04, d * 1.05, d * 1.05), 0.25, 1, 0.3)
	anim("Ball", P.moth_glow, NEON, CFrame.new(x, FLOOR_Y + 1.6, z), nil, Vector3.one * 1.2, Vector3.one * r * 1.4, 0.3, 1, 0.3)
	for i = 1, 8 do
		local a = i * TAU / 8 + math.random() * 0.4
		local from = Vector3.new(x, FLOOR_Y + 1.6, z)
		local to = Vector3.new(x + math.cos(a) * r, FLOOR_Y + 0.4 + math.random() * 2, z + math.sin(a) * r)
		anim("Ball", (i % 2 == 0) and P.gold_200 or P.moth_glow, NEON, CFrame.new(from), CFrame.new(to), Vector3.one * 0.45, Vector3.one * 0.15, 0, 1, 0.45)
	end
end

POP.gust = function(x, z, r)
	for i = 1, 10 do
		local a = i * TAU / 10 + math.random() * 0.4
		local from = Vector3.new(x + math.cos(a) * r * 0.3, FLOOR_Y + 0.8 + math.random() * 1.5, z + math.sin(a) * r * 0.3)
		local to = from + Vector3.new(math.cos(a) * r * 0.8, 0.4, math.sin(a) * r * 0.8)
		local cf0 = CFrame.lookAt(from, to)
		anim("Block", P.ivory_100, SMOOTH, cf0, CFrame.lookAt(to, to + (to - from)), Vector3.new(0.12, 0.12, 2.4), Vector3.new(0.06, 0.06, 0.8), 0.35, 1, 0.5)
	end
end

POP.heal = function(x, z, r)
	local d = r * 2
	anim("Cylinder", P.fx_heal, SMOOTH, flatDisc(x, z, 0.12), nil, Vector3.new(0.04, 2, 2), Vector3.new(0.04, d, d), 0.35, 1, 0.55)
	anim("Cylinder", P.moss_200, SMOOTH, flatDisc(x, z, 0.13), nil, Vector3.new(0.04, d * 0.9, d * 0.9), Vector3.new(0.04, d * 1.02, d * 1.02), 0.4, 1, 0.5)
	for i = 1, 7 do
		local a = i * TAU / 7 + math.random() * 0.6
		local rr = r * (0.2 + math.random() * 0.6)
		local from = Vector3.new(x + math.cos(a) * rr, FLOOR_Y + 0.8, z + math.sin(a) * rr)
		local cf = CFrame.new(from)
		anim("Block", P.fx_heal, NEON, cf, cf + Vector3.new(0, 2.6, 0), Vector3.new(0.5, 0.16, 0.16), Vector3.new(0.3, 0.1, 0.1), 0.1, 1, 0.7)
		anim("Block", P.fx_heal, NEON, cf, cf + Vector3.new(0, 2.6, 0), Vector3.new(0.16, 0.5, 0.16), Vector3.new(0.1, 0.3, 0.1), 0.1, 1, 0.7)
	end
end

POP.hatch = function(x, z, r)
	for i = 1, 7 do
		local a = i * TAU / 7 + math.random() * 0.5
		local from = Vector3.new(x, FLOOR_Y + 1.3, z)
		local to = Vector3.new(x + math.cos(a) * (r + 1), FLOOR_Y + 0.15, z + math.sin(a) * (r + 1))
		anim("Block", (i % 3 == 0) and P.gold_400 or P.ivory_200, SMOOTH, CFrame.new(from), CFrame.new(to) * CFrame.Angles(math.random() * 4, 0, math.random() * 4), Vector3.new(0.8, 0.14, 0.7), Vector3.new(0.5, 0.1, 0.4), 0, 1, 0.45, 1.5)
	end
	anim("Cylinder", P.amber_300, SMOOTH, flatDisc(x, z, 0.1), nil, Vector3.new(0.04, 1, 1), Vector3.new(0.04, r * 2.4, r * 2.4), 0.4, 1, 0.35)
end

POP.pulse = function(x, z, r)
	local d = r * 2
	anim("Cylinder", P.amber_300, SMOOTH, flatDisc(x, z, 0.14), nil, Vector3.new(0.04, d * 0.3, d * 0.3), Vector3.new(0.04, d * 1.1, d * 1.1), 0.2, 1, 0.35)
	anim("Cylinder", P.crimson_400, SMOOTH, flatDisc(x, z, 0.12), nil, Vector3.new(0.04, d * 0.6, d * 0.6), Vector3.new(0.04, d * 1.2, d * 1.2), 0.35, 1, 0.45)
end

POP.egg = function(x, z, _r)
	for i = 1, 6 do
		local a = i * TAU / 6 + math.random() * 0.5
		local from = Vector3.new(x, FLOOR_Y + 1.1, z)
		local to = Vector3.new(x + math.cos(a) * 2.2, FLOOR_Y + 0.15, z + math.sin(a) * 2.2)
		anim("Block", P.ivory_200, SMOOTH, CFrame.new(from), CFrame.new(to) * CFrame.Angles(math.random() * 4, 0, math.random() * 4), Vector3.new(0.7, 0.12, 0.6), Vector3.new(0.5, 0.1, 0.4), 0, 1, 0.45, 1.5)
	end
	anim("Cylinder", P.crimson_300, SMOOTH, flatDisc(x, z, 0.1), nil, Vector3.new(0.04, 1, 1), Vector3.new(0.04, 4, 4), 0.4, 1, 0.3)
end

-- Thorns bursting out of the soil along a root line (Briar Sentinel).
POP.thorn = function(x, z, r)
	local d = r * 2
	anim("Cylinder", P.dirt_600, SMOOTH, flatDisc(x, z, 0.12), nil, Vector3.new(0.04, d * 0.5, d * 0.5), Vector3.new(0.04, d * 1.1, d * 1.1), 0.3, 1, 0.5)
	for i = 1, 4 do
		local a = i * TAU / 4 + math.random() * 0.8
		local rr = r * (0.15 + math.random() * 0.5)
		local h = 2.4 + math.random() * 1.6
		local tilt = CFrame.Angles(math.cos(a) * 0.35, a, math.sin(a) * 0.35)
		local base = CFrame.new(x + math.cos(a) * rr, FLOOR_Y - h / 2, z + math.sin(a) * rr) * tilt
		anim("Wedge", (i % 2 == 0) and P.crimson_800 or P.wood_700, SMOOTH, base, base + Vector3.new(0, h * 0.9, 0), Vector3.new(0.5, h, 0.8), nil, 0, 1, 0.65)
	end
end

-- Ice spikes bursting out of a lane (Frostbound Colossus).
POP.ice = function(x, z, r)
	local d = r * 2
	anim("Cylinder", P.ice_300, SMOOTH, flatDisc(x, z, 0.12), nil, Vector3.new(0.04, d * 0.5, d * 0.5), Vector3.new(0.04, d * 1.05, d * 1.05), 0.3, 1, 0.45)
	for i = 1, 4 do
		local a = i * TAU / 4 + math.random() * 0.8
		local rr = r * (0.1 + math.random() * 0.5)
		local h = 2.6 + math.random() * 1.8
		local base = CFrame.new(x + math.cos(a) * rr, FLOOR_Y - h / 2, z + math.sin(a) * rr) * CFrame.Angles(math.cos(a) * 0.25, a, math.sin(a) * 0.25)
		anim("Wedge", (i % 2 == 0) and P.ice_100 or P.ice_500, SMOOTH, base, base + Vector3.new(0, h * 0.9, 0), Vector3.new(0.7, h, 1.0), nil, 0, 1, 0.6)
	end
end

-- An ice shard landing / the frost armour forming or shattering: pale shards fly out.
POP.frost = function(x, z, r)
	local d = r * 2
	anim("Cylinder", P.ice_100, SMOOTH, flatDisc(x, z, 0.14), nil, Vector3.new(0.04, d * 0.4, d * 0.4), Vector3.new(0.04, d * 1.1, d * 1.1), 0.25, 1, 0.35)
	anim("Cylinder", P.ice_500, SMOOTH, flatDisc(x, z, 0.12), nil, Vector3.new(0.04, d * 0.8, d * 0.8), Vector3.new(0.04, d * 1.15, d * 1.15), 0.35, 1, 0.4)
	for i = 1, 7 do
		local a = i * TAU / 7 + math.random() * 0.5
		local from = Vector3.new(x, FLOOR_Y + 1.4, z)
		local to = Vector3.new(x + math.cos(a) * r * 1.1, FLOOR_Y + 0.2, z + math.sin(a) * r * 1.1)
		anim("Block", (i % 2 == 0) and P.ice_100 or P.ice_300, SMOOTH, CFrame.new(from), CFrame.new(to) * CFrame.Angles(math.random() * 4, math.random() * 4, 0), Vector3.new(0.5, 0.5, 1.1), Vector3.new(0.3, 0.3, 0.6), 0, 1, 0.5, 1.6)
	end
end

------------------------------------------------------------------------------------------
-- Warnings
------------------------------------------------------------------------------------------

local Kind: { [string]: (any, ...any) -> any } = {}

-- Visibility of a warning at time t of dur: fades in, holds, fades out after the end.
local function vis(t: number, dur: number): number
	return math.min(1, t / FADE_IN) * (1 - math.clamp((t - dur) / FADE_OUT, 0, 1))
end

-- Filled growing circle: dark outline, zone, a fill that reaches the rim at the hit.
Kind.circle = function(x: number, z: number, radius: number, seconds: number, style: string?)
	local st = STYLES[style or "venom"] or STYLES.venom
	local r = math.max(0.5, radius)
	local y = FLOOR_Y
	local rec: any = { Dur = math.max(0.1, seconds), St = st, R = r }
	rec.Rim = disc(C.Outline, r * 2 + 0.7, 1, x, y + Y_RIM, z)
	rec.Zone = disc(st.Zone, r * 2, 1, x, y + Y_ZONE, z)
	rec.Fill = disc(st.Fill, 0.1, 1, x, y + Y_FILL, z)
	local n = r > 7 and 28 or 20
	rec.Edge = ring(n, st.Edge, 1, x, y + Y_EDGE, z, r - 0.22, 0.42, st.Dash, math.random() * TAU)
	rec.Dark = ring(n, C.Outline, 1, x, y + Y_EDGE - 0.006, z, r - 0.2, 0.75, 1)
	if st.Inner then
		rec.Inner = ring(14, st.Edge, 1, x, y + Y_EDGE, z, r * 0.55, 0.24, 0.6)
	end
	local marks: { BasePart } = {}
	if st.Cross then
		-- acid: a small crosshair where the glob lands
		for k = 0, 1 do
			local p = take("Block", st.Edge, Vector3.new(r * 0.55, 0.04, 0.22), 1)
			p.CFrame = CFrame.new(x, y + Y_MARK, z) * CFrame.Angles(0, k * math.pi / 2 + math.pi / 4, 0)
			table.insert(marks, p)
		end
	end
	if st.Ticks then
		-- burrow: inward ticks around the rim
		for k = 1, st.Ticks do
			local a = k * TAU / st.Ticks
			local c, s = math.cos(a), math.sin(a)
			local p = take("Block", st.Edge, Vector3.new(0.3, 0.04, 1.4), 1)
			local px, pz = x + c * (r - 1.1), z + s * (r - 1.1)
			p.CFrame = CFrame.lookAt(Vector3.new(px, y + Y_MARK, pz), Vector3.new(x, y + Y_MARK, z))
			table.insert(marks, p)
		end
	end
	rec.Marks = marks
	function rec.Update(t: number): boolean
		local dur = rec.Dur
		if t >= dur + FADE_OUT then
			return false
		end
		local v = vis(t, dur)
		local u = math.clamp(t / dur, 0, 1)
		setT(rec.Rim, 1 - 0.62 * v)
		setT(rec.Zone, 1 - 0.42 * v)
		setDisc(rec.Fill, rec.R * 2 * (0.12 + 0.88 * u))
		setT(rec.Fill, 1 - (0.42 + 0.3 * u) * v)
		local edge
		if rec.St.Blink and not ClientSettings.Flashes() then
			local hz = 5 + 12 * u
			edge = (math.sin(t * hz * TAU) > -0.2) and 0.1 or 0.75
		else
			edge = 0.12 + 0.2 * (0.5 + 0.5 * math.sin(t * (7 + 14 * u)))
		end
		setAlpha(rec.Edge, 1 - (1 - edge) * v)
		setAlpha(rec.Dark, 1 - 0.5 * v)
		if rec.Inner then
			setAlpha(rec.Inner, 1 - (1 - edge) * v)
		end
		setAlpha(rec.Marks, 1 - 0.8 * v)
		return true
	end
	function rec.Release()
		give("Cylinder", rec.Rim)
		give("Cylinder", rec.Zone)
		give("Cylinder", rec.Fill)
		giveAll("Block", rec.Edge)
		giveAll("Block", rec.Dark)
		giveAll("Block", rec.Inner)
		giveAll("Block", rec.Marks)
	end
	return rec
end

-- Lane (charges, lunges): outline, base, edge lines, an end cap, a fill running from the
-- attacker (local +Z end) to the far end over the warning time.
Kind.lane = function(x: number, z: number, yaw: number, length: number, width: number, seconds: number)
	local cf = CFrame.new(x, FLOOR_Y, z) * CFrame.Angles(0, tonumber(yaw) or 0, 0)
	local rec: any = { Dur = math.max(0.1, seconds), CF = cf, Len = length, W = width }
	local edge = 0.3
	rec.Rim = take("Block", C.Outline, Vector3.new(width + 0.8, 0.04, length + 0.8), 1)
	rec.Rim.CFrame = cf * CFrame.new(0, Y_RIM, 0)
	rec.Base = take("Block", P.crimson_700, Vector3.new(width, 0.04, length), 1)
	rec.Base.CFrame = cf * CFrame.new(0, Y_ZONE, 0)
	rec.Fill = take("Block", P.crimson_400, Vector3.new(width, 0.04, 0.1), 1)
	rec.L = take("Block", P.crimson_300, Vector3.new(edge, 0.04, length), 1)
	rec.L.CFrame = cf * CFrame.new(-width / 2 + edge / 2, Y_EDGE, 0)
	rec.R = take("Block", P.crimson_300, Vector3.new(edge, 0.04, length), 1)
	rec.R.CFrame = cf * CFrame.new(width / 2 - edge / 2, Y_EDGE, 0)
	rec.Cap = take("Block", P.crimson_300, Vector3.new(width, 0.04, edge * 1.6), 1)
	rec.Cap.CFrame = cf * CFrame.new(0, Y_EDGE, -length / 2 + edge * 0.8)
	-- chevrons pointing along the charge
	rec.Chev = {}
	local nChev = math.clamp(math.floor(length / 9), 1, 7)
	for k = 1, nChev do
		local zz = length / 2 - k * length / (nChev + 1)
		for side = -1, 1, 2 do
			local p = take("Block", P.crimson_300, Vector3.new(0.3, 0.04, math.min(width * 0.45, 3)), 1)
			p.CFrame = cf * CFrame.new(side * width * 0.16, Y_MARK, zz) * CFrame.Angles(0, side * math.rad(40), 0)
			table.insert(rec.Chev, p)
		end
	end
	function rec.Update(t: number): boolean
		local dur = rec.Dur
		if t >= dur + FADE_OUT then
			return false
		end
		local v = vis(t, dur)
		local u = math.clamp(t / dur, 0, 1)
		local pulse = 0.78 + 0.22 * math.sin(t * (8 + 18 * u))
		setT(rec.Rim, 1 - 0.5 * v)
		setT(rec.Base, 1 - 0.38 * v)
		local ea = 1 - 0.9 * pulse * v
		setT(rec.L, ea)
		setT(rec.R, ea)
		setT(rec.Cap, ea)
		setAlpha(rec.Chev, 1 - 0.7 * v)
		local len = math.max(0.1, rec.Len * u)
		rec.Fill.Size = Vector3.new(rec.W, 0.04, len)
		setT(rec.Fill, 1 - (0.35 + 0.3 * u) * v)
		bulk(rec.Fill, rec.CF * CFrame.new(0, Y_FILL, rec.Len / 2 - len / 2))
		return true
	end
	function rec.Release()
		for _, k in ipairs({ "Rim", "Base", "Fill", "L", "R", "Cap" }) do
			give("Block", rec[k])
		end
		giveAll("Block", rec.Chev)
	end
	return rec
end

-- Stinger ring: one spoke per stinger lane; the missing spokes are the safe gaps.
Kind.spokes = function(x: number, z: number, inner: number, length: number, seconds: number, angles: { number }?)
	local rec: any = { Dur = math.max(0.1, seconds), Spokes = {}, X = x, Z = z, R0 = inner, Len = length }
	if type(angles) ~= "table" then
		angles = {}
	end
	for _, a in ipairs(angles :: { number }) do
		if type(a) == "number" then
			local dark = take("Block", C.Outline, Vector3.new(1.0, 0.04, 0.1), 1)
			local core = take("Block", P.crimson_300, Vector3.new(0.45, 0.04, 0.1), 1)
			local tip = take("Wedge", P.crimson_300, Vector3.new(0.04, 1.1, 1.1), 1)
			table.insert(rec.Spokes, { A = a, Dark = dark, Core = core, Tip = tip })
		end
	end
	-- a thin crimson circle at her feet ties the spokes together
	rec.Ring = ring(24, P.crimson_400, 1, x, FLOOR_Y + Y_EDGE, z, inner, 0.3, 0.55)
	function rec.Update(t: number): boolean
		local dur = rec.Dur
		if t >= dur + FADE_OUT then
			return false
		end
		local v = vis(t, dur)
		local grow = math.clamp(t / 0.3, 0, 1)
		local len = math.max(0.2, rec.Len * grow)
		local pulse = 0.75 + 0.25 * math.sin(t * 14)
		for _, sp in ipairs(rec.Spokes) do
			local dir = Vector3.new(math.cos(sp.A), 0, math.sin(sp.A))
			local mid = Vector3.new(rec.X, FLOOR_Y + Y_EDGE, rec.Z) + dir * (rec.R0 + len / 2)
			local cf = CFrame.lookAt(mid, mid + dir)
			sp.Dark.Size = Vector3.new(1.0, 0.04, len + 0.4)
			sp.Core.Size = Vector3.new(0.45, 0.04, len)
			sp.Dark.Transparency = 1 - 0.5 * v
			sp.Core.Transparency = 1 - 0.85 * pulse * v
			sp.Tip.Transparency = 1 - 0.85 * pulse * v
			bulk(sp.Dark, cf * CFrame.new(0, -0.006, 0))
			bulk(sp.Core, cf)
			-- arrow head at the outer end (wedge lying flat, pointing outward)
			bulk(sp.Tip, cf * CFrame.new(0, 0.01, -len / 2 - 0.5) * CFrame.Angles(math.pi / 2, 0, 0) * CFrame.Angles(0, math.pi / 2, 0))
		end
		setAlpha(rec.Ring, 1 - 0.75 * v)
		return true
	end
	function rec.Release()
		for _, sp in ipairs(rec.Spokes) do
			give("Block", sp.Dark)
			give("Block", sp.Core)
			give("Wedge", sp.Tip)
		end
		giveAll("Block", rec.Ring)
	end
	return rec
end

-- The Spitter's acid glob in flight (its landing circle is a separate "circle" warning).
local globPool: { { any } } = {}

local function globPieces(): { any }
	local spare = table.remove(globPool)
	local meshReady = ModelLibrary.MeshFolder("Shot_Acid") ~= nil
	while spare and meshReady and not spare[1].Part:IsA("MeshPart") do
		for _, piece in ipairs(spare) do
			piece.Part:Destroy()
		end
		spare = table.remove(globPool)
	end
	if spare then
		return spare
	end
	local pieces = ModelLibrary.MeshPieces("Shot_Acid", nil, 1, 0)
	if pieces then
		for _, piece in ipairs(pieces) do
			piece.Part.Parent = folder
		end
		return pieces
	end
	-- fallback: an acid blob with a glowing core and a little tail (flies toward -Z)
	local list = {}
	local function add(shape: string, size: Vector3, color: Color3, offset: CFrame, material: Enum.Material?, alpha: number?)
		local p = newPart(shape)
		p.Size = size
		p.Color = Accessibility.Color(color)
		p.Material = material or SMOOTH
		p.Transparency = alpha or 0
		table.insert(list, { Part = p, Offset = offset, Color = color })
	end
	add("Ball", Vector3.one * 1.5, C.Acid, CFrame.new(0, 0, -0.2), nil, 0.25)
	add("Ball", Vector3.one * 0.8, C.AcidLight, CFrame.new(0, 0, -0.25), NEON)
	add("Ball", Vector3.one * 0.9, C.Acid, CFrame.new(0, 0, 0.75), nil, 0.35)
	add("Ball", Vector3.one * 0.5, C.Acid, CFrame.new(0, 0, 1.35), nil, 0.5)
	return list
end

-- The Hive Mother's lobbed egg (ivory with gold spots; the same arc as a glob).
local eggGlobPool: { { any } } = {}
local function eggGlobPieces(): { any }
	local spare = table.remove(eggGlobPool)
	if spare then
		return spare
	end
	local list = {}
	local function add(shape: string, size: Vector3, color: Color3, offset: CFrame, material: Enum.Material?)
		local p = newPart(shape)
		p.Size = size
		p.Color = Accessibility.Color(color)
		p.Material = material or SMOOTH
		p.Transparency = 0
		table.insert(list, { Part = p, Offset = offset, Color = color })
	end
	local shell = newPart("Block")
	shell.Size = Vector3.new(1.6, 2.0, 1.6)
	shell.Color = P.ivory_200
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = shell
	table.insert(list, { Part = shell, Offset = CFrame.identity, Color = P.ivory_200 })
	add("Ball", Vector3.one * 0.5, P.gold_400, CFrame.new(0.55, 0.3, -0.35))
	add("Ball", Vector3.one * 0.42, P.gold_400, CFrame.new(-0.5, -0.2, 0.4))
	add("Ball", Vector3.one * 0.7, P.amber_300, CFrame.new(0, 0, 0), NEON)
	return list
end

Kind.glob = function(x1: number, z1: number, x2: number, z2: number, seconds: number, arc: number?, style: string?)
	local isEgg = style == "egg"
	local rec: any = { Dur = math.max(0.1, seconds), A = Vector3.new(x1, FLOOR_Y + (isEgg and 4 or 2.2), z1), B = Vector3.new(x2, FLOOR_Y + (isEgg and 1 or 0.6), z2), H = tonumber(arc) or 6, Pieces = isEgg and eggGlobPieces() or globPieces(), Phase = math.random() * 6, Egg = isEgg }
	function rec.Update(t: number): boolean
		if t >= rec.Dur then
			return false
		end
		local u = t / rec.Dur
		local function at(k: number): Vector3
			return rec.A:Lerp(rec.B, k) + Vector3.new(0, rec.H * 4 * k * (1 - k), 0)
		end
		local pos = at(u)
		local ahead = at(math.min(1, u + 0.02))
		local dir = ahead - pos
		local cf = dir.Magnitude > 1e-3 and CFrame.lookAt(pos, ahead) or CFrame.new(pos)
		if rec.Egg then
			cf = CFrame.new(pos) * CFrame.Angles(t * 7, t * 3, 0) -- an egg tumbles
		end
		for _, piece in ipairs(rec.Pieces) do
			bulk(piece.Part, ModelLibrary.PieceCFrame(cf, piece, t, rec.Phase, 1))
		end
		return true
	end
	function rec.Release()
		for _, piece in ipairs(rec.Pieces) do
			piece.Part.CFrame = PARK
		end
		table.insert(rec.Egg and eggGlobPool or globPool, rec.Pieces)
	end
	return rec
end

-- A summon egg: wobbles harder and harder, cracks, bursts (the hatchling fades in).
local eggPool: { { BasePart } } = {}

local function eggParts(): { BasePart }
	local spare = table.remove(eggPool)
	if spare then
		return spare
	end
	local shell = newPart("Block")
	shell.Size = Vector3.new(2.0, 2.7, 2.0)
	shell.Color = P.ivory_200
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = shell
	local spots = {}
	for k = 1, 3 do
		local sp = newPart("Ball")
		sp.Size = Vector3.one * 0.55
		sp.Color = Accessibility.Color(P.crimson_500, "Danger")
		spots[k] = sp
	end
	local crackA = newPart("Block")
	crackA.Size = Vector3.new(0.1, 1.0, 0.1)
	crackA.Color = P.chitin_900
	local crackB = newPart("Block")
	crackB.Size = Vector3.new(0.1, 0.7, 0.1)
	crackB.Color = P.chitin_900
	return { shell, spots[1], spots[2], spots[3], crackA, crackB }
end

Kind.egg = function(x: number, z: number, seconds: number)
	local rec: any = { Dur = math.max(0.1, seconds), X = x, Z = z, Parts = eggParts() }
	rec.Rim = disc(C.Outline, 4.0, 1, x, FLOOR_Y + Y_RIM, z)
	rec.Ring = ring(14, P.crimson_300, 1, x, FLOOR_Y + Y_EDGE, z, 1.9, 0.26, 0.6)
	for _, p in ipairs(rec.Parts) do
		p.Transparency = 0
	end
	function rec.Update(t: number): boolean
		local dur = rec.Dur
		if t >= dur then
			POP.egg(rec.X, rec.Z, 1)
			return false
		end
		local u = t / dur
		local rise = math.min(1, t / 0.25)
		local amp = 0.05 + 0.3 * u * u
		local wob = CFrame.Angles(math.sin(t * (10 + 20 * u)) * amp, 0, math.cos(t * (9 + 18 * u)) * amp)
		local base = CFrame.new(rec.X, FLOOR_Y - 1 + rise, rec.Z) * wob
		local parts = rec.Parts
		bulk(parts[1], base * CFrame.new(0, 1.35, 0))
		bulk(parts[2], base * CFrame.new(0.72, 1.6, -0.5))
		bulk(parts[3], base * CFrame.new(-0.78, 1.15, -0.3))
		bulk(parts[4], base * CFrame.new(0.15, 2.05, 0.7))
		local cracked = u > 0.55
		parts[5].Transparency = cracked and 0 or 1
		parts[6].Transparency = (u > 0.75) and 0 or 1
		bulk(parts[5], base * CFrame.new(0, 1.7, -0.98) * CFrame.Angles(0, 0, 0.4))
		bulk(parts[6], base * CFrame.new(0.4, 1.25, -0.95) * CFrame.Angles(0, 0, -0.6))
		rec.Rim.Transparency = 1 - 0.5 * rise
		setAlpha(rec.Ring, 1 - (0.5 + 0.4 * math.sin(t * 12)) * rise)
		return true
	end
	function rec.Release()
		for _, p in ipairs(rec.Parts) do
			p.CFrame = PARK
		end
		table.insert(eggPool, rec.Parts)
		give("Cylinder", rec.Rim)
		giveAll("Block", rec.Ring)
	end
	return rec
end

-- A Burning elite's fire patch: glows (harmless, dashed rim) for `arm`, then burns.
-- style "acid": the Hive Mother's pool (a dashed acid circle fills for `arm`, then it
-- bubbles for `life`).
Kind.patch = function(x: number, z: number, radius: number, arm: number, life: number, style: string?)
	local r = math.max(0.5, radius)
	local acid = style == "acid"
	local rec: any = { Arm = math.max(0, arm), Life = math.max(0.1, life), X = x, Z = z, R = r, Acid = acid }
	rec.Dur = rec.Arm + rec.Life
	rec.Scorch = disc(C.Outline, r * 2 + 0.5, 1, x, FLOOR_Y + Y_RIM, z)
	rec.Ember = disc(acid and C.Acid or P.fx_fire, 0.1, 1, x, FLOOR_Y + Y_FILL, z)
	rec.Edge = ring(acid and 22 or 16, P.amber_300, 1, x, FLOOR_Y + Y_EDGE, z, r - 0.15, 0.26, acid and 0.55 or 0.6)
	rec.Flames = {}
	for k = 1, (acid and math.clamp(math.floor(r), 2, 5) or 3) do
		local f
		if acid then
			f = take("Ball", (k % 2 == 0) and C.AcidLight or C.Acid, Vector3.one * 0.6, 1)
		else
			f = take("Wedge", (k == 2) and P.amber_300 or P.fx_fire, Vector3.new(0.4, 1, 0.6), 1, NEON)
		end
		local a = k * TAU / 3 + math.random()
		local rr = r * (acid and (0.2 + math.random() * 0.55) or 0.45)
		rec.Flames[k] = { Part = f, X = x + math.cos(a) * rr, Z = z + math.sin(a) * rr, Ph = math.random() * 6 }
	end
	function rec.Update(t: number): boolean
		if t >= rec.Dur + FADE_OUT then
			return false
		end
		local v = vis(t, rec.Dur)
		local armed = t >= rec.Arm
		local ua = rec.Arm > 0 and math.clamp(t / rec.Arm, 0, 1) or 1
		rec.Scorch.Transparency = 1 - 0.5 * v
		setDisc(rec.Ember, rec.R * 2 * ua)
		rec.Ember.Transparency = 1 - (armed and (rec.Acid and 0.55 or 0.42) or (rec.Acid and 0.45 or 0.25)) * v
		setAlpha(rec.Edge, 1 - (armed and 0.8 or (0.4 + 0.4 * math.sin(t * 20))) * v)
		for _, fl in ipairs(rec.Flames) do
			if rec.Acid then
				-- bubbles that swell and pop
				local b = armed and ((t * 1.3 + fl.Ph) % 1) or 0
				fl.Part.Size = Vector3.one * (0.3 + 0.7 * b)
				fl.Part.Transparency = 1 - 0.75 * v * (armed and (1 - b * 0.6) or 0)
				bulk(fl.Part, CFrame.new(fl.X, FLOOR_Y + 0.35, fl.Z))
			else
				local h = armed and (0.9 + 0.5 * math.abs(math.sin(t * 9 + fl.Ph))) or 0.2
				fl.Part.Size = Vector3.new(0.4, h, 0.6)
				fl.Part.Transparency = 1 - 0.85 * v
				bulk(fl.Part, CFrame.new(fl.X, FLOOR_Y + h / 2, fl.Z) * CFrame.Angles(0, t * 2 + fl.Ph, 0))
			end
		end
		return true
	end
	function rec.Release()
		give("Cylinder", rec.Scorch)
		give("Cylinder", rec.Ember)
		giveAll("Block", rec.Edge)
		for _, fl in ipairs(rec.Flames) do
			give(rec.Acid and "Ball" or "Wedge", fl.Part)
		end
	end
	return rec
end

------------------------------------------------------------------------------------------
-- The rotating bosses' shapes
------------------------------------------------------------------------------------------

-- Places a ring segment: centre angle a, radius r, length along the tangent, width
-- along the radius (for rings whose radius changes every frame).
local function segCF(x: number, y: number, z: number, a: number, r: number): CFrame
	local c, s = math.cos(a), math.sin(a)
	return CFrame.new(x + c * r, y, z + s * r, s, 0, c, 0, 1, 0, -c, 0, s)
end

local function angleGap(a: number, b: number): number
	local d = (a - b) % TAU
	return math.min(d, TAU - d)
end

-- Ground-pound band: a ring zone from inner to outer (a faint wash in thin concentric
-- stripes, so the segments never overlap into dark spokes) with a bright front that
-- rolls from the inner edge to the outer rim; the band strikes when it gets there.
-- inner 0 = a filled circle like the other strikes.
Kind.band = function(x: number, z: number, inner: number, outer: number, seconds: number)
	local r0, r1 = math.max(0, inner), math.max(inner + 0.5, outer)
	if r0 < 0.5 then
		return Kind.circle(x, z, r1, seconds, "pound")
	end
	local w = r1 - r0
	local y = FLOOR_Y
	local n = math.clamp(math.floor(TAU * r1 / 2.4), 20, 64)
	local rec: any = { Dur = math.max(0.1, seconds), X = x, Z = z, R0 = r0, R1 = r1, N = n }
	rec.Zone = {}
	local stripes = math.max(2, math.ceil(w / 1.6))
	local sw = w / stripes
	for k = 1, stripes do
		for _, p in ipairs(ring(n, P.crimson_700, 1, x, y + Y_ZONE, z, r0 + sw * (k - 0.5), sw, 1.02)) do
			table.insert(rec.Zone, p)
		end
	end
	rec.DarkIn = ring(n, C.Outline, 1, x, y + Y_RIM, z, r0, 0.6, 1.04)
	rec.DarkOut = ring(n, C.Outline, 1, x, y + Y_RIM, z, r1, 0.8, 1.04)
	rec.Edge = ring(n, P.crimson_300, 1, x, y + Y_EDGE, z, r1 - 0.25, 0.45, 0.8)
	rec.Front = ring(n, P.crimson_400, 1, x, y + Y_FILL, z, r0 + 0.3, 0.9, 1.0)
	function rec.Update(t: number): boolean
		local dur = rec.Dur
		if t >= dur + FADE_OUT then
			return false
		end
		local v = vis(t, dur)
		local u = math.clamp(t / dur, 0, 1)
		setAlpha(rec.Zone, 1 - (0.3 + 0.2 * u) * v)
		setAlpha(rec.DarkIn, 1 - 0.55 * v)
		setAlpha(rec.DarkOut, 1 - 0.6 * v)
		setAlpha(rec.Edge, 1 - (0.6 + 0.3 * math.sin(t * (7 + 14 * u))) * v)
		-- the front rolls outward; reaching the outer rim = the hit
		local fr = rec.R0 + 0.45 + (rec.R1 - rec.R0 - 0.9) * u
		local len = 2 * (fr + 0.45) * math.tan(math.pi / rec.N)
		local alpha = 1 - (0.55 + 0.35 * u) * v
		for i, p in ipairs(rec.Front) do
			p.Size = Vector3.new(math.max(0.05, len), 0.04, 0.9)
			p.Transparency = alpha
			bulk(p, segCF(rec.X, FLOOR_Y + Y_FILL, rec.Z, (i - 0.5) * TAU / rec.N, fr))
		end
		return true
	end
	function rec.Release()
		giveAll("Block", rec.Zone)
		giveAll("Block", rec.DarkIn)
		giveAll("Block", rec.DarkOut)
		giveAll("Block", rec.Edge)
		giveAll("Block", rec.Front)
	end
	return rec
end

--[[
	Dust Storm wave: while it gathers (delay) a crimson ring at her feet with one opening
	and two ivory lines + chevrons marking the safe lane through the gap; then a dust ring
	rolls outward (speed studs/s) with that gap left open.
]]
Kind.wave = function(x: number, z: number, r0: number, delay: number, speed: number, maxR: number, width: number, gap: number, gapHalf: number)
	local rec: any = { X = x, Z = z, R0 = r0, Delay = math.max(0, delay), Speed = math.max(1, speed), MaxR = maxR, W = math.max(0.5, width), Gap = gap, Half = gapHalf }
	rec.Dur = rec.Delay + (maxR - r0) / rec.Speed
	local n = 56
	rec.N = n
	rec.Angles = {}
	for i = 1, n do
		local a = (i - 0.5) * TAU / n
		if angleGap(a, gap) > gapHalf then
			table.insert(rec.Angles, a)
		end
	end
	local y = FLOOR_Y
	-- the gathering ring at her feet (gap left out)
	rec.Feet = {}
	rec.FeetDark = {}
	for _, a in ipairs(rec.Angles) do
		local len = 2 * (r0 + 1.5) * math.tan(math.pi / n) * 0.85
		local p = take("Block", P.crimson_300, Vector3.new(len, 0.04, 0.55), 1)
		p.CFrame = segCF(x, y + Y_EDGE, z, a, r0 + 1.2)
		table.insert(rec.Feet, p)
		local d = take("Block", C.Outline, Vector3.new(len * 1.1, 0.04, 1.0), 1)
		d.CFrame = segCF(x, y + Y_RIM, z, a, r0 + 1.2)
		table.insert(rec.FeetDark, d)
	end
	-- the safe lane: two lines along the gap edges and chevrons pointing outward
	local laneLen = math.min(maxR, 34) - r0
	rec.Lane = {}
	for _, side in ipairs({ -1, 1 }) do
		local a = gap + side * gapHalf * 0.92
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local mid = Vector3.new(x, y + Y_MARK, z) + dir * (r0 + laneLen / 2)
		local p = take("Block", P.ivory_200, Vector3.new(0.3, 0.04, laneLen), 1)
		p.CFrame = CFrame.lookAt(mid, mid + dir)
		table.insert(rec.Lane, p)
	end
	local gdir = Vector3.new(math.cos(gap), 0, math.sin(gap))
	for k = 1, 3 do
		local at = Vector3.new(x, y + Y_MARK, z) + gdir * (r0 + 3 + k * 4.5)
		for side = -1, 1, 2 do
			local p = take("Block", P.gold_300, Vector3.new(0.3, 0.04, 2.2), 1)
			p.CFrame = CFrame.lookAt(at, at + gdir) * CFrame.Angles(0, side * math.rad(38), 0) * CFrame.new(0, 0, 0.9)
			table.insert(rec.Lane, p)
		end
	end
	-- the rolling ring (dust body, crimson leading edge)
	rec.Ring = {}
	rec.Front = {}
	for _ = 1, #rec.Angles do
		table.insert(rec.Ring, take("Block", C.Dust:Lerp(P.crimson_400, 0.3), Vector3.new(1, 0.04, 1), 1))
		table.insert(rec.Front, take("Block", P.crimson_400, Vector3.new(1, 0.04, 0.4), 1))
	end
	function rec.Update(t: number): boolean
		if t >= rec.Dur + FADE_OUT then
			return false
		end
		local gather = math.clamp(t / math.max(0.1, rec.Delay), 0, 1)
		local before = t < rec.Delay
		local vin = math.min(1, t / FADE_IN)
		-- feet ring and lane: strong while gathering, fading once the wave rolls
		local after = math.clamp((t - rec.Delay) / 1.2, 0, 1)
		local pulse = 0.7 + 0.3 * math.sin(t * (6 + 14 * gather))
		setAlpha(rec.Feet, 1 - 0.9 * pulse * vin * (1 - after))
		setAlpha(rec.FeetDark, 1 - 0.55 * vin * (1 - after))
		setAlpha(rec.Lane, 1 - 0.85 * vin * (1 - after * 0.7))
		if before then
			setAlpha(rec.Ring, 1)
			setAlpha(rec.Front, 1)
			return true
		end
		local rr = rec.R0 + (t - rec.Delay) * rec.Speed
		local fade = 1 - math.clamp((rr - (rec.MaxR - 8)) / 8, 0, 1)
		fade *= 1 - math.clamp((t - rec.Dur) / FADE_OUT, 0, 1)
		local len = 2 * rr * math.tan(math.pi / rec.N) * 1.05
		for i, a in ipairs(rec.Angles) do
			local body = rec.Ring[i]
			body.Size = Vector3.new(math.max(0.05, len), 0.04, rec.W)
			body.Transparency = 1 - 0.55 * fade
			bulk(body, segCF(rec.X, FLOOR_Y + Y_FILL, rec.Z, a, rr))
			local front = rec.Front[i]
			front.Size = Vector3.new(math.max(0.05, len), 0.04, 0.45)
			front.Transparency = 1 - 0.85 * fade
			bulk(front, segCF(rec.X, FLOOR_Y + Y_EDGE, rec.Z, a, rr + rec.W / 2 - 0.2))
		end
		return true
	end
	function rec.Release()
		giveAll("Block", rec.Feet)
		giveAll("Block", rec.FeetDark)
		giveAll("Block", rec.Lane)
		giveAll("Block", rec.Ring)
		giveAll("Block", rec.Front)
	end
	return rec
end

--[[
	Bramble ring (Briar Sentinel): while it gathers (delay) a thorny ring of radius r0
	shows with one opening, and ivory lines + gold chevrons point the way out through the
	gap; then the ring closes in (speed studs/s) down to minR, the gap kept open. The
	ring is dark bramble with a crimson inner edge (the side that hits you first).
]]
Kind.bramble = function(x: number, z: number, r0: number, delay: number, speed: number, minR: number, width: number, gap: number, gapHalf: number)
	local rec: any = { X = x, Z = z, R0 = r0, Delay = math.max(0, delay), Speed = math.max(1, speed), MinR = minR, W = math.max(0.5, width), Gap = gap, Half = gapHalf }
	rec.Dur = rec.Delay + math.max(0, r0 - minR) / rec.Speed
	local n = 64
	rec.N = n
	rec.Angles = {}
	for i = 1, n do
		local a = (i - 0.5) * TAU / n
		if angleGap(a, gap) > gapHalf then
			table.insert(rec.Angles, a)
		end
	end
	local y = FLOOR_Y
	-- the way out: two lines along the gap edges and chevrons pointing outward
	rec.Lane = {}
	local laneIn = math.max(minR, r0 - 14)
	for _, side in ipairs({ -1, 1 }) do
		local a = gap + side * gapHalf * 0.9
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local mid = Vector3.new(x, y + Y_MARK, z) + dir * ((laneIn + r0 + 3) / 2)
		local p = take("Block", P.ivory_200, Vector3.new(0.3, 0.04, r0 + 3 - laneIn), 1)
		p.CFrame = CFrame.lookAt(mid, mid + dir)
		table.insert(rec.Lane, p)
	end
	local gdir = Vector3.new(math.cos(gap), 0, math.sin(gap))
	for k = 0, 2 do
		local at = Vector3.new(x, y + Y_MARK, z) + gdir * (r0 - 8 + k * 4.5)
		for side = -1, 1, 2 do
			local p = take("Block", P.gold_300, Vector3.new(0.3, 0.04, 2.2), 1)
			p.CFrame = CFrame.lookAt(at, at + gdir) * CFrame.Angles(0, side * math.rad(38), 0) * CFrame.new(0, 0, 0.9)
			table.insert(rec.Lane, p)
		end
	end
	-- the closing ring: dark outline, bramble body, crimson inner edge, thorn ticks
	rec.Dark, rec.Body, rec.Edge, rec.Ticks = {}, {}, {}, {}
	for k = 1, #rec.Angles do
		table.insert(rec.Dark, take("Block", C.Outline, Vector3.new(1, 0.04, 1), 1))
		table.insert(rec.Body, take("Block", P.crimson_800:Lerp(P.wood_700, 0.45), Vector3.new(1, 0.04, 1), 1))
		table.insert(rec.Edge, take("Block", P.crimson_400, Vector3.new(1, 0.04, 0.4), 1))
		if k % 2 == 0 then
			table.insert(rec.Ticks, { Part = take("Wedge", P.crimson_800, Vector3.new(0.35, 1.1, 0.8), 1), A = rec.Angles[k] })
		end
	end
	function rec.Update(t: number): boolean
		if t >= rec.Dur + FADE_OUT then
			return false
		end
		local vin = math.min(1, t / FADE_IN)
		local gather = math.clamp(t / math.max(0.1, rec.Delay), 0, 1)
		local after = math.clamp((t - rec.Delay) / 1.0, 0, 1)
		setAlpha(rec.Lane, 1 - 0.85 * vin * (1 - after * 0.6))
		local rr = math.max(rec.MinR, rec.R0 - math.max(0, t - rec.Delay) * rec.Speed)
		local fade = vin * (1 - math.clamp((t - rec.Dur) / FADE_OUT, 0, 1))
		local before = t < rec.Delay
		-- while it gathers the ring pulses in place; then it closes
		local pulse = before and (0.55 + 0.35 * math.sin(t * (6 + 12 * gather))) or 1
		local len = 2 * (rr + rec.W / 2) * math.tan(math.pi / rec.N) * 1.05
		for i, a in ipairs(rec.Angles) do
			local dark = rec.Dark[i]
			dark.Size = Vector3.new(math.max(0.05, len), 0.04, rec.W + 0.7)
			dark.Transparency = 1 - 0.55 * fade
			bulk(dark, segCF(rec.X, FLOOR_Y + Y_RIM, rec.Z, a, rr))
			local body = rec.Body[i]
			body.Size = Vector3.new(math.max(0.05, len), 0.04, rec.W)
			body.Transparency = 1 - 0.75 * fade * pulse
			bulk(body, segCF(rec.X, FLOOR_Y + Y_FILL, rec.Z, a, rr))
			local edge = rec.Edge[i]
			edge.Size = Vector3.new(math.max(0.05, len), 0.04, 0.45)
			edge.Transparency = 1 - 0.9 * fade * pulse
			bulk(edge, segCF(rec.X, FLOOR_Y + Y_EDGE, rec.Z, a, rr - rec.W / 2 + 0.25))
		end
		for _, tk in ipairs(rec.Ticks) do
			local c, s = math.cos(tk.A), math.sin(tk.A)
			tk.Part.Transparency = 1 - 0.9 * fade
			-- a thorn standing up out of the ring, leaning inward
			local at = Vector3.new(rec.X + c * rr, FLOOR_Y + 0.5, rec.Z + s * rr)
			bulk(tk.Part, CFrame.lookAt(at, at - Vector3.new(c, 0, s)) * CFrame.Angles(-0.35, 0, 0))
		end
		return true
	end
	function rec.Release()
		giveAll("Block", rec.Lane)
		giveAll("Block", rec.Dark)
		giveAll("Block", rec.Body)
		giveAll("Block", rec.Edge)
		for _, tk in ipairs(rec.Ticks) do
			give("Wedge", tk.Part)
		end
	end
	return rec
end

-- Glimmer mine: a pale mote drifts from the Matriarch to its spot, hovers and blinks
-- (slow, then fast) over a dashed circle that fills until it pops.
Kind.mine = function(x: number, z: number, radius: number, seconds: number, fromX: number?, fromZ: number?)
	local rec: any = Kind.circle(x, z, radius, seconds, "glimmer")
	local inner = rec.Update
	local innerRelease = rec.Release
	local from = Vector3.new(tonumber(fromX) or x, FLOOR_Y + 6, tonumber(fromZ) or z)
	local to = Vector3.new(x, FLOOR_Y + 1.7, z)
	local core = take("Ball", P.moth_glow, Vector3.one * 1.0, 0, NEON)
	local halo = take("Ball", P.gold_200, Vector3.one * 2.0, 0.6, NEON)
	function rec.Update(t: number): boolean
		local alive = inner(t)
		local u = math.clamp(t / rec.Dur, 0, 1)
		local fly = math.clamp(t / 0.5, 0, 1)
		local e = 1 - (1 - fly) * (1 - fly)
		local pos = from:Lerp(to, e) + Vector3.new(0, 2.5 * 4 * e * (1 - e) + math.sin(t * 3) * 0.2 * fly, 0)
		local hz = 1.2 + 7 * u * u
		local on = ClientSettings.Flashes() or math.sin(t * hz * TAU) > 0
		core.Transparency = on and 0 or 0.45
		halo.Transparency = on and 0.55 or 0.85
		halo.Size = Vector3.one * (1.6 + 0.6 * u)
		bulk(core, CFrame.new(pos))
		bulk(halo, CFrame.new(pos))
		return alive
	end
	function rec.Release()
		innerRelease()
		give("Ball", core)
		give("Ball", halo)
	end
	return rec
end

-- Wing gust: an ivory wind cone (edges, end arc, streaks drifting outward); it pushes,
-- it never hurts, so it stays out of the crimson family. yaw = math.atan2(z, x).
-- style "frost": the same cone for the Colossus's freezing breath, crimson-edged.
Kind.gust = function(x: number, z: number, yaw: number, length: number, halfAngle: number, seconds: number, blow: number?, style: string?)
	-- "frost" (the Colossus's freezing breath): it hurts, so crimson edges over an icy wash
	local frost = style == "frost"
	local lineC = frost and P.crimson_300 or P.ivory_200
	local washC = frost and P.crimson_700:Lerp(P.ice_500, 0.3) or P.slate_300
	local streakC = frost and P.ice_100 or P.ivory_100
	local rec: any = { Dur = math.max(0.1, seconds) + (tonumber(blow) or 0.5), Wind = math.max(0.1, seconds), X = x, Z = z, Yaw = yaw, Len = length, Half = halfAngle, WashK = frost and 1.6 or 1 }
	local y = FLOOR_Y
	local origin = Vector3.new(x, y + Y_EDGE, z)
	rec.Lines = {}
	for _, side in ipairs({ -1, 1 }) do
		local a = yaw + side * halfAngle
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local mid = origin + dir * (length / 2 + 2)
		local p = take("Block", lineC, Vector3.new(0.35, 0.04, length - 4), 1)
		p.CFrame = CFrame.lookAt(mid, mid + dir)
		table.insert(rec.Lines, p)
		local d = take("Block", C.Outline, Vector3.new(0.75, 0.04, length - 4), 1)
		d.CFrame = CFrame.lookAt(mid - Vector3.new(0, 0.01, 0), mid + dir)
		table.insert(rec.Lines, d)
	end
	local arcN = math.clamp(math.floor(length * halfAngle * 2 / 2.2), 6, 30)
	for k = 1, arcN do
		local a = yaw - halfAngle + (k - 0.5) * (2 * halfAngle / arcN)
		local len = 2 * length * math.tan(halfAngle / arcN) * 0.8
		local p = take("Block", lineC, Vector3.new(len, 0.04, 0.35), 1)
		p.CFrame = segCF(x, y + Y_EDGE, z, a, length)
		table.insert(rec.Lines, p)
	end
	-- a pale floor wash
	rec.Wash = {}
	for k = 1, 7 do
		local a = yaw - halfAngle + (k - 0.5) * (2 * halfAngle / 7)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local mid = Vector3.new(x, y + Y_ZONE, z) + dir * (length / 2 + 1)
		local wdt = 2 * (length / 2 + 1) * math.tan(halfAngle / 7) * 1.1
		local p = take("Block", washC, Vector3.new(wdt, 0.04, length - 2), 1)
		p.CFrame = CFrame.lookAt(mid, mid + dir)
		table.insert(rec.Wash, p)
	end
	-- streaks that drift outward (faster once it blows)
	rec.Streaks = {}
	for k = 1, 9 do
		local p = take("Block", streakC, Vector3.new(0.25, 0.04, 2.6), 1)
		table.insert(rec.Streaks, { Part = p, A = yaw + (math.random() * 2 - 1) * halfAngle * 0.85, Off = math.random() })
	end
	function rec.Update(t: number): boolean
		local dur = rec.Dur
		if t >= dur + FADE_OUT then
			return false
		end
		local v = vis(t, dur)
		local blowing = t >= rec.Wind
		setAlpha(rec.Lines, 1 - (blowing and 0.55 or 0.8) * v)
		setAlpha(rec.Wash, 1 - (blowing and 0.3 or 0.18 + 0.1 * math.sin(t * 10)) * v * rec.WashK)
		local speed = blowing and 1.6 or 0.6
		for _, s in ipairs(rec.Streaks) do
			local f = (s.Off + t * speed) % 1
			local dir = Vector3.new(math.cos(s.A), 0, math.sin(s.A))
			local at = Vector3.new(rec.X, FLOOR_Y + Y_MARK, rec.Z) + dir * (4 + f * (rec.Len - 6))
			s.Part.Transparency = 1 - 0.85 * v * math.sin(f * math.pi)
			bulk(s.Part, CFrame.lookAt(at, at + dir))
		end
		return true
	end
	function rec.Release()
		giveAll("Block", rec.Lines)
		giveAll("Block", rec.Wash)
		for _, s in ipairs(rec.Streaks) do
			give("Block", s.Part)
		end
	end
	return rec
end

-- Emerge: the soil cracks open and heaves (a summon climbs out at the end).
Kind.emerge = function(x: number, z: number, seconds: number)
	local rec: any = { Dur = math.max(0.1, seconds), X = x, Z = z }
	rec.Rim = disc(C.Outline, 4.6, 1, x, FLOOR_Y + Y_RIM, z)
	rec.Hole = disc(P.dirt_700, 0.1, 1, x, FLOOR_Y + Y_ZONE, z)
	rec.Ring = ring(16, P.amber_300, 1, x, FLOOR_Y + Y_EDGE, z, 2.1, 0.26, 0.55)
	rec.Cracks = {}
	for k = 1, 5 do
		local a = k * TAU / 5 + math.random() * 0.5
		local p = take("Block", P.chitin_900, Vector3.new(0.18, 0.04, 0.1), 1)
		table.insert(rec.Cracks, { Part = p, A = a })
	end
	rec.Chunks = {}
	for k = 1, 4 do
		local p = take("Block", (k % 2 == 0) and P.dirt_500 or C.DustDark, Vector3.one * 0.6, 1)
		table.insert(rec.Chunks, { Part = p, A = k * TAU / 4 + math.random(), Ph = math.random() * 6 })
	end
	function rec.Update(t: number): boolean
		local dur = rec.Dur
		if t >= dur then
			POP.dust(rec.X, rec.Z, 3)
			return false
		end
		local u = t / dur
		local v = math.min(1, t / FADE_IN)
		rec.Rim.Transparency = 1 - 0.5 * v
		setDisc(rec.Hole, 3.6 * u)
		rec.Hole.Transparency = 1 - 0.8 * v
		setAlpha(rec.Ring, 1 - (0.5 + 0.4 * math.sin(t * 12)) * v)
		for _, cr in ipairs(rec.Cracks) do
			local len = 0.4 + 2.2 * u
			local dir = Vector3.new(math.cos(cr.A), 0, math.sin(cr.A))
			local mid = Vector3.new(rec.X, FLOOR_Y + Y_MARK, rec.Z) + dir * (len / 2)
			cr.Part.Size = Vector3.new(0.18, 0.04, len)
			cr.Part.Transparency = 1 - v
			bulk(cr.Part, CFrame.lookAt(mid, mid + dir))
		end
		for _, ch in ipairs(rec.Chunks) do
			local hop = math.abs(math.sin(t * (6 + 10 * u) + ch.Ph)) * (0.2 + 0.8 * u)
			local at = Vector3.new(rec.X + math.cos(ch.A) * 1.4, FLOOR_Y + 0.3 + hop, rec.Z + math.sin(ch.A) * 1.4)
			ch.Part.Transparency = 1 - v
			bulk(ch.Part, CFrame.new(at) * CFrame.Angles(t * 3 + ch.Ph, t * 2, 0))
		end
		return true
	end
	function rec.Release()
		give("Cylinder", rec.Rim)
		give("Cylinder", rec.Hole)
		giveAll("Block", rec.Ring)
		for _, cr in ipairs(rec.Cracks) do
			give("Block", cr.Part)
		end
		for _, ch in ipairs(rec.Chunks) do
			give("Block", ch.Part)
		end
	end
	return rec
end

-- The War Banner's rally zone: a slowly turning dashed crimson ring over a faint wash,
-- shown while the banner stands (the server cancels it when the banner falls).
Kind.aura = function(x: number, z: number, radius: number, seconds: number)
	local r = math.max(1, radius)
	local rec: any = { Dur = math.max(0.1, seconds), X = x, Z = z, R = r }
	rec.Wash = disc(P.crimson_700, r * 2, 1, x, FLOOR_Y + Y_RIM - 0.01, z)
	local n = math.clamp(math.floor(TAU * r / 2.6), 16, 56)
	rec.N = n
	rec.Dash = ring(n, P.crimson_300, 1, x, FLOOR_Y + Y_EDGE, z, r - 0.2, 0.4, 0.55)
	rec.Gold = ring(math.floor(n * 0.6), P.gold_400, 1, x, FLOOR_Y + Y_EDGE, z, r * 0.55, 0.22, 0.4)
	function rec.Update(t: number): boolean
		if t >= rec.Dur + FADE_OUT then
			return false
		end
		local v = vis(t, rec.Dur)
		rec.Wash.Transparency = 1 - 0.16 * v
		local spin = t * 0.25
		for i, p in ipairs(rec.Dash) do
			p.Transparency = 1 - 0.7 * v
			bulk(p, segCF(rec.X, FLOOR_Y + Y_EDGE, rec.Z, spin + (i - 0.5) * TAU / rec.N, rec.R - 0.2))
		end
		local m = #rec.Gold
		for i, p in ipairs(rec.Gold) do
			p.Transparency = 1 - (0.45 + 0.2 * math.sin(t * 3)) * v
			bulk(p, segCF(rec.X, FLOOR_Y + Y_EDGE, rec.Z, -spin * 1.5 + (i - 0.5) * TAU / m, rec.R * 0.55))
		end
		return true
	end
	function rec.Release()
		give("Cylinder", rec.Wash)
		giveAll("Block", rec.Dash)
		giveAll("Block", rec.Gold)
	end
	return rec
end

-- Sound cues for the new shapes (VFX plays the older ones).
local CUES: { [string]: string } = {
	wave = "BossWave",
	band = "BossPound",
	mine = "BossMine",
	gust = "BossGust",
	emerge = "BossEmerge",
	aura = "BossBanner",
	bramble = "BossWave",
}

------------------------------------------------------------------------------------------
-- Dispatch
------------------------------------------------------------------------------------------

local function clearWarn(id: number)
	if id == 0 then
		for key, rec in pairs(recs) do
			rec.Release()
			recs[key] = nil
		end
		return
	end
	local rec = recs[id]
	if rec then
		rec.Release()
		recs[id] = nil
	end
end

local function onWarn(w: { any })
	local id, kind = w[1], w[2]
	if type(id) ~= "number" or type(kind) ~= "string" then
		return
	end
	if kind == "pop" then
		local fn = POP[tostring(w[6])]
		if fn and type(w[3]) == "number" and type(w[4]) == "number" then
			fn(w[3], w[4], tonumber(w[5]) or 3, w[7])
		end
		return
	end
	local sound = CUES[kind]
	if sound and type(w[3]) == "number" and type(w[4]) == "number" then
		cue(sound, w[3], w[4])
	end
	local make = Kind[kind]
	if not make then
		return
	end
	local ok, rec = pcall(make, table.unpack(w, 3))
	if not ok or not rec then
		return
	end
	if recs[id] then
		clearWarn(id)
	end
	rec.Start = os.clock()
	recs[id] = rec
end

local function onFxBatch(batch)
	if type(batch) ~= "table" then
		return
	end
	if type(batch.x) == "table" then
		for _, id in ipairs(batch.x) do
			if type(id) == "number" then
				clearWarn(id)
			end
		end
	end
	if type(batch.w) == "table" then
		for _, w in ipairs(batch.w) do
			if type(w) == "table" then
				onWarn(w)
			end
		end
	end
end

local state: Instance? = nil
local lastStep = os.clock()

local function step()
	local now = os.clock()
	local dt = now - lastStep
	lastStep = now
	-- the run is frozen (pause menu, level-up choice): the server's timers stop, so the
	-- warnings hold their progress too and still match the hit when the run resumes
	if state and state:GetAttribute("Frozen") == true then
		for _, rec in pairs(recs) do
			rec.Start += dt
		end
	end
	for id, rec in pairs(recs) do
		local ok, alive = pcall(rec.Update, now - rec.Start)
		if not ok or not alive then
			rec.Release()
			recs[id] = nil
		end
	end
	stepAnims(now)
	flush()
end

-- Number of live warnings (preview / debug).
function Telegraphs.Count(): number
	local n = 0
	for _ in pairs(recs) do
		n += 1
	end
	return n
end

local started = false
function Telegraphs.Init()
	if started then
		return
	end
	started = true
	local f = Instance.new("Folder")
	f.Name = "SwarmTelegraphs"
	f.Parent = workspace
	folder = f
	Remotes.Get("FxBatch").OnClientEvent:Connect(onFxBatch)
	task.spawn(function()
		state = Remotes.State()
	end)
	RunService.RenderStepped:Connect(step)
end

return Telegraphs
