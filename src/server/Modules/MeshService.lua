--[[
	MeshService.lua
	Loads the uploaded Blender mesh models (MeshCatalog AssetIds) with InsertService and
	keeps one template MeshPart per piece in ReplicatedStorage.SwarmMeshes/<Model>/<Piece>.
	Clients clone those templates for enemies / projectiles / crystals; the server clones
	them for characters, pickups, chests and map props.

	Models whose AssetId is 0 (not uploaded yet) or that fail to load are simply missing,
	and every caller falls back to its part-built model. Loading runs in the background,
	so the game starts instantly; ready models get the attribute Ready = true.
]]

local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MeshCatalog = require(ReplicatedStorage.Shared.MeshCatalog)

local MeshService = {}

local root: Folder
local readyEvent = Instance.new("BindableEvent")
local pending = 0
local started = false

MeshService.Ready = readyEvent.Event -- fires (modelName) each time a model finishes

local MATERIALS = {
	SmoothPlastic = Enum.Material.SmoothPlastic,
	Neon = Enum.Material.Neon,
	Metal = Enum.Material.Metal,
	Glass = Enum.Material.Glass,
}

local function vec(t: { number }): Vector3
	return Vector3.new(t[1], t[2], t[3])
end

-- Import rotation recorded by loadModel (nil when the mesh came in upright, the normal case).
local function importRotation(template: Instance): CFrame?
	local r = template:GetAttribute("ImportRotation")
	if typeof(r) == "CFrame" then
		return r
	end
	return nil
end

-- Catalog sizes are in model (Roblox) axes; a rotated import needs them in its local axes.
local function localSize(size: Vector3, template: Instance): Vector3
	local r = importRotation(template)
	if not r then
		return size
	end
	local v = r:VectorToObjectSpace(size)
	return Vector3.new(math.abs(v.X), math.abs(v.Y), math.abs(v.Z))
end

local function loadModel(name: string, entry)
	local ok, asset = pcall(function()
		return InsertService:LoadAsset(entry.AssetId)
	end)
	if not ok or not asset then
		warn(string.format("[MeshService] could not load %s (%d): %s", name, entry.AssetId, tostring(asset)))
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	-- index the imported MeshParts by name (ignoring any ".001" suffix); containers that
	-- share a piece's name (the importer wraps everything in a Model) are skipped
	local byName: { [string]: MeshPart } = {}
	for _, d in ipairs(asset:GetDescendants()) do
		if d:IsA("MeshPart") then
			local clean = string.gsub(d.Name, "%.%d+$", "")
			if not byName[clean] then
				byName[clean] = d
			end
		end
	end
	local found = 0
	for _, piece in ipairs(entry.Pieces) do
		local mesh = byName[piece.Name]
		if mesh then
			local template = mesh:Clone()
			for _, child in ipairs(template:GetChildren()) do
				child:Destroy() -- drop imported welds / attachments
			end
			template.Name = piece.Name
			template.Anchored = true
			template.CanCollide = false
			template.CanQuery = false
			template.CanTouch = false
			template.CastShadow = false
			-- The FBX nodes carry a Y-up axis rotation (Lcl Rotation 90, 0, 180) over Z-up
			-- vertex data. If the importer kept that rotation on the MeshPart instead of
			-- baking it, the geometry's local axes are not the catalog's (Roblox) axes and the
			-- piece would lie on its side. Remember the rotation so Build() can compensate.
			local rot = mesh.CFrame.Rotation
			if rot.UpVector.Y < 0.99 then
				template:SetAttribute("ImportRotation", rot)
				warn(string.format("[MeshService] %s.%s was imported rotated; compensating", name, piece.Name))
			end
			template.Size = localSize(vec(piece.Size), template)
			template.Material = MATERIALS[piece.Material] or Enum.Material.SmoothPlastic
			template.TextureID = ""
			template.Parent = folder
			found += 1
		else
			warn(string.format("[MeshService] %s is missing piece %s", name, piece.Name))
		end
	end
	asset:Destroy()
	if found == #entry.Pieces then
		folder:SetAttribute("Ready", true)
		folder.Parent = root
		readyEvent:Fire(name)
	else
		folder:Destroy()
	end
end

-- Template folder for a model, or nil when it isn't loaded.
function MeshService.Get(name: string): Folder?
	local f = root and root:FindFirstChild(name)
	if f and f:GetAttribute("Ready") then
		return f :: Folder
	end
	return nil
end

function MeshService.IsLoading(): boolean
	return pending > 0
end

-- True while model `name` is not loaded yet but still might be (uploaded, and loading has
-- not started or not finished). Callers use it to swap a fallback for the mesh later.
function MeshService.MayLoad(name: string): boolean
	local entry = MeshCatalog.Models[name]
	if not entry or not entry.AssetId or entry.AssetId == 0 or MeshService.Get(name) then
		return false
	end
	return not started or pending > 0
end

--[[
	Builds an anchored Model of a mesh model at `cframe` (origin = ground centre).
	palette overrides slot colours; scale multiplies the whole model.
	Returns nil when the model isn't loaded.
]]
function MeshService.Build(name: string, cframe: CFrame, palette: { [string]: Color3 }?, scale: number?): Model?
	local folder = MeshService.Get(name)
	local entry = MeshCatalog.Models[name]
	if not folder or not entry then
		return nil
	end
	local s = scale or 1
	local model = Instance.new("Model")
	model.Name = name
	for _, piece in ipairs(entry.Pieces) do
		local template = folder:FindFirstChild(piece.Name) :: MeshPart?
		if template then
			local part = template:Clone()
			part.Size = localSize(vec(piece.Size), template) * s
			local color = (palette and palette[piece.Slot]) or (entry.Palette and entry.Palette[piece.Slot])
			if color then
				part.Color = color
			end
			part.Transparency = piece.Transparency or 0
			part.CastShadow = piece.Shadow == true
			-- piece centre in model space; an imported rotation (rare) keeps the mesh upright
			part.CFrame = cframe * CFrame.new(vec(piece.Offset) * s) * (importRotation(template) or CFrame.identity)
			part.Parent = model
		end
	end
	return model
end

-- Calls fn when every listed model is loaded (or immediately when already loaded).
function MeshService.WhenReady(names: { string }, fn: () -> ())
	local function check(): boolean
		for _, n in ipairs(names) do
			if not MeshService.Get(n) then
				return false
			end
		end
		return true
	end
	if check() then
		task.spawn(fn)
		return
	end
	local conn
	conn = readyEvent.Event:Connect(function()
		if check() then
			conn:Disconnect()
			fn()
		end
	end)
end

function MeshService.Init(_ctx)
	root = Instance.new("Folder")
	root.Name = "SwarmMeshes"
	root.Parent = ReplicatedStorage
end

function MeshService.Start()
	started = true
	for name, entry in pairs(MeshCatalog.Models) do
		if entry.AssetId and entry.AssetId ~= 0 then
			pending += 1
			task.spawn(function()
				loadModel(name, entry)
				pending -= 1
			end)
		end
	end
end

return MeshService
