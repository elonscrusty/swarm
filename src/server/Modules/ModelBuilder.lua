--[[
	ModelBuilder.lua
	Builds the server-side models: player characters (Blender hero meshes + skin hats, with
	part-built fallbacks in the same style until the meshes load), enemy shells (single
	Part), gems, floor pickups and treasure chests.
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
-- Hero rig (shared by every hero, mesh or part-built; matches blender/models/heroes.py)
------------------------------------------------------------------------------------------

local Palette = require(game:GetService("ReplicatedStorage").Shared.Palette)

-- Model space, root centre at y = 3, feet at y = 0, front = -Z, the hero's left = -X.
ModelBuilder.Rig = {
	Neck = Vector3.new(0, 4.45, 0),
	LeftShoulder = Vector3.new(-1.2, 3.95, 0),
	RightShoulder = Vector3.new(1.2, 3.95, 0),
	LeftHip = Vector3.new(-0.5, 2, 0),
	RightHip = Vector3.new(0.5, 2, 0),
}
-- The standard bare head every hero shares; hats are built on its top centre.
ModelBuilder.HeadSize = Vector3.new(1.45, 1.4, 1.35)
ModelBuilder.HeadCenter = Vector3.new(0, 5.15, 0)

local DARK = Palette.slate_950
local CROWN_GOLD = Palette.gold_400
local CROWN_JEWEL = Palette.crimson_400

------------------------------------------------------------------------------------------
-- Hats (part-built fallbacks for the "Hat_<Shape>" meshes): built on the head's top
-- centre, welded to the head. Same shapes and proportions as blender/models/hats.py.
------------------------------------------------------------------------------------------

type HatFn = (head: BasePart, model: Model, color: Color3, accent: Color3, lift: number?) -> ()

local function hatPart(head: BasePart, model: Model, props, offset: CFrame)
	props.Anchored = false
	local p = part(props)
	p.Massless = true
	p.CFrame = head.CFrame * CFrame.new(0, head.Size.Y / 2, 0) * offset
	p.Parent = model
	weld(head, p)
	return p
end

local UP = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis (X) → vertical
local METAL = Enum.Material.Metal

-- great helm: bucket, gold brow band, dark T visor
local function greatHelm(head, model, color)
	hatPart(head, model, { Name = "Helm", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.95, 1.95, 1.95), Color = color, Material = METAL, CastShadow = true }, CFrame.new(0, -0.62, 0) * UP)
	hatPart(head, model, { Name = "HelmTop", Shape = Enum.PartType.Ball, Size = Vector3.new(1.9, 0.75, 1.85), Color = color, Material = METAL }, CFrame.new(0, 0.32, 0))
	hatPart(head, model, { Name = "HelmBand", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.16, 2.02, 2.02), Color = Palette.gold_500, Material = METAL }, CFrame.new(0, -0.28, 0) * UP)
	hatPart(head, model, { Name = "VisorH", Size = Vector3.new(1.1, 0.17, 0.12), Color = DARK }, CFrame.new(0, -0.6, -0.94))
	hatPart(head, model, { Name = "VisorV", Size = Vector3.new(0.17, 0.62, 0.12), Color = DARK }, CFrame.new(0, -0.98, -0.94))
end

ModelBuilder.HatShapes = {
	Helmet = function(head, model, color, accent)
		greatHelm(head, model, color)
		for i, p in ipairs({ { 0.2, 0.75, 0.3 }, { 0.62, 0.9, 0.36 }, { 0.98, 0.65, 0.32 }, { 1.12, 0.15, 0.24 } }) do
			hatPart(head, model, { Name = "Plume" .. i, Shape = Enum.PartType.Ball, Size = Vector3.new(0.68, p[3] * 2, p[3] * 2), Color = accent }, CFrame.new(0, p[2], p[1]))
		end
	end,
	Plume = function(head, model, color, accent)
		hatPart(head, model, { Name = "Helm", Shape = Enum.PartType.Ball, Size = Vector3.new(1.95, 1.7, 1.95), Color = color, Material = METAL, CastShadow = true }, CFrame.new(0, -0.3, 0))
		hatPart(head, model, { Name = "NeckGuard", Size = Vector3.new(1.7, 0.75, 0.2), Color = color, Material = METAL }, CFrame.new(0, -1.0, 1.0) * CFrame.Angles(math.rad(-20), 0, 0))
		hatPart(head, model, { Name = "Nasal", Size = Vector3.new(0.15, 0.6, 0.12), Color = color, Material = METAL }, CFrame.new(0, -0.66, -0.92))
		hatPart(head, model, { Name = "HelmBand", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.16, 2.0, 2.0), Color = Palette.gold_500, Material = METAL }, CFrame.new(0, -0.68, 0) * UP)
		hatPart(head, model, { Name = "Crest", Size = Vector3.new(0.4, 0.9, 1.7), Color = accent }, CFrame.new(0, 0.75, 0.2))
	end,
	Horns = function(head, model, color, accent)
		greatHelm(head, model, color)
		for _, s in ipairs({ -1, 1 }) do
			hatPart(head, model, { Name = "Horn", Size = Vector3.new(0.75, 0.42, 0.42), Color = accent }, CFrame.new(s * 1.2, -0.3, 0) * CFrame.Angles(0, 0, math.rad(s * 25)))
			hatPart(head, model, { Name = "HornTip", Size = Vector3.new(0.3, 0.75, 0.3), Color = accent }, CFrame.new(s * 1.58, 0.2, -0.05) * CFrame.Angles(0, 0, math.rad(s * -12)))
		end
	end,
	Crown = function(head, model, color, accent, lift)
		local y = lift or 0
		hatPart(head, model, { Name = "CrownBand", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.4, 1.8, 1.8), Color = color, Material = METAL, CastShadow = true }, CFrame.new(0, y - 0.1, 0) * UP)
		for i = 0, 4 do
			local a = i * math.pi * 2 / 5
			hatPart(head, model, { Name = "CrownPoint", Wedge = true, Size = Vector3.new(0.12, 0.45, 0.4), Color = color, Material = METAL }, CFrame.new(math.sin(a) * 0.86, y + 0.32, -math.cos(a) * 0.86) * CFrame.Angles(0, -a + math.pi / 2, 0))
		end
		hatPart(head, model, { Name = "CrownGem", Shape = Enum.PartType.Ball, Size = Vector3.new(0.26, 0.3, 0.16), Color = accent }, CFrame.new(0, y - 0.1, -0.92))
	end,
	Wizard = function(head, model, color, accent)
		hatPart(head, model, { Name = "Brim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.12, 3.2, 3.2), Color = color, CastShadow = true }, CFrame.new(0, -0.38, 0) * UP)
		local h = -0.3
		for i, w in ipairs({ 1.9, 1.5, 1.05, 0.6, 0.25 }) do
			hatPart(head, model, { Name = "Cone" .. i, Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.34, w, w), Color = color }, CFrame.new(0, h + 0.17, 0.05 * i * i) * UP)
			h += 0.3
		end
		hatPart(head, model, { Name = "Band", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.26, 1.98, 1.98), Color = accent, Material = METAL }, CFrame.new(0, -0.2, 0) * UP)
	end,
	Tophat = function(head, model, color, accent)
		hatPart(head, model, { Name = "Brim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, 2.3, 2.3), Color = color, CastShadow = true }, CFrame.new(0, -0.1, 0) * UP)
		hatPart(head, model, { Name = "Crown", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.1, 1.65, 1.65), Color = color }, CFrame.new(0, 0.45, 0) * UP)
		hatPart(head, model, { Name = "Band", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.28, 1.7, 1.7), Color = accent }, CFrame.new(0, 0.06, 0) * UP)
	end,
	Halo = function(head, model, _color, accent)
		for i = 0, 9 do
			local a = i * math.pi / 5
			hatPart(head, model, { Name = "Halo", Size = Vector3.new(0.45, 0.09, 0.16), Color = accent, Material = Enum.Material.Neon }, CFrame.new(math.cos(a) * 0.7, 0.42, math.sin(a) * 0.7) * CFrame.Angles(0, -a + math.pi / 2, 0))
		end
	end,
	Hood = function(head, model, color, _accent)
		hatPart(head, model, { Name = "Hood", Shape = Enum.PartType.Ball, Size = Vector3.new(2.0, 2.1, 2.0), Color = color, CastShadow = true }, CFrame.new(0, -0.5, 0.12))
		hatPart(head, model, { Name = "HoodTip", Shape = Enum.PartType.Ball, Size = Vector3.new(0.6, 0.6, 1.0), Color = color }, CFrame.new(0, 0.4, 0.75))
		hatPart(head, model, { Name = "HoodShade", Size = Vector3.new(1.3, 1.0, 0.1), Color = DARK }, CFrame.new(0, -0.75, -0.72))
	end,
	Mitre = function(head, model, color, accent)
		hatPart(head, model, { Name = "Mitre", Size = Vector3.new(1.5, 1.0, 1.25), Color = color, CastShadow = true }, CFrame.new(0, 0.12, 0))
		hatPart(head, model, { Name = "MitreTopF", Wedge = true, Size = Vector3.new(1.5, 0.75, 0.62), Color = color }, CFrame.new(0, 0.98, -0.31))
		hatPart(head, model, { Name = "MitreTopB", Wedge = true, Size = Vector3.new(1.5, 0.75, 0.62), Color = color }, CFrame.new(0, 0.98, 0.31) * CFrame.Angles(0, math.pi, 0))
		hatPart(head, model, { Name = "MitreBand", Size = Vector3.new(1.58, 0.26, 1.4), Color = accent, Material = METAL }, CFrame.new(0, -0.3, 0))
		hatPart(head, model, { Name = "Stripe", Size = Vector3.new(0.26, 1.15, 0.06), Color = accent, Material = METAL }, CFrame.new(0, 0.35, -0.65))
		hatPart(head, model, { Name = "Cross", Size = Vector3.new(0.64, 0.18, 0.07), Color = accent, Material = METAL }, CFrame.new(0, 0.55, -0.66))
	end,
	Bandana = function(head, model, color, accent)
		hatPart(head, model, { Name = "Bandana", Shape = Enum.PartType.Ball, Size = Vector3.new(1.8, 1.1, 1.8), Color = color, CastShadow = true }, CFrame.new(0, -0.12, 0.04))
		hatPart(head, model, { Name = "Edge", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.12, 1.84, 1.84), Color = accent }, CFrame.new(0, -0.48, 0) * UP)
		hatPart(head, model, { Name = "Knot", Shape = Enum.PartType.Ball, Size = Vector3.new(0.5, 0.4, 0.35), Color = color }, CFrame.new(0, -0.6, 0.9))
		for _, s in ipairs({ -1, 1 }) do
			hatPart(head, model, { Name = "Tail", Size = Vector3.new(0.22, 0.65, 0.08), Color = color }, CFrame.new(s * 0.15, -0.98, 0.98) * CFrame.Angles(math.rad(14), 0, math.rad(s * 16)))
		end
		hatPart(head, model, { Name = "EyePatch", Size = Vector3.new(0.38, 0.32, 0.08), Color = DARK }, CFrame.new(0.3, -0.72, -0.69))
	end,
	Beanie = function(head, model, color, accent)
		hatPart(head, model, { Name = "Cowl", Size = Vector3.new(1.62, 0.78, 1.5), Color = color, CastShadow = true }, CFrame.new(0, -0.18, 0))
		hatPart(head, model, { Name = "Mask", Size = Vector3.new(1.62, 0.8, 1.5), Color = color }, CFrame.new(0, -1.22, 0))
		hatPart(head, model, { Name = "SlitBack", Size = Vector3.new(1.62, 0.36, 1.1), Color = color }, CFrame.new(0, -0.68, 0.22))
		hatPart(head, model, { Name = "Headband", Size = Vector3.new(1.7, 0.18, 1.58), Color = accent }, CFrame.new(0, -0.35, 0))
		for _, s in ipairs({ -1, 1 }) do
			hatPart(head, model, { Name = "Tail", Size = Vector3.new(0.16, 0.06, 1.1), Color = accent }, CFrame.new(s * 0.22, -0.48, 1.3) * CFrame.Angles(math.rad(-10), math.rad(s * 12), 0))
		end
	end,
	-- the Alchemist's leather cap with brass goggles pushed up on the forehead
	Goggles = function(head, model, color, accent)
		hatPart(head, model, { Name = "Cap", Shape = Enum.PartType.Ball, Size = Vector3.new(1.85, 1.2, 1.8), Color = color, CastShadow = true }, CFrame.new(0, -0.12, 0.04))
		hatPart(head, model, { Name = "GoggleStrap", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.16, 1.86, 1.86), Color = DARK }, CFrame.new(0, -0.32, 0) * UP)
		for _, x in ipairs({ -0.34, 0.34 }) do
			hatPart(head, model, { Name = "Goggles", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.18, 0.56, 0.56), Color = accent, Material = METAL }, CFrame.new(x, -0.3, -0.86) * CFrame.Angles(0, math.rad(90), 0))
			hatPart(head, model, { Name = "GoggleLens", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, 0.42, 0.42), Color = Palette.amber_300 }, CFrame.new(x, -0.3, -0.96) * CFrame.Angles(0, math.rad(90), 0))
		end
	end,
	-- the Engineer's steel helmet with a gold ridge and a lamp
	Miner = function(head, model, color, accent)
		hatPart(head, model, { Name = "Helm", Shape = Enum.PartType.Ball, Size = Vector3.new(2.0, 1.25, 2.0), Color = color, Material = METAL, CastShadow = true }, CFrame.new(0, -0.22, 0))
		hatPart(head, model, { Name = "HelmBrim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.12, 2.3, 2.3), Color = color, Material = METAL }, CFrame.new(0, -0.58, 0) * UP)
		hatPart(head, model, { Name = "HelmTrim", Size = Vector3.new(0.3, 0.3, 1.85), Color = accent, Material = METAL }, CFrame.new(0, 0.32, 0))
		hatPart(head, model, { Name = "HelmLamp", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.36, 0.56, 0.56), Color = accent, Material = METAL }, CFrame.new(0, -0.18, -0.98) * CFrame.Angles(0, math.rad(90), 0))
		hatPart(head, model, { Name = "HelmLight", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.06, 0.42, 0.42), Color = Palette.fx_gold, Material = Enum.Material.Neon }, CFrame.new(0, -0.18, -1.17) * CFrame.Angles(0, math.rad(90), 0))
	end,
	Cap = function(head, model, color, accent)
		hatPart(head, model, { Name = "Cap", Shape = Enum.PartType.Ball, Size = Vector3.new(1.78, 1.0, 1.9), Color = color, CastShadow = true }, CFrame.new(0, -0.05, 0.12))
		hatPart(head, model, { Name = "CapTip", Wedge = true, Size = Vector3.new(0.5, 0.45, 0.9), Color = color }, CFrame.new(0, 0.3, 0.85))
		hatPart(head, model, { Name = "Brim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, 2.2, 2.2), Color = color }, CFrame.new(0, -0.3, 0) * UP)
		hatPart(head, model, { Name = "Feather", Size = Vector3.new(0.08, 0.22, 1.5), Color = accent }, CFrame.new(-0.95, 0.15, 0.7) * CFrame.Angles(math.rad(25), 0, 0))
	end,
} :: { [string]: HatFn }

-- Colours a hat uses: the look's Hat / HatAccent (+ Gold / Dark for trims and slits).
local function hatPalette(colors: { [string]: Color3 }): { [string]: Color3 }
	return { Hat = colors.Hat, HatAccent = colors.HatAccent, Gold = colors.Gold }
end

--[[
	Welds a hat to `head`: the "Hat_<shape>" mesh when it is loaded (MeshService builds it
	anchored; its pieces are unanchored and welded like gear), otherwise the part-built
	HatShapes version. lift raises it, scale shrinks it (the VIP crown floats above the hat).
	Returns the new parts.
]]
local function attachHat(head: BasePart, model: Model, shape: string, colors: { [string]: Color3 }, lift: number?, scale: number?): { BasePart }
	local made: { BasePart } = {}
	local origin = head.CFrame * CFrame.new(0, head.Size.Y / 2 + (lift or 0), 0)
	local mesh = MeshService.Build("Hat_" .. shape, origin, hatPalette(colors), scale)
	if mesh then
		for _, child in ipairs(mesh:GetChildren()) do
			if child:IsA("BasePart") then
				child.Anchored = false
				child.CanCollide = false
				child.CanQuery = false
				child.CanTouch = false
				child.Massless = true
				child.Parent = model
				weld(head, child)
				table.insert(made, child)
			end
		end
		mesh:Destroy()
		return made
	end
	local fn = ModelBuilder.HatShapes[shape]
	if fn then
		local before: { [Instance]: boolean } = {}
		for _, c in ipairs(model:GetChildren()) do
			before[c] = true
		end
		fn(head, model, colors.Hat, colors.HatAccent, lift)
		for _, c in ipairs(model:GetChildren()) do
			if not before[c] and c:IsA("BasePart") then
				table.insert(made, c)
			end
		end
	end
	return made
end
ModelBuilder.AttachHat = attachHat

-- VIP lobby crown: a smaller gold crown floating just above the top of the hero.
local function addVipCrown(model: Model, head: BasePart)
	local top = head.Position.Y + head.Size.Y / 2
	for _, d in ipairs(model:GetChildren()) do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			top = math.max(top, d.Position.Y + d.Size.Y / 2)
		end
	end
	local lift = top - (head.Position.Y + head.Size.Y / 2) + 0.55
	local parts = attachHat(head, model, "Crown", { Hat = CROWN_GOLD, HatAccent = CROWN_JEWEL, Gold = CROWN_GOLD }, lift, 0.75)
	for _, p in ipairs(parts) do
		p.Name = "VIPCrown"
		p.CastShadow = false
	end
end

-- Mesh models a look needs (the hero + its custom hat), e.g. for MeshService.WhenReady.
function ModelBuilder.MeshesFor(characterId: string, skinId: string?): { string }
	local look = CharacterData.ResolveLook(characterId, skinId)
	local def = CharacterData.Characters[characterId]
	local list = { characterId }
	if def and look.Hat ~= def.Hat then
		table.insert(list, "Hat_" .. look.Hat)
	end
	return list
end

------------------------------------------------------------------------------------------
-- Class gear for the part-built fallback heroes (used until the meshes load): the same
-- silhouettes and colour slots as the Blender heroes, welded to their body part.
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

type Rig = { Model: Model, Torso: BasePart, Head: BasePart, LeftArm: BasePart, RightArm: BasePart, LeftLeg: BasePart, RightLeg: BasePart }

local LEATHER = Palette.leather_600
-- heroes whose part-built fallback wears leather gloves
local GLOVED = { Rogue = true, Ranger = true, Alchemist = true, Engineer = true }
local WOOD = Palette.wood_500
local BLADE = Palette.steel_300

-- Robe skirt, front panel and gold hem (Mage, Priest); torso centre is y = 3.3.
local function robe(rig: Rig, c, width: number)
	gear(rig.Torso, rig.Model, { Name = "Robe", Size = Vector3.new(width, 2.3, width * 0.82), Color = c.Cloth, CastShadow = true }, CFrame.new(0, -2.05, 0))
	gear(rig.Torso, rig.Model, { Name = "RobeFront", Size = Vector3.new(0.75, 2.2, 0.1), Color = c.Cloth2 }, CFrame.new(0, -2.05, -width * 0.41 - 0.04))
	gear(rig.Torso, rig.Model, { Name = "RobeHem", Size = Vector3.new(width + 0.08, 0.16, width * 0.82 + 0.08), Color = c.Gold, Material = METAL }, CFrame.new(0, -3.12, 0))
end

ModelBuilder.ClassGear = {
	-- Knight: domed pauldrons, plate skirt, crimson cape, kite shield, longsword.
	Knight = function(rig: Rig, c)
		for _, arm in ipairs({ rig.LeftArm, rig.RightArm }) do
			local s = arm.Position.X < 0 and -1 or 1
			gear(arm, rig.Model, { Name = "Pauldron", Shape = Enum.PartType.Ball, Size = Vector3.new(1.5, 0.95, 1.4), Color = c.Metal, Material = METAL, CastShadow = true }, CFrame.new(s * 0.06, 0.9, 0))
			gear(arm, rig.Model, { Name = "PauldronRim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.12, 1.55, 1.45), Color = c.Gold, Material = METAL }, CFrame.new(s * 0.06, 0.5, 0) * UP)
		end
		gear(rig.Torso, rig.Model, { Name = "Faulds", Size = Vector3.new(2.4, 0.8, 1.55), Color = c.MetalDark, Material = METAL }, CFrame.new(0, -1.4, 0))
		gear(rig.Torso, rig.Model, { Name = "Cape", Size = Vector3.new(2.3, 3.3, 0.14), Color = c.Accent, CastShadow = true }, CFrame.new(0, -0.6, 0.85) * CFrame.Angles(math.rad(8), 0, 0))
		gear(rig.Torso, rig.Model, { Name = "CapeTrim", Size = Vector3.new(2.36, 0.16, 0.2), Color = c.Gold, Material = METAL }, CFrame.new(0, 1.0, 0.72))
		local la = rig.LeftArm
		gear(la, rig.Model, { Name = "ShieldRim", Size = Vector3.new(0.14, 2.15, 1.55), Color = c.Gold, Material = METAL }, CFrame.new(-0.6, -0.42, -0.3) * CFrame.Angles(0, math.rad(-36), 0))
		gear(la, rig.Model, { Name = "Shield", Size = Vector3.new(0.14, 1.9, 1.32), Color = c.Accent, CastShadow = true }, CFrame.new(-0.68, -0.42, -0.36) * CFrame.Angles(0, math.rad(-36), 0))
		gear(la, rig.Model, { Name = "ShieldCrossV", Size = Vector3.new(0.08, 1.5, 0.22), Color = c.Gold, Material = METAL }, CFrame.new(-0.76, -0.42, -0.42) * CFrame.Angles(0, math.rad(-36), 0))
		gear(la, rig.Model, { Name = "ShieldCrossH", Size = Vector3.new(0.08, 0.22, 1.0), Color = c.Gold, Material = METAL }, CFrame.new(-0.76, -0.1, -0.42) * CFrame.Angles(0, math.rad(-36), 0))
		local ra = rig.RightArm
		-- longsword on one axis through the fist, forward and down like the mesh (heroes.py:
		-- hand (0.08, -0.93, -0.04) from the arm centre, blade direction (0.1, -0.46, -0.86))
		local hand = Vector3.new(0.08, -0.93, -0.04)
		local d = Vector3.new(0.1, -0.46, -0.86).Unit
		local function along(at: number): CFrame
			local p = hand + d * at
			return CFrame.lookAt(p, p + d)
		end
		gear(ra, rig.Model, { Name = "Grip", Size = Vector3.new(0.16, 0.16, 0.8), Color = LEATHER }, along(0.04))
		gear(ra, rig.Model, { Name = "Pommel", Shape = Enum.PartType.Ball, Size = Vector3.new(0.3, 0.3, 0.3), Color = c.Gold, Material = METAL }, along(-0.44))
		gear(ra, rig.Model, { Name = "Guard", Size = Vector3.new(1.0, 0.2, 0.22), Color = c.Gold, Material = METAL }, along(0.44))
		gear(ra, rig.Model, { Name = "Blade", Size = Vector3.new(0.44, 0.14, 2.3), Color = BLADE, Material = METAL }, along(0.44 + 0.08 + 1.15))
	end,
	-- Mage: robe, mantle, beard, staff with a small arcane crystal.
	Mage = function(rig: Rig, c)
		robe(rig, c, 2.5)
		gear(rig.Torso, rig.Model, { Name = "Mantle", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.7, 2.75, 2.75), Color = c.Accent, CastShadow = true }, CFrame.new(0, 0.75, 0) * UP)
		gear(rig.Head, rig.Model, { Name = "FaceBeard", Wedge = true, Size = Vector3.new(1.2, 1.3, 0.5), Color = Palette.ivory_200 }, CFrame.new(0, -0.95, -0.6) * CFrame.Angles(0, 0, math.rad(180)))
		local ra = rig.RightArm
		gear(ra, rig.Model, { Name = "Staff", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4.8, 0.24, 0.24), Color = WOOD }, CFrame.new(0.15, 0.4, -0.25) * UP)
		gear(ra, rig.Model, { Name = "StaffCrystal", Size = Vector3.new(0.3, 0.42, 0.3), Color = Palette.fx_arcane, Material = Enum.Material.Neon }, CFrame.new(0.15, 3.0, -0.25) * CFrame.Angles(0, math.rad(45), 0))
	end,
	-- Rogue: moss cloak, crimson scarf collar and mask, twin daggers.
	Rogue = function(rig: Rig, c)
		gear(rig.Torso, rig.Model, { Name = "Cloak", Size = Vector3.new(2.2, 3.2, 0.12), Color = c.Cloth, CastShadow = true }, CFrame.new(0, -0.7, 0.8) * CFrame.Angles(math.rad(7), 0, 0))
		gear(rig.Torso, rig.Model, { Name = "Scarf", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.45, 2.45, 2.2), Color = c.Accent }, CFrame.new(0, 0.92, 0) * UP)
		for _, arm in ipairs({ rig.LeftArm, rig.RightArm }) do
			gear(arm, rig.Model, { Name = "Dagger", Size = Vector3.new(0.36, 0.12, 1.1), Color = BLADE, Material = METAL }, CFrame.new(0, -1.1, -0.95) * CFrame.Angles(math.rad(18), 0, 0))
			gear(arm, rig.Model, { Name = "DaggerGuard", Size = Vector3.new(0.6, 0.14, 0.16), Color = c.Gold, Material = METAL }, CFrame.new(0, -0.98, -0.4))
		end
	end,
	-- Priest: robe, gold stole, sun staff, small book.
	Priest = function(rig: Rig, c)
		robe(rig, c, 2.65)
		for _, x in ipairs({ -0.3, 0.3 }) do
			gear(rig.Torso, rig.Model, { Name = "Stole", Size = Vector3.new(0.26, 3.6, 0.08), Color = c.Accent }, CFrame.new(x, -1.1, -0.8))
		end
		local ra = rig.RightArm
		gear(ra, rig.Model, { Name = "Staff", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4.7, 0.2, 0.2), Color = c.Gold, Material = METAL }, CFrame.new(0.15, 0.35, -0.3) * UP)
		gear(ra, rig.Model, { Name = "StaffSun", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.14, 0.9, 0.9), Color = c.Gold, Material = METAL }, CFrame.new(0.15, 2.95, -0.32) * CFrame.Angles(0, math.rad(90), math.rad(35)))
		gear(ra, rig.Model, { Name = "StaffCore", Shape = Enum.PartType.Ball, Size = Vector3.new(0.3, 0.3, 0.3), Color = Palette.fx_gold, Material = Enum.Material.Neon }, CFrame.new(0.15, 2.95, -0.42))
		gear(rig.LeftArm, rig.Model, { Name = "Book", Size = Vector3.new(0.24, 0.8, 0.66), Color = Palette.crimson_700 }, CFrame.new(-0.25, -0.75, -0.3))
	end,
	-- Ranger: moss mantle and short cape, crimson scarf, quiver of arrows on the back with its
	-- strap across the chest, leather bracer, longbow in the left hand (limbs curving back
	-- toward the archer, ivory string). Fallback until the "Ranger" mesh is uploaded.
	Ranger = function(rig: Rig, c)
		gear(rig.Torso, rig.Model, { Name = "Mantle", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.55, 2.6, 2.4), Color = c.Hat, CastShadow = true }, CFrame.new(0, 0.85, 0) * UP)
		gear(rig.Torso, rig.Model, { Name = "Scarf", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 2.2, 2.0), Color = c.Accent }, CFrame.new(0, 1.12, 0) * UP)
		gear(rig.Torso, rig.Model, { Name = "Cape", Size = Vector3.new(2.1, 2.6, 0.12), Color = c.Hat, CastShadow = true }, CFrame.new(0, -0.35, 0.82) * CFrame.Angles(math.rad(6), 0, 0))
		gear(rig.Torso, rig.Model, { Name = "Strap", Size = Vector3.new(0.24, 3.0, 0.1), Color = LEATHER }, CFrame.new(0, 0.05, -0.74) * CFrame.Angles(0, 0, math.rad(-38)))
		gear(rig.Torso, rig.Model, { Name = "StrapBuckle", Size = Vector3.new(0.3, 0.3, 0.08), Color = c.Gold, Material = METAL }, CFrame.new(0.32, 0.45, -0.8))
		local quiver = CFrame.new(0.45, 0.35, 0.95) * CFrame.Angles(0, 0, math.rad(-22))
		gear(rig.Torso, rig.Model, { Name = "Quiver", Shape = Enum.PartType.Cylinder, Size = Vector3.new(2.1, 0.6, 0.6), Color = c.Metal, CastShadow = true }, quiver * UP)
		gear(rig.Torso, rig.Model, { Name = "QuiverRim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.14, 0.66, 0.66), Color = c.Gold, Material = METAL }, quiver * CFrame.new(0, 1.0, 0) * UP)
		for i, x in ipairs({ -0.14, 0.0, 0.14 }) do
			gear(rig.Torso, rig.Model, { Name = "Fletching", Size = Vector3.new(0.08, 0.42, 0.22), Color = i == 2 and Palette.crimson_400 or Palette.ivory_200 }, quiver * CFrame.new(x, 1.32, (i - 2) * 0.08))
		end
		local la = rig.LeftArm
		gear(la, rig.Model, { Name = "Bracer", Size = Vector3.new(0.7, 0.55, 0.72), Color = c.Metal }, CFrame.new(0, -0.45, 0))
		local grip = CFrame.new(-0.05, -0.95, -0.42)
		gear(la, rig.Model, { Name = "BowGrip", Size = Vector3.new(0.2, 0.5, 0.22), Color = LEATHER }, grip)
		for _, sign in ipairs({ 1, -1 }) do
			gear(la, rig.Model, { Name = "BowLimb", Size = Vector3.new(0.14, 1.55, 0.16), Color = WOOD, CastShadow = true }, grip * CFrame.new(0, sign * 0.78, 0.14) * CFrame.Angles(math.rad(sign * 20), 0, 0))
			gear(la, rig.Model, { Name = "BowTip", Size = Vector3.new(0.16, 0.2, 0.16), Color = c.Gold, Material = METAL }, grip * CFrame.new(0, sign * 1.5, 0.53))
		end
		gear(la, rig.Model, { Name = "BowString", Size = Vector3.new(0.04, 2.95, 0.04), Color = Palette.ivory_100 }, grip * CFrame.new(0, 0, 0.55))
	end,
	-- Alchemist: long slate coat, leather apron, crimson cravat, a bandolier of glowing
	-- flasks across the chest and a flask in the right hand. Fallback for the "Alchemist" mesh.
	Alchemist = function(rig: Rig, c)
		robe(rig, c, 2.45)
		gear(rig.Torso, rig.Model, { Name = "Apron", Size = Vector3.new(1.3, 2.7, 0.1), Color = c.Metal }, CFrame.new(0, -1.3, -0.8))
		gear(rig.Torso, rig.Model, { Name = "Cravat", Size = Vector3.new(0.45, 0.8, 0.12), Color = c.Accent }, CFrame.new(0, 0.72, -0.76))
		gear(rig.Torso, rig.Model, { Name = "Bandolier", Size = Vector3.new(0.24, 3.0, 0.1), Color = LEATHER }, CFrame.new(0, 0.05, -0.76) * CFrame.Angles(0, 0, math.rad(38)))
		for i, t in ipairs({ -0.75, 0, 0.75 }) do
			local at = CFrame.new(-0.62 * t, 0.05 + 0.79 * t, -0.86)
			gear(rig.Torso, rig.Model, { Name = "Flask", Shape = Enum.PartType.Ball, Size = Vector3.new(0.4, 0.4, 0.4), Color = i == 2 and Palette.fx_arcane or Palette.fx_heal, Material = Enum.Material.Neon }, at)
			gear(rig.Torso, rig.Model, { Name = "FlaskCap", Size = Vector3.new(0.18, 0.12, 0.18), Color = c.Gold, Material = METAL }, at * CFrame.new(0, 0.24, 0))
		end
		local ra = rig.RightArm
		gear(ra, rig.Model, { Name = "HeldFlask", Shape = Enum.PartType.Ball, Size = Vector3.new(0.8, 0.85, 0.8), Color = Palette.ivory_100, Transparency = 0.4 }, CFrame.new(0.1, -1.25, -0.5))
		gear(ra, rig.Model, { Name = "HeldPotion", Shape = Enum.PartType.Ball, Size = Vector3.new(0.6, 0.5, 0.6), Color = Palette.fx_heal, Material = Enum.Material.Neon }, CFrame.new(0.1, -1.38, -0.5))
		gear(ra, rig.Model, { Name = "HeldFlaskCap", Size = Vector3.new(0.26, 0.18, 0.26), Color = c.Gold, Material = METAL }, CFrame.new(0.1, -0.78, -0.5))
	end,
	-- Engineer: steel pauldrons with gold trim, crimson kerchief, a red beard, a tool pack
	-- with a pipe on the back, a belt of gears and a big wrench in the right hand.
	Engineer = function(rig: Rig, c)
		for _, arm in ipairs({ rig.LeftArm, rig.RightArm }) do
			local s = arm.Position.X < 0 and -1 or 1
			gear(arm, rig.Model, { Name = "Pauldron", Shape = Enum.PartType.Ball, Size = Vector3.new(1.3, 0.8, 1.2), Color = c.Metal, Material = METAL, CastShadow = true }, CFrame.new(s * 0.05, 0.8, 0))
			gear(arm, rig.Model, { Name = "PadTrim", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.12, 1.3, 1.25), Color = c.Gold, Material = METAL }, CFrame.new(s * 0.05, 0.48, 0) * UP)
		end
		gear(rig.Torso, rig.Model, { Name = "Kerchief", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 2.2, 1.6), Color = c.Accent }, CFrame.new(0, 1.05, 0) * UP)
		gear(rig.Head, rig.Model, { Name = "FaceBeard", Wedge = true, Size = Vector3.new(1.3, 1.1, 0.55), Color = Palette.clay_500 }, CFrame.new(0, -0.85, -0.62) * CFrame.Angles(0, 0, math.rad(180)))
		gear(rig.Torso, rig.Model, { Name = "Pack", Size = Vector3.new(1.1, 1.8, 0.9), Color = c.Metal, Material = METAL, CastShadow = true }, CFrame.new(0, 0.2, 1.05))
		gear(rig.Torso, rig.Model, { Name = "PackPipe", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.9, 0.34, 0.34), Color = c.MetalDark, Material = METAL }, CFrame.new(0.36, 1.25, 1.2) * UP)
		for _, x in ipairs({ -0.7, 0.75 }) do
			gear(rig.Torso, rig.Model, { Name = "Gear", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.14, 0.55, 0.55), Color = c.Gold, Material = METAL }, CFrame.new(x, -0.95, -0.78) * CFrame.Angles(0, math.rad(90), 0))
		end
		local ra = rig.RightArm
		gear(ra, rig.Model, { Name = "WrenchGrip", Size = Vector3.new(0.3, 0.7, 0.3), Color = c.Accent }, CFrame.new(0.1, -1.05, -0.2))
		gear(ra, rig.Model, { Name = "Wrench", Size = Vector3.new(0.26, 0.3, 2.4), Color = BLADE, Material = METAL, CastShadow = true }, CFrame.new(0.15, -1.25, -1.4))
		gear(ra, rig.Model, { Name = "WrenchJaw", Size = Vector3.new(0.3, 0.75, 0.5), Color = BLADE, Material = METAL }, CFrame.new(0.15, -1.25, -2.6))
		gear(ra, rig.Model, { Name = "WrenchGear", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 0.5, 0.5), Color = c.Gold, Material = METAL }, CFrame.new(0.32, -1.25, -1.6))
	end,
	-- Necromancer: dark robe with a crimson front, a bone collar, a bone mask with glowing
	-- eyes under the hood and a bone staff topped with a small skull.
	Necromancer = function(rig: Rig, c)
		robe(rig, c, 2.7)
		gear(rig.Torso, rig.Model, { Name = "RobeFront", Size = Vector3.new(0.85, 2.3, 0.12), Color = c.Accent }, CFrame.new(0, -2.05, -1.16))
		gear(rig.Torso, rig.Model, { Name = "BoneCollar", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.5, 2.3, 2.0), Color = c.Metal, CastShadow = true }, CFrame.new(0, 1.15, 0.15) * UP)
		gear(rig.Head, rig.Model, { Name = "FaceMask", Size = Vector3.new(1.3, 1.05, 0.2), Color = Palette.ivory_200 }, CFrame.new(0, 0, -0.7))
		gear(rig.Head, rig.Model, { Name = "FaceGlow", Size = Vector3.new(0.7, 0.14, 0.08), Color = Palette.fx_heal, Material = Enum.Material.Neon }, CFrame.new(0, 0.07, -0.82))
		for _, arm in ipairs({ rig.LeftArm, rig.RightArm }) do
			gear(arm, rig.Model, { Name = "Ribs", Size = Vector3.new(0.8, 0.55, 0.8), Color = c.Metal }, CFrame.new(0, 0.75, 0))
		end
		local ra = rig.RightArm
		gear(ra, rig.Model, { Name = "Staff", Shape = Enum.PartType.Cylinder, Size = Vector3.new(5.2, 0.26, 0.26), Color = Palette.ivory_300 }, CFrame.new(0.15, 0.3, -0.35) * UP)
		gear(ra, rig.Model, { Name = "StaffSkull", Shape = Enum.PartType.Ball, Size = Vector3.new(0.5, 0.5, 0.5), Color = Palette.ivory_200 }, CFrame.new(0.15, 2.95, -0.4))
		gear(ra, rig.Model, { Name = "StaffCore", Shape = Enum.PartType.Ball, Size = Vector3.new(0.3, 0.3, 0.3), Color = Palette.fx_heal, Material = Enum.Material.Neon }, CFrame.new(0.15, 3.35, -0.4))
	end,
}

------------------------------------------------------------------------------------------
-- Player characters
------------------------------------------------------------------------------------------

-- Blender mesh body parts → Roblox rig part names.
local BONE_NAMES = {
	Torso = "Torso",
	Head = "Head",
	LeftArm = "Left Arm",
	RightArm = "Right Arm",
	LeftLeg = "Left Leg",
	RightLeg = "Right Leg",
}

-- Head-bone pieces that are the face (kept under a skin's hat); every other Head-bone piece
-- is headgear.
local function isFace(name: string): boolean
	return name == "Head" or name == "Eyes" or string.sub(name, 1, 4) == "Face"
end

-- Motor6D at a model-space point (parts are unrotated when the rig is built).
local function joint(name: string, parent: BasePart, child: BasePart?, point: Vector3)
	if not child then
		return
	end
	local world = CFrame.new(point)
	motor(name, parent, child, parent.CFrame:ToObjectSpace(world), child.CFrame:ToObjectSpace(world))
end

local function newRoot(): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "Character"
	local root = part({ Name = "HumanoidRootPart", Size = Vector3.new(2, 2, 1), Transparency = 1, Anchored = false, CanCollide = true })
	root.CFrame = CFrame.new(0, 3, 0)
	root.Parent = model
	model.PrimaryPart = root
	return model, root
end

--[[
	Hero built from the uploaded Blender meshes (MeshCatalog <characterId>): invisible
	HumanoidRootPart, six body MeshParts joined with Motor6Ds at the model's joint points
	(so the client walk cycle and HeroPoses work), gear MeshParts welded to their bone.
	A skin with its own hat drops the headgear pieces and welds the Hat_<shape> mesh (or
	its part-built fallback). Returns nil when the hero's meshes aren't loaded.
]]
local function buildMeshCharacter(characterId: string, skinId: string?, crown: boolean): Model?
	local folder = MeshService.Get(characterId)
	local entry = MeshCatalog.Models[characterId]
	if not folder or not entry then
		return nil
	end
	local palette = CharacterData.MeshPalette(characterId, skinId) or {}
	local look = CharacterData.ResolveLook(characterId, skinId)
	local def = CharacterData.Characters[characterId]
	local customHat = def ~= nil and look.Hat ~= def.Hat
	local model, root = newRoot()

	local bones: { [string]: BasePart } = {}
	local gearList = {}
	for _, piece in ipairs(entry.Pieces) do
		local template = folder:FindFirstChild(piece.Name) :: MeshPart?
		local headGear = piece.Bone == "Head" and not isFace(piece.Name)
		if template and not (customHat and headGear) then
			local p = template:Clone()
			p.Anchored = false
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Massless = true
			p.CastShadow = (piece :: any).Shadow == true or piece.Name == piece.Bone
			p.Size = Vector3.new(piece.Size[1], piece.Size[2], piece.Size[3])
			p.Color = palette[piece.Slot] or (entry.Palette and entry.Palette[piece.Slot]) or p.Color
			p.Transparency = piece.Transparency or 0
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
	-- joint points from the model (MeshCatalog Joints, set in Blender), else the shared rig
	local joints = (entry :: any).Joints or {}
	local function at(key: string): Vector3
		local j = joints[key]
		return j and Vector3.new(j[1], j[2], j[3]) or (ModelBuilder.Rig :: any)[key]
	end
	joint("RootJoint", root, torso, Vector3.new(0, 3, 0))
	joint("Neck", torso, head, at("Neck"))
	joint("Left Shoulder", torso, bones.LeftArm, at("LeftShoulder"))
	joint("Right Shoulder", torso, bones.RightArm, at("RightShoulder"))
	joint("Left Hip", torso, bones.LeftLeg, at("LeftHip"))
	joint("Right Hip", torso, bones.RightLeg, at("RightHip"))
	for _, g in ipairs(gearList) do
		weld(bones[g.Bone] or torso, g.Part)
	end
	if customHat then
		attachHat(head, model, look.Hat, look.Colors)
	end
	if crown then
		addVipCrown(model, head)
	end
	return model
end

function ModelBuilder.BuildCharacter(characterId: string, skinId: string?, opts: { Crown: boolean? }?): Model
	local crown = opts ~= nil and opts.Crown == true
	local meshModel = buildMeshCharacter(characterId, skinId, crown)
	if meshModel then
		ModelBuilder.AddHumanoid(meshModel, characterId, skinId)
		return meshModel
	end

	-- Part-built fallback (meshes not loaded): the same rig, proportions and slot colours.
	local look = CharacterData.ResolveLook(characterId, skinId)
	local c = look.Colors
	local model, root = newRoot()
	local armour = characterId == "Knight"
	local function body(name: string, size: Vector3, pos: Vector3, color: Color3, metal: boolean?): BasePart
		local p = part({ Name = name, Size = size, Color = color, Anchored = false, CastShadow = true, Material = metal and METAL or nil })
		p.Massless = true
		p.CFrame = CFrame.new(pos)
		p.Parent = model
		return p
	end
	local R = ModelBuilder.Rig
	local torso = body("Torso", Vector3.new(2.3, 2.4, 1.4), Vector3.new(0, 3.3, 0), c.Torso, armour)
	local head = body("Head", ModelBuilder.HeadSize, ModelBuilder.HeadCenter, c.Skin)
	local armColor = armour and c.MetalDark or ((characterId == "Rogue" or characterId == "Ranger") and c.Cloth2 or c.Cloth)
	local leftArm = body("Left Arm", Vector3.new(0.62, 1.75, 0.65), Vector3.new(-1.43, 3.05, 0), armColor, armour)
	local rightArm = body("Right Arm", Vector3.new(0.62, 1.75, 0.65), Vector3.new(1.43, 3.05, 0), armColor, armour)
	local leftLeg = body("Left Leg", Vector3.new(0.74, 1.6, 0.8), Vector3.new(-0.52, 1.25, 0), c.Cloth2)
	local rightLeg = body("Right Leg", Vector3.new(0.74, 1.6, 0.8), Vector3.new(0.52, 1.25, 0), c.Cloth2)
	joint("RootJoint", root, torso, Vector3.new(0, 3, 0))
	joint("Neck", torso, head, R.Neck)
	joint("Left Shoulder", torso, leftArm, R.LeftShoulder)
	joint("Right Shoulder", torso, rightArm, R.RightShoulder)
	joint("Left Hip", torso, leftLeg, R.LeftHip)
	joint("Right Hip", torso, rightLeg, R.RightHip)

	-- eyes, fists / hands, boots, belt
	for _, x in ipairs({ -0.27, 0.27 }) do
		gear(head, model, { Name = "Eyes", Size = Vector3.new(0.16, 0.28, 0.06), Color = DARK }, CFrame.new(x, -0.03, -0.68))
	end
	for _, arm in ipairs({ leftArm, rightArm }) do
		local s = arm.Position.X < 0 and -1 or 1
		gear(arm, model, { Name = "Hand", Size = Vector3.new(0.58, 0.56, 0.6), Color = armour and c.Metal or (GLOVED[characterId] and LEATHER or c.Skin), Material = armour and METAL or nil }, CFrame.new(s * 0.07, -0.93, -0.04))
	end
	for _, leg in ipairs({ leftLeg, rightLeg }) do
		gear(leg, model, { Name = "Boot", Size = Vector3.new(0.84, 0.5, 1.15), Color = armour and c.Metal or LEATHER, Material = armour and METAL or nil }, CFrame.new(0, -1.0, -0.14))
	end
	gear(torso, model, { Name = "Belt", Size = Vector3.new(2.36, 0.22, 1.46), Color = LEATHER }, CFrame.new(0, -0.95, 0))
	gear(torso, model, { Name = "Buckle", Size = Vector3.new(0.36, 0.28, 0.08), Color = c.Gold, Material = METAL }, CFrame.new(0, -0.95, -0.76))

	local gearFn = ModelBuilder.ClassGear[characterId]
	if gearFn then
		gearFn({ Model = model, Torso = torso, Head = head, LeftArm = leftArm, RightArm = rightArm, LeftLeg = leftLeg, RightLeg = rightLeg }, c)
	end
	attachHat(head, model, look.Hat, c)
	if look.GoldTrim then
		gear(torso, model, { Name = "GoldCollar", Size = Vector3.new(1.7, 0.18, 1.2), Color = c.Gold, Material = METAL }, CFrame.new(0, 1.15, 0))
	end
	if crown then
		addVipCrown(model, head)
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
	humanoid.JumpPower = Config.Movement.JumpPower -- the client JumpController decides when (Config.Movement)
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

local PickupTheme = require(game:GetService("ReplicatedStorage").Shared.Theme)
local PP = PickupTheme.Palette

-- XP gems are pooled cubes: the server only needs a position and a size. Clients draw a
-- faceted octahedron crystal in the gem colour over the nearest ones and stand the cube
-- on its corner for the rest. Cyan / blue / violet tones from Theme.Fx.Gem (gold is for
-- coins only); sizes from Config.XP.GemSize: the client reads the kind back from the cube
-- size. Anchored, no collision / query / touch: gems never take part in physics.
local GEM_SIZE = Config.XP.GemSize
ModelBuilder.GemStyles = {
	Small = { Size = Vector3.one * GEM_SIZE.Small, Color = PickupTheme.Fx.Gem.Small },
	Medium = { Size = Vector3.one * GEM_SIZE.Medium, Color = PickupTheme.Fx.Gem.Medium },
	Large = { Size = Vector3.one * GEM_SIZE.Large, Color = PickupTheme.Fx.Gem.Large },
}

function ModelBuilder.BuildGem(index: number, parent: Instance): BasePart
	local style = ModelBuilder.GemStyles.Small
	local gem = part({ Name = "G" .. index, Size = style.Size, Color = style.Color, Material = Enum.Material.SmoothPlastic, CFrame = CFrame.new(Config.Enemies.ParkPosition) })
	gem.Reflectance = 0.08
	gem:SetAttribute("Active", false)
	gem.Parent = parent
	return gem
end

function ModelBuilder.StyleGem(gem: BasePart, kind: string)
	local style = ModelBuilder.GemStyles[kind] or ModelBuilder.GemStyles.Small
	gem.Size = style.Size
	gem.Color = style.Color
end

-- Warm, modest pickup lights (the chest is the brightest).
local PICKUP_LIGHT: { [string]: { Color: Color3, Range: number, Brightness: number } } = {
	Chicken = { Color = PP.gold_200, Range = 7, Brightness = 0.6 },
	Magnet = { Color = PP.crimson_300, Range = 7, Brightness = 0.6 },
	Bomb = { Color = PP.fx_fire, Range = 7, Brightness = 0.6 },
	Chest = { Color = PP.gold_300, Range = 10, Brightness = 1.2 },
}

local function pickupLight(parent: BasePart, kind: string): PointLight
	local def = PICKUP_LIGHT[kind] or PICKUP_LIGHT.Chicken
	local light = Instance.new("PointLight")
	light.Color = def.Color
	light.Range = def.Range
	light.Brightness = def.Brightness
	light.Shadows = false
	light.Parent = parent
	return light
end

-- Chests turn their lock toward the gameplay camera (which looks toward -Z).
local FACE_CAMERA = CFrame.Angles(0, math.pi, 0)

-- Wraps a MeshService model as a pickup: primary part, light, Pickup attribute. `origin`
-- is the model's ground centre; the pivot is put there so the client's bob/spin turns the
-- pickup about its own centre line.
local function meshPickup(name: string, kind: string, origin: CFrame, primaryName: string?): Model?
	local model = MeshService.Build(name, origin)
	if not model then
		return nil
	end
	model.Name = kind
	local primary = (primaryName and model:FindFirstChild(primaryName) :: BasePart?) or model:FindFirstChildWhichIsA("BasePart")
	if primary then
		model.PrimaryPart = primary
		primary.PivotOffset = primary.CFrame:ToObjectSpace(origin)
		pickupLight(primary, kind)
	end
	model:SetAttribute("Pickup", kind)
	return model
end

-- Floor pickups: "Chicken" | "Magnet" | "Bomb" (position = 1.2 above the floor). Returns an
-- anchored model: the Blender mesh when loaded, otherwise a part-built stand-in.
function ModelBuilder.BuildPickup(kind: string, position: Vector3): Model
	local meshModel = meshPickup("Pickup_" .. kind, kind, CFrame.new(position.X, position.Y - 1.2, position.Z))
	if meshModel then
		return meshModel
	end
	local model = Instance.new("Model")
	model.Name = kind
	local base = CFrame.new(position)
	local function add(props): BasePart
		local p = part(props)
		p.Parent = model
		return p
	end
	local main: BasePart
	if kind == "Chicken" then
		local tilt = base * CFrame.Angles(0, 0, math.rad(20))
		main = add({ Name = "Meat", Shape = Enum.PartType.Ball, Size = Vector3.new(1.5, 1.15, 1.15), Color = PP.gold_600, CFrame = tilt * CFrame.new(-0.3, 0, 0) })
		add({ Name = "Crisp", Shape = Enum.PartType.Ball, Size = Vector3.new(1.0, 0.6, 0.9), Color = PP.gold_700, CFrame = tilt * CFrame.new(-0.35, 0.35, 0) })
		add({ Name = "Bone", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.9, 0.22, 0.22), Color = PP.ivory_100, CFrame = tilt * CFrame.new(0.75, 0, 0) })
		for _, z in ipairs({ -0.11, 0.11 }) do
			add({ Name = "Knob", Shape = Enum.PartType.Ball, Size = Vector3.new(0.32, 0.32, 0.32), Color = PP.ivory_100, CFrame = tilt * CFrame.new(1.25, 0, z) })
		end
	elseif kind == "Magnet" then
		main = add({ Name = "Bottom", Size = Vector3.new(1.6, 0.5, 0.55), Color = PP.crimson_500, CFrame = base * CFrame.new(0, -0.55, 0) })
		for _, x in ipairs({ -0.58, 0.58 }) do
			add({ Name = "Arm", Size = Vector3.new(0.48, 1.2, 0.55), Color = PP.crimson_500, CFrame = base * CFrame.new(x, 0.15, 0) })
			add({ Name = "Tip", Size = Vector3.new(0.52, 0.4, 0.59), Color = PP.steel_300, Material = Enum.Material.Metal, CFrame = base * CFrame.new(x, 0.9, 0) })
		end
	else -- Bomb
		main = add({ Name = "Bomb", Shape = Enum.PartType.Ball, Size = Vector3.new(1.6, 1.6, 1.6), Color = PP.slate_900, Material = Enum.Material.Metal, CFrame = base * CFrame.new(0, -0.35, 0) })
		add({ Name = "Cap", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 0.6, 0.6), Color = PP.steel_500, Material = Enum.Material.Metal, CFrame = base * CFrame.new(0, 0.5, 0) * CFrame.Angles(0, 0, math.rad(90)) })
		add({ Name = "Fuse", Size = Vector3.new(0.12, 0.45, 0.12), Color = PP.dirt_300, CFrame = base * CFrame.new(0.08, 0.8, 0) * CFrame.Angles(0, 0, math.rad(-20)) })
		add({ Name = "Spark", Shape = Enum.PartType.Ball, Size = Vector3.new(0.26, 0.26, 0.26), Color = PP.amber_300, Material = Enum.Material.Neon, CFrame = base * CFrame.new(0.18, 1.05, 0) })
	end
	model.PrimaryPart = main
	pickupLight(main, kind)
	model:SetAttribute("Pickup", kind)
	return model
end

-- Treasure chest dropped by elites (position = on the floor). "Box" is the primary part.
-- A FREE pickup, so it stays plain wood and iron: the paid stage chests (LootSystem) are
-- the ones with gold trim, a plinth, a coin and a light beam.
function ModelBuilder.BuildChest(position: Vector3): Model
	local meshModel = meshPickup("Chest", "Chest", CFrame.new(position) * FACE_CAMERA, "Box")
	if meshModel then
		local fittings = meshModel:FindFirstChild("Fittings")
		if fittings and fittings:IsA("BasePart") then
			fittings.Color = PP.steel_600
		end
		return meshModel
	end
	local model = Instance.new("Model")
	model.Name = "Chest"
	local base = CFrame.new(position) * FACE_CAMERA
	local function add(props): BasePart
		local p = part(props)
		p.Parent = model
		return p
	end
	local box = add({ Name = "Box", Size = Vector3.new(2.8, 1.25, 1.85), Color = PP.wood_500, CFrame = base * CFrame.new(0, 0.66, 0) })
	add({ Name = "Lid", Shape = Enum.PartType.Cylinder, Size = Vector3.new(2.84, 1.86, 1.86), Color = PP.wood_400, CFrame = base * CFrame.new(0, 1.28, 0) })
	for _, x in ipairs({ -0.82, 0.82 }) do
		add({ Name = "Strap", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.26, 1.94, 1.94), Color = PP.steel_700, Material = Enum.Material.Metal, CFrame = base * CFrame.new(x, 1.28, 0) })
		add({ Name = "Strap", Size = Vector3.new(0.26, 1.15, 1.95), Color = PP.steel_700, Material = Enum.Material.Metal, CFrame = base * CFrame.new(x, 0.68, 0) })
	end
	for _, x in ipairs({ -1.36, 1.36 }) do
		for _, z in ipairs({ -0.88, 0.88 }) do
			add({ Name = "Corner", Size = Vector3.new(0.22, 0.32, 0.22), Color = PP.steel_600, CFrame = base * CFrame.new(x, 0.3, z) })
		end
	end
	add({ Name = "Lock", Size = Vector3.new(0.48, 0.56, 0.12), Color = PP.steel_500, CFrame = base * CFrame.new(0, 1.15, -0.96) })
	model.PrimaryPart = box
	pickupLight(box, "Chest")
	model:SetAttribute("Pickup", "Chest")
	return model
end

return ModelBuilder
