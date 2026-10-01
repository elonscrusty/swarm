--[[
	VFX.lua
	All client-side visuals. Nothing here affects gameplay.

	* Projectiles: decodes the ProjectileBatch buffer (see WeaponSystem) and moves pooled
	  local parts with interpolation between batches (one workspace:BulkMoveTo per frame).
	  Each visual style spins/tumbles from time alone, gets a pooled Trail and an impact
	  puff (or glass shatter) when it disappears; the visual tier makes trails stronger.
	* Effects: FxBatch (hit flashes, death poofs, sword swings, lightning, pools, explosions,
	  shockwaves, boss telegraphs, player events, sounds) with pooled parts and tweens.
	* Gems: local bob/spin on top of the server position (attribute "Base").
	* Garlic aura (ring, pulse, motes), HP bars over players, procedural limb swing and
	  attack poses (sword swing / throw / cast) for characters.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Audio = require(script.Parent.Audio)
local ModelLibrary = require(script.Parent.ModelLibrary)
local EnemyRenderer = require(script.Parent.EnemyRenderer)
local CameraController = require(script.Parent.CameraController)

local VFX = {}

local player = Players.LocalPlayer
local PARK = CFrame.new(0, -150, 0) -- under the floor, above FallenPartsDestroyHeight
local FLOOR_Y = Config.ArenaOrigin.Y

local fxFolder: Folder
local onLocalEvent: ((string) -> ())? = nil

------------------------------------------------------------------------------------------
-- Part pools
------------------------------------------------------------------------------------------

local function newPart(shape: Enum.PartType?, color: Color3, material: Enum.Material, size: Vector3): Part
	local p = Instance.new("Part")
	if shape then
		p.Shape = shape
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = material
	p.Color = color
	p.Size = size
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CFrame = PARK
	p.Parent = fxFolder
	return p
end

-- Generic effect pools keyed by shape name ("Ball", "Block", "Cylinder").
local effectPools: { [string]: { Part } } = { Ball = {}, Block = {}, Cylinder = {} }
local SHAPES = { Ball = Enum.PartType.Ball, Block = Enum.PartType.Block, Cylinder = Enum.PartType.Cylinder }

local function getEffectPart(shape: string): Part
	local list = effectPools[shape]
	local p = table.remove(list)
	if not p then
		p = newPart(SHAPES[shape], Color3.new(1, 1, 1), Enum.Material.Neon, Vector3.one)
	end
	p.Transparency = 0
	return p
end

local function releaseEffectPart(shape: string, p: Part)
	p.CFrame = PARK
	table.insert(effectPools[shape], p)
end

-- Tween an effect part, then return it to the pool.
local function play(shape: string, p: Part, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?)
	local tween = TweenService:Create(p, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	tween.Completed:Once(function()
		releaseEffectPart(shape, p)
	end)
	tween:Play()
end

-- Flat disc lying on the floor (cylinder axis is X, so rotate it upright).
local DISC = CFrame.Angles(0, 0, math.rad(90))

------------------------------------------------------------------------------------------
-- Attack poses (purely visual arm / body motion on top of the walk cycle)
------------------------------------------------------------------------------------------

--[[
	A pose is started when this client sees a player attack: a sword swing (FxBatch "s")
	or a projectile appearing next to a player (throw / cast). animateLimbs blends it over
	the walk cycle through the rig's existing Motor6Ds (Right Shoulder, RootJoint).
]]
type Pose = { Kind: string, Start: number, Sweep: number, Back: boolean, Half: number }
local poses: { [number]: Pose } = {}

local SWING_WINDUP = 0.07 -- blade pulls back
local SWING_SWEEP = 0.15 -- blade crosses the arc (ease-out)
local SWING_FADE = 0.12 -- blade fades after the sweep
local POSE_RECOVER = 0.16 -- arm blends back to the walk cycle
local THROW_TIME = 0.24
local CAST_TIME = 0.2

local function easeOut(u: number): number
	local v = 1 - math.clamp(u, 0, 1)
	return 1 - v * v * v
end

local function startPose(userId: number, kind: string, sweep: number?, back: boolean?, half: number?)
	local now = os.clock()
	local cur = poses[userId]
	if cur and kind ~= "Swing" then
		-- throws never interrupt a swing or a throw that is still playing
		local busy = cur.Kind == "Swing" and (SWING_WINDUP + SWING_SWEEP + POSE_RECOVER) or THROW_TIME
		if now - cur.Start < busy then
			return
		end
	end
	poses[userId] = { Kind = kind, Start = now, Sweep = sweep or 1, Back = back == true, Half = half or 1.3 }
end

------------------------------------------------------------------------------------------
-- Trails (pooled Trail + carrier part, reused by projectiles)
------------------------------------------------------------------------------------------

type TrailSlot = { Part: Part, Trail: Trail, A0: Attachment, A1: Attachment, Life: number, FreeAt: number }

local MAX_TRAILS = 64 -- projectiles beyond this simply fly without a trail
local trailCount = 0
local freeTrails: { TrailSlot } = {}
local coolingTrails: { TrailSlot } = {}

local function newTrailSlot(): TrailSlot
	local p = newPart(Enum.PartType.Block, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, Vector3.new(0.1, 0.1, 0.1))
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
	trail.WidthScale = NumberSequence.new(1, 0.25)
	trail.Enabled = false
	trail.Parent = p
	return { Part = p, Trail = trail, A0 = a0, A1 = a1, Life = 0.2, FreeAt = 0 }
end

-- Takes a trail and starts it at `cf` (nil when the budget is used up).
local function acquireTrail(cf: CFrame, color: Color3, width: number, life: number, tier: number): TrailSlot?
	local slot = table.remove(freeTrails)
	if not slot then
		if trailCount >= MAX_TRAILS then
			return nil
		end
		trailCount += 1
		slot = newTrailSlot()
	end
	local s = slot :: TrailSlot
	s.A0.Position = Vector3.new(-width / 2, 0, 0)
	s.A1.Position = Vector3.new(width / 2, 0, 0)
	s.Life = life
	s.Trail.Lifetime = life
	s.Trail.Color = ColorSequence.new(color:Lerp(Color3.new(1, 1, 1), 0.5), color)
	s.Trail.LightEmission = 0.6 + tier * 0.13
	s.Trail.Transparency = NumberSequence.new(math.max(0.05, 0.5 - tier * 0.13), 1)
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

local function stepTrails()
	local now = os.clock()
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
local function poseFromSpawn(pos: Vector3, style: string?)
	if style == nil or style == "Stinger" then
		return
	end
	for _, other in ipairs(Players:GetPlayers()) do
		local char = other.Character
		local root = char and char.PrimaryPart
		if root then
			local d = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
			if d.Magnitude < 3.5 then
				startPose(other.UserId, style == "Orb" and "Cast" or "Throw")
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
			-- low 5 bits = visual index, the rest = cosmetic tier (see WeaponSystem)
			local visual = raw % 32
			local tier = raw // 32
			local def = WeaponData.Visuals[visual] or WeaponData.Visuals[1]
			if not WeaponData.Visuals[visual] then
				visual = 1
			end
			local trail: TrailSlot? = nil
			local td = def.Trail
			if td then
				trail = acquireTrail(CFrame.new(pos) * CFrame.Angles(0, yaw, 0), td.Color, td.Width * (0.7 + tier * 0.2), td.Life * (1 + tier * 0.15), tier)
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
			}
			poseFromSpawn(pos, def.Style)
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
	end
	return CFrame.Angles(0, e.Yaw + age * spin, 0)
end

local spinClock = 0
local function renderProjectiles(dt: number)
	spinClock += dt
	impactBudget = 10
	stepTrails()
	table.clear(projParts)
	table.clear(projCFrames)
	local now = os.clock()
	local n = 0
	for _, e in pairs(entries) do
		e.T += dt / syncInterval
		local alpha = math.min(e.T, 1.5) -- small extrapolation hides jitter
		local pos = e.From:Lerp(e.To, alpha)
		e.Drawn = pos
		local cf = CFrame.new(pos) * projectileRotation(e, now - e.Born)
		for _, piece in ipairs(e.Pieces) do
			n += 1
			projParts[n] = piece.Part
			projCFrames[n] = ModelLibrary.PieceCFrame(cf, piece, spinClock, e.Phase, 1)
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

------------------------------------------------------------------------------------------
-- Enemy hit flashes
------------------------------------------------------------------------------------------

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
		body.Color = Color3.new(1, 1, 1)
	end
	flashing[body] = os.clock() + Config.Enemies.HitFlashSeconds
end

local function updateFlashes()
	local now = os.clock()
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

------------------------------------------------------------------------------------------
-- Effects from FxBatch
------------------------------------------------------------------------------------------

local function deathPoof(x: number, z: number, color: Color3, size: number)
	local p = getEffectPart("Ball")
	p.Color = color
	p.Size = Vector3.one * size
	p.Transparency = 0.2
	p.CFrame = CFrame.new(x, FLOOR_Y + size / 2, z)
	play("Ball", p, 0.3, { Size = Vector3.one * size * 1.8, Transparency = 1 })
end

local function characterRoot(userId: number): BasePart?
	local other = Players:GetPlayerByUserId(userId)
	local char = other and other.Character
	return char and char.PrimaryPart
end

--[[
	Sword swings. Each swing is a pooled rig: a glowing blade part pivoting around the
	player (inner end near the body, tip at the hit reach), a Trail between the blade's two
	ends that paints the crescent behind it, and a bright tip spark. Timeline:
	  wind-up (blade pulls back, ghosted) → sweep across the arc (ease-out, trail on,
	  white hit flash mid-sweep) → blade fades while the trail tail dies away.
	The arc width comes from WeaponData (the server hits the same sector).
]]
type SwingRig = { Blade: Part, Tip: Part, Trail: Trail, A0: Attachment, A1: Attachment }
type Swing = { Rig: SwingRig, Root: BasePart?, X: number, Z: number, Yaw: number, Reach: number, Sweep: number, Tier: number, Start: number, Trailing: boolean, Life: number }

local SWING_ARC = math.rad(WeaponData.Weapons.Whip.Params.Arc)
local SWING_PULL = math.rad(22) -- extra wind-up beyond the arc start
local SWING_INNER = 1.2
local SWING_HEIGHT = 2.4
local SWING_COLORS = {
	[0] = Color3.fromRGB(235, 240, 255),
	[1] = Color3.fromRGB(255, 240, 190),
	[2] = Color3.fromRGB(255, 210, 90),
	[3] = Color3.fromRGB(235, 25, 50),
}

local swingRigs: { SwingRig } = {}
local swings: { Swing } = {}

local function getSwingRig(): SwingRig
	local rig = table.remove(swingRigs)
	if rig then
		return rig
	end
	local blade = newPart(Enum.PartType.Block, Color3.new(1, 1, 1), Enum.Material.Neon, Vector3.new(0.45, 0.15, 4))
	local tip = newPart(Enum.PartType.Ball, Color3.new(1, 1, 1), Enum.Material.Neon, Vector3.one)
	local a0 = Instance.new("Attachment")
	a0.Parent = blade
	local a1 = Instance.new("Attachment")
	a1.Parent = blade
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = false
	trail.LightInfluence = 0
	trail.MinLength = 0.02
	trail.WidthScale = NumberSequence.new(1, 0.55)
	trail.Enabled = false
	trail.Parent = blade
	return { Blade = blade, Tip = tip, Trail = trail, A0 = a0, A1 = a1 }
end

local function slash(x: number, z: number, yaw: number, reach: number, sweep: number, tier: number, userId: number)
	if type(userId) ~= "number" or type(reach) ~= "number" then
		return
	end
	tier = math.clamp(tier or 0, 0, 3)
	sweep = sweep < 0 and -1 or 1
	local rig = getSwingRig()
	local color = SWING_COLORS[tier]
	local len = math.max(1, reach - SWING_INNER)
	local evo = tier == 3
	rig.Blade.Size = Vector3.new(evo and 0.7 or 0.45, 0.15, len)
	rig.Blade.Color = color
	rig.Blade.Transparency = 0.6
	rig.Tip.Size = Vector3.one * (0.9 + tier * 0.3)
	rig.Tip.Color = color:Lerp(Color3.new(1, 1, 1), 0.5)
	rig.Tip.Transparency = 1
	rig.A0.Position = Vector3.new(0, 0, len / 2)
	rig.A1.Position = Vector3.new(0, 0, -len / 2)
	local life = 0.2 + tier * 0.03
	rig.Trail.Lifetime = life
	rig.Trail.Color = ColorSequence.new(Color3.new(1, 1, 1), color)
	rig.Trail.LightEmission = 0.7 + tier * 0.1
	rig.Trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, math.max(0, 0.25 - tier * 0.08)),
		NumberSequenceKeypoint.new(0.6, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	local root = characterRoot(userId)
	table.insert(swings, {
		Rig = rig,
		Root = root,
		X = x,
		Z = z,
		Yaw = yaw,
		Reach = reach,
		Sweep = sweep,
		Tier = tier,
		Start = os.clock(),
		Trailing = false,
		Life = life,
	})
	-- attack pose: a back swing (behind the player's facing) becomes a spin slash
	local back = false
	if root then
		local look = root.CFrame.LookVector
		local dir = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
		back = look.X * dir.X + look.Z * dir.Z < 0
	end
	startPose(userId, "Swing", sweep, back, SWING_ARC / 2)
end

-- Relative blade angle (radians from the swing direction) at time t since the swing began.
local function swingAngle(sweep: number, t: number): number
	local half = SWING_ARC / 2
	local from = sweep * (half + SWING_PULL)
	if t < SWING_WINDUP then
		return sweep * half + sweep * SWING_PULL * easeOut(t / SWING_WINDUP)
	end
	return from + (-sweep * half - from) * easeOut((t - SWING_WINDUP) / SWING_SWEEP)
end

local function renderSwings()
	local now = os.clock()
	for i = #swings, 1, -1 do
		local sw = swings[i]
		local rig = sw.Rig
		local t = now - sw.Start
		local root = sw.Root
		if root and root.Parent then
			sw.X, sw.Z = root.Position.X, root.Position.Z
		end
		local swingEnd = SWING_WINDUP + SWING_SWEEP
		if t >= swingEnd + SWING_FADE + sw.Life then
			-- done: park and recycle
			rig.Trail.Enabled = false
			rig.Blade.CFrame = PARK
			rig.Tip.CFrame = PARK
			rig.Trail:Clear()
			swings[i] = swings[#swings]
			swings[#swings] = nil
			table.insert(swingRigs, rig)
		else
			local a = swingAngle(sw.Sweep, math.min(t, swingEnd))
			local len = rig.Blade.Size.Z
			local pivot = CFrame.new(sw.X, FLOOR_Y + SWING_HEIGHT, sw.Z) * CFrame.Angles(0, sw.Yaw + a, 0)
			rig.Blade.CFrame = pivot * CFrame.new(0, 0, -(SWING_INNER + len / 2))
			if t >= SWING_WINDUP and not sw.Trailing and t < swingEnd then
				-- the sweep starts: trail on from where the blade is now
				sw.Trailing = true
				rig.Trail:Clear()
				rig.Trail.Enabled = true
			end
			if t < SWING_WINDUP then
				rig.Blade.Transparency = 0.6
				rig.Tip.Transparency = 1
			elseif t < swingEnd then
				local u = (t - SWING_WINDUP) / SWING_SWEEP
				-- hit flash: the blade goes white while the damage lands
				rig.Blade.Color = (u > 0.3 and u < 0.6) and Color3.new(1, 1, 1) or SWING_COLORS[sw.Tier]
				rig.Blade.Transparency = 0
				rig.Tip.Transparency = 0.15
				rig.Tip.CFrame = pivot * CFrame.new(0, 0, -(SWING_INNER + len))
			else
				if rig.Trail.Enabled then
					rig.Trail.Enabled = false
				end
				local f = math.clamp((t - swingEnd) / SWING_FADE, 0, 1)
				rig.Blade.Color = SWING_COLORS[sw.Tier]
				rig.Blade.Transparency = f
				rig.Tip.Transparency = 0.15 + 0.85 * f
				rig.Tip.CFrame = pivot * CFrame.new(0, 0, -(SWING_INNER + len))
			end
		end
	end
end

-- Jagged bolt from a to b: `segments` neon blocks with random kinks.
local function zigzag(a: Vector3, b: Vector3, segments: number, jitter: number, width: number, color: Color3, seconds: number)
	local prev = a
	for i = 1, segments do
		local nextPos = a:Lerp(b, i / segments)
		if i < segments then
			nextPos += Vector3.new((math.random() - 0.5) * jitter, (math.random() - 0.5) * jitter * 0.5, (math.random() - 0.5) * jitter)
		end
		local len = (nextPos - prev).Magnitude
		if len > 0.05 then
			local p = getEffectPart("Block")
			p.Color = color
			p.Size = Vector3.new(width, width, len)
			p.CFrame = CFrame.lookAt((prev + nextPos) / 2, nextPos)
			play("Block", p, seconds, { Transparency = 1, Size = Vector3.new(width * 0.2, width * 0.2, len) })
		end
		prev = nextPos
	end
end

local function bolt(x, z, radius, tier)
	tier = tier or 0
	local color = tier == 3 and Color3.fromRGB(190, 240, 255) or Color3.fromRGB(255, 250, 150)
	local ground = Vector3.new(x, FLOOR_Y + 0.3, z)
	zigzag(ground + Vector3.new(math.random(-3, 3), 26, math.random(-3, 3)), ground, 4, 3, 0.5 + tier * 0.15, color, 0.22)
	-- impact flash + scorch ring
	local glow = getEffectPart("Ball")
	glow.Color = color
	glow.Size = Vector3.one * radius
	glow.Transparency = 0.1
	glow.CFrame = CFrame.new(x, FLOOR_Y + 0.6, z)
	play("Ball", glow, 0.18, { Size = Vector3.one * radius * 2, Transparency = 1 })
	local ringPart = getEffectPart("Cylinder")
	ringPart.Color = Color3.fromRGB(255, 240, 90)
	ringPart.Size = Vector3.new(0.2, radius * 1.2, radius * 1.2)
	ringPart.Transparency = 0.3
	ringPart.CFrame = CFrame.new(x, FLOOR_Y + 0.15, z) * DISC
	play("Cylinder", ringPart, 0.3, { Transparency = 1, Size = Vector3.new(0.2, radius * 2.2, radius * 2.2) })
end

local function chain(x1, z1, x2, z2)
	local a = Vector3.new(x1, FLOOR_Y + 2, z1)
	local b = Vector3.new(x2, FLOOR_Y + 2, z2)
	if (b - a).Magnitude < 0.1 then
		return
	end
	zigzag(a, b, 3, 1.6, 0.35, Color3.fromRGB(200, 240, 255), 0.2)
end

-- Holy water pool: grows in, ripples while it burns, then fades.
local function pool(x, z, radius, seconds, evo)
	local color = evo and Color3.fromRGB(255, 110, 30) or Color3.fromRGB(70, 150, 255)
	local p = getEffectPart("Cylinder")
	p.Color = color
	p.Size = Vector3.new(0.25, 0.5, 0.5)
	p.Transparency = 0.35
	p.CFrame = CFrame.new(x, FLOOR_Y + 0.12, z) * DISC
	TweenService:Create(p, TweenInfo.new(0.15), { Size = Vector3.new(0.25, radius * 2, radius * 2) }):Play()
	local ripple = getEffectPart("Cylinder")
	ripple.Color = color:Lerp(Color3.new(1, 1, 1), evo and 0.3 or 0.5)
	ripple.Size = Vector3.new(0.3, radius * 0.4, radius * 0.4)
	ripple.Transparency = 0.4
	ripple.CFrame = CFrame.new(x, FLOOR_Y + 0.16, z) * DISC
	local rippleTween = TweenService:Create(ripple, TweenInfo.new(evo and 0.5 or 0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, -1), { Size = Vector3.new(0.3, radius * 2, radius * 2), Transparency = 1 })
	rippleTween:Play()
	task.delay(math.max(0.1, seconds - 0.3), function()
		rippleTween:Cancel()
		releaseEffectPart("Cylinder", ripple)
		play("Cylinder", p, 0.3, { Transparency = 1 })
	end)
end

-- Glass shards + splash where a bottle lands.
local function shatter(pos: Vector3, color: Color3)
	local ground = Vector3.new(pos.X, FLOOR_Y + 0.6, pos.Z)
	for i = 1, 4 do
		local a = i * math.pi / 2 + math.random() * 0.8
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		local shard = getEffectPart("Block")
		shard.Color = color:Lerp(Color3.new(1, 1, 1), 0.4)
		shard.Size = Vector3.new(0.3, 0.15, 0.55)
		shard.Transparency = 0.1
		shard.CFrame = CFrame.lookAt(ground, ground + out)
		local to = ground + out * (2 + math.random() * 1.5) + Vector3.new(0, -0.4, 0)
		play("Block", shard, 0.3, { CFrame = CFrame.lookAt(to, to + out) * CFrame.Angles(math.random() * 3, 0, 0), Transparency = 1 })
	end
	local splash = getEffectPart("Ball")
	splash.Color = color
	splash.Size = Vector3.new(1.5, 0.8, 1.5)
	splash.Transparency = 0.2
	splash.CFrame = CFrame.new(ground)
	play("Ball", splash, 0.25, { Size = Vector3.new(5, 0.2, 5), Transparency = 1 })
end

-- Puff / shatter where a projectile disappears (hit, expiry or landing). Budgeted per frame.
projectileImpact = function(e: Entry)
	if impactBudget <= 0 then
		return
	end
	local def = e.Def
	if def.Shatter then
		impactBudget -= 1
		shatter(e.Drawn, def.Color)
	elseif def.Impact then
		impactBudget -= 1
		local size = 1 + e.Tier * 0.25
		local p = getEffectPart("Ball")
		p.Color = def.Impact
		p.Size = Vector3.one * size
		p.Transparency = 0.25
		p.CFrame = CFrame.new(e.Drawn)
		play("Ball", p, 0.18, { Size = Vector3.one * size * 2.6, Transparency = 1 })
	end
end

local function explosion(x, z, radius)
	local p = getEffectPart("Ball")
	p.Color = Color3.fromRGB(255, 140, 40)
	p.Size = Vector3.one * 2
	p.Transparency = 0.1
	p.CFrame = CFrame.new(x, FLOOR_Y + 1, z)
	play("Ball", p, 0.35, { Size = Vector3.one * radius * 2, Transparency = 1 })
	local root = player.Character and player.Character.PrimaryPart
	if root and (root.Position - Vector3.new(x, root.Position.Y, z)).Magnitude < radius + 25 then
		CameraController.Shake(0.8)
	end
end

local function ring(x, z, radius, color)
	local p = getEffectPart("Cylinder")
	p.Color = color
	p.Size = Vector3.new(0.3, 1, 1)
	p.Transparency = 0.2
	p.CFrame = CFrame.new(x, FLOOR_Y + 0.3, z) * DISC
	play("Cylinder", p, 0.5, { Size = Vector3.new(0.3, radius * 2, radius * 2), Transparency = 1 })
end

local function telegraph(x, z, yaw, length, width, seconds)
	local p = getEffectPart("Block")
	p.Color = Color3.fromRGB(255, 40, 40)
	p.Size = Vector3.new(width, 0.1, length)
	p.Transparency = 0.6
	p.CFrame = CFrame.new(x, FLOOR_Y + 0.1, z) * CFrame.Angles(0, yaw, 0)
	play("Block", p, seconds, { Transparency = 0.95 }, Enum.EasingStyle.Linear)
end

local function playerEvent(userId: number, kind: string)
	local root = characterRoot(userId)
	local isLocal = userId == player.UserId
	if kind == "hurt" then
		if isLocal then
			CameraController.Shake(0.35)
			Audio.Play("Hit", 0.7)
		end
	elseif kind == "heal" and root then
		ring(root.Position.X, root.Position.Z, 5, Color3.fromRGB(90, 255, 120))
	elseif kind == "levelup" and root then
		ring(root.Position.X, root.Position.Z, 8, Color3.fromRGB(255, 220, 80))
		if isLocal then
			Audio.Play("LevelUp")
		end
	elseif kind == "die" then
		if root then
			deathPoof(root.Position.X, root.Position.Z, Color3.fromRGB(200, 200, 220), 5)
		end
		if isLocal then
			Audio.Play("Death")
		end
	elseif kind == "revive" and root then
		ring(root.Position.X, root.Position.Z, 12, Color3.fromRGB(255, 240, 150))
	end
	if isLocal and onLocalEvent then
		onLocalEvent(kind)
	end
end

local function onFxBatch(batch)
	if type(batch) ~= "table" then
		return
	end
	if batch.h then
		for _, id in ipairs(batch.h) do
			flash(id)
		end
		Audio.Play("Hit")
	end
	if batch.d then
		for _, d in ipairs(batch.d) do
			deathPoof(d[1], d[2], d[3], d[4])
		end
	end
	if batch.s then
		for _, s in ipairs(batch.s) do
			slash(s[1], s[2], s[3], s[4], s[5], s[6], s[7])
		end
	end
	if batch.b then
		for _, b in ipairs(batch.b) do
			bolt(b[1], b[2], b[3], b[4])
		end
	end
	if batch.c then
		for _, c in ipairs(batch.c) do
			chain(c[1], c[2], c[3], c[4])
		end
	end
	if batch.p then
		for _, p in ipairs(batch.p) do
			pool(p[1], p[2], p[3], p[4], p[5])
		end
	end
	if batch.e then
		for _, e in ipairs(batch.e) do
			explosion(e[1], e[2], e[3])
		end
	end
	if batch.r then
		for _, r in ipairs(batch.r) do
			ring(r[1], r[2], r[3], r[4])
		end
	end
	if batch.t then
		for _, t in ipairs(batch.t) do
			telegraph(t[1], t[2], t[3], t[4], t[5], t[6])
		end
	end
	if batch.u then
		for _, u in ipairs(batch.u) do
			playerEvent(u[1], u[2])
		end
	end
	if batch.n then
		for _, name in ipairs(batch.n) do
			Audio.Play(name)
			if name == "BossRoar" then
				CameraController.Shake(1.2)
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Gems (local bob / spin)
------------------------------------------------------------------------------------------

local gemState: { [BasePart]: Vector3 } = {} -- active gem → server base position
local gemParts: { BasePart } = {}
local gemCFrames: { CFrame } = {}

local crystals: { [BasePart]: { Pieces: { any }, Scale: number, Color: Color3 } } = {}
local crystalFor: (BasePart) -> any

local function trackGem(gem: Instance)
	if not gem:IsA("BasePart") then
		return
	end
	local part = gem :: BasePart
	local function refresh()
		local active = part:GetAttribute("Active") == true
		local base = part:GetAttribute("Base")
		if active and typeof(base) == "Vector3" then
			gemState[part] = base
		else
			local last = gemState[part]
			gemState[part] = nil
			local c = crystals[part]
			if c then
				for _, piece in ipairs(c.Pieces) do
					piece.Part.CFrame = PARK
				end
			end
			-- collected near me → pickup sound
			local root = player.Character and player.Character.PrimaryPart
			if last and root and (root.Position - last).Magnitude < 8 then
				Audio.Play("GemPickup")
			end
		end
	end
	part:GetAttributeChangedSignal("Active"):Connect(refresh)
	part:GetAttributeChangedSignal("Base"):Connect(refresh)
	refresh()
end

local gemClock = 0

-- One crystal mesh per pooled gem part, rebuilt when the gem's size or colour changes.
crystalFor = function(part: BasePart)
	local c = crystals[part]
	local scale = part.Size.X / 0.75
	if c and (math.abs(c.Scale - scale) > 0.01 or c.Color ~= part.Color) then
		for _, piece in ipairs(c.Pieces) do
			piece.Part:Destroy()
		end
		c = nil
	end
	if not c then
		local pieces = ModelLibrary.MeshPieces("Crystal", { Glow = part.Color, Light = part.Color:Lerp(Color3.new(1, 1, 1), 0.6) }, scale, 0)
		if not pieces then
			return nil
		end
		c = { Pieces = pieces, Scale = scale, Color = part.Color }
		crystals[part] = c
	end
	return c
end
local GEM_TILT = CFrame.Angles(math.rad(45), 0, math.rad(35.26))

-- Floor pickups bob and spin; chests just glow-pulse.
local pickupBases: { [Model]: CFrame } = {}
local function trackPickup(m: Instance)
	if m:IsA("Model") then
		task.defer(function()
			if m.Parent then
				pickupBases[m] = m:GetPivot()
			end
		end)
	end
end
local function renderPickups()
	for m, base in pairs(pickupBases) do
		if not m.Parent then
			pickupBases[m] = nil
		elseif m.Name == "Chest" then
			local box = m.PrimaryPart
			local light = box and box:FindFirstChildOfClass("PointLight")
			if light then
				light.Brightness = 1.5 + math.sin(gemClock * 4) * 1
			end
		else
			m:PivotTo(base * CFrame.new(0, 0.5 + math.sin(gemClock * 3) * 0.35, 0) * CFrame.Angles(0, gemClock * 2, 0))
		end
	end
end
local function renderGems(dt: number)
	gemClock += dt
	table.clear(gemParts)
	table.clear(gemCFrames)
	local n = 0
	local useMesh = ModelLibrary.MeshFolder("Crystal") ~= nil
	for part, base in pairs(gemState) do
		local phase = base.X * 0.37 + base.Z * 0.21
		local bob = Vector3.new(0, math.sin(gemClock * 3 + phase) * 0.3, 0)
		local spin = CFrame.Angles(0, gemClock * 2 + phase, 0)
		local crystal = useMesh and crystalFor(part) or nil
		if crystal then
			-- uploaded crystal mesh drawn in place of the plain server cube
			part.LocalTransparencyModifier = 1
			local s = crystal.Scale
			local cf = CFrame.new(base + bob - Vector3.new(0, 0.65 * s, 0)) * spin
			for _, piece in ipairs(crystal.Pieces) do
				n += 1
				gemParts[n] = piece.Part
				gemCFrames[n] = cf * piece.Offset
			end
		else
			n += 1
			gemParts[n] = part
			-- cube stood on its corner = diamond-shaped crystal
			gemCFrames[n] = CFrame.new(base + bob) * spin * GEM_TILT
		end
	end
	if n > 0 then
		workspace:BulkMoveTo(gemParts, gemCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

------------------------------------------------------------------------------------------
-- Player decorations: aura rings, HP bars, limb swing
------------------------------------------------------------------------------------------

type Deco = { Ring: Part?, AuraFill: Part?, Pulse: Part?, Motes: { Part }?, Bar: BillboardGui?, Fill: Frame?, Character: Model? }
local AURA_MOTES = 6
local decos: { [Player]: Deco } = {}

local function buildBar(char: Model): (BillboardGui, Frame)
	local gui = Instance.new("BillboardGui")
	gui.Name = "SwarmHP"
	gui.Size = UDim2.fromOffset(60, 8)
	gui.StudsOffset = Vector3.new(0, 4.2, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Adornee = char:FindFirstChild("HumanoidRootPart") :: BasePart
	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = Color3.fromRGB(30, 10, 10)
	back.BorderSizePixel = 0
	back.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 3)
	corner.Parent = back
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(80, 230, 90)
	fill.BorderSizePixel = 0
	fill.Parent = back
	local c2 = Instance.new("UICorner")
	c2.CornerRadius = UDim.new(0, 3)
	c2.Parent = fill
	gui.Parent = fxFolder
	return gui, fill
end

local function updateDecos(_dt: number)
	local t = os.clock()
	for _, other in ipairs(Players:GetPlayers()) do
		local deco = decos[other]
		if not deco then
			deco = {}
			decos[other] = deco
		end
		local char = other.Character
		local root = char and char.PrimaryPart
		local inRun = other:GetAttribute("InRun") == true

		-- HP bar
		if deco.Character ~= char then
			if deco.Bar then
				deco.Bar:Destroy()
				deco.Bar = nil
			end
			deco.Character = char
		end
		if inRun and char and root then
			if not deco.Bar then
				deco.Bar, deco.Fill = buildBar(char)
			end
			local hp = other:GetAttribute("HP") or 0
			local maxHp = math.max(1, other:GetAttribute("MaxHP") or 1)
			local frac = math.clamp(hp / maxHp, 0, 1)
			local fill = deco.Fill :: Frame
			fill.Size = UDim2.fromScale(frac, 1)
			fill.BackgroundColor3 = frac > 0.5 and Color3.fromRGB(80, 230, 90) or (frac > 0.25 and Color3.fromRGB(255, 200, 60) or Color3.fromRGB(255, 70, 70))
			local bar = deco.Bar :: BillboardGui
			bar.Enabled = other:GetAttribute("Alive") ~= false
		elseif deco.Bar then
			deco.Bar.Enabled = false
		end

		-- Garlic aura: rim ring, faint fill, a pulse wave each second and orbiting motes.
		-- Soul Eater (evolved) turns purple and its motes spiral inward like pulled souls.
		local radius = other:GetAttribute("AuraRadius") or 0
		if inRun and root and radius > 0 and other:GetAttribute("Alive") ~= false then
			if not deco.Ring then
				deco.Ring = newPart(Enum.PartType.Cylinder, Color3.fromRGB(240, 240, 190), Enum.Material.Neon, Vector3.one)
				deco.AuraFill = newPart(Enum.PartType.Cylinder, Color3.fromRGB(240, 240, 190), Enum.Material.Neon, Vector3.one)
				deco.Pulse = newPart(Enum.PartType.Cylinder, Color3.fromRGB(240, 240, 190), Enum.Material.Neon, Vector3.one)
				local motes = {}
				for i = 1, AURA_MOTES do
					motes[i] = newPart(Enum.PartType.Ball, Color3.fromRGB(240, 240, 190), Enum.Material.Neon, Vector3.one * 0.5)
				end
				deco.Motes = motes
			end
			local evo = other:GetAttribute("AuraEvo") == true
			local color = evo and Color3.fromRGB(200, 90, 255) or Color3.fromRGB(240, 240, 190)
			local cx, cz = root.Position.X, root.Position.Z
			local ringPart = deco.Ring :: Part
			ringPart.Color = color
			local pulse = 1 + math.sin(t * 4) * 0.03
			ringPart.Size = Vector3.new(0.15, radius * 2 * pulse, radius * 2 * pulse)
			ringPart.Transparency = 0.8
			ringPart.CFrame = CFrame.new(cx, FLOOR_Y + 0.2, cz) * DISC
			local fill = deco.AuraFill :: Part
			fill.Color = color
			fill.Size = Vector3.new(0.1, radius * 2, radius * 2)
			fill.Transparency = 0.93
			fill.CFrame = CFrame.new(cx, FLOOR_Y + 0.17, cz) * DISC
			-- pulse wave: inward for Soul Eater, outward for Garlic
			local k = (t * (evo and 1.4 or 1)) % 1
			local waveR = evo and radius * (1 - k * 0.8) or radius * (0.25 + 0.75 * k)
			local wave = deco.Pulse :: Part
			wave.Color = color
			wave.Size = Vector3.new(0.12, waveR * 2, waveR * 2)
			wave.Transparency = 0.6 + 0.4 * (evo and (1 - k) or k)
			wave.CFrame = CFrame.new(cx, FLOOR_Y + 0.22, cz) * DISC
			local motes = deco.Motes :: { Part }
			local shown = evo and AURA_MOTES or AURA_MOTES // 2
			for i, mote in ipairs(motes) do
				if i <= shown then
					local a = t * (evo and 2.4 or 1.2) + i * math.pi * 2 / shown
					local r = radius * 0.85
					if evo then
						r = radius * (1 - ((t * 0.7 + i / shown) % 1) * 0.85)
					end
					mote.Color = color
					mote.Transparency = 0.25
					mote.CFrame = CFrame.new(cx + math.cos(a) * r, FLOOR_Y + 1 + math.sin(t * 3 + i) * 0.4, cz + math.sin(a) * r)
				else
					mote.CFrame = PARK
				end
			end
		elseif deco.Ring then
			deco.Ring.CFrame = PARK
			if deco.AuraFill then
				deco.AuraFill.CFrame = PARK
			end
			if deco.Pulse then
				deco.Pulse.CFrame = PARK
			end
			for _, mote in ipairs(deco.Motes or {}) do
				mote.CFrame = PARK
			end
		end
	end
	for other, deco in pairs(decos) do
		if not other.Parent then
			for _, part in ipairs({ deco.Ring, deco.AuraFill, deco.Pulse } :: { Part? }) do
				if part then
					part:Destroy()
				end
			end
			for _, mote in ipairs(deco.Motes or {}) do
				mote:Destroy()
			end
			if deco.Bar then
				deco.Bar:Destroy()
			end
			decos[other] = nil
			poses[other.UserId] = nil
		end
	end
end

--[[
	Procedural walk cycle: swing arms/legs from the root's speed (no animation assets),
	plus the attack poses started by startPose:
	  Swing  right arm raised forward and swept across with the blade; a swing behind
	         the player turns into a quick full-body spin slash (RootJoint)
	  Throw  right arm cocks back over the head, then snaps forward
	  Cast   right arm points forward briefly
	Each pose blends back into the walk cycle over POSE_RECOVER seconds.
]]
local swingClock = 0
local function setMotor(torso: Instance, name: string, cf: CFrame)
	local m = torso:FindFirstChild(name)
	if m and m:IsA("Motor6D") then
		m.Transform = cf
	end
end

-- Arm transform (and body spin) for a pose at time t; nil when the pose is over.
local function poseTransform(pose: Pose, t: number): (CFrame?, number, number)
	local length, armCF, spin = 0, CFrame.identity, 0
	if pose.Kind == "Swing" then
		length = SWING_WINDUP + SWING_SWEEP
		local tt = math.min(t, length)
		local half = pose.Half
		local s = pose.Sweep
		local yawA
		if tt < SWING_WINDUP then
			yawA = s * (0.5 + 0.6 * easeOut(tt / SWING_WINDUP))
		else
			yawA = s * 1.1 - s * 2.3 * easeOut((tt - SWING_WINDUP) / SWING_SWEEP)
		end
		yawA = math.clamp(yawA, -half, half)
		if pose.Back then
			yawA = -1.0 -- arm held out to the side while the body spins
		end
		armCF = CFrame.Angles(0, yawA, 0) * CFrame.Angles(1.45, 0, 0)
		if pose.Back and tt >= SWING_WINDUP then
			-- a full turn over the sweep and the recovery
			spin = s * math.pi * 2 * easeOut((t - SWING_WINDUP) / (SWING_SWEEP + POSE_RECOVER))
		end
	elseif pose.Kind == "Throw" then
		length = THROW_TIME
		local u = math.min(t, length) / length
		local pitch = u < 0.4 and 3.3 * easeOut(u / 0.4) or 3.3 - 2.3 * easeOut((u - 0.4) / 0.6)
		armCF = CFrame.Angles(pitch, 0, 0)
	else
		length = CAST_TIME
		armCF = CFrame.Angles(1.5 * easeOut(math.min(t, length) / (length * 0.4)), 0, 0)
	end
	if t > length + POSE_RECOVER then
		return nil, 0, 0
	end
	local w = t <= length and 1 or 1 - (t - length) / POSE_RECOVER
	if pose.Back and pose.Kind == "Swing" and t > length then
		w = 1 -- keep the spin going until it has turned all the way round
	end
	return armCF, w, spin
end

local function animateLimbs(dt: number)
	swingClock += dt
	local now = os.clock()
	for _, other in ipairs(Players:GetPlayers()) do
		local char = other.Character
		local root = char and char.PrimaryPart
		local torso = char and char:FindFirstChild("Torso")
		if root and torso then
			local speed = (root.AssemblyLinearVelocity * Vector3.new(1, 0, 1)).Magnitude
			local amount = math.clamp(speed / 16, 0, 1) * 0.8
			local swing = math.sin(swingClock * 10) * amount
			local rightArm = CFrame.Angles(-swing, 0, 0)
			local spin = 0
			local pose = poses[other.UserId]
			if pose then
				local armCF, w, bodySpin = poseTransform(pose, now - pose.Start)
				if armCF then
					rightArm = rightArm:Lerp(armCF, w)
					spin = bodySpin
				else
					poses[other.UserId] = nil
				end
			end
			setMotor(torso, "Left Shoulder", CFrame.Angles(swing, 0, 0))
			setMotor(torso, "Right Shoulder", rightArm)
			setMotor(torso, "Left Hip", CFrame.Angles(-swing, 0, 0))
			setMotor(torso, "Right Hip", CFrame.Angles(swing, 0, 0))
			-- RootJoint lives on the HumanoidRootPart; only touched for the spin slash
			local rootJoint = root:FindFirstChild("RootJoint")
			if rootJoint and rootJoint:IsA("Motor6D") then
				rootJoint.Transform = spin ~= 0 and CFrame.Angles(0, spin, 0) or CFrame.identity
			end
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

	Remotes.Get("ProjectileBatch").OnClientEvent:Connect(onProjectileBatch)
	Remotes.Get("FxBatch").OnClientEvent:Connect(onFxBatch)

	task.spawn(function()
		local pickups = workspace:WaitForChild("SwarmPickups")
		pickups.ChildAdded:Connect(trackPickup)
		for _, m in ipairs(pickups:GetChildren()) do
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
		renderProjectiles(dt)
		renderSwings()
		renderPickups()
		renderGems(dt)
		updateFlashes()
		updateDecos(dt)
	end)
	RunService.PreSimulation:Connect(animateLimbs)
end

return VFX
