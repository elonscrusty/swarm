--[[
	MapBuilder.lua
	Procedurally builds the lobby and the two arenas from Parts.

	BuildLobby()        → lobby table (boards, start pad, spawn), built once at boot
	BuildArena(name)    → arena table, replaces any previous arena
	DestroyArena()
	ApplyLighting(name) → "Lobby" | "Backyard" | "Mall"

	Every collidable arena obstacle is also recorded as a simple shape in
	arena.Obstacles so EnemyAI can push enemies out of them cheaply:
	  { Kind = "Circle", Pos = Vector3, Radius = r }
	  { Kind = "Box", Pos = centre, Radius = halfDiagonal, MinX, MaxX, MinZ, MaxZ }
	Obstacle Parts live in arena.ObstacleFolder (the only thing enemy raycasts hit).
]]

local Lighting = game:GetService("Lighting")

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local ModelBuilder = require(script.Parent.ModelBuilder)

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
	if name == "Mall" then
		Lighting.ClockTime = 0.5
		Lighting.Brightness = 1.2
		Lighting.Ambient = Color3.fromRGB(110, 90, 140)
		Lighting.OutdoorAmbient = Color3.fromRGB(120, 100, 150)
		Lighting.FogEnd = 100000
	elseif name == "Lobby" then
		Lighting.ClockTime = 17.5
		Lighting.Brightness = 2
		Lighting.Ambient = Color3.fromRGB(120, 105, 95)
		Lighting.OutdoorAmbient = Color3.fromRGB(150, 130, 115)
		Lighting.FogEnd = 100000
	else -- Backyard: bright day
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

	-- Floor: warm wooden planks.
	add(part({ Name = "Floor", Size = Vector3.new(size, 2, size), CFrame = CFrame.new(o + Vector3.new(0, -1, 0)), Color = Color3.fromRGB(150, 105, 70), Material = Enum.Material.WoodPlanks, CanCollide = true, CanQuery = true }))
	-- Rug in the middle.
	add(part({ Name = "Rug", Size = Vector3.new(26, 0.1, 18), CFrame = CFrame.new(o + Vector3.new(0, 0.05, 4)), Color = Color3.fromRGB(150, 50, 60), Material = Enum.Material.Fabric }))
	add(part({ Name = "RugBorder", Size = Vector3.new(28, 0.08, 20), CFrame = CFrame.new(o + Vector3.new(0, 0.03, 4)), Color = Color3.fromRGB(230, 190, 90), Material = Enum.Material.Fabric }))

	-- Walls (low so the top-down camera can see over them) + tall invisible barriers.
	local wallColor = Color3.fromRGB(205, 185, 160)
	for _, w in ipairs({
		{ Vector3.new(0, wallH / 2, -half), Vector3.new(size + 2, wallH, 2) },
		{ Vector3.new(0, wallH / 2, half), Vector3.new(size + 2, wallH, 2) },
		{ Vector3.new(-half, wallH / 2, 0), Vector3.new(2, wallH, size + 2) },
		{ Vector3.new(half, wallH / 2, 0), Vector3.new(2, wallH, size + 2) },
	}) do
		add(part({ Name = "Wall", Size = w[2], CFrame = CFrame.new(o + w[1]), Color = wallColor, Material = Enum.Material.Plaster, CanCollide = true }))
		local barrier = add(part({ Name = "Barrier", Size = Vector3.new(w[2].X, 40, w[2].Z), CFrame = CFrame.new(o + Vector3.new(w[1].X, 20, w[1].Z)), Transparency = 1, CanCollide = true }))
		barrier.CastShadow = false
	end
	-- Wainscot trim.
	for _, z in ipairs({ -half + 1.1, half - 1.1 }) do
		add(part({ Name = "Trim", Size = Vector3.new(size, 0.6, 0.2), CFrame = CFrame.new(o + Vector3.new(0, wallH - 0.3, z)), Color = Color3.fromRGB(110, 70, 45), Material = Enum.Material.Wood }))
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
	-- Plants along the south wall.
	for i = -2, 2 do
		local pos = o + Vector3.new(i * 9, 0, half - 4)
		add(part({ Name = "Pot", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.6, 2, 2), CFrame = CFrame.new(pos + Vector3.new(0, 0.8, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(170, 90, 60), Material = Enum.Material.Slate, CanCollide = true }))
		add(part({ Name = "Leaves", Shape = Enum.PartType.Ball, Size = Vector3.new(3, 3, 3), CFrame = CFrame.new(pos + Vector3.new(0, 2.8, 0)), Color = Color3.fromRGB(70, 150, 70), Material = Enum.Material.Grass }))
	end

	-- START PAD (north centre).
	local padPos = o + Vector3.new(0, 0.15, -half + 12)
	local pad = add(part({ Name = "StartPad", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 12, 12), CFrame = CFrame.new(padPos) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(60, 230, 120), Material = Enum.Material.Neon, CanQuery = true }))
	local padRing = add(part({ Name = "StartRing", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.2, 14, 14), CFrame = CFrame.new(padPos - Vector3.new(0, 0.05, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(30, 90, 50) }))
	padRing.Name = "StartRing"
	local padSign = add(part({ Name = "StartSign", Size = Vector3.new(12, 3, 0.4), CFrame = CFrame.new(o + Vector3.new(0, 4.5, -half + 3)), Color = Color3.fromRGB(25, 25, 35) }))
	textSurface(padSign, Enum.NormalId.Back, "START RUN", Color3.fromRGB(90, 255, 140))
	local startPrompt = prompt(pad, "Start Run", "Swarm", "StartPrompt")
	startPrompt.MaxActivationDistance = 10

	-- The camera looks north and down, so every board hangs on the north wall (face +Z)
	-- or is a lectern tilted up toward the camera.
	local TILT = CFrame.Angles(math.rad(-50), 0, 0) -- turns the Back (+Z) face up to the camera

	-- ARENA LECTERN (west of the start pad).
	local arenaSign = add(part({ Name = "ArenaSign", Size = Vector3.new(9, 4, 0.4), CFrame = CFrame.new(o + Vector3.new(-14, 2.2, -half + 14)) * TILT, Color = Color3.fromRGB(25, 25, 35), CanCollide = true }))
	local arenaGui = textSurface(arenaSign, Enum.NormalId.Back, "ARENA: BACKYARD", Color3.fromRGB(255, 220, 120))
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
	local statsSign = add(part({ Name = "StatsSign", Size = Vector3.new(9, 6, 0.4), CFrame = CFrame.new(o + Vector3.new(14, 2.8, -half + 14)) * TILT, Color = Color3.fromRGB(30, 30, 45), CanCollide = true }))

	MapBuilder.ApplyLighting("Lobby")

	return {
		Model = folder,
		SpawnCFrame = CFrame.new(o + Vector3.new(0, 3.5, 6)),
		StartPrompt = startPrompt,
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

local function addBoxObstacle(arena, cf: CFrame, size: Vector3)
	local hx, hz = size.X / 2, size.Z / 2
	local p = cf.Position
	table.insert(arena.Obstacles, {
		Kind = "Box",
		Pos = Vector3.new(p.X, 0, p.Z),
		Radius = math.sqrt(hx * hx + hz * hz),
		MinX = p.X - hx,
		MaxX = p.X + hx,
		MinZ = p.Z - hz,
		MaxZ = p.Z + hz,
	})
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
		else -- mall: solid tiled wall with neon strip
			local solid = (i <= 2) and Vector3.new(size + 4, 10, 2) or Vector3.new(2, 10, size + 4)
			part({ Name = "MallWall", Size = solid, CFrame = CFrame.new(mid + Vector3.new(0, 5, 0)), Color = Color3.fromRGB(70, 60, 90), Material = Enum.Material.SmoothPlastic }).Parent = arena.Model
			local stripSize = (i <= 2) and Vector3.new(size, 0.4, 2.2) or Vector3.new(2.2, 0.4, size)
			part({ Name = "NeonStrip", Size = stripSize, CFrame = CFrame.new(mid + Vector3.new(0, 9, 0)), Color = Color3.fromRGB(255, 60, 200), Material = Enum.Material.Neon }).Parent = arena.Model
		end
	end
end

-- Subtle grid: thin slightly-different lines every 20 studs.
local function buildGrid(arena, color: Color3, spacing: number, transparency: number)
	local c, h = arena.Center, arena.Half
	for t = -h + spacing, h - spacing, spacing do
		part({ Name = "GridX", Size = Vector3.new(arena.Half * 2, 0.05, 0.25), CFrame = CFrame.new(c + Vector3.new(0, 0.03, t)), Color = color, Transparency = transparency }).Parent = arena.Model
		part({ Name = "GridZ", Size = Vector3.new(0.25, 0.05, arena.Half * 2), CFrame = CFrame.new(c + Vector3.new(t, 0.03, 0)), Color = color, Transparency = transparency }).Parent = arena.Model
	end
end

local function buildBackyard(arena)
	local c, h = arena.Center, arena.Half
	part({ Name = "Floor", Size = Vector3.new(h * 2 + 40, 2, h * 2 + 40), CFrame = CFrame.new(c - Vector3.new(0, 1, 0)), Color = Color3.fromRGB(95, 165, 70), Material = Enum.Material.Grass, CanCollide = true, CanQuery = true }).Parent = arena.Model
	buildGrid(arena, Color3.fromRGB(80, 145, 60), 20, 0.4)
	buildBoundary(arena, "Fence")

	-- Trees: trunk (collidable obstacle) + two leaf balls.
	for _ = 1, Config.Arenas.TreeCount do
		local x, z = randomSpot(arena, 6, 10)
		if x and z then
			local trunkH = rng:NextNumber(6, 9)
			local trunk = part({ Name = "Trunk", Shape = Enum.PartType.Cylinder, Size = Vector3.new(trunkH, 2.4, 2.4), CFrame = CFrame.new(x, trunkH / 2, z) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(110, 75, 45), Material = Enum.Material.Wood, CanCollide = true, CanQuery = true })
			trunk.Parent = arena.ObstacleFolder
			local leafSize = rng:NextNumber(7, 10)
			part({ Name = "Leaves", Shape = Enum.PartType.Ball, Size = Vector3.one * leafSize, CFrame = CFrame.new(x, trunkH + leafSize * 0.3, z), Color = Color3.fromRGB(60, 140 + rng:NextInteger(-20, 20), 55), Material = Enum.Material.Grass, CastShadow = true }).Parent = arena.Model
			part({ Name = "Leaves2", Shape = Enum.PartType.Ball, Size = Vector3.one * leafSize * 0.7, CFrame = CFrame.new(x + 1.5, trunkH + leafSize * 0.7, z - 1), Color = Color3.fromRGB(75, 160, 65), Material = Enum.Material.Grass }).Parent = arena.Model
			addCircleObstacle(arena, x, z, 1.4)
		end
	end
	-- Rocks.
	for _ = 1, Config.Arenas.RockCount do
		local x, z = randomSpot(arena, 5, 10)
		if x and z then
			local r = rng:NextNumber(1.8, 3.6)
			local rock = part({ Name = "Rock", Shape = Enum.PartType.Ball, Size = Vector3.new(r * 2, r * 1.4, r * 2), CFrame = CFrame.new(x, r * 0.4, z) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0), Color = Color3.fromRGB(125 + rng:NextInteger(-15, 15), 125, 130), Material = Enum.Material.Slate, CanCollide = true, CanQuery = true })
			rock.Parent = arena.ObstacleFolder
			addCircleObstacle(arena, x, z, r * 0.9)
		end
	end
	-- Flower patches (decoration, no collision).
	for _ = 1, 40 do
		local x, z = c.X + rng:NextNumber(-h + 5, h - 5), c.Z + rng:NextNumber(-h + 5, h - 5)
		local colors = { Color3.fromRGB(255, 240, 90), Color3.fromRGB(255, 120, 160), Color3.fromRGB(255, 255, 255) }
		part({ Name = "Flower", Shape = Enum.PartType.Ball, Size = Vector3.new(0.7, 0.4, 0.7), CFrame = CFrame.new(x, 0.15, z), Color = colors[rng:NextInteger(1, 3)], Material = Enum.Material.SmoothPlastic }).Parent = arena.Model
	end
end

local function buildMall(arena)
	local c, h = arena.Center, arena.Half
	part({ Name = "Floor", Size = Vector3.new(h * 2 + 40, 2, h * 2 + 40), CFrame = CFrame.new(c - Vector3.new(0, 1, 0)), Color = Color3.fromRGB(225, 220, 215), Material = Enum.Material.Marble, CanCollide = true, CanQuery = true }).Parent = arena.Model
	buildGrid(arena, Color3.fromRGB(170, 165, 175), 10, 0.2)
	buildBoundary(arena, "Mall")

	local neon = { Color3.fromRGB(255, 60, 200), Color3.fromRGB(60, 220, 255), Color3.fromRGB(255, 220, 60), Color3.fromRGB(120, 255, 120), Color3.fromRGB(190, 100, 255) }
	local lights = 0
	for i = 1, Config.Arenas.StorefrontCount do
		-- storefront blocks: rotate 0 or 90 degrees, need clear space
		local w, d = rng:NextNumber(18, 30), rng:NextNumber(8, 12)
		if rng:NextNumber() < 0.5 then
			w, d = d, w
		end
		local x, z = randomSpot(arena, math.max(w, d) / 2 + 8, math.max(w, d) / 2 + 12)
		if x and z then
			local height = 12
			local cf = CFrame.new(x, height / 2, z)
			local size = Vector3.new(w, height, d)
			local block = part({ Name = "Storefront", Size = size, CFrame = cf, Color = Color3.fromRGB(80 + rng:NextInteger(0, 40), 70, 100), Material = Enum.Material.SmoothPlastic, CanCollide = true, CanQuery = true })
			block.Parent = arena.ObstacleFolder
			local color = neon[(i - 1) % #neon + 1]
			-- glass window band and neon sign on every side
			part({ Name = "Window", Size = Vector3.new(w + 0.2, 4, d + 0.2), CFrame = cf * CFrame.new(0, -2, 0), Color = Color3.fromRGB(150, 200, 230), Material = Enum.Material.Glass, Transparency = 0.3 }).Parent = arena.Model
			local sign = part({ Name = "Sign", Size = Vector3.new(w + 0.4, 1.2, d + 0.4), CFrame = cf * CFrame.new(0, height / 2 - 1.5, 0), Color = color, Material = Enum.Material.Neon })
			sign.Parent = arena.Model
			if lights < 12 then
				lights += 1
				local light = Instance.new("PointLight")
				light.Color = color
				light.Range = 30
				light.Brightness = 2
				light.Parent = sign
			end
			addBoxObstacle(arena, cf, size)
		end
	end
	-- Benches and planters as small round obstacles.
	for _ = 1, 24 do
		local x, z = randomSpot(arena, 5, 12)
		if x and z then
			local planter = part({ Name = "Planter", Shape = Enum.PartType.Cylinder, Size = Vector3.new(2.5, 4, 4), CFrame = CFrame.new(x, 1.25, z) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(240, 240, 245), Material = Enum.Material.Marble, CanCollide = true, CanQuery = true })
			planter.Parent = arena.ObstacleFolder
			part({ Name = "Bush", Shape = Enum.PartType.Ball, Size = Vector3.new(3.6, 3, 3.6), CFrame = CFrame.new(x, 3.2, z), Color = Color3.fromRGB(60, 160, 80), Material = Enum.Material.Grass }).Parent = arena.Model
			addCircleObstacle(arena, x, z, 2)
		end
	end
	-- Ceiling light grid (neon panels high above, no shadows).
	for gx = -h + 40, h - 40, 80 do
		for gz = -h + 40, h - 40, 80 do
			part({ Name = "CeilingPanel", Size = Vector3.new(14, 0.3, 14), CFrame = CFrame.new(c + Vector3.new(gx, 0.04, gz)), Color = neon[rng:NextInteger(1, #neon)], Material = Enum.Material.Neon, Transparency = 0.6 }).Parent = arena.Model
		end
	end
end

-- Builds an arena by name, destroying the previous one.
function MapBuilder.BuildArena(name: string)
	MapBuilder.DestroyArena()
	local arena = newArena(name)
	if name == "Mall" then
		buildMall(arena)
	else
		buildBackyard(arena)
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
