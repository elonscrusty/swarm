--[[
	MapBuilder.lua
	Builds the castle lobby (the menu backdrop) and the six arenas (Forest, Ruins, Swamp,
	Snow, Desert, Lava) from the Blender world / castle / biome kits (MeshService +
	MeshCatalog) with part-built fallbacks (biome kit pieces fall back to one block per
	catalog piece), so the maps read the same before and after the meshes are uploaded.

	BuildLobby()        → lobby table (menu camera, spawn, legacy prompts), built once at boot
	BuildArena(name, variant?) → arena table, replaces any previous arena (variant > 0
	                      re-seeds the small decoration for later stages; the designed
	                      layout stays the same, variant 0 = the classic map)
	FindPortalSpot(arena, rng, avoid?) → a clear spot for the stage portal (Config.Stages)
	FindOpenSpot(arena, rng, opts) → a clear floor spot for loot (chests, shrines, the
	                      guarded altar: LootSystem), spaced from other spots
	PlaceProp(parent, name, cf, scale?, palette?, opts?) → a kit prop (mesh or fallback,
	                      swapped for the mesh when it loads); opts.fallback builds models
	                      that have no fallback here
	AddCollider(arena, nameOrShape, cf, scale?) → an obstacle collider (before EnemyAI.SetArena)
	BuildPortal(arena, pos) → the stage portal (kit mesh "Portal" or a part fallback, its
	                      collider, rune circle, light beam) with :SetState(state, charge)
	DestroyArena()
	ApplyLighting(name) → "Lobby" | an arena name (sun, sky, atmosphere, clouds, grade)

	Biome arenas also list their floor HAZARDS in arena.Hazards = { { Kind = "Mud" |
	"Quicksand" | "Ice" | "Lava", Pos, Radius } } (BiomeHazards applies them); FindPortalSpot
	and FindOpenSpot keep Config.Arenas.Hazards.LootPad studs from every pool's edge, and
	arena.PortalPalette tints the portal's moss slot for the biome.

	Layouts are DESIGNED, not scattered: every landmark, grove, path and outcrop has a fixed
	place, and small decoration uses a fixed seed per map, so every server builds the same
	map. The run camera looks down from the south (Config.Camera), so:
	  * nothing collidable stands within Config.Arenas.ClearRadius of the centre (spawn);
	  * tall things stand in groves, around landmarks and in the tree line outside the
	    boundary; the south (camera) side is kept low; trees, arches, walls and other tall
	    pieces are tagged "SwarmOccluder" so the client fades them (src/client/Occlusion.lua)
	    when they cover the player;
	  * decoration never collides (CanCollide / CanQuery / CanTouch off, not in the obstacle
	    folder); only deliberate obstacles (trunks, boulders, ruin walls, arch piers,
	    standing stones, crates ...) get ONE simple collider each, taken from the catalog
	    Collider extra so it lines up with the mesh.

	Every collider is recorded in arena.Obstacles for EnemyAI (cheap push-out) and is a part
	in arena.ObstacleFolder (the only thing enemy raycasts hit):
	  { Kind = "Circle", Pos = Vector3, Radius = r }
	  { Kind = "Box", Pos = centre, Radius = halfDiagonal, MinX, MaxX, MinZ, MaxZ }

	Navigation budget (measured with `bash tools/preview/render.sh arena-map --print-metrics`):
	blocked area and the blocked area per ring (40-100, 100-200, corners) stay within about
	15% of the previous random builder (Forest ~1130 studs², Ruins ~1300 studs²; the biome
	arenas are tuned to Forest: Swamp ~1140, Snow ~1040, Desert ~1130, Lava ~1140).
	Phone budget per arena: everything anchored, about <= 650 MeshParts + 450 Parts, <= 12
	lights, shadows only on big pieces (grass, flowers, ferns and clutter cast none).

	Fine ground detail (small tufts, flowers, clover discs, pebbles) is NOT built here: each
	client draws it around its own camera from a recycled pool (src/client/GroundDetail.lua,
	Config.Graphics.GroundDetail). BuildArena only writes the floor layout it needs as
	attributes on the arena model (DetailPaths, DetailBare: paths, landmark keepouts,
	arena.Bare circles such as the Ruins plaza, hazard pools); colliders come from the
	Obstacles folder.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Palette = require(Shared.Palette)
local MeshCatalog = require(Shared.MeshCatalog)
local ModelBuilder = require(script.Parent.ModelBuilder)
local MeshService = require(script.Parent.MeshService)

local part = ModelBuilder.Part

local MapBuilder = {}

local P = Palette :: { [string]: Color3 }
local OCCLUDER_TAG = ((Config.Graphics :: any).Occlusion or {}).Tag or "SwarmOccluder"

local mapFolder: Folder? = nil
local currentArena: { [string]: any }? = nil
local rng = Random.new(1)

local TAU = math.pi * 2
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- turns a Cylinder's axis (X) upward
local SMOOTH = Enum.Material.SmoothPlastic

local SEEDS = { Lobby = 20250, Forest = 41207, Ruins = 93011, Swamp = 52361, Snow = 63127, Desert = 74471, Lava = 85219 }

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function mix(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, t)
end

local function ensureMapFolder(): Folder
	if not mapFolder then
		local f = Instance.new("Folder")
		f.Name = "SwarmMap"
		f.Parent = workspace
		mapFolder = f
	end
	return mapFolder :: Folder
end

local function pick<T>(list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

local function jitter(amount: number): number
	return rng:NextNumber(-amount, amount)
end

local function yawCF(deg: number): CFrame
	return CFrame.Angles(0, math.rad(deg), 0)
end

local function randomYaw(): CFrame
	return CFrame.Angles(0, rng:NextNumber(0, TAU), 0)
end

local function tag(inst: Instance)
	CollectionService:AddTag(inst, OCCLUDER_TAG)
end

------------------------------------------------------------------------------------------
-- BUILDING BLOCKS (decoration by default: no collision, no queries, no shadow)
------------------------------------------------------------------------------------------

local function deco(parent: Instance, props: { [string]: any }): BasePart
	if props.Material == nil then
		props.Material = SMOOTH
	end
	local p = part(props)
	p.Parent = parent
	return p
end

-- Flat disc whose TOP surface is at `top` (ground patches, water, inlays).
local function disc(parent: Instance, name: string, top: Vector3, radius: number, color: Color3, thick: number?): BasePart
	local t = thick or 0.1
	return deco(parent, {
		Name = name,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(t, radius * 2, radius * 2),
		CFrame = CFrame.new(top - Vector3.new(0, t / 2, 0)) * UPRIGHT,
		Color = color,
	})
end

-- Flat slab whose TOP surface is at top.Y (paths, paving).
local function slab(parent: Instance, name: string, top: Vector3, sx: number, sz: number, yaw: number, color: Color3, thick: number?): BasePart
	local t = thick or 0.1
	return deco(parent, {
		Name = name,
		Size = Vector3.new(sx, t, sz),
		CFrame = CFrame.new(top - Vector3.new(0, t / 2, 0)) * CFrame.Angles(0, yaw, 0),
		Color = color,
	})
end

------------------------------------------------------------------------------------------
-- Fire lights: one flicker loop for every torch / brazier light in the world.
------------------------------------------------------------------------------------------

local flickers: { { Light: Light, Base: number, Phase: number } } = {}
local flickerRunning = false

local function addFlicker(light: Light)
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
					f.Light.Brightness = f.Base * (0.86 + 0.09 * math.sin(t * 7.3 + f.Phase) + 0.05 * math.sin(t * 17.9 + f.Phase * 2))
				end
			end
			task.wait(0.1)
		end
	end)
end

local FIRE = rgb(255, 168, 92)
-- arena torches / braziers: a warmer, stronger flame and light so they read as glowing
-- pools of firelight in the bright daylight (the lobby keeps FIRE)
local TORCH_FIRE = rgb(255, 150, 58)
local TORCH_FLAME: { [string]: Color3 } = { Flame = rgb(255, 132, 36), Core = rgb(255, 214, 120) }

-- Invisible holder with a PointLight (fire lights flicker).
local function pointLight(parent: Instance, pos: Vector3, range: number, brightness: number, color: Color3, flicker: boolean): PointLight
	local holder = deco(parent, { Name = "Light", Size = Vector3.new(0.2, 0.2, 0.2), CFrame = CFrame.new(pos), Transparency = 1 })
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = brightness
	light.Shadows = false
	light.Parent = holder
	if flicker then
		addFlicker(light)
	end
	return light
end

------------------------------------------------------------------------------------------
-- KIT PROPS: the Blender mesh when loaded (MeshService), a part-built fallback otherwise.
-- `cf` is the prop's origin (ground centre for standing pieces; see the catalog Anchor
-- note for wall banners / sconces). The prop is always a Model container named after
-- the kit piece, so tags survive the fallback → mesh swap when meshes finish loading.
------------------------------------------------------------------------------------------

type Pal = { [string]: Color3 }
type PropOpts = {
	shadow: boolean?, -- false: no shadows at all; nil: big pieces cast (catalog Shadow)
	occluder: boolean?, -- tag "SwarmOccluder"
	query: boolean?, -- CanQuery on (the dais: the showcase finds its top by raycast)
	fallback: ((Model, CFrame, number, { [string]: Color3 }, boolean) -> ())?, -- builder for models without a FALLBACK entry
}

local function kitEntry(name: string): any
	return (MeshCatalog.Models :: any)[name]
end

-- Catalog preview colours with the caller's overrides on top.
local function kitPalette(name: string, palette: Pal?): Pal
	local out: Pal = {}
	local entry = kitEntry(name)
	if entry and entry.Palette then
		for k, v in pairs(entry.Palette) do
			out[k] = v
		end
	end
	if palette then
		for k, v in pairs(palette) do
			out[k] = v
		end
	end
	return out
end

-- Fallback builders: (model, cf, scale, palette, shadow) in the catalog's slots/colours.
local FALLBACK: { [string]: (Model, CFrame, number, Pal, boolean) -> () } = {}

local function c3(pal: Pal, slot: string, default: Color3): Color3
	return pal[slot] or default
end

-- Part at cf * (at scaled by s), size scaled by s.
local function fpart(m: Model, cf: CFrame, s: number, name: string, size: Vector3, at: CFrame, color: Color3, shadow: boolean?, shape: Enum.PartType?, material: Enum.Material?): BasePart
	return deco(m, {
		Name = name,
		Shape = shape,
		Size = size * s,
		CFrame = cf * CFrame.new(at.Position * s) * at.Rotation,
		Color = color,
		Material = material or SMOOTH,
		CastShadow = shadow == true,
	})
end

-- Upright cylinder (radius r, height h) standing at y (all before scaling).
local function fcyl(m: Model, cf: CFrame, s: number, name: string, r: number, h: number, x: number, y: number, z: number, color: Color3, shadow: boolean?, material: Enum.Material?): BasePart
	return fpart(m, cf, s, name, Vector3.new(h, r * 2, r * 2), CFrame.new(x, y + h / 2, z) * UPRIGHT, color, shadow, Enum.PartType.Cylinder, material)
end

local function fball(m: Model, cf: CFrame, s: number, name: string, size: Vector3, x: number, y: number, z: number, color: Color3, shadow: boolean?): BasePart
	return fpart(m, cf, s, name, size, CFrame.new(x, y, z), color, shadow, Enum.PartType.Ball)
end

local function fblock(m: Model, cf: CFrame, s: number, name: string, size: Vector3, x: number, y: number, z: number, color: Color3, shadow: boolean?, rot: CFrame?)
	fpart(m, cf, s, name, size, CFrame.new(x, y, z) * (rot or CFrame.identity), color, shadow)
end

local NEON = Enum.Material.Neon

FALLBACK.Tree_Round = function(m, cf, s, pal, sh)
	fcyl(m, cf, s, "Trunk", 0.75, 6.5, 0, 0, 0, c3(pal, "Bark", P.wood_600), sh)
	fball(m, cf, s, "Leaves", Vector3.new(10, 7.5, 9.5), 0, 8.4, 0, c3(pal, "Leaves", P.moss_700), sh)
	fball(m, cf, s, "Leaves2", Vector3.new(6.5, 5, 6.5), 1.2, 11, -0.6, c3(pal, "Leaves2", P.moss_600), false)
end
local function pineFallback(height: number)
	return function(m: Model, cf: CFrame, s: number, pal: Pal, sh: boolean)
		local k = height / 16
		fcyl(m, cf, s, "Trunk", 0.6, 3 * k, 0, 0, 0, c3(pal, "Bark", P.wood_700), sh)
		for i, r in ipairs({ 4.4, 3.4, 2.3, 1.2 }) do
			local slot = i % 2 == 1 and "Needles" or "Needles2"
			fcyl(m, cf, s, "Needles", r, 3.4 * k, 0, (1.6 + (i - 1) * 3.3) * k, 0, c3(pal, slot, P.moss_800), sh and i <= 2)
		end
	end
end
FALLBACK.Tree_Pine = pineFallback(16)
FALLBACK.Tree_PineTall = pineFallback(22)
FALLBACK.Bush = function(m, cf, s, pal)
	fball(m, cf, s, "Leaves", Vector3.new(3.4, 1.9, 2.2), 0, 0.85, 0, c3(pal, "Leaves", P.moss_700))
	fball(m, cf, s, "Leaves2", Vector3.new(2, 1.4, 1.6), 0.5, 1.2, -0.2, c3(pal, "Leaves2", P.moss_500))
end
FALLBACK.Fern = function(m, cf, s, pal)
	fball(m, cf, s, "Fronds", Vector3.new(2.4, 0.8, 2.4), 0, 0.35, 0, c3(pal, "Fern", P.moss_500))
end
-- A fixed three-blade patch keeps grass light and upright at every mesh quality.
-- Use native parts instead of the broad triangular faces in the uploaded tuft.
FALLBACK.GrassTuft = function(m, cf, s, pal)
	local color = c3(pal, "Grass", P.meadow_600)
	for i = 1, 3 do
		local height = 0.65 + (i % 3) * 0.18
		local angle = i * 2.4
		local blade = CFrame.new(math.cos(angle) * 0.16, 0.04, math.sin(angle) * 0.16)
			* CFrame.Angles(0, angle, (i - 2) * 0.22) * CFrame.new(0, height / 2, 0)
		fpart(m, cf, s, "GrassBlade", Vector3.new(0.10, height, 0.08), blade,
			color:Lerp(P.meadow_700, (i - 1) * 0.10), false)
	end
end
FALLBACK.Flowers = function(m, cf, s, pal)
	fball(m, cf, s, "Blooms", Vector3.new(1.2, 0.35, 1.0), 0, 0.25, 0, c3(pal, "Bloom", P.ivory_100))
end
FALLBACK.Mushroom = function(m, cf, s, pal)
	fcyl(m, cf, s, "Stems", 0.18, 0.7, 0, 0, 0, c3(pal, "Stem", P.ivory_200))
	fball(m, cf, s, "Caps", Vector3.new(0.9, 0.45, 0.9), 0, 0.75, 0, c3(pal, "Cap", P.crimson_600))
end
local ROCK_ROT = CFrame.Angles(0.2, 0.5, 0.15)
FALLBACK.Rock = function(m, cf, s, pal, sh)
	fblock(m, cf, s, "Rock", Vector3.new(3.8, 2.3, 2.6), 0, 1.0, 0, c3(pal, "Stone", P.stone_500), sh, ROCK_ROT)
	fblock(m, cf, s, "Rock2", Vector3.new(2.2, 1.6, 2), 1.1, 0.7, 0.4, c3(pal, "Stone2", P.stone_600), false, CFrame.Angles(-0.1, 1.1, 0.2))
	fblock(m, cf, s, "Moss", Vector3.new(2.4, 0.3, 1.8), -0.3, 2.15, 0, c3(pal, "Moss", P.moss_400), false, CFrame.Angles(0.15, 0.5, 0.1))
end
FALLBACK.Rock_Small = function(m, cf, s, pal)
	fblock(m, cf, s, "Rock", Vector3.new(1.2, 0.7, 1), 0, 0.25, 0, c3(pal, "Stone", P.stone_400), false, ROCK_ROT)
end
FALLBACK.Rock_Slab = function(m, cf, s, pal)
	fblock(m, cf, s, "Slab", Vector3.new(3.6, 0.5, 2.7), 0, 0.3, 0, c3(pal, "Slab", P.stone_400))
end
local function wallFallback(len: number, h: number, thick: number)
	return function(m: Model, cf: CFrame, s: number, pal: Pal, sh: boolean)
		fblock(m, cf, s, "Stone", Vector3.new(len, h * 0.8, thick), 0, h * 0.4, 0, c3(pal, "Stone", P.stone_500), sh)
		fblock(m, cf, s, "Stone2", Vector3.new(len * 0.55, h * 0.2, thick * 0.95), -len * 0.18, h * 0.9, 0, c3(pal, "Stone2", P.stone_400), sh)
		fblock(m, cf, s, "Stone3", Vector3.new(len + 0.2, 0.4, thick + 0.25), 0, 0.2, 0, c3(pal, "Stone3", P.stone_600), false)
		fblock(m, cf, s, "Moss", Vector3.new(len * 0.4, 0.2, thick * 0.9), -len * 0.18, h + 0.05, 0, c3(pal, "Moss", P.moss_400), false)
	end
end
FALLBACK.Ruin_Wall = wallFallback(8, 3.5, 1.4)
FALLBACK.Ruin_WallLow = wallFallback(6, 1.6, 1.2)
FALLBACK.Pillar = function(m, cf, s, pal, sh)
	fblock(m, cf, s, "Plinth", Vector3.new(2.3, 0.6, 2.3), 0, 0.3, 0, c3(pal, "Base", P.stone_600), sh)
	fcyl(m, cf, s, "Shaft", 0.8, 4.2, 0, 0.6, 0, c3(pal, "Shaft", P.stone_300), sh)
end
FALLBACK.Ruin_Arch = function(m, cf, s, pal, sh)
	local stone, stone2 = c3(pal, "Stone", P.stone_500), c3(pal, "Stone2", P.stone_400)
	fblock(m, cf, s, "Stone", Vector3.new(2.5, 7, 2), 3.95, 3.5, 0, stone, sh)
	fblock(m, cf, s, "Stone2", Vector3.new(2.5, 4, 2), -3.95, 2, 0, stone2, sh)
	fblock(m, cf, s, "Stone3", Vector3.new(4.5, 1.4, 1.9), 2.6, 7.6, 0, c3(pal, "Stone3", P.stone_600), sh, CFrame.Angles(0, 0, math.rad(-12)))
end
FALLBACK.Ruin_Block = function(m, cf, s, pal, sh)
	fblock(m, cf, s, "Block", Vector3.new(2.4, 1.5, 2), 0, 0.5, 0, c3(pal, "Stone", P.stone_500), sh, CFrame.Angles(0.1, 0.3, 0.18))
end
FALLBACK.Fence_Section = function(m, cf, s, pal)
	for _, x in ipairs({ -3.6, 3.6 }) do
		fblock(m, cf, s, "Posts", Vector3.new(0.45, 2.6, 0.45), x, 1.2, 0, c3(pal, "Post", P.wood_700))
	end
	for _, y in ipairs({ 1.0, 2.0 }) do
		fblock(m, cf, s, "Rails", Vector3.new(7.9, 0.28, 0.22), 0, y, 0, c3(pal, "Rail", P.wood_500))
	end
end
FALLBACK.Banner = function(m, cf, s, pal)
	fcyl(m, cf, s, "Pole", 0.16, 9.2, 0, 0, 0, c3(pal, "Wood", P.wood_600))
	fblock(m, cf, s, "Cloth", Vector3.new(2.6, 4.4, 0.1), 0, 6.3, -0.2, c3(pal, "Cloth", P.slate_600))
	fblock(m, cf, s, "Gold", Vector3.new(1.0, 0.7, 0.12), 0, 7, -0.27, c3(pal, "Gold", P.gold_500))
end
FALLBACK.Torch = function(m, cf, s, pal)
	fcyl(m, cf, s, "Post", 0.2, 4.4, 0, 0, 0, c3(pal, "Wood", P.wood_600))
	fcyl(m, cf, s, "Bowl", 0.55, 0.45, 0, 4.3, 0, c3(pal, "Iron", P.steel_700))
	fball(m, cf, s, "Flame", Vector3.new(0.6, 0.9, 0.6), 0, 5.1, 0, c3(pal, "Flame", P.fx_fire)).Material = NEON
end
FALLBACK.Lantern_Post = function(m, cf, s, pal)
	fblock(m, cf, s, "Post", Vector3.new(0.45, 6.6, 0.45), 0, 3.3, 0, c3(pal, "Wood", P.wood_600))
	fblock(m, cf, s, "Iron", Vector3.new(1.9, 0.22, 0.22), -0.85, 6.4, 0, c3(pal, "Iron", P.steel_800))
	fpart(m, cf, s, "Core", Vector3.new(0.5, 0.7, 0.5), CFrame.new(-1.55, 5.0, 0), c3(pal, "Core", P.amber_300), false, nil, NEON)
end
FALLBACK.Barrel = function(m, cf, s, pal, sh)
	fcyl(m, cf, s, "Staves", 0.78, 2, 0, 0, 0, c3(pal, "Wood", P.wood_500), sh)
	fcyl(m, cf, s, "Hoops", 0.82, 0.18, 0, 1.4, 0, c3(pal, "Iron", P.steel_700))
end
FALLBACK.Crate = function(m, cf, s, pal, sh)
	fblock(m, cf, s, "Body", Vector3.new(2, 2, 2), 0, 1, 0, c3(pal, "Wood", P.wood_500), sh)
	fblock(m, cf, s, "Frame", Vector3.new(2.06, 0.25, 2.06), 0, 1.85, 0, c3(pal, "Frame", P.wood_700))
end
FALLBACK.Log = function(m, cf, s, pal, sh)
	fpart(m, cf, s, "Bark", Vector3.new(7, 1.4, 1.4), CFrame.new(0, 0.7, 0), c3(pal, "Bark", P.wood_600), sh, Enum.PartType.Cylinder)
end
FALLBACK.Stump = function(m, cf, s, pal, sh)
	fcyl(m, cf, s, "Bark", 0.85, 1.1, 0, 0, 0, c3(pal, "Bark", P.wood_600), sh)
	fcyl(m, cf, s, "Top", 0.75, 0.06, 0, 1.1, 0, c3(pal, "Heart", P.dirt_300))
end
FALLBACK.CrystalCluster = function(m, cf, s, pal)
	fblock(m, cf, s, "Base", Vector3.new(2.2, 0.6, 2), 0, 0.2, 0, c3(pal, "Stone", P.stone_600), false, ROCK_ROT)
	fblock(m, cf, s, "Crystals", Vector3.new(0.7, 2.4, 0.7), 0, 1.3, 0, c3(pal, "Crystal", P.slate_400), false, CFrame.Angles(0, 0.6, 0.15))
	fblock(m, cf, s, "Crystals2", Vector3.new(0.5, 1.6, 0.5), 0.6, 0.9, 0.3, c3(pal, "Crystal2", P.slate_200), false, CFrame.Angles(0.3, 0.2, -0.35))
end
FALLBACK.Shrine = function(m, cf, s, pal, sh)
	fblock(m, cf, s, "Plinth", Vector3.new(3, 0.6, 2), 0, 0.3, 0, c3(pal, "Base", P.stone_600), sh)
	fblock(m, cf, s, "Stone", Vector3.new(2.1, 4.2, 1.2), 0, 2.7, 0, c3(pal, "Stone", P.stone_500), sh)
	fblock(m, cf, s, "Sigil", Vector3.new(0.8, 0.8, 0.08), 0, 3.2, -0.62, c3(pal, "Gold", P.gold_500))
end
-- Stage portal: dais, two plinths, a horseshoe ring of 13 stones and the membrane. Piece
-- names match the mesh ("Surface", "Glyphs") so BuildPortal can recolour either.
FALLBACK.Portal = function(m, cf, s, pal, sh)
	local base, stone, stone2 = c3(pal, "Base", P.stone_600), c3(pal, "Stone", P.stone_500), c3(pal, "Stone2", P.stone_400)
	fcyl(m, cf, s, "Dais", 5.2, 0.32, 0, 0, 0, base, sh)
	fcyl(m, cf, s, "Dais", 4.0, 0.5, 0, 0, 0, base, false)
	fcyl(m, cf, s, "Runes", 2.95, 0.04, 0, 0.5, 0, c3(pal, "Gold", P.gold_500))
	fcyl(m, cf, s, "Dais", 2.7, 0.06, 0, 0.5, 0, base, false)
	for _, x in ipairs({ -3.55, 3.55 }) do
		fblock(m, cf, s, "Stone2", Vector3.new(2.7, 0.5, 2.1), x, 0.75, 0, stone2, sh)
		fblock(m, cf, s, "Stone", Vector3.new(2.35, 2.15, 1.8), x, 2.05, 0, stone, sh)
		fblock(m, cf, s, "Stone2", Vector3.new(2.6, 0.4, 2.0), x, 3.15, 0, stone2, sh)
	end
	for k = 0, 12 do
		local a = math.rad(-30 + k * 20)
		local key = k == 6
		local rm = 4.15
		local x, y = math.cos(a) * rm, 6 + math.sin(a) * rm
		fblock(m, cf, s, k % 2 == 0 and "Stone" or "Stone2", Vector3.new(key and 1.6 or 1.2, 1.38, key and 1.72 or 1.56), x, y, 0, k % 2 == 0 and stone or stone2, sh, CFrame.Angles(0, 0, a))
		if k % 2 == 1 or key then
			for _, z in ipairs({ -0.82, 0.82 }) do
				fblock(m, cf, s, "Glyphs", Vector3.new(0.24, 0.24, 0.1), x + math.cos(a) * 0.42, y + math.sin(a) * 0.42, z, c3(pal, "Glyph", P.fx_arcane), false, CFrame.Angles(0, 0, math.rad(45)))
			end
		end
	end
	local surface = fpart(m, cf, s, "Surface", Vector3.new(0.14, 6.84, 6.84), CFrame.new(0, 6, 0) * CFrame.Angles(0, math.rad(90), 0), c3(pal, "Surface", P.slate_400), false, Enum.PartType.Cylinder)
	surface.Transparency = 0.3
	for _, d in ipairs(m:GetChildren()) do
		if d:IsA("BasePart") and d.Name == "Glyphs" then
			d.Material = NEON
		end
	end
end
FALLBACK.Castle_Wall = function(m, cf, s, pal, sh)
	fblock(m, cf, s, "Wall", Vector3.new(12, 8.8, 3), 0, 4.4, 0, c3(pal, "Stone", P.stone_500), sh)
	fblock(m, cf, s, "Base", Vector3.new(12, 0.8, 3.2), 0, 0.4, 0, c3(pal, "Base", P.stone_600), false)
	for _, x in ipairs({ -4.5, -1.5, 1.5, 4.5 }) do
		fblock(m, cf, s, "Trim", Vector3.new(1.8, 1.2, 3), x, 9.4, 0, c3(pal, "Trim", P.stone_400), sh)
	end
end
local function towerFallback(m: Model, cf: CFrame, s: number, pal: Pal, sh: boolean)
	fcyl(m, cf, s, "Wall", 4.0, 14, 0, 0, 0, c3(pal, "Stone", P.stone_500), sh)
	fcyl(m, cf, s, "Trim", 4.4, 1, 0, 14, 0, c3(pal, "Trim", P.stone_400), sh)
	for k = 0, 5 do
		local a = k / 6 * TAU
		fblock(m, cf, s, "Trim", Vector3.new(1.6, 1.2, 1.2), math.cos(a) * 3.9, 15.6, math.sin(a) * 3.9, c3(pal, "Trim", P.stone_400), false, CFrame.Angles(0, -a, 0))
	end
end
FALLBACK.Castle_Tower = towerFallback
FALLBACK.Castle_TowerRoof = function(m, cf, s, pal, sh)
	towerFallback(m, cf, s, pal, sh)
	for i, r in ipairs({ 4.6, 3.5, 2.4, 1.3 }) do
		fcyl(m, cf, s, "Roof", r, 2.4, 0, 15 + (i - 1) * 2.4, 0, c3(pal, "Roof", P.slate_600), sh and i == 1)
	end
	fblock(m, cf, s, "Pennant", Vector3.new(1.6, 0.8, 0.06), 0.8, 25.4, 0, c3(pal, "Pennant", P.crimson_600))
end
FALLBACK.Castle_Gate = function(m, cf, s, pal, sh)
	fblock(m, cf, s, "Wall", Vector3.new(3.4, 11.5, 4), -4.3, 5.75, 0, c3(pal, "Stone", P.stone_500), sh)
	fblock(m, cf, s, "Wall", Vector3.new(3.4, 11.5, 4), 4.3, 5.75, 0, c3(pal, "Stone", P.stone_500), sh)
	fblock(m, cf, s, "Trim", Vector3.new(5.2, 4.2, 4), 0, 9.4, 0, c3(pal, "Trim", P.stone_400), sh)
	fblock(m, cf, s, "Doorway", Vector3.new(5.2, 7.3, 0.3), 0, 3.65, 0.6, c3(pal, "Warm", P.gold_700))
	for _, x in ipairs({ -2, -1, 0, 1, 2 }) do
		fblock(m, cf, s, "Portcullis", Vector3.new(0.18, 2.6, 0.18), x, 6, -1.6, c3(pal, "Iron", P.steel_800))
	end
	for x = -4.5, 4.5, 3 do
		fblock(m, cf, s, "Trim", Vector3.new(1.8, 1.2, 4), x, 12.1, 0, c3(pal, "Trim", P.stone_400), false)
	end
end
FALLBACK.Castle_Banner = function(m, cf, s, pal)
	fblock(m, cf, s, "Rod", Vector3.new(3.2, 0.2, 0.2), 0, 0, -0.2, c3(pal, "Iron", P.steel_700))
	fblock(m, cf, s, "Cloth", Vector3.new(2.6, 5.6, 0.1), 0, -3, -0.2, c3(pal, "Cloth", P.crimson_600))
	fblock(m, cf, s, "Gold", Vector3.new(1.2, 0.8, 0.12), 0, -2.2, -0.27, c3(pal, "Gold", P.gold_500))
end
FALLBACK.Torch_Wall = function(m, cf, s, pal)
	fblock(m, cf, s, "Iron", Vector3.new(0.4, 0.8, 0.2), 0, 0, -0.1, c3(pal, "Iron", P.steel_700))
	fblock(m, cf, s, "Stick", Vector3.new(0.2, 1.4, 0.2), 0, 0.5, -0.6, c3(pal, "Wood", P.wood_500), false, CFrame.Angles(math.rad(-20), 0, 0))
	fball(m, cf, s, "Flame", Vector3.new(0.45, 0.7, 0.45), 0, 1.35, -0.85, c3(pal, "Flame", P.fx_fire)).Material = NEON
end
FALLBACK.Brazier = function(m, cf, s, pal, sh)
	fcyl(m, cf, s, "Pedestal", 0.55, 2.6, 0, 0, 0, c3(pal, "Stone", P.stone_500), sh)
	fcyl(m, cf, s, "Bowl", 1.0, 0.6, 0, 2.6, 0, c3(pal, "Iron", P.steel_700))
	fball(m, cf, s, "Flame", Vector3.new(1.2, 1.4, 1.2), 0, 3.6, 0, c3(pal, "Flame", P.fx_fire)).Material = NEON
end
FALLBACK.Dais = function(m, cf, s, pal, sh)
	fcyl(m, cf, s, "Rim", 5.5, 0.6, 0, 0, 0, c3(pal, "Rim", P.stone_500), sh)
	fcyl(m, cf, s, "Top", 4.2, 0.6, 0, 0.6, 0, c3(pal, "Top", P.stone_300), sh)
	fcyl(m, cf, s, "Inlay", 3.2, 0.03, 0, 1.2, 0, c3(pal, "Inlay", P.gold_500))
	fcyl(m, cf, s, "Top", 2.9, 0.04, 0, 1.2, 0, c3(pal, "Top", P.stone_300))
end

-- Biome kit pieces (Swamp / Snow / Desert / Lava) have no hand-made fallback: until the
-- mesh loads they are drawn as one block per catalog piece (its box, slot colour and
-- material), which keeps sizes, colours and the hazard pools readable.
local BIOME_KITS = { Swamp = true, Snow = true, Desert = true, Lava = true }
local catalogFallbacks: { [string]: (Model, CFrame, number, Pal, boolean) -> () } = {}

local function catalogFallback(name: string): ((Model, CFrame, number, Pal, boolean) -> ())?
	local cached = catalogFallbacks[name]
	if cached then
		return cached
	end
	local entry = (MeshCatalog.Models :: any)[name]
	if not (entry and entry.Pieces and BIOME_KITS[entry.Category]) then
		return nil
	end
	local build = function(m: Model, cf: CFrame, s: number, pal: Pal, sh: boolean)
		for _, pc in ipairs(entry.Pieces) do
			local o, z = pc.Offset, pc.Size
			local p = fpart(m, cf, s, pc.Name, Vector3.new(z[1], z[2], z[3]) * 0.9, CFrame.new(o[1], o[2], o[3]), pal[pc.Slot] or P.stone_500, sh and pc.Shadow == true, nil, pc.Material == "Neon" and NEON or nil)
			if pc.Transparency then
				p.Transparency = pc.Transparency
			end
		end
	end
	catalogFallbacks[name] = build
	return build
end

-- One MeshService.WhenReady per model name while meshes are still loading. A model that
-- is standing in with its fallback right now moves to the front of the load queue.
local waitingSwaps: { [string]: { () -> () } } = {}

local function whenMeshLoads(name: string, fn: () -> ())
	MeshService.Prioritize({ name })
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

local function applyOpts(p: BasePart, opts: PropOpts)
	if opts.shadow == false then
		p.CastShadow = false
	end
	if opts.query then
		p.CanQuery = true
	end
end

-- Moves the mesh pieces of kit model `name` into `container`; false when not loaded.
local function fillMesh(container: Model, name: string, cf: CFrame, scale: number, palette: Pal?, opts: PropOpts): boolean
	local model = MeshService.Build(name, cf, palette, scale)
	if not model then
		return false
	end
	for _, d in ipairs(model:GetChildren()) do
		if d:IsA("BasePart") then
			applyOpts(d, opts)
			d.Parent = container
		end
	end
	model:Destroy()
	return true
end

-- Places kit piece `name` with its origin at `cf`. Returns the container Model.
local function prop(parent: Instance, name: string, cf: CFrame, scale: number?, palette: Pal?, opts: PropOpts?): Model
	local s = scale or 1
	local o: PropOpts = opts or {}
	local container = Instance.new("Model")
	container.Name = name
	if name == "GrassTuft" then
		-- Keep the same seeded prop placement and palette without replacing these
		-- narrow blades when the old mesh finishes loading.
		FALLBACK.GrassTuft(container, cf, s, kitPalette(name, palette), false)
	elseif not fillMesh(container, name, cf, s, palette, o) then
		local build = FALLBACK[name] or o.fallback or catalogFallback(name)
		if build then
			build(container, cf, s, kitPalette(name, palette), o.shadow ~= false)
			for _, d in ipairs(container:GetChildren()) do
				if d:IsA("BasePart") then
					applyOpts(d, o)
				end
			end
		end
		if MeshService.MayLoad(name) then
			whenMeshLoads(name, function()
				if container.Parent then
					local old = container:GetChildren()
					if fillMesh(container, name, cf, s, palette, o) then
						for _, d in ipairs(old) do
							d:Destroy()
						end
					end
				end
			end)
		end
	end
	if o.occluder then
		tag(container)
	end
	container.Parent = parent
	return container
end

-- World position of the kit's light point (catalog Light extra), or nil.
local function kitLightPoint(name: string, cf: CFrame, scale: number): Vector3?
	local entry = kitEntry(name)
	local l = entry and entry.Light
	if not l then
		return nil
	end
	return cf:PointToWorldSpace(Vector3.new(l[1], l[2], l[3]) * scale)
end

------------------------------------------------------------------------------------------
-- LIGHTING (Lighting.Technology = Future is set in default.project.json)
------------------------------------------------------------------------------------------

local LIGHTING = {
	-- dusk courtyard: cool slate sky and ambient, a low warm sun under the horizon glow;
	-- the fire pools and the key light on the dais do the rest
	Lobby = {
		Clock = 18.1, Brightness = 1.4, Latitude = 40, Shadow = 0.35,
		Ambient = rgb(118, 124, 160), Outdoor = rgb(152, 160, 204), Top = rgb(190, 192, 230), Bottom = rgb(56, 54, 74),
		Diffuse = 0.35, Specular = 0.3,
		Atmo = { Density = 0.28, Offset = 0.2, Color = rgb(126, 146, 200), Decay = rgb(218, 138, 100), Glare = 0.2, Haze = 1.1 },
		Bloom = { Intensity = 0.35, Size = 22, Threshold = 1.4 },
		Grade = { Brightness = 0.01, Contrast = 0.13, Saturation = 0.16, Tint = rgb(246, 244, 255) },
		Rays = { Intensity = 0.02, Spread = 0.5 },
		Clouds = { Cover = 0.55, Density = 0.55, Color = rgb(150, 136, 160) },
	},
	-- Arenas follow the bright "sunny storybook" look (docs/ART_DIRECTION.md): a warm
	-- high sun with soft shadows, warm ambient and a green / sand ground bounce, little
	-- haze, a positive Saturation grade and modest bloom (torches, lava and crystals glow,
	-- nothing blows out to white). The grade lifts every colour together, so enemies,
	-- gems and the hero keep their contrast against the brighter floors.
	-- sunny late morning in a forest clearing: saturated meadow, warm light
	Forest = {
		Clock = 10.8, Brightness = 3.0, Latitude = 38, Shadow = 0.55,
		Ambient = rgb(128, 126, 112), Outdoor = rgb(160, 162, 150), Top = rgb(255, 242, 212), Bottom = rgb(82, 112, 64),
		Diffuse = 0.5, Specular = 0.35,
		Atmo = { Density = 0.16, Offset = 0.05, Color = rgb(186, 220, 248), Decay = rgb(106, 160, 204), Glare = 0, Haze = 0.25 },
		Bloom = { Intensity = 0.25, Size = 22, Threshold = 1.7 },
		Grade = { Brightness = 0, Contrast = 0.12, Saturation = 0.22, Tint = rgb(255, 251, 240) },
		Rays = { Intensity = 0.03, Spread = 0.5 },
		Clouds = { Cover = 0.4, Density = 0.42, Color = rgb(255, 255, 255) },
	},
	-- sunny afternoon over the ruins: light warm paving on bright grass (warm, not dusk)
	Ruins = {
		Clock = 14.6, Brightness = 3.0, Latitude = 32, Shadow = 0.55,
		Ambient = rgb(130, 124, 112), Outdoor = rgb(162, 160, 150), Top = rgb(255, 238, 206), Bottom = rgb(88, 110, 66),
		Diffuse = 0.5, Specular = 0.35,
		Atmo = { Density = 0.18, Offset = 0.06, Color = rgb(204, 222, 242), Decay = rgb(178, 150, 120), Glare = 0.1, Haze = 0.35 },
		Bloom = { Intensity = 0.26, Size = 22, Threshold = 1.7 },
		Grade = { Brightness = 0, Contrast = 0.12, Saturation = 0.2, Tint = rgb(255, 249, 238) },
		Rays = { Intensity = 0.04, Spread = 0.55 },
		Clouds = { Cover = 0.32, Density = 0.4, Color = rgb(255, 244, 230) },
	},
	-- bright humid midday over the bog: lush moss greens, a light haze, warm sun
	Swamp = {
		Clock = 11.2, Brightness = 2.85, Latitude = 36, Shadow = 0.55,
		Ambient = rgb(118, 128, 104), Outdoor = rgb(152, 168, 136), Top = rgb(255, 246, 214), Bottom = rgb(72, 102, 58),
		Diffuse = 0.5, Specular = 0.3,
		Atmo = { Density = 0.2, Offset = 0.06, Color = rgb(190, 226, 200), Decay = rgb(104, 150, 98), Glare = 0, Haze = 0.5 },
		Bloom = { Intensity = 0.24, Size = 20, Threshold = 1.8 },
		Grade = { Brightness = 0, Contrast = 0.12, Saturation = 0.2, Tint = rgb(250, 255, 240) },
		Rays = { Intensity = 0.02, Spread = 0.5 },
		Clouds = { Cover = 0.5, Density = 0.45, Color = rgb(240, 244, 236) },
	},
	-- crisp sunny snowfield: lower sun brightness (the floor is white), cool fill.
	-- Readability on snow: a dimmer sun, less haze and bloom, crisper shadows and a bit
	-- more contrast and colour, so pale creatures, gems, warnings and the hero stand out
	-- from the floor (the floor itself is a greyer packed snow, see buildSnow).
	Snow = {
		Clock = 11.4, Brightness = 2.25, Latitude = 44, Shadow = 0.3,
		Ambient = rgb(108, 116, 132), Outdoor = rgb(140, 152, 174), Top = rgb(255, 244, 226), Bottom = rgb(110, 122, 140),
		Diffuse = 0.42, Specular = 0.3,
		Atmo = { Density = 0.18, Offset = 0.05, Color = rgb(192, 218, 250), Decay = rgb(124, 162, 210), Glare = 0, Haze = 0.35 },
		Bloom = { Intensity = 0.14, Size = 20, Threshold = 2.7 },
		Grade = { Brightness = -0.02, Contrast = 0.17, Saturation = 0.18, Tint = rgb(246, 248, 255) },
		Rays = { Intensity = 0.02, Spread = 0.5 },
		Clouds = { Cover = 0.42, Density = 0.4, Color = rgb(255, 255, 255) },
	},
	-- high desert sun: short soft shadows, warm sand bounce, a clear sky
	Desert = {
		Clock = 12.6, Brightness = 2.9, Latitude = 30, Shadow = 0.5,
		Ambient = rgb(126, 112, 94), Outdoor = rgb(160, 148, 128), Top = rgb(255, 238, 206), Bottom = rgb(128, 102, 66),
		Diffuse = 0.5, Specular = 0.3,
		Atmo = { Density = 0.18, Offset = 0.06, Color = rgb(214, 220, 236), Decay = rgb(200, 164, 116), Glare = 0.12, Haze = 0.5 },
		Bloom = { Intensity = 0.2, Size = 20, Threshold = 2.0 },
		Grade = { Brightness = 0.01, Contrast = 0.12, Saturation = 0.2, Tint = rgb(255, 248, 236) },
		Rays = { Intensity = 0.03, Spread = 0.5 },
		Clouds = { Cover = 0.2, Density = 0.35, Color = rgb(255, 250, 240) },
	},
	-- volcanic afternoon: warm light ash, red-orange bounce and glowing lava under a
	-- clear bright sun, so the swarm, pickups and the lava glow stay readable
	Lava = {
		Clock = 13.8, Brightness = 3.0, Latitude = 34, Shadow = 0.5,
		Ambient = rgb(142, 126, 118), Outdoor = rgb(178, 160, 148), Top = rgb(255, 236, 212), Bottom = rgb(128, 86, 62),
		Diffuse = 0.45, Specular = 0.3,
		Atmo = { Density = 0.18, Offset = 0.06, Color = rgb(222, 190, 166), Decay = rgb(196, 106, 64), Glare = 0.15, Haze = 0.6 },
		Bloom = { Intensity = 0.3, Size = 22, Threshold = 1.6 },
		Grade = { Brightness = 0.02, Contrast = 0.13, Saturation = 0.2, Tint = rgb(255, 245, 232) },
		Rays = { Intensity = 0.03, Spread = 0.5 },
		Clouds = { Cover = 0.5, Density = 0.48, Color = rgb(198, 172, 160) },
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
	Lighting.GlobalShadows = true
	Lighting.Ambient = L.Ambient
	Lighting.OutdoorAmbient = L.Outdoor
	Lighting.ColorShift_Top = L.Top
	Lighting.ColorShift_Bottom = L.Bottom
	Lighting.EnvironmentDiffuseScale = L.Diffuse
	Lighting.EnvironmentSpecularScale = L.Specular
	Lighting.FogEnd = 100000
	Lighting.ExposureCompensation = 0

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

	-- dynamic clouds (no custom sky textures)
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		pcall(function()
			local clouds = terrain:FindFirstChildOfClass("Clouds") or Instance.new("Clouds")
			clouds.Cover = L.Clouds.Cover
			clouds.Density = L.Clouds.Density
			clouds.Color = L.Clouds.Color
			clouds.Enabled = true
			clouds.Parent = terrain
		end)
	end
end

------------------------------------------------------------------------------------------
-- LOBBY: a castle courtyard at dusk, composed for the fixed menu camera.
--
--   north (−Z): keep wall with the gatehouse centred behind the hero, roofed towers
--               framing it, crimson banners and wall torches, pines over the battlements
--   centre:     the round two-step dais (part "MenuStand" on its top) between two braziers
--   south (+Z): the menu camera; behind it, out of the shot, the waiting spot where real
--               lobby characters spawn (WalkSpeed 0) and the legacy prompts / boards
--
-- The client showcase (src/client/Showcase.lua) stands a local clone of the hero on
-- "MenuStand" facing "MenuCamera"; the menu UI keeps the left / right thirds and the
-- bottom centre, so everything that matters sits in the middle band.
------------------------------------------------------------------------------------------

local function textSurface(target: BasePart, face: Enum.NormalId, text: string, color: Color3): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = target
	local label = Instance.new("TextLabel")
	label.Name = "Title"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = text
	label.Parent = gui
	return gui
end

local function prompt(parent: Instance, action: string, object: string, name: string): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = 0
	p.MaxActivationDistance = 8
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.Enabled = false -- the 2D menu replaces the world prompts
	p.Parent = parent
	return p
end

-- Menu shot (studs, relative to the dais centre): camera height / distance, aim height.
local MENU = {
	DaisZ = -4, -- dais centre, relative to Config.Lobby.Origin
	CamHeight = 7.6,
	CamDistance = 23,
	AimHeight = 4.5, -- the hero's chest on the dais (the aim point lands at MenuHeroY)
	KeepZ = -21, -- keep wall face, relative to the dais
	WaitZ = 34, -- hidden waiting spot for real characters (behind the camera)
}

function MapBuilder.BuildLobby()
	rng = Random.new(SEEDS.Lobby)
	-- The lobby lives directly in workspace ("workspace.Lobby"): the client menu camera and
	-- the showcase both look there first (and in workspace.SwarmMap.Lobby).
	local mapRoot = ensureMapFolder()
	for _, where in ipairs({ workspace, mapRoot }) do
		local existing = where:FindFirstChild("Lobby")
		if existing then
			existing:Destroy()
		end
	end
	local folder = Instance.new("Model")
	folder.Name = "Lobby"
	folder.Parent = workspace

	local o = Config.Lobby.Origin
	local daisPos = o + Vector3.new(0, 0, MENU.DaisZ)
	local keepZ = MENU.DaisZ + MENU.KeepZ -- keep wall front face (relative to o)
	local FACE_SOUTH = yawCF(180) -- kit fronts face −Z; this turns them toward the camera
	-- castle stone one step lighter than the kit default so it reads in the dusk light
	local CASTLE: Pal = { Stone = P.stone_400, Trim = P.stone_300, Base = P.stone_500 }
	local FLAME: Pal = { Flame = rgb(255, 128, 40), Core = rgb(255, 196, 110) }

	local function at(x: number, y: number, z: number): Vector3
		return o + Vector3.new(x, y, z)
	end
	local function add(props: { [string]: any }): BasePart
		return deco(folder, props)
	end

	--------------------------------------------------------------------------------------
	-- Ground: grout slab + 6-stud flagstones in three close stone tones, dark meadow
	-- outside the walls.
	local floorX0, floorX1 = -51, 51
	local floorZ0, floorZ1 = keepZ - 4, MENU.WaitZ + 10
	add({ Name = "Floor", Size = Vector3.new(floorX1 - floorX0, 2, floorZ1 - floorZ0), CFrame = CFrame.new(at((floorX0 + floorX1) / 2, -1.06, (floorZ0 + floorZ1) / 2)), Color = P.stone_700, CanCollide = true, CanQuery = true })
	add({ Name = "Grounds", Size = Vector3.new(420, 2, 420), CFrame = CFrame.new(at(0, -1.3, -60)), Color = P.moss_800, CanCollide = true })
	local tones = { P.stone_400, mix(P.stone_400, P.stone_500, 0.5), P.stone_500, mix(P.stone_400, P.slate_400, 0.25) }
	local tile = 6
	for ix = 0, 13 do
		for iz = 0, 8 do
			local x = -42 + tile / 2 + ix * tile
			local z = keepZ + tile / 2 + iz * tile
			local d = Vector2.new(x, z - MENU.DaisZ).Magnitude
			if d > 5.2 then -- the dais covers the middle
				local t = pick(tones)
				add({ Name = "Flagstone", Size = Vector3.new(tile - 0.32, 0.2, tile - 0.32), CFrame = CFrame.new(at(x, -0.1 + jitter(0.015), z)) * yawCF(jitter(0.8)), Color = t, CanQuery = true })
			end
		end
	end

	--------------------------------------------------------------------------------------
	-- Keep wall with the gatehouse in the middle, roofed towers framing it, plain towers
	-- at the corners, side walls running toward the camera.
	local wallZ = keepZ - 1.55 -- wall centre (3 thick, front face at keepZ)
	local GATE_S = 1.25
	local gateCF = CFrame.new(at(0, 0, keepZ - 2.05 * GATE_S + 0.4)) * FACE_SOUTH
	prop(folder, "Castle_Gate", gateCF, GATE_S, CASTLE)
	for _, sx in ipairs({ -1, 1 }) do
		for k = 1, 4 do
			prop(folder, "Castle_Wall", CFrame.new(at(sx * (k * 12), 0, wallZ)) * FACE_SOUTH, 1, CASTLE)
		end
		prop(folder, "Castle_TowerRoof", CFrame.new(at(sx * 19, 0, keepZ - 0.6)), 0.95, CASTLE)
		prop(folder, "Castle_Tower", CFrame.new(at(sx * 49, 0, wallZ)), 1.1, CASTLE)
		for k = 0, 3 do
			prop(folder, "Castle_Wall", CFrame.new(at(sx * 49, 0, keepZ + 6 + k * 12)) * yawCF(-90 * sx), 1, CASTLE)
		end
	end
	-- crimson banners and wall torches between the gate and the towers
	for _, sx in ipairs({ -1, 1 }) do
		prop(folder, "Castle_Banner", CFrame.new(at(sx * 10.9, 9.4, keepZ)) * FACE_SOUTH, 1.05)
		for _, x in ipairs({ 8.5, 13.3 }) do
			local cf = CFrame.new(at(sx * x, 4.6, keepZ)) * FACE_SOUTH
			prop(folder, "Torch_Wall", cf, 1.1, FLAME)
			pointLight(folder, kitLightPoint("Torch_Wall", cf, 1.1) or cf.Position, 13, 1.3, FIRE, true)
		end
	end
	-- warm-lit doorway inside the gate
	pointLight(folder, (kitLightPoint("Castle_Gate", gateCF, GATE_S) or at(0, 3, keepZ)) + Vector3.new(0, 1, 1.5), 13, 1.2, rgb(255, 176, 110), true)

	--------------------------------------------------------------------------------------
	-- The dais (raycast-able top for the showcase), braziers either side, the hero mark.
	local dais = prop(folder, "Dais", CFrame.new(daisPos), 1, nil, { query = true })
	local daisEntry = kitEntry("Dais")
	local daisTop = (daisEntry and daisEntry.Top) or 1.2
	for _, d in ipairs(dais:GetChildren()) do
		if d:IsA("BasePart") then
			d.CanCollide = true
		end
	end
	for _, sx in ipairs({ -1, 1 }) do
		local cf = CFrame.new(daisPos + Vector3.new(sx * 7.2, 0, -1.6))
		prop(folder, "Brazier", cf, 1.05, { Flame = FLAME.Flame, Core = FLAME.Core, Stone = P.stone_400, Base = P.stone_500 })
		pointLight(folder, (kitLightPoint("Brazier", cf, 1.05) or cf.Position + Vector3.new(0, 3.4, 0)) + Vector3.new(0, 1.8, 0), 17, 1.9, FIRE, true)
	end
	local camPos = daisPos + Vector3.new(0, MENU.CamHeight, MENU.CamDistance)
	local standPos = daisPos + Vector3.new(0, daisTop + 0.025, 0)
	local menuStand = add({
		Name = "MenuStand",
		Size = Vector3.new(2, 0.05, 2),
		CFrame = CFrame.lookAt(standPos, Vector3.new(camPos.X, standPos.Y, camPos.Z)),
		Transparency = 1,
	})
	-- key light: warm, in front of the hero and above the camera line, so the hero is the
	-- brightest thing in the shot; a cool rim from behind separates it from the gate
	pointLight(folder, daisPos + Vector3.new(-2.5, 8.5, 7.5), 15, 2.4, rgb(255, 226, 188), false)
	pointLight(folder, daisPos + Vector3.new(3, 7, -5), 9, 0.9, rgb(170, 190, 255), false)
	-- cool "moonlight" fill over the courtyard so the walls and towers read at dusk
	pointLight(folder, daisPos + Vector3.new(0, 24, -2), 50, 1.0, rgb(150, 170, 230), false)

	--------------------------------------------------------------------------------------
	-- Props at the edges: crates / barrels against the wall, ferns and shrubs at its foot,
	-- pines over the battlements.
	for _, sx in ipairs({ -1, 1 }) do
		local base = at(sx * 13.6, 0, keepZ + 4.2)
		prop(folder, "Crate", CFrame.new(base) * yawCF(8 * sx), 1.25)
		prop(folder, "Crate", CFrame.new(base + Vector3.new(sx * 2.7, 0, 0.5)) * yawCF(-12 * sx), 1.1)
		prop(folder, "Crate", CFrame.new(base + Vector3.new(sx * 1.2, 2.5, 0.1)) * yawCF(25 * sx), 0.95)
		prop(folder, "Barrel", CFrame.new(base + Vector3.new(-sx * 2.8, 0, 0.6)), 1.25)
		prop(folder, "Barrel", CFrame.new(base + Vector3.new(-sx * 4.6, 0, 1.4)), 1.15)
		for _, x in ipairs({ 8.2, 16.4, 25, 30 }) do
			prop(folder, "Fern", CFrame.new(at(sx * (x + jitter(0.6)), 0, keepZ + 0.9 + jitter(0.3))) * randomYaw(), rng:NextNumber(1.1, 1.5), nil, { shadow = false })
		end
		prop(folder, "Bush", CFrame.new(at(sx * 26.5, 0, keepZ + 6.5)) * randomYaw(), 1.3, nil, { shadow = false })
		prop(folder, "Fern", CFrame.new(at(sx * 8.4, 0, MENU.DaisZ + 1.5)) * randomYaw(), 1.0, nil, { shadow = false })
		prop(folder, "GrassTuft", CFrame.new(at(sx * 11, 0, MENU.DaisZ - 6)) * randomYaw(), 1.2, nil, { shadow = false })
	end
	for i = 1, 18 do
		local x = -64 + (i - 1) * (128 / 17) + jitter(2.5)
		local z = keepZ - rng:NextNumber(12, 30)
		if math.abs(x) > 12 or z < keepZ - 24 then
			prop(folder, "Tree_PineTall", CFrame.new(at(x, 0, z)) * randomYaw(), rng:NextNumber(1.05, 1.45), { Needles = mix(P.moss_700, P.slate_500, 0.3), Needles2 = mix(P.moss_600, P.slate_500, 0.3) })
		end
	end

	--------------------------------------------------------------------------------------
	-- Embers drifting up from the braziers, a few dust motes in the torch light.
	local air = add({ Name = "Ambience", Size = Vector3.new(26, 5, 10), CFrame = CFrame.new(daisPos + Vector3.new(0, 4, -3)), Transparency = 1 })
	local motes = Instance.new("ParticleEmitter")
	motes.Name = "Embers"
	motes.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	motes.Color = ColorSequence.new(rgb(255, 196, 120))
	motes.LightEmission = 1
	motes.LightInfluence = 0
	motes.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.3, 0.14), NumberSequenceKeypoint.new(1, 0) })
	motes.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.3), NumberSequenceKeypoint.new(1, 1) })
	motes.Lifetime = NumberRange.new(4, 7)
	motes.Rate = 4
	motes.Speed = NumberRange.new(0.2, 0.6)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Acceleration = Vector3.new(0, 0.25, 0)
	motes.Shape = Enum.ParticleEmitterShape.Box
	motes.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	motes.Parent = air

	--------------------------------------------------------------------------------------
	-- Behind the camera: the low south wall, the waiting spot and the legacy prompts /
	-- boards (RunManager keeps them; the 2D menu replaces them, so they stay disabled).
	local southZ = MENU.WaitZ + 9
	for k = -3, 3 do
		prop(folder, "Castle_Wall", CFrame.new(at(k * 12, 0, southZ + 1.5)), 1, nil, { shadow = false })
	end
	local waitPos = at(0, 0, MENU.WaitZ)
	local function post(name: string, x: number): BasePart
		return add({ Name = name, Size = Vector3.new(4, 2, 0.4), CFrame = CFrame.new(at(x, 1.6, southZ - 0.4)), Color = P.slate_800, CanQuery = true })
	end
	local startPad = add({ Name = "StartPad", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 4, 4), CFrame = CFrame.new(at(-6, 0.1, southZ - 4)) * UPRIGHT, Color = P.gold_600, CanQuery = true })
	local duoPad = add({ Name = "DuoPad", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 4, 4), CFrame = CFrame.new(at(6, 0.1, southZ - 4)) * UPRIGHT, Color = P.slate_500, CanQuery = true })
	local startPrompt = prompt(startPad, "Start Run", "Squad (1-4 players)", "StartPadPrompt")
	local duoPrompt = prompt(duoPad, "Start Run", "Duo (2 players)", "DuoPadPrompt")
	local arenaSign = post("ArenaSign", -14)
	local arenaGui = textSurface(arenaSign, Enum.NormalId.Front, "ARENA: FOREST", P.gold_300)
	local arenaPrompt = prompt(arenaSign, "Change Arena", "Arena", "ArenaPrompt")
	local charBoard = post("CharacterBoard", -20)
	textSurface(charBoard, Enum.NormalId.Front, "CHARACTERS", P.ivory_100)
	local charPrompt = prompt(charBoard, "Choose Character", "Characters", "CharacterPrompt")
	local shopBoard = post("ShopBoard", 20)
	textSurface(shopBoard, Enum.NormalId.Front, "UPGRADES", P.gold_300)
	local shopPrompt = prompt(shopBoard, "Open Shop", "Upgrades", "ShopPrompt")

	--------------------------------------------------------------------------------------
	-- Menu camera: low and centred, aimed at the hero's chest on the dais. The gate sits
	-- right behind the hero, banners / torches / braziers stay in the middle band, the
	-- roofed towers frame it at the UI column edges and the dais step shows above the
	-- nameplate.
	local fov = Config.Lobby.MenuFieldOfView or 45
	local camLook = daisPos + Vector3.new(0, MENU.AimHeight, 0)
	local menuCamera = add({ Name = "MenuCamera", Size = Vector3.new(1, 1, 1), CFrame = CFrame.lookAt(camPos, camLook), Transparency = 1 })
	menuCamera:SetAttribute("FieldOfView", fov)
	menuCamera:SetAttribute("Focus", camLook)
	menuStand:SetAttribute("Top", daisTop)

	MapBuilder.ApplyLighting("Lobby")

	return {
		Model = folder,
		-- real lobby characters wait behind the menu camera (RunManager adds a 5-stud ring)
		SpawnCFrame = CFrame.new(waitPos + Vector3.new(0, 3.5, 0)) * yawCF(180),
		MenuCamera = menuCamera,
		MenuStand = menuStand,
		StartPrompt = startPrompt,
		DuoPrompt = duoPrompt,
		DuoPad = duoPad,
		ArenaPrompt = arenaPrompt,
		ArenaLabel = arenaGui:FindFirstChild("Title") :: TextLabel,
		CharacterPrompt = charPrompt,
		ShopPrompt = shopPrompt,
		StartPad = startPad,
	}
end

------------------------------------------------------------------------------------------
-- ARENA TOOLKIT
------------------------------------------------------------------------------------------

type Arena = { [string]: any }

local function newArena(name: string): Arena
	local root = ensureMapFolder()
	local model = Instance.new("Model")
	model.Name = "Arena_" .. name
	local obstacleFolder = Instance.new("Folder")
	obstacleFolder.Name = "Obstacles"
	obstacleFolder.Parent = model
	local decoFolder = Instance.new("Folder")
	decoFolder.Name = "Decor"
	decoFolder.Parent = model
	return {
		Name = name,
		Model = model,
		Decor = decoFolder,
		ObstacleFolder = obstacleFolder,
		Obstacles = {},
		Keepout = {}, -- { X, Z, R } circles that scattered decoration avoids
		Bare = {}, -- { X, Z, R } floor the client ground detail leaves clean (paved plazas)
		Hazards = {}, -- { Kind, Pos (world floor point), Radius } biome floor hazards (BiomeHazards)
		Paths = {}, -- { {A = Vector3, B = Vector3, W = halfWidth} } path segments
		Root = root,
		Half = Config.Arenas.Size / 2,
		Center = Config.ArenaOrigin,
		Clear = Config.Arenas.ClearRadius or 40,
		Trees = 0,
		Rocks = 0,
		Lights = 0,
	}
end

-- World position of an arena-relative point on the floor.
local function W(arena: Arena, x: number, z: number, y: number?): Vector3
	local c = arena.Center
	return Vector3.new(c.X + x, c.Y + (y or 0), c.Z + z)
end

local function keepout(arena: Arena, x: number, z: number, r: number)
	table.insert(arena.Keepout, { X = x, Z = z, R = r })
end

-- Distance from (x, z) (arena-relative) to the nearest path edge (negative = on it).
local function pathDistance(arena: Arena, x: number, z: number): number
	local best = math.huge
	for _, seg in ipairs(arena.Paths) do
		local ax, az, bx, bz = seg.A.X, seg.A.Z, seg.B.X, seg.B.Z
		local dx, dz = bx - ax, bz - az
		local len2 = dx * dx + dz * dz
		local t = len2 > 0 and math.clamp(((x - ax) * dx + (z - az) * dz) / len2, 0, 1) or 0
		local px, pz = ax + dx * t - x, az + dz * t - z
		best = math.min(best, math.sqrt(px * px + pz * pz) - seg.W)
	end
	return best
end

-- Is (x, z) (arena-relative) clear of obstacles, keepouts, hazard pools and paths by
-- `clear` studs? hazardPad: extra floor kept from a pool's edge (portal, loot).
local function isFree(arena: Arena, x: number, z: number, clear: number, pathPad: number?, hazardPad: number?): boolean
	if math.abs(x) > arena.Half - 3 or math.abs(z) > arena.Half - 3 then
		return false
	end
	local c = arena.Center
	local wx, wz = c.X + x, c.Z + z
	for _, ob in ipairs(arena.Obstacles) do
		if ob.Kind == "Circle" then
			local ox, oz = ob.Pos.X - wx, ob.Pos.Z - wz
			local r = ob.Radius + clear
			if ox * ox + oz * oz < r * r then
				return false
			end
		elseif wx > ob.MinX - clear and wx < ob.MaxX + clear and wz > ob.MinZ - clear and wz < ob.MaxZ + clear then
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
	for _, hz in ipairs(arena.Hazards) do
		local hx, hzz = hz.Pos.X - wx, hz.Pos.Z - wz
		local r = hz.Radius + clear + (hazardPad or 0)
		if hx * hx + hzz * hzz < r * r then
			return false
		end
	end
	if pathPad and pathDistance(arena, x, z) < pathPad then
		return false
	end
	return true
end

-- Collider parts + obstacle records (world x / z). Nothing collidable in the clearing.
local function insideClearing(arena: Arena, wx: number, wz: number, r: number): boolean
	local c = arena.Center
	local dx, dz = wx - c.X, wz - c.Z
	return math.sqrt(dx * dx + dz * dz) - r < arena.Clear
end

local function circleCollider(arena: Arena, wx: number, wz: number, r: number, h: number)
	if insideClearing(arena, wx, wz, r) then
		warn(string.format("[MapBuilder] collider at (%.0f, %.0f) skipped: inside the spawn clearing", wx, wz))
		return
	end
	local y = arena.Center.Y
	local cp = part({ Name = "Collider", Shape = Enum.PartType.Cylinder, Size = Vector3.new(h, r * 2, r * 2), CFrame = CFrame.new(wx, y + h / 2, wz) * UPRIGHT, Transparency = 1, CanCollide = true, CanQuery = true })
	cp.Parent = arena.ObstacleFolder
	table.insert(arena.Obstacles, { Kind = "Circle", Pos = Vector3.new(wx, y, wz), Radius = r })
end

local function boxCollider(arena: Arena, cx: number, cz: number, sx: number, sz: number, h: number)
	if insideClearing(arena, cx, cz, math.sqrt(sx * sx + sz * sz) / 2) then
		warn(string.format("[MapBuilder] collider at (%.0f, %.0f) skipped: inside the spawn clearing", cx, cz))
		return
	end
	local y = arena.Center.Y
	local cp = part({ Name = "Collider", Size = Vector3.new(sx, h, sz), CFrame = CFrame.new(cx, y + h / 2, cz), Transparency = 1, CanCollide = true, CanQuery = true })
	cp.Parent = arena.ObstacleFolder
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

-- Registers the catalog collider of kit piece `name` placed at `cf` (scaled). Boxes are
-- axis-aligned in the obstacle format: the box of a turned piece is its world AABB, so
-- colliding box pieces are placed at multiples of 90° (small tilts only grow it a bit).
local function addShape(arena: Arena, shape: any, cf: CFrame, s: number)
	local off = shape.Offset
	local centre = off and cf:PointToWorldSpace(Vector3.new(off[1] * s, 0, off[2] * s)) or cf.Position
	if shape.Kind == "Circle" then
		circleCollider(arena, centre.X, centre.Z, shape.Radius * s, shape.Height * s)
	elseif shape.Kind == "Box" then
		local hx, hz = shape.Size[1] * s / 2, shape.Size[2] * s / 2
		local r, l = cf.RightVector, cf.LookVector
		local ex = math.abs(r.X) * hx + math.abs(l.X) * hz
		local ez = math.abs(r.Z) * hx + math.abs(l.Z) * hz
		boxCollider(arena, centre.X, centre.Z, ex * 2, ez * 2, shape.Height * s)
	elseif shape.Kind == "Multi" then
		for _, sub in ipairs(shape.Shapes) do
			addShape(arena, sub, cf, s)
		end
	end
end

local function kitCollider(arena: Arena, name: string, cf: CFrame, s: number)
	local entry = kitEntry(name)
	if entry and entry.Collider then
		addShape(arena, entry.Collider, cf, s)
	end
end

-- A deliberate obstacle: kit prop + its one collider. (x, z) arena-relative.
local function obstacle(arena: Arena, name: string, x: number, z: number, yawDeg: number, s: number, palette: Pal?, opts: PropOpts?): Model
	local cf = CFrame.new(W(arena, x, z)) * yawCF(yawDeg)
	local m = prop(arena.Model, name, cf, s, palette, opts)
	kitCollider(arena, name, cf, s)
	return m
end

-- Decoration: kit prop with no collider. (x, z) arena-relative.
local function decor(arena: Arena, name: string, x: number, z: number, yawDeg: number?, s: number?, palette: Pal?, opts: PropOpts?): Model
	local cf = CFrame.new(W(arena, x, z)) * (yawDeg and yawCF(yawDeg) or randomYaw())
	return prop(arena.Decor, name, cf, s, palette, opts or { shadow = false })
end

-- Fire light on a kit piece (torch / lantern / brazier) at its catalog light point.
local function kitLight(arena: Arena, name: string, x: number, z: number, yawDeg: number, s: number, range: number, brightness: number, color: Color3)
	local cf = CFrame.new(W(arena, x, z)) * yawCF(yawDeg)
	local pos = kitLightPoint(name, cf, s) or cf.Position + Vector3.new(0, 4, 0)
	pointLight(arena.Model, pos + Vector3.new(0, 0.4, 0), range, brightness, color, true)
	arena.Lights += 1
end

local function tree(arena: Arena, name: string, x: number, z: number, s: number, palette: Pal?)
	obstacle(arena, name, x, z, rng:NextNumber(0, 360), s, palette, { occluder = true })
	arena.Trees += 1
end

local function boulder(arena: Arena, x: number, z: number, s: number, palette: Pal?)
	obstacle(arena, "Rock", x, z, rng:NextNumber(0, 360), s, palette, nil)
	arena.Rocks += 1
end

-- Ground clutter is drawn bigger than life so it reads from the high run camera.
local CLUTTER_SCALE: { [string]: number } = { GrassTuft = 1.0, Flowers = 1.5, Fern = 1.35, Rock_Small = 1.3, Mushroom = 1.3, Reeds = 1.3, Lilypads = 1.2, Snow_Drift = 1.1, Snow_Bush = 1.1, Ash_Pile = 1.2 }

-- Small clutter scattered in a disc around (cx, cz): { {name, sMin, sMax, palette?} }.
local function scatter(arena: Arena, cx: number, cz: number, radius: number, count: number, kinds: { { any } }, clear: number?, pathPad: number?)
	count = math.max(1, math.floor(count * (arena.DecorDensity or 1) + 0.5))
	local placed = 0
	for _ = 1, count * 8 do
		if placed >= count then
			break
		end
		local a = rng:NextNumber(0, TAU)
		local r = radius * math.sqrt(rng:NextNumber())
		local x, z = cx + math.cos(a) * r, cz + math.sin(a) * r
		if isFree(arena, x, z, clear or 0.8, pathPad) then
			local k = pick(kinds)
			decor(arena, k[1], x, z, nil, rng:NextNumber(k[2], k[3]) * (CLUTTER_SCALE[k[1]] or 1), k[4])
			placed += 1
		end
	end
end

-- Large soft ground patch: a blob of 3 overlapping discs of one tone.
local function patch(arena: Arena, x: number, z: number, r: number, color: Color3, y: number)
	local a0 = rng:NextNumber(0, TAU)
	disc(arena.Decor, "Patch", W(arena, x, z, y), r, color)
	for k = 1, 2 do
		local a = a0 + k * 2.4
		local d = r * rng:NextNumber(0.45, 0.7)
		disc(arena.Decor, "Patch", W(arena, x + math.cos(a) * d, z + math.sin(a) * d, y + 0.001 * k), r * rng:NextNumber(0.55, 0.75), color)
	end
end

-- Catmull-Rom points every ~step studs through the control points (arena-relative).
local function smoothPath(ctrl: { Vector2 }, step: number): { Vector2 }
	local out: { Vector2 } = {}
	for i = 1, #ctrl - 1 do
		local p0, p1, p2, p3 = ctrl[math.max(1, i - 1)], ctrl[i], ctrl[i + 1], ctrl[math.min(#ctrl, i + 2)]
		local n = math.max(1, math.floor((p2 - p1).Magnitude / step + 0.5))
		for k = 0, n - 1 do
			local t = k / n
			local t2, t3 = t * t, t * t * t
			table.insert(out, ((p1 * 2) + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5)
		end
	end
	table.insert(out, ctrl[#ctrl])
	return out
end

-- Flat dirt path with a soft (grass-dirt) edge. Segments butt end to end (no overlap,
-- so no z-fighting seams from the high run camera); a disc a hair lower fills the outside
-- of every bend. Registered in arena.Paths (decoration keeps off it).
local function dirtPath(arena: Arena, ctrl: { Vector2 }, width: number, core: Color3, edge: Color3, yBase: number)
	local pts = smoothPath(ctrl, 18)
	local edgeW = width + 2.8
	local limit = arena.Half + 34 -- the path fades into the tree line
	for i = 1, #pts - 1 do
		local a, b = pts[i], pts[i + 1]
		if math.max(math.abs(a.X), math.abs(a.Y)) > limit and math.max(math.abs(b.X), math.abs(b.Y)) > limit then
			continue
		end
		local d = b - a
		local len = d.Magnitude
		local mid = (a + b) / 2
		local yaw = math.atan2(-d.X, -d.Y)
		slab(arena.Decor, "PathEdge", W(arena, mid.X, mid.Y, yBase), edgeW, len, yaw, edge)
		slab(arena.Decor, "Path", W(arena, mid.X, mid.Y, yBase + 0.16), width, len, yaw, core, 0.2)
		-- bend fill only where the bend is wide enough to open a visible gap
		local bend = i > 1 and math.acos(math.clamp(d.Unit:Dot((a - pts[i - 1]).Unit), -1, 1)) or 0
		if bend > math.rad(4) then
			disc(arena.Decor, "PathEdgeBend", W(arena, a.X, a.Y, yBase - 0.06), edgeW / 2, edge)
			disc(arena.Decor, "PathBend", W(arena, a.X, a.Y, yBase + 0.08), width / 2, core)
		end
		table.insert(arena.Paths, { A = Vector3.new(a.X, 0, a.Y), B = Vector3.new(b.X, 0, b.Y), W = edgeW / 2 })
	end
	return pts
end

-- Invisible walls just outside the play square (enemy raycasts hit them).
local function boundaryWalls(arena: Arena)
	local c, h = arena.Center, arena.Half
	local size = Config.Arenas.Size
	for i, side in ipairs({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0) }) do
		local wallSize = (i <= 2) and Vector3.new(size + 4, 60, 2) or Vector3.new(2, 60, size + 4)
		local wall = part({ Name = "Boundary", Size = wallSize, CFrame = CFrame.new(c + side * (h + 1) + Vector3.new(0, 30, 0)), Transparency = 1, CanCollide = true, CanQuery = true })
		wall.Parent = arena.ObstacleFolder
	end
end

-- Walks the four sides: fn(side, along, out, t) every `step` studs (t from -from..to).
-- side: 1 north (−Z), 2 south (+Z, camera side), 3 west, 4 east. along / out unit x,z.
local function alongSides(from: number, to: number, step: number, fn: (number, Vector2, Vector2, number) -> ())
	local sides = { Vector2.new(0, -1), Vector2.new(0, 1), Vector2.new(-1, 0), Vector2.new(1, 0) }
	for i, out in ipairs(sides) do
		local along = (i <= 2) and Vector2.new(1, 0) or Vector2.new(0, 1)
		local t = from
		while t <= to do
			fn(i, along, out, t)
			t += step
		end
	end
end

-- Dense tree line outside the boundary (decoration: the boundary walls block). The south
-- (camera) side gets low shrubs and small round trees only. With cliffs (arena.Cliff,
-- built first) the north / west / east trees stand on the cliff top, a little sparser
-- (the rock already fills the edge), and only the south side keeps its shade discs.
local function treeLine(arena: Arena, kinds: { { any } }, southKinds: { { any } }, step: number, shade: Color3)
	local h = arena.Half
	local topAt: ((number, number) -> number)? = arena.CliffTop
	-- forest shade straddling the boundary: a wavy dark edge instead of a straight line
	-- (the meadow floor ends at h + 10, under this row of discs)
	alongSides(-h - 16, h + 16, 32, function(side, along, out, t)
		if topAt and side ~= 2 then
			return
		end
		local p = along * (t + jitter(5)) + out * (h + 10 + jitter(2))
		disc(arena.Decor, "Shade", W(arena, p.X, p.Y, 0.03), rng:NextNumber(18, 23), shade)
	end)
	alongSides(-h - 24, h + 24, step, function(side, along, out, t)
		local south = side == 2
		if (south and rng:NextNumber() < 0.5) or (side >= 3 and math.abs(t) > h + 8) then
			return -- the camera side stays low and open; corners come from the N / S rows
		end
		if topAt and not south and rng:NextNumber() < 0.5 then
			return
		end
		local depth = south and rng:NextNumber(12, 26) or (topAt and rng:NextNumber(11, 21) or rng:NextNumber(7, 17))
		local tt = t + jitter(step * 0.3)
		local p = along * tt + out * (h + depth)
		local y = (topAt and not south) and topAt(side, tt) - 1.2 or 0
		local k = pick(south and southKinds or kinds)
		local cf = CFrame.new(W(arena, p.X, p.Y, y)) * randomYaw()
		prop(arena.Decor, k[1], cf, rng:NextNumber(k[2], k[3]), k[4], { occluder = true, shadow = not south })
	end)
end

-- Broken split-rail fence along the boundary (decoration): runs of sections with gaps,
-- some leaning, one now and then fallen.
local function brokenFence(arena: Arena, scale: number, palette: Pal?, period: number)
	local h = arena.Half
	local len = 8 * scale
	local k = 0
	alongSides(-h + len / 2, h - len / 2, len, function(side, along, out, t)
		-- a short run (2, sometimes 3 sections) every `period` slots, offset per side
		k += 1
		if arena.Cliff and side ~= 2 then
			return -- the cliffs line the other three sides
		end
		local phase = (k + side * 7) % period
		if phase >= 2 and not (phase == 2 and rng:NextNumber() < 0.35) then
			return
		end
		local p = along * t + out * (h - 1)
		local yaw = math.deg(math.atan2(-along.Y, along.X))
		local cf = CFrame.new(W(arena, p.X, p.Y)) * yawCF(yaw + jitter(3))
		local roll = rng:NextNumber()
		if roll < 0.08 then
			-- fallen section lying in the grass
			cf = CFrame.new(W(arena, p.X - out.X * 1.8, p.Y - out.Y * 1.8, 0.3)) * yawCF(yaw + jitter(8)) * CFrame.Angles(math.rad(80), 0, 0) * CFrame.new(0, -0.5, 0)
		elseif roll < 0.25 then
			cf = cf * CFrame.Angles(math.rad(jitter(9)), 0, math.rad(jitter(5)))
		end
		prop(arena.Decor, "Fence_Section", cf, scale, palette, { shadow = false })
	end)
end

------------------------------------------------------------------------------------------
-- CLIFFS: the arena edge as real 3D rock (owner: "make the edges actual cliffs you can't
-- go through"). Chunky low-poly rock blocks stand all the way round the play square, their
-- inner faces just outside it, so what you see is where you stop: the invisible Boundary
-- walls (boundaryWalls) still do the blocking for players and enemy raycasts, and EnemyAI
-- clamps enemies to the square on the server.
--   * north / west / east: tall cliffs (style.Height) with a flat top in the biome's cap
--     colour (moss, snow, sand, ash); about half the chunks get a lower ledge in front, so
--     the face steps like a real cliff; the tree line stands on the top (treeLine);
--   * south (camera side): a low broken rim (style.South) the run camera sees over.
-- Cost per tall chunk (~35 studs): block + cap + one kit rock face (3 mesh parts), Ruins
-- a ledge (+2) instead of the rock; south rim one part per ~20 studs. All
-- decoration: anchored, no collision / queries / touch; only the big bodies cast shadows.
------------------------------------------------------------------------------------------

type CliffStyle = {
	Rock: { Color3 }, -- body tones (one per chunk)
	Cap: Color3, -- top surface
	CapThick: number?, -- default 0.8 (snow lies thicker)
	Height: { number }, -- { min, max } north / west / east
	South: { number }, -- { min, max } camera side
	Foot: { { any } }?, -- kit pieces at the foot: { name, sMin, sMax, palette? }
	Masonry: boolean?, -- Ruins: square-cut blocks, merlons on top, no tilt
	Seam: Color3?, -- Lava: a glowing crack at the foot of some chunks
	Face: { any }?, -- { kit rock, palette }: the big low-poly rock in front of each tall chunk
}

local CLIFF_STEP = 31 -- studs between chunk centres on the tall sides
local CLIFF_STEP_SOUTH = 19
local CLIFF_DEPTH = 24 -- depth of a tall chunk (its flat top carries the tree line)

-- Top height of the cliff at `t` along `side` (smooth, seeded per side).
local function cliffTop(arena: Arena, side: number, t: number): number
	local style: CliffStyle = arena.Cliff
	local wave = arena.CliffWave[side]
	local range = side == 2 and style.South or style.Height
	local f = 0.5 + 0.3 * math.sin(t / 41 + wave[1]) + 0.2 * math.sin(t / 17 + wave[2])
	return range[1] + (range[2] - range[1]) * f
end

-- Extent of a kit piece (max |x| / |z| of its catalog bounds) at scale 1.
local function kitRadius(name: string): number
	local entry = kitEntry(name)
	local b = entry and entry.Bounds
	if not b then
		return 2
	end
	return math.max(math.abs(b[1][1]), math.abs(b[1][3]), math.abs(b[2][1]), math.abs(b[2][3]))
end

-- One rock block whose inner face is `inner` studs out from the centre line, plus its cap.
local function cliffBlock(arena: Arena, style: CliffStyle, along: Vector2, out: Vector2, t: number, inner: number, len: number, depth: number, hgt: number, color: Color3, shadow: boolean, noCap: boolean?): CFrame
	local yawDeg = style.Masonry and 0 or jitter(7)
	local tilt = style.Masonry and 0 or 3
	-- a turned / tilted block pokes in by its half length * sin(yaw) and half height * sin(tilt)
	local poke = math.abs(math.sin(math.rad(yawDeg))) * len / 2 + math.sin(math.rad(tilt)) * hgt / 2
	local p = along * t + out * (inner + poke + depth / 2)
	local base = math.deg(math.atan2(-along.Y, along.X))
	local cf = CFrame.new(W(arena, p.X, p.Y, hgt / 2 - 1)) * yawCF(base + yawDeg) * CFrame.Angles(math.rad(jitter(tilt)), 0, math.rad(jitter(tilt)))
	deco(arena.Decor, { Name = "Cliff", Size = Vector3.new(len, hgt + 1, depth), CFrame = cf, Color = color, CastShadow = shadow })
	if noCap then
		return cf
	end
	local capT = style.CapThick or 0.8
	deco(arena.Decor, { Name = "CliffCap", Size = Vector3.new(len - 0.5, capT, depth - 0.5), CFrame = cf * CFrame.new(0, (hgt + 1) / 2 + capT / 2 - 0.25, 0), Color = style.Cap, CastShadow = false })
	return cf
end

local function cliffs(arena: Arena, style: CliffStyle)
	local h = arena.Half
	arena.Cliff = style
	arena.CliffWave = {}
	for side = 1, 4 do
		arena.CliffWave[side] = { rng:NextNumber(0, TAU), rng:NextNumber(0, TAU) }
	end
	local sides = { Vector2.new(0, -1), Vector2.new(0, 1), Vector2.new(-1, 0), Vector2.new(1, 0) }
	for side, out in ipairs(sides) do
		local along = (side <= 2) and Vector2.new(1, 0) or Vector2.new(0, 1)
		local south = side == 2
		local out3 = Vector3.new(out.X, 0, out.Y)
		local step = south and CLIFF_STEP_SOUTH or CLIFF_STEP
		-- north / south rows run past the corners; west / east rows fill between them
		local reach = side <= 2 and h + 30 or h + 6
		local t = -reach + jitter(3)
		local k = 0
		while t <= reach do
			k += 1
			local hgt = cliffTop(arena, side, t) + jitter(south and 0.5 or 1.5)
			local color = pick(style.Rock)
			if south then
				local len = rng:NextNumber(18, 23)
				cliffBlock(arena, style, along, out, t, h + rng:NextNumber(0.3, 1.0), len, rng:NextNumber(5, 8), hgt, color, false, true)
			else
				local len = rng:NextNumber(33, 39)
				local face = style.Face
				-- Rocky face: a big kit rock (low-poly mesh, the biome's own) in front of
				-- the block hides its flat front; the block behind gives the height and
				-- the flat top. Masonry (Ruins) keeps cut blocks with stepped ledges.
				-- (sized to cover most of the block's length, never taller than the block)
				local faceScale = face and math.clamp(len * rng:NextNumber(0.62, 0.78) / 4.9, hgt * 0.5 / 2.9, hgt * 0.95 / 2.9) or 0
				local ledge = not face and rng:NextNumber() < 0.45
				local ledgeDepth = rng:NextNumber(6, 9)
				local setback = face and faceScale * 1.2 or (ledge and ledgeDepth - 1.5 or rng:NextNumber(0.3, 2.4))
				local cf = cliffBlock(arena, style, along, out, t, h + setback, len, CLIFF_DEPTH + jitter(3), hgt, color, true)
				if face then
					-- long side along the wall; turned up to 15°, its deepest point stays outside
					local fyaw = math.deg(math.atan2(-along.Y, along.X)) + jitter(15) + (rng:NextNumber() < 0.5 and 180 or 0)
					local fp = along * (t + jitter(4)) + out * (h + 2.25 * faceScale - 0.3)
					local fcf = CFrame.new(W(arena, fp.X, fp.Y, -0.3)) * yawCF(fyaw)
					prop(arena.Decor, face[1], fcf, faceScale, face[2], { shadow = true })
				end
				if ledge then
					local lh = hgt * rng:NextNumber(0.35, 0.6)
					cliffBlock(arena, style, along, out, t + jitter(len * 0.2), h + 0.3, len * rng:NextNumber(0.5, 0.75), ledgeDepth, lh, pick(style.Rock), false)
				end
				if style.Masonry then
					-- merlons on the wall top (a broken battlement)
					for _, dx in ipairs({ -len * 0.3, len * 0.3 }) do
						if rng:NextNumber() < 0.6 then
							local at = cf * CFrame.new(dx + jitter(2), (hgt + 1) / 2 + 1.1, 0)
							deco(arena.Decor, { Name = "Merlon", Size = Vector3.new(3.4, 2.2, 3), CFrame = at - out3 * (CLIFF_DEPTH / 2 - 2), Color = style.Rock[1], CastShadow = false })
						end
					end
				end
				if style.Seam and k % 3 == 0 then
					local sp = along * t + out * (h + 0.5)
					deco(arena.Decor, { Name = "CliffSeam", Size = Vector3.new(len * 0.55, 0.35, 0.7), CFrame = CFrame.new(W(arena, sp.X, sp.Y, 0.2)) * yawCF(math.deg(math.atan2(-along.Y, along.X))), Color = style.Seam, Material = NEON })
				end
				-- a kit rock at the foot (it pokes at most a stud into the play square)
				if style.Foot and math.abs(t) < h - 6 and rng:NextNumber() < (face and 0.15 or 0.3) then
					local f = pick(style.Foot)
					local s = rng:NextNumber(f[2], f[3])
					local d = h + kitRadius(f[1]) * s - 1
					local p = along * (t + jitter(8)) + out * d
					decor(arena, f[1], p.X, p.Y, nil, s, f[4], { shadow = false })
				end
			end
			t += step + jitter(step * 0.15)
		end
	end
	arena.CliffTop = function(side: number, t: number): number
		return cliffTop(arena, side, t)
	end
end

------------------------------------------------------------------------------------------
-- VIGNETTES (owner: "objects in the world look pretty bland"): small clustered scenes
-- dropped in the open meadow between the landmarks: a cold campfire, a mushroom ring, a
-- supply stack, a crystal patch, a fallen banner ... Decoration only (no colliders), low,
-- kept off the paths, the spawn clearing, landmarks and hazard pools; the loot / portal
-- placement clears decor around its own spots anyway.
------------------------------------------------------------------------------------------

type Vignette = (Arena, number, number) -> ()

local function campfire(arena: Arena, x: number, z: number, stone: Pal?, wood: Color3?)
	local w = wood or P.wood_600
	for k = 0, 5 do
		local a = k / 6 * TAU + jitter(0.2)
		decor(arena, "Rock_Small", x + math.cos(a) * 1.5, z + math.sin(a) * 1.5, nil, rng:NextNumber(0.55, 0.75), stone)
	end
	disc(arena.Decor, "Ash", W(arena, x, z, 0.06), 1.2, mix(P.cinder_500, P.dirt_500, 0.4))
	for _, yaw in ipairs({ 30, -40 }) do
		deco(arena.Decor, { Name = "FireLog", Size = Vector3.new(2.1, 0.35, 0.35), CFrame = CFrame.new(W(arena, x, z, 0.3)) * yawCF(yaw + jitter(10)) * CFrame.Angles(0, 0, math.rad(12)), Color = w })
	end
	deco(arena.Decor, { Name = "Embers", Shape = Enum.PartType.Ball, Size = Vector3.new(0.9, 0.4, 0.9), CFrame = CFrame.new(W(arena, x, z, 0.2)), Color = P.lava_300, Material = NEON })
	decor(arena, "Log", x + 3.2, z + jitter(1), rng:NextNumber(0, 360), 0.7)
end

local function ring(arena: Arena, x: number, z: number, name: string, n: number, r: number, sMin: number, sMax: number, palette: Pal?)
	local a0 = rng:NextNumber(0, TAU)
	for k = 1, n do
		local a = a0 + k / n * TAU + jitter(0.25)
		local d = r + jitter(r * 0.25)
		decor(arena, name, x + math.cos(a) * d, z + math.sin(a) * d, nil, rng:NextNumber(sMin, sMax), palette)
	end
end

local function supplies(arena: Arena, x: number, z: number, wood: Pal?)
	local yaw = rng:NextNumber(0, 360)
	decor(arena, "Crate", x, z, yaw, 1.0, wood, { shadow = true })
	decor(arena, "Crate", x + 2.1, z + jitter(0.4), yaw + jitter(15), 0.9, wood)
	prop(arena.Decor, "Crate", CFrame.new(W(arena, x + 0.9, z, 1.95)) * yawCF(yaw + 25), 0.8, wood, { shadow = false })
	decor(arena, "Barrel", x - 1.8, z + 1.2, nil, 1.0, wood)
	if rng:NextNumber() < 0.5 then
		decor(arena, "Barrel", x - 1.6, z - 0.9, nil, 0.9, wood)
	end
end

local function cluster(arena: Arena, x: number, z: number, kinds: { { any } }, n: number, r: number)
	for _ = 1, n do
		local k = pick(kinds)
		local a, d = rng:NextNumber(0, TAU), r * math.sqrt(rng:NextNumber())
		decor(arena, k[1], x + math.cos(a) * d, z + math.sin(a) * d, nil, rng:NextNumber(k[2], k[3]), k[4])
	end
end

-- Places each vignette once in a free meadow spot (radius 55-185 from the centre).
local function vignettes(arena: Arena, list: { Vignette })
	for _, build in ipairs(list) do
		for _ = 1, 30 do
			local a, r = rng:NextNumber(0, TAU), rng:NextNumber(55, 185)
			local x, z = math.cos(a) * r, math.sin(a) * r
			if isFree(arena, x, z, 6, 2.5, 3) then
				build(arena, x, z)
				keepout(arena, x, z, 5)
				break
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- FOREST: a mossy clearing in the woods (the main map).
--
--   centre      open clearing where two dirt paths cross (spawn), a little low decor
--   north       the paths' north arm runs through a RUINED ARCH with walls and pillars
--   west        a SHRINE with the slate-blue crown banner and two torches
--   east        a ring of STANDING STONES
--   south-west  a WOODCUTTER CAMP: fence, log pile, crates, barrels, lantern post
--   outer ring  groves (pine / round trees with ferns and mushrooms in their shade), a
--               reed pond (north-west), boulder outcrops, an old foundation, fallen logs
--   border      broken split-rail fence, then a dense tree line (low on the south side)
------------------------------------------------------------------------------------------

local FOREST_ROUND: { Pal } = {
	{ Leaves = P.moss_700, Leaves2 = P.moss_600 },
	{ Leaves = mix(P.moss_700, P.moss_600, 0.5), Leaves2 = P.moss_500 },
	{ Leaves = P.moss_600, Leaves2 = mix(P.moss_500, P.moss_400, 0.5) },
}
local FOREST_PINE: { Pal } = {
	{ Needles = P.moss_800, Needles2 = P.moss_700 },
	{ Needles = P.moss_900, Needles2 = P.moss_800 },
	{ Needles = mix(P.moss_800, P.slate_700, 0.2), Needles2 = P.moss_700 },
}
local FLOWER_TONES: { Pal } = { { Bloom = P.ivory_100 }, { Bloom = P.ivory_100 }, { Bloom = P.gold_300 } }

local SMALL_DECOR = {
	{ "GrassTuft", 1.0, 1.6 },
	{ "GrassTuft", 1.0, 1.6 },
	{ "GrassTuft", 1.0, 1.6 },
	{ "Fern", 0.9, 1.3 },
	{ "Flowers", 1.0, 1.4, FLOWER_TONES[1] },
	{ "Rock_Small", 0.7, 1.2 },
}
local SHADE_DECOR = {
	{ "Fern", 1.0, 1.5 },
	{ "Fern", 0.9, 1.3 },
	{ "Mushroom", 0.9, 1.3 },
	{ "GrassTuft", 1.0, 1.4 },
}

local function grove(arena: Arena, cx: number, cz: number, spots: { { any } })
	for _, t in ipairs(spots) do
		local kind = t[1]
		local pal = (kind == "Tree_Round") and pick(FOREST_ROUND) or pick(FOREST_PINE)
		tree(arena, kind, cx + t[2], cz + t[3], t[4], pal)
	end
	scatter(arena, cx, cz, 16, 3, SHADE_DECOR, 1)
	scatter(arena, cx, cz, 20, 1, { { "Bush", 1.0, 1.4 } }, 1.5)
end

local function outcrop(arena: Arena, x: number, z: number, big: number, medium: { number }?)
	boulder(arena, x, z, big)
	if medium then
		boulder(arena, x + medium[1], z + medium[2], medium[3])
	end
	scatter(arena, x, z, big * 5, 3, { { "Rock_Small", 0.8, 1.4 }, { "GrassTuft", 1, 1.5 }, { "Fern", 0.9, 1.2 } }, 0.6)
end

local function forestPond(arena: Arena, x: number, z: number, r: number)
	local m = arena.Decor
	disc(m, "PondBank", W(arena, x, z, 0.08), r + 2.6, mix(P.dirt_600, P.moss_600, 0.35))
	disc(m, "PondBed", W(arena, x, z, 0.12), r + 0.6, P.slate_700)
	local water = disc(m, "Water", W(arena, x, z, 0.2), r, mix(P.slate_500, P.moss_500, 0.25))
	water.Transparency = 0.12
	water.Reflectance = 0.06
	for k = 1, 5 do
		local a, d = k * 1.3 + jitter(0.3), rng:NextNumber(3, r - 2)
		disc(m, "LilyPad", W(arena, x + math.cos(a) * d, z + math.sin(a) * d, 0.23), rng:NextNumber(0.6, 1.0), P.moss_400, 0.03)
	end
	-- reeds on the north-west side, rocks on the far rim
	for k = 1, 9 do
		local a = math.rad(200) + k * 0.13 + jitter(0.05)
		local d = r + jitter(0.8)
		local hgt = rng:NextNumber(2.2, 3.4)
		local px, pz = x + math.cos(a) * d, z + math.sin(a) * d
		deco(m, { Name = "Reed", Size = Vector3.new(0.18, hgt, 0.18), CFrame = CFrame.new(W(arena, px, pz, hgt / 2)) * CFrame.Angles(jitter(0.12), 0, jitter(0.12)), Color = P.moss_400 })
		if k % 2 == 0 then
			deco(m, { Name = "Cattail", Size = Vector3.new(0.32, 0.7, 0.32), CFrame = CFrame.new(W(arena, px, pz, hgt + 0.2)), Color = P.wood_600 })
		end
	end
	circleCollider(arena, W(arena, x, z).X, W(arena, x, z).Z, r, 4)
	keepout(arena, x, z, r + 3)
	boulder(arena, x + (r + 1.6) * 0.71, z + (r + 1.6) * 0.71, 0.9)
	boulder(arena, x + r + 1.8, z - 3, 0.85)
	scatter(arena, x, z, r + 8, 4, { { "GrassTuft", 1.1, 1.6 }, { "Fern", 1, 1.3 }, { "Flowers", 1, 1.3 } }, 0.5)
end

-- Standing stone (part-built: chunky leaning slab with a moss cap) + circle collider.
local function standingStone(arena: Arena, x: number, z: number, hgt: number, faceYaw: number)
	local cf = CFrame.new(W(arena, x, z, hgt / 2 - 0.3)) * CFrame.Angles(0, faceYaw, 0) * CFrame.Angles(math.rad(jitter(5)), 0, math.rad(jitter(6)))
	local m = Instance.new("Model")
	m.Name = "StandingStone"
	deco(m, { Name = "Stone", Size = Vector3.new(2.3, hgt, 1.3), CFrame = cf, Color = mix(P.stone_500, P.stone_600, rng:NextNumber(0, 0.6)), CastShadow = true })
	deco(m, { Name = "Cap", Size = Vector3.new(1.9, 0.5, 1.15), CFrame = cf * CFrame.new(0, hgt / 2 + 0.05, 0) * CFrame.Angles(0, 0, math.rad(jitter(10))), Color = P.stone_400, CastShadow = false })
	deco(m, { Name = "Moss", Size = Vector3.new(2.36, hgt * 0.35, 1.36), CFrame = cf * CFrame.new(0, -hgt * 0.3, 0), Color = P.moss_600 })
	tag(m)
	m.Parent = arena.Model
	local wp = W(arena, x, z)
	circleCollider(arena, wp.X, wp.Z, 1.1, hgt)
end

local function buildForest(arena: Arena)
	local c, h = arena.Center, arena.Half
	local m = arena.Model

	-- ground: deeper meadow outside, a bright sunny meadow inside, big soft patches in two tones
	local base = mix(P.meadow_500, P.meadow_400, 0.3)
	deco(m, { Name = "ForestFloor", Size = Vector3.new(h * 2 + 360, 2, h * 2 + 360), CFrame = CFrame.new(c - Vector3.new(0, 1.08, 0)), Color = mix(P.meadow_600, P.meadow_700, 0.5), CanCollide = true, CanQuery = true })
	deco(m, { Name = "Floor", Size = Vector3.new(h * 2 + 20, 1, h * 2 + 20), CFrame = CFrame.new(c - Vector3.new(0, 0.5, 0)), Color = base, CanCollide = true, CanQuery = true })
	local darker, lighter, warm = mix(P.meadow_600, P.meadow_500, 0.3), mix(P.meadow_400, P.meadow_300, 0.45), mix(P.meadow_400, P.dirt_300, 0.3)
	for _, pt in ipairs({
		{ -150, -150, 26, darker }, { 120, -165, 22, darker }, { -170, 60, 24, darker }, { 160, 120, 26, darker },
		{ 30, -120, 20, darker }, { -60, 150, 22, darker }, { -110, -40, 18, darker },
		{ -80, 90, 22, lighter }, { 90, 70, 24, lighter }, { -40, -90, 22, lighter }, { 70, -80, 18, lighter },
		{ 140, -110, 18, lighter }, { -140, 120, 20, lighter }, { 0, 140, 24, lighter }, { -175, -90, 20, lighter },
		{ 120, 175, 16, warm }, { 175, 10, 18, warm },
	}) do
		patch(arena, pt[1], pt[2], pt[3], pt[4], 0.02)
	end

	-- the clearing: worn lighter grass around the crossing (low, almost no decoration)
	patch(arena, 0, 0, 24, mix(P.meadow_400, P.meadow_300, 0.4), 0.05)
	patch(arena, 3, 2, 13, mix(P.meadow_300, P.dirt_300, 0.35), 0.07)

	-- paths: west-east and south-north, crossing in the clearing
	local core, edge = P.dirt_400, mix(P.dirt_400, base, 0.55)
	dirtPath(arena, {
		Vector2.new(-262, 30), Vector2.new(-205, 16), Vector2.new(-145, 30), Vector2.new(-88, 14),
		Vector2.new(-40, 8), Vector2.new(0, 0), Vector2.new(42, -9), Vector2.new(92, -3),
		Vector2.new(142, -22), Vector2.new(200, -12), Vector2.new(262, -22),
	}, 7, core, edge, 0.12)
	dirtPath(arena, {
		Vector2.new(-24, 262), Vector2.new(-16, 192), Vector2.new(-30, 132), Vector2.new(-10, 82),
		Vector2.new(-6, 40), Vector2.new(0, 0), Vector2.new(9, -32), Vector2.new(14, -62),
		Vector2.new(6, -102), Vector2.new(-16, -150), Vector2.new(-8, -200), Vector2.new(-14, -262),
	}, 6, core, edge, 0.16)
	-- stepping stones and pebbles along the paths
	for _, sp in ipairs({ { 22, -4.5 }, { -20, 4 } }) do
		local cf = CFrame.new(W(arena, sp[1], sp[2], -0.42)) * randomYaw()
		prop(arena.Decor, "Rock_Slab", cf, rng:NextNumber(0.8, 1.05), { Slab = mix(P.stone_400, P.stone_300, 0.3) }, { shadow = false })
	end

	boundaryWalls(arena)

	-- clearing decor (low, sparse, off the paths)
	scatter(arena, 0, 0, 34, 26, { { "GrassTuft", 1.0, 1.6 }, { "GrassTuft", 1.0, 1.6 }, { "GrassTuft", 1.2, 1.8 }, { "Flowers", 1.0, 1.4, FLOWER_TONES[1] }, { "Rock_Small", 0.7, 1.1 } }, 1.2, 0.4)
	scatter(arena, 0, 0, 40, 8, { { "Fern", 1, 1.4 }, { "Flowers", 1.1, 1.5, FLOWER_TONES[3] }, { "Flowers", 1.1, 1.5, FLOWER_TONES[1] } }, 1.5, 0.5)

	--------------------------------------------------------------------------------------
	-- LANDMARKS (mid ring)

	-- 1. Ruined arch over the north path, walls running off both sides, broken columns
	local arch = obstacle(arena, "Ruin_Arch", 14, -62, 0, 1, nil, { occluder = true })
	arch.Name = "Landmark_Arch"
	obstacle(arena, "Ruin_Wall", 23.4, -62.4, 0, 1, nil, { occluder = true })
	obstacle(arena, "Ruin_WallLow", 4.2, -61.6, 180, 1)
	obstacle(arena, "Pillar", 1, -75, 30, 1.1, nil, { occluder = true })
	obstacle(arena, "Pillar", 29, -50, 200, 1.0, nil, { occluder = true })
	obstacle(arena, "Ruin_Block", 25, -73, 35, 1.0)
	decor(arena, "Ruin_Block", 34.5, -58, 70, 0.7, nil, { shadow = true })
	keepout(arena, 14, -62, 13)
	scatter(arena, 14, -62, 22, 8, { { "Rock_Small", 0.8, 1.3 }, { "Fern", 1, 1.4 }, { "GrassTuft", 1, 1.5 }, { "Flowers", 1, 1.3, FLOWER_TONES[1] } }, 0.6)

	-- 2. Shrine: standing stone with a gold sigil facing the clearing, the slate-blue crown
	--    banner behind it, a torch either side, a small paved apron
	-- (facing south so the run camera sees the sigil and the crown)
	obstacle(arena, "Shrine", -70, -32, 180, 1.1, nil, { occluder = true })
	obstacle(arena, "Banner", -70, -36.4, 180, 1.1, nil, { occluder = true })
	for _, dx in ipairs({ -4.8, 4.8 }) do
		obstacle(arena, "Torch", -70 + dx, -31, 0, 1.05, TORCH_FLAME)
		kitLight(arena, "Torch", -70 + dx, -31, 0, 1.05, 16, 1.8, TORCH_FIRE)
	end
	for _, sp in ipairs({ { -70, -27.4 }, { -66.6, -26.6 }, { -73.3, -26.9 } }) do
		prop(arena.Decor, "Rock_Slab", CFrame.new(W(arena, sp[1], sp[2], -0.45)) * yawCF(jitter(14)), 0.95, nil, { shadow = false })
	end
	boulder(arena, -79, -22, 1.1)
	boulder(arena, -78, -44, 0.9)
	keepout(arena, -70, -32, 9)
	scatter(arena, -70, -32, 16, 7, { { "Flowers", 1.1, 1.4, FLOWER_TONES[1] }, { "Flowers", 1.1, 1.4, FLOWER_TONES[3] }, { "Fern", 1, 1.4 }, { "GrassTuft", 1, 1.5 } }, 0.5)

	-- 3. Ring of standing stones (east), a flat altar stone in the middle
	local ringX, ringZ = 84, 26
	for k = 0, 6 do
		local a = k / 7 * TAU + 0.3
		standingStone(arena, ringX + math.cos(a) * 8.5, ringZ + math.sin(a) * 8.5, rng:NextNumber(3.6, 5.4), -a + math.pi / 2)
	end
	prop(arena.Decor, "Rock_Slab", CFrame.new(W(arena, ringX, ringZ, -0.3)) * yawCF(20), 1.2, nil, { shadow = false })
	keepout(arena, ringX, ringZ, 11)
	scatter(arena, ringX, ringZ, 14, 6, { { "GrassTuft", 1.1, 1.6 }, { "Flowers", 1, 1.3, FLOWER_TONES[1] }, { "Rock_Small", 0.8, 1.1 } }, 0.5)

	-- 4. Woodcutter camp (south-west, all low): fence, log pile, chopping stump, crates,
	--    barrels and a lantern post
	local kx, kz = -56, 52
	obstacle(arena, "Fence_Section", kx - 6, kz + 8, 0, 1)
	obstacle(arena, "Fence_Section", kx + 2.2, kz + 8.3, 3, 1)
	obstacle(arena, "Fence_Section", kx - 10.2, kz + 3.8, 90, 1)
	obstacle(arena, "Log", kx + 6, kz - 6, 0, 1.1)
	prop(arena.Decor, "Log", CFrame.new(W(arena, kx + 6.3, kz - 6.1, 1.25)) * yawCF(4), 1.0)
	obstacle(arena, "Stump", kx - 1, kz - 3, 0, 1.15)
	obstacle(arena, "Crate", kx - 6, kz - 2, 90, 1.0)
	decor(arena, "Crate", kx - 6, kz - 0.1, 8, 1.0, nil, { shadow = true })
	prop(arena.Decor, "Crate", CFrame.new(W(arena, kx - 6, kz - 1.1, 2)) * yawCF(30), 0.85)
	obstacle(arena, "Barrel", kx - 8.6, kz - 5.6, 0, 1.05)
	obstacle(arena, "Barrel", kx - 7.4, kz - 7.6, 40, 1.0)
	obstacle(arena, "Lantern_Post", kx + 3, kz + 3, 0, 1.0)
	kitLight(arena, "Lantern_Post", kx + 3, kz + 3, 0, 1.0, 14, 1.2, rgb(255, 196, 120))
	patch(arena, kx - 2, kz - 1, 9, mix(P.dirt_400, P.moss_500, 0.55), 0.05)
	keepout(arena, kx - 2, kz, 13)
	scatter(arena, kx - 2, kz, 18, 6, { { "GrassTuft", 1, 1.5 }, { "Fern", 1, 1.3 }, { "Rock_Small", 0.7, 1.0 } }, 0.5)

	--------------------------------------------------------------------------------------
	-- OUTER RING: pond, groves, outcrops, an old foundation, logs and stumps

	forestPond(arena, -118, -108, 12)

	grove(arena, -48, -150, { { "Tree_Pine", 0, 0, 1.25 }, { "Tree_Round", 9, 6, 1.15 }, { "Tree_Pine", -8, 7, 1.05 }, { "Tree_PineTall", 4, -10, 1.0 }, { "Tree_Round", -12, -6, 1.0 } })
	grove(arena, 112, -122, { { "Tree_Round", 0, 0, 1.3 }, { "Tree_Pine", 10, 5, 1.15 }, { "Tree_Round", -9, 8, 1.0 }, { "Tree_PineTall", 6, -9, 1.05 }, { "Tree_Pine", -7, -8, 0.95 } })
	grove(arena, 150, 72, { { "Tree_Round", 0, 0, 1.25 }, { "Tree_Round", 11, -5, 1.05 }, { "Tree_Pine", -6, 9, 1.0 }, { "Tree_Pine", 8, 10, 1.1 }, { "Tree_Round", -10, -7, 0.95 } })
	grove(arena, -152, -14, { { "Tree_Pine", 0, 0, 1.2 }, { "Tree_PineTall", -8, 8, 1.0 }, { "Tree_Round", 9, 4, 1.1 }, { "Tree_Pine", 2, -10, 1.0 } })
	grove(arena, 112, 146, { { "Tree_Round", 0, 0, 1.0 }, { "Tree_Round", 10, 6, 0.9 }, { "Tree_Round", -6, 9, 0.85 } })
	grove(arena, -122, 132, { { "Tree_Round", 0, 0, 1.05 }, { "Tree_Pine", 9, -5, 0.95 }, { "Tree_Round", -8, 7, 0.9 } })

	outcrop(arena, 62, -132, 1.5, { 5.5, 3, 1.0 })
	outcrop(arena, 166, -38, 1.45, { -4, 5, 1.0 })
	outcrop(arena, -172, 84, 1.5, { 5, -4, 1.0 })
	outcrop(arena, 42, 152, 1.4, { -5, -3, 0.95 })
	outcrop(arena, -64, -112, 1.4, { 5, 4, 0.95 })

	-- old foundation (north-east of the north path)
	obstacle(arena, "Ruin_Wall", 40, -172, 0, 1, nil, { occluder = true })
	obstacle(arena, "Ruin_Wall", 48.7, -172.2, 0, 1, nil, { occluder = true })
	obstacle(arena, "Ruin_Wall", 53.4, -166.6, 90, 1, nil, { occluder = true })
	obstacle(arena, "Ruin_WallLow", 53.6, -158, 90, 1)
	obstacle(arena, "Ruin_WallLow", 33.5, -164, 90, 1)
	obstacle(arena, "Pillar", 44, -156, 0, 1.0, nil, { occluder = true })
	obstacle(arena, "Ruin_Block", 37, -151, 20, 1.0)
	keepout(arena, 45, -164, 12)
	scatter(arena, 45, -164, 18, 6, { { "Rock_Small", 0.8, 1.3 }, { "Fern", 1, 1.4 }, { "GrassTuft", 1, 1.5 }, { "Mushroom", 1, 1.2 } }, 0.6)

	-- fallen logs and stumps
	obstacle(arena, "Log", -96, 100, 0, 1.15)
	obstacle(arena, "Log", 132, -62, 90, 1.1)
	obstacle(arena, "Log", -28, 134, 4, 1.05)
	for _, st in ipairs({ { -36, -136 }, { 128, -108 }, { 140, 86 }, { -142, -2 } }) do
		obstacle(arena, "Stump", st[1], st[2], rng:NextNumber(0, 360), rng:NextNumber(1.0, 1.25))
	end

	-- corners: a couple of trees and a boulder each
	for _, q in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local south = q[2] == 1
		local bx, bz = q[1] * 172, q[2] * 172
		boulder(arena, bx + q[1] * 6, bz - q[2] * 10, 1.35)
		tree(arena, south and "Tree_Round" or "Tree_Pine", bx - q[1] * 4, bz + q[2] * 8, south and 0.9 or 1.2, south and pick(FOREST_ROUND) or pick(FOREST_PINE))
		tree(arena, south and "Tree_Round" or "Tree_PineTall", bx + q[1] * 12, bz + q[2] * 2, south and 0.85 or 1.05, south and pick(FOREST_ROUND) or pick(FOREST_PINE))
		scatter(arena, bx, bz, 18, 3, SHADE_DECOR, 1)
	end

	-- meadow scatter: grass tufts, flowers and pebbles everywhere else (sparse)
	for _ = 1, 7 do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(44, 190)
		scatter(arena, math.cos(a) * r, math.sin(a) * r, 6, 2, SMALL_DECOR, 1.5, 0.5)
	end

	-- BORDER: mossy rock cliffs on three sides, a low rocky rim and the broken fence on the
	-- camera side, then the tree line (on the cliff tops)
	vignettes(arena, {
		function(a, x, z) campfire(a, x, z) end,
		function(a, x, z) ring(a, x, z, "Mushroom", 7, 3.2, 1.2, 1.7) end,
		function(a, x, z) supplies(a, x, z) end,
		function(a, x, z) cluster(a, x, z, { { "Mushroom", 1.1, 1.6 }, { "Fern", 1.3, 1.8 }, { "Stump", 0.8, 1.0 } }, 5, 3.5) end,
		function(a, x, z) decor(a, "Banner", x, z, 180, 1.0); cluster(a, x, z, { { "Rock_Small", 0.8, 1.2 }, { "Flowers", 1.2, 1.5 } }, 3, 3) end,
		function(a, x, z) ring(a, x, z, "Mushroom", 6, 2.6, 1.0, 1.4) end,
		function(a, x, z) cluster(a, x, z, { { "Crystal", 0.8, 1.2 }, { "Rock_Small", 0.8, 1.2 } }, 4, 2.5) end,
	})
	cliffs(arena, {
		Rock = { mix(P.stone_500, P.moss_700, 0.12), P.stone_600, mix(P.stone_500, P.stone_400, 0.5) },
		Cap = mix(P.moss_600, P.meadow_600, 0.4),
		Height = { 13, 21 },
		South = { 2.6, 4.2 },
		Face = { "Rock", { Stone = mix(P.stone_500, P.moss_700, 0.12), Stone2 = P.stone_600, Moss = mix(P.moss_600, P.meadow_600, 0.4) } },
		Foot = { { "Fern", 1.6, 2.2 }, { "Rock", 1.2, 1.8 }, { "Mushroom", 1.4, 1.8 } },
	})
	brokenFence(arena, 1.3, nil, 22)
	treeLine(arena, {
		{ "Tree_PineTall", 1.3, 1.8, FOREST_PINE[1] },
		{ "Tree_PineTall", 1.25, 1.7, FOREST_PINE[2] },
		{ "Tree_Pine", 1.35, 1.8, FOREST_PINE[3] },
		{ "Tree_Round", 1.35, 1.75, FOREST_ROUND[1] },
	}, {
		{ "Bush", 1.4, 2.0, nil },
		{ "Tree_Round", 0.75, 0.9, FOREST_ROUND[2] },
	}, 26, mix(P.meadow_700, P.meadow_800, 0.6))
end

------------------------------------------------------------------------------------------
-- RUINS: a sunlit, overgrown ruined courtyard (unlocked by reaching stage 2; every stage run visits it).
--
--   centre      a cracked paved plaza (grass in the gaps) with a compass inlay (spawn)
--   avenues     four slab avenues to the walls; broken columns flank their mouths
--   mid ring    four ruin vignettes on the diagonals: an arch (NE), a wall corner (NW),
--               low walls with a crystal outcrop (SE), a shrine with torches (SW)
--   outer ring  roofless buildings in the quadrants, a dry pool basin, a collapsed tower,
--               colonnades along the avenues, boulders, crystal clusters, a few trees
--   border      broken crenellated wall (low on the south side), corner towers, pines
------------------------------------------------------------------------------------------

local RUIN_PAL: Pal = { Stone = mix(P.stone_400, P.ivory_500, 0.25), Stone2 = mix(P.stone_300, P.ivory_400, 0.25), Stone3 = mix(P.stone_500, P.ivory_500, 0.2), Moss = P.moss_400 }
local PILLAR_PAL: Pal = { Base = mix(P.stone_500, P.ivory_500, 0.2), Shaft = mix(P.stone_300, P.ivory_300, 0.3), Shaft2 = mix(P.stone_400, P.ivory_400, 0.3), Moss = P.moss_400 }
local RUIN_TREES: { Pal } = {
	{ Leaves = P.moss_600, Leaves2 = P.moss_500 },
	{ Leaves = mix(P.moss_600, P.gold_600, 0.25), Leaves2 = mix(P.moss_500, P.gold_500, 0.3) },
}

local function ruinWallRun(arena: Arena, x0: number, z0: number, horizontal: boolean, pieces: { string }, s: number)
	local pos = 0
	for _, name in ipairs(pieces) do
		local len = (name == "Ruin_WallLow" and 6 or 8) * s
		local cx = horizontal and (x0 + pos + len / 2) or x0
		local cz = horizontal and z0 or (z0 + pos + len / 2)
		obstacle(arena, name, cx, cz, horizontal and pick({ 0, 180 }) or pick({ 90, -90 }), s, RUIN_PAL, { occluder = name == "Ruin_Wall" })
		pos += len - 0.3
	end
end

local function crystalOutcrop(arena: Arena, x: number, z: number, s: number, light: boolean)
	obstacle(arena, "CrystalCluster", x, z, rng:NextNumber(0, 360), s)
	decor(arena, "CrystalCluster", x + 2.6 * s, z + 1.2 * s, nil, s * 0.5)
	if light then
		local cf = CFrame.new(W(arena, x, z))
		pointLight(arena.Model, (kitLightPoint("CrystalCluster", cf, s) or cf.Position) + Vector3.new(0, 1.5, 0), 12, 0.8, P.fx_arcane, false)
		arena.Lights += 1
	end
	scatter(arena, x, z, 6 * s, 2, { { "Rock_Small", 0.7, 1.1 }, { "GrassTuft", 1, 1.4 } }, 0.4)
end

local function collapsedTower(arena: Arena, x: number, z: number, r: number)
	local m = Instance.new("Model")
	m.Name = "CollapsedTower"
	local n = 10
	for k = 0, n - 1 do
		local a = k / n * TAU
		local hgt = (k % 3 == 0) and rng:NextNumber(1.2, 2) or rng:NextNumber(3, 6.5)
		local p = W(arena, x + math.cos(a) * (r - 1), z + math.sin(a) * (r - 1), hgt / 2)
		deco(m, { Name = "Stone", Size = Vector3.new(2.2, hgt, r * TAU / n + 0.4), CFrame = CFrame.new(p) * CFrame.Angles(0, -a, 0), Color = mix(RUIN_PAL.Stone, RUIN_PAL.Stone3, rng:NextNumber(0, 1)), CastShadow = true })
	end
	disc(m, "Rubble", W(arena, x, z, 0.4), r - 1.6, RUIN_PAL.Stone3, 0.8)
	deco(m, { Name = "Moss", Size = Vector3.new(2.3, 1.2, r * 1.6), CFrame = CFrame.new(W(arena, x - r + 1, z, 0.6)), Color = P.moss_500 })
	tag(m)
	m.Parent = arena.Model
	local wp = W(arena, x, z)
	circleCollider(arena, wp.X, wp.Z, r, 6)
	decor(arena, "Ruin_Block", x + r + 2, z + 1.5, nil, 0.9, RUIN_PAL, { shadow = true })
	keepout(arena, x, z, r + 4)
end

local function poolBasin(arena: Arena, x: number, z: number, sx: number, sz: number)
	local m = Instance.new("Model")
	m.Name = "PoolBasin"
	local rim = RUIN_PAL.Stone2
	for _, e in ipairs({ { 0, -sz / 2, sx, 1.4 }, { 0, sz / 2, sx, 1.4 }, { -sx / 2, 0, 1.4, sz }, { sx / 2, 0, 1.4, sz } }) do
		deco(m, { Name = "Rim", Size = Vector3.new(e[3], 1.4, e[4]), CFrame = CFrame.new(W(arena, x + e[1], z + e[2], 0.7)), Color = rim, CastShadow = true })
	end
	slab(m, "Water", W(arena, x, z, 0.75), sx - 1.4, sz - 1.4, 0, mix(P.slate_500, P.moss_500, 0.3))
	slab(m, "Lilies", W(arena, x - sx * 0.2, z + 1, 0.78), 2.4, 1.8, 0.4, P.moss_400, 0.03)
	m.Parent = arena.Model
	local wp = W(arena, x, z)
	boxCollider(arena, wp.X, wp.Z, sx, sz, 1.6)
	keepout(arena, x, z, math.max(sx, sz) / 2 + 3)
end

local function buildRuins(arena: Arena)
	local c, h = arena.Center, arena.Half
	local m = arena.Model
	arena.DecorDensity = 0.5 -- the ruin pieces carry the detail here; less ground clutter

	-- ground: bright grassy courtyard with stone-dust and deeper grass patches
	deco(m, { Name = "OuterGround", Size = Vector3.new(h * 2 + 360, 2, h * 2 + 360), CFrame = CFrame.new(c - Vector3.new(0, 1.08, 0)), Color = P.meadow_700, CanCollide = true, CanQuery = true })
	deco(m, { Name = "Floor", Size = Vector3.new(h * 2 + 20, 1, h * 2 + 20), CFrame = CFrame.new(c - Vector3.new(0, 0.5, 0)), Color = mix(P.meadow_500, P.meadow_600, 0.3), CanCollide = true, CanQuery = true })
	local dust, deep, sun = mix(P.meadow_400, P.pave_300, 0.4), mix(P.meadow_600, P.meadow_700, 0.4), mix(P.meadow_400, P.meadow_300, 0.4)
	for _, pt in ipairs({
		{ -120, -60, 24, dust }, { 110, 60, 22, dust }, { 60, -150, 20, dust }, { -70, 150, 20, dust },
		{ 150, -150, 22, deep }, { -160, -150, 24, deep }, { 165, 150, 20, deep }, { -150, 120, 22, deep },
		{ -60, -70, 18, sun }, { 70, 75, 20, sun }, { -170, 30, 18, sun }, { 160, -30, 18, sun },
		{ 40, 120, 18, deep }, { -110, 70, 16, dust }, { 100, -90, 16, deep }, { 0, -180, 18, sun },
	}) do
		patch(arena, pt[1], pt[2], pt[3], pt[4], 0.02)
	end

	-- plaza: cracked light paving in three stone tones, grass where slabs are missing
	local paveA, paveB, paveC = P.pave_300, P.pave_400, P.pave_200
	disc(arena.Decor, "PlazaBed", W(arena, 0, 0, 0.05), 31, mix(P.pave_500, P.meadow_500, 0.5))
	table.insert(arena.Bare, { X = 0, Z = 0, R = 32 })
	for ix = -5, 4 do
		for iz = -5, 4 do
			local x, z = ix * 6 + 3, iz * 6 + 3
			local d = math.sqrt(x * x + z * z)
			if d < 29 and (d < 9 or rng:NextNumber() > 0.14) then
				slab(arena.Decor, "Paving", W(arena, x + jitter(0.15), z + jitter(0.15), 0.12), 5.6, 5.6, math.rad(jitter(2)), pick({ paveA, paveA, paveB, paveC }), 0.12)
			end
		end
	end
	-- compass rose: slate disc, gold ring, a long N-S / E-W cross and short diagonals
	disc(arena.Decor, "Inlay", W(arena, 0, 0, 0.17), 5.4, mix(P.slate_500, P.stone_500, 0.5), 0.02)
	disc(arena.Decor, "InlayRing", W(arena, 0, 0, 0.2), 4.2, P.gold_600, 0.02)
	disc(arena.Decor, "InlayCore", W(arena, 0, 0, 0.23), 3.8, mix(P.slate_500, P.stone_500, 0.5), 0.02)
	for k = 0, 3 do
		slab(arena.Decor, "InlayRay", W(arena, 0, 0, 0.26 + k * 0.02), k < 2 and 0.7 or 0.45, k < 2 and 10 or 5.4, k * math.pi / 2 + (k >= 2 and math.pi / 4 or 0), P.gold_500, 0.02)
	end

	-- avenues: rows of slabs out to the walls (a few missing), keep decoration off them
	local slabA, slabB = P.pave_400, P.pave_300
	for _, axis in ipairs({ Vector2.new(0, -1), Vector2.new(1, 0), Vector2.new(-1, 0), Vector2.new(0, 1) }) do
		local d = 36
		local stop = axis.Y > 0 and 150 or h - 6 -- the camera-side avenue fades out earlier
		while d < stop do
			if rng:NextNumber() > 0.14 then
				local p = axis * (d + jitter(0.2))
				slab(arena.Decor, "AvenueSlab", W(arena, p.X, p.Y, 0.1), axis.X ~= 0 and 7.5 or 11, axis.X ~= 0 and 11 or 7.5, math.rad(jitter(1.5)), pick({ slabA, slabB }), 0.12)
			end
			d += 8
		end
		local a, b = axis * 30, axis * (h + 10)
		table.insert(arena.Paths, { A = Vector3.new(a.X, 0, a.Y), B = Vector3.new(b.X, 0, b.Y), W = 6.5 })
	end

	boundaryWalls(arena)

	-- grass, flowers and pebbles in the plaza gaps and around it
	scatter(arena, 0, 0, 36, 14, { { "GrassTuft", 1, 1.5 }, { "GrassTuft", 1, 1.5 }, { "Flowers", 1, 1.3, { Bloom = P.ivory_100 } }, { "Rock_Small", 0.7, 1 } }, 1.2)

	--------------------------------------------------------------------------------------
	-- MID RING

	-- broken columns flanking each avenue mouth, torches between them
	for i, axis in ipairs({ Vector2.new(0, -1), Vector2.new(1, 0), Vector2.new(-1, 0), Vector2.new(0, 1) }) do
		local side = Vector2.new(-axis.Y, axis.X)
		for _, sgn in ipairs({ -1, 1 }) do
			local p = axis * 47 + side * sgn * 10
			if (i + sgn) % 4 == 0 then
				obstacle(arena, "Ruin_Block", p.X, p.Y, rng:NextNumber(0, 360), 1.1, RUIN_PAL)
			else
				obstacle(arena, "Pillar", p.X, p.Y, rng:NextNumber(0, 360), 1.2, PILLAR_PAL, { occluder = true })
			end
		end
		local t = axis * 42 + side * 7.5
		obstacle(arena, "Torch", t.X, t.Y, 0, 1.1, TORCH_FLAME)
		kitLight(arena, "Torch", t.X, t.Y, 0, 1.1, 16, 1.8, TORCH_FIRE)
	end

	-- NE: arch with walls either side and a crystal accent
	obstacle(arena, "Ruin_Arch", 56, -56, 90, 1.1, RUIN_PAL, { occluder = true })
	obstacle(arena, "Ruin_Wall", 56, -66.4, 90, 1, RUIN_PAL, { occluder = true })
	obstacle(arena, "Ruin_WallLow", 56.2, -45.7, 90, 1, RUIN_PAL)
	crystalOutcrop(arena, 66, -48, 1.4, true)
	scatter(arena, 56, -56, 18, 8, { { "Rock_Small", 0.8, 1.2 }, { "Fern", 1, 1.3 }, { "GrassTuft", 1, 1.5 } }, 0.6)

	-- NW: wall corner with a fallen block and a boulder
	ruinWallRun(arena, -70, -60, true, { "Ruin_Wall", "Ruin_Wall" }, 1)
	ruinWallRun(arena, -70.6, -59.4, false, { "Ruin_WallLow" }, 1)
	obstacle(arena, "Ruin_Block", -58, -50, 15, 1.05, RUIN_PAL)
	boulder(arena, -76, -44, 1.35, { Stone = RUIN_PAL.Stone, Stone2 = RUIN_PAL.Stone3 })
	scatter(arena, -62, -54, 16, 8, { { "Rock_Small", 0.8, 1.2 }, { "Mushroom", 1, 1.2 }, { "Fern", 1, 1.3 } }, 0.6)

	-- SE: low walls (camera side) around a crystal outcrop
	ruinWallRun(arena, 50, 58, true, { "Ruin_WallLow", "Ruin_WallLow" }, 1)
	ruinWallRun(arena, 62, 62, false, { "Ruin_Wall" }, 1)
	crystalOutcrop(arena, 57, 68, 1.3, false)
	boulder(arena, 44, 72, 1.3, { Stone = RUIN_PAL.Stone, Stone2 = RUIN_PAL.Stone3 })
	scatter(arena, 56, 64, 16, 8, { { "GrassTuft", 1, 1.5 }, { "Flowers", 1, 1.3 }, { "Rock_Small", 0.8, 1.1 } }, 0.6)

	-- SW: shrine with two torches and a low wall behind
	obstacle(arena, "Shrine", -58, 56, 180, 1.1, nil, { occluder = true })
	obstacle(arena, "Ruin_WallLow", -66, 64, 0, 1, RUIN_PAL)
	obstacle(arena, "Ruin_Block", -48, 66, 60, 1.0, RUIN_PAL)
	boulder(arena, -70, 50, 1.15, { Stone = RUIN_PAL.Stone, Stone2 = RUIN_PAL.Stone3 })
	for _, o in ipairs({ { -62.5, 52.5 }, { -54.5, 60.5 } }) do
		obstacle(arena, "Torch", o[1], o[2], 0, 1.0, TORCH_FLAME)
	end
	kitLight(arena, "Torch", -62.5, 52.5, 0, 1.0, 15, 1.8, TORCH_FIRE)
	scatter(arena, -58, 58, 14, 8, { { "Flowers", 1, 1.4, { Bloom = P.ivory_100 } }, { "Flowers", 1, 1.4, { Bloom = P.gold_300 } }, { "GrassTuft", 1, 1.5 } }, 0.5)

	--------------------------------------------------------------------------------------
	-- OUTER RING

	-- roofless buildings (walls in L / U shapes), lower toward the camera side
	local function building(bx: number, bz: number, w: number, d: number, tall: boolean)
		local s = 1.25
		local main = tall and "Ruin_Wall" or "Ruin_WallLow"
		local unit = (tall and 8 or 6) * s - 0.3
		local nW = math.max(1, math.floor(w / unit + 0.5))
		local nD = math.max(1, math.floor(d / unit + 0.5))
		local back = {}
		for k = 1, nW do
			back[k] = (k == nW and tall) and "Ruin_WallLow" or main
		end
		ruinWallRun(arena, bx - w / 2, bz - d / 2, true, back, s)
		local sideRun = {}
		for k = 1, nD do
			sideRun[k] = k == 1 and main or "Ruin_WallLow"
		end
		ruinWallRun(arena, bx - w / 2 - 0.6, bz - d / 2 + 1.2, false, sideRun, s)
		slab(arena.Decor, "OldFloor", W(arena, bx, bz, 0.07), w - 2, d - 2, 0, mix(P.stone_400, P.moss_500, 0.45))
		obstacle(arena, "Pillar", bx + w / 2 - 2, bz + d / 2 - 2, rng:NextNumber(0, 360), 1.1, PILLAR_PAL, { occluder = true })
		obstacle(arena, "Ruin_Block", bx + w * 0.15, bz + d * 0.1, rng:NextNumber(0, 360), 1.0, RUIN_PAL)
		keepout(arena, bx, bz, math.max(w, d) / 2 + 3)
		scatter(arena, bx, bz, math.max(w, d) / 2 + 4, 5, { { "Rock_Small", 0.8, 1.3 }, { "Fern", 1, 1.4 }, { "GrassTuft", 1, 1.5 }, { "Mushroom", 1, 1.2 } }, 0.6)
	end
	building(112, -112, 22, 20, true)
	building(-118, -104, 22, 18, true)
	building(152, 30, 20, 12, true)
	building(-124, 118, 16, 12, false)

	poolBasin(arena, -56, -150, 18, 10)
	collapsedTower(arena, -152, -42, 6.6)

	-- colonnades along the avenues (pillars, some fallen as blocks)
	for _, axis in ipairs({ Vector2.new(0, -1), Vector2.new(1, 0), Vector2.new(-1, 0) }) do
		local side = Vector2.new(-axis.Y, axis.X)
		for d = 112, 182, 35 do
			for _, sgn in ipairs({ -1, 1 }) do
				local p = axis * d + side * sgn * 11
				local roll = rng:NextNumber()
				if roll < 0.5 then
					obstacle(arena, "Pillar", p.X, p.Y, rng:NextNumber(0, 360), rng:NextNumber(1.1, 1.3), PILLAR_PAL, { occluder = true })
				elseif roll < 0.75 then
					obstacle(arena, "Ruin_Block", p.X + side.X * sgn * 1.5, p.Y + side.Y * sgn * 1.5, rng:NextNumber(0, 360), 1.0, RUIN_PAL)
				end
			end
		end
	end

	-- crystal outcrops (restrained accents) and boulders
	crystalOutcrop(arena, 84, -160, 1.8, true)
	crystalOutcrop(arena, -170, 64, 1.7, true)
	crystalOutcrop(arena, 34, 170, 1.6, false)
	for _, b in ipairs({ { 170, -84, 1.4 }, { -96, -170, 1.3 }, { 80, 100, 1.2 }, { -170, -110, 1.35 }, { 40, -120, 1.2 }, { -80, 172, 1.3 }, { 176, 80, 1.3 }, { -40, 120, 1.15 }, { 120, -40, 1.3 } }) do
		boulder(arena, b[1], b[2], b[3], { Stone = RUIN_PAL.Stone, Stone2 = RUIN_PAL.Stone3 })
		scatter(arena, b[1], b[2], 7, 3, { { "Rock_Small", 0.8, 1.2 }, { "GrassTuft", 1, 1.5 } }, 0.5)
	end

	-- a few trees growing out of the ruins
	for _, t in ipairs({ { -96, -136, 1.25 }, { 140, -60, 1.15 }, { -150, 10, 1.2 }, { 96, 160, 0.95 }, { -100, 74, 1.05 }, { 70, -176, 1.15 }, { -30, -172, 1.1 }, { 176, 112, 1.0 }, { -176, 150, 0.95 }, { 150, -170, 1.1 } }) do
		tree(arena, "Tree_Round", t[1], t[2], t[3], pick(RUIN_TREES))
		scatter(arena, t[1], t[2], 9, 3, { { "Fern", 1, 1.4 }, { "Bush", 1, 1.3 } }, 1)
	end
	obstacle(arena, "Log", 130, 90, 0, 1.1)
	obstacle(arena, "Log", -178, -10, 90, 1.05)

	-- corners: corner towers on the far side, rubble on the camera side
	for _, q in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local south = q[2] == 1
		local bx, bz = q[1] * (h + 2), q[2] * (h + 2)
		if south then
			obstacle(arena, "Ruin_Block", q[1] * (h - 9), q[2] * (h - 6), rng:NextNumber(0, 360), 1.2, RUIN_PAL)
		else
			obstacle(arena, "Castle_Tower", bx, bz, 0, 1.5, nil, { occluder = true })
		end
		boulder(arena, q[1] * (h - 18), q[2] * (h - 10), 1.1, { Stone = RUIN_PAL.Stone, Stone2 = RUIN_PAL.Stone3 })
		scatter(arena, q[1] * (h - 18), q[2] * (h - 18), 14, 3, { { "GrassTuft", 1, 1.5 }, { "Fern", 1, 1.3 }, { "Rock_Small", 0.8, 1.2 } }, 0.8)
	end

	-- meadow scatter between the ruins
	for _ = 1, 8 do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(44, 190)
		scatter(arena, math.cos(a) * r, math.sin(a) * r, 6, 2, { { "GrassTuft", 1, 1.5 }, { "GrassTuft", 1, 1.5 }, { "Flowers", 1, 1.3, { Bloom = P.ivory_100 } }, { "Rock_Small", 0.7, 1.1 } }, 1.5, 0.3)
	end

	-- BORDER: a tall broken curtain wall of cut stone on three sides (merlons on top), a low
	-- broken wall on the camera side, then pines behind
	vignettes(arena, {
		function(a, x, z) campfire(a, x, z) end,
		function(a, x, z) supplies(a, x, z) end,
		function(a, x, z) cluster(a, x, z, { { "CrystalCluster", 0.8, 1.1 }, { "Crystal", 0.8, 1.2 }, { "Rock_Small", 0.8, 1.2 } }, 4, 3) end,
		function(a, x, z) decor(a, "Banner", x, z, 180, 1.0); cluster(a, x, z, { { "Ruin_Block", 0.5, 0.8 }, { "Flowers", 1.2, 1.5 } }, 3, 3) end,
		function(a, x, z) ring(a, x, z, "Mushroom", 6, 2.8, 1.0, 1.5) end,
		function(a, x, z) cluster(a, x, z, { { "Ruin_Block", 0.5, 0.8 }, { "Rock_Small", 0.8, 1.2 }, { "Fern", 1.2, 1.6 } }, 5, 4) end,
	})
	cliffs(arena, {
		Rock = { RUIN_PAL.Stone, RUIN_PAL.Stone3, mix(RUIN_PAL.Stone, RUIN_PAL.Stone2, 0.5) },
		Cap = mix(RUIN_PAL.Stone2, P.moss_400, 0.35),
		Height = { 9, 15 },
		South = { 2.4, 3.6 },
		Masonry = true,
		Foot = { { "Ruin_Block", 1.0, 1.4 }, { "Rock", 1.2, 1.6, { Stone = RUIN_PAL.Stone, Stone2 = RUIN_PAL.Stone3 } } },
	})
	treeLine(arena, {
		{ "Tree_PineTall", 1.1, 1.5, { Needles = P.moss_800, Needles2 = P.moss_700 } },
		{ "Tree_Pine", 1.2, 1.6, { Needles = P.moss_900, Needles2 = P.moss_800 } },
		{ "Tree_Round", 1.1, 1.4, RUIN_TREES[1] },
	}, {
		{ "Bush", 1.4, 2.0, nil },
		{ "Tree_Round", 0.75, 0.9, RUIN_TREES[2] },
	}, 37, mix(P.meadow_700, P.meadow_800, 0.6))
end

------------------------------------------------------------------------------------------
-- BIOME TOOLKIT (Swamp, Snow, Desert, Lava): the same rules as the forest (designed
-- layout, fixed seed, nothing collidable in the clearing, tall things in groves and
-- outside the boundary, low south side, occluder tags, one collider per obstacle) plus
-- the biome's floor HAZARDS: fixed pools listed in arena.Hazards for BiomeHazards (the
-- server decides slow / slip / burn; the pool meshes are the telegraph).
------------------------------------------------------------------------------------------

-- Outer ground + the play floor (both collide and are raycast-able, like the forest's).
local function biomeGround(arena: Arena, outer: Color3, floor: Color3)
	local c, h = arena.Center, arena.Half
	deco(arena.Model, { Name = "OuterGround", Size = Vector3.new(h * 2 + 360, 2, h * 2 + 360), CFrame = CFrame.new(c - Vector3.new(0, 1.08, 0)), Color = outer, CanCollide = true, CanQuery = true })
	deco(arena.Model, { Name = "Floor", Size = Vector3.new(h * 2 + 20, 1, h * 2 + 20), CFrame = CFrame.new(c - Vector3.new(0, 0.5, 0)), Color = floor, CanCollide = true, CanQuery = true })
end

local function groundPatches(arena: Arena, list: { { any } })
	for _, pt in ipairs(list) do
		patch(arena, pt[1], pt[2], pt[3], pt[4], 0.02)
	end
end

-- A boulder-like obstacle of any kit rock (counted as a rock).
local function stone(arena: Arena, name: string, x: number, z: number, s: number, palette: Pal?, opts: PropOpts?): Model
	arena.Rocks += 1
	return obstacle(arena, name, x, z, rng:NextNumber(0, 360), s, palette, opts)
end

-- Trees of a grove: { {kit, dx, dz, scale, palette?} } around (cx, cz), shade decor under them.
local function kitGrove(arena: Arena, cx: number, cz: number, spots: { { any } }, shade: { { any } }?, extra: { any }?)
	for _, t in ipairs(spots) do
		tree(arena, t[1], cx + t[2], cz + t[3], t[4], t[5])
	end
	if shade then
		scatter(arena, cx, cz, 16, 3, shade, 1)
	end
	if extra then
		scatter(arena, cx, cz, 20, 1, { extra }, 1.5)
	end
end

-- Decoration around a ring (pool rims, ponds): n pieces between radius r0 and r1.
local function rimDecor(arena: Arena, x: number, z: number, r0: number, r1: number, n: number, kinds: { { any } })
	local a0 = rng:NextNumber(0, TAU)
	for k = 1, n do
		local a = a0 + k / n * TAU + jitter(0.35)
		local d = rng:NextNumber(r0, r1)
		local kind = pick(kinds)
		decor(arena, kind[1], x + math.cos(a) * d, z + math.sin(a) * d, nil, rng:NextNumber(kind[2], kind[3]) * (CLUTTER_SCALE[kind[1]] or 1), kind[4])
	end
end

-- Hazard pools: kit mesh (hazard radius from the catalog note, at scale 1) per kind.
local HAZARD_KIT: { [string]: { Model: string, Radius: number } } = {
	Mud = { Model = "Mud_Pool", Radius = 3.6 },
	Quicksand = { Model = "Quicksand", Radius = 3.6 },
	Ice = { Model = "Frozen_Pond", Radius = 4.4 },
	Lava = { Model = "Lava_Pool", Radius = 3.6 },
}
local HAZARD_GLOW_TAG = "SwarmHazardGlow" -- the client (TerrainFx) makes these breathe

--[[
	A hazard pool of `kind` at (x, z) (arena-relative), scale s: the kit mesh in the arena
	model (not Decor, so loot / portal decor clearing never removes it) and its record in
	arena.Hazards. Never in the spawn clearing (+10 studs); warns when it touches a path.
]]
local function hazardPool(arena: Arena, kind: string, x: number, z: number, s: number, yawDeg: number, palette: Pal?): Model?
	local kit = HAZARD_KIT[kind]
	local r = kit.Radius * s
	if math.sqrt(x * x + z * z) - r < arena.Clear + 10 then
		warn(string.format("[MapBuilder] %s pool at (%.0f, %.0f) skipped: too close to the spawn", kind, x, z))
		return nil
	end
	if pathDistance(arena, x, z) < r then
		warn(string.format("[MapBuilder] %s pool at (%.0f, %.0f) touches a path", kind, x, z))
	end
	local pos = W(arena, x, z)
	local model = prop(arena.Model, kit.Model, CFrame.new(pos) * yawCF(yawDeg), s, palette, { shadow = false })
	model.Name = "Hazard_" .. kind
	model:SetAttribute("HazardKind", kind)
	model:SetAttribute("HazardRadius", r)
	table.insert(arena.Hazards, { Kind = kind, Pos = pos, Radius = r })
	return model
end

-- Lava pool: the hazard, a warning glow ring just outside its burn radius and (some
-- of them) a warm light.
local function lavaPool(arena: Arena, x: number, z: number, s: number, yawDeg: number, lit: boolean)
	local model = hazardPool(arena, "Lava", x, z, s, yawDeg)
	if not model then
		return
	end
	local r = HAZARD_KIT.Lava.Radius * s
	local glow = disc(arena.Model, "HazardGlow", W(arena, x, z, 0.05), r + 1.1, P.lava_500, 0.06)
	glow.Material = NEON
	glow.Transparency = 0.5
	CollectionService:AddTag(glow, HAZARD_GLOW_TAG)
	if lit then
		local cf = CFrame.new(W(arena, x, z))
		pointLight(arena.Model, (kitLightPoint("Lava_Pool", cf, s) or cf.Position) + Vector3.new(0, 2.2, 0), 16, 1.1, P.lava_300, true)
		arena.Lights += 1
	end
end

------------------------------------------------------------------------------------------
-- SWAMP: a misty bog (unlocked at stage 3).
--
--   centre      a firm mossy clearing where two bog tracks cross (spawn)
--   north-west  the STILT HUT with its wisp lanterns, barrels and a log pile
--   north-east  SUNKEN RUINS: a mossy arch, walls and broken pillars
--   east        a WISP CIRCLE: bog stones around a crooked lantern
--   south-west  a low FISHER CAMP (fence, logs, crates, a lantern)
--   mid / outer MUD POOLS (8, slow 35%), a deep bog pond (impassable), mangrove and
--               willow groves, mossy boulders, rotting logs and stumps
--   border      reeds along the edge, a dense mangrove / willow line (low on the south)
------------------------------------------------------------------------------------------

local SWAMP_RUIN: Pal = { Stone = mix(P.stone_500, P.murk_500, 0.35), Stone2 = mix(P.stone_400, P.murk_400, 0.35), Stone3 = mix(P.stone_600, P.murk_600, 0.35), Moss = mix(P.moss_500, P.murk_400, 0.5), Trim = mix(P.stone_400, P.murk_400, 0.35) }
local SWAMP_PILLAR: Pal = { Base = SWAMP_RUIN.Stone3, Shaft = SWAMP_RUIN.Stone2, Shaft2 = SWAMP_RUIN.Stone, Moss = SWAMP_RUIN.Moss }
local SWAMP_WOOD: Pal = { Wood = mix(P.wood_600, P.murk_600, 0.3), Frame = P.wood_700, Iron = P.steel_700, Lid = P.wood_600, Post = P.wood_700, Rail = mix(P.wood_600, P.murk_500, 0.3) }
local SWAMP_GRASS: Pal = { Grass = P.fen_300 }
local SWAMP_FERN: Pal = { Fern = mix(P.fen_400, P.meadow_500, 0.4) }
local SWAMP_PEBBLE: Pal = { Stone = mix(P.stone_600, P.murk_600, 0.3) }
local SWAMP_WISP = rgb(196, 232, 150)
local SWAMP_SMALL = {
	{ "GrassTuft", 1.0, 1.6, SWAMP_GRASS },
	{ "GrassTuft", 1.0, 1.6, SWAMP_GRASS },
	{ "GrassTuft", 1.0, 1.6, SWAMP_GRASS },
	{ "Fern", 0.9, 1.3, SWAMP_FERN },
	{ "Rock_Small", 0.7, 1.1, SWAMP_PEBBLE },
}
local SWAMP_SHADE = {
	{ "Fern", 1.0, 1.5, SWAMP_FERN },
	{ "Mushroom", 0.9, 1.3 },
	{ "GrassTuft", 1.0, 1.4, SWAMP_GRASS },
}
local SWAMP_POOL_RIM = { { "Reeds", 1.0, 1.4 }, { "GrassTuft", 1.0, 1.5, SWAMP_GRASS }, { "GrassTuft", 1.0, 1.5, SWAMP_GRASS }, { "Rock_Small", 0.7, 1.0, SWAMP_PEBBLE } }

-- Deep bog pond (impassable water, one circle collider), lilypads and reeds.
local function bogPond(arena: Arena, x: number, z: number, r: number)
	local m = arena.Decor
	disc(m, "PondBank", W(arena, x, z, 0.08), r + 2.8, mix(P.peat_500, P.fen_600, 0.4))
	disc(m, "PondBed", W(arena, x, z, 0.12), r + 0.6, P.murk_800)
	local water = disc(m, "Water", W(arena, x, z, 0.2), r, mix(P.fen_600, P.slate_500, 0.45))
	water.Transparency = 0.1
	water.Reflectance = 0.08
	for k = 1, 3 do
		local a, d = k * 2.1 + jitter(0.3), rng:NextNumber(3, r - 3)
		prop(m, "Lilypads", CFrame.new(W(arena, x + math.cos(a) * d, z + math.sin(a) * d, 0.1)) * randomYaw(), rng:NextNumber(1.2, 1.6), nil, { shadow = false })
	end
	for k = 1, 5 do
		local a = math.rad(150) + k * 0.42 + jitter(0.08)
		local d = r + jitter(0.8)
		prop(m, "Reeds", CFrame.new(W(arena, x + math.cos(a) * d, z + math.sin(a) * d)) * randomYaw(), rng:NextNumber(1.3, 1.8), nil, { shadow = false })
	end
	local wp = W(arena, x, z)
	circleCollider(arena, wp.X, wp.Z, r, 4)
	keepout(arena, x, z, r + 3)
end

-- A mud pool with reeds on its rim and now and then a lilypad.
local function mudPool(arena: Arena, x: number, z: number, s: number, yawDeg: number)
	if hazardPool(arena, "Mud", x, z, s, yawDeg) then
		local r = HAZARD_KIT.Mud.Radius * s
		rimDecor(arena, x, z, r + 1.2, r + 3, 3, SWAMP_POOL_RIM)
		if rng:NextNumber() < 0.5 then
			local a = rng:NextNumber(0, TAU)
			prop(arena.Decor, "Lilypads", CFrame.new(W(arena, x + math.cos(a) * r * 0.4, z + math.sin(a) * r * 0.4, 0.05)) * randomYaw(), 1.1, nil, { shadow = false })
		end
	end
end

local function buildSwamp(arena: Arena)
	arena.DecorDensity = 0.7
	arena.PortalPalette = { Moss = P.murk_400 }
	local base = mix(P.fen_500, P.fen_400, 0.45)
	biomeGround(arena, P.fen_600, base)
	local dark, light, mud = mix(P.fen_600, P.fen_500, 0.5), mix(P.fen_400, P.fen_300, 0.4), mix(P.peat_500, P.fen_500, 0.45)
	groundPatches(arena, {
		{ -150, -150, 26, dark }, { 124, -160, 22, dark }, { -170, 60, 24, dark }, { 160, 120, 26, dark },
		{ 30, -130, 20, dark }, { -60, 150, 22, dark }, { -110, -36, 18, dark },
		{ -84, 96, 22, light }, { 92, 72, 22, light }, { -36, -96, 20, light }, { 74, -86, 18, light },
		{ 140, -108, 18, light }, { -140, 116, 20, light }, { 4, 140, 22, light }, { -176, -88, 20, light },
		{ 116, 174, 16, mud }, { 176, 12, 18, mud }, { -20, -170, 16, mud },
	})
	-- the clearing: firm lighter moss
	patch(arena, 0, 0, 24, mix(P.fen_400, P.fen_300, 0.4), 0.05)
	patch(arena, -3, 2, 13, mix(P.fen_400, P.peat_400, 0.3), 0.07)

	-- bog tracks: west-east and south-north, crossing in the clearing
	local core, edge = mix(P.peat_500, P.peat_400, 0.3), mix(P.peat_500, base, 0.55)
	dirtPath(arena, {
		Vector2.new(-262, -24), Vector2.new(-200, -10), Vector2.new(-140, -30), Vector2.new(-86, -14),
		Vector2.new(-40, -6), Vector2.new(0, 0), Vector2.new(44, 10), Vector2.new(96, 4),
		Vector2.new(146, 24), Vector2.new(204, 14), Vector2.new(262, 26),
	}, 7, core, edge, 0.12)
	dirtPath(arena, {
		Vector2.new(20, 262), Vector2.new(12, 196), Vector2.new(28, 132), Vector2.new(8, 84),
		Vector2.new(6, 40), Vector2.new(0, 0), Vector2.new(-8, -36), Vector2.new(-16, -70),
		Vector2.new(-6, -108), Vector2.new(14, -150), Vector2.new(4, -200), Vector2.new(12, -262),
	}, 6, core, edge, 0.16)

	boundaryWalls(arena)

	-- clearing decor (low, sparse, off the tracks)
	scatter(arena, 0, 0, 34, 22, { { "GrassTuft", 1.0, 1.6, SWAMP_GRASS }, { "GrassTuft", 1.2, 1.8, SWAMP_GRASS }, { "Reeds", 0.9, 1.2 }, { "Rock_Small", 0.7, 1.1, SWAMP_PEBBLE } }, 1.2, 0.4)
	scatter(arena, 0, 0, 40, 6, { { "Fern", 1, 1.4, SWAMP_FERN }, { "Mushroom", 1, 1.3 } }, 1.5, 0.5)

	--------------------------------------------------------------------------------------
	-- LANDMARKS (mid ring)

	-- 1. Stilt hut (north-west), porch toward the camera; wisp lanterns either side
	local hx, hz = -66, -52
	local hut = obstacle(arena, "Swamp_Hut", hx, hz, 180, 1.15, nil, { occluder = true })
	hut.Name = "Landmark_Hut"
	kitLight(arena, "Swamp_Hut", hx, hz, 180, 1.15, 14, 1.0, SWAMP_WISP)
	for _, l in ipairs({ { hx - 8, hz + 6, 0 }, { hx + 8.5, hz + 5, 180 } }) do
		obstacle(arena, "Swamp_Lantern", l[1], l[2], l[3], 1.0)
	end
	kitLight(arena, "Swamp_Lantern", hx + 8.5, hz + 5, 180, 1.0, 13, 1.1, SWAMP_WISP)
	obstacle(arena, "Barrel", hx + 6.5, hz - 5, 0, 1.05, SWAMP_WOOD)
	obstacle(arena, "Crate", hx + 6.8, hz - 2.4, 90, 0.95, SWAMP_WOOD)
	decor(arena, "Swamp_Log", hx - 7.5, hz - 4, 90, 0.9, nil, { shadow = true })
	patch(arena, hx, hz + 1, 10, mix(P.peat_500, P.fen_500, 0.5), 0.05)
	keepout(arena, hx, hz, 13)
	scatter(arena, hx, hz, 20, 7, { { "Reeds", 1, 1.4 }, { "Fern", 1, 1.4, SWAMP_FERN }, { "Mushroom", 1, 1.2 }, { "GrassTuft", 1, 1.5, SWAMP_GRASS } }, 0.6)

	-- 2. Sunken ruins (north-east): a mossy arch with walls and broken pillars
	obstacle(arena, "Ruin_Arch", 70, -64, 0, 1, SWAMP_RUIN, { occluder = true }).Name = "Landmark_Arch"
	obstacle(arena, "Ruin_Wall", 79.4, -64.4, 0, 1, SWAMP_RUIN, { occluder = true })
	obstacle(arena, "Ruin_WallLow", 60.2, -63.6, 180, 1, SWAMP_RUIN)
	obstacle(arena, "Pillar", 58, -77, 30, 1.05, SWAMP_PILLAR, { occluder = true })
	obstacle(arena, "Pillar", 85, -52, 200, 0.95, SWAMP_PILLAR, { occluder = true })
	decor(arena, "Ruin_Block", 82, -75, 35, 0.9, SWAMP_RUIN, { shadow = true })
	keepout(arena, 70, -64, 13)
	scatter(arena, 70, -64, 22, 8, { { "Reeds", 1, 1.4 }, { "Fern", 1, 1.4, SWAMP_FERN }, { "Rock_Small", 0.8, 1.2, SWAMP_PEBBLE }, { "GrassTuft", 1, 1.5, SWAMP_GRASS } }, 0.6)

	-- 3. Wisp circle (east): bog stones in a ring around a crooked lantern
	local wx, wz = 88, 32
	for k = 0, 5 do
		local a = k / 6 * TAU + 0.4
		stone(arena, "Swamp_Rock", wx + math.cos(a) * 9, wz + math.sin(a) * 9, rng:NextNumber(0.62, 0.78))
	end
	obstacle(arena, "Swamp_Lantern", wx, wz, 0, 1.1)
	kitLight(arena, "Swamp_Lantern", wx, wz, 0, 1.1, 15, 1.2, SWAMP_WISP)
	patch(arena, wx, wz, 8, mix(P.fen_400, P.fen_300, 0.4), 0.05)
	keepout(arena, wx, wz, 11)
	scatter(arena, wx, wz, 14, 6, { { "Mushroom", 1, 1.3 }, { "GrassTuft", 1.1, 1.6, SWAMP_GRASS }, { "Reeds", 1, 1.3 } }, 0.5)

	-- 4. Fisher camp (south-west, all low)
	local kx, kz = -56, 54
	obstacle(arena, "Fence_Section", kx - 6, kz + 8, 0, 1, SWAMP_WOOD)
	obstacle(arena, "Fence_Section", kx - 10.2, kz + 3.8, 90, 1, SWAMP_WOOD)
	obstacle(arena, "Swamp_Log", kx + 6, kz - 6, 0, 1.0)
	obstacle(arena, "Swamp_Stump", kx - 1, kz - 3, 0, 1.0)
	obstacle(arena, "Crate", kx - 6, kz - 2, 90, 1.0, SWAMP_WOOD)
	prop(arena.Decor, "Crate", CFrame.new(W(arena, kx - 6, kz - 1.9, 2)) * yawCF(25), 0.8, SWAMP_WOOD)
	obstacle(arena, "Barrel", kx - 8.6, kz - 5.6, 0, 1.0, SWAMP_WOOD)
	obstacle(arena, "Swamp_Lantern", kx + 3, kz + 3, 0, 1.0)
	kitLight(arena, "Swamp_Lantern", kx + 3, kz + 3, 0, 1.0, 13, 1.1, SWAMP_WISP)
	patch(arena, kx - 2, kz - 1, 9, mix(P.peat_500, P.fen_500, 0.55), 0.05)
	keepout(arena, kx - 2, kz, 13)
	scatter(arena, kx - 2, kz, 18, 6, { { "GrassTuft", 1, 1.5, SWAMP_GRASS }, { "Reeds", 1, 1.3 }, { "Rock_Small", 0.7, 1.0, SWAMP_PEBBLE } }, 0.5)

	--------------------------------------------------------------------------------------
	-- MUD POOLS (hazards: slow players and walking enemies)
	for _, mp in ipairs({
		{ -40, -90, 1.6, 20 }, { 50, -106, 1.55, 110 }, { 114, -40, 1.6, 60 }, { 62, 94, 1.55, 200 },
		{ -102, 32, 1.6, 140 }, { -142, -64, 1.5, 300 }, { 150, 122, 1.55, 30 }, { -62, 150, 1.6, 250 },
	}) do
		mudPool(arena, mp[1], mp[2], mp[3], mp[4])
	end

	--------------------------------------------------------------------------------------
	-- OUTER RING

	bogPond(arena, -118, -116, 12)
	tree(arena, "Swamp_Willow", -104, -104, 1.1)
	stone(arena, "Swamp_Rock", -131, -103, 0.95)

	local T, Wl = "Swamp_Tree", "Swamp_Willow"
	kitGrove(arena, -48, -152, { { T, 0, 0, 1.2 }, { Wl, 10, 6, 1.1 }, { T, -9, 7, 1.0 }, { Wl, 5, -10, 1.0 }, { T, -12, -6, 0.95 } }, SWAMP_SHADE)
	kitGrove(arena, 118, -128, { { Wl, 0, 0, 1.2 }, { T, 10, 5, 1.1 }, { T, -9, 8, 1.0 }, { Wl, 6, -9, 1.0 }, { T, -8, -8, 0.95 } }, SWAMP_SHADE)
	kitGrove(arena, 156, 62, { { T, 0, 0, 1.2 }, { Wl, 11, -5, 1.05 }, { T, -6, 9, 1.0 }, { Wl, 8, 10, 1.0 }, { T, -10, -7, 0.95 } }, SWAMP_SHADE)
	kitGrove(arena, -164, 30, { { Wl, 0, 0, 1.15 }, { T, -8, 8, 1.0 }, { T, 9, 4, 1.05 }, { Wl, 2, -10, 0.95 } }, SWAMP_SHADE)
	kitGrove(arena, 108, 152, { { T, 0, 0, 0.95 }, { Wl, 10, 6, 0.85 }, { T, -6, 9, 0.85 } }, SWAMP_SHADE)
	kitGrove(arena, -126, 124, { { Wl, 0, 0, 1.0 }, { T, 9, -5, 0.9 }, { T, -8, 7, 0.85 } }, SWAMP_SHADE)

	local function swampOutcrop(x: number, z: number, big: number, medium: { number }?)
		stone(arena, "Swamp_Rock", x, z, big)
		if medium then
			stone(arena, "Swamp_Rock", x + medium[1], z + medium[2], medium[3])
		end
		scatter(arena, x, z, big * 5, 3, { { "Rock_Small", 0.8, 1.3, SWAMP_PEBBLE }, { "Reeds", 1, 1.4 }, { "Fern", 0.9, 1.2, SWAMP_FERN } }, 0.6)
	end
	swampOutcrop(66, -142, 1.45, { 5.5, 3, 1.0 })
	swampOutcrop(172, -36, 1.4, { -4, 5, 1.0 })
	swampOutcrop(-176, 86, 1.45, { 5, -4, 1.0 })
	swampOutcrop(34, 160, 1.35, { -5, -3, 0.95 })
	swampOutcrop(-74, -122, 1.35, { 5, 4, 0.95 })

	-- rotting logs and stumps
	obstacle(arena, "Swamp_Log", -96, 100, 0, 1.15)
	obstacle(arena, "Swamp_Log", 134, -64, 90, 1.1)
	obstacle(arena, "Swamp_Log", -30, 128, 4, 1.05)
	for _, st in ipairs({ { -32, -136 }, { 130, -100 }, { 136, 88 }, { -146, 6 } }) do
		obstacle(arena, "Swamp_Stump", st[1], st[2], rng:NextNumber(0, 360), rng:NextNumber(1.0, 1.25))
	end

	-- corners: a mossy boulder and two trees each (small round ones on the camera side)
	for _, q in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local south = q[2] == 1
		local bx, bz = q[1] * 172, q[2] * 172
		stone(arena, "Swamp_Rock", bx + q[1] * 6, bz - q[2] * 10, 1.35)
		tree(arena, south and Wl or T, bx - q[1] * 4, bz + q[2] * 8, south and 0.85 or 1.15)
		tree(arena, south and T or Wl, bx + q[1] * 12, bz + q[2] * 2, south and 0.8 or 1.05)
		scatter(arena, bx, bz, 18, 3, SWAMP_SHADE, 1)
	end

	-- bog meadow scatter
	for _ = 1, 7 do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(44, 190)
		scatter(arena, math.cos(a) * r, math.sin(a) * r, 6, 2, SWAMP_SMALL, 1.5, 0.5)
	end

	-- BORDER: dark mossy bog rock on three sides, a low root-tangled rim on the camera side,
	-- reeds along the edge, then the mangrove / willow line
	vignettes(arena, {
		function(a, x, z) campfire(a, x, z, SWAMP_PEBBLE, P.wood_700) end,
		function(a, x, z) ring(a, x, z, "Mushroom", 7, 3.0, 1.2, 1.8) end,
		function(a, x, z) supplies(a, x, z, SWAMP_WOOD) end,
		function(a, x, z) decor(a, "Swamp_Lantern", x, z, 0, 0.9); cluster(a, x, z, { { "Reeds", 1.2, 1.6 }, { "Mushroom", 1.0, 1.4 } }, 4, 3) end,
		function(a, x, z) cluster(a, x, z, { { "Swamp_Stump", 0.7, 0.9 }, { "Mushroom", 1.1, 1.5 }, { "Fern", 1.1, 1.5, SWAMP_FERN } }, 5, 3.5) end,
		function(a, x, z) ring(a, x, z, "Mushroom", 5, 2.4, 1.0, 1.4) end,
	})
	cliffs(arena, {
		Rock = { mix(P.stone_600, P.murk_600, 0.4), mix(P.stone_700, P.murk_700, 0.35), mix(P.stone_500, P.fen_600, 0.3) },
		Cap = mix(P.fen_500, P.murk_400, 0.35),
		Height = { 10, 16 },
		South = { 2.2, 3.6 },
		Face = { "Swamp_Rock", { Stone = mix(P.stone_600, P.murk_600, 0.4), Stone2 = mix(P.stone_700, P.murk_700, 0.35), Moss = mix(P.fen_500, P.murk_400, 0.35) } },
		Foot = { { "Swamp_Log", 1.0, 1.3 }, { "Reeds", 1.5, 2.0 }, { "Mushroom", 1.3, 1.7 } },
	})
	local h = arena.Half
	alongSides(-h + 10, h - 10, 40, function(_side, along, out, t)
		if rng:NextNumber() < 0.38 then
			local p = along * (t + jitter(6)) + out * (h - 2 - rng:NextNumber(0, 3))
			decor(arena, "Reeds", p.X, p.Y, nil, rng:NextNumber(1.4, 1.9))
		end
	end)
	treeLine(arena, {
		{ "Swamp_Tree", 1.35, 1.8, nil },
		{ "Swamp_Willow", 1.35, 1.75, nil },
		{ "Swamp_Tree", 1.3, 1.7, nil },
	}, {
		{ "Bush", 1.4, 2.0, { Leaves = P.murk_600, Leaves2 = P.murk_500 } },
		{ "Swamp_Willow", 0.7, 0.85, nil },
	}, 37, mix(P.fen_600, P.fen_700, 0.6))
end

------------------------------------------------------------------------------------------
-- SNOW: a frozen pine valley (unlocked at stage 4).
--
--   centre      a trodden snow clearing where two packed-snow trails cross (spawn)
--   west        the TOTEM SHRINE: the carved totem on its plinth, stone lamps, slabs
--   north       a snowed RUINED ARCH over the north trail, walls and pillars
--   east        an ICE CRYSTAL ring with a frost glow
--   south-west  a low TRAPPER CAMP (fence, crates, barrels, a log, a stone lamp)
--   mid / outer FROZEN PONDS (7, slippery: faster but drifting), a boulder field, a
--               collapsed watchtower, snowy pine groves, boulders, logs, stumps
--   border      a snowed split-rail fence, then tall snowy pines (low on the south)
------------------------------------------------------------------------------------------

local SNOW_RUIN: Pal = { Stone = mix(P.stone_400, P.slate_400, 0.15), Stone2 = mix(P.stone_300, P.slate_300, 0.15), Stone3 = mix(P.stone_500, P.slate_500, 0.15), Moss = P.snow_100, Trim = P.stone_300 }
local SNOW_PILLAR: Pal = { Base = SNOW_RUIN.Stone3, Shaft = SNOW_RUIN.Stone2, Shaft2 = SNOW_RUIN.Stone, Moss = P.snow_100 }
local SNOW_WOOD: Pal = { Wood = P.wood_600, Frame = P.wood_700, Iron = P.steel_700, Lid = P.snow_200, Post = P.wood_700, Rail = P.wood_600, Bark = P.wood_600, Heart = P.dirt_300, Moss = P.snow_100 }
local SNOW_PEBBLE: Pal = { Stone = mix(P.stone_400, P.snow_400, 0.4) }
local SNOW_SLAB: Pal = { Slab = mix(P.stone_400, P.slate_400, 0.2), Moss = P.snow_100 }
local FROST = rgb(188, 222, 255)
local LAMP = rgb(255, 204, 140)
local SNOW_SMALL = {
	{ "Snow_Drift", 0.8, 1.3 },
	{ "Rock_Small", 0.7, 1.1, SNOW_PEBBLE },
	{ "Rock_Small", 0.7, 1.1, SNOW_PEBBLE },
	{ "Snow_Bush", 0.8, 1.1 },
}
local SNOW_SHADE = {
	{ "Snow_Bush", 0.9, 1.3 },
	{ "Rock_Small", 0.8, 1.2, SNOW_PEBBLE },
	{ "Rock_Small", 0.8, 1.2, SNOW_PEBBLE },
}
local ICE_RIM = { { "Snow_Drift", 0.8, 1.2 }, { "Rock_Small", 0.7, 1.1, SNOW_PEBBLE }, { "Snow_Bush", 0.7, 1.0 } }

-- Collapsed watchtower: a broken ring of snowed stone (one circle collider).
local function snowTower(arena: Arena, x: number, z: number, r: number)
	local m = Instance.new("Model")
	m.Name = "CollapsedTower"
	local n = 10
	for k = 0, n - 1 do
		local a = k / n * TAU
		local hgt = (k % 3 == 0) and rng:NextNumber(1.2, 2) or rng:NextNumber(3, 6)
		local cf = CFrame.new(W(arena, x + math.cos(a) * (r - 1), z + math.sin(a) * (r - 1), hgt / 2)) * CFrame.Angles(0, -a, 0)
		deco(m, { Name = "Stone", Size = Vector3.new(2.2, hgt, r * TAU / n + 0.4), CFrame = cf, Color = mix(SNOW_RUIN.Stone, SNOW_RUIN.Stone3, rng:NextNumber(0, 1)), CastShadow = true })
		deco(m, { Name = "Snow", Size = Vector3.new(2.3, 0.35, r * TAU / n + 0.45), CFrame = cf * CFrame.new(0, hgt / 2 + 0.1, 0), Color = P.snow_100 })
	end
	disc(m, "Rubble", W(arena, x, z, 0.4), r - 1.6, P.snow_200, 0.8)
	tag(m)
	m.Parent = arena.Model
	local wp = W(arena, x, z)
	circleCollider(arena, wp.X, wp.Z, r, 6)
	keepout(arena, x, z, r + 4)
end

local function icePond(arena: Arena, x: number, z: number, s: number, yawDeg: number)
	if hazardPool(arena, "Ice", x, z, s, yawDeg) then
		local r = HAZARD_KIT.Ice.Radius * s
		rimDecor(arena, x, z, r + 2, r + 4, 3, ICE_RIM)
	end
end

local function buildSnow(arena: Arena)
	arena.DecorDensity = 0.65
	arena.PortalPalette = { Moss = P.snow_100 }
	-- packed snow a step darker than fresh snow (value 0.78, not 0.9): white-ish creatures,
	-- ice-blue gems, warnings and the hero need a floor they can stand out from; the
	-- brightest white is kept for drifts, rims and props
	local base = mix(P.snow_300, P.stone_300, 0.3)
	biomeGround(arena, mix(P.snow_300, P.stone_300, 0.15), base)
	local blue, white, grey = mix(P.snow_400, P.ice_300, 0.25), mix(P.snow_200, P.snow_300, 0.4), mix(P.snow_400, P.stone_400, 0.35)
	groundPatches(arena, {
		{ -150, -150, 26, blue }, { 120, -165, 22, blue }, { -170, 60, 24, blue }, { 160, 120, 26, blue },
		{ 30, -126, 20, grey }, { -60, 150, 22, blue }, { -110, -40, 18, grey },
		{ -80, 90, 22, white }, { 90, 70, 24, white }, { -40, -90, 22, white }, { 70, -80, 18, white },
		{ 140, -110, 18, white }, { -140, 120, 20, white }, { 0, 140, 24, white }, { -175, -90, 20, white },
		{ 120, 175, 16, grey }, { 175, 10, 18, grey },
	})
	patch(arena, 0, 0, 24, mix(P.snow_300, P.stone_300, 0.15), 0.05)
	patch(arena, 3, 2, 13, mix(P.snow_400, P.stone_300, 0.4), 0.07)

	-- packed-snow trails: a warm trodden grey (blue gems and frost beetles read on it)
	local core, edge = mix(P.stone_400, P.dirt_300, 0.3), mix(P.snow_400, P.stone_300, 0.5)
	dirtPath(arena, {
		Vector2.new(-262, 18), Vector2.new(-196, 30), Vector2.new(-150, 12), Vector2.new(-96, 22),
		Vector2.new(-44, 6), Vector2.new(0, 0), Vector2.new(40, -12), Vector2.new(90, -4),
		Vector2.new(140, -24), Vector2.new(198, -10), Vector2.new(262, -18),
	}, 7, core, edge, 0.12)
	dirtPath(arena, {
		Vector2.new(-18, 262), Vector2.new(-24, 190), Vector2.new(-8, 130), Vector2.new(-20, 84),
		Vector2.new(-4, 40), Vector2.new(0, 0), Vector2.new(8, -38), Vector2.new(16, -76),
		Vector2.new(8, -118), Vector2.new(-10, -160), Vector2.new(0, -210), Vector2.new(-6, -262),
	}, 6, core, edge, 0.16)

	boundaryWalls(arena)

	scatter(arena, 0, 0, 34, 14, { { "Snow_Drift", 0.8, 1.2 }, { "Rock_Small", 0.7, 1.0, SNOW_PEBBLE }, { "Rock_Small", 0.7, 1.1, SNOW_PEBBLE } }, 1.2, 0.4)
	scatter(arena, 0, 0, 40, 6, { { "Snow_Bush", 0.8, 1.1 } }, 1.5, 0.5)

	--------------------------------------------------------------------------------------
	-- LANDMARKS (mid ring)

	-- 1. Totem shrine (west), facing the clearing; stone lamps either side, a slab apron
	local sx, sz = -72, -30
	obstacle(arena, "Snow_Shrine_Totem", sx, sz, 180, 1.2, nil, { occluder = true }).Name = "Landmark_Totem"
	kitLight(arena, "Snow_Shrine_Totem", sx, sz, 180, 1.2, 14, 1.0, FROST)
	for _, dx in ipairs({ -5.6, 5.6 }) do
		obstacle(arena, "Snow_Lamp", sx + dx, sz + 2, 0, 1.05)
	end
	kitLight(arena, "Snow_Lamp", sx + 5.6, sz + 2, 0, 1.05, 15, 1.3, LAMP)
	for _, sp in ipairs({ { sx, sz + 4.6 }, { sx + 3.4, sz + 5.4 }, { sx - 3.3, sz + 5.1 } }) do
		prop(arena.Decor, "Rock_Slab", CFrame.new(W(arena, sp[1], sp[2], -0.45)) * yawCF(jitter(14)), 0.95, SNOW_SLAB, { shadow = false })
	end
	stone(arena, "Snow_Rock", sx - 9, sz + 9, 1.05)
	stone(arena, "Snow_Rock", sx - 8, sz - 12, 0.9)
	keepout(arena, sx, sz, 9)
	scatter(arena, sx, sz, 16, 6, { { "Snow_Drift", 0.9, 1.3 }, { "Snow_Bush", 0.9, 1.2 } }, 0.5)

	-- 2. Snowed ruined arch over the north trail, walls running off, broken pillars
	obstacle(arena, "Ruin_Arch", 15, -70, 0, 1, SNOW_RUIN, { occluder = true }).Name = "Landmark_Arch"
	obstacle(arena, "Snow_Ruin_Wall", 24.4, -70.4, 0, 1, nil, { occluder = true })
	obstacle(arena, "Ruin_WallLow", 5.2, -69.6, 180, 1, SNOW_RUIN)
	obstacle(arena, "Pillar", 2, -83, 30, 1.1, SNOW_PILLAR, { occluder = true })
	obstacle(arena, "Pillar", 30, -58, 200, 1.0, SNOW_PILLAR, { occluder = true })
	obstacle(arena, "Ruin_Block", 26, -81, 35, 1.0, SNOW_RUIN)
	keepout(arena, 15, -70, 13)
	scatter(arena, 15, -70, 22, 7, { { "Rock_Small", 0.8, 1.3, SNOW_PEBBLE }, { "Snow_Drift", 0.9, 1.3 }, { "Snow_Bush", 0.9, 1.2 } }, 0.6)

	-- 3. Ice crystal ring (east) around a frost light
	local ix, iz = 86, 30
	for k = 0, 4 do
		local a = k / 5 * TAU + 0.5
		obstacle(arena, "Ice_Crystal", ix + math.cos(a) * 9, iz + math.sin(a) * 9, rng:NextNumber(0, 360), rng:NextNumber(1.0, 1.25))
	end
	kitLight(arena, "Ice_Crystal", ix + math.cos(0.5) * 9, iz + math.sin(0.5) * 9, 0, 1.1, 14, 1.0, FROST)
	pointLight(arena.Model, W(arena, ix, iz, 3), 14, 0.7, FROST, false)
	arena.Lights += 1
	prop(arena.Decor, "Rock_Slab", CFrame.new(W(arena, ix, iz, -0.3)) * yawCF(20), 1.2, SNOW_SLAB, { shadow = false })
	keepout(arena, ix, iz, 11)
	scatter(arena, ix, iz, 14, 5, { { "Snow_Drift", 0.9, 1.3 }, { "Rock_Small", 0.8, 1.1, SNOW_PEBBLE } }, 0.5)

	-- 4. Trapper camp (south-west, all low)
	local kx, kz = -56, 54
	obstacle(arena, "Fence_Section", kx - 6, kz + 8, 0, 1, SNOW_WOOD)
	obstacle(arena, "Fence_Section", kx + 2.2, kz + 8.3, 3, 1, SNOW_WOOD)
	obstacle(arena, "Fence_Section", kx - 10.2, kz + 3.8, 90, 1, SNOW_WOOD)
	obstacle(arena, "Log", kx + 6, kz - 6, 0, 1.1, SNOW_WOOD)
	obstacle(arena, "Stump", kx - 1, kz - 3, 0, 1.15, SNOW_WOOD)
	obstacle(arena, "Crate", kx - 6, kz - 2, 90, 1.0, SNOW_WOOD)
	prop(arena.Decor, "Crate", CFrame.new(W(arena, kx - 6, kz - 1.9, 2)) * yawCF(30), 0.85, SNOW_WOOD)
	obstacle(arena, "Barrel", kx - 8.6, kz - 5.6, 0, 1.05, SNOW_WOOD)
	obstacle(arena, "Snow_Lamp", kx + 3, kz + 3, 0, 1.0)
	kitLight(arena, "Snow_Lamp", kx + 3, kz + 3, 0, 1.0, 14, 1.2, LAMP)
	patch(arena, kx - 2, kz - 1, 9, mix(P.snow_300, P.dirt_300, 0.25), 0.05)
	keepout(arena, kx - 2, kz, 13)
	scatter(arena, kx - 2, kz, 18, 5, { { "Snow_Drift", 0.9, 1.2 }, { "Rock_Small", 0.7, 1.0, SNOW_PEBBLE } }, 0.5)

	--------------------------------------------------------------------------------------
	-- FROZEN PONDS (hazards: slippery)
	for _, fp in ipairs({
		{ -40, -94, 1.35, 15 }, { 58, -120, 1.3, 100 }, { 124, 46, 1.35, 70 }, { 40, 100, 1.3, 160 },
		{ -106, 66, 1.35, 220 }, { 152, -96, 1.3, 300 }, { -150, 142, 1.3, 40 },
	}) do
		icePond(arena, fp[1], fp[2], fp[3], fp[4])
	end

	--------------------------------------------------------------------------------------
	-- OUTER RING

	-- boulder field with ice crystals (north-west)
	for _, b in ipairs({ { -118, -112, 2.0 }, { -107, -123, 1.6 }, { -129, -100, 1.7 }, { -104, -100, 1.3 }, { -133, -123, 1.4 } }) do
		stone(arena, "Snow_Rock", b[1], b[2], b[3])
	end
	obstacle(arena, "Ice_Crystal", -116, -96, 40, 1.3)
	obstacle(arena, "Ice_Crystal", -96, -114, 160, 1.1)
	keepout(arena, -116, -110, 18)
	scatter(arena, -116, -110, 24, 6, SNOW_SHADE, 0.8)

	snowTower(arena, 150, -46, 6.4)
	snowTower(arena, -146, 56, 5.6)

	local SP, ST = "Snow_Pine", "Snow_PineTall"
	kitGrove(arena, -48, -152, { { SP, 0, 0, 1.2 }, { SP, 9, 6, 1.1 }, { SP, -8, 7, 1.0 }, { ST, 4, -10, 1.0 }, { SP, -12, -6, 0.95 } }, SNOW_SHADE)
	kitGrove(arena, 112, -134, { { ST, 0, 0, 1.0 }, { SP, 10, 5, 1.15 }, { SP, -9, 8, 1.0 }, { SP, 6, -9, 1.05 }, { SP, -7, -8, 0.95 } }, SNOW_SHADE)
	kitGrove(arena, 152, 76, { { SP, 0, 0, 1.2 }, { SP, 11, -5, 1.05 }, { SP, -6, 9, 1.0 }, { ST, 8, 10, 0.95 }, { SP, -10, -7, 0.95 } }, SNOW_SHADE)
	kitGrove(arena, -158, -12, { { SP, 0, 0, 1.2 }, { ST, -8, 8, 1.0 }, { SP, 9, 4, 1.1 }, { SP, 2, -10, 1.0 } }, SNOW_SHADE)
	kitGrove(arena, 104, 152, { { SP, 0, 0, 0.9 }, { SP, 10, 6, 0.8 }, { SP, -6, 9, 0.8 } }, SNOW_SHADE)
	kitGrove(arena, -112, 126, { { SP, 0, 0, 0.95 }, { SP, 9, -5, 0.9 }, { SP, -8, 7, 0.85 } }, SNOW_SHADE)

	local function snowOutcrop(x: number, z: number, big: number, medium: { number }?)
		stone(arena, "Snow_Rock", x, z, big)
		if medium then
			stone(arena, "Snow_Rock", x + medium[1], z + medium[2], medium[3])
		end
		scatter(arena, x, z, big * 5, 3, { { "Rock_Small", 0.8, 1.3, SNOW_PEBBLE }, { "Snow_Drift", 0.9, 1.2 } }, 0.6)
	end
	snowOutcrop(62, -150, 1.5, { 5.5, 3, 1.0 })
	snowOutcrop(176, 10, 1.45, { -4, 5, 1.0 })
	snowOutcrop(-176, 84, 1.5, { 5, -4, 1.0 })
	snowOutcrop(42, 156, 1.4, { -5, -3, 0.95 })
	snowOutcrop(-64, -122, 1.4, { 5, 4, 0.95 })

	-- old snowed foundation (north-east)
	obstacle(arena, "Snow_Ruin_Wall", 40, -176, 0, 1, nil, { occluder = true })
	obstacle(arena, "Snow_Ruin_Wall", 48.7, -176.2, 0, 1, nil, { occluder = true })
	obstacle(arena, "Snow_Ruin_Wall", 53.4, -170.6, 90, 1, nil, { occluder = true })
	obstacle(arena, "Ruin_WallLow", 33.5, -168, 90, 1, SNOW_RUIN)
	obstacle(arena, "Pillar", 44, -160, 0, 1.0, SNOW_PILLAR, { occluder = true })
	keepout(arena, 45, -168, 12)

	-- logs and stumps under snow
	obstacle(arena, "Log", -96, 100, 0, 1.15, SNOW_WOOD)
	obstacle(arena, "Log", 134, -64, 90, 1.1, SNOW_WOOD)
	obstacle(arena, "Log", -28, 134, 4, 1.05, SNOW_WOOD)
	for _, st in ipairs({ { -36, -136 }, { 128, -108 }, { 140, 92 }, { -142, 2 } }) do
		obstacle(arena, "Stump", st[1], st[2], rng:NextNumber(0, 360), rng:NextNumber(1.0, 1.25), SNOW_WOOD)
	end

	-- corners
	for _, q in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local south = q[2] == 1
		local bx, bz = q[1] * 172, q[2] * 172
		stone(arena, "Snow_Rock", bx + q[1] * 6, bz - q[2] * 10, 1.35)
		tree(arena, SP, bx - q[1] * 4, bz + q[2] * 8, south and 0.75 or 1.15)
		tree(arena, south and SP or ST, bx + q[1] * 12, bz + q[2] * 2, south and 0.7 or 1.0)
		scatter(arena, bx, bz, 18, 3, SNOW_SHADE, 1)
	end

	for _ = 1, 5 do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(44, 190)
		scatter(arena, math.cos(a) * r, math.sin(a) * r, 6, 2, SNOW_SMALL, 1.5, 0.5)
	end

	-- BORDER: icy blue-grey cliffs under thick snow on three sides, a low snowy rim and the
	-- fence on the camera side, then tall snowy pines on the cliff tops
	vignettes(arena, {
		function(a, x, z) campfire(a, x, z, SNOW_PEBBLE) end,
		function(a, x, z) supplies(a, x, z, SNOW_WOOD) end,
		function(a, x, z) cluster(a, x, z, { { "Ice_Crystal", 0.7, 1.1 }, { "Snow_Drift", 0.9, 1.2 }, { "Rock_Small", 0.8, 1.1, SNOW_PEBBLE } }, 5, 3.5) end,
		function(a, x, z) decor(a, "Snow_Lamp", x, z, 0, 0.9); cluster(a, x, z, { { "Snow_Bush", 0.9, 1.2 }, { "Snow_Drift", 0.9, 1.3 } }, 3, 3) end,
		function(a, x, z) cluster(a, x, z, { { "Ice_Crystal", 0.6, 1.0 }, { "Ice_Crystal", 0.8, 1.2 } }, 4, 2.5) end,
		function(a, x, z) decor(a, "Banner", x, z, 180, 1.0); cluster(a, x, z, { { "Snow_Drift", 0.9, 1.2 } }, 2, 2.5) end,
	})
	cliffs(arena, {
		Rock = { mix(P.stone_400, P.slate_500, 0.35), mix(P.stone_500, P.slate_600, 0.3), mix(P.ice_300, P.slate_400, 0.55) },
		Cap = P.snow_100,
		CapThick = 1.6,
		Height = { 13, 21 },
		South = { 2.4, 3.8 },
		Face = { "Snow_Rock", { Stone = mix(P.stone_400, P.slate_500, 0.35), Stone2 = mix(P.stone_500, P.slate_600, 0.3), Snow = P.snow_100 } },
		Foot = { { "Ice_Crystal", 1.0, 1.5 }, { "Snow_Drift", 1.4, 2.0 }, { "Snow_Bush", 1.2, 1.6 } },
	})
	brokenFence(arena, 1.3, SNOW_WOOD, 30)
	treeLine(arena, {
		{ "Snow_PineTall", 1.25, 1.7, nil },
		{ "Snow_PineTall", 1.2, 1.6, nil },
		{ "Snow_Pine", 1.35, 1.8, nil },
	}, {
		{ "Snow_Bush", 1.5, 2.1, nil },
		{ "Snow_Drift", 1.4, 2.0, nil },
		{ "Snow_Pine", 0.6, 0.75, nil },
	}, 38, mix(P.snow_300, P.ice_300, 0.35))
end

------------------------------------------------------------------------------------------
-- DESERT: sun-baked dunes and old sandstone (unlocked at stage 5).
--
--   centre      a hard-packed sand clearing where two caravan tracks cross (spawn)
--   north       the OBELISK COURT: the gold-capped obelisk, a ring of broken columns,
--               two braziers and a wall
--   west        a NOMAD CAMP: two striped tents, crates, barrels and torches
--   east        a RUINED GATE: sandstone walls and pillars across an old road
--   south-west  low BEAST BONES among rocks and cacti
--   mid / outer QUICKSAND (7, slows 45%), two big MESAS, a dry oasis basin
--               (impassable), cactus stands, sandstone outcrops and ruins
--   border      tall mesas and rocks on three sides, dunes on the camera side
------------------------------------------------------------------------------------------

local DESERT_PEBBLE: Pal = { Stone = P.sand_600 }
local DESERT_WOOD: Pal = { Wood = mix(P.wood_500, P.sand_600, 0.3), Frame = P.wood_600, Iron = P.steel_700, Lid = P.wood_500 }
local DESERT_FIRE: Pal = { Stone = P.sand_500, Base = P.sand_600, Iron = P.steel_700 }
local DESERT_SMALL = {
	{ "Dune", 0.5, 0.8 },
	{ "Rock_Small", 0.8, 1.2, DESERT_PEBBLE },
	{ "Rock_Small", 0.7, 1.0, DESERT_PEBBLE },
	{ "Cactus", 0.45, 0.6 },
}
local DESERT_SHADE = {
	{ "Rock_Small", 0.8, 1.3, DESERT_PEBBLE },
	{ "Dune", 0.5, 0.8 },
	{ "Bones", 0.6, 0.8 },
}
local SAND_RIM = { { "Rock_Small", 0.7, 1.1, DESERT_PEBBLE }, { "Dune", 0.45, 0.6 } }

-- Dry oasis basin: a cracked clay bed with a last puddle, reeds and rocks (impassable).
local function oasis(arena: Arena, x: number, z: number, r: number)
	local m = arena.Decor
	disc(m, "Bank", W(arena, x, z, 0.08), r + 2.6, P.sand_500)
	disc(m, "ClayBed", W(arena, x, z, 0.12), r + 0.5, mix(P.clay_600, P.sand_600, 0.4))
	local water = disc(m, "Water", W(arena, x, z, 0.18), r * 0.6, mix(P.slate_500, P.ice_500, 0.4))
	water.Transparency = 0.1
	water.Reflectance = 0.06
	for k = 1, 6 do
		local a = math.rad(200) + k * 0.4 + jitter(0.1)
		local d = r * 0.6 + jitter(0.6)
		prop(m, "Reeds", CFrame.new(W(arena, x + math.cos(a) * d, z + math.sin(a) * d, 0.1)) * randomYaw(), rng:NextNumber(1.2, 1.6), { Reed = mix(P.moss_500, P.sand_500, 0.3), Reed2 = P.sand_400 }, { shadow = false })
	end
	local wp = W(arena, x, z)
	circleCollider(arena, wp.X, wp.Z, r, 3)
	keepout(arena, x, z, r + 3)
	stone(arena, "Desert_Rock", x + r + 1.5, z - 2, 0.9)
	stone(arena, "Desert_Rock", x - r * 0.7, z + r * 0.75, 0.85)
	tree(arena, "Cactus_Tall", x + 2, z - r - 3, 1.0)
	tree(arena, "Cactus", x - r - 2.5, z - 4, 1.0)
end

local function quicksand(arena: Arena, x: number, z: number, s: number, yawDeg: number)
	if hazardPool(arena, "Quicksand", x, z, s, yawDeg) then
		local r = HAZARD_KIT.Quicksand.Radius * s
		rimDecor(arena, x, z, r + 1.8, r + 3.5, 3, SAND_RIM)
	end
end

local function buildDesert(arena: Arena)
	arena.DecorDensity = 0.7
	arena.PortalPalette = { Moss = P.sand_300 }
	local base = mix(P.sand_400, P.sand_300, 0.4)
	biomeGround(arena, P.sand_500, base)
	local deep, pale, clay = mix(P.sand_400, P.sand_500, 0.4), mix(P.sand_300, P.sand_200, 0.4), mix(P.sand_400, P.clay_500, 0.18)
	groundPatches(arena, {
		{ -150, -150, 26, deep }, { 120, -165, 22, deep }, { -170, 60, 24, deep }, { 160, 120, 26, deep },
		{ 30, -126, 20, clay }, { -60, 150, 22, deep }, { -110, -40, 18, clay },
		{ -80, 90, 22, pale }, { 90, 70, 24, pale }, { -40, -90, 22, pale }, { 74, -84, 18, pale },
		{ 140, -110, 18, pale }, { -140, 120, 20, pale }, { 0, 140, 24, pale }, { -175, -90, 20, pale },
		{ 120, 175, 16, clay }, { 175, 10, 18, clay },
	})
	patch(arena, 0, 0, 24, mix(P.sand_300, P.sand_200, 0.3), 0.05)
	patch(arena, 3, 2, 13, mix(P.sand_400, P.sand_500, 0.3), 0.07)

	-- caravan tracks
	local core, edge = mix(P.sand_500, P.clay_500, 0.22), mix(P.sand_500, base, 0.5)
	dirtPath(arena, {
		Vector2.new(-262, -30), Vector2.new(-204, -16), Vector2.new(-146, -34), Vector2.new(-90, -12),
		Vector2.new(-42, -8), Vector2.new(0, 0), Vector2.new(46, 6), Vector2.new(98, -6),
		Vector2.new(150, 14), Vector2.new(204, 2), Vector2.new(262, 16),
	}, 7, core, edge, 0.12)
	dirtPath(arena, {
		Vector2.new(14, 262), Vector2.new(4, 200), Vector2.new(22, 140), Vector2.new(6, 88),
		Vector2.new(8, 42), Vector2.new(0, 0), Vector2.new(-6, -40), Vector2.new(-14, -84),
		Vector2.new(-4, -130), Vector2.new(-16, -180), Vector2.new(-8, -230), Vector2.new(-12, -262),
	}, 6, core, edge, 0.16)

	boundaryWalls(arena)

	scatter(arena, 0, 0, 34, 14, { { "Rock_Small", 0.7, 1.1, DESERT_PEBBLE }, { "Rock_Small", 0.8, 1.2, DESERT_PEBBLE }, { "Dune", 0.4, 0.6 } }, 1.2, 0.4)
	scatter(arena, 0, 0, 40, 4, { { "Cactus", 0.45, 0.6 } }, 1.5, 0.5)

	--------------------------------------------------------------------------------------
	-- LANDMARKS (mid ring)

	-- 1. Obelisk court (north): the obelisk facing the clearing, columns around it
	local ox, oz = 28, -78
	obstacle(arena, "Desert_Obelisk", ox, oz, 180, 1.15, nil, { occluder = true }).Name = "Landmark_Obelisk"
	for k = 0, 3 do
		local a = k / 4 * TAU + math.rad(45)
		local px, pz = ox + math.cos(a) * 10, oz + math.sin(a) * 10
		if k == 1 then
			decor(arena, "Desert_Ruin_Pillar", px + 1.5, pz, 90, 0.8, nil, { shadow = true })
		else
			obstacle(arena, "Desert_Ruin_Pillar", px, pz, rng:NextNumber(0, 360), rng:NextNumber(1.0, 1.15), nil, { occluder = true })
		end
	end
	obstacle(arena, "Desert_Ruin_Wall", ox, oz - 15, 0, 1.0, nil, { occluder = true })
	for _, dx in ipairs({ -5.5, 5.5 }) do
		obstacle(arena, "Brazier", ox + dx, oz + 6, 0, 0.9, DESERT_FIRE)
	end
	kitLight(arena, "Brazier", ox - 5.5, oz + 6, 0, 0.9, 15, 1.7, TORCH_FIRE)
	kitLight(arena, "Brazier", ox + 5.5, oz + 6, 0, 0.9, 15, 1.7, TORCH_FIRE)
	for ix = -1, 1 do
		for iz = -1, 1 do
			if (ix + iz) % 2 == 0 then
				slab(arena.Decor, "Paving", W(arena, ox + ix * 5.6, oz + iz * 5.6, 0.1), 5.2, 5.2, math.rad(jitter(3)), pick({ P.sand_300, P.sand_200, mix(P.sand_300, P.clay_500, 0.15) }), 0.1)
			end
		end
	end
	keepout(arena, ox, oz, 15)
	scatter(arena, ox, oz, 22, 6, { { "Rock_Small", 0.8, 1.3, DESERT_PEBBLE }, { "Dune", 0.5, 0.7 } }, 0.6)

	-- 2. Nomad camp (west): two tents facing the track, crates, barrels, torches
	local nx, nz = -74, -40
	obstacle(arena, "Desert_Tent", nx - 4, nz, 160, 0.95, nil, nil)
	obstacle(arena, "Desert_Tent", nx + 6, nz - 4, 200, 0.9, nil, nil)
	obstacle(arena, "Crate", nx + 12, nz + 3, 90, 1.0, DESERT_WOOD)
	prop(arena.Decor, "Crate", CFrame.new(W(arena, nx + 12, nz + 3.1, 2)) * yawCF(25), 0.8, DESERT_WOOD)
	obstacle(arena, "Barrel", nx - 11, nz + 2, 0, 1.0, DESERT_WOOD)
	for _, t in ipairs({ { nx - 3, nz + 8 }, { nx + 7, nz + 7 } }) do
		obstacle(arena, "Torch", t[1], t[2], 0, 1.0, TORCH_FLAME)
	end
	kitLight(arena, "Torch", nx + 2, nz + 7.5, 0, 1.0, 16, 1.8, TORCH_FIRE)
	patch(arena, nx + 1, nz + 1, 10, mix(P.sand_500, P.clay_500, 0.2), 0.05)
	keepout(arena, nx + 1, nz, 14)
	scatter(arena, nx, nz, 18, 5, { { "Rock_Small", 0.8, 1.2, DESERT_PEBBLE }, { "Dune", 0.5, 0.7 } }, 0.6)

	-- 3. Ruined gate (east): two wall stubs and pillars across an old road
	local gx, gz = 86, 34
	obstacle(arena, "Desert_Ruin_Wall", gx, gz - 7, 90, 1.0, nil, { occluder = true })
	obstacle(arena, "Desert_Ruin_Wall", gx, gz + 9, 90, 0.9, nil, { occluder = true })
	obstacle(arena, "Desert_Ruin_Pillar", gx + 0.5, gz + 1, 0, 1.15, nil, { occluder = true })
	decor(arena, "Desert_Ruin_Pillar", gx + 5, gz + 3, 80, 0.8, nil, { shadow = true })
	decor(arena, "Desert_Rock", gx + 9, gz - 10, nil, 0.8, nil, { shadow = true })
	keepout(arena, gx, gz, 12)
	scatter(arena, gx, gz, 16, 5, { { "Rock_Small", 0.8, 1.2, DESERT_PEBBLE }, { "Dune", 0.5, 0.7 }, { "Bones", 0.6, 0.8 } }, 0.5)

	-- 4. Beast bones among rocks and cacti (south-west, low)
	local bx, bz = -56, 56
	decor(arena, "Bones", bx, bz, 25, 2.0, nil, { shadow = true })
	stone(arena, "Desert_Rock", bx - 8, bz - 5, 1.1)
	decor(arena, "Desert_Rock", bx + 7, bz + 6, nil, 0.8, nil, { shadow = true })
	tree(arena, "Cactus", bx + 9, bz - 6, 1.0)
	tree(arena, "Cactus", bx - 6, bz + 8, 0.9)
	keepout(arena, bx, bz, 12)
	scatter(arena, bx, bz, 18, 5, { { "Rock_Small", 0.7, 1.1, DESERT_PEBBLE }, { "Dune", 0.5, 0.7 } }, 0.5)

	--------------------------------------------------------------------------------------
	-- QUICKSAND (hazards)
	for _, q in ipairs({
		{ -50, -104, 1.6, 20 }, { 70, -132, 1.55, 110 }, { 126, 52, 1.6, 60 }, { 52, 104, 1.55, 200 },
		{ -104, 46, 1.6, 140 }, { -150, -64, 1.5, 300 }, { 140, 142, 1.55, 30 },
	}) do
		quicksand(arena, q[1], q[2], q[3], q[4])
	end

	--------------------------------------------------------------------------------------
	-- OUTER RING

	obstacle(arena, "Desert_Mesa", -120, -116, 20, 1.35, nil, { occluder = true }).Name = "Landmark_Mesa"
	stone(arena, "Desert_Rock", -104, -106, 1.1)
	stone(arena, "Desert_Rock", -136, -100, 0.95)
	keepout(arena, -120, -116, 14)
	obstacle(arena, "Desert_Mesa", 160, -44, 200, 1.2, nil, { occluder = true })
	stone(arena, "Desert_Rock", 148, -56, 1.0)
	keepout(arena, 160, -44, 13)

	oasis(arena, -62, -156, 8)

	local C, CT = "Cactus", "Cactus_Tall"
	kitGrove(arena, 130, -112, { { CT, 0, 0, 1.1 }, { C, 8, 5, 1.1 }, { C, -7, 6, 1.0 }, { CT, 5, -8, 0.95 } }, DESERT_SHADE)
	kitGrove(arena, 152, 82, { { CT, 0, 0, 1.15 }, { C, 9, -5, 1.0 }, { C, -6, 8, 1.0 }, { CT, 8, 9, 0.9 } }, DESERT_SHADE)
	kitGrove(arena, -160, -2, { { CT, 0, 0, 1.1 }, { C, -7, 7, 1.0 }, { CT, 8, 4, 1.0 } }, DESERT_SHADE)
	kitGrove(arena, 100, 160, { { C, 0, 0, 1.0 }, { C, 8, 5, 0.9 }, { CT, -6, 8, 0.85 } }, DESERT_SHADE)
	kitGrove(arena, -104, 150, { { CT, 0, 0, 1.0 }, { C, 8, -4, 0.9 }, { C, -7, 6, 0.9 } }, DESERT_SHADE)
	kitGrove(arena, 20, -168, { { CT, 0, 0, 1.1 }, { C, 8, 4, 1.0 }, { C, -8, 5, 1.0 } }, DESERT_SHADE)

	local function sandOutcrop(x: number, z: number, big: number, medium: { number }?)
		stone(arena, "Desert_Rock", x, z, big)
		if medium then
			stone(arena, "Desert_Rock", x + medium[1], z + medium[2], medium[3])
		end
		scatter(arena, x, z, big * 5, 3, { { "Rock_Small", 0.8, 1.3, DESERT_PEBBLE }, { "Dune", 0.5, 0.7 } }, 0.6)
	end
	sandOutcrop(62, -160, 1.5, { 5.5, 3, 1.0 })
	sandOutcrop(178, 8, 1.45, { -4, 5, 1.0 })
	sandOutcrop(-176, 86, 1.5, { 5, -4, 1.0 })
	sandOutcrop(36, 158, 1.4, { -5, -3, 0.95 })
	sandOutcrop(-70, -120, 1.4, { 5, 4, 0.95 })

	-- sandstone ruins (a half-buried house north-east, a wall corner south-west)
	obstacle(arena, "Desert_Ruin_Wall", 104, -156, 0, 1.1, nil, { occluder = true })
	obstacle(arena, "Desert_Ruin_Wall", 113.5, -156.2, 0, 1.1, nil, { occluder = true })
	obstacle(arena, "Desert_Ruin_Wall", 118.4, -150, 90, 1.1, nil, { occluder = true })
	obstacle(arena, "Desert_Ruin_Pillar", 100, -146, 0, 1.0, nil, { occluder = true })
	keepout(arena, 110, -152, 12)
	obstacle(arena, "Desert_Ruin_Wall", -136, 136, 0, 1.0)
	obstacle(arena, "Desert_Ruin_Wall", -140.4, 130, 90, 1.0)
	obstacle(arena, "Desert_Ruin_Pillar", -126, 140, 0, 0.95)
	keepout(arena, -134, 134, 10)

	-- corners
	for _, q in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local south = q[2] == 1
		local cx, cz = q[1] * 172, q[2] * 172
		stone(arena, "Desert_Rock", cx + q[1] * 6, cz - q[2] * 10, 1.35)
		tree(arena, south and C or CT, cx - q[1] * 4, cz + q[2] * 8, south and 1.0 or 1.15)
		decor(arena, "Dune", cx + q[1] * 12, cz + q[2] * 2, nil, 1.2, nil, { shadow = false })
		scatter(arena, cx, cz, 18, 3, DESERT_SHADE, 1)
	end

	for _ = 1, 6 do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(44, 190)
		scatter(arena, math.cos(a) * r, math.sin(a) * r, 6, 2, DESERT_SMALL, 1.5, 0.5)
	end
	for _, d in ipairs({ { -96, 12 }, { 60, -40 }, { 110, 120 }, { -30, 176 }, { 170, -130 }, { -176, -150 } }) do
		decor(arena, "Dune", d[1], d[2], nil, rng:NextNumber(1.1, 1.5), nil, { shadow = false })
	end

	-- BORDER: layered sandstone cliffs on three sides, a low sandstone rim on the camera
	-- side, then mesas and big rocks on the cliff tops
	vignettes(arena, {
		function(a, x, z) campfire(a, x, z, DESERT_PEBBLE) end,
		function(a, x, z) supplies(a, x, z, DESERT_WOOD) end,
		function(a, x, z) cluster(a, x, z, { { "Bones", 0.9, 1.2 }, { "Rock_Small", 0.8, 1.2, DESERT_PEBBLE }, { "Cactus", 0.7, 0.9 } }, 4, 3.5) end,
		function(a, x, z) cluster(a, x, z, { { "Cactus", 0.6, 0.9 }, { "Cactus", 0.5, 0.8 }, { "Rock_Small", 0.8, 1.1, DESERT_PEBBLE } }, 4, 3) end,
		function(a, x, z) decor(a, "Banner", x, z, 180, 1.0); cluster(a, x, z, { { "Crate", 0.7, 0.9, DESERT_WOOD } }, 2, 2.5) end,
		function(a, x, z) cluster(a, x, z, { { "Crystal", 0.7, 1.0 }, { "Desert_Rock", 0.5, 0.7 } }, 3, 2.5) end,
	})
	cliffs(arena, {
		Rock = { P.sand_600, mix(P.sand_600, P.clay_500, 0.45), mix(P.sand_500, P.clay_600, 0.3) },
		Cap = P.sand_400,
		Height = { 14, 22 },
		South = { 2.4, 3.8 },
		Face = { "Desert_Rock", { Rock = P.sand_600, Band = mix(P.sand_600, P.clay_500, 0.55), Top = P.sand_400 } },
		Foot = { { "Cactus", 1.0, 1.3 }, { "Dune", 0.9, 1.2 }, { "Desert_Rock", 0.9, 1.3 } },
	})
	treeLine(arena, {
		{ "Desert_Mesa", 1.2, 1.7, nil },
		{ "Desert_Rock", 1.9, 2.6, nil },
		{ "Cactus_Tall", 1.2, 1.5, nil },
		{ "Desert_Mesa", 1.0, 1.4, nil },
	}, {
		{ "Dune", 1.3, 1.9, nil },
		{ "Desert_Rock", 1.0, 1.4, nil },
	}, 30, mix(P.sand_500, P.sand_600, 0.35))
end

------------------------------------------------------------------------------------------
-- LAVA: a volcanic ash plain (unlocked at stage 6).
--
--   centre      a pale ash clearing where two ash tracks cross (spawn)
--   north       the BRIMSTONE ALTAR with its fire bowl, basalt columns behind it
--   west        a RUINED BASALT FORT: wall runs with glowing seams, an ember vent
--   east        an EMBER FIELD: vents and obsidian shards
--   south-west  low basalt rocks and ash heaps around a small vent
--   mid / outer LAVA POOLS (7, burn 6 / 0.5 s, glowing rims), a lava lake (impassable),
--               basalt column clusters, charred tree stands, basalt outcrops
--   border      basalt columns and charred trees, low rocks and ash on the camera side
------------------------------------------------------------------------------------------

local LAVA_PEBBLE: Pal = { Stone = P.cinder_500 }
local EMBER = rgb(255, 150, 80)
local LAVA_SMALL = {
	{ "Ash_Pile", 0.8, 1.2 },
	{ "Ash_Pile", 0.8, 1.2 },
	{ "Rock_Small", 0.8, 1.2, LAVA_PEBBLE },
}
local LAVA_SHADE = {
	{ "Ash_Pile", 0.9, 1.3 },
	{ "Rock_Small", 0.8, 1.3, LAVA_PEBBLE },
}

-- Lava lake: a big pool behind a ring of basalt rocks (impassable, one circle collider).
local function lavaLake(arena: Arena, x: number, z: number, r: number)
	local m = arena.Model
	disc(arena.Decor, "Crust", W(arena, x, z, 0.06), r + 3, P.basalt_800)
	prop(m, "Lava_Pool", CFrame.new(W(arena, x, z, 0.05)) * yawCF(30), r / 3.6, nil, { shadow = false }).Name = "LavaLake"
	local glow = disc(m, "HazardGlow", W(arena, x, z, 0.04), r + 1.6, P.lava_500, 0.06)
	glow.Material = NEON
	glow.Transparency = 0.5
	CollectionService:AddTag(glow, HAZARD_GLOW_TAG)
	pointLight(m, W(arena, x, z, 4), 26, 1.4, P.lava_300, true)
	arena.Lights += 1
	-- the rim rocks say "wall", not "pool"
	for k = 0, 8 do
		local a = k / 9 * TAU + jitter(0.15)
		decor(arena, "Basalt_Rock", x + math.cos(a) * (r + 2.4), z + math.sin(a) * (r + 2.4), nil, rng:NextNumber(0.9, 1.25), nil, { shadow = true })
	end
	local wp = W(arena, x, z)
	circleCollider(arena, wp.X, wp.Z, r + 1.2, 4)
	keepout(arena, x, z, r + 5)
end

local function buildLava(arena: Arena)
	arena.DecorDensity = 0.7
	arena.PortalPalette = { Moss = P.ash_300 }
	local base = mix(P.cinder_400, P.cinder_500, 0.35)
	biomeGround(arena, P.cinder_600, base)
	local dark, pale, ash = mix(P.cinder_500, P.cinder_600, 0.4), mix(P.cinder_300, P.cinder_200, 0.35), mix(P.cinder_400, P.cinder_500, 0.6)
	groundPatches(arena, {
		{ -150, -150, 26, dark }, { 120, -165, 22, dark }, { -170, 60, 24, dark }, { 160, 120, 26, dark },
		{ 30, -126, 20, ash }, { -60, 150, 22, dark }, { -110, -40, 18, ash },
		{ -80, 90, 22, pale }, { 90, 70, 24, pale }, { -40, -90, 22, ash }, { 74, -84, 18, pale },
		{ 140, -110, 18, pale }, { -140, 120, 20, ash }, { 0, 140, 24, pale }, { -175, -90, 20, pale },
		{ 120, 175, 16, ash }, { 175, 10, 18, dark },
	})
	patch(arena, 0, 0, 24, mix(P.cinder_300, P.cinder_400, 0.4), 0.05)
	patch(arena, 3, 2, 13, mix(P.cinder_300, P.cinder_200, 0.3), 0.07)

	-- ash tracks
	local core, edge = mix(P.cinder_200, P.cinder_300, 0.3), mix(P.cinder_300, base, 0.5)
	dirtPath(arena, {
		Vector2.new(-262, 26), Vector2.new(-200, 10), Vector2.new(-142, 28), Vector2.new(-90, 10),
		Vector2.new(-40, 4), Vector2.new(0, 0), Vector2.new(44, -10), Vector2.new(94, -2),
		Vector2.new(144, -20), Vector2.new(202, -8), Vector2.new(262, -20),
	}, 7, core, edge, 0.12)
	dirtPath(arena, {
		Vector2.new(-20, 262), Vector2.new(-12, 194), Vector2.new(-28, 134), Vector2.new(-8, 84),
		Vector2.new(-6, 40), Vector2.new(0, 0), Vector2.new(10, -34), Vector2.new(-6, -80),
		Vector2.new(-20, -124), Vector2.new(-4, -170), Vector2.new(-12, -214), Vector2.new(-6, -262),
	}, 6, core, edge, 0.16)

	boundaryWalls(arena)

	scatter(arena, 0, 0, 34, 14, { { "Ash_Pile", 0.7, 1.1 }, { "Rock_Small", 0.7, 1.1, LAVA_PEBBLE }, { "Rock_Small", 0.8, 1.2, LAVA_PEBBLE } }, 1.2, 0.4)

	--------------------------------------------------------------------------------------
	-- LANDMARKS (mid ring)

	-- 1. Brimstone altar (north) facing the clearing, basalt columns and obsidian behind
	local ax, az = 28, -72
	obstacle(arena, "Brimstone_Altar", ax, az, 180, 1.15, nil, { occluder = true }).Name = "Landmark_Altar"
	kitLight(arena, "Brimstone_Altar", ax, az, 180, 1.15, 20, 1.6, FIRE)
	obstacle(arena, "Basalt_Column", ax + 4, az - 13, 20, 1.0, nil, { occluder = true })
	obstacle(arena, "Obsidian_Crystal", ax - 9, az - 7, 40, 1.1)
	obstacle(arena, "Obsidian_Crystal", ax + 11, az - 3, 200, 0.95)
	keepout(arena, ax, az, 14)
	scatter(arena, ax, az, 20, 6, { { "Ash_Pile", 0.9, 1.3 }, { "Rock_Small", 0.8, 1.2, LAVA_PEBBLE } }, 0.6)

	-- 2. Ruined basalt fort (west): an L of walls with glowing seams and a vent
	local fx, fz = -74, -36
	for i = 0, 2 do
		obstacle(arena, "Lava_Ruin_Wall", fx - 8 + i * 7.8, fz - 8, 0, 1.0, nil, { occluder = true })
	end
	obstacle(arena, "Lava_Ruin_Wall", fx - 12, fz - 0.5, 90, 1.0, nil, { occluder = true })
	obstacle(arena, "Ember_Vent", fx + 4, fz + 2, 0, 1.1)
	kitLight(arena, "Ember_Vent", fx + 4, fz + 2, 0, 1.1, 14, 1.2, EMBER)
	stone(arena, "Basalt_Rock", fx + 13, fz - 3, 0.9)
	keepout(arena, fx, fz - 3, 13)
	scatter(arena, fx, fz, 18, 6, { { "Ash_Pile", 0.9, 1.3 }, { "Rock_Small", 0.8, 1.2, LAVA_PEBBLE } }, 0.6)

	-- 3. Ember field (east): vents and obsidian shards in a loose ring
	local ex, ez = 88, 30
	for k = 0, 5 do
		local a = k / 6 * TAU + 0.3
		local px, pz = ex + math.cos(a) * 9, ez + math.sin(a) * 9
		if k % 2 == 0 then
			obstacle(arena, "Ember_Vent", px, pz, rng:NextNumber(0, 360), rng:NextNumber(1.0, 1.15))
		else
			obstacle(arena, "Obsidian_Crystal", px, pz, rng:NextNumber(0, 360), rng:NextNumber(0.95, 1.15))
		end
	end
	kitLight(arena, "Ember_Vent", ex + math.cos(0.3) * 9, ez + math.sin(0.3) * 9, 0, 1.0, 14, 1.1, EMBER)
	pointLight(arena.Model, W(arena, ex, ez, 3), 14, 0.8, EMBER, true)
	arena.Lights += 1
	keepout(arena, ex, ez, 11)
	scatter(arena, ex, ez, 14, 5, { { "Ash_Pile", 0.9, 1.3 }, { "Rock_Small", 0.8, 1.1, LAVA_PEBBLE } }, 0.5)

	-- 4. Basalt rocks and ash heaps around a small vent (south-west, low)
	local sx, sz = -56, 56
	stone(arena, "Basalt_Rock", sx - 7, sz - 4, 1.1)
	stone(arena, "Basalt_Rock", sx + 6, sz + 6, 0.95)
	stone(arena, "Basalt_Rock", sx + 8, sz - 7, 0.8)
	obstacle(arena, "Ember_Vent", sx, sz, 0, 1.0)
	decor(arena, "Ash_Pile", sx - 4, sz + 6, nil, 1.6, nil, { shadow = false })
	keepout(arena, sx, sz, 12)
	scatter(arena, sx, sz, 18, 5, LAVA_SHADE, 0.5)

	--------------------------------------------------------------------------------------
	-- LAVA POOLS (hazards: burn)
	for i, lp in ipairs({
		{ -56, -102, 1.5, 20 }, { 72, -124, 1.45, 110 }, { 124, 50, 1.5, 60 }, { 48, 106, 1.45, 200 },
		{ -106, 58, 1.5, 140 }, { 152, -88, 1.4, 300 }, { -140, 150, 1.45, 30 },
	}) do
		lavaPool(arena, lp[1], lp[2], lp[3], lp[4], i <= 4)
	end

	--------------------------------------------------------------------------------------
	-- OUTER RING

	lavaLake(arena, -118, -150, 10)

	for _, bc in ipairs({ { -128, -96, 1.2, 0 }, { 156, -38, 1.15, 70 }, { 138, 138, 1.05, 140 }, { -170, 18, 1.15, 200 } }) do
		obstacle(arena, "Basalt_Column", bc[1], bc[2], bc[4], bc[3], nil, { occluder = true })
		scatter(arena, bc[1], bc[2], 10, 3, LAVA_SHADE, 0.8)
	end

	local CT = "Charred_Tree"
	kitGrove(arena, -48, -158, { { CT, 0, 0, 1.15 }, { CT, 9, 6, 1.0 }, { CT, -8, 7, 0.95 }, { CT, 4, -10, 1.05 } }, LAVA_SHADE)
	kitGrove(arena, 116, -150, { { CT, 0, 0, 1.15 }, { CT, 10, 5, 1.0 }, { CT, -9, 8, 0.95 }, { CT, 6, -9, 1.0 } }, LAVA_SHADE)
	kitGrove(arena, 160, 80, { { CT, 0, 0, 1.1 }, { CT, 11, -5, 1.0 }, { CT, -6, 9, 0.95 } }, LAVA_SHADE)
	kitGrove(arena, -164, -48, { { CT, 0, 0, 1.15 }, { CT, -8, 8, 1.0 }, { CT, 9, 4, 1.0 } }, LAVA_SHADE)
	kitGrove(arena, 96, 156, { { CT, 0, 0, 0.9 }, { CT, 9, 6, 0.8 } }, LAVA_SHADE)

	local function basaltOutcrop(x: number, z: number, big: number, medium: { number }?)
		stone(arena, "Basalt_Rock", x, z, big)
		if medium then
			stone(arena, "Basalt_Rock", x + medium[1], z + medium[2], medium[3])
		end
		scatter(arena, x, z, big * 5, 3, LAVA_SHADE, 0.6)
	end
	basaltOutcrop(62, -160, 1.5, { 5.5, 3, 1.0 })
	basaltOutcrop(178, 6, 1.45, { -4, 5, 1.0 })
	basaltOutcrop(-176, 92, 1.5, { 5, -4, 1.0 })
	basaltOutcrop(30, 160, 1.4, { -5, -3, 0.95 })
	basaltOutcrop(-80, -126, 1.4, { 5, 4, 0.95 })
	basaltOutcrop(-112, 112, 1.4, { -5, 4, 1.0 })

	-- obsidian outcrops (a little glow)
	for i, oc in ipairs({ { 112, -96, 1.3 }, { -150, 112, 1.2 }, { 24, -178, 1.25 } }) do
		obstacle(arena, "Obsidian_Crystal", oc[1], oc[2], rng:NextNumber(0, 360), oc[3])
		decor(arena, "Obsidian_Crystal", oc[1] + 2.6, oc[2] + 1.4, nil, oc[3] * 0.55, nil, { shadow = false })
		if i == 1 then
			kitLight(arena, "Obsidian_Crystal", oc[1], oc[2], 0, oc[3], 12, 0.9, EMBER)
		end
	end

	-- a broken outpost (north-east)
	obstacle(arena, "Lava_Ruin_Wall", 40, -176, 0, 1, nil, { occluder = true })
	obstacle(arena, "Lava_Ruin_Wall", 48.7, -176.2, 0, 1, nil, { occluder = true })
	obstacle(arena, "Lava_Ruin_Wall", 53.4, -170.6, 90, 1, nil, { occluder = true })
	keepout(arena, 46, -172, 10)

	-- corners
	for _, q in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		local south = q[2] == 1
		local bx, bz = q[1] * 172, q[2] * 172
		stone(arena, "Basalt_Rock", bx + q[1] * 6, bz - q[2] * 10, 1.35)
		if not south then
			tree(arena, CT, bx - q[1] * 4, bz + q[2] * 8, 1.1)
		end
		scatter(arena, bx, bz, 18, 3, LAVA_SHADE, 1)
	end

	for _ = 1, 6 do
		local a, r = rng:NextNumber(0, TAU), rng:NextNumber(44, 190)
		scatter(arena, math.cos(a) * r, math.sin(a) * r, 6, 2, LAVA_SMALL, 1.5, 0.5)
	end

	-- BORDER: black basalt cliffs with glowing cracks at their foot on three sides, a low
	-- basalt rim on the camera side, then columns and charred trees on the cliff tops
	vignettes(arena, {
		function(a, x, z) cluster(a, x, z, { { "Obsidian_Crystal", 0.7, 1.1 }, { "Basalt_Rock", 0.5, 0.7 } }, 4, 3) end,
		function(a, x, z) cluster(a, x, z, { { "Bones", 0.9, 1.2 }, { "Ash_Pile", 1.0, 1.4 }, { "Rock_Small", 0.8, 1.1, LAVA_PEBBLE } }, 4, 3.5) end,
		function(a, x, z) cluster(a, x, z, { { "Charred_Tree", 0.5, 0.7 }, { "Ash_Pile", 1.0, 1.4 } }, 3, 3) end,
		function(a, x, z) supplies(a, x, z, { Wood = P.wood_700, Frame = P.basalt_700, Iron = P.steel_700, Lid = P.wood_700 }) end,
		function(a, x, z) cluster(a, x, z, { { "Obsidian_Crystal", 0.5, 0.9 }, { "Obsidian_Crystal", 0.8, 1.2 } }, 3, 2.5) end,
	})
	cliffs(arena, {
		Rock = { P.basalt_700, P.basalt_600, mix(P.basalt_700, P.cinder_600, 0.4) },
		Cap = mix(P.cinder_500, P.ash_400, 0.3),
		Height = { 12, 20 },
		South = { 2.4, 3.6 },
		Seam = P.lava_500,
		Face = { "Basalt_Rock", { Stone = P.basalt_700, Stone2 = P.basalt_600, Ash = mix(P.cinder_500, P.ash_400, 0.3) } },
		Foot = { { "Obsidian_Crystal", 1.0, 1.4 }, { "Ash_Pile", 1.4, 2.0 }, { "Basalt_Rock", 1.0, 1.4 } },
	})
	treeLine(arena, {
		{ "Basalt_Column", 1.15, 1.6, nil },
		{ "Charred_Tree", 1.25, 1.6, nil },
		{ "Basalt_Rock", 1.7, 2.3, nil },
	}, {
		{ "Basalt_Rock", 1.0, 1.4, nil },
		{ "Ash_Pile", 1.6, 2.2, nil },
	}, 28, mix(P.cinder_600, P.basalt_600, 0.5))
end

------------------------------------------------------------------------------------------

local BUILDERS: { [string]: (Arena) -> () } = {
	Forest = buildForest,
	Ruins = buildRuins,
	Swamp = buildSwamp,
	Snow = buildSnow,
	Desert = buildDesert,
	Lava = buildLava,
}

-- Builds an arena by name, destroying the previous one. `variant` (stage - 1) re-seeds
-- the scattered decoration so later stages look a little different; 0 = the classic map.
-- Floor layout for the client ground detail (src/client/GroundDetail.lua), as compact
-- attributes on the arena model (arena-relative studs, one decimal): path segments
-- "ax,az,bx,bz,halfWidth;...", and "x,z,r;..." circles of landmark keepouts, bare floor
-- and hazard pools. Colliders are read from the Obstacles folder, so they are not repeated.
local function writeDetailLayout(arena: Arena)
	local c = arena.Center
	local function num(v: number): string
		return string.format("%.1f", v)
	end
	local paths = {}
	for _, seg in ipairs(arena.Paths) do
		table.insert(paths, num(seg.A.X) .. "," .. num(seg.A.Z) .. "," .. num(seg.B.X) .. "," .. num(seg.B.Z) .. "," .. num(seg.W))
	end
	local circles = {}
	for _, k in ipairs(arena.Keepout) do
		table.insert(circles, num(k.X) .. "," .. num(k.Z) .. "," .. num(k.R))
	end
	for _, b in ipairs(arena.Bare) do
		table.insert(circles, num(b.X) .. "," .. num(b.Z) .. "," .. num(b.R))
	end
	for _, hz in ipairs(arena.Hazards) do
		table.insert(circles, num(hz.Pos.X - c.X) .. "," .. num(hz.Pos.Z - c.Z) .. "," .. num(hz.Radius + 2))
	end
	arena.Model:SetAttribute("DetailPaths", table.concat(paths, ";"))
	arena.Model:SetAttribute("DetailBare", table.concat(circles, ";"))
	arena.Model:SetAttribute("Cliffs", arena.Cliff ~= nil)
end

function MapBuilder.BuildArena(name: string, variant: number?)
	MapBuilder.DestroyArena()
	rng = Random.new((SEEDS[name] or SEEDS.Forest) + (variant or 0) * 7919)
	local arena = newArena(name)
	local build = BUILDERS[name] or buildForest
	build(arena)
	writeDetailLayout(arena)
	arena.Model.Parent = arena.Root
	MapBuilder.ApplyLighting(name)
	currentArena = arena
	return arena
end

------------------------------------------------------------------------------------------
-- STAGE PORTAL
------------------------------------------------------------------------------------------

--[[
	A random clear spot for the stage portal (rejection sampling, world position on the
	floor): inside the fence by Config.Stages.PortalEdgeMargin, at least PortalMinDistance
	from the spawn centre, PortalClearance from every collider / landmark keepout, and
	PortalRepeatDistance from `avoid` (the last portal in this arena). The rules relax step
	by step if nothing fits; the last resort is a fixed spot on the north side.
]]
local HAZARD_PAD: number = ((Config.Arenas :: any).Hazards or {}).LootPad or 4

function MapBuilder.FindPortalSpot(arena: Arena, rand: Random, avoid: Vector3?): Vector3
	local S = Config.Stages
	local half = arena.Half - S.PortalEdgeMargin
	local c = arena.Center
	local function try(minDist: number, clear: number, avoidDist: number): Vector3?
		for _ = 1, 400 do
			local x, z = rand:NextNumber(-half, half), rand:NextNumber(-half, half)
			if math.sqrt(x * x + z * z) >= minDist and isFree(arena, x, z, clear, nil, HAZARD_PAD) then
				local far = true
				if avoid and avoidDist > 0 then
					local dx, dz = c.X + x - avoid.X, c.Z + z - avoid.Z
					far = dx * dx + dz * dz >= avoidDist * avoidDist
				end
				if far then
					return W(arena, x, z)
				end
			end
		end
		return nil
	end
	return try(S.PortalMinDistance, S.PortalClearance, S.PortalRepeatDistance)
		or try(S.PortalMinDistance, S.PortalClearance, 0)
		or try(S.PortalMinDistance * 0.8, S.PortalClearance * 0.6, 0)
		or W(arena, 0, -(arena.Half - S.PortalEdgeMargin))
end

-- Portal looks per state (UI and world share the palette).
local PORTAL_LOOK = {
	Idle = { Surface = P.slate_400, SurfaceT = 0.3, Glyph = P.fx_arcane, Beam = P.fx_arcane, BeamT = 0.86, Core = P.slate_200, Light = P.fx_arcane, Bright = 1.2, Mark = P.slate_300, MarkT = 0.35 },
	Charged = { Surface = P.gold_300, SurfaceT = 0.2, Glyph = P.gold_300, Beam = P.gold_300, BeamT = 0.8, Core = P.gold_200, Light = P.gold_300, Bright = 2, Mark = P.gold_400, MarkT = 0.1 },
	Boss = { Surface = P.crimson_600, SurfaceT = 0.22, Glyph = P.crimson_300, Beam = P.crimson_400, BeamT = 0.84, Core = P.crimson_300, Light = P.crimson_400, Bright = 1.6, Mark = P.crimson_400, MarkT = 0.25 },
	Surge = { Surface = P.crimson_500, SurfaceT = 0.15, Glyph = P.crimson_300, Beam = P.crimson_400, BeamT = 0.78, Core = P.crimson_300, Light = P.crimson_400, Bright = 2.2, Mark = P.crimson_300, MarkT = 0.15 },
	Open = { Surface = P.gold_200, SurfaceT = 0.15, Glyph = P.ivory_100, Beam = P.gold_300, BeamT = 0.74, Core = P.ivory_100, Light = P.gold_300, Bright = 2.4, Mark = P.gold_300, MarkT = 0.05 },
}

local function lerpLook(a, b, t: number)
	local out = {}
	for k, v in pairs(a) do
		local w = b[k]
		if typeof(v) == "Color3" then
			out[k] = (v :: Color3):Lerp(w, t)
		else
			out[k] = v + (w - v) * t
		end
	end
	return out
end

export type Portal = {
	Model: Model,
	Pos: Vector3,
	Radius: number,
	SetState: (state: string, charge: number?) -> (),
}

--[[
	Builds the stage portal at `pos` (floor point), facing the run camera (south). Adds
	its plinth colliders to the arena (call before EnemyAI.SetArena). Extras built here:
	a dashed rune circle on the floor showing where to stand (Config.Stages.PortalRadius;
	its marks light up with the charge), a tall soft light beam and a PointLight.
	SetState("Idle" | "Charging" | "Boss" | "Surge" | "Open", charge) recolors all of it.
]]
function MapBuilder.BuildPortal(arena: Arena, pos: Vector3): Portal
	local S = Config.Stages
	local cf = CFrame.new(pos) * yawCF(180) -- the mesh's front (-Z) turned toward the camera
	local model = prop(arena.Model, "Portal", cf, 1, arena.PortalPalette, { occluder = true }) -- biome moss / snow / sand tint
	kitCollider(arena, "Portal", cf, 1)
	table.insert(arena.Keepout, { X = pos.X - arena.Center.X, Z = pos.Z - arena.Center.Z, R = S.PortalRadius })
	-- scattered clutter (grass, ferns, bushes) would poke through the dais and the circle
	for _, d in ipairs(arena.Decor:GetChildren()) do
		if d:IsA("Model") and #d:GetChildren() > 0 then
			local at = d:GetPivot().Position
			local dx, dz = at.X - pos.X, at.Z - pos.Z
			if dx * dx + dz * dz < (S.PortalRadius + 1) ^ 2 then
				d:Destroy()
			end
		end
	end

	local fx = Instance.new("Folder")
	fx.Name = "PortalFx"
	fx.Parent = arena.Model
	local marks: { BasePart } = {}
	local n = 24
	local radius = S.PortalRadius
	for i = 1, n do
		local a = (i - 0.5) / n * TAU
		local at = Vector3.new(pos.X + math.cos(a) * radius, pos.Y + 0.08, pos.Z + math.sin(a) * radius)
		local mark = slab(fx, "RuneMark", at, 0.55, TAU * radius / n * 0.55, -a, P.slate_300, 0.12)
		mark.Transparency = 0.35
		table.insert(marks, mark)
	end
	local lightAt = kitLightPoint("Portal", cf, 1) or (pos + Vector3.new(0, 6, 0))
	local light = pointLight(fx, lightAt, 26, 1.2, P.fx_arcane, false)
	arena.Lights += 1
	local beamH = 70
	local beam = deco(fx, {
		Name = "Beam",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(beamH, 4.4, 4.4),
		CFrame = CFrame.new(pos + Vector3.new(0, 6 + beamH / 2, 0)) * UPRIGHT,
		Color = P.fx_arcane,
		Transparency = 0.86,
		CastShadow = false,
	})
	local core = deco(fx, {
		Name = "BeamCore",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(beamH, 1.4, 1.4),
		CFrame = CFrame.new(pos + Vector3.new(0, 6 + beamH / 2, 0)) * UPRIGHT,
		Color = P.slate_200,
		Transparency = 0.7,
		CastShadow = false,
	})

	local lastKey = ""
	local lastState, lastCharge = "Idle", 0
	local function setState(state: string, charge: number?)
		local c = math.clamp(charge or 0, 0, 1)
		lastState, lastCharge = state, c
		local key = state .. "|" .. tostring(math.floor(c * n))
		if key == lastKey then
			return
		end
		lastKey = key
		local look
		if state == "Charging" then
			look = lerpLook(PORTAL_LOOK.Idle, PORTAL_LOOK.Charged, c)
		else
			look = PORTAL_LOOK[state] or PORTAL_LOOK.Idle
		end
		-- the mesh may have replaced the fallback since the last call: look parts up again
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				if d.Name == "Surface" then
					d.Color = look.Surface
					d.Transparency = look.SurfaceT
				elseif d.Name == "Glyphs" then
					d.Color = look.Glyph
				end
			end
		end
		beam.Color = look.Beam
		beam.Transparency = look.BeamT
		core.Color = look.Core
		light.Color = look.Light
		light.Brightness = look.Bright
		local lit = state == "Charging" and math.floor(c * n) or (state == "Idle" and 0 or n)
		for i, mark in ipairs(marks) do
			local on = i <= lit
			mark.Color = on and (state == "Charging" and P.gold_300 or look.Mark) or PORTAL_LOOK.Idle.Mark
			mark.Transparency = on and 0.05 or PORTAL_LOOK.Idle.MarkT
		end
	end
	setState("Idle", 0)
	-- the uploaded mesh may replace the part fallback later (prop() registered that swap
	-- first, so this runs after it): paint the new pieces in the current state
	if MeshService.MayLoad("Portal") then
		whenMeshLoads("Portal", function()
			if model.Parent then
				lastKey = ""
				setState(lastState, lastCharge)
			end
		end)
	end
	return {
		Model = model,
		Pos = pos,
		Radius = radius,
		SetState = setState,
	}
end

------------------------------------------------------------------------------------------
-- LOOT SPOTS AND PROPS (LootSystem)
------------------------------------------------------------------------------------------

export type SpotOpts = {
	MinDistance: number?, -- from the arena centre (the spawn)
	EdgeMargin: number?, -- inside the fence
	Clearance: number?, -- free radius (colliders, landmarks, ponds)
	Spacing: number?, -- from every point in Avoid
	Avoid: { Vector3 }?,
	PathPad: number?, -- keep off the dirt paths by this much (nil = paths are fine)
	KeepFrom: Vector3?, -- a hard keep-out point (the portal), never relaxed with Spacing
	KeepRadius: number?, -- studs from KeepFrom
}

--[[
	A random clear floor spot (world position) for a loot object: rejection sampling like
	FindPortalSpot. Spacing relaxes step by step if the map is full; nil when nothing fits.
]]
function MapBuilder.FindOpenSpot(arena: Arena, rand: Random, opts: SpotOpts): Vector3?
	local half = arena.Half - (opts.EdgeMargin or 16)
	local minDist = opts.MinDistance or 0
	local clear = opts.Clearance or 3
	local avoid = opts.Avoid or {}
	local c = arena.Center
	local keep = opts.KeepFrom
	local keep2 = (opts.KeepRadius or 0) ^ 2
	local function try(spacing: number, tries: number): Vector3?
		for _ = 1, tries do
			local x, z = rand:NextNumber(-half, half), rand:NextNumber(-half, half)
			if math.sqrt(x * x + z * z) >= minDist and isFree(arena, x, z, clear, opts.PathPad, HAZARD_PAD) then
				local ok = true
				if keep then
					local kx, kz = c.X + x - keep.X, c.Z + z - keep.Z
					ok = kx * kx + kz * kz >= keep2
				end
				for _, a in ipairs(avoid) do
					local dx, dz = c.X + x - a.X, c.Z + z - a.Z
					if dx * dx + dz * dz < spacing * spacing then
						ok = false
						break
					end
				end
				if ok then
					return W(arena, x, z)
				end
			end
		end
		return nil
	end
	local spacing = opts.Spacing or 0
	return try(spacing, 300) or try(spacing * 0.6, 300) or try(spacing * 0.35, 300)
end

-- A kit prop under `parent` (the mesh, or the part fallback until it loads).
function MapBuilder.PlaceProp(parent: Instance, name: string, cf: CFrame, scale: number?, palette: Pal?, opts: PropOpts?): Model
	return prop(parent, name, cf, scale, palette, opts)
end

-- An obstacle collider: a catalog model's Collider (by name) or a shape table
-- { Kind = "Circle", Radius, Height } / { Kind = "Box", Size = {x, z}, Height }.
-- Register before EnemyAI.SetArena so the enemies' obstacle grid knows it.
function MapBuilder.AddCollider(arena: Arena, what: any, cf: CFrame, scale: number?)
	if type(what) == "string" then
		kitCollider(arena, what, cf, scale or 1)
	elseif type(what) == "table" then
		addShape(arena, what, cf, scale or 1)
	end
	local pos = cf.Position
	table.insert(arena.Keepout, { X = pos.X - arena.Center.X, Z = pos.Z - arena.Center.Z, R = 3 })
end

-- Removes scattered decoration (grass, ferns, bushes) within `radius` of `pos`, so it
-- doesn't poke through a chest or an altar.
function MapBuilder.ClearDecor(arena: Arena, pos: Vector3, radius: number)
	for _, d in ipairs(arena.Decor:GetChildren()) do
		if d:IsA("Model") and #d:GetChildren() > 0 then
			local at = d:GetPivot().Position
			local dx, dz = at.X - pos.X, at.Z - pos.Z
			if dx * dx + dz * dz < radius * radius then
				d:Destroy()
			end
		end
	end
end

-- The part-built fallback of a kit model (nil when there is none).
function MapBuilder.FallbackFor(name: string): ((Model, CFrame, number, { [string]: Color3 }, boolean) -> ())?
	return FALLBACK[name]
end

-- True when the catalog has (and may load) a mesh model with this name.
function MapBuilder.HasKit(name: string): boolean
	return kitEntry(name) ~= nil
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
