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
	Spitter = { "Spitter", "Scuttle" },
	Boss = { "ScorpionQueen", "Prowl" },
	MothBoss = { "MothMatriarch", "Flutter" },
	RhinoBoss = { "RhinoWarlord", "Stomp" },
	HiveBoss = { "HiveMother", "Prowl" },
	Burrower = { "Burrower", "Scuttle" },
	Healer = { "Healer", "Scuttle" },
	Nest = { "Nest", "Static" },
	WarBanner = { "RhinoWarlord", "Static" },
	BriarBoss = { "BriarSentinel", "Stomp" },
	FrostBoss = { "FrostboundColossus", "Stomp" },
	ThornSprout = { "ThornSprout", "Scuttle" },
}

--[[
	Extra mesh rules per enemy type: Scale (the Hive Mother's mesh is ~17 studs long, her
	body ~14), Only (keep just these pieces) and Shift (studs, model space, before Scale):
	the War Banner is the banner from the Warlord's back, stood on the ground.
]]
local MESH_EXTRA: { [string]: { Scale: number?, Only: { string }?, Shift: Vector3? } } = {
	HiveBoss = { Scale = 0.8 },
	WarBanner = { Scale = 1.45, Only = { "BannerPole", "BannerTrim", "Banner", "BannerCrown" }, Shift = Vector3.new(0, -4.95, -3.9) },
}

-- Pieces some poses hide (EnemyRenderer): the Burrower's soil ring, the Warlord's banner,
-- the Colossus's frost armour (shown only while it is on; mesh piece names from
-- blender/models/bosses2.py and the part-built fallback's names).
ModelLibrary.PieceGroups = {
	Mound = { Mound = true },
	Banner = { BannerPole = true, BannerTrim = true, Banner = true, BannerCrown = true },
	Frost = {
		FrostChest = true,
		FrostBack = true,
		FrostShoulder = true,
		FrostShoulderL = true,
		FrostShoulderR = true,
		FrostArm = true,
		FrostArmL = true,
		FrostArmR = true,
		FrostSpike = true,
	},
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
	-- mauve beetle with an amber acid sac (the same mixes as blender/models/enemies2.py)
	Spitter = {
		Base = Palette.crimson_500:Lerp(Palette.slate_400, 0.5),
		Accent = Palette.amber_500,
		Light = Palette.amber_300,
		Dark = Palette.chitin_900,
		Metal = Palette.crimson_800:Lerp(Palette.slate_700, 0.5),
		Glow = Palette.amber_300,
		Eye = Palette.amber_500,
	},
	Boss = {
		Base = Palette.crimson_500,
		Accent = Palette.crimson_800,
		Gold = Palette.gold_500,
		Dark = Palette.chitin_900,
		Light = Palette.amber_500,
		Glow = Palette.amber_300,
		Eye = Palette.amber_500,
	},
	-- the new creatures and bosses (the same slot colours as their Blender palettes)
	MothBoss = {
		Base = Palette.ivory_200:Lerp(Palette.stone_300, 0.2),
		Light = Palette.moth_300,
		Accent = Palette.slate_600,
		Metal = Palette.slate_500,
		Gold = Palette.gold_400,
		Dark = Palette.chitin_800,
		White = Palette.ivory_100,
		Glow = Palette.moth_glow,
		Eye = Palette.amber_500,
	},
	RhinoBoss = {
		Base = Palette.slate_600,
		Accent = Palette.steel_600,
		Metal = Palette.steel_400,
		Gold = Palette.gold_500,
		Dark = Palette.chitin_900,
		White = Palette.ivory_200,
		Cloth = Palette.crimson_500,
		Wood = Palette.wood_700,
		Eye = Palette.amber_500,
	},
	HiveBoss = {
		Base = Palette.ivory_200,
		Accent = Palette.gold_400:Lerp(Palette.ivory_300, 0.4),
		Light = Palette.ivory_100,
		Metal = Palette.wasp_500:Lerp(Palette.chitin_800, 0.5),
		Gold = Palette.gold_500,
		Dark = Palette.chitin_900,
		Glow = Palette.amber_300,
		Eye = Palette.amber_500,
	},
	Burrower = {
		Base = Palette.sand_400,
		Light = Palette.sand_300,
		Accent = Palette.dirt_500,
		Dark = Palette.chitin_900,
		Stone = Palette.dirt_600,
		Eye = Palette.amber_500,
	},
	Healer = {
		Base = Palette.ivory_200,
		Light = Palette.moss_200,
		Accent = Palette.moss_300,
		Dark = Palette.chitin_800,
		White = Palette.ivory_100,
		Glow = Palette.fx_heal,
		Eye = Palette.amber_500,
	},
	Nest = {
		Base = Palette.wood_500,
		Accent = Palette.gold_600,
		Light = Palette.gold_200,
		Dark = Palette.chitin_900,
		Stone = Palette.wood_700,
		Glow = Palette.amber_300,
	},
	WarBanner = {
		Cloth = Palette.crimson_500,
		Gold = Palette.gold_500,
		Wood = Palette.wood_700,
		Stone = Palette.stone_600,
	},
	-- the Briar Sentinel, her sprouts and the Frostbound Colossus (part-built fallbacks of the
	-- BriarSentinel / ThornSprout / FrostboundColossus meshes)
	-- dark bark, bone thorns and amber read on forest grass (no green-on-green)
	BriarBoss = {
		Base = Palette.wood_700:Lerp(Palette.wood_800, 0.35),
		Bark = Palette.wood_900,
		Light = Palette.wood_600,
		Moss = Palette.moss_500:Lerp(Palette.moss_400, 0.4),
		Leaf = Palette.moss_500,
		Vine = Palette.moss_700,
		Thorn = Palette.gold_200:Lerp(Palette.wood_400, 0.3),
		Berry = Palette.amber_300,
		Gold = Palette.wood_500,
		Eye = Palette.amber_500,
	},
	ThornSprout = {
		Base = Palette.wood_500,
		Light = Palette.moss_400:Lerp(Palette.moss_300, 0.3),
		Leaf = Palette.moss_400,
		Thorn = Palette.gold_200:Lerp(Palette.wood_400, 0.3),
		Dark = Palette.wood_900,
		Eye = Palette.amber_500,
	},
	-- deep blue ice, teal crystals and dark rock read on white snow
	FrostBoss = {
		Base = Palette.ice_500:Lerp(Palette.slate_500, 0.45),
		Dark = Palette.slate_800:Lerp(Palette.stone_800, 0.3),
		Stone = Palette.slate_700:Lerp(Palette.stone_700, 0.4),
		Ice = Color3.fromRGB(74, 176, 199),
		IceLight = Palette.ice_100:Lerp(Color3.fromRGB(74, 176, 199), 0.3),
		Gold = Palette.ice_300:Lerp(Color3.fromRGB(74, 176, 199), 0.25),
		Glow = Color3.fromRGB(158, 245, 255),
		Eye = Color3.fromRGB(158, 245, 255),
	},
	BroodEgg = {
		Base = Palette.ivory_200,
		Accent = Palette.gold_400,
		Dark = Palette.chitin_900,
		Glow = Palette.amber_300,
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
local TAU_ML = math.pi * 2

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

-- Spitter: mauve shell, a bulbous amber acid sac on its back, a raised spout, six legs.
ENEMIES.Spitter = function(b, c)
	egg(b, V(2.0, 1.15, 2.3), c.Base, CFrame.new(0, 0.95, 0.15))
	egg(b, V(1.3, 0.95, 1.0), c.Metal, CFrame.new(0, 0.95, -1.0))
	egg(b, V(1.8, 1.55, 1.7), c.Accent, CFrame.new(0, 1.85, 0.35), { Anim = "Pulse", Transparency = 0.12 })
	egg(b, V(0.7, 0.45, 0.7), c.Light, CFrame.new(0.35, 2.4, 0.05), { Anim = "Pulse" })
	ball(b, 0.7, c.Glow, V(0, 1.95, 0.4), { Material = NEON, Anim = "Throb" })
	local neck = V(0, 1.3, -1.05)
	bar(b, neck, V(0, 2.15, -1.65), 0.42, c.Metal, { Anim = "Jaw", Joint = neck })
	ball(b, 0.34, c.Glow, V(0, 2.2, -1.72), { Material = NEON, Anim = "Jaw", Joint = neck })
	for _, x in ipairs({ -0.28, 0.28 }) do
		ball(b, 0.18, c.Eye, V(x, 0.95, -1.5), { Material = NEON })
	end
	for _, side in ipairs({ -1, 1 }) do
		local anim = side < 0 and "SwingA" or "SwingB"
		local hip = V(side * 0.65, 0.55, 0.1)
		for i, z in ipairs({ -0.5, 0.15, 0.8 }) do
			local foot = V(side * 1.45, 0.04, z + ({ -0.6, 0.1, 0.6 })[i])
			bar(b, V(side * 0.95, 0.8, z), foot, 0.18, c.Dark, { Anim = anim, Joint = hip })
		end
	end
	return "Scuttle"
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

-- Moth Matriarch: pale furred body hovering ~4 studs up, four broad wings with gold eye
-- spots, a gold coronet, a glowing heart.
ENEMIES.MothBoss = function(b, c)
	egg(b, V(2.5, 2.6, 3.8), c.Base, CFrame.new(0, 4.2, -1.1))
	egg(b, V(2.0, 2.4, 4.0), c.Base, CFrame.new(0, 3.9, 2.3), { Anim = "Tail", Joint = V(0, 4.2, 0.6) })
	egg(b, V(2.1, 0.5, 2.8), c.Gold, CFrame.new(0, 4.0, 2.4), { Material = METAL, Anim = "Tail", Joint = V(0, 4.2, 0.6) })
	egg(b, V(1.3, 0.8, 1.4), c.Gold, CFrame.new(0, 4.9, -2.5), { Material = METAL })
	ball(b, 0.6, c.Glow, V(0, 5.45, -0.7), { Material = NEON, Anim = "Pulse" })
	for _, side in ipairs({ -1, 1 }) do
		ball(b, 0.38, c.Eye, V(side * 0.4, 4.35, -2.95), { Material = NEON })
		bar(b, V(side * 0.3, 5.0, -2.9), V(side * 2.2, 6.6, -4.4), 0.16, c.White, { Anim = "Wiggle", Joint = V(0, 5.0, -2.9) })
		local root = V(side * 0.7, 5.3, -0.6)
		local anim = side < 0 and "FlutterL" or "FlutterR"
		local wing = CFrame.new(root) * CFrame.Angles(0, 0, side * math.rad(10))
		egg(b, V(6.4, 0.12, 3.9), c.Light, wing * CFrame.new(side * 3.1, 0.2, -0.9), { Anim = anim, Joint = root, Transparency = 0.3 })
		egg(b, V(5.6, 0.12, 5.6), c.Accent, wing * CFrame.new(side * 2.7, 0, 2.4), { Anim = anim, Joint = root, Transparency = 0.18 })
		egg(b, V(1.6, 0.16, 1.6), c.Gold, wing * CFrame.new(side * 3.6, 0.25, -0.6), { Anim = anim, Joint = root, Material = METAL })
		for i, z in ipairs({ -1.2, -0.6, 0 }) do
			local hip = V(side * 0.6, 3.4, z)
			bar(b, hip, V(side * 1.3, 2.0, z + ({ -0.6, 0, 0.5 })[i]), 0.16, c.Dark, { Anim = side < 0 and "SwingA" or "SwingB", Joint = hip })
		end
	end
	return "Flutter"
end

-- Rhino Warlord: a huge slate-blue rhino beetle in steel plates with a crimson war banner.
ENEMIES.RhinoBoss = function(b, c)
	egg(b, V(8.4, 3.4, 8.6), c.Base, CFrame.new(0, 4.8, 1.4))
	egg(b, V(6.8, 2.6, 10.8), c.Dark, CFrame.new(0, 2.6, -0.2))
	egg(b, V(6.7, 2.4, 6.2), c.Metal, CFrame.new(0, 5.4, 1.35), { Material = METAL })
	egg(b, V(6.4, 2.6, 3.8), c.Accent, CFrame.new(0, 4.5, -2.5), { Material = METAL })
	local neck = V(0, 3.4, -4.4)
	local toss = { Anim = "Jaw", Joint = neck }
	bar(b, V(0, 3.2, -4.6), V(0, 4.9, -6.8), 1.4, c.White, toss)
	bar(b, V(0, 4.7, -6.8), V(0, 8.0, -6.4), 1.0, c.White, toss)
	bar(b, V(0, 4.5, -6.4), V(0, 4.5, -6.4) + V(0, 0.4, 0), 1.6, c.Gold, { Anim = "Jaw", Joint = neck, Material = METAL })
	bar(b, V(0, 5.6, -3.6), V(0, 6.3, -4.2), 0.7, c.White)
	for _, side in ipairs({ -1, 1 }) do
		ball(b, 0.45, c.Eye, V(side * 1.1, 2.9, -5.2), { Material = NEON })
		for i, z in ipairs({ -2.96, 0.62, 4.07 }) do
			local anim = (((i - 1) % 2 == 0) == (side < 0)) and "SwingA" or "SwingB"
			local hip = V(side * 2.6, 2.4, z)
			local knee = V(side * 4.6, 3.6, z)
			bar(b, hip, knee, 1.1, c.Dark, { Anim = anim, Joint = hip })
			bar(b, knee, V(side * 5.3, 0.05, z), 0.85, c.Dark, { Anim = anim, Joint = hip })
		end
	end
	local pole = b.add("Block", V(0.35, 8, 0.6), c.Wood, CFrame.new(0, 9, 3.7), { Anim = "Tail", Pivot = CFrame.new(0, -3.4, 0) })
	pole.Name = "BannerPole"
	local cloth = b.add("Block", V(3.6, 4.8, 0.14), c.Cloth, CFrame.new(0, 9.9, 4.05), { Anim = "Tail", Pivot = CFrame.new(0, -4.3, -0.4) })
	cloth.Name = "Banner"
	local trim = b.add("Block", V(4.4, 0.4, 0.5), c.Gold, CFrame.new(0, 12.6, 3.9), { Anim = "Tail", Pivot = CFrame.new(0, -7, -0.2), Material = METAL })
	trim.Name = "BannerTrim"
	local crown = b.add("Block", V(1.6, 1.0, 0.3), c.Gold, CFrame.new(0, 11.1, 4.0), { Anim = "Tail", Pivot = CFrame.new(0, -5.5, -0.35), Material = METAL })
	crown.Name = "BannerCrown"
	return "Stomp"
end

-- Hive Mother: a bloated ivory egg sac with glowing pods behind a gold-crowned thorax.
ENEMIES.HiveBoss = function(b, c)
	local tail = { Anim = "Tail", Joint = V(0, 2.4, -0.4) }
	egg(b, V(5.1, 4.7, 7.8), c.Base, CFrame.new(0, 2.35, 3.3), tail)
	egg(b, V(4.4, 4.4, 1.0), c.Accent, CFrame.new(0, 2.2, 2.2), tail)
	egg(b, V(4.4, 4.4, 1.0), c.Accent, CFrame.new(0, 2.2, 4.6), tail)
	for i = 1, 5 do
		local a = i * 1.25
		ball(b, 0.9, c.Glow, V(math.cos(a) * 1.6, 3.6 + math.sin(a) * 0.6, 2.4 + i * 0.7), { Material = NEON, Anim = "Throb" })
	end
	egg(b, V(3.5, 3.0, 4.6), c.Metal, CFrame.new(0, 2.0, -2.5))
	egg(b, V(3.3, 1.6, 4.0), c.Gold, CFrame.new(0, 3.0, -2.8), { Material = METAL })
	bar(b, V(0, 1.7, -4.8), V(0, 1.6, -5.6), 1.4, c.Dark, { Anim = "Jaw", Joint = V(0, 1.8, -4.6) })
	for _, side in ipairs({ -1, 1 }) do
		ball(b, 0.5, c.Eye, V(side * 0.8, 2.36, -4.6), { Material = NEON })
		bar(b, V(side * 0.5, 2.9, -4.6), V(side * 1.7, 3.6, -5.6), 0.2, c.Dark, { Anim = "Wiggle", Joint = V(0, 2.9, -4.6) })
		for i, z in ipairs({ -3.4, -2.2, -1.0 }) do
			local anim = (((i - 1) % 2 == 0) == (side < 0)) and "SwingA" or "SwingB"
			local hip = V(side * 1.5, 1.4, z)
			bar(b, hip, V(side * 2.6, 0.05, z + ({ -0.6, 0, 0.6 })[i]), 0.45, c.Dark, { Anim = anim, Joint = hip })
		end
	end
	return "Prowl"
end

-- Briar Sentinel (fallback for the BriarSentinel mesh): a bramble treant on two root legs;
-- a dark bark trunk wrapped in vines with bone thorns, a moss mantle, a carved bark mask
-- with amber eyes under a crown of thorns, an amber heart-knot, long branch arms with twig
-- claws and a few amber berries.
ENEMIES.BriarBoss = function(b, c)
	-- root legs, each splaying into three roots on the ground
	for _, side in ipairs({ -1, 1 }) do
		local hip = V(side * 1.7, 5.2, 0.2)
		local anim = side < 0 and "SwingA" or "SwingB"
		bar(b, hip, V(side * 2.1, 1.6, 0), 1.6, c.Bark, { Anim = anim, Joint = hip })
		for k, r in ipairs({ { -1.6, -1.4 }, { 1.2, -0.3 }, { 0.1, 1.5 } }) do
			bar(b, V(side * 2.1, 1.7, 0), V(side * 2.1 + side * r[1] * 0.6 + r[1] * 0.3, 0.15, r[2] * 1.2), 0.75 - k * 0.08, c.Bark, { Anim = anim, Joint = hip })
		end
	end
	-- trunk and bark plates
	egg(b, V(5.2, 6.6, 4.2), c.Base, CFrame.new(0, 7.6, 0.2))
	egg(b, V(4.2, 3.0, 3.4), c.Light, CFrame.new(0, 8.4, -1.0))
	ball(b, 1.0, c.Berry, V(0, 8.6, -2.6), { Material = NEON, Anim = "Pulse" })
	for i, y in ipairs({ 6.0, 7.6, 9.2 }) do
		b.add("Block", V(0.35, 1.2, 0.4), c.Bark, CFrame.new((i - 2) * 0.9, y, -2.25) * CFrame.Angles(0, 0, 0.3 * (i - 2)))
	end
	-- moss mantle over the shoulders
	egg(b, V(6.8, 2.2, 4.8), c.Moss, CFrame.new(0, 10.3, 0.3))
	egg(b, V(2.6, 1.6, 2.6), c.Leaf, CFrame.new(-2.6, 10.6, 0.4))
	egg(b, V(2.4, 1.5, 2.4), c.Leaf, CFrame.new(2.7, 10.5, 0.2))
	-- thorny vines spiralling up the trunk
	for k = 0, 9 do
		local a = k * 1.15
		local y = 4.8 + k * 0.62
		local r = 2.35 - math.abs(k - 4.5) * 0.08
		local at = V(math.cos(a) * r, y, math.sin(a) * r * 0.85 + 0.2)
		ball(b, 0.55, c.Vine, at)
		if k % 2 == 0 then
			local out = V(math.cos(a), 0.15, math.sin(a)).Unit
			bar(b, at, at + out * 1.1, 0.22, c.Thorn)
		end
	end
	-- the mask, eyes and the thorn crown
	egg(b, V(3.0, 3.2, 2.6), c.Light, CFrame.new(0, 12.3, -0.7))
	b.add("Block", V(2.4, 0.35, 0.5), c.Bark, CFrame.new(0, 12.9, -1.95))
	for _, side in ipairs({ -1, 1 }) do
		ball(b, 0.55, c.Eye, V(side * 0.62, 12.35, -1.92), { Material = NEON })
	end
	b.add("Block", V(0.4, 1.2, 0.4), c.Bark, CFrame.new(0, 11.5, -1.95))
	for k = 0, 6 do
		local a = math.rad(-75 + k * 25)
		local base = V(math.sin(a) * 1.2, 13.4, -0.6 + math.cos(a) * 0.2)
		bar(b, base, base + V(math.sin(a) * 0.9, 1.4 + (k % 2) * 0.6, 0.3), 0.3, k % 3 == 1 and c.Gold or c.Thorn, k % 3 == 1 and { Material = METAL } or nil)
	end
	-- branch arms with twig claws
	for _, side in ipairs({ -1, 1 }) do
		local shoulder = V(side * 3.0, 10.0, 0)
		local reach = { Anim = side < 0 and "SwingB" or "SwingA", Joint = shoulder }
		local elbow = V(side * 4.7, 7.6, -0.9)
		local hand = V(side * 5.3, 4.4, -2.0)
		bar(b, shoulder, elbow, 1.15, c.Base, reach)
		bar(b, elbow, hand, 0.95, c.Bark, reach)
		egg(b, V(1.5, 1.4, 1.5), c.Moss, CFrame.new(elbow), reach)
		for k = -1, 1 do
			bar(b, hand, hand + V(side * 0.35 * k, -1.5, -0.6 + k * 0.5), 0.3, c.Bark, reach)
		end
		bar(b, elbow, elbow + V(side * 0.9, 0.8, -0.2), 0.22, c.Thorn, reach)
		ball(b, 0.6, c.Berry, V(side * 3.2, 11.1, -1.3))
		ball(b, 0.45, c.Berry, V(side * 2.2, 9.0, -2.1))
		egg(b, V(1.0, 0.3, 1.0), c.Gold, CFrame.new(side * 1.8, 11.3, -1.6), { Material = METAL })
	end
	return "Stomp"
end

-- Frostbound Colossus (fallback for the FrostboundColossus mesh): a hunched giant of dark
-- blue-grey stone, teal ice crystals jutting from his shoulders and back, a small head sunk
-- between them with pale glowing eyes and an icicle beard, huge arms and fists bound in ice. "Frost*" pieces are the phase-2
-- frost armour (shown only while the body attribute FrostArmor is set).
ENEMIES.FrostBoss = function(b, c)
	-- pillar legs
	for _, side in ipairs({ -1, 1 }) do
		local hip = V(side * 2.3, 5.4, 0.4)
		local anim = side < 0 and "SwingA" or "SwingB"
		bar(b, hip, V(side * 2.5, 1.2, 0.2), 2.4, c.Dark, { Anim = anim, Joint = hip })
		egg(b, V(3.0, 1.6, 3.4), c.Stone, CFrame.new(side * 2.5, 0.8, -0.2), { Anim = anim, Joint = hip })
	end
	-- the hunched torso
	egg(b, V(7.6, 5.0, 6.0), c.Dark, CFrame.new(0, 6.6, 0.6))
	egg(b, V(8.8, 5.2, 6.4), c.Base, CFrame.new(0, 9.4, 0.4))
	egg(b, V(5.6, 3.2, 2.4), c.Stone, CFrame.new(0, 8.6, -2.1))
	b.add("Block", V(7.0, 0.5, 0.6), c.Gold, CFrame.new(0, 6.8, -2.2), { Material = METAL })
	-- ice crystals on the shoulders and back
	for k, s in ipairs({ { -3.4, 11.6, 0.8, -0.35 }, { -2.2, 12.4, 1.6, -0.15 }, { 2.4, 12.3, 1.4, 0.2 }, { 3.5, 11.5, 0.6, 0.4 }, { 0, 12.0, 2.6, 0 }, { -1.0, 11.0, 3.2, -0.2 }, { 1.4, 10.8, 3.3, 0.25 } }) do
		local base = V(s[1], s[2] - 0.6, s[3])
		bar(b, base, base + V(s[4] * 2.4, 2.4 + (k % 3) * 0.7, 0.4), 0.9 - (k % 2) * 0.2, k % 2 == 0 and c.IceLight or c.Ice)
	end
	-- the head, sunk between the shoulders
	egg(b, V(2.8, 2.4, 2.6), c.Stone, CFrame.new(0, 10.9, -2.6))
	b.add("Block", V(2.6, 0.5, 0.8), c.Dark, CFrame.new(0, 11.6, -3.6))
	for _, side in ipairs({ -1, 1 }) do
		ball(b, 0.5, c.Eye, V(side * 0.6, 11.15, -3.75), { Material = NEON })
	end
	for k = -2, 2 do
		local top = V(k * 0.45, 10.2, -3.55)
		bar(b, top, top + V(0, -1.2 + math.abs(k) * 0.3, -0.25), 0.3, c.IceLight)
	end
	ball(b, 1.1, c.Glow, V(0, 8.4, -3.3), { Material = NEON, Anim = "Pulse" })
	-- huge arms, gold-banded wrists, fists
	for _, side in ipairs({ -1, 1 }) do
		local shoulder = V(side * 4.4, 10.2, 0.2)
		local swing = { Anim = side < 0 and "SwingB" or "SwingA", Joint = shoulder }
		egg(b, V(3.4, 3.0, 3.4), c.Base, CFrame.new(side * 4.6, 10.4, 0.2), swing)
		local elbow = V(side * 5.6, 6.9, -0.6)
		local wrist = V(side * 5.5, 3.9, -1.6)
		bar(b, shoulder, elbow, 2.0, c.Dark, swing)
		bar(b, elbow, wrist, 1.9, c.Base, swing)
		bar(b, wrist + V(0, 0.6, 0.2), wrist + V(0, 0.1, 0.05), 2.3, c.Gold, { Anim = swing.Anim, Joint = shoulder, Material = METAL })
		egg(b, V(2.8, 2.6, 2.8), c.Stone, CFrame.new(wrist + V(0, -1.2, -0.4)), swing)
		bar(b, elbow, elbow + V(side * 1.2, 1.1, 0.4), 0.6, c.Ice, swing)
	end
	-- frost armour (phase 2): ice plates over the chest, shoulders and forearms
	local function frost(part: BasePart, name: string)
		part.Name = name
	end
	frost(egg(b, V(6.4, 3.6, 1.4), c.IceLight, CFrame.new(0, 8.4, -3.0), { Transparency = 0.15 }), "FrostChest")
	for _, side in ipairs({ -1, 1 }) do
		local shoulder = V(side * 4.4, 10.2, 0.2)
		local swing = { Anim = side < 0 and "SwingB" or "SwingA", Joint = shoulder, Transparency = 0.15 }
		frost(egg(b, V(3.8, 1.6, 3.8), c.IceLight, CFrame.new(side * 4.7, 11.9, 0.2), swing), "FrostShoulder")
		frost(egg(b, V(2.6, 3.4, 2.6), c.IceLight, CFrame.new(side * 5.55, 5.4, -1.1), swing), "FrostArm")
		frost(bar(b, V(side * 4.7, 12.4, 0.2), V(side * 5.6, 14.4, 0.6), 0.7, c.IceLight, swing), "FrostSpike")
	end
	return "Stomp"
end

-- Thorn Sprout (fallback for the ThornSprout mesh): a small bark bulb with a moss cap,
-- bone thorns, two leaf blades and root feet.
ENEMIES.ThornSprout = function(b, c)
	egg(b, V(2.2, 2.0, 2.2), c.Base, CFrame.new(0, 1.2, 0))
	egg(b, V(1.6, 0.8, 1.6), c.Light, CFrame.new(0, 2.1, 0))
	for k = 0, 5 do
		local a = k * TAU_ML / 6 + 0.3
		local at = V(math.cos(a) * 1.0, 1.3 + (k % 2) * 0.35, math.sin(a) * 1.0)
		bar(b, at, at + V(math.cos(a) * 0.7, 0.25, math.sin(a) * 0.7), 0.2, c.Thorn)
	end
	for _, side in ipairs({ -1, 1 }) do
		local root = V(side * 0.3, 2.4, 0.1)
		egg(b, V(0.3, 0.12, 1.6), c.Leaf, CFrame.new(side * 0.8, 2.9, 0.1) * CFrame.Angles(0, 0, side * 0.6), { Anim = "Wiggle", Joint = root })
		ball(b, 0.38, c.Eye, V(side * 0.42, 1.45, -1.0), { Material = NEON })
		local hip = V(side * 0.6, 0.6, 0)
		bar(b, hip, V(side * 1.1, 0.05, -0.3), 0.3, c.Dark, { Anim = side < 0 and "SwingA" or "SwingB", Joint = hip })
		bar(b, hip, V(side * 1.0, 0.05, 0.6), 0.3, c.Dark, { Anim = side < 0 and "SwingB" or "SwingA", Joint = hip })
	end
	return "Scuttle"
end

-- Burrower: a sandy mole-cricket with digging claws, sitting in a ring of loose soil
-- ("Mound": shown while it tunnels, hidden once it is out).
ENEMIES.Burrower = function(b, c)
	egg(b, V(1.4, 1.3, 2.6), c.Base, CFrame.new(0, 0.8, 1.0))
	egg(b, V(1.7, 1.1, 1.6), c.Accent, CFrame.new(0, 1.0, -0.6))
	egg(b, V(1.0, 0.8, 0.9), c.Dark, CFrame.new(0, 0.75, -1.5))
	ball(b, 0.22, c.Eye, V(-0.3, 0.9, -1.85), { Material = NEON })
	ball(b, 0.22, c.Eye, V(0.3, 0.9, -1.85), { Material = NEON })
	for _, side in ipairs({ -1, 1 }) do
		local shoulder = V(side * 0.7, 0.7, -1.2)
		egg(b, V(1.3, 0.7, 1.2), c.Accent, CFrame.new(side * 1.25, 0.6, -1.7), { Anim = "Jaw", Joint = shoulder })
		local hip = V(side * 0.6, 0.6, 0.4)
		bar(b, hip, V(side * 1.4, 0.05, 0.9), 0.2, c.Dark, { Anim = side < 0 and "SwingA" or "SwingB", Joint = hip })
	end
	local mound = b.add("Cylinder", V(0.45, 4.4, 4.4), c.Stone, CFrame.new(0, 0.22, 0) * CYL_UP)
	mound.Name = "Mound"
	return "Scuttle"
end

-- Healer: a pale aphid with green stripes and a slowly spinning glowing halo.
ENEMIES.Healer = function(b, c)
	egg(b, V(1.8, 1.6, 2.5), c.Base, CFrame.new(0, 1.0, 0.1))
	egg(b, V(1.85, 0.6, 0.75), c.Light, CFrame.new(0, 1.5, 0.4))
	egg(b, V(0.6, 0.64, 0.66), c.Dark, CFrame.new(0, 0.8, -1.27))
	ball(b, 0.16, c.Eye, V(-0.18, 0.92, -1.45), { Material = NEON })
	ball(b, 0.16, c.Eye, V(0.18, 0.92, -1.45), { Material = NEON })
	ball(b, 0.7, c.Glow, V(0, 1.82, 0.8), { Material = NEON, Anim = "Pulse" })
	local halo = b.add("Cylinder", V(0.2, 2.0, 2.0), c.Glow, CFrame.new(0, 2.62, 0.1) * CYL_UP, { Material = NEON, Anim = "Spin" })
	halo.Name = "Halo"
	for _, side in ipairs({ -1, 1 }) do
		egg(b, V(1.0, 0.1, 0.6), c.White, CFrame.new(side * 0.8, 1.67, -0.7), { Anim = side < 0 and "FlutterL" or "FlutterR", Joint = V(side * 0.3, 1.67, -0.7), Transparency = 0.45 })
		local hip = V(side * 0.5, 0.6, -0.4)
		bar(b, hip, V(side * 1.2, 0.05, -0.8), 0.15, c.Dark, { Anim = side < 0 and "SwingA" or "SwingB", Joint = hip })
	end
	return "Scuttle"
end

-- Nest: a wax-rimmed mound of earth with two dark openings and glowing eggs at its foot.
ENEMIES.Nest = function(b, c)
	b.add("Cylinder", V(0.4, 5.2, 4.7), c.Stone, CFrame.new(0, 0.2, 0) * CYL_UP)
	egg(b, V(4.4, 3.8, 4.0), c.Base, CFrame.new(0, 1.9, 0.2))
	egg(b, V(4.0, 1.4, 3.9), c.Accent, CFrame.new(0, 1.5, 0.16))
	egg(b, V(1.4, 1.6, 0.6), c.Dark, CFrame.new(0, 1.4, -1.85))
	egg(b, V(0.6, 1.6, 1.4), c.Dark, CFrame.new(-1.95, 1.4, -0.2))
	for i = -1, 1 do
		ball(b, 0.7, c.Light, V(i * 1.2, 0.5, -1.6), { Anim = "Pulse" })
		ball(b, 0.4, c.Glow, V(i * 1.2, 0.62, -1.75), { Material = NEON, Anim = "Pulse" })
	end
	b.add("Cylinder", V(0.2, 0.6, 0.6), c.Glow, CFrame.new(0, 3.86, 0.05) * CYL_UP, { Material = NEON, Anim = "Throb" })
	return "Static"
end

-- War Banner: a crimson banner on a wooden pole with a gold crown, in a stone foot.
ENEMIES.WarBanner = function(b, c)
	b.add("Cylinder", V(0.6, 3.0, 3.0), c.Stone, CFrame.new(0, 0.3, 0) * CYL_UP)
	b.add("Block", V(0.4, 9.2, 0.4), c.Wood, CFrame.new(0, 4.6, 0))
	b.add("Block", V(4.4, 0.35, 0.4), c.Gold, CFrame.new(0, 8.6, 0), { Material = METAL })
	b.add("Block", V(3.8, 5.0, 0.14), c.Cloth, CFrame.new(0, 6.0, 0.2), { Anim = "Tail", Pivot = CFrame.new(0, 2.6, 0) })
	b.add("Block", V(1.6, 1.0, 0.3), c.Gold, CFrame.new(0, 7.2, 0.3), { Material = METAL, Anim = "Tail", Pivot = CFrame.new(0, 1.4, 0) })
	ball(b, 0.7, c.Gold, V(0, 9.4, 0), { Material = METAL })
	return "Static"
end

-- Brood Egg: an ivory egg with gold spots and a glowing core showing through.
ENEMIES.BroodEgg = function(b, c)
	egg(b, V(2.0, 2.6, 2.0), c.Base, CFrame.new(0, 1.3, 0))
	ball(b, 0.55, c.Accent, V(0.72, 1.6, -0.5))
	ball(b, 0.5, c.Accent, V(-0.78, 1.15, -0.3))
	ball(b, 0.45, c.Accent, V(0.15, 2.1, 0.7))
	egg(b, V(1.1, 1.4, 1.1), c.Glow, CFrame.new(0, 1.3, 0), { Material = NEON, Transparency = 0.55 })
	return "Static"
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
	local extra = MESH_EXTRA[typeId]
	local meshScale = scale * (extra and extra.Scale or 1)
	local motion = meshInfo and meshInfo[2] or "Scuttle"
	local pieces: { Piece }? = meshInfo and ModelLibrary.MeshPieces(meshInfo[1], nil, meshScale, lift) or nil
	if pieces and #pieces == 0 then
		pieces = nil -- a template folder without its pieces: the part-built fallback instead
	end
	if pieces and extra and extra.Only then
		-- one part of a bigger model (the War Banner from the Warlord's back)
		local keep: { Piece } = {}
		local shift = (extra.Shift or Vector3.zero) * meshScale
		for _, piece in ipairs(pieces) do
			if table.find(extra.Only, piece.Part.Name) then
				piece.Offset = CFrame.new(shift) * piece.Offset
				table.insert(keep, piece)
			else
				piece.Part:Destroy()
			end
		end
		pieces = keep
	end
	if pieces and meshInfo then
		local entry = MeshCatalog.Models[meshInfo[1]]
		local bounds = (entry :: any).Bounds
		if bounds then
			top = lift + bounds[2][2] * meshScale
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

-- Arrow along Z, tip toward -Z: wooden shaft, steel head, two-tone fletching (the
-- part-built stand-in for the "Shot_Arrow" mesh).
local function arrow(b, shaft: Color3, head: Color3, fletch: Color3, glow: boolean)
	b.add("Cylinder", Vector3.new(2.6, 0.14, 0.14), shaft, CFrame.new(0, 0, 0.1) * CFrame.Angles(0, math.rad(90), 0), glow and { Material = SHOT_NEON } or nil)
	b.add("Wedge", Vector3.new(0.12, 0.34, 0.5), head, CFrame.new(0, 0, -1.4) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(math.rad(-90), 0, 0), { Material = glow and SHOT_NEON or SHOT_METAL })
	for _, rot in ipairs({ 0, 90 }) do
		b.add("Block", Vector3.new(0.04, 0.32, 0.5), fletch, CFrame.new(0, 0, 1.2) * CFrame.Angles(0, 0, math.rad(rot)))
	end
end
SHOTS[20] = function(b, _def)
	arrow(b, SHOT.Wood, SHOT.Steel, ShotPalette.ivory_100, false)
end
SHOTS[21] = function(b, _def)
	arrow(b, ShotPalette.moss_300, ShotPalette.gold_300, ShotPalette.moss_200, true)
end

--[[
	Part-built stand-ins for the weapons added with the Alchemist / Engineer / Necromancer
	(the meshes Shot_Spear, Shot_Bolt, Shot_FrostShard, Shot_Totem, Shot_Hook, Shot_Soul,
	Ability_Turret, Shot_Fire replace them once loaded). Same orientation as the meshes:
	front = -Z; the totem and the turret stand on the ground (origin = ground centre); the
	turret's head pieces carry Anim = "Spin" with a pivot on its turning axis (VFX aims them).
]]
local function spear(b, shaft: Color3, tip: Color3, collar: Color3, glow: boolean)
	b.add("Cylinder", Vector3.new(2.4, 0.14, 0.14), shaft, CFrame.new(0, 0, 0.35) * CFrame.Angles(0, math.rad(90), 0))
	b.add("Wedge", Vector3.new(0.12, 0.4, 0.8), tip, CFrame.new(0, 0, -1.12) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(math.rad(-90), 0, 0), { Material = glow and SHOT_NEON or SHOT_METAL })
	b.add("Cylinder", Vector3.new(0.18, 0.22, 0.22), collar, CFrame.new(0, 0, -0.62) * CFrame.Angles(0, math.rad(90), 0), { Material = SHOT_METAL })
	b.add("Cylinder", Vector3.new(0.5, 0.2, 0.2), ShotPalette.leather_600, CFrame.new(0, 0, 0.45) * CFrame.Angles(0, math.rad(90), 0))
end

local function bolt(b, shaft: Color3, head: Color3, fletch: Color3, s: number, glow: boolean)
	b.add("Cylinder", Vector3.new(1.3 * s, 0.1 * s, 0.1 * s), shaft, CFrame.new(0, 0, 0.16 * s) * CFrame.Angles(0, math.rad(90), 0))
	b.add("Wedge", Vector3.new(0.1 * s, 0.22 * s, 0.43 * s), head, CFrame.new(0, 0, -0.66 * s) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(math.rad(-90), 0, 0), { Material = glow and SHOT_NEON or SHOT_METAL })
	b.add("Block", Vector3.new(0.04 * s, 0.34 * s, 0.5 * s), fletch, CFrame.new(0, 0.05 * s, 0.61 * s))
	b.add("Block", Vector3.new(0.38 * s, 0.04 * s, 0.5 * s), fletch, CFrame.new(0, 0.05 * s, 0.61 * s))
end

local function shard(b, ice: Color3, glow: Color3)
	b.add("Wedge", Vector3.new(0.46, 0.58, 1.6), ice, CFrame.new(0, 0, -0.05) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(math.rad(-90), 0, 0), { Transparency = 0.2 })
	b.add("Ball", Vector3.new(0.24, 0.26, 0.4), glow, CFrame.new(0, 0, -0.3), { Material = SHOT_NEON })
end

local function totem(b, wood: Color3, carving: Color3, gold: Color3, glow: Color3)
	b.add("Block", Vector3.new(0.76, 2.85, 0.74), wood, CFrame.new(0, 0.82, 0))
	b.add("Block", Vector3.new(1.8, 0.95, 0.65), carving, CFrame.new(0, 1.46, 0))
	b.add("Block", Vector3.new(0.43, 0.38, 0.06), ShotPalette.chitin_900, CFrame.new(0, 1.38, -0.34))
	b.add("Block", Vector3.new(0.64, 0.5, 0.55), gold, CFrame.new(0, 2.5, 0), { Material = SHOT_METAL })
	b.add("Ball", Vector3.new(0.56, 0.6, 0.56), glow, CFrame.new(0, 2.85, 0), { Material = SHOT_NEON })
end

local function hook(b, metal: Color3, chain: Color3)
	b.add("Block", Vector3.new(0.18, 0.2, 1.1), metal, CFrame.new(0, 0, 0.1), { Material = SHOT_METAL })
	b.add("Block", Vector3.new(0.6, 0.2, 0.18), metal, CFrame.new(-0.25, 0, -0.45), { Material = SHOT_METAL })
	b.add("Wedge", Vector3.new(0.2, 0.18, 0.5), metal, CFrame.new(-0.5, 0, -0.25) * CFrame.Angles(0, math.rad(180), 0), { Material = SHOT_METAL })
	b.add("Cylinder", Vector3.new(0.12, 0.25, 0.25), chain, CFrame.new(0, 0, 0.75) * CFrame.Angles(0, 0, math.rad(90)), { Material = SHOT_METAL })
end

local function soul(b, glow: Color3, wisp: Color3)
	b.add("Ball", Vector3.new(0.9, 0.9, 0.95), ShotPalette.ivory_200, CFrame.new(0, 0.05, -0.45))
	b.add("Block", Vector3.new(0.52, 0.16, 0.12), glow, CFrame.new(0, 0.12, -0.9), { Material = SHOT_NEON })
	b.add("Ball", Vector3.new(0.62, 0.58, 2.0), wisp, CFrame.new(0, 0.23, 0.7), { Transparency = 0.45 })
end

local function turret(b, metal: Color3, dark: Color3, gold: Color3, glow: Color3)
	local aim = { Anim = "Spin" }
	b.add("Cylinder", Vector3.new(1.0, 2.2, 2.2), dark, CFrame.new(0, 0.5, 0.1) * CYL_UP, { Material = SHOT_METAL })
	b.add("Block", Vector3.new(0.6, 0.6, 0.6), dark, CFrame.new(0, 1.3, 0), { Material = SHOT_METAL })
	b.add("Block", Vector3.new(1.25, 0.85, 1.25), metal, CFrame.new(0, 1.84, 0), { Material = SHOT_METAL, Anim = aim.Anim, Pivot = CFrame.new(0, -0.24, 0) })
	b.add("Cylinder", Vector3.new(1.2, 0.36, 0.36), gold, CFrame.new(0, 1.8, -0.9) * CFrame.Angles(0, math.rad(90), 0), { Material = SHOT_METAL, Anim = aim.Anim, Pivot = CFrame.new(0, -0.2, 0.9) })
	b.add("Ball", Vector3.new(0.22, 0.22, 0.22), glow, CFrame.new(0, 1.8, -1.52), { Material = SHOT_NEON, Anim = aim.Anim, Pivot = CFrame.new(0, -0.2, 1.52) })
	b.add("Block", Vector3.new(0.25, 0.28, 0.24), ShotPalette.crimson_500, CFrame.new(0, 2.38, -0.4), { Anim = aim.Anim, Pivot = CFrame.new(0, -0.78, 0.4) })
end

local function flame(b, outer: Color3, core: Color3)
	b.add("Ball", Vector3.new(0.82, 0.82, 1.6), outer, CFrame.new(0, 0, 0.23), { Material = SHOT_NEON, Transparency = 0.15 })
	b.add("Ball", Vector3.new(0.43, 0.48, 1.0), core, CFrame.new(0, 0, 0.05), { Material = SHOT_NEON })
end

SHOTS[22] = function(b, _def)
	spear(b, SHOT.Haft, SHOT.Steel, SHOT.Gold, false)
end
SHOTS[23] = function(b, _def)
	spear(b, SHOT.CrimsonDark, ShotPalette.gold_200, SHOT.Gold, true)
end
SHOTS[24] = function(b, _def)
	bolt(b, ShotPalette.wood_600, SHOT.Steel, SHOT.Crimson, 1, false)
end
SHOTS[25] = function(b, _def)
	bolt(b, SHOT.CrimsonDark, ShotPalette.crimson_300, ShotPalette.gold_300, 1, true)
end
SHOTS[26] = function(b, _def)
	shard(b, ShotPalette.ice_300, ShotPalette.ice_100)
end
SHOTS[27] = function(b, _def)
	totem(b, ShotPalette.wood_500, ShotPalette.wood_400, SHOT.Gold, ShotPalette.fx_heal)
end
SHOTS[28] = function(b, _def)
	totem(b, ShotPalette.wood_500, ShotPalette.gold_500, ShotPalette.gold_300, ShotPalette.fx_gold)
end
SHOTS[29] = function(b, _def)
	hook(b, ShotPalette.steel_400, ShotPalette.steel_600)
end
SHOTS[30] = function(b, _def)
	hook(b, ShotPalette.crimson_400, ShotPalette.crimson_800)
end
SHOTS[31] = function(b, _def)
	soul(b, ShotPalette.fx_heal, ShotPalette.moss_100)
end
SHOTS[32] = function(b, _def)
	soul(b, ShotPalette.crimson_300, ShotPalette.crimson_300)
end
SHOTS[33] = function(b, _def)
	turret(b, ShotPalette.steel_400, ShotPalette.steel_600, SHOT.Gold, ShotPalette.fx_gold)
end
SHOTS[34] = function(b, _def)
	turret(b, ShotPalette.gold_400, ShotPalette.steel_600, SHOT.Crimson, ShotPalette.fx_gold)
end
SHOTS[35] = function(b, _def)
	bolt(b, ShotPalette.steel_600, ShotPalette.gold_300, SHOT.Gold, 0.75, false)
end
SHOTS[36] = function(b, _def)
	shard(b, ShotPalette.ice_100, ShotPalette.fx_holy)
end
SHOTS[37] = function(b, _def)
	flame(b, ShotPalette.fx_fire, ShotPalette.amber_300)
end
SHOTS[38] = function(b, _def)
	flame(b, ShotPalette.gold_300, ShotPalette.ivory_100)
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
	-- Longbow / Windpiercer arrows: the mesh when "Shot_Arrow" is in the catalog and loaded,
	-- else SHOTS[20] / SHOTS[21] (MeshPieces returns nil for a missing model)
	[20] = { "Shot_Arrow", nil },
	[21] = { "Shot_Arrow", { Wood = ShotPalette.moss_300, Blade = ShotPalette.gold_300, Accent = ShotPalette.moss_200, Gold = ShotPalette.gold_200 } },
	-- the Alchemist / Engineer / Necromancer weapons (a third value = model scale: spears,
	-- totems and turrets are drawn larger than their catalog size so they read next to a hero)
	[22] = { "Shot_Spear", nil, 1.5 },
	[23] = { "Shot_Spear", { Tip = ShotPalette.gold_200, Shaft = SHOT.CrimsonDark, Gold = SHOT.Gold, Wrap = ShotPalette.crimson_500 }, 1.6 },
	[24] = { "Shot_Bolt", nil },
	[25] = { "Shot_Bolt", { Head = ShotPalette.crimson_300, Shaft = SHOT.CrimsonDark, Fletch = ShotPalette.gold_300 } },
	[26] = { "Shot_FrostShard", nil },
	[27] = { "Shot_Totem", nil, 1.5 },
	[28] = { "Shot_Totem", { Wood2 = ShotPalette.gold_500, Gold = ShotPalette.gold_300, Leaf = ShotPalette.gold_400, Glow = ShotPalette.fx_gold }, 1.6 },
	[29] = { "Shot_Hook", nil },
	[30] = { "Shot_Hook", { Hook = ShotPalette.crimson_400, Chain = ShotPalette.crimson_800 } },
	[31] = { "Shot_Soul", nil },
	[32] = { "Shot_Soul", { Glow = ShotPalette.crimson_300, Light = ShotPalette.crimson_300 } },
	[33] = { "Ability_Turret", nil, 1.6 },
	[34] = { "Ability_Turret", { Metal = ShotPalette.gold_400, MetalDark = ShotPalette.steel_600, Gold = ShotPalette.crimson_500, Glow = ShotPalette.fx_gold }, 1.7 },
	[35] = { "Shot_Bolt", { Head = ShotPalette.gold_300, Shaft = ShotPalette.steel_600, Fletch = ShotPalette.gold_500 }, 0.75 },
	[36] = { "Shot_FrostShard", { Ice = ShotPalette.ice_100, Ice2 = ShotPalette.fx_holy, Glow = ShotPalette.fx_holy } },
	[37] = { "Shot_Fire", nil },
	[38] = { "Shot_Fire", { Flame = ShotPalette.gold_300, Core = ShotPalette.ivory_100, Ember = ShotPalette.fx_gold } },
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
		local meshPieces = ModelLibrary.MeshPieces(mesh[1], mesh[2], mesh[3] or 1, 0)
		if meshPieces then
			return meshPieces
		end
	end
	local def = WeaponData.Visuals[visual] or WeaponData.Visuals[1]
	local b = builder(mesh and mesh[3] or 1) -- stand-ins match the mesh scale
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

-- Like PieceCFrame, with the model scaled by s around the body centre (swelling poses).
function ModelLibrary.PieceCFrameScaled(bodyCF: CFrame, piece: Piece, t: number, phase: number, move: number, s: number): CFrame
	local off = piece.Offset
	local cf = bodyCF * CFrame.new(off.Position * s) * off.Rotation
	if piece.Anim then
		local rot = ModelLibrary.Animate(piece.Anim, t, phase, move)
		local pivot = piece.Pivot
		if pivot then
			local pv = CFrame.new(pivot.Position * s) * pivot.Rotation
			cf = cf * pv * rot * pv:Inverse()
		else
			cf = cf * rot
		end
	end
	return cf
end

--[[
	Elite affix aura (EliteAura_Burning / _Shield / _Swift meshes when loaded, else a part
	ring with the same read): pieces around the body centre, spinning with "Spin". radius =
	the enemy's body radius; halfHeight lifts the ground-origin model onto the body centre.
]]
local AURA_MESH = { Burning = "EliteAura_Burning", Shielded = "EliteAura_Shield", Swift = "EliteAura_Swift" }

function ModelLibrary.AuraMeshName(affix: string): string?
	return AURA_MESH[affix]
end

function ModelLibrary.Aura(affix: string, radius: number, halfHeight: number): { Piece }
	local s = radius / 1.4 -- the aura meshes are authored for a body of radius ~1.4
	local meshName = AURA_MESH[affix]
	local pieces = meshName and ModelLibrary.MeshPieces(meshName, nil, s, -halfHeight) or nil
	if pieces then
		return pieces
	end
	local b = builder(1)
	local function spinPiece(shape: string, size: Vector3, color: Color3, cf: CFrame, opts: { [string]: any }?)
		local o = table.clone(opts or {})
		o.Anim = "Spin"
		o.Pivot = cf:Inverse() * CFrame.new(0, cf.Position.Y, 0) -- spin around the body axis
		b.add(shape, size, color, cf, o)
	end
	local r = 1.6 * s
	local base = -halfHeight
	if affix == "Burning" then
		for i = 1, 10 do
			local a = i * math.pi * 2 / 10
			local h = (i % 2 == 0) and 1.1 or 0.75
			local cf = CFrame.new(math.cos(a) * r, base + h * s / 2, math.sin(a) * r) * CFrame.Angles(0, -a, 0)
			spinPiece("Wedge", V(0.3, h, 0.45) * s, (i % 2 == 0) and Palette.fx_fire or Palette.amber_300, cf, { Material = NEON, Transparency = 0.1 })
		end
	elseif affix == "Shielded" then
		for i = 1, 3 do
			local a = i * math.pi * 2 / 3
			local rr = r + 0.35 * s
			local cf = CFrame.lookAt(V(math.cos(a) * rr, base + 1.3 * s, math.sin(a) * rr), V(math.cos(a) * rr * 2, base + 1.3 * s, math.sin(a) * rr * 2))
			spinPiece("Block", V(1.15, 1.15, 0.1) * s, Palette.slate_200:Lerp(Palette.fx_arcane, 0.3), cf, { Material = METAL, Transparency = 0.25 })
			spinPiece("Block", V(1.3, 0.12, 0.14) * s, Palette.gold_400, cf * CFrame.new(0, 0.6 * s, 0), { Material = METAL })
		end
	else -- Swift
		for i = 1, 3 do
			local a = i * math.pi * 2 / 3
			local y = base + (0.35 + (i - 1) * 0.7) * s
			local cf = CFrame.new(math.cos(a) * (r + 0.2 * s), y, math.sin(a) * (r + 0.2 * s)) * CFrame.Angles(0, -a, 0)
			spinPiece("Block", V(0.12, 0.1, 2.2) * s, Palette.ivory_100, cf, { Transparency = 0.35 })
			spinPiece("Ball", V(0.22, 0.22, 0.22) * s, Palette.fx_bolt, cf * CFrame.new(0, 0, -1.1 * s), { Material = NEON })
		end
	end
	return b.pieces
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
