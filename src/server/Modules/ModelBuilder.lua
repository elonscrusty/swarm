--[[
	ModelBuilder.lua
	Builds every model in the game from plain Parts and built-in SpecialMesh types:
	player characters (blocky humanoids + hats), enemy shells (single Part), gems,
	floor pickups and treasure chests. No external assets.
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local CharacterData = require(game:GetService("ReplicatedStorage").Shared.CharacterData)
local MeshCatalog = require(game:GetService("ReplicatedStorage").Shared.MeshCatalog)
local MeshService = require(script.Parent.MeshService)

local ModelBuilder = {}

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function part(props: { [string]: any }): BasePart
	local p: BasePart
	if props.Shape then
		local pp = Instance.new("Part")
		pp.Shape = props.Shape
		p = pp
	elseif props.Wedge then
		p = Instance.new("WedgePart")
	else
		p = Instance.new("Part")
	end
	p.Anchored = props.Anchored ~= false
	p.CanCollide = props.CanCollide == true
	p.CanTouch = false
	p.CanQuery = props.CanQuery == true
	p.CastShadow = props.CastShadow == true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = props.Size or Vector3.one
	p.Color = props.Color or Color3.new(1, 1, 1)
	p.Material = props.Material or Enum.Material.SmoothPlastic
	p.Transparency = props.Transparency or 0
	p.Name = props.Name or "Part"
	if props.CFrame then
		p.CFrame = props.CFrame
	end
	return p
end
ModelBuilder.Part = part

-- Welds `child` to `base` keeping their current relative placement.
local function weld(base: BasePart, child: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = base
	w.Part1 = child
	w.Parent = child
end
ModelBuilder.Weld = weld

local function motor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame): Motor6D
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = part0
	m.Part1 = part1
	m.C0 = c0
	m.C1 = c1
	m.Parent = part0
	return m
end

------------------------------------------------------------------------------------------
-- Hats (all built relative to the head's top centre, welded to the head)
------------------------------------------------------------------------------------------

type HatFn = (head: BasePart, model: Model, color: Color3, accent: Color3, lift: number?) -> ()

local function hatPart(head: BasePart, model: Model, props, offset: CFrame)
	props.Anchored = false
	local p = part(props)
	p.Massless = true
	p.CFrame = head.CFrame * offset
	p.Parent = model
	weld(head, p)
	return p
end

local TOP = 0.6 -- head is 1.2 studs tall

ModelBuilder.HatShapes = {
	Helmet = function(head, model, color, accent)
		hatPart(head, model, { Name = "Helmet", Size = Vector3.new(1.45, 0.9, 1.45), Color = color, Material = Enum.Material.Metal }, CFrame.new(0, TOP - 0.25, 0))
		hatPart(head, model, { Name = "Visor", Size = Vector3.new(1.2, 0.18, 0.12), Color = Color3.fromRGB(30, 30, 35) }, CFrame.new(0, 0.05, -0.68))
		hatPart(head, model, { Name = "Crest", Size = Vector3.new(0.2, 0.5, 1.2), Color = accent }, CFrame.new(0, TOP + 0.4, 0))
	end,
	Wizard = function(head, model, color, accent)
		hatPart(head, model, { Name = "Brim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.15, 2.4, 2.4), Color = color }, CFrame.new(0, TOP + 0.05, 0) * CFrame.Angles(0, 0, math.rad(90)))
		local h = TOP + 0.1
		for i, s in ipairs({ 1.3, 1.0, 0.7, 0.4 }) do
			hatPart(head, model, { Name = "Tier" .. i, Size = Vector3.new(s, 0.45, s), Color = color }, CFrame.new(0.05 * i, h + 0.22, 0) * CFrame.Angles(0, 0, math.rad(-4 * i)))
			h += 0.42
		end
		hatPart(head, model, { Name = "Band", Size = Vector3.new(1.35, 0.15, 1.35), Color = accent }, CFrame.new(0, TOP + 0.2, 0))
	end,
	Hood = function(head, model, color, _accent)
		hatPart(head, model, { Name = "Hood", Shape = Enum.PartType.Ball, Size = Vector3.new(1.6, 1.6, 1.6), Color = color }, CFrame.new(0, 0.15, 0.15))
		hatPart(head, model, { Name = "HoodTip", Wedge = true, Size = Vector3.new(0.8, 0.6, 0.8), Color = color }, CFrame.new(0, 0.6, 0.75) * CFrame.Angles(0, math.rad(180), 0))
	end,
	Mitre = function(head, model, color, accent)
		hatPart(head, model, { Name = "Mitre", Size = Vector3.new(1.1, 1.0, 0.9), Color = color }, CFrame.new(0, TOP + 0.5, 0))
		hatPart(head, model, { Name = "MitreTopF", Wedge = true, Size = Vector3.new(1.1, 0.5, 0.45), Color = color }, CFrame.new(0, TOP + 1.25, -0.225))
		hatPart(head, model, { Name = "MitreTopB", Wedge = true, Size = Vector3.new(1.1, 0.5, 0.45), Color = color }, CFrame.new(0, TOP + 1.25, 0.225) * CFrame.Angles(0, math.rad(180), 0))
		hatPart(head, model, { Name = "Cross", Size = Vector3.new(0.12, 0.6, 0.05), Color = accent }, CFrame.new(0, TOP + 0.55, -0.47))
		hatPart(head, model, { Name = "CrossBar", Size = Vector3.new(0.4, 0.12, 0.05), Color = accent }, CFrame.new(0, TOP + 0.65, -0.47))
	end,
	Crown = function(head, model, color, accent, lift)
		local y = TOP + (lift or 0)
		hatPart(head, model, { Name = "CrownBand", Size = Vector3.new(1.3, 0.35, 1.3), Color = color, Material = Enum.Material.Metal }, CFrame.new(0, y + 0.15, 0))
		for i = 0, 3 do
			local a = i * math.pi / 2
			hatPart(head, model, { Name = "Spike" .. i, Size = Vector3.new(0.3, 0.45, 0.3), Color = color, Material = Enum.Material.Metal }, CFrame.new(math.cos(a) * 0.5, y + 0.5, math.sin(a) * 0.5) * CFrame.Angles(0, a + math.pi / 4, 0))
		end
		hatPart(head, model, { Name = "Jewel", Shape = Enum.PartType.Ball, Size = Vector3.new(0.3, 0.3, 0.3), Color = accent, Material = Enum.Material.Neon }, CFrame.new(0, y + 0.2, -0.66))
	end,
	Tophat = function(head, model, color, accent)
		hatPart(head, model, { Name = "Brim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.12, 1.9, 1.9), Color = color }, CFrame.new(0, TOP + 0.05, 0) * CFrame.Angles(0, 0, math.rad(90)))
		hatPart(head, model, { Name = "Crown", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.1, 1.2, 1.2), Color = color }, CFrame.new(0, TOP + 0.6, 0) * CFrame.Angles(0, 0, math.rad(90)))
		hatPart(head, model, { Name = "Band", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 1.25, 1.25), Color = accent }, CFrame.new(0, TOP + 0.2, 0) * CFrame.Angles(0, 0, math.rad(90)))
	end,
	Horns = function(head, model, color, accent)
		hatPart(head, model, { Name = "Helmet", Size = Vector3.new(1.4, 0.7, 1.4), Color = color, Material = Enum.Material.Metal }, CFrame.new(0, TOP - 0.15, 0))
		for _, side in ipairs({ -1, 1 }) do
			hatPart(head, model, { Name = "HornBase", Size = Vector3.new(0.3, 0.3, 0.3), Color = accent }, CFrame.new(side * 0.8, TOP, 0))
			hatPart(head, model, { Name = "Horn", Wedge = true, Size = Vector3.new(0.25, 0.8, 0.4), Color = accent }, CFrame.new(side * 0.95, TOP + 0.45, 0) * CFrame.Angles(0, math.rad(side * 90), math.rad(side * -15)))
		end
	end,
	Halo = function(head, model, _color, accent)
		for i = 0, 7 do
			local a = i * math.pi / 4
			hatPart(head, model, { Name = "Halo" .. i, Size = Vector3.new(0.45, 0.12, 0.15), Color = accent, Material = Enum.Material.Neon }, CFrame.new(math.cos(a) * 0.65, TOP + 0.55, math.sin(a) * 0.65) * CFrame.Angles(0, -a + math.pi / 2, 0))
		end
	end,
	Plume = function(head, model, color, accent)
		hatPart(head, model, { Name = "Helmet", Size = Vector3.new(1.45, 0.9, 1.45), Color = color, Material = Enum.Material.Metal }, CFrame.new(0, TOP - 0.25, 0))
		hatPart(head, model, { Name = "Visor", Size = Vector3.new(1.2, 0.18, 0.12), Color = Color3.fromRGB(30, 30, 35) }, CFrame.new(0, 0.05, -0.68))
		for i = 0, 2 do
			hatPart(head, model, { Name = "Plume" .. i, Shape = Enum.PartType.Ball, Size = Vector3.new(0.5, 0.6, 0.6), Color = accent }, CFrame.new(0, TOP + 0.35 + i * 0.15, 0.25 * i))
		end
	end,
	Bandana = function(head, model, color, accent)
		hatPart(head, model, { Name = "Bandana", Size = Vector3.new(1.3, 0.45, 1.3), Color = color }, CFrame.new(0, TOP - 0.1, 0))
		hatPart(head, model, { Name = "Knot", Size = Vector3.new(0.3, 0.3, 0.5), Color = color }, CFrame.new(0, TOP - 0.15, 0.8))
		hatPart(head, model, { Name = "EyePatch", Size = Vector3.new(0.3, 0.3, 0.06), Color = Color3.fromRGB(20, 20, 20) }, CFrame.new(0.25, 0.08, -0.62))
		hatPart(head, model, { Name = "Dot", Size = Vector3.new(0.2, 0.2, 0.05), Color = accent }, CFrame.new(-0.3, TOP - 0.05, -0.66))
	end,
	Beanie = function(head, model, color, accent)
		hatPart(head, model, { Name = "Mask", Size = Vector3.new(1.3, 1.3, 1.3), Color = color }, CFrame.new(0, 0.05, 0))
		hatPart(head, model, { Name = "EyeSlit", Size = Vector3.new(1.0, 0.25, 0.05), Color = Color3.fromRGB(255, 214, 170) }, CFrame.new(0, 0.1, -0.66))
		hatPart(head, model, { Name = "Tail", Size = Vector3.new(0.15, 0.15, 1.2), Color = accent }, CFrame.new(0.2, 0.3, 1.1) * CFrame.Angles(math.rad(-20), 0, 0))
	end,
	Cap = function(head, model, color, accent)
		hatPart(head, model, { Name = "Cap", Shape = Enum.PartType.Ball, Size = Vector3.new(1.35, 0.9, 1.35), Color = color }, CFrame.new(0, TOP, 0))
		hatPart(head, model, { Name = "Peak", Size = Vector3.new(1.0, 0.1, 0.7), Color = color }, CFrame.new(0, TOP - 0.05, -0.8))
		hatPart(head, model, { Name = "Feather", Size = Vector3.new(0.08, 0.9, 0.25), Color = accent }, CFrame.new(0.55, TOP + 0.4, 0.2) * CFrame.Angles(0, 0, math.rad(-25)))
	end,
} :: { [string]: HatFn }

------------------------------------------------------------------------------------------
-- Class gear (weapons, capes, armour bits) - welded to the body part it belongs to
------------------------------------------------------------------------------------------

local function gear(base: BasePart, model: Model, props, offset: CFrame): BasePart
	props.Anchored = false
	local p = part(props)
	p.Massless = true
	p.CFrame = base.CFrame * offset
	p.Parent = model
	weld(base, p)
	return p
end

local CYL_UP = CFrame.Angles(0, 0, math.rad(90))
local STEEL = Color3.fromRGB(200, 205, 215)
local WOOD = Color3.fromRGB(120, 80, 50)

ModelBuilder.ClassGear = {
	-- Knight: shoulder plates, round shield on the left arm, sword in the right hand.
	Knight = function(rig, c)
		for _, arm in ipairs({ rig.LeftArm, rig.RightArm }) do
			gear(arm, rig.Model, { Name = "Pauldron", Shape = Enum.PartType.Ball, Size = Vector3.new(1.3, 0.8, 1.2), Color = c.Hat, Material = Enum.Material.Metal }, CFrame.new(0, 0.85, 0))
		end
		gear(rig.LeftArm, rig.Model, { Name = "Shield", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.25, 1.9, 1.9), Color = c.Accent, Material = Enum.Material.Metal }, CFrame.new(-0.55, -0.2, 0))
		gear(rig.LeftArm, rig.Model, { Name = "ShieldBoss", Shape = Enum.PartType.Ball, Size = Vector3.new(0.5, 0.5, 0.5), Color = Color3.fromRGB(255, 205, 60), Material = Enum.Material.Metal }, CFrame.new(-0.7, -0.2, 0))
		gear(rig.RightArm, rig.Model, { Name = "Grip", Size = Vector3.new(0.25, 0.25, 0.7), Color = WOOD }, CFrame.new(0, -1.1, -0.2))
		gear(rig.RightArm, rig.Model, { Name = "Guard", Size = Vector3.new(0.9, 0.2, 0.2), Color = Color3.fromRGB(255, 205, 60), Material = Enum.Material.Metal }, CFrame.new(0, -1.1, -0.6))
		gear(rig.RightArm, rig.Model, { Name = "Blade", Size = Vector3.new(0.25, 0.12, 2.6), Color = STEEL, Material = Enum.Material.Metal }, CFrame.new(0, -1.1, -2.0))
	end,
	-- Mage: long cape, glowing staff, spell book on the belt.
	Mage = function(rig, c)
		gear(rig.Torso, rig.Model, { Name = "Cape", Size = Vector3.new(1.9, 3.4, 0.12), Color = c.Torso:Lerp(Color3.new(0, 0, 0), 0.35) }, CFrame.new(0, -0.6, 0.58) * CFrame.Angles(math.rad(8), 0, 0))
		gear(rig.Torso, rig.Model, { Name = "Clasp", Shape = Enum.PartType.Ball, Size = Vector3.new(0.35, 0.35, 0.35), Color = c.Accent, Material = Enum.Material.Neon }, CFrame.new(0, 0.85, -0.5))
		gear(rig.RightArm, rig.Model, { Name = "Staff", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4.2, 0.25, 0.25), Color = WOOD, Material = Enum.Material.Wood }, CFrame.new(0, -0.3, -0.45) * CYL_UP)
		gear(rig.RightArm, rig.Model, { Name = "StaffGem", Shape = Enum.PartType.Ball, Size = Vector3.new(0.7, 0.7, 0.7), Color = c.Accent, Material = Enum.Material.Neon }, CFrame.new(0, 1.9, -0.45))
		gear(rig.Torso, rig.Model, { Name = "Book", Size = Vector3.new(0.2, 0.7, 0.55), Color = Color3.fromRGB(120, 40, 50) }, CFrame.new(-1.05, -0.6, 0))
	end,
	-- Rogue: scarf with a tail, two daggers on the hips, quiver of knives on the back.
	Rogue = function(rig, c)
		gear(rig.Torso, rig.Model, { Name = "Scarf", Size = Vector3.new(1.6, 0.35, 1.15), Color = c.Accent }, CFrame.new(0, 0.95, 0))
		gear(rig.Torso, rig.Model, { Name = "ScarfTail", Size = Vector3.new(0.35, 1.2, 0.1), Color = c.Accent }, CFrame.new(0.4, 0.3, 0.6) * CFrame.Angles(math.rad(15), 0, math.rad(-10)))
		for _, side in ipairs({ -1, 1 }) do
			gear(rig.Torso, rig.Model, { Name = "Dagger", Size = Vector3.new(0.15, 1.0, 0.3), Color = STEEL, Material = Enum.Material.Metal }, CFrame.new(side * 1.05, -0.9, -0.1) * CFrame.Angles(0, 0, math.rad(side * 15)))
			gear(rig.Torso, rig.Model, { Name = "DaggerHilt", Size = Vector3.new(0.2, 0.35, 0.2), Color = WOOD }, CFrame.new(side * 1.0, -0.25, -0.1))
		end
		gear(rig.Torso, rig.Model, { Name = "Quiver", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.6, 0.6, 0.6), Color = Color3.fromRGB(90, 60, 40) }, CFrame.new(0.3, 0.2, 0.75) * CFrame.Angles(0, 0, math.rad(70)))
	end,
	-- Priest: robe skirt, glowing holy symbol, censer chain in the left hand.
	Priest = function(rig, c)
		gear(rig.Torso, rig.Model, { Name = "Robe", Size = Vector3.new(2.3, 1.6, 1.3), Color = c.Torso }, CFrame.new(0, -1.5, 0))
		gear(rig.Torso, rig.Model, { Name = "RobeTrim", Size = Vector3.new(2.35, 0.2, 1.35), Color = c.Accent }, CFrame.new(0, -2.25, 0))
		gear(rig.Torso, rig.Model, { Name = "Stole", Size = Vector3.new(0.4, 1.9, 0.08), Color = c.Accent }, CFrame.new(0, -0.05, -0.53))
		gear(rig.Torso, rig.Model, { Name = "Symbol", Shape = Enum.PartType.Ball, Size = Vector3.new(0.45, 0.45, 0.2), Color = Color3.fromRGB(255, 240, 150), Material = Enum.Material.Neon }, CFrame.new(0, 0.5, -0.6))
		gear(rig.LeftArm, rig.Model, { Name = "Chain", Size = Vector3.new(0.08, 0.9, 0.08), Color = STEEL, Material = Enum.Material.Metal }, CFrame.new(0, -1.4, 0))
		gear(rig.LeftArm, rig.Model, { Name = "Censer", Shape = Enum.PartType.Ball, Size = Vector3.new(0.6, 0.6, 0.6), Color = Color3.fromRGB(255, 205, 60), Material = Enum.Material.Metal }, CFrame.new(0, -2.0, 0))
	end,
}

------------------------------------------------------------------------------------------
-- Player characters
------------------------------------------------------------------------------------------

--[[
	Builds a blocky humanoid. Layout (studs, root centre at Y=3 when standing):
	  legs 1x2x1 (y 0..2), torso 2x2x1 (y 2..4), head 1.2^3 (y 4..5.2), arms 1x2x1.
	The rig uses Motor6Ds so the client can swing the limbs procedurally; there are no
	animation assets. Humanoid.RequiresNeck is off, and the Dead state is disabled by
	RunManager because HP is tracked by the server, not by the Humanoid.

	opts.Crown = true adds the VIP lobby crown above the hat.
]]
-- Blender mesh body parts → Roblox rig part names.
local BONE_NAMES = {
	Torso = "Torso",
	Head = "Head",
	LeftArm = "Left Arm",
	RightArm = "Right Arm",
	LeftLeg = "Left Leg",
	RightLeg = "Right Leg",
}

--[[
	Hero built from the uploaded Blender meshes (MeshCatalog <characterId>). Same rig as
	the part-built version: invisible HumanoidRootPart, six body MeshParts joined with
	Motor6Ds (so the client walk cycle works), gear MeshParts welded to their bone.
	Returns nil when the meshes aren't loaded.
]]
local function buildMeshCharacter(characterId: string, skinId: string?, crown: boolean): Model?
	local folder = MeshService.Get(characterId)
	local entry = MeshCatalog.Models[characterId]
	if not folder or not entry then
		return nil
	end
	local palette = CharacterData.MeshPalette(characterId, skinId) or {}
	-- a skin with its own hat shape replaces the mesh's head gear with that hat
	local look = CharacterData.ResolveLook(characterId, skinId)
	local def = CharacterData.Characters[characterId]
	local customHat = def ~= nil and look.Hat ~= def.Hat
	local model = Instance.new("Model")
	model.Name = "Character"
	local root = part({ Name = "HumanoidRootPart", Size = Vector3.new(2, 2, 1), Transparency = 1, Anchored = false, CanCollide = true })
	root.CFrame = CFrame.new(0, 3, 0)
	root.Parent = model
	model.PrimaryPart = root

	local bones: { [string]: BasePart } = {}
	local gearList = {}
	for _, piece in ipairs(entry.Pieces) do
		local template = folder:FindFirstChild(piece.Name) :: MeshPart?
		local isHeadGear = piece.Bone == "Head" and piece.Name ~= "Head" and piece.Name ~= "Eyes"
		if template and not (customHat and isHeadGear) then
			local p = template:Clone()
			p.Anchored = false
			p.CanCollide = false
			p.CanQuery = false
			p.Massless = true
			p.CastShadow = true
			p.Size = Vector3.new(piece.Size[1], piece.Size[2], piece.Size[3])
			p.Color = palette[piece.Slot] or (entry.Palette and entry.Palette[piece.Slot]) or p.Color
			p.CFrame = CFrame.new(piece.Offset[1], piece.Offset[2], piece.Offset[3])
			if piece.Bone and piece.Name == piece.Bone then
				p.Name = BONE_NAMES[piece.Bone] or piece.Name
				bones[piece.Bone] = p
			else
				table.insert(gearList, { Part = p, Bone = piece.Bone })
			end
			p.Parent = model
		end
	end
	local torso, head = bones.Torso, bones.Head
	if not torso or not head then
		model:Destroy()
		return nil
	end
	-- joints in model space (root centre at y = 3)
	local function joint(name: string, parent: BasePart, child: BasePart?, at: Vector3)
		if not child then
			return
		end
		local world = CFrame.new(at)
		motor(name, parent, child, parent.CFrame:ToObjectSpace(world), child.CFrame:ToObjectSpace(world))
	end
	joint("RootJoint", root, torso, Vector3.new(0, 3, 0))
	joint("Neck", torso, head, Vector3.new(0, 4, 0))
	joint("Left Shoulder", torso, bones.LeftArm, Vector3.new(-1, 3.9, 0))
	joint("Right Shoulder", torso, bones.RightArm, Vector3.new(1, 3.9, 0))
	joint("Left Hip", torso, bones.LeftLeg, Vector3.new(-0.5, 2, 0))
	joint("Right Hip", torso, bones.RightLeg, Vector3.new(0.5, 2, 0))
	for _, g in ipairs(gearList) do
		weld(bones[g.Bone] or torso, g.Part)
	end
	if customHat then
		local hatFn = ModelBuilder.HatShapes[look.Hat]
		if hatFn then
			hatFn(head, model, look.Colors.Hat, look.Colors.Accent)
		end
	end
	if crown then
		ModelBuilder.HatShapes.Crown(head, model, Color3.fromRGB(255, 205, 50), Color3.fromRGB(255, 60, 90), 1.9)
	end
	return model
end

function ModelBuilder.BuildCharacter(characterId: string, skinId: string?, opts: { Crown: boolean? }?): Model
	local look = CharacterData.ResolveLook(characterId, skinId)
	local meshModel = buildMeshCharacter(characterId, skinId, opts ~= nil and opts.Crown == true)
	if meshModel then
		ModelBuilder.AddHumanoid(meshModel, characterId, skinId)
		return meshModel
	end
	local colors = look.Colors
	local model = Instance.new("Model")
	model.Name = "Character"

	local root = part({ Name = "HumanoidRootPart", Size = Vector3.new(2, 2, 1), Transparency = 1, Anchored = false, CanCollide = true })
	root.CFrame = CFrame.new(0, 3, 0)
	root.Parent = model
	model.PrimaryPart = root

	local function limb(name: string, size: Vector3, color: Color3, offset: CFrame, jointName: string, parent: BasePart, c0: CFrame, c1: CFrame)
		local p = part({ Name = name, Size = size, Color = color, Anchored = false })
		p.Massless = true
		p.CFrame = root.CFrame * offset
		p.Parent = model
		motor(jointName, parent, p, c0, c1)
		return p
	end

	local torso = limb("Torso", Vector3.new(2, 2, 1), colors.Torso, CFrame.new(), "RootJoint", root, CFrame.new(), CFrame.new())
	local head = limb("Head", Vector3.new(1.2, 1.2, 1.2), colors.Head, CFrame.new(0, 1.6, 0), "Neck", torso, CFrame.new(0, 1, 0), CFrame.new(0, -0.6, 0))
	local leftArm = limb("Left Arm", Vector3.new(0.9, 2, 0.9), colors.Arms, CFrame.new(-1.45, 0, 0), "Left Shoulder", torso, CFrame.new(-1, 0.9, 0), CFrame.new(0.45, 0.9, 0))
	local rightArm = limb("Right Arm", Vector3.new(0.9, 2, 0.9), colors.Arms, CFrame.new(1.45, 0, 0), "Right Shoulder", torso, CFrame.new(1, 0.9, 0), CFrame.new(-0.45, 0.9, 0))
	limb("Left Leg", Vector3.new(0.95, 2, 0.95), colors.Legs, CFrame.new(-0.5, -2, 0), "Left Hip", torso, CFrame.new(-0.5, -1, 0), CFrame.new(0, 1, 0))
	limb("Right Leg", Vector3.new(0.95, 2, 0.95), colors.Legs, CFrame.new(0.5, -2, 0), "Right Hip", torso, CFrame.new(0.5, -1, 0), CFrame.new(0, 1, 0))

	-- Face: two eyes and a belt in the accent colour.
	for _, x in ipairs({ -0.25, 0.25 }) do
		local eye = part({ Name = "Eye", Size = Vector3.new(0.18, 0.25, 0.05), Color = Color3.fromRGB(25, 25, 30), Anchored = false })
		eye.Massless = true
		eye.CFrame = head.CFrame * CFrame.new(x, 0.05, -0.61)
		eye.Parent = model
		weld(head, eye)
	end
	local belt = part({ Name = "Belt", Size = Vector3.new(2.05, 0.3, 1.05), Color = colors.Accent, Anchored = false })
	belt.Massless = true
	belt.CFrame = torso.CFrame * CFrame.new(0, -0.7, 0)
	belt.Parent = model
	weld(torso, belt)

	local hatFn = ModelBuilder.HatShapes[look.Hat] or ModelBuilder.HatShapes.Helmet
	hatFn(head, model, colors.Hat, colors.Accent)

	local gearFn = ModelBuilder.ClassGear[characterId]
	if gearFn then
		gearFn({ Model = model, Torso = torso, Head = head, LeftArm = leftArm, RightArm = rightArm }, colors)
	end

	if look.GoldTrim then
		local gold = Color3.fromRGB(255, 200, 40)
		for _, cf in ipairs({ CFrame.new(-0.95, 0, -0.52), CFrame.new(0.95, 0, -0.52) }) do
			local strip = part({ Name = "GoldTrim", Size = Vector3.new(0.12, 2, 0.05), Color = gold, Material = Enum.Material.Neon, Anchored = false })
			strip.Massless = true
			strip.CFrame = torso.CFrame * cf
			strip.Parent = model
			weld(torso, strip)
		end
		local collar = part({ Name = "GoldCollar", Size = Vector3.new(2.05, 0.2, 1.05), Color = gold, Material = Enum.Material.Neon, Anchored = false })
		collar.Massless = true
		collar.CFrame = torso.CFrame * CFrame.new(0, 0.95, 0)
		collar.Parent = model
		weld(torso, collar)
	end

	if opts and opts.Crown then
		-- VIP crown floats above whatever hat the skin already has
		local before = {}
		for _, child in ipairs(model:GetChildren()) do
			before[child] = true
		end
		ModelBuilder.HatShapes.Crown(head, model, Color3.fromRGB(255, 205, 50), Color3.fromRGB(255, 60, 90), 1.2)
		for _, child in ipairs(model:GetChildren()) do
			if not before[child] then
				child.Name = "VIPCrown"
			end
		end
	end

	ModelBuilder.AddHumanoid(model, characterId, skinId)
	return model
end

function ModelBuilder.AddHumanoid(model: Model, characterId: string, skinId: string?)
	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15 -- R15 rules: HipHeight = floor to root bottom
	humanoid.HipHeight = 2
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 0
	humanoid.WalkSpeed = Config.Player.BaseSpeed
	humanoid.AutoRotate = true
	humanoid.Parent = model

	model:SetAttribute("CharacterId", characterId)
	model:SetAttribute("SkinId", skinId or "Default")
end

------------------------------------------------------------------------------------------
-- Enemies (one Part each, pooled)
------------------------------------------------------------------------------------------

--[[
	Enemy shells are created once at server start (Config.Enemies.PoolSize) and parked.
	Each is a Model with a single anchored Part "Body" plus a SpecialMesh for its shape.
	Body parts are anchored and moved with workspace:BulkMoveTo from one Heartbeat loop.
	Anchored parts are always simulated by the server, so SetNetworkOwner(nil) is not
	needed (and Roblox rejects that call on anchored parts); we only call it if a shell
	is ever left unanchored.
]]
function ModelBuilder.BuildEnemyShell(index: number, parent: Instance): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "E" .. index
	local body = part({ Name = "Body", Size = Vector3.new(2, 2, 2), CFrame = CFrame.new(Config.Enemies.ParkPosition) })
	body.Parent = model
	local mesh = Instance.new("SpecialMesh")
	mesh.Name = "Mesh"
	mesh.MeshType = Enum.MeshType.Brick
	mesh.Parent = body
	model.PrimaryPart = body
	model.Parent = parent
	if not body.Anchored then
		body:SetNetworkOwner(nil)
	end
	return model, body
end

local MESH_TYPES = {
	Sphere = Enum.MeshType.Sphere,
	Head = Enum.MeshType.Head,
	Wedge = Enum.MeshType.Wedge,
	Torso = Enum.MeshType.Torso,
	Brick = Enum.MeshType.Brick,
	Cylinder = Enum.MeshType.Cylinder,
}

-- Restyles a pooled enemy body for an enemy definition (elite = bigger and shinier).
function ModelBuilder.ApplyEnemyLook(body: BasePart, def, elite: boolean, sizeMult: number)
	body.Size = def.Size * sizeMult
	local color: Color3 = def.Color
	if elite then
		color = color:Lerp(Color3.fromRGB(255, 210, 60), 0.35)
	end
	body.Color = color
	body:SetAttribute("BaseColor", color)
	body.Material = (elite and Enum.Material.Neon) or (Enum.Material :: any)[def.Material or "SmoothPlastic"]
	body.Transparency = def.Transparency or 0
	local mesh = body:FindFirstChild("Mesh") :: SpecialMesh
	if mesh then
		if def.Mesh then
			mesh.MeshType = MESH_TYPES[def.Mesh.Type] or Enum.MeshType.Brick
			mesh.Scale = def.Mesh.Scale or Vector3.one
		elseif def.Shape == "Ball" then
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Scale = Vector3.one
		else
			mesh.MeshType = Enum.MeshType.Brick
			mesh.Scale = Vector3.one
		end
	end
end

------------------------------------------------------------------------------------------
-- Gems, pickups, chests
------------------------------------------------------------------------------------------

ModelBuilder.GemStyles = {
	-- cubes; clients stand them on a corner so they read as cut crystals
	Small = { Size = Vector3.new(0.75, 0.75, 0.75), Color = Color3.fromRGB(176, 91, 255) }, -- purple
	Medium = { Size = Vector3.new(1.0, 1.0, 1.0), Color = Color3.fromRGB(80, 170, 255) }, -- blue
	Large = { Size = Vector3.new(1.35, 1.35, 1.35), Color = Color3.fromRGB(255, 196, 50) }, -- gold
}

function ModelBuilder.BuildGem(index: number, parent: Instance): BasePart
	local gem = part({ Name = "G" .. index, Size = ModelBuilder.GemStyles.Small.Size, Color = ModelBuilder.GemStyles.Small.Color, Material = Enum.Material.Neon, CFrame = CFrame.new(Config.Enemies.ParkPosition) })
	gem:SetAttribute("Active", false)
	gem.Parent = parent
	return gem
end

function ModelBuilder.StyleGem(gem: BasePart, kind: string)
	local style = ModelBuilder.GemStyles[kind] or ModelBuilder.GemStyles.Small
	gem.Size = style.Size
	gem.Color = style.Color
end

-- Floor pickups: "Chicken" | "Magnet" | "Bomb". Returns an anchored model.
-- Wraps a MeshService model as a pickup: primary part, glow light, Pickup attribute.
local function meshPickup(name: string, kind: string, position: Vector3, lightColor: Color3): Model?
	local model = MeshService.Build(name, CFrame.new(position.X, position.Y - 1.2, position.Z))
	if not model then
		return nil
	end
	model.Name = kind
	local primary = model:FindFirstChildWhichIsA("BasePart")
	model.PrimaryPart = primary
	if primary then
		local light = Instance.new("PointLight")
		light.Range = 10
		light.Brightness = kind == "Chest" and 2 or 1
		light.Color = lightColor
		light.Parent = primary
	end
	model:SetAttribute("Pickup", kind)
	return model
end

function ModelBuilder.BuildPickup(kind: string, position: Vector3): Model
	local meshModel = meshPickup("Pickup_" .. kind, kind, position, (kind == "Chicken" and Color3.fromRGB(255, 200, 150)) or (kind == "Magnet" and Color3.fromRGB(255, 80, 80)) or Color3.fromRGB(255, 200, 80))
	if meshModel then
		return meshModel
	end
	local model = Instance.new("Model")
	model.Name = kind
	local base = CFrame.new(position)
	local main
	if kind == "Chicken" then
		main = part({ Name = "Meat", Shape = Enum.PartType.Ball, Size = Vector3.new(2, 1.6, 1.6), Color = Color3.fromRGB(180, 100, 40), CFrame = base })
		local bone = part({ Name = "Bone", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.4, 0.35, 0.35), Color = Color3.fromRGB(250, 245, 230), CFrame = base * CFrame.new(1.2, 0.2, 0) })
		bone.Parent = model
		local knob = part({ Name = "Knob", Shape = Enum.PartType.Ball, Size = Vector3.new(0.6, 0.6, 0.6), Color = Color3.fromRGB(250, 245, 230), CFrame = base * CFrame.new(1.9, 0.2, 0) })
		knob.Parent = model
	elseif kind == "Magnet" then
		main = part({ Name = "Bottom", Size = Vector3.new(2, 0.5, 0.6), Color = Color3.fromRGB(220, 40, 40), CFrame = base * CFrame.new(0, -0.6, 0) })
		for _, x in ipairs({ -0.75, 0.75 }) do
			local arm = part({ Name = "Arm", Size = Vector3.new(0.5, 1.6, 0.6), Color = Color3.fromRGB(220, 40, 40), CFrame = base * CFrame.new(x, 0.25, 0) })
			arm.Parent = model
			local tip = part({ Name = "Tip", Size = Vector3.new(0.5, 0.4, 0.6), Color = Color3.fromRGB(220, 220, 230), Material = Enum.Material.Metal, CFrame = base * CFrame.new(x, 1.2, 0) })
			tip.Parent = model
		end
	else -- Bomb
		main = part({ Name = "Bomb", Shape = Enum.PartType.Ball, Size = Vector3.new(1.8, 1.8, 1.8), Color = Color3.fromRGB(30, 30, 35), CFrame = base })
		local fuse = part({ Name = "Fuse", Size = Vector3.new(0.2, 0.6, 0.2), Color = Color3.fromRGB(150, 120, 80), CFrame = base * CFrame.new(0, 1.1, 0) })
		fuse.Parent = model
		local spark = part({ Name = "Spark", Shape = Enum.PartType.Ball, Size = Vector3.new(0.4, 0.4, 0.4), Color = Color3.fromRGB(255, 200, 60), Material = Enum.Material.Neon, CFrame = base * CFrame.new(0, 1.5, 0) })
		spark.Parent = model
	end
	main.Parent = model
	model.PrimaryPart = main
	local light = Instance.new("PointLight")
	light.Range = 8
	light.Brightness = 1
	light.Color = (kind == "Chicken" and Color3.fromRGB(255, 200, 150)) or (kind == "Magnet" and Color3.fromRGB(255, 80, 80)) or Color3.fromRGB(255, 200, 80)
	light.Parent = main
	model:SetAttribute("Pickup", kind)
	return model
end

-- Treasure chest dropped by elites.
function ModelBuilder.BuildChest(position: Vector3): Model
	local meshModel = meshPickup("Chest", "Chest", position + Vector3.new(0, 1.2, 0), Color3.fromRGB(255, 210, 90))
	if meshModel then
		local box = meshModel:FindFirstChild("Box") :: BasePart?
		if box then
			meshModel.PrimaryPart = box
			local light = meshModel:FindFirstChildWhichIsA("PointLight", true)
			if light then
				light.Parent = box
			end
		end
		return meshModel
	end
	local model = Instance.new("Model")
	model.Name = "Chest"
	local base = CFrame.new(position + Vector3.new(0, 0.9, 0))
	local box = part({ Name = "Box", Size = Vector3.new(3, 1.8, 2), Color = Color3.fromRGB(130, 80, 40), Material = Enum.Material.Wood, CFrame = base })
	box.Parent = model
	local lid = part({ Name = "Lid", Shape = Enum.PartType.Cylinder, Size = Vector3.new(3, 2, 2), Color = Color3.fromRGB(150, 95, 50), Material = Enum.Material.Wood, CFrame = base * CFrame.new(0, 0.9, 0) })
	lid.Parent = model
	for _, x in ipairs({ -1.3, 0, 1.3 }) do
		local band = part({ Name = "Band", Size = Vector3.new(0.25, 2.9, 2.1), Color = Color3.fromRGB(255, 200, 50), Material = Enum.Material.Metal, CFrame = base * CFrame.new(x, 0.45, 0) })
		band.Parent = model
	end
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 210, 90)
	glow.Range = 14
	glow.Brightness = 2
	glow.Parent = box
	model.PrimaryPart = box
	model:SetAttribute("Pickup", "Chest")
	return model
end

return ModelBuilder
