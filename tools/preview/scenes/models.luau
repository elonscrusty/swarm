-- models: contact sheet of every catalog model in the game's own colours (catalog
-- palettes; heroes through ModelBuilder.BuildCharacter), front 3/4 view, one ViewportFrame
-- per model. Models that are not uploaded yet are shown from meshes/ as well.
local C = lib("common")
local s = C.bootServer()
local MeshCatalog = C.shared("MeshCatalog")
local CharacterData = C.shared("CharacterData")
local catalog = preview.catalog()
local Lighting = game:GetService("Lighting")
Lighting.ClockTime = 14

local names = {}
for name in pairs(MeshCatalog and MeshCatalog.Models or {}) do
	table.insert(names, name)
end
local ORDER = { Heroes = 1, Enemies = 2, Pickups = 3, Projectiles = 4, World = 5 }
table.sort(names, function(a, b)
	local ca = ORDER[MeshCatalog.Models[a].Category] or 9
	local cb = ORDER[MeshCatalog.Models[b].Category] or 9
	if ca ~= cb then
		return ca < cb
	end
	return a < b
end)

local gui = Instance.new("ScreenGui")
gui.Name = "ModelSheet"
gui.IgnoreGuiInset = true
gui.ScreenInsets = Enum.ScreenInsets.None
gui.Parent = preview.playerGui()
local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
bg.BorderSizePixel = 0
bg.Parent = gui
local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -24, 0, 34)
title.Position = UDim2.fromOffset(12, 6)
title.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.Bold)
title.TextSize = 24
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(240, 236, 220)
title.Text = string.format("SWARM models - %d catalog models, game colours, front 3/4 view", #names)
title.Parent = bg
local grid = Instance.new("Frame")
grid.BackgroundTransparency = 1
grid.Position = UDim2.fromOffset(8, 44)
grid.Size = UDim2.new(1, -16, 1, -52)
grid.Parent = bg
local d = preview.device
local availW, availH = d.width - 16, d.height - 52
local n = math.max(1, #names)
local cell = math.floor(math.sqrt(availW * availH / n))
while cell > 40 and math.floor(availW / cell) * math.floor(availH / cell) < n do
	cell -= 2
end
local layout = Instance.new("UIGridLayout")
layout.CellSize = UDim2.fromOffset(cell - 6, cell - 6)
layout.CellPadding = UDim2.fromOffset(6, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = grid

for i, name in ipairs(names) do
	local entry = MeshCatalog.Models[name]
	local card = Instance.new("Frame")
	card.LayoutOrder = i
	card.BackgroundColor3 = Color3.fromRGB(196, 214, 230)
	card.BorderSizePixel = 0
	card.Parent = grid
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = card
	local vf = Instance.new("ViewportFrame")
	vf.BackgroundTransparency = 1
	vf.Size = UDim2.new(1, 0, 1, -30)
	vf.Ambient = Color3.fromRGB(150, 150, 160)
	vf.LightColor = Color3.fromRGB(255, 248, 235)
	vf.LightDirection = Vector3.new(-0.6, -1, 0.9)
	vf.Parent = card
	local model
	local isHero = CharacterData and CharacterData.Characters[name] ~= nil
	if isHero and s.ModelBuilder then
		model = C.try("BuildCharacter " .. name, s.ModelBuilder.BuildCharacter, name, "Default")
	elseif s.MeshService then
		model = C.try("MeshService.Build " .. name, s.MeshService.Build, name, CFrame.new(), nil, 1)
	end
	if model then
		model.Parent = vf
		local cf, size = model:GetBoundingBox()
		local radius = math.max(size.Magnitude / 2, 0.5)
		local dir = Vector3.new(0.6, 0.45, -1).Unit -- front (-Z), right, a little above
		local cam = Instance.new("Camera")
		cam.FieldOfView = 30
		cam.CFrame = CFrame.lookAt(cf.Position + dir * (radius / math.tan(math.rad(15)) * 1.08), cf.Position)
		cam.Parent = vf
		vf.CurrentCamera = cam
	else
		preview.warn("models scene: " .. name .. " could not be built")
	end
	local info = catalog[name]
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 6, 1, -30)
	label.Size = UDim2.new(1, -12, 0, 28)
	label.FontFace = Font.new("rbxasset://fonts/families/SourceSansPro.json", Enum.FontWeight.SemiBold)
	label.TextSize = math.clamp(math.floor(cell / 11), 10, 16)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(28, 31, 40)
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = string.format("%s  <font color=\"#55606e\">%s · %d pcs · %s tris%s</font>", name, entry.Category or "?", #entry.Pieces, info and tostring(info.tris) or "?", (entry.AssetId and entry.AssetId >= 990000000) and " · not uploaded" or "")
	label.RichText = true
	label.Parent = card
end
preview.render.background = Color3.fromRGB(28, 31, 40)
preview.render.hideCoreUi = true
preview.advance(0.2)
