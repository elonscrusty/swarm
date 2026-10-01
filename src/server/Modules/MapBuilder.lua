--[[
	MapBuilder.lua
	Procedurally builds the castle lobby and the two arenas (Forest, Ruins) from Parts and
	the Blender world meshes (MeshService). Everything is anchored; decoration has
	CanQuery / CanTouch off and small clutter casts no shadow, so the detail is cheap on
	phones (roughly 450-550 Parts + 300-450 MeshParts per arena, ~420 + ~90 in the lobby).

	BuildLobby()        → lobby table (spawn, menu camera, legacy prompts), built once at boot
	BuildArena(name)    → arena table, replaces any previous arena
	DestroyArena()
	ApplyLighting(name) → "Lobby" | "Forest" | "Ruins" (sun, atmosphere, bloom, colour grade)

	Every collidable arena obstacle is also recorded as a simple shape in
	arena.Obstacles so EnemyAI can push enemies out of them cheaply:
	  { Kind = "Circle", Pos = Vector3, Radius = r }
	  { Kind = "Box", Pos = centre, Radius = halfDiagonal, MinX, MaxX, MinZ, MaxZ }
	Obstacle Parts live in arena.ObstacleFolder (the only thing enemy raycasts hit).

	Where props go (and why):
	  * The run camera looks down from the south (Config.Camera), so tall props stand in a
	    few groves and in the tree line outside the boundary, never as a uniform scatter
	    that hides the player. The south border is kept low.
	  * Nothing collidable within Config.Arenas.ClearRadius of the centre (player spawn).
	  * Mesh props stand on the arena floor (Center.Y) by their ground centre, and their
	    collider is made at the same x/z by the same helper.
	  * Props are clustered (groves, outcrops, rings) around paths and landmarks, with
	    "keepout" circles so nothing lands on a path, the pond or another prop.
]]

local Lighting = game:GetService("Lighting")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local ModelBuilder = require(script.Parent.ModelBuilder)
local MeshService = require(script.Parent.MeshService)

local part = ModelBuilder.Part

local MapBuilder = {}

local mapFolder: Folder? = nil
local currentArena: { [string]: any }? = nil
local rng = Random.new()

local rgb = Color3.fromRGB
local TAU = math.pi * 2
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- turns a Cylinder's axis (X) upward

local function ensureMapFolder(): Folder
	if not mapFolder then
		local f = Instance.new("Folder")
		f.Name = "SwarmMap"
		f.Parent = workspace
		mapFolder = f
	end
	return mapFolder :: Folder
end

local function textSurface(target: BasePart, face: Enum.NormalId, text: string, color: Color3, bg: Color3?): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = target
	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = bg or Color3.fromRGB(25, 25, 35)
	label.BackgroundTransparency = bg and 0 or 1
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = text
	label.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.1, 0)
	pad.PaddingBottom = UDim.new(0.1, 0)
	pad.PaddingLeft = UDim.new(0.05, 0)
	pad.PaddingRight = UDim.new(0.05, 0)
	pad.Parent = label
	return gui
end

local function prompt(parent: Instance, action: string, object: string, name: string): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = 0
	p.MaxActivationDistance = 12
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.Parent = parent
	return p
end

------------------------------------------------------------------------------------------
-- BUILDING BLOCKS
------------------------------------------------------------------------------------------

-- part() + parent. Decoration by default: no collision, no queries, no shadow.
local function deco(parent: Instance, props: { [string]: any }): BasePart
	local p = part(props)
	p.Parent = parent
	return p
end

-- Flat disc whose TOP surface is at `top` (ground patches, puddles, rugs).
local function disc(parent: Instance, name: string, top: Vector3, radius: number, color: Color3, material: Enum.Material?, thick: number?): BasePart
	local t = thick or 0.1
	return deco(parent, {
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(t, radius * 2, radius * 2),
		CFrame = CFrame.new(top - Vector3.new(0, t / 2, 0)) * UPRIGHT,
		Color = color,
		Material = material or Enum.Material.Grass,
	})
end

-- Upright cylinder standing on `base`.
local function column(parent: Instance, name: string, base: Vector3, radius: number, height: number, color: Color3, material: Enum.Material?, extra: { [string]: any }?): BasePart
	local props: { [string]: any } = {
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		CFrame = CFrame.new(base + Vector3.new(0, height / 2, 0)) * UPRIGHT,
		Color = color,
		Material = material or Enum.Material.Slate,
	}
	if extra then
		for k, v in pairs(extra) do
			props[k] = v
		end
	end
	return deco(parent, props)
end

-- Picks a random entry of a list.
local function pick<T>(list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

-- Slight random variation of a colour (keeps big surfaces from looking flat).
local function vary(c: Color3, amount: number): Color3
	local d = rng:NextNumber(-amount, amount)
	return Color3.new(math.clamp(c.R + d, 0, 1), math.clamp(c.G + d, 0, 1), math.clamp(c.B + d, 0, 1))
end

------------------------------------------------------------------------------------------
-- Flickering fire lights: one loop for every torch / brazier light in the world.
------------------------------------------------------------------------------------------

local flickers: { { Light: PointLight, Base: number, Phase: number } } = {}
local flickerRunning = false

local function addFlicker(light: PointLight)
	table.insert(flickers, { Light = light, Base = light.Brightness, Phase = rng:NextNumber(0, 10) })
	if flickerRunning then
		return
	end
	flickerRunning = true
	task.spawn(function()
		while true do
			local t = os.clock()
			for i = #flickers, 1, -1 do
				local f = flickers[i]
				if f.Light.Parent == nil then
					table.remove(flickers, i)
				else
					f.Light.Brightness = f.Base * (0.84 + 0.1 * math.sin(t * 7.3 + f.Phase) + 0.06 * math.sin(t * 17.9 + f.Phase * 2))
				end
			end
			task.wait(0.1)
		end
	end)
end

-- Invisible holder with a warm PointLight (optionally flickering and with a Fire effect).
local function fireLight(parent: Instance, pos: Vector3, range: number, brightness: number, color: Color3?, withFire: boolean?): BasePart
	local holder = deco(parent, { Name = "FireLight", Size = Vector3.new(0.2, 0.2, 0.2), CFrame = CFrame.new(pos), Transparency = 1 })
	local light = Instance.new("PointLight")
	light.Color = color or rgb(255, 170, 90)
	light.Range = range
	light.Brightness = brightness
	light.Shadows = false
	light.Parent = holder
	if withFire then
		local fire = Instance.new("Fire")
		fire.Size = 1.6
		fire.Heat = 6
		fire.Color = rgb(255, 140, 40)
		fire.SecondaryColor = rgb(255, 220, 120)
		fire.Parent = holder
	end
	addFlicker(light)
	return holder
end

------------------------------------------------------------------------------------------
-- Mesh props: Blender mesh when loaded (MeshService), part-built fallback otherwise.
-- `cf` is the prop's GROUND centre (MeshCatalog offsets are measured from it). When the
-- meshes are still loading, the fallback is swapped for the mesh once it arrives.
------------------------------------------------------------------------------------------

type Palette = { [string]: Color3 }

local FALLBACK: { [string]: (Model, CFrame, number, Palette?) -> () } = {}

local function fbColor(palette: Palette?, slot: string, default: Color3): Color3
	return (palette and palette[slot]) or default
end

FALLBACK.Tree_Round = function(m, cf, s, pal)
	deco(m, { Name = "Trunk", Shape = Enum.PartType.Cylinder, Size = Vector3.new(8 * s, 2.4 * s, 2.4 * s), CFrame = cf * CFrame.new(0, 4 * s, 0) * UPRIGHT, Color = fbColor(pal, "Wood", rgb(122, 82, 50)), Material = Enum.Material.Wood, CastShadow = true })
	deco(m, { Name = "Leaves", Shape = Enum.PartType.Ball, Size = Vector3.new(10, 8, 9) * s, CFrame = cf * CFrame.new(0, 10 * s, 0), Color = fbColor(pal, "Leaf", rgb(79, 174, 74)), CastShadow = true })
end
FALLBACK.Tree_Pine = function(m, cf, s, pal)
	deco(m, { Name = "Trunk", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4 * s, 1.6 * s, 1.6 * s), CFrame = cf * CFrame.new(0, 2 * s, 0) * UPRIGHT, Color = fbColor(pal, "Wood", rgb(107, 74, 44)), Material = Enum.Material.Wood, CastShadow = true })
	for i, r in ipairs({ 4.2, 3.2, 2.0 }) do
		deco(m, { Name = "Leaves", Shape = Enum.PartType.Cylinder, Size = Vector3.new(3 * s, r * 2 * s, r * 2 * s), CFrame = cf * CFrame.new(0, (2.5 + i * 2.6) * s, 0) * UPRIGHT, Color = fbColor(pal, "Leaf", rgb(47, 125, 70)), CastShadow = true })
	end
end
FALLBACK.Mushroom = function(m, cf, s, pal)
	deco(m, { Name = "Stem", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4 * s, 1.6 * s, 1.6 * s), CFrame = cf * CFrame.new(0, 2 * s, 0) * UPRIGHT, Color = fbColor(pal, "Light", rgb(243, 234, 216)) })
	deco(m, { Name = "Cap", Shape = Enum.PartType.Ball, Size = Vector3.new(6, 3, 6) * s, CFrame = cf * CFrame.new(0, 4.6 * s, 0), Color = fbColor(pal, "Accent", rgb(224, 54, 46)), CastShadow = s > 0.8 })
end
FALLBACK.Rock = function(m, cf, s, pal)
	deco(m, { Name = "Rock", Shape = Enum.PartType.Ball, Size = Vector3.new(5, 3, 4) * s, CFrame = cf * CFrame.new(0, 1.1 * s, 0), Color = fbColor(pal, "Stone", rgb(140, 143, 153)), Material = Enum.Material.Slate, CastShadow = s > 0.9 })
end
FALLBACK.Bush = function(m, cf, s, pal)
	deco(m, { Name = "Bush", Shape = Enum.PartType.Ball, Size = Vector3.new(4, 2.5, 2.6) * s, CFrame = cf * CFrame.new(0, 1 * s, 0), Color = fbColor(pal, "Leaf", rgb(79, 174, 74)), Material = Enum.Material.Grass })
end
FALLBACK.Pillar = function(m, cf, s, pal)
	deco(m, { Name = "Base", Size = Vector3.new(3.2, 0.8, 3.2) * s, CFrame = cf * CFrame.new(0, 0.4 * s, 0), Color = fbColor(pal, "Stone", rgb(167, 164, 154)), Material = Enum.Material.Slate })
	deco(m, { Name = "Pillar", Shape = Enum.PartType.Cylinder, Size = Vector3.new(7 * s, 2.3 * s, 2.3 * s), CFrame = cf * CFrame.new(0, 4.3 * s, 0) * UPRIGHT, Color = fbColor(pal, "Stone", rgb(167, 164, 154)), Material = Enum.Material.Slate, CastShadow = true })
	deco(m, { Name = "Cap", Size = Vector3.new(2.8, 0.7, 2.8) * s, CFrame = cf * CFrame.new(0, 8.1 * s, 0), Color = fbColor(pal, "Stone", rgb(167, 164, 154)), Material = Enum.Material.Slate })
end
FALLBACK.CrystalCluster = function(m, cf, s, pal)
	deco(m, { Name = "Base", Shape = Enum.PartType.Ball, Size = Vector3.new(3.4, 1.2, 3) * s, CFrame = cf * CFrame.new(0, 0.4 * s, 0), Color = fbColor(pal, "Stone", rgb(110, 107, 120)), Material = Enum.Material.Slate })
	for i = 1, 3 do
		deco(m, { Name = "Crystal", Size = Vector3.new(0.8, 3 - i * 0.5, 0.8) * s, CFrame = cf * CFrame.Angles(0, i * 2.1, math.rad(14 * (i - 1))) * CFrame.new((i - 1) * 0.6 * s, (1.8 - i * 0.2) * s, 0), Color = fbColor(pal, "Glow", rgb(176, 91, 255)), Material = Enum.Material.Neon })
	end
end
FALLBACK.Torch = function(m, cf, s, pal)
	deco(m, { Name = "Post", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4 * s, 0.45 * s, 0.45 * s), CFrame = cf * CFrame.new(0, 2 * s, 0) * UPRIGHT, Color = fbColor(pal, "Wood", rgb(107, 74, 44)), Material = Enum.Material.Wood })
	deco(m, { Name = "Bowl", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.5 * s, 1.2 * s, 1.2 * s), CFrame = cf * CFrame.new(0, 4.2 * s, 0) * UPRIGHT, Color = fbColor(pal, "Metal", rgb(74, 78, 90)), Material = Enum.Material.Metal })
	deco(m, { Name = "Flame", Shape = Enum.PartType.Ball, Size = Vector3.new(0.8, 1.2, 0.8) * s, CFrame = cf * CFrame.new(0, 5 * s, 0), Color = fbColor(pal, "Glow", rgb(255, 154, 43)), Material = Enum.Material.Neon })
end
FALLBACK.Banner = function(m, cf, s, pal)
	deco(m, { Name = "Pole", Shape = Enum.PartType.Cylinder, Size = Vector3.new(9 * s, 0.36 * s, 0.36 * s), CFrame = cf * CFrame.new(0, 4.5 * s, 0) * UPRIGHT, Color = fbColor(pal, "Wood", rgb(107, 74, 44)), Material = Enum.Material.Wood })
	deco(m, { Name = "Bar", Size = Vector3.new(3.4, 0.25, 0.25) * s, CFrame = cf * CFrame.new(0, 8.6 * s, 0), Color = fbColor(pal, "Wood", rgb(107, 74, 44)), Material = Enum.Material.Wood })
	deco(m, { Name = "Cloth", Size = Vector3.new(3, 4.9, 0.1) * s, CFrame = cf * CFrame.new(0, 6.05 * s, -0.2 * s), Color = fbColor(pal, "Cloth", rgb(45, 79, 191)), Material = Enum.Material.Fabric })
	deco(m, { Name = "Emblem", Size = Vector3.new(1, 1, 0.12) * s, CFrame = cf * CFrame.new(0, 6.6 * s, -0.28 * s) * CFrame.Angles(0, 0, math.rad(45)), Color = fbColor(pal, "Gold", rgb(242, 193, 78)) })
end

-- One MeshService.WhenReady per model name while meshes are still loading.
local waitingSwaps: { [string]: { () -> () } } = {}

local function whenMeshLoads(name: string, fn: () -> ())
	local list = waitingSwaps[name]
	if not list then
		local newList: { () -> () } = {}
		waitingSwaps[name] = newList
		MeshService.WhenReady({ name }, function()
			waitingSwaps[name] = nil
			for _, f in ipairs(newList) do
				f()
			end
		end)
		list = newList
	end
	table.insert(list :: { () -> () }, fn)
end

local function meshInto(parent: Instance, name: string, cf: CFrame, scale: number, palette: Palette?, shadow: boolean): boolean
	local model = MeshService.Build(name, cf, palette, scale)
	if not model then
		return false
	end
	for _, d in ipairs(model:GetChildren()) do
		if d:IsA("BasePart") then
			d.CastShadow = shadow
		end
	end
	model.Parent = parent
	return true
end

-- Places mesh prop `name` standing on `cf` (ground centre, any yaw).
local function prop(parent: Instance, name: string, cf: CFrame, scale: number, palette: Palette?, shadow: boolean?)
	local castShadow = shadow == true
	if meshInto(parent, name, cf, scale, palette, castShadow) then
		return
	end
	local fb = Instance.new("Model")
	fb.Name = name
	local build = FALLBACK[name]
	if build then
		build(fb, cf, scale, palette)
	end
	fb.Parent = parent
	if MeshService.MayLoad(name) then
		whenMeshLoads(name, function()
			local p = fb.Parent
			if p and meshInto(p, name, cf, scale, palette, castShadow) then
				fb:Destroy()
			end
		end)
	end
end

local function randomYaw(): CFrame
	return CFrame.Angles(0, rng:NextNumber(0, TAU), 0)
end

------------------------------------------------------------------------------------------
-- LIGHTING
------------------------------------------------------------------------------------------

local LIGHTING = {
	-- warm golden hour over the castle
	Lobby = {
		Clock = 17.6, Brightness = 2.2, Latitude = 30, Shadow = 0.35,
		Ambient = rgb(118, 100, 92), Outdoor = rgb(160, 132, 118), Top = rgb(255, 226, 190),
		Atmo = { Density = 0.3, Offset = 0.2, Color = rgb(240, 202, 165), Decay = rgb(125, 85, 95), Glare = 0.5, Haze = 1.8 },
		Bloom = { Intensity = 0.6, Size = 26, Threshold = 1.15 },
		Grade = { Brightness = 0.02, Contrast = 0.1, Saturation = 0.14, Tint = rgb(255, 242, 228) },
		Rays = { Intensity = 0.08, Spread = 0.7 },
	},
	-- bright late morning in a forest clearing
	Forest = {
		Clock = 14.2, Brightness = 2.6, Latitude = 35, Shadow = 0.25,
		Ambient = rgb(96, 102, 106), Outdoor = rgb(136, 142, 136), Top = rgb(255, 244, 222),
		Atmo = { Density = 0.22, Offset = 0.25, Color = rgb(200, 222, 236), Decay = rgb(104, 140, 120), Glare = 0.15, Haze = 1.1 },
		Bloom = { Intensity = 0.35, Size = 24, Threshold = 1.4 },
		Grade = { Brightness = 0.02, Contrast = 0.06, Saturation = 0.16, Tint = rgb(255, 252, 240) },
		Rays = { Intensity = 0.05, Spread = 0.6 },
	},
	-- low golden dusk, purple crystal haze
	Ruins = {
		Clock = 17.3, Brightness = 2.1, Latitude = 25, Shadow = 0.3,
		Ambient = rgb(108, 90, 122), Outdoor = rgb(150, 122, 142), Top = rgb(255, 214, 170),
		Atmo = { Density = 0.3, Offset = 0.15, Color = rgb(228, 190, 176), Decay = rgb(112, 72, 132), Glare = 0.45, Haze = 2 },
		Bloom = { Intensity = 0.75, Size = 28, Threshold = 1.05 },
		Grade = { Brightness = 0, Contrast = 0.1, Saturation = 0.1, Tint = rgb(255, 238, 228) },
		Rays = { Intensity = 0.1, Spread = 0.75 },
	},
}

local function lightingEffect(className: string, name: string): Instance
	local e = Lighting:FindFirstChild(name)
	if not e then
		e = Instance.new(className)
		e.Name = name
		e.Parent = Lighting
	end
	return e :: Instance
end

function MapBuilder.ApplyLighting(name: string)
	local L = LIGHTING[name] or LIGHTING.Forest
	Lighting.ClockTime = L.Clock
	Lighting.Brightness = L.Brightness
	Lighting.GeographicLatitude = L.Latitude
	Lighting.ShadowSoftness = L.Shadow
	Lighting.Ambient = L.Ambient
	Lighting.OutdoorAmbient = L.Outdoor
	Lighting.ColorShift_Top = L.Top
	Lighting.EnvironmentDiffuseScale = 0.6
	Lighting.EnvironmentSpecularScale = 0.5
	Lighting.FogEnd = 100000

	local atmo = lightingEffect("Atmosphere", "SwarmAtmosphere") :: Atmosphere
	atmo.Density = L.Atmo.Density
	atmo.Offset = L.Atmo.Offset
	atmo.Color = L.Atmo.Color
	atmo.Decay = L.Atmo.Decay
	atmo.Glare = L.Atmo.Glare
	atmo.Haze = L.Atmo.Haze

	local bloom = lightingEffect("BloomEffect", "SwarmBloom") :: BloomEffect
	bloom.Intensity = L.Bloom.Intensity
	bloom.Size = L.Bloom.Size
	bloom.Threshold = L.Bloom.Threshold

	local grade = lightingEffect("ColorCorrectionEffect", "SwarmGrade") :: ColorCorrectionEffect
	grade.Brightness = L.Grade.Brightness
	grade.Contrast = L.Grade.Contrast
	grade.Saturation = L.Grade.Saturation
	grade.TintColor = L.Grade.Tint

	local rays = lightingEffect("SunRaysEffect", "SwarmSunRays") :: SunRaysEffect
	rays.Intensity = L.Rays.Intensity
	rays.Spread = L.Rays.Spread
end

------------------------------------------------------------------------------------------
-- LOBBY: a castle courtyard. The keep (gate, towers, banners) is on the north side; the
-- menu camera (part "MenuCamera") looks at it from the south over the spawn emblem.
------------------------------------------------------------------------------------------

local STONE = rgb(150, 146, 138)
local STONE_DARK = rgb(112, 108, 104)
local STONE_LIGHT = rgb(176, 170, 158)
local ROOF = rgb(62, 72, 112)
local BANNER_RED = rgb(150, 32, 44)
local GOLD = rgb(232, 186, 80)
local WOOD = rgb(110, 76, 46)

-- Ring of merlons (crenellations) on top of a round tower.
local function towerMerlons(parent: Instance, centre: Vector3, radius: number, y: number, count: number, color: Color3)
	for k = 0, count - 1 do
		local a = k / count * TAU
		local pos = centre + Vector3.new(math.cos(a) * radius, y + 1, math.sin(a) * radius)
		deco(parent, { Name = "Merlon", Size = Vector3.new(2.2, 2, 1.4), CFrame = CFrame.lookAt(pos, Vector3.new(centre.X, pos.Y, centre.Z)), Color = color, Material = Enum.Material.Cobblestone, CastShadow = true })
	end
end

-- Round tower: body, corbel ring, merlons, optional stepped cone roof and flag.
local function castleTower(parent: Instance, base: Vector3, radius: number, height: number, roof: boolean, flagColor: Color3?)
	column(parent, "Tower", base, radius, height, STONE, Enum.Material.Cobblestone, { CanCollide = true, CastShadow = true })
	column(parent, "TowerPlinth", base, radius + 0.7, 1.6, STONE_DARK, Enum.Material.Cobblestone)
	column(parent, "TowerCorbel", base + Vector3.new(0, height, 0), radius + 0.8, 1.4, STONE_LIGHT, Enum.Material.Cobblestone, { CastShadow = true })
	towerMerlons(parent, base, radius + 0.3, height + 1.4, math.max(6, math.floor(radius * 1.3)), STONE_LIGHT)
	local top = height + 1.4
	if roof then
		for i, r in ipairs({ radius - 0.2, radius * 0.72, radius * 0.46, radius * 0.22 }) do
			column(parent, "Roof", base + Vector3.new(0, top + (i - 1) * 2.1, 0), r, 2.1, vary(ROOF, 0.02), Enum.Material.Slate, { CastShadow = true })
		end
		top += 8.4
	end
	if flagColor then
		column(parent, "FlagPole", base + Vector3.new(0, top, 0), 0.15, 5, rgb(70, 60, 50), Enum.Material.Wood)
		deco(parent, { Name = "Flag", Size = Vector3.new(3.4, 1.9, 0.1), CFrame = CFrame.new(base + Vector3.new(1.75, top + 4, 0)) * CFrame.Angles(0, math.rad(-12), 0), Color = flagColor, Material = Enum.Material.Fabric })
	end
end

-- Hanging cloth banner on a wall face (front = +Z).
local function wallBanner(parent: Instance, x: number, top: number, z: number, o: Vector3)
	local h = 9
	deco(parent, { Name = "HangingRod", Size = Vector3.new(5.6, 0.4, 0.4), CFrame = CFrame.new(o + Vector3.new(x, top, z + 0.95)), Color = GOLD, Material = Enum.Material.Metal })
	deco(parent, { Name = "HangingBanner", Size = Vector3.new(4.6, h, 0.15), CFrame = CFrame.new(o + Vector3.new(x, top - h / 2, z + 0.8)), Color = BANNER_RED, Material = Enum.Material.Fabric })
	deco(parent, { Name = "BannerTrim", Size = Vector3.new(4.6, 0.5, 0.18), CFrame = CFrame.new(o + Vector3.new(x, top - h + 0.6, z + 0.83)), Color = GOLD, Material = Enum.Material.Fabric })
	deco(parent, { Name = "BannerEmblem", Size = Vector3.new(1.8, 1.8, 0.2), CFrame = CFrame.new(o + Vector3.new(x, top - 3.4, z + 0.86)) * CFrame.Angles(0, 0, math.rad(45)), Color = GOLD, Material = Enum.Material.Fabric })
end

function MapBuilder.BuildLobby()
	local root = ensureMapFolder()
	local existing = root:FindFirstChild("Lobby")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Model")
	folder.Name = "Lobby"
	folder.Parent = root

	local o = Config.Lobby.Origin
	local size = Config.Lobby.Size
	local half = size / 2
	local southH = Config.Lobby.WallHeight
	local keepH = 18 -- keep wall height (north)
	local sideH = 9 -- east / west wall height
	local spawnPos = o + Vector3.new(0, 0, -6) -- where characters stand (emblem centre)

	local function add(p: BasePart): BasePart
		p.Parent = folder
		return p
	end

	--------------------------------------------------------------------------------------
	-- Grounds around the castle + distant hills and mountains (menu backdrop).
	add(part({ Name = "Grounds", Size = Vector3.new(560, 2, 560), CFrame = CFrame.new(o + Vector3.new(0, -1.35, -100)), Color = rgb(98, 138, 72), Material = Enum.Material.Grass, CanCollide = true }))
	for _, h in ipairs({
		{ Vector3.new(-120, -14, -150), Vector3.new(150, 50, 90), rgb(88, 128, 70) },
		{ Vector3.new(90, -16, -170), Vector3.new(180, 56, 100), rgb(80, 120, 66) },
		{ Vector3.new(0, -20, -230), Vector3.new(220, 60, 110), rgb(92, 126, 76) },
		{ Vector3.new(-240, -20, -330), Vector3.new(260, 290, 160), rgb(112, 118, 140) },
		{ Vector3.new(60, -30, -400), Vector3.new(340, 350, 180), rgb(104, 110, 136) },
		{ Vector3.new(320, -20, -340), Vector3.new(280, 270, 160), rgb(116, 120, 142) },
	}) do
		add(part({ Name = "Hill", Shape = Enum.PartType.Ball, Size = h[2], CFrame = CFrame.new(o + h[1]), Color = h[3], Material = Enum.Material.Grass }))
	end

	--------------------------------------------------------------------------------------
	-- Courtyard floor: dark grout slab + 6x6 flagstones (a warm sandstone path runs from
	-- the south wall to the gate) + the spawn emblem.
	add(part({ Name = "Floor", Size = Vector3.new(size, 2, size), CFrame = CFrame.new(o + Vector3.new(0, -1, 0)), Color = rgb(86, 82, 78), Material = Enum.Material.Slate, CanCollide = true, CanQuery = true }))
	local stones = { rgb(150, 146, 138), rgb(140, 136, 130), rgb(160, 154, 144), rgb(132, 128, 124), rgb(146, 140, 128) }
	local sand = { rgb(182, 164, 132), rgb(172, 154, 124), rgb(188, 170, 140) }
	for ix = 0, 9 do
		for iz = 0, 9 do
			local x, z = -half + 3 + ix * 6, -half + 3 + iz * 6
			local onPath = math.abs(x) < 6
			add(part({ Name = "Flagstone", Size = Vector3.new(5.7, 0.2, 5.7), CFrame = CFrame.new(o + Vector3.new(x, 0, z)) * CFrame.Angles(0, math.rad(rng:NextNumber(-1.2, 1.2)), 0), Color = vary(onPath and pick(sand) or pick(stones), 0.02), Material = Enum.Material.Slate }))
		end
	end
	-- emblem: gold ring, blue field, four gold rays and a gold centre
	disc(folder, "EmblemRing", spawnPos + Vector3.new(0, 0.16, 0), 5.4, GOLD, Enum.Material.Metal)
	disc(folder, "EmblemField", spawnPos + Vector3.new(0, 0.18, 0), 4.7, rgb(38, 58, 120), Enum.Material.Slate)
	for k = 0, 3 do
		add(part({ Name = "EmblemRay", Size = Vector3.new(0.5, 0.06, 8.6), CFrame = CFrame.new(spawnPos + Vector3.new(0, 0.19, 0)) * CFrame.Angles(0, k * math.pi / 4, 0), Color = GOLD, Material = Enum.Material.Metal }))
	end
	disc(folder, "EmblemCore", spawnPos + Vector3.new(0, 0.22, 0), 1.3, GOLD, Enum.Material.Metal)

	--------------------------------------------------------------------------------------
	-- The keep (north): wall, plinth, string course, merlons, arrow slits, round-arched
	-- gate with a raised portcullis, gate buttresses with braziers, steps.
	local keepZ = -half -- front face of the keep
	add(part({ Name = "KeepWall", Size = Vector3.new(size + 4, keepH, 4), CFrame = CFrame.new(o + Vector3.new(0, keepH / 2, keepZ - 2)), Color = STONE, Material = Enum.Material.Cobblestone, CanCollide = true, CastShadow = true }))
	add(part({ Name = "KeepPlinth", Size = Vector3.new(size, 1.2, 0.8), CFrame = CFrame.new(o + Vector3.new(0, 0.6, keepZ + 0.2)), Color = STONE_DARK, Material = Enum.Material.Cobblestone }))
	add(part({ Name = "StringCourse", Size = Vector3.new(size, 0.8, 0.7), CFrame = CFrame.new(o + Vector3.new(0, 13.4, keepZ + 0.2)), Color = STONE_LIGHT, Material = Enum.Material.Slate }))
	for x = -half + 2, half - 2, 4 do
		add(part({ Name = "Merlon", Size = Vector3.new(2.4, 2.2, 4), CFrame = CFrame.new(o + Vector3.new(x, keepH + 1.1, keepZ - 2)), Color = STONE_LIGHT, Material = Enum.Material.Cobblestone, CastShadow = true }))
	end
	for _, x in ipairs({ -21, 21 }) do
		add(part({ Name = "ArrowSlit", Size = Vector3.new(0.8, 3.6, 0.1), CFrame = CFrame.new(o + Vector3.new(x, 9, keepZ + 0.05)), Color = rgb(28, 22, 20) }))
		add(part({ Name = "ArrowSlit", Size = Vector3.new(0.8, 2.6, 0.1), CFrame = CFrame.new(o + Vector3.new(x, 16, keepZ + 0.05)), Color = rgb(28, 22, 20) }))
	end
	-- gate: stone arch trim, warm-lit interior, raised portcullis teeth
	local gateR = 5.5
	local gateY = 6
	local function archShape(name: string, r: number, zOff: number, color: Color3, material: Enum.Material)
		add(part({ Name = name, Size = Vector3.new(r * 2, gateY, 0.3), CFrame = CFrame.new(o + Vector3.new(0, gateY / 2, keepZ + zOff)), Color = color, Material = material }))
		add(part({ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, r * 2, r * 2), CFrame = CFrame.new(o + Vector3.new(0, gateY, keepZ + zOff)) * CFrame.Angles(0, math.rad(90), 0), Color = color, Material = material }))
	end
	archShape("GateTrim", gateR + 1.2, 0.15, STONE_LIGHT, Enum.Material.Slate)
	archShape("GateDoorway", gateR, 0.35, rgb(64, 42, 30), Enum.Material.Wood)
	for x = -4.5, 4.5, 1.5 do
		local topY = gateY + math.sqrt(math.max(0, gateR * gateR - x * x))
		add(part({ Name = "Portcullis", Size = Vector3.new(0.3, topY - 8.4, 0.3), CFrame = CFrame.new(o + Vector3.new(x, (topY + 8.4) / 2, keepZ + 0.6)), Color = rgb(52, 52, 58), Material = Enum.Material.Metal }))
	end
	add(part({ Name = "Portcullis", Size = Vector3.new(10, 0.35, 0.35), CFrame = CFrame.new(o + Vector3.new(0, 8.6, keepZ + 0.6)), Color = rgb(52, 52, 58), Material = Enum.Material.Metal }))
	fireLight(folder, o + Vector3.new(0, 5, keepZ + 3), 16, 1.2, rgb(255, 180, 110))
	for _, x in ipairs({ -8.6, 8.6 }) do
		add(part({ Name = "Buttress", Size = Vector3.new(3, keepH + 3, 3), CFrame = CFrame.new(o + Vector3.new(x, (keepH + 3) / 2, keepZ - 0.5)), Color = STONE_LIGHT, Material = Enum.Material.Cobblestone, CanCollide = true, CastShadow = true }))
		add(part({ Name = "ButtressCap", Size = Vector3.new(3.6, 0.8, 3.6), CFrame = CFrame.new(o + Vector3.new(x, keepH + 3.4, keepZ - 0.5)), Color = STONE_DARK, Material = Enum.Material.Slate }))
		-- brazier on a bracket half way up
		add(part({ Name = "Bracket", Size = Vector3.new(0.5, 0.5, 1.6), CFrame = CFrame.new(o + Vector3.new(x, 10.2, keepZ + 1.6)), Color = rgb(52, 52, 58), Material = Enum.Material.Metal }))
		column(folder, "Brazier", o + Vector3.new(x, 10.4, keepZ + 2.4), 0.8, 0.7, rgb(60, 58, 62), Enum.Material.Metal)
		add(part({ Name = "BrazierFlame", Shape = Enum.PartType.Ball, Size = Vector3.new(1.1, 1.4, 1.1), CFrame = CFrame.new(o + Vector3.new(x, 11.6, keepZ + 2.4)), Color = rgb(255, 150, 50), Material = Enum.Material.Neon }))
		fireLight(folder, o + Vector3.new(x, 12, keepZ + 2.6), 20, 1.6, nil, true)
	end
	for _, x in ipairs({ -15.5, 15.5 }) do
		wallBanner(folder, x, 16.4, keepZ, o)
	end
	-- steps up to the gate (collidable, 0.6 studs each)
	for i, st in ipairs({ { 22, 9 }, { 19, 6 }, { 16, 3 } }) do
		local h = 0.6 * i
		add(part({ Name = "Step", Size = Vector3.new(st[1], h, st[2]), CFrame = CFrame.new(o + Vector3.new(0, h / 2, keepZ + st[2] / 2)), Color = i % 2 == 0 and STONE_LIGHT or rgb(160, 154, 144), Material = Enum.Material.Slate, CanCollide = true }))
	end
	-- ivy on the keep
	for _, iv in ipairs({ { -19.5, 1.5, 2.6, 6 }, { 20, 1, 3, 5 }, { -12, 15, 3.4, 4 }, { 12, 2.5, 4, 4 } }) do
		add(part({ Name = "Ivy", Size = Vector3.new(iv[3], iv[4], 0.2), CFrame = CFrame.new(o + Vector3.new(iv[1], iv[2] + iv[4] / 2 - 2, keepZ + 0.12)), Color = vary(rgb(70, 120, 60), 0.03), Material = Enum.Material.Grass }))
	end

	--------------------------------------------------------------------------------------
	-- Towers: tall roofed towers at the keep corners, short ones at the south corners.
	castleTower(folder, o + Vector3.new(-half, 0, keepZ), 6.5, 22, true, BANNER_RED)
	castleTower(folder, o + Vector3.new(half, 0, keepZ), 6.5, 22, true, rgb(45, 79, 191))
	castleTower(folder, o + Vector3.new(-half, 0, half), 4.5, 10, false, nil)
	castleTower(folder, o + Vector3.new(half, 0, half), 4.5, 10, false, nil)

	--------------------------------------------------------------------------------------
	-- Side walls (crenellated), the low south wall and tall invisible barriers.
	local walls = {
		{ Vector3.new(-half - 1.5, 0, 0), Vector3.new(3, sideH, size), "z" },
		{ Vector3.new(half + 1.5, 0, 0), Vector3.new(3, sideH, size), "z" },
		{ Vector3.new(0, 0, half + 1.5), Vector3.new(size, southH, 3), "x" },
	}
	for _, w in ipairs(walls) do
		local pos, sz = w[1], w[2]
		add(part({ Name = "Wall", Size = sz, CFrame = CFrame.new(o + pos + Vector3.new(0, sz.Y / 2, 0)), Color = STONE, Material = Enum.Material.Cobblestone, CanCollide = true, CastShadow = true }))
		add(part({ Name = "WallCap", Size = Vector3.new(sz.X + 0.4, 0.6, sz.Z + 0.4), CFrame = CFrame.new(o + pos + Vector3.new(0, sz.Y + 0.3, 0)), Color = STONE_LIGHT, Material = Enum.Material.Slate }))
		local length = w[3] == "z" and sz.Z or sz.X
		for t = -length / 2 + 4, length / 2 - 4, 4.5 do
			local off = w[3] == "z" and Vector3.new(0, 0, t) or Vector3.new(t, 0, 0)
			add(part({ Name = "Merlon", Size = Vector3.new(w[3] == "z" and 3 or 2.2, 1.8, w[3] == "z" and 2.2 or 3), CFrame = CFrame.new(o + pos + off + Vector3.new(0, sz.Y + 1.5, 0)), Color = STONE_LIGHT, Material = Enum.Material.Cobblestone }))
		end
	end
	for _, b in ipairs({
		{ Vector3.new(0, 20, -half - 2), Vector3.new(size + 2, 40, 2) },
		{ Vector3.new(0, 20, half + 1), Vector3.new(size + 2, 40, 2) },
		{ Vector3.new(-half - 1, 20, 0), Vector3.new(2, 40, size + 2) },
		{ Vector3.new(half + 1, 20, 0), Vector3.new(2, 40, size + 2) },
	}) do
		add(part({ Name = "Barrier", Size = b[2], CFrame = CFrame.new(o + b[1]), Transparency = 1, CanCollide = true }))
	end

	--------------------------------------------------------------------------------------
	-- Planters with bushes and flowers, exterminator supply corners.
	for _, sx in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -12, 6 }) do
			local c = o + Vector3.new(sx * (half - 3), 0, z)
			add(part({ Name = "Planter", Size = Vector3.new(4, 1.4, 9), CFrame = CFrame.new(c + Vector3.new(0, 0.7, 0)), Color = STONE_DARK, Material = Enum.Material.Cobblestone, CanCollide = true }))
			add(part({ Name = "Soil", Size = Vector3.new(3.4, 0.2, 8.4), CFrame = CFrame.new(c + Vector3.new(0, 1.35, 0)), Color = rgb(70, 50, 36), Material = Enum.Material.Ground }))
			for _, dz in ipairs({ -2.3, 2.3 }) do
				prop(folder, "Bush", CFrame.new(c + Vector3.new(0, 1.3, dz)) * randomYaw(), rng:NextNumber(0.75, 0.9), { Leaf = vary(rgb(79, 160, 74), 0.04), Accent = pick({ rgb(255, 90, 138), rgb(255, 210, 90), rgb(190, 120, 255) }) })
			end
			for _, f in ipairs({ { -1, 0 }, { 1, 0.4 }, { 0.2, -0.6 } }) do
				add(part({ Name = "Flower", Shape = Enum.PartType.Ball, Size = Vector3.new(0.6, 0.6, 0.6), CFrame = CFrame.new(c + Vector3.new(f[1], 1.7, f[2] * 2)), Color = pick({ rgb(255, 240, 120), rgb(255, 120, 150), rgb(255, 255, 255) }) }))
			end
		end
	end
	-- torches: at the steps and along the side walls
	local torchSpots = { Vector3.new(-11.8, 0, keepZ + 9.6), Vector3.new(11.8, 0, keepZ + 9.6) }
	for _, sx in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -18, -3, 13 }) do
			table.insert(torchSpots, Vector3.new(sx * (half - 1.6), 0, z))
		end
	end
	for _, t in ipairs(torchSpots) do
		prop(folder, "Torch", CFrame.new(o + t) * randomYaw(), 1.15)
		fireLight(folder, o + t + Vector3.new(0, 6, 0), 18, 1.4, nil, true)
	end
	-- pole banners in front of the towers (rotated so the emblem side faces the courtyard)
	for _, x in ipairs({ -23, 23 }) do
		prop(folder, "Banner", CFrame.new(o + Vector3.new(x, 0, keepZ + 8.5)) * CFrame.Angles(0, math.pi, 0), 1.2)
	end
	-- supply corners: crates, barrels and a pesticide tank (the heroes are exterminators)
	for _, sx in ipairs({ -1, 1 }) do
		local c = o + Vector3.new(sx * 21, 0, 17)
		add(part({ Name = "Crate", Size = Vector3.new(3, 3, 3), CFrame = CFrame.new(c + Vector3.new(0, 1.5, 0)) * CFrame.Angles(0, math.rad(12 * sx), 0), Color = WOOD, Material = Enum.Material.WoodPlanks, CanCollide = true, CastShadow = true }))
		add(part({ Name = "Crate", Size = Vector3.new(2.2, 2.2, 2.2), CFrame = CFrame.new(c + Vector3.new(0.3 * sx, 4.1, 0.2)) * CFrame.Angles(0, math.rad(-20 * sx), 0), Color = vary(WOOD, 0.04), Material = Enum.Material.WoodPlanks, CastShadow = true }))
		column(folder, "Barrel", c + Vector3.new(3 * sx, 0, 1.5), 1.1, 2.8, rgb(96, 64, 40), Enum.Material.Wood, { CanCollide = true })
		column(folder, "BarrelHoop", c + Vector3.new(3 * sx, 1.9, 1.5), 1.15, 0.25, rgb(60, 60, 66), Enum.Material.Metal)
		column(folder, "Tank", c + Vector3.new(-2.6 * sx, 0, 2), 1, 3.6, rgb(236, 196, 40), Enum.Material.Metal, { CanCollide = true })
		column(folder, "TankStripe", c + Vector3.new(-2.6 * sx, 2.2, 2), 1.05, 0.5, rgb(30, 30, 34), Enum.Material.SmoothPlastic)
		add(part({ Name = "TankGauge", Shape = Enum.PartType.Ball, Size = Vector3.new(0.6, 0.6, 0.6), CFrame = CFrame.new(c + Vector3.new(-2.6 * sx, 3.1, 3)), Color = rgb(120, 255, 120), Material = Enum.Material.Neon }))
	end

	--------------------------------------------------------------------------------------
	-- Pine forest behind and beside the castle (backdrop over the walls).
	local pinePalettes = { { Leaf = rgb(47, 125, 70) }, { Leaf = rgb(40, 108, 66) }, { Leaf = rgb(58, 132, 70) } }
	for i = 1, 26 do
		local x = rng:NextNumber(-95, 95)
		local z = rng:NextNumber(-95, -42)
		if math.abs(x) > 40 or z < -50 or i % 3 == 0 then
			prop(folder, "Tree_Pine", CFrame.new(o + Vector3.new(x, -0.3, z)) * randomYaw(), rng:NextNumber(1.6, 2.6), pick(pinePalettes), true)
		end
	end
	for _, sx in ipairs({ -1, 1 }) do
		for _ = 1, 6 do
			prop(folder, "Tree_Round", CFrame.new(o + Vector3.new(sx * rng:NextNumber(42, 70), -0.3, rng:NextNumber(-35, 20))) * randomYaw(), rng:NextNumber(1, 1.5), nil, true)
		end
	end

	--------------------------------------------------------------------------------------
	-- Ambient particles: warm dust motes and a few fireflies over the courtyard.
	local air = add(part({ Name = "Ambience", Size = Vector3.new(size - 6, 6, size - 10), CFrame = CFrame.new(o + Vector3.new(0, 4, 2)), Transparency = 1 }))
	local function emitter(name: string, color: Color3, rate: number, sizePx: number, life: number, speed: number)
		local e = Instance.new("ParticleEmitter")
		e.Name = name
		e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		e.Color = ColorSequence.new(color)
		e.LightEmission = 1
		e.LightInfluence = 0
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, sizePx), NumberSequenceKeypoint.new(1, 0) })
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.2), NumberSequenceKeypoint.new(1, 1) })
		e.Lifetime = NumberRange.new(life * 0.6, life)
		e.Rate = rate
		e.Speed = NumberRange.new(speed * 0.5, speed)
		e.SpreadAngle = Vector2.new(180, 180)
		e.Acceleration = Vector3.new(0, 0.15, 0)
		e.RotSpeed = NumberRange.new(-30, 30)
		e.Shape = Enum.ParticleEmitterShape.Box
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		e.Parent = air
	end
	emitter("Motes", rgb(255, 222, 170), 7, 0.22, 9, 0.6)
	emitter("Fireflies", rgb(210, 255, 120), 3, 0.35, 6, 1.2)

	--------------------------------------------------------------------------------------
	-- Legacy prompts / boards. The 2D menu replaces them; they stay valid (RunManager
	-- connects to them) but sit small against the south wall, out of the menu shot.
	local TILT = CFrame.Angles(math.rad(-50), 0, 0) -- turns the Back (+Z) face up to the camera
	local FACE_NORTH = CFrame.Angles(0, math.pi, 0) -- turns the Back face toward the keep
	local southZ = half - 1
	local function startPad(name: string, x: number, color: Color3, ringColor: Color3, title: string, objectText: string)
		local padPos = o + Vector3.new(x, 0.12, southZ - 5)
		local pad = add(part({ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 4, 4), CFrame = CFrame.new(padPos) * UPRIGHT, Color = color, Material = Enum.Material.SmoothPlastic, CanQuery = true }))
		add(part({ Name = name .. "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.16, 4.8, 4.8), CFrame = CFrame.new(padPos - Vector3.new(0, 0.03, 0)) * UPRIGHT, Color = ringColor }))
		local sign = add(part({ Name = name .. "Sign", Size = Vector3.new(4, 1.2, 0.3), CFrame = CFrame.new(o + Vector3.new(x, 2.6, southZ - 0.3)) * FACE_NORTH, Color = rgb(25, 25, 35) }))
		textSurface(sign, Enum.NormalId.Back, title, color)
		local pr = prompt(pad, "Start Run", objectText, name .. "Prompt")
		pr.MaxActivationDistance = 6
		return pad, pr
	end
	local pad, startPrompt = startPad("StartPad", -5, rgb(60, 200, 110), rgb(30, 90, 50), "SQUAD", "Squad (1-4 players)")
	local duoPad, duoPrompt = startPad("DuoPad", 5, rgb(80, 160, 240), rgb(30, 60, 110), "DUO", "Duo (2 players)")

	local arenaSign = add(part({ Name = "ArenaSign", Size = Vector3.new(5, 2.2, 0.3), CFrame = CFrame.new(o + Vector3.new(-12, 1.4, southZ - 3)) * FACE_NORTH * TILT, Color = rgb(25, 25, 35), CanCollide = true }))
	local arenaGui = textSurface(arenaSign, Enum.NormalId.Back, "ARENA: FOREST", rgb(255, 220, 120))
	local arenaPrompt = prompt(arenaSign, "Change Arena", "Arena", "ArenaPrompt")

	local charBoard = add(part({ Name = "CharacterBoard", Size = Vector3.new(5, 2, 0.3), CFrame = CFrame.new(o + Vector3.new(-19, 3.2, southZ - 0.3)) * FACE_NORTH, Color = rgb(30, 30, 45) }))
	textSurface(charBoard, Enum.NormalId.Back, "CHARACTERS", rgb(120, 200, 255))
	local charPost = add(part({ Name = "CharacterPost", Size = Vector3.new(1.2, 1, 1.2), CFrame = CFrame.new(o + Vector3.new(-19, 0.5, southZ - 2.5)), Color = WOOD, CanCollide = true }))
	local charPrompt = prompt(charPost, "Choose Character", "Characters", "CharacterPrompt")

	local shopBoard = add(part({ Name = "ShopBoard", Size = Vector3.new(5, 2, 0.3), CFrame = CFrame.new(o + Vector3.new(19, 3.2, southZ - 0.3)) * FACE_NORTH, Color = rgb(30, 30, 45) }))
	textSurface(shopBoard, Enum.NormalId.Back, "UPGRADES", rgb(255, 210, 80))
	local shopPost = add(part({ Name = "ShopPost", Size = Vector3.new(1.2, 1, 1.2), CFrame = CFrame.new(o + Vector3.new(19, 0.5, southZ - 2.5)), Color = WOOD, CanCollide = true }))
	local shopPrompt = prompt(shopPost, "Open Shop", "Upgrades", "ShopPrompt")

	-- stats lectern: each client draws its own stats on the Back face (UIBuilder)
	local statsSign = add(part({ Name = "StatsSign", Size = Vector3.new(5, 3.4, 0.3), CFrame = CFrame.new(o + Vector3.new(12, 1.8, southZ - 3)) * FACE_NORTH * TILT, Color = rgb(30, 30, 45), CanCollide = true }))

	--------------------------------------------------------------------------------------
	-- Menu camera: a fixed shot from the south end of the courtyard, aimed just above head
	-- height over the spawn emblem (frames well at FOV 50-60): the character sits
	-- mid-screen in front of the warm-lit gate, with banners, braziers and roofed towers
	-- behind and torches, planters and supply crates along the edges.
	local fov = Config.Lobby.MenuFieldOfView or 55
	local camPos = o + Vector3.new(0, 7, half - 5.5)
	local camLook = spawnPos + Vector3.new(0, 6, 0)
	local menuCamera = add(part({ Name = "MenuCamera", Size = Vector3.new(1, 1, 1), CFrame = CFrame.lookAt(camPos, camLook), Transparency = 1 }))
	menuCamera:SetAttribute("FieldOfView", fov)
	menuCamera:SetAttribute("Focus", camLook)

	MapBuilder.ApplyLighting("Lobby")

	return {
		Model = folder,
		SpawnCFrame = CFrame.new(spawnPos + Vector3.new(0, 3.5, 0)),
		MenuCamera = menuCamera,
		StartPrompt = startPrompt,
		DuoPrompt = duoPrompt,
		DuoPad = duoPad,
		ArenaPrompt = arenaPrompt,
		ArenaLabel = arenaGui:FindFirstChild("Title") :: TextLabel,
		CharacterPrompt = charPrompt,
		ShopPrompt = shopPrompt,
		StatsSign = statsSign,
		StartPad = pad,
	}
end

------------------------------------------------------------------------------------------
-- ARENAS
------------------------------------------------------------------------------------------

local function newArena(name: string)
	local root = ensureMapFolder()
	local model = Instance.new("Model")
	model.Name = "Arena_" .. name
	local obstacleFolder = Instance.new("Folder")
	obstacleFolder.Name = "Obstacles"
	obstacleFolder.Parent = model
	return {
		Name = name,
		Model = model,
		ObstacleFolder = obstacleFolder,
		Obstacles = {},
		Keepout = {}, -- { X, Z, R } circles that props avoid (paths, pond, decoration)
		Root = root,
		Half = Config.Arenas.Size / 2,
		Center = Config.ArenaOrigin,
		Clear = Config.Arenas.ClearRadius or 40,
		Trees = 0,
		Rocks = 0,
	}
end

-- Is (x, z) inside the fence, out of the spawn clearing, and `clear` studs from every
-- obstacle and keepout circle?
local function isFree(arena, x: number, z: number, clear: number): boolean
	local c = arena.Center
	local dx, dz = x - c.X, z - c.Z
	if dx * dx + dz * dz < arena.Clear * arena.Clear then
		return false
	end
	if math.abs(dx) > arena.Half - 4 or math.abs(dz) > arena.Half - 4 then
		return false
	end
	for _, ob in ipairs(arena.Obstacles) do
		if ob.Kind == "Circle" then
			local ox, oz = ob.Pos.X - x, ob.Pos.Z - z
			local r = ob.Radius + clear
			if ox * ox + oz * oz < r * r then
				return false
			end
		elseif x > ob.MinX - clear and x < ob.MaxX + clear and z > ob.MinZ - clear and z < ob.MaxZ + clear then
			return false
		end
	end
	for _, k in ipairs(arena.Keepout) do
		local kx, kz = k.X - x, k.Z - z
		local r = k.R + clear * 0.5
		if kx * kx + kz * kz < r * r then
			return false
		end
	end
	return true
end

-- Free spot at a distance between rMin and rMax from the centre (inside the square).
local function findSpot(arena, rMin: number, rMax: number, clear: number): (number?, number?)
	local c = arena.Center
	for _ = 1, 50 do
		local a = rng:NextNumber(0, TAU)
		local r = math.sqrt(rng:NextNumber(rMin * rMin, rMax * rMax))
		local x, z = c.X + math.cos(a) * r, c.Z + math.sin(a) * r
		if isFree(arena, x, z, clear) then
			return x, z
		end
	end
	return nil, nil
end

-- Calls fn(x, z, i) for up to `count` free spots scattered around (cx, cz).
local function cluster(arena, cx: number, cz: number, spread: number, count: number, clear: number, fn: (number, number, number) -> ())
	local placed = 0
	for _ = 1, count * 6 do
		if placed >= count then
			return
		end
		local a = rng:NextNumber(0, TAU)
		local r = spread * math.sqrt(rng:NextNumber())
		local x, z = cx + math.cos(a) * r, cz + math.sin(a) * r
		if isFree(arena, x, z, clear) then
			placed += 1
			fn(x, z, placed)
		end
	end
end

local function keepout(arena, x: number, z: number, r: number)
	table.insert(arena.Keepout, { X = x, Z = z, R = r })
end

local function circleCollider(arena, x: number, z: number, r: number, h: number)
	local y = arena.Center.Y
	local c = part({ Name = "Collider", Shape = Enum.PartType.Cylinder, Size = Vector3.new(h, r * 2, r * 2), CFrame = CFrame.new(x, y + h / 2, z) * UPRIGHT, Transparency = 1, CanCollide = true, CanQuery = true })
	c.Parent = arena.ObstacleFolder
	table.insert(arena.Obstacles, { Kind = "Circle", Pos = Vector3.new(x, y, z), Radius = r })
end

-- Axis-aligned box collider (the obstacle format is an AABB).
local function boxCollider(arena, cx: number, cz: number, sx: number, sz: number, h: number)
	local y = arena.Center.Y
	local c = part({ Name = "Collider", Size = Vector3.new(sx, h, sz), CFrame = CFrame.new(cx, y + h / 2, cz), Transparency = 1, CanCollide = true, CanQuery = true })
	c.Parent = arena.ObstacleFolder
	table.insert(arena.Obstacles, {
		Kind = "Box",
		Pos = Vector3.new(cx, y, cz),
		Radius = math.sqrt(sx * sx + sz * sz) / 2,
		MinX = cx - sx / 2,
		MaxX = cx + sx / 2,
		MinZ = cz - sz / 2,
		MaxZ = cz + sz / 2,
	})
end

-- Invisible tall walls just outside the play square (enemy raycasts hit them).
local function boundaryWalls(arena)
	local c, h = arena.Center, arena.Half
	local size = Config.Arenas.Size
	for i, side in ipairs({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0) }) do
		local wallSize = (i <= 2) and Vector3.new(size + 4, 60, 2) or Vector3.new(2, 60, size + 4)
		local wall = part({ Name = "Boundary", Size = wallSize, CFrame = CFrame.new(c + side * (h + 1) + Vector3.new(0, 30, 0)), Transparency = 1, CanCollide = true, CanQuery = true })
		wall.Parent = arena.ObstacleFolder
	end
end

-- Walks the four sides: fn(pos, outward, along, sideIndex, t) every `step` studs.
-- Side 2 is the south (+Z), the side nearest the camera.
local function alongSides(arena, step: number, from: number, to: number, fn: (Vector3, Vector3, Vector3, number, number) -> ())
	local c, h = arena.Center, arena.Half
	for i, side in ipairs({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0) }) do
		local along = (i <= 2) and Vector3.new(1, 0, 0) or Vector3.new(0, 0, 1)
		local t = from
		while t <= to do
			fn(c + side * h + along * t, side, along, i, t)
			t += step
		end
	end
end

local function isNearKeepout(arena, pos: Vector3, pad: number): boolean
	for _, k in ipairs(arena.Keepout) do
		local dx, dz = k.X - pos.X, k.Z - pos.Z
		if dx * dx + dz * dz < (k.R + pad) * (k.R + pad) then
			return true
		end
	end
	return false
end

-- Shared prop placers ------------------------------------------------------------------

local ROUND_LEAVES: { Palette } = {
	{ Leaf = rgb(79, 174, 74), Leaf2 = rgb(60, 143, 63) },
	{ Leaf = rgb(98, 182, 70), Leaf2 = rgb(72, 150, 58) },
	{ Leaf = rgb(66, 152, 80), Leaf2 = rgb(48, 122, 64) },
	{ Leaf = rgb(120, 180, 64), Leaf2 = rgb(86, 150, 56) },
}
local PINE_LEAVES: { Palette } = { { Leaf = rgb(47, 125, 70) }, { Leaf = rgb(40, 110, 72) }, { Leaf = rgb(58, 136, 66) } }

local function tree(arena, x: number, z: number, s: number, kind: string, palette: Palette?)
	prop(arena.Model, kind, CFrame.new(x, arena.Center.Y, z) * randomYaw(), s, palette, true)
	circleCollider(arena, x, z, (kind == "Tree_Round" and 1.3 or 0.95) * s, 8)
	arena.Trees += 1
end

-- Mushrooms of scale >= 0.85 block movement; smaller ones are clutter.
local function mushroom(arena, x: number, z: number, s: number, palette: Palette?)
	prop(arena.Model, "Mushroom", CFrame.new(x, arena.Center.Y, z) * randomYaw(), s, palette, s >= 0.85)
	if s >= 0.85 then
		circleCollider(arena, x, z, 0.9 * s, 5 * s)
	else
		keepout(arena, x, z, 1.2 * s + 0.5)
	end
end

-- Rocks of scale >= 0.9 block movement; smaller ones are clutter.
local function rock(arena, x: number, z: number, s: number, palette: Palette?)
	prop(arena.Model, "Rock", CFrame.new(x, arena.Center.Y - 0.15 * s, z) * randomYaw(), s, palette, s >= 0.9)
	if s >= 0.9 then
		circleCollider(arena, x, z, 2.2 * s, 3 * s)
		arena.Rocks += 1
	else
		keepout(arena, x, z, 2 * s)
	end
end

local function bush(arena, x: number, z: number, s: number, palette: Palette?)
	prop(arena.Model, "Bush", CFrame.new(x, arena.Center.Y - 0.1, z) * randomYaw(), s, palette, false)
	keepout(arena, x, z, 1.8 * s)
end

-- Little cluster of flowers (tiny balls, no shadow).
local function flowers(arena, x: number, z: number, colors: { Color3 })
	local y = arena.Center.Y
	for _ = 1, rng:NextInteger(3, 5) do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(0, 2.2)
		deco(arena.Model, { Name = "Flower", Shape = Enum.PartType.Ball, Size = Vector3.new(0.55, 0.45, 0.55), CFrame = CFrame.new(x + math.cos(a) * r, y + 0.3, z + math.sin(a) * r), Color = pick(colors) })
	end
end

-- Wobbly flat path from the centre clearing out past the boundary.
local function groundPath(arena, angle: number, width: number, colors: { Color3 }, material: Enum.Material, startR: number)
	local c, h = arena.Center, arena.Half
	local pts: { Vector3 } = {}
	local wob = rng:NextNumber(0, 10)
	local r = startR
	while r < h * 1.5 do
		local a = angle + math.sin(r * 0.022 + wob) * 0.2
		local p = Vector3.new(c.X + math.cos(a) * r, c.Y, c.Z + math.sin(a) * r)
		table.insert(pts, p)
		if math.abs(p.X - c.X) > h + 24 or math.abs(p.Z - c.Z) > h + 24 then
			break
		end
		r += 22
	end
	for i = 1, #pts - 1 do
		local p0, p1 = pts[i], pts[i + 1]
		local mid = (p0 + p1) / 2
		local col = vary(pick(colors), 0.015)
		deco(arena.Model, { Name = "Path", Size = Vector3.new(width, 0.1, (p1 - p0).Magnitude + 0.6), CFrame = CFrame.lookAt(mid, p1) + Vector3.new(0, 0.03 + i * 0.0004, 0), Color = col, Material = material })
		disc(arena.Model, "PathBend", p1 + Vector3.new(0, 0.085, 0), width / 2, col, material)
		keepout(arena, p0.X, p0.Z, width / 2 + 2)
		keepout(arena, mid.X, mid.Z, width / 2 + 2)
	end
end

------------------------------------------------------------------------------------------
-- FOREST: a sunny clearing in the woods. Dirt paths lead out from the spawn clearing;
-- trees grow in groves and as a dense tree line beyond a broken split-rail fence; red
-- mushrooms cluster in tree shade and in fairy rings; a reed pond, rock outcrops, fallen
-- logs, flowers, and a few purple alien hive nests where the swarm is breaking through.
------------------------------------------------------------------------------------------

local function forestPond(arena)
	local x, z = findSpot(arena, 95, 165, 22)
	if not (x and z) then
		return
	end
	local y = arena.Center.Y
	local r = rng:NextNumber(12, 16)
	disc(arena.Model, "PondBank", Vector3.new(x, y + 0.09, z), r + 3.5, rgb(122, 104, 74), Enum.Material.Ground)
	disc(arena.Model, "PondBed", Vector3.new(x, y + 0.1, z), r + 0.6, rgb(42, 70, 74), Enum.Material.Slate)
	local water = disc(arena.Model, "Water", Vector3.new(x, y + 0.2, z), r, rgb(70, 140, 172), Enum.Material.Glass, 0.1)
	water.Transparency = 0.3
	water.Reflectance = 0.15
	for _ = 1, 6 do
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(2, r - 2)
		disc(arena.Model, "LilyPad", Vector3.new(x + math.cos(a) * d, y + 0.23, z + math.sin(a) * d), rng:NextNumber(0.7, 1.2), rgb(70, 150, 70), Enum.Material.Grass, 0.04)
	end
	-- reeds on one side, rocks around the rim
	local side = rng:NextNumber(0, TAU)
	for _ = 1, 9 do
		local a = side + rng:NextNumber(-0.7, 0.7)
		local d = r + rng:NextNumber(-1, 1.5)
		local hgt = rng:NextNumber(2.4, 3.8)
		local px, pz = x + math.cos(a) * d, z + math.sin(a) * d
		deco(arena.Model, { Name = "Reed", Size = Vector3.new(0.18, hgt, 0.18), CFrame = CFrame.new(px, y + hgt / 2, pz) * CFrame.Angles(rng:NextNumber(-0.12, 0.12), 0, rng:NextNumber(-0.12, 0.12)), Color = rgb(96, 136, 60), Material = Enum.Material.Grass })
		deco(arena.Model, { Name = "Cattail", Size = Vector3.new(0.35, 0.8, 0.35), CFrame = CFrame.new(px, y + hgt + 0.2, pz), Color = rgb(110, 70, 40) })
	end
	for k = 1, 5 do
		local a = side + math.pi + (k - 3) * 0.45
		local d = r + 2
		rock(arena, x + math.cos(a) * d, z + math.sin(a) * d, rng:NextNumber(0.4, 0.75), { Stone = rgb(120, 124, 132) })
	end
	circleCollider(arena, x, z, r, 4)
	keepout(arena, x, z, r + 4)
end

local function alienNest(arena, x: number, z: number)
	local y = arena.Center.Y
	local m = arena.Model
	local r = rng:NextNumber(7, 10)
	disc(m, "Goo", Vector3.new(x, y + 0.11, z), r, rgb(52, 30, 70), Enum.Material.SmoothPlastic)
	disc(m, "GooRim", Vector3.new(x, y + 0.1, z), r + 1.4, rgb(84, 70, 60), Enum.Material.Ground)
	for k = 1, 5 do
		local a = k / 5 * TAU + rng:NextNumber(-0.3, 0.3)
		local len = rng:NextNumber(r * 0.6, r * 1.1)
		local mid = Vector3.new(x + math.cos(a) * len / 2, y + 0.13, z + math.sin(a) * len / 2)
		deco(m, { Name = "Vein", Size = Vector3.new(0.35, 0.05, len), CFrame = CFrame.lookAt(mid, Vector3.new(x, mid.Y, z)), Color = rgb(190, 90, 255), Material = Enum.Material.Neon })
	end
	-- hive mound (collidable) and egg pods
	column(m, "Hive", Vector3.new(x, y, z), 3, 2.4, rgb(92, 62, 82), Enum.Material.Slate, { CastShadow = true })
	column(m, "Hive", Vector3.new(x, y + 2.4, z), 2.2, 2, rgb(104, 70, 92), Enum.Material.Slate, { CastShadow = true })
	column(m, "Hive", Vector3.new(x, y + 4.4, z), 1.2, 1.4, rgb(116, 80, 104), Enum.Material.Slate)
	deco(m, { Name = "HiveGlow", Shape = Enum.PartType.Ball, Size = Vector3.new(1.2, 1.2, 1.2), CFrame = CFrame.new(x, y + 5.6, z), Color = rgb(200, 110, 255), Material = Enum.Material.Neon })
	circleCollider(arena, x, z, 3, 5)
	for k = 1, 4 do
		local a = rng:NextNumber(0, TAU)
		local d = rng:NextNumber(4.5, r - 1)
		local px, pz = x + math.cos(a) * d, z + math.sin(a) * d
		local pod = deco(m, { Name = "EggPod", Shape = Enum.PartType.Ball, Size = Vector3.new(1.8, 2.3, 1.8), CFrame = CFrame.new(px, y + 1, pz), Color = rgb(170, 220, 90), Material = Enum.Material.Glass, Transparency = 0.35 })
		pod.CastShadow = false
		deco(m, { Name = "EggCore", Shape = Enum.PartType.Ball, Size = Vector3.new(0.8, 1, 0.8), CFrame = CFrame.new(px, y + 1, pz), Color = rgb(200, 255, 100), Material = Enum.Material.Neon })
		if k == 1 then
			keepout(arena, px, pz, 1.5)
		end
	end
	keepout(arena, x, z, r + 2)
end

local function fallenLog(arena, x: number, z: number)
	local y = arena.Center.Y
	local len = rng:NextNumber(9, 13)
	local d = rng:NextNumber(2, 2.6)
	local alongX = rng:NextNumber() < 0.5
	local yaw = (alongX and 0 or math.pi / 2) + math.rad(rng:NextNumber(-6, 6))
	local cf = CFrame.new(x, y + d / 2 - 0.15, z) * CFrame.Angles(0, yaw, 0)
	deco(arena.Model, { Name = "Log", Shape = Enum.PartType.Cylinder, Size = Vector3.new(len, d, d), CFrame = cf, Color = rgb(112, 80, 52), Material = Enum.Material.Wood, CastShadow = true })
	for _, e in ipairs({ -1, 1 }) do
		deco(arena.Model, { Name = "LogEnd", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, d - 0.25, d - 0.25), CFrame = cf * CFrame.new(e * len / 2, 0, 0), Color = rgb(196, 156, 104), Material = Enum.Material.Wood })
	end
	deco(arena.Model, { Name = "LogMoss", Size = Vector3.new(len * 0.45, 0.2, d * 0.6), CFrame = cf * CFrame.new(rng:NextNumber(-1, 1), d / 2 - 0.02, 0), Color = rgb(92, 150, 70), Material = Enum.Material.Grass })
	local sx, sz = (alongX and len or d) + 0.4, (alongX and d or len) + 0.4
	boxCollider(arena, x, z, sx, sz, d)
end

local function buildForest(arena)
	local c, h = arena.Center, arena.Half
	local m = arena.Model
	local y = c.Y

	-- ground: darker forest floor everywhere, bright meadow inside the fence
	deco(m, { Name = "ForestFloor", Size = Vector3.new(h * 2 + 360, 2, h * 2 + 360), CFrame = CFrame.new(c - Vector3.new(0, 1.06, 0)), Color = rgb(74, 118, 54), Material = Enum.Material.Grass, CanCollide = true, CanQuery = true })
	deco(m, { Name = "Floor", Size = Vector3.new(h * 2 + 4, 1, h * 2 + 4), CFrame = CFrame.new(c - Vector3.new(0, 0.5, 0)), Color = rgb(104, 178, 76), Material = Enum.Material.Grass, CanCollide = true, CanQuery = true })
	for _ = 1, 30 do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(20, h * 1.1)
		local px, pz = c.X + math.clamp(math.cos(a) * r, -h + 10, h - 10), c.Z + math.clamp(math.sin(a) * r, -h + 10, h - 10)
		local tone = pick({ rgb(88, 160, 66), rgb(118, 186, 82), rgb(96, 168, 70), rgb(132, 178, 84) })
		disc(m, "Patch", Vector3.new(px, y + 0.02 + rng:NextNumber(0, 0.03), pz), rng:NextNumber(9, 24), tone)
	end

	-- spawn clearing: worn grass ring, packed dirt, a ring of flat stones
	disc(m, "Clearing", Vector3.new(c.X, y + 0.06, c.Z), 22, rgb(130, 168, 84))
	disc(m, "ClearingDirt", Vector3.new(c.X, y + 0.1, c.Z), 15, rgb(140, 112, 80), Enum.Material.Ground)
	for k = 1, 10 do
		local a = k / 10 * TAU
		disc(m, "FlatStone", Vector3.new(c.X + math.cos(a) * 17, y + 0.14, c.Z + math.sin(a) * 17), rng:NextNumber(0.9, 1.4), rgb(150, 150, 156), Enum.Material.Slate, 0.2)
	end
	local pathColors = { rgb(146, 116, 80), rgb(138, 110, 78), rgb(152, 124, 88) }
	local base = rng:NextNumber(0, TAU)
	for k = 0, 3 do
		groundPath(arena, base + k * math.pi / 2 + rng:NextNumber(-0.35, 0.35), rng:NextNumber(6, 8), pathColors, Enum.Material.Ground, 14)
	end

	boundaryWalls(arena)
	forestPond(arena)

	-- alien nests: the swarm breaking through
	for _ = 1, 3 do
		local x, z = findSpot(arena, 70, h * 1.2, 14)
		if x and z then
			alienNest(arena, x, z)
			for k = 1, 3 do
				local a = rng:NextNumber(0, TAU)
				local px, pz = x + math.cos(a) * 12, z + math.sin(a) * 12
				if isFree(arena, px, pz, 2) then
					mushroom(arena, px, pz, rng:NextNumber(0.4, 0.6) + k * 0.05, { Accent = rgb(150, 80, 220), White = rgb(220, 255, 140) })
				end
			end
		end
	end

	-- groves: tight stands of trees with mushrooms in their shade and bushes at the edge
	local treeCap = Config.Arenas.TreeCount or 34
	for _ = 1, 7 do
		local gx, gz = findSpot(arena, 65, h * 1.25, 16)
		if gx and gz and arena.Trees < treeCap then
			local pine = rng:NextNumber() < 0.35
			cluster(arena, gx, gz, 12, rng:NextInteger(4, 6), 5, function(x, z)
				if arena.Trees < treeCap then
					local kind = (pine or rng:NextNumber() < 0.2) and "Tree_Pine" or "Tree_Round"
					tree(arena, x, z, rng:NextNumber(0.85, 1.25), kind, kind == "Tree_Pine" and pick(PINE_LEAVES) or pick(ROUND_LEAVES))
				end
			end)
			local a = rng:NextNumber(0, TAU)
			cluster(arena, gx + math.cos(a) * 13, gz + math.sin(a) * 13, 5, rng:NextInteger(2, 5), 1.5, function(x, z, i)
				mushroom(arena, x, z, i == 1 and rng:NextNumber(0.9, 1.25) or rng:NextNumber(0.45, 0.75))
			end)
			cluster(arena, gx, gz, 18, rng:NextInteger(2, 4), 2, function(x, z)
				bush(arena, x, z, rng:NextNumber(0.8, 1.2))
			end)
		end
	end

	-- landmark trees: big lone oaks in the open with flowers around them
	for _ = 1, 3 do
		local x, z = findSpot(arena, 55, h * 1.2, 12)
		if x and z then
			tree(arena, x, z, rng:NextNumber(1.35, 1.55), "Tree_Round", pick(ROUND_LEAVES))
			for k = 1, 3 do
				local a = k / 3 * TAU + rng:NextNumber(-0.4, 0.4)
				flowers(arena, x + math.cos(a) * 6, z + math.sin(a) * 6, { rgb(255, 255, 255), rgb(255, 226, 90), rgb(255, 150, 190) })
			end
		end
	end

	-- fairy rings of small mushrooms (clutter)
	for _ = 1, 2 do
		local x, z = findSpot(arena, 50, h * 1.2, 9)
		if x and z then
			local n = rng:NextInteger(7, 9)
			for k = 1, n do
				local a = k / n * TAU
				mushroom(arena, x + math.cos(a) * 5, z + math.sin(a) * 5, rng:NextNumber(0.32, 0.45))
			end
			keepout(arena, x, z, 6)
		end
	end

	-- rock outcrops: one big rock with smaller ones around it
	local rockCap = Config.Arenas.RockCount or 26
	for _ = 1, 6 do
		local x, z = findSpot(arena, 50, h * 1.25, 9)
		if x and z and arena.Rocks < rockCap then
			rock(arena, x, z, rng:NextNumber(1.2, 1.7))
			cluster(arena, x, z, 7, rng:NextInteger(1, 3), 2.5, function(px, pz)
				rock(arena, px, pz, rng:NextNumber(0.45, 0.85))
			end)
		end
	end

	-- fallen logs
	for _ = 1, 5 do
		local x, z = findSpot(arena, 50, h * 1.2, 9)
		if x and z then
			fallenLog(arena, x, z)
		end
	end

	-- flower patches and loose bushes in the meadow
	for _ = 1, 9 do
		local x, z = findSpot(arena, 30, h * 1.25, 3)
		if x and z then
			flowers(arena, x, z, pick({ { rgb(255, 255, 255), rgb(255, 240, 120) }, { rgb(190, 130, 255), rgb(255, 255, 255) }, { rgb(255, 120, 150), rgb(255, 210, 90) } }))
		end
	end
	for _ = 1, 6 do
		local x, z = findSpot(arena, 45, h * 1.25, 6)
		if x and z then
			cluster(arena, x, z, 4, rng:NextInteger(2, 3), 1.5, function(px, pz)
				bush(arena, px, pz, rng:NextNumber(0.7, 1.1))
			end)
		end
	end

	-- BORDER: broken split-rail fence with bushes, then the tree line outside.
	local fenceH = Config.Arenas.FenceHeight or 6
	local fenceOn = true
	local wood = rgb(150, 116, 80)
	alongSides(arena, 20, -h, h - 20, function(pos, out, along, side, _t)
		if rng:NextNumber() < 0.18 then
			fenceOn = not fenceOn
		end
		local mid = pos + along * 10
		if fenceOn and not isNearKeepout(arena, mid, 2) then
			deco(m, { Name = "Post", Size = Vector3.new(0.9, fenceH, 0.9), CFrame = CFrame.new(pos + Vector3.new(0, fenceH / 2 - 0.3, 0)) * CFrame.Angles(0, rng:NextNumber(-0.2, 0.2), 0), Color = vary(wood, 0.03), Material = Enum.Material.Wood, CastShadow = true })
			for _, yy in ipairs({ fenceH * 0.38, fenceH * 0.78 }) do
				local railLen = 20.4
				local tilt = math.rad(rng:NextNumber(-1.5, 1.5))
				local cf = CFrame.lookAt(mid, mid + along) * CFrame.Angles(tilt, 0, 0) + Vector3.new(0, yy, 0)
				deco(m, { Name = "Rail", Size = Vector3.new(0.45, 0.55, railLen), CFrame = cf, Color = vary(wood, 0.03), Material = Enum.Material.Wood })
			end
		end
		-- hedge bushes on the inside edge, more where the fence is broken
		if rng:NextNumber() < (fenceOn and 0.35 or 0.8) then
			local b = mid - out * rng:NextNumber(1, 3.5) + along * rng:NextNumber(-6, 6)
			if not isNearKeepout(arena, b, 1) then
				prop(m, "Bush", CFrame.new(b) * randomYaw(), rng:NextNumber(0.9, 1.4), pick({ { Leaf = rgb(79, 174, 74) }, { Leaf = rgb(66, 150, 70) } }))
			end
		end
	end)
	-- tree line outside the fence; lower and sparser on the south (camera) side
	alongSides(arena, 18, -h - 24, h + 24, function(pos, out, along, side, _t)
		local south = side == 2
		for row = 1, (south or rng:NextNumber() < 0.4) and 1 or 2 do
			local depth = south and rng:NextNumber(18, 40) or (row == 1 and rng:NextNumber(7, 20) or rng:NextNumber(24, 44))
			local p = pos + out * depth + along * rng:NextNumber(-7, 7)
			if not isNearKeepout(arena, p, 3) then
				local isPine = rng:NextNumber() < (south and 0.6 or 0.4)
				local s = south and rng:NextNumber(0.6, 0.85) or rng:NextNumber(1, 1.55)
				prop(m, isPine and "Tree_Pine" or "Tree_Round", CFrame.new(p + Vector3.new(0, -0.05, 0)) * randomYaw(), s, isPine and pick(PINE_LEAVES) or pick(ROUND_LEAVES), not south)
			end
		end
		if south and rng:NextNumber() < 0.5 then
			prop(m, "Bush", CFrame.new(pos + out * rng:NextNumber(5, 12)) * randomYaw(), rng:NextNumber(1, 1.5))
		end
	end)
end

------------------------------------------------------------------------------------------
-- RUINS: an overgrown castle courtyard at dusk. A mosaic plaza (spawn) opens onto four
-- flagstone avenues lined with colonnades (standing, broken and toppled pillars); ruined
-- buildings fill the quadrants; alien crystals erupt from corrupted ground; torches burn
-- at the plaza; a broken crenellated wall with corner towers rings it all.
------------------------------------------------------------------------------------------

local RUIN_STONE = { rgb(168, 162, 150), rgb(156, 150, 140), rgb(178, 170, 154), rgb(146, 142, 134) }
local SANDSTONE = { rgb(196, 176, 136), rgb(186, 166, 128), rgb(204, 186, 146) }

local AXES = { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }

-- Broken wall line between two points on one axis: stepped chunks, one box collider.
local function ruinWall(arena, a: Vector3, b: Vector3, maxH: number)
	local m = arena.Model
	local dir = (b - a)
	local len = dir.Magnitude
	if len < 1 then
		return
	end
	dir = dir.Unit
	local thick = 2.6
	local chunks = math.max(1, math.floor(len / 7))
	local cl = len / chunks
	for k = 1, chunks do
		local hgt = rng:NextNumber(maxH * 0.4, maxH)
		local mid = a + dir * (cl * (k - 0.5))
		local cf = CFrame.lookAt(mid, mid + dir) + Vector3.new(0, hgt / 2, 0) -- mid is on the floor
		deco(m, { Name = "RuinWall", Size = Vector3.new(thick, hgt, cl + 0.05), CFrame = cf, Color = vary(pick(RUIN_STONE), 0.02), Material = Enum.Material.Cobblestone, CastShadow = true })
		if rng:NextNumber() < 0.45 then
			-- a jagged top block
			local th = rng:NextNumber(1, 2.2)
			deco(m, { Name = "RuinTop", Size = Vector3.new(thick * 0.9, th, cl * rng:NextNumber(0.3, 0.6)), CFrame = cf * CFrame.new(0, hgt / 2 + th / 2, rng:NextNumber(-cl * 0.2, cl * 0.2)), Color = vary(pick(RUIN_STONE), 0.02), Material = Enum.Material.Cobblestone, CastShadow = true })
		end
		if rng:NextNumber() < 0.3 then
			deco(m, { Name = "Ivy", Size = Vector3.new(thick + 0.25, hgt * rng:NextNumber(0.4, 0.8), cl * rng:NextNumber(0.3, 0.6)), CFrame = cf * CFrame.new(0, -hgt * 0.15, 0), Color = vary(rgb(84, 128, 62), 0.03), Material = Enum.Material.Grass })
		end
	end
	local mid = (a + b) / 2
	local alongX = math.abs(dir.X) > 0.5
	boxCollider(arena, mid.X, mid.Z, alongX and len or thick, alongX and thick or len, maxH)
end

local function ruinedBuilding(arena, bx: number, bz: number)
	local y = arena.Center.Y
	local sx = rng:NextNumber() < 0.5 and 1 or -1
	local sz = rng:NextNumber() < 0.5 and 1 or -1
	local w, d = rng:NextNumber(22, 28), rng:NextNumber(17, 22)
	local function P(px: number, pz: number): Vector3
		return Vector3.new(bx + px * sx, y, bz + pz * sz)
	end
	-- old tiled floor inside
	deco(arena.Model, { Name = "OldFloor", Size = Vector3.new(w - 1, 0.12, d - 1), CFrame = CFrame.new(bx, y + 0.05, bz), Color = rgb(128, 122, 112), Material = Enum.Material.Slate })
	-- back wall with a doorway gap, side wall, short broken front fragment
	local gap = rng:NextNumber(-w / 2 + 6, w / 2 - 8)
	ruinWall(arena, P(-w / 2, -d / 2), P(gap, -d / 2), 10)
	ruinWall(arena, P(gap + 5, -d / 2), P(w / 2, -d / 2), 9)
	ruinWall(arena, P(-w / 2, -d / 2 + 2.6), P(-w / 2, d / 2 - rng:NextNumber(2, 6)), 8)
	ruinWall(arena, P(-w / 2 + 2.6, d / 2), P(-w / 2 + rng:NextNumber(7, 11), d / 2), 5)
	-- rubble and a shady mushroom corner
	for _ = 1, 3 do
		local p = P(rng:NextNumber(-w / 2, w / 2), -d / 2 + rng:NextNumber(2.5, 4.5))
		prop(arena.Model, "Rock", CFrame.new(p) * randomYaw(), rng:NextNumber(0.35, 0.6), { Stone = pick(RUIN_STONE), Moss = rgb(92, 140, 70) })
	end
	local corner = P(-w / 2 + 3.5, -d / 2 + 3.5)
	for k = 1, 3 do
		mushroom(arena, corner.X + k * 1.4 * sx, corner.Z + (k % 2) * 1.3 * sz, rng:NextNumber(0.35, 0.55), { Accent = rgb(196, 120, 64) })
	end
	keepout(arena, bx, bz, math.max(w, d) / 2 + 3)
end

local function crystalField(arena, x: number, z: number)
	local y = arena.Center.Y
	local m = arena.Model
	local r = rng:NextNumber(8, 11)
	disc(m, "Corruption", Vector3.new(x, y + 0.08, z), r, rgb(48, 30, 66), Enum.Material.Slate)
	for k = 1, 4 do
		local a = k / 4 * TAU + rng:NextNumber(-0.4, 0.4)
		local len = rng:NextNumber(r * 0.7, r * 1.25)
		local mid = Vector3.new(x + math.cos(a) * len / 2, y + 0.11, z + math.sin(a) * len / 2)
		deco(m, { Name = "Crack", Size = Vector3.new(0.4, 0.05, len), CFrame = CFrame.lookAt(mid, Vector3.new(x, mid.Y, z)), Color = rgb(186, 100, 255), Material = Enum.Material.Neon })
	end
	-- one big collidable cluster in the middle, smaller ones around it
	local glow = { Glow = pick({ rgb(176, 91, 255), rgb(140, 90, 255), rgb(210, 100, 255) }) }
	prop(m, "CrystalCluster", CFrame.new(x, y, z) * randomYaw(), rng:NextNumber(1.6, 2), glow, true)
	circleCollider(arena, x, z, 3, 5)
	for k = 1, rng:NextInteger(3, 4) do
		local a = k / 4 * TAU + rng:NextNumber(-0.5, 0.5)
		local d = rng:NextNumber(3.8, r - 1.5)
		prop(m, "CrystalCluster", CFrame.new(x + math.cos(a) * d, y, z + math.sin(a) * d) * randomYaw(), rng:NextNumber(0.6, 1.1), glow, false)
	end
	local holder = deco(m, { Name = "CrystalGlow", Size = Vector3.new(0.2, 0.2, 0.2), CFrame = CFrame.new(x, y + 4, z), Transparency = 1 })
	local light = Instance.new("PointLight")
	light.Color = rgb(190, 110, 255)
	light.Range = 22
	light.Brightness = 1.6
	light.Shadows = false
	light.Parent = holder
	keepout(arena, x, z, r + 1)
end

local function buildRuins(arena)
	local c, h = arena.Center, arena.Half
	local m = arena.Model
	local y = c.Y

	-- ground: earth outside, overgrown courtyard earth inside
	deco(m, { Name = "OuterGround", Size = Vector3.new(h * 2 + 360, 2, h * 2 + 360), CFrame = CFrame.new(c - Vector3.new(0, 1.06, 0)), Color = rgb(96, 104, 70), Material = Enum.Material.Grass, CanCollide = true, CanQuery = true })
	deco(m, { Name = "Floor", Size = Vector3.new(h * 2 + 4, 1, h * 2 + 4), CFrame = CFrame.new(c - Vector3.new(0, 0.5, 0)), Color = rgb(128, 120, 98), Material = Enum.Material.Ground, CanCollide = true, CanQuery = true })
	for _ = 1, 30 do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(30, h * 1.15)
		local px, pz = c.X + math.clamp(math.cos(a) * r, -h + 8, h - 8), c.Z + math.clamp(math.sin(a) * r, -h + 8, h - 8)
		local tone = pick({ rgb(104, 140, 76), rgb(92, 128, 68), rgb(118, 146, 80), rgb(140, 128, 100) })
		disc(m, "Overgrowth", Vector3.new(px, y + 0.02 + rng:NextNumber(0, 0.03), pz), rng:NextNumber(7, 20), tone, tone.G > 0.52 and Enum.Material.Grass or Enum.Material.Ground)
	end

	-- plaza: border ring, cobbles, sandstone compass star, red-brown centre
	disc(m, "PlazaRing", Vector3.new(c.X, y + 0.12, c.Z), 31.5, rgb(104, 100, 96), Enum.Material.Slate, 0.2)
	disc(m, "Plaza", Vector3.new(c.X, y + 0.16, c.Z), 30, rgb(166, 160, 148), Enum.Material.Cobblestone, 0.2)
	for k = 0, 3 do
		deco(m, { Name = "StarRay", Size = Vector3.new(2.2, 0.06, k % 2 == 0 and 50 or 36), CFrame = CFrame.new(c.X, y + 0.18, c.Z) * CFrame.Angles(0, k * math.pi / 4, 0), Color = SANDSTONE[1], Material = Enum.Material.Slate })
	end
	disc(m, "StarCore", Vector3.new(c.X, y + 0.2, c.Z), 6.5, rgb(140, 70, 56), Enum.Material.Slate)
	disc(m, "StarHeart", Vector3.new(c.X, y + 0.22, c.Z), 2.6, SANDSTONE[3], Enum.Material.Slate)

	-- avenues: rows of slabs (a few missing or heaved) out to the wall
	for _, axis in ipairs(AXES) do
		local side = Vector3.new(axis.Z, 0, axis.X)
		local d = 31
		while d < h - 8 do
			if rng:NextNumber() > 0.08 then
				local pos = c + axis * (d + 6) + Vector3.new(0, 0.07, 0)
				deco(m, { Name = "AvenueSlab", Size = Vector3.new(22, 0.16, 11.6), CFrame = CFrame.lookAt(pos, pos + axis) * CFrame.Angles(0, math.rad(rng:NextNumber(-1.2, 1.2)), 0), Color = vary(pick(RUIN_STONE), 0.02), Material = Enum.Material.Slate })
			end
			keepout(arena, (c + axis * (d + 6)).X, (c + axis * (d + 6)).Z, 12)
			d += 12
		end
		-- curb stones along both edges
		for _, s in ipairs({ -1, 1 }) do
			local mid = c + axis * ((34 + h) / 2) + side * s * 11.5 + Vector3.new(0, 0.2, 0)
			deco(m, { Name = "Curb", Size = Vector3.new(1, 0.4, h - 34), CFrame = CFrame.lookAt(mid, mid + axis), Color = rgb(120, 116, 108), Material = Enum.Material.Slate })
		end
	end

	-- colonnades: pillars along the avenues (standing, broken stump, toppled or missing)
	local toppled = 0
	for _, axis in ipairs(AXES) do
		local side = Vector3.new(axis.Z, 0, axis.X)
		for _, s in ipairs({ -1, 1 }) do
			for d = 52, h - 20, 25 do
				local p = c + axis * d + side * s * 15.5
				local roll = rng:NextNumber()
				if roll < 0.55 then
					local sc = rng:NextNumber(1, 1.2)
					prop(m, "Pillar", CFrame.new(p.X, y, p.Z) * CFrame.Angles(0, rng:NextInteger(0, 3) * math.pi / 2, 0), sc, { Stone = vary(RUIN_STONE[1], 0.02) }, true)
					circleCollider(arena, p.X, p.Z, 1.6 * sc, 9 * sc)
				elseif roll < 0.8 then
					local sh = rng:NextNumber(1.5, 3.5)
					deco(m, { Name = "PillarBase", Size = Vector3.new(3.2, 0.8, 3.2), CFrame = CFrame.new(p.X, y + 0.4, p.Z), Color = RUIN_STONE[2], Material = Enum.Material.Slate })
					column(m, "Stump", Vector3.new(p.X, y + 0.8, p.Z), 1.15, sh, RUIN_STONE[1], Enum.Material.Slate, { CastShadow = true })
					circleCollider(arena, p.X, p.Z, 1.7, sh + 0.8)
				elseif toppled < 5 then
					-- fallen drum pointing away from the avenue
					toppled += 1
					local len = rng:NextNumber(7, 9)
					local centre = p + side * s * (len / 2 - 1)
					deco(m, { Name = "FallenPillar", Shape = Enum.PartType.Cylinder, Size = Vector3.new(len, 2.3, 2.3), CFrame = CFrame.lookAt(Vector3.new(centre.X, y + 1.05, centre.Z), Vector3.new(centre.X, y + 1.05, centre.Z) + side) * CFrame.Angles(0, math.pi / 2, 0), Color = RUIN_STONE[1], Material = Enum.Material.Slate, CastShadow = true })
					local alongX = math.abs(side.X) > 0.5
					boxCollider(arena, centre.X, centre.Z, alongX and len or 2.5, alongX and 2.5 or len, 2.3)
				end
			end
		end
	end

	-- torches at the plaza mouths
	for _, axis in ipairs(AXES) do
		local side = Vector3.new(axis.Z, 0, axis.X)
		for _, s in ipairs({ -1, 1 }) do
			local p = c + axis * 40 + side * s * 13
			prop(m, "Torch", CFrame.new(p.X, y, p.Z) * randomYaw(), 1.25)
			fireLight(m, Vector3.new(p.X, y + 6.4, p.Z), 20, 1.5, nil, true)
			circleCollider(arena, p.X, p.Z, 0.6, 6)
		end
	end

	boundaryWalls(arena)

	-- ruined buildings, one per quadrant
	for _, q in ipairs({ { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }) do
		ruinedBuilding(arena, c.X + q[1] * rng:NextNumber(85, 120), c.Z + q[2] * rng:NextNumber(85, 120))
	end

	-- alien crystal fields
	for _ = 1, 5 do
		local x, z = findSpot(arena, 60, h * 1.2, 14)
		if x and z then
			crystalField(arena, x, z)
		end
	end

	-- autumn trees growing out of the ruins
	local autumn: { Palette } = { { Leaf = rgb(214, 150, 60), Leaf2 = rgb(180, 96, 50) }, { Leaf = rgb(196, 170, 70), Leaf2 = rgb(160, 120, 52) } }
	for _ = 1, 5 do
		local x, z = findSpot(arena, 60, h * 1.25, 8)
		if x and z then
			tree(arena, x, z, rng:NextNumber(1, 1.3), "Tree_Round", pick(autumn))
			cluster(arena, x, z, 6, 2, 1.5, function(px, pz)
				bush(arena, px, pz, rng:NextNumber(0.7, 1), { Leaf = rgb(110, 140, 60), Accent = rgb(220, 120, 60) })
			end)
		end
	end

	-- rubble piles and lone boulders
	local rockCap = Config.Arenas.RockCount or 26
	for _ = 1, 10 do
		local x, z = findSpot(arena, 45, h * 1.25, 6)
		if x and z and arena.Rocks < rockCap then
			rock(arena, x, z, rng:NextNumber(0.9, 1.3), { Stone = pick(RUIN_STONE), Moss = rgb(96, 140, 70) })
			cluster(arena, x, z, 5, 2, 2, function(px, pz)
				rock(arena, px, pz, rng:NextNumber(0.35, 0.6), { Stone = pick(RUIN_STONE) })
			end)
		end
	end

	-- BORDER: broken crenellated wall (low on the south / camera side), rubble in the
	-- breaches, ruined corner towers, dark pines beyond.
	alongSides(arena, 20, -h, h - 20, function(pos, out, along, side, _t)
		local south = side == 2
		local mid = pos + along * 10 + out * 1.6
		if rng:NextNumber() < 0.12 then
			-- breach: rubble mound (the invisible boundary still blocks)
			for k = 1, 2 do
				prop(m, "Rock", CFrame.new(mid + along * (k * 6 - 9)) * randomYaw(), rng:NextNumber(1, 1.4), { Stone = pick(RUIN_STONE) }, true)
			end
			return
		end
		local hgt = south and rng:NextNumber(3, 4.5) or rng:NextNumber(6, 11)
		local cf = CFrame.lookAt(mid, mid + along) + Vector3.new(0, hgt / 2, 0) -- mid is on the floor
		deco(m, { Name = "OuterWall", Size = Vector3.new(3.2, hgt, 20.05), CFrame = cf, Color = vary(pick(RUIN_STONE), 0.02), Material = Enum.Material.Cobblestone, CastShadow = not south })
		if not south and rng:NextNumber() < 0.5 then
			for _, k in ipairs({ -5, 5 }) do
				deco(m, { Name = "Merlon", Size = Vector3.new(3.2, 2, 3), CFrame = cf * CFrame.new(0, hgt / 2 + 1, k), Color = RUIN_STONE[3], Material = Enum.Material.Cobblestone, CastShadow = true })
			end
		elseif rng:NextNumber() < 0.4 then
			local th = rng:NextNumber(1.2, 2.5)
			deco(m, { Name = "RuinTop", Size = Vector3.new(3, th, rng:NextNumber(5, 9)), CFrame = cf * CFrame.new(0, hgt / 2 + th / 2, rng:NextNumber(-5, 5)), Color = vary(pick(RUIN_STONE), 0.02), Material = Enum.Material.Cobblestone })
		end
		if rng:NextNumber() < 0.3 then
			deco(m, { Name = "Ivy", Size = Vector3.new(3.45, hgt * rng:NextNumber(0.4, 0.85), rng:NextNumber(4, 9)), CFrame = cf * CFrame.new(0, -hgt * 0.1, rng:NextNumber(-5, 5)), Color = vary(rgb(84, 128, 62), 0.03), Material = Enum.Material.Grass })
		end
	end)
	for _, q in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local south = q[2] == 1
		local base = Vector3.new(c.X + q[1] * (h + 2), y, c.Z + q[2] * (h + 2))
		local hgt = south and 7 or 16
		column(m, "CornerTower", base, 8, hgt, RUIN_STONE[2], Enum.Material.Cobblestone, { CastShadow = not south })
		column(m, "TowerRing", base + Vector3.new(0, hgt, 0), 8.6, 1.2, RUIN_STONE[3], Enum.Material.Cobblestone)
		circleCollider(arena, base.X, base.Z, 8, hgt) -- the tower pokes into the corner
		if not south then
			towerMerlons(m, base, 8.1, hgt + 1.2, 7, RUIN_STONE[3])
		end
	end
	local darkPines: { Palette } = { { Leaf = rgb(46, 92, 64) }, { Leaf = rgb(38, 80, 60) }, { Leaf = rgb(56, 100, 66) } }
	alongSides(arena, 16, -h - 20, h + 20, function(pos, out, along, side, _t)
		if side == 2 then
			return -- keep the camera side open
		end
		local p = pos + out * rng:NextNumber(12, 42) + along * rng:NextNumber(-5, 5)
		if rng:NextNumber() < 0.75 then
			prop(m, "Tree_Pine", CFrame.new(p) * randomYaw(), rng:NextNumber(1.1, 1.7), pick(darkPines), true)
		end
	end)
end

-- Builds an arena by name, destroying the previous one.
function MapBuilder.BuildArena(name: string)
	MapBuilder.DestroyArena()
	local arena = newArena(name)
	if name == "Ruins" then
		buildRuins(arena)
	else
		buildForest(arena)
	end
	arena.Model.Parent = arena.Root
	MapBuilder.ApplyLighting(name)
	currentArena = arena
	return arena
end

function MapBuilder.DestroyArena()
	if currentArena then
		currentArena.Model:Destroy()
		currentArena = nil
	end
end

function MapBuilder.GetArena()
	return currentArena
end

return MapBuilder
