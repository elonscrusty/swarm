--[[
	ModelLibrary.lua
	Detailed, animated 3D models built from Parts and built-in shapes, drawn only on the
	client. The server still moves one invisible-to-you hit body per enemy (cheap to
	replicate); EnemyRenderer hangs these models on those bodies every frame.

	A model is a list of pieces. Each piece:
	  Part     the local Part
	  Offset   CFrame relative to the body centre (forward = -Z)
	  Anim     optional animation key (see ModelLibrary.Animate)
	  Pivot    joint offset for swinging pieces (rotation happens around Offset * Pivot)
	  Color    the piece's own colour (restored after hit flashes)

	Enemies:  ModelLibrary.Enemy(typeId, elite) → pieces, motion style
	Shots:    ModelLibrary.Projectile(visualIndex) → pieces
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local EnemyData = require(Shared:WaitForChild("EnemyData"))
local Config = require(Shared:WaitForChild("Config"))

local ModelLibrary = {}

export type Piece = { Part: BasePart, Offset: CFrame, Anim: string?, Pivot: CFrame?, Color: Color3 }

local GOLD = Color3.fromRGB(255, 205, 60)
local BLACK = Color3.fromRGB(20, 20, 25)
local WHITE = Color3.fromRGB(245, 245, 245)

local folder: Instance? = nil

function ModelLibrary.SetFolder(f: Instance)
	folder = f
end

-- Creates one local part. shape: "Ball" | "Block" | "Cylinder" | "Wedge" | "Corner"
local function makePart(shape: string, size: Vector3, color: Color3, material: Enum.Material?, transparency: number?): BasePart
	local p: BasePart
	if shape == "Wedge" then
		p = Instance.new("WedgePart")
	elseif shape == "Corner" then
		p = Instance.new("CornerWedgePart")
	else
		local part = Instance.new("Part")
		part.Shape = (Enum.PartType :: any)[shape]
		p = part
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.CFrame = CFrame.new(0, -150, 0)
	p.Parent = folder
	return p
end

-- Builder: collects pieces scaled by `s` (elites are bigger).
local function builder(s: number)
	local pieces: { Piece } = {}
	local b = {}
	function b.add(shape: string, size: Vector3, color: Color3, offset: CFrame, opts: { [string]: any }?): BasePart
		local o = opts or {}
		local scaledOffset = CFrame.new(offset.Position * s) * offset.Rotation
		local part = makePart(shape, size * s, color, o.Material, o.Transparency)
		local pivot = o.Pivot and CFrame.new(o.Pivot.Position * s) * o.Pivot.Rotation or nil
		table.insert(pieces, { Part = part, Offset = scaledOffset, Anim = o.Anim, Pivot = pivot, Color = color })
		return part
	end
	b.pieces = pieces
	return b
end

local CYL_UP = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X → Y

------------------------------------------------------------------------------------------
-- ENEMIES
------------------------------------------------------------------------------------------

local ENEMIES: { [string]: (any, Color3, Color3) -> string } = {}

-- Slime: wobbly translucent blob with a dark core, big eyes and a little crown of goo.
ENEMIES.Slime = function(b, base, dark)
	b.add("Ball", Vector3.new(2.8, 2.1, 2.8), base, CFrame.new(0, -0.05, 0), { Material = Enum.Material.Glass, Transparency = 0.2 })
	b.add("Ball", Vector3.new(1.4, 1.1, 1.4), dark, CFrame.new(0, -0.2, 0.2), { Transparency = 0.1 })
	b.add("Ball", Vector3.new(1.1, 0.5, 1.1), base, CFrame.new(0.2, 0.95, 0.1), { Material = Enum.Material.Glass, Transparency = 0.2 })
	for _, x in ipairs({ -0.5, 0.5 }) do
		b.add("Ball", Vector3.new(0.6, 0.7, 0.3), WHITE, CFrame.new(x, 0.3, -1.2))
		b.add("Ball", Vector3.new(0.3, 0.4, 0.2), BLACK, CFrame.new(x, 0.28, -1.33))
	end
	b.add("Block", Vector3.new(0.6, 0.12, 0.1), BLACK, CFrame.new(0, -0.2, -1.32))
	return "Hop"
end

-- Bat: round body, pointy ears, red eyes, two flapping wings with finger struts.
ENEMIES.Bat = function(b, base, dark)
	b.add("Ball", Vector3.new(1.1, 1.0, 1.3), base, CFrame.new(0, 0, 0))
	b.add("Ball", Vector3.new(0.8, 0.75, 0.75), base, CFrame.new(0, 0.2, -0.7))
	for _, x in ipairs({ -0.25, 0.25 }) do
		b.add("Wedge", Vector3.new(0.15, 0.45, 0.3), dark, CFrame.new(x, 0.7, -0.7))
		b.add("Ball", Vector3.new(0.18, 0.18, 0.12), Color3.fromRGB(255, 40, 40), CFrame.new(x * 0.8, 0.28, -1.05), { Material = Enum.Material.Neon })
	end
	b.add("Wedge", Vector3.new(0.1, 0.18, 0.1), WHITE, CFrame.new(-0.12, 0.0, -1.05) * CFrame.Angles(math.rad(180), 0, 0))
	b.add("Wedge", Vector3.new(0.1, 0.18, 0.1), WHITE, CFrame.new(0.12, 0.0, -1.05) * CFrame.Angles(math.rad(180), 0, 0))
	for _, side in ipairs({ -1, 1 }) do
		local anim = side < 0 and "FlapL" or "FlapR"
		local pivot = CFrame.new(-side * 0.75, 0, 0) -- hinge at the body edge
		b.add("Block", Vector3.new(1.5, 0.08, 1.0), dark, CFrame.new(side * 1.25, 0.1, 0), { Anim = anim, Pivot = pivot })
		b.add("Block", Vector3.new(1.6, 0.14, 0.12), base, CFrame.new(side * 1.25, 0.15, -0.45), { Anim = anim, Pivot = pivot })
		b.add("Wedge", Vector3.new(0.08, 0.5, 0.9), dark, CFrame.new(side * 2.05, 0.1, 0.05) * CFrame.Angles(0, 0, math.rad(side * 90)), { Anim = anim, Pivot = CFrame.new(-side * 1.55, 0, 0) })
	end
	return "Fly"
end

-- Skeleton: skull with sockets, ribcage, spine, pelvis, swinging bone arms and legs.
ENEMIES.Skeleton = function(b, base, dark)
	local bone = base
	b.add("Block", Vector3.new(1.1, 1.0, 1.0), bone, CFrame.new(0, 1.55, -0.05))
	b.add("Block", Vector3.new(0.8, 0.3, 0.7), bone, CFrame.new(0, 1.0, -0.15))
	for _, x in ipairs({ -0.25, 0.25 }) do
		b.add("Block", Vector3.new(0.28, 0.3, 0.1), BLACK, CFrame.new(x, 1.6, -0.56))
		b.add("Ball", Vector3.new(0.1, 0.1, 0.05), Color3.fromRGB(255, 80, 60), CFrame.new(x, 1.6, -0.6), { Material = Enum.Material.Neon })
	end
	b.add("Block", Vector3.new(0.12, 0.25, 0.1), BLACK, CFrame.new(0, 1.35, -0.56))
	b.add("Block", Vector3.new(0.25, 2.0, 0.25), dark, CFrame.new(0, 0.2, 0.1))
	for i = 0, 3 do
		b.add("Block", Vector3.new(1.4 - i * 0.12, 0.12, 0.7), bone, CFrame.new(0, 0.75 - i * 0.3, -0.05))
	end
	b.add("Block", Vector3.new(1.0, 0.35, 0.55), bone, CFrame.new(0, -0.6, 0))
	for _, side in ipairs({ -1, 1 }) do
		local armAnim = side < 0 and "SwingA" or "SwingB"
		local legAnim = side < 0 and "SwingB" or "SwingA"
		b.add("Block", Vector3.new(0.25, 1.7, 0.25), bone, CFrame.new(side * 0.9, 0.15, 0), { Anim = armAnim, Pivot = CFrame.new(0, 0.85, 0) })
		b.add("Ball", Vector3.new(0.35, 0.35, 0.35), bone, CFrame.new(side * 0.9, -0.75, 0), { Anim = armAnim, Pivot = CFrame.new(0, 1.75, 0) })
		b.add("Block", Vector3.new(0.3, 1.5, 0.3), bone, CFrame.new(side * 0.35, -1.4, 0), { Anim = legAnim, Pivot = CFrame.new(0, 0.75, 0) })
		b.add("Block", Vector3.new(0.35, 0.15, 0.6), bone, CFrame.new(side * 0.35, -2.05, -0.15), { Anim = legAnim, Pivot = CFrame.new(0, 1.4, 0.15) })
	end
	return "Walk"
end

-- Ghost: glowing translucent head with a wavy tail and little arms.
ENEMIES.Ghost = function(b, base, _dark)
	b.add("Ball", Vector3.new(2.6, 2.4, 2.4), base, CFrame.new(0, 0.4, 0), { Material = Enum.Material.Neon, Transparency = 0.45 })
	b.add("Ball", Vector3.new(2.0, 1.8, 1.8), base, CFrame.new(0, -0.6, 0.2), { Material = Enum.Material.Neon, Transparency = 0.5 })
	b.add("Wedge", Vector3.new(1.4, 1.2, 1.6), base, CFrame.new(0, -1.4, 0.6) * CFrame.Angles(math.rad(180), 0, 0), { Material = Enum.Material.Neon, Transparency = 0.55, Anim = "Wiggle", Pivot = CFrame.new(0, 0.6, 0) })
	for _, x in ipairs({ -0.5, 0.5 }) do
		b.add("Ball", Vector3.new(0.45, 0.65, 0.2), BLACK, CFrame.new(x, 0.6, -1.15))
	end
	b.add("Ball", Vector3.new(0.5, 0.35, 0.2), BLACK, CFrame.new(0, 0.0, -1.15))
	for _, side in ipairs({ -1, 1 }) do
		b.add("Ball", Vector3.new(0.6, 0.9, 0.5), base, CFrame.new(side * 1.3, -0.2, -0.3), { Material = Enum.Material.Neon, Transparency = 0.5, Anim = side < 0 and "SwingA" or "SwingB", Pivot = CFrame.new(0, 0.45, 0) })
	end
	return "Float"
end

-- Brute: hulking ogre with a belly, tiny head, horns, tusks, long arms and a spiked club.
ENEMIES.Brute = function(b, base, dark)
	local skin = base
	b.add("Block", Vector3.new(3.6, 2.6, 2.6), skin, CFrame.new(0, 0.5, 0))
	b.add("Ball", Vector3.new(2.8, 2.2, 1.6), skin:Lerp(WHITE, 0.25), CFrame.new(0, 0.1, -0.7))
	b.add("Block", Vector3.new(3.8, 0.5, 2.8), dark, CFrame.new(0, -0.8, 0))
	b.add("Block", Vector3.new(1.4, 1.2, 1.3), skin, CFrame.new(0, 2.3, -0.4))
	for _, x in ipairs({ -0.35, 0.35 }) do
		b.add("Ball", Vector3.new(0.3, 0.3, 0.15), Color3.fromRGB(255, 220, 40), CFrame.new(x, 2.45, -1.07), { Material = Enum.Material.Neon })
		b.add("Wedge", Vector3.new(0.2, 0.4, 0.15), WHITE, CFrame.new(x, 1.85, -1.07))
		b.add("Wedge", Vector3.new(0.3, 0.8, 0.3), Color3.fromRGB(230, 220, 190), CFrame.new(x * 2, 3.1, -0.4) * CFrame.Angles(0, 0, math.rad(x > 0 and -20 or 20)))
	end
	for _, side in ipairs({ -1, 1 }) do
		local armAnim = side < 0 and "SwingA" or "SwingB"
		local legAnim = side < 0 and "SwingB" or "SwingA"
		b.add("Block", Vector3.new(1.0, 2.8, 1.0), skin, CFrame.new(side * 2.3, -0.1, 0), { Anim = armAnim, Pivot = CFrame.new(0, 1.3, 0) })
		b.add("Block", Vector3.new(1.2, 0.9, 1.2), dark, CFrame.new(side * 2.3, -1.6, 0), { Anim = armAnim, Pivot = CFrame.new(0, 2.8, 0) })
		b.add("Block", Vector3.new(1.1, 1.4, 1.1), dark, CFrame.new(side * 0.9, -1.8, 0), { Anim = legAnim, Pivot = CFrame.new(0, 0.7, 0) })
	end
	-- club in the right hand
	b.add("Cylinder", Vector3.new(3.0, 0.5, 0.5), Color3.fromRGB(110, 70, 40), CFrame.new(2.3, -1.6, -1.3) * CFrame.Angles(0, math.rad(90), 0), { Material = Enum.Material.Wood, Anim = "SwingB", Pivot = CFrame.new(0, 2.8, 0) })
	b.add("Ball", Vector3.new(1.2, 1.2, 1.2), Color3.fromRGB(90, 60, 35), CFrame.new(2.3, -1.6, -2.8), { Material = Enum.Material.Wood, Anim = "SwingB", Pivot = CFrame.new(0, 2.8, 1.5) })
	return "Stomp"
end

-- Bomber: round black bomb with a pulsing red band, feet and a sparking fuse.
ENEMIES.Bomber = function(b, base, _dark)
	b.add("Ball", Vector3.new(2.4, 2.4, 2.4), Color3.fromRGB(35, 35, 40), CFrame.new(0, 0, 0), { Material = Enum.Material.Metal })
	b.add("Cylinder", Vector3.new(0.4, 2.45, 2.45), base, CFrame.new(0, 0, 0) * CYL_UP, { Material = Enum.Material.Neon, Anim = "Pulse" })
	b.add("Cylinder", Vector3.new(0.3, 0.6, 0.6), Color3.fromRGB(90, 90, 95), CFrame.new(0, 1.25, 0) * CYL_UP, { Material = Enum.Material.Metal })
	b.add("Block", Vector3.new(0.15, 0.6, 0.15), Color3.fromRGB(160, 130, 90), CFrame.new(0.1, 1.65, 0) * CFrame.Angles(0, 0, math.rad(-15)))
	b.add("Ball", Vector3.new(0.45, 0.45, 0.45), Color3.fromRGB(255, 220, 80), CFrame.new(0.2, 2.0, 0), { Material = Enum.Material.Neon, Anim = "Flicker" })
	for _, x in ipairs({ -0.45, 0.45 }) do
		b.add("Ball", Vector3.new(0.45, 0.55, 0.15), WHITE, CFrame.new(x, 0.35, -1.12))
		b.add("Ball", Vector3.new(0.22, 0.3, 0.1), BLACK, CFrame.new(x, 0.3, -1.2))
		b.add("Ball", Vector3.new(0.7, 0.4, 0.9), Color3.fromRGB(60, 40, 30), CFrame.new(x, -1.2, -0.1), { Anim = x < 0 and "SwingA" or "SwingB", Pivot = CFrame.new(0, 0.3, 0) })
	end
	return "Waddle"
end

-- Boss "Swarm Queen": huge pulsing orb with glowing eyes, a jaw, horns, a spinning crown
-- of spikes, four legs and a halo ring.
ENEMIES.Boss = function(b, base, dark)
	b.add("Ball", Vector3.new(11, 10, 11), base, CFrame.new(0, 0, 0), { Material = Enum.Material.SmoothPlastic })
	b.add("Ball", Vector3.new(11.6, 6, 11.6), dark, CFrame.new(0, -2.5, 0), { Transparency = 0.15 })
	for _, x in ipairs({ -2.2, 2.2 }) do
		b.add("Ball", Vector3.new(2.4, 1.6, 0.8), Color3.fromRGB(255, 230, 60), CFrame.new(x, 1.6, -5.0), { Material = Enum.Material.Neon })
		b.add("Ball", Vector3.new(0.9, 1.2, 0.4), BLACK, CFrame.new(x, 1.6, -5.35))
		b.add("Wedge", Vector3.new(1.0, 4.0, 2.0), Color3.fromRGB(230, 220, 200), CFrame.new(x * 1.6, 5.5, -1) * CFrame.Angles(math.rad(-20), 0, math.rad(x > 0 and -30 or 30)))
	end
	b.add("Block", Vector3.new(6, 1.2, 1.0), BLACK, CFrame.new(0, -1.5, -5.1), { Anim = "Jaw", Pivot = CFrame.new(0, 0.6, 0.5) })
	for i = 0, 4 do
		b.add("Wedge", Vector3.new(0.5, 1.0, 0.4), WHITE, CFrame.new(-2 + i, -0.8, -5.2) * CFrame.Angles(math.rad(180), 0, 0), { Anim = "Jaw", Pivot = CFrame.new(0, -0.1, 0.6) })
	end
	for i = 0, 7 do
		local a = i * math.pi / 4
		b.add("Wedge", Vector3.new(0.8, 2.2, 1.2), GOLD, CFrame.Angles(0, a, 0) * CFrame.new(0, 5.6, -2.6), { Material = Enum.Material.Neon, Anim = "Spin", Pivot = CFrame.new(0, 0, 2.6) })
	end
	b.add("Cylinder", Vector3.new(0.3, 16, 16), base:Lerp(WHITE, 0.3), CFrame.new(0, -4.8, 0) * CYL_UP, { Material = Enum.Material.Neon, Transparency = 0.6, Anim = "Pulse" })
	for i = 0, 3 do
		local a = i * math.pi / 2 + math.pi / 4
		b.add("Block", Vector3.new(1.4, 4, 1.4), dark, CFrame.Angles(0, a, 0) * CFrame.new(0, -4, -4.2), { Anim = (i % 2 == 0) and "SwingA" or "SwingB", Pivot = CFrame.new(0, 2, 0) })
	end
	return "Hover"
end

-- Small floating gold crown that marks elites.
local function eliteCrown(b)
	b.add("Cylinder", Vector3.new(0.3, 1.4, 1.4), GOLD, CFrame.new(0, 0, 0) * CYL_UP, { Material = Enum.Material.Neon, Anim = "CrownBob" })
	for i = 0, 4 do
		local a = i * math.pi * 2 / 5
		b.add("Wedge", Vector3.new(0.25, 0.5, 0.25), GOLD, CFrame.Angles(0, a, 0) * CFrame.new(0, 0.35, -0.6), { Material = Enum.Material.Neon, Anim = "CrownBob" })
	end
end

--[[
	Builds the model for an enemy type. Returns pieces and the whole-body motion style
	("Hop", "Fly", "Walk", "Float", "Stomp", "Waddle", "Hover").
]]
function ModelLibrary.Enemy(typeId: string, elite: boolean): ({ Piece }, string, number)
	local def = EnemyData.Enemies[typeId] or EnemyData.Enemies.Slime
	local scale = elite and Config.Enemies.EliteSizeMult or 1
	local b = builder(scale)
	local base: Color3 = def.Color
	if elite then
		base = base:Lerp(GOLD, 0.35)
	end
	local dark = base:Lerp(BLACK, 0.45)
	local build = ENEMIES[typeId] or ENEMIES.Slime
	local motion = build(b, base, dark)
	if elite then
		-- the crown floats above the head (pieces built at scale 1, then offset)
		local crownBuilder = builder(1)
		eliteCrown(crownBuilder)
		local top = def.Size.Y * scale / 2 + 1.2
		for _, piece in ipairs(crownBuilder.pieces) do
			piece.Offset = CFrame.new(0, top, 0) * piece.Offset
			table.insert(b.pieces, piece)
		end
	end
	return b.pieces, motion, scale
end

------------------------------------------------------------------------------------------
-- PROJECTILES
------------------------------------------------------------------------------------------

local SHOTS: { [number]: (any, any) -> () } = {}

local function orb(b, color: Color3, size: number)
	b.add("Ball", Vector3.one * size * 0.6, WHITE, CFrame.new(), { Material = Enum.Material.Neon })
	b.add("Ball", Vector3.one * size, color, CFrame.new(), { Material = Enum.Material.Neon, Transparency = 0.35 })
	b.add("Cylinder", Vector3.new(0.08, size * 1.5, size * 1.5), color, CFrame.Angles(0, 0, math.rad(90)), { Material = Enum.Material.Neon, Transparency = 0.5, Anim = "Spin" })
	b.add("Ball", Vector3.one * size * 0.5, color, CFrame.new(0, 0, size * 0.9), { Material = Enum.Material.Neon, Transparency = 0.6 })
end

local function knife(b, blade: Color3, neon: boolean)
	local mat = neon and Enum.Material.Neon or Enum.Material.Metal
	b.add("Block", Vector3.new(0.35, 0.1, 1.6), blade, CFrame.new(0, 0, -0.4), { Material = mat })
	b.add("Wedge", Vector3.new(0.1, 0.35, 0.5), blade, CFrame.new(0, 0, -1.45) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(math.rad(-90), 0, 0), { Material = mat })
	b.add("Block", Vector3.new(0.8, 0.15, 0.15), GOLD, CFrame.new(0, 0, 0.45), { Material = Enum.Material.Metal })
	b.add("Block", Vector3.new(0.2, 0.2, 0.8), Color3.fromRGB(90, 55, 35), CFrame.new(0, 0, 0.9), { Material = Enum.Material.Wood })
end

local function bottle(b, glass: Color3, flame: boolean)
	b.add("Ball", Vector3.new(1.1, 1.1, 1.1), glass, CFrame.new(0, -0.1, 0), { Material = Enum.Material.Glass, Transparency = 0.2 })
	b.add("Ball", Vector3.new(0.7, 0.7, 0.7), glass:Lerp(WHITE, 0.4), CFrame.new(0, -0.15, 0), { Material = Enum.Material.Neon, Transparency = 0.3 })
	b.add("Cylinder", Vector3.new(0.6, 0.4, 0.4), glass, CFrame.new(0, 0.65, 0) * CYL_UP, { Material = Enum.Material.Glass, Transparency = 0.2 })
	b.add("Cylinder", Vector3.new(0.25, 0.42, 0.42), Color3.fromRGB(150, 110, 70), CFrame.new(0, 1.0, 0) * CYL_UP, { Material = Enum.Material.Wood })
	if flame then
		b.add("Ball", Vector3.new(0.5, 0.8, 0.5), Color3.fromRGB(255, 160, 40), CFrame.new(0, 1.45, 0), { Material = Enum.Material.Neon, Anim = "Flicker" })
	end
end

local function axe(b, headColor: Color3, double: boolean, neon: boolean)
	local mat = neon and Enum.Material.Neon or Enum.Material.Metal
	b.add("Cylinder", Vector3.new(2.6, 0.3, 0.3), Color3.fromRGB(110, 75, 45), CFrame.new(0, 0, 0), { Material = Enum.Material.Wood })
	b.add("Wedge", Vector3.new(0.2, 1.3, 1.0), headColor, CFrame.new(1.0, 0, -0.55) * CFrame.Angles(0, 0, math.rad(90)), { Material = mat })
	b.add("Block", Vector3.new(0.6, 0.25, 0.5), headColor:Lerp(BLACK, 0.3), CFrame.new(1.0, 0, -0.05), { Material = Enum.Material.Metal })
	if double then
		b.add("Wedge", Vector3.new(0.2, 1.3, 1.0), headColor, CFrame.new(1.0, 0, 0.55) * CFrame.Angles(0, math.rad(180), math.rad(90)), { Material = mat })
	end
end

local function boomerang(b, color: Color3, stripe: Color3, neon: boolean)
	local mat = neon and Enum.Material.Neon or Enum.Material.Wood
	for _, side in ipairs({ -1, 1 }) do
		local rot = CFrame.Angles(0, math.rad(side * 35), 0)
		b.add("Block", Vector3.new(0.5, 0.2, 1.8), color, rot * CFrame.new(0, 0, -0.75), { Material = mat })
		b.add("Block", Vector3.new(0.52, 0.22, 0.25), stripe, rot * CFrame.new(0, 0, -1.2), { Material = Enum.Material.SmoothPlastic })
	end
end

SHOTS[1] = function(b, def)
	orb(b, def.Color, 1.4)
end
SHOTS[2] = function(b, _def)
	knife(b, Color3.fromRGB(220, 225, 235), false)
end
SHOTS[3] = function(b, def)
	bottle(b, def.Color, false)
end
SHOTS[4] = function(b, _def)
	axe(b, Color3.fromRGB(170, 170, 180), false, false)
end
SHOTS[5] = function(b, def)
	boomerang(b, def.Color, Color3.fromRGB(200, 60, 50), false)
end
SHOTS[6] = function(b, def)
	orb(b, def.Color, 1.6)
	b.add("Ball", Vector3.one * 0.5, WHITE, CFrame.new(1.1, 0, 0), { Material = Enum.Material.Neon, Anim = "Spin", Pivot = CFrame.new(-1.1, 0, 0) })
end
SHOTS[7] = function(b, def)
	orb(b, def.Color, 2.4)
	for i = 0, 3 do
		b.add("Wedge", Vector3.new(0.4, 0.8, 0.4), BLACK, CFrame.Angles(0, i * math.pi / 2, 0) * CFrame.new(0, 0, -1.3), { Anim = "Spin", Pivot = CFrame.new(0, 0, 1.3) })
	end
end
SHOTS[8] = function(b, def)
	knife(b, def.Color, true)
end
SHOTS[9] = function(b, def)
	axe(b, def.Color, true, true)
end
SHOTS[10] = function(b, def)
	boomerang(b, def.Color, WHITE, true)
end
SHOTS[11] = function(b, def)
	bottle(b, def.Color, true)
end

function ModelLibrary.Projectile(visual: number): { Piece }
	local def = WeaponData.Visuals[visual] or WeaponData.Visuals[1]
	local b = builder(1)
	local fn = SHOTS[visual]
	if fn then
		fn(b, def)
	else
		b.add(def.Shape, def.Size, def.Color, CFrame.new(), { Material = Enum.Material.Neon })
	end
	return b.pieces
end

------------------------------------------------------------------------------------------
-- ANIMATION
------------------------------------------------------------------------------------------

--[[
	Extra transform for an animated piece. t = time, phase = per-enemy offset,
	move = 0..1 how fast it is walking. The result is applied as
	Offset * Pivot⁻¹ * rotation * Pivot so limbs swing around their joints.
]]
function ModelLibrary.Animate(anim: string, t: number, phase: number, move: number): CFrame
	if anim == "SwingA" or anim == "SwingB" then
		local dir = anim == "SwingA" and 1 or -1
		local amount = 0.15 + move * 0.55
		return CFrame.Angles(math.sin(t * 9 + phase) * amount * dir, 0, 0)
	elseif anim == "FlapL" or anim == "FlapR" then
		local dir = anim == "FlapL" and 1 or -1
		return CFrame.Angles(0, 0, math.sin(t * 18 + phase) * 0.8 * dir)
	elseif anim == "Spin" then
		return CFrame.Angles(0, t * 3 + phase, 0)
	elseif anim == "Wiggle" then
		return CFrame.Angles(0, 0, math.sin(t * 5 + phase) * 0.35)
	elseif anim == "Jaw" then
		return CFrame.Angles(math.max(0, math.sin(t * 2.5 + phase)) * 0.45, 0, 0)
	elseif anim == "Flicker" then
		local s = 0.08 * math.sin(t * 40 + phase)
		return CFrame.new(s, math.abs(s), 0)
	elseif anim == "Pulse" then
		return CFrame.new(0, math.sin(t * 6 + phase) * 0.05, 0)
	elseif anim == "CrownBob" then
		return CFrame.new(0, math.sin(t * 3 + phase) * 0.2, 0)
	end
	return CFrame.identity
end

-- Whole-body motion: returns a CFrame applied on top of the server body CFrame.
function ModelLibrary.Motion(style: string, t: number, phase: number, move: number, scale: number): CFrame
	if style == "Hop" then
		local hop = math.abs(math.sin(t * 6 + phase))
		return CFrame.new(0, hop * 0.6 * scale * (0.3 + move), 0) * CFrame.Angles(math.sin(t * 6 + phase) * 0.12, 0, 0)
	elseif style == "Fly" then
		return CFrame.new(0, math.sin(t * 9 + phase) * 0.25 * scale, 0)
	elseif style == "Walk" then
		return CFrame.new(0, math.abs(math.sin(t * 9 + phase)) * 0.12 * scale * move, 0)
	elseif style == "Float" then
		return CFrame.new(0, math.sin(t * 2 + phase) * 0.4 * scale, 0) * CFrame.Angles(0, 0, math.sin(t * 1.5 + phase) * 0.12)
	elseif style == "Stomp" then
		return CFrame.new(0, math.abs(math.sin(t * 4.5 + phase)) * 0.3 * scale * move, 0) * CFrame.Angles(0, 0, math.sin(t * 4.5 + phase) * 0.06)
	elseif style == "Waddle" then
		return CFrame.Angles(0, 0, math.sin(t * 12 + phase) * 0.18) * CFrame.new(0, math.abs(math.sin(t * 12 + phase)) * 0.15, 0)
	elseif style == "Hover" then
		return CFrame.new(0, 1 + math.sin(t * 1.6 + phase) * 0.8, 0)
	end
	return CFrame.identity
end

-- Final CFrame for one piece.
function ModelLibrary.PieceCFrame(bodyCF: CFrame, piece: Piece, t: number, phase: number, move: number): CFrame
	local cf = bodyCF * piece.Offset
	if piece.Anim then
		local rot = ModelLibrary.Animate(piece.Anim, t, phase, move)
		if piece.Pivot then
			cf = cf * piece.Pivot * rot * piece.Pivot:Inverse()
		else
			cf = cf * rot
		end
	end
	return cf
end

return ModelLibrary
