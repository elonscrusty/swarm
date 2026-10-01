--[[
	MapBuilder.lua
	Procedurally builds the lobby and the two arenas from Parts.

	BuildLobby()        → lobby table (boards, start pad, spawn), built once at boot
	BuildArena(name)    → arena table, replaces any previous arena
	DestroyArena()
	ApplyLighting(name) → "Lobby" | "Forest" | "Ruins"

	Every collidable arena obstacle is also recorded as a simple shape in
	arena.Obstacles so EnemyAI can push enemies out of them cheaply:
	  { Kind = "Circle", Pos = Vector3, Radius = r }
	  { Kind = "Box", Pos = centre, Radius = halfDiagonal, MinX, MaxX, MinZ, MaxZ }
	Obstacle Parts live in arena.ObstacleFolder (the only thing enemy raycasts hit).
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
-- LIGHTING
------------------------------------------------------------------------------------------

function MapBuilder.ApplyLighting(name: string)
	if name == "Ruins" then
		-- golden late afternoon
		Lighting.ClockTime = 16.8
		Lighting.Brightness = 2.2
		Lighting.Ambient = Color3.fromRGB(110, 95, 120)
		Lighting.OutdoorAmbient = Color3.fromRGB(150, 130, 150)
		Lighting.FogEnd = 100000
	elseif name == "Lobby" then
		Lighting.ClockTime = 17.5
		Lighting.Brightness = 2
		Lighting.Ambient = Color3.fromRGB(120, 105, 95)
		Lighting.OutdoorAmbient = Color3.fromRGB(150, 130, 115)
		Lighting.FogEnd = 100000
	else -- Forest: bright day
		Lighting.ClockTime = 13.5
		Lighting.Brightness = 2.6
		Lighting.Ambient = Color3.fromRGB(100, 100, 105)
		Lighting.OutdoorAmbient = Color3.fromRGB(140, 140, 140)
		Lighting.FogEnd = 100000
	end
end

------------------------------------------------------------------------------------------
-- LOBBY
------------------------------------------------------------------------------------------

function MapBuilder.BuildLobby()
	local root = ensureMapFolder()
	local folder = Instance.new("Model")
	folder.Name = "Lobby"
	folder.Parent = root

	local o = Config.Lobby.Origin
	local size = Config.Lobby.Size
	local half = size / 2
	local wallH = Config.Lobby.WallHeight

	local function add(p: BasePart): BasePart
		p.Parent = folder
		return p
	end

	-- Floor: castle courtyard flagstones.
	add(part({ Name = "Floor", Size = Vector3.new(size, 2, size), CFrame = CFrame.new(o + Vector3.new(0, -1, 0)), Color = Color3.fromRGB(150, 146, 140), Material = Enum.Material.Slate, CanCollide = true, CanQuery = true }))
	-- Rug in the middle.
	add(part({ Name = "Rug", Size = Vector3.new(26, 0.1, 18), CFrame = CFrame.new(o + Vector3.new(0, 0.05, 4)), Color = Color3.fromRGB(150, 50, 60), Material = Enum.Material.Fabric }))
	add(part({ Name = "RugBorder", Size = Vector3.new(28, 0.08, 20), CFrame = CFrame.new(o + Vector3.new(0, 0.03, 4)), Color = Color3.fromRGB(230, 190, 90), Material = Enum.Material.Fabric }))

	-- Walls (low so the top-down camera can see over them) + tall invisible barriers.
	local wallColor = Color3.fromRGB(140, 138, 134)
	for _, w in ipairs({
		{ Vector3.new(0, wallH / 2, -half), Vector3.new(size + 2, wallH, 2) },
		{ Vector3.new(0, wallH / 2, half), Vector3.new(size + 2, wallH, 2) },
		{ Vector3.new(-half, wallH / 2, 0), Vector3.new(2, wallH, size + 2) },
		{ Vector3.new(half, wallH / 2, 0), Vector3.new(2, wallH, size + 2) },
	}) do
		add(part({ Name = "Wall", Size = w[2], CFrame = CFrame.new(o + w[1]), Color = wallColor, Material = Enum.Material.Cobblestone, CanCollide = true }))
		local barrier = add(part({ Name = "Barrier", Size = Vector3.new(w[2].X, 40, w[2].Z), CFrame = CFrame.new(o + Vector3.new(w[1].X, 20, w[1].Z)), Transparency = 1, CanCollide = true }))
		barrier.CastShadow = false
	end
	-- Battlements along the top of the walls.
	for t = -half, half, 6 do
		for _, pos in ipairs({ Vector3.new(t, 0, -half), Vector3.new(t, 0, half), Vector3.new(-half, 0, t), Vector3.new(half, 0, t) }) do
			add(part({ Name = "Merlon", Size = Vector3.new(2.6, 1.8, 2.6), CFrame = CFrame.new(o + pos + Vector3.new(0, wallH + 0.9, 0)), Color = Color3.fromRGB(150, 148, 144), Material = Enum.Material.Cobblestone }))
		end
	end

	-- Corner lamps for a cosy glow.
	for _, c in ipairs({ Vector3.new(-half + 4, 0, -half + 4), Vector3.new(half - 4, 0, -half + 4), Vector3.new(-half + 4, 0, half - 4), Vector3.new(half - 4, 0, half - 4) }) do
		add(part({ Name = "LampPost", Shape = Enum.PartType.Cylinder, Size = Vector3.new(6, 0.5, 0.5), CFrame = CFrame.new(o + c + Vector3.new(0, 3, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(60, 50, 40), CanCollide = true }))
		local shade = add(part({ Name = "LampShade", Shape = Enum.PartType.Ball, Size = Vector3.new(2, 2, 2), CFrame = CFrame.new(o + c + Vector3.new(0, 6.5, 0)), Color = Color3.fromRGB(255, 220, 160), Material = Enum.Material.Neon }))
		local light = Instance.new("PointLight")
		light.Range = 22
		light.Brightness = 1.6
		light.Color = Color3.fromRGB(255, 200, 140)
		light.Parent = shade
	end
	-- START PADS (north): SQUAD (1-4 players) on the left, DUO (exactly 2) on the right.
	local function startPad(name: string, x: number, color: Color3, ringColor: Color3, title: string, objectText: string)
		local padPos = o + Vector3.new(x, 0.15, -half + 12)
		local pad = add(part({ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 10, 10), CFrame = CFrame.new(padPos) * CFrame.Angles(0, 0, math.rad(90)), Color = color, Material = Enum.Material.Neon, CanQuery = true }))
		add(part({ Name = name .. "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 12, 12), CFrame = CFrame.new(padPos - Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = ringColor }))
		local sign = add(part({ Name = name .. "Sign", Size = Vector3.new(10, 3, 0.4), CFrame = CFrame.new(o + Vector3.new(x, 4.5, -half + 1.8)), Color = Color3.fromRGB(25, 25, 35) }))
		textSurface(sign, Enum.NormalId.Back, title, color)
		local pr = prompt(pad, "Start Run", objectText, name .. "Prompt")
		pr.MaxActivationDistance = 9
		return pad, pr
	end
	local pad, startPrompt = startPad("StartPad", -7, Color3.fromRGB(60, 230, 120), Color3.fromRGB(30, 90, 50), "SQUAD 1-4", "Squad (1-4 players)")
	local duoPad, duoPrompt = startPad("DuoPad", 7, Color3.fromRGB(80, 170, 255), Color3.fromRGB(30, 60, 110), "DUO", "Duo (2 players)")

	-- The camera looks north and down, so every board hangs on the north wall (face +Z)
	-- or is a lectern tilted up toward the camera.
	local TILT = CFrame.Angles(math.rad(-50), 0, 0) -- turns the Back (+Z) face up to the camera

	-- ARENA LECTERN (west of the start pad).
	local arenaSign = add(part({ Name = "ArenaSign", Size = Vector3.new(9, 4, 0.4), CFrame = CFrame.new(o + Vector3.new(-21, 2.2, -half + 17)) * TILT, Color = Color3.fromRGB(25, 25, 35), CanCollide = true }))
	local arenaGui = textSurface(arenaSign, Enum.NormalId.Back, "ARENA: FOREST", Color3.fromRGB(255, 220, 120))
	local arenaPrompt = prompt(arenaSign, "Change Arena", "Arena", "ArenaPrompt")

	-- CHARACTER BOARD (north wall, left).
	local charBoard = add(part({ Name = "CharacterBoard", Size = Vector3.new(12, 5, 0.5), CFrame = CFrame.new(o + Vector3.new(-19, 3.5, -half + 1.6)), Color = Color3.fromRGB(30, 30, 45) }))
	textSurface(charBoard, Enum.NormalId.Back, "CHARACTERS", Color3.fromRGB(120, 200, 255))
	local charPost = add(part({ Name = "CharacterPost", Size = Vector3.new(2, 1, 2), CFrame = CFrame.new(o + Vector3.new(-19, 0.5, -half + 6)), Color = Color3.fromRGB(80, 60, 45), CanCollide = true }))
	local charPrompt = prompt(charPost, "Choose Character", "Characters", "CharacterPrompt")

	-- SHOP BOARD (north wall, right).
	local shopBoard = add(part({ Name = "ShopBoard", Size = Vector3.new(12, 5, 0.5), CFrame = CFrame.new(o + Vector3.new(19, 3.5, -half + 1.6)), Color = Color3.fromRGB(30, 30, 45) }))
	textSurface(shopBoard, Enum.NormalId.Back, "UPGRADES", Color3.fromRGB(255, 210, 80))
	local shopPost = add(part({ Name = "ShopPost", Size = Vector3.new(2, 1, 2), CFrame = CFrame.new(o + Vector3.new(19, 0.5, -half + 6)), Color = Color3.fromRGB(80, 60, 45), CanCollide = true }))
	local shopPrompt = prompt(shopPost, "Open Shop", "Upgrades", "ShopPrompt")

	-- STATS LECTERN (east of the start pad). Each client draws its own stats on it.
	local statsSign = add(part({ Name = "StatsSign", Size = Vector3.new(9, 6, 0.4), CFrame = CFrame.new(o + Vector3.new(21, 2.8, -half + 17)) * TILT, Color = Color3.fromRGB(30, 30, 45), CanCollide = true }))

	MapBuilder.ApplyLighting("Lobby")

	-- Castle dressing from the Blender meshes once they are loaded (banners, torches, trees).
	MeshService.WhenReady({ "Banner", "Torch" }, function()
		for _, x in ipairs({ -27, 27 }) do
			local m = MeshService.Build("Banner", CFrame.new(o + Vector3.new(x, 0, -half + 2.2)), nil, 0.8)
			if m then
				m.Parent = folder
			end
		end
		for _, c in ipairs({ Vector3.new(-half + 3, 0, -half + 3), Vector3.new(half - 3, 0, -half + 3), Vector3.new(-half + 3, 0, half - 3), Vector3.new(half - 3, 0, half - 3), Vector3.new(-14, 0, -half + 9), Vector3.new(14, 0, -half + 9) }) do
			local m = MeshService.Build("Torch", CFrame.new(o + c), nil, 1)
			if m then
				local flame = m:FindFirstChild("Flame") :: BasePart?
				if flame then
					local light = Instance.new("PointLight")
					light.Color = Color3.fromRGB(255, 170, 90)
					light.Range = 18
					light.Brightness = 1.4
					light.Parent = flame
				end
				m.Parent = folder
			end
		end
	end)
	MeshService.WhenReady({ "Tree_Round", "Mushroom" }, function()
		for i, x in ipairs({ -18, -6, 6, 18 }) do
			local name = (i % 2 == 0) and "Mushroom" or "Tree_Round"
			local m = MeshService.Build(name, CFrame.new(o + Vector3.new(x, 0, half - 5)), nil, name == "Mushroom" and 0.8 or 0.55)
			if m then
				m.Parent = folder
			end
		end
	end)

	return {
		Model = folder,
		SpawnCFrame = CFrame.new(o + Vector3.new(0, 3.5, 6)),
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
		Root = root,
		Half = Config.Arenas.Size / 2,
		Center = Config.ArenaOrigin,
	}
end

-- Is (x, z) at least `clear` studs away from every obstacle already placed?
local function isFree(arena, x: number, z: number, clear: number): boolean
	local c = arena.Center
	if (Vector2.new(x - c.X, z - c.Z)).Magnitude < 32 then
		return false -- keep the player spawn area empty
	end
	for _, ob in ipairs(arena.Obstacles) do
		if ob.Kind == "Circle" then
			if (Vector2.new(ob.Pos.X - x, ob.Pos.Z - z)).Magnitude < ob.Radius + clear then
				return false
			end
		else
			if x > ob.MinX - clear and x < ob.MaxX + clear and z > ob.MinZ - clear and z < ob.MaxZ + clear then
				return false
			end
		end
	end
	return true
end

local function randomSpot(arena, clear: number, margin: number): (number?, number?)
	local c, h = arena.Center, arena.Half - margin
	for _ = 1, 30 do
		local x = c.X + rng:NextNumber(-h, h)
		local z = c.Z + rng:NextNumber(-h, h)
		if isFree(arena, x, z, clear) then
			return x, z
		end
	end
	return nil, nil
end

local function addCircleObstacle(arena, x: number, z: number, r: number)
	table.insert(arena.Obstacles, { Kind = "Circle", Pos = Vector3.new(x, 0, z), Radius = r })
end

-- Fence posts, rails and an invisible tall wall on all four sides.
local function buildBoundary(arena, style: string)
	local c, h = arena.Center, arena.Half
	local size = Config.Arenas.Size
	local fenceH = Config.Arenas.FenceHeight
	for i, side in ipairs({ Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0) }) do
		local along = (i <= 2) and Vector3.new(1, 0, 0) or Vector3.new(0, 0, 1)
		local mid = c + side * (h + 1)
		local wallSize = (i <= 2) and Vector3.new(size + 4, 60, 2) or Vector3.new(2, 60, size + 4)
		local wall = part({ Name = "Boundary", Size = wallSize, CFrame = CFrame.new(mid + Vector3.new(0, 30, 0)), Transparency = 1, CanCollide = true, CanQuery = true })
		wall.Parent = arena.ObstacleFolder
		if style == "Fence" then
			local railSize = (i <= 2) and Vector3.new(size, 0.6, 0.4) or Vector3.new(0.4, 0.6, size)
			for _, y in ipairs({ fenceH * 0.35, fenceH * 0.75 }) do
				part({ Name = "Rail", Size = railSize, CFrame = CFrame.new(mid + Vector3.new(0, y, 0)), Color = Color3.fromRGB(235, 230, 215), Material = Enum.Material.Wood }).Parent = arena.Model
			end
			for t = -h, h, 20 do
				part({ Name = "Post", Size = Vector3.new(1, fenceH, 1), CFrame = CFrame.new(mid + along * t + Vector3.new(0, fenceH / 2, 0)), Color = Color3.fromRGB(245, 240, 225), Material = Enum.Material.Wood }).Parent = arena.Model
			end
		else -- ruins: low stone wall with crenellations
			local solid = (i <= 2) and Vector3.new(size + 4, 5, 2.5) or Vector3.new(2.5, 5, size + 4)
			part({ Name = "RuinWall", Size = solid, CFrame = CFrame.new(mid + Vector3.new(0, 2.5, 0)), Color = Color3.fromRGB(140, 136, 126), Material = Enum.Material.Cobblestone }).Parent = arena.Model
			for t = -h, h, 8 do
				part({ Name = "Merlon", Size = Vector3.new(3, 2, 3), CFrame = CFrame.new(mid + along * t + Vector3.new(0, 6, 0)), Color = Color3.fromRGB(150, 146, 136), Material = Enum.Material.Cobblestone }).Parent = arena.Model
			end
		end
	end
end

------------------------------------------------------------------------------------------
-- Props: Blender mesh when loaded (MeshService), part-built fallback otherwise.
-- Every collidable prop also gets an invisible collision Part in ObstacleFolder plus an
-- obstacle shape, so movement and enemy steering never depend on the mesh.
------------------------------------------------------------------------------------------

local function meshProp(arena, name: string, cf: CFrame, scale: number, palette): boolean
	local model = MeshService.Build(name, cf, palette, scale)
	if model then
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CastShadow = true
			end
		end
		model.Parent = arena.Model
		return true
	end
	return false
end

local function collider(arena, x: number, z: number, r: number, h: number)
	local c = part({ Name = "Collider", Shape = Enum.PartType.Cylinder, Size = Vector3.new(h, r * 2, r * 2), CFrame = CFrame.new(x, h / 2, z) * CFrame.Angles(0, 0, math.rad(90)), Transparency = 1, CanCollide = true, CanQuery = true })
	c.Parent = arena.ObstacleFolder
	addCircleObstacle(arena, x, z, r)
end

local function tree(arena, x: number, z: number)
	local s = rng:NextNumber(0.8, 1.25)
	local kind = rng:NextNumber() < 0.6 and "Tree_Round" or "Tree_Pine"
	local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	if not meshProp(arena, kind, cf, s) then
		local trunkH = 7 * s
		part({ Name = "Trunk", Shape = Enum.PartType.Cylinder, Size = Vector3.new(trunkH, 2.4, 2.4), CFrame = CFrame.new(x, trunkH / 2, z) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(110, 75, 45), Material = Enum.Material.Wood }).Parent = arena.Model
		part({ Name = "Leaves", Shape = Enum.PartType.Ball, Size = Vector3.one * 8 * s, CFrame = CFrame.new(x, trunkH + 2, z), Color = Color3.fromRGB(70, 160, 70), Material = Enum.Material.Grass, CastShadow = true }).Parent = arena.Model
	end
	collider(arena, x, z, (kind == "Tree_Round" and 1.3 or 0.95) * s, 8)
end

local function mushroom(arena, x: number, z: number)
	local s = rng:NextNumber(0.7, 1.3)
	local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	if not meshProp(arena, "Mushroom", cf, s) then
		part({ Name = "Stem", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4 * s, 1.6 * s, 1.6 * s), CFrame = CFrame.new(x, 2 * s, z) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(240, 232, 215) }).Parent = arena.Model
		part({ Name = "Cap", Shape = Enum.PartType.Ball, Size = Vector3.new(6, 3, 6) * s, CFrame = CFrame.new(x, 4.6 * s, z), Color = Color3.fromRGB(225, 55, 45) }).Parent = arena.Model
	end
	collider(arena, x, z, 0.9 * s, 5 * s)
end

local function rock(arena, x: number, z: number)
	local s = rng:NextNumber(0.7, 1.5)
	local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	if not meshProp(arena, "Rock", cf, s) then
		part({ Name = "Rock", Shape = Enum.PartType.Ball, Size = Vector3.new(5, 3, 4) * s, CFrame = cf * CFrame.new(0, 1.2 * s, 0), Color = Color3.fromRGB(135, 138, 148), Material = Enum.Material.Slate }).Parent = arena.Model
	end
	collider(arena, x, z, 2.3 * s, 3 * s)
end

local function decoration(arena, name: string, x: number, z: number, scale: number, fallbackColor: Color3)
	local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
	if not meshProp(arena, name, cf, scale) then
		part({ Name = name, Shape = Enum.PartType.Ball, Size = Vector3.new(3, 2, 3) * scale, CFrame = cf * CFrame.new(0, scale, 0), Color = fallbackColor, Material = Enum.Material.Grass }).Parent = arena.Model
	end
end

-- FOREST: bright grass meadow with big low-poly trees, giant red mushrooms, rocks, bushes.
local function buildForest(arena)
	local c, h = arena.Center, arena.Half
	part({ Name = "Floor", Size = Vector3.new(h * 2 + 40, 2, h * 2 + 40), CFrame = CFrame.new(c - Vector3.new(0, 1, 0)), Color = Color3.fromRGB(104, 178, 76), Material = Enum.Material.Grass, CanCollide = true, CanQuery = true }).Parent = arena.Model
	-- soft darker grass patches instead of a hard grid
	for _ = 1, 26 do
		local x, z = c.X + rng:NextNumber(-h + 10, h - 10), c.Z + rng:NextNumber(-h + 10, h - 10)
		local r = rng:NextNumber(10, 26)
		part({ Name = "Patch", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, r * 2, r * 2), CFrame = CFrame.new(x, 0.03, z) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(88, 160, 66), Material = Enum.Material.Grass }).Parent = arena.Model
	end
	buildBoundary(arena, "Fence")
	for _ = 1, Config.Arenas.TreeCount do
		local x, z = randomSpot(arena, 7, 10)
		if x and z then
			tree(arena, x, z)
		end
	end
	for _ = 1, 14 do
		local x, z = randomSpot(arena, 6, 12)
		if x and z then
			mushroom(arena, x, z)
		end
	end
	for _ = 1, Config.Arenas.RockCount do
		local x, z = randomSpot(arena, 5, 10)
		if x and z then
			rock(arena, x, z)
		end
	end
	for _ = 1, 40 do
		local x, z = c.X + rng:NextNumber(-h + 6, h - 6), c.Z + rng:NextNumber(-h + 6, h - 6)
		if isFree(arena, x, z, 3) then
			decoration(arena, "Bush", x, z, rng:NextNumber(0.7, 1.2), Color3.fromRGB(70, 160, 70))
		end
	end
end

-- RUINS: mossy stone courtyard with broken pillars, glowing crystals and torches.
local function buildRuins(arena)
	local c, h = arena.Center, arena.Half
	part({ Name = "Floor", Size = Vector3.new(h * 2 + 40, 2, h * 2 + 40), CFrame = CFrame.new(c - Vector3.new(0, 1, 0)), Color = Color3.fromRGB(150, 146, 136), Material = Enum.Material.Cobblestone, CanCollide = true, CanQuery = true }).Parent = arena.Model
	for _ = 1, 30 do
		local x, z = c.X + rng:NextNumber(-h + 10, h - 10), c.Z + rng:NextNumber(-h + 10, h - 10)
		local r = rng:NextNumber(8, 20)
		part({ Name = "Moss", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, r * 2, r * 2), CFrame = CFrame.new(x, 0.03, z) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(96, 140, 72), Material = Enum.Material.Grass }).Parent = arena.Model
	end
	buildBoundary(arena, "Ruins")
	local lights = 0
	for _ = 1, 34 do
		local x, z = randomSpot(arena, 7, 12)
		if x and z then
			local s = rng:NextNumber(0.9, 1.3)
			local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
			if not meshProp(arena, "Pillar", cf, s) then
				part({ Name = "Pillar", Shape = Enum.PartType.Cylinder, Size = Vector3.new(8 * s, 2.4 * s, 2.4 * s), CFrame = CFrame.new(x, 4 * s, z) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(170, 166, 156), Material = Enum.Material.Slate }).Parent = arena.Model
			end
			collider(arena, x, z, 1.6 * s, 9 * s)
		end
	end
	for _ = 1, 18 do
		local x, z = randomSpot(arena, 5, 12)
		if x and z then
			local s = rng:NextNumber(0.8, 1.4)
			local cf = CFrame.new(x, 0, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
			if not meshProp(arena, "CrystalCluster", cf, s) then
				part({ Name = "Crystal", Size = Vector3.new(1, 3, 1) * s, CFrame = cf * CFrame.new(0, 1.5 * s, 0), Color = Color3.fromRGB(176, 91, 255), Material = Enum.Material.Neon }).Parent = arena.Model
			end
			if lights < 12 then
				lights += 1
				local glow = part({ Name = "Glow", Size = Vector3.one, CFrame = cf * CFrame.new(0, 2, 0), Transparency = 1 })
				local light = Instance.new("PointLight")
				light.Color = Color3.fromRGB(190, 110, 255)
				light.Range = 20
				light.Brightness = 1.5
				light.Parent = glow
				glow.Parent = arena.Model
			end
			collider(arena, x, z, 1.4 * s, 3)
		end
	end
	for _ = 1, 16 do
		local x, z = randomSpot(arena, 4, 10)
		if x and z then
			rock(arena, x, z)
		end
	end
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
