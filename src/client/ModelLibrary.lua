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
local MeshCatalog = require(Shared:WaitForChild("MeshCatalog"))
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModelLibrary = {}

export type Piece = { Part: BasePart, Offset: CFrame, Anim: string?, Pivot: CFrame?, Color: Color3 }


local folder: Instance? = nil

function ModelLibrary.SetFolder(f: Instance)
	folder = f;
	(ModelLibrary :: any)._folder = f
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
-- UPLOADED MESH MODELS (Blender-built, see MeshCatalog / server MeshService)
------------------------------------------------------------------------------------------

local MATERIALS = {
	SmoothPlastic = Enum.Material.SmoothPlastic,
	Neon = Enum.Material.Neon,
	Metal = Enum.Material.Metal,
	Glass = Enum.Material.Glass,
}

-- Template folder of a loaded mesh model, or nil (not uploaded / still loading).
function ModelLibrary.MeshFolder(name: string): Instance?
	local root = ReplicatedStorage:FindFirstChild("SwarmMeshes")
	local f = root and root:FindFirstChild(name)
	if f and f:GetAttribute("Ready") then
		return f
	end
	return nil
end

--[[
	Pieces for a mesh model. palette overrides slot colours; tint(color) can change each
	colour (elite gold); scale grows everything; lift moves the model origin
	(e.g. -halfHeight so a ground-origin model sits under an enemy's body centre).
]]
function ModelLibrary.MeshPieces(name: string, palette: { [string]: Color3 }?, scale: number?, lift: number?, tint: ((Color3) -> Color3)?): { Piece }?
	local folder = ModelLibrary.MeshFolder(name)
	local entry = MeshCatalog.Models[name]
	if not folder or not entry then
		return nil
	end
	local s = scale or 1
	local pieces: { Piece } = {}
	for _, def in ipairs(entry.Pieces) do
		local template = folder:FindFirstChild(def.Name)
		if template and template:IsA("MeshPart") then
			local part = template:Clone()
			part.Size = Vector3.new(def.Size[1], def.Size[2], def.Size[3]) * s
			local color = (palette and palette[def.Slot]) or (entry.Palette and entry.Palette[def.Slot]) or part.Color
			if tint then
				color = tint(color)
			end
			part.Color = color
			part.Material = MATERIALS[def.Material] or Enum.Material.SmoothPlastic
			part.Transparency = def.Transparency or 0
			part.CastShadow = def.Shadow == true
			part.CFrame = CFrame.new(0, -150, 0)
			part.Parent = (ModelLibrary :: any)._folder
			local offset = Vector3.new(def.Offset[1], def.Offset[2], def.Offset[3]) * s + Vector3.new(0, lift or 0, 0)
			local pivot = def.Pivot and CFrame.new(Vector3.new(def.Pivot[1], def.Pivot[2], def.Pivot[3]) * s) or nil
			table.insert(pieces, { Part = part, Offset = CFrame.new(offset), Anim = def.Anim, Pivot = pivot, Color = color })
		end
	end
	return pieces
end

-- Enemy type → mesh model name (blender/models/enemies.py) and whole-body motion.
local ENEMY_MESH = {
	Slime = { "Mite", "Scuttle" },
	Bat = { "Wasp", "Buzz" },
	Skeleton = { "BeetleWarrior", "March" },
	Ghost = { "PhaseMoth", "Flutter" },
	Brute = { "RhinoBeetle", "Stomp" },
	Bomber = { "BombTick", "Waddle" },
	Boss = { "ScorpionQueen", "Prowl" },
}

------------------------------------------------------------------------------------------
-- ENEMIES (part-built fallbacks, used until the meshes are loaded)
------------------------------------------------------------------------------------------

local Palette = require(Shared:WaitForChild("Palette"))
local ELITE_GOLD = Palette.gold_400

-- Slot colours of each creature, the same as the Blender models' palettes.
local LOOKS: { [string]: { [string]: Color3 } } = {
	Slime = { Base = Palette.beetle_300, Dark = Palette.chitin_900, Eye = Palette.amber_500 },
	Bat = { Base = Palette.wasp_500, Dark = Palette.wasp_900, Light = Palette.ivory_100, Eye = Palette.amber_500 },
	Skeleton = {
		Base = Palette.beetle_700,
		Light = Palette.beetle_500,
		Dark = Palette.chitin_900,
		Metal = Palette.steel_500,
		White = Palette.steel_300,
		Wood = Palette.wood_700,
		Eye = Palette.amber_500,
	},
	Ghost = {
		Base = Palette.moth_500:Lerp(Palette.crimson_300, 0.16):Lerp(Palette.stone_500, 0.25),
		Light = Palette.moth_300:Lerp(Palette.crimson_300, 0.14):Lerp(Palette.slate_300, 0.12),
		Accent = Palette.slate_600,
		Glow = Palette.moth_glow,
		Dark = Palette.chitin_800,
		Eye = Palette.amber_500,
	},
	Brute = {
		Base = Palette.slate_400,
		Accent = Palette.slate_500,
		Light = Palette.slate_200,
		Dark = Palette.chitin_900,
		White = Palette.ivory_200,
		Eye = Palette.amber_500,
	},
	Bomber = { Base = Palette.tick_500, Dark = Palette.chitin_900, Glow = Palette.tick_glow, Eye = Palette.amber_500 },
	Boss = {
		Base = Palette.crimson_500,
		Accent = Palette.crimson_800,
		Gold = Palette.gold_500,
		Dark = Palette.chitin_900,
		Light = Palette.amber_500,
		Glow = Palette.amber_300,
		Eye = Palette.amber_500,
	},
}

-- Elites get a slight gold tint: the main shell most, glowing bits not at all.
local function eliteTint(color: Color3, slot: string?): Color3
	if slot == "Eye" or slot == "Glow" then
		return color
	end
	return color:Lerp(ELITE_GOLD, slot == "Base" and 0.3 or 0.12)
end

local NEON = Enum.Material.Neon
local METAL = Enum.Material.Metal

-- Pivot that turns a piece placed at `cf` around the body-space point `j` (body axes).
local function joint(cf: CFrame, j: Vector3): CFrame
	return cf:Inverse() * CFrame.new(j)
end

local function withJoint(cf: CFrame, opts: { [string]: any }?): { [string]: any }
	local o = table.clone(opts or {})
	if o.Joint then
		o.Pivot = joint(cf, o.Joint)
		o.Joint = nil
	end
	return o
end

-- Ellipsoid (a block with a sphere mesh) filling `size`.
local function egg(b, size: Vector3, color: Color3, cf: CFrame, opts: { [string]: any }?): BasePart
	local part = b.add("Block", size, color, cf, withJoint(cf, opts))
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

-- Square bar from a to c (legs, horns, spear shafts).
local function bar(b, a: Vector3, c: Vector3, thick: number, color: Color3, opts: { [string]: any }?): BasePart
	local dir = c - a
	local up = math.abs(dir.Unit.Y) > 0.9 and Vector3.zAxis or Vector3.yAxis
	local cf = CFrame.lookAt((a + c) / 2, c, up)
	return b.add("Block", Vector3.new(thick, thick, dir.Magnitude), color, cf, withJoint(cf, opts))
end

local function ball(b, d: number, color: Color3, pos: Vector3, opts: { [string]: any }?): BasePart
	local cf = CFrame.new(pos)
	return b.add("Ball", Vector3.one * d, color, cf, withJoint(cf, opts))
end

local V = Vector3.new

-- Fallbacks are authored with the origin on the ground (like the meshes; front = -Z, the
-- creature's left = -X) and lifted onto the body centre by ModelLibrary.Enemy.
local ENEMIES: { [string]: (any, { [string]: Color3 }) -> string } = {}

-- Mite: round yellow-green shell with a seam, dark head, amber eyes, six legs.
ENEMIES.Slime = function(b, c)
	egg(b, V(2.5, 1.6, 2.3), c.Base, CFrame.new(0, 0.95, 0.3))
	b.add("Block", V(0.09, 0.1, 1.4), c.Dark, CFrame.new(0, 1.72, 0.45))
	egg(b, V(1.65, 1.15, 0.95), c.Base, CFrame.new(0, 0.9, -0.7))
	egg(b, V(1.0, 0.72, 0.85), c.Dark, CFrame.new(0, 0.6, -1.15))
	for _, x in ipairs({ -0.29, 0.29 }) do
		ball(b, 0.2, c.Eye, V(x, 0.72, -1.45), { Material = NEON })
	end
	for _, side in ipairs({ -1, 1 }) do
		local anim = side < 0 and "SwingA" or "SwingB"
		local hip = V(side * 0.72, 0.5, 0.2)
		for i, z in ipairs({ -0.42, 0.2, 0.82 }) do
			local foot = V(side * 1.52, 0.04, z + ({ -0.72, 0.1, 0.7 })[i])
			bar(b, V(side * 1.1, 0.88, z + ({ -0.3, 0.02, 0.28 })[i]), foot, 0.2, c.Dark, { Anim = anim, Joint = hip })
		end
	end
	return "Scuttle"
end

-- Wasp: black thorax and head, gold abdomen with black bands, stinger, ivory wings.
ENEMIES.Bat = function(b, c)
	egg(b, V(0.62, 0.6, 0.78), c.Dark, CFrame.new(0, 0.64, -0.4))
	egg(b, V(0.55, 0.5, 0.42), c.Dark, CFrame.new(0, 0.66, -0.9))
	egg(b, V(0.82, 0.78, 1.36), c.Base, CFrame.new(0, 0.5, 0.74) * CFrame.Angles(math.rad(6), 0, 0))
	for _, z in ipairs({ 0.58, 0.98 }) do
		egg(b, V(0.86, 0.8, 0.16), c.Dark, CFrame.new(0, 0.5 - (z - 0.5) * 0.1, z))
	end
	bar(b, V(0, 0.42, 1.38), V(0, 0.34, 1.9), 0.1, c.Dark)
	for _, x in ipairs({ -0.19, 0.19 }) do
		ball(b, 0.17, c.Eye, V(x, 0.72, -1.0), { Material = NEON })
	end
	for _, side in ipairs({ -1, 1 }) do
		local anim = side < 0 and "FlapL" or "FlapR"
		egg(b, V(1.3, 0.05, 0.5), c.Light, CFrame.new(side * 0.74, 0.88, -0.3) * CFrame.Angles(0, -side * math.rad(18), 0),
			{ Transparency = 0.35, Anim = anim, Joint = V(side * 0.12, 0.88, -0.44) })
	end
	return "Buzz"
end

-- Beetle Warrior: dark green carapace, steel horned helm, shield on the left, spear on the right.
ENEMIES.Skeleton = function(b, c)
	for _, side in ipairs({ -1, 1 }) do
		local hip = V(side * 0.42, 1.62, 0.05)
		bar(b, hip, V(side * 0.5, 0.08, -0.2), 0.42, c.Dark, { Anim = side < 0 and "SwingB" or "SwingA", Joint = hip })
		egg(b, V(1.05, 0.62, 1.05), c.Base, CFrame.new(side * 0.85, 3.12, 0))
		bar(b, V(side * 0.35, 3.85, -0.1), V(side * 0.62, 4.35, -0.45), 0.16, c.Dark)
		ball(b, 0.15, c.Eye, V(side * 0.18, 3.42, -0.55), { Material = NEON })
	end
	egg(b, V(1.2, 0.85, 1.0), c.Dark, CFrame.new(0, 1.7, 0.05))
	egg(b, V(1.5, 1.42, 1.16), c.Base, CFrame.new(0, 2.6, 0))
	egg(b, V(1.66, 2.0, 0.95), c.Base, CFrame.new(0, 2.42, 0.42))
	egg(b, V(0.76, 0.72, 0.8), c.Dark, CFrame.new(0, 3.5, -0.16))
	egg(b, V(1.0, 0.9, 1.04), c.Metal, CFrame.new(0, 3.72, -0.12), { Material = METAL })
	-- left arm + shield (swing)
	local shoulder = V(-0.82, 3.0, 0)
	local swing = { Anim = "SwingA", Joint = shoulder }
	bar(b, shoulder, V(-1.05, 1.95, -0.3), 0.34, c.Dark, swing)
	local shieldCF = CFrame.new(-1.32, 2.2, -0.36) * CFrame.Angles(0, math.rad(15), math.rad(-25))
	b.add("Cylinder", V(0.1, 1.36, 1.36), c.Metal, shieldCF * CFrame.new(0.05, 0, 0), withJoint(shieldCF * CFrame.new(0.05, 0, 0), { Material = METAL, Anim = "SwingA", Joint = shoulder }))
	b.add("Cylinder", V(0.18, 1.2, 1.2), c.Base, shieldCF * CFrame.new(-0.04, 0, 0), withJoint(shieldCF * CFrame.new(-0.04, 0, 0), swing))
	-- right arm holding the spear still
	bar(b, V(0.82, 3.0, 0), V(1.0, 2.1, -0.5), 0.32, c.Dark)
	local d = V(0, 0.92, -0.38).Unit
	local f = V(1.0, 2.08, -0.58)
	bar(b, f - d * 1.95, f + d * 1.75, 0.13, c.Wood)
	bar(b, f + d * 1.7, f + d * 2.45, 0.2, c.White, { Material = METAL })
	return "March"
end

-- Phase Moth: grey-lavender body, translucent wings with slate eye-spots, glowing core.
ENEMIES.Ghost = function(b, c)
	egg(b, V(0.8, 0.8, 0.85), c.Base, CFrame.new(0, 1.55, -0.22))
	egg(b, V(0.46, 0.46, 1.0), c.Base, CFrame.new(0, 1.45, 0.4))
	egg(b, V(0.48, 0.44, 0.4), c.Base, CFrame.new(0, 1.6, -0.74))
	ball(b, 0.3, c.Glow, V(0, 1.98, -0.16), { Material = NEON, Anim = "Pulse" })
	for _, side in ipairs({ -1, 1 }) do
		ball(b, 0.16, c.Eye, V(side * 0.16, 1.66, -0.86), { Material = NEON })
		local root = V(side * 0.12, 1.74, -0.2)
		local wing = CFrame.new(root) * CFrame.Angles(0, 0, side * math.rad(16))
		local opts = { Anim = side < 0 and "FlutterL" or "FlutterR", Joint = root, Transparency = 0.3 }
		egg(b, V(1.6, 0.05, 1.05), c.Light, wing * CFrame.new(side * 0.84, 0, -0.32), opts)
		egg(b, V(1.05, 0.05, 0.95), c.Light, wing * CFrame.new(side * 0.6, -0.02, 0.48), opts)
		egg(b, V(0.46, 0.08, 0.46), c.Accent, wing * CFrame.new(side * 1.02, 0.01, -0.38), { Anim = opts.Anim, Joint = root })
	end
	return "Flutter"
end

-- Rhino Beetle: slate-blue wing cases with highlights, darker pronotum, big ivory horn.
ENEMIES.Brute = function(b, c)
	egg(b, V(4.0, 3.5, 4.1), c.Base, CFrame.new(0, 1.55, 0.7))
	egg(b, V(3.44, 2.7, 2.04), c.Accent, CFrame.new(0, 1.62, -1.08))
	egg(b, V(1.72, 1.28, 1.52), c.Dark, CFrame.new(0, 1.3, -2.12))
	bar(b, V(0, 2.75, -1.5), V(0, 3.7, -1.98), 0.4, c.White)
	local neck = V(0, 1.5, -2.25)
	local toss = { Anim = "Jaw", Joint = neck }
	bar(b, V(0, 1.42, -2.5), V(0, 2.45, -3.56), 0.75, c.White, toss)
	bar(b, V(0, 2.3, -3.56), V(0, 4.0, -3.4), 0.55, c.White, toss)
	bar(b, V(0, 3.9, -3.4), V(0, 4.72, -2.9), 0.32, c.White, toss)
	for _, side in ipairs({ -1, 1 }) do
		egg(b, V(0.42, 0.22, 2.0), c.Light, CFrame.new(side * 0.68, 3.18, 0.5))
		ball(b, 0.24, c.Eye, V(side * 0.62, 1.48, -2.56), { Material = NEON })
		for i, l in ipairs({ { -1.22, -0.36, -0.82 }, { 0.25, 0, 0.1 }, { 1.66, 0.36, 0.84 } }) do
			-- two alternating tripods (the mesh's rule, with Blender's +X = this -X)
			local anim = (((i - 1) % 2 == 0) == (side < 0)) and "SwingA" or "SwingB"
			local hip = V(side * 1.25, 1.15, l[1])
			local knee = V(side * 2.15, 1.78, l[1] + l[2])
			bar(b, hip, knee, 0.55, c.Dark, { Anim = anim, Joint = hip })
			bar(b, knee, V(side * 2.4, 0.02, l[1] + l[3]), 0.42, c.Dark, { Anim = anim, Joint = hip })
		end
	end
	return "Stomp"
end

-- Bomb Tick: bloated crimson sac with glowing amber blisters, dark shield and head.
ENEMIES.Bomber = function(b, c)
	egg(b, V(2.3, 1.95, 2.65), c.Base, CFrame.new(0, 1.12, 0.32))
	egg(b, V(1.2, 0.82, 0.86), c.Dark, CFrame.new(0, 1.02, -0.86))
	egg(b, V(0.72, 0.56, 0.68), c.Dark, CFrame.new(0, 0.72, -1.24))
	ball(b, 0.55, c.Glow, V(0, 2.04, 0.6), { Material = NEON, Anim = "Throb" })
	for _, side in ipairs({ -1, 1 }) do
		ball(b, 0.4, c.Glow, V(side * 0.66, 1.84, -0.05), { Material = NEON, Anim = "Throb" })
		ball(b, 0.4, c.Glow, V(side * 0.62, 1.72, 1.0), { Material = NEON, Anim = "Throb" })
		local anim = side < 0 and "SwingA" or "SwingB"
		local hip = V(side * 0.55, 0.6, -0.55)
		for i, z in ipairs({ -1.0, -0.72, -0.44, -0.16 }) do
			local df = ({ -0.66, -0.22, 0.3, 0.76 })[i]
			bar(b, V(side * 0.75, 0.8, z), V(side * 1.42, 0.03, z + df), 0.15, c.Dark, { Anim = anim, Joint = hip })
		end
	end
	return "Waddle"
end

-- Scorpion Queen: crimson plates with gold rims, gold crown, big claws, amber stinger.
ENEMIES.Boss = function(b, c)
	egg(b, V(5.0, 2.7, 3.5), c.Base, CFrame.new(0, 2.3, -2.55))
	egg(b, V(4.6, 1.9, 8.6), c.Dark, CFrame.new(0, 1.95, 0.1))
	for i = 0, 5 do
		local z = -1.15 + i * 0.82
		local w = 2.55 - math.abs(i - 1.5) * 0.12 - math.max(0, i - 3) * 0.2
		egg(b, V(w * 2, 2.3, 1.32), c.Base, CFrame.new(0, 2.25, z))
		egg(b, V(w * 1.7, 0.4, 0.5), c.Gold, CFrame.new(0, 3.2, z + 0.4), { Material = METAL })
	end
	for i, x in ipairs({ -0.78, -0.42, 0, 0.42, 0.78 }) do
		local h = ({ 1.0, 1.35, 1.75, 1.35, 1.0 })[i]
		bar(b, V(x * 1.6, 3.45, -2.85), V(x * 2.4, 3.45 + h, -2.65), 0.3, c.Gold, { Material = METAL })
	end
	for _, side in ipairs({ -1, 1 }) do
		ball(b, 0.4, c.Eye, V(side * 0.36, 3.48, -3.62), { Material = NEON })
		local shoulder = V(side * 1.9, 2.35, -3.3)
		local lift = { Anim = "Jaw", Joint = shoulder }
		bar(b, shoulder, V(side * 3.55, 2.95, -4.0), 1.1, c.Base, lift)
		bar(b, V(side * 3.55, 2.95, -4.0), V(side * 4.05, 2.85, -5.5), 1.0, c.Base, lift)
		egg(b, V(2.16, 1.8, 2.96), c.Base, CFrame.new(side * 3.85, 2.75, -6.55), lift)
		egg(b, V(0.9, 0.4, 2.4), c.Gold, CFrame.new(side * 3.85, 3.5, -6.55), { Anim = "Jaw", Joint = shoulder, Material = METAL })
		bar(b, V(side * 4.3, 2.75, -7.6), V(side * 3.8, 2.68, -9.2), 0.7, c.Dark, lift)
		bar(b, V(side * 3.35, 2.75, -7.65), V(side * 3.3, 2.68, -9.0), 0.6, c.Dark, lift)
		for i, l in ipairs({ { -1.75, -0.9, -1.75 }, { -0.45, -0.3, -0.5 }, { 0.85, 0.3, 0.6 }, { 2.15, 0.9, 1.75 } }) do
			local anim = (((i - 1) % 2 == 0) == (side < 0)) and "SwingA" or "SwingB"
			local hip = V(side * 2.0, 2.05, l[1])
			local knee = V(side * 4.0, 3.75, l[1] + l[2] * 0.55)
			bar(b, hip, knee, 0.7, c.Accent, { Anim = anim, Joint = hip })
			bar(b, knee, V(side * 6.55, 0.02, l[1] + l[3]), 0.5, c.Accent, { Anim = anim, Joint = hip })
		end
	end
	local pts = { V(0, 2.6, 3.15), V(0, 3.4, 4.5), V(0, 5.05, 5.4), V(0, 7.0, 5.6), V(0, 8.85, 5.1), V(0, 10.25, 3.95), V(0, 10.95, 2.45) }
	local base = pts[1]
	local sway = { Anim = "Tail", Joint = base }
	for i = 1, #pts - 1 do
		bar(b, pts[i], pts[i + 1], 1.6 - i * 0.09, c.Base, sway)
		if i > 1 then
			ball(b, 1.75 - i * 0.09, c.Gold, pts[i], { Anim = "Tail", Joint = base, Material = METAL })
		end
	end
	egg(b, V(1.48, 1.48, 1.96), c.Light, CFrame.new(0, 10.9, 1.95), sway)
	bar(b, V(0, 10.8, 1.35), V(0, 9.65, 0.5), 0.5, c.Dark, sway)
	ball(b, 0.32, c.Glow, V(0, 9.55, 0.5), { Anim = "Tail", Joint = base, Material = NEON })
	return "Prowl"
end

-- Elite marker: a small antique-gold crown (band, five points, a crimson stone) that bobs
-- and slowly turns above the creature.
local function eliteCrown(b)
	local function add(shape: string, size: Vector3, color: Color3, cf: CFrame)
		b.add(shape, size, color, cf, { Material = shape == "Ball" and Enum.Material.SmoothPlastic or METAL, Anim = "CrownBob", Pivot = cf:Inverse() })
	end
	add("Cylinder", V(0.34, 1.5, 1.5), Palette.gold_500, CYL_UP)
	for i = 0, 4 do
		local at = CFrame.Angles(0, i * math.pi * 2 / 5, 0) * CFrame.new(0, 0.42, -0.66)
		add("Wedge", V(0.1, 0.5, 0.16), Palette.gold_400, at * CFrame.new(-0.08, 0, 0) * CFrame.Angles(0, math.pi / 2, 0))
		add("Wedge", V(0.1, 0.5, 0.16), Palette.gold_400, at * CFrame.new(0.08, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0))
	end
	add("Ball", V(0.24, 0.24, 0.24), Palette.crimson_500, CFrame.new(0, 0, -0.76))
end

--[[
	Builds the model for an enemy type: the uploaded Blender mesh when it is loaded, else
	the part-built fallback. Returns pieces, the whole-body motion style (see Motion) and
	the scale. Elites are bigger (Config.Enemies.EliteSizeMult), slightly gold-tinted and
	wear the crown.
]]
function ModelLibrary.Enemy(typeId: string, elite: boolean): ({ Piece }, string, number)
	local def = EnemyData.Enemies[typeId] or EnemyData.Enemies.Slime
	local scale = elite and Config.Enemies.EliteSizeMult or 1
	local lift = -def.Size.Y * scale / 2 -- model origin (ground centre) under the body centre
	local top = def.Size.Y * scale / 2
	local meshInfo = ENEMY_MESH[typeId]
	local motion = meshInfo and meshInfo[2] or "Scuttle"
	local pieces: { Piece }? = meshInfo and ModelLibrary.MeshPieces(meshInfo[1], nil, scale, lift) or nil
	if pieces and meshInfo then
		local entry = MeshCatalog.Models[meshInfo[1]]
		local bounds = (entry :: any).Bounds
		if bounds then
			top = lift + bounds[2][2] * scale
		end
		if elite then
			local slotOf: { [string]: string } = {}
			for _, d in ipairs(entry.Pieces) do
				slotOf[d.Name] = d.Slot
			end
			for _, piece in ipairs(pieces) do
				if piece.Part.Material ~= NEON then
					piece.Color = eliteTint(piece.Color, slotOf[piece.Part.Name])
					piece.Part.Color = piece.Color
				end
			end
		end
	else
		local look = table.clone(LOOKS[typeId] or LOOKS.Slime)
		if elite then
			for slot, color in pairs(look) do
				look[slot] = eliteTint(color, slot)
			end
		end
		local b = builder(scale)
		motion = (ENEMIES[typeId] or ENEMIES.Slime)(b, look)
		for _, piece in ipairs(b.pieces) do
			piece.Offset = CFrame.new(0, lift, 0) * piece.Offset
		end
		pieces = b.pieces
	end
	local out = pieces :: { Piece }
	if elite then
		local crown = builder(1.3)
		eliteCrown(crown)
		for _, piece in ipairs(crown.pieces) do
			piece.Offset = CFrame.new(0, top + 0.9, 0) * piece.Offset
			table.insert(out, piece)
		end
	end
	return out, motion, scale
end

------------------------------------------------------------------------------------------
-- PROJECTILES
------------------------------------------------------------------------------------------

local SHOTS: { [number]: (any, any) -> () } = {}

-- Projectile colours (kept in step with the effects trails): arcane/gold orbs in a slate
-- shell, steel knives and axes, holy / fire flasks, wooden boomerangs with gold, crimson
-- and amber boss stingers; evolutions go gold or crimson.
local ShotPalette = require(Shared:WaitForChild("Palette"))
local SHOT = {
	Arcane = ShotPalette.fx_arcane,
	GoldCore = ShotPalette.fx_gold,
	Shell = ShotPalette.slate_400,
	Steel = ShotPalette.steel_300,
	SteelDark = ShotPalette.steel_600,
	Gold = ShotPalette.gold_500,
	GoldBlade = ShotPalette.gold_400,
	Leather = ShotPalette.leather_600,
	Wood = ShotPalette.wood_400,
	Haft = ShotPalette.wood_500,
	Glass = ShotPalette.ivory_100,
	Holy = ShotPalette.fx_holy,
	Fire = ShotPalette.fx_fire,
	Crimson = ShotPalette.crimson_500,
	CrimsonDark = ShotPalette.crimson_800,
	Amber = ShotPalette.amber_500,
	Ivory = ShotPalette.ivory_100,
}
local SHOT_NEON = Enum.Material.Neon
local SHOT_METAL = Enum.Material.Metal

-- Orb: small Neon core, translucent shell, two orbiting sparks.
local function orb(b, core: Color3, size: number)
	b.add("Ball", Vector3.one * size * 0.42, core, CFrame.new(), { Material = SHOT_NEON })
	b.add("Ball", Vector3.one * size * 0.85, SHOT.Shell, CFrame.new(), { Transparency = 0.55 })
	for _, x in ipairs({ -1, 1 }) do
		local r = size * 0.55
		b.add("Ball", Vector3.one * 0.16, core, CFrame.new(x * r, 0, 0), { Material = SHOT_NEON, Anim = "Spin", Pivot = CFrame.new(-x * r, 0, 0) })
	end
end

-- Knife along Z, tip toward -Z.
local function knife(b, blade: Color3, grip: Color3)
	b.add("Block", Vector3.new(0.36, 0.1, 1.3), blade, CFrame.new(0, 0, -0.5), { Material = SHOT_METAL })
	b.add("Wedge", Vector3.new(0.1, 0.36, 0.45), blade, CFrame.new(0, 0, -1.37) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(math.rad(-90), 0, 0), { Material = SHOT_METAL })
	b.add("Block", Vector3.new(0.72, 0.16, 0.16), SHOT.Gold, CFrame.new(0, 0, 0.2))
	b.add("Block", Vector3.new(0.17, 0.17, 0.6), grip, CFrame.new(0, 0, 0.6))
	b.add("Ball", Vector3.one * 0.24, SHOT.Gold, CFrame.new(0, 0, 0.98))
end

-- Flask, upright: translucent glass, small Neon liquid, cork.
local function bottle(b, liquid: Color3)
	b.add("Ball", Vector3.new(1.1, 1.1, 1.1), SHOT.Glass, CFrame.new(0, -0.15, 0), { Transparency = 0.5 })
	b.add("Ball", Vector3.new(0.8, 0.6, 0.8), liquid, CFrame.new(0, -0.3, 0), { Material = SHOT_NEON })
	b.add("Cylinder", Vector3.new(0.45, 0.36, 0.36), SHOT.Glass, CFrame.new(0, 0.5, 0) * CYL_UP, { Transparency = 0.5 })
	b.add("Cylinder", Vector3.new(0.3, 0.36, 0.36), SHOT.Wood, CFrame.new(0, 0.82, 0) * CYL_UP)
end

-- Axe: haft along Z, head at the -Z end with its bit toward -X (matches Shot_Axe).
local function axe(b, head: Color3)
	b.add("Cylinder", Vector3.new(2.2, 0.22, 0.22), SHOT.Haft, CFrame.new(0, 0, 0.05) * CFrame.Angles(0, math.rad(90), 0))
	b.add("Block", Vector3.new(0.42, 0.3, 0.5), SHOT.SteelDark, CFrame.new(0, 0, -0.72), { Material = SHOT_METAL })
	b.add("Wedge", Vector3.new(0.12, 1.2, 1.1), head, CFrame.new(-0.75, 0, -0.75) * CFrame.Angles(0, 0, math.rad(90)), { Material = SHOT_METAL })
	b.add("Block", Vector3.new(0.26, 0.26, 0.3), SHOT.Leather, CFrame.new(0, 0, 0.65))
end

-- Boomerang lying flat, apex toward -Z.
local function boomerang(b, wood: Color3, inlay: Color3)
	for _, side in ipairs({ -1, 1 }) do
		local rot = CFrame.new(0, 0, -0.35) * CFrame.Angles(0, math.rad(side * 55), 0)
		b.add("Block", Vector3.new(0.42, 0.18, 1.5), wood, rot * CFrame.new(0, 0, 0.7))
		b.add("Block", Vector3.new(0.3, 0.2, 0.2), inlay, rot * CFrame.new(0, 0.01, 1.2))
	end
	b.add("Block", Vector3.new(0.26, 0.2, 0.26), inlay, CFrame.new(0, 0.01, -0.35) * CFrame.Angles(0, math.rad(45), 0))
end

-- Boss stinger: amber Neon core, crimson barbs, dark carapace ring.
local function stinger(b, size: number)
	b.add("Ball", Vector3.one * size * 0.34, SHOT.Amber, CFrame.new(), { Material = SHOT_NEON })
	b.add("Cylinder", Vector3.new(0.4, size * 0.55, size * 0.55), SHOT.CrimsonDark, CYL_UP)
	for i = 0, 3 do
		b.add("Wedge", Vector3.new(0.3, 0.3, size * 0.42), SHOT.Crimson, CFrame.Angles(0, i * math.pi / 2 + 0.3, 0) * CFrame.new(0, 0, -size * 0.38))
	end
end

SHOTS[1] = function(b, _def)
	orb(b, SHOT.Arcane, 1.6)
end
SHOTS[2] = function(b, _def)
	knife(b, SHOT.Steel, SHOT.Leather)
end
SHOTS[3] = function(b, _def)
	bottle(b, SHOT.Holy)
end
SHOTS[4] = function(b, _def)
	axe(b, SHOT.Steel)
end
SHOTS[5] = function(b, _def)
	boomerang(b, SHOT.Wood, SHOT.Gold)
end
SHOTS[6] = function(b, _def)
	orb(b, SHOT.GoldCore, 1.8)
end
SHOTS[7] = function(b, _def)
	stinger(b, 2.6)
end
SHOTS[8] = function(b, _def)
	knife(b, SHOT.GoldBlade, SHOT.CrimsonDark)
end
SHOTS[9] = function(b, _def)
	axe(b, SHOT.Crimson)
end
SHOTS[10] = function(b, _def)
	boomerang(b, SHOT.GoldBlade, SHOT.Ivory)
end
SHOTS[11] = function(b, _def)
	bottle(b, SHOT.Fire)
end

-- Projectile visual index → mesh model + slot colour overrides (slots: see blender/models/items.py).
local SHOT_MESH: { [number]: { any } } = {
	[1] = { "Shot_Orb", { Core = SHOT.Arcane, Shard = SHOT.Arcane, Shell = SHOT.Shell } },
	[2] = { "Shot_Knife", { Blade = SHOT.Steel, Gold = SHOT.Gold, Grip = SHOT.Leather } },
	[3] = { "Shot_Bottle", { Liquid = SHOT.Holy, Glass = SHOT.Glass } },
	[4] = { "Shot_Axe", { Head = SHOT.Steel, Haft = SHOT.Haft } },
	[5] = { "Shot_Boomerang", { Wood = SHOT.Wood, Inlay = ShotPalette.gold_400 } },
	[6] = { "Shot_Orb", { Core = SHOT.GoldCore, Shard = SHOT.GoldCore, Shell = SHOT.Shell } },
	[7] = { "Shot_Stinger", { Core = SHOT.Amber, Barbs = SHOT.Crimson, Carapace = SHOT.CrimsonDark } },
	[8] = { "Shot_Knife", { Blade = SHOT.GoldBlade, Gold = SHOT.Gold, Grip = SHOT.CrimsonDark } },
	[9] = { "Shot_Axe", { Head = SHOT.Crimson, Haft = ShotPalette.wood_600 } },
	[10] = { "Shot_Boomerang", { Wood = SHOT.GoldBlade, Inlay = SHOT.Ivory } },
	[11] = { "Shot_Bottle", { Liquid = SHOT.Fire, Glass = SHOT.Glass } },
}

-- Mesh model name used for a projectile visual (nil = part-built only).
function ModelLibrary.ProjectileMeshName(visual: number): string?
	local mesh = SHOT_MESH[visual]
	return mesh and mesh[1] or nil
end

function ModelLibrary.Projectile(visual: number): { Piece }
	local mesh = SHOT_MESH[visual]
	if mesh then
		-- meshes are modelled at their WeaponData.Visuals size, so no extra scale
		local meshPieces = ModelLibrary.MeshPieces(mesh[1], mesh[2], 1, 0)
		if meshPieces then
			return meshPieces
		end
	end
	local def = WeaponData.Visuals[visual] or WeaponData.Visuals[1]
	local b = builder(1)
	local fn = SHOTS[visual]
	if fn then
		fn(b, def)
	else
		b.add(def.Shape, def.Size, def.Color, CFrame.new(), { Material = SHOT_NEON })
	end
	return b.pieces
end

------------------------------------------------------------------------------------------
-- ANIMATION
------------------------------------------------------------------------------------------

--[[
	Extra transform for an animated piece. t = time, phase = per-enemy offset,
	move = 0..1 how fast it is walking. The result is applied as
	Offset * Pivot * rotation * Pivot⁻¹ so limbs swing around their joints.

	Enemy keys: SwingA/SwingB legs and arms, FlapL/FlapR fast wasp wings, FlutterL/FlutterR
	slow moth wings (resting raised), Jaw mandibles / horn / claws, Tail, Wiggle antennae,
	Pulse and Throb glow (Throb sinks glowing blisters into the shell and back), CrownBob
	the elite crown. Projectiles use Spin, Flicker and Pulse.
]]
function ModelLibrary.Animate(anim: string, t: number, phase: number, move: number): CFrame
	if anim == "SwingA" or anim == "SwingB" then
		local dir = anim == "SwingA" and 1 or -1
		local amount = 0.15 + move * 0.55
		return CFrame.Angles(math.sin(t * 9 + phase) * amount * dir, 0, 0)
	elseif anim == "FlapL" or anim == "FlapR" then
		local dir = anim == "FlapL" and 1 or -1
		return CFrame.Angles(0, 0, math.sin(t * 34 + phase) * 0.6 * dir)
	elseif anim == "FlutterL" or anim == "FlutterR" then
		local dir = anim == "FlutterL" and -1 or 1 -- the left wing sits on -X
		return CFrame.Angles(0, 0, (0.2 + math.sin(t * 7 + phase) * 0.55) * dir)
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
	elseif anim == "Throb" then
		local s = math.max(0, math.sin(t * 5 + phase))
		return CFrame.new(0, s * s * s * 0.13 - 0.06, 0)
	elseif anim == "Tail" then
		return CFrame.Angles(math.sin(t * 2.2 + phase) * 0.12, 0, math.sin(t * 1.3 + phase) * 0.08)
	elseif anim == "CrownBob" then
		return CFrame.new(0, math.sin(t * 3 + phase) * 0.18, 0) * CFrame.Angles(0, t * 0.9, 0)
	end
	return CFrame.identity
end

-- Whole-body motion: returns a CFrame applied on top of the server body CFrame.
function ModelLibrary.Motion(style: string, t: number, phase: number, move: number, scale: number): CFrame
	local w = t * 9 + phase -- the leg cycle (SwingA / SwingB)
	if style == "Scuttle" then -- small quick beetles: two bumps per stride, a little yaw
		return CFrame.new(0, math.abs(math.sin(w)) * 0.1 * scale * move, 0) * CFrame.Angles(0, math.sin(w) * 0.06 * move, 0)
	elseif style == "Buzz" then -- wasp: bob, bank, nose down when flying fast
		return CFrame.new(0, math.sin(t * 7 + phase) * 0.22 * scale, 0)
			* CFrame.Angles(-0.15 * move, 0, math.sin(t * 3.1 + phase) * 0.12)
	elseif style == "March" then -- upright warrior: bob and sway with the stride
		return CFrame.new(0, math.abs(math.sin(w)) * 0.14 * scale * move, 0) * CFrame.Angles(0, 0, math.sin(w) * 0.05 * move)
	elseif style == "Flutter" then -- moth: slow float plus a lift on each wing beat
		return CFrame.new(0, (math.sin(t * 2 + phase) * 0.35 + math.sin(t * 7 + phase) * 0.1) * scale, 0)
			* CFrame.Angles(0, 0, math.sin(t * 1.5 + phase) * 0.1)
	elseif style == "Stomp" then -- heavy beetle: a bump per tripod step, slow rock
		return CFrame.new(0, math.abs(math.sin(w)) * 0.16 * scale * move, 0) * CFrame.Angles(0, 0, math.sin(t * 4.5 + phase) * 0.04 * move)
	elseif style == "Waddle" then -- bloated tick: rolls side to side with its legs
		return CFrame.Angles(0, 0, math.sin(w) * 0.14) * CFrame.new(0, math.abs(math.sin(w)) * 0.12 * scale, 0)
	elseif style == "Prowl" then -- the queen: low bob, slow menacing sway
		return CFrame.new(0, math.abs(math.sin(w)) * 0.12 * scale * move, 0) * CFrame.Angles(0, math.sin(t * 2 + phase) * 0.04, 0)
	elseif style == "Hop" then
		local hop = math.abs(math.sin(t * 6 + phase))
		return CFrame.new(0, hop * 0.6 * scale * (0.3 + move), 0) * CFrame.Angles(math.sin(t * 6 + phase) * 0.12, 0, 0)
	elseif style == "Fly" then
		return CFrame.new(0, math.sin(t * 9 + phase) * 0.25 * scale, 0)
	elseif style == "Walk" then
		return CFrame.new(0, math.abs(math.sin(w)) * 0.12 * scale * move, 0)
	elseif style == "Float" then
		return CFrame.new(0, math.sin(t * 2 + phase) * 0.4 * scale, 0) * CFrame.Angles(0, 0, math.sin(t * 1.5 + phase) * 0.12)
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
