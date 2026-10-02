--[[
	VFX.lua
	All client-side visuals. Nothing here affects gameplay.

	Look (docs/ART_DIRECTION.md §7): restrained and informative. Colours come from the
	shared palette (Theme.Fx). Surfaces are SmoothPlastic with transparency; Neon only for
	tiny cores and sparks; lifetimes short, alpha low, trails thin, no shadows.

	* Projectiles: decodes the ProjectileBatch buffer (see WeaponSystem) and moves pooled
	  local models with interpolation between batches (one workspace:BulkMoveTo per frame).
	  Each visual style spins/tumbles from time alone, gets a pooled thin Trail and a small
	  impact puff (or glass shatter) when it disappears.
	* Effects from FxBatch: hit sparks, creature-tinted death dust, sword arcs, lightning,
	  pools, explosions, shockwave rings, player events (telegraphs: Telegraphs.lua). One-shot effects
	  run on a small pooled animator (no Tween objects, no Instance churn once warm) inside
	  a part budget (Config.Graphics.MaxEffectParts); warnings and player events always play.
	* Gems: faceted octahedron crystals (eight pooled WedgeParts for the gems nearest the
	  hero, the server cube on its corner for the rest), sized by value, with a gentle bob,
	  a rare glint and a burst when collected; floor pickups bob and spin; chests glow.
	* Gold: coins (GoldCoin / GoldPile meshes) burst out of an enemy whose kill paid gold,
	  bounce once and fly to the player (FxBatch "g"); the HUD shows the "+N".
	* Players: gold ring under the local player (slate-blue under teammates) with a facing
	  chevron, a small overhead health bar, the garlic / soul eater aura ring.
	* Combat juice (impact / crit stars, kill shards, elite and boss kill bursts, level-up
	  pillar, swing-tip sparks, pickup sparkles, evolution and boss phase flashes) lives in
	  CombatFx.lua with its own pooled budget; VFX calls into it.
	* Heroes: procedural walk cycle (arm swing, body bob and lean), idle breathing and attack
	  poses (sword swing / throw / cast) through each rig's own Motor6Ds.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local Theme = require(Shared:WaitForChild("Theme"))
local Audio = require(script.Parent.Audio)
local ClientSettings = require(script.Parent.ClientSettings)
local ModelLibrary = require(script.Parent.ModelLibrary)
local EnemyRenderer = require(script.Parent.EnemyRenderer)
local CameraController = require(script.Parent.CameraController)
local Occlusion = require(script.Parent.Occlusion)
local CombatFx = require(script.Parent.CombatFx)

local VFX = {}
-- Tuning constants live in one table: a module chunk may hold at most 200 locals.
local K: any = {}

local P = Theme.Palette
local FX = Theme.Fx

local player = Players.LocalPlayer
local PARK = CFrame.new(0, -150, 0) -- under the floor, above FallenPartsDestroyHeight
local FLOOR_Y = Config.ArenaOrigin.Y
local GRAPHICS = Config.Graphics :: any
local MAX_FX_PARTS: number = GRAPHICS.MaxEffectParts or 220
local MAX_TRAILS: number = GRAPHICS.MaxTrails or 40
local TAU = math.pi * 2
local WHITE = Color3.new(1, 1, 1)
local SMOOTH = Enum.Material.SmoothPlastic
local NEON = Enum.Material.Neon
local DISC = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X → Y: a flat disc

local fxFolder: Folder
local onLocalEvent: ((string) -> ())? = nil

------------------------------------------------------------------------------------------
-- Colours
------------------------------------------------------------------------------------------

-- Server effects send free RGB colours (rings); bring them into the palette by hue.
local function paletteColor(c: Color3): Color3
	local h, s, v = c:ToHSV()
	if s < 0.22 then
		return v > 0.55 and FX.Hit or P.stone_300
	end
	local deg = h * 360
	if deg < 18 or deg >= 290 then
		return P.crimson_400 -- reds and pinks: danger
	elseif deg < 68 then
		return FX.Gold
	elseif deg < 165 then
		return FX.Heal
	elseif deg < 250 then
		return FX.Arcane
	end
	return P.crimson_300 -- violet: the boss's magic
end

--[[
	Death dust: the server sends the body colour of the enemy that died; find the creature
	it belongs to (EnemyData colours, plain or elite-tinted) and use that creature's colour
	from the palette, lightened into dust, plus the colour of the chitin bits.
]]
local ELITE_TINT = Color3.fromRGB(255, 210, 60) -- ModelBuilder tints elite bodies toward this
local CREATURE: { [string]: { Dust: Color3, Bits: Color3 } } = {
	Slime = { Dust = P.beetle_300, Bits = P.chitin_900 },
	Bat = { Dust = P.wasp_500, Bits = P.wasp_900 },
	Skeleton = { Dust = P.beetle_600, Bits = P.chitin_900 },
	Ghost = { Dust = P.moth_300, Bits = P.moth_500 },
	Brute = { Dust = P.slate_400, Bits = P.chitin_800 },
	Bomber = { Dust = P.tick_500, Bits = P.chitin_900 },
	Spitter = { Dust = P.crimson_500:Lerp(P.slate_400, 0.5), Bits = P.chitin_900 }, -- EnemyData colour
	Boss = { Dust = P.crimson_500, Bits = P.gold_500 },
}
type CreatureKey = { Color: Color3, Dust: Color3, Bits: Color3 }
local creatureKeys: { CreatureKey } = {}
for id, def in pairs(EnemyData.Enemies) do
	local look = CREATURE[id]
	if look and typeof(def.Color) == "Color3" then
		local dust = look.Dust:Lerp(P.ivory_200, 0.4)
		table.insert(creatureKeys, { Color = def.Color, Dust = dust, Bits = look.Bits })
		table.insert(creatureKeys, { Color = def.Color:Lerp(ELITE_TINT, 0.35), Dust = dust:Lerp(P.gold_300, 0.45), Bits = look.Bits })
	end
end

local function creatureLook(c: Color3): (Color3, Color3)
	local best: CreatureKey? = nil
	local bestD = 0.03
	for _, k in ipairs(creatureKeys) do
		local dr, dg, db = k.Color.R - c.R, k.Color.G - c.G, k.Color.B - c.B
		local d = dr * dr + dg * dg + db * db
		if d < bestD then
			best, bestD = k, d
		end
	end
	if best then
		return best.Dust, best.Bits
	end
	local h, s, v = c:ToHSV()
	return Color3.fromHSV(h, math.min(s, 0.35), math.clamp(v, 0.5, 0.78)), P.chitin_900
end

------------------------------------------------------------------------------------------
-- Part pools and the shared bulk move
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
	p.Parent = fxFolder
	return p
end

local function takePart(shape: string, color: Color3, material: Enum.Material, size: Vector3, alpha: number): BasePart
	local p = table.remove(pools[shape]) or newPart(shape)
	p.Color = color
	p.Material = material
	p.Size = size
	p.Transparency = alpha
	return p
end

local function givePart(shape: string, p: BasePart)
	p.CFrame = PARK
	table.insert(pools[shape], p)
end

-- Parts moved this frame, flushed with one workspace:BulkMoveTo at the end of the frame.
local bulkParts: { BasePart } = {}
local bulkCFrames: { CFrame } = {}
local bulkN = 0

local function bulk(p: BasePart, cf: CFrame)
	bulkN += 1
	bulkParts[bulkN] = p
	bulkCFrames[bulkN] = cf
end

local function flushBulk()
	for i = #bulkParts, bulkN + 1, -1 do
		bulkParts[i] = nil
		bulkCFrames[i] = nil
	end
	if bulkN > 0 then
		workspace:BulkMoveTo(bulkParts, bulkCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	bulkN = 0
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

------------------------------------------------------------------------------------------
-- One-shot effect animator (pooled records instead of Tweens)
------------------------------------------------------------------------------------------

local EASE_LINEAR, EASE_OUT, EASE_OUT3 = 0, 1, 2

local function ease(kind: number, u: number): number
	if kind == EASE_OUT then
		local v = 1 - u
		return 1 - v * v
	elseif kind == EASE_OUT3 then
		local v = 1 - u
		return 1 - v * v * v
	end
	return u
end

local function easeOut(u: number): number
	local v = 1 - math.clamp(u, 0, 1)
	return 1 - v * v * v
end

type Anim = {
	Part: BasePart,
	Shape: string,
	Start: number,
	Dur: number,
	Ease: number,
	CF0: CFrame,
	CF1: CFrame?,
	Arc: number,
	S0: Vector3,
	S1: Vector3?,
	A0: number,
	A1: number,
	FadeIn: number,
	Pow: number,
}

local anims: { Anim } = {}
local spareAnims: { Anim } = {}
local fxParts = 0 -- effect parts in use (animator, waves, pools)

-- Settings > Reduced effects: cosmetic effect and trail budgets shrink to this share.
local function budgetScale(): number
	return ClientSettings.Reduced() and (GRAPHICS.ReducedEffectsBudget or 0.4) or 1
end

-- Room for `count` more effect parts? Warnings (critical) may use half again the budget
-- (never reduced: telegraphs are gameplay information).
local function room(count: number, critical: boolean?): boolean
	local cap = critical and MAX_FX_PARTS * 1.5 or MAX_FX_PARTS * budgetScale()
	return fxParts + count <= cap
end

--[[
	One-shot effect part: grows from size0 to size1 and fades from a0 to a1 over `dur`
	seconds; with cf1 it also travels from cf0 to cf1 (plus `arc` studs of hop at mid-
	flight). fadeIn = share of the life spent appearing; pow > 1 keeps it solid longer
	before it fades. The caller checks room() first.
]]
local function fx(
	shape: string,
	color: Color3,
	material: Enum.Material,
	cf0: CFrame,
	cf1: CFrame?,
	size0: Vector3,
	size1: Vector3?,
	a0: number,
	a1: number,
	dur: number,
	easing: number?,
	arc: number?,
	fadeIn: number?,
	pow: number?
)
	local fin = fadeIn or 0
	local p = takePart(shape, color, material, size0, fin > 0 and 1 or a0)
	p.CFrame = cf0
	local rec: Anim = table.remove(spareAnims) or ({} :: any)
	rec.Part = p
	rec.Shape = shape
	rec.Start = os.clock()
	rec.Dur = math.max(dur, 0.01)
	rec.Ease = easing or EASE_LINEAR
	rec.CF0 = cf0
	rec.CF1 = cf1
	rec.Arc = arc or 0
	rec.S0 = size0
	rec.S1 = size1
	rec.A0 = a0
	rec.A1 = a1
	rec.FadeIn = fin
	rec.Pow = pow or 1
	table.insert(anims, rec)
	fxParts += 1
end

local function stepAnims(now: number)
	local i = 1
	while i <= #anims do
		local a = anims[i]
		local u = (now - a.Start) / a.Dur
		if u >= 1 then
			givePart(a.Shape, a.Part)
			fxParts -= 1
			anims[i] = anims[#anims]
			anims[#anims] = nil
			table.insert(spareAnims, a)
		else
			local e = ease(a.Ease, u)
			local p = a.Part
			local s1 = a.S1
			if s1 then
				p.Size = a.S0:Lerp(s1, e)
			end
			local fin = a.FadeIn
			if fin > 0 and u < fin then
				p.Transparency = 1 + (a.A0 - 1) * (u / fin)
			else
				local f = (u - fin) / (1 - fin)
				if a.Pow ~= 1 then
					f = f ^ a.Pow
				end
				p.Transparency = a.A0 + (a.A1 - a.A0) * f
			end
			local cf1 = a.CF1
			if cf1 then
				local cf = a.CF0:Lerp(cf1, e)
				if a.Arc ~= 0 then
					cf += Vector3.new(0, a.Arc * 4 * u * (1 - u), 0)
				end
				bulk(p, cf)
			end
			i += 1
		end
	end
end

------------------------------------------------------------------------------------------
-- Rings: thin block segments around a circle (markers, auras, shockwaves)
------------------------------------------------------------------------------------------

type Ring = { Parts: { BasePart }, N: number, R: number, Width: number, Dash: number, Color: Color3, Alpha: number }

local function newRing(n: number): Ring
	local parts = table.create(n)
	for i = 1, n do
		parts[i] = newPart("Block")
	end
	return { Parts = parts, N = n, R = -1, Width = -1, Dash = -1, Color = WHITE, Alpha = -1 }
end

-- Segment look; writes only what changed. dash < 1 leaves gaps between segments.
local function styleRing(ring: Ring, radius: number, width: number, color: Color3, alpha: number, dash: number?)
	local d = dash or 1
	if math.abs(ring.R - radius) > 0.02 or ring.Width ~= width or ring.Dash ~= d then
		ring.R, ring.Width, ring.Dash = radius, width, d
		local len = 2 * (radius + width / 2) * math.tan(math.pi / ring.N) * d
		local size = Vector3.new(math.max(0.05, len), 0.05, width)
		for _, p in ipairs(ring.Parts) do
			p.Size = size
		end
	end
	if ring.Color ~= color then
		ring.Color = color
		for _, p in ipairs(ring.Parts) do
			p.Color = color
		end
	end
	if ring.Alpha ~= alpha then
		ring.Alpha = alpha
		for _, p in ipairs(ring.Parts) do
			p.Transparency = alpha
		end
	end
end

-- Queues the segments around (x, y, z), turned by `spin` radians.
local function placeRing(ring: Ring, x: number, y: number, z: number, spin: number)
	local n = ring.N
	local r = ring.R
	local step = TAU / n
	for i = 1, n do
		local a = spin + (i - 0.5) * step
		local c, s = math.cos(a), math.sin(a)
		-- length (local X) along the tangent, width (local Z) along the radius
		bulk(ring.Parts[i], CFrame.new(x + c * r, y, z + s * r, s, 0, c, 0, 1, 0, -c, 0, s))
	end
end

local function hideRing(ring: Ring)
	for _, p in ipairs(ring.Parts) do
		p.CFrame = PARK
	end
end

local function destroyRing(ring: Ring?)
	if ring then
		for _, p in ipairs(ring.Parts) do
			p:Destroy()
		end
	end
end

-- Expanding rings on the floor (shockwaves, level-up, heal, revive).
type Wave = { Ring: Ring, X: number, Z: number, R0: number, R1: number, W: number, Color: Color3, A0: number, Start: number, Dur: number, Spin: number }
local waves: { Wave } = {}
local ringPool: { [number]: { Ring } } = {}

local function wave(x: number, z: number, r0: number, r1: number, width: number, color: Color3, a0: number, dur: number, critical: boolean?): boolean
	local n = r1 > 40 and 40 or (r1 > 14 and 28 or 18)
	if not room(n, critical) then
		return false
	end
	local list = ringPool[n]
	local ring = list and table.remove(list) or newRing(n)
	fxParts += n
	table.insert(waves, { Ring = ring, X = x, Z = z, R0 = r0, R1 = r1, W = width, Color = color, A0 = a0, Start = os.clock(), Dur = dur, Spin = math.random() * TAU })
	return true
end

local function stepWaves(now: number)
	for i = #waves, 1, -1 do
		local w = waves[i]
		local u = (now - w.Start) / w.Dur
		if u >= 1 then
			hideRing(w.Ring)
			local list = ringPool[w.Ring.N]
			if not list then
				list = {}
				ringPool[w.Ring.N] = list
			end
			table.insert(list, w.Ring)
			fxParts -= w.Ring.N
			waves[i] = waves[#waves]
			waves[#waves] = nil
		else
			local r = w.R0 + (w.R1 - w.R0) * ease(EASE_OUT3, u)
			-- crisp while it travels, gone by the end
			styleRing(w.Ring, r, w.W * (1 - 0.45 * u), w.Color, w.A0 + (1 - w.A0) * u * u)
			placeRing(w.Ring, w.X, FLOOR_Y + 0.09, w.Z, w.Spin)
		end
	end
end

------------------------------------------------------------------------------------------
-- Attack poses (purely visual arm / body motion on top of the walk cycle)
------------------------------------------------------------------------------------------

--[[
	A pose is started when this client sees a player attack: a sword swing (FxBatch "s")
	or a projectile appearing next to a player (throw / cast). animateLimbs blends it over
	the walk cycle through the rig's own Motor6Ds.
]]
type Pose = { Kind: string, Start: number, Sweep: number, Back: boolean, Half: number }
local poses: { [number]: Pose } = {}

-- A snappy cut: wind-up + sweep take 0.13 s (was 0.22). With the cubic ease-out the blade
-- passes the middle of the arc ~0.06 s after the swing starts, so the drawn hit lines up
-- with the server's damage (WeaponSystem SWING_HIT_DELAY 0.08 s, minus the Fx batch delay).
K.SWING_WINDUP = 0.04 -- blade pulls back
K.SWING_SWEEP = 0.09 -- blade crosses the arc (ease-out)
K.SWING_FADE = 0.07 -- tip spark fades after the sweep
K.POSE_RECOVER = 0.12 -- arm blends back to the walk cycle
K.THROW_TIME = 0.26
K.CAST_TIME = 0.24

local function startPose(userId: number, kind: string, sweep: number?, back: boolean?, half: number?)
	local now = os.clock()
	local cur = poses[userId]
	if cur and kind ~= "Swing" then
		-- throws never interrupt a swing or a throw that is still playing
		local busy = cur.Kind == "Swing" and (K.SWING_WINDUP + K.SWING_SWEEP + K.POSE_RECOVER) or K.THROW_TIME
		if now - cur.Start < busy then
			return
		end
	end
	poses[userId] = { Kind = kind, Start = now, Sweep = sweep or 1, Back = back == true, Half = half or 1.3 }
end

------------------------------------------------------------------------------------------
-- Trails (pooled Trail + carrier part, reused by projectiles)
------------------------------------------------------------------------------------------

type TrailSlot = { Part: BasePart, Trail: Trail, A0: Attachment, A1: Attachment, Life: number, FreeAt: number }
type TrailStyle = { Color: ColorSequence, Alpha: NumberSequence, Width: number, Life: number, Emission: number }

local trailCount = 0
local freeTrails: { TrailSlot } = {}
local coolingTrails: { TrailSlot } = {}
local trailStyles: { [number]: TrailStyle } = {} -- per visual byte (visual + tier)

local function newTrailSlot(): TrailSlot
	local p = newPart("Block")
	p.Size = Vector3.new(0.1, 0.1, 0.1)
	p.Transparency = 1
	local a0 = Instance.new("Attachment")
	a0.Parent = p
	local a1 = Instance.new("Attachment")
	a1.Parent = p
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = false
	trail.LightInfluence = 0
	trail.MinLength = 0.05
	trail.WidthScale = NumberSequence.new(1, 0.15)
	trail.Enabled = false
	trail.Parent = p
	return { Part = p, Trail = trail, A0 = a0, A1 = a1, Life = 0.1, FreeAt = 0 }
end

local function trailStyle(raw: number, td: any, tier: number): TrailStyle
	local st = trailStyles[raw]
	if not st then
		local head: Color3 = td.Color
		local tail: Color3 = td.Tail or td.Color
		st = {
			Color = ColorSequence.new(head:Lerp(FX.Hit, 0.3), tail),
			Alpha = NumberSequence.new(math.max(0.3, 0.5 - tier * 0.05), 1),
			Width = td.Width * (0.85 + tier * 0.1),
			Life = td.Life * (1 + tier * 0.12),
			Emission = 0.15 + tier * 0.05,
		}
		trailStyles[raw] = st
	end
	return st
end

-- Takes a trail and starts it at `cf` (nil when the budget is used up).
local function acquireTrail(cf: CFrame, st: TrailStyle): TrailSlot?
	local slot = table.remove(freeTrails)
	if not slot then
		if trailCount >= MAX_TRAILS * budgetScale() then
			return nil
		end
		trailCount += 1
		slot = newTrailSlot()
	end
	local s = slot :: TrailSlot
	s.A0.Position = Vector3.new(-st.Width / 2, 0, 0)
	s.A1.Position = Vector3.new(st.Width / 2, 0, 0)
	s.Life = st.Life
	s.Trail.Lifetime = st.Life
	s.Trail.Color = st.Color
	s.Trail.Transparency = st.Alpha
	s.Trail.LightEmission = st.Emission
	s.Part.CFrame = cf
	s.Trail:Clear()
	s.Trail.Enabled = true
	return s
end

-- Stops emitting; the tail fades on its own, then the slot goes back to the pool.
local function releaseTrail(s: TrailSlot)
	s.Trail.Enabled = false
	s.FreeAt = os.clock() + s.Life + 0.05
	table.insert(coolingTrails, s)
end

local function stepTrails(now: number)
	for i = #coolingTrails, 1, -1 do
		local s = coolingTrails[i]
		if now >= s.FreeAt then
			s.Part.CFrame = PARK
			s.Trail:Clear()
			coolingTrails[i] = coolingTrails[#coolingTrails]
			coolingTrails[#coolingTrails] = nil
			table.insert(freeTrails, s)
		end
	end
end

------------------------------------------------------------------------------------------
-- Projectiles
------------------------------------------------------------------------------------------

type Entry = {
	Pieces: { any },
	Visual: number,
	Tier: number,
	Raw: number,
	Def: any,
	Seq: number,
	From: Vector3,
	To: Vector3,
	Drawn: Vector3,
	Yaw: number,
	Heading: number,
	T: number,
	Born: number,
	Seen: number,
	Phase: number,
	Trail: TrailSlot?,
	BaseYaw: number?, -- planted models (totem, turret): the yaw they were built with
	Aim: number?, -- turret: the drawn head yaw, turning toward Yaw
}

-- Each projectile is a small multi-part model from ModelLibrary, pooled per visual.
local projectilePools: { [number]: { { any } } } = {}
local entries: { [number]: Entry } = {}
local batchCounter = 0
local syncInterval = 1 / Config.Net.ProjectileSyncHz
local projParts: { BasePart } = {}
local projCFrames: { CFrame } = {}
local impactBudget = 0 -- impact puffs left this frame (refilled in renderProjectiles)

local function getProjectileModel(visual: number): { any }
	local list = projectilePools[visual]
	if not list then
		list = {}
		projectilePools[visual] = list
	end
	local pieces = table.remove(list)
	-- drop pooled part-built models once the uploaded mesh version is available
	local meshName = ModelLibrary.ProjectileMeshName(visual)
	local meshReady = meshName ~= nil and ModelLibrary.MeshFolder(meshName) ~= nil
	while pieces and meshReady and not pieces[1].Part:IsA("MeshPart") do
		for _, piece in ipairs(pieces) do
			piece.Part:Destroy()
		end
		pieces = table.remove(list)
	end
	if pieces then
		return pieces
	end
	return ModelLibrary.Projectile(visual)
end

local projectileImpact: (Entry) -> ()

local function releaseProjectile(id: number, silent: boolean?)
	local e = entries[id]
	if not e then
		return
	end
	if not silent then
		projectileImpact(e)
	end
	for _, piece in ipairs(e.Pieces) do
		piece.Part.CFrame = PARK
	end
	if e.Trail then
		releaseTrail(e.Trail)
		e.Trail = nil
	end
	table.insert(projectilePools[e.Visual], e.Pieces)
	entries[id] = nil
end

-- A new projectile right next to a player = that player threw / cast it.
local function poseFromSpawn(pos: Vector3, style: string?, noPose: boolean?)
	if style == nil or style == "Stinger" or noPose then
		return
	end
	for _, other in ipairs(Players:GetPlayers()) do
		local char = other.Character
		local root = char and char.PrimaryPart
		if root then
			local d = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
			if d.Magnitude < 3.5 then
				startPose(other.UserId, style == "Orb" and "Cast" or "Throw")
				if other == player then
					Audio.Play("Throw") -- the local hero's attack cue (MinGap keeps it quiet)
				end
				return
			end
		end
	end
end

local function onProjectileBatch(b: buffer)
	if typeof(b) ~= "buffer" then
		return
	end
	batchCounter += 1
	local now = os.clock()
	local count = buffer.readu16(b, 0)
	local o = 2
	for _ = 1, count do
		local id = buffer.readu16(b, o)
		local raw = buffer.readu8(b, o + 2)
		local seq = buffer.readu8(b, o + 3)
		local x = buffer.readi16(b, o + 4) / 10
		local y = buffer.readi16(b, o + 6) / 10
		local z = buffer.readi16(b, o + 8) / 10
		local yaw = buffer.readu8(b, o + 10) / 255 * math.pi * 2
		o += 11
		local pos = Vector3.new(x, y, z)
		local e = entries[id]
		if e and (e.Seq ~= seq or e.Raw ~= raw) then
			releaseProjectile(id)
			e = nil
		end
		if not e then
			-- visual index + cosmetic tier in one byte (WeaponData.VisualByte)
			local visual = WeaponData.VisualIndex(raw)
			local tier = WeaponData.VisualTier(raw)
			local def = WeaponData.Visuals[visual] or WeaponData.Visuals[1]
			if not WeaponData.Visuals[visual] then
				visual = 1
			end
			local trail: TrailSlot? = nil
			local td = def.Trail
			if td then
				trail = acquireTrail(CFrame.new(pos) * CFrame.Angles(0, yaw, 0), trailStyle(raw, td, tier))
			end
			entries[id] = {
				Pieces = getProjectileModel(visual),
				Phase = math.random() * 6,
				Visual = visual,
				Tier = tier,
				Raw = raw,
				Def = def,
				Seq = seq,
				From = pos,
				To = pos,
				Drawn = pos,
				Yaw = yaw,
				Heading = yaw,
				T = 1,
				Born = now,
				Seen = batchCounter,
				Trail = trail,
				BaseYaw = yaw,
				Aim = yaw,
			}
			poseFromSpawn(pos, def.Style, def.NoPose)
		else
			-- continue from where it is drawn now
			local alpha = math.clamp(e.T, 0, 1)
			e.From = e.From:Lerp(e.To, alpha)
			e.To = pos
			e.T = 0
			e.Yaw = yaw
			e.Seen = batchCounter
			local flat = Vector3.new(e.To.X - e.From.X, 0, e.To.Z - e.From.Z)
			if flat.Magnitude > 0.05 then
				e.Heading = math.atan2(-flat.X, -flat.Z)
			end
		end
	end
	for id, e in pairs(entries) do
		if e.Seen ~= batchCounter then
			releaseProjectile(id)
		end
	end
end

--[[
	Orientation of a projectile model in flight, from its style and its age. Everything is
	derived from time + the synced position/yaw, so animation costs no network.
]]
local function projectileRotation(e: Entry, age: number): CFrame
	local def = e.Def
	local style = def.Style
	local spin = def.Spin or 0
	local tumble = def.Tumble or 0
	if style == "Orb" then
		-- wobbling, rolling ball of light
		return CFrame.Angles(0, e.Yaw + age * 4, 0) * CFrame.Angles(math.sin(age * 5 + e.Phase) * 0.5, 0, math.cos(age * 4 + e.Phase) * 0.4)
	elseif style == "Knife" then
		-- end-over-end tumble along the throw
		return CFrame.Angles(0, e.Yaw, 0) * CFrame.Angles(-age * tumble, 0, 0)
	elseif style == "Dart" then
		-- straight and fast, rolling around its own axis
		return CFrame.Angles(0, e.Yaw, 0) * CFrame.Angles(0, 0, age * spin)
	elseif style == "Axe" then
		-- heavy forward tumble along the flight direction
		return CFrame.Angles(0, e.Heading, 0) * CFrame.Angles(-age * tumble - e.Phase, 0, 0)
	elseif style == "Bottle" then
		-- lazy tumble with a little wobble
		return CFrame.Angles(0, e.Heading, 0) * CFrame.Angles(-age * tumble, 0, math.sin(age * 6 + e.Phase) * 0.35)
	elseif style == "Boomerang" then
		-- flat spin, banked into the turn
		return CFrame.Angles(0, e.Heading, 0) * CFrame.Angles(0, 0, 0.35) * CFrame.Angles(0, age * spin + e.Phase, 0)
	elseif style == "Saw" then
		-- tilted buzz saw
		return CFrame.Angles(0, e.Heading, 0) * CFrame.Angles(0.3, 0, 0) * CFrame.Angles(0, age * spin, 0)
	elseif style == "Stinger" then
		return CFrame.Angles(0, e.Yaw + age * spin, 0)
	elseif style == "Spear" or style == "Bolt" or style == "Hook" then
		-- points along its synced yaw (a spear thrusts, a hook's point faces its target)
		return CFrame.Angles(0, e.Yaw, 0)
	elseif style == "Shard" then
		-- spinning ice sliver
		return CFrame.Angles(0, e.Heading, 0) * CFrame.Angles(0, 0, age * tumble)
	elseif style == "Soul" then
		-- skull first, a slow bob and sway
		return CFrame.new(0, math.sin(age * 5 + e.Phase) * 0.3, 0) * CFrame.Angles(0, e.Heading, 0) * CFrame.Angles(0, 0, math.sin(age * 3 + e.Phase) * 0.25)
	elseif style == "Totem" or style == "Turret" then
		-- planted: the base keeps the yaw it was built with (the turret's head aims, see
		-- renderProjectiles); it rises out of the ground in its first 0.25 s
		local rise = math.min(1, age / 0.25)
		return CFrame.new(0, -1.2 * (1 - rise) * (1 - rise), 0) * CFrame.Angles(0, e.BaseYaw or e.Yaw, 0)
	end
	return CFrame.Angles(0, e.Yaw + age * spin, 0)
end

local spinClock = 0
local function renderProjectiles(dt: number, now: number)
	spinClock += dt
	impactBudget = 8
	stepTrails(now)
	table.clear(projParts)
	table.clear(projCFrames)
	local n = 0
	for _, e in pairs(entries) do
		e.T += dt / syncInterval
		local alpha = math.min(e.T, 1.5) -- small extrapolation hides jitter
		local pos = e.From:Lerp(e.To, alpha)
		e.Drawn = pos
		local cf = CFrame.new(pos) * projectileRotation(e, now - e.Born)
		local aim: CFrame? = nil
		if e.Def.Style == "Turret" then
			-- the head (pieces animated "Spin") turns toward the synced aim, the base stays put
			local cur = e.Aim or e.Yaw
			local diff = ((e.Yaw - cur + math.pi) % TAU) - math.pi
			cur += diff * math.min(1, dt * 12)
			e.Aim = cur
			aim = CFrame.Angles(0, cur - (e.BaseYaw or 0), 0)
		end
		for _, piece in ipairs(e.Pieces) do
			n += 1
			projParts[n] = piece.Part
			if aim and piece.Anim == "Spin" then
				local pv = piece.Pivot or CFrame.identity
				projCFrames[n] = cf * piece.Offset * pv * aim * pv:Inverse()
			else
				projCFrames[n] = ModelLibrary.PieceCFrame(cf, piece, spinClock, e.Phase, 1)
			end
		end
		local trail = e.Trail
		if trail then
			n += 1
			projParts[n] = trail.Part
			projCFrames[n] = CFrame.new(pos) * CFrame.Angles(0, e.Heading, 0)
		end
	end
	if n > 0 then
		workspace:BulkMoveTo(projParts, projCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Glass shards + a low splash where a bottle lands.
local function shatter(pos: Vector3, color: Color3)
	if not room(4) then
		return
	end
	local ground = Vector3.new(pos.X, FLOOR_Y + 0.5, pos.Z)
	for i = 1, 3 do
		local a = i * TAU / 3 + math.random() * 0.9
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		local to = ground + out * (1.4 + math.random()) + Vector3.new(0, -0.35, 0)
		fx("Block", color:Lerp(FX.Hit, 0.45), SMOOTH, CFrame.lookAt(ground, ground + out), CFrame.lookAt(to, to + out) * CFrame.Angles(math.random() * 3, 0, 0), Vector3.new(0.22, 0.1, 0.4), nil, 0.15, 1, 0.26, EASE_OUT, 0.6, nil, 1.6)
	end
	fx("Cylinder", color, SMOOTH, CFrame.new(ground.X, FLOOR_Y + 0.1, ground.Z) * DISC, nil, Vector3.new(0.05, 1.2, 1.2), Vector3.new(0.05, 4.2, 4.2), 0.5, 1, 0.22, EASE_OUT)
end

-- Small puff / shatter where a projectile disappears (hit, expiry or landing).
projectileImpact = function(e: Entry)
	if impactBudget <= 0 then
		return
	end
	local def = e.Def
	if def.Shatter then
		impactBudget -= 1
		shatter(e.Drawn, def.Color)
	elseif def.Impact and room(1) then
		impactBudget -= 1
		local size = 0.55 + e.Tier * 0.12
		fx("Ball", def.Impact, SMOOTH, CFrame.new(e.Drawn), nil, Vector3.one * size, Vector3.one * size * 2.2, 0.35, 1, 0.13, EASE_OUT)
	end
end

------------------------------------------------------------------------------------------
-- Enemy hit flashes and sparks
------------------------------------------------------------------------------------------

-- Fallback for bodies the EnemyRenderer does not track (yet): flash the body itself.
local enemyFolder: Folder? = nil
local enemyBodies: { [number]: BasePart } = {}
local flashing: { [BasePart]: number } = {}

local function enemyBody(id: number): BasePart?
	local body = enemyBodies[id]
	if body and body.Parent then
		return body
	end
	if not enemyFolder then
		enemyFolder = workspace:FindFirstChild("SwarmEnemies") :: Folder?
		if not enemyFolder then
			return nil
		end
	end
	local model = (enemyFolder :: Folder):FindFirstChild("E" .. id)
	body = model and model:FindFirstChild("Body") :: BasePart?
	if body then
		enemyBodies[id] = body
	end
	return body
end

local function flash(id: number)
	if EnemyRenderer.Flash(id) then
		return
	end
	local body = enemyBody(id)
	if not body then
		return
	end
	if not flashing[body] then
		body.Color = WHITE
	end
	flashing[body] = os.clock() + Config.Enemies.HitFlashSeconds
end

local function updateFlashes(now: number)
	for body, untilTime in pairs(flashing) do
		if now >= untilTime then
			flashing[body] = nil
			local base = body:GetAttribute("BaseColor")
			if typeof(base) == "Color3" then
				body.Color = base
			end
		end
	end
end

-- Small ivory flash and two gold sparks on a hit enemy (in front of its model).
local function hitSpark(id: number)
	local pos = EnemyRenderer.Position(id)
	if not pos or not room(3) then
		return
	end
	local at = towardCamera(pos + Vector3.new(0, 0.3, 0), 1.3)
	fx("Ball", FX.Hit, NEON, CFrame.new(at), nil, Vector3.one * 0.3, Vector3.one * 0.85, 0.15, 1, 0.09, EASE_OUT)
	for _ = 1, 2 do
		local a = math.random() * TAU
		local dir = Vector3.new(math.cos(a), 0.35 + math.random() * 0.5, math.sin(a)).Unit
		local cf0 = CFrame.lookAt(at, at + dir)
		fx("Block", FX.Spark, NEON, cf0, cf0 + dir * (1 + math.random() * 0.6), Vector3.new(0.08, 0.08, 0.42), Vector3.new(0.05, 0.05, 0.16), 0.05, 1, 0.13, EASE_OUT)
	end
	CombatFx.Impact(pos)
end

------------------------------------------------------------------------------------------
-- Effects from FxBatch
------------------------------------------------------------------------------------------

-- Creature-tinted dust that swells and fades, plus a couple of chitin bits hopping away.
local function deathPuff(x: number, z: number, dust: Color3, bitsColor: Color3, size: number, bits: number)
	local s = math.clamp(size, 1.6, 12)
	local y = FLOOR_Y + math.min(s * 0.32, 2.2)
	fx("Ball", dust, SMOOTH, CFrame.new(x, y, z), nil, Vector3.new(s * 0.55, s * 0.32, s * 0.55), Vector3.new(s * 1.25, s * 0.5, s * 1.25), 0.4, 1, 0.24 + s * 0.012, EASE_OUT3)
	local b = math.clamp(s * 0.16, 0.3, 1.1)
	local from = Vector3.new(x, y, z)
	for i = 1, bits do
		local a = (i / bits) * TAU + math.random() * 1.2
		local dist = s * 0.45 + 0.8 + math.random() * 1.2
		local to = Vector3.new(x + math.cos(a) * dist, FLOOR_Y + b * 0.3, z + math.sin(a) * dist)
		local turn = CFrame.Angles(math.random() * 3, math.random() * 3, math.random() * 3)
		fx("Wedge", bitsColor, SMOOTH, CFrame.new(from) * turn, CFrame.new(to) * turn * CFrame.Angles(2.4, 1.3, 0), Vector3.new(b * 0.7, b * 0.35, b), nil, 0, 1, 0.36, EASE_OUT, 0.8 + s * 0.12, nil, 2)
	end
end

local function characterRoot(userId: number): BasePart?
	local other = Players:GetPlayerByUserId(userId)
	local char = other and other.Character
	return char and char.PrimaryPart
end

--[[
	Sword swings. Each swing is a pooled rig: an invisible carrier pivoting around the
	player with two Trails between attachments along it - a wide, faint ivory band (the
	arc) and a thin pale-gold band on its outer edge - plus a tiny spark at the tip.
	Timeline: wind-up (carrier pulls back, trails off) → sweep across the arc (ease-out,
	trails on) → the tip spark fades while the short trail tails die away. The arc width
	comes from WeaponData (the server hits the same sector). Evolved (Bloodwhip) = crimson.
]]
type SwingRig = { Carrier: BasePart, Core: Trail, Edge: Trail, Inner: Attachment, Outer: Attachment, EdgeIn: Attachment, EdgeOut: Attachment, Tip: BasePart }
type Swing = { Rig: SwingRig, Root: BasePart?, X: number, Z: number, Yaw: number, Reach: number, Sweep: number, Start: number, Trailing: boolean, Life: number }
type SlashStyle = { Core: ColorSequence, CoreAlpha: NumberSequence, Edge: ColorSequence, EdgeAlpha: NumberSequence, EdgeWidth: number, Tip: Color3 }

K.SWING_ARC = math.rad(WeaponData.Weapons.Whip.Params.Arc)
K.SWING_PULL = math.rad(22) -- extra wind-up beyond the arc start
K.SWING_HEIGHT = 2.2

local function slashStyle(core: Color3, edge: Color3, coreAlpha: number, edgeAlpha: number, edgeWidth: number, tip: Color3): SlashStyle
	return {
		Core = ColorSequence.new(core),
		CoreAlpha = NumberSequence.new({
			NumberSequenceKeypoint.new(0, coreAlpha),
			NumberSequenceKeypoint.new(0.5, (coreAlpha + 1) / 2 + 0.08),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Edge = ColorSequence.new(edge, edge:Lerp(core, 0.5)),
		EdgeAlpha = NumberSequence.new(edgeAlpha, 1),
		EdgeWidth = edgeWidth,
		Tip = tip,
	}
end

local SLASH: { [number]: SlashStyle } = {
	[0] = slashStyle(FX.Slash, FX.SlashEdge, 0.68, 0.32, 0.3, P.gold_200),
	[1] = slashStyle(FX.Slash, FX.SlashEdge, 0.64, 0.28, 0.36, P.gold_200),
	[2] = slashStyle(FX.Slash, P.gold_300, 0.6, 0.22, 0.42, P.gold_200),
	[3] = slashStyle(FX.Slash:Lerp(P.crimson_300, 0.3), P.crimson_400, 0.6, 0.2, 0.48, P.crimson_300),
}

local swingRigs: { SwingRig } = {}
local swings: { Swing } = {}

local function newSlashTrail(parent: BasePart, a0: Attachment, a1: Attachment, emission: number): Trail
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = false
	trail.LightInfluence = 0
	trail.LightEmission = emission
	trail.MinLength = 0.02
	trail.WidthScale = NumberSequence.new(1, 0.6)
	trail.Enabled = false
	trail.Parent = parent
	return trail
end

local function getSwingRig(): SwingRig
	local rig = table.remove(swingRigs)
	if rig then
		return rig
	end
	local carrier = newPart("Block")
	carrier.Size = Vector3.new(0.1, 0.1, 0.1)
	carrier.Transparency = 1
	local function attach(): Attachment
		local a = Instance.new("Attachment")
		a.Parent = carrier
		return a
	end
	local inner, outer, edgeIn, edgeOut = attach(), attach(), attach(), attach()
	local tip = newPart("Ball")
	tip.Material = NEON
	return {
		Carrier = carrier,
		Core = newSlashTrail(carrier, inner, outer, 0.15),
		Edge = newSlashTrail(carrier, edgeIn, edgeOut, 0.4),
		Inner = inner,
		Outer = outer,
		EdgeIn = edgeIn,
		EdgeOut = edgeOut,
		Tip = tip,
	}
end

local function slash(x: number, z: number, yaw: number, reach: number, sweep: number, tier: number, userId: number)
	if type(userId) ~= "number" or type(reach) ~= "number" or type(yaw) ~= "number" then
		return
	end
	tier = math.clamp(math.floor(tonumber(tier) or 0), 0, 3)
	sweep = (tonumber(sweep) or 1) < 0 and -1 or 1
	local st = SLASH[tier]
	local rig = getSwingRig()
	local inner = math.max(1.6, reach * 0.42)
	rig.Inner.Position = Vector3.new(0, 0, -inner)
	rig.Outer.Position = Vector3.new(0, 0, -reach)
	rig.EdgeIn.Position = Vector3.new(0, 0, -(reach - st.EdgeWidth))
	rig.EdgeOut.Position = Vector3.new(0, 0, -(reach + 0.06))
	local life = 0.09 + tier * 0.01
	rig.Core.Lifetime = life
	rig.Core.Color = st.Core
	rig.Core.Transparency = st.CoreAlpha
	rig.Edge.Lifetime = life * 0.9
	rig.Edge.Color = st.Edge
	rig.Edge.Transparency = st.EdgeAlpha
	rig.Tip.Color = st.Tip
	rig.Tip.Size = Vector3.one * (0.4 + tier * 0.05)
	rig.Tip.Transparency = 1
	local root = characterRoot(userId)
	table.insert(swings, {
		Rig = rig,
		Root = root,
		X = x,
		Z = z,
		Yaw = yaw,
		Reach = reach,
		Sweep = sweep,
		Start = os.clock(),
		Trailing = false,
		Life = life,
		Tier = tier,
	})
	-- attack pose: a back swing (behind the player's facing) becomes a spin slash
	local back = false
	if root then
		local look = root.CFrame.LookVector
		local dir = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
		back = look.X * dir.X + look.Z * dir.Z < 0
	end
	startPose(userId, "Swing", sweep, back, K.SWING_ARC / 2)
	if userId == player.UserId then
		Audio.Play("Swing")
	end
end

-- Relative blade angle (radians from the swing direction) at time t since the swing began.
local function swingAngle(sweep: number, t: number): number
	local half = K.SWING_ARC / 2
	local from = sweep * (half + K.SWING_PULL)
	if t < K.SWING_WINDUP then
		return sweep * half + sweep * K.SWING_PULL * easeOut(t / K.SWING_WINDUP)
	end
	return from + (-sweep * half - from) * easeOut((t - K.SWING_WINDUP) / K.SWING_SWEEP)
end

local function renderSwings(now: number)
	local swingEnd = K.SWING_WINDUP + K.SWING_SWEEP
	for i = #swings, 1, -1 do
		local sw = swings[i]
		local rig = sw.Rig
		local t = now - sw.Start
		local root = sw.Root
		if root and root.Parent then
			sw.X, sw.Z = root.Position.X, root.Position.Z
		end
		if t >= swingEnd + K.SWING_FADE + sw.Life then
			-- done: park and recycle
			rig.Core.Enabled = false
			rig.Edge.Enabled = false
			rig.Carrier.CFrame = PARK
			rig.Tip.CFrame = PARK
			rig.Core:Clear()
			rig.Edge:Clear()
			swings[i] = swings[#swings]
			swings[#swings] = nil
			table.insert(swingRigs, rig)
		else
			local a = swingAngle(sw.Sweep, math.min(t, swingEnd))
			local pivot = CFrame.new(sw.X, FLOOR_Y + K.SWING_HEIGHT, sw.Z) * CFrame.Angles(0, sw.Yaw + a, 0)
			bulk(rig.Carrier, pivot)
			if t >= K.SWING_WINDUP and not sw.Trailing and t < swingEnd then
				-- the sweep starts: trails on from where the blade is now
				sw.Trailing = true
				rig.Core:Clear()
				rig.Edge:Clear()
				rig.Core.Enabled = true
				rig.Edge.Enabled = true
			end
			if t >= K.SWING_WINDUP then
				if t >= swingEnd and rig.Core.Enabled then
					rig.Core.Enabled = false
					rig.Edge.Enabled = false
					CombatFx.SwingTip((pivot * CFrame.new(0, 0, -sw.Reach)).Position, sw.Tier)
				end
				local f = math.clamp((t - swingEnd) / K.SWING_FADE, 0, 1)
				rig.Tip.Transparency = 0.2 + 0.8 * f
				bulk(rig.Tip, pivot * CFrame.new(0, 0, -sw.Reach))
			end
		end
	end
end

-- Thin jagged bolt from a to b: `segments` tiny neon blocks with random kinks.
local function zigzag(a: Vector3, b: Vector3, segments: number, jitter: number, width: number, color: Color3, seconds: number)
	local prev = a
	for i = 1, segments do
		local nextPos = a:Lerp(b, i / segments)
		if i < segments then
			nextPos += Vector3.new((math.random() - 0.5) * jitter, (math.random() - 0.5) * jitter * 0.4, (math.random() - 0.5) * jitter)
		end
		local d = nextPos - prev
		local len = d.Magnitude
		if len > 0.05 then
			local up = math.abs(d.Y / len) > 0.7 and Vector3.zAxis or Vector3.yAxis
			local cf = CFrame.lookAt((prev + nextPos) / 2, nextPos, up)
			fx("Block", color, NEON, cf, nil, Vector3.new(width, width, len + width), Vector3.new(width * 0.3, width * 0.3, len), 0.05, 1, seconds, EASE_OUT)
		end
		prev = nextPos
	end
end

-- Lightning: a thin pale bolt from the sky and a small flash on the ground.
local function bolt(x: number, z: number, radius: number, tier: number?)
	local t = tonumber(tier) or 0
	if type(x) ~= "number" or type(z) ~= "number" or not room(7, true) then
		return
	end
	local r = tonumber(radius) or 3
	local color = t >= 3 and FX.Bolt:Lerp(FX.Arcane, 0.35) or FX.Bolt
	local ground = Vector3.new(x, FLOOR_Y + 0.2, z)
	zigzag(ground + Vector3.new((math.random() - 0.5) * 6, 24, (math.random() - 0.5) * 6), ground, 5, 2.2, 0.2 + t * 0.03, color, 0.14)
	fx("Cylinder", color, SMOOTH, CFrame.new(x, FLOOR_Y + 0.08, z) * DISC, nil, Vector3.new(0.05, r * 0.9, r * 0.9), Vector3.new(0.05, r * 2, r * 2), 0.45, 1, 0.2, EASE_OUT)
	fx("Ball", color, NEON, CFrame.new(x, FLOOR_Y + 0.6, z), nil, Vector3.one * 0.6, Vector3.one * 1.4, 0.1, 1, 0.1, EASE_OUT)
end

local function chain(x1: number, z1: number, x2: number, z2: number)
	if type(x1) ~= "number" or type(x2) ~= "number" then
		return
	end
	local a = Vector3.new(x1, FLOOR_Y + 2, z1)
	local b = Vector3.new(x2, FLOOR_Y + 2, z2)
	if (b - a).Magnitude < 0.1 or not room(3, true) then
		return
	end
	zigzag(a, b, 3, 1.4, 0.16, FX.Bolt:Lerp(FX.Arcane, 0.35), 0.15)
end

--[[
	Holy water / hellfire pools: a soft low-alpha disc that grows in, two ripples running
	outward while it burns (plus two rising embers for hellfire), then a quick fade.
]]
type PoolFx = { Fill: BasePart, Ripples: { BasePart }, Embers: { BasePart }, X: number, Z: number, R: number, Start: number, Life: number, FillAlpha: number }
local poolList: { PoolFx } = {}
K.MAX_POOLS = 24
K.RIPPLE_PERIOD = 1.1

local function pool(x: number, z: number, radius: number, seconds: number, evo: boolean)
	if type(x) ~= "number" or type(radius) ~= "number" or #poolList >= K.MAX_POOLS then
		return
	end
	local count = evo and 5 or 3
	if not room(count, true) then
		return
	end
	local color = evo and FX.Fire or FX.Holy
	local rippleColor = evo and P.amber_300 or P.ivory_100
	local y = FLOOR_Y + 0.06
	local fill = takePart("Cylinder", color, SMOOTH, Vector3.new(0.05, radius * 1.4, radius * 1.4), 1)
	fill.CFrame = CFrame.new(x, y, z) * DISC
	local ripples = {}
	for k = 1, 2 do
		local rp = takePart("Cylinder", rippleColor, SMOOTH, Vector3.new(0.05, 1, 1), 1)
		rp.CFrame = CFrame.new(x, y + 0.01 * k, z) * DISC
		ripples[k] = rp
	end
	local embers = {}
	if evo then
		for k = 1, 2 do
			embers[k] = takePart("Ball", P.amber_500, NEON, Vector3.one * 0.26, 1)
		end
	end
	fxParts += count
	table.insert(poolList, {
		Fill = fill,
		Ripples = ripples,
		Embers = embers,
		X = x,
		Z = z,
		R = radius,
		Start = os.clock(),
		Life = math.max(0.4, tonumber(seconds) or 2),
		FillAlpha = evo and 0.66 or 0.7,
	})
end

local function stepPools(now: number)
	for i = #poolList, 1, -1 do
		local pl = poolList[i]
		local t = now - pl.Start
		if t >= pl.Life then
			givePart("Cylinder", pl.Fill)
			for _, rp in ipairs(pl.Ripples) do
				givePart("Cylinder", rp)
			end
			for _, em in ipairs(pl.Embers) do
				givePart("Ball", em)
			end
			fxParts -= 1 + #pl.Ripples + #pl.Embers
			poolList[i] = poolList[#poolList]
			poolList[#poolList] = nil
		else
			local appear = math.min(1, t / 0.18)
			local vis = math.min(appear, math.clamp((pl.Life - t) / 0.35, 0, 1))
			if appear < 1 or t < 0.25 then
				local r = pl.R * (0.7 + 0.3 * easeOut(appear))
				pl.Fill.Size = Vector3.new(0.05, r * 2, r * 2)
			end
			pl.Fill.Transparency = 1 - (1 - pl.FillAlpha) * vis
			for k, rp in ipairs(pl.Ripples) do
				local ph = (t / K.RIPPLE_PERIOD + (k - 1) / #pl.Ripples) % 1
				local rr = pl.R * (0.2 + 0.8 * ph)
				rp.Size = Vector3.new(0.05, rr * 2, rr * 2)
				rp.Transparency = 1 - 0.4 * (1 - ph) * vis
			end
			for k, em in ipairs(pl.Embers) do
				local ph = (t * 0.8 + k * 0.5) % 1
				local a = k * math.pi + t * 0.7
				em.Transparency = 1 - 0.7 * (1 - ph) * vis
				bulk(em, CFrame.new(pl.X + math.cos(a) * pl.R * 0.5, FLOOR_Y + 0.3 + ph * 2.2, pl.Z + math.sin(a) * pl.R * 0.5))
			end
		end
	end
end

-- Warm amber burst: a small hot core, a dusty puff and a shock ring (never blinding).
local function explosion(x: number, z: number, radius: number)
	if type(x) ~= "number" or type(radius) ~= "number" then
		return
	end
	local r = radius
	if room(2, true) then
		local core = math.min(r * 0.45, 4)
		fx("Ball", P.amber_300, NEON, CFrame.new(x, FLOOR_Y + 1.2, z), nil, Vector3.one * core, Vector3.one * core * 1.8, 0.2, 1, 0.14, EASE_OUT)
		local dust = math.min(r * 1.1, 26)
		fx("Ball", FX.Fire:Lerp(P.dirt_300, 0.45), SMOOTH, CFrame.new(x, FLOOR_Y + 0.6, z), nil, Vector3.new(dust * 0.5, dust * 0.22, dust * 0.5), Vector3.new(dust, dust * 0.35, dust), 0.5, 1, 0.38, EASE_OUT3)
	end
	wave(x, z, r * 0.15, r, 0.35 + math.min(r, 60) * 0.008, P.amber_300, 0.25, 0.28 + math.min(r, 80) / 220, true)
	if r <= 14 and room(3) then
		local from = Vector3.new(x, FLOOR_Y + 1, z)
		for i = 1, 3 do
			local a = i * TAU / 3 + math.random()
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			local to = from + dir * (r * 0.6 + math.random() * 2) - Vector3.new(0, 0.8, 0)
			fx("Block", P.amber_500, NEON, CFrame.lookAt(from, from + dir), CFrame.lookAt(to, to + dir), Vector3.new(0.14, 0.14, 0.5), Vector3.new(0.08, 0.08, 0.3), 0.1, 1, 0.3, EASE_OUT, 1.2)
		end
	end
	local root = player.Character and player.Character.PrimaryPart
	if root and (root.Position - Vector3.new(x, root.Position.Y, z)).Magnitude < r + 25 then
		CameraController.Shake(0.45)
	end
end

-- Shockwave ring from the server (bomb, revive, boss): colour brought into the palette.
local function ring(x: number, z: number, radius: number, color: Color3)
	if type(x) ~= "number" or type(radius) ~= "number" then
		return
	end
	local c = typeof(color) == "Color3" and paletteColor(color) or FX.Gold
	wave(x, z, radius * 0.2, radius, 0.3 + math.min(radius, 60) * 0.006, c, 0.2, 0.35 + math.min(radius, 80) / 200, true)
	if radius <= 32 and room(1, true) then
		fx("Cylinder", c, SMOOTH, CFrame.new(x, FLOOR_Y + 0.06, z) * DISC, nil, Vector3.new(0.05, radius * 0.6, radius * 0.6), Vector3.new(0.05, radius * 2, radius * 2), 0.82, 1, 0.4, EASE_OUT)
	end
end

-- Tiny glowing motes drifting up around a point (heal, level-up, revive).
local function sparkle(pos: Vector3, color: Color3, count: number, radius: number, rise: number, dur: number)
	if not room(count, true) then
		return
	end
	for i = 1, count do
		local a = (i / count) * TAU + math.random() * 0.6
		local r = radius * (0.5 + math.random() * 0.5)
		local from = pos + Vector3.new(math.cos(a) * r, math.random() * 0.8, math.sin(a) * r)
		local to = from + Vector3.new(0, rise * (0.7 + math.random() * 0.5), 0)
		fx("Ball", color, NEON, CFrame.new(from), CFrame.new(to), Vector3.one * 0.3, Vector3.one * 0.12, 0.15, 1, dur * (0.8 + math.random() * 0.4), EASE_OUT, nil, 0.15)
	end
end

local function playerEvent(userId: number, kind: string)
	local root = characterRoot(userId)
	local isLocal = userId == player.UserId
	local pos = root and root.Position
	if kind == "hurt" then
		if isLocal then
			CameraController.Shake(0.22)
			Audio.Play("Hurt")
		end
		if pos and room(1) then
			-- a small crimson nick on the hero
			local at = towardCamera(pos + Vector3.new(0, 0.8, 0), 1.2)
			fx("Ball", P.crimson_300, NEON, CFrame.new(at), nil, Vector3.one * 0.4, Vector3.one * 1.1, 0.2, 1, 0.12, EASE_OUT)
		end
	elseif kind == "heal" and pos then
		wave(pos.X, pos.Z, 1, 4.5, 0.2, FX.Heal, 0.35, 0.45, true)
		sparkle(Vector3.new(pos.X, FLOOR_Y + 0.8, pos.Z), FX.Heal, 5, 1.6, 3.2, 0.6)
	elseif kind == "levelup" and pos then
		wave(pos.X, pos.Z, 1.5, 9, 0.32, FX.Gold, 0.2, 0.55, true)
		sparkle(Vector3.new(pos.X, FLOOR_Y + 0.6, pos.Z), FX.Gold, 6, 2.2, 4.2, 0.7)
		if room(1, true) then
			-- a soft, short column of light
			local cf = CFrame.new(pos.X, FLOOR_Y + 3.5, pos.Z) * DISC
			fx("Cylinder", P.gold_200, SMOOTH, cf, nil, Vector3.new(7, 3.6, 3.6), Vector3.new(7.5, 5.4, 5.4), 0.8, 1, 0.45, EASE_OUT)
		end
		CombatFx.LevelUp(pos, isLocal)
		if isLocal then
			Audio.Play("LevelUp")
		end
	elseif kind == "die" then
		if pos and room(4, true) then
			deathPuff(pos.X, pos.Z, P.stone_200, P.steel_400, 5, 3)
		end
		if isLocal then
			Audio.Play("Death")
		end
	elseif kind == "revive" and pos then
		Audio.Play("Revive")
		wave(pos.X, pos.Z, 2, 12, 0.36, FX.Gold:Lerp(FX.Hit, 0.4), 0.15, 0.6, true)
		sparkle(Vector3.new(pos.X, FLOOR_Y + 0.6, pos.Z), FX.Gold, 8, 2.4, 5, 0.8)
	end
	if isLocal and onLocalEvent then
		onLocalEvent(kind)
	end
end

--[[
	Sound cue for a new warning entry { id, kind, ... } (Fx.Warn): the bomb tick's fuse
	ticks, the spitter's wind-up gurgle, a lunge's scrape, the Queen's attacks. Played at
	the warning's floor spot, so far-away ones are quieter.
]]
local function warningSound(w: { any })
	local kind = w[2]
	local x, z = tonumber(w[3]), tonumber(w[4])
	if not x or not z then
		return
	end
	local at = Vector3.new(x, FLOOR_Y + 1, z)
	if kind == "circle" then
		local style = w[7]
		local seconds = tonumber(w[6]) or 0.7
		if style == "blast" then
			-- fuse: three ticks, faster and higher toward the blast
			for i = 0, 2 do
				task.delay(seconds * (i / 3), function()
					Audio.PlayAt("FuseTick", at, 1.5 + i * 0.15)
				end)
			end
		elseif style == "acid" then
			Audio.PlayAt("SpitterWindup", at)
		else
			Audio.PlayAt("BossWarn", at)
		end
	elseif kind == "lane" then
		Audio.PlayAt("Lunge", at)
	elseif kind == "spokes" then
		Audio.PlayAt("BossWarn", at)
	elseif kind == "egg" then
		Audio.PlayAt("BossSummon", at)
	end
end

K.SPARKS_PER_BATCH = 6
K.PICKUP_SPARKLE_RANGE = 10 -- studs: a pickup removed this close to the hero was taken by them
K.FULL_DEATHS_PER_BATCH = 6 -- dust + bits; more deaths in one batch get dust only
K.DEATHS_PER_BATCH = 14

------------------------------------------------------------------------------------------
-- Gold coins (a kill that paid gold: FxBatch "g" = { x, z, amount, userId })
------------------------------------------------------------------------------------------

--[[
	Purely visual: the gold is already in the counter when the server sends this. Coins
	(GoldCoin mesh, or a gold disc) burst up out of the enemy, land with one small bounce
	and then fly into the player they belong to, ending in a tiny gold sparkle. Big amounts
	add a GoldPile. Pooled, at most K.MAX_COINS in flight; Reduced effects: one coin.
]]
type Coin = { Pieces: { any }, Pile: boolean, Start: number, From: Vector3, Land: Vector3, UserId: number, Phase: number, Fallback: BasePart? }
local coinPool: { [string]: { Coin } } = { Coin = {}, Pile = {} }
local coins: { Coin } = {}
K.MAX_COINS = 36
local COIN_POP, COIN_BOUNCE, COIN_FLY = 0.38, 0.16, 0.34 -- seconds per leg
local COIN_SCALE, PILE_SCALE = 2.1, 2.1 -- ~2 studs across: readable from the run camera

local function newCoin(pile: boolean): Coin
	local name = pile and "GoldPile" or "GoldCoin"
	local pieces = ModelLibrary.MeshPieces(name, nil, pile and PILE_SCALE or COIN_SCALE, 0)
	local fallback: BasePart? = nil
	if not pieces then
		-- part fallback: a thick gold disc (cylinder axis X: it spins like a coin)
		local disc = newPart("Cylinder")
		disc.Color = FX.Coin
		disc.Size = pile and Vector3.new(0.9, 2.6, 2.6) or Vector3.new(0.45, 2.1, 2.1)
		disc.Reflectance = 0.1
		fallback = disc
		pieces = { { Part = disc, Offset = CFrame.new(0, disc.Size.Y / 2, 0) } }
	else
		for _, piece in ipairs(pieces) do
			piece.Part.CastShadow = false
		end
	end
	return { Pieces = pieces :: { any }, Pile = pile, Start = 0, From = Vector3.zero, Land = Vector3.zero, UserId = 0, Phase = 0, Fallback = fallback }
end

local function takeCoin(pile: boolean): Coin
	local list = coinPool[pile and "Pile" or "Coin"]
	local c = table.remove(list)
	if c and c.Fallback and ModelLibrary.MeshFolder(pile and "GoldPile" or "GoldCoin") then
		-- the mesh arrived since this fallback was made: build a mesh coin instead
		c.Fallback:Destroy()
		c = nil
	end
	return c or newCoin(pile)
end

local function freeCoin(c: Coin)
	for _, piece in ipairs(c.Pieces) do
		piece.Part.CFrame = PARK
	end
	table.insert(coinPool[c.Pile and "Pile" or "Coin"], c)
end

local function goldBurst(x: number, z: number, amount: number, userId: number)
	amount = math.max(1, math.floor(amount))
	local count = math.clamp(amount, 1, 3)
	local pile = amount >= 8
	if ClientSettings.Reduced() then
		count, pile = 1, false
	end
	local from = Vector3.new(x, FLOOR_Y + 1.6, z)
	local now = os.clock()
	for i = 1, count + (pile and 1 or 0) do
		if #coins >= K.MAX_COINS then
			break
		end
		local isPile = pile and i == 1
		local c = takeCoin(isPile)
		local a = math.random() * TAU
		local r = isPile and 0.6 or (1.6 + math.random() * 1.6)
		c.Start = now + (i - 1) * 0.05
		c.From = from
		c.Land = Vector3.new(x + math.cos(a) * r, FLOOR_Y, z + math.sin(a) * r)
		c.UserId = userId
		c.Phase = math.random() * TAU
		table.insert(coins, c)
	end
	if userId == player.UserId then
		Audio.Play("Coin")
	end
end

local function renderCoins(now: number)
	for i = #coins, 1, -1 do
		local c = coins[i]
		local t = now - c.Start
		local pos: Vector3
		local done = false
		if t < 0 then
			pos = c.From
		elseif t < COIN_POP then
			-- the burst: an arc up out of the body and down beside it
			local u = t / COIN_POP
			local flat = c.From:Lerp(c.Land, u)
			pos = Vector3.new(flat.X, c.From.Y + (c.Land.Y - c.From.Y) * u + 4 * 3.2 * u * (1 - u), flat.Z)
		elseif t < COIN_POP + COIN_BOUNCE then
			local u = (t - COIN_POP) / COIN_BOUNCE
			pos = c.Land + Vector3.new(0, 4 * 0.55 * u * (1 - u), 0)
		else
			local u = (t - COIN_POP - COIN_BOUNCE) / COIN_FLY
			local root = characterRoot(c.UserId)
			if root and root.Parent then
				-- ease in: it lifts off slowly, then snaps into the player
				local k = u * u
				local to = root.Position + Vector3.new(0, 0.5, 0)
				pos = c.Land:Lerp(to, k) + Vector3.new(0, math.sin(u * math.pi) * 1.5, 0)
			else
				pos = c.Land
			end
			done = u >= 1
		end
		if done then
			if room(2) then
				sparkle(pos, FX.Gold, 2, 0.4, 1.2, 0.3)
			end
			freeCoin(c)
			coins[i] = coins[#coins]
			coins[#coins] = nil
		else
			-- spinning on the vertical axis (fast in the air, slow once landed)
			local spinRate = (t < COIN_POP) and 14 or 7
			local cf = CFrame.new(pos) * CFrame.Angles(0, c.Phase + t * spinRate, 0)
			if c.Pile then
				cf = CFrame.new(pos) * CFrame.Angles(0, c.Phase, 0)
			end
			for _, piece in ipairs(c.Pieces) do
				bulk(piece.Part, cf * piece.Offset)
			end
		end
	end
end

local function onFxBatch(batch)
	if type(batch) ~= "table" then
		return
	end
	if type(batch.g) == "table" then
		-- kills that paid gold: coins burst out and fly to their player
		for _, v in ipairs(batch.g) do
			if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" then
				goldBurst(v[1], v[2], tonumber(v[3]) or 1, tonumber(v[4]) or 0)
			end
		end
	end
	if type(batch.h) == "table" then
		local hits = batch.h
		local sparkEvery = math.max(1, math.ceil(#hits / K.SPARKS_PER_BATCH))
		for i, id in ipairs(hits) do
			if type(id) == "number" then
				flash(id)
				if (i - 1) % sparkEvery == 0 then
					hitSpark(id)
				end
			end
		end
		Audio.Play("Hit")
	end
	if type(batch.d) == "table" then
		for i, d in ipairs(batch.d) do
			if type(d) == "table" and type(d[1]) == "number" and type(d[2]) == "number" then
				local tint = typeof(d[3]) == "Color3" and d[3] or P.stone_300
				if i <= K.DEATHS_PER_BATCH then
					local bits = (i <= K.FULL_DEATHS_PER_BATCH) and ((tonumber(d[4]) or 2) > 5 and 4 or 2) or 0
					if room(1 + bits) then
						local dust, chitin = creatureLook(tint)
						deathPuff(d[1], d[2], dust, chitin, tonumber(d[4]) or 2.5, bits)
					end
				end
				-- shards + pop; elite / boss kills always get their burst (CombatFx budget)
				CombatFx.Kill(d[1], d[2], tint, tonumber(d[4]) or 2.5, i)
			end
		end
	end
	if type(batch.s) == "table" then
		for _, s in ipairs(batch.s) do
			slash(s[1], s[2], s[3], s[4], s[5], s[6], s[7])
		end
	end
	if type(batch.b) == "table" then
		for _, b in ipairs(batch.b) do
			bolt(b[1], b[2], b[3], b[4])
		end
	end
	if type(batch.c) == "table" then
		for _, c in ipairs(batch.c) do
			chain(c[1], c[2], c[3], c[4])
		end
	end
	if type(batch.p) == "table" then
		for _, p in ipairs(batch.p) do
			pool(p[1], p[2], p[3], p[4], p[5] == true)
		end
	end
	if type(batch.e) == "table" then
		for _, e in ipairs(batch.e) do
			explosion(e[1], e[2], e[3])
		end
	end
	if type(batch.r) == "table" then
		for _, r in ipairs(batch.r) do
			ring(r[1], r[2], r[3], r[4])
		end
	end
	if type(batch.k) == "table" then
		-- critical hits: a gold star on the enemy (a few per batch)
		for i, id in ipairs(batch.k) do
			local pos = i <= K.SPARKS_PER_BATCH and type(id) == "number" and EnemyRenderer.Position(id)
			if pos then
				CombatFx.Crit(pos)
			end
		end
	end
	if type(batch.u) == "table" then
		for _, u in ipairs(batch.u) do
			playerEvent(u[1], u[2])
		end
	end
	if type(batch.w) == "table" then
		-- telegraph cues at the warning's spot (the shapes are drawn by Telegraphs.lua)
		for _, w in ipairs(batch.w) do
			if type(w) == "table" then
				warningSound(w)
			end
		end
	end
	if type(batch.n) == "table" then
		for _, name in ipairs(batch.n) do
			Audio.Play(name)
			if name == "BossRoar" then
				CameraController.Shake(0.55)
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Weapon effects (WeaponFx remote, see WeaponSystem): frost nova bursts, Fire Trail
-- patches, Healing Totem pulses, Chain Hook chains, flak / lance bursts, harvested souls
------------------------------------------------------------------------------------------

K.ICE = P.ice_100
K.ICE_DEEP = P.ice_300

-- Frost Nova: a pale ice ring racing out to the burst's edge, a frosty floor flash and ice
-- spikes thrown outward (Absolute Zero: a second, brighter ring and more spikes).
local function nova(x: number, z: number, radius: number, evo: boolean)
	wave(x, z, radius * 0.15, radius, 0.45 + (evo and 0.15 or 0), K.ICE, 0.12, 0.34, true)
	if evo then
		wave(x, z, radius * 0.1, radius * 0.75, 0.3, FX.Holy, 0.25, 0.42, true)
	end
	if room(1, true) then
		fx("Cylinder", K.ICE_DEEP, SMOOTH, CFrame.new(x, FLOOR_Y + 0.07, z) * DISC, nil, Vector3.new(0.05, radius * 0.5, radius * 0.5), Vector3.new(0.05, radius * 2, radius * 2), 0.55, 1, 0.32, EASE_OUT)
	end
	local spikes = evo and 10 or 7
	if room(spikes) then
		local from = Vector3.new(x, FLOOR_Y + 0.6, z)
		for i = 1, spikes do
			local a = i * TAU / spikes + math.random() * 0.4
			local dir = Vector3.new(math.cos(a), 0, math.sin(a))
			local to = from + dir * radius * (0.65 + math.random() * 0.25) + Vector3.new(0, 0.4, 0)
			fx("Wedge", i % 2 == 0 and K.ICE or K.ICE_DEEP, SMOOTH, CFrame.lookAt(from, from + dir), CFrame.lookAt(to, to + dir), Vector3.new(0.3, 0.5, 1.1), Vector3.new(0.12, 0.2, 0.5), 0.15, 1, 0.3, EASE_OUT)
		end
	end
end

--[[
	Fire Trail patches: the burning ground the server damages (WeaponFx "fp": x, z, radius,
	life, evolved). Each patch is a barely visible scorch bed exactly as wide as its
	damage circle plus a small crown of flame licks standing in it. A lick is a tall pointed
	flame card (two mirrored wedges) turned to face the camera, with a smaller, brighter core
	card in front: a clean flame silhouette from the overhead view. Licks sway, lean and
	flicker, grow in one after the other, shift from gold-orange through orange to dull red
	as the patch ages and shrink away in its last half second, so walking leaves a
	continuous ribbon of flames instead of a chain of blobs. Spacing and lifetime are the
	server's; the client only caps how much it draws (K.FIRE_MAX_PARTS, 40% with Reduced
	effects): the oldest patch goes first, licks per patch drop as the trail gets long (one
	lick, no embers with Reduced effects), and patches far from the hero are skipped.
	Never the crimson and dark outline of enemy warnings: these never hurt heroes.
]]
type FireLick = { Cards: { BasePart }, Ox: number, Oz: number, W: number, H: number, Tilt: number, Delay: number, Speed: number, Phase: number, Vis: number }
type FirePatch = { Bed: BasePart, Licks: { FireLick }, Parts: number, X: number, Z: number, R: number, Start: number, Life: number, Evo: boolean, Stage: number }
local firePatches: { FirePatch } = {}
K.FIRE_MAX_PATCHES = 40
K.FIRE_MAX_PARTS = 300 -- flame parts in use (own budget, apart from the one-shot effects)
K.FIRE_NEAR = 110 -- patches farther than this from the hero are not drawn
K.fireParts = 0
K.fireEmber = 0
K.fireFace = CFrame.identity -- turns a flame card to face the camera (set each frame)
-- outer flame / core colours at the start, middle and end of a patch's life
K.FIRE_OUTER = { Color3.fromRGB(255, 122, 28), Color3.fromRGB(226, 76, 26), Color3.fromRGB(140, 40, 26) }
K.FIRE_CORE = { Color3.fromRGB(255, 232, 110), Color3.fromRGB(255, 184, 62), Color3.fromRGB(196, 84, 38) }
K.FIRE_OUTER_EVO = { Color3.fromRGB(255, 178, 44), Color3.fromRGB(255, 124, 34), Color3.fromRGB(200, 70, 32) }
K.FIRE_CORE_EVO = { Color3.fromRGB(255, 236, 140), Color3.fromRGB(255, 190, 80), Color3.fromRGB(238, 128, 52) }
K.FIRE_STAGES = 6

local function fireRamp(stops: { Color3 }, u: number): Color3
	if u < 0.5 then
		return stops[1]:Lerp(stops[2], u * 2)
	end
	return stops[2]:Lerp(stops[3], (u - 0.5) * 2)
end

local function freeFirePatch(fp: FirePatch)
	givePart("Cylinder", fp.Bed)
	for _, lick in ipairs(fp.Licks) do
		for _, card in ipairs(lick.Cards) do
			givePart("Wedge", card)
		end
	end
	K.fireParts -= fp.Parts
end

-- Colours for the patch's age stage (a few steps, not one change per frame).
local function colourFire(fp: FirePatch, stage: number)
	fp.Stage = stage
	local u = stage / K.FIRE_STAGES
	local outer = fireRamp(fp.Evo and K.FIRE_OUTER_EVO or K.FIRE_OUTER, u)
	local core = fireRamp(fp.Evo and K.FIRE_CORE_EVO or K.FIRE_CORE, u)
	for _, lick in ipairs(fp.Licks) do
		for i, card in ipairs(lick.Cards) do
			card.Color = i <= 2 and outer or core
		end
	end
	fp.Bed.Color = outer:Lerp(Color3.fromRGB(40, 14, 8), 0.65) -- scorched floor
end

local function firePatch(x: number, z: number, radius: number, life: number, evo: boolean)
	local reduced = ClientSettings.Reduced()
	local cap = reduced and K.FIRE_MAX_PARTS * (GRAPHICS.ReducedEffectsBudget or 0.4) or K.FIRE_MAX_PARTS
	while #firePatches > 0 and (#firePatches >= K.FIRE_MAX_PATCHES or K.fireParts + 5 > cap) do
		freeFirePatch(table.remove(firePatches, 1) :: FirePatch)
	end
	local char = player.Character
	local root = char and char.PrimaryPart
	if root and Vector2.new(root.Position.X - x, root.Position.Z - z).Magnitude > K.FIRE_NEAR then
		return
	end
	-- licks per patch: 3 while the trail is light, 2 once it is busy, 1 near the cap
	local count = reduced and 1 or ((K.fireParts < cap * 0.5 and 3) or (K.fireParts < cap * 0.75 and 2) or 1)
	if K.fireParts + 1 + count * 4 > cap then
		return
	end
	-- the bed is exactly the damage circle (above the dirt paths); later patches sit a hair higher
	local bed = takePart("Cylinder", P.crimson_700, SMOOTH, Vector3.new(0.05, radius * 2, radius * 2), 1)
	bed.CFrame = CFrame.new(x, FLOOR_Y + 0.44 + (K.fireParts % 7) * 0.004, z) * DISC
	local licks: { FireLick } = {}
	local scale = math.clamp(radius / 3.2, 0.8, 1.6)
	local offsets = count == 1 and { 0 } or (count == 2 and { -0.3, 0.3 } or { 0, -0.5, 0.5 })
	for k = 1, count do
		local main = k == 1 and count ~= 2
		local cards = {}
		for i = 1, 4 do
			-- outer pair plastic, core pair glowing
			cards[i] = takePart("Wedge", WHITE, i <= 2 and SMOOTH or NEON, Vector3.new(0.1, 0.1, 0.1), 0)
		end
		licks[k] = {
			Cards = cards,
			Ox = offsets[k] * radius,
			Oz = (math.random() - 0.5) * 0.5,
			W = (main and 1.6 or 1.1) * scale * (0.9 + math.random() * 0.2),
			H = (main and 3.3 or 2.3) * scale * (0.9 + math.random() * 0.2),
			Tilt = (math.random() - 0.5) * 0.3,
			Delay = (k - 1) * 0.09 + math.random() * 0.05,
			Speed = 5 + math.random() * 4,
			Phase = math.random() * TAU,
			Vis = -1,
		}
	end
	local parts = 1 + count * 4
	K.fireParts += parts
	local fp: FirePatch = { Bed = bed, Licks = licks, Parts = parts, X = x, Z = z, R = radius, Start = os.clock(), Life = math.max(0.5, life), Evo = evo, Stage = -1 }
	table.insert(firePatches, fp)
	colourFire(fp, 0)
end

-- A spark lifting off the fire (one at a time, none with Reduced effects).
local function fireEmber(fp: FirePatch, t: number)
	if not room(1) then
		return
	end
	local a, r = math.random() * TAU, fp.R * math.sqrt(math.random()) * 0.7
	local from = Vector3.new(fp.X + math.cos(a) * r, FLOOR_Y + 0.5, fp.Z + math.sin(a) * r)
	local to = from + Vector3.new((math.random() - 0.5) * 1.2, 1.6 + math.random() * 1.2, (math.random() - 0.5) * 1.2)
	local color = fireRamp(fp.Evo and K.FIRE_CORE_EVO or K.FIRE_CORE, math.clamp(t / fp.Life, 0, 1))
	fx("Block", color, NEON, CFrame.new(from), CFrame.new(to), Vector3.one * 0.14, Vector3.one * 0.04, 0.15, 1, 0.55 + math.random() * 0.3, EASE_OUT)
end

-- Sizes a flame card pair: a left and a right wedge sharing the tall centre line (the
-- wedge's tall face leans on it), `lean` moves the tip sideways.
local function sizeLick(lick: FireLick, vis: number)
	lick.Vis = vis
	local h, w = lick.H * vis, lick.W * (0.5 + 0.5 * vis)
	local lean = lick.Tilt * 0.5
	local wl, wr = w * (0.5 + lean), w * (0.5 - lean)
	local c = lick.Cards
	c[1].Size = Vector3.new(0.12, h, wl)
	c[2].Size = Vector3.new(0.12, h, wr)
	c[3].Size = Vector3.new(0.16, h * 0.72, wl * 0.62)
	c[4].Size = Vector3.new(0.16, h * 0.72, wr * 0.62)
end

local function stepFirePatches(now: number)
	local reduced = ClientSettings.Reduced()
	if #firePatches > 0 and not reduced and now >= K.fireEmber then
		K.fireEmber = now + 0.16
		local fp = firePatches[math.random(1, #firePatches)]
		local t = now - fp.Start
		if t > 0.2 and t < fp.Life - 0.4 then
			fireEmber(fp, t)
		end
	end
	if #firePatches == 0 then
		return
	end
	local cam = workspace.CurrentCamera
	if cam then
		local look = cam.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 1e-3 then
			K.fireFace = CFrame.lookAt(Vector3.zero, flat.Unit) -- local -Z = the camera's heading
		end
	end
	local face: CFrame = K.fireFace
	for i = #firePatches, 1, -1 do
		local fp = firePatches[i]
		local t = now - fp.Start
		if t >= fp.Life then
			freeFirePatch(fp)
			table.remove(firePatches, i)
		else
			local stage = math.min(K.FIRE_STAGES, math.floor(t / fp.Life * K.FIRE_STAGES))
			if stage ~= fp.Stage then
				colourFire(fp, stage)
			end
			local left = math.clamp((fp.Life - t) / 0.5, 0, 1) -- 1 → 0 over the last half second
			-- barely there: overlapping beds must never hide the floor
			fp.Bed.Transparency = 1 - 0.09 * math.min(1, t / 0.2) * left
			local origin = CFrame.new(fp.X, FLOOR_Y + 0.1, fp.Z) * face
			for _, lick in ipairs(fp.Licks) do
				local grow = math.clamp((t - lick.Delay) / 0.3, 0, 1)
				local vis = (1 - (1 - grow) * (1 - grow)) * left -- eases out, shrinks at the end
				if vis <= 0.02 then
					for _, card in ipairs(lick.Cards) do
						card.CFrame = PARK
					end
				else
					if math.abs(vis - lick.Vis) > 0.01 then
						sizeLick(lick, vis)
					end
					-- flicker: a small bob and roll, never a size change
					local flick = math.sin(t * lick.Speed + lick.Phase) * 0.1 + math.sin(t * lick.Speed * 1.9 + lick.Phase * 2) * 0.05
					local roll = math.sin(t * lick.Speed * 0.55 + lick.Phase) * 0.14 + lick.Tilt * 0.4
					local base = origin * CFrame.new(lick.Ox, flick, lick.Oz) * CFrame.Angles(0, 0, roll)
					local h = lick.H * vis
					local wl, wr = lick.W * (0.5 + 0.5 * vis) * (0.5 + lick.Tilt * 0.5), lick.W * (0.5 + 0.5 * vis) * (0.5 - lick.Tilt * 0.5)
					local c = lick.Cards
					-- left card: tall face (+Z) toward +X; right card: toward -X
					bulk(c[1], base * CFrame.new(-wl / 2, h / 2, 0) * CFrame.Angles(0, math.pi / 2, 0))
					bulk(c[2], base * CFrame.new(wr / 2, h / 2, 0) * CFrame.Angles(0, -math.pi / 2, 0))
					bulk(c[3], base * CFrame.new(-wl * 0.31, h * 0.36, 0.05) * CFrame.Angles(0, math.pi / 2, 0))
					bulk(c[4], base * CFrame.new(wr * 0.31, h * 0.36, 0.05) * CFrame.Angles(0, -math.pi / 2, 0))
				end
			end
		end
	end
end

-- Healing Totem pulse: a soft green ring out to the totem's reach (brighter when it healed).
local function totemPulseFx(x: number, z: number, radius: number, evo: boolean, healed: boolean)
	local color = evo and FX.Heal:Lerp(FX.Gold, 0.35) or FX.Heal
	wave(x, z, 1.2, radius, healed and 0.32 or 0.22, color, healed and 0.25 or 0.45, 0.55)
	if healed then
		sparkle(Vector3.new(x, FLOOR_Y + 4.2, z), color, 3, 0.6, 1.8, 0.5)
	end
end

-- A small gold burst (turret flak) or a crimson-gold one (Dragon Lance tips).
local function smallBurst(x: number, z: number, radius: number, core: Color3, ringColor: Color3)
	if room(1) then
		fx("Ball", core, SMOOTH, CFrame.new(x, FLOOR_Y + 1.2, z), nil, Vector3.one * 0.5, Vector3.one * radius * 0.55, 0.45, 1, 0.16, EASE_OUT)
	end
	wave(x, z, radius * 0.2, radius, 0.22, ringColor, 0.3, 0.22)
end

--[[
	Chain Hook chains: steel links from the thrower's hand to the hook while it is out. The
	server sends { userId, projectile id, seq } once; the chain follows that projectile
	entry until it is gone.
]]
type Chain = { UserId: number, Id: number, Seq: number, Born: number, Links: { BasePart } }
local chains: { [number]: Chain } = {}
K.CHAIN_MAX_LINKS = 30

local function dropChain(id: number)
	local c = chains[id]
	if not c then
		return
	end
	for _, link in ipairs(c.Links) do
		givePart("Block", link)
	end
	chains[id] = nil
end

local function hookChain(userId: number, id: number, seq: number)
	if type(userId) ~= "number" or type(id) ~= "number" then
		return
	end
	dropChain(id)
	chains[id] = { UserId = userId, Id = id, Seq = tonumber(seq) or -1, Born = os.clock(), Links = {} }
end

local function renderChains(now: number)
	for id, c in pairs(chains) do
		local e = entries[id]
		local root = characterRoot(c.UserId)
		if not e or e.Seq ~= c.Seq or not root then
			-- not drawn yet (the batches can arrive in either order) or gone
			if now - c.Born > 0.6 or (e and e.Seq ~= c.Seq) or not root then
				dropChain(id)
			end
		else
			local to = e.Drawn
			local from = Vector3.new(root.Position.X, to.Y, root.Position.Z)
			local d = to - from
			local len = d.Magnitude
			local count = math.clamp(math.floor(len / 0.85), 1, K.CHAIN_MAX_LINKS)
			local look = len > 0.05 and CFrame.lookAt(from, to) or CFrame.new(from)
			for k = 1, count do
				local link = c.Links[k]
				if not link then
					link = takePart("Block", e.Visual == 30 and P.crimson_700 or P.steel_600, Enum.Material.Metal, Vector3.new(0.16, 0.34, 0.62), 0)
					c.Links[k] = link
				end
				local along = (k - 0.5) / count * len
				bulk(link, look * CFrame.new(0, -math.sin(math.pi * (k - 0.5) / count) * 0.25, -along) * CFrame.Angles(0, 0, k % 2 == 0 and math.pi / 2 or 0))
			end
			for k = #c.Links, count + 1, -1 do
				givePart("Block", c.Links[k])
				c.Links[k] = nil
			end
		end
	end
end

local function onWeaponFx(batch)
	if type(batch) ~= "table" then
		return
	end
	local function each(key: string, fn: ({ any }) -> ())
		local list = batch[key]
		if type(list) == "table" then
			for _, v in ipairs(list) do
				if type(v) == "table" and type(v[1]) == "number" and type(v[2]) == "number" then
					fn(v)
				end
			end
		end
	end
	each("nv", function(v)
		nova(v[1], v[2], tonumber(v[3]) or 8, v[4] == 1)
	end)
	each("fp", function(v)
		firePatch(v[1], v[2], tonumber(v[3]) or 3, tonumber(v[4]) or 2, v[5] == 1)
	end)
	each("tp", function(v)
		totemPulseFx(v[1], v[2], tonumber(v[3]) or 7, v[4] == 1, v[5] == 1)
	end)
	each("hk", function(v)
		hookChain(v[1], v[2], v[3])
	end)
	each("fk", function(v)
		smallBurst(v[1], v[2], tonumber(v[3]) or 3, FX.Gold, P.amber_300)
	end)
	each("lb", function(v)
		smallBurst(v[1], v[2], tonumber(v[3]) or 4, P.gold_200, P.crimson_300)
	end)
	each("sh", function(v)
		sparkle(Vector3.new(v[1], FLOOR_Y + 1, v[2]), FX.Heal, 4, 0.7, 2.6, 0.5)
	end)
end

------------------------------------------------------------------------------------------
-- Gems (faceted octahedron crystals, local bob / spin, a burst when collected)
------------------------------------------------------------------------------------------

--[[
	XP gems must never be mistaken for gold: they are bright saturated azure / blue / violet
	crystals (Theme.Fx.Gem), about 1.5 / 1.9 / 2.6 studs tall for the small / medium / large
	gem (value 1 / 5 / 25; nearby small ones merge server-side, see XPSystem). A crystal is
	a real octahedron built from eight WedgeParts (a pyramid up, a longer one down, every
	facet its own tone) that bobs and turns slowly; a faint tinted disc on the floor and a
	rare glint are its only glow (no lights). Crystals are pooled "kits" handed out to the
	nearest gems only (K.GEM_KITS, fewer with Reduced effects); every other gem is drawn
	as the plain server cube standing on its corner, so a field of hundreds stays cheap.
	A flying gem (attribute "Fly" = the collector's UserId) is animated here: it homes in
	on that player's character with the server's speed rule (Config.XP MagnetSpeed /
	MagnetAcceleration); the server only says when it is collected (Active = false).
]]
local gemState: { [BasePart]: Vector3 } = {} -- active gem → server base position
local gemParts: { BasePart } = {}
local gemCFrames: { CFrame } = {}
local gemClock = 0
local popsThisFrame = 0
K.GEM_TILT = CFrame.Angles(math.rad(45), 0, math.rad(35.26)) -- cube on its corner
K.GEM_SIZE = (Config.XP :: any).GemSize or { Small = 1.1, Medium = 1.45, Large = 1.9 }
local GEM_HEIGHT: number = Config.XP.GemHeight
K.GEM_HOVER = 0.55 -- the crystal's tip floats this far over the floor (bob +-0.2)
-- half width of the square equator, crown (up) height, pavilion (down) height
K.GEM_DIM = { Small = { 0.5, 0.6, 0.95 }, Medium = { 0.65, 0.75, 1.2 }, Large = { 0.85, 1.0, 1.6 } }
K.GEM_KITS = { 44, 24 } -- most crystals drawn at once: normal / Reduced effects
K.GEM_NEAR = { 42, 26 } -- a gem gets a crystal inside this many studs (and keeps it up to +10)
K.GEM_KIT_PARTS = 8
type GemKit = { Wedges: { BasePart }, Halo: BasePart, Kind: string, Scaled: boolean }
type GemFx = { Kit: GemKit?, Kind: string, Pulse: number, Glint: number }
local gemFx: { [BasePart]: GemFx } = {}
local spareKits: { GemKit } = {}
K.kitsInUse = 0
K.gemFly = {} :: { [BasePart]: { Id: number, Pos: Vector3, Speed: number } } -- flights in progress

-- Gem kind from the server cube size (Config.XP.GemSize).
local function gemKindOf(part: BasePart): string
	local x = part.Size.X
	return x >= (K.GEM_SIZE.Medium + K.GEM_SIZE.Large) / 2 and "Large" or (x >= (K.GEM_SIZE.Small + K.GEM_SIZE.Medium) / 2 and "Medium" or "Small")
end

local function gemFxFor(part: BasePart): GemFx
	local g = gemFx[part]
	if not g then
		g = { Kit = nil, Kind = "", Pulse = -10, Glint = math.floor(gemClock / 3.7) }
		gemFx[part] = g
	end
	return g
end

local function takeKit(): GemKit
	local kit = table.remove(spareKits)
	if kit then
		return kit
	end
	local wedges = {}
	for i = 1, K.GEM_KIT_PARTS do
		wedges[i] = takePart("Wedge", WHITE, SMOOTH, Vector3.one, 0)
		wedges[i].Reflectance = 0.06
	end
	local halo = takePart("Cylinder", FX.Gem.Glow, Enum.Material.Neon, Vector3.new(0.05, 1, 1), 1)
	return { Wedges = wedges, Halo = halo, Kind = "", Scaled = false }
end

local function parkKit(kit: GemKit)
	for _, w in ipairs(kit.Wedges) do
		w.CFrame = PARK
	end
	kit.Halo.CFrame = PARK
	kit.Halo.Transparency = 1
	table.insert(spareKits, kit)
end

local function parkGem(part: BasePart)
	local g = gemFx[part]
	if g and g.Kit then
		parkKit(g.Kit)
		g.Kit = nil
		K.kitsInUse -= 1
	end
end

-- Resizes and recolours a crystal for its kind: facets alternate light / dark, the crown
-- lighter than the pavilion (kept close to the saturated base so the crystal reads as a
-- vivid blue, not a pale ice tint).
local function styleKit(kit: GemKit, kind: string)
	kit.Kind = kind
	local d = K.GEM_DIM[kind]
	local base: Color3 = FX.Gem[kind] or FX.Arcane
	local dark = Color3.new(0, 0, 0)
	for i, w in ipairs(kit.Wedges) do
		local up = i <= 4
		w.Size = Vector3.new(d[1] * 2, up and d[2] or d[3], d[1])
		if up then
			w.Color = base:Lerp(WHITE, i % 2 == 0 and 0.32 or 0.1)
		else
			w.Color = base:Lerp(dark, i % 2 == 0 and 0.3 or 0.1)
		end
	end
	kit.Halo.Size = Vector3.new(0.05, d[1] * 2.8, d[1] * 2.8)
	kit.Halo.Color = base
end

-- Poses a crystal whose lowest point is at (x, floorY, z); `scale` pulses it, `yaw` turns it.
local function poseKit(kit: GemKit, kind: string, x: number, floorY: number, z: number, yaw: number, scale: number, n: number): number
	local d = K.GEM_DIM[kind]
	local half, crown, pavilion = d[1] * scale, d[2] * scale, d[3] * scale
	local origin = CFrame.new(x, floorY + pavilion, z) * CFrame.Angles(0, yaw, 0) -- the equator's centre
	for i = 1, 4 do
		local turn = CFrame.Angles(0, (i - 1) * math.pi / 2, 0)
		local up, down = kit.Wedges[i], kit.Wedges[i + 4]
		-- a wedge's tall face (+Z) leans on the axis: four of them make a pyramid
		n += 1
		gemParts[n] = up
		gemCFrames[n] = origin * turn * CFrame.new(0, crown / 2, -half / 2)
		n += 1
		gemParts[n] = down
		gemCFrames[n] = origin * turn * CFrame.new(0, -pavilion / 2, -half / 2) * CFrame.Angles(0, 0, math.pi)
		if scale ~= 1 then
			up.Size = Vector3.new(half * 2, crown, half)
			down.Size = Vector3.new(half * 2, pavilion, half)
		end
	end
	return n
end

-- Burst where a gem was collected: a tinted flash, a four-point glint facing the camera
-- and a few crystal splinters thrown out.
local function gemPop(pos: Vector3, kind: string)
	if popsThisFrame >= 5 or not room(6) then
		return
	end
	popsThisFrame += 1
	local color: Color3 = FX.Gem[kind] or FX.Arcane
	local bright = color:Lerp(WHITE, 0.55)
	local at = pos + Vector3.new(0, 0.5, 0)
	fx("Ball", bright, NEON, CFrame.new(at), nil, Vector3.one * 0.35, Vector3.one * 1.5, 0.15, 1, 0.16, EASE_OUT)
	local cam = workspace.CurrentCamera
	local face = cam and CFrame.lookAt(at, cam.CFrame.Position) or CFrame.new(at)
	fx("Block", bright, NEON, face, nil, Vector3.new(0.1, 1.7, 0.04), Vector3.new(0.03, 0.4, 0.04), 0.1, 1, 0.2, EASE_OUT)
	fx("Block", bright, NEON, face, nil, Vector3.new(1.7, 0.1, 0.04), Vector3.new(0.4, 0.03, 0.04), 0.1, 1, 0.2, EASE_OUT)
	if not ClientSettings.Reduced() then
		for i = 1, 3 do
			local a = i * TAU / 3 + math.random() * 0.8
			local to = at + Vector3.new(math.cos(a) * 1.3, 0.5 + math.random() * 0.5, math.sin(a) * 1.3)
			fx("Wedge", color, SMOOTH, CFrame.new(at) * CFrame.Angles(0, a, 0), CFrame.new(to) * CFrame.Angles(math.random() * 3, a, math.random() * 3), Vector3.new(0.12, 0.3, 0.2), Vector3.new(0.04, 0.12, 0.08), 0.05, 1, 0.3, EASE_OUT)
		end
	end
end

-- A rare four-point glint on the crystal's crown.
local function gemGlint(at: Vector3, kind: string)
	if not room(2) then
		return
	end
	local cam = workspace.CurrentCamera
	local face = cam and CFrame.lookAt(at, cam.CFrame.Position) or CFrame.new(at)
	local color = (FX.Gem[kind] or FX.Arcane):Lerp(WHITE, 0.7)
	fx("Block", color, NEON, face, nil, Vector3.new(0.05, 0.2, 0.03), Vector3.new(0.05, 1.1, 0.03), 0.2, 1, 0.45, EASE_OUT, nil, 0.4)
	fx("Block", color, NEON, face, nil, Vector3.new(0.2, 0.05, 0.03), Vector3.new(1.1, 0.05, 0.03), 0.2, 1, 0.45, EASE_OUT, nil, 0.4)
end

local function trackGem(gem: Instance)
	if not gem:IsA("BasePart") then
		return
	end
	local part = gem :: BasePart
	local function refresh()
		local active = part:GetAttribute("Active") == true
		local base = part:GetAttribute("Base")
		local fly = part:GetAttribute("Fly")
		if active and typeof(base) == "Vector3" then
			local flight = K.gemFly[part]
			if type(fly) == "number" then
				-- flying (or retargeted mid-flight): start from where it is drawn now
				if flight then
					flight.Id = fly
				else
					K.gemFly[part] = { Id = fly, Pos = gemState[part] or base, Speed = 0 }
				end
				gemState[part] = K.gemFly[part].Pos
			else
				K.gemFly[part] = nil
				gemState[part] = base
			end
		else
			local last = gemState[part]
			gemState[part] = nil
			K.gemFly[part] = nil
			parkGem(part)
			if last then
				-- collected next to a player: a burst (and the pickup sound for me)
				local near = math.huge
				for _, other in ipairs(Players:GetPlayers()) do
					local char = other.Character
					local root = char and char.PrimaryPart
					if root then
						local d = (root.Position - last).Magnitude
						near = math.min(near, d)
						if other == player and d < 8 then
							Audio.Play("GemPickup")
						end
					end
				end
				if near < 6 then
					gemPop(last, gemKindOf(part))
				end
			end
		end
	end
	part:GetAttributeChangedSignal("Active"):Connect(refresh)
	part:GetAttributeChangedSignal("Base"):Connect(refresh)
	part:GetAttributeChangedSignal("Fly"):Connect(refresh)
	refresh()
end

-- Flying gems home in on their collector like the server flies them (XPSystem): speed
-- at least half MagnetSpeed, +MagnetAcceleration per second, at most 3x MagnetSpeed; they
-- wait at the player until the server's collect (Active = false) removes them.
K.stepGemFlights = function(dt: number)
	local X = Config.XP
	for part, f in pairs(K.gemFly) do
		local other = Players:GetPlayerByUserId(f.Id)
		local char = other and other.Character
		local root = char and char.PrimaryPart
		if root then
			local to = root.Position - f.Pos
			local dist = to.Magnitude
			f.Speed = math.min(math.max(f.Speed, X.MagnetSpeed * 0.5) + X.MagnetAcceleration * dt, X.MagnetSpeed * 3)
			if dist > 0.05 then
				f.Pos += to.Unit * math.min(dist, f.Speed * dt)
			end
		end
		gemState[part] = f.Pos
	end
end

local function renderGems(dt: number)
	gemClock += dt
	K.stepGemFlights(dt)
	table.clear(gemParts)
	table.clear(gemCFrames)
	local n = 0
	local reduced = ClientSettings.Reduced()
	local slot = reduced and 2 or 1
	local maxKits: number = K.GEM_KITS[slot]
	local enter: number = K.GEM_NEAR[slot]
	local leave = enter + 10
	local char = player.Character
	local root = char and char.PrimaryPart
	local rx, rz = 0, 0
	if root then
		rx, rz = root.Position.X, root.Position.Z
	end
	local glints = 0
	for part, base in pairs(gemState) do
		local g = gemFxFor(part)
		local kind = gemKindOf(part)
		if g.Kind ~= kind then
			if g.Kind ~= "" then
				g.Pulse = gemClock -- merged into a bigger gem: a small swell
			end
			g.Kind = kind
		end
		local phase = base.X * 0.37 + base.Z * 0.21
		local bob = math.sin(gemClock * 2 + phase) * 0.2
		local yaw = gemClock * 1.1 + phase
		local floorY = base.Y - GEM_HEIGHT + K.GEM_HOVER + bob -- the crystal's lowest point
		-- crystals go to the gems nearest the hero (hysteresis keeps them from flickering)
		local dx, dz = base.X - rx, base.Z - rz
		local d2 = dx * dx + dz * dz
		local kit = g.Kit
		if kit and d2 > leave * leave then
			parkGem(part)
			kit = nil
		elseif not kit and d2 <= enter * enter and K.kitsInUse < maxKits then
			kit = takeKit()
			g.Kit = kit
			K.kitsInUse += 1
		end
		local height
		if kit then
			if part.LocalTransparencyModifier ~= 1 then
				part.LocalTransparencyModifier = 1
			end
			if kit.Kind ~= kind then
				styleKit(kit, kind)
			end
			local dim = K.GEM_DIM[kind]
			local pop = 1 + 0.35 * math.max(0, 1 - (gemClock - g.Pulse) / 0.3)
			if pop == 1 and kit.Scaled then
				kit.Scaled = false
				styleKit(kit, kind)
			end
			kit.Scaled = kit.Scaled or pop ~= 1
			n = poseKit(kit, kind, base.X, floorY, base.Z, yaw, pop, n)
			height = (dim[2] + dim[3]) * pop
			-- the floor glow stays on the floor; a gem flying up to a player leaves it behind
			local resting = base.Y <= FLOOR_Y + GEM_HEIGHT + 0.5
			local wantHalo = (resting and not reduced) and 0.9 or 1
			if kit.Halo.Transparency ~= wantHalo then
				kit.Halo.Transparency = wantHalo
			end
			if wantHalo < 1 then
				n += 1
				gemParts[n] = kit.Halo
				gemCFrames[n] = CFrame.new(base.X, FLOOR_Y + 0.42, base.Z) * DISC -- over the dirt paths
			end
			-- a rare glint, a different moment for every gem
			local tick = math.floor((gemClock + phase * 3) / 3.7)
			if tick ~= g.Glint then
				g.Glint = tick
				if not reduced and glints < 2 and d2 < 30 * 30 then
					glints += 1
					gemGlint(Vector3.new(base.X, floorY + height * 0.7, base.Z), kind)
				end
			end
		else
			-- far away: the server cube stood on its corner, glassy in the gem colour
			local color: Color3 = FX.Gem[kind] or FX.Arcane
			if part.LocalTransparencyModifier ~= 0.1 then
				part.LocalTransparencyModifier = 0.1
			end
			if part.Color ~= color then
				part.Color = color
			end
			if part.Material ~= SMOOTH then
				part.Material = SMOOTH
			end
			local centre = Vector3.new(base.X, floorY + part.Size.X * 0.866, base.Z)
			n += 1
			gemParts[n] = part
			gemCFrames[n] = CFrame.new(centre) * CFrame.Angles(0, yaw, 0) * K.GEM_TILT
		end
	end
	if n > 0 then
		workspace:BulkMoveTo(gemParts, gemCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

------------------------------------------------------------------------------------------
-- Floor pickups (bob and spin) and chests (soft glow)
------------------------------------------------------------------------------------------

type Pickup = { Base: CFrame, Parts: { BasePart }, Offsets: { CFrame }, Chest: boolean, Light: PointLight?, Phase: number }
local pickups: { [Model]: Pickup } = {}

local function trackPickup(m: Instance)
	if not m:IsA("Model") then
		return
	end
	task.defer(function()
		if not m.Parent then
			return
		end
		local model = m :: Model
		local base = model:GetPivot()
		local parts, offsets = {}, {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(parts, d)
				table.insert(offsets, base:ToObjectSpace(d.CFrame))
			end
		end
		local chest = model.Name == "Chest"
		local light = model:FindFirstChildWhichIsA("PointLight", true)
		if light then
			light.Brightness = chest and 0.9 or 0.7 -- a modest glow
		end
		pickups[model] = { Base = base, Parts = parts, Offsets = offsets, Chest = chest, Light = light, Phase = math.random() * TAU }
	end)
end

local function renderPickups(now: number)
	for m, pk in pairs(pickups) do
		if not m.Parent then
			pickups[m] = nil
			-- taken next to the local hero: a sparkle where it sat
			local root = player.Character and player.Character.PrimaryPart
			if root and (root.Position - pk.Base.Position).Magnitude < K.PICKUP_SPARKLE_RANGE then
				CombatFx.Pickup(pk.Base.Position, pk.Chest)
			end
		elseif pk.Chest then
			if pk.Light then
				pk.Light.Brightness = 0.9 + math.sin(now * 3 + pk.Phase) * 0.35
			end
		else
			local cf = pk.Base * CFrame.new(0, 0.45 + math.sin(now * 2.6 + pk.Phase) * 0.25, 0) * CFrame.Angles(0, now * 1.4 + pk.Phase, 0)
			for i, part in ipairs(pk.Parts) do
				bulk(part, cf * pk.Offsets[i])
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Player decorations: ground marker, health bar, aura ring
------------------------------------------------------------------------------------------

type Deco = {
	Character: Model?,
	Marker: Ring?,
	MarkerFill: BasePart?,
	Chev: { BasePart }?,
	MarkerStyle: string,
	Aura: Ring?,
	AuraFill: BasePart?,
	Motes: { BasePart }?,
	AuraR: number,
	AuraShown: boolean,
	Bar: BillboardGui?,
	BarFill: Frame?,
	BarTrail: Frame?,
	BarText: TextLabel?,
	BarHp: number,
	BarMax: number,
	BarGrad: UIGradient?,
	BarTeam: boolean,
	BarRevive: boolean,
	Frac: number,
	TrailFrac: number,
	ShowUntil: number,
}
local decos: { [Player]: Deco } = {}
K.AURA_MOTES = 5

-- Facing chevron: two short bars forming a ">" just outside the ring, pointing forward.
K.CHEV_LEN = 0.62
K.CHEV_TIP = 3.5
K.CHEV_ANGLE = math.rad(40)
K.CHEV_L = CFrame.new(-math.sin(K.CHEV_ANGLE) * K.CHEV_LEN / 2, 0, -K.CHEV_TIP + math.cos(K.CHEV_ANGLE) * K.CHEV_LEN / 2) * CFrame.Angles(0, -K.CHEV_ANGLE, 0)
K.CHEV_R = CFrame.new(math.sin(K.CHEV_ANGLE) * K.CHEV_LEN / 2, 0, -K.CHEV_TIP + math.cos(K.CHEV_ANGLE) * K.CHEV_LEN / 2) * CFrame.Angles(0, K.CHEV_ANGLE, 0)

local function newDeco(): Deco
	return {
		Character = nil,
		MarkerStyle = "",
		AuraR = -1,
		AuraShown = false,
		BarTeam = false,
		BarRevive = false,
		BarHp = -1,
		BarMax = -1,
		Frac = -1,
		TrailFrac = 1,
		ShowUntil = 0,
	}
end

local function corner(parent: Instance, px: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = parent
end

-- Small overhead bar: thin dark outline, ivory track, crimson fill, light "lost" trail.
local function buildBar(deco: Deco, root: BasePart, team: boolean)
	if deco.Bar then
		deco.Bar:Destroy()
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "SwarmHP"
	local bw, bh = team and 44 or 50, team and 7 or 8
	gui.Size = UDim2.fromOffset(bw + 20, bh + 15)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 5.1, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.MaxDistance = 500
	gui.Adornee = root
	gui.Enabled = false
	local outline = Instance.new("Frame")
	outline.Name = "Outline"
	outline.AnchorPoint = Vector2.new(0.5, 1)
	outline.Position = UDim2.fromScale(0.5, 1)
	outline.Size = UDim2.fromOffset(bw, bh)
	outline.BackgroundColor3 = P.slate_950
	outline.BackgroundTransparency = 0.1
	outline.BorderSizePixel = 0
	outline.Parent = gui
	corner(outline, 3)
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.Position = UDim2.fromOffset(1, 1)
	track.Size = UDim2.new(1, -2, 1, -2)
	track.BackgroundColor3 = P.ivory_400
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.Parent = outline
	corner(track, 2)
	local trail = Instance.new("Frame")
	trail.Name = "Trail"
	trail.Size = UDim2.fromScale(1, 1)
	trail.BackgroundColor3 = P.ivory_100
	trail.BorderSizePixel = 0
	trail.Parent = track
	corner(trail, 2)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = WHITE
	fill.BorderSizePixel = 0
	fill.Parent = track
	corner(fill, 2)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(P.crimson_400, P.crimson_600)
	grad.Rotation = 90
	grad.Parent = fill
	-- "85 / 100" above the bar; rewritten only when HP or MaxHP change
	local num = Instance.new("TextLabel")
	num.Name = "Number"
	num.BackgroundTransparency = 1
	num.AnchorPoint = Vector2.new(0.5, 0)
	num.Position = UDim2.fromScale(0.5, 0)
	num.Size = UDim2.new(1, 0, 0, 13)
	num.FontFace = Theme.Font.Number
	num.TextSize = 12
	num.TextColor3 = P.ivory_100
	num.TextStrokeColor3 = P.slate_950
	num.TextStrokeTransparency = 0.35
	num.Text = ""
	num.Parent = gui
	gui.Parent = fxFolder
	deco.BarText, deco.BarHp, deco.BarMax = num, -1, -1
	deco.Bar, deco.BarFill, deco.BarTrail, deco.BarGrad = gui, fill, trail, grad
	deco.BarTeam = team
	deco.BarRevive = false
	deco.Frac = -1
	deco.TrailFrac = 1
end

K.BAR_HEALTH = ColorSequence.new(P.crimson_400, P.crimson_600)
K.BAR_REVIVE = ColorSequence.new(P.gold_300, P.gold_500)

--[[
	Local player: the small bar only (no number), shown only while hurt (and a moment after
	healing to full); the HUD has the full meter and the numbers. Teammates: always shown; a fallen teammate's bar turns into their gold
	revive meter.
]]
local function updateBar(deco: Deco, other: Player, root: BasePart, isLocal: boolean, alive: boolean, now: number, dt: number)
	local team = not isLocal
	local bar = deco.Bar
	if not bar or deco.BarTeam ~= team or bar.Adornee ~= root then
		buildBar(deco, root, team)
		bar = deco.Bar
	end
	local gui = bar :: BillboardGui
	local fill = deco.BarFill :: Frame
	local trail = deco.BarTrail :: Frame
	local grad = deco.BarGrad :: UIGradient
	local hp = tonumber(other:GetAttribute("HP")) or 0
	local maxHp = math.max(1, tonumber(other:GetAttribute("MaxHP")) or 1)
	local frac = math.clamp(hp / maxHp, 0, 1)
	local show: boolean
	if not alive then
		show = team
	elseif isLocal then
		if frac < 0.999 then
			deco.ShowUntil = now + 1.2
		end
		show = now < deco.ShowUntil
	else
		show = true
	end
	if gui.Enabled ~= show then
		gui.Enabled = show
	end
	if not show then
		return
	end
	local revive = not alive
	if deco.BarRevive ~= revive then
		deco.BarRevive = revive
		grad.Color = revive and K.BAR_REVIVE or K.BAR_HEALTH
		deco.Frac = -1
	end
	-- the number: teammates only (the local hero's "85 / 100" is on the HUD's health panel)
	local num = deco.BarText :: TextLabel
	local numShown = not revive and not isLocal
	if num.Visible ~= numShown then
		num.Visible = numShown
	end
	local hpShown, maxShown = math.ceil(hp), math.ceil(maxHp)
	if numShown and (deco.BarHp ~= hpShown or deco.BarMax ~= maxShown) then
		deco.BarHp, deco.BarMax = hpShown, maxShown
		num.Text = string.format("%d / %d", hpShown, maxShown)
	end
	local value = frac
	if revive then
		value = math.clamp(tonumber(other:GetAttribute("ReviveProgress")) or 0, 0, 1)
	end
	if value ~= deco.Frac then
		deco.Frac = value
		fill.Size = UDim2.fromScale(value, 1)
	end
	-- the light trail shows health just lost, then catches up with the fill
	local trailFrac = deco.TrailFrac
	if revive or value >= trailFrac then
		trailFrac = value
	else
		trailFrac = math.max(value, trailFrac - dt * 0.6)
	end
	if trailFrac ~= deco.TrailFrac or trail.Size.X.Scale ~= trailFrac then
		deco.TrailFrac = trailFrac
		trail.Size = UDim2.fromScale(trailFrac, 1)
	end
end

local function hideMarker(deco: Deco)
	if deco.MarkerStyle == "" then
		return
	end
	deco.MarkerStyle = ""
	if deco.Marker then
		hideRing(deco.Marker)
	end
	if deco.MarkerFill then
		deco.MarkerFill.CFrame = PARK
	end
	for _, c in ipairs(deco.Chev or {}) do
		c.CFrame = PARK
	end
end

-- Gold ring + soft fill + facing chevron under the local hero; slate-blue ring under
-- teammates; a pulsing crimson ring under a fallen player.
local function updateMarker(deco: Deco, root: BasePart, isLocal: boolean, alive: boolean, now: number)
	if not deco.Marker then
		deco.Marker = newRing(20)
		local fill = newPart("Cylinder")
		fill.Transparency = 1
		deco.MarkerFill = fill
		deco.Chev = { newPart("Block"), newPart("Block") }
	end
	local ringObj = deco.Marker :: Ring
	local fill = deco.MarkerFill :: BasePart
	local chev = deco.Chev :: { BasePart }
	local style = not alive and "down" or (isLocal and "local" or "team")
	if deco.MarkerStyle ~= style then
		deco.MarkerStyle = style
		local color = style == "local" and FX.PlayerRing or FX.TeamRing
		fill.Color = FX.PlayerRing
		fill.Size = Vector3.new(0.04, 5.3, 5.3)
		fill.Transparency = 0.86
		if style ~= "local" then
			fill.CFrame = PARK
		end
		for _, c in ipairs(chev) do
			c.Color = color
			c.Size = Vector3.new(0.17, 0.05, K.CHEV_LEN)
			c.Transparency = style == "local" and 0.06 or 0.25
			if style == "down" then
				c.CFrame = PARK
			end
		end
	end
	local pos = root.Position
	local y = FLOOR_Y + 0.07
	if style == "down" then
		styleRing(ringObj, 2.6, 0.2, P.crimson_300, math.floor((0.4 + 0.18 * math.sin(now * 5)) * 50 + 0.5) / 50)
	elseif style == "local" then
		styleRing(ringObj, 2.7, 0.22, FX.PlayerRing, 0.06)
	else
		styleRing(ringObj, 2.5, 0.18, FX.TeamRing, 0.15)
	end
	placeRing(ringObj, pos.X, y, pos.Z, 0)
	if style == "local" then
		bulk(fill, CFrame.new(pos.X, y - 0.012, pos.Z) * DISC)
	end
	if style ~= "down" then
		local look = root.CFrame.LookVector
		local cf = CFrame.new(pos.X, y, pos.Z) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
		bulk(chev[1], cf * K.CHEV_L)
		bulk(chev[2], cf * K.CHEV_R)
	end
end

local function hideAura(deco: Deco)
	if not deco.AuraShown then
		return
	end
	deco.AuraShown = false
	if deco.Aura then
		hideRing(deco.Aura)
	end
	if deco.AuraFill then
		deco.AuraFill.CFrame = PARK
	end
	for _, m in ipairs(deco.Motes or {}) do
		m.CFrame = PARK
	end
end

--[[
	Garlic aura: a thin dashed ivory ring at the damage edge turning slowly, a very faint
	fill that breathes once a second and three motes. Soul Eater (evolved): arcane blue,
	turning the other way, with five motes spiralling inward like pulled souls.
]]
local function updateAura(deco: Deco, root: BasePart, radius: number, evo: boolean, now: number)
	if not deco.Aura then
		deco.Aura = newRing(28)
		deco.AuraFill = newPart("Cylinder")
		local motes = {}
		for i = 1, K.AURA_MOTES do
			local m = newPart("Ball")
			m.Material = NEON
			m.Size = Vector3.one * 0.26
			motes[i] = m
		end
		deco.Motes = motes
	end
	deco.AuraShown = true
	local color = evo and FX.Arcane or P.ivory_200
	local pos = root.Position
	local ringObj = deco.Aura :: Ring
	styleRing(ringObj, radius, 0.16, color, 0.45, 0.62)
	placeRing(ringObj, pos.X, FLOOR_Y + 0.1, pos.Z, evo and -now * 0.8 or now * 0.3)
	local fill = deco.AuraFill :: BasePart
	if deco.AuraR ~= radius then
		deco.AuraR = radius
		fill.Size = Vector3.new(0.04, radius * 2, radius * 2)
	end
	local fillColor = evo and P.slate_300 or P.moss_100
	if fill.Color ~= fillColor then
		fill.Color = fillColor
	end
	fill.Transparency = 0.93 + 0.02 * math.sin(now * TAU)
	bulk(fill, CFrame.new(pos.X, FLOOR_Y + 0.05, pos.Z) * DISC)
	local motes = deco.Motes :: { BasePart }
	local shown = evo and K.AURA_MOTES or 3
	for i, mote in ipairs(motes) do
		if i <= shown then
			local a = now * (evo and 2.2 or 1.1) + i * TAU / shown
			local r = radius * 0.85
			if evo then
				r = radius * (1 - ((now * 0.7 + i / shown) % 1) * 0.85)
			end
			if mote.Color ~= color then
				mote.Color = color
			end
			mote.Transparency = 0.3
			bulk(mote, CFrame.new(pos.X + math.cos(a) * r, FLOOR_Y + 0.9 + math.sin(now * 3 + i) * 0.3, pos.Z + math.sin(a) * r))
		else
			mote.CFrame = PARK
		end
	end
end

local rigs: { [Player]: any } = {}

local function updateDecos(now: number, dt: number)
	local meInRun = player:GetAttribute("InRun") == true
	for _, other in ipairs(Players:GetPlayers()) do
		local deco = decos[other]
		if not deco then
			deco = newDeco()
			decos[other] = deco
		end
		local char = other.Character
		local root = char and char.PrimaryPart
		local isLocal = other == player
		local inRun = other:GetAttribute("InRun") == true
		local alive = other:GetAttribute("Alive") ~= false
		if deco.Character ~= char then
			deco.Character = char
			if deco.Bar then
				deco.Bar:Destroy()
				deco.Bar = nil
			end
		end
		if root and inRun and (isLocal or meInRun) then
			updateMarker(deco, root, isLocal, alive, now)
			updateBar(deco, other, root, isLocal, alive, now, dt)
		else
			hideMarker(deco)
			if deco.Bar and deco.Bar.Enabled then
				deco.Bar.Enabled = false
			end
		end
		local radius = tonumber(other:GetAttribute("AuraRadius")) or 0
		if root and inRun and alive and radius > 0 and (isLocal or meInRun) then
			updateAura(deco, root, radius, other:GetAttribute("AuraEvo") == true, now)
		else
			hideAura(deco)
		end
	end
	for other, deco in pairs(decos) do
		if not other.Parent then
			destroyRing(deco.Marker)
			destroyRing(deco.Aura)
			for _, part in ipairs({ deco.MarkerFill, deco.AuraFill } :: { BasePart? }) do
				if part then
					part:Destroy()
				end
			end
			for _, part in ipairs(deco.Chev or {}) do
				part:Destroy()
			end
			for _, part in ipairs(deco.Motes or {}) do
				part:Destroy()
			end
			if deco.Bar then
				deco.Bar:Destroy()
			end
			decos[other] = nil
			poses[other.UserId] = nil
			rigs[other] = nil
		end
	end
end

------------------------------------------------------------------------------------------
-- Hero animation: walk cycle, idle breathing, attack poses
------------------------------------------------------------------------------------------

--[[
	Procedural animation through the rig's own Motor6Ds (RootJoint on the root; Neck,
	shoulders and hips on the torso). Joint points differ per hero model (MeshCatalog
	Joints), so nothing assumes positions: rotations happen at each joint, and the leg
	length used for the walk's body bob is read from the hip joint.
	  Walk   chunky arm swing, legs, a body bob that keeps the feet planted (the hips drop
	         as the legs spread), a slight lean into the run and a shoulder twist.
	  Idle   slow breathing: the chest rises, the arms ease out, the head nods a touch.
	  Swing  sword arm raised and swept across with the blade, shoulders winding up and
	         following through, shield arm up; a swing behind the hero is a spin slash.
	  Throw  arm cocks back over the head, then snaps forward with a twist.
	  Cast   arm (staff) raised forward, the off hand lifts.
	  Fallen slumped forward and lowered, arms hanging.
]]
type Rig = {
	Char: Model,
	Root: BasePart,
	RootJoint: Motor6D?,
	Neck: Motor6D?,
	LS: Motor6D?,
	RS: Motor6D?,
	LH: Motor6D?,
	RH: Motor6D?,
	Leg: number,
	Phase: number,
	Move: number,
	Down: number,
	Seed: number,
	Complete: boolean,
	RetryAt: number,
}

local function motorFor(torso: Instance, name: string, partName: string): Motor6D?
	local m = torso:FindFirstChild(name)
	if m and m:IsA("Motor6D") then
		return m
	end
	-- a rig that names its joints differently: the Motor6D driving that body part
	for _, d in ipairs(torso:GetChildren()) do
		if d:IsA("Motor6D") and d.Part1 and d.Part1.Name == partName then
			return d
		end
	end
	return nil
end

local function buildRig(char: Model, now: number): Rig?
	local root = char:FindFirstChild("HumanoidRootPart")
	local torso = char:FindFirstChild("Torso")
	if not (root and root:IsA("BasePart") and torso and torso:IsA("BasePart")) then
		return nil
	end
	local rj = root:FindFirstChild("RootJoint")
	local rig: Rig = {
		Char = char,
		Root = root,
		RootJoint = (rj and rj:IsA("Motor6D")) and rj or nil,
		Neck = motorFor(torso, "Neck", "Head"),
		LS = motorFor(torso, "Left Shoulder", "Left Arm"),
		RS = motorFor(torso, "Right Shoulder", "Right Arm"),
		LH = motorFor(torso, "Left Hip", "Left Leg"),
		RH = motorFor(torso, "Right Hip", "Right Leg"),
		Leg = 2,
		Phase = 0,
		Move = 0,
		Down = 0,
		Seed = math.random() * 10,
		Complete = false,
		RetryAt = now + 1,
	}
	rig.Complete = rig.RootJoint ~= nil and rig.LS ~= nil and rig.RS ~= nil and rig.LH ~= nil and rig.RH ~= nil
	-- leg length (hip joint to soles) from the rig's own joints, not from live poses
	local hip = rig.LH or rig.RH
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hipHeight = hum and hum.HipHeight or 2
	if hip then
		local jointY: number
		local rootJoint = rig.RootJoint
		if rootJoint and rootJoint.Part1 == hip.Part0 then
			jointY = (rootJoint.C0 * rootJoint.C1:Inverse() * hip.C0).Position.Y
		elseif hip.Part0 then
			jointY = root.CFrame:PointToObjectSpace((hip.Part0.CFrame * hip.C0).Position).Y
		else
			jointY = -1
		end
		rig.Leg = math.clamp(jointY + root.Size.Y / 2 + hipHeight, 0.8, 4)
	end
	return rig
end

-- Right-arm transform, its weight, body spin, body twist and the off-arm transform for a
-- pose at time t (armCF = nil when the pose is over).
local function poseTransform(pose: Pose, t: number): (CFrame?, number, number, number, CFrame)
	local length = 0
	local armCF = CFrame.identity
	local off = CFrame.identity
	local spin, twist = 0, 0
	if pose.Kind == "Swing" then
		length = K.SWING_WINDUP + K.SWING_SWEEP
		local tt = math.min(t, length)
		local s = pose.Sweep
		local yawA
		if tt < K.SWING_WINDUP then
			local u = easeOut(tt / K.SWING_WINDUP)
			yawA = s * (0.5 + 0.6 * u)
			twist = s * 0.3 * u
		else
			local u = easeOut((tt - K.SWING_WINDUP) / K.SWING_SWEEP)
			yawA = s * 1.1 - s * 2.3 * u
			twist = s * 0.3 - s * 0.65 * u
		end
		yawA = math.clamp(yawA, -pose.Half, pose.Half)
		if pose.Back then
			yawA = -1.0 -- arm held out to the side while the body spins
			twist = 0
		end
		armCF = CFrame.Angles(0, yawA, 0) * CFrame.Angles(1.45, 0, 0)
		off = CFrame.Angles(0.55, 0, -0.3) -- shield arm up as a guard
		if pose.Back and tt >= K.SWING_WINDUP then
			-- a full turn over the sweep and the recovery
			spin = s * TAU * easeOut((t - K.SWING_WINDUP) / (K.SWING_SWEEP + K.POSE_RECOVER))
		end
	elseif pose.Kind == "Throw" then
		length = K.THROW_TIME
		local u = math.min(t, length) / length
		local pitch
		if u < 0.4 then
			local k = easeOut(u / 0.4)
			pitch = 3.0 * k
			twist = 0.3 * k
		else
			local k = easeOut((u - 0.4) / 0.6)
			pitch = 3.0 - 2.2 * k
			twist = 0.3 - 0.55 * k
		end
		armCF = CFrame.Angles(pitch, 0, 0.1)
		off = CFrame.Angles(0.5, 0, -0.15)
	else
		length = K.CAST_TIME
		local k = easeOut(math.min(t, length) / (length * 0.45))
		armCF = CFrame.Angles(1.65 * k, 0, 0.12 * k)
		off = CFrame.Angles(0.7 * k, 0, -0.2 * k)
		twist = -0.12 * k
	end
	if t > length + K.POSE_RECOVER then
		return nil, 0, 0, 0, off
	end
	local w = t <= length and 1 or 1 - (t - length) / K.POSE_RECOVER
	if pose.Back and pose.Kind == "Swing" and t > length then
		w = 1 -- keep the spin going until it has turned all the way round
	end
	return armCF, w, spin, twist, off
end

local function setTransform(m: Motor6D?, cf: CFrame)
	if m then
		m.Transform = cf
	end
end

local function animateRig(other: Player, rig: Rig, dt: number, now: number)
	local root = rig.Root
	local v = root.AssemblyLinearVelocity
	local speed = math.sqrt(v.X * v.X + v.Z * v.Z)
	local alive = other:GetAttribute("Alive") ~= false
	local fallen = not alive and other:GetAttribute("InRun") == true
	rig.Move += ((alive and math.clamp(speed / 16, 0, 1.25) or 0) - rig.Move) * (1 - math.exp(-dt * 10))
	rig.Down += ((fallen and 1 or 0) - rig.Down) * (1 - math.exp(-dt * 6))
	local move = rig.Move
	local walk = math.min(move, 1)
	if walk > 0.02 then
		rig.Phase = (rig.Phase + dt * (6.5 + 5 * move)) % TAU -- cadence follows speed
	end
	local s = math.sin(rig.Phase)
	local legA = 0.6 * walk * s
	local armA = 0.78 * walk * s
	local breath = math.sin(now * 2.2 + rig.Seed) * (1 - walk)
	-- feet stay planted: the hips drop as the legs spread (that is the walk's bob)
	local bob = -0.7 * rig.Leg * (1 - math.cos(legA)) + 0.035 * breath
	local lean = -0.09 * walk
	local twist = 0.09 * walk * s
	local rs = CFrame.Angles(-armA, 0, 0.07 + 0.03 * breath)
	local ls = CFrame.Angles(armA, 0, -0.07 - 0.03 * breath)
	local spin = 0
	local pose = poses[other.UserId]
	if pose then
		local armCF, w, bodySpin, bodyTwist, off = poseTransform(pose, now - pose.Start)
		if armCF then
			rs = rs:Lerp(armCF, w)
			ls = ls:Lerp(off, w * 0.7)
			spin = bodySpin
			twist += (bodyTwist - twist) * w
		else
			poses[other.UserId] = nil
		end
	end
	local down = rig.Down
	if down > 0.01 then
		bob -= 0.45 * down
		lean += (-0.35 - lean) * down
		rs = rs:Lerp(CFrame.Angles(0.35, 0, 0.05), down)
		ls = ls:Lerp(CFrame.Angles(0.35, 0, -0.05), down)
	end
	setTransform(rig.RootJoint, CFrame.new(0, bob, 0) * CFrame.Angles(0, twist + spin, 0) * CFrame.Angles(lean, 0, 0))
	setTransform(rig.Neck, CFrame.Angles(-lean * 0.5 + 0.03 * breath - 0.25 * down, -twist * 0.6, 0))
	setTransform(rig.RS, rs)
	setTransform(rig.LS, ls)
	-- legs: the swing, plus undoing the torso's lean and twist so they stay under the hero
	setTransform(rig.LH, CFrame.Angles(-legA - lean, -twist, 0))
	setTransform(rig.RH, CFrame.Angles(legA - lean, -twist, 0))
end

local function animateLimbs(dt: number)
	local now = os.clock()
	for _, other in ipairs(Players:GetPlayers()) do
		local char = other.Character
		local rig: Rig? = rigs[other]
		if rig and (rig.Char ~= char or (not rig.Complete and now >= rig.RetryAt)) then
			rig = nil -- new character, or joints still arriving: build again
		end
		if not rig and char then
			rig = buildRig(char, now)
		end
		rigs[other] = rig
		if rig and rig.Root.Parent then
			animateRig(other, rig, dt, now)
		end
	end
end

------------------------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------------------------

function VFX.Init(opts: { OnLocalEvent: ((string) -> ())? }?)
	onLocalEvent = opts and opts.OnLocalEvent or nil
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "SwarmClientFx"
	fxFolder.Parent = workspace

	Occlusion.Init()
	CombatFx.Init(workspace)

	Remotes.Get("ProjectileBatch").OnClientEvent:Connect(onProjectileBatch)
	Remotes.Get("FxBatch").OnClientEvent:Connect(onFxBatch)
	Remotes.Get("WeaponFx").OnClientEvent:Connect(onWeaponFx)

	task.spawn(function()
		local folder = workspace:WaitForChild("SwarmPickups")
		folder.ChildAdded:Connect(trackPickup)
		for _, m in ipairs(folder:GetChildren()) do
			trackPickup(m)
		end
	end)
	task.spawn(function()
		local gems = workspace:WaitForChild("SwarmGems")
		gems.ChildAdded:Connect(trackGem)
		for _, g in ipairs(gems:GetChildren()) do
			trackGem(g)
		end
	end)

	RunService.RenderStepped:Connect(function(dt)
		local now = os.clock()
		renderProjectiles(dt, now)
		renderSwings(now)
		stepAnims(now)
		stepWaves(now)
		stepPools(now)
		stepFirePatches(now)
		renderChains(now)
		renderPickups(now)
		renderGems(dt)
		renderCoins(now)
		updateFlashes(now)
		updateDecos(now, dt)
		flushBulk()
		popsThisFrame = 0
	end)
	RunService.PreSimulation:Connect(animateLimbs)
end

return VFX
